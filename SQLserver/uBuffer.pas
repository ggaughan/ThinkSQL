unit uBuffer;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE SAFETY}
//{$DEFINE DEBUGDETAIL} //debug pin and unpin activity
//{$DEFINE DEBUGDETAIL2} //debug flushpage & reaper fail activity - use for buffer allocation tuning

{$DEFINE LIMIT_HASH_PROBE} //limit probe for 1st empty slot to within MaxProbe
                           //MaxProbe=0 -> force reaper to try to use exact hash slot (unless pinned)
                           //note: remove when live(?) - could lead to too much flushing/hotspots - test!
                           //      - especially with multiple open catalogs

{Frame Buffer Manager
   This manages a number of buffer frames
   and provides the interface layer between the db(s) and the disk (via pages)

 Frame buffer definitions
   A frame encapsulates a disk page in buffer memory
   (callers access pages directly though, for speed)

Note: if, in future, we try to avoid writes back to disk by removing rolled-back/uncommitted data
       bear in mind the fact that some index updates just dirty the page without making any changes
       to ensure duplicates that are being relied on/re-used are committed with their transaction,
       even though the original writer may otherwise have rolled back the index entry.

 Note: 30/01/03
       Added FframeCS to safeguard access to frame array, else with heavy use on large
       files would occasionally get invalid pages = disaster!
}

interface

uses uGlobal, uPage, uDatabase, uStmt,  SyncObjs {for Critcal Sections};

//todo debug  MaxFrames=24;    //maximum size of buffer pool (per db?)
{$IFDEF LIMIT_HASH_PROBE}
const
  MaxProbe=trunc(0.05*DefaultMaxFrames{20}); //maximum range for hash-match probe //todo make a fraction of MaxFrames? //Must be <MaxFrames!
{$ENDIF}

type
  TFrame=class
    private
      page:TPage;                     //pointer to data
      FDB:TDB;                        //database id - only used to identify when freeing
      Fid:PageId;                     //page id
      FpinCount:integer;              //pin-count
      FlruCount:integer;              //used for Reaper LRU routine - can't merge with pinCount as one book suggests because we need to count pins/unpins
                                      //but we could use to ensure we keep important pages in buffer, e.g. system catalog
      FhitCount:cardinal;             //used to track 'hot' frames, e.g. for multiple catalog monitoring
      FdbThrashCount:cardinal;        //used to track 'hot' swapping frames, i.e. for multiple catalog monitoring
    public
      constructor Create;
      destructor Destroy; override;
      property id:PageId read Fid write Fid;
      property db:TDB read FDB;
      property pinCount:integer read FpinCount;
      property lruCount:integer read FlruCount write FlruCount;
      property hitCount:cardinal read FhitCount write FhitCount;
      property dbThrashCount:cardinal read FdbThrashCount write FdbThrashCount;
      function pin:integer;
      function unpin:integer;

      {debug}
      procedure Status(slot:integer);
  end; {TFrame}

  TBufMgr=class
    private
      Fframe:array [0..DefaultMaxFrames-1] of TFrame;  //buffer pool
      FreaperHand:integer;
      //FreaperCS:TCriticalSection;
      FframeCS:TCriticalSection;

      function getstatusBufferHit:cardinal;
      function getstatusBufferMiss:cardinal;
      function flushFramePage(st:TStmt;res:integer):integer;
    public
      property reaperHand:integer read FreaperHand write FreaperHand;

      property statusBufferHit:cardinal read getstatusBufferHit;
      property statusBufferMiss:cardinal read getstatusBufferMiss;

      constructor Create;
      destructor Destroy; override;
      function pinPage(st:TStmt;id:PageId;var p:Tpage):integer;    //frame-level read
      function unpinPage(st:TStmt;id:PageId):integer;              //frame-level write/release
      function flushPage(st:TStmt;id:PageId;otherDB:TDB):integer;//frame-level flush
      function flushAllPages(st:TStmt):integer;                    //frame-level total flush
      function Reaper(st:TStmt;id:PageId):integer{frameId};

      function resetPageFrame(st:TStmt;id:PageId):integer;//frame-level reset
      function resetAllFrames(db:TDB):integer;                   //frame-level total reset for a db

      {debug}
      procedure Status;
    end; {TBufMgr}

implementation

uses uLog, sysUtils, uTransaction, uOS;

const
  where='uBuffer';
  who='';
  pinPageReaperFailBackoffMin=20; //min. milliseconds (plus random) //todo make proportional to CPU speed/buffer size
  pinPageReaperFailBackoffExtra=200; //max. milliseconds (random) //todo make proportional to CPU speed/buffer size

var
  debugBufferHit:int64=0;
  debugBufferMiss:int64=0;
  debugBufferFlush:int64=0; //todo remove? -or at least make private

constructor TFrame.Create;
begin
  page:=TPage.create;
end;

destructor TFrame.Destroy;
const routine=':Destroy';
begin
//log(where+routine,'page='+inttostr(integer(page)),vdebug);
  page.Free;
  inherited Destroy;
end;

function TFrame.pin:integer;
begin
  inc(FpinCount);
  result:=pinCount;  //note: not really used - otherwise use InterlockedIncrement
end;

function TFrame.unpin:integer;
const routine=':unpin';
begin
  dec(FpinCount);
  if FpinCount<0 then
  begin
    {This problem could hide innocent errors, e.g. over-keen unpinning = no problem
     or nasty ones, e.g. same page pinned into two frames
     So clear up all occurrences! & raised error level to Assertion}
    {$IFDEF SAFETY}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Page %d pincount is already 0 - extra unpin will be ignored',[self.id]),vAssertion);
    {$ENDIF}
    {$ENDIF}
    FpinCount:=0;
  end;
  result:=pinCount;  //note: not really used - otherwise use InterlockedDecrement
end;


{debug}
procedure TFrame.Status(slot:integer);
begin
  if id=InvalidPageId then
    {$IFDEF DEBUG_LOG}
    log.add(who,where,format(' %4d: db=%10.10s, id=%5d, pincount=%2d, dirty=%1d, lru=%4d, dbswap=%6d, hit=%d',[slot,'?',id,pincount,ord(page.dirty),flruCount,fdbThrashCount,fhitcount]),vdebug)
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where,format(' %4d: db=%10.10s, id=%5d, pincount=%2d, dirty=%1d, lru=%4d, dbswap=%6d, hit=%d',[slot,fdb.dbname,id,pincount,ord(page.dirty),flruCount,fdbThrashCount,fhitcount]),vdebug)
    {$ELSE}
    ;
    {$ENDIF}
end;


{TBufMgr}

constructor TBufMgr.Create;
var
  i:integer;
begin
  for i:=0 to MaxFrames-1 do
  begin
    fFrame[i]:=TFrame.Create;
    fFrame[i].id:=InvalidPageId;
    fFrame[i].fPinCount:=0;
    fFrame[i].flruCount:=0;
    fFrame[i].fhitCount:=0;
    fFrame[i].dbThrashCount:=0;
  end;
  //FreaperCS:=TCriticalSection.Create;
  reaperHand:=0; //start at 1st frame
  FframeCS:=TCriticalSection.Create;
end;

destructor TBufMgr.Destroy;
var
  i:integer;
begin
  for i:=MaxFrames-1 downto 0 do
  begin
    //todo assertions?
    fFrame[i].Free;
  end;
  FframeCS.free;
  //FreaperCS.free;
  inherited Destroy;
end;

function TBufMgr.getstatusBufferHit:cardinal;
begin
  result:=debugBufferHit;
end;
function TBufMgr.getstatusBufferMiss:cardinal;
begin
  result:=debugBufferMiss;
end;

function TBufMgr.pinPage(st:TStmt;id:PageId;var p:Tpage):integer;
{Pins a db page. If necessary it is read from disk first
 IN     : db        - the database - Note: tr.db is not always available (e.g. when creating a db with a system tran)
          id        - the disk page id
 OUT    : p         - a pointer to the page data in the buffer pool
 RETURN : +ve=ok, -ve=failed
}
const routine=':pinPage';
var
  res:cardinal;
  hash,foundEmpty:integer;
  freeFrame:integer;
  csLeft:boolean;
  retry:integer;
begin
  result:=OK;
  //find the page in the buffer first
  //todo: everywhere: replace MOD with assembler?  speed
  {Note: we need to check every frame because the reaper could return any free frame in case most are pinned
   Once the page is read in, subsequent finding will be quick (especially if we're trying to limit probe-lengths)
   But first checks will have to scan the entire buffer: no way around unless we can guarantee local free frames: how?
                                                         Maybe using hash-chains is the way forward?
  }
  csLeft:=False; //track CS early leave
  FframeCS.Enter; //ensure only one frame search runs at once, else slight risk that same frame gets returned (e.g. find one which gets unpinned by someone else before we pin & return it)
  try
    hash:=id MOD MaxFrames;
    res:=0;
    foundEmpty:=-1; //while we're looking for the page, make a note of the 1st empty slot we pass in case we need it
    while res<MaxFrames do
    begin
      if fFrame[(hash+res) MOD MaxFrames].id=id then
        if fFrame[(hash+res) MOD MaxFrames].fdb=Ttransaction(st.owner).db then break;       //we need this check to allow multi-db's per server & use 1 buffer area - i.e to avoid page-id clashes
      {Note first empty slot - we might need it if this search fails}
      if foundEmpty=-1 then
        if (fFrame[(hash+res) MOD MaxFrames].id=InvalidPageId) and (fFrame[(hash+res) MOD MaxFrames].pinCount=0){i.e. not pinned by reaper} then
          foundEmpty:=res;
      inc(res);
    end;

    if res>=MaxFrames then
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d not found in buffer - will read now (foundEmpty=%d)',[id,foundEmpty]),vdebug);
      {$ENDIF}
      {$ENDIF}
      inc(debugBufferMiss);

      if foundEmpty=-1 then
        res:=MaxFrames+1 //fail & force reaper
      else
        res:=foundEmpty;

      {$IFDEF LIMIT_HASH_PROBE}
      {We're better off trying Reaper here if foundEmpty is a long way away from our original site (speed)
       (although a background reaper should prevent the need for this(?) as would a MRU reaper strategy
        for 'count(*) bigTable' etc.)
      }
      if foundEmpty>MaxProbe then
        res:=MaxFrames+1; //ignore foundEmpty - i.e. hash to within MaxProbe slots only & call reaper if not available
                          //- hopefully reaper will flush & return that frame, else one very nearby
                          //note: room for improvement?
      {$ENDIF}

      if res>=MaxFrames then
      begin
        res:=InvalidPageId;
        retry:=-1;
        while (res=InvalidPageId) and ((retry>0) or (retry=-1)) do //outer loop to retry in case reaper can't find space
        begin
          if retry>0 then
          begin
            dec(retry); //i.e. once retry fired, no more to avoid infinite loop
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Retrying (%d more tries to go)',[retry]),vDebugMedium);
            {$ENDIF}
          end;

          res:=Reaper(st,id); //note:reaper now uses critical section & leaves the found page pinned so it's protected for us
          if res=InvalidPageId then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'No more suitable frames free - Reaper unable to help.. will wait & retry',vdebugError);
            {$ENDIF}

            sleepOS(pinPageReaperFailBackoffMin+random(pinPageReaperFailBackoffExtra));

            if retry=-1 then retry:=50; //todo higher/lower/relative/configurable?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
            {$ENDIF}
            //exit;
            continue; //abort/retry
          end;

          //success & reaper will have left page pinned
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('No more suitable frames free - Reaper request returned frame %d',[res]),vdebugLow);
          {$ENDIF}
          {$ENDIF}
        end; {retry}

        if (res=InvalidPageId) then
        begin
          if (retry=0) then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed after retries',[nil]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}

          //todo show buffer status with page type details

          result:=-3; //failed //note: causes major problems for caller - better to cancel or at least get callers to check result!

          //note: if we fail here - we get range-check errors as if caller is using a weird frame/page....
          //note: set page:=nil?
          exit; //abort
        end;
      end
      else
      begin
        res:=(hash+res) MOD MaxFrames;
        {Ensure this frame slot is not used by another thread by tacking it
        }
        fFrame[res].pin;   //reserve this frame to prevent it from being allocated twice
      end;

      {$IFDEF SAFETY}
      if fFrame[res].pinCount<>1 then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('!Page %d not found in buffer, and is about to be read into free frame %d but frame is now pinned with page %d (pincount=%d but 1 expected)',[id,res,fFrame[res].id,fFrame[res].pincount]),vAssertion); //i.e. race condition: shouldn't happen now we have CS around buffer pinning!
        {$ENDIF}
        //note: abort & return nil rather than return wrong page?
      end;
      {$ENDIF}
      try
        freeFrame:=res;
        //ok, read into the free frame
        {Since we're going to release our CS we must ensure any parallel pinners
         of this page wait until we've finished reading it. So we latch it while we read
         and get others to latch/unlatch when they pin it so they queue if its not ready
         (otherwise we risk them reading garbage)}
        result:=fFrame[freeFrame].page.latch(st);
        if result=ok then
        begin
          try
            //complete the frame
            {This will make the page visible to other pinners, i.e. so they don't try to put the same
             page elsewhere. They must latch before they proceed to ensure they wait for us to read etc.}
            fFrame[freeFrame].id:=id;
            if fFrame[freeFrame].fdb<>Ttransaction(st.owner).db then
              inc(fFrame[freeFrame].fdbThrashCount);
            fFrame[freeFrame].fdb:=Ttransaction(st.owner).db;

            {It's safe to leave CS now, especially before readPage else we hold up non-readers unecessarily}
            FframeCS.Leave; //Note: it makes sense anyway since our search stability is no longer needed because we've pinned our page/frame & latch it to queue any others
            csLeft:=True; //track CS early leave

            if Ttransaction(st.owner).db.readPage(id,fFrame[freeFrame].page)=ok then
            begin
              //pin the frame
              //note: 03/01/03 no need to pin above/in reaper if we move this before CS leave...?
              fFrame[freeFrame].pin;   //todo assert result of pin=0!?
              fFrame[freeFrame].flruCount:=1;
              inc(fFrame[freeFrame].fhitCount);
              p:=fFrame[freeFrame].page; //return the now buffered page
            end
            else
            begin
              {This could happen if torn page flags were not in sync. (check result code)
               if so, we should tell the user to restore from backup/fix the problem
               - fix could be to mark this page as bad & skip it
               Note: currently even online backup would fail...
              }

              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed reading page %d',[id]),vError);
              {$ENDIF}
              fFrame[freeFrame].id:=InvalidPageId; //at least allow others to use it
              result:=-4; //failed
            end;
          finally
            fFrame[freeFrame].page.unlatch(st);
          end; {try}
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed latching page %d to read',[id]),vError);
          {$ENDIF}
          result:=-5; //failed
        end;
      finally
        fFrame[res].unpin; //remove the reserving pin (untack) (either from above or from reaper)
      end; {try}
    end
    else
    begin
      res:=(hash+res) MOD MaxFrames;

      fFrame[res].pin;

      {It's safe to leave CS now, although not much left to hold anyone up by much - it's best to get out ASAP}
      FframeCS.Leave; //Note: it makes sense anyway since our search stability is no longer needed because we've pinned our page/frame
      csLeft:=True; //track CS early leave

      {We latch/unlatch the page here to ensure it's not still being read by
       another thread that has just pinned the same page. If it is then we queue here
       before returning to our caller.
       Note: this code could be IFDEFd if no probing goes on}
      {$IFDEF DEBUGDETAIL}
      if fFrame[res].page.block.thisPage<>id then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Page %d found in buffer but actual page pinned is %d (pincount=%d) but still waiting for new page to be read...',[id,fFrame[res].page.block.thisPage,fFrame[res].pincount]),vDebugWarning); //debug race condition: show waits for other's read (pincount=2 expected: ours + readers)
        {$ENDIF}
      end;
      {$ENDIF}
      //{$ENDIF}
      fFrame[res].page.latchUnlatch(st); //todo use something more lightweight for speed

      {$IFDEF SAFETY}
      if fFrame[res].page.block.thisPage<>id then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('!Page %d found in buffer but actual page pinned is %d (pincount=%d)',[id,fFrame[res].page.block.thisPage,fFrame[res].pincount]),vAssertion); //i.e. race condition: shouldn't happen now we have CS around buffer pinning!
        {$ENDIF}
        //Note: we abort rather than return wrong page
        result:=-6; //failed
        //todo set page:=nil?
        exit; //abort
      end;
      {$ENDIF}

      fFrame[res].flruCount:=1; //as per basic clock algorithm - ok? better than inc?
      inc(fFrame[res].fhitCount);
      //note: leave fdbThrashCount alone here
      p:=fFrame[res].page; //return the buffered page
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d found in buffer (frame %d) - pinning page (%d)',[id,res,fFrame[res].pinCount]),vdebug);
      {$ENDIF}
      {$ENDIF}
      inc(debugBufferHit);
    end;
  finally
    if not csLeft then FframeCS.Leave;
  end; {try}
end; {pinPage}

function TBufMgr.unpinPage(st:TStmt;id:PageId):integer;
{Unpins a db page.
 IN     : db        - the database
        : id        - the disk page id
 RETURN : +ve=ok, -ve=failed

 //note: for safety might be good to pass the page & then we can zeroise it!
}
const routine=':unPinPage';
var
  res,hash:integer;
  //no need: csLeft:boolean;
begin
  result:=OK;
  FframeCS.Enter; //ensure only one frame search runs at once, else slight risk that same frame gets returned (e.g. find one which gets unpinned by someone else before we pin & return it)
  try
    //find the page in the buffer
    hash:=id MOD MaxFrames;
    res:=0;
    while res<MaxFrames do
    begin
      if fFrame[(hash+res) MOD MaxFrames].id=id then
        if fFrame[(hash+res) MOD MaxFrames].fdb=Ttransaction(st.owner).db then break;       //we need this check to allow multi-db's per server & use 1 buffer area - i.e to avoid page-id clashes
      inc(res);
    end;

    if res>=MaxFrames then
    begin
      {Could be that it's being unpinned by a too-eager caller after someone else has re-used it
       (bug in caller logic, but nothing to worry about too much?)}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Page %d not found in buffer - cannot unpin',[id]),vdebugError);
      {$ENDIF}
      result:=Fail;
    end
    else
    begin
      res:=(hash+res) MOD MaxFrames;

      //todo check it's pinned?!
      {$IFDEF SAFETY}
      if fFrame[res].page.block.thisPage<>id then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('!Page %d found in buffer but actual page pinned is %d',[id,fFrame[res].page.block.thisPage]),vAssertion); //i.e. race condition: shouldn't happen now we have CS around buffer pinning!
        {$ENDIF}
        //Note: we abort rather than unpin wrong page
        result:=Fail;
        exit; //abort
      end;
      {$ENDIF}
      fFrame[res].unpin;
      {It's safe to leave CS now, although we don't because there's nothing left to hold anyone up}
      //FframeCS.Leave; //Note: it makes sense anyway since our search stability is no longer needed because we've pinned our page/frame
      //csLeft:=True; //track CS early leave
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unpinning page %d (frame %d) (%d)',[id,res,fFrame[res].pinCount]),vdebug);
      {$ENDIF}
      {$ENDIF}
      //reaper will write to disk & make available if/when necessary
    end;
  finally
    //if not csLeft then
    FframeCS.Leave;
  end; {try}
end;

function TBufMgr.Reaper(st:TStmt;id:PageId):integer;
{Reaper/Victim picker
 IN:           id - required page id - used to try to get a spare slot close by to save search time
 RETURN:       available frame id, else InvalidPageId
               Note: page is pinned
 //todo allow different Reapers - also, call from LazyWriter thread

 Assumes: caller controls critical sections to prevent disasterous things like:
            others pinning our chosen frame's old page before we flush it & return it for overwriting
            others pinning another frame for the same page we're finding an empty frame
            etc.

 Note: currently uses clock algorithm, but with jumping hands to try to keep hash values close!
 //todo: test how good this jumping hand business really is...
 Note: this has the authority to flush pages from any database, not just the requesting thread's

 Note: if anything is wrong with this routine it can cause havoc elsewhere,
       e.g. if wrong page is flushed, caller assumes he can trash the specified page which may be dirty!
}
var
  start,hash:integer;
  i:integer;
  csLeft:boolean;
  pid:PageId;
begin
    hash:=id MOD MaxFrames;
    reaperHand:=-1; //re-start hand here - note: repeat loop is done once, so 1st successful candidate should be the required page
    i:=0; //keep compiler quiet...
    start:=0; //detect full circle
    repeat
      inc(FreaperHand);
      if reaperHand>MaxFrames then reaperHand:=0; //loop

      if reaperHand=start then i:=0; //detect complete buffer ring of pinned pages

      if fFrame[(hash+reaperHand) MOD MaxFrames].flruCount>0 then dec(fFrame[(hash+reaperHand) MOD MaxFrames].FlruCount); //handles 0/1 and higher lruCounts
      if fFrame[(hash+reaperHand) MOD MaxFrames].pinCount<>0 then inc(i);
    until ( (fFrame[(hash+reaperHand) MOD MaxFrames].flruCount=0) and (fFrame[(hash+reaperHand) MOD MaxFrames].pinCount=0) ) {found a candidate}
       or ( i=MaxFrames ) {buffer ring completely pinned} ;

    if i<>MaxFrames then
    begin //pin & prepare candidate
      i:=(hash+reaperHand) MOD MaxFrames;

      //note: some of the stuff below is overkill now we keep the reaper within the FframeCS
      fFrame[i].pin;   //reserve this frame to prevent it from being allocated while we're flushing it & for caller's safety
      pid:=fFrame[i].id; //save in case we need to flush
      fFrame[i].id:=InvalidPageId; //no need since no one else can pin while we're reaping

      {We don't need to leave CS now because flush would not need for any other user to unlatch because the page
       isn't pinned so can't be latched.}

      if pid<>InvalidPageId then //was not empty
        if fFrame[i].page.dirty then //had unwritten data
        begin //Note: we try to flush this page no matter which database it belongs to //note: maybe this anyDB decision should be passed in to this routine?
          if flushFramePage(st,i)<>ok then //note: this latches & we know it will succeed because we latched above (& no pinners!)
          begin
            fFrame[i].unpin; //abort
            i:=MaxFrames; //will return 'no page found' below -  todo: we should re-try the MaxFrames range again/pause until one becomes available else crash calling query!
          end;
        end;
    end;

    if i>=MaxFrames then
      result:=InvalidPageId
    else
      result:=i;
end; {Reaper}

function TBufMgr.flushPage(st:TStmt;id:PageId;otherDB:TDB):integer;
{Flushes a db page.
 IN     : db        - the database
        : id        - the disk page id
        : otherDB   - nil = only flush the page if it belongs to caller's database (cross-check for most cases)
                      else = flush the page for the specified database (e.g. Reaper is caller)
                              Note: obviously in this case caller's db file may not be the target i.e. check OS security (but Reaper must be super-user)
 RETURN : +ve=ok,
          +1=failed to find the page, e.g. no longer in buffer (e.g. flushed & replaced by another page/db-page)
          -ve=failed

 Note: page will only be flushed if it is dirty
          - bear in mind some other db/thread may have already flushed the page you thought needed flushing!
       page will be latched during flush
}
const routine=':flushPage';
var
  res,hash:integer;
  csLeft:boolean;
begin
  result:=OK;
  csLeft:=False; //track CS early leave
  FframeCS.Enter; //ensure only one frame search runs at once, else slight risk that same frame gets returned (e.g. find one which gets unpinned by someone else before we pin & return it)
  try
    //find the page in the buffer //todo use hash routine!
    hash:=id MOD MaxFrames;
    res:=0;
    while res<MaxFrames do
    begin
      if (fFrame[(hash+res) MOD MaxFrames].id=id) then
        if ((otherDB=nil) and (fFrame[(hash+res) MOD MaxFrames].fdb=Ttransaction(st.owner).db))
        or (fFrame[(hash+res) MOD MaxFrames].fdb=otherDB) then break;
      inc(res);
    end;

    if res>=MaxFrames then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d not found in buffer - cannot flush (otherDB=%d)',[id,longint(otherDB)]),vdebugWarning);
      {$ENDIF}
      result:=+1; //Note Fail was too severe if our caller had just been beaten to it
    end
    else
    begin
      res:=(hash+res) MOD MaxFrames;

      //todo also assert not latched! and readCount=0
      if fFrame[res].page.dirty then
      begin
        {We must leave CS now, page.latch -> latcher may be waiting to flush/pin/unpin -> reaper -> deadlock unless we release
         (& especially before writePage else we hold up others unecessarily)}
        FframeCS.Leave; //Note: it makes sense anyway since our search stability is no longer needed because our page/frame is dirty & so safe for now:
                        //...if someone else does jump in (just before we latch), we can be sure they'll reponsibly deal with it
                        //...and the worst is that we'll be flushing the wrong page (currently not a problem!)
                        // - but all this is only if caller does not have the page pinned... i.e. not reaper
        csLeft:=True; //track CS early leave

        {Prevent page from being latched & modified by another thread during flush by latching it ourselves}
        result:=fFrame[res].page.latch(st);  //this waits until not latched & no active readers (although could be pinned)
        if result=ok then
        begin
          try
            //todo assert we still have the expected page! no harm if we don't(?)
            //todo pin to prevent other buffer routines from releasing/reusing & unpin once flushed...
            //todo & then safe to leave CS now? especially before writePage else we hold up all others unecessarily
            {$IFDEF SAFETY}
            if fFrame[res].page.block.thisPage<>id then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Page %d found in buffer but actual page pinned is %d',[id,fFrame[res].page.block.thisPage]),vAssertion); //i.e. race condition: could happen here but don't worry too much - see note above //todo make debugError?
              {$ENDIF}
              //note we continue anyway - our write is safe
            end;
            {$ENDIF}
            result:=fFrame[res].db.writePage(fFrame[res].page.block.thisPage{safer than id},fFrame[res].page); //resets dirty flag
            if result=ok then
            begin
              {$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Page %d flushed (actually %d)',[id,fFrame[res].page.block.thisPage]),vdebugLow);
              {$ENDIF}
              {$ENDIF}
              inc(debugBufferFlush);
            end
            else
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed flushing page %d',[id]),vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
          finally
            fFrame[res].page.Unlatch(st);
          end; {try}
        end;
      end;
    end;
  finally
    if not csLeft then FframeCS.Leave;
  end; {try}
end; {flushPage}

function TBufMgr.flushFramePage(st:TStmt;res:integer):integer;
{Flushes a db page whose frame we have.
 IN     :
        : res       - the page's frame id
 RETURN : +ve=ok,
          -ve=failed

 Note: page will only be flushed if it is dirty
          - bear in mind some other db/thread may have already flushed the page you thought needed flushing!
       page will be latched during flush
}
const routine=':flushFramePage';
begin
  result:=OK;
  //we can be safe without FframeCS here, since we never touch the frame array?
  //try
      //code copied from flushPage...
      //todo also assert not latched! and readCount=0
      if fFrame[res].page.dirty then
      begin
        {Prevent page from being latched & modified by another thread during flush by latching it ourselves}
                        //...if someone else does jump in (just before we latch), we can be sure they'll reponsibly deal with it
                        //...and the worst is that we'll be flushing the wrong page (currently not a problem!)
                        // - but all this is only if caller does not have the page pinned... i.e. not reaper
        result:=fFrame[res].page.latch(st);  //this waits until not latched & no active readers (although could be pinned)
        if result=ok then
        begin
          try
            result:=fFrame[res].db.writePage(fFrame[res].page.block.thisPage{id},fFrame[res].page); //resets dirty flag
            if result=ok then
            begin
              {$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Page %d flushed',[fFrame[res].page.block.thisPage{id}]),vdebugLow);
              {$ENDIF}
              {$ENDIF}
              inc(debugBufferFlush);
            end
            else
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed flushing page %d',[fFrame[res].page.block.thisPage{id}]),vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
          finally
            fFrame[res].page.Unlatch(st);
          end; {try}
        end;
      end;
  //finally
    //FframeCS.Leave;
  //end; {try}
end; {flushFramePage}


function TBufMgr.flushAllPages(st:TStmt):integer;
{Flushes all dirty pages for this db
 IN      :  db           the database to flush for
 RETURN  :  +ve=ok, else fail
}
var
  i:integer;
begin
  result:=ok;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where,'Flushing all dirty pages:',vdebug);
  {$ENDIF}
  //note: maybe we need to prevent changes to all pages while we do this?
  try
    for i:=0 to MaxFrames-1 do
    begin
      if fFrame[i].page.dirty and (fFrame[i].fdb=Ttransaction(st.owner).db) then
        //if flushPage(st,fFrame[i].id,nil)<ok then //Note: we carry on if page slipped through our fingers
        if flushFramePage(st,i)<>ok then
          result:=Fail;
    end;
  finally
//debug deadlock    FframeCS.Leave;
  end; {try}
end; {flushAllPages}

function TBufMgr.resetPageFrame(st:TStmt;id:PageId):integer;
{Resets a frame for a given page
 (this avoids used frames (with pin=0, dirty=0) being treated as cached after a db de-allocation has scratched it)
 IN     : id        - the disk page id
 RETURN : +ve=ok, -ve=failed

 Note: page's frame will only be reset if it is not dirty & pincount=0
}
const routine=':resetFrame';
var
  res,hash:integer;
begin
  result:=OK;
  FframeCS.Enter;
  try
    //find the page in the buffer //todo use hash routine!
    res:=0;
    hash:=id MOD MaxFrames;
    while res<MaxFrames do
    begin
      if (fFrame[(hash+res) MOD MaxFrames].id=id) then
        if fFrame[(hash+res) MOD MaxFrames].fdb=Ttransaction(st.owner).db then break;
      inc(res);
    end;

    if res>=MaxFrames then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d not found in buffer - cannot reset frame',[id]),vdebugWarning);
      {$ENDIF}
      //note: maybe this can be ignored - e.g. db.deallocatePage may call this routine just in case page is still cachec
      //      but if it's not doesn't matter
      result:=Fail;
    end
    else
    begin
      res:=(hash+res) MOD MaxFrames;

      //first assert that pincount & dirty=0!
      if fFrame[res].pinCount<>0 then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Page %d is pinned, its holding frame %d should not be reset - aborting',[fFrame[res].id,res]),vAssertion); //note: expected since caller does not pin & page may have been swapped
        {$ENDIF}
        result:=Fail;
        exit; //abort to avoid corruption to others
      end;
      if fFrame[res].page.dirty then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Page %d is dirty, its holding frame %d should not be reset - aborting',[fFrame[res].id,res]),vAssertion);  //note: expected since caller does not pin & page may have been swapped
        {$ENDIF}
        result:=Fail;
        exit; //abort to avoid corruption to others
      end;
      //todo also check page is not latched!
      {$IFDEF SAFETY}
      if fFrame[res].page.block.thisPage<>id then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('!Page %d found in buffer but actual page pinned is %d',[id,fFrame[res].page.block.thisPage]),vAssertion);
        {$ENDIF}
        exit; //abort to avoid corruption to others
      end;
      {$ENDIF}
      fFrame[res].id:=InvalidPageId;
    end;
  finally
    FframeCS.Leave;
  end; {try}
end; {resetPageFrame}

function TBufMgr.resetAllFrames(db:TDB):integer;
{Resets all frames used by this db
 (this avoids used frames (with pin=0, dirty=0) being treated as cached after a db close & reopen)
 IN      :  db           the database to reset for
 RETURN  :  +ve=ok, else fail
}
const routine=':resetAllFrames';
var
  i:integer;
begin
  result:=ok;
  FframeCS.Enter;
  try
    {$IFDEF DEBUG_LOG}
    log.add(who,where,'Resetting all buffer frames:',vdebug);
    {$ENDIF}
    for i:=0 to MaxFrames-1 do
    begin
      if fFrame[i].fdb=db then
      begin
        //first assert that pincount & dirty=0!
        if fFrame[i].pinCount<>0 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Page %d is pinned (pincount=%d), its holding frame %d should not be reset but will be',[fFrame[i].id,fFrame[i].pincount,i]),vAssertion);
          {$ENDIF}
          result:=Fail;
        end;
        if fFrame[i].page.dirty then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Page %d is dirty, its holding frame %d should not be reset but will be',[fFrame[i].id,i]),vAssertion);
          {$ENDIF}
          result:=Fail;
        end;
        //todo also check page is not latched
        fFrame[i].id:=InvalidPageId;
        //todo set dirty=false & pincount=0 etc. as well here!
      end;
    end;
  finally
    FframeCS.Leave;
  end; {try}
end; {resetAllFrames}


{Debug}
procedure TBufMgr.Status;
var
  i:integer;
begin
   //todo protect with FframeCS?
  {$IFDEF DEBUG_LOG}
  log.add(who,where,'  Buffer manager status: ',vdebug);
  {$ENDIF}
  for i:=0 to MaxFrames-1 do  //todo only display up to highest used frame
  begin
    fFrame[i].Status(i);
  end;
  {$IFDEF DEBUG_LOG}
  log.add(who,where,format('  Buffer reaper hand           : %d',[reaperHand]),vdebug);
  log.add(who,where,format('  Buffer manager misses        : %d',[debugBufferMiss]),vdebug);
  log.add(who,where,format('  Buffer manager hits          : %d',[debugBufferHit]),vdebug);
  {$ENDIF}
  if debugBufferMiss<>0 then
    {$IFDEF DEBUG_LOG}
    log.add(who,where,format('  Buffer manager hit-miss ratio: %f:%d',[(debugBufferHit/debugBufferMiss),1]),vdebug);
    {$ELSE}
    ;
    {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(who,where,format('  Buffer manager flushes       : %d',[debugBufferFlush]),vdebug);
  {$ENDIF}
end;


end.

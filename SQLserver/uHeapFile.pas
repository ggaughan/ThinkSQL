unit uHeapFile;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{DB-file management routines
 Implements AddRecord, ReadRecord and sequential scan for a heap file
 (using a flexible slotted page structure)
 All routines are version-aware
}

//{$DEFINE DEBUGDETAIL}      //debug detail
//{$DEFINE DEBUGDETAIL2}       //debug detail, e.g. update
//{$DEFINE DEBUGDETAIL3}       //debug dump page memory pointer data

{$DEFINE SAFETY}  //extra sense checks, e.g. freespace>=0

interface

uses uFile, uPage, uGlobalDef, uGlobal,
     uStmt, IdTCPConnection{debug only};

type
  //note similarity between TSlot and Trec!!!  -same except Trec has a swizzled pointer to memory
                                                    //maybe could use Tslot.start(longint) as memory pointer? saving what?
  {Within a page - record slot header/pointer}
  TSlot=record
    rType:recType;        //marker for slot/record type (e.g. deleted, free)
                          //or rtHeader
    start:RecId;          //pointer to start of record within page block data
                          //for rtHeader = freeStart
    len:RecSize;          //size of record
                          //for rtHeader = slotCount
                          //Note: we can have slot.len=0 (e.g. for forwarding RID pointers after update)
    Wt:StampId;           //write timestamp
    PrevRID:Trid;         //previous delta
  end; {TSlot}
  {Slot[0]=slot header, 1..N = slots   slot[0].len=N i.e. count
                                       slot[0].start=free space pointer
                                       note: case for swapping - types are better other way round?!
  }

  THeapFile=class(TDBFile)         //database heapfile
  private
  public
    function createFile(st:TStmt;const fname:string):integer; override;
    function deleteFile(st:TStmt):integer; override;
    function openFile(st:TStmt;const filename:string;startPage:PageId):integer; override;
    function freeSpace(st:TStmt;page:TPage):integer; override;
    function contiguousFreeSpace(st:TStmt;page:TPage):integer;
    function GetNextUsedSlot(st:TStmt;page:TPage;var sid:SlotId):integer;
    function ReorgPage(st:TStmt;page:TPage):integer;

    function GetScanStart(st:TStmt;var rid:Trid):integer; override;
    function GetScanNext(st:TStmt;var rid:Trid;var noMore:boolean):integer; override;
    function GetScanStop(st:TStmt):integer; override;

    function ReadRecord(st:TStmt;page:TPage;sid:SlotId;r:Trec):integer; override;

    function AddRecord(st:TStmt;r:Trec;var rid:Trid):integer; override;
    function UpdateRecord(st:TStmt;r:Trec;rid:Trid;checkTranId:boolean):integer;
    function UpdateRecordHeader(st:TStmt;r:Trec;rid:Trid):integer;
    function UpdateRecordHeaderType(st:TStmt;rt:recType;rid:Trid):integer;

    function debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer; override;
  end; {THeapFile}

const
  slotSize=1{=sizeof(recType)}+(1)+ sizeof(recId)+sizeof(recSize)+(2)+       //1(+3) +2+2+   4+6(+2) (compiler-padding = 5 wasted bytes)
           sizeof(StampId)+sizeof(Trid); //note recType & Trid are not packed (5 bytes unused)

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uServer, uTransaction
  ,uEvsHelpers;

const
  where='uHeapFile';

  {Retry attempts}
  RETRY_ADDRECORD=50; //ok? more/less/infinite?

function THeapFile.createFile(st:TStmt;const fname:string):integer;
{Creates a heap file in the specified database
 IN       : db          the database
          : fname       the new filename
 RETURN   : +ve=ok, else fail
}
const routine=':createFile';
begin
  result:=inherited CreateFile(st,fname);
  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Heap-file %s created',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {createFile}

function THeapFile.deleteFile(st:TStmt):integer;
{Deletes a heap file from the specified database
 IN       : db          the database
 RETURN   : +ve=ok, else fail

 Assumes:
   file has been opened

   higher level dependencies have been sorted out,
     e.g. foreign key index pointers to this file will become invalid

 Obviously you should not try to use the file after this routine!
}
const routine=':deleteFile';
var
  lastPid:PageId;
  lastPagePrev:PageId;
  lastSlot:DirSlotId;
  pid:PageId;
  page:Tpage;
  lastDirPid,prevLastSlotDirPid:PageId;
  space:word;
  pidTest:PageId;
begin
  {Use the file directory to find the last page in the data chain
   Delete the data pages backwards, cross-checking them against the file page directory deallocations
   Then delete the file (including the startPage)
  }
  result:=Fail;

  //lastPage=invalid; lastPage.next=invalid; lastPage.prev=invalid;
  lastPid:=InvalidPageId;
  lastPagePrev:=InvalidPageId;
  //slot=lastSlot
  //page=slotPid
  if dirCount(st,lastSlot,lastDirPid,prevLastSlotDirPid,True{retry to get accurate figure})<>ok then exit; //abort
  if lastSlot>0 then
  begin //we have data pages
    lastSlot:=lastSlot-1;
    if dirPage(st,InvalidPageId,lastSlot,pid,space)<>ok then exit; //abort
    page:=nil;
    //while page<>invalid do
    while pid<>InvalidPageId do
    begin
    //  read page
      with (Ttransaction(st.owner).db.owner as TDBserver) do
      begin
        if lastPid<>InvalidPageId then
        begin
          {Now we can deallocate this page}
          if Ttransaction(st.owner).db.deAllocatePage(st,lastPid)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed de-allocating file page',vError);
            {$ENDIF}
            exit;
          end;
        end;

        if buffer.pinPage(st,pid,page)<>ok then exit;
        try
      //  if page.type<>data then assert 'unexpected page type!'
          if page.block.pageType<>ptData then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('File page is not the expected type (%d)',[ord(page.block.pageType)]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
      //  if lastpage<>invalid and lastPage.prev<>page then assert 'backward chain corrupt: what the hell is lastpage.prev?'
          if page.block.nextPage<>lastPid then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('File page has a forward pointer of %d - was expecting %d',[page.block.nextPage,lastPid]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
      //  if page.next<>lastPage then assert 'forward chain corrupt: what the hell is page.next?'
          if (lastPid<>InvalidPageId) and (lastPagePrev<>pid) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Last file page had a backward pointer of %d - was expecting %d',[lastPagePrev,pid]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;

      //  lastPage=page; lastPage.next=page.next; lastPage.prev=page.prev;
          lastPid:=pid; lastPagePrev:=page.block.prevPage;
      //  //deallocate page: deferred until after unpin

      //  //DirPageSet(slot,invalid)
          if dirPageRemove(st,pid,lastSlot)<>ok then exit; //abort
      //  slot=slot-1
          lastSlot:=lastSlot-1;

      //  page:=page.prev
          pid:=lastPagePrev;
          if (lastSlot=-1) and (pid=InvalidPageId) then
            pidTest:=pid //noMore
          else
            if dirPage(st,InvalidPageId,lastSlot,pidTest,space)<>ok then exit; //abort

          {Check that the previous page in the chain is the one expected in the previous directory slot
           Note: in future this may not hold true - may insert into the page chain at random...
           Currently though, these two sequences should match!}
          if pidTest<>pid then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Previous page in chain (%d) is not the previous one in directory slot %d (%d)',[pid,lastSlot,pidTest]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
        finally
          buffer.unpinPage(st,page.block.thisPage);
        end; {try}
      end; {with}
    //end while
    end;

    {Delete the last remaining data page}
    if lastPid<>InvalidPageId then
    begin
      {Now we can deallocate this page}
      if Ttransaction(st.owner).db.deAllocatePage(st,lastPid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed de-allocating file page',vError);
        {$ENDIF}
        exit;
      end;
    end;
  end;
  //else file was empty

  result:=inherited DeleteFile(st);
  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Heap-file %s deleted',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {deleteFile}

function THeapFile.openFile(st:TStmt;const filename:string;startPage:PageId):integer;
{Opens a heap file in the specified database
 i.e. goes to the file's page directory header page
 IN       : db          the database
          : filename    the existing filename
          : startPage   the start page for this file (found by caller from catalog)
 RETURN   : +ve=ok, else fail

 Side effects:
   sets fStartPage for this file
   sets fname for this file

 Assumes:
   filename and startpage are valid
}
const routine=':openFile';
begin
  result:=inherited openFile(st,filename,startPage);

  if result=ok then
  begin
    //goto first record?
  end;
end; {openFile}


function THeapFile.GetNextUsedSlot(st:TStmt;page:TPage;var sid:SlotId):integer;
{Finds the next valid record slot (record header) in this page

 IN    : page         the page
       : sid          the current slot to look beyond
 OUT   : sid          the next used slot id, InvalidSlotId if no more
 RETURN: +ve=ok, else fail

 Assumes:
   page is pinned/locked as appropriate
   current sid is a valid slot

 Note:
   this could return a slot that is not visible by the current transaction
     e.g. the current transaction is after the earliest valid record portion
      - maybe the record was created by one # after this transaction started
        - read will not find an entry before/= this
      - or maybe the record was deleted by one # before this transaction started
        - read realises delete # is after/= this
}
const routine=':GetNextUsedSlot';
var
  sHeader, slot:TSlot;
begin
  result:=ok;
  {Read page slot header}
  page.AsBlock(st,0,sizeof(sHeader),@sHeader);
  if sHeader.rType<>rtHeader then
  begin //avoid whizzing through invalid slots if our slot header len is unsafe 29/01/03 (not sure of cause, but could be old index pointer)
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Page %d has no slot header',[page.block.thispage]),vAssertion);
    {$ENDIF}
    result:=Fail;
    sid:=InvalidSlotId;  //=>no more used slots on this page (for those callers who don't check the result!)
    exit; //abort
  end;
  {Get next used slot}
  repeat
    inc(sid);
    if sid<=sHeader.len{=slotCount} then
    begin
      page.AsBlock(st,sid*sizeof(slot),sizeof(slot),@slot);
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('%d:%d slot previewed as Wt=%d:%d rType=%d prev.pid=%d prev.sid=%d len=%d',[page.block.thispage,sid,slot.wt.tranId,slot.wt.stmtId,ord(slot.rtype),slot.prevRID.pid,slot.prevRID.sid,slot.len]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if slot.rType in [rtRecord,rtDeletedRecord] then //record header
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record slot found on page %d at %d',[page.block.thispage,sid]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        break; //found a used slot
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record slot skipped on page %d at %d: not a record type (%d)',[page.block.thispage,sid,ord(slot.rtype)]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
    end;
  until sid>sHeader.len{=slotCount}; //past last slot
  if sid>sHeader.len{=slotCount} then
  begin
    sid:=InvalidSlotId;  //no more used slots on this page
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('No more valid record slots on page %d',[page.block.thispage]),vDebug);
    {$ENDIF}
    {$ENDIF}
  end;
end; {GetNextUsedSlot}

function THeapFile.freeSpace(st:TStmt;page:TPage):integer;
{Returns amount of free record space in the specified page
 IN      : page    the page to examine
 RETURN  : the amount of free space

 Note: this is not necessarily contiguous free space

 //may want to include rtEmpty slots at end of slot array, since
 // reorgPage would free these - might make a crucial difference?

 Assumes:
   we have the page pinned
   (& latched if we are going to make use of the result...)
}
const routine=':freeSpace';
var
  sHeader,slot:TSlot;
  parentFreeSpace:integer;
  i:SlotId;
begin
  parentFreeSpace:=inherited freeSpace(st,page); //starting point
  {Read page header}
  page.AsBlock(st,0,sizeof(sHeader),@sHeader);

  result:=parentFreeSpace - sizeof(sHeader)-(SlotSize*sHeader.len{=slotCount});
  for i:=1 to sHeader.len do
  begin
    page.AsBlock(st,i*sizeof(slot),sizeof(slot),@slot);
    result:=result - slot.len;
  end;

  {$IFDEF SAFETY}
  //return 0 to avoid infinite retry during addRecord/setDirPage
  if result<0 then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Error calculating freespace on page %d (type=%d) (%d) - returning 0 to be safe',[page.block.thispage,page.block.pagetype,result]),vAssertion);
    {$ENDIF}
    result:=0;
  end;
  {$ENDIF}
end; {FreeSpace}

function THeapFile.contiguousFreeSpace(st:TStmt;page:TPage):integer;
{Returns amount of contiguous free record space in the specified page
 IN      : page    the page to examine
 RETURN  : the amount of free space

 Note: for 'TRUE' usedSpace use freeSpace()

 Assumes:
   we have the page pinned & latched
}
const routine=':contiguousFreeSpace';
var
  sHeader:TSlot;
  parentFreeSpace:integer;
begin
  parentFreeSpace:=inherited freeSpace(st,page); //starting point
  {Read page header}
  page.AsBlock(st,0,sizeof(sHeader),@sHeader);
  result:=parentFreeSpace - sizeof(sHeader)-(SlotSize*sHeader.len{=slotCount})
         - (BlockSize -sHeader.Start{=freeStart}-1); //=block-header-slotheaders-usedSpace
end; {ContiguousFreeSpace}

function THeapFile.ReorgPage(st:TStmt;page:TPage):integer;
{Reorganise the (latched) page to give a contiguous chuck of free space

 IN      : page    the page to reorganise
 RETURN  : +ve=ok, else fail

 Assumes:
   we have the page latched by the caller

 Note:
   guarantees to leave slot-ids intact
   modifies slot-offsets though (so caller may need to re-read them)

 todo: maybe return the amount of free space: it might be quicker to call
         if reorgPage>=needed then ...
       than
         if contiguousFreespace<needed then
           if freespace>=needed then
             reorgPage...
       ? i.e. is freespace.duration ~ reorgPage.duration...

 Note: uses same page pointer logic as adding records
}
const routine=':reorgPage';
var
  sHeader,slot:TSlot;
  i, nextCandidate:SlotId;
  okToTruncate:boolean;
  lastTarget,nextCandidateStart:integer;


  //note: debug only:
  oldFree,oldFreeContiguous:integer;
  oldSlotCount:SlotId;
begin
  result:=Fail;

//  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'starting re-org',vDebugLow);
  {$ENDIF}
//  {$ENDIF}

  //todo assert page is latched (and so pinned)
  {Read page header}
  page.AsBlock(st,0,sizeof(sHeader),@sHeader);

  //note: debug only - time consuming! remove=speed!
  oldFree:=freeSpace(st,page);
  oldFreeContiguous:=contiguousFreeSpace(st,page);
  oldSlotCount:=sHeader.len;
  //

  (*todo:
    {Read all (remaining) slot start ptrs}
    {Sort them in reverse order - ones nearest end-of-page are first}

  for now, we will just repeatedly scan the array and deal with the highest non-moved one at a time
  to save sort memory allocation/space (& I can't be bothered to write a quicksort at the moment!)
  *)

  {In reverse order, shift each record block (& start ptr) to butt against last one/end-of-page}
  lastTarget:=blocksize-1;            //original freespace pointer on a blank page

  repeat
    {find the next candidate for shifting - i.e. the one nearest the lasttarget}
    nextCandidate:=0;
    nextCandidateStart:=0;
    for i:=1 to sHeader.len do //todo replace this brute force scan with a sorted array
    begin
      page.AsBlock(st,i*sizeof(slot),sizeof(slot),@slot);
      if (slot.start<lastTarget) and (slot.start>nextCandidateStart) then
      begin //not already dealt with & one already nearest end of page
        nextCandidate:=i;
        nextCandidateStart:=slot.start;
      end;
    end;
    if nextCandidate<>0 then
    begin //shift the block (if no reorg needed, this might be in the right place already)
      page.AsBlock(st,nextCandidate*sizeof(slot),sizeof(slot),@slot);
      if (slot.start+slot.len)-1<lastTarget then
      begin //there is a gap, need to move this block to fill it
        //todo put this next routine in the page class...i.e. hide the block.data!
        {Fix 20/07/01: 0 length slots (forwarding RIDs) should not attempt to use lastTarget-0+1, else range error!}
        //todo: again, if lastTarget still=blocksize-1, then lose this slot altogether!
        if slot.len>0 then move(page.block.data[slot.start],page.block.data[lastTarget-slot.len+1],slot.len);
        {Update the slot pointer to the new block offset}
        if slot.len>0 then
          slot.start:=lastTarget-slot.len+1
        else
          slot.start:=lastTarget; //i.e. start of last data. Anywhere would do since no bytes will be read from here
        {Update the page slot data}
        page.SetBlock(st,nextCandidate*sizeof(slot),sizeof(slot),@slot);
      end; //else already butted to end (unless > in which case screwed... todo assert/check?)
      {Update the lastTarget, i.e. the next free space}
      lastTarget:=lastTarget-slot.len;
    end;
  until nextCandidate=0; //no more to shift

  //todo: maybe fill (after-slots/old-freeSpace)..lastTarget with 0's?  //security?

  {Re-set freespace pointer}
  sHeader.Start{=freestart}:=lastTarget; //(work inwards)

  {Rewrite (possibly) updated header}      //todo slight speed: don't unless have to...only when was already perfectly re-orged
  page.SetBlock(st,0,sizeof(sHeader),@sHeader);

  page.dirty:=True;

  //  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Re-orged page %d from %d free space (%d contiguous, %d slots) to %d free space (%d contiguous, %d slots)',
                               [page.block.thisPage,oldFree,oldFreeContiguous,oldSlotCount,freeSpace(st,page),contiguousFreeSpace(st,page),sHeader.len]),vDebugMedium);
  {$ENDIF}
  //  {$ENDIF}
  result:=ok;
end; {ReorgPage}


function THeapFile.GetScanStart(st:TStmt;var rid:Trid):integer;
{Get start point for heap file scan
 OUT   : rid         1 before the 1st rid
}
const routine=':GetScanStart';
begin
  result:=Fail;
  if inherited GetScanStart(st,rid)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'ScanStart failed',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
  end
  else
  begin
    result:=ok;
    //start scan does nothing else in heapFile case!
    // - we're on the 1st data page & scanNext will move to the first data record
  end;
  rid:=fCurrentRid;
end; {GetScanStart}

function THeapFile.GetScanNext(st:TStmt;var rid:Trid;var noMore:boolean):integer;
{Reads a pointer to the next record in sequence
 OUT       : rid        the rid of the next record
           : noMore     True if no more records, else False
 RESULT    : +ve=ok, else fail
}
const routine=':GetScanNext';
var
  nextPid:PageId;
begin
  result:=ok;
  noMore:=False;
  inherited GetScanNext(st,rid,NoMore);
  if not noMore then  //we have some data in the scan
  begin
    {First find the correct page}
    {Move to next slot}
    GetNextUsedSlot(st,fCurrentPage,fCurrentRid.sid);
    if fCurrentRid.sid=InvalidSlotId then
    begin  //need to try and read next page
      {Update this file's current RID pointer}
      with (Ttransaction(st.owner).db.owner as TDBserver) do
      begin
        repeat
          if fCurrentpage.block.nextPage<>InvalidPageId then
          begin
            nextPid:=fCurrentpage.block.nextPage;
            buffer.unpinPage(st,fCurrentrid.pid);
            {Goto next page
             Note: HeapFile has no order & follows page pointers
                   it could also getNext DirPageSlot
                   in fact, these two orderings should be the same!? prove?
            }
            if buffer.pinPage(st,nextPid,fCurrentpage)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format(' %d:next failed',[nextPid]),vError);
              {$ENDIF}
              result:=Fail;
              exit; //abort
            end;
            fCurrentRid.pid:=fCurrentpage.block.thisPage;  //the new page
            fCurrentRid.sid:=0; //todo make constant= invalidSlotId or BeforeAllSlotIds
            GetNextUsedSlot(st,fCurrentpage,fCurrentRid.sid);
          end
        until (fCurrentRid.sid<>InvalidSlotId) or (fCurrentpage.block.nextPage=InvalidPageId);
      end; {with}
      if fCurrentRid.sid=InvalidSlotId then
        noMore:=True; //eof //todo set r.len:=0?
    end;
  end;
  rid:=fCurrentRID;
end; {GetScanNext}

function THeapFile.GetScanStop(st:TStmt):integer;
{Finalise heap file scan
}
const routine=':GetScanStop';
begin
  result:=Fail;
  if inherited GetScanStop(st)<>ok then
  begin
    {We've already reported the error in the parent, just fail silently}
  end
  else
  begin
    result:=ok;
    //stop scan does nothing else in heapFile case!
  end;
end; {GetScanStop}

function THeapFile.ReadRecord(st:TStmt;page:TPage;sid:SlotId;r:Trec):integer;
{Reads a record for a specified slot by pointing r.dataPtr to the record in the page
 IN    : page         the page
       : sid          the slot id
 OUT   : r            the record
                          len
                          dataPtr
                          Wt
                          PrevRID
 RETURN: +ve=ok, else fail

 Assumes:
   the page is pinned

 Note: copied in TTuple.copyBlobData
}
const routine=':ReadRecord';
var
  sHeader, slot:TSlot;
begin
  result:=ok;
  //todo Don't read header - assume sid is valid! i.e. got from GetNextUsedSlot etc.
  {Read page header}
  page.AsBlock(st,0,sizeof(sHeader),@sHeader);
  if sHeader.rType<>rtHeader then
  begin //avoid whizzing through invalid slots if our slot header len is unsafe 29/01/03 (not sure of cause, but could be old index pointer)
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SID %d refers to page %d which has no slot header',[sid,page.block.thispage]),vAssertion);
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;
  if sid>sHeader.len{=slotCount} then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SID %d is beyond %d=slots in this page',[sid,sHeader.len{=slotCount}]),vAssertion);
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;
  if sid<=0 then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SID %d is invalid (0=header slot)',[sid]),vAssertion);
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;

  {Read slot entry}
  page.AsBlock(st,sid*sizeof(slot),sizeof(slot),@slot);
  {Pass back slot entry in the record}
  r.rType:=slot.rType;
  r.Wt:=slot.Wt;
  r.PrevRID:=slot.PrevRID;
  {Point record data}
  r.len:=slot.len;
  r.dataPtr:=@page.block.data[slot.start];    //i.e. slot points to disk, rec points to memory
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%d:%d record read as Wt=%d:%d rType=%d prev.pid=%d prev.sid=%d len=%d',[page.block.thispage,sid,r.wt.tranId,r.wt.stmtId,ord(r.rtype),r.prevRID.pid,r.prevRID.sid,r.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {ReadRecord}

function THeapFile.AddRecord(st:TStmt;r:Trec;var rid:Trid):integer;
{Add a new record to the file
 IN    : st           the statement
       : r            the record
                      Note: assumes set properly, i.e.
                            Wt, prevRID, len, rType
 OUT   : rid          the rid used
 RETURN: +ve=ok, else fail

 Note: uses same page pointer logic as reorgPage
}
const routine=':AddRecord';
var
  spaceNeeded:word;
  spaceLeft:word;
  page:Tpage;
  prevPage:TPage;
  pid:PageId;
  prevPid:PageId;
  dirPid:PageId; //only used if page & directory freespace disagree
  dirPageId,prevDirSlotPageId:PageId;
  dirSlot:DirSlotId;
  sid:SlotId;

  sHeader, slot:TSlot;
  doretry:boolean;
  retry:integer;
begin
  result:=Fail;

  if slotSize<>sizeof(slot) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SlotSize[%d]<>sizeof(slot)[%d]',[slotSize,sizeof(slot)]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;

  {Note: we always look for rec.len + sizeof(slot), even though we
   may re-use an existing empty slot}
  spaceNeeded:=r.len+sizeof(slot);

  if spaceNeeded>(BlockSize-sizeof(sHeader){1st header slot is mandatory}) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Cannot add a record larger than %d',[BlockSize-sizeof(sHeader)]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;

 sid:=65535; //maxWord to keep compiler quiet
 retry:=-1; //i.e. don't retry at all, unless certain circumstance
 while (result<>ok) and ((retry>0) or (retry=-1)) do //outer loop to retry in case we find our page with space no longer has enough when we've latched it
 begin
  if retry>0 then
  begin
    dec(retry); //i.e. once retry fired, no more to avoid infinite loop
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Retrying (%d more tries to go)',[retry]),vDebugMedium);
    {$ENDIF}
  end;

  {Find and pin a page with enough space, else allocate a new page}
  repeat
    doretry:=false; //retry escape from this repeat loop to flag continue of retry loop (while retaining any pid)

    if DirPageFind(st,spaceNeeded,pid,dirPageId,dirSlot)<>ok then
    begin
      result:=Fail;
      if retry=-1 then retry:=1;
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
      {$ENDIF}
      //exit;
      doretry:=true; //signal this loop was broken out of to jump to retry
      break; //abort/retry
    end;
    //note: maybe the following check should be done by the DirPageFind routine?
    //      but it's not really the directory's responsibility, even though it might be neater
    //      if it were if we call it from many places. Currently we don't call it from anywhere else(?)
    //      so we take responsibility here...

    //      We can't implicitly trust the directory in case we've had a crash
    //      - we don't flush the directory pages after every single modification (would be overkill)
    //        and so because of this trade-off we must double check here...

    if pid=InvalidPageId then
    begin
      {No page with room was found, so we allocate and add a new one}
      if Ttransaction(st.owner).db.allocatePage(st,pid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed allocating new page',vError);
        {$ENDIF}
        if retry=-1 then retry:=1;
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
        {$ENDIF}
        //exit;
        doretry:=true; //signal this loop was broken out of to jump to retry
        break; //abort/retry
      end;
      {Initialise this new page as a heapfile page}
      with (Ttransaction(st.owner).db.owner as TDBserver) do
      begin
        if buffer.pinPage(st,pid,page)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading new page to initialise it, %d',[pid]),vError);
          {$ENDIF}
          if retry=-1 then retry:=1;
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
          {$ENDIF}
          //exit;
          doretry:=true; //signal this loop was broken out of to jump to retry
          break; //abort/retry
        end;
        try
          {Initialise blank data page}
          page.block.pageType:=ptData;
          sHeader.rtype:=rtHeader;
          sHeader.Start{=freeStart}:=blockSize-1; //last byte (work inwards)
          sHeader.len{=slotCount}:=0;
          sHeader.Wt:=InvalidStampId;          //unused
          sHeader.PrevRID.pid:=InvalidPageId;  //unused
          sHeader.PrevRID.sid:=InvalidSlotId;  //unused
          page.latch(st); //note: just to keep assertions quiet - no real need since page is local
          try
            {Write blank header}
            page.SetBlock(st,0,sizeof(sHeader),@sHeader);

            {Ok, add the page to the file's directory
             Note: once we've added the page here, we must double link to the previous dirSlot page
                   to ensure the file can be scanned!
                   So the dirPageAdd routine also passes back the previous slots dir page, which
                   allows us to quickly find the previous page from the directory without scanning the directory chain
                   Also, we keep the new page latched until we've linked it back to the previous one
                   to avoid others adding to it before it's ready
            }
            if DirPageAdd(st,pid,freespace(st,page),prevDirSlotPageId,dirPageId,dirSlot)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'Failed allocating new page to page dir (will retry = throw away allocated page)',vError);
              {$ENDIF}
              if retry=-1 then retry:=1;
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
              {$ENDIF}
              //exit;
              doretry:=true; //signal this loop was broken out of to jump to retry
              break; //abort/retry
            end;
            {Link to previous page}
            {note:
              shouldn't we flush these pages afer such links (prev/next) have been made
              else a newly linked page might be 'lost' or an existing page might point
              to a 'missing' next page & so break the table!
              Especially if another tran adds rows to the new page or modifies the old page & commits!
              - another reason to pre-allocate & (link!) blocks of pages
            }
            if dirSlot=0 then
              prevPid:=InvalidPageId  //this is the very first data page
            else
            begin
              if DirPage(st,prevDirSlotPageId,dirSlot-1,prevPid,spaceLeft)<>ok then    //Note: prevPid might be InvalidPageId...
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed locating previous page, page slot %d',[dirSlot-1]),vAssertion);
                {$ENDIF}
                //note: problem! We've allocated the dirslot in the directory and so must
                //              link the previous slot's page to retain the file chain...
                //     how to recover before retrying another page?
                //      - maybe dirPageRemove, but could leave hole...
                //      - maybe loop dirslot-2 downto 0 until we find a previous page?
                //      - maybe fill dirslot-1 downto last empty slot with chain of linked empty pages?
                //     the only way this could fail is if:
                //       the previous slot had been removed - shoudln't happen
                //       the previous slot was not filled consecutively - shouldn't happen (but did to cause this)
                //     so for now we'll concentrate on prevention... and won't retry here to prevent orphaned rows
                exit; //abort
              end;
              if buffer.pinPage(st,prevpid,prevpage)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed reading new page''s previous page, %d',[prevpid]),vError);
                {$ENDIF}
                //this is serious since the chain is now broken, so abort to prevent orphans
                exit; //abort
              end;
              if prevPage.latch(st)<>ok then
                exit; //abort - todo make more resiliant?
              try
                if prevPage.block.nextPage<>InvalidPageId then
                begin //our previous page is already linked! Problem...
                  //this is serious since the chain is now broken, so abort to prevent orphans
                  // - maybe better to re-chain the previous page?
                  // - but more likely that we've read the wrong dirPage slot? (at least while we're debugging)
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Previous page (%d) is already linked to page %d, so we cannot link it to our new page %d',[prevPage.block.thisPage,prevPage.block.nextPage,pid]),vAssertion); //vError?
                  {$ENDIF}
                  exit; //abort
                end;

                prevPage.block.nextPage:=pid; //link forwards
                prevPage.dirty:=True;
              finally
                prevPage.Unlatch(st);
                buffer.unpinPage(st,prevpid);
              end; {try}
            end;
            page.block.prevPage:=prevPid;  //link backwards

            page.dirty:=True;
          finally
            page.unlatch(st);
          end; {try}
        finally
          buffer.unpinPage(st,pid);
        end; {try}
      end; {with}
    end;
  until pid<>InvalidPageId;

  if doretry then continue; //must have broken out in error so jump to retry

  {We have the page (pid) and its directory slot (dirSlot),
   now pin it, add the record to it, and update the directory entry}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading page to add record to, %d',[pid]),vError);
      {$ENDIF}
      if retry=-1 then retry:=1;
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
      {$ENDIF}
      //exit;
      continue; //abort/retry
    end;
    try
      if page.latch(st)=ok then
      begin
        try
          //todo: maybe the following 2 checks should be done by the DirPageFind routine?
          //      but it's not really the directory's responsibility, even though it might be neater
          //      if it were if we call it from many places. Currently we don't call it from anywhere else(?)
          //      so we take responsibility here...

          {Double check the space is still roughly in sync. with the page dir (someone else might have just allocated some space)
           Note: we need to do this here until we leave the chosen page latched above! Else risk it's changed...}
          if spaceNeeded>FreeSpace(st,page) then //assertion failed //todo remove this assertion - takes time! just use next
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('No room in page %d [%d free] for record of length %d (although enough space was reported by the directory)',[page.block.thispage,freeSpace(st,page),r.len,copy(r.dataPtr^,0,r.len)]),vDebugWarning);
            {$ENDIF}

            {We fix this corruption here by updating the directory entry with the actual freeSpace
             so our next retry doesn't pick it again!
            }
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('FreeSpace reported by the found page (%d) is not actually the same as that in the directory - probably as a result of a crash or concurrent insertions - fixing now & re-finding to avoid future problems...',[freespace(st,page)]),vDebugLow);
              {$ENDIF}
                begin //ok fix
                  //todo make this fast by passing the dirPage!
                  if DirPageSet(st,dirPageId,dirSlot,{dir}Pid,freespace(st,page),False)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed fixing directory slot (%d on page %d) - unable to change freespace from %d to %d for page %d, continuing - will allocate a new page...',[dirSlot,dirPageId,spaceLeft,freespace(st,page),page.block.thisPage]),vAssertion);
                    {$ENDIF}
                  end
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Fixed directory slot (%d on page %d) - freespace changed to %d for page %d',[dirSlot,dirPageId,freespace(st,page),page.block.thisPage]),vFix);
                    {$ELSE}
                    ;
                    {$ENDIF}
                end;
              //end;
            end;

            if retry=-1 then retry:=RETRY_ADDRECORD;
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
            {$ENDIF}
            //exit;
            continue; //abort/retry
            //Note: the abort here is disastrous: we lose the data! But better than trashing the slot headers!
            // - should really re-try, or at least get caller to re-try...
          end;
          //todo: maybe the following check should be done by the DirPageFind routine?
          if spaceNeeded>contiguousFreeSpace(st,page) then //assertion failed
          begin
            {note: this gets called too often after updates - lots of tiny holes can be left that add up to enough space
             for the next record, but it's like rolling out pastry again & again - it's not worth it after a few times.
             We should do some of the following:
                only get pages if they have contiguous space
                     - maybe the dir page should only record contiguous space? - difficult
                     - or we should loop (reading pages = costly) until we find one that has its space contiguous
                only reOrg a page
                     - a few times
                     - if there's a fair chunk of non-contiguous space (maybe to a ratio of number of records?)
             otherwise we thrash the page (only in memory though) and shuffle chunks around to make space
             - at least we stick to the single page read & maybe never write/re-read it if we're in a hotspot..
             do some tests - I think the page-probing loop sounds too expensive...
             but we've got to have a (low?) threshold where we don't bother to reorg
             - also what about leaving a percentage of space in pages for future in-place updates
             - if we don't we'll end up with lots of RID forwarding which is very bad (multi-page reads for every 1)

             in both cases (so far) that we call reorg, the logic should change so we
               repeat
                 get a candidate page
                 check for space
                 reorg if necessary & practical, to make room
               until we have room
            }

            //again, use a server 'womble?' setting to determine whether we re-org or defer here
            // - if we defer, we should do this check in the find-page loop above...
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found enough (non-contiguous) space in page %d for new record length of %d - will now re-org page...',[page.block.thispage,r.len]),vDebugLow);
            {$ENDIF}
            result:=reorgPage(st,page); //REORG
            if result<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'Failed reorganising page',vError);
              {$ENDIF}
              if retry=-1 then retry:=RETRY_ADDRECORD;
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
              {$ENDIF}
              //exit;
              continue; //abort/retry
            end;
            {We don't need to re-read the page details, since we haven't read them yet}
            // - we currently assume that because freeSpace>required then reorg will give enough contiguous space
          end;
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Pre-add: page %d [%d free]',[page.block.thispage,freeSpace(page)]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          {Read page header}
          page.AsBlock(st,0,sizeof(sHeader),@sHeader);
          {Get a free slot}
          {first try to find & re-use a sid slot that has rType=rtEmpty}
          sid:=1;
          page.AsBlock(st,sid*sizeof(slot),sizeof(slot),@slot);
          while (sid<=sHeader.len) and (slot.rType<>rtEmpty) do
          begin
            inc(sid);
            page.AsBlock(st,sid*sizeof(slot),sizeof(slot),@slot);
          end;
          if sid>sHeader.len then
          begin //append slot
            sHeader.len{=slotCount}:=sHeader.len+1;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('appending new record slot %d',[sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
          else
          begin  //else we're re-using an empty slot
            spaceNeeded:=spaceNeeded-sizeof(slot);  //we don't need to add space for a new slot after all
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('re-using empty record slot %d',[sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;

          //todo assert r has been set (properly) by caller!
          slot.rType:=r.rType;
          slot.len:=r.len;
          //Note: we assume here that the free space is contiguous
          slot.start:=sHeader.Start{=freeStart}-slot.len+1;
          //todo warn if r.Wt<>Tr.Tid - unless inserting a delta...
          slot.Wt:=r.Wt; //todo remove!  Tr.Tid;
          //todo copy pid & sid in one go -speed!?
          slot.PrevRID.pid:=r.prevRID.pid;
          slot.PrevRID.sid:=r.prevRID.sid;
          {Reduce freeSpace}
          sHeader.Start{=freestart}:=sHeader.Start-slot.len; //(work inwards)

          //todo guard/check/constrain this code: it will corrupt the db if it overflows!
          {Write record data}
          page.SetBlock(st,slot.start,slot.len,r.dataPtr);
          {Write slot entry}
          page.SetBlock(st,sid*sizeof(slot),sizeof(slot),@slot);
          {Rewrite updated header}
          page.SetBlock(st,0,sizeof(sHeader),@sHeader);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}
      end
      else
      begin
        if retry=-1 then retry:=1;
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
        {$ENDIF}
        //exit;
        continue; //abort/retry
      end;

      if DirPageAdjustSpace(st,dirPageId,dirslot,-spaceNeeded,spaceLeft)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed updating directory entry for page %d, ignoring',[page.block.thispage]),vDebugError)
        {$ENDIF}
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Updated directory entry for page %d by %d to %d',[page.block.thispage,-spaceNeeded,spaceLeft]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        //use a server 'corrupt-womble?' setting to determine whether we fix or defer here
        //    - but remember: fixing these small problems early prevents major ones later...!
        //- in future, maybe we can set a bit on the tables that are modified
        //  and then the recovery module could check/fix the directories of those tables...
        //  - this would save calculating & latching and checking the freeSpace after every insert = speed!

        //todo calculate freespace() once for speed
        if freespace(st,page)<>spaceLeft then //warning: space reported is wrong (could happen after a crash, since we don't flush directory after every change = ok since directory space-list is only used as a quick-finder)
        begin                                 //also likely if another thread is inserting into the same table
          {$IFDEF DEBUGDETAIL}                //so maybe don't bother fixing here as well, seeing as we do this before we add the record (if we are concurrent with another inserter these fixes will be a big waste of time)
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('FreeSpace reported by the updated page (%d) is not the same as that in the directory (%d) - probably as a result of a crash/concurrent insert - fixing now to avoid future problems...',[freespace(st,page),spaceLeft]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
            begin //ok fix
              if DirPageSet(st,dirPageId,dirSlot,{dir}Pid,freespace(st,page),False)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed fixing directory slot (%d in page %d) - unable to change freespace from %d to %d for page %d, continuing',[dirSlot,dirPageId,spaceLeft,freespace(st,page),page.block.thisPage]),vAssertion)
                {$ENDIF}
              else
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Fixed directory slot (%d in page %d) - freespace changed from %d to %d for page %d',[dirSlot,dirPageId,spaceLeft,freespace(st,page),page.block.thisPage]),vFix);
                {$ELSE}
                ;
                {$ENDIF}
            end;
          //end;
        end;
      end;

      rid.pid:=pid;
      rid.sid:=sid;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Added record in page %d [now %d free] of length %d at slot %d (offset=%d) [Wt=%d]',
                                   [rid.pid,freeSpace(page),slot.len,rid.sid,slot.start,r.Wt]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      result:=ok;

    finally
      buffer.unpinPage(st,pid);
    end; {try}
  end; {with}
 end; {retry}

 if (result<>ok) and (retry=0) then
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Failed after retries',[nil]),vAssertion);
  {$ELSE}
  ;
  {$ENDIF}
end; {AddRecord}

function THeapFile.UpdateRecord(st:TStmt;r:Trec;rid:Trid;checkTranId:boolean):integer;
{Update an existing record in the file (by overwriting it in the same place)
 IN    : st           the statement
       : r            the record
       : rid          the rid to update
       : checkTranId  if True, asserts that the existing slot tran-id = new record tran-id (unless we are in recovery mode)
                      else, allows different new record tran-id to overwrite existing
 RETURN: +ve=ok, else fail

 Note:
   only updates record data, not header/slot info

 Side-effects:
   may modify the record, e.g. len & rType etc.

 Assumes:
   currently can guarantee in-place update with same or less length
   - if length has grown, then we try to de-allocate existing space & re-write in same page,
     but if we can't then we insert the updated record elsewhere (currently 1st place it fits)
     and then add a forwarding rid in its original location (by using MAXStampId)
   so we *always* keep the original RID in use
}
const routine=':UpdateRecord';
var
  spaceLeft:word;
  page:Tpage;
  dirSlot:DirSlotId;
  dirPageId:PageId;

  oldLen:RecSize;

  sHeader, slot, saveSlot:TSlot;
  newRid:Trid;
begin
  result:=Fail;

  {Todo move!}
  if slotSize<>sizeof(slot) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SlotSize[%d]<>sizeof(slot)[%d]',[slotSize,sizeof(slot)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {Pin the page, update the record in the specified slot}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,rid.pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading page to update record, %d',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read page header} //only needed if rec len change
      if page.latch(st)=ok then
      begin
        try
          page.AsBlock(st,0,sizeof(sHeader),@sHeader);

          {Read slot entry}
          page.AsBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);

          if checkTranId then
          begin
            {Check this update is legal?}
            if (slot.Wt.tranId<>r.Wt.tranId) then
            begin
              //todo also ignore if garbageCollector (and so pass True to checkTranId from tuple.garbageCollect etc.)
              if Ttransaction(st.owner).Recovery then //todo also, only if this is the sysTran table?
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Recovery excepted: Can only update record (%d:%d) with same transaction id (%d:%d)',[slot.Wt.tranId,slot.Wt.stmtId,r.Wt.tranId,r.Wt.stmtId]),vDebugLow)
                {$ENDIF}
              else
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Can only update record (%d:%d) with same transaction id (%d:%d)',[slot.Wt.tranId,slot.Wt.stmtId,r.Wt.tranId,r.Wt.stmtId]),vDebugError);
                {$ELSE}
                ;
                {$ENDIF}
                exit; //abort
              end;
            end;
          end;
          //else we're allowed

          {Update slot header
           //currently not start + len! this would affect slot header etc.}
          //todo assert r has been set (properly) by caller!

          {Record the original record length, so we can adjust the page free space later}
          oldLen:=slot.len;

          if r.len>slot.len then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Updating record (%d) with increased length (%d)...',[slot.len,r.len]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {First, temporarily reclaim existing space used
             -Note, we *always* re-use this slot, but maybe the length will change
            }
            {Save the current header details}
            saveSlot.rType:=slot.rType; //no need, use r?  -but what if r has been modified, e.g. delta added to another page?
            saveSlot.Wt:=slot.Wt; //no need, use r?
            saveSlot.PrevRID:=slot.prevRID; //no need, use r?

            slot.rType:=rtReservedSlot;
            //todo try..finally so we never leave a page as rtReservedSlot
            slot.len:=0; //this is the key, to fool the freeSpace calculation routine
            //Note: we assume here that the free space is contiguous
            slot.start:=0;
            {todo remove next 3 - overkill - then we needn't save all the slot data!}
            slot.Wt:=InvalidStampId;
            slot.PrevRID.pid:=InvalidPageId;
            slot.PrevRID.sid:=InvalidSlotId;

            //todo maybe zeroise old record data - security setting?
            //page.SetBlock(slot.start,slot.len,r.dataPtr);
            {Write emptied slot entry}
            page.SetBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);
            {We can't adjust the header's freeSpace pointer yet - not necessarily a contiguous free}

            page.dirty:=True;

            {Now try to fit the new record on the same page using the same slot}
            if r.len<=contiguousFreeSpace(st,page) then //easy option - use spare chunk & leave garbage for later collection...
                                                     //-but maybe we should re-org the page to clean it now? - use server 'womble' setting!
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found enough contiguous space in page %d for increased record length of %d',[page.block.thispage,r.len]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {We re-use/re-store the just emptied slot}
              slot.rType:=saveSlot.rType;
              slot.len:=r.len;
              //Note: we assume here that the free space is contiguous
              slot.start:=sHeader.Start{=freeStart}-slot.len+1;
              slot.Wt:=r.Wt;  //use new record tid    //bugfix 08/07/99: saveSlot.Wt;
              //todo copy pid & sid in one go -speed!?
              slot.PrevRID.pid:=saveSlot.prevRID.pid;
              slot.PrevRID.sid:=saveSlot.prevRID.sid;
              {Reduce freeSpace}
              sHeader.Start{=freestart}:=sHeader.Start-slot.len; //(work inwards)
            end
            else
            begin //no contiguous space, make room for the update...
              {we should try and re-organise the page, if it will help
               if it can't/won't help, copy the new data elsewhere and place forwarding pointer stub in this page/slot}
              if r.len<=freeSpace(st,page) then
              begin //there is room on this page, we just need to make it contiguous...
                //again, use a server 'womble2' setting to determine whether we re-org or defer here
                //- I can't think of any reason to defer at this point, since it will mean using a forwarding RID
                //  which would mean more page access now & in future (but use the switch anyway?=fine tuneable...????)
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found enough (non-contiguous) space in page %d for increased record length of %d - will now re-org page...',[page.block.thispage,r.len]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
    //********
    //TODO SEE the notes in AddRecord!!!!!  about page thrashing to eek out a few extra bytes...
    // Note: the leaving extra space for in-place updates doesn't apply - we are the updates!
    //********
                result:=reorgPage(st,page); //REORG
                if result<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'Failed reorganising page',vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  exit; //abort ?
                end;
                {We must re-read the page details. although the sid is the same}
                page.AsBlock(st,0,sizeof(sHeader),@sHeader);
                //Note: no need to re-read the slot: reorg only changes the start...
                //                                              and we re-set the start below...

                //todo improve logic flow: this code is copied from above!
    //copied...
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Made enough contiguous space in page %d for increased record length of %d',[page.block.thispage,r.len]),vDebugLow);
                {$ENDIF}
                {We re-use/re-store the just emptied slot}
                slot.rType:=saveSlot.rType;
                slot.len:=r.len;
                //Note: we assume here that the free space is contiguous
                slot.start:=sHeader.Start{=freeStart}-slot.len+1;
                slot.Wt:=r.Wt; //use new record tid    //bugfix 08/07/99: saveSlot.Wt;
                //todo copy pid & sid in one go -speed!?
                slot.PrevRID.pid:=saveSlot.prevRID.pid;
                slot.PrevRID.sid:=saveSlot.prevRID.sid;
                {Reduce freeSpace}
                sHeader.Start{=freestart}:=sHeader.Start-slot.len; //(work inwards)
    //end-copied... write is done below...
              end
              else
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Could not find enough space in page %d for increased record length of %d - will write update elsewhere and leave forwarding RID...',[page.block.thispage,r.len]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                //note: we'll always have enough in-place room to rewrite a forwarding RID...cos slot.len will=0
                //todo keep stats on how many times we have to do this: may mean we need a higher insert watermark
                r.rType:=rtDelta; //we store update as a delta, because we're forwarding to it
                try
                  result:=addRecord(st,r,newRid); //todo: need to ensure no deadlock in case add tries to read our latched page (tell add to ignore our page id=simplest way?)
                finally
                  r.rType:=saveSlot.rType; //restore input data
                end; {try}
                if result<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'Failed adding update record elsewhere',vError);
                  {$ENDIF}
                  exit; //abort ?
                end;
                {Note: between now and when we flush our page, there is a chance that the newly added update record in
                 another page will become an orphan if we crash
                 - maybe we should pin the newRid page immediately after addRecord to be safe!
                  - so maybe addRecord should have a 'leavePinned' flag - generally useful?
                 //todo ensure vacuum removes such orphans}

                {We re-use/re-store the just reset-to-delta forwarding address slot back to the original record}
                slot.rType:=saveSlot.rType; //keep the original's record type
                slot.len:=0; //zeroise the record - there is no data, we just use the prevRID on the slot...
                             {Since the caller won't appreciate direct modification of the input record
                              we just modify slot.len (not r.len) & make sure we use that below to rewrite the record data}
                slot.start:=0;
                slot.Wt:=MaxStampId; //we set to the maximum possible tranId so any readers will skip past to forwarding place
                {Point this slot to forward to the new place}
                //todo copy pid & sid in one go -speed!?
                slot.PrevRID.pid:=newRid.pid;
                slot.PrevRID.sid:=newRid.sid;

                {bugfix 15/11/02: update not fitting on current page left forwarder with incorrect prevRID - update header (called from uTuple.update) was re-using r
                 - why does tuple.update need to call updateHeader since this seems to do it?}
                //leave forwarders with Wt - need for visibility e.g. for future updates //r.Wt:=slot.Wt;
                r.prevRID.pid:=slot.PrevRID.pid;
                r.prevRID.sid:=slot.PrevRID.sid;

    //            {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Inserted update record at %d:%d and will be forwarded from %d:%d',[newRid.pid,newRid.sid,rid.pid,rid.sid]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
    //            {$ENDIF}
              end;
            end;

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Made room for record with increased length (%d) starting at %d...',[slot.len,slot.start]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
          end
          else
            if r.len<slot.len then
            begin  //shrink allocated len (slot.len=r.len)
                       //todo if the new length is less than before, we need to reclaim space/reorg page data... later/elsewhere?...
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Updating record (%d) with decreased length (%d)...',[slot.len,r.len]),vDebugLow); 
              {$ELSE}
              ;
              {$ENDIF}
              slot.len:=r.len; //reduce
              slot.Wt:=r.Wt; //use new record tid    //bugfix 08/07/99
            end
            else // =, so re-use slot & len without pre-adjusting
              slot.Wt:=r.Wt; //use new record tid    //bugfix 08/07/99


          {Now do the re-write of the current slot
           Note: we didn't modify r directly, so use the slot details as modified above e.g. len
           - especially in case slot.len=0 (but r.len is not, but it's already been written elsewhere)}

          {Update record data entry - overwrite!}
          page.SetBlock(st,slot.start,slot.len,r.dataPtr);

          {Re-Write slot entry}
          page.SetBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);

          {Rewrite updated header}
          page.SetBlock(st,0,sizeof(sHeader),@sHeader);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}
      end
      else
        exit; //abort

      {Do we have any extra/less space on this page now?}
      if oldLen<>slot.len then
      begin
        {Now update free space count in appropriate file directory page}
        {Find and pin the dir page for this page}
        if DirPageFindFromPID(st,rid.pid,dirPageId,dirSlot)<>ok then
        begin
          result:=Fail;
          exit;
        end;
        if dirSlot=InvalidDirSlot then
        begin
          result:=Fail;
          exit;
        end
        else
        begin
          if DirPageAdjustSpace(st,dirPageId,dirslot,(oldLen-slot.len),spaceLeft)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed updating directory entry for page %d, ignoring',[page.block.thispage]),vDebugError)
            {$ENDIF}
          else
          begin
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Updated directory entry for page %d by %d to %d',[page.block.thispage,(oldLen-slot.len),spaceLeft]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            if freespace(st,page)<>spaceLeft then //warning
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('FreeSpace reported by the updated page (%d) is not the same as that in the directory (%d) - ignoring',[freespace(st,page),spaceLeft]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
          end;
        end;
      end;

//      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Updated record in page %d at slot %d [Wt=%d:%d] old len=%d, new len=%d',
                                   [rid.pid,rid.sid,slot.Wt.tranId,slot.Wt.stmtId,oldLen,slot.len]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
//      {$ENDIF}
      result:=ok;

    finally
      buffer.unpinPage(st,rid.pid);
    end; {try}
  end; {with}
end; {UpdateRecord}


function THeapFile.UpdateRecordHeader(st:TStmt;r:Trec;rid:Trid):integer;
{Update an existing record header in the file
 IN    : st           the statement
       : r            the record
                      Note: assumes contains header changes, specifically.
                            Wt,
                            prevRID,
                            rType
                            (no others will be updated, unless listed
                            so other r fields may contain garbage)
       : rid          the rid to update
 RETURN: +ve=ok, else fail
}
const routine=':UpdateRecordHeader';
var
  page:Tpage;
  slot:Tslot;
begin
  result:=Fail;

  {Todo move!}
  if slotSize<>sizeof(slot) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SlotSize[%d]<>sizeof(slot)[%d]',[slotSize,sizeof(slot)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {Pin the page, update the record in the specified slot}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,rid.pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading page to update record, %d',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read slot entry}
      if page.latch(st)=ok then
      begin
        try
          page.AsBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);

          {Update slot header
           //currently not start + len! this would affect slot header etc.}
          //todo assert r has been set (properly) by caller!
          slot.rType:=r.rType;
          //todo warn if r.Wt<>Tr.Tid
          slot.Wt:=r.Wt; //todo remove!  Tr.Tid;
          //todo copy pid & sid in one go -speed!?
          slot.PrevRID.pid:=r.prevRID.pid;
          slot.PrevRID.sid:=r.prevRID.sid;

          {Re-Write slot entry}
          page.SetBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}
      end
      else
        exit; //abort

      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Updated record header in page %d at slot %d [Wt=%d]',
                                   [rid.pid,rid.sid,r.Wt]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      result:=ok;

    finally
      buffer.unpinPage(st,rid.pid);
    end; {try}
  end; {with}
end; {UpdateRecordHeader}
function THeapFile.UpdateRecordHeaderType(st:TStmt;rt:recType;rid:Trid):integer;
{Update an existing record header in the file
 IN    : st           the statement
       : rt           the new record header type
       : rid          the rid to update
 RETURN: +ve=ok, else fail
}
const routine=':UpdateRecordHeaderType';
var
  page:Tpage;
  slot:Tslot;
begin
  result:=Fail;

  {Todo move!}
  if slotSize<>sizeof(slot) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SlotSize[%d]<>sizeof(slot)[%d]',[slotSize,sizeof(slot)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {Pin the page, update the record in the specified slot}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,rid.pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading page to update record type, %d',[rid.pid]),vError);
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read slot entry}
      if page.latch(st)=ok then
      begin
        try
          page.AsBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);

          {Update slot header type}
          slot.rType:=rt;

          {Re-Write slot entry}
          page.SetBlock(st,rid.sid*sizeof(slot),sizeof(slot),@slot);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}
      end
      else
        exit; //abort

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Updated record header type in page %d at slot %d [Wt=%d]',
      {$ELSE}
      ;
      {$ENDIF}
                                   [rid.pid,rid.sid,tr.tid]),vDebugMedium);
      {$ENDIF}
      result:=ok;

    finally
      buffer.unpinPage(st,rid.pid);
    end; {try}
  end; {with}
end; {UpdateRecordHeaderType}

function THeapFile.debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
{
 Note: this will ruin any scan in progress
}
const routine=':debugDump';
var
  rid:Trid;
  i:SlotId;
  sHeader, slot:TSlot;
  totalPages,space,totalUsed,totalSpace:integer;
  nextPid:PageId;
begin
  inherited debugDump(st,connection,summary);

  totalPages:=0;
  totalUsed:=0;
  totalSpace:=0;
  result:=self.GetScanStart(st,rid);
  if result<>ok then exit; //abort
  try
    with (Ttransaction(st.owner).db.owner as TDBserver) do
    begin
      repeat
        inc(totalPages);
        if fCurrentpage.block.pageType=ptData then
        begin
          //show this page
          if connection<>nil then
          begin
            {Read page header}
            fCurrentpage.AsBlock(st,0,sizeof(sHeader),@sHeader);

            space:=freespace(st,fCurrentpage);


            totalUsed:=totalUsed+(BlockSize-space);  //todo refine: doesn't include slot-headers etc.?
            totalSpace:=totalSpace+space;


            {$IFDEF DEBUGDETAIL3}
            connection.WriteLn(format('Block memory address=%p',[@fCurrentpage.Block]));
            {$ENDIF}
            connection.WriteLn(format('Page %10.10d: type=%-10.10s slots=%3.3d space=%5.5d contiguous space=%5.5d prev=%10.10d next=%10.10d',
                                  [fCurrentpage.block.thisPage,
                                   pageTypeText[fCurrentpage.block.pageType],
                                   sHeader.len,
                                   space,
                                   contiguousFreespace(st,fCurrentpage),
                                   fCurrentpage.block.prevPage,
                                   fCurrentpage.block.nextPage
                                  ]));

            if not summary then
            begin
              connection.WriteLn(format('  Slot %3.3d: type=%-14.14s free-start=%5.5d slot-count=%5.5d Wt=%10.10d:%10.10d prevRID=%10.10d:%3.3d',
                                    [0,
                                     recTypeText[sHeader.rType],
                                     sHeader.start,
                                     sHeader.len,
                                     sHeader.Wt.tranId, sHeader.Wt.stmtId,
                                     sHeader.PrevRID.pid, sHeader.PrevRID.sid
                                    ]));

              for i:=1 to sHeader.len do
              begin
                fCurrentpage.AsBlock(st,i*sizeof(slot),sizeof(slot),@slot);

                connection.WriteLn(format('  Slot %3.3d: type=%-14.14s start=%5.5d size=%5.5d Wt=%10.10d:%10.10d prevRID=%10.10d:%3.3d',
                                      [i,
                                       recTypeText[slot.rType],
                                       slot.start,
                                       slot.len,
                                       slot.Wt.tranId, slot.Wt.stmtId,
                                       slot.PrevRID.pid, slot.PrevRID.sid
                                      ]));
              end;
            end;
          end;
        end
        else
          if connection<>nil then
            connection.WriteLn('  '+pageTypeText[fCurrentpage.block.pageType]);

        //next page
        if fCurrentpage.block.nextPage<>InvalidPageId then
        begin
          nextPid:=fCurrentpage.block.nextPage;
          buffer.unpinPage(st,fCurrentrid.pid);
          {Goto next page
           Note: HeapFile has no order & follows page pointers
                 it could also getNext DirPageSlot
                 in fact, these two orderings should be the same!? prove?
          }
          if buffer.pinPage(st,nextPid,fCurrentpage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format(' %d:next failed',[nextPid]),vError);
            {$ENDIF}
            result:=Fail;
            exit; //abort
          end;
          fCurrentRid.pid:=fCurrentpage.block.thisPage;  //the new page
          fCurrentRid.sid:=0;
        end
        else
          break; //no more
      until False;

      connection.WriteLn(format('Table space: pages=%10.10d total data=%12.12d used=%12.12d free=%12.12d',
                            [totalPages,
                             totalUsed+totalSpace,
                             totalUsed,
                             totalSpace
                            ]));
    end; {with}

  finally
    result:=self.GetScanStop(st);
  end; {try}
end; {debugDump}


end.

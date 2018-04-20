unit uFile;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Generic DB-file management routines
 Just has a file page directory and no page structure
 (although Trec is specified for Add/Read abstract routines)
 and virtual methods for reading and adding records and for scanning the file

 Note:
   the dbserver.buffer is accessed via the passed transaction - so it had better be stable
   - else we could pin using one buffer and try to unpin using another (can't see how this could happen)

 Note:
   pages chained in a heap file must match the order of the pages in the file directory

   the dirSlot references in the file directory are continous and are split into pages
   in the directory routines.
   To speed up some of the routines, the dirSlot page is often passed (dirPageId) as well:
   this avoids the need to scan long directory chains for large files, but does
   assume that the directory slots and pages are stable.
   (May have been better using RID? Could still calculate prevSlot:=slot-1?)
}

//{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUG_CHECKDIR}
{$DEFINE SAFETY}  //extra sense checks, e.g. page=0

interface

uses uPage, uGlobal, uStmt, uGlobalDef, IdTCPConnection{debug only};

const
  TFileDirSize=sizeof(pageId)+sizeof(word)  +2;  //Note: +2 because record seems to round up
  FileDirPerBlock=BlockSize div TFileDirSize;
  InvalidDirSlot=-1;

type
  TfileDir=record   //note: see TFileDirSize above - keep in sync!!
    pid:PageId;
    Space:word;           //(limits blockSize to 65535)
  end; {TfileDir}

  recType=(rtHeader,           {Special slot header}

           rtEmpty,            {Slot no longer used - can be purged if at end of page slot array}

           rtDeletedRecord,    {Deleted header - retain - deletion could be rolled-back => same as normal rtRecord}
           rtRecord,           {Record header}

           rtDelta,            {Record delta}

           rtReservedSlot,     {Note: this is for internal page shuffling only - it should never be seen on disk!}

           rtBlob              {Blob data - reference by rtRecord or rtDelta}
           ); //todo check/force size is byte? = default (or use $MINENUMSIZE 1)
           //todo keep in sync with recTypeText strings below

  {(These limit the max blockSize to 65535)}   //note: ensure algorithms don't try to go past the limit
  RecId=word;              //in-page pointer
  RecSize=word;            //in-page record length

  PtrRecData=^TrecData;
  TrecData=array [0..MaxRecSize-1] of char;           //record data (used for pointer typing and AddRecord tests)

  //note similarity between TSlot and Trec!  -same except Trec has a swizzled pointer to memory
                                            //maybe could use Tslot.start(longint) as memory pointer? saving what?
  Trec=class              //Record block pointer within a (pinned) page (overlay)
    private
    public
      rType:recType;      //record type
      dataPtr:PtrRecData; //data start
      len:integer;        //length
      Wt:StampId;         //Transaction W timestamp
      prevRID:Trid;       //pointer to previous record in db
  end; {Trec}


  TDBFile=class            //database heapfile //todo abstract?
  protected
    fstartPage:PageId;     //first page of page directory
    fname:string;          //the db filename

    //todo move these to the transaction level & have scan routines pass the latest value to us
    // that way multiple users can share the same file (esp. db.sysTable etc.) but can
    // scan independently.
    // So, make sure we make this thread-safe: esp. access to properties/open/new routines etc.
    //This then allows them to share heapfile & so Trelation
    // - again make sure these are thread safe:
    //  - ->we need to move relation.fTuple to the transaction also!
    //      but then iterator trees would collapse!
    //      we really need a new ftuple per tran using the relation
    //      but then there's little point sharing the relation!
    //      Think/design...
    //      only need to share ftuple (and file.currentRid) for db.sysTableRel etc.
    //      and these are only used for quick lookup access (don't serialise!)
    //      and occasionaly insertions/updates (could be serialised)
    //      So, each tran really needs a currentRid + currentTuple for each sysRel
    //      to allow concurrent scanning/reading (no sharing 1 tuple for all sysRel, since may be fast-joining etc)
    //      -probably will be around: col,table,auth,schema,dom,constr,dom-con,col-con,fk,idx= 10
    //      system relations = extra ~10k per transaction = not bad
    //      alternative is to keep as they are, via db = bottleneck
    //      but bottle neck only when
    //          opening/creating relations (then in tuple def)
    //          building constraint trees for insert/update (will be done once at start)
    //      so maybe hardly ever any contention????? so extra complexity not worth it?
    //      -maybe in future could add another thread/set of sysRels to handle extra requests in parallel
    //      - i.e. 1 or 2 sets of sysRels should handle it?
    //      We should replace hCatalogMutex with hsysTableCriticalSection, hsysColumnCriticalSection etc.
    //      and this means all system catalog functions must be made atomic -via db.routines? - ok?
    //      - may need sysCatalog.lock; sysCatalog.findNextColumn; ...; finally sysCatalog.unlock
    //      plus, these routines make it easier to have an extra catalog server thread later...
    //      plus they hide the details!

    //      but maybe for speed each tran should have its own sysTableRel,sysColumnRel?
    //      (etc.  -use array of rels, e.g. tr.sysCatalog[sysTable].startscan)
    //      then rel.open is very fast with no bottlenecks
    //      - other stuff like reading constraints/permissions
    //      can be left to db routines (serialised, but maybe less so later...)

    //      use tr.sysCatalog[] array for all sys relations
    //      - for those we can serialise for now, point the rel at db.sysRel instead of creating & opening it!
    //       - i.e. looks independent but is shared resource - who serialises access to it?
    //         - maybe use Trelation.serialiseAccess
    //         and all scanstart's rel.lock which will either do nothing or grab critical section
    //         and all scanstop's rel.unlock          -prone to error? -not very neat? waste CS per relation
    //      maybe db.FindSysDomain() can be used for now
    //      or all use shared db.FindNextCol(tr,rel)
    //       & if passed non-db rel, use else serialise access...
    //       e.g. tr: db.FindNextCol(tr,tr.sysCatalog[sysColumn])
    //            tr: db.FindNextDomain(tr,db.sysDomain)   -> serialised cos rel.owner=db
    //            tr: db.FindFirstCol(tr,tr.sysCatalog[sysColumn],'schema1','table1')

    //       but then may as well get findFirstCol to use tr.sysCatalog[sysColumn]
    //       and findFirstDomain to use db.sysDomain - save params
    //       -still isolated for user & can be changed later by adding to
    //              tr.sysCatalog array & tr.start (to open sysRels) & server routines

    //       plus catalog access code is in db routines where it belongs (not in tuple/rel routines)
    //       plus allows us to serialise/centralise issuing of new id's etc.
    //

    fCurrentRID:Trid;      //scan pointer (fCurrentRID.pid will be pinned during scan)
    fCurrentPage:TPage;    //scan page

    fDirPageFindStartPage:PageId;      //first page of page directory that we already found a space on
    fDirPageFindDirPageOffset:integer; //page offset from fStartPage for fDirPageFindStartPage
    fDirPageFindSpace:word;            //last space sought
  public
    property startPage:PageId read fStartPage;
    property name:string read fname; //only currently used for index name debug messages, so remove
    property currentRID:Trid read fCurrentRID;  //need to reference from tuple for deletions
    constructor Create; virtual;
    destructor Destroy; override;
    function createFile(st:Tstmt;const fname:string):integer; virtual;
    function deleteFile(st:Tstmt):integer; virtual;
    function openFile(st:Tstmt;const filename:string;startPage:PageId):integer; virtual;
    function freeSpace(st:Tstmt;page:TPage):integer; virtual;

    //TODO change to ReadRecord(rid:Trid,r:Trec):integer to match AddRecord etc.!
    // also move to HeapFile? i.e. make virtual;abstract - don't assume slot structure at this level? maybe?
    function ReadRecord(st:Tstmt;page:TPage;sid:SlotId;r:Trec):integer; virtual; abstract;
    function AddRecord(st:Tstmt;r:Trec;var rid:Trid):integer; virtual; abstract;

    {File directory is used for:
       tracking pages allocated to this file (and ones that should be deallocated)
       tracking free space within pages for new insertions
       providing a contiguous array of page references [0..DirCount-1] for hash file mapping
       - maybe expose a higher level than these?
    }
    function DirCount(st:Tstmt;var dirSlotCount:integer;var lastDirPage,prevLastSlotDirPage:PageId;retryForAccuracy:boolean):integer;
    function DirPage(st:Tstmt;DirPageId:PageId;dirSlot:DirSlotId;var pid:PageId;var space:word):integer;
    function DirPageSet(st:Tstmt;DirPageId:PageId;dirSlot:DirSlotId;pid:PageId;space:word;AllowOverwrite:boolean):integer;
    function DirPageFind(st:Tstmt;space:word;var pid:PageId;var DirPageId:PageId;var dirSlot:DirSlotId):integer;
    function DirPageFindFromPID(st:Tstmt;pid:PageId;var DirPageId:PageId;var dirSlot:DirSlotId):integer;
    function DirPageAdd(st:Tstmt;pid:PageId;space:word;var prevDirSlotPageId,DirPageId:PageId;var dirSlot:DirSlotId):integer;
    function DirPageRemove(st:Tstmt;pid:PageId;dirSlot:DirSlotId):integer;
    function DirPageAdjustSpace(st:Tstmt;DirPageId:PageId;dirSlot:DirSlotId;spaceAdj:integer;var space:word):integer;

    function GetScanStart(st:Tstmt;var rid:Trid):integer; virtual;
    function GetScanNext(st:Tstmt;var rid:Trid;var noMore:boolean):integer; virtual;
    function GetScanStop(st:Tstmt):integer; virtual;

    function debugDump(st:Tstmt;connection:TIdTCPConnection;summary:boolean):integer; virtual;
  end; {TDBFile}

const
  recTypeText:array [rtHeader..rtBlob] of string = ('header',
                                                    'empty',
                                                    'deletedRecord',
                                                    'record',
                                                    'delta',
                                                    'reserved',
                                                    'blob'
                                                   );
var
  debugFileCreate:integer=0;
  debugFileDestroy:integer=0;

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uServer, uTransaction, uOS {for sleep}
  ,uEvsHelpers
  ;

const
  where='uFile';
  who='';

  {Retry attempts}
  RETRY_DIRPAGEADD=50;
  RETRY_DIRCOUNT=50; //Note: this could be doubled by retry in DirPageAdd

  dirCountEmptyBackoffMin=5; //min. milliseconds (plus random) //todo make proportional to CPU speed/active threads
  dirCountEmptyBackoffExtra=50; //max. milliseconds (random) //todo make proportional to CPU speed/active threads

constructor TDBFile.Create;
begin
  inc(debugFileCreate);
  {$IFDEF DEBUG_LOG}
  if debugFileCreate=1 then
    log.add(who,where,format('  File memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}

  fStartPage:=InvalidPageId;
  fCurrentRID.pid:=InvalidPageId;
  fCurrentRID.sid:=InvalidSlotId;
end;
destructor TDBFile.Destroy;
const routine=':destroy';
begin
  if fCurrentRID.pid<>InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Scan of %s starting at %d is in progress - page %d will be left pinned',[fname,fStartPage,fCurrentRID.pid]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
  end;
  inc(debugFileDestroy);
  inherited;
end;

function TDBFile.createFile(st:Tstmt;const fname:string):integer;
{Creates a file in the database
 IN       : st          the statement (connected to a db)
          : fname       the new filename
 RETURN   : +ve=ok, else fail
}
const routine=':createFile';
var
  page:Tpage;
  fileDir:TFileDir;
  i:DirSlotId;
  needDirEntry:boolean;
begin
  //todo assert db<>nil
  result:=Fail;

  needDirEntry:=(fname=sysTable_file); //only need db-dir entry for sysTable

  if Ttransaction(st.owner).db.addFile(st,fname,fstartPage,needDirEntry)<>ok then
    result:=Fail
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('File %s created starting at page %d',[fname,fStartPage]),vDebug);
    {$ENDIF}

    {Reset DirPageFind cache}
    fDirPageFindStartPage:=InvalidPageId;
    fDirPageFindDirPageOffset:=0;
    fDirPageFindSpace:=MAX_WORD;

    {Create the directory page}
    //note: would be neater to do this when needed i.e. use DirPageAdd() chicken&egg
    with Ttransaction(st.owner).db.owner as TDBserver do
    begin
      if buffer.pinPage(st,fStartPage,page)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed pinning header page',vDebugError);
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      try
        if page.latch(st)=ok then //note: no real need since page is local?
        begin
          try
            page.block.pageType:=ptFileDir;   //overkill, ptFiledir is the default
            //speed: page.block.prevPage:=page.block.thisPage; //make linked list a circle for fast adding later
            {Write zeroised page pointers}
            fileDir.pid:=InvalidPageId;
            fileDir.space:=0;
            for i:=0 to FileDirPerBlock-1 do
            begin
              page.SetBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
            end;
            page.dirty:=True;
          finally
            page.unlatch(st);
          end; {try}

          //30/08/00 moved:page.dirty:=True;
        end
        else
        begin
          result:=fail;
          exit;
        end;
      finally
        buffer.unpinPage(st,fStartPage);
      end; {try}
    end; {with}

    result:=ok;
  end;
end; {createFile}

function TDBFile.deleteFile(st:TStmt):integer;
{Deletes the file from the database
 IN       : st       the statement (connected to a db)
 RETURN   : +ve=ok, else fail

 Assumes:
   file has been opened

 Obviously you should not try to use the file after this routine!
}
const routine=':deleteFile';
var
  page,startPage:Tpage;
  pid:PageId;
  fileDir:TFileDir;
  i:DirSlotId;
  needDirEntry:boolean;

  //newpid:PageId;
  prevPid:PageId;
  //newPage:TPage;
  prevPage:TPage;
  lastDirPage:PageId;
  dirSlot:DirSlotId;
begin
  //todo assert db<>nil
  result:=Fail;

  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    {Move forwards through chain & check the directory pages are clear}
    pid:=fStartPage;
    if buffer.pinPage(st,pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed pinning header page',vDebugError);
      {$ENDIF}
      exit;
    end;
    lastDirPage:=pid;
    try
      {Check each page in the file directory chain is clear: we can guarantee at least 1 file directory page}
      while pid<>InvalidPageId do
      begin
        {Check that this page is ok to delete}
        if page.block.pageType<>ptFileDir then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('File directory page (%d) is not the expected type (%d)',[pid,ord(page.block.pageType)]),vAssertion);
          {$ENDIF}
          exit; //abort
        end;
        (*
        if page.block.nextPage<>InvalidPageId then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Initial file directory page has a forward pointer (%d)',[page.block.nextPage]),vAssertion);
          {$ENDIF}
          exit; //abort
        end;
        *)
        for i:=0 to FileDirPerBlock-1 do
        begin
          page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
          if (FileDir.pid<>InvalidPageId) or (fileDir.space<>0) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('File file directory page (%d) has an allocted slot (%d) [%d:%d]',[pid,i,FileDir.pid,fileDir.space]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
        end;

        //next in chain
        pid:=page.block.nextPage;
        if pid<>InvalidPageId then
        begin
          buffer.unpinPage(st,page.block.thisPage);
          if buffer.pinPage(st,pid,page)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed pinning page',vDebugError);
            {$ENDIF}
            exit;
          end;
          lastDirPage:=pid;
        end;
        //speed: else assert fStartPage.block.prevPage=page.block.thisPage? (i.e. the end is what we expected)
      end;
    finally
      buffer.unpinPage(st,page.block.thisPage);
    end; {try}

    {Remove the dir pages (except the first one), starting with the last one moving backwards through the chain}
    (*speed:
    {First pin the start page so we can keep its end-page pointer up to date}
    if buffer.pinPage(st,fStartPage,startPage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed pinning header page',vDebugError);
      {$ENDIF}
      exit;
    end;
    startPage.latch(st); //keep latched, which also locks others out
    try
    *)
      if buffer.pinPage(st,lastDirPage,page)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed pinning last directory page',vDebugError);
        {$ENDIF}
        exit;
      end;
      try
        while lastDirPage<>fStartPage do
        begin
        {De-initialise the file directory page}
          {Unlink from previous dir page}
          if lastDirPage=fStartPage then
          begin
            prevPid:=InvalidPageId;  //this is the very first directory page
            (*speed:
            startPage.block.prevPage:=fStartPage; //point startPage to itself (keep list circle intact)
            startPage.dirty:=True;
            *)
          end
          else
          begin
            prevPid:=page.block.prevPage;
            if buffer.pinPage(st,prevpid,prevpage)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed reading dir page''s previous page, %d',[prevpid]),vError);
              {$ENDIF}
              exit; //abort
            end;
            prevPage.latch(st);
            try
              (*speed:
              startPage.block.prevPage:=prevpid; //point startPage to this new end page (keep list circle intact)
              startPage.dirty:=True;
              *)
              prevPage.block.nextPage:=InvalidPageId; //sever link forwards
              prevPage.dirty:=True;
            finally
              prevPage.Unlatch(st);
              buffer.unpinPage(st,prevpid);
            end; {try}
          end;

          //move to previous in chain
          lastDirPage:=prevPid;
          if lastDirPage<>InvalidPageId then
          begin
            buffer.unpinPage(st,page.block.thisPage);
            {Remove this directory page}
            //Note: these pages do not appear in the file directory itself, so no need to remove //double-check!
            if Ttransaction(st.owner).db.deallocatePage(st,page.block.thisPage)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'Failed deallocating file directory page',vError);
              {$ENDIF}
              exit; //abort
            end;
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Contracted file page directory by page %d',[page.block.thisPage]),vDebug);
            {$ENDIF}
            if buffer.pinPage(st,lastDirPage,page)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'Failed pinning page',vDebugError);
              {$ENDIF}
              exit;
            end;
          end;
        end;
      finally
        buffer.unpinPage(st,page.block.thisPage);
      end; {try}
    (*speed:
    finally
      startPage.Unlatch(st);
      buffer.unpinPage(st,startPage.block.thisPage);
    end; {try}
    *)

    {note: removing the first directory page is done by db.removeFile}
  end; {with}

  needDirEntry:=(fname=sysTable_file); //only need db-dir entry for sysTable

  if Ttransaction(st.owner).db.removeFile(st,fname,fstartPage,needDirEntry)<>ok then
    result:=Fail
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('File %s deleted starting at page %d',[fname,fStartPage]),vDebug);
    {$ENDIF}

    result:=ok;
  end;
end; {deleteFile}

function TDBFile.openFile(st:TStmt;const filename:string;startPage:PageId):integer;
{Opens a file in the specified database
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
var
  page:TPage;
begin
  result:=Fail;
  //todo assert db<>nil
  //     assert file exists?
  fname:=filename;
  {Get the directory page}
  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    if buffer.pinPage(st,StartPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading start page %d of %s',[fStartPage,filename]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      fstartPage:=startPage;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('File %s opened starting at page %d',[filename,fStartPage]),vDebug);
      {$ENDIF}
      {$ENDIF}
      //todo sanity checks?

      {Reset DirPageFind cache}
      fDirPageFindStartPage:=InvalidPageId;
      fDirPageFindDirPageOffset:=0;
      fDirPageFindSpace:=MAX_WORD;

      result:=ok;
    finally
      buffer.unpinPage(st,StartPage); //todo leave pinned until ScanNext
    end; {try}
  end; {with}
end; {openFile}

function TDBFile.freeSpace(st:TStmt;page:TPage):integer;
{Returns amount of free record space in the specified page
 IN      : page    the page to examine
 RETURN  : the amount of free space
}
const routine=':freeSpace';
begin
  result:=BlockSize;
end; {FreeSpace}

function TDBFile.DirCount(st:TStmt;var dirSlotCount:integer;var lastDirPage,prevLastSlotDirPage:PageId;retryForAccuracy:boolean):integer;
{Returns count of dir slots allocated to this file
 IN      :     retryForAccuracy       True = retries if fails due to other insertions
                                      else until
 OUT     :     dirSlotCount           the number of dir slots (pages) used
         :     lastDirPage            the page id of the last dir page
         :     prevLastSlotDirPage    the page id of the dir page of the last slot-1 (InvalidPageId=no previous slot)
                                      (used for chaining later on)
                                      //Note: this is always = lastDirPage!!! todo so remove!
 RETURNS :     +ve=ok, else fail

 Note: used for adding new pages: dirSlotCount = next free dir slot

 Note: if retryForAccuracy then it retries if necessary to count the slots in the file's directory
       and latches the final page while it counts the entries in an attempt to stabilise multiple inserts
       (but could fail if RETRY_DIRCOUNT is too small)
}
const routine=':DirCount';
var
  page:TPage;
  fileDir:TfileDir;
  dirPageOffset:integer;
  i:DirSlotId;
  retry:integer;
begin
  result:=Fail;
  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ENDIF}
    exit;
  end;
  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    retry:=-1; //i.e. don't retry at all, unless certain circumstance
    while (result<>ok) and ((retry>0) or (retry=-1)) do //outer loop to retry in case we find our last dir page has a next page when we've read it
    begin
      if retry>0 then
      begin
        dec(retry); //i.e. once retry fired, no more to avoid infinite loop
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Retrying (%d more tries to go)',[retry]),vDebugMedium);
        {$ENDIF}
      end;

      dirPageOffset:=0;
      {Move to last page}
      lastDirPage:=fStartPage;
      if buffer.pinPage(st,lastDirPage,page)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading next first dir page %d',[lastDirPage]),vDebugError);
        {$ENDIF}
        if retry=-1 then retry:=1; //todo any point?
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
        {$ENDIF}
        //exit;
        continue; //abort/retry
      end;
      try
        {speed: jump straight to last page rather than reading whole chain but:
           currently we need to count the dir pages to get the total slot count
           todo: get dirPageSet to take slot relative to page & then we can just count slots on the last page here
        lastDirPage:=page.block.prevPage; //use startPage's prevpage to jump straight to end (circular list)
        }
        while page.block.nextPage<>InvalidPageId do
        begin
          lastDirPage:=page.block.nextPage;
          buffer.unpinPage(st,page.block.thisPage{was lastDirPage & was before lastDirPage was reset});
          if buffer.pinPage(st,lastDirPage,page)<>ok then //note: use outer finally to unpin
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading next dir page %d',[lastDirPage]),vDebugError);
            {$ENDIF}
            if retry=-1 then retry:=1; //todo any point?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
            {$ENDIF}
            //exit; //abort - note will cause fail on finally, unpin
            continue; //abort/retry
          end;
          inc(dirPageOffset);
        end; {while}

        {Initial count based on number of full pages read
         (race note: the last page may just have been added by another thread but the new slot not yet set.
          If so, we don't want to return because the caller will think we still need a new page
          based on the slot count but we know we don't. So if the count on the final page = 0, we retry
          - effectively waiting for the new slot to be filled //todo need backoff delay? not much...
          //what if it never comes? retry will timeout...)
        }
        dirSlotCount:=dirPageOffset*FileDirPerBlock;
        {Now count the entries in this last page}
        i:=0;
        {We latch here in an attempt to make more stable (reduce retries) for multi-threaded adding}
        //todo check this doesn't cause it to be slower...
        if retryForAccuracy then
          page.latch(st);
        try
          //todo check if page.block.nextPage<>InvalidPageId=>retry now to avoid delay? speed
          page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
          while filedir.pid<>InvalidPageId do
          begin
            inc(dirSlotCount);
            inc(i);
            if i=FileDirPerBlock then
            begin //reached last entry in dir page - read next?
              if page.block.nextPage<>InvalidPageId then
              begin
                {Note: this could be because another thread is racing away adding entries...so we retry if caller needs accuracy}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Last dir page (%d) has a next pointer, but the initial bulk count reported none',[lastDirPage]),vDebugWarning); //i.e. race bug, e.g. during DirPageAdd! = disaster? but we retry...
                {$ENDIF}
                if retry=-1 then
                  if retryForAccuracy then
                    retry:=RETRY_DIRCOUNT
                  else
                    retry:=1; //todo any point? see code when i=0 below: surely this is accurate enough //speed
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
                {$ENDIF}

                sleepOS(dirCountEmptyBackoffMin+random(dirCountEmptyBackoffExtra));

                //exit; //abort
                break; //abort/retry
              end;
              //this last one is full, end loop
              fileDir.pid:=InvalidPageId;
            end;
            {Look at next slot}
            if fileDir.pid<>InvalidPageId then
              page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
          end; {while}
        finally
          if retryForAccuracy then
            page.unlatch(st);
        end; {try}

        if filedir.pid<>InvalidPageId then continue; //must have broken out in error so jump to retry

        if (dirPageOffset>0) and (i=0) then
        begin //last page is empty (& not just an empty file) - if we return now we could be causing caller to add another dir page unecessarily
          if retryForAccuracy then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Last dir page (%d) is empty, so we retry to wait for initial entry to avoid double adding',[lastDirPage]),vDebugError);
            {$ENDIF}

            //speed? I suppose we could return with i=1 so the caller tries to use this new page immediately
            //      seems like a better option but we can't be sure that slot will be free for us!
            //      - we could just retry this last page loop count (but once we can jump to the last dir page, no speed benefit)

            if retry=-1 then
              retry:=RETRY_DIRCOUNT;
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
            {$ENDIF}
            //exit; //abort - note will cause fail on finally, unpin
            continue; //abort/retry
          end;
          //else don't retry, we have the right count probably -1
        end;

        prevLastSlotDirPage:=lastDirPage; //all other slots' previous slots are on this page
                                          //since we return the last slot page & the count
                                          // - so it's up the the caller who adds a new dir page to
                                          //   set a different prev dir page
        result:=ok;
      finally
        buffer.unpinPage(st,lastDirPage);
      end; {try}
    end; {retry}

    if (result<>ok) and (retry=0) then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed after retries',[nil]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
  end; {with}
end; {DirCount}

function TDBFile.DirPage(st:TStmt;DirPageId:PageId;dirSlot:DirSlotId;var pid:PageId;var space:word):integer;
{Returns details of specified dir slot allocated to this file
 IN      :     dirPageId              the dir slot's page reference (InvalidPageId=not known, use slot reference only)
                                      (only used to shortcut the dir chain if we already know the dir page)
         :     dirSlot                the dir slot's reference
 OUT     :     pid                    the page id
                                      (NOTE: if InvalidPageId then not allocated=fail & caller to handle
                                       - except dirSlot=0 = empty file
                                      )
         :     space                  the amount of free space on the page
 RETURNS :     +ve=ok, else fail
}
const routine=':DirPage';
var
  page:TPage;
  fileDir:TfileDir;
  dirPageOffset:integer; //page jump count
  dirPage:PageId;
  nextDirPage:PageId;
begin
  result:=Fail;
  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ENDIF}
    exit;
  end;

  //SAFETY: check dirSlot>=0!

  {Find the appropriate dir page}
  dirPageOffset:=dirSlot div FileDirPerBlock; //page offset
  nextDirPage:=fStartPage;
  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    if DirPageId=InvalidPageId then
    begin
      {Find the appropriate dir page}
      while dirPageOffset>0 do
      begin
        dirPage:=nextDirPage;
        if buffer.pinPage(st,dirPage,page)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
          {$ENDIF}
          exit; //abort
        end;
        try
          if page.block.nextPage=InvalidPageId then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Missing next dir page from %d to read dir slot %d',[dirPage,dirSlot]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
          nextDirPage:=page.block.nextPage;
          dec(dirPageOffset);
        finally
          buffer.unpinPage(st,dirPage);
        end; {try}
      end; {while}
    end
    else
    begin //dir page reference was passed by caller, so we can jump straight to it
      nextDirPage:=DirPageId;
    end;

    {Ok, now get the dir slot}
    if buffer.pinPage(st,nextdirPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[nextdirPage]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      page.AsBlock(st,(dirSlot mod FileDirPerBlock)*sizeof(fileDir),sizeof(fileDir),@fileDir);
      pid:=fileDir.pid;      //if = InvalidPageId then read past end - caller to deal with this
      space:=fileDir.Space;
      {$IFDEF SAFETY}
      if (dirSlot<>0) and (pid=InvalidPageId) then //i.e. if initial dirSlot (0) could just be an empty file with no datapages yet
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Invalid page (%d) (space=%d) read from dir page %d (slot=%d)',[pid,space,nextdirPage,dirSlot]),vAssertion);
        {$ENDIF}
        exit; //abort
      end;
      {$ENDIF}

      result:=ok;
    finally
      buffer.unpinPage(st,nextdirPage);
    end; {try}
  end; {with}
end; {DirPage}

function TDBFile.DirPageSet(st:TStmt;DirPageId:PageId;dirSlot:DirSlotId;pid:PageId;space:word;AllowOverwrite:boolean):integer;
{Sets details of specified dir slot allocated to this file
 IN      :     dirPageId              the dir slot's page reference (InvalidPageId=not known, use slot reference only)
                                      (only used to shortcut the dir chain if we already know the dir page)
         :     dirSlot                the dir slot's reference
         :     pid                    the page id
         :     space                  the amount of free space on the page
         :     AllowOverwrite         True=ignore if pageId differs from existing one
                                      False=abort if pageId differs
 RETURNS :     +ve=ok,
               -2 = slot was occupied by another pageId, e.g. add race lost
               else fail

 Note: it is up to the caller to retry (or whatever) if this fails (especially when AllowOverwrite=False = normal case),
       e.g. dirPageAdd tries to set the 1st free dir slot but it could be
            beaten to it by another thread so it should retry

 Assumes: if dirPageId is passed, we assume the page is stable with respect to the dirSlot, i.e. within the dir chain
          (so future directory page insertion/deletion algorithms could cause problems)
}
const routine=':DirPageSet';
var
  page:TPage;
  fileDir:TfileDir;
  {$IFDEF DEBUG_CHECKDIR}
  existingFileDir:TfileDir;
  {$ENDIF}
  dirPageOffset:integer; //page jump count
  dirPage:PageId;
  nextDirPage:PageId;
begin
  result:=Fail;
  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ENDIF}
    exit;
  end;

  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    if DirPageId=InvalidPageId then
    begin
      {Find the appropriate dir page}
      dirPageOffset:=dirSlot div FileDirPerBlock; //page offset
      dirPage:=fStartPage;
      nextDirPage:=fStartPage;
      while dirPageOffset>0 do
      begin
        dirPage:=nextDirPage;
        if buffer.pinPage(st,dirPage,page)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
          {$ENDIF}
          exit; //abort
        end;
        try
          if page.block.nextPage=InvalidPageId then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Missing next dir page from %d to read dir slot %d',[dirPage,dirSlot]),vDebugError);
            {$ENDIF}
            exit; //abort
          end;
          nextDirPage:=page.block.nextPage;
          dec(dirPageOffset);
        finally
          buffer.unpinPage(st,dirPage);
        end; {try}
      end; {while}
    end
    else
    begin //dir page reference was passed by caller, so we can jump straight to it
      nextDirPage:=DirPageId;
    end;

    {Ok, now set the dir slot}
    if buffer.pinPage(st,nextdirPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[nextdirPage]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      if pid=InvalidPageId then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Cannot add an invalid page id to the page directory',vAssertion);
        {$ENDIF}
        exit;
      end;
      fileDir.pid:=pid;
      fileDir.Space:=space;
      if page.latch(st)=ok then
      begin
        try
          //Keep live to avoid race! {$IFDEF DEBUG_CHECKDIR}
          if not AllowOverwrite then
          begin
            {Check that the page we're setting is still ours, i.e. when adding new ones check no-one else has grabbed our slot}
            page.AsBlock(st,(dirSlot mod FileDirPerBlock)*sizeof(existingFileDir),sizeof(existingFileDir),@existingFileDir);
            if (existingFileDir.pid<>InvalidPageId) and (existingFileDir.pid<>fileDir.pid) then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Warning: trying to set an existing page id (%d) in the page directory to a new one (%d) - rejecting',[existingFileDir.pid,fileDir.pid]),vDebugError); //i.e. race bug, e.g. during DirPageAdd! = disaster? but we retry...
              {$ENDIF}
              result:=-2;
              exit; //abort! - up to caller to retry
            end;
          end;
          //else assume caller knows what they're doing!
          //{$ENDIF}

          page.SetBlock(st,(dirSlot mod FileDirPerBlock)*sizeof(fileDir),sizeof(fileDir),@fileDir);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}

        //30/08/00 moved:page.dirty:=True;
      end
      else
        exit; //abort

      result:=ok;
    finally
      buffer.unpinPage(st,nextdirPage);
    end; {try}
  end; {with}
end; {DirPageSet}

function TDBFile.DirPageFind(st:TStmt;space:word;var pid:PageId;var DirPageId:PageId;var dirSlot:DirSlotId):integer;
{Returns details of a dir slot allocated to this file that has >=space free
 IN      :  space                  the min. amount of free space required on the page
 OUT     :  pid                    the page id (if InvalidPageId then not found=caller error!)
         :  dirPageId              the dir slot's page reference
         :  dirSlot                the dir slot's reference
 RETURNS :     +ve=ok, else fail

 //todo: pass in reason & if AddRecord then leave watermark free in pages scanned for future growth
 //      - according to this file's watermark!

 //todo: speed up by skipping full pages at start of large directories!
}
const routine=':DirPageFind';
var
  page:TPage;
  fileDir:TfileDir;
  dirPageOffset:integer; //page jump count
  dirPage:PageId;

  found:boolean;
  i:DirSlotId;
begin
  result:=Fail;
  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {Find the appropriate dir page}
  dirPage:=fStartPage;
  dirPageOffset:=0;

  {Head start: have we already found a space beyond the first page? If so go straight there
   Note: this is only safe because only garbage collector reduces fileDir chain on dead tables - nothing else does!

   note: this only works if same caller, e.g. 1 insert of multiple rows, or parameterised insert
         - maybe we should jump straight to last dir page if space requested is not small? = speed
  }
  if fDirPageFindStartPage<>InvalidPageId then
    if space>=fDirPageFindSpace then //otherwise we might well find a smaller space earlier on: retry
    begin
      dirPage:=fDirPageFindStartPage;
      dirPageOffset:=fDirPageFindDirPageOffset;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Skipping %d directory pages to %d (asking for %d and previously found %d)',[dirPageOffset,dirPage,space,fDirPageFindSpace]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;

  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    {Ok, now get the dir slot}
    if buffer.pinPage(st,dirPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      i:=0;
      found:=False;
      while not found and (i<=FileDirPerBlock-1) do
      begin
        {I think this will be a big bottle-neck/waste-of-time for large files with multi-page
         directories, e.g. page=4096=510 filedirs per page: 100,000 small records = 1772 pages = 4th page is active, first 3 are full but scanned every time!
         Speed up by remembering last dir page used that had free space & starting from there next time.
         Problem=what if another thread deletes a load of records freeing earlier filedirs?
                 memory doesn't span more than 1 prepared insert
         Solution=1)so what 2)periodically reset the last-dir-page-used 3)get notified & reset...
                  or store page-full-flag at start of each page on disk, so all can skip...

                  Worse case is we don't reuse space, but append to end of file: so what?

         Same problem for updates/deletes... especially so since these more often hit many rows at once in same stmt.
        }
        page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
        if fileDir.space>=space then
          found:=True
        else
          inc(i);

        if i=FileDirPerBlock then
        begin
          if not found then
          begin
            {Try to read the next page}
            if page.block.nextPage<>InvalidPageId then
            begin
              dirPage:=page.block.nextPage;     //since we've just unpinned this page this could fail! Everywhere: nextPid:=page.block.thisPage; unpin(page.block.thisPage);
                                                //done: 31/01/03 - after lots of strange concurrency issues! We should have fixed this long before!
              buffer.unpinPage(st,page.block.thisPage{dirPage});
              if buffer.pinPage(st,dirPage,page)<>ok then
              begin //note: this will fail the unpin below!
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed reading next dir page %d',[dirPage]),vDebugError);
                {$ENDIF}
                exit; //abort
              end;
              inc(dirPageOffset);
              i:=0;
            end; //else at end of dir. Not found & will exit main loop
          end;
        end;
      end; {while}

      if found then
      begin
        //todo check sense, e.g. -784824 = bad!
        pid:=fileDir.pid;      //if = InvalidPageId then read past end - caller to deal with this
        dirPageId:=dirPage;
        dirSlot:=(dirPageOffset*FileDirPerBlock)+i;
        {$IFDEF DEBUGDETAIL} //todo commented-out: debug only after bug found 27/07/01
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Found page with >=%d free at slot %d=page %d (%d free)',[space,dirSlot,pid,fileDir.space]),vDebug);
        {$ENDIF}
        {$ENDIF}

        {Save this directory page to avoid future scans //in future: or to re-instate them
         Note: this assumes future requests against the same file (i.e. by the same caller)
               will be for the same size (or larger). Otherwise we might skip over unused space.
        }
        if dirPageOffset>fDirPageFindDirPageOffset then //in future: remove this check so we can re-instate full scans if requests become small again
        begin
          fDirPageFindStartPage:=dirPage; //=fileDir.pid
          fDirPageFindDirPageOffset:=dirPageOffset;
          {if space<fDirPageFindSpace then} fDirPageFindSpace:=space; //note: this will just record our last find, i.e. will behave as a filter: smaller requests will full-scan, larger or equal will skip ahead
        end;
      end
      else
      begin
        pid:=InvalidPageId;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Could not find a page with %d free space',[space]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end;
      result:=ok;
    finally
      buffer.unpinPage(st,dirPage);
    end; {try}
  end; {with}
end; {DirPageFind}

function TDBFile.DirPageFindFromPID(st:TStmt;pid:PageId;var DirPageId:PageId;var dirSlot:DirSlotId):integer;
{Returns details of a dir slot allocated to this file that has a specific pid
 IN      :  pid                    the page id
 OUT     :  dirPageId              the dir slot's page reference
         :  dirSlot                the dir slot's reference
 RETURNS :     +ve=ok, else fail
}
const routine=':DirPageFindFromPID';
var
  page:TPage;
  fileDir:TfileDir;
  dirPageOffset:integer; //page jump count
  dirPage:PageId;

  found:boolean;
  i:DirSlotId;
begin
  result:=Fail;
  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ENDIF}
    exit;
  end;
  {Find the appropriate dir page}
  dirPage:=fStartPage;
  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    {Ok, now get the dir slot}
    if buffer.pinPage(st,dirPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      i:=0;
      dirPageOffset:=0;
      found:=False;
      while not found and (i<=FileDirPerBlock-1) do
      begin
        page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
        if fileDir.pid=pid then
          found:=True
        else
          inc(i);

        if i=FileDirPerBlock then
        begin
          if not found then
          begin
            {Try to read the next page}
            if page.block.nextPage<>InvalidPageId then
            begin
              dirPage:=page.block.nextPage;
              buffer.unpinPage(st,page.block.thisPage{dirPage});
              if buffer.pinPage(st,dirPage,page)<>ok then
              begin //note: this will fail the unpin below!
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed reading next dir page %d',[dirPage]),vDebugError);
                {$ENDIF}
                exit; //abort
              end;
              inc(dirPageOffset);
              i:=0;
            end; //else at end of dir. Not found & will exit main loop
          end;
        end;
      end; {while}

      if found then
      begin
        dirPageId:=dirPage;
        dirSlot:=(dirPageOffset*FileDirPerBlock)+i;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Found page with pid=%d slot %d (%d free)',[pid,dirSlot,fileDir.space]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end
      else
      begin
        dirPageId:=InvalidPageId;
        dirSlot:=InvalidDirSlot;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Could not find a page with pid=%d',[pid]),vDebugError);
        {$ENDIF}
        {$ENDIF}
      end;
      result:=ok;
    finally
      buffer.unpinPage(st,dirPage);
    end; {try}
  end; {with}
end; {DirPageFindFromPID}

function TDBFile.DirPageAdjustSpace(st:TStmt;DirPageId:PageId;dirSlot:DirSlotId;spaceAdj:integer;var space:word):integer;
{Adjust the amount of space reported by a Dir entry
 IN     : dirPageId          the dir slot's page reference (InvalidPageId=not known, use slot reference only)
                             (only used to shortcut the dir chain if we already know the dir page)
        : dirSlot            the slot to adjust
        : spaceAdj           the adjustment +ve or -ve
 OUT    : space              the new space
 RETURNS: +ve=ok, -ve=fail
}
var
  pid:PageId;
  oldSpace:word;
begin
  result:=fail;
  {Read old}
  if DirPage(st,DirPageId,dirSlot,pid,oldSpace)=ok then
  begin
    {Update}
    if DirPageSet(st,dirPageId,dirSlot,pid,oldSpace+spaceAdj,False)<>ok then exit; //shouldn't fail

    {Read new - note: could avoid this by returning oldSpace+spaceAdj}
    if DirPage(st,DirPageId,dirSlot,pid,Space)=ok then
      result:=ok;
  end;
end; {DirPageAdjustSpace}

function TDBFile.DirPageAdd(st:TStmt;pid:PageId;space:word;var prevDirSlotPageId,DirPageId:PageId;var dirSlot:DirSlotId):integer;
{Adds the new page allocation details to the file page directory
 IN       : pid               the new page id
          : space             the amount of free space on the new page
 OUT      : prevDirSlotPageId the previous dir slot's page reference (InvalidPageId=no previous slot)
                              (caller may use for fast chaining, e.g. heapfile)
          : dirPageId         the dir slot's page reference
          : dirSlot           the dir slot used
 RETURN   : +ve=ok, else fail

 Note: it retries if necessary to add the page into the file's directory
       (but could fail if RETRY_DIRPAGEADD is too small)

 Note: if caller is heapFile it must ensure it links the new page to the previous slot's page
       - else broken chain
}
const routine='DirPageAdd';
var
  dc:integer;
  newpid:PageId;
  prevPid:PageId;
  newPage:TPage;
  prevPage:TPage;
  lastDirPage,prevLastSlotDirPage:PageId;
  fileDir:TFileDir;
  i:DirSlotId;
  retry:integer;
begin
  result:=Fail;

 retry:=-1; //i.e. don't retry at all, unless certain circumstance
 while (result<>ok) and ((retry>0) or (retry=-1)) do //outer loop to retry in case we find our empty slot is no longer empty when we try to set it
 begin
  if retry>0 then
  begin
    dec(retry); //i.e. once retry fired, no more to avoid infinite loop
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Retrying (%d more tries to go)',[retry]),vDebugMedium);
    {$ENDIF}
  end;

  if DirCount(st,dc,lastDirPage,prevLastSlotDirPage,True{retry to get accurate figure})<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed counting existing page dir entries',vDebugError);
    {$ENDIF}
    if retry=-1 then retry:=1; //Note: DirCount has already been tried many times, so no point...?
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
    {$ENDIF}
    //exit;
    continue; //abort/retry
  end;
  {Maybe we should check pid, and check/set freeSpace=space?}
  if (dc mod FileDirPerBlock)<>0 then
  begin
    {A directory page already exists with enough room for the new entry}
  end
  else
  begin
    if dc<>0 then  //we already have the startPage allocated as the first dir page
                   //Note: we could remove this test since the code can handle the 1st page addition
                   //      & then we might simplify the createFile routine. But, we have to add a startPage
                   //      when we create the file at the lowest level - so we may as well use it as dir page 1...
    begin
      {The page directory is full, so extend it by one page}
      {First we latch the end of the directory to prevent any other thread doing the same thing}
      prevPid:=LastDirPage; //Note: we can assume this always exists here
      with (Ttransaction(st.owner).db.owner as TDBserver) do
      begin
        if buffer.pinPage(st,prevpid,prevpage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading new dir page''s previous page, %d',[prevpid]),vError);
          {$ENDIF}
          exit; //abort
        end;
        try
          if prevpage.latch(st)=ok then
          begin
            try
              {Double check prevpage.nextpage=Invalid, else someone else must have jumped in => skip this bit/retry}
              if prevPage.block.nextPage<>InvalidPageId then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('New dir page''s previous page (%d) has already got a next page, %d',[prevpid,prevPage.block.nextPage]),vDebugWarning);
                {$ENDIF}
                //retry - someone must have bet us to it
                if retry=-1 then retry:=1;
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Retry set to %d',[retry]),vAssertion);
                {$ENDIF}
                //exit;
                continue; //abort/retry
              end;

              {Create the directory page}
              if Ttransaction(st.owner).db.allocatePage(st,newpid)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,'Failed allocating new file directory page',vError);
                {$ENDIF}
                exit;
              end;
              {Initialise this new page as a file directory page}
                if buffer.pinPage(st,newpid,Newpage)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed reading new file directory page to initialise it, %d',[newpid]),vError);
                  {$ENDIF}
                  exit; //abort
                end;
                try
                  {Initialise blank dir page}
                  if newpage.latch(st)=ok then //note: no real need since newpage=local/new?
                  begin
                    try
                      newpage.block.pageType:=ptFileDir;
                      {Write zeroised page pointers}
                      fileDir.pid:=InvalidPageId;
                      fileDir.space:=0;
                      for i:=0 to FileDirPerBlock-1 do
                      begin
                        newpage.SetBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
                      end;

                      newpage.block.prevPage:=prevPid;  //link backwards

                      newpage.dirty:=True;
                    finally
                      newpage.unlatch(st);
                    end; {try}

                    //30/08/00 moved:newpage.dirty:=True;
                  end
                  else
                    exit; //abort

                  {Link to previous dir page}
                  prevPage.block.nextPage:=newpid; //link forwards (now dirCount will include this new page)
                  prevPage.dirty:=True;

                  //speed: link dir startPage.prevPage to this new end page
                finally
                  buffer.unpinPage(st,newpid);
                end; {try}
              lastDirPage:=newpid; //for DirPageSet below
              prevLastSlotDirPage:=prevPid; //to return to caller: assumes we will now use 1st slot on newpage, i.e. prev slot's dir page is prevPid
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Extended file page directory with page %d',[newpid]),vDebug);
              {$ENDIF}
            finally
              prevpage.unlatch(st);
              //note: race was happening here:
              //  other thread was in dirCount and just sees our new page so returns an even block count but lastDir page = this empty one (now unlatched!)
              //  so it then adds a new page! leaving this new one with 1 slot & lots of empty slots = invalid heap chain!
              //we'll fix and speed up by:
              //   latching dir start page whenever we add to the end of the chain
              //   and linking the root prevPage to the end of the chain
              //but would still give same race... (count seeing new end page before new slot is added)
              //   for now try to get dirCount to spot its mistake... i.e. if last page=empty = race problem! retry count! i.e. wait for entry on new page
            end; {try}
          end
          else
            exit; //abort
        finally
          buffer.unpinPage(st,prevpid);
        end; {try}
      end; {with}
    end;
  end;

  {Now we have enough dir space, add the entry}
  dirSlot:=dc;
  //Note: we pass lastDirPage to dirPageSet so it can go straight to the dir page (rather than re-read the dir chain!)
  if DirPageSet(st,lastDirPage{speed(=DirPageId)},dirSlot,pid,space,False)<>ok then
  begin
    {We sometimes expect that the last slot we found has now been changed by another
     thread, so we retry if we fail to set it here}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed setting new page dir entry',vDebugError);
    {$ENDIF}
    if retry=-1 then retry:=RETRY_DIRPAGEADD;
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Retry set to %d',[retry]),vDebugLow);
    {$ENDIF}
    //exit;
    continue; //abort/retry
  end;

  prevDirSlotPageId:=prevLastSlotDirPage;     //returned to speed caller chaining
  dirPageId:=lastDirPage;                     //returned to speed caller updates

  result:=ok;
 end; {retry}

 if (result<>ok) and (retry=0) then
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Failed after retries',[nil]),vAssertion);
  {$ELSE}
  ;
  {$ENDIF}
end; {DirPageAdd}

function TDBFile.DirPageRemove(st:TStmt;pid:PageId;dirSlot:DirSlotId):integer;
{Removed the page allocation details from the file page directory
 IN       : pid               the page id
          : dirSlot           the dir slot used
 RETURN   : +ve=ok, else fail
}
const routine='DirPageRemove';
var
  page:TPage;
  fileDir:TfileDir;
  dirPageOffset:integer; //page jump count
  dirPage:PageId;
  nextDirPage:PageId;
begin
  result:=Fail;

  if fStartPage=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Uninitialised start page',vDebugError);
    {$ENDIF}
    exit;
  end;

  {Find the appropriate dir page}
  dirPageOffset:=dirSlot div FileDirPerBlock; //page offset
  dirPage:=fStartPage;
  nextDirPage:=fStartPage;
  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    while dirPageOffset>0 do
    begin
      dirPage:=nextDirPage;
      if buffer.pinPage(st,dirPage,page)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
        {$ENDIF}
        exit; //abort
      end;
      try
        if page.block.nextPage=InvalidPageId then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Missing next dir page from %d to read dir slot %d',[dirPage,dirSlot]),vDebugError);
          {$ENDIF}
          exit; //abort
        end;
        nextDirPage:=page.block.nextPage;
        dec(dirPageOffset);
      finally
        buffer.unpinPage(st,dirPage);
      end; {try}
    end; {while}

    {Ok, now reset the dir slot}
    if buffer.pinPage(st,nextdirPage,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      page.AsBlock(st,(dirSlot mod FileDirPerBlock)*sizeof(fileDir),sizeof(fileDir),@fileDir);
      if pid<>fileDir.pid then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('The page id in the directory (%d) is not the one expected (%d)',[fileDir.pid,pid]),vAssertion);
        {$ENDIF}
        exit; //abort //todo give it a detectable error code
      end;
      //ignore fileDir.Space - it might no be 0 if we haven't garbage collected it yet
      fileDir.pid:=InvalidPageId;
      fileDir.Space:=0;
      if page.latch(st)=ok then
      begin
        try
          page.SetBlock(st,(dirSlot mod FileDirPerBlock)*sizeof(fileDir),sizeof(fileDir),@fileDir);
          page.dirty:=True;
        finally
          page.unlatch(st);
        end; {try}

        //30/08/00 moved:page.dirty:=True;
      end
      else
        exit; //abort
    finally
      buffer.unpinPage(st,nextdirPage);
    end; {try}
  end; {with}

  result:=ok;
end; {DirPageRemove}


function TDBFile.GetScanStart(st:TStmt;var rid:Trid):integer;
{Initialises a scan by moving to the first data page of the file
 Descendents should then move to the page with the first record

 OUT      : rid     - 1 before start rid
 RETURN   : +ve=ok, else fail

 Note:
   this routine leaves fCurrentRID.pid pinned

 Assumes:
   the file has been created/opened already
}
const routine=':GetScanStart';
var
  space:word;
begin
  result:=Fail;
  if fCurrentRID.pid<>InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Scan of %s is already in progress - will unpin page %d and restart',[fname,fCurrentRID.pid]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    //todo abort rather than unpin & continue...
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,fCurrentRID.pid)<>ok then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed unpinning page from existing scan - continuing',[fCurrentRID.pid]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
  end;

  {Check we can read the header page}
  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fStartPage,fCurrentPage)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed reading dir page %d',[fStartPage]),vDebugError);
    {$ENDIF}
    exit; //abort
  end;
  //todo finally?
  (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,fStartPage); //unpin

  {Ok, read the data page}
  result:=DirPage(st,InvalidPageId{todo could use fStartPage?},0,fCurrentRID.pid,space);
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ENDIF}
    //note rid is undefined
    exit; //abort
  end;
  if fCurrentRID.pid<>InvalidPageId then //only if we have data pages
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fCurrentRID.pid,fCurrentPage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading dir page %d',[fStartPage]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    fCurrentRID.sid:=InvalidSlotId;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Started %s scan at page dir slot 0 (%d)',[fname,fCurrentRID.pid]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end
  else
    {there are no data pages for this file (yet) - current page is left as InvalidPageId}
    ;

  rid:=fCurrentRID;
end; {GetScanStart}

function TDBFile.GetScanNext(st:TStmt;var rid:Trid;var noMore:boolean):integer;
{Retrieves the next record in the scan
 Descendents dependent!
 Note: descendent should call & then check NoMore to see if they can proceed

 OUT      : rid      the next record
          : noMore = True if no more records
 RETURN   : +ve=ok, else fail

 Note:
   this routine leaves fCurrentRID.pid pinned (it may also change it)
   a descendent routine should call GetScanStop to unpin and reset fCurrentRID.pid after the last scan

 Assumes:
   the file has been created/opened already and a scan has been started
}
const routine=':GetScanNext';
begin
  result:=ok;
  if fCurrentRID.pid=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    //log.add(st.who,where+routine,'Scan has not been started',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    //note: can't tell difference between not started and started empty
    noMore:=True;
  end;
  rid:=fCurrentRID;
end; {GetScanNext}

function TDBFile.GetScanStop(st:TStmt):integer;
{Finalises a scan by unpinning the latest pinned data page of the file

 RETURN   : +ve=ok, else fail

 Assumes:
   the file has been created/opened already
}
const routine=':GetScanStop';
begin
  result:=Fail;
  if fCurrentRID.pid=InvalidPageId then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Scan of %s is not in progress - nothing to unpin',[fname]),vDebugError);
    {$ENDIF}
    {$ENDIF}
    result:=ok; //21/06/99- return ok, in case we came to end of file & it was empty
                //todo: maybe only ok if noMore=True - so pass it in!
    exit;
  end;

  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,fCurrentRID.pid)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed unpinning page %d from existing %s scan - continuing',[fCurrentRID.pid,fname]),vDebugError);
    {$ENDIF}
  end
  else
  begin
    {Reset the current RID}
    fCurrentRID.pid:=InvalidPageId;
    fCurrentRID.sid:=InvalidSlotId;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Stopped %s scan',[fname]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end;
end; {GetScanStop}

//todo realise AddRecord here!
// remember that a file could be:
// heap, hash, b-tree index etc.

function TDBFile.debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
const routine=':debugDump';
var
 dirSlotCount:integer;
 lastDirPage:pageId;

 page:TPage;
 fileDir:TfileDir;
 dirPageOffset:integer; //page jump count
 dirPage,prevLastSlotDirPage:PageId;

 i:DirSlotId;
begin
  result:=ok;

  if connection<>nil then
  begin
    connection.WriteLn(format('Start page=%d',[fStartPage]));
    DirCount(st,dirSlotCount,lastDirPage,prevLastSlotDirPage,False{don't retry to get accurate figure});

    {Show dir map}
    if fStartPage<>InvalidPageId then
    begin
      dirPage:=fStartPage;
      dirPageOffset:=0;
      connection.Writeln('Directory page: '+intToStr(dirPage));

      with Ttransaction(st.owner).db.owner as TDBserver do
      begin
        {Ok, now get the dir slot}
        if buffer.pinPage(st,dirPage,page)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading dir page %d',[dirPage]),vDebugError);
          {$ENDIF}
          connection.WriteLn(format('Failed reading directory page %d',[dirPage]));
          exit; //abort //todo continue some how...
        end;
        try
          i:=0;
          while (i<=FileDirPerBlock-1) do
          begin
            page.AsBlock(st,i*sizeof(fileDir),sizeof(fileDir),@fileDir);
            connection.Write(format('%d(%d) ',[fileDir.pid,fileDir.space]));

            inc(i);

            if i=FileDirPerBlock then
            begin
              connection.Writeln;
              connection.Writeln('Next directory page: '+intToStr(page.block.nextPage));
              begin
                {Try to read the next page}
                if page.block.nextPage<>InvalidPageId then
                begin
                  dirPage:=page.block.nextPage;
                  buffer.unpinPage(st,page.block.thisPage{dirPage});
                  if buffer.pinPage(st,dirPage,page)<>ok then
                  begin //note: this will fail the unpin below!
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading next dir page %d',[dirPage]),vDebugError);
                    {$ENDIF}
                    connection.WriteLn(format('Failed reading next directory page %d',[dirPage]));
                    exit; //abort
                  end;
                  inc(dirPageOffset);
                  i:=0;
                end; //else at end of dir. Will exit main loop
              end;
            end;
          end; {while}
        finally
          buffer.unpinPage(st,dirPage);
        end; {try}
        connection.Writeln;
      end; {with}
    end; //else nothing allocated to this file=error!

    connection.WriteLn(format('Last directory page=%d',[lastDirPage]));
    connection.WriteLn(format('Data pages allocated=%d',[dirSlotCount]));
  end;
end; {debugDump}


end.

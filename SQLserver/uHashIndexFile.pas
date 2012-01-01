unit uHashIndexFile;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Hashed index file
 Currently uses extendible hashing - may change in future
 Initially implemented for primary/unique/foreign-key lookups during constraint
 checking.

 Indexes are used internally throughout, so these routines must be very solid,
 else very strange things will happen...

 Note: these indexes are noisy, but duplicate keys for the same rid are prevented.

 todo: wrap assertions in IFDEF SAFETY after development testing ok
}

{$DEFINE SAFETY}
//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2} //directory doubling/split testing
//{$DEFINE DEBUGDETAIL3} //slot packing after split & during insert
//{$DEFINE DEBUGDETAIL4} //dump after open!

//{$DEFINE DEBUGDETAIL5} //worthsplitting
//{$DEFINE DEBUGDETAIL6} //buffer status &/or index dump after each insert!
//{$DEFINE DEBUGDETAIL7} //lookup detail
//{$DEFINE DEBUGDETAIL8} //lookup/scan summary
//{$DEFINE DEBUGDETAIL9} //dump to log
//{$DEFINE DEBUGDETAIL10} //debug hash algorithm
//{$DEFINE DEBUGDETAIL11} //delete detail
//{$DEFINE DEBUGDETAIL12} //iteration loop detail


interface

uses uIndexFile, uStmt, uGlobal, uGlobalDef, uPage, uTuple, IdTCPConnection{debug only};

const
  THashIndexFileDirSize=sizeof(pageId);
  //note: if we make HashIndexFileDirPerBlock a multiple of 2, then we can use SHR to DIV and get MOD faster...
  HashIndexFileDirPerBlock=BlockSize div THashIndexFileDirSize;
  THashSlotSize=sizeof(cardinal)+sizeof(Trid); //Note: sizeof(Trid) currently wastes 2 bytes
  //note: if we make HashSlotPerBlock a multiple of 2, then we can use SHR to DIV and get MOD faster...
  HashSlotPerBlock=BlockSize div THashSlotSize;

  {TODO:
   calculate maximum capacity (without overflows)
    =ceiling(HashIndexFileDirPerBlock-1,power of 2) * HashSlotPerBlock-1
    =number of pages in table

    for 512 blocks= maybe 10 rows per page
      124-1 = 64 * 41 = 2624 = around 26240 rows
      and again for each extra bucket directory page, e.g. 5248

    for 4096 blocks= maybe 100 rows per page
      1024-1 = 512 * 341 = 174592 = around 17459200 rows
      and again for each extra bucket directory page, e.g. 349184
  }

type
  {Within 1st page (chain) - hash bucket index}
  ThashIndexFileDir=record   //note: see THashIndexFileDirSize above - keep in sync!!
    pid:PageId;
  end; {TfileDir}
  {ThashIndexFileDir[0]=hash-bucket-dir header, 1..N = buckets available
                                                     ThashIndexFileDir[0].pid=extendible-hash-global-depth => 2^this = N
  }
  HashBucketId=word;

  {Within a page - hash key + RID}
  THashSlot=record  //note: see THashSlotSize above - keep in sync!!
    HashValue:cardinal;//hash value (1st few bits give bucket)
    RID:Trid;          //record pointer
    //note: in future, may add timestamp/full-key here to save false reads...
  end; {TSlot}
  {HashSlot[0]=hash-slot header, 1..N = used hash-slots   hashSlot[0].hashValue=N i.e. count
                                                          hashSlot[0].RID.pid=extendible-hash-local-depth
  }
  HashSlotId=cardinal; //limits max per overflow chain

  THashIndexFile=class(TIndexFile)
  private
    fHashValue:cardinal; //current hash value from last findStart
    fPid:PageId;         //current hash scan page
    //note: uses TDBfile.fCurrentPage for current page storage
    fhsId:HashSlotId;    //current hash scan hash slot
    fhsHeader:THashSlot; //current hash scan root page header (contains page-chain count for findNext)
    fdirpage:TPage;      //current hash dir page for duplicate scan
    fhashBucket:cardinal;//current bucket for duplicate scan
    fHashPrevious:THashSlot; //previous duplicate hash slot for duplicate scan & normal scan
    fglobalDepth:pageId;     //global depth for duplicate scan (read from 1st dir page during start)

    function extendDirectory(st:TStmt;var id:PageId):integer;
    function allocateBucket(st:TStmt;localDepth:pageId;var id:PageId):integer;
    function Hash(t:TTuple):cardinal;
    function slotCompare(ahashvalue:cardinal;arid:Trid;b:THashSlot):integer;
  public
    statHashClash:integer;     //count number of misses due to hash clash (i.e. found tuple does not match)
    statVersionMiss:integer;   //count number of misses due to wrong version (e.g. found to be too old/young/deleted/uncommitted etc.)

    function Dump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;

    function createFile(st:TStmt;const fname:string):integer; override;
    function deleteFile(st:TStmt):integer; override;
    function openFile(st:TStmt;const filename:string;startPage:PageId):integer; override;
    function freeSpace(st:TStmt;page:TPage):integer; override;

    function AddKeyPtr(st:TStmt;t:TTuple;rid:Trid):integer; override;

    {DeleteKey notes (may be out of date)
       need to ensure we don't leave overflow pages that are empty (check full test assumes all are used)
    }

    function FindStart(st:TStmt;FindData:TTuple):integer; override;
    function FindNext(st:TStmt;var noMore:boolean;var RID:Trid):integer; override;
    function FindStop(st:TStmt):integer; override;

    function FindStartDuplicate(st:TStmt):integer; override;
    function FindNextDuplicate(st:TStmt;var noMore:boolean;var RID1,RID2:TRid):integer; override;
    function FindStopDuplicate(st:TStmt):integer; override;
  end; {THashIndexFile}

implementation

uses uLog, SysUtils, Math {for power}, uServer, uTransaction,
uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for date/time structures}
;

const
  who='';
  where='uHashIndexFile';


function THashIndexFile.createFile(st:TStmt;const fname:string):integer;
{Creates a hash index file in the specified database
 IN       : db                  the database
          : fname               the new filename
 RETURN   : +ve=ok, else fail
}
const
  routine=':createFile';
  InitialGlobalDepth=1; //i.e. allocate 2^1 bucket pages & set bucket directory size=2^1
//  InitialGlobalDepth=3; //i.e. allocate 2^3 bucket pages & set bucket directory size=2^3
  //note: make 2+ to prevent early duplicate-overflow dead-end
  //todo: pass initialGlobalDepth from caller!
var
  page:Tpage;
  pid,bucketPid:PageId;

  hashIndexFileDir:THashIndexFileDir;
  dirSlot:DirSlotId;
  dirPageId,prevDirSlotPageId:PageId;
  i:integer;
begin
  result:=inherited CreateFile(st,fname);
  if result<>ok then exit; //abort

  result:=Fail; //default

  //todo: assert 2^InitialGlobalDepth <= HashIndexFileDirPerBlock
  //      otherwise we would need extra bucket-dir-pages & currently assume 1
  //      - also add this assumption to routine header comments!

  //todo write hash bucket directory page
  //todo call extendDirectory instead of below...

    {No page with room was found, so we allocate and add a new one}
    if Ttransaction(st.owner).db.allocatePage(st,pid)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed allocating new page',vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit;
    end;
    {Initialise this new page as a hashIndexFile directory page}
    with (Ttransaction(st.owner).db.owner as TDBserver) do
    begin
      if buffer.pinPage(st,pid,page)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading new page to initialise it, %d',[pid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;
      try
        {Ok, add the page to the file's directory}
        {Note: we do this now because this must be the 1st data page added to this file, because
         we assume dirSlot=0=start of bucket-directory}
        if DirPageAdd(st,pid,freespace(st,page),prevDirSlotPageId,dirPageId,dirSlot)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Failed allocating new bucket directory page to page dir',vError);
          {$ENDIF}
          exit;
        end;
        //todo: assert dirSlot=0!
        {Initialise blank directory page}
        if page.latch(st)=ok then //note: no real need since newpage=local/new?
        begin
          try
            page.block.pageType:=ptIndexData; //todo: use new type, e.g. ptHashIndexFileDir?

            {Write zeroised bucket pointers}
            hashIndexFileDir.pid:=InvalidPageId;
            for i:=0 to HashIndexFileDirPerBlock-1 do
            begin
              page.SetBlock(st,i*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
            end;

            {Create initial hash-directory}
            {Write hash-directory header}
            hashIndexFileDir.pid:=InitialGlobalDepth; //global-depth => # buckets = 2^global-depth
            page.SetBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);

            {Write allocate initial bucket pages and set bucket directory pointers}
            for i:=0 to trunc(power(2,InitialGlobalDepth))-1 do
            begin
              if allocateBucket(st,InitialGlobalDepth,bucketPid)<>ok then
                exit; //abort
              //Note: we don't set the new page's prevPage to itself here (maybe we should?) - no point until we have a proper chain
              hashIndexFileDir.pid:=bucketPid;
              page.SetBlock(st,(i+1){0 is reserved for dir-header}*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
            end;
          finally
            page.unlatch(st);
          end; {try}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Initialised hash file with bucket directory global depth=%d',[InitialGlobalDepth]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          page.dirty:=True;
          result:=ok;
        end
        else
          exit; //abort
      finally
        buffer.unpinPage(st,pid);
      end; {try}
    end; {with}

  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Hash-index-file %s created',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {createFile}

function slotToPageSlot(slot:HashSlotId):HashSlotId;
{Needed to map chain-scale slot-id to page slot-id for writing
 and some reading (but most reads count separately per page)

 Note: if we based everything at 0 this might not be needed...
}
begin
  result:=slot MOD (HashSlotPerBlock-1);
  if result=0 then result:=(HashSlotPerBlock-1);
end; {slotToPageSlot}

function bucketToDirBucket(bucket:HashBucketId):HashBucketId;
{Needed to map dir-scale bucket-id to dir page slot-id for writing
 and some reading (but most reads count separately per page)

 Note: if we based everything at 0 this might not be needed...
}
begin
  result:=bucket MOD (HashIndexFileDirPerBlock-1);
  if result=0 then result:=(HashIndexFileDirPerBlock-1);
end; {bucketToDirBucket}

function THashIndexFile.deleteFile(st:TStmt):integer;
{Deletes a hash index file in the specified database
 IN       : db                  the database
          : fname               the new filename
 RETURN   : +ve=ok, else fail
}
const
  routine=':deleteFile';
var
  page:Tpage;
  pid,bucketPid,nextfPid:PageId;

  dirSlot:DirSlotId;
  dirPageId:PageId;
  i:integer;

  hashMap:cardinal;
  dirpid:pageId;
  space:word;
  dirpage:TPage;
  hashIndexFileDir,hd:THashIndexFileDir;
  globalDepth,localDepth:pageId;
  hsHeader,hs:THashSlot;

  overflowCount:cardinal;
  noMoreOverflow:boolean;

  lastPid:PageId;
begin
  result:=Fail; //default

  {Structure summary:
  dirslot[0]=start of bucket-directory  (currently type=ptIndexData)
  each bucket-dir page:
    0:hashIndexFileDir.pid=globalDepth
    for i:=0 to trunc(power(2,InitialGlobalDepth))-1 do
    //for i:=1 to HashIndexFileDirPerBlock-1 do
      i+1:hashIndexFileDir.pid -> chain of index data pages


  Note: the following was based on the dump code.
        It runs in such as way as to be recoverable after a crash, i.e. links are kept consistent (hopefully!)
  }
  result:=self.DirPage(st,InvalidPageId,0,dirpid,space); //get 1st dir slot page = 1st bucket dir page
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ENDIF}
    exit; //abort
  end;
  if dirpid<>InvalidPageId then //only if we have the bucket dir
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[dirpid]),vError);
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read hash-directory header}
      dirpage.AsBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
      globalDepth:=hashIndexFileDir.pid; //global-depth => # buckets = 2^global-depth
      {$IFDEF DEBUGDETAIL11}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Global depth: %d (%d entries)',[globalDepth,trunc(power(2,globalDepth))]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      {Go through the bucket directory and zap each bucket page chain}
      for hashMap:=0 to trunc(power(2,globalDepth))-1 do
      begin
        overflowCount:=0; //indent level

        if (((hashMap+1) MOD (HashIndexFileDirPerBlock-1))=1) and ((hashMap+1)<>1) then
        begin //need next dir page
          if dirpage.block.nextPage=InvalidPageId then
          begin //error - not enough pages for count! Possibly crashed during last attempt so ignore...
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('No more directory pages after %d, but count says there should be %d slot entries & we have only read %d so far - continuing with the deletion...',[dirpage.block.thispage,trunc(power(2,globalDepth)),hashMap+1]),vDebugError);
            {$ENDIF}
            break; //continue with the deallocation... just abandon any further bucket slot reading...
          end;
          dirpid:=dirpage.block.nextPage;
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpage.block.thisPage);
          {Now we can deallocate this directory page}
          if self.DirPageRemove(st,dirpage.block.thisPage,0)<>ok then exit; //reset 1st dir slot - we will move the next dir page here
          //note: temporarily lost the rest of the index directory! But can be sure that no-one else will flush our garbage startpage before we do: (at least when transaction flushing is implemented)
          if Ttransaction(st.owner).db.deAllocatePage(st,dirpage.block.thisPage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed de-allocating index file page',vError);
            {$ENDIF}
            exit;
          end;
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket directory page %d [next]',[dirpid]),vError);
            {$ENDIF}
            exit; //abort
          end;
          {Now re-point the directory start to this directory page (in case we crash & restart)}
          //Note: this next bit is a bit dodgy: we should use a file.dirPageSwap routine(?)
          if self.DirPageSet(st,InvalidPageId,0,dirpid,freespace(st,dirpage),True{don't check})<>ok then exit; //set 1st dir slot page = new 1st bucket dir page
          if self.DirPageFindFromPID(st,dirpage.block.thisPage,dirPageId,dirSlot)<>ok then exit; //find previous slot for this new dir page
          if self.DirPageRemove(st,dirpage.block.thisPage,dirSlot)<>ok then exit; //reset the previous slot - we have moved it to slot 0 //Note: currently if this is 1st slot on an extended file directory page, the page will be deleted!
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.flushPage(st,startPage,nil);
          //note: also should flush the dirpage containing dirSlot: if we can't find it out, flush all!
          // - worst case=double entry for same page: de-allocation will remove 1st one, so file dir-page won't be empty...
        end;

        dirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);
        fpid:=hd.pid;
        {Now pin the bucket page}
        if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
          {$ENDIF}
          exit; //abort
        end;

        {Zap this page and any overflow pages}
        {Read hash-slot header}
        fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
        localDepth:=hsHeader.RID.pid;

        {Note: we've no need to go through the slots: just remove pages from the chain
        }
        begin
          fhsId:=1; //start at 1st hash slot
          //while fhsId<=hsHeader.hashValue do
          while fCurrentPage.block.nextPage<>InvalidPageId do
          begin
            //fCurrentPage.AsBlock(st,slotToPageSlot(fhsId)*sizeof(hs),sizeof(hs),@hs);

            //inc(fhsId);
            //if ((fhsId MOD (HashSlotPerBlock-1))=1) and (fhsId<>1) then
            begin //end of this read page, move to next one
              //if fCurrentPage.block.nextPage<>InvalidPageId then
              begin //get and pin next overflow page in this chain
                inc(overflowCount);

                lastPid:=fCurrentPage.block.prevPage; //i.e. save root page's prev pointer to end of chain
                nextfPid:=fCurrentPage.block.nextPage; //save before we unpin
                (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid); //un-pin current page
                {Now we can deallocate this page}
                if dirpage.latch(st)<>ok then //would be faster to latch once at start of routine
                  exit; //abort - todo make more resiliant?
                try
                  {Re-point the bucket page to the next in the chain, i.e. skip this one before it's de-allocated}
                  hd.pid:=nextfPid;
                  dirpage.SetBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);
                  {$IFDEF DEBUGDETAIL11}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Linking root to page (%d) to skip page (%d)',[hd.pid,fpid]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  dirPage.dirty:=True;
                finally
                  dirpage.unlatch(st);
                end; {try}

                if self.DirPageFindFromPID(st,fPid,dirPageId,dirSlot)<>ok then exit; //find slot for this page
                if self.DirPageRemove(st,fPid,dirSlot)<>ok then exit; //reset the slot //Note: currently if this is 1st slot on an extended file directory page, the page will be deleted!
                if Ttransaction(st.owner).db.deAllocatePage(st,fPid)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'Failed de-allocating index file page',vError);
                  {$ENDIF}
                  exit;
                end;

                fpid:=nextfPid;
                if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
                  {$ENDIF}
                  exit; //abort
                end;
                if fCurrentPage.latch(st)<>ok then
                  exit; //abort - todo make more resiliant?
                try
                  {Re-point the new root page to the last in the chain}
                  fCurrentPage.block.prevPage:=lastPid;
                  {$IFDEF DEBUGDETAIL11}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Linking end-of-chain-page (%d) to new root(%d).prevPage',[lastPid,fpid]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  fCurrentPage.dirty:=True;
                finally
                  fCurrentPage.unlatch(st);
                end; {try}
                (Ttransaction(st.owner).db.owner as TDBServer).buffer.flushPage(st,dirpid,nil);
                (Ttransaction(st.owner).db.owner as TDBServer).buffer.flushPage(st,fpid,nil);
              end
            end;
          end;
        end;
        //else skip detail

        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid); //un-pin current page
        {Now we can deallocate this page}
        if self.DirPageFindFromPID(st,fPid,dirPageId,dirSlot)<>ok then exit; //find slot for this page
        if self.DirPageRemove(st,fPid,dirSlot)<>ok then exit; //reset the slot //Note: currently if this is 1st slot on an extended file directory page, the page will be deleted!
        if Ttransaction(st.owner).db.deAllocatePage(st,fPid)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Failed de-allocating index file page',vError);
          {$ENDIF}
          exit;
        end;
        if dirpage.latch(st)<>ok then //would be faster to latch once at start of routine
          exit; //abort - todo make more resiliant?
        try
          {Reset the bucket page}
          hd.pid:=InvalidPageId;
          dirpage.SetBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);
          {$IFDEF DEBUGDETAIL11}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Resetting bucket slot %d',[(hashMap+1)]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          dirPage.dirty:=True;
        finally
          dirpage.unlatch(st);
        end; {try}
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.flushPage(st,dirpid,nil);
      end;

      result:=ok;
    finally
      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpid);
    end; {try}

    if result=ok then
    begin
      {Now we can deallocate this directory page}
      if self.DirPageFindFromPID(st,dirPid,dirPageId,dirSlot)<>ok then exit; //find slot for this directory page
      {Note: this is the last directory page so it should be at dirSlot=0, so assert! (we will have moved it there if there was originally more than 1 dir page)}
      if self.DirPageRemove(st,dirPid,dirSlot)<>ok then exit; //reset the slot //Note: currently if this is 1st slot on an extended file directory page, the page will be deleted!
      if Ttransaction(st.owner).db.deAllocatePage(st,dirpid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed de-allocating index file page',vError);
        {$ENDIF}
        exit;
      end;
      {The above should have re-set the directory start}
    end;
  end
  else
    {there are no data pages for this file (yet) - should never happen for this type of file
     - so assertion!}
    ;

  result:=inherited DeleteFile(st);
  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Hash-index-file %s deleted',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {deleteFile}

function THashIndexFile.extendDirectory(st:TStmt;var id:PageId):integer;
{Allocate a new page for this file directory and format it as a new directory page
 IN:

 OUT:   id             - new page id
}
const routine=':extendDirectory';
var
  newpid:PageId;
  newPage:TPage;
  hashIndexFileDir:THashIndexFileDir;
  dirSlot:DirSlotId;
  dirPageId,prevDirSlotPageId:PageId;
  i:integer;
begin
  id:=InvalidPageId; //note not required, but safer
  result:=Fail;

  {Allocate and add a new page}
  if Ttransaction(st.owner).db.allocatePage(st,newpid)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed allocating new page',vError);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {Initialise this new page as a hashIndexFile directory page}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,newpid,newpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading new page to initialise it, %d',[newpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {Ok, add the page to the file's directory}
      if DirPageAdd(st,newpid,freespace(st,newpage),prevDirSlotPageId,dirPageId,dirSlot)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Failed allocating new bucket directory page to page dir',vError);
        {$ENDIF}
        exit;
      end;
      {Initialise blank directory page}
      if newpage.latch(st)=ok then //note: no real need since newpage=local/new?
      begin
        try
          newpage.block.pageType:=ptIndexData; //todo: use new type, e.g. ptHashIndexFileDir?

          {Write zeroised bucket pointers}
          hashIndexFileDir.pid:=InvalidPageId;
          for i:=0 to HashIndexFileDirPerBlock-1 do
          begin
            newpage.SetBlock(st,i*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
          end;
          newpage.dirty:=True;
        finally
          newpage.unlatch(st);
        end; {try}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Extended hash file with directory page %d',[newpid]),vDebugLow);
        {$ENDIF}

        id:=newpid;

        result:=ok;
      end
      else
        exit; //abort
    finally
      buffer.unpinPage(st,newpid);
    end; {try}
  end; {with}
end; {extendDirectory}


function THashIndexFile.openFile(st:TStmt;const filename:string;startPage:PageId):integer;
{Opens a hash index file in the specified database
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

    //goto bucket directory page? always = dirSlot=0

    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    self.dump(st,nil);
    {$ENDIF}
    {$ENDIF}
  end;
end; {openFile}

function THashIndexFile.freeSpace(st:TStmt;page:TPage):integer;
{Returns amount of free record space in the specified page
 IN      : page    the page to examine
 RETURN  : the amount of free space

 Note: this is not necessarily contiguous free space

 Assumes:
   we have the page pinned
   (& latched if we are going to make use of the result...)
}
const routine=':freeSpace';
var
  parentFreeSpace:integer;
begin
  parentFreeSpace:=inherited freeSpace(st,page); //starting point
  result:=parentFreeSpace;

  result:=0; //for now... i.e. better for client to fail if it calls this than to assume space is available

  //note if page[1] then n/a? or return free buckets?
end; {FreeSpace}


function THashIndexFile.allocateBucket(st:TStmt;localDepth:pageId;var id:PageId):integer;
{Allocate a new page for this file and format it as a new bucket
 IN:    localDepth     - initial page local-depth
                         Note: type=pageId=>integer (only pageId because we overuse hash-slot [0]'s pid

 OUT:   id             - new page id
}
const routine=':allocateBucket';
var
  newpid:PageId;
  newPage:TPage;
  dirSlot:DirSlotId;
  dirPageId,prevDirSlotPageId:PageId;

  hsHeader:THashSlot;
begin
  id:=InvalidPageId; //not required, but safer
  result:=Fail;

  {Todo move!}
  if THashSlotSize<>sizeof(hsHeader) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('THashSlotSize[%d]<>sizeof(hsHeader)[%d]',[THashSlotSize,sizeof(hsHeader)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  if Ttransaction(st.owner).db.allocatePage(st,newpid)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed allocating new file page',vError);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  {Initialise this new page as a bucket page}
  with (Ttransaction(st.owner).db.owner as TDBserver) do
  begin
    if buffer.pinPage(st,newpid,Newpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading new file page to initialise it, %d',[newpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      //todo remove: debug only!
      {$IFDEF SAFETY}
      {$IFDEF DEBUG_LOG} //todo: what if live?
      if (Newpage.block.nextPage<>InvalidPageId) or (Newpage.block.prevPage<>InvalidPageId) then
        log.add(st.who,where+routine,format('...newly allocated bucket page %d still has page links %d and %d (type=%d)! - continuing with risk of corruption...',[newpid,Newpage.block.prevPage,Newpage.block.nextPage,Newpage.block.pageType]),vAssertion);
      {$ENDIF}
      {$ENDIF}

      {Initialise blank bucket page}
      if newpage.latch(st)=ok then //note: no real need since newpage=local/new?
      begin
        try
          newpage.block.pageType:=ptIndexData;

          {Write blank hash-slot header}
          hsHeader.hashValue:=0; //hash-slot count
          hsHeader.RID.pid:=localDepth;
          hsHeader.RID.sid:=InvalidSlotId;  //unused

          newpage.SetBlock(st,0,sizeof(hsHeader),@hsHeader);

          //rest of page is left zeroised
          newpage.dirty:=True;
        finally
          newpage.unlatch(st);
        end; {try}

        {Ok, add the page to the file's directory}
        if DirPageAdd(st,newpid,freespace(st,newpage),prevDirSlotPageId,dirPageId,dirSlot)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Failed allocating new page to page dir',vError);
          {$ENDIF}
          exit;
        end;

        id:=newpid;

        result:=ok;
      end
      else
        exit; //abort

      //Note: the prev/next page links are not used in this file's data pages
      // (except bucket directory header if it grows past initial 1 page
      //  and except overflow pages needed when bucket is full of same hashvalue)
    finally
      buffer.unpinPage(st,newpid);
    end; {try}
  end; {with}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Extended hash file with bucket page %d, local depth %d',[newpid,localDepth]),vDebugLow);
  {$ENDIF}
end; {allocateBucket}

function THashIndexFile.Hash(t:TTuple):cardinal;
{Hash function

 RETURNS:     0=fail, else hash value

 Based on djb2 algorithm which is supposed to be good

 Assumes:
   length returned from TTuple.getDataPointer is in bytes
}
const routine=':Hash';
var
  i:integer;
//  pv:byte;
//  p:^byte;
  pv:char;
//  pvi:integer;
  p:pchar;
  len,j:ColOffset;
  isnull:boolean;
  isString:boolean;

  //todo remove need for these: speed
  dt:TsqlDate;
  tm:TsqlTime;
  ts:TsqlTimestamp;
  dayCarry:shortint;
  s:string;
begin
  result:=5381;
  for i:=1 to colCount do
  begin
    isString:=(DataTypeDef[t.fColDef[colMap[i].cref].dataType] in [stString])
              or (t.fColDef[colMap[i].cref].dataType in [ctClob]);

    if DataTypeDef[t.fColDef[colMap[i].cref].dataType] in [stDate,stTime,stTimestamp] then
    begin //we need to hash the string representation (else got different answers each time! -not sure why...)
      case DataTypeDef[t.fColDef[colMap[i].cref].dataType] of
        stDate:      begin t.GetDate(colMap[i].cref,dt,isnull); s:=format(DATE_FORMAT,[dt.year,dt.month,dt.day]); end;
        stTime:      begin t.GetTime(colMap[i].cref,tm,isnull); s:=sqlTimeToStr(TIMEZONE_ZERO,tm,t.fColDef[colMap[i].cref].scale,dayCarry); end;
        stTimestamp: begin t.GetTimestamp(colMap[i].cref,ts,isnull); s:=sqlTimestampToStr(TIMEZONE_ZERO,ts,t.fColDef[colMap[i].cref].scale); end;
      end; {case}
      t.colIsNull(colMap[i].cref,isnull);
      len:=length(s);
      p:=pchar(s);
    end
    else //get direct pointer to raw data
      if t.GetDataPointer(colMap[i].cref,pointer(p),len,isnull)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Failed reading column data %d',[i]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=0; //=don't use
        exit; //abort, pointer is unsafe to use
      end;

    if not isnull then
      for j:=0 to len-1 do
      begin
        pv:=p^;

        {Note: we uppercase any text characters to ensure index searches ignore case}
        if isString then pv:={byte(}upcase(char(pv)){)}; //todo assembly=speed
        //todo: should also ignore trailing spaces, i.e. NO PAD, so that user passed values will match properly
        //todo: ensure/check that caller converts comparand type to match the index type, e.g. date & string don't directly hash-compare this way here...

        {$IFDEF DEBUGDETAIL10}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Hashing byte %d %s',[j,char(pv)]),vDebugLow); //assertion?
        {$ENDIF}
        {$ENDIF}

        //pvi:=ord(pv);  //copy to 4-byte integer because assembly ADD wouldn't accept DWORD cast in Kylix beta //todo re-instate:speed
        {We use assembly here because:
           1. it prevents Delphi from raising overflow exceptions that we'd otherwise need to trap with expensive try...excepts
           2. it's fast!
         todo: use assembly to control the loop and key-character access...
         Note: downside = less portable (but simple to port!)
        }
        asm //result:=result + (result shl 5) + p^; //hash * 33 + c
          MOV EAX,result
          MOV ECX,result
          SHL ECX,5
          ADD ECX,DWORD(pv)
          //todo remove: no need after Kylix released: ADD ECX,pvi
          ADD EAX,ECX
          MOV @result,EAX
        end; {asm}
      (*todo remove once assembly code is working...
        try
          result:=result + (result shl 5) + p^; //hash * 33 + c
        except //todo: maybe we need $Q+ to be able to trap this correctly?
          //continue, even if we have overflow...
        end;
      *)
        inc(p);
      end;
  end;
  if result=0 then result:=1; //avoid returning 0 = failure!

  {$IFDEF DEBUGDETAIL10}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Hash result=%d',[result]),vDebugLow); //assertion?
  {$ENDIF}
  {$ENDIF}
end; {Hash}

function THashIndexFile.slotCompare(ahashvalue:cardinal;arid:Trid;b:THashSlot):integer;
{Hash key/rid comparison function: needed for ordering the keys within page chains

 RETURNS:     -ve= a<b
                0= a=b
              +ve= a>b

 Notes: includes rid in the comparison to allow duplicate entries to be spotted/prevented
        still use hashvalue compares for finding routines
}
const routine=':slotCompare';
begin
  result:=0;

  if ahashvalue>b.HashValue then
    result:=+1
  else
    if ahashvalue<b.HashValue then
      result:=-1
    else //result=0
      if arid.pid>b.rid.pid then
        result:=+1
      else
        if arid.pid<b.rid.pid then
          result:=-1
        else //result=0
          if arid.sid>b.rid.sid then
            result:=+1
          else
            if arid.sid<b.rid.sid then
              result:=-1;
end; {slotCompare}

function THashIndexFile.AddKeyPtr(st:TStmt;t:TTuple;rid:Trid):integer;
{Add a new key+ptr to this file

 IN:     tr             - transaction
         t              - tuple containing key data
         rid            - rid

 RETURN: ok, else fail

 Notes:
   re-written to ensure page overflow chains are in order
     first page in chain has slot 0 storing count and local depth
     rest of pages in chain have slot 0 unused (although local depth is correct (but not used?))
     i.e. we treat the overflow chain of pages as part of the root page = faster searching (slower inserts maybe, but more effective splitting)

 todo: if we abort without inserting the new key it would be better to
       set the index status to 'dodgy-needs a rebuild' rather than just failing...!
       i.e. better to degrade to table scanning correctly than have missing rows
}
const routine=':AddKeyPtr';
  function worthSplitting(rPid:PageId;newDepth:pageId;var lastP:Tpage):boolean;
  {Checks whether it's worth splitting this page/chain

   IN:         rPid     - page id of start of chain
               newDepth - candidate depth to check against
   OUT:        lastP    - last page in chain
                          (only if result=False)
   RETURNS:    True - worth splitting, else False

   Side-effects:
     if result=False then we leave the last page in the chain pinned and return a pointer to it
     (so the caller can append an overflow page) - we'd need to read it anyway to prove result=False
     Note: this might be = rPid, so it would be pinned again (assuming caller already pinned it)

   Assumes:
     all pages are full

   Note:
     may need to follow all page chain - doesn't leave all pinned
     //todo may help if it did in a busy environment? since caller may need them again...

   //todo: we should take account of the new key to be inserted -speed
   // i.e. if it is different from all the ones in the chain (and they are the same)
   //      then it would be better in the long-run to split now
   //      rather than add another overflow when we would only split next time anyway
   //      - this logic should be in caller?
  }
  const routine=':worthSplitting';
  var
    newSet,newNotSet,differs:boolean;
    hs,hsFirst:THashSlot;
    nextPid:PageId;
    i:HashSlotId;
  begin
    result:=False; //assume the worst
    newSet:=False;
    newNotSet:=False;
    differs:=False;
    lastP:=nil; //just in case caller tries to use this if we fail - note: caller to check this=failure...

    {If any hash key in any page in the chain has the newDepth-bit set
     then it's worth splitting, but only if:
        at least one hasn't! (so don't just move everything to a new page/chain in case new key belongs there)
                             (and even if new key was only one that didn't need to go in new page - still no benefit!)
                              - so should include new key in this test process!

     otherwise it's not

     - todo: maybe test less, e.g. 1st and last?? speed?
    }

    nextPid:=rPid;

    {If this is a long chain, first check that it's not all the same key = likely, especially for FK indexes}
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,nextPid,lastP)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket page %d',[nextPid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      lastP:=nil; //just to prevent hidden disaster for now...!
      exit; //abort
    end;
    lastP.AsBlock(st,0*sizeof(hs),sizeof(hs),@hs);
    if (hs{Header}.hashValue>(2*(HashSlotPerBlock-1))) then //todo: maybe 3* if faster to read all - especially if likely to spot difference early
    begin
      {$IFDEF DEBUGDETAIL8}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...checking last page %d in long chain',[lastP.block.prevPage]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      lastP.AsBlock(st,1*sizeof(hsFirst),sizeof(hsFirst),@hsFirst); //save 1st key
      if lastP.block.prevPage<>InvalidPageId then
      begin //get and pin last overflow page in this chain
        nextPid:=lastP.block.prevPage;
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,lastP.block.thisPage{nextPid}); //un-pin current page
        if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,nextPid,lastP)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading last bucket page in chain %d',[nextPid]),vError); //assertion?
          {$ENDIF}
          lastP:=nil; //just to prevent hidden disaster for now...!
          exit; //abort //ok? todo: could/should continue with full scan
        end;
      end
      else
      begin //error - no end-chain page link!
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('No end-chain page link from %d - aborting find...',[lastP.block.thispage]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        lastP:=nil; //just to prevent hidden disaster for now...!
        exit; //abort //todo: could/should continue with full scan
              //todo: fix the prevPage ref here - may be corruption after crash...
      end;
      {Now check the last entry in the chain}
      lastP.AsBlock(st,(HashSlotPerBlock-1)*sizeof(hs),sizeof(hs),@hs);
      if (hsFirst.HashValue=hs.HashValue) then
      begin //chain contains same key throughout
        {We've already pinned the last page in the chain, so just return}
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...page/chain would not benefit from split: no differences found (using bit %d) using shortcut long chain test',[newDepth]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        result:=differs{=>false};
        exit; //done early
      end;
      //else continue with full chain check - possible difference in the chain
      //note: could test new bit of both these keys here to try to determine if differs early: speed
    end;
    //else small/average chain - not worth shortcut check

    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,lastP.block.thispage); //unpin this page
    nextPid:=rPid; //start back at root

    repeat
      {$IFDEF DEBUGDETAIL5}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...checking bucket page %d',[nextPid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,nextPid,lastP)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading bucket page %d',[nextPid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        lastP:=nil; //just to prevent hidden disaster for now...!
        exit; //abort
      end;

      {Check all keys in this page}
      i:=1;
      while i<=(HashSlotPerBlock-1) do
      begin
        //speed: maybe we can As whole block & check every xth bit of it in one go?
        lastP.AsBlock(st,i*sizeof(hs),sizeof(hs),@hs);
        if bitSet(hs.hashValue,newDepth-1{+1: bitset starts at 0}) then
          newSet:=True
        else
          if not bitSet(hs.hashValue,newDepth-1{+1: bitset starts at 0}) then
            newNotSet:=True;
        if newSet and newNotSet then differs:=True;
        if differs then break; //found a crucial difference - we can stop now
        inc(i);
      end;
      {$IFDEF DEBUGDETAIL12}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...checked %d keys in page %d for split-difference',[i,lastP.block.thisPage]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      if not differs then
      begin //read next page in chain
        nextPid:=lastP.block.nextPage;
      end;

      (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,lastP.block.thisPage{nextPid}); //unpin this page

    until differs or (nextPid=InvalidPageId);

    {Re-pin the final page if there was no difference = easier for caller to append overflow page}
    if not differs then
    begin
      {$IFDEF DEGUBDETAIL5}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('re-pinning last bucket page in chain: %d',[nextPid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,lastP.block.thisPage,lastP)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading bucket page %d (last in chain)',[nextPid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        //note: what would caller do? assume 2nd to last is last? - disaster?
        lastP:=nil; //just to prevent hidden disaster for now...!
        exit; //abort
      end;
    end;

    {$IFDEF DEBUGDETAIL2}
    if differs then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...page/chain would benefit from split: difference proved in page %d slot %d (using bit %d)',[lastP.block.thisPage,i,newDepth]),vDebugMedium)
      {$ENDIF}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...page/chain would not benefit from split: no differences found (using bit %d)',[newDepth]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
    {$ENDIF}

    result:=differs;
  end; {worthSplitting}

var
  hashValue,hashMap,hashGlobalMask,hashLocalMask:cardinal;
  dirpid,thisDirpid,rootPid,pid,newsplitPid,overflowPid,writePid,blankPid,lastBlankPid:pageId;
  dirskip,space:word;
  dirpage,thisDirpage,rootpage,page,newsplitPage,overflowPage,lastPage,writePage,blankPage:TPage;
  hashIndexFileDir,hd,temphd:THashIndexFileDir;
  globalDepth,localDepth:pageId;
  hsHeader,hs,hssplitHeader:THashSlot;
  hsId,i,icount:HashSlotId;
  foundPage,foundExists:boolean;
  sLow,sHigh,sMiddle:HashSlotId;

  {$IFDEF DEBUGDETAIL10}
  s:string;
  ti:colRef;
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  bv:Tblob;
  dummy_null:boolean;
  {$ENDIF}
begin
  result:=Fail;

  {First calculate the hash value}
  hashValue:=hash(t);

  {$IFDEF DEBUGDETAIL10}
  {$IFDEF DEBUG_LOG}
  //build key display for log (adapted from Ttuple.show)- remove: speed
  s:='';
  for ti:=1 to colCount do
  begin
    if t.fColDef[colMap[ti].cref].dataType in [ctChar,ctVarChar,ctBit,ctVarBit] then
    begin
      t.GetString(colMap[ti].cref,sv,dummy_null);
      s:=s+sv+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctInteger,ctSmallInt] then
    begin
      t.GetInteger(colMap[ti].cref,iv,dummy_null);
      s:=s+intToStr(iv)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctBigInt] then
    begin
      t.GetBigInt(colMap[ti].cref,biv,dummy_null);
      s:=s+intToStr64(biv)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctNumeric,ctDecimal] then
    begin
      t.GetComp(colMap[ti].cref,dv,dummy_null);
      s:=s+floatToStr(dv)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType=ctFloat then
    begin
      t.GetDouble(colMap[ti].cref,dv,dummy_null);
      s:=s+floatToStr(dv)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType=ctDate then
    begin
      t.GetDate(colMap[ti].cref,dtv,dummy_null);
      s:=s+format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day])+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctTime,ctTimeWithTimezone] then
    begin
      t.GetTime(colMap[ti].cref,tmv,dummy_null);
      s:=s+sqlTimeToStr(tmv,t.fColDef[colMap[ti].cref].scale)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctTimestamp,ctTimestampWithTimezone] then
    begin
      t.GetTimestamp(colMap[ti].cref,tsv,dummy_null);
      s:=s+sqlTimestampToStr(tsv,t.fColDef[colMap[ti].cref].scale)+';';
    end;
    if t.fColDef[colMap[ti].cref].dataType in [ctBlob,ctClob] then
    begin
      t.GetBlob(colMap[ti].cref,bv,dummy_null);
      s:=s+format('BLOB:%d:%d(len=%d)',[bv.rid.pid,bv.rid.sid,bv.len])+';';
    end;
  end;
  log.add(st.who,where+routine,format('inserting %d:%d into index %s with hash value of %d (%s)',[rid.pid,rid.sid,name,hashValue,s]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  if hashValue=0 then exit; //abort


  {Find the bucket page id}
  //note: maybe better to use GetScanStart, but leaves 1st data page (=bucket dir page) pinned
  result:=self.DirPage(st,InvalidPageId,0,dirpid,space); //get 1st dir slot page = 1st bucket dir page
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  if dirpid<>InvalidPageId then //only if we have the bucket dir
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[dirpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    (*note: we should really latch dir here in case, but this would bottleneck read-access to whole index
              - so instead we will latch it if and when we need to modify it & check that the globalDepth
                is still the same - else has been modified by someone else during the tiny gap we left = abort (& in future retry!)
    if dirpage.latch(st)<>ok then //Note: we must latch here in case we need to double dir later...
      exit; //abort - todo make more resiliant? also improve try/finally location so we unpin dirpage!!! Note: never risk unlatch without latch=ok first! = hang!: i.e. [latch?/try/finally unlatch] & NEVER [try/latch?/finally unlatch] !
    *)
    try
      foundPage:=False;
      repeat
        {Read hash-directory header}
        dirpage.AsBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
        {$IFDEF SAFETY}
        if dirpage.block.pageType<>ptIndexData then //todo: use new type, e.g. ptHashIndexFileDir?
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('unexpected page type for index page %d',[dirpid]),vAssertion);
          {$ENDIF}
          exit; //abort
        end;
        {$ENDIF}
        globalDepth:=hashIndexFileDir.pid; //global-depth => # buckets = 2^global-depth

        {Hash to bucket page pointer}
        hashGlobalMask:=trunc(power(2,globalDepth))-1;

        hashMap:=(hashGlobalMask AND hashValue); //use last few bits //todo: note not true- depends on endian... no matter until copy directory?...

        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('using global depth of %d, hash value %x AND %x used=%xx',[globalDepth,hashValue,hashGlobalMask,hashMap]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}

        {Find the correct directory page}
        thisDirpid:=dirpid;
        if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[thisDirpid]),vError);
          {$ENDIF}
          exit; //abort
        end;
        for dirskip:=1 to hashMap DIV (HashIndexFileDirPerBlock-1) do
        begin
          thisDirpid:=thisDirpage.block.nextPage;
          //todo assert <>InvalidPage
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpage.block.thisPage);
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket directory page %d [%d]',[thisDirpid,dirskip]),vError);
            {$ENDIF}
            exit; //abort
          end;
        end;

        try
          {Read bucket page pointer}
          //Assumes: do we need +1 below: hashMap is never 0 - reserved for directory header (i.e. count) - 1st page only?
          //         -Yes we do need +1: hashMap can give 0 even though hashValue cannot be...
          //         - so 0 maps to 1st slot, 1 to 2nd etc.
          thisDirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);

          {Store start of page chain}
          rootPid:=hashIndexFileDir.pid; //we use this bucket-start-page - it contains the entry count for the whole chain

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('...so bucket slot %d (dump-ref %d) is used to give root page id %d',[(hashMap+1),(hashMap),rootPid]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}

          {Now read the bucket page and ensure we can insert the key + ptr somewhere in the chain}
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,rootPid,rootpage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket root page %d',[rootPid]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          //note: latch rootpage here? we always will change it?
          //      and we assume it won't change between now & later
          // but should only latch close to action
          // but can't deadlock with self & need to latch to prevent others stealing our slot before we insert/split etc.
          //Note: we must always latch in a fixed order to avoid deadlock
          rootPage.latch(st);
          try
            {Read hash-slot header}
            rootPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
            localDepth:=hsHeader.RID.pid; //todo: assert same for all pages in this overflow chain...
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('...page/chain id %d has %d entries and has local-depth %d',[rootPid,hsHeader.hashValue,localdepth]),vDebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}

            {Note: next test assumes there are never any overflow pages attached that are empty}
            if not( ((hsHeader.HashValue MOD (HashSlotPerBlock-1))=0) and (hsHeader.HashValue<>0) ) then
            begin //page chain is not full, so there is already space in the last page (and we might need to do some shuffling to keep the chain in order)
              foundPage:=True;
            end
            else
            begin //page chain is full, we need to make room...
              //note: why not test with/upto globalDepth since we could split to that if need be, especially for long chains?
              if not worthSplitting(rootPid,localDepth+1,lastPage) then
              begin //add overflow page to end of page/chain
                //todo assert lastPage<>nil = aborted!
                //Note: lastPage might (hopefully!) be rootPage
                {Note: lastPage has been left pinned for us, so latch it now}
                if lastPage<>rootPage then //check not already latched in outer section
                  if lastPage.latch(st)<>ok then //todo: we should really have latched before is-full-checks (else tiny risk of full, then not full here!) //but doesn't matter anyway here!
                    exit; //abort - todo make more resiliant?
                try
                  {Allocate a new overflow bucket and link it to the last in chain page}
                  {Create a new overflow bucket with same local depth}
                  if allocateBucket(st,localDepth,overflowPid)<>ok then
                    exit; //abort
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('...chaining new overflow page %d to page/chain %d by appending to last page=%d...',[overflowPid,rootPid,lastPage.block.thisPage]),vDebugMedium);
                  {$ENDIF}
                  {$ENDIF}
                  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,overflowPid,overflowPage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading new overflow bucket page %d',[overflowPid]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort
                  end;
                  if overflowPage.latch(st)<>ok then //note: no real need since it is a new page
                    exit; //abort - todo make more resiliant?
                  try
                    {Note: each new overflow page is linked at end of any existing overflow chain - this avoids having to read-pin-latch-link a subsequent page
                           also the index scan assumes keys are sequential even across overflow pages}
                    if lastpage.block.nextPage<>InvalidPageId then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Last in overflow chain next page link is not empty (%d)',[lastPage.block.nextPage]),vAssertion);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      exit; //abort
                    end;
                    overflowPage.block.prevPage:=lastPage.block.thisPage; //link backwards to last in bucket chain
                    lastPage.block.nextPage:=overflowPid;      //link forwards from last in bucket chain
                    rootPage.block.prevPage:=overflowPid;      //link root page backwards to new end of bucket chain for quick appending to long chains
                    {$IFDEF DEBUGDETAIL8}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Linking new end-of-chain-page (%d) to root(%d).prevPage',[overflowPid,rootPage.block.thisPage]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}

                    rootPage.dirty:=True;
                    lastPage.dirty:=True;
                    overflowPage.dirty:=True;

                    foundPage:=True;
                  finally
                    overflowPage.unlatch(st);
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,overflowPid);
                  end; {try}
                finally
                  if lastPage<>rootPage then //check not already latched in outer section
                    lastPage.unlatch(st);
                  (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,lastPage.block.thisPage);
                end; {try}
              end {add overflow page}
              else
              begin //split the page/chain
                {We may need to double the directory, and we are definitely
                 going to repoint some searches to a new bucket so
                 we latch the (1st) bucket directory page.
                 This allows us to safely increment the globalDepth and to
                 update a bucket pointer to the new one and also
                 locks out further readers (by suspending reads of 1st directory page)
                 to prevent them reading half-empty pages during the sharing stage
                 Warning: but there may still be readers on the full page (might not be this page?)
                       so ensure it is not pinned by anyone else before
                       continuing (latching is not necessarily good enough), else their next
                       read may report noMore because
                       we might have re-distributed keys to a new page!
                       (++Check using same method used by index rebuild to add partial indexes to existing relations?)
                       Or better to split using 2 new pages?, then old one can
                       be put back to free-pool when no one needs it
                 Note: this dir page latch may be a bottleneck that halts access
                       to crucial data while page splitting is carried out
                 Note: I'm sure we could latch less, especially during a non-dir-double             -speed!
                       e.g. just latch current page (done) and new one (done!)
                       - but only after updating new bucket pointer first so
                         locked reader is trying to read the eventually-correct page
                 Also - just latch thisDirpage, not dirpage would be better until we know we are doubling depth?
                      - but beware of deadlock!
                }
                if dirpage.latch(st)<>ok then //todo: we should really have latched before is-full-check (else tiny risk of full, then not full here!) //but doesn't matter anyway here!
                  exit; //abort - todo make more resiliant?
                try
                  {Allocate a new bucket and share the entries among it and the current bucket page/chain}
                  {Create a new split bucket with incremented local depth}
                  if allocateBucket(st,localDepth+1,newsplitPid)<>ok then
                    exit; //abort
                  //Note: we don't set the new page's prevPage to itself here (maybe we should?) - no point until we have a proper chain

                  {Now share the entries between the two page/chains: page and newsplitPage
                   Note: we leave rootPage,rootPid and newSplitPid alone}
                  pid:=rootPid;

                  //Note: assumes we only split when page/chain is full
                  {Latch target (newsplitPage)}
                  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,newsplitPid,newsplitPage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading new bucket page %d',[newsplitPid]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort
                  end;
                  if newsplitPage.latch(st)<>ok then //note: no real need since it is a new page
                    exit; //abort - todo make more resiliant?
                  try
                    {Now share the entries between the two page/chains}
                    newsplitPage.AsBlock(st,0*sizeof(hssplitHeader),sizeof(hssplitHeader),@hssplitHeader);
                    {Re-read hsHeader - no real need (speed) except to make it clear what's going on}
                    rootPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
                    //todo: assert still same as when pinned!
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('...allocated new page - will split entries from page chain %d (has %d entries) to new page %d (new next check: %d)...',[pid,hsHeader.hashValue,newsplitPid,newSplitPage.block.nextPage]),vDebugMedium);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    {$ENDIF}
                    repeat
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,pid,page)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        exit; //abort
                      end;
                      if page<>rootPage then //check not already latched in outer section
                        if page.latch(st)<>ok then //todo: we should really have latched (root at least) before is-full-checks (else tiny risk of full, then not full here!)
                          exit; //abort - todo make more resiliant?
                      try
                        {Check all keys in this page/chain}
                        i:=1;
                        while i<=(HashSlotPerBlock-1) do
                        begin
                          //speed: maybe we can As whole block & check every xth bit of it in one go?
                          page.AsBlock(st,i*sizeof(hs),sizeof(hs),@hs);
                          if bitSet(hs.hashValue,localDepth{+1: bitset starts at 0}) then //this belongs in new page/chain
                          begin //move this entry from this page/chain to the new page/chain
                            if ((hssplitHeader.HashValue MOD (HashSlotPerBlock-1))=0) and (hssplitHeader.HashValue<>0) then
                            begin //target page is full, add an overflow
                              {$IFDEF DEBUGDETAIL}
                              {$IFDEF DEBUG_LOG}
                              log.add(st.who,where+routine,format('...new page %d is full - adding overflow page...',[newsplitPage.block.thisPage]),vDebugMedium);
                              {$ELSE}
                              ;
                              {$ENDIF}
                              {$ENDIF}
                              //unlatch current
                              //add & link new
                              //latch new
                              {Allocate a new overflow bucket and link it to the last in chain page}
                              {Create a new overflow bucket with same local depth}
                              if allocateBucket(st,localDepth+1,overflowPid)<>ok then
                                exit; //abort
                              {$IFDEF DEBUGDETAIL}
                              {$IFDEF DEBUG_LOG}
                              log.add(st.who,where+routine,format('...chaining new overflow page %d to page/chain %d by appending to last page=%d...',[overflowPid,newsplitPid,newsplitPage.block.thisPage]),vDebugMedium);
                              {$ELSE}
                              ;
                              {$ENDIF}
                              {$ENDIF}
                              if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,overflowPid,overflowPage)<>ok then
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(st.who,where+routine,format('Failed reading new overflow bucket page %d',[overflowPid]),vError);
                                {$ELSE}
                                ;
                                {$ENDIF}
                                exit; //abort
                              end;
                              if overflowPage.latch(st)<>ok then //note: no real need since it is a new page
                                exit; //abort - todo make more resiliant?
                              try
                                {Note: each new overflow page is linked at end of any existing overflow chain - this avoids having to read-pin-latch-link a subsequent page
                                       also the index scan assumes keys are sequential even across overflow pages}
                                if newsplitPage.block.nextPage<>InvalidPageId then
                                begin
                                  {$IFDEF DEBUG_LOG}
                                  log.add(st.who,where+routine,format('Last in overflow chain next page link is not empty (%d)',[newsplitPage.block.nextPage]),vAssertion);
                                  {$ELSE}
                                  ;
                                  {$ENDIF}
                                  exit; //abort
                                end;
                                overflowPage.block.prevPage:=newsplitPage.block.thisPage; //link backwards to last in bucket chain
                                newsplitPage.block.nextPage:=overflowPid;      //link forwards from last in bucket chain
                                //Note: we will set the new root page's prevPage to end of chain once we know the very last page, i.e. when we set the slot count below

                                lastPage.dirty:=True; //todo 28/01/03? newsplitPage not lastPage?
                                overflowPage.dirty:=True;
                                {$IFDEF DEBUGDETAIL}
                                {$IFDEF DEBUG_LOG}
                                log.add(st.who,where+routine,format('...chained new overflow page and setting it to be the current target page...',[nil]),vDebugMedium);
                                {$ENDIF}
                                {$ENDIF}
                              finally
                                {Unlatch previous overflow page}
                                newsplitPage.unlatch(st);
                                (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,newsplitPage.block.thisPage); //unpin this page
                                {Leave new overflow latched, but treat as new page...}
                                newsplitPage:=overflowPage;
                              end; {try}
                            end;
                            {$IFDEF DEBUGDETAIL}
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('...moving entry in page %d slot %d (value=%x) to new page %d at slot %d (because bit %d set)...',[pid,i,hs.hashValue,newsplitPage.block.thisPage,slotToPageSlot(hssplitHeader.hashValue+1),localDepth+1]),vDebugMedium);
                            {$ELSE}
                            ;
                            {$ENDIF}
                            {$ENDIF}
                            hssplitHeader.HashValue:=hssplitHeader.HashValue+1; //increment slot count in new root page
                            //todo: assert not past end of page!
                            newsplitPage.SetBlock(st,slotToPageSlot(hssplitHeader.HashValue)*sizeof(hs),sizeof(hs),@hs); //append entry (already in sorted order)
                            newsplitPage.dirty:=True;
                            hs.HashValue:=0; //empty slot to be tidied/packed
                            page.SetBlock(st,i*sizeof(hs),sizeof(hs),@hs); //write empty slot
                            page.dirty:=True;
                            hsHeader.HashValue:=hsHeader.HashValue-1; //decrement slot count in this page
                          end
                          else
                          begin
                            {$IFDEF DEBUGDETAIL}
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('...leaving entry in page %d slot %d (value=%x) where it is (because bit %d not set)...',[pid,i,hs.hashValue,localDepth+1]),vDebugMedium);
                            {$ELSE}
                            ;
                            {$ENDIF}
                            {$ENDIF}
                          end;

                          inc(i);
                        end;
                        {$IFDEF DEBUGDETAIL12}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('...checked all keys in page %d for split-move',[page.block.thisPage]),vDebugLow);
                        {$ENDIF}
                        {$ENDIF}
                      finally
                        if page<>rootPage then //check not pre-latched in outer section
                          page.unlatch(st);
                        {read next page in chain}
                        pid:=page.block.nextPage;
                        (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,page.block.thisPage{Pid}); //unpin this page
                      end; {try}

                    until pid=InvalidPageId;
                  finally
                    newsplitPage.unlatch(st);
                    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,newsplitPage.block.thisPage); //unpin this page
                  end; {try}

                  {Update page/chain headers}
                  {Re-latch original new page root}
                  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,newsplitPid,newsplitPage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading new bucket page %d',[newsplitPid]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort
                  end;
                  if newsplitPage.latch(st)<>ok then //note: no real need since it is a new page
                    exit; //abort - todo make more resiliant?
                  try
                    newsplitPage.SetBlock(st,0*sizeof(hssplitHeader),sizeof(hssplitHeader),@hssplitHeader); //update slot header
                    newsplitPage.block.prevPage:=overflowPid;      //link new root page backwards to new end of bucket chain for quick appending to long chains

                    newsplitPage.dirty:=True;
                  finally
                    newsplitPage.unlatch(st);
                    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,newsplitPid); //unpin this page
                  end; {try}

                  //todo assert/note rootPage=page
                  try
                    rootPage.SetBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader); //update slot header
                    rootPage.dirty:=True;
                  finally
                  //  rootPage.unlatch(st);
                  end; {try}
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('...after split: page/chain %d has %d entries, new page/chain %d has %d entries...',[rootPid,hsHeader.hashValue,newsplitPid,hssplitheader.hashValue]),vDebugMedium);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}


                  {Now pack the source page/chain to fill in any holes}
                  hsId:=1; //write
                  writePid:=rootPid;
                  {Latch target (writePage)}
                  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading new bucket page %d',[writePid]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort
                  end;
                  if writePage<>rootPage then //check not already latched in outer section
                    if writePage.latch(st)<>ok then
                      exit; //abort - todo make more resiliant?
                  try
                    icount:=0;
                    pid:=rootPid;

                    repeat
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,pid,page)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        exit; //abort
                      end;
                      //Note: we don't latch the read-page in case we trip over write page latches
                      //      -since the root page is latched, & we only read, there's no need anyway
                      {Check all key-slots in this page/chain}
                      i:=1;
                      while i<=(HashSlotPerBlock-1) do
                      begin
                        //speed: maybe we can As whole block & check every xth bit of it in one go?
                        page.AsBlock(st,i*sizeof(hs),sizeof(hs),@hs);

                        if hs.HashValue=0 then
                        begin //hole, shuffle rest down 1 to fill it
                          //leave hsId alone
                          {$IFDEF DEBUGDETAIL3}
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('...skipping hole at page %d slot %d...',[pid,i]),vDebugMedium);
                          {$ELSE}
                          ;
                          {$ENDIF}
                          {$ENDIF}
                        end
                        else
                        begin
                          if ((hsId MOD (HashSlotPerBlock-1))=1) and (hsId<>1) then
                          begin //next target page is needed now, move to it
                            //todo assert nextPage<>invalidPage!
                            if writePage<>rootPage then //check not already latched in outer section: todo no need to check here? cannot be root page?
                              writePage.unlatch(st);
                            writePid:=writePage.block.nextPage;
                            (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,writePage.block.thisPage); //unpin this page
                            if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                            begin
                              {$IFDEF DEBUG_LOG}
                              log.add(st.who,where+routine,format('Failed reading new bucket page %d',[writePid]),vError);
                              {$ELSE}
                              ;
                              {$ENDIF}
                              exit; //abort
                            end;
                            if writePage.latch(st)<>ok then //note: cannot be rootPage
                              exit; //abort - todo make more resiliant?
                          end;
                          {$IFDEF DEBUGDETAIL3}
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('...packing page %d slot %d (%x) to page %d slot %d...',[pid,i,hs.hashValue,writePid,slotToPageSlot(hsId)]),vDebugMedium);
                          {$ELSE}
                          ;
                          {$ENDIF}
                          {$ENDIF}
                          writePage.SetBlock(st,slotToPageSlot(hsId)*sizeof(hs),sizeof(hs),@hs); //write empty
                          writePage.dirty:=True;

                          //note: would be nice to null the source of the pack (page/pid .i) but we'd need to latch & might conflict with write latch

                          inc(hsId);
                        end;

                        inc(i);
                        inc(icount);
                      end;
                      {$IFDEF DEBUGDETAIL12}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('...checked all keys in page %d for hole-packing',[page.block.thisPage]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}

                      //Note: we don't latch the read-page in case we trip over write page latches
                      //      -since the root page is latched, & we only read, there's no need anyway
                      //read next page in chain
                      pid:=page.block.nextPage;
                      (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,page.block.thisPage{pid}); //unpin this page

                    until pid=InvalidPageId;

                    {Now we must remove any empty overflow pages (the full-test relies on there being none)
                     (Note: with clever juggling it might be possible to re-use
                      these during the new page chain build - but we pack too late?
                      - maybe better if we can move and pack in one pass?)
                    }
                    blankPage:=writePage;
                    blankPid:=blankPage.block.nextPage; //start with next page since it must be 1st empty one
                    while blankPid<>InvalidPageId do
                    begin
                      {Need to pin the page so we can read next in chain}
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,blankPid,blankPage)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        exit; //abort
                      end;

                      //note: maybe we could set blankPage.dirty:=False here
                      //      to prevent buffer manager from writing back null changes to a de-allocated page -speed
                      //      but probably better to write-back nulls than old-data
                      //      (todo: get de-allocate routine to zeroise such pages if a switch is set!)

                      lastBlankPid:=blankPage.block.thisPage;
                      blankPid:=blankPage.block.nextPage;
                      (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,blankPage.block.thisPage); //must unpin this page before deallocate (cos resetPageFrame will be called)
                      if Ttransaction(st.owner).db.deAllocatePage(st,lastBlankPid{blankPage.block.thisPage})<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,'Failed de-allocating file page',vError);
                        {$ENDIF}
                        exit;
                      end;
                    end;
                    writePage.block.nextPage:=InvalidPageId; //chop trailing page list (now it's been de-allocated)
                    rootPage.block.prevPage:=writePid;       //link root page backwards to new end of bucket chain for quick appending to long chains

                    rootPage.dirty:=True;
                    writePage.dirty:=True;
                  finally
                    if writePage<>rootPage then //check not already latched in outer section
                      writePage.unlatch(st);
                    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,writePid); //unpin this page
                  end; {try}

                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('...after split-pack: page/chain %d read %d entries and pack-wrote %d entries...',[rootpid,icount,hsId-1]),vDebugMedium);
                  {$ENDIF}
                  {$ENDIF}
                  //todo: assert hsId-1 = hssplitHeader.hashValue
                  //             count=originalCount
                  //             & sum total = same+1... etc.

                  {Also increment current root page's local depth}
                  {Re-latch original page root (no need to pin - already pinned)}
                  try
                    hsHeader.RID.pid:=localDepth+1;
                    rootPage.SetBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader); //update slot header
                    rootPage.dirty:=True;
                  finally
                  //  rootPage.unlatch(st);
                  end; {try}
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('...increased page %d local depth to %d...',[rootPid,localDepth+1]),vDebugMedium);
                  {$ENDIF}
                  {$ENDIF}

                  {Double the directory?}
                  if localDepth=globalDepth then
                  begin //we need to double the bucket directory
                    //note: we assume the latch on dirpage will prevent interference
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpid);

                    thisDirpid:=dirpid; //start at beginning of dir
                    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading directory page %d',[thisDirpid]),vError);
                      {$ENDIF}
                      exit; //abort
                    end;

                    {Find the correct starting target directory page}
                    writepid:=dirpid;
                    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[writePid]),vError);
                      {$ENDIF}
                      exit; //abort
                    end;
                    {Add any more directory pages that might be needed}
                    for dirskip:=1 to (trunc(power(2,globalDepth+1))) DIV (HashIndexFileDirPerBlock-1) do
                    begin
                      if writePage.block.nextPage=InvalidPageId then
                      begin //we need to extend the directory
                        {Latch target (writePage)}
                        if writePage<>dirPage then //check not already latched in outer section
                          if writePage.latch(st)<>ok then
                            exit; //abort - todo make more resiliant?
                        try
                          if extendDirectory(st,blankPid)<>ok then
                            exit; //abort
                          writePage.block.nextPage:=blankPid; //chain to new directory page
                          writePage.dirty:=True;
                        finally
                          if writePage<>dirPage then //check not already latched in outer section
                            writePage.unlatch(st);
                        end; {try}
                      end;

                      writePid:=writePage.block.nextPage;
                      //todo assert <>InvalidPage
                      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,writePage.block.thisPage);
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket directory page %d [%d]',[writePid,dirskip]),vError);
                        {$ENDIF}
                        exit; //abort
                      end;
                    end; {for}
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,writePage.block.thisPage);

                    {Now we can move to the correct starting target directory page}
                    writepid:=dirpid;
                    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[writePid]),vError);
                      {$ENDIF}
                      exit; //abort
                    end;
                    for dirskip:=1 to (trunc(power(2,globalDepth))) DIV (HashIndexFileDirPerBlock-1) do
                    begin
                      writePid:=writePage.block.nextPage;
                      //todo assert <>InvalidPage
                      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,writePage.block.thisPage);
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket directory page %d [%d]',[writePid,dirskip]),vError);
                        {$ENDIF}
                        exit; //abort
                      end;
                    end;
                    {Latch target (writePage)}
                    if writePage<>dirPage then //check not already latched in outer section
                      if writePage.latch(st)<>ok then
                        exit; //abort - todo make more resiliant?
                    try
                      for hashMap:=0 to trunc(power(2,globalDepth))-1 do
                      begin //todo: just move this as one block! -speed!
                        //todo assert mappings are in dir list range

                        if (((hashMap+1) MOD (HashIndexFileDirPerBlock-1))=1) and ((hashMap+1)<>1) then
                        begin //need next source dir page
                          thisDirpid:=thisDirpage.block.nextPage;
                          //todo assert <>InvalidPage
                          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpage.block.thisPage);
                          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
                          begin
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('Failed reading bucket directory page %d [(?)]',[thisDirpid{n/a:,dirskip}]),vError);
                            {$ENDIF}
                            exit; //abort
                          end;
                        end;

                        if (((hashMap OR trunc(power(2,globalDepth)) +1) MOD (HashIndexFileDirPerBlock-1))=1) {+ can never be just 1 here} then
                        begin //need next target dir page
                          writePid:=writePage.block.nextPage;
                          //todo assert <>InvalidPage
                          if writePage<>dirPage then //check not already latched in outer section
                            writePage.unlatch(st);
                          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,writePage.block.thisPage);
                          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
                          begin
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('Failed reading bucket directory page %d [(?)]',[writePid{{n/a:dirskip}]),vError);
                            {$ENDIF}
                            exit; //abort
                          end;
                          if writePage<>dirPage then //check not already latched in outer section
                            if writePage.latch(st)<>ok then
                              exit; //abort - todo make more resiliant?
                        end;

                        thisDirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);
                        writePage.SetBlock(st,bucketToDirBucket((hashMap OR trunc(power(2,globalDepth))) +1)*sizeof(hd),sizeof(hd),@hd);
                        writePage.Dirty:=True;
                        {$IFDEF DEBUGDETAIL2}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('...duplicating directory entry slot %d[%d:%d] (%d) to slot %d[%d:%d]...',[(hashMap+1),
                                                                                                                                       thisDirpid,
                                                                                                                                       bucketToDirBucket(hashMap+1),
                                                                                                                                       hd.pid,
                                                                                                                                       (hashMap OR trunc(power(2,globalDepth)))+1,
                                                                                                                                       writePid,
                                                                                                                                       bucketToDirBucket((hashMap OR trunc(power(2,globalDepth)))+1)
                                                                                                                                       ]),vDebugMedium);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        {$ENDIF}
                      end;
                    finally
                      if writePage<>dirPage then //check not already latched in outer section
                        writePage.unlatch(st);
                      (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,writePid); //unpin this page
                    end; {try}

                    {Update hash-directory header with incremented globalDepth}
                    hashIndexFileDir.pid:=globalDepth+1; //global-depth => # buckets = 2^global-depth //note: could have done: hashIndexFileDir.pid:=hashIndexFileDir.pid+1, but not as safe/obvious????
                    dirpage.SetBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
                    dirPage.dirty:=True;
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('...incremented global depth to %d...',[globalDepth+1]),vDebugMedium);
                    {$ENDIF}
                    {$ENDIF}
                    globalDepth:=globalDepth+1; //needed for re-pointing routine below
                  end;

                  {Now repoint the bucket directory entry/entries for the new page/level}
                  (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpid);
                  {Start at the first directory page}
                  thisDirpid:=dirpid;
                  if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[thisDirpid]),vError);
                    {$ENDIF}
                    exit; //abort
                  end;

                  hd.pid:=newsplitPid; //single value record
                  hashLocalMask:=trunc(power(2,localDepth))-1;

                  {Repoint bucket directories for all levels up to the global depth that were pointing
                   to the old rootpid but which should now point to the new page (check if new bitSet)
                   - this could be more than 1 if global has skipped a level & left us behind
                   Note: warning if globaldepth-localdepth gap is large -> bad hashing, i.e. probably 1 long branch splitting directory
                   //note: this loop could be re-thought & made quicker: speed
                  }
                  hashMap:=0;
                  while hashMap< (trunc(power(2,globalDepth))) do
                  begin
                    if (((hashMap+1) MOD (HashIndexFileDirPerBlock-1))=1) and ((hashMap+1)<>1) then
                    begin //need next dir page
                      thisDirpid:=thisDirpage.block.nextPage;
                      //todo assert <>InvalidPage
                      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpage.block.thisPage);
                      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,thisDirpid,thisDirpage)<>ok then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Failed reading bucket directory page %d [next]',[thisDirpid]),vError);
                        {$ENDIF}
                        exit; //abort
                      end;
                    end;

                    //todo move this above dir search!
                    if bitSet(hashMap,localDepth{+1: bitset starts at 0}) then //maybe this should point to new page/chain
                    begin
                      thisDirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@temphd);
//todo - improve this - don't relatch - usually will only be 1 dir page! - read/latch next when move across border
                      if temphd.pid=rootpid then
                      begin
                        {$IFDEF DEBUGDETAIL}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('...re-pointed bucket directory entry %d (dump-ref %d) to new page %d...',[hashMap+1,hashmap,hd.pid]),vDebugMedium);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        {$ENDIF}
                        //todo remove need for repetitive latch/unlatch here - speed (ok for 1st dirpage)
                        {Latch target}
                        if thisDirpage<>dirPage then //check not already latched in outer section
                          if thisDirpage.latch(st)<>ok then
                            exit; //abort - todo make more resiliant?
                        try
                          //todo assert/check pointing to rootpid

                          thisDirpage.SetBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);

                          thisDirPage.dirty:=True;
                          //todo ensure we re-read the hsheader?
                          //todo ensure we latch and re-pin the pid?
                        finally
                          if thisDirpage<>dirPage then //check not already latched in outer section
                            thisDirpage.unlatch(st);
                        end; {try}
                      end
                      else
                      begin
                        {$IFDEF DEBUGDETAIL}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('...not re-pointed bucket directory entry %d (dump-ref %d) to new page %d...',[hashMap+1,hashmap,hd.pid]),vDebugMedium);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        {$ENDIF}
                      end;
                    end
                    else
                    begin
                      {$IFDEF DEBUGDETAIL}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('...not re-pointed pre-re-pointed bucket directory entry %d (dump-ref %d) to new page %d...',[hashMap+1,hashmap,hd.pid]),vDebugMedium);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      {$ENDIF}
                    end;

                    {Skip to next candidate}
                    hashMap:=hashMap+ 1; 
                  end;
                finally
                  dirPage.unlatch(st);
                end; {try}

                {Now the split is complete, re-read the root pointer info for the actual insertion}
                {We do this via the surrounding repeat..until loop, i.e. foundPage is still False
                 - assumes dirpid is still same...}

                //todo: save time by keeping existing root (and setting foundPage=True)
                //      if we know new key belongs there & there's already room!-speed
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Re-reading hash-bucket info after split:',[nil]),vDebugMedium);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}

                //note: we need to make sure no-one sneaks in a steals our new slot! latch the dir!?

                //note: perhaps we could pass a hint to the next loop:
                //      i.e. don't bother checking worthsplitting - we now know it isn't... either find a gap or overflow!

                //note: double check we don't get here twice, since the next time should not need a split!
                //      - else we could loop & split forever!!!!
              end; {split page/chain}
            end; {full page chain}
          finally
            if not foundPage then
            begin //un-latch root for next attempt
              rootPage.unlatch(st);
              (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rootPid);
            end;
            //else keep correct root pinned and latched, and issue another try..finally after the repeat loop
          end; {try}
        finally
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisDirpid);
        end; {try}
      until foundPage; //loop until we have (made) room

      {Ok, we have room for the insertion on the currently pinned & latched root page/chain}
      try //we finished our initial try, re-issue it
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...ok: we have room for the new key+ptr in page/chain %d (it has %d used slots)...',[rootPid,hsHeader.hashValue]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        //assumes rootPid is now latched and (still/re) pinned
        //assumes rootPid chain has 1 slot free at least
        //assumes hsHeader is still current for this rootPid
        {Now insert the key + ptr in the appropriate page & slot}
        begin
          {Find place}
          hsId:=1; //start at 1st hash slot
          pid:=rootPid; //insert-locator
          page:=rootPage; //start at root page
          {Pin again, to simplify unpins - symmetry
           (note+: because we rely on its already being latched, the latch/unlatch routines can't be nested
                   at the moment otherwise the latchTran reference would be made invalid. To fix we could either:
                     make the unlatch routine pop until it resets the id
                     or unlatch and re-latch in this routine more complexly...
           )
          }
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,pid,page)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          try
            //we leave last read-page pinned for insertion
            {Skip to the appropriate page by checking the last key on each page}
            //note: would be nice to check last page in a long chain & jump there if we are appending (for FK indexing) -speed
            page.AsBlock(st,slotToPageSlot(hsId+(HashSlotPerBlock-1)-1)*sizeof(hs),sizeof(hs),@hs);
            while (slotCompare(hashvalue,rid,hs)>0) and ((hsId+(HashSlotPerBlock-1))<=hsHeader.hashValue) do
            begin //this hash value belongs on a later page & we have another page in the chain
              {First, before trailing through the chain pages, if this is a long chain we check the last page in the
               chain - long chains are often because of duplicate keys and so if our new key is >= the rest it
               belongs at the end of the chain. This is an important shortcut for very long chains such as sometimes
               found in FK indexes. It means maintaining an extra page link (rootPage.prevPage) but it's worth it
               (we'll need to read the end page anyway no matter what happens: insert+shuffle or append)}
              if (hsId=1) and (hsHeader.hashValue>(2*(HashSlotPerBlock-1))) then //note: maybe 3* in case just added blank 3rd page
              begin
                {$IFDEF DEBUGDETAIL8}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('...checking last page %d in long chain',[rootPage.block.prevPage]),vDebugMedium);
                {$ENDIF}
                {$ENDIF}
                if rootPage.block.prevPage<>InvalidPageId then
                begin //get and pin last overflow page in this chain
                  pid:=rootPage.block.prevPage;
                  (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rootPage.block.thisPage{pid}); //un-pin current page
                  if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading last bucket page in chain %d',[pid]),vError); //assertion?
                    {$ENDIF}
                    exit; //abort
                  end;
                  {If we've just added a new (empty) page to the end of the chain,
                   we need to check the last entry of the previous page}
                  if (hsHeader.hashValue MOD (HashSlotPerBlock-1))=0 then
                  begin
                    pid:=page.block.prevPage;
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,page.block.thisPage{pid}); //un-pin current page
                    {$IFDEF DEBUGDETAIL8}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Just added new page at end of chain so will read last bucket page-1 in chain %d',[pid]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading last bucket page-1 in chain %d',[pid]),vError); //assertion?
                      {$ENDIF}
                      exit; //abort
                    end;
                  end;
                end
                else
                begin //error - no end-chain page link!
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('No end-chain page link from %d - aborting find...',[rootPage.block.thispage]),vAssertion);
                  {$ENDIF}
                  exit; //abort
                end;
                {Now check the last entry in the chain}
                page.AsBlock(st,slotToPageSlot(hsHeader.hashValue)*sizeof(hs),sizeof(hs),@hs);
                if slotCompare(hashvalue,rid,hs)>0 then
                begin //key belongs at end of the chain
                  {If we've just added a new (empty) page to the end of the chain,
                   we need to skip forward again to the last page}
                  if (hsHeader.hashValue MOD (HashSlotPerBlock-1))=0 then
                  begin
                    pid:=page.block.nextPage;
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,page.block.thisPage{pid}); //un-pin current page
                    {$IFDEF DEBUGDETAIL8}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Just added new page at end of chain so will now skip forward to last bucket page in chain %d',[pid]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading last bucket page-1 in chain %d',[pid]),vError); //assertion?
                      {$ENDIF}
                      exit; //abort
                    end;
                  end;

                  {$IFDEF DEBUGDETAIL8}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Key belongs at end of chain so will shortcut to it %d',[pid]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  hsId:=(hsHeader.hashValue DIV (HashSlotPerBlock-1)) * (HashSlotPerBlock-1) +1; //i.e. 1st slot on last page
                  break; //chain-trailing shortcut worked
                end
                else
                begin //key belongs somewhere inside the chain, so continue with the page trail
                  {$IFDEF DEBUGDETAIL8}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Key does not belong at end of chain so will continue with chain trail',[nil]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,pid); //un-pin current page
                  pid:=rootPage.block.thisPage; //back to 1st page in chain (our next step, below, is to move to the next page since we've already checked we belong after the very first page)
                                                //note: only safe if rootPage<>page (since we've just unpinned page)
                  if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError); //assertion?
                    {$ENDIF}
                    exit; //abort //ok?
                  end;
                end;
              end; {initial shortcut attempt}

              {$IFDEF DEBUGDETAIL8}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('...skipping to next page in chain since end-of-page slot %d hash %d >= %d',[hsId,hashValue,hs.HashValue]),vDebugMedium);
              {$ENDIF}
              {$ENDIF}
              hsId:=hsId+(HashSlotPerBlock-1); //skip to 1st slot on next page
              if ((hsId MOD (HashSlotPerBlock-1))=1) and (hsId<>1) then //note: this test is guaranteed to succeed
              begin //end of this read page, move to next one
                if page.block.nextPage<>InvalidPageId then
                begin //get and pin next overflow page in this chain
                  pid:=page.block.nextPage;
                  (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,page.block.thisPage{pid}); //un-pin current page
                  if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError); //assertion?
                    {$ENDIF}
                    exit; //abort //ok?
                  end;
                end
                else
                begin //error - not enough pages for count!
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('No more overflow pages after %d, but count says there should be %d entries & we have only read %d so far - aborting find...(HashSlotPerBlock=%d)',[page.block.thispage,hsHeader.hashValue,hsId,HashSlotPerBlock]),vAssertion);
                  {$ENDIF}
                  exit; //abort, we can't continue & do the find because we haven't found a place!
                end;
              end;
              //todo: else assertion error! - quit to prevent infinite loop
              page.AsBlock(st,slotToPageSlot(hsId+(HashSlotPerBlock-1)-1)*sizeof(hs),sizeof(hs),@hs);
            end; {while}

            {Ok, we're on the right page so binary search to find the 1st matching key}
            sLow:=hsId; //i.e. 1st slot on the chosen page (Note: if chosen page is empty we will use 1st slot on it (hsId = hsHeader.hashValue+1)
            sHigh:=hsId+(HashSlotPerBlock-1)-1; //i.e. last slot on the chosen page
            if sHigh>hsHeader.hashValue then sHigh:=hsHeader.hashValue; //must be on single (non-full) page
            while sLow<sHigh do
            begin
              sMiddle:=(sLow+sHigh) DIV 2; //todo use SHR - speed
              page.AsBlock(st,slotToPageSlot(sMiddle)*sizeof(hs),sizeof(hs),@hs);
              if slotCompare(hashvalue,rid,hs)<0 then
                sHigh:=sMiddle
              else
                sLow:=sMiddle+1;
            end;
            hsId:=sLow;

            //todo (especially if inserting) if HashValue>high.hashvalue then hsId++
            page.AsBlock(st,slotToPageSlot(hsId)*sizeof(hs),sizeof(hs),@hs);
            foundExists:=(slotCompare(hashvalue,rid,hs)=0); //don't add this key: it already exists (e.g. update to an old value)
            if slotCompare(hashvalue,rid,hs)<0 then //Note: this means equal keys are appended to end of same-key chain (if rids increase) = fast inserts (less shuffling), but maybe slower reads if most recent = less likely to be junk(?)
            begin //found place, shift this + rest down 1
              //Note: once we start doing this we should ensure we increment the slot count, else we'll lose the end one!
              //i.e. any exits below should really continue on... or undo the shuffling?

              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('...found slot %d (chain-scale) - moving rest down to make a space...',[hsId]),vDebugMedium);
              {$ENDIF}
              {$ENDIF}

              //Note: this page is pinned, and we leave it so...

              {Scan to end of overflow chain}
              //todo: we should probably!!! latch from left-right here... i.e. ensure insertion into chain is atomic!
              //      but beware of pinning very long chains: could run out of buffer pages
              while page.block.nextPage<>InvalidPageId do
              begin
                pid:=page.block.nextPage;
                (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,page.block.thisPage); //unpin previous page
                if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,pid,page)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed reading bucket overflow page %d',[pid]),vError);
                  {$ENDIF}
                  exit; //abort //beware! see note above
                end;
              end;
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('...scanned to end of overflow chain to reach end page %d (identified as %d)...',[pid,page.block.thispage]),vDebugMedium);
              {$ENDIF}
              {$ENDIF}
              {Now shuffle slot keys down by 1}
              //Note: write trails read, so it re-pins initial page
              writePid:=pid;
              if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writePage)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed reading bucket overflow page %d',[writePid]),vError);
                {$ENDIF}
                exit; //abort //beware! see note above
              end;
              if writePage<>rootPage then //check not already latched in outer section
                writePage.latch(st);
              try
                icount:=0;
                for i:=hsHeader.hashValue+1 downto hsid+1 do
                begin
                  {Check we're on the correct read-page}
                  if (((i-1) MOD (HashSlotPerBlock-1))=0) and (i-1<>0){no need, i is always above 0} then
                  begin //end of this read page, read previous one
                    //todo: assert pid<>rootpid now that root.prevPage could be valid, i.e. circle
                    pid:=page.block.prevPage;
                    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,page.block.thisPage); //unpin this page (it should still be pinned for the write to unpin)
                    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,pid,page)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading bucket overflow page %d (read prev)',[pid]),vError);
                      {$ENDIF}
                      exit; //abort //beware! see note above
                    end;
                  end;
                  {Check we're on the correct write-page}
                  if ((i MOD (HashSlotPerBlock-1))=0) and (i<>hsHeader.hashValue+1){ignore when starting write at last slot in page} and (i<>0){no need, i is always above 0} then
                  begin //end of this write page, read previous one
                    //todo: assert writePid<>rootpid now that root.prevPage could be valid, i.e. circle
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('...reading previous page in chain %d...',[writePage.block.prevPage]),vDebugMedium);
                    {$ENDIF}
                    {$ENDIF}
                    if writePage<>rootPage then //check not already latched in outer section
                      writePage.unlatch(st);
                    writePid:=writePage.block.prevPage;
                    (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,writePage.block.thisPage); //unpin this page (it should no longer be pinned - write trails read)
                    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,writePid,writepage)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading bucket overflow page %d (write prev)',[writePid]),vError);
                      {$ENDIF}
                      exit; //abort //beware! see note above
                    end;
                    if writePage<>rootPage then //check not already latched in outer section
                      writePage.latch(st);
                  end;

                  //todo: move this as one block! -speed!
                  page.AsBlock(st,slotToPageSlot(i-1)*sizeof(hs),sizeof(hs),@hs);
                  writePage.SetBlock(st,slotToPageSlot(i)*sizeof(hs),sizeof(hs),@hs);
                  writePage.dirty:=True;
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('...moving from slot %d (chain-scale) to %d value %x->%d:%d...',[i-1,i,hs.HashValue,hs.rid.pid,hs.rid.sid]),vDebugMedium);
                  {$ENDIF}
                  {$ENDIF}
                end;
                {$IFDEF DEBUGDETAIL12}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('...checked %d keys in page %d for shuffling',[((hsHeader.hashValue+1)-(hsid+1))+1,page.block.thisPage]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                {At end of this loop we assume:
                   writePage is latched and pinned as is 1 past hsid
                   readPage is pinned and is our insertion page
                }
              finally
                if writePage<>rootPage then //check not already latched in outer section
                  writePage.unlatch(st);
                (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,writePid); //unpin this page
              end;
            end
            else
            begin //not found on this page & must be last page, so append to end (usual case for FK indexes)
              if not(foundExists) and (hsId<=hsHeader.hashValue) then //not duplicate or 1st entry (i.e. sLow=1 and sHigh=0)
              begin
                inc(hsId);
                //note: I don't think we ever need the following check: initial while loop should always move to the right page - including any new overflow page...
                if ((hsId MOD (HashSlotPerBlock-1))=1) and (hsId<>1) then
                begin //end of this read page, move to next one
                  if page.block.nextPage<>InvalidPageId then
                  begin //get and pin next overflow page in this chain
                    pid:=page.block.nextPage;
                    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,page.block.thisPage{pid}); //un-pin current page
                    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,pid,page)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed reading bucket page %d',[pid]),vError); //assertion?
                      {$ENDIF}
                      exit; //abort //ok?
                    end;
                  end
                  else
                  begin //error - not enough pages for count!
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('No more overflow pages after %d, but count says there should be %d entries & we have only read %d so far - aborting find....'{Note 4 dots to distinguish},[page.block.thispage,hsHeader.hashValue,hsId]),vAssertion);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort, we can't continue & do the find because we haven't found a place!
                  end;
                end;
              end;
              //else leave here (i.e. duplicate or slot 1 (when count=0 or new empty page just added))
            end;

            //todo: assert not past end of page
            //      assert this page = hsid DIV (HashSlotPerBlock-1) !
            {Write the new entry (or just dirty the page if this is a duplicate: to make sure anything we commit gets saved, e.g. in case the duplicate we rely on was uncommitted/rolled back)}
            if pid<>page.block.thisPage then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Page is not the one we expected %d instead of %d, aborting...',[page.block.thisPage,pid]),vAssertion);
              {$ENDIF}
              exit; //abort //beware! see note above
            end;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            if not foundExists then
              log.add(st.who,where+routine,format('...writing entry (%x=%d:%d) at page %d slot %d (chain-scale) and incrementing slot count to %d...',[hashValue,rid.pid,rid.sid,pid,hsId,hsHeader.hashValue+1]),vDebugMedium)
            else
              log.add(st.who,where+routine,format('...key/rid exists: avoiding writing entry (%x=%d:%d) at page %d slot %d (chain-scale) and incrementing slot count to %d...',[hashValue,rid.pid,rid.sid,pid,hsId,hsHeader.hashValue+1]),vDebugMedium);
            {$ENDIF}
            {$ENDIF}
            hs.hashValue:=hashValue;
            hs.RID:=rid;
            if page<>rootPage then //check not already latched in outer section
              page.latch(st);
            try
              if not foundExists then page.SetBlock(st,slotToPageSlot(hsId)*sizeof(hs),sizeof(hs),@hs);
              page.dirty:=True; //Note: we still set dirty even if foundExists to ensure the duplicate we will rely on is committed if we are
            finally
              if page<>rootPage then //check not already latched in outer section
                page.unlatch(st);
            end; {try}
          finally
            (Ttransaction(st.owner).db.owner as TDBserver).buffer.unpinPage(st,pid); //unpin this page (root is still left pinned)
          end; {try}

          if not foundExists then
          begin
            {Increment slot header count}
            hsHeader.hashValue:=hsHeader.hashValue+1; //increment hash-slot count
            rootPage.SetBlock(st,0,sizeof(hsHeader),@hsHeader);

            rootPage.dirty:=True;
          end;
          result:=ok;
        end;
      finally
        rootPage.unlatch(st);
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rootPid);
      end; {try}

    finally
      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpid);
    end; {try}

    {$IFDEF DEBUGDETAIL6}
    {$IFDEF DEBUG_LOG}
    //(Ttransaction(st.owner).db.owner as TDBServer).buffer.status;
    self.Dump(st,nil);
    {$ENDIF}
    {$ENDIF}
  end
  else
    {there are no data pages for this file (yet) - should never happen for this type of file
     todo: so assertion!}
    ;
end; {AddKeyPtr}

function THashIndexFile.FindStart(st:TStmt;FindData:TTuple):integer;
{Start a key search
 IN:      tr            - transaction
          FindData      - tuple (with same definition as the owning relation's)
                          containing search data

 RETURN: ok, else fail

 Assumes:
   index has been opened

 Notes:
   leaves the bucket page pinned
   - this page may or may not contain a matching key - use FindNext/FindStop to unpin
   - if the page does contain a matching key, this routine will have set fhsId to the slot
}
const routine=':FindStart';
var
  i:ColRef;
  hashMap,hashGlobalMask,hashLocalMask:cardinal;
  dirpid,pid:pageId;
  dirskip,space:word;
  dirpage:TPage;
  hashIndexFileDir:THashIndexFileDir;
  globalDepth,localDepth:pageId;
  hsHeader,hs:THashSlot;
  sLow,sHigh,sMiddle:HashSlotId;
begin
  result:=Fail;

  fpid:=InvalidPageId; //prevent stop from unpinning if we haven't pinned yet

  {Store the search key}
  //note - we may not need to do this currently if we don't need it again - so remove - speed?
  // - i.e. caller does full-check against its copy...
  if findData<>nil then
  begin
    fTupleKey.clear(st);
    for i:=1 to fTupleKey.ColCount do
      fTupleKey.copyColDataDeep(i-1,st,findData,i-1,false);
    fTupleKey.preInsert; //finalise it
  end;
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeadingKey]),vDebugLow);
  log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeading]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%s',[fTupleKey.Show(st)]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {First calculate the hash value}
  fHashValue:=hash(findData);     //note: if this is the only place we use findData then do away with fTupleKey?! - future matching may be useful though
  if fHashValue=0 then exit; //abort

  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('scanning index %s with hash value of %d',[name,fHashValue]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  {Find the bucket page id}
  //note: maybe better to use GetScanStart, but leaves 1st data page (=bucket dir page) pinned
  result:=self.DirPage(st,InvalidPageId,0,dirpid,space); //get 1st dir slot page = 1st bucket dir page
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  if dirpid<>InvalidPageId then //only if we have the bucket dir
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[dirpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read hash-directory header}
      dirpage.AsBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
      globalDepth:=hashIndexFileDir.pid; //global-depth => # buckets = 2^global-depth

      {Hash to bucket page pointer}
      hashGlobalMask:=trunc(power(2,globalDepth))-1;

      hashMap:=(hashGlobalMask AND fHashValue); //use last few bits //note not true- depends on endian... no matter until copy directory?...

      {$IFDEF DEBUGDETAIL7}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('using global depth of %d, hash value %x AND %x used=%xx',[globalDepth,fHashValue,hashGlobalMask,hashMap]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      {Find the correct directory page}
      for dirskip:=1 to hashMap DIV (HashIndexFileDirPerBlock-1) do
      begin
        dirpid:=dirpage.block.nextPage;
        //todo assert <>InvalidPage
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpage.block.thisPage);
        if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading bucket directory page %d [%d]',[dirpid,dirskip]),vError);
          {$ENDIF}
          exit; //abort
        end;
      end;

      {Read bucket page pointer}
      //Assumes: do we need +1 below: hashMap is never 0 - reserved for directory header (i.e. count) - 1st page only?
      //         -Yes we do need +1: hashMap can give 0 even though hashValue cannot be...
      //         - so 0 maps to 1st slot, 1 to 2nd etc.
      dirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);

      fpid:=hashIndexFileDir.pid; //we might revert back to (& test =) this bucket-start-page later...

      {$IFDEF DEBUGDETAIL7}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...so bucket slot %d (dump-ref %d) is used to give page id %d',[(hashMap+1),hashmap,fpid]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {Now pin the bucket page}
      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;

      {Read hash-slot header}
      fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
      fhsHeader:=hsHeader; //store so FindNext knows where last used slot is
      localDepth:=hsHeader.RID.pid;
      {$IFDEF DEBUGDETAIL7}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('...page/chain id %d has %d entries and has local-depth %d',[fpid,hsHeader.hashValue,localdepth]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {Now try to move to the first matching key + ptr in the appropriate slot}
      {Find place}
      fhsId:=1; //start at 1st hash slot
      {Skip to the appropriate page by checking the last key on each page}
      fCurrentPage.AsBlock(st,slotToPageSlot(fhsId+(HashSlotPerBlock-1)-1)*sizeof(hs),sizeof(hs),@hs);
      while (fHashValue>hs.HashValue) and ((fhsId+(HashSlotPerBlock-1))<=hsHeader.hashValue) do
      begin //this hash value belongs on a later page & we have another page in the chain
        {$IFDEF DEBUGDETAIL8}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...skipping to next page in chain since end-of-page slot %d hash %d > %d',[fhsId,fHashValue,hs.HashValue]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        fhsId:=fhsId+(HashSlotPerBlock-1); //skip to 1st slot on next page
        if ((fhsId MOD (HashSlotPerBlock-1))=1) and (fhsId<>1) then //note: this test is guaranteed to succeed
        begin //end of this read page, move to next one
          if fCurrentPage.block.nextPage<>InvalidPageId then
          begin //get and pin next overflow page in this chain
            fpid:=fCurrentPage.block.nextPage;
            (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fCurrentPage.block.thisPage{fpid}); //un-pin current page
            if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError); //assertion?
              {$ENDIF}
              exit; //abort //ok?
            end;
          end
          else
          begin //error - not enough pages for count!
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('No more overflow pages after %d, but count says there should be %d entries & we have only read %d so far - aborting find...',[fCurrentPage.block.thispage,hsHeader.hashValue,fhsId]),vAssertion);
            {$ENDIF}
            exit; //abort, we can't continue & do the find because we haven't found a place!
          end;
        end;
        //todo: else assertion error! - quit to prevent infinite loop
        fCurrentPage.AsBlock(st,slotToPageSlot(fhsId+(HashSlotPerBlock-1)-1)*sizeof(hs),sizeof(hs),@hs);
      end;
      {Ok, we're on the right page so binary search to find the 1st matching key}
      sLow:=fhsId; //i.e. 1st slot on the chosen page
      sHigh:=fhsId+(HashSlotPerBlock-1)-1; //i.e. last slot on the chosen page
      if sHigh>hsHeader.hashValue then sHigh:=hsHeader.hashValue; //must be on single (non-full) page
      while sLow<sHigh do
      begin
        sMiddle:=(sLow+sHigh) DIV 2; //todo use SHR - speed
        fCurrentPage.AsBlock(st,slotToPageSlot(sMiddle)*sizeof(hs),sizeof(hs),@hs);
        if fhashValue<=hs.HashValue then
          sHigh:=sMiddle
        else
          sLow:=sMiddle+1;
      end;
      fhsId:=sHigh;
      fhashPrevious.HashValue:=0; //invalid
      fhashPrevious.RID.pid:=InvalidPageId;

      //we leave the current page pinned, even if we reached the end of the chain
      // - FindNext will determine whether we found a match or not and will (or FindStop will) unpin it

      {$IFDEF DEBUGDETAIL7}
      //note: does this test always report the correct result? - should be 'may have found...'?
      if fhsId<=hsHeader.hashValue then
      begin //debug only section!
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...found matching hash value at slot %d...',[fhsId]),vDebugMedium)
        {$ENDIF}
      end
      else //debug only section!
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...found no matching hash value...',[nil]),vDebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      {$ENDIF}

      result:=ok;
    finally
      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpid);
    end; {try}
  end
  else
    {there are no data pages for this file (yet) - should never happen for this type of file
     - so assertion!}
    ;
end; {FindStart}

function THashIndexFile.FindNext(st:TStmt;var noMore:boolean;var RID:Trid):integer;
{Gets next potentially matching key

 OUT:     noMore   - no more potentially matching keys in this relation
 RETURN : +ve=ok, else fail

 Note:
   We can only (currently) return potential matching keys from this hash index because:
     1) we don't store the whole key here, just the hash value
        - hopefully there won't be many key/hash overlaps but it is possible
     2) we don't store timestamp information here
        - this will mean some data will not be applicable/visible to the caller
   ...so the caller must read and check the data/timestamp for a match before using it

 Assumes:
  FindStart has been called (& so moved to 1st matching slot, if any, else just past where it would have been)
  Index has been opened
}
const routine=':FindNext';
var
  hs:THashSlot;
  foundNewRid:boolean;
begin
  result:=Fail;

  //todo assert FindScanStart has been called? - check fTupleKey?

  {If the current hash slot exists and matches our hash value:
     return it to the caller
     move to the next slot
   else
     return noMore
  }
  foundNewRid:=False; //avoid duplicate value+RID entries: these are rare, e.g. insert A/rollback/insert A atomically could do it
                      //bug fix: 02/12/02 (although these shouldn't be in the index to start with...)
  repeat
    {Refer back to root hash-slot header}
    if fhsId>fhsHeader.hashValue then
    begin
      noMore:=True; //we past any matches
    end
    else
    begin
      fCurrentPage.AsBlock(st,slotToPageSlot(fhsId)*sizeof(hs),sizeof(hs),@hs);
      if fHashValue=hs.HashValue then //current slot matches
      begin
        if (hs.RID.pid<>fhashPrevious.RID.pid) or (hs.RID.sid<>fhashPrevious.RID.sid) then //assume hashValue matches by definition of this search
          foundNewRid:=True; //flag that we've found a none duplicated hashValue+RID entry & so can return
        {$IFDEF DEBUGDETAIL7}
        {$IFDEF DEBUG_LOG}
        if not foundNewRid then log.add(st.who,where+routine,format('...skipping duplicate hashvalue+RID (should never happen?!)...',[nil]),vAssertion); //should never happen!
        {$ENDIF}
        {$ENDIF}

        RID:=hs.rid;

        fhashPrevious:=hs; //store the last entry to avoid duplicate rids
        {Now move to next slot ready for next}
        inc(fhsId);
        if ((fhsId MOD (HashSlotPerBlock-1))=1) and (fhsId<>1) then
        begin //we've exhausted the entries on this page, move to next overflow page
          if fCurrentPage.block.nextPage<>InvalidPageId then
          begin //read next overflow page
            {$IFDEF DEBUGDETAIL7}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('...page id %d exhausted, moving to next page in overflow chain (%d) ready for next',[fpid,fCurrentPage.block.nextPage]),vDebugMedium);
            {$ENDIF}
            {$ENDIF}
            fpid:=fCurrentPage.block.nextPage;
            (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fCurrentPage.block.thisPage{fpid}); //un-pin current page
            if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
              {$ENDIF}
              exit; //abort
            end;
          end
          else
          begin
            //else no more pages in the overflow chain, next call will return noMore
            //todo: assert hsid>count: else will crash next time...
            fCurrentPage:=nil; //safety - we should never use this again!
          end;
        end;
      end
      else
      begin
        noMore:=True; //we must have past any matches (since we're guaranteed to have them in sorted order)
      end;
    end;
  until noMore or foundNewRid; //99% this will loop once, rarely might need to skip an entry if we've already returned the value+RID, i.e. duplicate

  result:=ok;
end; {FindNext}

function THashIndexFile.FindStop(st:TStmt):integer;
{Stops a key search

 RETURN : +ve=ok, else fail

 Assumes:
  index has been opened

 Note:
   if caller read any candidates (likely!) then it is responsible for
   unpinning any pages pinned by those reads
}
const routine=':FindStop';
begin
  result:=Fail;

  if fpid<>InvalidPageId then
  begin
    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid); //un-pin current index page
    fpid:=InvalidPageId;
  end;

  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Total hash mismatches: %d  Total version mismatches: %d',[statHashClash,statVersionMiss]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=ok;
end; {FindStop}

////todo tidy these routines!
function THashIndexFile.FindStartDuplicate(st:TStmt):integer;
{Start a duplicate key search
 IN:      tr            - transaction

 RETURN: ok, else fail

 Assumes:
   index has been opened

 Notes:
   leaves the bucket page pinned
   - this page may or may not contain a duplicate key - use FindNextDuplicate/FindStopDuplicate to unpin
   leaves the directory page pinned
}
const routine=':FindStartDuplicate';
var
  i:ColRef;
  hashGlobalMask,hashLocalMask:cardinal;
  dirpid,pid:pageId;
  space:word;
  hashIndexFileDir:THashIndexFileDir;
  localDepth:pageId;
  hsHeader,hs:THashSlot;
begin
  result:=Fail;

  fpid:=InvalidPageId; //prevent stop from unpinning if we haven't pinned yet

  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('scanning index %s for duplicates',[name]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  {Find the bucket page id}
  //note: maybe better to use GetScanStart, but leaves 1st data page (=bucket dir page) pinned
  result:=self.DirPage(st,InvalidPageId,0,dirpid,space); //get 1st dir slot page = 1st bucket dir page
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  if dirpid<>InvalidPageId then //only if we have the bucket dir
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,fdirpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[dirpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;

    fhashPrevious.HashValue:=0; //invalid
    fhashBucket:=0;
    fhsId:=0; //start at 1st hash slot (next will ++)

    {Read hash-directory header - used for next calls}
    fdirpage.AsBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
    fglobalDepth:=hashIndexFileDir.pid; //global-depth => # buckets = 2^global-depth

    begin
      {Read bucket page pointer}
      //Assumes: do we need +1 below: fhashBucket is never 0 - reserved for directory header (i.e. count) - 1st page only?
      //         -Yes we do need +1: fhashBucket starts at 0
      //         - so 0 maps to 1st slot, 1 to 2nd etc.
      fdirpage.AsBlock(st,bucketToDirBucket(fhashBucket+1)*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
    end;

    fpid:=hashIndexFileDir.pid; //we might revert back to (& test =) this bucket-start-page later...

    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('starting at bucket slot %d which gives page id %d',[(fhashBucket+1),fpid]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    {Now pin the bucket page}
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;

    {Read hash-slot header}
    fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
    fhsHeader:=hsHeader; //store so FindNext knows where last used slot is
  end
  else
    {there are no data pages for this file (yet) - should never happen for this type of file
     - so assertion!}
    ;
end; {FindStartDuplicate}

function THashIndexFile.FindNextDuplicate(st:TStmt;var noMore:boolean;var RID1,RID2:TRid):integer;
{Finds the next duplicate index entries which will be candidates
 for duplicate keys in the relation. Used to determine if the relation key isUnique.

 Note: must not be called during an indexed FindScan (uses same cursor vars)

 IN:      tr            - transaction

 OUT:     noMore        - no more potentially duplicate keys in this relation
          RID1
          RID2          - pair of RIDs that are duplicate key candidates

 RETURN: ok, else fail

 Assumes:
   index has been opened
   FindStartDuplicate has been called

 Notes:
   leaves the bucket page pinned
   - this page may or may not contain a matching key - use FindNext/FindStop to unpin
   - if the page does contain a matching key, this routine will have set fhsId to the slot

   RID1 and RID2 could both be same (e.g. garbage left after update/rollbacks etc.)
   - the caller must determine which ones are garbage by ignoring duplicate RIDs after a
     tuple for one of them has been successfully read
}
const routine=':FindNextDuplicate';
var
  i:ColRef;
  hashGlobalMask,hashLocalMask:cardinal;
  dirpid:pageId;
  space:word;
  hashIndexFileDir:THashIndexFileDir;
  localDepth:pageId;
  hsHeader,hs:THashSlot;
begin
  result:=Fail;

  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('scanning index %s for duplicates',[name]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  {Read hash-directory header}
  while fhashBucket<=trunc(power(2,fglobalDepth))-1 do
  begin
    {re-Read hash-slot header}
    fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
    fhsHeader:=hsHeader; //store so FindNext knows where last used slot is

    localDepth:=hsHeader.RID.pid;
    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('...page id %d has %d entries and has local-depth %d',[fpid,hsHeader.hashValue,localdepth]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    {(Continue to) scan this page and any overflow pages until we find a duplicate or reach the end}
    fhsId:=fhsId+1; //continue at next hash slot
    //Note: assumes page has not changed since we were last here: check/assert/guarantee/else?!
    while fhsId<=hsHeader.hashValue do
    begin
      fCurrentPage.AsBlock(st,fhsId*sizeof(hs),sizeof(hs),@hs);
      if (hs.HashValue<>fhashPrevious.HashValue) then //keep searching
      begin
        fhashPrevious:=hs;
      end
      else //found duplicate, we're done here for now
      begin
        {$IFDEF DEBUGDETAIL8}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('...found duplicate at slot %d hash=%d',[fhsId,hs.HashValue]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        break;
      end;

      inc(fhsId);
      if ((fhsId MOD (HashSlotPerBlock-1))=1) and (fhsId<>1) and (fhsId<=hsHeader.hashValue) then
      begin //end of this read page, move to next one ready for next loop
        if fCurrentPage.block.nextPage<>InvalidPageId then
        begin //get and pin next overflow page in this chain
          fpid:=fCurrentPage.block.nextPage;
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fCurrentPage.block.thisPage{fpid}); //un-pin current page
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError); //assertion?
            {$ENDIF}
            exit; //abort //ok?
          end;
        end
        else
        begin //error - not enough pages for count!
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('No more overflow pages after %d, but count says there should be %d entries & we have only read %d so far - aborting find...',[fCurrentPage.block.thispage,hsHeader.hashValue,fhsId]),vAssertion);
          {$ENDIF}
          exit; //abort, we can't continue & do the find because we haven't found a place!
        end;
      end;
    end; {while}

    if fhsId<=hsHeader.hashValue then
    begin
      //found duplicate
      RID1:=fhashPrevious.RID;
      RID2:=hs.RID;
      fhashPrevious:=hs; //note: this means next pair will contain RID2 if same
      break;
    end
    else
    begin //finished with this page, continue searching index
      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid); //un-pin current page
      fpid:=InvalidPageId; //prevent stop from unpinning if we haven't pinned yet
    end;

    inc(fhashBucket); //try next bucket

    if fhashBucket<=trunc(power(2,fglobalDepth))-1 then
    begin
      if (((fhashBucket+1) MOD (HashIndexFileDirPerBlock-1))=1) and ((fhashBucket+1)<>1) then
      begin //need next dir page
        dirpid:=fdirpage.block.nextPage;
        //todo assert <>InvalidPage
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fdirpage.block.thisPage);
        if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,fdirpage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading bucket directory page %d [next]',[dirpid]),vError);
          {$ENDIF}
          exit; //abort
        end;
      end;

      fdirpage.AsBlock(st,bucketToDirBucket(fhashBucket+1)*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
      fpid:=hashIndexFileDir.pid; //we might revert back to (& test =) this bucket-start-page later...

      {Now pin the next bucket page}
      if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;
      {Read hash-slot header}
      fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
      fhsHeader:=hsHeader; //store so FindNext knows where last used slot is
      fhsId:=0; //start of next bucket
    end;
  end; {while}

  //note: does this test always report the correct result? - should be 'may have found...'?
  if fhashBucket<=trunc(power(2,fglobalDepth))-1 then
  begin
    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('...found duplicate hash value at slot %d...',[fhsId]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    noMore:=False;
  end
  else
  begin
    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('...found no duplicate hash value...',[nil]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    noMore:=True;
  end;
  result:=ok;
end; {FindNextDuplicate}

function THashIndexFile.FindStopDuplicate(st:TStmt):integer;
{Stops a duplicate key search

 RETURN : +ve=ok, else fail

 Assumes:
  index has been opened

 Note:
   if caller read any candidates (likely!) then it is responsible for
   unpinning any pages pinned by those reads
}
const routine=':FindStopDuplicate';
begin
  result:=Fail;

  if fpid<>InvalidPageId then
  begin
    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid);   //un-pin current index page
    fpid:=InvalidPageId;
  end;
  if fdirpage.block.thisPage<>InvalidPageId then
  begin
    (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fdirpage.block.thisPage); //un-pin current dir page
  end;

  {$IFDEF DEBUGDETAIL8}
  {$ENDIF}

  result:=ok;
end; {FindStopDuplicate}

function THashIndexFile.Dump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
{Dumps this index structure to log file

 RETURN : +ve=ok, else fail

 Assumes:
  index has been opened

 Note:
  doesn't lock the index, so could become (very!?) confusing if others are updating it
}
const routine=':Dump';
var
  hashMap:cardinal;
  dirpid:pageId;
  space:word;
  dirpage:TPage;
  hashIndexFileDir,hd:THashIndexFileDir;
  globalDepth,localDepth:pageId;
  hsHeader,hs:THashSlot;

  overflowCount:cardinal;
  s:string;
  noMoreOverflow:boolean;
  totalEntries:cardinal;
begin
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('starting',[nil]),vDebugLow);
  {$ENDIF}

  {If detailed, then dump the file directory}
  if not summary then debugDump(st,connection,True);

  result:=self.DirPage(st,InvalidPageId,0,dirpid,space); //get 1st dir slot page = 1st bucket dir page
  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed reading first dir slot',vDebugError);
    {$ENDIF}
    exit; //abort
  end;
  if dirpid<>InvalidPageId then //only if we have the bucket dir
  begin
    if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading bucket directory page %d',[dirpid]),vError);
      {$ENDIF}
      exit; //abort
    end;
    try
      {Read hash-directory header}
      dirpage.AsBlock(st,0*sizeof(hashIndexFileDir),sizeof(hashIndexFileDir),@hashIndexFileDir);
      globalDepth:=hashIndexFileDir.pid; //global-depth => # buckets = 2^global-depth
      {$IFDEF DEBUGDETAIL9}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Global depth: %d (%d entries)',[globalDepth,trunc(power(2,globalDepth))]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      if connection<>nil then
      begin
        connection.WriteLn(format('Start page=%d',[dirPid]));
        connection.WriteLn(format('Global depth: %d (%d entries)',[globalDepth,trunc(power(2,globalDepth))]));
      end;

      totalEntries:=0;
      for hashMap:=0 to trunc(power(2,globalDepth))-1 do
      begin
        s:='';
        overflowCount:=0; //indent level

        if (((hashMap+1) MOD (HashIndexFileDirPerBlock-1))=1) and ((hashMap+1)<>1) then
        begin //need next dir page
          dirpid:=dirpage.block.nextPage;
          //todo assert <>InvalidPage
          (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpage.block.thisPage);
          if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,dirpid,dirpage)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed reading bucket directory page %d [next]',[dirpid]),vError);
            {$ENDIF}
            exit; //abort
          end;
          s:='--- dir page break ---';
          {$IFDEF DEBUGDETAIL9}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,s,vDebugMedium); //flush current row
          {$ENDIF}
          {$ENDIF}
          if connection<>nil then
            connection.WriteLn(s);
          s:='';
        end;

        dirpage.AsBlock(st,bucketToDirBucket(hashMap+1)*sizeof(hd),sizeof(hd),@hd);
        fpid:=hd.pid;
        s:=s+format('%3.3d -> %5.5d',[hashmap,fpid]);
        {Now pin the bucket page}
        if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
          {$ENDIF}
          continue; //don't abort (used for debugging)- try next one
        end;

        {Dump this page and any overflow pages}
        {Read hash-slot header}
        fCurrentPage.AsBlock(st,0*sizeof(hsHeader),sizeof(hsHeader),@hsHeader);
        localDepth:=hsHeader.RID.pid;
        s:=s+format(' [%3.3d] %3.3d:',[localDepth,hsHeader.hashValue]);

        {Add to total, unless duplicate shared chain}
        if (localDepth=globalDepth) or
           (hashmap<=trunc(power(2,localDepth))-1) then
          totalEntries:=totalEntries+hsHeader.hashValue;

        //if not summary then
        begin
          fhsId:=1; //start at 1st hash slot
          while fhsId<=hsHeader.hashValue do
          begin
            fCurrentPage.AsBlock(st,slotToPageSlot(fhsId)*sizeof(hs),sizeof(hs),@hs);
            //note: I think for large indexes, this re-allocating of s causes a big slowdown... todo: pre-allocate or flush (i.e. write)...
            if not summary then
              s:=s+format(' [%3.3d]%8.8x->%5.5d:%3.3d ',[fhsId,hs.hashValue,hs.RID.pid,hs.RID.sid]);

            inc(fhsId);
            if ((fhsId MOD (HashSlotPerBlock-1))=1) and (fhsId<>1) and (fhsId<=hsHeader.hashValue) then
            begin //end of this read page, move to next one ready for next loop
              if fCurrentPage.block.nextPage<>InvalidPageId then
              begin //get and pin next overflow page in this chain
                inc(overflowCount);
                s:=s+format(CRLF+' =>%5.5d ',[fCurrentPage.block.nextPage]); //overflow header

                fpid:=fCurrentPage.block.nextPage;
                (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fCurrentPage.block.thisPage{fpid}); //un-pin current page
                if (Ttransaction(st.owner).db.owner as TDBserver).buffer.pinPage(st,fpid,fCurrentPage)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed reading bucket page %d',[fpid]),vError);
                  {$ENDIF}
                  break; //don't abort (used for debugging)- try next root page
                end;
              end
              else
              begin //error - not enough pages for count!
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('No more overflow pages after %d, but count says there should be %d entries & we have only read %d so far - aborting find...',[fCurrentPage.block.thispage,hsHeader.hashValue,fhsId]),vAssertion);
                s:=s+format(' *** Count = %d entries, read %d - missing overflow page(s) - aborting find...',[hsHeader.hashValue,fhsId]);
                {$ENDIF}
                break; //don't abort (used for debugging)- try next root page
              end;
            end;
          end;

          {$IFDEF DEBUGDETAIL9}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,s,vDebugMedium); //flush current row
          {$ENDIF}
          {$ENDIF}
          if connection<>nil then
            connection.WriteLn(s);
        end;
        //else skip detail

        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,fpid); //un-pin current page
      end;
    finally
      (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,dirpid);
    end; {try}

    if connection<>nil then
      connection.WriteLn(format('Total entries: %d',[totalEntries]));
  end
  else
    {there are no data pages for this file (yet) - should never happen for this type of file
     - so assertion!}
    ;
end; {Dump}


end.

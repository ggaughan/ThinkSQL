unit uPage;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Page (disk block i/o) definitions
 A page is (always?) embedded within a buffer frame, but to save stack access time
 calling frame to pass on the call to its page - we call page directly. Otherwise
 the dirty flag and latch should probably be at the frame level.

 The latch mechanism uses a TmultiReadExclusiveWriteSynchronizer and records the
 latch transaction owner.
 Once latched, a page can be read and modified by the transaction owner.
 When unlatched, a page can be read by any transaction(s), but modified by none.

 OLD:
 The latch mechanism uses a critical section and records the latch transaction owner.
 Once latched, a page can be read and modified by the transaction owner.
 When unlatched, a page can be read by any transaction(s), but modified by none.

 Note: used to use a mutex per page, but this is slower/bigger than a critical section
 and since we are a single process, there's no benefit.
 Mutex            = 500-600 instructions
 Critical section = 15-16 instructions (lightweight)

 Note: we just compare tranId's and not stmtId's as well, since it should be
       impossible for two stmtId's of the same tranId to conflict since they
       are always sequentially executed by the same thread.
       todo: check it can never happen, even after a crash...
       Note: we are ok to only compare tranId with InvalidStampId/MaxStampId.tranId

       Also note: we always compare with Tr.Rt.tranId, since this is always = Tr.Wt.tranId
                  and Rt.stmtId is never really important here, but we may quote it anyway...

 Note: double check this code against Delphi Magazine 03/2000
       & specify rules, i.e. no nested latching, only short+sweet etc. to prevent deadlock
       (& use NT's TryToGetCriticalSection...)
       etc.
 Especially make sure latches are taken in a fixed order, e.g. left-right, to avoid deadlock
 (latch calls can be nested by same caller)
}

interface

uses uGlobal, uStmt, sysutils,
     IdTCPConnection{debug only};

const
  //InvalidPageId:pageId=$FFFFFFFF; //i.e. maxCardinal(32-bit) //old:-1; (*$7FFFFFFE; {while still crippled in catalog}*)

  {PageTypes}
  ptEmpty=0;
  ptDBheader=1;
  ptDBMap=2;
  ptDBdir=3;
  ptFileDir=4;
  ptData=5;
  ptIndexData=6;
  //todo keep max in sync with pageTypes string array...

  pageTypeText:array [ptEmpty..ptIndexData] of string = ('empty',
                                                         'dbHeader',
                                                         'dbMap',
                                                         'dbDir',
                                                         'fileDir',
                                                         'data',
                                                         'indexData'
                                                        );


type
  TBlock=array [0..BlockSize-1] of char; //user data block

  {Note: this page structure needs to remain constant through future upgrades
         (and so is classed outside the database file structure)
   - to read the header page of a database file, we use the page read routines
   so this limits us from modifying the page tearing bytes - otherwise we couldn't
   even reach the structure version information on page 0
   (unless the openfile routine ignores the page read error, but still need same size
    page header details to be able to read the data)
  }
  TPageBlock=record      //page block (keep size in sync. with BlockSize)
    tearStart:byte{padded to 4 bytes};      //parity check for torn page        //note: wasted space is room for enhanced checksum in future
    prevPage:PageId;
    thisPage:PageId;
    pageType:byte{padded to 4 bytes};       //note: wasted space is room for future expansion     
    ownerRef:cardinal;                      //future use as owner-object-id e.g. which table this belongs to (useful for buffer-policy-debugging & fixing etc)
    nextPage:PageId;
    data:TBlock;
    tearEnd:byte{padded to 4 bytes};        //parity check for torn page
  end; {TPageBlock}

  TPage=class            //page in memory
    private
//      PageCS:TcriticalSection;//page access mutex - used to protect access to latchTranId
      PageCS:TmultiReadExclusiveWriteSynchronizer;     //page access mutex - used to protect access to latchTranId
      latchStampId:StampId;       //tran-id of latch holder
    public
      block:TPageBlock;         //disk block data  (just need getAddrPtr(offset) for file.read)
                                //todo Should take account of latch when setting block attributes! - only in uDatabase?

      dirty:boolean;            //page dirty flag - set by read/write page routines
      constructor Create;
      destructor Destroy; override;

      function AsCardinal(St:TStmt;offset:integer):cardinal;
      procedure AsBlock(St:TStmt;offset:integer;len:integer;p:pointer);

      procedure SetCardinal(St:TStmt;offset:integer;v:cardinal);  //deprecated
      procedure SetBlock(St:TStmt;offset:integer;len:integer;p:pointer);

      function latch(St:TStmt):integer;
      function Unlatch(St:TStmt):integer;

      function latchUnlatch(st:Tstmt):integer;

      function debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
  end; {TPage}

var
  emptyPage:TPage;            //used to create new disk pages

  debugLatchCount:int64; //cardinal;
  //todo we should keep count of number of contentions

implementation

uses uLog; //todo remove

const
  where='uPage';
  who='';

constructor TPage.Create;
const routine=':create';
begin
  fillchar(block.data,sizeOf(block.data),0); //zeroise
  block.tearStart:=0;
  block.prevPage:=InvalidPageId;
  block.thisPage:=InvalidPageId;
  block.nextPage:=InvalidPageId;
  block.ownerRef:=0;
  block.pageType:=ptEmpty;
  block.tearEnd:=0;
  dirty:=False;
  latchStampId:=InvalidStampId;
//  PageCS:=TCriticalSection.Create;
  PageCS:=TmultiReadExclusiveWriteSynchronizer.Create;
{$IFDEF DEBUG_LOG}
//    log.add(who,where+routine,'Failed creating page mutex',vAssertion);
{$ELSE}
;
{$ENDIF}
end;
destructor TPage.Destroy;
const routine=':Destroy';
begin
//  log(where+routine,'page destroy...',vdebug);
  {$IFDEF DEBUG_LOG}
  if (latchStampId.tranId<>InvalidStampId.tranId) then log.add(who,where+routine,format('Page is still latched by %d:%d',[latchStampId.tranId,latchStampId.stmtId]),vAssertion);
  {$ENDIF}
  //todo maybe assert we can BeginWrite/EndWrite here?
  PageCS.Free; //todo check not already free - can't happen?
  inherited;
end;

function TPage.AsCardinal(St:TStmt;offset:integer):cardinal;
const routine=':AsCardinal';
begin
  //inc(readCount);
  PageCS.BeginRead;
  try
    if (offset>=BlockSize) or (offset<0) then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Invalid offset, %d, ignoring',[offset]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    move(block.data[offset],result,SizeOf(result));
  finally
    //dec(readCount);
    PageCS.EndRead;
  end; {try}
end;

procedure TPage.AsBlock(St:TStmt;offset:integer;len:integer;p:pointer);
const routine=':AsBlock';
begin
  //todo also that pointer+len is allocated?
  //inc(readCount);
  PageCS.BeginRead;
  try
    if (offset>=BlockSize) or (offset<0) then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Invalid offset, %d, in page %d ignoring',[offset,block.thisPage]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    move(block.data[offset],p^,len);
  finally
    //dec(readCount);
    PageCS.EndRead;
  end; {try}
end;

procedure TPage.SetCardinal(St:TStmt;offset:integer;v:cardinal);
const routine=':SetCardinal';
begin
  {Assert latched} //todo remove
  if (latchStampId.tranId<>st.Rt.tranId) and (latchStampId.stmtId<>st.Rt.stmtId) then
  begin
    if latchStampId.tranId=InvalidStampId.tranId then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Page is not latched before set',vAssertion)
      {$ENDIF}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page is latched by %d:%d before set by %d:%d',[latchStampId.tranId,latchStampId.stmtId,st.Rt.tranId,st.Rt.stmtId]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.logFlush; //todo remove
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort //todo raise exception or return ok/fail - although it is an assertion...
  end;

  {Note: loophole, but latchStampId cannot change except by caller latch/unlatch
         = caller sequence protected because we currently only use a single thread per transaction
         and that thread should call Set after latch and before unlatch (blocked)
  }
  if (offset>=BlockSize) or (offset<0) then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Invalid offset, %d, ignoring',[offset]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  move(v,block.data[offset],SizeOf(v));
end;

procedure TPage.SetBlock(St:TStmt;offset:integer;len:integer;p:pointer);
const routine=':SetBlock';
begin
  {Assert latched} //todo remove
  if (latchStampId.tranId<>st.Rt.tranId) and (latchStampId.stmtId<>st.Rt.stmtId) then
  begin
    if latchStampId.tranId=InvalidStampId.tranId then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d is not latched before set - aborting',[block.thisPage]),vAssertion)
      {$ENDIF}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Page %d is latched by %d:%d before set by %d:%d - aborting',[block.thisPage,latchStampId.tranId,latchStampId.stmtId,st.Rt.tranId,st.Rt.stmtId]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.logFlush; //todo remove
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort //todo raise exception or return ok/fail - although it is an assertion...
  end;

  {Note: loophole, but latchStampId cannot change except by caller latch/unlatch
         = caller sequence protected because we currently only use a single thread per transaction
         and that thread should call Set after latch and before unlatch (blocked)
  }

  //todo also that pointer+len is allocated?
  if (offset>=BlockSize) or (offset<0) then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Invalid offset, %d, in page %d ignoring',[offset,block.thisPage]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  move(p^,block.data[offset],len);
end;

function TPage.Latch(St:TStmt):integer;
{Latches the page for single-thread access
 Call before modifying a page via the Set routines.

 Note:
   this routine may wait/loop until the page can be latched
   //todo test how this loop affects the processor

 Assumes:
   the page is pinned in the frame first (caller's responsibility)

 Note: keep in sync. with latchUnlatch

 RETURNS:    +ve=ok, else fail (& not latched)
}
//todo can we assert that it is pinned?
const routine=':latch';
var
  timeoutRetry:integer;
begin
  result:=fail;
  PageCS.BeginWrite; //note: will block
  latchStampId:=st.Rt; //latched= restrict reads to this transaction and allow writes by this transaction (only)
  inc(debugLatchCount); //todo note: not thread safe!
  result:=ok;
end; {latch}

function TPage.Unlatch(St:TStmt):integer;
{Unlatches the page after single-thread access
 Call after modifying a page via the Set routines.

 Note:
   this routine may wait/loop until the page can be unlatched //todo should never need to?
   //todo test how this loop affects the processor - if it ever can happen!

   this routine must always been called after a latch

 Assumes:
   the page has been latched first (caller's responsibility)

 Note: keep in sync. with latchUnlatch

 RETURNS:    +ve=ok, else fail
}
const routine=':unlatch';
begin
  result:=fail;
  latchStampId:=InvalidStampId; //unlatched= allow reads by anyone and allow other's to latch //28/01/03 moved before endWrite: was causing race condition where setblock appeared unlatched!
  PageCS.EndWrite;
  result:=ok;
end; {unlatch}

function TPage.latchUnlatch(st:Tstmt):integer;
{Waits for control of the critical section and releases it immediately
 without updating the latch tran owner reference

 Used for buffer manager queuing without upsetting other areas by nesting
 latch calls.

 Note: doesn't call latch/unlatch so keep in sync.
}
begin
  result:=fail;
  PageCS.BeginWrite; //note: will block
  inc(debugLatchCount); //todo note: not thread safe!
  //todo finally
  PageCS.EndWrite;
  result:=ok;
end;


function TPage.debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
{Dump analysis of page to client

 Note: header read doesn't check if it's latched already so could read garbled header data...
}
var
  s,s2:string;
  i:integer;
  pi:integer;
begin
  result:=fail;

  if connection<>nil then
  begin
    s:=format('Page %10.10d  (Previous %10.10d  Next %10.10d)',[block.thisPage, block.prevPage, block.nextPage]);
    connection.WriteLn(s);
    //todo ownerRef...

    s:=format('Type %2.2d (%s)',[block.pageType, pageTypeText[block.pageType]]);
    connection.WriteLn(s);

    if not summary then
    begin
      s:=format('(Tear start %2.2x, Tear end %2.2x)',[block.tearStart, block.tearEnd]);
      connection.WriteLn(s);

      s:='';
      if dirty then s:='(Dirty)';
      connection.WriteLn('Data: '+s);


      s:='';
      {Read each byte & display as a hex block}
      for i:=0 to sizeof(block.data)-1 do
      begin
        asBlock(st,i,1,@pi);
        s:=s+format('%2.2x ',[pi]);
        if length(s)>=16*(2+1) then //new line after 16 bytes
        begin
          connection.WriteLn(s);
          s:='';
        end;
      end;
      connection.WriteLn(s);
    end;

  end;

  result:=ok;
end; {debugDump}


initialization
  emptyPage:=TPage.create;
  assert(sizeof(emptyPage.block)=DiskBlockSize,'uPage: emptyPage.Block <> DiskBlockSize');
  debugLatchCount:=0;

finalization
  emptyPage.free;

end.

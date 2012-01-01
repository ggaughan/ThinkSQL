unit uVirtualFile;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{DB-file management routines
 Implements AddRecord, ReadRecord and sequential scan for a virtual file
 (using no disk space)

 Copied from THeapFile

 Keep in sync. with uDatabase createDB, relation open, database maint etc.
}

//{$DEFINE DEBUGDETAIL}      //debug detail
//{$DEFINE DEBUGDETAIL2}       //debug detail, e.g. update

interface

uses uFile, uPage, uGlobalDef, uGlobal,
     uStmt, {todo remove!}IdTCPConnection{debug only}, uTuple, uDatabase;

type
  VirtualFileType=(vfUnknown,
                   vfsysTransaction,
                   vfsysServer,vfsysStatusGroup,vfsysStatus,vfsysServerStatus,
                   vfsysCatalog,vfsysServerCatalog);

  TVirtualFile=class(TDBFile)         //virtual database file
  private
//    fCurrentRid:TRid; //todo remove!
    fType:VirtualFileType;
    noRecords:integer;
    tempPage:Tpage;
    tempTuple:TTuple;

    nextNode:TtranNodePtr;
    nextPtr:pointer;
    nextIndex:integer;

    processedFirstEnum, processedFirstEnum2:boolean;
    nextServer:TsysServer;
    nextStatusGroup:TsysStatusGroup;
    nextStatus:TsysStatus;
  public
    constructor Create(t:TTuple); reintroduce;
    destructor Destroy; override;

    function createFile(st:TStmt;const fname:string):integer; override;
    function openFile(st:TStmt;const filename:string;startPage:PageId):integer; override;
    function freeSpace(st:TStmt;page:TPage):integer; override;

    function GetScanStart(st:TStmt;var rid:Trid):integer; override;
    function GetScanNext(st:TStmt;var rid:Trid;var noMore:boolean):integer; override;
    function GetScanStop(st:TStmt):integer; override;

    function ReadRecord(st:TStmt;page:TPage;sid:SlotId;r:Trec):integer; override;

    function AddRecord(st:TStmt;r:Trec;var rid:Trid):integer; override;
    //todo Update: updates rid data with new rid data, i.e. Tr=rid.wt

    function debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer; override;

    //todo override dbFile routines like DirCount to give a guesstimate at least, rather than an error
  end; {TVirtualFile}


implementation

uses uLog, sysUtils, uServer,
     uBuffer{for stats}, uSyntax{for debug status}, uTransaction,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for sqltimestamp},
     classes {for PPointerList}, Math {for power}
;

const
  where='uVirtualFile';

constructor TVirtualFile.Create(t:TTuple);
{IN:        t      caller's (i.e. relation's) tuple definition - used to return data in correct format
}
const routine=':create';
begin
  inherited Create;
  tempTuple:=TTuple.Create(self);
  tempTuple.CopyTupleDef(t);
  tempPage:=TPage.create;
end; {Create}
destructor TVirtualFile.Destroy;
const routine=':destroy';
begin
  {Destroy page}
  tempPage.free;
  {Destroy tuple}
  tempTuple.free;

  inherited;
end; {destroy}

function TVirtualFile.createFile(st:TStmt;const fname:string):integer;
{Creates a virtual file in the specified database
 IN       : db          the database
          : fname       the new filename
 RETURN   : +ve=ok, else fail
}
const routine=':createFile';
begin
  {Note: we could remove createFile and create nothing, but:
   currently the tuple read routines expect to use the page pointed at by the rid
   to pin/unpin & read the data from, using some dummy page like 0 would overwrite a real
   buffer page & be shared by other virtual files = join garbage..
   so for now what's a wasted page? - it might even be useful in future...
   (& it keeps the garbage collector & optimiser a bit happier)

   Note: we write the dummy rows to our own internal tempPage to avoid multiuser conflicts

   Note: we assume we never need to delete such a 'system' file but if we tried
   the standard tfile routine should suffice? except...
  }
  result:=inherited CreateFile(st,fname);
  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Virtual-file %s created',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {createFile}

function TVirtualFile.openFile(st:TStmt;const filename:string;startPage:PageId):integer;
{Opens a virtual file in the specified database
 IN       : db          the database
          : filename    the existing filename
          : startPage   the start page for this file (found by caller from catalog)
                        -Note: not used here
 RETURN   : +ve=ok, else fail

 Side effects:
   sets fStartPage for this file
   sets fname for this file
   sets ftype for this file

 Assumes:
   filename and startpage are valid
}
const routine=':openFile';
begin
  {See notes on file creation: we do need a start page but not for storage}
  result:=inherited openFile(st,filename,startPage);

  fType:=vfUnknown;
  if uppercase(fname)=uppercase(sysTransaction_table) then ftype:=vfsysTransaction;     //per catalog -> IS.ACTIVE_TRANSACTIONS
  if uppercase(fname)=uppercase(sysServer_table) then ftype:=vfsysServer;               //per server (1 meta)
  if uppercase(fname)=uppercase(sysStatusGroup_table) then ftype:=vfsysStatusGroup;     //per server (meta)
  if uppercase(fname)=uppercase(sysStatus_table) then ftype:=vfsysStatus;               //per server (meta)
  if uppercase(fname)=uppercase(sysServerStatus_table) then ftype:=vfsysServerStatus;   //per server
  if uppercase(fname)=uppercase(sysCatalog_table) then ftype:=vfsysCatalog;             //per catalog -> IS.INFORMATION_SCHEMA_CATALOG_NAME (id not exposed)
  if uppercase(fname)=uppercase(sysServerCatalog_table) then ftype:=vfsysServerCatalog; //per server

  if result=ok then
  begin
    //goto first record?
  end;
end; {openFile}

function TVirtualFile.freeSpace(st:TStmt;page:TPage):integer;
{Returns amount of free record space in the specified page
 IN      : page    the page to examine - not used here
 RETURN  : the amount of free space - always 0 here

 Assumes:
}
const routine=':freeSpace';
begin
  result:=0;
end; {FreeSpace}

function TVirtualFile.GetScanStart(st:TStmt;var rid:Trid):integer;
{Get start point for virtual file scan
 OUT   : rid         1 before the 1st rid
}
const routine=':GetScanStart';
begin
  result:=ok;

  fCurrentRid.pid:=startPage; //dummy data area
  fCurrentRid.sid:=0; //dummy data area (not used)

  rid:=fCurrentRid; //Note: we never advance this for these virtual files

  nextNode:=nil;
  nextPtr:=nil;
  nextIndex:=-1;
  processedFirstEnum:=false;
  processedFirstEnum2:=false;

  case fType of
    vfsysTransaction:   nextNode:=nil;

    vfsysServer:        nextServer:=low(TsysServer);
    vfsysStatusGroup:   nextStatusGroup:=low(TsysStatusGroup);
    vfsysStatus:        nextStatus:=low(TsysStatus);
    vfsysServerStatus:  begin nextServer:=low(TsysServer); nextStatus:=low(TsysStatus); end;

    vfsysCatalog:       ;

    vfsysServerCatalog: begin nextPtr:=nil; nextIndex:=-1; end;
  else
    noRecords:=0;
  end; {case}
end; {GetScanStart}

function TVirtualFile.GetScanNext(st:TStmt;var rid:Trid;var noMore:boolean):integer;
{Reads a pointer to the next record in sequence
 OUT       : rid        the rid of the next record
           : noMore     True if no more records, else False
 RESULT    : +ve=ok, else fail
}
const routine=':GetScanNext';
begin
  result:=ok;
  noMore:=False;

  {Move on or return noMore}
  case fType of
    vfsysTransaction:
    begin
      if nextNode=nil then
        nextNode:=Ttransaction(st.owner).db.tranList //1st
      else
      begin
        try //rather than lock the transaction's live list, we guard against list corruption
          nextNode:=nextNode.next; //next
        except
          nextNode:=nil; //terminate list traversal
          //todo return fail!??
        end; {try}
      end;
      if nextNode=nil then noMore:=True;
    end; {vfsysTransaction}
    vfsysServer:
    begin
      if processedFirstEnum then
      begin
        if nextServer=high(TsysServer) then noMore:=True else nextServer:=succ(nextServer);
      end
      else
        processedFirstEnum:=true;
    end; {vfsysServer}
    vfsysStatusGroup:
    begin
      if processedFirstEnum then
      begin
        if nextStatusGroup=high(TsysStatusGroup) then noMore:=True else nextStatusGroup:=succ(nextStatusGroup);
      end
      else
        processedFirstEnum:=true;
    end; {vfsysStatusGroup}
    vfsysStatus:
    begin
      if processedFirstEnum then
      begin
        if nextStatus=high(TsysStatus) then noMore:=True else nextStatus:=succ(nextStatus);
      end
      else
        processedFirstEnum:=true;
    end; {vfsysStatus}
    vfsysServerStatus:
    begin
      if processedFirstEnum then
      begin
        if nextStatus=high(TsysStatus) then
        begin
          //if processedFirstEnum2 then
          begin
            if nextServer=high(TsysServer) then
              noMore:=True
            else
            begin
              nextServer:=succ(nextServer);
              nextStatus:=low(TsysStatus);
              processedFirstEnum:=false;
            end;
          end
          //else
          //  processedFirstEnum2:=true;
        end
        else
          nextStatus:=succ(nextStatus);
      end
      else
        processedFirstEnum:=true;
    end; {vfsysServerStatus}
    vfsysCatalog:
    begin
      if processedFirstEnum then
      begin
        noMore:=True;
      end
      else
        processedFirstEnum:=true;
    end; {vfsysCatalog}
    vfsysServerCatalog:
    begin
      if nextPtr=nil then
      begin
        with (Ttransaction(st.owner).db.owner as TDBserver).dbList.locklist do
          try
            nextPtr:=list; //1st
            noRecords:=count;
            nextIndex:=0;
          finally
            (Ttransaction(st.owner).db.owner as TDBserver).dbList.unlockList;
          end; {try}
      end
      else
      begin
        //rather than lock the transaction's live list, we guard against list corruption
        nextIndex:=nextIndex+1; //next
      end;
      if nextIndex>=noRecords then noMore:=True;
    end; {vfsysServerCatalog}
  else
    fCurrentRid.sid:=fCurrentRid.sid+1;
    if fCurrentRid.sid>noRecords then noMore:=True;
  end; {case}

  rid:=fCurrentRID; //todo remove: never advances here
end; {GetScanNext}

function TVirtualFile.GetScanStop(st:TStmt):integer;
{Finalise virtual file scan
}
const routine=':GetScanStop';
begin
  {Reset the current RID}
  fCurrentRID.pid:=InvalidPageId;
  fCurrentRID.sid:=InvalidSlotId;

  result:=ok;
end; {GetScanStop}

function TVirtualFile.ReadRecord(st:TStmt;page:TPage;sid:SlotId;r:Trec):integer;
{Reads a record for a specified slot by pointing r.dataPtr to the record in the page
 IN    : page         the page (actually ignored here in favour of internal tempPage since we write fake data to it!)
       : sid          the slot id
 OUT   : r            the record
                          len
                          dataPtr
                          Wt
                          PrevRID
 RETURN: +ve=ok, else fail

 Assumes:
   the page is pinned
}
const routine=':ReadRecord';
var
  isolationDesc:string;
  bufLen:integer;
  i:int64; //integer;
  s:string;
  ts:TsqlTimestamp;
  inull,snull:boolean;

  dd,dm,dy:word;
  tmh,tmm,tms,tmms:word;

  hs:THeapStatus;
begin
  result:=fail;
  {Pass back slot entry in the record}
  r.rType:=rtRecord;
  r.Wt:=st.Rt;
  r.PrevRID.pid:=InvalidPageId;
  r.PrevRID.sid:=InvalidSlotId;
  {Point record data}
//  r.dataPtr:=nil; //todo! @page.block.data[slot.start];    //i.e. slot points to disk, rec points to memory
//  i:=fColCount;
//  move(i,fRecData[0],SizeOf(ColRef));
  if page.block.data=nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Page is nil!',[nil]),vAssertion);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;

  r.dataPtr:=@tempPage.block.data[0]; //Note: this is our own local (ptEmpty) page (not in the buffer, no need to use PageCS)
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('r.dataptr set to page %d data[0]',[tempPage.block.thisPage]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo zeroise data?
  tempTuple.clear(st);

  {Set column data}
  case fType of
    vfsysTransaction:
    begin
      try //rather than lock the transaction's live list, we guard against list corruption
        with (nextNode.tran as TTransaction) do
        begin
          tempTuple.SetInteger(0,tranRt.tranId,False);
          tempTuple.SetString(1,pchar(authName),False);
          case isolation of
            isSerializable:    isolationDesc:='Serializable';
            isReadCommitted:   isolationDesc:='Read committed';
            isReadUncommitted: isolationDesc:='Read uncommitted';
            isReadCommittedPlusUncommittedDeletions:    isolationDesc:='Read committed (1)'; //internal: 1=plus uncommitted deletions
            isReadUncommittedMinusUncommittedDeletions: isolationDesc:='Read uncommitted (2)'; //internal: 2=minus uncommitted deletions
          else
            isolationDesc:='?';
          end; {case}
          tempTuple.SetString(2,pchar(isolationDesc),False);

          //todo list stmts and their current status?
        end; {with}
      except
        //ignore & leave clear
      end; {try}
    end; {sysTransaction}
    vfsysServer:
    begin
      //todo use (tr.db.owner as TDBServer)
      tempTuple.SetInteger(0,ord(nextServer),False);
      tempTuple.SetString(1,pchar(serverName),False);
    end; {vfsysServer}
    vfsysStatusGroup:
    begin
      tempTuple.SetInteger(0,ord(nextStatusGroup),False);
      tempTuple.SetString(1,pchar(StatusGroupString[nextStatusGroup]),False);
    end; {vfsysStatusGroup}
    vfsysStatus:
    begin
      tempTuple.SetInteger(0,ord(nextStatus),False);
      i:=0;
      case nextStatus of
        {$IFDEF DEBUG_LOG}
        ssDebugSyntaxCreate,ssDebugSyntaxDestroy:                             i:=ord(ssDebug);
        {$ENDIF}

        ssProcessUptime:                                                      i:=ord(ssProcess);
        ssMemoryManager,ssMemoryHeapAvailable,ssMemoryHeapCommitted,ssMemoryHeapUncommitted,
        ssMemoryHeapAllocated,ssMemoryHeapFree:                               i:=ord(ssMemory);

        ssCacheHits, ssCacheMisses:                                           i:=ord(ssCache);

        ssTransactionEarliestUncommitted:                                     i:=ord(ssTransaction);
      //todo else assertion
      end; {case}
      tempTuple.SetInteger(1,i,False);
      tempTuple.SetString(2,pchar(StatusString[nextStatus]),False);
    end; {vfsysStatus}
    vfsysServerStatus:
    begin
      tempTuple.SetInteger(0,ord(nextServer),False);
      tempTuple.SetInteger(1,ord(nextStatus),False);
      i:=0;  inull:=false; //default to number
      s:=''; snull:=true;
      case nextServer of
        ssMain:
        case nextStatus of
          {$IFDEF DEBUG_LOG}
          ssDebugSyntaxCreate:          i:=uSyntax.debugSyntaxCreate;
          ssDebugSyntaxDestroy:         i:=uSyntax.debugSyntaxDestroy;
          {$ENDIF}

          ssProcessUptime:              i:=trunc((now-(Ttransaction(st.owner).db.owner as TDBServer).startTime)* (60*60*24)); //seconds

          ssMemoryManager:              begin snull:=false; inull:=true; if IsMemoryManagerSet then s:='MultiMM' else s:='Borland'; end;
          ssMemoryHeapAvailable,ssMemoryHeapCommitted,ssMemoryHeapUncommitted,
          ssMemoryHeapAllocated,ssMemoryHeapFree:
          begin
            {$IFDEF WIN32}
            hs:=GetHeapStatus;  //todo use uOS for Linux...
            case nextStatus of
              ssMemoryHeapAvailable:    i:=hs.TotalAddrSpace;
              ssMemoryHeapCommitted:    i:=hs.totalCommitted;
              ssMemoryHeapUncommitted:  i:=hs.totalUncommitted;
              ssMemoryHeapAllocated:    i:=hs.totalAllocated;
              ssMemoryHeapFree:         i:=hs.TotalFree;
            end; {case}
            {$ENDIF}
          end; {MemoryHeap}

          ssCacheHits:   i:=(Ttransaction(st.owner).db.owner as TDBServer).buffer.statusBufferHit;
          ssCacheMisses: i:=(Ttransaction(st.owner).db.owner as TDBServer).buffer.statusBufferMiss;

          ssTransactionEarliestUncommitted: i:=Ttransaction(st.owner).earliestUncommitted.tranId;
          //todo etc.

        //else leave as null
        end; {case}
      end; {case}
      //tempTuple.SetInteger(2,i,inull);
      tempTuple.SetBigInt(2,i,inull);
      tempTuple.SetString(3,pchar(s),snull);
    end; {vfsysServerStatus}
    vfsysCatalog:
    begin
      tempTuple.SetInteger(0,sysCatalogDefinitionCatalogId{=1: all catalog ids are 1 - todo would be nice to make them unique per cluster},False);
                                                           //so we currently don't expose the catalog_id anywhere...just the name which is unique per cluster/server                     
      tempTuple.SetString(1,pchar((Ttransaction(st.owner).db).dbName),False);
    end; {vfsysCatalog}
    vfsysServerCatalog:
    begin
      try //rather than lock the server's live list, we guard against list corruption
        with TDB(PPointerList(nextPtr)^[nextIndex]) do
        begin
          tempTuple.SetInteger(0,ord(ssMain),False); //note: assumes 1 server
          tempTuple.SetString(1,pchar(dbName),False);
          decodeDate(opened,dy,dm,dd);
          decodeTime(opened,tmh,tmm,tms,tmms);
          ts.date.year:=dy; ts.date.month:=dm; ts.date.day:=dd;
          ts.time.hour:=tmh; ts.time.minute:=tmm; ts.time.second:=round(tms*power(10,TIME_MAX_SCALE)); ts.time.scale:=0;
          tempTuple.SetTimestamp(2,ts,False);
          if (Ttransaction(st.owner).db.owner as TDBserver).getInitialConnectdb=TDB(PPointerList(nextPtr)^[nextIndex]) then
            tempTuple.SetString(3,pchar(NoYes[true]),False)
          else
            tempTuple.SetString(3,pchar(NoYes[false]),False);
        end; {with}
      except
        //ignore & leave clear
      end; {try}
    end; {vfsysServerCatalog}
  else
    //todo log assertion... for now return no data!
  end; {case}

  //todo do we need to preInsert now? we probably should!
  tempTuple.preInsert;
  r.len:=tempTuple.GetDataLen;  //todo remove need for this routine: set to bufLen next...

  tempTuple.CopyDataToFixedBuffer(@tempPage.block.data[0]{todo remove:r.dataPtr},bufLen);


  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%d:%d record read as Wt=%d:%d rType=%d prev.pid=%d prev.sid=%d len=%d',[tempPage.block.thispage,sid,r.wt.tranId,r.wt.stmtId,ord(r.rtype),r.prevRID.pid,r.prevRID.sid,r.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {ReadRecord}

function TVirtualFile.AddRecord(st:TStmt;r:Trec;var rid:Trid):integer;
{Add a new record to the file - actually does nothing here except raise an assertion!
 IN    : st           the statement
       : r            the record
                      Note: assumes set properly, i.e.
                            Wt, prevRID, len, rType
 OUT   : rid          the rid used
 RETURN: +ve=ok, else fail
}
const routine=':AddRecord';
begin
  result:=Fail;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Should not be called on a virtual file!',[nil]),vAssertion);
  {$ENDIF}
end; {AddRecord}

function TVirtualFile.debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
{
 Note: this will ruin any scan in progress
}
const routine=':debugDump';
var
  totalPages,space,totalUsed,totalSpace{todo remove: meaningless:,totalContiguousSpace}:integer;
begin
  inherited debugDump(st,connection,summary); //todo remove?

  result:=ok;

  totalPages:=0;
  totalUsed:=0;
  totalSpace:=0;

  connection.WriteLn(format('Table space: pages=%10.10d total data=%12.12d used=%12.12d free=%12.12d',
                        [totalPages,
                         totalUsed+totalSpace,
                         totalUsed,
                         totalSpace
                        ]));
end; {debugDump}

end.

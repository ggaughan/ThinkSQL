unit uDatabase;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUG_ALLOCDETAIL}  //page allocation details
{$DEFINE SAFETY} //note: can turn off when live (so far in this unit): speed

//{$DEFINE SKIP_MANUAL_INDEXES}   //turn off manual index opening - debug only - remove when live!

{$DEFINE CACHE_GENERATORS}  //cache generators by CACHE_GENERATORS_COUNT

{A database uses its server's buffer manager to interface to its disk file
 It includes/provides:
   system catalog (relations)

 27/01/03 A database here is now definitely an SQL catalog (was considering making it a cluster)

 Note: buffer.pinPage etc. use the st.owner.db to work out the database, not the Tdb source of the call
       so most of these routines assume st.owner.db = self! else strange things will happen! 
}

interface

uses uGlobal, SyncObjs {for Critcal Sections}, sysutils, classes {for TBits}, IdTCPConnection{debug only}, uStmt;

type
  TdbHeader=record //db header page data layout
    structureVersionMajor:word;      //increase = incompatible
    structureVersionMinor:word;      //increase = compatible
    diskBlockSize:integer;
    dbmap:PageId;
    dbdir:PageId;
  end; {Tdbheader}

  TtranNodePtr=^TtranNode;
  TtranNode=record
    tran:TObject; {TTransaction}
    next:TtranNodePtr;
  end; {TtranNode}

  TcachedGeneratorPtr=^TcachedGenerator;
  TcachedGenerator=record
    schemaId:integer;   //schema id
    name:string;        //generator name
    id:integer;         //generator id
    next:integer;       //next
    limit:integer;      //limit = last to be issued = next on disk-1
  end;

  TDB=class
    private
      fowner:TObject;    //owner - i.e. server - allows buffer manager calls
      fdbname:string;    //the db reference name = catalog name
      ffname:string;     //db disk filename
      fopened:Tdatetime; //opened date/time

      diskfile:file;                   //untyped db file
      diskfileCS:TCriticalSection;  //protect diskfile access
                                    //Note: also protects use of shared emptyPage

      dbHeader:TdbHeader;              //db header page info
      dbnext:TDB;                      //pointer to next db in this server (linked list)

      {I think we need to keep this because when creating a new catalog, we
       can't use the getGeneratorNext because the generator tables don't exist yet.
       So it's needed for bootstrapping, but can't we then switch power to a sysTable_generator?
       for user tables? In which case we could use a simple unprotected memory counter
       during catalog creation - would be nice to hook into getGeneratorNext to keep transparent
       - e.g. if generatorName=sysTable_generator and still creating then result:=inc(nextsysTable) else...
	TODO
      }
      fsysTable_LastTableId:integer;                //table_id counter

      {I think we can switch over from using this after creation if we add a hook in
       getGeneratorNext that returns this if we are still creating a new catalog else generator.next}
      fsysSchema_LastSchemaId:integer;
      fsysDomain_LastDomainId:integer;

      {Cached generators}
      cachedGenerators:TList;

      {System catalog (more SQL specifically the catalog catalog!)
       Note: some of these relations will be duplicated per transaction
             to give greater concurrency.
             Note: maybe not sysTran/sysTranStmt - needs some thought first...
                   and maybe not sysGenerator - needs to be centralised, although we'd
                     only be distributing scan ability - they'd still all share same (latchable) buffer page!
             But (for now) all will be accessed via central Tdb routines - see below
      }
      catalogRelation:array [catalogRelationIndex] of Tobject; //TRelation
      catalogRelationCS:array [catalogRelationIndex] of TCriticalSection; //protect centralised catalog access
                                                                          //Note: some may not be used if duplicated at Tr level
    public

      {Transactions}
      tranList:TtranNodePtr;           //list of currently connected transactions
      tranListCS:TmultiReadExclusiveWriteSynchronizer;  //protect transaction list access
      tranListNextNode:TtranNodePtr;   //cursor for TransactionScan

      tranCommittedOffset:cardinal;     //tracks earliest tran-id in tranCommitted array
      tranCommitted:Tbits;             //tracks committed/rolled-back transactions in current session
      tranPartiallyCommitted:Tbits;    //tracks committed transactions that have partial stmt roll-back info
      tranPartiallyCommittedDetails:pointer{TtranStatusPtr};  //stores partial stmt roll-back info
      {Note the above work as follows:
                                               active  fully-committed  partially-committed  fully-rolled-back
            tranCommitted                         F           T                  T                   F
            tranPartiallyCommitted                F           F                  T                   T
            tranPartiallyCommittedDetails        n/a         n/a             stmt-list              n/a

       so maybe a better name would be tranRolledBack instead of tranPartiallyCommitted?
      }
      SysOption:array [otOptimiser..otOptimiser] of record value:integer; text:string; end;

      constructor Create(Aowner:TObject;dbname:string);
      destructor Destroy; override;
      property owner:TObject read fowner;
      property dbName:string read fdbName write fdbName;
      property fName:string read ffname; //test: if '' then not open (i.e. being created?)
      property opened:Tdatetime read fopened write fopened;

      function CreateFile(st:Tstmt;name:string):integer;
      function openFile(name:string):integer;
      function closeFile:integer;
      function createDB(name:string;emptyDB:boolean):integer;
      function createSysIndexes(st:Tstmt):integer;
      function createInformationSchema:integer;
      function openDB(fname:string;emptyDB:boolean):integer;

      {DB directory}
      function getFile(st:Tstmt;fname:string;var pid:PageId):integer;
      function addFile(st:Tstmt;fname:string;var pid:PageId;needDirEntry:boolean):integer;
      function removeFile(st:Tstmt;fname:string;pid:PageId;needDirEntry:boolean):integer;
      procedure dirStatus(st:Tstmt);

      {Make private & buffer=friend?}
      function readPage(id:PageId;p:TObject{TPage}):integer;   //low-level page read
      function writePage(id:PageId;p:TObject{TPage}):integer;  //low-level page write
      function allocatePage(st:Tstmt;var id:PageId):integer;       //low-level page allocation
      function deallocatePage(st:Tstmt;id:PageId):integer;         //low-level page de-allocation

      {transactions}
      function addTransaction(Tr:TObject{TTransaction}):integer;
      function removeTransaction(Tr:TObject{TTransaction}):integer;
      function detachAnyTransactions(Tr:TObject{TTransaction}):integer;
      function showTransactions:string;
      function TransactionScanStart:integer;
      function TransactionScanNext(var Tr:TObject{TTransaction}; var noMore:boolean):integer;
      function TransactionScanStop:integer;
      function findTransaction(FindRt:StampId):TObject{TTransaction};
      function TransactionIsCommitted(CheckWt:StampId):boolean;
      function TransactionIsRolledBack(CheckWt:StampId):boolean;
      function TransactionIsActive(CheckWt:StampId):boolean;

      {debug}
      procedure Status;

      {Catalog access routines}
      //Note: these can choose whether to use a shared db relation & serialise access
      //      or use the caller's transaction catalog relation(s)
      //      Because some may need serialising, caller should call start/stop around
      //      any routines that depend on last state of relation (i.e. current cursor position)
      //      so that the routines can lock and unlock the resource if need be.

      function catalogRelationStart(st:Tstmt;cri:catalogRelationIndex;var rel:TObject{Trelation}):integer;
      function catalogRelationStop(st:Tstmt;cri:catalogRelationIndex;var rel:TObject{Trelation}):integer;

      function findCatalogEntryByString(st:Tstmt;
                                      rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;
      function findCatalogEntryByInteger(st:Tstmt;
                                      rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;

      function findFirstCatalogEntryByInteger(st:Tstmt;
                                            rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;
      function findNextCatalogEntryByInteger(st:Tstmt;
                                           rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;
      function findFirstCatalogEntryByString(st:Tstmt;
                                            rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;
      function findNextCatalogEntryByString(st:Tstmt;
                                           rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;

      function findDoneCatalogEntry(st:Tstmt; rel:Tobject{Trelation}):integer;

      function getGeneratorNext(st:Tstmt;schema_id:integer;
                                const generatorName:string;var generator_id:integer;var next:integer):integer;
      function uncacheGenerator(st:Tstmt;schema_id:integer;
                                const generatorName:string;generator_id:integer):integer;

      function debugDump(st:Tstmt; connection:TIdTCPConnection;summary:boolean):integer; virtual;
  end; {TDB}


  {Overlay records}
  {Maybe move to a new unit? or upage?}
  TdbDirEntry=record
    filename:string[10];
    startPage:PageId;
  end; {TdbDirEntry}


const
  {Column references for sysTable tuples}   //note: must be sequential, else system-schema-change=db conversion required!
  sysTable_colCount=8;

  {Column references for sysColumn tuples}  //note: must be sequential, else system-schema-change=db conversion required!
  sysColumn_colCount=10;

var
  debugRelationStart:integer=0;
  debugRelationStop:integer=0;
  debugFindFirstStart:integer=0;
  debugFindFirstStop:integer=0;

implementation

uses uBuffer, uLog, uServer, uRelation, uTuple,
     uFile, uParser, uGlobalDef, uPage, uTransaction, uProcessor,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for date/time structures},
     uGarbage {for detachAnyTransactions (disconnection)}, uOS{for sleepOS}
     ;

const
  where='uDatabase';
  who='';

  WAITFOR_GC_TERMINATE=250;

constructor TDB.Create(Aowner:TObject;dbname:string);
const routine=':create';
var
  cri:catalogRelationIndex;
  i:colRef;
  oi:ToptionType;
begin
  fowner:=Aowner;
  tranlistCS:=TmultiReadExclusiveWriteSynchronizer.Create;
  diskfileCS:=TCriticalSection.Create;
  for cri:=sysTran to sysColumn do
    catalogRelationCS[cri]:=TCriticalSection.Create;

  for oi:=otOptimiser to otOptimiser do
  begin
    SysOption[oi].value:=0; SysOption[oi].text:='';

    //Set some sensible defaults in case sysOption open fails (should never happen)
    if oi=otOptimiser then SysOption[oi].value:=1;
  end;

  tranList:=nil; //initialise transaction list
  tranCommittedOffset:=InvalidTranCommittedOffset;    //will set properly (reduce) when first transaction starts
  tranCommitted:=TBits.Create;
  tranPartiallyCommitted:=TBits.Create;
  tranPartiallyCommittedDetails:=nil;

  fdbname:=dbName; //sets db name
  ffname:=''; //=> not open
  fopened:=0;
  dbnext:=nil; //initialise next db pointer
  dbHeader.structureVersionMajor:=0;
  dbHeader.structureVersionMinor:=0;
  dbHeader.diskBlockSize:=0;
  dbHeader.dbmap:=InvalidPageId;
  dbHeader.dbdir:=InvalidPageId;
  fsysTable_LastTableId:=0; //last table id
  fsysSchema_LastSchemaId:=0; //last schema id
  fsysDomain_LastDomainId:=0; //last domain id

  {Generator cache list}
  cachedGenerators:=TList.Create;

  {Create system catalog}

  for cri:=sysTran to sysColumn do
    catalogRelation[cri]:=TRelation.Create;

  {Define the 2 relations that are needed for bootstrap purposes,
   the other relation definitions can then be read during open time}
  with catalogRelation[sysTable] as TRelation do
  begin
    {Definitions}
    fTuple.ColCount:=sysTable_colCount;
    NextColId:=fTuple.ColCount+1; //needed for match
    fTuple.SetColDef(ord(st_Table_id),1,'table_id',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(st_Table_name),2,'table_name',0,ctVarChar,MaxTableName,0,'',False);
    fTuple.SetColDef(ord(st_schema_id),3,'schema_id',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(st_File),4,'file',0,ctVarChar,MaxFileName,0,'',False);
    fTuple.SetColDef(ord(st_First_page),5,'first_page',0,ctBigInt,0,0,'',False);
    fTuple.SetColDef(ord(st_Table_Type),6,'table_type',0,ctChar,1,0,'',False);
    fTuple.SetColDef(ord(st_View_definition),7,'view_definition',0,ctVarChar,MaxRecSize,0,'',False);
    fTuple.SetColDef(ord(st_Next_Col_id),8,'next_col_id',0,ctInteger,0,0,'',False);
  end; {with}

  with catalogRelation[sysColumn] as TRelation do
  begin
    {Definitions}
    fTuple.ColCount:=sysColumn_colCount;
    NextColId:=fTuple.ColCount+1; //needed for match
    fTuple.SetColDef(ord(sc_Table_id),1,'table_id',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(sc_Column_id),2,'column_id',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(sc_column_name),3,'column_name',0,ctVarChar,MaxColName,0,'',False);
    fTuple.SetColDef(ord(sc_domain_id),4,'domain_id',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(sc_reserved_1),5,'reserved_1',0,ctVarChar,1,0,'',False);
    fTuple.SetColDef(ord(sc_datatype),6,'datatype',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(sc_width),7,'width',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(sc_scale),8,'scale',0,ctInteger,0,0,'',False);
    fTuple.SetColDef(ord(uGlobal.sc_default),9,'default',0,ctVarChar,MaxRecSize,0,'',True); //default=null =>defaultNull
    fTuple.SetColDef(ord(sc_reserved_2),10,'reserved_2',0,ctVarChar,1,0,'',True);
  end; {with}

  //todo Ensure all mutexes have program-specific prefix, e.g. GDB? - check all units...
  //     (since they are visible to all Windows processes
  //      unless we use the security options...? but space overhead)

end;

destructor TDB.Destroy;
const routine=':destroy';
var
  Tr:TTransaction;
  cri:catalogRelationIndex;

  tranStatus:TtranStatusPtr;
  stmtStatus:TstmtStatusPtr;
  i:integer;
begin
  tr:=TTransaction.create; //can't pass owner as dbserver, tables are closed.
  try
    tr.connectToDB(self); //todo check result & finally disconnect

    detachAnyTransactions(tr); //ensures any garbage collectors etc. are stopped

    with (owner as TDBserver) do
    begin
      buffer.status; //show the status now that the GC has definitely finished

      buffer.flushAllPages(tr.sysStmt);
    //todo check result of flushAll- if fail, force all to be flushed, even if pinned (better than bug->corruption?)
    // but, would this ensure that we have a consistent db?

      //Need the following to assert that all pages have been unpinned
      buffer.resetAllFrames(self);
    end;
  finally
    tr.free;
  end; {try}

  //todo: assert tranlist=nil
  //todo detachAnyTransactions(tr.sysStmt) at least?

  {Destroy generator cache list}
  cachedGenerators.Pack;
  for i:=cachedGenerators.Count-1 downto 0 do
    dispose(cachedGenerators.Items[i]); //todo log lost numbers?
  cachedGenerators.Free;

  {Destroy system catalog}
  //do before flush pages as last scans may still be pinning pages
  for cri:=sysColumn downto sysTran do
    catalogRelation[cri].free;

  {Remove any transaction partially-committed lists}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Transaction committed array offset = %d, size = %d',[tranCommittedOffset,tranCommitted.size]),vdebugLow);
  {$ENDIF}
  while tranPartiallyCommittedDetails<>nil do
  begin
    tranStatus:=tranPartiallyCommittedDetails;

    {Remove any rolled-back stmt list}
    while tranStatus.rolledBackStmtList<>nil do
    begin
      stmtStatus:=tranStatus.rolledBackStmtList;
      tranStatus.rolledBackStmtList:=tranStatus.rolledBackStmtList.next;
      dispose(stmtStatus);
    end;

    tranPartiallyCommittedDetails:=TtranStatusPtr(tranPartiallyCommittedDetails).next;
    dispose(tranStatus);
  end;
  tranPartiallyCommitted.free;
  tranCommitted.free;

  closeFile;

  for cri:=sysColumn downto sysTran do
    catalogRelationCS[cri].Free;

  diskfileCS.Free;

  //todo assert translist=nil!
  tranlistCS.Free;

  inherited Destroy;
end;

function TDB.createDB(name:string;emptyDB:boolean):integer;
{Create a new database file (=catalog)
 Called by CREATE CATALOG & catalog backup routine

 IN:    name       - the name of the new database (& OS filename (minus extension))
        emptyDB    - False = create catalog_definition_schema tables to support ThinkSQL
                     True  = just create skeleton database file for population by caller

 Note: this routine doesn't add the information_schema. It is up to the caller
       to open the new database shell and to call DB.createInformationSchema.
}
const routine=':createDB';
var
  Tr:TTransaction;
  rid:Trid;
  page:TPage;

  nextId,genId:integer;

  {for adding sysTable columns tot sysColumn}
  i:ColRef;
  s:string;

  saveSchemaId:TSchemaId;

  rc:integer; //executePlan rowCount results
begin
  result:=OK;

  {reset memory variables}
  fsysSchema_LastSchemaId:=0;
  fsysDomain_LastDomainId:=0;

  tr:=TTransaction.create; //use internal transaction to create db, nil=>Start does nothing
  {We have to set transaction defaults because we cannot call tr.Connect('_SYSTEM',null)
   because sysAuth is not open/created!}
  //Note we initialise these settings before they actually exist...i.e. technically foreign key violations
  tr.CatalogId:=sysCatalogDefinitionCatalogId; //=1 default MAIN catalog
  tr.AuthId:=SYSTEM_AUTHID; //_SYSTEM authId
  tr.AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
  genId:=0; //lookup by name
  getGeneratorNext(tr.sysStmt,sysCatalogDefinitionSchemaId,'sysSchema_generator',genId,nextId);
  //todo assert nextId=sysCatalogDefinitionSchemaId! else later assumptions will be wrong
  tr.SchemaId:=nextId; //surely = sysCatalogDefinitionSchemaId? - todo assert at least!
  tr.SchemaName:=sysCatalogDefinitionSchemaName;
  tr.connectToDB(self); //we need to connect tr.db to ourself here to allow page i/o etc.

  tr.tranRt:=MaxStampId; //avoid auto-tran-start failure
  tr.SynchroniseStmts(true);

  {$IFDEF DEBUG_LOG}
  log.add(tr.sysStmt.who,where+routine,format('Creating db as %s (read %d:%d) (write %d:%d)',[tr.AuthName,tr.sysStmt.Rt.tranId,tr.sysStmt.Rt.stmtId,tr.sysStmt.Wt.tranId,tr.sysStmt.Wt.stmtId]),vdebug);
  {$ENDIF}

  try
    //todo ensure file does not already exist!?
    if CreateFile(tr.sysStmt,name)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,format('Created physical database file %s',[name]),vdebug);
      {$ELSE}
      ;
      {$ENDIF}

      {Reset db memory variables}
      fsysTable_LastTableId:=0; //last table id
      fdbname:=dbName; //sets db name
      dbnext:=nil; //initialise next db pointer
      dbHeader.structureVersionMajor:=0;
      dbHeader.structureVersionMinor:=0;
      dbHeader.diskBlockSize:=0;
      dbHeader.dbmap:=InvalidPageId;
      dbHeader.dbdir:=InvalidPageId;

      {Open new database file to add system catalogs}
      if OpenFile(name)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Failed opening new physical database file',vdebugError);
        {$ENDIF}
        result:=Fail;
        exit; //abort
      end;
      try
        {Start proper DB open...}
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Opened database file %s on %s',[ffname,dbname]),vdebug);
        {$ENDIF}
        with (owner as TDBserver) do
        begin
          if buffer.pinPage(tr.sysStmt,0,page)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Failed reading db header page',vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit;
          end;
          try
            move(page.block.data,dbHeader,sizeof(dbheader));
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('structureVersion=%d.%d',[dbheader.structureVersionMajor,dbheader.structureVersionMinor]),vdebug);
            log.add(tr.sysStmt.who,where+routine,format('DiskBlocksize=%d',[dbheader.DiskBlocksize]),vDebug);
            {$ENDIF}
            if dbheader.diskBlockSize<>DiskBlockSize then
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Incompatible diskBlocksize!',vError);
              {$ELSE}
              ;
              {$ENDIF}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'DbMap='+intToStr(dbheader.dbmap),vdebug);
            log.add(tr.sysStmt.who,where+routine,'DbDir='+intToStr(dbheader.dbdir),vdebug);
            {$ENDIF}
          finally
            buffer.unPinPage(tr.sysStmt,0);
          end; {try}
        end;

        //note: most of these system tables should have the _name as primary key - i.e. force unique!
        {Create system catalogs: sysTable}
        with (catalogRelation[sysTable] as TRelation) do
        begin
          if CreateNew(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTable_table, False, sysTable_file)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysTable_table,vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysTable_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          end;
        end; {with}
        with (catalogRelation[sysColumn] as TRelation) do
        begin
          if CreateNew(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysColumn_table, False, sysColumn_file)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysColumn_table,vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysColumn_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          end;
          {Chicken & egg (Catalog structure & catalog definitions):
                   sysTable.createNew()
                      creates sysTable
                      adds reflexive table entry to sysTable
                   sysColumn.createNew()
                      creates sysColumn
                      adds table entry to sysTable
                      adds reflexive column entries to sysColumn

                   =missing sysTable column entries, so add them manually now...
          }
          {Entries for sysTable columns
           Note: keep in sync with table ColDefs above}
          {table_id}
          fTuple.clear(tr.sysStmt);
          {Note: it is *vital* that these are added in sequential order - else strange things happen!}

          {We need to guarantee these (& all table col defs) can be read back in sequence:
           either
           1. pass KeepSequential flag to tuple.insert routine - knock on to HeapFile.addRecord - not easy
              -also impossible for future mods/inserts!
           2. modify relation.open to read back in id order
                either a) 'select from sysColumn order by id' => sort - but use quicksort!
                or     b) sort colDef/Data array after loading e.g. tuple.InternalOrderColDefs
           3. use clustered file (i.e. btree data so already sorted)
           4. add (system) index to be able to scan definitions in id order - needs to be indexed anyway...

           does it really matter (assuming we hide array of colDefs)?
            -only for 'insert into x values (orig1,orig2,orig3)'
             and for output of tuple left-right
           so maybe insert code could present/sort unlisted values by id?
           e.g. instead of set colDef[0]=orig1, use set colDef[smallest-id]=orig1 etc.
           and tuple show code/project * routine could also loop by increasing id? =>mini sort each time
               - better to sort early...
               so use 2b) for now, with future use of 3 or 4 (via 2a)...

           Note: remember: Scanning a heap-file does not guarantee any order!

           Note+: we sort the columns when we re-open the relation: it does matter a lot!
          }

          for i:=0 to (catalogRelation[sysTable] as TRelation).fTuple.ColCount-1 do
          begin
            {Note: it is *vital* that these are added in sequential order - else strange things happen!}
            fTuple.clear(tr.sysStmt);
            fTuple.SetInteger(ord(sc_table_id),1,false);
            fTuple.SetInteger(ord(sc_column_id),(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].id,false);
            s:=(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].name;
            fTuple.SetString(ord(sc_column_name),pchar(s),false); //assume never null
            fTuple.SetInteger(ord(sc_domain_id),(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].domainId,false);
            fTuple.SetString(ord(sc_reserved_1),'',True);
            fTuple.SetInteger(ord(sc_datatype),ord((catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].dataType),false);
            fTuple.SetInteger(ord(sc_width),(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].width,false);
            fTuple.SetInteger(ord(sc_scale),(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].scale,false);
            fTuple.SetString(ord(uGlobal.sc_default),pchar((catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].defaultVal),(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].defaultNull);
            fTuple.SetString(ord(sc_reserved_2),'',True);
            fTuple.insert(tr.sysStmt,rid); //Note: obviously this bypasses any constraints
    {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted column %s of %s into %s',[(catalogRelation[sysTable] as TRelation).fTuple.fColDef[i].name,sysTable_table,sysColumn_table]),vdebugLow);
            {$ELSE}
            ;
            {$ENDIF}
    {$ENDIF}
          end;

          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Inserted entries into '+sysColumn_table,vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        end; {with}

        {Now we have the two fundamental tables (sysTable & sysColumn) we can
         add other system tables}

        {Index tables - keep in sync with column enumerations in uGlobal!}
        result:=PrepareSQL(tr.sysStmt,nil,
          'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysIndex (index_id integer,'+
                                 'index_name varchar('+IntToStr(MaxIndexName)+'),'+
                                 'table_id integer,'+
                                 'index_type char(1),'+
                                 'index_origin char(1),'+
                                 'constraint_id integer,'+ //optional FK
                                 'file varchar('+IntToStr(MaxFileName)+'),'+
                                 'first_page bigint,'+
                                 'status integer'+
                                 '); ');
        if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed creating sysIndex via PrepareSQL/ExecutePlan: ',vAssertion)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Created sysIndex',vdebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(tr.sysStmt)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(tr.sysStmt,nil,
          'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysIndexColumn (index_id integer,'+
                                       'column_id integer,'+
                                       'column_sequence integer'+
                                       '); ');
        if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed creating sysIndexColumn via PrepareSQL/ExecutePlan: ',vAssertion)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Created sysIndexColumn',vdebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(tr.sysStmt)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}


        if not emptyDB then
        begin
          {Add auth (user) table - keep in sync with column enumeration in uGlobal!
           and with GRANT option which omits password column}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysAuth (auth_id integer,'+
                                  'auth_name varchar('+IntToStr(MaxAuthName)+'),'+
                                  'auth_type char(1),'+
                                  '"password" varchar('+IntToStr(MaxPassword)+'),'+ //TODO grant no access to this to PUBLIC!
                                  'default_catalog_id integer,'+  //for future use - currently no use since we must know catalog_id to get to this table & users are held per catalog
                                  'default_schema_id integer,'+
                                  'admin_role integer,'+
                                  'admin_option char(1) '+
                                  '); '
                       );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysAuth via PrepareSQL/ExecutePlan: ',vAssertion)
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysAuth',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}

          {Add the internal sysAuth rows (Note: null password=>cannot connect)}
          //remember, data here can be read by analysing EXE - encrypt/scramble!
          result:=PrepareSQL(tr.sysStmt,nil,
            'INSERT INTO sysAuth VALUES '+
            '(1,''_SYSTEM'','''+atUser+''',null,'+intToStr(sysCatalogDefinitionCatalogId)+','+intTostr(sysCatalogDefinitionSchemaId)+','+intToStr(ord(atAdmin))+',''N''),'+ {todo hash password!}  //Note: 1 is assumed to be =SYSTEM_AUTHID in other places
            '(2,''PUBLIC'','''+atRole+''',null,'+intToStr(sysCatalogDefinitionCatalogId)+',2,'+intToStr(ord(atNone))+',''N''),'+             //2=> INFORMATION_SCHEMA //Note: 2 is assumed to be =PUBLIC_AUTHID so use constant?
            '(3,''INFORMATION_SCHEMA'','''+atUser+''',null,'+intToStr(sysCatalogDefinitionCatalogId)+',2,'+intToStr(ord(atNone))+',''N''),'+ //2=> INFORMATION_SCHEMA
            '(4,''DEFAULT'','''+atUser+''',null,'+intToStr(sysCatalogDefinitionCatalogId)+',3,'+intToStr(ord(atNone))+',''N''),'+             //3=> DEFAULT_SCHEMA
            '(5,''ADMIN'','''+atUser+''',''admin'','+intToStr(sysCatalogDefinitionCatalogId)+',3,'+intToStr(ord(atAdmin))+',''Y'')'+          //3=> DEFAULT_SCHEMA
            '; ');
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed inserting sysAuth row via PrepareSQL/ExecutePlan: ',vAssertion)
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted %d entries into sysAuth',[rc]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          //maybe other system tables should be added as follows:
          //  parse & process 'create newsystable(id integer, name character(10)) etc.'
          //  open a new sys Trelation with the new table name


          {Note: the INSERT INTO's here don't need a prefix of sysCatalogDefinitionSchema (or permission!)
                 because that is our current tr.authId = default

                 would be safer, better if we do explicitly state the schema_name prefix
                       then the insertion SQL code is more portable
                       - but sysSchema is not open to enable such lookups here
          }

          {Add table/column privilege table - keep in sync with column enumeration in uGlobal!
           Also, createTable assumes this will become table_id=4 ****** - todo ensure/use constant}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege (table_id integer,'+
                                  'column_id integer,'+
                                  'grantor integer,'+
                                  'grantee integer,'+
                                  'privilege integer,'+
                                  'grant_option char(1) '+
                                  '); '
                       );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnPrivilege via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnPrivilege',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}

          {Add routine privilege table - keep in sync with column enumeration in uGlobal!}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege (routine_id integer,'+
                                  'grantor integer,'+
                                  'grantee integer,'+
                                  'privilege integer,'+
                                  'grant_option char(1) '+
                                  '); '
                       );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutinePrivilege via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysRoutinePrivilege',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}

          {sysCatalog keep in sync. with TVirtualFile}
          {Add the catalog table)}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysCatalog_table+' (catalog_id integer,'+
                                     'catalog_name varchar('+IntToStr(MaxCatalogName)+')'+
                                     '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysCatalog via PrepareSQL/ExecutePlan: ',vAssertion)
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysCatalog',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}

          {Add schema table}
          {Note:
             all system catalog tables should have a column to reference to a schema_id
             if all the following are true:
               they are contained by the schema (e.g. sysCatalog and sysAuth are not)
               they have a _name column
               they do not depend on another table that has a schema_id ref (e.g. sysColumn depends on sysTable)

             In other words, a schema_id reference is needed to disambiguate an object's name during lookup
             but afterwards does not need to form part of the object's key since objects satisfying
             the above rules have schema-unique id's (e.g. sysColumn)
          }
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysSchema (catalog_id integer,'+
                                    'auth_id integer,'+
                                    'schema_id integer,'+
                                    'schema_name varchar('+IntToStr(MaxSchemaName)+'),'+
                                    'schema_version_major integer,'+
                                    'schema_version_minor integer'+
                                    '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysSchema via PrepareSQL/ExecutePlan: ',vAssertion)
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysSchema',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
          {Add the system catalog schema row
           Note: we can't call CREATE SCHEMA because we've already taken 1 as the next schema_id
           to use for sysTable and sysColumn
           Also note that we assume sysCatalogDefinitionSchemaId (=1) does not already exist (reasonable since we just created the table!)
           - if it did, the insert would fail, but we would (currently) carry on

           Also note that the major/minor version entries for this schema define the catalog version
           (these are the ones that really matter since the sys table structures are defined here)
           which we will use in future to upgrade/tolerate older catalog schemas

           (other schema versions could be used by the schema owners for their own purposes:
            we don't care what version they are, although we create them with our current sys-catalog-schema version)
           }
          result:=PrepareSQL(tr.sysStmt,nil,format(
            'INSERT INTO sysSchema VALUES (1,1,%d,''%s'',%d,%d); ',
            [sysCatalogDefinitionSchemaId,sysCatalogDefinitionSchemaName,
             dbCatalogDefinitionSchemaVersionMajor,dbCatalogDefinitionSchemaVersionMinor]) );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed inserting sysSchema row via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted %d entries into sysSchema',[rc]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Add the transaction control table}
          //todo: make sure these 2 tables pre-allocate plenty of consecutive disk pages
          //      they'll grow (& shrink), but hopefully not beyond a certain size: speed
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysTran (tran_id integer,'+
                                  'state char(1)'+
                                  '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTran via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysTran',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Add the sub-transaction control table}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysTranStmt (tran_id integer,'+
                                      'stmt_id integer'+
                                      //note: state is always assumed to be rolled back
                                      '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc );
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTranStmt via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysTranStmt',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Add domain table - keep in sync with column enumeration in uGlobal!}
          //maybe this should be just after sysTable,sysColumn so future tables can use the info-schema domains?
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysDomain (domain_id integer,'+
                                    'domain_name varchar('+IntToStr(MaxDomainName)+'),'+
                                    'schema_id integer,'+
                                    'datatype integer,'+
                                    'width integer,'+
                                    'scale integer,'+
                                    '"default" varchar('+IntToStr(MaxRecSize)+')'+
                                    '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysDomain via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysDomain',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}
          {Add the system domain rows}
          //CATALOG_IDENTIFIER? etc...

          {Add generator table - keep in sync with column enumeration in uGlobal!}
          {synchronise with
             sysGenerator_columns=(sg_Generator_Id,sg_Generator_name,sg_Schema_id,sg_Generator_next etc);
           in uGlobal! - so far only needed in uGlobal for get_next routine to find gen name...
          }
          //we should prevent the user from modifying this table directly (and normal users from viewing it?)
          // - also applies to sysTran, etc.?
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysGenerator (generator_id integer,'+
                                       'generator_name varchar('+IntToStr(MaxGeneratorName)+'),'+
                                       'schema_id integer,'+
                                       'start_at integer,'+
                                       '"next" integer,'+
                                       'increment integer,'+    //future use
                                       'cache_size integer,'+
                                       'cycle char(1)'+         //future use
                                       '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysGenerator via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysGenerator',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Add the server-option table: Note: keep in sync with insertion below & later 'grant update to public...'}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysOption (option_id integer,'+
                                     'option_name varchar('+IntToStr(MaxOptionName)+'),'+
                                     'option_value integer,'+
                                     'option_text varchar('+IntToStr(MaxOptionText)+'), '+
                                     'option_last_modified timestamp(0) default current_timestamp '+
                                     '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysOption via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysOption',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}
          {Add the option rows}
          result:=PrepareSQL(tr.sysStmt,nil,
            'INSERT INTO sysOption VALUES (1,'''+OptionString[otOptimiser]+''',1,null,default) '+
            '; ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed inserting sysOption rows via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted %d entry into sysOption',[rc]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Constraint tables - keep in sync with column enumerations in uGlobal!}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysConstraint (constraint_id integer,'+
                                        'constraint_name varchar('+IntToStr(MaxConstraintName)+'),'+
                                        'schema_id integer,'+
                                        '"deferrable" char(1),'+
                                        'initially_deferred char(1),'+
                                        'rule_type integer,'+
                                        'rule_check varchar('+IntToStr(MaxRecSize)+'),'+ 
                                        'FK_parent_table_id integer,'+
                                        'FK_child_table_id integer,'+
                                        'FK_match_type integer,'+
                                        'FK_on_update_action integer,'+
                                        'FK_on_delete_action integer'+  
                                        '); ');
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraint via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysConstraint',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysConstraintColumn (constraint_id integer,'+
                                              'parent_or_child_table char(1),'+
                                              'column_id integer,'+
                                              'column_sequence integer'+
                                              '); ');
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraintColumn via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysConstraintColumn',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}


          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysDomainConstraint (domain_id integer,'+
                                              'constraint_id integer'+
                                              '); ');
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysDomainConstraint via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysDomainConstraint',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then 
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {- keep in sync with column enumeration in uGlobal!}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysTableColumnConstraint (table_id integer,'+
                                                   'column_id integer,'+
                                                   'constraint_id integer'+
                                                   '); ');
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnConstraint via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnConstraint',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {sysTransaction  keep in sync. with TVirtualFile}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysTransaction_table+' (transaction_id integer,'+
                                         '"authorization" varchar(128),'+ 
                                         'isolation_level varchar(20)'+
                                         '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysTransaction_table+' via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysTransaction_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}

          {Note: these server related virtual tables are not catalog specific,
                 so they don't really belong here...
                 but adding them here makes them accessible: we need to put them somewhere!
                 - maybe we need a server/cluster meta catalog?
                 - if so, we should put the users there... but then catalog files are less portable
          }
          {sysServer  keep in sync. with TVirtualFile}
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysServer_table+' (server_id integer,'+
                                         'server_name varchar('+IntToStr(MaxServerText)+')'+  
                                         '); ',
                                         nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysServer_table+' via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysServer_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {sysStatusGroup  keep in sync. with TVirtualFile}
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysStatusGroup_table+' (statusgroup_id integer,'+
                                         'statusgroup_name varchar('+IntToStr(MaxStatusGroupText)+')'+  
                                         '); ',
                                         nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysStatusGroup_table+' via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysStatusGroup_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {sysStatus  keep in sync. with TVirtualFile}
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysStatus_table+' (status_id integer,'+
                                         'statusgroup_id integer,'+  //todo add FK constraint
                                         'status_name varchar('+IntToStr(MaxStatusText)+')'+  
                                         '); ',
                                         nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysStatus_table+' via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysStatus_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {sysServerStatus  keep in sync. with TVirtualFile}
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysServerStatus_table+' (server_id integer,'+ //todo FK
                                         'status_id integer,'+  //todo add FK constraint
                                         'status_value bigint,'+
                                         'status_text varchar('+IntToStr(MaxServerStatusText)+')'+  
                                         '); ',
                                         nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysServerStatus_table+' via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysServerStatus_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {sysServerCatalog  keep in sync. with TVirtualFile}
          result:=PrepareSQL(tr.sysStmt,nil,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.'+sysServerCatalog_table+' (server_id integer,'+ //todo FK
                                         //note: can't have FK to catalog_id because no cross catalog joins & all are =1
                                         'catalog_name varchar('+IntToStr(MaxCatalogName)+'),'+
                                         'opened_on timestamp,'+
                                         'primary_catalog char(1)'+
                                         '); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating '+sysServerCatalog_table+' via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created '+sysServerCatalog_table,vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}


          {Add routine table -  keep in sync with column enumeration in uGlobal!}
          //note 1st attempt to use revamped ExecSQL rather than 3 stages with lots of lines! ... since used above...
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysRoutine (routine_id integer,'+
                                  'routine_name varchar('+IntToStr(MaxRoutineName)+'),'+
                                  'schema_id integer,'+
                                  'module_id integer,'+ //for future use
                                  'routine_type char(1),'+
                                  'routine_definition character large object(2M),'+
                                  //schema version 01.00 = 'routine_definition varchar('+IntToStr(MaxRecSize)+'),'+
                                  'next_parameter_id integer'+
                                  '); ',
                       nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutine via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysRoutine',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {Add routine parameter table -  keep in sync with column enumeration in uGlobal!}
          result:=ExecSQL(tr.sysStmt,
            'CREATE TABLE '+sysCatalogDefinitionSchemaName+'.sysParameter (routine_id integer,'+
                                  'parameter_id integer,'+
                                  'parameter_name varchar('+IntToStr(MaxParameterName)+'),'+
                                  'parameter_type integer,'+ //=variableType internally
                                  'datatype integer,'+
                                  'width integer,'+
                                  'scale integer,'+
                                  '"default" varchar('+IntToStr(MaxRecSize)+')'+
                                  '); ',
                       nil,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed creating sysParameter via ExecSQL: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Created sysParameter',vdebugMedium);
            {$ELSE}
            ;
            {$ENDIF}

          {etc. all other system tables...-------------------------------------}



          {Finally, add the system generator rows ==========================================================
           Note: this assumes we create no more objects after this in this routine.
           During creation, we don't have access to these generators, so we must now
           synchronise initial Nexts with what we created}
          // couldn't we open the sysGenerator catalog relation once we've built it...?
          {Note: start all generators at 1, since 0 is often used internally to mean All or None or N/A
                 also, no caching is used for these system generators (not heavily thrashed)
          }
          result:=PrepareSQL(tr.sysStmt,nil,
            'INSERT INTO sysGenerator VALUES '+                                 //start, next, inc, cache, 'cycle'
            '(1,''sysGenerator_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1, 9, 1,0,''N''),'+   //Note: ensure Next is last id inserted here+1
            '(2,''sysTable_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1,'+intToStr(fsysTable_LastTableId+1)+',1,0,''N''),'+       //Note: based on bootstrap generator
            '(3,''sysAuth_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1, 6, 1,0,''N''),'+        //Note: ensure Next is last auth_id created above+1 (DEFAULT)
            '(4,''sysSchema_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1,'+intToStr(fsysSchema_LastSchemaId+1)+',1,0,''N''),'+      //Note: based on bootstrap generator
            '(5,''sysDomain_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1,'+intToStr(fsysDomain_LastDomainId+1)+',1,0,''N''),'+       //Note: based on bootstrap generator
            //add sysOption_generator in case we dynamically add more(?)....
            '(6,''sysConstraint_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1, 1, 1,0,''N''),'+  //Note: ensure Next is last constraint_id created above+1
            '(7,''sysIndex_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1, 1, 1,0,''N''),'+        //Note: ensure Next is last index_id created above+1
            '(8,''sysRoutine_generator'','+intToStr(sysCatalogDefinitionSchemaId)+',1, 1, 1,0,''N'')'+       //Note: ensure Next is last routine_id created above+1

            {Note: additional generators must be added to sysGenerator_generator.Next in 1st row!}

            '; ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed inserting sysGenerator row via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted %d entries into sysGenerator',[rc]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}


          {Insert rows into sysTran}
          with (owner as TDBserver) do
          begin
            buffer.status;
          end;
          result:=PrepareSQL(tr.sysStmt,nil,
            'INSERT INTO sysTran VALUES (1,''N''); ' );
          if result=ok then result:=ExecutePlan(tr.sysStmt,rc );
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'  Failed inserting sysTran row via PrepareSQL/ExecutePlan: ',vAssertion) 
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Inserted %d entries into sysTran',[rc]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}
          with (owner as TDBserver) do
          begin
            buffer.status;
          end;
  //*)
        end;
        //else just creating emptyDB
      finally
        (catalogRelation[sysTable] as TRelation).Close;
        (catalogRelation[sysColumn] as TRelation).Close;
//?      end; {try}
//?    finally
        {First ensure we have released the buffer pages and frames}
        with (owner as TDBserver) do
        begin
          buffer.flushAllPages(tr.sysStmt);
        //todo check result of flushAll- if fail, force all to be flushed, even if pinned (better than bug->corruption?)
        // but, would this ensure that we have a consistent db?
          buffer.resetAllFrames(self);
        end;

        if CloseFile<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Failed closing new physical database file',vdebugError);
          {$ELSE}
          ;
          {$ENDIF}
          result:=Fail;
        end;
      end; {try}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,'Failed creating database',vError);
      {$ELSE}
      ;
      {$ENDIF}
      result:=Fail;
    end;
  finally
    tr.tranRt:=InvalidStampId; //Note: assumes 'not in a transaction'=>InvalidTranId
    tr.SynchroniseStmts(true);
    tr.Free;
  end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(who,'','',vdebug);
  {$ENDIF}
end; {createDB}

function TDB.createSysIndexes(st:Tstmt):integer;
{Create indexes on base system catalog tables
 (also used by backup catalog maintenance routine)
}
const routine=':createSysIndexes';
begin
  result:=fail;

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTable_index1',ioSystem,0,(catalogRelation[sysTable] as TRelation),nil,ord(st_Table_name));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysTable_index1 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysTable_index1',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTable_index2',ioSystem,0,(catalogRelation[sysTable] as TRelation),nil,ord(st_Table_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysTable_index2 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysTable_index2',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTable_index3',ioSystem,0,(catalogRelation[sysTable] as TRelation),nil,ord(st_Schema_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysTable_index3 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysTable_index3',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}


  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysColumn_index1',ioSystem,0,(catalogRelation[sysColumn] as TRelation),nil,ord(sc_Table_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysColumn_index1 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysColumn_index1',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysColumn_index2',ioSystem,0,(catalogRelation[sysColumn] as TRelation),nil,ord(sc_datatype));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysColumn_index2 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysColumn_index2',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysColumn_index3',ioSystem,0,(catalogRelation[sysColumn] as TRelation),nil,ord(sc_column_name));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysColumn_index3 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysColumn_index3',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysColumn_index4',ioSystem,0,(catalogRelation[sysColumn] as TRelation),nil,ord(sc_Column_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysColumn_index4 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysColumn_index4',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysIndex_index1',ioSystem,0,(catalogRelation[sysIndex] as TRelation),nil,ord(si_table_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysIndex_index1 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysIndex_index1',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}

  //todo add sysIndex on constraint_id to speed up constraint/table/index deletion

  result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysIndexColumn_index1',ioSystem,0,(catalogRelation[sysIndexColumn] as TRelation),nil,ord(sic_index_id));
  if result<ok then //result=index_id
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Failed creating sysIndexColumn_index1 via CreateIndex: ',vAssertion) 
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'  Created sysIndexColumn_index1',vdebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
end; {createSysIndexes}

function TDB.createInformationSchema:integer;
{Adds the information schema to a new database file (=catalog)
 Called by CREATE CATALOG

 Needs to be done in a separate routine so the newly created tables can be opened
 to allow schema/domain/auth-id lookups etc.

 Note: also adds DEFAULT schema and some system indexes - see code below for details!

 Assumes:
   caller has just created and then opened the new db
}
const routine=':createInformationSchema';
var
  Tr:TTransaction;
  St:TStmt;

  rc:integer; //executePlan rowCount results
begin
  result:=ok;

  tr:=TTransaction.create; //use internal transaction to create info schema, nil=>Start does nothing
  try
    tr.connectToDB(self); //we need to connect tr.db to ourself here to allow page i/o etc
    {ensure we can read everything during startup: needed because dbCreate now uses 0:1..0:5 etc.}
    tr.Start; //defaults to next tran = 2

    //Note we initialise these settings before they actually exist...i.e. technically foreign key violations
    tr.connect(SYSTEM_AUTHNAME,'');

    //We need to start a stmt
    if tr.addStmt(stSystemDDL,st)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,'Failed creating temporary stmt',vAssertion);
      {$ENDIF}
      //continue but will use sysStmt which will currently fail when we constraint check below...
    end;
    try
      {Add the system information schema}
      //-todo: base sys catalog tables should use the 3 domains from here
      // so that the info_schema views will have the right column types
      // so I think we'll need to assume/reserve domain_id's 1,2 and 3
      // and use them before they exist...as we've done with schema_id's etc.
      //- or else we add them at the start and artificially set their schema id to 2?
      //  then we can use 'create table sysSchema(schema_id CARDINAL_NUMBER...etc)'

      //todo: need to add PUBLIC Select (etc.?) privilege to info schema system views
      // but to do this neatly (via the CREATE VIEW routine) we would need to have the
      // sysSchema etc. open
      //   anyway, ok for now: we leave INFO_SCHEMA tables alone
      //           but probably need to openDb before creating INFO_SCHEMA below...
      //           otherwise createTable can't lookup schema/sysAuth etc.


        {Grant select permission on system tables to INFORMATION_SCHEMA
         - we need to grant via PUBLIC because any user can reference INFORMATION_SCHEMA views and so
           needs access to the underlying tables}
        //todo put in loop
        //sysAuth hides access to password column: todo: only need auth_id and auth_name + USERS view? = reduce sys catalog space
        result:=PrepareSQL(st,nil,'GRANT SELECT(auth_id,auth_name,auth_type,default_catalog_id,default_schema_id,admin_role,admin_option) ON '+sysCatalogDefinitionSchemaName+'.sysAuth TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysTable TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then 
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysColumn TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then 
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysSchema TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then 
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysCatalog_table+' TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysDomain TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT, UPDATE(option_value,option_text) ON '+sysCatalogDefinitionSchemaName+'.sysOption TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysConstraint TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysConstraintColumn TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysDomainConstraint TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysTableColumnConstraint TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysIndex TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysIndexColumn TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then 
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysTransaction_table+' TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=ExecSQL(tr.sysStmt,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysServer_table+' TO PUBLIC;',nil,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}

        result:=ExecSQL(tr.sysStmt,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysStatusGroup_table+' TO PUBLIC;',nil,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}

        result:=ExecSQL(tr.sysStmt,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysStatus_table+' TO PUBLIC;',nil,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}

        result:=ExecSQL(tr.sysStmt,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysServerStatus_table+' TO PUBLIC;',nil,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}

        result:=ExecSQL(tr.sysStmt,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.'+sysServerCatalog_table+' TO PUBLIC;',nil,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysRoutine TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysParameter TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

        result:=PrepareSQL(st,nil,'GRANT SELECT ON '+sysCatalogDefinitionSchemaName+'.sysGenerator TO PUBLIC;');
        if result=ok then result:=ExecutePlan(st,rc);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'  Failed granting system table permissions to PUBLIC row via PrepareSQL/ExecutePlan: ',vAssertion) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'Granted permission on system table to PUBLIC',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        if UnPreparePlan(st)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}

      //todo: maybe owner should be PUBLIC not _SYSTEM? - no: need special user
      result:=PrepareSQL(st,nil,
        'CREATE SCHEMA '+sysInformationSchemaName+' AUTHORIZATION INFORMATION_SCHEMA '+
        '  CREATE DOMAIN CARDINAL_NUMBER AS INTEGER '+
        '    CONSTRAINT CARDINAL_NUMBER_DOMAIN_CHECK '+
        '    CHECK (VALUE>=0) '+
        '  CREATE DOMAIN CHARACTER_DATA AS CHARACTER VARYING('+intToStr(MaxVarChar)+') '+  //todo add character set
        '  CREATE DOMAIN SQL_IDENTIFIER AS CHARACTER VARYING('+intToStr(MaxRegularId)+') '+  //todo add character set
        //todo etc. and add constraints
        '  CREATE TABLE TYPE_INFO ('+
        '    datatype INTEGER,'+    //cross-ref for system tables
        '    TYPE_NAME VARCHAR(128),'+
        '    DATA_TYPE SMALLINT,'+
        '    COLUMN_SIZE INTEGER,'+
        '    LITERAL_PREFIX VARCHAR(128),'+
        '    LITERAL_SUFFIX VARCHAR(128),'+
        '    CREATE_PARAMS VARCHAR(128),'+
        '    NULLABLE SMALLINT,'+
        '    CASE_SENSITIVE SMALLINT,'+
        '    SEARCHABLE SMALLINT,'+
        '    UNSIGNED_ATTRIBUTE SMALLINT,'+
        '    FIXED_PREC_SCALE SMALLINT,'+
        '    AUTO_UNIQUE_VALUE SMALLINT,'+
        '    LOCAL_TYPE_NAME VARCHAR(128),'+
        '    MINIMUM_SCALE INTEGER,'+
        '    MAXIMUM_SCALE INTEGER,'+
        '    SQL_DATA_TYPE SMALLINT,'+
        '    SQL_DATETIME_SUB SMALLINT,'+
        '    NUM_PREC_RADIX INTEGER,'+
        '    INTERVAL_PRECISION SMALLINT,'+
        '    PRIMARY KEY (datatype)'+      //todo give this constraint a name! e.g. typeInfo_index1
        '  ) '+

        '  CREATE VIEW INFORMATION_SCHEMA_CATALOG_NAME ('+
        '    CATALOG_NAME '+ 
        '    ) AS SELECT '+
        '    catalog_name '+
        '    FROM '+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog '+

        '  CREATE VIEW SQL_LANGUAGES ('+
        '    SQL_LANGUAGE_SOURCE,'+
        '    SQL_LANGUAGE_YEAR,'+
        '    SQL_LANGUAGE_CONFORMANCE,'+
        '    SQL_LANGUAGE_INTEGRITY,'+
        '    SQL_LANGUAGE_IMPLEMENTATION,'+
        '    SQL_LANGUAGE_BINDING_STYLE,'+
        '    SQL_LANGUAGE_PROGRAMMING_LANGUAGE'+
        '    ) AS '+
        '    VALUES '+
        '    (''ISO 9075'',''1999'',''CORE'',NULL,NULL,''DIRECT'',NULL), '+
        '    (''ISO 9075'',''1999'',''CORE'',NULL,NULL,''SQL/CLI'',NULL), '+
        '    (''ISO 9075'',''1999'',''CORE'',NULL,NULL,''JDBC'',''JAVA''), '+
        '    (''ISO 9075'',''1999'',''CORE'',NULL,NULL,''DBEXPRESS'',''PASCAL''), '+
        '    (''ISO 9075'',''1999'',''CORE'',NULL,NULL,''DB-API'',''PYTHON'') '+

        (*todo implement & populate
        '  CREATE TABLE SQL_IMPLEMENTATION_INFO ('+ //todo: rename & wrap in a view...
        '    IMPLEMENTATION_INFO_ID CHARACTER_DATA,'+
        '    IMPLEMENTATION_INFO_NAME CHARACTER_DATA,'+
        '    INTEGER_VALUE CARDINAL_NUMBER,'+
        '    CHARACTER_VALUE CHARACTER_DATA,'+
        '    IMPLEMENTATION_INFO_COMMENTS CHARACTER_DATA,'+
        '    PRIMARY KEY (IMPLEMENTATION_INFO_ID)'+       //todo: too much overhead for a small table?
        '  ) '+
        *)


        '  CREATE VIEW TABLES ( '+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    TABLE_TYPE,'+
        '    SELF_REFERENCING_COLUMN_NAME,'+    //todo remove? SQL3 only?
        '    REFERENCE_GENERATION'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    CASE table_type'+
        '      WHEN ''B'' THEN ''BASE TABLE'' '+
        '      WHEN ''V'' THEN ''VIEW'' '+
               //todo 'local temporary' and 'global temporary'
        '    ELSE'+
        '      table_type'+  //todo better to return UNKNOWN ?
        '    END,'+
        '    NULL,'+
        '    NULL'+
        '    FROM'+
//note: hand-optimised
(*
        '    '+sysCatalogDefinitionSchemaName+'.sysTable  natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog'+
*)
//(* todo reinstate - bug with adding conditions...
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable'+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         OR table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) ) '+

//*)
        //todo: and where current_user is table owner => auth-id owns the schema(?)

        '  CREATE VIEW COLUMNS ( '+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    COLUMN_NAME,'+
        '    ORDINAL_POSITION,'+
        '    COLUMN_DEFAULT,'+
        '    IS_NULLABLE,'+
        '    DATA_TYPE,'+
        '    CHARACTER_MAXIMUM_LENGTH,'+
        '    CHARACTER_OCTET_LENGTH,'+
        '    NUMERIC_PRECISION,'+
        '    NUMERIC_PRECISION_RADIX,'+
        '    NUMERIC_SCALE,'+
        '    DATETIME_PRECISION,'+
        '    INTERVAL_TYPE,'+
        '    INTERVAL_PRECISION,'+
        '    CHARACTER_SET_CATALOG,'+
        '    CHARACTER_SET_SCHEMA,'+
        '    CHARACTER_SET_NAME,'+
        '    COLLATION_CATALOG,'+
        '    COLLATION_SCHEMA,'+
        '    COLLATION_NAME,'+
        '    DOMAIN_CATALOG,'+  //todo lookup
        '    DOMAIN_SCHEMA,'+
        '    DOMAIN_NAME,'+
        '    USER_DEFINED_TYPE_CATALOG,'+       //todo remove: SQL3 only?
        '    USER_DEFINED_TYPE_SCHEMA,'+
        '    USER_DEFINED_TYPE_NAME,'+
        '    SCOPE_CATALOG,'+       //todo remove: SQL3 only?
        '    SCOPE_SCHEMA,'+
        '    SCOPE_NAME,'+
        '    IS_SELF_REFERENCING,'+
        '    CHECK_REFERENCES,'+
        '    CHECK_ACTION'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    column_name,'+
        '    column_id,'+ //todo check correct for info-schema views! reflexive...or rather should reset ids at higher levels as per aliases...but need for data retrieval, so need another way to get col-position...
        '    "default",'+    //todo rename "default" on sysColumn = easier to handle
        '    CASE '+ //note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                     //Note: outer reference to sysTable...}
        '      WHEN EXISTS (SELECT 1 FROM '+sysCatalogDefinitionSchemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
        '    ELSE '+
        '      ''Y'' '+
        '    END,'+
        '    TYPE_NAME,'+
        '    width,'+        //todo need case for some of these: dependent on data_type!!!
        '    width,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    width,'+
        '    NUM_PREC_RADIX,'+
        '    scale,'+
        '    width,'+
        '    null,'+          //todo interval type
        '    scale,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null'+
        '    FROM'+
//not optimised to use indexes yet, so takes over 1 minute when new!: speed
//(* //todo re-instate: debug fixing problem with selection...
        '    '+sysInformationSchemaName+'.TYPE_INFO natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysColumn natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog '+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         OR table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID) '+
        '                          AND column_id IS NULL) '+
        '         OR (table_id,column_id) IN (SELECT table_id,column_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) '+
        '        ) '+

        '  CREATE VIEW DOMAINS ( '+
        '    DOMAIN_CATALOG,'+
        '    DOMAIN_SCHEMA,'+
        '    DOMAIN_NAME,'+
        '    DATA_TYPE,'+
        '    CHARACTER_MAXIMUM_LENGTH,'+
        '    CHARACTER_OCTET_LENGTH,'+
        '    COLLATION_CATALOG,'+
        '    COLLATION_SCHEMA,'+
        '    COLLATION_NAME,'+
        '    CHARACTER_SET_CATALOG,'+
        '    CHARACTER_SET_SCHEMA,'+
        '    CHARACTER_SET_NAME,'+
        '    NUMERIC_PRECISION,'+
        '    NUMERIC_PRECISION_RADIX,'+
        '    NUMERIC_SCALE,'+
        '    DATETIME_PRECISION,'+
        '    INTERVAL_TYPE,'+
        '    INTERVAL_PRECISION,'+
        '    DOMAIN_DEFAULT,'+
        '    USER_DEFINED_TYPE_CATALOG,'+       //todo remove: SQL3 only?
        '    USER_DEFINED_TYPE_SCHEMA,'+
        '    USER_DEFINED_TYPE_NAME,'+
        '    SCOPE_CATALOG,'+       //todo remove: SQL3 only?
        '    SCOPE_SCHEMA,'+
        '    SCOPE_NAME'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    domain_name,'+
        '    TYPE_NAME,'+
        '    width,'+        //todo need case for some of these: dependent on data_type!!!
        '    width,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    width,'+
        '    NUM_PREC_RADIX,'+
        '    scale,'+
        '    width,'+
        '    null,'+          //todo interval type
        '    scale,'+
        '    "default",'+    //todo rename "default" on sysColumn = easier to handle
        '    null,'+          //todo
        '    null,'+
        '    null,'+
        '    null,'+          //todo
        '    null,'+
        '    null'+
        '    FROM'+
//not optimised to use indexes yet, so takes over 1 minute when new!: speed
//(* //todo re-instate: debug fixing problem with selection...
        '    '+sysInformationSchemaName+'.TYPE_INFO natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysDomain natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog '+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        //todo: restrict to those in the catalog to which we have usage privilege
        //'    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        //todo'         OR table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID) '+
        //'                          AND column_id IS NULL) '+
        //'         OR (table_id,column_id) IN (SELECT table_id,column_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) '+
        //'        ) '+

        '  CREATE VIEW DOMAIN_CONSTRAINTS ( '+
        '    CONSTRAINT_CATALOG,'+
        '    CONSTRAINT_SCHEMA,'+
        '    CONSTRAINT_NAME,'+
        '    DOMAIN_CATALOG,'+
        '    DOMAIN_SCHEMA,'+
        '    DOMAIN_NAME,'+
        '    IS_DEFERRABLE,'+
        '    INITIALLY_DEFERRED'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    constraint_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    domain_name,'+
        '    CASE "deferrable"'+
        '      WHEN ''N'' THEN ''NO'' '+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    END,'+
        '    CASE initially_deferred'+
        '      WHEN ''N'' THEN ''NO'' '+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    END'+
        '    FROM'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysDomainConstraint natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysDomain'+
        '    WHERE '+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        //todo: restrict to those in the catalog to which we have usage privilege
        //'    AND auth_id=CURRENT_AUTHID '+

//*)
        //todo: and where current_user is column/table owner => auth-id owns the schema(?)

        '  CREATE VIEW KEY_COLUMN_USAGE ('+
        '    CONSTRAINT_CATALOG,'+
        '    CONSTRAINT_SCHEMA,'+
        '    CONSTRAINT_NAME,'+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    COLUMN_NAME,'+
        '    ORDINAL_POSITION'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    constraint_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    column_name,'+
        '    column_sequence'+
        '    FROM'+
//todo replace join syntax with where as above - speed until optimiser handles joins
//todo reverse table ordering to optimise!
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join '+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraintColumn natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable on FK_child_table_id=table_id join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysColumn using (table_id,column_id)'+
        '    WHERE parent_or_child_table=''C'' '+
        '    AND '+'schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND auth_id=CURRENT_AUTHID '+

        '  CREATE VIEW TABLE_CONSTRAINTS ( '+
        '    CONSTRAINT_CATALOG,'+
        '    CONSTRAINT_SCHEMA,'+
        '    CONSTRAINT_NAME,'+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    CONSTRAINT_TYPE,'+
        '    IS_DEFERRABLE,'+
        '    INITIALLY_DEFERRED'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    constraint_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    CASE rule_type'+
        '      WHEN 0 THEN ''UNIQUE'' '+
        '      WHEN 1 THEN ''PRIMARY KEY'' '+
        '      WHEN 2 THEN ''FOREIGN KEY'' '+
        '      WHEN 3 THEN ''CHECK'' '+
        '    ELSE'+
        '      ''UNKNOWN'' '+
        '    END,'+
        '    CASE "deferrable"'+
        '      WHEN ''N'' THEN ''NO'' '+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    END,'+
        '    CASE initially_deferred'+
        '      WHEN ''N'' THEN ''NO'' '+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    END'+
        '    FROM'+
//todo replace join syntax with where as above - speed until optimiser handles joins
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraintColumn join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable'+
        '    WHERE table_id=FK_child_table_id '+
        '    AND parent_or_child_table=''C'' AND'+
        '    sysTable.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND auth_id=CURRENT_AUTHID '+
        //todo maybe base/join on KEY_COLUMN_USAGE or vice-versa...

        '  CREATE VIEW CHECK_CONSTRAINTS ('+
        '    CONSTRAINT_CATALOG,'+
        '    CONSTRAINT_SCHEMA,'+
        '    CONSTRAINT_NAME,'+
        '    CHECK_CLAUSE'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    constraint_name,'+
        '    rule_check'+
        '    FROM'+
//todo replace join syntax with where as above - speed until optimiser handles joins
//todo reverse table ordering to optimise!
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join '+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        //'    '+sysCatalogDefinitionSchemaName+'.sysConstraintColumn natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint '+ //join'+
        //'    '+sysCatalogDefinitionSchemaName+'.sysTable on FK_child_table_id=table_id join'+
        //'    '+sysCatalogDefinitionSchemaName+'.sysColumn using (table_id,column_id)'+
        '    WHERE '+ //parent_or_child_table=''C'' '+
        '    rule_type=3 '+ //todo: keep in sync with TconstraintRuleType
        '    AND '+'schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND auth_id=CURRENT_AUTHID '+

        '  CREATE VIEW TABLE_PRIVILEGES ( '+
        '    GRANTOR,'+
        '    GRANTEE,'+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    PRIVILEGE_TYPE,'+
        '    IS_GRANTABLE,'+
        '    WITH_HIERACHY'+    //todo remove? SQL3 only
        '    ) AS SELECT'+
        '    sysAuth_GRANTOR.auth_name,'+
        '    sysAuth_GRANTEE.auth_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    CASE privilege'+            //todo keep in sync with TprivilegeType ordering
        '      WHEN 0 THEN ''SELECT'' '+
        '      WHEN 1 THEN ''INSERT'' '+
        '      WHEN 2 THEN ''UPDATE'' '+
        '      WHEN 3 THEN ''DELETE'' '+
        '      WHEN 4 THEN ''REFERENCES'' '+
        '      WHEN 5 THEN ''USAGE'' '+
        '      WHEN 6 THEN ''EXECUTE'' '+
        //todo TRIGGER = USAGE?
        '    ELSE'+
        '      NULL'+  //todo better to return UNKNOWN ?
        '    END,'+
        '    CASE grant_option'+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    ELSE'+
        '      ''NO'' '+
        '    END,'+
        '    NULL'+
        '    FROM'+
{todo revert to natural joins when optimiser can tune them properly - neater...
}
//note: hand-optimised
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTOR,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTEE,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege'+
        '    WHERE'+
        '    sysTableColumnPrivilege.column_id is null AND'+
        '    sysCatalog.catalog_id=sysSchema.catalog_id AND'+
        '    sysSchema.schema_id=sysTable.schema_id AND'+
        '    sysAuth_GRANTOR.auth_id=sysTableColumnPrivilege.grantor AND'+
        '    sysAuth_GRANTEE.auth_id=sysTableColumnPrivilege.grantee AND'+
        '    sysTableColumnPrivilege.table_id=sysTable.table_id AND'+
        '    sysSchema.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND ('+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         sysTable.table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID) '+
        '                          AND column_id IS NULL) '+
        '         OR sysTable.table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantor=CURRENT_AUTHID '+
        '                          AND column_id IS NULL) '+
        '        ) '+
        //done: and where current_user is grantee

        '  CREATE VIEW COLUMN_PRIVILEGES ( '+
        '    GRANTOR,'+
        '    GRANTEE,'+
        '    TABLE_CATALOG,'+
        '    TABLE_SCHEMA,'+
        '    TABLE_NAME,'+
        '    COLUMN_NAME,'+
        '    PRIVILEGE_TYPE,'+
        '    IS_GRANTABLE'+
        '    ) AS SELECT'+
        '    sysAuth_GRANTOR.auth_name,'+
        '    sysAuth_GRANTEE.auth_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    table_name,'+
        '    column_name,'+
        '    CASE privilege'+            //todo keep in sync with TprivilegeType ordering
        '      WHEN 0 THEN ''SELECT'' '+ //todo remove for pure SQL/92 - this is only a SQL/3 capability
        '      WHEN 1 THEN ''INSERT'' '+
        '      WHEN 2 THEN ''UPDATE'' '+
//todo remove: n/a        '      WHEN 3 THEN ''DELETE'' '+
        '      WHEN 4 THEN ''REFERENCES'' '+
        '      WHEN 5 THEN ''USAGE'' '+  //todo remove? n/a?
        '      WHEN 6 THEN ''EXECUTE'' '+
        //todo TRIGGER = USAGE?
        '    ELSE'+
        '      NULL'+  //todo better to return UNKNOWN ?
        '    END,'+
        '    CASE grant_option'+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    ELSE'+
        '      ''NO'' '+
        '    END'+
        '    FROM'+
{todo revert to natural joins when optimiser can tune them properly - neater...
}
//note: hand-optimised
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTOR,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTEE,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTable,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysColumn,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege'+
        '    WHERE'+
        '    sysCatalog.catalog_id=sysSchema.catalog_id AND'+
        '    sysSchema.schema_id=sysTable.schema_id AND'+
        '    sysAuth_GRANTOR.auth_id=sysTableColumnPrivilege.grantor AND'+
        '    sysAuth_GRANTEE.auth_id=sysTableColumnPrivilege.grantee AND'+
        '    sysTable.table_id=sysTableColumnPrivilege.table_id AND'+
        '    sysTableColumnPrivilege.table_id=sysColumn.table_id AND'+
        '    sysTableColumnPrivilege.column_id=sysColumn.column_id AND'+
        '    sysSchema.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND ('+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         sysTable.table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID) '+
        '                          AND column_id IS NULL) '+
        '         OR (sysColumn.table_id,sysColumn.column_id) IN (SELECT table_id,column_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) '+
        '         OR sysTable.table_id IN (SELECT table_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantor=CURRENT_AUTHID '+
        '                          AND column_id IS NULL) '+
        '         OR (sysColumn.table_id,sysColumn.column_id) IN (SELECT table_id,column_id FROM '+sysCatalogDefinitionSchemaName+'.sysTableColumnPrivilege WHERE grantor=CURRENT_AUTHID) '+
        '        ) '+
        //todo: we should include columns for tables that are privileged with column_id=null?
        //      i.e. left-outer join column_id above... see Complete, Really p283

        //note: this may need to be more strict:
        //      i.e. check that all contributing/joining columns in sysConstraintColumn are involved
        //      in case we could have unique constraints made up of primary key + other columns for example.
        //      - the current view would show both as matching parents, when probably is only 1
        //      - maybe distinct could hide this glitch?
        '  CREATE VIEW REFERENTIAL_CONSTRAINTS ( '+
        '    CONSTRAINT_CATALOG,'+
        '    CONSTRAINT_SCHEMA,'+
        '    CONSTRAINT_NAME,'+
        '    UNIQUE_CONSTRAINT_CATALOG,'+
        '    UNIQUE_CONSTRAINT_SCHEMA,'+
        '    UNIQUE_CONSTRAINT_NAME,'+
        '    MATCH_OPTION,'+
        '    UPDATE_RULE,'+
        '    DELETE_RULE'+
        '    ) AS SELECT'+
        //todo: may need distinct
        '    CCAT.catalog_name,'+
        '    CSCH.schema_name,'+
        '    C.constraint_name,'+
        '    PCAT.catalog_name,'+
        '    PSCH.schema_name,'+
        '    P.constraint_name,'+
        '    CASE C.FK_match_type'+
        //todo: keep in sync with TconstraintFKmatchType
        '      WHEN 0 THEN ''SIMPLE'' '+
        '      WHEN 1 THEN ''PARTIAL'' '+
        '      WHEN 2 THEN ''FULL'' '+
        '    ELSE'+
        '      ''NONE'' '+
        '    END,'+
        '    CASE C.FK_on_update_action'+
        //todo: keep in sync with TconstraintFKactionType
        '      WHEN 0 THEN ''NO ACTION'' '+
        '      WHEN 1 THEN ''CASCADE'' '+
        '      WHEN 2 THEN ''RESTRICT'' '+
        '      WHEN 3 THEN ''SET NULL'' '+
        '      WHEN 4 THEN ''SET DEFAULT'' '+
        '    END,'+
        '    CASE C.FK_on_delete_action'+
        //todo: keep in sync with TconstraintFKactionType
        '      WHEN 0 THEN ''NO ACTION'' '+
        '      WHEN 1 THEN ''CASCADE'' '+
        '      WHEN 2 THEN ''RESTRICT'' '+
        '      WHEN 3 THEN ''SET NULL'' '+
        '      WHEN 4 THEN ''SET DEFAULT'' '+
        '    END'+
        '    FROM'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog AS CCAT,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema AS CSCH,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog AS PCAT,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema AS PSCH,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint AS C,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysConstraint AS P'+
        '    WHERE'+
        '    CCAT.catalog_id=CSCH.catalog_id AND'+
        '    CSCH.schema_id=C.schema_id AND'+
        '    PCAT.catalog_id=PSCH.catalog_id AND'+
        '    PSCH.schema_id=P.schema_id AND'+
        '    C.rule_type=2 AND'+        //todo: keep in sync with TconstraintRuleType
        '    (P.rule_type=0 OR P.rule_type=1) AND'+
        '    C.FK_parent_table_id=P.FK_child_table_id AND'+
        '    PSCH.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' AND'+
        '    CSCH.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND CSCH.auth_id=CURRENT_AUTHID '+
        //done: and where current_user is constraint owner => auth-id owns the schema(?)

        '  CREATE VIEW ACTIVE_TRANSACTIONS ( '+
        '    "TRANSACTION",'+
        '    "AUTHORIZATION",'+
        '    ISOLATION_LEVEL'+
        '  ) AS SELECT '+
        '    transaction_id,'+
        '    "authorization",'+
        '    isolation_level'+
        '    FROM'+
        '    '+sysCatalogDefinitionSchemaName+'.'+sysTransaction_table+' '+

        '  CREATE VIEW SCHEMATA ( '+
        '    CATALOG_NAME,'+
        '    SCHEMA_NAME,'+
        '    SCHEMA_OWNER,'+
        '    DEFAULT_CHARACTER_SET_CATALOG,'+
        '    DEFAULT_CHARACTER_SET_SCHEMA,'+
        '    DEFAULT_CHARACTER_SET_NAME,'+
        '    SQL_PATH'+ //non SQL92?
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    auth_name,'+
        '    NULL,'+
        '    NULL,'+
        '    NULL,'+
        '    NULL'+
        '    FROM'+
//note: hand-optimised
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth'+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND auth_id=CURRENT_AUTHID '+

        //this was added after authId restrictions above: so we could see all users!
        '  CREATE VIEW USERS ( '+
        '    USER_NAME,'+
        '    DEFAULT_CATALOG_NAME,'+
        '    DEFAULT_SCHEMA_NAME'+
        '    ) AS SELECT'+
        '    auth_name,'+
        '    catalog_name,'+
        '    schema_name'+
        '    FROM'+
//note: hand-optimised
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema'+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND sysCatalog.catalog_id=default_catalog_id '+
        '    AND schema_id=default_schema_id '+
        '    AND auth_type='''+atUser+''' '+

        //Note: length of this tips minimum db page size>512! A few others are even worse! e.g. column_privileges, type_info
        //21/01/03 solution = store as CLOB which can span pages
        '  CREATE VIEW ROUTINES ( '+
        '    SPECIFIC_CATALOG,'+
        '    SPECIFIC_SCHEMA,'+
        '    SPECIFIC_NAME,'+
        '    ROUTINE_CATALOG,'+
        '    ROUTINE_SCHEMA,'+
        '    ROUTINE_NAME,'+
        '    ROUTINE_TYPE,'+
        '    MODULE_CATALOG,'+
        '    MODULE_SCHEMA,'+
        '    MODULE_NAME,'+
        '    USER_DEFINED_TYPE_CATALOG,'+
        '    USER_DEFINED_TYPE_SCHEMA,'+
        '    USER_DEFINED_TYPE_NAME,'+
        '    DATA_TYPE,'+
        '    CHARACTER_MAXIMUM_LENGTH,'+
        '    CHARACTER_OCTET_LENGTH,'+
        '    COLLATION_CATALOG,'+
        '    COLLATION_SCHEMA,'+
        '    COLLATION_NAME,'+
        '    NUMERIC_PRECISION,'+
        '    NUMERIC_PRECISION_RADIX,'+
        '    NUMERIC_SCALE,'+
        '    DATETIME_PRECISION,'+
        '    INTERVAL_TYPE,'+
        '    INTERVAL_PRECISION,'+
        '    TYPE_USER_DEFINED_TYPE_CATALOG,'+       //todo remove: SQL3 only?
        '    TYPE_USER_DEFINED_TYPE_SCHEMA,'+
        '    TYPE_USER_DEFINED_TYPE_NAME,'+
        '    SCOPE_CATALOG,'+       //todo remove: SQL3 only?
        '    SCOPE_SCHEMA,'+
        '    SCOPE_NAME,'+
        '    ROUTINE_BODY,'+
        '    ROUTINE_DEFINITION,'+
        '    EXTERNAL_NAME,'+
        '    EXTERNAL_LANGUAGE,'+
        '    PARAMETER_STYLE,'+
        '    IS_DETERMINISTIC,'+
        '    SQL_DATA_ACCESS,'+
        '    SQL_PATH,'+
        '    SCHEMA_LEVEL_ROUTINE,'+
        '    MAX_DYNAMIC_RESULT_SETS,'+
        '    IS_USER_DEFINED_CAST,'+
        '    IS_IMPLICITLY_INVOCABLE,'+
        '    ROUTINE_CREATED,'+
        '    ROUTINE_LAST_ALTERED'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    routine_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    routine_name,'+
        '    CASE routine_type'+
        '      WHEN ''P'' THEN ''PROCEDURE'' '+
        '      WHEN ''F'' THEN ''FUNCTION'' '+
               //todo 'method' for SQL/99
        '    ELSE'+
        '      routine_type'+  //todo better to return UNKNOWN ?
        '    END,'+
        '    NULL,'+ //module
        '    NULL,'+ //module
        '    NULL,'+ //module
        '    NULL,'+ //udt
        '    NULL,'+ //udt
        '    NULL,'+ //udt
        '    TYPE_NAME,'+
        '    width,'+        //todo need case for some of these: dependent on data_type
        '    width,'+
        '    null,'+         //todo collation
        '    null,'+
        '    null,'+
        '    width,'+
        '    NUM_PREC_RADIX,'+
        '    scale,'+
        '    width,'+
        '    null,'+          //todo interval type
        '    scale,'+
        '    null,'+          //udt
        '    null,'+
        '    null,'+
        '    null,'+          //scope
        '    null,'+
        '    null,'+
        '    ''SQL'','+
        '    routine_definition,'+ //todo convert to CHARACTER_DATA?
        '    null,'+          //external
        '    null,'+
        '    null,'+
        '    null,'+
        '    ''CONTAINS'','+
        '    null,'+
        '    ''YES'','+
        '    0,'+
        '    ''NO'','+
        '    null,'+
        '    null,'+          //todo created/modified
        '    null'+
        '    FROM'+
//note: hand-optimised
(*
        '    '+sysCatalogDefinitionSchemaName+'.sysTable  natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog'+
*)
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysRoutine left outer join'+
        '    ('+sysInformationSchemaName+'.TYPE_INFO natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysParameter) on parameter_type='+intToStr(ord(vtResult))+' AND sysParameter.routine_id = sysRoutine.routine_id '+      //todo: bug fix when 0 parameters!
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         OR sysRoutine.routine_id IN (SELECT routine_id FROM '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) ) '+

        '  CREATE VIEW PARAMETERS ( '+
        '    SPECIFIC_CATALOG,'+
        '    SPECIFIC_SCHEMA,'+
        '    SPECIFIC_NAME,'+
        '    ORDINAL_POSITION,'+
        '    PARAMETER_MODE,'+
        '    IS_RESULT,'+
        '    AS_LOCATOR,'+
        '    PARAMETER_NAME,'+
        '    DATA_TYPE,'+
        '    CHARACTER_MAXIMUM_LENGTH,'+
        '    CHARACTER_OCTET_LENGTH,'+
        '    COLLATION_CATALOG,'+
        '    COLLATION_SCHEMA,'+
        '    COLLATION_NAME,'+
        '    CHARACTER_SET_CATALOG,'+
        '    CHARACTER_SET_SCHEMA,'+
        '    CHARACTER_SET_NAME,'+
        '    NUMERIC_PRECISION,'+
        '    NUMERIC_PRECISION_RADIX,'+
        '    NUMERIC_SCALE,'+
        '    DATETIME_PRECISION,'+
        '    INTERVAL_TYPE,'+
        '    INTERVAL_PRECISION,'+
        '    USER_DEFINED_TYPE_CATALOG,'+       //todo remove: SQL3 only?
        '    USER_DEFINED_TYPE_SCHEMA,'+
        '    USER_DEFINED_TYPE_NAME,'+
        '    SCOPE_CATALOG,'+       //todo remove: SQL3 only?
        '    SCOPE_SCHEMA,'+
        '    SCOPE_NAME'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    routine_name,'+
        '    parameter_id,'+ //todo check correct for info-schema views! reflexive...or rather should reset ids at higher levels as per aliases...but need for data retrieval, so need another way to get col-position...
        '    CASE parameter_type'+
        '      WHEN 0 THEN ''IN'' '+
        '      WHEN 1 THEN ''OUT'' '+
        '      WHEN 2 THEN ''INOUT'' '+
        '    ELSE'+
        '      NULL'+
        '    END,'+
        '    ''NO'','+
        '    ''NO'','+
        '    parameter_name,'+
        '    TYPE_NAME,'+
        '    width,'+        //todo need case for some of these: dependent on data_type
        '    width,'+
        '    null,'+         //todo collation
        '    null,'+
        '    null,'+
        '    null,'+         //todo character set
        '    null,'+
        '    null,'+
        '    width,'+
        '    NUM_PREC_RADIX,'+
        '    scale,'+
        '    width,'+
        '    null,'+          //todo interval type
        '    scale,'+
        '    null,'+          //udt
        '    null,'+
        '    null,'+
        '    null,'+          //scope
        '    null,'+
        '    null'+
        '    FROM'+
//note: hand-optimised
(*
        '    '+sysCatalogDefinitionSchemaName+'.sysTable  natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog'+
*)
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysRoutine natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysParameter natural join'+
        '    '+sysInformationSchemaName+'.TYPE_INFO'+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND parameter_type<>'+intToStr(ord(vtResult))+
        '    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         OR routine_id IN (SELECT routine_id FROM '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) ) '+

        '  CREATE VIEW ROUTINE_PRIVILEGES ( '+
        '    GRANTOR,'+
        '    GRANTEE,'+
        '    SPECIFIC_CATALOG,'+
        '    SPECIFIC_SCHEMA,'+
        '    SPECIFIC_NAME,'+
        '    ROUTINE_CATALOG,'+
        '    ROUTINE_SCHEMA,'+
        '    ROUTINE_NAME,'+
        '    PRIVILEGE_TYPE,'+
        '    IS_GRANTABLE'+
        '    ) AS SELECT'+
        '    sysAuth_GRANTOR.auth_name,'+
        '    sysAuth_GRANTEE.auth_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    routine_name,'+
        '    catalog_name,'+
        '    schema_name,'+
        '    routine_name,'+
        '    CASE privilege'+            //todo keep in sync with TprivilegeType ordering
        '      WHEN 0 THEN ''SELECT'' '+
        '      WHEN 1 THEN ''INSERT'' '+
        '      WHEN 2 THEN ''UPDATE'' '+
        '      WHEN 3 THEN ''DELETE'' '+
        '      WHEN 4 THEN ''REFERENCES'' '+
        '      WHEN 5 THEN ''USAGE'' '+
        '      WHEN 6 THEN ''EXECUTE'' '+
        //todo TRIGGER = USAGE?
        '    ELSE'+
        '      NULL'+  //todo better to return UNKNOWN ?
        '    END,'+
        '    CASE grant_option'+
        '      WHEN ''Y'' THEN ''YES'' '+
        '    ELSE'+
        '      ''NO'' '+
        '    END'+
        '    FROM'+
{todo revert to natural joins when optimiser can tune them properly - neater...
}
//note: hand-optimised
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTOR,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysAuth AS sysAuth_GRANTEE,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysRoutine,'+
        '    '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege'+
        '    WHERE'+
        '    sysCatalog.catalog_id=sysSchema.catalog_id AND'+
        '    sysSchema.schema_id=sysRoutine.schema_id AND'+
        '    sysAuth_GRANTOR.auth_id=sysRoutinePrivilege.grantor AND'+
        '    sysAuth_GRANTEE.auth_id=sysRoutinePrivilege.grantee AND'+
        '    sysRoutinePrivilege.routine_id=sysRoutine.routine_id AND'+
        '    sysSchema.schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        '    AND ('+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         sysRoutine.routine_id IN (SELECT routine_id FROM '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID) )'+
        '         OR sysRoutine.routine_id IN (SELECT routine_id FROM '+sysCatalogDefinitionSchemaName+'.sysRoutinePrivilege WHERE grantor=CURRENT_AUTHID )'+
        '        ) '+
        //done: and where current_user is grantee

        '  CREATE VIEW SEQUENCES ( '+
        '    SEQUENCE_CATALOG,'+
        '    SEQUENCE_SCHEMA,'+
        '    SEQUENCE_NAME,'+
        '    COUNTER'+
        '    ) AS SELECT'+
        '    catalog_name,'+
        '    schema_name,'+
        '    generator_name,'+
        '    "next"'+
        '    FROM'+
//note: hand-optimised
(*
        '    '+sysCatalogDefinitionSchemaName+'.sysTable  natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog'+
*)
        '    '+sysCatalogDefinitionSchemaName+'.sysCatalog natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysSchema natural join'+
        '    '+sysCatalogDefinitionSchemaName+'.sysGenerator '+
        '    WHERE'+
        '    schema_id<>'+intToStr(sysCatalogDefinitionSchemaId)+' '+
        (*todo that's all until we get the privilege table(s) in place!
        '    AND (auth_id=CURRENT_AUTHID '+ //todo: optimise better: convert IN (a,b) to =a OR =b to use future indexes
        '         OR routine_id IN (SELECT routine_id FROM '+sysCatalogDefinitionSchemaName+'.sysGeneratorPrivilege WHERE grantee IN ('+intToStr(PUBLIC_AUTHID)+',CURRENT_AUTHID)) ) '+
        *)

        '  GRANT SELECT ON '+sysInformationSchemaName+'.TYPE_INFO TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.INFORMATION_SCHEMA_CATALOG_NAME TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.SQL_LANGUAGES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.TABLES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.COLUMNS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.DOMAINS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.DOMAIN_CONSTRAINTS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.KEY_COLUMN_USAGE TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.TABLE_CONSTRAINTS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.TABLE_PRIVILEGES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.COLUMN_PRIVILEGES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.REFERENTIAL_CONSTRAINTS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.ACTIVE_TRANSACTIONS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.SCHEMATA TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.USERS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.ROUTINES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.PARAMETERS TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.ROUTINE_PRIVILEGES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.SEQUENCES TO PUBLIC '+
        '  GRANT SELECT ON '+sysInformationSchemaName+'.CHECK_CONSTRAINTS TO PUBLIC '+

        ';'
        );
      if result=ok then result:=ExecutePlan(st,rc);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed inserting information schema via PrepareSQL/ExecutePlan: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Inserted information schema',vdebug);
        {$ELSE}
        ;
        {$ENDIF}
      if UnPreparePlan(st)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}

      {Add INFORMATION_SCHEMA data}
      {We first need to connect as the schema owner to be able to insert data}
      tr.connect('INFORMATION_SCHEMA','');

      {Add the type_info rows}
      //Note: we add datatype column so we can join sysColumn to find type-name info etc. - i.e. drive insertion by TdataType
      //- also use dataTypeToSQL mapping function used by CLIserver...
      //TODO: replace 17 with MaxNumericPrecision etc.
      result:=PrepareSQL(st,nil,
        'INSERT INTO '+sysInformationSchemaName+'.TYPE_INFO VALUES '+
        //todo check/fix column_size -especially CHAR!
        '('+intToStr(ord(ctChar))+     ',''CHARACTER'',                01,4000,'''''''', '''''''',''LENGTH'',         1,1,3,null,0,0,''CHARACTER'',        null,null,01,null,null,null),'+
        '('+intToStr(ord(ctNumeric))+  ',''NUMERIC'',                  02,17, null,         null,''PRECISION,SCALE'',1,0,2,0,   0,0,''NUMERIC'',          0,   17,  02,null,10,  null),'+
        '('+intToStr(ord(ctDecimal))+  ',''DECIMAL'',                  03,17, null,         null,''PRECISION,SCALE'',1,0,2,0,   0,0,''DECIMAL'',          0,   17,  03,null,10,  null),'+
        '('+intToStr(ord(ctBigInt))+   ',''BIGINT'',                  0-5,17, null,         null,null,               1,0,2,0,   1,0,''BIGINT'',          0,   0,   0-5,null,2,   null),'+
        '('+intToStr(ord(ctInteger))+  ',''INTEGER'',                  04,17, null,         null,null,               1,0,2,0,   1,0,''INTEGER'',          0,   0,   04,null,2,   null),'+
        '('+intToStr(ord(ctSmallInt))+ ',''SMALLINT'',                 05,17, null,         null,null,               1,0,2,0,   1,0,''SMALLINT'',         0,   0,   05,null,2,   null),'+
        '('+intToStr(ord(ctFloat))+    ',''FLOAT'',                    06,17, null,         null,''PRECISION'',      1,0,2,0,   0,0,''FLOAT'',            null,null,06,null,2,   null),'+
        '('+intToStr(998)+{=ctFloat(r) todo fix/remove} ',''REAL'',             07,17, null,null,null,               1,0,2,0,   0,0,''REAL'',             null,null,07,null,2,   null),'+
        '('+intToStr(999)+{=ctFloat(dp) todo fix/remove}',''DOUBLE PRECISION'', 08,17, null,null,        null,               1,0,2,0,   0,0,''DOUBLE PRECISION'', null,null,08,null,2,   null),'+
        '('+intToStr(ord(ctVarChar))+  ',''CHARACTER VARYING'',        12,4000,'''''''', '''''''',''LENGTH'',         1,1,3,null,0,0,''CHARACTER VARYING'',null,null,12,null,null,null),'+
  //todo expose later(ODBC clash?debug Broke MSQuery!)          '('+intToStr(ord(ctBit))+      ',''BIT'',              14,255,'''''''''''','''''''''''',''LENGTH'',         1,1,3,null,0,0,''BIT'',              null,null,14,null,null,null),'+ //todo insert B in literal_prefix!
  //todo expose later(debug? Broke MSQuery!)          '('+intToStr(ord(ctVarBit))+   ',''BIT VARYING'',      15,255,'''''''''''','''''''''''',''LENGTH'',         1,1,3,null,0,0,''BIT VARYING'',      null,null,15,null,null,null)'+  //todo insert B in literal_prefix!
        //Note: the following date_types (3rd column=91,92,94,93,95) are reported differently to pre ODBC 3 clients
        //Note: also the timezone types are not recognised by ODBC clients (esp. msQuery??) & cause problems: debug?
        '('+intToStr(ord(ctDate))+     ',''DATE'',                     91,'+intToStr(DATE_MIN_LENGTH)+', ''DATE '''''',                                         '''''''',          null,               1,0,2,null,0,0,''DATE'',                  null,null,          09,01,  null,null),'+
        '('+intToStr(ord(ctTime))+     ',''TIME'',                     92,'+intToStr(TIME_MAX_LENGTH)+', ''TIME '''''',                                         '''''''', ''PRECISION'',               1,0,2,null,0,0,''TIME'',                     0,'+intToStr(TIME_MAX_SCALE)+',09,02,  null,null),'+
        '('+intToStr(ord(ctTimeWithTimezone))+     ',''TIME WITH TIME ZONE'',      94,'+intToStr(TIME_MAX_LENGTH+TIMEZONE_LENGTH)+', ''TIME '''''',             '''''''', ''PRECISION'',               1,0,2,null,0,0,''TIME WITH TIME ZONE'',      0,'+intToStr(TIME_MAX_SCALE)+',09,04,  null,null),'+
        '('+intToStr(ord(ctTimestamp))+',''TIMESTAMP'',                93,'+intToStr(TIMESTAMP_MAX_LENGTH)+', ''TIMESTAMP '''''',   '''''''',                             ''PRECISION'',               1,0,2,null,0,0,''TIMESTAMP'',                0,'+intToStr(TIME_MAX_SCALE)+',09,03,  null,null),'+
        '('+intToStr(ord(ctTimestampWithTimeZone))+',''TIMESTAMP WITH TIME ZONE'', 95,'+intToStr(TIMESTAMP_MAX_LENGTH+TIMEZONE_LENGTH)+', ''TIMESTAMP '''''',   '''''''', ''PRECISION'',               1,0,2,null,0,0,''TIMESTAMP WITH TIME ZONE'', 0,'+intToStr(TIME_MAX_SCALE)+',09,05,  null,null),'+
        '('+intToStr(ord(ctBlob))+  ',''BINARY LARGE OBJECT'',         30,2147483647,''X'''''', '''''''',''LENGTH'',         1,0,3,null,0,0,''BINARY LARGE OBJECT'',null,null,0-4,null,null,null),'+
        '('+intToStr(ord(ctClob))+  ',''CHARACTER LARGE OBJECT'',      40,2147483647,'''''''', '''''''',''LENGTH'',         1,1,3,null,0,0,''CHARACTER LARGE OBJECT'',null,null,0-1,null,null,null)'+

        //todo complete date/time etc! - link to TDataType? - maybe in future read our types from here!? chicken & egg...
        //...note - last row has missing , at end...
        '; ' );
      if result=ok then result:=ExecutePlan(st,rc);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed inserting TYPE_INFO rows via PrepareSQL/ExecutePlan: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Inserted %d entries into TYPE_INFO',[rc]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
      if UnPreparePlan(st)<>ok then 
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}


      {Add the default schema}
      //todo make owner=DEFAULT authId? - reConnect?
      {Note: this gives a warning about 'missing default schema, since we're about to create it!}
      tr.connect(DEFAULT_AUTHNAME,'');
      result:=PrepareSQL(st,nil,
        'CREATE SCHEMA DEFAULT_SCHEMA ;'
        );
      if result=ok then result:=ExecutePlan(st,rc);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed inserting default schema via PrepareSQL/ExecutePlan: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Inserted default schema',vdebug);
        {$ELSE}
        ;
        {$ENDIF}
      if UnPreparePlan(st)<>ok then 
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}


      //maybe put this in a separate routine/transaction - it doesn't really belong here
      //      but it needs to be done after generator and tables have been opened properly...
      {Now we are in a state to be able to create indexes on the system tables
       todo: we also need to manually add PK/FK constraints for them
             (these are *****more***** important, but less practical - maybe we can ignore them
              by guaranteeing no user-modifications and system-wide-good-behaviour... too lax?)
      }
      //Note: during the creation of these indexes, the system catalogs are used and
      //      the lookup routines immediately and cleverly start using the indexes! (a sign of neat development!)
      //Note: with a better optimiser we might be able to combine some of these into composite indexes & do away with the constituents
      //Note: we must also manually open these indexes! see db open...

      //todo here, instead of calling createSysIndexes we could/should issue ALTER TABLE as _SYSTEM to
      //     add constraints + indexes     
      result:=createSysIndexes(st); //creates indexes for sysTable, sysColumn, sysIndex, sysIndexColumn

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTableColumnConstraint_index1',ioSystem,0,(catalogRelation[sysTableColumnConstraint] as TRelation),nil,ord(stc_table_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnConstraint_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnConstraint_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTableColumnPrivilege_index1',ioSystem,0,(catalogRelation[sysTableColumnPrivilege] as TRelation),nil,ord(scp_table_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnPrivilege_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnPrivilege_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTableColumnPrivilege_index2',ioSystem,0,(catalogRelation[sysTableColumnPrivilege] as TRelation),nil,ord(scp_column_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnPrivilege_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnPrivilege_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTableColumnPrivilege_index3',ioSystem,0,(catalogRelation[sysTableColumnPrivilege] as TRelation),nil,ord(scp_grantor));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnPrivilege_index3 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnPrivilege_index3',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysTableColumnPrivilege_index4',ioSystem,0,(catalogRelation[sysTableColumnPrivilege] as TRelation),nil,ord(scp_grantee));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysTableColumnPrivilege_index4 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysTableColumnPrivilege_index4',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutinePrivilege_index1',ioSystem,0,(catalogRelation[sysRoutinePrivilege] as TRelation),nil,ord(srp_routine_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutinePrivilege_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutinePrivilege_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutinePrivilege_index2',ioSystem,0,(catalogRelation[sysRoutinePrivilege] as TRelation),nil,ord(srp_grantor));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutinePrivilege_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutinePrivilege_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutinePrivilege_index3',ioSystem,0,(catalogRelation[sysRoutinePrivilege] as TRelation),nil,ord(srp_grantee));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutinePrivilege_index3 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutinePrivilege_index3',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysSchema_index1',ioSystem,0,(catalogRelation[sysSchema] as TRelation),nil,ord(ss_schema_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysSchema_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysSchema_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysSchema_index2',ioSystem,0,(catalogRelation[sysSchema] as TRelation),nil,ord(ss_schema_name));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysSchema_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysSchema_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysAuth_index1',ioSystem,0,(catalogRelation[sysAuth] as TRelation),nil,ord(sa_auth_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysAuth_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysAuth_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysAuth_index2',ioSystem,0,(catalogRelation[sysAuth] as TRelation),nil,ord(sa_auth_name));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysAuth_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysAuth_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysConstraint_index1',ioSystem,0,(catalogRelation[sysConstraint] as TRelation),nil,ord(sco_FK_parent_table_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraint_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysConstraint_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysConstraint_index2',ioSystem,0,(catalogRelation[sysConstraint] as TRelation),nil,ord(sco_FK_child_table_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraint_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysConstraint_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysConstraint_index3',ioSystem,0,(catalogRelation[sysConstraint] as TRelation),nil,ord(sco_constraint_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraint_index3 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysConstraint_index3',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      //todo sysConstraint on constraint_name to speed up duplicate checks for create & for drop constraint

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysConstraintColumn_index1',ioSystem,0,(catalogRelation[sysConstraintColumn] as TRelation),nil,ord(scc_constraint_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysConstraintColumn_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysConstraintColumn_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutine_index1',ioSystem,0,(catalogRelation[sysRoutine] as TRelation),nil,ord(sr_routine_name));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutine_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutine_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutine_index2',ioSystem,0,(catalogRelation[sysRoutine] as TRelation),nil,ord(sr_Routine_Id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutine_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutine_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysRoutine_index3',ioSystem,0,(catalogRelation[sysRoutine] as TRelation),nil,ord(sr_Schema_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysRoutine_index3 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysRoutine_index3',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysParameter_index1',ioSystem,0,(catalogRelation[sysParameter] as TRelation),nil,ord(sp_Routine_Id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysParameter_index1 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysParameter_index1',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      (*todo: check if the following would give bad plans...?
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysParameter_index2',(catalogRelation[sysParameter] as TRelation),nil,ord(sp_datatype));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysParameter_index2 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysParameter_index2',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      *)
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysParameter_index3',ioSystem,0,(catalogRelation[sysParameter] as TRelation),nil,ord(sp_Parameter_name));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysParameter_index3 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysParameter_index3',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      result:=CreateIndex(st,nil,sysCatalogDefinitionSchemaId,'sysParameter_index4',ioSystem,0,(catalogRelation[sysParameter] as TRelation),nil,ord(sp_Parameter_id));
      if result<ok then //result=index_id
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Failed creating sysParameter_index4 via CreateIndex: ',vAssertion) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'  Created sysParameter_index4',vdebugMedium);
        {$ELSE}
        ;
        {$ENDIF}


      result:=ok; //reset result (since createIndex returns +ve for ok)

      {Commit changes}
      tr.Commit(st);
    finally
      //todo assert st exists
      st.deleteErrorList;
      if tr.removeStmt(st)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Failed removing temporary stmt',vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
      end;
    end; {try}
  finally
    tr.Free;
  end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(who,'','',vdebug);
  {$ELSE}
  ;
  {$ENDIF}
end; {createInformationSchema}

function TDB.openDB(fname:string;emptyDB:boolean):integer;
{Opens a db
 IN    :     fname          the database filename
             emptyDB        False = expect standard catalog_definition_schema tables to exist
                            True  = expect only sysTable and sysColumn basic tables (ready for catalog backup target)
 RETURNS:  ok
           -2 = incompatible version, too new
           -3 = incompatible version, too old
           -4 = failed to open file (not found/failed to open)
           -5 = failed to open file (invalid header)
           else fail
}
const routine=':openDB';
var
  page:TPage;
  tr:TTransaction;

  isView:boolean;
  viewDefinition:string;

  dummy_null:boolean;
  tempRel:TRelation;
begin
  result:=OpenFile(fname);
  if result=ok then
  begin
    ffname:=fname;
    fopened:=now;
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Opened database file %s on %s',[fname,dbname]),vdebug);
    {$ENDIF}
    //todo read initial pages, e.g. system catalogs, free-page usage etc.
    with (owner as TDBserver) do
    begin
      tr:=TTransaction.create;
      try
        {ensure we can read everything during startup: needed because dbCreate now uses 0:1..0:5 etc.}

        tr.ConnectToDB(self); //connect this temporary transaction to self

        tr.tranRt:=MaxStampId; //to ensure we see index entries created in 2nd phase of db creation...Note: never write here!...
                           //the danger is we could read rolled-back/aborted data!
                           //       but we postpone reading until we've recovered & then we can start proper transactions
                           //       - check the sys-catalog reading routines, e.g. relation.open, are immune

        //07/04/02: create & start a new stmt wherever we used to default to sysStmt
        tr.SynchroniseStmts(true);

        //todo reset buffer stats

        if buffer.pinPage(tr.sysStmt,0,page)<>ok then exit;  //get pointer
        try
          move(page.block.data,dbHeader,sizeof(dbheader));
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('structureVersion=%d.%d',[dbheader.structureVersionMajor,dbheader.structureVersionMinor]),vdebug);
          log.add(who,where+routine,format('DiskBlocksize=%d',[dbheader.DiskBlocksize]),vDebug);
          {$ENDIF}

          {Check we can read this database file
           Note: we've already assumed page structure is readable,
           i.e. page not torn (1st and last bytes are equal)
           so this limits us from modifying the page tearing bytes
           }
          if dbheader.structureVersionMajor>dbStructureVersionMajor then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Incompatible database structure version!',vError);
            {$ENDIF}
            result:=-2;
            exit; //abort
          end;
          if dbheader.structureVersionMajor<dbStructureVersionMajor then
          begin
            //here build-in any backwards compatible code to read
            //      (or possible auto-upgrade) old database files

            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Incompatible database structure version!',vError);
            {$ENDIF}
            result:=-3;
            exit; //abort
          end;
          //Note: any minor version differences are assumed to be ok

          if dbheader.diskBlockSize<>DiskBlockSize then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Incompatible diskBlocksize!',vError);
            {$ENDIF}
            result:=-3;
            exit; //abort
          end;

          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'DbMap='+intToStr(dbheader.dbmap),vdebug);
          log.add(who,where+routine,'DbDir='+intToStr(dbheader.dbdir),vdebug);
          {$ENDIF}
        finally
          buffer.unPinPage(tr.sysStmt,0);
        end; {try}

        {Load system catalog relations}
        //todo use a loop to open the relations!

        {Note: once we open them here, subsequent transactions using them will get
               a fixed catalog structure throughout the life of this Tdb instance
               (because we subsequently only access the Trelations,
                unless we start using Tr level catalog relations & then future
                connections may read the new sys catalog structure - ok?).
               So if a transaction modified the sysColumn table (for example)
               this would not affect the catalog definitions, even after the
               transaction has been committed, until the next db restart.
               This is good, because no user should be able to modify these tables
               but if a system-level routine wants to it can (e.g. db version upgrades)
               without having to unload & reload the db data.

               todo: so ensure that when we read sysColumn below we do read its
                     structure from itself (or at least assert it's the same!)
                     This would allow extra columns to be added to sysColumn, etc.,
                     without reloading the db data!
        }
        {sysTable}
        {We need to open this first to be able to find all other tables}
        with (catalogRelation[sysTable] as TRelation) do
        begin
          //Note: we open the sysTable with its filename (chicken & egg)
          if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTable_file,isView,viewDefinition)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysTable_table,vdebugError);
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            //todo assert not isView
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Opened '+sysTable_table,vdebug);
            {$ENDIF}
            {We defer reading the last table_id until after sysTran is open when we can tr.start and make sure we read ALL tables! 03/10/99}
          end;
        end; {with}

        {sysColumn}
        with (catalogRelation[sysColumn] as TRelation) do
        begin
          if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysColumn_table,isView,viewDefinition)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysColumn_table,vdebugError);
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            //todo assert not isView
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Opened '+sysColumn_table,vdebug);
            {$ENDIF}
          end;
        end; {with}

        (*todo defer for now... debug
        {sysIndex}
        with (catalogRelation[sysIndex] as TRelation) do
        begin
          if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysIndex_table,isView,viewDefinition)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysIndex_table,vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            //todo assert not isView
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Opened '+sysIndex_table,vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          end;
        end; {with}

        {sysIndexColumn}
        with (catalogRelation[sysIndexColumn] as TRelation) do
        begin
          if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysIndexColumn_table,isView,viewDefinition)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysIndexColumn_table,vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit; //abort;
          end
          else
          begin
            //todo assert not isView
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,'Opened '+sysIndexColumn_table,vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          end;
        end; {with}
        *)


        if not emptyDB then
        begin
          {sysTran}
          with (catalogRelation[sysTran] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,'sysTran',isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading sysTran',vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened sysTran',vdebug);
              {$ENDIF}
              //todo note this page & pin it good!
            end;
          end; {with}

          {sysTranStmt}
          with (catalogRelation[sysTranStmt] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,'sysTranStmt',isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading sysTranStmt',vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened sysTranStmt',vdebug);
              {$ENDIF}
              //todo note this page & pin it good!
            end;
          end; {with}

          {sysDomain}
          with (catalogRelation[sysDomain] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysDomain_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysDomain_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysDomain_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysGenerator}
          with (catalogRelation[sysGenerator] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysGenerator_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysGenerator_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysGenerator_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysAuth}
          with (catalogRelation[sysAuth] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysAuth_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysAuth_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysAuth_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysTableColumnPrivilege}
          with (catalogRelation[sysTableColumnPrivilege] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableColumnPrivilege_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysTableColumnPrivilege_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysTableColumnPrivilege_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysRoutinePrivilege}
          with (catalogRelation[sysRoutinePrivilege] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysRoutinePrivilege_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysRoutinePrivilege_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysRoutinePrivilege_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysSchema}
          with (catalogRelation[sysSchema] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysSchema_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysSchema_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysSchema_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysConstraint}
          with (catalogRelation[sysConstraint] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysConstraint_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysConstraint_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysConstraint_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysConstraintColumn}
          with (catalogRelation[sysConstraintColumn] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysConstraintColumn_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysConstraintColumn_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysConstraintColumn_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysDomainConstraint}
          with (catalogRelation[sysDomainConstraint] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysDomainConstraint_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysDomainConstraint_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysDomainConstraint_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysTableColumnConstraint}
          with (catalogRelation[sysTableColumnConstraint] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableColumnConstraint_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysTableColumnConstraint_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysTableColumnConstraint_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysIndexColumn} //put before sysIndex because any indexes will fail to open if sysIndex is still closed
          with (catalogRelation[sysIndexColumn] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysIndexColumn_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysIndexColumn_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysIndexColumn_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysIndex}
          with (catalogRelation[sysIndex] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysIndex_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysIndex_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysIndex_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          //*)

          {sysRoutine}
          with (catalogRelation[sysRoutine] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysRoutine_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysRoutine_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysRoutine_table,vdebug);
              {$ENDIF}
            end;
          end; {with}

          {sysParameter}
          with (catalogRelation[sysParameter] as TRelation) do
          begin
            if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysParameter_table,isView,viewDefinition)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysParameter_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Opened '+sysParameter_table,vdebug);
              {$ENDIF}
            end;
          end; {with}


          {$IFNDEF SKIP_MANUAL_INDEXES}
          //todo once the sysIndex tables are open and available
          //     we should then manually open and add any indexes to the earlier sys tables' index lists
          //     i.e. initial lookups are slow until now when we make them fast!
          //     - also make sure during creation that we manually add index entries for earlier sys tables!
          with (catalogRelation[sysTable] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysTable_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysTable_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysColumn] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysColumn_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysColumn_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysIndexColumn] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysIndexColumn_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysIndexColumn_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysTableColumnConstraint] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysTableColumnConstraint_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysTableColumnConstraint_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysTableColumnPrivilege] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysTableColumnPrivilege_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysTableColumnPrivilege_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysRoutinePrivilege] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysRoutinePrivilege_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysRoutinePrivilege_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysSchema] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysSchema_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysSchema_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysAuth] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysAuth_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysAuth_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysConstraint] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysConstraint_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysConstraint_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          with (catalogRelation[sysConstraintColumn] as TRelation) do
          begin
            if OpenIndexes(tr.sysStmt,tableId)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Failed manually opening indexes for '+sysConstraintColumn_table,vdebugError);
              {$ENDIF}
              result:=Fail;
              exit; //abort;
            end
            else
            begin
              //todo assert not isView
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'Manually opened indexes for '+sysConstraintColumn_table,vdebug);
              {$ENDIF}
            end;
          end; {with}
          //Note: sysRoutine and sysParameter were opened after sysIndex so they don't need manual entries..
          //      tried moving opening of sysindex earlier to avoid need for so many others but failed & didn't have time to investigate (18/09/02)

          //todo etc...? no more expected..
          {$ENDIF}
        end;
        //else emptyDB skeleton open

      finally
        tr.tranRt:=InvalidStampId; //restore tran id //Note: assumes 'not in a transaction'=>InvalidTranId
        tr.SynchroniseStmts(true);
        tr.free;
      end; {try}

      if not emptyDB then
      begin
        {Now recover if the db crashed}
        //todo maybe skip this (& save a tranId) if it's not required - how do we know? -pre-scan sysTran for non-rolledbacks?
        //todo- we should do this before/at-start-of the sys-transaction above! - can't cos sysTran is not open - chicken & egg!
        //      maybe better if we can do it immediately after sysTran/Stmt is opened?
        //      especially since failure to open a sys relation will abort the routine=bad!
        tr:=TTransaction.create;
        try
          {ensure we can read everything during startup: needed because dbCreate now uses 0:1..0:5 etc.
           plus creating info_schema (+ currently indexes) is done in yet another transaction}

          tr.connectToDB(self);
          tr.Start;
          //Note: TranId will be largest, so we can read all - neat!
          tr.DoRecovery;
          {todo also need to
             fix any mismatching dir-page free & actual free
             etc.
          }
          tr.commit(tr.sysStmt);
        finally
          tr.free;
        end; {try}

        tr:=TTransaction.create;
        try
          {ensure we can read everything during startup: needed because dbCreate now uses 0:1..0:5 etc.}

          tr.ConnectToDB(self); //connect this temporary transaction to self
          tr.Start; 

          {sysOption: note we open this temporarily here & read the current values into db properties
           Note: in future we may need to read these values on the fly, so may need a catalogRelation[] entry}
          tempRel:=TRelation.Create;
          try
            with tempRel do
            begin
              if Open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysOption_table,isView,viewDefinition)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,'Failed reading '+sysOption_table,vdebugError);
                {$ENDIF}
                result:=Fail;
                exit; //abort; //we will use the default settings as set in Tdb.create
              end
              else
              begin
                //todo assert not isView
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,'Opened '+sysOption_table,vdebug);
                {$ENDIF}
              end;
            end; {with}

            //Note: not shared so no need for start
            //todo for oi:=otOptimiser to otOptimiser do...
            if findCatalogEntryByString(tr.sysStmt,tempRel,ord(so_Option_name),OptionString[otOptimiser])=ok then
            begin
              with tempRel do
              begin
                fTuple.GetInteger(ord(so_Option_value),sysOption[otOptimiser].value,dummy_null); //todo store null?
                fTuple.GetString(ord(so_Option_text),sysOption[otOptimiser].text,dummy_null); //todo store null?
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,format('Found sysOption relation %s in %s (with value=%d, text=%s)',[OptionString[otOptimiser],sysOption_table,sysOption[otOptimiser].value,sysOption[otOptimiser].text]),vDebugLow);
                {$ENDIF}
              end; {with}
            end;
            //todo else error!

            //Note: not shared so no need for stop
          finally
            tempRel.free;
          end; {try}

          tr.commit(tr.sysStmt);
        finally
          tr.free;
        end; {try}
      end;
      //else emptyDB skeleton open
    end; {with}
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Failed opening database '+fname,vError);
    {$ENDIF}
    if result=-2 then
      result:=-5 //invalid header
    else
      result:=-4; //not found/failed to open
  end;
end; {openDB}

{debug}
procedure TDB.Status;
var
  oi:ToptionType;
begin
  {$IFDEF DEBUG_LOG}
  log.add(who,where,'  DB Status:',vdebug);
  log.add(who,where,format('   Name=%10s, File=%20s',[dbName,ffname]),vdebug);
  for oi:=otOptimiser to otOptimiser do
  begin
    log.add(who,where,format('   %s=%d %s',[OptionString[oi],SysOption[oi].value,SysOption[oi].text]),vdebug);
  end;
  log.add(who,where,'  DB connections:',vdebug);
  log.add(who,where,showTransactions,vdebug);
  {$ENDIF}
end;

function TDB.readPage(id:PageId;p:TObject{TPage}):integer;
{Reads a page from the specified disk slot (page id)
 IN     : id        - the disk page id
          p         - the page
 RETURN : +ve=ok,
          -2=read exception
          -3=corruption: tearStart<>tearEnd (page has been read)
          else=failed

 Assumes:
   page has been latched

 Side-effects:
   resets page's dirty flag
}
const routine=':readPage';
var
  res:integer;
begin
  result:=Fail; //assume failure
  //todo assert not dirty (seeing as we take the liberty to reset the dirty flag here)
  try
    diskfileCS.Enter;
    try
      if id>Filesize(diskfile) then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Attempted read past end of file: page %d (filesize=%d)',[id,filesize(diskfile)]),vAssertion);
        {$ENDIF}
        exit; //abort
      end;
      {Do it}
      //todo pass via a disk-access unit? and use another thread to free the caller
      //todo check {$IOResult} rather than (more expensive?) try..except?
      seek(diskfile,id);
      blockread(diskfile,(p as TPage).block,1,res);
    finally
      diskfileCS.Leave;
    end; {try}

    TPage(p).dirty:=False; //reset dirty flag
    if res=1 then
    begin
      result:=ok;

      //todo check for errors - checksum? what if corrupt? - auto-fix?
      if (result=ok) and (TPage(p).block.tearStart<>TPage(p).block.tearEnd) then
      begin //corruption
        result:=-3;
        exit;
      end;
    end;
    //else failed to read
  except
    on E:Exception do
      result:=-2; //exception during read - big failure!
  end; {try}
end; {readPage}

function TDB.writePage(id:PageId;p:TObject{TPage}):integer;
{Writes the page to the specified disk slot (page id)
 IN     : id        - the disk page id
          p         - the page
 RETURN : +ve=ok, -ve=failed

 Assumes:
   page has been latched (to prevent another thread latching & modifying it during write-out)

 Side-effects:
   resets page's dirty flag
}
const routine=':writePage';
var
  res:integer;
begin
  result:=Fail; //assume failure
  //todo maybe assert/warn if not dirty? (seeing as we take the liberty to reset the dirty flag here)
  try
    diskfileCS.Enter;
    try
      if id>Filesize(diskfile) then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Attempted write past end of file: page %d (filesize=%d)',[id,filesize(diskfile)]),vAssertion);
        {$ENDIF}
        exit; //abort
      end;
      {Do it}
      //todo pass via a disk-access unit? and use another thread to free the caller
      //todo check for errors - checksum? what if corrupt? - auto-fix?
      {First flip the torn page checks}
      (p as TPage).block.tearStart:=TPage(p).block.tearStart xor 1;
      TPage(p).block.tearEnd:=TPage(p).block.tearStart;
      //todo check {$IOResult} rather than (more expensive?) try..except?
      seek(diskfile,id);
      blockwrite(diskfile,TPage(p).block,1,res);  //todo guarantee this writes the whole block now?
      //todo read back the page & compare (switchable?) - if error then retry - if still error then what?
      //- maybe mark block as bad, write block elsewhere & relink & adjust directory pages etc.?
    finally
      diskfileCS.Leave;
    end; {try}
    TPage(p).dirty:=False; //reset dirty flag
    if res=1 then result:=ok;
  except
    on E:Exception do
      result:=-2; //exception during write - big failure!
  end; {try}
end; {writePage}

{TODO speed up these routines - use assembly}
(*
function MapPageIntegerFull:integer;  //deprecated
begin
  result:=$FFFFFFFF;
end;
*)
function MapPageCardinalFull:cardinal;
begin
  result:=$FFFFFFFF;
end;
function MapPageOffset(pid:PageId):cardinal;
{Return the directory map page offset for this pageId
  0=first map page, 1=2nd etc.}
begin
  result:=(pid div ((32*BlockSize) div sizeof(cardinal)));  //todo replace 32 with bits-per-cardinal
end;
(*
function MapPageIntegerOffset(pid:PageId):integer;  //deprecated
{Return the integer map offset for this pageId}
begin
  result:=((pid div 32) *sizeof(integer)) mod BlockSize;  //todo replace 32 with bits-per-integer
end;
*)
function MapPageCardinalOffset(pid:PageId):cardinal;
{Return the cardinal map offset for this pageId}
begin
  result:=((pid div 32) *sizeof(cardinal)) mod BlockSize;  //todo replace 32 with bits-per-cardinal
end;
function MapPageBitOffset(pid:PageId):cardinal;
{Return the bit offset for this pageId}
begin
  result:=pid mod 32; //todo replace 32 with bits-per-cardinal
//  if result=0 then result:=(sizeof(cardinal)*32);
end;

function TDB.allocatePage(st:TStmt;var id:PageId):integer;
{Allocates a new free page in the disk file and returns its page id
 OUT     : id        - the disk page id
 RETURN : +ve=ok, -ve=failed

 //todo!! 22/08/00 'atomise'! i.e. shouldn't we flush the map page or at least (better) handle it if we crash before it's written?
 //       I suppose it would be ok providing caller tags map page as dirtied by him & so flushes it on commit
 //       - worst case = page allocated & not marked (but ok because use was not committed...
 //                    ...!!!!No! another user could use this new page & commit before map was written!!!!!= BAD!!!
 //                    or more likely: caller could commit - crash - new caller gets same page & overwrites it!!!!
 //
 //       Probably best to allocate block of pages & always flush map here before anyone can use...
 //       Currently safe because we flush all dirty pages at once!
 //        - although: tr1 allocates & rollsback & shutsdown: file=extended but no allocations recorded! will be re-used though...
}
const routine=':allocatePage';
var
  res:integer;
  mapPageLatch:TPage;
  mapPage:TPage;
  map:cardinal;
  dirPageOffset:integer;
  dirPage:PageId;
  nextDirPage:PageId;

  savePageType:integer; //used to stamp emptyPage when adding new map page

  foundGap:boolean;
  tryInteger:cardinal;
  i:cardinal;
begin
  id:=InvalidPageId;
  result:=Fail; //assume failure

  //todo split into subroutines

  foundGap:=False;

  if dbHeader.dbmap=InvalidPageId then
  begin //special case before map is created
    try
      diskfileCS.Enter;
      try
        seek(diskFile,FileSize(diskFile)); //move to end of file
        emptyPage.block.thisPage:=FilePos(diskFile);  //try to set the page's id
        blockwrite(diskfile,emptyPage.block,1,res);

        if res<>1 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Failed allocating extra system page at end of database',vError);
          {$ENDIF}
        end
        else
        begin
          id:=emptyPage.block.thisPage; //new page id
          result:=ok;
        end;
      finally
        diskfileCS.Leave;
      end; {try}
    except
      on E:Exception do
        result:=-2; //exception during append/write - big failure!
    end; {try}
  end
  else
  begin
    {Note: while we find out which page is free and so which dir map we need to modify,
     we pre-latch the 1st map page here to prevent others allocating the same page.
     Re-pinning and re-latching below is sometimes overkill, but keeps the algorithm intact!
     (so what if we have more than one map page: no one else should need to write to prior ones: except maybe allow deallocater in parallel with allocater?)
    }
    with (owner as TDBserver) do
    begin
      dirPage:=dbHeader.dbMap;
      if buffer.pinPage(st,dirPage,mapPageLatch)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading page map from page %d',[dirPage]),vError);
        {$ENDIF}
        exit; //abort //todo try to do something more useful else we might grind to a halt!?
      end;
      if mapPageLatch.latch(st)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed latching page map from page %d',[dirPage]),vError);
        {$ENDIF}
        exit; //abort //todo try to do something more useful else we might grind to a halt!?
      end;
    end; {with}
    try
      {First try to find free pages from the block map(s)}
      with (owner as TDBserver) do
      begin
        dirPage:=dbHeader.dbMap;
        dirPageOffset:=0;
        //todo: as for file page allocation: store latest non-full page to save lots of time in big DBs: speed

        tryInteger:=0;
        if buffer.pinPage(st,dirPage,mapPage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading page map from page %d',[dirPage]),vError);
          {$ENDIF}
          exit; //abort //todo try to do something more useful else we might grind to a halt!?
        end;
        try
          //todo maybe save time and start from last found free! speed
          while (id=InvalidPageId) do
          begin
            if mapPage.AsCardinal(st,tryInteger)<>MapPageCardinalFull then
            begin
              {we have a candidate} //todo latch it before we check if it's full to prevent race! - or use disk critical section for whole routine? no: blocks readers...
              i:=0;
              while i<32 do
              begin
                if not BitSet(mapPage.AsCardinal(st,tryInteger),i) then break; //todo speed up by AsCardinal once at start of loop
                inc(i);
              end;
              if i=32 then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('A bitmap integer (%d) with a gap did not have one: %x',[tryInteger,mapPage.AsCardinal(st,tryInteger)]),vAssertion);
                {$ENDIF}
                exit; //abort
              end;
              {Work backwards to get the candidate page id - todo: link to inverse map functions!}
              id:=(dirPageOffset*((32*BlockSize) div 4)) + ( (tryInteger div 4)*32)+i;
            end
            else
            begin
              tryInteger:=tryInteger+sizeof(Integer);
              if tryInteger=BlockSize then
              begin
                if mapPage.block.nextPage=InvalidPageId then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Map search hit end of map at page %d',[mapPage.block.thisPage]),vDebug);
                  {$ENDIF}
                  break; //quit scan
                end;
                dirPage:=mapPage.block.nextPage; //move to next page
                tryInteger:=0; //start of new page
                inc(dirPageOffset);

                buffer.unpinPage(st,mapPage.block.thisPage);
                if buffer.pinPage(st,dirPage,mapPage)<>ok then exit;
              end;
            end;
          end; {while}
        finally
          buffer.unpinPage(st,dirPage);
        end; {try}

        if id<>InvalidPageId then        //we found a gap...
        begin
          diskfileCS.Enter;
          try
            if id<FileSize(diskFile) then  //it has been allocated before...
            begin
              foundGap:=True;              //so reuse it below
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Re-allocating page %d',[id]),vDebugLow);
              {$ENDIF}
              //todo make switchable:
              {Reset the page contents before re-use - not required (unless we didn't flush map before crashed... should prevent & then this shouldn't be needed)}
              try
                seek(diskFile,id);
                emptyPage.block.thisPage:=id;  //try to set the page's id
                //todo assert this block is empty?
                //todo check {$IOResult} rather than (more expensive?) try..except?
                blockwrite(diskfile,emptyPage.block,1,res);
                if res<>1 then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed resetting contents of page %d',[id]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  //continue!
              except
                on E:Exception do
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed resetting contents of page %d',[id]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  //continue!
              end; {try}
            end;
          finally
            diskfileCS.Leave;
          end; {try}
        end;
      end; {with}

      if not foundGap then
      begin
        {We must append the new page and then move to the appropriate
         map slot - this may (very rarely) involve appending a new map page}
        //todo enable this routine to allocate a number of pages at once, e.g. 8 for speed
        try
          diskfileCS.Enter;
          try
            //todo check {$IOResult} rather than (more expensive?) try..except?
            seek(diskFile,FileSize(diskFile)); //move to end of file
            emptyPage.block.thisPage:=FilePos(diskFile);  //try to set the page's id
            blockwrite(diskfile,emptyPage.block,1,res);
            if res=1 then //ensure we read the shared emptyPage details before we release the critical section
            begin
              id:=emptyPage.block.thisPage; //new page id
            end;
          finally
            diskfileCS.Leave;
          end; {try}
          if res=1 then
          begin
            {Mark bit in dbmap}
            if dbHeader.dbmap<>InvalidPageId then
              with (owner as TDBserver) do
              begin
                {Find the appropriate dir page}
                dirPage:=dbHeader.dbMap;
                nextdirPage:=dbHeader.dbMap;
                dirPageOffset:=MapPageOffset(id); //count this down until we arrive at the correct directory map page
                {skip forward to appropriate map page}
                while dirPageOffset>0 do            //todo test map page boundary! - need v.big db
                begin
                  if buffer.pinPage(st,dirPage,mapPage)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading page map from page %d',[dirPage]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    exit; //abort
                  end;
                  try
                    if mapPage.block.nextPage=InvalidPageId then
                    begin
                      //need to allocate a new map page (recursion can't help!)
                      //todo: we should notify someone that this page should be re-organised to start of db to save head movement
                      //todo try..excepts around disk i/o's
                      diskfileCS.Enter;
                      try
                        savePageType:=emptyPage.block.pageType; //save

                        emptyPage.block.pageType:=ptDBmap;
                        emptyPage.block.prevPage:=dirPage; //link-back

                        seek(diskFile,FileSize(diskFile)); //move to end of file
                        emptyPage.block.thisPage:=FilePos(diskFile);  //try to set the page's id
                        if emptyPage.latch(st)=ok then //todo any point latching this - although is speed important here?
                        begin
                          try
                            emptyPage.SetCardinal(st,0,$02);       //mark this new dir page allocated (bit 1 = new page we're now adding)
                            blockwrite(diskfile,emptyPage.block,1,res);
                            emptyPage.block.pageType:=savePageType; //restore
                            emptyPage.block.prevPage:=InvalidPageId;//restore
                            emptyPage.SetCardinal(st,0,$00);            //restore
                          finally
                            emptyPage.Unlatch(st);
                          end; {try}
                        end
                        else
                        begin
                          res:=2; //cause fail (over-use error trap below)
                          emptyPage.block.pageType:=savePageType; //restore
                          emptyPage.block.prevPage:=InvalidPageId;//restore
                          emptyPage.SetCardinal(st,0,$00);            //restore
                        end;

                        //ensure we read the shared emptyPage details before we release the critical section
                        if res<>1 then
                        begin
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,'Failed adding new page map at end of database',vError);
                          {$ENDIF}
                          exit; //abort
                        end;
                        mapPage.block.nextPage:=emptyPage.block.thisPage; //link-forward

                        mapPage.dirty:=True;
                      finally
                        diskfileCS.Leave;
                      end; {try}
                    end;
                    nextDirPage:=mapPage.block.nextPage;
                    dec(dirPageOffset); //reduce jump count
                  finally
                    buffer.unpinPage(st,dirPage);
                    dirPage:=nextDirPage;
                  end; {try}
                end; {while}
              end; {with}
          end
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed allocating extra page at end of database',vError);
            {$ELSE}
            ;
            {$ENDIF}
        except
          on E:Exception do
            result:=-2; //exception during append/write - big failure!
        end; {try}
      end;

      {Ok, we have the map page=dirPage, we also have the page id to be allocated
       and the disk space for it has been made available, so mark it} //todo keep page pinned/locked so no-one else can jump in!
      with (owner as TDBserver) do
      begin
        if buffer.pinPage(st,dirPage,mapPage)<>ok then exit;  //get pointer, else abort
        try
          if mapPage.latch(st)=ok then
          begin
            try
              map:=mapPage.AsCardinal(st,MapPageCardinalOffset(id));
              {$IFDEF DEBUG_ALLOCDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Allocation map[%d] before=%x',[MapPageCardinalOffset(id),map]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              map:=bitOn(map,MapPageBitOffset(id));
              {$IFDEF DEBUG_ALLOCDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Allocation map[%d] after allocating page %d=%x',[MapPageCardinalOffset(id),id,map]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              mapPage.SetCardinal(st,MapPageCardinalOffset(id),map);
              mapPage.dirty:=True;
            finally
              mapPage.Unlatch(st);
            end; {try}
            //todo 30/08/00 moved: mapPage.dirty:=True;
          end
          else
            exit; //abort
        finally
          buffer.unpinPage(st,dirPage);
        end; {try}
      end; {with}

      result:=ok;
    finally
      {Release our lock}
      with (owner as TDBserver) do
      begin
        mapPageLatch.Unlatch(st);
        buffer.unpinPage(st,mapPageLatch.block.thisPage);
      end; {with}
    end; {try}
  end;
end; {allocatePage}

function TDB.deallocatePage(st:Tstmt;id:PageId):integer;
{De-allocates an existing page in the disk file
 IN     : id        - the disk page id
 RETURN : +ve=ok, -ve=failed

 Assumes:
   currently will give an error message if pages frame cannot be reset
   - this would happen if the page was still pinned/dirty

   the page is still in the cache
    - since it cannot be pinned this cannot be guaranteed by the caller
    //so ignore flush/reset messages!

 Notes:
  does not de-allocate the disk space, even if it's the last page
  ...todo it should eventually

  this was written a long time after the allocatePage routine (12/02/00)
  and needs testing - but is much simpler.
  Written for extendible hash-index overflow chain splitting

  The page is flushed from the buffer and removed from the buffer manager's control
  - otherwise a re-allocation could re-use the old data (even though
  reallocate (currently) writes an empty page to the disk - the buffer would not re-read it)
  todo: we should leave the page buffered & just zeroise it somehow so we don't needlessly
        re-read if/when we re-allocate it - speed

 todo: also, need to 'atomise' to prevent map page showing page allocation when it's been de-allocated (I think 22/08/00 - does it matter?)
       - else another user could jump in the gap & assume page existed when it's been zapped!

 //       Probably best to de-allocate (block of?) pages & always flush map here before anyone can lose...
 //       Currently safe because we flush all dirty pages at once!
}
const routine=':deallocatePage';
var
  mapPage:TPage;
  map:cardinal;
  dirPageOffset:integer;
  dirPage:PageId;
  nextDirPage:PageId;
begin
  result:=Fail; //assume failure

  //todo: ifdef safety: speed
  if dbHeader.dbmap=InvalidPageId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed de-allocating page - dbmap invalid',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  //****************
  //todo - need to document map structure!!!!!!

  {Note: we should have no need for pre-latching since only one thread will be
         de-allocating any given page at once (surely!)
  }

  {Find the appropriate dir page}
  dirPage:=dbHeader.dbMap;
  nextdirPage:=dbHeader.dbMap;
  dirPageOffset:=MapPageOffset(id); //count this down until we arrive at the correct directory map page
  {skip forward to appropriate map page}
  with (owner as TDBserver) do
  begin
    while dirPageOffset>0 do            //todo test map page boundary! - need v.big db
    begin
      if buffer.pinPage(st,dirPage,mapPage)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading page map from page %d',[dirPage]),vError);
        {$ENDIF}
        exit; //abort
      end;
      try
        if mapPage.block.nextPage=InvalidPageId then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('No next page map from page %d (was expecting one since dir-offset=%d)',[mapPage.block.thisPage,dirPageOffset]),vError);
          {$ENDIF}
          exit; //abort
        end;
        nextDirPage:=mapPage.block.nextPage;
        dec(dirPageOffset); //reduce jump count
      finally
        buffer.unpinPage(st,dirPage);
        dirPage:=nextDirPage;
      end; {try}
    end; {while}
  end; {with}

  {Ok, we have the map page=dirPage, we also have the page id to be de-allocated
   (the disk space for it will be made available} //todo keep page pinned/locked so no-one else can jump in!
  with (owner as TDBserver) do
  begin
    {Ensure the page is not kept in the cache - else a re-allocation could re-use it & not the scratched page}
    if buffer.flushPage(st,id,nil)<>ok then //todo <ok is better?
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed flushing page - continuing with de-allocation but if cached page exists it may be used on re-allocation instead of scratched page',vAssertion);
      {$ENDIF}
      //todo ignore error if because page is not in cache (an eager reader may have replaced its frame)
      //exit;
    end;
    if buffer.resetPageFrame(st,id)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed resetting page frame - continuing with de-allocation but if cached page exists it may be used on re-allocation instead of scratched page',vAssertion);
      {$ENDIF}
      //todo ignore error if because page is not in cache (an eager reader may have replaced its frame)
      //exit;
    end;

    if buffer.pinPage(st,dirPage,mapPage)<>ok then exit;  //get pointer, else abort
    try
      if mapPage.latch(st)=ok then
      begin
        try
          map:=mapPage.AsCardinal(st,MapPageCardinalOffset(id));
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Allocation map[%d] before=%x',[MapPageCardinalOffset(id),map]),vDebugLow);
          {$ENDIF}
          map:=bitOff(map,MapPageBitOffset(id));
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Allocation map[%d] after de-allocating page %d=%x',[MapPageCardinalOffset(id),id,map]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          mapPage.SetCardinal(st,MapPageCardinalOffset(id),map);
          mapPage.dirty:=True;
        finally
          mapPage.Unlatch(st);
        end; {try}
        //todo 30/08/00 moved:mapPage.dirty:=True;
      end
      else
        exit; //abort
    finally
      buffer.unpinPage(st,dirPage);
    end; {try}
  end;
  result:=ok;
end; {deallocatePage}

function TDB.createFile(st:Tstmt;name:string):integer;
{Create a new disk file for this db<->bufMgr interface
 IN     : name     - the disk filename (without file extension)
 RETURN : +ve=ok, -ve=failed

 Note:
      Deletes file if it already exists!
      Leaves the db file closed
}
const routine=':createFile';
var
  newPid:PageId;
  page:TPage;   //new page ref
begin
  result:=Fail; //assume fail
  assignFile(diskfile,name+DB_FILE_EXTENSION);
  try
    diskfileCS.Enter;
    try
      rewrite(diskfile,DiskBlocksize);
      try
        {Create initial database pages}
        if allocatePage(st,newPid)=ok then //db header page
        begin
          if newPid<>0 then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'First allocated page of new file is not 0 - dbheader must be 0!',vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
          with (owner as TDBserver) do
          begin
          end; {with}
          dbheader.structureVersionMajor:=dbStructureVersionMajor;
          dbheader.structureVersionMinor:=dbStructureVersionMinor;
          dbheader.diskBlockSize:=DiskBlockSize;
          dbheader.dbMap:=InvalidPageId;
          dbheader.dbdir:=InvalidPageId;
        end;

        if allocatePage(st,newPid)=ok then //dbmap page 1
        begin
          with (owner as TDBserver) do
          begin
            if buffer.pinPage(st,newPid,page)<>ok then exit;  //get pointer
            try
              if page.latch(st)=ok then
              begin
                try
                  page.block.pageType:=ptDBmap;
                  page.SetCardinal(st,MapPageCardinalOffset(newPid),$03);       //page 0 and 1 =allocated (self)
                  page.dirty:=True;
                finally
                  page.unlatch(st);
                end; {try}
                //todo 30/08/00 moved:page.dirty:=True;
                dbHeader.dbmap:=newPid; //set dbmap pointer
              end
              else
                exit; //abort
            finally
              buffer.unPinPage(st,newPid);
            end; {try}
          end; {with}
        end;

        if allocatePage(st,newPid)=ok then //dbdir page 2
        begin
          with (owner as TDBserver) do
          begin
            if buffer.pinPage(st,newPid,page)<>ok then exit;  //get pointer
            try
              page.block.pageType:=ptDBdir;
              page.dirty:=True;
              dbHeader.dbdir:=newPid; //set dbdir pointer
            finally
              buffer.unPinPage(st,newPid);
            end; {try}
          end; {with}
        end;

        {Now go back and update the dbheader with the new details}
        //todo should have kept it pinned?
        with (owner as TDBserver) do
        begin
          if buffer.pinPage(st,0,page)<>ok then exit;  //get pointer
          try
            page.block.pageType:=ptDBheader;
            if sizeof(dbheader)>sizeof(page.block.data) then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'DBHeader is too big for page size',vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
            move(dbHeader,page.block.data,sizeof(dbheader)); 

            page.dirty:=True;
          finally
            buffer.unPinPage(st,0);
          end; {try}
        end; {with}

        result:=ok;
      finally
        {First ensure we have released the buffer pages and frames}
        with (owner as TDBserver) do
        begin
          buffer.flushAllPages(st);
        //todo check result of flushAll- if fail, force all to be flushed, even if pinned (better than bug->corruption?)
        // but, would this ensure that we have a consistent db?
          buffer.resetAllFrames(self);
        end;

        system.closeFile(diskfile);
      end; {try}
    finally
      diskfileCS.Leave;
    end; {try}
  except
    on E:Exception do
      result:=-2; //failed
  end; {try}
end; {createFile}

function TDB.openFile(name:string):integer;
{Open an existing disk file for this db<->bufMgr interface
 IN     : name         db diskfile name to open (without filename extension)
 RETURN : +ve=ok,
          -2 = failed reading header
          else failed
}
const routine=':openFile';
var
  headPage:TPage;
begin
  result:=OK; //assume ok
  //assert check it is not already open?
  assignFile(diskfile,name+DB_FILE_EXTENSION);
  try
    diskfileCS.Enter;
    try
      reset(diskfile,DiskBlocksize);
      try
        {Read initial database page to check page size}
        headPage:=Tpage.create;
        try
          if readPage(0,headPage)<>OK then result:=-2; //failed reading header

          //todo check page size etc. e.g. crashed?
        finally
          headPage.free;
        end; {try}
      finally
      end; {try}
    finally
      diskfileCS.Leave;
    end; {try}
  except
    on E:Exception do
      result:=Fail; //failed
  end; {try}
end; {openFile}

function TDB.closeFile:integer;
{Close an open disk file for this db<->bufMgr interface
 RETURN : +ve=ok, -ve=failed

 Assumes: *NOTE* important:
   that all associated buffer pages have been flushed and the frames reset
}
const routine=':closeFile';
begin
  result:=OK; //assume ok
  //assert check it is already open?
  try
    diskfileCS.Enter;
    try
      system.closeFile(diskFile);
    finally
      diskfileCS.Leave;
    end; {try}
  except
    on E:Exception do
      result:=Fail; //failed
  end; {try}
end; {closeFile}

function TDB.getFile(st:Tstmt;fname:string;var pid:PageId):integer;
{Get start of db file
 IN        :   fname                  the filename to find
 OUT       :   pid                    the 1st page of the file
 RETURN    :   +ve=found, else not found

 Note: this routine should only be used for files that are not in the
       sysTable relation (and sysTable itself to bootstrap)
 TODO: scrap this structure altogether? point to sysTable from db-header page
}
const routine=':getFile';
var
  dirpage:TPage;
  dirEntry:TdbDirEntry;
  i:integer;  //dir-slot
begin
  result:=Fail;
  {Find the appropriate slot in the db file directory}
  with (owner as TDBserver) do
  begin
    if buffer.pinPage(st,dbheader.dbdir,dirpage)<>ok then exit;  //get pointer
    try
      i:=0;
      while ((i+1)*sizeof(DirEntry))<sizeof(dirpage.block.data) do
      begin
        dirpage.AsBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
        if dirEntry.filename=fname then break;
        inc(i);
      end;
      if ((i+1)*sizeof(DirEntry))>=sizeof(dirpage.block.data) then
      begin
        //not found
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('File entry %s not found ',[fname]),vdebug);
        {$ENDIF}
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('File entry %s found in dir-slot %d starting at page %d',[fname,i,dirEntry.startPage]),vdebug);
        {$ENDIF}
        pid:=dirEntry.startPage;
        result:=ok;
      end;
    finally
      buffer.unPinPage(st,dbheader.dbdir);
    end; {try}
  end; {with}
end; {getFile}

procedure TDB.dirStatus(st:Tstmt);
{Show directory status
}
const routine=':dirStatus';
var
  dirpage:TPage;
  dirEntry:TdbDirEntry;
  i:integer;  //dir-slot
begin
  {List the slots in the db file directory}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'  Dir Status:',vdebug);
  {$ENDIF}
  with (owner as TDBserver) do
  begin
    if buffer.pinPage(st,dbheader.dbdir,dirpage)<>ok then exit;  //get pointer
    try
      i:=0;
      while ((i+1)*sizeof(DirEntry))<sizeof(dirpage.block.data) do
      begin
        dirpage.AsBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
        if dirEntry.filename<>'' then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(' %3d: Filename=%10s, StartPage=%4d',[i,dirEntry.filename,dirEntry.startPage]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
        inc(i);
      end;
    finally
      buffer.unPinPage(st,dbheader.dbdir);
    end; {try}
  end; {with}
end; {dirStatus}

function TDB.addFile(st:Tstmt;fname:string;var pid:PageId;needDirEntry:boolean):integer;
{Add a db file
 IN        :   fname                  the filename to add
           :   needDirEntry           True if a db-directory entry is required
 OUT       :   pid                    the 1st page of the file
 RETURN    :   +ve=ok, else fail
}
const routine=':addFile';
var
  dirpage, page:TPage;
  dirEntry:TdbDirEntry;
  newPid:PageId;
  i:integer;  //dir slot
begin
  result:=Fail;

  {Ok, get the 1st block of the new file}
  if allocatePage(st,newPid)=ok then
  begin
    with (owner as TDBserver) do
    begin
      if buffer.pinPage(st,newPid,page)<>ok then exit;  //get pointer
      try
        //todo initialise 1st page...
        page.block.pageType:=ptFileDir;
        page.dirty:=True;
      finally
        buffer.unPinPage(st,newPid);
      end; {try}
    end; {with}

    if needDirEntry then
    begin
      {Find a slot in the db file directory}
      with (owner as TDBserver) do
      begin
        if buffer.pinPage(st,dbheader.dbdir,dirpage)<>ok then exit;  //get pointer
        try
          i:=0;
          while ((i+1)*sizeof(DirEntry))<sizeof(dirpage.block.data) do
          begin
            dirpage.AsBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
            if dirEntry.filename='' then break;
            inc(i);
          end;
          if ((i+1)*sizeof(DirEntry))>=sizeof(dirpage.block.data) then
          begin
            //no free entries - try next page... //todo! not necessary? only $sysTable used?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'No free directory entries - TODO need to add another dir page...',vdebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit;
          end
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Free directory entry found: %d',[i]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}

          {Add the directory entry}
          dirEntry.filename:=fname;
          dirEntry.startPage:=newPid;
          if dirpage.latch(st)=ok then
          begin
            try
              dirpage.SetBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
            finally
              dirpage.unlatch(st);
            end; {try}

            dirpage.dirty:=True;

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('File %s added in dir-slot %d starting at page %d',[fname,i,dirEntry.startPage]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          end
          else
            exit; //abort
        finally
          buffer.unPinPage(st,dbheader.dbdir);
        end; {try}
      end; {with}
    end;

    pid:=newpid;

    result:=ok;
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed creating new file - could not allocate first page',vError);
    {$ENDIF}
    result:=-2;
  end;
end; {addFile}

function TDB.removeFile(st:Tstmt;fname:string;pid:PageId;needDirEntry:boolean):integer;
{Remove a db file
 IN        :   fname                  the filename to remove
           :   pid                    the 1st page of the file
           :   needDirEntry           True if a db-directory entry removal is required
 RETURN    :   +ve=ok, else fail
}
const routine=':removeFile';
var
  dirpage, page:TPage;
  dirEntry:TdbDirEntry;
  newPid:PageId;
  i:integer;  //dir slot
begin
  result:=Fail;

  with (owner as TDBserver) do
  begin
    if buffer.pinPage(st,Pid,page)<>ok then exit;  //get pointer
    try
      //todo de-initialise 1st page...
      //todo page.block.pageType:=ptEmpty; //needed? or thisPage:=invalid?
      {Check that this page has been made ready for deletion}
      if page.block.prevPage<>InvalidPageId then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Initial page has a prior pointer (%d)',[page.block.prevPage]),vAssertion);
        {$ENDIF}
        exit; //abort (i.e. over cautious)
      end;
      if page.block.nextPage<>InvalidPageId then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Initial page has a next pointer (%d)',[page.block.nextPage]),vAssertion);
        {$ENDIF}
        exit; //abort (i.e. over cautious)
      end;
    finally
      buffer.unPinPage(st,Pid);
    end; {try}
  end; {with}

  {Ok, remove the 1st block of the file}
  if deallocatePage(st,pid)=ok then
  begin
    if needDirEntry then
    begin
      {Find a slot in the db file directory}
      with (owner as TDBserver) do
      begin
        if buffer.pinPage(st,dbheader.dbdir,dirpage)<>ok then exit;  //get pointer
        try
          i:=0;
          while ((i+1)*sizeof(DirEntry))<sizeof(dirpage.block.data) do
          begin
            dirpage.AsBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
            if dirEntry.filename=fname then break; //assumes filenames are unique here (currently only expecting $sysTable & this will never be removed!?)
            inc(i);
          end;
          if ((i+1)*sizeof(DirEntry))>=sizeof(dirpage.block.data) then
          begin
            //entry not found - try next page... //todo! not necessary? only $sysTable used?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Directory entry not found - TODO need to try another dir page...',vdebugError);
            {$ENDIF}
            exit;
          end
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Directory entry found: %d',[i]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}

          {Remove the directory entry}
          dirEntry.filename:=''; //free
          dirEntry.startPage:=InvalidPageId; {06/01/02 compiler spotted error: was newPid;} //todo: make invalid!?
          if dirpage.latch(st)=ok then
          begin
            try
              dirpage.SetBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
            finally
              dirpage.unlatch(st);
            end; {try}

            dirpage.dirty:=True;

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('File %s removed from dir-slot %d',[fname,i]),vdebug);
            {$ENDIF}
          end
          else
            exit; //abort
        finally
          buffer.unPinPage(st,dbheader.dbdir);
        end; {try}
      end; {with}
    end;

    result:=ok;
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Failed removing file - could not deallocate first page',vError);
    {$ENDIF}
    result:=-2;
  end;
end; {removeFile}


{System catalog routines}
{Notes:
   Obviously these routines need to be highly optimised,
   preferably searching using indexes or hash tables - maybe we could build these
   (in memory) each time the db opens?
   Also, they may become bottlenecks, so it's important the common ones don't
   need to touch the disk - i.e. pin the heavily used catalog pages.

   we must ensure that all callers of these routines are privileged to access all sys tables/columns they use
   - because these routines directly access the tables, they avoid the usual SQL privilege checks
   I think most/all callers are internal & so are privileged because they are effectively _SYSTEM
   and anyway, PUBLIC has read access to the system tables & all are members of PUBLIC (unless extra revokes)
}
function TDB.catalogRelationStart(st:Tstmt;cri:catalogRelationIndex;var rel:TObject{Trelation}):integer;
{Allows catalog routines to access the catalog relation (& maybe callers its tuple) in safety
 i.e. if this relation must be serialised, this routines gains sole access and ensures
      no other caller can do the same until catalogRelationStop is called to release it.
 If the transaction has a duplicate of this relation, for better concurrency, then
 this routine does nothing (but should still be called for future safety).

 IN:
              cri     the catalogRelationIndex of the relation required
 OUT:
              rel     a reference to the protected/concurrent relation for use
                      in catalog access routines (& by caller to access tuples)

 RETURNS:     ok, else fail => could not gain safe access to relation
              //Note: this is not expected to fail by many routines - since failure currently waits indefinitely
              //      so check tableId=0 to check if relation was not open = error in many cases (but not catalog creation for example)
              -2 = relation not yet opened (a particular case: sysIndex)- e.g. database is starting up
                   it's sometimes easier to code as if relation is always available
                   than to code for 1 exceptional bootstrap situation

 Note:
  Failure to call catalogRelationStop may result in a serialised relation becoming blocked = system crunch!

  This routine does not fail if the relation is open
  The caller may wait for this routine to wait for sole access (currently via critical section)
}
const
  routine=':catalogRelationStart';
  notAvailable=-2;
begin
  result:=ok;

  {todo: if there is a duplicate of this at the Tr level, i.e. if tr.catalogRelation[cri]<>nil, then
   point rel at tr.catalogRelation[cri] instead = more concurrency,
  ELSE...}
    //synchronise access to central resource
    catalogRelationCS[cri].Enter;
    rel:=(catalogRelation[cri] as TRelation);

  {$IFDEF DEBUG_LOG}
  if (rel as TRelation).ScanInProgress then
  begin
    log.add(st.who,where+routine,format('Relation %s is already being scanned',[(rel as TRelation).relname]),vAssertion);
  end;
  {$ENDIF}

  //if we are starting up the database and this relation is not available yet, return error
  //Note: this was added to avoid index opening failing - i.e. doesn't matter if caller errors
  //(especially since we manually open indexes missed because sysIndex wasn't open at the time)
  // - todo: better to have a if db-starting-up-flag bypass index-open - then can remove this check = speed/neat
  if (cri in [sysIndex]) and ((rel as Trelation).tableId=0) then
  begin
    catalogRelationCS[cri].Leave;
    rel:=nil;
    result:=notAvailable;
    exit;
  end;

  inc(debugRelationStart);
end; {catalogRelationStart}
function TDB.catalogRelationStop(st:Tstmt;cri:catalogRelationIndex;var rel:TObject{Trelation}):integer;
{Stops allowing catalog routines to access the catalog relation (& maybe callers its tuple) in safety
 i.e. if this relation must be serialised, this releases sole access and ensures
      another caller can now call catalogRelationStart.
 If the transaction has a duplicate of this relation, for better concurrency, then
 this routine does nothing (but should still be called for future safety).

 IN:
              cri     the catalogRelationIndex of the relation to be release
 OUT:
              rel     set to nil for safety: 
                      was the reference to the protected/concurrent relation that was used
                      in catalog access routines (& by caller to access tuples)

 RETURNS:     ok, else fail => could not release safe access to relation
              //Note: this is not expected to fail by many routines - since failure currently will cause the next caller to wait indefinitely
                      - this would be a very bad thing, so we should log any failures here! & fix them

 Note:
  Failure to call catalogRelationStop may result in a serialised relation becoming blocked = system crunch!

  //if caller statically knows that this routine won't do anything, i.e. relation is also at Tr level,
  // e.g. sysTable, sysColumn
  // then it might improve performance to remove the try..finally clause (but still call this routine(?))
  // - since the try..finally might impose an overhead, especially in a tight loop -speed
  // - if we do this, I would surround the try..finally commands with $IFDEF FAST_CATALOG_STOP & $ENDIF
}
begin
  result:=ok;

  {todo: if there is a duplicate of this at the Tr level, i.e. if tr.catalogRelation[cri]<>nil (actually=rel!),
   then point rel at nil & do nothing more = more concurrency,
  ELSE...}
    //unsynchronise access to central resource
    catalogRelationCS[cri].Leave;
    rel:=nil;

  inc(debugRelationStop);
end; {catalogRelationStop}

function TDB.findCatalogEntryByString(st:Tstmt;
                                      rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;
{Searches a catalog relation for a specific string value and returns a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else not found


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it? TODO? =unsafe!?)

       Self-contained so caller needn't call findDoneCatalogEntry to stop the scan
}
const routine=':findCatalogEntryByString';
var
  noMore:boolean;
  s:string;
  s_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    fTupleKey.clearToNulls(st);
    fTupleKey.ClearKeyIds(st);
    fTupleKey.SetKeyId(cRef,1); //1st column in key
    fTupleKey.SetString(cRef,pchar(trimRight(lookFor)),False);
    fTupleKey.preInsert;
    if FindScanStart(st,nil)<>ok then exit;
    noMore:=False;
    try
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!

          fTuple.GetString(cRef,s,s_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Scanning relation %s for %s (%s)',[relname,lookfor,s]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          if not s_null and (CompareText(trimRight(s),lookfor)=0) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %s in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'No more',vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    finally
      FindScanStop(st);
    end; {try}
  end; {with}
end; {findCatalogEntryByString}

function TDB.findCatalogEntryByInteger(st:Tstmt;
                                       rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;
{Searches a catalog relation for a specific integer value and returns a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else not found


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it? TODO? =unsafe!?)

       Self-contained so caller needn't call findDoneCatalogEntry to stop the scan
}
const routine=':findCatalogEntryByInteger';
var
  noMore:boolean;
  i:integer;
  i_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    fTupleKey.clearToNulls(st);
    fTupleKey.ClearKeyIds(st);
    fTupleKey.SetKeyId(cRef,1); //1st column in key
    fTupleKey.SetInteger(cRef,lookFor,False);
    fTupleKey.preInsert;
    if FindScanStart(st,nil)<>ok then exit;
    noMore:=False;
    try
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!

          fTuple.GetInteger(cRef,i,i_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Scanning relation %s for %d (%d)',[relname,lookfor,i]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          if not i_null and (i=lookfor) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %d in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'No more',vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    finally
      FindScanStop(st);
    end; {try}
  end; {with}
end; {findCatalogEntryByInteger}


function TDB.findFirstCatalogEntryByInteger(st:Tstmt;
                                            rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;
{Searches a catalog relation for the first tuple matching a specific integer value and returns
 a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else not found (& scan is closed)


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it?=unsafe!?)

       Starts a scan so caller must call findDoneCatalogEntry to stop the scan
       - else will leave last read page pinned etc.
       (unless result=fail, in which case the scan won't be left open)
}
const routine=':findFirstCatalogEntryByInteger';
var
  noMore:boolean;
  i:integer;
  i_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    fTupleKey.clearToNulls(st);
    fTupleKey.ClearKeyIds(st);
    fTupleKey.SetKeyId(cRef,1); //1st column in key
    fTupleKey.SetInteger(cRef,lookFor,False);
    fTupleKey.preInsert; 
    if FindScanStart(st,nil)<>ok then exit;
    noMore:=False;
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!

          fTuple.GetInteger(cRef,i,i_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Scanning relation %s for %d (%d)',[relname,lookfor,i]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          if not i_null and (i=lookfor) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %d in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('None found %s',[relname]),vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    {We close the scan here to simplify the caller code}
    if result<>ok then FindScanStop(st); 

    //if result=ok then
    inc(debugFindFirstStart);
  end; {with}
end; {findFirstCatalogEntryByInteger}
function TDB.findNextCatalogEntryByInteger(st:Tstmt;
                                           rel:Tobject{Trelation};cRef:colRef;const lookfor:integer):integer;
{Searches a catalog relation for the next tuple matching a specific integer value and returns
 a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else no more found


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it?=unsafe!?)

       Caller must call findDoneCatalogEntry to stop the scan
       - else will leave last read page pinned etc.
}
const routine=':findNextCatalogEntryByInteger';
var
  noMore:boolean;
  i:integer;
  i_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    noMore:=False;
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!
          //          - and so avoid passing the key/col as parameters again! - speed

          fTuple.GetInteger(cRef,i,i_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Scanning relation %s for %d (%d)',[relname,lookfor,i]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          if not i_null and (i=lookfor) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %d in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'No more',vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end; {with}
end; {findNextCatalogEntryByInteger}

function TDB.findFirstCatalogEntryByString(st:Tstmt;
                                            rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;
{Searches a catalog relation for the first tuple matching a specific string value and returns
 a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else not found (& scan closed)


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it?=unsafe!?)

       Starts a scan so caller must call findDoneCatalogEntry to stop the scan
       - else will leave last read page pinned etc.
       (unless result=fail, in which case the scan won't be left open)
}
const routine=':findFirstCatalogEntryByString';
var
  noMore:boolean;
  s:string;
  s_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    fTupleKey.clearToNulls(st);
    fTupleKey.ClearKeyIds(st);
    fTupleKey.SetKeyId(cRef,1); //1st column in key
    fTupleKey.SetString(cRef,pchar(trimRight(lookFor)),False); 
    fTupleKey.preInsert;
    if FindScanStart(st,nil)<>ok then exit; //abort
    noMore:=False;
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!

          fTuple.GetString(cRef,s,s_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Scanning relation %s for %s (%s)',[relname,lookfor,s]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          if not s_null and (CompareText(trimRight(s),lookfor)=0) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %s in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('None found %s',[relname]),vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    {We close the scan here to simplify the caller code}
    if result<>ok then FindScanStop(st); 

    //if result=ok then
    inc(debugFindFirstStart);
  end; {with}
end; {findFirstCatalogEntryByString}
function TDB.findNextCatalogEntryByString(st:Tstmt;
                                           rel:Tobject{Trelation};cRef:colRef;const lookfor:string):integer;
{Searches a catalog relation for the next tuple matching a specific string value and returns
 a pointer to the tuple if found

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else no more found


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it?=unsafe!?)

       Caller must call findDoneCatalogEntry to stop the scan
       - else will leave last read page pinned etc.
}
const routine=':findNextCatalogEntryByString';
var
  noMore:boolean;
  s:string;
  s_null:boolean;
begin
  result:=fail; //=not found

  with (rel as TRelation) do
  begin
    noMore:=False;
      while not noMore do
      begin
        if FindScanNext(st,noMore)<>ok then exit;
        if not noMore then
        begin
          //note: depending on the index/findScan algorithm used
          //          we can assume here that we have a match!
          //          - and so avoid passing the key/col as parameters again! - speed

          fTuple.GetString(cRef,s,s_null);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Scanning relation %s for %s (%s)',[relname,lookfor,s]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          if not s_null and (CompareText(trimRight(s),lookfor)=0) then
          begin
            {Found match}

            result:=ok; //return found
            noMore:=True; //end loop
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Found %s in %s with rid=%d:%d',[lookfor,relname,dbFile.currentRID.pid,dbFile.currentRID.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,'No more',vDebug) //i.e. not found
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end; {with}
end; {findNextCatalogEntryByString}

function TDB.findDoneCatalogEntry(st:Tstmt; rel:Tobject{Trelation}):integer;
{Stops searching a catalog relation

 IN:
                 rel         the catalog relation (must have been retrieved via catalogRelationStart)

 RETURNS:        ok, else fail


 Assumes:
       catalogRelationStart has been called to get serialised access (if required) to rel
       rel is open

 Note: this routine handles both central/serialised relations and local concurrent relations
       so it is important that the routine call is surrounded by start and finally stop calls
       to ensure that any returned tuple remains stable.
       Failure to call stop may result in a serialised relation becoming blocked = system crunch!

       If a system relation is not serialised then calling start/stop is a tiny overhead
       (although the finally may be a big overhead - maybe could remove it?=unsafe!?)
}
const routine=':findDoneCatalogEntry';
begin
  result:=fail;

  with (rel as TRelation) do
  begin
    result:=FindScanStop(st);

    {$IFDEF DEBUG_LOG}
    if result<>ok then
    begin
      log.add(st.who,where+routine,format('Relation %s find scan stop failed with %d',[(rel as TRelation).relname,result]),vAssertion);
    end;
    {$ENDIF}

    inc(debugFindFirstStop);
  end; {with}
end; {findDoneCatalogEntry}

{Notes:
  the generators are not part of a schema, they are catalog level objects
  - here we directly access them with no privilege checks, so ensure all callers
    are allowed access/update.
}
function TDB.getGeneratorNext(st:Tstmt;schema_id:integer;
                                const generatorName:string;var generator_id:integer;var next:integer):integer;
{Searches the system generator catalog relation for the generator tuple with
 a name matching a specific value and returns the next value of it if found
 (after incrementing the next value in a safe/fast/cached/centralised way)

 If db is starting, will used bootstrap generator values instead

 IN:      st             the stmt
          schema_id      the schema id
          generatorName  the generator name
          generator_id   0=use name (non-zero for future use)

 OUT      generator_id   the found id (0 if bootstrapping)
          next           the next value in sequence

 RETURNS: ok
          -2 = failed updating generator
          else fail=generator not found (& returns generator_id=0)
}
const routine=':getGeneratorNext';
var
  sysGeneratorR:TObject; //Trelation
  generator_schema_id:integer;
  start_at,increment,cache_size:integer;
  cycle:string;
  generator_id_null,generator_schema_id_null,start_at_null,next_null,
  increment_null,cache_size_null,cycle_null:boolean;
  writeNext,i:integer;
  cgp:TcachedGeneratorPtr;
begin
  result:=fail;
  //todo if generator_id<>0 then lookup & increment via passed in number: speed (see cache code below)

  generator_id:=0;
  //note: this needs to access a single central sysGenerator relation,
  //      but must we really gain sole access first?
  //      - we must because we have a single central currentRID during scan/find...
  //        so we need a way of directly going to the particular system-generator - i.e. store []RIDs for system catalogs!
  //        (or at least find the generator by generator_id)
  //        then we could just pin/get/inc/update/unpin for that RID with less chance of conflict
  //        - this would be needed especially if/when we use a sysTran_generator! - speed required!
  //        for the moment this is not a big deal, since sysTran has its own fast generator in row 1
  //        -but hang on: tr.start currently relationStarts access to central sysTran!
  //         so surely a fast generator would be faster, but we need to scan the relation anyway...? 6 & half-a-dozen?

  //we hash the generator name onto a cache list of generator caches:
  //         empty slot = not used yet, read from db & cache 20-ish
  //         matching slot = get next from cache, if no more left get next 20-ish from disk (i.e. advance 'next value on disk')
  //         mismatching slot = collision, probe until found/not found
  //       so cache entry=
  //         name
  //         critical section
  //         next value
  //         next value on disk (so this - next value = number left in cache)
  //       & only need to lock sysGenerator (below) if hitting disk, e.g. reading next/first cache block
  //       & could cleverly cache bootstrapping ones by initialising with massive/infinite 'next value on disk'
  //            - would need getGeneratorCurrent... for db use only though?...

  if catalogRelationStart(st,sysGenerator,sysGeneratorR)=ok then
  begin
    try
      if (sysGeneratorR as Trelation).tableId=0 then
      begin //couldn't get access to sysGenerator
        //must be still creating the database, use bootstrap generators
        {Note: we've gained sole access to the bootstrap generator, although there was no need - but quite tidy & safe!}
        if generatorName='sysTable_generator' then begin inc(fsysTable_LastTableId); next:=fsysTable_LastTableId; result:=ok; end;
        if generatorName='sysSchema_generator' then begin inc(fsysSchema_LastSchemaId); next:=fsysSchema_LastSchemaId; result:=ok; end;
        if generatorName='sysDomain_generator' then begin inc(fsysDomain_LastDomainId); next:=fsysDomain_LastDomainId; result:=ok; end;

        //so far, when creating a new db we only CREATE schemas and tables
        //if in future we create other objects, we'll need bootstrap generators here for them as well
      end
      else
      begin //ok, generator table is open
        {First, check if this generator has been accessed and cached already
         If so:
           use a cached number
           remove the generator from the cache if this is the last number (so the next call will hit the disk)
         Note: catalogRelationStart above protects us threadwise
        }
        // keep in sync. with uncacheGenerator
        for i:=0 to cachedGenerators.count-1 do
        begin
          if (compareText(TcachedGeneratorPtr(cachedGenerators.Items[i])^.name,generatorName)=0) and (TcachedGeneratorPtr(cachedGenerators.Items[i])^.schemaId=schema_id) then
          begin //matched in cache
            cgp:=TcachedGeneratorPtr(cachedGenerators.Items[i]);

            next:=cgp.next;
            inc(cgp.next);
            generator_id:=cgp.id; //pass back our id

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found generator in cache %s (index=%d, id=%d, limit=%d) and issued next %d',[generatorName,i,cgp.id,cgp.limit,next]),vdebugLow);
            {$ENDIF}

            if cgp.next>cgp.limit then
            begin //cache is now empty, so make sure the next call hits the disk again
              {$IFDEF SAFETY}
              if (cgp.next-1)<>cgp.limit then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found generator in cache %s but next-1 (%d) <> limit (%d) when cache is exhausted',[generatorName,cgp.next-1,cgp.limit]),vAssertion);
                {$ENDIF}
              end;
              {$ENDIF}

              cachedGenerators.Remove(cgp); //todo ensure result >=0  //todo could use items[i].remove but not as threadsafe if we use threadlist in future (no need now we are protected)
              dispose(cgp);
            end;

            result:=ok;
            exit; //we're done: no need to search/update the generator table
          end;
        end;

        if findFirstCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),generatorName)=ok then
          try
          repeat
          {Found another matching generator for this name}
          with (sysGeneratorR as TRelation) do
          begin
            fTuple.GetInteger(ord(sg_Schema_id),generator_schema_id,generator_schema_id_null);
            if generator_schema_id=schema_Id then
            begin
              //Note: read all columns because we rewrite the whole row //todo improve!
              fTuple.GetInteger(ord(sg_Generator_Id),generator_id,generator_id_null);
              //already got generatorName
              //todo get start, increment, cycle
              fTuple.GetInteger(ord(sg_start_at),start_at,start_at_null);
              fTuple.GetInteger(ord(sg_Generator_next),next,next_null);
              fTuple.GetInteger(ord(sg_increment),increment,increment_null);
              fTuple.GetInteger(ord(sg_cache_size),cache_size,cache_size_null);
              fTuple.GetString(ord(sg_cycle),cycle,cycle_null);
              //{$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found generator relation %s in %s (with generator-id=%d, cache-size=%d) next=%d',[generatorName,sysGenerator_table,generator_id,cache_size,next]),vDebugLow);
              {$ENDIF}
              //{$ENDIF}
              {Now increment the next value in the table}
              {$IFDEF CACHE_GENERATORS}
                if cache_size>1 then
                begin
                  {Store a number of them in a new cache entry for this generator}
                  writeNext:=next+cache_size; //to be flushed to disk  (Note: add 1 here to cache actual number requested (& can then use cache_size=1), but increments would creep... i.e. cache 2 => jumps of 3)
                  new(cgp);
                  cgp.schemaId:=schema_id;
                  cgp.name:=generatorName;
                  cgp.id:=generator_id;
                  cgp.next:=next+1;
                  cgp.limit:=writeNext-1;
                  cachedGenerators.Add(cgp); //todo ensure result >=0  //todo could use items[i].remove but not as threadsafe if we use threadlist in future (no need now we are protected)
                end
                else
                  writeNext:=next+1; //no cache, or cache_size=1 & so no point/invalid to cache
              {$ELSE}
                writeNext:=next+1; //no cache, caching disabled
              {$ENDIF}
              fTuple.clear(st); //prepare to insert //note@ crap way of updating!
              fTuple.SetInteger(ord(sg_Generator_Id),generator_id,generator_id_null);
              fTuple.SetString(ord(sg_Generator_name),pchar(generatorName),False);
              fTuple.SetInteger(ord(sg_Schema_id),generator_schema_id,generator_schema_id_null); 
              fTuple.SetInteger(ord(sg_start_at),start_at,start_at_null); 
              fTuple.SetInteger(ord(sg_Generator_next),writeNext,False);
              fTuple.SetInteger(ord(sg_increment),increment,increment_null);
              fTuple.SetInteger(ord(sg_cache_size),cache_size,cache_size_null);
              fTuple.SetString(ord(sg_cycle),pchar(cycle),cycle_null); 
              fTuple.preInsert;
              try
                //note: dodgy in-place update with no versioning checks
                if fTuple.updateOverwriteNoVersioning(st,fTuple.RID)<>ok then
                begin
                  //error!
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'Failed incrementing generator record',vDebugError);
                  {$ENDIF}
                  result:=-2;
                  exit; //abort
                end;
                {Flush the new next generator value to disk to prevent chance of re-use}
                //todo defer this! we should pre-cache a batch of numbers...e.g. increment 10 in advance? (Oracle actually does this: good idea!)
                (owner as TDBServer).buffer.flushPage(st,fTuple.RID.pid,nil);  //todo use FlushAndKeep to avoid flush-fail on next call if pages are same
              finally
              end; {try}
              //{$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Next generator set to %d',[writeNext]),vdebugLow);
              {$ENDIF}
              //{$ENDIF}
              result:=ok;
            end;
            //else not for our schema - skip & continue looking
          end; {with}
          until (generator_id<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),generatorName)<>ok);
                //todo stop once we've found a generator_id with our schema_Id, or there are no more matching this name
          finally
            if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysGeneratorR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysGenerator)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        //else generator not found
      end;
    finally
      if catalogRelationStop(st,sysGenerator,sysGeneratorR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysGenerator)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysGenerator
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysGenerator)]),vDebugError);
    {$ENDIF}
  end;
end; {getGeneratorNext}

function TDB.uncacheGenerator(st:Tstmt;schema_id:integer;
                                const generatorName:string;generator_id:integer):integer;
{Removes the generator with a name matching a specific value from the cache (if it's there)

 IN:      st             the stmt
          schema_id      the schema id
          generatorName  the generator name
          generator_id   0=use name (non-zero for future use)

 RETURNS: ok
          else fail=generator not found (not necessarily a problem!)
}
const routine=':uncacheGenerator';
var
  sysGeneratorR:TObject; //Trelation
  i:integer;
  cgp:TcachedGeneratorPtr;
begin
  result:=fail;
  //todo if generator_id<>0 then lookup & increment via passed in number: speed (see cache code below)

  generator_id:=0;

  //keep in sync. with getGeneratorNext

  if catalogRelationStart(st,sysGenerator,sysGeneratorR)=ok then
  begin
    try
      if (sysGeneratorR as Trelation).tableId=0 then
      begin //couldn't get access to sysGenerator
        //must be still creating the database
      end
      else
      begin //ok, generator table is open
        {Now check if this generator has been accessed and cached already
         Note: catalogRelationStart above protects us threadwise
        }
        for i:=0 to cachedGenerators.count-1 do
        begin
          if (compareText(TcachedGeneratorPtr(cachedGenerators.Items[i])^.name,generatorName)=0) and (TcachedGeneratorPtr(cachedGenerators.Items[i])^.schemaId=schema_id) then
          begin //matched in cache
            cgp:=TcachedGeneratorPtr(cachedGenerators.Items[i]);

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found generator in cache %s (index=%d, id=%d)',[generatorName,i,cgp.id]),vdebugLow);
            {$ENDIF}

            cachedGenerators.Remove(cgp); //todo ensure result >=0  //todo could use items[i].remove but not as threadsafe if we use threadlist in future (no need now we are protected)
            dispose(cgp);

            result:=ok;
            exit; //we're done
          end;
        end;
      end;
    finally
      if catalogRelationStop(st,sysGenerator,sysGeneratorR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysGenerator)]),vError);
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysGenerator
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysGenerator)]),vDebugError);
    {$ENDIF}
  end;
end; {uncacheGenerator}

function TDB.addTransaction(Tr:TObject{TTransaction}):integer;
{Add a transaction to the list for this db}
const routine=':addTransaction';
var
  newNode:TtranNodePtr;
begin
  result:=fail;
  tranlistCS.BeginWrite;
  try
    //todo put some sort of limit as to the number of db-connections here
    // to avoid malicious/infinite db-connections: maybe use indy's maxConnections?

    new(newNode);

    newNode.next:=tranlist;
    newNode.tran:=Tr;

    tranlist:=newNode;

    {$IFDEF DEBUG_LOG}
    log.add((tr as Ttransaction).sysStmt.who,where+routine,format('Added tran pointer node to head of tranlist: %d [%s]',[longint(tranlist.tran),(tranlist.tran as TTransaction).sysStmt.who]),vDebugLow);
    {$ENDIF}
    result:=ok;
  finally
    tranlistCS.EndWrite;
  end; {try}
  //todo catch any exceptions, since they would be nasty!
end; {addTransaction}

function TDB.removeTransaction(Tr:TObject{TTransaction}):integer;
{Remove a transaction from the list for this db}
const routine=':removeTransaction';
var
  trailNode,nextNode:TtranNodePtr;
begin
  result:=fail;

  tranlistCS.BeginWrite;
  try
    {Find the pointer node with the matching stmt pointer}
    trailNode:=nil;
    nextNode:=tranlist;
    while nextNode<>nil do
    begin
      if nextNode.tran=Tr then break; //found
      trailNode:=nextNode;
      nextNode:=nextNode^.next;
    end;

    if nextNode<>nil then
    begin //found match, delete it
      {$IFDEF DEBUG_LOG}
      log.add((tr as TTransaction).sysStmt.who,where+routine,format('Removing tran %d from tranlist: [%s]',[longint(nextNode.tran),(nextNode.tran as TTransaction).sysStmt.who]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}

      //todo any tests needed to check tran is ok to unlink from this list?

      {Update the list to skip over the pointer node}
      //Note: yes here, and elsewhere, it would be neater if we introduced a fixed header node - easier list logic!
      if trailNode<>nil then
        trailNode.next:=nextNode.next  //skip over about-to-be-zapped node
      else
        tranlist:=nextNode.next;          //we're about to zap the 1st node, so update the root pointer to skip over it

      {ok remove the pointer node}
      dispose(nextNode);

      result:=ok;
    end
    else
    begin
      //handle was not found, error!
      result:=fail;
    end;
  finally
    tranlistCS.EndWrite;
  end; {try}
  //todo catch any exceptions, since they would be nasty!
end; {removeTransaction}

function TDB.detachAnyTransactions(Tr:TObject{TTransaction}):integer;
{Rollsback and terminates and detaches all connected transactions from this db
 - this is a last resort to prevent attachments from damaging any new db
   after create catalog - e.g. garbage collector

 //todo remove need for this by notifying db which thread is garbage collector
   and suspending/disconnecting-reconnecting it during db re-creation

 Note: this could cause problems: we're calling a transaction method from
       another thread! We avoid disconnecting ourself!

       In theory, could hang waiting for a thread to terminate
}
const routine='detachAnyTransactions';
var
  lastNode,nextNode,readAhead:TtranNodePtr;
  isolationDesc:string;
begin
  result:=fail;
  try
    lastNode:=nil;
    nextNode:=tranList;
    while nextNode<>nil do
    begin
      readAhead:=nextNode.next; //in case this node is removed from the list, e.g. via disconnectFromDB
                                //note: assumes list remains stable when a node is removed=bad!

      with (nextNode.tran as TTransaction) do
      begin
        {Kill the garbage collector's controlling thread}
        if nextNode.tran<>tr then
          if thread<>nil then
            if thread is TGarbageCollector then
            begin
              {$IFDEF DEBUG_LOG}
              log.add((tr as TTransaction).sysStmt.who,where+routine,format('Forceably terminating tran %d from tranlist: [%s]',[longint(nextNode.tran),(nextNode.tran as TTransaction).sysStmt.who]),vDebugLow);
              {$ENDIF}
              //Note: after terminating, calls gcOnTerminate only when main thread closes = too late
              //      (because onTerminate is executed in main VCL thread & it is suspended)
              if not thread.suspended then
              begin
                thread.Terminate;
                sleepOS(WAITFOR_GC_TERMINATE); //wait for garbage collector to finish off
                //note: waitFor is too dangerous? should be ok...
              end;

              //              thread.WaitFor; //hang until the thread wakes up and finishes
            end
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add((tr as TTransaction).sysStmt.who,where+routine,format('Forceably cancelling and rolling back tran %d from tranlist: [%s]',[longint(nextNode.tran),(nextNode.tran as TTransaction).sysStmt.who]),vDebugLow);
              {$ENDIF}
              cancel(nil,nil);
              disconnect; //Note: does a rollback
              //todo db:=nil !
              disconnectFromDB;
            end;
      end;

      lastNode:=nextNode;
      //nextNode:=nextNode.next; //unsafe
      nextNode:=readAhead;
      //note: following could return error since disconnectFromDB may have done it already above...
      removeTransaction(lastNode.tran); //will dispose of lastNode, but we've skipped beyond it
    end;
  finally
  end; {try}
  result:=ok;
end; {detachAnyTransactions}

function TDB.showTransactions:string;
{Return formatted list of current transactions
 - actually connections
 - Note: if Rt.tranId=InvalidTranId (0) then no transaction is in progress
}
var
  nextNode:TtranNodePtr;
  isolationDesc:string;
begin
  result:='';
  tranlistCS.BeginRead;
  try
    nextNode:=tranList;
    if nextNode=nil then
    begin
      result:='<none>';
    end
    else
      while nextNode<>nil do
      begin
        //todo: note in future, Rt.tranId could be user's 'kill' reference/handle...
        with (nextNode.tran as TTransaction) do
        begin
          case isolation of
            isSerializable:    isolationDesc:='Serializable';
            isReadCommitted:   isolationDesc:='Read committed';
            isReadUncommitted: isolationDesc:='Read uncommitted';
            isReadCommittedPlusUncommittedDeletions:    isolationDesc:='Read committed (plus uncommitted deletions)'; //internal
            isReadUncommittedMinusUncommittedDeletions: isolationDesc:='Read uncommitted (minus uncommitted deletions)'; //internal
          else
            isolationDesc:='?';
          end; {case}
          {$IFDEF DEBUG_LOG}
          result:=result+format('%-*.*s %30.30s %s',[32,32,authName,who,isolationDesc])+CRLF;
          {$ELSE}
          result:=result+format('%-*.*s %21.21s %s',[32,32,authName,who,isolationDesc])+CRLF;
          {$ENDIF}

          //todo list stmts and their current status?
          {$IFDEF DEBUG_LOG}
          result:=result+showStmts;
          {$ENDIF}
        end;

        nextNode:=nextNode.next;
      end;
  finally
    tranlistCS.EndRead;
  end; {try}
end; {showTransactions}

function TDB.TransactionScanStart:integer;
begin
  result:=Fail;
  tranlistCS.BeginRead;
  tranListNextNode:=tranList;
  result:=ok;
end;
function TDB.TransactionScanNext(var Tr:TObject{TTransaction}; var noMore:boolean):integer;
begin
  result:=fail;
  noMore:=False;

  if tranListNextNode<>nil then
  begin
    tr:=tranListNextNode^.tran;
    tranListNextNode:=tranListNextNode.next;
    result:=ok;
  end
  else
  begin
    noMore:=True;
    tr:=nil;
    result:=ok;
  end;
end;
function TDB.TransactionScanStop:integer;
{Note: up to caller to finally do this after TransactionScanStart
}
begin
  result:=Fail;
  tranlistCS.EndRead;
  result:=ok;
end;

function TDB.findTransaction(FindRt:StampId):TObject{TTransaction};
{Return transaction
 IN:               FindRt     - stmtId not used, just TranId
 RETURNS:          TTransaction or nil if not found
}
var
  nextNode:TtranNodePtr;
  tr:TObject; {TTransaction}
  noMore:boolean;
begin
  result:=nil;
  if TransactionScanStart=ok then
  try
    noMore:=False;
    while not noMore do
    begin
      if TransactionScanNext(tr,noMore)<>ok then exit;
      if not noMore then
        with (tr as TTransaction) do
        begin
          if tranRt.tranId=FindRt.tranId then
          begin
            result:=(tr as TTransaction);
            exit;
          end;
        end;
    end;
  finally
    TransactionScanStop;
  end; {try}
end; {findTransaction}

function TDB.TransactionIsCommitted(CheckWt:StampId):boolean;
{Checks the committed array to see if this transaction is now committed
 - used by transaction visibility checks

 Assumes:
   CheckWt>=tranCommittedOffset (else this routine can't help & should not be called)
   CheckWt<>self.Rt.tranId (else this routine should not be called)

 Note: this routine should be thread-safe without the need for latches
       because we only add partially committed lists before setting the flag bit
}
const routine=':TransactionIsCommitted';
var
  tranStatus:TtranStatusPtr;
  stmtStatus:TstmtStatusPtr;
begin
  {$IFDEF SAFETY}
  {If the tran was before this db session started, then we can't know it's state}
  if CheckWt.tranId<tranCommittedOffset then
  begin
    result:=False; 
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%d cannot be in the committed array which started at %d',[CheckWt.tranId,tranCommittedOffset]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  if tranCommitted[CheckWt.tranId-tranCommittedOffset]=True then
  begin
    if tranPartiallyCommitted[CheckWt.tranId-tranCommittedOffset]=True then
    begin
      result:=False; //default (so if tranPartiallyCommitted but can't find tranPartiallyCommittedDetails = assume the worst = safe) //should really give debugError!
      tranStatus:=tranPartiallyCommittedDetails;
      while tranStatus<>nil do
      begin
        if tranStatus.tid.tranId=CheckWt.tranId then
        begin
          result:=True; //default
          begin //this has been part-rolled-back, so check if the stmt was rolled-back or not
            {Quick check to see if stmtId was rolled-back} //note: only useful in future when we don't write full rollback list -for now we'll keep the algorithm simple
            if CheckWt.stmtId>tranStatus.tid.stmtId then
            begin
              result:=False;
              break; //stmtId is > original tran Rt so it was never advanced by being committed => rolled-back (done to save list space/time)
            end;
            stmtStatus:=tranStatus.rolledBackStmtList;
            while stmtStatus<>nil do
            begin
              if stmtStatus.tid.stmtId=CheckWt.stmtId then
              begin
                result:=False;
                break; //found in part-rolled-back stmt list, so done searching
              end;
              stmtStatus:=stmtStatus.next;
            end; {while}
            break; //not found in part-rolled-back stmt list, so default=True was correct & done searching
          end;
        end;
        tranStatus:=tranStatus.next;
      end; {while}
    end
    else //totally committed
      result:=True;
  end
  else //not committed
    result:=False;
end; {TransactionIsCommitted}

function TDB.TransactionIsRolledBack(CheckWt:StampId):boolean;
{Checks the committed array to see if this transaction is now rolled-back
 - used by transaction visibility checks

 Assumes:
   CheckWt>=tranCommittedOffset (else this routine can't help & should not be called)
   CheckWt<>self.Rt.tranId (else this routine should not be called)

 Note: this routine should be thread-safe without the need for latches
       because we only add partially committed lists before setting the flag bit
}
const routine=':TransactionIsRolledBack';
var
  tranStatus:TtranStatusPtr;
  stmtStatus:TstmtStatusPtr;
begin
  {$IFDEF SAFETY}
  {If the tran was before this db session started, then we can't know it's state}
  if CheckWt.tranId<tranCommittedOffset then
  begin
    result:=False;
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%d cannot be in the committed array which started at %d',[CheckWt.tranId,tranCommittedOffset]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  if tranPartiallyCommitted[CheckWt.tranId-tranCommittedOffset]=True then
  begin
    if tranCommitted[CheckWt.tranId-tranCommittedOffset]=True then
    begin
      result:=True; //default (so if tranPartiallyCommitted but can't find tranPartiallyCommittedDetails = assume the worst = safe) //should really give debugError!
      tranStatus:=tranPartiallyCommittedDetails;
      while tranStatus<>nil do
      begin
        if tranStatus.tid.tranId=CheckWt.tranId then
        begin
          result:=False; //default
          begin //this has been part-rolled-back, so check if the stmt was rolled-back or not
            {Quick check to see if stmtId was rolled-back} //note: only useful in future when we don't write full rollback list -for now we'll keep the algorithm simple
            if CheckWt.stmtId>tranStatus.tid.stmtId then
            begin
              result:=True;
              break; //stmtId is > original tran Rt so it was never advanced by being committed => rolled-back (done to save list space/time)
            end;
            stmtStatus:=tranStatus.rolledBackStmtList;
            while stmtStatus<>nil do
            begin
              if stmtStatus.tid.stmtId=CheckWt.stmtId then
              begin
                result:=True;
                break; //found in part-rolled-back stmt list, so done searching
              end;
              stmtStatus:=stmtStatus.next;
            end; {while}
            break; //not found in part-rolled-back stmt list, so default=False was correct & done searching
          end;
        end;
        tranStatus:=tranStatus.next;
      end; {while}
    end
    else //totally rolled-back
      result:=True;
  end
  else //not rolled-back (active or totally committed)
    result:=False;
end; {TransactionIsRolledBack}

function TDB.TransactionIsActive(CheckWt:StampId):boolean;
{Checks the committed array to see if this transaction is still active
 - used by transaction updateability checks

 Assumes:
   CheckWt>=tranCommittedOffset (else this routine can't help & should not be called)
   CheckWt<>self.Rt.tranId (else this routine should not be called)

 Note: this routine should be thread-safe without the need for latches
       because we only add partially committed lists before setting the flag bit
}
const routine=':TransactionIsActive';
begin
  {$IFDEF SAFETY}
  {If the tran was before this db session started, then we can't know it's state}
  if CheckWt.tranId<tranCommittedOffset then
  begin
    result:=False;
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%d cannot be in the committed array which started at %d',[CheckWt.tranId,tranCommittedOffset]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  result:=False; //default
  if tranPartiallyCommitted[CheckWt.tranId-tranCommittedOffset]=False then
    if tranCommitted[CheckWt.tranId-tranCommittedOffset]=False then
      result:=True;
end; {TransactionIsActive}

function TDB.debugDump(st:Tstmt;connection:TIdTCPConnection;summary:boolean):integer;
const routine=':debugDump';
var
  dirpage:TPage;
  dirEntry:TdbDirEntry;
  i:integer;  //dir-slot

  mapPage:TPage;
  map:cardinal;
  dirPageOffset:integer;
  nextDirPage:PageId;

  foundGap:boolean;
  tryInteger:cardinal;
  mapData:cardinal;
  dirPid:PageId;
begin
  result:=ok;

  if connection<>nil then
  begin
    connection.Writeln('Catalog: '+dbName);
    connection.Writeln('File: '+fname);
    connection.Writeln(format('Structure version: %d.%d',[dbheader.structureVersionMajor,dbheader.structureVersionMinor]));
    connection.Writeln(format('Disk block size: %d',[dbheader.DiskBlocksize]));

    with (owner as TDBserver) do
    begin
      connection.Writeln('Directory page: '+intToStr(dbheader.dbdir));
      {Copied from DirStatus}
      if buffer.pinPage(st,dbheader.dbdir,dirpage)<>ok then exit;  //get pointer
      try
        i:=0;
        while ((i+1)*sizeof(DirEntry))<sizeof(dirpage.block.data) do
        begin
          dirpage.AsBlock(st,i*sizeof(DirEntry),sizeof(dirEntry),@dirEntry);
          if dirEntry.filename<>'' then
            connection.Writeln(format(' %3d: Filename=%10s, Start page=%4d',[i,dirEntry.filename,dirEntry.startPage]));
          inc(i);
        end;
      finally
        buffer.unPinPage(st,dbheader.dbdir);
      end; {try}

      if not summary then
      begin
        {Show page allocations}
        connection.Writeln;
        connection.Writeln('Allocation map page: '+intToStr(dbheader.dbmap));
        dirPid:=dbHeader.dbMap;
        dirPageOffset:=0;

        tryInteger:=0;
        if buffer.pinPage(st,dirPid,mapPage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading page map from page %d',[dirPid]),vError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort //todo try to do something more useful else we might grind to a halt!?
        end;
        try
          while True do
          begin
            mapData:=mapPage.AsCardinal(st,tryInteger);
            connection.Write(format('%8.8x',[mapData])); //todo: 8=sizeof(integer)*2
            begin
              tryInteger:=tryInteger+sizeof(Integer);
              if tryInteger=BlockSize then
              begin
                connection.Writeln;
                connection.Writeln(format('Next map page %d',[mapPage.block.nextPage]));
                if mapPage.block.nextPage=InvalidPageId then
                begin
                  break; //quit scan
                end;
                dirPid:=mapPage.block.nextPage; //move to next page
                tryInteger:=0; //start of new page
                inc(dirPageOffset);

                buffer.unpinPage(st,mapPage.block.thisPage);
                if buffer.pinPage(st,dirPid,mapPage)<>ok then exit;
              end;
            end;
          end; {while}
        finally
          buffer.unpinPage(st,dirPid);
        end; {try}
        connection.Writeln;
      end;

    end; {with}

  end;
end; {debugDump}


end.

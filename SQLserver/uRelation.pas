unit uRelation;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Links a tuple with a db file
 plus any indexes
}

//{$DEFINE DEBUGDETAIL} //detailed debug log
//{$DEFINE DEBUGDETAIL2} //detailed debug log
//{$DEFINE DEBUGDETAIL3} //detailed debug log (searched scanning)
//{$DEFINE DEBUGDETAIL4} //detailed debug log (searched scanning without index, e.g. db startup)
//{$DEFINE DEBUGDETAIL5} //debug log summary
//{$DEFINE DEBUGDETAIL6} //summary of final optimisation paths
//{$DEFINE DEBUGDETAIL7} //detail of index opening
{$DEFINE DEBUGDETAIL8} //detail of index rebuilding
{$DEFINE DEBUGDETAIL9} //detail of garbage collecting
{$DEFINE DEBUGDETAIL10} //summary of failed (i.e. full scan) final optimisation paths (leave defined to spot problems!)

//{$DEFINE SKIP_INDEXES}   //turn off relation index opening - debug only - remove when live!
//{$DEFINE SKIP_INDEXES2}    //turn off relation index searching - debug only - remove when live!

interface

uses uTuple, uFile, uIndexFile, uStmt, uGlobal,
     IdTCPConnection{debug only}, uSyntax{for catalog.schema finding from node};

type
  TIndexListPtr=^TIndexList;
  TIndexList=record
    index:TIndexFile;
    next:TIndexListPtr;
  end; {TIndexList}

  TConstraintListPtr=^TConstraintList;
  TConstraintList=record
    constraintId:integer;
    constraintType:TconstraintRuleType;
    parentTableId:integer;
    {Note: subscript starts at 1 to mirror disk storage of constraint column_sequence & since UnusedId=0}
    childColsCount:integer;
    childCols:array [1..MaxCol] of TColId;
    parentColsCount:integer;
    parentCols:array [1..MaxCol] of TColId;
    next:TConstraintListPtr;
  end; {TConstraintList}

  TRelation=class
    private
      fname:string;           //filename
      fCatalogName:string;    //catalog name
      fSchemaName:string;     //schema name
      fdbFile:TDBFile;        //generic filetype - could be Heap, or Btree etc.
      fAuthId:TAuthId;        //auth_id of schema owner (at time of opening, although can it change?)
      fCatalogId:integer;     //catalog_id in system catalog
      fSchemaId:integer;      //schema_id in system catalog (originally used for GRANT adding privilege rows)
      fTableId:integer;       //table_id (could be for view) in system catalog (originally used for GRANT adding privilege rows)
      fIndexList:TIndexListPtr; //index list
      fCurrentIndex:TIndexListPtr; //current index, nil=scan
      fConstraintList:TConstraintListPtr; //constraint definition list (nothing to do with checking, just optimisation)
      fNextColId:integer;     //next col id to be used (also used as maximum possible column id for matching etc.)
      function fScanInProgress:boolean;
      function linkNewConstraint(st:TStmt;table_id:integer;constraint_id:integer):integer;
      function LoadConstraints(st:TStmt;table_id:integer):integer; //called by openIndexes
    public
      fTuple:TTuple;
      fTupleKey:TTuple;       //key data used for searched scans (finds)
      property relname:string read fname;   //reference from Processor (etc?)
      property catalogName:string read fcatalogName; //reference from Processor (etc?)
      property schemaName:string read fschemaName;   //reference from Processor (etc?)
      property dbFile:TDBfile read fdbfile; //(need access from tuple)
      property authId:TAuthId read fAuthId;
      property schemaId:integer read fSchemaId;
      property tableId:integer read fTableId;
      property indexList:TIndexListPtr read fIndexList; //currently used by fTuple methods
      property scanInProgress:boolean read fScanInProgress;
      property constraintList:TConstraintListPtr read fConstraintList; //used by optimiser
      property NextColId:integer read fNextColId write fNextColId; //updated externally by create table (may need to be maintained elsewhere? e.g. setColDef?)
                                                                   //Note: when we allow columns to be added/removed we must protect this db-wide but we don't have a generator...
                                                                   //      and we must maintain it because it's needed for internal matches etc.

      constructor Create;
      destructor Destroy; override;
      function Open(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;var viewDef:boolean;var viewDefinition:string):integer;
      function CreateNew(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;ViewDef:boolean;const viewOrFilename:string):integer;
      function Close:integer;
      function ScanStart(st:TStmt):integer;
      function ScanNext(st:TStmt;var noMore:boolean):integer;
      function ScanNextGarbageCollect(st:TStmt;var noMore:boolean;readFirst:boolean):integer;
      function ScanNextToIndex(st:TStmt;var noMore:boolean;iFile:TIndexFile):integer;
      function ScanStop(st:TStmt):integer;

      function FindScanStart(st:TStmt;FindData:TTuple):integer;
      function FindScanNext(st:TStmt;var noMore:boolean):integer;
      function FindScanStop(st:TStmt):integer;

      function isUnique(st:TStmt;FindData:TTuple;var res:TriLogic):integer;

      function CreateNewIndex(st:TStmt;iFile:TIndexFile;const indexName:string):integer;
      function LinkNewIndex(st:TStmt;iIndex_id:integer;iIndexType:string;iIndexOrigin:string;iIndexConstraintId:integer;iFilename:string;iStartpage:PageId;iStatus:TindexState):TIndexFile;
      function OpenIndexes(st:TStmt;table_id:integer):integer;
      function ScanAlltoIndex(st:TStmt;iFile:TIndexFile):integer;

      function EstimateSize(st:TStmt):integer;

      function debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
  end; {TRelation}

  TRelationListPtr=^TRelationList;

  TRelationList=record
    r:TRelation;
    next:TRelationListPtr;
  end; {TRelationList}

  function getOwnerDetails(st:TStmt;find_node:TSyntaxNodePtr;find_schema_name:string;default_schema_name:string;
                         var catalog_Id:TCatalogId;var catalog_name:string;var schema_Id:TSchemaId;var schema_name:string;var auth_Id:TAuthID):integer;

var
  //todo remove these -or at least make private
  debugRelationCreate:integer=0;   
  debugRelationDestroy:integer=0;
  debugRelationIndexCreate:integer=0;
  debugRelationIndexDestroy:integer=0;
  debugRelationConstraintCreate:integer=0;
  debugRelationConstraintDestroy:integer=0;

implementation

uses uLog, uTransaction, uHeapFile, uVirtualFile, uServer, sysUtils, uPage, uGlobalDef,
 uEvalCondExpr {for matchTuples - todo:belongs in uTuple really...},
 uHashIndexFile;

const
  where='uRelation';
  who='';
  CatalogMutexWait=5000;   //milliseconds to wait for catalog mutex when trying single access to scan sysTable/sysColumn
                           //- currently used by Open routine (may be replaced by catalog per transaction or non-scan)

constructor TRelation.create;
begin
  {Create this relation's tuple definition}
inherited Create;
  inc(debugRelationCreate);
  {$IFDEF DEBUG_LOG}
  if debugRelationCreate=1 then
    log.add(who,where,format('  Relation memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}
  fTuple:=TTuple.Create(self);
  fTupleKey:=TTuple.Create(self);
  //todo fTupleKey.clearKeyIds? and on re-open... only in case we combine scan and findscan soon...
  fIndexList:=nil;
  fCurrentIndex:=nil;
  fNextColId:=0; //currently maintained by relation.open and processor createTable
end; {Create}
destructor TRelation.Destroy;
const routine=':destroy';
begin
  {Destroy tuple}
//  scanStop(nil); //added 29/06/99 to clean up algebra linked relations (pages were left pinned, e.g. IterInsert)
//  fTuple.unpin;  //""

  fTupleKey.free;
  fTuple.free;
  if assigned(fdbfile) then //not released by close routine: error & check why?
    Close; 

  if fIndexList<>nil then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Relation still has index(es) open',[fname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}

  if fConstraintList<>nil then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Relation still has constraint(s) open',[fname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}

  inc(debugRelationDestroy); //todo remove

  inherited destroy;
end; {Destroy}

function getOwnerDetails(st:TStmt;find_node:TSyntaxNodePtr;find_schema_name:string;default_schema_name:string;
                         var catalog_Id:TCatalogId;var catalog_name:string;var schema_Id:TSchemaId;var schema_name:string;var auth_Id:TAuthID):integer;
{Find the catalog/schema/owner details from the specified syntax node (or schema_name)
 IN       :  st                    the statement
          :  find_node             the ntSchema node to search for
          :  find_schema name      the schema name to search for (if node=nil): Note: will be phased out!
          :  default_schema_name   todo!
 OUT:
          :  catalog_Id            catalog id
          :  catalog_name          catalog name         //note: currently returns database default
          :  schema_Id             schema id
          :  schema_name           schema name
          :  auth_Id               schema owner authId

 RETURN   :  +ve=ok
             -2 = catalog not found
             -3 = schema not found
             else fail

 Notes:
  this has been added to provide a standard way to access owner information -
  adding future things such as multiple catalog references should be much easier if everything
  goes through this.

  This is used to find routine owner as well...
  and sequence owner...
  and user default schema (alter)
  - so if it's not related to Trelation we should consider moving it...
}
const
  routine=':getOwnerDetails';
  noCatalog=-2;
  noSchema=-3;
var
  sysSchemaR:TObject; //Trelation
  dummy_null:boolean;

  tempi:integer;
  find_catalog_name:string;
begin
  result:=fail;

  if find_node<>nil then
  begin
    //todo: assert find_schema_name=''

    //find find_schema_name from syntax tree
    if find_node.nType=ntSchema then
      find_schema_name:=find_node.rightChild.idVal;

    //now find the catalog name & look it up (unless=tr.catalogId, in which case use it)
    if find_node.leftChild<>nil then
    begin
      find_catalog_name:=find_node.leftChild.rightChild.idVal;
      if find_catalog_name<>Ttransaction(st.owner).catalogName then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Invalid catalog specified %s to find %s',[find_catalog_name,find_schema_name]),vDebugError); 
        {$ENDIF}
        result:=noCatalog;
        exit; //fail
      end;
    end;
    //else no catalog specified so use current...
  end;
  //todo else warning: deprecated call!

  {Use the specified default if no other has been given, e.g. from tr.schemaName}
  //todo maybe we can remove the default parameter & always use tr.schemaName?
  if find_schema_name='' then find_schema_name:=default_schema_name;

  if find_schema_name=sysCatalogDefinitionSchemaName then
  begin
    //we only *need* to assume this before sysSchema is open (currently if db.open is opening sysTable or sysColumn)
    // but it's faster anyway to always assume it (although the relations are only opened once per db)
    schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation algorithm
    schema_name:=sysCatalogDefinitionSchemaName; //needed here?
    //if a user (or internal user via SQL?) references the system catalog tables
    // they need to do permission checks & so we need to set relation auth_id to allow owner-rights-check
    // - I think this is only needed if we connect as '_SYSTEM' for debugging only so remove? but may as well leave in or set to InvalidAuthId at least!
    auth_Id:=SYSTEM_AUTHID; //_SYSTEM
    {The following are both per catalog and so we should never use them here,
     but better to have something for the moment?}
    catalog_Id:=1;
    catalog_name:=Ttransaction(st.owner).db.dbName;

    result:=ok;
  end
  else
  begin
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysSchema,sysSchemaR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysSchemaR,ord(ss_schema_name),find_schema_name)=ok then
        begin
          with (sysSchemaR as TRelation) do
          begin
            fTuple.GetInteger(ord(ss_catalog_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
            catalog_Id:=tempi;
            fTuple.GetInteger(ord(ss_auth_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
            auth_Id:=tempi;
            fTuple.GetInteger(ord(ss_schema_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
            schema_Id:=tempi;
            fTuple.GetString(ord(ss_schema_name),schema_name,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
            //todo major/minor versions

            catalog_name:=Ttransaction(st.owner).db.dbName; //todo get actual one! or at least assert =catalog_Id=1!

            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found schema %s (%d) owner=%d',[schema_name,schema_Id,auth_Id]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end; {with}
          result:=ok;
        end
        else
        begin  //schema not found
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown schema %s',[find_schema_name]),vError);
          {$ENDIF}
          result:=noSchema;
          exit; //abort
        end;
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysSchema,sysSchemaR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysSchema
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
  end;
end; {getOwnerDetails}



function TRelation.Open(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;var viewDef:boolean;var viewDefinition:string):integer;
{Link the relation to a db file, or just defines the tuple if it's a view
 IN       :  st           the statement
          :  find_node    the ntSchema node to search for
          :  schema name  the schema name in case find_node is nil //will be phased out
                                  //although may always need for bootstrap & GC etc.
          //todo pass catalog and schema names
          :  name         the relation name (view or base_table)
 OUT:
          :  viewDef          False=base-table, True=view-definition (i.e. no dbFile)
          :  viewDefinition   if viewDef then the view definition

 RETURN   :  +ve=ok
                +2=failed opening an index, but main file opened ok, so caller can still continue
                   but in this case caller should give a warning or rebuild indexes or something!
             -2=catalog not found
             -3=schema not found
             else fail


 Side-effects
   Creates fdbFile instance
   Initialises tuple definition if required (i.e. if not sysTable)
   Copies the tuple definition to the tupleKey definition for searched-scans etc.
   Opens all assocated indexes and creates index pointers and links them to this relation (freed/deleted on Close)

 Notes
   The view open was piggybacked onto this routine because it's very similar to
   the opening of a table, although Trelation is not used for handling the view
   at any other time (except definition), so maybe they should both call a common 'get table/columns'
   routine, but be separate so we don't have to create a dummy relation to open a view?
}
const
  routine=':Open';

  {Warning results}
  failedOpeningIndex=+2;
var
  filename:string;
  crippledStartPage:integer;
  bigStartPage:int64;
  startPage:PageId;
  s:string;
  n:integer;
  catalog_Id:TcatalogId;
  schema_Id:TschemaId; //schema id of name passed into routine (schemaId is Tr's)
  tempi:integer;
  catalog_name:string;
  table_auth_id:TauthId; //auth_id of table schema owner => table owner
  table_schema_Id:integer; //schema id of current lookup loop table
  table_table_Id:integer;
  tableType:string;
  table_nextColId:integer;

  needToFindTableOwner:boolean;

  filename_null,startPage_null,s_null,n_null,table_table_Id_null,dummy_null:boolean;
  tableType_null,viewDefinition_null,table_nextColId_null:boolean;
  i:ColRef;
  tempResult:integer;

  sysTableR, sysColumnR, sysSchemaR:TObject; //Trelation   //maybe able to share some as common lookupR? any point?
begin
  result:=Fail;
  if assigned(fdbfile) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Table %s is already open',[fname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  table_table_Id:=0; table_table_Id_null:=true;
  needToFindTableOwner:=False;

  {Find the filename, start-page and the tuple definition}
  if name=sysTable_file then {this is the only time before sysTable is open}
  begin
    filename:=name; filename_null:=false;
    {Get start page from db dir}
    startPage_null:=False;
    if Ttransaction(st.owner).db.getFile(st,filename,startPage)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed finding start page for %s',[filename]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      result:=Fail;
      exit;
    end;
    //we will use the name as it is, i.e. as a raw filename
    //So this is the only file that needs to be in the db file directory

    {No need to read column details - they are fixed already}

    {Copy the tuple structure to the tupleKey for use in searched-scans etc.}
    self.fTupleKey.CopyTupleDef(self.fTuple);

    fAuthId:=SYSTEM_AUTHID; //=> _SYSTEM 
    fCatalogId:=1;
    fCatalogName:=Ttransaction(st.owner).db.dbName;
    fSchemaId:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation algorithm //store for later reference
    fSchemaName:=sysCatalogDefinitionSchemaName;
    //Note: this next one is needed for manual index opening during dbOpen
    fTableId:=1; //assumed based on catalog creation algorithm - todo use constant //store for later reference
  end
  else
  begin
    {Find the relation in sysSchema/sysTable}
    //todo use future indexed relation.Find() method}
    //Note: we don't use sysColumn as we should but we directly access sysTable columns
    // - this is bad or good? (rules out system metadata updates via versioning... so!)
    // - but then we may be opening sysColumn now!...
          //see notes in Tdb about how we should read the sysColumn definition from the sysColumn table
          //  and at least assert it's =sysColumnR or even better, ignore sysColumnR & use disk structure
    filename:=''; filename_null:=true;
    viewDef:=False; //so we error properly if we don't find the table or view

    {first, find the schema id for this table} //todo check if this is ok if this is the sysSchema table?
    if (find_node=nil){added 16/09/02 for backup bootstrap} and (schema_name=sysCatalogDefinitionSchemaName) then
    begin
      //we only *need* to assume this before sysSchema is open (currently if db.open is opening sysTable or sysColumn)
      // but it's faster anyway to always assume it (although the relations are only opened once per db)
      fCatalogId:=1; 
      fCatalogName:=Ttransaction(st.owner).db.dbName; 
      schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation algorithm
      fSchemaName:=sysCatalogDefinitionSchemaName; 
      //if a user (or internal user via SQL?) references the system catalog tables
      // they need to do permission checks & so we need to set relation auth_id to allow owner-rights-check
      // - I think this is only needed if we connect as '_SYSTEM' for debugging only so remove? but may as well leave in or set to InvalidAuthId at least!
      table_auth_id:=1; //todo use constant for _SYSTEM
    end
    else
    begin
      begin
        tempResult:=getOwnerDetails(st,find_node,schema_name,Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,table_auth_Id);
        if tempResult<>ok then
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugError);
          {$ENDIF}
          result:=tempResult;
          exit; //abort
        end;
      end;
    end;

    {Now lookup relation in sysTable and get the filename & startpage, unless it's a view}
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysTable,sysTableR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysTableR,ord(st_table_name),name)=ok then
          try
            repeat
              {Found another matching table - is it for this schema?}
              with (sysTableR as TRelation) do
              begin
                fTuple.GetInteger(ord(st_Schema_id),table_schema_id,dummy_null);  //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                if table_schema_id=schema_Id then
                begin
                  fTuple.GetString(ord(st_file),filename,filename_null);
                  fTuple.GetBigInt(ord(st_first_page),bigStartPage,startPage_null);
                  StartPage:=bigStartPage;
                  fTuple.GetInteger(ord(st_table_id),table_Table_Id,table_table_Id_null);
                  fTuple.GetString(ord(st_Table_Type),tableType,tableType_null);
                  fTuple.GetString(ord(st_View_definition),viewDefinition,viewDefinition_null);
                  if tableType=ttView then viewDef:=True {no real need for else}else viewDef:=False; //return flag to caller
                  //todo assert not (tableType=ttView and viewDefinition_null) ! else what?
                  fTuple.GetInteger(ord(st_Next_Col_id),table_nextColId,table_nextColId_null);
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Found relation %s in %s with file=%s, id=%d and start page=%d, type=%s, viewDef=%s, nextColId=%d',[name,sysTable_table,filename,table_table_Id,startPage,tableType,viewDefinition,table_nextColId]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                end;
                //else not for our schema - skip & continue looking
              end; {with}
            until (table_table_Id<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysTableR,ord(st_table_name),name)<>ok);
                  //todo stop once we've found a table_id with our schema_Id, or there are no more matching this name
          finally
            if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysTableR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTable)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        //else table not found
      //todo move this finally till after we've read the columns,
      // else someone could drop the table & we'd fail - or would we? sysCatalog info is versioned! so we'd probably be ok!!!!!
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysTable,sysTableR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTable)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysTable
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysTable)]),vDebugError); 
      {$ELSE}
      ;
      {$ENDIF}
    end;

    if table_table_Id<>0 then
    begin
      {Now we've found the table, if we didn't look up the schema details already, do it now}
      //note: this can be removed I think since needToFindTableOwner is no longer set True
      //- although may be needed for SQL99 because table-owners could be other than schema owner...
      if needToFindTableOwner and (name<>sysColumn_table) then
      begin
        if Ttransaction(st.owner).db.catalogRelationStart(st,sysSchema,sysSchemaR)=ok then
        begin
          try
            if Ttransaction(st.owner).db.findCatalogEntryByInteger(st,sysSchemaR,ord(ss_schema_id),table_schema_id)=ok then
            begin
              with (sysSchemaR as TRelation) do
              begin
                fTuple.GetInteger(ord(ss_schema_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                schema_Id:=tempi;
                fTuple.GetInteger(ord(ss_auth_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                table_auth_Id:=tempi;
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found schema %s (%d) owner=%d (from table)',[schema_name,schema_Id,table_auth_id]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
              end; {with}
            end
            else
            begin  //schema not found
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed finding table schema details %d',[table_schema_id]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit; //abort
            end;
          finally
            if Ttransaction(st.owner).db.catalogRelationStop(st,sysSchema,sysSchemaR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        end
        else
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;
      end;


      fAuthId:=table_auth_Id; //store for later reference
      fSchemaId:=table_schema_id; //store for later reference
      fTableId:=table_table_Id; //store for later reference
      fNextColId:=table_nextColId; //store for later reference
      {Now load the tuple definition for the relation/view}
      if Ttransaction(st.owner).db.catalogRelationStart(st,sysColumn,sysColumnR)=ok then
      begin
        try
          if name<>sysColumn_table then  //remove? may as well re-read - may have benefits (if db created by prior version)? clean? NO:- BAD to change while using tuple to read tuple!!!!
          begin
            //todo use future relation.Find() method}
            fTuple.ColCount:=0; //Note: I think this is the only place we set this to 0 - else we could assert<>0 in uTuple.SetColCount...

            if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysColumnR,ord(sc_table_id),table_table_Id)=ok then
              try
                repeat
                  {Found another matching column for this relation}
                  with (sysColumnR as TRelation) do
                  begin
                    {Set source}
                    //Note: (self.)fAuthId etc. are masked by 'with sysColumnR'!
                    self.fTuple.fColDef[self.fTuple.colCount].sourceAuthId:=table_auth_Id;
                    self.fTuple.fColDef[self.fTuple.colCount].sourceTableId:=table_table_Id;

                    fTuple.GetInteger(ord(sc_column_id),n,n_null); //assume never null
                    self.fTuple.fColDef[self.fTuple.colCount].id:=n;
                    {$IFDEF DEBUG_LOG}
                    if (n>=self.nextColId) and not viewDef then
                      log.add(st.who,where+routine,format('Column id (%d) is not less than nextColId (%d)',[n,self.nextColId]),vAssertion);
                    {$ENDIF}

                    fTuple.GetString(ord(sc_column_name),s,s_null); //assume never null
                    self.fTuple.fColDef[self.fTuple.colCount].name:=s;

                    //I think the caller only needs the column names for
                    //      a view, so we might be able to skip the rest if ViewDef? -speed, but not as safe...

                    fTuple.GetInteger(ord(sc_domain_id),n,n_null); //todo check domain_id? assume never null
                    self.fTuple.fColDef[self.fTuple.colCount].domainId:=n;

                    fTuple.GetInteger(ord(sc_datatype),n,n_null); //todo cross-ref domain id? assume never null
                    //todo assert ord(first)<=n<=ord(last)
                    self.fTuple.fColDef[self.fTuple.colCount].dataType:=TDataType(n);
                    fTuple.GetInteger(ord(sc_width),n,n_null); //assume never null
                    self.fTuple.fColDef[self.fTuple.colCount].width:=n;
                    fTuple.GetInteger(ord(sc_scale),n,n_null); //assume never null
                    self.fTuple.fColDef[self.fTuple.colCount].scale:=n;

                    fTuple.GetString(ord(uGlobal.sc_default),s,s_null);
                    if not s_null then self.fTuple.fColDef[self.fTuple.colCount].defaultVal:=s;
                    self.fTuple.fColDef[self.fTuple.colCount].defaultNull:=s_null;
                    //todo check that these ^ are cleared since we don't always blank them

                    //todo & rest of col definition
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Found column %s in %s with id=%d',[self.fTuple.fColDef[self.fTuple.colCount].name,sysColumn_table,self.fTuple.fColDef[self.fTuple.colCount].id]),vDebugLow);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    {$ENDIF}
                    self.fTuple.ColCount:=self.fTuple.ColCount+1; //add this column
                  end; {with}
                until Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysColumnR,ord(sc_table_id),table_table_Id)<>ok;
                      //todo stop once we're past our table_id if sysColumn is sorted... -speed - this logic should be in Find routines...
              finally
                if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysColumnR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysColumn)]),vError); 
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}
            //else table has no columns = assertion?
          end
          else
          begin
            //todo remove need for following? (only required for reflexive reference from user - db users sysColumn):
            {Artificially set parameters for hard-coded relation - taken from Database.sysColumn relation}
            //Note: no real need to have gained safe access, since we're just reading the structure - speed
            //      - but we did need to get some reference to the sysColumn relation
            self.fTuple.CopyTupleDef((sysColumnR as TRelation).fTuple);

            {We need to set the source details for any permission checking later}
            for i:=0 to self.fTuple.colCount-1 do
            begin
              {Set source}
              self.fTuple.fColDef[i].sourceAuthId:=table_auth_Id;
              self.fTuple.fColDef[i].sourceTableId:=table_table_Id;
            end;

            //todo see notes in Tdb about how we should read the sysColumn definition from the sysColumn table
            //  and at least assert it's =sysColumnR or even better, ignore sysColumnR & use disk structure
          end;

        finally
          if Ttransaction(st.owner).db.catalogRelationStop(st,sysColumn,sysColumnR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysColumn)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysColumn
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysColumn)]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}
      end;

      {Now ensure our column definitions are in Id order, because the heapfile scan doesn't guarantee this}
      self.fTuple.OrderColDef;           //may not be needed in rare case when name=sysColumn_table, since we just copied from a tuple def - (slight) speed?
      //todo check result!

      {Copy the tuple structure to the tupleKey for use in searched-scans etc.}
      self.fTupleKey.CopyTupleDef(self.fTuple);
    end;
    //else table name not found (for this schema)
  end;

  if not filename_null and (filename<>'') then
  begin
    {Okay, we have the filename & start-Page, now create it & open it}
    if (uppercase(name)=uppercase(sysTransaction_table))
    or (uppercase(name)=uppercase(sysServer_table))
    or (uppercase(name)=uppercase(sysStatusGroup_table))
    or (uppercase(name)=uppercase(sysStatus_table))
    or (uppercase(name)=uppercase(sysServerStatus_table))
    or (uppercase(name)=uppercase(sysCatalog_table))
    or (uppercase(name)=uppercase(sysServerCatalog_table))
    then
      fdbfile:=TVirtualFile.create(fTuple)
    else
      fdbfile:=THeapFile.create;

    if startPage_null or (fdbfile.openFile(st,filename,startPage)<>ok) then  {short-circuit}
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed opening file %s',[filename]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      exit;
    end;
    fname:=name;
    fCatalogName:=catalog_name;
    fSchemaName:=schema_name;
    //todo set ..ids as well?
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation %s %s opened',[schema_name,name]),vDebugMedium);
    log.add(st.who,where+routine,self.ftuple.showHeading,vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    result:=ok;

    {Now open and link all associated indexes}
    //Note: currently if any of these fail, we return +ve, i.e. warning - caller can still limp along = more resiliant?
    //todo: ensure all callers handle such a return value properly
    if name=sysTable_file then {this is the only time before sysColumn is open}
    begin
      //todo open sysTable index(es) by hand...
      // (not needed for internal use of sysTable - its indexes are opened when available by dbOpen)
    end
    else
    begin
      {$IFNDEF SKIP_INDEXES}
      if OpenIndexes(st,table_table_Id)<>ok then
      begin
        //todo reinstate once callers can handle +ve result: result:=failedOpeningIndex;
        {leave result=ok};
      end;
      {$ENDIF}
    end;
  end
  else
  begin
    if not viewDef then
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Relation %s %s not found',[schema_name,name]),vError) //todo remove error: ok if called by createNew!
      {$ENDIF}
      {$ENDIF}
    else
      result:=ok; //no problem if we're a view (flag => we found it)- we don't actually open the relation
                  //in fact (currently) the caller will delete the relation once its looked at the colDefs
  end;
end; {Open}

function TRelation.linkNewConstraint(st:TStmt;table_id:integer;constraint_id:integer):integer;
{Create a constraint record for the specified constraint, find the details, and link it into this relation's constraint chain
 IN:       tr                   transaction context
           table_id             the table id
           constraint_id        the constraint id

 RETURNS:  ok
           -2 = constraint not applicable: caller should continue
           else fail

 Note:
   the relation will be responsible for freeing the created constraint record when it closes
}
const routine=':linkNewConstraint';
var
  constraintPtr:TConstraintListPtr;
  sysConstraintR:TObject; //Trelation
  sysConstraintColumnR:TObject; //Trelation
  dummy_integer:integer;
  dummy_null:boolean;
  dummy_string:string;
  i:integer;
begin
  result:=fail;

  {Add this to our constraint list - we are now responsible for its removal}
  new(constraintPtr);
  inc(debugRelationConstraintCreate);
  constraintPtr.constraintId:=0; //incomplete;
  constraintPtr.parentTableId:=0; //incomplete
  //constraintPtr.constraintType:=; //incomplete
  constraintPtr.childColsCount:=0;
  constraintPtr.parentColsCount:=0;
  constraintPtr.next:=self.fConstraintList;
  self.fConstraintList:=constraintPtr;

  {Now lookup and complete the details}
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraint,sysConstraintR)=ok then
  begin
    try
      if Ttransaction(st.owner).db.findCatalogEntryByInteger(st,sysConstraintR,ord(sco_constraint_id),constraint_id)=ok then
      begin
        with (sysConstraintR as TRelation) do
        begin
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Found constraint %d',[constraint_id]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          {Read the appropriate constraint details}
          fTuple.GetInteger(ord(sco_rule_type),dummy_integer,dummy_null); //moved before Tconstraint.create so if fails, no memory leak
          constraintPtr.constraintType:=TconstraintRuleType(dummy_integer); //todo protect cast from garbage!!!!!
          fTuple.GetInteger(ord(sco_FK_parent_table_id),constraintPtr.parentTableId,dummy_null); //0=not FK
          fTuple.GetInteger(ord(sco_FK_child_table_id),dummy_integer,dummy_null); //0=not FK
          if dummy_integer<>table_id then //this must be the parent's end of a FK
          begin //not applicable: leave constraint in chain as incomplete (contraintId=0) and exit now
            result:=-2;
            //todo dispose of our half-done constraint node before returning! memory!
            self.fConstraintList:=constraintPtr.next;
            dispose(constraintPtr);
            inc(debugRelationConstraintDestroy);
            exit; //abort: caller will continue with next candidate
          end;
          //todo assert FK_child_table_id=table_id : always?

          {Find constraint columns}
          //Note: based on Tconstraint.create
          if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraintColumn,sysConstraintColumnR)=ok then
          begin
            try
              //assumes we have best index/hash on scc_constraint_id, but may not be the case
              if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),constraint_Id)=ok then
                try
                  repeat
                    {Found another matching constraint column id}
                    with (sysConstraintColumnR as TRelation) do
                    begin
                      {Record child/parent column}
                      fTuple.GetString(ord(scc_parent_or_child_table),dummy_string,dummy_null);
                      //todo: assert if fRuleType<>rtForeignKey then parent_or_child_table<>ctParent
                      fTuple.GetInteger(ord(scc_column_sequence),i,dummy_null);
                      fTuple.GetInteger(ord(scc_column_id),dummy_integer,dummy_null);
                      if dummy_string=ctParent then
                      begin
                        constraintPtr.parentCols[i]:=dummy_integer;
                        {Note: we don't care if we read out of sequence but we assume the count & so assume no gaps}
                        if i>constraintPtr.parentColsCount then constraintPtr.parentColsCount:=i;
                      end
                      else
                      begin
                        constraintPtr.childCols[i]:=dummy_integer;
                        {Note: we don't care if we read out of sequence but we assume the count & so assume no gaps}
                        if i>constraintPtr.childColsCount then constraintPtr.childColsCount:=i;
                      end;
                    end; {with}
                  until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),constraint_Id)<>ok);
                        //todo stop when there are no more matching this id
                finally
                  if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysConstraintColumnR)<>ok then
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysConstraintColumn)]),vError); 
                    {$ELSE}
                    ;
                    {$ENDIF}
                end; {try}
              //else no constraint column(s) for this table found - todo assertion since such keys always have some! we do assert below
            finally
              if Ttransaction(st.owner).db.catalogRelationStop(st,sysConstraintColumn,sysConstraintColumnR)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysConstraintColumn)]),vError); 
                {$ELSE}
                ;
                {$ENDIF}
            end; {try}
          end
          else
          begin  //couldn't get access to sysConstraintColumn
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysConstraintColumn)]),vDebugError); 
            {$ELSE}
            ;
            {$ENDIF}
          end;
        end; {with}
      end
      else //constraint_id not found
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed finding constraint %d',[constraint_id]),vAssertion); 
        {$ENDIF}
        //todo? return resultErrCode etc.
        exit; //abort
      end;
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysConstraint,sysConstraintR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysConstraint)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
    result:=ok;
  end
  else
  begin  //couldn't get access to sysConstraint
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysConstraint)]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    //todo? return resultErrCode etc.
  end;

  {Finalise to make available}
  constraintPtr.constraintId:=constraint_id;

  {$IFDEF DEBUGDETAIL7}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Constraint %d added to relation list %s',[constraint_id,self.relname]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {linkNewConstraint}

function TRelation.LoadConstraints(st:TStmt;table_id:integer):integer;
{Loads constraint information for optimiser use

 Duplicates/summaries some code from uConstraint, but for different purposes

 Called from openIndexes
}
const routine=':loadConstraints';
var
  sysTableColumnConstraintR:TObject; //Trelation
  columnId,constraintId:integer;
  columnId_null,dummy_null:boolean;
begin
  result:=fail;

  if fConstraintList<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Table %s already has constraint(s) loaded',[nil]),vAssertion);
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;

  if Ttransaction(st.owner).db.catalogRelationStart(st,sysTableColumnConstraint,sysTableColumnConstraintR)=ok then
  begin
    try
      //assumes we have best index/hash on stc_table_id, but may not be the case
      //Note: would be better to also have table_id+column_id since we're looking for 0 column_ids here (speed)
      if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),table_Id)=ok then
        try
          repeat
            {Found another matching table id}
            with (sysTableColumnConstraintR as TRelation) do
            begin
              fTuple.GetInteger(ord(stc_column_id),columnId,columnId_null);
              begin //match found
                {Add the constraint}
                fTuple.GetInteger(ord(stc_constraint_id),constraintId,dummy_null);
                self{not sysTableColumnConstraintR!}.linkNewConstraint(st,table_id,constraintId);
              end;
            end; {with}
          until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),table_Id)<>ok); //note: duplicated above before Continues
                //todo stop when there are no more matching this id
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysTableColumnConstraintR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTableColumnConstraint)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else no constraint for this table found
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysTableColumnConstraint,sysTableColumnConstraintR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTableColumnConstraint)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
    result:=ok; //scan completed ok
  end
  else
  begin  //couldn't get access to sysTableColumnConstraint
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysTableColumnConstraint)]),vDebugError); 
    {$ELSE}
    ;
    {$ENDIF}
  end;
end; {LoadConstraints}


function TRelation.LinkNewIndex(st:TStmt;iIndex_id:integer;iIndexType:string;iIndexOrigin:string;iIndexConstraintId:integer;iFilename:string;iStartpage:PageId;iStatus:TindexState):TIndexFile;
{Create the an index file object for the existing index, open it, and link it into this relation's index chain
 IN:       tr                   transaction context
           iIndex_id            the catalog index_id
           iIndexType           e.g. itHash
           iIndexOrigin         e.g. ioSystem
           iIndexConstraintId   constraintId if iIndexOrigin=ioSystemConstraint, else 0=>null=n/a
           iFilename            catalog filename for the index
           iStartPage           catalog startpage
           iStatus              catalog status

 RETURNS:  TIndexFile or nil=fail

 Note:
   the relation will be responsible for freeing the created index when it closes
}
const routine=':linkNewIndex';
var
  iNew:TIndexFile;
  indexPtr:TIndexListPtr;
begin
  result:=nil;

  iNew:=nil;
  if iIndexType=itHash then iNew:=THashIndexFile.Create;
  //todo in future create other index types...
  if iNew=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unknown index type %s',[iIndexType]),vAssertion); 
    {$ENDIF}
    exit; //abort
  end; {case}

  {Open and link the index file to this relation} //todo maybe put this in a separate routine? ++especially now it's needed by uProcessor.createIndex routine
  iNew.Owner:=self;
  iNew.indexId:=iIndex_id;
  iNew.indexOrigin:=iIndexOrigin;
  iNew.indexConstraintId:=iIndexConstraintId;
  //record index_name as well? no-need, filename will be kept at file level
  iNew.indexState:=iStatus;
  if iNew.openFile(st,iFilename,iStartPage)<>ok then
  begin
    iNew.free; iNew:=nil; //else will be freed by (self)relation.close
    exit; //abort
  end;
  {Add this to our index list - we are now responsible for its removal}
  //todo: must protect this list now that indexes can be linked by other threads!!!
  new(indexPtr);
  inc(debugRelationIndexCreate);
  indexPtr.index:=iNew;
  indexPtr.next:=self.fIndexList;
  self.fIndexList:=indexPtr;

  result:=iNew;
  {$IFDEF DEBUGDETAIL7}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Index %s added to relation list %s',[iFilename,self.relname]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {LinkNewIndex}

function TRelation.OpenIndexes(st:TStmt;table_id:integer):integer;
{Open all indexes associated with this table_id
 IN       :  st           the statement
             table_id     the table_id to open indexes for

 RESULT:     ok, else fail

 Side-effects:
   Copies the relation's tuple definition to the tupleKey definition for indexed-scans etc.
   Calls LoadConstraints

 Assumes:
   fTuple has been defined - needed to find cRef's from cids stored in sys catalog
                                       and to copy definition to index key-data store

   system catalog tables for indexes are open
   system catalog tables for constraints are open (for LoadConstraints)

 Notes:
   this is called to open indexes for the system catalog tables

   the index list this routine creates might be added to later if someone adds/rebuilds
   and index on this table_id. This is to make sure all modifiers add to all indexes, even
   if they are still partial (isBeingBuilt) indexes.

   To make sure we use all partially built indexes immediately (to be able to maintain them)
   we read the index catalog relation with readUncommited visibilty
}
const routine=':openIndexes';
var
  filename:string;
  crippledStartPage:integer;
  bigStartPage:int64;
  startPage:PageId;
  status:integer;
  s:string;
  n:integer;
  schema_Id:integer; //schema id of name passed into routine (schemaId is Tr's)
  table_auth_id:integer; //auth_id of table schema owner => table owner
  index_Id,indexConstraintId:integer;
  indexType,indexOrigin:string;
  filename_null,startPage_null,status_null,s_null,n_null,index_Id_null,dummy_null:boolean;
  indexType_null,indexOrigin_null,indexConstraintId_null,viewDefinition_null:boolean;
  i,iseek:ColRef;

  sysIndexR, sysIndexColumnR:TObject; //Trelation   //todo maybe able to share some as common lookupR? any point?

  indexPtr:TIndexListPtr;
  iNew:TIndexFile;
  saveTranIsolation:Tisolation;
begin
  result:=Ok;

  if fIndexList<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Table %s already has index(es) open',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;

  index_Id:=0; index_Id_null:=true;
  filename:=''; filename_null:=true;

  {Lookup indexes in sysIndex and get the filename & startpage, unless it's a view}
  result:=Ttransaction(st.owner).db.catalogRelationStart(st,sysIndex,sysIndexR);
  if result=ok then
  begin
    saveTranIsolation:=Ttransaction(st.owner).isolation;
    Ttransaction(st.owner).isolation:=isReadUncommitted; //we need to see partially built indexes to be able to maintain them (dirty but safe)
                                     //Potential problem if new index is for a new column: but then our caller would never modify such a column so ok(?)
    try
      if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysIndexR,ord(si_table_id),table_id)=ok then
        try
          repeat
            {Found another matching index table for this table}
            with (sysIndexR as TRelation) do
            begin
              fTuple.GetInteger(ord(si_index_id),index_id,index_id_null);

              fTuple.GetString(ord(si_index_name),s,s_null); //assume never null
              //todo: in future remember the index name against the index, currently ignored...
              fTuple.GetString(ord(si_index_Type),indexType,indexType_null);
              fTuple.GetString(ord(si_index_origin),indexOrigin,indexOrigin_null);
              fTuple.GetInteger(ord(si_index_constraint_id),indexConstraintid,indexConstraintid_null);
              fTuple.GetString(ord(si_file),filename,filename_null);
              fTuple.GetBigInt(ord(si_first_page),bigStartPage,startPage_null);
              StartPage:=bigStartPage;
              fTuple.GetInteger(ord(si_status),status,status_null);
              {$IFDEF DEBUGDETAIL7}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found index %s in %s for table_id=%d with file=%s, id=%d and start page=%d, type=%s',[s,sysIndex_table,table_id,filename,index_Id,startPage,indexType]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}

              iNew:=self{!not with sysIndexR! aaarrrgh! wasted 4 hours!}.LinkNewIndex(st,index_id,indexType,indexOrigin,indexConstraintid,filename,startpage,TindexState(status));
              if iNew=nil then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed linking index',[nil]),vError);
                {$ENDIF}
                result:=Fail;
                exit; //abort
              end;
              result:=ok;
              {Now lookup the index columns}
              if Ttransaction(st.owner).db.catalogRelationStart(st,sysIndexColumn,sysIndexColumnR)=ok then
              begin
                try
                  begin
                    //todo use future relation.Find() method}
                    iNew.ColCount:=0;

                    if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysIndexColumnR,ord(sic_index_id),index_Id)=ok then
                      try
                        repeat
                          {Found another matching column for this index}
                          iNew.colCount:=iNew.colCount+1; //add this index column
                          with (sysIndexColumnR as TRelation) do
                          begin
                            fTuple.GetInteger(ord(sic_column_id),n,n_null); //assume never null
                            iNew.ColMap[iNew.ColCount].cid:=n;
                            fTuple.GetInteger(ord(sic_column_sequence),n,n_null); //assume never null
                            iNew.ColMap[iNew.ColCount].cref:=n; //temporary store seq to enable sort so that subscript is used for column sequencing from now on
                            //Note: we find real cRef from cid in self.tuple after read all and sorted by sequence

                            {$IFDEF DEBUGDETAIL7}
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('Found index column %d in %s with seq=%d',[iNew.colMap[iNew.colCount].cid,sysIndexColumn_table,iNew.colMap[iNew.colCount].cref]),vDebugLow);
                            {$ELSE}
                            ;
                            {$ENDIF}
                            {$ENDIF}
                            //todo assert sequence=colCount - need to read all then reorder!*
                          end; {with}
                        until Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysIndexColumnR,ord(sic_index_id),index_Id)<>ok;
                              //todo stop once we're past our index_id if sysIndexColumn is sorted... -speed - this logic should be in Find routines...

                        {$IFDEF DEBUGDETAIL7}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Found index with %d columns',[iNew.colCount]),vDebugLow);
                        {$ELSE}
                        ;
                        {$ENDIF}
                        {$ENDIF}
                      finally
                        if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysIndexColumnR)<>ok then
                        begin
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysIndexColumn)]),vError); 
                          {$ELSE}
                          ;
                          {$ENDIF}
                          result:=Fail;
                        end;
                      end; {try}
                    //else index has no columns = todo assertion?
                  end
                finally
                  if Ttransaction(st.owner).db.catalogRelationStop(st,sysIndexColumn,sysIndexColumnR)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysIndexColumn)]),vError); 
                    {$ELSE}
                    ;
                    {$ENDIF}
                    result:=Fail;
                  end;
                end; {try}
              end
              else
              begin  //couldn't get access to sysIndexColumn
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysIndexColumn)]),vDebugError); 
                {$ELSE}
                ;
                {$ENDIF}
                result:=Fail;
              end;

              {Now ensure our index column definitions are in sequence order, because the heapfile scan doesn't guarantee this}
              iNew.OrderColRef;        
              //todo check result!

              {Now that we have re-ordered the index columns, lookup the cref from the cid's}
              //todo: put this FindColFromId lookup in TTuple?
              for i:=1 to iNew.ColCount do
              begin
                iseek:=0;
                while iseek<self.fTuple.colCount{=1 past end} do
                begin
                  if iNew.ColMap[i].cid=self.fTuple.fColDef[iseek].id then
                    break;
                  inc(iseek);
                end;
                if iseek<self.fTuple.colCount{=1 past end} then
                begin //match found
                  iNew.ColMap[i].cRef:=iseek; //set cRef to its proper current value
                end
                else
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Index column id %d not found in relation %s',[iNew.ColMap[i].cid,self.relname]),vAssertion{DebugError});
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=Fail;
                  exit; //abort
                  //todo: just ignore this index and continue (applies to all index failures!)
                end;
              end;

              {Copy the relations's tuple structure to the index's tupleKey for use in indexed-scans etc.}
              iNew.fTupleKey.CopyTupleDef(self.fTuple);

            end; {with}
          until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysIndexR,ord(si_table_id),table_id)<>ok);
                //todo stop when there are no more matching this id
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysIndexR)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysIndex)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
          end;
        end; {try}
      //else no index(es) found
    finally
      Ttransaction(st.owner).isolation:=saveTranIsolation;
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysIndex,sysIndexR)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysIndex)]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
      end;
    end; {try}

    {Now load constraint information for optimiser use}
    LoadConstraints(st,table_id);
  end
  else
  begin  //couldn't get access to sysIndex
    //Note: -2 result -> relation is not yet open - i.e. db is starting up
    {$IFDEF DEBUG_LOG}
    if result<>-2 then log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysIndex)]),vDebugError); 
    {$ENDIF}
  end;
end; {OpenIndexes}

function TRelation.CreateNew(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;ViewDef:boolean;const viewOrFilename:string):integer;
{Link the relation to a new db file, or just adds the view definition to the system catalog
 IN       :  st               the statement
          :  find_node        the ntSchema node to search for
          :  schema name      the schema name (must already exist) in case find_node is nil //will be phased out
                                                           //although may always need for initial bootstrap creations
          :  name             the relation name
          :  viewDef          False=base-table, True=view-definition (i.e. don't create a dbFile)
          :  viewOrFilename   the base-table filename in the db; if viewDef then the view definition
 RETURN   :  +ve=ok,
             -2 = table/view already exists
             -3 = not privileged to add to this schema
             -4 = unknown catalog
             -5 = unknown schema
             else fail

 Side-effects
   Creates fdbFile instance, if not viewDef
   Add the table and column definitions to the system catalog
   Creates a new db file entry in the database, if not viewDef
   Copies the tuple definition to tupleKey for searched-scans etc.

 Notes:
   Don't call Open afterwards - just use

   The view definition was piggybacked onto this routine because it's very similar to
   the addition of a new table, although Trelation is not used for handling the view
   at any other time (except open), so maybe they should both call a common 'add table/columns'
   routine, but be separate so we don't have to create a dummy relation to add a view?

   We check whether we're privileged or not, e.g. schema auth_id=tr.authId
   (otherwise UserA could create a table in a schema owned by UserB and so not have privileges to it!)
}
const routine=':createNew';
var
  i:ColRef;
  rid:Trid;
  table_Id,genId:integer;
  s:string;
  null:boolean;

  auth_id:TauthId; //auth_id of schema => table owner
  catalog_Id:TcatalogId;
  schema_Id:TschemaId; //schema id of name passed into routine (schemaId is Tr's)
  catalog_name:string;

  sysTableR, sysColumnR:TObject; //Trelation

  isView:boolean;
  viewDefinition:string;
  tempResult:integer;
begin
  result:=fail;
  if assigned(fdbfile) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Table %s is already open',[fname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {first, find the schema id for this table} //todo check if this is ok if this is the sysSchema table?
  {Note: =>checked foreign key relation}
  if schema_name=sysCatalogDefinitionSchemaName then
  begin
    //we only *need* to assume this before sysSchema is open (currently if db.createdb is creating sys tables)
    // - otherwise we have a chicken and egg loop: trying to find schema id for (or before) schema id table
    // but it's faster anyway to always assume it (although the relations are only created once per db)
    schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation/open algorithm
    auth_id:=Ttransaction(st.owner).authId; //use default if none specified
                     //todo? assert =our default schema's authid - for SQL92 but not for SQL3? check specs!
                     //Note: this creates a loophole: any authId can create tables in sysCatalogDefinitionSchemaName!
  end
  else
  begin
    {Now we've defaulted the schema name, should we still skip checks because of bootstrap?}
    if schema_name=sysCatalogDefinitionSchemaName then
    begin
      //we only *need* to assume this before sysSchema is open (currently if db.createdb is creating sys tables)
      // - otherwise we have a chicken and egg loop: trying to find schema id for (or before) schema id table
      // but it's faster anyway to always assume it (although the relations are only created once per db)
      schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation/open algorithm
      auth_id:=Ttransaction(st.owner).authId; //use default if none specified
                       //todo? assert =our default schema's authid - for SQL92 but not for SQL3? check specs!
                       //Note: this creates a loophole: any authId can create tables in sysCatalogDefinitionSchemaName!
    end
    else
    begin {Now lookup the schema_id and compare it's auth_id with this user's - if they don't match we fail}
      tempResult:=getOwnerDetails(st,find_node,schema_name,Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
      if tempResult<>ok then
      begin  //couldn't get access to sysSchema
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugError); 
        {$ENDIF}
        case tempResult of -2: result:=-4; -3: result:=-5; end; {case}
        exit; //abort
      end;
      {Now check that we are privileged to add entries to this schema}
      if auth_Id<>Ttransaction(st.owner).authId then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%d not privileged to insert into schema authorised by %d',[Ttransaction(st.owner).authId,auth_id]),vError);
        {$ENDIF}
        result:=-3;
        exit; //abort
      end;
    end;
  end;

  {Check this relation is not already in sysTable: if it is, return error}
  if open(st,find_node,schema_name,name,isView,viewDefinition)<>fail then  //i.e. +2 = opened table ok
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Table %s already exists',[fname]),vError);
    {$ENDIF}
    result:=-2;
    close;
    exit; //abort
  end;

  //move this below, i.e. defer until we've added entry to system catalog
  if not viewDef then
  begin
    if (uppercase(name)=uppercase(sysTransaction_table))
    or (uppercase(name)=uppercase(sysServer_table))
    or (uppercase(name)=uppercase(sysStatusGroup_table))
    or (uppercase(name)=uppercase(sysStatus_table))
    or (uppercase(name)=uppercase(sysServerStatus_table))
    or (uppercase(name)=uppercase(sysCatalog_table))
    or (uppercase(name)=uppercase(sysServerCatalog_table))
    then
      fdbfile:=TVirtualFile.create(fTuple)
    else
      fdbfile:=THeapFile.create;  //todo: use a class pointer instead of hardcoding THeapFile here...?
    if fdbfile.createFile(st,viewOrFilename)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed creating file %s',[viewOrFilename]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      exit;
    end;
  end;

  {Add entry to sysTable (even if this is sysTable being created!)}
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysTable,sysTableR)=ok then
  begin
    try
      //now we could do: if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysTableR,ord(st_table_name),name)=ok then already exists
      //-but we'll leave that to caller/elsewhere
      with (sysTableR as TRelation) do
      begin
        fTuple.clear(st);
        //todo check results!
        {Note: it is *vital* that these are added in sequential order - else strange things happen!}
        genId:=0; //lookup by name
        (Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysTable_generator',genId,Table_Id); //todo check result!
        fTuple.SetInteger(ord(st_table_id),Table_Id,false);
        fTuple.SetString(ord(st_table_name),pchar(name),false);  //assume never null
        fTuple.SetInteger(ord(st_schema_id),schema_Id,false);
        if not viewDef then
        begin
          fTuple.SetString(ord(st_file),pchar(viewOrFilename),false); //assume never null
          fTuple.SetBigInt(ord(st_first_page),self.fdbFile.startPage,false);
          fTuple.SetString(ord(st_Table_Type),ttBaseTable,false); //assume never null
          fTuple.SetString(ord(st_View_definition),'',true); 
        end
        else
        begin
          fTuple.SetString(ord(st_file),'',True);
          fTuple.SetBigInt(ord(st_first_page),0,True);
          fTuple.SetString(ord(st_Table_Type),ttView,false); //assume never null
          fTuple.SetString(ord(st_View_definition),pchar(viewOrFilename),False); 
        end;
        {$IFDEF DEBUG_LOG}
        if (self.NextColId<=self.fTuple.fColDef[self.fTuple.ColCount-1].id) and not viewDef then
          log.add(st.who,where+routine,format('NextColId (%d) is less than last column id (%d) - should be at least 1 higher',[self.NextColId,self.fTuple.fColDef[self.fTuple.ColCount-1].id]),vAssertion);
        {$ENDIF}
        fTuple.SetInteger(ord(st_Next_Col_id),self.NextColId,false);
        fTuple.insert(st,rid); //Note: obviously this bypasses any constraints
                               //Note: as soon as this startPage is added (even uncommitted) then
                               //      the garbage collector will rely on it when it comes to purging the table
                               //      - so any updates to startPage must be valid immediately!
      end; {with}
      fAuthId:=auth_Id; //store for later reference
      fSchemaId:=schema_Id; //store for later reference
      fTableId:=table_Id; //store for later reference
      {$IFDEF DEBUGDETAIL5}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Inserted %s %s into %s',[schema_name,name,sysTable_table]),vdebug);
      {$ENDIF}
      {$ENDIF}
      
    //todo move this finally till after we've added the columns,
    // else someone could drop the table & we'd fail - or would we? sysCatalog info is versioned! so we'd probably be ok!!!!!
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysTable,sysTableR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTable)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysTable
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysTable)]),vDebugError); 
    {$ELSE}
    ;
    {$ENDIF}
  end;

  {Now add this table/view's column entries to sysColumn, if it exists yet}
  if viewOrFilename<>sysTable_file then {this is the only time before sysColumn exists}
  begin
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysColumn,sysColumnR)=ok then
    begin
      try
        with (sysColumnR as TRelation) do
        begin
          for i:=0 to self.fTuple.ColCount-1 do
          begin
            //todo check results!
            {Set source}
            //Note: (self.)fAuthId etc. are masked by 'with sysColumnR'!
            self.fTuple.fColDef[i].sourceAuthId:=auth_Id;
            self.fTuple.fColDef[i].sourceTableId:=table_Id;
            {Note: it is *vital* that these are added in sequential order - else strange things happen!}
            fTuple.clear(st);
            fTuple.SetInteger(ord(sc_table_id),Table_Id,false);
            fTuple.SetInteger(ord(sc_column_id),self.fTuple.fColDef[i].id,false);
            s:=self.fTuple.fColDef[i].name;
            fTuple.SetString(ord(sc_column_name),pchar(s),false); //assume never null
            fTuple.SetInteger(ord(sc_domain_id),self.fTuple.fColDef[i].domainId,false);
            fTuple.SetString(ord(sc_reserved_1),'',True); 
            fTuple.SetInteger(ord(sc_datatype),ord(self.fTuple.fColDef[i].dataType),false);
            fTuple.SetInteger(ord(sc_width),self.fTuple.fColDef[i].width,false);
            fTuple.SetInteger(ord(sc_scale),self.fTuple.fColDef[i].scale,false);
            //todo ensure default is null if viewDef
            fTuple.SetString(ord(uGlobal.sc_default),pchar(self.fTuple.fColDef[i].defaultVal),self.fTuple.fColDef[i].defaultNull);
            fTuple.SetString(ord(sc_reserved_2),'',True); 
            fTuple.insert(st,rid); //Note: obviously this bypasses any constraints
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Inserted column %s of %s into %s',[self.fTuple.fColDef[i].name,name,sysColumn_table]),vdebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end;
        end; {with}
        {$IFDEF DEBUGDETAIL5}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %s columns into %s',[name,sysColumn_table]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysColumn,sysColumnR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysColumn)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysColumn
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysColumn)]),vDebugError); 
      {$ELSE}
      ;
      {$ENDIF}
    end;
  end;
  //else we assume the db will manually add the sysTable columns elsewhere
  //todo should we ever see this case, surely we wouldn't be called
  //     and so the test here is just an assertion: if so add an assertion violation here!
  // todo: do we need to set the source details for any permission checking later? 

  if not viewDef then
  begin
    fname:=name;
    fSchemaName:=schema_name;
    fCatalogName:=catalog_name;
    //todo set ..ids here?
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation %s %s created in file %s (auth_id=%d)',[schema_name,name,viewOrFilename,auth_id]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('View %s %s created as %s (auth_id=%d)',[schema_name,name,viewOrFilename,auth_id]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    //todo fname:='' fschemaName:='' for safety?
  end;

  {Copy the tuple structure to the tupleKey for use in searched-scans etc.}
  self.fTupleKey.CopyTupleDef(self.fTuple);

  result:=ok;
end; {CreateNew}

function TRelation.Close:integer;
{Close the relation's link to a db file
 RETURN   :  +ve=ok, else fail

 Side effects:
   destroys fDBfile
   destroys any linked index files
}
const routine=':Close';
var
  indexPtr:TIndexListPtr;
  constraintPtr:TConstraintListPtr;
begin
  result:=fail;
  if not assigned(fdbfile) then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'File is not open',vAssertion)
    {$ENDIF}
  else
  begin
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Relation file %s closed',[fname]),vDebug);
    {$ENDIF}
    {$ENDIF}
    fdbfile.free;
    fdbfile:=nil;
    //todo reset tuple/tupleKey definitions to aid debugging?
    result:=ok;
  end;

  {Clean up index list}
  while fIndexList<>nil do
  begin
    indexPtr:=fIndexList;
    fIndexList:=indexPtr.next;
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Relation index file %s closed',[indexPtr.index.name]),vDebug);
    {$ENDIF}
    {$ENDIF}
    indexPtr.index.free;
    dispose(indexPtr);
    inc(debugRelationIndexDestroy);
  end;
  fCurrentIndex:=nil;

  {Clean up constraint list}
  while fConstraintList<>nil do
  begin
    constraintPtr:=fConstraintList;
    fConstraintList:=constraintPtr.next;
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Relation constraint %d removed',[constraintPtr.constraintId]),vDebug);
    {$ENDIF}
    {$ENDIF}
    dispose(constraintPtr);
    inc(debugRelationConstraintDestroy);
  end;
end; {Close}

function TRelation.ScanStart(st:TStmt):integer;
{Starts a scan of the open relation

 RETURN : +ve=ok, else fail

 Assumes:
  relation has been opened
}
const routine=':ScanStart';
var
  rid:Trid;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  result:=fdbFile.GetScanStart(st,rid);
  {$IFDEF DEBUGDETAIL5}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%s',[fTuple.ShowHeading]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,stringOfChar('=',length(fTuple.ShowHeading)),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {ScanStart}

function TRelation.ScanNext(st:TStmt;var noMore:boolean):integer;
{Gets next scan of the open relation

 OUT:     noMore   - no more tuples in this relation
 RETURN : +ve=ok, else fail (e.g. relation not open)

 Note:
  this calls tuple.read which pins the record(s) until the next read or tuple.unpin

 Assumes:
  relation has been opened
  ScanStart has been called
}
const routine=':ScanNext';
var
  rid:Trid;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    noMore:=True; //ensure we stop any loop depending on this
    exit;
  end;
  //todo assert ScanStart has been called?
  begin
    repeat
      result:=fdbFile.GetScanNext(st,rid,noMore);
      if result<>ok then exit; //abort
      if not noMore then
      begin
        result:=fTuple.read(st,rid,False);
        if result=fail then exit;
        //else result could be = noData/ = try again by looping
        // this happens if the current record is hidden from our transaction
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%s',[fTuple.ShowMap]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%s',[fTuple.Show]),vDebugLow);
        {$ENDIF}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('RID=%d:%d',[rid.pid,rid.sid]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
    until noMore or (result=ok); //i.e. if result=noData, loop again
  end;
end; {ScanNext}

function TRelation.ScanNextGarbageCollect(st:TStmt;var noMore:boolean;readFirst:boolean):integer;
{Gets next scan of the open relation (including any deleted / invisible rows)
 and garbage collects the record chain

 IN:      readFirst    - reads the tuple during garbage collect, e.g. in case we need to know what has gone (e.g. sysTable entries)
                         (obviously this is slower)
 OUT:     noMore       - no more tuples in this relation
 RETURN : +ve=ok,
          +1=deleted whole record chain
          else fail

 Note:
  this calls tuple.garbageCollect
  this does not currently update any indexes

 Assumes:
  relation has been opened
  ScanStart has been called

 todo: maybe use ScanNext & have it detect that tr is garbageCollector ?  Easier to keep in sync!
       -only difference is repeat loop is removed & call garbagecollect instead of read & result could be +1
       - BUT no record read! (usually)
}
const routine=':ScanNextGarbageCollect';
var
  rid:Trid;
  saveIsolation:Tisolation;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    noMore:=True; //ensure we stop any loop depending on this
    exit;
  end;
  //todo assert ScanStart has been called?
  begin
      result:=fdbFile.GetScanNext(st,rid,noMore);
      if result<>ok then exit; //abort
      if not noMore then
      begin
        result:=fTuple.garbageCollect(st,rid,readFirst);
        if result=fail then exit;
        //else result could be = +1 etc.

        //todo: if we've moved onto another page, maybe now's a good time to
        //re-org the previous one & remove any empty slots?
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
  end;
end; {ScanNextGarbageCollect}

function TRelation.ScanNextToIndex(st:TStmt;var noMore:boolean;iFile:TIndexFile):integer;
{Gets next scan of the open relation and adds all visible versions to the specified index

 IN:      st         the statement
          iFile      an open index file object (with the name and column mappings defined)
 OUT:     noMore   - no more tuples in this relation
 RETURN : +ve=ok,
          else fail

 Note:
  this calls tuple.readToIndex

 Assumes:
  relation has been opened
  ScanStart has been called
}
const routine=':ScanNextToIndex';
var
  rid:Trid;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ENDIF}
    noMore:=True; //ensure we stop any loop depending on this
    exit;
  end;
  //todo assert ScanStart has been called?
  begin
      result:=fdbFile.GetScanNext(st,rid,noMore);
      if result<>ok then exit; //abort
      if not noMore then
      begin
        result:=fTuple.readToIndex(st,rid,iFile);
        if result=fail then exit;
        //else result could be = +1 etc.
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
        {$ENDIF}
        {$ENDIF}
      end;
  end;
end; {ScanNextToIndex}


function TRelation.ScanStop(st:TStmt):integer;
{Stops a scan of the open relation

 RETURN : +ve=ok, else fail

 Assumes:
  relation has been opened
}
const routine=':ScanStop';
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[''{relname}]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  result:=fdbFile.GetScanStop(st);
  result:=fTuple.unpin(st); //21/06/99 added to clean up scans properly - noticed during transaction committing...
                        //final read pins & leaves pinned until next read
end; {ScanStop}


function TRelation.FindScanStart(st:TStmt;FindData:TTuple):integer;
{Starts a searched scan of the open relation

 IN:      FindData      tuple with same definition as this relation's
                        containing search data
                        If nil, then the search data has already been copied
                        into fTupleKey
                        (e.g. caller saved creating a temp tuple if search data was already in another format)

 RETURN : +ve=ok, else fail

 Notes:
   attempts to use the 'best' access method available
   - in future a parameter may be passed to tell us which one is best

 Assumes:
  relation has been opened
}
const routine=':FindScanStart';
var
  i:colRef;
  indexPtr:TIndexListPtr;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ENDIF}
    exit;
  end;

  {Store the search key}
  //todo: maybe we/caller need to set id='1','2'..'n' for key order & flagging
  //                           since: key order is needed for index lookups
  //                                  or rather flagging is needed to determine whether null=don't match or null
  //                                  - maybe dataPtr=nil => ignore?
  if findData<>nil then
  begin
    fTupleKey.clear(st);
    //no need to clearToNulls because we deepCopy all columns...
    fTupleKey.clearKeyIds(st);
    for i:=0 to fTupleKey.ColCount-1 do
    begin
      if st.whereOldValues then
        fTupleKey.copyOldColDataDeep(i,st,findData,i)
      else
        fTupleKey.copyColDataDeep(i,st,findData,i,false);
      fTupleKey.fColDef[i].keyId:=findData.fColDef[i].keyId; //todo use a copyKey routine...
      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Setting key column %d to keyId %d',[i,findData.fColDef[i].keyId]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;
    fTupleKey.preInsert; //finalise it
  end;
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeadingKey]),vDebugLow);
  log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeading]),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%s',[fTupleKey.Show(st)]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {Select and start the best access method}
  {First look for a matching index}
  indexPtr:=fIndexList;
  while indexPtr<>nil do
  begin
    if indexPtr.index.Match(st,fTupleKey,self.fNextColId{note: could reduce by 1, but no need}) then
    begin
      {$IFDEF DEBUGDETAIL6}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Relation index file %s will be used as the access method',[indexPtr.index.name]),vDebug);
      {$ENDIF}
      {$ENDIF}
      {Note: currently we crudely use the 1st matching (hash) index,
             in future the index may/should be passed to this routine from the optimiser}
      break; //found a matching index - use it
    end;
    indexPtr:=indexPtr.next;
  end;
  fCurrentIndex:=indexPtr; //set index to be used for findScan, nil=(full)scan

  {$IFDEF SKIP_INDEXES2}
  fCurrentIndex:=nil; //avoid using index debug only!
  {$ENDIF}

  if fCurrentIndex<>nil then
    result:=fCurrentIndex.index.FindStart(st,fTupleKey)  //start indexed scan
  else
  begin
    result:=self.ScanStart(st);                   //start full scan
    {$IFDEF DEBUGDETAIL10}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('No index file can be used as the access method on %s (%s)',[relname,fTupleKey.ShowHeadingKey]),vDebug);
    {$ENDIF}
    {$ENDIF}
  end;

end; {FindScanStart}

function TRelation.FindScanNext(st:TStmt;var noMore:boolean):integer;
{Gets next searched scan of the open relation

 OUT:     noMore   - no more matching tuples in this relation
 RETURN : +ve=ok, else fail (e.g. relation not open)

 Note:
  this calls tuple.read (via self.ScanNext) which pins the record(s) until the next read or tuple.unpin

 Assumes:
  relation has been opened
  FindScanStart has been called

 todo:
   surely we can immediately return noMore if we know this is a unique/primary key? -speed
}
const routine=':FindScanNext';
var
  res:TriLogic;
  rid:Trid;
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    noMore:=True; //ensure we stop any loop depending on this
    exit;
  end;
  //todo assert FindScanStart has been called? - check fTupleKey?
  begin
    {Use the selected access method to get the next tuple}
    if fCurrentIndex<>nil then
    begin //indexed scan
      repeat
        result:=fCurrentIndex.index.FindNext(st,noMore,rid);   
        if result<>ok then exit; //abort
        if not noMore then
        begin //we have a candidate rid
          result:=fTuple.read(st,rid,True); //note: this pins the data page(s)
          if result=fail then exit;

          //todo: only do the next 2 cross-checks if this is a ThashIndexFile!
          //      (because future index methods may guarantee valid rids)
          //      so check if indexType=itHash //=>(fCurrentIndex.index is ThashIndexFile)...

          //result could be = noData = try again by looping (can't debug/log show tuple- may be partial)
          // this happens if the current record is hidden from our transaction

          if result=ok then
          begin //ok, we can see this RID but is it really a matching row (might not be because hash-index currently only stores hash value to save space)
            {$IFDEF DEBUGDETAIL3}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Candidate: %s',[fTuple.Show(st)]),vDebugLow);
            {$ENDIF}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('[%d] RID=%d:%d',[result,rid.pid,rid.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            {Compare this tuple with the key data}
            //Note: this matchTuples now needs some pre-call logic to be proper...
            // - I think we really need a MatchTuples(tl,tr,keyPartList,T,F,res)... 

            //todo: matchTuples: most key cols will be null, can we skip repetitive isnull checks? - maybe quit loop early if last non-null is noted... - speed
            //todo: if we're scanning for FK match candidates we may need to pass this matchTuples test
            //      with the same match full/partial given in the FK definition!
            //      else keys with nulls will be filtered too early (but not if we pass in nulls as key parts...?)
            //done:?: we'll allow WHERE col=null for FK checks and let them pass up to the Match routine for filtering
            //        this should solve the problem without us having to pre-determine whether we have a FK index
            //        or not
            result:=MatchTuples(st,fTupleKey,fTuple,True{partial},False{full},res);
            if result<>ok then
            begin
              noMore:=True; //ensure we stop any loop depending on this //todo remove: no need if callers are well written
              exit; //abort if compare fails
            end;
            if res<>isTrue then res:=isFalse; //todo: no need, match always returns T/F? -speed

            if res<>isTrue then
            begin
              result:=noData; //continue looping until noMore or we do match
              inc((fCurrentIndex.index as THashIndexFile).statHashClash);
            end;
            //else use default result=ok to finish this loop

            {$IFDEF DEBUGDETAIL3}
            if result=ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Candidate matched',[nil]),vDebugLow)
              {$ENDIF}
            else
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Candidate did not match',[nil]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUGDETAIL3}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Candidate was invisible',[nil]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            inc((fCurrentIndex.index as THashIndexFile).statVersionMiss);
          end;
        end
        else
        begin
          {$IFDEF DEBUGDETAIL5}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      until noMore or (result=ok); //i.e. if result=noData, loop again
    end
    else
    begin //full scan
      repeat
        result:=self.ScanNext(st,noMore); //Note: this gives the next record visible to us

        if result<>ok then exit; //abort
        if not noMore then
        begin
          {Compare this tuple with the key data}
          //Note: this matchTuples now needs some pre-call logic to be proper...

          //todo: matchTuples: most key cols will be null, can we skip repetitive isnull checks? - maybe quit loop early if last non-null is noted... - speed
          result:=MatchTuples(st,fTupleKey,fTuple,True{partial},False{full},res);
          if result<>ok then
          begin
            noMore:=True; //ensure we stop any loop depending on this //todo remove: no need if callers are well written
            exit; //abort if compare fails
          end;
          if res<>isTrue then res:=isFalse; //todo: no need, match always returns T/F? -speed

          if res<>isTrue then result:=noData; //continue looping until noMore or we do match
          //else use default result=ok to finish this loop

          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%s',[fTuple.Show(st)]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end
        else
        begin
          {$IFDEF DEBUGDETAIL5}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      until noMore or (result=ok); //i.e. if result=noData, loop again
    end;
  end;
end; {FindScanNext}

function TRelation.FindScanStop(st:TStmt):integer;
{Stops a searched scan of the open relation

 RETURN : +ve=ok, else fail

 Assumes:
  relation has been opened
}
const routine=':FindScanStop';
begin
  result:=Fail;
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  if fCurrentIndex<>nil then
  begin
    result:=fCurrentIndex.index.FindStop(st); //stop indexed scan
    //todo check result!
    result:=self.ScanStop(st);                //=unpin any leftover pins from Ttuple.read
                                              //- maybe we need a relation.unpinCurrent instead?
    fTupleKey.unpin(st); //07/03/00 added to clean up find match scans properly
                         //match read pins & leaves pinned until next read
  end
  else
    result:=self.ScanStop(st);                //stop full scan
end; {FindScanStop}

function TRelation.isUnique(st:TStmt;FindData:TTuple;var res:TriLogic):integer;
{Checks if each tuple in the relation is unique

 IN:      FindData      tuple with same definition as this relation's //todo remove comment: not true?
                        containing key definition
                        If nil, then the key definition has already been copied
                        into fTupleKey
                        (e.g. caller saved creating a temp tuple)

 OUT:     res           isTrue=unique
                        else isFalse
                        (Note: never isUnknown - this behaves like a boolean)

 RETURN : +ve=ok, else fail

 Notes:
   attempts to use the 'best' access method available
   - in future a parameter may be passed to tell us which one is best

 Assumes:
  relation has been opened
}
const routine=':isUnique';
var
  i:colRef;
  indexPtr:TIndexListPtr;
  RID1,RID2:TRid;
  noMore,foundDuplicate:boolean;

  prevTupleKey:TTuple;
  skipReadUntilRIDchange,RID2wasHidden:boolean;
begin
  result:=Fail;
  res:=isFalse;

  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  {Store the key}
  if findData<>nil then
  begin
    fTupleKey.clear(st);
    //no need to clearToNulls because we deepCopy all columns...
    fTupleKey.clearKeyIds(st);
    for i:=0 to fTupleKey.ColCount-1 do
    begin
      fTupleKey.fColDef[i].keyId:=findData.fColDef[i].keyId; //todo use a copyKey routine...
    end;
    fTupleKey.preInsert; //finalise it 
  end;
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  //log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeading]),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  //log.add(st.who,where+routine,format('%s',[fTupleKey.Show]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {Select the best access method}
  {First look for a matching index}
  indexPtr:=fIndexList;
  while indexPtr<>nil do
  begin
    if indexPtr.index.Match(st,fTupleKey,self.fNextColId) then
    begin
      {$IFDEF DEBUGDETAIL6}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Relation index file %s will be used as the access method',[indexPtr.index.name]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Note: currently we crudely use the 1st matching (hash) index,
             in future the index may/should be passed to this routine from the optimiser}
      break; //found a matching index - use it
    end;
    indexPtr:=indexPtr.next;
  end;

  if indexPtr<>nil then
  begin
    result:=indexPtr.index.findStartDuplicate(st);
    if result=ok then
      try
        prevTupleKey:=TTuple.Create(self);
        try
          //todo is this copy over/underkill?
          prevTupleKey.CopyTupleDef(fTupleKey); //temp copy for duplicate comparisons
          skipReadUntilRIDchange:=False; //avoid losing 'real' records for chains of same RID pointers
          RID2wasHidden:=False; //avoid losing 'real' records for chains with invisible RID2 records
          foundDuplicate:=False; //assume none until proven otherwise
          repeat
            result:=indexPtr.index.findNextDuplicate(st,noMore,RID1,RID2);
            if result<>ok then exit; //abort
            if not noMore then
            begin //we have candidate rids
              {$IFDEF DEBUGDETAIL3}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Relation has duplicate candidates %d:%d and %d:%d',[RID1.pid,RID1.sid,RID2.pid,RID2.sid]),vDebug);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              //todo read the row(s) & confirm...

              if skipReadUntilRIDchange then
                if (RID2.pid=RID1.pid) and (RID2.sid=RID1.sid) then
                begin
                  {We have already encountered 2 identical RIDs and read a real record
                   so here we avoid the re-reading of a ghost 1st RID
                   until we know we have 2 different RIDs later
                   - this is in case later we get another match that
                       has a different RID but is a match.
                  }
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Candidates were the same RID - ignoring until we reach another RID because we already have a real one that may match',[nil]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}

                  //todo this is not exactly a miss or a clash: inc((indexPtr.index as THashIndexFile).statVersionMiss);
                  //todo use another counter? e.g. keyGarbageMiss

                  result:=noData; //continue looping until noMore or we do find a duplication
                  continue;
                end
                else
                  skipReadUntilRIDchange:=False; //reset hold
                  //todo: maybe now need to check our original found RID1 with new RID1...
                  //      could be match & only then check new RID1 and RID2...
                  //      else loophole? & miss a real duplicate match...
                  //      But no need(?) because:
                  //        findNextDuplicate only returns if hashes are different
                  //        which implies no match!
                  //        1(real) 1(garbage)
                  //        1       1...
                  //        1       2
                  //        so only case would be that we need to check against RID2
                  //        and next statement checks whether we need to re-read RID1 or not...
                  //        - bulk test extensively!

              if RID2wasHidden then
              begin //skip reading RID1 (since it was the hidden RID2 from last time (or a processed record at least))
                result:=ok; //RID1 was read ok & retained (but in a prior iteration)
              end
              else
              begin
                if (RID1.pid<>prevTupleKey.RID.pid) or (RID1.sid<>prevTupleKey.RID.sid) then
                begin
                  result:=prevTupleKey.read(st,RID1,True); //note: this pins the data page(s)
                  if result=fail then exit;
                end;
              end;
              
              //todo: only do the next 3 cross-checks if this is a ThashIndexFile!!
              //      so check if indexType=itHash //=>(fCurrentIndex.index is ThashIndexFile)...
              //todo: any other indexes might guarantee duplicate candidates

              //result could be = noData = try again by looping (can't debug/log show tuple- may be partial)
              // this happens if the current record is hidden from our transaction

              if result=ok then
              begin //ok, we can see this RID1 but is it really a duplicate row (might not be because hash-index currently only stores hash value to save space)
                {$IFDEF DEBUGDETAIL3}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Candidate1: %s',[prevTupleKey.Show(st)]),vDebugLow);
                {$ENDIF}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('[%d] RID=%d:%d',[result,rid1.pid,rid1.sid]),vDebugLow);
                {$ENDIF}
                {$ENDIF}

                {Note: if we encounter two pointers to the same RID, treat as mismatch
                 - only one can be the latest & it cannot match its old versions
                 Note: we do this after reading a valid 1st one because we need to retain
                       any real record in case later we get another match that
                       has a different RID but is a match.
                       We also skip the re-reading of a ghost 1st RID
                       until we know we have 2 different RIDs later
                }
                if (RID2.pid=RID1.pid) and (RID2.sid=RID1.sid) then  //speed: we could avoid this check if we know we just set skipReadUntilRIDchange:=False
                begin
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Candidates were the same RID - ignoring (at least one must be invisible)',[nil]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  inc((indexPtr.index as THashIndexFile).statVersionMiss);

                  skipReadUntilRIDchange:=True;

                  result:=noData; //continue looping until noMore or we do find a duplication
                  continue; //keep searching
                end;

                {Compare this tuple with the second tuple}

                //todo: maybe skip if rid2=rid1 - in future =>old versions?
                result:=fTupleKey.read(st,RID2,True); //note: this pins the data page(s)
                if result=fail then exit;

                //result could be = noData = try again by looping (can't debug/log show tuple- may be partial)
                // this happens if the current record is hidden from our transaction

                if result=ok then
                begin //ok, we can see both RIDs but are they really duplicate rows  (might not be because hash-index currently only stores hash value to save space)
                  RID2wasHidden:=False; //now we've read a visible RID2 we can revert to normal read 1 & 2 matching behaviour
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Candidate2: %s',[fTupleKey.Show(st)]),vDebugLow);
                  {$ENDIF}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('[%d] RID=%d:%d',[result,rid2.pid,rid2.sid]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  result:=CompareTuples(st,prevTupleKey,fTupleKey,compResEQ,res);
                  if result<>ok then
                  begin
                    noMore:=True; //ensure we stop any loop depending on this //todo remove: no need if callers are well written
                    exit; //abort if compare fails
                  end;
                  if res<>isTrue then res:=isFalse; //Note: force unknown to be false i.e. force to be boolean

                  if res<>isTrue then
                  begin
                    result:=noData; //continue looping until noMore or we do find a duplication
                    inc((indexPtr.index as THashIndexFile).statHashClash);
                    //todo x 2? or use another clash counter?
                  end
                  else //default result=ok (with res inverted to isFalse) to finish this loop
                  begin
                    foundDuplicate:=True;
                  end;

                  {$IFDEF DEBUGDETAIL3}
                  if result=ok then
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Duplicate matched',[nil]),vDebugLow)
                    {$ENDIF}
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Duplicate did not match',[nil]),vDebugLow);
                    {$ELSE}
                    ;
                    {$ENDIF}
                  {$ENDIF}
                end
                else
                begin
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Candidate2 was invisible',[nil]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  inc((indexPtr.index as THashIndexFile).statVersionMiss);

                  {Ensure we retain our valid RID1 tuple for next duplicate
                   Note: the next duplicate will include this hidden RID2 as its RID1 so we will ignore it
                   and preserve our current RID1 and wait until we have a visible RID2}
                  RID2wasHidden:=True; //note: may have already been set if we're following a chain of failures
                end;

                //speed:
                //  copy ftupleKey to prevTupleKey (i.e. RID2 becomes next RID1)
                //  this should save re-reads for lists of duplicates = most likely to bunch

              end
              else
              begin
                {$IFDEF DEBUGDETAIL3}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Candidate1 was invisible',[nil]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                inc((indexPtr.index as THashIndexFile).statVersionMiss);
              end;
            end
            else
            begin
              {$IFDEF DEBUGDETAIL5}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('No more %s',[relname]),vDebugMedium)
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
            end;
          until noMore or (result=ok); //i.e. if result=noData, loop again
              //todo or foundDuplicate - no need?
          if foundDuplicate then
            res:=isFalse //i.e. we found duplicates, return isUnique=isFalse (invert)
          else
            res:=isTrue; //i.e. we did not find duplicates, return isUnique=isTrue (invert)
          result:=ok;
        finally
          prevTupleKey.unpin(st); //07/03/00 added to clean up duplicate scans properly
                                  //compare read pins & leaves pinned until next read
          prevTupleKey.free;
        end; {try}
      finally
        indexPtr.index.findStopDuplicate(st); //todo check result?
        fTupleKey.unpin(st); //07/03/00 added to clean up duplicate scans properly
                             //compare read pins & leaves pinned until next read
      end; {try}
  end
  else //todo log assertion/warning...?
    result:=fail; //no matching index, so currently isUnique is not supported //todo use group-by/distinct/count instead = slow but sure
end; {isUnique}


function TRelation.CreateNewIndex(st:TStmt;iFile:TIndexFile;const indexName:string):integer;
{Link the relation to a new db index file
 IN       :  st               the statement
          :  iFile            an index file object with the name and columns mappings defined
          :  indexName        the index name
 RETURN   :  +ve=ok, else fail

 Side-effects
   Links the iFile instance to this relation
   Creates a new db index-file entry in the database
   Copies the relation's tuple definition to the tupleKey definition for indexed-scans etc.

 Notes:
   Don't call Open afterwards - just use

 Assumes:
  caller will add the index and index-column definitions to the system catalog
}
const routine=':createNewIndex';
var
  indexPtr:TIndexListPtr;
begin
  result:=Fail;

  iFile.Owner:=self;

  result:=iFile.createFile(st,indexName);

  {Note:
    we should call PrepareSQL/ExecutePlan here to add the index definition
    to the sys catalog.
    We currently leave this code to the calling routine to save reliance/
    circular references for future simplicity. i.e. better if Trelation
    relies on as little as possible.
  }

  if result=ok then
  begin
    {Copy the relations's tuple structure to the index's tupleKey for use in indexed-scans etc.}
    iFile.fTupleKey.CopyTupleDef(self.fTuple);

    {Add this to our index list - we are now responsible for its removal}
    new(indexPtr);
    inc(debugRelationIndexCreate);
    indexPtr.index:=iFile;
    indexPtr.next:=fIndexList;
    fIndexList:=indexPtr;
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Index %s added to relation list %s',[indexName,relname]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end;
end; {CreateNewIndex}

function TRelation.ScanAlltoIndex(st:TStmt;iFile:TIndexFile):integer;
{Add all the relation's tuple versions to the specified index file
 IN       :  st               the statement
          :  iFile            an open index file object (with the name and column mappings defined)
 RETURN   :  +ve=ok, else fail

 Side-effects:
   does a full scan of the relation pointed to by the index - currently (always?) self

 Notes:
   intended for building sys-catalog indexes with future use in rebuilding indexes
   (maybe future use to add keys after bulk insert to save buffer switching... speed)

 Assumes:
  caller will have truncated the index file if it is to be rebuilt

  the index file is owned/linked to this relation

 todo: allow pre-allocate parameter - or get caller to pre-allocate space
       based on estimated number of rows (for hash indexes we can guess pretty well?)
}
const routine=':ScanAlltoIndex';
var
  noMore:boolean;
  saveRt:StampId;
  saveIsolation:Tisolation;
begin
  result:=Fail;

  //SAFETY (speed?)
  if iFile.Owner<>self then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Index does not point to this relation (%d)',[longint(iFile.Owner)]),vAssertion);
    {$ENDIF}
    exit;
  end;
  //else not allowed? crazy?

  saveRt:=st.Rt;
  saveIsolation:=Ttransaction(st.owner).isolation;
  try
    st.Rt:=Ttransaction(st.owner).GetEarliestActiveTranId; //we read as if we were the earliest active transaction & save any future versions up until we see a committed record from our viewpoint = history horizon
    Ttransaction(st.owner).isolation:=isSerializable; //read committed records earlier than the earliest, i.e. keep adding all versions of a record which may be visible to active transactions

    {$IFDEF DEBUGDETAIL8}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Using tranId=%s',[st.who]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    result:=self.ScanStart(st);
    if result<>ok then exit; //abort
    try
      noMore:=False;
      repeat
        result:=self.ScanNextToIndex(st,noMore,iFile);
        if result<>ok then exit; //abort
      until noMore;
    finally
      result:=self.ScanStop(st);
    end; {try}
  finally
    st.Rt:=saveRt;
    Ttransaction(st.owner).isolation:=saveIsolation;
  end; {try}
end; {ScanAlltoIndex}

function TRelation.fScanInProgress:boolean;
begin
  if fdbfile=nil then
    result:=False
  else
    result:=not(fdbfile.currentRID.pid=InvalidPageId) and (fdbfile.currentRID.sid=InvalidSlotId);
end;

function TRelation.EstimateSize(st:TStmt):integer;
{Estimates size of this relation
 RETURNS:  0=fail, else relative size

 Currently, size=number of dirSlots, i.e. pages allocated (although they could be empty! but still need to read in a scan...)
}
const routine=':estimateSize';
var
  lastDirPage,prevLastSlotDirPage:cardinal;
  dirSlotCount:integer;
begin
  if fdbFile=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Relation file not open %s',[relname]),vAssertion);
    {$ENDIF}
    result:=0;
    exit;
  end;

  if dbFile.DirCount(st,dirSlotCount,lastDirPage,prevLastSlotDirPage,False{don't retry to get accurate figure})=ok then result:=dirSlotCount else result:=0;
end;

function TRelation.debugDump(st:TStmt;connection:TIdTCPConnection;summary:boolean):integer;
{Dump analysis of pages to client
}
begin
  result:=fail;

  result:=fdbFile.debugDump(st,connection,summary);
end; {debugDump}


end.


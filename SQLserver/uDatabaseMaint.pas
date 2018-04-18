unit uDatabaseMaint;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses uStmt,uGlobal,IdTCPConnection;

function CatalogBackup(st:Tstmt;connection:TIdTCPConnection;targetName:string):integer;


implementation

uses uLog,SysUtils,uServer,uDatabase,uTransaction,
     uRelation, uFile, uHeapFile, uHashIndexFile, uPage,
     uOS, uGlobalDef, classes{for TList}, uParser,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
     uProcessor     
     ,uEvsHelpers;

const where='uDatabaseMaint';


function copySystemTables(st:Tstmt;connection:TIdTCPConnection;targetTran:TTransaction;targetDB:TDB):integer;
{Copy
        sysTable        (and allocate table space for each table, updating the start page in each row)
        sysColumn
        sysIndex        (and allocate index space for each index, updating the start page in each row)
        sysIndexColumn
 ignoring these tables themselves which are taken to already exist.


 Note: based on garbageCollector.execute
}
const routine=':copySystemTables';
var
  i:integer;
  res:integer;

  sysTableR, targetSysTableR:TRelation; //generic system table references
  targetdbFile:TDBFile;
  r:TRelation;
  isView:boolean;
  viewDefinition:string;
  rnoMore,noMore:boolean;

  schema_name:string;
  table_auth_id:integer; //auth_id of table schema owner => table owner
  crippledStartPage:integer;
  startPage:PageId; //note: many of these are used for more than one table below
  table_schema_id,table_table_Id:integer;
  filename,tableName,tableType,indexName:string;
  indexType:string;
  tableName_null,filename_null,startPage_null,table_table_Id_null:boolean;
  indexType_null,tableType_null,dummy_null:boolean;

  sysSchemaR:TObject; //Trelation

  sysTableName:string;
  tableId,indexId:integer;
  sysTableId,sysColumnId,sysIndexId,sysIndexColumnId:integer;
  copiedRid:Trid;
  newStart:PageId;

  sysIndexList:TList;
begin
 result:=fail; //assume failure

 try //to avoid strange crash when r fails to open & then tries to free twice...
  {$IFDEF DEBUG_LOG}
  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,formatDateTime('"Table copy starting at "c',now),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy starting as %d with earliest active transaction of %d',[Ttransaction(st.owner).sysStmt.Wt.tranId,Ttransaction(st.owner).sysStmt.Rt.tranId]),vDebugLow);
  {$ENDIF}


  sysIndexList:=TList.create;
  r:=TRelation.create;
  sysTableR:=TRelation.create;
  targetSysTableR:=TRelation.create;
  try
    sysTableId:=0;
    sysColumnId:=0;
    sysIndexId:=0;
    sysIndexColumnId:=0;

    {1. sysTable}
    sysTableName:=sysTable_table;
    if sysTableR.open(Ttransaction(st.owner).sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening %s',[sysTableName]));
      exit; //abort
    end;

    noMore:=False;

    {Open the target sysTable}
    if targetSysTableR.open(targetTran.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy opened %s on %s',[sysTableName,targetTran.db.dbname]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy failed to open target %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening target %s',[sysTableName]));
      exit; //abort
    end;

      if not noMore then
        if sysTableR.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to start scan on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed accessing %s',[sysTableName]));
          exit; //abort
        end;

      {Process loop}
      while (not noMore) do
      begin
        if sysTableR.ScanNext(Ttransaction(st.owner).sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            if st.status=ssCancelled then
            begin
              result:=Cancelled;
              exit;
            end;

            sysTableR.fTuple.GetInteger(ord(st_Table_Id),tableId,dummy_null);
            sysTableR.fTuple.GetString(ord(st_Table_Type),tableType,tableType_null);
            sysTableR.fTuple.GetString(ord(st_Table_Name),tableName,tableName_null);

            {We must skip the tables which already exist}
            //Note: assume start pages are same!
            if tableName=sysTable_table then
            begin
              assert(sysTableId=0,'sysTable already processed');
              sysTableId:=tableId;
              continue; //skip
            end;
            if tableName=sysColumn_table then
            begin
              assert(sysColumnId=0,'sysColumn already processed');
              sysColumnId:=tableId;
              continue; //skip
            end;
            if tableName=sysIndex_table then
            begin
              assert(sysIndexId=0,'sysIndex already processed');
              sysIndexId:=tableId;
              continue; //skip
            end;
            if tableName=sysIndexColumn_table then
            begin
              assert(sysIndexColumnId=0,'sysIndexColumn already processed');
              sysIndexColumnId:=tableId;
              continue; //skip
            end;

            {First create the table space}
            newStart:=0; //=n/a, e.g. view or virtual table
            if tableType<>ttView then
            begin //base table
              begin
                {Create space for the table in the target database (code copied from Trelation.creatNew)}
                targetdbFile:=THeapFile.create;  //todo: use a class pointer instead of hardcoding THeapFile here...?
                targetdbFile.createFile(targetTran.sysStmt,tableName{not used});
                newStart:=targetdbFile.startPage;
                targetdbFile.free;
                targetdbFile:=nil;

                {$IFDEF DEBUG_LOG}
                log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy created target space for: %s.%s starting at page %d',[schema_name,tableName,newStart]),vDebugLow);
                {$ENDIF}
              end;
            end;
            //else view = no storage

            {Now we can copy the sysTable row to the target sysTable, with any new table start page}
	    //Note: upgrade mapping logic would go here
            targetSysTableR.fTuple.clear(targetTran.sysStmt);
            for i:=0 to sysTableR.fTuple.ColCount-1 do
              if (i=ord(st_First_page)) and (newStart<>0) then
                targetSysTableR.fTuple.SetBigInt(i,newStart,False)
              else
                targetSysTableR.fTuple.CopyColDataDeep(i,st{->source db},sysTableR.fTuple,i,true);
            targetSysTableR.fTuple.insert(targetTran.sysStmt,copiedRid);
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,format('  copied row to %d:%d: %s',[copiedRid.pid,copiedRid.sid,targetSysTableR.fTuple.Show(targetTran.sysStmt)]),vDebugLow);
            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy finished scan of %s',[sysTableName]),vDebugLow);
            {$ENDIF}
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to scan next on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed reading %s',[sysTableName]));
          exit; //abort
        end;

      end; {process loop}

    sysTableR.scanStop(Ttransaction(st.owner).sysStmt);
    sysTableR.Close;
    targetSysTableR.Close;

    {2. sysColumn}
    sysTableName:=sysColumn_table;
    if sysTableR.open(Ttransaction(st.owner).sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening %s',[sysTableName]));
      exit; //abort
    end;

    noMore:=False;

    {Open the target sysColumn}
    if targetSysTableR.open(targetTran.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening target %s',[sysTableName]));
      exit; //abort
    end;

      if not noMore then
        if sysTableR.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to start scan on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed accessing %s',[sysTableName]));
          exit; //abort
        end;

      {Process loop}
      while (not noMore) do
      begin
        if sysTableR.ScanNext(Ttransaction(st.owner).sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            if st.status=ssCancelled then
            begin
              result:=Cancelled;
              exit;
            end;

            sysTableR.fTuple.GetInteger(ord(sc_Table_id),tableId,dummy_null);

            {We must skip the entries for the tables which already exist}
            if tableId in [sysTableId, sysColumnId, sysIndexId, sysIndexColumnId] then
              continue; //skip

            {Copy the sysColumn row to the target sysColumn}
            //Note: upgrade mapping logic woud go here
            targetSysTableR.fTuple.clear(targetTran.sysStmt);
            for i:=0 to sysTableR.fTuple.ColCount-1 do
              targetSysTableR.fTuple.CopyColDataDeep(i,st{->source db},sysTableR.fTuple,i,true);
            targetSysTableR.fTuple.insert(targetTran.sysStmt,copiedRid);
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,format('  copied row to %d:%d: %s',[copiedRid.pid,copiedRid.sid,targetSysTableR.fTuple.Show(targetTran.sysStmt)]),vDebugLow);
            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy finished scan of %s',[sysTableName]),vDebugLow);
            {$ENDIF}
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to scan next on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed reading %s',[sysTableName]));
          exit; //abort
        end;

      end; {process loop}

    sysTableR.scanStop(Ttransaction(st.owner).sysStmt);
    sysTableR.Close;
    targetSysTableR.Close;

    {3. sysIndex}
    sysTableName:=sysIndex_table;
    if sysTableR.open(Ttransaction(st.owner).sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening %s',[sysTableName]));
      exit; //abort
    end;

    noMore:=False;

    {Open the target sysIndex}
    if targetSysTableR.open(targetTran.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening target %s',[sysTableName]));
      exit; //abort
    end;

      if not noMore then
        if sysTableR.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to start scan on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed accessing %s',[sysTableName]));
          exit; //abort
        end;

      {Process loop}
      while (not noMore) do
      begin
        if sysTableR.ScanNext(Ttransaction(st.owner).sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            if st.status=ssCancelled then
            begin
              result:=Cancelled;
              exit;
            end;

            sysTableR.fTuple.GetInteger(ord(si_index_id),indexId,dummy_null);
            sysTableR.fTuple.GetString(ord(si_index_name),indexName,dummy_null);
            sysTableR.fTuple.GetInteger(ord(si_table_id),tableId,dummy_null);
            sysTableR.fTuple.GetString(ord(si_index_type),indexType,dummy_null);

            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Index (for table %d) %s: ',[tableId,indexName]),vDebugLow);
            {$ENDIF}

            {We should't skip entries for the tables which already exist, since the emptyDB has no index entries
             but we must because the data for these tables is either:
                already copied (sysTable, sysColumn)
             or about to be copied (sysIndex, sysIndexColumn)
             So the best bet will be to skip these kinds of system indexes and re-create
             them via SQL at the end of the backup routine...}
            if tableId in [sysTableId, sysColumnId, sysIndexId, sysIndexColumnId] then
            begin
              sysIndexList.Add(pointer(indexId)); //note the index_id to skip the indexColumns in the next section
              continue; //skip
            end;

            //todo: do skip entries which are unfinished e.g. isBeingBuilt?

            {First create the index space}
            begin
              {Create space for the index in the target database (code copied from createIndex/Trelation.createNewIndex)}
              newStart:=0;
              if indexType=itHash then
              begin
                targetdbFile:=THashIndexFile.create;  //todo: use a class pointer instead of hardcoding THashIndexFile here...?
                targetdbFile.createFile(targetTran.sysStmt,indexName{not used?}); //todo check result!
                newStart:=targetdbFile.startPage;
                targetdbFile.free;
                targetdbFile:=nil;

                {$IFDEF DEBUG_LOG}
                log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy created target space for: %s.%s starting at %d',[schema_name,indexName,newStart]),vDebugLow);
                {$ENDIF}
              end
              else
              begin
                {$IFDEF DEBUG_LOG}
                log.add(targetTran.sysStmt.who,where+routine,format('  Unknown index type %s',[indexType]),vAssertion);
                {$ENDIF}
                if connection<>nil then connection.WriteLn(format('Unknown index type %d',[indexType]));
                exit; //abort
              end;
            end;

            {Now we can copy the sysIndex row to the target sysIndex}
            //note: upgrade mapping logic would go here
            targetSysTableR.fTuple.clear(targetTran.sysStmt);
            for i:=0 to sysTableR.fTuple.ColCount-1 do
              if i=ord(si_first_page) then
                targetSysTableR.fTuple.SetBigInt(i,newStart,False)
              else
                targetSysTableR.fTuple.CopyColDataDeep(i,st{->source db},sysTableR.fTuple,i,true);
            targetSysTableR.fTuple.insert(targetTran.sysStmt,copiedRid);
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,format('    copied row to %d:%d: %s',[copiedRid.pid,copiedRid.sid,targetSysTableR.fTuple.Show(targetTran.sysStmt)]),vDebugLow);
            {$ENDIF}

          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy finished scan of %s',[sysTableName]),vDebugLow);
            {$ENDIF}
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to scan next on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed reading %s',[sysTableName]));
          exit; //abort
        end;

      end; {process loop}

    sysTableR.scanStop(Ttransaction(st.owner).sysStmt);
    sysTableR.Close;
    targetSysTableR.Close;

    {4. sysIndexColumn}
    sysTableName:=sysIndexColumn_table;
    if sysTableR.open(Ttransaction(st.owner).sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening %s',[sysTableName]));
      exit; //abort
    end;

    noMore:=False;

    {Open the target sysIndexColumn}
    if targetSysTableR.open(targetTran.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTableName,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy opened %s',[sysTableName]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(targetTran.sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTableName]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening target %s',[sysTableName]));
      exit; //abort
    end;

      if not noMore then
        if sysTableR.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to start scan on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed accessing %s',[sysTableName]));
          exit; //abort
        end;

      {Process loop}
      while (not noMore) do
      begin
        if sysTableR.ScanNext(Ttransaction(st.owner).sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            if st.status=ssCancelled then
            begin
              result:=Cancelled;
              exit;
            end;

            sysTableR.fTuple.GetInteger(ord(sic_index_id),indexId,dummy_null);

            {We must skip the entries for the indexes for the tables which already exist}
            if sysIndexList.IndexOf(pointer(indexId))<>-1 then
              continue; //skip

            {Copy the sysIndexColumn row to the target sysIndexColumn}
            //note: upgrade mapping logic would go here
            targetSysTableR.fTuple.clear(targetTran.sysStmt);
            for i:=0 to sysTableR.fTuple.ColCount-1 do
              targetSysTableR.fTuple.CopyColDataDeep(i,st{->source db},sysTableR.fTuple,i,true);
            targetSysTableR.fTuple.insert(targetTran.sysStmt,copiedRid);
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,format('  copied row to %d:%d: %s',[copiedRid.pid,copiedRid.sid,targetSysTableR.fTuple.Show(targetTran.sysStmt)]),vDebugLow);
            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy finished scan of %s',[sysTableName]),vDebugLow);
            {$ENDIF}
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to scan next on %s',[sysTableName]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed reading %s',[sysTableName]));
          exit; //abort
        end;

      end; {process loop}

    sysTableR.scanStop(Ttransaction(st.owner).sysStmt);
    sysTableR.Close;
    targetSysTableR.Close;

    result:=ok;
  finally
    sysIndexList.free;

    if targetsysTableR<>nil then
    begin
      targetsysTableR.free;
      targetsysTableR:=nil;
    end;

    if sysTableR<>nil then
    begin
      sysTableR.free;
      sysTableR:=nil;
    end;

    if r<>nil then
    begin
      r.free;
      r:=nil;
    end;
  end; {try}
 except
   //log message?
   //terminate;
 end;{try}
end; {copySystemTables}

function copyTables(st:Tstmt;connection:TIdTCPConnection;targetTran:TTransaction;targetDB:TDB):integer;
{Loops through sysTable copying the contents of each table
 In doing this, we remove all old versions of rows and leave a database written by 1 transaction.

 (skips the sysTable/sysColumn/sysIndex/sysIndexColumn tables - they have already been dealt with
  skips sysTran/sysTranStmt - these will be reset
  skips virtual tables - no real rows are stored)

 Note: based on garbageCollector.execute

 //todo continue if fails...
}
const routine=':copyTables';
var
  i:integer;
  res:integer;

  sysTableR:TRelation;
  r,targetr:TRelation;
  isView:boolean;
  viewDefinition:string;
  rnoMore,noMore:boolean;

  schema_name:string;
  table_auth_id:integer; //auth_id of table schema owner => table owner
  crippledStartPage:integer;
  bigStartPage:int64;
  startPage:PageId; //note: many of these are used for more than one table below
  table_schema_id,table_table_Id:integer;
  filename,tableName,tableType:string;
  indexType:string;
  tableName_null,filename_null,startPage_null,table_table_Id_null:boolean;
  indexType_null,tableType_null,dummy_null:boolean;

  sysSchemaR:TObject; //Trelation
  copiedRid:Trid;
begin
 result:=fail; //assume failure

 try //to avoid strange crash when r fails to open & then tries to free twice...
  {$IFDEF DEBUG_LOG}
  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,formatDateTime('"Table copy starting at "c',now),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy starting as %d with earliest active transaction of %d',[Ttransaction(st.owner).sysStmt.Wt.tranId,Ttransaction(st.owner).sysStmt.Rt.tranId]),vDebugLow);
  {$ENDIF}


  r:=TRelation.create;
  targetr:=TRelation.create;
  sysTableR:=TRelation.create;
  try
    {Try to open sysTable}
    if sysTableR.open(Ttransaction(st.owner).sysStmt,nil,sysCatalogDefinitionSchemaName,sysTable_table,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy opened %s',[sysTable_table]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to open %s',[sysTable_table]),vDebugError);
      {$ENDIF}
      if connection<>nil then connection.WriteLn(format('Failed opening %s',[sysTable_table]));
      exit; //abort
    end;

    noMore:=False;

    {Main loop}
    //while not terminated do
    begin

      if not noMore then
        if sysTableR.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to start scan on %s',[sysTable_table]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed accessing %s',[sysTable_table]));
          exit; //abort
        end;

      {Process loop}
      while (not noMore) do
      begin
        if sysTableR.ScanNext(Ttransaction(st.owner).sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            sysTableR.fTuple.GetString(ord(st_Table_Type),tableType,tableType_null);

            {todo if in-progress = skip to last table/page}
            if tableType<>ttView then
            begin //base table
              {Try to open relation}
              sysTableR.fTuple.GetInteger(ord(st_Schema_id),table_schema_id,dummy_null);  //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
              {We need to read the schema name}
              if Ttransaction(st.owner).db.catalogRelationStart(Ttransaction(st.owner).sysStmt,sysSchema,sysSchemaR)=ok then
              begin
                try
                  if Ttransaction(st.owner).db.findCatalogEntryByInteger(Ttransaction(st.owner).sysStmt,sysSchemaR,ord(ss_schema_id),table_schema_id)=ok then
                  begin
                    with (sysSchemaR as TRelation) do
                    begin
                      fTuple.GetString(ord(ss_schema_name),schema_name,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      fTuple.GetInteger(ord(ss_auth_id),table_auth_Id,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      //todo major/minor versions
                      {$IFDEF DEBUGDETAIL}
                      {$IFDEF DEBUG_LOG}
                      //log.add(tr.sysStmt.who,where+routine,format('Found schema %s owner=%d (from table)',[schema_name,table_auth_id]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                    end; {with}
                  end
                  else
                  begin  //schema not found
                    {$IFDEF DEBUG_LOG}
                    log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Failed finding table schema details %d',[table_schema_id]),vError);
                    {$ENDIF}
                    if connection<>nil then connection.WriteLn(format('Failed finding table schema details (%d)',[table_schema_id]));
                    continue; //abort - try next relation
                  end;
                finally
                  if Ttransaction(st.owner).db.catalogRelationStop(Ttransaction(st.owner).sysStmt,sysSchema,sysSchemaR)<>ok then
                    {$IFDEF DEBUG_LOG}
                    log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                end; {try}
              end
              else
              begin  //couldn't get access to sysSchema
                {$IFDEF DEBUG_LOG}
                log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError);
                {$ENDIF}
                if connection<>nil then connection.WriteLn(format('Failed accessing table schema details (%d)',[table_schema_id]));
                continue; //abort - try next relation
              end;

              sysTableR.fTuple.GetString(ord(st_Table_Name),tableName,tableName_null);

              {$IFDEF DEBUG_LOG}
              log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table %s.%s: ',[schema_name,tableName]),vDebugLow);
              {$ENDIF}

              {Skip the following which have already been copied}
              if tableName=sysTable_table then
                continue; //skip
              if tableName=sysColumn_table then
                continue; //skip
              if tableName=sysIndex_table then
                continue; //skip
              if tableName=sysIndexColumn_table then  
                continue; //skip

              {Skip the following which have already been reset}
              if tableName='sysTran' then  //todo use table number or constant...
                continue; //skip
              if tableName='sysTranStmt' then  //todo use table number or constant...
                continue; //skip

              {Skip the following which are virtual tables}
              if uppercase(tableName)=uppercase(sysTransaction_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysServer_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysStatusGroup_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysStatus_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysServerStatus_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysCatalog_table) then continue; //skip
              if uppercase(tableName)=uppercase(sysServerCatalog_table) then continue; //skip


              {$IFDEF DEBUG_LOG}
              log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy processing: %s.%s ',[schema_name,tableName]),vDebugLow);
              {$ENDIF}

              sysTableR.fTuple.GetString(ord(st_file),filename,filename_null);
              sysTableR.fTuple.GetBigInt(ord(st_first_page),bigStartPage,startPage_null);
              StartPage:=bigStartPage;
              sysTableR.fTuple.GetInteger(ord(st_table_id),table_Table_Id,table_table_Id_null);

              {Note: we use relation here to gain access to all associated indexes}
              if r.open(Ttransaction(st.owner).sysStmt,nil,schema_name,tableName,isView,viewDefinition)=ok then
              begin
                try
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy opened %s',[tableName]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  {Open the target table}
                  if targetr.open(targetTran.sysStmt,nil,schema_name,tableName,isView,viewDefinition)=ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(targetTran.sysStmt.who,where+routine,format('  Table copy opened %s on %s',[tableName,targetTran.db.dbname]),vDebugLow);
                    {$ENDIF}
                  end
                  else
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(targetTran.sysStmt.who,where+routine,format('  Table copy failed to open %s',[tableName]),vDebugError);
                    {$ENDIF}
                    if connection<>nil then connection.WriteLn(format('Failed opening target table %s',[tableName]));
                    exit; //abort
                  end;

                  if r.scanStart(Ttransaction(st.owner).sysStmt)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy failed to start scan on %s',[tableName]),vDebugError);
                    {$ENDIF}
                    if connection<>nil then connection.WriteLn(format('Failed accessing table %s',[tableName]));
                    continue; //abort - try next relation
                  end;
                  rNoMore:=False;
                  i:=0;

                  while (not rNoMore) do
                  begin
                    {todo!
                    if stmt.status=ssCancelled then
                    begin
                      result:=Cancelled;
                      exit;
                    end;
                    }

                    res:=r.ScanNext(Ttransaction(st.owner).sysStmt,rNoMore);
                    {Note: this table copy scans through the whole db file and fills the buffer with
                           pages only we need, possibly throwing other pages out
                           note: we must set these buffer frames to 'flush immediately' somehow... scan policy?
                    }
                    if res<>fail then
                    begin
                      if not rNoMore then
                      begin
                        //todo if sysCatalog/INFORMATION_SCHEMA_CATALOG_NAME then change name to new target
                        if st.status=ssCancelled then
                        begin
                          result:=Cancelled;
                          exit;
                        end;

                        {Now we can copy the table row to the target table, with the new table start page}
                        //note: upgrade mapping logic would go here
                        {Notes:

                        We read blob data from source disk into memory and then write to target, rather
                        than trying to write blocks from source->target because we may be able to write
                        bigger blocks to our fresh target (or take advantage of updated blob storage, e.g. compression)
                        }
                        targetr.fTuple.clear(targetTran.sysStmt);
                        for i:=0 to r.fTuple.ColCount-1 do
                          targetr.fTuple.CopyColDataDeep(i,st{->source db},r.fTuple,i,true{deep blob}); //note: shallow copy should be fine (& faster) except blobs need to be deep to read across catalogs!
                        if targetr.fTuple.insert(targetTran.sysStmt,copiedRid)<>ok then
                        begin
                          if connection<>nil then connection.WriteLn(format('Failed copying row (%d) of table %s, continuing',[i,tableName]));
                        end
                        else
                          {$IFDEF DEBUG_LOG}
                          log.add(targetTran.sysStmt.who,where+routine,format('    copied row to %d:%d: %s',[copiedRid.pid,copiedRid.sid,targetr.fTuple.Show(targetTran.sysStmt)]),vDebugLow);
                          {$ELSE}
                          ;
                          {$ENDIF}

                        inc(i);

                        //todo flush checkpoint=table-id:page-id (e.g. every 10/100 pages or so)
                      end;
                      //else no more
                    end;
                  end; {while scan}

                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy counted %d rows',[i]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  //{Flush all pages to save any de-allocations and garbage collections}
                  //(targetTran.db.owner as TDBServer).buffer.flushAllPages(targetTran.sysStmt);
                finally
                  r.scanStop(Ttransaction(st.owner).sysStmt);
                  r.close;
                  targetr.Close;
                end; {try}
              end
              else
              begin
                {$IFDEF DEBUG_LOG}
                log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('  Table copy failed to open %s',[tableName]),vDebugError);
                {$ENDIF}
                if connection<>nil then connection.WriteLn(format('Failed opening table %s',[tableName]));
                //continue...
              end;
            end;
            //else view = no storage
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy finished scan of %s',[sysTable_table]),vDebugLow);
            {$ENDIF}
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(Ttransaction(st.owner).sysStmt.who,where+routine,format('Table copy failed to scan next on %s',[sysTable_table]),vDebugError);
          {$ENDIF}
          if connection<>nil then connection.WriteLn(format('Failed finding next table',[nil]));
          exit; //abort
        end;

        sleepOS(0); //relinquish rest of time slice - we'll return immediately if nothing else to do
      end; {process loop}

      sysTableR.scanStop(Ttransaction(st.owner).sysStmt);
    end; {main loop}

    result:=ok;
  finally
    if sysTableR<>nil then
    begin
      sysTableR.Close;
      sysTableR.free;
      sysTableR:=nil;
    end;

    if targetr<>nil then
    begin
      targetr.free;
      targetr:=nil;
    end;

    if r<>nil then
    begin
      r.free;
      r:=nil;
    end;
  end; {try}
 except
   //log message
   //terminate;
 end;{try}
end; {copyTables}


function CatalogBackup(st:Tstmt;connection:TIdTCPConnection;targetName:string):integer;
{Copies the stmt's source catalog into a new one (compressing etc. as we go)
 Closes the target file when done.

 IN:         st               the current statement (pointing to a current source catalog)
             connection       the connection - not used (was for debugging)
             targetName       the destination catalog name

 RETURN:     ok, else fail:
               -2=target is already attached to the server (could be self!)

 Assumes:
             caller is ok with targetName being overwritten (if we find it's not open)
}
const
  routine=':CatalogBackup';
  //tempTargetName='catalog_backup_test';
  debugStampId:StampId=(tranId:MAX_CARDINAL-100;stmtId:MAX_CARDINAL-100); //todo replace with formula for max(tranId type) //Note: no need when comparing to compare stmtId
var
  targetDB:TDB;
  targetTran:TTransaction;
  tempResult,resultRowCount:integer;
begin
  result:=fail;

  //Note: in future, the target may be CSV/XML files etc. leave flexible/portable (but security issues)
  //Note: in future, the source may use an old uDatabase unit to be able read read old structures

  {Check targetName is not open}
  if (Ttransaction(st.owner).db.owner as TDBserver).findDB(targetName)<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Target database is already open on this server',vDebug);
    {$ENDIF}
    st.addError(seTargetDatabaseIsAlreadyOpen,seTargetDatabaseIsAlreadyOpenText);
    result:=-2;
    exit;
  end;

  {Create the new target database on our server}
  targetDB:=(Ttransaction(st.owner).db.owner as TDBserver).addDB(targetName);
  if targetDB<>nil then
  begin
    try
      targetTran:=TTransaction.Create;
      try
        {Note: we set these based on database.createDB so we can insert into sysTran later}
        targetTran.CatalogId:=1; //default MAIN catalog
        targetTran.AuthId:=SYSTEM_AUTHID; //_SYSTEM authId
        targetTran.AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        targetTran.SchemaId:=sysCatalogDefinitionSchemaId;
        targetTran.SchemaName:=sysCatalogDefinitionSchemaName;

        targetTran.tranRt:=MaxStampId; //avoid auto-tran-start failure
        targetTran.SynchroniseStmts(true);

        targetTran.connectToDB(targetDB); //todo check result (leave connected at end though)

        result:=targetDB.createDB(targetName,True{emptyDB}); //=>ok result
        if result=ok then
        begin
          if targetDB.openDB(targetName,True{emptyDB})=ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,'Opened new target database',vDebug);
            {$ENDIF}
            targetDB.status; //debug report
            (targetDB.owner as TDBserver).buffer.status;

            result:=copySystemTables(st,connection,targetTran,targetDB);
            if result<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,'Failed to copy system tables to new target database',vdebugError);
              {$ENDIF}
              //todo discard partial db catalog?
              exit; //abort
            end;

            {$IFDEF DEBUG_LOG}
            //targetTran.thread:=Ttransaction(st.owner).thread; //needed for debug table... remove!
            ////ExecSQL(targetTran.sysStmt,'DEBUG table sysTable',connection,resultRowCount);
            //ExecSQL(targetTran.sysStmt,'DEBUG table sysColumn',connection,resultRowCount);
            ////ExecSQL(targetTran.sysStmt,'SELECT * from sysColumn',connection,resultRowCount);
            {$ENDIF}

            {Add initial entry to sysTran to allow database to be restarted}
            tempresult:=PrepareSQL(targetTran.sysStmt,nil,
              'INSERT INTO '{'+sysCatalogDefinitionSchemaName+'.}+'sysTran VALUES (1,''N'') ');
            if tempresult=ok then tempresult:=ExecutePlan(targetTran.sysStmt,resultRowCount);
            if tempresult<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,'  Failed inserting sysTran row: ',vAssertion)
              {$ENDIF}
            else
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,'  Inserted sysTran row',vdebugMedium);
              {$ELSE}
              ;
              {$ENDIF}
            if UnPreparePlan(targetTran.sysStmt)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
              {$ELSE}
              ;
              {$ENDIF}

          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,'Failed to open new target database',vdebugError);
            {$ENDIF}
            //todo discard partial db catalog?
            result:=fail;
            exit; //abort
          end;
        end;
        result:=ok;
      finally
        //todo remove tr.rollback if not committed
        targetTran.tranRt:=InvalidStampId; //Note: assumes 'not in a transaction'=>InvalidTranId
        targetTran.SynchroniseStmts(true);
        targetTran.free; //this will disconnectFromDB etc.
      end; {try}
    finally
      (Ttransaction(st.owner).db.owner as TDBserver).removeDB(targetDB);
    end; {try}
  end;
  //else fail: log error!

  {Now re-open the new target and copy all the non-metadata rows
   Note: createInformationSchema is not called, i.e. we copy the source's information_schema}
  targetDB:=(Ttransaction(st.owner).db.owner as TDBserver).addDB(targetName);
  if targetDB<>nil then
  begin
    try
      targetTran:=TTransaction.Create;
      try
        {Note: we set these based on database.createDB so we can insert into sysTran later}
        targetTran.CatalogId:=1; //default MAIN catalog
        targetTran.AuthId:=SYSTEM_AUTHID; //_SYSTEM authId 
        targetTran.AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        targetTran.SchemaId:=sysCatalogDefinitionSchemaId;
        targetTran.SchemaName:=sysCatalogDefinitionSchemaName;

        targetTran.tranRt:=MaxStampId; //avoid auto-tran-start failure
        targetTran.SynchroniseStmts(true);

        targetTran.connectToDB(targetDB); //todo check result (leave connected at end though)
          if targetDB.openDB(targetName,False)=ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,'Re-opened new target database',vDebug);
            {$ENDIF}
            targetDB.status; //debug report
            (targetDB.owner as TDBserver).buffer.status;

            result:=copyTables(st,connection,targetTran,targetDB);
            if result<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,'Failed to copy user tables to new target database',vdebugError);
              {$ENDIF}
              //todo discard partial db catalog?
              result:=fail;
              exit; //abort
            end;

            {Now recreate any indexes for [sysTableId, sysColumnId, sysIndexId, sysIndexColumnId]
             These will have different table_id's to the ones in the source catalog.
             (we need to do it after user tables are copied because we need sysGenerator (etc?)
              - no downside? user table copy shouldn't be any slower? except opening target relations might be slow...)
            }
            if targetDB.createSysIndexes(targetTran.sysStmt)<ok then //creates indexes for sysTable, sysColumn, sysIndex, sysIndexColumn (returns last index_id)
            begin
              {$IFDEF DEBUG_LOG}
              log.add(targetTran.sysStmt.who,where+routine,'Failed to rebuild system indexes on new target database',vdebugError);
              {$ENDIF}
              //todo discard partial db catalog?
              result:=fail;
              exit; //abort
              //todo!! carry on?
            end;
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(targetTran.sysStmt.who,where+routine,'Failed to re-open new target database',vdebugError);
            {$ENDIF}
            //todo discard partial db catalog?
            result:=fail;
            exit; //abort
          end;
      finally
        targetTran.free; //this will disconnectFromDB etc.
      end; {try}
    finally
      {We disconnect the pristine backup from the server, i.e. offline it}
      (Ttransaction(st.owner).db.owner as TDBserver).removeDB(targetDB);
    end; {try}
  end;
  //else fail: log error!
end; {CatalogBackup}


end.

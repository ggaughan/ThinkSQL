unit uProcessor;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Command processor
 Takes a syntax tree, prepares it for execution and then executes it
 via one of the Create... routines.
 The process routines navigate the syntax tree and either:
 1) execute it there and then
 2) check the structure and pass it to the query optimiser
 ?...

 Query executive - calls top iterator

 //todo Make the Processor a separate class & create one per connection/transaction?

 //todo split this unit into smaller pieces:
 //     especially since many of the routines deal with create/drop objects etc.

 //     will need to use another stmt instead of sysStmt if any are not executed as _SYSTEM
 //     because constraint checks will need sysStmt. See db.createInfoSchema for workaround.
}

//{$IFNDEF DEBUG_LOG}
  //  {$DEFINE DISALLOW_CASCADE_UPDATES}    
//{$ENDIF}

//{$DEFINE DEBUGDETAIL}  //debug detail
//{$DEFINE DEBUGDETAIL2}  //debug detail (privilege related)
//{$DEFINE DEBUGDETAIL3}  //debug detail (constraint related)
//{$DEFINE DEBUGDETAIL4}  //debug detail (index building related)

//{$DEFINE IGNORE_USER_CREATEINDEX} //remove when live: only for debug

{$IFDEF DEBUG_LOG}
  //  {$DEFINE LARGE_COLIDS}  //set new col ids to 1000+position (debug subscript/ref confusion errors)
                            //Note: this needs extra bit space for match arrays etc.
{$ENDIF}

interface

uses uTransaction, uStmt, uSyntax, uTuple, uIterator, uAlgebra, uGlobal, IdTCPConnection, uIndexFile;

function CreateIndex(st:Tstmt;nroot:TSyntaxNodePtr;schema_id:integer;
                     indexName:string; origin:string; constraintId:integer; owner:TObject; ownerIndexFile:TIndexFile; ownerCref:integer):integer;

function CheckTableColumnPrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                                   do_authId_level_match:boolean;var authId_level_match:boolean;
                                   ownerAuth_id:integer;table_id:integer;column_id:integer; var table_level_match:boolean;
                                   privilege_type:TprivilegeType;grant_option_search:boolean;var grant_option:string):integer;
function CheckRoutinePrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                               do_authId_level_match:boolean;var authId_level_match:boolean;
                               ownerAuth_id:integer;routine_id:integer;
                               privilege_type:TprivilegeType;grant_option_search:boolean;var grant_option:string):integer;

function CreateCallRoutine(st:Tstmt;nroot:TSyntaxNodePtr;subSt:TStmt;functionCall:boolean):integer;
function CreateTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
function CreateJoinTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
function CreateTableRef(st:Tstmt;sparent:TSyntaxNodePtr;useRightChild:boolean;var aroot:TAlgebraNodePtr):integer;
function CreateNonJoinTablePrimary(st:Tstmt;sparent:TSyntaxNodePtr;useRightChild:boolean;var aroot:TAlgebraNodePtr):integer;
function CreateNonJoinTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
function CreateNonJoinTableTerm(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
function CreateTableTerm(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
function CreateTablePrimary(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;

function RowSubquery(st:TStmt;planRoot:TIterator;tuple:TTuple):integer;

function PrepareAndExecutePlan(stmt:Tstmt;iter:TIterator;var rowCount:integer):integer;
function PreparePlan(stmt:Tstmt;iter:TIterator):integer;
function ExecutePlan(stmt:Tstmt;var rowCount:integer):integer;
function UnPreparePlan(stmt:Tstmt):integer;

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  SysUtils, uRelation, uServer,
  uOptimiser, uCondToCNF, uParser {for ExecSQL}, uDatabase {for create catalog},
  uIterStmt,
  uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
  uHashIndexFile, uConstraint, IdTCPServer {for connection handle via tr.thread},
  uRoutine, uVariableSet, uEvalCondExpr, uIterInto{for dynamic fetch},
  uDatabaseMaint, uPage{debug only}
  ,uConnectionMgr{for access to TCMthread for shutdown check},
  uGarbage
  ,uEvsHelpers
  ;

const
  where='uProcessor';
  who='';

{Enable mutual recursion:}
function CreateSelectExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer; forward;

{Create}
function CreateIndex(st:Tstmt;nroot:TSyntaxNodePtr;schema_id:integer;
                     indexName:string; origin:string; constraintId:integer; owner:TObject; ownerIndexFile:TIndexFile; ownerCref:integer):integer;
{Create an index
 IN:
           tr             transaction
           st             statement
           nroot          pointer to list of column-ref nodes (use nil/may not be used if ownerIndexFile<>nil or ownerCref<>0)
           schema_id      caller is responsible for providing since there's no
                          stand-alone index creation (except maybe in future)
           indexName      name for the new index ('' => create a unique one here)
           origin         index origin, e.g. ioSystemConstraint
           constraintId   constraintId FK if index origin = ioSystemConstraint,
                          else pass 0=>null = ignore
           owner          reference to owning object: Trelation required
           ownerIndexFile owning object index file to use as template (e.g. index rebuild based on existing index)
           ownerCref      owning object subscript
                            indicates current column-ref (0=table-level index & therefore use nroot list of columns instead)
                            //todo: if no more are used name this column_ref!

 RETURNS:  >0 = Ok & value = index_id
           else Fail

 Assumes:
   column list (if specified) is in sequence order
   Index is valid, i.e. caller must check that another primary key does not already exist etc.

 Note:
   initially created for calling from createConstraint, but this routine
   will be called for future index creation.
   Actually called to create single or multiple column indexes or index copies, according to parameters.

   allows safe concurrent on-line building/rebuilding by:
     flagging the unfinished index as 'beingBuilt' & adding it to the catalog for new statements to pick up
     adding the unfinished index to any appropriate open relations to catch any mid-build modifications
     index (will:todo!) tracks latest RID added & can determine whether to adjust or ignore concurrent updates

 //todo: allow passing of name, e.g. constraint name

 //todo: really should be a Trelation method?
 //      which should then call a TIndex method?
}
const routine=':CreateIndex';
var
  IndexId,genId:integer;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  nChildColumn:TSyntaxNodePtr;

  table_id:integer;

  //used for parent/child column lookup
  cId:TColId;
  cRef,parentCref:ColRef;

  cTuple:TTuple;  //todo make global?

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;

  tempResult:integer;

  i:ColRef;

  iNew:TIndexFile;

  noMore:boolean;
  noMoreSt:boolean;
  otherTr:TObject; {TTransaction}
  otherSt:TStmt;

  constraintIdorNull:string;
begin
  result:=Fail; //can't rely on this since we re-assign to sub-routine result below

  nChildColumn:=nil;

  table_id:=(owner as Trelation).tableId;

  //todo check it doesn't already exist (in this schema?)! maybe a future primary key will prevent this...
  //todo: here and other sys-creation places: probably need a setSavepoint...finally rollback to savepoint/commit
  //                                          to ensure these actions are atomic
  genId:=0; //lookup by name
  tempResult:=(Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysIndex_generator',genId,IndexId);
  if tempResult<>ok then
    exit; //abort

  {If no index name was given explicitly, we create a unique one now}
  if IndexName='' then
  begin
    //todo define (& document) format elsewhere, i.e. use a getUnique..() function
    IndexName:='anon_index_'+intToStr(indexId);
    //todo: for now, need to incorporate owner info,
    //      e.g. test_index_43 is better than anon_index_43
  end;

  {Create the index file to attach to the relation}
  iNew:=THashIndexFile.Create; //todo: pass index type from caller: hash is currently default for PKs etc.
  try
    iNew.indexState:=isBeingBuilt;
    iNew.indexId:=IndexId;
    {Set index column mappings onto the relation column refs}
    iNew.colCount:=0;
    if nroot<>nil then
    begin //we have an explicit list
      {$IFDEF DEBUG_LOG}
      {$IFDEF DEBUGDETAIL4}
      log.add(st.who,where+routine,format('  template=explicit column list',[nil]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      nChildColumn:=nroot;
      while nChildColumn<>nil do
      begin
        //note: todo: check in caller!  //caller should have already checked these, so we can expect no failures!
        (owner as Trelation).fTuple.FindCol(nil,nChildColumn.idval,'',nil,cTuple,cRef,cid);
        if cid=InvalidColId then
        begin
          //this should have been caught before now!!!
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown column reference (%s)',[nChildColumn.idVal]),vAssertion); //todo debug/user error here?
          {$ENDIF}
          result:=Fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
          exit; //abort, no point continuing
        end;
        //todo if any result<>0 then quit
        {Note: we don't use cTuple, we just used FindCol to find our own id,
         never to find a column source}
        //todo: I'm not sure why/if we need this check here, especially since owner can't be a view (but it's just an assertion...)
        if cTuple<>(owner as Trelation).fTuple then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@(owner as Trelation).fTuple]),vAssertion);
          {$ENDIF}
          //todo **** resultErr - or catch earlier with result=-2 = ambiguous
          result:=fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
          exit;
        end;
        {Ok, insert the reference}
        iNew.colCount:=iNew.colCount+1;
        iNew.ColMap[iNew.colCount].cRef:=cRef;
        iNew.ColMap[iNew.colCount].cid:=cid;

        nChildColumn:=nChildColumn.nextNode;
      end; {while}
    end
    else //we have an implied (single) column or a template to copy from
    begin
      if ownerIndexFile=nil then
      begin
        {$IFDEF DEBUG_LOG}
        {$IFDEF DEBUGDETAIL4}
        log.add(st.who,where+routine,format('  template=implied single column',[nil]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        //todo may be neater to code this as a sub-function, since we call it twice
        {Ok, insert the reference}
        iNew.colCount:=iNew.colCount+1;
        iNew.ColMap[iNew.colCount{=1}].cref:=ownerCref;
        iNew.ColMap[iNew.colCount{=1}].cid:=(owner as Trelation).fTuple.fColDef[ownerCref].id;
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        {$IFDEF DEBUGDETAIL4}
        log.add(st.who,where+routine,format('  template=existing index',[nil]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        {Copy the index structure from the one passed as a template (assumes for same relation!)}
        iNew.colCount:=ownerIndexFile.colCount;
        for i:=1 to iNew.colCount do
        begin
          iNew.ColMap[i].cref:=ownerIndexFile.ColMap[i].cref;
          iNew.ColMap[i].cid:=ownerIndexFile.ColMap[i].cid;
        end;
      end;
    end;

    {Call relation to create and link the index file}
    //todo pre-allocate block! especially if caller knows size of old index in case of rebuild
    tempResult:=(owner as Trelation).createNewIndex(st,iNew,indexName);
    if tempResult<>ok then exit; //abort

    {Add the unfinished entry to the catalog now so future statements will pick up & maintain the new index}
    {Note: although we don't commit this, the relation's index opening routines will read-uncommitted}
    {      (so we could just use the fact that the index entry=uncommitted to mean unfinished instead of an explicit flag!?)}
    {Note: in future this next sys catalog bit might be put into the tRelation.CreateNewIndex routine}
    {We need to insert as _SYSTEM to ensure we have permission on sysIndex (plus is quicker since _SYSTEM has ownership rights)}
    //Note: caller probably already set this, since we are only ever a sub-creation... but carry on anyway...
    if constraintId=0 then
      constraintIdorNull:='null'{todo 0 is safer?}
    else
      constraintIdorNull:=intToStr(constraintId);
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
      tempResult:=ExecSQL(tempStmt,
        format('INSERT INTO %s.sysIndex (index_id,'+
                                        'index_name,'+
                                        'table_id,'+
                                        'index_type,'+
                                        'index_origin,'+
                                        'constraint_id,'+
                                        'file,'+
                                        'first_page,'+ //todo: fix: crippled to integer!
                                        'status'+
                                        ' ) '+
               'VALUES (%d,''%s'',%d,''%s'',''%s'',%s,''%s'',%d,%d); ',
               [sysCatalogDefinitionSchemaName,
                IndexId,IndexName,table_id,itHash,origin,constraintIdorNull,indexName,iNew.startPage,ord(iNew.indexState{=isBeingBuilt})])   //todo: itHash is default for FKs: pass in from caller!
               ,nil,resultRowCount);
      //todo if <>ok copy tempStmt errors to st?
      if tempResult<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysIndex row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
        {$ENDIF}
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysIndex',[resultRowCount]),vdebug);
        {$ENDIF}
        //todo assert resultRowCount=1?

        //todo need to make this + column detail below atomic!
        // - for starters, we don't overwrite the result that we set here...
      end;

      {Next add index column(s)}
      for i:=1 to iNew.colCount do
      begin
        //todo maybe better/more efficient to build a single statement for all column entries
        // - easier to rollback, faster (much less parsing),
        //   and could maybe build/prepare earlier during initial checks = neater code!?

        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
        tempResult:=ExecSQL(tempStmt,
          format('INSERT INTO %s.sysIndexColumn (index_id,'+
                                                'column_id,'+
                                                'column_sequence'+
                                                ' ) '+
                 'VALUES (%d,%d,%d); ',
                 [sysCatalogDefinitionSchemaName,
                  IndexId,iNew.ColMap[i].cid,i{start sequence at 1}])
                 ,nil,resultRowCount);

        if tempResult<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed inserting sysIndexColumn row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
          {$ENDIF}
          //todo return fail?
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Inserted %d entries into sysIndexColumn',[resultRowCount]),vdebug);
          {$ENDIF}
          //todo assert resultRowCount=1?
        end;
      end;

    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}

    {Link this index to all open relations for this table to ensure we capture all concurrent changes}
    //todo: prevent race: new relation reads index from catalog, and we might add it also next
    //  i.e. check index_id does not exist already before adding below:
    tempResult:=(Ttransaction(st.owner).db).TransactionScanStart; //Note: this protects us from the transaction we find from disappearing!
    if tempResult<>ok then exit; //abort
    try
      noMore:=False;
      while not noMore do
      begin
        if (Ttransaction(st.owner).db).TransactionScanNext(otherTr,noMore)<>ok then exit;
        if not noMore then
          with (otherTr as TTransaction) do
          begin
            {Now scan this transaction's statement list
             Note: this checks sysStmt just in case (since it's in the stmtList)}
            {Loop through all this transaction's statements
             Note: this logic is copied from uStmt.exists - todo: in future use a class to hide this detail!
            }
            tempResult:=StmtScanStart; //Note: this protects us from the stmt we find from disappearing!
            if tempResult<>ok then exit; //abort
            try
              noMoreSt:=False;
              while not noMoreSt do
              begin
                if StmtScanNext(otherSt,noMoreSt)<>ok then exit;
                if not noMoreSt then
                begin
                  if (otherTr=Ttransaction(st.owner)) and (otherSt=st) then
                  begin //this is us, so skip it
                    //todo maybe we should use this & avoid passing in ownerRef:
                    //  i.e. find the owner in passing through this list and so remove it as a special case
                    //  - although, the call does need to be different to create the actual index - so ignore this!
                    {$IFDEF DEBUG_LOG}
                    {$IFDEF DEBUGDETAIL4}
                    log.add(st.who,where+routine,format('  Found a stmt (%s) (status=%d) modifying the same tableId - was ourself so already uses the new index (%d)',[otherSt.who,ord(otherSt.status),indexId]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    continue;
                  end;

                  {If this statement is an active data manipulation statement, then
                   check if the relation it updates is the same as the one our (new) index is for}
                  if (otherSt.planActive) then //todo and (otherStmtNode^.sp.status=ssActive) ?
                    if otherSt.sroot<>nil then
                      if otherSt.sroot.ptree<>nil then
                        if otherSt.sroot.ptree is TIterStmt then
                          if (otherSt.sroot.ptree as TIterStmt{could use Titerator here}).anodeRef.rel.tableId=table_id then
                          begin
                            {This stmt needs to maintain our new index immediately}
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('  Found a concurrent stmt (%s) (status=%d) modifying the same tableId so will attach this new index (%d)',[otherSt.who,ord(otherSt.status),indexId]),vDebugMedium);
                            log.add(st.who,where+routine,format('    %s',[otherSt.InputText]),vDebugLow);
                            {$ENDIF}

                            {Call the relation to link a clone of the index file}
                            //todo: cross thread meddling: protect the relation's index list!
                            if (otherSt.sroot.ptree as TIterStmt{could use Titerator here}).anodeRef.rel.LinkNewIndex(st,indexId,itHash,origin,constraintId,indexName,iNew.startPage,iNew.indexState)=nil then exit; //abort //todo too strong? dare we continue?
                          end;
                end;
              end; {while}
            finally
              tempResult:=StmtScanStop; //todo check result
            end; {try}
          end; {with}
      end; {while}
    finally
      tempResult:=(Ttransaction(st.owner).db).TransactionScanStop; //todo check result
    end; {try}


    {Start the index build, i.e. add all existing tuples (if any) to this new index}
    tempResult:=(owner as Trelation).ScanAlltoIndex(st,iNew);
    if tempResult<>ok then exit; //abort

  finally
    if tempResult<>ok then begin iNew.free; iNew:=nil; end; //else will be freed by relation
  end; {try}

  if tempResult<>ok then exit; //abort

  {Now update the catalog entry and set the status to 'ok' so it can be used for scanning etc.
   Note: it will be picked up & used immediately by new statements! todo: what if rebuild caller then rollsback?}
  //todo: could also update initial stats here...
  {Note: in future this next sys catalog bit might be put into the tRelation.ScanAlltoIndex routine}
  {We need to insert as _SYSTEM to ensure we have permission on sysIndex (plus is quicker since _SYSTEM has ownership rights)}
  //Note: caller probably already set this, since we are only ever a sub-creation... but carry on anyway...
  saveAuthId:=Ttransaction(st.owner).AuthId;
  saveAuthName:=Ttransaction(st.owner).AuthName;
  Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
  Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
  try
    Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
    tempResult:=ExecSQL(tempStmt,
      format('UPDATE %s.sysIndex SET '+
                                'status=%d'+
             'WHERE index_id=%d;',
             [sysCatalogDefinitionSchemaName,
              ord(isOk{since we've finished creating it}),IndexId])
             ,nil,resultRowCount);
    if tempResult<>ok then
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'  Failed updating sysIndex row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
      {$ENDIF}
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Updated %d entries in sysIndex',[resultRowCount]),vdebug);
      {$ELSE}
      ;
      {$ENDIF}
      //todo assert resultRowCount=1?

      iNew.indexState:=isOk; //flag as built //Note: other concurrent users who have been notified of this
                             // index will not be told it's built. They will find out when they run another statement
                             //Note: this was necessary after creating a new catalog & using it straight away:
                             //      system indexes wouldn't be available...

      //todo need to make this + column detail below atomic!
      // - for starters, we don't overwrite the result that we set here...
    end;
  finally
    Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
    Ttransaction(st.owner).AuthName:=saveAuthName;
  end; {try}

  result:=IndexId; //return success & indexId for caller to reference

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defined %s',[IndexName]),vDebugLow);
  {$ENDIF}
end; {CreateIndex}

function CreateConstraint(st:Tstmt;nroot:TSyntaxNodePtr;schema_id:integer;
                          ownerRoot:TSyntaxNodePtr; owner:TObject; ownerCref:integer):integer;
{Create a constraint
 IN:
           tr          transaction
           st          statement
           nroot       pointer to ntConstraintDef node
           schema_id   caller is responsible for providing since there's no
                       stand-alone constraint creation (except Assertions which will have their
                                                        own createAssertion caller routine)
                       + we do now allow schema prefixes so we assert that the schema_id passed matches any explicit one
           ownerRoot   pointer to caller's root node
                       this is used to determine whether the constraint type is valid or not
                       e.g. if ownerRoot=ntCreateDomain then only rtCheck is allowed, rest are rejected
           owner       reference to owning object
                         Trelation required if:
                                constraint is foreign-key/references - need to check child-column def(s)
                         //todo: if no more are used make this a Trelation parameter!
                         else can be nil
           ownerCref   owning object subscript
                       required if:
                                owner is Trelation, indicates current column-ref (0=table-level constraint & therefore foreign-key-def rather than references-def)
                         //todo: if no more are used name this column_ref!
                         else can be -1  //todo use 'bad/missing/null' constant

 RETURNS:  >0 = Ok & value = constraint_id
           -2 = unknown catalog
           -3 = unknown schema
           -4 = constraint name already exists
           else Fail

 Side-effects:
   Will also create an index for:
        primary key definitions
        unique definitions
        foreign key child definitions (used for integrity check/cascade when delete/update parent)
        //todo keep this list up to date!

   Will also add an entry in sysTableColumnConstraint for the parent of a
   Foreign Key constraint (caller will do child upon success) - so iterDelete
   can pick up referencing constraints for restrict/cascade checking.


 Assumes:
   tr.authId is original, and has not been temporarily bumped to _SYSTEM by caller
   to ease insertion etc.
   We need the original authId in this routine to check FK reference privileges.
   //todo: maybe faster (since caller bump-back needs try..finally) to pass original
           authId as an extra parameter?

 Note:
   initially created for calling from createDomain, but this routine
   will be called for all constraint nodes. This routine will reject any that
   aren't appropriate.

   Adding constraints such as unique, primary-key and foreign-key are good suggestions
   for future indexes (and for optimiser hints). Currently no indexes are assumed:
   the constraints are purely logical. (except for isUnique tests...)
   In future, I think the server should handle all index creation automatically, and
   it will add them to speed up insert/update/delete constraint-checking as well
   as select-searching as an important side-effect.

   Keep in sync. with constraint.check routine.
}
const routine=':CreateConstraint';
var
  n,n2,nParentColumn,nChildColumn,nConstraint,nDef:TSyntaxNodePtr;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  dummy_null:boolean;

  ConstraintName:string;
  ConstraintId,genId:integer;
  deferrable,initially_deferred:string[1];
  rule_type:TconstraintRuleType;
  rule_check:string;
  FK_parent_table_id:integer;
  child_table_id:integer;
  FK_match_type:TconstraintFKmatchType;
  FK_on_update_action,FK_on_delete_action:TconstraintFKactionType;

  //used for parent table lookup
  r:TRelation;
  isView:boolean;
  viewDefinition:string;
  name:string;
  //for parent default primary key lookup
  ParentConstraintId:integer;
  dummy_integer:integer;
  dummy_string:string;
  sysTableColumnConstraintR:TObject; //Trelation
  sysConstraintR:TObject; //Trelation
  sysConstraintColumnR:TObject; //Trelation
  columnId:integer;

  //used for parent/child column lookup
  cId:TColId;
  cRef,parentCref:ColRef;

  cTuple:TTuple;  //todo make global?

  {for references privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;

  colCount:integer;

  tempResult:integer;

  i:integer;
  tempInt,tempInt2:integer;
  s,s2,sQuotesOk:string;

  tempStmt:TStmt;

  catalog_id:TcatalogId;
  check_schema_id:TschemaId;
  auth_id:TauthId;
begin
  result:=Fail; //can't rely on this since we re-assign to sub-routine result below
  n:=nroot;

  nConstraint:=nil;
  nDef:=nil;
  nParentColumn:=nil;
  nChildColumn:=nil;

  if nroot.ntype<>ntConstraintDef then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntConstraintDef',vAssertion);
    {$ENDIF}
    exit;
  end;

  if n.leftChild<>nil then
  begin
    tempResult:=getOwnerDetails(st,n.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,s,check_schema_id,s2,auth_id);
    if tempResult<>ok then
    begin  //couldn't get access to sysSchema
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed to find schema',[nil]),vDebugLow);
      {$ENDIF}
      result:=tempResult;
      case result of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      end; {case}
      exit; //abort
    end;

    ConstraintName:=n.leftChild.rightChild.idVal;

    {Prevent cross-schema constraints} //todo: check standard spec. ok?
    if check_schema_id<>schema_id then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Schema reference %d does not match owner %d',[check_schema_id,schema_id]),vDebugLow);
      {$ENDIF}
      st.addError(seSyntaxInvalidSchema,format(seSyntaxInvalidSchemaText,[s2]));
      result:=-4;
      exit; //abort
    end;
  end
  else
  begin
    ConstraintName:=''; //anonymous - we'll use the constraint_id to auto-name it later...
    //todo? catalog_Id:=;
  end;

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining %s',[ConstraintName]),vDebug);
  {$ENDIF}

  {First ensure that the constraintName is unique for this schema
   - only needed if <>'' since system generated are guaranteed unique}
  if ConstraintName<>'' then
  begin //user specified name
    tempInt2:=0; //not found
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraint,sysConstraintR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysConstraintR,ord(sco_constraint_name),ConstraintName)=ok then
          try
          repeat
          {Found another matching constraint for this name}
          with (sysConstraintR as TRelation) do
          begin
            fTuple.GetInteger(ord(sco_Schema_id),tempInt,dummy_null);
            if tempInt=schema_Id then
            begin
              fTuple.GetInteger(ord(sco_constraint_Id),tempInt2,dummy_null);
              //already got constraintName
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found constraint %s in %s (with constraint-id=%d)',[s,sysConstraint_table,tempInt2]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              //...will abort below
            end;
            //else not for our schema - skip & continue looking
          end; {with}
          until (tempInt2<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysConstraintR,ord(sco_constraint_name),ConstraintName)<>ok);
                //todo stop once we've found a constraint_id with our schema_Id, or there are no more matching this name
          finally
            if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysConstraintR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysConstraint)]),vError); //todo abort?
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        //else constraint not found
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysConstraint,sysConstraintR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysConstraint)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysConstraint
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysConstraint),ConstraintName]),vDebugError); //todo assertion?
      {$ENDIF}
      st.addError(seFail,seFailText);
      result:=fail;
      exit; //abort
    end;

    if tempInt2<>0 then
    begin //found already
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Constraint already exists',[nil]),vDebugLow);
      {$ENDIF}
      st.addError(seSyntaxConstraintAlreadyExists,seSyntaxConstraintAlreadyExistsText);
      result:=-4;
      exit; //abort
    end;
  end;
  //else name will be unique

  r:=nil; //parent reference relation for FK lookup

  try
    {defaults}
    deferrable:=No;  //this default may be overridden if initially deferred is specified
    initially_deferred:=No;
    rule_type:=rtCheck;
    rule_check:=''; //todo use null
    FK_parent_table_id:=0; //todo use null
    child_table_id:=0; //todo use null
    FK_match_type:=mtSimple; //todo use null
    FK_on_update_action:=raNone; //todo use null
    FK_on_delete_action:=raNone; //todo use null

    //todo check it doesn't already exist! maybe a future primary key will prevent this...
    //todo: here and other sys-creation places: probably need a setSavepoint...finally rollback to savepoint/commit
    //                                          to ensure these actions are atomic
    genId:=0; //lookup by name
    result:=(Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysConstraint_generator',genId,ConstraintId);
    if result<>ok then
      exit; //abort

    {If no constraint name was given explicitly, we create a unique one now}
    if ConstraintName='' then
    begin
      //todo: for now, need to incorporate more owner info,
      //      e.g. prefix with table/domain name

      case ownerRoot.ntype of
        ntCreateDomain: ConstraintName:='domain';

        ntCreateTable,
        ntAlterTable:  ConstraintName:='table';
      else
        ConstraintName:='anon'; //prefix default
      end;
      //todo define (& document) format elsewhere, i.e. use a getUnique..() function
      ConstraintName:=ConstraintName+'_constraint_'+intToStr(ConstraintId);
    end;

    nConstraint:=n.rightChild; //note: we will do this further throughout this routine, so leave nConstraint alone!

    {Get any constraint deferral options}
    if nConstraint.nextNode<>nil then
    begin
      n2:=nConstraint.nextNode;
      if n2.nType in [ntInitiallyDeferred,ntInitiallyImmediate] then
      begin //we have deferral information
        case n2.nType of
          ntInitiallyDeferred:  begin initially_deferred:=Yes; deferrable:=Yes; end;
          ntInitiallyImmediate: begin initially_deferred:=No; deferrable:=No; end;
        (*todo leave other types for later, e.g. onUpdate action
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown constraint initial deferral option type %d',[ord(n2.nType)]),vAssertion);
          {$ENDIF}
          result:=Fail;
          exit;
        *)
        end; {case}
        if n2.leftChild<>nil then
          case n2.leftChild.nType of
            ntDeferrable:    deferrable:=Yes;
            ntNotDeferrable: deferrable:=No;
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown constraint deferral option type %d',[ord(n2.leftChild.nType)]),vAssertion);
            {$ENDIF}
            result:=Fail;
            exit;
          end; {case}

        {Sense check}
        if (initially_deferred=Yes) and (deferrable=No) then
        begin
          {$IFDEF DEBUG_LOG}
          {Note: we still need the log.add before addError calls so we know where the error came from}
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(seSyntaxInvalidConstraintText,[nil]),vError);
          {$ENDIF}
          st.addError(seSyntaxInvalidConstraint,seSyntaxInvalidConstraintText); //todo? make more explicit
          result:=Fail;
          exit;
        end;
        //todo: note: there may be others cases
        //      e.g. where deferrable makes no sense, e.g. see footnote on P217 of A Guide SQL (4th ed.)
      end; {deferrals}
    end;

    {Get constraint type and appropriate details}
    case nConstraint.nType of
      ntUnique,ntUniqueDef,
      ntPrimaryKeyDef,ntPrimaryKey:
      begin
        if ownerRoot.ntype=ntCreateDomain then
        begin
          {$IFDEF DEBUG_LOG}
          {Note: we still need the log.add before addError calls so we know where the error came from}
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(seSyntaxInvalidConstraintText,[nil]),vError);
          {$ENDIF}
          st.addError(seSyntaxInvalidConstraint,seSyntaxInvalidConstraintText);
          result:=Fail;
          exit;
        end;
        if owner=nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Need an owner relation passing for PK/unique constraint',[nil]),vAssertion);
          {$ENDIF}
          result:=Fail; //abort
          exit;
        end;

        if nConstraint.nType in  [ntUnique,ntUniqueDef] then
          rule_type:=rtUnique
        else
          rule_type:=rtPrimaryKey;

        if nConstraint.nType in [ntUniqueDef,ntPrimaryKeyDef] then
        begin
          nDef:=nConstraint.leftChild; //save pointer to child column list //Note: guaranteed not nil by syntax
          //from now on, this is treated as a ntUnique/ntPrimaryKey... only difference is nDef<>nil and ownerCref is ignored
          //todo: note: may as well use ntUniqueDef/ntPrimaryKeyDef for ntUnique/ntPrimaryKey in grammar
        end
        else
        begin
          //single column child is found via ownerCref
          if ownerCref=-1 then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Need an owner column reference passing for PK/unique reference constraint',[nil]),vAssertion);
            {$ENDIF}
            result:=Fail; //abort
            exit;
          end;
        end;

        child_table_id:=(owner as Trelation).tableId;

        //todo: if rtPrimaryKey, reject if one already exists for this table!
        // also if any existing key matches/covers this one...

        //todo: for nDef=nil, create dummy syntax node for implied column-ref?
        nChildColumn:=nDef;
        while nChildColumn<>nil do
        begin
          (owner as Trelation).fTuple.FindCol(nil,nChildColumn.idval,'',nil,cTuple,cRef,cid);
          if cid=InvalidColId then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown column reference (%s)',[nChildColumn.idVal]),vError); //todo debug/user error here?
            {$ENDIF}
            st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nChildColumn.idVal]));
            result:=Fail;
            exit; //abort, no point continuing
          end;
          //todo if any result<>0 then quit
          {Note: we don't use cTuple, we just used FindCol to find our own id,
           never to find a column source}
          //todo: I'm not sure why/if we need this check here, especially since owner can't be a view (but it's just an assertion...)
          if cTuple<>(owner as Trelation).fTuple then //todo =speed
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@(owner as Trelation).fTuple]),vAssertion);
            {$ENDIF}
            //todo **** resultErr - or catch earlier with result=-2 = ambiguous
            result:=fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
            exit;
          end;

          //todo check [NOT] (owner as TRelation).fTuple.fColDef[cRef]. allows null...? depending on nConstraint.nType

          nChildColumn:=nChildColumn.nextNode;
        end; {while}
      end; {ntUnique,ntUniqueDef,ntPrimaryKeyDef,ntPrimaryKey}

      ntForeignKeyDef,ntReferencesDef:
      begin
        {ntForeignKeyDef has child column list -> references must have matching column list
         ntForeignKeyDef links to ntReferencesDef}
        if ownerRoot.ntype=ntCreateDomain then
        begin
          {$IFDEF DEBUG_LOG}
          {Note: we still need the log.add before addError calls so we know where the error came from}
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(seSyntaxInvalidConstraintText,[nil]),vError);
          {$ENDIF}
          st.addError(seSyntaxInvalidConstraint,seSyntaxInvalidConstraintText);
          result:=Fail;
          exit;
        end;
        if owner=nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Need an owner relation passing for FK constraint',[nil]),vAssertion);
          {$ENDIF}
          result:=Fail; //abort
          exit;
        end;

        rule_type:=rtForeignKey;

        if nConstraint.nType=ntForeignKeyDef then
        begin
          nDef:=nConstraint.leftChild; //save pointer to child column list //Note: guaranteed not nil by syntax
          //from now on, this becomes a ntReferencesDef... only difference is nDef<>nil and ownerCref is ignored
          nConstraint:=nConstraint.rightChild; //move down to ntReferencesDef
        end
        else
        begin
          //single column child is found via ownerCref
          if ownerCref=-1 then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Need an owner column reference passing for FK reference constraint',[nil]),vAssertion);
            {$ENDIF}
            result:=Fail; //abort
            exit;
          end;
        end;

        child_table_id:=(owner as Trelation).tableId;

        n2:=nConstraint;
        {Left child is table reference, right child is optional parent column list (default=primary key)}
        {Find parent table}
        r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation

        n2:=n2.leftChild; //todo assert if fail!
        if n2.rightChild<>nil then
        begin
          name:=n2.rightChild.idVal; //table name //todo take account of schema!
          //todo add any specified catalog/schema prefix!
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Missing table name',vError);
          {$ENDIF}
          result:=fail;
          exit;
        end;
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('  Referencing table node %s',[name]),vDebug);
        {$ENDIF}
        {Try to open this relation so we can check the column refs (and get their id's)}
        //todo: quicker/neater to use catalog lookups direct to find specified columns in the table?
        //      we're not in a great rush here, so safer/simpler is better for now...
        //      - if we keep this lookup method, ensure relation.open doesn't incure any great/unecessary overhead
        //+: we need to ensure the referenced columns are a primary/candidate key
        //   else cannot FK reference to it. So, look up key columns in sysConstraint tables
        if r.open(st,n2.leftChild,'',name,isView,viewDefinition)=ok then
        begin
          if isView then
          begin
            result:=-4; //view not allowed here
            st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
            exit; //abort
          end;

          FK_parent_table_id:=r.tableId;

          {If no parent column references were explicitly given we default to the primary key
           so build syntax nodes for the primary key column(s) here to simplify the checking algorithm...}
          //todo: this is very long-winded and very nested and copied more or less from uConstraint: use a sub-routine!
          //      sysTableColumnConstraint->sysConstraint->sysConstraintColumn

          //todo: note: even if columns were explictly given we must check (here?)
          //      that they are either unique or primary key of the parent table
          //      (++ and the key is not deferrable!)
          //      else fail
          //todo+: this is also important for cascade/restrict dropping of constraints later

          if nConstraint.rightChild=nil then
          begin
            nParentColumn:=nil; //start of artificial syntax node column chain
            {Find the primary key constraint}
            if Ttransaction(st.owner).db.catalogRelationStart(st,sysTableColumnConstraint,sysTableColumnConstraintR)=ok then
            begin
              try
                //todo: assumes we have best index/hash on stc_table_id, but may not be the case
                if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),FK_parent_table_id)=ok then
                  try
                    repeat
                      {Found another matching table id}
                      with (sysTableColumnConstraintR as TRelation) do
                      begin
                        fTuple.GetInteger(ord(stc_column_id),columnId,dummy_null);
                        begin //table-level match found
                          {Lookup the constraint to see if it's the Primary Key}
                          fTuple.GetInteger(ord(stc_constraint_id),ParentConstraintId,dummy_null);
                          if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraint,sysConstraintR)=ok then
                          begin
                            try
                              if Ttransaction(st.owner).db.findCatalogEntryByInteger(st,sysConstraintR,ord(sco_constraint_id),ParentConstraintId)=ok then
                              begin
                                with (sysConstraintR as TRelation) do
                                begin
                                  {$IFDEF DEBUGDETAIL3}
                                  {$IFDEF DEBUG_LOG}
                                  log.add(st.who,where+routine,format('Found constraint %d',[ParentConstraintId]),vDebugLow);
                                  {$ENDIF}
                                  {$ENDIF}

                                  fTuple.GetString(ord(sco_deferrable),dummy_string,dummy_null); //note: we use this later!
                                  fTuple.GetInteger(ord(sco_rule_type),dummy_integer,dummy_null);
                                  if TconstraintRuleType(dummy_integer)=rtPrimaryKey then //todo protect cast from garbage!
                                  begin //we've found the primary key, so read the constraint columns
                                    {First check the PK is not deferrable:
                                     this is in the standard & prevents nasty deferred cascading actions}
                                    //done: todo: also must be not-deferrable (SQL/3 at least) but that should be checked/enforced when creating primary key?
                                    if dummy_string=Yes then
                                    begin
                                      {$IFDEF DEBUG_LOG}
                                      log.add(st.who,where+routine,format('Referenced table (%s) primary key is deferrable, so cannot be referenced by a foreign key',[name]),vError); //todo debug/user error here?
                                      {$ENDIF}
                                      st.addError(seSyntaxDeferrableParentPrimaryKey,format(seSyntaxDeferrableParentPrimaryKeyText,[name]));
                                      result:=Fail;
                                      exit; //abort, no point continuing
                                    end;

                                    {$IFDEF DEBUGDETAIL3}
                                    {$IFDEF DEBUG_LOG}
                                    log.add(st.who,where+routine,format('Reading primary key constraint columns %d',[ParentConstraintId]),vDebugLow);
                                    {$ENDIF}
                                    {$ENDIF}

                                    if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraintColumn,sysConstraintColumnR)=ok then
                                    begin
                                      try
                                        //note: assumes we have best index/hash on scc_constraint_id, but may not be the case
                                        if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),ParentConstraintId)=ok then
                                          try
                                            repeat
                                              {Found another matching constraint column id}
                                              with (sysConstraintColumnR as TRelation) do
                                              begin
                                                //Note: we can assume scc_parent_or_child_table=Child //todo assert?
                                                fTuple.GetInteger(ord(scc_column_id),dummy_integer,dummy_null);
                                                {Add 'artificial' syntax node for this column}
                                                n2:=mkLeaf(st.srootAlloc,ntId,uGlobal.ctUnknown,0,0); //todo id_count++?;
                                                if r.fTuple.findColFromId(dummy_integer,cRef)=ok then
                                                begin
                                                  n2.idVal:=r.fTuple.fColDef[cRef].name; //will be looked up again later to get back to cRef!
                                                  if nParentColumn=nil then
                                                    nParentColumn:=n2   //start of chain
                                                  else
                                                    chainNext(nParentColumn,n2); //add to chain
                                                end
                                                else
                                                begin
                                                  {$IFDEF DEBUG_LOG}
                                                  log.add(st.who,where+routine,format('Failed finding column id %d in parent table, despite finding it in primary key constraint column',[dummy_integer]),vAssertion);
                                                  {$ENDIF}
                                                  result:=Fail;
                                                  exit; //abort
                                                end;
                                              end; {with}
                                            until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),ParentConstraintId)<>ok);
                                                  //todo stop when there are no more matching this id
                                          finally
                                            if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysConstraintColumnR)<>ok then
                                              {$IFDEF DEBUG_LOG}
                                              log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysConstraintColumn)]),vError); //todo abort?
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
                                      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysConstraintColumn)]),vDebugError); //todo assertion?
                                      {$ENDIF}
                                    end;


                                  end;
                                end; {with}
                              end
                              else //constraint_id not found
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(st.who,where+routine,format('Failed finding constraint %d',[ParentConstraintId]),vAssertion);
                                {$ENDIF}
                                result:=Fail;
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
                          end
                          else
                          begin  //couldn't get access to sysConstraint
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysConstraint)]),vDebugError); //todo assertion?
                            {$ENDIF}
                            result:=Fail;
                            exit; //abort, no point continuing
                          end;
                        end
                        //else not table-level - skip & continue looking
                      end; {with}
                    until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),FK_parent_table_id)<>ok);
                          //todo stop when there are no more matching this id
                  finally
                    if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysTableColumnConstraintR)<>ok then
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTableColumnConstraint)]),vError); //todo abort?
                      {$ELSE}
                      ;
                      {$ENDIF}
                  end; {try}
                //else no constraint for this table found => user error, trapped below
              finally
                if Ttransaction(st.owner).db.catalogRelationStop(st,sysTableColumnConstraint,sysTableColumnConstraintR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTableColumnConstraint)]),vError); 
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}
            end
            else
            begin  //couldn't get access to sysTableColumnConstraint
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysTableColumnConstraint)]),vDebugError); //todo assertion?
              {$ENDIF}
              result:=Fail;
              exit; //abort, no point continuing
            end;

            if nParentColumn=nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Referenced table (%s) does not have a primary key, so default column(s) cannot be used',[name]),vError); //todo debug/user error here?
              {$ENDIF}
              st.addError(seSyntaxMissingParentPrimaryKey,format(seSyntaxMissingParentPrimaryKeyText,[name]));
              result:=Fail;
              exit; //abort, no point continuing
            end
            else
            begin //link the artificial chain to the existing tree
              linkRightChild(nConstraint,nParentColumn);
            end;
          end;
          //else ok, user explicitly specified parent reference columns
          //todo so here, check they specify a candidate key

          {We now check the column references are valid:
           there are a number of checks to be made, so this is quite long}
          colCount:=0;
          {Now check through the parent column references (main loop)}
          nParentColumn:=nConstraint.rightChild; //todo assert if fail!? or if nil, after above routine!
          {...as we do this, we compare each with the corresponding child column reference(s) (secondary loop)}
          nChildColumn:=nDef; //if nDef=nil, then we'll use ownerCref as the implied single-column subscript
          while nParentColumn<>nil do
          begin
            inc(colCount); //so sequencing starts at 1

            result:=r.fTuple.FindCol(nil,nParentColumn.idval,'',nil,cTuple,cRef,cid);
            //todo check result: applies to other calls to findCol! although can't currently(!) fail
            if cid=InvalidColId then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Unknown column reference (%s)',[nParentColumn.idVal]),vError); //todo debug/user error here?
              {$ENDIF}
              st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nParentColumn.idVal]));
              result:=Fail;
              exit; //abort, no point continuing
            end;
            //todo if any result<>0 then quit
            {Note: we don't use cTuple, we just used FindCol to find our own id,
             never to find a column source}
            //todo: I'm not sure why/if we need this check here, especially since r can't be a view (but it's just an assertion...)
            if cTuple<>r.fTuple then //todo =speed
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@r.fTuple]),vAssertion);
              {$ENDIF}
              //todo **** resultErr - or catch earlier with result=-2 = ambiguous
              result:=fail;
              exit;
            end;

            {Now check if we're privileged to reference this column}
            if CheckTableColumnPrivilege(st,0{we don't care who grantor is},Ttransaction(st.owner).authId,{todo: are we always checking our own privilege here?}
                                         False{we don't care about role/authId grantee},authId_level_match,
                                         cTuple.fColDef[cRef].sourceAuthId{=source table owner},
                                         cTuple.fColDef[cRef].sourceTableId{=source table},
                                         cid,table_level_match{we don't care how exact we match},
                                         ptReferences,False{we don't want grant-option search},grantabilityOption)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed checking privilege %s on %d.%d for %d',[PrivilegeString[ptReferences],cTuple.fColDef[cRef].sourceTableId,cid,Ttransaction(st.owner).AuthId]),vDebugError);
              {$ENDIF}
              st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[nParentColumn.idVal+' privilege']));
              result:=Fail;
              exit;
            end;
            if grantabilityOption='' then //use constant for no-permission?
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Not privileged to %s on %d.%d for %d',[PrivilegeString[ptReferences],cTuple.fColDef[cRef].sourceTableId,cid,Ttransaction(st.owner).AuthId]),vDebugLow);
              {$ENDIF}
              st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to reference '+nParentColumn.idVal]));
              result:=Fail;
              exit;
            end;

            {Ok, we're privileged}

            {Compare this parent column with the corresponding child column}
            parentCref:=cRef; //note parent's reference
            //todo: may be neater to use some kind of tuple/row compare-types/check-compatible routine?
            if nDef<>nil then
            begin //we have an explicit list (=> foreign-key-def)
              if nChildColumn<>nil then
              begin
                (owner as Trelation).fTuple.FindCol(nil,nChildColumn.idval,'',nil,cTuple,cRef,cid);
                if cid=InvalidColId then
                begin
                  //shouldn't this have been caught before now!?
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Unknown column reference (%s)',[nChildColumn.idVal]),vError); //todo debug/user error here?
                  {$ENDIF}
                  st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nChildColumn.idVal]));
                  result:=Fail;
                  exit; //abort, no point continuing
                end;
                //todo if any result<>0 then quit
                {Note: we don't use cTuple, we just used FindCol to find our own id,
                 never to find a column source}
                //todo: I'm not sure why/if we need this check here, especially since owner can't be a view (but it's just an assertion...)
                if cTuple<>(owner as Trelation).fTuple then //todo =speed
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@(owner as Trelation).fTuple]),vAssertion);
                  {$ENDIF}
                  //todo **** resultErr - or catch earlier with result=-2 = ambiguous
                  result:=fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
                  exit;
                end;
              end
              else
              begin  //error- not enough child columns
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Not enough child column references',[nil]),vError);
                {$ENDIF}
                st.addError(seSyntaxNotEnoughChildColumns,seSyntaxNotEnoughChildColumnsText);
                result:=Fail;
                exit; //abort, no point continuing

              end;
            end
            else //we have an implied (single) column (=> references-def)
            begin
              if colCount=1 then
                cRef:=ownerCref
              else
              begin  //error- not enough child columns
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Not enough child column references',[nil]),vError);
                {$ENDIF}
                st.addError(seSyntaxNotEnoughChildColumns,seSyntaxNotEnoughChildColumnsText);
                result:=Fail;
                exit; //abort, no point continuing
              end;
            end;

            {Ok, now compare the two column definitions}
            {Currently, we only allow column pairs having the same underlying storage type
             Note: this may be too restrained/or too lax - see A Guide to SQL (4th ed) p442
             re standard being vague on this point}
            {++ I think this is currently too lax: should be same type}
            {TODO: use a common isCompatible routine - also used in iterSet preparation}
            if DataTypeDef[r.fTuple.fColDef[parentCref].datatype]<>DataTypeDef[(owner as TRelation).fTuple.fColDef[cRef].datatype] then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format(seSyntaxColumnTypesMustMatchText,[r.fTuple.fColDef[parentCref].name,(owner as Trelation).fTuple.fColDef[Cref].name]),vError);
              {$ENDIF}
              st.addError(seSyntaxColumnTypesMustMatch,format(seSyntaxColumnTypesMustMatchText,[r.fTuple.fColDef[parentCref].name,(owner as Trelation).fTuple.fColDef[Cref].name]));
              result:=Fail;
              exit; //abort, no point continuing
            end;

            {Get next child column (secondary loop increment)
             we need extra checks because the loop is not driven by this...}
            if nDef<>nil then //we have an explicit list
            begin
              if nChildColumn<>nil then
                nChildColumn:=nChildColumn.nextNode  //if this now becomes nil, we hopefully won't loop again if 2 lists are in sync.
              else
              begin  //should never happen - we should have errored earlier with 'not enough child columns'
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Not enough child column references - found too late',[nil]),vAssertion);
                {$ENDIF}
                //we might as well continue...
              end;
            end;

            nParentColumn:=nParentColumn.nextNode; //(main loop increment)
          end; {while}
          {Check we don't have any left-over child column references}
          if nDef<>nil then //we had an explicit list
          begin
            if nChildColumn<>nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Too many child column references',[nil]),vError);
              {$ENDIF}
              st.addError(seSyntaxNotEnoughChildColumns,seSyntaxNotEnoughChildColumnsText);
              result:=Fail;
              exit; //abort, no point continuing //todo although we could & just ignore extra!= bad!
            end;
          end;
        end
        else
        begin
          result:=-3; //could not find table
          st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
          exit; //abort
        end;

        //has table-ref: must ensure it is a base table and not a view here!
        //    also, need to check reference permissions before adding
        //has optional column or column list(=> foreignKeyDef): add detail entries to sysConstraintColumn

        {Get any optional trigger actions and match types
         and check for optional match types
        }
        if nConstraint.nextNode<>nil then
        begin
          n2:=nConstraint.nextNode;
          while n2<>nil do
          begin
            case n2.nType of
              ntOnUpdate:
              begin
                {$IFDEF DISALLOW_CASCADE_UPDATES}
                if n2.leftChild.nType=ntCascade then
                begin
                  result:=-1; //not allowed yet
                  st.addError(seNotImplementedYet,format(seNotImplementedYetText,['ON UPDATE CASCADE']));
                  exit; //abort
                end;
                {$ELSE}
                case n2.leftChild.nType of
                  ntNoAction:    FK_on_update_action:=raNone; //=raRestrict
                  ntCascade:     FK_on_update_action:=raCascade;
                  ntSetDefault:  FK_on_update_action:=raSetDefault;
                  ntSetNull:     FK_on_update_action:=raSetNull;
                end; {case}
                {$ENDIF}
              end;
              ntOnDelete:
              begin
                case n2.leftChild.nType of
                  ntNoAction:    FK_on_delete_action:=raNone; //=raRestrict
                  ntCascade:     FK_on_delete_action:=raCascade;
                  ntSetDefault:  FK_on_delete_action:=raSetDefault;
                  ntSetNull:     FK_on_delete_action:=raSetNull;
                end; {case}
              end;
              
              ntMatchFull:    FK_match_type:=mtFull;
              ntMatchPartial: FK_match_type:=mtPartial;
            //else other parameters?
            end; {case}

            n2:=n2.nextNode;
          end;
        end;
      end; {ntReferencesDef,ntForeignKeyDef}

      ntCheckConstraint:
      begin //Note: the code here is mostly duplicated below for the not-null shorthand
        rule_type:=rtCheck;      //todo maybe rename syntax node to ntCheck?
        {Store the raw check text
         Note: the parsed check text is available in the left subtree (useful for checking?)

         Note: domain check must use only VALUE
               column check must use only 'this-column'?
               table check must use only 'this-table columns'?
               - would be nice to be able to use only VALUE (maybe in SQL/99)?
        }

        if ownerRoot.ntype<>ntCreateDomain then
          child_table_id:=(owner as Trelation).tableId;
        //else leave child_table_id as default=n/a

        //todo: trim() the text? often will have a leading space or more...
        s:=nConstraint.rightChild.strVal; //note node type=ntCondExpText
        {Replace 's with ''s since we will insert this via a SQL statement} //todo make this a common function
        //todo: is this appropriate to every quote here?
        //todo: there's probably a faster, less fragmentory algorithm! - can't lex do the hard work?
        sQuotesOk:='';
        i:=pos('''',s); //find '
        while i>0 do
        begin
          sQuotesOk:=sQuotesOk+copy(s,1,i)+''''; //include existing quote and add a second: i.e. expand ' to ''
          s:=copy(s,i+1,length(s)); //next search is only in remainder, i.e. skip this quote
          i:=pos('''',s);
        end;
        sQuotesOk:=sQuotesOk+copy(s,1,length(s)); //whatever's left (in most cases this will be all of s)

        rule_check:=sQuotesOk;

        //todo maybe in future we should store the pre-parsed sub-tree as well as/instead of the text = speed
      end; {ntCheckConstraint}

      ntNotNull:
      begin
        if ownerRoot.ntype=ntCreateDomain then //although domain could use 'check(VALUE is not null)' = same thing (but slower?)
        begin
          {$IFDEF DEBUG_LOG}
          {Note: we still need the log.add before addError calls so we know where the error came from}
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(seSyntaxInvalidConstraintText,[nil]),vError);
          {$ENDIF}
          st.addError(seSyntaxInvalidConstraint,seSyntaxInvalidConstraintText);
          result:=Fail;
          exit;
        end;

        {Note: we don't use a separate notNull rule type: instead treat as CHECK ("C" IS NOT NULL)
          +ve: less special cases = simpler storage & handling
               domain constraint doesn't have this shorthand so it really is a one-off SQL-kludge
          -ve: need to build a plan etc. so may be slightly slower todo:stress-test
               some odbc funtions/info-schema views need column-is-nullable flag against column defs:
                    we could either use a subquery to check if a table rules exists matching '"C" IS NOT NULL' - ok,since we control the format
                       todo the above solution
                    or we could set a redundant flag against the column in sysColumn
                       -ve: would need to keep in sync. with column alterations & domain constraints could contain CHECK (C IS not NULL)
        }

        //single column child is found via ownerCref
        if ownerCref=-1 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Need an owner column reference passing for not-null constraint',[nil]),vAssertion);
          {$ENDIF}
          result:=Fail; //abort
          exit;
        end;

        rule_type:=rtCheck;

        child_table_id:=(owner as Trelation).tableId;

        //Note: we can tell this is internally generated because it has no ()s - todo: use them for consistency?
        rule_check:='"'+(owner as Trelation).fTuple.fColDef[ownerCref].name+'" IS NOT NULL';

      end; {ntNotNull}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unknown constraint type %d',[ord(nConstraint.nType)]),vAssertion);
      {$ENDIF}
      result:=Fail;
      exit;
    end; {case}

    {We need to insert as _SYSTEM to ensure we have permission on sysConstraint (plus is quicker since _SYSTEM has ownership rights)}
    //Note: caller probably already set this, since we are only ever a sub-creation... but carry on anyway...
    //todo: but this is wrong, because FK privilege needs to check 'our' references privilege, not _SYSTEM... todo check callers don't mask themselves!
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
      result:=ExecSQL(tempStmt,
        format('INSERT INTO %s.sysConstraint (constraint_id,'+
                                             'constraint_name,'+
                                             'schema_id,'+
                                             '"deferrable",'+
                                             'initially_deferred,'+
                                             'rule_type,'+
                                             'rule_check,'+
                                             'FK_parent_table_id,'+
                                             'FK_child_table_id,'+
                                             'FK_match_type,'+
                                             'FK_on_update_action,'+
                                             'FK_on_delete_action'+
                                             ' ) '+
               'VALUES (%d,''%s'',%d,''%s'',''%s'',%d,''%s'',%d,%d,%d,%d,%d); ',  //todo allow FK*, rule_check etc to be null
               [sysCatalogDefinitionSchemaName,
                ConstraintId,ConstraintName,schema_Id,
                deferrable,initially_deferred,
                ord(rule_type),rule_check,   //todo instead of storing ord() we should store getStorageValue()! - everywhere we use ord->db!!!!
                FK_parent_table_id,child_table_id,ord(FK_match_type),ord(FK_on_update_action),ord(FK_on_delete_action)])
               ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
        {$ENDIF}
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysConstraint',[resultRowCount]),vdebug);
        {$ENDIF}
        //todo assert resultRowCount=1?
        result:=ConstraintId; //return success & constraintId for caller to reference

        //todo need to make this + column detail below atomic!
        // - for starters, we don't overwrite the result that we set here...
      end;
      {Now, if required, we add the constraint-column entries}
      if rule_type in [rtForeignKey,rtUnique,rtPrimaryKey] then
      begin
        if rule_type=rtForeignKey then
        begin
          {First, parent reference columns, i.e. for foreign-key constraints
           - assumes r is still valid & if it wasn't found we wouldn't be here}
          nParentColumn:=nConstraint.rightChild; //todo assert if fail!?
          colCount:=0;
          while nParentColumn<>nil do
          begin
            //note: we've already checked these, so we can expect no failures!
            r.fTuple.FindCol(nil,nParentColumn.idval,'',nil,cTuple,cRef,cid);
            if cid=InvalidColId then
            begin
              //this should have been caught before now!!!
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Unknown column reference (%s)',[nParentColumn.idVal]),vAssertion); //todo debug/user error here?
              {$ENDIF}
              result:=Fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
              exit; //abort, no point continuing
            end;
            //todo if any result<>0 then quit
            {Note: we don't use cTuple, we just used FindCol to find our own id,
             never to find a column source}
            //todo: I'm not sure why/if we need this check here, especially since r can't be a view (but it's just an assertion...)
            if cTuple<>r.fTuple then //todo =speed
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@r.fTuple]),vAssertion);
              {$ENDIF}
              //todo **** resultErr - or catch earlier with result=-2 = ambiguous
              result:=fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
              exit;
            end;

            {Ok, insert the reference}
            inc(colCount); //so sequencing starts at 1

            //todo maybe better/more efficient to build a single statement for all column entries
            // - easier to rollback, faster (much less parsing),
            //   and could maybe build/prepare earlier during initial checks = neater code!?

            Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
            tempResult:=ExecSQL(tempStmt,
              format('INSERT INTO %s.sysConstraintColumn (constraint_id,'+
                                                         'parent_or_child_table,'+
                                                         'column_id,'+
                                                         'column_sequence'+
                                                         ' ) '+
                     'VALUES (%d,''%s'',%d,%d); ',
                     [sysCatalogDefinitionSchemaName,
                      ConstraintId,ctParent,cid,colCount])
                     ,nil,resultRowCount);
            if tempResult<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'  Failed inserting sysConstraintColumn row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
              {$ENDIF}
              //todo return fail?
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Inserted %d entries into sysConstraintColumn',[resultRowCount]),vdebug);
              {$ENDIF}
              //todo assert resultRowCount=1?
            end;

            nParentColumn:=nParentColumn.nextNode;
          end; {while}

          //Since we must always reference a parent's [candidate] key we have
          //no need to add any indexes here...yet...
          //Below, we add referenced-by indexes to speed up RI trigger actions...

          {Add constraint entry for this Parent table entry for deletion checking - caller will do child's}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          tempResult:=ExecSQL(tempStmt,
            format('INSERT INTO %s.sysTableColumnConstraint (table_id,column_id,constraint_id) '+
                   'VALUES (%d,NULL,%d); ',
                   [sysCatalogDefinitionSchemaName, FK_parent_table_id,{,table-level: Note: null=parent end of FK}ConstraintId])
                   ,nil,resultRowCount);
          if tempResult<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed inserting sysTableColumnConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
            //todo return fail?
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnConstraint',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
            //todo assert resultRowCount=1?
        end; {rtForeignKey}

        {Second, child reference column(s), e.g. for foreign-key,primary-key constraints
         - assumes owner is valid & if it wasn't we wouldn't be here}
        colCount:=0;
        if nDef<>nil then
        begin //we have an explicit list => foreign-key-def if rtForeignKey
          nChildColumn:=nDef;
          while nChildColumn<>nil do
          begin
            //note: todo: check above!  //we've already checked these, so we can expect no failures!
            (owner as Trelation).fTuple.FindCol(nil,nChildColumn.idval,'',nil,cTuple,cRef,cid);
            if cid=InvalidColId then
            begin
              //this should have been caught before now!!!
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Unknown column reference (%s)',[nChildColumn.idVal]),vAssertion); //todo debug/user error here?
              {$ENDIF}
              result:=Fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
              exit; //abort, no point continuing
            end;
            //todo if any result<>0 then quit
            {Note: we don't use cTuple, we just used FindCol to find our own id,
             never to find a column source}
            //todo: I'm not sure why/if we need this check here, especially since owner can't be a view (but it's just an assertion...)
            if cTuple<>(owner as Trelation).fTuple then //todo =speed
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Column tuple found in %p and not in this parent relation %p',[@cTuple,@(owner as Trelation).fTuple]),vAssertion);
              {$ENDIF}
              //todo **** resultErr - or catch earlier with result=-2 = ambiguous
              result:=fail; //this will lose the constraintId return ref. //todo so ensure we remove the constraint header here? //should never happen!
              exit;
            end;
            {Ok, insert the reference}
            inc(colCount); //so sequencing starts at 1

            //todo maybe better/more efficient to build a single statement for all column entries
            // - easier to rollback, faster (much less parsing),
            //   and could maybe build/prepare earlier during initial checks = neater code!?

            Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
            tempResult:=ExecSQL(tempStmt,
              format('INSERT INTO %s.sysConstraintColumn (constraint_id,'+
                                                         'parent_or_child_table,'+
                                                         'column_id,'+
                                                         'column_sequence'+
                                                         ' ) '+
                     'VALUES (%d,''%s'',%d,%d); ',
                     [sysCatalogDefinitionSchemaName,
                      ConstraintId,ctChild,cid,colCount])
                     ,nil,resultRowCount);
            if tempResult<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'  Failed inserting sysConstraintColumn row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
              {$ENDIF}
              //todo return fail?
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Inserted %d entries into sysConstraintColumn',[resultRowCount]),vdebug);
              {$ENDIF}
              //todo assert resultRowCount=1?
            end;

            nChildColumn:=nChildColumn.nextNode;
          end; {while}
        end
        else //we have an implied (single) column => references-def
        begin
          //todo may be neater to code this as a sub-function, since we call it twice
          {Ok, insert the reference}
          inc(colCount); //so sequencing starts at 1

          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          tempResult:=ExecSQL(tempStmt,
            format('INSERT INTO %s.sysConstraintColumn (constraint_id,'+
                                                       'parent_or_child_table,'+
                                                       'column_id,'+
                                                       'column_sequence'+
                                                       ' ) '+
                   'VALUES (%d,''%s'',%d,%d); ',
                   [sysCatalogDefinitionSchemaName,
                    ConstraintId,ctChild,(owner as Trelation).fTuple.fColDef[ownerCref].id,colCount])
                   ,nil,resultRowCount);
          if tempResult<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed inserting sysConstraintColumn row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
            {$ENDIF}
            //todo return fail?
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Inserted %d entries into sysConstraintColumn',[resultRowCount]),vdebug);
            {$ENDIF}
            //todo assert resultRowCount=1?
          end;
        end;

        {Now add a system index for the unique/primary key - used for subsequent FK definition lookups}
        if rule_type in [rtUnique,rtPrimaryKey] then
        begin
          //todo: get result=index_id
          CreateIndex(st,nDef,schema_id,ConstraintName+'_index',ioSystemConstraint,result,owner,nil,ownerCref);
        end;
        {Now add an index for the foreign key child - used for subsequent FK trigger action checks}
        if rule_type in [rtForeignKey] then
        begin
          //todo: get result=index_id
          CreateIndex(st,nDef,schema_id,ConstraintName+'_index',ioSystemConstraint,result,owner,nil,ownerCref); //todo: flag as not likely to be very selective?
        end;
      end; {rtForeignKey,rtUnique,rtPrimaryKey}

    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Defined %s',[ConstraintName]),vDebugLow);
    {$ENDIF}
  finally
    {Clean up any reference relation, if used}
    r.free;
    r:=nil;
  end; {try}
end; {createConstraint}

function deleteConstraint(st:Tstmt;constraintId:integer):integer;
{Delete a constraint
 IN:
           st            statement
           constraintId  the constraint to be deleted

 RETURNS:  ok,
           else Fail

 Side-effects:
   Will also delete the system created index for:
        primary key definitions
        unique definitions
        foreign key child definitions (used for integrity check/cascade when delete/update parent)
        //todo keep this list up to date!

   Will also delete the entry in sysTableColumnConstraint for the parent of a
   Foreign Key constraint.

 Assumes:
   caller has set appropriate authId

   caller has checked there are no dependents, e.g. FK on our PK

 Note:
   initially created for calling from dropTable, but this routine
   will be called from elsewhere such as alterTable.

   Keep in sync. with constraint.check routine.
}
const routine=':deleteConstraint';
var
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=fail;

          {Remove any constraint links to table/columns (from both ends if FK)}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTableColumnConstraint WHERE constraint_id=%d ',
                   [sysCatalogDefinitionSchemaName, constraintId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTableColumnConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove constraint column details (from both ends if FK)}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysConstraintColumn WHERE constraint_id=%d ',
                   [sysCatalogDefinitionSchemaName, constraintId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysConstraintColumn row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysConstraintColumn',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove constraint}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysConstraint WHERE constraint_id=%d ',
                   [sysCatalogDefinitionSchemaName, constraintId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove any index columns for the constraint}
          //todo: call DropIndex instead...
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysIndexColumn WHERE index_id IN (SELECT index_id FROM %s.sysIndex WHERE constraint_id=%d)',
                 [sysCatalogDefinitionSchemaName, sysCatalogDefinitionSchemaName, constraintId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysIndexColumn row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndexColumn',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove any indexes for the table}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysIndex WHERE constraint_id=%d ',
                 [sysCatalogDefinitionSchemaName, constraintId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysIndex row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndex',[resultRowCount]),vdebug);
          {$ENDIF}

end; {deleteConstraint}

function dropConstraint(st:Tstmt;nroot:TSyntaxNodePtr;table_id:integer):integer;
{Drop a constraint
 IN:
           st        statement
           nroot     pointer to ntDropConstraint node
           table_id  reference to constraint owner for assertion check, or 0 = ignore

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           -4 = constraint is not for the specified table
           -5 = dependent constraint(s) exist
           else Fail

 Note:
  uses deleteConstraint to do the work
}
const routine=':DropConstraint';
var
  n,n2:TSyntaxNodePtr;

  sysConstraintR:TObject; //Trelation
  s,s2:string;
  tempInt,tempInt2,dummy_integer:integer;
  vnull:boolean;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;

  ruleType:TconstraintRuleType;
  FKchildTableId:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if another transaction is executing?

    check cascade option (in rightChild)
  }

  {For now, we can't cascade and zap the constraints that depend on this constraint
   todo!}
  if (n.rightChild<>nil{in case optional/default in future}) and (n.rightChild.nType=ntCascade) then
  begin
    st.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP CONSTRAINT...CASCADE'])+' (use RESTRICT)');
    exit; //abort
  end;

  {Left child is constraint reference}
  {Find constraint}
  tempResult:=getOwnerDetails(st,n.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,s,schema_Id,s2,auth_id);
  if tempResult<>ok then
  begin  //couldn't get access to sysSchema
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed to find schema',[nil]),vDebugLow);
    {$ENDIF}
    result:=tempResult;
    case result of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    end; {case}
    exit; //abort
  end;

  s:=n.leftChild.rightChild.idVal;

  //todo lookup the constraint once during pre-evaluation & then here = faster
  {maybe we should put this code in Tconstraint class?}
  {find constraintID for s}
  tempInt2:=0; //not found
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysConstraint,sysConstraintR)=ok then
  begin
    try
      if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysConstraintR,ord(sco_constraint_name),s)=ok then
        try
        repeat
        {Found another matching constraint for this name}
        with (sysConstraintR as TRelation) do
        begin
          fTuple.GetInteger(ord(sco_Schema_id),tempInt,vnull);
          if tempInt=schema_Id then
          begin
            fTuple.GetInteger(ord(sco_constraint_Id),tempInt2,vnull);
            //already got constraintName
            fTuple.GetInteger(ord(sco_rule_type),dummy_integer,vnull);
            ruleType:=TconstraintRuleType(dummy_integer); //todo protect cast from garbage!
            fTuple.GetInteger(ord(sco_FK_child_table_id),FKchildTableId,vnull);
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found constraint %s in %s (with constraint-id=%d)',[s,sysConstraint_table,tempInt2]),vDebugLow);
            {$ENDIF}
            {$ENDIF}

            if (table_id<>0) and (table_id<>FKchildTableId) then
            begin
              result:=-4; //specified constraint was not for the specified table
              st.addError(seSyntaxUnknownConstraintForThisTable,format(seSyntaxUnknownConstraintForThisTableText,[s]));
              exit; //abort
            end;
          end;
          //else not for our schema - skip & continue looking
        end; {with}
        until (tempInt2<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysConstraintR,ord(sco_constraint_name),s)<>ok);
              //todo stop once we've found a constraint_id with our schema_Id, or there are no more matching this name
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysConstraintR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysConstraint)]),vError); //todo abort?
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else constraint not found
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysConstraint,sysConstraintR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysConstraint)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysConstraint
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysConstraint),s]),vDebugError); //todo assertion?
    {$ENDIF}
    st.addError(seFail,seFailText);
    result:=fail;
    exit; //abort
  end;

  if tempInt2<>0 then
  begin //found
    if (auth_id<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
    begin
      result:=-5;
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop '+s]));
      exit; //abort
    end;

    if True then
    begin
      //todo: if any of these fail, abort & rollback(?)
      //todo: devise a neater way to bundle these together!

      {We need to delete as _SYSTEM to ensure we have permission on sysConstraint (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        {If this is a unique/pk, ensure no FK is dependent on us
              todo: in future, ensure FK constraint refers to PK constraint
                (need to update createConstraint to cross-check specified columns are a key & store key id)
              for now, we can do this here by:
                for all constraints where FK_parent_table_id=our_child_table_id (i.e. FKs depending on our table)
                  if all its Parent constraintColumns match our Child constraintColumn
                    then we can infer that it is dependent on us... so reject the drop here (or cascade the drop?)
           for simplicity we use SQL!:
             SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS
             (original PK rows EXCEPT ...
             ((SELECT column_id,column_sequence FROM catalog_definition_schema.sysconstraint NATURAL JOIN catalog_definition_schema.sysconstraintcolumn
             WHERE constraint_id = 12 AND parent_or_child_table='C')
             INTERSECT CORRESPONDING BY (column_id,column_sequence)
             (SELECT column_id,column_sequence FROM catalog_definition_schema.sysconstraint NATURAL JOIN catalog_definition_schema.sysconstraintcolumn
             WHERE rule_type=2 AND fk_parent_table_id = 50 AND parent_or_child_table='P'))
             )
        }
        if ruleType in [rtUnique,rtPrimaryKey] then
        begin
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS '+
                    '((SELECT column_id,column_sequence FROM %s.sysconstraint NATURAL JOIN %s.sysconstraintcolumn '+
                    '  WHERE constraint_id = %d and parent_or_child_table=''C'') '+

                    'EXCEPT CORRESPONDING BY (column_id,column_sequence) '+

                    '((SELECT column_id,column_sequence FROM %s.sysConstraint NATURAL JOIN %s.sysConstraintColumn '+
                    '  WHERE constraint_id = %d AND parent_or_child_table=''C'') '+

                    'INTERSECT CORRESPONDING BY (column_id,column_sequence) '+

                    '(SELECT column_id,column_sequence FROM %s.sysConstraint NATURAL JOIN %s.sysConstraintColumn '+
                    ' WHERE rule_type=%d AND fk_parent_table_id = %d AND parent_or_child_table=''P'')) ) ',
                     [sysCatalogDefinitionSchemaName,sysCatalogDefinitionSchemaName,
                      tempInt2,
                      sysCatalogDefinitionSchemaName,sysCatalogDefinitionSchemaName,
                      tempInt2,
                      sysCatalogDefinitionSchemaName,sysCatalogDefinitionSchemaName,
                      ord(rtForeignKey),FKchildTableId])
                 ,nil,resultRowCount);
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed checking candidate key dependents: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
            resultRowCount:=0; //assume none exist
          end;
          if resultRowCount=0 then //key-cols - (key-cols intersect fk-cols) should give key-cols rows if no dependents, so 0 rows = dependent references all our key columns (note: could be dependentS - todo problem?)
          begin
            result:=-4; //dependent constraint(s) exist
            st.addError(seConstraintHasConstraint,seConstraintHasConstraintText);
            exit; //abort
          end;
        end;
        //else can't have dependents (but user must still specify Restrict or Cascade!)

        {Remove the constraint (and any system constraint index)}
        result:=deleteConstraint(st,tempInt2);
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Dropped %s',[s]),vDebugLow);
      {$ENDIF}
    end;
  end
  else
  begin
    result:=-3; //could not find specified constraint
    st.addError(seSyntaxUnknownConstraint,format(seSyntaxUnknownConstraintText,[s]));
    exit; //abort
  end;
end; {dropConstraint}

function DetermineDatatype(st:Tstmt;nroot:TSyntaxNodePtr;
                           var dDomainId:integer;var dDataType:TDatatype;var dWidth:integer;var dScale:smallint;
                           var dDefaultVal:string;var dDefaultNull:boolean;var dVariableType:TVariableType):integer;
{Examine subnode of a ntColumnDef, ntParameterDef, ntDeclaration, ntCreateDomain
 to determine the datatype definition details

 IN:
           tr      transaction
           s       statement
           nroot   pointer to datatype definition node

 OUT:      dDomainId        - column definitions only
           dDataType
           dWidth
           dScale
           dDefaultVal
           dDefaultNull
           dVariableType    - parameter definitions only

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           else Fail

 Note: it is up to the syntax analyser to prevent options that don't apply,
 e.g. variable-type will be looked for but should only be present for parameter definitions
}
const routine=':DetermineDatatype';
var
  n,n2:TSyntaxNodePtr;
  sysDomainR:TObject; //Trelation
  tempi:integer;
  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;
  dummy_null:boolean;
  tempResult:integer;
begin
  result:=fail;
  n:=nroot;

  dDomainId:=0;
  dDataType:=ctInteger;
  dWidth:=0;
  dScale:=0;
  dDefaultVal:='';
  dDefaultNull:=true;
  dVariableType:=vtIn;

  {Set the datatype/domain}
  case n.nType of
    ntInteger:
    begin
      dDataType:=ctInteger;
    end;
    ntSmallInt:
    begin
      dDataType:=ctSmallInt;
    end;
    ntBigInt:
    begin
      dDataType:=ctBigInt;
    end;
    ntFloat:
    begin
      dDataType:=ctFloat;
      if n.leftChild<>nil then
        dWidth:=trunc(n.leftChild.numVal); //todo replace trunc()s with DoubleToIntSafe()...
        //todo this specifies number of bits (todo check?) - we can specify the maximum e.g. 32 or sizeof(double)/8?
        //todo should we store this in colWidth? - might this be displayed as NUMERIC(p)?
        //todo It really should alter the colDataType depending on its size but we need to store the user's value as well
      //else we default the size of the float
    end;
    ntNumeric:
    begin
      dDataType:=ctNumeric;
      if n.leftChild<>nil then
        dWidth:=trunc(n.leftChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dWidth:=DefaultNumericPrecision;
      if n.rightChild<>nil then
        dScale:=trunc(n.rightChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dScale:=DefaultNumericScale;
    end;
    ntDecimal:
    begin
      dDataType:=ctDecimal;
      if n.leftChild<>nil then
        dWidth:=trunc(n.leftChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dWidth:=DefaultNumericPrecision;
      {TODO: Up the allowed dWidth (now or when Get?) if the storage allows (but still need to retain original def)}
      if n.rightChild<>nil then
        dScale:=trunc(n.rightChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dScale:=DefaultNumericScale;
    end;
    ntCharacter:
    begin
      dDataType:=ctChar;
      dWidth:=trunc(n.leftChild.numVal); //todo replace trunc()s with DoubleToIntSafe()...
      //todo check max width not breached (& total record length)
    end;
    ntVarChar:
    begin
      dDataType:=ctVarChar;
      dWidth:=trunc(n.leftChild.numVal); //todo don't store here?
      //todo check max width not breached (& total record length)
    end;
    ntBit:
    begin
      dDataType:=ctBit;
      dWidth:=trunc(n.leftChild.numVal);
      //todo check max width not breached (& total record length)
    end;
    ntVarBit:
    begin
      dDataType:=ctBit;
      dWidth:=trunc(n.leftChild.numVal); //todo don't store here?
      //todo check max width not breached (& total record length)
    end;
    ntDate:
    begin
      dDataType:=ctDate;
      dWidth:=DATE_MIN_LENGTH;
    end;
    ntTime:
    begin
      dDataType:=ctTime;
      if n.rightChild<>nil then
        if n.rightChild.nType=ntWithTimezone then dDataType:=ctTimeWithTimezone;
      if n.leftChild<>nil then
        dScale:=trunc(n.leftChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dScale:=DefaultTimeScale;
      dWidth:=TIME_MIN_LENGTH+dScale;
      if dDataType=ctTimeWithTimezone then dWidth:=dWidth+TIMEZONE_LENGTH;
    end;
    ntTimestamp:
    begin
      dDataType:=ctTimestamp;
      if n.rightChild<>nil then
        if n.rightChild.nType=ntWithTimezone then dDataType:=ctTimestampWithTimezone;
      if n.leftChild<>nil then
        dScale:=trunc(n.leftChild.numVal) //todo replace trunc()s with DoubleToIntSafe()...
      else
        dScale:=DefaultTimestampScale;
      dWidth:=TIMESTAMP_MIN_LENGTH+dScale;
      if dDataType=ctTimestampWithTimezone then dWidth:=dWidth+TIMEZONE_LENGTH;
    end;
    ntBlob:
    begin
      dDataType:=ctBlob;
      dWidth:=trunc(n.leftChild.numVal); //todo don't store here?
      //todo check max width not breached (& total record length, e.g. 6 bytes for ref storage in this row)
    end;
    ntClob:
    begin
      dDataType:=ctClob;
      dWidth:=trunc(n.leftChild.numVal); //todo don't store here?
      //todo check max width not breached (& total record length, e.g. 6 bytes for ref storage in this row)
    end;

    ntDomain:
    begin
      //todo add any specified catalog/schema prefix!
      tempResult:=getOwnerDetails(st,nroot.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
      if tempResult<>ok then
      begin  //couldn't get access to sysSchema
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugLow);
        {$ENDIF}
        result:=tempResult;
        case result of
          -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
          -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
        end; {case}
        exit; //abort
      end;

      {find domainID for n.rightChild.idVal}
      if Ttransaction(st.owner).db.catalogRelationStart(st,sysDomain,sysDomainR)=ok then
      begin
        try
          //todo assert n.rightChild.idVal exists
          if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysDomainR,ord(sd_domain_name),n.rightChild.idVal)=ok then
            try
              repeat
                {Found another matching domain with this name}
                with (sysDomainR as TRelation) do
                begin
                  fTuple.GetInteger(ord(sd_schema_id),tempi,dummy_null);  //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                  if tempi=schema_Id then
                  begin
                    fTuple.GetInteger(ord(sd_domain_id),dDomainId,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                    //domain_name
                    fTuple.GetInteger(ord(sd_datatype),tempi,dummy_null);
                    dDataType:=TDataType(tempi); //todo we have to assume datatype is (still) valid //todo check what happens if it's not- exception?
                    fTuple.GetInteger(ord(sd_width),tempi,dummy_null);
                    dWidth:=tempi;
                    fTuple.GetInteger(ord(sd_scale),tempi,dummy_null);
                    dScale:=tempi;
                    fTuple.GetString(ord(sd_default),dDefaultVal,dDefaultNull);
                    //todo if colDefaultNull=True then we assume default=null

                    //todo default to domain constraints unless overridden in next section...

                    //{$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Found domain %s (%d) with width=%d, scale=%d, default=%s (null=%d)',[n.rightChild.idVal,dDomainId,dWidth,dScale,dDefaultVal,ord(dDefaultNull)]),vDebugLow);
                    {$ENDIF}
                    //{$ENDIF}
                  end;
                  //else not for our schema - skip & continue looking
                end; {with}
              until (dDomainId<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysDomainR,ord(sd_domain_name),n.rightChild.idVal)<>ok);
                    //todo stop once we've found a dDomainId with our schema_Id, or there are no more matching this name
            finally
              if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysDomainR)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysDomain)]),vError); //todo abort?
                {$ELSE}
                ;
                {$ENDIF}
            end; {try}
          //else domain not found
        finally
          if Ttransaction(st.owner).db.catalogRelationStop(st,sysDomain,sysDomainR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysDomain)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysDomain
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysDomain),n.rightChild.idVal]),vDebugError); //todo assertion?
        {$ENDIF}
        exit; //abort
      end;

      if dDomainId<>0 then
      begin
        //todo CheckDomainPrivilege to make sure we're allowed Usage
      end
      else
      begin  //domain not found
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unknown domain %s',[n.rightChild.idVal]),vError);
        {$ENDIF}
        st.addError(seSyntaxUnknownDomain,format(seSyntaxUnknownDomainText,[n.rightChild.idVal]));
        exit; //abort
      end;
    end; {ntDomain}
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unknown datatype %d',[ord(n.nType)]),vDebugError); //todo assertion?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  {Loop through chain to check for any default for this column}
  //todo ok to override any default domain constraints/defaults?
  n2:=n;
  while n2.nextNode<>nil do
  begin
    n2:=n2.nextNode;

    case n2.nType of
      ntDefault: //default
      begin
        if n2.leftChild.nType<>ntNull then
        begin
          dDefaultNull:=false;
          case n2.leftChild.nType of
            ntNumber: dDefaultVal:=floatToStr(n2.leftChild.numVal); //todo use common safe convert routine!
            ntString: dDefaultVal:=n2.leftChild.strVal;
            ntCurrentUser: dDefaultVal:='CURRENT_USER';
            ntSessionUser: dDefaultVal:='SESSION_USER';
            ntSystemUser: dDefaultVal:='SYSTEM_USER';
            ntCurrentDate: dDefaultVal:='CURRENT_DATE';
            ntCurrentTime: dDefaultVal:='CURRENT_TIME';
            ntCurrentTimestamp: dDefaultVal:='CURRENT_TIMESTAMP';
            ntNextSequence: if (n2.leftChild.leftChild.leftChild<>nil) and (n2.leftChild.leftChild.leftChild.nType=ntSchema) then
                              dDefaultVal:='NEXT_SEQUENCE('+n2.leftChild.leftChild.leftChild.rightChild.idVal+'.'+n2.leftChild.leftChild.rightChild.idVal+')'
                            else dDefaultVal:='NEXT_SEQUENCE('+n2.leftChild.leftChild.rightChild.idVal+')';
            ntLatestSequence: if (n2.leftChild.leftChild.leftChild<>nil) and (n2.leftChild.leftChild.leftChild.nType=ntSchema) then
                                dDefaultVal:='LATEST_SEQUENCE('+n2.leftChild.leftChild.leftChild.rightChild.idVal+'.'+n2.leftChild.leftChild.rightChild.idVal+')'
                              else
                                dDefaultVal:='LATEST_SEQUENCE('+n2.leftChild.leftChild.rightChild.idVal+')';
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown default datatype %d',[ord(n2.leftChild.nType)]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=Fail;
            exit;
          end; {case}
        end;
        //else default null -> currently implicit default
      end; {ntDefault}
      ntIn: //in
      begin
        dVariableType:=vtIn;
      end; {ntIn}
      ntOut: //out
      begin
        dVariableType:=vtOut;
      end; {ntOut}
      ntInOut: //inout
      begin
        dVariableType:=vtInOut;
      end; {ntInOut}
      ntResult: //result
      begin
        dVariableType:=vtResult;
      end; {ntInOut}
    end; {case}
  end; {while}

  result:=ok;
end; {DetermineDatatype}

function CreateTable(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a table
 IN:
           tr      transaction
           s       statement
           nroot   pointer to ntCreateTable node

 RETURNS:  Ok,
           -2 = table already exists
           -3 = not privileged
           -4 = duplicate column name specified
           -5 = unknown catalog
           -6 = unknown schema
           else Fail
}
const routine=':CreateTable';
var
  r:TRelation;
  n,n2,n3:TSyntaxNodePtr;
  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;
  colVariableType:TVariableType; //n/a
  constraintValid:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //used for column lookup
  cId:TColId;
  cRef:ColRef;

  cTuple:TTuple;  //todo make global?


  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  r:=TRelation.create;
  try
    colCount:=0;
    {Loop through column sub-tree chain}
    n:=n.rightChild;
    repeat
      if n.nType=ntColumnDef then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('column %p %d %s',[n,ord(n.ntype),n.leftchild.idVal]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}

        {Note: some of this code is duplicated in the ntCast evaluation}

        result:=DetermineDatatype(st,n.rightChild,
                                  colDomainId,colDataType,colWidth,colScale,colDefaultVal,colDefaultNull,colVariableType{n/a});
        if result<>ok then exit; //abort

        //todo check for 'default null, check not null' semantic nonsense before this next step
        // (could be more subtle, e.g. domain = check not null and column = default null)
        // - i.e. delay it until after we've added (or pre-scanned) any constraints below...
        // - for now, it's up to the user to be sensible!

        {Check this column name has not already been added to this table!}
        r.fTuple.findCol(nil,n.leftChild.idVal,'',nil,cTuple,cRef,cId);
        if cId<>InvalidColId then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(seSyntaxAmbiguousColumnText,[n.leftChild.idVal]),vError); //todo should be reported as error to user
          {$ENDIF}
          st.addError(seSyntaxAmbiguousColumn,format(seSyntaxAmbiguousColumnText,[n.leftChild.idVal]));
          result:=-4;
          exit;
        end;

        //todo check the width is within range for this type (or do in determineDatatype routine?)

        inc(colCount); //need to increment before SetColDef
        r.fTuple.ColCount:=colCount; //set the new number of columns before SetColDef
        r.NextColId:=colCount{$IFDEF LARGE_COLIDS}+1000{$ENDIF} +1;
        r.fTuple.SetColDef(colCount-1,r.NextColId-1,n.leftChild.idVal,
                           colDomainId,colDataType,
                           colWidth,colScale,
                           colDefaultVal,colDefaultNull); 
        //todo inc fColCount here? - for subscript checks etc
      end;
      //else not a column_def, e.g. a constraint_def

      n:=n.nextNode; //move to next column definition

    until n=nil;

    {Create the relation}
    result:=r.createNew(st,nroot.leftChild.leftChild,'',nroot.leftchild.rightChild.idVal,False,nroot.leftchild.rightChild.idVal);

    if result=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Defined %s (owner=%s)',[nroot.leftChild.rightChild.idVal,Ttransaction(st.owner).AuthName]),vDebugLow);
      {$ENDIF}
      {Add any constraint(s)}
      {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        {Add any column constraint(s)}
        //todo also we need to ensure we add or don't add any domain constraint copies as appropriate...
        // - use colDomainId to find this (there can only be one..?)
        colCount:=0;
        {Loop again through column sub-tree chain}
        n:=nroot.rightChild;
        repeat
          if n.nType=ntColumnDef then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('checking for column constraints for %s',[n.leftchild.idVal]),vDebug);
            {$ENDIF}

            inc(colCount); //start at 1 - i.e. column id, not subscript/reference

            {Loop through chain to check for constraints etc. for this column}
            n2:=n.rightChild;
            while n2.nextNode<>nil do
            begin
              n2:=n2.nextNode;

              case n2.nType of
                ntConstraintDef:
                begin
                  constraintValid:=True;

                  {If this is a primary key, check it has also been defined as not null} //todo in future, must assume not null
                  if n2.rightChild.nType=ntPrimaryKey then
                  begin
                    constraintValid:=False;
                    n3:=n.rightChild;
                    while n3.nextNode<>nil do
                    begin
                      n3:=n3.nextNode;

                      if n3.nType=ntConstraintDef then
                        if n3.rightChild.nType=ntNotNull then
                        begin
                          constraintValid:=True;
                          break;
                        end;
                    end;

                    if not constraintValid then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,seSyntaxPKcannotBeNullText,vError); //todo should be reported as error to user
                      {$ENDIF}
                      st.addError(seSyntaxPKcannotBeNull,seSyntaxPKcannotBeNullText);
                    end;
                  end;

                  //todo in future: pass this columnId to the createConstraint routine
                  // (done: we now pass the whole relation - we needed column defs as well for child-FK-refs)
                  //  because it must check that the check-constraint does not refer to it (directly or indirectly)
                  //  i.e. check for circularity that would indicate recursion...
                  //   - maybe best way to do this is to test-evaluate the constraint before we add (or make visible)
                  //     this column. If it fails with 'unknown column: this' then = invalid recursion
                  //  Note: if we don't check, then when we use it we will infinitely loop!
                  //        so for now, constraint checking should have a recursion count-out to detect this //todo
                  //  I don't think this applies here- can't strictly check that VALUE is used & no other refs?

                  if constraintValid then
                  begin
                    {We need to use our real authId, because constraint creation may need to check our privileges, e.g. for references}
                    Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
                    Ttransaction(st.owner).AuthName:=saveAuthName;
                    try
                      ConstraintId:=CreateConstraint(st,n2,r.schemaId,nroot,r,colCount-1{pass column subscript});
                    finally
                      {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
                      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
                      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
                    end; {try}
                  end
                  else
                    constraintId:=fail;

                  if ConstraintId<=ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed adding constraint',[nil]),vDebugError);
                    {$ENDIF}
                    //todo fail table creation? - need to rollback last stmt at least!! -need sys-level savepoints..?
                    //     also need to rollback relation.createNew changes! - should be ok - it calls tuple.insert(tr...)
                    //...for now we DROP what's left of it the long way...
                    //todo r.close?
                    Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
                    result:=ExecSQL(tempStmt,
                      format('DROP TABLE "%s"."%s" RESTRICT ', //todo CASCADE would be better when it's available
                             [r.schemaName, r.relname])
                             ,nil,resultRowCount);
                    if result<>ok then
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,'  Failed un-creating new table row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                      {$ENDIF}
                    else
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Un-created new table',[nil]),vdebug);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //todo assert resultRowCount=1?

                    result:=Fail;
                    exit;
                  end
                  else
                  begin
                    {Add constraint entry for this column entry}
                    //todo FK/references, Unique, Primary (etc.?) should become table-level, i.e. column_id=0 here...
                    //     not null & check remain column-level (=> may be able to check early in .next loop; for inserts at least!)
                    Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
                    result:=ExecSQL(tempStmt,
                      format('INSERT INTO %s.sysTableColumnConstraint (table_id,column_id,constraint_id) '+
                             'VALUES (%d,%d,%d); ',
                             [sysCatalogDefinitionSchemaName, r.tableId,colCount{Note: not-null=child-end of FK},ConstraintId])
                             ,nil,resultRowCount);
                    if result<>ok then
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,'  Failed inserting sysTableColumnConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                      {$ENDIF}
                    else
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnConstraint',[resultRowCount]),vdebug);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //todo assert resultRowCount=1?
                  end;

                end;
              end; {case}
            end; {while}
          end;
          //else not a column_def, e.g. a constraint_def

          n:=n.nextNode; //move to next column definition
        until n=nil;
        //todo: ifdef safety? here & elsewhere: n2:=nil, to prevent accidental use of garbage later in this routine...

        {Add any table constraint(s)}
        {Loop again through sub-tree chain looking for table constraints this time, not column definitions}
        n:=nroot.rightChild;
        repeat
          //Note: this code is duplicated in alterTable //todo keep in sync.
          if n.nType=ntConstraintDef then
          begin
            constraintValid:=True;

            {If this is a primary key, check it has also been defined as not null} //todo in future, must assume not null
            if n.rightChild.nType=ntPrimaryKeyDef then
            begin
              (*todo- check columns are (already defined) not null
              constraintValid:=False;
              n3:=n.rightChild;
              while n3.nextNode<>nil do
              begin
                n3:=n3.nextNode;

                if n3.nType=ntNotNull then
                begin
                  constraintValid:=True;
                  break;
                end;
              end;
              *)
            end;

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('adding a table constraint',[nil]),vDebug);
            {$ENDIF}

            if constraintValid then
            begin
              {We need to use our real authId, because constraint creation may need to check our privileges, e.g. for references}
              Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
              Ttransaction(st.owner).AuthName:=saveAuthName;
              try
                ConstraintId:=CreateConstraint(st,n,r.schemaId,nroot,r,-1);
              finally
                {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
                Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
                Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
              end; {try}
            end
            else
              ConstraintId:=fail;

            if ConstraintId<=ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed adding constraint',[nil]),vDebugError);
              {$ENDIF}
              //todo fail table creation? - need to rollback last stmt at least!! -need sys-level savepoints..?
              //     also need to rollback relation.createNew changes! - should be ok - it calls tuple.insert(tr...)
              //...for now we DROP what's left of it the long way...
              //todo r.close?
              Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
              result:=ExecSQL(tempStmt,
                format('DROP TABLE "%s"."%s" RESTRICT ', //todo CASCADE would be better when it's available
                       [r.schemaName, r.relname])
                       ,nil,resultRowCount);
              if result<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,'  Failed un-creating new table row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                {$ENDIF}
              else
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Un-created new table',[nil]),vdebug);
                {$ELSE}
                ;
                {$ENDIF}
                //todo assert resultRowCount=1?

              result:=Fail;
              exit;
            end
            else
            begin
              {Add constraint entry for this table entry}
              Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
              result:=ExecSQL(tempStmt,
                format('INSERT INTO %s.sysTableColumnConstraint (table_id,column_id,constraint_id) '+
                       'VALUES (%d,%d,%d); ',
                       [sysCatalogDefinitionSchemaName, r.tableId,0{=table-level: Note not-null=child end of FK},ConstraintId])
                       ,nil,resultRowCount);
              if result<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,'  Failed inserting sysTableColumnConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                {$ENDIF}
              else
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnConstraint',[resultRowCount]),vdebug);
                {$ELSE}
                ;
                {$ENDIF}
                //todo assert resultRowCount=1?
            end;
          end;
          //else not a constraint_def, e.g. a column_def
          //todo: for now give error message 'not handled yet' to make sure we catch all

          n:=n.nextNode; //move to next column/constraint definition
        until n=nil;

        //todo: check 1 primary key & not nullable columns etc.

      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}

      //simulate empty scan to avoid problem with scan-open pinning page
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,r.fTuple.ShowHeading,vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,stringOfChar('=',length(r.fTuple.ShowHeading)),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
{$IFDEF DEBUG_LOG}
//      log.quick('unpinning '+intTostr(r.dbFile.startPage));
{$ELSE}
;
{$ENDIF}
//      s.buffer.unpinPage(s.db,r.dbFile.startPage); //unpin start page to release it
                                                   //the scan routines can't auto do this
                                                   //because empty-scan = scan not started
    end
    else //create failed
    begin
      case result of
        -2: st.addError(seSyntaxTableAlreadyExists,seSyntaxTableAlreadyExistsText);
        -3: st.addError(sePrivilegeCreateTableFailed,sePrivilegeCreateTableFailedText);
        -4: begin result:=-5; st.addError(seUnknownCatalog,seUnknownCatalogText); end;
        -5: begin result:=-6; st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[''])); end;
      else
        st.addError(seFail,seFailText); //todo general error ok?
      end; {case}
    end;

  finally
    r.free;
  end; {try}
end; {createTable}

function CreateView(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a view
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntCreateView node

 RETURNS:  Ok,
           -2 = view already exists
           -3 = not privileged

           -5 = catalog not found
           -6 = schema not found
           else Fail
}
const routine=':CreateView';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;
  colCount:integer;

  viewDef:string; //view definition text

  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root
//todo directly use stmt - not locals - but needed else compiler type errors
begin
  atree:=nil;
  ptree:=nil;
  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ELSE}
  ;
  {$ENDIF}
  {done - complete?: todo: - update comment!
   I think we need to create (but not necessarily optimise) and prepare the select tree
   so we can get the type info for each column that we should add to the catalog.
   We can then stop and delete the sub-tree without ever having to iterate it,
   although the starting will open each relation - which is needed for syntax checking.

   Since we need to create, optmise, and start the select tree at runtime,
   with the columns correctly aliased, we may as well do the same here then
   we can take each column's alias from the column sub-tree rather
   than having to check whether the view definition has a (column-alias-list) or not.

   We can then call Trelation.createNew(newViewFlag)

   to add the columns and view/table to the catalog
   (turn off the creation of the heap file! - we're not materialised)
  }
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  {We use a temporary relation to be able to add the view/columns to the catalog}
  r:=TRelation.create;
  try
    {Now we build the algebra and iterator plan so we can start it and thus
     assertain the column count & types (although the view-def may override the names)
     Note: we dispose of the plans within this routine.
    }
    n:=nroot.rightChild;
    //todo: remove the next 2 assertions - no need!
    {Assert we haven't already an algebra/plan attached}
    if n.atree<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(n.nType),n.atree]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
      result:=Fail;
      exit;
    end;
    if n.ptree<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(n.nType),longint(n.ptree)]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
      result:=Fail;
      exit;
    end;
    {Note: n.nType doesn't have to lead to a SelectExp - i.e. a nice extension is
         to be able to 'create view V as values (1,2,3),(4,5,6)' etc.
         or 'create view V as tableX cross join tableY' ?
    }
    {Create the algebra plan}
    result:=CreateTableExp(st,n,atree);
    n.atree:=atree; //todo ok, even though result may not be ok?
    if result<>ok then exit; //abort

    {Create the iterator plan}
    result:=CreatePlan(st,n,n.atree,ptree);
    n.ptree:=ptree; //todo ok, even though result may not be ok?
    if result<>ok then
    begin
      st.addError(seFail,seFailText); //todo general error ok?
      exit; //abort
    end;
    {We have built a plan, so we need to prepare it now to make any final projected tuple definition available}
    if n.ptree<>nil then //assert we have a plan may=> result-set //todo ok assumption? is ptree initialised to nil?
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Starting prepared query plan %d',[longint(n.ptree)]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      result:=(n.ptree as TIterator).prePlan(nil{todo: pass system iter+tuple?});
      //note: no need to optimise here - we just need the final projection definition
      if result<>ok then exit; //abort
      try
        {Ok, now we can define the view in the catalog}
        result:=r.fTuple.CopyTupleDef((n.ptree as TIterator).iTuple);
        if result<>ok then
        begin
          st.addError(seFail,seFailText); //todo general error ok?
          exit; //abort
        end;

        {Check if the user specified explicit names for the columns,
         if so we use them instead of the default ones}
        n2:=n.nextNode;
        if (n2<>nil) and (n2.nType<>ntNOP){i.e. avoid any optimiser chain additions to the root: todo: fix any more like this!} then
        begin
          {Change each column name}
          colCount:=0;
          while n2<>nil do
          begin
            if colCount<r.fTuple.colCount then
              r.fTuple.fColDef[colCount].name:=n2.idVal;

            n2:=n2.nextNode;
            inc(colCount); //note: this will end 1 past last colRef = colCount
          end;
          {Check we had enough names for the number of columns in the view, else syntax error}
          if colCount<>r.fTuple.ColCount then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format(seSyntaxNotEnoughViewColumnsText,[nil]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            st.addError(seSyntaxNotEnoughViewColumns,seSyntaxNotEnoughViewColumnsText);
            exit; //abort
            //Note: (todo) we could continue if we had too many...? but we'd need to assume user knew what they were doing & only use leftmost names
          end;
        end;
        //else stick with the default names...
        //todo: error if any of these are system generated! as per standard

        {Create the view definition}
        //Note: (todo) since we've just built the plan, are there any more details we can
        //      store now that will save time later - especially since we've also expanded any
        //      views that this view is using - e.g. we might be able to determine now
        //      whether the view is SQL-updatable or not.
        //      We maybe should store the whole iterator plan; but no, because the best plan
        //      may change depending on what else the view is joined with.
        viewDef:=nroot.strVal; //this has leading & trailing garbage (e.g. VN AS SELECT... NEXTLEXEME) so trim
        viewDef:='CREATE VIEW '+viewDef; //Note: we store the whole creation script
        result:=r.createNew(st,nroot.leftChild.leftChild,''{todo remove schema_id},nroot.leftchild.rightChild.idVal,True,viewDef{todo remove! st.LastInputText}{todo ensure this is only ever the create view statement!});
        if result=ok then
        begin
          //simulate empty scan to avoid problem with scan-open pinning page
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,r.fTuple.ShowHeading,vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,stringOfChar('=',length(r.fTuple.ShowHeading)),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}

          {Add PUBLIC privilege if this is an INFORMATION_SCHEMA view
          Note/todo: I think we should do this explicitly during createDB!!!!}
          (*todo wait until we have sysSchema etc. open during info_schema create
          if (r.schemaId=InformationSchemaId) then
          begin
            result:=PrepareSQL(st,format(
              'INSERT INTO %s.sysTableColumnPrivilege VALUES '+
              '(%d,null,1,2,''%s'',''%s''); ',
              [sysCatalogDefinitionSchemaName, r.tableId,ptSelect,Yes]),
              tr.sysStmt,resultErrCode,resultErrText);
            if result=ok then result:=ExecutePlan(st,tr.sysStmt,resultRowCount,resultErrCode,resultErrText);
            if result<>ok then
              //todo make these Failure messages generic/parameter driven to save resource space!
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'  Failed inserting sysTableColumnPrivilege rows via PrepareSQL/ExecutePlan: '+resultErrText,vError) //todo should be assertion? unless at runtime after release?
              {$ENDIF}
            else
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnPrivilege',[resultRowCount]),vdebug);
              {$ELSE}
              ;
              {$ENDIF}
            if UnPreparePlan(st,tr.sysStmt)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); //todo assertion
              {$ELSE}
              ;
              {$ENDIF}
          end;
          *)
        end
        else
        begin
          case result of
            -2: st.addError(seSyntaxTableAlreadyExists,seSyntaxTableAlreadyExistsText);
            -3: st.addError(sePrivilegeCreateTableFailed,sePrivilegeCreateTableFailedText);
            -4: begin result:=-5; st.addError(seUnknownCatalog,seUnknownCatalogText); end;
            -5: begin result:=-6; st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[''])); end;
          else
            st.addError(seFail,seFailText); //todo general error ok?
          end; {case}
          exit; //abort
        end;
      finally
        {Now close the plan}
        {Note: we defer cleaning up of the algebra and iterator plans to the syntax tree deletion}
      end; {try}
    end;
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Defined %s',[nroot.leftChild.rightChild.idVal]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
  finally
    r.free;
  end; {try}
end; {CreateView}

function CreateRoutine(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a routine (procedure/function)
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntCreateRoutie node

 RETURNS:  Ok,
           -2 = routine already exists
           -3 = not privileged
           -4 = syntax error: result cannot be specified for non-function
           -5 = syntax error: result must be specified for function
           -6 = syntax error: function cannot have out parameters
           -7 = catalog not found
           -8 = schema not found
           else Fail
}
const routine=':CreateRoutine';
var
  r:TRoutine;
  n,n2:TSyntaxNodePtr;
  varCount:integer;

  routineType:string; //routine type
  routineDef:string;  //routine definition text

  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root
//todo directly use stmt - not locals - but needed else compiler type errors

  varDomainId:integer; //n/a
  varVariableType:TVariableType;
  varDataType:TDatatype;
  varWidth:integer;
  varScale:smallint;
  varDefaultVal:string;
  varDefaultNull:boolean;
  returnsFound:boolean;
  outFound:boolean;
begin
  atree:=nil;
  ptree:=nil;

  routineDef:='';
  routineType:='';

  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}

  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  r:=TRoutine.create;
  try
    varCount:=0;
    returnsFound:=false;
    outFound:=false;
    {Loop through parameter sub-tree chain}
    n:=n.rightChild;
    repeat
      if n.nType=ntParameterDef then
      begin
        {Note:
          this also include any return result: the parser coerces this into a parameter (varType=vtResult)
        }

        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('parameter %p %d %s',[n,ord(n.ntype),n.leftchild.idVal]),vDebug);
        {$ENDIF}

        {Note: some of this code is duplicated in the ntCast evaluation}

        result:=DetermineDatatype(st,n.rightChild,
                                  varDomainId{n/a},varDataType,varWidth,varScale,varDefaultVal,varDefaultNull,varVariableType);
        if result<>ok then exit; //abort

        if varVariableType=vtResult then returnsFound:=True;
        if varVariableType in [vtOut,vtInOut] then outFound:=True;

        //todo syntax assertion if already found a vtResult, i.e. max=1
        inc(varCount); //need to increment before SetVarDef
        r.fVariableSet.VarCount:=varCount; //set the new number of variables before SetVarDef
        r.fVariableSet.SetVarDef(st,varCount-1,varCount,n.leftChild.idVal,
                           varVariableType, varDataType,
                           varWidth,varScale,
                           varDefaultVal,varDefaultNull);
        //todo inc fVarCount here? - for subscript checks etc
      end;

      if n.nType<>ntParameterDef then //todo replace with if ntype=sql-stmt = safer if append other nodes later
      begin //not a parameter_def, i.e. the sql_compound_element itself
        {Create the view definition}
        //Note: (todo) since we've just built the plan, are there any more details we can
        //      store now that will save time later - especially since we've also expanded any
        //      views that this view is using - e.g. we might be able to determine now
        //      whether the view is SQL-updatable or not.
        //      We maybe should store the whole iterator plan; but no, because the best plan
        //      may change depending on what else the view is joined with.
        routineDef:=nroot.strVal; //this has leading & trailing garbage (e.g. VN AS SELECT... NEXTLEXEME) so trim
        //Note: we add CREATE procedure/function prefix later
      end;

      n:=n.nextNode; //move to next parameter definition
    until n=nil;

    {Loop through routine name/options sub-tree chain}
    n:=nroot.leftChild;
    repeat
      if n.nType=ntProcedure then
      begin
        routineType:=rtProcedure;
        routineDef:='CREATE PROCEDURE'+routineDef; //Note: we store the whole creation script
      end;
      if n.nType=ntFunction then
      begin
        routineType:=rtFunction;
        routineDef:='CREATE FUNCTION'+routineDef; //Note: we store the whole creation script
      end;

      //todo handle other options

      n:=n.nextNode; //move to next parameter definition
    until n=nil;


    {$IFDEF DEBUG_LOG}
    log.quick('ROUTINE_DEF='+routineDef);
    {$ENDIF}

    //todo! if routineDef='' then syntax assertion!
    //todo! if routineType='' then syntax assertion!
    {Syntax errors}
    if returnsFound and (routineType<>rtFunction) then
    begin
      result:=-4;
      st.addError(seReturnsNotAllowed,seReturnsNotAllowedText);
      exit; //abort
    end;
    if not returnsFound and (routineType=rtFunction) then
    begin
      result:=-5;
      st.addError(seReturnsRequired,seReturnsRequiredText);
      exit; //abort
    end;
    if outFound and (routineType=rtFunction) then
    begin
      result:=-6;
      st.addError(seOutNotAllowed,seOutNotAllowedText);
      exit; //abort
    end;
    //todo prevent functions from updating any data!

    {Create the routine}
    result:=r.createNew(st,nroot.leftChild.leftChild,'',nroot.leftchild.rightChild.idVal,routineType,routineDef);

    if result=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Defined %s (owner=%s)',[nroot.leftChild.rightChild.idVal,Ttransaction(st.owner).AuthName]),vDebugLow);
      {$ENDIF}

      //simulate empty scan to avoid problem with scan-open pinning page
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,r.fVariableSet.ShowHeading,vDebugLow);
      {$ENDIF}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,stringOfChar('=',length(r.fVariableSet.ShowHeading)),vDebugLow);
      {$ENDIF}
{$IFDEF DEBUG_LOG}
//      log.quick('unpinning '+intTostr(r.dbFile.startPage));
{$ELSE}
;
{$ENDIF}
//      s.buffer.unpinPage(s.db,r.dbFile.startPage); //unpin start page to release it
                                                   //the scan routines can't auto do this
                                                   //because empty-scan = scan not started
    end
    else //create failed
    begin
      case result of
        -2: st.addError(seSyntaxRoutineAlreadyExists,seSyntaxRoutineAlreadyExistsText);
        -3: st.addError(sePrivilegeCreateTableFailed,sePrivilegeCreateTableFailedText);
        -4: begin result:=-7; st.addError(seUnknownCatalog,seUnknownCatalogText); end;
        -5: begin result:=-8; st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[''])); end;
      else
        st.addError(seFail,seFailText); //todo general error ok?
      end; {case}
    end;

  finally
    r.free;
  end; {try}
end; {CreateRoutine}

function CreateDomain(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a domain
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntCreateDomain node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           else Fail
}
const routine=':CreateDomain';
var
  n,n2:TSyntaxNodePtr;
  colDomainId:integer; //n/a
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;
  colVariableType:TVariableType; //n/a

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;
  dummy_null:boolean;
  sysSchemaR:TObject; //Trelation

  DomainName:string;
  DomainId,genId:integer;
  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  DomainName:=nroot.leftChild.rightChild.idVal;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining %s',[DomainName]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  try
    {todo get datatype from n.rightChild
     add domain entry into sysDomain
     (check we can't define domains on domains)
     add any checks (below) to the sysConstraint or sysCheck? table
     with a corresponding link in sysDomainConstraint
     add any default below to the domain entry in sysDomain
     - note: similar code should be copied to createTable

     Usage:
     column_id -> domain_id -> sysDomain -> sysDomainConstraint -> list of sysConstraint to apply
     column_id -> sysTableConstraint -> list of sysConstraint to apply on top of domain constraints (check with spec)
     column_id -> colDefault to use
     column_id -> domain_id -> sysDomain -> domDefault to use if no colDefault

     Tables: (CS=catalog_id,schema_id)
     sysColumn (CS,column_id, domain_id, default,...)
     sysDomain (CS,domain_id, default,...)
     sysConstraint (CS,constraint_id, type, type_check_details)
     sysTableConstraint (C S?,table_id,column_id, constraint_id)
     sysDomainConstraint (C S?,domain_id, constraint_id)

     During insert/update start, gather constraints & build expression trees to attach to each
     target column.
     Or, do this at relation open time? (& avoid if relation opened as read-only... i.e. those in iterRelation, etc.)
     Attach the ability at relation.open time (& just after initial creation!)
     e.g. Trelation.attachConstraintTrees- & tuple.insert to check any tree had been built else security error!
     No: only places we can insert & update it via iterInsert/iterUpdate (check!!!!) so they should call
         Trelation.attachConstraintTrees just before needed

     Note: same place (wherever) should be used (add hooks now) for update/insert permission checking...
    }

    {Get datatype}
    result:=DetermineDatatype(st,n.rightChild,
                              colDomainId{n/a},colDataType,colWidth,colScale,colDefaultVal,colDefaultNull,colVariableType{n/a});
    if result<>ok then exit; //abort

    {Now add the new domain to the system catalog}
    {We use the default/system stmt plan to add the catalog entries
     Benefits:
       simple
       no need for explicit structure knowledge = no maintenance
       transaction handling is correct - no need for our DDL to auto-commit like most other dbms's
     Downside:
       need to parse, build query tree, execute iterator plan etc.  = slower than direct insert into relation
       - but this only take a few milliseconds, so worth it for the benefits
    }

    //todo add any specified catalog/schema prefix!
    tempResult:=getOwnerDetails(st,nroot.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
    if tempResult<>ok then
    begin  //couldn't get access to sysSchema
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugLow);
      {$ENDIF}
      result:=tempResult;
      case result of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      end; {case}
      exit; //abort
    end;

    //todo check it doesn't already exist! maybe a future primary key will prevent this...
    //todo: here and other sys-creation places: probably need a setSavepoint...finally rollback to savepoint/commit
    //                                          to ensure these actions are atomic
    {We need to insert as _SYSTEM to ensure we have permission on sysDomain (plus is quicker since _SYSTEM has ownership rights)}
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail

      {Check we have no domain with this name already}
      result:=ExecSQL(tempStmt,
        format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysDomain WHERE schema_id=%d AND domain_name=''%s'') ',
             [sysCatalogDefinitionSchemaName, schema_Id,DomainName])
             ,nil,resultRowCount);
      if result<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed checking domain existence: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
        {$ENDIF}
        resultRowCount:=1; //assume exists
      end;
      if resultRowCount<>0 then
      begin
        result:=-4; //domain exists
        st.addError(seSyntaxDomainAlreadyExists,seSyntaxDomainAlreadyExistsText);
        exit; //abort
      end;

      genId:=0; //lookup by name
      result:=(Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysDomain_generator',genId,DomainId);
      if result<>ok then
        exit; //abort

      result:=ExecSQL(tempStmt,
        format('INSERT INTO %s.sysDomain (domain_id,domain_name,schema_id,datatype,width,scale,"default") '+
               'VALUES (%d,''%s'',%d,%d,%d,%d,''%s''); ', //todo handle case when colDefaultNull=true
               [sysCatalogDefinitionSchemaName,DomainId,DomainName,schema_Id,ord(colDataType),colWidth,colScale,colDefaultVal])
              ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysDomain row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release?
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysDomain',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?

      {Add any domain constraint(s)
       Note: SQL/92 allows 1 constraint but table structures are designed to allow multiple for SQL/99}
      {Loop through chain to check for constraints etc. for this domain}
      n2:=n.rightChild;
      while n2.nextNode<>nil do
      begin
        n2:=n2.nextNode;

        case n2.nType of
          ntConstraintDef:
          begin
            //todo in future: pass this domainId to the createConstraint routine
            //  because it must check that the check-constraint does not refer to it (directly or indirectly)
            //  i.e. check for circularity that would indicate recursion...
            //   - maybe best way to do this is to test-evaluate the constraint before we add (or make visible)
            //     this domain. If it fails with 'unknown domain: this' then = invalid recursion
            //  Note: if we don't check, then when we use it we will infinitely loop!
            //        so for now, constraint checking should have a recursion count-out to detect this //todo

            {We need to use our real authId, because constraint creation may need to check our privileges, e.g. for references}
            Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
            Ttransaction(st.owner).AuthName:=saveAuthName;
            try
              ConstraintId:=CreateConstraint(st,n2,schema_id,nroot,nil,-1);
            finally
              {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
              Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
              Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
            end; {try}
            if ConstraintId<=ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed adding constraint, continuing for now...',[nil]),vDebugError)
              {$ELSE}
              ;
              {$ENDIF}
              //todo fail domain creation? - need to rollback last stmt at least!! -need sys-level savepoints..?
            end
            else
            begin
              {Add constraint entry for this domain entry}
              Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
              result:=ExecSQL(tempStmt,
                format('INSERT INTO %s.sysDomainConstraint (domain_id,constraint_id) '+
                       'VALUES (%d,%d); ',
                       [sysCatalogDefinitionSchemaName, DomainId,ConstraintId])
                       ,nil,resultRowCount);
              if result<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,'  Failed inserting sysDomainConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                {$ENDIF}
              else
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Inserted %d entries into sysDomainConstraint',[resultRowCount]),vdebug);
                {$ELSE}
                ;
                {$ENDIF}
                //todo assert resultRowCount=1?
            end;
          end;
        end; {case}
      end; {while}

    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Defined %s',[DomainName]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
  finally
  end; {try}
end; {createDomain}

{Alter}
function AlterTable(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Alters a table
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntAlterTable node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           -4 = view not allowed
           -5 = not authorised
           -6 = new constraint is not applicable to the existing data
           else Fail

 Note:
}
const routine=':AlterTable';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;

  constraintValid:boolean;

  errNode:TErrorNodePtr;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Altering %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if dropped column is referenced by view/constraint etc?

    what if another transaction is inserting/scanning/re-indexing?

    check cascade option (in rightChild) for drops

    check if we are allowed to alter this table! must we own its schema?
  }

  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    tempResult:=r.open(st,n2.leftChild,'',name,isView,viewDefinition);
    if tempResult=ok then
    begin
      if isView then
      begin
        result:=-4; //view not allowed here
        st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
        exit; //abort
      end;

      if (r.authId<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
      begin
        result:=-5; //todo ok error value?
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to alter '+name]));
        exit; //abort
      end;

      if True then
      begin
        //todo: if any of these fail, abort & rollback(?)
        //todo: devise a neater way to bundle these together!

        {We need to alter as _SYSTEM to ensure we have permissions on sys tables (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try

          case n.rightChild.nType of
            ntAddColumn:
            begin
              {left is column_def}

              {todo
                 simply determineDatatype and add entry to sysColumn
                   plus add any column constraint as per createTable
                 default = null if data is missing (no extra space needed for old rows!)
                   otherwise need to Update table set newcol=newdefault
              }

              result:=-1; //not allowed yet
              st.addError(seNotImplementedYet,format(seNotImplementedYetText,['ALTER TABLE ADD COLUMN']));
              exit; //abort
            end; {ntAddColumn}

            ntAlterColumn:
            begin
              {left is column, right is nil (set default) or default_def}
              result:=-1; //not allowed yet
              st.addError(seNotImplementedYet,format(seNotImplementedYetText,['ALTER TABLE ALTER COLUMN']));
              exit; //abort
            end; {ntAlterColumn}

            ntDropColumn:
            begin
              {left is column, right is restrict/cascade}

              {todo
                 simply delete entry from sysColumn
                   plus delete any column constraint as per dropTable
                 could leave old data lying around
                   or get garbage collector to shrink unreferenced rows
                   or create new table copy and load
                   or suggest online backup & restore
              }

              result:=-1; //not allowed yet
              st.addError(seNotImplementedYet,format(seNotImplementedYetText,['ALTER TABLE DROP COLUMN']));
              exit; //abort
            end; {ntDropColumn}


            ntAddConstraint:
            begin
              n:=n.rightChild.leftChild; //left is base_table_constraint_def

              //todo assert n.nType=ntConstraintDef?

              //code taken from createTable - todo keep in sync. (modified to avoid drop table if fail)
              constraintValid:=True;

              {If this is a primary key, check it has also been defined as not null} //todo in future, must assume not null
              if n.rightChild.nType=ntPrimaryKeyDef then
              begin
                (*todo- check columns are (already defined) not null
                constraintValid:=False;
                n3:=n.rightChild;
                while n3.nextNode<>nil do
                begin
                  n3:=n3.nextNode;

                  if n3.nType=ntNotNull then
                  begin
                    constraintValid:=True;
                    break;
                  end;
                end;
                *)
              end;

              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('adding a table constraint',[nil]),vDebug);
              {$ENDIF}

              if constraintValid then
              begin
                {We need to use our real authId, because constraint creation may need to check our privileges, e.g. for references}
                Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
                Ttransaction(st.owner).AuthName:=saveAuthName;
                try
                  ConstraintId:=CreateConstraint(st,n,r.schemaId,nroot,r,-1);
                finally
                  {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
                  Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
                  Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
                end; {try}
              end
              else
                ConstraintId:=fail;

              if ConstraintId<=ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed adding constraint',[nil]),vDebugError);
                {$ENDIF}
                result:=Fail;
                exit;
              end
              else
              begin
                {Add constraint entry for this table entry}
                Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
                result:=ExecSQL(tempStmt,
                  format('INSERT INTO %s.sysTableColumnConstraint (table_id,column_id,constraint_id) '+
                         'VALUES (%d,%d,%d); ',
                         [sysCatalogDefinitionSchemaName, r.tableId,0{=table-level: Note not-null=child end of FK},ConstraintId])
                         ,nil,resultRowCount);
                if result<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'  Failed inserting sysTableColumnConstraint row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
                  {$ENDIF}
                else
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnConstraint',[resultRowCount]),vdebug);
                  {$ELSE}
                  ;
                  {$ENDIF}
                //todo assert resultRowCount=1?

                {Now check the new constraint is valid & if not, delete it & abort
                 Note: none of the books/standard seems to mention this, but it seems essential to me!
                }
                {We need to use our real authId, because constraint checking may need to check our privileges, e.g. for references}
                Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
                Ttransaction(st.owner).AuthName:=saveAuthName;
                try
                  result:=addConstraint(tempStmt,nil,r.schemaName,r.tableId,r.relName,0,constraintId,ccStandalone,ceChild); //todo check result
                  result:=(tempStmt.constraintList as Tconstraint).checkChain(tempStmt,nil,ctStmt,ceChild);
                  (tempStmt.constraintList as Tconstraint).clearChain;
                finally
                  {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnConstraint (plus is quicker since _SYSTEM has ownership rights)}
                  Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
                  Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
                end; {try}
                if result<>ok then //the new constraint failed, so it cannot apply to the data in the table so we discard it & abort
                begin
                  result:=-6;

                  {Copy any constraint failure errors to our stmt}
                  errNode:=tempStmt.errorList;
                  while errNode<>nil do
                  begin
                    st.addError(errNode.code,errNode.text);
                    errNode:=errNode.next;
                  end;

                  st.addError(seTableConstraintNotAdded,seTableConstraintNotAddedText);

                  deleteConstraint(tempStmt,constraintId); //zap the bad constraint
                  exit; //abort
                end;
              end;
            end; {ntAddConstraint}

            ntDropConstraint:
            begin
              n:=n.rightChild; //left is constraint, right is restrict/cascade

              result:=dropConstraint(st,n,r.TableId);
            end; {ntDropConstraint}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown table alteration %d',[ord(n.rightChild.nType)]),vAssertion);
            {$ENDIF}
            result:=Fail;
            exit;
          end; {case}
          //note: n is now repointed
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}

        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Altered %s',[name]),vDebugLow);
        {$ENDIF}
      end;
    end
    else
    begin
      case tempResult of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      else
        st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      end; {case}
      result:=-3; //could not find base_table or view
      exit; //abort
    end;
  finally
    r.free; //todo: make sure this won't try to touch catalog again, since there's nothing left!
  end; {try}
end; {AlterTable}

{Drop}
function DropTable(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a table
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropTable node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           -4 = not privileged
           -5 = dependent constraint(s) exist
           else Fail

 Note:
   currently does an implicit DELETE FROM table
   to check for any constraint violations unless tr.authId=_SYSTEM (e.g. aborting table creation)
}
const routine=':DropTable';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  sysDomainR:TObject; //Trelation

  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if referenced by view/constraint etc?

    what if another transaction is inserting/scanning/re-indexing?

    check cascade option (in rightChild)

    check if we are allowed to zap this table! must we own its schema?
  }

  {For now, we can't cascade and zap the constraints that depend on this table's key constraints
   todo!}
  if (n.rightChild<>nil{in case optional/default in future}) and (n.rightChild.nType=ntCascade) then
  begin
    st.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP TABLE...CASCADE'])+' (use RESTRICT)');
    exit; //abort
  end;

  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    tempResult:=r.open(st,n2.leftChild,'',name,isView,viewDefinition);
    if tempResult=ok then
    begin
      if (r.authId<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
      begin
        result:=-4; //todo ok error value?
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop '+name]));
        exit; //abort
      end;

      if True then
      begin
        //todo: if any of these fail, abort & rollback(?)
        //todo: devise a neater way to bundle these together!

        if (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
        begin
        end;
        //else leave to the _SYSTEM user to explicitly do this

        {$IFDEF DEBUG_LOG}
        //todo keep list in sync. with all reference to table_id in sys catalog.
        {$ENDIF}

        {We need to delete as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try
          {Check we have no dependent constraints}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS '+
                    '(SELECT 1 FROM %s.sysConstraint '+
                    ' WHERE fk_parent_table_id = %d) ', //todo and constraint type=FK?
                     [sysCatalogDefinitionSchemaName,r.tableId])
                 ,nil,resultRowCount);
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Failed checking table candidate key dependents: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
            resultRowCount:=1; //assume exists
          end;
          if resultRowCount=1 then
          begin
            result:=-5; //dependent constraint(s) exist
            st.addError(seTableHasConstraint,seTableHasConstraintText);
            exit; //abort
          end;

          //todo if cascade: loop through dependent constraints & drop them via temporary syntax node+restrict

          {Ok, safe to drop the table & all its metadata}
          {Remove any constraint entries for the table/columns}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTableColumnConstraint WHERE table_id=%d ',
                   [sysCatalogDefinitionSchemaName, r.tableId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTableColumnConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          //Note: we must also do the above for all parent/child FK table entries
          //      that are linked to this table by the constraints we delete next
          //      Note+: these could be from other schemas...
          //      (because the constraint finding code searches by tableColumnconstraint first)
          //      (i.e. we need ON DELETE CASCADE in the sysConstraint table! & then we'd only need 1 constraint DELETE)
          //      (or, even better: ON DELETE CASCADE in the sysTable table! - would clean up everything! SQL is great!)
          //      so... for now we do the following:
          {Remove any constraint entries for any FK parent table/columns}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTableColumnConstraint WHERE table_id IN '+
                   ' (SELECT FK_parent_table_id FROM %s.sysConstraint WHERE FK_child_table_id=%d AND rule_type=%d) ',
                   [sysCatalogDefinitionSchemaName, sysCatalogDefinitionSchemaName, r.tableId, ord(rtForeignKey)])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTableColumnConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTableColumnConstraint WHERE constraint_id IN (SELECT constraint_id FROM %s.sysConstraint WHERE FK_child_table_id=%d)',
                   [sysCatalogDefinitionSchemaName, sysCatalogDefinitionSchemaName, r.tableId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTableColumnConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysConstraint WHERE FK_child_table_id=%d ',
                   [sysCatalogDefinitionSchemaName, r.tableId])
                   ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysConstraint row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysConstraint',[resultRowCount]),vdebug);
          {$ENDIF}

          //todo: call DropIndex instead?
          {Remove any index columns for the table
           Note: we don't care about their origin}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysIndexColumn WHERE index_id IN (SELECT index_id FROM %s.sysIndex WHERE table_id=%d)',
                 [sysCatalogDefinitionSchemaName, sysCatalogDefinitionSchemaName, r.tableId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysIndexColumn row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndexColumn',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove any indexes for the table
           Note: we don't care about their origin}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysIndex WHERE table_id=%d',
                 [sysCatalogDefinitionSchemaName, r.tableId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysIndex row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndex',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove any privileges for the table}
          //todo use Revoke routine?
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTableColumnPrivilege WHERE table_id=%d',
                 [sysCatalogDefinitionSchemaName, r.tableId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTableColumnPrivilege row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnPrivilege',[resultRowCount]),vdebug);
          {$ENDIF}

          {Remove any columns for the table}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysColumn WHERE table_id=%d',
                 [sysCatalogDefinitionSchemaName, r.tableId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysColumn row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysColumn',[resultRowCount]),vdebug);
          {$ENDIF}
          //todo assert resultRowCount=colcount?

          {Remove the table}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysTable WHERE table_id=%d',
                 [sysCatalogDefinitionSchemaName, r.tableId])
                 ,nil,resultRowCount);
          {$IFDEF DEBUG_LOG}
          if result<>ok then
            log.add(st.who,where+routine,'Failed deleting sysTable row'{todo tempStmt.lastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          else
            log.add(st.who,where+routine,format('Deleted %d entries from sysTable',[resultRowCount]),vdebug);
          {$ENDIF}
          //todo assert resultRowCount=1?
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}

        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Dropped %s',[name]),vDebugLow);
        {$ENDIF}
      end;
    end
    else
    begin
      case tempResult of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      else
        st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      end; {case}
      result:=-3; //could not find base_table or view
      exit; //abort
    end;
  finally
    r.free; //todo: make sure this won't try to touch catalog again, since there's nothing left!
  end; {try}
end; {dropTable}

function DropView(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a view
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropView node

 RETURNS:  Ok, else Fail
}
const routine=':DropView';
begin
  result:=DropTable(st,nroot);
end; {DropView}

function DropIndex(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop an index
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropIndex node

 RETURNS:  Ok, else Fail

 Note:
}
const routine=':DropIndex';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  //viewDefinition:string;
  name,schema_name:string;

  //colCount:integer;
  //colDomainId:integer;
  //colDataType:TDatatype;
  //colWidth:integer;
  //ColScale:smallint;
  //colDefaultVal:string;
  //colDefaultNull:boolean;

  //tempi:integer;
  //dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //sysDomainR:TObject; //Trelation

  //ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  //todo HERE: find index & so table
  // delete from sysIndex & sysIndexColumn
  // call this routine from drop table for each index (but may miss some?)!
  st.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP INDEX']));

  (*todo HERE ***
  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    if n2.leftChild<>nil then
      schema_name:=n2.leftChild.rightChild.idVal
    else
      schema_name:='';
    if r.open(st,schema_name,name,isView,viewDefinition)=ok then
    begin
      if (r.authId<>tr.authID) and (tr.authID<>1) then  //todo replace 1 with constant for _SYSTEM
      begin
        result:=-4; //todo ok error value?
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop '+name]));
        exit; //abort
      end;

      if True then
      begin
        //todo: if any of these fail, abort & rollback(?)
        //todo: devise a neater way to bundle these together!

        {We need to delete as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=tr.AuthId;
        saveAuthName:=tr.AuthName;
        tr.AuthId:=1; //todo replace 1 with _SYSTEM constant
        tr.AuthName:='_SYSTEM'; //todo use constant
        try
          {Remove any index columns for the table} //todo any=the!
          result:=PrepareSQL(st,tr.sysStmt,nil,
            format('DELETE FROM %s.sysIndexColumn WHERE index_id IN (SELECT index_id FROM %s.sysIndex WHERE table_id=%d)',
                 [sysCatalogDefinitionSchemaName, sysCatalogDefinitionSchemaName, r.tableId])
                 );
          if result=ok then result:=ExecutePlan(st,tr.sysStmt,resultRowCount);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed deleting sysIndexColumn row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndexColumn',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(st,tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); //todo assertion
            {$ELSE}
            ;
            {$ENDIF}

          {Remove any indexes for the table} //todo any=the!
          result:=PrepareSQL(st,tr.sysStmt,nil,
            format('DELETE FROM %s.sysIndex WHERE table_id=%d',
                 [sysCatalogDefinitionSchemaName, r.tableId])
                 );
          if result=ok then result:=ExecutePlan(st,tr.sysStmt,resultRowCount);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed deleting sysIndex row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Deleted %d entries from sysIndex',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          if UnPreparePlan(st,tr.sysStmt)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); //todo assertion
            {$ELSE}
            ;
            {$ENDIF}
        finally
          tr.AuthId:=saveAuthId; //restore auth_id
          tr.AuthName:=saveAuthName;
        end; {try}

        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Dropped %s',[name]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
      end;
    end
    else
    begin
      result:=-3; //could not find base_table or view
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      exit; //abort
    end;
  finally
    r.free; //todo: make sure this won't try to touch catalog again, since there's nothing left!
  end; {try}
  *)
end; {dropIndex}

function DropRoutine(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a routine
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropRoutine node

 RETURNS:  Ok, else Fail

 Note:
   currently does not check for any dependencies //todo should!
}
const routine=':DropRoutine';
var
  r:TRoutine;
  n,n2:TSyntaxNodePtr;

  requestedType:string;
  routineType:string;
  routineDefinition:string;
  name:string;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if referenced by view/constraint etc?

    what if another transaction is executing?

    check cascade option (in rightChild)

    check if we are allowed to zap this routine! must we own its schema?
  }

  {Left child is routine reference}
  {Find routine}
  r:=TRoutine.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //routine name
    (*
    if n2.leftChild<>nil then
      schema_name:=n2.leftChild.rightChild.idVal
    else
      schema_name:='';
    *)

    {Find what kind of routine the user wants to drop}
    requestedType:='';
    n:=n2.nextNode;
    if n<>nil then
    begin
      if n.nType=ntProcedure then requestedType:=rtProcedure;
      if n.nType=ntFunction then requestedType:=rtFunction;
      //else ntProcedureOrFunction
    end;

    tempResult:=r.open(st,n2.leftChild,'',name,routineType,routineDefinition);
    if tempResult=ok then
    begin
      if (requestedType<>'') and (    ( (routineType=rtProcedure) and (requestedType<>rtProcedure) )
                                   or ( (routineType=rtFunction) and (requestedType<>rtFunction) ) ) then
      begin
        result:=-3; //found a routine but not of the requested type
        st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[name]));
        exit; //abort
      end;

      if (r.authId<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
      begin
        result:=-4; //todo ok error value?
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop '+name]));
        exit; //abort
      end;

      if True then
      begin
        //todo: if any of these fail, abort & rollback(?)
        //todo: devise a neater way to bundle these together!

        {We need to delete as _SYSTEM to ensure we have permission on sysParameterPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try
          {Remove any privileges for the routine}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysRoutinePrivilege WHERE routine_id=%d',
                 [sysCatalogDefinitionSchemaName, r.routineId])
                 ,nil,resultRowCount);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed deleting sysRoutinePrivilege row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Deleted %d entries from sysRoutinePrivilege',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}

          //todo use prepareAndExecute/ExecSQL everywhere...?

          {Remove any parameters for the routine}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysParameter WHERE routine_id=%d',
                 [sysCatalogDefinitionSchemaName, r.routineId])
                 ,nil,resultRowCount);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed deleting sysParameter row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Deleted %d entries from sysParameter',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
            //todo assert resultRowCount=colcount?
          {Remove the routine}
          Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
          result:=ExecSQL(tempStmt,
            format('DELETE FROM %s.sysRoutine WHERE routine_id=%d',
                 [sysCatalogDefinitionSchemaName, r.routineId])
                 ,nil,resultRowCount);
          if result<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'  Failed deleting sysRoutine row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Deleted %d entries from sysRoutine',[resultRowCount]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
            //todo assert resultRowCount=1?
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}

        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Dropped %s',[name]),vDebugLow);
        {$ENDIF}
      end;
    end
    else
    begin
      case tempResult of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      else
        st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[name]));
      end; {case}
      result:=-3; //could not find specified routine
      exit; //abort
    end;
  finally
    r.free; //todo: make sure this won't try to touch catalog again, since there's nothing left!
  end; {try}
end; {dropRoutine}

function DropSequence(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a sequence
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropSequence node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           else Fail

 Note:
   currently does not check for any dependencies //todo should!
}
const routine=':DropSequence';
var
  n,n2:TSyntaxNodePtr;

  sysGeneratorR:TObject; //Trelation
  s,s2:string;
  tempInt,tempInt2:integer;
  vnull:boolean;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if referenced by table/routine etc?

    what if another transaction is executing?

    check cascade option (in rightChild)

    check if we are allowed to zap this sequence! must we own its schema?
  }

  {Left child is sequence reference}
  {Find sequence}
  tempResult:=getOwnerDetails(st,n.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,s,schema_Id,s2,auth_id);
  if tempResult<>ok then
  begin  //couldn't get access to sysSchema
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed to find schema',[nil]),vDebugLow);
    {$ENDIF}
    result:=tempResult;
    case result of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    end; {case}
    exit; //abort
  end;

  s:=n.leftChild.rightChild.idVal;

  //todo lookup the generator once during pre-evaluation & then here = faster
  (* code copied from TDB.getGeneratorNext
   maybe we need a Tgenerator class? since we find(~open), create(~createNew) etc.
   or at least put this lookup into a routine: will be needed also by grant etc.
  *)
  {find generatorID for s}
  tempInt2:=0; //not found
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysGenerator,sysGeneratorR)=ok then
  begin
    try
      if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)=ok then
        try
        repeat
        {Found another matching generator for this name}
        with (sysGeneratorR as TRelation) do
        begin
          fTuple.GetInteger(ord(sg_Schema_id),tempInt,vnull);
          if tempInt=schema_Id then
          begin
            fTuple.GetInteger(ord(sg_Generator_Id),tempInt2,vnull);
            //already got generatorName
            //todo: too recent! fTuple.GetInteger(ord(sg_Generator_next),next,next_null);
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found generator %s in %s (with generator-id=%d)',[s,sysGenerator_table,tempInt2]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            result:=ok;
          end;
          //else not for our schema - skip & continue looking
        end; {with}
        until (tempInt2<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)<>ok);
              //todo stop once we've found a generator_id with our schema_Id, or there are no more matching this name
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysGeneratorR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysGenerator)]),vError); //todo abort?
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else generator not found
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysGenerator,sysGeneratorR)<>ok then
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
    log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysGenerator),s]),vDebugError); //todo assertion?
    {$ENDIF}
    st.addError(seFail,seFailText);
    result:=fail;
    exit; //abort
  end;

  if tempInt2<>0 then
  begin //found
    if (auth_id<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
    begin
      result:=-4; //todo ok error value?
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop '+s]));
      exit; //abort
    end;

    if True then
    begin
      //todo: if any of these fail, abort & rollback(?)
      //todo: devise a neater way to bundle these together!

      {We need to delete as _SYSTEM to ensure we have permission on sysGenerator (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        //todo {Remove any privileges for the sequence}

        {Remove the sequence}
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
        result:=ExecSQL(tempStmt,
          format('DELETE FROM %s.sysGenerator WHERE generator_id=%d',
               [sysCatalogDefinitionSchemaName, tempInt2])
               ,nil,resultRowCount);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed deleting sysGenerator row via PrepareSQL/ExecutePlan: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Deleted %d entries from sysGenerator',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}

      {Now remove the generator from the cache:
        this fix prevents the old remaining cached numbers from being issued if the generator is re-created
        (although a loophole still exists where another user referencing the uncommmitted deleted generator will
         re-cache it - todo: so make such users not see uncommitted deleted generators)
      }
      Ttransaction(st.owner).db.uncacheGenerator(st,schema_Id,s,tempInt2{genId});

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Dropped %s',[s]),vDebugLow);
      {$ENDIF}
    end;
  end
  else
  begin
    result:=-3; //could not find specified sequence
    st.addError(seSyntaxUnknownSequence,format(seSyntaxUnknownSequenceText,[s]));
    exit; //abort
  end;
end; {dropSequence}

function DropUser(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a user
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropUser node

 RETURNS:  Ok, else Fail

 Note:
   currently does not checks for:
        sysSchema
}
const routine=':DropUser';
var
  n,n2:TSyntaxNodePtr;

  name:string;
  sysAuthR:TObject; //Trelation
  s,s2:string;
  tempInt,tempInt2:integer;
  vnull:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;

  default_catalog_id,default_schema_id:integer;
  auth_name,auth_Type,password:string;
  auth_admin_role:integer;
  auth_name_null,auth_Type_null,password_null,default_catalog_id_null,default_schema_id_null,auth_admin_role_null:boolean;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if referenced by schema etc?

    what if another transaction is connected as this user?

    check cascade option (in rightChild)

    check if we are allowed to zap this user!
  }

  {For now, we can't cascade and zap the schemas this user owns
   todo!}
  if (n.rightChild<>nil{in case optional/default in future}) and (n.rightChild.nType=ntCascade) then
  begin
    st.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP USER...CASCADE'])+' (use RESTRICT)');
    exit; //abort
  end;

  {Left child is user reference}
  s:=n.leftChild.idVal;
  {Find user}
  //todo lookup the user once during pre-evaluation & then here = faster
  (* code also in TTransaction.connect
   maybe we need a Tuser class? since we find(~open), create(~createNew) etc.
   or at least put this lookup into a routine
  *)
  {find authID for s}
  tempInt2:=0; //not found
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysAuth,sysAuthR)=ok then
  begin
    try
      if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysAuthR,ord(sa_auth_name),s)=ok then
      begin
        {Found matching user for this name}
        with (sysAuthR as TRelation) do
        begin
          fTuple.GetInteger(ord(sa_auth_id),tempInt2,vnull);
          fTuple.GetString(ord(sa_auth_type),auth_Type,auth_Type_null);
          fTuple.GetString(ord(sa_password),password,password_null);
          fTuple.GetInteger(ord(sa_default_catalog_id),default_catalog_id,default_catalog_id_null);
          fTuple.GetInteger(ord(sa_default_schema_id),default_schema_id,default_schema_id_null);
          fTuple.GetString(ord(sa_auth_name),auth_name,auth_name_null);
          fTuple.GetInteger(ord(sa_admin_role),auth_admin_role,auth_admin_role_null);
          //we don't need to read sa_admin_option yet

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Found user %s in %s (with auth-id=%d)',[s,sysAuth_table,tempInt2]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          result:=ok;
        end; {with}
      end
      else //auth_id not found
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Unknown auth_id %s',[s]),vDebugLow);
        {$ENDIF}
      end;
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysAuth,sysAuthR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysAuth
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysAuth),s]),vDebugError); //todo assertion?
    {$ENDIF}
    st.addError(seFail,seFailText);
    result:=fail;
    exit; //abort
  end;

  if tempInt2<>0 then
  begin //found
    {Prevent dropping of admin, role, system, information_schema and default users}
    if (TadminRoleType(auth_admin_role){todo protect cast from garbage!}=atAdmin) or
       (auth_Type=atRole) or
       (tempInt2=SYSTEM_AUTHID) or (tempInt2=PUBLIC_AUTHID) or //note: these 2 are covered by the others anyway
       (uppercase(auth_name)=uppercase(sysInformationSchemaName){assume schema=user, as spec.}) or (uppercase(auth_name)=uppercase(DEFAULT_AUTHNAME)) then
    begin
      result:=-4; //todo ok error value?
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop user '+s]));
      exit; //abort
    end;

    {Check we have privilege}
    if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
       not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Not privileged to drop user %s for %d',[s,Ttransaction(st.owner).AuthId]),vDebugLow);
      {$ENDIF}
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop this user']));
      result:=Fail;
      exit;
    end;

    if True then
    begin
      //todo: if any of these fail, abort & rollback(?)
      //todo: devise a neater way to bundle these together!

      {We need to delete as _SYSTEM to ensure we have permission on sysUser (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail

        {Check we have no schemas owned by this user}
        //note: 1st internal SELECT...
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysSchema WHERE auth_id=%d) ',
               [sysCatalogDefinitionSchemaName, tempInt2])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropSchema

          result:=-4; //user had dependencies
          st.addError(seAuthHasSchema,seAuthHasSchemaText);
          exit; //abort
        end;


        {Remove the user}
        result:=ExecSQL(tempStmt,
          format('DELETE FROM %s.sysAuth WHERE auth_id=%d',
               [sysCatalogDefinitionSchemaName, tempInt2])
               ,nil,resultRowCount);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed deleting row: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Deleted %d entries',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Dropped %s',[s]),vDebugLow);
      {$ENDIF}
    end;
  end
  else
  begin
    result:=-3; //could not find specified user
    st.addError(seUnknownAuth,format(seUnknownAuthText,[s]));
    exit; //abort
  end;
end; {dropUser}

function DropSchema(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Drop a schema
 IN:
           tr        transaction
           st        statement
           nroot     pointer to ntDropSchema node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           else Fail

 Note:
   currently does not checks for:
        sysSchema
}
const routine=':DropSchema';
var
  n,n2:TSyntaxNodePtr;

  name:string;
  s,s2:string;
  tempInt:integer;
  vnull:boolean;

  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Dropping %s',[n.leftChild.idVal]),vDebug);
  {$ENDIF}

  {todo check not in use:
    what if referenced by another schema etc? e.g. constraints

    what if another transaction is connected to this schema?

    check cascade option (in rightChild)

    check if we are allowed to zap this schema!
  }

  {For now, we can't cascade and zap the schema objects this schema owns
   todo!}
  if (n.rightChild<>nil{in case optional/default in future}) and (n.rightChild.nType=ntCascade) then
  begin
    st.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP SCHEMA...CASCADE'])+' (use RESTRICT)');
    exit; //abort
  end;

  {Left child is schema reference}
  s:=n.leftChild.rightchild.idVal;
  {Find schema}
  //todo lookup the schema once during pre-evaluation & then here = faster
  tempResult:=getOwnerDetails(st,n.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
  if tempResult<>ok then
  begin  //couldn't get access to sysSchema
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed to find %s',[s]),vDebugLow);
    {$ENDIF}
    result:=tempResult;
    case result of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[s]));
    end; {case}
    exit; //abort
  end;

  if schema_Id<>0 then
  begin //found
    (*
    table           dropview/table
    routine         droproutine
    domain          dropdomain
    generator       dropsequence
    constraint      droptable? unless from another schema's table? possible since table_ids are catalog unique

    & subroutines cascade/restrict as appropriate
    + they zap indexes/privileges

    auth->default
    *)

    {Prevent dropping of catalog definition, information and default schemas}
    if (schema_Id=sysCatalogDefinitionSchemaId) or
       (uppercase(schema_name)=uppercase(sysInformationSchemaName)) or
       (uppercase(schema_name)=uppercase('DEFAULT_SCHEMA')) then  //todo: use constant
    begin
      result:=-4; //todo ok error value?
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop schema '+s]));
      exit; //abort
    end;

    {Check we have privilege}
    if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
       not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) and
       not(auth_id=Ttransaction(st.owner).authID) then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Not privileged to drop user %s for %d',[s,Ttransaction(st.owner).AuthId]),vDebugLow);
      {$ENDIF}
      st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to drop this schema']));
      result:=Fail;
      exit;
    end;

    if True then
    begin
      //todo: if any of these fail, abort & rollback(?)
      //todo: devise a neater way to bundle these together!

      {We need to delete as _SYSTEM to ensure we have permission on sys tables (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail

        {Manual referential integrity!
         (hard to add FK constraints to system catalog because of dependencies...
          todo: should be possible once alter table is done...)}
        {Check we have no tables owned by this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysTable WHERE schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropTable

          result:=-4; //user had dependencies
          st.addError(seSchemaHasTable,seSchemaHasTableText);
          exit; //abort
        end;

        {Check we have no routines owned by this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysRoutine WHERE schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropRoutine

          result:=-4; //user had dependencies
          st.addError(seSchemaHasRoutine,seSchemaHasRoutineText);
          exit; //abort
        end;

        {Check we have no domains owned by this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysDomain WHERE schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropDomain

          result:=-4; //user had dependencies
          st.addError(seSchemaHasDomain,seSchemaHasDomainText);
          exit; //abort
        end;

        {Check we have no generators owned by this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysGenerator WHERE schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropSequence

          result:=-4; //user had dependencies
          st.addError(seSchemaHasSequence,seSchemaHasSequenceText);
          exit; //abort
        end;

        {Check we have no constraints owned by this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysConstraint WHERE schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then delete them now, preferably via dropTable

          result:=-4; //user had dependencies
          st.addError(seSchemaHasConstraint,seSchemaHasConstraintText);
          exit; //abort
        end;

        //todo auto set these to DEFAULT_SCHEMA?
        {Check we have no users defaulting to this schema}
        result:=ExecSQL(tempStmt,
          format('SELECT 1 FROM (VALUES(1)) AS DUMMY WHERE EXISTS (SELECT 1 FROM %s.sysAuth WHERE default_schema_id=%d) ',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed checking dependencies: '{todo getlastError},vError); //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
          resultRowCount:=1; //assume dependencies
        end;
        if resultRowCount<>0 then
        begin
          //todo: if cascade, then update them now, preferably via alterUser

          result:=-4; //user had dependencies
          st.addError(seSchemaIsDefault,seSchemaIsDefaultText);
          exit; //abort
        end;

        //todo: anything else? keep in synch with catalog_definition_schema / createSchema

        {Remove the schema}
        result:=ExecSQL(tempStmt,
          format('DELETE FROM %s.sysSchema WHERE schema_id=%d',
               [sysCatalogDefinitionSchemaName, schema_Id])
               ,nil,resultRowCount);
        if result<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed deleting row: '{todo getlastError},vError) //todo should be assertion? unless at runtime after release? //todo also, should rollback to savepoint...
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Deleted %d entries',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Dropped %s',[s]),vDebugLow);
      {$ENDIF}
    end;
  end
  else
  begin
    result:=-3; //could not find specified schema
    st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[s]));
    exit; //abort
  end;
end; {dropSchema}

//todo dropDomain etc.



function DebugTable(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug a table - i.e. describe its storage etc.
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugTable node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const routine=':DebugTable';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  sysDomainR:TObject; //Trelation

  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Debugging %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    if r.open(st,n2.leftChild,'',name,isView,viewDefinition)=ok then
    begin
      if isView then
      begin
        result:=-4; //view not allowed here
        st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
        exit; //abort
      end;

      if (r.authId<>Ttransaction(st.owner).authID) and (Ttransaction(st.owner).authID<>SYSTEM_AUTHID) then
      begin
        result:=-4;
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug '+name]));
        exit; //abort
      end;

      if True then
      begin
        {We need to view as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try
          if nroot.rightChild=nil then
            result:=r.debugDump(st,connection,False{detail})
          else
            result:=r.debugDump(st,connection,True{assume nroot.rightChild.nType=ntSummary});
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}
      end;
    end
    else
    begin
      result:=-3; //could not find base_table or view
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      exit; //abort
    end;
  finally
    r.free;
  end; {try}
end; {debugTable}

function DebugIndex(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug a table's hash indexes - i.e. describe their storage etc.
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugIndex node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail

 Note: will return fail if this table has no hash indexes
}
const routine=':DebugIndex';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  sysDomainR:TObject; //Trelation

  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;

  indexPtr:TIndexListPtr;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Debugging indexes of %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    if r.open(st,n2.leftChild,'',name,isView,viewDefinition)=ok then
    begin
      if isView then
      begin
        result:=-4; //view not allowed here
        st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
        exit; //abort
      end;

      if r.authId<>Ttransaction(st.owner).authID then
      begin
        result:=-4;
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug '+name]));
        exit; //abort
      end;

      if True then
      begin
        {We need to view as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try
          indexPtr:=r.IndexList;
          while indexPtr<>nil do
          begin
            if connection<>nil then
            begin
              connection.WriteLn(format('Index: [%d] %s',[indexPtr.index.indexId,indexPtr.index.name]));
              connection.WriteLn(format('Index status: %d',[ord(indexPtr.index.indexState)]));
            end;

            if indexPtr.index is THashIndexFile then
              if nroot.rightChild=nil then
                result:=(indexPtr.index as THashIndexFile).Dump(st,connection,False{detail})
              else
                result:=(indexPtr.index as THashIndexFile).Dump(st,connection,True{assume nroot.rightChild.nType=ntSummary});

            if connection<>nil then
              connection.WriteLn;

            indexPtr:=indexPtr.next;
          end;
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}
      end;
    end
    else
    begin
      result:=-3; //could not find base_table or view
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      exit; //abort
    end;
  finally
    r.free;
  end; {try}
end; {debugIndex}

function UserCreateIndex(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create an index
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntCreateIndex node

 RETURNS:  +ve=Ok (index_id), else Fail
}
const routine=':UserCreateIndex';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  nDef:TSyntaxNodePtr;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Creating index %s %s',[n.rightChild.rightChild.idVal,n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {Right child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.rightChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    tempResult:=r.open(st,n2.leftChild,'',name,isView,viewDefinition);
    if tempResult=ok then
    begin
      if isView then
      begin
        result:=-4; //view not allowed here
        st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
        exit; //abort
      end;

      if r.authId<>Ttransaction(st.owner).authID then
      begin
        result:=-4;
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to create index on '+name]));
        exit; //abort
      end;

      {Find the column list}
      nDef:=nroot.nextNode;

      if nDef<>nil then
      begin
        //todo: check this index name is unique & that these columns are not already indexed...

        {Note: the createIndex routine takes care of other active transactions using this table etc.}
        result:=CreateIndex(st,nDef,r.schemaId,nroot.leftChild.rightChild.idVal,ioUser,0,r,nil,0);
        if result<=0 then exit; //abort //todo! force rollback and/or remove partial index info from catalog & file
                                        //dbRecover/garbage collector might/should do this since still flagged as isBeingBuilt: at least will be ignored...

        //note also!
        //  this new index will become immediately available to all new statements
        //  but we/user must commit the create for it to have a (permanent?) effect!!!
        //  i.e. we could rollback the create!
      end
      else //no columns - should never happen
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Missing column list - should have received syntax error before now',[nil]),vAssertion);
        {$ENDIF}
        result:=-5;
        exit; //abort
      end;
    end
    else
    begin
      case tempResult of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      else
        st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      end; {case}
      result:=-3; //could not find base_table or view
      exit; //abort
    end;
  finally
    r.free;
  end; {try}
end; {UserCreateIndex}

function RebuildIndex(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Rebuild an index
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntRebuildIndex node
           connection  client connection to return raw results to //not used?

 RETURNS:  Ok, else Fail

 Note: will return fail if this index does not exist
}
const routine=':RebuildIndex';
var
  r:TRelation;
  n,n2:TSyntaxNodePtr;

  isView:boolean;
  viewDefinition:string;
  name:string;

  colCount:integer;
  colDomainId:integer;
  colDataType:TDatatype;
  colWidth:integer;
  ColScale:smallint;
  colDefaultVal:string;
  colDefaultNull:boolean;

  tempi:integer;
  dummy_null:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  sysDomainR:TObject; //Trelation

  ConstraintId:integer;

  //dummy results needed for prepareSQL/executePlan - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;

  indexPtr:TIndexListPtr;
  newIndexId:integer;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Rebuilding index %s %s',[n.leftChild.rightChild.idVal,n.rightChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  {Left child is table reference}
  {Find table}
  r:=TRelation.create; //cleaned up at end of this routine - just a temporary relation
  try
    n2:=nroot.leftChild; //todo assert if fail!
    name:=n2.rightChild.idVal; //table name
    tempResult:=r.open(st,n2.leftChild,'',name,isView,viewDefinition);
    if tempResult=ok then
    begin
      if isView then
      begin
        result:=-4; //view not allowed here
        st.addError(seSyntaxViewNotAllowed,format(seSyntaxViewNotAllowedText,[nil]));
        exit; //abort

      end;

      if r.authId<>Ttransaction(st.owner).authID then
      begin
        result:=-4;
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug '+name]));
        exit; //abort
      end;

      if True then
      begin
        {We need to view as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
        saveAuthId:=Ttransaction(st.owner).AuthId;
        saveAuthName:=Ttransaction(st.owner).AuthName;
        Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
        Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
        try
          indexPtr:=r.IndexList;
          while indexPtr<>nil do
          begin
            //todo assert nroot.rightChild exists! - todo: if not, rebuild all indexes!!
            if lowercase(indexPtr.index.name)=lowercase(nroot.rightChild.rightChild.idVal) then
            begin //matched
              if connection<>nil then
              begin //show before header
                connection.WriteLn('Before:');
                connection.WriteLn(format('Index: [%d] %s',[indexPtr.index.indexId,indexPtr.index.name]));
                connection.WriteLn(format('Index status: %d',[ord(indexPtr.index.indexState)]));
              end;
              if indexPtr.index is THashIndexFile then //show before dump
                result:=(indexPtr.index as THashIndexFile).Dump(st,connection,True{summary});

              if connection<>nil then connection.WriteLn('Rebuilding...');

              {1. Safely create a new index based on this indexes structure}
              newIndexId:=CreateIndex(st,nil,r.schemaId,indexPtr.index.name+'_rebuilding',indexPtr.index.indexOrigin,indexPtr.index.indexConstraintId,r,indexPtr.index,0);
              if newIndexId<=0 then exit; //abort //todo! force rollback and/or remove partial index info from catalog & file
                                              //dbRecover/garbage collector might/should do this since still flagged as isBeingBuilt: at least will be ignored...

              //todo here: must remove this index from all active stmts: if we can find a gap in their use/switch-over safely?

              //note also!
              //  this new index will become immediately available to all new statements
              //  but we/user must commit the rebuild for it to have a (permanent?) effect!!!
              //  i.e. we could rollback the rebuild!

              {3. Now delete the old index catalog entry}
                Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
                result:=ExecSQL(tempStmt,
                  format('DELETE FROM %s.sysIndex WHERE index_id=%d;',
                         [sysCatalogDefinitionSchemaName,indexPtr.index.indexId])
                         ,nil,resultRowCount);
                if result<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'  Failed deleting sysIndex row via PrepareSQL/ExecutePlan: '{todo getlastError},vError)
                  {$ENDIF}
                else
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Deleted %d entries from sysIndex',[resultRowCount]),vdebug);
                  {$ENDIF}
                  //todo assert resultRowCount=1?
                end;

              {4. Now rename the new index catalog entry to be the same as the old one we just deleted
                  Note: currently file is retained when opening the index (not index_name), so we update that as well.
              }
                Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
                result:=ExecSQL(tempStmt,
                  format('UPDATE %s.sysIndex SET index_name=''%s'', file=''%s'' WHERE index_id=%d;',
                         [sysCatalogDefinitionSchemaName,indexPtr.index.name,indexPtr.index.name,newIndexId])
                         ,nil,resultRowCount);
                if result<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'  Failed renaming sysIndex row via PrepareSQL/ExecutePlan: '{todo getlastError},vError)
                  {$ENDIF}
                else
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Updated %d entries in sysIndex',[resultRowCount]),vdebug);
                  {$ENDIF}
                  //todo assert resultRowCount=1?
                end;

              //TODO! we must now de-allocate the space used by the index!
              //         use a common De-allocate-chain routine...
              //  Note: use DROP INDEX above!


              (*todo: no point showing old one here! find new one!
              if connection<>nil then
              begin //show after header
                connection.WriteLn('After:');
                connection.WriteLn(format('Index: [%d] %s',[indexPtr.index.indexId,indexPtr.index.name]));
                connection.WriteLn(format('Index status: %d',[ord(indexPtr.index.indexState)]));
              end;
              if indexPtr.index is THashIndexFile then //show after dump
                result:=(indexPtr.index as THashIndexFile).Dump(st,connection);
              *)

              if connection<>nil then
                connection.WriteLn;
            end;

            indexPtr:=indexPtr.next;
          end;
        finally
          Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
          Ttransaction(st.owner).AuthName:=saveAuthName;
        end; {try}
      end;
    end
    else
    begin
      case tempResult of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      else
        st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[name]));
      end; {case}
      result:=-3; //could not find base_table or view
      exit; //abort
    end;
  finally
    r.free;
  end; {try}
end; {rebuildIndex}

function CreateSequence(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a sequence
 IN:
           s           statement
           nroot       pointer to ntCreateSequence node

 RETURNS:  +ve=Ok (sequence_id),
           -2 = unknown catalog
           -3 = unknown schema
           else Fail
}
const routine=':CreateSequence';
var
  n,n2:TSyntaxNodePtr;

  name:string;
  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  GeneratorId,genId:integer;
  generatorName:string;
  startAt:integer;

  tempStmt:TStmt;
  resultRowCount:integer;

  nDef:TSyntaxNodePtr;

  {for exists check}
  sysGeneratorR:TObject; //Trelation
  s,s2:string;
  tempInt,tempInt2:integer;
  vnull:boolean;
  tempResult:integer;
begin
  result:=Fail;
  n:=nroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Creating sequence %s',[n.leftChild.rightChild.idVal]),vDebug);
  {$ENDIF}

  try
    tempResult:=getOwnerDetails(st,nroot.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
    if tempResult<>ok then
    begin  //couldn't get access to sysSchema
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugLow);
      {$ENDIF}
      result:=tempResult;
      case result of
        -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
        -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
      end; {case}
      exit; //abort
    end;

    {Now check that we are privileged to add entries to this schema}
    if auth_Id<>Ttransaction(st.owner).authId then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('%d not privileged to insert into schema authorised by %d',[Ttransaction(st.owner).authId,auth_id]),vError);
      {$ENDIF}
      st.addError(sePrivilegeCreateTableFailed,sePrivilegeCreateTableFailedText);
      result:=-3;
      exit; //abort
    end;

    {Now check it doesn't already exist}
    //todo: use a single routine for this! or Tsequence?
    s:=n.leftChild.rightChild.idVal;

    //todo lookup the generator once during pre-evaluation & then here = faster
    (* code copied from TDB.getGeneratorNext
     maybe we need a Tgenerator class? since we find(~open), create(~createNew) etc.
     or at least put this lookup into a routine: will be needed also by grant etc.
    *)
    {find generatorID for s}
    tempInt2:=0; //not found
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysGenerator,sysGeneratorR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)=ok then
          try
          repeat
          {Found another matching generator for this name}
          with (sysGeneratorR as TRelation) do
          begin
            fTuple.GetInteger(ord(sg_Schema_id),tempInt,vnull);
            if tempInt=schema_Id then
            begin
              fTuple.GetInteger(ord(sg_Generator_Id),tempInt2,vnull);
              //already got generatorName
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found generator relation %s in %s (with generator-id=%d)',[s,sysGenerator_table,tempInt2]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              //result:=ok;
            end;
            //else not for our schema - skip & continue looking
          end; {with}
          until (tempInt2<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)<>ok);
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
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysGenerator,sysGeneratorR)<>ok then
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
      log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysGenerator),s]),vDebugError);
      {$ENDIF}
      result:=fail;
      exit; //abort
    end;

    if tempInt2<>0 then
    begin //found
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('%d not privileged to insert into schema authorised by %d',[Ttransaction(st.owner).authId,auth_id]),vError);
      {$ENDIF}
      st.addError(seSyntaxSequenceAlreadyExists,seSyntaxSequenceAlreadyExistsText);
      result:=-2;
      exit; //abort
    end;

    generatorName:=n.leftChild.rightChild.idVal;
    startAt:=1;

    {Check options}
    n2:=n.rightChild;
    while n2<>nil do
    begin
      case n2.nType of
        ntStartingAt:
        begin
          startAt:=trunc(n2.leftChild.numVal);
        end;
      end; {case}

      n2:=n2.nextNode;
    end; {while}

    //todo check it doesn't already exist! maybe a future primary key will prevent this...
    //todo: here and other sys-creation places: probably need a setSavepoint...finally rollback to savepoint/commit
    //                                          to ensure these actions are atomic
    genId:=0; //lookup by name
    result:=(Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysGenerator_generator',genId,GeneratorId);
    if result<>ok then
      exit; //abort
    {We need to insert as _SYSTEM to ensure we have permission on sysGenerator (plus is quicker since _SYSTEM has ownership rights)}
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
      result:=ExecSQL(tempStmt,
        format('INSERT INTO %s.sysGenerator (generator_id,generator_name,schema_id,start_at,"next",increment,cache_size,cycle) '+
               'VALUES (%d,''%s'',%d,%d,%d,%d,%d,''%s''); ',
               [sysCatalogDefinitionSchemaName,GeneratorId,generatorName,schema_Id,startAt,startAt,1,CACHE_GENERATORS_DEFAULT_SIZE,NoYes[False]])
              ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysGenerator row via PrepareSQL/ExecutePlan: '{todo getlastError},vError)
        {$ENDIF}
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysGenerator',[resultRowCount]),vdebug);
        {$ENDIF}
        //todo assert resultRowCount=1?

        result:=GeneratorId;
      end;
    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Defined %s',[generatorName]),vDebugLow);
    {$ENDIF}
  finally
  end; {try}
end; {CreateSequence}


function DebugCatalog(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug the catalog - i.e. describe the database storage etc.
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugCatalog node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const routine=':DebugCatalog';
var
  newDB:TDB;
begin
  {Check we have privilege}
  if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
     not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to debug a catalog for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug a catalog']));
    result:=Fail;
    exit;
  end;

  if Ttransaction(st.owner).db=nil then
  begin //without a valid db we won't find the server
    result:=fail;
    st.addError(seFail,seFailText);
    exit; //abort
  end;

  newDB:=(Ttransaction(st.owner).db.owner as TDBserver).findDB(nroot.leftChild.idVal); //assumes we're already connected to a db
  if newDB<>nil then
  begin
    if newDB<>Ttransaction(st.owner).db then
    begin //can only debug our current catalog, since pinPage etc. assumes st.owner.db is the database
      result:=fail;
      st.addError(seCanOnlyDebugCurrentDatabase,seCanOnlyDebugCurrentDatabaseText);
      exit;
    end;

    if nroot.rightChild=nil then
      result:=newDB.debugDump(st,connection,False{detail})
    else
      result:=newDB.debugDump(st,connection,True{assume nroot.rightChild.nType=ntSummary});
  end
  else
  begin
    result:=fail;
    st.addError(seUnknownCatalog,seUnknownCatalogText); //always ok?
    exit; //abort
  end;
end; {DebugCatalog}

function DebugServer(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug the server
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugServer node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const routine=':DebugServer';
begin
  if Ttransaction(st.owner).db=nil then
  begin //without a valid db we won't find the server
    result:=fail;
    st.addError(seFail,seFailText);
    exit; //abort
  end;
  //todo else we could use (Ttransaction(st.owner).thread as TCMThread).dbServer

  {Check we have privilege}
  if (not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
      not(Ttransaction(st.owner).authID=SYSTEM_AUTHID))
     or
     not((Ttransaction(st.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(st.owner).db) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to debug this server for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug this server']));
    result:=Fail;
    exit;
  end;

  if nroot.rightChild=nil then
    result:=(Ttransaction(st.owner).db.owner as TDBserver).debugDump(st,connection,False{detail})
  else
    result:=(Ttransaction(st.owner).db.owner as TDBserver).debugDump(st,connection,True{assume nroot.rightChild.nType=ntSummary});
end; {DebugServer}

function DebugPage(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug a page in the current catalog
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugPage node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const routine=':DebugPage';
var
  page:TPage;
  pid:PageId;
begin
  result:=fail;

  if Ttransaction(st.owner).db=nil then
  begin //without a valid db we won't find the page
    result:=fail;
    st.addError(seFail,seFailText);
    exit; //abort
  end;

  {Check we have privilege}
  if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
     not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to debug a page for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to debug a catalog page']));
    result:=Fail;
    exit;
  end;

  with Ttransaction(st.owner).db.owner as TDBserver do
  begin
    {Get page #}
    pid:=trunc(nroot.leftChild.numval);

    if buffer.pinPage(st,pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed reading specified page %d (could be out of range)',[pid]),vDebugError);
      {$ENDIF}
      exit; //abort
    end;
    try
      if nroot.rightChild=nil then
        result:=page.debugDump(st,connection,False{detail})
      else
        result:=page.debugDump(st,connection,True{assume nroot.rightChild.nType=ntSummary});

      result:=ok;
    finally
      buffer.unpinPage(st,pid); //todo leave pinned until ScanNext
    end; {try}
  end; {with}
end; {DebugPage}

function debugPlanNode(level:integer;p:Titerator;connection:TIdTCPConnection):integer;
{Recursively displays the iterator plan tree
}
const routine=':debugPlanNode';
var
  s:string;
begin
  result:=ok;

  if p=nil then exit; //done

  s:=p.description;

  s:=s+' ';

  if connection<>nil then
    connection.WriteLn(format('%s%s',[stringOfchar(' ',level*2),s]));

  debugPlanNode(level+1,p.leftChild,connection);
  debugPlanNode(level+1,p.rightChild,connection);
end; {debugPlanNode}

function DebugPlan(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug the plan
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugPlan node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const routine=':DebugPlan';
var
  sql:string;
  p:Titerator;
  errNode:TErrorNodePtr;
begin
  result:=ok;

  if Ttransaction(st.owner).db=nil then
  begin //without a valid db we won't find the server
    result:=fail;
    st.addError(seFail,seFailText);
    exit; //abort
  end;

  {Get SQL}
  sql:=nroot.leftChild.strval;

  {Build the plan}
  //todo: use new substmt!
  try
    st.deleteErrorList; //clear error stack

    {Prepare}
    result:=PrepareSQL(st,nil,sql);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('  prepareSQL returns %d',[result]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    try
      if result<>ok then
      begin
        exit; //abort batch
      end;

      if (st.sroot<>nil) and (st.sroot.ptree<>nil) then //a plan was created
      begin
        {Show the plan}
        //todo assert st.sroot.ptree is TIterator
        p:=st.sroot.ptree as Titerator;

        debugPlanNode(0,p,connection);

        (*todo detail?
        if nroot.rightChild=nil then
          result:=(Ttransaction(st.owner).db.owner as TDBserver).debugDump(st,connection,False{detail})
        else
          result:=(Ttransaction(st.owner).db.owner as TDBserver).debugDump(st,connection,True{assume nroot.rightChild.nType=ntSummary});
        *)
      end;
    finally
      {Close result set}
      st.CloseCursor(1{=unprepare});
    end; {try}
  finally
    if (result<>ok) and (result<>-999) then
    begin
      {Output any errors to the console}
      errNode:=st.errorList;
      if errNode=nil then
        if connection<>nil then
          connection.WriteLn(format('Error %5.5d: %s',[seFail,seFailText{$IFDEF DEBUG_LOG}+' (debug='+inttostr(result)+')'{$ENDIF}{todo improve}]));
      while errNode<>nil do
      begin
        //todo output errNode.code?
        if connection<>nil then
          connection.WriteLn(format('Error %5.5d: %s',[errNode.code,errNode.text]));
        errNode:=errNode.next;
      end;
    end;
    st.deleteErrorList;
  end; {try}
end; {DebugPlan}

function DebugPrint(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Debug print
 IN:
           tr          transaction
           s           statement
           nroot       pointer to ntDebugPrint node
           connection  client connection to return raw results to

 RETURNS:  Ok, else Fail
}
const
  routine=':DebugPrint';
  ceInternal='sys/pe'; //temp column name
var
  s:string;
  snull:boolean;
  p:Titerator;
  n:TSyntaxNodePtr;
  tempTuple,tempTuple2:TTuple;
  errNode:TErrorNodePtr;
begin
  result:=ok;

  if Ttransaction(st.owner).db=nil then
  begin //without a valid db we won't find the server
    result:=fail;
    st.addError(seFail,seFailText);
    exit; //abort
  end;

  {Get string}
  n:=nroot.leftChild;
  if n<>nil then
  begin
    result:=CompleteScalarExp(st,nil,n.leftChild{descend below ..._exp},agNone);
    if result<>ok then exit; //aborted by child

    {Now evaluate and print expression}
    tempTuple:=TTuple.create(nil);
    tempTuple2:=TTuple.create(nil);
    try
      {Define result as string}
      tempTuple2.ColCount:=1;
      tempTuple2.clear(st);
      tempTuple2.SetColDef(0,1,ceInternal,0,ctVarChar,0,0,'',True);

      tempTuple.ColCount:=1;
      tempTuple.clear(st);
      tempTuple.SetColDef(0,1,ceInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
      result:=EvalScalarExp(st,nil{not expecting column values here},n.leftChild{descend below ..._exp},tempTuple,0,agNone,false);
      if result<>ok then exit; //aborted by child
      tempTuple.preInsert; //prepare buffer

      {Convert (cast) & return result}
      result:=tempTuple2.CopyColDataDeepGetSet(st,0,tempTuple,0);
      if result<>ok then
      begin
        st.addError(seInvalidValue,format(seInvalidValueText,[nil]));
        exit; //abort the operation
      end;
      result:=tempTuple2.GetString(0,s,snull); //store result
      if result<>ok then
      begin
        st.addError(seInvalidValue,format(seInvalidValueText,[nil]));
        exit; //abort the operation
      end;

      if connection<>nil then
        connection.WriteLn(format('%s',[s]));
    finally
      tempTuple2.free;
      tempTuple.free;
    end; {try}
  end;
end; {DebugPrint}

//todo: move this to a more appropriate unit...
function CheckTableColumnPrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                                   do_authId_level_match:boolean;var authId_level_match:boolean;
                                   ownerAuth_id:integer;table_id:integer;column_id:integer; var table_level_match:boolean;
                                   privilege_type:TprivilegeType;grant_option_search:boolean;var grant_option:string):integer;
{Check the privilege of a table/column
 IN:        tr
            grantorAuth_id       the auth_id of the grantor for restricted match
                                 if 0, caller doesn't care about who granted a matching privilege
                                 if<>0,caller is only looking for a privilege granted by this auth_id
                                   (e.g. =0 for typical use, <>0 to check if a particular privilege already exists)
            granteeAuth_id       the auth_id of the grantee to check the privilege of
                                 (in future (for SQL3), this routine will also check for roles
                                  that this auth_id is a member of. Currently it will just check for
                                  the PUBLIC role. Any auth_id specific privilege will override any PUBLIC
                                  privilege)
            do_authId_level_match True=we keep searching even after we've found a role-level match
            ownerAuth_id         the auth id of the table owner (used for quick 'rights' check)
            table_id             (if SyntaxTableId, then assume rights to any caller)
            column_id            0=check for whole table privilege (currently => sysTableColumnPrivilege=table_id,null)
            privilege_type       ptSelect..ptExecute
            grant_option_search  True=we want to look for grant-option=Yes
                                 False=we don't care:just look for the privilege
                                   (False (may) mean faster search, since we can abort early (or maybe even avoid a sort))
                                   Typically, GRANT will use True & everything else will use False here.

 OUT:       authId_level_match   True=matched authId-level privilege/right, i.e. most specific
                                 False=matched higher role privilege
                                 (Note: if grantee is a role, then True only if a higher role matched,
                                        else classed as authId_level_match)
            table_level_match    True=matched row with column_id=null
                                 False=matched exact column_id, i.e. most specific
            grant_option         Yes=privileged, with grant option
                                 No=privileged, with no grant option (unless grant_option_search was False in which case may have grant option)
                                    (I suppose technically we should return <null> or '?' if we find privilege but didn't look for strongest)
                                 ''=not privileged
                                 (Note: no guarantees on result - we take what we find in the column: GIGO)
 RETURNS:   ok, else fail

 Assumes:
         caller will ask for most specific privilege,
         e.g. asking for column-level privilege if that's what's needed rather than whole table-level privilege
         (since we currently wouldn't necessarily have a table-level entry if just a column had privilege)

 Note: we currently do a full scan to find any matching privilege
       we should really hash(grantee,table_id,column_id,privilegeType) to give fast access to Y/N/with_grant result

       we currently match any column if we find an entry with column_id=null
       although we still continue searching (usually in vain) for an exact column match if columnId<>0
       because we might find a more restrictive (grant-option=N) column-specific entry, e.g.
               checking table,3:
                 table,null,Y       //keep searching...
                 table,3,N          //return grant option N
       (todo: so would be much faster if we had a flag on the table,null row to say 'augmented, keep looking' - index is better...)
       So, it's no longer possible for a caller to use columnId=0 to speed up searching?
       - especially when we may soon have extra 'revoke' column rows...
       but still needed for when we're granting table-level privileges...
       & when we're indexed by table_id the extra searching won't happen unnecessarily

       todo: this routine must be fast! -speed

             I suppose, being optimistic, this routine should hardly ever miss since most
             users don't try to access things they aren't allowed to. In such cases the full scan is cut
             short when a match is found = speed.

             maybe useful to return the grantor: the first one at least

             select * repeatedly calls for the same table: we should cache table level
             queries and return much faster for 2..n columns.

       todo: maybe this routine could cache results? (rather than caller)
}
const routine=':CheckTableColumnPrivilege';
var
  sysTableColumnPrivilegeR:TObject; //Trelation
  granteeAuthID,grantorAuthID,columnId:integer;
  privilegeType:integer; //read as integer from table
  grantOption:string;
  columnId_null,dummy_null:boolean;
  role_match:boolean;
begin
  result:=Fail;
  grant_option:=''; //default to not privileged

  //todo: if either of these 2 quick rights is matched, we should return consistent table_level_match/authId_level_match return values

  {If table schema owner = grantee, then we have unrevokable rights and ability to grant privileges
   (providing grantor match is ok or not specified)
   Obviously this is the fastest (& luckily most common?) privilege check because we don't need to touch the catalog
   Note: these rights are not (currently) explicitly stored in sysTableColumnPrivilege, so this is
         the only test to find out if we have these rights
  }
  if (ownerAuth_Id=granteeAuth_Id) and (ownerAuth_id<>0){check caller isn't being lazy}
  and ((grantorAuth_id=0) or (ownerAuth_Id<>grantorAuth_Id)) then
  begin
    grant_option:=Yes;
    result:=ok;
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Found right %s(%d) on %d.%d to %d (grant_option_search=%d) (do_authId_level_match=%d)',[PrivilegeString[privilege_Type],ord(privilege_Type),table_Id,column_Id,granteeAuth_Id,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;

  {If table_id = SyntaxTableId, then we default to all rights (but no ability/need to grant privileges)
   (so the caller always has access (only ever need to Select) to syntax relations)
   Again, we don't need to touch the catalog
  }
  if ((table_id=SyntaxTableId) and (privilege_Type=ptSelect))
     or (table_id=InvalidTableId)
     then
  begin
    grant_option:=No; //i.e. privileged (but no need to give grant option)
    result:=ok;
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Found syntax right %s(%d) on %d.%d to %d (grant_option_search=%d) (do_authId_level_match=%d)',[PrivilegeString[privilege_Type],ord(privilege_Type),table_Id,column_Id,granteeAuth_Id,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;
  //todo trap if SyntaxTableId and not ptSelect -> syntax error not caught elsewhere... e.g. insert into (values (1,2,3)) as X values (4,5,6)

  {We directly access the privilege system table rather than doing an internal Select:
    1) this should be faster than parsing & building/iterating/deleting a plan for an internal Select (+ we don't need a sort!)
    2) an internal Select would cause other privilege checks = eternal recursion!
    3) an internal Select would use the sysStmt and the caller may already be using it

    but it's not as flexible for changes...

   todo: Check we are always privileged to access the privilege rows (I can't think why we wouldn't be!)
   and also this would be a good candidate for a transaction-level copy of the system catalog relation
   to improve concurrent scanning of the same table. speed/concurrency
   For the time being we will use a single server copy - we only check when preparing...?
   But we do need to do whole scans of this (very?) large table! todo monitor blockage - also monitor time-taken
  }
  {Now lookup applicable privileges in sysTableColumnPrivilege and get the grant-option}
  //Note: any privileges granted/revoked on sysTableColumnPrivilege will be ignored... so don't allow them?

  table_level_match:=False;
  authId_level_match:=False;
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysTableColumnPrivilege,sysTableColumnPrivilegeR)=ok then
  begin
    try
      //note: assumes we have best index/hash on scp_table_id, but may not be the case, could be scp_grantee or scp_privilege
      if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)=ok then
        try
          repeat
            {Found another matching table id}
            with (sysTableColumnPrivilegeR as TRelation) do
            begin
              fTuple.GetInteger(ord(scp_column_id),columnId,columnId_null);
              if (columnId_null) or (columnId=column_Id) then //Note: if columnId=null then we match any column
              begin
                fTuple.GetInteger(ord(scp_grantee),granteeAuthId,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                role_match:=(granteeAuthId=PUBLIC_AUTHID) and (granteeAuth_Id<>granteeAuthId); {todo for SQL3: OR a role of which grantee is a member}
                if (granteeAuthId=granteeAuth_Id) or role_match  then
                begin
                  fTuple.GetInteger(ord(scp_privilege),privilegeType,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                  if dummy_null then privilegeType:=-1; //not expected to ever happen (but avoid defaulting if it does)
                  //todo assert privilegeType in ptSelect..ptExecute
                  if privilegeType=ord(privilege_type) then  //Note: we assume order will stay same (or grow at ends)
                  begin
                    fTuple.GetString(ord(scp_grant_option),grantOption,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                    if dummy_null then grantOption:=''; //not expected to ever happen (but avoid <null> if it does)
                    {If caller has requested a match on grantor then we must check it and
                     keep searching if not matched, even if we would otherwise be able to stop searching (e.g. grantOption=Yes=strongest possible)
                     Note: we haven't set the result yet (unless on a previous loop), so if we never match the grantor we don't return 'privilege found'}
                    if grantorAuth_id<>0 then
                    begin
                      fTuple.GetInteger(ord(scp_grantor),grantorAuthId,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      if grantorAuthId<>grantorAuth_Id then
                      begin
                        {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                        if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)<>ok) then
                          break; //end loop
                        continue; //skip any early breaks
                        //note: this means we don't return this Y/N although a privilege was found
                      end;
                    end;

                    //todo: around here we need to cope with (i.e. continue searching?) granteeAuthId=granteeAuth_Id
                    //      being 'stronger' than granteeAuthId=PUBLIC_AUTHID. But is only of concern
                    //      if grant_option_search or column_id<>0? e.g. role.grant_option=Y but authId.grant_option=N
                    //      For now, we use the last one we find! //todo fix

                    if role_match and do_authId_level_match and authId_level_match then
                    begin
                      {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                      if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)<>ok) then
                        break; //end loop
                      continue;  //we've already found a authId specific match and we're no longer interested
                                 //in more general role-level matches for this privilege type
                                 //So we skip, but continue searching in case there are any more specific authId matches
                                 //e.g. column-level, grantOption=Y etc.
                    end;

                    {If caller has requested a 'most-specific' match on column then we must check it and
                     keep searching if not exactly matched (i.e. if null), even if we would otherwise be able to stop searching (e.g. grantOption=Yes and grantor matched if requested)
                     Note: we may or may not use this result, depending on whether it overrides any current one
                           if we do, it will override any current result,
                           e.g. table,null=Y, then table,3,N returns N
                                table,null=N, then table,3,Y returns Y
                    }
                    if (column_id<>0) and (columnId_null) then //table-level match; are/were there any more specific?
                    begin
                      {Note: the logic of the next line is a bit complicated:
                        we save this matching result if we haven't already found the/a column specific one
                        (since they could be in any order & we may have specified grant_option_search)
                      }
                      if grant_option='' then
                      begin
                        {$IFDEF DEBUGDETAIL2}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Found privilege %d on %d.%d(%d) to %d grant-option=%s (grant_option_search=%d) (do_authId_level_match=%d)',[privilegeType,table_Id,columnId,column_id,granteeAuthId,grantOption,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
                        {$ENDIF}
                        {$ENDIF}
                        grant_option:=grantOption; //todo log 'found privilege...'
                        table_level_match:=True;
                        if not(role_match) then authId_level_match:=True;
                      end;
                      {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                      if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)<>ok) then
                        break; //end loop
                      continue; //skip any early breaks
                    end;

                    {$IFDEF DEBUGDETAIL2}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Found privilege %d on %d.%d(%d) to %d grant-option=%s (grant_option_search=%d) (do_authId_level_match=%d)',[privilegeType,table_Id,columnId,column_id,granteeAuthId,grantOption,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    grant_option:=grantOption; //save matching result (though it may not be the final one)
                    if columnId_null then table_level_match:=True;
                    if not(role_match) then authId_level_match:=True;

                    {If this is the strongest match, then we can quit the repeat loop now
                     otherwise we might find a stronger one if we keep looking (i.e. grant-option=Y is stronger than grant-option=N)
                     Note: if we could guarantee that grant-option=Y always came first, then we could always break now - speed
                           or, if the caller specified that they don't care about grant-option, then we can always break now
                    }
                    if do_authId_level_match and not(authId_level_match) then
                    begin
                      {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                      if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)<>ok) then
                        break; //end loop
                      continue; //continue searching - we may find a non-role specific match
                    end;

                    if (grantOption=Yes) then break;
                    if not grant_option_search then break; {caller doesn't care about finding grant-option, so quit early}
                    //else we have a match, but we continue looking for a stronger one
                  end;
                  //else not for our privilege - skip & continue looking
                end;
                //else not for our grantee - skip & continue looking
              end;
              //else not for our column - skip & continue looking
            end; {with}
          until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysTableColumnPrivilegeR,ord(scp_table_id),table_Id)<>ok); //note: this is duplicate in the loop before Continues
                //todo stop when there are no more matching this id (we break early if we get a strong match)
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysTableColumnPrivilegeR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTableColumnPrivilege)]),vError);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else no privilege for this table found
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysTableColumnPrivilege,sysTableColumnPrivilegeR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTableColumnPrivilege)]),vError);
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
    result:=ok; //scan completed ok
  end
  else
  begin  //couldn't get access to sysTableColumnPrivilege
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysTableColumnPrivilege)]),vDebugError);
    {$ENDIF}
  end;
end; {CheckTableColumnPrivilege}

function SetTableColumnPrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                                 table_id:integer;column_id:integer;
                                 privilege_type:TprivilegeType;const grant_option:string):integer;
{Adds the specified privilege
 Checks whether the exact privilege already exists, if it does, leave it else add or update it if grant_option changes
 IN:        tr
            grantorAuth_id       the auth_id of the grantor (we assume caller has checked we're allowed to add this privilege)
            granteeAuth_id       the auth_id of the grantee
            table_id
            column_id            0=just add table privilege (currently => sysTableColumnPrivilege=table_id,null)
            privilege_type       ptSelect..ptExecute
            grant_option         Yes=privilege with grant option
                                 No=privilege with no grant option
                                 (Note: no checks on value - we put what we're given into the column: GIGO)
 RETURNS:   ok, else fail
            Note: even if privilege already exists, we return Ok

 Assumes:
            caller has checked that grantor is privileged to add/update this privilege to the grantee
            and the object and privilege being given to it are valid
            //todo maybe we should do the checking here...depends on who calls us - review...

            grant_option is never passed as '', else our logic might match 'no privilege found' result
            and so ignore the addition (although that would be ok because we don't want to add a privilege of ''!)

 Note: we currently call CheckTableColumnPrivilege (which does a full scan) to find any existing matching privilege

       note: currently we use SQL to insert/update
             - would be better (faster) if we directly appended to the system tables -speed (but more error prone?)
             - plus maybe we are a user that doesn't have privileges to modify privilege tables! using SQL should respect this..
}
const routine=':SetTableColumnPrivilege';
var
  columnIdorNull:string;
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=Fail;

  {Check the privilege doesn't already exist}
  if CheckTableColumnPrivilege(st,grantorAuth_id{we specifically want to match grantor},granteeAuth_Id,
                               True{we care whether a role or auth level grantee},authId_level_match,
                               0{authId 0 because we never want a 'rights match' here, else would try to update
                                 something that wasn't really there. As it stands we will allow the addition of
                                 extra/superfluous privileges but so what: think-through & test to break},
                               table_Id,column_id{if 0=null=all table},table_level_match{we care how exact we match},
                               privilege_type,True{we want grant-option search},grantabilityOption)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed checking existence of privilege %s on %d.%d from %d to %d',[PrivilegeString[privilege_type],table_id,column_id,grantorAuth_id,granteeAuth_Id]),vDebugError);
    {$ENDIF}
    //todo return resultErrCode etc.
    exit; //abort, no point continuing
  end;

  if grantabilityOption=grant_option then
  begin
    //Note: includes case when we're trying to set a column privilege & an exact matching table-level one already exists
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Exact privilege already exists, ignoring grant %s on %d.%d from %d to %d',[PrivilegeString[privilege_type],table_id,column_id,grantorAuth_id,granteeAuth_Id]),vDebugLow);
    {$ENDIF}
    result:=ok; //caller need never know
    exit;
  end
  else
  begin
    if grantabilityOption='' then
    begin
      {No existing privilege (at any level), add it}
      //todo better to use IFNULL?
      if column_id=0 then
        columnIdorNull:='null'{todo 0 is safer?}
      else
        columnIdorNull:=intToStr(column_id);
      //note: since we're using SQL, we should always have privileges to add privileges!
      {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
        result:=ExecSQL(tempStmt,
          format('INSERT INTO %s.sysTableColumnPrivilege (table_id,column_id,grantor,grantee,privilege,grant_option) '+
                 'VALUES (%d,%s,%d,%d,%d,''%s''); ',
                 [sysCatalogDefinitionSchemaName, table_Id,columnIdorNull,grantorAuth_Id,granteeAuth_Id,ord(privilege_type),grant_option])
                ,nil,resultRowCount);
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed inserting sysTableColumnPrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Inserted %d entries into sysTableColumnPrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end
    else
    begin
      {Privilege exists but is slightly different, update it
       Actually, the only possible differences could be:
          the grant_option, from Y to N or from N to Y,
       or the match was with a role-level privilege
       so for now that's all we'll update todo: review: maybe cleaner/more maintainable to delete & re-insert it?
      }
      {Note: the update statement assumes/implies and ensure that we only have 1 grant_option value per privilege
        i.e. Y and N cannot both exist for the same privilege

       So this is a problem if we have table,null,Y and user sets table,3,N
       the update would fail because the privilege (at this column level) didn't really exist even though we got a match.
       We've determined whether we matched at a different level (table_level_match) and so we can
       INSERT instead in such cases.
       We've also determined whether we matched at a role level (authId_level_match) and so we can
       INSERT instead in such cases.
      }

      {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
        if ((column_id<>0) and table_level_match) or not(authId_level_match) then
        begin //we need to add an augment row for this specific column, since it now differs from the table-level (must only differ by grant-option!)
              //or since it differs from a role-level match
          //todo better to use IFNULL?
          if column_id=0 then
            columnIdorNull:='null'{todo 0 is safer?} //todo 0 is better here because it tells us that we got here because only a role-level-match was found
          else
            columnIdorNull:=intToStr(column_id);
          //note: since we're using SQL, we should always have privileges to add privileges!
          result:=ExecSQL(tempStmt,
            format('INSERT INTO %s.sysTableColumnPrivilege (table_id,column_id,grantor,grantee,privilege,grant_option) '+
                   'VALUES (%d,%s,%d,%d,%d,''%s''); ',
                   [sysCatalogDefinitionSchemaName, table_Id,columnIdorNull{only null here if role-level match},grantorAuth_Id,granteeAuth_Id,ord(privilege_type),grant_option])
                  ,nil,resultRowCount);
        end
        else
        begin //we're dealing with the table, or we found an existing column-level row match: so update existing (auth-id level) row
          //todo better to use IFNULL?
          if column_id=0 then
            columnIdorNull:=' is null'{todo 0 is safer?}
          else
            columnIdorNull:='='+intToStr(column_id);

          //note: since we're using SQL, we should always have privileges to update privileges!
          result:=ExecSQL(tempStmt,
            format('UPDATE %s.sysTableColumnPrivilege '+
                   'SET grant_option=''%s'' '+
                   'WHERE table_id=%d AND column_id%s AND grantor=%d AND grantee=%d AND privilege=%d ; ',
                   [sysCatalogDefinitionSchemaName, grant_option, table_Id,columnIdorNull,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)])
                  ,nil,resultRowCount);
        end;
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed updating/inserting sysTableColumnPrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Updated/inserted %d entries into sysTableColumnPrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end;
  end;
end; {SetTableColumnPrivilege}

function UnsetTableColumnPrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                                 table_id:integer;column_id:integer;
                                 privilege_type:TprivilegeType;const grant_option:string):integer;
{Removes the specified privilege
 Assumes the exact privilege already exists and removes it, or updates it if grant_option changes
 IN:        tr
            grantorAuth_id       the auth_id of the grantor (we assume caller has checked we're allowed to remove this privilege)
            granteeAuth_id       the auth_id of the grantee
            table_id
            column_id            0=just add table privilege (currently => sysTableColumnPrivilege=table_id,null)
            privilege_type       ptSelect..ptExecute
            grant_option         Yes=remove grant option
                                 No=remove privilege
                                 (Note: no checks on value - we put what we're given into the column: GIGO)
 RETURNS:   ok, else fail

 Assumes:
            caller has checked that grantor is privileged to remove/update this privilege from the grantee
            and the object and privilege being given to it are valid
            //todo maybe we should do the checking here...depends on who calls us - review...

            grant_option is never passed as '', else our logic might match 'no privilege found' result
            and so ignore the addition (although that would be ok because we don't want to add a privilege of ''!)

 Note: we currently call CheckTableColumnPrivilege (which does a full scan) to find the existing matching privilege

       note: currently we use SQL to delete/update
             - would be better (faster) if we directly deleted from the system tables -speed (but more error prone?)
             - plus maybe we are a user that doesn't have privileges to modify privilege tables! using SQL should respect this..
}
const routine=':UnsetTableColumnPrivilege';
var
  columnIdorNull:string;
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=Fail;

  {Find the existing privilege details}
  if CheckTableColumnPrivilege(st,grantorAuth_id{we specifically want to match grantor},granteeAuth_Id,
                               True{we care whether a role or auth level grantee},authId_level_match,
                               0{authId 0 because we never want a 'rights match' here, else would try to remove
                                 something that wasn't really there. todo - think-through & test to break},
                               table_Id,column_id{if 0=null=all table},table_level_match{we care how exact we match},
                               privilege_type,(grant_option=Yes){grant-option search?},grantabilityOption)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed checking existence of privilege %s on %d.%d from %d to %d',[PrivilegeString[privilege_type],table_id,column_id,grantorAuth_id,granteeAuth_Id]),vDebugError);
    {$ENDIF}
    //todo return resultErrCode etc.
    exit; //abort, no point continuing
  end;

  if (grant_option=Yes) and (grantabilityOption=grant_option){can assume this: just check grantabilityOption<>''?} then
  begin
    //Note: includes case when we're trying to set a column privilege & an exact matching table-level one already exists
    {Privilege exists but we want to revoke the grant option, update it
     Actually, the only possible differences could be:
        the grant_option, from Y to N,
     or the match was with a role-level privilege
     so for now that's all we'll update todo: review: maybe cleaner/more maintainable to delete & re-insert it?
    }
    {Note: the update statement assumes/implies and ensure that we only have 1 grant_option value per privilege
      i.e. Y and N cannot both exist for the same privilege
    }

    {We need to update as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
      (*todo:
        possibly here (if table_level_match & column_id<>0) we need to replace a table-level privilege with a number of column specific
        ones except the one for the column we're revoking? Check spec.

      if ((column_id<>0) and table_level_match) or not(authId_level_match) then
      begin //we need to add an augment row for this specific column, since it now differs from the table-level (must only differ by grant-option!)
            //or since it differs from a role-level match
        //todo better to use IFNULL?
        if column_id=0 then
          columnIdorNull:='null'{todo 0 is safer?} //todo 0 is better here because it tells us that we got here because only a role-level-match was found
        else
          columnIdorNull:=intToStr(column_id);
        //note: since we're using SQL, we should always have privileges to add privileges!!!!!
        result:=ExecSQL(tempStmt,
          format('INSERT INTO %s.sysTableColumnPrivilege (table_id,column_id,grantor,grantee,privilege,grant_option) '+
                 'VALUES (%d,%s,%d,%d,%d,''%s''); ',
                 [sysCatalogDefinitionSchemaName, table_Id,columnIdorNull{only null here if role-level match},grantorAuth_Id,granteeAuth_Id,ord(privilege_type),grant_option])
                ,nil,resultRowCount);
      end
      else
      *)
      begin //we're dealing with the table, or we found an existing column-level row match: so update existing (auth-id level) row
        //todo better to use IFNULL?
        if column_id=0 then
          columnIdorNull:=' is null'{todo 0 is safer?}
        else
          columnIdorNull:='='+intToStr(column_id);

        //note: since we're using SQL, we should always have privileges to update privileges!
        result:=ExecSQL(tempStmt,
          format('UPDATE %s.sysTableColumnPrivilege '+
                 'SET grant_option=''%s'' '+
                 'WHERE table_id=%d AND column_id%s AND grantor=%d AND grantee=%d AND privilege=%d ; ',
                 [sysCatalogDefinitionSchemaName, No{i.e. inverted grant_option}, table_Id,columnIdorNull,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)])
                ,nil,resultRowCount);
      end;
      if result<>ok then //todo return warning?
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed updating/inserting sysTableColumnPrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Updated/inserted %d entries into sysTableColumnPrivilege',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?
    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}
  end
  else
  begin
    if grantabilityOption='' then
    begin
      {No existing privilege (at any level), error}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed to find existing privilege %s on %d.%d from %d to %d',[PrivilegeString[privilege_type],table_id,column_id,grantorAuth_id,granteeAuth_Id]),vAssertion);
      {$ENDIF}
      exit; //abort
    end
    else
    begin
      {todo
        possibly here (if table_level_match & column_id<>0) we need to replace a table-level privilege with a number of column specific
        ones except the one for the column we're revoking? Check spec.
      }

      //todo if column_id=0 then remove the column_id condition altogether to ensure
      //     we remove all privileges for this column (table and column level) (for this grantor/grantee)

      //exact match found, remove it
      //todo better to use IFNULL?
      if column_id=0 then
        columnIdorNull:=''{i.e. don't just delete for this table-level: zap all column specifics for this table as well}
      else
        columnIdorNull:='AND column_id='+intToStr(column_id); //but if table_level_match... see note above
      //note: since we're using SQL, we should always have privileges to add privileges!
      {We need to delete as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
        result:=ExecSQL(tempStmt,
          format('DELETE FROM %s.sysTableColumnPrivilege WHERE table_id=%d '+columnIdorNull+' AND grantor=%d AND grantee=%d AND privilege=%d; ', //n/a: AND grant_option=''%s''; ',
                 [sysCatalogDefinitionSchemaName, table_Id,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)]) //n/a: ,grant_option])
                ,nil,resultRowCount);
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed deleting sysTableColumnPrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Deleted %d entries from sysTableColumnPrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end;
  end;
end; {UnsetTableColumnPrivilege}

function CheckRoutinePrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                               do_authId_level_match:boolean;var authId_level_match:boolean;
                               ownerAuth_id:integer;routine_id:integer;
                               privilege_type:TprivilegeType;grant_option_search:boolean;var grant_option:string):integer;
{Check the privilege of a routine
 IN:        tr
            grantorAuth_id       the auth_id of the grantor for restricted match
                                 if 0, caller doesn't care about who granted a matching privilege
                                 if<>0,caller is only looking for a privilege granted by this auth_id
                                   (e.g. =0 for typical use, <>0 to check if a particular privilege already exists)
            granteeAuth_id       the auth_id of the grantee to check the privilege of
                                 (in future (for SQL3), this routine will also check for roles
                                  that this auth_id is a member of. Currently it will just check for
                                  the PUBLIC role. Any auth_id specific privilege will override any PUBLIC
                                  privilege)
            do_authId_level_match True=we keep searching even after we've found a role-level match
            ownerAuth_id         the auth id of the routine owner (used for quick 'rights' check)
            routine_id
            privilege_type       ptSelect..ptExecute (only ptExecute currently applies)
            grant_option_search  True=we want to look for grant-option=Yes
                                 False=we don't care:just look for the privilege
                                   (False (may) mean faster search, since we can abort early (or maybe even avoid a sort))
                                   Typically, GRANT will use True & everything else will use False here.

 OUT:       authId_level_match   True=matched authId-level privilege/right, i.e. most specific
                                 False=matched higher role privilege
                                 (Note: if grantee is a role, then True only if a higher role matched,
                                        else classed as authId_level_match)
            grant_option         Yes=privileged, with grant option
                                 No=privileged, with no grant option (unless grant_option_search was False in which case may have grant option)
                                    (I suppose technically we should return <null> or '?' if we find privilege but didn't look for strongest)
                                 ''=not privileged
                                 (Note: no guarantees on result - we take what we find in the column: GIGO)
 RETURNS:   ok, else fail

 Assumes:

 Note: we currently do a full scan to find any matching privilege
       we should really hash(grantee,routine_id,privilegeType) to give fast access to Y/N/with_grant result

       note: this routine must be fast! -speed

             I suppose, being optimistic, this routine should hardly ever miss since most
             users don't try to access things they aren't allowed to. In such cases the full scan is cut
             short when a match is found = speed.

             maybe useful to return the grantor: the first one at least

       todo: maybe this routine could cache results? (rather than caller)
}
const routine=':CheckRoutinePrivilege';
var
  sysRoutinePrivilegeR:TObject; //Trelation
  granteeAuthID,grantorAuthID,columnId:integer;
  privilegeType:integer; //read as integer from table
  grantOption:string;
  dummy_null:boolean;
  role_match:boolean;
begin
  result:=Fail;
  grant_option:=''; //default to not privileged

  //todo: if this quick right is matched, we should return consistent authId_level_match return value

  {If routine schema owner = grantee, then we have unrevokable rights and ability to grant privileges
   (providing grantor match is ok or not specified)
   Obviously this is the fastest (& luckily most common?) privilege check because we don't need to touch the catalog
   Note: these rights are not (currently) explicitly stored in sysRoutinePrivilege, so this is
         the only test to find out if we have these rights
  }
  if (ownerAuth_Id=granteeAuth_Id) and (ownerAuth_id<>0){check caller isn't being lazy} 
  and ((grantorAuth_id=0) or (ownerAuth_Id<>grantorAuth_Id)) then
  begin
    grant_option:=Yes;
    result:=ok;
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Found right %s(%d) on %d to %d (grant_option_search=%d) (do_authId_level_match=%d)',[PrivilegeString[privilege_Type],ord(privilege_Type),routine_Id,granteeAuth_Id,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;

  {We directly access the privilege system table rather than doing an internal Select:
    1) this should be faster than parsing & building/iterating/deleting a plan for an internal Select (+ we don't need a sort!)
    2) an internal Select would cause other privilege checks = eternal recursion!

    but it's not as flexible for changes...

   todo: Check we are always privileged to access the privilege rows (I can't think why we wouldn't be!)
   and also this would be a good candidate for a transaction-level copy of the system catalog relation
   to improve concurrent scanning of the same table. speed/concurrency
   For the time being we will use a single server copy - we only check when preparing...?
   But we do need to do whole scans of this (very?) large table! todo monitor blockage - also monitor time-taken
  }
  {Now lookup applicable privileges in sysRoutinePrivilege and get the grant-option}
  //Note: any privileges granted/revoked on sysRoutinePrivilege will be ignored... so don't allow them?

  authId_level_match:=False;
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysRoutinePrivilege,sysRoutinePrivilegeR)=ok then
  begin
    try
      //note: assumes we have best index/hash on srp_routine_id, but may not be the case, could be srp_grantee or srp_privilege
      if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysRoutinePrivilegeR,ord(srp_routine_id),routine_Id)=ok then
        try
          repeat
            {Found another matching routine id}
            with (sysRoutinePrivilegeR as TRelation) do
            begin
              begin
                fTuple.GetInteger(ord(srp_grantee),granteeAuthId,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                role_match:=(granteeAuthId=PUBLIC_AUTHID) and (granteeAuth_Id<>granteeAuthId); {todo for SQL3: OR a role of which grantee is a member}
                if (granteeAuthId=granteeAuth_Id) or role_match  then
                begin
                  fTuple.GetInteger(ord(srp_privilege),privilegeType,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                  if dummy_null then privilegeType:=-1; //not expected to ever happen (but avoid defaulting if it does)
                  //todo assert privilegeType in ptSelect..ptExecute
                  if privilegeType=ord(privilege_type) then  //Note: we assume order will stay same (or grow at ends)
                  begin
                    fTuple.GetString(ord(srp_grant_option),grantOption,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                    if dummy_null then grantOption:=''; //not expected to ever happen (but avoid <null> if it does)
                    {If caller has requested a match on grantor then we must check it and
                     keep searching if not matched, even if we would otherwise be able to stop searching (e.g. grantOption=Yes=strongest possible)
                     Note: we haven't set the result yet (unless on a previous loop), so if we never match the grantor we don't return 'privilege found'}
                    if grantorAuth_id<>0 then
                    begin
                      fTuple.GetInteger(ord(srp_grantor),grantorAuthId,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      if grantorAuthId<>grantorAuth_Id then
                      begin
                        {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                        if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysRoutinePrivilegeR,ord(srp_routine_id),routine_Id)<>ok) then
                          break; //end loop
                        continue; //skip any early breaks
                        //note: this means we don't return this Y/N although a privilege was found
                      end;
                    end;

                    //todo: around here we need to cope with (i.e. continue searching?) granteeAuthId=granteeAuth_Id
                    //      being 'stronger' than granteeAuthId=PUBLIC_AUTHID. But is only of concern
                    //      if grant_option_search or column_id<>0? e.g. role.grant_option=Y but authId.grant_option=N
                    //      For now, we use the last one we find! //todo fix!

                    if role_match and do_authId_level_match and authId_level_match then
                    begin
                      {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                      if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysRoutinePrivilegeR,ord(srp_routine_id),routine_Id)<>ok) then
                        break; //end loop
                      continue;  //we've already found a authId specific match and we're no longer interested
                                 //in more general role-level matches for this privilege type
                                 //So we skip, but continue searching in case there are any more specific authId matches
                                 //e.g. grantOption=Y etc.
                    end;

                    {$IFDEF DEBUGDETAIL2}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Found privilege %d on %d to %d grant-option=%s (grant_option_search=%d) (do_authId_level_match=%d)',[privilegeType,routine_Id,granteeAuthId,grantOption,ord(grant_option_search),ord(do_authId_level_match)]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    grant_option:=grantOption; //save matching result (though it may not be the final one)
                    if not(role_match) then authId_level_match:=True;

                    {If this is the strongest match, then we can quit the repeat loop now
                     otherwise we might find a stronger one if we keep looking (i.e. grant-option=Y is stronger than grant-option=N)
                     Note: if we could guarantee that grant-option=Y always came first, then we could always break now - speed
                           or, if the caller specified that they don't care about grant-option, then we can always break now
                    }
                    if do_authId_level_match and not(authId_level_match) then
                    begin
                      {Note: we call the findNext here since the continue will goto the repeat = infinite loop}
                      if (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysRoutinePrivilegeR,ord(srp_routine_id),routine_Id)<>ok) then
                        break; //end loop
                      continue; //continue searching - we may find a non-role specific match
                    end;

                    if (grantOption=Yes) then break;
                    if not grant_option_search then break; {caller doesn't care about finding grant-option, so quit early}
                    //else we have a match, but we continue looking for a stronger one
                  end;
                  //else not for our privilege - skip & continue looking
                end;
                //else not for our grantee - skip & continue looking
              end;
            end; {with}
          until (Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysRoutinePrivilegeR,ord(srp_routine_id),routine_Id)<>ok); //note: this is duplicate in the loop before Continues
                //todo stop when there are no more matching this id (we break early if we get a strong match)
        finally
          if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysRoutinePrivilegeR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysRoutinePrivilege)]),vError);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else no privilege for this routine found
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysRoutinePrivilege,sysRoutinePrivilegeR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysRoutinePrivilege)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
    result:=ok; //scan completed ok
  end
  else
  begin  //couldn't get access to sysRoutinePrivilege
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysRoutinePrivilege)]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
  end;
end; {CheckRoutinePrivilege}

function SetRoutinePrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                             routine_id:integer;
                             privilege_type:TprivilegeType;const grant_option:string):integer;
{Adds the specified privilege
 Checks whether the exact privilege already exists, if it does, leave it else add or update it if grant_option changes
 IN:        tr
            grantorAuth_id       the auth_id of the grantor (we assume caller has checked we're allowed to add this privilege)
            granteeAuth_id       the auth_id of the grantee
            routine_id
            privilege_type       ptSelect..ptExecute (only ptExecute currently applies)
            grant_option         Yes=privilege with grant option
                                 No=privilege with no grant option
                                 (Note: no checks on value - we put what we're given into the column: GIGO)
 RETURNS:   ok, else fail
            Note: even if privilege already exists, we return Ok

 Assumes:
            caller has checked that grantor is privileged to add/update this privilege to the grantee
            and the object and privilege being given to it are valid
            //todo maybe we should do the checking here...depends on who calls us - todo review...

            grant_option is never passed as '', else our logic might match 'no privilege found' result
            and so ignore the addition (although that would be ok because we don't want to add a privilege of ''!)

 Note: we currently call CheckRoutinePrivilege (which does a full scan) to find any existing matching privilege

       note: currently we use SQL to insert/update
             - would be better (faster) if we directly appended to the system tables -speed (but more error prone?)
             - plus maybe we are a user that doesn't have privileges to modify privilege tables! using SQL should respect this..
}
const routine=':SetRoutinePrivilege';
var
  grantabilityOption:string;
  authId_level_match:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=Fail;

  {Check the privilege doesn't already exist}
  if CheckRoutinePrivilege(st,grantorAuth_id{we specifically want to match grantor},granteeAuth_Id,
                           True{we care whether a role or auth level grantee},authId_level_match,
                           0{authId 0 because we never want a 'rights match' here, else would try to update
                             something that wasn't really there. As it stands we will allow the addition of
                             extra/superfluous privileges but so what: todo think-through & test to break},
                           routine_Id,
                           privilege_type,True{we want grant-option search},grantabilityOption)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed checking existence of privilege %s on %d from %d to %d',[PrivilegeString[privilege_type],routine_id,grantorAuth_id,granteeAuth_Id]),vDebugError);
    {$ENDIF}
    //todo return resultErrCode etc.
    exit; //abort, no point continuing
  end;

  if grantabilityOption=grant_option then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Exact privilege already exists, ignoring grant %s on %d from %d to %d',[PrivilegeString[privilege_type],routine_id,grantorAuth_id,granteeAuth_Id]),vDebugLow);
    {$ENDIF}
    result:=ok; //caller need never know
    exit;
  end
  else
  begin
    if grantabilityOption='' then
    begin
      {No existing privilege (at any level), add it}
      //note: since we're using SQL, we should always have privileges to add privileges!
      {We need to insert as _SYSTEM to ensure we have permission on sysRoutinePrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); 
        result:=ExecSQL(tempStmt,
          format('INSERT INTO %s.sysRoutinePrivilege (routine_id,grantor,grantee,privilege,grant_option) '+
                 'VALUES (%d,%d,%d,%d,''%s''); ',
                 [sysCatalogDefinitionSchemaName, routine_Id,grantorAuth_Id,granteeAuth_Id,ord(privilege_type),grant_option])
                ,nil,resultRowCount);
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed inserting sysRoutinePrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Inserted %d entries into sysRoutinePrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end
    else
    begin
      {Privilege exists but is slightly different, update it
       Actually, the only possible differences could be:
          the grant_option, from Y to N or from N to Y,
       or the match was with a role-level privilege
       so for now that's all we'll update todo: review: maybe cleaner/more maintainable to delete & re-insert it?
      }
      {Note: the update statement assumes/implies and ensure that we only have 1 grant_option value per privilege
        i.e. Y and N cannot both exist for the same privilege
      }

      {We need to insert as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); 
        begin //we're dealing with the routine: so update existing (auth-id level) row
          //note: since we're using SQL, we should always have privileges to update privileges!
          result:=ExecSQL(tempStmt,
            format('UPDATE %s.sysRoutinePrivilege '+
                   'SET grant_option=''%s'' '+
                   'WHERE routine_id=%d AND grantor=%d AND grantee=%d AND privilege=%d ; ',
                   [sysCatalogDefinitionSchemaName, grant_option, routine_Id,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)])
                  ,nil,resultRowCount);
        end;
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed updating/inserting sysRoutinePrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Updated/inserted %d entries into sysRoutinePrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end;
  end;
end; {SetRoutinePrivilege}

function UnsetRoutinePrivilege(st:TStmt;grantorAuth_id:integer;granteeAuth_id:integer;
                             routine_id:integer;
                             privilege_type:TprivilegeType;const grant_option:string):integer;
{Removes the specified privilege
 Assumes the exact privilege already exists and removes it, or updates it if grant_option changes
 IN:        tr
            grantorAuth_id       the auth_id of the grantor (we assume caller has checked we're allowed to add this privilege)
            granteeAuth_id       the auth_id of the grantee
            routine_id
            privilege_type       ptSelect..ptExecute (only ptExecute currently applies)
            grant_option         Yes=remove grant option
                                 No=remove privilege
                                 (Note: no checks on value - we put what we're given into the column: GIGO)
 RETURNS:   ok, else fail
            Note: even if privilege already exists, we return Ok

 Assumes:
            caller has checked that grantor is privileged to delete/update this privilege from the grantee
            and the object and privilege being given to it are valid
            //todo maybe we should do the checking here...depends on who calls us - todo review...

            grant_option is never passed as '', else our logic might match 'no privilege found' result
            and so ignore the addition (although that would be ok because we don't want to add a privilege of ''!)

 Note: we currently call CheckRoutinePrivilege (which does a full scan) to find the existing matching privilege

       note: currently we use SQL to insert/update
             - would be better (faster) if we directly appended to the system tables -speed (but more error prone?)
             - plus maybe we are a user that doesn't have privileges to modify privilege tables! using SQL should respect this..
}
const routine=':UnsetRoutinePrivilege';
var
  grantabilityOption:string;
  authId_level_match:boolean;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=Fail;

  {Check the privilege doesn't already exist}
  if CheckRoutinePrivilege(st,grantorAuth_id{we specifically want to match grantor},granteeAuth_Id,
                           True{we care whether a role or auth level grantee},authId_level_match,
                           0{authId 0 because we never want a 'rights match' here, else would try to remove
                             something that wasn't really there. todo think-through & test to break},
                           routine_Id,
                           privilege_type,(grant_option=Yes){grant-option search?},grantabilityOption)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed checking existence of privilege %s on %d from %d to %d',[PrivilegeString[privilege_type],routine_id,grantorAuth_id,granteeAuth_Id]),vDebugError);
    {$ENDIF}
    //todo return resultErrCode etc.
    exit; //abort, no point continuing
  end;

  if (grant_option=Yes) and (grantabilityOption=grant_option){can assume this: just check grantabilityOption<>''?} then
  begin
    {Privilege exists but is slightly different, update it
     Actually, the only possible differences could be:
        the grant_option, from Y to N
     or the match was with a role-level privilege
     so for now that's all we'll update todo: review: maybe cleaner/more maintainable to delete & re-insert it?
    }
    {Note: the update statement assumes/implies and ensure that we only have 1 grant_option value per privilege
      i.e. Y and N cannot both exist for the same privilege
    }

    {We need to update as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
      begin //we're dealing with the routine: so update existing (auth-id level) row
        //note: since we're using SQL, we should always have privileges to update privileges!
        result:=ExecSQL(tempStmt,
          format('UPDATE %s.sysRoutinePrivilege '+
                 'SET grant_option=''%s'' '+
                 'WHERE routine_id=%d AND grantor=%d AND grantee=%d AND privilege=%d ; ',
                 [sysCatalogDefinitionSchemaName, No{i.e. invert grant_option}, routine_Id,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)])
                ,nil,resultRowCount);
      end;
      if result<>ok then //todo return warning?
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed updating/inserting sysRoutinePrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError) 
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Updated/inserted %d entries into sysRoutinePrivilege',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?
    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}
  end
  else
  begin
    if grantabilityOption='' then
    begin
      {No existing privilege (at any level), error}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed to find existing privilege %s on %d from %d to %d',[PrivilegeString[privilege_type],routine_id,grantorAuth_id,granteeAuth_Id]),vDebugError); 
      {$ENDIF}
      exit; //abort
    end
    else
    begin
      //exact match found, remove it
      //note: since we're using SQL, we should always have privileges to add privileges!
      {We need to delete as _SYSTEM to ensure we have permission on sysRoutinePrivilege (plus is quicker since _SYSTEM has ownership rights)}
      saveAuthId:=Ttransaction(st.owner).AuthId;
      saveAuthName:=Ttransaction(st.owner).AuthName;
      Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
      Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      try
        Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); 
        result:=ExecSQL(tempStmt,
          format('DELETE FROM %s.sysRoutinePrivilege WHERE routine_id=%d AND grantor=%d AND grantee=%d AND privilege=%d;', //n/a: AND grant_option=''%s''); ',
                 [sysCatalogDefinitionSchemaName, routine_Id,grantorAuth_Id,granteeAuth_Id,ord(privilege_type)]) //n/a: ,grant_option])
                ,nil,resultRowCount);
        if result<>ok then //todo return warning?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'  Failed deleting sysRoutinePrivilege row via PrepareSQL/ExecutePlan: '{todo getLastError},vError) 
          {$ENDIF}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Deleted %d entries into sysRoutinePrivilege',[resultRowCount]),vdebug);
          {$ELSE}
          ;
          {$ENDIF}
          //todo assert resultRowCount=1?
      finally
        Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
        Ttransaction(st.owner).AuthName:=saveAuthName;
      end; {try}
    end;
  end;
end; {UnsetRoutinePrivilege}

function Grant(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Grant privilege(s) on an object to user(s)
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntGrant node

 RETURNS:  Ok,
           +ve = number of warnings (possible sub-failures) but some part worked
           else Fail
}
const routine=':Grant';
var
  n,nGrantee,nObject,nRootPrivilege,nPrivilege,nColumn:TSyntaxNodePtr;

  objectId:integer;

  r:TRelation;
  rt:TRoutine;
  isView:boolean;
  viewDefinition:string;
  routineType,routineDefinition:string;
  id:string;

  grantOption,grantabilityOption:string;
  granteeAuth:string;
  granteeAuthId, grantorAuthId:integer;

  dummy_null:boolean; //todo extra (ifdef-conditional) safety throughout code: assert dummy_null=False whenever we assume so!

  sysAuthR:TObject; {TRelation;} //todo improve by using Trelation - no circularity here?

  privilegeType,fromPt,toPt:TprivilegeType;
  table_level_match,authId_level_match:boolean;

  cTuple:TTuple;
  cId:TColId;
  cRef:ColRef;
  tempResult:integer;
begin
  result:=ok; //default
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Granting privilege(s)',[nil]),vDebug);
  {$ENDIF}

  grantorAuthId:=Ttransaction(st.owner).authId; //in SQL/3 I think we can override this, i.e. grant on behalf of someone

  toPt:=ptSelect; //to keep compiler warning quiet

  {Note whether we are trying to give the 'with grant' option}
  grantOption:=No;
  if nroot.nextNode<>nil then
    if nroot.nextNode.nType=ntWithGrantOption then
      grantOption:=Yes;

  {Note object detail node}
  nObject:=nroot.leftChild;

  r:=nil;
  rt:=nil;
  try
    {we also save the objectId to save having to re-find it every time in the loop}
    objectId:=0; //todo -1 safer?
    case nObject.ntype of
      ntTable:
      begin
        {Find table_id => objectId}
        //Since we may need to access/check column names as well, better to use Trelation.open?
        // then find logic is handled/centralised as well
        id:=nObject.rightChild.idVal;

        r:=TRelation.create;
          {Try to open this relation so we can get the id and its column ids if needed below}
          tempResult:=r.open(st,nObject.leftChild,'',id,isView,viewDefinition);
          if tempResult=ok then
          begin
            //todo check whether we're dealing with a view or base_table? we don't care...
            //- or do we? If we have grant-option on a view's constituent tables then we can
            //  grant privileges on the view - but how do we know which objectId(s) to lookup?
            // - probably best if we copy all privileges from all tables when we create the view...
            //  if we do, then what happens if we revoke on one of the underlying tables?
            //  - I would think the view would need to reflect it somehow?....check spec...
            objectId:=r.tableId;
          end
          else
          begin
            case tempResult of
              -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
              -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
            else
              st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id])); 
            end; {case}
            result:=-3; //could not find base_table or view
            exit; //abort
          end;
        //Note: we clean up r at end
      end; {ntTable}
      ntDomain:
      begin
        {Find domain_id => objectId}
      end; {ntDomain}
      ntRoutine:
      begin
        {Note: we don't record whether the user specified function/procedure/routine here
              so to use a routineType filter in future (to support func + procs with same name)
              we'd need to adjust the syntax tree & then cross-check/filter here}
        {Find routine_id => objectId}
        id:=nObject.rightChild.idVal;
        rt:=TRoutine.create;
          {Try to open this routine so we can get the id}
          tempResult:=rt.open(st,nObject.leftChild,'',id,routineType,routineDefinition);
          if tempResult=ok then
          begin
            objectId:=rt.routineId;
          end
          else
          begin
            case tempResult of
              -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
              -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
            else
              st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[id]));
            end; {case}
            result:=-3; //could not find routine
            exit; //abort
          end;
        //Note: we clean up rt at end
      end; {ntRoutine}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Grant object not handled %d',[ord(nObject.ntype)]),vDebugError); 
      {$ENDIF}
      //todo return resultErrCode etc.
      result:=fail;
      exit; //abort - no point continuing
    end; {case}

    //todo assert that objectId<>0

    {Note start of privilege list}
    nRootPrivilege:=nroot.leftChild.nextNode; //todo assert exists!?

    {For each grantee}
    nGrantee:=nroot.rightChild;
    while nGrantee<>nil do
    begin
      granteeAuthId:=0; //todo use invalidAuthId?
      if nGrantee.leftChild<>nil then
        granteeAuth:=nGrantee.leftChild.idVal
      else
        granteeAuth:='PUBLIC'; //todo use constant! or even remove from parser & lookup like any other since it always exists!
      {Lookup granteeAuthId}
      //todo move this routine into a separate routine: e.g. findAuthId(authName, id,type,password,default...);
      //  used in transaction.connect, here, createSchema etc?
      if Ttransaction(st.owner).db.catalogRelationStart(st,sysAuth,sysAuthR)=ok then
      begin
        try
          if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysAuthR,ord(sa_auth_name),granteeAuth)=ok then
          begin
            with (sysAuthR as TRelation) do
            begin
              fTuple.GetInteger(ord(sa_auth_id),granteeAuthId,dummy_null);
              //todo check authType=atUser? fail if atRole?
              {$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found auth %s in %s',[granteeAuth,sysAuth_table]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
            end; {with}
          end
          else //granteeAuthId not found
          begin
            //todo in future this might be a good place to auto-create this auth/user

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown granteeAuthId %s',[granteeAuth]),vDebugLow);
            {$ENDIF}
            //todo ? result:=badUsername;
            //todo return resultErrCode etc.
            inc(result); //add to warning count
            {Skip to next}
            nGrantee:=nGrantee.nextNode;
            continue; //todo remove continue with next grantee...exit;
          end;
        finally
          if Ttransaction(st.owner).db.catalogRelationStop(st,sysAuth,sysAuthR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysAuth
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError); 
        {$ENDIF}
        //todo return resultErrCode etc.
        inc(result); //add to warning count
        {Skip to next}
        nGrantee:=nGrantee.nextNode;
        continue; //todo remove continue with next grantee...exit;
      end;

      //todo: reject if grantor=grantee, else loophole: could grant duplicate privileges to self!
      // - is here best place - or in Set routine(s)? 

      {For each privilege listed}
      nPrivilege:=nRootPrivilege;
      while nPrivilege<>nil do
      begin
        if nPrivilege.nType=ntAllPrivileges then
        begin
          {We loop for all possible privileges and attempt to grant them all,
           but we fail silently if we aren't allowed to grant any of them
           (or if they don't apply to this object).
           The overall aim is to grant for every privilege we have}
          fromPt:=ptSelect;
          toPt:=ptExecute;
          //todo debug log message here?
        end
        else
        begin
          {Map privilege syntax node to type}
          case nPrivilege.nType of
            ntPrivilegeSelect:      fromPt:=ptSelect;
            ntPrivilegeInsert:      fromPt:=ptInsert;
            ntPrivilegeUpdate:      fromPt:=ptUpdate;
            ntPrivilegeDelete:      fromPt:=ptDelete;
            ntPrivilegeReferences:  fromPt:=ptReferences;
            ntPrivilegeUsage:       fromPt:=ptUsage;
            ntPrivilegeExecute:     fromPt:=ptExecute;
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Grant privilege not handled %d',[ord(nPrivilege.ntype)]),vDebugError); 
            {$ENDIF}
            //todo return resultErrCode etc.
            //todo continue with bad privilege code rather than abort totally.... exit; //abort - no point continuing
            inc(result); //add to warning count
            fromPt:=ptSelect; //just in case
            toPt:=ptSelect; //we only loop the once //just in case
            {Skip to next}
            nPrivilege:=nPrivilege.nextNode;
            continue; //skip this one & continue with next privilege
          end; {case}
          toPt:=fromPt; //we only loop the once
        end;

        {Loop for All privileges (loop once unless 'All' specified)}
        for privilegeType:=fromPt to toPt do
        begin
          {Add (or try to add at least) the privilege(s)}
          case nObject.ntype of
            ntTable:
            begin
              {We have already found table_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if privilegeType in [ptUsage,ptExecute] then  //todo maybe set [ptUsage,ptExecute] as a set, e.g. PtNotForTable - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              if nPrivilege.leftChild=nil then
              begin //no column-list, so just process table-level privilege (All always goes in here)
                {First check that we are privileged to grant this privilege}
                //todo use cache (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not privileged - speed
                if CheckTableColumnPrivilege(st,0{we don't care who grantor is},grantorAuthId, {note: we pass grantor as grantee, because we're checking our own privilege}
                                             False{we don't care about role/authId grantee},authId_level_match,
                                             r.authId{=table owner},objectId,0{=null=all table},table_level_match{must always return True since we pass column_id=0},
                                             privilegeType,True{we want grant-option search},grantabilityOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed checking grantability privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  //todo return resultErrCode etc.
                  inc(result); //add to warning count
                  {Skip to next}
                  break;
                end;
                if grantabilityOption<>Yes then
                begin
                  {Only error if we're not trying All, else skip silently}
                  if fromPt=toPt then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to grant privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    inc(result); //add to warning count
                    st.addError(sePrivilegeGrantFailed,sePrivilegeGrantFailedText);
                  end;
                  {Skip to next}
                  break;
                end;
                //todo cache this work by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed

                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Granting privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                {$ENDIF}

                {Add table_id,null}
                if SetTableColumnPrivilege(st,grantorAuthId,granteeAuthId,
                                           objectId,0{=null=all table},
                                           privilegeType,grantOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed setting privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  inc(result); //add to warning count
                  //todo return resultErrCode etc.
                  {Skip to next}
                  break;
                end;
              end
              else
              begin //column-list, so process each column separately
                {Process each column privilege in the list}
                nColumn:=nPrivilege.leftChild;
                while nColumn<>nil do
                begin
                  {Find column name in the table}
                  if r.fTuple.FindCol(nil,nColumn.idVal,''{not columnRefs so no range prefix},nil{no context},cTuple,cRef,cId)<>ok then
                  begin
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //abort current column privilege if child aborts
                  end;
                  if cid=InvalidColId then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown column reference (%s)',[nColumn.idVal]),vError); //todo return syntax error info to user?
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  //todo? assert cTuple=r.fTuple?

                  {First check that we are privileged to grant this privilege}
                  //todo use cache? (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not all columns are privileged, need to recheck each time - speed
                  if CheckTableColumnPrivilege(st,0{we don't care who grantor is},grantorAuthId, {note: we pass grantor as grantee, because we're checking our own privilege}
                                               False{we don't care about role/authId grantee},authId_level_match,
                                               r.authId{=table owner},objectId,cid,table_level_match{we don't care},
                                               privilegeType,True{we want grant-option search},grantabilityOption)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed checking grantability privilege %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugError); 
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  if grantabilityOption<>Yes then
                  begin
                    //Note: no need to silently skip if All, since All can never specify a column list
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to grant privilege %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    st.addError(sePrivilegeGrantFailed,sePrivilegeGrantFailedText);
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  //todo cache this work? by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed - would have to be if all columns were ok...

                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Granting privilege %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}

                  {Add table_id,cid}
                  if SetTableColumnPrivilege(st,grantorAuthId,granteeAuthId,
                                             objectId,cid,
                                             privilegeType,grantOption)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed setting privilege %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugError);
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;

                  {Next}
                  nColumn:=nColumn.nextNode;
                end; {each column}
              end;

              {todo - SQL99 book says we should do always add
                      table_id + column_id entries, but I think it's better (space/speed/neatness)
                      if we just add the 1 entry for table-level privileges
                      then we can check for table_id,null -> all columns,
                                       else others        -> limited columns,
                                       else               -> none
                      - plus we should add them for owned tables = another shortcut to lose! - not worth the hassle?

                      - needs testing when adding columns then tables, to ensure we clean up after a revoke etc. etc.
              }
            end; {ntTable}
            ntDomain:
            begin
              {We have already found domain_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if not(privilegeType in [ptUsage]) then  //todo maybe set [ptUsage] as a set, e.g. PtForDomain - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              {Check before each whether the exact privilege already exists, if it does, leave it else add}
              {Also, only error on not-granted-grant-privilege if we're not trying All, else skip silently}
              //todo...
              //check we can & then setDomainPrivilege
            end; {ntDomain}
            ntRoutine:
            begin
              {We have already found routine_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if not(privilegeType in [ptExecute]) then  //todo maybe set [ptExecute] as a set, e.g. PtForRoutine - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              {Check before each whether the exact privilege already exists, if it does, leave it else add}
              {Also, only error on not-granted-grant-privilege if we're not trying All, else skip silently}
              begin //process routine-level privilege
                {First check that we are privileged to grant this privilege}
                //todo use cache (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not privileged - speed
                if CheckRoutinePrivilege(st,0{we don't care who grantor is},grantorAuthId, {note: we pass grantor as grantee, because we're checking our own privilege}
                                         False{we don't care about role/authId grantee},authId_level_match,
                                         rt.authId{=routine owner},objectId,
                                         privilegeType,True{we want grant-option search},grantabilityOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed checking grantability privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  //todo return resultErrCode etc.
                  inc(result); //add to warning count
                  {Skip to next}
                  break;
                end;
                if grantabilityOption<>Yes then
                begin
                  {Only error if we're not trying All, else skip silently}
                  if fromPt=toPt then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to grant privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    inc(result); //add to warning count
                    st.addError(sePrivilegeGrantFailed,sePrivilegeGrantFailedText);
                  end;
                  {Skip to next}
                  break;
                end;
                //todo cache this work by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed

                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Granting privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                {$ENDIF}

                {Add routine_id}
                if SetRoutinePrivilege(st,grantorAuthId,granteeAuthId,
                                       objectId,
                                       privilegeType,grantOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed setting privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  inc(result); //add to warning count
                  //todo return resultErrCode etc.
                  {Skip to next}
                  break;
                end;
              end;
            end; {ntRoutine}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Grant object not handled %d',[ord(nObject.ntype)]),vAssertion);
            {$ENDIF}
            //todo return resultErrCode etc.
            result:=fail;
            exit; //abort - no point continuing
          end; {case}
        end; {for All (or one)}

        {Next listed privilege}
        nPrivilege:=nPrivilege.nextNode;
      end; {each privilege}


      {Next} //note: duplicated above before Continues
      nGrantee:=nGrantee.nextNode;
    end; {each grantee}

  {rough algorithm

   for each grantee (ok if some fail & some succeed - continue with warning)
     find grantee auth_id
     for each privilege (ok if some fail & some succeed - continue with warning?)
       find object type/id (e.g. table_id or domain_id etc.)
       check that we(grantor) have rights to grant such rights on this object/columns - if we own it then we do
        - use CheckPrivilege routines, e.g CheckPrivilege(grantor,privilege,table_id,column_id(0=table-level=all),grantOption)
          which looks at all privileges for this object (at all granularities) & our user or our user's roles
       does the privilege already exist? (fail or continue if so?)
        - use CheckPrivilege, but also/instead need to select from sysXPrivilege to see if row exists? = not same thing!
          e.g. 1. grant insert to Bob on table1
               2. grant insert (col3) to Bob on table 1
            2nd statement is superfluous if we just CheckPrivilege (Bob can already insert into all columns)
            but 2nd statement may need to be added explicitly to sysColumnPrivilege in case
            the 1st is revoked (if this can be done & would leave 2nd intact - check spec. - I don't think it would)

       if table or columns: insert 1 into sysTablePrivilege
       if columns: insert into sysColumnPrivilege for each column
       if routine: insert 1 into sysRoutinePrivilege
       if domain etc.: insert 1 into sys?Privilege
  }
  finally
    if r<>nil then r.free;
    if rt<>nil then rt.free;
  end; {try}
end; {Grant}

function Revoke(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Revoke privilege(s) on an object from user(s)
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntRevoke node

 RETURNS:  Ok,
           +ve = number of warnings (possible sub-failures) but some part worked
           else Fail
}
const routine=':Revoke';
var
  n,nGrantee,nObject,nRootPrivilege,nPrivilege,nColumn:TSyntaxNodePtr;

  objectId:integer;

  r:TRelation;
  rt:TRoutine;
  isView:boolean;
  viewDefinition:string;
  routineType,routineDefinition:string;
  id:string;

  grantOption,grantabilityOption:string;
  granteeAuth:string;
  granteeAuthId, grantorAuthId:integer;

  dummy_null:boolean; //todo extra (ifdef-conditional) safety throughout code: assert dummy_null=False whenever we assume so!

  sysAuthR:TObject; {TRelation;} //todo improve by using Trelation - no circularity here?

  privilegeType,fromPt,toPt:TprivilegeType;
  table_level_match,authId_level_match:boolean;

  cTuple:TTuple;
  cId:TColId;
  cRef:ColRef;
  tempResult:integer;
begin
  result:=ok; //default
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Revoking privilege(s)',[nil]),vDebug);
  {$ENDIF}

  grantorAuthId:=Ttransaction(st.owner).authId; //in SQL/3 I think we can override this, i.e. grant on behalf of someone

  toPt:=ptSelect; //to keep compiler warning quiet

  {Note whether we are trying to revoke the 'with grant' option}
  grantOption:=No;
  if nroot.nextNode<>nil then
    if nroot.nextNode.nType=ntWithGrantOption then
      grantOption:=Yes;

  {Note object detail node}
  nObject:=nroot.leftChild;

  r:=nil;
  rt:=nil;
  try
    {we also save the objectId to save having to re-find it every time in the loop}
    objectId:=0; //todo -1 safer?
    case nObject.ntype of
      ntTable:
      begin
        {Find table_id => objectId}
        //Since we may need to access/check column names as well, better to use Trelation.open?
        // then find logic is handled/centralised as well
        id:=nObject.rightChild.idVal;

        r:=TRelation.create;
          {Try to open this relation so we can get the id and its column ids if needed below}
          tempResult:=r.open(st,nObject.leftChild,'',id,isView,viewDefinition);
          if tempResult=ok then
          begin
            //todo check whether we're dealing with a view or base_table? we don't care...
            //- or do we? If we have grant-option on a view's constituent tables then we can
            //  grant privileges on the view - but how do we know which objectId(s) to lookup?
            // - probably best if we copy all privileges from all tables when we create the view...
            //  if we do, then what happens if we revoke on one of the underlying tables?
            //  - I would think the view would need to reflect it somehow?....check spec...
            objectId:=r.tableId;
          end
          else
          begin
            case tempResult of
              -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
              -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
            else
              st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
            end; {case}
            result:=-3; //could not find base_table or view
            exit; //abort
          end;
        //Note: we clean up r at end
      end; {ntTable}
      ntDomain:
      begin
        {Find domain_id => objectId}
      end; {ntDomain}
      ntRoutine:
      begin
        {Note: we don't record whether the user specified function/procedure/routine here
              so to use a routineType filter in future (to support func + procs with same name)
              we'd need to adjust the syntax tree & then cross-check/filter here}
        {Find routine_id => objectId}
        id:=nObject.rightChild.idVal;
        rt:=TRoutine.create;
          {Try to open this routine so we can get the id}
          tempResult:=rt.open(st,nObject.leftChild,'',id,routineType,routineDefinition);
          if tempResult=ok then
          begin
            objectId:=rt.routineId;
          end
          else
          begin
            case tempResult of
              -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
              -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
            else
              st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
            end; {case}
            result:=-3; //could not find routine
            exit; //abort
          end;
        //Note: we clean up rt at end
      end; {ntRoutine}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Revoke object not handled %d',[ord(nObject.ntype)]),vDebugError);
      {$ENDIF}
      //todo return resultErrCode etc.
      result:=fail;
      exit; //abort - no point continuing
    end; {case}

    //todo assert that objectId<>0

    {Note start of privilege list}
    nRootPrivilege:=nroot.leftChild.nextNode; //todo assert exists!?

    {For each grantee}
    nGrantee:=nroot.rightChild;
    while nGrantee<>nil do
    begin
      granteeAuthId:=0; //todo use invalidAuthId?
      if nGrantee.leftChild<>nil then
        granteeAuth:=nGrantee.leftChild.idVal
      else
        granteeAuth:='PUBLIC'; //todo use constant! or even remove from parser & lookup like any other since it always exists!
      {Lookup granteeAuthId}
      //todo move this routine into a separate routine: e.g. findAuthId(authName, id,type,password,default...);
      //  used in transaction.connect, here, createSchema etc?
      if Ttransaction(st.owner).db.catalogRelationStart(st,sysAuth,sysAuthR)=ok then
      begin
        try
          if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysAuthR,ord(sa_auth_name),granteeAuth)=ok then
          begin
            with (sysAuthR as TRelation) do
            begin
              fTuple.GetInteger(ord(sa_auth_id),granteeAuthId,dummy_null);
              //todo check authType=atUser? fail if atRole?
              {$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Found auth %s in %s',[granteeAuth,sysAuth_table]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
            end; {with}
          end
          else //granteeAuthId not found
          begin
            //todo in future this might be a good place to auto-create this auth/user

            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown granteeAuthId %s',[granteeAuth]),vDebugLow);
            {$ENDIF}
            //todo ? result:=badUsername;
            //todo return resultErrCode etc.
            inc(result); //add to warning count
            {Skip to next}
            nGrantee:=nGrantee.nextNode;
            continue;
          end;
        finally
          if Ttransaction(st.owner).db.catalogRelationStop(st,sysAuth,sysAuthR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysAuth
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError);
        {$ENDIF}
        //todo return resultErrCode etc.
        inc(result); //add to warning count
        {Skip to next}
        nGrantee:=nGrantee.nextNode;
        continue;
      end;

      //todo: reject if grantor=grantee, else loophole: could grant duplicate privileges to self!
      // - is here best place - or in Set routine(s)? 

      {For each privilege listed}
      nPrivilege:=nRootPrivilege;
      while nPrivilege<>nil do
      begin
        if nPrivilege.nType=ntAllPrivileges then
        begin
          {We loop for all possible privileges and attempt to grant them all,
           but we fail silently if we aren't allowed to grant any of them
           (or if they don't apply to this object).
           The overall aim is to grant for every privilege we have}
          fromPt:=ptSelect;
          toPt:=ptExecute;
        end
        else
        begin
          {Map privilege syntax node to type}
          case nPrivilege.nType of
            ntPrivilegeSelect:      fromPt:=ptSelect;
            ntPrivilegeInsert:      fromPt:=ptInsert;
            ntPrivilegeUpdate:      fromPt:=ptUpdate;
            ntPrivilegeDelete:      fromPt:=ptDelete;
            ntPrivilegeReferences:  fromPt:=ptReferences;
            ntPrivilegeUsage:       fromPt:=ptUsage;
            ntPrivilegeExecute:     fromPt:=ptExecute;
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Revoke privilege not handled %d',[ord(nPrivilege.ntype)]),vDebugError);
            {$ENDIF}
            //todo return resultErrCode etc.
            //todo continue with bad privilege code rather than abort totally.... exit; //abort - no point continuing
            inc(result); //add to warning count
            fromPt:=ptSelect; //just in case
            toPt:=ptSelect; //we only loop the once //just in case
            {Skip to next}
            nPrivilege:=nPrivilege.nextNode;
            continue; //skip this one & continue with next privilege
          end; {case}
          toPt:=fromPt; //we only loop the once
        end;

        {Loop for All privileges (loop once unless 'All' specified)}
        for privilegeType:=fromPt to toPt do
        begin
          {Remove (or try to remove at least) the privilege(s)}
          case nObject.ntype of
            ntTable:
            begin
              {We have already found table_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if privilegeType in [ptUsage,ptExecute] then  //todo maybe set [ptUsage,ptExecute] as a set, e.g. PtNotForTable - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              if nPrivilege.leftChild=nil then
              begin //no column-list, so just process table-level privilege (All always goes in here)
                {First check that we are privileged to revoke this privilege}
                //todo use cache (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not privileged - speed
                if CheckTableColumnPrivilege(st,grantorAuthId{grantor must be us},granteeAuthId,
                                             True{we care about role/authId grantee: todo?},authId_level_match,
                                             0{authId 0 because we never want a 'rights match' here, else would try to revoke
                                               a right. todo think-through & test to break},
                                             objectId,0{=null=all table},table_level_match{must always return True since we pass column_id=0},
                                             privilegeType,(grantOption=Yes){grant-option search?},grantabilityOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed checking revokability privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  //todo return resultErrCode etc.
                  inc(result); //add to warning count
                  {Skip to next}
                  break;
                end;
                if (grantabilityOption='') or ((grantOption=Yes) and (grantabilityOption<>Yes)) then
                begin
                  {Only error if we're not trying All, else skip silently}
                  if fromPt=toPt then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to revoke grant option for %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    inc(result); //add to warning count
                    st.addError(sePrivilegeRevokeFailed,sePrivilegeRevokeFailedText);
                  end;
                  {Skip to next}
                  break;
                end;
                //todo cache this work by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed

                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Revoking privilege %s on %d from %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                {$ENDIF}

                {Remove table_id,null}
                if UnsetTableColumnPrivilege(st,grantorAuthId,granteeAuthId,
                                           objectId,0{=null=all table},
                                           privilegeType,grantOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed unsetting privilege %s on %d from %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError); 
                  {$ENDIF}
                  inc(result); //add to warning count
                  //todo return resultErrCode etc.
                  {Skip to next}
                  break;
                end;
              end
              else
              begin //column-list, so process each column separately
                {Process each column privilege in the list}
                nColumn:=nPrivilege.leftChild;
                while nColumn<>nil do
                begin
                  {Find column name in the table}
                  if r.fTuple.FindCol(nil,nColumn.idVal,''{not columnRefs so no range prefix},nil{no context},cTuple,cRef,cId)<>ok then
                  begin
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //abort current column privilege if child aborts
                  end;
                  if cid=InvalidColId then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown column reference (%s)',[nColumn.idVal]),vError); //todo return syntax error info to user?
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  //todo? assert cTuple=r.fTuple?

                  {First check that we are privileged to revoke this privilege}
                  //todo use cache? (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not all columns are privileged, need to recheck each time - speed
                  if CheckTableColumnPrivilege(st,grantorAuthId{grantor must be us},granteeAuthId,
                                               True{we care about role/authId grantee: todo?},authId_level_match,
                                               0{authId 0 because we never want a 'rights match' here, else would try to revoke
                                                 a right. todo think-through & test to break},
                                               objectId,cid,table_level_match{we don't care},
                                               privilegeType,(grantOption=Yes){grant-option search?},grantabilityOption)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed checking revokability privilege %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugError);
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  if (grantabilityOption='') or ((grantOption=Yes) and (grantabilityOption<>Yes)) then
                  begin
                    //Note: no need to silently skip if All, since All can never specify a column list
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to revoke grant option for %s on %d.%d to %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    st.addError(sePrivilegeRevokeFailed,sePrivilegeRevokeFailedText);
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;
                  //todo cache this work? by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed - would have to be if all columns were ok...

                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Revoking privilege %s on %d.%d from %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}

                  {Remove table_id,cid}
                  if UnsetTableColumnPrivilege(st,grantorAuthId,granteeAuthId,
                                             objectId,cid,
                                             privilegeType,grantOption)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed unsetting privilege %s on %d.%d from %s (%d)',[PrivilegeString[privilegeType],objectId,cid,granteeAuth,granteeAuthId]),vDebugError); 
                    {$ENDIF}
                    //todo return resultErrCode etc.
                    inc(result); //add to warning count
                    {Skip to next}
                    nColumn:=nColumn.nextNode;
                    continue; //skip current column privilege & try next one
                  end;

                  {Next}
                  nColumn:=nColumn.nextNode;
                end; {each column}
              end;

              {todo - SQL99 book says we should do always add
                      table_id + column_id entries, but I think it's better (space/speed/neatness)
                      if we just add the 1 entry for table-level privileges
                      then we can check for table_id,null -> all columns,
                                       else others        -> limited columns,
                                       else               -> none
                      - plus we should add them for owned tables = another shortcut to lose! - not worth the hassle?

                      - needs testing when adding columns then tables, to ensure we clean up after a revoke etc. etc.
              }
            end; {ntTable}
            ntDomain:
            begin
              {We have already found domain_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if not(privilegeType in [ptUsage]) then  //todo maybe set [ptUsage] as a set, e.g. PtForDomain - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              {Check before each whether the exact privilege already exists, if it does, remove it else update}
              {Also, only error on not-granted-grant-privilege if we're not trying All, else skip silently}
              //todo...
            end; {ntDomain}
            ntRoutine:
            begin
              {We have already found routine_id = objectId}
              {First check this privilege is applicable to this object, if not skip this privilege}
              if not(privilegeType in [ptExecute]) then  //todo maybe set [ptExecute] as a set, e.g. PtForRoutine - neater/more maintainable?
              begin
                {Only error if we're not trying All, else skip silently}
                if fromPt=toPt then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Privilege %s not applicable to %d (attempted to %s (%d))',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                  {$ENDIF}
                  inc(result); //add to warning count
                  st.addError(seSyntaxPrivilegeNotApplicable,seSyntaxPrivilegeNotApplicableText);
                end;
                {Skip to next}
                break;
              end;
              {Check before each whether the exact privilege already exists, if it does, leave it else add}
              {Also, only error on not-granted-grant-privilege if we're not trying All, else skip silently}
              begin //process routine-level privilege
                {First check that we are privileged to grant this privilege}
                //todo use cache (in case multiple grantees) by checking ntPrivilegeX right child - if ntNOP -> not privileged - speed
                if CheckRoutinePrivilege(st,grantorAuthId{grantor must be us},granteeAuthId,
                                         True{we care about role/authId grantee: todo?},authId_level_match,
                                         0{authId 0 because we never want a 'rights match' here, else would try to revoke
                                           a right. todo think-through & test to break},
                                         objectId,
                                         privilegeType,True{we want grant-option search},grantabilityOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed checking revokability privilege %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  //todo return resultErrCode etc.
                  inc(result); //add to warning count
                  {Skip to next}
                  break;
                end;
                if (grantabilityOption='') or ((grantOption=Yes) and (grantabilityOption<>Yes)) then
                begin
                  {Only error if we're not trying All, else skip silently}
                  if fromPt=toPt then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not privileged to revoke grant option for %s on %d to %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                    {$ENDIF}
                    inc(result); //add to warning count
                    st.addError(sePrivilegeRevokeFailed,sePrivilegeRevokeFailedText);
                  end;
                  {Skip to next}
                  break;
                end;
                //todo cache this work by setting ntPrivilegeX right child to ntNOP or something -> not privileged - speed

                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Revoking privilege %s on %d from %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugLow);
                {$ENDIF}

                {Add routine_id}
                if UnsetRoutinePrivilege(st,grantorAuthId,granteeAuthId,
                                       objectId,
                                       privilegeType,grantOption)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed unsetting privilege %s on %d from %s (%d)',[PrivilegeString[privilegeType],objectId,granteeAuth,granteeAuthId]),vDebugError);
                  {$ENDIF}
                  inc(result); //add to warning count
                  //todo return resultErrCode etc.
                  {Skip to next}
                  break;
                end;
              end;
            end; {ntRoutine}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Revoke object not handled %d',[ord(nObject.ntype)]),vAssertion);
            {$ENDIF}
            //todo return resultErrCode etc.
            result:=fail;
            exit; //abort - no point continuing
          end; {case}
        end; {for All (or one)}

        {Next listed privilege}
        nPrivilege:=nPrivilege.nextNode;
      end; {each privilege}


      {Next} //note: duplicated above before Continues
      nGrantee:=nGrantee.nextNode;
    end; {each grantee}

  {rough algorithm

   for each grantee (ok if some fail & some succeed - continue with warning)
     find grantee auth_id
     for each privilege (ok if some fail & some succeed - continue with warning?)
       find object type/id (e.g. table_id or domain_id etc.)
          which looks at all privileges for this object (at all granularities) & our user or our user's roles
       does the privilege already exist? (fail or continue if so?)
        - use CheckPrivilege routines, e.g CheckPrivilege(grantor,privilege,table_id,column_id(0=table-level=all),grantOption)
       & check that we(grantor) have rights to revoke such rights on this object/columns, i.e. we are the grantor

       if table or columns: delete 1 from sysTablePrivilege
       if columns: delete from sysColumnPrivilege for each column
       if routine: delete 1 from into sysRoutinePrivilege
       if domain etc.: delete 1 from sys?Privilege
  }
  finally
    if r<>nil then r.free;
    if rt<>nil then rt.free;
  end; {try}
end; {Revoke}


function CreateSchema(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create a schema
 IN:
           tr      transaction
           st      statement
           nroot   pointer to ntCreateSchema node

 RETURNS:  Ok, else Fail

 Note: uses current server sys schema version as schema version
}

const routine=':CreateSchema';
var
  n:TSyntaxNodePtr;
  nextId,genId:integer;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];
  saveSchemaId:TSchemaId;
  saveSchemaName:string[MaxSchemaName];

  Auth_Id:integer;
  schemaName:string[MaxSchemaName];
  authName:string[MaxAuthName];

  dummy_null:boolean; //todo extra (ifdef-conditional) safety throughout code: assert dummy_null=False whenever we assume so!

  sysAuthR:TObject; {TRelation;} //todo improve by using Trelation - no circularity here?
  sysSchemaR:TObject; //Trelation

  //dummy results needed for createView - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;
begin
  result:=ok;

  n:=nroot;
  {Check we have a valid Auth_id}
  authName:='';
  while n.nextNode<>nil do //loop through chain looking for authorization clause
  begin
    n:=n.nextNode;
    if n.ntype=ntAuthorization then
    begin
      authName:=n.leftChild.idVal;
    end;
  end;
  if authName<>'' then
  begin
    {Lookup AuthId}
    //todo move this routine into a separate routine: e.g. findAuthId(authName, id,type,password,default...);
    //  used in transaction.connect, here, createSchema, dropUser etc?
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysAuth,sysAuthR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysAuthR,ord(sa_auth_name),authName)=ok then
        begin
          with (sysAuthR as TRelation) do
          begin
            fTuple.GetInteger(ord(sa_auth_id),Auth_Id,dummy_null);
            //todo check authType=atUser? fail if atRole?
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Found auth %s in %s',[AuthName,sysAuth_table]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}

            //todo maybe best if we auto-set the user's default schema to the new one
          end; {with}
        end
        else //AuthName not found
        begin
          //todo in future this might be a good place to auto-create this auth/user
          // with a default schema of the one we're about to create

          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown authorization %s',[authName]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          st.addError(seSyntaxUnknownAuth,format(seSyntaxUnknownAuthText,[authName]));
          //todo ? result:=badUsername;
          result:=fail;
          exit; //abort, no point continuing
        end;
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysAuth,sysAuthR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError);
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysAuth
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      //todo return resultErrCode etc.
      result:=fail;
      exit; //abort, no point continuing
    end;
  end
  else
    auth_id:=Ttransaction(st.owner).AuthId; //use default authId

  n:=nroot;
  {Get the schema name}
  if n.leftChild<>nil then
    schemaName:=n.leftChild.rightChild.idVal
  else
    schemaName:=authName; {schema name defaults to (unqualified) authorization user}

  if schemaName='' then
  begin
    //todo schemaName:=lookupAuthName(tr.authId);  //todo only if standalone, i.e. not in module (=bad) - Date P47
    schemaName:=DEFAULT_AUTHNAME; //todo! module_default_auth or at least use DEFAULT_SCHEMA!?=fail - should never happen!
  end;

  {Check this schema name does not already exist in this catalog, else fail
  Note: todo this check & others like it (e.g. in relation.createNew) is not good enough
        we're safer using a UNIQUE constraint to prevent concurrent creation & dual commits.
  }
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysSchema,sysSchemaR)=ok then
  begin
    try
      if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysSchemaR,ord(ss_schema_name),schemaName)=ok then
      begin
        with (sysSchemaR as TRelation) do
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Found existing schema %s in %s',[schemaName,sysSchema_table]),vError);
          {$ENDIF}
          {$ENDIF}
          st.addError(seSyntaxSchemaAlreadyExists,seSyntaxSchemaAlreadyExistsText);
          result:=fail;
          exit;
        end; {with}
      end;
      //else not found
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
    log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schemaName]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {Check we have privilege}
  if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
     not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) and
     not(auth_id=Ttransaction(st.owner).authID) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to create schema %s for %d',[schemaName,Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to create this schema']));
    result:=Fail;
    exit;
  end;

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining schema %s',[schemaName]),vDebug);
  {$ENDIF}


  saveSchemaId:=Ttransaction(st.owner).schemaID; //save schema
  saveSchemaName:=Ttransaction(st.owner).schemaName; //save schema name
  saveAuthId:=Ttransaction(st.owner).AuthId; //save auth Id
  saveAuthName:=Ttransaction(st.owner).AuthName;
  try
    genId:=0; //lookup by name
    Ttransaction(st.owner).db.getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysSchema_generator',genId,nextId); //todo check result!
    Ttransaction(st.owner).SchemaId:=nextId;
    Ttransaction(st.owner).SchemaName:=schemaName;
    {We will use auth_id as the tr.AuthId, but first we insert the schema row as authId=_SYSTEM...}
    {We need to insert as _SYSTEM to ensure we have permission on sysSchema (plus is quicker since _SYSTEM has ownership rights)}
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
      result:=ExecSQL(tempStmt,
               format(
               'INSERT INTO %s.sysSchema (catalog_id,auth_id,schema_id,schema_name,schema_version_major,schema_version_minor) VALUES (%d,%d,%d,''%s'',%d,%d); '
               ,[sysCatalogDefinitionSchemaName,Ttransaction(st.owner).CatalogID,Auth_Id,Ttransaction(st.owner).SchemaId,schemaName{=tr.SchemaName},
                 dbCatalogDefinitionSchemaVersionMajor,dbCatalogDefinitionSchemaVersionMinor])
              ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysSchema row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysSchema',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?

    Ttransaction(st.owner).AuthId:=auth_id; //now set auth id to schema owner for rest of objects
    Ttransaction(st.owner).AuthName:=authname;

    {Loop through schema element sub-tree chain}
    n:=n.rightChild;
    while n<>nil do
    begin
      //todo don't assume that we have at least one element?
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('schema element %p %d',[n,ord(n.ntype)]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
      {Before we call the sub-create routine, we need to ensure its deleteSyntaxTree doesn't
       clear the next sub-trees for this schema, so we increment the link-ref-count on the
       next one first}
        {Create the schema element}
        case n.nType of
          ntCreateTable:
          begin
            result:=CreateTable(st,n);
          end;
          ntCreateView:
          begin
            result:=CreateView(st,n);
          end; {createView}
          ntCreateRoutine:
          begin
            result:=CreateRoutine(st,n);
          end; {createRoutine}
          ntCreateDomain:
          begin
            result:=CreateDomain(st,n);
          end; {createDomain}
          ntGrant:
          begin
            result:=Grant(st,n);
          end; {grant}

          {Non-standard stuff}
          ntCreateIndex:
          begin
            {$IFDEF IGNORE_USER_CREATEINDEX}
            result:=ok;
            {$ELSE}
            result:=UserCreateIndex(st,n);
            {$ENDIF}
            if result>ok then result:=ok;
          end;
          ntCreateSequence:
          begin
            result:=CreateSequence(st,n);
            if result>ok then result:=ok;
          end;

          //todo etc. - keep in sync. with executePlan
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown schema element type %d',[ord(n.nType)]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail; //todo return more specific info via a novel error code?
        end; {case}
        if result<>ok then exit; //abort if any element aborts //todo ensure we rollback any half-done schema!
      n:=n.nextNode; //move to next element definition
    end; {while}

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Defined schema %s',[schemaName]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}

    {We now set the named user's default schema to this new one} //todo ok with standard? better than adding 'set default schema' syntax & cleaner?
    {We need to insert as _SYSTEM to ensure we have permission on sysAuth (plus is quicker since _SYSTEM has ownership rights)}

    //todo+: we could now issue an Alter User u Set Default Schema s    = safer?
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt);
      result:=ExecSQL(tempStmt,
        format('UPDATE %s.sysAuth SET default_schema_id=%d WHERE auth_id=%d ',
               [sysCatalogDefinitionSchemaName,Ttransaction(st.owner).SchemaId,auth_Id])
              ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed updating sysAuth row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Updated %d entries in sysAuth',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Updated authorisation id %s',[authName]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}

  finally
    Ttransaction(st.owner).SchemaId:=saveSchemaId;  //restore schema
    Ttransaction(st.owner).SchemaName:=saveSchemaName;  //restore schema name
    Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth
    Ttransaction(st.owner).AuthName:=saveAuthName;
  end; {try}
end; {createSchema}

function CreateCatalog(dbs:TDBserver;st:TStmt;nroot:TSyntaxNodePtr):integer;
{Create a catalog (non-SQL/92)
 IN:       dbs     db server needed to control new catalog creation
           tr      transaction
           nroot   pointer to ntCreateCatalog node

 RETURNS:  Ok,

           -2=target is already attached to the server (could be self!)
           -3=target file already exists (but was not open)
           else Fail

 Side effects:
   the current transaction is rolled back & left disconnected but attached to the new catalog
   the newly created catalog remains open on the server

 todo:
      re-think what this routine does:
      shouldn't we just add a new entry to the sysCatalog table? each schema is in a catalog, & sysAuth gives default catalog on connect...
      - we'd need to ensure all schema searches were restricted to match the current/specified catalog...
        + info-schema would need to join to sysCatalog via sysSchema etc.
      so the routine here is really behaving now as 'create cluster'!
      but... it seems like a lot of work to change our 1 db = 1 catalog half-assumptions... so for now
             we'll keep assuming 1 db=1 catalog & many catalog (db files) = 1 cluster...
}
const routine=':CreateCatalog';
var
  n:TSyntaxNodePtr;
  catalogName:string[MaxCatalogName];
  oldDB,newDB:TDB;
begin
  result:=fail;
  n:=nroot;

  //todo: check no other connections(transactions) are active against this db - else reject!
  //todo: note: this includes garbageCollector thread! so suspend it!

  {Check we have privilege}
  //todo simplify this logic!
  if (not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and                   //if not admin
      not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) and                         //(and not sys)
      not({(Ttransaction(st.owner).db.owner as TDBserver)}dbs.getInitialConnectdb=nil)) //and exists a primary catalog
     or
     not( ({(Ttransaction(st.owner).db.owner as TDBserver)}dbs.getInitialConnectdb=nil) or
          ({(Ttransaction(st.owner).db.owner as TDBserver)}dbs.getInitialConnectdb=Ttransaction(st.owner).db) //or, if ours is not primary catalog (if one exists)
        ) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to create a catalog for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to create a catalog on this server']));
    result:=Fail;
    exit;
  end;

  {Get the catalog name}
  catalogName:=n.leftChild.idVal;

  //todo check catalogName is valid (i.e. no spaces or bad filename characters)

  {Check targetName is not open}
  if {(Ttransaction(st.owner).db.owner as TDBserver)}dbs.findDB(catalogName)<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Target database is already open on this server',vDebug);
    {$ENDIF}
    st.addError(seTargetDatabaseIsAlreadyOpen,seTargetDatabaseIsAlreadyOpenText);
    result:=-2;
    exit;
  end;

  {Check target file doesn't exist}
  if fileExists(catalogName+DB_FILE_EXTENSION) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Target database already exists',vDebug);
    {$ENDIF}
    st.addError(seSyntaxCatalogAlreadyExists,seSyntaxCatalogAlreadyExistsText);
    result:=-3;
    exit;
  end;

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining catalog %s',[catalogName]),vDebug);
  {$ENDIF}

  {Currently we must us the server's db handle to create the new catalog
   //todo remove this need, so we can keep current db & tran? active
  }

  {We must finish the current transaction to be able to connect to the new target}
  Ttransaction(st.owner).disconnect; //todo document/warn that we rollback here!
  Ttransaction(st.owner).disconnectFromDB;

  newDB:=dbs.addDB(catalogName);
  if newDB=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where,'Failed to add new db: '+catalogName,vdebug);
    {$ENDIF}
    exit; //abort - no point continuing? //todo note: we are left unstable?
  end;

  //todo copy tran/connection params from catalogBackup...?

  //Note: we must not have connected until after the createDB because
  Ttransaction(st.owner).connectToDB(newDB); //todo check result (leave connected at end though)
  try
    st.Rt:=InvalidStampId; //resume in no transaction //Note: assumes 'not in a transaction'=>InvalidTranId

    result:=Ttransaction(st.owner).db.createDB(catalogName,False); //=>ok result
    if result=ok then
    begin
      if Ttransaction(st.owner).db.openDB(catalogName,False)=ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where,'Opened new database',vDebug);
        log.add(st.who,where,'',vDebug);
        {$ENDIF}
        Ttransaction(st.owner).db.status; //debug report
        (Ttransaction(st.owner).db.owner as TDBserver).buffer.status;
        {Now add the information_schema}
        if Ttransaction(st.owner).db.createInformationSchema<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where,'Failed to create '+sysInformationSchemaName,vdebugError);
          {$ENDIF}
          result:=fail;
          //todo discard partial db catalog?
          exit; //abort
        end;
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where,'Failed to open new database',vdebugError);
        {$ENDIF}
        //todo discard partial db catalog?
        exit; //abort
      end;
    end;
  finally
    {Disconnect from the new catalog since our credentials are system/old-catalog, but leave 'connected' to the db}
    Ttransaction(st.owner).disconnect;

    if result<>ok then dbs.removeDB(newDB); //tidy up after failure
  end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defined catalog %s',[catalogName]),vDebugLow);
  {$ENDIF}
end; {createCatalog}

function BackupCatalog(st:Tstmt;nroot:TSyntaxNodePtr;connection:TIdTCPConnection):integer;
{Backup a catalog
 IN:
           s           statement
           nroot       pointer to ntBackupCatalog node
           connection  client connection to return raw results to //not used?

 RETURNS:  Ok, else Fail
}
const routine=':BackupCatalog';
begin
  //todo if source<>our db then load & pass it, e.g. to upgrade from an old version...

  {Check we have privilege}
  if (not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
      not(Ttransaction(st.owner).authID=SYSTEM_AUTHID))
     or
     not((Ttransaction(st.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(st.owner).db) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to backup a catalog for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to backup this catalog on this server']));
    result:=Fail;
    exit;
  end;

  {Check target file doesn't exist}
  if fileExists(nroot.leftChild.idVal+DB_FILE_EXTENSION) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Backup target already exists',vDebugLow);
    {$ENDIF}
    st.addError(seSyntaxCatalogAlreadyExists,seSyntaxCatalogAlreadyExistsText);
    result:=Fail;
    exit;
  end;

  result:=CatalogBackup(st,(Ttransaction(st.owner).thread as TIdPeerThread).connection,nroot.leftChild.idVal);
end; {BackupCatalog}

function CreateUser(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Create an authorisation id (non-SQL/92)
 IN:       tr      transaction
           st      statement
           nroot   pointer to ntCreateUser node

 RETURNS:  Ok, else Fail

 Side effects:
}
const routine=':CreateUser';
var
  n:TSyntaxNodePtr;
  authName:string;
  password:string;
  authId,genId:integer;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;

  sysAuthR:TObject; {TRelation;} //todo improve by using Trelation - no circularity here?
begin
  result:=fail;

  {Check we have privilege}
  if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
     not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to create user for %d',[Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to create a user']));
    result:=Fail;
    exit;
  end;

  n:=nroot;
  {Get the auth name}
  authName:=n.leftChild.idVal;
  password:=''; //=>null
  {Get any password}
  if n.rightChild<>nil then //todo assert n.rightChild.ntype=ntPassword
    password:=n.rightChild.leftChild.strVal;

  //todo check password is valid (e.g. correct hash length/format) + not containing '! see below
  //todo check authName is valid (i.e. no spaces or bad characters)
  {Check authName does not already exist - for now we fail if it does!}
  //todo improve by implicitly using primary key constraints!
  //todo Note: this current check ignores multi-users creating at same time!
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysAuth,sysAuthR)=ok then
  begin
    try
      if (sysAuthR as Trelation).tableId=0 then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError);
        {$ENDIF}
        exit;
      end;

      if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysAuthR,ord(sa_auth_name),authName)=ok then
      begin
        with (sysAuthR as TRelation) do
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Found existing auth %s in %s',[authName,sysAuth_table]),vError);
          {$ENDIF}
          {$ENDIF}
          st.addError(seSyntaxAuthAlreadyExists,seSyntaxAuthAlreadyExistsText);
          exit;
        end; {with}
      end; //ok: authName does not already exist
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysAuth,sysAuthR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysAuth
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError);
    {$ENDIF}
    exit;
  end;


  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defining authorisation id %s',[authName]),vDebug);
  {$ENDIF}

    {Now add the new auth to the system catalog}
    {We use the default/system stmt plan to add the entry
     Benefits:
       simple
       no need for explicit structure knowledge = no maintenance
       transaction handling is correct - no need for our DDL to auto-commit like most other dbms's
     Downside:
       need to parse, build query tree, execute iterator plan etc.  = slower than direct insert into relation
       - but this only take a few milliseconds, so worth it for the benefits
    }
    //todo check it doesn't already exist! maybe a future primary key will prevent this...
    genId:=0; //lookup by name
    result:=(Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysAuth_generator',genId,authId);
    if result<>ok then
      exit; //abort
    {We need to insert as _SYSTEM to ensure we have permission on sysAuth (plus is quicker since _SYSTEM has ownership rights)}
    saveAuthId:=Ttransaction(st.owner).AuthId;
    saveAuthName:=Ttransaction(st.owner).AuthName;
    Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
    Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
    try
      if password='' then
        password:='null'
      else
        password:=''''+password+''''; //todo => ensure password cannot contain '
      Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
      result:=ExecSQL(tempStmt,
        format('INSERT INTO %s.sysAuth (auth_id,auth_name,auth_type,"password",default_catalog_id,default_schema_id) '+
               'VALUES (%d,''%s'',''%s'',%s,%d,%d); ',
               [sysCatalogDefinitionSchemaName,authId,authName,atUser,password,Ttransaction(st.owner).catalogId,Ttransaction(st.owner).schemaId])
              ,nil,resultRowCount);
      if result<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'  Failed inserting sysAuth row via PrepareSQL/ExecutePlan: '{todo getLastError},vError)
        {$ENDIF}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %d entries into sysAuth',[resultRowCount]),vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //todo assert resultRowCount=1?
    finally
      Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
      Ttransaction(st.owner).AuthName:=saveAuthName;
    end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Defined authorisation id %s',[authName]),vDebugLow);
  {$ENDIF}
end; {createUser}

function AlterUser(st:Tstmt;nroot:TSyntaxNodePtr):integer;
{Alter an authorisation id (non-SQL/92)
 IN:       tr      transaction
           st      statement
           nroot   pointer to ntAlterUser node

 RETURNS:  Ok,
           -2 = unknown catalog
           -3 = unknown schema
           else Fail

 Side effects:
}
const routine=':AlterUser';
var
  n:TSyntaxNodePtr;
  authName:string;

  saveAuthId:TAuthId;
  saveAuthName:string[MaxAuthName];

  //dummy results needed for PrepareSQL - not passed back from this routine (yet)
  resultRowCount:integer;
  tempStmt:TStmt;

  updateSetClause:string;

  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;
  tempResult:integer;
begin
  result:=fail;

  n:=nroot;
  {Get the auth name}
  authName:=n.leftChild.idVal;

  {Check we have privilege}
  if not(Ttransaction(st.owner).authAdminRole in [atAdmin]) and
     not(Ttransaction(st.owner).authID=SYSTEM_AUTHID) and
     not(uppercase(authName)=uppercase(Ttransaction(st.owner).authName)) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Not privileged to alter user %s for %d',[authName,Ttransaction(st.owner).AuthId]),vDebugLow);
    {$ENDIF}
    st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to alter this user']));
    result:=Fail;
    exit;
  end;


  //todo check password is valid (e.g. correct hash length/format) + not containing '! see below
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Updating authorisation id %s',[authName]),vDebug);
  {$ENDIF}

  {Build the UPDATE SET clause}
  updateSetClause:='SET ';

  case n.rightChild.nType of
    ntPassword:
    begin
      if n.rightChild.leftChild.ntype=ntNull then
        updateSetClause:=updateSetClause+format('%s=NULL ',['"password"'])
      else
        updateSetClause:=updateSetClause+format('%s=''%s'' ',['"password"',n.rightChild.leftChild.strVal]);
    end;
    ntSchema:
    begin
      tempResult:=getOwnerDetails(st,n.rightChild,'',Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
      if tempResult<>ok then
      begin  //couldn't get access to sysSchema
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugLow);
        {$ENDIF}
        result:=tempResult;
        case result of
          -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
          -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
        end; {case}
        exit; //abort
      end;
      //todo assumes so assert catalog_Id = default_catalog_id = sysCatalogDefinitionCatalogId = 1
      updateSetClause:=updateSetClause+format('%s=%d ',['default_schema_id',schema_Id]);
    end;
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unexpected alteration %d',[ord(n.rightChild.nType)]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;
  {todo assert updateSetClause<>'SET '}

  {We need to update as _SYSTEM to ensure we have permission on sysTableColumnPrivilege (plus is quicker since _SYSTEM has ownership rights)}
  saveAuthId:=Ttransaction(st.owner).AuthId;
  saveAuthName:=Ttransaction(st.owner).AuthName;
  Ttransaction(st.owner).AuthId:=SYSTEM_AUTHID;
  Ttransaction(st.owner).AuthName:=SYSTEM_AUTHNAME; //=>'_SYSTEM'
  try
    Ttransaction(st.owner).getSpareStmt(stSystemDDL,tempStmt); //todo abort if fail
    begin //we're dealing with the routine: so update existing (auth-id level) row
      //todo since we're using SQL, we should always have privileges to update privileges!
      result:=ExecSQL(tempStmt,
        format('UPDATE %s.sysAuth '+
               '%s '+
               'WHERE auth_name=''%s'' ; ',
               [sysCatalogDefinitionSchemaName, updateSetClause, authName])
              ,nil,resultRowCount);
    end;
    if resultRowCount=0 then
    begin
      result:=-2; //=> invalid user
      st.addError(seUnknownAuth,seUnknownAuthText);
      exit;
    end;
    if result<>ok then //todo return warning?
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'  Failed updating/inserting sysAuth row via ExecSQL: '{todo getLastError},vError) 
      {$ENDIF}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Updated/inserted %d entries into sysAuth',[resultRowCount]),vdebug);
      {$ELSE}
      ;
      {$ENDIF}
      //todo assert resultRowCount=1?
  finally
    Ttransaction(st.owner).AuthId:=saveAuthId; //restore auth_id
    Ttransaction(st.owner).AuthName:=saveAuthName;
  end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Updated authorisation id %s',[authName]),vDebugLow);
  {$ENDIF}
end; {alterUser}


function CreateTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a TableExp
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntTableExp syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createTableExp';
var
  n:TSyntaxNodePtr;
  raNode:TAlgebraNodePtr;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntTableExp then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntTableExp',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntJoinTableExp:
    begin
      result:=CreateJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntJoinTableExp}

    ntNonJoinTableExp:
    begin
      result:=CreateNonJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTableExp}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('TableExp left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}

  {Loop through clause tree chain looking for initial order by
   - else could be column alias list - if so forget it...}
  n:=sroot;
  n:=n.nextNode;
  while n<>nil do
  begin
    case n.ntype of
      ntOrderBy:
      begin
        //todo only allow in direct/cursor SQL
        //todo (re)move/merge? if group by already used? =optimiser's job!- don't worry here
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Order By...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {Add the new sort node and point to the column list header in the syntax tree}
        raNode:=mkANode(antSort,n.leftChild,nil,aroot,nil);
        //debug? raNode.rangeName:=aroot.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
        aroot:=raNode; //new head
        {This next section tries a mini-traversal of the sub-tree purely
         for parser-debugging purposes. It can be removed. All we really
         need to do here is link this portion of the syntax tree to the
         algebra tree with a new Group node}
        if n.leftChild<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  %d',[ord(n.leftChild.ntype)]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
      end; {order by}
      ntId:
      begin
        {We've found a column alias list (appended at the table_ref level)
         so abandon the search for interesting clause nodes}
        break; //exit while loop
      end;

      ntAny,ntAll:
      begin
        //ignore attached clauses - these are handled by eval routines
      end; {ntAny,ntAll}
    else //todo: make into assertion - should never happen
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unknown clause syntax node in TableExp: %d',[ord(n.ntype)]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
    end; {case}
    n:=n.nextNode; //move to next clause
  end; {while}
end; {CreateTableExp}

function CreateJoinTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a JoinTableExp
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntJoinTableExp syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createJoinTableExp';
var
  n,next,ref:TSyntaxNodePtr;

  raTemp:TAlgebraNodePtr;
  joinNodeType:AlgebraNodeType;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntJoinTableExp then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntJoinTableExp',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntCrossJoin:
    begin
      result:=CreateTableRef(st,n.leftChild,False,raTemp);               //left
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      {We build a cross join in the same way as a cartesian join}
      aroot:=mkANode(antInnerJoin,nil,nil,raTemp,nil);
      result:=CreateTableRef(st,n.leftChild,True,raTemp);              //right
      linkARightChild(aroot,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Cross Join',vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
    end; {ntCrossJoin}

    ntJoin:
    begin
      result:=CreateTableRef(st,n.leftChild,False,raTemp);               //left
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      {We build a join in the same way as a cartesian join}
      //todo: build left/right/full Join node
      //+todo: - we will leave this to the join routine...
      //      & process /natural /on/using:
      //                natural -> find columns with same names (& types?) & build cond -> antSelection
      //                on -> add cond to Where tree (or add another antSelection node (before the join!)? - already pushed down=optimal)
      //                using -> antSelection with columns = columns ...
      //  - also reject bad combinations, e.g. natural.. on.. using.. etc.
      joinNodeType:=antInnerJoin; //default
      ref:=nil; //default syntax node reference (used by join startup code)
      next:=n.leftChild.nextNode;
      while next<>nil do
      begin
        case next.nType of
          ntJoinInner: {explicit default};
          ntJoinLeft:  joinNodeType:=antLeftJoin;
          ntJoinRight: joinNodeType:=antRightJoin;
          ntJoinFull:  joinNodeType:=antFullJoin;
          //todo what is this?: ntJoinUnion:joinNodeType:=antUnionJoin;
          //todo handle rest of chain possibilities...
          ntJoinOn:    begin
                         //Note: if this does not contain x=y then can't use MergeJoin etc. //todo optimiser?
                         if ref<>nil then
                           {$IFDEF DEBUG_LOG}
                           log.add(st.who,where+routine,format('ntJoinOn not allowed in this combination, continuing using On...',[1]),vDebugError);
                           {$ELSE}
                           ;
                           {$ENDIF}
                         ref:=next;
                       end;
          ntJoinUsing: begin
                         if ref<>nil then
                           {$IFDEF DEBUG_LOG}
                           log.add(st.who,where+routine,format('ntJoinUsing not allowed in this combination, continuing using Using...',[1]),vDebugError);
                           {$ELSE}
                           ;
                           {$ENDIF}
                         ref:=next;
                       end;
          ntNatural:   begin
                         if ref<>nil then
                           {$IFDEF DEBUG_LOG}
                           log.add(st.who,where+routine,format('ntNatural not allowed in this combination, continuing using Natural...',[1]),vDebugError);
                           {$ELSE}
                           ;
                           {$ENDIF}
                         ref:=next; //its up to the join startup code to pick the 'natural' selection
                       end;
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('ntJoin modifier option not handled (%d), continuing...',[ord(next.nType)]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
        end; {case}
        {Move to next in chain}
        next:=next.nextNode;
      end;
      aroot:=mkANode(joinNodeType,nil,nil,raTemp,nil);
      aroot.nodeRef:=ref; //link to syntax node ref (if one has been specified above)
      result:=CreateTableRef(st,n.leftChild,True,raTemp);              //right
      linkARightChild(aroot,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Join...',vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
    end; {ntJoin}

    ntJoinTableExp:
    begin
      //directly recursive
      result:=CreateJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntJoinTableExp}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntJoinTableExp left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateJoinTableExp}

function CreateTableRef(st:Tstmt;sparent:TSyntaxNodePtr;useRightChild:boolean;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a TableRef
 IN:
           tr                 transaction
           st                 statement
           sparent            pointer to parent of ntTableRef syntax node (may be pointed to new sub-tree)
           useRightChild      use right child of parent as ntTableRef, else use leftChild
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail

 Notes:
   may modify the syntax tree, to replace view with its definition sub-tree
   (that's why we need to know the parent node)
}
const routine=':createTableRef';
var
  i:ColRef;

  sroot,n,n2,n3,newN:TSyntaxNodePtr;

  r:TRelation;
  isView:boolean;
  viewDefinition:string;

  id:string;
  tempResult:integer;
begin
  result:=Fail;
  aroot:=nil;

  if useRightChild then
    sroot:=sparent.rightChild
  else
    sroot:=sparent.leftChild;

  //todo assert sroot<>nil!

  if sroot.ntype<>ntTableRef then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Parent''s child is not ntTableRef',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntJoinTableExp:
    begin
      result:=CreateJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntJoinTableExp}

    ntTable:
    begin
      id:=n.leftChild.rightChild.idVal;
      {Check whether we're dealing with a view or base_table}
      r:=TRelation.create;
      try
        {Try to open this relation so we can check the type & its column refs}
        tempResult:=r.open(st,n.leftChild.leftChild,'',id,isView,viewDefinition);
        if tempResult=ok then
        begin
          if isView then
          begin //view
            {Build a syntax sub tree from the viewDefinition}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('expanding ntTableRef into view (%s)',[id]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            result:=ParseSubSQL(st,viewDefinition,newN);
            if result<>ok then exit; //abort

            //todo assert newN.ntype=ntCreateView
            //todo assert view name=id? - no point since we opened the view with the id!

            //todo expand any select * to use original columns

            {Modify the syntax tree to include a table alias
             and optional column aliases according to the view definition
             i.e. we wrap the view definition's table_exp in a table_ref}
            {Build artifical AS node to alias as per the view}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('building aliased wrapper node of table_ref for view''s table_exp (%s)',[id]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            n2:=mkLeaf(st.srootAlloc,ntId,uGlobal.ctUnknown,0,0);
            n2.nullVal:=false;
            n2.idVal:=id; //add explicit view range name

            {Link any view column alias list to the wrapper}
            if newN.rightChild.nextNode<>nil then
            begin
              chainNext(n2,newN.rightChild.nextNode);
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('linked column alias list to wrapper node (%p)',[n2.nextNode]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
            end;

            {If the view has been re-aliased, then use the explicit alias instead of the view name
             (the actual range-aliasing will be done when this artificial tableRef is pre-evaluated)}
            if n.rightChild<>nil then
            begin
              n2.idVal:=n.rightChild.idVal; //explicit range name override
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('  ... as %s',[n.rightChild.idVal]),vDebug);
              {$ELSE}
              ;
              {$ENDIF}
            end;
            //else keep original view name

            {Now we can build the wrapper and insert it between the ntCreateView and its ntTableExp sub-tree}
            n3:=mkNode(st.srootAlloc,ntTableRef,uGlobal.ctUnknown,newN.rightChild,n2);

            newN:=n3; //point to the root of the new sub-tree

            {Now replace the current syntax sub-tree with the new tableRef around the new expanded one}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('deleting existing ntTableRef sub-tree (%p)',[sroot]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {Note: by unlinking and then re-linking we generate a few syntax tree warnings
             (because we create an orphaned tree) but they can be ignored.
             - really, we've no need to unlink the about-to-be-zapped sub-tree,
             (or haven't we? deleteSyntaxTree wouldn't work if tree root was still being referenced!)
             and we could just link in the new tree, but this overwrites the existing child
             pointer - and that's not as clean as first setting the child pointer to nil via unlink.
             This shouldn't be a problem anywhere else since syntax trees are built once (grown) and not chopped about...
            }
            if useRightChild then unlinkRightChild(sparent) else unlinkLeftChild(sparent);
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('pointing to new expanded sub-tree (%p)',[newN]),vDebugLow);
            {$ENDIF}
            sroot:=newN;
            {swap in the new sub-tree root - the caller now takes on responsibility for freeing it}
            if useRightChild then linkRightChild(sparent,sroot) else linkLeftChild(sparent,sroot); //increases reference count to sub-tree...

            {$IFDEF DEBUG_LOG}
            log.quick('expanded sub-tree:');
            {$ELSE}
            ;
            {$ENDIF}
            DisplaySyntaxTree(sroot); //debug before

            {Now create and return the sub-plan - recursive call}
            {Note: we pass the same parent & useRightChild that we were passed, since we've just expanded the parent's child and we're now evaluating it}
            result:=CreateTableRef(st,sparent,useRightChild,aroot);

            //todo: we should check that any view defined (especially as select *) is still
            //      returning the same column names - need to check now while we have the view relation open...
            //      (i.e. to trap when underlying table(s) is modified, e.g. drop column!)

            {$IFDEF DEBUG_LOG}
            log.quick('expanded algebra:');
            {$ELSE}
            ;
            {$ENDIF}
            DisplayAlgebraTree(aroot);

            {Note: we only prescribe the algebra here - and so we leave the optimiser
             to (cleverly!) merge this with any above/below it to create the iterator
             execution plan}

            //todo check/prove! falling through to next case doesn't look at new sroot value - although might be quicker?
          end
          else
          begin //base table
            {Now create the node in the algebra tree}
            aroot:=mkANode(antRelation,n,nil{may be set below},nil,nil);
            {Link the opened relation - we leave it open for the execution plan to use}
            aroot.rel:=r;
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('  Added base table node %s',[id]),vDebug);
            {$ELSE}
            ;
            {$ENDIF}
            if n.rightChild<>nil then
            begin
              aroot.rangeName:=n.rightChild.idVal; //explicit range name
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('  ... as %s',[n.rightChild.idVal]),vDebug);
              {$ELSE}
              ;
              {$ENDIF}
              {If the right child has a nextNode then this is the list of column aliases
               so we pass a reference to it to the algebra node for use after the relation is opened
               during the iterator initialisation
               //todo or maybe, since the relation is opened here, we should rename the columns now!?
              }
              aroot.exprNodeRef:=n.rightChild.nextNode; //link to optional column aliases
            end
            else
            begin
              aroot.catalogName:=aroot.rel.catalogName;
              aroot.schemaName:=aroot.rel.schemaName;
              aroot.tableName:=aroot.rel.relName;
            end;
            //todo set aroot.catalog/schema from rel
            {Now we can set the column sourceRange's (i.e. aliases)}
            for i:=0 to aroot.rel.fTuple.ColCount-1 do
              aroot.rel.fTuple.fColDef[i].sourceRange:=aroot;
          end;
        end
        else
        begin
          case tempResult of
            -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
            -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
          else
            st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
          end; {case}
          result:=-3; //could not find base_table or view //todo use local constant
          exit; //abort
        end;
      finally
        {if not linked to antRelation as base_table then delete the temporary relation - only used for View preview}
        if not((aroot<>nil) and (aroot.rel=r)) then  //todo convert to more readable expression!
          r.free;
      end; {try}

      result:=ok;
    end; {ntTable}

    ntTableExp:
    begin
      id:='sysTableExpRange'; //todo make system numbered? or fatal error if missing?
      result:=CreateTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      if n.rightChild<>nil then
      begin
        //todo check that this is the range name (cos column list is attached!)
        aroot.rangeName:=n.rightChild.idVal; //explicit range name
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('  ... as %s',[n.rightChild.idVal]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {If the right child has a nextNode then this is the list of column aliases
         so we pass a reference to it to the algebra node for use after the relations are opened
         during the iterator initialisation - could be a number of iterators- todo check they all handle this ref.
        }
        aroot.exprNodeRef:=n.rightChild.nextNode; //link to optional column aliases
      end
      else
      begin
        aroot.catalogName:=aroot.rel.catalogName;
        aroot.schemaName:=aroot.rel.schemaName;
        aroot.tableName:=aroot.rel.relName;
      end;
      //todo set aroot.catalog/schema - already done by createTableExp?
      {We have no relation directly connected to this anode, so we must defer setting
       the column sourceRange's (i.e. aliases) e.g. until the IterProject is created
       (the CreateTableExp will either return a antProject->IterProject or
        a antRelation which has already been aliased)}
    end; {ntTableExp}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('TableRef left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateTableRef}

function CreateNonJoinTableExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a NonJoinTableExp
 IN:
           tr      transaction
           sroot   pointer to ntNonJoinTableExp syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createNonJoinTableExp';
var
  n,next,ref:TSyntaxNodePtr;

  haveAll:boolean;
  raTemp:TAlgebraNodePtr;
  joinNodeType:AlgebraNodeType;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntNonJoinTableExp then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntNonJoinTableExp',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntNonJoinTableTerm:
    begin
      result:=CreateNonJoinTableTerm(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTableTerm}

    ntUnionExcept:
    begin
      result:=CreateTableExp(st,n.leftChild.leftChild,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;

      joinNodeType:=antUnion; //default
      haveAll:=False;
      ref:=nil; //default syntax node reference (used by union/except startup code)
      next:=n.leftChild.nextNode;
      while next<>nil do
      begin
        case next.nType of
          ntUnion:           joinNodeType:=antUnion; //no real need - default
          ntExcept:          joinNodeType:=antExcept;
          ntCorrespondingBy: ref:=next; //left child is a column comma list
          ntCorresponding:   ref:=next;
          ntAll:             haveAll:=True;
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('ntUnionExcept modifier option not handled (%d), continuing...',[ord(next.nType)]),vDebugError);
          {$ENDIF}
        end; {case}
        {Move to next in chain}
        next:=next.nextNode;
      end;
      {Convert ALL nodes}
      if haveAll then
        case joinNodeType of
          antUnion:  joinNodeType:=antUnionAll;
          antExcept: joinNodeType:=antExceptAll;
        end; {case}
      aroot:=mkANode(joinNodeType,nil,nil,raTemp,nil);
      aroot.nodeRef:=ref; //link to syntax node ref (if one has been specified above)
      result:=CreateTableTerm(st,n.leftChild.rightChild,raTemp);
      linkARightChild(aroot,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Union/Except...',vDebugMedium);
      {$ENDIF}
      result:=ok;
    end; {ntUnionExcept}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntNonJoinTableExp left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateNonJoinTableExp}

function CreateNonJoinTableTerm(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a NonJoinTableTerm
 IN:       
           tr      transaction
           sroot   pointer to ntNonJoinTableTerm syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createNonJoinTableTerm';
var
  n,next,ref:TSyntaxNodePtr;

  haveAll:boolean;
  raTemp:TAlgebraNodePtr;
  joinNodeType:AlgebraNodeType;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntNonJoinTableTerm then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntNonJoinTableTerm',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntNonJoinTablePrimary:
    begin
      result:=CreateNonJoinTablePrimary(st,n,False,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTablePrimary}

    ntIntersect:
    begin
      //Note: this code was copied from ntUnionExcept but changed children table types
      result:=CreateTableTerm(st,n.leftChild.leftChild,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;

      joinNodeType:=antIntersect; //default
      haveAll:=False;
      ref:=nil; //default syntax node reference (used by intersect startup code)
      next:=n.leftChild.nextNode;
      while next<>nil do
      begin
        case next.nType of
          ntIntersect:       joinNodeType:=antIntersect; //no real need - default: will never happen? kw
          ntCorrespondingBy: ref:=next; //left child is a column comma list
          ntCorresponding:   ref:=next;
          ntAll:             haveAll:=True;
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('ntIntersect modifier option not handled (%d), continuing...',[ord(next.nType)]),vDebugError);
          {$ENDIF}
        end; {case}
        {Move to next in chain}
        next:=next.nextNode;
      end;
      {Convert ALL nodes}
      if haveAll then
        case joinNodeType of
          antIntersect:  joinNodeType:=antIntersectAll;
        end; {case}
      aroot:=mkANode(joinNodeType,nil,nil,raTemp,nil);
      aroot.nodeRef:=ref; //link to syntax node ref (if one has been specified above)
      result:=CreateTablePrimary(st,n.leftChild.rightChild,raTemp);
      linkARightChild(aroot,raTemp);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Intersect...',vDebugMedium);
      {$ENDIF}
      result:=ok;
    end; {ntIntersect}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntNonJoinTableTerm left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateNonJoinTableTerm}

function CreateTableTerm(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a TableTerm
 IN:
           tr      transaction
           sroot   pointer to ntTableTerm syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createTableTerm';
var
  n:TSyntaxNodePtr;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntTableTerm then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntTableTerm',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntJoinTableExp:
    begin
      result:=CreateJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntJoinTableExp}

    ntNonJoinTableTerm:
    begin
      result:=CreateNonJoinTableTerm(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTableTerm}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntTableTerm left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateTableTerm}

function CreateTablePrimary(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a TablePrimary
 IN:
           tr      transaction
           sroot   pointer to ntTablePrimary syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createTablePrimary';
var
  n:TSyntaxNodePtr;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntTablePrimary then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntTablePrimary',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntJoinTableExp:
    begin
      result:=CreateJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntJoinTableExp}

    ntNonJoinTablePrimary:
    begin
      result:=CreateNonJoinTablePrimary(st,n,False,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTablePrimary}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntTablePrimary left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateTablePrimary}

function CreateNonJoinTablePrimary(st:Tstmt;sparent:TSyntaxNodePtr;useRightChild:boolean;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a NonJoinTablePrimary
 IN:
           tr      transaction
           st      statement
           sparent pointer to parent of ntNonJoinTablePrimary syntax node (may be pointed to new sub-tree)
           useRightChild      use right child of parent as ntNonJoinTablePrimary, else use leftChild
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createNonJoinTablePrimary';
var
  i:ColRef;
  n:TSyntaxNodePtr;
  sroot,n2,n3,newN:TSyntaxNodePtr;

  id:string;

  r:TRelation;
  isView:boolean;
  viewDefinition:string;
  tempResult:integer;
begin
  result:=Fail;
  aroot:=nil;

  if useRightChild then
    sroot:=sparent.rightChild
  else
    sroot:=sparent.leftChild;

  //todo assert sroot<>nil!

  if sroot.ntype<>ntNonJoinTablePrimary then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntNonJoinTablePrimary',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  n:=sroot;
  case n.leftChild.ntype of
    ntNonJoinTableExp:
    begin
      result:=CreateNonJoinTableExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntNonJoinTableExp}

    ntSelect:
    begin
      {Build algebra tree for select expression
       This will call CreateTableRef and may be recursive}
      result:=CreateSelectExp(st,n.leftChild,aroot);
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
    end; {ntSelect}

    ntTable:
    begin
      id:=n.leftChild.rightChild.idVal;
      {Check whether we're dealing with a view or base_table}
      r:=TRelation.create;
      try
        {Try to open this relation so we can check the type & its column refs}
        tempResult:=r.open(st,n.leftChild.leftChild,'',id,isView,viewDefinition);
        if tempResult=ok then
        begin
          if isView then
          begin //view
            {Build a syntax sub tree from the viewDefinition}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('expanding ntNonJoinTablePrimary into view (%s)',[id]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            result:=ParseSubSQL(st,viewDefinition,newN);
            if result<>ok then exit; //abort

            //todo assert newN.ntype=ntCreateView
            //todo assert view name=id? - no point since we opened the view with the id!

            //todo expand any select * to use original columns

            {Modify the syntax tree to include a table alias
             and optional column aliases according to the view definition
             i.e. we wrap the view definition's table_exp in a table_ref}

            //todo: check we're ok to introduce a table_ref node here, when the parent is a ntNonJoinTablePrimary
            // - I don't think it's allowed by the grammar...so maybe it will break the caller?
            // or allow an illegal plan to slip through via the use of a view
            //Actually, maybe this can only be a base-table here since the keyword before it
            // is TABLE. If so, remove all this crap & pass sroot instead of sparent & remove errorResults etc.!
            //************************ check grammar ********
            //- we'll continue as if it's ok for a view to be used here...

            {Build artifical AS node to alias as per the view}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('building aliased wrapper node of table_ref for view''s table_exp (%s)',[id]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            n2:=mkLeaf(st.srootAlloc,ntId,uGlobal.ctUnknown,0,0);
            n2.nullVal:=false;
            n2.idVal:=id; //add explicit view range name

            {Link any view column alias list to the wrapper}
            if newN.rightChild.nextNode<>nil then
            begin
              chainNext(n2,newN.rightChild.nextNode);
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('linked column alias list to wrapper node (%p)',[n2.nextNode]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
            end;

            {The view cannot be aliased here}

            {Now we can build the wrapper and insert it between the ntCreateView and its ntTableExp sub-tree}
            n3:=mkNode(st.srootAlloc,ntTableRef,uGlobal.ctUnknown,newN.rightChild,n2);

            newN:=n3; //point to the root of the new sub-tree

            {Now replace the current syntax sub-tree with the new tableRef around the new expanded one}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('deleting existing ntTableRef sub-tree (%p)',[sroot]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {Note: by unlinking and then re-linking we generate a few syntax tree warnings
             (because we create an orphaned tree) but they can be ignored.
             - really, we've no need to unlink the about-to-be-zapped sub-tree, and we could just
             link in the new tree, but this overwrites the existing child pointer - and that's not as clean
             as first setting the child pointer to nil via unlink.
             This shouldn't be a problem anywhere else since syntax trees are built once (grown) and not chopped about...
            }
            if useRightChild then unlinkRightChild(sparent) else unlinkLeftChild(sparent);
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('pointing to new expanded sub-tree (%p)',[newN]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            sroot:=newN;
            {swap in the new sub-tree root - the caller now takes on responsibility for freeing it}
            if useRightChild then linkRightChild(sparent,sroot) else linkLeftChild(sparent,sroot); //increases reference count to sub-tree...

            {$IFDEF DEBUG_LOG}
            log.quick('expanded sub-tree:');
            {$ELSE}
            ;
            {$ENDIF}
            DisplaySyntaxTree(sroot); //debug before

            {Now create and return the sub-plan - recursive call}
            {Note: we pass the same parent & useRightChild that we were passed, since we've just expanded the parent's child and we're now evaluating it}
            result:=CreateTableRef(st,sparent,useRightChild,aroot);

            //todo: we should check that any view defined (especially as select *) is still
            //      returning the same column names - need to check now while we have the view relation open...
            //      (i.e. to trap when underlying table(s) is modified, e.g. drop column!)

            {$IFDEF DEBUG_LOG}
            log.quick('expanded algebra:');
            {$ELSE}
            ;
            {$ENDIF}
            DisplayAlgebraTree(aroot);

            {Note: we only prescribe the algebra here - and so we leave the optimiser
             to (cleverly!) merge this with any above/below it to create the iterator
             execution plan}

            //todo check/prove! falling through to next case doesn't look at new sroot value - although might be quicker?
          end
          else
          begin //base table
            {Now create the node in the algebra tree}
            aroot:=mkANode(antRelation,n,nil{may be set below},nil,nil);
            {Link the opened relation - we leave it open for the execution plan to use}
            aroot.rel:=r;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('  Added base table node %s',[id]),vDebug);
            {$ENDIF}
            {$ENDIF}
            {The table cannot be aliased here}
            aroot.catalogName:=aroot.rel.catalogName;
            aroot.schemaName:=aroot.rel.schemaName;
            aroot.tableName:=aroot.rel.relName;
            //todo set aroot.catalog/schema from rel
            {Now we can set the column sourceRange's (i.e. aliases)}
            for i:=0 to aroot.rel.fTuple.ColCount-1 do
              aroot.rel.fTuple.fColDef[i].sourceRange:=aroot;
          end;
        end
        else
        begin
          case tempResult of
            -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
            -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
          else
            st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
          end; {case}
          result:=-3; //could not find base_table or view
          exit; //abort
        end;
      finally
        {if not linked to antRelation as base_table then delete the temporary relation - only used for View preview}
        if not((aroot<>nil) and (aroot.rel=r)) then  //todo convert to more readable expression!
          r.free;
      end; {try}
      
      result:=ok;
    end; {ntTable}

    ntTableConstructor:
    begin
      id:='sys/TC'; //todo assign unique internal id (any use?)
      {Now create the node in the algebra tree}
      aroot:=mkANode(antSyntaxRelation,n.leftChild,nil,nil,nil);
      aroot.rangeName:=id; //todo remove, no use?
      //todo set aroot.catalog/schema? - default to current? n/a?

      {Note: We defer setting the column sourceRange's (i.e. aliases) until we pre-plan the syntax relation}

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('  Added syntax table node %s',[id]),vDebug);
      {$ENDIF}
      result:=ok;
    end; {ntTableConstructor}

  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('ntNonJoinTablePrimary left child not handled (%d)',[ord(n.leftChild.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end; {case}
end; {CreateNonJoinTablePrimary}

function CreateSelectExp(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a TableExp
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntTableExp syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail

 Note:
   the syntax tree can be modified during this routine, e.g.
       add a branch to a new AS node for simple columns in the Select list
}
const routine=':createSelectExp';
var
  n,n2,nInto:TSyntaxNodePtr;

  raHead,raNode,raTemp:TAlgebraNodePtr;

  haveGroup:boolean;
  haveDistinct:boolean;
  haveInto:boolean;
  raHavingGroup:TAlgebraNodePtr;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntSelect then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntSelectExp',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  haveGroup:=False;       //have we processed an explicit group-by?
  haveDistinct:=False;    //have we seen a distinct option?
  haveInto:=False;        //have we seen an Into option?
  nInto:=nil;
  raHavingGroup:=nil;     //link back to group-by node so we can add Having expression afterwards

  {We build an algebra tree roughly as follows:

                                  [antSort(duplicate removal)]

                             antProject | [system group-by for aggregates] | [antGroupBy]

                   [antSelect]

              [antJoin]
                       table-ref
      table-ref

      etc.
  }

  {Loop through table sub-tree (multi-table Join) and build and open a list of relations}
  {Note: this was stored as a chain of tableRefs but we re-structured it into a long spindly tree
   to share the same parent-child tree juggling routines used to expand views.
  }
  n:=sroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'Joining...',vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  n:=n.rightChild;
  raHead:=nil;
  //todo trap if n=nil => missing From clause
  repeat
    case n.ntype of
      ntCrossJoin: //todo replace with 'special purpose' dummy glue node
      //todo right child=TableRef:   //could produce recursive calls, e.g. select * from (select * from X)
      begin
        if raHead=nil then
        begin
          result:=CreateTableRef(st,n,True,raNode); //should really use mkALeaf - no matter?
          if result<>ok then
          begin
            //todo error message needed?
            exit;
          end;
          raHead:=raNode; //new head
        end
        else
        begin
          {Others are new levels with a new right leaf = inner relation}
          raNode:=mkANode(antInnerJoin,nil,nil,raHead,nil);
          raHead:=raNode; //new head
          {link this new relation to the right child
                  raHead
              (left)    <nil>

                  raHead
              (left)    newRelation pointer
          }
          result:=CreateTableRef(st,n,True,raNode);
          linkARightChild(raHead,raNode);
          if result<>ok then
          begin
            //todo error message needed?
            aroot:=raHead; //return node for cleanup
            exit;
          end;
          raTemp:=raNode; //todo remove!
        end;
      end; {ntTableRef}
    end; {case}
    n:=n.leftChild;
  until n=nil;

  {Loop through clause tree chain (Where etc.)}
  {todo
    need to distinguish between conditions that join two different tables
    and those that don't - can they always be split?
    e.g. from a,b where a.id=b.id and b.tot<100 and a.ord>b.ord
    => syntax tree
                                        AND
                          AND                    >
                   =              <         a.ord b.ord
              a.bid  b.bid   b.tot 100

    => algebra tree
               Join list                 Selection List
               ?
  }
  n:=sroot;
  n:=n.nextNode;
  while n<>nil do
  begin
    case n.ntype of
      ntWhere:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Where...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {Re-arrange the syntax subtree (n.leftChild) to CNF
         which will be a chain of sub-trees (implicitly ANDed and separable)}
        DisplaySyntaxTree(n.leftChild); //debug before
        result:=CondToCNF(st.srootAlloc,n.leftchild);
        DisplaySyntaxTree(n.leftChild); //debug after (multiple sub-trees)
        n2:=n.leftChild.nextNode;
        while n2<>nil do
        begin
          DisplaySyntaxTree(n2); //debug after
          n2:=n2.nextNode;
        end;
        if result<>ok then
          exit;  //abort - //todo assume lower level gives error... ok?

        {Add the new selection node & point to the syntax tree}
        raNode:=mkANode(antSelection,n.leftChild,nil,raHead,nil);
        raHead:=raNode; //new head
        {link this new selection to the join tree
                      raHead(selection)

            old-raHead(join)    <nil>
        }
        aroot:=raHead; //return node for cleanup in case of error
        {This next section tries a mini-traversal of the sub-tree purely
         for parser-debugging purposes. It can be removed. All we really
         need to do here is link this portion of the syntax tree to the
         algebra tree with a new Selection node}
        if n.leftChild<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  %d',[ord(n.leftChild.ntype)]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
      end; {where}
      ntGroupBy:
      begin
        //todo need to ensure we have Sort node (somewhere/anywhere?) beneath - always! & with at least these columns
        //e.g. group(a,b,c) => order(a,b,c...)
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Group By...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        haveGroup:=True;
        {Add an implied sort node and point to the column list header in the syntax tree} //Note: optimiser can remove if already sorted
        raNode:=mkANode(antSort,n.leftChild,nil,raHead,nil);
        //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
        raHead:=raNode; //new head
        {Add the new group by node and point to the column list header in the syntax tree}
        raNode:=mkANode(antGroup,n.leftChild,nil{Note: set later by having expr},raHead,nil);
        //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
        raHavingGroup:=raNode; //remember this so we can set exprNodeRef if/when we get Having clause
        raHead:=raNode; //new head
        {link this new group to the selection/join tree
                      raHead(group)

                 old-raHead(sort)

            old-raHead(selection or join)    <nil>
        }
        aroot:=raHead; //return node for cleanup in case of error
        {This next section tries a mini-traversal of the sub-tree purely
         for parser-debugging purposes. It can be removed. All we really
         need to do here is link this portion of the syntax tree to the
         algebra tree with a new Group node}
        if n.leftChild<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  %d',[ord(n.leftChild.ntype)]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
      end; {group by}
      ntHaving:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Having...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {Re-arrange the syntax subtree (n.leftChild) to CNF
         which will be a chain of sub-trees (implicitly ANDed and separable)}
        DisplaySyntaxTree(n.leftChild); //debug before
        result:=CondToCNF(st.srootAlloc,n.leftchild);
        DisplaySyntaxTree(n.leftChild); //debug after (multiple sub-trees)
        n2:=n.leftChild.nextNode;
        while n2<>nil do
        begin
          DisplaySyntaxTree(n2); //debug after
          n2:=n2.nextNode;
        end;
        if result<>ok then
          exit;  //abort - //todo assume lower level gives error... ok?

        if raHavingGroup=nil then
        begin
          {no group by, we must create an artifical one... (no need for pre-sort)}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'System Group By...',vDebug);
          {$ELSE}
          ;
          {$ENDIF}
          haveGroup:=True;
          {Add the new group by node and point to nil - we have no column list => 1 supergroup}
          raNode:=mkANode(antGroup,nil,n.leftChild,raHead,nil);
          //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
          raHavingGroup:=raNode; //remember this in case we ever need to check if we had a having clause later - todo remove? no need
          raHead:=raNode; //new head
          aroot:=raHead; //return node for cleanup in case of error
        end
        else
        begin
          {we already have a group-by, point it to this expression}
          raHavingGroup.exprNodeRef:=n.leftChild;
        end;
      end; {having}
      ntInto: //only applies to single-row selects i.e. not sub-selects
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Into...',vDebug);
        {$ENDIF}

        nInto:=n;
        haveInto:=True;
      end; {into}

      {These next two don't really belong here, but it's the neatest place to attach them for now}
      ntDistinct:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Distinct...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        haveDistinct:=True;
      end; {all/distinct}
      ntAll:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'All...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        haveDistinct:=False; //default anyway, so no need to trap
      end; {all/distinct}
    else //todo: make into assertion - should never happen
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unknown clause syntax node in Select: %d',[ord(n.ntype)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
    end; {case}
    n:=n.nextNode; //move to next clause
  end; {while}

  {Loop through select item list and process/check each sub-tree}
  n:=sroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'Projecting...',vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  {Traverse syntax tree}
  n:=n.leftChild;
  repeat
    case n.ntype of
      ntSelectAll:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('   *',[nil]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
      end;
      ntSelectItem:
      begin
        if hasAggregate(n) then
        begin
          n.aggregate:=True; //todo remove this - we use Complete...(agStart) to do this for us...?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('   <aggregate sub-tree>',[nil]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
          if not haveGroup then
          begin
            {We have aggregates but no group to calculate them in,
             so we create a dummy one (no need for pre-sort)}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'System Group By...',vDebug);
            {$ELSE}
            ;
            {$ENDIF}
            haveGroup:=True;
            {Add the new group by node and point to nil - we have no column list => 1 supergroup}
            raNode:=mkANode(antGroup,nil,nil,raHead,nil);
            //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
            raHead:=raNode; //new head
            {link this new group to the selection/join tree
                          raHead(group)

                old-raHead(selection or join)    <nil>
            }
            aroot:=raHead; //return node for cleanup in case of error
          end;
        end;
        {Note: each columnRef has a link to its sourceRange so we can use
         findCol to find its definition, even after joins and projection etc.
        }
      end;
    //todo: else warning?
    end; {case}
    n:=n.nextNode; //move to next select item in list
  until n=nil;
  n:=sroot;


  {Add the new projection node & point to the syntax tree}
  raNode:=mkANode(antProjection,n.leftChild,nil,raHead,nil);
  raHead:=raNode; //new head
  {link this new projection to the selection tree (or maybe the join tree, if
   no selection is present) or maybe the group tree
                  raHead(projection)

      old-raHead(selection)    <nil>
  }

  {Add the distinct duplicate removal at the top of the tree}
  if haveDistinct then
  begin
    {Insert a sort node to remove duplicates} //note: nil => duplicate removal (for now - todo make better)
    raNode:=mkANode(antSort,nil,nil,raHead,nil);
    //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
    raHead:=raNode; //new head
    {link this new group to the projection tree
                  raHead(sort-distinct)

        old-raHead(projection)    <nil>
    }
  end;

  {Add any Into sink at the top of the tree}
  if haveInto then
  begin
    {Add the new into node}
    raNode:=mkANode(antInto,nInto.leftChild,nil,raHead,nil);
    //debug? raNode.rangeName:=raHead.rangeName; //pull up any alias: 29/03/01 debug fix alias view problem?
    raHead:=raNode; //new head
  end;

  {Return the algebra tree}
  aroot:=raHead;
  result:=ok;
end; {CreateSelectExp}

function CreateDelete(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for a Delete
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntDelete syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createDelete';
var
  n,n2:TSyntaxNodePtr;

  raHead,raNode:TAlgebraNodePtr;
  id:string;
  i:colRef;

  isView:boolean;
  viewDefinition:string;
  tempResult:integer;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntDelete then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntDelete',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  {Initialise the source table-exp}
  n:=sroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'Deleting...',vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  raHead:=nil;

  {Syntax:
                               ntDelete
                  table_OPT_as           [ntWhere]
                                     cond_exp
  }

  {Before we add any where selection node, we must artifically add the table relation node
   Needed even if no where clause is specified to drive the IterDelete.next routine}
  id:=sroot.leftChild.leftChild.rightChild.idVal; //todo assumes=check!
  {Now create the node in the algebra tree}
  //todo use MkALeaf & can link rel
  raNode:=mkANode(antRelation,sroot.leftChild.leftChild,nil,nil,nil);
  raHead:=raNode; //new head
  aroot:=raHead; //return node for cleanup in case of error

  {Create new linked relation and open it}
  raNode.rel:=TRelation.create;
{$IFDEF DEBUG_LOG}
//  log.add(st.who,where+routine,format('  Added base table node %s',[id]),vDebug);
{$ELSE}
;
{$ENDIF}
{$IFDEF DEBUG_LOG}
//  log.add(st.who,where+routine,format('  antRelation.rel=%d',[longint(raNode.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
  if sroot.leftChild.rightChild<>nil then
  begin
    raNode.rangeName:=n.leftChild.rightChild.idVal; //explicit range name
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('  ... as %s',[n.leftChild.rightChild.idVal]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
  end;
  //todo set aroot.catalog/schema from rel, after opened below!
  
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('range named %s',[raNode.rangeName]),vDebug);
  {$ENDIF}
  {Try to open this relation so we can check the column refs}
  tempResult:=raNode.rel.open(st,sroot.leftChild.leftChild.leftChild,'',id,isView,viewDefinition);
  if tempResult=ok then
  begin
    if raNode.rangeName='' then
    begin //not aliased
      raNode.catalogName:=raNode.rel.catalogName;
      raNode.schemaName:=raNode.rel.schemaName;
      raNode.tableName:=raNode.rel.relName;
    end;

    {Now we can set the column sourceRange's (i.e. aliases)}
    for i:=0 to raNode.rel.fTuple.ColCount-1 do
      raNode.rel.fTuple.fColDef[i].sourceRange:=raNode;

    //todo check that if isView, that we can delete from it!
  end
  else
  begin
    case tempResult of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    else
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
    end; {case}
    result:=-3; //could not find relation
    exit; //abort
  end;


  n:=n.rightChild;

  if n<>nil then
    case n.nType of
      ntWhere:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Where...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {Re-arrange the syntax subtree (n.leftChild) to CNF
         which will be a chain of sub-trees (implicitly ANDed and separable)}
        DisplaySyntaxTree(n.leftChild); //debug before
        result:=CondToCNF(st.srootAlloc,n.leftchild);
        DisplaySyntaxTree(n.leftChild); //debug after (multiple sub-trees)
        n2:=n.leftChild.nextNode;
        while n2<>nil do
        begin
          DisplaySyntaxTree(n2); //debug after
          n2:=n2.nextNode;
        end;
        if result<>ok then
          exit;  //abort - //todo assume lower level gives error... ok?

        {Add the new selection node & point to the syntax tree}
        raNode:=mkANode(antSelection,n.leftChild,nil,raHead,nil);
//        raNode.rel:=raHead.rel; //bug fix (leftChild in delete needs access to its relation owner)
//                                // - duplicate link - no matter? - todo check! maybe null old rel link?
{$IFDEF DEBUG_LOG}
//       log.add(st.who,where+routine,format('  antSelection.rel=%d',[longint(raNode.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
{$IFDEF DEBUG_LOG}
//       log.add(st.who,where+routine,format('linked select to relation %s',[raNode.rel.relname]),vDebug);
{$ELSE}
;
{$ENDIF}
        raHead:=raNode; //new head
        {link this new selection to the join tree
                      raHead(selection)

           old-raHead(Relation)    <nil>
        }
        aroot:=raHead; //return node for cleanup in case of error
        {This next section tries a mini-traversal of the sub-tree purely
         for parser-debugging purposes. It can be removed. All we really
         need to do here is link this portion of the syntax tree to the
         algebra tree with a new Selection node}
        if n.leftChild<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  %d',[ord(n.leftChild.ntype)]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
      end; {where}
    //todo else sys error
    end; {case}

  raNode:=mkANode(antDeletion,sroot,nil,raHead,nil);
  raHead:=raNode; //new head
  aroot:=raHead; //return node for cleanup in case of error
  {Create new linked relation and open it}
  //Note: could we share the one just created for the where clause? May not have a where clause
  // - so instead, create relation here & link it back to any where clause? todo: check race conditions...
  //                                                                        e.g. delete from X where X.c>5
  raHead.rel:=TRelation.create;
{$IFDEF DEBUG_LOG}
//  log.add(st.who,where+routine,format('  antdelete.rel=%d',[longint(raHead.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
  n:=sroot.leftChild.leftChild; //todo assert if fail!
  if n.rightChild<>nil then
  begin
    id:=n.rightChild.idVal; //table name //todo take account of schema!

    //todo add any specified catalog/schema prefix!
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Missing table name',vError);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('  Added delete table node %s',[id]),vDebug);
  {$ENDIF}
  {Try to open this relation so we can check the column refs}
  tempResult:=raHead.rel.open(st,n.leftChild,'',id,isView,viewDefinition);
  if tempResult=ok then
  begin
    //todo check that if isView, that we can delete from it!

  end
  else
  begin
    case tempResult of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));

    else
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
    end; {case}
    result:=-3; //could not find table
    exit; //abort
  end;

  {Return the algebra tree}
  aroot:=raHead;
  result:=ok;
end; {CreateDelete}

function CreateUpdate(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for an Update
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntUpdate syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createUpdate';
var
  n,n2:TSyntaxNodePtr;

  raHead,raNode:TAlgebraNodePtr;
  id:string;
  i:colRef;

  isView:boolean;
  viewDefinition:string;
  tempResult:integer;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntUpdate then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntUpdate',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  {Initialise the source table-exp}
  n:=sroot;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'Updating...',vDebug);
  {$ELSE}
  ;
  {$ENDIF}

  raHead:=nil;

  {Syntax:
                               ntUpdate                -> ntupdate_assignment (list)
                  table_OPT_as           [ntWhere]
                                   cond_exp
  }

  {Before we add any where selection node, we must artifically add the table relation node
   Needed even if no where clause is specified to drive the IterUpdate.next routine}
  id:=sroot.leftChild.leftChild.rightChild.idVal; //todo assumes=check!
  {Now create the node in the algebra tree}
  //todo use MkALeaf & can link rel
  raNode:=mkANode(antRelation,sroot.leftChild.leftChild,nil,nil,nil);
  raHead:=raNode; //new head
  aroot:=raHead; //return node for cleanup in case of error

  {Create new linked relation and open it}
  raNode.rel:=TRelation.create;
{$IFDEF DEBUG_LOG}
//  log.add(st.who,where+routine,format('  Added base table node %s',[id]),vDebug);
{$ELSE}
;
{$ENDIF}
{$IFDEF DEBUG_LOG}

//  log.add(st.who,where+routine,format('  antRelation.rel=%d',[longint(raNode.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
  if sroot.leftChild.rightChild<>nil then
  begin
    raNode.rangeName:=n.leftChild.rightChild.idVal; //explicit range name
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('  ... as %s',[n.leftChild.rightChild.idVal]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
  end;
  //todo set aroot.catalog/schema from rel after opened below!

  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('range named %s',[raNode.rangeName]),vDebug);
  {$ENDIF}
  {Try to open this relation so we can check the column refs}
  tempResult:=raNode.rel.open(st,sroot.leftChild.leftChild.leftChild,'',id,isView,viewDefinition);
  if tempResult=ok then
  begin
    if raNode.rangeName='' then
    begin //not aliased
      raNode.catalogName:=raNode.rel.catalogName;
      raNode.schemaName:=raNode.rel.schemaName;
      raNode.tableName:=raNode.rel.relName;
    end;
    
    {Now we can set the column sourceRange's (i.e. aliases)}
    for i:=0 to raNode.rel.fTuple.ColCount-1 do
      raNode.rel.fTuple.fColDef[i].sourceRange:=raNode;

    //todo check that if isView, that we can update it!

  end
  else
  begin
    case tempResult of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    else
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
    end; {case}
    result:=-3; //could not find relation
    exit; //abort
  end;


  //note: (also for Delete) may be quicker to combine Select within IterUpdate next routine...?

  n:=n.rightChild;

  if n<>nil then
    case n.nType of
      ntWhere:
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,'Where...',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {Re-arrange the syntax subtree (n.leftChild) to CNF
         which will be a chain of sub-trees (implicitly ANDed and separable)}
        DisplaySyntaxTree(n.leftChild); //debug before
        result:=CondToCNF(st.srootAlloc,n.leftchild);
        DisplaySyntaxTree(n.leftChild); //debug after (multiple sub-trees)
        n2:=n.leftChild.nextNode;
        while n2<>nil do
        begin
          DisplaySyntaxTree(n2); //debug after
          n2:=n2.nextNode;
        end;
        if result<>ok then
          exit;  //abort - //todo assume lower level gives error... ok?

        {Add the new selection node & point to the syntax tree}
        raNode:=mkANode(antSelection,n.leftChild,nil,raHead,nil);
//        raNode.rel:=raHead.rel; //bug fix (leftChild in delete needs access to its relation owner)
//                                // - duplicate link - no matter? - todo check! maybe null old rel link?
{$IFDEF DEBUG_LOG}
//       log.add(st.who,where+routine,format('  antSelection.rel=%d',[longint(raNode.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
{$IFDEF DEBUG_LOG}
//       log.add(st.who,where+routine,format('linked select to relation %s',[raNode.rel.relname]),vDebug);
{$ELSE}
;
{$ENDIF}
        raHead:=raNode; //new head
        {link this new selection to the join tree
                      raHead(selection)

           old-raHead(Relation)    <nil>
        }
        aroot:=raHead; //return node for cleanup in case of error
        {This next section tries a mini-traversal of the sub-tree purely
         for parser-debugging purposes. It can be removed. All we really
         need to do here is link this portion of the syntax tree to the
         algebra tree with a new Selection node}
        if n.leftChild<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  %d',[ord(n.leftChild.ntype)]),vDebug);
          {$ELSE}
          ;
          {$ENDIF}
      end; {where}
    //todo else sys error
    end; {case}

  raNode:=mkANode(antUpdate,sroot,sroot.nextNode,raHead,nil);
  raHead:=raNode; //new head
  aroot:=raHead; //return node for cleanup in case of error
  {Create new linked relation and open it}
  //Note: todo: could we share the one just created for the where clause? May not have a where clause
  // - so instead, create relation here & link it back to any where clause? todo: check race conditions...
  //                                                                        e.g. update X set c=c+1 where X.c>5
  raHead.rel:=TRelation.create;
{$IFDEF DEBUG_LOG}
//  log.add(st.who,where+routine,format('  antupdate.rel=%d',[longint(raHead.rel)]),vDebug);
{$ELSE}
;
{$ENDIF}
  n:=sroot.leftChild.leftChild; //todo assert if fail!
  if n.rightChild<>nil then
  begin
    id:=n.rightChild.idVal; //table name //todo take account of schema!
    //todo add any specified catalog/schema prefix!
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Missing table name',vError);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('  Added update table node %s',[id]),vDebug);
  {$ENDIF}
  {Try to open this relation so we can check the column refs}
  tempResult:=raHead.rel.open(st,n.leftChild,'',id,isView,viewDefinition);
  if tempResult=ok then
  begin
    //todo check that if isView, that we can update it!

  end
  else
  begin
    case tempResult of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    else
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
    end; {case}
    result:=-3; //could not find table
    exit; //abort
  end;

  {Return the algebra tree}
  aroot:=raHead;
  result:=ok;
end; {CreateUpdate}


function CreateInsert(st:Tstmt;sroot:TSyntaxNodePtr;var aroot:TAlgebraNodePtr):integer;
{Converts a syntax tree into an algebra tree for an Insert
 IN:
           tr      transaction
           st      statement
           sroot   pointer to ntInsert syntax node
 OUT:      aroot   pointer to algebra root node
                   Note: the algebra nodes & supporting nodes are not cleaned-up here!

 RETURNS:  Ok, else Fail
}
const routine=':createInsert';
var
  n:TSyntaxNodePtr;

  raHead,raNode:TAlgebraNodePtr;
  id:string;

  isView:boolean;
  viewDefinition:string;
  tempResult:integer;
begin
  result:=Fail;
  aroot:=nil;

  if sroot.ntype<>ntInsert then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Root is not ntInsert',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;

  {Initialise the source table-exp}
  n:=sroot;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'Inserting...',vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  raHead:=nil;

  {Syntax:
                               ntInsert
                         table           ntInsertValues  |  ntDefaultValues
                                     column-list   tableExp
  }

  n:=n.rightChild;

  case n.nType of
    ntInsertValues:
    begin
      id:='sysTableExpRange'; //todo make system numbered? no need - remove?
      result:=CreateTableExp(st,n.rightChild,raNode);
      raHead:=raNode; //new head
      if result<>ok then
      begin
        //todo error message?
        exit;
      end;
      raHead.rangeName:=id; //internal implicit range name - todo remove it, no need?
      //todo set aroot.catalog/schema? - already done by createTablExp?
      {We have no relation directly connected to this anode, so we must defer setting
       the column sourceRange's (i.e. aliases) e.g. until the IterProject is created
       (the CreateTableExp will either return a antProject->IterProject or
        a antRelation which has already been aliased)}
    end; {ntInsertValues}
    ntDefaultValues:
    begin
      //no child here -> iterator should use defaults
    end;
  end; {case}

  raNode:=mkANode(antInsertion,sroot,nil,raHead,nil);
  raHead:=raNode; //new head
  aroot:=raHead; //return node for cleanup in case of error
  {Create new linked relation and open it}
  raHead.rel:=TRelation.create;
  n:=sroot.leftChild; //todo assert if fail!
  if n.rightChild<>nil then
  begin
    id:=n.rightChild.idVal; //table name //todo take account of schema!
    //todo add any specified catalog/schema prefix!
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Missing table name',vError);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('  Added insert table node %s',[id]),vDebug);
  {$ENDIF}
  {$ENDIF}
  {Try to open this relation so we can check the column refs}
  tempResult:=raHead.rel.open(st,n.leftChild,'',id,isView,viewDefinition);
  if tempResult=ok then
  begin
    //todo check that if isView, that we can insert into it!

  end
  else
  begin
    case tempResult of
      -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
      -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
    else
      st.addError(seSyntaxUnknownTable,format(seSyntaxUnknownTableText,[id]));
    end; {case}
    result:=-3; //could not find table
    exit; //abort
  end;

  {Return the algebra tree}
  aroot:=raHead;
  result:=ok;
end; {CreateInsert}

function CreateCallRoutine(st:Tstmt;nroot:TSyntaxNodePtr;subSt:TStmt;functionCall:boolean):integer;
{Creates a syntax tree for a subSt from the given call st
 IN:       tr      transaction
           st      call statement
           nroot   pointer to ntCallRoutine/ntUserFunction node
           subSt   statement to run the routine body
           functionCall True=allow function call, else expecting procedure call

 RETURNS:  Ok, else Fail

 Notes:
   also checks that we're privileged to execute this routine, else fails

   also defines and sets subSt parameters from the routine arguments/st parameters

   also sets the subSt.sroot.idVal to the routine name for later Return (to behave as Leave)
}
const routine=':CreateCallRoutine';
var
  i:ColRef;

  sroot,n,n2,n3,newN:TSyntaxNodePtr;

  r:TRoutine;
  routineType:string;
  routineDefinition:string;

  id:string;

  {for privilege check}
  grantabilityOption:string;
  authId_level_match:boolean;
  tempResult:integer;
begin
  result:=Fail;
  sroot:=nroot;

  //todo assert sroot<>nil!

  if not(sroot.ntype in [ntCallRoutine,ntUserFunction]) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Parent''s child is not ntCallRoutine/ntUserFunction',vAssertion);
    {$ENDIF}
    exit;
  end;

  n:=sroot;

      id:=n.leftChild.rightChild.idVal;
      {Load the routine definition} //todo in future search a routine cache
      //Note: this sub-section is copied in completeScalarExp
      r:=TRoutine.create;
      try
        {Try to open this routine so we can check the type & its parameter refs}
        tempResult:=r.open(st,n.leftChild.leftChild,'',id,routineType,routineDefinition);
        if tempResult=ok then
        begin
          if (not functionCall and (routineType=rtProcedure))
          or (functionCall and (routineType=rtFunction)) then
          begin //ok
            {Now we ensure we have privilege to Execute this function
              - this needs to be fast!
            }
            if CheckRoutinePrivilege(st,0{we don't care who grantor is},Ttransaction(st.owner).authId,{todo: are we always checking our own privilege here?}
                                     False{we don't care about role/authId grantee},authId_level_match,
                                     r.AuthId{=routine owner},
                                     r.routineId{=routine},
                                     ptExecute{todo always?},False{we don't want grant-option search},grantabilityOption)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed checking privilege %s on %d for %d',[PrivilegeString[ptSelect],r.routineId,Ttransaction(st.owner).AuthId]),vDebugError);
              {$ENDIF}
              st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[id+' privilege']));
              result:=Fail;
              exit;
            end;
            if grantabilityOption='' then //use constant for no-permission?
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Not privileged to %s on %d for %d',[PrivilegeString[ptExecute],r.routineId,Ttransaction(st.owner).AuthId]),vDebugLow);
              {$ENDIF}
              st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to execute '+id]));
              result:=Fail;
              exit;
            end;

            {Ok, we're privileged}
            {Build a syntax sub tree from the routineDefinition}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('expanding ntCallRoutine into routine (%s)',[id]),vDebugLow);
            {$ENDIF}
            //todo since subSt is blank we could use a standard parseSQL here
            result:=ParseSubSQL(st,routineDefinition+';',newN); //note: we add ; to keep parser happy: see sql_compound_element in yacc
            if result<>ok then exit; //abort

            //todo assert newN.ntype=ntCreateRoutine
            //todo assert routine name=id? - no point since we opened the routine with the id!
            {We double reference the routine body subtree from the root - so the caller now takes on responsibility for freeing it}
            subSt.sroot:=newN.rightChild.leftChild; //this will execute the routine body part of the tree (skipping the compound_element)
            subSt.sroot.idVal:=id; //this will allow a Return to leave all blocks until the function block
            linkLeftChild(newN.rightChild,newN.rightChild.leftChild); //increases reference count to sub-tree... //note: bad use of a side-effect!?
            {$IFDEF DEBUG_LOG}
            log.quick('expanded sub-tree:');
            {$ENDIF}
            DisplaySyntaxTree(subSt.sroot); //debug

            {Now setup the parameter definitions for this subSt}
            subSt.varSet.CopyVariableSetDef(r.fVariableSet);
          end
          else
          begin //unexpected routine type error here
            result:=-3; //found function instead of procedure or vice-versa //todo use a better error message!
            st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[id]));
            exit; //abort
          end;
        end
        else
        begin
          case tempResult of
            -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
            -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
          else
            st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[id]));
          end; {case}
          result:=-3; //could not find routine //todo use local constant
          exit; //abort
        end;
      finally
        {delete the temporary routine - only used for routine preview & variableSet definition}
        r.free;
      end; {try}

      result:=ok;
end; {CreateCallRoutine}



function RowSubquery(st:TStmt;planRoot:TIterator;tuple:TTuple):integer;
{Executes the (sub)query plan and retrieves the final tuple
 Fails if the plan returns >1 tuple

 Note: assumes iterator's tuple is still available after it has been stopped

 IN:      st              the statement (only needed to pass to tuple.clear)
          planRoot        the plan root of the subquery = iterator chain root
 OUT:     tuple           a formatted tuple with data in its read-buffer
                          Note: tuple must be created by caller

 Assumes:
   planRoot has already been prePlanned (to complete the syntax trees)

 //todo allow termination during next looping (e.g. owner sets a Cancel flag) - would need to pass Tr in somehow...

 //todo rename to EvalRowSubquery or ExecuteRowSubQuery?

 RESULT: ok or fail (in which case don't use the tuple result)
}
const routine=':rowSubquery';
var
  noMore:boolean;
  gotOne:boolean;
  i:colRef;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Executing subquery %p',[@planRoot]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}
  result:=planRoot.start;
  if result=ok then
    try
      noMore:=False;
      gotOne:=False;  //track whether we've receive a result
      {Note: this while loop shouldn't be needed since we're only expecting
       a single row result. We do next until noMore to ensure there are
       no more after the 1st one
      }
      while not noMore do
      begin
        result:=planRoot.next(noMore);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'Aborting execution',vError); 
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;  //don't duplicate error for each tuple!
        end
        else
        begin //store the resulting tuple
          //todo: if no rows were returned, generate a row of nulls (currently will give error?)
          if not(noMore) then
          begin
            if gotOne then
            begin //we are expecting more rows - not allowed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Only allowed a single row result',[nil]),vError);
              {$ELSE}
              ;
              {$ENDIF}
  {$IFDEF DEBUG_LOG}
  //            log.add(st.who,where+routine,format('continuing...',[1]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  //            (*todo continue?
              //todo assert planRoot.stmt is always ok here
              planRoot.stmt.addError(seOnlyOneRowExpected,seOnlyOneRowExpectedText);
              result:=fail;
              exit; //abort
  //            *)
            end;
            gotOne:=true;
            tuple.clear(st); //todo remove? need to be sure we release any blobs...
            tuple.ColCount:=planRoot.iTuple.ColCount;
            tuple.clear(st);
            if tuple.ColCount>0 then
              for i:=0 to tuple.ColCount-1 do
              begin
                tuple.CopyColDef(i,planRoot.iTuple,i); //todo check ok?
                tuple.copyColDataDeep(i,st,planRoot.iTuple,i,false);   //todo: don't do if not necessary - see below! - debug fix only
                       //Note: deep copy seems necessary only when subquery returns an aggregate
                       //(probably because that is a manufactured tuple & the callers of this routine will destroy the iterator
                       // tree after so the data pointers then dangle)
                       //else deep copy not required
              end;
            tuple.preInsert; //finalise the output tuple
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('result tuple= %s',[tuple.Show(st)]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end ;
        end;
      end; {while}
    finally
      planRoot.stop;
      //todo check result, although stmt.commit/rollback typically won't be involved, so not vital?
    end; {try}

  //todo: need to destroy this iterator plan! - caller's responsibility
  //also, think about saving the compiled plan (i.e algebra?) in
  //      the db/memory for re-use...
end; {RowSubquery}

function TableSubquery(iter:TIterator;planRoot:TIterator):integer;
{Executes the (sub)query plan
 IN:      iter            the current iterator (->tuple) to take column values from
          planRoot        the plan root of the subquery = iterator chain root

 RESULT: ok or fail

 //todo allow termination during next looping (e.g. owner sets a Cancel flag) - would need to pass Tr in somehow...

 Assumes:
   planRoot has already been prePlanned (to complete the syntax trees)
   up to caller to set stmt.status:=ssActive and then ssInactive after call

 Note:
  this routine is currently internal to this unit only
  It is basically RowSubquery but without attempting a tuple result
  The code is also replicated in uEvalCondExpr (preplan is done in a first-step)
  where it's used to loop through ALL and ANY and EXISTS sub-table expressions
}
const routine=':tableSubquery';
var
  noMore:boolean;
begin
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Executing query %p',[@planRoot]),vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  result:=planRoot.start;
  if result=ok then
    try
      noMore:=False;
      while not noMore do
      begin
        result:=planRoot.next(noMore);
        if result<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'Aborting execution',vError);  
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;  //don't duplicate error for each tuple!
        end
      end; {while}
    finally
      if planRoot.stop<>ok then  //i.e. don't set result=ok, since next might have failed (we're in a finally clause)
      begin
        {stmt.commit/rollback may have been involved in .stop, so could fail because of constraint violations etc.}
        result:=fail;
      end;
      //todo note: we might be able to improve the fail/result logic above using the new iterator.success flag...
    end; {try}

  //todo: need to destroy this iterator plan! - caller's responsibility
  //also, think about saving the compiled plan (i.e algebra?) in
  //      the db/memory for re-use...
end; {TableSubquery}

function PreparePlan(stmt:Tstmt;iter:TIterator):integer;
{Prepare an execute plan for the syntax tree that was generated by the parser
 If query/insert/update/delete etc. (i.e. anything that might be executed repeatedly):
   converts it to an algebra tree (which references the syntax tree)
   optimises this into a plan tree if necessary (which references the algebra tree)
   prePlans the plan to complete the syntax tree & make the final projected tuple definition available
 Otherwise, does nothing - the execute routine will handle it - no plan is needed/possible

 IN:
           tr        transaction
           stmt      the partially complete plan node (sroot is set to the root of the syntax tree/subtree to process)
           iter      super-context (initially needed for passing current row into constraint check
                                    but in future could be used to pass system-constants)
                         - nil if not needed
                     //todo* ensure we pass this everywhere we currently have (pass system iter+tuple?)
 OUT:
           stmt           the completed plan node (i.e. sroot.atree and sroot.ptree are prepared for execution)
                          with resultSet set appropriately

 RESULT:   Ok,
           else Fail - stmt may have partially allocated structures, e.g. atree

 Side-effects:
   the syntax tree will probably change & its root will point to the 1st in a chain of sub-trees (CNF)
   if an IterGroup is used, its child.next is called (which cascades down) to start the grouping match routines
   - todo check this comment is still valid for final group algorithm...
   A transaction is implicitly started if one is not already in progress & we have something to prepare

 Notes:
   the trees pointed to by the plan are not freed by this routine
   we have to store ptree into TObject for storage in sroot (due to circular units)

 Assumes:
   we are connected already

 todo:
   we should attach a list of ntParam syntax node pointers to the stmt (populated in CreateSelectExp?)
   so the caller can auto-populate the client's IPD.

   for most plans, we could delete the syntax tree after preparation
   (except where we have (user,tables,in,the,SQL) ; Aggregates(could-workaround?) etc? - condition typing etc.)
}
const routine=':PreparePlan';
var
  sroot,n:TSyntaxNodePtr;   //syntax root
  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root

  newChildParent:TIterator;
//note: directly use stmt - not locals - but needed else compiler type errors
begin
  result:=Ok;

  sroot:=stmt.sroot;
  atree:=nil;
  ptree:=nil;
  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}

  {If we're running inside a compound loop then we may have prepared already, so skip this code
   Note: this could be a good way to cache recently used queries/routines, i.e.
         new stmt could repoint iterator owner to self & run
         (would need to run a safe copy though, unless we move all state to stmt e.g. noMore)
  }
  if (stmt.outer<>nil) and
  (   (stmt.outer.sroot.nType=ntCompoundWhile)
   or (stmt.outer.sroot.nType=ntCompoundRepeat)
   or (stmt.outer.sroot.nType=ntCompoundLoop)
   or (stmt.outer.sroot.nType=ntCompoundIf)
   or (stmt.outer.sroot.nType=ntCompoundCase)
   //or (stmt.outer.sroot.nType=ntCompoundBlock) //todo ok?
  ) then
  begin
    if sroot.atree<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned (assuming done in 1st pass of loop) %p',[ord(sroot.nType),sroot.atree]),vDebugLow);
      {$ENDIF}

      {But we may need to re-preplan to make sure our (possibly new) stmt is fit to run again
       Note: this does too much, e.g. we don't need to re-check privileges etc.}
      stmt.resultSet:=False;  //default = no result set
      //todo assert planActive=False already here!!!
      stmt.planActive:=False;

      case sroot.nType of //todo replace with if..in... or if needsPlan(node)...
        ntTableExp,ntSelect{into},ntInsert,ntUpdate,ntDelete:
        begin
          {We have built a plan, so we may need to prePlan it now to make any final projected tuple definition available}
          if sroot.ptree<>nil then //assert we have a plan may=> result-set //todo ok assumption? is ptree initialised to nil?
          begin
            //re=point the original stmt to this new one: todo ok? dangerous? de-allocate & totally re-prepare?
            ChangeIteratorTreeOwner((sroot.ptree as TIterator),stmt);

            //re-preplan to ready the new stmt, e.g. constraints etc. 
            //todo replace this test by a setting in the stmt, e.g. sType:=stSelectStmt...
            if TAlgebraNodePtr(sroot.atree)^.anType in [antInto, antInsertion, antUpdate, antDeletion] then
            begin
              {This will be executed en-bloc in the ExecutePlan routine, but we still allow user to prepare}
              result:=(sroot.ptree as TIterator).prePlan(iter{caller passes super-context}{nil}{todo: pass system iter+tuple?});
              if result=ok then
              begin
                //todo assert sarg=nil!
                result:=(sroot.ptree as TIterator).optimise(stmt.sarg,newChildParent);
                //todo assert newChildParent=nil!
                //todo only if result=ok then...?
                stmt.noMore:=True; //to force ExecutePlan and prevent fetch attempt //todo crude (client should ensure) but better than nothing!? for now
              end;
            end
            else
            begin
              {We need to open a cursor and start the plan}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Starting prepared query plan %d with super-context %d',[longint(sroot.ptree),longint(iter)]),vDebugMedium);
              {$ENDIF}
              result:=(sroot.ptree as TIterator).prePlan(iter{caller passes super-context}{nil}{todo: pass system iter+tuple?});
              if result=ok then
              begin
                //todo assert sarg=nil!
                result:=(sroot.ptree as TIterator).optimise(stmt.sarg,newChildParent);
                //todo assert newChildParent=nil!
                //todo only if result=ok then...?
                stmt.resultSet:=True; //notify caller that there will be a result set
                stmt.noMore:=True; //to force ExecutePlan before 1st fetch //todo crude (client should ensure) but better than nothing!? for now
              end;
            end;
          end;
        end; {nodes needing plan}
      end; {case}

      //todo any use? result:=+1;
      exit;
    end;
  end;


  try
    stmt.resultSet:=False;  //default = no result set
    //todo assert planActive=False already here!!!
    stmt.planActive:=False;

    case sroot.nType of //todo replace with if..in... or if needsPlan(node)...
      //ntCompoundBlock,ntDeclaration,ntCompoundLoop etc. - leave until executePlan (for now at least)
      ntCallRoutine:
      begin //prepare parameters
        n:=sroot.rightChild;
        while n<>nil do
        begin
          result:=CompleteScalarExp(stmt,iter{not expecting column values here, but pass anyway},n.leftChild{descend below ..._exp},agNone);
          if result<>ok then exit; //aborted by child

          n:=n.nextNode; //next parameter in this list
        end;

        //todo we might have a result set- who knows!
        // ....note: this gets unset by the CLIserver because there is no plan root/tuple def!
        // so we need to somehow find out what the first result set is:
        //      whip through the sub-stmts & prepare last declare cursor with return?
        //stmt.resultSet:=True; //notify caller that there will be a result set
        //stmt.noMore:=True; //to force ExecutePlan before 1st fetch //todo crude (client should ensure) but better than nothing!? for now
      end;
      ntAssignment:
      begin //prepare assignment expression
        //todo: syntax error if LH = FunctionReturnParameterName (reserved for RETURN result)
        n:=sroot.leftChild.rightChild; {=ntUpdateAssignment expression}
        if n<>nil then

        begin
          result:=CompleteScalarExp(stmt,iter{not expecting column values here, but pass anyway},n.leftChild{descend below ..._exp},agNone);
          if result<>ok then exit; //aborted by child
        end;

        //todo prepare left side as well, i.e. findVar now
      end;
      ntReturn:
      begin //prepare return expression
        n:=sroot.rightChild; {=ntReturn expression}
        if n<>nil then
        begin
          result:=CompleteScalarExp(stmt,iter{not expecting column values here, but pass anyway},n.leftChild{descend below ..._exp},agNone);
          if result<>ok then exit; //aborted by child
        end;
      end;
      ntCompoundWhile:
      begin //prepare condition
        n:=sroot.rightChild;
        result:=CondToCNF(stmt.srootAlloc,n); //ok to do this here?
        if result<>ok then exit; //aborted by child
        result:=CompleteCondExpr(stmt,iter{not expecting column values here, but pass anyway},n,agNone);
        if result<>ok then exit; //aborted by child
      end;
      ntCompoundRepeat:
      begin //prepare condition
        n:=sroot.rightChild;
        result:=CondToCNF(stmt.srootAlloc,n); //ok to do this here?
        if result<>ok then exit; //aborted by child
        result:=CompleteCondExpr(stmt,iter{not expecting column values here, but pass anyway},n,agNone);
        if result<>ok then exit; //aborted by child
      end;
      ntCompoundIf, ntCompoundCase:
      begin //prepare conditions
        n:=sroot.leftChild;
        while n<>nil do
        begin
          result:=CondToCNF(stmt.srootAlloc,n.leftChild); //ok to do this here?
          if result<>ok then exit; //aborted by child
          //todo we need to re complete each of these when we run them since we only use 1 stmt, so why bother here???? debug...
          result:=CompleteCondExpr(stmt,iter{not expecting column values here, but pass anyway},n.leftChild,agNone);
          if result<>ok then exit; //aborted by child

          //we can never prepare all the sub-calls statically but maybe we could prepare the (top-level) action blocks here?

          n:=n.nextNode; //next condition/action in this list
        end;
      end;

      ntTableExp,ntSelect{into},ntInsert,ntUpdate,ntDelete:
      begin
        {Assert we haven't already an algebra/plan attached}
        if sroot.atree<>nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(sroot.nType),sroot.atree]),vAssertion);
          {$ENDIF}
          result:=Fail;
          exit;
        end;
        if sroot.ptree<>nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(sroot.nType),longint(sroot.ptree)]),vAssertion);
          {$ENDIF}
          result:=Fail;
          exit;
        end;

        {Do we need to auto-initiate a transaction now?}
        //if we haven't already started a transaction, do so now
        if Ttransaction(stmt.owner).tranRt.tranId=InvalidStampId.tranId then
        begin
          result:=Ttransaction(stmt.owner).Start;
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Failed to auto-start transaction',[nil]),vDebugError);
            {$ENDIF}
            result:=Fail;
            exit;
          end;
          //ensure stmt keeps up: todo any more places we need to synch. these???
          stmt.fRt:=Ttransaction(stmt.owner).tranRt;

          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Auto-initiating transaction...',[nil]),vDebugLow);
          {$ENDIF}
        end;

        {Create the algebra plan}
        case sroot.nType of
          ntTableExp:    result:=CreateTableExp(stmt,sroot,atree);
          ntSelect:      result:=CreateSelectExp(stmt,sroot,atree); //=> antInto
          ntInsert:      result:=CreateInsert(stmt,sroot,atree);
          ntUpdate:      result:=CreateUpdate(stmt,sroot,atree);
          ntDelete:      result:=CreateDelete(stmt,sroot,atree);
          //todo in future we might ntCallRoutine: result:=CreateCallRoutine(st,stmt,sroot,atree);
          //     and then prepare all the stmts within the routine body...?
        else //should never happen
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Syntax node planning half-handled %d',[ord(sroot.nType)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          result:=Fail;
          exit;
        end; {case}
        sroot.atree:=atree; //todo ok, even though result may not be ok?
        if result<>ok then exit; //abort

        {Create the iterator plan}
        result:=CreatePlan(stmt,sroot,sroot.atree,ptree);
        sroot.ptree:=ptree; //todo ok, even though result may not be ok?
        if result<>ok then
        begin
          stmt.addError(seFail,seFailText); 
          exit; //abort
        end;
        {We have built a plan, so we may need to prePlan it now to make any final projected tuple definition available}
        if sroot.ptree<>nil then //assert we have a plan may=> result-set 
        begin
          //todo replace this test by a setting in the stmt, e.g. sType:=stSelectStmt...
          if TAlgebraNodePtr(sroot.atree)^.anType in [antInto, antInsertion, antUpdate, antDeletion] then
          begin
            {This will be executed en-bloc in the ExecutePlan routine, but we still allow user to prepare}
            result:=(sroot.ptree as TIterator).prePlan(iter{caller passes super-context}{nil}{todo: pass system iter+tuple?});
            if result=ok then
            begin
              //todo assert sarg=nil!
              result:=(sroot.ptree as TIterator).optimise(stmt.sarg,newChildParent);
              //todo assert newChildParent=nil!
              //todo only if result=ok then...?
              stmt.noMore:=True; //to force ExecutePlan and prevent fetch attempt //todo crude (client should ensure) but better than nothing!? for now
            end;
          end
          else
          begin
            {We need to open a cursor and start the plan}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Starting prepared query plan %d with super-context %d',[longint(sroot.ptree),longint(iter)]),vDebugMedium);
            {$ENDIF}
            result:=(sroot.ptree as TIterator).prePlan(iter{caller passes super-context}{nil}{todo: pass system iter+tuple?});
            if result=ok then
            begin
              //todo assert sarg=nil!
              result:=(sroot.ptree as TIterator).optimise(stmt.sarg,newChildParent);
              //todo assert newChildParent=nil!
              //todo only if result=ok then...?
              stmt.resultSet:=True; //notify caller that there will be a result set
              stmt.noMore:=True; //to force ExecutePlan before 1st fetch //todo crude (client should ensure) but better than nothing!? for now
            end;
          end;
        end;
      end; {nodes needing plan}
    //else nothing to be prepared - leave to execute phase
    end; {case}

  //todo catch exceptions here?
  finally
  end; {try}
end; {PreparePlan}

function PrepareAndExecutePlan(stmt:Tstmt;iter:TIterator;var rowCount:integer):integer;
{Prepares, executes and unprepares a plan for the syntax tree that was generated by the parser
 (created for compoundBlock/call nesting etc. within executePlan)

 IN:
           tr        transaction
           stmt      the partially complete plan node (sroot is set to the root of the syntax tree/subtree to process)
           iter      super-context (initially needed for passing current row into constraint check
                                    but in future could be used to pass system-constants)
                         - nil if not needed = always for this routine?
                     //todo* ensure we pass this everywhere we currently have (pass system iter+tuple?)

 OUT:      rowCount      count of affected rows

 RESULT:   Ok,
           1+, need parameter data (=>SQL_NEED_DATA) result=param ref number
           else Fail - stmt may have partially allocated structures, e.g. atree

 Note: any cursors/result-sets are fully consumed (silently for now)
}
const routine=':PrepareAndExecutePlan';
begin
  result:=PreparePlan(stmt,iter{nil here since we cannot be a sub-query or constraint-check here});
  try
    if result<>ok then
      exit; //abort - todo ok? //todo improve recovery

    if stmt.sroot<>nil then //a plan was created: for now we must consume it
    begin
      result:=ExecutePlan(stmt,rowCount); //likely to be a recursive call
      if result<>ok then
      begin
        //if (result=Leaving) and (assigned(stmt.outer){always true here}) {todo n/a impossible!? or (result=Iterating)} then
        if (result=Leaving) (*and (assigned(stmt.outer){always true here})*) {todo n/a impossible!? or (result=Iterating)} then
        begin //this is a user-requested leave, e.g. Return
          //if compareText(stmt.leavingLabel,stmt.outer.sroot.idVal)=0 then
          if compareText(stmt.leavingLabel,stmt.sroot.idVal)=0 then
          //begin //our parent is the block we need to break out of
          begin //we are the block we need to break out of (could be ourself if return from function with no begin..end)
            //we have broken from our loop naturally
            result:=ok;
          end
          else
          begin 
            if not assigned(stmt.outer) then
            begin //if there is no outer block, error
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Error unexpected leave from routine: %s',[stmt.leavingLabel]),vAssertion);
              {$ENDIF}
              //todo leave as is? result:=fail;
              stmt.addError(seUnknownLabel,format(seUnknownLabelText,[stmt.leavingLabel]));
              exit; //abort the operation
            end
            else
            begin //we leave the result=Leaving for the caller to pick up
              exit;
            end;
          end;
        end
        else
        begin
          stmt.need_param:=result; //store which parameter is missing
          exit; //abort - todo ok? //todo improve recovery
        end;
      end;

      {If this plan returned a cursor, loop through it and consume the rows}
      if stmt.planActive then
      begin //executed & cursor pending
        try
          rowCount:=0; //for now we'll return affected rows

          //if we aren't going to use any results from here, jump straight to .stop (speed)

          while not stmt.noMore do
          begin
            result:=(stmt.sroot.ptree as TIterator).next(stmt.noMore);
            if result<>ok then
            begin
              //for now, prevent access violation below:
              stmt.noMore:=True; //todo too crude? but works!
              //todo should be more severe! return critical error to client...
              exit; //abort batch //todo continue?: assume an error has been added to the st already... todo add another here just in case? //todo improve recovery
            end;

            if not stmt.noMore then
            begin
              inc(rowCount);
              (*todo: some kind of processing/storing/returning of rows here?
              subSt.sroot.ptree as TIterator).iTuple.Show(tr)...
              *)
            end;
          end;
        finally
          if (stmt.sroot.ptree as TIterator).stop<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Error stopping existing plan',[nil]),vDebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end; {cursor}
    end;

    {Note: we can be nested, so be aware of our level}
  finally
    {Copied from cli closeCursor- ok?}
    stmt.planActive:=False;
    stmt.resultSet:=False;
    stmt.need_param:=0;
    begin
      if UnPreparePlan(stmt)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
    end;
  end; {try}
end; {PrepareAndExecutePlan}

function ExecutePlan(stmt:Tstmt;var rowCount:integer):integer;
{Executes a prepared plan
 IN:
           tr        transaction
           stmt      the completed syntax/plan node
                     Note: stmt.outer gives us the variable/parameter scope context (if any)

 OUT:
           stmt      the executed plan node (noMore &/or planActive & status modified)
           rowCount  count of affected rows (only valid for insert/update/delete)
                     //may be valid in future for materialised select (iterOutput->iterMaterialise?)

 RESULT:   Ok, executed
           -2 = call depth nested too deeply (or unknown auth if connecting...)
           Leaving = recursive call requested leave to an outer block (specified in stmt.leavingLabel)
           Iterating = recursive call requested continuation of an outer loop block (specified in stmt.leavingLabel)
           1+, need parameter data (=>SQL_NEED_DATA) result=param ref number
           else Fail


todo Design:
  we have a few options here. We need to support Prepare,Execute,Fetch,FetchScroll(NEXT),FetchScroll(RANDOM)
     (and in future, maybe some updates but I'll worry about that later)

   1. plan.ptree.start
        Fetch calls plan.ptree.Next as and when each row is required
      until no more

      +: keep current structure - good for initial ODBC dev?
         immediate response to client so can start processing results
      -: work is done in bits per fetch, so server buffer management will suffer
         fetch is slower than it should be
           -although client would fetch[20] and should rapidly repeat this call till no more

   2. add materialise to plan.ptree
      plan.ptree.start
        plan.ptree.next
      until no more
      Fetch steps through materialised result-set

      +: work is done in one chunk
         should handle future random-fetching
      -: need space for whole result-set - may be massive
         client has to wait until all processing complete before being able to get results/info

   3. add readAhead-buffer to plan.ptree
      plan.ptree.start
        clear readAhead-buffer
          plan.ptree.next
        until readAhead-buffer is full or no more
        Fetch steps though readAhead-buffer until empty
      until no more

      +: work is done in reasonable/tailorable sized chunks (readAhead-buffer could hold thousands of rows)
         can limit materialisation space required -would really have to anyway, so maybe 2=>3
      -: doesn't offer full random-fetching for future (but could simulate by restarting if required etc)

   Summary:
     1 is easiest to implement now to get the ODBC driver working (forward cursors only)
      //todo remove old comment:- note: this meant we moved plan.ptree.start to the PreparePlan routine,
              so this routine effectively does nothing! (we really do execute on-the-fly!)
     3 is probably the solution for the long-term, but needs thought into totally random access


 Side-effects:

 Notes:
   the trees pointed to by the plan are not freed by this routine
   this routine can be called repeatedly with the same stmtPlan

   calling this routine for planned nodes (re)starts the prepared plan
}
const
  routine=':ExecutePlan';
  ceInternal='sys/pe'; //temp column name
var
  nextParam:TParamListPtr;
  n,n2:TSyntaxNodePtr;

  catalog_id:TcatalogId;
  schema_id:TschemaId;
  catalog_name,schema_name:string;
  schemaId_auth_Id:TauthId;
  dummy_null:boolean;

  serverName,username,password,connectionName:string;
  saveTranId:StampId;

  killTr:TTransaction;
  killTranRt:StampId;

  subSt,otherSt:TStmt;
  subStrowCount:integer;
  errNode:TErrorNodePtr;
  tempTuple:TTuple;
  initialVarCount,i:varRef;
  j:varRef; //actually a param count
  res:TriLogic;
  varCount:integer;
  varDomainId:integer; //n/a
  varVariableType:TVariableType; //n/a
  varDataType:TDatatype;
  varWidth:integer;
  varScale:smallint;
  varDefaultVal:string;
  varDefaultNull:boolean;
  vId:TVarId;
  vSet:TVariableSet;
  vRef:VarRef;
  newDB:TDB;

  {for cursor fetch dynamic plans}
  raNode:TAlgebraNodePtr;
  itNode:TIterator;
  noMore:boolean;

  gc:TGarbageCollector;
begin
  result:=Fail;
  n:=nil; //safety/ease debug if we crash
  rowCount:=-1; //reset for select etc. better than garbage - although we shouldn't use it

  if stmt.sroot=nil then
  begin
    {There is no chance of plan!}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('No prepared plan (not even a syntax root!)',[nil]),vAssertion);
    {$ENDIF}
    stmt.addError(seNotPrepared,seNotPreparedText);
    exit; //abort
  end;

  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}
  try
    {Do we have a plan?}
    if stmt.sroot.ptree=nil then
    begin
      {Handle operations that don't have a plan}

      {Do we need to auto-initiate a transaction now?}
      case stmt.sroot.nType of
        ntCommit,ntRollback,ntConnect,ntDisconnect,ntSetTransaction,ntSetSchema,ntSetConstraints,
        ntCreateCatalog, ntKILLTRAN, //from parser logic... todo: maybe some here need to be copied back there as well?
        ntSHOWTRANS,ntSHUTDOWN:
          {don't initiate a transaction} //Note: most of these won't appear here since ODBC filters them
      else //if we haven't already started a transaction, do so now
        if Ttransaction(stmt.owner).tranRt.tranId=InvalidStampId.tranId {note: elsewhere we use tr.connected} then
        begin
          result:=Ttransaction(stmt.owner).Start;
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Failed to auto-start transaction',[nil]),vDebugError);
            {$ENDIF}
            result:=Fail;
            exit;
          end;
          //ensure stmt keeps up: todo any more places we need to synch. these???
          stmt.fRt:=Ttransaction(stmt.owner).tranRt;

          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Auto-initiating transaction...',[nil]),vDebugLow); 
          {$ENDIF}
        end;
      end;

      //todo may need to call some Complete routines here in future...
      case stmt.sroot.nType of
        ntCompoundBlock:
        begin
          //todo: think about preserving the results of each sub-stmt's processing for future re-use
          //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
          //      - attach to ntCompoundBlock node...

          rowCount:=0; //for now we'll accumulate affected rows

          result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
          if result=ok then
          begin
            try
              subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              subSt.varSet:=TVariableSet.create(subSt);
              subSt.status:=ssActive; //i.e. cancellable
              {Loop through each sub-statement in this compound block}
              n:=stmt.sroot.leftChild; //1st sub-stmt's ntCompoundElement container
              while n<>nil do  
              begin
                subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree
                //note: we leave syntaxErr details etc. to the main st since the parsing's already been done
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Processing %p compound sub-stmt %p %d %s',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype),stmt.sroot.idVal]),vDebug);
                DisplaySyntaxTree(subSt.{parse}sroot); //debug
                {$ENDIF}

                {We need to ensure we don't remove subtree while the root points to it,
                 so we increment the reference count here to delay the tree deletion until the compound
                 block is finished with}
                linkLeftChild(n,subSt.{parse}sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                //      - maybe if we know we're looping we should retain the local ones...

                {Note: compounds can be nested, so be aware of our level}
                if subSt.status=ssCancelled then
                begin
                  result:=Cancelled;
                  exit;
                end;
                result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                if result<>ok then
                begin
                  if (result=Leaving) or (result=Iterating) then
                  begin //this is a user-requested leave/continue
                    if compareText(subSt.leavingLabel,stmt.sroot.idVal)=0 then
                    begin //we are the block we need to break out of
                      if result=Iterating then
                      begin //we cannot iterate a block
                        result:=fail;
                        stmt.addError(seCannotIterateHere,format(seCannotIterateHereText,[nil]));
                        exit; //abort the operation
                      end
                      else
                      begin
                        result:=ok; //let the caller continue
                        break; //break from our loop naturally
                      end;
                    end
                    else
                    begin
                      if not assigned(stmt.outer.outer) then
                      begin //if there is no outer block, error
                        result:=fail;
                        stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                        exit; //abort the operation
                      end
                      else
                      begin //we leave the result=Leaving/Iterating for the caller to pick up
                        stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                        break; //break from our loop naturally
                      end;
                    end;
                  end
                  else
                    exit; //abort - todo ok? //todo improve recovery
                end;
                if subStrowCount<>-1 then
                  rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                n:=n.nextNode; //next sub-stmt in this compound block
              end;
            finally
              if (result<>ok) and (result<>Leaving) and (result<>Iterating) then
              begin
                {Copy errors from sub-stmt to batch stmt level}
                errNode:=subSt.errorList;
                while errNode<>nil do
                begin
                  stmt.addError(errNode.code,errNode.text);
                  errNode:=errNode.next;
                end;
                subSt.deleteErrorList; //clear subSt error stack
              end;

              if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion);
                {$ELSE}
                ;
                {$ENDIF}
              subSt:=nil;
              //todo assert subStmtList=nil!
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating temporary compound stmt handle, continuing...',vAssertion);
            {$ENDIF}
          end;
        end; {ntCompoundBlock}
        ntCompoundWhile:
        begin
          //todo: think about preserving the results of each sub-stmt's processing for future re-use
          //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
          //      - attach to ntCompoundBlock node...

          //todo!
          //if level>Max then infinite loop error...

          rowCount:=0; //for now we'll accumulate affected rows

          result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
          if result=ok then
          begin
            try
              subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              subSt.varSet:=TVariableSet.create(subSt);
              subSt.status:=ssActive; //i.e. cancellable

              repeat
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Processing %p while loop test sub-stmt %p %s on %d',[stmt.sroot,stmt.sroot.leftChild,stmt.sroot.idVal,longint(subSt)]),vDebug);
                {$ENDIF}

                if subSt.status=ssCancelled then
                begin
                  result:=Cancelled;
                  exit;
                end;
                result:=EvalCondExpr(stmt,nil{not expecting column values here},stmt.sroot.rightChild,res,agNone,false);
                if result<>ok then exit; //abort
                if res=isTrue then
                begin
                  {Note: compounds can be nested, so be aware of our level}

                  {Loop through each sub-statement in this compound block}
                  //todo need a common multiple execute routines?
                  n:=stmt.sroot.leftChild; //1st sub-stmt's ntCompoundElement container
                  while n<>nil do  
                  begin
                    subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree
                    //note: we leave syntaxErr details etc. to the main st since the parsing's already been done
                    {$IFDEF DEBUG_LOG}
                    log.add(stmt.who,where+routine,format('Processing %p while compound sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                    //DisplaySyntaxTree(subSt.{parse}sroot); //debug
                    {$ENDIF}

                    {We need to ensure we don't remove subtree while the root points to it,
                     so we increment the reference count here to delay the tree deletion until the compound
                     block is finished with

                     Note: a good side-effect of this is that the substmt tree(s) will stay prepared
                           throughout the duration of the compound loop
                    }
                    linkLeftChild(n,subSt.{parse}sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                    //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                    //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                    //      - maybe if we know we're looping we should retain the local ones...

                    {Note: compounds can be nested, so be aware of our level}
                    if subSt.status=ssCancelled then
                    begin
                      result:=Cancelled;
                      exit;
                    end;
                    result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                    if result<>ok then
                    begin
                      if (result=Leaving) or (result=Iterating) then
                      begin //this is a user-requested leave/continue
                        if compareText(subSt.leavingLabel,stmt.sroot.idVal)=0 then
                        begin //we are the block we need to break out of
                          break; //break from our loop naturally
                        end
                        else
                        begin
                          if not assigned(stmt.outer.outer) then
                          begin //if there is no outer block, error
                            result:=fail;
                            stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                            exit; //abort the operation
                          end
                          else
                          begin //we leave the result=Leaving/Iterating for the caller to pick up
                            stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                            break; //break from our loop naturally
                          end;
                        end;
                      end
                      else
                        exit; //abort - todo ok? //todo improve recovery
                    end;
                    if subStrowCount<>-1 then
                      rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                    n:=n.nextNode; //next sub-stmt in this compound block
                  end; {while}
                  {If we broke out because of a Leave, ensure we continue to break out of the repeat}
                  if (result=Leaving) or ( (result=Iterating) and (stmt.leavingLabel<>'') ) then
                  begin //leaving or mismatched iterate
                    if (result=Leaving) and (stmt.leavingLabel='') then result:=ok; //matched
                    break;
                  end;
                  //an iterating match will continue the loop here by default
                end
                else
                  break; //user loop end
              until false; //forever until condition<>isTrue
            finally
              if (result<>ok) and (result<>Leaving) and (result<>Iterating) then
              begin
                {Copy errors from sub-stmt to caller stmt level}
                errNode:=subSt.errorList;
                while errNode<>nil do
                begin
                  stmt.addError(errNode.code,errNode.text);
                  errNode:=errNode.next;
                end;
                subSt.deleteErrorList; //clear subSt error stack
              end;
              //todo else?...

              if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion);
                {$ELSE}
                ;
                {$ENDIF}
              subSt:=nil;
              //todo assert subStmtList=nil!
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion);
            {$ENDIF}
          end;
        end; {ntCompoundWhile}
        ntCompoundRepeat:
        begin
          //todo: think about preserving the results of each sub-stmt's processing for future re-use
          //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
          //      - attach to ntCompoundBlock node...

          //todo!
          //if level>Max then infinite loop error...

          rowCount:=0; //for now we'll accumulate affected rows

          result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
          if result=ok then
          begin
            try
              subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              subSt.varSet:=TVariableSet.create(subSt);
              subSt.status:=ssActive; //i.e. cancellable

              res:=isTrue;
              repeat
                begin
                  {Note: compounds can be nested, so be aware of our level}

                  {Loop through each sub-statement in this compound block}
                  //todo need a common multiple execute routines?
                  n:=stmt.sroot.leftChild; //1st sub-stmt's ntCompoundElement container
                  while n<>nil do  
                  begin
                    subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree
                    //note: we leave syntaxErr details etc. to the main st since the parsing's already been done
                    {$IFDEF DEBUG_LOG}
                    log.add(stmt.who,where+routine,format('Processing %p repeat compound sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                    //DisplaySyntaxTree(subSt.{parse}sroot); //debug
                    {$ENDIF}

                    {We need to ensure we don't remove subtree while the root points to it,
                     so we increment the reference count here to delay the tree deletion until the compound
                     block is finished with

                     Note: a good side-effect of this is that the substmt tree(s) will stay prepared
                           throughout the duration of the compound loop
                    }
                    linkLeftChild(n,subSt.{parse}sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                    //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                    //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                    //      - maybe if we know we're looping we should retain the local ones...

                    {Note: compounds can be nested, so be aware of our level}
                    if subSt.status=ssCancelled then
                    begin
                      result:=Cancelled;
                      exit;
                    end;
                    result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                    if result<>ok then
                    begin
                      if (result=Leaving) or (result=Iterating) then
                      begin //this is a user-requested leave/continue
                        if compareText(subSt.leavingLabel,stmt.sroot.idVal)=0 then
                        begin //we are the block we need to break out of
                          break; //break from our loop naturally
                        end
                        else
                        begin
                          if not assigned(stmt.outer.outer) then
                          begin //if there is no outer block, error
                            result:=fail;
                            stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                            exit; //abort the operation
                          end
                          else
                          begin //we leave the result=Leaving/Iterating for the caller to pick up
                            stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                            break; //break from our loop naturally
                          end;
                        end;
                      end
                      else
                        exit; //abort - todo ok? //todo improve recovery
                    end;
                    if subStrowCount<>-1 then
                      rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                    n:=n.nextNode; //next sub-stmt in this compound block
                  end; {while}
                  {If we broke out because of a Leave, ensure we continue to break out of the repeat}
                  if (result=Leaving) or ( (result=Iterating) and (stmt.leavingLabel<>'') ) then
                  begin //leaving or mismatched iterate
                    if (result=Leaving) and (stmt.leavingLabel='') then result:=ok; //matched
                    break;
                  end;
                  //an iterating match will continue the loop here by default
                end;

                {Test the user repeat-until condition}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Processing %p repeat loop test sub-stmt %p %s',[stmt.sroot,stmt.sroot.leftChild,stmt.sroot.idVal]),vDebug);
                {$ENDIF}
                if subSt.status=ssCancelled then
                begin
                  result:=Cancelled;
                  exit;
                end;
                result:=EvalCondExpr(stmt,nil{not expecting column values here},stmt.sroot.rightChild,res,agNone,false);
                if result<>ok then exit; //abort

              until res=isTrue;
            finally
              if (result<>ok) and (result<>Leaving) and (result<>Iterating) then
              begin
                {Copy errors from sub-stmt to caller stmt level}
                errNode:=subSt.errorList;
                while errNode<>nil do
                begin
                  stmt.addError(errNode.code,errNode.text);
                  errNode:=errNode.next;
                end;
                subSt.deleteErrorList; //clear subSt error stack
              end;
              //todo else?...

              if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion); 
                {$ELSE}
                ;
                {$ENDIF}
              subSt:=nil;
              //todo assert subStmtList=nil!
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion); 
            {$ENDIF}
          end;
        end; {ntCompoundRepeat}
        ntCompoundLoop:
        begin
          //todo: think about preserving the results of each sub-stmt's processing for future re-use
          //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
          //      - attach to ntCompoundBlock node...

          //todo!
          //if level>Max then infinite loop error...

          rowCount:=0; //for now we'll accumulate affected rows

          result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
          if result=ok then
          begin
            try
              subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              subSt.varSet:=TVariableSet.create(subSt);
              subSt.status:=ssActive; //i.e. cancellable

              repeat
                //Note: the only way out of this infinite loop is to leave/return
                //todo: how do we prevent the processor being pegged? leave to OS for now...
                if subSt.status=ssCancelled then
                begin
                  result:=Cancelled;
                  exit;
                end;
                begin
                  {Note: compounds can be nested, so be aware of our level}

                  {Loop through each sub-statement in this compound block}
                  //todo need a common multiple execute routines?
                  n:=stmt.sroot.leftChild; //1st sub-stmt's ntCompoundElement container
                  while n<>nil do  
                  begin
                    subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree
                    //note: we leave syntaxErr details etc. to the main st since the parsing's already been done
                    {$IFDEF DEBUG_LOG}
                    log.add(stmt.who,where+routine,format('Processing %p loop compound sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                    //DisplaySyntaxTree(subSt.{parse}sroot); //debug
                    {$ENDIF}

                    {We need to ensure we don't remove subtree while the root points to it,
                     so we increment the reference count here to delay the tree deletion until the compound
                     block is finished with

                     Note: a good side-effect of this is that the substmt tree(s) will stay prepared
                           throughout the duration of the compound loop
                    }
                    linkLeftChild(n,subSt.{parse}sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                    //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                    //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                    //      - maybe if we know we're looping we should retain the local ones...

                    {Note: compounds can be nested, so be aware of our level}
                    if subSt.status=ssCancelled then
                    begin
                      result:=Cancelled;
                      exit;
                    end;
                    result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                    if result<>ok then
                    begin
                      if (result=Leaving) or (result=Iterating) then
                      begin //this is a user-requested leave/continue
                        if compareText(subSt.leavingLabel,stmt.sroot.idVal)=0 then
                        begin //we are the block we need to break out of
                          break; //break from our loop naturally
                        end
                        else
                        begin
                          if not assigned(stmt.outer.outer) then
                          begin //if there is no outer block, error
                            result:=fail;
                            stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                            exit; //abort the operation
                          end
                          else
                          begin //we leave the result=Leaving/Iterating for the caller to pick up
                            stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                            break; //break from our loop naturally
                          end;
                        end;
                      end
                      else
                        exit; //abort - todo ok? //todo improve recovery
                    end;
                    if subStrowCount<>-1 then
                      rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                    n:=n.nextNode; //next sub-stmt in this compound block
                  end; {while}
                  {If we broke out because of a Leave, ensure we continue to break out of the repeat}
                  if (result=Leaving) or ( (result=Iterating) and (stmt.leavingLabel<>'') ) then
                  begin //leaving or mismatched iterate
                    if (result=Leaving) and (stmt.leavingLabel='') then result:=ok; //matched
                    break;
                  end;
                  //an iterating match will continue the loop here by default
                end;
              until false; //forever until leave or return
            finally
              if (result<>ok) and (result<>Leaving) and (result<>Iterating) then
              begin
                {Copy errors from sub-stmt to caller stmt level}
                errNode:=subSt.errorList;
                while errNode<>nil do
                begin
                  stmt.addError(errNode.code,errNode.text);
                  errNode:=errNode.next;
                end;
                subSt.deleteErrorList; //clear subSt error stack
              end;
              //todo else?...

              if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion); 
                {$ELSE}
                ;
                {$ENDIF}
              subSt:=nil;
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion); 
            {$ENDIF}
          end;
        end; {ntCompoundLoop}
        ntCompoundIf,ntCompoundCase:
        begin
          //todo: think about preserving the results of each sub-stmt's processing for future re-use
          //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
          //      - attach to ntCompoundBlock node...

          //todo!
          //if level>Max then infinite loop error...

          rowCount:=0; //for now we'll accumulate affected rows

          result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
          if result=ok then
          begin
            try
              subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              subSt.varSet:=TVariableSet.create(subSt);
              subSt.status:=ssActive; //i.e. cancellable

              n:=stmt.sroot.leftChild;
              {Loop through the conditions until one matches}
              while n<>nil do
              begin
                if n.ntype=ntIfThen then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Processing if/case sub-stmt %p',[n]),vDebug);
                  {$ENDIF}

                  result:=EvalCondExpr(stmt,nil{not expecting column values here},n.leftChild,res,agNone,false);
                  if result<>ok then exit; //abort
                  if res=isTrue then
                  begin
                    {Process this node's action list & stop looking for if matches}
                    //fix 04/01/01 (previously just did a1, workaround was: IF x THEN BEGIN a1; a2; END; END IF;)
                    n:=n.rightChild; //we can overwrite n here, because we'll never continue with the outer while loop
                    while n<>nil do  //todo repeat is more appropriate: the grammar forbids an empty list here?
                    begin
                      subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree //1st sub-stmt's ntCompoundElement container
                      //note: we leave syntaxErr details etc. to the main st since the parsing's already been done

                      {$IFDEF DEBUG_LOG}
                      log.add(stmt.who,where+routine,format('Processing %p if/case compound sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                      //DisplaySyntaxTree(subSt.{parse}sroot); //debug
                      {$ENDIF}

                      {We need to ensure we don't remove subtree while the root points to it,
                       so we increment the reference count here to delay the tree deletion until the compound
                       block is finished with

                       Note: a good side-effect of this is that the substmt tree(s) will stay prepared
                             throughout the duration of the compound loop
                      }
                      linkLeftChild(n.rightChild,subSt.{parse}sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                      //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                      //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                      //      - maybe if we know we're looping we should retain the local ones...

                      {Note: compounds can be nested, so be aware of our level}
                      result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                      if result<>ok then
                      begin
                        if (result=Leaving) or (result=Iterating) then
                        begin //this is a user-requested leave
                          begin
                            if not assigned(stmt.outer.outer) then
                            begin //if there is no outer block, error
                              result:=fail;
                              stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                              exit; //abort the operation
                            end
                            else
                            begin //we leave the result=Leaving/Iterating for the caller to pick up
                              stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                              break; //break from our loop naturally
                            end;
                          end;
                        end
                        else
                          exit; //abort - todo ok? //todo improve recovery
                      end;
                      if subStrowCount<>-1 then
                        rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                      n:=n.nextNode; //next sub-stmt in this compound list
                    end; {while}
                    {If we broke out because of a Leave, ensure we continue to break out of the outer while}
                    if (result=Leaving) or ( (result=Iterating) and (stmt.leavingLabel<>'') ) then
                    begin //leaving or mismatched iterate
                      if (result=Leaving) and (stmt.leavingLabel='') then result:=ok; //matched
                      break;
                    end;
                    break; //exit if-elseif-else-end if
                  end
                  else
                  begin
                    //no match, so we continue testing chain of elseifs
                  end;
                end;
                //else assertion: we're not expecting anything else here!

                n:=n.nextNode; //next condition/action in this list
              end; {while}

              if (res<>isTrue) and (stmt.sroot.rightChild<>nil) then
              begin //we perform any else part since we didn't match any of the conditions
                res:=isTrue; //i.e. we've done something

                //fix 04/01/01 (previously just did a1, workaround was: IF x THEN BEGIN a1; a2; END; END IF;)
                n:=stmt.sroot.rightChild;
                while n<>nil do  //todo repeat is more appropriate: the grammar forbids an empty list here?
                begin
                  subSt.sroot:=n.leftChild; //pass whole stand-alone sub-tree //1st sub-stmt's ntCompoundElement container
                  //note: we leave syntaxErr details etc. to the main st since the parsing's already been done
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Processing %p else compound sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                  //DisplaySyntaxTree(subSt.{parse}sroot); //debug
                  {$ENDIF}

                  {We need to ensure we don't remove subtree while the root points to it,
                   so we increment the reference count here to delay the tree deletion until the compound
                   block is finished with

                   Note: a good side-effect of this is that the substmt tree(s) will stay prepared
                         throughout the duration of the compound loop
                  }
                  linkLeftChild(stmt.sroot.rightChild,subSt.sroot);  //superfluous (todo: so assert n.leftChild=subSt.parseRoot already)
                  //todo: alternatively, set n.leftChild=nil after process call (if asserted leftchild=missing!)
                  //      - note: this alternative would free lots of memory (syntax,algebra etc.)!!!!
                  //      - maybe if we know we're looping we should retain the local ones...

                  {Note: compounds can be nested, so be aware of our level}
                  result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                  if result<>ok then
                  begin
                    if result=Leaving then
                    begin //this is a user-requested leave
                      if compareText(subSt.leavingLabel,stmt.sroot.idVal)=0 then
                      begin //we are the block we need to break out of
                        //result:=ok; //let the caller continue
                        //n/a break; //break from our loop naturally
                        break; //break from our loop naturally
                      end
                      else
                      begin
                        if not assigned(stmt.outer.outer) then
                        begin //if there is no outer block, error
                          result:=fail;
                          stmt.addError(seUnknownLabel,format(seUnknownLabelText,[subSt.leavingLabel]));
                          exit; //abort the operation
                        end
                        else
                        begin //we leave the result=Leaving/Iterating for the caller to pick up
                          stmt.leavingLabel:=subSt.leavingLabel; //re-surface the exit block label for the caller to try to match
                          //n/a break; //break from our loop naturally
                          break; //break from our loop naturally
                        end;
                      end;
                    end
                    else
                      exit; //abort - todo ok? //todo improve recovery
                  end;
                  if subStrowCount<>-1 then
                    rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                  n:=n.nextNode; //next sub-stmt in this compound list
                end; {while}
              end;

              if (res<>isTrue) and (stmt.sroot.nType=ntCompoundCase) then
              begin //we must go down one branch of a case statement
                result:=fail;
                stmt.addError(seCaseNotFound,format(seCaseNotFoundText,[nil]));
                exit; //abort the operation
              end;
            finally
              if (result<>ok) and (result<>Leaving) and (result<>Iterating) then
              begin
                {Copy errors from sub-stmt to caller stmt level}
                errNode:=subSt.errorList;
                while errNode<>nil do
                begin
                  stmt.addError(errNode.code,errNode.text);
                  errNode:=errNode.next;
                end;
                subSt.deleteErrorList; //clear subSt error stack
              end;
              //todo else?...

              if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion); 
                {$ELSE}
                ;
                {$ENDIF}
              subSt:=nil;
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion); 
            {$ENDIF}
          end;
        end; {ntCompoundIf,ntCompoundCase}

        ntCallRoutine: //todo note: keep in sync. with ntUserFunction evaluation
        begin
          begin
            if stmt.depth>=MAX_ROUTINE_NEST then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,seTooMuchNestingText+format(' %d',[stmt.depth]),vError);
              {$ENDIF}
              stmt.addError(seTooMuchNesting,format(seTooMuchNestingText,[nil]));
              result:=-2;
              exit; //abort the operation
            end;

            //todo: think about preserving the results of each sub-stmt's processing for future re-use
            //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
            //      - attach to ntCompoundBlock node...

            rowCount:=0; //for now we'll accumulate affected rows

            result:=Ttransaction(stmt.owner).addStmt(stSystemUserCall,subSt);
            if result=ok then
            begin
              try
                subSt.outer:=stmt; //link children to this parent context for variable/parameter scoping
                subSt.depth:=stmt.depth+1; //track nesting
                //todo assert varSet=nil
                subSt.varSet:=TVariableSet.create(subSt);
                subSt.status:=ssActive; //i.e. cancellable
                {Prepare the called routine's body for this sub-statement}
                  result:=CreateCallRoutine(stmt,stmt.sroot,subSt,false); //Note: we pass our current st for the routine body script, and the new child subSt which will do the processing
                  if result<>ok then
                    exit; //abort - todo ok? //todo improve recovery

                  {Now evaluate and load any in/inout parameters}
                  if subSt.varSet.VarCount>0 then
                  begin
                    tempTuple:=TTuple.create(nil);
                    try
                      tempTuple.ColCount:=1;

                      n:=stmt.sroot.rightChild;

                      for i:=0 to subSt.varSet.VarCount-1 do
                      begin //for each routine argument
                        if n<>nil then
                        begin //we have a value to pass
                          if subSt.varSet.fVarDef[i].variableType in [vtIn,vtInOut] then
                          begin //a value is needed
                            //todo assert n.ntype=ntVariableRef if vtInOut
                            tempTuple.clear(stmt);
                            tempTuple.SetColDef(0,1,ceInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
                            result:=EvalScalarExp(subSt,nil{not expecting column values here},n.leftChild{descend below ..._exp},tempTuple,0,agNone,false);
                            if result<>ok then exit; //aborted by child
                            tempTuple.preInsert; //prepare buffer
                            result:=subSt.varSet.CopyColDataDeepGetSet(stmt,i,tempTuple,0);  //Note: deep copy required here
                            if result<>ok then
                            begin
                              stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                              {Clean-up the syntax tree prepared by the createCallRoutine}
                              if UnPreparePlan(subSt)<>ok then
                                {$IFDEF DEBUG_LOG}
                                log.add(stmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
                                {$ELSE}
                                ;
                                {$ENDIF}
                              exit; //abort the operation
                            end;
                          end;
                          //todo else must be vtOut so assert n.ntype=ntVariableRef

                          n:=n.nextNode; //next parameter in this list
                        end
                        else
                        begin
                          stmt.addError(seSyntaxNotEnoughParemeters,seSyntaxNotEnoughParemetersText);
                          result:=fail;
                          {Clean-up the syntax tree prepared by the createCallRoutine}
                          if UnPreparePlan(subSt)<>ok then
                            {$IFDEF DEBUG_LOG}
                            log.add(stmt.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError);
                            {$ELSE}
                            ;
                            {$ENDIF}
                          exit; //abort
                        end;
                      end;
                    finally
                      tempTuple.free;
                    end; {try}
                  end;
                  //else parameterless

                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Processing %p routine call sub-stmt %p %d:',[stmt.sroot,subSt.{parse}sroot,ord(subSt.{parse}sroot.ntype)]),vDebug);
                  log.add(stmt.who,where+routine,format('  parameters=%s',[subSt.{parse}varSet.showHeading]),vDebug);
                  log.add(stmt.who,where+routine,format('             %s',[subSt.{parse}varSet.show(stmt)]),vDebug);
                  DisplaySyntaxTree(subSt.{parse}sroot); //debug
                  {$ENDIF}

                  {We store the current varCount for out parameter checking later (i.e. no need to scan any extra locally declared variables)}
                  initialVarCount:=subSt.varSet.VarCount; //todo: useful to variableSet itself, so store it there!

                  {Note: compounds can be nested, so be aware of our level}
                  result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
                  if result<>ok then
                    exit; //abort - todo ok? //todo improve recovery
                    //Note: we're not expecting a Leave to surface here...

                  if subStrowCount<>-1 then
                    rowCount:=rowCount+subStrowCount; //accumulate any valid rowcounts (for now)

                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('After routine call, tree root = %p',[stmt.sroot]),vDebug);
                  {$ENDIF}

                  {Now retrieve any out parameters}
                  n:=stmt.sroot.rightChild;

                  if initialVarCount>0 then
                    for i:=0 to initialVarCount-1 do
                    begin //for each routine argument
                      if n<>nil then
                      begin //we have a potential variable to receive a result in
                        if subSt.varSet.fVarDef[i].variableType in [vtOut,vtInOut] then
                        begin //a return value is needed
                          {Find the variable/(CLI)parameter in this context}
                          //todo assert assigned(stmt.varSet)!!! or ensure we always have one...
                          case n.leftChild.nType of
                            ntVariableRef:
                            begin
                              result:=stmt.varSet.FindVar(n.leftChild.rightChild.idval,stmt.outer{todo: always pass nil here?},vSet,vRef,vid);
                              if vid=InvalidVarId then
                              begin
                                //todo make this next error message more specific, e.g. unknown column parameter reference...
                                stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.leftChild.rightChild.idval]));
                                result:=fail;
                                exit; //abort the operation
                              end;
                              {$IFDEF DEBUG_LOG}
                              log.add(stmt.who,where+routine,format('Setting output variable (%x) %d to %s',[longint(vset),vid,subSt.varSet.ShowVar(stmt,i)]),vDebug);
                              {$ENDIF}
                              result:=vset.CopyVarDataDeepGetSet(stmt,vRef,subSt.varSet,i); //Note: deep copy required here
                              if result<>ok then
                              begin
                                stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                                exit; //abort the operation
                              end;
                            end; {ntVariableRef}
                            ntParam:
                            begin //? => top of call chain & done from CLI
                              {Find the corresponding (output) parameter} //todo improve - use fast method of paramList - speed
                              //Note: this assumes all parameters were CLI parameters - ok?
                              nextParam:=stmt.paramList; //todo add interface to this & hide the structure!
                              j:=0;
                              while (j<i) and (nextParam<>nil) do
                              begin
                                nextParam:=nextParam.next;
                                inc(j);
                              end;
                              if (j<=i) and (nextParam<>nil) then
                              begin //found
                                //todo assert nextParam.paramType in [vtOut,vtInOut]
                                {Set the type of this parameter - is this the first time we realise it's an output?}
                                nextParam.paramType:=vtOut; //todo or vtInOut if was already sent in
                                {$IFDEF DEBUG_LOG}
                                log.add(stmt.who,where+routine,format('Setting output parameter %d (%s) to %s',[j,nextParam.paramSnode.idVal,subSt.varSet.ShowVar(stmt,i)]),vDebug);
                                {$ENDIF}
                                //todo: need big case to set for all types! ...we really need a type mapping subroutine!
                                //      although client seems to coerce parameters into/from strings for now...
                                nextParam.paramSnode.strVal:=subSt.varSet.ShowVar(stmt,i); //Note: deep copy required here
                                nextParam.paramSnode.nullval:=False;
                              end
                              else
                              begin
                                //todo make this next error message more specific, e.g. missing column parameter reference...
                                stmt.addError(seInvalidOutputParameter,seInvalidOutputParameterText);
                                result:=fail;
                                exit; //abort the operation
                              end;
                            end; {ntParam}
                          else //user tried to pass a non-variable into an out parameter
                            //todo make this next error message more specific, e.g. missing column parameter reference...
                            stmt.addError(seInvalidOutputParameter,seInvalidOutputParameterText);
                            result:=fail;
                            exit; //abort the operation
                          end; {case}
                        end;

                        n:=n.nextNode; //next parameter in this list
                      end
                      else
                      begin
                        stmt.addError(seSyntaxNotEnoughParemeters,seSyntaxNotEnoughParemetersText);
                        result:=fail;
                        exit; //abort
                      end;
                    end;

                  {Check for any return cursors}
                  result:=Ttransaction(stmt.owner).StmtScanStart;
                  if result<>ok then exit; //abort
                  try
                    noMore:=False;
                    while not noMore do
                    begin
                      if Ttransaction(stmt.owner).StmtScanNext(otherSt,noMore)<>ok then begin result:=fail; exit; end;
                      if not noMore then
                      begin
                        if (otherSt<>stmt) then
                          if (otherSt.outer=subSt) //owned by our routine
                          //todo and (otherSt.cursorName<>'') //i.e. still alive
                          and (otherSt.stmtType=stUserCursor)
                          and otherSt.planReturn then
                          begin
                            if (otherSt.sroot.ptree is TIterInto) then
                            begin //we have already done a fetch, so remove the top-level sink
                              //attempt to remove fetch into node //todo needs testing for memory leaks
                              itNode:=(otherSt.sroot.ptree as Titerator).leftChild;
                              (otherSt.sroot.ptree as Titerator).leftChild:=nil;
                              DeleteIteratorTree((otherSt.sroot.ptree as Titerator)); //todo check result: should do singleton iterInto
                              otherSt.sroot.ptree:=itNode;
                            end;
                            {Zap this stmt's leftovers}
                            (*note: removed during debug: 11/09/04:
                                         return cursors crashed server on call. Defering this fixed it - not sure why...
                            DeleteSyntaxTree(stmt.srootAlloc.allocNext); //todo ok? check result!
                            stmt.srootAlloc.allocNext:=nil;
                            *)
                            {Repoint this stmt at the result set}
                            stmt.sroot:=otherSt.sroot;
                            inc(otherSt.sroot.refCount); //todo ok?
                            stmt.resultSet:=true;
                            stmt.planActive:=true; //todo set to otherSt.planActive?
                            stmt.noMore:=otherSt.noMore; //todo assert true? may not be, e.g. never opened?
                            stmt.cursorName:=otherSt.cursorName; //Move cursor
                            stmt.cursorClosing:=otherSt.cursorClosing;
                            //todo anything else? status?
                            {Now wither the old stmt: we need to keep the plan etc.}
                            otherSt.cursorName:='';
                            otherSt.cursorClosing:=False;
                            otherSt.resultSet:=false;
                            otherSt.planActive:=false;
                            otherSt.noMore:=true;
                          end;
                      end;
                    end; {while}
                  finally
                    result:=Ttransaction(stmt.owner).StmtScanStop; //todo check result
                  end; {try}

              finally
                if result<>ok then
                begin
                  {Copy errors from sub-stmt to caller stmt level}
                  errNode:=subSt.errorList;
                  while errNode<>nil do
                  begin
                    stmt.addError(errNode.code,errNode.text);
                    errNode:=errNode.next;
                  end;
                  subSt.deleteErrorList; //clear subSt error stack

                  stmt.addError(seCompoundFail,seCompoundFailText); //todo general routine error ok for now?
                end;
                //todo else?...
                if Ttransaction(stmt.owner).removeStmt(subSt)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion); 
                  {$ELSE}
                  ;
                  {$ENDIF}
                subSt:=nil;
              end; {try}
            end
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion); 
              {$ENDIF}
            end;
          end;
        end; {ntCallRoutine}
        ntDeclaration:
        begin //declare local variable(s)
          if not assigned(stmt.varSet) then
          begin //i.e. stmt.outer=nil, i.e. root stmt has (currently) no variable context
            stmt.addError(seCannotDeclareVariableHere,seCannotDeclareVariableHereText);
            result:=fail;
            exit; //abort
          end;

          n:=stmt.sroot;
          n2:=n.leftChild; {1st variable}

          varCount:=stmt.varSet.VarCount; //keep count of new additions from what we already have
          while n2<>nil do
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Processing variable declaration %s',[n2.idVal]),vDebug);
            {$ENDIF}

            {Note: some of this code is duplicated in the ntCast evaluation}

            result:=DetermineDatatype(stmt,n.rightChild,
                                      varDomainId{n/a},varDataType,varWidth,varScale,varDefaultVal,varDefaultNull,varVariableType{n/a});
            if result<>ok then exit; //abort

            {Prohibit blob vars: not working yet (& no use?)
             workaround: use cast + varchar!}
            if DataTypeDef[varDataType] in [stBlob] then
            begin //for now we can't declare blob variables: todo detach blob routines from Ttuple & fix
              stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['Declaring large object variables']));
              result:=fail;
              exit; //abort
            end;

            varVariableType:=vtDeclared; //override the vtIn default

            {Ensure we don't reach the local variable limit}
            if (varCount+1)>maxVar then
            begin
              stmt.addError(seTooManyVariables,seTooManyVariablesText);
              result:=fail;
              exit;
            end;

            inc(varCount); //need to increment before SetVarDef
            stmt.varSet.VarCount:=varCount; //set the new number of variables before SetVarDef
            stmt.varSet.SetVarDef(stmt,varCount-1,varCount,n2.idVal,
                               varVariableType, varDataType,
                               varWidth,varScale,
                               varDefaultVal,varDefaultNull);
            //todo inc fVarCount here? - for subscript checks etc

            n2:=n2.nextNode; //move to any more variables
          end;

          result:=ok;
        end; {ntDeclaration}
        ntCursorDeclaration:
        begin
          n:=stmt.sroot;

          //todo read/write cursor names to varSet to give proper scoping/recursion/garbage-collection abilities
          if Ttransaction(stmt.owner).getStmtFromCursorName(n.leftChild.idVal,subSt)=ok then
          begin //cursor name already exists
            subSt:=nil; //forget result
            stmt.addError(seSyntaxCursorAlreadyExists,seSyntaxCursorAlreadyExistsText);
            result:=fail;
            exit;
          end;

          //todo using getspareStmt would be better to re-use 'dead?' cursors
          result:=Ttransaction(stmt.owner).getSpareStmt(stUserCursor,subSt);
          if result=ok then
          begin
            try
              //Note: we only set these so we can destroy the cursor when the calling block/routine is destroyed
              subSt.outer:=stmt; //link children to same context as self for variable/parameter scoping
              subSt.depth:=stmt.depth; //track nesting
              //todo assert varSet=nil
              //no need? subSt.varSet:=TVariableSet.create(subSt);
              //no need? subSt.status:=ssActive; //i.e. cancellable

              {Prepare this plan}
              //todo subSt should really be called st here (i.e. not really a sub-statement in this case)
              n2:=n.rightChild; {table expression}
              subSt.sroot:=n2; //point to table expression to be prepared now
              {Steal the sub-plan}
              inc(n2.refCount); //increment the ref count to prevent this part of the plan from being cleaned early!

              n2:=n.leftChild;
              subSt.cursorName:=n2.idVal;
              n2:=n2.nextNode;
              while n2<>nil do
              begin //cursor options/specification
                case n2.nType of
                  ntScroll:
                  begin
                    result:=fail;
                    stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['Scrollable cursor declaration']));
                    exit; //abort
                  end;
                  ntSensitive:
                  begin
                    result:=fail;
                    stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['Sensitive cursor declaration']));
                    exit; //abort
                  end;
                  ntCursorHold:
                    subSt.planHold:=True;
                  ntCursorReturn:
                    subSt.planReturn:=True;
                  ntForReadOnly:
                  begin
                    //default
                  end;
                  ntForUpdate:
                  begin
                    //todo: n/a (read only) if scroll or insensitive or order-by etc.
                    //leftchild = column list or nil = all
                    result:=fail;
                    stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['Updatable cursor declaration']));
                    exit; //abort
                  end;
                end; {case}

                n2:=n2.nextNode;
              end;
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Declaring cursor %s in %d',[subSt.cursorName,longint(subSt.outer)]),vDebug);
              {$ENDIF}
              result:=PreparePlan(subSt,nil); //todo check result & fail if it fails!
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Declared cursor %s with sroot ptree=%d',[subSt.cursorName,longint(subSt.sroot.ptree)]),vDebug);
              {$ENDIF}

              //todo: how to clear these up? should do at end of this stmt/block as with variables
              //      - but leaving until later will aid result sets from procs etc. plus may be standalone/session based
              //      so, leave until tran destroy? need explicit deallocate cursor?

            finally
              subSt:=nil; //no one else in this section should assume/take-hold of this: it belongs to the transaction!
            end; {try}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,'failed allocating cursor stmt handle, continuing...',vAssertion); 
            {$ENDIF}
          end;
        end; {ntCursorDeclaration}
        ntOpen:
        begin
          n:=stmt.sroot;

          if Ttransaction(stmt.owner).getStmtFromCursorName(n.leftChild.idVal,subSt)=ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(subSt.who,where+routine,format(': (re)starting prepared cursor query plan %d',[longint(subSt.sroot.ptree)]),vDebugMedium);
            {$ENDIF}
            //todo: (& elsewhere?) if planActive then .restart to close & reset any materialisation - else materialised sub-queries could be kept too long!

            {if not closed, fail}
            if subSt.planActive then
            begin
              result:=fail;
              stmt.addError(seSyntaxCursorAlreadyOpen,seSyntaxCursorAlreadyOpenText);
              exit; //abort
            end;

            result:=(subSt.sroot.ptree as TIterator).start;
            if result<>ok then
            begin
              //todo avoid planActive:=True if start failed!?

              {Copy any error details to the user's stmt}
              if subSt.errorList<>nil then stmt.addError(subSt.errorList.code,subSt.errorList.text);
              exit; //abort
            end;
            subSt.planActive:=True;
            subSt.noMore:=False; //ready for 1st fetch
            //note: n/a here? subSt.status:=ssActive;

            Ttransaction(subSt.owner).sqlstateSQL_NO_DATA:=False; //reset EOF

            result:=ok; //todo remove: use result of start!

            subSt:=nil; //forget result
          end
          else
          begin //not found
            stmt.addError(seSyntaxUnknownCursor,format(seSyntaxUnknownCursorText,[n.leftChild.idVal]));
            result:=fail;
            exit;
          end;
        end; {ntOpen}
        ntClose:
        begin
          n:=stmt.sroot;

          if Ttransaction(stmt.owner).getStmtFromCursorName(n.leftChild.idVal,subSt)=ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(subSt.who,where+routine,format(': (re)starting prepared cursor query plan %d',[longint(subSt.sroot.ptree)]),vDebugMedium);
            {$ENDIF}
            //todo: (& elsewhere?) if planActive then .restart to close & reset any materialisation - else materialised sub-queries could be kept too long!

            //todo call stmt.closeCursor here = centralised? is it the same here? i.e. not a result set pointer

            {if not open, fail}
            if not subSt.planActive then
            begin
              result:=fail;
              stmt.addError(seSyntaxCursorNotOpen,seSyntaxCursorNotOpenText);
              exit; //abort
            end;

            result:=(subSt.sroot.ptree as TIterator).stop;
            if result<>ok then
            begin
              {stmt.commit/rollback may have been involved in .stop, so could fail because of constraint violations etc.}
              {Copy any error details to the user's stmt}
              if subSt.errorList<>nil then stmt.addError(subSt.errorList.code,subSt.errorList.text);
              exit; //abort
            end;
            subSt.planActive:=False;
            //note: n/a here? subSt.status:=ssInactive;

            if Ttransaction(stmt.owner).existsStmt(subSt.outer)<>ok then
            begin //this cursor is outside its original owning block so it can be zapped now
              subSt.closeCursor(1{=unprepare}); //I think this is when the standard means for this to happen...
              Ttransaction(stmt.owner).removeStmt(subSt);
            end;
            //else we leave the cursor until the end of the owning block, in case user wants to re-open it

            result:=ok; //todo remove: use result of stop!

            subSt:=nil; //forget result
          end
          else
          begin //not found
            stmt.addError(seSyntaxUnknownCursor,format(seSyntaxUnknownCursorText,[n.leftChild.idVal]));
            result:=fail;
            exit;
          end;
        end; {ntClose}
        ntFetch:
        begin
          n:=stmt.sroot;

          //todo save this subSt against the prepared fetch: speed!
          if Ttransaction(stmt.owner).getStmtFromCursorName(n.leftChild.idVal,subSt)=ok then
          begin
            {if not open, fail}
            if not subSt.planActive then
            begin
              result:=fail;
              stmt.addError(seSyntaxCursorNotOpen,seSyntaxCursorNotOpenText);
              exit; //abort
            end;

            if not(subSt.sroot.ptree is TIterInto) then
            begin //first call
              {$IFDEF DEBUG_LOG}
              log.add(subSt.who,where+routine,format(': building prepared cursor query plan on top of %d',[longint(subSt.sroot.ptree)]),vDebugMedium);
              {$ENDIF}
              {Place into iterator on top of our query}
              //todo plus squeeze in an iterMaterialise if scrollable!
              //Note: this is the right place because at compile-time we cannot find the declared cursor (easily)
              //Note: we can get away without calling start/optimise since this wouldn't currently do anything...
              itNode:=nil;
              raNode:=mkANode(antInto,n.nextNode.leftChild,nil,nil,nil);
              itNode:=TIterInto.create(subSt,raNode);

              {Link to this stmt's plan}
              linkAleftChild(raNode,subSt.sroot.atree);
              subSt.sroot.atree:=raNode;
              itNode.leftChild:=(subSt.sroot.ptree as TIterator);
              subSt.sroot.ptree:=itNode;

              //todo assert varSet=nil

              (subSt.sroot.ptree as Titerator).prePlan(nil);

              //todo clean up: itNode:=nil; raNode:=nil;
            end;

            {$IFDEF DEBUG_LOG}
            log.add(subSt.who,where+routine,format(': fetching from prepared cursor query plan %d',[longint(subSt.sroot.ptree)]),vDebugMedium);
            {$ENDIF}

            {todo: remove the need for this varset here & so speed up with try..finally removed}
            subSt.varSet:=stmt.varSet; //set cursor's variables to this stmt's since we've no need of our own here... todo ok?
            //subSt.varSet:=subSt.outer.varSet; //debug? ok?
            try
              result:=(subSt.sroot.ptree as Titerator).next(subSt.noMore);
            finally
              subSt.varSet:=nil; //else we own the varSet & close would try to free it
            end; {try}
            if result<>ok then
            begin
              {Copy any error details to the user's stmt}
              if subSt.errorList<>nil then stmt.addError(subSt.errorList.code,subSt.errorList.text);
              exit; //abort
            end;

            if subSt.noMore then Ttransaction(subSt.owner).sqlstateSQL_NO_DATA:=True; //flag EOF

            result:=ok; //todo remove: use result of next!

            subSt:=nil; //forget result
          end
          else
          begin //not found
            stmt.addError(seSyntaxUnknownCursor,format(seSyntaxUnknownCursorText,[n.leftChild.idVal]));
            result:=fail;
            exit;
          end;
        end; {ntFetch}
        ntAssignment:
        begin //assign expression to variable
          if not assigned(stmt.varSet) then
          begin //i.e. stmt.outer=nil, i.e. root stmt has (currently) no variable context
            stmt.addError(seCannotSetVariableHere,seCannotSetVariableHereText);
            result:=fail;
            exit; //abort
          end;

          n:=stmt.sroot.leftChild.rightChild; {=ntUpdateAssignment expression}
          if n<>nil then
          begin
            {Now evaluate and set variable = expression}
            tempTuple:=TTuple.create(nil);
            try
              tempTuple.ColCount:=1;
              tempTuple.clear(stmt);
              tempTuple.SetColDef(0,1,ceInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
              result:=EvalScalarExp(stmt,nil{not expecting column values here},n.leftChild{descend below ..._exp},tempTuple,0,agNone,false);
              if result<>ok then exit; //aborted by child
              tempTuple.preInsert; //prepare buffer
              {Find the variable}
              //todo assert assigned(stmt.varSet)!!! or ensure we always have one...
              result:=stmt.varSet.FindVar(stmt.sroot.leftChild.leftChild.idval,stmt.outer,vSet,vRef,vid);
              if vid=InvalidVarId then
              begin
                //todo make this next error message more vague, e.g. unknown column/variable/parameter reference...
                stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[stmt.sroot.leftChild.rightChild.idval]));
                result:=fail;
                exit; //abort the operation
              end;
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Setting variable (%x) %d to %s',[longint(vset),vid,tempTuple.show(stmt)]),vDebug);
              {$ENDIF}
              result:=vset.CopyColDataDeepGetSet(stmt,vRef,tempTuple,0);  //Note: deep copy required here
              if result<>ok then
              begin
                stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                exit; //abort the operation
              end;
            finally
              tempTuple.free;
            end; {try}
          end;
          //else todo leave/set-as default
        end; {ntAssignment}
        ntReturn:
        begin //return expression from function
          if not assigned(stmt.varSet) then
          begin //i.e. stmt.outer=nil, i.e. root stmt has (currently) no variable context
            stmt.addError(seCannotSetVariableHere,seCannotSetVariableHereText); //todo make more specific
            result:=fail;
            exit; //abort
          end;

          n:=stmt.sroot.rightChild; {=ntReturn expression}
          if n<>nil then
          begin
            {Now evaluate and set return value = expression}
            tempTuple:=TTuple.create(nil);
            try
              tempTuple.ColCount:=1;
              tempTuple.clear(stmt);
              tempTuple.SetColDef(0,1,ceInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
              result:=EvalScalarExp(stmt,nil{not expecting column values here},n.leftChild{descend below ..._exp},tempTuple,0,agNone,false);
              if result<>ok then exit; //aborted by child
              tempTuple.preInsert; //prepare buffer 
              {Find the variable}
              //todo assert assigned(stmt.varSet)!!! or ensure we always have one...
              result:=stmt.varSet.FindVar(FunctionReturnParameterName{i.e. system named},stmt.outer,vSet,vRef,vid);
              if vid=InvalidVarId then
              begin
                //todo make this next error message more specific, e.g. can only return from within a function
                stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,['<function result>']));
                result:=fail;
                exit; //abort the operation
              end;
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Setting result variable (%x) %d to %s',[longint(vset),vid,tempTuple.show(stmt)]),vDebug);
              {$ENDIF}
              result:=vset.CopyColDataDeepGetSet(stmt,vRef,tempTuple,0);  //Note: deep copy required here
              if result<>ok then
              begin
                stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                exit; //abort the operation
              end;

              {Now leave the the function (but we could be nested a few blocks, so use the label matching leave)}
              if vset.owner is Tstmt then
              begin
                result:=Leaving;
                stmt.leavingLabel:=(vset.owner as Tstmt).sroot.idVal;
              end;
              //else should never happen
            finally
              tempTuple.free;
            end; {try}
          end;
          //else todo leave/set-as default
        end; {ntReturn}
        ntLeave:
        begin //break from the specified block/loop
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Processing %p leave %s:',[stmt.sroot,stmt.sroot.leftChild.idVal]),vDebug);
          {$ENDIF}
          if not assigned(stmt.outer) then
          begin //there is no outer block to leave
            result:=fail;
            stmt.addError(seCannotLeaveHere,format(seCannotLeaveHereText,[nil]));
            exit; //abort the operation
          end
          else
          begin
            result:=Leaving;
            stmt.leavingLabel:=stmt.sroot.leftChild.idVal+LABEL_TERMINATOR;
          end;
        end; {ntLeave}
        ntIterate:
        begin //break from the specified block/loop
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Processing %p iterate %s:',[stmt.sroot,stmt.sroot.leftChild.idVal]),vDebug);
          {$ENDIF}
          if not assigned(stmt.outer) then
          begin //there is no outer block to iterate
            result:=fail;
            stmt.addError(seCannotIterateHere,format(seCannotIterateHereText,[nil]));
            exit; //abort the operation
          end
          else
          begin
            result:=Iterating;
            stmt.leavingLabel:=stmt.sroot.leftChild.idVal+LABEL_TERMINATOR;
          end;
        end; {ntIterate}

        ntCreateCatalog:
        begin
          if Ttransaction(stmt.owner).db=nil then
          begin //without a valid db we won't find the server so use the default server
            result:=CreateCatalog((Ttransaction(stmt.owner).thread as TCMThread).dbServer,stmt,stmt.sroot);
          end
          else
            result:=CreateCatalog((Ttransaction(stmt.owner).db.owner as TDBserver),stmt,stmt.sroot); //Note: we pass our current transaction's server
          (*note: error logging left to subroutine
          if result<>ok then
          begin
            stmt.addError(seFail,seFailText); //todo general error ok?
            //todo remove all these general errors: Create... will add errors to stmt for us...
          end;
          *)
        end; {createCatalog}
        ntCreateUser:
        begin
          result:=CreateUser(stmt,stmt.sroot);
        end; {createUser}
        ntAlterUser:
        begin
          result:=AlterUser(stmt,stmt.sroot);
        end; {ntAlterUser}
        ntCreateSchema:
        begin
          result:=CreateSchema(stmt,stmt.sroot);
          //todo ensure subroutine logs all errors
          if result<>ok then
          begin
            stmt.addError(seFail,seFailText);
          end;
        end; {createSchema}
          {Schema elements: indented because they can each also be called from within createSchema}
          ntCreateTable:
          begin
            result:=CreateTable(stmt,stmt.sroot);
            //todo ensure subroutine logs all errors
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end; {createTable}
          ntCreateView:
          begin
            result:=CreateView(stmt,stmt.sroot);
            //todo ensure subroutine logs all errors
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end; {createView}
          ntCreateRoutine:
          begin
            result:=CreateRoutine(stmt,stmt.sroot);
            //todo ensure subroutine logs all errors
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end; {createRoutine}
          ntCreateDomain:
          begin
            result:=CreateDomain(stmt,stmt.sroot);
            //todo ensure subroutine logs all errors
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end; {createDomain}
          ntGrant:
          begin
            result:=Grant(stmt,stmt.sroot);
            //todo ensure subroutine logs all errors
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end; {grant}

          {Non-standard stuff}
          //todo ensure subroutine logs all errors
          ntCreateIndex:
          begin
            {$IFDEF IGNORE_USER_CREATEINDEX}
            result:=ok;
            {$ELSE}
            result:=UserCreateIndex(stmt,stmt.sroot);
            {$ENDIF}
            if result>ok then result:=ok;
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end;
          ntCreateSequence:
          begin
            result:=CreateSequence(stmt,stmt.sroot);
            if result>ok then result:=ok;
            if result<>ok then
            begin
              stmt.addError(seFail,seFailText); 
            end;
          end;

          //todo etc. - keep in sync. with createSchema

        ntRevoke:
        begin
          result:=Revoke(stmt,stmt.sroot);
          if result<>ok then
          begin
            stmt.addError(seFail,seFailText); 
          end;
        end; {revoke}

        ntAlterTable:
        begin
          result:=AlterTable(stmt,stmt.sroot);
        end; {alterTable}

        ntDropSchema:
        begin
          result:=DropSchema(stmt,stmt.sroot);
        end; {dropSchema}
        ntDropDomain:
        begin
          //todo
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('DROP DOMAIN has not been implemented yet',[nil]),vError);
          {$ENDIF}
          stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['DROP DOMAIN']));
          exit; //abort
        end; {dropDomain}
        ntDropTable:
        begin
          result:=DropTable(stmt,stmt.sroot);
        end; {dropTable}
        ntDropView:
        begin
          result:=DropView(stmt,stmt.sroot);
        end; {dropView}
        ntDropRoutine:
        begin
          result:=DropRoutine(stmt,stmt.sroot);
        end; {ntDropRoutine}

        {Non-standard}
        ntDropUser:
        begin
          result:=DropUser(stmt,stmt.sroot);
        end; {dropUser}
        ntDropIndex:
        begin
          result:=DropIndex(stmt,stmt.sroot);
        end; {dropIndex}
        ntDropSequence:
        begin
          result:=DropSequence(stmt,stmt.sroot);
        end; {ntDropSequence}

        {The following commands are not transaction-initiating statements}

        ntCommit:
        begin
          result:=Ttransaction(stmt.owner).Commit(stmt);
          if result<>ok then
          begin
            stmt.addError(seFail,seFailText); //todo no need now we pass stmt to Commit?
          end;
        end; {commit}
        ntRollback: 
        begin
          result:=Ttransaction(stmt.owner).Rollback(False);
          if result<>ok then
          begin
            stmt.addError(seFail,seFailText); 
          end;
        end; {rollback}

        ntConnect: 
        begin
          if stmt.sroot.leftChild<>nil then
            serverName:=stmt.sroot.leftChild.strVal
          else
            serverName:='';
          username:='';
          password:='';
          connectionName:='';
          n:=stmt.sroot.rightChild;
          while n<>nil do
          begin
            case n.nType of
              {Note: the parser needs to use a dummy ntPassword node as a list header - it has no left child & is ignored}
              ntPassword:     if n.leftChild<>nil then password:=n.leftChild.strVal; //todo could be nullVal=True - ok to treat as ''?
              ntAsConnection: connectionName:=n.leftChild.strVal; //todo could be nullVal=True - ok to treat as ''?
              ntUser:         userName:=n.leftChild.strVal; //todo could be nullVal=True - ok to treat as ''?
            else
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Unexpected connection option %d (%d)',[ord(n.nType),longint(stmt.sroot.ptree)]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
            end; {case}
            n:=n.nextNode;
          end; {while}
          {DEFAULTs}
          if serverName='' then serverName:=''; //todo choose current server/catalog
          {Default the connection name to the server name as per the spec.}
          if connectionName='' then connectionName:=serverName;
          {todo: if the connection name already exists - fail here with error 08002}
          if userName='' then userName:=DEFAULT_AUTHNAME;

          //todo check that the db Tr is (pre)connected to is = serverName, else re-pre-connect it now to serverName?
          // - currently we ignore the serverName!
          {We stay with the current server (thread is attached to it)
           but allow reconnection to another db via SERVER.CATALOG
           e.g. CONNECT TO 'thinksql.db1' ...
           currently ignore server prefix so can use CONNECT TO '.db1'}
          //Note: following is copied in uCLIserver.SQLconnect - keep in sync.
          if pos('.',serverName)<>0 then
          begin //we have a server catalog specified so reconnect our transaction/connection to it
            serverName:=copy(serverName,pos('.',serverName)+1,length(serverName));
            //(Ttransaction(stmt.owner).thread as TCMThread).dbServer.findDB(serverName);
            //todo add Ttransaction getServer method (via tcmthread)!
            if Ttransaction(stmt.owner).db=nil then
            begin //without a valid db we won't find the server
              result:=fail;
              stmt.addError(seCatalogFailedToOpen,seCatalogFailedToOpenText); //todo this error ok?
              exit; //abort
            end;

            newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).findDB(serverName); //assumes we're already connected to a db
            if newDB<>nil then
            begin
              {We must finish the current transaction to allow a new tran id to be allocated from the new db etc.}
              Ttransaction(stmt.owner).Disconnect; //todo document/warn that we rollback here!
              Ttransaction(stmt.owner).DisconnectFromDB;
              Ttransaction(stmt.owner).ConnectToDB(newDB);
            end
            else
            begin
              result:=-6;
              stmt.addError(seUnknownCatalog,seUnknownCatalogText);
              exit; //abort
            end;
          end
          else //no server catalog is specified, so connect to the primary one
          begin
            if Ttransaction(stmt.owner).db=nil then
            begin //without a primary db we've nothing to connect to
              result:=fail;
              stmt.addError(seCatalogFailedToOpen,seCatalogFailedToOpenText); //todo this error ok?
              exit; //abort
            end;

            //todo assert (Ttransaction(st.owner).db.owner as TDBserver).getInitialConnectdb<>nil
            //todo assert serverName='' or server name!
            {We must finish the current transaction to allow a new tran id to be allocated from the new db etc.}
            newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).getInitialConnectdb;
            Ttransaction(stmt.owner).Disconnect; //todo document/warn that we rollback here!
            Ttransaction(stmt.owner).DisconnectFromDB;
            Ttransaction(stmt.owner).ConnectToDB(newDB);
          end;

          {Check the username and password are valid & return success or fail}
          result:=Ttransaction(stmt.owner).Connect(username,password);
          case result of
            ok:begin
                //Authorised & connected
                result:=ok; //todo remove - overkill

                //I think we need to pass back the thread reference (can't remember why exactly...)
                //although don't we know the caller because they always come through this thread - maybe not in future...
                //the thread-ref will be used in future as the hdbc from the client
               end;
            -2:begin
                stmt.addError(seUnknownAuth,seUnknownAuthText);
               end;
            -3:begin
                //todo be extra secure: i.e. don't let on that user-id was found!: stmt.addError(seUnknownAuth,seUnknownAuthText);
                stmt.addError(seWrongPassword,seWrongPasswordText);
               end;
            -4:begin
                stmt.addError(seAuthAccessError,seAuthAccessErrorText);
               end;
            -5:begin
                stmt.addError(seAuthLimitError,seAuthLimitErrorText);
               end;
          else
            stmt.addError(seFail,seFailText); 
          end; {case}
        end; {connect}
        ntDisconnect: 
        begin
          //todo: what if we could get here if we're not already connected??
          if stmt.sroot.leftChild<>nil then
            connectionName:=stmt.sroot.leftChild.strVal
          else
          begin
            //todo distinguish between CURRENT/DEFAULT and ALL - currently treat all same!
            connectionName:=Ttransaction(stmt.owner).connectionName;
          end;
          {todo: if the connection does not exist - fail here with error 08002 /surely 08003?!}
          if connectionName<>Ttransaction(stmt.owner).connectionName then
          begin
            stmt.addError(seUnknownConnection,seUnknownConnectionText);
          end
          else
          begin
            //todo: check this is all ok...
            result:=Ttransaction(stmt.owner).Disconnect;
          end;
        end; {ntDisconnect}
        ntSetTransaction:  
        begin
          if stmt.Rt.tranId<>InvalidStampId.tranId then
          begin
            stmt.addError(seInvalidTransactionState,seInvalidTransactionStateText);
            result:=Fail;
            exit; //abort
          end;

          //todo handle list of options, not just assume 1=isolation level!
          if stmt.sroot.leftChild<>nil then
            case stmt.sroot.leftChild.nType of
              ntOptionIsolationSerializable,
              ntOptionIsolationRepeatableRead:  Ttransaction(stmt.owner).isolation:=isSerializable;    //note: repeated read is bumped up

              ntOptionIsolationReadCommitted:   Ttransaction(stmt.owner).isolation:=isReadCommitted;
              ntOptionIsolationReadUncommitted: Ttransaction(stmt.owner).isolation:=isReadUncommitted; //todo bump up to readCommitted for better behaviour?
            else
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Un-handled transaction option %d (%d) (rest of options will be ignored!)',[ord(stmt.sroot.leftChild.nType),longint(stmt.sroot.ptree)]),vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
            end; {case}

          result:=Ok;
        end; {ntSetTransaction}

        ntSetSchema:
        begin
          {Reset current schema for this session}
          saveTranId:=stmt.Rt;
          stmt.Rt:=MaxStampId; //ensure we see all entries in system tables (we have to fake our id because we are not in a transaction yet)
          {We haven't started a transaction yet but we need to avoid rolled-back sysSchema rows so we temporarily read them
           Note: assumes 'not in a transaction'=>InvalidTranId}
          if saveTranId.tranId=InvalidStampId.tranId then Ttransaction(stmt.owner).readUncommittedList; //note: check result: currently we chance it even if this fails: better than nothing: risk=read rolled-back default-schema: still connects!
          try
            result:=getOwnerDetails(stmt,nil{todo make grammar return ntSchema here!},stmt.sroot.leftChild.strVal,'',catalog_Id,catalog_name,schema_Id,schema_name,schemaId_auth_Id);
            if result<>ok then
            begin
              case result of
                -2: stmt.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
                -3: stmt.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[stmt.sroot.leftChild.strVal]));
              end; {case}
              result:=fail; //return general error
              exit; //abort
            end;
          finally
            if saveTranId.tranId=InvalidStampId.tranId then Ttransaction(stmt.owner).removeUncommittedList(False);
            stmt.Rt:=InvalidStampId; //restore tran id //Note: assumes 'not in a transaction'=>InvalidTranId
          end; {try}

          //todo don't we need to check that tr.authID is privileged enough to change to this new schema_id?
          // -maybe it even needs to be the schema owner?

          {Ok, set schema id}
          Ttransaction(stmt.owner).SchemaId:=schema_id;
          Ttransaction(stmt.owner).SchemaName:=stmt.sroot.leftChild.strVal; //todo normalise? uppercase?
          Ttransaction(stmt.owner).schemaId_authId:=schemaId_auth_Id;
        end; {ntSetSchema}

        ntSetConstraints:
        begin
          {Ok, set specified constraints to immediate or deferred}
          if stmt.sroot.leftChild<>nil then
          begin //todo implement & remove!
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Only SET CONSTRAINTS ALL has currently been implemented',[nil]),vError);
            {$ENDIF}
            stmt.addError(seNotImplementedYet,format(seNotImplementedYetText,['SET CONSTRAINTS name']));
            exit; //abort
          end
          else
          begin
            result:=setConstraints(stmt,stmt.sroot.rightChild,stmt.sroot.leftChild);
          end;
        end; {ntSetConstraints}


        {We only expect these from directSQL}
        ntDEBUGTABLE:
        begin
          result:=DebugTable(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {DEBUGTABLE}
        ntDEBUGINDEX:
        begin
          result:=DebugIndex(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {DEBUGINDEX}
        ntDEBUGCATALOG:
        begin
          result:=DebugCatalog(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {DEBUGCATALOG}
        ntDEBUGSERVER:
        begin
          result:=DebugServer(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {DEBUGSERVER}
        ntDEBUGPAGE:
        begin
          result:=DebugPage(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {ntDEBUGPAGE}
        ntDEBUGPLAN:
        begin
          result:=DebugPlan(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {ntDEBUGPLAN}
        ntDEBUGPRINT:
        begin
          result:=DebugPrint(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {ntDEBUGPRINT}
        ntKILLTRAN:
        begin
          if stmt.sroot.leftChild<>nil then killTranRt.tranId:=trunc(stmt.sroot.leftChild.numVal);
          {Find this transaction}
          KillTr:=(Ttransaction(stmt.owner).db.findTransaction(killTranRt) as TTransaction);
          if KillTr<>nil then
          begin
            {Check we have privilege}
            if not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and
               not(Ttransaction(stmt.owner).authID=KillTr.authID) and
               not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID) then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Not privileged to kill a transaction using this catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
              {$ENDIF}
              stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to kill a transaction using this catalog']));
              result:=Fail;
              exit;
            end;
            //todo? also check we are connected to the server's primary catalog

            result:=KillTr.Kill((Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown tran %d',[killTranRt.tranId]),vError);
            {$ENDIF}
            stmt.addError(seSyntaxUnknownTransaction,format(seSyntaxUnknownTransactionText,[killTranRt.tranId]));
            exit; //abort
          end;
        end; {KILLTRAN}
        ntCANCELTRAN:
        begin
          if stmt.sroot.leftChild<>nil then killTranRt.tranId:=trunc(stmt.sroot.leftChild.numVal);
          {Find this transaction}
          KillTr:=(Ttransaction(stmt.owner).db.findTransaction(killTranRt) as TTransaction);
          if KillTr<>nil then
          begin
            {Check we have privilege}
            if not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and
               not(Ttransaction(stmt.owner).authID=KillTr.authID) and
               not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID) then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Not privileged to cancel a statement using this catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
              {$ENDIF}
              stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to cancel a statement using this catalog']));
              result:=Fail;
              exit;
            end;
            //todo? also check we are connected to the server's primary catalog

            result:=KillTr.Cancel(nil{specific st in future},(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown tran %d',[killTranRt.tranId]),vError);
            {$ENDIF}
            stmt.addError(seSyntaxUnknownTransaction,format(seSyntaxUnknownTransactionText,[killTranRt.tranId]));
            exit; //abort
          end;
        end; {CANCELTRAN}
        ntREBUILDINDEX:
        begin
          result:=RebuildIndex(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {REBUILDINDEX}
        ntSHOWTRANS:    //DEBUG ONLY - TODO REMOVE!
        begin
          result:=Ttransaction(stmt.owner).ShowTrans((Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end; {SHOWTRANS}
        ntBackupCatalog:
        begin
          result:=BackupCatalog(stmt,stmt.sroot,(Ttransaction(stmt.owner).thread as TIdPeerThread).connection);
        end;
        ntOpenCatalog:
        begin
          if Ttransaction(stmt.owner).db=nil then
          begin //without a valid db we won't find the server
            result:=fail;
            stmt.addError(seFail,seFailText);
            exit; //abort
          end;

          {Check we have privilege}
          if (not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and   //not admin
              not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID))  //(and not sys)
             or
             ((Ttransaction(stmt.owner).db<>nil) and {protect in case direct & no db}
              not((Ttransaction(stmt.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(stmt.owner).db)) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to open a catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to open a catalog on this server']));
            result:=Fail;
            exit;
          end;

          newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).addDB(stmt.sroot.leftChild.idVal);
          if newDB<>nil then
          begin
            result:=newDB.openDB(stmt.sroot.leftChild.idVal,False);
            if result<>ok then
            begin
              (Ttransaction(stmt.owner).db.owner as TDBserver).removeDB(newDB); //tidy up after failure
              newDB:=nil;
            end;
          end
          else
            result:=fail;
          if newDB=nil then
          begin
            //try to work out if we failed because the catalog was already open (likeliest) (can't do before because another thread may be just about to add it)
            if (Ttransaction(stmt.owner).db.owner as TDBserver).findDB(stmt.sroot.leftChild.idVal)<>nil then
              stmt.addError(seDatabaseIsAlreadyOpen,seDatabaseIsAlreadyOpenText)
            else
            begin //interpret openDB error
              case result of
                -2: stmt.addError(seCatalogTooNew,seCatalogTooNewText);
                -3: stmt.addError(seCatalogTooOld,seCatalogTooOldText);
                -4: stmt.addError(seCatalogFailedToOpen,seCatalogFailedToOpenText);
                -5: stmt.addError(seCatalogInvalid,seCatalogInvalidText);
              else
                stmt.addError(seFail,seFailText); //general error
              end; {case}
            end;
            exit; //abort
          end;
        end; {ntOpenCatalog}
        ntCloseCatalog:
        begin
          if Ttransaction(stmt.owner).db=nil then
          begin //without a valid db we won't find the server
            result:=fail;
            stmt.addError(seFail,seFailText); 
            exit; //abort
          end;

          {Check we have privilege}
          if (not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and
              not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID))
             or
             not((Ttransaction(stmt.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(stmt.owner).db) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to close a catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to close a catalog on this server']));
            result:=Fail;
            exit;
          end;

          newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).findDB(stmt.sroot.leftChild.idVal); //assumes we're already connected to a db
          if newDB<>nil then
          begin
            if newDB=Ttransaction(stmt.owner).db then
            begin //cannot close our current catalog! //todo can if we disconnect all first?
                  //Note: this means we cannot close the primary catalog since we must be connected to it to get here!
              result:=fail;
              stmt.addError(seCannotCloseCurrentDatabase,seCannotCloseCurrentDatabaseText);
              exit;
            end
            else
            begin
              //todo what if others are connected? - see createCatalog

              {todo: forceably rollback any connections! - e.g. garbage collector}
              newDB.detachAnyTransactions(Ttransaction(stmt.owner));

              result:=(Ttransaction(stmt.owner).db.owner as TDBserver).removeDB(newDB);
            end;
          end
          else
          begin
            result:=fail;
            stmt.addError(seUnknownCatalog,seUnknownCatalogText); //always ok?
            exit; //abort
          end;
        end; {ntCloseCatalog}
        ntGarbageCollectCatalog:
        begin
          if Ttransaction(stmt.owner).db=nil then
          begin //without a valid db we won't find the server
            result:=fail;
            stmt.addError(seFail,seFailText); 
            exit; //abort
          end;

          {Check we have privilege}
          if (not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and
              not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID))
             or
             not((Ttransaction(stmt.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(stmt.owner).db) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to garbage collect a catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to garbage collect a catalog on this server']));
            result:=Fail;
            exit;
          end;

          newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).findDB(stmt.sroot.leftChild.idVal); //assumes we're already connected to a db
          if newDB<>nil then
          begin
            begin
              //todo what if another garbage collector is connected?

              {Start the garbage collector going on this catalog
               Note: it will free itself when its finished (or when the db terminates it on closedown)}
              gc:=TGarbageCollector.Create(newDB);
              //todo gc:=nil?

              if (Ttransaction(stmt.owner).thread as TIdPeerThread).connection<>nil then
               (Ttransaction(stmt.owner).thread as TIdPeerThread).connection.WriteLn(format('Started garbage collector on %s (%s)',[newDB.dbname,gc.tr.Who]));
              {$IFDEF DEBUG_LOG}
              //log.add(stmt.who,where+routine,format('Not privileged to garbage collect a catalog for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
              {$ENDIF}


              result:=ok;
            end;
          end
          else
          begin
            result:=fail;
            stmt.addError(seUnknownCatalog,seUnknownCatalogText); //always ok?
            exit; //abort
          end;
        end; {ntGarbageCollectCatalog}

        ntSHUTDOWN:     //SYSTEM DEBUG ONLY - TODO REMOVE!
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Shutdown requested (%s)',[(Ttransaction(stmt.owner).thread as TCMThread).IP]),vDebugLow);
          log.add(stmt.who,where+routine,format('Shutdown requested (%d)',[longint(Ttransaction(stmt.owner).db){.getInitialConnectdb}]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          {Check we have privilege}
          if (not(Ttransaction(stmt.owner).authAdminRole in [atAdmin]) and   //not admin
              not((not Ttransaction(stmt.owner).connected) and ((Ttransaction(stmt.owner).thread as TCMThread).IP='127.0.0.1'{direct client=server, e.g. monitor})) and //and not connected locally (e.g. monitor)
              not(Ttransaction(stmt.owner).authID=SYSTEM_AUTHID))  //(and not sys)
             or
             ((Ttransaction(stmt.owner).db<>nil) and {protect in case direct & no db}
              not((Ttransaction(stmt.owner).db.owner as TDBserver).getInitialConnectdb=Ttransaction(stmt.owner).db)) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to shutdown for %d',[Ttransaction(stmt.owner).AuthId]),vDebugLow);
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to shutdown this server']));
            result:=Fail;
            exit;
          end;

          result:=-999; //signal server to shutdown //todo debug only - security hole!!!
        end; {SHUTDOWN}


      else
        {There was no plan, but we needed one for this operation - seems like PreparePlan was not called}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('No prepared plan',[nil]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        stmt.addError(seNotPrepared,seNotPreparedText);
        exit; //abort
      end; {case}
    end
    else
    begin
      {Handle operations that do have a plan}
      if not(stmt.sroot.ptree is TIterator) then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Prepared plan pointer is invalid %d',[longint(stmt.sroot.ptree)]),vAssertion);
        {$ENDIF}
        stmt.addError(seNotPrepared,seNotPreparedText);
        exit; //abort
      end;
      //todo since we check ptree is TIterator we can remove AS - speed

      //todo assert algebra tree exists!
      if TAlgebraNodePtr(stmt.sroot.atree)^.anType in [antInto, antInsertion, antUpdate, antDeletion] then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Preparing to execute select-into/insert/update/delete %d',[longint(stmt.sroot.ptree)]),vDebugMedium);
        {$ENDIF}
        begin
          {Find the first parameter with missing data} //todo improve - use fast method of paramList - speed
          nextParam:=stmt.paramList; //todo add interface to this & hide the structure!
          while nextParam<>nil do
          begin
            //todo only if paramType=in/inout?...
            if nextParam.paramSnode.strVal='?' then break; //todo replace '?' with special constant - see sqllex.l
            nextParam:=nextParam.next;
          end;
          if nextParam<>nil then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Missing parameter data %s',[nextParam.paramSnode.idVal]),vDebugLow);
            {$ENDIF}
            result:=strToIntDef(nextParam.paramSnode.idVal,-1); //returns fail if idVal is not a number
          end
          else
          begin
            {Now execute the iterator plan until done, i.e. do all inserts/updates/deletes now en-bloc}
            //note: if user prepares then we give a better performance improvement on
            //      repeated executions. i.e. prepare should call prePlan (& maybe set planActive)
            //      to avoid repetitive/expensive! startup steps, e.g./i.e. privilege/constraint checking

            {Do we need to auto-initiate a transaction now? e.g. client auto-committed & expects us to be able to re-execute!}
            //if we haven't already started a transaction, do so now
            if Ttransaction(stmt.owner).tranRt.tranId=InvalidStampId.tranId then
            begin
              result:=Ttransaction(stmt.owner).Start;
              if result<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Failed to auto-start transaction',[nil]),vDebugError);
                {$ENDIF}
                result:=Fail;
                exit;
              end;
              //ensure stmt keeps up: todo any more places we need to synch. these???
              stmt.fRt:=Ttransaction(stmt.owner).tranRt;

              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Auto-initiating transaction (on re-execution of a statement prepared in a previous transaction!)...',[nil]),vDebugLow); //todo remove
              {$ENDIF}
            end;

            stmt.status:=ssActive;
            result:=TableSubquery(nil{todo: pass system iter+tuple?},(stmt.sroot.ptree as TIterator));
            stmt.status:=ssInactive;
            if result<>ok then
            begin
              //todo avoid getting rowcount if failed here!?
            end;
            //Note: assumes TableSubquery will only fail with -ve return result (else caller will mistake for missing parameter)
            //general note: ensure any results>0 are not passed up the chain unless its safe! else unsuspecting result<>ok will fail...
            {Return the row count} //todo in future insert/update/delete(etc) should inherit from TIteratorNoCursor/Counter... or something...
            case TAlgebraNodePtr(stmt.sroot.atree)^.anType of
              antInsertion:  rowCount:=(stmt.sroot.ptree as TIterStmt).rowCount;
              antUpdate:     rowCount:=(stmt.sroot.ptree as TIterStmt).rowCount;
              antDeletion:   rowCount:=(stmt.sroot.ptree as TIterStmt).rowCount;
            //else (todo?) assertion or ignore rowCount result
            else
              rowCount:=0; //zeroise - may as well!
            end; {case}
            //todo unprepare now? -no! could call execute again!
            //     does the caller have to call CloseCursor now? (no because resultSet was False - assert?)
            //     for now (since we have no cursor to close etc.) we'll set status:=ssInactive above and reset params
            //     - consider calling stmt.closeCursor...
            if stmt.paramList<>nil then stmt.resetParamList;
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format(':  existing plan left prepared (reset any parameters)',[nil]),vDebugMedium);
            {$ENDIF}
          end;
        end
      end {select-into/insert/update/delete}
      else
      begin
        {We have a result-set/cursor to deal with} //todo assert stmt.resultSet=True!
        {plan.start == opening a cursor
         The caller is responsible for always closing the cursor => plan.stop
        }
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Executing query %d',[longint(stmt.sroot.ptree)]),vDebugMedium);
        {$ENDIF}
        if stmt.planActive then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,'Plan has already been executed but is still active (cursor was not closed?). Will continue from existing server cursor position...',vDebugError); 
          {$ENDIF}
          result:=ok; //ok? - may be better to return -1 or something?

        end
        else
        begin
          //todo re-word this next comment: this is the proper execution or re-execution - we don't care which...
          {The originally prepared plan has been stopped via CloseCursor (only?)
           So to re-execute it, we must re-start the plan here since the client doesn't have to re-Prepare
           (that's the whole point of preparing!)

           Note: this might require us to restart a transaction (in case the client auto-committed
           and expects prepared statements to still be available! e.g. dbExpress and JDBC after ODBC)
           - the result of such re-executions with new transactions cannot ensure serialisability etc.
           but that's the stupid client protocol's fault.


           //todo remove this next comment: we've managed to do it using prePlan!...
           (it would be neater if the plan.start was in the execute routine, but we need to open the relations
            at the bottom of the plan to have a chance of defining the final project tuple - and that's what
            the plan.start does)
             - I suppose we could always plan.start in the Prepare routine and then
               plan.stop + plan.start in the execute routine
               - what's the overhead? we only ever prepare once, and opening the relations then is kind of
                 justified by the fact that we have to reference the catalog to build the parse tree
             - I think we're ok as is: if we call start twice, the tree is only completed once (the time-consuming part)
                - we needed this logic anyway for restarting sub-select plans
           }

          //now we know (all/some of) the parameter types/data
          //  call checkParamsSet before starting!
          //  if some missing
          //    planActive=false, i.e. skip next bit
          //    return NEED_DATA to caller
          //(if they could differ (they can:user knows best!) we should really re-start to re-complete the syntax trees
          // so reset all iterselect.treeCompleted now) - ? including all sub-iterselect-nodes... & ALL others??? e.g case c=?...
          // - maybe need usyntax.hasParameters to check each iter's syntax noderef

          //todo Do we need to check this here (2nd time around)? - only if we should reset at-exec params after closeCursor- check spec.
          {Find the first parameter with missing data} //todo improve - use fast method of paramList - speed
          nextParam:=stmt.paramList; //todo add interface to this & hide the structure!
          while nextParam<>nil do
          begin
            //todo only if paramType=in/inout?...
            if nextParam.paramSnode.strVal='?' then break; //todo replace '?' with special constant - see sqllex.l
            nextParam:=nextParam.next;
          end;
          if nextParam<>nil then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Missing parameter data %s',[nextParam.paramSnode.idVal]),vDebugLow);
            {$ENDIF}
            result:=strToIntDef(nextParam.paramSnode.idVal,-1); //returns fail if idVal is not a number
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('(re)starting prepared query plan %d',[longint(stmt.sroot.ptree)]),vDebugMedium);
            {$ENDIF}
            //todo maybe we need to finish off parameters that were filled by PutData, e.g. add \0?
            //todo: (& elsewhere?) if planActive then .restart to close & reset any materialisation - else materialised sub-queries could be kept too long!

            {Do we need to auto-initiate a transaction now? e.g. client auto-committed & expects us to be able to re-execute!}
            //if we haven't already started a transaction, do so now
            if Ttransaction(stmt.owner).tranRt.tranId=InvalidStampId.tranId then
            begin
              result:=Ttransaction(stmt.owner).Start;
              if result<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Failed to auto-start transaction',[nil]),vDebugError);
                {$ENDIF}
                result:=Fail;
                exit;
              end;
              //ensure stmt keeps up: todo any more places we need to synch. these???
              stmt.fRt:=Ttransaction(stmt.owner).tranRt;

              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Auto-initiating transaction (on re-execution of a statement prepared in a previous transaction!)...',[nil]),vDebugLow); 
              {$ENDIF}
            end;

            result:=(stmt.sroot.ptree as TIterator).start;
            if result<>ok then
            begin
              //todo avoid planActive:=True if start failed!?
              exit; //abort
            end;
            stmt.planActive:=True;
            stmt.noMore:=False; //ready for 1st fetch
            stmt.status:=ssActive;
            result:=ok; //todo remove: use result of start!
          end;
        end; {re-execute}
      end; {select}
    end; {planned}

  //todo catch exceptions here?
  finally
  end; {try}
end; {ExecutePlan}

function UnPreparePlan(stmt:Tstmt):integer;
{Delete a prepared plan

 IN:
           tr        transaction  
           stmt      the plan node (sroot is set to the root of the syntax tree/subtree to process)
 OUT:
           stmt      the unprepared plan node (roots set to nil)

 RESULT:     Ok,
             else Fail

 Side-effects:
   the stmtPlan pointers will be reset to nil
}
const routine=':UnPreparePlan';
var
  sroot:TSyntaxNodePtr;   //syntax root
begin
  result:=Fail;
  sroot:=stmt.sroot; 
  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}

  //todo?! plan.stop - since preparePlan will have plan.start
  //- or can we assume cursor has been closed by now?

  //assert stmt.planActive=False!!!!
  if stmt.planActive then
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,'Plan is still active!',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}

  //now clean up and delete all the tree nodes (need a stack?)
  if stmt.paramList<>nil then stmt.DeleteParamList;

  {Delete the syntax tree using the old (pre-CNF split) root}
  //todo* check this root still exists - didn't we 'clean' such a node up during CNF?
  //Note: this code has been copied to TConstraint.destroy
  {$IFDEF DEBUG_LOG}
  //todo debug: if sroot<>nil then log.add(stmt.who,where+routine,format('Deleting syntax tree (%p)...',[sroot]),vDebugMedium);
  if stmt.srootAlloc.allocNext<>nil then log.add(stmt.who,where+routine,format('Deleting syntax tree (%p from %p)...',[stmt.srootAlloc.allocNext,stmt.srootAlloc]),vDebugMedium);
  {$ENDIF}
  //todo debug: DeleteSyntaxTree(sroot);
  DeleteSyntaxTree(stmt.srootAlloc.allocNext);
  stmt.srootAlloc.allocNext:=nil;
  stmt.sroot:=nil;
  //todo remove? debug: //todo reinstate when ExecSQL loop can handle it!   tr.ParseRoot:=nil; //reset parseRoot
  stmt.ParseRoot:=nil; //reset parseRoot
  stmt.ResultSet:=FALSE; //reset resultSet

  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}

  result:=ok;
end; {UnPreparePlan}

end.

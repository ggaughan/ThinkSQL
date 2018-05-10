unit uConstraint;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{This constraint object stores details about a constraint that has yet to be
 checked.
 It containts a mixture of constraint/object reference id's, the current
 state of the transaction/statement/constraint, and details of the
 check plan/execution.

 Initially it is envisaged that 2 lists will be kept:
   one attached to the stmt
     this will be used during an iterInsert/iterUpdate/iterDelete
     and will be cleared down before each one
   one attached to the tran
     this will be used to store deferred constraints during the transaction's life
     and will be cleared down before each one

   if this model works well and is maintainable, maybe try the same scheme
   for handling privileges. By caching against the tran/stmt we might save
   repeated calls for the same checks (although checks are only really done
   once anyway during start/pre-parse)

   if a very long transaction is used, many constraint objects will be created
   and tagged to the transaction. This will gather memory. Maybe for not ctRow
   constraints we should defer lookup of their details until they are checked
   - until then we just store the constraint_id and constraint_time references.

 Note:
   constraints (PK/FK/unique only) are also looked up and attached to each relation
   as it is opened - these are used for query optimisation and store lightweight details
   of static relationships which are never used for constraint checking, so the two structures
   have been developed separately. In future, the lookup routines here could reference
   information from the relation to save lookup time (at the expense of storing more detailed
   constraint information for every open relation).
}

{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3}  //log check sub-queries
{$DEFINE DEBUGDETAIL4}  //log check successes
//{$DEFINE DEBUGDETAIL5}  //constraint ignoring
{$DEFINE DEBUGDETAIL6}   //show constraint sql
//{$DEFINE DEBUGDETAIL7}   //show set constraints
//{$DEFINE DEBUGDETAIL8}   //show constraint check-timings

{$DEFINE SAFETY}  //use assertions
                  //Note: Should be no reason to disable these, except maybe small speed increase & small size reduction
                  //      Disabling them would cause more severe crashes (access violations) if an assertion fails
                  //      - at least with them enabled, the server will generate an assertion error message
                  //        and should abort the routine fairly gracefully
                  //      so if they are ever turned off, the code should be thoroughly re-tested and the limits
                  //      stretched to breaking

interface

uses uGlobal, uSyntax {removed uTuple because of circularity}, uStmt;

type
  TconstraintTime=(ctNever,       //ignore, e.g. list header node, or null match in override list
                   ctRow,         //immediate (next: before each row is inserted/updated)
                   ctStmt,        //immediate (stop: after all rows have been inserted/updated)
                   ctTran         //deferred (commit: just before transaction commit)
                  );

  TconstraintEnd=(ceParent,       //only check parent->child, i.e. FK delete/pre-update parent
                  ceChild,        //only check child(->parent), i.e. all others
                  ceBoth);        //check both ends, i.e. tran level

  TconstraintCreator=(ccUnknown,
                      ccInsert,
                      ccDelete,
                      ccUpdate,
                      ccStandalone{e.g. Alter Table check});

  TconstraintAction=(caSelect, //=restrict/none
                     caDelete,
                     caUpdateSetNull,
                     caUpdateSetDefault,
                     caUpdate);

  TconstraintColumn=class  //note: this will be similar to a tuple's colDef array... merge structures in future?
  private
    name:string;
    id:word; //used to compare with update list
    sequence:integer; //used to keep in key order
    next:TconstraintColumn;
  end; {TconstraintColumn}

  Tconstraint=class
  private
    fTableId:integer;     //initially =child table_id for FKs, i.e. constraint not RI action: ++ could be parent for RI action
    fTableName:string;    //used for SQL generation during stmt/tran checking (pass from caller)
    fColumnId:integer;    //0 => null => table-level owner
    fSchemaName:string;   //used for SQL generation during stmt/tran checking (pass from caller) relation in-memory definition

    fCreator:TconstraintCreator; //we record this for FK parent cascade-time (update or delete)
    fAction:TconstraintAction;

    //note: keep in sync. with sysConstraint table definition
    fConstraintId:integer;
    fConstraintName:string;
    fDeferrable:boolean;
    fInitiallyDeferred:boolean;
    fRuleType:TconstraintRuleType;
    fRuleEnd:TconstraintEnd; //which end are we? ceChild=default but could be ceParent for FK parent end check
    fRuleCheck:string;
    fFKparentTableId:integer;
    fFKchildTableId:integer;
    fFKmatchType:TconstraintFKmatchType;
    fFKonUpdateAction,fFKonDeleteAction:TconstraintFKactionType;

    //store sysConstraintColumn info for Primary/Unique/Foreign keys
    fChildColumn:TconstraintColumn;
    fParentColumn:TconstraintColumn;
    fFKotherTableName:string; //used for SQL generation during stmt/tran checking

    fConstraintTime:TconstraintTime;
    fConstraintIsolation:Tisolation;

    sroot:TSyntaxNodePtr;         //syntax root
                                  //Note: will link to atree and to ptree if algebra/iterator trees added
                                  //Note+: this will have been prepared/created against a particular system stmt,
                                  //       e.g. sysStmt2, and so when executed the iterator plan will refer back
                                  //       to use that stmt (so we first reset the stmt's Rt before execution)
                                  //Note:++ this is used to save & restore stmt.sroot to allow multiple use
    stmt:TStmt;                   //stmt used to prepare/execute the constraint (will be shared for non-nested ones)

    fWt:StampId; //read/write as timestamp (used to write optimistically and atomically)
                 //this will be used to filter our checking to just those rows affected = speed

    fNext:Tconstraint;
  public
    property constraintId:integer read fConstraintId write fConstraintId;
    property tableId:integer read ftableId write ftableId;
    property columnId:integer read fcolumnId write fcolumnId;

    property deferrable:boolean read fdeferrable write fdeferrable;
    property initiallyDeferred:boolean read finitiallyDeferred write finitiallyDeferred;
    property constraintTime:TconstraintTime read fconstraintTime write fconstraintTime;
    property constraintIsolation:Tisolation read fconstraintIsolation write fconstraintIsolation;

    property next:Tconstraint read fnext write fnext;

    constructor Create(st:Tstmt;schema_name:string;table_id:integer; table_name:string; column_id:integer;
                       constraintTuple:TObject{TTuple}; actuallyDeferred:boolean;
                       thisWt:StampId;creator:TconstraintCreator;constraint_end:TconstraintEnd);
    destructor Destroy; override;

    function lookupColumnDetails(st:Tstmt; table_id:integer; column_id:integer; col:TconstraintColumn):integer;
    procedure insertColumn(parent:boolean;column:TconstraintColumn);

    function chainNext(newOne:Tconstraint):integer;
    function clearChain:integer;
    procedure listChain(st:Tstmt);
    function existsInChain(table_id:integer; column_id:integer; constraint_id:integer; constraint_end:TconstraintEnd):integer;

    function check(st:Tstmt;iter:TObject{TIterator};var Valid:TriLogic):integer;
    function checkChain(st:Tstmt;iter:TObject{TIterator};constraint_time:TconstraintTime;constraint_end:TconstraintEnd):integer;

  end; {Tconstraint}



function AddTableColumnConstraints(st:Tstmt;iter:TObject{TIterator};
                                   schema_name:string;
                                   table_id:integer;table_name:string;column_id:integer;creator:TconstraintCreator):integer;

function SetConstraints(st:Tstmt;nmode,nroot:TSyntaxNodePtr):integer;

{Only used externally for checking a newly added constraint:}
function AddConstraint(st:Tstmt;iter:TObject{Titerator};
                       schema_name:string;
                       table_id:integer; table_name:string; column_id:integer;
                       constraint_id:integer;creator:TconstraintCreator;
                       constraint_end:TconstraintEnd):integer;

var
  debugConstraintCreate:integer=0;
  debugConstraintDestroy:integer=0;

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  uTransaction, uTuple, sysUtils, uRelation,
     //next are needed to build and process check-plans
     uAlgebra, uIterator, uParser, uOptimiser, uProcessor,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}
     ;

const
  where='uConstraint';
  who='';

  {$IFDEF DEBUG_LOG}
  {Constraint end type values}
  ConstraintEndString:array [ceParent..ceBoth] of string=('Parent end','Child end','Both ends');
  {$ENDIF}

constructor Tconstraint.create(st:Tstmt;
                               schema_name:string;
                               table_id:integer; table_name:string; column_id:integer;
                               constraintTuple:TObject{TTuple}; actuallyDeferred:boolean;
                               thisWt:StampId;creator:TconstraintCreator;constraint_end:TconstraintEnd);
{IN       tr          transaction
                      only needed for constraint column lookups, i.e. primary/unique/foreign-key
                      else can be nil
          ...
          actuallyDeferred
                      caller sets this since it might override the setting based on any
                      user SET CONSTRAINTS for this transaction. True=deferred, False=immediate
          ...
          creator     contraint creator, e.g. insert/update/delete
                       - used to determine whether we can optimise physical check-time or not
          constraint_end ceParent = parent end of FK, else n/a (or child)

 Note:
   If, for any reason, the child/parent constraint columns cannot be read then
   we set the constraint's constraint-time to ctNever. This is the best we can
   currently do to prevent the caller from using the bad constraint.
   It leaves a loophole though! - warn the caller to abort, either by
   passing a bad-flag or get caller to always check if constraint-time=ctNever
   after creation.

   No constraint should need an index to make it work:
   The fact that most constraints (unique/primary/foreign-key) will use indexes
   to make their performance acceptable is due to the caller adding them, and the
   sub-routines called during constraint checking being able to use them if they exist.

 This is tied to the sysConstraint definition:
 it copies the tuple information into the object fields
 Maybe in future it would be better to just store the constraint tuple RID
 and with clever caching, we can retrieve data from the buffers.
 But constraints may not be checked until the end of a large statement, or
 even deferred until the end of a long transaction, so why pin lots of constraint
 pages when we can just cache the row data we need now.

 In most cases we are reading the constraints for the child table and lookup the parent
 table name for future reference (insert/update). However we also lookup constraints for parent tables
 and need to then lookup the child table name for future reference (delete). We tell the
 difference by comparing table_id with the child/parent table id.
}
const routine=':create';
var
  dummy_null:boolean;
  dummy_string,parent_or_child_table:string;
  dummy_integer,FKtableId:integer;

  tras:TTransaction;
  sysConstraintColumnR, sysTableR:TObject; //Trelation
  columnNode:TconstraintColumn;
begin
  inc(debugConstraintCreate);
  {$IFDEF DEBUG_LOG}
  if debugConstraintCreate=1 then
    log.add(who,where,format('  Constraint memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}

  {Record owner}
  fTableId:=table_id;
  fTableName:=table_name;
  fSchemaName:=schema_name;
  fColumnId:=column_id; //may be 0 => null => table-level constraint

  fCreator:=creator;
  fAction:=caSelect; //presume default

  sroot:=nil;
  stmt:=nil;
  fWt:=thisWt;

  if constraintTuple<>nil then
  begin
    {Record constraint definition}
    //note: keep in sync. with sysConstraint table definition
    with (constraintTuple as TTuple) do
    begin
      GetInteger(ord(sco_constraint_id),fconstraintId,dummy_null);
      GetString(ord(sco_constraint_name),fconstraintName,dummy_null);
      GetString(ord(sco_deferrable),dummy_string,dummy_null);
      if dummy_string=Yes then fdeferrable:=True else fdeferrable:=False;
      GetString(ord(sco_initially_deferred),dummy_string,dummy_null);
      if dummy_string=Yes then finitiallyDeferred:=True else finitiallyDeferred:=False;
      GetInteger(ord(sco_rule_type),dummy_integer,dummy_null);
      fRuleType:=TconstraintRuleType(dummy_integer);
      fRuleEnd:=ceChild; //default
      if (fRuleType=rtForeignKey) and (constraint_end=ceParent) then fRuleEnd:=ceParent; //we are parent end of FK
      GetString(ord(sco_rule_check),fRuleCheck,dummy_null);
      GetInteger(ord(sco_FK_parent_table_id),fFKparentTableId,dummy_null);
      //Note: we lookup the name of this parent tableId later in this routine...
      GetInteger(ord(sco_FK_child_table_id),fFKchildTableId,dummy_null);
      GetInteger(ord(sco_FK_match_type),dummy_integer,dummy_null);
      fFKmatchType:=TconstraintFKmatchType(dummy_integer);
      GetInteger(ord(sco_FK_on_update_action),dummy_integer,dummy_null);
      fFKonUpdateAction:=TconstraintFKactionType(dummy_integer);
      GetInteger(ord(sco_FK_on_delete_action),dummy_integer,dummy_null);
      fFKonDeleteAction:=TconstraintFKactionType(dummy_integer);
    end; {with}

    //note: can remove these 2 redundant statements- speed
    {Deduce the constraint check time}
    fConstraintTime:=ctStmt; //immediate, at end of statement
    if finitiallyDeferred then fConstraintTime:=ctTran; //deferred until transaction commit

    {Note: whatever the constraint time, we now override it by what the caller has passed!}
    if actuallyDeferred then
      fConstraintTime:=ctTran
    else
      fConstraintTime:=ctStmt;

    //note: depending on the type of constraint and the type of action about to be performed (creator)
    //      bring forward the constraint time to ctRow - i.e. check before each insertion/update
    //      This will save loads of time/garbage space in many cases, e.g.
    //        insert + check (but not table-level check?)
    //        insert + FK where not self-related
    //        insert + PK, UK  (aborts early but sometimes may be faster to leave till stmt (=1 big check) if inserting loads?? when?)
    //        update + check where only column related
    //        update + PK, UK (& FK if not self related) where not updating key fields (aborts early but sometimes may be faster to leave till stmt (=1 big check) if updating loads?? when?)
    //        etc. - may be easier to specify those that must be moved to ctStmt...
    //        for now, we'll leave everything until the end of the stmt - no need to move earlier except speed/garbage
    //                             except...
    //                             PK/UK for early abort to save wasting space
    //                                       and because UK stmt is not currently correct for nulls (small fix needed)
    //        ++ now we have creator this has been refined since the comments above...
    case creator of
      ccStandalone:
      begin
        fConstraintTime:=ctStmt; //caller wants to check this constraint now, e.g. alter table add constraint validation
                                 //note: this overrides any actuallyDeferred setting!
      end; {ccStandalone}
      ccUpdate:
      begin //ccUpdate (note: if constrained columns are not to be updated, this constraint will be ignored later)
        //else we can't currently ignore existing rowID in check, so update PK/UK checks must be left at stmt
        // - although this might be quicker for bulk update PK/UK checks
        //   but the drawback is that we might write many invalid changes before rejecting them all...
        //   -so ASAP guess whether mass or small update & pick ctRow if appropriate & when possible
        //   ++ also drawback is that 'not match' is used = no index => full source table scan!
        // - ++ although how would ignoring existing rowID in check help updates?
        //      surely tpk(1)(2)(3) updated to set pk=pk+abs(pk-2) would update to tpk(2)(2)(2)
        //      & *how could we know in advance* that there will be a problem but not if
        //      set pk=pk+1 to give tpk(2)(3)(4) ? If ctRow, both would choke on 1st row update (1)->(2)=duplicate pk
        //      a) if WHERE = pk/indexed then ok to do ctRow, i.e. know only 1 row
        //      b) if FK & not self-ref, should be safe: 16/04/02 so that's what we do...
        //      c) if check, should be safe - make sure not table-level check
        //   +++ I think checking at stmt time for a retained list of updated rowIDs might improve speed/filter
        if fConstraintTime=ctStmt then
        begin
          if fRuleType=rtCheck then fConstraintTime:=ctRow; //note: only if table_id<>0 i.e. table-level or less...

          //note debug only!
          if fRuleType=rtForeignKey then
            if fFKparentTableId<>fFKchildTableId then {not self-referencing (else could be updating child before parent->defer)}
              fConstraintTime:=ctRow;
        end;

        {Note: the difference between ctRow and ctStmt is purely physical. From the user's (logical) point
         of view there is no difference in behaviour}
      end; {ccUpdate}
    else //rest, e.g. insert, delete
      if fConstraintTime=ctStmt then
      begin
        //note: only can be sure no logic-change if inserting!?
        if fRuleType=rtCheck then fConstraintTime:=ctRow; //note: only if table_id<>0 i.e. table-level or less...

        if fRuleType=rtForeignKey then
          if (creator<>ccInsert)
          or ((creator=ccInsert) and (fFKparentTableId<>fFKchildTableId)) then {not insert self-referencing (else could be inserting child before parent->defer to stmt end)}
            fConstraintTime:=ctRow;
      end;
      {Note: the difference between ctRow and ctStmt is purely physical. From the user's (logical) point
       of view there is no difference in behaviour}
    end; {case}

    {Note:
     caller must ensure FK actions at parent end remain at ctRow level & not deferred
    }

    {Now lookup and store sysConstraintColumn info for Primary/Unique/Foreign keys}
    //      (note: if these column names change during our stmt/tran then check we survive)
    //note: in future store colRefs=speed? although at moment parse will re-lookup once only
    fChildColumn:=nil;
    fParentColumn:=nil; //again, technically no need, but I feel better/more portable
    if fRuleType in [rtPrimaryKey,rtUnique,rtForeignKey] then
    begin //we must have some additional column info
      tras:=Ttransaction(st.owner);

      if tras.db.catalogRelationStart(st,sysConstraintColumn,sysConstraintColumnR)=ok then
      begin
        try
          //note: assumes we have best index/hash on scc_constraint_id, but may not be the case
          if tras.db.findFirstCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),fconstraintId)=ok then
            try
              repeat
                {Found another matching constraint column id}
                with (sysConstraintColumnR as TRelation) do
                begin
                  fTuple.GetString(ord(scc_parent_or_child_table),parent_or_child_table,dummy_null);
                  {Add child/parent column node}
                  //todo: assert if fRuleType<>rtForeignKey then parent_or_child_table<>ctParent
                  columnNode:=TconstraintColumn.create;
                  fTuple.GetInteger(ord(scc_column_sequence),columnNode.sequence,dummy_null);
                  fTuple.GetInteger(ord(scc_column_id),dummy_integer,dummy_null);
                  if parent_or_child_table=ctParent then
                  begin
                    FKtableId:=fFKparentTableId;
                  end
                  else FKtableId:=fFKchildTableId;
                  //note: this lookup could be faster. Currently it re-scans for every constraint column!
                  //      in most cases this will be looking for child columns, so we could use the caller's rel-ref? -speed
                  //      We originally just looked up the columns we need to save time (since only a few would be
                  //      in the key), but in fact the way it's currently implemented probably means opening
                  //      the parent/child relation here would be faster:
                  //      we'd do one scan to load all column-defs and we can guarantee that we have
                  //      only a parent/child table to look at, e.g. can't 'references table1(a),table2(b) etc!'
                  //       -speed
                  //      especially since we need to lookup the parent tableName around here...
                  if lookupColumnDetails(st,FKtableId,dummy_integer,columnNode)<>ok then
                  begin //lookup failed
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Failed reading a constraint column (%d) - will disable this constraint',[dummy_integer]),vError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    columnNode.free; //remove half-used garbage
                    fConstraintTime:=ctNever; //todo: improve on this error handling!? i.e. prevent caller from proceeding!
                                              // or at least get caller to recognise that this new constraint is disabled
                    exit; //abort
                  end
                  else //ok, add to appropriate list
                    insertColumn((parent_or_child_table=ctParent),columnNode);
                end; {with}
              until (tras.db.findNextCatalogEntryByInteger(st,sysConstraintColumnR,ord(scc_constraint_id),fconstraintId)<>ok);
                    //todo stop when there are no more matching this id
            finally
              if tras.db.findDoneCatalogEntry(st,sysConstraintColumnR)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysConstraintColumn)]),vError);
                {$ELSE}
                ;
                {$ENDIF}
            end; {try}
          //else no constraint column(s) for this table found
        finally
          if tras.db.catalogRelationStop(st,sysConstraintColumn,sysConstraintColumnR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysConstraintColumn)]),vError); //todo abort? fix! else possible server crunch?
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

      {Check we succeeded}
      if (fChildColumn=nil) or ((fRuleType=rtForeignKey) and (fParentColumn=nil)) then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed reading constraint columns - will disable this constraint',[nil]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        fConstraintTime:=ctNever; //todo: improve on this error handling!? i.e. prevent caller from proceeding!
                                  // or at least get caller to recognise that this new constraint is disabled
      end;

      {Now we also need the parent or child (other) relation name if this is a foreign key constraint}
      //todo use a common routine to find this? = neater code
      //todo: also we need to ensure we get a complete table name- i.e. including the schema name!
      if fRuleType=rtForeignKey then
      begin
        fFKotherTableName:='';
        if fRuleEnd=ceChild then FKtableId:=fFKparentTableId else FKtableId:=fFKchildTableId;
        //todo assert table_id = parent or child!
        if tras.db.catalogRelationStart(st,sysTable,sysTableR)=ok then
        begin
          try
            if tras.db.FindCatalogEntryByInteger(st,sysTableR,ord(st_table_id),FKtableId)=ok then
            begin
              with (sysTableR as TRelation) do
              begin
                fTuple.GetString(ord(st_table_name),fFKotherTableName,dummy_null);
                //todo: get the schema name! else will only be able to FK check within current schema! - check spec.!
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found other relation %s in %s',[fFKotherTableName,sysTable_table]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
              end; {with}
            end;
            //else table not found
          finally
            if tras.db.catalogRelationStop(st,sysTable,sysTableR)<>ok then
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

        if fFKotherTableName='' then
        begin  //lookup failed
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed reading a constraint other relation (%d) - will disable this constraint',[fFKparentTableId]),vError);
          {$ELSE}
          ;
          {$ENDIF}
          fConstraintTime:=ctNever; //todo: improve on this error handling!? i.e. prevent caller from proceeding!
                                    // or at least get caller to recognise that this new constraint is disabled
          exit; //abort
        end;
      end; {other relation name}

    end; {have constraint column definitions}


    {Deduce the constraint isolation}
    fConstraintIsolation:=isReadCommitted; //i.e. we cannot ignore committed data, even if transaction does!
                                           // similarly, we cannot rely on uncommitted data, even if transaction does! //not an issue if uncommitted=>read-only
    if fRuleType=rtPrimaryKey then fConstraintIsolation:=isReadUncommitted; //dirty, but safe (alternative would be to wait for commit/rollback, but better for user to decide to try later or another key?)
    if fRuleType=rtUnique then fConstraintIsolation:=isReadUncommitted; //dirty, but safe (alternative would be to wait for commit/rollback, but better for user to decide to try later or another key?)
    if fRuleType=rtForeignKey then //depends on which direction we're checking, but we take the general approach of treating uncommitted deletions/insertions as if they will be committed
    begin
      {Note: these now ignore our own uncommitted deletions/insertions to allow (e.g) cascading deletes/updates on self-referencing table:
         e.g. stmt-level FK check should ignore our deleted children but consider other transaction's uncommitted deletions in parent table
      }
      if fRuleEnd=ceChild then //if child insert/update checking for parent, e.g. don't allow inserts that reference a parent that's been deleted - even if it's not been committed yet
        fConstraintIsolation:=isReadCommittedPlusUncommittedDeletions //sees others dirty deletions, but not dirty insertions =safe(alternative would be to wait for commit/rollback, but better for user to decide to try later or another key?)
      else //if parent delete checking for children, e.g. don't allow deletes that reference a child that's been deleted if it's not been committed yet
        fConstraintIsolation:=isReadUncommittedMinusUncommittedDeletions; //sees others dirty insertions, but not dirty deletions =safe(alternative would be to wait for commit/rollback, but better for user to decide to try later or another key?)
    end;

    //note: avoid checking if no use: e.g. if delete, no point primary/unique/foreign-key (except trigger) etc.
    //                                e.g. if update, no point primary/unique/foreign-key if those columns aren't being modified
    //                                e.g. if insert, no point primary/unique if those columns are defaulting to generator values...
    //note++ we do this in addConstraint...
    //       - done for update already...
    //       - do for insert (as for update?)
    //       - don't do for delete - checkChain ignores the appropriate end of FK checks
  end
  else //must be a dummy list-head node
  begin
    fConstraintTime:=ctNever; //ignore
    //leave rest as default, i.e. 0/nil
  end;
end; {create}

destructor Tconstraint.Destroy;
const routine=':Destroy';
var
  columnPtr:TconstraintColumn;
begin
  {Release any constraint column structures}
  while fChildColumn<>nil do
  begin
    columnPtr:=fChildColumn;
    fChildColumn:=fChildColumn.next;
    columnPtr.free;
  end; {while}
  while fParentColumn<>nil do
  begin
    columnPtr:=fParentColumn;
    fParentColumn:=fParentColumn.next;
    columnPtr.free;
  end; {while}


  {Release anything attached to sroot, e.g. syntax/algebra/iterator trees
   - code take from unPreparePlan routine}
  {Delete the syntax tree using the old (pre-CNF split) root}
  //todo check this root still exists - didn't we 'clean' such a node up during CNF?
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  if sroot<>nil then log.add(who,where+routine,format('Deleting syntax tree (%p)...',[sroot]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}
  //note debug: DeleteSyntaxTree(sroot);
  if stmt<>nil then
  begin
    DeleteSyntaxTree(stmt.srootAlloc.allocNext);
    stmt.srootAlloc.allocNext:=nil;
  end;
  sroot:=nil;
  stmt:=nil; //no need...

  inc(debugConstraintDestroy);

  inherited;
end; {Destroy}

//note: move to a more common unit? e.g. uRelation?
function Tconstraint.lookupColumnDetails(st:Tstmt; table_id:integer; column_id:integer; col:TconstraintColumn):integer;
{Lookup column details from its reference

 OUT:     col = TconstraintColumn with updated:
                  name
                  id
 RETURNS: ok=found, else fail=not found

 //todo make very fast!
}
const routine=':lookupColumnDetails';
var
  dummy_integer:integer;
  dummy_null:boolean;

  tras:TTransaction;

  sysColumnR:TObject; //Trelation
begin
  result:=fail;

  tras:=Ttransaction(st.owner);

  if tras.db.catalogRelationStart(st,sysColumn,sysColumnR)=ok then
  begin
    try
      //note: use future relation.Find() method
      if tras.db.findFirstCatalogEntryByInteger(st,sysColumnR,ord(sc_table_id),table_Id)=ok then
        try
          repeat
            {Found another matching column for this relation}
            with (sysColumnR as TRelation) do
            begin
              fTuple.GetInteger(ord(sc_column_id),dummy_integer,dummy_null);
              if dummy_integer=column_id then
              begin
                col.id:=dummy_integer;
                fTuple.GetString(ord(sc_column_name),col.name,dummy_null); //assume never null
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found column %s in %d with id=%d',[col.name,table_id,col.id]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                result:=ok;
                exit; //success
              end;
            end; {with}
          until tras.db.findNextCatalogEntryByInteger(st,sysColumnR,ord(sc_table_id),table_Id)<>ok;
                //todo stop once we're past our table_id if sysColumn is sorted... -speed - this logic should be in Find routines...
        finally
          if tras.db.findDoneCatalogEntry(st,sysColumnR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysColumn)]),vError);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else table has no columns = assertion?
    finally
      if tras.db.catalogRelationStop(st,sysColumn,sysColumnR)<>ok then
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
end; {lookupColumnDetails}

procedure Tconstraint.insertColumn(parent:boolean;column:TconstraintColumn);
{Inserts a constraint column node into the child or parent list in sequence order
 IN:     parent              True=add to parent list
                             False=add to child list
         column              the constraint column node to add
}
var
  trailNode,ptr:TconstraintColumn;
begin
  trailNode:=nil;
  if parent then ptr:=fParentColumn else ptr:=fChildColumn;
  {Traverse until we find the correct position}
  while (ptr<>nil) and (ptr.sequence<column.sequence) do //assumes short-circuit
  begin
    trailNode:=ptr;
    ptr:=ptr.next;
  end; {while}
  
  if trailNode=nil then
  begin //empty or 1st node has larger sequence, i.e. we're the new head
    column.next:=ptr;
    if parent then fParentColumn:=column else fChildColumn:=column;
  end
  else
  begin
    column.next:=ptr;
    trailNode.next:=column;
  end;
end; {insertColumn}

function Tconstraint.chainNext(newOne:Tconstraint):integer;
{Chains a new constraint node to an existing constraint list

 Assumes newOne is a singleton, i.e. has no next list

 Note:
   currently inserts at the head of the list, just after this(self) node
   (so maybe use a dummy head to keep ordering)

   - in future may be better to ensure latterly added constraints are
     checked last - they tend to be less restrictive & we would be faster
     checking the most restrictive ones first = speed

 RESULT: ok, else fail
}
const routine=':chainNext';
begin
  result:=ok;

  if newOne.next<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'new constraint node has a next list (assumed to be singleton) - not linked',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
  end;

  newOne.next:=self.next;
  self.next:=newOne;
end; {chainNext}

function Tconstraint.clearChain:integer;
{Clears down a constraint list, leaving this head node
}
{$IFDEF DEBUGDETAIL}
const routine=':clearChain';
{$ENDIF}
var
  constraintNode:Tconstraint;
  {$IFDEF DEBUGDETAIL}
  count:integer;
  {$ENDIF}
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  count:=0;
  {$ENDIF}

  while self.next<>nil do
  begin
    constraintNode:=self.next;
    self.next:=constraintNode.next;
    constraintNode.free;
    {$IFDEF DEBUGDETAIL}
    inc(count);
    {$ENDIF}
  end;

  {$IFDEF DEBUGDETAIL}
  if count>0 then
  begin
    {$IFDEF DEBUG_LOG}
    log.status; //memory display
    {$ELSE}
    ;
    {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Cleared %d constraint(s) from list',[count]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
  end;
  {$ENDIF}
end; {clearChain}


//note: debug only
procedure Tconstraint.listChain(st:Tstmt);
const routine=':listChain';
var
  node:Tconstraint;
  columnNode:TconstraintColumn;
  s:string;
begin
  node:=self;
  while node<>nil do
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('%d:%d %d=%s (%s %s %s) at %d',[node.fTableId,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
    {$ENDIF}
    s:='';
    columnNode:=node.fChildColumn;
    while columnNode<>nil do
    begin
      s:=s+format('(%d)%s,',[columnNode.sequence,columnNode.name]);
      columnNode:=columnNode.next;
    end; {while}
    {$IFDEF DEBUG_LOG}
    if s<>'' then log.add(st.who,where+routine,format('   Child columns:%s',[s]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    s:='';
    columnNode:=node.fParentColumn;
    while columnNode<>nil do
    begin
      s:=s+format('(%d)%s,',[columnNode.sequence,columnNode.name]);
      columnNode:=columnNode.next;
    end; {while}
    {$IFDEF DEBUG_LOG}
    if s<>'' then log.add(st.who,where+routine,format('   Parent columns:%s',[s]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}

    node:=node.next;
  end;
end; {listChain}


function Tconstraint.check(st:Tstmt;iter:TObject{TIterator};var Valid:TriLogic):integer;
{Check this constraint

 IN:      st                   statement  (used to find appropriate system stmt)
          iter                 iterator from caller
                               - used for fast row-level checking (if not row-level checking, can pass nil)

 OUT:
          valid                isTrue
                               isUnknown
                               isFalse

                               note: we only currently return isTrue or isFalse so use boolean? speed

 RESULT: ok, else fail=error

 Assumes:
   the caller has checked the fConstraintTime of this constraint is appropriate before calling

   iter is not nil if this is a row-time constraint

 Note:
   if this constraint node has not been checked before, its plan will be prepared
   and stored in the node so that any repeated checks will be faster. (only applies to ctRow)
   Such plan information will be cleaned up when the constraint node is destroyed.

   Keep in sync. with CreateConstraint routine.

   We use the transaction's getSpareStmt() to plan the lookups
   this should be ok here because:
       we are serial on the same transaction because we use the same thread
          so no synchronisation issues, i.e. if a stmt is inactive it is spare for us

   iterDelete could be the caller in which case FK checks will only be checking that the
   child referencer does not exist (else restrict/cascade etc.)
   iterUpdate could also check this way round ('this end')
}
const routine=':check';
var
  tras:TTransaction; 

  {only used for initial prepare}
  sqlText:string;

  saveStmtRt:StampId;
  saveTranIsolation:Tisolation;

  //noMore:boolean;
  res:string;
  res_null:boolean;

{$IFDEF Debug_Log}
  {$IFNDEF DEBUGDETAIL3}
  saveLogVerbosity:vbType;
  {$ENDIF}
{$ENDIF}  

  FKchildCol,FKparentCol:TconstraintColumn;

  newChildParent:TIterator;
  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  start,stop:TdateTime;
  h,m,sec,ms:word;
  {$ENDIF}
  {$ENDIF}
begin
  result:=fail;

  Valid:=isFalse; //default (may be inverted by some constraint checks, i.e. no rows=valid)

  {$IFDEF SAFETY}
  if (fConstraintTime=ctRow) and (iter=nil) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Row-time constraint (%d) can only be checked if given a context',[fConstraintId]),vAssertion);
    {$ENDIF}
    exit; //abort
    {Note: although we could get by, e.g. treat as for ctStmt
     but bad performance: full scans per .next loop
    }
  end;
  {$ENDIF}

  {$IFDEF DEBUGDETAIL8}
  {$IFDEF DEBUG_LOG}
  start:=now;
  {$ENDIF}
  {$ENDIF}

  tras:=Ttransaction(st.owner);

  sqlText:=''; //note remove: technically should be no need - speed?

  //todo assert constraintTime is appropriate, and ignore any that aren't
  //     - this is the caller's duty, but double check ifdef safety!
  //     ignore if ctNever  -caller does this

  //todo replace 'DUMMY' with a constant & 'sysInternal' or something better: _DUMMY should be good or _CHECK
  //       also try and remove subselects, as per unique:ctRow
  {Allocate a spare stmt to be used to prepare and execute this constraint
   (the idea is that any nested constraint will create a new system stmt since
    the parent/initiator is not spare because it already has a plan attached.
    Non-nested constraints will share the same stmt)
  }
  if stmt=nil then
  begin
    if tras.getSpareStmt(stSystemConstraint,stmt)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Failed getting spare constraint stmt',[nil]),vAssertion);
      {$ENDIF}
      result:=Fail;
      exit;
    end;
  end;

  if sroot=nil then
  begin
    {Check which kind of rule we're dealing with}
    case fRuleType of
      rtUnique:
      begin
        case fConstraintTime of
          //note: neater to use common prefix...upto WHERE & then add appropriate clause
          ctRow:
          begin //we can implicitly use the context = fast (but we need to alias-mask self table to avoid name ambiguity)
            //we can assume that the table is valid before we start, so we need only check that this
            //  row will not cause a duplication

            //Aim: SELECT 'N' FROM fTableName AS DUMMY WHERE (DUMMY.c1=fTableName.c1 AND DUMMY.c2=fTableName.c2)
            //Note: iterRelation optimiser assume DUMMY is on left of =  -keep in sync.
            //note: assumes fTableName is not DUMMY
            sqlText:='SELECT ''N'' FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY WHERE (';
            //Note: default Valid will be inverted
            {Children}
            FKchildCol:=fChildColumn;
            while FKchildCol<>nil do
            begin
              sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"="'+fTableName+'"."'+FKchildCol.name+'"';
              FKchildCol:=FKchildCol.next;
              if FKchildCol<>nil then sqlText:=sqlText+' AND ';
            end;

            sqlText:=sqlText+')';

            {Note: we have an optimisable sub-select because the SARGs will be an index
             Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
             Note: nulls never match =, and so never cause the unique test to return N
            }
          end; {ctRow}
          ctStmt,ctTran:
          begin //we must explicitly give the table
            //Aim: SELECT 'Y' FROM (VALUES(1)) AS DUMMY WHERE UNIQUE (SELECT c1,c2 FROM fTableName)
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY WHERE ';
            sqlText:=sqlText+'UNIQUE ( SELECT ';
            {Children}
            FKchildCol:=fChildColumn;
            while FKchildCol<>nil do
            begin
              sqlText:=sqlText+'"'+FKchildCol.name+'"'; //note: add explicit prefix - findcol speed
              FKchildCol:=FKchildCol.next;
              if FKchildCol<>nil then sqlText:=sqlText+',';
            end;
            sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fTableName+'")';
          end; {ctStmt,ctTran}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Constraint time %d not handled, ignoring...',[ord(fConstraintTime)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY';
        end; {case}
      end; {rtUnique}
      rtPrimaryKey:
      begin
        //Note: same as for rtUnique but with NOT NULL
        //       remove need to NOT NULL checks by enforcing NOT NULL on PK columns!
        //       i.e. check not null can be assumed to be there! (or remove 'check not null' from PK columns?)
        case fConstraintTime of
          ctRow:
          begin //we can implicitly use the context = fast (but we need to alias-mask self table to avoid name ambiguity)
            //we can assume that the table is valid before we start, so we need only check that this
            //  row will not cause a duplication

            //Aim: SELECT 'N' FROM fTableName AS DUMMY WHERE (DUMMY.c1=fTableName.c1 AND DUMMY.c2=fTableName.c2)
            //Note: iterRelation optimiser assume DUMMY is on left of =  -keep in sync.
            //        leave not null checking to other clause - otherwise using an OR here prevents us from using an index!
            //        i.e. creating PK creates PK + check(NOT NULL) is assumed/asserted/done on each column
            //improve: faster to use MATCH or something to compare whole tuple with nulls at once...?
            //note: assumes fTableName is not DUMMY
            sqlText:='SELECT ''N'' FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY WHERE (';
            //Note: default Valid will be inverted
            {Children}
            FKchildCol:=fChildColumn;
            while FKchildCol<>nil do
            begin
              sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"="'+fTableName+'"."'+FKchildCol.name+'"';
              FKchildCol:=FKchildCol.next;
              if FKchildCol<>nil then sqlText:=sqlText+' AND ';
            end;

            sqlText:=sqlText+')';

            {Note: we have an optimisable sub-select because the SARGs will be an index
             Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
             Note: null columns always match, and so always cause the unique test to return N
            }
          end; {ctRow}
          ctStmt,ctTran:
          begin //we must explicitly give the table
            //Aim: SELECT 'Y' FROM (VALUES(1)) AS DUMMY WHERE (UNIQUE (SELECT c1,c2 FROM fTableName) AND    --chance to short-circuit
            //                                                 NOT EXISTS (SELECT 1 FROM fTableName WHERE c1 IS NULL) AND
            //                                                 NOT EXISTS (SELECT 1 FROM fTableName WHERE c2 IS NULL)
            //                                                )
            //Note: the above needs indexes on each of the constituent columns to give full speed else crawl
            //
            // note: ensure col IS NULL matches index! else full scan!
            //        remove need to NOT NULL checks by enforcing NOT NULL on PK columns!
            //        i.e. check not null can be assumed to be there! (or remove 'check not null' from PK columns?)
            //       we now assume NOT NULL check is also in effect & so not needed here: speed/simpler logic
            //
            //note: if no indexes, faster to combine null checks & so just do 1 scan instead of 1 scan per column
            //      e.g. UNIQUE... AND NOT EXISTS(... WHERE c1 IS NULL OR c2 IS NULL...)
            //      is this faster even with indexes? check OR processing logic/short-circuitry...
            //      - I think not: OR would not match index (currently)
            //      so we should either guarantee column indexes or do single scan logic!
            //      currently assume column indexes which is fine for single column PKs (most?) but not for others...
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY WHERE (';
            sqlText:=sqlText+'UNIQUE ( SELECT ';
            {Children}
            FKchildCol:=fChildColumn;
            while FKchildCol<>nil do
            begin
              sqlText:=sqlText+'"'+FKchildCol.name+'"'; //note: add explicit prefix - findcol speed
              FKchildCol:=FKchildCol.next;
              if FKchildCol<>nil then sqlText:=sqlText+',';
            end;
            sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fTableName+'")';

            sqlText:=sqlText+')';
          end; {ctStmt,ctTran}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Constraint time %d not handled, ignoring...',[ord(fConstraintTime)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY'; //todo abort instead, rather than ignore: should never happen!
        end; {case}
      end; {rtPrimaryKey}
      rtForeignKey:
      begin
        {Detemine which end of the FK we are checking...}
        if fRuleEnd=ceChild then
        begin //child insert/update checking for parent
          case fConstraintTime of
            //todo neater to use common prefix...upto WHERE & then add appropriate clause
            ctRow:
            begin //we can use the context = fast (but we need to alias-mask parent table to avoid name clashes)
              //Notes:
              //  since ctRow, we assume this was set with caution, i.e. not self-referencing etc.
            //  (although if self-referencing we can still use context etc. is this not ok? - do we need to see self or not?)
              //  this where clause can still be planned and optimised once because iter.start re-evaluates key-lookups

              //Aim: CHECK( c1,c1,c3 MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM parent WHERE (c1=p1 AND c2=p2 AND c3=p3) ) )
              sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY2 WHERE ';
              sqlText:=sqlText+'(';
              {Children}
              FKchildCol:=fChildColumn;
              while FKchildCol<>nil do
              begin
                sqlText:=sqlText+'"'+FKchildCol.name+'"';
                FKchildCol:=FKchildCol.next;
                if FKchildCol<>nil then sqlText:=sqlText+',';
              end;

              sqlText:=sqlText+') MATCH ';
              case fFKmatchType of
                mtSimple:  sqlText:=sqlText+'';
                mtPartial: sqlText:=sqlText+'PARTIAL ';
                mtFull:    sqlText:=sqlText+'FULL ';
              end; {case}
              sqlText:=sqlText+'(SELECT ';
              {Parents}
              FKparentCol:=fParentColumn;
              while FKparentCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!
                sqlText:=sqlText+'DUMMY."'+FKparentCol.name+'"';
                FKparentCol:=FKparentCol.next;
                if FKparentCol<>nil then sqlText:=sqlText+',';
              end;

              {Note: we need to alias the parent so the preceding select and following where-clause is unambigous}
              //todo lookup & prefix with FKotherSchema... in case cross-schema constraints are allowed... should be? or at least stop their definition!
              sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY WHERE (';

              {Optimise the sub-select by passing SARGs that will be used to use an FK index
               Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
               Note: this uses an 'evaluation feature' where col=null gives a boolean result (so null=null is true)
                     so that matching tuples are only filtered out by the Match
                     - this is turned on just before the execution below (stmt.equalNulls)
              }
              FKchildCol:=fChildColumn;
              FKparentCol:=fParentColumn;
              while FKchildCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!
                sqlText:=sqlText+'DUMMY."'+FKparentCol.name+'"="'+fTableName+'"."'+FKchildCol.name+'"';
                FKchildCol:=FKchildCol.next;
                FKparentCol:=FKparentCol.next; //assumes we have exactly same number as child columns - checked elsewhere
                if FKchildCol<>nil then sqlText:=sqlText+' AND ';
              end;

              sqlText:=sqlText+') )';
            end; {ctRow}
            ctStmt,ctTran:
            begin //we must explicitly give the table
              //can we always avoid this?
              //  e.g. if self-referencing, can't we do the above but just at stmt end
              //     no- no single LH row to match with
              //     maybe build LH-row list? - potentially too big for parser...
              //     looks like we need special WHERE thisStmt=#WT# clause soon!
              //   do something slow/simple for now...e.g:
              //        CHECK( (SELECT c1,c1,c3 FROM child) MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM parent WHERE (c1=p1 AND c2=p2 AND c3=p3) ) )
              //                   ^ not allowed on LH of match?
              //                   so must surround with NOT EXISTS...

              //...from childTable C,parentTable P where C.col1=P.col1 and C.col2=P.col2... +match modifier?
              //- or faster/neater? to ...from childTable C join parentTable P on (C.col1=P.col1 and C.col2=P.col2)...

              //Aim: SELECT 'Y' FROM (VALUES(1)) AS DUMMY WHERE
              //       NOT EXISTS(SELECT 1 FROM '+fTableName+' AS DUMMY2 WHERE NOT (
              //         (c1,c1,c3) MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM parent WHERE (c1=p1 AND c2=p2 AND c3=p3))
              //         ) )
              sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY2 WHERE ';
              //12/04/02 sqlText:=sqlText+'  NOT EXISTS (SELECT 1 FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY WHERE NOT(';
              sqlText:=sqlText+'  NOT EXISTS (SELECT 1 FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY3 WHERE NOT(';
              sqlText:=sqlText+'(';
              {Children}
              FKchildCol:=fChildColumn;
              while FKchildCol<>nil do
              begin
                sqlText:=sqlText+'"'+FKchildCol.name+'"';
                FKchildCol:=FKchildCol.next;
                if FKchildCol<>nil then sqlText:=sqlText+',';
              end;

              sqlText:=sqlText+') MATCH ';
              case fFKmatchType of
                mtSimple:  sqlText:=sqlText+'';
                mtPartial: sqlText:=sqlText+'PARTIAL ';
                mtFull:    sqlText:=sqlText+'FULL ';
              end; {case}
              sqlText:=sqlText+'(SELECT ';
              {Parents}
              FKparentCol:=fParentColumn;
              while FKparentCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!/DUMMY2/3
                sqlText:=sqlText+'"'+FKparentCol.name+'"';
                FKparentCol:=FKparentCol.next;
                if FKparentCol<>nil then sqlText:=sqlText+',';
              end;

              {Note: we need to alias the parent so the preceding select and following where-clause is unambigous}
              //todo lookup & prefix with FKotherSchema... in case cross-schema constraints are allowed... should be? or at least stop their definition!
              //12/04/02 sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY3 WHERE (';
              sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY WHERE (';

              {Optimise the sub-select by passing SARGs that will be used to use an FK index
               Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
               Note: this uses an 'evaluation feature' where col=null gives a boolean result (so null=null is true)
                     so that matching tuples are only filtered out by the Match
                     - this is turned on just before the execution below (stmt.equalNulls)
              }
              FKchildCol:=fChildColumn;
              FKparentCol:=fParentColumn;
              while FKchildCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!/2/3
                //note: correlated sub-query = slow!?
                //12/04/02 sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"=DUMMY3."'+FKparentCol.name+'"';
                sqlText:=sqlText+'DUMMY."'+FKparentCol.name+'"=DUMMY3."'+FKchildCol.name+'"';
                FKchildCol:=FKchildCol.next;
                FKparentCol:=FKparentCol.next; //assumes we have exactly same number as child columns - checked elsewhere
                if FKchildCol<>nil then sqlText:=sqlText+' AND ';
              end;

              sqlText:=sqlText+') )';
              sqlText:=sqlText+') )';
            end; {ctStmt,ctTran}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Constraint time %d not handled, ignoring...',[ord(fConstraintTime)]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY'; //todo abort instead, rather than ignore: should never happen!
          end; {case}
        end
        else
        begin //parent delete checking-for/ensuring (via cascade) no child
          case fConstraintTime of
            //note: is MATCH a waste of time here (at parent end)!? I think so... 13/05/02 - not used for cascade delete...
            //       also, do we ever need cascade logic at ctStmt/ctTran level? I think so for deferrals/self-updates!
            //       neater to use common prefix...upto WHERE & then add appropriate clause
            ctRow:
            begin //we can use the context = fast (but we need to alias-mask child table to avoid name clashes)
              //Notes:
              //  since ctRow, we assume this was set with caution, i.e. not self-referencing etc.
            //  (although if self-referencing we can still use context etc. is this not ok? - do we need to see self or not?)
              //  this where clause can still be planned and optimised once because iter.start re-evaluates key-lookups

              //Aim: CHECK( c1,c1,c3 MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM child WHERE (c1=p1 AND c2=p2 AND c3=p3) ) )
              //Note: these cascade actions must work (or fail/abort) since if they work we assume all RI is kept intact,
              //      i.e. the action is instead of the usual check  
              sqlText:='SELECT ''N'' FROM (VALUES (1)) AS DUMMY2 WHERE '; //default = restrict
              case fCreator of
                ccDelete:
                begin
                  case fFKonDeleteAction of
                    raNone,raRestrict:  {default};
                    raCascade:          begin fAction:=caDelete; sqlText:='DELETE FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY WHERE '; end;
                    raSetNull:          begin fAction:=caUpdateSetNull; sqlText:='UPDATE "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY SET '; end;
                    raSetDefault:       begin fAction:=caUpdateSetDefault; sqlText:='UPDATE "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY SET '; end;
                  end; {case}
                end; {ccDelete}
                ccUpdate:
                begin
                  case fFKonUpdateAction of
                    raNone,raRestrict:  {default};
                    raCascade:          begin fAction:=caUpdate; sqlText:='UPDATE "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY SET '; end; //todo ensure we update the parent row first, else cycles possible!
                    raSetNull:          begin fAction:=caUpdateSetNull; sqlText:='UPDATE "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY SET '; end;
                    raSetDefault:       begin fAction:=caUpdateSetDefault; sqlText:='UPDATE "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY SET '; end;
                  end; {case}
                end; {ccUpdate}
              end; {case}

              if fAction<>caSelect then
                begin //action
                  if fAction in [caUpdate,caUpdateSetNull,caUpdateSetDefault] then
                  begin {SET}
                    {Children}
                    FKChildCol:=fChildColumn;
                    FKparentCol:=fParentColumn;
                    while FKChildCol<>nil do
                    begin
                      {$IFDEF SAFETY}
                      if FKparentCol=nil then
                      begin
                        {$IFDEF DEBUG_LOG}
                        log.add(who,where+routine,format('Row-time constraint (%d) can only be checked if given a context',[fConstraintId]),vAssertion);
                        {$ENDIF}
                        exit; //abort
                      end;
                      {$ENDIF}

                      //note: assumes fTableName is not DUMMY!
                      sqlText:=sqlText+'"'+FKChildCol.name+'"=';
                      if fAction=caUpdateSetNull then sqlText:=sqlText+'NULL';
                      if fAction=caUpdateSetDefault then sqlText:=sqlText+'DEFAULT';
                      if fAction=caUpdate then sqlText:=sqlText+'"'+fTableName+'"."'+FKparentCol.name+'"';

                      FKChildCol:=FKChildCol.next;
                      FKparentCol:=FKparentCol.next;
                      if FKChildCol<>nil then sqlText:=sqlText+',';
                    end;
                    sqlText:=sqlText+' WHERE ';
                  end;

                  {WHERE}
                  {Children=Parent} //Note: we don't need match(?) & so can optimise easily
                  FKchildCol:=fChildColumn;
                  FKparentCol:=fParentColumn;
                  while FKchildCol<>nil do
                  begin
                    {$IFDEF SAFETY}
                    if FKparentCol=nil then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(who,where+routine,format('Row-time constraint (%d) can only be checked if given a context',[fConstraintId]),vAssertion);
                      {$ENDIF}
                      exit; //abort
                    end;
                    {$ENDIF}

                    sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"="'+fTableName+'"."'+FKparentCol.name+'"';
                    //note: if fAction=caUpdate then use previous (pre-update) parent column values on right here
                    //note: we would also need to avoid update set 3=3 to avoid endless loops
                    FKchildCol:=FKchildCol.next;
                    FKparentCol:=FKparentCol.next;
                    if FKchildCol<>nil then sqlText:=sqlText+' AND ';
                  end;
                end
              else //select
              begin
                sqlText:=sqlText+'(';
                {Parents}
                FKparentCol:=fParentColumn;
                while FKparentCol<>nil do
                begin
                  sqlText:=sqlText+'"'+FKparentCol.name+'"';
                  FKparentCol:=FKparentCol.next;
                  if FKparentCol<>nil then sqlText:=sqlText+',';
                end;

                sqlText:=sqlText+') MATCH ';
                case fFKmatchType of
                  mtSimple:  sqlText:=sqlText+'';
                  mtPartial: sqlText:=sqlText+'PARTIAL ';
                  mtFull:    sqlText:=sqlText+'FULL ';
                end; {case}
                sqlText:=sqlText+'(SELECT ';
                {Children}
                FKChildCol:=fChildColumn;
                while FKChildCol<>nil do
                begin
                  //note: assumes fTableName is not DUMMY!
                  sqlText:=sqlText+'DUMMY."'+FKChildCol.name+'"';
                  FKChildCol:=FKChildCol.next;
                  if FKChildCol<>nil then sqlText:=sqlText+',';
                end;

                {Note: we need to alias the child so the preceding select and following where-clause is unambigous}
                //todo lookup & prefix with fFKotherSchemaName
                sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY WHERE (';

                {Optimise the sub-select by passing SARGs that will be used to use an FK index
                 Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
                 Note: this uses an 'evaluation feature' where col=null gives a boolean result (so null=null is true)
                       so that matching tuples are only filtered out by the Match
                       - this is turned on just before the execution below (stmt.equalNulls)
                }
                //note: check/make sure parentCol=DUMMY.childCol will be seen as indexable...
                //      currently we check if expression just references self...
                //      looks like we need to treat outer-refs as 'self' & as static integers/strings
                // -fixed? DUMMY.col=anything = indexable - i.e. constraint checker overrides...
                FKparentCol:=fParentColumn;
                FKchildCol:=fChildColumn;
                while FKParentCol<>nil do
                begin
                  //note: assumes fTableName is not DUMMY!
                  sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"="'+fTableName+'"."'+FKparentCol.name+'"';
                  FKparentCol:=FKparentCol.next;
                  FKchildCol:=FKchildCol.next; //assumes we have exactly same number as parent columns - checked elsewhere
                  if FKparentCol<>nil then sqlText:=sqlText+' AND ';
                end;

                sqlText:=sqlText+') )';
              end; {}
            end; {ctRow}
            ctStmt,ctTran:
            begin //we must explicitly give the table
              //can we always avoid this?
              //  e.g. if self-referencing, can't we do the above but just at stmt end
              //     no- no single LH row to match with
              //     maybe build LH-row list? - potentially too big for parser...
              //     looks like we need special WHERE thisStmt=#WT# clause soon!
              //  do something slow/simple for now...e.g:
              //        CHECK( (SELECT c1,c1,c3 FROM child) MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM parent WHERE (c1=p1 AND c2=p2 AND c3=p3) ) )
              //                   ^ not allowed on LH of match?
              //                   so must surround with NOT EXISTS...

              //...from childTable C,parentTable P where C.col1=P.col1 and C.col2=P.col2... +match modifier?
              //- or faster/neater? to ...from childTable C join parentTable P on (C.col1=P.col1 and C.col2=P.col2)...

              //Aim: SELECT 'Y' FROM (VALUES(1)) AS DUMMY WHERE
              //       NOT EXISTS(SELECT 1 FROM '+fTableName+' AS DUMMY2 WHERE NOT (
              //         (c1,c1,c3) MATCH [PARTIAL|FULL] (SELECT p1,p2,p3 FROM parent WHERE (c1=p1 AND c2=p2 AND c3=p3))
              //         ) )
              sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY2 WHERE ';
              //12/04/02 sqlText:=sqlText+'  NOT EXISTS (SELECT 1 FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY WHERE NOT(';
              sqlText:=sqlText+'  NOT EXISTS (SELECT 1 FROM "'+fSchemaName+'"."'+fFKotherTableName+'" AS DUMMY3 WHERE NOT(';
              sqlText:=sqlText+'(';
              {Parents}
              FKparentCol:=fParentColumn;
              while FKparentCol<>nil do
              begin
                sqlText:=sqlText+'"'+FKparentCol.name+'"';
                FKparentCol:=FKparentCol.next;
                if FKparentCol<>nil then sqlText:=sqlText+',';
              end;

              sqlText:=sqlText+') MATCH ';
              case fFKmatchType of
                mtSimple:  sqlText:=sqlText+'';
                mtPartial: sqlText:=sqlText+'PARTIAL ';
                mtFull:    sqlText:=sqlText+'FULL ';
              end; {case}
              sqlText:=sqlText+'(SELECT ';
              {Children}
              FKchildCol:=fChildColumn;
              while FKchildCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!/DUMMY2/3
                sqlText:=sqlText+'"'+FKchildCol.name+'"';
                FKchildCol:=FKchildCol.next;
                if FKchildCol<>nil then sqlText:=sqlText+',';
              end;

              {Note: we need to alias the child so the preceding select and following where-clause is unambigous}
              //12/04/02 sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY3 WHERE (';
              sqlText:=sqlText+' FROM "'+fSchemaName+'"."'+fTableName+'" AS DUMMY WHERE (';

              {Optimise the sub-select by passing SARGs that will be used to use an FK index
               Note: we assume this index always exists - else very slow! & so would be better to defer till end of stmt/tran
               Note: this uses an 'evaluation feature' where col=null gives a boolean result (so null=null is true)
                     so that matching tuples are only filtered out by the Match
                     - this is turned on just before the execution below (stmt.equalNulls)
              }
              FKparentCol:=fParentColumn;
              FKchildCol:=fChildColumn;
              while FKparentCol<>nil do
              begin
                //note: assumes fTableName is not DUMMY!/2/3
                //note: correlated sub-query = slow!?
                //12/04/02 sqlText:=sqlText+'DUMMY."'+FKparentCol.name+'"=DUMMY3."'+FKchildCol.name+'"';
                sqlText:=sqlText+'DUMMY."'+FKchildCol.name+'"=DUMMY3."'+FKparentCol.name+'"';
                FKparentCol:=FKparentCol.next;
                FKchildCol:=FKchildCol.next; //assumes we have exactly same number as parent columns - checked elsewhere
                if FKparentCol<>nil then sqlText:=sqlText+' AND ';
              end;

              sqlText:=sqlText+') )';
              sqlText:=sqlText+') )';
            end; {ctStmt,ctTran}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Constraint time %d not handled, ignoring...',[ord(fConstraintTime)]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY'; //todo abort instead, rather than ignore: should never happen!
          end; {case}
        end;
      end; {rtForeignKey}
      rtCheck:
      begin
        {note: if ctRow then
           we can just CompleteCondExpr and evaluate it without having a full select statement
           and all the iterator plans that go with it.
           e.g. parse(ruleCheck) - need to ensure this is valid, maybe use CHECK(cond) or SELECT 1 FROM dummy WHERE?
                create dummy algebra node...
                result:=CompleteCondExpr(tras,tras.sysStmt2,parse-cond-root,anodeRef.nodeRef,agNone);
                then execute without the need for iter - just pass current column as Value??? - needs some thought!

         For now, we'll do it the long way (since everything defaults to ctStmt)
        }
        {Comments about the SQL generated here: (so improve)
            may be quicker to SELECT a number? (using string because currently SELECT 1 gives a real and getInteger fails)
            AS DUMMY should be something that the user cannot use
            Maybe we should prefix the table_name with its schema name, but only needed for tran-level constraints?

            We need to simplify this: currently it performs an expensive set of parsing because of sub-select & exists...
            I think this is designed for tran level checking:
             for stmt-level we can probably drop the NOT EXISTS somehow...
             for row-level we can just use SELECT Y FROM 1-ROW-DUMMY WHERE (col>0) and pass current iter => col value
               maybe SELECT Y FROM DUMMY(current-col-value AS col) WHERE (col>0) is a neat way of passing col-data?
               e.g. SELECT Y FROM (VALUES (1)) AS X (col) where col>0  - but must be re-prepared each time...no good for row (unless we use parameters? X)
                 - but executing this once per row needs to be quicker than one big one at the end
                 - should be because we don't need to scan the whole table!
                 -        plus prepared once & then fast execution
                 - todo: be clever and change ctRow to ctStmt if table is fairly empty
                         i.e. auto-bulk-load optmisation with no risk! speed + feature!

             also we need to make sure it only looks at data with the current read stampId (which is temp-bumped before checking)

            For domain constraints (although they will be owned by table+column here)
            we need to replace 'VALUE' with 'colname' where col-name is owner colname- pass as with tableName?
            - maybe we should do this during constraint.create...then we don't need to keep the colname...
            - how do we tell if a constraint came from a domain? - caller should know?
        }
        case fConstraintTime of
          //note: neater to use common prefix...upto WHERE & then add appropriate clause
          ctRow:
          begin //we can use the context = fast
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY WHERE '+fRuleCheck
            //also note: the Where clause has access to the DUMMY table - may be useful for passing data?
            //e.g. (VALUES(curCol)) AS DUMMY (value) for neatly handling any domain syntax?
            // - so we need to know here what the column-name is...
            //- also: similar idea might apply to stmt/tran level domain checks below:
            //        (select domainCol as value from...) - can where access value? no...

            //note: don't use same DUMMY here as that above & used in optimiser... confusing?
          end; {ctRow}
          ctStmt,ctTran:
          begin //we must explicitly give the table
            sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY WHERE '+
                        'NOT EXISTS (SELECT 1 FROM "'+fSchemaName+'"."'+fTableName+'" WHERE NOT('+fRuleCheck+') )';
            //   -todo check this logic with DATE!
          end; {ctStmt,ctTran}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Constraint time %d not handled, ignoring...',[ord(fConstraintTime)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          sqlText:='SELECT ''Y'' FROM (VALUES (1)) AS DUMMY'; //todo abort instead, rather than ignore: should never happen!
        end; {case}
      end; {rtCheck}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unknown constraint type %d',[ord(fRuleType)]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
      result:=Fail;
      exit;
    end; {case}

    {Now parse & create an optimised plan}
    //todo: assert sqlText<>''
    //         maybe look at using parseSubSQL?

    {$IFDEF DEBUGDETAIL6}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('constraint check=%s',[sqlText]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {$IFDEF DEBUG_LOG}
    if stmt.sroot<>nil then log.add(who,where+routine,format('stmt.sroot is not nil (%p)...',[stmt.sroot]),vAssertion);
    {$ENDIF}
    {$IFNDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    saveLogVerbosity:=log.verbosity;
    {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.verbosity:=vFix; //quiet logging of sub-query
    {$ENDIF}
    try //conditional
    {$ENDIF}
      if prepareSQL(stmt,(iter as TIterator),sqlText)<>ok then
      begin
        result:=Fail;
        //Note: during initial tests, if we fail here strange things happened to subsequent parsing

        {Release anything attached to sroot, e.g. syntax/algebra/iterator trees
         - code take from unPreparePlan routine}
        {Delete the syntax tree using the old (pre-CNF split) root}
        {$IFDEF DEBUG_LOG}
        if stmt.sroot<>nil then log.add(who,where+routine,format('Deleting syntax tree (%p)...',[stmt.sroot]),vDebugMedium);
        {$ENDIF}
        //debug: DeleteSyntaxTree(stmt.sroot);
        DeleteSyntaxTree(stmt.srootAlloc.allocNext);
        stmt.srootAlloc.allocNext:=nil;
        stmt.sroot:=nil;
        {$IFDEF DEBUG_LOG}
        log.status; //memory display
        {$ENDIF}

        exit; //abort
      end;
      //assert resultSet=true(?)
    {$IFNDEF DEBUGDETAIL3}
    finally //conditional
      {$IFDEF DEBUG_LOG}
      log.verbosity:=saveLogVerbosity; //resume logging
      {$ENDIF}
    end;    //conditional
    {$ENDIF}

    {Store this plan for future use,
     so we can free up the common system stmt for other (non-nested) constraints}
    sroot:=stmt.sroot;

    {We can now de-prepare this stmt plan, because we've copied (actually moved) it}
    stmt.sroot:=nil; //this prevents 'memory still allocated' errors etc. & lets us re-use it for other constraints
  end; {prepare}


  {Now check the constraint}
  if sroot.ptree=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('No prepared plan (sroot=%p, sroot.atree=%p)',[sroot,sroot.atree]),vAssertion); //todo error - could happen? if so, give better user-error, e.g. Not applicable
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;

  {For ctStmt (and some ctRow) checking we must temporarily set the read-as to see the tentative
   changes that this constraint is associated with.
   (Note: assumes tran.Rt.tranId=self.Wt.tranId: should always be true - latest we can defer to is transaction end)
  }
  {todo: ensure we skip checking if self.fWt has been rolled back!- no need: stmt.rollback removes them
   - but it doesn't remove them from the tran-level list!
   - currently what's the harm if we do do a few extra checks? providing we skip any rolled-back data... speed!
  }
  saveStmtRt:=st.Rt;
  saveTranIsolation:=tras.isolation;
  if (fConstraintTime=ctStmt)
     or (fConstraintTime=ctRow) then
  begin
    stmt.Rt:=self.fWt; //i.e. use the (expected) stmtId so that we see our data
  end;

  {Set the isolation for this constraint}
  tras.isolation:=fConstraintIsolation;

  {$IFNDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  saveLogVerbosity:=log.verbosity;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.verbosity:=vFix; //quiet logging of sub-query
  {$ENDIF}
  {$ENDIF}
  if (fRuleType=rtForeignKey) and (fConstraintTime=ctRow) then
    stmt.equalNulls:=True; //temporarily enable null=null =>true
  try
    //Note: nothing here must change the fConstraintTime, else the finally restore will be inconsistent

    //assumes we are dealing with a IterSelect? and also that it will return at most 1 row
    // This is effectively the same as calling rowSubQuery, but is hopefully faster
    // because we have less housekeeping/result copying requirements...

    case fRuleType of
      rtUnique, rtPrimaryKey:
        if fConstraintTime=ctRow then valid:=isTrue; //inverted, i.e. no rows = check ok
      rtForeignKey:
        if fTableId<>fFKchildTableId then
          if fConstraintTime=ctRow then valid:=isTrue; //inverted, i.e. no rows = check ok
      //else keep default of isFalse
    end; {case}

    stmt.whereOldValues:=(fCreator=ccUpdate) and (fRuleEnd=ceParent); 
                                 //use old values in where clause: needed here in case start uses findScanStart (indexed)
                                 //note: make sure no other where clauses (iterSelects) are affected! e.g. meta-data? but prepare already...

    if (sroot.ptree as TIterator).start<>ok then
    begin
      result:=Fail;
      exit; //abort
    end;
    try
      stmt.planActive:=True;
      {Note: we do need to restart each time to re-start the cursor and especially to re-evaluate key lookups}
      stmt.noMore:=False; //ready for 1st fetch
      stmt.status:=ssActive; //needed for getSpareStmt to leave nested parents intact

      if (fRuleType=rtForeignKey) and (fRuleEnd=ceParent)
      and (fAction<>caSelect) then
      begin //cascade action
        repeat //Note: this could initiate another stmt + check list firing... but won't use same stmt...
          result:=ok; //i.e. normal (non action) failures here return ok... valid is what matters
          if (sroot.ptree as TIterator).next(stmt.noMore)<>ok then
          begin
            valid:=isFalse; //constraint failed
            exit; //abort
          end;
        until stmt.noMore;
        valid:=isTrue; //override any inversion - constraint succeeded
      end
      else //standard SELECT/restrict
      begin
        stmt.resultSet:=True; //set for stmt.CanSee to work out whether we see earlier active stmt data or not
        if (sroot.ptree as TIterator).next(stmt.noMore)<>ok then
        begin
          result:=Fail;
          exit; //abort
        end;
        if not stmt.noMore then
        begin
          {Now check the result of the sub-query}
          (sroot.ptree as TIterator).iTuple.GetString(0,res,res_null);

          if res=Yes then
            Valid:=isTrue
          else
            if res=No then //inverted, e.g. unique ctRow (or FK parent ctRow) result
              Valid:=isFalse;
        end;
        //else no rows so assume default (typically inValid, unless inverted)
      end;
      result:=ok; //but didn't error
    finally
      stmt.whereOldValues:=False; //reset

      if (sroot.ptree as TIterator).stop<>ok then
      begin
        valid:=isFalse; //constraint failed (e.g. stmt-level performed on stmt.commit)
        //exit; //abort
      end;
      stmt.planActive:=False;
      stmt.status:=ssInactive;
      stmt.resultSet:=False;
    end; {try}
  finally
    if (fRuleType=rtForeignKey) and (fConstraintTime=ctRow) then
      stmt.equalNulls:=False; //disable null=null =>true kludge
    {$IFNDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    log.verbosity:=saveLogVerbosity; //resume logging
    {$ENDIF}
    {$ENDIF}
    {$IFDEF DEBUGDETAIL8}
    {$IFDEF DEBUG_LOG}
    stop:=now;
    decodeTime(stop-start,h,m,sec,ms);
    log.add(st.who,where+routine,format('Constraint check time: %2.2d:%2.2d:%2.2d:%3.3d',[h,m,sec,ms]),vDebug);
    {$ENDIF}
    {$ENDIF}
    tras.isolation:=saveTranIsolation; //restore transaction isolation
    if (fConstraintTime=ctStmt)
     or (fConstraintTime=ctRow) then
    begin
      //st.Rt:=saveStmtRt; //restore - it's up to the stmtCommit to finally upgrade this after all checks are valid
      stmt.Rt:=saveStmtRt; //restore - it's up to the stmtCommit to finally upgrade this after all checks are valid
    end;
  end; {try}
end; {check}

function Tconstraint.checkChain(st:Tstmt;iter:TObject{TIterator};constraint_time:TconstraintTime;constraint_end:TconstraintEnd):integer;
{Checks all applicable constraints in this chain that have the specified contraint-time

 IN:      tr                   transaction
          st                   statement
          iter                 iterator from caller
                               - used for fast row-level checking (if not row-level checking can pass nil)
          constraint_time      limits checking to those nodes ready for this time, e.g. ctRow,ctStmt,ctTran
          constraint_end       limits checking to those nodes applicable to this 'end' e.g. parent FK, or others=child

 RESULT: ok = all checked valid
         else fail = one checked invalid or failed (caller doesn't care/distinguish)

 Note: take care to prefix references with node - else hard to debug errors!
}
const routine=':checkChain';
var
  stas:TStmt;

  node:Tconstraint;
  valid:TriLogic;
  s:string;
begin
  result:=Fail;

  stas:=(st as TStmt);

  node:=self.next; //i.e. skip header
  while node<>nil do
  begin
    if node.fConstraintTime=constraint_time then
    begin
      if constraint_end=ceParent then
        if node.fRuleEnd=ceChild then
        begin
          {This is not a child-FK-check so we ignore it for parent-end checking}
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('skipping %d(%s):%d %d=%s (%s %s %s) at %d - checking parent-end only',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
          {$ENDIF}
          {$ENDIF}
          node:=node.next;
          continue;
        end;
      if constraint_end=ceChild then
        if node.fRuleEnd=ceParent then
        begin
          {This is not a parent-FK-check so we ignore it for child-end checking}
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('skipping %d(%s):%d %d=%s (%s %s %s) at %d - checking child-end only',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
          {$ENDIF}
          {$ENDIF}
          node:=node.next;
          continue;
        end;

      if (constraint_end=ceBoth) and (node.fCreator=ccInsert) then
        if node.fRuleEnd=ceParent then
        begin
          {This is was not meant to be parent-FK-check so we ignore it: 05/06/04
          (in case of self-ref inserts, i.e. was checking each row had a child!)}
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('skipping %d(%s):%d %d=%s (%s %s %s) at %d - checking child-end only',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
          {$ENDIF}
          {$ENDIF}
          node:=node.next;
          continue;
        end;

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('checking %d(%s):%d %d=%s (%s %s %s) at %d',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
      {$ENDIF}
      if node.check(st,iter,valid)<>ok then
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('checking %d(%s):%d %d=%s (%s %s %s) at %d errored',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        stas.addError(seConstraintCheckFailed,format(seConstraintCheckFailedText,[node.fConstraintName]));
        exit; //abort if error
      end;
      if valid=isFalse then
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('checking %d(%s):%d %d=%s (%s %s %s) at %d failed',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}

        //todo improve this message: e.g. constraint failed: parent_table has references in children
        s:=node.fConstraintName; //default explanation
        {Try to give a reason for the failure}
        case node.fRuleType of
          rtUnique:       s:=s+' '+seConstraintViolatedUniqueText;
          rtPrimaryKey:   s:=s+' '+seConstraintViolatedPrimaryText;
          rtForeignKey:   if node.fRuleEnd=ceChild then
                            s:=s+' '+seConstraintViolatedFKchildText
                          else
                            s:=s+' '+seConstraintViolatedFKparentText;
          rtCheck:        s:=s+' '+seConstraintViolatedCheckText;
        end; {case}
        stas.addError(seConstraintViolated,format(seConstraintViolatedText,[s]));
        exit; //abort if invalid
      end
      {$IFDEF DEBUGDETAIL4}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('checking %d(%s):%d %d=%s (%s %s %s) at %d succeeded',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
      {$ENDIF}
    end;
    node:=node.next;
  end;
  result:=ok; //i.e. nothing errored and nothing was invalid
end; {checkChain}

function Tconstraint.existsInChain(table_id:integer; column_id:integer; constraint_id:integer; constraint_end:TconstraintEnd):integer;
{Searches constraints in this chain to find one matching the criteria

 IN:               table_id       table id of owner
                   column_id      column id of owner
                                    0 = table-level constraint
                   constraint_id  constraint_id to find
                   constraint_end ceParent = parent end of FK, else n/a (or child)

 RESULT: ok = found match
         else fail = no match found
}
const routine=':existsInChain';
var
  node:Tconstraint;
begin
  result:=Fail; //default=not found

  node:=self.next; //i.e. skip header
  while node<>nil do
  begin
    if (node.fConstraintId=constraint_id) and (node.fColumnId=column_id) and (node.fTableId=table_id) and (node.fRuleEnd=constraint_end) then
    begin
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('constraint already noted %d(%s):%d %d=%s (%s %s %s) at %d',[node.fTableId,node.fSchemaName+'.'+node.fTableName,node.fColumnId,node.fConstraintId,node.fConstraintName,ConstraintRuleString[node.fRuleType],ConstraintEndString[node.fRuleEnd],node.fRuleCheck,ord(node.fConstraintTime)]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
      exit; //finish as soon as we find a match
    end;
    node:=node.next;
  end;
end; {existsInChain}

{general routines}

function AddConstraint(st:Tstmt;iter:TObject{Titerator};
                       schema_name:string;
                       table_id:integer; table_name:string; column_id:integer;
                       constraint_id:integer;creator:TconstraintCreator;
                       constraint_end:TconstraintEnd):integer;
{Adds a constraint to the transaction or statement constraint list,
 according to its initially deferred (or overridden) state

 IN:               tr             transaction
                                  Note: Wt+1 is currently used as the 'current' statement to be written
                   st             statement
                   iter           calling iterator (currently used to get tuple definition for iterUpdate key-column check)
                   schema_name    schema name used for SQL generation during checking
                   table_id       table id of owner
                   table_name     table name used for SQL generation during checking
                   column_id      column id of owner
                                    0 = table-level constraint
                   constraint_id  constraint_id to add
                   creator        contraint creator, e.g. insert/update/delete
                                  - used to determine whether we can optimise physical check-time or not
                   constraint_end ceParent = parent end of FK, else n/a (or child)

 //Note: the reason we call this before stmtStart is in case privilege check/constraint lookup fails
 //        - the privilege check failing is likely, e.g. if a column name is garbage
 //          so we should either:
 //            leave as is and pass Wt+1 to create routine (should be a safe assumption, if called consistently)
 //            or,
 //            take the constraint column adding call out of the privilege column loop
 //             = extra loop code needed in caller to constraint add, but neater?
 //Note: *** for now we do the former and pass Wt+1 to the create routine ***

 RESULT: ok,
         +2 = not actually added because not applicable (e.g. PK for update to non-PK columns, or already existed in chain)
         else fail
}
const
  routine=':AddConstraint';
  notAdded=+2; //ok result with info
var
  sysConstraintR:TObject; //Trelation

  tras:TTransaction;
  //stas:TStmt;

  initiallyDeferred,deferrable:string;
  dummy_null:boolean;
  actuallyDeferred:boolean;

  newConstraint:Tconstraint;
  stampNow:StampId;

  willUpdateColumn:boolean;
  nhead:TSyntaxNodePtr;
  cRef:ColRef;
  childCol:TconstraintColumn;
begin
  result:=fail;

  tras:=Ttransaction(st.owner);
  //stas:=(st as TStmt);

  {We currently need to add 1 to Wt to ensure we are aligned with the statement id that
   the caller is about to start}
  stampNow:=st.Wt;
  stampNow.stmtId:=stampNow.stmtId+1;

  if tras.db.catalogRelationStart(st,sysConstraint,sysConstraintR)=ok then
  begin
    try
      if tras.db.findCatalogEntryByInteger(st,sysConstraintR,ord(sco_constraint_id),constraint_id)=ok then
      begin
        with (sysConstraintR as TRelation) do
        begin
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Found constraint %d',[constraint_id]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          {Add the constraint to the list}
          fTuple.GetString(ord(sco_initially_deferred),initiallyDeferred,dummy_null); //moved before Tconstraint.create so if fails, no memory leak
          fTuple.GetString(ord(sco_deferrable),deferrable,dummy_null); //moved before Tconstraint.create so if fails, no memory leak

          {Default deferred status}
          actuallyDeferred:=(initiallyDeferred=Yes);

          {Now check if this constraint time has been overridden for this transaction}
          case tras.constraintTimeOverridden(constraint_id) of
            ctTran: if deferrable=Yes then actuallyDeferred:=True;
            ctStmt: actuallyDeferred:=False;
          else
            //leave as is: not overridden (result will actually be ctNever=>null)
          end; {case}

          {Check if this constraint already exists - if it does, skip this addition - speed/memory //is this always appropriate?
           (If deferred then would add to transaction, not statement)}
          if actuallyDeferred then
          begin
            //this is the most likely case to match: deferred constraints are accumulated over the life of the transaction
            if tras.constraintList.existsInChain(table_id,column_id,constraint_id,constraint_end)=ok then
            begin
              result:=notAdded;
              exit; //skip adding, already exists
            end;
          end
          else
          begin
            //this is unlikely to be needed since ctStmt/ctRow constraints are cleared down before
            if (st.constraintList as Tconstraint).existsInChain(table_id,column_id,constraint_id,constraint_end)=ok then
            begin
              result:=notAdded;
              exit; //skip adding, already exists
            end;
          end;

          newConstraint:=TConstraint.create(st,schema_name,table_id,table_name,column_id,fTuple,actuallyDeferred,stampNow,creator,constraint_end);
          //todo: check if constraintTime=ctNever = must have had a creation problem, i.e. key columns not totally read... etc.?
          //      so we should abort rather than continue with a missing constraint, else bad data!

          {Before we add this constraint to a chain (now that we have the constraint details):-
           If we are called by iterUpdate then only add constraints that might
           be affected by this statement, i.e. only ones where we might update the columns involved
           This will save lots of time, especially for PK/UK/FK checking.
           (and *especially* at the moment since update checks cannot be row level yet! until can ignore self.rids...)
           Note: this applies to column and table level constraints
          }
          if creator=ccUpdate {todo use (iter is iterUpdate) - but need to include another unit!} then
          begin
            {Now check all constraint columns, if any are in our update column list then keep this constraint, else ignore it}
            //Note: this logic is taken from the tuple insert routine + iterUpdate
            willUpdateColumn:=False;
            {First choose the columns that apply to our 'end' of the constraint} //note: assumes self-referencing FK will issue 2 addConstraints
            if newConstraint.fRuleEnd=ceChild then
              childCol:=newConstraint.fChildColumn
            else
              childCol:=newConstraint.fParentColumn;
            while childCol<>nil do //for each (child) column in the constraint
            begin
              nhead:=(iter as Titerator).anodeRef.exprNodeRef;  //start of update-assignment chain
              while nhead<>nil do //for each column in the update statement
              begin
                case nhead.nType of
                  ntUpdateAssignment:
                  begin //column name
                    {Get the pre-found cref}
                    cRef:=nhead.cRef;
                    if ((iter as Titerator).iTuple.fColDef[cRef].id=childCol.id) and (nhead.cTuple<>nil){assert found already!} then
                    begin
                      willUpdateColumn:=True;
                      break;
                    end;
                  end;
                end; {case}
                nhead:=nhead.NextNode;
              end; {while}

              if willUpdateColumn then break; //we've found a column in this constraint that will be updated

              childCol:=childCol.next;
            end; {while}

            if not willUpdateColumn then
            begin //no need to check this constraint!
              newConstraint.free;
              newConstraint:=nil;
              result:=notAdded;
              {$IFDEF DEBUGDETAIL5}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Ignoring constraint %d - update will not affect it',[constraint_id]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              exit; //skip adding, already exists
            end;
          end;

          {Ok to continue, so add this new constraint to a chain...}

          {Prevent deferral of FK actions - these need to be kept at row level otherwise
           cycle problems etc. could arise(?) - standard forbids FK-deferrable PK to prevent this.
           should be ok since actions are really constraints}
          //note: the following is long for if fAction<>caSelect (but not built SQL until 1st check)
          //if actuallyDeferred then
            if newConstraint.fRuleEnd<>ceChild then //parent end
              //if newConstraint.fConstraintTime=ctRow then //row
                if ( (newConstraint.fCreator=ccDelete) and (newConstraint.fFKonDeleteAction in [raCascade,raSetNull,raSetDefault]) )
                or ( (newConstraint.fCreator=ccUpdate) and (newConstraint.fFKonUpdateAction in [raCascade,raSetNull,raSetDefault]) ) then //action
                begin
                  {$IFDEF DEBUGDETAIL5}
                  {$IFDEF DEBUG_LOG}
                  if actuallyDeferred then log.add(st.who,where+routine,format('Constraint FK action not being deferred %d',[constraint_id]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  actuallyDeferred:=false;
                  {$IFDEF DEBUGDETAIL5}
                  {$IFDEF DEBUG_LOG}
                  if newConstraint.fConstraintTime<>ctRow then log.add(st.who,where+routine,format('Constraint FK action retained at row-level %d',[constraint_id]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  newConstraint.fConstraintTime:=ctRow;
                end;

          {If deferred then add to transaction, not statement}
          if actuallyDeferred then
          begin
            newConstraint.fWt.stmtId:=MaxStampId.stmtId; {ensure we see changes by all this tran's potential stmts - note: could set accurately from tran.fWt at time of checking}
            tras.constraintList.chainNext(newConstraint);
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Added constraint %d to tran (deferred)',[constraint_id]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
          else
          begin
            (st.constraintList as Tconstraint).chainNext(newConstraint);
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Added constraint %d to stmt (immediate)',[constraint_id]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;
        end; {with}
      end
      else //constraint_id not found
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed finding constraint %d',[constraint_id]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;
    finally
      if tras.db.catalogRelationStop(st,sysConstraint,sysConstraintR)<>ok then
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
  end;
end; {AddConstraint}

function AddTableColumnConstraints(st:Tstmt;iter:TObject{TIterator};
                                   schema_name:string;
                                   table_id:integer;table_name:string;column_id:integer;creator:TconstraintCreator):integer;
{Adds table/column constraints to the transaction or statement constraint list
 IN:               tr          transaction
                   st          statement
                   iter        calling iterator (currently used to get tuple definition for iterUpdate key-column check)
                   schema_name schema name used for SQL generation during checking
                   table_id    table id to match
                   table_name  table name used for SQL generation during checking
                   column_id   column id to match
                               0 = table-level matches only
                   creator     contraint creator, e.g. insert/update/delete
                               - used to determine whether we can optimise physical check-time or not

 RESULT: ok, else fail

 Note:
   //***forget this note: we use sys catalog routines which are
   // synchronised elsewhere...
   //Move it to the check and trigger action routines though...
   <OLD comments before nesting was used:>
   We use the transaction's sysStmt2 to perform the lookups
   this should be ok here because:
       we are serial on the same transaction because we use the same thread
          so no synchronisation issues
       all internal uses of sysStmt2 to insert/update/delete
          are done by _SYSTEM which by-passes all constraint addition.
       we never nest, since constraints are only added at start of
          insert/delete/update and constraint adding itself should never use these
          (although in future, action triggers can recurse in this way...
           so problem for forthcoming cascadeTableConstraints routine)
   If any of this changes we must ensure we use some kind of fresh sysStmt
   in case we are nested.
   </OLD>


 //todo
    pass domain_id and add any domain-id constraints for the column
    (unless we copy the constraints to the column when the table is created... see spec.)

    speed this routine up
      although only called before execution, it is currently called once for every column
      that is to be modified: since it currently scans, currently would be better to scan
      once per table and match columns that way - but clumsier code in caller...
      Also, this routine calls another to find the constraint definition
      = currently another scan per constraint found - speed this? maybe use a join or index?
                                                                  ideally use RID pointer?...

    we can now derive creator from iter... so remove creator parameter?

 Assumes:
   sysTableColumnConstraint.constraint_id is never null
}
const routine=':AddTableColumnConstraints';
var
  sysTableColumnConstraintR:TObject; //Trelation
  columnId,constraintId:integer;
  columnId_null,dummy_null:boolean;

  tras:TTransaction;
begin
  result:=fail;

  tras:=Ttransaction(st.owner);

  if tras.db.catalogRelationStart(st,sysTableColumnConstraint,sysTableColumnConstraintR)=ok then
  begin
    try
      //note: assumes we have best index/hash on stc_table_id, but may not be the case
      if tras.db.findFirstCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),table_Id)=ok then
        try
          repeat
            {Found another matching table id}
            with (sysTableColumnConstraintR as TRelation) do
            begin
              fTuple.GetInteger(ord(stc_column_id),columnId,columnId_null);
              if ((columnId=0) or columnId_null) and (column_id=0) then
              begin //table-level match found (and was asked for) e.g. FK parent end(null), or column-constraint defined at table-level
                {Add the constraint}
                fTuple.GetInteger(ord(stc_constraint_id),constraintId,dummy_null);
                if columnId_null then
                  result:=addConstraint(st,iter,schema_name,table_id,table_name,column_id,constraintId,creator,ceParent)
                else
                  result:=addConstraint(st,iter,schema_name,table_id,table_name,column_id,constraintId,creator,ceChild);
                if result<ok then
                begin
                  exit; //abort
                end;
              end
              else
                if (columnId=column_id) then //we can assume not null
                begin //column-level match found
                  {Add the constraint}
                  fTuple.GetInteger(ord(stc_constraint_id),constraintId,dummy_null);
                  result:=addConstraint(st,iter,schema_name,table_id,table_name,column_id,constraintId,creator,ceChild);
                  if result<ok then
                  begin
                    exit; //abort
                  end;
                end;
                //else not for our column - skip & continue looking
            end; {with}
          until (tras.db.findNextCatalogEntryByInteger(st,sysTableColumnConstraintR,ord(stc_table_id),table_Id)<>ok); //note: duplicated above before Continues
        finally
          if tras.db.findDoneCatalogEntry(st,sysTableColumnConstraintR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTableColumnConstraint)]),vError);
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      //else no constraint for this table found
    finally
      if tras.db.catalogRelationStop(st,sysTableColumnConstraint,sysTableColumnConstraintR)<>ok then
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
end; {AddTableColumnConstraints}

function SetConstraints(st:Tstmt;nmode,nroot:TSyntaxNodePtr):integer;
{Set constraints for the specified transaction

 IN:         nmode - deferred or immediate syntax node
             nroot - list of constraint names. Nil=ALL
}
const routine=':SetContraints';
var
  tras:TTransaction;
  //stas:TStmt;

  cTime:TconstraintTime;
  cId:integer;
  cOverride:TconstraintTimeOverridePtr;
begin
  result:=Fail;

  tras:=Ttransaction(st.owner);
  //stas:=(st as TStmt);

  cTime:=ctNever;
  if nmode.nType=ntDeferred then cTime:=ctTran;
  if nmode.nType=ntImmediate then cTime:=ctStmt;
  if cTime=ctNever then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Unknown constraint time - syntax error should have caught this earlier',vAssertion);
    {$ENDIF}
    exit;
  end;

  if nroot=nil then
  begin //add ALL
    {We must first deal with any existing constraints:
     i.e. if set to deferred, nothing can currently be immediate so do nothing
          if set to immediate, check any matching tran-level constraints now - if any fail, fail
    }
    if cTime=ctStmt then
    begin //check all tran-level constraints now
      if tras.constraintList.checkChain(st,nil{iter n/a},ctTran,ceBoth)<>ok then
      begin
        {Up to user to rollback or fix}
        st.addError(seSetConstraintFailed,seSetConstraintFailedText);
        result:=fail;
        exit; //abort the set contraints
      end;

      {Ok, remove the tran level constraints}
      tras.constraintList.clearChain;
    end;

    {Ok, now add to transaction override list to cover any future constraints}
    new(cOverride);
    cOverride.constraintId:=0; //=ALL
    cOverride.constraintTime:=cTime;
    cOverride.next:=tras.constraintTimeOverride; //note: currently assumes 1 thread per tran
    tras.constraintTimeOverride:=cOverride;  //Note: linked in reverse scan order: Head->3->2->1

    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Added constraint-id %d into override list at time %d',[cOverride.constraintId,ord(cOverride.constraintTime)]),vdebugLow);
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('SET CONSTRAINTS name has not been implemented yet',[nil]),vError);
    {$ENDIF}
    st.addError(seNotImplementedYet,format(seNotImplementedYetText,['SET CONSTRAINTS name']));
    exit; //abort
  end;

  result:=Ok;
end; {SetConstraints}


end.

unit uStmt;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{This unit came about because we need to allow the client to SQLPrepare
 a number of statements on the same connection. Each of these can be
 executed later and the result-sets fetched. So I'm splitting the
 ExecSQL into a Prepare and an Execute phase. The pointers to the 3 trees
 need to be kept for each prepared statement
   a) to allow the plan to be run (via the ptree)
   b) to clean up all the memory after the statement is finished with

 Actually this structure is the server-half of the client's stmt.
 We keep cursor info here.
 And log user errors here.

 Currently the stmtList will be attached to the transaction. This seems right
 because the stmtList is attached to the dbc on the client side.

 10/04/02 We now use stmt references where we once passed tran + stmt.
 This is mainly to allow cursors to be left open & not see future stmts, but
 also helps us keep cursors open after transaction commit/rollback, e.g. for ODBC/JDBC autocommit.
 It also simplifies the parameter passing & seems to make more sense in some situations.
}

{$DEFINE SAFETY}
{$DEFINE DEBUGDETAIL3}

interface

uses uGlobal,uSyntax,
     classes {for TBits}, uVariableSet
     ;

type
  TParamListPtr=^TParamList;
  TParamList=record
    paramSnode:TSyntaxNodePtr;
    paramType:TvariableType; //e.g. in/out
    next:TParamListPtr;
  end; {TParamList}

  TErrorNodePtr=^TErrorNode;
  TErrorNode=record
    code:word;
    text:string;
    next:TErrorNodePtr;
  end; {TErrorNode}

  Tstmt=class
  private
    fOwner:Tobject;                //transaction owner (=access to its db/Rt etc.)
    function fWho:string;
  public 
    fRt:StampId; //read as timestamp (stamped by transaction at stmt start)
    fWt:StampId; //write as timestamp (used to write optimistically and atomically)

    {Link to outer stmt context}
    outer:Tstmt;                  //runtime scope context used to reference variables/parameters
                                  //todo: a setter would be nice!
    depth:integer;                //track routine/function call nesting level
    leavingLabel:string;          //when leaving/iterating, this is the block label we're trying to break out of/continue
                                  //todo: merge this with forthcoming exception handling mechanism...
    varSet:TVariableSet;          //current block's local variables/parameters
                                  //- only relevant for compound statements, i.e. for functions/procedures
                                  //todo: expand use to replace CLI params (paramList etc. below)
                                  //      - although they are different things...

    ParseRoot:TSyntaxNodePtr;     //returned parse tree root from parser
    InputText:string;             //input buffer string for parser
    syntaxErrLine,syntaxErrCol:integer{word}; //used to return parser error details //todo too small=could break?
    syntaxErrMessage:string;         //used to return parser error context

    sroot:TSyntaxNodePtr;         //syntax root     //rename to stree?
                                  //Note: will link to atree and to ptree if algebra/iterator trees added
                                  //Note: also used to determine whether we have a plan or not, i.e. potentially active

    srootAlloc:TSyntaxNodePtr;    //syntax node allocation header node
                                  //- used to ensure total cleanup of every allocated syntax node

    sarg:TSyntaxNodePtr;          //current (temporary) SARG list during optimisation

    paramCount:integer;
    paramList:TParamListPtr;      //parameter node chain (contains list of syntax tree ntParam nodes)
                                  //- see SQLexecute for more info...
    need_param:smallint; {SQLSMALLINT}//current parameter id for SQLputData to add to (incremented by SQLparamData)

    constraintList:TObject{TConstraint};   //list of current statement level constraints
    equalNulls:boolean;           //switch to determine whether null=null constraint kludge is used
                                  // e.g. for FK selecting, should be on so MATCH clause can work & subsequent filter does not remove
                                  //      for unique (ctRow), should be off so multiple nulls are allowed
    whereOldValues:boolean;       //reference pre-update column values in where clause tuples
                                  //set by update cascade constraint check & passed to eval routines from iterSelect
                                  //so we can Update set c=a.new where c=a.old
                                  //Also used in canSee to ignore old stmts which are still active
                                  //(probably always a good thing to do anyway, but until we're sure.. save time)

    errorCount:integer;
    errorList:TErrorNodePtr;      //error node chain (contains stack of user errors)
                                  // - these can be stacked from anywhere

    {We track the columns that the client has bound
     Note: these can be bound/unbound at any time, even before the Prepare and after the Execute
           but they are referenced by the server only at fetch time to determine which data to return
           (in future, we might save traffic from the client and just return all column data (up to a max.)
            - this might make the getData routines quicker
            - but this current way means we send the minimum amount of result data back, which is probably more
              efficient (unless getData is heavily used=rare?).
           Either way, the types of behaviour will be switchable.
           )
    }
    //todo: we don't need these for internal stmts! - we have direct access to tuples
    //todo: pass a switch to create() to avoid allocating memory for this...
    colBoundCount:colRef;
    colBound:TBits;
    (*todo remove
    colBound:array [0..MaxCol-1] of boolean;  //todo use sets? - speed - but can't: max=256!
                                              //todo note: if we have 32000 max. columns, then
                                              //           this would be too big an overhead
                                              //            (32k per stmt, ~1 stmt per user)
                                              //           - use lists (of bits?) instead
                                              // anyway, list might be faster cos
                                              //  main loop is fetch & fetch could loop list which is <= cols in tuple

                                              //use bitmask array, so 1024 max columns = 128 bytes
                                            //-> best solution for now! - fixed array of bitmap-bytes

                                              //or sparse bit-list: 1 byte=offset + 1 byte=8 bits + 4 bytes=nextPtr
                                              // -> max (256*8) = 2048 columns covered
                                              // if all bound = 1536 bytes
                                              // if 1st 1024 half bound = 768 bytes
                                              // if 1st 20 bound = 18 bytes
                                              // etc. - i.e. dynamically sized

                                              //or sparse bit-list: 1 byte=offset + 3 bytes=24 bits + 4 bytes=nextPtr
                                              // -> max (256*24) = 6144 columns covered
                                              // if 2048 bound = 688 bytes
                                              // if 1st 1024 half bound = 344 bytes
                                              // if 1st 20 bound = 8 bytes
                                              // etc. - i.e. dynamically sized
    *)

    rowsetSize:integer;                 //=array_size

    {The following relate to the server-side cursor} //todo so maybe this whole object is a cursor? rename?
    cursorName:string;                  //used for declare cursor
                                        // - also used by CLI execute to determine whether we are a cursor return result set
    cursorClosing:boolean;              //flag to prevent self-dependency loops when closing: debug fix attempt 04/01/01: failed: see testproc1.sql
    planHold:boolean;                   //used for declare cursor: hold open after commit (not rollback)
    planReturn:boolean;                 //used for declare cursor: hold open after procedure end
    planActive:boolean;                 //has the plan been started & not stopped? ==cursor open ?
                                        //- maybe we could put this state flag on the root iterator?
                                        //- maybe replace boolean with a proper multi-state type?
    resultSet:boolean;                  //will the plan return a result set (e.g. select statement)
                                        //todo: maybe combine this with planActive & use ssExpectResultSet, ssActive etc.?
    noMore:boolean;                     //on-the-fly execution via fetch needs this state kept


    status:TstmtStatusType;             //current status - introduced to allow Cancel/kill
                                        //- also used to determine whether to next constraint system stmts
                                        //todo: this could probably replace the planActive above?

    stmtType:TstmtType;                 //what kind of stmt is this, e.g. user or systemDDL

    property Owner:Tobject read fOwner;                //transaction owner (=access to its db/Rt etc.)

    property Rt:StampId read fRt write fRt;   //written by owner & temporarily by constraint.check
    property Wt:StampId read fWt write fWt;   //written by owner

    property who:string read fWho;

    constructor create(tran:Tobject{TTransaction};tranRt,tranWt:StampId);
    destructor destroy; override;

    function addParam(snode:TSyntaxNodePtr):integer;
    function resetParamList:integer;
    function deleteParamList:integer;

    function addError(errorCode:word;errorText:string):integer;
    function deleteErrorList:integer;

    function CanSee(CheckWt:StampId;deletion:boolean):boolean;
    function IsMe(CheckWt:StampId):boolean;
    function CannotSee(CheckWt:StampId):boolean;
    function CanUpdate(CheckWt:StampId):boolean;

    function CloseCursor(unprepareFlag:integer):integer;
  end; {Tstmt}

  TPtrstmtList=^TstmtList;     //should really be called TPtrStmtNode
  //todo make this list (and its routines) a class
  {Stmt pointer list nodes}
  TstmtList=record
    sp:Tstmt;
    next:TPtrstmtList;
  end; {TstmtList}

var
  //todo remove these -or at least make private
  debugStmtCreate:integer=0;
  debugStmtDestroy:integer=0;
  debugStmtParamCreate:integer=0;
  debugStmtParamDestroy:integer=0;
  debugStmtErrorCreate:integer=0; 
  debugStmtErrorDestroy:integer=0;

implementation

uses uLog, sysUtils{for format}, uConstraint, uTransaction,
     uProcessor{for unpreparePlan}, uIterator{for unpreparePlan}, uEvsHelpers;

const
  where='uStmt';

constructor Tstmt.create(tran:Tobject{TTransaction};tranRt,tranWt:StampId);
const routine=':create';
begin
  inc(debugStmtCreate);
  {$IFDEF DEBUG_LOG}
  if debugStmtCreate=1 then
    log.add(who,where+routine,format('  Stmt memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}

  fowner:=tran;
  {$IFDEF SAFETY}
  if not assigned(owner) then
    log.add(who,where+routine,format('Owner must be set',[nil]),vAssertion); //todo remove!
  if not(owner is TTransaction) then
    log.add(who,where+routine,format('Owner must be a transaction',[nil]),vAssertion); //todo remove!
  {$ENDIF}

  {Delphi does this for use, but good practice! (& less portability bugs)}
  outer:=nil;
  depth:=0;
  leavingLabel:='';
  varSet:=nil; //todo in future may auto-create, e.g. to allow variables at topmost level

  sroot:=nil;

  new(srootAlloc);
  inc(debugSyntaxCreate); //todo remove
  srootAlloc.ntype:=ntNOP;
  srootAlloc.ptree:=nil;
  srootAlloc.atree:=nil;
  srootAlloc.cTuple:=nil;
  srootAlloc.vVariableSet:=nil;
  //todo etc. from mkLeaf
  srootAlloc.allocNext:=nil;

  sarg:=nil;

  paramCount:=0;
  paramList:=nil;
  need_param:=0; //parameter id's start at 1, so 0=invalid

  constraintList:=TConstraint.create(nil,'',0,'',0,nil,false,InvalidStampId,ccUnknown,ceChild); //create dummy header node
  equalNulls:=False; //default to not kludge null=null => true (only used for FK checks)
  whereOldValues:=False; //default

  errorCount:=0;
  errorList:=nil;

  colBoundCount:=0;
  colBound:=TBits.Create;
  //todo leave as default: colBound.size:=0;
  // - I think TBits can handle 0..31 already without increasing the size
  //  - overhead seems to be only 16 bytes

  //we could do with a fast routine to set colBound array to False,
  // i.e. to reset all columns to unbound (currently relying on Delphi to do this)
  // maybe quicker to use a list - but no cos we need speed of random access more than reset
  //Note: colBound bits default to false as and when size is increased

  rowsetSize:=1; //default rowset size - todo ensure this agrees with client - use same constant?

  {result-set cursor state}
  cursorName:='';
  cursorClosing:=False;
  planHold:=false;
  planReturn:=false;
  planActive:=false;
  resultSet:=false;
  noMore:=True;

  {stmt status}
  status:=ssInactive;

  //default visibility
  fRt:=tranRt; //todo: default to rt.stmt=MAX to retain old behaviour: i.e. unspecified=all tran
  fWt:=tranWt;
  //todo: was :=InvalidStampId
end; {create}

destructor Tstmt.destroy;
begin
  //todo assert all tree's & lists are free etc.
  //- even though probably should be done in owner=stmtList=>transaction...

  {Delete any remaining constraint list (should just be header node?) //todo assert if more?}
  //todo assert that none of these have ConstraintTime=csTran - they should not be here!
  (constraintList as Tconstraint).clearChain; //todo check result
  {Delete the constraint list head node}
  constraintList.free;

  //we only currently free the colBound space once here - maybe in future owner should do this more often - to avoid keeping maximum-ever for no reason?
  colBound.free;

  {Clean up any assigned variable/parameter blocks: only added for compound blocks e.g. routine calls}
  if assigned(varSet) then varSet.free;

  {Remove syntax allocation header node}
  DeleteSyntaxTree(srootAlloc);

  inc(debugStmtDestroy); //todo remove

  inherited;
end; {destroy}

function Tstmt.addParam(snode:TSyntaxNodePtr):integer;
{Add a parameter entry to the paramList

 Note: this version build in left-to-right order since parameters are passed that
       way (else they were being reversed!)

       this is called from the grammar as each ? is found
}
const routine=':addParam';
var
  oldTailNode:TParamListPtr;
  newNode:TParamListPtr;
begin
  result:=ok;
  new(newNode);
  inc(debugStmtParamCreate);

  newNode.next:=nil;
  newNode.paramSnode:=snode; //todo should increment snode reference count
//  newNode.next:=paramList;
//  newNode.paramSnode:=snode;

  //todo: note: for now we default all parameters to varchar
  newNode.paramSnode.dType:=ctVarChar;
  //Note: this doesn't seem to matter - change sqllex.l routine! & remember to makelex!
  newNode.paramSnode.idVal:=intToStr(paramCount+1); //set idVal for client/server sync. (start at 0 to match client)
  newNode.paramSnode.nullVal:=True; //default

  newNode.paramType:=vtIn; //default, until we call a routine having an out/inout parameter

//  paramList:=newNode;
  //find tail
  oldTailNode:=paramList;
  if oldTailNode<>nil then
    while oldTailNode.next<>nil do
      oldTailNode:=oldTailNode.next;

  if oldTailNode=nil then //new start
    paramList:=newNode
  else //append to tail
    oldTailNode.next:=newNode;

  inc(paramCount);
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Added parameter to stmt: %s %f',[newNode.paramSnode.idVal,newNode.paramSnode.numVal]),vDebugLow); //todo remove!
  {$ENDIF}
end; {addParam}

function Tstmt.resetParamList:integer;
{Reset the whole paramList
 i.e. mark each parameter as 'needed'}
var
  nextParam:TParamListPtr;
begin
  result:=ok;
  nextParam:=self.paramList;
  while nextParam<>nil do
  begin
    //todo only if paramType=in/inout?...
    nextParam.paramSnode.strVal:='?'; //todo replace '?' with special constant - see sqllex.l install_param
    nextParam:=nextParam.next;
  end;
  need_param:=0; //belt & braces, probably no need
end; {resetParamList}

function Tstmt.deleteParamList:integer;
{Delete the whole paramList}
var
  oldNode:TParamListPtr;
begin
  result:=ok;
  while paramList<>nil do
  begin
    oldNode:=paramList.next;
    dispose(paramList);
    inc(debugStmtParamDestroy); //todo remove
    dec(paramCount);
    paramList:=oldNode;
  end;
  need_param:=0; //belt & braces, probably no need
  //todo assert paramCount=0 !
end; {deleteParamList}

function Tstmt.addError(errorCode:word;errorText:string):integer;
{Add an error entry to the errorList
 Note: we build the list in reverse order, i.e. it's a stack
}
const routine=':addError';
var
  newNode:TErrorNodePtr;
begin
  result:=ok;
  new(newNode);
  inc(debugStmtErrorCreate);

  newNode.next:=errorList;
  newNode.code:=errorCode;
  newNode.text:=errorText;

  errorList:=newNode;
  inc(errorCount);
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Added error to stmt: %d %s',[errorList.code,errorList.text]),vDebugLow); //todo remove!
  {$ENDIF}
end; {addError}

function Tstmt.deleteErrorList:integer;
{Delete the whole errorList}
var
  oldNode:TErrorNodePtr;
begin
  result:=ok;
  while errorList<>nil do
  begin
    oldNode:=errorList.next;
    dispose(errorList);
    inc(debugStmtErrorDestroy); //todo remove
    dec(errorCount);
    errorList:=oldNode;
  end;
  //todo assert errorCount=0 !
end; {deleteErrorList}

function TStmt.CanSee(CheckWt:StampId;deletion:boolean):boolean;
{Checks if this transaction/stmt's read timestamp allows it to see the specified timestamp
 IN        : CheckWt       the W timestamp to check
             deletion      True=record is a deleted header record type, i.e. a final deletion, if committed
                           False=record is not a deleted header
                           Note: this flag is only used for isolation=isReadCommittedPlusUncommittedDeletions
                                                        and isolation=isReadUncommittedMinusUncommittedDeletions

 RETURN    : True=this transaction.stmt can see it, else it cannot
 //todo return reason why we cannot - caller might want to tidy up rolled-back data

 //this needs to be fast!

 //todo what about updates that are effectively deletions?
}
const routine=':canSee';
var
  tranStatus:TtranStatusPtr; //todo make global -speed
  stmtWriter:TStmt;
  stmtStatus:TstmtStatusPtr;
  isolationLevel:Tisolation;
begin
  isolationLevel:=Ttransaction(owner).isolation;

  {Special cases for cautious foreign key constraint checking}
  if isolationLevel=isReadCommittedPlusUncommittedDeletions then
  begin
    if deletion and (CheckWt.tranId<>fRt.tranId){unless we deleted it=respect} then
      isolationLevel:=isReadUncommitted
    else
      isolationLevel:=isReadCommitted
  end;
  if isolationLevel=isReadUncommittedMinusUncommittedDeletions then
  begin
    if deletion or (CheckWt.tranId=fRt.tranId){unless we inserted it=respect} then
      isolationLevel:=isReadCommitted
    else
      isolationLevel:=isReadUncommitted
  end;

  if CheckWt.tranId<fRt.tranId then
  begin
    {$IFDEF SAFETY}
    if not assigned(owner) then
      log.add(who,where+routine,format('Owner not set',[nil]),vAssertion); //todo remove!
    {$ENDIF}
    if (isolationLevel=isReadUncommitted) and (CheckWt.tranId>=Ttransaction(owner).db.tranCommittedOffset) then
    begin //read any old garbage! Note: this was only added so primary-key constraints could work properly
      result:=not(Ttransaction(owner).db.TransactionIsRolledBack(CheckWt));
      exit;
    end;

    if (isolationLevel=isReadCommitted) and (CheckWt.tranId>=Ttransaction(owner).db.tranCommittedOffset) then
    begin  //current transaction state is in the global array
      result:=Ttransaction(owner).db.TransactionIsCommitted(CheckWt);
      exit;
    end;

    {Ok, was CheckWt part-committed before we started? if so we may be able to see it}
    result:=True; //so far...
    {Can we shortcut the uncommitted list search? Most of the time we would scan it *all* & conclude canSee anyway!}
    if CheckWt.tranId<Ttransaction(owner).earliestUncommitted.tranId then
      //skip the list search! We know that we can see this record since it is before our earliest uncommitted
    else
    begin
      //todo improve this brute search - use a binary tree search -speed
      // - although currently, we store list in reverse scanned order so we 'might' be able to prove that
      //     if tranStatus.tid>CheckWt then break - done searching!    e.g. Checkwt=6 (ftid=10)   tranStatus->5->4->3 check 5 & break
      //   -only if tran-id rows are always sequential in the heapFile -guaranteed?
      //   + we're more likely to find tranId=CheckWt.tranId early which would prove/disprove stmt visibility early
      {Check our history to see if this transaction was (part)rolled-back or not}
      tranStatus:=Ttransaction(owner).uncommitted;
      while tranStatus<>nil do
      begin
        if tranStatus.tid.tranId=CheckWt.tranId then
        begin
          if tranStatus.status=tsPartRolledBack then
          begin //this was part-rolled-back when we started, so check if the stmt was rolled-back or not
            {Quick check to see if stmtId was rolled-back} //todo note: only useful in future when we don't write full rollback list -for now we'll keep the algorithm simple
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
          end
          else
          begin //this was uncommitted (tsInProgress) or totally rolled-back (tsRolledBack) when we started, so we cannot see it
            result:=False;
            break; //found in uncommitted list, so done searching
          end;
        end;
        tranStatus:=tranStatus.next;
      end; {while}
    end;
    {if not broken out, default=True was correct}
  end
  else //this is ourself or in our future...
  begin
    if CheckWt.tranId=fRt.tranId then
    begin //this is ourself, but is it a future, rolled-back or active stmt?
      begin
        result:=True; //so far...

        //(*
        {Can see own updates!}
        if CheckWt.stmtId=fRt.stmtId then
          exit;

        {Check the current rolled-back stmt list for this stmtId
         Note: typically, this is empty, hence the quick pre-test, i.e. hopefully quicker that := + while <>}
            stmtStatus:=Ttransaction(owner).rolledBackStmtList;
            while stmtStatus<>nil do
            begin
              if stmtStatus.tid.stmtId=CheckWt.stmtId then
              begin
                result:=False;
                break; //found in current rolled-back stmt list, so done searching
              end;
              stmtStatus:=stmtStatus.next;
            end;
        {not found in current rolled-back stmt list, so default=True was correct}
      end;
    end
    else //future transaction
    begin
      if (isolationLevel=isReadUncommitted) and (CheckWt.tranId>=Ttransaction(owner).db.tranCommittedOffset){must be by definition, currently!} then
      begin //read any old garbage! Note: this was only added so primary-key constraints could work properly
        result:=not(Ttransaction(owner).db.TransactionIsRolledBack(CheckWt));
        exit;
      end;

      if (isolationLevel=isReadCommitted) and (CheckWt.tranId>=Ttransaction(owner).db.tranCommittedOffset){must be by definition, currently!} then
      begin //current transaction state is in the global array
        result:=Ttransaction(owner).db.TransactionIsCommitted(CheckWt);
        exit;
      end;

      result:=False; //no chance - CheckWt is in our future
    end;
  end;
end; {CanSee}

function TStmt.IsMe(CheckWt:StampId):boolean;
{Checks if this transaction/stmt's Wt timestamp = the specified timestamp
 (if it is, we can do certain things update-wise, e.g. overwrite without versioning)

 Note: We use Wt to compare against, since we're assuming that callers will
       be writing...

 IN        : CheckWt       the W timestamp to check
 RETURN    : True=this transaction/stmt = it, else not
}
begin
  if (Wt.tranId=CheckWt.tranId) and (Wt.stmtId=CheckWt.stmtId) then result:=True else result:=False;
end; {IsMe}

function TStmt.CannotSee(CheckWt:StampId):boolean;
{Checks if this transaction/stmt's timestamp doesn't allow it to see the specified timestamp
 IN        : CheckWt       the W timestamp to check
 RETURN    : True=this transaction.stmt cannot see it, else it can

 Note: assumes caller doesn't care about isolation=isReadCommittedPlusUncommittedDeletions
}
begin
  result:=not CanSee(CheckWt,False); //todo improve speed by re-coding negative? i.e. if CheckWt>fTid OR CheckWt in fTid.uncommitted-list - don't think so...
                                     //speed: code callers as not(canSee...)?
end; {CannotSee}

function TStmt.CanUpdate(CheckWt:StampId):boolean;
{Checks if this transaction/stmt's read timestamp allows it to update after the specified timestamp
 IN        : CheckWt       the W timestamp to check
 RETURN    : True=this transaction.stmt can update after it, else it cannot
 //todo return reason why we cannot - caller might want to tidy up/give better user error message/re-try/forget the update

 //this needs to be fast! (but not as fast as CanSee...?)
}
const routine=':canUpdate';
var
  tranStatus:TtranStatusPtr; //todo make global -speed
begin
  //todo ifdef safety when set transaction forces read-only!
  if Ttransaction(owner).isolation=isReadUncommitted then
  begin
    {we can never allow read-uncommitted to update records because it could have
     created its version data against a record that will be rolled back & purged
     (unless we make the garbage collector very clever, e.g.:
       don't purge old rolled back records if the latest committed record
       was read-uncommitted: instead keep going until we reach a reliable committed
       record that the version reader can trace back to.
       Plus: the version reader would also need to keep going past records committed by
             read-uncommitted transactions to ensure we got the full story...
     )
     //todo except ttransaction uses tuple.delete in one case & we must allow that: bug
    }
    result:=False;
    //todo remove:- noise!
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Attempt to update by read-uncommitted transaction/stmt rejected - continuing...',vDebugWarning); //todo remove!
    {$ENDIF}
  end;

  if CheckWt.tranId<fRt.tranId then
  begin
    {ok, is CheckWt now no longer active? if so we may be able to update it}
    result:=True; //so far...

    {Note: it's better to check the active trans-array now only if
           #active-trans < #transInOurUncommittedList, else later as & when we find each active tran in list}
    if (Ttransaction(owner).isolation=isReadCommitted) and (CheckWt.tranId>=Ttransaction(owner).db.tranCommittedOffset) then
    begin  //current transaction state is in the global array
      result:=not(Ttransaction(owner).db.TransactionIsActive(CheckWt)); //i.e. we can update if committed or rolled-back,
                                                    //     but only if we can be sure we're updating the committed
                                                    //     record - i.e. we are read-committed (else, if serializable
                                                    //     could be versioning against old data, so a rollback would
                                                    //     undo/lose comitted data!)
      {Note: rather than fail here, we could wait to see if it gets rolled-back!}
      //todo!: why do we allow update after rolled-back but not active!?? commit safety?!
      //note: could mean we need to KEEP rolled-back versions to retain integrity of data:
      //      e.g. v1(c)<-v2(r)->v3(c)
      //      & no active tran < v3 => garbage collect v1 + v2 BUT v3 was versioned based on v2!
      //      & v2 was rolled back(rubbish) - so bad v3 without v1 + v2!(?)
      //      => don't allow update to rolled-back (bad)
      //         or: garbage collector needs to be more careful? TODO!
      //todo: Ignore above: updates are always done/versioned against the read-tuple
      //      and the read-tuple must always be visible=not read-uncommitted (i.e. => read-only)
      //

      {Note: we allow update after rolled-back because
             column updates are always done/versioned against the read-tuple
             and the read-tuple must always be visible=not the rolled-back garbage
             that we might now be checking at the head of the record chain
      }
      exit;
    end;

    //todo improve this brute search - use a binary tree search -speed
    // - although currently, we store list in reverse scanned order so we 'might' be able to prove that
    //     if tranStatus.tid>CheckWt then break - done searching!    e.g. Checkwt=6 (ftid=10)   tranStatus->5->4->3 check 5 & break
    //   -only if tran-id rows are always sequential in the heapFile -guaranteed?
    //   + we're more likely to find tranId=CheckWt.tranId early which would prove/disprove stmt visibility early
    {Check our history to see if this transaction was (part)rolled-back or not}
    //todo: shortcut here as for canSee?: if checkWt.tranId<earliestUncommitted then True: NO: we need to know exactly why it was uncommitted!
    tranStatus:=Ttransaction(owner).uncommitted;
    while tranStatus<>nil do
    begin
      if tranStatus.tid.tranId=CheckWt.tranId then
      begin
        if (tranStatus.status=tsRolledBack) or (tranStatus.status=tsPartRolledBack) then
        begin //this tran was rolled-back or part-rolled-back when we started, so we can update it (we don't care whether this stmt was was rolled back or committed)
          result:=True;
          break; //found, so done searching
        end
        else
        begin //this was uncommitted (tsInProgress) when we started, so we cannot update it unless it is now committed or rolled-back (non-active)
          result:=False;
          //todo: maybe here is best place to check active Transactions to see if this one is still among them or not...?
          //      - if it's not then return True
          //      Note: if it is, then we could wait here to see if it gets rolled-back!
          break; //found to be active, so done searching
        end;
      end;
      tranStatus:=tranStatus.next;
    end; {while}
    {if not broken out, default=True was correct (since =>was committed when we started)}
  end
  else //if this is ourself, we allow updates (it's up to caller to do in-place or version)
  begin
    if CheckWt.tranId=fRt.tranId then
    begin
      result:=True;  //(we don't care whether this is an uncommitted stmt or not)
                     //todo: or do we, now we can see the stmt details...?
    end
    else //todo: maybe return True here if rolled-back???? or again, we could wait here to see if it gets rolled-back! No because record(s) before could be future+committed!!!!!
      result:=False; //no chance - CheckWt is in our future
                     //but... if CheckWt is committed and if we are read-committed then we
                     //       could throw away our pending update & assume it never happened!?
                     //       (only if there is no active read-(un)committed tran: fRt > X < checkWt) ! although who cares if there is? they're willing to read anything!
                     //       = Thomas Write Rule... TODO!
                     //       this might appear confusing: e.g. a=4 : update set a=3 : a=4 (i.e. stubbornly ignored but correct!)
  end;
end; {CanUpdate}

function Tstmt.fWho:string;
  {$IFDEF DEBUG_LOG}
  function fwhoLabel(sr:TSyntaxNodePtr):string;
  begin
    if assigned(sr) then result:=sr.idVal else result:='';
  end;
  {$ENDIF}
begin
  {$IFDEF DEBUG_LOG}
  if owner=nil then result:=cursorName
  else
    if Ttransaction(owner).thread<>nil then
      result:=format('%8.8x)%10.10d:%10.10d %s %s',[TIDPeerThread(Ttransaction(owner).Thread).ThreadId,fRt.tranId,fRt.stmtId,cursorName,fwhoLabel(sroot)])
    else
    {$ENDIF}
      result:=format('%10.10d:%10.10d',[fRt.tranId,fRt.stmtId]);
end;

function Tstmt.CloseCursor(unprepareFlag:integer):integer;
{Close cursor: actually deallocate it & reset any cursor name
 IN:    unprepareFlag   1=unprepare plan, else leave

 RETURNS:   ok, else fail
}
const routine=':closeCursor';
begin
  result:=ok;

  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format(': Closing left-open stmt %d...',[Rt.stmtId]),vDebugWarning); //todo client error?
  {$ENDIF}

  if cursorClosing then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format(': Note: cursor is already in the process of being closed - continuing this call...',[nil]),vDebugWarning); //note: avoiding recursion
    {$ENDIF}
    //todo! exit;
  end;

  cursorClosing:=True;

  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  //if (sroot<>nil) and (sroot.ptree<>nil) then
  //  if not (sroot.ptree is TIterator) then
  //    log.add(who,where+routine,format(': left-open stmt root ptree is not an iterator! %d',[longint(sroot.ptree)]),vAssertion);
  if (sroot<>nil) and (sroot.ptree<>nil) then
    log.add(who,where+routine,format(': left-open stmt root ptree = %d (unprepareFlag=%d)',[longint(sroot.ptree),unprepareFlag]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  {Code copied from uCLIserver.closeCursor}
  if (sroot<>nil) and (sroot.ptree<>nil) then
   if (sroot.ptree as TIterator).stop<>ok then //done(?): was sharing tree & not protecting root refcount todo HERE fails if 'with return'?
   begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format(':  failed closing cursor',[nil]),vDebugWarning); //add more info - =error
    {$ENDIF}
    result:=fail;
   end;

   {Close cursor & free plan} //todo: in future may want to save plan for future use
   if sroot<>nil then
   begin
    cursorName:='';
    //cursorClosing:=True already
    planHold:=False;
    planReturn:=False;
    planActive:=False;
    resultSet:=False;
    need_param:=0;
    status:=ssInactive;
    {we only do this next step if the client is going to the unprepared state
     - else leave plan until freeHandle or next prepare or whenever}
    if unprepareFlag=1 then
    begin
      if UnPreparePlan(self)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format(':  error unpreparing existing plan',[nil]),vDebugMedium);
        {$ENDIF}
        result:=fail;
      end;

      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format(': left-open stmt root = %d',[longint(sroot)]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      (*todo
      {Now, in case this was a resultSet cursor pointing to a subStmt, we remove any child stmts}
      for each stmt on this transaction:
      if owner=us then
      begin //this cursor is outside its original owning block so it can be zapped now
        subSt.closeCursor(1{=unprepare}); //I think this is when the standard means for this to happen...
        Ttransaction(stmt.owner).removeStmt(subSt);
      end;
      //else we leave the cursor until the end of the owning block, in case user wants to re-open it
      *)
    end
    else
    begin
      if paramList<>nil then resetParamList;
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format(':  existing plan left prepared (reset any parameters)',[nil]),vDebugMedium);
      {$ENDIF}
    end;
   end;

  cursorClosing:=False; //done
end; {closeCursor}



end.

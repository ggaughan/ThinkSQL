unit uIterator;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}  
{$DEFINE CACHE_TUPLES}  //create left and right tuples once to avoid many times in eval routine

{The TIterator (almost) abstract class definition.

 These objects are linked together in the same way as the chosen
 relational algebra plan.

 Also, there is a runtime link back to any outer plan.

 A call to the tree root will call each sub-tree via the inherited
 methods here.
}

//{$DEFINE DEBUGDETAIL}

interface

uses uTuple, uTransaction, uStmt, uAlgebra, uSyntax;

type
  TIterator=class
    private
    public
      //note: most of these only need to be public to give access to planner - hide via set/get routines

      {Reference nodes - leads to syntax tree via algebra tree}
      aNodeRef:TAlgebraNodePtr;


      {Child nodes}
      leftChild:TIterator;             //main (left)
      rightChild:TIterator;            //optional (right) (e.g. for joins)

      {Parent node}
      parent:TIterator;                //parent (e.g. for eval to see groupRowCount)

      {Link to outer plan}
      outer:TIterator;                 //runtime scope context used to reference correlations
                                       //(also used by row-time constraint checks to reference row data
                                       // and in future as a way to pass/access system globals)

      tran:TTransaction;
      stmt:TStmt;

      iTuple:TTuple;                    //output

      success:integer;                  //flag
                                        //  introduced so .stop knows whether .next failed
                                        //  - needed to decide whether to stmtCommit or stmtRollback
                                        //    in insert/update/delete

      prePlanned:boolean;               //flag
                                        //  introduced to be able to tell if prePlan has not/already been called

      correlated:boolean;               //flag
                                        //  introduced to be able to record whether a sub-plan is correlated to
                                        //  an outer query

      lrInUse:boolean;        //todo track number of uses (:=true) for cache performance
      ltuple,rtuple:TTuple;   //cache create/destroy for majority of cases: speed


      constructor create(S:TStmt);
      destructor destroy; override;

      function description:string; virtual;
      function status:string; virtual; abstract;

      function prePlan(outerRef:TIterator):integer; virtual;                  //prepare the iterator plan
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; virtual;            //optimise iterator plan (locally)
      function start:integer; virtual;                                        //begin iteration
      function next(var noMore:boolean):integer; virtual; abstract;           //  loop
      function stop:integer ;virtual;                                         //end
  end; {TIterator}

function DisplayAnotatedIteratorTree(ptree:TIterator):integer;
function DeleteIteratorTree(ptree:TIterator):integer;
function ChangeIteratorTreeOwner(ptree:TIterator;S:TStmt):integer;

var
  debugIteratorCreate:integer=0;
  debugIteratorDestroy:integer=0;


implementation

uses
{$IFDEF Debug_Log}
uLog,
{$ENDIF}
  sysUtils, uGlobal,
     {for tree display}
      uIterDelete,
      uIterGroup,
      uIterInsert,
      uIterJoinMerge,
      uIterJoinNestedLoop,
      uIterMaterialise,
      uIterProject,
      uIterRelation,
      uIterSelect,
      uIterSet,
      uIterSort,
      uIterSyntaxRelation,
      uIterUpdate
;

const
  where='uIterator';
  who='';

constructor TIterator.create(S:TStmt);
{This routine creates/initialises any objects needed by the start/next/stop routines

 The behaviour inherited by all is:
   create iTuple
   (with no owner, since it's just used as a buffer
    or in some cases the default buffer is ignored and the iTuple is repointed
    to another tuple for the duration of the iterator)
   set Tran to the initiator's TTransaction reference
   set Stmt to the initiator's TStmt reference
   set prePlanned flag = False
}
const routine=':create';
begin
  inherited create;
  inc(debugIteratorCreate);
  {$IFDEF DEBUG_LOG}
  if debugIteratorCreate=1 then
    log.add(who,where,format('  Iterator memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}

  tran:=Ttransaction(s.owner);
  stmt:=s;
  if tran=nil then
    {$IFDEF DEBUG_LOG}
    log.add(s.who,where+routine,'Transaction is nil',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  if stmt=nil then
    {$IFDEF DEBUG_LOG}
    log.add(s.who,where+routine,'Statement is nil',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  iTuple:=TTuple.Create(nil);
  prePlanned:=False;
  correlated:=False;

  {$IFDEF CACHE_TUPLES}
  ltuple:=TTuple.create(nil);
  rtuple:=TTuple.create(nil);
  {$ELSE}
  ltuple:=nil;
  rtuple:=nil;
  {$ENDIF}
  lrInUse:=false;
end; {create}

destructor TIterator.destroy;
{This routine destroys any objects created by the create routine

 The behaviour inherited by all is:
   destroy iTuple
}
begin
  {$IFDEF CACHE_TUPLES}
  rtuple.free;
  ltuple.free;
  {$ENDIF}

  iTuple.free;

  inc(debugIteratorDestroy);

  inherited destroy;
end; {destroy}

function TIterator.prePlan(outerRef:TIterator):integer;
{This routine prepares the iterator plan for optimisation and eventual execution

 The behaviour inherited by all is:
   set Outer to the passed OuterRef
   (this provides a scope context for optimiser & runtime name finding, especially (only?)
    for correlations between sub and super queries)
   debug warning if prePlanned = True (unless possibly re-preplanning, e.g. in a user loop)
   set prePlanned flag = True

 This should be called once per plan, even if the start method is repeatedly called
 It should pull up *any* setting of correlated in a lower sub-plan using OR,
 e.g. after a Complete... or after a child.prePlan, or even a setProjectHeadings

  RETURNS:  ok, else fail

 Note: if fails, execution should abort
}
const routine=':prePlan';
begin
  {Pass outer Iterator (and so link to tuple & its outers) into each Iterator.
   Overhead, but only way for outer to be referenced by an inner (correlated)
   i.e. iter-tree passes data from bottom up via iTuple (initialised by calls to start)
        and outerTuple reference is passed from top down (pushed in by subQuery,IterSyntaxRelation.start call)

   Also used for optimiser to know when to stop 'pushing-down selects' etc.
  }
  outer:=outerRef; //save reference to runtime outer plan

  {$IFDEF DEBUG_LOG}
  if prePlanned then
    if stmt.outer=nil then
      log.add(stmt.who,where+routine,'Statement has already been pre-planned',vAssertion)
    else
      log.add(stmt.who,where+routine,'Statement has already been pre-planned',vDebugLow); 
  {$ENDIF}
  prePlanned:=True;

  result:=ok;
end; {prePlan}

function TIterator.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{This routine optimises the prepared iterator plan from a local perspective

 The behaviour inherited by all is:
   debug warning if prePlanned = False
   set newChildParent return value=nil

 This only needs to be called once per prepared plan

  RETURNS:  ok, else fail

 Note: if fails, execution should abort
}
const routine=':optimise';
begin
  {$IFDEF DEBUG_LOG}
  if not prePlanned then log.add(stmt.who,where+routine,'Statement has not yet been planned',vAssertion);
  {$ELSE}
  ;
  {$ENDIF}

  {General routine for children:
    add our SARGs to global list
    if any of the SARGs belong just above here (cos parts are introduced here)
            insert iterSelect parent (if needed) & so return in newChildParent for re-linking
            attach them
            mark them as 'pushed' so caller can remove (although no crash if we don't)
    left.optimise - push down remainders
    if newChildParent<>nil then re-link new left child
    right.optimise - push down remainders
    if newChildParent<>nil then re-link new right child
    check any of ours that are now marked pushed and remove them from ourself
      - actually just ignore them in our eval routines, since children will re-use/share/modify? the sub-nodes
  }

  newChildParent:=nil;

  result:=ok;
end; {optimise}

function TIterator.start:integer;
{This routine starts the iterator process

 The behaviour inherited by all is:
   set Success=ok
   (this is currently only used for insert/update/commit so .stop knows if .next aborted)

   debug warning if prePlanned = False

  //todo*: once prePlan is used everywhere (even for iterinsert etc.) then
    we should get rid of the outer reference stuff from here.
    Also remove all completedTree flags!
    Also check result of prePlan when we call it!
    Also remove iter from some routines, e.g:
         all eval... routines since complete... routines calls prePlan (may be some exceptions)
         all rowSubquery type routines - prePlan is assumed to have been called by caller
         also check any other places where iter is being passed around at runtime for no reason...

  RETURNS:  ok, else fail

 Note: if fails, execution should abort
}
const routine=':start';
begin
  success:=ok;

  {$IFDEF DEBUG_LOG}
  if not prePlanned then log.add(stmt.who,where+routine,'Statement has not been pre-planned',vAssertion);
  {$ELSE}
  ;
  {$ENDIF}

  result:=ok;
end; {start}

function TIterator.stop:integer;
{This routine stops the iterator process

 The behaviour inherited by all is:
   RETURNS:  ok, else fail

 Note: the rowSubquery routine assumes the iterator's tuple is still valid
       after this stop (if this is changed, rowSubquery would have to take the
       first tuple after the first 'next' had been called.)
}
const routine=':stop';
begin
  result:=ok;
end; {stop}

function TIterator.description:string;
{Return a user-friendly description of this node
}
begin
  result:=copy(self.className,6,length(self.className));  //name minus Titer prefix
  if aNodeRef<>nil then
    if aNodeRef.rel<>nil then
    begin
      result:=result+' '+aNodeRef.rel.schemaName+'.'+aNodeRef.rel.relname;
      // if ptree.aNodeRef.tableName<>'' then s:=s+' '+ptree.aNodeRef.tablename;
      if aNodeRef.rangeName<>'' then result:=result+' ['+aNodeRef.rangename+']';
    end;
end; {description}

{Class method}
function DisplayAnotatedIteratorTree(ptree:TIterator):integer;
{Attempt at a crude build of a display of the iterator tree
 IN:     ptree              root to draw from

//todo - pass to a graphical front-end routine to draw & annotate tree properly

//Note: this will fail if circular references
// exist in the tree.
// Need: either a better deletion algorithm, or prove no circles...

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const
  routine=':displayAnotatedIteratorTree';
var
  d:integer;

  function BuildDisplayAnotatedIteratorTree(ptree:TIterator;d:integer):integer;
  { IN       : d              current depth (start with 0!) = down
  }
  var
    s:string;
  begin
    if ptree<>nil then
    begin
      {display this node}
      s:=ptree.className;

      if ptree.aNodeRef<>nil then
      begin
        if ptree.aNodeRef.tableName<>'' then s:=s+' '+ptree.aNodeRef.tablename;
        if ptree.aNodeRef.rangeName<>'' then s:=s+' '+ptree.aNodeRef.rangename;
      end;

      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('%*.*s %s',[d,d,' ',s]),vDebugMedium);
      {$ENDIF}

      if ptree.leftChild<>nil then BuildDisplayAnotatedIteratorTree(ptree.leftChild,d+3);
      if ptree.rightChild<>nil then BuildDisplayAnotatedIteratorTree(ptree.rightChild,d+3);
    end;
    result:=ok;
  end; {BuildDisplayIteratorTree}
begin
  {$IFDEF DEBUGDETAIL}
  d:=0;
  BuildDisplayAnotatedIteratorTree(ptree,d);
  {$ENDIF}

  result:=ok;
end; {DisplayAnotatedIteratorTree}

{Class method}
function DeleteIteratorTree(ptree:TIterator):integer;
{Removes the complete iterator tree
 Also frees any associated iTuple (as part of the TIterator destroy method)

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const routine=':deleteIteratorTree';
begin
  if ptree<>nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('(%p)',[@ptree]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    if ptree.leftChild<>nil then DeleteIteratorTree(ptree.leftChild);
    if ptree.rightChild<>nil then DeleteIteratorTree(ptree.rightChild); //never?
    ptree.free; //close & free iTuple & self
    //note algebra tree is not disturbed...
    // although the algebra tree has probably already been deleted
    // so any anodeRef's will be dangling by now - assert here? or maybe deleteAlgebraTree should fix such dangling?
  end;
  result:=ok;
end; {DeleteIteratorTree}

{Class method}
function ChangeIteratorTreeOwner(ptree:TIterator;S:TStmt):integer;
{Changes the ownership of the complete iterator tree

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const routine=':changeIteratorTreeOwner';
begin
  if ptree<>nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('(%p)',[@ptree]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {Set owner}
    ptree.tran:=Ttransaction(s.owner);
    ptree.stmt:=s;
    if ptree.tran=nil then
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,'Transaction is nil',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    if ptree.stmt=nil then
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,'Statement is nil',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}

    if ptree.leftChild<>nil then ChangeIteratorTreeOwner(ptree.leftChild,S);
    if ptree.rightChild<>nil then ChangeIteratorTreeOwner(ptree.rightChild,S); //never?
  end;
  result:=ok;
end; {ChangeIteratorTreeOwner}


end.

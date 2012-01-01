unit uIterSelect;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}

{Select iterator
 = filter
}

interface

uses uIterator, uSyntax, uTransaction, uStmt, uAlgebra,
     uTuple{for tuple cache};

type
  TIterSelect=class(TIterator)
    private
      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
    public
      function status:string; override;

      constructor create(S:TStmt;condExprRef:TAlgebraNodePtr);

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterSelect}

implementation

uses uLog, sysUtils, uGlobal, {uTuple,} uEvalCondExpr;

const
  where='uIterSelect';

constructor TIterSelect.create(S:TStmt;condExprRef:TAlgebraNodePtr);
begin
  inherited create(s);
  aNodeRef:=condExprRef;
  //todo maybe we should use exprNodeRef instead of original nodeRef? - check others using 'expressions' also?...
  completedTrees:=False;
end; {create}

function TIterSelect.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterSelect';
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterSelect.prePlan(outerRef:TIterator):integer;
{PrePlans the select process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  if self.aNodeRef.nodeRef.leftChild<>nil then
    log.add(stmt.who,where+routine,format('%s preplanning with syntax node ref %d',[self.status,ord(self.aNodeRef.nodeRef.leftChild.ntype)]),vDebugLow)
  else
    log.add(stmt.who,where+routine,format('%s preplanning with syntax node ref %d',[self.status,0]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    correlated:=correlated OR leftChild.correlated;
  end;
  if result<>ok then exit; //aborted by child

  {Define this ituple from leftChild.ituple}
  //todo is there a way to share the same memory or tuple?
  // - maybe destroy this one & point iTuple at leftChild's?
  iTuple.CopyTupleDef(leftChild.iTuple);

  {Complete condition sub-tree}
  if not completedTrees then
  begin
    completedTrees:=True; //ensure we only complete the sub-trees once
    result:=CompleteCondExpr(stmt,leftChild,anodeRef.nodeRef,agNone);
    if result<>ok then exit; //aborted by child
    correlated:=correlated OR leftChild.correlated;
  end;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugMedium); //debug
  {$ELSE}
  ;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[leftChild.iTuple.ShowHeading]),vDebugMedium); //debug
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {prePlan}

function TIterSelect.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
var
  subNode,sargNode,trailsargNode:TSyntaxNodePtr;
  {$IFDEF DEBUGDETAIL}
  debugs:string;
  {$ENDIF}
  outerSARGlist:TSyntaxNodePtr; //used to block/store any existing outer level SARG list while we push down from here
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  outerSARGlist:=nil;
  if SARGlist<>nil then
  begin
    {We must be a nested sub-select since a parent has passed us a SARGlist.
     Currently we're not clever enough to determine whether such SARGs can be pulled
     down, e.g. are we correlated to the correct level, ambiguous names, etc.
     so we simply prevent such pull-downs, as we do in Where clause pushing/pulling.
     (But we do continue pushing down with a new SARGlist since this sub-select won't be optimised separately)
     (even when we can determine which can be pulled, we need to re-find them
      at the lower levels or the column/tuple refs would be invalid...)
    }
    //todo: also same for group by etc.?
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('SARG list exists so we assume this is a sub-select and stop passing down optimisations from higher levels (for now)',[nil]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}    
    outerSARGlist:=SARGlist;
    SARGlist:=nil; //we've saved the original SARGlist, so now we can reset it
  end;
  try
    {Add our SARGs to the list}
    {$IFDEF DEBUGDETAIL}
    debugs:='';
    subNode:=anodeRef.nodeRef;
    while (subNode<>nil) do
    begin
      debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
      subNode:=subNode.nextNode; //any more sub-trees?
    end;
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,'adding SARGs: '+debugs,vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    //todo: replace chainTempLink with chainAppendTempLink??? safer removal??
    chainTempLink(SARGlist,anodeRef.nodeRef);

    //todo check SARG list: if any belong just above here
    //     insert Select algebra+iter parent (if necessary) & link to this node & create
    //     attach SARG(s)
    //     re-complete SARG expression(s) to point to new level , i.e. newNode.prePlan with this outer!
    //     mark SARG(s) as 'pushed' so caller/we can remove (although no crash if we don't)

    if assigned(leftChild) then
    begin
      result:=leftChild.optimise(SARGlist,newChildParent);   //recurse down tree
    end;
    if result<>ok then exit; //aborted by child
    if newChildParent<>nil then
    begin
      {Child has inserted an intermediate node - re-link to new child for execution calls}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('linking to new leftChild: %s',[newChildParent.Status]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      leftChild:=newChildParent;
      newChildParent:=nil; //don't continue passing up!
    end;
    //todo: same for rightChild if we could have one

    {$IFDEF DEBUGDETAIL}
    debugs:='';
    {$ENDIF}
    {Check our SARG nodes to see if any have been 'pushed' - if so we need to remove them from this iter node}
    subNode:=anodeRef.nodeRef;
    trailsargNode:=nil;
    while (subNode<>nil) do
    begin
      {$IFDEF DEBUGDETAIL}
      debugs:=debugs+format('%p(%d)[%d] ',[subNode,ord(subNode.nType),ord(subNode.pushed)]);
      {$ENDIF}
      //todo if pushed, then unlink from anodeRef.nodeRef list (child/children has now taken ownership)
      subNode:=subNode.nextNode; //any more sub-trees?
    end;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,'checked for pushed SARGs: '+debugs,vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    {$IFDEF DEBUGDETAIL}
    debugs:='';
    {$ENDIF}
    {Now we can unlink our SARG node chain from the SARGlist
     Note: this assume that nothing disturbs the links...(children make copies of the roots)}
    //todo: maybe better & faster to use a list of lists, e.g. leftChild = chain & then chain above = SARGlist
    {Find this subtree in SARGlist}
    subNode:=anodeRef.nodeRef;
    trailsargNode:=nil;
    sargNode:=SARGlist;
    while (sargNode<>nil) do
    begin
      if subNode=sargNode then //this is the head of ours //is this the best/failsafe way to check?
      begin
        {Move along both lists for the correct number of nodes}
        while (subNode<>nil) do
        begin
          //todo: assert/check sargNode<>nil!
          {$IFDEF DEBUGDETAIL}
          debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
          {$ENDIF}
          //I suppose we really should inc/dec refCounts in all this in case 2 children take ownership etc.!
          //     unless we remove & re-add nodes before passing down to any right child! - avoid double-push/use - ok?
          //     but maybe not if we have sub-queries & both branches would benefit from a criteria push...?
          //     For now, we don't push down both branches - we stop at iterProject (sub-selects) & might do at joins...
          //     - maybe it will be ok now the children will clone the root node of each subtree when needed...
          subNode:=subNode.nextNode; //any more sub-trees?
          sargNode:=sargNode.nextNode; //any more sub-trees?
        end;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,'unlinking SARG chain containing: '+debugs,vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}

        {Now unlink our temporary node pointer list copy from the SARGlist}
        if trailsargNode=nil then
          SARGlist:=sargNode //i.e. 1 after end of our list
        else
        begin
          trailsargNode.nextNode:=sargNode; //by-pass (chain nodes are still used elsewhere, so we leave them alone)
        end;
        subNode:=nil; //mark as done
        break; //found match
      end;
      trailsargNode:=sargNode;
      sargNode:=sargNode.nextNode; //any more sub-trees?
    end;
    {$IFDEF DEBUG_LOG}
    if subNode<>nil then log.add(stmt.who,where+routine,format('SARG chain %p disappeared from SARGlist on return!',[subNode]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  finally
    //restore any saved/held outer SARGlist for parent
    SARGlist:=outerSARGlist;
  end; {try}
end; {optimise}

function TIterSelect.start:integer;
{Start the select process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  if self.aNodeRef.nodeRef.leftChild<>nil then
    log.add(stmt.who,where+routine,format('%s starting with syntax node ref %d',[self.status,ord(self.aNodeRef.nodeRef.leftChild.ntype)]),vDebugLow)
  else
    log.add(stmt.who,where+routine,format('%s starting with syntax node ref %d',[self.status,0]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.start;   //recurse down tree
  if result<>ok then exit; //aborted by child

  lrInUse:=false; //lr tuples are available for use in eval routine (if they exist)
end; {start}

function TIterSelect.stop:integer;
{Start the select process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
end; {stop}

function TIterSelect.next(var noMore:boolean):integer;
{Get the next tuple from the select process
 RETURNS:  ok, else fail

 Note:
   needs to be fast - this is (currently) used to implement constraint checking 
}
const routine=':next';
var
  res:TriLogic;

  i:ColRef;
begin
//  inherited next;
  result:=ok;
  //todo catch exceptions -> fail
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  (*speed increases:
     precreate two tuples in this iterator's initialisation & and pass them
     to EvalCondExpr which will pass them to EvalCondPredicate which could use
     them to do basic comparisons (80%!)
     (instead of recreating & destroying them each time, i.e. once for every row!)

     but: recursion is possible...?
          e.g. a=b where a has CASE expression involving a=b, i.e. would need stacking!
     so: safer to cache temp tuples or have a fast-create for in-memory temptuples (e.g where owner=nil?)

     or: create 2 here & mark them as in-use/no-in-use during eval routine (if in use, create nested ones)
     - so most of time = fast
  *)
  repeat
    if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
    if result<>ok then exit; //abort
    if not noMore then
    begin
      result:=EvalCondExpr(stmt,leftChild,anodeRef.nodeRef,res,agNone,stmt.whereOldValues{i.e. if update cascade use pre-update column values});
      if result<>ok then exit; //abort
    end;
  until noMore or (res=isTrue);

  if not noMore then //=> res=isTrue
  begin //copy leftchild.iTuple to this.iTuple (point?)
{$IFDEF DEBUG_LOG}
{$ELSE}
;
{$ENDIF}
    iTuple.clear(stmt); //speed - fastClear?
    for i:=0 to leftChild.iTuple.ColCount-1 do
    begin
      iTuple.CopyColDataPtr(i,leftChild.iTuple,i);
    end;
    iTuple.SetRID(leftChild.iTuple.RID); //pass up //copy to all iterators!
                                         //or add to end of Tuple.CopyAll routine?
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',[iTuple.Show(tran)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;
end; {next}

end.

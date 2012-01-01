unit uIterJoinNestedLoop;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3}
//{$DEFINE DEBUGDETAIL4}
//{$DEFINE DEBUGDETAIL5}
//{$DEFINE DEBUGDETAIL6}
{$DEFINE DEBUGSUMMARY}

//{$DEFINE OLD_EARLY_SELECTION} //i.e. project now - optimiser not allowed freedom to re-arrange!

{Nested loop join
 Supports: jtInner, jtRight (actually implemented as left-outer) (or jtLeft if LRswapped)
 Notes:
   does not require indexes
   does not require sorted inputs

   i and j are colRef (0..) so the array loops go from 1 to count and then we use loopvar-1 as the subscripts
   - else range error
}

interface

uses uIterator, uIterJoin, uTransaction, uStmt, uAlgebra, uGlobal {for jointype},
     uTuple {for MaxCol}, uSyntax;

type
  TIterJoinNestedLoop=class(TIterJoin)
    private
      innerNoMore:boolean;
      matchedForOuter:boolean;
    public
      function status:string; override;

      constructor create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType); override;
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterJoinNestedLoop}

implementation

uses uLog, sysUtils, uEvalCondExpr, uIterRelation {for equi-join filter test/assertion}, uMarshalGlobal;

const
  where='uIterJoin(NL)';

constructor TIterJoinNestedLoop.create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType);
begin
  inherited create(S,condExprRef,joinFlag);
end; {create}

destructor TIterJoinNestedLoop.destroy;
const routine=':destroy';
var
  tempJoinKeyNode:TSyntaxNodePtr;
begin
  inherited destroy;
end; {destroy}

function TIterJoinNestedLoop.status:string;
var s:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterJoinNestedLoop '+leftChild.anodeRef.tablename+' ('+leftChild.anodeRef.rangeName+') ['+joinTypeToStr(joinType)+'] '+rightChild.anodeRef.tablename+' ('+rightChild.anodeRef.rangeName+') (LRswapped='+intToStr(ord(anodeRef.LRswapped))+')';
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterJoinNestedLoop.prePlan(outerRef:TIterator):integer;
{PrePlans the join process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  i,j:colRef;
  nhead,n:TSyntaxNodePtr;
  cTuple:TTuple;   //make global?
  cRange:string;
  cId:TColId;
  leftcRef:ColRef;
  rightcRef:ColRef;
  sourceCount:colRef;
begin
  {Assert that this joinType is handled
  //Note: done before inherited prePlan since it will reset LRswapped to True
  }
  //if not(joinType in [jtInner, jtLeft]) then
  {L join R already builds as RxJ (unless it's LRswapped) and so we actually can handle L right-join R by default, not L left-join R as initially assumed: fixed 03/06/01}
  if (joinType in [jtFull,jtUnion]) or ((joinType=jtLeft) and not anodeRef.LRswapped) or ((joinType=jtRight) and anodeRef.LRswapped) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('This sort type does not support the %s join type',[joinTypeToStr(joinType)]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;

  result:=inherited prePlan(outerRef);

  {$IFDEF DEBUGSUMMARY}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo: maybe pull down 'if joinExpr' to this class?
end; {prePlan}

function TIterJoinNestedLoop.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
var
  subNode,sargNode,trailsargNode,tempSARG,candidateSARG:TSyntaxNodePtr;
  tempNode,tempNode1,tempNode2:TSyntaxNodePtr;
  tempJoinKeyNode:TSyntaxNodePtr;
  i:colRef;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  debugs:string;
  {$ENDIF}
  {$ENDIF}
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUGSUMMARY}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  tempJoinKeyNode:=nil;

  //todo check SARG list: if any belong just above here
  //     insert Select algebra+iter parent (if necessary) & link to this node & create
  //     attach SARG(s)
  //     re-complete SARG expression(s) to point to new level , i.e. newNode.prePlan with this outer!
  //     mark SARG(s) as 'pulled' so caller/we can remove (although no crash if we don't)
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  debugs:='';
  subNode:=SARGlist;
  while (subNode<>nil) do
  begin
    debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
    subNode:=subNode.nextNode; //any more sub-trees?
  end;
  log.add(stmt.who,where+routine,'receiving SARGlist: '+debugs,vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {Note: to avoid pushing left any SARGs that will be marked as must-pulls, we push
   them left here before the marking routine
   (otherwise iterRelation optimise code would match left & right for equi-joins = mutual dependence/knots)
  }
  if assigned(leftChild) then
  begin
    result:=leftChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('linking to new leftChild: %s',[newChildParent.Status]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    leftChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;

//todo tidy this!:
//(* debug time test
  {We now need to add SARGs that are implied by the 'natural' join syntax
   (as opposed to 'where' join clause SARGs that have been passed down from the iterSelect node)
   It's likely that they will be used.
   To do this, we check joinKey and joinExpr flags to see what can be added to the current SARGlist
   - this will mean creating temporary/artifical expression syntax subtrees for joinKey parts to pass down
   - we'll make sure these are cleaned up properly by appending them to the joinExpr
     (which changes the actual syntax tree)

   note: may be cleaner if joinKey created joinExpr nodes and then we could just pass joinExpr expression...
         -but for now, the joinKey is done before the join-tuple is materialised & (so) is faster
         - so we'll keep it the way it is for now, but duplicate the equi-join parts as sub-trees for SARG passing
  }
 //{$IFDEF OLD_EARLY_SELECTION} //optimiser handles all this now: else can no longer be sure to find the columns in the children after optimiser
  if joinKey then
  begin
    {$IFDEF DEBUGDETAIL6}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('building (artificial) join-key expressions for passing down via SARGlist',[nil]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    for i:=1 to anodeRef.keyColMapCount do
    begin
      {$IFDEF DEBUGDETAIL6}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('adding artificial subtree for key-join pair %d (%s) and %d (%s)',[anodeRef.keyColMap[i-1].left,leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].name,anodeRef.keyColMap[i-1].right,rightChild.iTuple.fColDef[anodeRef.keyColMap[i-1].right].name]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      //todo: keep in sync. with lex install_id routine:
      {Column}
      tempNode1:=mkLeaf(stmt.srootAlloc,ntId,ctUnknown,0,0); //todo id_count;
      tempNode1.idVal:=leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].name;
      tempNode1.nullVal:=false;
      tempNode1.line:=0; tempNode1.col:=0;

      {Table}
      tempNode:=mkLeaf(stmt.srootAlloc,ntId,ctUnknown,0,0); //todo id_count;
      if TAlgebraNodePtr(leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].sourceRange).rangeName='' then
        tempNode.idVal:=TAlgebraNodePtr(leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].sourceRange).tableName
      else
        tempNode.idVal:=TAlgebraNodePtr(leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].sourceRange).rangeName;
      tempNode.nullVal:=false;
      tempNode.line:=0; tempNode.col:=0;

      //todo: keep in sync. with yacc routines:
      {Left}
      tempNode:=mkNode(stmt.srootAlloc,ntTable,ctUnknown,nil,tempNode);
      tempNode1:=mkNode(stmt.srootAlloc,ntColumnRef,ctUnknown,tempNode,tempNode1);
      tempNode1:=mkNode(stmt.srootAlloc,ntCharacterExp{doesn't matter},ctUnknown{debug CASE? ctChar},tempNode1,nil);
      tempNode1:=mkNode(stmt.srootAlloc,ntRowConstructor,ctUnknown,tempNode1,nil);
      {$IFDEF DEBUGDETAIL6}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('building join-key sub-tree (left) for SARGlist: %s %s.%s',[TAlgebraNodePtr(leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].sourceRange).rangeName,TAlgebraNodePtr(leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].sourceRange).tableName,leftChild.iTuple.fColDef[anodeRef.keyColMap[i-1].left].name]),vDebugLow);
      {$ENDIF}
      {$ENDIF}


      //todo: keep in sync. with lex install_id routine:
      {Column}
      tempNode2:=mkLeaf(stmt.srootAlloc,ntId,ctUnknown,0,0); //todo id_count;
      tempNode2.idVal:=rightChild.iTuple.fColDef[anodeRef.keyColMap[i-1].right].name;
      tempNode2.nullVal:=false;
      tempNode2.line:=0; tempNode2.col:=0;
//*)
//(* cont
      //todo: keep in sync. with yacc routines:
      {Right}
      tempNode2:=mkNode(stmt.srootAlloc,ntColumnRef,ctUnknown,nil,tempNode2);
      tempNode2:=mkNode(stmt.srootAlloc,ntCharacterExp{doesn't matter},ctUnknown{debug CASE? ctChar},tempNode2,nil);
      tempNode2:=mkNode(stmt.srootAlloc,ntRowConstructor,ctUnknown,tempNode2,nil);
      {$IFDEF DEBUGDETAIL6}
{$IFDEF DEBUG_LOG}
log.add(stmt.who,where+routine,format('building join-key sub-tree (right) for SARGlist: %s %s.%s',[TAlgebraNodePtr(rightChild.iTuple.fColDef[anodeRef.keyColMap[i-1].right].sourceRange).rangeName,TAlgebraNodePtr(rightChild.iTuple.fColDef[anodeRef.keyColMap[i-1].right].sourceRange).tableName,rightChild.iTuple.fColDef[anodeRef.keyColMap[i-1].right].name]),vDebugLow);
{$ENDIF}
{$IFDEF DEBUG_LOG}
//      log.add(stmt.who,where+routine,format('building join-key sub-tree (right) for SARGlist: %s',[rightChild.iTuple.fColDef[keyColMap[i].right].name]),vDebugLow);
{$ELSE}
;
{$ENDIF}
      {$ENDIF}

      {Equal}
//todo do backwards to allow right-child optimisation code to pull:subNode:=mkNode(ntEqual,ctUnknown,tempNode1,tempNode2);
//     because inner right child expects: innercol=outerTable.outercol
      subNode:=mkNode(stmt.srootAlloc,ntEqualOrNull,ctUnknown,tempNode2,tempNode1);
      subNode.pushed:=ptMustPull; //force (right)child to pull
      {$IFDEF DEBUGDETAIL6}
      {$IFDEF DEBUG_LOG}
      displaySyntaxTree(subNode);
      {$ENDIF}
      {$ENDIF}

      chainNext(tempJoinKeyNode,subNode);//use chainAppendNext?
    end;
    //todo: ensure we only complete the sub-trees once - we're assuming optimise is called once!
    {Note: to prevent us having to materialise the join tuple before we can test the key equivalence in
           such optimised cases, we start evaluating the columns from the leftChild: this ensures the
           columns for the outer relation are pointing directly at it. Any inner (right) child columns
           will be found in the join tuple (1 level up) and will be re-found locally during key-setting.
           Note that this means the inner columns must have no prefix because in natural joined tuples
           it is the left/outer tuple duplicate columns that are kept. (although we'd re-find anyway...)
    }
    //Attach the new syntax nodes to the existing tree to hand over memory management responsibility
    if tempJoinKeyNode<>nil then
    begin
      linkRightChild(anodeRef.nodeRef,tempJoinKeyNode);
      result:=CompleteCondExpr(stmt,leftChild,anodeRef.nodeRef.rightChild,agNone);
      //note: no need to check result? since we built the conditions...
      if result<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('system-built join expression failed',[nil]),vAssertion);
        {$ENDIF}
        exit; //abort
      end;
    end;
    //else may not have had any columns in common
  end;

  if joinExpr then
  begin
    {$IFDEF DEBUGDETAIL6}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('appending join-expr to SARGlist',[nil]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    chainAppendTempLink(SARGlist,anodeRef.nodeRef.leftChild);
  end;
  if joinKey then
  begin
    {$IFDEF DEBUGDETAIL6}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('appending join-key to SARGlist',[nil]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    chainAppendTempLink(SARGlist,anodeRef.nodeRef.rightChild); //may be nil
  end;
//*)
 //{$ENDIF}

  {Check the SARGlist for subnodes that only reference our 2 child relations (assuming we have 2 appropriate children)}
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  debugs:='';
  {$ENDIF}
  {$ENDIF}
  subNode:=SARGlist;
  while (subNode<>nil) do
  begin
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
    {$ENDIF}
    {$ENDIF}

    //note: if not pulled already then
    //      - reasoning is:
    //          1. may cause problems if we re-link subnode to more than 1 child?
    //          2. no benefit - would only be applied to self-joins & filtering 1 should be good enough??
    //          3. when we swap and unset pulled flag on old-candidate (temporary logic) we must be sure only we set it!
    if justReferencesChildren(subNode)=+1 then
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('will ensure %p(%d) is pulled by right child to filter inner relation (hopefully via an index)',[subNode,ord(subNode.nType)]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      if assigned(rightChild) then
      begin
        subNode.pushed:=ptMustPull; //force pull in next child - needed to override local SARG optimisation rules
      end;
    end;

    subNode:=subNode.nextNode; //any more sub-trees?
  end;

  {We've marked the inner-relation's equi-join SARGs as 'must-pull', so these will
   be pushed down here...}
  if assigned(rightChild) then
  begin
    result:=rightChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('linking to new rightChild: %s',[newChildParent.Status]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    rightChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;

  //check if any of our SARGs are now marked 'pulled' & remove them from ourself if so
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    debugs:='';
    {$ENDIF}
    {$ENDIF}
    {Now we can unlink our SARG node chain from the SARGlist
     Note: this assumes that nothing disturbs the links...(children make copies of the roots)}
    //todo: maybe better & faster to use a list of lists, e.g. leftChild = chain & then chain above = SARGlist
    {Find this subtree in SARGlist}
    subNode:=nil;
   //{$IFDEF OLD_EARLY_SELECTION} //optimiser handles all this now: else can no longer be sure to find the columns in the children after optimiser
    if joinExpr then subNode:=anodeRef.nodeRef.leftChild; //may be nil
    if joinKey then subNode:=anodeRef.nodeRef.rightChild; //may be nil //Note: assumes joinkey & joinExpr are mutually exclusive
   //{$ENDIF}
    trailsargNode:=nil;
    sargNode:=SARGlist;
    while (sargNode<>nil) do
    begin
      if subNode=sargNode then //this is the head of ours
      begin
        {Move along both lists for the correct number of nodes}
        {Note/fix: we couldn't be sure of the number of nodes since chainTempLink attached the end of our sub-list to the existing list
         but now we use chainAppendTempLink, we always stitch the sub-list to the end so we can keep going & the end is our end...
         - check this workaround always works - i.e. can a lower level append before we try to remove?}
        while (subNode<>nil) do
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
          {$ENDIF}
          {$ENDIF}
          //note I suppose we really should inc/dec refCounts in all this in case 2 children take ownership etc.!
          //     unless we remove & re-add nodes before passing down to any right child! - avoid double-push/use - ok?
          //     but maybe not if we have sub-queries & both branches would benefit from a criteria push...?
          //     For now, we don't push down both branches - we stop at iterProject (sub-selects) & might do at joins...
          //     - it will be ok now the children will clone the root node of each subtree when needed...
          subNode:=subNode.nextNode; //any more sub-trees?
          sargNode:=sargNode.nextNode; //any more sub-trees?
        end;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,'unlinking SARG chain containing: '+debugs,vDebugLow);
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
  end;
end; {optimise}

function TIterJoinNestedLoop.start:integer;
{Start the join process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  if result<>ok then exit;
  {$IFDEF DEBUGSUMMARY}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  innerNoMore:=True;

  matchedForOuter:=True;

  {Note: to be able to handle right outer joins:
    swap outer & inner children so our main loop driver is inner tuple
    but retain order of tuple appending so original outer results are first

    Note: this might affect/ruin the optimiser's results... check consequences
    - don't we *have* to drive with the right child as outer loop for a right outer join? i.e. no choice?
  }
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {start}

function TIterJoinNestedLoop.stop:integer;
{Stop the join process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUGSUMMARY}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {stop}

function TIterJoinNestedLoop.next(var noMore:boolean):integer;
{Get the next tuple from the join process
 RETURNS:  ok, else fail

 Note: the noMore result should be kept static by the caller
       as this routine assumes this
       Does this requirement apply to other Iters?
}
const routine=':next';
var
  res:TriLogic;
  keyres:boolean;
  i:ColRef;
begin
//  inherited next;
  result:=ok;
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  repeat
    res:=isUnknown;

    if not innerNoMore then
    begin //we still have more inner relations to be joined
      //speed: no need to check assigned(rightChild) - safety only
      if assigned(rightChild) then result:=rightChild.next(innerNoMore);   //read next
      if result<>ok then exit; //abort
    end;

    if innerNoMore then
    begin //inner relation exhausted, try next outer relation & restart inner
      if (joinType in [jtLeft,jtRight]) and not(matchedForOuter) then
      begin {Note: we test jtLeft and jtRight because LRswapping means could be symmetrical (but always actually Left here from our point of view)}
        //speed: no need to check assigned(rightChild) - safety only
        if assigned(rightChild) then begin rightChild.iTuple.clearToNulls(stmt); rightChild.iTuple.preInsert; end; //set to nulls
        res:=isTrue; //force output for left outer join
      end
      else
      begin
        repeat //24/07/00 added in case filtered multi-join with possible repeat failures
          //speed: no need to check assigned(leftChild) - safety only
          if assigned(rightChild) then rightChild.stop;   //stop (note may not have started at start & this causes a debugError message - todo avoid)
          if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
          if result<>ok then exit; //abort
          if not noMore then
          begin  //we have an outer candidate, (re)start the inner loop
            matchedForOuter:=false;
            //speed: remove assigned check - check once in start routine!
            if not assigned(rightChild) then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,'Missing right child',vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
              exit; //abort
            end;
            {Note: this re-start doesn't need a re-prePlan}
            innerNoMore:=False; //Fix: 12/03/00 only spotted after indexed children used...
                                //before: some part of rel.scanstart set noMore=False before/during 1st next (but not indexed scan)
                                //can remove this if/when .start resets noMore
            result:=rightChild.start; //Note: if inner is using an indexed-filter, this will re-evaluate its filter value (based on our current tuple)
                                      //which is fine, but we must ensure no optimisations that have been pushed to the children refer to the join tuple
                                      //otherwise they'd have no data to work on (until after the join tuple is built below...)
            if result=ok then
              result:=rightChild.next(innerNoMore);
            //else abort?


            {Since we might repeat this loop if inner is filtered & gives no match, we break out if we need to emit a left outer join output}
            if innerNoMore then
              if (joinType in [jtLeft,jtRight]) and not(matchedForOuter){=>true here} then
              begin {Note: we test jtLeft and jtRight because LRswapping means could be symmetrical (but always actually Left here from our point of view)}
                //speed: no need to check assigned(rightChild) - safety only
                if assigned(rightChild) then begin rightChild.iTuple.clearToNulls(stmt); rightChild.iTuple.preInsert; end; //set to nulls
                res:=isTrue; //force output for left outer join
                break; //exit the filtered next inner loop
              end
          end;
        until not(innerNoMore) or noMore; //i.e. repeat restart of inner loop until we do get a match (only needed in case inner is filtered)
      end;
    end;

    //note/speed: could skip this if we have forced/know-we-have-pushed an equi-join down to the child = all joinkey cases nowadays?
    //- e.g. if known-equi-join and not noMore then res:=isTrue
    if joinKey then //ensure both tuples match on the equijoin key //could do by just pre-reading key-join-columns? speed?
      if not noMore then
        if res<>isTrue then //don't key match for forced outers
        begin
          result:=CompareTupleKeysEQ(leftChild.iTuple,rightChild.iTuple,keyres);
          if result<>ok then exit;
          if not keyres then res:=isFalse; //abandon eval test & output
        end;
    //note: joinKey is no longer set, but should do the same optimisation & will use anodeRef.KeyColCount>0! speed!!!!

    //Note: we need to build this tuple from left & right children to pass to eval routine
    //- better if we could somehow point the eval routine at both children... speed
    //the key-equijoin filter above prevents us joining many tuples that don't match (e.g. join using)
    if not noMore then
      if res<>isFalse then
      begin //move the joined data into the join output tuple area
        {Note: the current output area for this non-materialised join is a
        single record buffer (i.e. as if a single version exists)
        Also, we only do a shallow copy of the data pointers
        }
        iTuple.clear(stmt); //speed - fastClear?
        for i:=1 to leftMapCount do
        begin
          if not anodeRef.LRswapped then
            iTuple.CopyColDataPtr(i-1,rightChild.iTuple,leftMap[i-1])  //after optimiser switch
          else
            iTuple.CopyColDataPtr(i-1,leftChild.iTuple,leftMap[i-1]);
        end;
        for i:=1 to rightMapCount do
        begin
          if not anodeRef.LRswapped then
            iTuple.CopyColDataPtr(leftMapCount+(i-1),leftChild.iTuple,rightMap[i-1]) //after optimiser switch
          else
            iTuple.CopyColDataPtr(leftMapCount+(i-1),rightChild.iTuple,rightMap[i-1]);
        end;
        {$IFDEF DEBUGDETAIL3}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('(pre-eval left ) %s',[leftChild.iTuple.Show(stmt)]),vDebugLow);
        log.add(stmt.who,where+routine,format('(pre-eval right) %s',[rightChild.iTuple.Show(stmt)]),vDebugLow);
        log.add(stmt.who,where+routine,format('(pre-eval) %s',[iTuple.Show(stmt)]),vDebugLow);
        {$ENDIF}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('(pre-eval) %s',[iTuple.ShowHeading]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;

    //speed: I'm sure (in future?) all such joinExpr parts will have been pushed further down than here, so no need to re-check here?
    //Note+: this is needed here for outer join-on to ensure we output the null halves properly:
    //       this is another reason why outer joins cannot be reordered by the optimiser...
    if not noMore then
      if res=isUnknown then //if not forced true already by outer join logic above, and not false by key equi-join
        if joinExpr then
        begin
          if EvalCondExpr(stmt,self,anodeRef.nodeRef.leftChild,res,agNone,false)<>ok then exit; //abort (silent)
        end
        else //no expression, so always true
          res:=isTrue;
  until noMore or (res=isTrue);

  if not noMore then //=>res=isTrue
  begin
    matchedForOuter:=true;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;
end; {next}

end.

unit uOptimiser;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Query optimiser and planner
}

//{$DEFINE NO_REWRITER} //avoid plan rewriter (i.e. join strategy optimiser): remove when live! - use db/server option
{$DEFINE MERGEJOIN} //use joinMerge instead of joinNestedLoop for joins USING
{$DEFINE DEBUG_DETAIL}

interface

uses uAlgebra, uStmt, uIterator, uSyntax{for ntJoinUsing, ntNOP and infixSyntax & root ref};

function CreatePlan(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr;var planRoot:TIterator):integer;
function Optimise(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr):integer;

var
  debugSyntaxExtraCreate:integer=0;
  debugSyntaxExtraDestroy:integer=0;

implementation

uses uGlobal, uTransaction, uIterProject, uIterSelect,
     uIterGroup,
     uIterJoinNestedLoop, uIterJoinMerge,
     uIterSort,
     uIterRelation, uIterSyntaxRelation,
     uIterInsert, uIterDelete, uIterUpdate,
     uIterSet,
     uIterInto,
     uLog, sysUtils,
     uTuple {just for unused result from FindCol},
     uRelation {for constraintListPtr},
     uMarshalGlobal {for errors};

const
  where='uOptimiser';
  Max_CanSeeCol_results=50; //i.e. since columns are unique per relation,
                            //     this puts a limit on the number of joined tables sharing a common attribute
                            //     which is referenced in a where/using/natural clause
                            //todo enlarge (or shrink if possible! since it specifies the array
                            //              sizes that get passed on the stack for canSeeCol())
                            //              - a more dynamic structure would be leaner!

function CreatePlan(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr;var planRoot:TIterator):integer;
{Convert the relational algebra tree into a corresponding iterator (physical) plan for execution

 IN           :
                st        the statement
                sRoot     the tree/subtree syntax root used to hang any new nodes from (to ensure garbage collection)
                aRoot     algebra tree/subtree root
 OUT          : planRoot  plan root = iterator chain root

 Note: this is capable of creating bushy iteration trees (from Joins)
       and if so the routine is recursive
       (although we now remove such bushyness before starting, so the recursion
        is practically only one level (i.e. antRelation))

 Note: this routine calls the optimise routine to find the best plan
}
const routine=':createPlan';
var
  raNode,raTemp,raProjectGroup:TAlgebraNodePtr;
  itNode,itNodeTemp,parentItNode,itHead:TIterator;
  parentParentItNode:TIterator;
  itNodeTemp2:TIterator;
  makeDistinct:boolean;
  mergeJoin:boolean;

  optimiseOk:integer;
begin
  result:=ok; //default

  {Assert we haven't already a plan attached}
  if planRoot<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Sub-query reference has already been assigned %d',[longint(planRoot)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
    exit;
  end;

  raProjectGroup:=nil;
  {Draw algebra tree
   Note: the way this routine currently works and is called:
    we will display the whole tree and then each right-bush (because of the recursion in joins)
  }
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,'',vDebugMedium); //need blank line in case we call more than once in succession
  {$ENDIF}
  //DisplayAlgebraTree(aroot);
  DisplayAnotatedAlgebraTree(aroot);

  {Find and return the best plan}
  //todo: we might need to call this once outside this routine since this one is recursive
  //      for sub-plans to the right of joins (Note: is this needed now we left-deep everything!??)
  //      Or, make the optimise not go right & wait for this calling routine to dictate the right subplan patterns
  optimiseOk:=ok;
  {$IFNDEF NO_REWRITER}
  if Ttransaction(st.owner).db.SysOption[otOptimiser].value<>0 then
  begin
    log.Status;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    //no use? displaySyntaxTree(aroot.nodeRef);
    {$ENDIF}
    {$ENDIF}
    optimiseOk:=Optimise(st,sroot,aroot); //note the result for later (i.e. can we trust some of the annotations?)
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    //no use? displaySyntaxTree(aroot.nodeRef);
    {$ENDIF}
    {$ENDIF}
    log.Status;
  end;
  //else optimiser disabled
  {$ENDIF}

  {$IFDEF DEBUG_LOG}
  log.quick('');
  {$ENDIF}
  DisplayAnotatedAlgebraTree(aroot);

  {Loop through algebra tree to create an iterator tree}
  //todo: maybe we should build from bottom up?
  parentParentItNode:=nil; //trace grandparent links down tree to be able to remove iterators links if necessary
  parentItNode:=nil; //trace parent links down tree to link iterators backwards
  itHead:=nil;
  itNode:=nil; //just to keep compiler quiet really
  raNode:=aroot;
  while raNode<>nil do
  begin
    case raNode.antype of
      antInsertion:
      begin
        itNode:=TIterInsert.create(st,raNode); //pass select-item list (syntax tree link)
        {$IFDEF DEBUG_LOG}
        log.quick(format('%p',[@itnode.anodeRef.nodeRef]));
        {$ENDIF}
      end;
      antUpdate:
      begin
        itNode:=TIterUpdate.create(st,raNode); //pass where child + update-assignment list
        {$IFDEF DEBUG_LOG}
        log.quick(format('%p',[@itnode.anodeRef.nodeRef]));
        {$ENDIF}
      end;
      antDeletion:
      begin
        itNode:=TIterDelete.create(st,raNode); //pass where child
        {$IFDEF DEBUG_LOG}
        log.quick(format('%p',[@itnode.anodeRef.nodeRef]));
        {$ENDIF}
      end;
      antInto:
      begin
        itNode:=TIterInto.create(st,raNode);
        {$IFDEF DEBUG_LOG}
        log.quick(format('%d',[longint(itnode)]));
        {$ENDIF}
      end;
      antProjection:
      begin
        itNode:=TIterProject.create(st,raNode); //pass select-item list (syntax tree link)
        {$IFDEF DEBUG_LOG}
        log.quick(format('%d',[longint(itnode)]));
        {$ENDIF}
        raProjectGroup:=raNode; //store in case we have a group-by below (to ensure aggregates are evaluated in proper place)
        //if this contains aggregates (i.e. detect & mark here rather than IterGroup.start)
        //then we must have/add a group-by to calculate them (or can IterProject handle this!? - hopefully=cleaner?)

        //todo: if we knew now that we would not need this iterator node then it would be better to not create it!
        //      we need to at the moment so we can pass the raProjectGroup to the lower level antGroup node...
      end;
      antGroup: {includes Having}
      begin
        //todo warning (here or in IterGroup?) if raProjectGroup is null
        itNode:=TIterGroup.create(st,raNode,raProjectGroup); //pass group-by column list (syntax tree link)
                                                                 //     + any Having expression (syntax tree link)
                                                                 //also pass Project node for pre-calc of any aggregates for Iter nodes above - else they won't be available
                                                             //this effectively combines the IterProject with the IterGroup and so IterProject can do no work....

        {reset raProjectGroup now we've used it}
        raProjectGroup:=nil;
      end;
      antSort:
      begin
        if raNode.nodeRef<>nil then
          itNode:=TIterSort.create(st,raNode,False) //pass order by column list (syntax tree link)
        else //=> duplicate removal  //todo use a better flag - on the anode?
          itNode:=TIterSort.create(st,raNode,True); //pass order by column list (syntax tree link)
      end;
      antSelection:
      begin
        itNode:=TIterSelect.create(st,raNode); //pass cond-expression (syntax tree link)
      end;
      antInnerJoin,antLeftJoin,antRightJoin,antFullJoin,antUnionJoin:
      begin
        //todo (here?) decide which kind of join node to execute
        {ok, when can/should we use mergeJoin:
         Minimum requirement:
           at least 1 equi-join

         Choose over nested loop if:
           left, right, full, union (i.e. more reliable or only way!)
           inner & no index on right (todo make right biggest) & right>X (X=10% of buffersize? depends on current buffer users)
           higher level requires sorting by equi-join column(s)
        }
        mergeJoin:=False; //i.e. default to nestedLoop

        {$IFDEF MERGEJOIN}
        //Note: the following should not always be done - may have option & often be better to joinNL
        if (optimiseOk=ok){only if the optimiser finished ok} and (raNode.optimiserSuggestion=osMergeJoin) then
          mergeJoin:=True;
        {$ENDIF}

        if not mergeJoin then
        begin //nested loop join
          case raNode.antype of
            //debug antInnerJoin: itNode:=TIterJoinMerge.create(tr,raNode,jtInner);
            antInnerJoin: itNode:=TIterJoinNestedLoop.create(st,raNode,jtInner);
            antLeftJoin:  itNode:=TIterJoinNestedLoop.create(st,raNode,jtLeft);
            antRightJoin: itNode:=TIterJoinNestedLoop.create(st,raNode,jtRight);
            (*17/01/03 bug fix: nested loop join simply cannot handle these types of joins
                       so better to reject here than fail with an assertion in iterjoinnestedloop
                       note: mergejoin didn't take them because it requires an equijoin
                            (although should be able to handle no on/using at all?)
            antFullJoin:  itNode:=TIterJoinNestedLoop.create(st,raNode,jtFull);
            antUnionJoin: itNode:=TIterJoinNestedLoop.create(st,raNode,jtUnion);
            *)
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Join not fully implemented yet (half-recognised by optimiser logic)',vAssertion); //should never happen!
            {$ENDIF}
            st.addError(seSyntaxInvalidJoin,format(seSyntaxInvalidJoinText,[nil]));
            result:=fail;
            exit;
          end; {case}

          {link right child}
          raTemp:=raNode.rightChild;
          itNodeTemp:=nil; //zeroise - createPlan asserts it's nil
          result:=CreatePlan(st,sroot,raTemp,itNodeTemp);  //recursion
          if result<>ok then
          begin
            //todo error message?
            exit;
          end;

          itNode.rightChild:=itNodeTemp; //could be bushy!

        end
        else
        begin //merge join
          case raNode.antype of
            antInnerJoin: itNode:=TIterJoinMerge.create(st,raNode,jtInner);
            antLeftJoin:  itNode:=TIterJoinMerge.create(st,raNode,jtLeft);
            antRightJoin: itNode:=TIterJoinMerge.create(st,raNode,jtRight);
            antFullJoin:  itNode:=TIterJoinMerge.create(st,raNode,jtFull);
            antUnionJoin: itNode:=TIterJoinMerge.create(st,raNode,jtUnion);
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,'Join not fully implemented yet (half-recognised by optimiser logic)',vAssertion); //should never happen!
            {$ENDIF}
            result:=fail;
            exit;
          end; {case}

          {link right child}
          raTemp:=raNode.rightChild;
          itNodeTemp:=nil; //zeroise - createPlan asserts it's nil
          result:=CreatePlan(st,sroot,raTemp,itNodeTemp);  //recursion
          if result<>ok then
          begin
            //todo error message?
            exit;
          end;

          {Note: the keys for these sort children will be overridden by the JoinMerge pre-plan (i.e. after any implicit equi-joins have been prepared)}
          {Insert a sort for right}
          itNodeTemp2:=TIterSort.create(st,nil{raNode},False); //todo: pass order by column list (syntax tree link) - if higher level=distinct, pass distinct now! speed!
          itNodeTemp2.leftChild:=itNodeTemp; //could be bushy!
          itNode.rightChild:=itNodeTemp2; //link back

          {Insert a sort for left}
          parentParentItNode:=parentItNode; //track grandparent in case we need to remove an iterProject node
          if parentItNode<>nil then parentItNode.leftChild:=itNode; //link back
          itNode.parent:=parentItNode; //set parent pointer (for runtime use)
          parentItNode:=itNode; //this is new parent for next level down
          if itHead=nil then itHead:=itNode; //initial node=header/root
          itNode:=TIterSort.create(st,nil{raNode},False); //todo: pass order by column list (syntax tree link) - if higher level=distinct, pass distinct now! speed!
        end;
      end;
      antUnion,antExcept,antIntersect,
      antUnionAll,antExceptAll,antIntersectAll:
      begin
        case raNode.antype of
          antUnion:        itNode:=TIterSet.create(st,raNode,stUnion);
          antUnionAll:     itNode:=TIterSet.create(st,raNode,stUnionAll);
          antExcept:       itNode:=TIterSet.create(st,raNode,stExcept);
          antExceptAll:    itNode:=TIterSet.create(st,raNode,stExceptAll);
          antIntersect:    itNode:=TIterSet.create(st,raNode,stIntersect);
          antIntersectAll: itNode:=TIterSet.create(st,raNode,stIntersectAll);
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Unknown Set operation',vAssertion); //should never happen!
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}

        case raNode.antype of
          antUnion,antExcept,antIntersect:  makeDistinct:=True; //default=removed duplicates from children
        else
          makeDistinct:=False; //i.e. ALL was specified
        end; {case}

        {link right child}
        raTemp:=raNode.rightChild;
        itNodeTemp:=nil; //zeroise - createPlan asserts it's nil
        result:=CreatePlan(st,sroot,raTemp,itNodeTemp);  //recursion
        if result<>ok then
        begin
          //todo error message?
          exit;
        end;

        {Note: the keys for these sort children will be overridden by the Set pre-plan (i.e. after any corresponding clause has been prepared)}
        {Insert a sort for right}
        itNodeTemp2:=TIterSort.create(st,raNode,makeDistinct); //raNode contains any corresponding link
        itNodeTemp2.leftChild:=itNodeTemp; //could be bushy!
        itNode.rightChild:=itNodeTemp2; //link back

        {Insert a sort for left}
        parentParentItNode:=parentItNode; //track grandparent in case we need to remove an iterProject node
        if parentItNode<>nil then parentItNode.leftChild:=itNode; //link back
        itNode.parent:=parentItNode; //set parent pointer (for runtime use)
        parentItNode:=itNode; //this is new parent for next level down
        if itHead=nil then itHead:=itNode; //initial node=header/root
        itNode:=TIterSort.create(st,raNode,makeDistinct); //raNode contains any corresponding link
      end; {union/except/intersect(All)}
      antRelation:  //this will be a single left-most leaf
      begin
        itNode:=TIterRelation.create(st,raNode);
        //Note: keep in sync (1)
      end;
      antSyntaxRelation:  //this will be a single left-most leaf
      begin
        itNode:=TIterSyntaxRelation.create(st,raNode);
        //Note: keep in sync (1)
      end;
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Unknown algebra plan node',vDebugError);
      {$ENDIF}
      itNode:=nil;
    end; {case}

    {Hack(?) to remove an iterProject preceding a group-by, else we would both try and use the syntax
     node's column source pointers. IterGroup does everything the project would need to do, so we remove
     the redundant iterProject - also improves speed/memory use!}
    if itNode is TIterGroup then
      if parentItNode is TIterProject then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Removing unnecessary iterProject node (after iterGroup): %d',[longint(parentItNode)]),vDebugLow);
        {$ENDIF}
        if itHead=parentItNode then
          itHead:=nil //was root, so set reset root
        else
        begin
          if assigned(parentParentItNode) then parentParentItNode.leftChild:=itNode; //leave root but grandparent must skip the about to be zapped parent
        end;
        parentItNode.free; //destroy iterProject node
        parentItNode:=parentParentItNode; //get iterProject's parent to skip it
      end;
    {Link sub-tree back up to its parent}
    parentParentItNode:=parentItNode; //track grandparent in case we need to remove an iterProject node
    if parentItNode<>nil then parentItNode.leftChild:=itNode; //link back
    itNode.parent:=parentItNode; //set parent pointer (for runtime use)
    parentItNode:=itNode; //this is new parent for next level down
    if itHead=nil then itHead:=itNode; //initial node=header/root

    raNode:=raNode.leftChild; //move to next level down (left-deep tree)
                              //this also applies for non-branching 'straight down' paths (e.g. projection -> selection)
  end; {while}

  {Return plan}
  //DisplayIteratorTree(itHead);
  {$IFDEF DEBUG_LOG}
  log.quick('DEBUG:');
  {$ENDIF}
  DisplayAnotatedIteratorTree(itHead);
  planRoot:=itHead;
end; {CreatePlan}

//todo remove? leave to iter.optimise once we've found best plan
function pushDown(a:TAlgebraNodePtr;n:TSyntaxNodePtr):integer;
{}
begin
  {Is this the lowest level for this node? If so, push it down to here}
  result:=ok;

  {Push expressions at this level down to their lowest level}
  if a.anType in [antSelection,antInnerJoin,antLeftJoin,antRightJoin,antFullJoin,antRelation,antSyntaxRelation] then
  begin //we can have expressions here
    n:=a.nodeRef;
    while n<>nil do
    begin
      if n.optimised<>ptPulled then
      begin //not been pushed down yet
        if a.leftChild<>nil then pushDown(a.leftChild,n);
        if a.rightChild<>nil then pushDown(a.rightChild,n);
      end;
    end;

  end;
end; {pushDown}

function ensureLeftDeepOnly(st:TStmt;atree:TAlgebraNodePtr):integer;
{Since we can't quite get yacc to build pure left-deep trees,
 we swap any that were built as right-deep now (or if just simple 2-table join & left-outer => don't reverse!)
 This should be ok because we traverse downwards...
 ++ but the side-effect is that column projecting is reversed (R-L)
    so in the iterJoinNestedLoop prepare/next, we reverse the projection if we are a joinKey/joinExpr node
    i.e. one that would have been switched round here
 ++ we can't (yet) do this in set operations so we don't reverse them - is this detrimental? I don't think so
    since we (currently) have to treat left & right as totally separate subtrees
}
const routine=':ensureLeftDeepOnly';
var
  raTemp:TAlgebraNodePtr;
begin
  result:=ok;

  if atree=nil then exit; //done this branch

  if (
       ( (atree.rightChild<>nil) and (atree.rightChild.anType in antJoins) )  //[antInnerJoin,antLeftJoin,antRightJoin,antFullJoin,antUnionJoin]) )
       or ((atree.anType=antLeftJoin) and not(atree.leftChild.anType in antJoins)) //[antInnerJoin,antLeftJoin,antRightJoin,antFullJoin,antUnionJoin]))
     )
     and not(atree.anType in antSets) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Swapping left (%p) & right (%p) child nodes of %p during plan build (to fix grammar into left-deep)',[atree.leftChild,atree.rightChild,atree]),vDebugMedium);
    {$ENDIF}
    raTemp:=atree.rightChild;
    atree.rightChild:=atree.leftChild;
    atree.leftChild:=raTemp;
    atree.LRswapped:=True;
  end;
  ensureLeftDeepOnly(st,atree.leftChild);  //recurse
  ensureLeftDeepOnly(st,atree.rightChild); //recurse
end; {ensureLeftDeepOnly}

function JustReferencesChildren(snode:TSyntaxNodePtr;lr,rr:TAlgebraNodePtr;var lcid,rcid:TColId;var lcref,rcref:ColRef):boolean;
{Checks whether this selection (syntax node) just references these two children
 and so could be a candidate join filter expression

 IN:       snode        the syntax node of the expression, e.g. ntEqual
           lr           the left algebra relation
           rr           the right algebra relation
 OUT:      lcid         the left colId matched if True
           rcid         the right colId matched if True
           lcref        the left cRef matched if True
           rcref        the right cRef matched if True

 RETURNS:  True/False

 //todo remove check for nextNode=nil, i.e. handle multiple elements
}
  function safeType(n:TSyntaxNodePtr):nodeType;
  {Guard from nil for simplified comparisons} //todo make global? too safe?
  begin
    if n=nil then result:=ntNOP else result:=n.nType;
  end;
const left=0; right=1;
var
  cTuple:array [0..Max_CanSeeCol_results{todo reduce!}] of TTuple;
  cRange:array [0..Max_CanSeeCol_results{todo reduce!}] of string;
  cId:array [left..right{relation},left..right{operand}] of array [0..Max_CanSeeCol_results{todo reduce!}] of TColId;
  res:array [left..right{relation},left..right{operand}] of integer;
  cRef:array [left..right{relation},left..right{operand}] of array [0..Max_CanSeeCol_results{todo reduce!}] of ColRef;
  i:integer;
begin
  result:=false;

  (*todo ifdef safety
  //prevent nasty errors
  for i:=0 to Max_CanSeeCol_results do
  begin
    cTuple[i]:=nil;
    cRange[i]:=''; //overkill?
    cId[left,left[i]:=InvalidColId;
    cId[left,right[i]:=InvalidColId;
    cId[right,left[i]:=InvalidColId;
    cId[right,right[i]:=InvalidColId;
    res[left,left]:=0;
    res[left,right]:=0;
    res[right,left]:=0;
    res[right,right]:=0;
    cRef[left,left[i]:=0;
    cRef[left,right[i]:=0;
    cRef[right,left[i]:=0;
    cRef[right,left[i]:=0;
  end;
  *)

  if (safeType(snode.leftChild)=ntRowConstructor) and (snode.leftChild.nextNode=nil) then //L=single element
    if (safeType(snode.rightChild)=ntRowConstructor) and (snode.rightChild.nextNode=nil) then //R=single element
      if (safeType(snode.leftChild.leftChild) in [ntNumericExp,ntCharacterExp]) then //L=exp
        if (safeType(snode.rightChild.leftChild) in [ntNumericExp,ntCharacterExp]) then //R=exp
        begin
          if (safeType(snode.leftChild.leftChild.leftChild)=ntColumnRef) AND //L=colref
             (safeType(snode.rightChild.leftChild.leftChild)=ntColumnRef) then //R=colref
          begin
            {Lookup the two columns in the two relations}
            res[left,left]:=0;
            res[left,right]:=0;
            res[right,left]:=0;
            res[right,right]:=0;
            if CanSeeCol(lr,snode.leftChild.leftChild.leftChild,'',res[left,left],cTuple,cRef[left,left],cId[left,left],cRange)<>ok then exit; //abort
            if CanSeeCol(lr,snode.rightChild.leftChild.leftChild,'',res[left,right],cTuple,cRef[left,right],cId[left,right],cRange)<>ok then exit; //abort
            if CanSeeCol(rr,snode.leftChild.leftChild.leftChild,'',res[right,left],cTuple,cRef[right,left],cId[right,left],cRange)<>ok then exit; //abort
            if CanSeeCol(rr,snode.rightChild.leftChild.leftChild,'',res[right,right],cTuple,cRef[right,right],cId[right,right],cRange)<>ok then exit; //abort

            if ((res[left,left]=1) and (res[right,right]=1)) or ((res[left,right]=1) and (res[right,left]=1)) then
            begin //valid combination of matches, i.e. l[L]=r[R] or r[L]=l[R]
              result:=True;
              if res[left,left]=1 then
              begin
                lcid:=cid[left,left][0];
                lcref:=cref[left,left][0];
              end
              else
              begin
                lcid:=cid[left,right][0];
                lcref:=cref[left,right][0];
              end;
              if res[right,right]=1 then
              begin
                rcid:=cid[right,right][0];
                rcref:=cref[right,right][0];
              end
              else
              begin
                rcid:=cid[right,left][0];
                rcref:=cref[right,left][0];
              end;
            end;

            //todo if res[all] then self-join = ok? problems for later stage? special cost=1-1
          end;
        end;
end;

function OptimiseJoins(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr):integer;
{Optimise a join portion of the relational algebra tree

 IN           :
                st          the statement
                sRoot       the tree/subtree syntax root used to hang any new nodes from (to ensure garbage collection)
                aRoot       algebra join subtree root

 RESULT:      ok else fail (currently plan could be corrupt if fail! todo prevent!)

 todo: create multiple alternative plans rather than re-ordering existing algebra
       tree: this would allow more flexible and imaginative plans

     Note:
       May add a selection root if none exists, but will leave a as the pointer
       by sneakily copying the old root to a new sub-node and overwriting the original
       root node with any new selection node.
}
const
  routine=':optimiseJoins';
  MAX_RELS=100; //todo move to global & make infinite
  MAX_PLANS=MAX_RELS; //currently greedy & square
  MAX_SELECTIONS=1; //todo: move to global & make bigger if more than 1 could ever be needed
type
  Trel=record
    parentNode:TAlgebraNodePtr; //for implementing chosen plan via repointing
    parentFromLeft:boolean; //false=fromRight
    anode:TAlgebraNodePtr;
    state:integer;  //stores 0=available or else join cost for current plan
    estimatedSize:integer;
    joinColsCount:integer;
    joinCols:array [1..MaxCol] of TColId; //temporary area for tracking join keys
  end;
  Tplan=record
    plan:array[0..MAX_RELS] of integer; //i.e. point to rels[] subscript
    cost:integer;
  end;
var
  //atree:TAlgebraNodePtr;
  n:TSyntaxNodePtr;

  relsCount,relsOrderCount:integer;
  rels:array [0..MAX_RELS] of Trel;

  plansCount:integer;
  plans:array [0..MAX_PLANS] of Tplan;

  selectionsCount:integer;
  selections:array [0..MAX_SELECTIONS] of TAlgebraNodePtr;

  i,{j,}si,planStep,best,bestCost:integer;
  lcid,rcid:TColId;
  lcref,rcref:ColRef;

  constraintPtr:TConstraintListPtr;

  needProjection:boolean;


    procedure findRels(a:TAlgebraNodePtr);
    {Locates the moveable relations in the join subtree
     starting at the bottom left & working upwards

     IN : a        the root node to search from
     OUT: rels[] array & relsCount

     Assumes relsCount has been reset before first call

     Note: Currently only looks leftdeep
           (in sync with OptimiseFindJoins skip logic), e.g:
                J
               J R
              J R
             R R

     Note: it is important that this find the relations in order starting at bottom-left
           so the implementation can map the best plan in the best way.
           This is not necessarily the user-specified order: see findRelsOriginalOrder
    }
    begin
      if a=nil then exit;

      //todo in future allow non-relation relations here, e.g. NJ(project,project) for now allow old join-key at iter stage to catch these
      if a.anType in antRelations then
      begin //found one
        rels[relsCount].parentNode:=a.parent; //todo assert a.parent<>nil
        rels[relsCount].parentFromLeft:=(rels[relsCount].parentNode.leftChild=a); //we record it now for repointing to work properly
        rels[relsCount].anode:=a;

        {Get statistics}
        if a.anType=antSyntaxRelation then
          rels[relsCount].estimatedSize:=1 //todo count the actual number of rows! could be many!
        else
          rels[relsCount].estimatedSize:=a.rel.EstimateSize(st)+1; //plus 1 to improve multiplication costs on small tables

        inc(relsCount);
      end;

      if (a.anType in antJoins) then //debug fix for FK complex J(p,p)
        findRels(a.leftChild);  //recurse

      if (a.anType in antJoins) then //debug fix for FK complex J(p,p)
        findRels(a.rightChild); //recurse
    end; {findRels}

    procedure findRelsOriginalOrder(a:TAlgebraNodePtr);
    {Finds the relations' original ordering by navigating the subtree and
     taking account of the swapped flag.
     This route differs from the findRels route and is closely tied
     to the yacc building code.

     IN : a        the root node to search from
     OUT: sets rels[].anode.originalOrder

     Assumes findRels has been called
     Assumes relsOrderCount=0

     Note: keep in sync with findRels navigation
    }
    begin
      if a=nil then exit;

      if a.anType in antRelations then
      begin //found one
        {Store this original user ordering}
        a.originalOrder:=relsOrderCount+1;

        inc(relsOrderCount);
      end;
      if a.anType in antSubqueryHeaders then
      begin //found a high level projection that will need an ordering in case it is further joined
        {Store this original user ordering}
        a.originalOrder:=relsOrderCount+1;
        //we don't increment here though... we don't yet treat these as re-orderable sections
        //todo! treat as if they were relations! - bring up size etc.
      end;

      if a.LRswapped then
      begin
        {Note: keep this in sync with the findRels navigation}
        findRelsOriginalOrder(a.leftChild);  //recurse
        findRelsOriginalOrder(a.rightChild); //recurse
      end
      else //reverse order to ensure we get the originalOrder correct
      begin
        findRelsOriginalOrder(a.rightChild); //recurse
        findRelsOriginalOrder(a.leftChild);  //recurse
      end;
    end; {findRelsOriginalOrder}

    procedure findSelections(a:TAlgebraNodePtr);
    {IN : a        the root node to search from
     OUT: selections[] array & selectionsCount

     Assumes selectionsCount has been reset before first call
     Currently assumes max of 1 selection node is to be found
    }
    begin
      while a<>nil do
      begin

        if a.anType in [antSelection] then
        begin //found one
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log.add('',where+routine,format('selection node %d found at %p',[selectionsCount,a]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          selections[selectionsCount]:=a;
          inc(selectionsCount);
          exit; //done
        end;

        {todo: check these cover all cases}
        if a.anType in antSubqueryHeaders then
          exit; //abort: leaving our subquery

        a:=a.parent; //move up through the tree
      end;
    end; {findSelections}

    procedure insertSelection(s:TSyntaxNodePtr;a:TAlgebraNodePtr);
    {IN :
          s        the tree/subtree syntax root used to hang any new nodes from (to ensure garbage collection)
          a        the root node to insert above
     OUT: set selections[] array & selectionsCount=1

     Note:
       May add a selection root if none exists, but will leave a as the pointer
       by sneakily copying the old root to a new sub-node and overwriting the original
       root node with any new selection node.

     Assumes 0 selections have already been found
    }
    var
      child,raNode,raTemp,raTemp1,raTemp2:TAlgebraNodePtr;
      snode:TSyntaxNodePtr;
    begin
      child:=nil; //assumes caller is not from selection/subqueryHeader

      while a<>nil do
      begin

        if a.anType in [antSelection] then
        begin //found one
          exit; //abort, one already exists
        end;

        {todo: check these cover all cases}
        if a.anType in antSubqueryHeaders then
        begin
          {Insert the new selection node & point to a stub syntax tree}
          if child<>a.rightChild then
          begin
            raTemp:=a.leftChild;
            if raTemp<>nil then unlinkALeftChild(a);
            snode:=nil;
            {We need a stub syntax tree in case we end up with no other criteria}
            snode:=mkLeaf(st.srootAlloc,ntNOP,ctUnknown,0,0);
            inc(debugSyntaxExtraCreate);
            chainPrev(s,snode); //Note: we must link it into the syntax tree to allow it to be cleared up: todo does chainPrev prevent side-effects to existing tree traversals?
            raNode:=mkANode(antSelection,snode,nil,raTemp,nil);
            linkALeftChild(a,raNode);
          end
          else
          begin
            raTemp:=a.rightChild;
            if raTemp<>nil then unlinkARightChild(a);
            snode:=nil;
            {We need a stub syntax tree in case we end up with no other criteria}
            snode:=mkLeaf(st.srootAlloc,ntNOP,ctUnknown,0,0);
            inc(debugSyntaxExtraCreate);
            chainPrev(s,snode); //Note: we must link it into the syntax tree to allow it to be cleared up: todo does chainPrev prevent side-effects to existing tree traversals?
            raNode:=mkANode(antSelection,snode,nil,raTemp,nil);
            linkARightChild(a,raNode);
          end;

          selections[selectionsCount]:=raNode;
          inc(selectionsCount);
          exit; //done
        end;

        if a.parent=nil then
        begin //there is no existing projection/sort/group so we add the select at the top
          {Insert the new selection node}
          snode:=nil;
          raTemp:=a.leftChild;
          raTemp1:=a.rightChild;
          {Unlink children - we will move them down to the new node}
          if raTemp<>nil then unlinkALeftChild(a);
          if raTemp1<>nil then unlinkARightChild(a);
          {Create a new node, relink the root's children to it & copy the details from the existing root}
          raNode:=mkANode(a.anType,a.nodeRef,a.exprNodeRef,raTemp,raTemp1); //note: left/right will have their parents reset
          copyANodeData(a,raNode);
          {Now overwrite the original unlinked root node with our new selection details}
          raTemp2:=mkANode(antSelection,snode,nil,nil,nil);
          try
            copyANodeData(raTemp2,a);
            a.nodeRef:=nil;
            a.exprNodeRef:=nil;
          finally
            DeleteAlgebraTree(raTemp2); //todo check result
          end; {try}
          {Now relink the new root to the new node}
          linkALeftChild(a,raNode);

          selections[selectionsCount]:=a;
          inc(selectionsCount);

          exit; //done
        end;

        child:=a; //keep track of where we're coming from in case we hit a union/except/intersect
        a:=a.parent; //move up through the tree
      end;
    end; {insertSelection}

    procedure insertProjection(a:TAlgebraNodePtr);
    {IN : a        the root node to insert above

     Note:
       May add a projection * root if none exists, but will leave a as the pointer
       by sneakily copying the old root to a new sub-node and overwriting the original
       root node with any new projection node.

     Assumes projection is needed, i.e. join using/natural
    }
    var
      child,raNode,raTemp,raTemp1,raTemp2:TAlgebraNodePtr;
      snode:TSyntaxNodePtr;
    begin
      child:=nil; //assumes caller is not from projection/group

      while a<>nil do
      begin

        if a.anType in [antProjection,antGroup] then
        begin //found one
          exit; //abort, one already exists
        end;

        {todo: check these cover all cases}
        if a.anType in antSubqueryHeaders then
        begin
          {Insert the new projection node & point to an * syntax tree}
          if child<>a.rightChild then
          begin
            raTemp:=a.leftChild;
            if raTemp<>nil then unlinkALeftChild(a);
            snode:=mkNode(st.srootAlloc,ntSelectAll,ctUnknown,nil,nil);
            inc(debugSyntaxExtraCreate);
            raNode:=mkANode(antProjection,snode,nil,raTemp,nil);
            linkALeftChild(a,raNode);
          end
          else
          begin
            raTemp:=a.rightChild;
            if raTemp<>nil then unlinkARightChild(a);
            snode:=mkNode(st.srootAlloc,ntSelectAll,ctUnknown,nil,nil);
            inc(debugSyntaxExtraCreate);
            raNode:=mkANode(antProjection,snode,nil,raTemp,nil);
            linkARightChild(a,raNode);
          end;

          exit; //done
        end;

        if a.parent=nil then
        begin //there is no existing projection/sort/group so we add the project at the top
          {Insert the new projection node}
          raTemp:=a.leftChild;
          raTemp1:=a.rightChild;
          {Unlink children - we will move them down to the new node}
          if raTemp<>nil then unlinkALeftChild(a);
          if raTemp1<>nil then unlinkARightChild(a);
          {Create a new node, relink the root's children to it & copy the details from the existing root}
          raNode:=mkANode(a.anType,a.nodeRef,a.exprNodeRef,raTemp,raTemp1); //note: left/right will have their parents reset
          copyANodeData(a,raNode);
          {Now overwrite the original unlinked root node with our new projection details}
          raTemp2:=mkANode(antProjection,nil,nil,nil,nil);
          try
            copyANodeData(raTemp2,a);
            snode:=mkNode(st.srootAlloc,ntSelectAll,ctUnknown,nil,nil);
            inc(debugSyntaxExtraCreate);
            a.nodeRef:=snode;
            a.exprNodeRef:=nil;
          finally
            DeleteAlgebraTree(raTemp2); //todo check result
          end; {try}
          {Now relink the new root to the new node}
          linkALeftChild(a,raNode);

          exit; //done
        end;

        child:=a; //keep track of where we're coming from in case we hit a union/except/intersect
        a:=a.parent; //move up through the tree
      end;
    end; {insertProjection}

    function addSelectionsForJoins(a:TAlgebraNodePtr):integer;
    {IN :      a        the root node to search from
     RETURNS:  ok, else fail

     Note: could change a if a new selection root is required

     Adds implied join WHERE clauses to the nearest WHERE clause.
     Note: the equi-joins created are ntEqualOrNull to ensure Unknown is treated as True, e.g. for outer joins.
     Note: the join prePlan/optimise execution must currently still bring down and apply the conditions
           to make optimal use: todo in future this unit should do that...

     Assumes selections[0] node exists & currently uses it as the WHERE clause

     Assumes:
       a has a selection node already available, i.e. selectionsCount>0

     Note: Currently looks bushy and not only at antCommutativeJoins (i.e. all joins are processed this way)
           Since this could mean we see the same subtree twice, optimiserSuggestion is used to flag a join as processed

           Currently copes with ambiguous children by creating a join condition
           for every combination, e.g. A(a,b,c) JOIN B(b,c,d) NJOIN C(a,b,c,d)
           would give for the NJOIN: A.a=C.a & A.b=C.b & A.c=C.c
                                             & B.b=C.b & B.c=C.c & B.d=C.d
                                             \----ambiguous----/
           i.e. we insist the ambigous A/B.b and A/B.c are equal
           but I think such ambigous joins (C.b and C.c only) should give syntax errors!
           We do this to allow the following, since we don't project out the common columns
           until the end because we could re-arrange the join order:
             A(a,b,c) NJOIN B(b,c,d) NJOIN C(a,b,c,d)
           would give for the NJOIN: A.a=C.a & A.b=C.b & A.c=C.c
                                             & B.b=C.b & B.c=C.c & B.d=C.d
                                             \----ambiguous----/
                                              but implied equal
                                                  by NJOIN!
           todo: so if we syntax error on the first NJOIN C because of b and c
                 and ignore ambiguous matches that have been flagged as 'common'
                 then we needn't handle multiple matches so explicitly/at all.
           If/when we join with a projection we could have duplicates, but still syntax error.
           So: flag common columns from bottom-up before adding conditions.
           For now: maybe the extra join conditions will speed up subtree joins?
           i.e. transitive. So ignore ambiguity & force all equal & give syntax error in future

           This also gets called for non-re-orderable joins

           +Problem:
             [A(a,b,c) JOIN B(b,c,d)]asX NJOIN A(a,b,c)
             would give A.a=A.a etc. rather than X.a=A.a... we pass back rangeNames for each match & so should never be ambiguous results?

     Side-effects:
       modifes the selections[] node by adding artificial WHERE conditions
       - these will be removed by the syntax-tree disposal routines

       sets commonColumn on underlying relations for future natural projections
       (also can indicate left-right outer common column preference to coalesce nulls properly)

       sets optimiserSuggestion as each node is processed
    }
    const routine=':addSelectionsForJoins';
    var
      leftcTuple,rightcTuple:array [0..Max_CanSeeCol_results{todo reduce!}] of TTuple;
      cRange:array [0..Max_CanSeeCol_results{todo reduce!}] of string;
      cId:array [0..Max_CanSeeCol_results{todo reduce!}] of TColId;
      lres,rres:integer;
      i,j:integer;
      leftcRef,rightcRef:array [0..Max_CanSeeCol_results{todo reduce!}] of ColRef;
      nhead,n,leftNode,rightNode,subNode,tempJoinKeyNode:TSyntaxNodePtr;

      function buildColumnReference(cTuple:TTuple;cRef:ColRef;cRange:string):TSyntaxNodePtr;
      {Create an artifical syntax node representing the specified column
       with its full reference details to allow it to be moved out of its local
       join scope

       IN:      cTuple - the tuple reference
                cRef   - the column subscript
                cRange - if not '' then this cRange overrides any column prefix, e.g. via higher alias e.g. self-joins
       RETURNS: the syntax node (ntRowConstructor) representing the column reference
                nil=error
      }
      const routine=':buildColumnReference';
      var
        tempNode,tempNode1,tempNode2,tempNode3:TSyntaxNodePtr;
      begin
        result:=nil;

        //todo: keep in sync. with lex install_id routine:
        {Column}
        tempNode1:=mkLeaf(st.srootAlloc,ntId,ctUnknown,0,0); //todo id_count;
        inc(debugSyntaxExtraCreate);
        tempNode1.idVal:=cTuple.fColDef[cRef].name;
        tempNode1.nullVal:=false;
        tempNode1.line:=0; tempNode1.col:=0;

        {Table/range}
        tempNode:=mkLeaf(st.srootAlloc,ntId,ctUnknown,0,0); //todo id_count;
        inc(debugSyntaxExtraCreate);
        if cRange<>'' then
          tempNode.idVal:=cRange
        else
          if TAlgebraNodePtr(cTuple.fColDef[cRef].sourceRange).rangeName<>'' then
            tempNode.idVal:=TAlgebraNodePtr(cTuple.fColDef[cRef].sourceRange).rangeName
          else
            tempNode.idVal:=TAlgebraNodePtr(cTuple.fColDef[cRef].sourceRange).tableName;
        tempNode.nullVal:=false;
        tempNode.line:=0; tempNode.col:=0;

        {Schema (unless range alias specified)}
        tempNode3:=nil;
        if (cRange='') and (TAlgebraNodePtr(cTuple.fColDef[cRef].sourceRange).rangeName='') then
        begin
          tempNode3:=mkLeaf(st.srootAlloc,ntId,ctUnknown,0,0); //todo id_count
          inc(debugSyntaxExtraCreate);
          tempNode3.idVal:=TAlgebraNodePtr(cTuple.fColDef[cRef].sourceRange).schemaName;
          tempNode3.nullVal:=false;
          tempNode3.line:=0; tempNode3.col:=0;

          tempNode3:=mkNode(st.srootAlloc,ntSchema,ctUnknown,nil,tempNode3);
          inc(debugSyntaxExtraCreate);
        end;

        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.add('',where+routine,format('building join-key sub-tree for: %s.%s',[tempNode.idVal,tempNode1.idVal]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        //todo: keep in sync. with yacc routines:
        tempNode:=mkNode(st.srootAlloc,ntTable,ctUnknown,tempNode3,tempNode);
        inc(debugSyntaxExtraCreate);
        tempNode1:=mkNode(st.srootAlloc,ntColumnRef,ctUnknown,tempNode,tempNode1);
        inc(debugSyntaxExtraCreate);
        tempNode1.systemNode:=True; //flag this as a system-generated column ref so FindCol will allow specifics for natural join common columns
        tempNode1:=mkNode(st.srootAlloc,ntCharacterExp{doesn't matter},ctUnknown{debug CASE? ctChar},tempNode1,nil);
        inc(debugSyntaxExtraCreate);
        tempNode1:=mkNode(st.srootAlloc,ntRowConstructor,ctUnknown,tempNode1,nil);
        inc(debugSyntaxExtraCreate);

        result:=tempNode1;
      end; {buildColumnReference}

      function beforeSubqueryHeader(a:TAlgebraNodePtr):boolean;
      {Allow optimisation of this join-child?

       todo
         prefix function name when we know exactly what it does!
      }
      begin
        if a=nil then
        begin
          result:=True; //todo ok? should never happen - would hit relation first!?
          exit;
        end;
        if a.anType in antRelations then
        begin
          result:=True; //ok, found before a stopper - bounce back
          exit;
        end
        else
        begin
          if a.anType in antSubqueryHeaders then
          begin
            result:=False; //can't move relations beneath this at the moment
            exit;
          end
          else
          begin
            result:=beforeSubqueryHeader(a.leftChild);
            if result then
              result:=beforeSubqueryHeader(a.rightChild);
          end;
        end;
      end; {beforeSubqueryHeader}

    {Start}
    begin
      result:=ok;

      if a=nil then exit;

      if (a.optimiserSuggestion=osUnprocessed) and (a.anType in antJoins)
         and (a.nodeRef<>nil) and (a.nodeRef.nType in [ntJoinOn,ntJoinUsing,ntNatural]) then
      begin //found a on/using/natural join that hasn't already been processed
        {We now need to add conditions that are implied by the join syntax
         (It's likely that these will actually be used for joining).
        }
        {For natural/using find any (specified) right-child columns matching a left-child/grandchildren column
        (Note: we expect to find a maximum of 1 match, but if there are more we insist they all match)}
        if (a.nodeRef.nType in [ntJoinOn,ntJoinUsing,ntNatural]) or (a.rightChild.anType in antRelations) then
        begin //we are On or have a right-child relation //todo what else? what if projection: should still handle...but need colCount & tuple refs beneath etc.
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('building (artificial) join-key expressions for join on/using/natural',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          tempJoinKeyNode:=nil;

          {Find the specified key column mappings}
          case a.nodeRef.nType of
            ntJoinOn:
            begin
              if a.anType in antOuterJoins then
              begin //we leave the condition within the join to ensure we can tell whether to add null row-halves or not
                //Note: iterJoin will interpret & use this
                {$IFDEF DEBUG_DETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('  On (outer): will use old-fashioned way',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                //todo: in future, use merge-join if the condition is all colA=colB AND... i.e. no ORs or >= or alien columns(?)
                //      especially (we must!) if this is a full outer join, since joinNL cannot handle this=error!
              end
              else
              begin //we can re-order the tables, so move the condition up to the select level
                //Note: we can do this because inner joins don't need to be treated as ntEqualOrNull & can be checked after join
                tempJoinKeyNode:=a.nodeRef; //point to On node (condition is leftChild)
                //Note: the risk is that these are not equality comparisons, so a cartesian will be realised first & then filtered: todo fix by using old-fashion test-during-join if that's the case!
                //Note: we don't need to qualify this condition, it's the user's job since this is shorthand for WHERE
                //Note: should we convert = to (=) i.e. mark any = nodes as 'system'? If so also review iterJoinNL logic...
              end;
            end; {ntJoinOn}
            ntJoinUsing:
            begin
              if not(beforeSubqueryHeader(a.leftChild) and beforeSubqueryHeader(a.rightChild)) then
              begin //subtle: prevent specific selects at a higher level when old-fashioned join will be used!
                {$IFDEF DEBUG_DETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('  Using: will use old-fashioned way',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
              end
              else
              begin //we can re-order the tables, so move the condition up to the select level
                nhead:=a.nodeRef.leftChild; //descend into ntJoinUsing -> column commalist
                n:=nhead;
                while n<>nil do
                begin
                  {Find in right subtree: not expecting any ambiguity}
                  rres:=0;
                  if CanSeeCol(a.rightChild,n,'',rres,rightcTuple,rightcRef,cId,cRange)<>ok then exit; //abort
                  if rres=0 then
                  begin
                    //shouldn't this have been caught before now!?
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown column reference (%s) in right of join',[n.idVal]),vError);
                    {$ENDIF}
                    st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
                    result:=Fail;
                    exit; //abort, no point continuing?
                  end;
                  //todo error if rres>1

                  {Find in left subtree}
                  lres:=0;
                  if CanSeeCol(a.leftChild,n,'',lres,leftcTuple,leftcRef,cId,cRange)<>ok then exit; //abort
                  if lres=0 then
                  begin
                    //shouldn't this have been caught before now!?
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown column reference (%s) in left of join',[n.idVal]),vError);
                    {$ENDIF}
                    st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
                    result:=Fail;
                    exit; //abort, no point continuing?
                  end;
                  //todo error if matches not marked as 'common' >1

                  {Add key pair(s)}
                  for i:=0 to rres-1 do
                  begin
                    for j:=0 to lres-1 do
                    begin
                      //todo only if cRange=''?
                      {Flag paired columns as 'merge and output in reverse originalOrder in projection before others'
                       Note: -ve means common column but not the preferred one, i.e. for left/right outer joins}
                      if (not a.LRswapped and (a.anType=antLeftJoin)) or (a.LRswapped and (a.anType=antRightJoin)) then
                        dec(leftcTuple[j].fColDef[leftcRef[j]].commonColumn) //don't use left common column for right-joins (note: inverted)
                      else
                        inc(leftcTuple[j].fColDef[leftcRef[j]].commonColumn);
                      if (not a.LRswapped and (a.anType=antRightJoin)) or (a.LRswapped and (a.anType=antLeftJoin)) then
                        dec(rightcTuple[i].fColDef[rightcRef[i]].commonColumn) //don't use right common column for left-joins (note: inverted)
                      else
                        inc(rightcTuple[i].fColDef[rightcRef[i]].commonColumn);

                      {$IFDEF DEBUG_DETAIL}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('  Using: adding artificial subtree for key-join pair %d (%s) and %d (%s) (range=%s)',[leftcRef[j],leftcTuple[j].fColDef[leftcRef[j]].name,rightcRef[i],rightcTuple[i].fColDef[rightcRef[i]].name,cRange[j]]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}

                      leftNode:=buildColumnReference(leftcTuple[j],leftcRef[j],cRange[j]);
                      rightNode:=buildColumnReference(rightcTuple[i],rightcRef[i],'');

                      {EqualOrNull - internal operator which assumes Unknown=True, e.g. for outer joins}
                      //todo do backwards to allow right-child optimisation code to pull:subNode:=mkNode(ntEqual,ctUnknown,tempNode1,tempNode2);
                      //     because inner right child expects: innercol=outerTable.outercol
                      subNode:=mkNode(st.srootAlloc,ntEqualOrNull,ctUnknown,rightNode,leftNode);
                      inc(debugSyntaxExtraCreate);
                      {$IFDEF DEBUG_DETAIL}
                      {$IFDEF DEBUG_LOG}
                      displaySyntaxTree(subNode);
                      {$ENDIF}
                      {$ENDIF}
                      chainNext(tempJoinKeyNode,subNode);
                    end;
                  end;

                  n:=n.nextNode;
                end; {while}
              end;
            end; {ntUsing}
            ntNatural:
            begin
              if not(beforeSubqueryHeader(a.leftChild) and beforeSubqueryHeader(a.rightChild)) then
              begin //subtle: prevent specific selects at a higher level when old-fashioned join will be used!
                {$IFDEF DEBUG_DETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('  Natural: will use old-fashioned way',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
              end
              else
              begin
                //todo need algebra.countCol & algebra.nextCol routines to make more generic e.g. NJ(UNION(A,B),UNION(A,C))
                rightcRef[0]:=0;
                while rightcRef[0]<a.rightChild.rel.fTuple.ColCount do
                begin
                  {Find if this right column exists in left subtree}
                  lres:=0;
                  if CanSeeCol(a.leftChild,nil,a.rightChild.rel.fTuple.fColDef[rightcRef[0]].name,lres,leftcTuple,leftcRef,cId,cRange)<>ok then exit; //abort
                  if lres>0 then
                  begin
                    {Add key pair(s)}
                    for j:=0 to lres-1 do
                    begin
                      //todo only if cRange=''?
                      {Flag paired columns as 'merge and output in reverse originalOrder in projection before others'
                       Note: -ve means common column but not the preferred one, i.e. for left/right outer joins}
                      if (not a.LRswapped and (a.anType=antLeftJoin)) or (a.LRswapped and (a.anType=antRightJoin)) then
                        dec(leftcTuple[j].fColDef[leftcRef[j]].commonColumn) //don't use left common column for right-joins (note: inverted)
                      else
                        inc(leftcTuple[j].fColDef[leftcRef[j]].commonColumn);
                      if (not a.LRswapped and (a.anType=antRightJoin)) or (a.LRswapped and (a.anType=antLeftJoin)) then
                        dec(a.rightChild.rel.fTuple.fColDef[rightcRef[0]].commonColumn) //don't use right common column for left-joins (note: inverted)
                      else
                        inc(a.rightChild.rel.fTuple.fColDef[rightcRef[0]].commonColumn);

                      {$IFDEF DEBUG_DETAIL}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('  Natural: adding artificial subtree for key-join pair %d (%s) and %d (%s) (range=%s)',[leftcRef[j],leftcTuple[j].fColDef[leftcRef[j]].name,rightcRef[0],a.rightChild.rel.fTuple.fColDef[rightcRef[0]].name,cRange[j]]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}

                      leftNode:=buildColumnReference(leftcTuple[j],leftcRef[j],cRange[j]);
                      rightNode:=buildColumnReference(a.rightChild.rel.fTuple,rightcRef[0],'');

                      {EqualOrNull - internal operator which assumes Unknown=True, e.g. for outer joins}
                      //todo do backwards to allow right-child optimisation code to pull:subNode:=mkNode(ntEqual,ctUnknown,tempNode1,tempNode2);
                      //     because inner right child expects: innercol=outerTable.outercol
                      subNode:=mkNode(st.srootAlloc,ntEqualOrNull,ctUnknown,rightNode,leftNode);
                      inc(debugSyntaxExtraCreate);
                      {$IFDEF DEBUG_DETAIL}
                      {$IFDEF DEBUG_LOG}
                      displaySyntaxTree(subNode);
                      {$ENDIF}
                      {$ENDIF}

                      chainNext(tempJoinKeyNode,subNode);
                    end;
                  end;
                  //todo error if matches not marked as 'common' >1

                  inc(rightcRef[0]);
                end; {while}
              end;
            end; {ntNatural}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('ntJoin modifier option not handled (%d), continuing...',[ord(a.nodeRef.nType)]),vDebugError);
            {$ENDIF}
          end; {case}

          {Now attach the new syntax node(s) to the existing WHERE clause tree to hand over memory management responsibility}
          if tempJoinKeyNode<>nil then
          begin
            //todo (if not On) mark node as a candidate for merge-join execution, i.e. equi-join
            if (a.nodeRef.nType<>ntJoinOn) and (a.anType in [(*antInnerJoin{todo remove:give more thought!},*) antLeftJoin,antRightJoin,antFullJoin,antUnionJoin]) then
              a.optimiserSuggestion:=osMergeJoin;
            //todo: for full-join with join-on, we should: (L innerjoin R) union ((L - R)||nulls) union (nulls|(R - L))

            if selectionsCount=0 then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Missing selection node',[nil]),vAssertion);
              {$ENDIF}
              exit; //todo assertion!
            end;
            if a.nodeRef.nType=ntJoinOn then
              chainNext(selections[0].nodeRef,tempJoinKeyNode.leftChild) //skip On node
            else
              chainNext(selections[0].nodeRef,tempJoinKeyNode);

            {Since the finalisation stage of the chosen plan will pull down all equality conditions,
             not just these system-specified ones, to the join node they apply to as key-column pairs,
             we must mark the node itself as system-replaced: i.e. don't re-process within the join iterator in an
             old-fashioned way, otherwise do. (old-fashioned processing leaves tempJoinKeyNode=nil)
            }
            a.nodeRef.systemNode:=True;
          end
          else
          begin
            //e.g. could be ntJoinOn & outer join -> leave as-is i.e. old-fashioned join
            //     or using/natural that could not be moved because of subqueries beneath
            //...so this join node won't be flagged as 'system-replaced'
            //else may not have had any columns in common
          end;
        end
        else //right child is not a relation so for now we don't //todo make sure then that this join's children remain!
        begin
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('right-child of join natural/using is not a relation: cannot process',[nil]),vDebugMedium);
          {$ENDIF}
          {$ENDIF}
          //todo abort
        end;

        if a.optimiserSuggestion=osUnprocessed then a.optimiserSuggestion:=osProcessed; //flag as processed in case we see this again, e.g. commutative tree with non-commutative level above a commutative sub-tree
      end;
      //else todo: log devWarning if candidate but processed already - i.e. repetetive plan/subplan

      {We can continue left even if we are not a commutative join node}
      if not(a.anType in antSubqueryHeaders) then
        if a.leftChild<>nil then
        begin
          result:=addSelectionsForJoins(a.leftChild);  //recurse
          if result<>ok then exit; //abort
        end;

      {We can look right even if we are not a commutative join node
       i.e. (since no bushy joins) we probably only look one level right, i.e. simple relation joins}
      if not(a.anType in antSubqueryHeaders) then
        if a.rightChild<>nil then
        begin
          result:=addSelectionsForJoins(a.rightChild); //recurse
          if result<>ok then exit; //abort
        end;
    end; {addSelectionsForJoins}

    function findBestRel(r:integer;var currentCost:integer):integer;
    {IN     : r           - rels subscript of the relation to join to
     OUT    : currentCost - adjusted plan cost after the join
     RETURNS: rels subscript, else -1=fail

     Note: if rels[r].parentNode=non-optimisable then existing right-child is returned

     Reads rels[] but left to caller to update
     Does update rels[].joinCols
          and rels[r].parentNode.keyColMap/keyColMapCount
     }
    var
      i,j,k,bestRel,si,bestCost:integer;
      n:TSyntaxNodePtr;
      cost:integer;
      lcid,rcid:TColId;
      lcref,rcref:ColRef;
      constraintPtr:TConstraintListPtr;
      foundCount:integer;
      found:boolean;
    begin
      result:=-1; //fail

      //todo: if only one available: pick it now: speed

      bestRel:=-1;
      bestCost:=maxint;

      if rels[r].parentNode.anType in antCommutativeJoins then
      begin //chance to re-arrange
        for i:=0 to relsCount-1 do
        begin //try each available rels
          if rels[i].state=0 then
          begin //available
            {Reset outer relation's key join columns-used}
            rels[r].joinColsCount:=0;

            {Reset potential relation's key join columns-used}
            rels[i].joinColsCount:=0;

            {Look for any selections that apply to our two relations}
            for si:=0 to selectionsCount-1 do
            begin
              n:=selections[si].nodeRef;
              while n<>nil do
              begin
                if n.nType in [ntEqual,ntEqualOrNull] then
                  if justReferencesChildren(n,rels[r].anode,rels[i].anode,lcid,rcid,lcref,rcref) then
                  begin
                    {$IFDEF DEBUG_DETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('  %d->%d found equi-join selection node: %s (lcid=%d, rcid=%d)',[r,i,infixSyntax(n),lcid,rcid]),vDebugMedium);
                    {$ENDIF}
                    {$ENDIF}
                    {Keep track of which columns/keys we are using
                     we can beat other DBs by noting PK/FK relationships here}
                    //todo check array range!
                    inc(rels[r].joinColsCount);
                    rels[r].joinCols[rels[r].joinColsCount]:=lcid;

                    inc(rels[i].joinColsCount);
                    rels[i].joinCols[rels[i].joinColsCount]:=rcid;
                  end;

                //todo even if justReferencesChildren (with any operator)
                // this should enable us to reduce the cost estimate by something?

                n:=n.nextNode;
              end;

            end;

            {Calculate the worst cost of joining to r}
            cost:=(currentCost*(rels[i].estimatedSize+1{todo match avoid 0 below})); //i.e. cost of cartesian join for now

            {Now check whether we have any useful join keys to reduce the cost}
            {$IFDEF DEBUG_DETAIL}
            {$IFDEF DEBUG_LOG}
            for j:=1 to rels[r].joinColsCount do
              log.add(st.who,where+routine,format('  outer col used: %d',[rels[r].joinCols[j]]),vDebugMedium);
            for j:=1 to rels[i].joinColsCount do
              log.add(st.who,where+routine,format('  inner col used: %d',[rels[i].joinCols[j]]),vDebugMedium);
            {$ENDIF}
            {$ENDIF}

            {Before checking constraints, rough guess at a reduced cost if we have common column(s)}
            //todo: refine!
            if rels[r].joinColsCount>0 then
              cost:=trunc(currentCost*((rels[i].estimatedSize/4)+1{avoid 0})); //i.e. cost of cartesian join with a quarter of the rows for now

            if rels[r].anode.rel=nil then
              constraintPtr:=nil //i.e. antSyntaxRelation
            else
              constraintPtr:=rels[r].anode.rel.constraintList;
            while constraintPtr<>nil do
            begin
              if constraintPtr.constraintId<>0 then
              begin //complete
                //todo check constraintType?

                if rels[i].anode.rel<>nil then
                begin
                  {Foreign Key from outer relation to our relation, i.e. guaranteed single match}
                  if constraintPtr.parentTableId=rels[i].anode.rel.tableId then
                  begin //this is an FK from our outer table... check the columns match
                    foundCount:=0;
                    for k:=1 to constraintPtr.childColsCount do
                    begin
                      {Find outer FK column in the used list}
                      found:=false;
                      for j:=1 to rels[r].joinColsCount do
                        if constraintPtr.childCols[k]=rels[r].joinCols[j] then
                        begin
                          found:=true;
                          break;
                        end;
                      if found then inc(foundCount) else break;
                    end;
                    if foundCount=constraintPtr.childColsCount then
                    begin
                      foundCount:=0;
                      for k:=1 to constraintPtr.parentColsCount do
                      begin
                        {Find our FK column in the used list}
                        found:=false;
                        for j:=1 to rels[i].joinColsCount do
                          if constraintPtr.parentCols[k]=rels[i].joinCols[j] then
                          begin
                            found:=true;
                            break;
                          end;
                        if found then inc(foundCount) else break;
                      end;
                      if foundCount=constraintPtr.parentColsCount then
                      begin //matched!
                        {$IFDEF DEBUG_DETAIL}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('    matches C->P FK constraint %d',[constraintPtr.constraintId]),vDebugMedium);
                        {$ENDIF}
                        {$ENDIF}

                        {This guarantees that a maximum of 1 row will match each row in the outer relation}
                        cost:=currentCost; //todo: add something for our relation lookups?
                                           //todo: need 2 figures: size of result: currentCost
                                           //                      cost          : currentCost+accessMethod, e.g. nestedLoop+index=O(outersize), noIndex=O(outersize*inner)
                      end;
                      //else parent portion did not fully match
                    end;
                    //else child portion did not fully match
                  end;
                end;
                //else our relation is syntax only so cannot have FK constraints

                {todo:
                   if primaryKey/unique & justReferencesChildren recognised col=const then
                   we can determine cases returning max 1 row etc.

                   maybe also we can use parent-end FKs plus index stats to
                   guess at valency of joins the other way

                   etc.
                }
              end;

              constraintPtr:=constraintPtr.next;
            end;

            //todo also worth checking against index columns...
            // even though we can infer indexes from constraints the reverse is not true
            // but what does it tell us? The directory depth would tell us if it was a total waste or else useful?

            if cost<bestCost then
            begin //new winner
              bestRel:=i;
              bestCost:=cost; //(returned direct)
            end;
          end;
        end;
      end
      else //we have no room to rearrange the join order in this case, so return the existing right child
      begin
        for i:=0 to relsCount-1 do
        begin //find the only available rel
          if rels[i].state=0 then
          begin //available
            if rels[r].parentNode=rels[i].parentNode then
            begin
              {Reset outer relation's key join columns-used}

              //use existing child //todo assert bestRel=-1, else more than one!!!
              bestRel:=i;
              bestCost:=1; //todo ok?
            end;
          end;
        end;
      end;

      {Return the winner}
      {$IFDEF DEBUG_DETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('  running cost=%d',[CurrentCost]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      result:=bestRel;
      currentCost:=bestCost;
    end; {findBestRel}


begin
  result:=ok;

  if aroot.optimiserSuggestion=osProcessed then
  begin
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('%p is already optimised - skipping...',[aroot]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;

  {Since there seem to be some complex situations which crash the optimiser logic,
   we protect the caller from these & leave the plan unoptimised in the event of any problem...}
  try
    //atree:=aRoot;
    //todo ifdef safety
    //prevent nasty errors
    for i:=0 to MAX_SELECTIONS do selections[i]:=nil;

    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Optimising sub-tree of joins at %p',[aRoot]),vDebugMedium);
    {$ENDIF}
    //todo: assert atree.anType=join

    //todo! for runtime safety: wrap all this in a try.except and continue gracefully if we get an error
    //      need a try finally in case re-pointing fails halfway...

    //todo convert join Using/Natural/On into expressions now & add to local/nearest/new WHERE clause above this subtree
    //(but don't pass subtree boundaries, e.g. Union)

    //todo add extra transitive constraints: e.g. A=B B=C => A=C: this might make all the difference!

    //todo push-down all sargs?

    //todo do this before findRels?
    {Find the WHERE clause (if any) that our joins are defined in
     Note: we use an array to ease future growth}
    selectionsCount:=0;
    findSelections(aRoot);
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    for i:=0 to selectionsCount-1 do
      log.add(st.who,where+routine,format('selections[%d]=%p',[i,selections[i]]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}

    {If no selection exists, insert one now (even though we may not need it, e.g. nested-loop joins can keep criteria within}
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.quick('Before insertSelection');
    DisplayAlgebraTree(aroot); //before
    {$ENDIF}
    {$ENDIF}
    if selectionsCount=0 then insertSelection(sRoot,aRoot); //this could change the root
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.quick('After insertSelection');
    DisplayAlgebraTree(aroot); //before
    {$ENDIF}
    {$ENDIF}


    {Find all the relations in this subtree that we are going to plan for}
    relsCount:=0;
    findRels(aRoot);

    relsOrderCount:=0;
    findRelsOriginalOrder(aRoot);

    //todo move ifdef debug_logs to one outer one here
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Found %d relations beneath %p',[relsCount,aRoot]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    for i:=0 to relsCount-1 do
    begin
      if rels[i].anode.rel=nil then //i.e. antSyntaxRelation
      begin
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('rels[%d](original order=%d)=%s (%d) (size=%d) (parent=%p)',[i,rels[i].anode.originalOrder,'[syntax]',-1,rels[i].estimatedSize,rels[i].parentNode]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        constraintPtr:=nil;
      end
      else
      begin
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('rels[%d](original order=%d)=%s (%d) (size=%d) (parent=%p)',[i,rels[i].anode.originalOrder,rels[i].anode.rel.relname,rels[i].anode.rel.tableId,rels[i].estimatedSize,rels[i].parentNode]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        constraintPtr:=rels[i].anode.rel.constraintList;
      end;
      while constraintPtr<>nil do
      begin
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        if constraintPtr.constraintId<>0 then
          log.add(st.who,where+routine,format('  constraint %d: type=%d parentTable=%d childCols=%d parentCols=%d',[constraintPtr.constraintId,ord(constraintPtr.constraintType),constraintPtr.parentTableId,constraintPtr.childColsCount,constraintPtr.parentColsCount]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        constraintPtr:=constraintPtr.next;
      end;
    end;


    {Add WHERE conditions implied by the on/using/natural join syntax within this subtree (& any non-traversed sub-subtrees)
     Note: this may set optimiserSuggestion to mergeJoin (need to ignore if section below aborts...)}
    if addSelectionsForJoins(aRoot)<>ok then exit; //abort

    if relsCount<=1 then
    begin //no need to continue!
      exit;
    end;

    {If any of our rels are natural/using then we must ensure we have a projection node
     which can handle the results}
    needProjection:=False;
    for i:=0 to relsCount-1 do
    begin
      if (rels[i].parentNode.anType in antJoins) and (rels[i].parentNode.nodeRef<>nil) and (rels[i].parentNode.nodeRef.nType in [ntJoinUsing,ntNatural]) then
      begin
        needProjection:=True;
        break; //done
      end;
    end;

    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.quick('Before insertProjection');
    DisplayAlgebraTree(aroot); //before
    {$ENDIF}
    {$ENDIF}
    if needProjection then insertProjection(aRoot); //this could change the root
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.quick('After insertProjection');
    DisplayAlgebraTree(aroot); //before
    {$ENDIF}
    {$ENDIF}

    //todo if total costs are small (i.e. cartesian join: worst case) then no point wasting time planning! exit!
    // e.g. 10 tables with a few rows each


    {Enumerate plans greedily: starting with each of the relations in turn}
    //todo track how much time we spend & implement a cut-off if necessary, e.g. 16 table => 256 combinations = ok?
    for plansCount:=0 to relsCount-1{i.e. square, i.e. O(n2)} do
    begin
      {Make all rels available for use}
      for i:=0 to relsCount-1 do
        rels[i].state:=0;

      planStep:=0;

      {Start with specified first relation}
      plans[plansCount].plan[planStep]:=plansCount;
      rels[plansCount].state:=rels[plansCount].estimatedSize; //i.e. cost of full scan

      {Start accumulating the plan cost}
      plans[plansCount].cost:=rels[plansCount].state;

      {Now complete this plan}
      while planStep<relsCount-1 do
      begin
        inc(planStep);

        best:=findBestRel(plans[plansCount].plan[planStep-1],plans[plansCount].cost);
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.quick(format('  picked next best relation=%d',[best]));
        {$ENDIF}
        {$ENDIF}
        if best=-1 then
        begin
          {This could be because our chosen relations span across non-joins, e.g. projections
           so there's no way we can find even the original right-child since there isn't one
           that has the same parent as us. todo: perhaps we can notice this earlier...
          }
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('plans[%d] failed finding next best join %d, abandoning this subtree optimisation...',[plansCount,planStep]),vDebugMedium);
          {$ENDIF}
          result:=fail; //todo too strong?
          exit; //abort
        end;

        {Add next best relation}
        plans[plansCount].plan[planStep]:=best;
        rels[best].state:=plans[plansCount].cost; //i.e. non-zero

      end;

      for i:=0 to relsCount-1 do
      begin
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('  plans[%d].plan[%d]=%d',[plansCount,i,plans[plansCount].plan[i]]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
      end;
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('plans[%d].cost=%d',[plansCount,plans[plansCount].cost]),vDebugMedium);
      {$ENDIF}

    end; {plansCount}

    {Now pick the plan with the lowest cost
     Note: we search forward so that we pick the one nearest the user-order from any that are equal}
    best:=-1;
    bestCost:=maxint;
    for plansCount:=0 to relsCount-1 do
      if plans[plansCount].cost<bestCost then
      begin
        best:=plansCount;
        bestCost:=plans[best{=plansCount}].cost;
      end;

    if best=-1 then //todo remove: speed
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Failed picking best plan',vAssertion);
      {$ENDIF}
      result:=fail;
      exit; //abort
    end;
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Chosen plan %d with cost=%d',[best,bestCost]),vDebugMedium);
    {$ENDIF}
  except
    on E:Exception do
    begin
      result:=fail;

      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Exception: %s',[E.message]),vAssertion); //todo user caused?
      {$ENDIF}
      //return to the caller: i.e. carry on unoptimised at least
      exit; //abort
    end;
  end; {try}

  try
    {Ok, implement the chosen plan by repointing the leaves' parents}
    //todo if plan = original order, no need to repoint: speed (note: plan 0 is not necessarily the original order!)
    for i:=0 to relsCount-1 do
    begin
      {$IFDEF DEBUG_DETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('  repointing %p(left:%d) from %p to %p',[rels[i].parentNode,ord(rels[i].parentFromLeft),rels[i].aNode,rels[plans[best].plan[i]].anode]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}


      rels[i].aNode.parent:=nil; //break old c->p: orphaned one way
      if rels[i].parentFromLeft then
      begin
        //todo assert parent.leftChild=rels[i].aNode
        rels[i].parentNode.leftChild:=rels[plans[best].plan[i]].anode; //p->c
        //todo remember original position for projection ordering: plans[best].plan[i]
      end
      else
      begin
        //todo assert parent.rightChild=rels[i].aNode
        rels[i].parentNode.rightChild:=rels[plans[best].plan[i]].anode; //p->c
        //todo remember original position for projection ordering: plans[best].plan[i]
      end;
      rels[plans[best].plan[i]].anode.parent:=rels[i].parentNode; //new c->p

    end;
    {We should now have no orphans}

    //todo now reset the equi-join keys as we found them in findBestRel
    {We must finalise the existing plan, even if we can't optimise the join order,
     so that we set the equi-join keys for merge-joins for example (needed for outer joins)
     todo: also in this section, we should/could pull down the applicable conditions to where they belong etc.!
           i.e. create antSelect nodes and then disable the local/specific/unmaintainable iter-level optimisations
           (but this does not necesssarily only apply to pairs of relations in our chosen plan)
    }
    //code copied from findBestRel... todo use common find equi-selections routine?
    {Note: we compare i with i+1 for i=0 to N-1
           and we add any common-columns to the parent of node i+1 to allow join-node processing to use them
           todo: ensure any common columns between others are also moved down to their lowest place
    }
    for i:=0 to relsCount-2 do
    begin
      begin
        begin
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          //log.add(st.who,where+routine,format('  %d: %d->%d (%p->%p)',[i,plans[best].plan[i],plans[best].plan[i+1],rels[plans[best].plan[i]].anode,rels[plans[best].plan[i+1]].anode]),vDebugMedium);
          {$ENDIF}
          {$ENDIF}

          //note A,B will call reset/compare twice! todo: avoid: speed
          //     also avoid (speed) if this node will not use them, e.g. old-fashioned using/on 
          rels[plans[best].plan[i+1]].parentNode.keyColMapCount:=0;
          {Look for any selections that apply to our two relations}
          for si:=0 to selectionsCount-1 do
          begin
            n:=selections[si].nodeRef;
            while n<>nil do
            begin
              if n.nType in [ntEqual,ntEqualOrNull] then
                if justReferencesChildren(n,rels[plans[best].plan[i]].anode,rels[plans[best].plan[i+1]].anode,lcid,rcid,lcref,rcref) then
                begin
                  {$IFDEF DEBUG_DETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('  %d->%d using equi-join selection node will be added to %p: %s (lcid=%d, rcid=%d)',[plans[best].plan[i],plans[best].plan[i+1],rels[plans[best].plan[i+1]].parentNode,infixSyntax(n),lcid,rcid]),vDebugMedium);
                  {$ENDIF}
                  {$ENDIF}

                  {Also track the equi-join columns in the outer relation's parent join node
                   for possible merge-join execution in case this relation is chosen}
                  //todo assert/check rels[i].parentNode=(merge?)join
                  if rels[plans[best].plan[i+1]].parentNode.keyColMapCount>=MaxKeyColMap-1 then
                  begin
                    //shouldn't this have been caught before now!?
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Too many join columns %d',[rels[plans[best].plan[i+1]].parentNode.keyColMapCount]),vError);
                    {$ENDIF}
                    result:=Fail;
                    exit; //abort, no point continuing?
                  end;
                  inc(rels[plans[best].plan[i+1]].parentNode.keyColMapCount);
                  rels[plans[best].plan[i+1]].parentNode.keyColMap[rels[plans[best].plan[i+1]].parentNode.keyColMapCount-1].left:=lcRef;
                  rels[plans[best].plan[i+1]].parentNode.keyColMap[rels[plans[best].plan[i+1]].parentNode.keyColMapCount-1].right:=rcRef;
                end;
              n:=n.nextNode;
            end;
          end; {si}
        end;
      end; {j}
    end; {i}

    if aRoot.optimiserSuggestion=osUnprocessed then aRoot.optimiserSuggestion:=osProcessed; //flag as processed to prevent call to optimise this tree again

    result:=ok;
  except
    on E:Exception do
    begin
      result:=Fail;
      //todo!
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Exception: %s',[E.message]),vAssertion); //todo user caused?
      {$ENDIF}

      {Repoint everything to its original state so we can continue even if the repointing should fail
       Not expected to happen, but just in case!}
      for i:=0 to relsCount-1 do
      begin
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        //log.add(st.who,where+routine,format('  recovery repointing %p to %p',[rels[i].parentNode,rels[i].anode]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}

        //todo! We need to know whether the parent orginally pointed left or right...
        // -    can't we just fix the last one that must have failed: i.e. no duplicate/twisted pointer, just bad order
        //      Also reset optimiserSuggestion (else mergeJoin? = wrong)
      end;
    end;
  end; {try}
end; {OptimiseJoins}

function OptimiseFindJoins(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr):integer;
{Find the start of each join sequence/subtree to pass to optimiseJoins routine

 Note:
   May add a selection root if none exists, but will leave aRoot as the pointer
   by sneakily copying the old root to a new sub-node and overwriting the original
   root node with any new selection node.
}
const
  routine=':optimiseFindJoins';
var
  atree:TAlgebraNodePtr;
begin
  result:=ok;

  atree:=aRoot;

  while (atree<>nil) do
  begin
    //todo remove debug
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    //log.quick(format('aroot=%p (%d)',[atree,ord(atree.anType)]));
    {$ENDIF}
    {$ENDIF}

    if atree.anType in antJoins then //i.e. if non-commutative, still need to add implicit WHERE clauses & will return immediately
    begin //found start of a subtree
      if optimiseJoins(st,sroot,atree)<>ok then
      begin
        result:=fail;
        exit; //abort
      end;

      {Skip optimised joins and move down left to next possible subtree}
      //todo: note: this skip needs to be the same as the one use to group joins in optimiseJoins!
      while (atree<>nil) and (atree.anType in antJoins) do
      begin
        if atree.rightChild<>nil{no need} then
          if optimiseFindJoins(st,sroot,atree.rightChild)<>ok then //recurse: we might have sub-joins in the distance if not simple Relation joins
          begin
            result:=fail;
            exit; //abort
          end;
        atree:=atree.leftChild;
      end;
    end;

    if atree.rightChild<>nil then
      if OptimiseFindJoins(st,sroot,atree.rightChild)<>ok then //recurse
      begin
        result:=fail;
        exit; //abort
      end;

    atree:=atree.leftChild;
  end;
end; {OptimiseFindJoins}

function Optimise(St:TStmt;sRoot:TSyntaxNodePtr;aRoot:TAlgebraNodePtr):integer;
{Optimise the relational algebra tree

 IN           :
                st        the statement
                sRoot     the tree/subtree syntax root used to hang any new nodes from (to ensure garbage collection)
                aRoot     algebra tree/subtree root

 Optimisation Notes
   Need to move any antSelection sub-branches that are join selections into the
   appropriate join's 'on' node (this is more efficient)
   e.g.  antSelection (X.a=Y.b & X.c>50)
         antJoin (X,Y)
   becomes
         antSelection (X.c>50)
         antJoin (X,Y) + ON(X.a=Y.b)    i.e. internal selection

   May add a selection root if none exists, but will leave aRoot as the pointer
   by sneakily copying the old root to a new sub-node and overwriting the original
   root node with any new selection node.
}
const
  routine=':optimise';
begin
  result:=ok;

  {Swap any bushy right children}
  ensureLeftDeepOnly(st,aRoot);

  result:=OptimiseFindJoins(st,sRoot,aRoot); //could change aRoot
end; {Optimise}

end.

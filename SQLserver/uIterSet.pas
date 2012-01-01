unit uIterSet;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3}
{$DEFINE DEBUGDETAIL4}


{Set operations
 Supports: stUnion, stExcept, stIntersect, stUnionAll, stExceptAll, stIntersectAll
 Notes:
   requires pre-sorted inputs (preferably physically sorted, but indexed access will do)
   (must be pre-sorted on same corresponding key(s) in same direction)

   if sorted inputs have no duplicates then this behaves as if ALL was not specified
   (i.e. ALL behavioural differences are mostly governed by the children)
}

interface

uses uIterator, uTransaction, uStmt, uAlgebra, uGlobal {for settype},
     uSyntax, uTuple;

const
  MaxKeyColMap=MaxCol;    //maximum number of sort columns

type
  TKeyColMap=record           //todo: move to common join/set unit
    left:colRef;
    right:colRef;
  end; {TKeyColMap}
  //note: index colMap subscripts start at 1

  TIterSet=class(TIterator)
    private
      setType:TsetType;
      leftNoMore, rightNoMore:boolean;

      keyColMap:array [0..MaxKeyColMap] of TKeyColMap; //todo: replace array with linked list!
      keyColMapCount:integer;

      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started

      function CompareTupleKeys(tl,tr:TTuple;var res:integer):integer;
    public
      function description:string; override;
      function status:string; override;

      constructor create(S:Tstmt;itemExprRef:TAlgebraNodePtr;setFlag:TsetType);

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterSet}


implementation

uses uLog, sysUtils, uMarshalGlobal, uIterSort{for pushing down corresponding columns};

const
  where='uIterSet';

constructor TIterSet.create(S:Tstmt;itemExprRef:TAlgebraNodePtr;setFlag:TsetType);
begin
  inherited create(s);
  aNodeRef:=itemExprRef;
  setType:=setFlag;
  completedTrees:=False;
end; {create}

function TIterSet.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  result:=result+' ('+setTypeToStr(setType)+')';
end; {description}

function TIterSet.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterSet '+leftChild.anodeRef.rangeName+' ('+setTypeToStr(setType)+') '+rightChild.anodeRef.rangeName;
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterSet.prePlan(outerRef:TIterator):integer;
{PrePlans the set process
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
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down left-side of tree, i.e. left=outer join
    correlated:=correlated OR leftChild.correlated;
  end;
  if result<>ok then exit; //aborted by child
  if assigned(rightChild) then
  begin
    result:=rightChild.prePlan(outer); //sub-recurse down right-side of tree (bushy)
    correlated:=correlated OR rightChild.correlated;
  end;
  if result<>ok then exit; //aborted by child

  {Setup the comparison key columns}
  keyColMapCount:=0;
  if anodeRef.nodeRef<>nil then
  begin
    case anodeRef.nodeRef.nType of
      ntCorrespondingBy: //todo: is this still needed? we pass the column list during iterSort creation...
      begin //Note: following copied from ntJoinUsing
        {Find the specified key column mappings}
        cRange:=''; //always must be simple column refs
        nhead:=anodeRef.nodeRef.leftChild; //descend into ntCorrespondingBy -> column commalist
        n:=nhead;
        while n<>nil do
        begin
          {Find in left tuple}
          result:=leftChild.iTuple.FindCol(nil,n.idval,cRange,nil,cTuple,leftcRef,cid);
          if cid=InvalidColId then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column reference (%s) in left of set operation',[n.idVal]),vError);
            {$ENDIF}
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
            result:=Fail;
            exit; //abort, no point continuing?
          end;

          {Also find in right tuple}
          result:=rightChild.iTuple.FindCol(nil,n.idval,cRange,nil,cTuple,rightcRef,cid);
          if cid=InvalidColId then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column reference (%s) in right of set operation',[n.idVal]),vError);
            {$ENDIF}
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
            result:=Fail;
            exit; //abort, no point continuing?
          end;

          {Add key pair}
          if keyColMapCount>=MaxKeyColMap-1 then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Too many corresponding columns %d',[keyColMapCount]),vError);
            {$ENDIF}
            result:=Fail;
            exit; //abort, no point continuing?
          end;
          inc(keyColMapCount);
          keyColMap[keyColMapCount-1].left:=leftcRef;
          keyColMap[keyColMapCount-1].right:=rightcRef;
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('added corresponding pair %d (%s) and %d (%s)',[leftcRef,leftChild.iTuple.fColDef[leftcRef].name,rightcRef,rightChild.iTuple.fColDef[rightcRef].name]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          n:=n.nextNode;
        end; {while}
      end; {ntCorrespondingBy}
      ntCorresponding:
      begin //Note: following copied from ntNatural
        {Find the matching 'natural' key column mappings}
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Natural corresponding...',[nil]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        cRange:=''; //always must be simple column refs
        leftcRef:=0;
        while leftcRef<leftChild.iTuple.ColCount do
        begin
          {Find this left column in right tuple}
          result:=rightChild.iTuple.FindCol(nil,leftChild.iTuple.fColDef[leftcRef].name,cRange,nil,cTuple,rightcRef,cid);
          if cid<>InvalidColId then
          begin //found match
            {Add key pair}
            if keyColMapCount>=MaxKeyColMap-1 then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Too many corresponding columns %d',[keyColMapCount]),vError);
              {$ENDIF}
              result:=Fail;
              exit; //abort, no point continuing?
            end;
            inc(keyColMapCount);
            keyColMap[keyColMapCount-1].left:=leftcRef;
            keyColMap[keyColMapCount-1].right:=rightcRef;
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('added corresponding pair %d (%s) and %d (%s)',[leftcRef,leftChild.iTuple.fColDef[leftcRef].name,rightcRef,rightChild.iTuple.fColDef[rightcRef].name]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;

          inc(leftcRef);
        end; {while}
      end; {ntCorresponding}
    else
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('iterSet modifier option not handled (%d), continuing...',[ord(anodeRef.nodeRef.nType)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
    end; {case}
  end
  else //default = all columns by ordinal position
  begin
    if leftChild.iTuple.colCount<>rightChild.iTuple.colCount then
    begin
      //shouldn't this have been caught before now!?
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('The two operands are of different degrees',[nil]),vError);
      {$ENDIF}
      stmt.addError(seSyntaxNotDegreeCompatible,seSyntaxNotDegreeCompatibleText);
      result:=Fail;
      exit; //abort, no point continuing?
    end;
    leftcRef:=0;
    while leftcRef<leftChild.iTuple.ColCount do
    begin
      rightcRef:=leftcRef;

      inc(keyColMapCount);
      keyColMap[keyColMapCount-1].left:=leftcRef;
      keyColMap[keyColMapCount-1].right:=rightcRef;
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('added corresponding pair %d (%s) and %d (%s)',[leftcRef,leftChild.iTuple.fColDef[leftcRef].name,rightcRef,rightChild.iTuple.fColDef[rightcRef].name]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      inc(leftcRef);
    end; {while}
  end;

  {Check the resulting operands are compatible and valid}
  if keyColMapCount=0 then
  begin
    //shouldn't this have been caught before now!?
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('The two operands have no corresponding columns',[nil]),vError);
    {$ENDIF}
    stmt.addError(seSyntaxDegreeIsZero,seSyntaxDegreeIsZeroText);
    result:=Fail;
    exit; //abort, no point continuing?
  end;
  for j:=1 to keyColMapCount do
  begin
    {Currently, we only allow column pairs having the same underlying storage type
     Note: this may be too restrained/or too lax - see A Guide to SQL (4th ed) section 7.6
     re type compatibility}
    {TODO: use a common isCompatible routine - also used in FK definition}
    if DataTypeDef[leftChild.iTuple.fColDef[keyColMap[j-1].left].datatype]<>DataTypeDef[rightChild.iTuple.fColDef[keyColMap[j-1].right].datatype] then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format(seSyntaxColumnTypesMustMatchText,[leftChild.iTuple.fColDef[keyColMap[j-1].left].name,rightChild.iTuple.fColDef[keyColMap[j-1].right].name]),vError);
      {$ENDIF}
      stmt.addError(seSyntaxColumnTypesMustMatch,format(seSyntaxColumnTypesMustMatchText,[leftChild.iTuple.fColDef[keyColMap[j-1].left].name,rightChild.iTuple.fColDef[keyColMap[j-1].right].name]));
      result:=Fail;
      exit; //abort, no point continuing
    end;
  end;

  {Now we can pass the corresponding columns down to override the two sort children keys}
  //actually no need if no 'corresponding' clause was specified: speed
  //Note: the children have already been set to remove duplicates or not
  if assigned(leftChild) and (leftChild is TiterSort) then
  begin
    (leftChild as TiterSort).keyColCount:=keyColMapCount;
    for j:=1 to keyColMapCount do
    begin
      (leftChild as TiterSort).keyCol[j-1].col:=keyColMap[j-1].left;
      (leftChild as TiterSort).keyCol[j-1].direction:=sdASC; //any would do
    end;
  end;
  if assigned(rightChild) and (rightChild is TiterSort) then
  begin
    (rightChild as TiterSort).keyColCount:=keyColMapCount;
    for j:=1 to keyColMapCount do
    begin
      (rightChild as TiterSort).keyCol[j-1].col:=keyColMap[j-1].right;
      (rightChild as TiterSort).keyCol[j-1].direction:=sdASC; //any would do
    end;
  end;


  {Ok, set tuple size}
  iTuple.ColCount:=keyColMapCount;

  {Now set the output column definitions}
  for j:=1 to keyColMapCount do
    iTuple.CopyColDef(j-1,leftChild.iTuple,keyColMap[j-1].left);

  {If necessary, we now reset the tuple's sourceRange alias if this node has been given an explicit alias}
  if anodeRef.rangeName<>'' then
  begin
    {Now we can set the column sourceRange's
     These are needed in case this is a subselect with an AS, e.g. in From clause
     Note: they wouldn't be needed if we could guarantee that the rows projected were being
     materialised into a relation: since we are using on-the-fly pipelining, we can't.
     }
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('aliased set to %s',[anodeRef.rangeName]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    for i:=0 to iTuple.ColCount-1 do
      iTuple.fColDef[i].sourceRange:=anodeRef;
  end;

  //todo test this doesn't break group-by/having with us over-using the same syntax noderef
  if anodeRef.exprNodeRef<>nil then
  begin
    {We have a list of column aliases (that were set at the table_ref level) so apply them now
     Note: these may well override any previous column names/aliases}
    nhead:=anodeRef.exprNodeRef;
    for i:=0 to iTuple.ColCount-1 do
    begin
      if nhead<>nil then
      begin
        iTuple.fColDef[i].name:=nhead.idVal; //column alias
        nhead:=nhead.nextNode;
      end
      else
      begin
        //shouldn't this have been caught before now!?
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Not enough column aliases (at %d out of %d)',[i+1,iTuple.ColCount]),vError);
        {$ENDIF}
        //todo for now we leave the original column names - i.e. half aliased/half original = bad! todo FIX! by failing!- check what happens to caller...
        //todo? result:=Fail;
        //      exit; //abort, no point continuing?
      end;
    end;
  end;



  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugMedium); //debug
  {$ENDIF}
  {$ENDIF}
end; {prePlan}

function TIterSet.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

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

  if assigned(rightChild) then
  begin
    result:=rightChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('linking to new rightChild: %s',[newChildParent.Status]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    rightChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterSet.start:integer;
{Start the set process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.start;   //recurse down tree
  if result<>ok then exit; //aborted by child
  if assigned(rightChild) then result:=rightChild.start; //sub-recurse down right-side of tree (bushy)
  if result<>ok then exit; //aborted by child

  {Read initial tuples from the children}
  result:=leftChild.next(leftNoMore);
  if result<>ok then exit; //aborted by child
  result:=rightChild.next(rightNoMore);
  if result<>ok then exit; //aborted by child
end; {start}

function TIterSet.stop:integer;
{Stop the set process
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
  //todo ok/better to continue anyway...?  if result<>ok then exit; //aborted by child
  if assigned(rightChild) then result:=rightChild.stop; //recurse down right-side of tree
end; {stop}

function TIterSet.next(var noMore:boolean):integer;
{Get the next tuple from the set process
 RETURNS:  ok, else fail

 Note: the noMore result should be kept static by the caller
       as this routine (I suspect:confirmed bug fix 15/06/99) assumes this
       Does this requirement apply to other Iters?
}
//todo add comment about using eval routine to select
const routine=':next';
var
  res:TriLogic;
  keyresComp:integer;
  i:ColRef;
begin
//  inherited next;
  result:=ok;
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  {Calculate loop termination}
  res:=isUnknown;
  case setType of
    stIntersect,stIntersectAll: noMore:=leftNoMore or rightNoMore;
    stUnion,stUnionAll:         noMore:=leftNoMore and rightNoMore;
    stExcept,stExceptAll:       noMore:=leftNoMore;
  end; {case}
  while not noMore and (res<>isTrue) do
  begin
    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    if not leftNoMore then log.add(stmt.who,where+routine,format('left :%s',[leftChild.iTuple.show(stmt)]),vDebugLow);
    if not rightNoMore then log.add(stmt.who,where+routine,format('right:%s',[rightChild.iTuple.show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {Compare the tuples: if we don't have two tuples left, set an artificial result to simplify the algorithms}
    if leftNoMore then
    begin
      case setType of
        stUnion,stUnionAll:     keyresComp:=+1; //i.e. l>r => output r
      end; {case}
    end
    else
      if rightNoMore then
      begin
        case setType of
          stUnion,stUnionAll:      keyresComp:=-1; //i.e. l<r => output l
          stExcept,stExceptAll:    keyresComp:=-1; //i.e. l<r => output l
        end; {case}
      end
      else //we do have two tuples, so compare them
      begin
        result:=CompareTupleKeys(leftChild.iTuple,rightChild.iTuple,keyresComp);
        if result<>ok then exit; //abort
      end;

    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('compare result=%d',[keyresComp]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {Now decide what to return & how to traverse the relations}
    {Note: the current output area for this non-materialised set is a
    single record buffer (i.e. as if a single version exists)

    We need to do a deep copy because we move ready for the next iteration
    -todo: improve & allow shallow copy by moving to next at start (i.e. after used)
    }
    //speed: applies to all below: no need to check assigned(leftChild) - safety only
    if keyresComp<0 then //l<r
    begin
      case setType of
        stUnion,stExcept,
        stUnionAll,stExceptAll:
        begin
          {Return L}
          iTuple.clear(stmt); //speed - fastClear?
          for i:=1 to keyColMapCount do
            iTuple.CopyColDataDeep{Ptr}(i-1,stmt,leftChild.iTuple,keyColMap[i-1].left,false);
          res:=isTrue;
        end;
      end; {case}
      {Next L}
      if assigned(leftChild) then result:=leftChild.next(leftNoMore);
      if result<>ok then exit; //abort
    end;

    if keyresComp>0 then //l>r
    begin
      case setType of
        stUnion,
        stUnionAll:
        begin
          {Return R}
          iTuple.clear(stmt); //speed - fastClear?
          for i:=1 to keyColMapCount do
            iTuple.CopyColDataDeep{Ptr}(i-1,stmt,rightChild.iTuple,keyColMap[i-1].right,false);
          res:=isTrue;
        end;
      end; {case}
      {Next R}
      if assigned(rightChild) then result:=rightChild.next(rightNoMore);
      if result<>ok then exit; //abort
    end;

    if keyresComp=0 then //l=r
    begin
      case setType of
        stIntersect,stUnion,
        stIntersectAll,stUnionAll:
        begin
          {Return L}
          iTuple.clear(stmt); //speed - fastClear?
          for i:=1 to keyColMapCount do
            iTuple.CopyColDataDeep{Ptr}(i-1,stmt,leftChild.iTuple,keyColMap[i-1].left,false);
          res:=isTrue;
        end;
      end; {case}
      {Next L}
      if assigned(leftChild) then result:=leftChild.next(leftNoMore);
      if result<>ok then exit; //abort
      {Next R}
      case setType of
        stUnion,
        {Note: NOT stUnionAll} //todo is this the *only* ALL behaviour in this iterator? (better than sorting result!)
        stIntersect,stExcept,
        stIntersectAll,stExceptAll:
        begin
          if assigned(rightChild) then result:=rightChild.next(rightNoMore);
          if result<>ok then exit; //abort
        end;
      end; {case}
    end;

    {Re-calculate loop termination} //speed: no need if res=isTrue
    case setType of
      stIntersect,stIntersectAll: noMore:=leftNoMore or rightNoMore;
      stUnion,stUnionAll:         noMore:=leftNoMore and rightNoMore;
      stExcept,stExceptAll:       noMore:=leftNoMore;
    end; {case}
  end; {while}

  {If this is the last result, force caller to use it
  & so return to get noMore again (from before while loop)
  todo improve this logic & use repeat..until?}
  if res=isTrue then noMore:=False;

  if not noMore then //=>res=isTrue
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;
end; {next}

//combine this with two routines from IterSort - or use the ones from EvalCondExpr
function TIterSet.CompareTupleKeys(tl,tr:TTuple;var res:integer):integer;
{Compare 2 tuple keys l , r

 OUT:      RES        0    l=r
                      -ve  l<r
                      +ve  l>r

 Assumes:
 keyColMap array has been defined
 both tuples have same column definitions for those that are being compared

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'
}
const routine=':compareTupleKeys';
var
  cl:colRef;
  resComp:shortint;
  resNull:boolean;
  {$IFDEF DEBUGDETAIL3}
  i,i2:integer;
  iv_null,iv_null2:boolean;
  {$ENDIF}
begin
  result:=ok;
  res:=0;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<keyColMapCount) do
  begin
    result:=tl.CompareCol(stmt,keyColMap[cl].left,keyColMap[cl].right,tr,resComp,resNull);
    {$IFDEF DEBUGDETAIL3}
    tl.GetInteger(keyColMap[cl].left,i,iv_null);
    tr.GetInteger(keyColMap[cl].right,i2,iv_null2);
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('comparing (%d)%d and (%d)%d, result=%d',[keyColMap[cl].left,i,keyColMap[cl].right,i2,resComp]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(keyColMap[cl].left,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(keyColMap[cl].right,resNull);
        if result<>ok then exit; //abort
        if resNull then
          resComp:=0   //both are null so treat as equal (SQL anomaly!)
        else
          resComp:=NullSortOthers;
      end
      else
        resComp:=-NullSortOthers;
    end;
    inc(cl);
  end;
  res:=resComp;
end; {CompareTupleKeys}


end.

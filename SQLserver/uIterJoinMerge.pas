unit uIterJoinMerge;

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


{Merge join
 Supports: jtInner, jtLeft, jtRight, ,jtFull, //todo! jtUnion

 Notes:
   requires pre-sorted inputs (preferably physically sorted, but in future 2ndary indexed access might do)
   (must be pre-sorted on same join key(s) in same direction)
   must be at least one equi-join (currently only tested for equi-join, but might be adaptable)
   outer/left child must support getPosition/findPosition, i.e. bookmarking & random access
   inner/right child is scanned once with no re-positioning needed

   currently: keys are passed to children during prePlan etc., so it's assumed children are TIterSort
}

interface

uses uIterator, uIterJoin, uTransaction, uStmt, uAlgebra, uGlobal {for jointype},
     uTuple {for MaxCol}, uSyntax;

type
  TIterJoinMerge=class(TIterJoin)
    private
      leftNoMore, rightNoMore:boolean;
      doingRightOuter, doingLeftOuter:boolean; //track state while merging: right=return to caller & keep same place; left=nullify right tuples when processing results block
      lastKey:TTuple;   //buffer to store last key comparison for left readTuple
      lastBMpos, leftBMtop, leftBMbottom:cardinal; //store current left-block (cursor) pos; just-before left-block start; just-after left-block end
    public
      function status:string; override;

      constructor create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType); override;
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterJoinMerge}

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uEvalCondExpr, uIterRelation {for equi-join filter test/assertion}, uMarshalGlobal,
     uIterSort{for child assertion};

const
  where='uIterJoin(Merge)';

constructor TIterJoinMerge.create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType);
begin
  inherited create(S,condExprRef,joinFlag);
  lastKey:=TTuple.Create(nil);
end; {create}

destructor TIterJoinMerge.destroy;
const routine=':destroy';
begin
  lastKey.free;
  inherited destroy;
end; {destroy}

function TIterJoinMerge.status:string;
var s:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterJoinMerge '+'('+joinTypeToStr(joinType)+')'+' (LRswapped='+intToStr(ord(anodeRef.LRswapped))+')';
  //todo fix: result:='TIterJoinMerge '+inherited.status;
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterJoinMerge.prePlan(outerRef:TIterator):integer;
{PrePlans the join process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  j:colRef;
begin
  {L join R already builds as RxJ (unless it's LRswapped) and so we need to reverse our interpretation
   so that we can subsequently treat them as we'd expect}
  //Note: done before inherited prePlan since it will reset LRswapped to True
  if not anodeRef.LRswapped then
    if joinType=jtLeft then
      joinType:=jtRight
    else
      if joinType=jtRight then
        joinType:=jtLeft;

  result:=inherited prePlan(outerRef);

  {Assert that this joinType is handled
   Note: we do this after we've called the inherited prePlan to make sure we have all the details
  }
  if not(joinType in [jtInner, jtLeft, jtRight, jtFull {todo! ,jtUnion}]) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('This sort type does not support the %s join type',[joinTypeToStr(joinType)]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;

  {Assert that the children have been sorted and that the left/outer one can be bookmared
   Note: we do this after we've called the inherited prePlan to make sure we have all the details
  }
  if not((leftChild is TiterSort) and (rightChild is TiterSort){todo relax to just rightChild.isSorted}) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('This sort type does not support the %s join type',[joinTypeToStr(joinType)]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;

  {$IFDEF DEBUGSUMMARY}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo: maybe pull down 'if joinExpr' to this class?
  //      at least pull down those that are applicable equi-joins into key-array!

  lastKey.CopyTupleDef(leftChild.iTuple);


  //todo remove: to allow natural join even if no columns in common: i.e. cartesian merge
  {Assert we have some equi-join column(s)}
  if anodeRef.keyColMapCount=0 then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('This sort type needs an equi-join',[nil]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;
  //todo end remove

  {Now we can pass the corresponding columns down to override the two sort children keys}
  if assigned(leftChild) and (leftChild is TiterSort) then
  begin
    (leftChild as TiterSort).keyColCount:=anodeRef.keyColMapCount;
    for j:=1 to anodeRef.keyColMapCount do
    begin
      (leftChild as TiterSort).keyCol[j-1].col:=anodeRef.keyColMap[j-1].left;
      (leftChild as TiterSort).keyCol[j-1].direction:=sdASC; //because we use LT
    end;
  end;
  if assigned(rightChild) and (rightChild is TiterSort) then
  begin
    (rightChild as TiterSort).keyColCount:=anodeRef.keyColMapCount;
    for j:=1 to anodeRef.keyColMapCount do
    begin
      (rightChild as TiterSort).keyCol[j-1].col:=anodeRef.keyColMap[j-1].right;
      (rightChild as TiterSort).keyCol[j-1].direction:=sdASC; //because we use LT
    end;
  end;
end; {prePlan}

function TIterJoinMerge.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail

 Note:
  unlike the nested-loop join, we don't need to create artificial syntax nodes for the
  implicit equi-joins, since passing them down to the children won't be useful for index looping
}
const routine=':optimise';
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}

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
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    rightChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterJoinMerge.start:integer;
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

  leftNoMore:=False;
  rightNoMore:=False;
  doingRightOuter:=False;
  doingLeftOuter:=False;

  {Left/outer cursor - used to drive the matching}
  lastKey.clear(stmt);
  lastBMpos:=0;
  leftBMtop:=0;
  leftBMbottom:=0;

  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('L:%s',[leftChild.iTuple.ShowHeading]),vDebugLow);
  log.add(stmt.who,where+routine,format('R:%s',[rightChild.iTuple.ShowHeading]),vDebugLow);
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {start}

function TIterJoinMerge.stop:integer;
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

function TIterJoinMerge.next(var noMore:boolean):integer;
{Get the next tuple from the join process
 RETURNS:  ok, else fail

 Note: the noMore result should be kept static by the caller
       as this routine (I suspect:confirmed bug fix 15/06/99) assumes this *todo avoid this requirement?
       Does this requirement apply to other Iters?
}
const routine=':next';
var
  res:TriLogic;
  keyres:boolean;
  i:ColRef;
  done:boolean;
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

  res:=isUnknown;

  if leftBMbottom=0 then
  begin //initial read
    result:=leftChild.next(leftNoMore);
    if result<>ok then exit; //aborted by child
    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('L1:%s',[leftChild.iTuple.show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    result:=rightChild.next(rightNoMore);
    if result<>ok then exit; //aborted by child
    {$IFDEF DEBUGDETAIL4}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('R1:%s',[rightChild.iTuple.show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  if not doingRightOuter then //(ensure we do return if we said we would)
    if leftNoMore and rightNoMore then
      noMore:=True;

  while not(noMore) and (res<>isTrue) do
  begin
    if (leftBMbottom=leftBMtop) or doingRightOuter then
    begin  //find next left block & then the next right-tuple that matches/> (this section does not return any tuples, except right-outer if required)
      if not doingRightOuter then //(we're not returning from a right-outer result)
      begin
        leftBMtop:=lastBMpos; //treat the current left tuple as the 1st in the new block, i.e. top=previous saved position
        lastKey.clear(stmt);
        for i:=1 to leftChild.iTuple.ColCount do
          lastKey.copyColDataDeep(i-1,stmt,leftChild.iTuple,i-1,false);   //deep needed //todo: just copy key columns! speed!
        lastBMpos:=(leftChild as TIterSort).GetPosition; //we always save the latest position before we read-ahead
        {Read all left tuples that match the current one until we read one-too-many}
        result:=leftChild.next(leftNoMore);
        if result<>ok then exit; //aborted by child
        {$IFDEF DEBUGDETAIL4}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('L2:%s',[leftChild.iTuple.show(stmt)]),vDebugLow); //read-ahead next in new left block
        {$ENDIF}
        {$ENDIF}
        done:=False;
        while not(done) and not(leftNoMore) do
        begin
          result:=CompareLeftTupleKeysEQ(leftChild.iTuple,lastKey,keyres);
          if result<>ok then exit;  //abort
          if keyres then
          begin
            lastBMpos:=(leftChild as TIterSort).GetPosition;
            result:=leftChild.next(leftNoMore);
            {$IFDEF DEBUGDETAIL4}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('L3:%s',[leftChild.iTuple.show(stmt)]),vDebugLow); //read-ahead next in this left block
            {$ENDIF}
            {$ENDIF}
            if result<>ok then exit; //aborted by child
          end
          else
            done:=True;
        end;

        leftBMbottom:=lastBMpos; //mark bottom of block (i.e. don't include the extra mismatch we just read)

        {Move to first right tuple that matches this left group}
        result:=CompareTupleKeysGT(lastKey,rightChild.iTuple,keyres); //=right<lastKey: LT needed left,right parameter order to be fixed for keyColumn array assumption!
        if result<>ok then exit;  //abort
      //start of jump-back code
      end
      else
        keyres:=doingRightOuter; //this will allow us to jump back to where we left off: assume joinType=same!
      //end of jump-back code
      while not(rightNoMore) and keyres do
      begin
        if (joinType in [jtRight,jtFull]) and not doingRightOuter then
        begin //Note: right-outer rows are processed one at a time
          {We return a null,right tuple & exit the loop: ensuring we return here next call
            todo: needs testing in case L.eof already & we jump out & back & get rejected - can't happen here?}
          iTuple.clearToNulls(stmt);
          {Return null+right
           Note: we must deep copy because we move the current record afterwards ready for the next iteration}
          iTuple.clear(stmt); //todo fastClear? maybe faster to clearToNulls & then populate the half we need to?: speed
          for i:=1 to leftMapCount do
          begin
            if not anodeRef.LRswapped then
              iTuple.copyColDataDeep(i-1,stmt,rightChild.iTuple,leftMap[i-1],false)  //after optimiser switch
            else
              iTuple.setNull(i-1);
          end;
          for i:=1 to rightMapCount do
          begin
            if not anodeRef.LRswapped then
              iTuple.setNull(leftMapCount+(i-1)) //after optimiser switch
            else
              iTuple.copyColDataDeep(leftMapCount+(i-1),stmt,rightChild.iTuple,rightMap[i-1],false);
          end;
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('O2:%s',[iTuple.show(stmt)]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          res:=isTrue; //return to caller
          doingRightOuter:=True; //ensure we return here
          break; //will exit this local while loop & then continue to drop out of the outer loop/routine
        end
        else
        begin
          if doingRightOuter then doingRightOuter:=False; //ok, we've returned: continue where we left off

          result:=rightChild.next(rightNoMore);
          if result<>ok then exit; //aborted by child
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('R2:%s',[rightChild.iTuple.show(stmt)]),vDebugLow); //skip non-matching right row
          {$ENDIF}
          {$ENDIF}

          result:=CompareTupleKeysGT(lastKey,rightChild.iTuple,keyres); //=right<lastKey: LT needed left,right parameter order to be fixed for keyColumn array assumption!
          if result<>ok then exit;  //abort
        end;
      end;
      if doingRightOuter then continue; //will break out of the outer loop since res=isTrue

      {Determine the next step according to whether we have a matching right tuple or not
       (if we don't, then the right tuple must now be >lastkey or rightNoMore)}
      result:=CompareTupleKeysEQ(lastKey,rightChild.iTuple,keyres);
      if result<>ok then exit;  //abort
      if not(rightNoMore) and keyres then
        (leftChild as TIterSort).FindPosition(leftBMtop) //(re-)start this left block to match return results for this right tuple
      else
      begin //no passes of this left-block needed (unless we're left-outer), we have no matching right tuple
        if joinType in [jtLeft,jtFull] then
        begin //Note: left-outer rows are processed as a block
          {We simulate a right-match here so that the left block is processed almost as normal}
          doingLeftOuter:=True;
          (leftChild as TIterSort).FindPosition(leftBMtop); //(re-)start this left block to match return results for this null right tuple
        end
        else
        begin
          {Note: we've just read ahead the 1st tuple of the next block (if any more existed)}
          leftBMtop:=leftBMbottom{=lastBMpos}; //zeroise block size so next iteration will reset it
          if leftNoMore then noMore:=True; //we read ahead nothing - terminate this loop
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('L6:%s',[leftChild.iTuple.show(stmt)]),vDebugLow); //start next left block: no right matches
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    end;

    {Calculate our next result tuple, if any}
    if (leftChild as TIterSort).GetPosition<leftBMbottom then
    begin //we are part-way through our left-block result building stage & we know we have at least 1 right match (or doingLeftOuter=>null right)
      {(RE!)Read the next block tuple} //todo check how these are cached (explicitly bring into our cache?) -speed!
      result:=leftChild.next(leftNoMore); //todo: assert leftNoMore=False here!
      if result<>ok then exit; //aborted by child
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('L4:%s',[leftChild.iTuple.show(stmt)]),vDebugLow); //matching left row
      {$ENDIF}
      {$ENDIF}

      {Return left+right (possibly using nulls for right if doingLeftOuter)
       Note: we must deep copy because we move the current record afterwards ready for the next iteration}
      iTuple.clear(stmt); //todo fastClear?
      for i:=1 to leftMapCount do
      begin
        if not anodeRef.LRswapped then
          if doingLeftOuter then iTuple.setNull(i-1) else iTuple.copyColDataDeep(i-1,stmt,rightChild.iTuple,leftMap[i-1],false)  //after optimiser switch
        else
          iTuple.copyColDataDeep(i-1,stmt,leftChild.iTuple,leftMap[i-1],false);
      end;
      for i:=1 to rightMapCount do
      begin
        if not anodeRef.LRswapped then
          iTuple.copyColDataDeep(leftMapCount+(i-1),stmt,leftChild.iTuple,rightMap[i-1],false) //after optimiser switch
        else
          if doingLeftOuter then iTuple.setNull(leftMapCount+(i-1)) else iTuple.copyColDataDeep(leftMapCount+(i-1),stmt,rightChild.iTuple,rightMap[i-1],false);
      end;
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('O1:%s',[iTuple.show(stmt)]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      res:=isTrue; //return to caller

      {Prepare for next iteration}
      if (leftChild as TIterSort).GetPosition>=leftBMbottom then    //note: should just check =, but > used for safety
      begin //finished this pass of the left-block
        if doingLeftOuter then
        begin
          doingLeftOuter:=False; //finished left-outer processing for this block
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('R4:%s',[rightChild.iTuple.show(stmt)]),vDebugLow); //last possible right to match current left block
          {$ENDIF}
          {$ENDIF}
        end
        else
        begin
          result:=rightChild.next(rightNoMore); //Note: if rightNoMore=true will be caught by next call
          if result<>ok then exit; //aborted by child
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('R3:%s',[rightChild.iTuple.show(stmt)]),vDebugLow); //next possible right to match current left block
          {$ENDIF}
          {$ENDIF}
        end;

        result:=CompareTupleKeysEQ(lastKey,rightChild.iTuple,keyres);
        if result<>ok then exit;  //abort

        if rightNoMore or not(keyres) then
        begin //no more passes of left-block needed, we have a different right tuple
          leftBMtop:=leftBMbottom; //zeroise block size so next iteration will reset it
          lastBMpos:=(leftChild as TIterSort).GetPosition; //ready for new leftBMtop
          result:=leftChild.next(leftNoMore); //Note: if leftNoMore=true will be caught by next call
          if result<>ok then exit; //aborted by child
          {$IFDEF DEBUGDETAIL4}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('L5:%s',[leftChild.iTuple.show(stmt)]),vDebugLow); //start next left block: right matches have ended
          {$ENDIF}
          {$ENDIF}
        end
        else
          (leftChild as TIterSort).FindPosition(leftBMtop) //re-start this left block to match return results for this right tuple
      end;

    end
    else
    begin
      {No passes of this left-block were needed, we had no matching right tuple (the next right tuple is > or noMore)
       (and we aren't left-outer building)
       - loop again to read the next left block (if there is one, otherwise noMore will have been set & we'll drop out)}

      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%d>=%d so end of this left block',[(leftChild as TIterSort).GetPosition,leftBMbottom ]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      //fix: 13/05/03: was looping forever if 1 row left outer (where doingLeftOuter set true above, noMore wouldn't be set)
      if doingLeftOuter=True then
        if leftNoMore then noMore:=True; //we read ahead nothing - terminate this loop
    end;

    //check we never lose the last result...
    //if leftNoMore and rightNoMore then
    //  if res<>isTrue then noMore:=True {else not just yet!}; //end outer loop
  end; {while}
end; {next}


end.

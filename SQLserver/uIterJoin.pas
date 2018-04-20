unit uIterJoin;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3} //compare detail: warning assumes integer keys!
//{$DEFINE DEBUGDETAIL4}

//{$DEFINE OLD_EARLY_SELECTION} //i.e. project now - optimiser not allowed freedom to re-arrange!

{Abstract join, e.g. iterJoinMerge, iterJoinNestedLoop

   i and j are colRef (0..) so the array loops go from 1 to count and then we use loopvar-1 as the subscripts
   - else range error
}

interface

uses uIterator, uTransaction, uStmt, uAlgebra, uGlobal {for jointype, MaxCol},
     uTuple, uSyntax;

const
  MaxMap=MaxCol;          //maximum number of left/right column output mappings

type
  TIterJoin=class(TIterator)
    public
      joinType:TjoinType;
      joinExpr:boolean;                        //do we filter the joins before returning? if True, anodeRef.leftChild->condition
      joinKey:boolean;                         //do we perform key-equi-join on left & right tuples?

      leftMapCount, rightMapCount:integer;
      leftMap,rightMap:array [0..MaxMap] of colRef;

      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started

      function CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
      function CompareTupleKeysGT(tl,tr:TTuple;var res:boolean):integer;
      function CompareLeftTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;

      function description:string; override;
      function status:string; override;

      constructor create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType); virtual;
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop - actually abstract here

      function JustReferencesChildren(snode:TSyntaxNodePtr):integer;
  end; {TIterJoin}

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uEvalCondExpr, uIterRelation {for equi-join filter test/assertion}, uMarshalGlobal;

const
  where='uIterJoin';

constructor TIterJoin.create(S:TStmt;condExprRef:TAlgebraNodePtr;joinFlag:TjoinType);
begin
  inherited create(s);
  aNodeRef:=condExprRef;
  joinType:=joinFlag;
  completedTrees:=False;
end; {create}

destructor TIterJoin.destroy;
const routine=':destroy';
begin
  inherited destroy;
end; {destroy}

function TIterJoin.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  result:=result+' ('+joinTypeToStr(joinType)+')';
end; {description}

function TIterJoin.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=leftChild.anodeRef.rangeName+' ('+joinTypeToStr(joinType)+') '+rightChild.anodeRef.rangeName+' (LRswapped='+intToStr(ord(anodeRef.LRswapped))+')';
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterJoin.prePlan(outerRef:TIterator):integer;
{PrePlans the join process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  i,j:colRef;
  nhead,n,oldn:TSyntaxNodePtr;
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
  {$ENDIF}
  {$ENDIF}

  //{$IFNDEF OLD_EARLY_SELECTION}
    anodeRef.LRswapped:=True; //left & right are always as they seem
                              {
                                       since the optimiser ensures left-deep only trees, the code:
                                         if not anodeRef.LRswapped then
                                           X
                                         else
                                           Y
                                        can be made simpler, i.e. Y

                                todo: leave for now to keep code stable (tried to remove & wasn't smooth)
                               }
  //{$ENDIF}


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

  {to be able to handle right outer joins:
    swap outer & inner children so our main loop driver is inner tuple
    but retain order of tuple appending so original outer results are first
  }

  {Set the default output mapping
   - this is what we use if the optimiser has dealt with our natural/using
     since the relations may have been re-ordered: the projection is done at a higher level
  }
  //todo: remove: we overwrite it later anyway... & doesn't take account of R-L swap...
  leftMapCount:=leftChild.iTuple.colCount;
  rightMapCount:=rightChild.iTuple.colCount;
  for j:=1 to leftMapCount do
    leftMap[j-1]:=j-1;
  {Adding right columns}
  for j:=1 to rightMapCount do
    rightMap[j-1]:=j-1;

  //todo most of this is no longer active: done by optimiser and smart/late natural projections
  {Setup the join key and conditions}  //Note: common routine - combine
  joinKey:=False;  //only set by late logic if optimiser can't handle yet: we assume children remain static in these cases
  joinExpr:=False; //set by joinOn or by late logic if optimiser can't handle yet
  if anodeRef.nodeRef<>nil then
  begin
    case anodeRef.nodeRef.nType of
      ntJoinOn:
      begin
        if not anodeRef.nodeRef.systemNode then
        begin //not handled by optimiser yet so use old late join logic
          joinExpr:=True;
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('joining ON...%p',[anodeRef.nodeRef.leftChild]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('using system-replaced key-join (hopefully-if not, a higher filter) for optimised join on',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
   //{$IFDEF OLD_EARLY_SELECTION} //optimiser handles all this now: else can no longer be sure to find the columns in the children after optimiser
      ntJoinUsing:
      begin
        if not anodeRef.nodeRef.systemNode then
        begin //not handled by optimiser yet so use old late join logic
          anodeRef.keyColMapCount:=0;
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('using old-fashioned key-join for non-optimised join using',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          {Find the specified key column mappings}
          cRange:=''; //always must be simple column refs
          nhead:=anodeRef.nodeRef.leftChild; //descend into ntJoinUsing -> column commalist
          n:=nhead;
          while n<>nil do
          begin
            {Find in left tuple}
            result:=leftChild.iTuple.FindCol(nil,n.idval,cRange,nil{debug=limit match!},cTuple,leftcRef,cid);
            if cid=InvalidColId then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Unknown column reference (%s) in left of join',[n.idVal]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
              result:=Fail;
              exit; //abort, no point continuing?
            end;

            {Also find in right tuple}
            result:=rightChild.iTuple.FindCol(nil,n.idval,cRange{remove},nil,{debug=limit match!}cTuple,rightcRef,cid);
            if cid=InvalidColId then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Unknown column reference (%s) in right of join',[n.idVal]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idVal]));
              result:=Fail;
              exit; //abort, no point continuing?
            end;

            {Add key pair}
            if anodeRef.keyColMapCount>=MaxKeyColMap-1 then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Too many join columns %d',[anodeRef.keyColMapCount]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit; //abort, no point continuing?
            end;
            inc(anodeRef.keyColMapCount);
            anodeRef.keyColMap[anodeRef.keyColMapCount-1].left:=leftcRef;
            anodeRef.keyColMap[anodeRef.keyColMapCount-1].right:=rightcRef;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('added key-join pair %d (%s) and %d (%s)',[leftcRef,leftChild.iTuple.fColDef[leftcRef].name,rightcRef,rightChild.iTuple.fColDef[rightcRef].name]),vDebugLow);
            {$ENDIF}
            {$ENDIF}

            n:=n.nextNode;
          end; {while}
          joinKey:=True;
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('using system-replaced key-join for optimised join using',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end; {ntJoinUsing}
      ntNatural:
      begin
        if not anodeRef.nodeRef.systemNode then
        begin //not handled by optimiser yet so use old late join logic
          anodeRef.keyColMapCount:=0;
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('using old-fashioned key-join for non-optimised natural join',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          {Find the matching 'natural' key column mappings}
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Natural join...',[nil]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
          cRange:=''; //always must be simple column refs
          leftcRef:=0;
          while leftcRef<leftChild.iTuple.ColCount do
          begin
            {Find this left column in right tuple}
            result:=rightChild.iTuple.FindCol(nil,leftChild.iTuple.fColDef[leftcRef].name,cRange,nil{debug limit match!},cTuple,rightcRef,cid);
            if cid<>InvalidColId then
            begin //found match
              {Add key pair}
              if anodeRef.keyColMapCount>=MaxKeyColMap-1 then
              begin
                //shouldn't this have been caught before now!?
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Too many join columns %d',[anodeRef.keyColMapCount]),vError);
                {$ELSE}
                ;
                {$ENDIF}
                result:=Fail;
                exit; //abort, no point continuing?
              end;
              inc(anodeRef.keyColMapCount);
              anodeRef.keyColMap[anodeRef.keyColMapCount-1].left:=leftcRef;
              anodeRef.keyColMap[anodeRef.keyColMapCount-1].right:=rightcRef;
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('added key-join pair %d (%s) and %d (%s)',[leftcRef,leftChild.iTuple.fColDef[leftcRef].name,rightcRef,rightChild.iTuple.fColDef[rightcRef].name]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
            end;

            inc(leftcRef);
          end; {while}
          joinKey:=True;
        end
        else
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('using system-replaced key-join for optimised natural join',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end; {ntNatural}
    else
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('ntJoin modifier option not handled (%d), continuing...',[ord(anodeRef.nodeRef.nType)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
   //{$ENDIF}
    end; {case}
  end;

 //{$IFDEF OLD_EARLY_SELECTION}
  if joinKey then //old fashioned natural/using
  begin
    //todo log the fact that we're using an internal selection
    // - such a join type has a special name/symbol?

    {Now set the input->output mappings}
    leftMapCount:=0;
    {Add the duplicate columns first}
    for j:=1 to anodeRef.keyColMapCount do
    begin
      //todo fix outer join bug: should pick from left or right depending on type of join... full=runtime coalesce
      inc(leftMapCount);
      if not anodeRef.LRswapped then
        leftMap[leftMapCount-1]:=anodeRef.keyColMap[j-1].right //after optimiser switch
      else
        leftMap[leftMapCount-1]:=anodeRef.keyColMap[j-1].left;

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('  removed old-fashioned key-join column (chosen %d)',[leftMap[leftMapCount-1]]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;
    {Add the rest of the left tuple columns}
    if not anodeRef.LRswapped then
      sourceCount:=rightChild.iTuple.ColCount //after optimiser switch
    else
      sourceCount:=leftChild.iTuple.ColCount;
    for j:=1 to sourceCount do
    begin
      i:=0;  //todo speed search
      while (i<anodeRef.keyColMapCount) do
      begin
        if not anodeRef.LRswapped then
        begin //after optimiser switch
          if anodeRef.keyColMap[i].right=j-1 then
            break  //duplicate already added
          else
            inc(i);
        end
        else
        begin
          if anodeRef.keyColMap[i].left=j-1 then
            break  //duplicate already added
          else
            inc(i);
        end;
      end;
      if i>=anodeRef.keyColMapCount then
      begin
        inc(leftMapCount);
        leftMap[leftMapCount-1]:=j-1;
      end;
    end;
    {Add the rest of the right tuple columns}
    if not anodeRef.LRswapped then
      sourceCount:=leftChild.iTuple.ColCount //after optimiser switch
    else
      sourceCount:=rightChild.iTuple.ColCount;
    rightMapCount:=0;
    for j:=1 to sourceCount do
    begin
      i:=0; //todo speed search
      while (i<anodeRef.keyColMapCount) do
      begin
        if not anodeRef.LRswapped then
        begin //after optimiser switch
          if anodeRef.keyColMap[i].left=j-1 then
            break  //duplicate already added
          else
            inc(i);
        end
        else
        begin
          if anodeRef.keyColMap[i].right=j-1 then
            break  //duplicate already added
          else
            inc(i);
        end;
      end;
      if i>=anodeRef.keyColMapCount then
      begin
        inc(rightMapCount);
        rightMap[rightMapCount-1]:=j-1;
      end;
    end;
  end;
 //{$ENDIF}

  {Ok, set tuple size}
  iTuple.ColCount:=leftMapCount+rightMapCount;

  {Now set the output column definitions}
  //todo: no need for this now moved to project level?: remove mapping arrays...
  {Note: duplicates will take the left-child's source details...}
  {Adding left columns}
  for j:=1 to leftMapCount do
    if not anodeRef.LRswapped then
      iTuple.CopyColDef(j-1,rightChild.iTuple,leftMap[j-1]) //after optimiser switch
    else
      iTuple.CopyColDef(j-1,leftChild.iTuple,leftMap[j-1]);
  {Adding right columns}
  for j:=1 to rightMapCount do
    if not anodeRef.LRswapped then
      iTuple.CopyColDef(leftMapCount+(j-1),leftChild.iTuple,rightMap[j-1]) //after optimiser switch
    else
      iTuple.CopyColDef(leftMapCount+(j-1),rightChild.iTuple,rightMap[j-1]);

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
    log.add(stmt.who,where+routine,format('aliased join to %s',[anodeRef.rangeName]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    for i:=0 to iTuple.ColCount-1 do
      iTuple.fColDef[i].sourceRange:=anodeRef;
  end;

  if anodeRef.exprNodeRef<>nil then
  begin
    {We have a list of column aliases (that were set at the table_ref level) so apply them now
     Note: these may well override any previous column names/aliases}
    nhead:=anodeRef.exprNodeRef;
    for i:=1 to iTuple.ColCount do
    begin
      if nhead<>nil then
      begin
        iTuple.fColDef[i-1].name:=nhead.idVal; //column alias
        nhead:=nhead.nextNode;
      end
      else
      begin
        //shouldn't this have been caught before now!?
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Not enough column aliases (at %d out of %d)',[i,iTuple.ColCount]),vError);
        {$ENDIF}
        stmt.addError(seSyntaxNotEnoughViewColumns,format(seSyntaxNotEnoughViewColumnsText,[nil]));
        result:=Fail;
        exit; //abort, no point continuing?
      end;
    end;
  end;

  //does this always apply at this level?
  if joinExpr then
  begin
    {Now complete the join-condition tree}
    if not completedTrees then
    begin
      completedTrees:=True; //ensure we only complete the sub-trees once
      result:=CompleteCondExpr(stmt,self,anodeRef.nodeRef.leftChild,agNone);
      if result<>ok then exit; //aborted by child
    end;
  end;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,ituple.ShowHeading,vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {prePlan}

{Note: the following routine was taken from TIterRelation
       - it wasn't totally finished/tidied, so keep in sync!
}
function TIterJoin.JustReferencesChildren(snode:TSyntaxNodePtr):integer;
{Check if this sub-tree is a candidate equi-join filter expression
 i.e. one that only equates column(s) in the left child to column(s) in the right child and
      where right child is iterRelation (at least to be able to index-nested-loop)

 (If it is, the optimise routine can choose to use it for
  (hopefully index) joining via filtered scanning of the inner (right) child relation,
  else it cannot)

 IN:       snode            the sub-tree root
 RETURNS:  +1=is a candidate expression
           else ok (or fail = error)

           matching right-child column is re-pointed by this routine to
           point directly to the left/outer child instead of this join's tuple
           so that the data is valid during the Next routine

 Assumes:
   the right child iterator is a prepared TiterRelation

   //for now assumes Left relation's column is on left of equals... FIX!
   //this also needs to cope with join using/on syntax... -higher level...

   the snode has be pre-planned

 Note:
   a candidate equi-join filter expression is one that is a simple column equality test against
   a column from each of the two children

   matching right-child column is re-pointed by this routine to
   point directly to the left/outer instead of this join's tuple
   so that the data is valid during the Next routine
}
const routine=':JustReferencesChildren';
var
  cTuple:TTuple;
  cId:TColId;
  cRef:ColRef;
begin
  result:=ok; //assume fail, i.e. that we are not a pure candidate filter expression, until proven otherwise

  //todo tidy!
  //for now we do a simplistic test: are we                   ntEqual
  //                                         ntRowConstructor         ntRowConstructor
  //       ntNumericExp|ntCharacterExp //todo etc. e.g. ntBitExp        ntNumericExp|ntCharacterExp //todo etc. e.g. ntBitExp
  //         ntColumnRef                                                  ntColumnRef

  //note: these tests assume boolean short-circuiting...
 if (self.rightChild is TIterRelation) then
  //Note: we do assume that this iter node always has 2 children!
  if snode.nType in [ntEqual,ntEqualOrNull] then
    if (snode.leftChild<>nil) and (snode.leftChild.nType=ntRowConstructor) and (snode.leftChild.nextNode=nil) then //L=single element
      if (snode.rightChild<>nil) and (snode.rightChild.nType=ntRowConstructor) and (snode.rightChild.nextNode=nil) then //R=single element
        if (snode.leftChild.leftChild<>nil) and (snode.leftChild.leftChild.nType in [ntNumericExp,ntCharacterExp]) then //L=exp
          if (snode.rightChild.leftChild<>nil) and (snode.rightChild.leftChild.nType in [ntNumericExp,ntCharacterExp]) then //R=exp
          begin
            if ( (snode.leftChild.leftChild.leftChild<>nil) and (snode.leftChild.leftChild.leftChild.nType=ntColumnRef) ) AND //L=colref
               ( (snode.rightChild.leftChild.leftChild<>nil) and (snode.rightChild.leftChild.leftChild.nType=ntColumnRef) ) then //R=colref
            begin
              {Check if the left points to the right/inner child
               and the right points to the left/outer child or vice-versa}
              {Note: even if the outer part of the equi-join cannot be pushed down (e.g. it refers to a higher level)
               we still force-push it from here & leave it to the lower levels to ignore
               (the right/inner can still use such a condition anyway)}

              {Note: we match based on table_id so implicitly assumes that we are not passing
                     conditions across sub-selects (even, for now, if they were correlated & so usable)
                     Although we Find (here + in iterRelation) using table_id + range
              }

              //Note: left & right join children are built backwards (reversed) (due to parsing/nested-building)
              //      but we'll still pass any matching tree to the right sub-node = inner relation
              //may be easier & less confusing in long run to reverse these during parsing/algebra tree building
              //       - for now, just get it working to test the principle...

              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('checking leftChild-col table_id (%d) against this nodes right iterRelation child table_ids (%d) to see if this is a valid equi-join-filter: %p',[(snode.leftChild.leftChild.leftChild.cTuple as TTuple).fColDef[snode.leftChild.leftChild.leftChild.cRef].sourceTableId, self.rightChild.aNodeRef.rel.tableId, snode]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              if ( (snode.leftChild.leftChild.leftChild.cTuple as TTuple).fColDef[snode.leftChild.leftChild.leftChild.cRef].sourceTableId=self.rightChild.aNodeRef.rel.tableId) then
              begin
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('leftChild-col=right/inner is a valid equi-join-filter (based on table_id alone): %p',[snode]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}

                {We must double-check that this matches by range before we re-point anything!
                 otherwise could be a self-join, i.e. 2 aliases}
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                //todo remove log.add(stmt.who,where+routine,format('check-range=%s:',[cRange]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                result:=self.rightChild.iTuple.FindCol(snode.leftChild.leftChild.leftChild,snode.leftChild.leftChild.leftChild.rightChild.idval,'',nil{=don't look higher flag!},cTuple{not needed},cRef,cid);
                {$IFDEF DEBUGDETAIL5}
                if cid=InvalidColId then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('...but leftChild-col=right/inner is not actually a valid equi-join-filter: %p',[snode]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                end;
                {$ENDIF}
                if cid=InvalidColId then result:=Fail; //should have been caught before now!
                if result<>ok then exit; //abort if child aborts

                {Note: we must re-point the rightChild-col directly to the left/outer tuple instead of the
                       join tuple because the join-next logic does:
                         read-left
                         read-right
                         check-join-keys
                         copy left child data into join tuple
                         copy right child data into join tuple
                       otherwise we would need it to:
                         read-left
                         copy left child data into join tuple (so right filter could find the data)
                         read-right
                         check-join-keys
                         copy right child data into join tuple

                 Note: this would probably screw up higher levels if they re-use this SARG
                       so ensure after optimiser push-down that ptMustPush ones are removed from their original source
                }
                {So first we need to re-find this column in the left/outer tuple}
                {Get range - depends on catalog.schema parse} //note: needed in case of ambiguity since left can now be other than a simple iterRelation
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                result:=self.leftChild.iTuple.FindCol(snode.rightChild.leftChild.leftChild,snode.rightChild.leftChild.leftChild.rightChild.idval,'',nil{=don't look higher flag!},cTuple{not needed},cRef,cid);
                {$IFDEF DEBUGDETAIL5}
                if cid=InvalidColId then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Unknown column reference (%s) in outer-side of join',[snode.rightChild.leftChild.leftChild.rightChild.idval]),vDebugError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                end;
                {$ENDIF}
                if cid=InvalidColId then result:=Fail; //should have been caught before now!
                if result<>ok then exit; //abort if child aborts

                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('re-pointing rightChild-col from tuple %d cref %d direct to the left/outer tuple %d cref %d',[longint(snode.rightChild.leftChild.leftChild.cTuple), snode.rightChild.leftChild.leftChild.cRef, longint(self.leftChild.iTuple), cRef]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}

                snode.rightChild.leftChild.leftChild.cTuple:=self.leftChild.iTuple;
                snode.rightChild.leftChild.leftChild.cRef:=cRef;

                result:=+1;
              end
              else
              begin //vice-versa
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('checking rightChild-col table_id (%d) against this nodes right iterRelation child table_ids (%d) to see if this is a valid equi-join-filter: %p',[(snode.rightChild.leftChild.leftChild.cTuple as TTuple).fColDef[snode.rightChild.leftChild.leftChild.cRef].sourceTableId, self.rightChild.aNodeRef.rel.tableId, snode]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                if ( (snode.rightChild.leftChild.leftChild.cTuple as TTuple).fColDef[snode.rightChild.leftChild.leftChild.cRef].sourceTableId=self.rightChild.aNodeRef.rel.tableId) then
                begin
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('rightChild-col=right/inner is a valid equi-join-filter (based on table_id alone): %p',[snode]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}

                  {We must double-check that this matches by range before we re-point anything!
                   otherwise could be a self-join, i.e. 2 aliases}
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  result:=self.rightChild.iTuple.FindCol(snode.rightChild.leftChild.leftChild,snode.rightChild.leftChild.leftChild.rightChild.idval,'',nil{=don't look higher flag?},cTuple{not needed},cRef,cid);
                  {$IFDEF DEBUGDETAIL5}
                  if cid=InvalidColId then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(stmt.who,where+routine,format('...but rightChild-col=right/inner is not actually a valid equi-join-filter: %p',[snode]),vDebugLow);
                    {$ELSE}
                    ;
                    {$ENDIF}
                  end;
                  {$ENDIF}
                  if cid=InvalidColId then result:=Fail; //should have been caught before now!
                  if result<>ok then exit; //abort if child aborts

                  {Note: we must re-point the leftChild-col directly to the left/outer tuple instead of the
                         join tuple - see above for reasoning

                   Note: this would probably screw up higher levels if they re-use this SARG
                         so ensure after optimiser push-down that ptMustPush ones are removed from their original source
                  }
                  {So first we need to re-find this column in the left/outer tuple}
                  {Get range - depends on catalog.schema parse} //note: needed in case of ambiguity since left can now be other than a simple iterRelation
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  result:=self.leftChild.iTuple.FindCol(snode.leftChild.leftChild.leftChild,snode.leftChild.leftChild.leftChild.rightChild.idval,'',nil{=don't look higher flag!},cTuple{not needed},cRef,cid);
                  {$IFDEF DEBUGDETAIL5}
                  if cid=InvalidColId then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(stmt.who,where+routine,format('Unknown column reference (%s) in outer-side of join',[snode.leftChild.leftChild.leftChild.rightChild.idval]),vDebugError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                  end;

                  {$ENDIF}
                  if cid=InvalidColId then result:=Fail; //should have been caught before now!
                  if result<>ok then exit; //abort if child aborts

                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('re-pointing leftChild-col from tuple %d cref %d direct to the left/outer tuple %d cref %d',[longint(snode.leftChild.leftChild.leftChild.cTuple), snode.leftChild.leftChild.leftChild.cRef, longint(self.leftChild.iTuple), cRef]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}

                  snode.leftChild.leftChild.leftChild.cTuple:=self.leftChild.iTuple;
                  snode.leftChild.leftChild.leftChild.cRef:=cRef;

                  result:=+1;
                end;
              end;
            end;
            //else?
          end;
end; {JustReferencesChildren}

function TIterJoin.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

  //todo could pull up some logic to this level... e.g. creating implied equi-join syntax nodes
end; {optimise}

function TIterJoin.start:integer;
{Start the join process
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

  if assigned(leftChild) then result:=leftChild.start;   //recurse down left-side of tree, i.e. left=outer join
  if result<>ok then exit; //aborted by child
  if assigned(rightChild) then result:=rightChild.start; //sub-recurse down right-side of tree (bushy)
  if result<>ok then exit; //aborted by child

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {start}

function TIterJoin.stop:integer;
{Stop the join process
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
  //note: these were swapped: 29/10/01
  if assigned(rightChild) then result:=rightChild.stop; //recurse down right-side of tree
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down left-side of tree
end; {stop}

function TIterJoin.next(var noMore:boolean):integer;
{Get the next tuple from the join process
 RETURNS:  ok, else fail

 Note: the noMore result should be kept static by the caller
       as this routine (I suspect:confirmed bug fix 15/06/99) assumes this *todo avoid this requirement?
       Does this requirement apply to other Iters?

 Note: at this level, this routine does nothing and should be overridden
}
const routine=':next';
begin
//  inherited next;
  result:=ok;
end; {next}

//combine these with two routines from IterSort - or use the ones from EvalCondExpr
function TIterJoin.CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l = r

 Assumes:
 keyColMap array has been defined in the anodeRef
 both tuples have same column definitions for those that are being compared

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'
}
const routine=':compareTupleKeysEQ';
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
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<anodeRef.keyColMapCount) do
  begin
    result:=tl.CompareCol(stmt,anodeRef.keyColMap[cl].left,anodeRef.keyColMap[cl].right,tr,resComp,resNull);
    {$IFDEF DEBUGDETAIL3}
    tl.GetInteger(anodeRef.keyColMap[cl].left,i,iv_null);
    tr.GetInteger(anodeRef.keyColMap[cl].right,i2,iv_null2);
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('comparing (%d)%d and (%d)%d, result=%d',[anodeRef.keyColMap[cl].left,i,anodeRef.keyColMap[cl].right,i2,resComp]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(anodeRef.keyColMap[cl].left,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(anodeRef.keyColMap[cl].right,resNull);
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
  if resComp=0 then res:=True else res:=False;
end; {CompareTupleKeysEQ}
function TIterJoin.CompareLeftTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l = r

 Assumes:
 keyColMap array has been defined for left tuple in the anodeRef
 both tuples have same column definitions as left column map

 //todo: pass in left/right flags to all these routines to dictate which mappings to use

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'
}
const routine=':compareLeftTupleKeysEQ';
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
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<anodeRef.keyColMapCount) do
  begin
    result:=tl.CompareCol(stmt,anodeRef.keyColMap[cl].left,anodeRef.keyColMap[cl].left,tr,resComp,resNull);
    {$IFDEF DEBUGDETAIL3}
    tl.GetInteger(anodeRef.keyColMap[cl].left,i,iv_null);
    tr.GetInteger(anodeRef.keyColMap[cl].left,i2,iv_null2);
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('comparing (%d)%d and (%d)%d, result=%d',[anodeRef.keyColMap[cl].left,i,anodeRef.keyColMap[cl].left,i2,resComp]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(anodeRef.keyColMap[cl].left,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(anodeRef.keyColMap[cl].left,resNull);
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
  if resComp=0 then res:=True else res:=False;
end; {CompareLeftTupleKeysEQ}
function TIterJoin.CompareTupleKeysGT(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l > r

 Assumes:
 keyColMap array has been defined in the anodeRef
 both tuples have same column definitions for those that are being compared

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'
}
const routine=':compareTupleKeysGT';
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
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<anodeRef.keyColMapCount) do
  begin
    result:=tl.CompareCol(stmt,anodeRef.keyColMap[cl].left,anodeRef.keyColMap[cl].right,tr,resComp,resNull);
    {$IFDEF DEBUGDETAIL3}
    tl.GetInteger(anodeRef.keyColMap[cl].left,i,iv_null);
    tr.GetInteger(anodeRef.keyColMap[cl].right,i2,iv_null2);
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('comparing (%d)%d and (%d)%d, result=%d',[anodeRef.keyColMap[cl].left,i,anodeRef.keyColMap[cl].right,i2,resComp]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(anodeRef.keyColMap[cl].left,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(anodeRef.keyColMap[cl].right,resNull);
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
  if resComp>0 then res:=True else res:=False;
end; {CompareTupleKeysGT}


end.

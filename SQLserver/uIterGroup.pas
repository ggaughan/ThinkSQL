unit uIterGroup;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}  //debug detail
//{$DEFINE DEBUGDETAIL2}

interface

uses uIterator, uSyntax, uTransaction, uStmt, uAlgebra, uTuple, uGlobal{for maxCol};

const
  MaxKeyCol=MaxCol;    //maximum number of group-by columns
  MaxMap=MaxCol;          //maximum number of column output mappings for * natural ordering

type
  TIterGroup=class(TIterator)
    private
      lastGroupTuple,tempTuple, garbageTuple:TTuple;
      noMoreStart, noMoreEnd:boolean;
      projectRef:TAlgebraNodePtr;    //stores link to Project node above so aggregates can be pulled down
      havingExprRef:TSyntaxNodePtr;  //stores link to optional Having syntax node

      {Allow read-ahead for multi-groupings to ensure stable projections of grouping columns
       - note: this currently assumes leftChild is IItersort
       - if not we assume 1 big grouping, i.e. no sort needed & so no read-ahead to preserve stability}
      lastGroupPos,lastPos:cardinal;

      //TODO: use  keyColMap:array [0..MaxKeyCol] of TKeyColMap;
      //note: index colMap subscripts start at 1
      keyCol:array [0..MaxKeyCol-1] of record col:colRef; direction:TsortDirection; end; //array of group-by columns
      keyColCount:integer;

      //todo* can remove these now we use prePlan
      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
      completedTrees2:boolean; //ensures we only complete having sub-trees once even if we're re-started

      {From iterProject to allow natural * order}
      naturalMapAllCount:integer;
      naturalMapAll:array [0..MaxMap] of colRef;

      function CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
    public
      groupRowCount:integer; //used for AVG during evalScalarExp with agStop

      function description:string; override;
      function status:string; override;

      constructor create(S:TStmt;colRef,projRef:TAlgebraNodePtr);
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterGroup}

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uEvalCondExpr, uIterProject{for SetProjectHeadings}, uMarshalGlobal, uIterSort;

const
  where='uIterGroup';

constructor TIterGroup.create(S:TStmt;colRef,projRef:TAlgebraNodePtr);
begin
  inherited create(s);
  aNodeRef:=colRef;
  projectRef:=projRef;
  havingExprRef:=aNodeRef.exprNodeRef;  //extract optional Having expression syntax tree link
  tempTuple:=TTuple.create(nil);
  garbageTuple:=TTuple.create(nil);
  lastGroupTuple:=TTuple.create(nil);
  completedTrees:=False;
  completedTrees2:=False;
end; {create}
destructor TIterGroup.destroy;
begin
  lastGroupTuple.free;
  garbageTuple.free;
  tempTuple.free;
  inherited destroy;
end; {destroy}

function TIterGroup.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  if havingExprRef<>nil then
    result:=result+' (having)';
end; {description}

function TIterGroup.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterGroup';
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterGroup.prePlan(outerRef:TIterator):integer;
{PrePlans the delete process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  n,nhead:TSyntaxNodePtr;
  count,i,j:colRef;
  colName:string;

  cTuple:TTuple;

  cId:TColId;
  cRef:ColRef;
begin
  result:=inherited prePlan(outerRef);
  if havingExprRef<>nil then
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s preplanning with having clause syntax node of %d',[self.status,ord(havingExprRef.leftChild.ntype)]),vDebugLow)
    {$ENDIF}
  else
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s preplanning (with no having clause)',[self.status]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    correlated:=correlated OR leftChild.correlated;
  end;
  if result<>ok then exit; //aborted by child

  {Define lastGroupTuple (and clone to tempTuple) from the group-by-column list}

  //assumes column type rises to top of tree

  {Set up the sort key from the column list passed}
  //may need to handle expressions here...
  // - (only for GROUP-BY sort?) although the standard grammar I have only allows column-refs!
  //                             could do SELECT exp as E ... GROUP BY E = legal
  keyColCount:=0;
  nhead:=anodeRef.nodeRef;
  i:=0;
  while nhead<>nil do
  begin
    //todo use new code that relies on complete* routines... although overkill here maybe?

    {todo: take name from column name (pass up?)
        ntSelectItem:
        begin
          n:=n.rightChild; //optional
    }
    //Note: the expression calculators will re-define these if needed anyway - ok?
    colName:=intToStr(i); //default column name
    case nhead.nType of
      ntColumnRef:
      begin
        //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
        //assumes we have a right child! -assert!
        result:=leftchild.iTuple.FindCol(nhead,nhead.rightChild.idval,'',leftchild.outer,cTuple,cRef,cid);
        if result<>ok then
        begin
          if result=-2 then
          begin
            stmt.addError(seSyntaxAmbiguousColumn,format(seSyntaxAmbiguousColumnText,[nhead.rightChild.idval]));
          end
          else
          begin
            stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,['column '+nhead.rightChild.idval]));
          end;
          exit; //abort if child aborts
        end;
        if cid=InvalidColId then
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Unknown column reference (%s)',[nhead.rightChild.idVal]),vError);
          {$ENDIF}
          stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.rightChild.idVal]));
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        if cTuple<>leftChild.iTuple then //relax later when using expressions? if so remember to pull up correlated from any call to Complete...
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Column reference (%s) must be in this sub-select',[nhead.rightChild.idVal]),vError);
          {$ENDIF}
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        if keyColCount>=MaxKeyCol-1 then
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Too many group-by columns %d',[keyColCount]),vError);
          {$ENDIF}
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        inc(keyColCount);
        keyCol[keyColCount-1].col:=cRef;

        inc(i); //single column added
      end; {ntColumnRef}
    else
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Only column references allowed in group-by',[nil]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      //ignore it! ok?
    end; {case}
    nhead:=nhead.NextNode;
  end; {while}

  //Note: if KeyColCount=0, then one big group - i.e. all columns are always equal
  //todo: if this should be 1 group per row, then set default in Compare routine <>0

  (*todo remove - may need for SUM(DISTINCT col) ?
  if keyColCount=0 then
  begin
    if distinct then //duplicate removal, so sort on all columns
    begin
      for i:=0 to iTuple.ColCount-1 do
      begin
        inc(keyColCount);
        keyCol[keyColCount-1].col:=i;
        keyCol[keyColCount-1].direction:=sdASC;
      end;
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Sorting on all %d columns',[keyColCount]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Sort needs a column reference',[nil]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      result:=fail;
    end;
  end;
  //instead assume all columns?
  *)

  {Now define the columns required by the project}
  {This code is taken from IterProject and should be kept in synch/shared}
  if projectRef<>nil then
  begin
    if not completedTrees then
    begin
      completedTrees:=True; //ensure we only complete the sub-trees once
      result:=SetProjectHeadings(stmt,projectRef,projectRef.nodeRef,iTuple,naturalMapAll,naturalMapAllCount,leftChild,False,agStart);
      if result<>ok then exit; //aborted by child
      correlated:=correlated OR leftChild.correlated;
    end;
  end;
  //else error? or maybe default to just projecting the group-by columns

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ENDIF}

  {Now complete the having clause tree}
  if havingExprRef<>nil then
  begin
    if not completedTrees2 then
    begin
      completedTrees2:=True; //ensure we only complete the sub-trees once
      result:=CompleteCondExpr(stmt,leftChild,havingExprRef,agStart{complete aggregates});
      if result<>ok then exit; //aborted by child
      correlated:=correlated OR leftChild.correlated;
    end;
  end;

  {Now setup the grouping loop tuples}
  lastGroupTuple.CopyTupleDef(leftChild.iTuple);
  tempTuple.CopyTupleDef(leftChild.iTuple);
end; {prePlan}

function TIterGroup.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ENDIF}

  if assigned(leftChild) then
  begin
    result:=leftChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('linking to new leftChild: %s',[newChildParent.Status]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    leftChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;
  //todo: same for rightChild if we could have one

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterGroup.start:integer;
{Start the group project process
 RETURNS:  ok, else fail
}
const routine=':start';
var
  i:colRef;
begin
  result:=inherited start;
  if assigned(leftChild) then result:=leftChild.start;   //recurse down tree
  if result<>ok then exit; //aborted by child

  //Important!
  //todo assert leftChild is tIterSort, else no sort = 1 big group expected!
  //- otherwise read-ahead 1 row will fail because we cannot jump back
  //  and this will cause subtle problems for any columns that try to reference
  //  the group constants/keys, especially in subqueries!

  {Now setup the grouping loop}
  lastGroupTuple.clear(stmt);
  tempTuple.clear(stmt);
  groupRowCount:=0;
  {Read the start row from the child (& remember the noMore result)}
  noMoreStart:=False; //17/06/00 debug fix- initialise
  if leftChild is Titersort then lastGroupPos:=(leftChild as titerSort).GetPosition; //bookmark
  if assigned(leftChild) then leftChild.next(noMoreStart);     //recurse down tree
  if not noMoreStart then
  begin
    inc(groupRowCount);
    {1. Group by columns}
    //todo maybe copy all columns? ok to have gaps? => assumed null
    for i:=1 to keyColCount do
    begin
      result:=tempTuple.copyColDataPtr{Data}(keyCol[i-1].col,leftChild.iTuple,keyCol[i-1].col);
    end;
  end
  else //set all to null
  begin
    tempTuple.ClearToNulls(stmt);
    tempTuple.preInsert;
  end;

  noMoreEnd:=False; //reset extra last row required for final group
end; {start}

function TIterGroup.stop:integer;
{Start the group project process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
end; {stop}

function TIterGroup.next(var noMore:boolean):integer;
{Get the next tuple from the group project process
 RETURNS:  ok, else fail
}
const
  routine=':next';
  seInternal='sys/agg'; //temp column name
var
  nhead,n:TSyntaxNodePtr;
  i,j:colRef;

  res:boolean;
  resHaving:TriLogic;
begin
//  inherited next;
  result:=ok;

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

  if noMoreEnd then //we finished during the previous call, but we had to send a final group row
  begin
    noMore:=True;   //now we really have finished
    exit;
  end;

  repeat {Having loop}
    {Initialise the lastGroupTuple to the 'last different' tuple before we compare stuff to it}
    //Note: we load it with the whole tuple (not just the group by key columns) because
    //      we currently use it to build the final iTuple at the end of each group
    lastGroupTuple.clear(stmt);
    if not noMoreStart then
    begin
      for i:=1 to lastGroupTuple.ColCount do
        lastGroupTuple.copyColDataDeep(i-1,stmt,leftChild.iTuple,i-1,false);   //deep needed - we are not merely passing up the tuples but are *creating* new ones based on groups of others - also the source may be long gone from the buffers by the end of the group
    end
    else
    begin
      lastGroupTuple.ClearToNulls(stmt);
    end;

    lastGroupTuple.preInsert; //finalise it
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%p Last initialised: %s',[@self,lastGroupTuple.Show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {Initialise the iTuple tuple and zeroise/null aggregate slots in syntax tree}
    iTuple.clear(stmt);

    nhead:=projectRef.nodeRef; //start with 1st project column
    i:=0;
    while nhead<>nil do
    begin
      n:=nhead;
      if n.aggregate then
      begin
        case n.nType of
          ntSelectItem:
          begin
            n:=n.leftChild; //get expression

            n:=n.leftChild; //move to exp root
            {We return aggregate column result in throwaway tuple}
            garbageTuple.ColCount:=1; //todo: move outside loop -speed
            garbageTuple.clear(stmt);   //todo use fast clear
            garbageTuple.SetColDef(0,1,seInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True); //have to reset if type can change?
            {evaluate sub-expression}

            result:=EvalScalarExp(stmt,leftChild,n,garbageTuple,0,agStart,false);
            if result<>ok then exit;
          end; {ntSelectItem}
          //Note ntSelectAll -> no aggregation required, so ignore here
        else
          {$IFDEF DEBUG_LOG}
          {$ELSE}
          ;
          {$ENDIF}
        end; {case}
        //todo if any result<>0 then quit
      end;
      inc(i); //processed a single column
      nhead:=nhead.nextNode;
    end;

    {Initialise the having expression aggregates slots to zero/null}
    nhead:=havingExprRef; //start with 1st having column
    while nhead<>nil do
    begin
      result:=EvalCondExpr(stmt,leftChild,havingExprRef,resHaving,agStart,false);
      if result<>ok then exit;
      nhead:=nhead.nextNode;
    end;

    {Pass forward initial noMore test}
    if noMoreStart then begin noMore:=noMoreStart{=true!}; noMoreStart:=False; end;

   {Main group loop}
    groupRowCount:=0;
    {If this is the same as the last tuple, then part of same group, so continue}
    result:=CompareTupleKeysEQ(lastGroupTuple,tempTuple,res);
    if result<>ok then exit; //abort
    while res and not noMore do
    begin
      if stmt.status=ssCancelled then
      begin
        result:=Cancelled;
        exit;
      end;

      inc(groupRowCount);
      {Update aggregate nodes in syntax tree (the aggregate functions in EvalScalarExp do this)}
      nhead:=projectRef.nodeRef; //start with 1st project column
      i:=0;
      while nhead<>nil do
      begin
        n:=nhead;
        if n.aggregate then
        begin
          case n.nType of
            ntSelectItem:
            begin
              n:=n.leftChild; //get expression

              n:=n.leftChild; //move to exp root
              {We return aggregate column result in throwaway tuple}
              garbageTuple.ColCount:=1; //todo: move outside loop -speed
              garbageTuple.clear(stmt);   //todo use fast clear
              garbageTuple.SetColDef(0,1,seInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True); //have to reset if type can change?
              {evaluate sub-expression}

              result:=EvalScalarExp(stmt,leftChild,n,garbageTuple,0,agNext,false);
              if result<>ok then exit;
            end; {ntSelectItem}
            //Note ntSelectAll -> no aggregation required, so ignore in this 'Next' loop
          else
            {$IFDEF DEBUG_LOG}
            {$ELSE}
            ;
            {$ENDIF}
          end; {case}
          //todo if any result<>0 then quit
        end;
        inc(i); //processed a single column
        nhead:=nhead.nextNode;
      end;

      {Update aggregate nodes in having syntax tree (the aggregate function in EvalCondExpr do this)}
      nhead:=havingExprRef; //start with 1st having column
      while nhead<>nil do
      begin
        {We do the evaluation to update the aggregates} //is this the only way?
        result:=EvalCondExpr(stmt,leftChild,havingExprRef,resHaving,agNext{=calculate aggregates},false);
        if result<>ok then exit; //abort (silent)
        nhead:=nhead.nextNode;
      end;


      {Read next row's group columns and compare with current}
      if leftChild is Titersort then lastPos:=(leftChild as titerSort).GetPosition; //bookmark
      tempTuple.clear(stmt); //todo speed - fastClear?
      if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
      if result<>ok then exit; //abort
      if not noMore then
      begin
        //todo maybe copy all columns? ok to have gaps? => assumed null
        for i:=1 to keyColCount do
        begin
          result:=tempTuple.copyColDataPtr(keyCol[i-1].col,leftChild.iTuple,keyCol[i-1].col);
        end;

        {$IFDEF DEBUGDETAIL}
        {Debug output}
        {$IFDEF DEBUG_LOG}
        //log.add(stmt.who,where+routine,format('%p Read: %s',[@self,tempTuple.Show(stmt)]),vDebugLow);
        {$ENDIF}
        {$IFDEF DEBUG_LOG}
        //log.add(stmt.who,where+routine,format('%p Last: %s',[@self,lastGroupTuple.Show(stmt)]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;

      {If this is the same as the last tuple, then part of same group, so continue}
      result:=CompareTupleKeysEQ(lastGroupTuple,tempTuple,res);
      if result<>ok then exit; //abort

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      {$ENDIF}
      {$IFDEF DEBUG_LOG}
      //if res then log.add(stmt.who,where+routine,'Compared equal',vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end; {while}
   {End main group loop}

    {Build the iTuple tuple from data from the last row (assumed constant for group)
     and get final value of all aggregates in this group}

    {Since we've now moved to the 1st tuple of the next group (needed to detect the end of the group)
     we first need to point the leftChild tuple at the saved member of the last (i.e. current) group
     so we read the right constants
     //I suppose we should read such constants at the start of the group, but then that means we have
       to insert/update the aggregate column data into the tuple = difficult

       we do need to set the tuple back to the previous row because further subquery rows (etc!?)
       may rely on the original syntax scope column ref pointers - the temporary repoint is only
       good enough when we tell the eval routine that we're agStop: maybe pass this down to subqueries?
       - but won't that interfere with their grouping?
       Best to move leftchild back a row?
    }
    if leftChild is Titersort then begin (leftChild as TiterSort).findPosition(lastGroupPos); result:=leftChild.next(noMore); end; //skip back to group constant row
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%p Moving back to %d from %d',[@self,lastGroupPos,lastPos]),vDebugLow);
    log.add(stmt.who,where+routine,format('%p leftChild.tuple: %s',[@self,leftChild.ituple.Show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    try
      nhead:=projectRef.nodeRef; //start with 1st project column
      i:=0;
      while nhead<>nil do
      begin
        n:=nhead;
        begin
          case n.nType of
            ntSelectItem:
            begin
              if not noMoreStart then
              begin
                n:=n.leftChild; //get expression
                n:=n.leftChild; //move to char exp root
                result:=EvalScalarExp(stmt,leftChild,n,iTuple,i,agStop{agStop->finalise AVG},false);
                if result<>ok then exit;
              end
              else  //else no valid leftChild tuple
                iTuple.SetNull(i);
            end; {ntSelectItem}
            ntSelectAll:
            begin
              for j:=0 to naturalMapAllCount-1 do
              begin
                //only add columns if the range. matches (e.g. select T1.*, T2.* ...)
                //note: match code taken from ttuple.findCol
                //todo: need to ignore columns that have commonColumn>0, i.e. they are no longer aliased! except for system-where matching
                if n.leftChild<>nil then
                  if leftChild.iTuple.fColDef[naturalMapAll[j]].commonColumn<>0 then
                    continue //skip this column, it can no longer be referered to so specifically
                  else
                    if CompareText(trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).rangeName),'')=0 then
                    begin
                      if CompareText(trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).tableName),trimRight(n.leftChild.idVal))<>0 then
                        continue; //skip this column, its owner didn't match the specified prefix
                        //todo grammar bug: should be able to check catalog + schema here!!!
                    end
                    else //aliased
                      if CompareText(n.leftChild.idVal,trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).rangeName))<>0 then
                        continue; //skip this column, its owner didn't match the specified prefix

                if not noMoreStart then //todo speed if move outside loop - i.e. test once
                begin
                  result:=iTuple.copyColDataDeep(i+j,stmt,leftChild.iTuple,naturalMapAll[j],false);
                end
                else
                  iTuple.SetNull(i+j);
                //todo if any result<>0 then quit
              end;
              inc(i,leftChild.iTuple.ColCount-1); //bulk columns processed (-1 because we increment at end of loop)
            end; {ntSelectAll}
          else
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unrecognised select constructor node (%d)',[ord(n.nType)]),vDebugWarning);
            {$ELSE}
            ;
            {$ENDIF}
          end; {case}
          //todo if any result<>0 then quit
        end;
        inc(i); //processed a single column
        nhead:=nhead.nextNode;
      end;

      iTuple.preInsert; //finalise the output tuple

      {Check Having expression, if any}
      result:=EvalCondExpr(stmt,leftChild,havingExprRef,resHaving,agStop,false);
      if result<>ok then exit; //abort (silent)
    finally
      //debug remove leftChild.iTuple:=storeTuple; //restore child iTuple! //Note: assumes we're the only thread calling leftChild
      if leftChild is Titersort then begin (leftChild as TiterSort).findPosition(lastPos); result:=leftChild.next(noMore); end; //restore bookmark
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%p Moving back to %d',[@self,lastPos]),vDebugLow);
      log.add(stmt.who,where+routine,format('%p leftChild.tuple: %s',[@self,leftChild.ituple.Show(stmt)]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end; {try}

    //for speed: we should bookmark this before every leftChild.next to
    //             limit the amount of bookmark restore to 1 row so:
    //                1) less disk traversal (especially since a group could be massive)
    //                2) we could implement a 1 row local buffer, even when we have no TiterSort beneath
    if leftChild is Titersort then lastGroupPos:=lastPos; //bookmark for next group

  until (havingExprRef=nil) or noMore or (resHaving=isTrue); //i.e. until no having, no more, or having=isTrue

  {If this is the last row, but the Having clause filtered it out, then don't return it}
  if (havingExprRef<>nil) and noMore and (resHaving<>isTrue) then
  begin
    noMoreEnd:=True; //force immediate end with no final row
  end;

  if noMore and not noMoreEnd then
  begin
    noMore:=False;    //fake a final row, even though children are now emptied
    noMoreEnd:=True;  //make sure we trap the next call and send a genuine noMore to terminate
  end;
end; {next}

//combine/merge with ones from sort/loop etc.
function TIterGroup.CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l = r

 Assumes:
 keyCol array has been defined
 both tuples have same column definitions

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'

 Takes account of sort direction for each column (reverses test result for DESCending)
}
const routine=':compareTupleKeysEQ';
var
  cl:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<keyColCount) do
  begin
    result:=tl.CompareCol(stmt,keyCol[cl].col,keyCol[cl].col,tr,resComp,resNull);
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(keyCol[cl].col,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(keyCol[cl].col,resNull);
        if result<>ok then exit; //abort
        if resNull then
          resComp:=0   //both are null so treat as equal (SQL anomaly!)
        else
          resComp:=NullSortOthers;
      end
      else
        resComp:=-NullSortOthers;
    end;
    if keyCol[cl].direction=sdDESC then resComp:=-resComp; //reverse direction
    inc(cl);
  end;
  if resComp=0 then res:=True else res:=False;
end; {CompareTupleKeysEQ}

end.

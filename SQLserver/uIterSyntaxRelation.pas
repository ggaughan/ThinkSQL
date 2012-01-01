unit uIterSyntaxRelation;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}


{Syntax tree temporary relation iterator

 This is slightly different from most other iterators in that it traverses the
 syntax tree in its next loop.
 Used for table/row constructors introduced with the VALUES construct.
}

{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2}

interface

uses uIterator, uTuple, uTransaction, uStmt, uSyntax, uAlgebra;

type
  TIterSyntaxRelation=class(TIterator)
    private
      nextRCnode:TSyntaxNodePtr;   //track the syntax node for the next row-constructor
      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
    public
      constructor create(S:TStmt;rowRef:TAlgebraNodePtr);

      function status:string; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterSyntaxRelation}

implementation

uses uLog, sysUtils, uGlobal, uEvalCondExpr;

const
  where='uIterSyntaxRelation';

constructor TIterSyntaxRelation.create(S:TStmt;rowRef:TAlgebraNodePtr);
begin
  inherited create(s);
  aNodeRef:=rowRef; //pointer to table constructor tree
  completedTrees:=False;
end; {create}

function TIterSyntaxRelation.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterSyntaxRelation'; //todo show nextRCnode?
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterSyntaxRelation.prePlan(outerRef:TIterator):integer;
{PrePlans the syntax relation process
 RETURNS:  ok, else fail
}
const
  routine=':prePlan';
var
  count,nextCol:colRef;
  n,nhead:TSyntaxNodePtr;
  rcInternal:string;
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if anodeRef.nodeRef.nType<>ntTableConstructor then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Root should be a table constructor (%d)',[ord(anodeRef.nodeRef.nType)]),vDebugError); //assertion
    {$ENDIF}
    result:=Fail;
    exit;
  end;
  nextRCnode:=anodeRef.nodeRef.leftChild; //point to 1st child of table-constructor=1st row-constructor in list
  {Complete all row-constructor sub-tree(s)}
  if not completedTrees then
  begin
    completedTrees:=True; //ensure we only complete the sub-trees once
    while nextRCnode<>nil do
    begin
      result:=CompleteRowConstructor(stmt,outer,nextRCnode,agNone);
      if result<>ok then exit; //abort
      if outer<>nil then correlated:=correlated OR outer.correlated; //todo ok? needed? I think so, e.g. select..from X where X.x=(select y from (values (X.x)) as Y)
      //we should:
      //  check valency of this RC is same as all preceding
      //  check column types of this RC are compatible with all preceding
      //  maybe we should pick largest definitions from all the row-constructor completions?
      nextRCnode:=nextRCnode.nextNode; //next row-constructor in list
    end;
  end;
  nextRCnode:=anodeRef.nodeRef.leftChild; //point to 1st child of table-constructor=1st row-constructor in list
  {Try to build the tuple descriptor from the 1st row constructor}
  count:=0;
  if nextRCnode<>nil then
  begin
    nhead:=nextRCnode.leftChild;
    while nhead<>nil do
    begin
      inc(count);
      nhead:=nhead.NextNode;
    end;
  end;
  iTuple.clear(stmt); //todo: needed here in prePlan? ok just to move to start method?

  iTuple.ColCount:=count;
  iTuple.clear(stmt); //todo: needed here in prePlan? ok just to move to start method?

  {For each node in the chain (for scalar_exp_commalist)}
  nhead:=nextRCnode.leftChild;
  nextCol:=0;
  {If we have a list of column aliases (that were set at the table_ref level) then apply them during the loop
   Note: this is the only way of naming syntax relation columns
   Note: we also point them to any table alias via their sourceRange, e.g. in case T.* is used to reference them}
  n:=anodeRef.exprNodeRef;
  while nhead<>nil do
  begin
    rcInternal:=intToStr(nextCol+1); //'implementation defined' internal column name
    {If we have a columm alias then use it instead. Note: assumes we have exactly the right number of aliases - else left half aliased, which is not allowed by SQL standard (even though it might be useful!)}
    if n<>nil then
    begin
      rcInternal:=n.idVal; //column alias
      n:=n.nextNode;
    end;
    //default type definition based on dtype info passed up syntax tree
    iTuple.SetColDef(nextCol,nextCol+1,rcInternal,0,nhead.dType,nhead.dwidth,nhead.dscale,'',True);
    iTuple.fColDef[nextCol].sourceTableId:=SyntaxTableId; //set sourceTableId to skip privilege checking
    {Now we can set the column's sourceRange (i.e. table alias)}
    iTuple.fColDef[nextCol].sourceRange:=aNodeRef;
    iTuple.fColDef[nextCol].sourceAuthId:=tran.authID; //todo ok? needed?

    inc(nextCol);
    nhead:=nhead.nextNode;
  end;

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,stringOfChar('=',length(iTuple.ShowHeading)),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
end; {prePlan}

function TIterSyntaxRelation.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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
  {$ELSE}
  ;
  {$ENDIF}

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterSyntaxRelation.start:integer;
{Start the syntax relation process
 RETURNS:  ok, else fail
}
const
  routine=':start';
begin
  result:=inherited start;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  nextRCnode:=anodeRef.nodeRef.leftChild; //point to 1st child of table-constructor=1st row-constructor in list

  iTuple.clear(stmt); //ok here? - copied from prePlan
end; {start}

function TIterSyntaxRelation.stop:integer;
{Stop the syntax relation process
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
  //todo assert nextRCnode=nil? - no may have genuinely aborted... set success=false?
end; {stop}

function TIterSyntaxRelation.next(var noMore:boolean):integer;
{Get the next tuple from the syntax relation process
 RETURNS:  ok, else fail
}
const routine=':next';
begin
//  inherited next;
  result:=ok;
{$IFDEF DEBUGDETAIL}
{$IFDEF DEBUG_LOG}
{$ELSE}
;
{$ENDIF}
{$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  if nextRCnode=nil then
  begin
    noMore:=true;
{$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',['no more']),vDebugLow)
    {$ELSE}
    ;
    {$ENDIF}
{$ENDIF}
  end
  else
  begin
    //todo need to check valency of this RC is same as all others!
    noMore:=false;
    result:=EvalRowConstructor(stmt,outer{=nil},nextRCnode,iTuple,agNone,true{=preserve tuple definition},false);
    if result<>ok then exit; //abort
    nextRCnode:=nextRCnode.nextNode; //ready for next row-constructor in list
{$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugLow)
    {$ELSE}
    ;
    {$ENDIF}
{$ENDIF}
  end;
end; {next}

end.

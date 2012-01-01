unit uIterInto;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}

{Note: prePlan and Next routines behave slightly differently if this is part of a cursor stmt, i.e. a fetch
 (basically no call to leftchild.preplan & can handle multiple rows: one per call)
}

interface

uses uIterator, uTransaction, uStmt, uSyntax, uAlgebra;

type
  TIterInto=class(TIterator)
    private
      rowCount:integer; //keep count of rows output (just for debugging?)

      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
    public
      function status:string; override;

      constructor create(S:TStmt;targetExprRef:TAlgebraNodePtr);
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterInto}

implementation

uses uLog, sysUtils, uGlobal, uTuple, uEvalCondExpr, uVariableSet,
uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}
;

const
  where='uIterInto';

constructor TIterInto.create(S:TStmt;targetExprRef:TAlgebraNodePtr);
begin
  inherited create(s);
  aNodeRef:=targetExprRef;
  completedTrees:=False;
end; {create}

destructor TIterInto.destroy;
begin
  inherited destroy;
end; {destroy}


function TIterInto.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterInto [%d row(s)]',[rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterInto.prePlan(outerRef:TIterator):integer;
{PrePlans the output process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  nhead,n:TSyntaxNodePtr;
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then
  begin
    if (stmt.stmtType<>stUserCursor) then result:=leftChild.prePlan(outer);   //recurse down tree
    if result<>ok then exit; //aborted by child
    correlated:=correlated OR leftChild.correlated;

    {This is a real sink since we don't define our ituple}
  end;

  {Now prepare our target list}
  if not completedTrees then
  begin
    n:=anodeRef.nodeRef;  //start of target chain
    while n<>nil do
    begin
      result:=CompleteScalarExp(stmt,leftChild,n,agNone);
      correlated:=correlated OR leftChild.correlated;

      n:=n.NextNode;
    end;
  end;

  //todo findVars now!

  completedTrees:=True; //ensure we only complete the sub-trees once
end; {prePlan}

function TIterInto.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterInto.start:integer;
{Start the into process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.start;   //recurse down tree
    if result<>ok then exit; //aborted by child
  end;

  rowCount:=0;
end; {start}

function TIterInto.stop:integer;
{Stop the into process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
end; {stop}

function TIterInto.next(var noMore:boolean):integer;
{Get the next tuple & set the sepcified variables
 RETURNS:  ok, else fail
}
const routine=':next';
var
  i:ColRef;
  nhead,n:TSyntaxNodePtr;
  vId:TVarId;
  vSet:TVariableSet;
  vRef:VarRef;
begin
//  inherited next;
  result:=ok;
{$IFDEF DEBUG_LOG}
//  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
{$ELSE}
;
{$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
  if result<>ok then exit; //abort
  if not noMore then
  begin
    if (rowCount<>0) and (stmt.stmtType<>stUserCursor) then
    begin //we're expecting only 1 row here: else we need a cursor
      stmt.addError(seOnlyOneRowExpected,seOnlyOneRowExpectedText);
      result:=fail;
      exit; //abort
    end;

    n:=anodeRef.nodeRef;  //start of target chain

    for i:=0 to leftChild.iTuple.ColCount-1 do
    begin
      if n<>nil then
      begin //we have a target
        //todo findVars during prePlan - speed!

        if assigned(stmt.varSet) then
        begin
          {Find the variable}
          //todo assert assigned(stmt.varSet)!!! or ensure we always have one...
          result:=stmt.varSet.FindVar(n.idval,stmt.outer,vSet,vRef,vid);
          if vid=InvalidVarId then
          begin
            //todo make this next error message more specific, e.g. unknown target reference...
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idval]));
            result:=fail;
            exit; //abort the operation
          end;
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Setting variable (%x) %d',[longint(vset),vid]),vDebug);
          {$ENDIF}
          result:=vset.CopyColDataDeepGetSet(tran,vRef,leftChild.iTuple,i);  //Note: deep copy required here
          if result<>ok then
          begin
            stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
            exit; //abort the operation
          end;
        end
        else
        begin
          //todo make this next error message more specific, e.g. no target references in this context...
          stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.idval]));
          result:=fail;
          exit; //abort the operation
        end;

        n:=n.nextNode; //next parameter in this list
      end
      else
      begin
        stmt.addError(seSyntaxNotEnoughParemeters,seSyntaxNotEnoughParemetersText);
        result:=fail;
        exit; //abort
      end;
    end;

    inc(rowCount);
  end;
end; {next}


end.

unit uIterOutput;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{05/01/02
 No longer used: replaced by ExecSQL cursor loop 
}

{$DEFINE DEBUGDETAIL}

interface

uses uIterator, uTransaction, uStmt, IdTCPConnection, uSyntax;

type
  TIterOutput=class(TIterator)
    private
      rowCount:integer; //keep count of rows output (just for debugging?)
      connection:TIdTCPConnection; //output result to this client connection
    public
      function status:string; override;

      constructor create(T:TTransaction;S:TStmt;clientConnection:TIdTCPConnection);
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterOutput}

implementation

uses uLog, sysUtils, uGlobal, uTuple;

const
  where='uIterOutput';

constructor TIterOutput.create(T:TTransaction;S:TStmt;clientConnection:TIdTCPConnection);
begin
  inherited create(t,s);
  connection:=clientConnection;
end; {create}

destructor TIterOutput.destroy;
begin
  inherited destroy;
end; {destroy}


function TIterOutput.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterOutput [%d row(s)]',[rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterOutput.prePlan(outerRef:TIterator):integer;
{PrePlans the output process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    if result<>ok then exit; //aborted by child
    correlated:=correlated OR leftChild.correlated;

    {Define this ituple from leftChild.ituple}
    //todo is there a way to share the same memory or tuple?
    // - maybe destroy this one & point iTuple at leftChild's?
    iTuple.CopyTupleDef(leftChild.iTuple);
  end;

  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ELSE}
  ;
  {$ENDIF}
end; {prePlan}

function TIterOutput.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
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
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(tran.who,where+routine,format('linking to new leftChild: %s',[newChildParent.Status]),vDebugLow);
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

function TIterOutput.start:integer;
{Start the output process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.start;   //recurse down tree
    if result<>ok then exit; //aborted by child
  end;

  rowCount:=0;

  if connection<>nil then
  begin
    connection.WriteLn(format('%s',[iTuple.ShowHeading]));
    connection.WriteLn(stringOfChar('=',length(iTuple.ShowHeading)));
  end;
end; {start}

function TIterOutput.stop:integer;
{Stop the output process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree

  {Now output the row count}
  {$IFDEF DEBUG_LOG}
  log.add(tran.who,where+routine,format('%d row(s) affected',[rowCount]),vDebugHigh);
  {$ELSE}
  ;
  {$ENDIF}
  if connection<>nil then
    if rowcount=1 then  //todo use common plural routine if needed elsewhere
      connection.WriteLn(format('%d row affected',[rowCount]))
    else
      connection.WriteLn(format('%d rows affected',[rowCount]));
  //Note: we leave timings etc. to caller (for now)
end; {stop}

function TIterOutput.next(var noMore:boolean):integer;
{Get the next tuple from the output process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the copy method used) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok, else fail
}
const routine=':next';
var
  i:ColRef;
begin
//  inherited next;
  result:=ok;
{$IFDEF DEBUG_LOG}
//  log.add(tran.who,where+routine,format('%s next',[self.status]),vDebugLow);
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
  begin //copy leftchild.iTuple to this.iTuple (point?)
    iTuple.clear(tran); //speed - fastClear?
    for i:=0 to leftChild.iTuple.ColCount-1 do
    begin
      if iTuple.fColDef[i].dataType<>leftChild.iTuple.fColDef[i].datatype then
        iTuple.CopyColDef(i,leftChild.iTuple,i); //DEBUG only to fix when # suddenly changes to $ - remove!!
                                                 //Did fix problem - but need to remove this overhead!!!
                                                 // e.g. problem: select 1,(select "s" from sysTable) from sysTable
                                                 //                                 ^
      iTuple.CopyColDataPtr(i,leftChild.iTuple,i);
    end;
    {Now do the actual output - the whole point of this extra layer!}
    {$IFDEF DEBUG_LOG}
    log.add(tran.who,where+routine,format('%s',[iTuple.Show(tran)]),vDebugHigh);
    {$ELSE}
    ;
    {$ENDIF}
    if connection<>nil then connection.WriteLn(format('%s',[iTuple.Show(tran)]));
    inc(rowCount);
  end;
end; {next}


end.

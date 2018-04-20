unit uIterStmt;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Abstract atomic data modification statement, e.g. iterInsert, iterUpdate, iterDelete

 Safe to assume that anodeRef.rel is set to the relation that will be modified
}

interface

uses uIterator, uTuple, uTransaction, uStmt, uAlgebra, uSyntax;

type
  TIterStmt=class(TIterator)
    private
      unusedTuple:TTuple; //used to save/restore our tuple for destruction
    public
      rowCount:integer; //keep count of rows affected

      constructor create(S:TStmt;relRef:TAlgebraNodePtr); virtual;
      destructor destroy; override;

      //function status:string; override;

      //todo bring up to this level: function prePlan(outerRef:TIterator):integer; override;
      //todo bring up to this level: function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      //todo bring some up to this level: function next(var noMore:boolean):integer; override;   //loop
  end; {TIterStmt}


implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uGlobal, uGlobalDef, uProcessor,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
     uConstraint
     ;

const
  where='uIterStmt';

constructor TIterStmt.create(S:TStmt;relRef:TAlgebraNodePtr);
begin
  inherited create(s);
  anodeRef:=relRef;
  {Note: we assume anodeRef.rel has been created (& opened) by caller
   so we do not own it (& its tuple has been created elsewhere)
   Note: originally opened from anodeRef (& will be closed from there)
  }
  unusedTuple:=iTuple; //save our tuple for final destruction
  {Define (repoint) our ituple as mapping directly to the relation's tuple}
  {$IFDEF DEBUG_LOG}
  //log.add(stmt.who,where+':create',format('rel name=',[anodeRef.rel.relname]),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  //log.add(stmt.who,where+':create',format('  anodeRef.rel=%d',[longint(anoderef.rel)]),vDebug);
  {$ENDIF}
  iTuple:=anodeRef.rel.fTuple;
end; {create}


destructor TIterStmt.destroy;
begin
  iTuple:=unusedTuple; //restore our tuple for final destruction

  inherited destroy;
end; {destroy}

function TIterStmt.start:integer;
{Start the process
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
  end;

  if result<>ok then exit; //aborted by child

  rowCount:=0;

  {Now start a sub-transaction so we can abort cleanly at any time if we need to}
  result:=tran.StmtStart(stmt);
  if result<>ok then
  begin
    stmt.addError(seStmtStartFailed,format(seStmtStartFailedText,[nil]));
    exit; //abort if child aborts
  end;
end; {start}

function TIterStmt.stop:integer;
{Stop the process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree

  //todo maybe flush or close the relation?

  //todo maybe clear the iTuple to release any blob data now (no need: should have been released on insert/update)

  //todo: check the current result then
  // check immediate constraints

  {Now commit or rollback the sub-transaction}
  //Note: unlike insert and update, delete failures here should be rare
  //      since foreign/primary key constraints etc. ensure the data *in* the
  //      tables is valid.
  //      However, table constraints may fail(?) e.g. check(...count(*)...>0)
  if success=ok then
  begin
    if tran.StmtCommit(stmt)<>ok then
    begin
      result:=Fail;
      exit; //abort if child aborts
    end
    else
    begin
      {Now output the row count}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%d row(s) affected',[rowCount]),vDebugHigh);
      {$ENDIF}
      //Note: we leave timings etc. to caller (for now)
    end;
  end
  else
  begin
    if tran.StmtRollback(stmt)<>ok then
    begin
      //keep original error code //todo ok? any use?
      exit; //abort if child aborts
    end
    else
    begin
      {Now output the debug dirtied-row count} //todo remove
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%d row(s) dirtied before stmt rollback',[rowCount]),vDebugLow);
      {$ENDIF}
    end;
  end;
end; {stop}



end.

unit uIterDelete;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}

interface

uses uIterator, uIterStmt, uTuple, uTransaction, uStmt, uAlgebra, uSyntax;

type
  TIterDelete=class(TIterStmt)
    private
    public
      constructor create(S:TStmt;relRef:TAlgebraNodePtr); override;
      destructor destroy; override;

      function status:string; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterDelete}

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
  where='uIterDelete';

constructor TIterDelete.create(S:TStmt;relRef:TAlgebraNodePtr);
begin
  inherited create(s,relRef);
end; {create}

destructor TIterDelete.destroy;
begin
  inherited destroy;
end; {destroy}

function TIterDelete.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterDelete %d',[rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterDelete.prePlan(outerRef:TIterator):integer;
{PrePlans the delete process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  {for privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  schema_name,table_name:string;
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    correlated:=correlated OR leftChild.correlated;
    {$IFDEF DEBUG_LOG}
    //log.add(stmt.who,where+routine,format('leftchild.rel name=',[leftChild.iTuple.rel.relname]),vDebugLow);
    {$ENDIF}
    {$IFDEF DEBUG_LOG}
    //log.add(stmt.who,where+routine,format('  leftchild.rel=%d',[longint(leftChild.iTuple.rel)]),vDebug);
    {$ENDIF}
  end;

  if result<>ok then exit; //aborted by child

  {We need to skip permission checks (and so we skip constraint checks) during Delete when transaction.authId=_SYSTEM
   to allow dropping of user objects  //todo more clever if granted delete permission to _SYSTEM... no chicken & egg case here!
   //todo * replace with a proper grant
   //    since _SYSTEM shouldn't really be omnipotent & it's currently inconsistent because
   //    _SYSTEM can't update or even select from any old table, but it can insert/delete!
  }
  if not( (Ttransaction(stmt.owner).authID=1) and (anodeRef.rel.schemaId=sysCatalogDefinitionSchemaId) ) then //todo replace 1 with constant for _SYSTEM
  begin
    {Now we ensure we have privilege to Delete from this table
      - this needs to be fast!
    }
    if CheckTableColumnPrivilege(stmt,0{we don't care who grantor is},Ttransaction(stmt.owner).authId,{todo: are we always checking our own privilege here?}
                                 False{we don't care about role/authId grantee},authId_level_match,
                                 anodeRef.rel.AuthId{=source table owner},
                                 anodeRef.rel.TableId{=source table},
                                 0{=table level check},table_level_match{we don't care how exact we match: can only be table-level here},
                                 ptDelete,False{we don't want grant-option search},grantabilityOption)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Failed checking privilege %s on %d for %d',[PrivilegeString[ptDelete],anodeRef.rel.TableId,tran.AuthId]),vDebugError);
      {$ENDIF}
      stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[anodeRef.rel.relname+' privilege']));
      result:=Fail;
      exit;
    end;
    if grantabilityOption='' then //use constant for no-permission?
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Not privileged to %s on %d for %d',[PrivilegeString[ptDelete],anodeRef.rel.TableId,tran.AuthId]),vDebugLow);
      {$ENDIF}
      stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to delete from '+anodeRef.rel.relname]));
      result:=Fail;
      exit;
    end;
  end
  else //internal system catalog delete - no permission checks required //todo check not a loophole...
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Internal deletion - skipping permission checks and constraints',[nil]),vDebugHigh); //debug
    {$ENDIF}
  end;

  {Ok, we're privileged}


  {Now add any table constraints} //is this ok inside the 'avoid checks if system catalog insert' block?
  //note: only the FK parent ones will be checked by this iterator
  {First get the table name} //isn't anodeRef.rel.relname always ok? -so set once at start & re-use here?
  table_name:=anodeRef.rel.relname;
  schema_name:=anodeRef.rel.schemaName;
  if AddTableColumnConstraints(stmt,self,schema_name,anodeRef.rel.tableId,table_name,0{=table-level},ccDelete)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Failed adding constraints for %d',[anodeRef.rel.tableId]),vDebugError);
    {$ENDIF}
    stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[table_name+' constraint']));
    result:=Fail;
    exit;
  end;

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ENDIF}
end; {prePlan}

function TIterDelete.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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
    {$ENDIF}
    {$ENDIF}
    leftChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;
  //todo: same for rightChild if we could have one

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterDelete.start:integer;
{Start the delete process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  if result<>ok then exit; //aborted by child
end; {start}

function TIterDelete.stop:integer;
{Stop the delete process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
end; {stop}

function TIterDelete.next(var noMore:boolean):integer;
{Get the next tuple from the project process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the copy method used) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok,
           -2 = delete rejected =>too late
           else fail
}
const routine=':next';
var   i:ColRef;
begin
//  inherited next;
  result:=ok;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
  {$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
  if result<>ok then
  begin
    success:=Fail;
    exit; //abort;
  end;
  if not noMore then
  begin
    {Now do the actual delete - the whole point of this extra layer!}
    {We do it before constraint check/action to:
        a) prevent cascading cycles
        b) prevent new children during deletion
    }
    {Note: self.iTuple (just loaded above) -> anodeRef.rel.fTuple = delete target relation}

    {Note: we can assume source.rid always=target.rid because they point to the same relation
     and rids don't move.
    }
    result:=iTuple.delete(stmt,leftChild.iTuple.RID);

    if result=-2{tooLate} then
    begin
      stmt.addError(seDeleteTooLate,format(seDeleteTooLateText,[nil]));
    end;

    if result=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%s <%d:%d>',[leftChild.iTuple.Show(stmt),leftChild.iTuple.RID.pid,leftChild.iTuple.RID.sid]),vDebugHigh);
      {$ENDIF}
      inc(rowCount);
    end
    else
      success:=Fail;


    {We shallow-copy the feeder relation's iTuple into our iTuple to allow constraint check substitution
     Both tuples are pointing to the same relation, so their definitions are identical
     - check speed ok...
    }
    //note: this is needed because the iTuple.delete above calls file.delete...
    //       which overwrites the record in the buffer, i.e. the root source, with the deleted row
    //       & we need to refer back to the pre-delete values
    iTuple.clear(stmt); //todo speed - fastClear?
    for i:=0 to leftChild.iTuple.ColCount-1 do
    begin
      iTuple.CopyColDataPtr(i,leftChild.iTuple,i);
    end;

    {Note: this is after the actual tuple.delete to avoid cycles (although cycle definitions prevented for now... but self?)
          also will prevent new children being added by another transaction while we're checking/cascading!
          - so we restore iTuple before calling constraint.check (for param values)
    }
    if (stmt.constraintList as Tconstraint).checkChain(stmt,self{iter context},ctRow,ceParent)<>ok then
    begin
      success:=Fail; {=> rollback statement} //todo * in future: cascade etc. & continue!
                                             //Note: constraint.check should do this (& return ok) so call at tran level will also work...
      dec(rowCount); //actually didn't!
      result:=-10;
      exit; //abort the operation
    end;

  end;
end; {next}


end.

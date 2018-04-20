unit uIterUpdate;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}

interface

uses uIterator, uIterStmt, uTuple, uTransaction, uStmt, uAlgebra,uGlobal{for colRef}, uSyntax;

type
  TIterUpdate=class(TIterStmt)
    private
      tempTuple:TTuple;   //used to build default/actual value
      updateCount:colRef; //remember number of update assignments

      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
    public
      constructor create(S:TStmt;relRef:TAlgebraNodePtr); override;
      destructor destroy; override;

      function status:string; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterUpdate}

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uGlobalDef,
     uEvalCondExpr, uProcessor,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
     uConstraint;

const
  where='uIterUpdate';

constructor TIterUpdate.create(S:TStmt;relRef:TAlgebraNodePtr);
begin
  inherited create(s,relRef);
  completedTrees:=False;

  tempTuple:=TTuple.create(nil);
  tempTuple.ColCount:=1;
end; {create}

destructor TIterUpdate.destroy;
begin
  tempTuple.free;

  inherited destroy;
end; {destroy}

function TIterUpdate.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterUpdate %d',[rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterUpdate.prePlan(outerRef:TIterator):integer;
{PrePlans the update process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  nhead,n:TSyntaxNodePtr;
  count,i,j:colRef;
  colName:string;

  cTuple:TTuple;   //make global?

  cRange:string;
  cId:TColId;
  cRef:ColRef;

  {for privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  schema_name,table_name:string;
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ELSE}
  ;
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

  {we always need a relation, so
       point ituple at our own anode.rel relation version/view
       shallow-copy the leftChild tuple to our cleared ituple & update it to the correct RID...
       speed ok?
       else
         need a way to link back to original source relation = possible because only thing in way
         is a where clause - i.e. no group/having/order by etc.
         so link base relation to anode in processor...
         BUT maybe better to read from rel1 and update rel2 - especially for key modification etc.?
          - cos where clause could introduce new kind of non-sequential scanning
  }

  {We now note the number of update-assignment columns
   (we need to do this so we can use column-headers to store the col-ids in the tuple's NewDataRec buffer)
   Also, we complete the syntax tree for each update scalar expression
  }
  {We first count each node in the update-assignment chain to set the tuple's update buffer size
   - improve?
   Also, while we're at it, we pre-scan the syntax tree for any expressions to fill in
   any missing type information.
   Also we check we have Update permission on each column to be updated
   (by doing this we also remember the colRef's to prevent re-Finding every call to next - speed).
   We can do this now that the relations are open and the iterator plan is built.
   Note: this needs to be fairly quick since it's done when the client SQLprepares

   Note+: the results of this are also used by the addConstraint routine
  }
  count:=0;
  nhead:=anodeRef.exprNodeRef;  //start of update-assignment chain
  while nhead<>nil do
  begin
    if nhead.nType<>ntUpdateAssignment then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Node is not an update-assignment node (%s)',[ord(nhead.ntype)]),vAssertion); //must be grammar error?
      {$ENDIF}
      exit; //abort
    end
    else
    begin
      inc(count);
      {Check our Update permission of the LHS column}
      {First, find the column ref}
      cRange:=''; //always look in this tuple (grammar allows column, not column-ref) obvious for update!
      //assumes we have a left child! -assert!
      result:=iTuple.FindCol(nil,nhead.leftChild.idval,cRange{range},nil,cTuple,cRef,cid);
      if result<>ok then exit; //abort if child aborts
      if cid=InvalidColId then
      begin
        //shouldn't this have been caught before now!?
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Unknown column (%s)',[nhead.leftChild.idVal]),vError);
        {$ENDIF}
        stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.leftChild.idVal]));
        result:=Fail;
        exit; //abort, no point continuing?
      end;
      {Note: we don't use cTuple, we just used FindCol to find our own id,
       never to find a column source}
      if cTuple<>iTuple then
      begin
        //shouldn't this have been caught before now!?
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Column tuple found in %p and not in this update relation %p',[@cTuple,@iTuple]),vAssertion);
        {$ENDIF}
        //todo * resultErr - or catch earlier with result=-2 = ambiguous
        result:=Fail;
        exit; //abort, no point continuing?
      end;

      //todo if iTuple.fCol[cref].dataType not coercable to nhead.rightChild.expression.datatype found below:then error
      {We store the column reference (in the ntUpdateAssignment syntax node) for use at evaluation time - speed}
      //todo use the node's cTuple/cRef directly so we don't need local vars & this copying - make sure FindCol only sets if found
      // - TODO ASSERT IF cTuple<>nil here!
      if nhead.cTuple=nil then
      begin
        nhead.cTuple:=cTuple; //todo remove?: not actually used (yet!? - maybe better to leave=safer for future)
        nhead.cRef:=cRef;
      end; //else already set //todo should never happen //todo note: we still go ahead & update the type/size again...shouldn't matter...
      {$IFDEF DEBUG_LOG}
      if nhead.cTuple=nil then
        log.add(stmt.who,where+routine,format('Column tuple not found/set in this update relation %p',[@iTuple]),vAssertion);
      {$ENDIF}

      {Now we ensure we have privilege to Update this column
        - we leave it to the CheckTableColumnPrivilege routine to sensibly cache when we're checking for a whole table
        - especially since we always are here in an Update routine!
        - this needs to be fast!
      }
      if CheckTableColumnPrivilege(stmt,0{we don't care who grantor is},Ttransaction(stmt.owner).authId,{todo: are we always checking our own privilege here?}
                                   False{we don't care about role/authId grantee},authId_level_match,
                                   {todo use anodeRef.rel.authid instead?if only updating 1 relation,never a join}cTuple.fColDef[cRef].sourceAuthId{=source table owner},
                                   {todo use anodeRef.rel.tableid instead?if only updating 1 relation,never a join}cTuple.fColDef[cRef].sourceTableId{=source table},
                                   cid,table_level_match{we don't care how exact we match},
                                   ptUpdate,False{we don't want grant-option search},grantabilityOption)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Failed checking privilege %s on %d:%d for %d',[PrivilegeString[ptUpdate],cTuple.fColDef[cRef].sourceTableId,cid,tran.AuthId]),vDebugError);
        {$ENDIF}
        stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[nhead.leftChild.idVal+' privilege']));
        result:=Fail;
        exit;
      end;
      if grantabilityOption='' then //use constant for no-permission?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Not privileged to %s on %d:%d for %d',[PrivilegeString[ptUpdate],cTuple.fColDef[cRef].sourceTableId,cid,tran.AuthId]),vDebugLow);
        {$ENDIF}
        stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to update '+nhead.leftChild.idVal]));
        result:=Fail;
        exit;
      end;

      {Ok, we're privileged}

      {Now add any column constraints}
      {First get the table name}
        table_name:=anodeRef.rel.relname;
        schema_name:=anodeRef.rel.schemaName;
      if AddTableColumnConstraints(stmt,self,schema_name,iTuple.fColDef[cRef].sourceTableId,table_name,iTuple.fColDef[cRef].id,ccUpdate)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Failed adding constraints for %d:%d',[iTuple.fColDef[cRef].sourceTableId,iTuple.fColDef[cRef].id]),vDebugError);
        {$ENDIF}
        stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[iTuple.fColDef[cRef].name+' constraint']));
        result:=Fail;
        exit;
      end;


      {Now, check/complete any expression on the RHS}
      n:=nhead.rightChild; //get expression
      if n=nil then
      begin //default
      end
      else
      begin
        if n.nType=ntNull then //todo pass through eval below?
        begin
        end
        else
        begin
          if not completedTrees then
          begin
            result:=CompleteScalarExp(stmt,leftChild,n.leftChild,agNone);
            correlated:=correlated OR leftChild.correlated; //todo probably no need here...?
          end;
          //todo: check compatible with colunm.datatype found above - once=speed/early failure
        end;
      end;
    end;
    nhead:=nhead.NextNode;
  end;
  completedTrees:=True; //ensure we only complete the sub-trees once

  {Now add any table constraints}
  {First get the table name}
  table_name:=anodeRef.rel.relname;
  schema_name:=anodeRef.rel.schemaName;
  //todo prevent adding PK/UK/FK constraints if no column involved will be updated!
  if AddTableColumnConstraints(stmt,self,schema_name,anodeRef.rel.tableId,table_name,0{=table-level},ccUpdate)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Failed adding constraints for %d',[anodeRef.rel.tableId]),vDebugError);
    {$ENDIF}
    stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[table_name+' constraint']));
    result:=Fail;
    exit;
  end;

  if count=0 then
  begin
    //todo assertion because should always be caught earlier ??check?
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('No update-assignment nodes specified (%s)',[ord(nhead.ntype)]),vAssertion); //must be grammar error?
    {$ENDIF}
    exit; //abort
  end;

  updateCount:=count;

  {maybe now we should/could define an array of assignment column mappings to speed up the Next loop?
   otherwise we must FindCol each every time! = slooowww!}

  rowCount:=0;

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ENDIF}
end; {prePlan}

function TIterUpdate.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

function TIterUpdate.start:integer;
{Start the update process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;
  if result<>ok then exit; //aborted by child
end; {start}

function TIterUpdate.stop:integer;
{Stop the update process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
end; {stop}

function TIterUpdate.next(var noMore:boolean):integer;
{Get the next tuple from the project process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the copy method used) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok,
           -2 = update rejected =>too late
           else fail
}
const
  routine=':next';
  neInternal='sys/ne'; //temp column name
  ceInternal='sys/ce'; //temp column name
  idInternal='sys/id'; //temp column name
var
  nhead,n:TSyntaxNodePtr;
  i:ColRef;
  newRid:TRid;

  cRef:ColRef;

  //todo make IterUpdate global= speed
  defaultS:string;
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
    {Now do the actual update - the whole point of this extra layer!}
    {Note: self.iTuple (just loaded above) -> anodeRef.rel.fTuple = update target relation}

    {We may now deep-copy the feeder relation's iTuple into our updateable relation's iTuple
     This is because any cascade updates will need to refer to the old and new values.
     If we just shallow copy, the iTuple.update below calls Theapfile.updateRecord
     which overwrites the record in the buffer, i.e. the root source, with the updated values
     & we lose the pre-update values.
     todo! shallow-copy if we have no cascade updates - speed!
           - maybe check stmt.whereOldValues: if false then no update-action constraints
           - ok but need extra check for cascade update- speed

     We can shallow-copy the feeder relation's iTuple into our updateable relation's iTuple
     Both tuples are pointing to the same relation, so their definitions are identical
     - todo check speed ok...
     - also need to ensure new changes not seen by leftChild relation...
     -   maybe use another transId to hide them? or lock out via fact that we use 2 relations...?
     -Note: this might not be a noticeable problem until the where-clause starts to use non-sequential scans...
     -done: stmts cope with this.
    }

    //todo do we have to do this every loop? I guess we must...
    iTuple.clear(stmt); //speed - fastClear?
    for i:=0 to leftChild.iTuple.ColCount-1 do
    begin
      //if stmt.whereOldValues then
        iTuple.CopyColDataDeep(i,stmt,leftChild.iTuple,i,false) //keep old values for cascade
      //else
      //  iTuple.CopyColDataPtr(i,leftChild.iTuple,i); //shallow copy
    end;
    //if stmt.whereOldValues then
      iTuple.preInsert;

    {Define number of updates for new buffer}
    iTuple.DiffColCount:=UpdateCount;
    iTuple.clearUpdate; //todo check result

      //todo here: update column data
      {nil=default, ntnull=null, else scalar_exp}
      nhead:=anodeRef.exprNodeRef; //start of update-assignment chain
      while nhead<>nil do
      begin
        case nhead.nType of
          ntUpdateAssignment:
          begin //column name
            {Get the pre-found cref} //use directly - speed
            cRef:=nhead.cRef;

            n:=nhead.rightChild; //get expression
            if n=nil then
            begin //default
              //todo: handle functions, e.g. CURRENT_USER and NEXT_SEQUENCE
              {build default expression into temp string tuple}
              tempTuple.clear(stmt);
              tempTuple.SetColDef(0,1,idInternal,0,ctVarChar,0,0,'',True);
              defaultS:=iTuple.fColDef[cRef].defaultVal;
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('setting default value to %s',[defaultS]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              tempTuple.SetString(0,pchar(defaultS),iTuple.fColDef[cRef].defaultNull{=False});
              tempTuple.preInsert; //prepare buffer

              result:=iTuple.CopyColDataDeepGetUpdate(stmt,cref,tempTuple,0);  //Note: deep copy required here
              if result<>ok then
              begin
                success:=Fail; {=> rollback statement}
                stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                exit; //abort the operation
              end;

              {$IFDEF DEBUG_LOG}
              {$ENDIF}
            end
            else
            begin
              if n.nType=ntNull then
              begin
                result:=iTuple.UpdateNull(cref);
                if result<>ok then
                begin
                  success:=Fail; {=> rollback statement}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Failed updating column %d with NULL',[cref]),vAssertion);
                  {$ENDIF}
                  exit; //abort, no point continuing?
                end;
              end
              else
              begin
                {Ok, we have an expression to deal with...put the result in tempTuple}
                //todo These may be constant & so could be calculated at start?
                //note: this code should be similar/same as IterProject output code - check/combine!
                //18/06/00: wrong node - details don't get pulled this high during preplan: tempTuple.SetColDef(0,1,ceInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True);
                tempTuple.clear(stmt);
                tempTuple.SetColDef(0,1,ceInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
                {evaluate left expression}
                result:=EvalScalarExp(stmt,leftChild,n.leftChild,tempTuple,0,agNone,false);
                if result<>ok then exit; //aborted by child
                tempTuple.preInsert; //prepare buffer
                result:=iTuple.CopyColDataDeepGetUpdate(stmt,cref,tempTuple,0);  //Note: deep copy required here
                if result<>ok then
                begin
                  success:=Fail; {=> rollback statement}
                  stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                  exit; //abort the operation
                end;
              end;
            end;
          end; {ntUpdateAssignment}
        else
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Only update assignments allowed in update (%d)',[ord(nhead.ntype)]),vAssertion);
          {$ENDIF}
          //ignore it! ok?
        end; {case}
        nhead:=nhead.NextNode;
      end; {while}

    {Note: constraint checks were here: moved afer update for:
       cascade update of child needs new parent to be in place
       changed parent is safe from other users' links while cascading etc. is going on
       cascade update of self-referencing table avoids infinite loops
    }

    {Note: we can assume source.rid always=target.rid because they point to the same relation
     and rids don't move.
    }
    {$IFDEF DEBUG_LOG}
    {$ENDIF}
    result:=iTuple.update(stmt,leftChild.iTuple.RID);

    if result=-2{tooLate} then
    begin
      stmt.addError(seUpdateTooLate,format(seUpdateTooLateText,[nil]));
    end;

    //Note: the tuple.show below will re-read any blobs from disk again //switch off for speed

    if result=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%s <%d:%d>',[iTuple.Show(stmt),leftChild.iTuple.RID.pid,leftChild.iTuple.RID.sid]),vDebugHigh);
      {$ENDIF}
      inc(rowCount);
    end
    else
      success:=Fail;


    {If there are any row-time pre-delete constraint checks we can do, do them now
     to save time/garbage later, i.e. catch early (& avoid full table scan at end)}
    //avoid this call if we know there are none!
    //Note: for updated we check the parent end here & then the child end after...
    //i.e. constraint checks behave like delete + insert
    if (stmt.constraintList as Tconstraint).checkChain(stmt,self{iter context},ctRow,ceParent)<>ok then
    begin
      success:=Fail; {=> rollback statement} //todo * in future: cascade etc. & continue!
                                             //Note: constraint.check should do this (& return ok) so call at tran level will also work...
      dec(rowCount); //actually didn't!
      result:=-10;
      exit; //abort the operation
    end;

    {If there are any row-time constraint checks we can do, do them now
     to save time/garbage later, i.e. catch early (& avoid full table scan at end)}
    //avoid this call if we know there are none!
    //todo! check should add 'AND RID<>leftChild.iTuple.RID' if called from here to avoid FK-self/PK/UK fail on this-row
    //todo for now just force stmt level checking for updates! TODO FIX!*
           //else can update FK column & point to invalid parent!
           //or can update PK column & create duplcate entries!
           // also we need to skip PK/UK etc. if no key-part-columns have been updated! speed!
           //      -especially at tran level - but then we can't know?
           //       - unless we sensibly don't add the constraint during update.preplan if can't be needed!!!!!
    if (stmt.constraintList as Tconstraint).checkChain(stmt,self{iter context},ctRow,ceChild)<>ok then
    begin
      success:=Fail; {=> rollback statement}
      dec(rowCount); //actually didn't!
      result:=-10;
      exit; //abort the operation
    end;

  end;
end; {next}


end.

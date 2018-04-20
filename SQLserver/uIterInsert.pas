unit uIterInsert;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}

interface

uses uIterator, uIterStmt, uTuple, uTransaction, uStmt, uAlgebra, uSyntax, uGlobal{for MaxCol};

const
  MaxMap=MaxCol;          //maximum number of column mappings (must allow MaxCol)

type
  TIterInsert=class(TIterStmt)
    private
      tempTuple:TTuple;   //used to build default value
    public
      Map:array [0..MaxMap] of colRef;  //map target columns to source ordering to allow left-right tuple build up
                                        //Note: subscript=target cRef+1, value=source cRef+1 (i.e. [0]0 reserved for 'no mapping')

      constructor create(S:TStmt;relRef:TAlgebraNodePtr); override;
      destructor destroy; override;

      function status:string; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterInsert}

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uGlobalDef, uProcessor,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
     uConstraint, uOS {for getSystemUser (was Windows & so had to prefix maxSMALLINT with uGlobal)},
     uRelation{for sysGenerator lookup for DEFAULTs};

const
  where='uIterInsert';

constructor TIterInsert.create(S:TStmt;relRef:TAlgebraNodePtr);
const
  idInternal='sys/id'; //temp column name
begin
  inherited create(s,relRef);

  {Create temp tuple used for building default (string) values}
  tempTuple:=TTuple.create(nil);
  tempTuple.ColCount:=1;
  tempTuple.SetColDef(0,1,idInternal,0,ctVarChar,0,0,'',True);
end; {create}

destructor TIterInsert.destroy;
begin
  tempTuple.free;
  inherited destroy;
end; {destroy}

function TIterInsert.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterInsert %d',[rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterInsert.prePlan(outerRef:TIterator):integer;
{PrePlans the insert process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  nhead:TSyntaxNodePtr;
  cId:TColId;
  cRef:ColRef;

  cTuple:TTuple;

  {for privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  schema_name,table_name:string;
  i:ColRef;
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
  end
  else
    if anodeRef.nodeRef.rightChild.nType<>ntDefaultValues then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('missing leftChild',[nil]),vAssertion); 
      {$ENDIF}
      result:=fail;
    end;

  if result<>ok then exit; //aborted by child

  //maybe we should be extra tidy and stmt.clearConstraintList
  //      should be no need because stmtcommit/stmtrollback should do this i.e. as early as possible to release memory
  //      But could happen e.g. if last insert/update/delete added constraints but never reached the
  //      stmt.start call which increments the Wt (and so probably never reached stmt.commit/rollback)
  //      - then we would have garbage entries in this list with a Wt = next (i.e. this!)
  //      - if we called stmt.start here, that would clean for us
  //todo: at least assert list is empty!

  if anodeRef.nodeRef.rightChild.nType<>ntDefaultValues then
  begin
    {We need to skip permission checks (and so we skip constraint checks) during Insert when transaction.authId=_SYSTEM
     to avoid chicken & egg during createDB  //todo more clever if inserted into sysTableColumnPrivileges first to allow rest to be ok...
     //todo: replace with a less crude test (e.g. caller=createDB,
     //                  or tr=_SYSTEM AND anoderef.rel.schemaId=CATALOG_DEFINITION? =
     //                                    assumes 1 relation, not a join...but ok because Insert currently can only take 1 relation),
     //    since _SYSTEM shouldn't really be omnipotent & it's currently inconsistent because
     //    _SYSTEM can't delete/update or even select from any old table, but it can insert!
     //    ++ 07/01/01 actually it can now delete: need to drop failed table creation!
    }
    if not( (Ttransaction(stmt.owner).authID=1) and (anodeRef.rel.schemaId=sysCatalogDefinitionSchemaId) ) then //todo replace 1 with constant for _SYSTEM
    begin
      {Check we are privileged to insert all the columns,

       We can add any column specific constraints to the stmt constraint list while we're at it in case:
         1. a column list is explicitly given
         2. not all columns are in the list and one of the missing ones defaults=NULL + has constraint NOT NULL
       else we'd miss the ref. integtrity violation!
       So, we add all columnConstraints afterwards to make sure we don't miss any
       Note: in future we should not just default=NULL & error if default is required but missing
                   then we can assume the default complies with the checks and go back to the old method.

       also, the above should apply to privileges! i.e. implicit defaults must be on privileged columns!
          Note: if anodeRef.nodeRef.rightChild<>ntDefaultValues then DEFAULT VALUES => all iTuple columns...

      }
      nhead:=anodeRef.nodeRef.rightChild; //go to ntInsertValues
      if nhead.leftChild=nil then
      begin //no column list specified, we will be inserting all columns (from all those projected, in the left-right order)
        for cRef:=0 to leftChild.iTuple.ColCount-1 do
        begin
          {Now we ensure we have privilege to Insert this column
            - we leave it to the CheckTableColumnPrivilege routine to sensibly cache when we're checking for a whole table
            - this needs to be fast!
          }
          if CheckTableColumnPrivilege(stmt,0{we don't care who grantor is},Ttransaction(stmt.owner).authId,{todo: are we always checking our own privilege here?}
                                       False{we don't care about role/authId grantee},authId_level_match,
                                       {todo use anodeRef.rel.authid instead?if only inserting 1 relation,never a join}iTuple.fColDef[cRef].sourceAuthId{=source table owner},
                                       {todo use anodeRef.rel.tableid instead?if only inserting 1 relation,never a join}iTuple.fColDef[cRef].sourceTableId{=source table},
                                       iTuple.fColDef[cRef].id,table_level_match{we don't care how exact we match},
                                       ptInsert,False{we don't want grant-option search},grantabilityOption)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Failed checking privilege %s on %d:%d for %d',[PrivilegeString[ptInsert],iTuple.fColDef[cRef].sourceTableId,iTuple.fColDef[cRef].id,tran.AuthId]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[iTuple.fColDef[cRef].name+' privilege']));
            result:=Fail;
            exit;
          end;
          if grantabilityOption='' then //use constant for no-permission?
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to %s on %d:%d for %d',[PrivilegeString[ptInsert],iTuple.fColDef[cRef].sourceTableId,iTuple.fColDef[cRef].id,tran.AuthId]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to insert into '+iTuple.fColDef[cRef].name]));
            result:=Fail;
            exit;
          end;

          {Ok, we're privileged}
        end;
      end
      else
      begin //we will be inserting only those columns in list
        nhead:=nhead.leftChild;
        while nhead<>nil do
        begin
          //Note: we assume the list is column names only
          //todo - pre-define mapping at start - don't re-find every time!
          result:=iTuple.FindCol(nil,nhead.idval,'',nil,cTuple,cRef,cid);
          if cid=InvalidColId then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column reference (%s)',[nhead.idVal]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.idVal]));
            result:=Fail;
            exit; //abort, no point continuing
          end;
          //todo if any result<>0 then quit
          {Note: we don't use cTuple, we just used FindCol to find our own id,
           never to find a column source}
          if cTuple<>iTuple then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Column tuple found in %p and not in this input relation %p',[@cTuple,@iTuple]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
            //resultErr - or catch earlier with result=-2 = ambiguous
            result:=fail;
            exit;
          end;
          //todo if iTuple.fCol[i].dataType not coercable to leftChild.iTuple.fCol[i].datatype then error
          {We store the column reference for use at evaluation time - speed}
          //todo use the node's cTuple/cRef directly so we don't need local vars & this copying - make sure FindCol only sets if found
          // - TODO ASSERT cTuple<>nil here!
          if nhead.cTuple=nil then
          begin
            nhead.cTuple:=cTuple;
            nhead.cRef:=cRef;
          end; //else already set //note: we still go ahead & update the type/size again...shouldn't matter...
          {Now we ensure we have privilege to Insert this column
            - we leave it to the CheckTableColumnPrivilege routine to sensibly cache when we're checking for a whole table
            - this needs to be fast!
          }
          if CheckTableColumnPrivilege(stmt,0{we don't care who grantor is},Ttransaction(stmt.owner).authId,{todo: are we always checking our own privilege here?}
                                       False{we don't care about role/authId grantee},authId_level_match,
                                       cTuple.fColDef[cRef].sourceAuthId{=source table owner},
                                       cTuple.fColDef[cRef].sourceTableId{=source table},
                                       cid,table_level_match{we don't care how exact we match},
                                       ptInsert,False{we don't want grant-option search},grantabilityOption)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Failed checking privilege %s on %d:%d for %d',[PrivilegeString[ptInsert],cTuple.fColDef[cRef].sourceTableId,cid,tran.AuthId]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[nhead.idVal+' privilege']));
            result:=Fail;
            exit;
          end;
          if grantabilityOption='' then //use constant for no-permission?
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Not privileged to %s on %d:%d for %d',[PrivilegeString[ptInsert],cTuple.fColDef[cRef].sourceTableId,cid,tran.AuthId]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to insert '+nhead.idVal]));
            result:=Fail;
            exit;
          end;

          {Ok, we're privileged}
          nhead:=nhead.nextNode;
        end;
      end;

      {Now (temporarily here) we can add constraint for all columns (even those that aren't mentioned)}
      for cRef:=0 to iTuple.ColCount-1 do
      begin
        {Now add any column constraints}
        {First get the table name}
          table_name:=anodeRef.rel.relname;
          schema_name:=anodeRef.rel.schemaName;
        if AddTableColumnConstraints(stmt,self,schema_name,iTuple.fColDef[cRef].sourceTableId,table_name,iTuple.fColDef[cRef].id,ccInsert)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Failed adding constraints for %d:%d',[iTuple.fColDef[cRef].sourceTableId,iTuple.fColDef[cRef].id]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[iTuple.fColDef[cRef].name+' constraint']));
          result:=Fail;
          exit;
        end;
      end;

      {Now add any table constraints}
      {First get the table name}
      table_name:=anodeRef.rel.relname;
      schema_name:=anodeRef.rel.schemaName;
      if AddTableColumnConstraints(stmt,self,schema_name,anodeRef.rel.tableId,table_name,0{=table-level},ccInsert)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Failed adding constraints for %d',[anodeRef.rel.tableId]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[table_name+' constraint']));
        result:=Fail;
        exit;
      end;

    end
    else //internal system catalog insert - no permission checks required
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Internal insertion - skipping permission checks and constraints',[nil]),vDebugHigh); //debug
      {$ELSE}
      ;
      {$ENDIF}
      //Note: following is block copied from above - keep in sync/share

      nhead:=anodeRef.nodeRef.rightChild; //go to ntInsertValues
      if nhead.leftChild<>nil then
      begin //we will be inserting only those columns in list
        nhead:=nhead.leftChild;
        while nhead<>nil do
        begin
          //Note: we assume the list is column names only
          result:=iTuple.FindCol(nil,nhead.idval,'',nil,cTuple,cRef,cid);
          if cid=InvalidColId then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column reference (%s)',[nhead.idVal]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.idVal]));
            result:=Fail;
            exit; //abort, no point continuing
          end;
          //todo if any result<>0 then quit
          {Note: we don't use cTuple, we just used FindCol to find our own id,
           never to find a column source}
          if cTuple<>iTuple then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Column tuple found in %p and not in this input relation %p',[@cTuple,@iTuple]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
            //resultErr - or catch earlier with result=-2 = ambiguous
            result:=fail;
            exit;
          end;
          {We store the column reference for use at evaluation time - speed}
          //todo use the node's cTuple/cRef directly so we don't need local vars & this copying - make sure FindCol only sets if found
          // - TODO ASSERT cTuple<>nil here!
          if nhead.cTuple=nil then
          begin
            nhead.cTuple:=cTuple;
            nhead.cRef:=cRef;
          end; //else already set //note: we still go ahead & update the type/size again...shouldn't matter...
          nhead:=nhead.nextNode;
        end;
      end;
    end;
  end
  else
  begin //default values
    //todo check as above but for iTuple, i.e. ALL columns
    //we could probably assume constraints are satisfied by defaults, i.e. checked at creation time?
    //but we still check privilege for whole table.
    {Now we ensure we have privilege to Insert into this table
      - this needs to be fast!
    }

    {Now (temporarily here, until we can guarantee that default are always ok) we can add constraint for all columns (since none are mentioned)}
    for cRef:=0 to iTuple.ColCount-1 do
    begin
      {Now add any column constraints}
      {First get the table name}
        table_name:=anodeRef.rel.relname;
        schema_name:=anodeRef.rel.schemaName;
      if AddTableColumnConstraints(stmt,self,schema_name,iTuple.fColDef[cRef].sourceTableId,table_name,iTuple.fColDef[cRef].id,ccInsert)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Failed adding constraints for %d:%d',[iTuple.fColDef[cRef].sourceTableId,iTuple.fColDef[cRef].id]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[iTuple.fColDef[cRef].name+' constraint']));
        result:=Fail;
        exit;
      end;
    end;

    if not( (Ttransaction(stmt.owner).authID=1) and (anodeRef.rel.schemaId=sysCatalogDefinitionSchemaId) ) then //todo replace 1 with constant for _SYSTEM
    begin
      if CheckTableColumnPrivilege(stmt,0{we don't care who grantor is},Ttransaction(stmt.owner).authId,{todo: are we always checking our own privilege here?}
                                   False{we don't care about role/authId grantee},authId_level_match,
                                   anodeRef.rel.AuthId{=source table owner},
                                   anodeRef.rel.TableId{=source table},
                                   0{=table level check},table_level_match{we don't care how exact we match: can only be table-level here},
                                   ptInsert,False{we don't want grant-option search},grantabilityOption)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Failed checking privilege %s on %d for %d',[PrivilegeString[ptInsert],anodeRef.rel.TableId,tran.AuthId]),vDebugError);
        {$ENDIF}
        stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[anodeRef.rel.relname+' privilege']));
        result:=Fail;
        exit;
      end;
      if grantabilityOption='' then //use constant for no-permission?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Not privileged to %s on %d for %d',[PrivilegeString[ptInsert],anodeRef.rel.TableId,tran.AuthId]),vDebugLow);
        {$ENDIF}
        stmt.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to insert '+anodeRef.rel.relname]));
        result:=Fail;
        exit;
      end;
    end;
    //else internal=no check
  end;

  {Initialise column mappings (needed so we can build tuple in left-right column order)}
  {Note: we skip [0] because we use 0 to mean 'no mapping' for specified column lists}
  for cRef:=1 to iTuple.ColCount do
    Map[cRef]:=0;

  if anodeRef.nodeRef.rightChild.nType<>ntDefaultValues then
  begin
    nhead:=anodeRef.nodeRef.rightChild; //go to ntInsertValues
    if nhead.leftChild=nil then
    begin //no column list specified, so map all those projected in that order
      {Give error if trying to insert more than can take (todo: error if too few? will safely default to null.. check spec.)}
      if leftChild.iTuple.ColCount>iTuple.colCount then
      begin
        stmt.addError(seSyntaxNotDegreeCompatible,seSyntaxNotDegreeCompatibleText);
        result:=Fail;
        exit;
      end;

      //todo: give a mismatch error if source/target list valencies don't match (currently safe though: ignore extra/default too few)
      for i:=0 to leftChild.iTuple.ColCount-1 do
        Map[i+1]:=i+1;
    end
    else
    begin //map only those columns in list
      i:=0;
      nhead:=nhead.leftChild;
      while nhead<>nil do
      begin
        Map[nhead.cRef+1]:=i+1;

        inc(i); //processed a single column
        nhead:=nhead.nextNode;
      end;

      {Give error if list count doesn't match insert values count (todo: always an error? check spec.)}
      if leftChild.iTuple.ColCount<>i then
      begin
        stmt.addError(seSyntaxNotDegreeCompatible,seSyntaxNotDegreeCompatibleText);
        result:=Fail;
        exit;
      end;
    end;
  end;
  //else leave all iTuple columns set to no mapping -> default

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ENDIF}
end; {prePlan}

function TIterInsert.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

function TIterInsert.start:integer;
{Start the insert process
 RETURNS:  ok, else fail
}
const routine=':start';
begin
  result:=inherited start;

  if not assigned(leftChild) then
    if anodeRef.nodeRef.rightChild.nType<>ntDefaultValues then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('missing leftChild',[nil]),vAssertion);
      {$ENDIF}
      result:=fail;
    end;

  if result<>ok then exit; //aborted by child
end; {start}

function TIterInsert.stop:integer;
{Stop the insert process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
end; {stop}

function TIterInsert.next(var noMore:boolean):integer;
{Get the next tuple from the project process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the copy method used) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok,
           -2 = unknown catalog (sequence owner)
           -3 = unknown schema (sequence owner)
           else fail
               (-10 = constraint violation)

 Note:
   a failure sets success=Fail
}
const routine=':next';
var
  nhead:TSyntaxNodePtr;
  i:ColRef;
  newRid:TRid;

  defaultS:string;
  dayCarry:shortint;

  //for eval
  s,s2:string;
  tempInt,tempInt2:integer;
  catalog_name,schema_name:string;
  catalog_id:TcatalogId;
  schema_id:TschemaId;
  auth_id:TauthId;
  vnull:boolean;
  sysGeneratorR:TObject; //Trelation
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

  {If this is a single-row DEFAULT VALUES, stop at the second iteration}
  if not assigned(leftChild) and (anodeRef.nodeRef.rightChild.nType=ntDefaultValues) and (rowCount>0) then
  begin
    noMore:=True;
  end;

  if result<>ok then
  begin
    success:=Fail;
    exit; //abort;
  end;
  if not noMore then
  begin //copy leftchild.iTuple to this.iTuple (point?)
    {Note: iTuple points directly at the insert relation's tuple}
    iTuple.clear(stmt); //todo speed - fastClear?

    {Insert column data (including any defaults) in left-right (safe) order}
    //todo: prevent need for this array scan (expensive?) by using linked lists (& one for default columns- would need to pre-find in prePlan)
    for i:=0 to iTuple.ColCount-1 do
    begin
      if (Map[i+1]<>0) and (leftChild.iTuple.fColDef[Map[i+1]-1].datatype<>ctUnknown) then
      begin //mapped (and not onto DEFAULT)
        result:=iTuple.CopyColDataDeepGetSet(stmt,i,leftChild.iTuple,Map[i+1]-1);  //Note: deep copy required here
        if result<>ok then
        begin
          success:=Fail; {=> rollback statement}
          stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
          exit; //abort the operation
        end;
      end
      else
      begin //not-mapped (or mapped onto DEFAULT), maybe has (must have!) a default value...
        {Check/set any default} //Note: this code is copied in TvariableSet.SetVarDef
        if (iTuple.fColDef[i].defaultVal<>'') or not(iTuple.fColDef[i].defaultNull) then
        begin
          {build default expression into temp string tuple}
          tempTuple.clear(stmt);
          defaultS:=iTuple.fColDef[i].defaultVal;
          {Interpret/evaluate default value
           (todo use uEvalCondExpr (see NEXT_SEQUENCE below!)! & differentiate between CURRENT_TIME and 'CURRENT_TIME' !)
          }
          {Note: following code snippets copied from uEvalCondExpr: keep in sync!
           + do same to iterUpdate for set default}
          if uppercase(defaultS)='CURRENT_USER' then defaultS:=tran.authName;
          if uppercase(defaultS)='SESSION_USER' then defaultS:=tran.authName;
          if uppercase(defaultS)='SYSTEM_USER' then
          begin
            defaultS:=tran.authName;
            getSystemUser(stmt,defaultS);
          end;
          //todo: use scale from target column!
          if uppercase(defaultS)='CURRENT_CATALOG' then defaultS:=tran.catalogName;
          if uppercase(defaultS)='CURRENT_SCHEMA' then defaultS:=tran.schemaName;
          if uppercase(defaultS)='CURRENT_DATE' then defaultS:=sqlDateToStr(Ttransaction(stmt.owner).currentDate);
          if uppercase(defaultS)='CURRENT_TIME' then defaultS:=sqlTimeToStr(TIMEZONE_ZERO,Ttransaction(stmt.owner).currentTime,0,dayCarry);
          if uppercase(defaultS)='CURRENT_TIMESTAMP' then defaultS:=sqlTimestampToStr(TIMEZONE_ZERO,Ttransaction(stmt.owner).currentTimestamp,0);

          if (copy(uppercase(defaultS),1,length('NEXT_SEQUENCE('))='NEXT_SEQUENCE(') then
          begin
            //copied from uEvalCondExpr, but not pre-parsed: todo use common routine(s)
            s:=copy(defaultS,length('NEXT_SEQUENCE(')+1,length(defaultS));
            system.delete(s,length(s),1); //remove )

            schema_id:=anodeRef.rel.schemaId; //default to table schema //note: not like view definitions... orthogonality!
            tempInt:=pos('.',s);
            if tempInt<>0 then
            begin //override schema via text lookup
              s2:=copy(s,1,tempInt-1); //schema prefix //note: catalog prefix = not found! todo document/fix
              s:=copy(s,tempInt+1,length(s)); //sequence name
              result:=getOwnerDetails(stmt,nil,s2,anodeRef.rel.schemaName,catalog_id,catalog_name,schema_id,schema_name,auth_id);
              if result<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Failed to find sequence owner',[nil]),vDebugError);
                {$ENDIF}
                case result of
                  -2: stmt.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
                  -3: stmt.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[s2]));
                end; {case}
                success:=Fail; {=> rollback statement}
                exit; //abort
              end;
            end;

            //todo lookup the generator once during pre-evaluation & then here = faster
            tempInt2:=0; //lookup by name
            result:=tran.db.getGeneratorNext(stmt,schema_id,s,tempInt2{genId},tempInt);
            if result<>ok then
            begin
              success:=Fail; {=> rollback statement}
              if tempInt2=0 then //=not found
                stmt.addError(seSyntaxUnknownSequence,format(seSyntaxUnknownSequenceText,[s]));
              exit; //abort
            end;

            {Store this as the current value for this sequence for this transaction so it can be re-used/referenced}
            tran.SetLastGeneratedValue(tempInt2,tempInt);

            defaultS:=intToStr(tempInt);
          end;
          //todo: better/simpler to disallow this here?
          if (copy(uppercase(defaultS),1,length('LATEST_SEQUENCE('))='LATEST_SEQUENCE(') then
          begin
            //copied from uEvalCondExpr, but not pre-parsed: todo use common routine(s)
            s:=copy(defaultS,length('LATEST_SEQUENCE(')+1,length(defaultS));
            system.delete(s,length(s),1); //remove )

            schema_id:=anodeRef.rel.schemaId; //default to table schema //note: not like view definitions... orthogonality!
            tempInt:=pos('.',s);
            if tempInt<>0 then
            begin //override schema via text lookup
              s2:=copy(s,1,tempInt-1); //schema prefix //note: catalog prefix = not found! todo document/fix
              s:=copy(s,tempInt+1,length(s)); //sequence name
              result:=getOwnerDetails(stmt,nil,s2,anodeRef.rel.schemaName,catalog_id,catalog_name,schema_id,schema_name,auth_id);
              if result<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Failed to find sequence owner',[nil]),vDebugError);
                {$ENDIF}
                case result of
                  -2: stmt.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
                  -3: stmt.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,[s2]));
                end; {case}
                success:=Fail; {=> rollback statement}
                exit; //abort
              end;
            end;

            //todo lookup the generator once during pre-evaluation & then here = faster
            (* code copied from TDB.getGeneratorNext
             maybe we need a Tgenerator class? since we find(~open), create(~createNew) etc.
             or at least put this lookup into a routine: will be needed also by grant etc.
            *)
            {find generatorID for s}
            tempInt2:=0; //not found
            if tran.db.catalogRelationStart(stmt,sysGenerator,sysGeneratorR)=ok then
            begin
              try
                if tran.db.findFirstCatalogEntryByString(stmt,sysGeneratorR,ord(sg_Generator_name),s)=ok then
                  try
                  repeat
                  {Found another matching generator for this name}
                  with (sysGeneratorR as TRelation) do
                  begin
                    fTuple.GetInteger(ord(sg_Schema_id),tempInt,vnull);
                    if tempInt=schema_id then
                    begin
                      fTuple.GetInteger(ord(sg_Generator_Id),tempInt2,vnull);
                      //already got generatorName
                      {$IFDEF DEBUGDETAIL}
                      {$IFDEF DEBUG_LOG}
                      log.add(stmt.who,where+routine,format('Found generator relation %s in %s (with generator-id=%d)',[s,sysGenerator_table,tempInt2]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                      result:=ok;
                    end;
                    //else not for our schema - skip & continue looking
                  end; {with}
                  until (tempInt2<>0) or (tran.db.findNextCatalogEntryByString(stmt,sysGeneratorR,ord(sg_Generator_name),s)<>ok);
                        //todo stop once we've found a generator_id with our schema_Id, or there are no more matching this name
                  finally
                    if tran.db.findDoneCatalogEntry(stmt,sysGeneratorR)<>ok then
                      {$IFDEF DEBUG_LOG}
                      log.add(stmt.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysGenerator)]),vError);
                      {$ELSE}
                      ;
                      {$ENDIF}
                  end; {try}
                //else generator not found
              finally
                if tran.db.catalogRelationStop(stmt,sysGenerator,sysGeneratorR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysGenerator)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}
            end
            else
            begin  //couldn't get access to sysGenerator
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysGenerator),s]),vDebugError);
              {$ENDIF}
              success:=Fail; {=> rollback statement}
              result:=fail;
              exit; //abort
            end;

            if tempInt2<>0 then
            begin //found
              {Store the latest value for this sequence for this transaction (null if none so far)}
              if tran.GetLastGeneratedValue(tempInt2,tempInt)<>ok then
                defaultS:='' //=> null at the moment: when this changes we'll need to pass null to tempTuple below
              else
                defaultS:=intToStr(tempInt);
              if result<>ok then exit;
            end;
          end;

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('setting default value to %s',[defaultS]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          tempTuple.SetString(0,pchar(defaultS),iTuple.fColDef[i].defaultNull{=False});
          tempTuple.preInsert; //prepare buffer

          {Convert (cast) & return result}
          result:=iTuple.CopyColDataDeepGetSet(stmt,i,tempTuple,0);
          if result<>ok then
          begin //should never happen
            success:=Fail; {=> rollback statement}
            stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
            exit; //abort the operation
          end;
        end
        else //default=null (or not specified)
        //need to explicitly set?
        //- actually DATE p112 sounds like it is an error if no default!?
        //  if so: ntDefaultValues cannot rely on us auto-nulling here (i.e. colDef would need defaultSet? flag)
        begin
          result:=iTuple.SetNull(i);
          if result<>ok then
          begin //should never happen
            success:=Fail; {=> rollback statement}
            stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
            exit; //abort the operation
          end;
        end;
      end;
    end;

    if result=ok then
    begin
      //todo: fill in any defaults (should be tuple level call - so do in preInsert?)
      //      must be done before constraint check below...

      {Ok, store the output tuple in the tuple (memory) buffer}
      iTuple.preInsert;

      {If there are any row-time constraint checks we can do, do them now
       to save time/garbage later, i.e. catch early (& avoid full table scan at end)}
      //todo: avoid PK/unique checks if default next_sequence was used on column/key-part
      if (stmt.constraintList as Tconstraint).checkChain(stmt,self{iter context},ctRow,ceChild)<>ok then
      begin
        success:=Fail; {=> rollback statement}
        result:=-10;
        exit; //abort the operation
      end;

      {Now do the actual insert - the whole point of this extra layer!}
      {Note: self.iTuple (just loaded above) -> anodeRef.rel.fTuple}
      result:=iTuple.insert(stmt,newRid); //do the insert

      //Note: the tuple.show below will re-read any blobs from disk again //switch off for speed

      if result=ok then
      begin
{$IFDEF DEBUG_LOG}
{$ELSE}
;
{$ENDIF}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugHigh);
        {$ENDIF}
        inc(rowCount);
      end
      else
        success:=Fail;

      //*TODO* ensure all iter*.next failures set success:=fail !!!
      //            currently only detected by some .stop routines, but may expand in future
      //            and sometimes caller will use as detection

    end;
  end;
end; {next}


end.

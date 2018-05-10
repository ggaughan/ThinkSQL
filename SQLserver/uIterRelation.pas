unit uIterRelation;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3} //filter details

//{$DEFINE DEBUGDETAIL5} //debug view problem
//{$DEFINE DEBUGDETAIL6}  //filter match results summary
{$DEFINE DEBUGDETAIL7}    //final filter usage log

interface

uses uIterator, uRelation, uTuple, uTransaction, uStmt, uAlgebra, uSyntax, uGlobal;

type
  TIterRelation=class(TIterator)
    private
      unusedTuple:TTuple; //used to save/restore our tuple for destruction
      rel:TRelation;      //todo use algebraNode's rel instead! (?)
      pulledSARGlist:TSyntaxNodePtr; //pulled SARGs, some of which may be moved into the filter list if findScanStart can be used
                                     //Note: if any remain here & don't go into the filter, then they will be moved to a parent/manufactured iterSelect -todo!
                                     //      (or maybe we could evaluate them in this iterRelation.next?}
      filter:TSyntaxNodePtr; //do we use a filter expression & so findScanStart rather than default=nil=>ScanStart
                             // (the relation's fTupleKey will be pre-loaded with this filter by the optimise routine)

      findexName:string; //just used for description
    public
      constructor create(S:TStmt;relRef:TAlgebraNodePtr);
      destructor destroy; override;
      function description:string; override;
      function status:string; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop

      function JustReferencesSelf(snode:TSyntaxNodePtr):integer;
      function checkFilterPart(snode:TSyntaxNodePtr;var candidateCRef:ColRef; var candidateScalarNode:TSyntaxNodePtr):integer;
      function getTupleEqualKeyData(equalFilter:TSyntaxNodePtr;tupleData:TTuple):integer;
  end; {TIterRelation}

implementation

uses
{$IFDEF Debug_Log}
uLog,
{$ENDIF}
sysUtils, uEvalCondExpr, uMarshalGlobal;

const
  where='uIterRelation';

constructor TIterRelation.create(S:TStmt;relRef:TAlgebraNodePtr);
begin
  inherited create(s);
  anodeRef:=relRef;
  rel:=anodeRef.rel; //Note: we assume r has been created (& opened) by caller
          // so we do not own it (& its tuple has been created elsewhere)
  unusedTuple:=iTuple; //save our tuple for final destruction
  {Define (repoint) our ituple as mapping directly to the relation's tuple}
  iTuple:=rel.fTuple;
  {Default=no local SARGs}
  pulledSARGlist:=nil;
  {Default=full scan}
  filter:=nil;
end; {create}

destructor TIterRelation.destroy;
begin
  iTuple:=unusedTuple; //restore our tuple for final destruction
  inherited destroy;
end; {destroy}

function TIterRelation.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  if findexName<>'' then result:=result+' (using index '+findexName+')';
end; {description}

function TIterRelation.status:string;
begin
  {$IFDEF DEBUG_LOG}
  if rel<>nil then
    result:='TIterRelation ('+rel.schemaName+'.'+rel.relname+')'
  else
    result:='TIterRelation (<nil>=error)';
  {$ELSE}
  result:='';
  {$ENDIF}    
end; {status}

function TIterRelation.prePlan(outerRef:TIterator):integer;
{PrePlans the relation process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
var
  nhead:TSyntaxNodePtr;
  i:colRef;
begin
  result:=inherited prePlan(outerRef);
{$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
{$ENDIF}

  if anodeRef.exprNodeRef<>nil then
  begin
    {We have a list of column aliases (that were set at the table_ref level) so apply them now
     Note: these may well override any previous column names/aliases}
    nhead:=anodeRef.exprNodeRef;
    for i:=0 to iTuple.ColCount-1 do
    begin
      if nhead<>nil then
      begin
        iTuple.fColDef[i].name:=nhead.idVal; //column alias
        nhead:=nhead.nextNode;
      end
      else
      begin
        //shouldn't this have been caught before now!?
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Not enough column aliases (at %d out of %d)',[i+1,iTuple.ColCount]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        //todo for now we leave the original column names - i.e. half aliased/half original = bad! todo FIX! by failing!- check what happens to caller...
        stmt.addError(seSyntaxNotEnoughViewColumns,format(seSyntaxNotEnoughViewColumnsText,[nil]));
        result:=Fail;
        exit; //abort, no point continuing?
      end;
    end;
  end;
end; {prePlan}

function TIterRelation.JustReferencesSelf(snode:TSyntaxNodePtr):integer;
{Check if this sub-tree just references ourself
 (If it does, the optimise routine can choose to pull it down to this level
  else it cannot)

 IN:       snode            the sub-tree root
 RETURNS:  +1=just references ourself (or references no relation, e.g. 1=1)
           +2=child references constraint override (DUMMY) so parent can assume ok to filter
              (this is until we can optimise sub-selects better)
           else ok (or fail = error)

 Note:
   the routine is recursive

   treats references to DUMMY as self
     i.e. constraint checker 'knows' that this (& its comparison for FKs) will be constant & so SARGable
     //todo: ensure user cannot use DUMMY! i.e. prefix with _

 todo: if references no relation, maybe we shouldn't pull down
       although it would/should still help eliminate rows before a join
       (unless it was something silly like 1=1,
        although a silly thing like 1=0 would be the most helpful!)
}
const routine=':justReferencesSelf';
var r1:integer;
begin
  result:=+1; //assume that we purely self-reference, until proven otherwise

  if snode.nType=ntSelect then   //is this the only stopped? -maybe group-by??? or maybe where anode=antProject etc.?
  begin
    {We stop here for 2 reasons:
       1. we aren't clever enough (yet?) to work out if sub-query references
          relate to other versions of our table_id or are correlated to our table_id
          - we would need to look at the alias info etc. to work this out
          - even if it purely (correlatedly) references us - can we still push down???
            -I think we should be able to but this will affect the pre-planned attached sub-plans etc.?
            - also columns references will/may be for outer layers and will need to be re-found?
               (maybe we should always re-find anyway once pushed-down? - we do for join right pushes...)
       2. the sub-tree's of sub-queries aren't simply further children - we'd need to
          side-step to the where clause to continue descending...

       Note: this also needs to refer to any sub-iterSelects already built into the iterator tree...
             e.g. after a view expansion: so not just Where sub-selects...
    }
    {$IFDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%p  type=%d => sub-query (so ignore)',[snode,ord(snode.nType)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    result:=ok; //i.e. return false
    exit; //no point continuing (e.g. to look at any children)
  end;

  {We already stored column references during CompleteScalarExp, so we use them rather than re-FindCol}
  if snode.cTuple<>nil then
  begin
    //maybe we could skip 2 tests by checking the snode.nType first... - speed
    //- although the 1st test (if ctuple<>nil) should remove most...

      //new: 03/03/02 - added to avoid FK constraint scanning
      if snode.nType=ntColumnRef then //possibly a left-hand column & if referencing DUMMY = always allow
        if (snode.leftChild<>nil) and
           (snode.leftChild.rightChild.idVal='DUMMY') then //this is a special override one, so always allow...
      begin //we have a constraint overridden 'DUMMY' reference, so treat this whole subtree as 'referencing self'
        {$IFDEF DEBUGDETAIL3}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('columnRef = DUMMY so treat as self-reference/filter candidate ',[nil]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        result:=+2; //i.e. inform parent call to return +1, despite the fact that the other child = fail to reference self (i.e. FK table)
        exit; //done: no point continuing (e.g. to look at any children)
      end;

      if (snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId=InvalidTableId then
      begin //i.e. not copied from an original relation column - must be made up and in a projection => somewhere above
        {$IFDEF DEBUGDETAIL3}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('%p  %s %d = invalid (assume from higher projection) ',[snode,(snode.cTuple as TTuple).fColDef[snode.cRef].name,(snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        result:=ok; //i.e. return false
        exit; //no point continuing (e.g. to look at any children)
      end;
      if (snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId<>(self.rel).tableId then
      begin //i.e. the the base relation this column came from was not ours
        {$IFDEF DEBUGDETAIL3}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('%p  %s %d <> self(%d) ',[snode,(snode.cTuple as TTuple).fColDef[snode.cRef].name,(snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId,(self.rel).tableId]),vDebugLow);
        {$ENDIF}
        {$ENDIF}

        //but check first that the constraint checker is not over-ruling this test...
        if snode.nType=ntColumnRef then //possibly a left-hand column & if referencing DUMMY = always allow
          if (snode.leftChild=nil) or //we have no specified range (and this is not a self-table reference) //assumes boolean short-circuit
             (snode.leftChild.rightChild.idVal<>'DUMMY') then //...or we do but it's not a special override one, so disallow...
	     begin //this source range is not DUMMY //todo make DUMMY a constant!
		  //{$IFDEF DEBUGDETAIL3}
		  {$IFDEF DEBUG_LOG}
		  //log.add(stmt.who,where+routine,format('%p  %s %d <> self(%d) ',[snode,(snode.cTuple as TTuple).fColDef[snode.cRef].name,(snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId,(self.rel).tableId]),vDebugLow);
		  {$ENDIF}
		  //{$ENDIF}
		  result:=ok; //i.e. return false
		  exit; //no point continuing (e.g. to look at any children)
	     end;
      end;
{$IFDEF DEBUG_LOG}
{$ELSE}
;
{$ENDIF}

    //so: this is a self-reference (or constraint-overridden) so continue looking to prove otherwise
    // - maybe we can double-check (to avoid ambiguity with sub-queries) by
    //         checking if col.dataPtr points here (via intermediate nodes (unless group-by in middle))...
    //         - for now we'll crudely not pass down SARGS past a iterProject etc.

    //todo: should at least check by range, not just table_id... although we can handle such garbage further down

    {$IFDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%p  %s %d = self(%d) ',[snode,(snode.cTuple as TTuple).fColDef[snode.cRef].name,(snode.cTuple as TTuple).fColDef[snode.cRef].sourceTableId,(self.rel).tableId]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end;
  //else ignore, since we can guarantee that all cTuples will have been set for column references

  {Now recurse down into any children}
  if snode.leftChild<>nil then
  begin
    result:=JustReferencesSelf(snode.leftChild);
    if result=+2 then
    begin
      //result:=+1;
      exit; //ignore other children, constraint override says we can treat this as a filter
    end;
    //continue in case constraint override in next child... if result=ok then exit; //no point continuing
  end;
  r1:=ok; //0
  if snode.rightChild<>nil then
  begin
    r1:=JustReferencesSelf(snode.rightChild);
    if r1=+2 then
    begin
      //result:=+1;
      result:=r1; //use this (override whatever left-child result was)
      exit; //ignore other children, constraint override says we can treat this as a filter
    end;
    //continue in case constraint override in next child... if result=ok then exit; //no point continuing
    if result<>ok then result:=r1; //i.e. use right-child as result, unless left-child=not-self(0) then it overrides right-child result
                                   //- the intention is: 0 prevails, +2 overrides & wins, +1 is default/success                                        
  end;
end; {JustReferencesSelf}

function TIterRelation.checkFilterPart(snode:TSyntaxNodePtr;var candidateCRef:ColRef; var candidateScalarNode:TSyntaxNodePtr):integer;
{Check if this sub-tree is a candidate part of a potential filter expression
 (If it is, the optimise routine can choose to use it for filtered scanning,
  else it cannot)

 IN:       snode                the sub-tree root
 OUT:      candidateCRef        the column-ref of this iterator's iTuple for the filter expression
                                (this will be evaluated and set in the getTupleEqualKeyData routine for valid filter expressions)
                                 - only use if result=+1
           candidateScalarNode  the sub-expression to be evaluated
                                Note: this is returned for 2 reasons:
                                      1 - it's the only bit we need after this routine has checked this sub-node is a candidate
                                      2 - we need to chain the parts together without messing with the existing chain header nodes
                                          because the original SARG owner needs these to remain intact to unlink/garbage collect etc.
                                          (so we leave it to caller to link using another way - currently creates a new chain of ntEqualFilter nodes)
 RETURNS:  +1=is a candidate expression part (and cRef has been returned)
           else ok (or fail = error)

 Assumes:
   we have passed the JustReferencesSelf test
   - so we can assume that if we have col=col then:
         they both are from our relation
     or: the left relation has an alias (rangeName) of DUMMY //ensure user cannot do this! & note that we only check left one - keep in sync. with constraint check logic
         (otherwise could be a self-join etc. = both try to drive via index = crash!)
     or: col=outerRef.col forced down from join
     or: outerRef.col=col forced down from join

     - used by PK row constraint checking...
     - note: will default to use left col as filter (even if right has index...)
       so we don't need to check if left is col-ref when looking for Literal=colref
       (since we use DUMMY.col=t.col, should be fine)

   the snode has be pre-planned

 Note:
   the routine is recursive  //will it be!?

   a candidate filter expression part is one that has a simple column equality test against
   a non-column value (or possibly one of the col=col options above)
}
const routine=':checkFilterPart';
var
  cTuple:TTuple;
  cRange:string; //todo remove
  cId:TColId;
  cRef:ColRef;
begin
  result:=ok; //assume no match, i.e. that we are not a pure candidate filter expression part, until proven otherwise

  candidateCRef:=MaxCol+1; //cause crash if caller uses - todo remove/make safe!
  candidateScalarNode:=nil;

  //todo tidy & improve!
  // i.e. generalise to allow (constant!?) sub-expressions etc. (but still exactly one column ref per side)
  //for now we do a simplistic test: are we                   ntEqual
  //                                         ntRowConstructor         ntRowConstructor
  //       ntNumericExp|ntCharacterExp //todo etc. e.g. ntBitExp        ntNumericExp|ntCharacterExp //todo etc. e.g. ntBitExp
  //         ntColumnRef                                                ntNumber|ntString|ntParam|ntNull //todo etc.?
  //                                                                    (or ntColumnRef to speed PK row self checks  -assuming left column->DUMMY
  //                                                                     or ntColumnRef for equi-joins force down from join)

  //note: these tests assume boolean short-circuiting...
  //todo use EvalCondPredicate instead...
  //     and at runtime, if nextChild<>nil then combine...
  if snode.nType in [ntEqual,ntEqualOrNull] then
    if (snode.leftChild<>nil) and (snode.leftChild.nType=ntRowConstructor) and (snode.leftChild.nextNode=nil) then //L=single element
      if (snode.rightChild<>nil) and (snode.rightChild.nType=ntRowConstructor) and (snode.rightChild.nextNode=nil) then //R=single element
        if (snode.leftChild.leftChild<>nil) and (snode.leftChild.leftChild.nType in [ntNumericExp,ntCharacterExp]) then //L=exp
          if (snode.rightChild.leftChild<>nil) and (snode.rightChild.leftChild.nType in [ntNumericExp,ntCharacterExp]) then //R=exp
          begin
            if ( (snode.leftChild.leftChild.leftChild<>nil) and (snode.leftChild.leftChild.leftChild.nType=ntColumnRef) ) AND //L=colref
               ( (snode.rightChild.leftChild.leftChild<>nil) and (snode.rightChild.leftChild.leftChild.nType in [ntColumnRef,ntNumber,ntString,ntParam,ntNull]) ) then //R=literal (or colref to allow PK row self matching)
               {Note: also covers case when (snode.pushed=ptMustPull) => equi-join forced from above - e.g. if INNERcol=OUTERcol then we treat OUTERcol as constant}
            begin  //column-ref on left
              {We must re-find this column locally, since the planned cRef points to immediate tuple context}
              //once we pull this down & move it we could/should re-set such pointers
              {Get range - depends on catalog.schema parse}
              //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
              if snode.leftChild.leftChild.leftChild.leftChild<>nil then cRange:=snode.leftChild.leftChild.leftChild.leftChild.rightChild.idVal else cRange:='';
              {$IFDEF DEBUGDETAIL3}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('range=%s:',[cRange]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=iTuple.FindCol(snode.leftChild.leftChild.leftChild,snode.leftChild.leftChild.leftChild.rightChild.idval,'',nil,cTuple{not needed},cRef,cid);
              {$IFDEF DEBUGDETAIL5}
              if cid=InvalidColId then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('Unknown (left) column reference (%s) in filter/local re-find (will check right column in case of reversal)',[snode.leftChild.leftChild.leftChild.rightChild.idval]),vDebugError);
                {$ELSE}
                ;
                {$ENDIF}
                //Note: this may be valid since we pass down A=B for A join B on (A=B) to both A (inner (built-backwards!)) and B (outer)
                //      and we will only choose as a filter for A so B will (gracefully) not match here

                //Also, we pass down B=A and in this case we must try to find the rightchild & return the left...
              end;
              {$ENDIF}
              if cid=InvalidColId then
              begin
                {We now have one of 3 things:
                   1. a self-join that passes selfReference but shouldn't match here else both sides try to drive by index=crash (differing aliases will cause a fail below)
                   2. a reversed equi-join, e.g. B=A where this is inner=B - we'll try to match the right-child next
                   3. an invalid filter condition, e.g. A=1, where A has the correct table_id but wrong range/alias
                }
                {3.}
                if snode.leftChild.leftChild.leftChild.nType<>ntColumnRef then
                begin
                  {$IFDEF DEBUGDETAIL5}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('%p is not a valid filter part: possibly wrong alias/range',[snode]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  exit; //ignore
                end;
                {1. if we are not a forced equi-join from above, then we assume this is not a candidate, e.g. could be a standard col=1 or a self-join}
                if (snode.pushed<>ptMustPull) then
                begin
                  {$IFDEF DEBUGDETAIL5}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('%p is not a valid equi-join col=col filter: not marked must-pull',[snode]),vdebugLow); 
                  {$ENDIF}
                  {$ENDIF}
                  exit; //invalid col=col reference //fail? should never get here?
                        // => self-join but alias difference should have prevented this being passed down??
                end;
                {2. Try to match right-child column in case this is a reversed equi-join}
                //maybe make the initial entry test above more general to cover the column-ref on right case below for non-equi-joins...
                //assumes rightchild = ntColumnRef - todo assert

                {Get range - depends on catalog.schema parse}
                //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
                if snode.rightChild.leftChild.leftChild.leftChild<>nil then cRange:=snode.rightChild.leftChild.leftChild.leftChild.rightChild.idVal else cRange:='';
                {$IFDEF DEBUGDETAIL3}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('range=%s:',[cRange]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                result:=iTuple.FindCol(snode.rightChild.leftChild.leftChild,snode.rightChild.leftChild.leftChild.rightChild.idval,'',nil,cTuple,cRef,cid);
                {$IFDEF DEBUGDETAIL5}
                if cid=InvalidColId then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Unknown (right) column reference (%s) in filter/local re-find',[snode.rightChild.leftChild.leftChild.rightChild.idval]),vDebugError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                end;
                {$ENDIF}

                if cid=InvalidColId then
                begin
                  result:=Fail; //should have been caught before now!
                                //rather, shouldn't really have got here (except for equi-joins) but referencesSelf lets self-references through in case DUMMY.a=T.a, but sometimes might be ALIASA.a=ALIASB.a which would silently fail here = ok
                end
                else
                begin
                  {$IFDEF DEBUGDETAIL6}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('%p is a valid filter part: %s colRef %d may be set to left-sub-expression',[snode,snode.rightChild.leftChild.leftChild.rightChild.idval,cRef]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}

                  candidateCRef:=cRef; //return cRef for our iTuple
                  candidateScalarNode:=snode.leftChild.leftChild.leftChild; //return scalar expression for evaluation
                  result:=+1; //return success
                end;

                exit; //either found to be reversed equi-join or not: either way we're done
              end;

              {Check if col=col that we are constraint-overridden, else
               could allow self-join -> both driven by index=crash
              }
              if (snode.rightChild.leftChild.leftChild.nType=ntColumnRef) then //R=colref to allow PK row self matching
                if (cRange<>'DUMMY') and (snode.pushed<>ptMustPull) then //Note: we still allow forced equi-joins from above
                begin
                  {$IFDEF DEBUGDETAIL3}
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('%p is not a valid col=col filter: %s colRef %d is not DUMMY',[snode,snode.leftChild.leftChild.leftChild.rightChild.idval,cRef]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$IFDEF DEBUG_LOG}
                  log.quick('(='+cRange+')');
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                  exit; //invalid col=col reference //fail?
                end;


              {$IFDEF DEBUGDETAIL6}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('%p is a valid filter part: %s colRef %d may be set to right-sub-expression',[snode,snode.leftChild.leftChild.leftChild.rightChild.idval,cRef]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              candidateCRef:=cRef; //return cRef for our iTuple
              candidateScalarNode:=snode.rightChild.leftChild.leftChild; //return scalar expression for evaluation
              result:=+1; //return success
            end
            else
              if
               ( (snode.leftChild.leftChild.leftChild<>nil) and (snode.leftChild.leftChild.leftChild.nType in [ntNumber,ntString,ntParam,ntNull]) ) AND //L=literal (not totally symmetrical - we don't check for ntColumnRef here - no need, although no harm to keep neater...)
               ( (snode.rightChild.leftChild.leftChild<>nil) and (snode.rightChild.leftChild.leftChild.nType=ntColumnRef) ) then //R=colref
              begin //column-ref on right
                {We must re-find this column locally, since the planned cRef points to immediate tuple context}
                //once we pull this down & move it we could/should re-set such pointers
                {Get range - depends on catalog.schema parse}
                //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
                //note: bugfix 14/01/03: if snode.rightChild.leftChild.leftChild<>nil then cRange:=snode.rightChild.leftChild.leftChild.leftChild.rightChild.idVal else cRange:='';
                if snode.rightChild.leftChild.leftChild.leftChild<>nil then cRange:=snode.rightChild.leftChild.leftChild.leftChild.rightChild.idVal else cRange:='';
                {$IFDEF DEBUGDETAIL3}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('range=%s:',[cRange]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                //note: bugfix 14/01/03: result:=iTuple.FindCol(snode.rightChild.leftChild,snode.rightChild.leftChild.leftChild.rightChild.idval,'',nil,cTuple,cRef,cid);
                result:=iTuple.FindCol(snode.rightChild.leftChild.leftChild,snode.rightChild.leftChild.leftChild.rightChild.idval,'',nil,cTuple,cRef,cid);
                {$IFDEF DEBUGDETAIL5}
                if cid=InvalidColId then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(stmt.who,where+routine,format('Unknown column reference (%s) in filter/local re-find',[snode.rightChild.leftChild.leftChild.rightChild.idval]),vDebugError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                end;
                {$ENDIF}
                if cid=InvalidColId then result:=Fail; //should have been caught before now!
                if result<>ok then exit; //abort if child aborts

                {$IFDEF DEBUGDETAIL6}
                {$IFDEF DEBUG_LOG}
                log.add(stmt.who,where+routine,format('%p is a valid filter part: %s colRef %d may be set to left-sub-expression',[snode,snode.rightChild.leftChild.leftChild.rightChild.idval,cRef]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
                candidateCRef:=cRef; //return cRef for our iTuple
                candidateScalarNode:=snode.leftChild.leftChild.leftChild; //return scalar expression for evaluation
                result:=+1; //return success
              end;
          end;
end; {checkFilterPart}

function TIterRelation.getTupleEqualKeyData(equalFilter:TSyntaxNodePtr;tupleData:TTuple):integer;
{Evaluate filter expression and set into tupleData for filtered scanning

 IN:       equalFilter      the list of sub-tree roots containing the filter scalar expression parts, each
                            on left of a ntEqualFilter node - in column-ref order (use ntEqualFilter.cRef)
                            (limited to equalities because hash index searches can only handle equalities)
 OUT:      tupleData        the tuple to be initialised with the filter expression
 RETURNS:  ok else fail = error

 Assumes:
   the caller has first cleared the tupleData, preferably using:
     clearToNulls
   (and tupleData is pre-defined to match the relation's tuple
    with the appropriate keyIds set)

   we have passed the JustReferencesSelf test
   - so we can assume that if we have col=col then they both are from our relation
     or the left relation has an alias (rangeName) of DUMMY //ensure user cannot do this! & note that we only check left one - keep in sync. with constraint check logic
       (otherwise could be a self-join etc. = both try to drive via index = crash!)
     Note: in future would like to treat col=outerRef.col as indexable... later!

     - used by PK row constraint checking...
     - note: will default to use left col as filter (even if right has index...)
       so we don't need to check if left is col-ref when looking for Literal=colref
       (since we use DUMMY.col=t.col, should be fine)

   the snode has be pre-planned

   each part (sub-node) in the equalFilter has passed the checkFilterPart routine
   and forms part of a single index (or if not, we're just filtering a full scan)

 Note:
   we call evalScalarExp on each sub-tree to evaluate the data
    - but we can guarantee there will be no relation references in it...

   ignores nodes of type ntNOP
}
const routine=':getTupleEqualKeyData';
var
  n:TSyntaxNodePtr;
begin
  result:=ok; //default

  //we must make sure that these are evaluated in the correct cRef order to ensure correct tuple building!*
  //      - up to caller to ensure this?
  n:=equalFilter;
  while n<>nil do
  begin
    if n.nType<>ntNOP then //skip marked as deleted (until we can properly delete from chains)
    begin
      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('filter part %d colRef %d will be set to sub-expression %p',[iTuple.fColDef[n.cRef].id,n.cRef,n.leftChild]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=EvalScalarExp(stmt,self,n.leftChild,tupleData,n.cRef,agNone,stmt.whereOldValues{for optimise filtering});
      //Note: the above call might give a dataptr=nil warning if it's the 1st call of a nested join
      //      if it contains 'must-pull' equi-join parts, since the lhs values won't have been read yet

      //we should trim the result of trailing spaces!
      if result<>ok then exit; //abort if child aborts
    end;
    n:=n.nextNode;
  end;

  tupleData.preInsert; //finalise any output
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[tupleData.ShowHeading]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[tupleData.Show(stmt)]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {getTupleEqualKeyData}

function TIterRelation.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
var
  subNode,sargNode,trailsargNode,tempSARG,candidateSARG, candidateScalarNode, tempFilterNode, tempNode:TSyntaxNodePtr;
  candidateCref:colRef;
  indexPtr,chosenIndexPtr:TIndexListPtr;
  i:colRef;
{$IFDEF DEBUGDETAIL2}
  debugs:string;
{$ENDIF}
begin
  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}

  //debug test - remove
  {$IFDEF DEBUGDETAIL2}
  debugs:='';
  subNode:=SARGlist;
  while (subNode<>nil) do
  begin
    debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
    subNode:=subNode.nextNode; //any more sub-trees?
  end;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'receiving SARGlist: '+debugs,vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {Check the SARGlist for subnodes that only reference our relation}
  {$IFDEF DEBUGDETAIL2}
  debugs:='';
  {$ENDIF}
  subNode:=SARGlist;
  //todo: assert filter=nil, else remaining tree/list
  {$IFDEF DEBUG_LOG}
  if filter<>nil then log.add(stmt.who,where+routine,'filter<>nil!',vAssertion);
  {$ELSE}
  ;
  {$ENDIF}
  //!or else DeleteSyntaxTree(filter); //todo error if fail?
  filter:=nil;
  //todo: ensure that we don't deleteSyntaxTree(filter) while it's being provisionally built cos leftChild pointer is not properly linked

  //todo: assert pulledSARGlist=nil, else remaining tree/list
  {$IFDEF DEBUG_LOG}
  if pulledSARGlist<>nil then log.add(stmt.who,where+routine,'pulledSARGlist<>nil!',vAssertion);
  {$ELSE}
  ;
  {$ENDIF}
  pulledSARGlist:=nil;
  //!!!!!!!!!!!!!!!!!!or else DeleteSyntaxTree(pulledSARGlist); //todo error if fail?
  while (subNode<>nil) do
  begin
    {$IFDEF DEBUGDETAIL2}
    debugs:=debugs+format('%p(%d) ',[subNode,ord(subNode.nType)]);
    {$ENDIF}

    //if not pulled already then
    //      - reasoning is:
    //          1. may cause problems if we re-link subnode to more than 1 child?
    //          2. no benefit - would only be applied to self-joins & filtering 1 should be good enough??
    //          3. when we swap and unset pulled flag on old-candidate (temporary logic) we must be sure only we set it!
    if (subNode.pushed=ptMustPull) or (justReferencesSelf(subNode)>=+1{i.e. includes +2}) then
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('will pull-down %p(%d pushed=%d) from SARGlist',[subNode,ord(subNode.nType),ord(subNode.pushed)]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {Add this SARG to our list}
      candidateSARG:=cloneNode(stmt.srootAlloc,subNode,False,True{so original owner can release original SARG root}); //we copy the root to simplify list management in calling routines
      {Note: we must reset sibling pointers to remove our copy from the owner SARG list
       this is ok, since we said False to clone the sibling links in the cloneNode method
      }
      candidateSARG.nextNode:=nil;
      candidateSARG.prevNode:=nil;
      chainNext(pulledSARGlist,candidateSARG); //note: inc's ref count except for 1st candidate which becomes pulledSARGlist

      {Note: we leave as mustPull to ensure re-starts re-evaluate the SARG correctly each time, i.e. as VARcol=CONST}
      if subNode.pushed<>ptMustPull then
        subNode.pushed:=ptPulled; //mark original as pulled so higher-level caller can remove from its SARG list

      //Note: our root copy retains its original pushed value throughout...

      {Ok, now see if this can be used as part of the filter}
      if checkFilterPart(candidateSARG,candidateCref,candidateScalarNode)=+1 then
      begin //this is a candidate filter part, store it in a provisional filter header list
        tempFilterNode:=mkNode(stmt.srootAlloc,ntEqualFilter,ctUnknown,nil,nil); //create dummy list node (to link + store cref & expression pointer)
        tempFilterNode.cRef:=candidateCref;
        tempFilterNode.leftChild:=candidateScalarNode; //i.e. store pointer but not linked (yet) so no ref count increase (until we decide if we'll keep/use this part)
        chainNext(filter,tempFilterNode); //note: inc's ref count except for 1st new node which becomes filter
      end;

      {Now if candidateSARG<>nil we must add it to a (new) iterSelect above here - note comments below about re-planning!}
      //todo: for now just un-set its pulled flag? => we must check it wasn't already pulled elsewhere!

    end;

    subNode:=subNode.nextNode; //any more sub-trees?
  end;

  {Now we check if our filter candidate list matches (or covers) any available index}
  //todo improve high-level comments...
  //     also needs more module testing!

  //we must ensure that:
  //  if a column is used in more than 1 filter part that we
  //  always choose the one that is 'must-pull' (i.e. used as part of the join)
  //  (if none are, then choose the most restrictive - need real statistics, else pick 1st one!)
  //  and leave/move the rest as normal (non-filter) candidates for the forthcoming iterSelec
  //TODO! - currently we pick the last (I think) which is fine if these are the must-pull (join) ones
  //          because we currently leave rest of SARGs at the higher level select, so the results are fine!

  chosenIndexPtr:=nil;
  indexPtr:=self.rel.indexList;
  while indexPtr<>nil do
  begin
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Checking for match against relation index file %s',[indexPtr.index.name]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    {Check all parts of this index}
    for i:=1 to indexPtr.index.colCount do
    begin
      subNode:=filter;
      while subNode<>nil do
      begin
        if indexPtr.index.colMap[i].cid=iTuple.fColDef[subNode.cref].id then break; //found matching column, try next index column
        subNode:=subNode.nextNode; //keep looking
      end;
      if subNode=nil then break; //not matched this index column, try next index
    end;
    if subNode<>nil then
    begin //found a matching index, make a note
      //todo: if one already found, is this better? for now just uses last matching one...
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Matched relation index file %s',[indexPtr.index.name]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      chosenIndexPtr:=indexPtr;
    end;
    indexPtr:=indexPtr.next;
  end;

  rel.fTupleKey.clearKeyIds(stmt);

  if chosenIndexPtr<>nil then
  begin //we've found a matching index
    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Will use relation index file %s as filter',[chosenIndexPtr.index.name]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    findexName:=chosenIndexPtr.index.name; //record for description
    {First remove any filter candidate parts that aren't part of the chosen index}
    //todo: until we have some (better) unchain routines, we'll mark as deleted
    subNode:=filter;
    while subNode<>nil do
    begin
      i:=1;
      while i<=chosenIndexPtr.index.colCount do
      begin
        if iTuple.fColDef[subNode.cref].id=chosenIndexPtr.index.colMap[i].cid then break; //used
        inc(i);
      end;
      if i>chosenIndexPtr.index.colCount then
      begin //not used
        tempNode:=subNode;
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Filter candidate part %p (cRef=%d) will not be used, leaving in SARG list',[tempNode,tempNode.cref]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        tempNode.nType:=ntNOP;
        tempNode.leftChild:=nil; //remove potential link-reference to avoid deleting sub-tree that is not to be copied

        tempNode:=nil; //todo debug/assertion only - remove? slight speed
      end
      else
      begin
        //todo: assert rel.fTupleKey.setKeyId(subNode.cRef,i) has not already been set!
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Filter candidate part %p (cRef=%d) will be used, moving from SARG list to actual filter list',[subNode,subNode.cref]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        linkLeftChild(subNode,subNode.leftChild); //use link-reference and so use sub-tree of ntEqualFilter
        //todo! remove this from the pulledSARGlist (no harm if left for now...)
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Filter candidate part %p (cRef=%d) will be keyId %d',[subNode,subNode.cref,i]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}

        {Set the key part}
        //todo defer until after sort by cref?
        rel.fTupleKey.setKeyId(subNode.cRef,i);
      end;

      subNode:=subNode.nextNode; //check next filter candidate part
    end;
      //  use new ntEqualFilter left-linking to eval-sub-tree -tempchained!
      //   & so remove from pulledSARGlist
      //  sort the matching parts in the filter list by cref order, so eval builds tuple data properly
      //  set the keyIds in fTupleKey from the index
  end
  else
  begin
    {$IFDEF DEBUGDETAIL7}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('Will use no relation index file as filter (=> full scan)',[nil]),vDebug);
    //todo count these & log debug error/warning...
    {$ENDIF}
    {$ENDIF}
    {Remove all filter candidate parts}
    //todo - use code above to do this in future
    subNode:=filter;
    while subNode<>nil do
    begin
      subNode.leftChild:=nil; //remove potential link-reference to avoid deleting sub-tree that is not to be copied
      subNode:=subNode.nextNode; //check next filter candidate part
    end;
    filter:=nil; //so we don't try to evaluate anything during start
  end;

  //remove unused ntEqualFilter nodes

  //check if any of our SARGs are now marked 'pulled' & remove them from ourself if so
end; {optimise}

function TIterRelation.start:integer;
{Start the relation process
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

  {Start the scan, or filtered scan depending on optimisation results}
  if filter<>nil then
  begin
    rel.fTupleKey.clearToNulls(stmt);
    result:=getTupleEqualKeyData(filter,rel.fTupleKey);
    if result=ok then
      result:=rel.findScanStart(stmt,nil);
  end
  else
    result:=rel.scanStart(stmt); //maybe place/fit rel into leftChild slot?
end; {start}

function TIterRelation.stop:integer;
{Stop the relation process
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
  {Stop the scan, or filtered scan depending on optimisation results}
  if filter<>nil then
    result:=rel.findScanStop(stmt)
  else
    result:=rel.scanStop(stmt);
end; {stop}

function TIterRelation.next(var noMore:boolean):integer;
{Get the next tuple from the relation process
 RETURNS:  ok, else fail
}
const routine=':next';
begin
//  inherited next;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  {Next scan, or filtered scan depending on optimisation results}
  if filter<>nil then
    result:=rel.findScanNext(stmt,noMore)
  else
    result:=rel.ScanNext(stmt,noMore);

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
end; {next}


end.

unit uIterProject;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}

interface

uses uIterator, uSyntax, uTransaction, uStmt, uAlgebra, uTuple {, uServer}, uGlobal;

const
  MaxMap=MaxCol;          //maximum number of column output mappings for * natural ordering

type
  TIterProject=class(TIterator) //todo: maybe create common ancestor for project/group?
    private
      completedTrees:boolean; //ensures we only complete sub-trees once even if we're re-started
      naturalMapAllCount:integer;
      naturalMapAll:array [0..MaxMap] of colRef;
    public
      function description:string; override;
      function status:string; override;

      constructor create(S:Tstmt;itemExprRef:TAlgebraNodePtr);

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterProject}

function SetProjectHeadings(st:Tstmt;anode:TAlgebraNodePtr;snode:TSyntaxNodePtr;toTuple:TTuple;var mapAll:array of colRef;var mapAllCount:integer;iter:TIterator;NewSource:boolean;aggregate:Taggregation):integer;

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}
  sysUtils, uEvalCondExpr, uProcessor {for checkTableColumnPrivilege},
  uRelation, {for checkTableColumnPrivilege}
  uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}
  ;

const
  where='uIterProject';

constructor TIterProject.create(S:Tstmt;itemExprRef:TAlgebraNodePtr);
begin
  inherited create(s);
  aNodeRef:=itemExprRef;
  completedTrees:=False;
end; {create}

function TIterProject.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  if anodeRef.rangeName<>'' then result:=result+' ('+anodeRef.rangeName+')';
end; {description}

function TIterProject.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:='TIterProject '+anodeRef.rangeName;
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterProject.prePlan(outerRef:TIterator):integer;
{PrePlans the project process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    correlated:=correlated OR leftChild.correlated;
  end;
  if result<>ok then exit; //aborted by child

  {Define this ituple from the select-item list of expressions}

  //assumes column type rises to top of tree
  if not completedTrees then
  begin
    completedTrees:=True; //ensure we only complete the sub-trees once
    {Setup projection and check select privileges}
    result:=SetProjectHeadings(stmt,anodeRef,anodeRef.nodeRef,iTuple,naturalMapAll,naturalMapAllCount,leftChild,True,agNone);
    correlated:=correlated OR leftChild.correlated;
  end;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugMedium); //debug
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {prePlan}

function TIterProject.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

function TIterProject.start:integer;
{Start the project process
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
  if assigned(leftChild) then result:=leftChild.start;   //recurse down tree
  if result<>ok then exit; //aborted by child

  {What if any of these start routines returns Fail,
   some might have succeeded and started Scans on the base relations etc.
   we need to either:
       always call rootiter.stop if start fails (& make sure stops don't complain if partially started)
    or ensure the iterators all have a destroy routine that cleans up/closes any debris
    or ensure the relation destroy routines unpin any remaining pinned pages
       - but at that level they can't be sure the page hasn't been dirtied by the pinner = not totally safe
   We should probably use all 3 methods to make sure we catch any problems: 1:safe, 2:not-so-safe, 3:assertion & unsafe clean.
  }
end; {start}

function TIterProject.stop:integer;
{Stop the project process
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
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
end; {stop}

function TIterProject.next(var noMore:boolean):integer;
{Get the next tuple from the project process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the expression evaluator's copy method) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok, else fail
}
const routine=':next';
var
  nhead,n:TSyntaxNodePtr;
  i,j:colRef;
begin
//  inherited next;
  result:=ok;
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

  if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
  {$IFDEF DEBUG_LOG}
  if not assigned(leftChild) then log.add(stmt.who,where+routine,format('leftchild is not assigned!',[1]),vDebugError);
  {$ELSE}
  ;
  {$ENDIF}
  if result<>ok then exit; //abort
  if not noMore then
  begin //populate project row
    iTuple.clear(stmt); //speed - fastClear?
    nhead:=anodeRef.nodeRef; //start with 1st project column
    i:=0;
    while i<=iTuple.ColCount-1 do
    begin
      n:=nhead;
      //todo double check not nil!
     begin
      case n.nType of     //todo remove this check - assume for speed's sake
        ntSelectItem:
        begin
          n:=n.leftChild; //get expression
          n:=n.leftChild; //move to exp root //todo remove if we remove ntCharacterExp etc.

          //todo: if this is above a iterGroup then pass a flag down to re-find the column
          //      since aggregate uses syntax pointer to point to source tuple/col-ref
          // i.e. in this case iterProject isn't really needed so to have it and share
          // the same syntax nodes means we need to do extra work to pretend we have our
          // own set of project-column pointers.
          // Eventually, this node wouldn't be present if a group-by was used... instead!?

          result:=EvalScalarExp(stmt,leftChild,n,ituple,i,agNone,false);
          //note: if result=-5 then Default, i.e. ignore & assume parent will handle
          inc(i); //processed a single column
        end; {ntSelectItem}
        ntSelectAll:
        begin
          for j:=0 to naturalMapAllCount-1 do
          begin
            //only add columns if the range. matches (e.g. select T1.*, T2.* ...)
            //note: match code taken from ttuple.findCol

            //todo if naturalMapAll[j]=invalid then must be full outer join common column:
            //     i.e. coalesce all having the same name from the original level below
            //     (or should this give an 'ambiguous reference' error?)

            //todo: must we really match the name again for every row here? Only for ALIAS.* though...
            if nhead.leftChild<>nil then
              if leftChild.iTuple.fColDef[naturalMapAll[j]].commonColumn<>0 then
                continue //skip this column, it can no longer be referered to so specifically
              else
                if CompareText(trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).rangeName),'')=0 then  //todo case! use = function
                begin
                  if CompareText(trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).tableName),trimRight(nhead.leftChild.idVal))<>0 then    //todo case! use = function
                    continue; //skip this column, its owner didn't match the specified prefix
                    //todo grammar bug: should be able to check catalog + schema here!!!
                end
                else //aliased
                  if CompareText(nhead.leftChild.idVal,trimRight(TAlgebraNodePtr(leftChild.iTuple.fColDef[naturalMapAll[j]].sourceRange).rangeName))<>0 then
                    continue; //skip this column, its owner didn't match the specified prefix

            result:=ituple.copyColDataPtr(i,leftChild.iTuple,naturalMapAll[j]);
            inc(i); //processed another column

            //todo if any result<>0 then quit
          end;
        end; {ntSelectAll}
      else
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('Unrecognised select constructor node (%d)',[ord(n.nType)]),vDebugWarning);
        {$ELSE}
        ;
        {$ENDIF}
      end; {case}
     end
     ;

      //todo if any result<>0 then quit
      nhead:=nhead.nextNode;
    end;
    {Now display the output tuple}
    if result=ok then
    begin
      ituple.preInsert; //prepare buffer

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugHigh);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Error during project, final tuple not finalised',[1]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      success:=Fail;
    end;
  end;
{$IFDEF DEBUG_LOG}
//  if noMore then log.add(stmt.who,where+routine,format('NO MORE',[1]),vDebugHigh);
{$ELSE}
;
{$ENDIF}
end; {next}

function SetProjectHeadings(st:Tstmt;anode:TAlgebraNodePtr;snode:TSyntaxNodePtr;toTuple:TTuple;var mapAll:array of colRef;var mapAllCount:integer;iter:TIterator;NewSource:boolean;aggregate:Taggregation):integer;
{Create project header from syntax tree and lower tuple.
 Also sets alias links for the projected columns (may be needed with nested selects)
 Note: debug 29/03/01: copyTupleDef does not re-point the sourceRange if it's already been set (e.g. during view expansion)

 IN:      st           the statement
          anode       the algebra tree node (used for the sourceRange links)
          snode       the syntax node containing the select item list
          toTuple     the tuple to project to (define)
          iter        the iterator (-> tuple) to read from
          newSource   if True, each column's sourceRange is set to the anode (e.g. sub-selects)
                      else, left as original source (e.g. group by)
          aggregate   pass to complete-tree routine (i.e. drill down to complete aggregate trees?)
 OUT      mapAll      an array of projected column mapping to iter.tuple in natural order for later * expansion
          mapAllCount size of mapAll array
 RESULT:  ok, else fail

 Assumes:
   toTuple has not be defined
   only one thread will be modifying this tuple at a time

 Side effects:
   will negate any iter.iTuple.fColDef[].commonColumn which are genuinely duplicates for removal
   this should be fine since this projection introduces a new set of fcolDefs with fresh commonColumns

 Note: default anode.originalOrder is from optimiser, and toTuple.fColDef[].commonColumn is 0

 //todo move this to a common parsing module (and pass transaction?)
 // - maybe uEvalCondExpr or uProcessor?
}
const routine=':SetProjectHeadings';
var
  nhead,n:TSyntaxNodePtr;
  count,countStar,i,j:colRef;
  colName:string;

  cTuple:TTuple;   //make global?

  cId:TColId;
  cRef:ColRef;

  rawMapAllCount:integer;
  rawMapAll:array [0..MaxMap] of colRef;
  tempColMap:ColRef;

  {for privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;
begin
  result:=ok;
  {We first count each node in the chain to set the tuple size
   - improve?
   Also, while we're at it, we pre-scan the syntax tree for each item to fill in
   any missing type information, and to do permission checking.
   We can do this now that the relations are open and the iterator plan is built.
   Note: this needs to be fairly quick since it's done when the client SQLprepares}
  mapAllCount:=0;
  count:=0;
  nhead:=snode;
  while nhead<>nil do
  begin
    if nhead.nType=ntSelectAll then
    begin
      if mapAllCount=0 then
      begin //we first need to build the * mapping in the natural order to remove common attributes etc.
        {Load the temporary map with the full column list}
        for cRef:=0 to iter.iTuple.ColCount-1 do
        begin
          rawMapAll[cRef]:=cRef;
        end;

        {Now sort it in original table/column order, i.e. user's FROM clause order}
        //todo this uses a naff bubble-sort: fix!
        //Note: less work (usually?) if we sort in reverse order & reverse the following loops but this loses the column order within the tables which we need
        repeat
          i:=0;
          while (i<iter.iTuple.ColCount-1) do
          begin
            //iter.iTuple.fColDef[cRef]
            if TAlgebraNodePtr(iter.iTuple.fColDef[rawMapAll[i]].sourceRange).originalOrder > TAlgebraNodePtr(iter.iTuple.fColDef[rawMapAll[i+1]].sourceRange).originalOrder then
              break; //swap these
            inc(i);
          end;

          if i<>iter.iTuple.ColCount-1 then
          begin //swap needed
            {do the swap}
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            //log.add(st.who,where+routine,format('Column map position %d has originalOrder %d and has been bubbled up to map position %d',[i,TAlgebraNodePtr(iter.iTuple.fColDef[rawMapAll[i]].sourceRange).originalOrder,i+1]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            tempColMap:=rawMapAll[i];
            rawMapAll[i]:=rawMapAll[i+1];
            rawMapAll[i+1]:=tempColMap;
          end;
        until i=iter.iTuple.ColCount-1;

        {Now load the real map}
        {Pick the first of the common flagged columns and remove their counterparts
         Note: left/right outer common columns already have their unpreferred one marked -ve -> skip
         For full outer joins we need to pick one of the two at run-time: here we pick the first for now, i.e. the right-side one}
        for cRef:=iter.iTuple.ColCount-1 downto 0 do //i.e. descending originalOrder
        begin
          if iter.iTuple.fColDef[rawMapAll[cRef]].commonColumn>=0 then //not to be skipped
          begin
            if iter.iTuple.fColDef[rawMapAll[cRef]].commonColumn>0 then
            begin //we have a common attribute, use it
              mapAll[mapAllCount]:=rawMapAll[cRef];
              inc(mapAllCount);
              {Now remove any further duplicates}
              if cRef>0 then
                for i:=cRef-1 downto 0 do
                begin
                  if CompareText(trimRight(iter.iTuple.fColDef[rawMapAll[cRef]].name),trimRight(iter.iTuple.fColDef[rawMapAll[i]].name))=0 then //todo case! use = function
                    if iter.iTuple.fColDef[rawMapAll[i]].commonColumn>0 then //we have a common flagged duplicate name so remove it
                      iter.iTuple.fColDef[rawMapAll[i]].commonColumn:=iter.iTuple.fColDef[rawMapAll[i]].commonColumn*-1; //negate it so we will skip it
                end;
            end;
          end;
        end;
        {Use the remaining columns in ascending order}
        for cRef:=0 to iter.iTuple.ColCount-1 do //i.e. ascending order
        begin
          if iter.iTuple.fColDef[rawMapAll[cRef]].commonColumn=0 then
          begin //we have an uncommon attribute, use it
            mapAll[mapAllCount]:=rawMapAll[cRef];
            inc(mapAllCount);
          end;
        end;
      end; {mapping}

      //no need to scan tree for type info - relation defines it all exactly

      (* 02/04/00 The following code was going to be removed:
         it was preventing us from selecting from columns created by CASE (in info schema views)
         - looking at the code, privilege checks are done below via completeselectItem
         but not if we do SELECT * from ...SELECT a,CASE etc..

         instead we'll ensure CASE columns are given a 'syntax' sourceTableId
      *)

      {Note: following code based on completeEvalScalarExp & put in a loop
       It's a pity we can't just check once here for table-level privilege, but
       there could be overrides/augmentations for specific column(s), so we can't}
      countStar:=0;
      for cRef:=0 to mapAllCount-1 do
      begin
        //only check columns if the range. matches (e.g. select T1.*, T2.* ...)
        //todo: need to ignore columns that have commonColumn>0, i.e. they are no longer aliased! except for system-where matching
        if nhead.leftChild<>nil then
          if iter.iTuple.fColDef[mapAll[cRef]].commonColumn<>0 then
            continue //skip this column, it can no longer be referered to so specifically
          else
            if CompareText(trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[cRef]].sourceRange).rangeName),'')=0 then  //todo case! use = function
            begin
              if CompareText(trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[cRef]].sourceRange).tableName),trimRight(nhead.leftChild.idVal))<>0 then    //todo case! use = function
                continue; //skip this column, its owner didn't match the specified prefix
                //todo grammar bug: should be able to check catalog + schema here!!!
            end
            else //aliased
              if CompareText(nhead.leftChild.idVal,trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[cRef]].sourceRange).rangeName))<>0 then
                continue; //skip this column, its owner didn't match the specified prefix

        inc(count);
        inc(countStar);

        {Now we ensure we have privilege to Select all these columns
          - we leave it to the CheckTableColumnPrivilege routine to sensibly cache when we're checking for a whole table
          - this needs to be fast!
         //todo is it true that here we're always needing to Select? I think so...
         //     but are there any internal projections (or something) that need to bypass this check?

         //Note also that some columns will have already been checked further
         //down the tree if there are also used in Selects etc.
         //- so maybe have a flag on the colDef array to mark 'checked privilege status'?? - future -speed
        }
        //todo check that passing the column id here is ok - what if we are about to (or have already) alias it?: need sourceColId?
        if CheckTableColumnPrivilege(st,0{we don't care who grantor is},Ttransaction(st.owner).authId,{todo: are we always checking our own privilege here?}
                                     False{we don't care about role/authId grantee},authId_level_match,
                                     iter.iTuple.fColDef[mapAll[cRef]].sourceAuthId{=source table owner},
                                     iter.iTuple.fColDef[mapAll[cRef]].sourceTableId{=source table},
                                     iter.iTuple.fColDef[mapAll[cRef]].id,table_level_match{we don't care how exact we match},
                                     ptSelect{always?},False{we don't want grant-option search},grantabilityOption)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed checking privilege %s on %d:%d for %d',[PrivilegeString[ptSelect],iter.iTuple.fColDef[mapAll[cRef]].sourceTableId,iter.iTuple.fColDef[mapAll[cRef]].id,Ttransaction(st.owner).AuthId]),vDebugError);
          {$ENDIF}
          st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[iter.iTuple.fColDef[mapAll[cRef]].name+' privilege']));
          result:=Fail;
          exit;
        end;
        if grantabilityOption='' then //use constant for no-permission?
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Not privileged to %s on %d:%d for %d',[PrivilegeString[ptSelect],iter.iTuple.fColDef[mapAll[cRef]].sourceTableId,iter.iTuple.fColDef[mapAll[cRef]].id,Ttransaction(st.owner).AuthId]),vDebugLow);
          {$ENDIF}
          st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to select '+iter.iTuple.fColDef[mapAll[cRef]].name]));
          result:=Fail;
          exit;
        end;
      end;
      {Ok, we're privileged}

      {If no columns have been matched, i.e. badalias.*, then give error}
      //todo is this still ok even now we can hide common attributes? => A.* = 0 columns
      if countStar=0 then
      begin
        st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.leftChild.idVal+'.*']));
        result:=Fail;
        exit;
      end;
    end
    else
    begin
      inc(count);
      result:=CompleteSelectItem(st,iter,nhead,aggregate); //todo check result! - maybe permission failure
      //todo ensure if we get result=fail here that we pass it to caller, maybe if <>ok exit here?
      if result<>ok then exit; //abort if child aborts i.e. as soon as one column isn't privileged, we fail
    end;
    nhead:=nhead.NextNode;
  end;

  toTuple.ColCount:=count;

  {Okay, define the projection columns}
  nhead:=snode;
  i:=0;
  while nhead<>nil do
  begin
    //todo impossible, but double check nhead not nil!

    colName:=intToStr(i+1); //default column name - start at 1 as per 'order by 1 etc.'
                            //todo make more configurable...
                            // & use whole section from parser as colName e.g. 'thiscol||"abc"' (as Sybase)
                            //- maybe from line,col/yytext?
                            // or use '' (as MSQL)
    if nhead.nType=ntSelectAll then
    begin
      for j:=0 to mapAllCount-1 do
      begin
        //only add columns if the range. matches (e.g. select T1.*, T2.* ...)
        //note: match code taken from ttuple.findCol
        //todo: need to ignore columns that have commonColumn>0, i.e. they are no longer aliased! except for system-where matching
        if nhead.leftChild<>nil then
          if iter.iTuple.fColDef[mapAll[j]].commonColumn<>0 then
            continue //skip this column, it can no longer be referered to so specifically
          else
            if CompareText(trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[j]].sourceRange).rangeName),'')=0 then  //todo case! use = function
            begin
              if CompareText(trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[j]].sourceRange).tableName),trimRight(nhead.leftChild.idVal))<>0 then    //todo case! use = function
                continue; //skip this column, its owner didn't match the specified prefix
                //todo grammar bug: should be able to check catalog + schema here!!!
            end
            else //aliased
              if CompareText(nhead.leftChild.idVal,trimRight(TAlgebraNodePtr(iter.iTuple.fColDef[mapAll[j]].sourceRange).rangeName))<>0 then
                continue; //skip this column, its owner didn't match the specified prefix

        toTuple.CopyColDef(i,iter.iTuple,mapAll[j]);
        inc(i);
      end;
    end
    else
    begin //ntSelectItem
      //default type definition based on dtype info passed up syntax tree
      toTuple.SetColDef(i,i+1,colName,0,nhead.dType,nhead.dwidth,nhead.dscale,'',True);

      {If this selectItem leads to a simple column-ref, pull up its total definition
       (even though we already have its type,width and scale - more is needed/better, e.g. name}
      if nhead.leftChild<>nil then      //numeric/character expression
        if nhead.leftChild.leftChild<>nil then          //column reference
          if nhead.leftChild.leftChild.nType=ntColumnRef then
          begin //this is a simple column reference
            n:=nhead.leftChild.leftChild;
            {$IFDEF DEBUG_LOG}
            {Get range - depends on catalog.schema parse}
            {$ENDIF}
            //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
            //assumes we have a right child! -assert!
            result:=iter.iTuple.FindCol(n,n.rightChild.idval,'',iter.outer,cTuple,cRef,cid);
            if cid=InvalidColId then
            begin
              //shouldn't this have been caught before now!?
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Unknown column reference (%s)',[n.rightChild.idVal]),vError);
              {$ENDIF}
              //todo? result:=Fail;
              //      exit; //abort, no point continuing?
            end;
            result:=toTuple.copyColDef(i,cTuple,cRef);
            //todo? if result<>ok then exit; //abort if child aborts
          end;
      {Override the default column name with a user-supplied alias?}
      if nhead.rightChild<>nil then
        if nhead.rightChild.nType=ntId then //use AS alias instead
          toTuple.fColDef[i].name:=nhead.rightChild.idVal;
      inc(i); //single column added
    end;
    nhead:=nhead.NextNode;
  end;

  //todo complete the tuple!? - not important yet cos we're not using the buffer to insert?

  //todo should only do newSource if this projection/sub-select is being aliased
  // -otherwise ORDER BY will fail if it includes underlying table/schema prefixes
  // - which I think is illegal (they are now hidden cos the order by is after the project)
  // but MSquery seems to use them, so double-check...
  //either way, the following fix should work:
  // we now only reset the tuple's sourceRange alias if this node (e.g antProjection) has been given an explicit alias
  if newSource then
  begin
    if anode.rangeName<>'' then
    begin
      {Now we can set the column sourceRange's
       These are needed in case this is a subselect with an AS, e.g. in From clause
       Note: they wouldn't be needed if we could guarantee that the rows projected were being
       materialised into a relation: since we are using on-the-fly pipelining, we can't.
       }
      for i:=0 to toTuple.ColCount-1 do
        toTuple.fColDef[i].sourceRange:=anode;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('NewSource aliased projection to %s',[anode.rangeName]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;

    //todo test this doesn't break group-by/having with us over-using the same syntax noderef
    if anode.exprNodeRef<>nil then
    begin
      {We have a list of column aliases (that were set at the table_ref level) so apply them now
       Note: these may well override any previous column names/aliases}
      nhead:=anode.exprNodeRef;
      for i:=0 to toTuple.ColCount-1 do
      begin
        if nhead<>nil then
        begin
          toTuple.fColDef[i].name:=nhead.idVal; //column alias
          nhead:=nhead.nextNode;
        end
        else
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Not enough column aliases (at %d out of %d)',[i+1,toTuple.ColCount]),vError);
          {$ENDIF}
          //for now we leave the original column names - i.e. half aliased/half original = bad! todo FIX! by failing!- check what happens to caller...
          //todo? result:=Fail;
          //      exit; //abort, no point continuing?
        end;
      end;
    end;
  end;
end; {SetProjectHeadings}


end.

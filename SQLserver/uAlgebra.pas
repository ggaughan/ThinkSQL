unit uAlgebra;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Relational algebra tree routines}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}

interface

uses uSyntax, uRelation, uTuple {for canSeeCol result},uGlobal;

const
  MaxKeyColMap=MaxCol;    //maximum number of sort columns
  
type
  AlgebraNodeType=(antInsertion,
                   antDeletion,
                   antUpdate,

                   antInto,
                   antProjection,
                   antGroup,

                   antSort,                //used for sort & distinct

                   antSelection,           //note: the usual ambiguity with true 'selection' and SQL's SELECTion

                   antInnerJoin,
                   antLeftJoin,
                   antRightJoin,
                   antFullJoin,
                   antUnionJoin,

                   antUnion,
                   antExcept,
                   antIntersect,
                   antUnionAll,
                   antExceptAll,
                   antIntersectAll,

                   antRelation,
                   antSyntaxRelation
                  );

  TKeyColMap=record
    left:colRef;
    right:colRef;
  end; {TKeyColMap}
  //note: index colMap subscripts start at 1

  //note: may be better as a class? - easier to convert to Java if needed
  TAlgebraNodePtr=^TAlgebraNode;
  {Note: use the functions below to create and link!}
  TAlgebraNode=record
    anType:AlgebraNodeType;
    {Reference nodes - to syntax tree}
    nodeRef:TSyntaxNodePtr;
    {Secondary syntax link - introduced for group-by Having link
     also (over)used for a column-list of aliases,
     which can be attached to table_refs which eventually produce:
       antRelation, antSyntaxRelation, antXjoin etc.
     (maybe neater to introduce an extra antAlias (& iterAlias) node
      but this would create an extra level, and I think we might get away
      without it at the cost of a little complexity)
     //-note: make sure all iterator.starts check this node ref
     (also, maybe should rename exprNodeRef to nodeRef2 - more generic?)
    }
    exprNodeRef:TSyntaxNodePtr;

    {Relation reference - for leaf nodes (also used by Insert/Delete etc.}
    rel:TRelation; //Note: freed by DeleteAlgebraTree
    {Range name, applies to antRelation, antProject (from select_exp) etc.}
    catalogName,schemaName,tableName:string;
    rangeName:string; //tableName alias: if set => ignore catalogName & schemaName & tableName when matching

    {Re-ordering control, i.e. optimisation}
    parent:TAlgebraNodePtr;
    originalOrder:integer;                   //user-specified order (1..N) before optimised, e.g. for SELECT * and natural join projection
    optimiserSuggestion:ToptimiserSuggestion;  //state of node as seen (or not) by optimiser
    {Merge join implementation, i.e. optimisation}  //todo use TAlgebraMergeJoinNode=class of (TAlgebraNode)
    keyColMap:array [0..MaxKeyColMap] of TKeyColMap; //note: replace array with linked list?
    keyColMapCount:integer;

    {Child nodes}
    leftChild:TAlgebraNodePtr;
    rightChild:TAlgebraNodePtr;
    LRswapped:boolean;                       //L-R switched by optimiser to build left-deep tree
                                             //Note (still valid?): had to invert test because seemed L-R were reversed already!
  end; {TAlgebraNode}

function mkANode(antype:algebraNodeType;nodeRef:TSyntaxNodePtr;exprNodeRef:TSyntaxNodePtr;lp,rp:TAlgebraNodePtr):TAlgebraNodePtr;
procedure copyANodeData(source,target:TAlgebraNodePtr);
procedure linkALeftChild(tp,cp:TAlgebraNodePtr);
procedure linkARightChild(tp,cp:TAlgebraNodePtr);
procedure unlinkALeftChild(tp:TAlgebraNodePtr);
procedure unlinkARightChild(tp:TAlgebraNodePtr);
function mkALeaf(antype:algebraNodeType;nodeRef:TSyntaxNodePtr;exprNodeRef:TSyntaxNodePtr;r:TRelation):TAlgebraNodePtr;

function DisplayAlgebraTree(atree:TAlgebraNodePtr):integer;
function DisplayAnotatedAlgebraTree(atree:TAlgebraNodePtr):integer;

function CanSeeCol(atree:TAlgebraNodePtr;find_node:TSyntaxNodePtr;const cName:string;var res:integer;var cTuple:array of TTuple;var c:array of ColRef;var colId:array of TColId;var cRange:array of String):integer;

function DeleteAlgebraTree(atree:TAlgebraNodePtr):integer;

const
  antJoins=[antInnerJoin,antLeftJoin,antRightJoin,antFullJoin,antUnionJoin]; //todo =antCommutativeJoins+antOuterJoins?
  antOuterJoins=[antLeftJoin,antRightJoin,antFullJoin];
  antCommutativeJoins=[antInnerJoin];
  antRelations=[antRelation,antSyntaxRelation];
  antSubqueryHeaders=[antInto,antProjection,antGroup,antSort,antUnion,antExcept,antIntersect,antUnionAll,antExceptAll,antIntersectAll];
                     //used when optimising & looking for place to insert selection before 
                     //Note: copied separately in canSeeCol- keep in sync!
                     // = antSets+...
  antSets=[antUnion,antExcept,antIntersect,antUnionAll,antExceptAll,antIntersectAll];

var
  debugAlgebraCreate:integer=0;   //todo remove -or at least make private
  debugAlgebraDestroy:integer=0;  //todo remove -or at least make private


implementation

uses uLog, sysUtils;

const
  where='uAlgebra';
  who='';

function mkANode(antype:algebraNodeType;nodeRef:TSyntaxNodePtr;exprNodeRef:TSyntaxNodePtr;lp,rp:TAlgebraNodePtr):TAlgebraNodePtr;
{Make an algebra tree node
}
const routine=':mkANode';
var
  n:TAlgebraNodePtr;
begin
  //todo replace new() with a node handler
  new(n); //note: memory
  inc(debugAlgebraCreate); //todo remove
  {$IFDEF DEBUG_LOG}
  if debugAlgebraCreate=1 then
    log.add(who,where,format('  Algebra node memory size=%d',[sizeof(TAlgebraNode)]),vDebugLow);
  {$ENDIF}
  n.antype:=antype;
  n.nodeRef:=nodeRef;
  n.exprNodeRef:=exprNodeRef;
  n.rel:=nil;
  n.catalogName:='';
  n.schemaName:='';
  n.tableName:='';
  n.rangeName:='';
  n.parent:=nil;
  n.originalOrder:=0;
  n.optimiserSuggestion:=osUnprocessed;
  n.keyColMapCount:=0;
  {Set links to children}
  n.leftChild:=lp;
  //note: if lp<>nil and lp.parent<>nil then debugWarning
  if (lp<>nil) and (lp.parent=nil) then lp.parent:=n;
  if (lp<>nil) and (lp.parent<>n) then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'lp.parent<>n',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  n.rightChild:=rp;
  //note: if rp<>nil and rp.parent<>nil then debugWarning
  if (rp<>nil) and (rp.parent=nil) then rp.parent:=n;
  if (rp<>nil) and (rp.parent<>n) then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'rp.parent<>n',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
  n.LRswapped:=False;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('(%p)%s %d [%p] %p %p',[n,n.rangeName,ord(n.antype),n.nodeRef,n.leftChild,n.rightChild]),vDebug);
  {$ENDIF}
  {$ENDIF}
  result:=n;
end; {mkANode}

procedure copyANodeData(source,target:TAlgebraNodePtr);
{Copy an algebra node's details, except any syntax/child pointers}
begin
  target.anType:=source.anType;
  target.rel:=source.rel;
  target.catalogName:=source.catalogName;
  target.schemaName:=source.schemaName;
  target.tableName:=source.tableName;
  target.rangeName:=source.rangeName;
  target.originalOrder:=source.originalOrder;
  target.optimiserSuggestion:=source.optimiserSuggestion;
  target.keyColMap:=source.keyColMap;
  target.keyColMapCount:=source.keyColMapCount;
  target.LRswapped:=source.LRswapped;
end;

procedure linkALeftChild(tp,cp:TAlgebraNodePtr);
const routine=':linkALeftChild';
begin
  if tp<>nil then
  begin
    tp.leftChild:=cp;
    cp.parent:=tp;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,cp]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end;
end; {linkALeftChild}
procedure linkARightChild(tp,cp:TAlgebraNodePtr);
const routine=':linkARightChild';
begin
  if tp<>nil then
  begin
    tp.rightChild:=cp;
    cp.parent:=tp;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,cp]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end;
end; {linkARightChild}
procedure unlinkALeftChild(tp:TAlgebraNodePtr);
const routine=':unlinkALeftChild';
begin
  if tp<>nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,tp.leftChild]),vDebug);
    {$ENDIF}
    {$ENDIF}
    tp.leftChild.parent:=nil;
    tp.leftChild:=nil;
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ENDIF}
    {$ENDIF}
  end;
end; {unlinkALeftChild}
procedure unlinkARightChild(tp:TAlgebraNodePtr);
const routine=':unlinkARightChild';
begin
  if tp<>nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,tp.rightChild]),vDebug);
    {$ENDIF}
    {$ENDIF}
    tp.rightChild.parent:=nil;
    tp.rightChild:=nil;
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ENDIF}
    {$ENDIF}
  end;
end; {unlinkARightChild}

function mkALeaf(antype:algebraNodeType;nodeRef:TSyntaxNodePtr;exprNodeRef:TSyntaxNodePtr;r:TRelation):TAlgebraNodePtr;
const routine=':mkALeaf';
var
  n:TAlgebraNodePtr;
begin
  //todo replace new() with a node handler
  new(n); //note: memory
  inc(debugAlgebraCreate); //todo remove
  n.antype:=antype;
  n.nodeRef:=nodeRef;
  n.exprNodeRef:=exprNodeRef;
  n.rel:=r;
  n.catalogName:='';
  n.schemaName:='';
  n.tableName:='';
  n.rangeName:='';
  n.parent:=nil;
  n.originalOrder:=0;
  n.optimiserSuggestion:=osUnprocessed;
  n.keyColMapCount:=0;
  n.leftChild:=nil; n.rightChild:=nil; n.LRswapped:=False;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('(%p)%d [%p]',[n,ord(antype),nodeRef]),vDebug);
  {$ENDIF}
  {$ENDIF}
  result:=n;
end; {mkALeaf}

//note: old?
function DisplayAlgebraTree(atree:TAlgebraNodePtr):integer;
{Attempt at a crude build of a display of the algebra tree
 IN:     atree              root to draw from

//note: pass to a graphical front-end routine to draw & annotate tree properly

//Note: this will fail if circular references
// exist in the tree.
// Need: either a better deletion algorithm, or prove no circles...

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const
  routine=':displayAlgebraTree';
  MAXdepth=100;   //down screen = max fan out
  MAXwidth=50;    //across screen = max tree depth
  centre=MAXdepth div 2;
  spread=0; //3; //chars away from root to display next level
type
  sline=array [0..MAXwidth] of char;
var
  scanL:array [0..MAXdepth] of sline;
  topd:integer;
  d,w:integer;

  function BuildDisplayAlgebraTree(atree:TAlgebraNodePtr;d,w:integer):integer;
  { IN       : d              current depth (start with 0!) = across
               w              current width (start with centre) = down
  }
  const
    routine=':buildDisplayAlgebraTree';
  var
    s:string;
  begin
    if abs(w)>topd then
    begin
      topd:=abs(w);
    end;
    if atree<>nil then
    begin
      {display this node}
      s:='?';
      case atree.anType of
        antInsertion:s:='I';
        antDeletion:s:='D';
        antUpdate:s:='U';
        antInto:s:='V';
        antProjection:s:='P';
        antGroup:s:='G';
        antSort:s:='O';
        antSelection:s:='S';
        antInnerJoin:s:='J';
        antLeftJoin:s:='j';
        antRightJoin:s:='j';
        antFullJoin:s:='j';
        antUnion:s:='U';
        antExcept:s:='E';
        antIntersect:s:='I';
        antUnionAll:s:='u';
        antExceptAll:s:='e';
        antIntersectAll:s:='i';
        antRelation:s:='R';
        antSyntaxRelation:s:='T';
      else
        {$IFDEF DEBUG_LOG}
        log.quick('Unrecognised tree node: '+intToStr(ord(atree.antype)));
        {$ELSE}
        ;
        {$ENDIF}
      end; {case}
      //todo when got display room!  if atree.rangeName<>'' then s:=s+atree.rangename;
      //       maybe draw straight if no right-child?
      if scanL[centre+w][d]<>' ' then
      begin  //clash
        if scanL[centre+w][d+1]<>' ' then
          scanL[centre+w][d+2]:=s[1]  
        else
          scanL[centre+w][d+1]:=s[1];
      end
      else
        scanL[centre+w][d]:=s[1];
      if atree.leftChild<>nil then BuildDisplayAlgebraTree(atree.leftChild,d+3,w+1+trunc(spread*w));
      if atree.rightChild<>nil then BuildDisplayAlgebraTree(atree.rightChild,d+3,w-1+trunc(spread*w));
    end;
    result:=ok;
  end; {BuildDisplayAlgebraTree}
begin
  {$IFDEF DEBUGDETAIL}
  topd:=-1;
  {clear slate}
  for d:=0 to MAXdepth do
    for w:=0 to MAXwidth do scanL[d][w]:=' ';

  d:=0; w:=0;       //=across and down offset!
  try
    BuildDisplayAlgebraTree(atree,d,w);
  except
    on ERangeError do topd:=MAXdepth div 2;//ignore range errors - tree too big...
  end; {try}

  for w:=centre-topd to centre+topd do
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,scanL[w],vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
  {$ENDIF}

  result:=ok;
end; {DisplayAlgebraTree}

function DisplayAnotatedAlgebraTree(atree:TAlgebraNodePtr):integer;
{Attempt at a crude build of a display of the algebra tree
 IN:     atree              root to draw from

//note: pass to a graphical front-end routine to draw & annotate tree properly

//Note: this will fail if circular references
// exist in the tree.
// Need: either a better deletion algorithm, or prove no circles...

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const
  routine=':displayAnotatedAlgebraTree';
var
  d:integer;

  function BuildDisplayAnotatedAlgebraTree(atree:TAlgebraNodePtr;d:integer):integer;
  { IN       : d              current depth (start with 0!) = down
  }
  var
    s:string;
    n:TSyntaxNodePtr;
  begin
    if atree<>nil then
    begin
      {display this node}
      s:='?';
      case atree.anType of
        antInsertion:s:='INSERT';
        antDeletion:s:='DELETE';
        antUpdate:s:='UPDATE';
        antInto:s:='INTO';
        antProjection:s:='PROJECT';
        antGroup:s:='GROUP';
        antSort:s:='SORT';
        antSelection:s:='SELECT';
        antInnerJoin:s:='INNERJOIN';
        antLeftJoin:s:='LEFTJOIN';
        antRightJoin:s:='RIGHTJOIN';
        antFullJoin:s:='FULLJOIN';
        antUnion:s:='UNION';
        antExcept:s:='EXCEPT';
        antIntersect:s:='INTERSECT';
        antUnionAll:s:='UNIONALL';
        antExceptAll:s:='EXCEPTALL';
        antIntersectAll:s:='INTERSECTALL';
        antRelation:s:='RELATION';
        antSyntaxRelation:s:='SYNTAXRELATION';
      else
        {$IFDEF DEBUG_LOG}
        log.quick('Unrecognised tree node: '+intToStr(ord(atree.antype)));
        {$ELSE}
        ;
        {$ENDIF}
      end; {case}
      if atree.LRswapped then s:=s+' (swapped children)';
      if atree.tableName<>'' then s:=s+' '+atree.tablename;
      if atree.rangeName<>'' then s:=s+' '+atree.rangename;
      n:=atree.nodeRef;
      while n<>nil do
      begin
        s:=s+' '+format('[%s]',[infixSyntax(n)]);

        n:=n.nextNode;
      end;

      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('%p: %*.*s %s',[atree,d,d,' ',s]),vDebugMedium);
      {$ENDIF}

      if atree.leftChild<>nil then BuildDisplayAnotatedAlgebraTree(atree.leftChild,d+3);
      if atree.rightChild<>nil then BuildDisplayAnotatedAlgebraTree(atree.rightChild,d+3);
    end;
    result:=ok;
  end; {BuildDisplayAnotatedAlgebraTree}
begin
  {$IFDEF DEBUGDETAIL}
  d:=0;
  BuildDisplayAnotatedAlgebraTree(atree,d);
  {$ENDIF}

  result:=ok;
end; {DisplayAnotatedAlgebraTree}


function CanSeeCol(atree:TAlgebraNodePtr;find_node:TSyntaxNodePtr;const cName:string;var res:integer;var cTuple:array of TTuple;var c:array of ColRef;var colId:array of TColId;var cRange:array of String):integer;
{Checks whether we could see the column reference given its (full) name

 IN        atree             the algebra subtree to search down
           find_node         the ntColumnRef (or simple Column i.e. ID) node to search for (can include ntTable,ntSchema,ntCatalog)
           cName             colName search override, used instead of find_node for simple column name search
           res               caller must set to start-offset for array results, i.e. 0
 OUT       res               number of times found (i.e. 0=cannot see, 1=can see, 2+=ambiguous). Subscript array results -1
           cTuple[]          the tuple reference(s) (if matched a relation)
           c[]               the column reference(s)/subscript(s) (if matched a relation)
           colId[]           the column id(s) (if matched a relation)
           cRange[]          the column range alias overrides (if any)

 RESULT    ok, else fail (use res=0 for 'failure to find match')
           res>1 =ambiguous-column-ref

 //note: re-write ttuple.FindCol based on this neater code... not exactly same logic though

 Assumes: first call passes res=0

 Note: subscript cTuple,c,colId via [0..res-1] only when result=ok!

 Note: this is used for finding the best possible plan, and does no tests for
       access privileges etc.
       This could be a good clean mechanism/time to set projection headings, aliases and
       column bindings etc. but, since the plan could be radically re-arranged,
       it's best to leave that stuff at the physical (iterator) level.
       We'd need to do it bottom up at least...

 Note: currently this is only called for antRelation nodes but it has been designed
       to match other nodes in future, e.g. projection columns, and to pass through
       other nodes as if they weren't there to get to the underlying relation/projection
       If we match against a relation, we can return details about the column
       but matching against a projection currently cannot get that information
       since the actual binding of those is done in the physical plan.
       + We do now return the range alias for such nodes
}
const routine=':CanSeeCol';
var
  i:ColRef;
  catalogName,schemaName,rangeName,colName:string;
  found_node:TSyntaxNodePtr;
  catalogName2,schemaName2,rangeName2,colName2:string;
  nhead:TSyntaxNodePtr;
begin
  //note: use hash function!

  result:=ok;

  //todo ifdef safety
  if atree=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('atree=nil',[]),vAssertion);
    {$ENDIF}
    exit;
  end;

  rangeName:='';
  schemaName:='';
  catalogName:='';

  colName:=cName; //default to simple parameter
  if find_node<>nil then
  begin
    if find_node.nType=ntColumnRef then
    begin
      colName:=find_node.rightChild.idVal; //column name
      if find_node.leftChild<>nil then
      begin
        rangeName:=find_node.leftChild.rightChild.idVal; //ntTable name
        if find_node.leftChild.leftChild<>nil then
        begin
          schemaName:=find_node.leftChild.leftChild.rightChild.idVal; //ntSchema name
          if find_node.leftChild.leftChild.leftChild<>nil then
            catalogName:=find_node.leftChild.leftChild.leftChild.rightChild.idVal; //ntCatalog name
        end;
      end;
    end
    else //simple column identifier //todo assert find_node.nType=ntId
      colName:=find_node.idVal;
  end;

  case atree.anType of
    //antProjection,antGroup:
    //note: keep in sync. with antSubqueryHeaders
    antProjection,antGroup,antSort,antUnion,antExcept,antIntersect,antUnionAll,antExceptAll,antIntersectAll:
    begin //check this level & then stop since these operators hide columns beneath them
      //note: how to handle antGroup? same as project? but exprNodeRef=having clause?

      {Handle chain of ntSelectItem,ntSelectAll by estimating the runtime name
       from setProjectHeadings logic: note: merge!}
      {Note: this is quite complex logic because projections can:
         a) be aliased e.g. (SELECT a FROM t) AS X
         b) use column aliases e.g. (SELECT a AS b FROM t)
         c) use column aliases at the projection level e.g. (SELECT a FROM t) AS X(c)
         d) use both kinds of aliases e.g. (SELECT a AS c FROM t) AS X(d)
         e) use shorthands e.g. (SELECT * FROM t) AS X
         f) use multiple shorthands e.g. (SELECT t.*, * FROM t) AS X
         g) contain unamed columns e.g. (SELECT 3 FROM t) AS X
      }
      {First make sure we're using any projection level alias}
      if atree.rangeName<>'' then
      begin //whole projection source is renamed: Note this is mandatory for sub-projections I think...
        if rangeName<>'' then
          if CompareText(atree.rangeName,trimRight(rangeName))<>0 then
          begin //our prefix doesn't match
            exit;
          end;
      end;
      {Next make sure we're only referencing renamed columns if they're renamed at the projection level}
      if atree.exprNodeRef<>nil then
      begin
        {We have a list of column aliases (that were set at the table_ref level) so test them now
         Note: these override any other column names/aliases}
        nhead:=atree.exprNodeRef;
        while nhead<>nil do
        begin
          if colName=nhead.idVal then
          begin
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Matched column reference %s.%s to projection column alias %s',[rangeName,colName,nhead.idVal]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            cTuple[res]:=nil; colId[res]:=InvalidColId;
            if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
            inc(res);
            //we continue the loop to check for more matches
          end;
          nhead:=nhead.nextNode;
        end;
      end
      else
      begin //use the names within the select / or look beneath for other nodes e.g. union
        if atree.anType in [antProjection,antGroup] then
        begin
          i:=0;
          nhead:=atree.nodeRef;
          while nhead<>nil do
          begin
            if nhead.nType=ntSelectAll then
            begin
              if nhead.leftChild<>nil then //range.*  i.e. atree.rangeName<>''
              begin
                if (atree.rangeName<>'') or (rangeName='') then
                begin //we've already matched any projection alias, or we specified none
                  //todo we should continue searching children with a prefix of nhead.leftChild.idVal
                  //to include the restriction imposed by this R.* projection

                  //note: for now we do nothing, i.e. user must explicitly give inner prefix to hope to do this...
                end;
                {note: we shouldn't get here if syntax enforces a projection-level alias}
                if CompareText(nhead.leftChild.idVal,trimRight(rangeName))=0 then
                begin //our prefix matches
                  cTuple[res]:=nil; colId[res]:=InvalidColId;
                  if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
                  inc(res);
                end;
                //else no match
              end
              else
              begin //*, i.e. treat as a pass-through
                if cRange[res]='' then cRange[res]:=atree.rangeName; //set the alias we must use at runtime
                result:=canSeeCol(atree.leftChild,find_node,cName,res,cTuple,c,colId,cRange);  //recurse
                if result<>ok then exit; //abort
              end;

              //note: should inc(i) by number of columns beneath
            end
            else
            begin //ntSelectItem
              if (nhead.rightChild<>nil) and
                 (nhead.rightChild.nType=ntId) then
              begin //aliased column
                if CompareText(trimRight(nhead.rightChild.idVal),trimRight(colname))=0 then
                begin //matched column & we've already checked any range alias
                  {Note: this can't have any other catalog/schema/range info since it's been renamed}
                  {$IFDEF DEBUGDETAIL2}
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Matched column reference %s.%s to projection column alias %s',[rangeName,colName,nhead.rightChild.idVal]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  cTuple[res]:=nil; colId[res]:=InvalidColId;
                  if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
                  inc(res);
                end;
              end
              else //root column name
              begin
                if (nhead.leftChild<>nil) and      //numeric/character expression
                   (nhead.leftChild.leftChild<>nil) and          //column reference
                   (nhead.leftChild.leftChild.nType=ntColumnRef) then
                begin
                  found_node:=nhead.leftChild.leftChild;
                  colName2:=found_node.rightChild.idVal; //column name
                  if found_node.leftChild<>nil then
                  begin
                    rangeName2:=found_node.leftChild.rightChild.idVal; //ntTable name: could be missing
                    if found_node.leftChild.leftChild<>nil then
                    begin
                      schemaName2:=found_node.leftChild.leftChild.rightChild.idVal; //ntSchema name: could be missing
                      if found_node.leftChild.leftChild.leftChild<>nil then
                        catalogName2:=found_node.leftChild.leftChild.leftChild.rightChild.idVal; //ntCatalog name: could be missing
                    end;
                  end;
                  if CompareText(trimRight(colname2),trimRight(colname))=0 then
                  begin
                    if rangeName='' then
                    begin
                      {$IFDEF DEBUGDETAIL2}
                      {$IFDEF DEBUG_LOG}
                      log.add(who,where+routine,format('Matched column reference %s.%s to projection',[rangeName,colName]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                      cTuple[res]:=nil; colId[res]:=InvalidColId;
                      if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
                      inc(res);
                    end
                    else
                    begin
                      {Note: if we have a rangeName but none is specified in the projected column
                      then we would need to drill beneath to find the source to be sure of a match
                      BUT: we should never get here since the syntax enforces an alias at the projection level
                      //note: prove & then remove this code!
                      Worst case for now is we wouldn't match if projected without explicit prefixes}
                      if CompareText(trimRight(rangeName2),trimRight(rangeName))=0 then
                        if ( (schemaName='') or (CompareText(trimRight(schemaName2),trimRight(schemaName))=0) ) then
                          if ( (catalogName='') or (CompareText(trimRight(catalogName2),trimRight(catalogName))=0) ) then
                          begin
                            {$IFDEF DEBUGDETAIL2}
                            {$IFDEF DEBUG_LOG}
                            log.add(who,where+routine,format('Matched column reference %s.%s to projection',[rangeName,colName]),vDebugError); //error because deprecated
                            {$ENDIF}
                            {$ENDIF}
                            cTuple[res]:=nil; colId[res]:=InvalidColId;
                            if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
                            inc(res);
                          end;
                    end;
                  end;
                end
                else //default column name
                begin
                  if CompareText(trimRight(intToStr(i+1)),trimRight(colname))=0 then
                  begin //matched column & we've already checked any range alias
                    {Note: this will currently be incorrect (miss some) if * are used since we don't increment yet for those
                           In fact this doesn't matter since the numeric defaults cannot be referenced! unless "1" is allowed?
                           So this should not match anyway...note: remove}
                    {Note: this can't have any other catalog/schema/range info since it's been renamed}
                    {$IFDEF DEBUGDETAIL2}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Matched column reference %s.%s to projection column alias %s',[rangeName,colName,inttoStr(i+1)]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    cTuple[res]:=nil; colId[res]:=InvalidColId;
                    if cRange[res]='' then cRange[res]:=atree.rangeName; //return the alias we must use at runtime
                    inc(res);
                  end;
                end;
              end;
              inc(i);
            end;

            nhead:=nhead.NextNode;
          end;
        end
        else
        begin //treat non-select/group as a pass-through
          //note: filter here: e.g. corresponding=common-only, correspondingBy=listed-only, else all but must be same
          if cRange[res]='' then cRange[res]:=atree.rangeName; //set the alias we must use at runtime
          result:=canSeeCol(atree.leftChild,find_node,cName,res,cTuple,c,colId,cRange);  //recurse
          if result<>ok then exit; //abort
          if atree.rightChild<>nil then
          begin //note: need we bother if we just found one?
            if cRange[res]='' then cRange[res]:=atree.rangeName; //set the alias we must use at runtime
            result:=canSeeCol(atree.rightChild,find_node,cName,res,cTuple,c,colId,cRange); //recurse
            if result<>ok then exit; //abort
          end;
        end;
      end;
    end; {sub-aliased}

    antSyntaxRelation:
    begin
      {Cannot match anything here since row constructor columns do not have names
       - they can be aliased but at a higher level (i.e. projection)
       - they can be referenced by ordinal position in an order by but that references a projection}
    end; {antSyntaxRelation}

    antRelation:
    begin
      i:=0;
      while (i<=atree.rel.fTuple.ColCount-1) do
      begin
        {Only match if both the column name and its originating source relation name match}
        if CompareText(trimRight(atree.rel.fTuple.fColDef[i].name),trimRight(colname))=0 then
        begin
          //since we're dealing with the raw relation, we can be less picky about range names here //+maybe not...
          if (atree.rangeName<>'') {aliased}  //note: actually would allow c.s.t aliased as t to be refered to as c.s.t! small bugette: todo fix later
          and (schemaName='')
          and (catalogName='')
          and (CompareText(trimRight(atree.rangeName),trimRight(rangeName))=0) then
          begin //range name specified, so we match based on it
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Fully matched column reference %s.%s to relation %s',[rangeName,colName,atree.rel.relName]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            cTuple[res]:=atree.rel.fTuple; c[res]:=i; colId[res]:=atree.rel.fTuple.fColDef[i].id;
            //we retain any cRange[res] set by a higher projection level
            inc(res);
            break; //full match- done since relations cannot have duplicate column names
          end
          else
          begin
            if rangeName<>'' then //prefix specified, so match
            begin
              if CompareText(trimRight(atree.tableName),trimRight(rangeName))=0 then
                if ( (schemaName='') or (CompareText(trimRight(atree.schemaName),trimRight(schemaName))=0) ) then
                  if ( (catalogName='') or (CompareText(trimRight(atree.catalogName),trimRight(catalogName))=0) ) then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,format('Matched column reference %s.%s to relation %s',[rangeName,colName,atree.rel.relName]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                cTuple[res]:=atree.rel.fTuple; c[res]:=i; colId[res]:=atree.rel.fTuple.fColDef[i].id;
                //we retain any cRange[res] set by a higher projection level
                inc(res);
                //we continue the loop to check this is not ambiguous
                //note: any point here for relations that can't have duplicate columns?
              end;
            end
            else
            begin //no prefix was specified so match
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Matched column reference %s to relation %s',[colName,atree.rel.relName]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              cTuple[res]:=atree.rel.fTuple; c[res]:=i; colId[res]:=atree.rel.fTuple.fColDef[i].id;
              //we retain any cRange[res] set by a higher projection level
              inc(res);
              //we continue the loop to check this is not ambiguous
              //note: any point here for relations that can't have duplicate columns?
            end;
          end;
        end;
        inc(i);
      end
    end; {leaf antRelation}
  else //pass-through
    //check any children (none of these operators hides any columns)
    //note: except natural join could make less specific/ambiguous: handle!
    //  - especially if this natural join is done the old-fashioned way, then we won't match any specific prefix!

    //note: if natural/using then lose any rangeName/schemaName/catalogName if the colName is one of the join columns
    //      i.e. these joins (will) project away the prefixes for those columns so we should be less fussy when matching beneath them
    //  although... why would a prefix be asked for in such cases? - prevent that instead...

    //todo: cRange[res] is ok as is? natural join leaves common columns & their prefixes available
    if cRange[res]='' then cRange[res]:=atree.rangeName; //pass down the alias we must use at runtime
    result:=canSeeCol(atree.leftChild,find_node,cName,res,cTuple,c,colId,cRange);  //recurse
    if result<>ok then exit; //abort

    if atree.rightChild<>nil then
    begin
      //todo: cRange[res] is ok as is? natural join leaves common columns & their prefixes available
      if cRange[res]='' then cRange[res]:=atree.rangeName; //pass down the alias we must use at runtime
      result:=canSeeCol(atree.rightChild,find_node,cName,res,cTuple,c,colId,cRange); //recurse
      if result<>ok then exit; //abort
    end;
  end; {case}
end; {CanSeeCol}


function DeleteAlgebraTree(atree:TAlgebraNodePtr):integer;
{Removes the complete algebra tree
 Also frees any associated relations (even though they were created elsewhere)

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const routine=':deleteAlgebraTree';
begin
  if atree<>nil then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('(%p)%s %d [%p] (%p) %p %p',[atree,atree.rangeName,ord(atree.antype),atree.nodeRef,atree.parent,atree.leftChild,atree.rightChild]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    if atree.leftChild<>nil then DeleteAlgebraTree(atree.leftChild);
    if atree.rightChild<>nil then DeleteAlgebraTree(atree.rightChild);
    if atree.rel<>nil then atree.rel.Free; //close & free relation
    //todo replace dispose() with a node handler
    dispose(atree); //delete self
    inc(debugAlgebraDestroy); //todo remove
    //note syntax tree is not disturbed...
  end;
  result:=ok;
end; {DeleteAlgebraTree}

end.

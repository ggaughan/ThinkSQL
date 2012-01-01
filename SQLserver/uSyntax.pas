unit uSyntax;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Syntax Tree routines}
//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3}
interface

uses uGlobal;

type //note: subtract 10 from line number to get ORD()
  nodeType=(ntNOP,                //used for syntax tree manipulation
            ntOperator,
            ntExpression,
            ntCommand,            //-
            ntCreateSchema,
            ntAuthorization,
            ntCreateTable,
            ntCreateView,
            ntCreateRoutine,      //-
            ntRoutine,
            ntProcedure,
            ntFunction,
            ntProcedureOrFunction,
            ntParameterDef,
            ntVariableRef,        //note: converted by evalConExpr.complete from ntColumnRef
            ntIn,
            ntOut,
            ntInOut,
            ntResult,
            ntCallRoutine,
            ntUserFunction,
            ntDeclaration,
            ntAssignment,
            ntReturn,
            ntCursorDeclaration,
            ntSensitive,
            ntInsensitive,
            ntAsensitive,
            ntScroll,
            ntCursorHold,
            ntCursorReturn,
            ntForReadOnly,
            ntForUpdate,
            ntOpen,
            ntClose,
            ntFetch,
            ntNext,
            ntPrior,
            ntFirst,
            ntLast,
            ntAbsolute,
            ntRelative,
            ntSQLState,
            ntCreateDomain,
            ntWithCheckOption,
            ntCascaded,
            ntLocal,
            ntNumber,
            ntString,
            ntId,
            ntLocalTemporary,
            ntGlobalTemporary,
            ntOnCommitDelete,
            ntOnCommitPreserve,
            ntColumnDef,
            ntNull,
            ntParam,
            ntDefault,
            ntNotNull,
            ntPrimaryKey,
            ntUnique,  //note: used for 2 slightly different nodes (2nd one should really be ntUNIQUE)
            ntReferences,
            ntReferencesDef,
            ntConstraintDef,             //-
            ntConstraint,
            ntAlterTable,
            ntAddColumn,
            ntAlterColumn,
            ntDropColumn,
            ntAddConstraint,
            ntDropConstraint,
            ntDropUser,               //-
            ntDropSchema,
            ntDropTable,
            ntDropView,
            ntDropRoutine,
            ntDropDomain,
            ntNumeric,                //-
            ntDecimal,
            ntInteger,
            ntSmallInt,
            ntBigInt,
            ntFloat,
            ntCharacter,
            ntVarChar,
            ntBit,
            ntVarBit,
            ntDate,
            ntTime,
            ntTimestamp,
            ntWithTimezone,
            ntBlob,
            ntClob,
            ntCount,                  //-
            ntAvg,
            ntMax,
            ntMin,
            ntSum,
            ntAggregate,
            ntPlus,
            ntMinus,
            ntMultiply,
            ntDivide,
            ntPrimaryKeyDef,
            ntUniqueDef,
            ntForeignKeyDef,
            ntMatchFull,
            ntMatchPartial,
            ntOnDelete,
            ntOnUpdate,
            ntNoAction,
            ntCascade,
            ntRestrict,
            ntSetDefault,
            ntSetNull,
            ntCheckConstraint,
            ntCondExpText, //todo never used: remove?
            ntInitiallyDeferred,
            ntInitiallyImmediate,
            ntDeferrable,
            ntNotDeferrable,
            ntSetConstraints,
            ntDeferred,
            ntImmediate,
            ntSchema,
            ntCatalog,
            ntDomain,
            ntConcat,            //-
            ntSelect,
            ntInto,
            ntDistinct,
            ntAll,
            ntWhere,
            ntSelectItem,
            ntSelectAll,
            ntColumnRef,
            ntHaving,
            ntGroupBy,
            ntOrderBy,
            ntOrderItem,
            ntAsc,
            ntDesc,
            ntTableRef,          //-
            ntAND,
            ntOR,
            ntNOT,
            ntIS,
            ntTrue,
            ntFalse,
            ntUnknown,
            ntISnull,
            ntEqual,
            ntEqualOrNull,
            ntLT,
            ntLTEQ,
            ntGT,
            ntGTEQ,
            ntNotEqual,
            ntLike,
            ntAny,
            ntInScalar,
            ntExists,
            ntIsUnique,          //-
            ntInsert,
            ntInsertValues,
            ntDefaultValues,
            ntUpdate,
            ntUpdateAssignment,
            ntDelete,
            ntTableConstructor,  //-
            ntTable,
            ntRowConstructor,
            ntCharacterExp,  //todo remove?
            ntBitExp,        //todo remove?
            ntNumericExp,    //todo rename to genericExp
            ntDatetimeExp,   //todo remove?
            ntTableExp,          //-
            ntJoin,
            ntCrossJoin,
            ntJoinOn,
            ntJoinUsing,
            ntJoinInner,
            ntJoinLeft,
            ntJoinRight,
            ntJoinFull,
            ntJoinUnion,
            ntOuter,
            ntNatural,
            ntNonJoinTableExp,
            ntCorrespondingBy,
            ntCorresponding,
            ntNonJoinTableTerm,
            ntJoinTableExp,
            ntUnionExcept,
            ntUnion,
            ntExcept,
            ntIntersect,
            ntTableTerm,
            ntTablePrimary,
            ntNonJoinTablePrimary,  //-
            ntCommit,
            ntRollback,
            ntSetTransaction,
            ntOptionDiagnostic,
            ntOptionReadOnly,
            ntOptionReadWrite,
            ntOptionIsolationReadUncommitted,
            ntOptionIsolationReadCommitted,
            ntOptionIsolationRepeatableRead,
            ntOptionIsolationSerializable,
            ntConnect,
            ntAsConnection,
            ntUser,
            ntCurrentUser,
            ntSessionUser,
            ntSystemUser,
            ntCurrentDate,
            ntCurrentTime,
            ntCurrentTimestamp,
            ntDisconnect,
            ntSetSchema,
            ntGrant,
            ntAllPrivileges,
            ntPrivilegeSelect,
            ntPrivilegeInsert,
            ntPrivilegeUpdate,
            ntPrivilegeDelete,
            ntPrivilegeReferences,
            ntPrivilegeUsage,
            ntPrivilegeExecute,
            ntCharacterSet,
            ntCollation,
            ntTranslation,
            ntWithGrantOption,
            ntRevoke,
            ntCast,
            ntCase,
            ntCaseOf,
            ntWhen,
            ntWhenType2,
            ntCoalesce,
            ntNullIf,              //-
            ntMatch,
            ntPARTIAL,
            ntFULL,               //-
            ntEqualFilter,        //internally generated node to allow separate chaining
            ntTrim,
            ntTrimWhat,
            ntTrimLeading,
            ntTrimTrailing,
            ntTrimBoth,
            ntCharLength,
            ntOctetLength,
            ntLower,
            ntUpper,
            ntPosition,
            ntSubstring,
            ntSubstringFrom,
            ntCompoundBlock,
            ntAtomic,
            ntNotAtomic,
            ntCompoundElement,
            ntCompoundWhile,
            ntCompoundIf,
            ntCompoundCase,
            ntIfThen,
            ntCompoundLoop,
            ntCompoundRepeat,
            ntLeave,
            ntIterate,

              //Non-SQL/92 (implementation-defined) nodes: subtract 12
              ntPassword,
              ntCreateCatalog,
              ntCreateUser,
              ntAlterUser,
              ntDEBUGTABLE,           //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGINDEX,           //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGCATALOG,         //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGSERVER,          //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGPAGE,            //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGPLAN,            //DEBUG ONLY - REMOVE/HIDE!
              ntDEBUGPRINT,           //DEBUG ONLY - REMOVE/HIDE!
              ntSUMMARY,              //DEBUG ONLY - REMOVE/HIDE!
              ntKILLTRAN,
              ntCANCELTRAN,
              ntREBUILDINDEX,         //DEBUG ONLY - REMOVE/HIDE!
              ntSHOWTRANS,            //DEBUG ONLY - REMOVE!
              ntCurrentAuthID,
              ntCurrentCatalog,
              ntCurrentSchema,
              ntIndex,
              ntCreateIndex,
              ntDropIndex,
              ntSequence,
              ntCreateSequence,
              ntDropSequence,
              ntStartingAt,
              ntNextSequence,
              ntLatestSequence,
              ntBackupCatalog,
              ntOpenCatalog,
              ntCloseCatalog,
              ntGarbageCollectCatalog,
              
              ntSHUTDOWN              //SYSTEM DEBUG - REMOVE!?

           ); //todo etc?

  {Used during optimisation SARG passing}
  pushedType=(ptAvailable,            //available for a child to pull
              ptPulled,               //marked as pulled by a child
              ptMustPull              //force pull to child, e.g. to override local rules for equi-join inner-filter
             );

  TSyntaxNodePtr=^TSyntaxNode;
  {Note: use the functions below to create and link!}
  TSyntaxNode=record
    {Node type}
    nType:nodeType;
    systemNode:boolean; //(initially) used for ntColumnRef/Id for optimiser to FindCol natural join columns
                        //also used to flag optimiser-handled joins (i.e. common columns set by optimiser from implicit join)
    {Reference count}
    refCount:shortint;  //reference count to allow a sub-tree to be referenced more than once (save space & time)
                        //Note: this is also inc/dec'ed in the CondToCNF routine(s) & processor routine for cursor declarations
                        //Note: if/when these syntax trees can be shared among threads we must make
                        //      sure that the inc/dec refCount is made thread-safe! todo

    {Link to iterator root}
    ptree:TObject; {=TIterator;}        //plan root - needed for main & sub-plans
                                        //since we now build (& destroy) the sub-plans once, eval needs links
    {Link to algebra root}
    atree:pointer; {=TAlgebraNodePtr;}  //algebra root - only needed so we can delete the algebra tree/sub-tree(s) once
                                        //we're done with the plans.
                                        //probably better to use ptree.anodeRef once we're sure that
                                        //it is always set properly - then we can get rid of this link space!

    {Link to tuple column}
    cTuple:TObject; {=TTuple}                 //used for fast evaluation once FindCol has found the source
    cRef:colRef;                              // "
    {Link to variable def}
    vVariableSet:TObject; {=TVariableSet}     //used for fast evaluation once FindVar has found the source
    vRef:varRef;                              // "

    {Definition (based on tuple column or variable def & passed up tree)}
    //todo: are these always associated with some iTuple.colDef? if so can't we use that to store this data?
    dType:TDataType;    //datatype, passed up through tree
    dwidth:integer;     //storage size (0=variable)
    dscale:smallint;    //precision

    aggregate:boolean;  //flag to indicate aggregation within IterGroup group-by loops
    {Mutually exclusive values}
    nullVal:boolean;    //null (introduced for aggregate counting + used for null literal)
    idVal:string;       //id (also used to store param number (will be name in future))
    numVal:double;      //number (also used to store param length if param string contains #0s, i.e. blob length)
    strVal:string;      //string (also used to store param value - initially ?=value not set)
    (*todo ?
    blobVal:pointer;    //blob (used to store param value - used with strVal ?=value not set)
    blobLen:cardinal;   //blob length
    *)
    pushed:pushedType;  //pushed flag - set during optimisation to denote moving of a SARG (actually is 'pulled'?)
    optimised:pushedType;  //pushed flag - set during (trial) algebra optimisation to denote moving of a SARG (actually is 'pulled'?)
                           //in development: note: will replace pushed
    {Child nodes}
    leftChild:TSyntaxNodePtr;
    rightChild:TSyntaxNodePtr;
    {Peer nodes}
    nextNode:TSyntaxNodePtr;
    prevNode:TSyntaxNodePtr;   //Note: used for hiding dynamically created syntax nodes at the root level to allow full cleanup //todo use another hook for this...
    {Lexical references}
    line,col:word;  //pointer back to source SQL
                    //Note this will break if column gets too big, e.g. create schema on one line
                    // - make an integer & have lexlib.inc(colNo) wrap around to 0 instead, i.e. make IT a word as well!

    allocNext:TSyntaxNodePtr; //allocation chain pointer (to guarantee full clean up after syntax error etc.)
                              //old deleteSyntaxTree tried used recursive traversal & refCount but
                              //would miss some nodes (& so sub-trees) (maybe after other routines had fiddled with the tree)
                              //and yacc wouldn't return partial trees after syntax error
                              // - seemed quicker to chain all allocations to a stmt root node
                              //   and the deleteSyntaxTree is quick and simple & should never lose any nodes
                              //May make pre-allocation/pooling of nodes easier in future?
  end; {TSyntaxNode} //approx size=1+2+4+4+4+2+1+2+2+1+1+1+4+4+4+1+4+4+4+4+2+2 +idVal+strVal = 58+ ~10 = ~68 bytes (so <16 per K)
                     // how much of this is unecessary overhead?:
                     //   is prevNode ever used?
                     //   combine idVal & strVal - too confusing!
                     //   line, col any use here?
                     //   ptree/atree rarely used - maybe use for other things (but be careful, e.g. when deleting trees!)
                     //   cTuple/cRef rarely used - maybe use for other things (no! as TTuple often used to test)
                     //(but remember, record is not packed, so saving <4 bytes may not reduce the size)

                     //todo: maybe a better solution would be to have a basic syntaxNode class
                     // and inherited classes could add their own data
                     // - more elegant (safer), but what's the speed/memory overhead?
                     // - also, would be much harder to use our own memory allocation
                     //   because the sizes would be different & less control (whereas a record can be plonked anywhere)
                     //So maybe use a variant record instead? with nType as the flag/switch...

function mkNode(allocRoot:TSyntaxNodePtr;ntype:nodeType;dtype:TdataType;lp,rp:TSyntaxNodePtr):TSyntaxNodePtr;

function cloneNode(allocRoot:TSyntaxNodePtr;np:TSyntaxNodePtr;cloneSiblingLinks,cloneChildLinks:boolean):TSyntaxNodePtr;

procedure chainNext(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
procedure chainAppendNext(tp,np:TSyntaxNodePtr);

procedure chainTempLink(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
procedure chainAppendTempLink(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
//Note: iterator.optimise routines unlink by-hand using nextNode pointers!
procedure chainPrev(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);

procedure linkLeftChild(tp,cp:TSyntaxNodePtr);
procedure linkRightChild(tp,cp:TSyntaxNodePtr);
procedure unlinkRightChild(tp:TSyntaxNodePtr);
procedure unlinkLeftChild(tp:TSyntaxNodePtr);
function mkLeaf(allocRoot:TSyntaxNodePtr;ntype:nodeType;dtype:Tdatatype;dwidth:integer;dscale:smallint):TSyntaxNodePtr;

function infixSyntax(node:TSyntaxNodePtr):string;
function DisplaySyntaxTree(stree:TSyntaxNodePtr):integer;

function DeleteSyntaxTree(stree:TSyntaxNodePtr):integer;

function hasAggregate(stree:TSyntaxNodePtr):boolean;


var
  debugSyntaxCreate:integer=0;   //todo remove -or at least make thread-safe & private
  debugSyntaxDestroy:integer=0;  //"

implementation

uses uLog, sysUtils, uAlgebra, uIterator {for deleting trees}, uIterMaterialise;

const
  where='uSyntax';
  who='';

function mkNode(allocRoot:TSyntaxNodePtr;ntype:nodeType;dtype:Tdatatype;lp,rp:TSyntaxNodePtr):TSyntaxNodePtr;
{Make a syntax tree node
 Note: dtype can be used to override the default type which is:
         x if both children are x (or only one child exists)
         else ctUnknown?... todo or default to left child type?...

 dwidth, dscale are taken from the child/children
}
const routine=':mkNode';
var
  n:TSyntaxNodePtr;
  combinedDtype:TDatatype;
  lDWidth,rDWidth:integer;
  lDScale,rDScale:smallint;
begin
  //todo replace new() with a node handler
  new(n);
  inc(debugSyntaxCreate); //todo remove
  {$IFDEF DEBUG_LOG}
  if debugSyntaxCreate=1 then
    log.add(who,where,format('  Syntax node memory size=%d',[sizeof(TSyntaxNode)]),vDebugLow);
  {$ENDIF}
  n.allocNext:=allocRoot.allocNext;
  allocRoot.allocNext:=n;
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('  chaining syntax node %p to %p',[n,allocRoot]),vdebugLow);
  {$ENDIF}
  {$ENDIF}

  n.ntype:=ntype;
  n.systemNode:=False;
  n.refCount:=0; //we increment via link/chain..Child() and decrement during DeleteSyntaxTree

  n.ptree:=nil;
  n.atree:=nil;

  n.cTuple:=nil;
  n.cRef:=0; //todo better make maxint? because 0 is actually valid!

  n.vVariableSet:=nil;
  n.vRef:=0; //todo better make maxint? because 0 is actually valid!

  n.dwidth:=0; //default //remove=speed
  n.dscale:=0; //default //remove=speed
  n.aggregate:=false;
  n.nullVal:=true;
  n.idVal:='';
  n.numVal:=0;
  n.strVal:='';
  n.pushed:=ptAvailable;
  n.optimised:=ptAvailable;
  n.nextNode:=nil; n.prevNode:=nil;
  //todo use link routines...!
  n.leftChild:=lp; if lp<>nil then inc(lp.refCount);
  n.rightChild:=rp; if rp<>nil then inc(rp.refCount);

  {Pass up the datatype etc. from the children}
  //speed- could directly change n values...
  combinedDtype:=dtype; //default/override
  if combinedDtype=ctUnknown then
  begin
    if n.rightChild<>nil then
      combinedDtype:=n.rightChild.dtype
    else
      if n.leftChild<>nil then   //note: new addition to handle ntunknown with typed left-child
        combinedDtype:=n.leftChild.dtype;

    if n.leftChild<>nil then
    begin
      if (n.leftChild.dType=combinedDtype) or (n.leftChild.dType=ctUnknown) then
        //ok, all children are same - use this dtype
      else
        if combinedDtype<>ctUnknown then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Invalid types: node default [%d], left [%d]',[ord(dtype),ord(n.leftChild.dtype)]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
    end;
  end;
  n.dtype:=combinedDtype;
  {etc}
  lDWidth:=0; rDWidth:=0;
  lDScale:=0; rDScale:=0;
  if n.leftChild<>nil then
  begin
    lDWidth:=n.leftChild.dWidth;
    lDScale:=n.leftChild.dScale;
  end;
  if n.rightChild<>nil then
  begin
    rDWidth:=n.rightChild.dWidth;
    rDScale:=n.rightChild.dScale;
  end;
  {Note the following rules are not always correct (80/20?)
   e.g. 'ABC'||'D' should have dWidth=4, not 3
   but we leave this to the next phases to correct
   //todo could update it in parser e.g. in || rule?
   // - although not if column ref etc. were involved - need to defer...
  }
  n.dWidth:=maxINTEGER(lDWidth,rDWidth);
  n.dScale:=maxSMALLINT(lDScale,rDScale);

  n.line:=0;
  n.col:=0;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('(%p)%d [%d %d %d] %p %p',[n,ord(n.ntype),ord(n.dtype),n.dwidth,n.dscale,n.leftChild,n.rightChild]),vDebug);
  {$ENDIF}
  {$ENDIF}
  result:=n;
end; {mkNode}

function cloneNode(allocRoot:TSyntaxNodePtr;np:TSyntaxNodePtr;cloneSiblingLinks,cloneChildLinks:boolean):TSyntaxNodePtr;
{Make a copy of a syntax tree node
 IN: np                  the node to clone
     cloneSiblingLinks   True=increment reference counts on siblings, else share siblings
     cloneChildLinks     True=increment reference counts on children, else share children

 Note:
   this new node's ref count is not copied, but set to 0
}
const routine=':cloneNode';
var
  n:TSyntaxNodePtr;
begin
  //todo replace new() with a node handler
  new(n);
  inc(debugSyntaxCreate); //todo remove
  n.allocNext:=allocRoot.allocNext;
  allocRoot.allocNext:=n;
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('  chaining syntax node %p to %p',[n,allocRoot]),vdebugLow);
  {$ENDIF}
  {$ENDIF}

  n.ntype:=np.ntype;
  n.systemNode:=False;
  n.refCount:=0; //we increment via link/chain..Child() and decrement during DeleteSyntaxTree

  n.ptree:=np.ptree;
  n.atree:=np.atree;

  n.cTuple:=np.cTuple;
  n.cRef:=np.cRef;

  n.vVariableSet:=np.vVariableSet;
  n.vRef:=np.vRef;

  n.dwidth:=np.dwidth;
  n.dscale:=np.dscale;
  n.aggregate:=np.aggregate;
  n.nullVal:=np.nullVal;
  n.idVal:=np.idVal;
  n.numVal:=np.numVal;
  n.strVal:=np.strVal;
  n.pushed:=np.pushed;
  n.optimised:=np.optimised;

  n.nextNode:=np.nextNode;
  n.prevNode:=np.prevNode;
  //todo use link routines...!
  if cloneSiblingLinks then
  begin
    if n.nextNode<>nil then inc(n.nextNode.refCount);
    if n.prevNode<>nil then inc(n.prevNode.refCount);
  end;
  n.leftChild:=np.leftChild;
  n.rightChild:=np.rightChild;
  //todo use link routines...!
  if cloneChildLinks then
  begin
    if n.leftChild<>nil then inc(n.leftChild.refCount);
    if n.rightChild<>nil then inc(n.rightChild.refCount);
  end;

  n.dtype:=np.dtype;
  {etc}
  n.dWidth:=np.dWidth;
  n.dScale:=np.dScale;

  n.line:=np.line;
  n.col:=np.col;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('(%p <- %p)%d [%d %d %d] %p %p',[n,np,ord(n.ntype),ord(n.dtype),n.dwidth,n.dscale,n.leftChild,n.rightChild]),vDebug);
  {$ENDIF}
  {$ENDIF}
  result:=n;
end; {cloneNode}

procedure chainNext(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
{Insert node (or chain) between this node and its next one
 effectively stacking the new node & assuming a static head-node

 28/03/00 if tp=nil, then set to np to start a new chain (for local SARG lists)
          Note: still works a bit weird: e.g. 1,2,3,4 -> 1,4,3,2 ?
           -not used from Yacc (yet?)
}
const routine=':chainNext';
var
  tempn, lastInInsertedChain:TSyntaxNodePtr;
  looping:integer; //todo remove loop detector in final code!
begin
  if tp<>np then
  begin
    if tp<>nil then
    begin
      if np<>nil then
      begin
        tempn:=tp.nextNode;
        tp.nextNode:=np; //insert in chain
        inc(np.refCount);

        //todo link np.prevNode?
        lastInInsertedChain:=np; //find end of this sub-chain being inserted
        looping:=0; //todo remove loop detector ****or at least increase in case we have many items!!!
        while (lastInInsertedChain.nextNode<>nil) and (looping<200) do
        begin
          lastInInsertedChain:=lastInInsertedChain.nextNode;
          inc(looping);
        end;
        if looping=200 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%p %p: Chain probably has a loop! It will be corrupt now...',[tp,np]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}
        end;
        lastInInsertedChain.NextNode:=tempn;  //re-link end to rest of existing chain
        //todo link tempn.prevNode?
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%p %p',[tp,np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'np=nil',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
    end
    else
    begin //tp=nil -> new list
      if np<>nil then
      begin
        tp:=np;
        //todo remove! inc(np.refCount);
        //             we assume that if we're starting a list this way that
        //             the np node will become the tp node & so is not actually being referenced
        //             from another node (but is pointing tp to itself, so caller must ignore np = fine if temp/loop)
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%s %p',['nil',np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'np=nil (and tp=nil!)',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
    end;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=np',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
end; {chainNext}

procedure chainAppendNext(tp,np:TSyntaxNodePtr);
{Append node (or chain) at end of this current node's chain}
const routine=':chainAppendNext';
var
  lastInChain:TSyntaxNodePtr;
  looping:integer; //todo remove loop detector in final code!
begin
  if tp<>np then
  begin
    if tp<>nil then
    begin
      if np<>nil then
      begin
        lastInChain:=tp; //find end of the current chain //todo speed up repeated calls - maybe tp.prevNode should point to its end=loop?
        looping:=0; //todo remove loop detector ****or at least increase in case we have many items!!!
        while (lastInChain.nextNode<>nil) and (looping<200) do
        begin
          lastInChain:=lastInChain.nextNode;
          inc(looping);
        end;
        if looping=200 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%p %p: Chain probably has a loop! It will be corrupt now...',[tp,np]),vDebugError); 
          {$ENDIF}
        end;
        lastInChain.NextNode:=np;  //link end to new node/chain
        inc(np.refCount);
        //todo link np.prevNode?
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%p %p',[tp,np]),vDebug);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'np=nil',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
    end
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'tp=nil',vDebug);
      {$ELSE}
      ;
      {$ENDIF}
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=np',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
end; {chainAppendNext}

procedure chainTempLink(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
{Chain node (or chain) to build temporary chain
 If tp is nil, returns head of np as tp to start new chain

 Note: no reference counts are incremented - it is assumed this list
       is a temporary list of copied pointers to nodes that already exist and
       are reference-counted elsewhere.
       Also, the caller is free to unlink/dispose of copy nodes by-hand
       (introduced for initial iterator.optimise SARG pushing routines)

       When children use parts of this chain, they must create a new duplicate
       root node for each so that they can use separate prev/nextNode
       links and leave the originals alone so that the parent
       iterator can still find and remove them from the cumulative SARGlist.

 //TODO: **** increase loop detection to allow long SARG lists!
}
const routine=':chainTempLink';
var
  tempn, lastInInsertedChain:TSyntaxNodePtr;
  looping:integer; //todo remove loop detector in final code!
begin
  if tp=nil then
  begin
    tp:=np;
  end
  else
  begin
    if tp<>np then
    begin
      if np<>nil then
      begin
        tempn:=tp.nextNode;
        tp.nextNode:=np; //insert in chain

        //todo link np.prevNode?
        lastInInsertedChain:=np; //find end of this sub-chain being inserted
        looping:=0; //todo remove loop detector ****or at least increase in case we have many items!!!
        while (lastInInsertedChain.nextNode<>nil) and (looping<2000) do
        begin
          lastInInsertedChain:=lastInInsertedChain.nextNode;
          inc(looping);
        end;
        if looping=2000 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%p %p: Chain probably has a loop! It will be corrupt now...',[tp,np]),vDebugError); 
          {$ELSE}
          ;
          {$ENDIF}
        end;
        lastInInsertedChain.NextNode:=tempn;  //re-link end to rest of existing chain
        //todo link tempn.prevNode?
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%p %p',[tp,np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end;
      //else np=nil - ok, nothing to chain
    end
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'tp=np',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
  end;
end; {chainTempLink}

procedure chainAppendTempLink(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
{Append node (or chain) to build temporary chain
 If tp is nil, returns head of np as tp to start new chain

 Note: no reference counts are incremented - it is assumed this list
       is a temporary list of copied pointers to nodes that already exist and
       are reference-counted elsewhere.
       Also, the caller is free to unlink/dispose of copy nodes by-hand
       (introduced for initial iterator.optimise SARG pushing routines)
       (Append introduced to ensure unlink traversal match doesn't include new chain itself!
        because chainTempLink attaches new chain to old chain!)

       When children use parts of this chain, they must create a new duplicate
       root node for each so that they can use separate prev/nextNode
       links and leave the originals alone so that the parent
       iterator can still find and remove them from the cumulative SARGlist.

 //TODO: **** increase loop detection to allow long SARG lists!
}
const routine=':chainAppendTempLink';
var
  lastInChain:TSyntaxNodePtr;
  looping:integer; //todo remove loop detector in final code!
begin
  if tp=nil then
  begin
    tp:=np;
  end
  else
  begin
    if tp<>np then
    begin
      if np<>nil then
      begin
        lastInChain:=tp; //find end of the current chain //todo speed up repeated calls - maybe tp.prevNode should point to its end=loop?
        looping:=0; //todo remove loop detector ****or at least increase in case we have many items!!!
        while (lastInChain.nextNode<>nil) and (looping<2000) do
        begin
          lastInChain:=lastInChain.nextNode;
          inc(looping);
        end;
        if looping=2000 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%p %p: Chain probably has a loop! It will be corrupt now...',[tp,np]),vDebugError); 
          {$ENDIF}
        end;
        lastInChain.NextNode:=np;  //link end to new node/chain

        //todo link prevNode?
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%p %p',[tp,np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end;
      //else np=nil - ok, nothing to chain
    end
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'tp=np',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
  end;
end; {chainAppendTempLink}

procedure chainPrev(var tp:TSyntaxNodePtr;np:TSyntaxNodePtr);
{Insert node (or chain) between this node and its previous one
 effectively stacking the new node & assuming a static head-node

 28/03/00 if tp=nil, then set to np to start a new chain (for local SARG lists)
          Note: still works a bit weird: e.g. 1,2,3,4 -> 1,4,3,2 ?
           -not used from Yacc (yet?)

 Note: added to be able to attach nodes to root for clean-up but for
       processing from elsewhere, not the root
}
const routine=':chainPrev';
var
  tempn, lastInInsertedChain:TSyntaxNodePtr;
  looping:integer; //todo remove loop detector in final code!
begin
  if tp<>np then
  begin
    if tp<>nil then
    begin
      if np<>nil then
      begin
        tempn:=tp.prevNode;
        tp.prevNode:=np; //insert in chain
        inc(np.refCount);

        //todo link np.nextNode?!
        lastInInsertedChain:=np; //find end of this sub-chain being inserted
        looping:=0; //todo remove loop detector ****or at least increase in case we have many items!!!
        while (lastInInsertedChain.prevNode<>nil) and (looping<200) do
        begin
          lastInInsertedChain:=lastInInsertedChain.prevNode;
          inc(looping);
        end;
        if looping=200 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%p %p: Chain probably has a loop! It will be corrupt now...',[tp,np]),vDebugError); 
          {$ENDIF}
        end;
        lastInInsertedChain.prevNode:=tempn;  //re-link end to rest of existing chain
        //todo link tempn.prevNode?
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%p %p',[tp,np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'np=nil',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
    end
    else
    begin //tp=nil -> new list
      if np<>nil then
      begin
        tp:=np;
        //todo remove! inc(np.refCount);
        //             we assume that if we're starting a list this way that
        //             the np node will become the tp node & so is not actually being referenced
        //             from another node (but is pointing tp to itself, so caller must ignore np = fine if temp/loop)
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('%s %p',['nil',np]),vDebug);
        {$ENDIF}
        {$ENDIF}
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'np=nil (and tp=nil!)',vDebug);
        {$ELSE}
        ;
        {$ENDIF}
    end;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=np',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
end; {chainPrev}


procedure linkLeftChild(tp,cp:TSyntaxNodePtr);
const routine=':linkLeftChild';
begin
  if tp<>nil then
  begin
    tp.leftChild:=cp;
    inc(cp.refCount);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,cp]),vDebug);
    {$ENDIF}
    {$ENDIF}
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {linkLeftChild}
procedure linkRightChild(tp,cp:TSyntaxNodePtr);
const routine=':linkRightChild';
begin
  if tp<>nil then
  begin
    tp.rightChild:=cp;
    inc(cp.refCount);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,cp]),vDebug);
    {$ENDIF}
    {$ENDIF}
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {linkRightChild}
procedure unlinkRightChild(tp:TSyntaxNodePtr);
const routine=':unlinkRightChild';
begin
  if tp<>nil then
  begin
    dec(tp.rightChild.refCount);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,tp.rightChild]),vDebug);
    {$ENDIF}
    {$ENDIF}
    if tp.rightChild.refCount<=0 then
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('  reference count is now <=0 (%d)',[tp.rightChild.refCount]),vDebugWarning);
      {$ELSE}
      ;
      {$ENDIF}
    tp.rightChild:=nil;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {unlinkRightChild}
procedure unlinkLeftChild(tp:TSyntaxNodePtr);
const routine=':unlinkLeftChild';
begin
  if tp<>nil then
  begin
    dec(tp.leftChild.refCount);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('%p %p',[tp,tp.leftChild]),vDebug);
    {$ENDIF}
    {$ENDIF}
    if tp.leftChild.refCount<=0 then
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('  reference count is now <=0 (%d)',[tp.leftChild.refCount]),vDebugWarning);
      {$ELSE}
      ;
      {$ENDIF}
    tp.leftChild:=nil;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'tp=nil',vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {unlinkLeftChild}

function mkLeaf(allocRoot:TSyntaxNodePtr;ntype:nodeType;dtype:Tdatatype;dwidth:integer;dscale:smallint):TSyntaxNodePtr;
const routine=':mkLeaf';
var
  n:TSyntaxNodePtr;
begin
  //todo replace new() with a node handler
  new(n);
  inc(debugSyntaxCreate); //todo remove
  n.allocNext:=allocRoot.allocNext;
  allocRoot.allocNext:=n;
  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('  chaining syntax node %p to %p',[n,allocRoot]),vdebugLow);
  {$ENDIF}
  {$ENDIF}

  n.ntype:=ntype;
  n.systemNode:=False;
  n.refCount:=0; //incremented by chain/link and decremented by DeleteSyntaxTree

  n.ptree:=nil;
  n.atree:=nil;

  n.cTuple:=nil;
  n.cRef:=0; //todo better make maxint? because 0 is actually valid!

  n.vVariableSet:=nil;
  n.vRef:=0; //todo better make maxint? because 0 is actually valid!

  n.dtype:=dtype;
  n.dwidth:=dwidth;
  n.dscale:=dscale;
  n.aggregate:=false;
  n.nullVal:=true;
  n.idVal:='';
  n.numVal:=0;
  n.strVal:='';
  n.pushed:=ptAvailable;
  n.optimised:=ptAvailable;
  n.nextNode:=nil; n.prevNode:=nil;
  n.leftChild:=nil; n.rightChild:=nil;

  n.line:=0;
  n.col:=0;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('(%p)%d [%d]',[n,ord(ntype),ord(dtype)]),vDebug);
  {$ENDIF}
  {$ENDIF}
  result:=n;
end; {mkLeaf}

function infixSyntax(node:TSyntaxNodePtr):string;
{Flatten syntax node}
var s:string;
begin
  if node=nil then
  begin
    result:='';
    exit;
  end;

  //originally copied from displaySyntaxTree
  s:='?';
  case node.ntype of
    ntNOP:s:='';
    ntOR:s:=' OR ';
    ntAND:s:=' AND ';
    ntEqual:s:='=';
    ntEqualOrNull:s:='(=)';
    ntNotEqual:s:='<>';
    ntLT:s:='<';
    ntGT:s:='>';
    ntGTEQ:s:='>=';
    ntLTEQ:s:='<=';
    ntNOT:s:='NOT ';
    ntRowConstructor:s:=''{R};
    ntID:s:=' '+node.idVal+' ';
    ntColumnRef:s:=''{C};
    ntTable:s:=''{T};
    ntSchema:s:=''{S};
    ntCharacterExp:s:='';
    ntNumericExp:s:='';
    ntInteger:s:='';
    ntSmallInt:s:='';
    ntBigInt:s:='';
    ntFloat:s:='';
    ntNumber:s:=floatToStr(node.numVal);
    ntString:s:=node.strVal;
    ntNull:s:='NULL';
    ntConcat:s:='||';
    ntPlus:s:='+';
    ntMinus:s:='-';
    ntMultiply:s:='*';
    ntDivide:s:='/';
    ntTableExp:s:='';
    ntSelect:s:='';
    ntAll:s:='A';
    ntDistinct:s:='D';
    ntSelectItem:s:='';
    ntSelectAll:s:='*';
    ntTableRef:s:=node.idVal;
    ntAggregate:s:='A';
    ntMax:s:='MAX';
    ntMin:s:='MIN';
    ntCount:s:='COUNT';
    ntIsNull:s:='ISNULL';
    ntAny:s:='ANY';
    ntExists:s:='EXISTS';
    ntLike:s:='LIKE';
    ntInScalar:s:='IN';
    ntOrderBy:s:='ORDER';
    ntParam:s:='?';
    ntCase:s:='CASE';
    ntCaseOf:s:='CASEOF';
    ntWhen,ntWhenType2:s:='WHEN';
    ntJoin:s:='JOIN';
    ntCrossJoin:s:='CROSSJOIN';
    ntMatch:s:='MATCH';
    ntIsUnique:s:='UNIQUE';
    ntIs:s:='IS';
    ntTrue:s:='TRUE';
    ntFalse:s:='FALSE';
    ntUnknown:s:='UNKNOWN';

    ntNonJoinTableExp,ntNonJoinTableTerm,
    ntNonJoinTablePrimary,ntJoinTableExp: //'filler' nodes - not very interesting
      s:='';

    ntCurrentAuthID,ntCurrentCatalog,ntCurrentSchema:s:='fn()';

    ntJoinOn:s:='ON:';
    ntJoinUsing:s:='USING:';
    ntNatural:s:='NATURAL';
    ntTableConstructor:s:=',';
  else
    s:='{'+inttostr(ord(node.ntype))+'}';
  end; {case}
  result:=infixSyntax(node.leftChild)+s+infixSyntax(node.rightChild);
end; {infixSyntax}

function DisplaySyntaxTree(stree:TSyntaxNodePtr):integer;
{Attempt at a crude build of a display of the syntax tree
 IN:     stree              root to draw from

//todo - pass to a graphical front-end routine to draw & annotate tree properly

//Note: this will fail if circular references
// exist in the tree.
// Need: either a better deletion algorithm, or prove no circles...

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const
  routine=':displaySyntaxTree';
  MAXdepth=100;   //down screen = max fan out
  MAXwidth=80;    //across screen = max tree depth
  centre=MAXdepth div 2;
  spread=0; //3; //chars away from root to display next level
type
  sline=array [0..MAXwidth] of char;
var
  scanL:array [0..MAXdepth] of sline;
  topd:integer;
  d,w:integer;

  function BuildDisplaySyntaxTree(stree:TSyntaxNodePtr;d,w:integer):integer;
  { IN       : d              current depth (start with 0!) = across
               w              current width (start with centre) = down
  }
  const
    routine=':buildDisplaySyntaxTree';
  var
    s:string;
  begin
    if abs(w)>topd then
    begin
      topd:=abs(w);
    end;
    if stree<>nil then
    begin
      {display this node}
      s:='?';
      case stree.nType of
        ntNOP:s:='X';
        ntOR:s:='V';
        ntAND:s:='&';
        ntEqual:s:='=';
        ntEqualOrNull:s:='=';
        ntNotEqual:s:='#';
        ntLT:s:='<';
        ntGT:s:='>';
        ntGTEQ:s:='»';
        ntLTEQ:s:='«';
        ntNOT:s:='¬';
        ntRowConstructor:s:='R';
        ntID:s:='n'; //todo use when get better display: stree.idVal;
        ntColumnRef:s:='C';
        ntTable:s:='T';
        ntSchema:s:='S';
        ntCharacterExp:s:='e';
        ntNumericExp:s:='e';
        ntInteger:s:='i';
        ntSmallInt:s:='i';
        ntBigInt:s:='i';
        ntFloat:s:='f';
        ntNumber:s:='#';
        ntString:s:='$';
        ntNull:s:='x';
        ntConcat:s:='+';
        ntPlus:s:='+';
        ntMinus:s:='-';
        ntMultiply:s:='*';
        ntDivide:s:='/';
        ntTableExp:s:='t';
        ntSelect:s:='S';
        ntDelete:s:='D';
        ntInsert:s:='I';
        ntUpdate:s:='U';
        ntAll:s:='A';
        ntDistinct:s:='D';
        ntSelectItem:s:='s';
        ntSelectAll:s:='*';
        ntTableRef:s:='r';
        ntAggregate:s:='A';
        ntMax:s:='m';
        ntMin:s:='m';
        ntCount:s:='#';
        ntIsNull:s:='0';
        ntAny:s:='1';
        ntExists:s:='E';
        ntLike:s:='L';
        ntInScalar:s:='I';
        ntOrderBy:s:='O';
        ntParam:s:='?';
        ntCase:s:='c';
        ntCaseOf:s:='o';
        ntWhen,ntWhenType2:s:='w';
        ntJoin:s:='J';
        ntCrossJoin:s:='J';
        ntMatch:s:='M';
        ntIsUnique:s:='U';
        ntIs:s:='I';
        ntTrue:s:='T';
        ntFalse:s:='F';
        ntUnknown:s:='U';
        ntCurrentAuthID,ntCurrentCatalog,ntCurrentSchema:s:='f';
        ntRoutine:s:='R';
        ntCallRoutine:s:='C';
        ntUserFunction:s:='F';
        ntDeclaration:s:='D';
        ntAssignment:s:='S';
        ntUpdateAssignment:s:='=';
        ntCompoundBlock:s:='€';
        ntCompoundWhile:s:='W';
        ntReturn:s:='R';
        ntCompoundIf:s:='I';
        ntCompoundCase:s:='C';
        ntIfThen:s:='i';
        ntCompoundLoop:s:='L';
        ntCompoundRepeat:s:='R';
        ntLeave:s:='l';
        ntIterate:s:='i';

        
        ntNumeric,
        ntDecimal,
        ntCharacter,
        ntVarChar,
        ntBit,
        ntVarBit,
        ntDate,
        ntTime,
        ntTimestamp:s:='d';

        ntCharLength:s:='F';
        ntOctetLength:s:='F';

        ntTableConstructor,ntCompoundElement,
        ntNonJoinTableExp,ntNonJoinTableTerm,
        ntNonJoinTablePrimary,ntJoinTableExp: //'filler' nodes - not very interesting
          s:='.';
      else
        {$IFDEF DEBUG_LOG}
        log.quick('Unrecognised tree node: '+intToStr(ord(stree.ntype)));
        {$ELSE}
        ;
        {$ENDIF}
      end; {case}
      //todo: maybe draw straight if no right-child?
      if scanL[centre+w][d]<>' ' then
      begin  //clash
        if scanL[centre+w][d+1]<>' ' then
          scanL[centre+w][d+2]:=s[1]  //todo if needed may need more...
        else
          scanL[centre+w][d+1]:=s[1];
      end
      else
        scanL[centre+w][d]:=s[1];           //todo build L..R!
    //todo?    if stree.prevNode<>nil then BuildDisplaySyntaxTree(stree.prevNode);
    //todo?    if stree.nextNode<>nil then BuildDisplaySyntaxTree(stree.nextNode);
      if stree.leftChild<>nil then BuildDisplaySyntaxTree(stree.leftChild,d+3,w+1+trunc(spread*w));
      if stree.rightChild<>nil then BuildDisplaySyntaxTree(stree.rightChild,d+3,w-1+trunc(spread*w));
    end;
    result:=ok;
  end; {BuildDisplaySyntaxTree}
begin
  {$IFDEF DEBUGDETAIL}
  topd:=-1;
  {clear slate}
  for d:=0 to MAXdepth do
    for w:=0 to MAXwidth do scanL[d][w]:=' ';

  d:=0; w:=0;       //=across and down offset!
  try
    BuildDisplaySyntaxTree(stree,d,w);
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
end; {DisplaySyntaxTree}

function DeleteSyntaxTree(stree:TSyntaxNodePtr):integer;
{Removes the complete syntax tree,
 and as each syntax node is deleted, the routine also deletes any
 algebra and iterator trees that are attached. //todo so rename routine?

 Note:
   some logic is duplicated in uCondToCNF.chopAnd routine

//Note: this will fail (or leave stray garbage) if circular references
// exist in the tree.
// Need: either a better deletion algorithm, or prove no circles...

 RESULT     : ok or fail
              (ok even if no tree is specified)
}
const routine=':deleteSyntaxTree';

  function deleteSyntaxNode(snode:TSyntaxNodePtr):integer;
  const routine=':deleteSyntaxNode';
  begin
    result:=ok;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('(%p)%d [%s]',[snode,ord(snode.ntype),snode.idVal]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    {Now we can be sure we've finally stopped the (sub)plan we can close any pending relations
     Note: we must do this before cleaning the algebra nodes etc.}
    if snode.ptree<>nil then
      if snode.ptree is TIterMaterialise then
      begin
        {We may never have really stopped (just bounced around the cache) so do it now before we delete our children!}
        if not (snode.ptree as TIterMaterialise).stopped then
        begin
          begin //really stop for 1st time
            if assigned((snode.ptree as TIterator).leftChild) then (snode.ptree as TIterator).leftChild.stop;   //recurse down tree
            //{$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Finally actually stopping materialised node',[nil]),vDebugLow);
            {$ENDIF}
            //{$ENDIF}
            (snode.ptree as TIterMaterialise).stopped:=True;
          end;
        end;
      end;

    {Remove any sub-plan information if this node is a sub-root}
    if snode.atree<>nil then
    begin
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.status; //memory display
      {$ENDIF}
      {$ENDIF}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'Deleting algebra tree...',vDebugMedium);
      {$ENDIF}
      {$ENDIF}
      DeleteAlgebraTree(TAlgebraNodePtr(snode.atree));
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.status; //memory display
      {$ENDIF}
      {$ENDIF}
    end;
    if snode.ptree<>nil then
    begin
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.status; //memory display
      {$ENDIF}
      {$ENDIF}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'Deleting plan tree...',vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      DeleteIteratorTree(snode.ptree as TIterator);
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.status; //memory display
      {$ENDIF}
      {$ENDIF}
    end;
    //todo replace dispose() with a node handler
    //  i.e. return to a common heap of syntax nodes for re-cycling...
    {$IFDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    if snode=nil then
      log.add(who,where+routine,format('Free error',[nil]),vAssertion);
    {$ENDIF}
    {$ENDIF}
    dispose(snode); //delete self
    inc(debugSyntaxDestroy); //todo remove
  end; {deleteSyntaxNode}

var
  curNode,zapNode:TSyntaxNodePtr;
begin
  if stree<>nil then
  begin
    curNode:=stree;

    while curNode.allocNext<>nil do
    begin
      zapNode:=curNode.allocNext;
      curNode.allocNext:=zapNode.allocNext;

      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('  deleting syntax node %p from %p',[zapNode,stree]),vdebugLow);
      {$ENDIF}
      {$ENDIF}
      deleteSyntaxNode(zapNode);
    end;

    deleteSyntaxNode(curNode);
  end;
  result:=ok;
end; {DeleteSyntaxTree}


function hasAggregate(stree:TSyntaxNodePtr):boolean;
{Recurse the tree looking for an aggregate function.
 RESULT:    True if aggregate is found, else False

 Note: does not recurse down into any sub-selects (since their aggregates are internal)

 todo: I think this should go through the next chain as well in case we have
       aggregate parameters to a routine
       - see eval routine comments for a possible way to avoid the need for this routine
}
begin
  result:=False;
  if stree.nType=ntAggregate then result:=true;
  if result=true then exit; //return
  {Recurse left and right sub-trees}
  if stree.leftChild<>nil then if stree.leftChild.nType<>ntSelect then result:=hasAggregate(stree.leftChild);
  if result=true then exit; //return
  if stree.rightChild<>nil then if stree.rightChild.nType<>ntSelect then result:=hasAggregate(stree.rightChild);
end; {hasAggregate}


end.

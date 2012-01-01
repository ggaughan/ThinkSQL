unit uIterSort;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}
//{$DEFINE DEBUGDETAIL3} //duplicate removal

//todo tidy!

interface

uses uIterator, uSyntax, uTransaction, uStmt, uAlgebra, uTuple,
     uFile, uTempTape, uGlobal;

const
  nTempFiles=7;        //number of temporary files (tapes) //todo make flexible?
                       //Note: need to extend FNAME template if max digits changes
  nNodes=20;           //number of nodes for selection tree //todo make flexible?
  FNAME='sort%4.4d_%4.4d_%1.1d';  //temporary filename template (stmt,plan-node,file#) //todo make unique to server etc.
  MaxKeyCol=MaxCol;    //maximum number of sort columns

type
  {Temporary file (tape) wrappers}
  TtFile=class               //hide? - but need to keep in sort class to assist multi-user memory handling
    fp:TTempTape;             //temporary tape file
    fpBuf:array [0..MaxRecSize-1] of char;  //read buffer area
    fpBufLen:integer;                       //read buffer length of current record
    dummy:integer;            //number of dummy runs    D[]
    fib:integer;              //ideal fibonacci number  A[]
    eof:boolean;              //end of file flag
    eor:boolean;              //end of run flag
    valid:boolean;            //true if tuple is valid
  end; {TtFile}

  {Selection tree nodes}
  TiNode=class; //forward
  TeNode=class                      //external node (4+4+4+4+1=17 bytes = 20 bytes)
    parent:TiNode;                  //parent of external node
    rec:PChar;                      //pointer to dynamic tuple record data buffer
    recLen:integer;
    run:integer;                    //run number
    valid:boolean;                  //input tuple is valid
  end; {TeNode}
  TiNode=class                      //internal node (4+4=8 bytes)
    parent:TiNode;                  //parent of internal node
    loser:TeNode;                   //external loser
  end; {TiNode}
  TNode=class                       //(4+4=8 bytes)  e.g. 1000 nodes = 8000 + 8000 + 20000 + rec buffer = 36000+ (e.g. 76000 for 40 char rec buffers)
    i:TiNode;                       //internal node
    e:TeNode;                       //external node
  end; {TNode}

  TIterSort=class(TIterator)
    private
      tFile:array [0..nTempFiles-1] of TtFile;

      level:integer;        //level of runs

      sorted:boolean;       //first call = sort & materialise

      node:array [0..nNodes] of TNode;              //array of selection tree nodes
      win:TeNode;                                   //new winner
      eof:boolean;                                  //end of file, input
      maxrun:integer;                               //maximum run number
      currun:integer;                               //current run number
      lastKeyValid:boolean;                         //true if last key is valid
      lastKey:TTuple;   //buffer to store last key comparison for readTuple
      noMoreData:boolean;                           //input tuple noMore flag (needed to be static by IterNestedLoop)

      tempTuple1,tempTuple2:TTuple;

      distinct:boolean;                             //remove duplicates?

      function CompareTupleKeysLT(tl,tr:TTuple;var res:boolean):integer;
      function CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
      function CompareTupleKeysGT(tl,tr:TTuple;var res:boolean):integer;

      function initTempFiles:integer;
      function deleteTempFiles:integer;
      function termTempFiles:integer;
      function rewindFile(f:integer):integer;
      function readTuple(var noMore:boolean):integer;
      function makeRuns:integer;
      function doMergeSort:integer;

      function mergeSort:integer;
    public
      //TODO: use  keyColMap:array [0..MaxKeyCol] of TKeyColMap;
      //todo use same array/structure as TindexFile...
      //Note: made public so parent iterSet can override them
      keyCol:array [0..MaxKeyCol-1] of record col:colRef; direction:TsortDirection; end; //array of sort columns
      keyColCount:integer;

      function description:string; override;
      function status:string; override;

      constructor create(S:TStmt;itemExprRef:TAlgebraNodePtr;distinctFlag:boolean);
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop

      function GetPosition:cardinal;
      function FindPosition(p:cardinal):integer;
  end; {TIterSort}

implementation

uses uLog, sysUtils, uEvalCondExpr, uHeapFile, uMarshalGlobal;

const
  where='uIterSort';

  fileT=nTempFiles-1;  //last file
  fileP=fileT-1;       //next to last file (P-way merging)

constructor TIterSort.create(S:TStmt;itemExprRef:TAlgebraNodePtr;distinctFlag:boolean);
const routine=':create';
var
  i:integer;
begin
  inherited create(s);
  aNodeRef:=itemExprRef;
  distinct:=distinctFlag;
  sorted:=false;
  for i:=0 to nTempFiles-1 do
  begin
    tFile[i]:=TtFile.Create; //todo: faster if use records & new(TtFilePtr)?
    tFile[i].fp:=TTempTape.Create;
  end;
  for i:=0 to nNodes-1 do //todo check for memory full...
  begin
    node[i]:=TNode.Create;
    node[i].i:=TiNode.Create;
    node[i].e:=TeNode.Create;
  end;
  lastKey:=TTuple.Create(nil);
  tempTuple1:=TTuple.Create(nil);
  tempTuple2:=TTuple.Create(nil);
end; {create}

destructor TIterSort.destroy;
const routine=':destroy';
var i:integer;
begin
  tempTuple2.free;
  tempTuple1.free;
  lastKey.free;
  for i:=nNodes-1 downto 0 do
  begin
    if node[i].e.rec<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('buffer for external node %d was not released',[i]),vAssertion);
      {$ENDIF}
      //continue //abort?
    end;

    node[i].e.free;
    node[i].i.free;
    node[i].free;
  end;
  for i:=nTempFiles-1 downto 0 do
  begin
    tFile[i].fp.Free;
    tFile[i].free;
  end;
  inherited destroy;
end; {destroy}

function TIterSort.description:string;
{Return a user-friendly description of this node
}
begin
  result:=inherited description;
  if distinct then
    result:=result+' (distinct)';
end; {description}

function TIterSort.status:string;
begin
  {$IFDEF DEBUG_LOG}
  if distinct then
    result:=format('TIterSort %d (distinct)',[keyColCount])
  else
    result:=format('TIterSort %d',[keyColCount]);
  if anodeRef<>nil then result:=result+' '+anodeRef.rangeName; //not set for merge-join children
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterSort.prePlan(outerRef:TIterator):integer;
{PrePlans the sort process
 RETURNS:  ok, else fail

 NOTE:
   if the sort is used before an iterSet, the iterSet may
   push down the keyCol array settings after this prePlan
   i.e. once the iterSet preplan has found out the 'corresponding' columns
}
const routine=':prePlan';
var
  nhead:TSyntaxNodePtr;
  i:colRef;
  colName:string;

  cTuple:TTuple; //todo make global?

  cId:TColId;
  cRef:ColRef;
begin
  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    correlated:=correlated OR leftChild.correlated;
  end;
  if result<>ok then exit; //aborted by child

  {Define this ituple from leftChild.ituple}
  iTuple.CopyTupleDef(leftChild.iTuple);

  {Define the temporary tuples to be identical to the input tuple}
  lastKey.CopyTupleDef(leftChild.iTuple);
  tempTuple1.CopyTupleDef(leftChild.iTuple);
  tempTuple2.CopyTupleDef(leftChild.iTuple);

  {Set up the sort key from the column list passed}
  //in future may need to handle expressions here...?
  // - (only for GROUP-BY sort?) although the standard grammar I have only allows column-refs!!!!
  //                             could do SELECT exp as E ... GROUP BY E = legal
  keyColCount:=0;
  if anodeRef=nil then
    nhead:=nil //e.g. sort for joinMerge - no syntax nodes passed at this stage...
  else
  begin
    nhead:=anodeRef.nodeRef;
    //todo remove the following line: overkill, since iterSet will push down the sort-order afterwards... no harm? better to do it this way? = one set of code...
    if (nhead<>nil) and (nhead.nType in [ntCorresponding,ntCorrespondingBy]) then nhead:=nhead.leftChild;
  end;

  i:=0;
  while nhead<>nil do
  begin
    //todo impossible, but double check nhead not nil!

    //todo use new code that relies on complete* routines... although overkill here maybe?

    {todo: take name from column name (pass up?)
        ntSelectItem:
        begin
          n:=n.rightChild; //optional
    }
    //Note: the expression calculators will re-define these if needed anyway - ok?
    colName:=intToStr(i); //default column name
    case nhead.nType of
      ntColumnRef: //todo note: this is from group-by! = no ASC/DESC
      begin
        //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
        //assumes we have a right child! -assert!
        result:=leftchild.iTuple.FindCol(nhead,nhead.rightChild.idval,'',leftchild.outer,cTuple,cRef,cid);
        if result<>ok then
        begin
          if result=-2 then
          begin
            stmt.addError(seSyntaxAmbiguousColumn,format(seSyntaxAmbiguousColumnText,[nhead.rightChild.idval]));
          end
          else
          begin
            stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,['column '+nhead.rightChild.idval]));
          end;
          exit; //abort if child aborts
        end;
        if cid=InvalidColId then
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Unknown column reference (%s)',[nhead.rightChild.idVal]),vError);
          {$ENDIF}
          stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[nhead.rightChild.idVal]));
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        if cTuple<>leftChild.iTuple then //todo relax later when using expressions? if so remember to pull up correlated from any Complete... call
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Column reference (%s) must be in this sub-select',[nhead.rightChild.idVal]),vError);
          {$ENDIF}
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        if keyColCount>=MaxKeyCol-1 then
        begin
          //shouldn't this have been caught before now!?
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('Too many sort columns %d',[keyColCount]),vError);
          {$ENDIF}
          result:=Fail;
          exit; //abort, no point continuing?
        end;
        inc(keyColCount);
        keyCol[keyColCount-1].col:=cRef;
        keyCol[keyColCount-1].direction:=sdASC;

        inc(i); //single column added
      end; {ntColumnRef}
      ntOrderItem:
      begin
        //assumes we have a left child! -assert!
        if (nhead.leftChild.idval='') and (nhead.leftChild.dtype=ctNumeric) then //assume integer //todo check dtype as well/instead?
        begin
          {Note: this is deprecated in SQL-92}
          cRef:=trunc(nhead.leftChild.numVal); //user subscript
          if (cRef<1) or (cRef>iTuple.ColCount) then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column subscript (%d)',[trunc(nhead.leftChild.numVal)]),vError);
            {$ENDIF}
            stmt.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[intToStr(cRef)]));
            result:=Fail;
            exit; //abort, no point continuing?
          end;
          cRef:=cRef-1; //todo check ok to map directly to subscript..
        end
        else
        begin //column name
          //assumes we have a right child! -assert!
          result:=leftchild.iTuple.FindCol(nhead.leftChild,nhead.leftChild.rightChild.idval,'',outer,cTuple,cRef,cid);
          if result<>ok then
          begin
            if result=-2 then
            begin
              stmt.addError(seSyntaxAmbiguousColumn,format(seSyntaxAmbiguousColumnText,[nhead.leftChild.rightChild.idval]));
            end
            else
            begin
              stmt.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,['column '+nhead.leftChild.rightChild.idval]));
            end;
            exit; //abort if child aborts
          end;
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
          if cTuple<>leftChild.iTuple then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Column (%s) must be in this sub-select',[nhead.leftChild.rightChild.idVal]),vError);
            {$ENDIF}
            result:=Fail;
            exit; //abort, no point continuing?
          end;
          if keyColCount>=MaxKeyCol-1 then
          begin
            //shouldn't this have been caught before now!?
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Too many sort columns %d',[keyColCount]),vError);
            {$ENDIF}
            result:=Fail;
            exit; //abort, no point continuing?
          end;
        end;
        inc(keyColCount);
        keyCol[keyColCount-1].col:=cRef;
        keyCol[keyColCount-1].direction:=sdASC; //default
        if nhead.rightChild<>nil then //Retrieve ASC/DESC from nhead.rightChild
          case nhead.rightChild.nType of
            ntASC:  keyCol[keyColCount-1].direction:=sdASC;
            ntDESC: keyCol[keyColCount-1].direction:=sdDESC;
          else
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('Unknown column sort direction',[nil]),vError);
            {$ENDIF}
            //ignore it! ok?
          end; {case}

        inc(i); //single column added
      end; {ntOrderItem}
    else
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Only columns/column references allowed in sort',[nil]),vError);
      {$ENDIF}
      //ignore it! ok?
    end; {case}
    nhead:=nhead.NextNode;
  end; {while}

  if keyColCount=0 then
  begin
    if distinct then //duplicate removal, so sort on all columns
    begin
      for i:=0 to iTuple.ColCount-1 do
      begin
        inc(keyColCount);
        keyCol[keyColCount-1].col:=i;
        keyCol[keyColCount-1].direction:=sdASC;
      end;
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Sorting on all %d columns (for distinct)',[keyColCount]),vDebugLow);
      {$ENDIF}
    end
    else
    begin //assume sort on all columns anyway (was needed for initial pre-iterSet - now pushed down)
      for i:=0 to iTuple.ColCount-1 do
      begin
        inc(keyColCount);
        keyCol[keyColCount-1].col:=i;
        keyCol[keyColCount-1].direction:=sdASC;
      end;
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('Sorting on all %d columns',[keyColCount]),vDebugLow);
      {$ENDIF}
    end;
  end //todo instead assume all columns?
  else
  begin
    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    for i:=0 to keyColCount-1 do
      log.add(stmt.who,where+routine,format('Sorting on column %d',[keyCol[i].col]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;
end; {prePlan}

function TIterSort.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
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

  //todo: optimise sort
  //      ensure projections have been pushed down below here at least
  //      if small result set (expected) then quicksort in memory! - use buffers or keep separate? how to limit...

  if assigned(leftChild) then
  begin
    result:=leftChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL2}
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

function TIterSort.start:integer;
{Start the sort process
 RETURNS:  ok, else fail
}
const routine=':start';
var
  i:integer;
begin
  result:=inherited start;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.start;   //recurse down tree
  if result<>ok then exit; //aborted by child

  {Clear - mainly needed to point scratch data buffer pointer for all columns}
  iTuple.clear(stmt);
  lastKey.clear(stmt);
  tempTuple1.clear(stmt);
  tempTuple2.clear(stmt);

  sorted:=false; //13/05/00 fix: nested iteration of groups called re-start but wasn't re-sorting on 1st call to next!

  {18/11/02 fix: re-execute prepared caused win top errors (moved here from create)}
  for i:=0 to nNodes-1 do
  begin
    node[i].i.loser:=node[i].e;
    node[i].i.parent:=node[i div 2].i;
    node[i].e.parent:=node[(nNodes+i) div 2].i;
    node[i].e.run:=0;
    node[i].e.valid:=False;
    if node[i].e.rec<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('buffer for external node %d was not released',[i]),vAssertion);
      {$ENDIF}
      freemem(node[i].e.rec,node[i].e.recLen); //Note: we don't have to specify the length
      node[i].e.rec:=nil;
      node[i].e.recLen:=0; //todo remove - no need?
    end;
  end;

  {29/03/03 fix: re-execute prepared caused empty results set (not resetting valid)}
  for i:=0 to nTempFiles-1 do
  begin
    tFile[i].dummy:=0;
    tFile[i].fib:=0;
    tFile[i].eof:=false;
    tFile[i].eor:=false;
    tFile[i].valid:=false;
  end;

  win:=node[0].e;
  eof:=False;
  maxrun:=0; //29/03/03 fix: re-execute prepared caused empty results set
  currun:=0; //29/03/03 fix: re-execute prepared caused empty results set
  lastKeyValid:=False;
  noMoreData:=false; //29/03/03 fix: re-execute prepared caused empty results set
end; {start}

function TIterSort.stop:integer;
{Stop the sort process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
  //todo ok/better to continue?.... if result<>ok then exit; //aborted by child
  result:=tFile[fileT].fp.close; //stop materialised scan
  result:=tFile[fileT].fp.delete; //delete materialised scan
end; {stop}

function TIterSort.next(var noMore:boolean):integer;
{Get the next tuple in sort-order
 If this is the first call to next() then we perform the sort & materialise
 the sorted relation, then return the next=first tuple
 (although for now, just in a temp-file)
 RETURNS:  ok, else fail
}
const routine=':next';
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

  if not sorted then
  begin //first call = sort input & materialise
    sorted:=True;
    //todo: when we can determine that the child iterator is already in sorted order, then skip this step & just shallow read child-tuple! -speed!
    result:=mergeSort; //todo need to allow to be interrupted by caller somehow...
    if result<>ok then exit; //abort
  end;

  if not tFile[fileT].fp.noMore then
  begin
    {already sorted, so get next from materialised relation}
    result:=tFile[fileT].fp.readRecord(tFile[fileT].fpBuf,tFile[fileT].fpBufLen);
    if result<>ok then exit; //abort

    result:=iTuple.CopyBufferToData(tFile[fileT].fpBuf,tFile[fileT].fpBufLen);
    noMore:=False;  //todo: bug? we should not need this. Similar problem in materialise.next was because .stop was called but should have delayed closing children until 'really' done
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end
  else  //end of tape
    noMore:=True;
end; {next}


{Expose materialised positioning from final tape
 - initially used by join merge for bookmarking a block
}
function TIterSort.GetPosition:cardinal;
begin
  if not sorted then
    result:=0
  else
    result:=tFile[fileT].fp.GetPosition;
end; {GetPosition}
function TIterSort.FindPosition(p:cardinal):integer;
begin
  if not sorted then
    result:=fail
  else
  begin
    result:=tFile[fileT].fp.FindPosition(p);
  end;
end; {FindPosition}


//combine these two routines - or use the ones from EvalCondExpr
//eventually we will call EvalExpr to allow non-column orderings... eg. ORDER BY tot*2
function TIterSort.CompareTupleKeysLT(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l < r

 Assumes:
 keyCol array has been defined
 both tuples have same column definitions

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'

 Takes account of sort direction for each column (reverses test result for DESCending)
}
const routine=':compareTupleKeysLT';
var
  cl:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<keyColCount) do
  begin
    result:=tl.CompareCol(stmt,keyCol[cl].col,keyCol[cl].col,tr,resComp,resNull);
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(keyCol[cl].col,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(keyCol[cl].col,resNull);
        if result<>ok then exit; //abort
        if resNull then
          resComp:=0   //both are null so treat as equal (SQL anomaly!)
        else
          resComp:=NullSortOthers;
      end
      else
        resComp:=-NullSortOthers;
    end;
    if keyCol[cl].direction=sdDESC then resComp:=-resComp; //reverse direction
    inc(cl);
  end;
  if resComp<0 then res:=True else res:=False;
end; {CompareTupleKeysLT}
function TIterSort.CompareTupleKeysEQ(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l = r

 Assumes:
 keyCol array has been defined
 both tuples have same column definitions

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1<b.key1 and a.key2<b.key2...'
 - this would allow sorts such as Order by name||'z'

 Takes account of sort direction for each column (reverses test result for DESCending)
}
const routine=':compareTupleKeysEQ';
var
  cl:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<keyColCount) do
  begin
    result:=tl.CompareCol(stmt,keyCol[cl].col,keyCol[cl].col,tr,resComp,resNull);
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(keyCol[cl].col,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(keyCol[cl].col,resNull);
        if result<>ok then exit; //abort
        if resNull then
          resComp:=0   //both are null so treat as equal (SQL anomaly!)
        else
          resComp:=NullSortOthers;
      end
      else
        resComp:=-NullSortOthers;
    end;
    if keyCol[cl].direction=sdDESC then resComp:=-resComp; //reverse direction
    inc(cl);
  end;
  if resComp=0 then res:=True else res:=False;
end; {CompareTupleKeysEQ}
function TIterSort.CompareTupleKeysGT(tl,tr:TTuple;var res:boolean):integer;
{Compare 2 tuple keys for l > r

 Assumes:
 keyCol array has been defined
 both tuples have same column definitions

 Note:
 in future, may need to call EvalCondExpr() with 'a.key1>b.key1 and a.key2>b.key2...'
 - this would allow sorts such as Order by name||'z'

 Takes account of sort direction for each column (reverses test result for DESCending)
}
const routine=':compareTupleKeysGT';
var
  cl:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=False;
  cl:=0;

  //todo make into an assertion: if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  //todo speed logic
  resComp:=0;
  while (resComp=0) and (cl<keyColCount) do
  begin
    result:=tl.CompareCol(stmt,keyCol[cl].col,keyCol[cl].col,tr,resComp,resNull);
    if result<>ok then exit; //abort if compare fails
    if resNull then
    begin
      result:=tl.ColIsNull(keyCol[cl].col,resNull);
      if result<>ok then exit; //abort
      if resNull then
      begin
        result:=tr.ColIsNull(keyCol[cl].col,resNull);
        if result<>ok then exit; //abort
        if resNull then
          resComp:=0   //both are null so treat as equal (SQL anomaly!)
        else
          resComp:=NullSortOthers;
      end
      else
        resComp:=-NullSortOthers;
    end;
    if keyCol[cl].direction=sdDESC then resComp:=-resComp; //reverse direction
    inc(cl);
  end;
  if resComp>0 then res:=True else res:=False;
end; {CompareTupleKeysGT}

function TIterSort.initTempFiles:integer;
{Initialise the temp files
 RETURNS:   ok, else fail
}
const routine=':initTempFiles';
var
  i:integer;
  r:integer;
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'initialising temp files',vDebugLow);
  {$ENDIF}
  {$ENDIF}
  if nTempFiles<3 then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('must have more than 3 temp files (%d)',[nTempFiles]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;

  for i:=0 to nTempFiles-1 do
  begin
    {Open each new relation ready for writing to}
    r:=trunc(random(9999)); //todo DEBUG ONLY - REMOVE!! need to make file unique to trans+node! i.e. SYS-getNextFilename!
    result:=tFile[i].fp.CreateNew(format(FNAME,[stmt.Rt.tranId,r,i]));
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,'initialising temp file: '+format(FNAME,[stmt.Rt.tranId,r,i]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    if result<>ok then exit; //abort
  end;
end; {initTempFiles}

function TIterSort.deleteTempFiles:integer;
{Delete temp files, except final relation
 RETURNS:    ok, else fail
}
const routine=':deleteTempFiles';
var
  i:integer;
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'deleting temp files:',vDebugLow);
  {$ENDIF}
  {$ENDIF}

  for i:=0 to fileT-1 do
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('  %s',[tFile[i].fp.filename]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    result:=tFile[i].fp.close;
    result:=tFile[i].fp.delete;
    //we don't clean up allocations until Iter is finished
  end;
end; {deleteTempFiles}

function TIterSort.termTempFiles:integer;
{Clean up files & restart scan on final output relation
 RETURNS:  ok, else fail
}
const routine=':termTempFiles';
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'finalising temp files',vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {file[T] contains results}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('re-opening results file %d',[fileT]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=tFile[fileT].fp.rewind;
  //todo check result...

  result:=deleteTempFiles;
end; {termTempFiles}

function TIterSort.rewindFile(f:integer):integer;
{Rewinds the temp file ready for a pass.
 The file scan is (re-)started and the first tuple is read.
 The tFile[] end-of-file flag is set appropriately.

 IN:       f   - the file number
 RETURNS:  ok, else fail
}
const routine=':rewindFile';
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('rewinding file %d',[f]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  tFile[f].eor:=False;
  tFile[f].eof:=False;
  tFile[f].fp.rewind;
  //todo check result...
  if tFile[f].fp.noMore then
  begin
    if result<>ok then exit; //abort
    tFile[f].eor:=True;
    tFile[f].eof:=True;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('initial record read = eof from file %d',[f]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    result:=tFile[f].fp.readRecord(tFile[f].fpBuf,tFile[f].fpBufLen);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('initial record read from file %d: %s',[f,tFile[f].fpBuf]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;
end; {rewindFile}

function TIterSort.readTuple(var noMore:boolean):integer;
{Read next tuple using replacement selection
 Algorithm from Knuth volume 3.

 OUT:      noMore      - no more tuples left (end of input)
           iTuple      - the next tuple

 RETURNS:  ok, else fail

 Note:
   we (over-)use iTuple to return the next tuple
   //todo return in temp buffer area

//todo replace with fixed heap array?
//also - use buffer pages to store such dynamic memory
//       to save the Delphi heap from being ragged
}
const routine=':readTuple';
var
  p:TiNode;                                     //pointer to internal nodes
  t:TeNode;                                     //pointer for swapping
  swap:boolean;
  res:boolean;
begin
  result:=ok;
  while True do
  begin
    {replace previous winner with new tuple}
    if not eof then
    begin
      if assigned(leftChild) then
      begin
        result:=leftChild.next(noMoreData);   //recurse down tree (this input will be buffered)
        if result<>ok then exit; //abort
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('  reading %s',[leftChild.iTuple.show(stmt)]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        if not noMoreData then
        begin
          {copy leftChild.iTuple data to new win.rec buffer}
          //todo: note this copy routine is probably relatively slow... (we need to account for multiple versions of buffers from child)
{$IFDEF DEBUG_LOG}
//          log.quick('tuple= '+leftChild.iTuple.show+'');
{$ENDIF}
{$IFDEF DEBUG_LOG}
//          log.quick('tuple= ['+leftChild.iTuple.showMap+']');
{$ENDIF}
          result:=leftChild.iTuple.CopyDataToBuffer(win.rec,win.recLen);
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.quick('win.rec ['+intToStr(win.recLen)+']='+win.rec+']');
          {$ENDIF}
          {$ENDIF}
          if lastKeyValid then
            result:=CompareTupleKeysLT(leftChild.iTuple,lastKey,res)
          else
            res:=False; //speed?
          if result<>ok then exit;
          if not(lastKeyValid) or res then
          begin
            inc(win.run);
            if win.run>maxRun then maxRun:=win.run;
          end;
          win.valid:=True;
        end
        else
        begin
          //todo: maybe leftChild.stop now? - may as well!
          eof:=true;
          win.valid:=False;
          win.run:=maxRun+1;
        end;
      end;
    end
    else
    begin
      win.valid:=False;
      win.run:=maxrun+1;
    end;

    {Adjust loser and winner pointers}
    p:=win.parent;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('loser.run=%d winner.run=%d',[p.loser.run,win.run]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    repeat
      swap:=False;
      if p.loser.run < win.run then
        swap:=True
      else
        if p.loser.run = win.run then
          if p.loser.valid and win.valid then
          begin
            {prepare tuples for compare - just copy/repoint data blocks}
            tempTuple1.CopyBufferToData(p.loser.rec,p.loser.recLen);
{$IFDEF DEBUG_LOG}
//          log.quick('temptuple1(p.loser)= '+tempTuple1.show+'');
{$ENDIF}
{$IFDEF DEBUG_LOG}
//          log.quick('temptuple1(p.loser)= ['+tempTuple1.showMap+']');
{$ENDIF}
            tempTuple2.CopyBufferToData(win.rec,win.recLen);
{$IFDEF DEBUG_LOG}
//          log.quick('temptuple2(win)= '+tempTuple2.show+'');
{$ENDIF}
{$IFDEF DEBUG_LOG}
//          log.quick('temptuple2(win)= ['+tempTuple2.showMap+']');
{$ENDIF}
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('about to compare for swap loser %s and winner %s',[tempTuple1.show(stmt),tempTuple2.show(stmt)]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            result:=CompareTupleKeysLT(tempTuple1,tempTuple2,res);
            if result<>ok then exit; //abort
            if res then swap:=True;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            if swap then log.add(stmt.who,where+routine,format('about to swap loser %s and winner %s',[tempTuple1.show(stmt),tempTuple2.show(stmt)]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end
          else
            swap:=true;
      if swap then
      begin
        {p should be winner}
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('swapping loser [%d] run %d and winner [%d] run %d',[p.loser.recLen,p.loser.run,win.recLen,win.run]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        t:=p.loser;
        p.loser:=win;
        win:=t;
      end;
      p:=p.parent;
    until p=node[0].i;

    {end of run?}
    if win.run<>currun then
    begin
      {win.run=currun+1}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('end of run? %d %d',[win.run,maxrun]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      if win.run>maxrun then
      begin
        {end of output}
        //free node array //todo should do, since this is only the initialisation part
        noMore:=True;
        exit; //done
      end;
      currun:=win.run;
    end;

    {output top of tree}
    if win.run>0 then
    begin
      {$IFDEF DEBUG_LOG}
      if not win.valid then  //04/01/02 after multiple group-bys naturally joined failed (but seem ok separately)
      begin //not sure what this means, but we have no valid record to return
        log.add(stmt.who,where+routine,format('not win.valid for top of tree',[nil]),vAssertion);
        if win.rec<>nil then log.add(stmt.who,where+routine,'  win.rec ['+intToStr(win.recLen)+']='+win.rec+']',vAssertion); //never seems to happen
        exit; //todo abort altogether?
      end;
      {$ENDIF}
      lastKey.CopyBufferToData(win.rec,win.recLen);
      lastKeyValid:=True;
      noMore:=False;
      iTuple.CopyBufferToData(win.rec,win.recLen);
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('returning %s',[win.rec]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('deallocating %d byte buffer',[win.recLen]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      {now we can/must dispose of win.rec buffer memory}
      //todo allocate/deallocate these blocks via buffer pages: difficult?
      //     or at least allocate/deallocate them in fixed chunks via an allocator
      freemem(win.rec,win.recLen); //Note: we don't have to specify the length
      win.rec:=nil; //todo set reclen=0?
      exit; //done
    end;

  end; {while}
end; {readTuple}

function TIterSort.makeRuns:integer;
{Makes initial runs using replacement selection.
 Runs are written using a Fibonacci distribution.

 RETURNS:   ok, else fail
}
const routine=':makeRuns';
var
  //we use iTuple as win
  j:integer;           //selects tFile[j]
  res, res2:boolean;         //comparison result
  noMore:boolean;      //end of input file

  anyRun, run:boolean;

  a:integer;          //temp
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'creating initial runs',vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {Initialise file structures}   //D1
  for j:=0 to fileT-1 do
  begin
    tFile[j].fib:=1;
    tFile[j].dummy:=1;
  end;
  tFile[fileT].fib:=0;
  tFile[fileT].dummy:=0;

  level:=1;
  j:=0; //todo remove - dead code?

  result:=readTuple(noMore);
  if result<>ok then exit; //abort (?)
  while not noMore do
  begin
    anyrun:=False;
    j:=0;
    while not(noMore) and (j<=fileP) do
    begin
      run:=False;
      if tFile[j].valid then
      begin
        result:=tempTuple1.CopyBufferToData(tFile[j].fpBuf,tFile[j].fpBufLen);
        if result<>ok then exit; //fail
        result:=CompareTupleKeysLT(iTuple,tempTuple1,res);
        if not res then
          run:=True //append to an existing run
        else
          if tFile[j].dummy>0 then
          begin //start a new run
            dec(tFile[j].dummy);
            run:=True;
          end;
      end
      else
      begin //first run in file
        dec(tFile[j].dummy);
        run:=True;
      end;

      if run then
      begin
        anyrun:=True;
        //flush run
        while True do
        begin
          //todo speed up?
          result:=iTuple.CopyDataToFixedBuffer(tFile[j].fpBuf,tFile[j].fpBufLen); //todo skip this step?
          result:=tFile[j].fp.WriteRecord(tFile[j].fpBuf,tFile[j].fpBufLen);

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(stmt.who,where+routine,format('run flushed to file %d: %s',[j,tFile[j].fpBuf]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          if result<>ok then exit; //abort
          tFile[j].valid:=True;
          repeat
            result:=readTuple(noMore);
            if result<>ok then exit; //abort (?)
            if noMore then break;
            result:=tempTuple1.CopyBufferToData(tFile[j].fpBuf,tFile[j].fpBufLen);
            if result<>ok then exit; //fail
            result:=CompareTupleKeysLT(iTuple,tempTuple1,res);
            //todo check result
            if res then break;
            if distinct then
              result:=CompareTupleKeysEQ(iTuple,tempTuple1,res2)
            else
              res2:=false; //speed
            //todo check result
            {$IFDEF DEBUGDETAIL3}
            if distinct and res2 then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('duplicate record skipped during run creation %d: %s',[j,tFile[j].fpBuf]),vDebugLow);
              {$ENDIF}
              {$IFDEF DEBUG_LOG}
              log.add(stmt.who,where+routine,format('  %s',[iTuple.show(stmt)]),vDebugLow);
              {$ENDIF}
            end;
            {$ENDIF}
          until not distinct or not res2; //until we have a non-duplicate
          if noMore then break;
          if res then break;
        end;
      end;
      //next
      inc(j);
    end;

    {if no room for runs, up a level}     //D4
    if not anyrun then
    begin
      inc(level);
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('next level: %d: shifting logical tapes',[level]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      a:=tFile[0].fib;
      for j:=0 to fileP do
      begin
        tFile[j].dummy:=a+tFile[j+1].fib-tFile[j].fib;
        tFile[j].fib:=a+tFile[j+1].fib;
      end;
    end;

  end; {while}
end; {makeRuns}

function TIterSort.doMergeSort:integer;
{Merge the initial sorted runs into the final output file.
 This may make repeated passes if necessary, but it's polyphase so it won't needlessly
 copy runs from one file to another.
 Algorithm from Knuth volume 3.

 RETURNS:  ok, else fail
}
const routine=':doMergeSort';
var
  j:integer;           //selects tFile[j]
  k:integer;
  res:boolean;         //comparison result
  tempfile:TtFile;

  allDummies,anyRuns:boolean;
begin
  result:=ok;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,'starting merge',vDebugLow);
  {$ENDIF}
  {$ENDIF}

  lastKeyValid:=False; //we re-use lastKey in this routine //31/12/00 ok?

  {polyphase merge sort}

  {prime the files}
  for j:=0 to fileT-1 do
  begin
    result:=rewindFile(j);
    if result<>ok then exit; //abort
  end;

  {each pass through loop merges one run}
  while level>0 do
  begin
    //todo: is this the best place for the cancelled test? maybe readTuple?
    if stmt.status=ssCancelled then
    begin
      result:=Cancelled;
      exit;
    end;

    while True do
    begin
      {scan for runs}
      allDummies:=True;
      anyRuns:=False;
      for j:=0 to fileP do
      begin
        if tFile[j].dummy=0 then
        begin
          allDummies:=False;
          if not tFile[j].eof then anyRuns:=True;
        end;
      end;

      if anyRuns then
      begin
        {merge 1 run file[0]..file[P] -> file[T]}
        while True do
        begin
          {each pass through loop writes 1 record to file[fileT]}
          {find smallest key}
          k:=-1;
          for j:=0 to fileP do
          begin
            if tFile[j].eor then continue;
            if tFile[j].dummy>0 then continue;
            if not(k<0) {todo check logic! and not(k<>j) } then
            begin
              result:=tempTuple1.CopyBufferToData(tFile[k].fpBuf,tFile[k].fpBufLen);
              if result<>ok then exit; //fail
              result:=tempTuple2.CopyBufferToData(tFile[j].fpBuf,tFile[j].fpBufLen);
              if result<>ok then exit; //fail
              result:=CompareTupleKeysGT(tempTuple1,tempTuple2,res);
              if result<>ok then exit; //abort
            end;
            if (k<0) or ( (k<>j) and res ) then
              k:=j;
          end;

          if k<0 then break;

//todo ok? debug: extra section for duplicate removal
          if distinct and lastKeyValid{31/12/00 ok?} then
          begin
            result:=tempTuple1.CopyBufferToData(tFile[k].fpBuf,tFile[k].fpBufLen);
            if result<>ok then exit; //fail
            result:=CompareTupleKeysEQ(tempTuple1,lastKey,res);
          end
          else
            res:=False;
          if not res then
          begin
//debug end
            {write record[k] to file[fileT]}
            //speed up?
            result:=tFile[fileT].fp.WriteRecord(tFile[k].fpBuf,tFile[k].fpBufLen);
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('record written to file %d: %s',[fileT,tFile[k].fpBuf]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            if result<>ok then exit; //abort

            {replace record[k]} //just copy key columns (?) -speed
            result:=lastKey.CopyBufferToData(tFile[k].fpBuf,tFile[k].fpBufLen);
            lastKeyValid:=True; //31/12/00 ok?
            if result<>ok then exit; //fail
//debug restart
          end
          else
          begin
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('duplicate record not written to file %d: %s',[fileT,tFile[k].fpBuf]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;
//debug part 2 end
          if not tFile[k].fp.noMore then
          begin
            result:=tFile[k].fp.ReadRecord(tFile[k].fpBuf,tFile[k].fpBufLen);
            if result<>ok then exit; //abort
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(stmt.who,where+routine,format('record read from file %d: %s',[k,tFile[k].fpBuf]),vDebugLow);
            {$ENDIF}
            {$ENDIF}

            result:=tempTuple1.CopyBufferToData(tFile[k].fpBuf,tFile[k].fpBufLen);
            if result<>ok then exit; //fail
            result:=CompareTupleKeysLT(tempTuple1,lastKey,res);
            if result<>ok then exit; //abort
            if res then
              tFile[k].eor:=True;
          end
          else
          begin
            tFile[k].eof:=True;
            tFile[k].eor:=True;
          end;
        end; {while}

        {fixup dummies}
        for j:=0 to fileP do
        begin
          if tFile[j].dummy>0 then dec(tFile[j].dummy);
          if not tFile[j].eof then tFile[j].eor:=False;
        end;
      end
      else
      begin
        if allDummies then
        begin
          for j:=0 to fileP do
            dec(tFile[j].dummy);
          inc(tFile[fileT].dummy);
        end;
      end;

      {end of run}
      if tFile[fileP].eof and not(tFile[fileP].dummy>0) then
      begin
        {completed fibonacci level}
        dec(level);
        if level=0 then
        begin
          {we're done, file[fileT] contains data}
          exit;
        end;

        {fileP is exhausted, reopen as new}
        tFile[fileP].fp.rewind;
        result:=tFile[fileP].fp.truncate;
        if result<>ok then exit; //abort
        tFile[fileP].eof:=False;
        tFile[fileP].eor:=False;

        rewindFile(fileT);

        {Rotate file array so we switch output to the newly exhausted input file
         f[0],f[1]...,f[fileT] <- f[fileT],f[0]...,f[T-1]}
        tempFile:=tFile[fileT];
        for j:=fileT-1 downto 0 do
        begin
          tFile[j+1]:=tFile[j];
        end;
        tFile[0]:=tempFile;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('rotated files',[1]),vDebugLow);
        {$ENDIF}
        {$ENDIF}

        {start new runs}
        for j:=0 to fileP do
          if not tFile[j].eof then tFile[j].eor:=False;
      end;
    end; {while}
  end; {level}
end; {doMergeSort}

function TIterSort.mergeSort:integer;
{Sort the input relation into a temporary file
 RETURNS:  ok, else fail
}
const routine=':mergeSort';
begin
  //todo if only a few tuples, we should quicksort them in memory instead...
  result:=initTempFiles;
  {$IFDEF DEBUG_LOG}
  log.status; //memory display
  {$ENDIF}
  if result<>ok then exit; //abort
  try
    result:=makeRuns;
    if result<>ok then exit;
    result:=doMergeSort;
  finally
    if termTempFiles<>ok then
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,'Failed deleting temporary sort files',vError); //todo: note still return ok if sort worked
      {$ELSE}
      ;
      {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.status; //memory display
    {$ELSE}
    ;
    {$ENDIF}
  end; {try}
end; {mergeSort}

end.

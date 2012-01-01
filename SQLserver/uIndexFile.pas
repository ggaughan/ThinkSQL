unit uIndexFile;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE SAFETY}
//{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2} //debug match failures due to indexState<>isok

{Note: Trelation is responsible for completing most of this structure
}

interface

uses uFile, uStmt, uGlobal, uGlobalDef, uPage, uTuple;

type
  {Map index columns onto tuple columns. ColMap subscription=KeyId, i.e. key-col-left-to-right-position}
  TColMapNode=record
    cref:ColRef;
    cid:TColId;
  end; {TColMapNode}
  {Note: subscript starts at 1 to mirror disk storage of index column_sequence & since InvalidKeyId=0}
  TColMapArray=array [1..MaxCol] of TColMapNode;

  TIndexFile=class(TDBFile)
  private
    fIndexId:integer;           //index_id in system catalog
    fIndexOrigin:string;        //e.g. ioSystem or ioUser
    fIndexConstraintId:integer; //if indexOrigin=ioSystemConstraint then constraintId, else 0=null=n/a
    fIndexState:TindexState;    //e.g. isOk or isBeingBuilt
    fColCount:ColRef;

    procedure SetColCount(v:ColRef);
  public
    Owner:Tobject;          //relation owner (=access to its tuple for inserting etc.)
                            //set by caller

    //we expose these because they are always set by higher-level caller and/or child class
    ColMap:TColMapArray;    //key definition: map to relation's tuple column subscripts
    fTupleKey:TTuple;        //key data used for searching
                             //definition set by owner relation during open

    property indexId:integer read fIndexId write fIndexId;
    property indexOrigin:string read fIndexOrigin write fIndexOrigin;
    property indexConstraintId:integer read findexConstraintId write findexConstraintId;
    property indexState:TindexState read fIndexState write fIndexState;
    property ColCount:ColRef read fColCount write SetColCount;

    constructor Create; override;
    destructor Destroy; override;

    function createFile(st:Tstmt;const fname:string):integer; override;
    function openFile(st:Tstmt;const filename:string;startPage:PageId):integer; override;
    function freeSpace(st:Tstmt;page:TPage):integer; override;

    function AddKeyPtr(st:Tstmt;t:TTuple;rid:Trid):integer; virtual; abstract;
    {todo!!! AddKeyPtr at this level should:
        if indexState=isBeingBuilt then
          if rid>lastRid added by rebuilder transaction then
            ignore & return: a reference to this rid will be added by the rebuilder soon

     At the moment we risk adding entries that another transaction rebuilding the index will add again
     but this is worth the risk of extra noise because otherwise the rebuild would miss concurrent updates
     i.e. we'd need to stop all use of the relation to re-index!
     To support the new behaviour, we need a centralised list of [index_id,lastRid added by rebuilder]
    }

    function Match(st:Tstmt;FindData:TTuple;maxColId:integer):boolean; virtual;

    //design note: there are similar functions defined at TheapFile level - maybe merge to common TdbFile level?
    function FindStart(st:Tstmt;FindData:TTuple):integer; virtual; abstract;
    function FindNext(st:Tstmt;var noMore:boolean;var RID:Trid):integer; virtual; abstract;
    function FindStop(st:Tstmt):integer; virtual; abstract;

    function FindStartDuplicate(st:Tstmt):integer; virtual; abstract;
    function FindNextDuplicate(st:Tstmt;var noMore:boolean;var RID1,RID2:TRid):integer; virtual; abstract;
    function FindStopDuplicate(st:Tstmt):integer; virtual; abstract;

    function OrderColRef:integer;
  end; {TIndexFile}

implementation

uses uLog, SysUtils, classes {for TBits}, uTransaction;

const
  who='';
  where='uIndexFile';

constructor TIndexFile.Create;
const routine=':create';
begin
  inherited Create;
  Owner:=nil; //set by caller
  fColCount:=0;
  fTupleKey:=TTuple.Create(self);
end; {Create}
destructor TIndexFile.Destroy;
begin
  //maybe if owner=nil - warning 'never used properly' ?
  fTupleKey.free;
  inherited destroy;
end;

function TIndexFile.createFile(st:TStmt;const fname:string):integer;
{Creates an index file in the specified database
 IN       : db          the database
          : fname       the new filename
 RETURN   : +ve=ok, else fail
}
const routine=':createFile';
begin
  result:=inherited CreateFile(st,fname);
  if result=ok then
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Index-file %s created',[fname]),vDebug);
    {$ELSE}
    ;
    {$ENDIF}
end; {createFile}

function TIndexFile.openFile(st:TStmt;const filename:string;startPage:PageId):integer;
{Opens an index file in the specified database
 i.e. goes to the file's page directory header page
 IN       : db          the database
          : filename    the existing filename
          : startPage   the start page for this file (found by caller from catalog)
 RETURN   : +ve=ok, else fail

 Side effects:
   sets fStartPage for this file
   sets fname for this file

 Assumes:
   filename and startpage are valid
}
const routine=':openFile';
begin
  result:=inherited openFile(st,filename,startPage);

  if result=ok then
  begin
    //goto first record?
  end;
end; {openFile}

function TIndexFile.freeSpace(st:TStmt;page:TPage):integer;
{Returns amount of free record space in the specified page
 IN      : page    the page to examine
 RETURN  : the amount of free space

 Note: this is not necessarily contiguous free space

 Assumes:
   we have the page pinned
   (& latched if we are going to make use of the result...)
}
const routine=':freeSpace';
var
  parentFreeSpace:integer;
begin
  parentFreeSpace:=inherited freeSpace(st,page); //starting point
  result:=parentFreeSpace;
end; {FreeSpace}


procedure TIndexFile.SetColCount(v:ColRef);
begin
  {$IFDEF SAFETY}
  if (v>maxCol) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+':setColCount',format('Column count %d is beyond limits 0..%d',[v,maxCol]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway - this means we'll get a failure sometime later...
  end;
  {$ENDIF}

  if v<>fColCount then
  begin
    fColCount:=v;
  end;
end; {SetColCount}

function TIndexFile.OrderColRef:integer;
{Sort the colMap array by colRef
 - used by index reading routines to ensure ordered by column sequence
 - cref is used to temporarily read in column sequence which then becomes the subscript after this routine
   (so we can use cref for its true purpose of cref to the tuple column)
}
const routine=':OrderColDef';
var
  i:colRef;
  tempColNode:TColMapNode;
begin
  result:=fail;

  //todo improve - this uses a naff bubble sort - use quick-sort (or originally read using an index/sort!)
  if colCount>0 then
    repeat
      i:=1;
      while (i<ColCount) do
      begin
        if ColMap[i].cRef > ColMap[i+1].cRef then
          break; //swap these
        inc(i);
      end;

      if i<>ColCount then
      begin //swap needed
        {do the swap}
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column mapping %d has cRef %d and has been bubbled up to %d',[i,ColMap[i].cRef,i+1]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        tempColNode:=ColMap[i];
        ColMap[i]:=ColMap[i+1];
        ColMap[i+1]:=tempColNode;
      end;
    until i=ColCount;
  result:=ok;
end; {OrderColRef}

function TIndexFile.Match(st:TStmt;FindData:TTuple;maxColId:integer):boolean;
{Checks if this index matches the search data definition (& is available for use in searching)
 IN:            tr           - transaction
                findData     - the data to find
                               (we use the keyId's to identify the key parts)
                maxColId     - the maximum possible colId (used for bitmap array sizing)

 RETURNS:       True if it matches
                False otherwise

 Assumes:
   this matches all or nothing so we don't need to match on the key-part order
   (i.e. 1,2,3 will match 2,3,1 etc. - which is fine for our current hash indexing
    but would limit the use of future btree indexing)

 Note:
   we used colIds for matching (not crefs)

   The SARG-local-optimisation routines match the other way:
     i.e. we have a number of candidate equality SARGs, are all columns of an index matched/covered?

   If this index state is not isOk (e.g. isBeingBuilt) then this function returns False.
}
const routine=':Match';
var
  i:colRef;
  inBoth:TBits;
begin
  result:=True; //assume true until proved otherwise

  {We need to ensure both arrays have only common columns and that neither has extra}
  inBoth:=TBits.Create;
  try
    inBoth.size:=maxColId+1; //starts at 0 so we need an extra 1 to be able to subscript naturally from 1
    {Set for all parts of this index}
    for i:=1 to colCount do
      inBoth.Bits[colMap[i].cid]:=True;
    {Now check for all key parts of this search data}
    for i:=0 to findData.colCount-1 do
      if findData.fColDef[i].keyId<>InvalidKeyId then
      begin
        if not inBoth.Bits[findData.fColDef[i].id] then
        begin //column is in search key but was not in this index
          result:=False;
          break;
        end;
      end
      else
      begin
        if inBoth.Bits[findData.fColDef[i].id] then
        begin //column was in this index but is not in search key
          result:=False;
          break;
        end;
      end;
  finally
    inBoth.free;
  end; {try}

  if result then
    if indexState<>isOk then
    begin
      result:=False;
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Index (%d columns, %d=max id) matched search data (%d columns) but the index status is %d',[colCount,maxColId,findData.colCount,ord(indexState)]),vDebugMedium)
      {$ENDIF}
      {$ENDIF}
    end;

  //Debug reporting only:
  {$IFDEF DEBUGDETAIL}
  if result then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Index (%d columns, %d=max id) matched search data (%d columns)',[colCount,maxColId,findData.colCount]),vDebugLow)
    {$ENDIF}
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Index (%d columns, %d=max id) did not match search data (%d columns)',[colCount,maxColId,findData.colCount]),vDebugLow)
    {$ELSE}
    ;
    {$ENDIF}
  {$ENDIF}
end; {Match}


end.

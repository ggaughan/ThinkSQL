unit uTuple;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Tuple mapping onto file records for a particular relation
 Provides versioning during tuple-reads and updates
 Also used for system tuples, e.g. system catalog
 Also used for in-memory tuples, e.g. condition comparisons
 And for column manipluations and comparisons
 And for relation search definition and matching
 And for index search definition and matching
 And uses owner (relation) link to maintain index entries (may move to Trelation?)


 Note: check that no outside routines use any of the current tuple
 storage properties e.g. if nextCOff-coff=0 then null.
}

{$DEFINE SAFETY}  //use assertions
                  //Note: Should be no reason to disable these, except maybe small speed increase & small size reduction
                  //      Disabling them would cause more severe crashes (access violations) if an assertion fails
                  //      - at least with them enabled, the server will generate an assertion error message
                  //        and should abort the routine fairly gracefully
                  //      so if they are ever turned off, the code should be thoroughly re-tested and the limits
                  //      stretched to breaking (probably even then only with selective ones disabled)
//{$DEFINE ZEROISE_BUFFERS} //debug aid only: remove when live for extra speed

//{$DEFINE DEBUGDETAIL}  //debug detail
//{$DEFINE DEBUGDETAIL2} //debug versioning detail
{$DEFINE DEBUGDETAIL3}   //debug memory leak
//{$DEFINE DEBUGCOLUMNDETAIL}  //debug column reading detail
//{$DEFINE DEBUGCOLUMNDETAIL2} //debug column old-values copy detail
//{$DEFINE DEBUGCOLUMNDETAILID} //debug column id/sort detail
{$DEFINE DEBUGCOLUMNDETAIL_BLOB} //debug blob detail & allocation counts
//{$DEFINE DEBUGINDEXDETAIL}  //debug index maintenance detail
//{$DEFINE DEBUGCOPYDETAIL}  //debug copy data detail (initially for if nil, dump tuple)
//{$DEFINE DEBUGRID}           //debug display RIDs on all tuple shows
//{$DEFINE DEBUGCOERCION}      //debug automatic column type coercion
//{$DEFINE DEBUGDATETIME}      //debug date-time routines
//{$DEFINE DEBUG_ALIAS}         //debug sourceRange (alias) for column headings in showHeading

{$DEFINE NILTONULL} //prevent crash and return null if getX finds dataptr=nil
                    //(should never happen, but maybe better to prevent Access violation sometimes by uncommenting this?)
                    //Can happen if user says: WHERE max(name)... i.e. invalid syntax -> access violation = too severe so enabled this until we trap the error earlier

//{$DEFINE SKIP_GARBAGE_DELETE}  //skip actual record zapping action of garbageCollect routine
//{$DEFINE SKIP_BLOB_DELETE}     //skip blob zapping action of deleteBlobData

{todo:
 check all callers of shallow dataPtr copy and maybe ensure that they increment the buffer-usage count
 so that if the original tuple is zapped, we can still reference the page
 - this might mean we can replace some deep copies with this new protected shallow copy and the code
 won't break - see Group and Join routines for example =speed,
                   also evalExpr sometimes does deep but maybe now can always shallow?
}

interface

uses uFile, uPage, uStmt, uGlobalDef, uGlobal,
uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for date/time structures},
uSyntax{for catalog.schema finding from node}
;

const
  InvalidColId=0;     //0 is invalid (also reserved for end-marker)
  InvalidKeyId=0;     //0 is invalid=not part of key
  PadChar=' ';        //pad character to fill CHAR() fixed length strings

  NullSortOthers=1;    //determines sort order of nulls (used by IterSort, IterJoin... etc)
                       //1  = nulls come after others
                       //-1 = nulls come before others


type
  TColId=word;                       //unique column id
                                     //Note: if changes from atom check sizeof(TcolId) references

  ColOffset=word;                    //column offset stored in tuple header (limits col size=65535)
                                     //Note: if changes from atom check sizeof(coloffset) references

  TColDef=record
    {Definition}
    //note: any modifications may affect server & client CLI get/put parameters
    //also: some of the basics are duplicated throughout the syntax tree nodes
    id:TColId;                          {used to set dynamic data after record read
                                         (also use to give columns a natural order for 'select *' and 'insert values')
                                         (note: this is stored on disk with each column slot data offset)

                                         We can compress version records into a list of differences, each
                                         prefixed with their column-id.
                                         (and ignore future/hidden column-id's)
                                        }
    name:string  ;                      //user reference
    sourceRange:pointer; {TAlgebraNodePtr;}        //algebraNode - used to find range name
    sourceTableId:integer; //source table_id - used for privilege check after joins etc.
    sourceAuthId:TAuthId;  //source table_id owner - used for privilege/rights check after joins etc.
    {These are read from the domain system table}
    domainId:integer;                   //cross reference only?
    dataType:TDataType;                 //column type
    Width:integer; {07/01/03 was smallint pre blobs}    //storage size (0=variable, i.e. no constraint)
    Scale:smallint;                     //precision
    defaultVal:string;                  //default
    defaultNull:boolean;                //default null?
    keyId:TColId;                       //index key sequence number (0=not part of key) (used for relation searches to find best index and used for index key-definition)
    commonColumn:integer;               //incremented each time optimiser processes a natural join: indicates this column & its common namesake(s) should become one in a later projection (sourceRange.originalOrder is used to specify left-right order)
  end; {TColDef}

  TColData=record
    {Dynamic - modified per read/insert/update to point to correct record version and slot
             - also used as update difference pointers to refer to original column data
     (also modified during data-setting for internal tuples (for insert/update/eval) and in copying)
    }
    dataPtr:PtrRecData;                 {column pointer to the appropriate fR in buffer/version list
                                        }
    offset:integer;                     {column offset to slot-id within the record
                                         & we then read the actual data offset within the record
                                         (this way, one thread can move data around on a pinned page (latch first!)
                                          & other pointers will still be valid)
                                        }
    len:colOffset;                      {column data length
                                         This is overkill (we could calculate it each time it's needed from
                                         the record data) but we store it and keep it up to date because:
                                           it's needed by the update routine
                                             (where we can pull out an individual column's data detached from its original successor)
                                           the logic to calculate length from the disk storage is localised to read/write routines
                                             (so future on-disk structure can change without greatly affecting the code)

                                         (type=colOffset because that's the limiting length in the current storage
                                               mechanism, where the length = nextOffset - thisOffset)
                                        }
    blobAllocated:boolean;              {the blob pointed to by dataptr has memory allocated,
                                         i.e. this is the original allocation not a shallow copy
                                         Note: see Tblob definition for details of how a swizzled Tblob is referenced
                                               after it's been read into memory
                                        }
  end; {TColData}

  //todo move to other units?
  TPageList=class
    page:TPage;
    next:TpageList;
  end; {TPageList}

  TRecList=class
    rec:TRec;
    next:TRecList;
  end; {TRecList}

  TTuple=class
    {Note: the interface/methods for this class have evolved,
           so when they have settled down we can hide more data then,
           i.e. once we know what outside routines need access to read/write
    }
    private
    //todo remove owner now that we pass tr to get db?? - but still need access to relation->dbfile...
    //     I think also that we will access owner as Trelation to gain access to indexes for auto-insert etc. to keep in sync.
      Owner:Tobject;                            //relation owner (=access to its dbfile for reading/inserting etc.)
      fRID:TRID;                                //rid - only used for reference (e.g. passing back up iterator tree for IterDelete)
                                                // -set by read routine
                                                // -also set by insert routine (for subsequent index keyPtr additions, so not just for pure reference)
                                                //Note: if this is invalid, check that all Iterators pass the value up via their iTuple output (currently only a couple do this)
      fRecData:TrecData;                        //scratch area for inserts (Note: this allocates a 'block' of space) - not always needed - so allow 'no allocation' =speed/memory
      {These two linked lists are used to pin and point to the record versions
       The linked lists grow as needed and don't shrink until the Tuple is destroyed
       The PageList is a list of page pointers that are pinned and stored in the Buffer Manager
         - we need TPage pointers rather than PageIds because PinPage returns a TPage
       The RecList is a list of record objects that are stored here
         - each one contains a pointer to the page data in memory
         (so to read 10 versions of a record we may need to fit up to 10 pages in buffer area at once
          - else what? - e.g. what if too many & small buffer?
            - could read and move into a single multi-version record area - time consuming...?)
      }
      fPageList:TPageList;                      //list of pinned pages for this tuple
      fRecList:TRecList;                        //list of record pointers for this tuple
                                                //1st pointer is also used to reference output buffer
                                                // - the space for which is allocated as part of the tuple (fRecData)
      fColCount:ColRef;                         //no. columns in this tuple (set and get) defines size of fColData & fColDef arrays
      fColData:array [0..MaxCol-1] of TColData;      //column data pointers //todo keep private - may not always use array
                                                     //todo: doesn't need to be fixed array? or does it?-access speed!

      fDiffColCount:ColRef;                     //no. difference columns in this update tuple - defines size of fDiffColData
      fDiffColData:array [0..MaxCol-1] of TColData;  //difference column data pointers - points to old/original column data
                                                     //todo: doesn't need to be fixed array...only for build & output?
      fDiffColCountDone:ColRef;                 //no. difference columns updated in this tuple - used to update column-id's in new data rec buffer
      fNewDataRec:Trec;                         //update new data record + buffer (Note: during clearUpdate this will allocate a 'block' of space)
      fUpdateRec:Trec;                          //update delta/new record + buffer (Note: during clearUpdate this will allocate a 'block' of space)
      fBlobRec:Trec;                            //blob record + buffer (Note: during [todo???insert] this will allocate a 'block' of space)

      function FreeRecord(st:TStmt):integer;
      procedure SetColCount(v:ColRef);
      procedure SetDiffColCount(v:ColRef);
    public
      fColDef:array [0..MaxCol-1] of TColDef;      //column definitions //todo make private - may not always use array
                                                   //todo use GetColDef...

      property RID:Trid read fRID; //todo remove write fRID; written by read() & insert()
      property ColCount:ColRef read fColCount write SetColCount;
      property DiffColCount:ColRef read fDiffColCount write SetDiffColCount;

      constructor Create(AOwner:Tobject);
      destructor Destroy; override;

      procedure SetColDef(c:colRef;colId:TColId;colName:string;colDomainId:integer;
                          ColDatatype:TDatatype;colWidth:integer;colScale:smallint;
                          ColDefaultVal:string;ColDefaultNull:boolean); 
                          //todo use a 'ColSetDef' structure to ease future code changes
      function CopyColDef(cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
      function CopyTupleDef(tR:TTuple):integer;
      function GetColBasicDef(c:colRef;var ColDatatype:TDatatype;var colWidth:integer;var colScale:smallint):integer;

      function OrderColDef:integer;

      procedure SetRID(r:Trid);

      function SetWt(t:StampId):integer;

      function PreInsert:integer;
      function insert(st:TStmt;var rid:Trid):integer;
      //todo etc.
      function read(st:TStmt;rid:Trid;attempt:boolean):integer;
      function delete(st:TStmt;rid:Trid):integer;
      function garbageCollect(st:TStmt;rid:Trid;readFirst:boolean):integer;
      function readToIndex(st:TStmt;rid:Trid;iFile:TObject{TIndexFile}):integer;

      function PrepareUpdateDiffRec:integer;
      function PrepareUpdateNewRec:integer;
      function update(st:TStmt;rid:Trid):integer;

      function updateOverwrite(st:TStmt;rid:Trid):integer; //todo replace with generic update
      function updateOverwriteNoVersioning(st:TStmt;rid:Trid):integer; //todo replace with generic update

      function Unpin(st:TStmt):integer;

      function ColIsNull(col:colRef;var null:boolean):integer;
      function GetString(col:colRef;var s:string;var null:boolean):integer;
      function GetInteger(col:colRef;var i:integer;var null:boolean):integer;
      function GetBigInt(col:colRef;var i:int64;var null:boolean):integer;
      function GetDouble(col:colRef;var d:double;var null:boolean):integer;
      function GetComp(col:colRef;var d:double;var null:boolean):integer;
      function GetNumber(col:colRef;var d:double;var null:boolean):integer;
      function GetDate(col:colRef;var d:TsqlDate;var null:boolean):integer;
      function GetTime(col:colRef;var t:TsqlTime;var null:boolean):integer;
      function GetTimestamp(col:colRef;var ts:TsqlTimestamp;var null:boolean):integer;
      function GetBlob(col:colRef;var b:Tblob;var null:boolean):integer;
      //todo etc.
      function GetDataPointer(col:colRef;var p:pointer;var len:colOffset;var null:boolean):integer;

      function GetOldBlob(col:colRef;var b:Tblob;var null:boolean):integer;
      //todo etc.?  

      function clear(st:TStmt):integer;
      function clearToNulls(st:TStmt):integer;
      function clearKeyIds(st:TStmt):integer;
      function setKeyId(col:ColRef;keyId:TColId):integer;
      function SetNull(col:ColRef):integer;
      function SetString(col:ColRef;s:pchar;null:boolean):integer;
      function SetInteger(col:ColRef;i:integer;null:boolean):integer;
      function SetBigInt(col:ColRef;i:int64;null:boolean):integer;
      function SetDouble(col:ColRef;d:double;null:boolean):integer;
      function SetComp(col:ColRef;d:double;null:boolean):integer;
      function SetNumber(col:colRef;d:double;null:boolean):integer;   //new - todo test!
      function SetDate(col:colRef;d:TsqlDate;null:boolean):integer;
      function SetTime(col:colRef;t:TsqlTime;null:boolean):integer;
      function SetTimestamp(col:colRef;ts:TsqlTimestamp;null:boolean):integer;
      function SetBlob(st:TStmt;col:colRef;b:Tblob;null:boolean):integer;
      //todo etc.

      function clearUpdate:integer;
      function UpdateNull(col:ColRef):integer;
      function UpdateString(col:ColRef;s:pchar;null:boolean):integer;
      function UpdateInteger(col:ColRef;i:integer;null:boolean):integer;
      function UpdateBigInt(col:ColRef;i:int64;null:boolean):integer;
      function UpdateDouble(col:ColRef;d:double;null:boolean):integer;
      function UpdateComp(col:ColRef;d:double;null:boolean):integer;
      function UpdateDate(col:ColRef;d:TsqlDate;null:boolean):integer;
      function UpdateTime(col:ColRef;t:TsqlTime;null:boolean):integer;
      function UpdateTimestamp(col:ColRef;ts:TsqlTimestamp;null:boolean):integer;
      function UpdateBlob(st:TStmt;col:colRef;b:Tblob;null:boolean):integer;


      function CopyColDataPtr(cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
      function CopyColDataDeep(cRefL:colRef;stR:TStmt;tR:TTuple;cRefR:ColRef;deepCopyBlobData:boolean):integer;
      function CopyOldColDataDeep(cRefL:colRef;stR:TStmt;tR:TTuple;cRefR:ColRef):integer;

      function CopyColDataDeepGetSet(st:TStmt;cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
      function CopyVarDataDeepGetSet(st:TStmt;cRefL:colRef;tRo:TObject{TVariableSet};vRefR:VarRef):integer;

      function CopyColDataDeepGetUpdate(st:TStmt;cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;

      function CopyDataToBuffer(var buf:Pchar;var bufLen:integer):integer;
      function CopyDataToFixedBuffer(buf:Pchar;var bufLen:integer):integer;
      function CopyBufferToData(buf:Pchar;bufLen:integer):integer;
      function GetDataLen:integer;


      function CompareCol(st:TStmt;colL,colR:ColRef;tR:TTuple;var res:shortint;var null:boolean):integer;

      function FindCol(find_node:TSyntaxNodePtr;const colName:string;rangeName:string;outerRef:TObject{==TIterator};var cTuple:TTuple;var c:ColRef;var colId:TColId):integer;
      function FindColFromId(colId:TColId;var c:ColRef):integer;

      function ShowHeading:string;
      function ShowHeadingKey:string;
      function ShowMap:string;
      function Show(st:TStmt):string;

      function copyBlobData(st:TStmt;b:Tblob;var newb:Tblob):integer;
      function freeBlobData(var b:Tblob):integer;
      function insertBlobData(st:TStmt;b:Tblob;var bRid:Trid):integer;
      function deleteBlobData(st:TStmt;b:Tblob):integer;
      function CompareBlob(st:TStmt;bl,br:TBlob;clobInvolved:boolean;var res:shortint):integer; //todo: move elsewhere?
  end;


var
  //todo: move these to a debug stat array and  make thread-safe & private
  debugTupleMax:integer=0;    
  debugTupleCount:integer=0;         
  debugTupleCreate:integer=0;
  debugTupleDestroy:integer=0;
  debugRecDataCreate:integer=0;
  debugRecDataDestroy:integer=0;
  debugRecCreate:integer=0;   
  debugRecDestroy:integer=0;  
  debugPagelistCreate:integer=0;
  debugPagelistDestroy:integer=0;
  debugTupleBlobAllocated:cardinal=0;
  debugTupleBlobDeallocated:cardinal=0;
  debugTupleBlobRecAllocated:cardinal=0;
  debugTupleBlobRecDeallocated:cardinal=0;

implementation

uses uLog, sysUtils, uRelation, uServer, uTransaction,
uAlgebra {for source node pointing}, uIterator, uHeapFile {for header updates}, Math {for power}, uIndexFile{for readToIndex},
uVariableSet;

const
  where='uTuple';
  who='';

constructor TTuple.Create(AOwner:Tobject);
const routine=':create';
begin
  //todo speed: if Aowner=nil then can we assume this is a temporary tupe, i.e. fast/cached create?
  Owner:=AOwner; //relation
  fPageList:=TPageList.create;
  {$IFDEF DEBUGDETAIL3}
  inc(debugPagelistCreate);
  {$ENDIF}
  fPageList.page:=nil;
  fPageList.next:=nil;
  //todo maybe create rec buffer space inside pages/frames - save the heap manager? = efficiency/speed
  fRecList:=TRecList.create;
  fRecList.rec:=TRec.create;     //create space for Trec
  {$IFDEF DEBUGDETAIL3}
  inc(debugRecCreate);
  {$ENDIF}
  fRecList.next:=nil;
  fRID.pid:=InvalidPageId;
  fRID.sid:=InvalidSlotId;
  fColCount:=0;

  fBlobRec:=TRec.create;
  {$IFDEF DEBUGDETAIL3}
  inc(debugRecCreate);
  {$ENDIF}

  inc(debugTupleCount); //todo remove
  inc(debugTupleCreate); //todo remove
  if debugTupleCount>debugTupleMax then
  begin
    debugTupleMax:=debugTupleCount;
  end;
  {$IFDEF DEBUG_LOG}
  if debugTupleMax=1 then
    log.add(who,where,format('  Tuple memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}
end; {Create}
destructor TTuple.Destroy;
var
  i:integer;
  b:Tblob;
  bnull:boolean;
begin
  {Free any allocated blob memory
   Note: would be nice to be able to call self.clear & self.clearUpdate, but would need an st & overkill?}
  if fColCount>0 then
    for i:=0 to fcolCount-1 do
    begin
      {If this is a blob, ensure we free any allocated memory}
      if DataTypeDef[fColDef[i].datatype] in [stBlob] then
      begin
        if fColData[i].blobAllocated and (fColData[i].dataPtr<>nil) then
        begin
          if getBlob(i,b,bnull)=ok then
          begin
            {todo no need for if? assert instead}if not bnull and (b.rid.sid=InvalidSlotId) then begin freeBlobData(b); fColData[i].blobAllocated:=false; {fColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
          end;
        end;
      end;
    end;

  if fDiffColCount>0 then
    for i:=0 to fDiffColCount-1 do
    begin
      {If this is a blob, ensure we free any allocated memory (assumes column type hasn't changed since data was set)}
      if DataTypeDef[fColDef[i].datatype] in [stBlob] then
      begin
        if fDiffColData[i].blobAllocated and (fDiffColData[i].dataPtr<>nil) then
        begin
          if getBlob(i,b,bnull)=ok then
          begin
            {todo remove if, assert instead}if not bnull and (b.rid.sid=InvalidSlotId) then begin freeBlobData(b); fDiffColData[i].blobAllocated:=false; {fDiffColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
          end;
        end;
      end;
    end;

  fBlobRec.free;
  {$IFDEF DEBUGDETAIL3}
  inc(debugRecDestroy);
  {$ENDIF}

  FreeRecord(nil); //delete any remaining record/page chain
  //todo FreeRecord should handle nil better
  //*** - or we should assert here that it can handle everything ok
  {$IFDEF DEBUGDETAIL3}
  {$IFDEF DEBUG_LOG}
  if fRecList.rec=nil then
    log.add(who,where+':destroy',format('Free error',[nil]),vAssertion);
  {$ENDIF}
  {$ENDIF}
  fRecList.rec.free;
  {$IFDEF DEBUGDETAIL3}
  inc(debugRecDestroy);
  {$ENDIF}
  fRecList.Free;
  fPageList.Free;
  {$IFDEF DEBUGDETAIL3}
  inc(debugPagelistDestroy);
  {$ENDIF}
  if fNewDataRec<>nil then
  begin
    dispose(fNewDataRec.dataPtr);
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataDestroy);
    {$ENDIF}
    fNewDataRec.free; //de-allocate update new data record buffer (if allocated)
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDestroy);
    {$ENDIF}
  end;
  if fUpdateRec<>nil then
  begin
    dispose(fUpdateRec.dataPtr);
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataDestroy);
    {$ENDIF}
    fUpdateRec.free; //de-allocate update record buffer (if allocated)
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDestroy);
    {$ENDIF}
  end;

  dec(debugTupleCount); //todo remove
  inc(debugTupleDestroy); //todo remove

  inherited destroy;
end;

procedure TTuple.SetColCount(v:ColRef);
begin
  //todo: maybe if this routine does nothing special we can remove it and
  //      have the user directly set fColCount - this should be slightly faster
  //      - but no: this is not used any crucial loops? - except eval temp tuples... but these should be more static...

  {$IFDEF SAFETY}
  //todo log warnings if v=0 or v>maxCol
  if  (v>maxCol) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+':setColCount',format('Column count %d is beyond limits 0..%d',[v,maxCol]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway - this means we'll get a failure sometime later...
    //todo halt here? - no point?
  end;
  {$ENDIF}

  if v<>fColCount then
  begin
    fColCount:=v;
  end;
  //todo also reset ColDef's? or at least a flag to ensure they are redefined before attempting to use them...
end; {SetColCount}

procedure TTuple.SetDiffColCount(v:ColRef);
{
 Assumes:
   we've set ColCount first (so we can do an extra range check)
}
begin
  //todo: maybe if this routine does nothing special we can remove it and
  //      have the user directly set fDiffColCount - this should be slightly faster
  //      - but no: this is not used any crucial loops?

  {$IFDEF SAFETY}
  //todo log warnings if v=0 or v>maxCol
  if  (v>maxCol) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+':setDiffColCount',format('Diff-column count %d is beyond limits 0..%d',[v,maxCol]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway - this means we'll get a failure sometime later...
    //todo halt here? - no point?
  end;
  {$ENDIF}

  {$IFDEF SAFETY}
  //todo log warnings if v>colCount //Note: this assumes we set colCount first
  if (v>fColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+':setDiffColCount',format('Diff-column count %d is beyond colCount %d',[v,fcolCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway - this means we'll get a failure sometime later...
    //todo halt here? - no point?
  end;
  {$ENDIF}

  if v<>fDiffColCount then
  begin
    fDiffColCount:=v;
  end;
  //todo also reset DiffColDef's? or at least a flag to ensure they are redefined before attempting to use them...
end; {SetDiffColCount}

procedure TTuple.SetColDef(c:colRef;colId:TColId;colName:string;colDomainId:integer;ColDatatype:TDatatype;colWidth:integer;colScale:smallint;colDefaultVal:string;colDefaultNull:boolean); 
{Initialises a column definition

 Note: the colId is used to give the columns a left-right ordering that is used by SQL for:
         tuple default (*) output
         insert values in 'natural' order
         (etc?)
       so for new relation definitions, increment the colId from left to right.

       Resets source info.
}
const routine=':SetColDef';
begin
  {$IFDEF SAFETY}
  {Assert c is a valid subscript => fcolCount must be incremented before defining a new column}
  if (c>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[c,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}

  //todo SAFETY:
  //  track last_colRef set for this tuple and
  //  if c<>last_colRef+1, debugAssertion!

  with fColDef[c] do
  begin
    sourceRange:=nil; //initialise
    sourceTableId:=InvalidTableId;
    sourceAuthId:=InvalidAuthId;

    id:=ColId; //todo: assert this is <= relation's nextColId
    name:=ColName;
    domainId:=colDomainId;
    dataType:=colDatatype;
    width:=colWidth;
    scale:=colScale;
    defaultVal:=colDefaultVal;
    defaultNull:=colDefaultNull;
    keyId:=InvalidKeyId; //not part of index key data
    commonColumn:=0;
  end; {with}
end; {SetColDef}

function TTuple.GetColBasicDef(c:colRef;var ColDatatype:TDatatype;var colWidth:integer;var colScale:smallint):integer;
{Returns basic column definition info
}
const routine=':GetColBasicDef';
begin
  result:=ok;
  {$IFDEF SAFETY}
  {Assert c is a valid subscript}
  if (c>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[c,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;
  {$ENDIF}

  with fColDef[c] do
  begin
    colDatatype:=dataType;
    colWidth:=width;
    colScale:=scale;
  end; {with}
end; {GetColBasicDef}

function TTuple.CopyColDef(cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
{Initialises a column definition from another tuple column
 IN:         cRefL               this tuple column to set
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok, or fail

 Note:
   this can reset the name and sourceRange info so any runtime aliasing may be lost
}
const routine=':CopyColDef';
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before defining a new column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before defining a new column}
  if (cRefR>tR.fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}

  with fColDef[cRefL] do
  begin
//debug:was caused by view distinct...    if sourceRange=nil then //29/03/01: debug ok? to prevent aliased projection from losing aliased columns e.g. when view referenced: caller to control?
      sourceRange:=tR.fColDef[cRefR].sourceRange; //ensure we retain the original source
    sourceTableId:=tR.fColDef[cRefR].sourceTableId; //ensure we retain the original source
    sourceAuthId:=tR.fColDef[cRefR].sourceAuthId; //ensure we retain the original source

    id:=tR.fColDef[cRefR].id;
    name:=tR.fColDef[cRefR].name;
    domainId:=tR.fColDef[cRefR].domainId;
    dataType:=tR.fColDef[cRefR].datatype;
    width:=tR.fColDef[cRefR].Width;
    scale:=tR.fColDef[cRefR].Scale;
    defaultVal:=tR.fColDef[cRefR].defaultVal;
    defaultNull:=tR.fColDef[cRefR].defaultNull;

    keyId:=tR.fColDef[cRefR].keyId;
    commonColumn:=tR.fColDef[cRefR].commonColumn; //ok? linked to source
  end; {with}
  result:=ok;
end; {CopyColDef}

function TTuple.CopyTupleDef(tR:TTuple):integer;
{Initialises all column definitions from another tuple
 IN:         tR                  the source tuple
 RETURNS:    ok, or fail

 Note:
   also sets the colCount
   and retains original's colId's

   does not copy (or set) data pointers
    - so caller will probably need to call clear afterwards

 Assumes:
   source tuple is defined
}
const routine=':CopyTupleDef';
var
  i:colRef;
begin
  result:=fail;

  {Define this tuple from source tuple}
  ColCount:=tR.ColCount;
  if ColCount>0 then
    for i:=0 to tR.ColCount-1 do
    begin
      result:=CopyColDef(i,tR,i);
      if result<>ok then exit; //abort
    end;
end; {CopyTupleDef}

function TTuple.OrderColDef:integer;
{Re-orders all column definitions (and any data/diff pointers) in Id order
 This is needed to give a natural order:
   select *...
   insert... values
   etc?

 And because the system catalog heap-files don't (currently) retain the ordering
 //todo may be no need for this once we have system catalog indexes...?

 RETURNS:    0 or +ve = ok (actually highest column id)
             else fail

 Note:
   this also copies corresponding data/diffData arrays
   but this routine is designed to be called immediately after definition, so they
   should not be needed

 Assumes:
   tuple is defined
}
const routine=':OrderColDef';
var
  i:colRef;
  tempColDef:TColDef;
  tempColData:TColData;
  tempDiffColData:TColData;
begin
  result:=fail;

  //todo improve - this uses a naff bubble sort - use quick-sort (or originally read using an index/sort!)
  if colCount>0 then
    repeat
      i:=0;
      while (i<ColCount-1) do
      begin
        if fColDef[i].id > result then result:=fColDef[i].id; //track the highest colId (initially used for bitmap sizing: stored in relation)

        if fColDef[i].id > fColDef[i+1].id then
          break; //swap these
        inc(i);
      end;

      if i<>ColCount-1 then
      begin //swap needed
        {do the swap}
        {$IFDEF DEBUGCOLUMNDETAILID}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d has Id %d and has been bubbled up to ref %d',[i,fColDef[i].id,i+1]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        tempColDef:=fColDef[i];
        fColDef[i]:=fColDef[i+1];
        fColDef[i+1]:=tempColDef;
        //todo could probably remove rest - speed - although terrible bugs if ever needed!
        tempColData:=fColData[i];
        fColData[i]:=fColData[i+1];
        fColData[i+1]:=tempColData;
        tempDiffColData:=fDiffColData[i];
        fDiffColData[i]:=fDiffColData[i+1];
        fDiffColData[i+1]:=tempDiffColData;
      end;
    until i=ColCount-1
  else
    result:=ok; //no columns is ok
end; {OrderColDef}


function TTuple.CopyColDataPtr(cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
{Shallow copies a column's data pointer from another tuple column
 IN:         cRefL               this tuple column to set
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok, or fail

 Assumes:
   source tuple's data will remain pinned for the life of this (target)
   tuple, since we copy the data pointers.

   If this cannot be guaranteed, caller should use a deep copy routine
}
const routine=':CopyColDataPtr';
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before defining a new column}
  if (cRefL>fColCount-1) then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before defining a new column}
  if (cRefR>tR.fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}

  with fColData[cRefL] do
  begin
    {Now we shallow copy the data by duplicating the pointers}
    dataPtr:=tR.fColData[cRefR].dataPtr;
    offset:=tR.fColData[cRefR].offset;
    len:=tR.fColData[cRefR].len;
    blobAllocated:=false; //Note: we don't copy this!
  end; {with}
  result:=ok;
end; {CopyColDataPtr}

function TTuple.CopyColDataDeep(cRefL:colRef;stR:TStmt;tR:TTuple;cRefR:ColRef;deepCopyBlobData:boolean):integer;
{Copies the data from one tuple column and appends to another tuple
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         cRefL               this tuple column to copy to
             stR                 the source st -> db (only used when deepCopyBlobData=true)
             tR                  the source tuple
             cRefR               the source tuple column
             deepCopyBlobData    true=copy blob data into target memory (used for cross-catalog backup)
                                 else just deep copy blob ref (which should be enough if in same catalog)
                                 (although maybe sometimes deep copying memory->memory woud be better
                                  than having to hit the disk again(?) from the copy (todo test/speed))
 RETURNS:    ok (even if dataptr=nil => no data copied),
             or fail

 Note:
   blob data is not copied (yet), but the the Tblob is deep copied

 Assumes:
   target and source tuples are already defined
   target data has not already been appended to data record
   copying is called in target column order, as for SetInteger etc.
   column data is compatible when 'moved' (i.e. column definitions can read each other's raw data)
}
const routine=':CopyColDataDeep';
var
  coff,newCoff:ColOffset;
  null:boolean;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
  b,newB:Tblob;
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefR>tR.fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?

  with tR.fColData[cRefR] do
  begin
    if dataPtr<>nil then
    begin
      {Move the source to the target}
      move(dataPtr^[offset],coff,sizeof(coff)); //get offset for this column
      //todo remove(len) move(dataPtr^[offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
      //todo debugAssert nextCoff-coff=len!

      {Also set the new column slot offset}
      //todo next line may not be needed every time
      fColData[cRefL].dataPtr:=fRecList.rec.dataPtr;
      fColData[cRefL].len:=len;
      //todo next line is overkill if we initially cleared
      fColData[cRefL].offset:=sizeof(ColRef)+(cRefL*(sizeof(cid)+sizeof(colOffset)))+sizeof(cid);
      fColData[cRefL].blobAllocated:=false; //Note: we don't copy this (unless deepCopyBlobData - see below)

      {Get current output position}
      newCoff:=fRecList.rec.len;
      if len=0 then null:=True else null:=False;

      //Note: the next assertion may need to be retained as a runtime test because
      //      the variable length columns could break the MaxRecSize limit at any time
      //      We either need to pre-empt this or handle it better in these tuple routines
      //      TODO, if we do handle it elsewhere we can add IFDEF SAFETY to ALL such MaxRecSize assertions
      if not null and (newCoff+len>=MaxRecSize) then        //todo remove?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.cleared)',[newCoff]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit;
      end;

      if not null then
      begin
        if deepCopyBlobData and (DataTypeDef[tR.fColDef[cRefR].datatype] in [stBlob]) then
        begin //copy the blob data into memory as well, e.g. for cross-catalog backup
          //todo here? read data from blob (b) into newly allocated memory (may come from disk or memory)
          //           store pointer to that memory here as this blob ref (sid=0)
          //           then tuple.insert etc. will create blob on disk & swizzle ref before writing record
          //                & tuple.clear will deallocate any remaining memory
          tR.GetBlob(cRefR,b,null);
          result:=tR.copyBlobData(stR{->source db},b,newB); //from source catalog
          if result>=ok then
          begin
            fColData[cRefL].blobAllocated:=true; //ensure we free this memory later
            //todo assert len=sizeof(newB)
            move(newB,fColData[cRefL].dataPtr^[newCoff],sizeof(newB));
            fRecList.rec.len:=fRecList.rec.len+sizeof(newB);
            //{$IFDEF DEBUGCOLUMNDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('deep copied (%d %d)',[newB.rid.pid, newB.rid.sid]),vDebugLow);
            {$ENDIF}
            //{$ENDIF}
          end
          else
            exit; //abort
        end
        else
        begin //normal (in record) deep copy
          move(dataPtr[coff],fColData[cRefL].dataPtr^[newCoff],len); //move data
          fRecList.rec.len:=newCoff+len;     //increase length
        end;
      end;
      move(newCoff,fColData[cRefL].dataPtr^[sizeof(ColRef)+(cRefL*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
      //todo check coff when empty

      result:=ok;
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column %d dataptr is nil - no data copied (%s from %d)',[cRefR,tR.fColDef[cRefR].name,tR.fColDef[cRefR].sourceTableId]),vDebugWarning); //todo: maybe assertion or error or silent?
      {$ELSE}
      ;
      {$ENDIF}
                                                                                                        //silent because only happens if (top-level?) subquery is empty (e.g. select returns no rows)

      {$IFDEF DEBUGCOPYDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format(' - tuple is:',[nil{todo pass tran},tR.Show(nil)]),vDebugWarning); //todo: maybe assertion or error or silent?
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      result:=ok; //todo maybe should return +1 & let caller decide whether this is bad or good?
    end;
  end;

  //todo don't we need to ensure the end-column offset is set? - caller should/must call preInsert?
end; {CopyColDataDeep}

function TTuple.CopyOldColDataDeep(cRefL:colRef;stR:TStmt;tR:TTuple;cRefR:ColRef):integer;
{Copies the pre-update (old) data from one tuple column and appends to another tuple
 - needed for cascading updates
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         cRefL               this tuple column to copy to
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok (even if dataptr=nil => no data copied),
             or fail

 Assumes:
   target and source tuples are already defined
   target data has not already been appended to data record
   copying is called in target column order, as for SetInteger etc.
   column data is compatible when 'moved' (i.e. column definitions can read each other's raw data)

 Note: calls/copied from CopyColDataDeep: keep in sync.
}
const routine=':CopyOldColDataDeep';
var
  coff,newCoff:ColOffset;
  null:boolean;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
  size:colOffset;
  i:ColRef;
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefR>tR.fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.fColCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?

  with tR.fColData[cRefR] do
  begin
    if dataPtr<>nil then
    begin
      if (tR.fNewDataRec<>nil) {}and (dataPtr=tR.fNewDataRec.dataPtr){} then
      begin //we have a pre-update value
        {$IFDEF DEBUGCOLUMNDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column %d has an old value (%d column updates)'{; col pointed at update=%d)'},[cRefR,tR.fDiffColCount{,ord(dataPtr=tR.fNewDataRec.dataPtr)}]),vDebugHigh);
        {$ENDIF}
        {$ENDIF}

        //Note: following copied from PrepareUpdateDiffRec
        //size:=sizeof(colRef)+((tR.fDiffColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
        if tR.fDiffColCount>0 then //todo no need here?
        begin
          for i:=0 to tR.fDiffColCount-1 do //todo any way to get the appropriate one directly? speed
          begin
            move(tR.fDiffColData[i].dataPtr^[tR.fDiffColData[i].offset],coff,sizeof(coff)); //get offset for this column
            move(tR.fDiffColData[i].dataPtr^[tR.fDiffColData[i].offset-sizeof(cid)],cid,sizeof(cid)); //get original id for this column
                                                                                                //Note: we had to move back just before offset (I think this is the only time we do this)

            if tR.fColDef[cRefR].id=cid then
            begin //this is our source column's old data
              //todo debugAssert nextCoff-coff=len
              {Also set the new column slot offset}
              //todo next line may not be needed every time
              fColData[cRefL].dataPtr:=fRecList.rec.dataPtr;
              fColData[cRefL].len:=tR.fDiffColData[i].len;
              //todo next line is overkill if we initially cleared (todo+ seems necessary, else garbage returned)
              fColData[cRefL].offset:=sizeof(ColRef)+(cRefL*(sizeof(cid)+sizeof(colOffset)))+sizeof(cid);
              fColData[cRefL].blobAllocated:=false; //

              {Get current output position}
              newCoff:=fRecList.rec.len;
              if tR.fDiffColData[i].len=0 then null:=true else null:=false;

              {$IFDEF DEBUGCOLUMNDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('column %d offset=%d len=%d (target offset=%d)',[i,coff,tR.fDiffColData[i].len,newcoff]),vDebugLow);
              {$ENDIF}
              {$ENDIF}

              //Note: the next assertion may need to be retained as a runtime test because
              //      the variable length columns could break the MaxRecSize limit at any time
              //      We either need to pre-empt this or handle it better in these tuple routines
              //      TODO, if we do handle it elsewhere we can add IFDEF SAFETY to ALL such MaxRecSize assertions
              if not null and (newCoff+tR.fDiffColData[i].len>=MaxRecSize) then        //todo remove?
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.cleared)',[newCoff]),vAssertion);
                {$ENDIF}
                exit;
              end;

              if not null then
              begin
                move(tR.fDiffColData[i].dataPtr[coff],fColData[cRefL].dataPtr^[newCoff],tR.fDiffColData[i].len); //move data
                fRecList.rec.len:=newCoff+tR.fDiffColData[i].len;     //increase length

                //todo: if blob in memory, then copyBlobData now...!!!!!!!!!? & set blobAllocated=true
              end;
              move(newCoff,fColData[cRefL].dataPtr^[sizeof(ColRef)+(cRefL*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
              //todo check coff when empty

              result:=ok;

              break; //ok, no more matches expected
            end;
          end;
        end;
        {$IFDEF DEBUG_LOG}
        if result<>ok then
          log.add(who,where+routine,format('Failed finding updated column value id=%d',[tR.fColDef[cRefR].id]),vAssertion);
        {$ENDIF}
      end
      else //this column wasn't updated
        result:=copyColDataDeep{Ptr todo debug fixed group-by?}(cRefL,stR,tR,cRefR,false);
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column %d dataptr is nil - no data copied (%s from %d)',[cRefR,tR.fColDef[cRefR].name,tR.fColDef[cRefR].sourceTableId]),vDebugWarning); //todo: maybe assertion or error or silent?
      {$ENDIF}
                                                                                                        //silent because only happens if (top-level?) subquery is empty (e.g. select returns no rows)
      {$IFDEF DEBUGCOPYDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format(' - tuple is:',[nil{todo pass tran},tR.Show(nil)]),vDebugWarning); //todo: maybe assertion or error or silent?
      {$ENDIF}
      {$ENDIF}

      result:=ok; //todo maybe should return +1 & let caller decide whether this is bad or good?
    end;
  end;

  //todo don't we need to ensure the end-column offset is set? - caller should/must call preInsert?
end; {CopyOldColDataDeep}

function TTuple.CopyColDataDeepGetSet(st:TStmt;cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
{Copies the data from one tuple column and appends to another tuple
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         tran                the caller transaction - may be needed for local timezone
             cRefL               this tuple column to copy to
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok, or fail

 Assumes:
   target and source tuples are already defined
   target data has not already been appended to data record
   copying is called in target column order, as for SetInteger etc.

 Note:
   if column data is not compatible/coercible then we fail,
   but column definitions don't need to read each other's raw data, as we use Get then Set

   Written for IterInsert where we're building up an empty target area from a variable typed source
   Also used to CAST types as other types
   Safer but slower than CopyColDataDeep

   Keep in sync with CopyColDataDeepGetUpdate (& TvariableSet routines)
}
const routine=':CopyColDataDeepGetSet';
var
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv,bv2:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefR>tR.fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {Set these in case we read an integer & try to set a string - i.e. coerce to null}
  //todo need to spot such problems in future as errors or 'implicit' coercions e.g. string->integer
  //todo we can remove these now....
  sv_null:=true;
  iv_null:=true;
  biv_null:=true;
  dv_null:=true;
  dtv_null:=true;
  tmv_null:=true;
  tsv_null:=true;
  bv_null:=true;

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?
  {Read the data
   and copy the data by setting the target columns (safer than pointers + block copying)
  }
  case tR.fColDef[cRefR].dataType of
    ctChar,ctVarChar,ctBit,ctVarBit:
    begin
      tR.GetString(cRefR,sv,sv_null);
      case fColDef[cRefL].dataType of
        ctChar,ctVarChar,ctBit,ctVarBit:
          SetString(cRefL,pchar(sv),sv_null);
        ctInteger,ctSmallInt:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              iv:=strToInt(sv); //todo check range for smallint...
              SetInteger(cRefL,iv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBigInt:
        begin
          if sv_null then
            SetBigInt(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              biv:=strToInt64(sv); //todo check range for smallint...
              SetBigInt(cRefL,biv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctFloat:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetDouble(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctNumeric,ctDecimal:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetComp(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          if sv_null then
            SetDate(cRefL,dtv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              dtv:=strToSqlDate(sv);
              SetDate(cRefL,dtv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          if sv_null then
            SetTime(cRefL,tmv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimeWithTimezone then
                tmv:=strToSqlTime(Ttransaction(st.owner).timezone,sv,dayCarry)
              else
                tmv:=strToSqlTime(TIMEZONE_ZERO,sv,dayCarry);
              SetTime(cRefL,tmv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          if sv_null then
            SetTimestamp(cRefL,tsv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimestampWithTimezone then
                tsv:=strToSqlTimestamp(Ttransaction(st.owner).timezone,sv)
              else
                tsv:=strToSqlTimestamp(TIMEZONE_ZERO,sv);
              SetTimestamp(cRefL,tsv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin //note: conversion not required by standard CAST for ctBlob
          if sv_null then
            SetBlob(st,cRefL,bv{todo! use BLOB_ZERO},sv_null) //no need to coerce
          else
          begin
            bv.rid.sid:=0; //i.e. in-memory blob
            bv.rid.pid:=pageId(pchar(sv)); //pass syntax data pointer as blob source in memory
            bv.len:=length(sv);
            SetBlob(st,cRefL,bv,sv_null); //sv_null is always false
          end;
        end; {ctBlob,ctClob}
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d (possible attempt to convert from a parameter)',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctChar,ctVarChar,ctBit,ctVarBit}
    ctInteger,ctSmallInt:
    begin
      tR.GetInteger(cRefR,iv,iv_null);
      case fColDef[cRefL].dataType of
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(cRefL,iv,iv_null);
        end;
        ctBigInt:
          SetBigInt(cRefL,iv,iv_null);
        ctFloat:
          SetDouble(cRefL,iv,iv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(cRefL,iv,iv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if iv_null then
            SetString(cRefL,'',iv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(iv);
              SetString(cRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctInteger,ctSmallInt}
    ctBigInt:
    begin
      tR.GetBigInt(cRefR,biv,biv_null);
      case fColDef[cRefL].dataType of
        ctBigInt:
          SetBigInt(cRefL,biv,biv_null);
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(cRefL,integer(biv),biv_null);
        end;
        ctFloat:
          SetDouble(cRefL,biv,biv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(cRefL,biv,biv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if biv_null then
            SetString(cRefL,'',biv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(biv);
              SetString(cRefL,pchar(sv),biv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctInteger,ctSmallInt}
    ctFloat:
    begin
      tR.GetDouble(cRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(cRefL,dv,dv_null);
        end;
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctFloat}
    ctNumeric,ctDecimal:
    begin
      tR.GetComp(cRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(cRefL,dv,dv_null); //todo fix/check
        end;
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctNumeric,ctDecimal}
    ctDate:
    begin
      tR.GetDate(cRefR,dtv,dtv_null);
      case fColDef[cRefL].dataType of
        ctDate:
        begin
          SetDate(cRefL,dtv,dtv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if dtv_null then
            SetString(cRefL,'',dtv_null) //no need to coerce
          else
          begin
            try
              sv:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]);
              SetString(cRefL,pchar(sv),dtv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          //todo tsv.time=ZERO_TIME?
          tsv.date:=dtv;
          SetTimestamp(cRefL,tsv,dtv_null);
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctDate}
    ctTime,ctTimeWithTimezone:
    begin
      tR.GetTime(cRefR,tmv,tmv_null);
      case fColDef[cRefL].dataType of
        ctTime,ctTimeWithTimezone:
        begin
          SetTime(cRefL,tmv,tmv_null);
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          tsv.date:=Ttransaction(st.owner).currentDate; //DATE_ZERO;
          tsv.time:=tmv;
          SetTimestamp(cRefL,tsv,tmv_null);
        end;
        ctDate,
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(cRefL,'',tmv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimeWithTimezone then
                sv:=sqlTimeToStr(Ttransaction(st.owner).timezone,tmv,tR.fColDef[cRefR].scale,dayCarry)
              else
                sv:=sqlTimeToStr(TIMEZONE_ZERO,tmv,tR.fColDef[cRefR].scale,dayCarry);
              SetString(cRefL,pchar(sv),tmv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctTime,ctTimeWithTimezone}
    ctTimestamp,ctTimestampWithTimezone:
    begin
      tR.GetTimestamp(cRefR,tsv,tsv_null);
      //todo: need to retain time-zone if target has one, not normalise
      case fColDef[cRefL].dataType of
        ctTimestamp,ctTimestampWithTimezone:
        begin
          SetTimestamp(cRefL,tsv,tsv_null);
        end;
        ctTime,ctTimeWithTimezone:
        begin
          //todo data loss error
          SetTime(cRefL,tsv.time,tsv_null);
        end;
        ctDate:
        begin
          //todo data loss error
          SetDate(cRefL,tsv.date,tsv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tsv_null then
            SetString(cRefL,'',tsv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimestampWithTimezone then
                sv:=sqlTimestampToStr(Ttransaction(st.owner).timezone,tsv,tR.fColDef[cRefR].scale)
              else
                sv:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,tR.fColDef[cRefR].scale);
              SetString(cRefL,pchar(sv),tsv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctTimestamp,ctTimestampWithTimezone}
    ctBlob,ctClob:
    begin
      tR.GetBlob(cRefR,bv,bv_null);
      case fColDef[cRefL].dataType of
        ctBlob,ctClob:
          SetBlob(st,cRefL,bv,bv_null);

        ctChar,ctVarChar: //note: conversion not required by standard CAST for ctBlob
        begin
          if bv_null then
            SetString(cRefL,'',bv_null) //no need to coerce
          else
            try
              if copyBlobData(st,bv,bv2)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                  //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
              begin
                SetLength(sv,bv2.len);
                StrMove(pchar(sv),pchar(bv2.rid.pid),bv2.len);  //note: should we use strLcopy instead of strMove to ensure we add #0?
                SetString(cRefL,pchar(sv),bv_null);
              end;
            finally
              freeBlobData(bv2);
            end; {try}
        end;

        //todo convert blob to others? note: not required by standard CAST
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctBlob,ctClob}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefR,ord(tR.fColDef[cRefR].dataType)]),vAssertion); //todo error?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  result:=ok;
end; {CopyColDataDeepGetSet}

function TTuple.CopyVarDataDeepGetSet(st:TStmt;cRefL:colRef;tRo:TObject{TVariableSet};vRefR:VarRef):integer;
{Copies the data from one variable and appends to another tuple
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         tran                the caller transaction - may be needed for local timezone
             cRefL               this tuple column to copy to
             tRo                  the source vairable set
             vRefR               the source variable
 RETURNS:    ok, or fail

 Assumes:
   target and source tuples are already defined
   target data has not already been appended to data record
   copying is called in target column order, as for SetInteger etc.

 Note:
   if column data is not compatible/coercible then we fail,
   but column definitions don't need to read each other's raw data, as we use Get then Set

   Written for IterInsert where we're building up an empty target area from a variable typed source
   Also used to CAST types as other types
   Safer but slower than CopyColDataDeep

   Keep in sync with CopyColDataDeepGetUpdate (& TvariableSet routines)
}
const routine=':CopyVarDataDeepGetSet';
var
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv,bvData:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;

  tR:TVariableSet;
begin
  result:=fail;

  tR:=(tRo as TVariableSet); //cast

  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert vRefR is a valid subscript => fvarCount must be incremented before copying a column}
  if (vRefR>tR.varCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefR,tR.varCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {Set these in case we read an integer & try to set a string - i.e. coerce to null}
  //todo need to spot such problems in future as errors or 'implicit' coercions e.g. string->integer
  //todo we can remove these now....
  sv_null:=true;
  iv_null:=true;
  biv_null:=true;
  dv_null:=true;
  dtv_null:=true;
  tmv_null:=true;
  tsv_null:=true;
  bv_null:=true;

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?
  {Read the data
   and copy the data by setting the target columns (safer than pointers + block copying)
  }
  case tR.fvarDef[vRefR].dataType of
    ctChar,ctVarChar,ctBit,ctVarBit:
    begin
      tR.GetString(vRefR,sv,sv_null);
      case fColDef[cRefL].dataType of
        ctChar,ctVarChar,ctBit,ctVarBit:
          SetString(cRefL,pchar(sv),sv_null);
        ctInteger,ctSmallInt:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              iv:=strToInt(sv); //todo check range for smallint...
              SetInteger(cRefL,iv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBigInt:
        begin
          if sv_null then
            SetBigInt(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              biv:=strToInt64(sv); //todo check range for smallint...
              SetBigInt(cRefL,biv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctFloat:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetDouble(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctNumeric,ctDecimal:
        begin
          if sv_null then
            SetInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetComp(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          if sv_null then
            SetDate(cRefL,dtv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              dtv:=strToSqlDate(sv);
              SetDate(cRefL,dtv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          if sv_null then
            SetTime(cRefL,tmv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimeWithTimezone then
                tmv:=strToSqlTime(Ttransaction(st.owner).timezone,sv,dayCarry)
              else
                tmv:=strToSqlTime(TIMEZONE_ZERO,sv,dayCarry);
              SetTime(cRefL,tmv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          if sv_null then
            SetTimestamp(cRefL,tsv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimestampWithTimezone then
                tsv:=strToSqlTimestamp(Ttransaction(st.owner).timezone,sv)
              else
                tsv:=strToSqlTimestamp(TIMEZONE_ZERO,sv);
              SetTimestamp(cRefL,tsv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          if sv_null then
            SetBlob(st,cRefL,bv{todo! use BLOB_ZERO},sv_null) //no need to coerce
          else
          begin
            bv.rid.sid:=0; //i.e. in-memory blob
            bv.rid.pid:=pageId(pchar(sv)); //pass syntax data pointer as blob source in memory
            bv.len:=length(sv);
            SetBlob(st,cRefL,bv,sv_null); //sv_null is always false
          end;
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctInteger,ctSmallInt:
    begin
      tR.GetInteger(vRefR,iv,iv_null);
      case fColDef[cRefL].dataType of
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(cRefL,iv,iv_null);
        end;
        ctBigInt:
          SetBigInt(cRefL,iv,iv_null);
        ctFloat:
          SetDouble(cRefL,iv,iv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(cRefL,iv,iv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if iv_null then
            SetString(cRefL,'',iv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(iv);
              SetString(cRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBigInt:
    begin
      tR.GetBigInt(vRefR,biv,biv_null);
      case fColDef[cRefL].dataType of
        ctBigInt:
          SetBigInt(cRefL,biv,biv_null);
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(cRefL,integer(biv),biv_null);
        end;
        ctFloat:
          SetDouble(cRefL,biv,biv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(cRefL,biv,biv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if biv_null then
            SetString(cRefL,'',biv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(biv);
              SetString(cRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctFloat:
    begin
      tR.GetDouble(vRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(cRefL,dv,dv_null);
        end;
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctNumeric,ctDecimal:
    begin
      tR.GetComp(vRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(cRefL,dv,dv_null); //todo fix/check
        end;
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctDate:
    begin
      tR.GetDate(vRefR,dtv,dtv_null);
      case fColDef[cRefL].dataType of
        ctDate:
        begin
          SetDate(cRefL,dtv,dtv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if dtv_null then
            SetString(cRefL,'',dtv_null) //no need to coerce
          else
          begin
            try
              sv:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]);
              SetString(cRefL,pchar(sv),dtv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          //todo tsv.time=ZERO_TIME?
          tsv.date:=dtv;
          SetTimestamp(cRefL,tsv,dtv_null);
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTime,ctTimeWithTimezone:
    begin
      tR.GetTime(vRefR,tmv,tmv_null);
      case fColDef[cRefL].dataType of
        ctTime,ctTimeWithTimezone:
        begin
          SetTime(cRefL,tmv,tmv_null);
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          tsv.date:=Ttransaction(st.owner).currentDate; //DATE_ZERO;
          tsv.time:=tmv;
          SetTimestamp(cRefL,tsv,tmv_null);
        end;
        ctDate,
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(cRefL,'',tmv_null) //no need to coerce
          else
          begin
            try
              if tR.fvarDef[vRefR].dataType=ctTimeWithTimezone then
                sv:=sqlTimeToStr(Ttransaction(st.owner).timezone,tmv,tR.fvarDef[vRefR].scale,dayCarry)
              else
                sv:=sqlTimeToStr(TIMEZONE_ZERO,tmv,tR.fvarDef[vRefR].scale,dayCarry);
              SetString(cRefL,pchar(sv),tmv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTimestamp,ctTimestampWithTimezone:
    begin
      tR.GetTimestamp(vRefR,tsv,tsv_null);
      //todo: need to retain time-zone if target has one, not normalise
      case fColDef[cRefL].dataType of
        ctTimestamp,ctTimestampWithTimezone:
        begin
          SetTimestamp(cRefL,tsv,tsv_null);
        end;
        ctTime,ctTimeWithTimezone:
        begin
          //todo data loss error
          SetTime(cRefL,tsv.time,tsv_null);
        end;
        ctDate:
        begin
          //todo data loss error
          SetDate(cRefL,tsv.date,tsv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tsv_null then
            SetString(cRefL,'',tsv_null) //no need to coerce
          else
          begin
            try
              if tR.fvarDef[vRefR].dataType=ctTimestampWithTimezone then
                sv:=sqlTimestampToStr(Ttransaction(st.owner).timezone,tsv,tR.fvarDef[vRefR].scale)
              else
                sv:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,tR.fvarDef[vRefR].scale);
              SetString(cRefL,pchar(sv),tsv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fvarDef[vRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBlob,ctClob:
    begin
      tR.GetBlob(vRefR,bv,bv_null);
      case fColDef[cRefL].dataType of
        ctBlob,ctClob:
          SetBlob(st,cRefL,bv,bv_null);

        ctChar,ctVarChar: //note: conversion not required by standard CAST for ctBlob
        begin
          if bv_null then
            SetString(cRefL,'',bv_null) //no need to coerce
          else
            try
              if copyBlobData(st,bv,bvData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                  //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
              begin
                SetLength(sv,bvData.len);
                StrMove(pchar(sv),pchar(bvData.rid.pid),bvData.len);
                SetString(cRefL,pchar(sv),bv_null);
              end;
            finally
              freeBlobData(bvData);
            end; {try}
        end;

        //todo convert blob to others? note: not required by standard CAST
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctBlob,ctClob}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefR,ord(tR.fvarDef[vRefR].dataType)]),vAssertion); //todo error?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  result:=ok;
end; {CopyVarDataDeepGetSet}

function TTuple.CopyColDataDeepGetUpdate(st:TStmt;cRefL:colRef;tR:TTuple;cRefR:ColRef):integer;
{Copies the data from one tuple column and appends to another tuple as an update
 (This is a deep copy: the bytes are actually moved, not just the data pointers)
 IN:         tran                the caller transaction - may be needed for local timezone
             cRefL               this tuple column to copy to
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok, or fail

 Assumes:
   target and source tuples/sets are already defined
   target update data has not already been appended to data record
   copying is called in target column order, as for UpdateInteger etc.

 Note:
   if column data is not compatible/coercible then we fail,
   but column definitions don't need to read each other's raw data, as we use Get then Update

   Written for IterUpdate where we're updating an existing target area from a variable typed source
   Safer but slower than CopyColDataDeep

   Keep in sync with CopyColDataDeepGetSet (& TvariableSet routines)
}
const routine=':CopyColDataDeepGetUpdate';
var
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv,bv2:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;
begin
  result:=fail;

  {$IFDEF SAFETY}
  {Assert cRefL is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefL>fColCount-1) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefL,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefR>tR.fcolCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[cRefR,tR.fcolCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {Set these in case we read an integer & try to set a string - i.e. coerce to null}
  //todo need to spot such problems in future as errors or 'implicit' coercions e.g. string->integer
  //todo we can remove these now....
  sv_null:=true;
  iv_null:=true;
  biv_null:=true;
  dv_null:=true;
  dtv_null:=true;
  tmv_null:=true;
  tsv_null:=true;
  bv_null:=true;

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?
  {Read the data
   and copy the data by setting the target columns (safer than pointers + block copying)
  }
  case tR.fColDef[cRefR].dataType of
    ctChar,ctVarChar,ctBit,ctVarBit:
    begin
      tR.GetString(cRefR,sv,sv_null);
      case fColDef[cRefL].dataType of
        ctChar,ctVarChar,ctBit,ctVarBit:
          UpdateString(cRefL,pchar(sv),sv_null);
        ctInteger,ctSmallInt:
        begin
          if sv_null then
            UpdateInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              iv:=strToInt(sv); //todo check range for smallint...
              UpdateInteger(cRefL,iv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBigInt:
        begin
          if sv_null then
            UpdateBigInt(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              biv:=strToInt64(sv); //todo check range for smallint...
              UpdateBigInt(cRefL,biv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctFloat:
        begin
          if sv_null then
            UpdateInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              UpdateDouble(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctNumeric,ctDecimal:
        begin
          if sv_null then
            UpdateInteger(cRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              UpdateComp(cRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          if sv_null then
            UpdateDate(cRefL,dtv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              dtv:=strToSqlDate(sv);
              UpdateDate(cRefL,dtv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          if sv_null then
            UpdateTime(cRefL,tmv{todo! use TIME_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimeWithTimezone then
                tmv:=strToSqlTime(Ttransaction(st.owner).timezone,sv,dayCarry)
              else
                tmv:=strToSqlTime(TIMEZONE_ZERO,sv,dayCarry);
              UpdateTime(cRefL,tmv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          if sv_null then
            UpdateTimestamp(cRefL,tsv{todo! use TIMESTAMP_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fColDef[cRefL].dataType=ctTimestampWithTimezone then
                tsv:=strToSqlTimestamp(Ttransaction(st.owner).timezone,sv)
              else
                tsv:=strToSqlTimestamp(TIMEZONE_ZERO,sv);
              UpdateTimestamp(cRefL,tsv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          if sv_null then
            UpdateBlob(st,cRefL,bv{todo! use BLOB_ZERO},sv_null) //no need to coerce
          else
          begin
            bv.rid.sid:=0; //i.e. in-memory blob
            bv.rid.pid:=pageId(pchar(sv)); //pass syntax data pointer as blob source in memory
            bv.len:=length(sv);
            UpdateBlob(st,cRefL,bv,sv_null); //sv_null is always false
          end;
        end; {ctBlob,ctClob}
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctInteger,ctSmallInt:
    begin
      tR.GetInteger(cRefR,iv,iv_null);
      case fColDef[cRefL].dataType of
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          UpdateInteger(cRefL,iv,iv_null);
        end;
        ctBigInt:
          UpdateBigInt(cRefL,iv,iv_null);
        ctFloat:
          UpdateDouble(cRefL,iv,iv_null);
        ctNumeric,ctDecimal:
        begin
          UpdateComp(cRefL,iv,iv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if iv_null then
            UpdateString(cRefL,'',iv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(iv);
              UpdateString(cRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBigInt:
    begin
      tR.GetBigInt(cRefR,biv,biv_null);
      case fColDef[cRefL].dataType of
        ctBigInt:
          UpdateBigInt(cRefL,biv,biv_null);
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          UpdateInteger(cRefL,integer(biv),biv_null);
        end;
        ctFloat:
          UpdateDouble(cRefL,biv,biv_null);
        ctNumeric,ctDecimal:
        begin
          UpdateComp(cRefL,biv,biv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if biv_null then
            UpdateString(cRefL,'',biv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(biv);
              UpdateString(cRefL,pchar(sv),biv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctFloat:
    begin
      tR.GetDouble(cRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          UpdateDouble(cRefL,dv,dv_null);
        end;
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          UpdateComp(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          UpdateInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          UpdateBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            UpdateString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              UpdateString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctNumeric,ctDecimal:
    begin
      tR.GetComp(cRefR,dv,dv_null);
      case fColDef[cRefL].dataType of
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          UpdateComp(cRefL,dv,dv_null); //todo fix/check
        end;
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          UpdateDouble(cRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          UpdateInteger(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          UpdateBigInt(cRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            UpdateString(cRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              UpdateString(cRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctDate:
    begin
      tR.GetDate(cRefR,dtv,dtv_null);
      case fColDef[cRefL].dataType of
        ctDate:
        begin
          UpdateDate(cRefL,dtv,dtv_null); //todo fix/check
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if dtv_null then
            UpdateString(cRefL,'',dtv_null) //no need to coerce
          else
          begin
            try
              sv:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]);
              UpdateString(cRefL,pchar(sv),dtv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTime,ctTimeWithTimezone:
    begin
      tR.GetTime(cRefR,tmv,tmv_null);
      case fColDef[cRefL].dataType of
        ctTime,ctTimeWithTimezone:
        begin
          UpdateTime(cRefL,tmv,tmv_null); //todo fix/check
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          tsv.date:=Ttransaction(st.owner).currentDate; //DATE_ZERO;
          tsv.time:=tmv;
          UpdateTimestamp(cRefL,tsv,tmv_null);
        end;
        ctDate,
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            UpdateString(cRefL,'',tmv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimeWithTimezone then
                sv:=sqlTimeToStr(Ttransaction(st.owner).timezone,tmv,tR.fColDef[cRefR].scale,dayCarry)
              else
                sv:=sqlTimeToStr(TIMEZONE_ZERO,tmv,tR.fColDef[cRefR].scale,dayCarry);
              UpdateString(cRefL,pchar(sv),tmv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTimestamp,ctTimestampWithTimezone:
    begin
      tR.GetTimestamp(cRefR,tsv,tsv_null);
      //todo: need to retain time-zone if target has one, not normalise
      case fColDef[cRefL].dataType of
        ctTimestamp,ctTimestampWithTimezone:
        begin
          UpdateTimestamp(cRefL,tsv,tsv_null); //todo fix/check
        end;
        ctTime,ctTimeWithTimezone:
        begin
          //todo data loss error
          UpdateTime(cRefL,tsv.time,tsv_null);
        end;
        ctDate:
        begin
          //todo data loss error
          UpdateDate(cRefL,tsv.date,tsv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tsv_null then
            UpdateString(cRefL,'',tsv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimestampWithTimezone then
                sv:=sqlTimestampToStr(Ttransaction(st.owner).timezone,tsv,tR.fColDef[cRefR].scale)
              else
                sv:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,tR.fColDef[cRefR].scale);
              UpdateString(cRefL,pchar(sv),tsv_null)
            except 
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[cRefL,ord(tR.fColDef[cRefR].dataType),ord(fColDef[cRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBlob,ctClob:
    begin
      tR.GetBlob(cRefR,bv,bv_null);
      case fColDef[cRefL].dataType of
        ctBlob,ctClob:
          UpdateBlob(st,cRefL,bv,bv_null);

        ctChar,ctVarChar: //note: conversion not required by standard CAST for ctBlob
        begin
          if bv_null then
            UpdateString(cRefL,'',bv_null) //no need to coerce
          else
            try
              if copyBlobData(st,bv,bv2)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                  //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
              begin
                SetLength(sv,bv2.len);
                StrMove(pchar(sv),pchar(bv2.rid.pid),bv2.len);
                UpdateString(cRefL,pchar(sv),bv_null);
              end;
            finally
              freeBlobData(bv2);
            end; {try}
        end;

        //todo convert blob to others...
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefL,ord(fColDef[cRefL].dataType)]),vAssertion); //todo error?
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctBlob,ctClob}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefR,ord(tR.fColDef[cRefR].dataType)]),vAssertion); //todo error?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  result:=ok;
end; {CopyColDataDeepGetUpdate}


function TTuple.CopyDataToBuffer(var buf:Pchar;var bufLen:integer):integer;
{Copies the data from all tuple columns and appends to a data buffer
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 OUT:        buf   - the tuple data in a pchar array
                     The buffer memory is allocated in this routine
             bufLen- the number of bytes allocated for buf
 RETURNS:    ok, or fail

 Note:
   buffer memory is allocated by this routine
   we can't just copy the tuple buffer because we may be referencing many buffer versions

 Assumes:
   source tuple is already defined
   buf is nil (we assert this) - else memory leak!
}
const routine=':CopyDataToBuffer';
var
  i:ColRef;
  newCoff,coff:ColOffset;
  null:boolean;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
  size:colOffset;
begin
  result:=fail;

  if buf<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('buffer is already allocated',[1]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  //{$ENDIF}

  {Find out space required}
  size:=sizeof(colRef); //size of buffer needed
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      //allow space for column specifiers + data space
      //todo debugAssert nextCoff-coff=len
      size:=size+sizeof(TColId)+sizeof(coff)+fColData[i].len;
    end;
  //todo else (internal?) warning
  //allow space for final column specifier
  size:=size+sizeof(TColId)+sizeof(coff);

  {Allocate memory}
  bufLen:=size;
  getMem(buf,bufLen);
  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('allocated %d byte buffer',[size]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {Add initial column count} //this is needed by record reading routines (delta's have variable number of columns)
  move(fColCount,buf[0],sizeof(fColCount));

  {Copy the data to the buffer
   Note: we have to do this column by column because they could be pointing to separate data areas}
  size:=sizeof(colRef)+((fColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      move(fColData[i].dataPtr^[fColData[i].offset],coff,sizeof(coff)); //get offset for this column
      //todo debugAssert nextCoff-coff=len
      if fColData[i].len=0 then null:=true else null:=false;

      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('column %d offset=%d',[i,coff]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if not null and (size+fColData[i].len>=MaxRecSize) then        //todo remove?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.cleared)',[size]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit;
      end;

      newCoff:=size;
      if not null then
      begin
        //move(fCol[i].dataPtr[coff],buf^[size],(nextCOff-coff)); //move data
        move(fColData[i].dataPtr[coff],buf[newCoff],fColData[i].len); //move data
        size:=size+fColData[i].len;     //increase length
        {$IFDEF DEBUGCOLUMNDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('copied %d bytes for column %d (%s)',[fColData[i].len,i,fColData[i].dataPtr[coff]]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      {Set column specifier}
      move(fColDef[i].Id,buf[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))],sizeof(TcolId));
      move(newCoff,buf[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
    end;
  //else (internal?) warning
  {Add final offset}
  move(size,buf[sizeof(ColRef)+(fColCount*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  //todo final id?

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('final size=%d',[size]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  result:=ok;
end; {CopyDataToBuffer}
function TTuple.CopyDataToFixedBuffer(buf:Pchar;var bufLen:integer):integer;
{Copies the data from all tuple columns and appends to a data buffer
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 OUT:        buf   - the tuple data in a pchar array
                     The buffer memory is not allocated in this routine
             bufLen- the number of bytes returned in buf
 RETURNS:    ok, or fail

 Note:
   buffer memory is not allocated by this routine
   we can't just copy the tuple buffer because we may be referencing many buffer versions

 Assumes:
   source tuple is already defined
   buf is pre-allocated big enough for largest record - else crash!
    - //todo pass sizeof(buf) to avoid this! TODO!
}
const routine=':CopyDataToFixedBuffer';
var
  i:ColRef;
  newCoff,coff:ColOffset;
  null:boolean;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
  size:colOffset;
begin
  result:=fail;

  if buf=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('buffer is not already allocated',[1]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  //{$ENDIF}

  {Add initial column count} //this is needed by record reading routines (delta's have variable number of columns)
  move(fColCount,buf[0],sizeof(fColCount));

  {Copy the data to the buffer
   Note: we have to do this column by column because they could be pointing to separate data areas}
  size:=sizeof(colRef)+((fColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      move(fColData[i].dataPtr^[fColData[i].offset],coff,sizeof(coff)); //get offset for this column
      if fColData[i].len=0 then null:=true else null:=false;

      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('column %d offset=%d',[i,coff]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if not null and (size+fColData[i].len>=MaxRecSize) then        //todo remove?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.cleared)',[size]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit;
      end;

      newCoff:=size;
      if not null then
      begin
        //move(fCol[i].dataPtr[coff],buf^[size],(nextCOff-coff)); //move data
        move(fColData[i].dataPtr[coff],buf[newCoff],fColData[i].len); //move data
        size:=size+fColData[i].len;     //increase length
        {$IFDEF DEBUGCOLUMNDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('copied %d bytes for column %d (%s)',[fColData[i].len,i,fColData[i].dataPtr[coff]]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      {Set column specifier}
      move(fColDef[i].Id,buf[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))],sizeof(TcolId));
      move(newCoff,buf[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
    end;
  //else (internal?) warning
  {Add final offset}
  move(size,buf[sizeof(ColRef)+(fColCount*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  //todo final id?

  bufLen:=size;

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('final size=%d',[size]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  result:=ok;
end; {CopyDataToFixedBuffer}

function TTuple.CopyBufferToData(buf:Pchar;bufLen:integer):integer;
//todo improve name: copyBufferToTuple/rec?
{Copies the data from a data buffer to all tuple columns
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         buf   - the tuple data in a pchar array
             bufLen- the size of the pchar array

 RETURNS:    ok, or fail

 Assumes:
   source tuple is already defined with the correct number of columns
   buffer contains data
}
const routine=':CopyBufferToData';
var
  i:ColRef;
  coff,nextCoff:ColOffset;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
begin
  result:=fail;

  {Copy buffer data}
  move(buf^,fRecData,bufLen);
  fRecList.rec.len:=bufLen;
  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('copied %d byte buffer to tuple',[fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {Set column data pointers}
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      //todo next two settings are redundant if we kept the original settings from 'clear' routine
      fColData[i].dataPtr:=fRecList.rec.dataPtr; //output buffer
      //todo remove next line- offset should always be same! ?
      fColData[i].offset:=sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
      fColData[i].blobAllocated:=false; //

      //todo throughout!: use sizeof(TcolId) OR sizeof(cid) - could be different?!
      move(fColData[i].dataPtr^[fColData[i].offset],coff,sizeof(coff)); //get offset for this column //todo remove- only for debug

      move(fColData[i].dataPtr^[fColData[i].offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
      fColData[i].len:=nextCoff-coff; //re-calculate column data length
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('repointed column %d to offset %d, len %d (%s)',[i,coff,fColData[i].len,fColData[i].dataPtr^[coff]]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
    end;
  //else (interal?) warning

  //todo maybe assert 0th word = fColCount?
  //move(fColCount,buf[0],sizeof(fColCount));

  result:=ok;
end; {CopyBufferToData}

function TTuple.GetDataLen:integer;
{Added for TVirtualFile}
begin
  result:=fRecList.rec.len;
end; {GetDataLen}


function TTuple.Unpin(st:TStmt):integer;
{Unpins page list
 RETURN : +ve=ok, else fail
}
const routine=':Unpin';
var
  pZap:TPageList;
begin
  result:=ok;
  {Unpin page chain}
  pZap:=fPageList;
  while pZap<>nil do
  begin
    if pZap.page<>nil then
      if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,pZap.page.block.thisPage)=ok then
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unpinned record page %d',[pZap.page.block.thisPage{note: unsafe ref}]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        pZap.page:=nil;
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed unpinning page %d from existing tuple - ignoring',[pZap.page.block.thisPage]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}

    pZap:=pZap.next;
  end;
end; {Unpin}

function TTuple.FreeRecord(st:TStmt):integer;
{Unpins page list and frees record chain
 RETURN : +ve=ok, else fail
}
const routine=':FreeRecord';
var
  rZap:TRecList;
  pZap:TPageList;
begin
  result:=ok;
  {Free record chain (except initial header)}
  while fRecList.next<>nil do
  begin
    rZap:=fRecList.next;
    fRecList.next:=rZap.next;
    {$IFDEF DEBUGDETAIL3}
    {$IFDEF DEBUG_LOG}
    if rZap.rec=nil then
      log.add(who,where+routine,format('Free error',[nil]),vAssertion);
    {$ENDIF}
    {$ENDIF}
    rZap.rec.free;
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDestroy);
    {$ENDIF}
    rZap.free;
  end;

  if st<>nil then Unpin(st);
  //todo else: perform unpin checks/none transaction based releases!?

  {Free page chain (except initial header)}
  while fPageList.next<>nil do
  begin
    pZap:=fPageList.next;
    fPageList.next:=pZap.next;
    pZap.free;
    {$IFDEF DEBUGDETAIL3}
    inc(debugPagelistDestroy);
    {$ENDIF}
  end;
end; {FreeRecord}


function TTuple.read(st:TStmt;rid:Trid;attempt:boolean):integer;
{Reads a specific tuple from the file
 This reads all versions of the record that are needed and also
 maps the current column definitions to point to the appropriate data, and calculates
 and sets their lengths.

 Note:
 The pages referenced are all pinned until the next read (or until UnPin is run)

 The tuple's fRID is set by this routine for reference

 IN      : st              the statement
           rid             the record to read (with all appropriate deltas)
           attempt         True=>caller expects that rid may be invalid
                           (i.e. calling from an index pointer that may be out of date)
                           so will not log corruption errors & will return noData instead of fail
                           in extreme cases (e.g. slot/page is no longer valid)
 RETURN  : ok,     record read
           noData, record read ok, but invisible to this transaction (ignore result)
                   (Note: if attempt=True, could be because of old rid->now-empty slot (or even missing page!)
           else fail

 Note:
  the column offsets point to the column offset slots, not directly to the data.

  This routine can fail genuinely (result=noData) if the current transaction
  cannot see this record
  (i.e. it was deleted before we started, or created after we started,
        or was created by a transaction that we cannot see
        (e.g. because it was not committed when we started)
        or the old history has been wiped too early - shouldn't happen!
  )

  This routine is the basis for garbageCollect & readToIndex: keep in sync.

 Assumes:
   we already have the tuple format
}
const routine=':Read';
var
  newPage,thispage:TPageList;
  newRec, thisrec:TRecList;
  versionCount, i:integer;
  needOlderVersion:boolean;
  rColCount:ColRef;
  j, k:ColRef;
  cid:TColId;
  coff,nextCoff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  UnPin(st); //unpin from previous read

  thispage:=fPageList;       //first page (note: might have an existing chain in place that we can re-use, i.e. cached)
  thisrec:=fRecList;         //first rec
  versionCount:=0;
  repeat
    {move to & pin the appropriate page - stores the page reference in thisPage}
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,thispage.page)<>ok then
    begin
      if attempt and (versionCount=0) then
      begin
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record is invisible because the page was purged (%d) before/when we started, skipping',[rid.pid{,tr.Rt.TranId}]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        result:=noData;
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
        {$ELSE}
        ;
        {$ENDIF}
      exit; //reject/abort
    end;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Pinned record page %d',[rid.pid]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {read the record & store its pointer}
    if (owner as TRelation).dbFile.ReadRecord(st,thisPage.page,rid.sid,thisRec.rec)=ok then
    begin
      if thisRec=fRecList then
      begin
        if not(thisrec.rec.rtype in [rtRecord,rtDeletedRecord]) then
        begin
          if attempt and (versionCount=0){todo remove:can assume:speed} then
          begin
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Next record is invisible because it was no longer a header (%d) before/when we started, skipping',[thisrec.rec.Wt.tranId{,tr.Rt.TranId}]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            result:=noData;
          end
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('First record is not a record header %d:%d, continuing',[rid.pid,rid.sid]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
          exit; //reject/abort
        end;
        {We store the RID of the header record now for any future use
         - we re-use rid below to traverse any version record list, so
           we store it now because we never update or directly touch
           any deeper version}
        fRID:=rid;
      end
      else
        if thisrec.rec.rtype<>rtDelta then //todo what about rolled-back deletes? i.e. ignoreable tomb-stones - these are converted to delta during update!
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Next record [%d] is not a record delta %d:%d, continuing',[versionCount,rid.pid,rid.sid]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;

      {Check if this is a deleted record, if so do we have a chance of seeing
       its history?}
      if thisRec=fRecList then  //todo note: a delete anywhere else => was rolledback = skip it
        if thisrec.rec.rtype=rtDeletedRecord then
          if st.CanSee(thisRec.rec.Wt,True) then
          begin //zapped (& committed the zap) before/when we started, so abort
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Next record is invisible because it was deleted (%d) before/when we started, skipping',[thisrec.rec.Wt.tranId{,tr.Rt.TranId}]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            result:=noData;
            exit; //reject
          end;
    end
    else
    begin
      if attempt and (versionCount=0) then
      begin
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record is invisible because it was no longer readable (%d) before/when we started, skipping',[rid.sid{,tr.Rt.TranId}]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        result:=noData;
      end
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' Failed reading %d:%d',[rid.pid,rid.sid]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
      exit; //reject/abort
    end;

    {if Wt is too recent then prepare for another read loop}
    needOlderVersion:=st.CannotSee(thisRec.rec.Wt);
    if thisRec.rec.len=0 then needOlderVersion:=True; //skip forward RIDs //todo check ok test here?   //always???
    if needOlderVersion then
    begin
      {todo: maybe if thisRec.rec.Wt is in our uncommitted list as tsRolledBack
             (i.e. get reason-code back from CannotSee routine! - or use Before=>rolled-back)
             then we could/should take the opportunity to remove this record version from the history now
             - or at least pass its rid to a background sweeper, or add to sweeper's todo list...
       Note: we should have hooks to do this whenever we read record versions, e.g. delete/update routines
       The switch to clean-now or postpone should be on the transaction...
      }

      if thisRec.rec.prevRID.pid=InvalidPageId then //sanity check
      begin
        {This was created after our transaction - it is in our future, or wasn't committed when we started &
         so is hidden from us (or has been rolled back & so needs garbage collecting)}
        //todo: note we cannot tell difference between this, and a too-early (crashed?) purge... either way there's not much we can read of any use
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record is invisible (%d) to us, skipping',[thisrec.rec.Wt.tranId{,tr.Rt.TranId}]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
        result:=noData;
        exit; //reject
      end;
      rid:=thisRec.rec.prevRID; //loop again to read next version

      {move to next free page pointer}
      if thispage.next=nil then
      begin //no more in list, create an extra one
        newPage:=TPageList.create; 
        {$IFDEF DEBUGDETAIL3}
        inc(debugPagelistCreate);
        {$ENDIF}
        thispage.next:=newPage;  //link
      end;
      thispage:=thispage.next; //move to next page slot
      {$IFDEF DEBUGDETAIL3}
      if thisPage.page<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next page in chain is not nil when chaining version',[nil]),vAssertion); //=> not unpinned?
        {$ENDIF}
      end;
      {$ENDIF}

      {move to next free record}
      if thisrec.next=nil then
      begin //no more in list, create an extra one
        newRec:=TRecList.create;  
        newRec.rec:=TRec.create;     //create space for Trec (Note: this is *not* a whole block in size - dataptr points to data in pinned page) 
        {$IFDEF DEBUGDETAIL3}
        inc(debugRecCreate);
        {$ENDIF}
        thisrec.next:=newRec;  //link
      end;
      thisRec:=thisRec.next; //move to next rec slot
    end;

    inc(versionCount);          //number of records used (we never contract chains)
  until not needOlderVersion;

  {Loop through each record version, pointing our columns at the appropriate portion}
  thisRec:=fRecList; //first
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%d:%d [Wt=%d](%d) %s',[fRID.pid,fRID.sid,thisRec.rec.Wt.tranId,thisRec.rec.len,copy(thisRec.rec.dataPtr^,0,thisRec.rec.len)]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  for i:=1 to versionCount do
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Version %d [Wt=%d](%d) prevRID=%d:%d %s',[i,thisRec.rec.Wt.tranId,thisRec.rec.len,thisRec.rec.prevrid.pid,thisRec.rec.prevrid.sid,copy(thisRec.rec.dataPtr^,0,thisRec.rec.len)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    {Loop through each column slot in the record header}
    //todo+ maybe continue here if i<>1 and tr.CannotSee(thisRec.rec.Wt)? i.e. skip rolled-back deltas along the way: speed
    if thisRec.rec.len<>0 then
    begin
      move(thisRec.rec.dataPtr^[0],rColCount,SizeOf(rColCount));
      //todo assert rcolCount<colCount!? => corrupt
      if rColCount>0 then //Note: could be 0 columns if delta'd for deletion (etc.?)
        for j:=0 to rColCount-1 do
        begin
          {If this column id existed when our transaction started, then we need it}
          move(thisRec.rec.dataPtr^[sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))],cid,sizeof(cid));
          //todo only bother to store if cid is to be projected/used later?
          {Find this column id in our tuple column definition}
          //todo Note: start k:=0 outside 'for j' loop - it *always* increments! ?check? =faster
          //todo hash column id onto ColDefs?
          //todo don't bother looking if cid>our-highest-cid
          k:=0;
          while k<fColCount do
          begin
            if fColDef[k].id=cid then
              break;
            inc(k);
          end;
          if k<fColCount then
          begin //we found this col id in the current tuple definition
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Matched column id %d in version %d at col-ref %d',[cid,i,k]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            {Store the pointer to this record version and column offset slot
             (slot rather than data offset because we need to access the
             'next' slot later to calculate the data length, and makes multi-access
             easier?)
             Remember, the record versions are in pinned pages
             }
            fColData[k].dataPtr:=thisRec.rec.dataPtr;
            fColData[k].offset:=sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))+sizeof(cid);
            fColData[k].blobAllocated:=false; //
            {Get column length}
            //todo speed: use j-1 to get last offset and then only need 1 move below to get length
            //     i.e. we currently: move(1), move(2)   move(2), move(3)    move(3), move(4) ..etc...
            //          surely could: move(1), move(2)   move(3)             move(4)          ..etc...
            move(fColData[k].dataPtr^[fColData[k].offset],coff,sizeof(coff)); //get data offset for this column
            move(fColData[k].dataPtr^[fColData[k].offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
            fColData[k].len:=nextCoff-coff; //from now on, we will reference & update this value
          end
          else
          begin
            //else this col id must be a new one, added since our transaction started (actually, opened this relation) - we ignore it
            // {$IFDEF DEBUGDETAIL}  //todo re-hide after testing with schema updates etc.
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Not matched column id %d in version %d (this is ok if looking for duplicate keys)',[cid,i]),vDebugWarning); 
            {$ELSE}
            ;
            {$ENDIF}
            //this is not a problem during relation.isUnique, since we read just the key columns and ignore any others            
            // {$ENDIF}
          end;
        end; {for each column slot}
    end; //else 0 data stored here, must just be a forwarding RID
         //todo: maybe do same for deletions instead of rtDeletedRecord? - i.e. proper tombstone
    {Look at the next record version, if any}
    thisRec:=thisRec.next; ///note: bugfix 08/07/99 to allow more than 2 versions!  fRecList.next;
  end; {for each record version}
  {end result=colDefs[] = array of record pointers+slot-column-offsets+data-lengths which specify the record+column
   - each page involved is pinned
   ideally: 1 page involved + 1 record so all ColDefs[] have same recPtr + consecutive column-slot-offsets
   e.g. coldef[1].dataptr=1 coldef[1].offset=1 coldef[2].dataptr=1 coldef[2].offset=2 etc.
   worse: 1 page per column - unlikely to cause a problem? - what about length=nextCoff-coff? -we store lengths in memory, so should be easy to handle once we calculate it here.
   Worsens after each update until garbage collection after all committed transactions are swept away
  }
  result:=ok;
end; {read}

function TTuple.delete(st:TStmt;rid:Trid):integer;
{Deletes a specific tuple from the file
 This may delta the whole record for the final time & mark the record as deleted.

 IN      : st              the statement
           rid             the record to delete
 RETURN  : +ve=ok
           -2 = too late, already updated by a 'later' active tran
           else fail

 Assumes:

 Note:
   this routine treats the tuple owner as a THeapFile rather than the generic TFile
   this is to allow some specific header updates that don't really belong in Tfile

   The tuple's fRID is set by this routine for reference

 Note:
   we use Tr.Wt for timestamping
}
const
  routine=':Delete';
  tooLate=-2;
var
  page:TPage;
  needOlderVersion:boolean;
  i:ColRef;

  newRid:TRid;
  saveSlot:TSlot;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {afterthought: haven't we always just read and pinned this Rid?
    -no, we may read matches from leftChild iterator and then delete that RID from our own relation's iTuple
    - this way, we can read old values and delete from a fresh 'view' of the file
    - this will probably be more important during an update, e.g. update set x=x+1 (where x>3)...
    Although may be worth not unpinning & re-reading here (& in Update()) to see if we improve speed/logic
    - but don't we need to re-read to ensure we can see the 1st record
     - but we wouldn't be here if we couldn't see it...
  }

  unPin(st); //todo debug only- I think without this, the previous read's pinned pages are screwed

  {move to & pin the appropriate page - stores the page reference in thisPage}
  if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,page)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  try
    {We latch the header page to ensure our checks + versioning are undisturbed}
    {Note: we could try to latch another page below (addRecord) (hopefully not: delta=empty) which could cause deadlock
           so the latch routine will now time-out to avoid this: so one of the routines would fail!
           Note: result=fail here, so latch fail=>return fail
    }
    if page.latch(st)=ok then
    try
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Pinned and latched record page %d',[rid.pid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {read the record & store its pointer}
      if (owner as TRelation).dbFile.ReadRecord(st,page,rid.sid,fRecList.rec)=ok then
      begin
        //todo ifdef safety? speed
        if not(fRecList.rec.rtype in [rtRecord,rtDeletedRecord]) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('First record is not a record header %d:%d, aborting',[rid.pid,rid.sid]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;
        //Note: we allow deletes past records already deleted by a future transaction
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' Failed reading %d:%d',[rid.pid,rid.sid]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;

      if not st.CanUpdate(fRecList.rec.Wt) then
      begin
        {We cannot delete this tuple, since a later or active earlier transaction than ours has already updated it}
        //todo+: we could wait here to see if the conflicting version will be rolled back?
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Cannot delete this tuple - another (later or active earlier) transaction %d:%d has already updated it (we are %d:%d)',[fRecList.rec.Wt.tranId,fRecList.rec.Wt.stmtId,st.Wt.tranId,st.Wt.stmtId]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        //todo gently rollback caller.... not just abort!
        result:=tooLate;
        exit; //abort
      end;

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('%d:%d [Wt=%d](%d)%s',[rid.pid,rid.sid,fRecList.rec.Wt.tranId,fRecList.rec.len,copy(fRecList.rec.dataPtr^,0,fRecList.rec.len)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      if not st.IsMe(fRecList.rec.Wt) then //we can see it (because we just ruled out CannotSee) but it's not us, so version
      begin //we need to create a delta to indicate who deleted this tuple
        {save the current header details}
        saveSlot.rType:=fRecList.rec.rType;
        saveSlot.Wt:=fRecList.rec.Wt; //todo no need - check!
        saveSlot.PrevRID:=fRecList.rec.prevRID; //todo no need - check!

        {Insert blank delta}  //todo we should really delta all columns and insert a blank deleted record
                              //unless this way is ok, then try to keep it because it is quicker & ensures this rid stays in place
                              // - maybe see the update routine to see how it handles delta placements/space shuffling
        clear(st); //clear this tuple (& so the fRecList)
        i:=0;
        move(i,fRecData[0],SizeOf(ColRef)); //0 columns changed
        fRecList.rec.len:=sizeOf(colRef);   //so not 0 data length as with forwarding RID - see heapfile.updateRecord routine
        fRecList.rec.Wt:=saveSlot.Wt; //set Wt to this latest record
        fRecList.rec.rType:=rtDelta;
        fRecList.rec.prevRID.pid:=saveSlot.prevRID.pid;
        fRecList.rec.prevRID.sid:=saveSlot.prevRID.sid;

        {$IFDEF SAFETY} //todo remove, since we crash if this isn't trapped?
        {Assert owner is valid}
        if not assigned(owner) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Tuple is not associated with a relation',vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end;
        {$ENDIF}

        {Now, add the record}
        result:=(owner as TRelation).dbFile.AddRecord(st,fRecList.rec,newRid);

        if result=ok then
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%d:%d inserted delta [Wt=%d](%d)',[newrid.pid,newrid.sid,fRecList.rec.Wt.tranId,fRecList.rec.len]),vDebugMedium)
          {$ENDIF}
          {$ENDIF}
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed inserting delta [Wt=%d:%d](%d)',[fRecList.rec.Wt.tranId,fRecList.rec.Wt.stmtId,fRecList.rec.len]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;

        {Now update the latest header with
          Wt = the current tr.Wt
          prevRID pointing to the new delta}
        fRecList.rec.rType:=saveSlot.rType; //todo always should be rtRecord header?
        fRecList.rec.Wt:=st.Wt;
        fRecList.rec.prevRID:=newRid; //point to new delta added above
        {Now, update the record header}
        result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeader(st,fRecList.rec,rid);

        {Now, update the record header to mark as deleted}
        result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeaderType(st,rtDeletedRecord,rid);

        {We store the RID of the deleted record now for any future use (e.g index keyPtr deletion)}
        fRID:=rid;
      end
      else
      begin //this record is ours alone, so we might be able to zap it
        if fRecList.rec.prevRID.pid=InvalidPageId then
        begin //we have no history so we can indeed obliterate this record
          fRecList.rec.len:=0; //zap-set length=0 to free page space //todo ok? friendlier way? - not clear!- it resets Wt=0
          result:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,fRecList.rec,rid,True);

          {Now, update the record header to mark as empty}
          result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeaderType(st,rtEmpty,rid);
        end
        else
        begin //we can delete it, but we must not orphan the history so far, so just mark deleted //todo new rec-type=tombstone/forward?
          {Note: we can't even set length=0 because if we rollback, the current record allows us to build a complete historical version
           - otherwise, we have the old deltas, but these are no use without the latest values to fill the blanks}
          {Now, update the record header to mark as deleted}
          result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeaderType(st,rtDeletedRecord,rid);
        end;
        {We store the RID of the deleted record now for any future use (e.g index keyPtr deletion)}
        fRID:=rid;
      end;
      result:=ok;
    finally
      //todo check ok to unlatch before indexes are updated? I think so...
      page.unlatch(st);
    end {try}
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed latching',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;

    //todo: update indexes here?

  finally
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rid.pid)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed unpinning',[rid.pid]),vError);
      {$ENDIF}
      result:=fail;
    end;
  end; {try}
end; {delete}

function TTuple.garbageCollect(st:TStmt;rid:Trid;readFirst:boolean):integer;
{Zaps a specific tuple from the transaction's Rt & any previous versions from the file
 If this includes the header record, then a side-effect is that we free the RID
 and read the tuple if readFirst is True.

 IN      : st              the statement
           rid             the record to delete versions from
           readFirst       if result=purgedDeletedChain then we will have read the tuple
 RETURN  : +ve=ok
           purgedDeletedChain=purged whole deleted chain
           else fail (note: this might hide another result...)

 Assumes:
   //todo: is the following still the case?
    the record has been deemed as having garbage

 Note:
   this routine treats the tuple owner as a THeapFile rather than the generic TFile
   this is to allow some specific header updates that don't really belong in Tfile

   The tuple's fRID is set by this routine for reference

 Note:
   we use Tr.Wt for timestamping

 Note:
   we can't simply treat rolled-back records as garbage for 2 reasons:
        1) they may be in our future, i.e. a concurrent transaction is busy (I don't think we'd see them though here)
        2) if previous records are not rolled-back, we need the latest records to rebuild the earlier committed tuples
           We could unwind & convert chains of such records into a (single?) committed record- hard: future!
           Or we could trace through the chain & if no records are visible then re-trace & trash...
}
const
  routine=':garbageCollect';
  purgedDeletedChain=1;
var
  deleting:boolean;

  initialRid,nextRid:TRid;           //actually previous rid!
  saveSlot:TSlot;
  tempResult:integer;
  saveLen:integer;

  newPage,thispage:TPageList;
  newRec, thisrec:TRecList;
  versionCount:integer;
  needOlderVersion:boolean;
  rColCount:ColRef;
  j, k:ColRef;
  cid:TColId;
  coff,nextCoff:ColOffset;

  startWasRolledBack, restart, purgeBlobs:boolean;
  bv:Tblob;
  bvnull:boolean;
begin
  result:=ok;
  initialRid:=rid; //save passed parameter

  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;
  {$ENDIF}

  {afterthought: haven't we always just read and pinned this Rid?
    -no, we may read matches from leftChild iterator and then delete that RID from our own relation's iTuple
    - this way, we can read old values and delete from a fresh 'view' of the file
    - this will probably be more important during an update, e.g. update set x=x+1 (where x>3)...
    Although may be worth not unpinning & re-reading here (& in Update()) to see if we improve speed/logic
    - but don't we need to re-read to ensure we can see the 1st record
     - but we wouldn't be here if we couldn't see it...
  }

  UnPin(st); //todo debug only- I think without this, the previous read's pinned pages are screwed

  {If this tuple has at least one blob column then we must go through each column as we purge
   and delete any blob data before zapping the record}

  purgeBlobs:=false;
  for j:=0 to fColCount-1 do
    if fColDef[j].dataType in [ctBlob,ctClob] then
    begin
      purgeBlobs:=true;
      break; //found
    end;

 restart:=False;
 repeat //until restart=False   i.e. once, maybe twice
  needOlderVersion:=False; //True=>first phase = find first visible record version
  deleting:=False;         //True=>second phase = purging previous versions

  {Note: we only retain a chain of records/pages if we find a header to be deleted & readFirst=True
         otherwise we throw away each read & unpin as we go = faster & less memory}
  thispage:=fPageList;       //first page
  thisrec:=fRecList;         //first rec //todo use fRecList directly!?
  versionCount:=0;

  rid:=initialRid; //restore initial parameter


  if restart then
  begin
    //{$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Next record will be the start of a rolled-back chain before/when we started %d, will garbage collect it on this second pass',[st.Rt.tranId]),vDebugLow);
    {$ENDIF}
    //{$ENDIF}
    restart:=False; //don't repeat again!
    
    result:=purgedDeletedChain;
    needOlderVersion:=False; //end first phase
    deleting:=True;          //start second phase
  end;

  startWasRolledBack:=False;
  repeat
    {move to & pin the appropriate page - stores the page reference in thisPage}
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,thispage.page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
      {$ENDIF}
      result:=Fail;
      exit; //abort
    end;
    try
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Pinned record page %d',[rid.pid]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      {read the record & store its pointer}
      if (owner as TRelation).dbFile.ReadRecord(st,thisPage.page,rid.sid,thisRec.rec)=ok then
      begin
        if versionCount=0 then
        begin
          if not(thisrec.rec.rtype in [rtRecord,rtDeletedRecord]) then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('First record is not a record header %d:%d (%d), continuing - ok if forwarder is 1st',[rid.pid,rid.sid,ord(thisrec.rec.rtype)]),vDebugError);
            {$ENDIF}
            //bugfix 15/11/02 - if forwarder starts then ok for 2nd record to have versionCount=0
            //result:=Fail;
            //exit; //abort
          end;
          {We store the RID of the header record now for any future use
           - we re-use rid below to traverse any version record list, so
             we store it now because we never update or directly touch
             any deeper version}
          fRID:=rid;
        end
        else
          if thisrec.rec.rtype<>rtDelta then //todo what about rolled-back deletes? i.e. ignoreable tomb-stones - these are converted to delta during update!
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Next record [%d] is not a record delta %d:%d, continuing',[versionCount,rid.pid,rid.sid]),vAssertion);
            {$ENDIF}
            result:=Fail;
            exit; //abort
          end;

        {Check if this is a deleted record, if so do we have a chance of purging it and
         its history?}
        if versionCount=0 then  //todo note: a deleteRecord anywhere else=>rolled back = skip it
          if thisrec.rec.rtype=rtDeletedRecord then
            if st.CanSee(thisRec.rec.Wt,True) then
            begin //zapped (& committed the zap) before/when we started, so we can delete it and all previous versions
              {$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Next record was deleted (%d) before/when we started, will garbage collect it and previous versions',[thisrec.rec.Wt.tranId{,tr.Rt.tranId}]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              result:=purgedDeletedChain;
              needOlderVersion:=False; //end first phase
              deleting:=True;          //start second phase
            end;

        {Check if this is an invisible header-only old record, if so we can purge it, i.e. rolled back insert}
        //Note! todo!: don't do this to sysTran/sysTranStmt! else deletes rollback history = shows ALL db garbage!!!
        if versionCount=0 then  //note: an header-only old record anywhere else=>visible or rolled back + having some visible history
          if thisRec.rec.prevRID.pid=InvalidPageId then //no history
          begin
            {Was this created before our transaction}
            if thisRec.rec.Wt.tranId<st.Rt.tranId then
            begin //this might be a rolled-back record header
              if st.CannotSee(thisRec.rec.Wt) then
              begin //invisible header with no history, so we can delete it
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Next record was a rolled-back header (%d) before/when we started, will garbage collect it',[thisrec.rec.Wt.tranId{,tr.Rt.tranId}]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                result:=purgedDeletedChain;
                needOlderVersion:=False; //end first phase
                deleting:=True;          //start second phase
              end;
            end;
          end;
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' Failed reading %d:%d',[rid.pid,rid.sid]),vDebugError);
        {$ENDIF}
        result:=Fail;
        exit; //abort
      end;

      if deleting then
      begin
        //Note: todo: if we fail half-way through the chain deletion, we will leave orphaned records!
        //todo: either start from end (too slow) or have an orphan detector (or dump & restore?)
        // todo!- at least let garbage collector clean them up rather than abort next time! especially if they can cause other routine to abort - check!
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Deleting %d:%d (%d:%d) size=%d',[rid.pid,rid.sid,thisrec.rec.Wt.tranId,thisrec.rec.Wt.stmtId,thisRec.rec.len]),vDebugLow);
        {$ENDIF}
        {$ENDIF}

        //todo call delete here instead of duplicating code?

        {If required, glean column data from this record version before we zap it
         - we will also preserve it in memory (with the page pinned) below
         Note: future: this means we can't de-allocate the page just yet even if it has become empty...
               - caller could do this once it's finished with the read-garbage?
         Also use this section to zap blobs (if we have any blob columns)}
        if ( (result=purgedDeletedChain) and readFirst ) or purgeBlobs then
        begin
          {Loop through this record version, pointing our columns at the appropriate portion, or zapping blob data}
          {Note: although this was copied from tuple.read, we do actually go through all versions here one by one not just those that should be visible}
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%d:%d [Wt=%d](%d) %s',[fRID.pid,fRID.sid,thisRec.rec.Wt.tranId,thisRec.rec.len,copy(thisRec.rec.dataPtr^,0,thisRec.rec.len)]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          begin
            {Loop through each column slot in the record header}
            //todo+ maybe continue here if i<>1 and tr.CannotSee(thisRec.rec.Wt)? i.e. skip rolled-back deltas along the way: speed
           //todo remove if not Ttransaction(st.owner).db.TransactionIsRolledBack(thisRec.rec.Wt) then
           {need since we are deleting the whole chain, we try to ignore rolled-back data //todo: ok? we need to take account of rolled back data sometimes!}
           {todo: the following was removed because we do need to see uncommitted (rolled-back) data to be able to de-allocate space etc. e.g. rolled-back table creation
                  Should be safe since we only set purgedDeletedChain if we originally could see this roll-back, i.e. prior to garbage collector: needs testing with GC running at any time!
           if not tr.CannotSee(thisRec.rec.Wt) then //todo assumes garbage collector readsCommitted (not serializable!)
           }
            if thisRec.rec.len<>0 then
            begin
              move(thisRec.rec.dataPtr^[0],rColCount,SizeOf(rColCount));
              //todo assert rcolCount<colCount!? => corrupt
              if rColCount>0 then //Note: could be 0 columns if delta'd for deletion (etc.?)
                for j:=0 to rColCount-1 do
                begin
                  {If this column id existed when our transaction started, then we need it}
                  move(thisRec.rec.dataPtr^[sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))],cid,sizeof(cid));
                  //todo only bother to store if cid is to be projected/used later?
                  {Find this column id in our tuple column definition}
                  //todo Note: start k:=0 outside 'for j' loop - it *always* increments! ?check? =faster
                  //todo hash column id onto ColDefs?
                  //todo don't bother looking if cid>our-highest-cid
                  k:=0;
                  while k<fColCount do
                  begin
                    if fColDef[k].id=cid then
                      break;
                    inc(k);
                  end;
                  if k<fColCount then
                  begin //we found this col id in the current tuple definition
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Matched column id %d in version %d at col-ref %d',[cid,0,k]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    {Store the pointer to this record version and column offset slot
                     (slot rather than data offset because we need to access the
                     'next' slot later to calculate the data length, and makes multi-access
                     easier?)
                     Remember, the record versions are in pinned pages
                     }
                    fColData[k].dataPtr:=thisRec.rec.dataPtr;
                    fColData[k].offset:=sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))+sizeof(cid);
                    fColData[k].blobAllocated:=false; //
                    {Get column length}
                    //todo speed: use j-1 to get last offset and then only need 1 move below to get length
                    //     i.e. we currently: move(1), move(2)   move(2), move(3)    move(3), move(4) ..etc...
                    //          surely could: move(1), move(2)   move(3)             move(4)          ..etc...
                    move(fColData[k].dataPtr^[fColData[k].offset],coff,sizeof(coff)); //get data offset for this column
                    move(fColData[k].dataPtr^[fColData[k].offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
                    fColData[k].len:=nextCoff-coff; //from now on, we will reference & update this value

                    {Delete the blob data now before we zap the parent record}
                    {$IFNDEF SKIP_GARBAGE_DELETE}
                    if fColDef[k].dataType in [ctBlob,ctClob] then
                    begin
                      getBlob(k,bv,bvnull);
                      //todo ifdef blobdebug
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Deleting blob at %d:%d (length=%d) for %d in version %d',[bv.rid.pid,bv.rid.sid,bv.len,cid,0]),vDebugWarning); 
                      {$ENDIF}
                      deleteBlobData(st,bv);
                    end;
                    {$ENDIF}
                  end
                  else
                  begin
                    //else this col id must be a new one, added since our transaction started (actually, opened this relation) - we ignore it
                    // {$IFDEF DEBUGDETAIL}  //todo re-hide after testing with schema updates etc.
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Not matched column id %d in version %d (this is ok if looking for duplicate keys)',[cid,0]),vDebugWarning); 
                    {$ENDIF}
                    //this is not a problem during relation.isUnique, since we read just the key columns and ignore any others
                    // {$ENDIF}
                  end;
                end; {for each column slot}
            end; //else 0 data stored here, must just be a forwarding RID
                 //todo: maybe do same for deletions instead of rtDeletedRecord? - i.e. proper tombstone
          end; {for each record version}
          {end result=colDefs[] = array of record pointers+slot-column-offsets+data-lengths which specify the record+column
           - each page involved is pinned
           ideally: 1 page involved + 1 record so all ColDefs[] have same recPtr + consecutive column-slot-offsets
           e.g. coldef[1].dataptr=1 coldef[1].offset=1 coldef[2].dataptr=1 coldef[2].offset=2 etc.
           worse: 1 page per column - unlikely to cause a problem? - what about length=nextCoff-coff? -we store lengths in memory, so should be easy to handle once we calculate it here.
           Worsens after each update until garbage collection after all committed transactions are swept away
          }
        end;
        {End of column data glean}

        nextRid:=thisRec.rec.prevRID; //save previous pointer before we blank it
        saveLen:=thisRec.rec.len;     //save record length before we blank it: caller reading tuple data will need this
        {$IFNDEF SKIP_GARBAGE_DELETE}
        {First update the record header to mark as empty}
        thisRec.rec.rType:=rtEmpty;
        {Reset this record's previous RID pointer}
        thisRec.rec.prevRID.pid:=InvalidPageId;
        thisRec.rec.prevRID.sid:=InvalidSlotId;
        tempResult:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeader(st,thisRec.rec,rid);

        {Now remove the record data}
        thisRec.rec.len:=0; //zap-set length=0 to free page space //todo ok? friendlier way? - not clear!- it resets Wt=0
        tempResult:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,thisRec.rec,rid,False);

        //todo: track whether we do any deletions and if so, call ReorgPage?
        //      also might be nice to first/at-least de-allocate any empty slots at end of slot array...?
        //      - e.g. 50 empty slots take up a lot of space & we might only need 1 in future on this page...
        //      plus increase contiguous space count on page header if we can...
        {$ENDIF}
        thisRec.rec.len:=saveLen; //restore the record length in memory after we truncated it
                                  //Note: needed especially if readFirst, but also tested further down to determine whether to skip the increment of versionCount
                                  //fix: 19/02/03

        {Now keep the (deleted) history in memory so the caller can read the tuple if required}
        if (result=purgedDeletedChain) and readFirst then
        begin
          //note: moved earlier since it's always needed in the check below: thisRec.rec.len:=saveLen; //restore the record length in memory after we truncated it

          {move to next free page pointer}
          if thispage.next=nil then
          begin //no more in list, create an extra one
            newPage:=TPageList.create; 
            thispage.next:=newPage;  //link
          end;
          thispage:=thispage.next; //move to next page slot
          thisPage.page:=nil;      //i.e. new page
          thisPage.next:=nil;
          {move to next free record}
          if thisrec.next=nil then
          begin //no more in list, create an extra one
            newRec:=TRecList.create;  
            newRec.rec:=TRec.create;     //create space for Trec (Note: this is *not* a whole block in size - dataptr points to data in pinned page) 
            thisrec.next:=newRec;  //link
          end;
          thisRec:=thisRec.next; //move to next rec slot
          thisRec.next:=nil;     //i.e. new rec
        end;

        if nextRid.pid=InvalidPageId then
        begin //this is the end of the chain
          deleting:=False; //end second phase
        end;
        rid:=nextRid; //loop again to read next version
      end
      else
      begin //still looking for first visible record
        {if Wt is too recent then prepare for another read loop}
        {todo: if (versionCount=0) and (thisRec.rec.Wt.tranId<tr.Rt.tranId) and tr.CannotSee(thisRec.rec.Wt) then
                 startWasRolledBack:=True
               //below: if reach invisible dead-end & startWasRolledBack => whole chain of rollback
                  so: re-start & set purgeWholeChain+deleting=True!

         todo: easier way= track startWasRolledBack as above
                below: if reach invisible dead-end & startWasRolledBack => end of rollback chain
                so: delete this final record & next garbage-collection will do same
                    & eventually 1 record will be left & will be caught by code above as 'whole chain deleted'

         todo: even easier way=
                 below: if reach invisible dead-end
                 so: delete this final record & next GC will do same & eventually reach the singleton header=>chain deleted
               FAILED: previous record then pointed to rtEmpty, not delta=corrupt chain! Will try 1st option...

        }
        needOlderVersion:=st.CannotSee(thisRec.rec.Wt);
        if thisRec.rec.len=0 then needOlderVersion:=True; //skip forward RIDs //todo check ok test here?   //always???
        if needOlderVersion then
        begin
          if (versionCount=0) and (thisRec.rec.Wt.tranId<st.Rt.tranId) then
          begin
            {We are at the start of a potentially rolled-back chain: mark it
             If we get to the end & it is rolled back then we can purge the whole chain}
            startWasRolledBack:=True;

            //Note: we could probably handle the case above where we check for singleton headers
            //      using this section of code & the one below... todo rationalise!
          end;

          if thisRec.rec.prevRID.pid=InvalidPageId then //sanity check
          begin
            {This was created after our transaction - it is in our future, or wasn't committed when we started &
             so is hidden from us (or has been rolled back & so needs garbage collecting)}
            if thisRec.rec.Wt.tranId<st.Rt.tranId then
            begin //this must be a rolled-back record at the end of the chain => none of this chain was visible => scrap?
              //todo does this mean we can delete the header? only if transtatus=R (not r)?: No: we would have read partially committed records
              //                                              and only versionCount=0?     : No: we could have had a long chain of rollbacks
              //                                              but we should check 1st version = <Rt to be safe
              //todo if so, return purgedrolledbackheader

              if startWasRolledBack then
              begin
                //{$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Next record is end of rolled-back version chain (%d) and we (%d) will restart to delete the chain',[thisrec.rec.Wt.tranId,st.Rt.Tranid]),vDebugLow);
                {$ENDIF}
                //{$ENDIF}
                needOlderVersion:=False; //there are no more, so don't bother trying! Quit the inner repeat loop
                restart:=True;
                //todo: result=ok?
              end;

              //todo remove: we delete single-rolled back headers earlier: overlap
              //bugfix 15/11/02: was looping forever when hitting an end which started with a forwarder...(i.e. rolled back but always in future)
              //  so now we set make sure we stop looping, and try to avoid this situation by
              //  not increasing versionCount from 0 if 1st record is a forwarder
              needOlderVersion:=False; //there are no more, so don't bother trying! Quit the inner repeat loop
            end
            else
            begin
              //{$IFDEF DEBUGDETAIL2}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Next record is end of a future version chain (%d) and we (%d) will skip it (todo for now)',[thisrec.rec.Wt.tranId,st.Rt.Tranid]),vDebugLow);
              {$ENDIF}
              //{$ENDIF}
              result:=ok;
              exit; //done
            end;
          end
          else
            rid:=thisRec.rec.prevRID; //loop again to read next version

          //if we get here we can't be deleting the whole chain, so no need to keep
        end
        else
        begin
          {We've found a visible version, so delete any versions prior to this one}
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Next record is visible to earliest active tran, will garbage collect any previous versions',[nil{tr.Rt.tranId}]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}

          needOlderVersion:=False; //end first phase //todo remove: redundant!
          deleting:=True;          //start second phase

          nextRid:=thisRec.rec.prevRID; //save previous pointer before we blank it
          if thisRec.rec.prevRID.pid=InvalidPageId then
          begin //this is the end of the chain
            deleting:=False; //end second phase
          end
          else
          begin
            //Note: no need to glean column data before we zap it since we're not purging a whole record chain

            {We must first reset this record's previous RID pointer}
            {$IFNDEF SKIP_GARBAGE_DELETE}
            thisRec.rec.prevRID.pid:=InvalidPageId;
            thisRec.rec.prevRID.sid:=InvalidSlotId;
            result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeader(st,thisRec.rec,rid);
            {$ENDIF}
          end;
          rid:=nextRid; //loop again to read next version
        end;
      end;

      if thisRec.rec.len<>0 then //i.e. don't count initial forwarder to allow startWasRolledBack to be set
        inc(versionCount);          //number of records used (we never contract chains)
    finally
      if not ((result=purgedDeletedChain) and readFirst) then
      begin
        if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,thisPage.page.block.thisPage)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(' %d failed unpinning',[thisPage.page.block.thisPage{note: unsafe ref?}]),vError);
          {$ENDIF}
          result:=fail;
          //note: will continue with loop if necessary... todo ok?
        end
        else //page was unpinned ok so prevent future tuple unpin from trying to do it again
          thisPage.page:=nil;
      end;
      //else tuple chain/page-chain is being stored & will be unpinned later (i.e. scanStop or next read)
    end; {try}
  until not needOlderVersion and not deleting;
 until restart=False; //i.e. once, maybe twice

end; {garbageCollect}

function TTuple.readToIndex(st:TStmt;rid:Trid;iFile:TObject{TIndexFile}):integer;
{Reads a specific tuple from the file and adds all appropriate index entries
 This reads all versions of the record that could be needed by any transaction
 greater than us - so caller should use tr.Rt=earliestActiveTran.

 Note:
 The pages referenced are all pinned until the next read (or until UnPin is run)

 The tuple is built in case reindexing is done in future during a normal scan
 and the tuple's fRID is set by this routine for reference

 IN      : st              the statement
           rid             the record to read and index (with all appropriate deltas)
           iFile           an open index file object (with the name and column mappings defined)

 RETURN  : ok,     record read & index entries added
           noData, record read ok, but invisible to this transaction (ignore result)
           else fail

 Note:
  the column offsets point to the column offset slots, not directly to the data.

  This routine can fail genuinely (result=noData) if the current transaction
  cannot see this record
  (i.e. it was deleted before we started, or created after we started,
        or was created by a transaction that we cannot see
        (e.g. because it was not committed when we started)
        or the old history has been wiped too early - shouldn't happen!
  )

  This routine was copied from the read routine + extra addKey calls in column looping
  (minus 'attempt')

  todo: in future may need to update all indexes in one scan! i.e. if iFile=nil?

 Assumes:
   we already have the tuple format
}
const routine=':ReadToIndex';
var
  newPage,thispage:TPageList;
  newRec, thisrec:TRecList;
  versionCount, i:integer;
  needOlderVersion:boolean;
  rColCount:ColRef;
  j, k:ColRef;
  j2:ColRef;
  cid:TColId;
  coff,nextCoff:ColOffset;
  needToUpdateIndex:boolean;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  UnPin(st); //unpin from previous read

  thispage:=fPageList;       //first page (note: might have an existing chain in place that we can re-use, i.e. cached)
  thisrec:=fRecList;         //first rec
  versionCount:=0;
  repeat
    {move to & pin the appropriate page - stores the page reference in thisPage}
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,thispage.page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
      {$ENDIF}
      exit; //reject/abort
    end;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Pinned record page %d',[rid.pid]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    {read the record & store its pointer}
    if (owner as TRelation).dbFile.ReadRecord(st,thisPage.page,rid.sid,thisRec.rec)=ok then
    begin
      if thisRec=fRecList then
      begin
        if not(thisrec.rec.rtype in [rtRecord,rtDeletedRecord]) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('First record is not a record header %d:%d, continuing',[rid.pid,rid.sid]),vAssertion);
          {$ENDIF}
          exit; //reject/abort
        end;
        {We store the RID of the header record now for any future use
         - we re-use rid below to traverse any version record list, so
           we store it now because we never update or directly touch
           any deeper version}
        fRID:=rid;
      end
      else
        if thisrec.rec.rtype<>rtDelta then //todo what about rolled-back deletes? i.e. ignoreable tomb-stones - these are converted to delta during update!
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Next record [%d] is not a record delta %d:%d, continuing',[versionCount,rid.pid,rid.sid]),vAssertion);
          {$ENDIF}
          exit; //abort
        end;

      {Check if this is a deleted record, if so do we have a chance of seeing
       its history?}
      if thisRec=fRecList then  //note: a delete anywhere else => was rolledback = skip it
        if thisrec.rec.rtype=rtDeletedRecord then
          if st.CanSee(thisRec.rec.Wt,True) then
          begin //zapped (& committed the zap) before/when we started, so abort
            {$IFDEF DEBUGINDEXDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Next record is invisible because it was deleted (%d) before/when we started %d, skipping',[thisrec.rec.Wt.tranId,tr.Rt.TranId]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            result:=noData;
            exit; //reject
          end;
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' Failed reading %d:%d',[rid.pid,rid.sid]),vDebugError);
      {$ENDIF}
      exit; //reject/abort
    end;

    {if Wt is too recent then prepare for another read loop}
    needOlderVersion:=st.CannotSee(thisRec.rec.Wt);
    if thisRec.rec.len=0 then needOlderVersion:=True; //skip forward RIDs //todo check ok test here?   //always???
    if needOlderVersion then
    begin
      {todo: maybe if thisRec.rec.Wt is in our uncommitted list as tsRolledBack
             (i.e. get reason-code back from CannotSee routine! - or use Before=>rolled-back)
             then we could/should take the opportunity to remove this record version from the history now
             - or at least pass its rid to a background sweeper, or add to sweeper's todo list...
       Note: we should have hooks to do this whenever we read record versions, e.g. delete/update routines
       The switch to clean-now or postpone should be on the transaction...
      }

      if thisRec.rec.prevRID.pid=InvalidPageId then //sanity check
      begin
        {We've reached the earliest version: it was created after our transaction - it is in our future, or wasn't committed when we started}
        //todo: note we cannot tell difference between this, and a too-early (crashed?) purge... either way there's not much we can read of any use
        {$IFDEF DEBUGINDEXDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next record is end of version chain (%d) but we (%d) will still process it',[thisrec.rec.Wt.tranId,tr.Rt.Tranid]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        inc(versionCount);          //count this one towards number of records used (we never contract chains)
        break; //out of version repeat loop
      end;
      rid:=thisRec.rec.prevRID; //loop again to read next version

      {move to next free page pointer}
      if thispage.next=nil then
      begin //no more in list, create an extra one
        newPage:=TPageList.create;
        {$IFDEF DEBUGDETAIL3}
        inc(debugPagelistCreate);
        {$ENDIF}
        thispage.next:=newPage;  //link
      end;
      thispage:=thispage.next; //move to next page slot
      {$IFDEF DEBUGDETAIL3}
      if thisPage.page<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Next page in chain is not nil when chaining version',[nil]),vAssertion); //=> not unpinned?
        {$ENDIF}
      end;
      {$ENDIF}

      {move to next free record}
      if thisrec.next=nil then
      begin //no more in list, create an extra one
        newRec:=TRecList.create;  
        newRec.rec:=TRec.create;     //create space for Trec (Note: this is *not* a whole block in size - dataptr points to data in pinned page) 
        {$IFDEF DEBUGDETAIL3}
        inc(debugRecCreate);
        {$ENDIF}
        thisrec.next:=newRec;  //link
      end;
      thisRec:=thisRec.next; //move to next rec slot
    end;

    inc(versionCount);          //number of records used (we never contract chains)
  until not needOlderVersion;

  {Loop through each record version, pointing our columns at the appropriate portion and adding any modified index values}
  thisRec:=fRecList; //first
  {$IFDEF DEBUGINDEXDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('%d:%d [Wt=%d](%d) %s',[fRID.pid,fRID.sid,thisRec.rec.Wt.tranId,thisRec.rec.len,copy(thisRec.rec.dataPtr^,0,thisRec.rec.len)]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  for i:=1 to versionCount do
  begin
    {$IFDEF DEBUGINDEXDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Version %d [Wt=%d](%d) prevRID=%d:%d %s',[i,thisRec.rec.Wt.tranId,thisRec.rec.len,thisRec.rec.prevrid.pid,thisRec.rec.prevrid.sid,copy(thisRec.rec.dataPtr^,0,thisRec.rec.len)]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    {Loop through each column slot in the record header}
    //todo+ maybe continue here if i<>1 and tr.CannotSee(thisRec.rec.Wt)? i.e. skip rolled-back deltas along the way: speed
    if thisRec.rec.len<>0 then
    begin
      move(thisRec.rec.dataPtr^[0],rColCount,SizeOf(rColCount));
      needToUpdateIndex:=False;
      //todo assert rcolCount<colCount!? => corrupt
      if rColCount>0 then //Note: could be 0 columns if delta'd for deletion (etc.?)
        for j:=0 to rColCount-1 do
        begin
          {If this column id existed when our transaction started, then we need it}
          move(thisRec.rec.dataPtr^[sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))],cid,sizeof(cid));
          //todo only bother to store if cid is to be projected/used later?
          {Find this column id in our tuple column definition}
          //todo Note: start k:=0 outside 'for j' loop - it *always* increments! ?check? =faster
          //todo hash column id onto ColDefs?
          //todo don't bother looking if cid>our-highest-cid
          k:=0;
          while k<fColCount do
          begin
            if fColDef[k].id=cid then
              break;
            inc(k);
          end;
          if k<fColCount then
          begin //we found this col id in the current tuple definition
            {$IFDEF DEBUGINDEXDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Matched column id %d in version %d at col-ref %d',[cid,i,k]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            {Store the pointer to this record version and column offset slot
             (slot rather than data offset because we need to access the
             'next' slot later to calculate the data length, and makes multi-access
             easier?)
             Remember, the record versions are in pinned pages
             }
            fColData[k].dataPtr:=thisRec.rec.dataPtr;
            fColData[k].offset:=sizeof(ColRef)+(j*(sizeof(cid)+sizeof(colOffset)))+sizeof(cid);
            fColData[k].blobAllocated:=false; //
            {Get column length}
            //todo speed: use j-1 to get last offset and then only need 1 move below to get length
            //     i.e. we currently: move(1), move(2)   move(2), move(3)    move(3), move(4) ..etc...
            //          surely could: move(1), move(2)   move(3)             move(4)          ..etc...
            move(fColData[k].dataPtr^[fColData[k].offset],coff,sizeof(coff)); //get data offset for this column
            move(fColData[k].dataPtr^[fColData[k].offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
            fColData[k].len:=nextCoff-coff; //from now on, we will reference & update this value

            {Check if this column delta requires a new index entry}
            //todo?: if not rolled-back delta then
            for j2:=1 to fColCount do
              if (iFile as TIndexFile).colMap[j2].cid=cid then
              begin
                needToUpdateIndex:=True;
                break;
              end;
          end
          else
          begin
            //else this col id must be a new one, added since our transaction started (actually, opened this relation) - we ignore it
            // {$IFDEF DEBUGINDEXDETAIL}  //todo re-hide after testing with schema updates etc.
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Not matched column id %d in version %d (this is ok if looking for duplicate keys)',[cid,i]),vDebugWarning); 
            {$ENDIF}
            //this is not a problem during relation.isUnique, since we read just the key columns and ignore any others
            // {$ENDIF}
          end;
        end; {for each column slot}

      {Add the tuple in its current state to the index - it might be useful to someone
       Note: this includes 'earliest'...'latest' tuple versions if their index columns differ
       Note: we always point to this delta's header RID that we stored before we read the versions}
      {Note:
         we need to index rolled-back records (version=first) because some columns may actually be valid
                          e.g. [a,b,c,d]commit; [c->z](rollback) => [a,b,z,d](rolledback)->[c](committed)
                                                                     ^ ^   ^ = columns needing index entries
                          but ok to skip rolled-back deltas...
      }
      if (i>1) and (thisRec.rec.Wt.tranId>=Ttransaction(st.owner).db.tranCommittedOffset) and Ttransaction(st.owner).db.TransactionIsRolledBack(thisRec.rec.Wt) then
      begin //we can safely ignore any rolled-back delta records: there's no need for them in the index (even though we do need them to rebuild records: especially/currently if header=rolled-back!) & we can't rollback a rollback!
            //Note: this doesn't catch all rollbacks... just fresh ones: unlikely to have fresh deltas?
            //todo: improve: really need canSee as max-tran/read-uncommitted to skip all (delta) rollbacks
        {$IFDEF DEBUGINDEXDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%d:%d missed from index %s - has been rolled back',[fRID.pid,fRID.sid,(iFile as TIndexFile).name]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
      end
      else
        if needToUpdateIndex then
        begin
          if (iFile as TIndexFile).AddKeyPtr(st,self,fRID)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed inserting %d:%d into index %s',[fRID.pid,fRID.sid,(iFile as TIndexFile).name]),vDebugError); //todo user error?
            {$ENDIF}
            //todo: should we continue to return ok to caller... todo: not critical???? or is it??? I think it probably is!...so....
            result:=fail; //return fail for now, but continue to try and add rest of index entries anyway...
            //todo once caller's can handle +ve result: result:=result+1;
          end
          else
          begin
            {$IFDEF DEBUGINDEXDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('%d:%d inserted into index %s',[fRID.pid,fRID.sid,(iFile as TIndexFile).name]),vDebugMedium);
            {$ENDIF}
            {$ENDIF}
          end;
        end;

    end; //else 0 data stored here, must just be a forwarding RID
         //todo: maybe do same for deletions instead of rtDeletedRecord? - i.e. proper tombstone
    {Look at the next record version, if any}
    thisRec:=thisRec.next; ///note: bugfix 08/07/99 to allow more than 2 versions!  fRecList.next;
  end; {for each record version}
  {end result=colDefs[] = array of record pointers+slot-column-offsets+data-lengths which specify the record+column
   - each page involved is pinned
   ideally: 1 page involved + 1 record so all ColDefs[] have same recPtr + consecutive column-slot-offsets
   e.g. coldef[1].dataptr=1 coldef[1].offset=1 coldef[2].dataptr=1 coldef[2].offset=2 etc.
   worse: 1 page per column - unlikely to cause a problem? - what about length=nextCoff-coff? -we store lengths in memory, so should be easy to handle once we calculate it here.
   Worsens after each update until garbage collection after all committed transactions are swept away
  }

  result:=ok;
end; {readToIndex}


function TTuple.PrepareUpdateDiffRec:integer;
{Prepares the updated delta tuple for update into the relation
 RETURNS  : fUpdateRec.dataPtr completed
            +ve=ok, else fail

 Assumes:
   the update diff-columns have been cleared and been pointed at the old column data
}
const routine=':PrepareUpdateDiffRec';
var
  i:ColRef;
  size:colOffset;
  newCoff,coff:ColOffset;
  null:boolean;
  cid:TColId;
begin
  result:=Fail;

  {Add initial column count} //this is needed by record reading routines (delta's have variable number of columns)
  move(fDiffColCount,fUpdateRec.dataPtr^[0],sizeof(fDiffColCount));

  {Copy the data to the buffer
   Note: we have to do this column by column because there could be gaps}
  size:=sizeof(colRef)+((fDiffColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
  if fDiffColCount>0 then
    for i:=0 to fDiffColCount-1 do
    begin
      move(fDiffColData[i].dataPtr^[fDiffColData[i].offset],coff,sizeof(coff)); //get offset for this column
      move(fDiffColData[i].dataPtr^[fDiffColData[i].offset-sizeof(cid)],cid,sizeof(cid)); //get original id for this column
                                                                                          //Note: we had to move back just before offset (I think this is the only time we do this)
      //todo debugAssert nextCoff-coff=len
      if fDiffColData[i].len=0 then null:=true else null:=false;

      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('column %d offset=%d',[i,coff]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if not null and (size+fDiffColData[i].len>=MaxRecSize) then        //todo remove?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.clearUpdate''ed)',[size]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit;
      end;

      newCoff:=size;
      if not null then
      begin
        //move(fCol[i].dataPtr[coff],buf^[size],(nextCOff-coff)); //move data
        move(fDiffColData[i].dataPtr[coff],fUpdateRec.dataPtr^[newCoff],fDiffColData[i].len); //move data
        size:=size+fDiffColData[i].len;     //increase length
        {$IFDEF DEBUGCOLUMNDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('copied %d bytes for column %d (%s)',[fDiffColData[i].len,i,fDiffColData[i].dataPtr[coff]]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      {Set column specifier}
      move(cid,fUpdateRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))],sizeof(TcolId));
      move(newCoff,fUpdateRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
    end;
  //else (internal?) warning
  {Add final offset}
  move(size,fUpdateRec.dataPtr^[sizeof(ColRef)+(fDiffColCount*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  //todo final id?

  //todo ok setting fUpdateRec.len?
  fUpdateRec.len:=size;

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('final size=%d',[size]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {PrepareUpdateDiffRec}

function TTuple.PrepareUpdateNewRec:integer;
{Prepares the new updated record tuple for update into the relation
 RETURNS  : fUpdateRec.dataPtr completed
            +ve=ok, else fail

  //todo maybe merge this routine with the PrepareUpdateDiffRec one above?
  //todo maybe a quicker way than copying all the existing data from its original place

 Assumes:
   the updated columns have been re-pointed at the new column data buffer
}
const routine=':PrepareUpdateNewRec';
var
  i:ColRef;
  size:colOffset;
  newCoff,coff:ColOffset;
  null:boolean;
  cid:TColId; //needed, even though compiler gives warning (for sizeof)
begin
  result:=Fail;

  {Add initial column count} //this is needed by record reading routines (delta's have variable number of columns)
  move(fColCount,fUpdateRec.dataPtr^[0],sizeof(fColCount));

  {Copy the data to the buffer
   Note: we have to do this column by column because they could be pointing to (2) separate data areas}
  size:=sizeof(colRef)+((fColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      move(fColData[i].dataPtr^[fColData[i].offset],coff,sizeof(coff)); //get offset for this column
      //todo debugAssert nextCoff-coff=len
      if fColData[i].len=0 then null:=true else null:=false;

      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('column %d offset=%d',[i,coff]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if not null and (size+fColData[i].len>=MaxRecSize) then        //todo remove?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.clearUpdate''ed)',[size]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        exit;
      end;

      newCoff:=size;
      if not null then
      begin
        //move(fCol[i].dataPtr[coff],buf^[size],(nextCOff-coff)); //move data
        move(fColData[i].dataPtr[coff],fUpdateRec.dataPtr^[newCoff],fColData[i].len); //move data
        size:=size+fColData[i].len;     //increase length
        {$IFDEF DEBUGCOLUMNDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('copied %d bytes for column %d (%s)',[fColData[i].len,i,fColData[i].dataPtr[coff]]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      {Set column specifier}
      move(fColDef[i].Id,fUpdateRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))],sizeof(TcolId));
      move(newCoff,fUpdateRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
    end;
  //else (internal?) warning
  {Add final offset}
  move(size,fUpdateRec.dataPtr^[sizeof(ColRef)+(fColCount*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  //todo final id?

  //todo ok setting fUpdateRec.len?
  fUpdateRec.len:=size;

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('final size=%d',[size]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
end; {PrepareUpdateNewRec}


function TTuple.update(st:TStmt;rid:Trid):integer;
{Updates a specific tuple from the file
 This may delta the record.

 IN      : st              the statement
           rid             the record to update
 RETURN  : +ve=ok
           -2 = too late, already updated by a 'later' active tran
           else fail

 Assumes:

 Note:
   this routine treats the tuple owner as a THeapFile rather than the generic TFile
   this is to allow some specific header updates that don't really belong in Tfile

   The tuple's fRID is set by this routine for reference

 Side-effects:
   If the tuple's owner has indexes attached, their AddKeyPtr methods are called for any relevant changed data
    - see the Insert method's comments for more details

   Any modified blob columns are written first (hopefully they're small & will fit on the same page as this record)
   (also they are swizzled to point to their new disk rids)

 Note:
   we use Tr.Wt for timestamping
}
const
  routine=':Update';
  tooLate=-2;
var
  page:TPage;
  needOlderVersion:boolean;
  i,j:ColRef;
  cid:TColId;

  newRid:TRid;
  saveSlot:TSlot;
  indexPtr:TIndexListPtr;
  needToUpdateIndex:boolean;

  {for blob writing}
  coff, nextCoff:ColOffset;
  bv:Tblob;
  bvnull:boolean;
  blobRid:Trid;
  blobLen:cardinal;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {$IFDEF SAFETY}
  if fDiffColCountDone<>fDiffColCount then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('We only updated %d columns out of the %d defined',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
    //we can't continue, especially since the initial col-id's in the cleared new data rec are 0 (= reserved?)
  end;
  {$ENDIF}

(*todo we have to re-read the tuple here because:
   a) it gives us the Wt, prevRID, rType etc that I don't think we get from having
      shallow-copied it from the IterUpdate.leftChild
      - fix this?
   b) we check that no one else has updated/deleted etc. since we first read it
      (although it should have been pinned & this might stop them?
       - maybe we should have properly locked the RID before we shallow copied in IterUpdate?
         - i.e. latch the page as well as pinning it
         - although if we latch it here (or better granularity=in subroutines used here),
           maybe that's more concurrent because the original source may have done the read
           a 'long' time ago? difficult cos no sort/group allowed?...)
   c) still developing/debugging update routines (many bits)
      so this is a quick debug fix to check the idea works...

  {See notes in Delete routine about not repeating the pin of an already read rid ! todo

  todo - we have already pinned & read this record,
  just check that all col pointers are pointing at the 1st record, i.e. latest version only
  }
  thispage:=fPageList;       //pointer to first page //todo don't use these - they simulate a read-pin & free fails...?maybe
  thisrec:=fRecList;         //pointer to first rec
*)
//(*
  unPin(st); //todo debug only- I think without this, the previous read's pinned pages are screwed

  {move to & pin the appropriate page - stores the page reference in thisPage}
  if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,page)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  try
    {We latch the header page to ensure our checks + versioning are undisturbed}
    {Note: we could try to latch another page below (addRecord) which could cause deadlock
           so the latch routine will now time-out to avoid this: so one of the routines would fail!
           Note: result=fail here, so latch fail=>return fail
    }
    if page.latch(st)=ok then
    try
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Pinned and latched record page %d',[rid.pid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {read the record & store its pointer}
      if (owner as TRelation).dbFile.ReadRecord(st,page,rid.sid,fRecList.rec)=ok then
      begin
        //todo ifdef safety? speed
        if not(fRecList.rec.rtype in [rtRecord,rtDeletedRecord]) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('First record is not a record header %d:%d, aborting',[rid.pid,rid.sid]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;
        //Note: we assume updates after deleted records cannot happen
        //      because we would never see them/be allowed to update them below
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' Failed reading %d:%d',[rid.pid,rid.sid]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end;
  //*)

      if not st.CanUpdate(fRecList.rec.Wt) then
      begin
        {We cannot update this tuple, since a later or active earlier transaction than ours has already updated it}
        //todo+: we could wait here to see if the conflicting version will be rolled back?
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Cannot update this tuple - another (later or active earlier) transaction %d:%d has already updated it (we are %d:%d)',[fRecList.rec.Wt.tranId,fRecList.rec.Wt.stmtId,st.Wt.tranId,st.Wt.stmtId]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        //todo gently rollback caller.... not just abort!
        result:=tooLate;
        exit; //abort
      end;

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('%d:%d [Wt=%d](%d)%s',[rid.pid,rid.sid,fRecList.rec.Wt.tranId,fRecList.rec.len,copy(fRecList.rec.dataPtr^,0,fRecList.rec.len)]),vDebugError);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      //todo check that this Wt is the same as our original
      // - otherwise our colData may have been scuppered!...

      {Save the current header details}
      saveSlot.rType:=fRecList.rec.rType; //todo: assert = rtRecord (or even rtDeletedRecord)
      saveSlot.Wt:=fRecList.rec.Wt; //todo no need - check!
      saveSlot.PrevRID:=fRecList.rec.prevRID; //todo no need - check!

      if not st.IsMe(fRecList.rec.Wt) then //we can see it (because we just ruled out CannotSee) but it's not us, so version
      begin //we need to create a delta to indicate who updated this tuple
        {Insert prepared update delta}
        PrepareUpdateDiffRec;
        fUpdateRec.Wt:=saveSlot.Wt; //set Wt to this latest record
        fUpdateRec.rType:=rtDelta;
        fUpdateRec.prevRID.pid:=saveSlot.prevRID.pid;
        fUpdateRec.prevRID.sid:=saveSlot.prevRID.sid;
        {$IFDEF SAFETY} //todo remove since we crash if this isn't trapped
        {Assert owner is valid}
        if not assigned(owner) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'Tuple is not associated with a relation',vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end;
        {$ENDIF}

        {Now, add the record}
        result:=(owner as TRelation).dbFile.AddRecord(st,fUpdateRec,newRid);

        if result=ok then
  //        {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%d:%d inserted delta [Wt=%d:%d](%d)',[newrid.pid,newrid.sid,fUpdateRec.Wt.tranId,fUpdateRec.Wt.stmtId,fUpdateRec.len]),vDebugMedium)
          {$ENDIF}
  //        {$ENDIF}
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed inserting delta [Wt=%d:%d](%d)',[fUpdateRec.Wt.tranId,fUpdateRec.Wt.stmtId,fUpdateRec.len]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort!
        end;


        {Now update the existing record with the new data}
        PrepareUpdateNewRec;

        {Now update the latest header with
          Wt = the current tr.Wt
          prevRID pointing to the new delta}

        //todo maybe move lines here that are duplicated in else below, to after if...?
        fUpdateRec.rType:=rtRecord; 
        fUpdateRec.Wt:=st.Wt;
        fUpdateRec.prevRID:=newRid; //point to new delta added above
      end
      else //this record is ours alone, so we can update it by overwriting it
      begin
        PrepareUpdateNewRec; //todo: this is wasteful if we haven't changed anything (or even changed not much?)
        fUpdateRec.rType:=rtRecord; 
        fUpdateRec.Wt:=st.Wt;
        fUpdateRec.prevRID.pid:=saveSlot.prevRID.pid;
        fUpdateRec.prevRID.sid:=saveSlot.prevRID.sid;
      end;

      {Now, update any blob data}
      if fColCount>0 then //todo: again, this assertion should not be needed or not silent
        //todo check no col offsets still=0? or if so set them =to next offset
        for i:=0 to fColCount-1 do
        begin
          if fColDef[i].dataType in [ctBlob,ctClob] then
          begin
            if fColData[i].dataPtr<>nil then //todo no need?
            begin
              if {(fNewDataRec<>nil) and} (fColData[i].dataPtr=fNewDataRec.dataPtr) then
              begin //this is new blob data
                move(fUpdateRec.dataptr^[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],coff,sizeof(coff));
                move(fUpdateRec.dataptr^[sizeof(ColRef)+((i+1)*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('  updating blob column %d offset=%d',[i,coff]),vDebugLow);
                {$ENDIF}
                {$ENDIF}

                {Find the old blob value (if any)}
                result:=fail;
                //Note: following copied from PrepareUpdateDiffRec
                //size:=sizeof(colRef)+((tR.fDiffColCount+1)*(sizeof(TColId)+sizeof(coff))); //leave room for column specifiers
                if fDiffColCount>0 then //todo no need here?
                begin
                  for j:=0 to fDiffColCount-1 do //todo any way to get the appropriate one directly? speed
                  begin
                    move(fDiffColData[j].dataPtr^[fDiffColData[j].offset-sizeof(cid)],cid,sizeof(cid)); //get original id for this column
                                                                                                        //Note: we had to move back just before offset (I think this is the only time we do this)

                    if fColDef[i].id=cid then
                    begin //this is our source column's old data
                      result:=j;

                      {If we're not versioning (i.e. updating our own record 'in-place') then we need to delete the existing blob from disk}
                      if st.IsMe(fRecList.rec.Wt) then //we can see it (because we just ruled out CannotSee) and it's us, so not versioning
                      begin
                        {$IFDEF DEBUGDETAIL}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('  deleting blob column %d offset=%d',[i,coff]),vDebugLow);
                        {$ENDIF}
                        {$ENDIF}

                        result:=GetOldBlob(j,bv,bvnull);
                        result:=deleteBlobData(st,bv);
                      end;
                      //else we're versioning this record so we leave the existing blob on disk (garbage collector will remove when possible)

                      //todo just store difference between old & new blobs to save space...

                      {Now add the new blob data}
                      //todo debugAssert fCol[i].len = nextcoff-coff
                      if nextCoff-coff<>0 then
                      begin //not null
                        {$IFDEF DEBUGDETAIL}
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('  inserting blob column %d offset=%d',[i,coff]),vDebugLow);
                        {$ENDIF}
                        {$ENDIF}

                        getBlob(i,bv,bvnull);
                        //todo suggest to insertBlobData that we don't use rid if fUpdateRec would then need a forwarding rid!
                        //     - especially important since blob segments are written in reverse, i.e. smallest piece first
                        //     (although there'd still be a chance that some other thread would steal our space...) 
                        if insertBlobData(st,bv,blobRid)<>ok then
                        begin
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('failed inserting blob column %d, aborting update',[i]),vDebugLow);
                          {$ENDIF}
                          //todo delete any blobs just inserted otherwise they will be orphaned now
                          exit; //abort
                        end;
                        {Now update this column's blob reference to point to our new disk rid}
                        //but first we must release the in-memory blob now it's on disk! (code taken from Ttuple.clear)
                        {$IFDEF DEBUG_LOG}
                        if not fColData[i].blobAllocated then
                          log.add(who,where+routine,format('Blob just written has no allocation flag',[nil]),vAssertion);
                        {$ENDIF}
                        blobLen:=bv.len; //remember, since freeBlobData will zeroise it //obviously len remains unchanged (unless in future we store differently on disk somehow?)
                        begin freeBlobData(bv); fColData[i].blobAllocated:=false; {fColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
                        bv.rid:=blobRid; //obviously len remains unchanged (unless in future we store differently on disk somehow?)
                        bv.len:=blobLen;
                        move(bv,fUpdateRec.dataptr^[coff],sizeof(bv)); //overwrite in-place (take care!)
                      end;

                      break; //ok, no more matches expected
                    end;
                  end;
                end;
                {$IFDEF DEBUG_LOG}
                //todo ok, must not be updating this column (or failed updating): continue
                if result<ok then
                  log.add(st.who,where+routine,format('Blob column not updated (id=%d)',[fColDef[i].id]),vAssertion);
                {$ENDIF}

              end;
            end;
          end;
        end;
      //else todo: warning

      {Now update the existing record in place with its new data and slot header details
       (note: may never have used new data buffer)
      }

      //todo also update the header in this routine, not separately below!!
      // - i.e. Wt and prevRID...  maybe over-use True flag as 'versioned' or 'not been versioned'
  {$IFDEF DEBUG_LOG}
  log.add(st.who,where+routine,format('Pre-update prevRID=%d:%d',[fUpdateRec.prevRID.pid,fUpdateRec.prevRID.sid]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
      result:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,fUpdateRec,rid,False);
      {Now, update the record header}
      result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeader(st,fUpdateRec,rid);
      //todo check results!

      {We store the RID of the updated record now for any future use (e.g index keyPtr update)}
      fRID:=rid;
    finally
      //todo check ok to unlatch before indexes are updated? I think so...
      page.unlatch(st);
    end {try}
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed latching',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;

    {Now add any index entries, if any key columns have changed}
    //Note: this logic is taken from the insert routine + colId logic from PrepareUpdateDiffRec
    indexPtr:=(owner as TRelation).indexList;
    while indexPtr<>nil do
    begin
      needToUpdateIndex:=False;
      if fDiffColCount>0 then
        for i:=0 to fDiffColCount-1 do
        begin
          move(fDiffColData[i].dataPtr^[fDiffColData[i].offset-sizeof(cid)],cid,sizeof(cid)); //get original id for this column
                                                                                              //Note: we had to move back just before offset (I think this is the only time we do this)
          for j:=1 to colCount do
            if indexPtr.index.colMap[j].cid=cid then
            begin
              needToUpdateIndex:=True;
              break;
            end;

          if needToUpdateIndex then break;
        end;

      if needToUpdateIndex then
      begin
        if indexPtr.index.AddKeyPtr(st,self,rid)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed inserting %d:%d into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugError); //todo user error?
          {$ELSE}
          ;
          {$ENDIF}
          //todo: should we continue to return ok to caller... todo: not critical???? or is it??? I think it probably is!...so....
          result:=fail; //return fail for now, but continue to try and add rest of index entries anyway...
          //todo once caller's can handle +ve result: result:=result+1;
        end
        else
        begin
          {$IFDEF DEBUGINDEXDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%d:%d inserted into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      end;

      indexPtr:=indexPtr.next;
      //else no key part changed, so keep existing index entry (ok because rid is fixed)
    end;

    result:=ok;
  finally
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rid.pid)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed unpinning',[rid.pid]),vError);
      {$ENDIF}
      result:=fail;
    end;
  end; {try}
//*)
end; {update}


function TTuple.updateOverwrite(st:TStmt;rid:Trid):integer;
{Updates a specific tuple from the file

 //todo replace this with the generic update()

 IN      : st              the statement
           rid             the record to update
 RETURN  : +ve=ok else fail

 Assumes:
   the rec has been cleared, filled and preInserted
   and the rec data is in fRecList as if we were inserting a new record
   the record's tran-id is correct

   currently, can only update if it is this transaction's record! i.e. overwrite
   Note: it doesn't care if this is not the same stmtId though - so up to caller to
         ensure we are allowed to update in this position
         (needed since if caller is updating sysTran in place and Rt.stmtid is behind
          latest Wt, then because isMe used Wt would fail assertion)

 Note:
   this routine treats the tuple owner as a THeapFile rather than the generic TFile
   this is to allow some specific record updates that don't really belong in Tfile

   The tuple's fRID is set by this routine for reference

   No Blob data needs updating
}
const routine=':UpdateOverwrite';
var
  Page:TPage;
  thisrec:TRecList;

  i,j:ColRef;
  cid:TColId;
  indexPtr:TIndexListPtr;
  needToUpdateIndex:boolean;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  unPin(st); //todo debug only- I think without this, the previous read's pinned pages are screwed

  thisrec:=fRecList;         //first rec //todo use fRecList directly?

  if (st.Rt.tranId=thisrec.rec.Wt.tranId) then //Note: so we're only concerned that this was written by this tran - i.e. up to caller to ensure we can in-place overwrite here...
  begin //this is our record, so we can update it by overwriting it
        //todo: not strictly true, since stmtId could be anything (even rolled-back!) but assume caller knows what they're doing...

    {move to & pin the appropriate page - stores the page reference in thisPage}
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Pinned record page %d',[rid.pid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {Now, update the record}
      result:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,thisRec.rec,rid,True);

      {We store the RID of the updated record now for any future use (e.g index keyPtr update)}
      fRID:=rid;

      {Now add any index entries, if any key columns have changed}
      //Note: this logic is taken from the insert routine + colId logic from PrepareUpdateDiffRec
      indexPtr:=(owner as TRelation).indexList;
      while indexPtr<>nil do
      begin
        needToUpdateIndex:=False;
        if fDiffColCount>0 then
          for i:=0 to fDiffColCount-1 do
          begin
            move(fDiffColData[i].dataPtr^[fDiffColData[i].offset-sizeof(cid)],cid,sizeof(cid)); //get original id for this column
                                                                                                //Note: we had to move back just before offset (I think this is the only time we do this)
            for j:=1 to colCount do
              if indexPtr.index.colMap[j].cid=cid then
              begin
                needToUpdateIndex:=True;
                break;
              end;

            if needToUpdateIndex then break;
          end;

        if needToUpdateIndex then
        begin
          if indexPtr.index.AddKeyPtr(st,self,rid)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed inserting %d:%d into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugError); //todo user error?
            {$ELSE}
            ;
            {$ENDIF}
            //todo: should we continue to return ok to caller... todo: not critical???? or is it??? I think it probably is!...so....
            result:=fail; //return fail for now, but continue to try and add rest of index entries anyway...
            //todo once caller's can handle +ve result: result:=result+1;
          end
          else
          begin
            {$IFDEF DEBUGINDEXDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('%d:%d inserted into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugMedium);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end;
        end;
        
        indexPtr:=indexPtr.next;
        //else no key part changed, so keep existing index entry (ok because rid is fixed)
      end;
    finally
      if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rid.pid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' %d failed unpinning',[rid.pid]),vError);
        {$ENDIF}
        result:=fail;
      end;
    end; {try}
  end
  else
  begin //this is another kind of update - can we handle it here?
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Attempt to update record with tid=%d:%d from transaction %d:%d - TODO, ignoring...',[thisrec.rec.Wt.tranId,thisrec.rec.Wt.stmtId,st.Wt.tranId,st.Wt.stmtId]),vAssertion{todo DebugError?}); //todo assertion?
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end;
end; {updateOverwrite}

function TTuple.updateOverwriteNoVersioning(st:TStmt;rid:Trid):integer;
{Updates a specific tuple from the file and ignore all versioning rules
 Note: copied from updateOverwrite
 Warning: only use for sysGenerator in-place updates
          & so we don't update any indexes

 //todo replace this with the generic update()

 IN      : st              the statement
           rid             the record to update
 RETURN  : +ve=ok else fail

 Assumes:
   the rec has been cleared, filled and preInserted
   and the rec data is in fRecList as if we were inserting a new record
   the record's tran-id is correct (or unimportant)

   currently, we update and always overwrite - dangerous!

 Note:
   this routine treats the tuple owner as a THeapFile rather than the generic TFile
   this is to allow some specific record updates that don't really belong in Tfile

   The tuple's fRID is set by this routine for reference

   No Blob data needs updating
}
const routine=':UpdateOverwriteNoVersioning';
var
  page:TPage;
  thisrec:TRecList;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  unPin(st); //todo debug only- I think without this, the previous read's pinned pages are screwed

  thisrec:=fRecList;         //first rec //todo use fRecList directly?

    {move to & pin the appropriate page - stores the page reference in thisPage}
    if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,rid.pid,page)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(' %d failed pinning',[rid.pid]),vError);
      {$ELSE}
      ;
      {$ENDIF}
      exit; //abort
    end;
    try
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Pinned record page %d',[rid.pid]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}

      {Now, update the record}
      result:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,thisRec.rec,rid,{todo should be false?}False{made false for user generators 12/07/02: True});
                                                                                        //^ but sysGenerator inc always keeps original Wt of 0, so ok to leave True (only for system ones!)
      {We store the RID of the updated record now for any future use (e.g index keyPtr update)}
      fRID:=rid;

      //Note: we don't update any indexes for such an update //todo check ok/assert in indexes are open
    finally
      if (Ttransaction(st.owner).db.owner as TDBServer).buffer.unpinPage(st,rid.pid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format(' %d failed unpinning',[rid.pid]),vError);
        {$ENDIF}
        result:=fail;
      end;
    end; {try}
end; {updateOverwriteNoVersioning}

function TTuple.ColIsNull(col:colRef;var null:boolean):integer;
{Checks whether the column is null
 IN       : col           - the col subscript (not the id)
 OUT      : null          - true if null, else false
 RETURNS  : +ve=ok, else fail (& so ignore result)

 Assumes:
   the rec has been read

 Note: currently this test is duplicated in the GetX routines
 - keep in sync!
}
const routine=':ColIsNull';
begin
  result:=ok;
  //todo check col id<>0 =reserved

  //todo - remove safety checks from here - done elsewhere
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  //todo DebugAssert nextCoff-coff=len
  //todo if nextCoff=-1 then warning!
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
  end
  else
  begin
    null:=false;
    {$IFDEF SAFETY}
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError); //critical
      {$ELSE}
      ;
      {$ENDIF}
      result:=fail;
    end;
    {$ENDIF}
  end;
end; {ColIsNull}

function TTuple.GetString(col:colRef;var s:string;var null:boolean):integer;
{Gets the last read value for a string column
 IN       : col           - the col subscript (not the id)
 OUT      : s             - the string value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   fixed length CHAR()s will be padded to their full size
   //todo: is this most effecient way? maybe just modify compare/output routines?

   we store '' as #0 to distinguish it from null (len=0) (getString will reverse this)

 Assumes:
   the rec has been read
}
const routine=':GetString';
var
  coff:ColOffset;
  sp:PtrRecData;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stString]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a string (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    s:=nullShow; //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position} //todo after len: we can now move this after the null check - for all Gets....
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextCoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo throughout: call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    s:=nullShow; //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?)
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove(%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      sp:=@fColData[col].dataPtr^[coff];
      s:=copy(sp^,0,fColData[col].len);
      if s=nullterm then s:=''; //restore #0 to '' (was stored this way to distinguish from null)
      {Now pad the string if it should be a fixed size}
      if fColDef[col].dataType in [ctChar,ctBit] then //user-specified fixed size //todo also for numeric etc.
        if fColData[col].len<>fColDef[col].width then
        begin
          s:=s+stringOfChar(PadChar,fColDef[col].width-fColData[col].len); //todo: quicker way!
          {$IFDEF DEBUGCOLUMNDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d padded from %d to %d',[col,fColData[col].len,fColDef[col].width]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned "%s"',[s]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetString}

function TTuple.GetInteger(col:colRef;var i:integer;var null:boolean):integer;
{Gets the last read value for an integer column
 IN       : col           - the col subscript (not the id)
 OUT      : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetInteger';
var
  coff:ColOffset;
  //don't re-use i!
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not an integer
   or
      coerce the type into an integer
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch  {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stInteger,stSmallInt]) {todo: also/remove smallInt?} then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not an integer (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    i:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextCoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    i:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?) 
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],i,SizeOf(i));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned %d',[i]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetInteger}

function TTuple.GetBigInt(col:colRef;var i:int64;var null:boolean):integer;
{Gets the last read value for a big integer column
 IN       : col           - the col subscript (not the id)
 OUT      : i             - the big integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetBigInt';
var
  coff:ColOffset;
  //don't re-use i!
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a big integer
   or
      coerce the type into a big integer
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch  {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stBigInt]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a big integer (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    i:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextCoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    i:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?)
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],i,SizeOf(i));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned %d',[i]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetBigInt}

function TTuple.GetDouble(col:colRef;var d:double;var null:boolean):integer;
{Gets the last read value for a double column
 IN       : col           - the col subscript (not the id)
 OUT      : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetDouble';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then       
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a double
   or
      coerce the type into a double
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch  {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stDouble]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a double (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?) 
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],d,SizeOf(d));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned %g',[d]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetDouble}

//todo remove function TTuple.GetComp(col:colRef;var c:comp;var null:boolean):integer;
function TTuple.GetComp(col:colRef;var d:double;var null:boolean):integer;
{Gets the last read value for a comp column

 Note: this is an attempt to handle and store floating point numbers with
       accuracy. We can't easily handle the assumed-point integer arithmetic (yet),
       so we return a double after adjusting it & reading it as a comp - does this help or sometimes confuse?

 IN       : col           - the col subscript (not the id)
 OUT      : d             - the double (was comp) value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetComp';
var
  coff:ColOffset;
  c:comp;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a double
   or
      coerce the type into a double
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stComp]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a comp (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?) 
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],c,SizeOf(c));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned %g',[c]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Adjust the scale}
      d:=c/power(10,fColDef[col].scale); //i.e. shift scale decimal places to the right
      result:=ok;
    end;
  end;
end; {GetComp}

function TTuple.GetNumber(col:colRef;var d:double;var null:boolean):integer;
{Gets the last read value for a comp, double or an integer column as a double
 If the column is an integer, it will be automatically coerced into returning a double
 If the column is a comp, it will be automatically coerced into returning a double //todo fix by returning a comp?

 IN       : col           - the col subscript (not the id)
 OUT      : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   this routine was added for the numeric expression evaluation, e.g. (x + y)
   It is inteded that this imprecise routine be replaced by code in the
   expression routine that handles mixed numeric types.

 Assumes:
   the rec has been read
}
const routine=':GetNumber';
var
  coerceFromInt:integer;
  coerceFromBigInt:int64;
  coerceFromComp:comp;
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColdata[col].len=0 then
  begin
    {null}
    null:=true;
    d:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?) 
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      case DataTypeDef[fColDef[col].datatype] of
      stDouble:
        begin
          move(fColData[col].dataPtr^[coff],d,SizeOf(d));
        end;
        //this is not a double, so we coerce it
      stInteger,stSmallInt:
        begin //we can coerce an integer into a double
          move(fColData[col].dataPtr^[coff],coerceFromInt,SizeOf(coerceFromInt));
          d:=coerceFromInt; //we use the compiler's coercion
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('coerced integer (type %d) into double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      stBigInt:
        begin //we can try to coerce a big integer into a double
          move(fColData[col].dataPtr^[coff],coerceFromBigInt,SizeOf(coerceFromBigInt));
          d:=coerceFromBigInt; //we use the compiler's coercion
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('coerced big integer (type %d) into double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
      stComp:
        begin //we can coerce a comp into a double
          move(fColData[col].dataPtr^[coff],coerceFromComp,SizeOf(coerceFromComp));
          d:=coerceFromComp; //we use the compiler's coercion
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('coerced comp (type %d) into double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is not a number (%d), returning 0',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
        {$ELSE}
        ;
        {$ENDIF}
        d:=0;
      end; {case}
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned %g',[d]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetNumber}

function TTuple.GetDate(col:colRef;var d:TsqlDate;var null:boolean):integer;
{Gets the last read value for a date column

 IN       : col           - the col subscript (not the id)
 OUT      : d             - the date value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetDate';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a date
   or
      coerce the type into a date
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stDate]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a date (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    //todo use DATE_ZERO
    d.year:=-1;{=null!} //todo remove - save time - only when safe!
    d.month:=-1;{=null!} //todo remove - save time - only when safe!
    d.day:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    //todo use DATE_ZERO
    d.year:=-1;{=null!} //todo remove - save time - only when safe!
    d.month:=-1;{=null!} //todo remove - save time - only when safe!
    d.day:=-1;{=null!} //todo remove - save time - only when safe!
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?)
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],d,SizeOf(d));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned (%d %d %d)',[d.year,d.month,d.day]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetDate}

function TTuple.GetTime(col:colRef;var t:TsqlTime;var null:boolean):integer;
{Gets the last read value for a time column

 IN       : col           - the col subscript (not the id)
 OUT      : d             - the time value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetTime';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a time
   or
      coerce the type into a time
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stTime]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a time (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    //todo use DATE_ZERO
    t.hour:=-1;{=null!} //todo remove - save time - only when safe!
    t.minute:=-1;{=null!} //todo remove - save time - only when safe!
    t.second:=-1;{=null!} //todo remove - save time - only when safe!
    t.scale:=0;
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    //todo use DATE_ZERO
    t.hour:=-1;{=null!} //todo remove - save time - only when safe!
    t.minute:=-1;{=null!} //todo remove - save time - only when safe!
    t.second:=-1;{=null!} //todo remove - save time - only when safe!
    t.scale:=0;
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?)
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],t,SizeOf(t));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned (%d %d %d)',[t.hour,t.minute,t.second]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetTime}

function TTuple.GetTimestamp(col:colRef;var ts:TsqlTimestamp;var null:boolean):integer;
{Gets the last read value for a timestamp column

 IN       : col           - the col subscript (not the id)
 OUT      : d             - the timestamp value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetTimestamp';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a timestamp
   or
      coerce the type into a timestamp
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stTimestamp]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a timestamp (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    //todo use DATE_ZERO
    ts.date.year:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.month:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.day:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.hour:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.minute:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.second:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.scale:=0;
    (*12/01/02 time no longer has timezone...
    ts.time.timezone.sign:=0; {=null!} //todo remove - save time - only when safe!
    ts.time.timezone.hour:=0; {=null!} //todo remove - save time - only when safe!
    ts.time.timezone.minute:=0; {=null!} //todo remove - save time - only when safe!
    *)
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    //todo use DATE_ZERO
    ts.date.year:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.month:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.day:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.hour:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.minute:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.second:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.scale:=0;
    //todo: what about result:=ok? - why wasn't this omission discovered until 21/04/00 in code?
    result:=ok; //todo: 14/05/00 why wasn't this fixed when above comment was put in????! needed or CompareLike aborts (etc.!?)
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],ts,SizeOf(ts));
      {$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned (%d %d %d : %d %d %d)',[ts.date.year,ts.date.month,ts.date.day,ts.time.hour,ts.time.minute,ts.time.second]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {$IFDEF DEBUGDATETIME}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Getting timestamp: %d %d %d %d %d %d %d %d %d',[ts.date.year,ts.date.month,ts.date.day,ts.time.hour,ts.time.minute,ts.time.second,ts.time.timezone.sign,ts.time.timezone.hour,ts.time.timezone.minute]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    end;
  end;
end; {GetTimestamp}

function TTuple.GetBlob(col:colRef;var b:Tblob;var null:boolean):integer;
{Gets the last read reference for a blob column

 IN       : col           - the col subscript (not the id)
 OUT      : b             - the blob reference
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read
}
const routine=':GetBlob';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a blob
   or
      coerce the type into a blob
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stBlob]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a blob (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    //todo use InvalidRid
    b.rid.pid:=InvalidPageId;
    b.rid.sid:=InvalidSlotId;
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fColData[col].len=0 then
  begin
    {null}
    null:=true;
    //todo use InvalidRid
    b.rid.pid:=InvalidPageId;
    b.rid.sid:=InvalidSlotId;
    result:=ok;
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fColData[col].dataPtr^[coff],b,SizeOf(b));
      //{$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned (%d %d)',[b.rid.pid, b.rid.sid]),vDebugLow);
      {$ENDIF}
      //{$ENDIF}
      result:=ok;
    end;
  end;
end; {GetBlob}

function TTuple.GetOldBlob(col:colRef;var b:Tblob;var null:boolean):integer;
{Gets the pre-update reference for a blob column

 IN       : col           - the DiffCol subscript (not the id)
 OUT      : b             - the blob reference
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Assumes:
   the rec has been read & the column updated

 //todo pass col id & return -2 if column not updated (i.e. put diff-finding logic here)
}
const routine=':GetOldBlob';
var
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fDiffColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple update size %d',[col,fDiffColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {TODO We can either:
      error if the col type is not a blob
   or
      coerce the type into a blob
   --same for GetString!
  }
  //todo remove ifdef: e.g. eval could call for date=user type mismatch   {$IFDEF SAFETY}
  if not(DataTypeDef[fColDef[col].datatype] in [stBlob]) then //todo = is faster than in ?
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a blob (%d)',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fDiffColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has diffdataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    //todo use InvalidRid
    b.rid.pid:=InvalidPageId;
    b.rid.sid:=InvalidSlotId;
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position}
  move(fDiffColData[col].dataPtr^[fDiffColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo debugAssert nextcoff-coff=len
  //todo if nextCoff=-1 then warning!
  //todo call ColIsNull instead of direct check
  if fDiffColData[col].len=0 then
  begin
    {null}
    null:=true;
    //todo use InvalidRid
    b.rid.pid:=InvalidPageId;
    b.rid.sid:=InvalidSlotId;
    result:=ok;
  end
  else
  begin
    null:=false;
    {check max len} //todo remove/enhance?
    if (fDiffColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove (%d..%d)'},[col,fDiffColData[col].len]),vDebugError) //critical
      {$ENDIF}
    else
    begin
      move(fDiffColData[col].dataPtr^[coff],b,SizeOf(b));
      //{$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('returned (%d %d)',[b.rid.pid, b.rid.sid]),vDebugLow);
      {$ENDIF}
      //{$ENDIF}
      result:=ok;
    end;
  end;
end; {GetOldBlob}

function TTuple.GetDataPointer(col:colRef;var p:pointer;var len:colOffset;var null:boolean):integer;
{Gets the last read value for any column type as a pointer to its raw data
 This is a dangerous handle to the data (it has no format, i.e. no Pascal type) so it should only
 be used for reading only - don't write to the column data through this pointer.
 (there should be no problems providing you don't write more than the length, but safer
  to use Set routines since they might need to do other things)
 This routine has been written for passing raw result data back to client via CLI (ODBC)
 It is also now used for the initial hash index hash function...

 IN       : col           - the col subscript (not the id)
 OUT      : p             - the pointer to the data
          : len           - the currently reported length of the data
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail (=>don't use returned pointer!)

 Note:
   fixed length CHAR()s are not padded to their full size - use GetString instead

 todo:
   there is a case for passing back a reduced len if the column is a string and has trailing spaces (for hash at least)

 Assumes:
   the rec has been read
}
const routine=':GetDataPointer';
var
  coff:ColOffset;
  sp:PtrRecData;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  {$IFDEF NILTONULL}
  //todo remove: should be no need
  if fColData[col].dataPtr=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d has dataptr=nil, will return null but this should not have happened',[col]),vAssertion); //critical
    {$ELSE}
    ;
    {$ENDIF}
    //todo: unless 1st inner start of a join maybe????? - better to workaround earlier, e.g. when copydatadeep finds nil...
    null:=true;
    p:=nil;
    len:=0;
    result:=ok;
    exit;
  end;
  {$ENDIF}

  {Get the column position} //todo after len: we can now move this after the null check - for all Gets....
  move(fColData[col].dataPtr^[fColData[col].offset],coff,sizeof(coff)); //get offset for this column
  //todo throughout: call ColIsNull instead of direct check
  if fColData[col].len=0 then
    null:=true
  else
    null:=false;

  if (fColData[col].len>MaxRecSize) then  //sanity check purely for debugging - todo remove or take better action?
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is illegal size %d'{todo remove(%d..%d)'},[col,fColData[col].len]),vDebugError) //critical
    {$ENDIF}
  else
  begin
    p:=@fColData[col].dataPtr^[coff];
    len:=fColData[col].len;
    //todo maybe if data=#0 & string and not-null and len=1 then return len=0 (i.e. stored '' as #0)
    //- for now trust that a string of #0 will be treated by the client as ''
    {$IFDEF DEBUGCOLUMNDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%p"',[p]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end;
end; {GetDataPointer}

function TTuple.clear(st:TStmt):integer;
{Clears the first rec for creation of an insertion record
 (also clears any previously allocated blob buffers: todo speed: so split into .clearBuffers and .clear?)

//note: only passing tr for unPin - is unPin still needed?

 RETURNS    : +ve=ok, else fail

 Assumes:
   the tuple structure has been defined (not necessary? - check)

 Note:
   frees any allocated space for blob columns (i.e. those which have been read into memory)
    - therefore call this routine BEFORE resetting any column types or count
    (else blob free could fail or not be called (only apparent when tuple is re-used in a loop))
    - also needed after colCount has been reset so calls may be: clear [free old]; colcount:=X; clear [start new]

   resets the column data pointers to the output buffer area
          (not always needed - sometimes remove to speed up?)

 //todo IN=transaction, stamp it on fRec.Wt and assert same when inserting!
}
const routine=':clear';
var
  i:ColRef;
  cid:TColId;
  coff:ColOffset;
  b:Tblob;
  bnull:boolean;
begin
  result:=ok;

  {$IFDEF DEBUG_LOG}
  //14/01/03: clear before set colCount leads to initial len offset being 6 = preInsert will overwrite & trash!
  //          ok, if clear is called again after colCount set, e.g 1st call to free blobs, 2nd to clear
  if fColCount=0 then
    log.add(who,where+routine,format('Column structure must be set before clearing',[nil]),vDebugWarning);
  {$ENDIF}

  UnPin(st);    //clear previous read's pinned pages (if any)
  {Reset 1st rec}
  fRecList.rec.Wt:=InvalidStampId;
  fRecList.rec.prevRID.pid:=InvalidPageId;
  fRecList.rec.prevRID.sid:=InvalidSlotId;
  fRecList.rec.rType:=rtRecord;
  fRecList.rec.dataPtr:=@fRecData;         //point to scratch area
  {Initialise record buffer}
  {$IFDEF ZEROISE_BUFFERS}
  fillChar(fRecData,sizeof(fRecData),0);  //nullify  //TODO remove - save time, but aids debugging... (make server switchable)
  {$ENDIF}
  i:=fColCount;
  move(i,fRecData[0],SizeOf(ColRef));
  if fColCount>0 then
    for i:=0 to fcolCount-1 do
    begin
      {If this is a blob, ensure we free any allocated memory (assumes column type hasn't changed since data was set)}
      if DataTypeDef[fColDef[i].datatype] in [stBlob] then
      begin
        if fColData[i].blobAllocated and (fColData[i].dataPtr<>nil) then
        begin
          if getBlob(i,b,bnull)=ok then
          begin
            {todo remove if, assert instead}if not bnull and (b.rid.sid=InvalidSlotId) then begin freeBlobData(b); fColData[i].blobAllocated:=false; {fColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
          end;
        end;
      end;

      cid:=fColDef[i].id;
      coff:=0;
      move(cid,fRecData[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))],sizeof(cid));
      move(coff,fRecData[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))+sizeof(cid)],sizeof(coff));
    end;
  //else todo maybe warn about clearing a tuple with 0 cols defined?
  {End column marker}
  cid:=0; //reserved for end marker
  coff:=0;       //todo ok? should be rec.len after set rec.len below?
  move(cid,fRecData[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))],sizeof(cid));
  move(coff,fRecData[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))+sizeof(cid)],sizeof(coff));
  fRecList.rec.len:=sizeof(ColRef)+((fcolCount+1)*(sizeof(cid)+sizeof(coff)));
end; {clear}

function TTuple.clearUpdate:integer;
{Clears the update rec for creation of an update record
 RETURNS    : +ve=ok, else fail

 Assumes:
   the tuple structure has been defined (not necessary? - check)

 Note:
   resets the diff-column data pointers
}
var
  i:ColRef;
  cid:TColId;
  coff:ColOffset;
  b:Tblob;
  bnull:boolean;
begin
  result:=ok;
  {Reset update new data rec}
  if fNewDataRec=nil then
  begin
    fNewDataRec:=TRec.create;     //allocate update new data record when first needed
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecCreate);
    {$ENDIF}
    new(fNewDataRec.dataPtr);     //allocate update new data buffer - ensure dataPtr is not repointed e.g. via heapfile.readRecord
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataCreate);
    {$ENDIF}
  end;
  fNewDataRec.Wt:=InvalidStampId;
  fNewDataRec.prevRID.pid:=InvalidPageId;
  fNewDataRec.prevRID.sid:=InvalidSlotId;
  fNewDataRec.rType:=rtEmpty; //todo never used
  {Initialise record buffer}
  {$IFDEF ZEROISE_BUFFERS}
  //todo check next fill is safe!
  fillChar(fNewDataRec.dataPtr^,sizeof(TrecData),0);  //nullify  //TODO remove - save time, but aids debugging... (make server switchable)
  {$ENDIF}
  i:=fDiffColCount;
  fDiffColCountDone:=0; //count as we update so we can update the column-id's in the new data rec buffer
  move(i,fNewDataRec.dataPtr^[0],SizeOf(ColRef));
  if fDiffColCount>0 then
    for i:=0 to fDiffColCount-1 do
    begin
      {If this is a blob, ensure we free any allocated memory (assumes column type hasn't changed since data was set)}
      if DataTypeDef[fColDef[i].datatype] in [stBlob] then
      begin
        if fDiffColData[i].blobAllocated and (fDiffColData[i].dataPtr<>nil) then
        begin
          if getBlob(i,b,bnull)=ok then
          begin
            {todo remove if, assert instead}if not bnull and (b.rid.sid=InvalidSlotId) then begin freeBlobData(b); fDiffColData[i].blobAllocated:=false; {fDiffColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
          end;
        end;
      end;

      cid:=0; //deferred until update
      coff:=0;
      move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))],sizeof(cid));
      move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))+sizeof(cid)],sizeof(coff));

    end;
  //else todo maybe warn about clearing a tuple with 0 cols defined?
  {End column marker}
  cid:=0; //reserved for end marker
  coff:=0;       //todo ok? should be rec.len after set rec.len below?
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))],sizeof(cid));
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(i*(sizeof(cid)+sizeof(coff)))+sizeof(cid)],sizeof(coff));
  fNewDataRec.len:=sizeof(ColRef)+((fDiffColCount+1)*(sizeof(cid)+sizeof(coff)));

  {Reset update rec}
  if fUpdateRec=nil then
  begin
    fUpdateRec:=TRec.create;     //allocate update record when first needed
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecCreate);
    {$ENDIF}
    new(fUpdateRec.dataPtr);     //allocate update buffer - ensure dataPtr is not repointed e.g. via heapfile.readRecord
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataCreate);
    {$ENDIF}
  end;
  fUpdateRec.Wt:=InvalidStampId;
  fUpdateRec.prevRID.pid:=InvalidPageId;
  fUpdateRec.prevRID.sid:=InvalidSlotId;
  fUpdateRec.rType:=rtEmpty; //todo never used
  {Initialise record buffer}
  {$IFDEF ZEROISE_BUFFERS}
  //todo check next fill is safe!
  fillChar(fUpdateRec.dataPtr^,sizeof(TrecData),0);  //nullify  //TODO remove - save time, but aids debugging... (make server switchable)
  {$ENDIF}
  //todo no need for any more?
end; {clearUpdate}

function TTuple.clearToNulls(st:TStmt):integer;
{Clears and then sets all columns to null
 //Note (todo) stub routine only? could be improved?
 RETURNS    : +ve=ok, else fail

 Assumes:
   the tuple structure has been defined

 Note:
   calls the clear routine - see its notes

   caller still needs to call PreInsert before use(?)

   caller should use this instead of just clear if only going to set odd columns
   (e.g. for findScanStart etc.)

 todo:
   use in IterGroup and other places where we try to clear nulls
}
var
  i:ColRef;
begin
  result:=clear(st);
  if fColCount>0 then
    for i:=0 to fColCount-1 do
      SetNull(i);
  //else (internal?) warning
end; {clearToNulls}

function TTuple.clearKeyIds(st:TStmt):integer;
{Clears all column keyIds to InvalidKeyId (0)
 //Note (todo) stub routine only? could be improved?
 RETURNS    : +ve=ok, else fail

 Assumes:
   the tuple structure has been defined
}
var
  i:ColRef;
begin
  if fColCount>0 then
    for i:=0 to fColCount-1 do
      fColDef[i].keyId:=InvalidKeyId;
  //else (internal?) warning
  result:=ok;
end; {clearKeyIds}

function TTuple.setKeyId(col:ColRef;keyId:TColId):integer;
{Sets column keyId
 IN:   col        - the column subscript in this tuple (matching is done by id though, not subscript position)
       KeyId      - the position in the key from left to right, starting at 1
 //Note (todo) stub routine only? could be improved?
 RETURNS    : +ve=ok, else fail

 Assumes:
   the tuple structure has been defined
}
const routine=':setKeyId';
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  fColDef[col].keyId:=KeyId;
  result:=ok;
end; {setKeyId}

function TTuple.SetWt(t:StampId):integer;
{Sets the insertion(/update) record's Wt timestamp
 - Note this is a temporary workaround for updating during rollback
 - we need to clear the tuple & recreate using Set to update
   and we need to keep the initial TranId, so this routine allows us to
   set it

   TODO: remove, or at least ensure it is not mis-used!!!
}
const routine=':SetWt';
begin
  result:=fail;
  if fRecList.rec.Wt.tranId<>InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('record timestamp is not clear (%d:%d) when trying to set to %d:%d - not updating Wt...',[fRecList.rec.Wt.tranId,fRecList.rec.Wt.stmtId,t.tranId,t.stmtId]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;
  fRecList.rec.Wt:=t;
  result:=ok;
end; {SetWt}

function TTuple.SetNull(col:ColRef):integer;
{Sets the insertion value for a null column (of any type)
 IN       : col           - the col subscript (not the id)
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetNull';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the null to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?

  //todo: also, moved this code to 'clear' routine so it should be
  // redundant here (except the length!) & in all other Set routines - todo!
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].len:=0;
  fColData[col].blobAllocated:=false; //todo assert was not true! need to free here? 

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setNull}

function TTuple.SetString(col:colRef;s:pchar;null:boolean):integer;
{Sets the insertion value for a string column
 IN       : col           - the col subscript (not the id)
          : s             - the string value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we first strip trailing spaces from the string (these will be restored for fixed length CHAR()s)

   we append the column to the end of the existing record
      - so try to set in sequence?

   we store '' as #0 to distinguish it from null (len=0) (getString will reverse this)

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetString';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved

  //todo remove ifdef: e.g. eval could call for date=user type mismatch  {$IFDEF SAFETY} //todo: do this for all Set routines?
  if DataTypeDef[fColDef[col].datatype]<>stString then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not a string (%d), not set',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  //todo: check target size is large enough & if not, truncate & return warning

  {We strip trailing spaces            //todo check: and control characters! - bad!!!!!
   from the end of all strings. Char()s will be read back and padded, varchar()s won't
  }
(*todo insert right-trim routine here!
  s:=pchar(trimRight(string(s)));       //todo: too many casts - speed up!
             doesn't work: loses #0
{$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('String trimmed to %d (%s)',[length(s),s]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
{$ENDIF}
*)
  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null and (coff+length(s)+1{todo only +1 if s=''}>=MaxRecSize) then        //todo remove?
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column offset %d + data is beyond record size (check tuple.cleared)',[coff]),vAssertion);
    {$ENDIF}
    exit;
  end;

  if not null then
  begin
    if length(s)=0 then
    begin //we store '' as #0 to distinguish it from null (getString reverses this)
      move(nullterm,fRecData[fRecList.rec.len],length(nullterm)); //todo length+2?
      fRecList.rec.len:=fRecList.rec.len+length(nullterm);   //todo length+2?
    end
    else
    begin
      move(s^,fRecData[fRecList.rec.len],length(s)); //todo length+2?
      fRecList.rec.len:=fRecList.rec.len+length(s);   //todo length+2?
    end;
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    if length(s)=0 then //stored as #0
      fColData[col].len:=length(nullterm) //todo length+2 if above?
    else
      fColData[col].len:=length(s) //todo length+2 if above?
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setString}

function TTuple.SetInteger(col:ColRef;i:integer;null:boolean):integer;
{Sets the insertion value for an integer column
 IN       : col           - the col subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetInteger';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(i,fRecData[fRecList.rec.len],sizeof(i));
    fRecList.rec.len:=fRecList.rec.len+sizeof(i);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?

  //todo: also, moved this code to 'clear' routine so it should be
  // redundant here (except the length!) & in all other Set routines - todo!
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(i)
  else
    fColData[col].len:=0;

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('set %d',[i]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setInteger}

function TTuple.SetBigInt(col:ColRef;i:int64;null:boolean):integer;
{Sets the insertion value for a big integer column
 IN       : col           - the col subscript (not the id)
          : i             - the big integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetBigInt';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(i,fRecData[fRecList.rec.len],sizeof(i));
    fRecList.rec.len:=fRecList.rec.len+sizeof(i);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?

  //todo: also, moved this code to 'clear' routine so it should be
  // redundant here (except the length!) & in all other Set routines - todo!
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(i)
  else
    fColData[col].len:=0;

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('set %d',[i]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setBigInt}

function TTuple.SetDouble(col:ColRef;d:double;null:boolean):integer;
{Sets the insertion value for a double column
 IN       : col           - the col subscript (not the id)
          : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetDouble';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stDouble then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a double (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(d,fRecData[fRecList.rec.len],sizeof(d));
    fRecList.rec.len:=fRecList.rec.len+sizeof(d);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(d)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setDouble}

//todo remove function TTuple.SetComp(col:ColRef;c:comp;null:boolean):integer;
function TTuple.SetComp(col:ColRef;d:double;null:boolean):integer;
{Sets the insertion value for a comp column

 Note: this is an attempt to handle and store floating point numbers with
       accuracy. We can't easily handle the assumed-point integer arithmetic (yet),
       so we input a double and adjust it & store it as a comp - does this help or sometimes confuse?

 IN       : col           - the col subscript (not the id)
          : d             - the double (to be comp) value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetComp';
var
  coff:ColOffset;
  c:comp;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stComp then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a comp (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}


  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {Adjust the value for storage}
  c:=d*power(10,fColDef[col].scale); //i.e. shift scale decimal places to the left

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(c,fRecData[fRecList.rec.len],sizeof(c));
    fRecList.rec.len:=fRecList.rec.len+sizeof(c);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(c)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setComp}

function TTuple.SetNumber(col:colRef;d:double;null:boolean):integer;
{Sets the insertion value for a comp, double or an integer column from a double
 If the column is an integer, it will be automatically coerced into setting a double
 If the column is a comp, it will be automatically coerced into setting a double //todo fix by setting a comp?

 IN       : col           - the col subscript (not the id)
          : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   this routine was added for the group aggregate setting, e.g. SUM(x)
   It is intended that this imprecise routine be replaced by code in the
   eval routines that handles mixed numeric types.

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetNumber';
var
  setFromInt:integer;
  setFromBigInt:int64;
  setFromComp:comp;
  coff:ColOffset;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    case DataTypeDef[fColDef[col].datatype] of
    stDouble:
      begin
        move(d,fRecData[fRecList.rec.len],sizeof(d));
        fRecList.rec.len:=fRecList.rec.len+sizeof(d);
      end;
    //this is not a double, so we coerce it
    stInteger,stSmallInt:
      begin //we can coerce an integer into a double
        setFromInt:=trunc(d);
        move(setFromInt,fRecData[fRecList.rec.len],sizeof(setFromInt));
        fRecList.rec.len:=fRecList.rec.len+sizeof(setFromInt);
        {$IFDEF DEBUGCOERCION}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('set integer (type %d) from double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
    stBigInt:
      begin //we can try to coerce a big integer into a double
        setFromBigInt:=trunc(d);
        move(setFromBigInt,fRecData[fRecList.rec.len],sizeof(setFromBigInt));
        fRecList.rec.len:=fRecList.rec.len+sizeof(setFromBigInt);
        {$IFDEF DEBUGCOERCION}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('set big integer (type %d) from double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;
    stComp:
      begin //we can coerce a comp into a double
        setFromComp:=trunc(d); //todo is this any use????
        move(setFromComp,fRecData[fRecList.rec.len],sizeof(setFromComp));
        fRecList.rec.len:=fRecList.rec.len+sizeof(setFromComp);
        {$IFDEF DEBUGCOERCION}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('set comp (type %d) from double %g',[ord(fColDef[col].datatype),d]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is not a number (%d), not set',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
      {$ELSE}
      ;
      {$ENDIF}
      d:=0;
    end; {case}
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
  begin
    case DataTypeDef[fColDef[col].datatype] of
      stDouble: fColData[col].len:=sizeof(d);
      //this is not a double, so we coerce it
      stInteger,stSmallInt:     fColData[col].len:=sizeof(setFromInt);
      stBigInt: fColData[col].len:=sizeof(setFromBigInt);
      stComp: fColData[col].len:=sizeof(setFromComp);
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Column ref %d is not a number (%d), len not set',[col,ord(fColDef[col].datatype)]),vAssertion); //critical
      {$ELSE}
      ;
      {$ENDIF}
      fColData[col].len:=0;
    end; {case}
  end
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('set %g',[d]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {SetNumber}

function TTuple.SetDate(col:ColRef;d:TsqlDate;null:boolean):integer;
{Sets the insertion value for a date column

 IN       : col           - the col subscript (not the id)
          : d             - the date value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetDate';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stDate then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a date (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}


  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(d,fRecData[fRecList.rec.len],sizeof(d));
    fRecList.rec.len:=fRecList.rec.len+sizeof(d);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(d)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setDate}

function TTuple.SetTime(col:ColRef;t:TsqlTime;null:boolean):integer;
{Sets the insertion value for a time column

 IN       : col           - the col subscript (not the id)
          : d             - the time value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

   We reset the scale to match that of the column so that binary
   comparisons/hashes are equal.

 Assumes:
   the rec has been cleared initially
   the column has not been added before

 TODO:
   obviously if this time has no timezone & no fractional seconds
   we could compress it before writing it to save ~7 bytes
}
const routine=':SetTime';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stTime then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a time (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}


  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {Reset the value's scale to match that of the column}
  t.scale:=fColDef[col].scale;
  //todo timezones should also be adjusted here?

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(t,fRecData[fRecList.rec.len],sizeof(t));
    fRecList.rec.len:=fRecList.rec.len+sizeof(t);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(t)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setTime}

function TTuple.SetTimestamp(col:ColRef;ts:TsqlTimestamp;null:boolean):integer;
{Sets the insertion value for a timestamp column

 IN       : col           - the col subscript (not the id)
          : d             - the timestamp value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

   We reset the scale to match that of the column so that binary
   comparisons/hashes are equal.
      
 Assumes:
   the rec has been cleared initially
   the column has not been added before

 TODO:
   obviously if this time has no timezone & no fractional seconds
   we could compress it before writing it to save ~7 bytes
}
const routine=':SetTimestamp';
var
  coff:ColOffset;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stTimestamp then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a timestamp (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}


  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {Reset the value's scale to match that of the column}
  ts.time.scale:=fColDef[col].scale;
  //todo timezones should also be adjusted here?
  {$IFDEF DEBUGDATETIME}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Setting timestamp: %d %d %d %d %d %d %d %d %d',[ts.date.year,ts.date.month,ts.date.day,ts.time.hour,ts.time.minute,ts.time.second,ts.time.timezone.sign,ts.time.timezone.hour,ts.time.timezone.minute]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    move(ts,fRecData[fRecList.rec.len],sizeof(ts));
    fRecList.rec.len:=fRecList.rec.len+sizeof(ts);
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(ts)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {setTimestamp}

function TTuple.SetBlob(st:TStmt;col:colRef;b:Tblob;null:boolean):integer;
{Sets the insertion reference for a blob column

 Actually reads (perhaps from disk) and copies the blob data into a new memory area,
 ready to write to disk if necessary

 IN         st            - the statement - needed in case we need to read blob from disk
          : col           - the col subscript (not the id)
          : b             - the blob reference
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing record
      - so try to set in sequence?

 Assumes:
   the rec has been cleared initially
   the column has not been added before
}
const routine=':SetBlob';
var
  coff:ColOffset;
  newB:Tblob;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check col id<>0 =reserved
  //todo ? {$IFDEF SAFETY}
  if DataTypeDef[fColDef[col].datatype]<>stBlob then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is not stored as a blob (it is type %d)',[col,ord(fColDef[col].datatype)]),vAssertion);
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}


  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  //todo: check target size is large enough & if not, truncate & return warning

  fColData[col].blobAllocated:=false; //e.g. if null

  {append the value to the end of the record}
  {point the colStart to this data}
  {increase the len}
  coff:=fRecList.rec.len;
  if not null then
  begin
    //todo here? read data from blob (b) into newly allocated memory (may come from disk or memory)
    //           store pointer to that memory here as this blob ref (sid=0)
    //           then tuple.insert etc. will create blob on disk & swizzle ref before writing record
    //                & tuple.clear will deallocate any remaining memory
    result:=copyBlobData(st,b,newB);
    if result>=ok then
    begin
      fColData[col].blobAllocated:=true; //ensure we free this memory later
      move(newB,fRecData[fRecList.rec.len],sizeof(newB));
      fRecList.rec.len:=fRecList.rec.len+sizeof(newB);
      //{$IFDEF DEBUGCOLUMNDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('set (%d %d)',[newB.rid.pid, newB.rid.sid]),vDebugLow);
      {$ENDIF}
      //{$ENDIF}
    end
    else
      exit; //abort
  end;
  move(coff,fRecData[sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));

  {Update column pointers in case this is an internal tuple & we need to read it}
  //todo maybe turn off for speed for 'real' relation tuples, i.e. if Owner<>nil?
  fColData[col].dataPtr:=fRecList.rec.dataPtr; //output buffer
  fColData[col].offset:=sizeof(ColRef)+(col*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  if not null then
    fColData[col].len:=sizeof(newB)
  else
    fColData[col].len:=0;

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Rec length increased from %d to %d',[coff,fRecList.rec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {SetBlob}


function TTuple.updateNull(col:ColRef):integer;
{Updates the value for a column to null
 (applies to all column types - currently)
 IN       : col           - the col subscript (not the id)
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the column/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateNull';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //


  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].len:=0;
  fColData[col].blobAllocated:=false; //

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateNull}

function TTuple.updateInteger(col:ColRef;i:integer;null:boolean):integer;
{Updates the value for an integer column
 IN       : col           - the col subscript (not the id)
          : i             - the new integer value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the integer/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateInteger';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then       
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(i,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(i));
    fNewDataRec.len:=fNewDataRec.len+sizeof(i);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(i)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateInteger}

function TTuple.updateBigInt(col:ColRef;i:int64;null:boolean):integer;
{Updates the value for a big integer column
 IN       : col           - the col subscript (not the id)
          : i             - the new big integer value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the integer/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateBigInt';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(i,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(i));
    fNewDataRec.len:=fNewDataRec.len+sizeof(i);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(i)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateBigInt}

function TTuple.updateDouble(col:ColRef;d:double;null:boolean):integer;
{Updates the value for a double column
 IN       : col           - the col subscript (not the id)
          : d             - the new double value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the double/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateDouble';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then       
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then        
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(d,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(d));
    fNewDataRec.len:=fNewDataRec.len+sizeof(d);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(d)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateDouble}

function TTuple.updateComp(col:ColRef;d:double;null:boolean):integer;
{Updates the value for a comp column
 IN       : col           - the col subscript (not the id)
          : d             - the new double (to be comp) value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note: this is an attempt to handle and store floating point numbers with
       accuracy. We can't easily handle the assumed-point integer arithmetic (yet),
       so we input a double and adjust it & store it as a comp - does this help or sometimes confuse?

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the double/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateComp';
var
  coff:ColOffset;
  cid:TColId;
  c:comp;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then       
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {Adjust the value for storage}
  c:=d*power(10,fColDef[col].scale); //i.e. shift scale decimal places to the left

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(c,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(c));
    fNewDataRec.len:=fNewDataRec.len+sizeof(c);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(c)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateComp}

function TTuple.updateDate(col:ColRef;d:TsqlDate;null:boolean):integer;
{Updates the value for a date column
 IN       : col           - the col subscript (not the id)
          : d             - the new date value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the date/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateDate';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(d,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(d));
    fNewDataRec.len:=fNewDataRec.len+sizeof(d);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(d)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateDate}

function TTuple.updateTime(col:ColRef;t:TsqlTime;null:boolean):integer;
{Updates the value for a time column
 IN       : col           - the col subscript (not the id)
          : d             - the new time value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the time/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateTime';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(t,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(t));
    fNewDataRec.len:=fNewDataRec.len+sizeof(t);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(t)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateTime}

function TTuple.updateTimestamp(col:ColRef;ts:TsqlTimestamp;null:boolean):integer;
{Updates the value for a timestamp column
 IN       : col           - the col subscript (not the id)
          : d             - the new timestamp value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the timestamp/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateTimestamp';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null then
  begin
    move(ts,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(ts));
    fNewDataRec.len:=fNewDataRec.len+sizeof(ts);
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    fColData[col].len:=sizeof(ts)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateTimestamp}

function TTuple.updateString(col:ColRef;s:pchar;null:boolean):integer;
{Updates the value for a string column
 IN       : col           - the col subscript (not the id)
          : s             - the new string value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

   we store '' as #0 to distinguish it from null (len=0) (getString will reverse this)

 Assumes:
   the string/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateString';
var
  coff:ColOffset;
  cid:TColId;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null and (coff+length(s)+1{todo only +1 if s=''}>=MaxRecSize) then        //todo remove?
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column offset %d + data is beyond new record size (check update tuple.cleared)',[coff]),vAssertion);
    {$ENDIF}
    exit;
  end;

  if not null then
  begin
    if length(s)=0 then
    begin //we store '' as #0 to distinguish it from null (getString reverses this)
      move(nullterm,fNewDataRec.dataPtr^[fNewDataRec.len],length(nullterm));
      fNewDataRec.len:=fNewDataRec.len+length(nullterm);
    end
    else
    begin
      move(s^,fNewDataRec.dataPtr^[fNewDataRec.len],length(s));
      fNewDataRec.len:=fNewDataRec.len+length(s);
    end;
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=false; //

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=false; //
  if not null then
    if length(s)=0 then //stored as #0
      fColData[col].len:=length(nullterm)
    else
      fColData[col].len:=length(s)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateString}

function TTuple.UpdateBlob(st:TStmt;col:colRef;b:Tblob;null:boolean):integer;
{Updates the value for a blob column

 Actually reads (perhaps from disk) and copies the blob data into a new memory area,
 ready to write to disk if necessary

 IN       : st            - the statement - needed in case we need to read blob from disk
          : col           - the col subscript (not the id)
          : b             - the new blob value
          : null          - true if new null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we append the column to the end of the existing update buffer record
      - so try to set in sequence?
   also we repoint the diffColData[] pointer to point to the original data

 Assumes:
   the blob/record needs versioning, i.e. the updating transaction will create a delta record
   the update buffer new data rec has been cleared and sized (by setting DiffColCount) initially
   the update column has not been added before
}
const routine=':updateBlob';
var
  coff:ColOffset;
  cid:TColId;
  newB:Tblob;
  newAllocation:boolean;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if (col>fColCount-1)  then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[col,fColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (fDiffColCountDone>=fDiffColCount) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('There have been too many updates (%d) for %d columns',[fDiffColCountDone,fDiffColCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo check/force in sequence - for pilot system at least
  //  this means we can append data at end of update buffer data so far
  //  - otherwise would need to handle insertions & re-jigging of existing offsets

  newAllocation:=false; //e.g. if null

  {append the new value to the end of the update new data record}
  {point the colStart to this data}
  {increase the len}
  {set the col-id in the column-header}
  coff:=fNewDataRec.len;
  if not null and (coff+sizeof(b)>=MaxRecSize) then        //todo remove?
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column offset %d + data is beyond new record size (check update tuple.cleared)',[coff]),vAssertion);
    {$ENDIF}
    exit;
  end;

  if not null then
  begin
    //todo here? read data from blob (b) into newly allocated memory (may come from disk or memory)
    //           store pointer to that memory here as this blob ref (sid=0)
    //           then tuple.insert etc. will create blob on disk & swizzle ref before writing record
    //                & tuple.clear will deallocate any remaining memory
    result:=copyBlobData(st,b,newB);
    if result>=ok then
    begin
      newAllocation:=true; //ensure we free this memory later
      move(newB,fNewDataRec.dataPtr^[fNewDataRec.len],sizeof(newB));
      fNewDataRec.len:=fNewDataRec.len+sizeof(newB);
    end
    else
      exit; //abort
  end;
  move(coff,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
  {We now update the col-id (we didn't know it until now)}
  cid:=fColDef[col].id;
  move(cid,fNewDataRec.dataPtr^[sizeof(ColRef)+(fDiffColCountDone*(sizeof(cid)+sizeof(coff)))],sizeof(cid));

  {Update diff-column pointers for when we need to write the difference record}
  fDiffColData[fDiffColCountDone].dataPtr:=fColData[col].dataPtr; //original read buffer area
  fDiffColData[fDiffColCountDone].offset:=fColData[col].offset;   //original read slot
  fDiffColData[fDiffColCountDone].len:=fColData[col].len;         //original len
                                                                //todo for integers, check old len=new len! (unless null)
  fDiffColData[fDiffColCountDone].blobAllocated:=fColData[col].blobAllocated; //ensure we free this memory later (transferred responsibility with the dataptr)

  {Update original column pointers to point to new column data}
  fColData[col].dataPtr:=fNewDataRec.dataPtr; //update buffer
  fColData[col].offset:=sizeof(ColRef)+(fDiffColCountDone*(sizeof(TcolId)+sizeof(colOffset)))+sizeof(TColId);
  fColData[col].blobAllocated:=newAllocation; //ensure we free this memory later
  if not null then
    fColData[col].len:=sizeof(newB)
  else
    fColData[col].len:=0;

  inc(fDiffColCountDone); //so we know how far we've got to be able to update the col-id at in the buffer header

  //todo check coff when empty
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Update buffer rec length increased from %d to %d',[coff,fNewDataRec.len]),vDebugLow);
  {$ENDIF}
  {$ENDIF}
  result:=ok;
end; {updateBlob}

function TTuple.CompareCol(st:TStmt;colL,colR:ColRef;tR:TTuple;var res:shortint;var null:boolean):integer;
{Compares the current values of two tuple columns
 IN:      tran        the caller transaction - may be needed for local timezone
          colL        colRef for 1st column (in this tuple)
          colR        colRef for 2nd column
          tR          tuple containing second column
 OUT:     res         result (see null)
                            -ve  L<R
                             0   L=R
                            +ve  L>R
          null        if True then result is unknown and should not be used (likely to be 0 = =)

 RESULT:  ok, or fail if error

 Assumes:
   both column references are valid
}
const routine=':compareCol';
var
  sl,sr:string;
  il,ir:integer;
  bil,bir:int64;
  dl,dr:double;
  dtl,dtr:TsqlDate;
  tml,tmr:TsqlTime;
  tsl,tsr:TsqlTimestamp;
  dayCarry:shortint;
  bl,br,bData:Tblob;
  lnull,rnull:boolean;
begin
  result:=ok;
  res:=0;
  null:=false;
  {$IFDEF SAFETY}
  {Assert colL & colR are valid subscripts}
  if (colL>fColCount-1) (*todo remove n/a:or (colL<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[colL,ColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  if (colR>tR.fColCount-1) (*todo remove n/a:or (colR<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[colR,tR.ColCount]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  with fColDef[colL] do
  begin
    {This section could be tidied and speeded up:
     e.g. the Comparible() and comparison could be done once
    }
    //todo check domainId
    //todo always make compatible: e.g. if 1>"2" - auto-coerce if possible...? too lax?

    //todo check? scale:=colScale;
    //todo check? nulls

    {Comparison matrix}
    //todo code could be simplified...
    //todo check the s,i,d (l,r) flags are all correct - else subtle logic errors! ***
    case DataTypeDef[datatype] of
      stString:
      begin
        GetString(colL,sl,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Comparing "%s" and "%s"',[sl,sr]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            if not null then //todo: note: we should take note of PAD option here! (but make sure param matching still works for Delphi updates)
              res:=CompareText(trimRight(sl),trimRight(sr)); //todo: improve speed (get rid of need for trims!)
          end; {stString}
          stInteger,stSmallInt:
          begin
            tR.GetInteger(colR,ir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                il:=strToInt(sl);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[il,ir]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if il>ir then
                res:=+1
              else
                if il<ir then res:=-1;
            end;
          end; {stInteger,stSmallInt}
          stBigInt:
          begin
            tR.GetBigInt(colR,bir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                bil:=strToInt64(sl);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[bil,bir]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if bil>bir then
                res:=+1
              else
                if bil<bir then res:=-1;
            end;
          end; {stBigInt}
          stDouble, stComp: //todo use separate routine for Comp
          begin
            if DataTypeDef[tR.fColDef[colR].datatype]<>stComp then
              tR.GetDouble(colR,dr,rnull)
            else
              tR.GetComp(colR,dr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                dl:=strToFloat(sl);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %f and %f',[dl,dr]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if dl>dr then
                res:=+1
              else
                if dl<dr then res:=-1;
            end;
          end; {stDouble}
          //todo handle stDouble=numeric
          stDate:
          begin
            tR.GetDate(colR,dtr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                dtl:=strToSqlDate(sl);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[dtl.year,dtl.month,dtl.day,dtr.year,dtr.month,dtr.day]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareDate(dtl,dtr,res);
            end;
          end; {stDate}
          stTime:
          begin
            tR.GetTime(colR,tmr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                if tR.fColDef[colR].datatype=ctTimeWithTimezone then
                  tml:=strToSqlTime(Ttransaction(st.owner).timezone,sl,dayCarry)
                else
                  tml:=strToSqlTime(TIMEZONE_ZERO,sl,dayCarry);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tml.hour,tml.minute,tml.second,tmr.hour,tmr.minute,tmr.second]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareTime(tml,tmr,res);
            end;
          end; {stTime}
          stTimestamp:
          begin
            tR.GetTimestamp(colR,tsr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                if tR.fColDef[colR].datatype=ctTimestampWithTimezone then
                  tsl:=strToSqlTimestamp(Ttransaction(st.owner).timezone,sl)
                else
                  tsl:=strToSqlTimestamp(TIMEZONE_ZERO,sl);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tsl.date.year,tsl.date.month,tsl.date.day,tsr.date.year,tsr.date.month,tsr.date.day]),vDebugLow);
              log.add(who,where+routine,format('          (%d %d %d) and (%d %d %d)',[tsl.time.hour,tsl.time.minute,tsl.time.second,tsr.time.hour,tsr.time.minute,tsr.time.second]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareTimestamp(tsl,tsr,res);
            end;
          end; {stTimestamp}
          stBlob:
          begin
            if tR.fColDef[colR].datatype=ctClob then
            begin //we can only compare char with clob
              tR.GetBlob(colR,br,rnull);
              if lnull or rnull then null:=true;
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%s) and (%d %d %d)',[sl,br.rid.pid,br.rid.sid,br.len]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              if not null then
              begin
                try
                  if copyBlobData(st,br,bData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                        //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                  begin
                    SetLength(sr,bData.len);
                    StrMove(pchar(sr),pchar(bData.rid.pid),bData.len);
                    //todo: note: we should take note of PAD option here! (but make sure param matching still works for Delphi updates)
                    res:=CompareText(trimRight(sl),trimRight(sr)); //todo: improve speed (get rid of need for trims!)
                  end;
                finally
                  freeBlobData(bData);
                end; {try}
              end;
            end
            else
            begin
              result:=fail;
              exit; //incomparable
            end;
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stString}
      stInteger,stSmallInt:
      begin
        GetInteger(colL,il,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                ir:=strToInt(sr);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[il,ir]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if il>ir then
                res:=+1
              else
                if il<ir then res:=-1;
            end;
          end; {stString}
          stInteger,stSmallInt:
          begin
            tR.GetInteger(colR,ir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[il,ir]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if il>ir then
                res:=+1
              else
                if il<ir then res:=-1;
            end;
          end; {stInteger,stSmallInt}
          stDouble, stComp: //todo use separate routine for Comp
          begin
            if DataTypeDef[tR.fColDef[colR].datatype]<>stComp then
              tR.GetDouble(colR,dr,rnull)
            else
              tR.GetComp(colR,dr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %f',[il,dr]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if il>dr then //todo tolerance? - maybe trunc(dr??? no)
                res:=+1
              else
                if il<dr then res:=-1;
            end;
          end; {stDouble}
          //todo handle stDouble=numeric
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stInteger, stSmallInt}
      stBigInt:
      begin
        GetBigInt(colL,bil,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                bir:=strToInt64(sr);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[bil,bir]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if bil>bir then
                res:=+1
              else
                if bil<bir then res:=-1;
            end;
          end; {stString}
          stInteger,stSmallInt:
          begin
            tR.GetInteger(colR,ir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %d',[bil,ir]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if bil>ir then
                res:=+1
              else
                if bil<ir then res:=-1;
            end;
          end; {stInteger,stSmallInt}
          stDouble, stComp: //todo use separate routine for Comp
          begin
            if DataTypeDef[tR.fColDef[colR].datatype]<>stComp then
              tR.GetDouble(colR,dr,rnull)
            else
              tR.GetComp(colR,dr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %d and %f',[bil,dr]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if bil>dr then //todo tolerance? - maybe trunc(dr??? no)
                res:=+1
              else
                if bil<dr then res:=-1;
            end;
          end; {stDouble}
          //todo handle stDouble=numeric
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stBigInt}
      stDouble,stComp: //todo use separate routine for Comp
      begin
        if DataTypeDef[datatype]<>stComp then
          GetDouble(colL,dl,lnull)
        else
          GetComp(colL,dl,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                dr:=strToFloat(sr);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %f and %f',[dl,dr]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if dl>dr then //todo tolerance?
                res:=+1
              else
                if dl<dr then res:=-1;
            end;
          end; {stString}
          stInteger,stSmallInt:
          begin
            tR.GetInteger(colR,ir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %f and %d',[dl,ir]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if dl>ir then //todo tolerance?
                res:=+1
              else
                if dl<ir then res:=-1;
            end;
          end; {stInteger,stSmallInt}
          stBigInt:
          begin
            tR.GetBigInt(colR,bir,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %f and %d',[dl,bir]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if dl>bir then //todo tolerance?
                res:=+1
              else
                if dl<bir then res:=-1;
            end;
          end; {stBigInt}
          stDouble, stComp: //todo use separate routine for Comp
          begin
            if DataTypeDef[tR.fColDef[colR].datatype]<>stComp then
              tR.GetDouble(colR,dr,rnull)
            else
              tR.GetComp(colR,dr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing %f and %f',[dl,dr]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              res:=0;
              if dl>dr then //todo tolerance? - maybe trunc(dr??? no)
                res:=+1
              else
                if dl<dr then res:=-1;
            end;
          end; {stDouble}
          //todo handle stDouble=numeric
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stDouble,stComp}
      //todo handle stDouble=numeric
      stDate:
      begin
        GetDate(colL,dtl,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                dtr:=strToSqlDate(sr);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[dtl.year,dtl.month,dtl.day,dtr.year,dtr.month,dtr.day]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareDate(dtl,dtr,res);
            end;
          end; {stString}
          stInteger,stSmallInt, stBigInt,
          stDouble, stComp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stDate:
          begin
            tR.GetDate(colR,dtr,rnull);
            if lnull or rnull then null:=true;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[dtl.year,dtl.month,dtl.day,dtr.year,dtr.month,dtr.day]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            if not null then
            begin
              result:=CompareDate(dtl,dtr,res);
            end;
          end; {stDate}
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable //todo really?
          end;
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stDate}
      stTime:
      begin
        GetTime(colL,tml,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                if dataType=ctTimeWithTimezone then
                  tmr:=strToSqlTime(Ttransaction(st.owner).timezone,sr,dayCarry)
                else
                  tmr:=strToSqlTime(TIMEZONE_ZERO,sr,dayCarry);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tml.hour,tml.minute,tml.second,tmr.hour,tmr.minute,tmr.second]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareTime(tml,tmr,res);
            end;
          end; {stString}
          stInteger,stSmallInt, stBigInt,
          stDouble, stComp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            tR.GetTime(colR,tmr,rnull);
            if lnull or rnull then null:=true;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tml.hour,tml.minute,tml.second,tmr.hour,tmr.minute,tmr.second]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            if not null then
            begin
              result:=CompareTime(tml,tmr,res);
            end;
          end; {stTime}
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stTime}
      stTimestamp:
      begin
        GetTimestamp(colL,tsl,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stString:
          begin
            tR.GetString(colR,sr,rnull);
            if lnull or rnull then null:=true;
            if not null then
            begin
              try
                if dataType=ctTimestampWithTimezone then
                  tsr:=strToSqlTimestamp(Ttransaction(st.owner).timezone,sr)
                else
                  tsr:=strToSqlTimestamp(TIMEZONE_ZERO,sr);
              except
                on E:Exception do
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Column %s (%d) and %s (%d) are not comparable',[name,ord(datatype),tR.fColDef[colR].name,ord(tR.fColDef[colR].datatype)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=fail;
                  exit;
                end;
              end; {try}
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tsl.date.year,tsl.date.month,tsl.date.day,tsr.date.year,tsr.date.month,tsr.date.day]),vDebugLow);
              log.add(who,where+routine,format('          (%d %d %d) and (%d %d %d)',[tsl.time.hour,tsl.time.minute,tsl.time.second,tsr.time.hour,tsr.time.minute,tsr.time.second]),vDebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              {$ENDIF}
              result:=CompareTimestamp(tsl,tsr,res);
            end;
          end; {stString}
          stInteger,stSmallInt, stBigInt,
          stDouble, stComp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            tR.GetTimestamp(colR,tsr,rnull);
            if lnull or rnull then null:=true;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[tsl.date.year,tsl.date.month,tsl.date.day,tsr.date.year,tsr.date.month,tsr.date.day]),vDebugLow);
            log.add(who,where+routine,format('          (%d %d %d) and (%d %d %d)',[tsl.time.hour,tsl.time.minute,tsl.time.second,tsr.time.hour,tsr.time.minute,tsr.time.second]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            if not null then
            begin
              result:=CompareTimestamp(tsl,tsr,res);
            end;
          end; {stTimestamp}
          stBlob:
          begin
            result:=fail;
            exit; //incomparable
          end; {stBlob}
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ELSE}
          ;
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stTimestamp}
      stBlob:
      begin
        GetBlob(colL,bl,lnull);
        case DataTypeDef[tR.fColDef[colR].datatype] of
          stBlob:
          begin
            tR.GetBlob(colR,br,rnull);
            if lnull or rnull then null:=true;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Comparing (%d %d %d) and (%d %d %d)',[bl.rid.pid,bl.rid.sid,bl.len,br.rid.pid,br.rid.sid,br.len]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            if not null then
            begin
              result:=CompareBlob(st,bl,br,((datatype=ctClob) or (tR.fColDef[colR].datatype=ctClob)),res);
            end;
          end; {stBlob}

          stString:
          begin
            if datatype=ctClob then
            begin //we can only compare clob with char
              tR.GetString(colR,sr,rnull);
              if lnull or rnull then null:=true;
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Comparing (%d %d %d) and (%s)',[bl.rid.pid,bl.rid.sid,bl.len,sr]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              if not null then
              begin
                try
                  if copyBlobData(st,bl,bData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                        //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                  begin
                    SetLength(sl,bData.len);
                    StrMove(pchar(sl),pchar(bData.rid.pid),bData.len);
                    //todo: note: we should take note of PAD option here! (but make sure param matching still works for Delphi updates)
                    res:=CompareText(trimRight(sl),trimRight(sr)); //todo: improve speed (get rid of need for trims!)
                  end;
                finally
                  freeBlobData(bData);
                end; {try}
              end;
            end
            else
            begin
              result:=fail;
              exit; //incomparable
            end;
          end;

          stInteger,stSmallInt, stBigInt,
          stDouble, stComp:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stDate:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTime:
          begin
            result:=fail;
            exit; //incomparable
          end;
          stTimestamp:
          begin
            result:=fail;
            exit; //incomparable
          end;
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown datatype %d',[ord(tR.fColDef[colR].datatype)]),vAssertion); //todo error?
          {$ENDIF}
          result:=fail;
          exit;
        end; {case}
      end; {stBlob}
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Unknown datatype %d',[ord(datatype)]),vAssertion); //todo error?
      {$ELSE}
      ;
      {$ENDIF}
      result:=fail;
      exit;
    end; {case}

  end; {with}
end; {CompareCol}

function TTuple.PreInsert:integer;
{Prepares the created tuple for insertion into the relation
 RETURNS  : +ve=ok, else fail

 Note:
   this routines needn't be called if we've just done a shallow-copy
   - if only colData[] pointers are updated, the insert buffer record need not be prepared - it's empty!
   //todo maybe we can detect if such a false/pointless call is being made...

 Assumes:
   the rec has been cleared and filled with all column data
}
const routine=':PreInsert';
var
  coff, nextCoff:ColOffset;
  i:ColRef;
begin
  result:=Fail;

  if fRecList.rec.len>0 then //todo remove this silent (crude) assertion - make proper?
  begin
    {First, set the end col marker offset to len = 1 past end}
    coff:=fRecList.rec.len;
    move(coff,fRecData[sizeof(ColRef)+(fColCount*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(coff));
    {$IFDEF DEBUGCOLUMNDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Set end column marker %d to %d',[colCount,coff]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
  end
  else
  begin
    //todo: for now, give log warning but remain silent (when called from subQuery)
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'No columns, and so presumably no valid rec.len, so preInsert did nothing',vDebugWarning); //todo: maybe assertion or error or silent?
    {$ELSE}
    ;
    {$ENDIF}
    result:=ok; //continue ok
  end;

  //{$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  //  log.add(who,where+routine,format('%s',[self.ShowMap]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
  //{$ENDIF}

  //todo if any columns have defaults, ensure they are set now
  //todo also perform any checks now? - no- use constraints!

  if fColCount>0 then //todo: again, this assertion should not be needed or not silent
    //todo check no col offsets still=0? or if so set them =to next offset
    for i:=fColCount-1 downto 0 do
    begin
      move(fRecData[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],coff,sizeof(coff));
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('column %d offset=%d',[i,coff]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      if coff=0 then
      begin
        {Look at next offset}
        move(fRecData[sizeof(ColRef)+((i+1)*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
        //todo debugAssert fCol[i].len = nextcoff-coff
        {Set this offset to the next one}
        move(nextCoff,fRecData[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],sizeof(NextCoff)); //set offset for this column
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Unset column %d set to null before insert',[i]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
    end;
  //else todo: warning
end; {PreInsert}

function TTuple.insert(st:TStmt;var rid:Trid):integer;
{Inserts the created tuple into the relation (+ any index entries) (+ any blob entries)

 IN       : st              the statement
 OUT      : rid             the RID inserted into //todo rename- name clash with Ttuple.rid - could be confusing?
 RETURNS  : +ve=ok, else fail

 Note:
   the tuple is inserted wherever there is space for it
   e.g. inserting t1,t2,t3 into a new relation does not guarantee that they will be inserted in that order
   (because relations (currently) use heap files)

   The tuple's fRID is set by this routine for reference

   We don't check constraints here - that's left to a higher level, so
   beware of loop-holes.

 Side-effects:
   If the tuple's owner has indexes attached, their AddKeyPtr methods are called for this data
   Note: not sure that this is the best place to call such methods, with them being attached to
         the relation and not the tuple, but:
           i) it's neater for initial index (& future!?) development to not have to remember
              to call each index add (or more likely would be relation.addAllIndexEntries)
              after every insert etc. - e.g. iterInsert, relation.CreateNew etc. etc.
           ii) we remove any chance of forgetting to add an index - this routine is always used!
           ii) all real (non-virtual) tuples are owned by a relation anyway
               - if this routine is called on a virtual tuple it fails with an assertion

   Any blob columns are written first (hopefully they're small & will fit on the same page as this record)
   (also they are swizzled to point to their new disk rids)

 Assumes:
   the rec has been cleared, filled //todo remove - we seem to do this now: and preInserted todo: avoid duplicating calls:speed

 Note:
   we use Tr.Wt for timestamping
}
const routine=':Insert';
var
  indexPtr:TIndexListPtr;

  {for blob writing}
  coff, nextCoff:ColOffset;
  i:ColRef;
  bv:Tblob;
  bvnull:boolean;
  blobRid:Trid;
  blobLen:cardinal;
begin
  result:=Fail;
  {$IFDEF SAFETY}
  if st=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Missing transaction',vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  PreInsert; //set slot end marker & check column slots

  fRecList.rec.Wt:=st.Wt; //set Wt to this transaction
  fRecList.rec.rType:=rtRecord;
  fRecList.rec.prevRID.pid:=InvalidPageId;
  fRecList.rec.prevRID.sid:=InvalidSlotId;

  {$IFDEF SAFETY} //todo remove? since we crash if not trapped
  {Assert owner is valid}
  if not assigned(owner) then        //todo remove?
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'Tuple is not associated with a relation',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  {Now, add any blob data}
  if fColCount>0 then //todo: again, this assertion should not be needed or not silent
    //todo check no col offsets still=0? or if so set them =to next offset
    for i:=0 to fColCount-1 do
    begin
      if fColDef[i].dataType in [ctBlob,ctClob] then
      begin
        move(fRecData[sizeof(ColRef)+(i*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],coff,sizeof(coff));
        move(fRecData[sizeof(ColRef)+((i+1)*(sizeof(TcolId)+sizeof(coff)))+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column
        //todo debugAssert fCol[i].len = nextcoff-coff
        if nextCoff-coff<>0 then
        begin //not null
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('  inserting blob column %d offset=%d',[i,coff]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          getBlob(i,bv,bvnull);
          if insertBlobData(st,bv,blobRid)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('failed inserting blob column %d, aborting insert',[i]),vDebugLow);
            {$ENDIF}
            //todo delete any blobs just inserted otherwise they will be orphaned now
            exit; //abort
          end;
          {Now update this column's blob reference to point to our new disk rid}
          //but first we must release the in-memory blob now it's on disk! (code taken from Ttuple.clear)
          {$IFDEF DEBUG_LOG}
          if not fColData[i].blobAllocated then
            log.add(who,where+routine,format('Blob just written has no allocation flag',[nil]),vAssertion);
          {$ENDIF}
          blobLen:=bv.len; //remember, since freeBlobData will zeroise it //obviously len remains unchanged (unless in future we store differently on disk somehow?)
          begin freeBlobData(bv); fColData[i].blobAllocated:=false; {fColData[i].len:=0;}{prevent re-free: todo okay? safe?} end;
          bv.rid:=blobRid;
          bv.len:=blobLen;
          move(bv,fRecData[coff],sizeof(bv)); //overwrite in-place (take care!)
        end;
      end;
    end;
  //else todo: warning



  {Now, add the record}
  result:=(owner as TRelation).dbFile.AddRecord(st,fRecList.rec,rid);

  if result=ok then
  begin
    {We store the RID of the new record now for any future use (e.g index keyPtr addition)}
    fRID:=rid;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('%d:%d inserted [Wt=%d](%d)',[rid.pid,rid.sid,fRecList.rec.Wt.tranId,fRecList.rec.len]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    {Now add any index entries}
    //Note: this logic is duplicated in the Trelation.ScanAlltoIndex routine (for index (re)building)
    indexPtr:=(owner as TRelation).indexList;
    while indexPtr<>nil do
    begin

      if indexPtr.index.AddKeyPtr(st,self,rid)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed inserting %d:%d into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugError); //todo user error?
        {$ELSE}
        ;
        {$ENDIF}
        //todo: should we continue to return ok to caller... todo: not critical???? or is it??? I think it probably is!...so....
        result:=fail; //return fail for now, but continue to try and add rest of index entries anyway...
        //todo once caller's can handle +ve result: result:=result+1;
      end
      else
      begin
        {$IFDEF DEBUGINDEXDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%d:%d inserted into index %s',[rid.pid,rid.sid,indexPtr.index.name]),vDebugMedium);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      indexPtr:=indexPtr.next;
    end;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Failed inserting [Wt=%d:%d](%d)',[fRecList.rec.Wt.tranId,fRecList.rec.Wt.stmtId,fRecList.rec.len]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    //todo: invalidate fRID to be safe????

//{$IFDEF DEBUGDETAIL}
{$IFDEF DEBUG_LOG}
//  log.add(who,where+routine,'PostInsert:'+format('%s',[self.ShowMap]),vDebug);
{$ELSE}
;
{$ENDIF}
//{$ENDIF}

  //todo auto-clear?
end; {Insert}

function TTuple.FindCol(find_node:TSyntaxNodePtr;const colName:string;rangeName:string;outerRef:TObject{==TIterator};var cTuple:TTuple;var c:ColRef;var colId:TColId):integer;
{Finds the column reference and id given its (full) name
 //todo: in most cases, repeated calls to this should be avoided by remembering the mappings
         - see IterGroup and EvalCondExpr callers...

 IN        find_node         the ntColumnRef node to search for (can include ntTable,ntSchema,ntCatalog)
           colName           the column name
                               //todo: if find_node is passed, this should not not be used
                               it could be needed to find columns rather than columnRefs, i.e. where no prefix is permitted
           rangeName         the table or range name //todo: deprecate
                               if this is blank, find_node.ntTable is used: otherwise this overrides find_node.ntTable
           outerRef          the outer iterator reference (used for correlations)
                                 - we search the current iterator's tuple first, if we find no match
                                   then we progress up through the chain of outer iterators and search each
                                   of those until we find a match (or there are no outer ones left).
                                   This chain of iterators provides scoping, and each can be thought of as
                                   the 'current context'.
 OUT       cTuple            the tuple reference (may not be self if a match was found in an outer context)
           c                 the column reference/subscript
           colId             the column id, InvalidColId if not found
 RESULT    ok, else fail (use colId for real 'failure to find match')
           -2=ambiguous-column-ref

 Note:
    if table/rangeName is blank, then assume only one with this column name
                                              - else fail with 'ambiguous column name'
                                              - note: leaving blank means we have to loop through ALL
                                                      columns in the relation (or maybe an outer plan's relation)
                                                      which takes longer
                                              //todo: unless we could guarantee that we
                                              //      trapped ambiguous references earlier = faster loops!

    if commonColumn<>0 then any attempt to use a prefix that matches anything other than the column's rangeName (i.e. alias)
    will fail, unless the find_node.systemNode=True, i.e. we're a system generated column reference
    Also, ambiguous columns will not be sought: it is assumed they are all marked 'common'
        and so the first one is matched ok, unless we have no range specified & it is -ve in which case we keep looking for the favoured one, e.g. for projection
}
const routine=':FindCol';
var
  i:ColRef;
begin
  //todo use hash function!

  {$IFDEF SAFETY}
  if (outerRef<>nil) and not(outerRef is TIterator) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('outerRef %p is not a TIterator',[@outerRef]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  result:=ok;

  {If no rangeName override was specified, take any table name from the find_node
   (if a rangeName was given, it might be the same as the find_node table name, but not necessarily: it could have been aliased)
   (if no find_node was given, then there is no table name or range name)}
  if rangeName='' then
    if find_node<>nil then //ntColumnRef
      if find_node.leftChild<>nil then
        rangeName:=find_node.leftChild.rightChild.idVal; //ntTable name

  //todo debugAssert that colName=find_node col name

  i:=0;
  cTuple:=self; //default result to this tuple
  colId:=InvalidColId;
  while (i<=fColCount-1) do 
  begin
    {Only match if both the column name and its originating source relation name match}
    if CompareText(trimRight(fColDef[i].name),trimRight(colname))=0 then //todo case! use = function
    begin
      //todo: need a way of telling whether this table has been explicitly aliased or not... otherwise we will accept: schema.alias.column!
      //If we have a rangeName then we have been aliased, so check if it matches any required alias
      if (fColDef[i].sourceRange=nil) or //(i.e. if no sourceRange then no alias=assume system-match base table during constraint check, e.g. insert) //todo: it could be though that the specified alias does not match the table-name but we currently can't tell...
        (
        ( (trimRight(TAlgebraNodePtr(fColDef[i].sourceRange).rangeName)<>'') ) //then
      //begin //todo: deprecate
        //note: uses boolean short-circuiting
        and{if} ( (find_node=nil){nothing} or (find_node.leftChild=nil){no table} or (find_node.leftChild.leftChild=nil){no schema} )
           and (CompareText(trimRight(TAlgebraNodePtr(fColDef[i].sourceRange).rangeName),trimRight(rangeName))=0)
        ) then    //todo case! use = function
        begin //no catalog/schema prefix was specified, so we just matched the rangeName against the column range name (defaults to table name)
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Fully matched column reference %s.%s to relation %d',[rangeName,colName,longint(fColDef[i].sourceRange)]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          colId:=fColDef[i].id;
          c:=i;
          break; //full match - done
        end
      //end
      else
        if (find_node<>nil) and (find_node.leftChild<>nil){prefixed} {todo?? or (fColDef[i].sourceRange=nil)} then
        begin //check if the specified table, schema, catalog prefix matches the column's
          if ( (CompareText(trimRight(TAlgebraNodePtr(fColDef[i].sourceRange).tableName),trimRight(find_node.leftChild.rightChild.idVal{table name}))=0) ) then    //todo case! use = function
            if ( (find_node.leftChild.leftChild=nil) or (CompareText(trimRight(TAlgebraNodePtr(fColDef[i].sourceRange).schemaName),trimRight(find_node.leftChild.leftChild.rightChild.idVal{schema name}))=0) ) then    //todo case! use = function
              if ( (find_node.leftChild.leftChild=nil) or (find_node.leftChild.leftChild.leftChild=nil) or (CompareText(trimRight(TAlgebraNodePtr(fColDef[i].sourceRange).catalogName),trimRight(find_node.leftChild.leftChild.leftChild.rightChild.idVal{catalog name}))=0) ) then    //todo case! use = function
              begin
                {If this column has been marked for natural join merging, then we're trying to use too-specific a prefix, i.e. not a rangeName (alias)}
                if (fColDef[i].commonColumn<>0) and not(find_node.systemNode) then
                begin
                  //ignore match, since we're not a system-generated column reference which does allow specific prefixing of natural common columns
                  inc(i);
                  continue; //keep searching, though likely to fail
                end
                else //matched
                  if colId=InvalidColId then
                  begin
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Matched column reference ...%s.%s to relation %d',[find_node.leftChild.rightChild.idVal,colName,longint(fColDef[i].sourceRange)]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    //Note we match even if commonColumn<0, since the search was specific, e.g. a join condition
                    colId:=fColDef[i].id;
                    c:=i;
                    if fColDef[i].commonColumn<>0 then break; //done: others with same name are not ambiguous: they will have also been marked as commonColumn like this one: they are the same
                    //else we continue the loop to check this is not ambiguous
                  end
                  else
                  begin
                    {We already found a column matching this name, and no rangeName was given so we have an ambiguous reference}
                    //we keep the original match - i.e. pick the first from left
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Ambiguous column reference (%s.%s)',[find_node.leftChild.rightChild.idVal,colName]),vError); //todo user error here?
                    log.add(who,where+routine,self.ShowHeading,vDebugLow);
                    {$ENDIF}
                    result:=-2;
                    //todo exit now? no point list other matches except for debugging
                    // - so, exit if not debugOn...
                  end;
              end;
        end
        else
        begin //no prefix was specified so match
          if colId=InvalidColId then
          begin
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Matched column reference %s to relation %d',[colName,longint(fColDef[i].sourceRange)]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            if fColDef[i].commonColumn<0 then
            begin
              //we know this column has been ignored in favour of another with the same name
              //so we keep looking for the favoured copy (so we get the column from the correct part of the outer join for example)
              //                                         (- except full outer which needs to pick the non-null value from both: todo)
            end
            else
            begin
              colId:=fColDef[i].id;
              c:=i;
              if fColDef[i].commonColumn<>0 then break; //done: others with same name are not ambiguous: they will have also been marked as commonColumn like this one: they are the same
              //else we continue the loop to check this is not ambiguous
            end;
          end
          else
          begin
            {We already found a column matching this name, and no rangeName was given so we have an ambiguous reference}
            //we keep the original match - i.e. pick the first from left
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Ambiguous column reference (%s)',[colName]),vError); //todo user error here?
            log.add(who,where+routine,self.ShowHeading,vDebugLow);
            {$ENDIF}
            result:=-2;
            //todo exit now? no point list other matches except for debugging
            // - so, exit if not debugOn...
          end;
        end;
    end;
    inc(i);
  end; {while}

  {Do we need to search the outer plan?}
  {Note: we don't search outer if we've found a match,
   even though there may be another in the outer plan with the
   same name (even including the range name) - i.e. we hide the outer layers
   and the column names are thus given a natural scope which I think complies
   with the SQL standard.
  }
  if (colId=InvalidColId) and (outerRef<>nil) then
  begin
    {Recurse into outer plan to try and find a match
     i.e. this is a correlated sub-query}
    result:=TIterator(outerRef).iTuple.FindCol(find_node,colName,rangeName,
                                               TIterator(outerRef).outer{==TIterator},
                                               cTuple,c,colId);
    //todo: maybe if we get a result (colId<>InvalidColId) then
    //we should flag this sub-query as being correlated ?
    // - should already know?
  end;
end; {FindCol}

function TTuple.FindColFromId(colId:TColId;var c:ColRef):integer;
{Finds the column reference given its id

 IN        colId             the column id
 OUT       c                 the column reference/subscript
 RESULT    ok, else fail (=> don't use result)
}
const routine=':FindColFromId';
var
  i:ColRef;
begin
  //todo use hash function!

  result:=ok;
  i:=0;
  while (i<=fColCount-1) do
  begin
    if (fColDef[i].id=colId) then
    begin
      c:=i;
      break;
    end;
    inc(i);
  end;

  if (c=fColCount) then
    result:=Fail   //not found
  else
    result:=ok;
end; {FindColFromId}


function TTuple.Show(st:TStmt):string;
{Debug only (except for dumb client results!)

 IN:  tran - may be needed for local timezone
             if nil is passed, no timezone is used = risk of bad times, but ok for debug

 Returns a display of the whole tuple

 Note: if we are just debugging we may be paying a large price
       for blob displaying (memory re-allocation, disk re-read, etc.)

 Note: the debug info is only as good as this routine allows!
       CRLF are removed

 Assumes:
   we have read one
}
const
  routine=':Show';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;
  defaultBlobSize=100;

  maxSize=100; //todo increase - keep in sync with showHeading!
var
  i:colRef;
  size,scale,j:integer;
  s:string;
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv,bvData:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;
begin
  result:='';
  {$IFDEF DEBUG_LOG}
  {$IFDEF DEBUGRID}
  //todo need to move to eval & iterRelation... s:=format('%-*s',[8,format('%4.4d:%3.3d',[(owner as Trelation).dbfile.currentRID.pid,(owner as Trelation).dbfile.currentRID.sid])]);
  //todo need to move to eval & iterRelation... result:=result+separator+s;
  {$ENDIF}
  {$ENDIF}
 if fColCount>0 then //todo remove this assertion - should be no need here...
  for i:=0 to fColCount-1 do
  begin
    s:='?';
    if fColData[i].dataPtr<>nil then //todo debug:avoid crash if tuple data is not initialised
    begin
      if fColDef[i].dataType in [ctChar,ctVarChar,ctBit,ctVarBit] then
      begin
        GetString(i,sv,sv_null);
        size:=fColDef[i].width;
        if size=0 then size:=DefaultStringSize;
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        sv:=stringReplace(sv,CRLF,' ',[rfReplaceAll]);
        if not sv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctInteger,ctSmallInt] then
      begin
        GetInteger(i,iv,iv_null);
        size:=fColDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not iv_null then s:=format('%*d',[size,iv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctBigInt] then
      begin
        GetBigInt(i,biv,biv_null);
        size:=fColDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not biv_null then s:=format('%*d',[size,biv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctNumeric,ctDecimal] then
      begin
        GetComp(i,dv,dv_null);
        size:=fColDef[i].width;
        scale:=fColDef[i].scale;
        if fColDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*.*f',[size,scale,dv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType=ctFloat then
      begin
        GetDouble(i,dv,dv_null);
        size:=defaultFloatWidth;
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        //todo why not? if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*s',[size,format('%g',[dv])]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctDate] then
      begin
        GetDate(i,dtv,dtv_null);
        size:=fColDef[i].width; //todo DATE_MIN_LENGTH fixed?
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dtv_null then s:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]) else s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctTime,ctTimeWithTimezone] then
      begin
        GetTime(i,tmv,tmv_null);
        size:=fColDef[i].width; //todo TIME_MIN_LENGTH + fixed?
        if fColDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tmv_null then
        begin
          if (fColDef[i].dataType=ctTimeWithTimezone) and (st<>nil) then
            s:=sqlTimeToStr(Ttransaction(st.owner).timezone,tmv,fColDef[i].scale,dayCarry)
          else
            s:=sqlTimeToStr(TIMEZONE_ZERO,tmv,fColDef[i].scale,dayCarry);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctTimestamp,ctTimestampWithTimezone] then
      begin
        GetTimestamp(i,tsv,tsv_null);
        size:=fColDef[i].width; //todo TIMESTAMP_MIN_LENGTH + fixed?
        if fColDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tsv_null then
        begin
          if (fColDef[i].dataType=ctTimestampWithTimezone) and (st<>nil) then
            s:=sqlTimestampToStr(Ttransaction(st.owner).timezone,tsv,fColDef[i].scale)
          else
            s:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,fColDef[i].scale);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fColDef[i].dataType in [ctBlob,ctClob] then
      begin
        //todo ifdef debug fast blobs then avoid getblob & just use [BLOB] (especially for internal shows)
        GetBlob(i,bv,bv_null);
        size:=defaultBlobSize;
        if not bv_null then
          try
            if copyBlobData(st,bv,bvData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                   //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
            begin
              size:=fColDef[i].width;
              if fColDef[i].dataType in [ctBlob] then size:=size*2{double since we output as hexits};
              //todo assert size=bvData size
              if size=0 then size:=defaultBlobSize;
              if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
              if size>maxSize then size:=maxSize;
              sv:='';
              iv:=bv.len; if iv>size then iv:=size;
              if fColDef[i].dataType in [ctClob] then
              begin //char data
                setLength(sv,iv);
                strMove(pchar(sv),pchar(bvData.rid.pid),iv);
              end
              else //binary->hexits
                for j:=0 to iv-1 do //(size div 2)-1 do
                begin
                  sv:=sv+intToHex(ord(pchar(bvData.rid.pid)[j]),2);
                end;
            end;
          finally
            freeBlobData(bvData);
          end; {try}
        if not bv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;

    end;

    result:=result+separator+s;
  end;
end; {show}
function TTuple.ShowMap:string;
{Debug only
 Returns a display of the tuple column mappings

 Assumes:
   we have read one
}
const
  routine=':ShowMap';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
var
  i:colRef;
  s:string;
  coff,nextCoff:ColOffset;
begin
  result:='';
 if fColCount>0 then //todo remove this assertion - should be no need here...
  for i:=0 to fColCount-1 do
  begin
    s:='';
    {Note: these pointers are taken from GetString routine}
    move(fColData[i].dataPtr^[fColData[i].offset],coff,sizeof(coff)); //get offset for this column
    move(fColData[i].dataPtr^[fColData[i].offset+sizeof(ColOffset)+sizeof(TColId)],nextCoff,sizeof(nextCoff)); //get offset for next column

    //todo debugAssert len=nextcoff-coff

    s:=format('%s(%d):[%d]=(%d) %d..%d',[fColDef[i].name,fColDef[i].id,fColData[i].offset,fColData[i].len,coff,nextCoff]);
    result:=result+separator+s;
  end;
  {$IFDEF DEBUG_LOG}
  log.logFlush;
  {$ELSE}
  ;
  {$ENDIF}
end; {showMap}
function TTuple.ShowHeading:string;
{Debug only
 Returns a display of the whole tuple's headings

 Assumes:
   we have opened the relation
}
const
  routine=':ShowHeading';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;
  defaultBlobSize=100;

  maxSize=100; //todo increase!
var
  i:colRef;
  size:integer;
  s:string;
  sv:string;
begin
  result:='';
  {$IFDEF DEBUG_LOG}
  {$IFDEF DEBUGRID}
  //todo need to move to eval & iterRelation... s:=format('%-*.*s',[8,8,'RID']);
  //todo need to move to eval & iterRelation... result:=result+separator+s;
  {$ENDIF}
  {$ENDIF}
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      sv:=fColDef[i].name;
      {$IFDEF DEBUG_LOG}
      {$IFDEF DEBUG_ALIAS}
      if fColDef[i].sourceRange<>nil then
        sv:=sv+'['+intToStr(TAlgebraNodePtr(fColDef[i].sourceRange).originalOrder)+'/'
              +intToStr(fColDef[i].commonColumn)+':'
              +(TAlgebraNodePtr(fColDef[i].sourceRange).catalogName)+'.'
              +(TAlgebraNodePtr(fColDef[i].sourceRange).schemaName)+'.'
              +(TAlgebraNodePtr(fColDef[i].sourceRange).tableName)+' '
              +(TAlgebraNodePtr(fColDef[i].sourceRange).rangeName)+']';
      {$ENDIF}
      {$ENDIF}
      size:=fColDef[i].width;
      if size=0 then
      begin
        if fColDef[i].datatype in [ctChar,ctVarChar,ctBit,ctVarBit,ctClob] then
          size:=DefaultStringSize;
        if fColDef[i].dataType in [ctInteger,ctSmallInt,ctBigInt] then
          size:=DefaultIntegerSize;
      end;
      if fColDef[i].dataType=ctFloat then
        size:=defaultFloatWidth;
      if fColDef[i].scale<>0 then size:=size+1; //for d.p.
      if fColDef[i].datatype in [ctBlob] then
        if (size*2{output as hexits}>maxSize) then
          size:=DefaultBlobSize
        else
          size:=size*2;{output as hexits}

      if length(sv)>size then size:=length(sv);

      if size>maxSize then size:=maxSize;
      s:=format('%-*.*s',[size,size,sv]);

      result:=result+separator+s;
    end;
end; {showHeading}
function TTuple.ShowHeadingKey:string;
{Debug only
 Returns a display of the tuple's key column headings

 Assumes:
   we have opened the relation
}
const
  routine=':ShowHeadingKey';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;

  maxSize=100; //todo increase!
var
  i:colRef;
  size:integer;
  s:string;
  sv:string;
begin
  result:='';
  if fColCount>0 then
    for i:=0 to fColCount-1 do
    begin
      if fColDef[i].keyId>0 then
      begin
        s:=format('%s(%d)',[fColDef[i].name,fColDef[i].keyId]);

        result:=result+separator+s;
      end;
      //else non-key column
    end;
end; {showHeadingKey}

procedure TTuple.SetRID(r:Trid);
{Set the RID source reference
 Safer (more obvious) than setting RID directly
 - todo allow write of fRID in future?
}
begin
  fRID:=r;
end;


function TTuple.copyBlobData(st:TStmt;b:Tblob;var newb:Tblob):integer;
{Read the blob data and copy into a new memory area

 IN:        st    - statement needed in case we need to hit the disk
            b     - the source blob reference
            newb  - the reference to the in-memory blob copy

 todo: pass a temp-use switch to avoid copying memory if caller knows the source
       is in memory & will outlive any new allocation, i.e. avoid allocation & copy, just
       ensure we have a valid memory pointer (i.e. read from disk if necessary)

 assumes: blob is not null
          b<>newb
          caller will set ColData[].blobAllocated:=true if required

 Note:    although this is currently a method of TTuple, it uses st to determine
          where to read from, so it (& other blob routines) could stand alone (or elsewhere, e.g. db?)

 Returns ok, else fail
          -2 = record was not blob type
          -3 = failed reading blob record

          +2 = ok(?) but length read from disk did not match length stored on record
}
const
  routine=':copyBlobData';
var
  source,target,targetOffset:pointer;
  sourceDiskRid:Trid;
  page:TPage;
  //targetOffset:cardinal;
  sHeader, slot:TSlot; //todo do heapfile.readRecord's job
  tempRes:integer;
begin
  result:=fail;

  //todo assert newb.rid.pid=InvalidPageId?
  //todo in future, maybe retain a minimum sized buffer rather than deallocating each time?
  // - only really matters when we evaluate/project the blob i.e. not very often?

  newb.rid.pid:=InvalidPageId;
  newb.rid.sid:=InvalidSlotId;
  newb.len:=0;

  if b.rid.sid=InvalidSlotId then
  begin //source is in memory so simply duplicate it
    source:=pointer(b.rid.pid);
    getMem(target,b.len); 
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    debugTupleBlobAllocated:=debugTupleBlobAllocated+b.len;
    inc(debugTupleBlobRecAllocated);
    {$ENDIF}
    {$IFDEF ZEROISE_BUFFERS}
    fillChar(target^,b.len,0);  //nullify  //TODO remove - save time, but aids debugging... (make server switchable)
    {$ENDIF}
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Copying blob data from memory %p (len=%d) to %p',[source,b.len,target]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    newb.rid.pid:=PageId(target);
    newb.rid.sid:=InvalidSlotId; //mark as memory resident blob
    newb.len:=b.len;
    move(source^,target^,b.len);
    result:=ok;
  end
  else
  begin //source is still on disk so read and copy into memory now
    sourceDiskRid:=b.rid;
    getMem(target,b.len); 
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    debugTupleBlobAllocated:=debugTupleBlobAllocated+b.len;
    inc(debugTupleBlobRecAllocated);
    {$ENDIF}
    {$IFDEF ZEROISE_BUFFERS}
    fillChar(target^,b.len,0);  //nullify  //TODO remove - save time, but aids debugging... (make server switchable)
    {$ENDIF}
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Copying blob data from disk %d:%d (len=%d) to %p',[b.rid.pid,b.rid.sid,b.len,target]),vDebugLow);
    {$ENDIF}
    {$ENDIF}

    newb.rid.pid:=PageId(target);
    newb.rid.sid:=InvalidSlotId; //mark as memory resident blob
    newb.len:=b.len;
    targetOffset:=target; //write cursor
    repeat
      if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,sourceDiskRid.pid,page)<>ok then exit;  //get pointer
      try
        //if (owner as TRelation).dbFile.ReadRecord(st,page,sourceDiskRid.sid,fBlobRec)=ok then
        {Note: since we might be a tuple copied far from the original source, we can't assume we have an owner/file
         so we've duplicated the THeapFile.readRecord code here (for now) to read blobs almost raw from the disk...
         todo remove this if possible!}
        //*** start of readRecord duplicate code
        tempRes:=ok;
        {Read page header}
        page.AsBlock(st,0,sizeof(sHeader),@sHeader);
        if sHeader.rType<>rtHeader then
        begin //avoid whizzing through invalid slots if our slot header len is unsafe 29/01/03 (not sure of cause, but could be old index pointer)
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('SID %d refers to page %d which has no slot header',[sourceDiskRid.sid,page.block.thispage]),vAssertion);
          {$ENDIF}
          tempRes:=Fail;
        end;
        if sourceDiskRid.sid>sHeader.len{=slotCount} then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('SID %d is beyond %d=slots in this page',[sourceDiskRid.sid,sHeader.len{=slotCount}]),vAssertion);
          {$ENDIF}
          tempRes:=Fail;
        end;
        if (tempRes=ok) and (sourceDiskRid.sid<=0) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('SID %d is invalid (0=header slot)',[sourceDiskRid.sid]),vAssertion);
          {$ENDIF}
          tempRes:=Fail;
        end;
        if tempRes=ok then
        begin
          {Read slot entry}
          page.AsBlock(st,sourceDiskRid.sid*sizeof(slot),sizeof(slot),@slot);
          {Pass back slot entry in the record}
          fBlobRec.rType:=slot.rType;
          fBlobRec.Wt:=slot.Wt;
          fBlobRec.PrevRID:=slot.PrevRID;
          {Point record data}
          fBlobRec.len:=slot.len;
          fBlobRec.dataPtr:=@page.block.data[slot.start];    //i.e. slot points to disk, rec points to memory
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%d:%d record read (avoiding heapfile.readRecord) as Wt=%d:%d rType=%d prev.pid=%d prev.sid=%d len=%d',[page.block.thispage,sourceDiskRid.sid,fBlobRec.wt.tranId,fBlobRec.wt.stmtId,ord(fBlobRec.rtype),fBlobRec.prevRID.pid,fBlobRec.prevRID.sid,fBlobRec.len]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
        end;
        //*** end of readRecord duplicate code
        if tempRes=ok then
        begin
          if fBlobRec.rtype in [rtBlob] then
          begin //append this record data to our blob copy
            {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('  reading blob data segment from disk %d:%d (len=%d)',[sourceDiskRid.pid,sourceDiskRid.sid,fBlobRec.len]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            move(fBlobRec.dataPtr^[0],targetOffset^,fBlobRec.len);
            targetOffset:=pchar(targetOffset)+fBlobRec.len;
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format(' Record is not a blob, reading %d:%d',[sourceDiskRid.pid,sourceDiskRid.sid]),vAssertion); //todo error?
            {$ENDIF}
            result:=-2;
            exit; //reject/abort
          end;
          sourceDiskRid:=fBlobRec.prevRID; //loop again to read next data block in the blob chain
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(' Failed reading %d:%d',[sourceDiskRid.pid,sourceDiskRid.sid]),vDebugError);
          {$ENDIF}
          result:=-3;
          exit; //reject/abort
        end;
      finally
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unPinPage(st,page.block.thisPage);
      end; {try}
    until sourceDiskRid.pid=InvalidPageId; //no more data

    result:=ok;

    if targetOffset<>(pchar(target)+newb.len) then
    begin //the length we read didn't match what we expected
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('  blob data expected len=%d, actually read len=%d - mismatch!',[newb.len,(pchar(targetOffset)-pchar(target))]),vAssertion);
      {$ENDIF}
      result:=+2; //todo return -ve = error; or at least fix the record length now! .. a job for garbage collector?
    end;
  end;
end; {copyBlobData}

function TTuple.freeBlobData(var b:Tblob):integer;
{Deallocates blob in-memory data

 Returns:
    b with any memory deallocated & any memory reference set to InvalidPageId
    although up to caller to set b back to its source (or other-wise remember it's been freed)

 Initially used for after copyBlobData to a temporary blob ref.
}
const routine=':freeBlobData';
begin
  result:=ok;

  if b.rid.sid<>InvalidSlotId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format(' Record is not an in-memory blob (%d:%d)',[b.rid.pid,b.rid.sid]),vAssertion); //todo not an error?
    {$ENDIF}
    result:=fail; //too strong, return +ve?
  end
  else
  begin
    {$IFDEF SAFETY}
    if b.rid.pid=InvalidPageId then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format(' Record is an in-memory blob but has an invalid address (%d:%d)',[b.rid.pid,b.rid.sid]),vAssertion);
      {$ENDIF}
      result:=fail;
      exit;
    end;
    {$ENDIF}

    freemem(pointer(b.rid.pid),b.len);
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    debugTupleBlobDeallocated:=debugTupleBlobDeallocated+b.len;
    inc(debugTupleBlobRecDeallocated);
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Freed blob at %p (len=%d)',[pointer(b.rid.pid),b.len]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    b.rid.pid:=InvalidPageId; //safety
    b.len:=0;
  end;
end; {freeBlobData}

function TTuple.insertBlobData(st:TStmt;b:Tblob;var bRid:Trid):integer;
{Inserts the blob data into the relation and returns the location
 (used before for storing the tuple)

 IN:        st    - statement needed in case we need to hit the disk
            b     - the source blob reference
 OUT:       bRid  - the starting storage location (i.e. 1st block in the blob chain)

 assumes: blob is not null & blob is in memory
          (if not, it will be read into memory here - but check when & why needed...)

 Note: if caller overwrites the blob ref with the new disk target, then it is
       responsible for first releasing the in-memory blob data!

 Returns ok, else fail
          -2 = failed writing blob record
}
const
  routine=':insertBlobData';
var
  source,sourceCursor:pointer;
  sourceOffset,maxBlobSegment:cardinal;
  sHeader:TSlot; //just for sizing
  justRead:boolean;
begin
  result:=fail;

  justRead:=false;
  if b.rid.sid<>InvalidSlotId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format(' Record is not an in-memory blob, will read now (may be ok for some situation?) (%d:%d)',[b.rid.pid,b.rid.sid]),vAssertion);
    {$ENDIF}
      //Note: we overwrite our copy of b with the in-memory reference (only if we're copying a catalog)
      result:=copyBlobData(st,b,b); //todo use a buffer cache to avoid try..finally etc. here! //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
      justRead:=true; //ensure we free our memory copy
      if result<ok then
        exit; //abort
  end;

  //todo improve: since we use fBlobRec for reading & writing, the dataPtr cannot be used to retain a temp buffer
  (*
  {Have we already allocated the blob buffer?}
  if fBlobRec.dataPtr=nil then
  begin
  *)
    new(fBlobRec.dataPtr);     //allocate blob data buffer //todo ensure dataPtr is not repointed e.g. via heapfile.readRecord
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataCreate);
    {$ENDIF}
  (*
  end;
  *)
  try

    {Now, buffer and add the blob record(s) in reverse segments so we can chain them easily}
    fBlobRec.Wt:=st.Wt; //set Wt to this transaction (not used, but might be handy for garbage collecting?)
    fBlobRec.rType:=rtBlob;
    fBlobRec.prevRID.pid:=InvalidPageId; //=> last in chain
    fBlobRec.prevRID.sid:=InvalidSlotId; //=> last in chain

    source:=pointer(b.rid.pid); //start of blob
    maxBlobSegment:=(BlockSize-sizeof(sHeader){1st header slot is mandatory}-sizeof(sHeader){slot for this blob section}); //largest record per page //todo keep in sync. with HeapFile.addRecord etc.

    sourceOffset:=b.len div maxBlobSegment;      //number of full segments
    sourceOffset:=sourceOffset*maxBlobSegment;   //offset to start of final segment

    sourceCursor:=pchar(source)+sourceOffset;           //move to start of final segment
    sourceCursor:=pchar(sourceCursor)+maxBlobSegment;   //move forward a whole segment purely for ending-on-zero loop logic
    repeat
      sourceCursor:=pchar(sourceCursor)-maxBlobSegment; //move back a whole segment

      if fBlobRec.prevRID.pid=InvalidPageId then
        fBlobRec.len:=b.len-sourceOffset //length of final segment (i.e. last portion of blob, written first)
      else
        fBlobRec.len:=maxBlobSegment;    //length of all other segments

      //todo: should we add column header & offset overhead for flexibility? for now we keep it raw...
      move(sourceCursor^,fBlobRec.dataPtr^[0],fBlobRec.len);

      result:=(owner as TRelation).dbFile.AddRecord(st,fBlobRec,bRid);
      {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('  written blob data segment to disk %d:%d (len=%d, prev=%d:%d) from %p (%s)',[bRid.pid,bRid.sid,fBlobRec.len,fBlobRec.prevRid.pid,fBlobRec.prevRid.sid,sourceCursor,pchar(sourceCursor)]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      {Set the chain reference}
      fBlobRec.prevRID:=bRid;
    until sourceCursor=source;

    //if all went well we return ok and bRid is the location of the first segment
  finally
    //now free our temp write buffer
    dispose(fBlobRec.dataPtr);
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDataDestroy);
    {$ENDIF}

    if justRead then //free the in-memory copy we needed to make
      freeBlobData(b);
  end; {try}
end; {insertBlobData}

function TTuple.deleteBlobData(st:TStmt;b:Tblob):integer;
{Deletes the blob data from the relation
 (used before for updating the tuple)

 IN:        st    - statement needed in case we need to hit the disk
            b     - the blob reference

 assumes: blob is not null

 Returns ok, else fail
          -2 = failed deleting blob record
}
const
  routine=':deleteBlobData';
var
  maxBlobSegment:cardinal;
  thisrecRec:TRec;
  thisRid,prevRid:Trid;
  page:TPage;
begin
  result:=fail;

  if b.rid.sid=InvalidSlotId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format(' Record is an in-memory blob (%d:%d)',[b.rid.pid,b.rid.sid]),vAssertion);
    {$ENDIF}
    result:=fail;
  end;

  thisrecRec:=Trec.create;
  {$IFDEF DEBUGDETAIL3}
  inc(debugRecCreate);
  {$ENDIF}
  try
    //todo would be safer to delete chain in reverse? less chance of orphans?
    // - if so, maybe store last rid in Tblob to allow quick skipping to end of chain?

    thisRid:=b.rid;
    while thisRid.pid<>InvalidPageId do
    begin
      if (Ttransaction(st.owner).db.owner as TDBServer).buffer.pinPage(st,thisRid.pid,page)<>ok then exit;  //get pointer
      try
        if (owner as TRelation).dbFile.ReadRecord(st,page,thisRid.sid,thisrecRec)=ok then
        begin
          prevRid:=thisrecRec.prevRID; //store next data block in the blob chain
          maxBlobSegment:=thisrecRec.len; //store for report

          if thisrecRec.rtype in [rtBlob] then
          begin //delete this record data
            {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('  deleting blob data segment from disk %d:%d (len=%d)',[thisRid.pid,thisRid.sid,thisrecRec.len]),vDebugLow);
            {$ENDIF}
            {$ENDIF}

            //todo ok? or leave alone?
            thisrecRec.Wt:=st.Wt; //set Wt to this transaction (not used? - might be handy for garbage collecting?)

            {$IFNDEF SKIP_BLOB_DELETE}
            {First update the record header to mark as empty}
            thisrecRec.rType:=rtEmpty;
            {Reset this record's previous RID pointer}
            thisrecRec.prevRID.pid:=InvalidPageId;
            thisrecRec.prevRID.sid:=InvalidSlotId;
            result:=((owner as TRelation).dbFile as THeapFile).UpdateRecordHeader(st,thisrecRec,thisRid);

            {Now remove the record data}
            thisrecRec.len:=0; //zap-set length=0 to free page space //todo ok? friendlier way? - not clear!- it resets Wt=0
            result:=((owner as TRelation).dbFile as THeapFile).UpdateRecord(st,thisrecRec,thisRid,True);

            //todo: track whether we do any deletions and if so, call ReorgPage?
            //      also might be nice to first/at-least de-allocate any empty slots at end of slot array...?
            //      - e.g. 50 empty slots take up a lot of space & we might only need 1 in future on this page...
            //      plus increase contiguous space count on page header if we can...
            {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('  deleted blob data segment from disk %d:%d (len=%d, prev=%d:%d)',[thisRid.pid,thisRid.sid,maxBlobSegment,prevRid.pid,prevRid.sid]),vDebugLow);
            {$ENDIF}
            {$ENDIF}

            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format(' Record is not a blob, trying to delete %d:%d',[thisRid.pid,thisRid.sid]),vAssertion); //todo error?
            {$ENDIF}
            result:=-2;
            exit; //reject/abort
          end;

          thisRid:=prevRid; //loop again to delete next data block in the blob chain
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format(' Failed deleting %d:%d',[thisRid.pid,thisRid.sid]),vDebugError);
          {$ENDIF}
          result:=-3;
          exit; //reject/abort
        end;
      finally
        (Ttransaction(st.owner).db.owner as TDBServer).buffer.unPinPage(st,page.block.thisPage);
      end; {try}
    end;

    //if all went well we return ok
  finally
    thisrecRec.free;
    {$IFDEF DEBUGDETAIL3}
    inc(debugRecDestroy);
    {$ENDIF}
  end; {try}
end; {deleteBlobData}

//todo move elsewhere? not really part of Ttuple (but does call Ttuple.getBlobData!), but needs globalDef & stmt etc.
function TTuple.CompareBlob(st:TStmt;bl,br:TBlob;clobInvolved:boolean;var res:shortint):integer;
{Compares the current values of two blobs
 IN:      bl
          br
          clobInvolved          True = one of the blobs is a clob, so compare case-insensitively
                                False = byte for byte comparison
 OUT:     res         result
                            -1  bL<bR
                             0  bL=bR
                            +1  bL>bR

 RESULT:  ok, or fail if error

 Assumes:
   caller deals with nulls before calling
}
var
  blData,brData:Tblob;
  j:cardinal;
begin
  result:=ok;

  res:=0;
  if bl.len>br.len then
    res:=+1
  else
    if bl.len<br.len then res:=-1
    else //we need to read the blob data
    begin
      try
        if copyBlobData(st,bl,blData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                               //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
        begin
          try
            if copyBlobData(st,br,brData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                   //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
            begin
              //todo speed: compare blob hash if not clobInvolved?
              //todo or use compareMem for fast equality check?

              {Compare byte for byte} //todo speed: check 4 bytes at a time via cardinal casting! //todo speed use MMX?
              for j:=0 to bl.len-1 do
              begin
                if clobInvolved then
                begin //case-insensitive
                  if upcase(pchar(blData.rid.pid)[j])>upcase(pchar(brData.rid.pid)[j]) then
                  begin
                    res:=+1;
                    exit; //done
                  end
                  else
                    if upcase(pchar(blData.rid.pid)[j])<upcase(pchar(brData.rid.pid)[j]) then
                    begin
                      res:=-1;
                      exit; //done
                    end;
                    //else check next byte... still equal
                end
                else
                begin //case-sensitive / exact-match
                  if pchar(blData.rid.pid)[j]>pchar(brData.rid.pid)[j] then
                  begin
                    res:=+1;
                    exit; //done
                  end
                  else
                    if pchar(blData.rid.pid)[j]<pchar(brData.rid.pid)[j] then
                    begin
                      res:=-1;
                      exit; //done
                    end;
                    //else check next byte... still equal
                end;
              end;
            end;
          finally
            freeBlobData(brData);
          end; {try}
        end;
      finally
        freeBlobData(blData);
      end; {try}
    end;
end; {CompareBlob}


end.


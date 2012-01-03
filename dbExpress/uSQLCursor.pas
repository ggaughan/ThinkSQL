{$DEFINE DEBUG_DETAIL}

{$IFNDEF DBEXP_STATIC}
unit uSQLCursor;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses DBXpress,
     uSQLCommand,
     uGlobalDB,
     DB;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

type
  TSQLCursor=class(TInterfacedObject,ISQLCursor)
  private
    SQLCommand:TSQLCommand;
    SQLCommandRef:ISQLCommand; //purely used to keep ref. count in order

    (*todo remove: we now have a buffer per column so we can bind as we need
    cursorBuf:pUCHAR;
    cursorsdw:SDWORD;
    cursorNull:SQLSMALLINT;
    *)

    errorMessage:string;
    procedure logError(s:string);

    function readRaw(ColumnNumber: Word): SQLResult; //todo no need: stdcall;
  public
    constructor Create(c:TSQLCommand);
    destructor Destroy; override;

    function SetOption(eOption: TSQLCursorOption;
                     PropValue: LongInt): SQLResult; stdcall;
    function GetOption(eOption: TSQLCursorOption; PropValue: Pointer;
                     MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
    function getErrorMessage(Error: PChar): SQLResult; overload; stdcall;
    function getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
    function getColumnCount(var pColumns: Word): SQLResult; stdcall;
    function getColumnNameLength(
      ColumnNumber: Word;
      var pLen: Word): SQLResult; stdcall;
    function getColumnName(ColumnNumber: Word; pColumnName: PChar): SQLResult; stdcall;
    function getColumnType(ColumnNumber: Word; var puType: Word;
      var puSubType: Word): SQLResult; stdcall;
    function  getColumnLength(ColumnNumber: Word; var pLength: LongWord): SQLResult; stdcall;
    function getColumnPrecision(ColumnNumber: Word;
      var piPrecision: SmallInt): SQLResult; stdcall;
    function getColumnScale(ColumnNumber: Word; var piScale: SmallInt): SQLResult; stdcall;
    function isNullable(ColumnNumber: Word; var Nullable: LongBool): SQLResult; stdcall;
    function isAutoIncrement(ColumnNumber: Word; var AutoIncr: LongBool): SQLResult; stdcall;
    function isReadOnly(ColumnNumber: Word; var ReadOnly: LongBool): SQLResult; stdcall;
    function isSearchable(ColumnNumber: Word; var Searchable: LongBool): SQLResult; stdcall;
    function isBlobSizeExact(ColumnNumber: Word; var IsExact: LongBool): SQLResult; stdcall;
    function next: SQLResult; stdcall;
    function getString(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getShort(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getLong(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getDouble(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getBcd(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getTimeStamp(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getTime(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getDate(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getBytes(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getBlobSize(ColumnNumber: Word; var Length: LongWord;
      var IsBlank: LongBool): SQLResult; stdcall;
    function getBlob(ColumnNumber: Word; Value: Pointer;
      var IsBlank: LongBool; Length: LongWord): SQLResult; stdcall;
  end; {TSQLCursor}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}

implementation

uses uLog,
     SysUtils,
     uMarshalGlobal,
     uMarshal,
     FmtBCD, Math{for power},
     SQLTimSt;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
constructor TSQLCursor.Create(c:TSQLCommand);
begin
  inherited create;

  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.create called (%d) for command (%d)',[longint(self),longint(c)]),vLow);
  {$ENDIF}

  SQLCommand:=c;
  SQLCommandRef:=c;
end; {create}

destructor TSQLCursor.Destroy;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.Destroy called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  if assigned(SQLCommand) then
    SQLCommand.SQLCloseCursor;

  inherited;
end; {destroy}

procedure TSQLCursor.logError(s:string);
begin
  errorMessage:=s;
end; {logError}


function TSQLCursor.SetOption(eOption: TSQLCursorOption;
                 PropValue: LongInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.SetOption called %d %d',[ord(eOption),PropValue]),vLow);
  {$ENDIF}

  result:=SQL_SUCCESS;
  result:=DBXERR_NOTSUPPORTED; //todo remove!!!
end; {SetOption}

function TSQLCursor.GetOption(eOption: TSQLCursorOption; PropValue: Pointer;
                 MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.GetOption called %d %d',[ord(eOption),MaxLength]),vLow);
  {$ENDIF}

  Length:=0;

  result:=SQL_SUCCESS;
  result:=DBXERR_NOTSUPPORTED; //todo remove!!!
end; {GetOption}

function TSQLCursor.getErrorMessage(Error: PChar): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getErrorMessage called',vLow);
  {$ENDIF}

  strLCopy(Error,pchar(errorMessage),length(errorMessage));

  result:=SQL_SUCCESS;
end; {getErrorMessage}

function TSQLCursor.getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getErrorMessageLen called',vLow);
  {$ENDIF}

  ErrorLen:=length(errorMessage);

  result:=SQL_SUCCESS;
end; {getErrorMessageLen}

function TSQLCursor.getColumnCount(var pColumns: Word): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.getColumnCount called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  if assigned(SQLCommand) then
    pColumns:=SQLCommand.colCount
  else
    pColumns:=0; //handle missing parent for metaData stub-tests

  result:=SQL_SUCCESS;
end; {getColumnCount}

function TSQLCursor.getColumnNameLength(
  ColumnNumber: Word;
  var pLen: Word): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.getColumnNameLength called (%d) %d',[longint(self),ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    pLen:=length(SQLCommand.col[ColumnNumber].desc.szName); //todo too big!?
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnNameLength}

function TSQLCursor.getColumnName(ColumnNumber: Word; pColumnName: PChar): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.getColumnName called (%d) %d',[longint(self),ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}
  if ColumnNumber<=SQLCommand.colCount then
  begin
    strLCopy(pColumnName,SQLCommand.col[ColumnNumber].desc.szName,length(SQLCommand.col[ColumnNumber].desc.szName));
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnName}

function TSQLCursor.getColumnType(ColumnNumber: Word; var puType: Word;
  var puSubType: Word): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.getColumnType called (%d) %d',[longint(self),ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    puType:=SQLCommand.col[ColumnNumber].desc.iFldType;
    puSubType:=SQLCommand.col[ColumnNumber].desc.iSubType;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCursor.getColumnType returns %d %d',[puType,puSubType]),vLow);
    {$ENDIF}
    {$ENDIF}
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnType}

function TSQLCursor.getColumnLength(ColumnNumber: Word; var pLength: LongWord): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.getColumnLength called (%d) %d',[longint(self),ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    pLength:=SQLCommand.col[ColumnNumber].desc.iLen; //todo always ok? what if prec=0?! what if not read row yet?
    //todo HERE!remove:
    pLength:=longWord(SQLCommand.col[ColumnNumber].desc.iUnits1); //todo always ok? what if prec=0?! what if not read row yet?
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCursor.getColumnLength returns %d',[pLength]),vLow);
    {$ENDIF}
    {$ENDIF}
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnLength}

function TSQLCursor.getColumnPrecision(ColumnNumber: Word;
  var piPrecision: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getColumnPrecision called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    piPrecision:=SQLCommand.col[ColumnNumber].desc.iUnits1;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCursor.getColumnPrecision returns %d',[piPrecision]),vLow);
    {$ENDIF}
    {$ENDIF}
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnPrecision}

function TSQLCursor.getColumnScale(ColumnNumber: Word; var piScale: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getColumnScale called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    piScale:=SQLCommand.col[ColumnNumber].desc.iUnits2;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCursor.getColumnScale returns %d',[piScale]),vLow);
    {$ENDIF}
    {$ENDIF}
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getColumnScale}

function TSQLCursor.isNullable(ColumnNumber: Word; var Nullable: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('isNullable called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    Nullable:=LongBool(SQLCommand.col[ColumnNumber].desc.iNullOffset);
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {isNullable}

function TSQLCursor.isAutoIncrement(ColumnNumber: Word; var AutoIncr: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('isAutoIncrement called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    AutoIncr:=FALSE; //todo could be true in future
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {isAutoIncrement}

function TSQLCursor.isReadOnly(ColumnNumber: Word; var ReadOnly: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('isReadOnly called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    ReadOnly:=FALSE; //todo could be true in future
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {isReadOnly}

function TSQLCursor.isSearchable(ColumnNumber: Word; var Searchable: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('isSearchable called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    Searchable:=TRUE; //todo could be false in future
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {isSearchable}

function TSQLCursor.isBlobSizeExact(ColumnNumber: Word; var IsExact: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('isBlobSizeExact called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    IsExact:=TRUE; 
    result:=SQL_SUCCESS;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {isBlobSizeExact}

function TSQLCursor.next: SQLResult; stdcall;
var
  err:integer;

  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  rowStatusExtra:SQLSMALLINT;      //conversion error/warning in row
  colStatusExtra:SQLSMALLINT;      //conversion error/warning in column
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  //todo remove dataPtr:SQLPOINTER;
  //todo remove lenPtr:pSQLINTEGER;
  //todo remove  statusPtr:pSQLUSMALLINT;

  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;

  tempsdw:SDWORD;
  tempNull:SQLSMALLINT;

  offsetSize:SQLINTEGER;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCursor.next called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  //todo remove getMem(dataPtr,MAX_ROW_SIZE);
  //todo remove try

  if assigned(SQLCommand) then
  begin
    {call server fetchScroll}
    //todo Replace all AS with casts - speed
    with SQLCommand.SQLConnection.Marshal do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      putFunction(SQL_API_SQLFETCHSCROLL);
      putSQLHSTMT(SQLCommand.ServerStatementHandle); //pass server statement ref
      putSQLSMALLINT(SQL_FETCH_NEXT);
      putSQLINTEGER(0); //todo check not used for fetch_next!
      if Send<>ok then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;

      {Wait for response}
      if Read<>ok then
      begin
        result:=SQL_ERROR2;
        logError(ssHYT00);
        exit;
      end;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      }
      getFunction(functionId);
      if functionId<>SQL_API_SQLFETCHSCROLL then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;
      //resultCode comes later
      {retrieve any result data}

      {Read row count}
      getSQLUINTEGER(rowCount);
      //todo? check rowCount=array_size - no reason why not... could assume? - but dangerous
      {Initialise the count of non-empty rows in the application's buffer}
      //if s.ard.desc_rows_processed_ptr<>nil then
      //  pSQLuINTEGER(s.ard.desc_rows_processed_ptr)^:=0; //we increment this each time we get a 'real' result row
      //might be slightly quicker (less safe) to set to rowCount now & decrement if we get an empty row - speed?

      //todo: note pSQLINTEGER(intPtr)^:=x is safer than SQLINTEGER(intPtr^):=x
      // - check this is true & if so make sure we use this everywhere!

      {$IFDEF DEBUG_LOG}
      log(format('SQLFetchScroll returns %d rows',[rowCount]),vLow);
      {$ENDIF}

      //if s.ard.desc_bind_offset_ptr<>nil then
      //  offsetSize:=SQLINTEGER(s.ard.desc_bind_offset_ptr^) //get deferred value
      //else
        offsetSize:=0; //todo assert rowCount/array_size = 1 - else where do we put the data!!!!

      {$IFDEF DEBUG_LOG}
      //log(format('SQLFetchScroll bind offset size=%d',[offsetSize]));
      {$ENDIF}

      setStatusExtra:=0; //no conversion errors

      for row:=1 to rowCount do
      begin
        {Now get the col count & data for this row}
        getSQLINTEGER(colCount);
        {$IFDEF DEBUG_LOG}
        log(format('SQLFetchScroll returns %d column data',[colCount]),vLow);
        {$ENDIF}
        //todo assert s.ard.desc_count<=colCount ?
        //todo now use get with result checking!!!

        rowStatusExtra:=0; //no conversion errors
        rn:=0; //initialise in case 0 columns - i.e. DBXpress with no pre-binding
        //todo remove! inc(colCount); //assume 0 based count... todo remove? debug

        //zeroise col[] buffers now to avoid risk of old data being read
        //(risk is either by null=true seeing data or by not getting same columns each row
        // although we only increase the bindings so we should be safe to free per column) //todo speed
        for i:=0 to colCount-1 do
        begin
          {Free any previous data buffer}
          with SQLCommand.col[i+1] do
          begin
            isNull:=false;
            if buffer<>nil then
            begin
              {$IFDEF DEBUG_DETAIL}
              {$IFDEF DEBUG_LOG}
              log(format('freeing column %d buffer: %d bytes of data',[i+1,bufferLen]),vLow);
              {$ENDIF}
              {$ENDIF}
              freeMem(buffer);
              buffer:=nil;
              bufferLen:=0;
            end;
          end; {with}
        end;

        i:=0;
        while i<=colCount-1 do
        begin
          //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
          if getSQLSMALLINT(rn)<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;
          if rn<=High(SQLCommand.col) then
          begin
            //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
            with SQLCommand.col[rn] do
            begin
              {Get the null flag}
              if getSQLSMALLINT(tempNull)<>ok then
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              isNull:=(tempNull=SQL_TRUE);
              
              if isNull then
              begin
                bufferLen:=0; //we only zeroise this for the debug message below - todo remove: speed
              end
              else
              begin
                //Note: we only get length+data if not null
                  //note: we don't add \0 here
                  if getpDataSDWORD(buffer,DYNAMIC_ALLOCATION,bufferLen)<>ok then
                  begin
                    result:=SQL_ERROR2;
                    logError(ss08S01);
                    exit;
                  end;
              end;


              (*todo re-instate this code when we need speed!

              //todo use a get routine that doesn't add \0 = waste of space at such a raw level?
              //todo check casts are ok
              //todo assert desc_data_ptr<>nil! surely not every time!?
              {Get the data}
              //we need to store pointer in a temp var cos we need to pass as var next (only because routine needs to allow Dynamic allocation - use 2 routines = speed)
              //elementSize may not be original desc_octet_length if fixed-length data-type, but bindCol fixes it for us
              if s.ard.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* desc_octet_length))
              else //row-wise
                dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* s.ard.desc_bind_type));

              //todo convert from server to c type (i.e. from IRD to ARD) ******
              // - note do before we modify client's buffer area - may be too small!
              if s.ird.getRecord(rn,Idr,True)<>ok then
              begin
                //error, skip this column: need to consume the rest of this column definition anyway -> sink
                //todo or, could abort the whole routine instead?
                //note: currently getRecord cannot fail!
                {$IFDEF DEBUGDETAIL}
                log(format('SQLFetchScroll failed getting IRD desc record %d - rest of column data abandoned...',[rn])); //todo debug error only - remove
                {$ENDIF}
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit; //todo: just for now!
              end;

              {Get the null flag}
              if getSQLSMALLINT(tempNull)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              if tempNull=SQL_TRUE then
              begin
                if desc_indicator_pointer<>nil then
                begin
                  if s.ard.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                    lenPtr:=pSQLINTEGER(longint(desc_indicator_pointer)+offsetSize+( (row-1)* sizeof(SQLINTEGER)))
                  else //row-wise
                    lenPtr:=pSQLINTEGER(longint(desc_indicator_pointer)+offsetSize+( (row-1)* s.ard.desc_bind_type));

                  SQLINTEGER(lenPtr^):=SQL_NULL_DATA
                end
                else
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss22002,fail,'',row,rn); //todo check result
                  exit; //todo continue with next row!
                end;
                tempsdw:=0; //we only zeroise this for the debug message below - todo remove: speed
              end
              else
              begin
                //Note: we only get length+data if not null
                //note: SQL_C_DEFAULT could be dangerous - we assume user knows what they're doing!
                if not isBinaryCompatible(desc_concise_type,Idr.desc_concise_type) then
                begin //conversion required
                  {We read the 1st part, the length, of the field}
                  if getSDWORD(tempsdw)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  {Remember any result (error or warning) to add to rowStatus returned from server}
                  colStatusExtra:=getAndConvert(desc_concise_type,Idr, dataPtr,desc_octet_length,
                                  (s.owner as Tdbc).Marshal,tempsdw, s.diagnostic,row,rn);
                  if colStatusExtra<>ok then
                    if rowStatusExtra=0 then
                      rowStatusExtra:=colStatusExtra; //note: we only retain the 1st warning or error (todo check ok with standard)
                                                      //(although multiple diagnostic error may have been stacked)

                  //todo ensure that if a fixed-size result is null, the get in getandconvert doesn't read too much!!!
                  //********* i.e. server should always return a int/float value even if null
                  //          or we should read null flag first before reading data
                  //          or getandconvert should not get if tempsdw=0 is passed!
                  //     Note: we do the 3rd option - check works ok...

                  //todo check no need: marshal.skip(tempsdw); //just read by another routine!
                end
                else
                begin //no conversion required
                  //note: we don't add \0 here
                  if getpDataSDWORD(dataPtr,desc_octet_length,tempsdw)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                end;

                //todo: maybe this should be outside this else:
                //  do we set the length if we got null???? check spec.!
                // - the len + null flag are usually the same thing!
                // so I suppose if they're not, we should set the length???? or not????!

                {Set the length to tempsdw - may have been modified by conversion routines}
                //todo maybe don't set the desc_octet_length_pointer if null will be set below?
                if desc_octet_length_pointer<>nil then
                begin
                  if s.ard.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                    lenPtr:=pSQLINTEGER(longint(desc_octet_length_pointer)+offsetSize+( (row-1)* sizeof(SQLINTEGER)))
                  else //row-wise
                    lenPtr:=pSQLINTEGER(longint(desc_octet_length_pointer)+offsetSize+( (row-1)* s.ard.desc_bind_type));

                  SQLINTEGER(lenPtr^):=tempsdw;
                end;
              end;
            *)

              {$IFDEF DEBUG_LOG}
              log(format('next read past column %d data: %d bytes, null=%d',[rn,bufferLen,ord(isNull)]),vLow); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
              {$ENDIF}
            end; {with}
          end
          else
          begin
            //error, skip this column: need to consume the rest of this column definition anyway -> sink
            //todo or, could abort the whole routine instead?
            //note: currently getRecord cannot fail!
            {$IFDEF DEBUG_LOG}
            log(format('next failed getting record %d - rest of column data abandoned...',[rn]),vLow); //todo debug error only - remove
            {$ENDIF}
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit; //todo: just for now!
          end;

          inc(i);
        end; {while}
        {get row status}
        getSQLUSMALLINT(sqlRowStatus);
        {$IFDEF DEBUG_LOG}
        log(format('next read past row status %d: %d',[rn,sqlRowStatus]),vLow); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
        {$ENDIF}
        {If there was a conversion error, then we set the SQLrowStatus to it
         todo - check ok with standard!}
        if rowStatusExtra<>0 then
        begin
          sqlRowStatus:=rowStatusExtra; //todo: maybe we should only if sqlRowStatus is 'OK'?
          if setStatusExtra=0 then
            setStatusExtra:=rowStatusExtra;
        end;
        //if s.ard.desc_array_status_ptr<>nil then
        //begin
          //todo remove & statusPtr var: statusPtr:=pSQLUSMALLINT(longint(desc_array_status_ptr)+( (row-1)* sizeof(SQLUSMALLINT)))
        //  SQLUSMALLINT(pSQLUSMALLINT(longint(s.ard.desc_array_status_ptr)+( (row-1)* sizeof(SQLUSMALLINT)))^):=sqlRowStatus;
        //end;
        {Add to the count of non-empty rows in the application's buffer}
        //if sqlRowStatus<>SQL_ROW_NOROW then
        //  if s.ard.desc_rows_processed_ptr<>nil then
        //    inc(pSQLuINTEGER(s.ard.desc_rows_processed_ptr)^); //we increment this each time we get a 'real' result row
      end; {for row}

      getRETCODE(resultCode);
      //todo we should set to SQL_SUCCESS_WITH_INFO if any rowStatus just had a problem - i.e a conversion problem
      // since server wouldn't have known...

      //todo remove result:=resultCode; //pass it on //todo need to pass EOF properly for DBX!!!!
      {$IFDEF DEBUG_LOG}
      log(format('next returns %d',[resultCode]),vLow);
      {$ENDIF}
      {Translate result}
      case resultCode of
        SQL_NO_DATA: result:=DBXERR_EOF;
        SQL_ERROR: result:=SQL_ERROR2;
      else
        result:=SQL_SUCCESS; //DBX ignores warnings etc.
      end; {case}
      {$IFDEF DEBUG_LOG}
      log(format('next actually returns %d',[result]),vLow);
      {$ENDIF}

      {if error, then get error details: local-number, default-text}
      if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
      if resultCode=SQL_ERROR then
      begin
        for err:=1 to resultErrCode do
        begin
          if getSQLINTEGER(resultErrCode)<>ok then exit;
          if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
          case resultErrCode of
            seInvalidHandle:         result:=DBXERR_INVALIDHNDL;
            seNotPrepared:           result:=SQL_ERROR2;
            seNoResultSet:           result:=SQL_ERROR2;
            seDivisionByZero:        result:=SQL_ERROR2;
          else
            result:=SQL_ERROR2;
          end; {case}
          logError(resultErrText);
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
      end;

      {If server returned SQL_SUCCESS, but we just encountered a conversion warning/error
       then modify the result code to SQL_SUCCESS_WITH_INFO as per ODBC spec.}
      //if setStatusExtra<>0 then
      //  if resultCode=SQL_SUCCESS then
      //    resultCode:=SQL_SUCCESS_WITH_INFO;

      (*todo remove N/A to DBX
      case resultCode of
        SQL_SUCCESS, SQL_SUCCESS_WITH_INFO, SQL_NO_DATA:
        begin
          if s.state=S5 then
            s.state:=S6;
        end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
        SQL_STILL_EXECUTING:
        begin
          s.state:=S11;
        end; {SQL_STILL_EXECUTING}
      else
        //todo what if SQL_ERROR?
        //(else) should never happen!? - it can if 1 row returned & it was an error row... //todo
      end; {case}
      *)

      (*todo remove: debug rubbish
      {Since DBX cursors can be detached from their commands, i.e. metaData results
       we should closeCursor here, e.g. in case cursor is left open & another command is performed & cursor is then re-executed}
      if result=DBXERR_EOF then
      begin
        {$IFDEF DEBUG_LOG}
        log(format('next eof will close cursor now',[nil]),vLow);
        {$ENDIF}
        if assigned(SQLCommand) then
          SQLCommand.SQLCloseCursor;
      end;
      *)
    end; {with}
  end
  else
    result:=DBXERR_EOF; //handle missing parent for metaData stub-tests

  //todo HERE:remove!
  //result:=DBXERR_NOTSUPPORTED;

  //todo remove finally
  //todo remove   freemem(dataptr);
  //todo remove end; {try}
end; {next}

function TSQLCursor.readRaw(ColumnNumber: Word): SQLResult; //todo no need: stdcall;
{Support function for getX routines
 //todo remove old: Reads data into cursorBuf,cursorsdw,cursorNull
  Reads data into col[].buffer,.bufferLen,.bufferisNull

  If this column is not bound already, then the data is retrieved now and the server is told to bind it
  (so future fetches will bring back all the required column data for the row = network speed)
  Note: the first row of each query will be unbound (since dbExpress has no user-binding) 
}
var
  err:integer;

  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;
  tempsw:SWORD;
  tempNull:SQLSMALLINT;

begin
  {$IFDEF DEBUG_LOG}
  //log('readRaw called',vLow);
  {$ENDIF}

  {$IFDEF DEBUG_LOG}
  //todo remove old: if cursorBuf<>nil then log('readRaw cursorBuf<>nil',vAssertion);
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    if (SQLCommand.col[ColumnNumber].buffer<>nil) or SQLCommand.col[ColumnNumber].isNull then
    begin //we already have the data in the right place so just return: column must have been bound before
      result:=SQL_SUCCESS;
    end
    else
    begin //pull the data from the server now and then bind the column to avoid future calls
      {call server getData}
      //todo Replace all AS with casts - speed
      with SQLCommand.SQLConnection.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLGETDATA);
        putSQLHSTMT(SQLCommand.ServerStatementHandle); //pass server statement ref
        putSQLSMALLINT(ColumnNumber);
        if SQLCommand.SQLConnection.serverCLIversion>=0093 then
        begin //restrict result to client buffer size chunks: expect client to repeatedly call this routine
          //todo assert BufferLength<marshalBufSize-sizeof(bufferLen)!!!!!!!!!!
          //- todo else we'd be responsible for using our smaller buffer size to fill the clients
          //-      maybe we should do this & it will be fine because client gets told what's left & status code...
          (*todo remove: no need here now?
          if BufferLength>(marshalBufSize-sizeof(bufferLen)) then
          begin
            {$IFDEF DEBUG_LOG}
            log(format('SQLGetData buffer of %d is being reduced to %d to suit marshal buffer',[BufferLength,(marshalBufSize-sizeof(bufferLen))]),vLow);
            {$ENDIF}
            BufferLength:=(marshalBufSize-sizeof(bufferLen)); //todo check fits ok!
          end;
          BufferLen:=BufferLength; //cast
          *)
          putSQLUINTEGER(4294967294); //todo replace with const
        end;
        if Send<>ok then
        begin
          result:=SQL_ERROR2;
          logError(ss08S01);
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR2;
          logError(ssHYT00);
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLGETDATA then
        begin
          result:=SQL_ERROR2;
          logError(ss08S01);
          exit;
        end;
        //resultCode comes later
        {retrieve any result data}

        {Read row count}
        getSQLUINTEGER(rowCount);
        //todo? assert rowCount=1 - only here to keep similar protocol as fetchScroll (& maybe future use)

        {$IFDEF DEBUG_LOG}
        //log(format('SQLGetData returns %d rows',[rowCount]),vDebug);
        {$ENDIF}

        setStatusExtra:=0; //no conversion errors

        for row:=1 to rowCount do //todo remove- not needed, but no harm either...
        begin
          {Now get the col count & data for this row}
          getSQLINTEGER(colCount);
          //todo? again assert colCount=1 - only here to keep similar protocol as fetchScroll (& maybe future use)
          {$IFDEF DEBUG_LOG}
          //log(format('SQLGetData returns %d column data',[colCount]),VDebug);
          {$ENDIF}
          //todo now use get with result checking!!!

          i:=0;
          while i<=colCount-1 do //todo remove- not needed, but no harm either...
          begin
            //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
            if getSQLSMALLINT(rn)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;

            //todo assert than rn=ColumnNumber that we just sent!
            {$IFDEF DEBUG_LOG}
            //log(format('SQLGetData reading returned column %d (should be =%d)',[rn,ColumnNumber]),vDebug); //todo debug only - remove!
            {$ENDIF}

            //todo use a get routine that doesn't add \0 = waste of space at such a raw level?
            //todo check casts are ok
            //todo assert TargetValue<>nil!
            {Get the data}
            //we need to store pointer in a temp var cos we need to pass as var next (only because routine needs to allow Dynamic allocation - use 2 routines = speed)
            //todo remove: dataPtr:=Value;

            //todo convert from server to c type (i.e. from IRD to ARD) ******
            // - note do before we modify client's buffer area - may be too small!
            if rn>High(SQLCommand.col) then //todo safer to check if rn<>iFldNum?
            begin
              //error, skip this column: need to consume the rest of this column definition anyway -> sink
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUG_LOG}
              log(format('SQLGetData failed getting record %d - rest of column data abandoned...',[rn]),vLow); //todo debug error only - remove
              {$ENDIF}
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit; //todo: just for now!
            end;

            {Get the null flag}
            if getSQLSMALLINT(tempNull)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            SQLCommand.col[rn].isNull:=(tempNull=SQL_TRUE);

            if SQLCommand.col[rn].isNull then
            begin
              SQLCommand.col[rn].bufferLen:=0; //we only zeroise this for the debug message below - todo remove: speed
            end
            else
            begin
              //Note: we only get length+data if not null
              (*todo remove: we ca assume the type
              //note: SQL_C_DEFAULT could be dangerous - we assume user knows what they're doing!
              if not isBinaryCompatible(TargetType,Idr.desc_concise_type) then
              begin //conversion required
                {We read the 1st part, the length, of the field}
                if getSDWORD(tempsdw)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                {Remember any result (error or warning) to add to setStatusExtra returned from server
                 Note: we assume we only deal with 1 row x 1 column here, i.e. we overwrite the setStatusExtra}
                setStatusExtra:=getAndConvert(TargetType,Idr, dataPtr,BufferLength,
                                (s.owner as Tdbc).Marshal,tempsdw, s.diagnostic,row,rn);

                //todo ensure that if a fixed-size result is null, the get in getandconvert doesn't read too much!!!
                //********* i.e. server should always return a int/float value even if null
                //          or we should read null flag first before reading data
                //          or getandconvert should not get if tempsdw=0 is passed!
                //     Note: we do the 3rd option - check works ok...

                //todo check no need: marshal.skip(tempsdw); //just read by another routine!
              end
              else
              *)
              begin //no conversion required
                if getpDataSDWORD(SQLCommand.col[rn].buffer,DYNAMIC_ALLOCATION,SQLCommand.col[rn].bufferLen)<>ok then
                begin
                  result:=SQL_ERROR2;
                  logError(ss08S01);
                  exit;
                end;
              end;

              (*todo remove
              //todo: maybe this should be outside this else:
              //  do we set the length if we got null???? check spec.!
              // - the len + null flag are usually the same thing!
              // so I suppose if they're not, we should set the length???? or not????!

              {Set the length to tempsdw - may have been modified by conversion routines}
              //todo maybe don't set the StrLen_or_Ind if null will be set below?
              if StrLen_or_Ind<>nil then
              begin
                SQLINTEGER(StrLen_or_Ind^):=tempsdw;
              end;
              *)
            end;

            {$IFDEF DEBUG_LOG}
            log(format('SQLGetData read column %d data: %d bytes, null=%d',[rn,SQLCommand.col[rn].bufferLen,ord(SQLCommand.col[rn].isnull)]),vLow); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
            {$ENDIF}

            inc(i);
          end; {while}
          {get row status}
          getSQLUSMALLINT(sqlRowStatus);  //again, only here to keep similar protocol as fetchScroll (& maybe future use)
          {$IFDEF DEBUG_LOG}
          //log(format('SQLGetData read row status %d: %d',[rn,sqlRowStatus]),vDebug); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
          {$ENDIF}
          {If there was an overall conversion error, then we set the setStatusExtra to it
           todo - check ok with standard!}
          if setStatusExtra=0 then
            setStatusExtra:=sqlRowStatus;
        end; {for row}

        getRETCODE(resultCode);
        //todo we should set to SQL_SUCCESS_WITH_INFO if any rowStatus just had a problem - i.e a conversion problem
        // since server wouldn't have known...
        //todo remove result:=resultCode; //pass it on //todo fix first for DBX
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log(format('SQLGetData returns %d',[resultCode]),vLow);
        {$ENDIF}
        {$ENDIF}
        {Translate result}
        case resultCode of
          SQL_ERROR: result:=SQL_ERROR2;
        else
          result:=SQL_SUCCESS; //DBX ignores warnings etc.
        end; {case}

        {if error, then get error details: local-number, default-text}
        if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
        if resultCode=SQL_ERROR then
        begin
          for err:=1 to resultErrCode do
          begin
            if getSQLINTEGER(resultErrCode)<>ok then exit;
            if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
            case resultErrCode of
              seInvalidHandle:         result:=DBXERR_INVALIDHNDL;
              seNotPrepared:           result:=SQL_ERROR2;
              seNoResultSet:           result:=SQL_ERROR2;
            else
              result:=SQL_ERROR2;
            end; {case}
            logError(resultErrText);
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;

        {Bind this column now, so future fetches will return it as part of the returned row}
        //todo avoid this line if type=blob, i.e. don't assume wasted overhead for each row... better to call raw each time?
        SQLCommand.SQLSetDescField(ColumnNumber,SQL_DESC_DATA_POINTER,SQLPOINTER(01),00); //todo check result 


        (*todo remove
        {If server returned SQL_SUCCESS, but we just encountered a conversion warning/error
         then modify the result code to SQL_SUCCESS_WITH_INFO as per ODBC spec.}
        if setStatusExtra<>0 then
          if resultCode=SQL_SUCCESS then
            resultCode:=SQL_SUCCESS_WITH_INFO;

        case resultCode of
          SQL_SUCCESS, SQL_SUCCESS_WITH_INFO, SQL_NO_DATA:
          begin
            //state stays same
            //todo unless [x] [b] or [i] - see spec.
          end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
          SQL_STILL_EXECUTING:
          begin
            s.state:=S11;
          end; {SQL_STILL_EXECUTING}
        else
          //todo what if SQL_ERROR?
          //(else) should never happen!? - it can if 1 row returned & it was an error row... //todo
        end; {case}
        *)
      end; {with}

      result:=SQL_SUCCESS;
    end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {readRaw}


function TSQLCursor.getString(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('getString called %d',[ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          //returnString(pUCHAR(SQLCommand.col[ColumnNumber].buffer),Value,SQLCommand.col[ColumnNumber].bufferLen+1);
          move(SQLCommand.col[ColumnNumber].buffer^,Value^,SQLCommand.col[ColumnNumber].bufferLen); //todo safe?
          move(nullchar,(pchar(Value)+SQLCommand.col[ColumnNumber].bufferLen)^,sizeof(nullchar)); //todo safe?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getstring returns %s',[pchar(Value)]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getString}

function TSQLCursor.getShort(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getShort called',vLow);
  {$ENDIF}
  {$ENDIF}

  result:=DBXERR_NOTSUPPORTED; //n/a
end; {getShort}

function TSQLCursor.getLong(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getLong called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,Value^,sizeof(integer)); //todo safe?
          //todo remove: wrong! returnNumber(strToIntDef(cursorBuf^,0),Value,sizeof(integer));
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getLong returns %d',[integer(Value^)]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getLong}

function TSQLCursor.getDouble(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getDouble called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,Value^,sizeof(double)); //todo safe?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          if not IsBlank then log(format('getDouble returns %f',[double(Value^)]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getDouble}

function TSQLCursor.getBcd(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
var
  c:comp;
  bcd,bcd2:Tbcd;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getBcd called',vLow);
  log(format('  prec=%d scale=%d',[SQLCommand.col[ColumnNumber].desc.iUnits1,SQLCommand.col[ColumnNumber].desc.iUnits2]),vLow);

  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,c,sizeof(comp));  //todo safe?
          {Adjust the scale}
          bcd:=doubleToBCD(c/power(10,SQLCommand.col[ColumnNumber].desc.iUnits2)); //i.e. shift scale decimal places to the right
          {$IFDEF DEBUG_LOG}
          //log(format('getBcd working with %s before normalize',[bcdToStr(bcd)]),vDebug);
          {$ENDIF}
          //todo remove if not currToBCD(compToCurrency(c),bcd,SQLCommand.col[ColumnNumber].iUnits1,SQLCommand.col[ColumnNumber].iUnits2) then
          if not NormalizeBCD(bcd,bcd2,SQLCommand.col[ColumnNumber].desc.iUnits1,SQLCommand.col[ColumnNumber].desc.iUnits2) then
          begin
            {Fix: 16/07/03: should give truncation warning instead
            result:=DBXERR_INVALIDPRECISION; //todo ok?
            exit;}
          end;
          {$IFDEF DEBUG_LOG}
          //log(format('getBcd working with %s after normalize',[bcdToStr(bcd2)]),vDebug);
          {$ENDIF}
          move(bcd2,Value^,sizeof(bcd2)); //todo safe? //todo fix! length reported won't be big enough? Is client clever enough to allocate/pass BCD structure?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getBcd returns %s',[bcdToStr(TBCD(Value^))]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getBcd}

function TSQLCursor.getTimeStamp(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
var
  tsFrom:{$IFNDEF DBEXP_STATIC}uMarshalGlobal.{$ENDIF}TSQLtimeStamp;
  tsTo:SQLTimSt.TSQLtimeStamp;
  sec:double;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getTimeStamp called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,tsFrom,sizeof(tsFrom));  //todo safe?
          tsTo.Year:=tsFrom.date.year;
          tsTo.Month:=tsFrom.date.month;
          tsTo.Day:=tsFrom.date.day;
          tsTo.Hour:=tsFrom.time.hour;
          tsTo.Minute:=tsFrom.time.minute;
          {Denormalise seconds}
          sec:=tsFrom.time.second/power(10,TIME_MAX_SCALE); //i.e. shift TIME_MAX_SCALE decimal places to the right
          tsTo.Second:=trunc(int(sec));
          tsTo.Fractions:=round(frac(sec)*power(10,DBX_TIME_FRACTION_SCALE));

          move(tsTo,Value^,sizeof(tsTo)); //todo safe? //todo fix! length reported won't be big enough? Is client clever enough to allocate/pass BCD structure?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getTimestamp returns %s',[SQLTimSt.SQLTimeStampToStr('ddddd hh:nn:ss.zzz',SQLTimSt.TSQLtimeStamp(Value^))]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getTimeStamp}

function TSQLCursor.getTime(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
var
  tFrom:{$IFNDEF DBEXP_STATIC}uMarshalGlobal.{$ENDIF}TsqlTime;
  t:TDateTime;
  sec:double;
  ts:TTimeStamp;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getTime called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,tFrom,sizeof(tFrom));  //todo safe?
          {Denormalise seconds}
          sec:=tFrom.second/power(10,TIME_MAX_SCALE); //i.e. shift TIME_MAX_SCALE decimal places to the right
          t:=encodeTime(tFrom.hour,tFrom.minute,trunc(int(sec)),round(frac(sec)*power(10,DBX_TIME_FRACTION_SCALE)));
          ts:=DateTimeToTimeStamp(t);
          move(ts.time,Value^,sizeof(ts.time)); //todo safe? //todo fix! length reported won't be big enough? Is client clever enough to allocate/pass BCD structure?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          //log(formatDateTime('"getTime returns "hh:nn:ss.zzz',TDateTime(Value^)),vLow);
          log(format('getTime returns %d',[longint(Value^)]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getTime}

function TSQLCursor.getDate(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
var
  dFrom:{$IFNDEF DBEXP_STATIC}uMarshalGlobal.{$ENDIF}TsqlDate;
  d:TDateTime;
  ts:TTimeStamp;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getDate called',vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          move(SQLCommand.col[ColumnNumber].buffer^,dFrom,sizeof(dFrom));  //todo safe?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getDate working with %d %d %d',[dFrom.year,dFrom.month,dFrom.day]),vLow);
          {$ENDIF}
          {$ENDIF}
          d:=encodeDate(dFrom.year,dFrom.month,dFrom.day);
          ts:=DateTimeToTimeStamp(d);
          move(ts.date,Value^,sizeof(ts.date)); //todo safe? //todo fix! length reported won't be big enough? Is client clever enough to allocate/pass BCD structure?
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getDate returns %d',[longint(Value^)]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getDate}

function TSQLCursor.getBytes(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log('getBytes called',vLow);
  {$ENDIF}
  {$ENDIF}

  result:=SQL_SUCCESS;
  result:=DBXERR_NOTSUPPORTED; //todo remove!!!
end; {getBytes}

function TSQLCursor.getBlobSize(ColumnNumber: Word; var Length: LongWord;
  var IsBlank: LongBool): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('getBlobSize called %d',[ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    {We actually read the blob to work out its size. This is buffered so a subsequent
     call to getBlob will have no repeat network traffic.
     todo: better to just ask server for blob length before pulling data, in case caller
           decides to not pull very large ones for example}
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          Length:=SQLCommand.col[ColumnNumber].bufferLen;
          {$IFDEF DEBUG_DETAIL}
          {$IFDEF DEBUG_LOG}
          log(format('getBlobSize returns %d',[Length]),vLow);
          {$ENDIF}
          {$ENDIF}
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getBlobSize}

function TSQLCursor.getBlob(ColumnNumber: Word; Value: Pointer;
  var IsBlank: LongBool; Length: LongWord): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_DETAIL}
  {$IFDEF DEBUG_LOG}
  log(format('getBlob called %d',[ColumnNumber]),vLow);
  {$ENDIF}
  {$ENDIF}

  if ColumnNumber<=SQLCommand.colCount then
  begin
    result:=readRaw(ColumnNumber);
      if result=SQL_SUCCESS then
      begin
        IsBlank:=SQLCommand.col[ColumnNumber].isNull;
        if not IsBlank then
        begin
          //returnString(pUCHAR(SQLCommand.col[ColumnNumber].buffer),Value,SQLCommand.col[ColumnNumber].bufferLen+1);
          if Length<SQLCommand.col[ColumnNumber].bufferLen then //not enough room allocated by caller, truncate
          begin
            move(SQLCommand.col[ColumnNumber].buffer^,Value^,Length); //todo safe?
            {$IFDEF DEBUG_DETAIL}
            {$IFDEF DEBUG_LOG}
            log(format('getBlob returns %d bytes (out of actual %d)',[Length,SQLCommand.col[ColumnNumber].bufferLen]),vLow);
            {$ENDIF}
            {$ENDIF}
          end
          else //enough room allocated
          begin
            move(SQLCommand.col[ColumnNumber].buffer^,Value^,SQLCommand.col[ColumnNumber].bufferLen); //todo safe?
            //todo remove: no need: move(nullchar,(pchar(Value)+SQLCommand.col[ColumnNumber].bufferLen)^,sizeof(nullchar)); //todo safe?
            {$IFDEF DEBUG_DETAIL}
            {$IFDEF DEBUG_LOG}
            log(format('getBlob returns %d bytes',[SQLCommand.col[ColumnNumber].bufferLen]),vLow);
            {$ENDIF}
            {$ENDIF}
          end;
        end;
      end;
  end
  else
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {getBlob}



{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


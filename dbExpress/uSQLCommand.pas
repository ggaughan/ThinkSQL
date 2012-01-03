{$IFNDEF DBEXP_STATIC}
unit uSQLCommand;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses uSQLConnection,
     DBXpress,
     uGlobalDB;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

type
  SPParamBuffer=record
    desc:SPParamDesc;
    buffer:pointer;
    bufferLen:integer;
    isNull:boolean;
  end; {SPParamBuffer}

  FLDBuffer=record
    desc:FLDDesc;
    buffer:pointer;
    bufferLen:SDWORD;
    isNull:boolean;
  end; {FLDBuffer}

  TSQLCommand=class(TInterfacedObject,ISQLCommand)
  private
    SQLConnectionRef:ISQLConnection; //purely used to keep ref. count in order

    isStoredProc:boolean;

    resultSet:boolean;
    prepared:boolean;   //just for tracking state
    opened:boolean;     //just for tracking state
    affectedRowCount:integer;

    errorMessage:string;
    procedure logError(s:string);
  public
    SQLConnection:TxSQLConnection;

    ServerStatementHandle:integer; {-> stmtPlan ref on server, also if <>-1 => state=connected}

    colCount:integer;   //todo word ok?
    col:array [1..MAX_COL_PER_TABLE] of FLDBuffer;

    paramCount:integer; //todo word would be ok?
    param:array [1..MAX_PARAM_PER_QUERY] of SPParamBuffer;


    constructor Create(c:TxSQLConnection);
    destructor Destroy; override;

    function SQLCloseCursor:SQLResult; //todo protect (needed by cursor)
    function SQLSetDescField(RecordNumber:SQLSMALLINT; //todo protect (needed by cursor)
                                     FieldIdentifier:SQLSMALLINT;
                                     Value:SQLPOINTER;
                                     BufferLength:SQLINTEGER):SQLResult;

    function SetOption(
      eSqlCommandOption: TSQLCommandOption;
      ulValue: Integer): SQLResult; stdcall;
    function GetOption(eSqlCommandOption: TSQLCommandOption;
      var pValue: Integer;
      MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
    function setParameter(
      ulParameter: Word ;
      ulChildPos: Word ;
      eParamType: TSTMTParamType ;
      uLogType: Word;
      uSubType: Word;
      iPrecision: Integer;
      iScale: Integer;
      Length: LongWord ;
      pBuffer: Pointer;
      lInd: Integer): SQLResult; stdcall;
    function getParameter(ParameterNumber: Word; ulChildPos: Word; Value: Pointer;
      Length: Integer; var IsBlank: Integer): SQLResult; stdcall;
    function prepare(SQL: PChar; ParamCount: Word): SQLResult; stdcall;
    function execute(var Cursor: ISQLCursor): SQLResult; stdcall;
    function executeImmediate(SQL: PChar; var Cursor: ISQLCursor): SQLResult; stdcall;
    function getNextCursor(var Cursor: ISQLCursor): SQLResult; stdcall;
    function getRowsAffected(var Rows: LongWord): SQLResult; stdcall;
    function close: SQLResult; stdcall;
    function getErrorMessage(Error: PChar): SQLResult; overload; stdcall;
    function getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
  end; {TSQLCommand}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses uLog,
     SysUtils,
     uMarshalGlobal,
     uMarshal,
     DB {for TFieldType},
     uSQLCursor,
     SQLTimSt,FmtBCD;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}

constructor TSQLCommand.Create(c:TxSQLConnection);
var
  serverS:SQLHSTMT;
  err:integer;
begin
  inherited create;

  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.Create called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  SQLConnection:=c;
  SQLConnectionRef:=c;

  ServerStatementHandle:=-1; //=> not connected

  isStoredProc:=false;
  prepared:=false;
  opened:=false;

  {We notify the server of this new command(=stmt)}
  with c.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLALLOCHANDLE);
    putSQLSMALLINT(SQL_HANDLE_STMT);
    putSQLHDBC(SQLHDBC(c));  //todo assert this = c? also elsewhere?
    if Send<>ok then
    begin
      //result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for response}
    if Read<>ok then
    begin
      //result:=SQL_ERROR2;
      logError(ssHYT00);
      exit;
    end;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer has been read in total by the Read above because its size was known,
     we can omit the error result checking in the following get() calls = speed
    }
    getFunction(functionId);
    if functionId<>SQL_API_SQLALLOCHANDLE then
    begin
      //result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getSQLHSTMT(serverS);  //server will return 0 if failed
    getRETCODE(resultCode);
    //result:=resultCode; //pass it on //todo fix for DBX first!!!!!
    {$IFDEF DEBUG_LOG}
    log(format('SQLAllocHandle returns %d %d',[resultCode,serverS]),vLow);
    {$ENDIF}
    {if error, then get error details: local-number, default-text}
    if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
    if resultCode=SQL_ERROR then
    begin
      for err:=1 to resultErrCode do
      begin
        if getSQLINTEGER(resultErrCode)<>ok then exit;
        if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
        logError(resultErrText);
        (*  todo Pass error to caller=SQLConnection: at least reset ServerStatementHandle=BAD
        case resultErrCode of
          seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; end;
        else
          resultState:=ss08001; //todo more general failure needed/possible?
        end; {case}
        *)
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}

  ServerStatementHandle:=serverS; //we will pass this reference to server in future calls
end; {create}

destructor TSQLCommand.destroy;
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
begin
  try
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCommand.destroy called (%d)',[longint(self)]),vLow);
    {$ENDIF}

    {Close (de-allocate cursor & stmt etc.) if client hasn't already done this}
    if ServerStatementHandle<>-1 then
    begin
      //todo remove self.close;

      {Free the server handle}
      with SQLConnection.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLFREEHANDLE);
        putSQLSMALLINT(SQL_HANDLE_STMT);
        putSQLHSTMT(ServerStatementHandle); //i.e. we don't directly pass Handle, but use it to find the server's reference
        if Send<>ok then
        begin
          //result:=SQL_ERROR2;
          logError(ss08S01);
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          //result:=SQL_ERROR2;
          logError(ssHYT00);
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLFREEHANDLE then
        begin
          //result:=SQL_ERROR2;
          logError(ss08S01);
          exit;
        end;
        getRETCODE(resultCode);
        //todo remove result:=resultCode; //pass it on //todo fix first for DBX
        {$IFDEF DEBUG_LOG}
        log(format('SQLFreeHandle returns %d',[resultCode]),vLow);
        {$ENDIF}
        {Translate result}
        case resultCode of
          SQL_ERROR: {result:=SQL_ERROR2};
        else
          {result:=SQL_SUCCESS}; //DBX ignores warnings etc.
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
              seInvalidHandle:         {result:=DBXERR_INVALIDHNDL};
            else
              {result:=SQL_ERROR2};
            end; {case}
            logError(resultErrText);
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          exit;
        end;
      end; {with}

      ServerStatementHandle:=-1; //reset our handle
    end;
  finally
    inherited destroy;
  end; {try}
end; {destroy}

procedure TSQLCommand.logError(s:string);
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.logError called %s',[s]),vLow);
  {$ENDIF}
  errorMessage:=s;
end; {logError}


function TSQLCommand.SetOption(
  eSqlCommandOption: TSQLCommandOption;
  ulValue: Integer): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.SetOption called %d %d',[ord(eSqlCommandOption),ulValue]),vLow);
  {$ENDIF}

  case eSqlCommandOption of
    eCommStoredProc:   isStoredProc:=(ulValue<>0);
  end; {case}

  result:=SQL_SUCCESS;
end; {SetOption}

function TSQLCommand.GetOption(eSqlCommandOption: TSQLCommandOption;
  var pValue: Integer;
  MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.GetOption called %d %d',[ord(eSqlCommandOption),MaxLength]),vLow);
  {$ENDIF}

  Length:=0;

  result:=SQL_SUCCESS;
end; {GetOption}

function TSQLCommand.setParameter(
  ulParameter: Word ;
  ulChildPos: Word ;
  eParamType: TSTMTParamType ;
  uLogType: Word;
  uSubType: Word;
  iPrecision: Integer;
  iScale: Integer;
  Length: LongWord ;
  pBuffer: Pointer;
  lInd: Integer): SQLResult; stdcall;
var
  dt:TDatetime;
  ts:TTimestamp;
  s:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.setParameter called (%d) %d %d %d',[longint(self),ulParameter,uLogType,Length]),vLow);
  {$ENDIF}

  if ulParameter<=self.paramCount then
  begin
    {Free any previous param buffer}
    if self.param[ulParameter].buffer<>nil then
    begin
      freeMem(self.param[ulParameter].buffer);
      self.param[ulParameter].buffer:=nil;
      self.param[ulParameter].bufferLen:=0;
    end;

    {Convert from user type to server parameter type}
    s:='';
    self.param[ulParameter].isNull:=(lInd=1);
    if not(lInd=1) then
      case uLogType of
        fldZSTRING: s:=pchar(pBuffer);
        fldINT32:   s:=intToStr(integer(pBuffer^));
        fldFLOAT:   s:=floatToStr(double(pBuffer^));
        fldBCD:     s:=bcdToStr(Tbcd(pBuffer^));
        fldDATETIME:s:=SQLTimSt.SQLTimeStampToStr('yyyy-mm-dd hh:nn:ss.zzz',SQLTimSt.TSQLTimeStamp(pBuffer^)); //todo in future convert to native timestamp & use native toStr routines
        fldDATE:    begin ts.time:=0; ts.date:=integer(pBuffer^); dt:=TimeStampToDateTime(ts); s:=FormatDateTime('yyyy-mm-dd',dt); end;
        fldTIME:    begin ts.date:=0; ts.time:=integer(pBuffer^); dt:=TimeStampToDateTime(ts); s:=FormatDateTime('hh:nn:ss.zzz',dt); end;
        fldBLOB:    s:='[BLOB]'; //handled differently below in case of embedded nulls
      else
        result:=DBXERR_INVALIDFLDTYPE;
        exit;
      end; {case}

    {$IFDEF DEBUG_LOG}
    log(format('setParameter working with %s (null=%d)',[s,lInd]),vDebug); //todo debug only
    {$ENDIF}

    {Store parameter data}
    if uLogType=fldBLOB then
    begin
      self.param[ulParameter].bufferLen:=length;
      getMem(self.param[ulParameter].buffer,self.param[ulParameter].bufferLen);
      move(pBuffer^,self.param[ulParameter].buffer^,self.param[ulParameter].bufferLen);
    end
    else
    begin
      self.param[ulParameter].bufferLen:=System.length(s)+1;
      getMem(self.param[ulParameter].buffer,self.param[ulParameter].bufferLen);
      strLCopy(self.param[ulParameter].buffer,pchar(s),System.length(s));
    end;

    {$IFDEF DEBUG_LOG}
    log(format('setParameter sets %s',[pchar(self.param[ulParameter].buffer)]),vLow);
    {$ENDIF}
    result:=SQL_SUCCESS;
  end
  else  //todo: should allow user to set more params than server says we have!
  begin
    result:=DBXERR_OUTOFRANGE;
  end;
end; {setParameter}

function TSQLCommand.getParameter(ParameterNumber: Word; ulChildPos: Word; Value: Pointer;
  Length: Integer; var IsBlank: Integer): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getParameter called',vLow);
  {$ENDIF}

  result:=SQL_SUCCESS;
end; {getParameter}

function TSQLCommand.prepare(SQL: PChar; ParamCount: Word): SQLResult; stdcall;
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;

  resSet:SQLUSMALLINT;

  colName:pchar;
  x,sFldType:SQLSMALLINT; //sink
  tempNull:SQLINTEGER;
  y:Word; //sink

  finalSQL:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.prepare called (%d) %s %d',[longint(self),hidenil(SQL),ParamCount]),vLow);
  {$ENDIF}

  result:=SQL_ERROR2;

  //todo assert SQLConnection is set

  finalSQL:=SQL;
  if isStoredProc then
  begin
    finalSQL:='CALL '+finalSQL;
    //todo is this really necessary? What about (parameters)?
    {$IFDEF DEBUG_LOG}
    log(format('prepare SQL prefixed with CALL',[nil]),vLow);
    {$ENDIF}
  end;

  {call server prepare}
  //todo Replace all AS with casts - speed
  with SQLConnection.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLPREPARE);
    putSQLHSTMT(ServerStatementHandle);
    if putpUCHAR_SDWORD(pchar(finalSQL),length(finalSQL))<>ok then
    begin //todo assert sql length is small enough beforehand! //todo in future can split over buffers... //todo until then set MAX_STMT_LENGTH for client to inquire upon
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
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
    if functionId<>SQL_API_SQLPREPARE then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    {$IFDEF DEBUG_LOG}
    log(format('prepare returns %d',[resultCode]),vDebug);
    {$ENDIF}

    //todo remove result:=resultCode; //pass it on //todo Fix for DBX first!!!!!
    {Translate result}
    case resultCode of
      SQL_ERROR: result:=SQL_ERROR2;
    else
      result:=SQL_SUCCESS; //DBX ignores warnings etc.
    end; {case}
    {$IFDEF DEBUG_LOG}
    log(format('prepare actually returns %d',[result]),vLow);
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
          seSyntax:                result:=DBXERR_SYNTAX;
          seSyntaxUnknownColumn:   result:=DBXERR_SYNTAX;
          seSyntaxAmbiguousColumn: result:=DBXERR_SYNTAX;
          seSyntaxLookupFailed:    result:=DBXERR_SYNTAX;
          sePrivilegeFailed:       result:=DBXERR_SYNTAX;
          seSyntaxUnknownTable:    result:=DBXERR_SYNTAX;
          seSyntaxUnknownSchema:   result:=DBXERR_SYNTAX;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
    end;

    //todo remove getSQLHSTMT(planHandle);
    getSQLUSMALLINT(resSet);
    {Remember this for future state changes}
    if resSet=SQL_TRUE then resultSet:=True else resultSet:=False;

    {$IFDEF DEBUG_LOG}
    log(format('prepare returns %d %d',[resultCode,resSet]),vLow);
    {$ENDIF}

    if resultCode=SQL_ERROR {todo and any other bad return value possible: use case?} then
    begin
      //todo remove-done above: s.diagnostic.logError(ss42000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo too vague! todo correct?pass details! //todo check result
      //todo maybe server should send details along...
      exit;
    end;
    //todo remove! s.ServerStatementHandle:=planHandle; //store server's handle for future calls
    //todo I think we should store the StatementText against the stmt - may need later...
    // - although may be obtainable from server later?
    prepared:=True; //used for future FSM state changes
    if resultSet then
    begin
      {Now get the cursor column count & definitions}
      getSQLINTEGER(colCount);
      {$IFDEF DEBUG_LOG}
      log(format('SQLPrepare returns %d column defs',[colCount]),vLow);
      {$ENDIF}
      //todo rest is switchable? - maybe can defer till needed?
      //todo now use get with result checking!!!
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
        if rn<=High(Col) then
        begin
          with col[rn] do
          begin
            desc.iFldNum:=rn;
            {We first read the name, type, precision and scale
             and then we make sure the correct parts of the descriptor are
             set according to the type}
            if getpSQLCHAR_SWORD(colName,DYNAMIC_ALLOCATION{todo remove desc_name_SIZE},tempsw)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            strLCopy(desc.szName,colName,sizeof(desc.szName));
            if colName<>nil then begin freeMem(colName); colName:=nil; end; //todo safe without length?

            if getSQLSMALLINT(sFldType)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            //desc.iFldType:=x;

            if SQLConnection.serverCLIversion>=0093 then
            begin
              if getSQLINTEGER(tempNull)<>ok then  //=server width
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              desc.iUnits1:=tempNull;
            end
            else
            begin
              if getSQLSMALLINT(desc.iUnits1)<>ok then  //=server width
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
            end;
            if getSQLSMALLINT(desc.iUnits2)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            if getSQLSMALLINT(x)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            desc.iNullOffset:=x;

            {$IFDEF DEBUG_LOG}
            log(format('SQLPrepare read column definition: %s (%d)',[desc.szName,desc.iUnits1]),vLow); //todo debug only - remove
            {$ENDIF}

            desc.iFldType:=convertType(sFldType,desc.iSubType);
          end; {with}
        end
        else
        begin
          //error, skip this column: need to consume the rest of this column definition anyway -> sink
          //todo or, could abort the whole routine instead?
          //note: currently getRecord cannot fail!
          {$IFDEF DEBUG_LOG}
          log(format('SQLPrepare failed getting desc record %d - rest of column defs abandoned...',[rn]),vLow); //todo debug error only - remove
          {$ENDIF}
          result:=SQL_ERROR2;
          logError(ss08S01);
          exit; //todo: just for now!
        end;

        inc(i);
      end; {while}
    end
    else //no result set
    begin
    end; {result set check}

    {Now get the param count & definitions}
    getSQLINTEGER(self.paramCount);
    {$IFDEF DEBUG_LOG}
    log(format('SQLPrepare returns %d parameter defs',[self.paramCount]),vLow);
    {$ENDIF}
    //todo now use get with result checking!!!
    i:=0;
    while i<=self.paramCount-1 do
    begin
      //todo maybe server should sort by param-ref before sending?, although we sort here via getRecord...
      if getSQLSMALLINT(rn)<>ok then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;
      //todo if auto-ipd is switched off then
      // either set dr to a dummy-sink or
      // get all the parameter definitions into local dummy variables
      // - the server passes back the definition no matter what the driver switch is set to
      // - I think we should always auto-set the IPD count anyway?

      //todo since server doesn't yet give us any decent type info for the
      // parameters, we shouldn't overwrite any details that the user has
      // set - maybe don't use the server info if dataPtr has been set by user *******

      if rn<=High(self.Param) then
      begin
        with param[rn] do
        begin
          desc.iParamNum:=rn;
          {We first read the name, type, precision and scale
           and then we make sure the correct parts of the descriptor are
           set according to the type}
          if getpSQLCHAR_SWORD(colName,DYNAMIC_ALLOCATION{todo ok? desc_name_SIZE}{todo no real limit:make dynamic},tempsw)<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;
          setLength(desc.szName,length(colName));
          strLCopy(pchar(desc.szName),colName,sizeof(desc.szName));
          if colName<>nil then begin freeMem(colName); colName:=nil; end; //todo safe without length?

          //todo get desc_base_column_name as well...and catalog,schema,table!
          if getSQLSMALLINT(x)<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;
          desc.iDataType:=TFieldType(convertType(x,y{dummy}));

          desc.iArgType:=ptInput; //default

          if SQLConnection.serverCLIversion>=0093 then
          begin
            if getSQLINTEGER(tempNull)<>ok then  //=server width
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
            desc.iUnits1:=tempNull;
          end
          else
          begin
            if getSQLSMALLINT(desc.iUnits1)<>ok then  //=server width
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;
          end;
          if getSQLSMALLINT(desc.iUnits2)<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;
          if getSQLSMALLINT(x{nullable n/a})<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;

          {We set the initial parameter to null to avoid sending garbage to the server if the user
           forgets to set the parameter}
          isnull:=true;

          {$IFDEF DEBUG_LOG}
          log(format('SQLPrepare read parameter definition: %s (%d)',[desc.szName,desc.iUnits1]),vLow); //todo debug only - remove
          {$ENDIF}
        end; {with}
      end
      else
      begin
        //error, skip this parameter: need to consume the rest of this parameter definition anyway -> sink
        //todo or, could abort the whole routine instead?
        //note: currently getRecord cannot fail!
        {$IFDEF DEBUG_LOG}
        log(format('SQLPrepare failed getting desc record %d - rest of parameter defs abandoned...',[rn]),vLow); //todo debug error only - remove
        {$ENDIF}
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit; //todo: just for now!
      end;

      inc(i);
    end; {while}

    (*todo remove? here
    {Now auto-bind all the columns}
    for i:=1 to colCount do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      //note: it might be easier just to pass serverStmt,recordNumber,bound(T or F)
      //but we're trying to keep this function the same on the server in case we need it for other things...
      // - we could always call a special serverBindCol routine here instead?
      putFunction(SQL_API_SQLSETDESCFIELD);
      putSQLHSTMT(ServerStatementHandle); //pass server statement ref (it has no concept of our desc's)
      putSQLSMALLINT(col[i].iFldType); //todo don't really need this since server only cares about us setting its ARD responsibilities (currently...)
      //together, the above two are the server's closest concept of our DescriptorHandle
      putSQLSMALLINT(col[i].iFldNum); //this will be the colRef(-1) on the server
      putSQLSMALLINT(SQL_DESC_DATA_POINTER); //=SQL_DESC_DATA_POINTER
      putSQLPOINTER(SQLPOINTER(1){server could tell we are DBXpress if all bindings are to 1!}); //= 0=unbound, else bound
      putSQLINTEGER(col[i].iUnits1{todo:better to set & use iLen?});
      //we send Value (& BufferLength) even though it means nothing to the server,
      // - the server just needs to know if it's 0 or not to be able to track the bind/unbinds
      // although it might help for debugging/error reporting/comparing colBound values? - not used for such yet...
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
      if functionId<>SQL_API_SQLSETDESCFIELD then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;
      getRETCODE(resultCode);
      //todo remove result:=resultCode; //pass it on //todo fix first for DBX!
      {Translate result}
      case resultCode of
        SQL_ERROR: result:=SQL_ERROR2;
      else
        result:=SQL_SUCCESS; //DBX ignores warnings etc.
      end; {case}
      {$IFDEF DEBUG_LOG}
      log(format('prepare bound column %d (%d) returns %d',[i,col[i].iFldNum,resultCode]),vLow);
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
            seColumnNotBound:        result:=SQL_ERROR2;
            seColumnAlreadyBound:    result:=SQL_ERROR2;
            seUnknownFieldId:        result:=SQL_ERROR2;
          else
            result:=SQL_ERROR2;
          end; {case}
          logError(resultErrText);
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
        exit;
      end;
    end; {for}
    *)
  end; {with}

  result:=SQL_SUCCESS; //todo ok?
end; {prepare}

function TSQLCommand.execute(var Cursor: ISQLCursor): SQLResult; stdcall;
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;

  row:SQLUINTEGER;
  rowCount:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  rowStatusExtra:SQLSMALLINT;      //conversion error/warning in row
  colStatusExtra:SQLSMALLINT;      //conversion error/warning in column
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  offsetSize:SQLINTEGER;

  resultRowCount:SQLINTEGER;
  tempNull:SQLSMALLINT;

  lateResSet:SQLUSMALLINT;

  colName:pchar;
  x,sFldType:SQLSMALLINT; //sink
  tempNull2:SQLINTEGER;
  y:Word; //sink
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.execute called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  {dbExpress allows re-execute without explicit cursor close, so we close it here}
  {todo? if opened then}
  if assigned(Cursor) then
  begin
    {$IFDEF DEBUG_LOG}
    log(format('TSQLCommand.execute called with existing cursor... closing cursor',[longint(cursor)]),vLow);
    {$ENDIF}
    SQLCloseCursor; //todo check result
  end;

  //todo if manual commit mode & tran has not been started, do it now - actually needed at SQLPrepare instead!
  //...in fact, leave this to the server - it knows when we need a transaction & don't have one!!!!!
  {call server execute}
  //todo Replace all AS with casts - speed
  with SQLConnection.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLEXECUTE);
    putSQLHSTMT(ServerStatementHandle); //pass server statement ref

    //todo send parameter data - could be array & have offset etc.
    // - reverse logic used in fetchScroll... (after it's complete!)
    //Note: here is where we implicitly convert the valueType(client) into the ParamType(server)

    (* todo implement when server can accept parameter arrays
       for now, we restrict PARAMSET_SIZE = 1
    *)
    //for now:
    rowCount:=1; //todo get from PARAMSET_SIZE, may as well since it's always 1

    {Write row count}
    putSQLUINTEGER(rowCount);
    //todo? check rowCount=array_size - no reason why not... could assume? - but dangerous
    {Initialise the count of non-empty param (rows?) in the application's buffer}
    //if s.apd.desc_rows_processed_ptr<>nil then
    //  pSQLuINTEGER(s.apd.desc_rows_processed_ptr)^:=0; //we increment this each time we send a 'real' param row
    //might be slightly quicker (less safe) to set to rowCount now & decrement if we get an empty/bad row - speed?

    //todo: note pSQLINTEGER(intPtr)^:=x is safer than SQLINTEGER(intPtr^):=x
    // - check this is true & if so make sure we use this everywhere!

    {$IFDEF DEBUG_LOG}
    //log(format('SQLExecute sending %d rows',[rowCount]),vLow);
    {$ENDIF}

    //if s.apd.desc_bind_offset_ptr<>nil then
    //  offsetSize:=SQLINTEGER(s.apd.desc_bind_offset_ptr^) //get deferred value
    //else
      offsetSize:=0; //todo assert rowCount/array_size = 1 - else where do we get the data!!!!

    {$IFDEF DEBUG_LOG}
    //log(format('SQLExecute bind offset size=%d',[offsetSize]));
    {$ENDIF}

    setStatusExtra:=0; //no conversion errors

    for row:=1 to rowCount do
    begin
      {Now send the param count & data for this row}
      putSQLINTEGER(self.paramCount); //note: this may no longer match server's count! //todo ok/disallow?
                                 // or should we always use s.ipd.desc_count?
      {$IFDEF DEBUG_LOG}
      log(format('SQLExecute sending %d parameter data',[self.paramCount]),vLow);
      {$ENDIF}
      //todo assert s.apd.desc_count(<?)=s.ipd.desc_count ?
      //todo now use put with result checking!!!

      rowStatusExtra:=0; //no conversion errors

      i:=0;
      while i<=self.paramCount-1 do
      begin
        with param[i+1] do
        begin
          //todo maybe server should sort by param-ref after receiving?, although we sort here via getRecord...
          if putSQLSMALLINT(i+1)<>ok then
          begin
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit;
          end;
          //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
          begin
            //todo use a put routine that doesn't add \0 = waste of space at such a raw level?
            //todo check casts are ok
            //todo assert desc_data_ptr<>nil! surely not every time!?
            {Put the data}
            //we need to store pointer in a temp var cos we need to pass as var next (only because routine needs to allow Dynamic allocation - use 2 routines = speed)
              //todo - doesn't apply to put - remove need here in parameter sending routine! -speed
            //elementSize may not be original desc_octet_length if fixed-length data-type, but bindCol fixes it for us
                //-> todo: if we start to use arrays of parameters - need to ensure desc_octet_length is set to size of fixed types during bindParameter/setdescField
            //if s.apd.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
            //  dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* desc_octet_length))
            //else //row-wise
            //  dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* s.apd.desc_bind_type));

            //todo convert from c to server type (i.e. from APD to IPD) ******
            // - note do before we modify send buffer area - may be too big!
            (*todo remove
            if s.ipd.getRecord(i+1,Idr,True)<>ok then
            begin
              //error, skip this parameter: need to send the rest of this parameter definition anyway -> dummy
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUGDETAIL}
              log(format('SQLExecute failed getting IPD desc record %d - rest of parameter data abandoned...',[i+1])); //todo debug error only - remove
              {$ENDIF}
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit; //todo: just for now!
            end;
            *)

            {Put the null flag}
            tempNull:=SQL_FALSE; //default
            if isnull then tempNULL:=SQL_TRUE;
            if putSQLSMALLINT(tempNull)<>ok then
            begin
              result:=SQL_ERROR2;
              logError(ss08S01);
              exit;
            end;

            //tempsdw:=0; //todo: remove: only set for debug message below -speed

            if tempNull=SQL_FALSE then
            begin
              //Note: we only send length+data if not null
              {Set tempsdw to the length - may be modified by conversion routines}
              //todo maybe don't set tempsdw if null will be set below?
              //tempsdw:=bufferLen;
              {If this is a fixed type, we ignore the passed BufferLength & use our own} //todo is this the best place for this?
//todo debug only!!!!! copied from BindCol...
              //todo copy this code to BindParameter?
              //FixBufferLen(desc_type,tempsdw);
              //todo if DATA_AT_EXEC then pass data_pointer to server - it will return it when data required
              //-no: we have then server return the param-ref & we return the data_pointer locally

              //case desc.iDataType of
                //todo: for now we only get/return string params
                //fldZSTRING:
                begin
                  (*todo remove to allow large parameters
                  //assume buffer is already a string
                  if putpUCHAR_SDWORD(buffer,bufferLen)<>ok then
                  *)
                  if putpDataSDWORD(buffer,bufferLen)<>ok then
                  begin
                    result:=SQL_ERROR2;
                    logError(ss08S01);
                    exit;
                  end;
                end;
              //end; {case}

              (*todo remove
              //note: SQL_C_DEFAULT could be dangerous - we assume user knows what they're doing!
              if not isBinaryCompatible(Idr.desc_concise_type,desc_concise_type) then
              begin //conversion required
                /* todo remove, we don't know it yet
                {We read the 1st part, the length, of the field}
                if getSDWORD(tempsdw)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                */
                {Remember any result (error or warning) to add to rowStatus returned from server}
                colStatusExtra:=putAndConvert(Adr,Idr.desc_concise_type, dataPtr,tempsdw {todo replaced desc_octet_length},
                                (s.owner as Tdbc).Marshal,tempsdw {todo no need here/or just here!?}, s.diagnostic,row,i+1);
                if colStatusExtra<>ok then
                  if rowStatusExtra=0 then
                    rowStatusExtra:=colStatusExtra; //note: we only retain the 1st warning or error (todo check ok with standard)
                                                    //(although multiple diagnostic error may have been stacked)

                //todo ensure that if a fixed-size result is null, the put in putandconvert doesn't send too much!!!
                //********* i.e. we should always send a int/float value even if null
                //          or we should send null flag first before sending data
                //          or putandconvert should not put if tempsdw=0 is passed!
                //     Note: we do the 3rd option - check works ok...

                //todo check no need: marshal.skip(tempsdw); //just read by another routine!
              end
              else
              begin //no conversion required
                //note: we don't add \0 here
                //todo we should if user has given len=NTS!!!!!!!! ***
                // -is there an inverse rule to this for the receival side(fetch)?
                if putpDataSDWORD(dataPtr,tempsdw{todo replaced desc_octet_length})<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
              end;
              *)
            end;

            {$IFDEF DEBUGDETAIL}
            log(format('execute sent parameter %d data: %d bytes, null=%d',[i+1,bufferLen,tempNull]),vLow); //todo debug only
            {$ENDIF}
          end; {with}
        end; {with}
        inc(i);
      end; {while}
      (* //these need to be inverted if/when we allow parameters arrays
      {put row status}
      getSQLUSMALLINT(sqlRowStatus);
      {$IFDEF DEBUGDETAIL}
      log(format('SQLFetchScroll read row status %d: %d',[rn,sqlRowStatus])); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
      {$ENDIF}
      {If there was a conversion error, then we set the SQLrowStatus to it
       todo - check ok with standard!}
      if rowStatusExtra<>0 then
      begin
        sqlRowStatus:=rowStatusExtra; //todo: maybe we should only if sqlRowStatus is 'OK'?
        if setStatusExtra=0 then
          setStatusExtra:=rowStatusExtra;
      end;
      if s.ard.desc_array_status_ptr<>nil then
      begin
        //todo remove & statusPtr var: statusPtr:=pSQLUSMALLINT(longint(desc_array_status_ptr)+( (row-1)* sizeof(SQLUSMALLINT)))
        SQLUSMALLINT(pSQLUSMALLINT(longint(s.ard.desc_array_status_ptr)+( (row-1)* sizeof(SQLUSMALLINT)))^):=sqlRowStatus;
      end;
      *)
      {Add to the count of non-empty param rows in the application's buffer}
    //todo reinstate when arrays are allowed:   if sqlRowStatus<>SQL_ROW_NOROW then

      //  if s.apd.desc_rows_processed_ptr<>nil then
      //    inc(pSQLuINTEGER(s.apd.desc_rows_processed_ptr)^); //we increment this each time we put a (todo remove?'real') param row
    end; {for row}

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
    if functionId<>SQL_API_SQLEXECUTE then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on
    {$IFDEF DEBUG_LOG}
    log(format('SQLExecute returns %d',[resultCode]),vLow);
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
          seSyntaxNotEnoughViewColumns: result:=SQL_ERROR2;
          seSyntaxTableAlreadyExists:   result:=SQL_ERROR2;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
    end;
    {Get the row count - only valid for insert/update/delete}
    getSQLINTEGER(resultRowCount);
    affectedRowCount:=resultRowCount; //todo get direct?

    if SQLConnection.serverCLIversion>=0092 then
    begin
      {Now get any late (post-prepare) resultSet definition, i.e. for stored procedure return cursors
       False here doesn't mean we have no result set, it means we should use the details from SQLprepare}
      //todo remove getSQLHSTMT(planHandle);
      getSQLUSMALLINT(lateResSet);
      {Remember this for future state changes}
      if lateResSet=SQL_TRUE then resultSet:=True; //else leave resultSet as was

      {$IFDEF DEBUG_LOG}
      log(format('execute returns %d %d',[resultCode,lateresSet]),vLow);
      {$ENDIF}
      if lateResSet=SQL_TRUE then
      begin
        {Now get the cursor column count & definitions}
        getSQLINTEGER(colCount);
        {$IFDEF DEBUG_LOG}
        log(format('SQLExecute returns %d column defs',[colCount]),vLow);
        {$ENDIF}
        //todo rest is switchable? - maybe can defer till needed?
        //todo now use get with result checking!!!
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
          if rn<=High(Col) then
          begin
            with col[rn] do
            begin
              desc.iFldNum:=rn;
              {We first read the name, type, precision and scale
               and then we make sure the correct parts of the descriptor are
               set according to the type}
              if getpSQLCHAR_SWORD(colName,DYNAMIC_ALLOCATION{todo remove desc_name_SIZE},tempsw)<>ok then
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              strLCopy(desc.szName,colName,sizeof(desc.szName));
              if colName<>nil then begin freeMem(colName); colName:=nil; end; //todo safe without length?

              if getSQLSMALLINT(sFldType)<>ok then
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              //desc.iFldType:=x;

              if SQLConnection.serverCLIversion>=0093 then
              begin
                if getSQLINTEGER(tempNull2)<>ok then  //=server width
                begin
                  result:=SQL_ERROR2;
                  logError(ss08S01);
                  exit;
                end;
                desc.iUnits1:=tempNull2;
              end
              else
              begin
                if getSQLSMALLINT(desc.iUnits1)<>ok then  //=server width
                begin
                  result:=SQL_ERROR2;
                  logError(ss08S01);
                  exit;
                end;
              end;
              if getSQLSMALLINT(desc.iUnits2)<>ok then
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              if getSQLSMALLINT(x)<>ok then
              begin
                result:=SQL_ERROR2;
                logError(ss08S01);
                exit;
              end;
              desc.iNullOffset:=x;

              {$IFDEF DEBUG_LOG}
              log(format('SQLExecute read column definition: %s (%d)',[desc.szName,desc.iUnits1]),vLow); //todo debug only - remove
              {$ENDIF}

              desc.iFldType:=convertType(sFldType,desc.iSubType);
            end; {with}
          end
          else
          begin
            //error, skip this column: need to consume the rest of this column definition anyway -> sink
            //todo or, could abort the whole routine instead?
            //note: currently getRecord cannot fail!
            {$IFDEF DEBUG_LOG}
            log(format('SQLExecute failed getting desc record %d - rest of column defs abandoned...',[rn]),vLow); //todo debug error only - remove
            {$ENDIF}
            result:=SQL_ERROR2;
            logError(ss08S01);
            exit; //todo: just for now!
          end;

          inc(i);
        end; {while}
      end;
      //else no result set
    end;
    //else young server cannot handle this

    case resultCode of
      SQL_SUCCESS, SQL_SUCCESS_WITH_INFO:
      begin
        //todo get rowCount
        //todo get command-type & store locally somewhere...
        //todo if update/delete affected 0 rows, we need to return SQL_NO_DATA

        //we SQLendTran now if in autocommit mode & if not select/result-set
        if not resultSet and (SQLConnection.autocommit=DBTrue) then
        begin
          {$IFDEF DEBUG_LOG}
          log('execute autocommitting...',vLow);
          {$ENDIF}
          SQLConnection.commit(cardinal(self));
          //prepared:=false; //todo ok? only place?
        end;

        if resultSet then opened:=true; //track state so we know the cursor we're returning is still open against this command

        if opened then //25/01/03 fix: was always creating cursor, even for INSERT etc. => close on next execute => unprepared!
        begin
          {Build & return cursor, if we have one}
          Cursor:=TSQLCursor.create(self);
        end;
        {Translate result}
        result:=SQL_SUCCESS; //DBX ignores warnings etc.
        {$IFDEF DEBUG_LOG}
        log(format('execute actually returns %d',[result]),vLow);
        {$ENDIF}
      end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
      SQL_NEED_DATA:
      begin
        if prepared then //Note: could be called from SQLexecDirect so behaves as if prepared...
        begin
          {Get the next missing parameter reference from the server}
          getSQLSMALLINT(rn);
          {but we can't return it to the user here - they must call SQLParamData to get it}
          //todo could save 1st call to SQLparamData from contacting server!!!! - speed
        end
        else
        begin //should never happen unless caller doesn't know the rules, but then how could we get to need data if we weren't prepared?
          result:=SQL_ERROR2;
          logError(ssHY010);
          exit;
        end;
      end; {SQL_NEED_DATA}
      SQL_STILL_EXECUTING:
      begin
      end; {SQL_STILL_EXECUTING}
      SQL_ERROR:
      begin
        if prepared then //Note: could be called from SQLexecDirect so caller will need to move from S2 to S1

        else
        begin
          result:=SQL_ERROR2;
          //todo remove: already logged error from server: logError(ssHY010);
          exit;
        end;
      end; {SQL_ERROR}
    else
      //todo what if SQL_ERROR?
      //(else) should never happen!?
    end; {case}
  end; {with}
end; {execute}

function TSQLCommand.executeImmediate(SQL: PChar; var Cursor: ISQLCursor): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.executeImmediate called (%d) %s',[longint(self),SQL]),vLow);
  {$ENDIF}

  result:=prepare(SQL,0{must be assumed});
  if result=SQL_SUCCESS then
  begin
    result:=execute(Cursor);
    prepared:=false; //todo ok? only place?
  end;
end; {executeImmediate}

function TSQLCommand.getNextCursor(var Cursor: ISQLCursor): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getNextCursor called',vLow);
  {$ENDIF}

  Cursor:=nil; //no more cursors

  result:=SQL_SUCCESS;
end; {getNextCursor}

function TSQLCommand.getRowsAffected(var Rows: LongWord): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getRowsAffected called',vLow);
  {$ENDIF}

  //todo remove! caused client crash!?! Rows:=affectedRowCount;
  Rows:=LongWord(affectedRowCount);

  {$IFDEF DEBUG_LOG}
  log(format('getRowsAffected returning %d',[Rows]),vDebug);
  {$ENDIF}

  result:=SQL_SUCCESS;
end; {getRowsAffected}

function TSQLCommand.SQLSetDescField(RecordNumber:SQLSMALLINT;
                                     FieldIdentifier:SQLSMALLINT;
                                     Value:SQLPOINTER;
                                     BufferLength:SQLINTEGER):SQLResult;
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.SQLSetDescField implicitly called (%d) rn=%d, value=%p',[longint(self),RecordNumber,Value]),vLow);
  {$ENDIF}

  result:=SQL_ERROR2;

  if FieldIdentifier=SQL_DESC_DATA_POINTER then
  begin
    with SQLConnection.Marshal do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      //note: it might be easier just to pass serverStmt,recordNumber,bound(T or F)
      //but we're trying to keep this function the same on the server in case we need it for other things...
      // - we could always call a special serverBindCol routine here instead?
      putFunction(SQL_API_SQLSETDESCFIELD);
      putSQLHSTMT(ServerStatementHandle); //pass server statement ref (it has no concept of our desc's)
      putSQLSMALLINT(SQL_ATTR_APP_ROW_DESC); //todo don't really need this since server only cares about us setting its ARD responsibilities (currently...)
      //together, the above two are the server's closest concept of our DescriptorHandle
      putSQLSMALLINT(recordNumber); //this will be the colRef(-1) on the server
      putSQLSMALLINT(FieldIdentifier); //=SQL_DESC_DATA_POINTER
      putSQLPOINTER(Value); //= 0=unbound, else bound
      putSQLINTEGER(BufferLength);
      //we send Value (& BufferLength) even though it means nothing to the server,
      // - the server just needs to know if it's 0 or not to be able to track the bind/unbinds
      // although it might help for debugging/error reporting/comparing colBound values? - not used for such yet...
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
      if functionId<>SQL_API_SQLSETDESCFIELD then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;
      getRETCODE(resultCode);
      //todo remove result:=resultCode; //pass it on //todo fix for DBX
      {$IFDEF DEBUG_LOG}
      log(format('SQLSetDescField %d (ARD & DATA_PTR bound switch %p) returns %d',[recordNumber,Value,resultCode]),vLow);
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
          else
            result:=SQL_ERROR2;
          end; {case}
          logError(resultErrText);
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
      end;
    end; {with}
  end;
end; {SQLSetDescField}

function TSQLCommand.SQLCloseCursor:SQLResult;
{Internal close cursor (but keep stmt handle)
 seems to be implicit in dbExpress (ODBC calls this implicitly after eof & explicitly)
}
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.SQLCloseCursor implicitly called (%d) (prepared=%d)',[longint(self),ord(prepared)]),vLow);
  {$ENDIF}

  //todo assert opened

  {Here seems to be the best place to unbind any columns:
   (just before prepare/execute might be better?)
   worst case could be that we unbind too early but would still work
  }
  for i:=0 to colCount-1 do
  begin
    {free allocated memory from the last row & unbind the column}
    with col[i+1] do
    begin //column must have been bound before
      if (buffer<>nil) or isNull then
        SQLSetDescField(i+1,SQL_DESC_DATA_POINTER,nil,00); //todo check result

      isNull:=false;
      if buffer<>nil then
      begin
        freeMem(buffer);
        buffer:=nil;
        bufferLen:=0;
      end;
    end; {with}
  end;

  with SQLConnection.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLCLOSECURSOR);
    putSQLHSTMT(ServerStatementHandle); //pass server statement ref
    if prepared then putSQLSMALLINT(0) else putSQLSMALLINT(1);
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
    if functionId<>SQL_API_SQLCLOSECURSOR then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on //todo fix for DBX
    {$IFDEF DEBUG_LOG}
    log(format('SQLCloseCursor returns %d',[resultCode]),vLow);
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
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
    end;

    //we SQLendTran now if in autocommit mode & if not select/result-set
    if opened and (SQLConnection.autocommit=DBTrue) then
    begin
      {$IFDEF DEBUG_LOG}
      log('CloseCursor autocommitting...',vLow);
      {$ENDIF}
      SQLConnection.commit(cardinal(self));
      //prepared:=false; //todo ok? only place?
    end;

    opened:=false; //todo ok even if errored?
  end; {with}
end; {SQLCloseCursor}

function TSQLCommand.close: SQLResult; stdcall;
var
  err:integer;
  i:SQLINTEGER; //todo word ok?
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLCommand.close called (%d)',[longint(self)]),vLow);
  {$ENDIF}

  {We must notify the server before we delete this object so it can delete its prepare/execute handle for it
   todo: note, maybe the server can auto-create a default handle so the majority of clients
         needn't notify it during this routine unless they allocate >1 stmt = unusual
  }

  {Before we zap the server stmt, we unbind and close in case the caller hasn't done this,
   otherwise calling them during our stmt.free would try to notify the server about the unbinding/closing
   but by then it would be too late - the server handle would have been freed
  }

(*todo here: remove: no binding at the moment...
  {Unbind all columns}
  with SQLConnection.Marshal do
  begin
    {Now auto-unbind all the columns}
    for i:=1 to colCount do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      //note: it might be easier just to pass serverStmt,recordNumber,bound(T or F)
      //but we're trying to keep this function the same on the server in case we need it for other things...
      // - we could always call a special serverBindCol routine here instead?
      putFunction(SQL_API_SQLSETDESCFIELD);
      putSQLHSTMT(ServerStatementHandle); //pass server statement ref (it has no concept of our desc's)
      putSQLSMALLINT(col[i].iFldType); //todo don't really need this since server only cares about us setting its ARD responsibilities (currently...)
      //together, the above two are the server's closest concept of our DescriptorHandle
      putSQLSMALLINT(col[i].iFldNum); //this will be the colRef(-1) on the server
      putSQLSMALLINT(SQL_DESC_DATA_POINTER); //=SQL_DESC_DATA_POINTER
      putSQLPOINTER(SQLPOINTER(0)); //= 0=unbound, else bound
      putSQLINTEGER(col[i].iUnits1{todo:better to set & use iLen?});
      //we send Value (& BufferLength) even though it means nothing to the server,
      // - the server just needs to know if it's 0 or not to be able to track the bind/unbinds
      // although it might help for debugging/error reporting/comparing colBound values? - not used for such yet...
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
      if functionId<>SQL_API_SQLSETDESCFIELD then
      begin
        result:=SQL_ERROR2;
        logError(ss08S01);
        exit;
      end;
      getRETCODE(resultCode);
      //todo remove result:=resultCode; //pass it on //todo fix first for DBX!
      {Translate result}
      case resultCode of
        SQL_ERROR: result:=SQL_ERROR2;
      else
        result:=SQL_SUCCESS; //DBX ignores warnings etc.
      end; {case}
      {$IFDEF DEBUG_LOG}
      log(format('close unbound column %d (%d) returns %d',[i,col[i].iFldNum,resultCode]),vLow);
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
            seNotPrepared:           result:=SQL_SUCCESS; //todo ok? result:=SQL_ERROR2;
            seColumnNotBound:        result:=SQL_SUCCESS; //todo ok? result:=SQL_ERROR2;
            seColumnAlreadyBound:    result:=SQL_SUCCESS; //todo ok? result:=SQL_ERROR2;
            seUnknownFieldId:        result:=SQL_SUCCESS; //todo ok? result:=SQL_ERROR2;
          else
            result:=SQL_ERROR2;
          end; {case}
          logError(resultErrText);
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
        exit;
      end;
    end; {for}

  end; {with}
*)

  {todo remove debug: we've misunderstood what this should do: just unprepare!?
  if opened then
    SQLCloseCursor; //todo check result
  }

(*todo remove HERE debug
  {call server SQLCloseCursor}
  //todo do we need to if our cursor.state is not open!!!!??? save time e.g. when called from SQLendTran
  //todo Replace all AS with casts - speed
  with SQLConnection.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLCLOSECURSOR);
    putSQLHSTMT(ServerStatementHandle); //pass server statement ref
    if prepared then putSQLSMALLINT(0) else putSQLSMALLINT(1);
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
    if functionId<>SQL_API_SQLCLOSECURSOR then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on //todo fix for DBX
    {$IFDEF DEBUG_LOG}
    log(format('SQLCloseCursor returns %d',[resultCode]),vLow);
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
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
    end;
  end; {with}
*)

(*todo moved to command destroy: debug?
  {Free the server handle}
  with SQLConnection.Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLFREEHANDLE);
    putSQLSMALLINT(SQL_HANDLE_STMT);
    putSQLHSTMT(ServerStatementHandle); //i.e. we don't directly pass Handle, but use it to find the server's reference
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
    if functionId<>SQL_API_SQLFREEHANDLE then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on //todo fix first for DBX
    {$IFDEF DEBUG_LOG}
    log(format('SQLFreeHandle returns %d',[resultCode]),vLow);
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
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}
*)

  {Free any parameter buffers}
  for i:=1 to self.paramCount{todo for all array?} do
  begin
    if self.param[i].buffer<>nil then
    begin
      freeMem(self.param[i].buffer);
      self.param[i].buffer:=nil;
      self.param[i].bufferLen:=0;
    end;
  end;

(*todo moved to command destroy: debug?
  ServerStatementHandle:=-1; //reset our handle
*)

  prepared:=false; //todo ok? only place?

  result:=SQL_SUCCESS;
end; {close}

function TSQLCommand.getErrorMessage(Error: PChar): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getErrorMessage called: '+errorMessage,vLow);
  {$ENDIF}

  strLCopy(Error,pchar(errorMessage),length(errorMessage));

  result:=SQL_SUCCESS;
end; {getErrorMessage}

function TSQLCommand.getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getErrorMessageLen called',vLow);
  {$ENDIF}

  ErrorLen:=length(errorMessage);

  result:=SQL_SUCCESS;
end; {getErrorMessageLen}


{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


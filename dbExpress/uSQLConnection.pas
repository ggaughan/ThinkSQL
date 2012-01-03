{$IFNDEF DBEXP_STATIC}
unit uSQLConnection;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses uSQLDriver,
     DBXpress,
     IdTCPClient,
     uMarshal;

{Include the ODBC standard definitions}
{$define NO_FUNCTIONS}
{$include ODBC.INC}
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

type
  TxSQLConnection=class(TInterfacedObject,ISQLConnection)       //TSQLConnection is used in SQLExpr
  private
    SQLdriver:TSQLDriver;
    SQLdriverRef:ISQLDriver; //purely used to keep ref. count in order

    clientSocket:TIdTCPClient;
    fmarshal:TMarshalBuffer; //protect with criticalSection - maybe can use socket.lock?

    callBack:TSQLCallbackEvent;
    callbackInfo:pointer;

    transactionBegun:boolean; //True=beginTransaction called when autocommit=DBTRUE, which suspends any autocommit until commit/rollback

    errorMessage:string;
    procedure logError(s:string);

    function getMarshal:TMarshalBuffer;
  public
    autocommit:integer;
    serverCLIversion:word; //store server's parameter protocol version
    serverTransactionKey:SQLPOINTER; //store server's unique id for future encryption/validation

    property marshal:TMarshalBuffer read getMarshal;


    constructor Create(d:TSQLDriver);
    destructor Destroy; override;

    function connect(ServerName: PChar; UserName: PChar;
                          Password: PChar): SQLResult; stdcall;
    function disconnect: SQLResult; stdcall;
    function getSQLCommand(out pComm: ISQLCommand): SQLResult; stdcall;
    function getSQLMetaData(out pMetaData: ISQLMetaData): SQLResult; stdcall;
    function SetOption(eConnectOption: TSQLConnectionOption;
            lValue: LongInt): SQLResult; stdcall;
    function GetOption(eDOption: TSQLConnectionOption; PropValue: Pointer;
            MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
    function beginTransaction(TranID: LongWord): SQLResult; stdcall;
    function commit(TranID: LongWord): SQLResult; stdcall;
    function rollback(TranID: LongWord): SQLResult; stdcall;
    function getErrorMessage(Error: PChar): SQLResult; overload; stdcall;
    function getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
  end; {TxSQLConnection}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}

implementation

uses uLog,
     uGlobalDB,
     SysUtils,
     uSQLCommand,
     uSQLMetaData,
     uMarshalGlobal;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
constructor TxSQLConnection.create(d:TSQLDriver);
begin
  inherited create;

  SQLDriver:=d;
  SQLdriverRef:=d;

  clientSocket:=TIdTCPClient.Create(nil);
  //todo disable Nagle?!?

  clientSocket.Host:=defaultHost;
  clientSocket.Port:=defaultPort;

  fmarshal:=TMarshalBuffer.create(clientSocket);

  serverCLIversion:=0000;
  serverTransactionKey:=nil;

  autocommit:=DBTrue; //crappy default (& only option!) for DBXpress at the moment
  transactionBegun:=False;
end; {create}

destructor TxSQLConnection.destroy;
begin
  fmarshal.free;
  fmarshal:=nil;
  clientSocket.free;
  clientSocket:=nil;

  inherited destroy;
end; {destroy}

procedure TxSQLConnection.logError(s:string);
begin
  errorMessage:=s;
end; {logError}

function TxSQLConnection.getMarshal:TMarshalBuffer;
begin
  if assigned(fmarshal) then
    result:=fmarshal
  else
  begin
    result:=nil;
    log('getMarshal called for unassigned marshal buffer',vAssertion);
  end;
end; {getMarshal}


function TxSQLConnection.connect(ServerName: PChar; UserName: PChar;
                          Password: PChar): SQLResult; stdcall;
var
  err:integer;
begin
  {$IFDEF DEBUG_LOG}
  log(format('connect called %s %s %d',[hidenil(ServerName),hidenil(UserName),length(Password)]),vLow);
  {$ENDIF}

  result:=SQL_ERROR2;

  {Try to open the connection to the server}
  try
    //todo use c.login_timeout!
    clientSocket.Connect; //try to open the connection
  except
    {on E:EIdSocksError do
    begin
      result:=SQL_ERROR2;
      //todo interpret E.message?
      logError(E.message);
      exit;
    end; }
    on E:Exception do
    begin
      result:=SQL_ERROR2;
      //todo interpret E.message?
      logError(E.message);
      exit;
    end;
  end; {try}

  {Negotiate the connection}
  {Since this is the 1st contact between this connection & the server
   the Connect also marshals the driver version info and should retrieve the
   server's version info so that a newer server can still talk to an older driver
   i.e. handshake
  }
  with Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }

    //todo remove: putFunction(SQL_API_handshake);
    if SendHandshake<>ok then //send raw handshake
    begin
      result:=SQL_ERROR2;
      logError('Handshake failed');
      exit;
    end;
    {Now the server knows we're using CLI protocol we can use the marshal buffer}
    putSQLUSMALLINT(clientCLIversion); //special version marker for initial protocol handshake
    if clientCLIversion>=0093 then //todo no need to check here!
    begin
      putSQLUSMALLINT(CLI_DBEXPRESS);
    end;
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08001);
      exit;
    end;

    {Wait for handshake response}
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
    if functionId<>SQL_API_handshake then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getSQLUSMALLINT(serverCLIversion); //note server's protocol
    if serverCLIversion>=0093 then
    begin
      getSQLPOINTER(serverTransactionKey); //note server's transaction key
    end;
    {$IFDEF DEBUG_LOG}
    log(format('handshake returns %d',[serverCLIversion]),vLow);
    {$ENDIF}

    {Now SQLconnect}
    //todo when marshalling user+password -> encrypt the password!!!!
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLCONNECT);
    putSQLHDBC(SQLHDBC(self));
    putpUCHAR_SWORD(ServerName,length(ServerName));
    putpUCHAR_SWORD(UserName,length(UserName));
    putpUCHAR_SWORD(Password,length(Password));
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for read to return the response}
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
    if functionId<>SQL_API_SQLCONNECT then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on //todo only pass on SUCCESS/FAIL ie. convertTOdbX!!!!!!
    {$IFDEF DEBUG_LOG}
    log(format('connect returns %d',[resultCode]),vLow);
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
        logError(resultErrText);
        case resultErrCode of
          seUnknownAuth:   result:=DBXERR_INVALIDUSRPASS;
          seWrongPassword: result:=DBXERR_INVALIDUSRPASS;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}

  {Ok, we're connected}


  result:=SQL_SUCCESS;
end; {connect}

function TxSQLConnection.disconnect: SQLResult; stdcall;
var
  err:integer;
begin
  {$IFDEF DEBUG_LOG}
  log('disconnect called',vLow);
  {$ENDIF}

  result:=SQL_ERROR2;

  {Negotiate disconnection}
  //todo: check that from here on, we never return ERROR!
  with Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLDISCONNECT);
    putSQLHDBC(SQLHDBC(self));
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for read to return the response}
    if Read<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer has been read in total by the Read above because its size was known,
     we can omit the error result checking in the following get() calls = speed
    }
    getFunction(functionId);
    if functionId<>SQL_API_SQLDISCONNECT then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo any point?: result:=resultCode;
    {$IFDEF DEBUG_LOG}
    log(format('disconnect returns %d',[resultCode]),vLow);
    {$ENDIF}
    //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
    {if error, then get error details: local-number, default-text}
    if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
    if resultCode=SQL_ERROR then
    begin
      for err:=1 to resultErrCode do
      begin
        if getSQLINTEGER(resultErrCode)<>ok then exit;
        if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      //todo remove: never will happen: exit;
    end;
  end; {with}

  {Try to disconnect from the server}
  try
    clientSocket.Disconnect{todo socket?}; //close this connection
  except
    on E:Exception do
    begin
      result:=SQL_SUCCESS_WITH_INFO;
      //todo interpret E.message?
      logError(E.message); //todo remove: just warn & assume?
      exit;
    end;
  end; {try}

  {$IFDEF DEBUG_LOG}
  logNoShow:=True; //todo debug:remove
  {$ENDIF}

  result:=SQL_SUCCESS;
end; {disconnect}

function TxSQLConnection.getSQLCommand(out pComm: ISQLCommand): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getSQLCommand called',vLow);
  {$ENDIF}

  pComm:=TSQLCommand.create(self);

  result:=SQL_SUCCESS;
end; {getSQLCommand}

function TxSQLConnection.getSQLMetaData(out pMetaData: ISQLMetaData): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getSQLMetaData called',vLow);
  {$ENDIF}

  pMetaData:=TSQLMetaData.create(self);

  result:=SQL_SUCCESS;
end; {getSQLMetaData}

function TxSQLConnection.SetOption(eConnectOption: TSQLConnectionOption;
            lValue: LongInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TxSQLConnection.SetOption called %d %d',[ord(eConnectOption),lValue]),vLow);
  {$ENDIF}
  case eConnectOption of
    eConnAutoCommit:            begin
                                  //todo if transactionBegun then reject?
                                  autocommit:=integer(lValue); //todo typecast ok
                                  {$IFDEF DEBUG_LOG}
                                  log(format('Set autocommit %d',[autocommit]),vLow);
                                  {$ENDIF}
                                end;
    eConnBlockingMode:          ;
    eConnBlobSize:              ;
    eConnRoleName:              ;
    eConnWaitOnLocks:           ;
    eConnCommitRetain:          ;
    eConnTxnIsoLevel:           ;
    eConnNativeHandle:          {ro};
    eConnServerVersion:         {ro};
    eConnCallBack:              begin
                                  callback:=TSQLCallbackEvent(lValue);
                                  {$IFDEF DEBUG_LOG}
                                  log(format('Set callback function %p',[addr(callback)]),vLow);
                                  {$ENDIF}
                                  //Note: we will call this as-and-when we want to
                                  //      currently type can only be cbTRACE & we should call for each 'command'
                                  //      check result of type CBRType
                                end;
    eConnHostName:              begin
                                  clientSocket.Host:=pchar(lValue);
                                  {$IFDEF DEBUG_LOG}
                                  log(format('Set host name %s',[clientSocket.Host]),vLow);
                                  {$ENDIF}
                                end;
    eConnDatabaseName:          {ro};
    eConnCallBackInfo:          begin
                                  callbackInfo:=pointer(lValue);
                                  {$IFDEF DEBUG_LOG}
                                  log(format('Set callback info %p',[callbackInfo]),vLow);
                                  {$ENDIF}
                                end;
    eConnObjectMode:            ;
    eConnMaxActiveConnection:   {ro};
    eConnServerCharSet:         ;
    eConnSQLDialect:            ;
  end; {case}

  result:=SQL_SUCCESS;
end; {SetOption}

function TxSQLConnection.GetOption(eDOption: TSQLConnectionOption; PropValue: Pointer;
            MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TxSQLConnection.GetOption called %d %d',[ord(eDOption),MaxLength]),vLow);
  {$ENDIF}

  case eDOption of
    eConnAutoCommit:            length:=returnNumber(autocommit,PropValue,MaxLength); //todo if transactionBegun then reject?
    eConnBlockingMode:          length:=returnNumber(DBTrue,PropValue,MaxLength);   //todo manual sounds like this should default to false...
    eConnBlobSize:              length:=returnNumber(0,PropValue,MaxLength);  //in K
    eConnRoleName:              length:=returnString('',PropValue,MaxLength); //IB only
    eConnWaitOnLocks:           length:=returnNumber(DBFalse,PropValue,MaxLength);  //IB only
    eConnCommitRetain:          length:=returnNumber(DBFalse,PropValue,MaxLength);  //IB only but does apply!
    eConnTxnIsoLevel:           length:=returnNumber(ord(xilREPEATABLEREAD),PropValue,MaxLength); //todo: make stronger via custom... & get from server
    eConnNativeHandle:          length:=returnNumber(0,PropValue,MaxLength);  //N/A! todo: return server's handle?
    eConnServerVersion:         length:=returnNumber(0,PropValue,MaxLength); //todo get from server as getInfo!
    eConnCallBack:              begin pointer(PropValue^):=nil; Length:=0; end; //todo
    eConnHostName:              length:=returnString('',PropValue,MaxLength); //mySQL only: todo get from server
    eConnDatabaseName:          length:=returnString('',PropValue,MaxLength); //todo get from server
    eConnCallBackInfo:          length:=returnNumber(0,PropValue,MaxLength);  //todo
    eConnObjectMode:            length:=returnNumber(DBFalse,PropValue,MaxLength);  //Oracle only
    eConnMaxActiveConnection:   length:=returnNumber(9999999,PropValue,MaxLength);  //todo get from server
    eConnServerCharSet:         length:=returnString('',PropValue,MaxLength); //IB only: todo get from server
    eConnSQLDialect:            length:=returnNumber(0,PropValue,MaxLength);  //IB only
  end; {case}

  result:=SQL_SUCCESS;
end; {GetOption}

function TxSQLConnection.beginTransaction(TranID: LongWord): SQLResult; stdcall;
var
  err:integer;
begin
  {$IFDEF DEBUG_LOG}
  log(format('beginTransaction called %d %d',[TranId,ord(TTransactionDesc(pointer(TranId)^).IsolationLevel)]),vLow);
  {$ENDIF}

  if autocommit=DBTrue then
  begin
    transactionBegun:=True;
    autocommit:=DBFalse;
    {$IFDEF DEBUG_LOG}
    log(format('  autocommit temporarily disabled',[nil]),vLow);
    {$ENDIF}
  end;

  {Send SQLendTran to server}
  with Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLSETCONNECTATTR);
    putSQLHDBC(SQLHDBC(self));  //todo pass TranId?
    putSQLINTEGER(SQL_ATTR_TXN_ISOLATION);
    case TTransactionDesc(pointer(TranId)^).IsolationLevel of //= isolation level
      xilREADCOMMITTED:  putSQLUINTEGER(SQL_TRANSACTION_READ_COMMITTED);
      xilREPEATABLEREAD: putSQLUINTEGER(SQL_TRANSACTION_SERIALIZABLE{todo note we're being more strict: SQL_TRANSACTION_REPEATABLE_READ});
      xilDIRTYREAD:      putSQLUINTEGER(SQL_TRANSACTION_READ_UNCOMMITTED);
      xilCUSTOM:         putSQLUINTEGER(TTransactionDesc(pointer(TranId)^).CustomIsolation); //use user value direct, e.g. 8=SQL_TRANSACTION_SERIALIZABLE, or 4 really does mean SQL_TRANSACTION_REPEATABLE_READ
    else
      putSQLUINTEGER(SQL_TRANSACTION_SERIALIZABLE); //default
    end;
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for read to return the response}
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
    if functionId<>SQL_API_SQLSETCONNECTATTR then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on
    {$IFDEF DEBUG_LOG}
    log(format('SQLSetConnectAttr (SQL_ATTR_TXN_ISOLATION) returns %d',[resultCode]),vLow);
    {$ENDIF}
    {Translate result}
    case resultCode of
      SQL_ERROR: result:=SQL_ERROR2;
    else
      result:=SQL_SUCCESS; //DBX ignores warnings etc.
    end; {case}

    //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
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
          seInvalidOption:         result:=SQL_ERROR2;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}

  result:=SQL_SUCCESS;
end; {beginTransaction}

function TxSQLConnection.commit(TranID: LongWord): SQLResult; stdcall;
var
  err:integer;
begin
  {$IFDEF DEBUG_LOG}
  log(format('commit called %d',[TranId]),vLow);
  {$ENDIF}

  if transactionBegun then
  begin
    autocommit:=DBTrue;
    transactionBegun:=False;
    {$IFDEF DEBUG_LOG}
    log(format('  autocommit re-enabled',[nil]),vLow);
    {$ENDIF}
  end;

  //todo: we must close any open command/cursors first! leave to user...

  {Send SQLendTran to server}
  with Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLENDTRAN);
    putSQLHDBC(SQLHDBC(self));  //todo pass TranId?
    putSQLSMALLINT(SQL_COMMIT);
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for read to return the response}
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
    if functionId<>SQL_API_SQLENDTRAN then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on
    {$IFDEF DEBUG_LOG}
    log(format('SQLEndTran returns %d',[resultCode]),vLow);
    {$ENDIF}
    {Translate result}
    case resultCode of
      SQL_ERROR: result:=SQL_ERROR2;
    else
      result:=SQL_SUCCESS; //DBX ignores warnings etc.
    end; {case}

    //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
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
          seInvalidOption:         result:=SQL_ERROR2;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}

  result:=SQL_SUCCESS;
end; {commit}

function TxSQLConnection.rollback(TranID: LongWord): SQLResult; stdcall;
var
  err:integer;
begin
  {$IFDEF DEBUG_LOG}
  log(format('rollback called %d',[TranId]),vLow);
  {$ENDIF}

  if transactionBegun then
  begin
    autocommit:=DBTrue;
    transactionBegun:=False;
    {$IFDEF DEBUG_LOG}
    log(format('  autocommit re-enabled',[nil]),vLow);
    {$ENDIF}
  end;

  //todo: we must close any open command/cursors first! leave to user...

  {Send SQLendTran to server}
  with Marshal do
  begin
    ClearToSend;
    {Note: because we know these marshalled parameters all fit in a buffer together,
     and because the buffer is now empty after the clearToSend,
     we can omit the error result checking in the following put() calls = speed
    }
    putFunction(SQL_API_SQLENDTRAN);
    putSQLHDBC(SQLHDBC(self));  //todo pass TranId?
    putSQLSMALLINT(SQL_ROLLBACK);
    if Send<>ok then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;

    {Wait for read to return the response}
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
    if functionId<>SQL_API_SQLENDTRAN then
    begin
      result:=SQL_ERROR2;
      logError(ss08S01);
      exit;
    end;
    getRETCODE(resultCode);
    //todo remove result:=resultCode; //pass it on
    {$IFDEF DEBUG_LOG}
    log(format('SQLEndTran returns %d',[resultCode]),vLow);
    {$ENDIF}
    {Translate result}
    case resultCode of
      SQL_ERROR: result:=SQL_ERROR2;
    else
      result:=SQL_SUCCESS; //DBX ignores warnings etc.
    end; {case}

    //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
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
          seInvalidOption:         result:=SQL_ERROR2;
        else
          result:=SQL_ERROR2;
        end; {case}
        logError(resultErrText);
        if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
      end;
      exit;
    end;
  end; {with}

  result:=SQL_SUCCESS;
end; {rollback}

function TxSQLConnection.getErrorMessage(Error: PChar): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getErrorMessage called',vLow);
  {$ENDIF}

  strLCopy(Error,pchar(errorMessage),length(errorMessage));

  result:=SQL_SUCCESS;
end; {getErrorMessage}

function TxSQLConnection.getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
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


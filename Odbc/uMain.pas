unit uMain;

{$IFDEF DEBUG_LOG}
  {$DEFINE DEBUGDETAIL}    //todo remove when live!
  //{$DEFINE DEBUGDETAIL2} //debug error message detail truncation error
  {$DEFINE DEBUGDETAILWARNING}
    //todo check all debug logging causes no errors! e.g. %p & invalid type etc.
{$ENDIF}

{Run Parameters:
  D:\Program Files\Platform SDK\test\ansi\Odbcte32.exe
  c:\program files\borland\delphi 3\bin\delphi32.exe
  C:\Program Files\Borland\Delphi 3\BIN\dbexplor.exe
  OLD: C:\WINDOWS\MsApps\MSQUERY\MSQRY32.EXE
  C:\Program Files\Common Files\Microsoft Shared\MSQUERY\MSQRY32.EXE
  C:\Tools\QTODBC\QTODBC.exe
 //todo remove comment!
}

{$DEFINE NO_SQLGETDIAGREC} //hide SQLgetDiagRec to allow SQLerror to be called with correct buffer size
                           //(else most callers would only pass buffer size of 1 & not re-call!)
                           //Note: also needed to be defined in Project to prevent publication

{Note:
 prevent all routines (including sub-units) from excepting! //todo
 //especially with memory failures -i.e. all new/create calls should be able to return fail

 todo:
   remove ; from all internal queries...
}

interface

{Include the ODBC standard definitions}
{$define SQL_API}
{$include odbc.inc}

{Note:
 we use a strange combination of 'standard SQL' definitions
 and 'Microsoft ODBC' stub function declarations.

 There are some incompatibilities and we currently use the ODBC version.
 This DLL will always be an ODBC driver: be practical!
}

function FixStringSDWORD(s:pUCHAR;var l:SDWORD):integer;


implementation

uses uGlobal, sysUtils, (*todo remove Windows {sleep debug},*) uStrings, IdException {for SocksError}, IdStack,
     uDiagnostic, uEnv, uDbc, uStmt, uDesc, fmConnect, uDataType, uMarshal{just for const DYNAMIC_ALLOCATION},
     uMarshalGlobal;

const
  ODBC_INSTALLER_DLL='odbccp32.dll'; //todo load dynamically? = more portable?

  {Keyword value pair constants}
  kUID='UID';
  kPWD='PWD';
  kDSN='DSN';

  kDRIVER='DRIVER';
  //todo handle BDE: kDATABASE='DATABASE'
  //Note: more keywords (common to this routine & registry) are defined in uGlobal

function SQLGetPrivateProfileString(lpszSection:pUCHAR;
                                    lpszEntry:pUCHAR;
                                    lpszDefault:pUCHAR;
                                    RetBuffer:pUCHAR;
                                    cbRetBuffer:INTEGER;
                                    lpszFilename:pUCHAR):INTEGER;
{$IFDEF WIN32}
  stdcall; external ODBC_INSTALLER_DLL;
{$ELSE}
  begin
    result:=0; //fail //todo map to Linux equivalent...
  end; {SQLGetPrivateProfileString}
{$ENDIF}

const
  MAX_VARCHAR_TEMP_FIX=127; //temporary limit on varchar(0) definitions - todo FIX!!!

//todo move to common/other unit?
//- also ensure they're being used everywhere they should - not just before we marshal them!
//also check if l<>SQL_NTS that we have \0 at end of string - do we ever need to add it?  YES!
//     but the memory is not ours to extend
//     but we can try to put a \0 1 after the lth position and hope caller accounted for it!?
//     - I think ultimately we'll need to make local copies of these strings!
function FixStringSWORD(var s:pUCHAR;var l:SWORD):integer;
{RETURNS  ok, else fail}
var
  newCopy:pUCHAR;
begin
  result:=ok;
  if s=nil then exit;

  if l<0 then
  begin
    if l=SQL_NTS then
    begin
      l:=length(s);
    end
    else
      result:=fail;
  end
  else
  begin
    {We need to null-terminate the string ourselves}
    {Note: this should be rare, since MS ODBC clients tend to be C
           but SQLForeignKeys/SQLconnect (etc?) seem to not use this standard...
           although in most cases they seem to null-terminate anyway...}
    newCopy:=strAlloc(l+1);
    strLCopy(pUCHAR(newCopy),s,l);   //todo no need for safety? -speed: but use l to limit in case \0 not available in source
    s:=newCopy;              //caller still owns original memory, so no garbage problems...
                             //todo: except that we don't free our memory here! - todo MUST!
    result:=+1; //allow caller to realise that it must now free this memory
                //Note: we don't currently do this = memory leak: TODO fix! (but only small + rare!)
                //Alternative is to copy every string parameter into a local buffer but
                //is it worth the slow-down to plug such a small leak? better to track & fix each leak...
  end;
end;
//todo: apply any length processing from above in this routine, but only if useful...
function FixStringSDWORD(s:pUCHAR;var l:SDWORD):integer;
{RETURNS  ok, else fail}
begin
  result:=ok;
  if s=nil then exit;

  if l<0 then
    if l=SQL_NTS then
    begin
      l:=length(s);
    end
    else
      result:=fail;
end;

function FixBufferLen(dtype:SQLSMALLINT;var l:SDWORD):integer;
{RETURNS  ok
   if type is unknown, l is left as-is}
begin
  result:=ok;
  case dtype of
    SQL_C_SSHORT, SQL_C_USHORT, SQL_C_SHORT:          l:=sizeof(SQLSMALLINT);
    SQL_C_SLONG, SQL_C_ULONG, SQL_C_LONG:             l:=sizeof(SQLINTEGER);
    SQL_C_FLOAT:                                      l:=sizeof(single);
    SQL_C_DOUBLE:                                     l:=sizeof(SQLDOUBLE);
    SQL_C_STINYINT, SQL_C_UTINYINT, SQL_C_TINYINT:    l:=sizeof(SQLCHAR);
    SQL_C_SBIGINT, SQL_C_UBIGINT:                     l:=sizeof(comp);
    {SQL_C_BOOKMARK=SQL_C_ULONG,} {SQL_C_VARBOOKMARK=SQL_C_BINARY,}
    SQL_C_TYPE_DATE:                                  l:=sizeof(DATE_STRUCT);
    SQL_C_TYPE_TIME:                                  l:=sizeof(TIME_STRUCT);
    SQL_C_TYPE_TIMESTAMP:                             l:=sizeof(TIMESTAMP_STRUCT);
    SQL_C_NUMERIC:                                    l:=sizeof(SQL_NUMERIC_STRUCT);
//todo *****    SQL_C_GUID:                        l:=sizeof(SQLGUID);
//todo *****    SQL_C_INTERVAL_YEAR..SQL_C_INTERVAL_MINUTE_TO_SECOND: l:=sizeof(SQL_INTERVAL_STRUCT);
    {todo etc?}
//todo?    SQL_C_DATE, SQL_C_TIME, SQL_C_TIMESTAMP, //todo check we need to support these - aren't they higher-level flags?

    //todo check if we ignore this that all is well: SQL_C_DEFAULT:
  //else we leave the length alone
  end; {case}
end; {FixBufferLen}

(* FROM ODBC SDK smplDrv.c
*)
(*obsolete
///// SQLAllocConnect /////
function SQLAllocConnect  (EnvironmentHandle:HENV;
                   ConnectionHandle:pHDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  log('SQLAllocConnect called');
  result:=SQL_SUCCESS;
end;
*)
(*
///// SQLAllocEnv /////

RETCODE SQL_API SQLAllocEnv  (HENV * arg0)
{
	log("SQLAllocEnv called\n");
	return(SQL_SUCCESS);
}

///// SQLAllocStmt /////

RETCODE SQL_API SQLAllocStmt  (HDBC arg0,
		 HSTMT * arg1)
{
	log("SQLAllocStmt called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLBindCol /////

function SQLBindCol  (StatementHandle:SQLHSTMT;
			ColumnNumber:UWORD;
			BufferType:SQLSMALLINT; {was SWORD;}
			Data:PTR;
			BufferLength:SDWORD;
			StrLen_or_Ind:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLBindCol called %d %d %d %p %d %p',[StatementHandle,ColumnNumber,BufferType,Data,BufferLength,StrLen_or_Ind]));
  {$ENDIF}

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  if s.state>=S8 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  if ColumnNumber<1 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  {Check the datatype is valid}
  if not isValidCtype(BufferType) then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY003,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  if BufferLength<0 then //SQL standard says <=0 //todo make switchable?
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo maybe set s.ard values directly & bypass setDescField - speed (but no checks/side-effects!)
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_TYPE,SQLPOINTER(BufferType),SQL_IS_SMALLINT);
  if result=SQL_ERROR then exit;

  {If this is a fixed type, we ignore the passed BufferLength & use our own} //todo is this the best place for this?
  //otherwise, fetching more than 1 row doesn't work properly: fetchScroll needs correct desc_octet_length
  //todo copy this code to BindParameter?
  FixBufferLen(BufferType,BufferLength);
(*todo remove
  case BufferType of
    SQL_C_SSHORT, SQL_C_USHORT, SQL_C_SHORT:          BufferLength:=sizeof(SQLSMALLINT);
    SQL_C_SLONG, SQL_C_ULONG, SQL_C_LONG:             BufferLength:=sizeof(SQLINTEGER);
    SQL_C_FLOAT:                                      BufferLength:=sizeof(single);
    SQL_C_DOUBLE:                                     BufferLength:=sizeof(SQLDOUBLE);
    SQL_C_STINYINT, SQL_C_UTINYINT, SQL_C_TINYINT:    BufferLength:=sizeof(SQLCHAR);
    SQL_C_SBIGINT, SQL_C_UBIGINT:                     BufferLength:=sizeof(comp);
    {SQL_C_BOOKMARK=SQL_C_ULONG,} {SQL_C_VARBOOKMARK=SQL_C_BINARY,}
    SQL_C_TYPE_DATE:                                  BufferLength:=sizeof(DATE_STRUCT);
    SQL_C_TYPE_TIME:                                  BufferLength:=sizeof(TIME_STRUCT);
    SQL_C_TYPE_TIMESTAMP:                             BufferLength:=sizeof(TIMESTAMP_STRUCT);
    SQL_C_NUMERIC:                                    BufferLength:=sizeof(SQL_NUMERIC_STRUCT);
//todo *****    SQL_C_GUID:                        BufferLength:=sizeof(SQLGUID);
//todo *****    SQL_C_INTERVAL_YEAR..SQL_C_INTERVAL_MINUTE_TO_SECOND: BufferLength:=sizeof(SQL_INTERVAL_STRUCT);
    {todo etc?}
//todo?    SQL_C_DATE, SQL_C_TIME, SQL_C_TIMESTAMP, //todo check we need to support these - aren't they higher-level flags?

    //todo check if we ignore this that all is well: SQL_C_DEFAULT:
  end; {case}
*)
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_OCTET_LENGTH,SQLPOINTER(BufferLength),SQL_IS_INTEGER);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_LENGTH,SQLPOINTER(99){todo max for this data type!},SQL_IS_UINTEGER);
  if result=SQL_ERROR then exit;
  //todo precision & scale...?
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_DATA_POINTER,Data,BufferLength);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_OCTET_LENGTH_POINTER,StrLen_or_Ind,SQL_IS_POINTER);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.ard),ColumnNumber,SQL_DESC_INDICATOR_POINTER,StrLen_or_Ind,SQL_IS_POINTER);
  if result=SQL_ERROR then exit;

  //setting this column number via SetDescField ensures ARD.SQL_DESC_COUNT is increased, if need be, to ColumnNumber
  //Note: if an error occurred above, we should leave desc_count as it was!
end; {SQLBindCol}

///// SQLCancel /////

function SQLCancel  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLCancel called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle: remember it could be someone else's here}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //s.diagnostic.clear; //ok?

  case s.state of
    S1,S2..S3,S4,S5..S7, {still call SQLcancel?}
    S8..S10:
    begin
      {call server SQLCancel}
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLCANCEL);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLCANCEL then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('   Cancel returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        case resultCode of
          SQL_SUCCESS:
          begin
            case s.state of
              S8..S10:
              begin
                s.cursor.state:=csClosed; //todo ok? leave to caller or server or call SQLcloseCursor?
                //todo should we reset the cursor name as well? - maybe a future cursor.close method will handle all the details?
                if s.resultSet then
                begin
                  if s.prepared {s.state=S8=need_data} then
                    s.state:=S3 {prepared}
                  else
                    s.state:=S1;
                end
                else
                begin
                  if s.prepared {s.state=S8=need_data} then
                    s.state:=S2 {not prepared}
                  else
                    s.state:=S1;
                end;
              end; {S8..S10}
            //todo else keep same?
            end; {case}
          end; {SQL_SUCCESS}
        else
          //todo what if SQL_ERROR?
          //(else) should never happen!?
        end; {case}
      end; {with}
    end; {S8..S10}
    S11:
    begin
      //next state depending on the stmt...?
    end; {S11}
    S12:
    begin
    end; {S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLCancel}

(*
///// SQLColAttributes /////
//todo check this is still ok - accidentally converted into SQLColAttribute - I think they were identical...
function SQLColAttributes  (StatementHandle:HSTMT;
		 ColumnNumber:UWORD;
		 FieldIdentifier:UWORD;
		 CharacterAttribute:PTR;
		 BufferLength:SWORD;
		 StringLength:{UNALIGNED}pSWORD;
		 NumericAttribute:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  log('SQLColAttributes called');
  result:=SQL_SUCCESS;
end;
*)

///// SQLConnect /////

function SQLConnect  (ConnectionHandle:SQLHDBC;
		 ServerName:pUCHAR;
		 NameLength1:SWORD;
		 UserName:pUCHAR;
		 NameLength2:SWORD;
		 Authentication:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  retBuf:array [0..MAX_RETBUF-1] of char;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLConnect called %s %s',[ServerName,UserName]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle}
  c:=Tdbc(ConnectionHandle);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  {Fix string lengths}
  if FixStringSWORD(ServerName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(UserName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(Authentication,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  if c.state=C2 then
  begin
    //todo diagnostic clear? I think so

    {Setup connection from ServerName=DSN, i.e. lookup details in registry}
    {Note: serverName='DEFAULT' may have been passed by driver manager if serverName was nil //todo check always handled by driverConnect}
    //todo remove: c.clientSocket.Host:='localHost'; //ServerName; //todo: for now this must be localHost or IP address of server

    c.DSN:=ServerName;

    {Read server details from DSN only if not already completed, e.g. by sqlDriverConnect}
    if c.clientSocket.Host='' then
    begin
      if SQLGetPrivateProfileString(pchar(ServerName),kHOST,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:=defaultHost;
      c.clientSocket.Host:=retBuf;
    end;
    if c.clientSocket.Port=0 then
    begin
      if SQLGetPrivateProfileString(pchar(ServerName),kSERVICE,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:=defaultService; 
      try
        c.clientSocket.Port:=GStack.WSGetServByName(retBuf);
      except
        c.clientSocket.Port:=defaultPort; 
      end; {try}
    end;
    if c.DSNserver='' then
    begin
      if SQLGetPrivateProfileString(pchar(ServerName),kSERVER,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:=defaultServer;
      c.DSNserver:=retBuf;
    end;

    //todo should also read UID/PWD if they are not passed?

    {Try to open the connection to the server}
    try
      //todo use c.login_timeout!
      c.clientSocket.Connect; //try to open the connection
    except
      on E:EIdSocksError do
      begin
        result:=SQL_ERROR;
        //todo interpret E.message?
        c.diagnostic.logError(ss08001,fail,E.message{todo:ok to put this here?},0,0); //todo check result
        exit;
      end;
      on E:Exception do
      begin
        result:=SQL_ERROR;
        //todo interpret E.message?
        c.diagnostic.logError(ss08001,fail,E.message{todo:ok to put this here?},0,0); //todo check result
        exit;
      end;
    end; {try}

    //todo remove: sleep(1000*1); //sleep 1 second to allow to open //todo fix!/remove now we're blocking

    //todo remove this (or at least use a modifiable parameter for the call/duration)
    //todo -or if it remains, we should wrap it in a $ifdef Windows...
    //todo remove: next Read waits very patiently until server is ready... sleep(100); //todo try to fix occasional hang on connect... probably need to use WaitFor...

    (*todo removed: dumb clients only
    {Wait for welcome noise}
    if c.Marshal.Read<>ok then //todo: ensure we time-out relatively quickly here = failed to connect to our server...
    begin
      result:=SQL_ERROR;
      c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo wrong error state? //todo check result
      exit;
    end;
    *)

    {Negotiate the connection}
    {Since this is the 1st contact between this connection & the server
     the Connect also marshals the driver version info and should retrieve the
     server's version info so that a newer server can still talk to an older driver
     i.e. handshake
    }
    with c.Marshal do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }

      //todo remove: putFunction(SQL_API_handshake);
      if SendHandshake<>ok then //send raw handshake
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
        exit;
      end;
      {Now the server knows we're using CLI protocol we can use the marshal buffer}
      putSQLUSMALLINT(clientCLIversion); //special version marker for initial protocol handshake
      if clientCLIversion>=0093 then //todo no need to check here!
      begin
        putSQLUSMALLINT(CLI_ODBC); 
      end;
      if Send<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
        exit;
      end;

      {Wait for handshake response}
      if Read<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
        exit;
      end;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      }
      getFunction(functionId);
      if functionId<>SQL_API_handshake then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
        exit;
      end;
      getSQLUSMALLINT(c.serverCLIversion); //note server's protocol
      if c.serverCLIversion>=0093 then
      begin
        getSQLPOINTER(c.serverTransactionKey); //note server's transaction key
      end;
      {$IFDEF DEBUGDETAIL}
      log(format('handshake returns %d',[c.serverCLIversion]));
      {$ENDIF}

      {Now SQLconnect}
      //todo when marshalling user+password -> encrypt the password!!!!
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      putFunction(SQL_API_SQLCONNECT);
      putSQLHDBC(ConnectionHandle);
      putpUCHAR_SWORD(pUCHAR(c.DSNserver),length(c.DSNserver)); //02/10/02 used to pass serverName (i.e. raw DSN)
      putpUCHAR_SWORD(UserName,NameLength2);
      putpUCHAR_SWORD(Authentication,NameLength3);
      if Send<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
        exit;
      end;

      {Wait for read to return the response}
      if Read<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
        exit;
      end;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      }
      getFunction(functionId);
      if functionId<>SQL_API_SQLCONNECT then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
        exit;
      end;
      getRETCODE(resultCode);
      result:=resultCode; //pass it on
      {$IFDEF DEBUGDETAIL}
      log(format('SQLConnect returns %d',[resultCode]));
      {$ENDIF}
      {if error, then get error details: local-number, default-text}
      //todo: replace resultErrCode by resultErrCount (everywhere!) since we modify it inside the for-loop (safe for Delphi)
      if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
      if resultCode=SQL_ERROR then
      begin
        for err:=1 to resultErrCode do
        begin
          if getSQLINTEGER(resultErrCode)<>ok then exit;
          if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
          case resultErrCode of
            seUnknownAuth:   resultState:=ss08004; //todo 28000 is better? too specific - vague is better here!
            seWrongPassword: resultState:=ss08004;
            //todo unknown catalog/server...
          else
            resultState:=ss08001;
          end; {case}
          c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
        {Now disconnect (todo: reset other details?)}
        try
          c.clientSocket.Disconnect; //try to close the connection
        except
          on E:Exception do
          begin
            //todo interpret E.message?
          end;
        end; {try}
        exit;
      end;
    end; {with}

    {Ok, we're connected}
    c.state:=C4;
  end
  else
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ss08002,fail,'',0,0); //todo check result
    exit;
  end;
end; {SQLConnect}

///// SQLDescribeCol /////

function SQLDescribeCol  (StatementHandle:SQLHSTMT;
		 ColumnNumber:UWORD;
		 ColumnName:pUCHAR;
		 BufferLength:SWORD;
		 NameLength:pSWORD;
		 DataType:{UNALIGNED} pSWORD;
		 ColumnSize:{UNALIGNED} pUDWORD;
		 DecimalDigits:{UNALIGNED} pSWORD;
		 Nullable:{UNALIGNED} pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  temppSQLINTEGER:pSQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLDescribeCol called %d %d %d %d',[StatementHandle,ColumnNumber,longint(ColumnName),BufferLength]));
  {$ENDIF}

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo remove! s.diagnostic.clear;

  result:=SQL_SUCCESS; //default

  //todo check that this check s.state is ok
  if (s.state>=S8) {=>..S12} then  //todo or s.active?
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  if s.ird.desc_count=0 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07005,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
  if ColumnNumber<0 then //note: SQL standard says <1
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
  if ColumnNumber>s.ird.desc_count then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
  //todo maybe bypass SQLGetDescField and set columnName etc directly from s.ird - speed
  //todo - alternatively could base on GetColAttribute?
  if ColumnName<>nil then
  begin
    new(temppSQLINTEGER); //todo allocate once for thread?
    try
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_NAME, ColumnName, BufferLength, temppSQLINTEGER);
      nameLength^:=pSWORD(temppSQLINTEGER)^;
    finally
      dispose(temppSQLINTEGER);
    end; {try}
  end;
  //todo check result
  if DataType<>nil then result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_CONCISE_TYPE, DataType, SQL_IS_POINTER, nil);
  //todo check result
  if ColumnSize<>nil then result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LENGTH{todo ok?}, ColumnSize, SQL_IS_POINTER, nil);
  //todo check result
  if DecimalDigits<>nil then result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_SCALE, DecimalDigits, SQL_IS_POINTER, nil);
  //todo check result
  if Nullable<>nil then result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_NULLABLE, Nullable, SQL_IS_POINTER, nil);
  //todo check result

//todo remove?  if DataType^=12 then
//    DataType^:=SQL_CHAR; //todo should be SQL_C_CHAR
//  else
//    DataType^:=SQL_INTEGER;
end; {SQLDescribeCol}

///// SQLDisconnect /////

function SQLDisconnect  (ConnectionHandle:SQLHDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;
  nextNode:PtrTstmtList;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log('SQLDisconnect called');
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle C0,C1}
  c:=Tdbc(ConnectionHandle);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  c.diagnostic.clear;

  case c.state of
    C2:
    begin
      result:=SQL_ERROR;
      c.diagnostic.logError(ss08003,fail,'',0,0); //todo check result
      exit;
    end;
    C3,C4,C5:
    begin
      //todo if not connected, error 08003  - already covered by state check, but physically double check here!

      {Release any statements (may fail if active/waiting for params etc.)}
      {Note: code copied from Tdbc.destroy - todo maybe we should use a Tdbc.disconnect/freeAllStmts?}
      while c.stmtList<>nil do
      begin
        {Before we zap the server stmt, we unbind and close in case the caller hasn't done this,
         otherwise calling them during our stmt.free would try to notify the server about the unbinding/closing
         but by then it would be too late - the server handle would have been freed
        }
        SQLfreeStmt(SQLHSTMT(c.stmtList^.stmt),SQL_UNBIND); //todo check result
        SQLfreeStmt(SQLHSTMT(c.stmtList^.stmt),SQL_CLOSE); //todo check result

        c.RemoveStatement(c.stmtList^.stmt); //only to be tidy, we don't really care here -just zap them all...
        (c.stmtList^.stmt).free;    //remove the stmt (this closes any open cursor, unbinds everything & removes descs)
        nextNode:=c.stmtList^.next;
        dispose(c.stmtList);
        c.stmtList:=nextNode;
      end;

      //todo free any non-implicit descs

      {Negotiate disconnection}
      //todo: check that from here on, we never return ERROR!
      with c.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLDISCONNECT);
        putSQLHDBC(ConnectionHandle);
        if Send<>ok then
        begin //actually an 08S01 error, but we're trying to disconnect so just return a warning
          result:=SQL_SUCCESS_WITH_INFO;
          c.diagnostic.logError(ss01002,fail,'',0,0); //todo check result
          exit;
        end;

        {Wait for read to return the response}
        if Read<>ok then
        begin //actually an HYT00 error, but we're trying to disconnect so just return a warning
          result:=SQL_SUCCESS_WITH_INFO;
          c.diagnostic.logError(ss01002,fail,'',0,0); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLDISCONNECT then
        begin //actually an 08S01 error, but we're trying to disconnect so just return a warning
          result:=SQL_SUCCESS_WITH_INFO;
          c.diagnostic.logError(ss01002,fail,'',0,0); //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        //todo any point?: result:=resultCode;
        {$IFDEF DEBUGDETAIL}
        log(format('SQLDisconnect returns %d',[resultCode]));
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
            //todo remove: we don't return any errors from here: c.diagnostic.logError(ssTODO,resultErrCode,'TODO',0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          //todo remove: never will happen: exit;
        end;
      end; {with}

      {Try to disconnect from the server}
      try
        c.clientSocket.Disconnect{todo socket?}; //close this connection
        c.state:=C2;
      except
        on E:Exception do
        begin
          result:=SQL_SUCCESS_WITH_INFO;
          //todo interpret E.message?
          c.diagnostic.logError(ss01002,fail,E.message{todo:ok to put this here?},0,0); //todo check result
          exit;
        end;
      end; {try}
    end;
    C6:
    begin
      result:=SQL_ERROR;
      c.diagnostic.logError(ss25000,fail,'',0,0); //todo check result
      exit;
    end;
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLDisconnect}

function SQLError  (EnvironmentHandle:SQLHENV;
                 ConnectionHandle:SQLHDBC;
		 StatementHandle:SQLHSTMT;
		 Sqlstate:pUCHAR;
		 {UNALIGNED}NativeError:pSQLINTEGER;
		 MessageText:pUCHAR;
		 BufferLength:SQLSMALLINT;
		 {UNALIGNED}TextLength:pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  HandleType:SQLSMALLINT;
  Handle:SQLHANDLE;
  e:Tenv;
  c:Tdbc;
  s:Tstmt;
  recordNumber:SQLSMALLINT;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLError called ',[nil]));
  {$ENDIF}

  HandleType:=0; //none
  if EnvironmentHandle<>0 then
  begin
    HandleType:=SQL_HANDLE_ENV;
    Handle:=EnvironmentHandle;
    e:=Tenv(Handle);
    if not(e is Tenv) then
    begin
      result:=SQL_INVALID_HANDLE;
      exit;
    end;
    e.diagnostic.errorNextToRead:=e.diagnostic.errorNextToRead+1;
    recordNumber:=e.diagnostic.errorNextToRead;
  end;
  if ConnectionHandle<>0 then
  begin
    HandleType:=SQL_HANDLE_DBC;
    Handle:=ConnectionHandle;
    c:=Tdbc(Handle);
    if not(c is Tdbc) then
    begin
      result:=SQL_INVALID_HANDLE;
      exit;
    end;
    c.diagnostic.errorNextToRead:=c.diagnostic.errorNextToRead+1;
    recordNumber:=c.diagnostic.errorNextToRead;
  end;
  if StatementHandle<>0 then
  begin
    HandleType:=SQL_HANDLE_STMT;
    Handle:=StatementHandle;
    s:=Tstmt(Handle);
    if not(s is Tstmt) then
    begin
      result:=SQL_INVALID_HANDLE;
      exit;
    end;
    s.diagnostic.errorNextToRead:=s.diagnostic.errorNextToRead+1;
    recordNumber:=s.diagnostic.errorNextToRead;
  end;

  if HandleType=0 then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  result:=SQLGetDiagRec(HandleType, Handle, recordNumber{todo ok?}, Sqlstate, NativeError, MessageText, BufferLength, TextLength);
end; {SQLError}

///// SQLExecDirect /////

function SQLExecDirect  (StatementHandle:SQLHSTMT;
		 StatementText:pUCHAR;
		 TextLength:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLExecDirect called %d %s',[StatementHandle,StatementText]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  {Prepare}
  result:=SQLPrepare(StatementHandle,
		 StatementText,
		 TextLength);
  {Execute}
  if result in [SQL_SUCCESS,SQL_SUCCESS_WITH_INFO] then
  begin
    //Note: we leave s.prepared to get most state changes correct after SQLexecute is done
    result:=SQLExecute(StatementHandle);
    s.prepared:=False; //used for future FSM state changes
    //...but there is one exception:
    if s.state=S2 then s.state:=S1; //i.e. behave as if we weren't really prepared
  end;
end; {SQLExecDirect}

///// SQLExecute /////

function SQLExecute  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

//todo remove?  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  rowStatusExtra:SQLSMALLINT;      //conversion error/warning in row
  colStatusExtra:SQLSMALLINT;      //conversion error/warning in column
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  dataPtr:SQLPOINTER;
  lenPtr:pSQLINTEGER;
//todo remove  statusPtr:pSQLUSMALLINT;

  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;
  adr,idr:TdescRec;

  tempsdw:SDWORD;
  tempNull:SQLSMALLINT;

  lateResSet:SQLUSMALLINT;
  colCount:SQLINTEGER;  //todo word ok?
  dr:TdescRec;

  offsetSize:SQLINTEGER;

  resultRowCount:SQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLExecute called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  s.diagnostic.clear; //todo check

  case s.state of
    S1:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1}
    S2..S3,S4:
    begin
      //todo if manual commit mode & tran has not been started, do it now - actually needed at SQLPrepare instead!
      //...in fact, leave this to the server - it knows when we need a transaction & don't have one!!!!!
      {call server execute}
      //todo Replace all AS with casts - speed

      //todo keep in sync. with SetParamData!
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLEXECUTE);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref

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
        if s.apd.desc_rows_processed_ptr<>nil then
          pSQLuINTEGER(s.apd.desc_rows_processed_ptr)^:=0; //we increment this each time we send a 'real' param row
        //might be slightly quicker (less safe) to set to rowCount now & decrement if we get an empty/bad row - speed?

        //todo: note pSQLINTEGER(intPtr)^:=x is safer than SQLINTEGER(intPtr^):=x
        // - check this is true & if so make sure we use this everywhere!

        {$IFDEF DEBUGDETAIL}
        log(format('SQLExecute sending %d rows',[rowCount]));
        {$ENDIF}

        if s.apd.desc_bind_offset_ptr<>nil then
          offsetSize:=SQLINTEGER(s.apd.desc_bind_offset_ptr^) //get deferred value
        else
          offsetSize:=0; //todo assert rowCount/array_size = 1 - else where do we get the data!!!!

        {$IFDEF DEBUGDETAIL}
        log(format('SQLExecute bind offset size=%d',[offsetSize]));
        {$ENDIF}

        setStatusExtra:=0; //no conversion errors

        for row:=1 to rowCount do
        begin
          {Now send the param count & data for this row}
          putSQLINTEGER(s.apd.desc_count); //note: this may no longer match server's count! //todo ok/disallow?
                                           // or should we always use s.ipd.desc_count?
          {$IFDEF DEBUGDETAIL}
          log(format('SQLExecute sending %d parameter data',[s.apd.desc_count]));
          {$ENDIF}
          //todo assert s.apd.desc_count(<?)=s.ipd.desc_count ?
          //todo now use put with result checking!!!

          rowStatusExtra:=0; //no conversion errors

          i:=0;
          while i<=s.apd.desc_count-1 do
          begin
            if s.apd.getRecord(i+1,Adr,True)=ok then //todo assume i+1 = record number for params -should be ok?
            begin
              //todo maybe server should sort by param-ref after receiving?, although we sort here via getRecord...
              if putSQLSMALLINT(i+1)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
              with Adr do
              begin
                //todo use a put routine that doesn't add \0 = waste of space at such a raw level?
                //todo check casts are ok
                //todo assert desc_data_ptr<>nil! surely not every time!?
                dataPtr:=nil; //04/12/02 assist debug
                {Put the data}
                //we need to store pointer in a temp var cos we need to pass as var next (only because routine needs to allow Dynamic allocation - use 2 routines = speed)
                  //todo - doesn't apply to put - remove need here in parameter sending routine! -speed
                //elementSize may not be original desc_octet_length if fixed-length data-type, but bindCol fixes it for us
                    //-> todo: if we start to use arrays of parameters - need to ensure desc_octet_length is set to size of fixed types during bindParameter/setdescField
                if s.apd.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                  dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* desc_octet_length))
                else //row-wise
                  dataPtr:=pUCHAR(SQLHDESC(desc_data_ptr)+offsetSize+( (row-1)* s.apd.desc_bind_type));

                //todo convert from c to server type (i.e. from APD to IPD) ******
                // - note do before we modify send buffer area - may be too big!
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

                {Put the null flag}
                tempNull:=SQL_FALSE; //default
                if desc_indicator_pointer<>nil then
                begin
                  if s.apd.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                    lenPtr:=pSQLINTEGER(longint(desc_indicator_pointer)+offsetSize+( (row-1)* sizeof(SQLINTEGER)))
                  else //row-wise
                    lenPtr:=pSQLINTEGER(longint(desc_indicator_pointer)+offsetSize+( (row-1)* s.apd.desc_bind_type));

                  //todo check pointer is valid - or catch failure at least - todo for all user pointers!
                  if SQLINTEGER(lenPtr^)=SQL_NULL_DATA then
                    tempNull:=SQL_TRUE;
                end;
                if putSQLSMALLINT(tempNull)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;

                tempsdw:=0; //todo: remove: only set for debug message below -speed

                if tempNull=SQL_FALSE then
                begin
                  //Note: we only send length+data if not null
                  {Set tempsdw to the length - may be modified by conversion routines}
                  //todo maybe don't set tempsdw if null will be set below?
                  tempsdw:=SQL_NTS; //default
                  if desc_octet_length_pointer<>nil then
                  begin
                    if s.ard.desc_bind_type=SQL_BIND_BY_COLUMN then //column-wise //todo move this if outside loop -speed
                      lenPtr:=pSQLINTEGER(longint(desc_octet_length_pointer)+offsetSize+( (row-1)* sizeof(SQLINTEGER)))
                    else //row-wise
                      lenPtr:=pSQLINTEGER(longint(desc_octet_length_pointer)+offsetSize+( (row-1)* s.ard.desc_bind_type));

                    tempsdw:=SQLINTEGER(lenPtr^);
                  end;
                  //else assumes null-terminated, or fixed-length...
                  {$IFDEF DEBUGDETAIL}
                  log(format('SQLExecute parameter %d details: desc_type=%d, apd.bind-by-column=%d, dataPtr=%p, ard.bind-by-column=%d, tempsdw=%d',[i+1,desc_type,ord(s.apd.desc_bind_type=SQL_BIND_BY_COLUMN),dataPtr,ord(s.ard.desc_bind_type=SQL_BIND_BY_COLUMN),tempsdw]));
                  {$ENDIF}

                  (*
                  {Check we don't have a 'caller wants to be prompted to send data' parameter
                   if we do we abandon this execution (we already know a parameter is missing) and
                   switch to setParamData/PutData mode, where the caller converses to feed large data...}
                  if (tempsdw=SQL_DATA_AT_EXEC) or (tempsdw<=SQL_LEN_DATA_AT_EXEC_OFFSET) then
                  begin
                    ClearToSend; //abort this server call

                    resultCode:=SQL_NEED_DATA;
                    result:=resultCode; //pass it on
                    {$IFDEF DEBUGDETAIL}
                    log(format('SQLExecute aborting with %d',[resultCode]));
                    {$ENDIF}
                    if s.prepared then //Note: could be called from SQLexecDirect so behaves as if prepared...
                    begin
                      {The next missing parameter reference from the server is i+1
                       but we can't return it to the user here - they must call SQLParamData to get it}
                      //todo could save 1st call to SQLparamData from contacting server!!!! - speed
                      s.state:=S8;
                    end
                    else
                    begin //should never happen unless caller doesn't know the rules, but then how could we get to need data if we weren't prepared?
                      result:=SQL_ERROR;
                      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                      exit;
                    end;
                    exit; //abort
                  end;
                  *)
                  {Check we don't have a 'caller wants to be prompted to send data' parameter
                   if we do we send 0 bytes to the server so it continues to think the parameter is missing (?)
                   and continue to send the other parameter data from the buffers.
                   The execute will return NEED_DATA and we'll then switch to setParamData/PutData mode,
                   where the caller converses to feed large data...}
                  if {(tempsdw=SQL_DATA_AT_EXEC) or} (tempsdw<=SQL_LEN_DATA_AT_EXEC_OFFSET) then
                  begin
                    //note: tempsdw-SQL_LEN_DATA_AT_EXEC_OFFSET = length
                    tempsdw:=SQL_DATA_AT_EXEC; //handled in putAndConvert //todo ensure isBinaryCompatible = false always...
                  end;
                  //else

                  begin //buffered parameter
                    {If this is a fixed type, we ignore the passed BufferLength & use our own} //todo is this the best place for this?
  //todo debug only!!!!! copied from BindCol...
                    //todo copy this code to BindParameter?
                    FixBufferLen(desc_type,tempsdw);
  (*todo remove
                    case desc_type of
                      SQL_C_SSHORT, SQL_C_USHORT, SQL_C_SHORT:          tempsdw:=sizeof(SQLSMALLINT);
                      SQL_C_SLONG, SQL_C_ULONG, SQL_C_LONG:             tempsdw:=sizeof(SQLINTEGER);
                      SQL_C_FLOAT:                                      tempsdw:=sizeof(single);
                      SQL_C_DOUBLE:                                     tempsdw:=sizeof(SQLDOUBLE);
                      SQL_C_STINYINT, SQL_C_UTINYINT, SQL_C_TINYINT:    tempsdw:=sizeof(SQLCHAR);
                      SQL_C_SBIGINT, SQL_C_UBIGINT:                     tempsdw:=sizeof(comp);
                      {SQL_C_BOOKMARK=SQL_C_ULONG,} {SQL_C_VARBOOKMARK=SQL_C_BINARY,}
                      SQL_C_TYPE_DATE:                                  tempsdw:=sizeof(DATE_STRUCT);
                      SQL_C_TYPE_TIME:                                  tempsdw:=sizeof(TIME_STRUCT);
                      SQL_C_TYPE_TIMESTAMP:                             tempsdw:=sizeof(TIMESTAMP_STRUCT);
                      SQL_C_NUMERIC:                                    tempsdw:=sizeof(SQL_NUMERIC_STRUCT);
                  //todo *****    SQL_C_GUID:                        tempsdw:=sizeof(SQLGUID);
                  //todo *****    SQL_C_INTERVAL_YEAR..SQL_C_INTERVAL_MINUTE_TO_SECOND: tempsdw:=sizeof(SQL_INTERVAL_STRUCT);
                      {todo etc?}
                  //todo?    SQL_C_DATE, SQL_C_TIME, SQL_C_TIMESTAMP, //todo check we need to support these - aren't they higher-level flags?

                      //todo check if we ignore this that all is well: SQL_C_DEFAULT:
                    end; {case}
  *)
                    //todo if DATA_AT_EXEC then pass data_pointer to server - it will return it when data required
                    //-no: we have then server return the param-ref & we return the data_pointer locally

                    //note: SQL_C_DEFAULT could be dangerous - we assume user knows what they're doing!
                    if not isBinaryCompatible(Idr.desc_concise_type,desc_concise_type) then
                    begin //conversion required
                      (* todo remove, we don't know it yet
                      {We read the 1st part, the length, of the field}
                      if getSDWORD(tempsdw)<>ok then
                      begin
                        result:=SQL_ERROR;
                        s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                        exit;
                      end;
                      *)
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
                  end;
                end;

                {$IFDEF DEBUGDETAIL}
                log(format('SQLExecute sent parameter %d data: %d bytes, null=%d',[i+1,tempsdw{todo check means something here!},tempNull])); //todo debug only
                {$ENDIF}
              end; {with}
            end
            else
            begin
              //error, skip this parameter: need to send the rest of this parameter definition anyway -> dummy
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUGDETAIL}
              log(format('SQLExecute failed getting APD desc record %d - rest of parameter data abandoned...',[i+1])); //todo debug error only - remove
              {$ENDIF}              
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit; //todo: just for now!
            end;

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
            if s.apd.desc_rows_processed_ptr<>nil then
              inc(pSQLuINTEGER(s.apd.desc_rows_processed_ptr)^); //we increment this each time we put a (todo remove?'real') param row
        end; {for row}

        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLEXECUTE then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLExecute returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seSyntaxNotEnoughViewColumns: resultState:=ss21S01;
              seSyntaxTableAlreadyExists:   resultState:=ss42S01;
            else
              resultState:=ssHY000;
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        {Get the row count - only valid for insert/update/delete}
        getSQLINTEGER(resultRowCount);
        s.rowCount:=resultRowCount; //todo get direct?

        if (s.owner as Tdbc).serverCLIversion>=0092 then
        begin
          {Now get any late (post-prepare) resultSet definition, i.e. for stored procedure return cursors
           False here doesn't mean we have no result set, it means we should use the details from SQLprepare}
          getSQLUSMALLINT(lateResSet);
          {Remember this for future state changes}
          if lateResSet=SQL_TRUE then s.resultSet:=True; //else leave s.resultSet as was

          {$IFDEF DEBUGDETAIL}
          log(format('SQLExecute returns %d %d',[resultCode,lateResSet]));
          {$ENDIF}
          if lateResSet=SQL_TRUE then
          begin
            s.cursor.state:=csOpen;
            //s.state:=S3; //todo: if s.state=S4 then only if last result of multiple
            if s.state=S2 then s.state:=S3; //below will then advance this to S5
            {Now get the IRD count & definitions}
            getSQLINTEGER(colCount);
            {$IFDEF DEBUGDETAIL}
            log(format('SQLExecute returns %d IRD column defs',[colCount]));
            {$ENDIF}
            s.ird.desc_count:=colCount;
            //todo rest is switchable? - maybe can defer till needed?
            //todo now use get with result checking!!!
            i:=0;
            while i<=colCount-1 do
            begin
              //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
              if getSQLSMALLINT(rn)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              if s.ird.getRecord(rn,dr,True)=ok then
              begin
                with dr do
                begin
                  {We first read the name, type, precision and scale
                   and then we make sure the correct parts of the descriptor are
                   set according to the type}
                  if getpSQLCHAR_SWORD(desc_name,desc_name_SIZE,tempsw)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  if getSQLSMALLINT(desc_type)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;

                  desc_concise_type:=desc_type; //todo check this is correct
                                                //note: we modify it below if datetime/interval
                                                //- bindParameter does this via calling SetDescField
                                                // - maybe we should also call it here to gain exactly
                                                //   the same side-effects?
                  (* todo remove:
                  {Now set the desc type properly to gain necessary side-effects}
                  result:=SQLSetDescField(SQLHDESC(s.ird),rn,SQL_DESC_TYPE,SQLPOINTER(desc_type),SQL_IS_SMALLINT);
                  //better to continue with bad type settings? //if result=SQL_ERROR then exit;
                  *)

                  if (s.owner as Tdbc).serverCLIversion>=0093 then
                  begin
                    if getSQLINTEGER(desc_precision)<>ok then  //=server width
                    begin
                      result:=SQL_ERROR;
                      s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                      exit;
                    end;
                  end
                  else
                  begin
                    if getSQLSMALLINT(tempNull)<>ok then  //=server width
                    begin
                      result:=SQL_ERROR;
                      s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                      exit;
                    end;
                    desc_precision:=tempNull;
                  end;
                  (* todo - moved below
                  //todo length, octet_length & display_size <- width?
                  //for now, set length=precision - not valid for all types... use a dataConversion unit...
                  desc_length:=desc_precision;
                  if not(desc_type in [SQL_CHAR,SQL_VARCHAR]) or (desc_length=0) then
                  begin
                    desc_length:=4; //todo desperate fix to try to please Delphi...(didn't work) - mend!
                  end;
                  *)
                  if getSQLSMALLINT(desc_scale)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  if getSQLSMALLINT(desc_nullable)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  {$IFDEF DEBUGDETAIL}
                  log(format('SQLExecute read column definition: %s (%d)',[desc_name,desc_precision])); //todo debug only - remove
                  {$ENDIF}

                  {The following chunk of code is the inverse of the BindParameter logic
                   - check ok}
                   //todo it is copied below for the IPD...
                   // - so maybe we need a function that
                   //   sets the length,precision,scale,...interval_code/_precision,concise_type
                   //   based on the type?
                   //   Since we use the logic in 3 places already
                  desc_datetime_interval_code:=0; //reset for all non-date/time types
                  case desc_type of
                    SQL_NUMERIC, SQL_DECIMAL:
                      desc_length:=desc_precision;

                    SQL_INTEGER, SQL_SMALLINT, SQL_FLOAT, SQL_REAL, SQL_DOUBLE:
                    begin
                      desc_scale:=0;
                      case desc_type of
                        SQL_INTEGER: desc_precision:=10;
                        SQL_SMALLINT: desc_precision:=5;
                        SQL_FLOAT:    desc_precision:=15;
                        SQL_DOUBLE:   desc_precision:=15;
                        SQL_REAL:     desc_precision:=7;
                      end; {case}
                      desc_length:=desc_precision;
                    end; {numeric}

                    //Note: datetime/interval complications taken from standard, not ODBC
                    SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                    SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
                    SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
                    SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                    begin
                      {Split the Type into (Major) Type and (Sub-type) IntervalCode, e.g. 103 = 10 and 3}
                      desc_datetime_interval_code:=desc_type-((desc_type div 10){=SQL_DATETIME or SQL_INTERVAL}*10);
                      desc_length:=desc_precision; //todo reset precision & scale?

                      {SQL_DESC_PRECISION}
                      case desc_type of
                        SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                        SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                        begin
                          desc_precision:=desc_scale;
                        end;
                      else
                        desc_precision:=0;
                      end; {case SQL_DESC_PRECISION}

                      {SQL_DESC_DATETIME_INTERVAL_PRECISION}
                      case desc_type of
                        SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
                          {no SQL_DESC_DATETIME_INTERVAL_PRECISION} ;
                        SQL_INTERVAL_YEAR_TO_MONTH, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_HOUR_TO_MINUTE:
                        begin //columnSize-4
                          desc_datetime_interval_precision:=desc_precision-4;
                        end;
                        SQL_INTERVAL_DAY_TO_MINUTE:
                        begin //columnSize-7
                          desc_datetime_interval_precision:=desc_precision-7;
                        end;
                        SQL_INTERVAL_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-2
                          else
                            desc_datetime_interval_precision:=desc_precision-1;
                        end;
                        SQL_INTERVAL_DAY_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-11
                          else
                            desc_datetime_interval_precision:=desc_precision-10;
                        end;
                        SQL_INTERVAL_HOUR_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-8
                          else
                            desc_datetime_interval_precision:=desc_precision-7;
                        end;
                        SQL_INTERVAL_MINUTE_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-5
                          else
                            desc_datetime_interval_precision:=desc_precision-4;
                        end;
                      else //columnSize-1
                        desc_datetime_interval_precision:=desc_precision-1;
                      end; {case SQL_DESC_DATETIME_INTERVAL_PRECISION}

                      {Now we can set the verbose type}
                      desc_type:=(desc_type div 10){=SQL_DATETIME or SQL_INTERVAL};
                    end; {datetime/interval}

                    SQL_CHAR, SQL_VARCHAR, {SQL_BIT, SQL_BIT_VARYING not standard,}
                    SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
                    SQL_LONGVARCHAR{todo debug test...remove?}:
                    begin
                      desc_length:=desc_precision;
                      {Temporary fix to workaround ODBC express errors - todo **** get server to return better limit!}
                      if (desc_length=0) and (desc_type=SQL_VARCHAR) then desc_length:=MAX_VARCHAR_TEMP_FIX;
                    end; {other}
                  else
                    //todo error?! - or just set type instead?
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ssHY004,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end; {case}
                end; {with}
              end
              else
              begin
                //error, skip this column: need to consume the rest of this column definition anyway -> sink
                //todo or, could abort the whole routine instead?
                //note: currently getRecord cannot fail!
                {$IFDEF DEBUGDETAIL}
                log(format('SQLExecute failed getting desc record %d - rest of column defs abandoned...',[rn])); //todo debug error only - remove
                {$ENDIF}              
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit; //todo: just for now!
              end;

              inc(i);
            end; {while}
          end;
          //else no late result set: leave as was
        end;
        //else young server cannot handle this

        case resultCode of
          SQL_SUCCESS, SQL_SUCCESS_WITH_INFO:
          begin
            //todo get rowCount
            //todo get command-type & store locally somewhere...
            //todo if update/delete affected 0 rows, we need to return SQL_NO_DATA

            //we SQLendTran now if in autocommit mode & if not select/result-set
            //todo remove old Note: the (serious) side-effect of this is that any existing open cursors will be closed!
            //Note: any existing open cursors will be left open in this case
            if not s.resultSet and (s.owner as Tdbc).autocommit then
            begin
              {$IFDEF DEBUGDETAIL}
              log('SQLExecute autocommitting...');
              {$ENDIF}
              if SQLEndTran(SQL_HANDLE_DBC,SQLHANDLE(s.owner as Tdbc),SQL_COMMIT)<>SQL_SUCCESS then
              begin //should never happen: what about state if it does?
                result:=SQL_ERROR;
                //todo: improve/remove the following error: SQLEndTran failure would have added errors to dbc already
                s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
            end;

            case s.state of
              S2: s.state:=S4; //no results //todo improve test: use s.resultSet...?
              S3: begin //results
                    s.state:=S5;
                    s.cursor.state:=csOpen;
                    if s.cursor.name='' then s.cursor.name:=GetDefaultCursorName; //todo check right place to do this
                  end;
              S4: if s.resultSet then s.state:=S5 else s.state:=S4;
            else
              //todo assertion!
            end; {case}

            {Also might affect the connection state}
            case (s.owner as Tdbc).state of
              C5: if (s.owner as Tdbc).autoCommit then
                  begin
                    if s.resultSet then (s.owner as Tdbc).state:=C6;
                  end
                  else
                  begin
                    (s.owner as Tdbc).state:=C6;
                  end;
            end; {case}

          end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
          SQL_NEED_DATA:
          begin
            if s.prepared then //Note: could be called from SQLexecDirect so behaves as if prepared...
            begin
              {Get the next missing parameter reference from the server}
              getSQLSMALLINT(rn);
              {but we can't return it to the user here - they must call SQLParamData to get it}
              //todo could save 1st call to SQLparamData from contacting server!!!! - speed
              s.state:=S8;
            end
            else
            begin //should never happen unless caller doesn't know the rules, but then how could we get to need data if we weren't prepared?
              result:=SQL_ERROR;
              s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
          end; {SQL_NEED_DATA}
          SQL_STILL_EXECUTING:
          begin
            s.state:=S11;
          end; {SQL_STILL_EXECUTING}
          SQL_ERROR:
          begin
            if s.prepared then //Note: could be called from SQLexecDirect so caller will need to move from S2 to S1
              s.state:=S2
            else
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
          end; {SQL_ERROR}
        else
          //todo what if SQL_ERROR?
          //(else) should never happen!?
        end; {case}
      end; {with}
    end; {S2..S3,S4}
(*
    S4:
    begin
      //todo 2,4,5,8,11 or error
    end; {S4}
*)
    S5..S7:
    begin //cursor states
      if s.prepared then
      begin
        //todo if S6 then only if sqlFetch/FetchScroll returned No_data
        result:=SQL_ERROR;
        s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end
      else
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
    end; {S5..S7}
    S8..S10:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S8..S10}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLExecute}

///// SQLFetch /////

function SQLFetch  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLFetch called %d',[StatementHandle]));
  {$ENDIF}
  result:=SQLFetchScroll(StatementHandle,SQL_FETCH_NEXT,0{ignored});
end; {SQLFetch}

(*obsolete
///// SQLFreeConnect /////

function SQLFreeConnect  (ConnectionHandle:HDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  log('SQLFreeConnect called');
  result:=SQL_SUCCESS;
end;
*)
(*
///// SQLFreeEnv /////

function SQLFreeEnv  (arg0:HENV):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  log('SQLFreeEnv called');
  result:=SQL_SUCCESS;
end;
*)

///// SQLFreeStmt /////

function SQLFreeStmt  (StatementHandle:SQLHSTMT;
		 Option:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  i:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLFreeStmt called %d %d',[StatementHandle,Option]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  //todo this handle check is not working as it should(?prove): applies to all handle checks!
  //- odbcTest frees stmt and then closes and unbinds it!!! - leave = app error! & server should catch...
  //but we should be able to spot this kind of garbage given to us...
  // we should search current list of stmts instead (but for which connections/envs?)
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  if s.state in [S8..S12] then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  case Option of
    SQL_CLOSE:
    begin
      case s.state of
        //todo unprepare if we have prepared... not in ODBC diagram?
        //...so maybe merge S4 onto S5..S7 below & let server decide?
        // - if we do, note that S4 if prepared should goto S2 not S3
        S4:
        begin
          if s.prepared then
            s.state:=S2 {prepared}
          else
            s.state:=S1; {not prepared}
        end;
        S5..S7:
        begin
          result:=SQLCloseCursor(StatementHandle); //Note: this might call SQLEndTran if autocommit

          (*todo remove:
          //This code is taken from SQLCloseCursor:
          {call server SQLCloseCursor}
          //todo Replace all AS with casts - speed
          with (s.owner as Tdbc).Marshal do
          begin
            ClearToSend;
            {Note: because we know these marshalled parameters all fit in a buffer together,
             and because the buffer is now empty after the clearToSend,
             we can omit the error result checking in the following put() calls = speed
            }
            putFunction(SQL_API_SQLCLOSECURSOR);
            putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
            if s.prepared then putSQLSMALLINT(0) else putSQLSMALLINT(1);
            if Send<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;

            {Wait for response}
            if Read<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
            {Note: because we know these marshalled parameters all fit in a buffer together,
             and because the buffer has been read in total by the Read above because its size was known,
             we can omit the error result checking in the following get() calls = speed
            }
            getFunction(functionId);
            if functionId<>SQL_API_SQLCLOSECURSOR then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
              exit;
            end;
            getRETCODE(resultCode);
            result:=resultCode; //pass it on
            {$IFDEF DEBUGDETAIL}
            log(format('SQLFreeStmt (SQL_CLOSE) returns %d',[resultCode]));
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
                  seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
                  seNotPrepared:           resultState:=ssHY010;
                else
                  resultState:=ss08001; //todo more general failure needed/possible?
                end; {case}
                s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
                if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
              end;
            end;
            case resultCode of
              SQL_SUCCESS:
              begin
                s.cursor.state:=csClosed;
                //todo should we reset the cursor name as well? - maybe a future cursor.close method will handle all the details?
                if s.prepared then
                  s.state:=S3 {prepared}
                else
                  s.state:=S1; {not prepared}
              end; {SQL_SUCCESS}
            else
              //todo what if SQL_ERROR?
              //- todo continue anyway?
              //(else) should never happen!?
            end; {case}
          end; {with}
          *)
        end; {S5..S7}
      //else we don't report an error - SQLCloseCursor would
      end; {case}
    end; {SQL_CLOSE}
    //SQL_DROP is deprecated - driver manager calls FreeHandle instead
    //- although I think we should implement it to comply with ODBC core level
    SQL_UNBIND:
    begin
      {Unbind any bound columns}
      //todo to save traffic to server, we should implement server.unbind to reset its bind-map array
      for i:=1 to s.ard.desc_count do
      begin
        result:=SQLSetDescField(SQLHDESC(s.ard),i,SQL_DESC_DATA_POINTER,nil,00);
        if result=SQL_ERROR then exit; //todo should probably continue, but retain any error
      end;
      {De-allocate the bindings} //todo check we should do this...
      s.ard.desc_count:=0;
      s.ard.PurgeRecords; //todo check result?
    end; {SQL_UNBIND}
    SQL_RESET_PARAMS:
    begin
      {Unbind any bound parameters}
      for i:=1 to s.apd.desc_count do
      begin
        result:=SQLSetDescField(SQLHDESC(s.apd),i,SQL_DESC_DATA_POINTER,nil,00); //todo: no real need? just set count=0 below?
        if result=SQL_ERROR then exit; //todo should probably continue, but retain any error
      end;
      {De-allocate the bindings} //todo check we should do this...
      s.apd.desc_count:=0;
      s.apd.PurgeRecords; //todo check result?
    end; {SQL_RESET_PARAMS}
  else
    {$IFDEF DEBUGDETAIL}
    log(format('SQLFreeStmt called with unknown option: %d',[Option]));
    {$ENDIF}
  end; {case}
end; {SQLFreeStmt}

///// SQLGetCursorName /////

function SQLGetCursorName  (StatementHandle:SQLHSTMT;
		 CursorName:pUCHAR;
		 BufferLength:SWORD;
		 NameLength:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetCursorName called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  strLcopy(pUCHAR(CursorName),pchar(s.cursor.name),BufferLength-1);
  NameLength^:=length(s.cursor.name);
end; {SQLGetCursorName}

///// SQLNumResultCols /////

function SQLNumResultCols  (StatementHandle:SQLHSTMT;
		 ColumnCount:{UNALIGNED} pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLNumResultCols called %d',[StatementHandle]));
  {$ENDIF}

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  if (s.state<=S1) or (s.state>=S8) then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo go via getDescField instead - more checks/safer/more portable/maintainable?
  SWORD(ColumnCount^):=s.ird.desc_count;

  result:=SQL_SUCCESS;
end; {SQLNumResultCols}

///// SQLPrepare /////

function SQLPrepare  (StatementHandle:SQLHSTMT;
		 StatementText:pUCHAR;
		 TextLength:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

//todo remove  planHandle:SQLHSTMT;
  resSet:SQLUSMALLINT;

  tempNull:SQLSMALLINT;

  colCount:SQLINTEGER;  //todo word ok?
  paramCount:SQLINTEGER; //todo work would be ok?
  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;
  dr:TdescRec;
//todo remove  tempsw:SWORD;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLPrepare called %d %s',[StatementHandle,StatementText]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  s.diagnostic.clear; //todo check

  {Fix string lengths}
  if FixStringSDWORD(StatementText,TextLength)<>ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  case s.state of
    S1,S2..S3,S4:
    begin
      {call server prepare}
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLPREPARE);
        putSQLHSTMT(s.ServerStatementHandle);
        if putpUCHAR_SDWORD(StatementText,TextLength)<>ok then
        begin //todo assert sql length is small enough beforehand! //todo in future can split over buffers... //todo until then set MAX_STMT_LENGTH for client to inquire upon
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLPREPARE then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {if error, then get error details: local-number, default-text}
        if getSQLINTEGER(resultErrCode)<>ok then exit; //error count 
        if resultCode=SQL_ERROR then
        begin
          for err:=1 to resultErrCode do
          begin
            if getSQLINTEGER(resultErrCode)<>ok then exit;
            if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
            case resultErrCode of
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seSyntax:                resultState:=ss42000;
              seSyntaxUnknownColumn:   resultState:=ss42S22;
              seSyntaxAmbiguousColumn: resultState:=ss42000; //todo: be more specific ss42S22?
              seSyntaxLookupFailed:    resultState:=ssHY000;
              sePrivilegeFailed:       resultState:=ss42000;
              seSyntaxUnknownTable:    resultState:=ss42S02;
              seSyntaxUnknownSchema:   resultState:=ss42000; //todo: be more specific 3F000?
            else
              resultState:=ssHY000;
            end; {case}
            s.diagnostic.logError(ss42000,resultErrCode,resultErrText,SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        //todo remove getSQLHSTMT(planHandle);
        getSQLUSMALLINT(resSet);
        {Remember this for future state changes}
        if resSet=SQL_TRUE then s.resultSet:=True else s.resultSet:=False;

        {$IFDEF DEBUGDETAIL}
        log(format('SQLPrepare returns %d %d',[resultCode,resSet]));
        {$ENDIF}
        if resultCode=SQL_ERROR {todo and any other bad return value possible: use case?} then
        begin
          //todo remove-done above: s.diagnostic.logError(ss42000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo too vague! todo correct?pass details! //todo check result
          //todo maybe server should send details along...
          s.state:=S1; //in case we entered as S2..S3,S4 (todo unless error was HY009 or HY090) //todo: if s.state=S4 then only if last result of multiple
          exit;
        end;
        //todo remove! s.ServerStatementHandle:=planHandle; //store server's handle for future calls
        //todo I think we should store the StatementText against the stmt - may need later...
        // - although may be obtainable from server later?
        s.prepared:=True; //used for future FSM state changes
        if s.resultSet then
        begin
          s.cursor.state:=csOpen;
          s.state:=S3; //todo: if s.state=S4 then only if last result of multiple
          {Now get the IRD count & definitions}
          getSQLINTEGER(colCount);
          {$IFDEF DEBUGDETAIL}
          log(format('SQLPrepare returns %d IRD column defs',[colCount]));
          {$ENDIF}
          s.ird.desc_count:=colCount;
          //todo rest is switchable? - maybe can defer till needed?
          //todo now use get with result checking!!!
          i:=0;
          while i<=colCount-1 do
          begin
            //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
            if getSQLSMALLINT(rn)<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
            if s.ird.getRecord(rn,dr,True)=ok then
            begin
              with dr do
              begin
                {We first read the name, type, precision and scale
                 and then we make sure the correct parts of the descriptor are
                 set according to the type}
                if getpSQLCHAR_SWORD(desc_name,desc_name_SIZE,tempsw)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                if getSQLSMALLINT(desc_type)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;

                desc_concise_type:=desc_type; //todo check this is correct
                                              //note: we modify it below if datetime/interval
                                              //- bindParameter does this via calling SetDescField
                                              // - maybe we should also call it here to gain exactly
                                              //   the same side-effects?
                (* todo remove:
                {Now set the desc type properly to gain necessary side-effects}
                result:=SQLSetDescField(SQLHDESC(s.ird),rn,SQL_DESC_TYPE,SQLPOINTER(desc_type),SQL_IS_SMALLINT);
                //better to continue with bad type settings? //if result=SQL_ERROR then exit;
                *)

                if (s.owner as Tdbc).serverCLIversion>=0093 then
                begin
                  if getSQLINTEGER(desc_precision)<>ok then  //=server width
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                end
                else
                begin
                  if getSQLSMALLINT(tempNull)<>ok then  //=server width
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  desc_precision:=tempNull;
                end;
                (* todo - moved below
                //todo length, octet_length & display_size <- width?
                //for now, set length=precision - not valid for all types... use a dataConversion unit...
                desc_length:=desc_precision;
                if not(desc_type in [SQL_CHAR,SQL_VARCHAR]) or (desc_length=0) then
                begin
                  desc_length:=4; //todo desperate fix to try to please Delphi...(didn't work) - mend!
                end;
                *)
                if getSQLSMALLINT(desc_scale)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                if getSQLSMALLINT(desc_nullable)<>ok then
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                {$IFDEF DEBUGDETAIL}
                log(format('SQLPrepare read column definition: %s (%d)',[desc_name,desc_precision])); //todo debug only - remove
                {$ENDIF}

                {The following chunk of code is the inverse of the BindParameter logic
                 - check ok}
                 //todo it is copied below for the IPD...
                 // - so maybe we need a function that
                 //   sets the length,precision,scale,...interval_code/_precision,concise_type
                 //   based on the type?
                 //   Since we use the logic in 3 places already
                desc_datetime_interval_code:=0; //reset for all non-date/time types
                case desc_type of
                  SQL_NUMERIC, SQL_DECIMAL:
                    desc_length:=desc_precision;

                  SQL_INTEGER, SQL_SMALLINT, SQL_FLOAT, SQL_REAL, SQL_DOUBLE:
                  begin
                    desc_scale:=0;
                    case desc_type of
                      SQL_INTEGER: desc_precision:=10;
                      SQL_SMALLINT: desc_precision:=5;
                      SQL_FLOAT:    desc_precision:=15;
                      SQL_DOUBLE:   desc_precision:=15;
                      SQL_REAL:     desc_precision:=7;
                    end; {case}
                    desc_length:=desc_precision;
                  end; {numeric}

                  //Note: datetime/interval complications taken from standard, not ODBC
                  SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                  SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
                  SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
                  SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                  begin
                    {Split the Type into (Major) Type and (Sub-type) IntervalCode, e.g. 103 = 10 and 3}
                    desc_datetime_interval_code:=desc_type-((desc_type div 10){=SQL_DATETIME or SQL_INTERVAL}*10);
                    desc_length:=desc_precision; //todo reset precision & scale?

                    {SQL_DESC_PRECISION}
                    case desc_type of
                      SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                      SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                      begin
                        desc_precision:=desc_scale;
                      end;
                    else
                      desc_precision:=0;
                    end; {case SQL_DESC_PRECISION}

                    {SQL_DESC_DATETIME_INTERVAL_PRECISION}
                    case desc_type of
                      SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
                        {no SQL_DESC_DATETIME_INTERVAL_PRECISION} ;
                      SQL_INTERVAL_YEAR_TO_MONTH, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_HOUR_TO_MINUTE:
                      begin //columnSize-4
                        desc_datetime_interval_precision:=desc_precision-4;
                      end;
                      SQL_INTERVAL_DAY_TO_MINUTE:
                      begin //columnSize-7
                        desc_datetime_interval_precision:=desc_precision-7;
                      end;
                      SQL_INTERVAL_SECOND:
                      begin
                        if desc_scale<>0 then
                          desc_datetime_interval_precision:=desc_precision-desc_scale-2
                        else
                          desc_datetime_interval_precision:=desc_precision-1;
                      end;
                      SQL_INTERVAL_DAY_TO_SECOND:
                      begin
                        if desc_scale<>0 then
                          desc_datetime_interval_precision:=desc_precision-desc_scale-11
                        else
                          desc_datetime_interval_precision:=desc_precision-10;
                      end;
                      SQL_INTERVAL_HOUR_TO_SECOND:
                      begin
                        if desc_scale<>0 then
                          desc_datetime_interval_precision:=desc_precision-desc_scale-8
                        else
                          desc_datetime_interval_precision:=desc_precision-7;
                      end;
                      SQL_INTERVAL_MINUTE_TO_SECOND:
                      begin
                        if desc_scale<>0 then
                          desc_datetime_interval_precision:=desc_precision-desc_scale-5
                        else
                          desc_datetime_interval_precision:=desc_precision-4;
                      end;
                    else //columnSize-1
                      desc_datetime_interval_precision:=desc_precision-1;
                    end; {case SQL_DESC_DATETIME_INTERVAL_PRECISION}

                    {Now we can set the verbose type}
                    desc_type:=(desc_type div 10){=SQL_DATETIME or SQL_INTERVAL};
                  end; {datetime/interval}

                  SQL_CHAR, SQL_VARCHAR, {SQL_BIT, SQL_BIT_VARYING not standard,}
                  SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
                  SQL_LONGVARCHAR{todo debug test...remove?}:
                  begin
                    desc_length:=desc_precision;
                    {Temporary fix to workaround ODBC express errors - todo **** get server to return better limit!}
                    if (desc_length=0) and (desc_type=SQL_VARCHAR) then desc_length:=MAX_VARCHAR_TEMP_FIX;
                  end; {other}
                else
                  //todo error?! - or just set type instead?
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ssHY004,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end; {case}
              end; {with}
            end
            else
            begin
              //error, skip this column: need to consume the rest of this column definition anyway -> sink
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUGDETAIL}
              log(format('SQLPrepare failed getting desc record %d - rest of column defs abandoned...',[rn])); //todo debug error only - remove
              {$ENDIF}              
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit; //todo: just for now!
            end;

            inc(i);
          end; {while}
        end
        else //no result set
        begin
          s.state:=S2; //todo: if s.state=S4 then only if last result of multiple
        end; {result set check}

        {Now get the IPD count & definitions}
        getSQLINTEGER(paramCount);
        {$IFDEF DEBUGDETAIL}
        log(format('SQLPrepare returns %d IPD parameter defs',[paramCount]));
        {$ENDIF}
        s.ipd.desc_count:=paramCount;
        //todo now use get with result checking!!!
        i:=0;
        while i<=paramCount-1 do
        begin
          //todo maybe server should sort by param-ref before sending?, although we sort here via getRecord...
          if getSQLSMALLINT(rn)<>ok then
          begin
            result:=SQL_ERROR;
            s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
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
          if s.ipd.getRecord(rn,dr,True)=ok then
          begin
            with dr do
            begin
              {We first read the name, type, precision and scale
               and then we make sure the correct parts of the descriptor are
               set according to the type}
              if getpSQLCHAR_SWORD(desc_name,desc_name_SIZE,tempsw)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              //todo get desc_base_column_name as well...and catalog,schema,table!
              if getSQLSMALLINT(desc_type)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;

              desc_concise_type:=desc_type; //todo check this is correct
                                            //note: we should modify it below if datetime/interval
                                            //- bindParameter does this via calling SetDescField
                                            // - maybe we should also call it here to gain
                                            //   the same side-effects?

              if (s.owner as Tdbc).serverCLIversion>=0093 then
              begin
                if getSQLINTEGER(desc_precision)<>ok then  //=server width
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
              end
              else
              begin
                if getSQLSMALLINT(tempNull)<>ok then  //=server width
                begin
                  result:=SQL_ERROR;
                  s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                  exit;
                end;
                desc_precision:=tempNull;
              end;
              (*todo remove - moved logic below
              //todo length, octet_length & display_size <- width?
              //for now, set length=precision - not valid for all types... use a dataConversion unit...
              desc_length:=desc_precision;
              if not(desc_type in [SQL_CHAR,SQL_VARCHAR]) or (desc_length=0) then
              begin
                desc_length:=4; //todo desperate fix to try to please Delphi...(didn't work) - mend!
              end;
              *)
              if getSQLSMALLINT(desc_scale)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              if getSQLSMALLINT(desc_nullable)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              {$IFDEF DEBUGDETAIL}
              log(format('SQLPrepare read parameter definition: %s (%d)',[desc_name,desc_precision])); //todo debug only - remove
              {$ENDIF}

              {The following chunk of code is the inverse of the BindParameter logic
               - check ok}
              case desc_type of
                SQL_NUMERIC, SQL_DECIMAL:
                  desc_length:=desc_precision;

                SQL_INTEGER, SQL_SMALLINT, SQL_FLOAT, SQL_REAL, SQL_DOUBLE:
                begin
                  desc_scale:=0;
                  case desc_type of
                    SQL_INTEGER: desc_precision:=10;
                    SQL_SMALLINT: desc_precision:=5;
                    SQL_FLOAT:    desc_precision:=15;
                    SQL_DOUBLE:   desc_precision:=15;
                    SQL_REAL:     desc_precision:=7;
                  end; {case}
                  desc_length:=desc_precision;
                end; {numeric}

                //Note: datetime/interval complications taken from standard, not ODBC
                {SQL_DATETIME? todo possible? , SQL_INTERVAL? todo possible?}
                SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
                SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
                SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                begin
                  {Split the Type into (Major) Type and (Sub-type) IntervalCode, e.g. 103 = 10 and 3}
                  desc_datetime_interval_code:=desc_type-((desc_type div 10){=SQL_DATETIME or SQL_INTERVAL}*10);
                  desc_length:=desc_precision; //todo reset precision & scale?

                  {SQL_DESC_PRECISION}
                  case desc_type of
                    SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                    SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                    begin
                      desc_precision:=desc_scale;
                    end;
                  else
                    desc_precision:=0;
                  end; {case SQL_DESC_PRECISION}

                  {SQL_DESC_DATETIME_INTERVAL_PRECISION}
                  case desc_type of
                    SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
                      {no SQL_DESC_DATETIME_INTERVAL_PRECISION} ;
                    SQL_INTERVAL_YEAR_TO_MONTH, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_HOUR_TO_MINUTE:
                    begin //columnSize-4
                      desc_datetime_interval_precision:=desc_precision-4;
                    end;
                    SQL_INTERVAL_DAY_TO_MINUTE:
                    begin //columnSize-7
                      desc_datetime_interval_precision:=desc_precision-7;
                    end;
                    SQL_INTERVAL_SECOND:
                    begin
                      if desc_scale<>0 then
                        desc_datetime_interval_precision:=desc_precision-desc_scale-2
                      else
                        desc_datetime_interval_precision:=desc_precision-1;
                    end;
                    SQL_INTERVAL_DAY_TO_SECOND:
                    begin
                      if desc_scale<>0 then
                        desc_datetime_interval_precision:=desc_precision-desc_scale-11
                      else
                        desc_datetime_interval_precision:=desc_precision-10;
                    end;
                    SQL_INTERVAL_HOUR_TO_SECOND:
                    begin
                      if desc_scale<>0 then
                        desc_datetime_interval_precision:=desc_precision-desc_scale-8
                      else
                        desc_datetime_interval_precision:=desc_precision-7;
                    end;
                    SQL_INTERVAL_MINUTE_TO_SECOND:
                    begin
                      if desc_scale<>0 then
                        desc_datetime_interval_precision:=desc_precision-desc_scale-5
                      else
                        desc_datetime_interval_precision:=desc_precision-4;
                    end;
                  else //columnSize-1
                    desc_datetime_interval_precision:=desc_precision-1;
                  end; {case SQL_DESC_DATETIME_INTERVAL_PRECISION}

                  desc_type:=(desc_type div 10){=SQL_DATETIME or SQL_INTERVAL};
                end; {datetime/interval}

                SQL_CHAR, SQL_VARCHAR, {SQL_BIT, SQL_BIT_VARYING not standard,}
                SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
                SQL_LONGVARCHAR{todo debug test...remove?}:
                begin
                  desc_length:=desc_precision;
                  {Temporary fix to workaround ODBC express errors - todo **** get server to return better limit!}
                  if (desc_length=0) and (desc_type=SQL_VARCHAR) then desc_length:=MAX_VARCHAR_TEMP_FIX;
                end; {other}
              else
                //todo error?! - or just set type instead?
                result:=SQL_ERROR;
                s.diagnostic.logError(ssHY004,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end; {case}
            end; {with}
          end
          else
          begin
            //error, skip this parameter: need to consume the rest of this parameter definition anyway -> sink
            //todo or, could abort the whole routine instead?
            //note: currently getRecord cannot fail!
            {$IFDEF DEBUGDETAIL}
            log(format('SQLPrepare failed getting desc record %d - rest of parameter defs abandoned...',[rn])); //todo debug error only - remove
            {$ENDIF}            
            result:=SQL_ERROR;
            s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
            exit; //todo: just for now!
          end;

          inc(i);
        end; {while}

      end; {with}
    end; {S1,S2..S3,S4}
(*todo remove- merged with S1 to allow re-prepare
    S2,S3:
    begin
      //todo should re-call server prepare!
      //todo unprepare(?) or leave to server=better since server memory involved...?
      //some state changes if fails //todo
    end; {S2,S3}
    S4:
    begin
      //todo 1,2,3,11 or error
    end; {S4}
*)
    S5..S7:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S5..S7}
    S8..S10:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S8..S10}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLPrepare}

///// SQLRowCount /////

function SQLRowCount  (StatementHandle:SQLHSTMT;
		 RowCount:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLRowCount called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  RowCount^:=s.rowCount;
end; {SQLRowCount}

///// SQLSetCursorName /////

function SQLSetCursorName  (StatementHandle:SQLHSTMT;
		 CursorName:pUCHAR;
		 NameLength:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetCursorName called %d %s',[StatementHandle,CursorName]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  {Fix string lengths}
  if FixStringSWORD(CursorName,NameLength)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo check cursor is open/ready for a name... check spec.
  s.cursor.name:=CursorName;
end; {SQLSetCursorName}
(*
///// SQLSetParam /////

RETCODE SQL_API SQLSetParam  (HSTMT arg0,
		 UWORD arg1,
		 SWORD arg2,
		 SWORD arg3,
		 UDWORD arg4,
		 SWORD arg5,
		 PTR arg6,
		 UNALIGNED SDWORD * arg7)
{
	log("SQLSetParam called\n");
	return(SQL_SUCCESS);
}

///// SQLTransact /////

RETCODE SQL_API SQLTransact  (HENV arg0,
		 HDBC arg1,
		 UWORD arg2)
{
	log("SQLTransact called\n");
	return(SQL_SUCCESS);
}
*)

function PatternWhere(odbcVersion:SQLINTEGER;const s:string):string;
{Creates a Where clause for a pattern search string
 IN:       odbcVersion      the ODBC version (2 = no patterns allowed)
           s                the column value to search for

 Returns:  (with any escaped wildcard characters removed)
           LIKE '%' if s=''
           or
           ='s' if no wildcards (LIKE_ONE,LIKE_ALL) or ODBC version 2
           or
           LIKE 's' if wildcards
           e.g. TABLE\_NAME  ->  ='TABLE_NAME'
                TABLE_NAME   ->  LIKE 'TABLE_NAME'
                TABLE%       ->  LIKE 'TABLE%'
                TABLE\%      ->  ='TABLE%'

 Note: we ignore LIKE_ONE (_) for now since it's so commonly not escaped by callers! (27/01/02)
       todo: fix... client bug really? maybe check if they've asked about our escape character - most don't!
}
var
  i:integer;
  patterned:boolean;
begin
  //todo if stmt.metadataId=True then search patterns are not accepted

  if s='' then
  begin
    result:='LIKE '''+LIKE_ALL+''' ';
    exit;
  end;

  (*removed for now: winSQL was passing table_name as '%' with ver=2
  if odbcVersion=SQL_OV_ODBC2 then
  begin
    result:='='''+s+''' ';
  end
  else
  *)
  begin
    result:='';
    patterned:=False;
    i:=1;
    while i<=length(s) do
    begin
      if (s[i]=SEARCH_PATTERN_ESCAPE) and (i<length(s)) and ((s[i+1]=LIKE_ALL) or (s[i+1]=LIKE_ONE)) then //assumes boolean short-circuiting
        inc(i) //skip escape character
      else
        if (s[i]=LIKE_ALL) {todo reinstate: or (s[i]=LIKE_ONE)} then patterned:=True; //was not escaped

      result:=result+s[i];
      inc(i);
    end;

    if patterned then
      result:='LIKE '''+result+''' '
    else
      result:='='''+result+''' ';
  end;
end; {PatternWhere}
function OverrideWhere(const w:string;const s:string):string;
{Overrides a 'LIKE 'LIKE_ALL'' Where clause created from PatternWhere with a =replacement search string
 IN:       w      the result of PatternWhere
           s      the replacement where clause =string

 Example use:
     if a schemaName pattern is '', it should be replaced with schema_name=CURRENT_SCHEMA
     so wrap the patternWhere call result in an OverrideWhere
}
begin
  if w='LIKE '''+LIKE_ALL+''' ' then
    result:='='+s  //replace
  else
    result:=w; //leave
end; {OverrideWhere}

///// SQLColumns /////

function SQLColumns  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD;
		 ColumnName:pUCHAR;
		 NameLength4:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

//  catPattern, schemPattern, tablePattern, columnPattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLColumns called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(ColumnName,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName else tablePattern:=SQL_ALL_TABLES;
  if ColumnName<>'' then columnPattern:=ColumnName else columnPattern:=SQL_ALL_COLUMNS;
  *)

  (*todo remove?
  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLColumns called with embedded ., %s',[tablePattern]));
    {$ENDIF}
    //todo: really should move left portion to schemPattern...
//todo!    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
  *)

(*todo remove old version
  //todo improve!
  //todo use just one Information_schema view! especially since catalog_def_schema will be invisible
  query:='SELECT '+
         'catalog_name AS TABLE_CAT, '+
         'schema_name AS TABLE_SCHEM, '+
         'table_name AS TABLE_NAME, '+
         'column_name AS COLUMN_NAME, '+
         'DATA_TYPE, '+
         'TYPE_NAME, '+
         'COLUMN_SIZE, '+
         'width AS BUFFER_LENGTH, '+
         'scale AS DECIMAL_DIGITS, '+
         'NUM_PREC_RADIX, '+
         'null AS REMARKS, '+
         '"default" AS COLUMN_DEF, '+    //todo rename "default" on server = easier to handle
         'SQL_DATA_TYPE, '+
         'SQL_DATETIME_SUB, '+
         'width AS CHAR_OCTET_LENGTH, '+
         'column_id AS ORDINAL_POSITION, '+
         'nulls AS IS_NULLABLE, '+
         'null AS CHAR_SET_CAT, '+       //todo fix the following...
         'null AS CHAR_SET_SCHEM, '+
         'null AS CHAR_SET_NAME, '+
         'null AS COLLATION_CAT, '+
         'null AS COLLATION_SCHEM, '+
         'null AS COLLATION_NAME '+
         'FROM '+
         '  ((('+catalog_definition_schemaName+'.sysColumn natural join '+information_schemaName+'.TYPE_INFO) '+
         '     natural join '+catalog_definition_schemaName+'.sysTable) natural join '+catalog_definition_schemaName+'.sysSchema) '+
         '     natural join '+catalog_definition_schemaName+'.sysCatalog '+
         'WHERE '+
         'catalog_name LIKE '''+catPattern+''' '+
         'AND schema_name LIKE '''+schemPattern+''' '+
         'AND table_name LIKE '''+tablePattern+''' '+
         'AND column_name LIKE '''+columnPattern+''' '+
         '; ';
*)

(*todo re-instate when SARGs are passed into sub-selects...
  query:='SELECT '+
         '  TABLE_CATALOG AS table_cat, '+
//todo         '  '''' AS table_cat, '+
//todo         '  '''' AS table_schem, '+
         '  TABLE_SCHEMA AS table_schem, '+
         '  TABLE_NAME, '+
         '  COLUMN_NAME, '+
         '  CASE DATA_TYPE '+
         '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
         '    WHEN ''NUMERIC'' THEN 2 '+
         '    WHEN ''DECIMAL'' THEN 3 '+
         '    WHEN ''INTEGER'' THEN 4 '+
         '    WHEN ''SMALLINT'' THEN 5 '+
         '    WHEN ''FLOAT'' THEN 6 '+
         '    WHEN ''REAL'' THEN 7 '+
         '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
//todo remove         '    WHEN ''VARCHAR'' THEN 12 '+
         '    WHEN ''CHARACTER VARYING'' THEN 12 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  END AS DATA_TYPE, '+
         '  DATA_TYPE AS TYPE_NAME, '+
         '  CASE '+
         '    WHEN DATA_TYPE=''CHARACTER'' '+
//todo remove         '      OR DATA_TYPE=''VARCHAR'' '+
         '      OR DATA_TYPE=''CHARACTER VARYING'' '+
         //todo etc.
         '    THEN CHARACTER_MAXIMUM_LENGTH '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '      OR DATA_TYPE=''SMALLINT'' '+
         '      OR DATA_TYPE=''INTEGER'' '+
         '      OR DATA_TYPE=''REAL'' '+
         '      OR DATA_TYPE=''FLOAT'' '+
         '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
         '    THEN NUMERIC_PRECISION '+
         //todo etc.
         '  END AS COLUMN_SIZE, '+
         '  CHARACTER_OCTET_LENGTH AS BUFFER_LENGTH, '+
         '  CASE '+
         '    WHEN DATA_TYPE=''DATE'' '+
         //todo etc.
         '    THEN DATETIME_PRECISION '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '      OR DATA_TYPE=''SMALLINT'' '+
         '      OR DATA_TYPE=''INTEGER'' '+
         '    THEN NUMERIC_SCALE '+
         '  ELSE NULL '+
         '  END AS DECIMAL_DIGITS, '+
         '  NUMERIC_PRECISION_RADIX AS num_prec_radix, '+
         '  CASE '+
         '    WHEN IS_NULLABLE=''NO'' THEN 0 '+
         '    ELSE 1 '+
         '  END AS nullable, '+
         '  null AS remarks, '+
         '  COLUMN_DEFAULT AS COLUMN_DEF, '+
         '  CASE DATA_TYPE '+
         '    WHEN ''CHARACTER'' THEN 1'+
         '    WHEN ''NUMERIC'' THEN 2 '+
         '    WHEN ''DECIMAL'' THEN 3 '+
         '    WHEN ''INTEGER'' THEN 4 '+
         '    WHEN ''SMALLINT'' THEN 5 '+
         '    WHEN ''FLOAT'' THEN 6 '+
         '    WHEN ''REAL'' THEN 7 '+
         '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
//todo remove         '    WHEN ''VARCHAR'' THEN 12 '+
         '    WHEN ''CHARACTER VARYING'' THEN 12 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  END AS sql_data_type, '+
         '  CASE DATA_TYPE '+
         '    WHEN ''DATE'' THEN 1'+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  ELSE NULL '+
         '  END AS sql_datetime_sub, '+
         '  CHARACTER_OCTET_LENGTH AS char_octet_length, '+
         '  ORDINAL_POSITION, '+
         '  IS_NULLABLE, '+
         '  CHARACTER_SET_CATALOG AS char_set_cat, '+       //todo fix the following...
         '  CHARACTER_SET_SCHEMA AS char_set_schem, '+
         '  CHARACTER_SET_NAME AS char_set_name, '+
         '  COLLATION_CATALOG AS collation_cat, '+
         '  COLLATION_SCHEMA AS collation_schem, '+
         '  COLLATION_NAME '+
         //todo +UDT stuff for SQL3
         'FROM '+
         '  '+information_schemaName+'.COLUMNS '+
         'WHERE '+
         '  TABLE_CATALOG LIKE '''+catPattern+''' '+
         '  AND TABLE_SCHEMA LIKE '''+schemPattern+''' '+
         '  AND TABLE_NAME LIKE '''+tablePattern+''' '+
         '  AND COLUMN_NAME LIKE '''+columnPattern+''' '+
         'ORDER BY table_cat, table_schem, TABLE_NAME, ORDINAL_POSITION '+
         '; ';
*)

  if ((s.owner as Tdbc).owner as Tenv).odbcVersion=SQL_OV_ODBC2 then
  begin //return old-fashioned date/time types
    query:='SELECT '+
           '  catalog_name AS table_cat, '+
           '  schema_name AS table_schem, '+
           '  TABLE_NAME, '+
           '  COLUMN_NAME, '+
           '  CASE type_name '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS DATA_TYPE, '+
           '  TYPE_NAME, '+
           '  CASE '+
           '    WHEN type_name=''CHARACTER'' '+
           '      OR type_name=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN width '+
           '    WHEN type_name=''NUMERIC'' '+
           '      OR type_name=''DECIMAL'' '+
           '    THEN width '+
           '    WHEN type_name=''SMALLINT'' THEN 5 '+
           '    WHEN type_name=''INTEGER'' THEN 10 '+
           '    WHEN type_name=''REAL'' THEN 7 '+
           '    WHEN type_name=''FLOAT'' '+
           '      OR type_name=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN type_name=''DATE'' '+
           '    THEN 10 '+
           '    WHEN type_name=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+scale '+
           '    WHEN type_name=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+scale '+
           '    WHEN type_name=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+scale  '+
           '    WHEN type_name=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+scale '+
           '    WHEN type_name=''BINARY LARGE OBJECT'' '+
           '    THEN width '+
           '    WHEN type_name=''CHARACTER LARGE OBJECT'' '+
           '    THEN width '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  width AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN type_name=''DATE'' '+
           '      OR type_name=''TIME'' '+
           '      OR type_name=''TIMESTAMP'' '+
           '      OR type_name=''TIME WITH TIME ZONE'' '+
           '      OR type_name=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN scale '+
           '    WHEN type_name=''NUMERIC'' '+
           '      OR type_name=''DECIMAL'' '+
           '      OR type_name=''SMALLINT'' '+
           '      OR type_name=''INTEGER'' '+
           '    THEN scale '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUM_PREC_RADIX, '+
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           '  null AS remarks, '+
           '  "default" AS COLUMN_DEF, '+
           '  CASE type_name '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  NULL '+
           '  AS sql_datetime_sub, '+
           '  width AS char_octet_length, '+
           '  column_id AS ORDINAL_POSITION, '+
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           '  null AS char_set_cat, '+       //todo fix the following...
           '  null AS char_set_schem, '+
           '  null AS char_set_name, '+
           '  null AS collation_cat, '+
           '  null AS collation_schem, '+
           '  null '
           //todo +UDT stuff for SQL3
  end
  else //return standard v3 date/time types
  begin
    query:='SELECT '+
           '  catalog_name AS table_cat, '+
           '  schema_name AS table_schem, '+
           '  TABLE_NAME, '+
           '  COLUMN_NAME, '+
           '  CASE type_name '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 91 '+
           '    WHEN ''TIME'' THEN 92 '+
           '    WHEN ''TIMESTAMP'' THEN 93 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 94 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 95 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS DATA_TYPE, '+
           '  TYPE_NAME, '+
           '  CASE '+
           '    WHEN type_name=''CHARACTER'' '+
           '      OR type_name=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN width '+
           '    WHEN type_name=''NUMERIC'' '+
           '      OR type_name=''DECIMAL'' '+
           '    THEN width '+
           '    WHEN type_name=''SMALLINT'' THEN 5 '+
           '    WHEN type_name=''INTEGER'' THEN 10 '+
           '    WHEN type_name=''REAL'' THEN 7 '+
           '    WHEN type_name=''FLOAT'' '+
           '      OR type_name=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN type_name=''DATE'' '+
           '    THEN 10 '+
           '    WHEN type_name=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+scale '+
           '    WHEN type_name=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+scale '+
           '    WHEN type_name=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+scale  '+
           '    WHEN type_name=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+scale '+
           '    WHEN type_name=''BINARY LARGE OBJECT'' '+
           '    THEN width '+
           '    WHEN type_name=''CHARACTER LARGE OBJECT'' '+
           '    THEN width '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  width AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN type_name=''DATE'' '+
           '      OR type_name=''TIME'' '+
           '      OR type_name=''TIMESTAMP'' '+
           '      OR type_name=''TIME WITH TIME ZONE'' '+
           '      OR type_name=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN scale '+
           '    WHEN type_name=''NUMERIC'' '+
           '      OR type_name=''DECIMAL'' '+
           '      OR type_name=''SMALLINT'' '+
           '      OR type_name=''INTEGER'' '+
           '    THEN scale '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUM_PREC_RADIX, '+
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           '  null AS remarks, '+
           '  "default" AS COLUMN_DEF, '+
           '  CASE type_name '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 9 '+
           '    WHEN ''TIMESTAMP'' THEN 9 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  CASE type_name '+
           '    WHEN ''DATE'' THEN 1 '+
           '    WHEN ''TIME'' THEN 2 '+
           '    WHEN ''TIMESTAMP'' THEN 3 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 4 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 5 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  ELSE NULL '+
           '  END AS sql_datetime_sub, '+
           '  width AS char_octet_length, '+
           '  column_id AS ORDINAL_POSITION, '+
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           '  null AS char_set_cat, '+       //todo fix the following...
           '  null AS char_set_schem, '+
           '  null AS char_set_name, '+
           '  null AS collation_cat, '+
           '  null AS collation_schem, '+
           '  null '
           //todo +UDT stuff for SQL3
  end;

  query:=query+
         'FROM '+
//not optimised to use indexes yet, so takes over 1 minute when new!: speed
        '    '+information_schemaName+'.TYPE_INFO natural join'+
        '    '+catalog_definition_schemaName+'.sysColumn natural join'+
        '    '+catalog_definition_schemaName+'.sysTable natural join'+
        '    '+catalog_definition_schemaName+'.sysSchema natural join'+
        '    '+catalog_definition_schemaName+'.sysCatalog '+
         'WHERE '+
         '  schema_id<>1 '+ //todo replace 1 with constant for sysCatalog
         ' AND catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
         ' AND COLUMN_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,ColumnName)+
         'ORDER BY table_cat, table_schem, TABLE_NAME, ORDINAL_POSITION '+
         '; ';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLColumns}

{Support function for SQLDriverConnect (and will be used by configuration routines)
 //TODO move to a better/global? place
}
function parseNextKeywordValuePair(var kvps:string;var keyword:string;var value:string):boolean;
{Parses a keyword-value pair string to get the next pair
 IN:      kvps          the un-parsed keyword-value pair string
 OUT:     kvps          the remaining un-parsed keyword-value pair string
          keyword       the keyword of the next pair
          value         the value of the next pair
 RESULT:  true = next pair was available
          false = end - nothing more to parse

 Note:
   missing pairs are skipped, e.g. ';;A=B' will return the pair A,B - the empty pair is ignored
   an incomplete pair is not returned, e.g. 'A;C=D' will return the pair C,D - A is ignored
}
const
  ASSIGNMENT='=';
  SEPARATOR=';';
var
  gettingKeyword:boolean;
begin
  result:=false;
  keyword:='';
  value:='';
  gettingKeyword:=true;
  while kvps<>'' do
  begin
    case kvps[1] of
      ASSIGNMENT:
      begin
        if gettingKeyword then
        begin
          gettingKeyword:=False; //start getting value
        end
        else
        begin
          value:=value+kvps[1]; //part of value
        end;
      end; {ASSIGNMENT}
      SEPARATOR:
      begin
        if gettingKeyword then
        begin
          keyword:=''; //reset - end of partial/empty pair - skip over and start on next pair //todo log error if keyword was <>''?
        end
        else
        begin
          result:=True;
          kvps:=copy(kvps,2,length(kvps)); //reduce string by 1
          exit; //done!
        end;
      end; {SEPARATOR}
    else
      if gettingKeyword then
      begin
        keyword:=keyword+kvps[1];
      end
      else
      begin
        value:=value+kvps[1];
      end;
    end; {case}
    kvps:=copy(kvps,2,length(kvps)); //reduce string by 1
  end; {while more characters}

  if not gettingKeyword then result:=True; //we read the final pair at the end of the string
end; {parseNextKeywordValuePair}

///// SQLDriverConnect /////

function SQLDriverConnect  (hdbc:HDBC;
		 hWnd:HWND;
		 szConnStrIn:pUCHAR;
		 cbConnStrIn:SWORD;
		 szConnStrOut:pUCHAR;
		 cbConnStrOut:SWORD;
		 pcbConnStrOut:{UNALIGNED}pSWORD;
		 fDriverCompletion:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;

  kvps:string;
  keyword,value:string;

  tempUID, tempPWD, tempDSN:string;
  tempDRIVER:string;
  tempHOST,tempSERVICE,tempSERVER:string;

  done:boolean;

  frmConnect:TfrmConnect;

  retBuf:array [0..MAX_RETBUF-1] of char;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLDriverConnect called %d %s %x %d',[hdbc,szConnStrIn,longint(szConnStrOut),cbConnStrOut]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  c:=Tdbc(hdbc);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  (*todo remove
  // This really doesn't show nearly all that you need to know
  // about driver connect, read the programmer's reference

  if ((cbConnStrIn == SQL_NTS) && (szConnStrIn))
          cbConnStrIn = strlen(szConnStrIn);

  MessageBox(hWnd,
             "Connection dialog would go here",
             "Sample driver",
             MB_OK);

  if ((szConnStrOut) && cbConnStrOut > 0)
  {
          strncpy(szConnStrOut,
                  szConnStrIn,
                  (cbConnStrIn == SQL_NTS) ? cbConnStrOut - 1 :
                                          min(cbConnStrOut,cbConnStrIn));

          szConnStrOut[cbConnStrOut - 1] = '\0';
  }

  if (pcbConnStrOut)
          *pcbConnStrOut = cbConnStrIn;
  *)


  if fixStringSWORD(szConnStrIn,cbConnStrIn)<ok then
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  {Parse the connection string}
  kvps:=szConnStrIn;
  tempUID:='';
  tempPWD:='';
  tempDSN:='';
  tempDRIVER:='';
  tempHOST:='';
  tempSERVICE:='';
  tempSERVER:='';
  while parseNextKeywordValuePair(kvps,keyword,value) do
  begin
    keyword:=uppercase(trim(keyword));
    done:=False;

    {match keywords and use the value, unless it's already been specified - i.e. ignore duplicates & use 1st instance
     - todo this doesn't exactly match the spec. since 'UID=;UID=Second' would use Second (but 'UID=First;UID=Second' wouldn't at least)
    }
    if keyword=kUID then begin if tempUID='' then tempUID:=value; done:=true; end;
    if keyword=kPWD then begin if tempPWD='' then tempPWD:=value; done:=true; end;
    if keyword=kDSN then begin if tempDSN='' then tempDSN:=value; done:=true; end;

    if keyword=kDRIVER then begin if tempDRIVER='' then tempDRIVER:=value; done:=true; end;
    //todo more logic for driver/dsn...

    if keyword=kHOST then begin if tempHOST='' then tempHOST:=value; done:=true; end;
    if keyword=kSERVICE then begin if tempSERVICE='' then tempSERVICE:=value; done:=true; end;
    if keyword=kSERVER then begin if tempSERVER='' then tempSERVER:=value; done:=true; end;


    if not done then
    begin
      result:=SQL_SUCCESS_WITH_INFO;
      c.diagnostic.logError(ss01S00,fail,'',0,0); //todo check result
      //try to continue with connect
    end;
  end; {while more pairs}

  {Read the specified Datasource connection properties to augment the connection string}
  if tempDSN<>'' then //todo what if DEFAULT?
  begin
    if tempUID='' then
    begin
      if SQLGetPrivateProfileString(pchar(tempDSN),kUID,'DEFAULT',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:='';
      tempUID:=retBuf;
    end;
    if tempPWD='' then
    begin
      //todo: bug: shouldn't really get PWD if PWD was passed as ''
      if SQLGetPrivateProfileString(pchar(tempDSN),kPWD,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:='';
      tempPWD:=retBuf;
    end;
    if tempHOST='' then
    begin
      if SQLGetPrivateProfileString(pchar(tempDSN),kHOST,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:='';
      tempHOST:=retBuf;
    end;
    if tempSERVICE='' then
    begin
      if SQLGetPrivateProfileString(pchar(tempDSN),kSERVICE,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:='';
      tempSERVICE:=retBuf;
    end;
    if tempSERVER='' then
    begin
      if SQLGetPrivateProfileString(pchar(tempDSN),kSERVER,'',retBuf,sizeof(retBuf),INIfilename)=0 then
        retBuf:='';
      tempSERVER:=retBuf;
    end;
  end;

  //adding a dialog to this DLL seemed to add about 30k onto DLL size, but only 12k without bitBtns!
  if hWnd<>0 then
  begin
    if (fDriverCompletion=SQL_DRIVER_PROMPT) or ((tempUID='') or (tempPWD='')) then
    begin
      if fDriverCompletion=SQL_DRIVER_NOPROMPT then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08001,fail,'',0,0); //todo check result
        exit;
      end;

      frmConnect:=TfrmConnect.CreateParented(hWnd);
      try
        with frmConnect do
        begin
          //todo set form caption to DSN?
          Caption:=tempDSN;
          edUID.text:=tempUID;
          edPWD.text:=tempPWD;
          if tempUID<>'' then ActiveControl:=edPWD;
          if ShowModal<>1{todo 0 ok?- then don't need Windows unit: idOK} then
          begin
            result:=SQL_NO_DATA;
            exit;
          end;
          tempUID:=edUID.text;
          tempPWD:=edPWD.text;
        end; {with}
      finally
        frmConnect.free;
      end; {try}
    end;
  end
  else
    if fDriverCompletion=SQL_DRIVER_PROMPT then
    begin
      result:=SQL_ERROR;
      c.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
      exit;
    end;


  if (szConnStrOut<>nil) and (cbConnStrOut>0) then
  begin
    //todo we should build connection string from our now complete set of params!
    strLcopy(pUCHAR(szConnStrOut),szConnStrIn,cbConnStrOut-1);
    pcbConnStrOut^:=length(szConnStrIn);
  end;

  {If we were passed server details, use them now}
  if tempHOST<>'' then
    c.clientSocket.Host:=tempHOST;
  if tempSERVICE<>'' then
  try
    c.clientSocket.Port:=GStack.WSGetServByName(tempSERVICE);
  except
    c.clientSocket.Port:=0; //reset so SQLconnect will use default port
  end; {try}
  if tempSERVER<>'' then
    c.DSNserver:=tempSERVER;

  {Connect}
  result:=SQLConnect  (hdbc,
		 pchar(tempDSN),
		 length(tempDSN),
		 pchar(tempUID),
		 length(tempUID),
		 pchar(tempPWD),
		 length(tempPWD) );
end; {SQLDriverConnect}
(*
///// SQLGetConnectOption /////

RETCODE SQL_API SQLGetConnectOption  (HDBC arg0,
		 UWORD arg1,
		 PTR arg2)
{
	log("SQLGetConnectOption called\n");
	return(SQL_SUCCESS);
}
*)
///// SQLGetData /////

function SQLGetData  (StatementHandle:SQLHSTMT;
		 ColumnNumber:UWORD;
		 TargetType:SWORD;
		 TargetValue:PTR;
		 BufferLength:SDWORD;
		 StrLen_or_Ind:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{
 Notes:
   This passes every (valid) request to the server, so it's much more efficient
   to SQLBindCol the required columns once and then call SQLfetch/SQLfetchScroll than
   to call SQLgetData repeatedly inside a fetch loop.
   Instead we could have SQLfetchScroll bring back the entire row and then
   SQLgetData would be faster. The reasons we don't do this are:
     1. lots of extra network traffic/client memory allocation would be required
        for a feature that may never be used
        (& when we implement server-side cursors, we may be able to just materialise
         the bound columns?)
     2. SQLgetData should really only be used to get long-data
     3. Security: although the client must be privileged to select all the columns
        in the first place, an application may choose to restrict the bound
        columns based on the user. Pulling across all columns would allow
        network/memory hacking.
}
var
  s:Tstmt;

  adr,idr:TdescRec;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;
  tempsdw:SDWORD;

  dataPtr:SQLPOINTER;
  tempNull:SQLSMALLINT;

  BufferLen:SQLUINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetData called %d %d %d %p %d %p',[StatementHandle,ColumnNumber,TargetType,TargetValue,BufferLength,StrLen_or_Ind]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  case s.state of
    S1,S2,S3:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1,S2,S3}
    S4:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S4}
    S5:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S5}
    S6,S7:
    begin
      //todo may need to call a sub-routine to keep manageable

      //todo if desc_array_size>1 AND if forward-only cursor then we shouldn't be called...

      if (ColumnNumber<1) or (ColumnNumber>s.ird.desc_count) then
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;

      {Check the datatype is valid}
      if not isValidCtype(TargetType) then
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHY003,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;

      if BufferLength<0 then //SQL standard says <=0 //todo make switchable?
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHY090,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;

      //we will handle the SQL_GD_ANY_ORDER ODBC extension
      //- if we didn't, we would check:
      //    if last SQLgetData columnNumber<this one, then error 07009

      //we will handle the SQL_GD_ANY_COLUMN ODBC extension
      //- if we didn't, we would check:
      //    if this one is <= the last bound column (not ARD.desc_count!), then error 07009

      {We check that this column is not already bound.
       If it is we return an error according to the SQL spec. although the ODBC
       spec. lets us extend SQLGetData with SQL_GD_BOUND to allow getting of bound
       columns. We can easily handle this extension, but for now we won't simply
       because I can't see it being that useful for the price of subverting the SQL spec.
       And because it keeps early binding and late/dynamic binding distinct.
       (update: 18/12/02: blob chunking assumes no binding!)
      }
      if s.ard.getRecord(ColumnNumber,Adr,False{fail if it doesn't exist rather than auto-create})=ok then
      begin
        //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
        with Adr do
        begin
          if desc_data_ptr<>nil then
          begin //this column is already bound, error
            result:=SQL_ERROR;
            s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
            exit;
          end;

          //we will handle the SQL_GD_ANY_COLUMN and SQL_GD_ANY_ORDER ODBC extensions
          //- if we didn't, we would check:
          //  if desc_data_ptr=nil for any column before this one, then error 07009
        end; {with}
      end;
      //else must not be bound

      {Ok, now we can get the data}
      //todo (and elsewhere, e.g. bindParameter/col) we should check the TargetType is valid

      FixBufferLen(TargetType,BufferLength);  //todo maybe this should be earlier (in all uses) e.g. before we check bufferlength<0?

      {Note: this code is based on SQLFetchScroll code (although chunks have been removed),
       we just substitute our direct parameters for pre-bound ones
       //todo maybe ensure we keep in sync. by using a common sub-routine, e.g. getColData?
      }

      {call server getData}
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLGETDATA);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
        putSQLSMALLINT(ColumnNumber);
        if (s.owner as Tdbc).serverCLIversion>=0093 then
        begin //restrict result to client buffer size chunks: expect client to repeatedly call this routine
          (*todo remove: since we can now handle marshalling big buffers & QTODBC objects to us shrinking
                 what it expects to be filled...
          //todo assert BufferLength<marshalBufSize-sizeof(bufferLen)!!!!!!!!!!
          //- todo else we'd be responsible for using our smaller buffer size to fill the clients
          //-      maybe we should do this & it will be fine because client gets told what's left & status code...
          if BufferLength>(marshalBufSize-sizeof(bufferLen)) then
          begin
            {$IFDEF DEBUGDETAIL}
            log(format('SQLGetData buffer of %d is being reduced to %d to suit marshal buffer',[BufferLength,(marshalBufSize-sizeof(bufferLen))]));
            {$ENDIF}
            BufferLength:=(marshalBufSize-sizeof(bufferLen)); //todo check fits ok!
          end;
          *)
          BufferLen:=BufferLength; //cast
          putSQLUINTEGER(BufferLen);
          {$IFDEF DEBUGDETAIL}
          log(format('SQLGetData sent buffer size %d',[BufferLen]));
          {$ENDIF}
        end;
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLGETDATA then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        //resultCode comes later
        {retrieve any result data}

        {Read row count}
        getSQLUINTEGER(rowCount);
        //todo? assert rowCount=1 - only here to keep similar protocol as fetchScroll (& maybe future use)

        {$IFDEF DEBUGDETAIL}
        log(format('SQLGetData returns %d rows',[rowCount]));
        {$ENDIF}

        setStatusExtra:=0; //no conversion errors

        for row:=1 to rowCount do //todo remove- not needed, but no harm either...
        begin
          {Now get the col count & data for this row}
          getSQLINTEGER(colCount);
          //todo? again assert colCount=1 - only here to keep similar protocol as fetchScroll (& maybe future use)
          {$IFDEF DEBUGDETAIL}
          log(format('SQLGetData returns %d column data',[colCount]));
          {$ENDIF}
          //todo now use get with result checking!!!

          i:=0;
          while i<=colCount-1 do //todo remove- not needed, but no harm either...
          begin
            //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
            if getSQLSMALLINT(rn)<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;

            //todo assert than rn=ColumnNumber that we just sent!
            {$IFDEF DEBUGDETAIL}
            log(format('SQLGetData reading returned column %d (should be =%d)',[rn,ColumnNumber])); //todo debug only - remove!
            {$ENDIF}

            //todo use a get routine that doesn't add \0 = waste of space at such a raw level?
            //todo check casts are ok
            //todo assert TargetValue<>nil!
            {Get the data}
            //we need to store pointer in a temp var cos we need to pass as var next (only because routine needs to allow Dynamic allocation - use 2 routines = speed)
            dataPtr:=pUCHAR(TargetValue);

            //todo convert from server to c type (i.e. from IRD to ARD) ******
            // - note do before we modify client's buffer area - may be too small!
            if s.ird.getRecord(rn,Idr,True)<>ok then
            begin
              //error, skip this column: need to consume the rest of this column definition anyway -> sink
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUGDETAIL}
              log(format('SQLGetData failed getting IRD desc record %d - rest of column data abandoned...',[rn])); //todo debug error only - remove
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
              if StrLen_or_Ind<>nil then
              begin
                SQLINTEGER(StrLen_or_Ind^):=SQL_NULL_DATA;
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
              begin //no conversion required
                //note: we don't add \0 here
                if getpDataSDWORD(dataPtr,BufferLength,tempsdw)<>ok then
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
              //todo maybe don't set the StrLen_or_Ind if null will be set below?
              if StrLen_or_Ind<>nil then
              begin
                SQLINTEGER(StrLen_or_Ind^):=tempsdw;
              end;
            end;

            {$IFDEF DEBUGDETAIL}
            log(format('SQLGetData read column %d data: %d bytes, null=%d',[rn,tempsdw,tempNull])); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
            {$ENDIF}

            inc(i);
          end; {while}
          {get row status}
          getSQLUSMALLINT(sqlRowStatus);  //again, only here to keep similar protocol as fetchScroll (& maybe future use)
          {$IFDEF DEBUGDETAIL}
          log(format('SQLGetData read row status %d: %d',[rn,sqlRowStatus])); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
          {$ENDIF}
          {If there was an overall conversion error, then we set the setStatusExtra to it
           todo - check ok with standard!}
          if setStatusExtra=0 then
            setStatusExtra:=sqlRowStatus;
        end; {for row}

        getRETCODE(resultCode);
        //todo we should set to SQL_SUCCESS_WITH_INFO if any rowStatus just had a problem - i.e a conversion problem
        // since server wouldn't have known...
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLGetData returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seNoResultSet:           resultState:=ssHY010{todo ok??};
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;

        //log any truncation errors, e.g. from blob chunking
        if (resultCode=SQL_SUCCESS_WITH_INFO) and (setStatusExtra=SQL_ROW_SUCCESS_WITH_INFO) then
        begin
          s.diagnostic.logError(ss01004,seFail,'',0,0);

          {Also reset the length //todo get total blob length from server!}
          if StrLen_or_Ind<>nil then
          begin
            SQLINTEGER(StrLen_or_Ind^):=SQL_NO_TOTAL;
          end;
        end;

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
      end; {with}
    end; {S6,S7}
    S8..S10:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S8..10}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLGetData}

///// SQLGetFunctions /////

function SQLGetFunctions  (ConnectionHandle:SQLHDBC;
		 FunctionId:UWORD;
		 Supported:pUWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;

  {support routine based on inverted SQL_FUNC_EXISTS from sqlext.h}
  procedure setSQL_FUNC_EXISTS(Supported:pUWORD;FunctionId:UWORD);
  begin
    //for speed could use (shr 4) for div 16 etc.
    pUWORD(longint(Supported)+(sizeof(UWORD)*(FunctionId div 16)))^:=
       pUWORD(longint(Supported)+(sizeof(UWORD)*(FunctionId div 16)))^ or (1 shl (FunctionId mod 16) );
  end;

begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetFunctions called %d %d %p',[ConnectionHandle,FunctionId,Supported]));
  {$ENDIF}

  {Check handle}
  c:=Tdbc(ConnectionHandle);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  UWORD(Supported^):=SQL_FALSE;

  //todo fill the 4000 bitmap (once for the driver) & query it to return singles/100s

  case FunctionId of
    SQL_API_ODBC3_ALL_FUNCTIONS:
    begin //4000 bit bitmap
      //todo remove: no need? fillChar(Supported^,SQL_API_ODBC3_ALL_FUNCTIONS_SIZE,0);

      //todo debug ADO!!!
      //fillChar(Supported^,SQL_API_ODBC3_ALL_FUNCTIONS_SIZE,255);

      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLALLOCHANDLE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLBINDCOL);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLBINDPARAMETER);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCLOSECURSOR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCANCEL);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCOLATTRIBUTE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLALLOCHANDLE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCONNECT);
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLBULKOPERATIONS); //debug ADO
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLDRIVERCONNECT);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLDESCRIBECOL);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLDISCONNECT);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLENDTRAN);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLERROR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLEXECUTE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLEXECDIRECT);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLFETCHSCROLL);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLFETCH);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLFREEHANDLE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLFREESTMT);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETDESCFIELD);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETDIAGFIELD);
      {$IFNDEF NO_SQLGETDIAGREC}
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETDIAGREC);
      {$ENDIF}
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETENVATTR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETFUNCTIONS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETINFO);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETSTMTATTR);
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLMORERESULTS); //debug ADO
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLNUMRESULTCOLS);
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLEXTENDEDFETCH); //debug ADO
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLNATIVESQL); //debug ADO
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLBROWSECONNECT); 
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLDESCRIBEPARAM); //debug ADO
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLNUMPARAMS);
      //      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETPOS); //debug ADO
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPROCEDURECOLUMNS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPROCEDURES);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPREPARE);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETCURSORNAME);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETCURSORNAME);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETDESCFIELD);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETENVATTR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLTABLES);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCOLUMNS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETTYPEINFO);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPARAMDATA);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPUTDATA);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLROWCOUNT);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETDATA);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETSTMTATTR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLGETCONNECTATTR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSETCONNECTATTR);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLPRIMARYKEYS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLTABLEPRIVILEGES);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLCOLUMNPRIVILEGES);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLFOREIGNKEYS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSTATISTICS);
      setSQL_FUNC_EXISTS(Supported,SQL_API_SQLSPECIALCOLUMNS);
    end;

    SQL_API_ALL_FUNCTIONS:
    begin //100 element array
      //todo remove: no need? fillChar(Supported^,100,0);
      //Note: ensure no function id > 100 is ever used here - else access violation!
      //- todo also ensure we have all those we support <100!
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLBINDCOL))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLBINDPARAMETER))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLCOLATTRIBUTE))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLCANCEL))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLCONNECT))^:=SQL_TRUE;
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLBULKOPERATIONS))^:=SQL_TRUE; //debug ADO
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLDRIVERCONNECT))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLDESCRIBECOL))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLDISCONNECT))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLERROR))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLEXECUTE))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLEXECDIRECT))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLGETFUNCTIONS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLGETINFO))^:=SQL_TRUE;
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLMORERESULTS))^:=SQL_TRUE; //debug ADO
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLNUMRESULTCOLS))^:=SQL_TRUE;
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLEXTENDEDFETCH))^:=SQL_TRUE; //debug ADO
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLNATIVESQL))^:=SQL_TRUE; //debug ADO
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLBROWSECONNECT))^:=SQL_TRUE; 
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLDESCRIBEPARAM))^:=SQL_TRUE; //debug ADO
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLNUMPARAMS))^:=SQL_TRUE;
      //      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLSETPOS))^:=SQL_TRUE; //debug ADO
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPROCEDURECOLUMNS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPROCEDURES))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPREPARE))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLSETCURSORNAME))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLGETCURSORNAME))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLFREESTMT))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLTABLES))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLCOLUMNS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLGETTYPEINFO))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPARAMDATA))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPUTDATA))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLROWCOUNT))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLGETDATA))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLPRIMARYKEYS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLTABLEPRIVILEGES))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLCOLUMNPRIVILEGES))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLFOREIGNKEYS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLSTATISTICS))^:=SQL_TRUE;
      pUWORD(longint(Supported)+(sizeof(UWORD)* SQL_API_SQLSPECIALCOLUMNS))^:=SQL_TRUE;
    end;

    //todo combine into one case: - maybe including from..to ranges?
    SQL_API_SQLALLOCHANDLE: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLBINDCOL: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLBINDPARAMETER: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLCLOSECURSOR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLCANCEL: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLCOLATTRIBUTE: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLCONNECT: UWORD(Supported^):=SQL_TRUE;
    //    SQL_API_SQLBULKOPERATIONS: UWORD(Supported^):=SQL_TRUE; //debug ADO
    SQL_API_SQLDRIVERCONNECT: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLDESCRIBECOL: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLDISCONNECT: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLENDTRAN: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLERROR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLEXECUTE: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLEXECDIRECT: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLFETCHSCROLL: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLFETCH: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLFREEHANDLE: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLFREESTMT: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLGETDESCFIELD: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLGETDIAGFIELD: UWORD(Supported^):=SQL_TRUE;
    {$IFNDEF NO_SQLGETDIAGREC}
    SQL_API_SQLGETDIAGREC: UWORD(Supported^):=SQL_TRUE;
    {$ENDIF}

    SQL_API_SQLGETENVATTR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLGETFUNCTIONS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLGETINFO: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLGETSTMTATTR: UWORD(Supported^):=SQL_TRUE;

    //    SQL_API_SQLMORERESULTS: UWORD(Supported^):=SQL_TRUE; //debug ADO
    SQL_API_SQLNUMRESULTCOLS: UWORD(Supported^):=SQL_TRUE;
    //    SQL_API_SQLEXTENDEDFETCH: UWORD(Supported^):=SQL_TRUE; //debug ADO
    //    SQL_API_SQLNATIVESQL: UWORD(Supported^):=SQL_TRUE; //debug ADO
    SQL_API_SQLBROWSECONNECT: UWORD(Supported^):=SQL_TRUE; 
    //    SQL_API_SQLDESCRIBEPARAM: UWORD(Supported^):=SQL_TRUE; //debug ADO
    SQL_API_SQLNUMPARAMS: UWORD(Supported^):=SQL_TRUE;
    //    SQL_API_SQLSETPOS: UWORD(Supported^):=SQL_TRUE;  //debug ADO

    SQL_API_SQLPROCEDURECOLUMNS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLPROCEDURES: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLPREPARE: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLSETCURSORNAME: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLGETCURSORNAME: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLSETDESCFIELD: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLSETENVATTR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLTABLES: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLCOLUMNS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLGETTYPEINFO: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLPARAMDATA: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLPUTDATA: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLROWCOUNT: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLGETDATA: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLSETSTMTATTR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLGETCONNECTATTR: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLSETCONNECTATTR: UWORD(Supported^):=SQL_TRUE;

    SQL_API_SQLPRIMARYKEYS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLTABLEPRIVILEGES: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLCOLUMNPRIVILEGES: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLFOREIGNKEYS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLSTATISTICS: UWORD(Supported^):=SQL_TRUE;
    SQL_API_SQLSPECIALCOLUMNS: UWORD(Supported^):=SQL_TRUE;
  else
    //todo just return FALSE? - not error!?
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY096,fail,'',0,0); //todo check result
    exit;
  end; {case}

  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetFunctions returning successfully',[nil]));
  {$ENDIF}
  result:=SQL_SUCCESS;
end; {SQLGetFunctions}

///// SQLGetInfo /////

function SQLGetInfo  (ConnectionHandle:SQLHDBC;
		 InfoType:UWORD;
		 InfoValue:PTR;
		 BufferLength:SWORD;
		 StringLength:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
const
  OUR_KEYWORDS='';

  procedure Yes;
  begin
    strLcopy(pUCHAR(InfoValue),'Y',BufferLength-1);
    StringLength^:=SWORD(length('Y'));
  end;
  procedure No;
  begin
    strLcopy(pUCHAR(InfoValue),'N',BufferLength-1);
    StringLength^:=SWORD(length('N'));
  end;

var
  c:Tdbc;

  procedure AskServer;
  var
    functionId:SQLUSMALLINT;
    resultCode:RETCODE;
    resultErrCode:SQLINTEGER;
    resultErrText:pUCHAR;
    resultState:TsqlState;
    err:integer;
    tempsw:SWORD;
  begin
    //pass this info to server now

    if bufferLength=0 then
    begin
      {$IFDEF DEBUGDETAIL}
      log(format('SQLGetInfo (server-call) called with 0 buffer length',[nil]));
      {$ENDIF}
      //result:=SQL_ERROR;
      //c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
      exit; //nothing to return
    end;

    with c.Marshal do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      //note: it might be easier just to pass serverStmt,array_size
      //but we're trying to keep this function the same on the server because we need it for other things...
      // - we could always call a special serverSetArraySize routine here instead?
      //      or pass it every time we call ServerFetch?
      putFunction(SQL_API_SQLGETINFO);
      putSQLHDBC(ConnectionHandle);
      putSQLSMALLINT(InfoType);
      if Send<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
        exit;
      end;

      {Wait for response}
      if Read<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
        exit;
      end;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      }
      getFunction(functionId);
      if functionId<>SQL_API_SQLGETINFO then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
        exit;
      end;
      if getpUCHAR_SWORD(pUCHAR(InfoValue),BufferLength,tempsw)<>ok then exit;
      StringLength^:=SWORD(tempsw);
      getRETCODE(resultCode);
      result:=resultCode; //pass it on
      {$IFDEF DEBUGDETAIL}
      log(format('SQLGetInfo (server-call) returns %p',[infoValue]));
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
            seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
            seUnknownInfoType:       resultState:=ssHY096; //todo ok???
          else
            resultState:=ss08001; //todo more general failure needed/possible?
          end; {case}
          c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
        exit;
      end;
    end; {with}
  end; {AskServer}

begin
  //{$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetInfo called %d %d %p %d %p',[ConnectionHandle,InfoType,InfoValue,BufferLength,StringLength]));
  {$ENDIF}

  c:=nil; //keep compiler quiet

  if InfoType<>SQL_DRIVER_ODBC_VER then
  begin
    {Check handle}
    c:=Tdbc(ConnectionHandle);
    if not(c is Tdbc) then
    begin
      result:=SQL_INVALID_HANDLE;
      exit;
    end;
    if c.state=C3 then
    begin
      result:=SQL_ERROR;
      c.diagnostic.logError(ss08003,fail,'',0,0); //todo check result
      exit;
    end;
  end;

  case InfoType of
  //note: todo: check all comments here (even though may not have 'todo' alongside)
  //These return values were done before the server was complete, so some options
  //will need upgrading and others are already optimistically high - double check them all!
    SQL_DRIVER_ODBC_VER:
    begin
      //todo check that this fits the spec's \0 truncation policy - I think it should if strLcopy always adds \0
      //- if not - fix every occurrence!
      //TODO - we need to add if length>=bufferlength then log.error('truncated') to all these!! -use subroutine?
      strLcopy(pUCHAR(InfoValue),SQL_SPEC_STRING,BufferLength-1);
      StringLength^:=SWORD(length(SQL_SPEC_STRING));
    end; {SQL_DRIVER_ODBC_VER}
    //rest are in no particular order...
    //they can be put into groups (todo!), e.g. Driver-info, datasource-info, sql-info etc. -see ODBC spec.
    // - for things like limitations of the server, we should ask the server rather than answer on its
    //   behalf - in case the values change in a future server version & an old ODBC driver is being used
    //  -obviously driver info can be returned directly

    SQL_DRIVER_VER:
    begin
      strLcopy(pUCHAR(InfoValue),driverVer,BufferLength-1);
      StringLength^:=SWORD(length(driverVer));
    end; {SQL_DRIVER_VER}
    SQL_DRIVER_NAME:
    begin
      strLcopy(pUCHAR(InfoValue),driverName,BufferLength-1);
      StringLength^:=SWORD(length(driverName));
    end; {SQL_DRIVER_NAME}
    SQL_CATALOG_LOCATION:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_CL_START; //todo make sure we do this=standard
    end; {SQL_CATALOG_LOCATION}
    SQL_CATALOG_NAME: Yes;
    SQL_CATALOG_NAME_SEPARATOR:
    begin
      strLcopy(pUCHAR(InfoValue),'.'{todo use constant},BufferLength-1);
      StringLength^:=SWORD(length('.'));
    end; {SQL_CATALOG_NAME_SEPARATOR}
    SQL_CATALOG_TERM:
    begin
      strLcopy(pUCHAR(InfoValue),'catalog'{todo use constant},BufferLength-1);
      StringLength^:=SWORD(length('catalog'));
    end; {SQL_CATALOG_TERM}
    SQL_CATALOG_USAGE:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_CU_DML_STATEMENTS
                                 OR SQL_CU_TABLE_DEFINITION
                                 OR SQL_CU_PRIVILEGE_DEFINITION);  //todo probably some more eventually
    end; {SQL_CATALOG_USAGE}
    SQL_COLUMN_ALIAS: Yes;
    SQL_CORRELATION_NAME:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_CN_ANY; //todo make sure we do this=standard
    end; {SQL_CORRELATION_NAME}

    SQL_DATABASE_NAME: AskServer;
    SQL_DBMS_NAME: AskServer;
    SQL_DBMS_VERSION: AskServer;
    SQL_SERVER_NAME: AskServer;
    SQL_USER_NAME: AskServer;

    SQL_DATA_SOURCE_NAME:
    begin
      strLcopy(pUCHAR(InfoValue),pchar(c.DSN),BufferLength-1);
      StringLength^:=SWORD(length(c.DSN));
    end; {SQL_DATA_SOURCE_NAME}


    SQL_CURSOR_COMMIT_BEHAVIOR:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_CB_PRESERVE; //todo remove now we can auto-commit: SQL_CB_DELETE; //todo remove: trying to fix MSAccess97 disconnnect: SQL_CB_DELETE; //todo make sure we do this=standard  //SQL_CB_CLOSE//SQL_CB_PRESERVE; //todo maybe check with server?
      //todo double-check we leave StringLength^ unset - if not apply to all!
    end; {SQL_CURSOR_COMMIT_BEHAVIOR}
    SQL_CURSOR_ROLLBACK_BEHAVIOR:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_CB_PRESERVE; //todo remove now we can auto-commit: SQL_CB_DELETE; //todo remove: trying to fix MSAccess97 disconnnect: SQL_CB_DELETE; //todo make sure we do this=standard  //SQL_CB_CLOSE//SQL_CB_PRESERVE; //todo maybe check with server?
    end; {SQL_CURSOR_ROLLBACK_BEHAVIOR}

    SQL_DATA_SOURCE_READ_ONLY: No; //todo server

    SQL_DEFAULT_TRANSACTION_ISOLATION:   //=SQL_DEFAULT_TXN_ISOLATION in odbc, but no entry in odbc.h
    begin
      SQLUINTEGER(InfoValue^):=SQL_TXN_SERIALIZABLE; //todo server
    end; {SQL_DEFAULT_TRANSACTION_ISOLATION}

    SQL_DYNAMIC_CURSOR_ATTRIBUTES1:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_CA1_NEXT ); //todo more?
                                //OR SQL_CA1_ABSOLUTE OR SQL_CA1_RELATIVE OR SQL_CA1_BOOKMARK {todo remove these!: debug ADO}); {todo OR with other option bits}
    end; {SQL_DYNAMIC_CURSOR_ATTRIBUTES1}

    SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES1:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_CA1_NEXT ); //todo more?
                                //OR SQL_CA1_ABSOLUTE OR SQL_CA1_RELATIVE OR SQL_CA1_BOOKMARK {todo remove these!: debug ADO}); {todo OR with other option bits}
    end; {SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES1}

    SQL_STATIC_CURSOR_ATTRIBUTES1:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_CA1_NEXT ); //todo more?
                                //OR SQL_CA1_ABSOLUTE OR SQL_CA1_RELATIVE OR SQL_CA1_BOOKMARK {todo remove these!: debug ADO}); {todo OR with other option bits}
    end; {SQL_STATIC_CURSOR_ATTRIBUTES1}

    SQL_KEYWORDS:
    begin
      strLcopy(pUCHAR(InfoValue),OUR_KEYWORDS,BufferLength-1);
      StringLength^:=SWORD(length(OUR_KEYWORDS));
    end; {SQL_KEYWORDS}
    SQL_IDENTIFIER_QUOTE_CHAR:
    begin
      strLcopy(pUCHAR(InfoValue),'"'{todo fix!},BufferLength-1);  //server? will be "
      StringLength^:=SWORD(length('"'));
    end; {SQL_IDENTIFIER_QUOTE_CHAR}

    SQL_TRANSACTION_CAPABLE:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_TC_ALL;
    end; {SQL_TRANSACTION_CAPABLE}

    SQL_ODBC_INTERFACE_CONFORMANCE:
    begin
      SQLUINTEGER(InfoValue^):=SQL_OIC_CORE; //todo b-b-b-b-b-higher!!!!!
    end; {SQL_ODBC_INTERFACE_CONFORMANCE}

    SQL_SQL_CONFORMANCE:
    begin
      SQLUINTEGER(InfoValue^):=SQL_SC_SQL92_FULL; //todo b-b-b-b-b-lower???!!!!!
    end; {SQL_SQL_CONFORMANCE}

    SQL_INSERT_STATEMENT:
    begin
      SQLUINTEGER(InfoValue^):=(SQL_IS_INSERT_LITERALS
                                OR SQL_IS_INSERT_SEARCHED
                                OR SQL_IS_SELECT_INTO);
    end; {SQL_INSERT_STATEMENT}

    SQL_MAXIMUM_DRIVER_CONNECTIONS:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit
    end; {}
    SQL_MAXIMUM_CONCURRENT_ACTIVITIES:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit
    end;
    SQL_SEARCH_PATTERN_ESCAPE:
    begin
      strLcopy(pUCHAR(InfoValue),SEARCH_PATTERN_ESCAPE,BufferLength-1);
      StringLength^:=SWORD(length(SEARCH_PATTERN_ESCAPE));
    end;
    SQL_ACCESSIBLE_TABLES: Yes; //standard should return N
    //todo not in ODBC, SQL_ACCESSIBLE_ROUTINES, see SQL_ACCESSIBLE_PROCEDURES instead
    SQL_IDENTIFIER_CASE:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_IC_MIXED; //standard should return SQL_IC_UPPER? => change server create-table code etc. todo
    end;
    SQL_MAXIMUM_COLUMN_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=128; //todo***** debug only for gator: reinstate zero=no limit! 0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_CURSOR_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - keep in sync with stmt definition code
    end;
    SQL_MAXIMUM_SCHEMA_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_CATALOG_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_TABLE_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=128; //todo***** debug only for gator: reinstate zero=no limit! 0;//no limit - todo server - check/share constants
    end;
    SQL_SCROLL_OPTIONS:
    begin
      SQLUINTEGER(InfoValue^):=(SQL_SO_FORWARD_ONLY);
                                //OR SQL_SO_STATIC{ok?=only if serializable}); //todo more?
                                //OR SQL_SO_KEYSET_DRIVEN OR SQL_SO_DYNAMIC OR SQL_SO_MIXED {todo remove these!: debug ADO});
                                                    {todo OR others?};
    end;
    SQL_TRANSACTION_ISOLATION_OPTION:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_TRANSACTION_READ_UNCOMMITTED OR SQL_TRANSACTION_READ_COMMITTED
                                 OR SQL_TRANSACTION_REPEATABLE_READ OR SQL_TRANSACTION_SERIALIZABLE
                                 {OR SQL_TXN_VERSIONING todo?} ); //todo ensure server can drop down from serializable!
                                                                 //currently I think it can simulate all of these
    end;
    SQL_INTEGRITY: Yes; //todo todo on server!
    SQL_GETDATA_EXTENSIONS:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_GD_ANY_COLUMN OR SQL_GD_ANY_ORDER );
                                //we could easily support SQL_GD_BOUND as well, but have chosen not to
                                //++ 18/12/02 - this would exclude blobs!
    end;
    SQL_NULL_COLLATION:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_NC_LOW; //todo check this is currently correct! //todo server - check/share constants
      //todo note/check SQL_NC_START = SQL_NC_LOW ? but they don't mean the same!
    end;
    SQL_ORDER_BY_COLUMNS_IN_SELECT: Yes; //todo SQL3=N, and we do actually handle N already (I think)
    SQL_SPECIAL_CHARACTERS:
    begin
      strLcopy(pUCHAR(InfoValue),'',BufferLength-1); //todo probably will allow some wierd characters if delimited
      StringLength^:=SWORD(length(''));
    end;
    SQL_MAXIMUM_COLUMNS_IN_GROUP_BY:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_COLUMNS_IN_ORDER_BY:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_COLUMNS_IN_SELECT:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - todo server - check/share constants
    end;
    SQL_MAXIMUM_COLUMNS_IN_TABLE:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - todo server - check/share constants
    end;
    SQL_MAX_COLUMNS_IN_INDEX:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - todo server - check/share constants
    end;
    //todo clashed with SQL_GETPARAMDATA_EXTENSIONS: SQL_MAXIMUM_STMT_OCTETS,
    SQL_MAXIMUM_STMT_OCTETS_DATA,
    SQL_MAXIMUM_STMT_OCTETS_SCHEMA: //todo ODBC has SQL_MAX_STATEMENT_LEN, but not in odbc.h
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - should be bigBufferMax?/parser limit? - todo server - check/share constants
    end;
    SQL_MAXIMUM_TABLES_IN_SELECT:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit - todo server - check/share constants
    end;
    SQL_MAXIMUM_USER_NAME_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - check user_name col-definition?- todo server - check/share constants
    end;
    SQL_OUTER_JOIN_CAPABILITIES: //todo ODBC has SQL_OJ_CAPABILITIES & is different value?
    begin
      SQLUINTEGER(InfoValue^):=( SQL_OUTER_JOIN_LEFT OR SQL_OUTER_JOIN_RIGHT
                                 OR SQL_OUTER_JOIN_FULL OR SQL_OUTER_JOIN_NESTED
                                 OR SQL_OUTER_JOIN_NOT_ORDERED OR SQL_OUTER_JOIN_INNER
                                 OR SQL_OUTER_JOIN_ALL_COMPARISON_OPS ); //todo make sure server handles all these!
                                                                         //it should be able to!
    end;
    SQL_CURSOR_SENSITIVITY: //todo ODBC has SQL_CURSOR_ROLLBACK_SQL_CURSOR_SENSITIVITY (doc error?) & is not in odbc.h
    begin
      SQLUINTEGER(InfoValue^):=SQL_INSENSITIVE;
    end;
    SQL_COLLATING_SEQUENCE: //todo ODBC has SQL_COLLATION_SEQ - not in odbc.h
    begin
      strLcopy(pUCHAR(InfoValue),'SQLTEXT'{todo fix!},BufferLength-1); //todo get from info schema...
      StringLength^:=SWORD(length('SQLTEXT'));
    end;
    SQL_MAXIMUM_IDENTIFIER_LENGTH:
    begin
      SQLUSMALLINT(InfoValue^):=0; //no limit? - todo server - check/share constants
    end;
    SQL_REF_LENGTH: //todo standard only - concerning UDTs...
    begin
      SQLSMALLINT(InfoValue^):=0; //no limit? - todo server - check/share constants
    end;
    SQL_SCHEMA_TERM:
    begin
      strLcopy(pUCHAR(InfoValue),'schema'{todo use constant},BufferLength-1);
      StringLength^:=SWORD(length('schema'));
    end; {SQL_SCHEMA_TERM}
    SQL_TABLE_TERM:
    begin
      strLcopy(pUCHAR(InfoValue),'table'{todo use constant},BufferLength-1);
      StringLength^:=SWORD(length('table'));
    end; {SQL_TABLE_TERM}
    SQL_SCHEMA_USAGE:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_SU_DML_STATEMENTS
                                 OR SQL_SU_TABLE_DEFINITION
                                 OR SQL_SU_PRIVILEGE_DEFINITION);  //todo probably some more eventually
    end; {SQL_SCHEMA_USAGE}
    SQL_SUBQUERIES:
    begin
      SQLUINTEGER(InfoValue^):=( SQL_SQ_COMPARISON
                                 OR SQL_SQ_EXISTS
                                 OR SQL_SQ_IN
                                 OR SQL_SQ_QUANTIFIED
                                 OR SQL_SQ_CORRELATED_SUBQUERIES);
    end; {SQL_SUBQUERIES}
    SQL_GETPARAMDATA_EXTENSIONS:
    begin
      SQLUINTEGER(InfoValue^):=( 0 {todo: probably all will be allowed when driver is finished} ); //todo
    end;
    SQL_NEED_LONG_DATA_LEN: No;

    //todo ODBC etc.
    SQL_EXPRESSIONS_IN_ORDERBY: No;

    //these come from queries by MSQuery and Borland DBexplorer - I think they're old/deprecated...
    SQL_NON_NULLABLE_COLUMNS:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_NNC_NON_NULL;
    end;
    SQL_FILE_USAGE:
    begin
      SQLUSMALLINT(InfoValue^):=SQL_FILE_NOT_SUPPORTED;
    end;
    SQL_OUTER_JOINS: Yes; //old?
    SQL_QUOTED_IDENTIFIER_CASE: //old?
    begin
      SQLUSMALLINT(InfoValue^):=SQL_IC_MIXED; //apparently should return SQL_IC_SENSITIVE;
    end;

    {from QTODBC}
    SQL_ODBC_SAG_CLI_CONFORMANCE: SQLUSMALLINT(InfoValue^):=SQL_OSCC_COMPLIANT;

    //from Delphi
    SQL_PROCEDURES: Yes;

    SQL_TIMEDATE_ADD_INTERVALS:
    begin
      SQLUINTEGER(InfoValue^):=$00000000; //todo in future
    end;
    SQL_TIMEDATE_DIFF_INTERVALS:
    begin
      SQLUINTEGER(InfoValue^):=$00000000; //todo in future
    end;

    {Advanced (mainly ODBC 3) results}
    SQL_AGGREGATE_FUNCTIONS: SQLUINTEGER(InfoValue^):=SQL_AF_ALL;
    SQL_ASYNC_MODE: SQLUINTEGER(InfoValue^):=SQL_AM_NONE;
    SQL_CONCAT_NULL_BEHAVIOR: SQLUSMALLINT(InfoValue^):=SQL_CB_NULL;

    //todo: SQL_CONVERT_...

    SQL_CREATE_DOMAIN: SQLUINTEGER(InfoValue^):=( SQL_CDO_CREATE_DOMAIN OR
                                                  SQL_CDO_DEFAULT OR SQL_CDO_CONSTRAINT OR
                                                  SQL_CDO_CONSTRAINT_NAME_DEFINITION OR SQL_CDO_CONSTRAINT_INITIALLY_DEFERRED OR SQL_CDO_CONSTRAINT_INITIALLY_IMMEDIATE OR SQL_CDO_CONSTRAINT_DEFERRABLE OR SQL_CDO_CONSTRAINT_NON_DEFERRABLE);

    SQL_CREATE_SCHEMA: SQLUINTEGER(InfoValue^):=( SQL_CS_CREATE_SCHEMA OR SQL_CS_AUTHORIZATION OR SQL_CS_DEFAULT_CHARACTER_SET);
    SQL_CREATE_TABLE:  SQLUINTEGER(InfoValue^):=( SQL_CT_CREATE_TABLE OR SQL_CT_TABLE_CONSTRAINT OR SQL_CT_CONSTRAINT_NAME_DEFINITION
                                                  OR SQL_CT_COLUMN_CONSTRAINT OR SQL_CT_COLUMN_DEFAULT OR
                                                  SQL_CT_CONSTRAINT_INITIALLY_DEFERRED OR SQL_CT_CONSTRAINT_INITIALLY_IMMEDIATE OR SQL_CT_CONSTRAINT_DEFERRABLE OR SQL_CT_CONSTRAINT_NON_DEFERRABLE
                                                  OR SQL_CT_GLOBAL_TEMPORARY OR SQL_CT_LOCAL_TEMPORARY OR SQL_CT_COMMIT_PRESERVE OR SQL_CT_COMMIT_DELETE);
    SQL_CREATE_VIEW:   SQLUINTEGER(InfoValue^):=( SQL_CV_CREATE_VIEW OR SQL_CV_CHECK_OPTION OR SQL_CV_CASCADED OR SQL_CV_LOCAL);
    SQL_DATETIME_LITERALS: SQLUINTEGER(InfoValue^):=( SQL_DL_SQL92_DATE OR SQL_DL_SQL92_TIME OR SQL_DL_SQL92_TIMESTAMP);
    SQL_DROP_TABLE: SQLUINTEGER(InfoValue^):=( SQL_DT_DROP_TABLE OR SQL_DT_RESTRICT OR SQL_DT_CASCADE);
    SQL_DROP_VIEW: SQLUINTEGER(InfoValue^):=( SQL_DV_DROP_VIEW OR SQL_DV_RESTRICT OR SQL_DV_CASCADE);
    SQL_GROUP_BY: SQLUINTEGER(InfoValue^):=( SQL_GB_GROUP_BY_CONTAINS_SELECT ); //ODBC doc says should return SQL_GB_GROUP_BY_EQUALS_SELECT but I think it's wrong
    SQL_INFO_SCHEMA_VIEWS: SQLUINTEGER(InfoValue^):=( SQL_ISV_COLUMN_PRIVILEGES OR
                                                      SQL_ISV_COLUMNS OR
                                                      SQL_ISV_KEY_COLUMN_USAGE OR
                                                      SQL_ISV_REFERENTIAL_CONSTRAINTS OR
                                                      SQL_ISV_SCHEMATA OR
                                                      SQL_ISV_TABLE_CONSTRAINTS OR
                                                      SQL_ISV_TABLE_PRIVILEGES OR
                                                      SQL_ISV_TABLES
                                                      //todo more!
                                                    );
    SQL_MAX_ROW_SIZE_INCLUDES_LONG: Yes;
    SQL_MULTIPLE_ACTIVE_TXN: Yes;
    SQL_SQL92_DATETIME_FUNCTIONS: SQLUINTEGER(InfoValue^):=( SQL_SDF_CURRENT_DATE OR SQL_SDF_CURRENT_TIME OR SQL_SDF_CURRENT_TIMESTAMP);
    SQL_SQL92_FOREIGN_KEY_DELETE_RULE: SQLUINTEGER(InfoValue^):=( SQL_SFKD_CASCADE OR SQL_SFKD_NO_ACTION OR SQL_SFKD_SET_DEFAULT OR SQL_SFKD_SET_NULL);
    SQL_SQL92_FOREIGN_KEY_UPDATE_RULE: SQLUINTEGER(InfoValue^):=( SQL_SFKU_CASCADE OR SQL_SFKU_NO_ACTION OR SQL_SFKU_SET_DEFAULT OR SQL_SFKU_SET_NULL);
    SQL_SQL92_GRANT: SQLUINTEGER(InfoValue^):=( SQL_SG_USAGE_ON_DOMAIN OR SQL_SG_WITH_GRANT_OPTION OR
                                                SQL_SG_DELETE_TABLE OR
                                                SQL_SG_INSERT_TABLE OR SQL_SG_INSERT_COLUMN OR
                                                SQL_SG_REFERENCES_TABLE OR SQL_SG_REFERENCES_COLUMN OR
                                                SQL_SG_SELECT_TABLE OR
                                                SQL_SG_UPDATE_TABLE OR SQL_SG_UPDATE_COLUMN);
    SQL_SQL92_NUMERIC_VALUE_FUNCTIONS: SQLUINTEGER(InfoValue^):=( SQL_SNVF_CHAR_LENGTH OR SQL_SNVF_CHARACTER_LENGTH OR SQL_SNVF_OCTET_LENGTH OR SQL_SNVF_POSITION);
    SQL_SQL92_PREDICATES: SQLUINTEGER(InfoValue^):=( SQL_SP_EXISTS OR SQL_SP_ISNOTNULL OR SQL_SP_ISNULL OR SQL_SP_MATCH_FULL OR SQL_SP_MATCH_PARTIAL OR SQL_SP_MATCH_UNIQUE_FULL OR SQL_SP_MATCH_UNIQUE_PARTIAL OR
                                                     SQL_SP_LIKE OR SQL_SP_IN OR SQL_SP_BETWEEN OR SQL_SP_COMPARISON OR SQL_SP_QUANTIFIED_COMPARISON);
    SQL_SQL92_RELATIONAL_JOIN_OPERATORS: SQLUINTEGER(InfoValue^):=( SQL_SRJO_CORRESPONDING_CLAUSE OR SQL_SRJO_CROSS_JOIN OR SQL_SRJO_EXCEPT_JOIN OR SQL_SRJO_FULL_OUTER_JOIN OR SQL_SRJO_INNER_JOIN OR SQL_SRJO_INTERSECT_JOIN OR SQL_SRJO_LEFT_OUTER_JOIN OR SQL_SRJO_NATURAL_JOIN OR SQL_SRJO_RIGHT_OUTER_JOIN OR SQL_SRJO_UNION_JOIN);
    SQL_SQL92_REVOKE: SQLUINTEGER(InfoValue^):=( SQL_SR_USAGE_ON_DOMAIN OR
                                                SQL_SR_DELETE_TABLE OR
                                                SQL_SR_INSERT_TABLE OR SQL_SR_INSERT_COLUMN OR
                                                SQL_SR_REFERENCES_TABLE OR SQL_SR_REFERENCES_COLUMN OR
                                                SQL_SR_SELECT_TABLE OR
                                                SQL_SR_UPDATE_TABLE OR SQL_SR_UPDATE_COLUMN);
    SQL_SQL92_ROW_VALUE_CONSTRUCTOR: SQLUINTEGER(InfoValue^):=( SQL_SRVC_VALUE_EXPRESSION OR SQL_SRVC_NULL OR SQL_SRVC_DEFAULT OR SQL_SRVC_ROW_SUBQUERY);
    SQL_SQL92_STRING_FUNCTIONS: SQLUINTEGER(InfoValue^):=( SQL_SSF_LOWER OR SQL_SSF_UPPER OR SQL_SSF_SUBSTRING OR SQL_SSF_TRIM_BOTH OR SQL_SSF_TRIM_LEADING OR SQL_SSF_TRIM_TRAILING);
    SQL_SQL92_VALUE_EXPRESSIONS: SQLUINTEGER(InfoValue^):=( SQL_SVE_CASE OR SQL_SVE_CAST);
    SQL_STANDARD_CLI_CONFORMANCE: SQLUINTEGER(InfoValue^):=( SQL_SCC_XOPEN_CLI_VERSION1 OR SQL_SCC_ISO92_CLI);
    SQL_UNION: SQLUINTEGER(InfoValue^):=(SQL_U_UNION OR SQL_U_UNION_ALL);

    {The following have been added to return some 0/N response (instead of an error) until we implement them}
    SQL_ACCESSIBLE_PROCEDURES: No;
    SQL_DESCRIBE_PARAMETER: No; //todo if we implement DESCRIBE INPUT then maybe?

    SQL_BOOKMARK_PERSISTENCE, //:    SQLUINTEGER(InfoValue^):=(SQL_BP_CLOSE OR SQL_BP_DELETE OR SQL_BP_DROP OR SQL_BP_TRANSACTION OR SQL_BP_UPDATE OR SQL_BP_OTHER_HSTMT OR SQL_BP_SCROLL
                              //                            ); //debug ADO

    SQL_KEYSET_CURSOR_ATTRIBUTES1,
    SQL_KEYSET_CURSOR_ATTRIBUTES2, //: SQLUINTEGER(InfoValue^):=( SQL_CA1_NEXT
                     //OR SQL_CA1_ABSOLUTE OR SQL_CA1_RELATIVE OR SQL_CA1_BOOKMARK {todo remove these!: debug ADO}); {todo OR with other option bits}

    SQL_ACTIVE_ENVIRONMENTS,
    SQL_ALTER_DOMAIN,
    SQL_ALTER_TABLE,
    SQL_BATCH_ROW_COUNT,
    SQL_BATCH_SUPPORT,
    SQL_CONVERT_FUNCTIONS,
    SQL_CREATE_ASSERTION,
    SQL_CREATE_CHARACTER_SET,
    SQL_CREATE_COLLATION,
    SQL_CREATE_TRANSLATION,
    SQL_DDL_INDEX,
    SQL_DROP_ASSERTION,
    SQL_DROP_CHARACTER_SET,
    SQL_DROP_COLLATION,
    SQL_DROP_DOMAIN,
    SQL_DROP_SCHEMA,
    SQL_DROP_TRANSLATION,
    SQL_DYNAMIC_CURSOR_ATTRIBUTES2,
    SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES2,
    SQL_STATIC_CURSOR_ATTRIBUTES2,
    SQL_INDEX_KEYWORDS,
    SQL_MAX_ASYNC_CONCURRENT_STATEMENTS, //number
    SQL_MAX_BINARY_LITERAL_LEN, //number
    SQL_MAX_CHAR_LITERAL_LEN, //number
    SQL_MAX_INDEX_SIZE, //number //had to add to ODBC.inc manually!
    SQL_MAX_STATEMENT_LEN, //number //had to add to ODBC.inc manually!
    SQL_NUMERIC_FUNCTIONS,
    SQL_PARAM_ARRAY_ROW_COUNTS, //ok?
    SQL_PARAM_ARRAY_SELECTS,    //ok?,
    SQL_STRING_FUNCTIONS,
    SQL_SYSTEM_FUNCTIONS,
    SQL_TIMEDATE_FUNCTIONS
                             : SQLUINTEGER(InfoValue^):=0;

    {Smallint numbers}
    SQL_MAX_PROCEDURE_NAME_LEN,
    SQL_MAX_ROW_SIZE //had to add to ODBC.inc manually!
                             :SQLUSMALLINT(InfoValue^):=0;

    SQL_LIKE_ESCAPE_CLAUSE: Yes;
    SQL_MULT_RESULT_SETS: No; //todo: not yet... SQLmoreResults needed first
    SQL_ROW_UPDATES: No;

    SQL_PROCEDURE_TERM:
    begin
      strLcopy(pUCHAR(InfoValue),'procedure'{todo use constant},BufferLength-1);
      StringLength^:=SWORD(length('procedure'));
    end;

    {The following are deprecated in ODBC 3.0 but needed for v2 clients}
    SQL_POS_OPERATIONS:        SQLUINTEGER(InfoValue^):=0 ;//(SQL_POS_POSITION OR SQL_POS_REFRESH OR SQL_POS_UPDATE OR
                                                         //SQL_POS_DELETE OR SQL_POS_ADD); //debug ADO

    SQL_SCROLL_CONCURRENCY:    SQLUINTEGER(InfoValue^):=SQL_SCCO_READ_ONLY; //(SQL_SCCO_OPT_ROWVER); //debug ADO
    SQL_LOCK_TYPES:            SQLUINTEGER(InfoValue^):=SQL_LCK_NO_CHANGE; //SQL_LCK_NO_CHANGE; //debug ADO
    SQL_POSITIONED_STATEMENTS: SQLUINTEGER(InfoValue^):=0; //(SQL_PS_POSITIONED_DELETE OR SQL_PS_POSITIONED_UPDATE OR
                                                         //SQL_PS_SELECT_FOR_UPDATE); //debug ADO
    SQL_STATIC_SENSITIVITY:    SQLUINTEGER(InfoValue^):=0; //(SQL_SS_ADDITIONS OR SQL_SS_DELETIONS OR SQL_SS_UPDATES); //debug ADO

    SQL_FETCH_DIRECTION:
    begin
      SQLINTEGER(InfoValue^):=SQL_FD_FETCH_NEXT {todo OR others when implemented!}; //todo all for now!
    end; {SQL_FETCH_DIRECTION}
    SQL_ODBC_API_CONFORMANCE:
    begin
      SQLSMALLINT(InfoValue^):=SQL_OAC_LEVEL1; //try to fix MSAccess97 crash: SQL_OAC_LEVEL1; //todo b-b-b-b-b-higher!!!!!
    end; {SQL_ODBC_API_CONFORMANCE}
    SQL_ODBC_SQL_CONFORMANCE:
    begin
      SQLSMALLINT(InfoValue^):=SQL_OSC_EXTENDED;  //todo b-b-b-b-b-lower???!!!!!
    end; {SQL_ODBC_SQL_CONFORMANCE}
    {End of deprecated section}
  else
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY096,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLGetInfo called with unhandled type %d',[InfoType]));
    {$ENDIF}
    exit;
    //todo return with error HY096 or HYC00
  end; {case}

  result:=SQL_SUCCESS;
end; {getInfo}
(*                                             1
///// SQLGetStmtOption /////

RETCODE SQL_API SQLGetStmtOption  (HSTMT arg0,
		 UWORD arg1,
		 PTR arg2)
{
	log("SQLGetStmtOption called\n");
	return(SQL_SUCCESS);
}
*)
///// SQLGetTypeInfo /////

function SQLGetTypeInfo  (StatementHandle:SQLHSTMT;
		 DataType:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetTypeInfo called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo improve! -& fix by using a server created View in INFORMATION_SCHEMA (implementation defined - see p332)
  query:='SELECT TYPE_NAME,'+
         'DATA_TYPE,'+
         'COLUMN_SIZE,'+
         'LITERAL_PREFIX,'+
         'LITERAL_SUFFIX,'+
         'CREATE_PARAMS,'+
         'NULLABLE,'+
         'CASE_SENSITIVE,'+
         'SEARCHABLE,'+
         'UNSIGNED_ATTRIBUTE,'+
         'FIXED_PREC_SCALE,'+
         'AUTO_UNIQUE_VALUE,'+
         'LOCAL_TYPE_NAME,'+
         'MINIMUM_SCALE,'+
         'MAXIMUM_SCALE,'+
         'SQL_DATA_TYPE,'+
         'SQL_DATETIME_SUB,'+
         'NUM_PREC_RADIX,'+
         'INTERVAL_PRECISION '+
         'FROM '+information_schemaName+'.TYPE_INFO ';
  if DataType<>SQL_ALL_TYPES then
  begin
    if dataType<0 then //todo remove test...
      query:=query+'WHERE DATA_TYPE=0'+intToStr(DataType) //todo remove: debug until server handles unary -  !! i.e. we use 0-3 for -3
    else
      query:=query+'WHERE DATA_TYPE='+intToStr(DataType);
  end;

  query:=query+'; ';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLGetTypeInfo}

///// SQLParamData /////

function SQLParamData  (StatementHandle:SQLHSTMT;
		 Value:pSQLPOINTER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;

//todo remove?  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;

  rn:SQLSMALLINT;
  adr:TdescRec;

  resultRowCount:SQLINTEGER;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  tempNull:SQLSMALLINT;

  i:SQLINTEGER; //todo word ok?
  lateResSet:SQLUSMALLINT;
  colCount:SQLINTEGER;  //todo word ok?
  dr:TdescRec;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLParamData called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  {todo
   2 approaches:
     1: driver knows which params are deferred and can request missing info without consulting server
     2: server knows which params are missing and can request missing info
   (could give different orderings... I think 2 is safer (user might define unused params that we never need fill)
                                      but extra traffic, but easier management?)

   call SQLexecute on server (no need to send parameters first!)
   pass user_param_ref back to user if need_data
     - note: since server is in control, it should store return this value (which param) & driver returns it's dataPtr
   return result (need_data or success/fail)

   Note++
     with blobs, caller binds parameter as <=SQL_LEN_DATA_AT_EXEC_OFFSET or =SQL_DATA_AT_EXEC to
     pre-specify that a parameter should be filled via setParamData/setParam after sqlExecute returns need_data.
     In such cases we should take approach 1 above:
        a) to avoid a call to the server to find out what we already know
        b) because the caller expects this routine to return its unique reference
     but because we need to track which ones have been completed during this execution we
     currently take the easy approach of 2, and leave the work to the server
     - we still pass back the callers ref. from the index we get back from the server
  }
  case s.state of
    S1, S2..S3, S4, S5..S7, S9:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1,S2..S3,S4,S5..S7,S9}
    S8,S10:
    begin
      {call server execute}
      //todo Replace all AS with casts - speed

      //todo keep in sync. with SQLExecute
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLEXECUTE);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref

        {We're not sending any parameters here (prior call to SQLExecute has already done this),
         but we still send rowCount=1, colCount=0 for protocol's sake}
        rowCount:=1;

        {Write row count}
        putSQLUINTEGER(rowCount);

        {$IFDEF DEBUGDETAIL}
        log(format('SQLParamData sending %d rows',[rowCount]));
        {$ENDIF}

        for row:=1 to rowCount do
        begin
          {Now send the param count & data for this row = 0}
          putSQLINTEGER(0);

          {$IFDEF DEBUGDETAIL}
          log(format('SQLParamData sending %d parameter data',[0]));
          {$ENDIF}
        end; {for row}

        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLEXECUTE then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLParamData returns %d',[resultCode]));
        {$ENDIF}
        {if error, then get error details: local-number, default-text}
        if getSQLINTEGER(resultErrCode)<>ok then exit; //error count
        if resultCode=SQL_ERROR then
        begin
          for err:=1 to resultErrCode do
          begin
            if getSQLINTEGER(resultErrCode)<>ok then exit;
            if getpUCHAR_SWORD(pUCHAR(resultErrText),DYNAMIC_ALLOCATION,tempsw)<>ok then exit;
            //todo keep this case in sync. with SQLExecute
            case resultErrCode of
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seSyntaxNotEnoughViewColumns: resultState:=ss21S01;
              seSyntaxTableAlreadyExists:   resultState:=ss42S01;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        {Get the row count - only valid for insert/update/delete}
        getSQLINTEGER(resultRowCount);
        s.rowCount:=resultRowCount; //todo get direct?

        if (s.owner as Tdbc).serverCLIversion>=0092 then
        begin
          {Now get any late (post-prepare) resultSet definition, i.e. for stored procedure return cursors
           False here doesn't mean we have no result set, it means we should use the details from SQLprepare}
          getSQLUSMALLINT(lateResSet);
          {Remember this for future state changes}
          if lateResSet=SQL_TRUE then s.resultSet:=True; //else leave s.resultSet as was

          {$IFDEF DEBUGDETAIL}
          log(format('SQLParamData returns %d %d',[resultCode,lateResSet]));
          {$ENDIF}
          if lateResSet=SQL_TRUE then
          begin
            s.cursor.state:=csOpen;
            //s.state:=S3; //todo: if s.state=S4 then only if last result of multiple
            if s.state=S2 then s.state:=S3; //below will then advance this to S5
            {Now get the IRD count & definitions}
            getSQLINTEGER(colCount);
            {$IFDEF DEBUGDETAIL}
            log(format('SQLParamData returns %d IRD column defs',[colCount]));
            {$ENDIF}
            s.ird.desc_count:=colCount;
            //todo rest is switchable? - maybe can defer till needed?
            //todo now use get with result checking!!!
            i:=0;
            while i<=colCount-1 do
            begin
              //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
              if getSQLSMALLINT(rn)<>ok then
              begin
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit;
              end;
              if s.ird.getRecord(rn,dr,True)=ok then
              begin
                with dr do
                begin
                  {We first read the name, type, precision and scale
                   and then we make sure the correct parts of the descriptor are
                   set according to the type}
                  if getpSQLCHAR_SWORD(desc_name,desc_name_SIZE,tempsw)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  if getSQLSMALLINT(desc_type)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;

                  desc_concise_type:=desc_type; //todo check this is correct
                                                //note: we modify it below if datetime/interval
                                                //- bindParameter does this via calling SetDescField
                                                // - maybe we should also call it here to gain exactly
                                                //   the same side-effects?
                  (* todo remove:
                  {Now set the desc type properly to gain necessary side-effects}
                  result:=SQLSetDescField(SQLHDESC(s.ird),rn,SQL_DESC_TYPE,SQLPOINTER(desc_type),SQL_IS_SMALLINT);
                  //better to continue with bad type settings? //if result=SQL_ERROR then exit;
                  *)

                if (s.owner as Tdbc).serverCLIversion>=0093 then
                begin
                  if getSQLINTEGER(desc_precision)<>ok then  //=server width
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                end
                else
                begin
                  if getSQLSMALLINT(tempNull)<>ok then  //=server width
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  desc_precision:=tempNull;
                end;
                  (* todo - moved below
                  //todo length, octet_length & display_size <- width?
                  //for now, set length=precision - not valid for all types... use a dataConversion unit...
                  desc_length:=desc_precision;
                  if not(desc_type in [SQL_CHAR,SQL_VARCHAR]) or (desc_length=0) then
                  begin
                    desc_length:=4; //todo desperate fix to try to please Delphi...(didn't work) - mend!
                  end;
                  *)
                  if getSQLSMALLINT(desc_scale)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  if getSQLSMALLINT(desc_nullable)<>ok then
                  begin
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end;
                  {$IFDEF DEBUGDETAIL}
                  log(format('SQLParamData read column definition: %s (%d)',[desc_name,desc_precision])); //todo debug only - remove
                  {$ENDIF}

                  {The following chunk of code is the inverse of the BindParameter logic
                   - check ok}
                   //todo it is copied below for the IPD...
                   // - so maybe we need a function that
                   //   sets the length,precision,scale,...interval_code/_precision,concise_type
                   //   based on the type?
                   //   Since we use the logic in 3 places already
                  desc_datetime_interval_code:=0; //reset for all non-date/time types
                  case desc_type of
                    SQL_NUMERIC, SQL_DECIMAL:
                      desc_length:=desc_precision;

                    SQL_INTEGER, SQL_SMALLINT, SQL_FLOAT, SQL_REAL, SQL_DOUBLE:
                    begin
                      desc_scale:=0;
                      case desc_type of
                        SQL_INTEGER: desc_precision:=10;
                        SQL_SMALLINT: desc_precision:=5;
                        SQL_FLOAT:    desc_precision:=15;
                        SQL_DOUBLE:   desc_precision:=15;
                        SQL_REAL:     desc_precision:=7;
                      end; {case}
                      desc_length:=desc_precision;
                    end; {numeric}

                    //Note: datetime/interval complications taken from standard, not ODBC
                    SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                    SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
                    SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
                    SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                    begin
                      {Split the Type into (Major) Type and (Sub-type) IntervalCode, e.g. 103 = 10 and 3}
                      desc_datetime_interval_code:=desc_type-((desc_type div 10){=SQL_DATETIME or SQL_INTERVAL}*10);
                      desc_length:=desc_precision; //todo reset precision & scale?

                      {SQL_DESC_PRECISION}
                      case desc_type of
                        SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
                        SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
                        begin
                          desc_precision:=desc_scale;
                        end;
                      else
                        desc_precision:=0;
                      end; {case SQL_DESC_PRECISION}

                      {SQL_DESC_DATETIME_INTERVAL_PRECISION}
                      case desc_type of
                        SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
                          {no SQL_DESC_DATETIME_INTERVAL_PRECISION} ;
                        SQL_INTERVAL_YEAR_TO_MONTH, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_HOUR_TO_MINUTE:
                        begin //columnSize-4
                          desc_datetime_interval_precision:=desc_precision-4;
                        end;
                        SQL_INTERVAL_DAY_TO_MINUTE:
                        begin //columnSize-7
                          desc_datetime_interval_precision:=desc_precision-7;
                        end;
                        SQL_INTERVAL_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-2
                          else
                            desc_datetime_interval_precision:=desc_precision-1;
                        end;
                        SQL_INTERVAL_DAY_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-11
                          else
                            desc_datetime_interval_precision:=desc_precision-10;
                        end;
                        SQL_INTERVAL_HOUR_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-8
                          else
                            desc_datetime_interval_precision:=desc_precision-7;
                        end;
                        SQL_INTERVAL_MINUTE_TO_SECOND:
                        begin
                          if desc_scale<>0 then
                            desc_datetime_interval_precision:=desc_precision-desc_scale-5
                          else
                            desc_datetime_interval_precision:=desc_precision-4;
                        end;
                      else //columnSize-1
                        desc_datetime_interval_precision:=desc_precision-1;
                      end; {case SQL_DESC_DATETIME_INTERVAL_PRECISION}

                      {Now we can set the verbose type}
                      desc_type:=(desc_type div 10){=SQL_DATETIME or SQL_INTERVAL};
                    end; {datetime/interval}

                    SQL_CHAR, SQL_VARCHAR, {SQL_BIT, SQL_BIT_VARYING not standard,} 
                    SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
                    SQL_LONGVARCHAR{todo debug test...remove?}:
                    begin
                      desc_length:=desc_precision;
                      {Temporary fix to workaround ODBC express errors - todo **** get server to return better limit!}
                      if (desc_length=0) and (desc_type=SQL_VARCHAR) then desc_length:=MAX_VARCHAR_TEMP_FIX;
                    end; {other}
                  else
                    //todo error?! - or just set type instead?
                    result:=SQL_ERROR;
                    s.diagnostic.logError(ssHY004,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                    exit;
                  end; {case}
                end; {with}
              end
              else
              begin
                //error, skip this column: need to consume the rest of this column definition anyway -> sink
                //todo or, could abort the whole routine instead?
                //note: currently getRecord cannot fail!
                {$IFDEF DEBUGDETAIL}
                log(format('SQLParamData failed getting desc record %d - rest of column defs abandoned...',[rn])); //todo debug error only - remove
                {$ENDIF}              
                result:=SQL_ERROR;
                s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
                exit; //todo: just for now!
              end;

              inc(i);
            end; {while}
          end;
          //else no late result set: leave as was
        end;
        //else young server cannot handle this

        case resultCode of
          //todo**** check the state-transition table...currently taken from SQLExecute = good base, but not complete
          //may need to retain original SQLExecute state...when SQLexecute first goes into S8!
          SQL_SUCCESS, SQL_SUCCESS_WITH_INFO:
          begin
            //todo if update/delete affected 0 rows, we need to return SQL_NO_DATA
            if not(s.resultSet) then //no results
              s.state:=S4
            else //results
            begin
              s.state:=S5;
              s.cursor.state:=csOpen;
              if s.cursor.name='' then s.cursor.name:=GetDefaultCursorName; //todo check right place to do this
            end;
          end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
          SQL_NEED_DATA:
          begin
            {Get the next missing parameter reference from the server}
            getSQLSMALLINT(rn); //todo save rn for putData use...
            {and translate this into the user's reference}
            if s.apd.getRecord(rn,Adr,True)=ok then
            begin
              //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
              with Adr do
              begin
                //todo return (pointer to?) data_pointer...
                Value^:=desc_data_ptr;  //todo check pointing!!!!
                {$IFDEF DEBUGDETAIL}
                log(format('SQLParamData returns %d reference %p',[rn,desc_data_ptr]));
                {$ENDIF}
              end; {with}
            end;
            s.state:=S9;
          end; {SQL_NEED_DATA}
          SQL_STILL_EXECUTING:
          begin
            s.state:=S11;
          end; {SQL_STILL_EXECUTING}
          SQL_ERROR:
          begin
            if not(s.resultSet) then //no results
              s.state:=S2
            else
              s.state:=S3;
          end; {SQL_ERROR}
        else
          //(else) should never happen!?
        end; {case}
      end; {with}
    end; {S8,S10}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLParamData}

///// SQLPutData /////

function SQLPutData  (StatementHandle:SQLHSTMT;
		 Data:SQLPOINTER;
		 StrLen_or_Ind:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

//todo remove  dataPtr:SQLPOINTER;
//todo remove  lenPtr:pSQLINTEGER;
//todo remove  statusPtr:pSQLUSMALLINT;

//todo remove  i:SQLINTEGER; //todo word ok?
//todo remove  rn:SQLSMALLINT;
//todo remove  adr,idr:TdescRec;

  tempsdw:SDWORD;
  tempNull:SQLSMALLINT;

//todo remove  offsetSize:SQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLPutData called %d %d',[StatementHandle,StrLen_or_Ind]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  case s.state of
    S1, S2..S3, S4, S5..S7, S8:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1,S2..S3,S4,S5..S7,S8}
    S9,S10:
      {todo
       call SQLputData on server (server is aware of 'next param to be filled' - last call to ParamData/Execute would have returned this) )
      }
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLPUTDATA);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref

      //todo: copy code from SQLExecute: add extra clauses to set dataPtr and lenPtr
      //- but we still need concept of paramNo- get & save from last execute/paramData call
      //-also maybe better to send row + colCount for future growth, e.g. may send multiple put blocks at once?
      // (the current code assumes we're sending character/binary only & only in one chunk!)

        {Put the null flag}
        tempNull:=SQL_FALSE; //default
        if StrLen_or_Ind=SQL_NULL_DATA then tempNull:=SQL_TRUE;
        if putSQLSMALLINT(tempNull)<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        tempsdw:=0; //todo: remove: only set for debug message below -speed

        if tempNull=SQL_FALSE then
        begin
          //Note: we only send length+data if not null
          //todo maybe don't set tempsdw if null will be set below?

          //todo assert column is DATA_AT_EXEC?
          //todo assert column is char or binary?

          //todo need to be able to send simple types, i.e. set our own length etc.
          //- get code from SQLexecute... => we need param-ref: store in SQLparamData:need_data
          // (the current code assumes we're sending character/binary only & only in one chunk!)

          begin //no conversion required
            //note: we don't add \0 here
            //todo we should if user has given len=NTS!!!!!!!! ***
            // -is there an inverse rule to this for the receival side(fetch)?

          //todo remove: debug for strings only!!!!
            {Fix string lengths}
            if FixStringSDWORD(Data,StrLen_or_Ind)<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
              exit;
            end;

          //todo should be putDataSDWORD !!!! debug for strings only!!!!
          //-especially since this prevents us calling SQLputData more than once for the same parameter=the whole point!!!!
            if putpUCHAR_SDWORD(Data,StrLen_or_Ind{todo very crude!})<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
            {$IFDEF DEBUGDETAIL}
            log(format('SQLPutData sent parameter todo!d data: %d bytes, null=%d',[{todo! rn,}StrLen_or_Ind{todo crude!},tempNull])); //todo debug only
            {$ENDIF}
          end;
        end;


        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLPUTDATA then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLPutData returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seNoMissingParameter:    resultState:=ssHY000; 
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        case resultCode of
          SQL_SUCCESS, SQL_SUCCESS_WITH_INFO:
          begin
            if s.state=S9 then
              s.state:=S10;
          end; {SQL_SUCCESS, SQL_SUCCESS_WITH_INFO}
          SQL_STILL_EXECUTING:
          begin
            s.state:=S11;
          end; {SQL_STILL_EXECUTING}
          SQL_ERROR:
          begin
            if not(s.resultSet) then //no results
              s.state:=S2
            else
              s.state:=S3;
          end; {SQL_ERROR}
          //todo etc.
        else
         //should never happen
        end; {case}
      end; {with}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLPutData}

(*
///// SQLSetConnectOption /////

RETCODE SQL_API SQLSetConnectOption  (HDBC arg0,
		 UWORD arg1,
		 UDWORD arg2)
{
	log("SQLSetConnectOption called\n");
	return(SQL_SUCCESS);
}

///// SQLSetStmtOption /////

RETCODE SQL_API SQLSetStmtOption  (HSTMT arg0,
		 UWORD arg1,
		 UDWORD arg2)
{
	log("SQLSetStmtOption called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLSpecialColumns /////

function SQLSpecialColumns  (StatementHandle:HSTMT;
		 IdentifierType:UWORD;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD;
		 Scope:UWORD;
		 Nullable:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

//  catPattern, schemPattern, tablePattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSpecialColumns called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  if IdentifierType<>SQL_BEST_ROWID then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY097,fail,'',0,0); //todo check result
    exit;
  end;
  if not(Scope in [SQL_SCOPE_CURROW,SQL_SCOPE_TRANSACTION,SQL_SCOPE_SESSION]) then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY098,fail,'',0,0); //todo check result
    exit;
  end;
  if not(Nullable in [SQL_NO_NULLS,SQL_NULLABLE]) then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY099,fail,'',0,0); //todo check result
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName else tablePattern:=SQL_ALL_TABLES;
  *)

  (*todo remove
  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLSpecialColumns called with embedded ., %s',[tablePattern]));
    {$ENDIF}
    //todo: really should move left portion to schemPattern...
//todo!    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
  *)

(*todo re-instate when SARGs are passed into sub-selects...
  //Note: copied from SQLcolumns - todo: keep in sync.
  query:='SELECT '+
         '  '+intToStr(SQL_SCOPE_TRANSACTION)+' AS SCOPE, '+ //todo fixed?
         '  COLUMN_NAME, '+
         '  CASE DATA_TYPE '+
         '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
         '    WHEN ''NUMERIC'' THEN 2 '+
         '    WHEN ''DECIMAL'' THEN 3 '+
         '    WHEN ''INTEGER'' THEN 4 '+
         '    WHEN ''SMALLINT'' THEN 5 '+
         '    WHEN ''FLOAT'' THEN 6 '+
         '    WHEN ''REAL'' THEN 7 '+
         '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
//todo         '    WHEN ''VARCHAR'' THEN 12 '+
         '    WHEN ''CHARACTER VARYING'' THEN 12 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  END AS DATA_TYPE, '+
         '  DATA_TYPE AS TYPE_NAME, '+
         '  CASE '+
         '    WHEN DATA_TYPE=''CHARACTER'' '+
//todo          '      OR DATA_TYPE=''VARCHAR'' '+
         '      OR DATA_TYPE=''CHARACTER VARYING'' '+
         //todo etc.
         '    THEN CHARACTER_MAXIMUM_LENGTH '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '      OR DATA_TYPE=''SMALLINT'' '+
         '      OR DATA_TYPE=''INTEGER'' '+
         '      OR DATA_TYPE=''REAL'' '+
         '      OR DATA_TYPE=''FLOAT'' '+
         '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
         '    THEN NUMERIC_PRECISION '+
         //todo etc.
         '  END AS COLUMN_SIZE, '+
         '  CHARACTER_OCTET_LENGTH AS BUFFER_LENGTH, '+
         '  CASE '+
         '    WHEN DATA_TYPE=''DATE'' '+
         //todo etc.
         '    THEN DATETIME_PRECISION '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '      OR DATA_TYPE=''SMALLINT'' '+
         '      OR DATA_TYPE=''INTEGER'' '+
         '    THEN NUMERIC_SCALE '+
         '  ELSE NULL '+
         '  END AS DECIMAL_DIGITS, '+
         '  '+intToStr(SQL_PC_NOT_PSEUDO)+' AS pseudocolumn '+ //todo fixed?
         'FROM '+
         ' ('+information_schemaName+'.KEY_COLUMN_USAGE AS K JOIN '+
         ' '+information_schemaName+'.TABLE_CONSTRAINTS AS P '+
         ' ON K.CONSTRAINT_CATALOG=P.CONSTRAINT_CATALOG '+
         ' AND K.CONSTRAINT_SCHEMA=P.CONSTRAINT_SCHEMA '+
         ' AND K.CONSTRAINT_NAME=P.CONSTRAINT_NAME '+
         ' ) NATURAL JOIN '+information_schemaName+'.COLUMNS '+   //todo remove natural join=speed
         'WHERE '+
         '  K.TABLE_CATALOG LIKE '''+catPattern+''' '+
         '  AND K.TABLE_SCHEMA LIKE '''+schemPattern+''' '+
         '  AND K.TABLE_NAME LIKE '''+tablePattern+''' '+
//todo?         '  AND SCOPE = '+intToStr(scope)+' '+
         'ORDER BY SCOPE '+
         '; ';
*)

  //Note: copied from SQLcolumns - todo: keep in sync.
  query:='SELECT '+
         '  '+intToStr(SQL_SCOPE_TRANSACTION)+' AS SCOPE, '+ //todo fixed?
         '  COLUMN_NAME, '+
         '  CASE type_name '+
         '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
         '    WHEN ''NUMERIC'' THEN 2 '+
         '    WHEN ''DECIMAL'' THEN 3 '+
         '    WHEN ''INTEGER'' THEN 4 '+
         '    WHEN ''SMALLINT'' THEN 5 '+
         '    WHEN ''FLOAT'' THEN 6 '+
         '    WHEN ''REAL'' THEN 7 '+
         '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
//todo         '    WHEN ''VARCHAR'' THEN 12 '+
         '    WHEN ''CHARACTER VARYING'' THEN 12 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  END AS DATA_TYPE, '+
         '  TYPE_NAME, '+
         '  CASE '+
         '    WHEN type_name=''CHARACTER'' '+
//todo          '      OR DATA_TYPE=''VARCHAR'' '+
         '      OR type_name=''CHARACTER VARYING'' '+
         //todo etc.
         '    THEN width '+
         '    WHEN type_name=''NUMERIC'' '+
         '      OR type_name=''DECIMAL'' '+
         '    THEN width '+
         '    WHEN type_name=''SMALLINT'' THEN 5 '+
         '    WHEN type_name=''INTEGER'' THEN 10 '+
         '    WHEN type_name=''REAL'' THEN 7 '+
         '    WHEN type_name=''FLOAT'' '+
         '      OR type_name=''DOUBLE PRECISION'' '+
         '    THEN 15 '+
         //todo etc.
         '  END AS COLUMN_SIZE, '+
         '  width AS BUFFER_LENGTH, '+
         '  CASE '+
         '    WHEN type_name=''DATE'' '+
         //todo etc.
         '    THEN scale '+
         '    WHEN type_name=''NUMERIC'' '+
         '      OR type_name=''DECIMAL'' '+
         '      OR type_name=''SMALLINT'' '+
         '      OR type_name=''INTEGER'' '+
         '    THEN scale '+
         '  ELSE NULL '+
         '  END AS DECIMAL_DIGITS, '+
         '  '+intToStr(SQL_PC_NOT_PSEUDO)+' AS pseudocolumn '+ //todo fixed?
         'FROM '+
         '    '+catalog_definition_schemaName+'.sysCatalog natural join'+
         '    '+catalog_definition_schemaName+'.sysSchema natural join'+
         '    '+catalog_definition_schemaName+'.sysConstraintColumn natural join'+
         '    '+catalog_definition_schemaName+'.sysConstraint join'+
         '    '+catalog_definition_schemaName+'.sysTable on FK_child_table_id=table_id join'+
         '    ('+
         '    '+information_schemaName+'.TYPE_INFO natural join'+
         '    '+catalog_definition_schemaName+'.sysColumn'+
         '    ) using (table_id,column_id)'+
         'WHERE '+
         '  parent_or_child_table=''C'' '+
         '  AND rule_type in (0,1) '+   //i.e. unique or primary        //todo maybe should just pick best? 

         ' AND catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
//todo?         '  AND SCOPE = '+intToStr(scope)+' '+
         'ORDER BY SCOPE '+
         '; ';

  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLSpecialColumns}

///// SQLStatistics /////

function SQLStatistics  (hstmt:HSTMT;
		 szTableQualifier:pUCHAR;
		 cbTableQualifier:SWORD;
		 szTableOwner:pUCHAR;
		 cbTableOwner:SWORD;
		 szTableName:pUCHAR;
		 cbTableName:SWORD;
		 fUnique:UWORD;
		 fAccuracy:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  //catPattern, schemPattern,
  schemPattern,tablePattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLStatistics called %d',[hstmt]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(hstmt);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(szTableQualifier,cbTableQualifier)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(szTableOwner,cbTableOwner)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(szTableName,cbTableName)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  {$IFDEF DEBUGDETAIL}
  if szTableQualifier<>nil then log(format('SQLStatistics called with szTableQualifier %s',[szTableQualifier]));
  if szTableOwner<>nil then log(format('SQLStatistics called with szTableOwner %s',[szTableOwner]));
  if szTableName<>nil then log(format('SQLStatistics called with szTableName %s',[szTableName]));
  {$ENDIF}

  (*todo remove
  if szTableQualifier<>'' then catPattern:=szTableQualifier else catPattern:=SQL_ALL_CATALOGS;
  if szTableOwner<>'' then schemPattern:=szTableOwner else schemPattern:=SQL_ALL_SCHEMAS;
  *)
  if szTableName<>'' then tablePattern:=szTableName; // else tablePattern:=SQL_ALL_TABLES;
  if szTableOwner<>'' then schemPattern:=szTableOwner;

  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...  log(format('SQLStatistics called with %s %s %s',[catPattern,schemPattern, tablePattern]));
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLStatistics called with embedded ., will split %s',[tablePattern]));
    {$ENDIF}
    //done: really should move left portion to schemPattern...
    //

    //todo do we still need this here? Has been removed from elsewhere... I think we do for dbExplorer!
    schemPattern:=copy(tablePattern,1,pos('.',tablePattern)-1);
    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
(*todo reinstate when view optimisation is improved?
  query:='SELECT '+
         '  K.TABLE_CATALOG AS table_cat, '+
//todo '  '''' AS table_cat, '+
//todo remove BASTARD!
//todo '  '''' AS table_schem, '+
         '  K.TABLE_SCHEMA AS table_schem, '+

//         '  K.TABLE_SCHEMA||''.''||K.TABLE_NAME AS TABLE_NAME, '+
         '  K.TABLE_NAME, '+
//         '  ''0'' as NON_UNIQUE, '+       //todo use SQL_FALSE
         '  0 as NON_UNIQUE, '+       //todo use SQL_FALSE
         '  null AS INDEX_QUALIFIER, '+
         '  K.CONSTRAINT_NAME AS INDEX_NAME, '+
         '  '+intToStr(SQL_INDEX_CLUSTERED)+' AS TYPE, '+
//         '  '+intToStr(SQL_INDEX_OTHER)+' AS TYPE, '+
//         '  '''+intToStr(SQL_INDEX_OTHER)+''' AS TYPE, '+
         '  K.ORDINAL_POSITION, '+
         '  K.COLUMN_NAME, '+
         '  null AS ASC_OR_DESC, '+
//todo         '  ''A'' AS ASC_OR_DESC, '+
         '  null AS CARDINALITY, '+
         '  null AS PAGES, '+
         '  null AS FILTER_CONDITION '+
         'FROM '+
         ' '+information_schemaName+'.KEY_COLUMN_USAGE AS K JOIN '+
         ' '+information_schemaName+'.TABLE_CONSTRAINTS AS P '+
         ' ON K.CONSTRAINT_CATALOG=P.CONSTRAINT_CATALOG '+
         ' AND K.CONSTRAINT_SCHEMA=P.CONSTRAINT_SCHEMA '+
         ' AND K.CONSTRAINT_NAME=P.CONSTRAINT_NAME '+
         'WHERE '+
         '  K.TABLE_CATALOG LIKE '''+catPattern+''' '+
         '  AND K.TABLE_SCHEMA LIKE '''+schemPattern+''' '+
         '  AND K.TABLE_NAME LIKE '''+tablePattern+''' '+
         '  AND P.CONSTRAINT_TYPE=''PRIMARY KEY'' '+
         'ORDER BY '+{todo no need, fixed! NON_UNIQUE,TYPE, INDEX_QUALIFIER,}'INDEX_NAME, ORDINAL_POSITION '+
         //todo remove: 'ORDER BY table_cat, table_schem, TABLE_NAME, ORDINAL_POSITION '+
         '; ';
*)
  query:='SELECT '+
         '  PC.catalog_name AS table_cat, '+
         '  PS.schema_name AS table_schem, '+
         '  PT.table_name AS TABLE_NAME, '+
         '  0 as NON_UNIQUE, '+       //todo use SQL_FALSE
         '  null AS INDEX_QUALIFIER, '+
         '  constraint_name AS INDEX_NAME, '+
         '  '+intToStr(SQL_INDEX_CLUSTERED)+' AS TYPE, '+
         '  column_sequence AS ORDINAL_POSITION, '+
         '  PL.column_name AS COLUMN_NAME, '+
         '  null AS ASC_OR_DESC, '+
//todo         '  ''A'' AS ASC_OR_DESC, '+
         '  null AS CARDINALITY, '+
         '  null AS PAGES, '+
         '  null AS FILTER_CONDITION '+
         'FROM '+
         ' '+catalog_definition_schemaName+'.sysCatalog PC, '+
         ' '+catalog_definition_schemaName+'.sysSchema PS, '+
         ' '+catalog_definition_schemaName+'.sysColumn PL, '+
         ' '+catalog_definition_schemaName+'.sysTable PT, '+
         ' ('+catalog_definition_schemaName+'.sysConstraintColumn J natural join '+
         ' '+catalog_definition_schemaName+'.sysConstraint ) '+
         'WHERE '+
         ' parent_or_child_table=''C'' '+
//         AND FK_parent_table_id=0
         ' AND rule_type=1 '+
         ' AND FK_child_table_id=PT.table_id '+
         ' AND PT.schema_id=PS.schema_id '+
         ' AND PS.catalog_id=PC.catalog_id '+
         ' AND J.column_id=PL.column_id '+
         ' AND PL.table_id=PT.table_id '+

         //' AND PC.catalog_name =CURRENT_CATALOG '+
         //' AND PS.schema_name =CURRENT_SCHEMA '+
         //todo following ok? or is it the catalog_name? or both?
         ' AND PC.catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,szTableQualifier),'CURRENT_CATALOG')+
         ' AND PS.schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,schemPattern),'CURRENT_SCHEMA')+
         ' AND PT.TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,tablePattern)+

         //todo schema/catalog as well
         'ORDER BY '+{todo no need, fixed! NON_UNIQUE,TYPE, INDEX_QUALIFIER,}'INDEX_NAME, ORDINAL_POSITION ';

  result:=SQLExecDirect(hstmt,pchar(query),length(query));
end; {SQLStatistics}


///// SQLTables /////

function SQLTables  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD;
		 TableType:pUCHAR;
		 NameLength4:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  catPattern, schemPattern, tablePattern, typePattern:string;
  queryType:integer;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLTables called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableType,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

(*
  if catalogName=nil then catalogName:='';
  if SchemaName=nil then SchemaName:='';
  if TableName=nil then TableName:='';
  if TableType=nil then TableType:='';
*)
  catPattern:=CatalogName;
  schemPattern:=SchemaName;
  tablePattern:=TableName;
  typePattern:=TableType;

  queryType:=4; //standard table search

  if (catPattern=SQL_ALL_CATALOGS) and (schemPattern='') and (tablePattern='') and (typePattern='') then queryType:=1; //catalog search
  if (catPattern='') and (schemPattern=SQL_ALL_SCHEMAS) and (tablePattern='') and (typePattern='') then queryType:=2; //schema search
  if (catPattern='') and (schemPattern='') and (tablePattern='') and (typePattern=SQL_ALL_TABLE_TYPES) then queryType:=3; //table-type search

  if CatalogName<>'' then catPattern:=CatalogName; // else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName; // else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName; // else tablePattern:=SQL_ALL_TABLES;
  {todo reinstate: debugging MSquery! if TableType<>'' then typePattern:=TableType else} //typePattern:=SQL_ALL_TABLES;
  //todo: need to handle CSV format...
  {If tableType is not quoted (e.g. quoted from BDE/Query Tool, not from AQueryx), then quote it now}
  if copy(typePattern,1,1)<>'''' then typePattern:=''''+typePattern+'''';
  {Most clients should see the information_schema views, but most only look for 'TABLE' and 'VIEW', so auto-append 'SYSTEM TABLE' whenever we see 'VIEW'}
  if (typePattern<>'') and (pos('VIEW',uppercase(typePattern))<>0) and (pos('SYSTEM TABLE',uppercase(typePattern))=0) then
    typePattern:=typePattern+',''SYSTEM TABLE''';

  //todo remove: log(format('SQLTables called with %s %s %s %s',[catPattern,schemPattern, tablePattern, typePattern]));
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLTables called with embedded ., will split %s',[tablePattern]));
    {$ENDIF}
    //done: really should move left portion to schemPattern...
    //todo reinstate? //
    //todo do we still need this here? Has been removed from elsewhere...I think we do for dbExplorer!

    schemPattern:=copy(tablePattern,1,pos('.',tablePattern)-1);
    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;


(*todo remove old version
  //todo improve! -& fix table type column! - need CASE? & when View + INFORMATION_SCHEMA => System Table
  //todo use a single information_schema view, since catalog_def schema will become invisible
  query:='SELECT catalog_name as TABLE_CAT, schema_name as TABLE_SCHEM, '+
         'table_name as TABLE_NAME, '+
         'CASE table_type WHEN ''B'' THEN ''TABLE'' WHEN ''V'' THEN ''VIEW'' ELSE table_type END as TABLE_TYPE, '+
         'null as REMARKS '+
         'FROM '+catalog_definition_schemaName+'.sysTable T natural join '+catalog_definition_schemaName+'.sysSchema S '+
         'natural join '+catalog_definition_schemaName+'.sysCatalog '+
         'WHERE '+
         'catalog_name LIKE '''+catPattern+''' '+
         'AND schema_name LIKE '''+schemPattern+''' '+
         'AND table_name LIKE '''+tablePattern+''' '+
         'AND table_type LIKE '''+typePattern+''' '+
         '; ';
*)
  query:='';
  case queryType of
    1: query:='SELECT DISTINCT '+
         'TABLE_CATALOG AS table_cat, '+
         'null, '+
         'null, '+
         'null, '+
         'null '+
         'FROM '+information_schemaName+'.TABLES ';

    2: query:='SELECT DISTINCT '+
         'null, '+
         'TABLE_SCHEMA AS table_schem, '+
         'null, '+
         'null, '+
         'null '+
         'FROM '+information_schemaName+'.TABLES ';

    3: query:='SELECT DISTINCT '+
         'null, '+
         'null, '+
         'null, '+
         'CASE TABLE_TYPE '+
         '  WHEN ''VIEW      '' THEN '+  //todo padded to match BASE TABLE since CASE results are pre-fixed currently...
         '    CASE TABLE_SCHEMA '+
         '      WHEN ''INFORMATION_SCHEMA'' THEN ''SYSTEM TABLE'' '+
         '    ELSE '+
         '      ''VIEW'' '+
         '    END '+
         '  WHEN ''BASE TABLE'' THEN ''TABLE'' '+
         'ELSE '+
         '  TABLE_TYPE '+
         'END AS TABLE_TYPE, '+
         'null '+
         'FROM '+information_schemaName+'.TABLES ';

    4: begin
       query:='SELECT '+
         '  TABLE_CATALOG AS table_cat, '+
//todo          '  '''' AS table_cat, '+
//todo remove: trying to hide owner to make dbExplorer etc. work
         '  TABLE_SCHEMA AS table_schem, '+
//todo         '  '''' AS table_schem, '+
         '  TABLE_NAME, '+
         '  CASE TABLE_TYPE '+
         '    WHEN ''VIEW      '' THEN '+  //todo padded to match BASE TABLE since CASE results are pre-fixed currently...
         '      CASE TABLE_SCHEMA '+
         '        WHEN ''INFORMATION_SCHEMA'' THEN ''SYSTEM TABLE'' '+
         '      ELSE '+
         '        ''VIEW'' '+
         '      END '+
         '    WHEN ''BASE TABLE'' THEN ''TABLE'' '+
         '  ELSE '+
         '    TABLE_TYPE '+
         '  END AS TABLE_TYPE, '+
         '  null AS remarks '+
         'FROM '+
         '  '+information_schemaName+'.TABLES '+
         'WHERE '+
         ' TABLE_CATALOG '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,catPattern)+
         ' AND TABLE_SCHEMA '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,schemPattern)+
         ' AND TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,tablePattern);
         if typePattern<>'''''' then
         begin
           query:=query+
           ' AND '+
           '  CASE TABLE_TYPE '+
           '    WHEN ''VIEW      '' THEN '+  //todo padded to match BASE TABLE since CASE results are pre-fixed currently...
           '      CASE TABLE_SCHEMA '+
           '        WHEN ''INFORMATION_SCHEMA'' THEN ''SYSTEM TABLE'' '+
           '      ELSE '+
           '        ''VIEW'' '+
           '      END '+
           '    WHEN ''BASE TABLE'' THEN ''TABLE'' '+
           '  ELSE '+
           '    TABLE_TYPE '+
           '  END IN ('+typePattern+')';  {already quoted and comma separated!?} //
           //todo remove: alias conflicts with base: 'TABLE_TYPE='+typePattern+' '+{already quoted!?} //todo remove: patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableType)+
         end;
         //todo remove: no need?: '; ';
       end; {4}
  end; {case}
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLTables}

///// SQLBrowseConnect /////
function SQLBrowseConnect  (hdbc:HDBC;
           szConnStrIn:PUCHAR;
           cbConnStrIn:SWORD;
           szConnStrOut:PUCHAR;
           cbConnStrOutMax:SWORD;
           {UNALIGNED}pcbConnStrOut:PSWORD):RETCODE;
           {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
const
  ConnectionTemplate='*HOST:Server=?; UID:User=?; PWD:Password=?; *SERVER:Server.catalog=?';
var
  c:Tdbc;
  kvps:string;
  keyword,value:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLBrowseConnect called %d',[hdbc]));
  {$ENDIF}

  {Check handle}
  c:=Tdbc(hdbc);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(szConnStrIn,cbConnStrIn)<ok then
  begin
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  {Parse the connection string}
  kvps:=szConnStrIn;
  while parseNextKeywordValuePair(kvps,keyword,value) do
  begin
    keyword:=uppercase(trim(keyword));

    if (keyword=kDSN) or (keyword=kDRIVER) then
    begin //initial request, prompt for more
      strLcopy(pUCHAR(szConnStrOut),ConnectionTemplate,cbConnStrOutMax-1);
      pcbConnStrOut^:=length(ConnectionTemplate);
      result:=SQL_NEED_DATA;
      exit;
    end;
  end; {while more pairs}

  {Assume we have everything we need}
  //todo should prepend original string as well, e.g. DSN=;
  strLcopy(pUCHAR(szConnStrOut),szConnStrIn,cbConnStrOutMax-1);
  pcbConnStrOut^:=length(szConnStrIn);
  result:=SQL_SUCCESS; //default
end; {SQLBrowseConnect}

///// SQLColumnPrivileges /////

function SQLColumnPrivileges  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD;
		 ColumnName:pUCHAR;
		 NameLength4:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  //catPattern, schemPattern, tablePattern, columnPattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLColumnPrivileges called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(ColumnName,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName else tablePattern:=SQL_ALL_TABLES;
  if ColumnName<>'' then columnPattern:=ColumnName else columnPattern:=SQL_ALL_COLUMNS;
  *)

  (*todo remove
  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLColumnPrivileges called with embedded ., %s',[tablePattern]));
    {$ENDIF}
    //todo: really should move left portion to schemPattern...
//todo!    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
  *)

  query:='SELECT '+
         '  TABLE_CATALOG AS table_cat, '+
//todo         '  '''' AS table_cat, '+
         '  TABLE_SCHEMA AS table_schem, '+
//todo         '  '''' AS table_schem, '+
         '  TABLE_NAME, '+
         '  COLUMN_NAME, '+
         '  GRANTOR, '+
         '  GRANTEE, '+
         '  PRIVILEGE_TYPE AS privilege, '+
         '  IS_GRANTABLE '+
         'FROM '+
         '  '+information_schemaName+'.COLUMN_PRIVILEGES '+
         'WHERE '+
         ' TABLE_CATALOG '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND TABLE_SCHEMA '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
         ' AND COLUMN_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,ColumnName)+
         'ORDER BY table_cat, table_schem, TABLE_NAME, COLUMN_NAME, privilege '+
         '; ';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLColumnPrivileges}

(*
///// SQLDataSources /////

RETCODE SQL_API SQLDataSources  (HENV arg0,
		 UWORD arg1,
		 UCHAR * arg2,
		 SWORD arg3,
		 SWORD * arg4,
		 UCHAR * arg5,
		 SWORD arg6,
		 SWORD * arg7)
{
	log("SQLDataSources called\n");
	return(SQL_SUCCESS);
}
*)

(*
///// SQLDescribeParam /////
//debug ADO
function SQLDescribeParam(
    hstmt:HSTMT;
    ipar:UWORD;
    {UNALIGNED} pfSqlType:PSWORD;
    {UNALIGNED} pcbColDef:PUDWORD;
    {UNALIGNED} pibScale:PSWORD;
    {UNALIGNED} pfNullable:PSWORD):RETCODE;
                          {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLDescribeParam called %d',[hstmt]));
  {$ENDIF}
  result:=SQL_SUCCESS; //default
end; {SQLDescribeParam}
*)
(*
///// SQLExtendedFetch /////

//debug ADO - remove
function SQLExtendedFetch(
    hstmt:HSTMT;
    fFetchType:UWORD;
    irow:SDWORD;
    {UNALIGNED} pcrow:PUDWORD;
    {UNALIGNED} rgfRowStatus:PUWORD):RETCODE;
                          {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLExtendedFetch called %d',[hstmt]));
  {$ENDIF}
  result:=SQL_SUCCESS; //default
end; {}
*)
///// SQLForeignKeys /////

function SQLForeignKeys  (StatementHandle:SQLHSTMT;
		 PKCatalogName:pUCHAR;
		 NameLength1:SWORD;
		 PKSchemaName:pUCHAR;
		 NameLength2:SWORD;
		 PKTableName:pUCHAR;
		 NameLength3:SWORD;
		 FKCatalogName:pUCHAR;
		 NameLength4:SWORD;
		 FKSchemaName:pUCHAR;
		 NameLength5:SWORD;
		 FKTableName:pUCHAR;
		 NameLength6:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

//  PKcatPattern, PKschemPattern, PKtablePattern:string;
//  FKcatPattern, FKschemPattern, FKtablePattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLForeignKeys called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(PKCatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(PKSchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(PKTableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  if FixStringSWORD(FKCatalogName,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(FKSchemaName,NameLength5)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(FKTableName,NameLength6)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  //todo etc. and for all other routines!

  //todo: prevent tableNames from containing search patterns as per ODBC standard

  {$IFDEF DEBUGDETAIL}
  if PKCatalogName<>nil then log(format('SQLForeignKeys called with PKCatalogName %s',[PKCatalogName]));
  if PKSchemaName<>nil then log(format('SQLForeignKeys called with PKSchemaName %s',[PKSchemaName]));
  if PKTableName<>nil then log(format('SQLForeignKeys called with PKTableName %s',[PKTableName]));

  if FKCatalogName<>nil then log(format('SQLForeignKeys called with FKCatalogName %s',[FKCatalogName]));
  if FKSchemaName<>nil then log(format('SQLForeignKeys called with FKSchemaName %s',[FKSchemaName]));
  if FKTableName<>nil then log(format('SQLForeignKeys called with FKTableName %s',[FKTableName]));
  {$ENDIF}

  {Set FKcatalog/schema=PKcatalog/schema if null & vice versa...
   This is so relationships in other schemas can be retrieved
  }
  if PKCatalogName=nil then PKCatalogName:=FKCatalogName;
  if PKSchemaName=nil then PKSchemaName:=FKSchemaName;
  if FKCatalogName=nil then FKCatalogName:=PKCatalogName;
  if FKSchemaName=nil then FKSchemaName:=PKSchemaName;

  (*todo remove
  if PKCatalogName<>'' then PKcatPattern:=PKCatalogName else PKcatPattern:=SQL_ALL_CATALOGS;
  if PKSchemaName<>'' then PKschemPattern:=PKSchemaName else PKschemPattern:=SQL_ALL_SCHEMAS;
  if PKTableName<>'' then PKtablePattern:=PKTableName else PKtablePattern:=SQL_ALL_TABLES;

  if FKCatalogName<>'' then FKcatPattern:=FKCatalogName else FKcatPattern:=SQL_ALL_CATALOGS;
  if FKSchemaName<>'' then FKschemPattern:=FKSchemaName else FKschemPattern:=SQL_ALL_SCHEMAS;
  if FKTableName<>'' then FKtablePattern:=FKTableName else FKtablePattern:=SQL_ALL_TABLES;
  *)

  //todo handle schema.table from dbExplorer as other routines do...

  //todo check we have proper values - need some!
(*todo re-instate once views are optimised
  //todo: probably need distinct! although maybe not now we've fixed key_column_usage to just use 'C's
  //differs slightly from SQL standard, but this is an ODBC driver so we go with MS... but needs join to sysCatalog...
  query:='SELECT '+
//todo         '  UKCO.TABLE_CATALOG AS PKtable_cat, '+
         '  '''' AS PKtable_cat, '+
//todo         '  UKCO.TABLE_SCHEMA AS PKtable_schem, '+
         '  '''' AS PKtable_schem, '+
         '  UKCO.TABLE_NAME AS PKTABLE_NAME, '+
         '  UKCO.COLUMN_NAME AS PKCOLUMN_NAME, '+
//todo         '  FKCO.TABLE_CATALOG AS FKtable_cat, '+
         '  '''' AS FKtable_cat, '+
//todo          '  FKCO.TABLE_SCHEMA AS FKtable_schem, '+
         '  '''' AS FKtable_schem, '+
         '  FKCO.TABLE_NAME AS FKTABLE_NAME, '+
         '  FKCO.COLUMN_NAME AS FKCOLUMN_NAME, '+
         '  UKCO.ORDINAL_POSITION AS KEY_SEQ, '+
         '  CASE FK.UPDATE_RULE '+
         '    WHEN ''CASCADE'' THEN '+intToStr(SQL_CASCADE)+' '+
         '    WHEN ''SET NULL'' THEN '+intToStr(SQL_SET_NULL)+' '+
         '    WHEN ''NO ACTION'' THEN '+intToStr(SQL_NO_ACTION)+' '+
         '    WHEN ''SET DEFAULT'' THEN '+intToStr(SQL_SET_DEFAULT)+' '+
         '  END AS UPDATE_RULE, '+
         '  CASE FK.DELETE_RULE '+
         '    WHEN ''CASCADE'' THEN '+intToStr(SQL_CASCADE)+' '+
         '    WHEN ''SET NULL'' THEN '+intToStr(SQL_SET_NULL)+' '+
         '    WHEN ''NO ACTION'' THEN '+intToStr(SQL_NO_ACTION)+' '+
         '    WHEN ''SET DEFAULT'' THEN '+intToStr(SQL_SET_DEFAULT)+' '+
         '  END AS DELETE_RULE, '+
         '  FK.CONSTRAINT_NAME AS FK_NAME, '+
         '  UK.CONSTRAINT_NAME AS PK_NAME, '+
         '  CASE FKsys.initially_deferred '+
         '    WHEN ''Y'' THEN '+intToStr(SQL_INITIALLY_DEFERRED)+' '+
         '  ELSE'+
         '    CASE FKsys."deferrable" '+
         '      WHEN ''Y'' THEN '+intToStr(SQL_INITIALLY_IMMEDIATE)+' '+
         '    ELSE '+
         '      '+intToStr(SQL_NOT_DEFERRABLE)+' '+
         '    END '+
         '  END AS DEFERRABILITY '+
         'FROM '+
         '  '+catalog_definition_schemaName+'.sysConstraint AS FKsys, '+    //todo had to augment with sys catalog!
         '  '+information_schemaName+'.KEY_COLUMN_USAGE AS UKCO, '+
         '  '+information_schemaName+'.KEY_COLUMN_USAGE AS FKCO, '+
         '  '+information_schemaName+'.REFERENTIAL_CONSTRAINTS AS FK, '+
         '  '+information_schemaName+'.TABLE_CONSTRAINTS AS UK '+
         'WHERE '+
         '  UKCO.CONSTRAINT_NAME=UK.CONSTRAINT_NAME '+
         '  AND FKCO.CONSTRAINT_NAME=FK.CONSTRAINT_NAME '+
         '  AND FK.UNIQUE_CONSTRAINT_NAME=UK.CONSTRAINT_NAME '+
         '  AND FKsys.constraint_name=FK.CONSTRAINT_NAME '+

         '  AND UKCO.TABLE_CATALOG LIKE '''+PKcatPattern+''' '+
         '  AND UKCO.TABLE_SCHEMA LIKE '''+PKschemPattern+''' '+
         '  AND UKCO.TABLE_NAME LIKE '''+PKtablePattern+''' '+
         '  AND FKCO.TABLE_CATALOG LIKE '''+FKcatPattern+''' '+
         '  AND FKCO.TABLE_SCHEMA LIKE '''+FKschemPattern+''' '+
         '  AND FKCO.TABLE_NAME LIKE '''+FKtablePattern+''' '+
         'ORDER BY FKtable_cat, FKtable_schem, FKTABLE_NAME, KEY_SEQ ';
*)
  query:='SELECT '+
         ' PKTABLE_CAT, PKTABLE_SCHEM, PKTABLE_NAME, PKCOLUMN_NAME, '+
         ' FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, FKCOLUMN_NAME, '+
         ' column_sequence AS KEY_SEQ, '+
         ' CASE FK_on_update_action'+
         '   WHEN 0 THEN '+intToStr(SQL_NO_ACTION)+' '+
         '   WHEN 1 THEN '+intToStr(SQL_CASCADE)+' '+
         '   WHEN 2 THEN '+intToStr(SQL_RESTRICT)+' '+
         '   WHEN 3 THEN '+intToStr(SQL_SET_NULL)+' '+
         '   WHEN 4 THEN '+intToStr(SQL_SET_DEFAULT)+' '+
         ' END AS UPDATE_RULE, '+
         ' CASE FK_on_delete_action '+
         '   WHEN 0 THEN '+intToStr(SQL_NO_ACTION)+' '+
         '   WHEN 1 THEN '+intToStr(SQL_CASCADE)+' '+
         '   WHEN 2 THEN '+intToStr(SQL_RESTRICT)+' '+
         '   WHEN 3 THEN '+intToStr(SQL_SET_NULL)+' '+
         '   WHEN 4 THEN '+intToStr(SQL_SET_DEFAULT)+' '+
         ' END AS DELETE_RULE, '+
         ' constraint_name AS FK_NAME, '+
         ' CASE initially_deferred '+
         '   WHEN ''Y'' THEN '+intToStr(SQL_INITIALLY_DEFERRED)+' '+
         ' ELSE'+
         '   CASE "deferrable" '+
         '     WHEN ''Y'' THEN '+intToStr(SQL_INITIALLY_IMMEDIATE)+' '+
         '   ELSE '+
         '     '+intToStr(SQL_NOT_DEFERRABLE)+' '+
         '   END '+
         ' END AS DEFERRABILITY '+
         'FROM '+
         ' ( '+
//       PK
         ' SELECT '+
         ' PC.catalog_name AS PKTABLE_CAT, PS.schema_name AS PKTABLE_SCHEM, PT.table_name AS PKTABLE_NAME, PL.column_name AS PKCOLUMN_NAME, '+
         ' constraint_id, '+
         ' column_sequence , '+
         ' FK_child_table_id '+
         ' FROM '+
         ' '+catalog_definition_schemaName+'.sysCatalog PC, '+
         ' '+catalog_definition_schemaName+'.sysSchema PS, '+
         ' '+catalog_definition_schemaName+'.sysColumn PL, '+
         ' '+catalog_definition_schemaName+'.sysTable PT2, '+
         ' '+catalog_definition_schemaName+'.sysTable PT, '+
         ' ('+catalog_definition_schemaName+'.sysConstraintColumn J natural join '+
         ' '+catalog_definition_schemaName+'.sysConstraint ) '+
         ' WHERE '+
         ' parent_or_child_table=''P'' '+
//        AND FK_parent_table_id=0
         ' AND FK_parent_table_id=PT.table_id '+
         ' AND PT.schema_id=PS.schema_id '+
         ' AND PS.catalog_id=PC.catalog_id '+
         ' AND J.column_id=PL.column_id '+
         ' AND PL.table_id=PT.table_id '+

         ' AND FK_child_table_id=PT2.table_id '+

         ' AND PC.catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,PKCatalogName),'CURRENT_CATALOG')+
         ' AND PS.schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,PKSchemaName),'CURRENT_SCHEMA')+
         ' AND PT.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,PKTableName)+
         ' AND PT2.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,FKTableName)+
         //todo schema/catalog as well

         ' ) AS FKPARENT '+
         ' JOIN '+
         ' ( '+
//       FK
         ' SELECT '+
         ' PC.catalog_name AS FKTABLE_CAT, PS.schema_name AS FKTABLE_SCHEM, PT.table_name AS FKTABLE_NAME, PL.column_name AS FKCOLUMN_NAME, '+
         ' constraint_id, '+
         ' column_sequence, '+
         ' FK_on_update_action,  FK_on_delete_action, '+
         ' constraint_name, '+
         ' initially_deferred, '+
         ' "deferrable", '+
         ' FK_child_table_id '+
         ' FROM '+
         ' '+catalog_definition_schemaName+'.sysCatalog PC, '+
         ' '+catalog_definition_schemaName+'.sysSchema PS, '+
         ' '+catalog_definition_schemaName+'.sysColumn PL, '+
         ' '+catalog_definition_schemaName+'.sysTable PT2, '+
         ' '+catalog_definition_schemaName+'.sysTable PT, '+
         ' ('+catalog_definition_schemaName+'.sysConstraintColumn J natural join '+
         ' '+catalog_definition_schemaName+'.sysConstraint ) '+
         ' WHERE '+
         ' parent_or_child_table=''C'' '+
         ' AND FK_parent_table_id<>0 '+
         ' AND FK_child_table_id=PT.table_id '+
         ' AND PT.schema_id=PS.schema_id '+
         ' AND PS.catalog_id=PC.catalog_id '+
         ' AND J.column_id=PL.column_id '+
         ' AND PL.table_id=PT.table_id '+

         ' AND PC.catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,FKCatalogName),'CURRENT_CATALOG')+
         ' AND PS.schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,FKSchemaName),'CURRENT_SCHEMA')+
         ' AND FK_parent_table_id=PT2.table_id '+
         ' AND PT2.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,PKTableName)+
         ' AND PT.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,FKTableName)+
         //todo schema/catalog as well?

         ' ) AS FKCHILD '+

         ' USING (constraint_id, column_sequence, FK_child_table_id) '+
         'ORDER BY FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, KEY_SEQ ';

//         ' WHERE FK_child_table_id=28';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLForeignKeys}

(*
///// SQLMoreResults /////

//debug ADO
function SQLMoreResults(StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLMoreResults called %d',[StatementHandle]));
  {$ENDIF}
  result:=SQL_SUCCESS;
end; {SQLMoreResults}

///// SQLNativeSql /////
//debug ADO
function SQLNativeSql(
    hdbc:HDBC;
    szSqlStrIn:PUCHAR;
    cbSqlStrIn:SDWORD;
    szSqlStr:PUCHAR;
    cbSqlStrMax:SDWORD;
    {UNALIGNED} pcbSqlStr:PSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLNativeSql called %d',[hdbc]));
  {$ENDIF}
  result:=SQL_SUCCESS;
end; {SQLNativeSql}
*)
///// SQLNumParams /////

function SQLNumParams  (hstmt:SQLHSTMT;  //todo name ok? clash with type!?
		 pcpar:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLNumParams called %d',[hstmt]));
  {$ENDIF}

  {Check handle S0}
  s:=Tstmt(hstmt);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo check state check! just copied from numResultCols
  if (s.state<=S1) or (s.state>=S8) then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo go via getDescField instead - more checks/safer/more portable/maintainable?
  SWORD(pcpar^):=s.ipd.desc_count;

  result:=SQL_SUCCESS;
end; {SQLNumParams}
(*
///// SQLParamOptions /////

RETCODE SQL_API SQLParamOptions  (HSTMT arg0,
		 UDWORD arg1,
		 UNALIGNED UDWORD * arg2)
{
	log("SQLParamOptions called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLPrimaryKeys /////

function SQLPrimaryKeys  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  //catPattern, schemPattern, tablePattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLPrimaryKeys called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName else tablePattern:=SQL_ALL_TABLES;
  *)

  (*todo remove
  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLPrimaryKeys called with embedded ., %s',[tablePattern]));
    {$ENDIF}
    //todo: really should move left portion to schemPattern...
//todo!    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
  *)

(* todo reinstate once view optimisation is improved?
  query:='SELECT '+
         '  K.TABLE_CATALOG AS table_cat, '+
//todo         '  '''' AS table_cat, '+
         '  K.TABLE_SCHEMA AS table_schem, '+
//todo         '  '''' AS table_schem, '+
         '  K.TABLE_NAME, '+
         '  K.COLUMN_NAME, '+
         '  K.ORDINAL_POSITION, '+
         '  K.CONSTRAINT_NAME AS pk_name '+
         'FROM '+
         ' '+information_schemaName+'.KEY_COLUMN_USAGE AS K JOIN '+
         ' '+information_schemaName+'.TABLE_CONSTRAINTS AS P '+
         ' ON K.CONSTRAINT_CATALOG=P.CONSTRAINT_CATALOG '+
         ' AND K.CONSTRAINT_SCHEMA=P.CONSTRAINT_SCHEMA '+
         ' AND K.CONSTRAINT_NAME=P.CONSTRAINT_NAME '+
         'WHERE '+
         '  K.TABLE_CATALOG LIKE '''+catPattern+''' '+
         '  AND K.TABLE_SCHEMA LIKE '''+schemPattern+''' '+
         '  AND K.TABLE_NAME LIKE '''+tablePattern+''' '+
         '  AND P.CONSTRAINT_TYPE=''PRIMARY KEY'' '+
         'ORDER BY table_cat, table_schem, TABLE_NAME, ORDINAL_POSITION '+
         '; ';
*)
  query:='SELECT '+
         '  PC.catalog_name AS table_cat, '+
         '  PS.schema_name AS table_schem, '+
         '  PT.table_name AS TABLE_NAME, '+
         '  PL.column_name AS COLUMN_NAME, '+
         '  column_sequence AS ORDINAL_POSITION, '+
         '  constraint_name AS pk_name '+
         'FROM '+
         ' '+catalog_definition_schemaName+'.sysCatalog PC, '+
         ' '+catalog_definition_schemaName+'.sysSchema PS, '+
         ' '+catalog_definition_schemaName+'.sysColumn PL, '+
         ' '+catalog_definition_schemaName+'.sysTable PT, '+
         ' ('+catalog_definition_schemaName+'.sysConstraintColumn J natural join '+
         ' '+catalog_definition_schemaName+'.sysConstraint ) '+
         'WHERE '+
         ' parent_or_child_table=''C'' '+
//         AND FK_parent_table_id=0
         ' AND rule_type=1 '+
         ' AND FK_child_table_id=PT.table_id '+
         ' AND PT.schema_id=PS.schema_id '+
         ' AND PS.catalog_id=PC.catalog_id '+
         ' AND J.column_id=PL.column_id '+
         ' AND PL.table_id=PT.table_id '+

         ' AND PC.catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND PS.schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND PT.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
         //todo schema/catalog as well
         'ORDER BY table_cat, table_schem, TABLE_NAME, ORDINAL_POSITION ';

  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLPrimaryKeys}

///// SQLProcedureColumns /////

function SQLProcedureColumns  (StatementHandle:HSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 RoutineName:pUCHAR;
		 NameLength3:SWORD;
		 ParameterName:pUCHAR;
		 NameLength4:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

//  catPattern, schemPattern, tablePattern, columnPattern:string;
  query, query2:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLProcedureColumns called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(RoutineName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(ParameterName,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;

  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if RoutineName<>'' then routinePattern:=RoutineName else tablePattern:=SQL_ALL_TABLES;
  if ParameterName<>'' then parameterPattern:=ParameterName else parameterPattern:=SQL_ALL_COLUMNS;
  *)

  if ((s.owner as Tdbc).owner as Tenv).odbcVersion=SQL_OV_ODBC2 then
  begin //return old-fashioned date/time types
    query:='SELECT '+
           '  specific_catalog AS procedure_cat, '+
           '  specific_schema AS procedure_schem, '+
           '  specific_name AS procedure_name, '+
           '  PARAMETER_NAME AS column_name, '+
           '  CASE PARAMETER_MODE '+
           '    WHEN ''IN'' THEN '+intToStr(SQL_PARAM_INPUT)+
           '    WHEN ''INOUT'' THEN '+intToStr(SQL_PARAM_INPUT_OUTPUT)+
           '    WHEN ''OUT'' THEN '+intToStr(SQL_PARAM_OUTPUT)+
           '  ELSE '+intToStr(SQL_PARAM_TYPE_UNKNOWN)+
           '  END AS column_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS data_type, '+
           '  DATA_TYPE AS type_name, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''CHARACTER'' '+
           '      OR DATA_TYPE=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '    THEN NUMERIC_PRECISION '+
           '    WHEN DATA_TYPE=''SMALLINT'' THEN 5 '+
           '    WHEN DATA_TYPE=''INTEGER'' THEN 10 '+
           '    WHEN DATA_TYPE=''REAL'' THEN 7 '+
           '    WHEN DATA_TYPE=''FLOAT'' '+
           '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '    THEN 10 '+
           '    WHEN DATA_TYPE=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+NUMERIC_SCALE  '+
           '    WHEN DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''BINARY LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''CHARACTER LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  CHARACTER_MAXIMUM_LENGTH AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '      OR DATA_TYPE=''TIME'' '+
           '      OR DATA_TYPE=''TIMESTAMP'' '+
           '      OR DATA_TYPE=''TIME WITH TIME ZONE'' '+
           '      OR DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '      OR DATA_TYPE=''SMALLINT'' '+
           '      OR DATA_TYPE=''INTEGER'' '+
           '    THEN NUMERIC_SCALE '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUMERIC_PRECISION_RADIX AS NUM_PREC_RADIX, '+
           (*
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           *)
           '  '+intToStr(SQL_NULLABLE)+' AS nullable,'+ //since we can't specify not null or use domains for parameters
           '  null AS remarks, '+
           '  null AS COLUMN_DEF, '+  //todo read from sysParameters?
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  NULL '+
           '  AS sql_datetime_sub, '+
           '  NUMERIC_PRECISION AS char_octet_length, '+
           '  ORDINAL_POSITION+0 AS ORDINAL_POSITION, '+  //must be a number (not integer) for union compatibility
           (*
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           *)
           '  ''Y'' AS is_nullable '; //since we can't specify not null or use domains for parameters

    //Now get the result parameter
    query2:='SELECT '+
           '  specific_catalog AS procedure_cat, '+
           '  specific_schema AS procedure_schem, '+
           '  specific_name AS procedure_name, '+
           '  '''' AS column_name, '+
           '  '+intToStr(SQL_RETURN_VALUE)+' AS column_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS data_type, '+
           '  DATA_TYPE AS type_name, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''CHARACTER'' '+
           '      OR DATA_TYPE=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '    THEN NUMERIC_PRECISION '+
           '    WHEN DATA_TYPE=''SMALLINT'' THEN 5 '+
           '    WHEN DATA_TYPE=''INTEGER'' THEN 10 '+
           '    WHEN DATA_TYPE=''REAL'' THEN 7 '+
           '    WHEN DATA_TYPE=''FLOAT'' '+
           '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '    THEN 10 '+
           '    WHEN DATA_TYPE=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+NUMERIC_SCALE  '+
           '    WHEN DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''BINARY LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''CHARACTER LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  CHARACTER_MAXIMUM_LENGTH AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '      OR DATA_TYPE=''TIME'' '+
           '      OR DATA_TYPE=''TIMESTAMP'' '+
           '      OR DATA_TYPE=''TIME WITH TIME ZONE'' '+
           '      OR DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '      OR DATA_TYPE=''SMALLINT'' '+
           '      OR DATA_TYPE=''INTEGER'' '+
           '    THEN NUMERIC_SCALE '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUMERIC_PRECISION_RADIX AS NUM_PREC_RADIX, '+
           (*
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           *)
           '  '+intToStr(SQL_NULLABLE)+' AS nullable,'+ //since we can't specify not null or use domains for parameters
           '  null AS remarks, '+
           '  null AS COLUMN_DEF, '+  //todo read from sysParameters?
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 10 '+
           '    WHEN ''TIMESTAMP'' THEN 11 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 11 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  NULL '+
           '  AS sql_datetime_sub, '+
           '  NUMERIC_PRECISION AS char_octet_length, '+
           '  0 AS ORDINAL_POSITION, '+ //must be a number to union match
           (*
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           *)
           '  ''Y'' AS is_nullable ' //since we can't specify not null or use domains for parameters
  end
  else //return standard v3 date/time types
  begin
    query:='SELECT '+
           '  specific_catalog AS procedure_cat, '+
           '  specific_schema AS procedure_schem, '+
           '  specific_name AS procedure_name, '+
           '  PARAMETER_NAME AS column_name, '+
           '  CASE PARAMETER_MODE '+
           '    WHEN ''IN'' THEN '+intToStr(SQL_PARAM_INPUT)+
           '    WHEN ''INOUT'' THEN '+intToStr(SQL_PARAM_INPUT_OUTPUT)+
           '    WHEN ''OUT'' THEN '+intToStr(SQL_PARAM_OUTPUT)+
           '  ELSE '+intToStr(SQL_PARAM_TYPE_UNKNOWN)+
           '  END AS column_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 91 '+
           '    WHEN ''TIME'' THEN 92 '+
           '    WHEN ''TIMESTAMP'' THEN 93 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 94 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 95 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS data_type, '+
           '  DATA_TYPE AS type_name, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''CHARACTER'' '+
           '      OR DATA_TYPE=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '    THEN NUMERIC_PRECISION '+
           '    WHEN DATA_TYPE=''SMALLINT'' THEN 5 '+
           '    WHEN DATA_TYPE=''INTEGER'' THEN 10 '+
           '    WHEN DATA_TYPE=''REAL'' THEN 7 '+
           '    WHEN DATA_TYPE=''FLOAT'' '+
           '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '    THEN 10 '+
           '    WHEN DATA_TYPE=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+NUMERIC_SCALE  '+
           '    WHEN DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''BINARY LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''CHARACTER LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  CHARACTER_MAXIMUM_LENGTH AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '      OR DATA_TYPE=''TIME'' '+
           '      OR DATA_TYPE=''TIMESTAMP'' '+
           '      OR DATA_TYPE=''TIME WITH TIME ZONE'' '+
           '      OR DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '      OR DATA_TYPE=''SMALLINT'' '+
           '      OR DATA_TYPE=''INTEGER'' '+
           '    THEN NUMERIC_SCALE '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUMERIC_PRECISION_RADIX AS NUM_PREC_RADIX, '+
           (*
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           *)
           '  '+intToStr(SQL_NULLABLE)+' AS nullable,'+ //since we can't specify not null or use domains for parameters
           '  null AS remarks, '+
           '  null AS COLUMN_DEF, '+  //todo read from sysParameters?
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 9 '+
           '    WHEN ''TIMESTAMP'' THEN 9 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''DATE'' THEN 1 '+
           '    WHEN ''TIME'' THEN 2 '+
           '    WHEN ''TIMESTAMP'' THEN 3 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 4 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 5 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  ELSE NULL '+
           '  END AS sql_datetime_sub, '+
           '  NUMERIC_PRECISION AS char_octet_length, '+
           '  ORDINAL_POSITION+0 AS ORDINAL_POSITION, '+  //must be a number (not integer) for union compatibility
           (*
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           *)
           '  ''Y'' AS is_nullable '; //since we can't specify not null or use domains for parameters

    //Now get the result parameter
    query2:='SELECT '+
           '  specific_catalog AS procedure_cat, '+
           '  specific_schema AS procedure_schem, '+
           '  specific_name AS procedure_name, '+
           '  '''' AS column_name, '+
           '  '+intToStr(SQL_RETURN_VALUE)+' AS column_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants!
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 91 '+
           '    WHEN ''TIME'' THEN 92 '+
           '    WHEN ''TIMESTAMP'' THEN 93 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 94 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 95 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS data_type, '+
           '  DATA_TYPE AS type_name, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''CHARACTER'' '+
           '      OR DATA_TYPE=''CHARACTER VARYING'' '+
           //todo etc.
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '    THEN NUMERIC_PRECISION '+
           '    WHEN DATA_TYPE=''SMALLINT'' THEN 5 '+
           '    WHEN DATA_TYPE=''INTEGER'' THEN 10 '+
           '    WHEN DATA_TYPE=''REAL'' THEN 7 '+
           '    WHEN DATA_TYPE=''FLOAT'' '+
           '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
           '    THEN 15 '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '    THEN 10 '+
           '    WHEN DATA_TYPE=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
           '    THEN 9+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
           '    THEN 20+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
           '    THEN 15+NUMERIC_SCALE  '+
           '    WHEN DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
           '    THEN 26+NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''BINARY LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           '    WHEN DATA_TYPE=''CHARACTER LARGE OBJECT'' '+
           '    THEN CHARACTER_MAXIMUM_LENGTH '+
           //todo etc.
           '  END AS COLUMN_SIZE, '+
           '  CHARACTER_MAXIMUM_LENGTH AS BUFFER_LENGTH, '+
           '  CASE '+
           '    WHEN DATA_TYPE=''DATE'' '+
           '      OR DATA_TYPE=''TIME'' '+
           '      OR DATA_TYPE=''TIMESTAMP'' '+
           '      OR DATA_TYPE=''TIME WITH TIME ZONE'' '+
           '      OR DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
           '    THEN NUMERIC_SCALE '+
           '    WHEN DATA_TYPE=''NUMERIC'' '+
           '      OR DATA_TYPE=''DECIMAL'' '+
           '      OR DATA_TYPE=''SMALLINT'' '+
           '      OR DATA_TYPE=''INTEGER'' '+
           '    THEN NUMERIC_SCALE '+
           '  ELSE NULL '+
           '  END AS DECIMAL_DIGITS, '+
           '  NUMERIC_PRECISION_RADIX AS NUM_PREC_RADIX, '+
           (*
           '  CASE '+
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'')  THEN 0 '+
           '    ELSE 1 '+
           '  END AS nullable, '+
           *)
           '  '+intToStr(SQL_NULLABLE)+' AS nullable,'+ //since we can't specify not null or use domains for parameters
           '  null AS remarks, '+
           '  null AS COLUMN_DEF, '+  //todo read from sysParameters?
           '  CASE DATA_TYPE '+
           '    WHEN ''CHARACTER'' THEN 1'+
           '    WHEN ''NUMERIC'' THEN 2 '+
           '    WHEN ''DECIMAL'' THEN 3 '+
           '    WHEN ''INTEGER'' THEN 4 '+
           '    WHEN ''SMALLINT'' THEN 5 '+
           '    WHEN ''FLOAT'' THEN 6 '+
           '    WHEN ''REAL'' THEN 7 '+
           '    WHEN ''DOUBLE PRECISION'' THEN 8 '+
           '    WHEN ''CHARACTER VARYING'' THEN 12 '+
           '    WHEN ''DATE'' THEN 9 '+
           '    WHEN ''TIME'' THEN 9 '+
           '    WHEN ''TIMESTAMP'' THEN 9 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 9 '+
           '    WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
           '    WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  END AS sql_data_type, '+
           '  CASE DATA_TYPE '+
           '    WHEN ''DATE'' THEN 1 '+
           '    WHEN ''TIME'' THEN 2 '+
           '    WHEN ''TIMESTAMP'' THEN 3 '+
           '    WHEN ''TIME WITH TIME ZONE'' THEN 4 '+
           '    WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 5 '+
           //todo etc.
           //todo join to type_info to get SQL type...?
           '  ELSE NULL '+
           '  END AS sql_datetime_sub, '+
           '  NUMERIC_PRECISION AS char_octet_length, '+
           '  0 AS ORDINAL_POSITION, '+ //must be a number to union match
           (*
           '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           '    WHEN EXISTS (SELECT 1 FROM '+catalog_definition_schemaName+'.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN ''N'' '+
           '  ELSE '+
           '    ''Y'' '+
           '  END AS IS_NULLABLE,'+
           *)
           '  ''Y'' AS is_nullable ' //since we can't specify not null or use domains for parameters
  end;

  query:=query+
         'FROM '+
         '    '+information_schemaName+'.PARAMETERS '+
         'WHERE '+
         ' specific_catalog '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND specific_schema '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND specific_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,routineName)+
         ' AND PARAMETER_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,parameterName);

  query:=query+CRLF+' UNION ';

  query:=query+
         query2+
         'FROM '+
         '    '+information_schemaName+'.ROUTINES '+
         'WHERE '+
         ' specific_catalog '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND specific_schema '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND specific_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,routineName)+

         'ORDER BY procedure_cat, procedure_schem, procedure_name, ORDINAL_POSITION '; //odbc 3 says column_type rather than ORDINAL_POSITION but then conflicts itself
         //'; ';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLProcedureColumns}

///// SQLProcedures /////

function SQLProcedures  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 RoutineName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  catPattern, schemPattern, routinePattern, typePattern:string;
  queryType:integer;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLProcedures called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(RoutineName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  (*todo n/a
  if FixStringSWORD(RoutineType,NameLength4)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  *)

(*
  if catalogName=nil then catalogName:='';
  if SchemaName=nil then SchemaName:='';
  if TableName=nil then TableName:='';
  if TableType=nil then TableType:='';
*)
  catPattern:=CatalogName;
  schemPattern:=SchemaName;
  routinePattern:=RoutineName;
  //typePattern:=RoutineType;

  queryType:=4; //standard routine search

  if (catPattern=SQL_ALL_CATALOGS) and (schemPattern='') and (routinePattern='') {and (typePattern='')} then queryType:=1; //catalog search
  if (catPattern='') and (schemPattern=SQL_ALL_SCHEMAS) and (routinePattern='') {and (typePattern='')} then queryType:=2; //schema search
  //if (catPattern='') and (schemPattern='') and (routinePattern='') {and (typePattern=SQL_ALL_TABLE_TYPES)} then queryType:=3; //routine-type search

  if CatalogName<>'' then catPattern:=CatalogName; // else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName; // else schemPattern:=SQL_ALL_SCHEMAS;
  if RoutineName<>'' then routinePattern:=RoutineName; // else routinePattern:=SQL_ALL_TABLES;
  {todo reinstate: debugging MSquery! if TableType<>'' then typePattern:=TableType else} //typePattern:=SQL_ALL_TABLES;
  //todo: need to handle CSV format...
  {If tableType is not quoted (e.g. quoted from BDE/Query Tool, not from AQueryx), then quote it now}
  //if copy(typePattern,1,1)<>'''' then typePattern:=''''+typePattern+'''';

  //todo remove: log(format('SQLProcedures called with %s %s %s %s',[catPattern,schemPattern, routinePattern, typePattern]));
  if pos('.',routinePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLProcedures called with embedded ., will split %s',[routinePattern]));
    {$ENDIF}
    //done: really should move left portion to schemPattern...
    //todo reinstate? //
    //todo do we still need this here? Has been removed from elsewhere...I think we do for dbExplorer!

    schemPattern:=copy(routinePattern,1,pos('.',routinePattern)-1);
    routinePattern:=copy(routinePattern,pos('.',routinePattern)+1,length(routinePattern));
  end;

  query:='';
  case queryType of
    1: query:='SELECT DISTINCT '+
         'ROUTINE_CATALOG AS procedure_cat, '+
         'null, '+
         'null, '+
         '  null AS num_input_params, '+
         '  null AS num_output_params, '+
         '  null AS num_result_sets, '+
         '  null AS remarks, '+
         'null '+
         'FROM '+information_schemaName+'.ROUTINES ';

    2: query:='SELECT DISTINCT '+
         'null, '+
         'ROUTINE_SCHEMA AS procedure_schem, '+
         'null, '+
         '  null AS num_input_params, '+
         '  null AS num_output_params, '+
         '  null AS num_result_sets, '+
         '  null AS remarks, '+
         'null '+
         'FROM '+information_schemaName+'.ROUTINES ';

    //3 = n/a
    3: query:='SELECT DISTINCT '+
         'null, '+
         'null, '+
         'null, '+
         '  null AS num_input_params, '+
         '  null AS num_output_params, '+
         '  null AS num_result_sets, '+
         '  null AS remarks, '+
         'ROUTINE_TYPE '+
         'FROM '+information_schemaName+'.ROUTINES ';

    4: begin
       query:='SELECT '+
         '  ROUTINE_CATALOG AS procedure_cat, '+
         '  ROUTINE_SCHEMA AS procedure_schem, '+
         '  ROUTINE_NAME AS procedure_name, '+
         '  null AS num_input_params, '+
         '  null AS num_output_params, '+
         '  null AS num_result_sets, '+
         '  null AS remarks, '+
         '  CASE ROUTINE_TYPE '+
         '    WHEN ''FUNCTION '' THEN '+intToStr(SQL_PT_FUNCTION)+  //todo padded to match PROCEDURE since CASE results are pre-fixed currently...
         '    WHEN ''PROCEDURE'' THEN '+intToStr(SQL_PT_PROCEDURE)+
         '  ELSE '+
         '    '+intToStr(SQL_PT_UNKNOWN)+
         '  END AS procedure_type '+
         'FROM '+
         '  '+information_schemaName+'.ROUTINES '+
         'WHERE '+
         ' ROUTINE_CATALOG '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,catPattern)+
         ' AND ROUTINE_SCHEMA '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,schemPattern)+
         ' AND ROUTINE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,routinePattern);
         (*todo n/a
         if typePattern<>'''''' then
         begin
           query:=query+
           ' AND '+
           '  CASE ROUTINE_TYPE '+
           '    WHEN ''FUNCTION '' THEN '+intToStr(SQL_PT_FUNCTION)+  //todo padded to match PROCEDURE since CASE results are pre-fixed currently...
           '    WHEN ''PROCEDURE'' THEN '+intToStr(SQL_PT_PROCEDURE)+
           '  ELSE '+
           '    '+intToStr(SQL_PT_UNKNOWN)+
           '  END IN ('+typePattern+')';  {already quoted and comma separated!?} //
           //todo remove: alias conflicts with base: 'TABLE_TYPE='+typePattern+' '+{already quoted!?} //todo remove: patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableType)+
         end;
         *)
         //todo remove: no need?: '; ';
       end; {4}
  end; {case}
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLProcedures}

(*
///// SQLSetPos /////
//debug ADO
function SQLSetPos  (hstmt:HSTMT;
		 irow:UWORD;fRefresh:UWORD;fLock:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetPos called %d',[hstmt]));
  {$ENDIF}

  //todo only put here while debugging ADO connecting... remove from everywhere if left undone!!!!!!!!!!!!!

  result:=SQL_SUCCESS; //default
end; {SQLSetPos}
*)

(*
///// SQLSetScrollOptions /////

RETCODE SQL_API SQLSetScrollOptions  (HSTMT arg0,
		 UWORD arg1,
		 SDWORD arg2,
		 UWORD arg3)
{
	log("SQLSetScrollOptions called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLTablePrivileges /////

function SQLTablePrivileges  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  //catPattern, schemPattern, tablePattern:string;
  query:string;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLTablePrivileges called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo fixStrings?
  //todo: note: we seem to need to from ODBCtest for this routine!
  //-todo: may be neater code to add all results & fail if >0? assumes only possible result is 0=ok...
  if FixStringSWORD(CatalogName,NameLength1)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(SchemaName,NameLength2)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  if FixStringSWORD(TableName,NameLength3)<ok then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',0,0); //todo check result
    exit;
  end;
  (*todo remove
  if CatalogName<>'' then catPattern:=CatalogName else catPattern:=SQL_ALL_CATALOGS;
  if SchemaName<>'' then schemPattern:=SchemaName else schemPattern:=SQL_ALL_SCHEMAS;
  if TableName<>'' then tablePattern:=TableName else tablePattern:=SQL_ALL_TABLES;
  *)

  (*todo remove
  //todo: remove!!!! no need: except dbExplorer error & trying to get indexes to be read...
  if pos('.',tablePattern)<>0 then
  begin
    {$IFDEF DEBUGDETAIL}
    log(format('SQLTablePrivileges called with embedded ., %s',[tablePattern]));
    {$ENDIF}
    //todo: really should move left portion to schemPattern...
//todo!    tablePattern:=copy(tablePattern,pos('.',tablePattern)+1,length(tablePattern));
  end;
  *)

  query:='SELECT '+
         '  TABLE_CATALOG AS table_cat, '+
//todo         '  '''' AS table_cat, '+
         '  TABLE_SCHEMA AS table_schem, '+
//todo         '  '''' AS table_schem, '+
         '  TABLE_NAME, '+
         '  GRANTOR, '+
         '  GRANTEE, '+
         '  PRIVILEGE_TYPE AS privlege, '+
         '  IS_GRANTABLE '+
         'FROM '+
         '  '+information_schemaName+'.TABLE_PRIVILEGES '+
         'WHERE '+
         ' TABLE_CATALOG '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
         ' AND TABLE_SCHEMA '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
         ' AND TABLE_NAME '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
         '; ';
  result:=SQLExecDirect(StatementHandle,pchar(query),length(query));
end; {SQLTablePrivileges}

(*
///// SQLDrivers /////

RETCODE SQL_API SQLDrivers  (HENV arg0,
		 UWORD arg1,
		 UCHAR * arg2,
		 SWORD arg3,
		 SWORD * arg4,
		 UCHAR * arg5,
		 SWORD arg6,
		 SWORD * arg7)
{
	log("SQLDrivers called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLBindParameter /////

function SQLBindParameter  (StatementHandle:SQLHSTMT;
		 ParamNumber:UWORD;
		 InputOutputMode:SWORD;
		 ValueType:SWORD;
		 ParameterType:SWORD;
		 ColumnSize:UDWORD;
		 DecimalDigits:SWORD;
		 ParameterValue:PTR;
		 BufferLength:SDWORD;
                 StrLen_or_Ind:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLBindParameter called %d %d %d %d %d %d %d %p %d %p',[StatementHandle,ParamNumber,InputOutputMode,
                                                             ValueType,ParameterType,ColumnSize,DecimalDigits,
                                                             ParameterValue,BufferLength,StrLen_or_Ind]));
  {$ENDIF}

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  //todo remove! s.diagnostic.clear; //todo remove!!??

  if s.state>=S8 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  if ParamNumber<1 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

(*todo reinstate!!!!!!!!
  for now, we debug with ODBC test which sends us wierd types - accept anything for now!!!!!
  if not(BufferType in [SQL_C_DEFAULT,
                        SQL_CHAR,SQL_NUMERIC,SQL_DECIMAL,SQL_INTEGER,SQL_SMALLINT,SQL_FLOAT,SQL_REAL,SQL_DOUBLE,
                        SQL_UDT_LOCATOR,SQL_REF,SQL_LONGVARBINARY{SQL_BLOB},SQL_BLOB_LOCATOR,SQL_CLOB,SQL_CLOB_LOCATOR
                       ]) then //todo remove some of these - we/caller code don't support them all!?
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY003,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
*)
  if BufferLength<0 then //SQL standard says <=0
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY090,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo maybe set s.apd values directly & bypass setDescField - speed (but no checks?)
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_PARAMETER_TYPE{SQL_DESC_PARAMETER_MODE in standard},SQLPOINTER(InputOutputMode),SQL_IS_SMALLINT);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_TYPE,SQLPOINTER(ValueType),SQL_IS_SMALLINT);
  if result=SQL_ERROR then exit;
  //todo concise_type also?
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_OCTET_LENGTH,SQLPOINTER(BufferLength),SQL_IS_INTEGER);
  if result=SQL_ERROR then exit;
  //todo precision & scale...? defaults for ODBC numerics...
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_DATA_POINTER,ParameterValue,BufferLength);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_OCTET_LENGTH_POINTER,StrLen_or_Ind,SQL_IS_POINTER);
  if result=SQL_ERROR then exit;
  result:=SQLSetDescField(SQLHDESC(s.apd),ParamNumber,SQL_DESC_INDICATOR_POINTER,StrLen_or_Ind,SQL_IS_POINTER);
  if result=SQL_ERROR then exit;

  //setting this param number via SetDescField ensures APD.SQL_DESC_COUNT is increased, if need be, to ParamNumber
  //Note: if an error occurred above, we should leave desc_count as it was!

  {Now set some of the IPD fields}
  {Note: this will overwrite the auto-populated values (if the auto-populate option is not turned off)
   - most DBMSs can't auto-populate so it's not an issue for them, but for us this
   isn't good - it would be nice to be able to use SQLBindParameter and pass a ParameterType=-1 or something
   to leave the IPD alone. I can't see this in any of the documentation, so the user will be best advised
   to SQLPrepare after binding columns if they want to leave the IPD automatic.
   Although the IPD won't always be totally automatic, so maybe it's best if the user sets the IPD...?
                                                       plus the server not overwrite the user's settings!!!
  }
  result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_TYPE,SQLPOINTER(ParameterType),SQL_IS_SMALLINT); //may be overwritten below (by datetime types)
  if result=SQL_ERROR then exit;
  {Note: this logic is (inverted) and copied into the SQLPrepare routine to handle column definitions coming
   from the server}
  case ParameterType of
    SQL_NUMERIC, SQL_DECIMAL, SQL_INTEGER, SQL_SMALLINT, SQL_FLOAT, SQL_REAL, SQL_DOUBLE:
    begin
      //Note: ColumnSize is UDWORD, but precision holds SQLSMALLINT so could be too big! - todo check?-but unlikely for numeric!
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_PRECISION,SQLPOINTER(ColumnSize),SQL_IS_SMALLINT); //todo lie: is_actually_UDWORD
      if result=SQL_ERROR then exit;
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_SCALE,SQLPOINTER(DecimalDigits),SQL_IS_SMALLINT);
      if result=SQL_ERROR then exit;
    end; {numeric}

    //Note: datetime/interval complications taken from standard, not ODBC - but that's ok because we want a standard back-end
    SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
    SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
    SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
    SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
    begin
      //todo setting concise_type might be slicker... this also sets SQL_DESC_TYPE and SQL_DESC_DATETIME_INTERVAL_CODE
      {Split the Type into (Major) Type and (Sub-type) IntervalCode, e.g. 103 = 10 and 3}
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_TYPE,SQLPOINTER((ParameterType div 10){=SQL_DATETIME or SQL_INTERVAL}),SQL_IS_SMALLINT);
      if result=SQL_ERROR then exit;
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_CODE,SQLPOINTER(ParameterType-((ParameterType div 10){=SQL_DATETIME or SQL_INTERVAL}*10)),SQL_IS_SMALLINT);
      if result=SQL_ERROR then exit;
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_LENGTH,SQLPOINTER(ColumnSize),SQL_IS_UINTEGER);
      if result=SQL_ERROR then exit;

      {SQL_DESC_PRECISION}
      case ParameterType of
        SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
        SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
        begin
          result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_PRECISION,SQLPOINTER(DecimalDigits),SQL_IS_SMALLINT);
          if result=SQL_ERROR then exit;
        end;
      else
        result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_PRECISION,SQLPOINTER(0),SQL_IS_SMALLINT);
        if result=SQL_ERROR then exit;
      end; {case SQL_DESC_PRECISION}

      {SQL_DESC_DATETIME_INTERVAL_PRECISION}
      case ParameterType of
        SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
          {no SQL_DESC_DATETIME_INTERVAL_PRECISION} ;
        SQL_INTERVAL_YEAR_TO_MONTH, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_HOUR_TO_MINUTE:
        begin //columnSize-4
          result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-4),SQL_IS_SMALLINT);
          if result=SQL_ERROR then exit;
        end;
        SQL_INTERVAL_DAY_TO_MINUTE:
        begin //columnSize-7
          result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-7),SQL_IS_SMALLINT);
          if result=SQL_ERROR then exit;
        end;
        SQL_INTERVAL_SECOND:
        begin
          if DecimalDigits<>0 then
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-DecimalDigits-2),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end
          else
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-1),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end;
        end;
        SQL_INTERVAL_DAY_TO_SECOND:
        begin
          if DecimalDigits<>0 then
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-DecimalDigits-11),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end
          else
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-10),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end;
        end;
        SQL_INTERVAL_HOUR_TO_SECOND:
        begin
          if DecimalDigits<>0 then
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-DecimalDigits-8),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end
          else
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-7),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end;
        end;
        SQL_INTERVAL_MINUTE_TO_SECOND:
        begin
          if DecimalDigits<>0 then
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-DecimalDigits-5),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end
          else
          begin
            result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-4),SQL_IS_SMALLINT);
            if result=SQL_ERROR then exit;
          end;
        end;
      else //columnSize-1
        result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_DATETIME_INTERVAL_PRECISION,SQLPOINTER(ColumnSize-1),SQL_IS_SMALLINT);
        if result=SQL_ERROR then exit;
      end; {case SQL_DESC_DATETIME_INTERVAL_PRECISION}
    end; {datetime/interval}

    SQL_CHAR, SQL_VARCHAR, {SQL_BIT, SQL_BIT_VARYING not standard,}
    SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
    SQL_LONGVARCHAR{todo debug test...remove?}:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ipd),ParamNumber,SQL_DESC_LENGTH,SQLPOINTER(ColumnSize),SQL_IS_UINTEGER);
      if result=SQL_ERROR then exit;
    end; {other}
  else
    //todo error?! - or just set type instead?
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY004,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end; {case}
end; {SQLBindParameter}

///// SQLAllocHandle /////

function SQLAllocHandle  (HandleType:SQLSMALLINT;
		 InputHandle:SQLHANDLE;
		 OutputHandle:pSQLHANDLE):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
  c:Tdbc;
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;

  serverS:SQLHSTMT;

  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLAllocHandle called: %d %d %p',[HandleType,InputHandle,OutputHandle]));
  {$ENDIF}

  case HandleType of
    SQL_HANDLE_ENV:
    begin
      e:=Tenv.create;
      OutputHandle^:=SQLHENV(e);
      e.state:=E1;
    end; {SQL_HANDLE_ENV}
    SQL_HANDLE_DBC:
    begin
      {Check handle}
      e:=Tenv(InputHandle);
      if not(e is Tenv) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      //todo: check if SQL_ATTR_ODBC_VERSION has been set: if yes, continue else abort with HY010
      c:=Tdbc.create;
      e.addConnection(c); //todo check result
      {We will notify the server about this object when we connect}
      OutputHandle^:=SQLHDBC(c);
      e.state:=E2;
      c.state:=C2;
    end; {SQL_HANDLE_DBC}
    SQL_HANDLE_STMT:
    begin
      {Check handle}
      c:=Tdbc(InputHandle);
      if not(c is Tdbc) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      c.diagnostic.clear;
      {Check states}
      if (c.state=C2) or (c.state=C3) then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08003,fail,'',0,0); //todo check result
        OutputHandle^:=0;
        exit;
      end;
      //todo assert c.state=C4
      //todo if maxNumber of stmts reached, output^=0 & return error
      //todo should wrap ALL Creates in try..except & return memory-allocation error if fails
      {We must notify the server before we create this object so it can reserve a prepare/execute handle for it
       todo: note, maybe the server can auto-create a default handle so the majority of clients
             needn't notify it during this routine unless they allocate >1 stmt = unusual
      }
      with c.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLALLOCHANDLE);
        putSQLSMALLINT(HandleType);
        putSQLHDBC(InputHandle);  //todo assert this = c? also elsewhere?
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLALLOCHANDLE then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
          exit;
        end;
        getSQLHSTMT(serverS);  //server will return 0 if failed
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLAllocHandle returns %d %d',[resultCode,serverS]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          exit;
        end;
      end; {with}
      {Ok, now allocate our own stmt}
      s:=Tstmt.create;
      c.addStatement(s); //todo check result
      s.ServerStatementHandle:=serverS; //we will pass this reference to server in future calls
      OutputHandle^:=SQLHSTMT(s);
      c.state:=C5;
      s.state:=S1;
    end; {SQL_HANDLE_STMT}
  else
    result:=SQL_INVALID_HANDLE;
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end; {SQLAllocHandle}
(*
///// SQLBindParam /////

RETCODE SQL_API SQLBindParam  (SQLHSTMT arg0,
		 SQLUSMALLINT arg1,
		 SQLSMALLINT arg2,
		 SQLSMALLINT arg3,
		 SQLUINTEGER arg4,
		 SQLSMALLINT arg5,
		 SQLPOINTER arg6,
		 SQLINTEGER * arg7)
{
	log("SQLBindParam called\n");
	return(SQL_SUCCESS);
}
*)


function CloseCursor(StatementHandle:SQLHSTMT):RETCODE;
{Support function that just closes the cursor if it is open and:
   1) does not report an error if there's nothing to close
   2) does not autocommit

 This routine is called from
   SQLCloseCursor               //does most of the work, except autocommit
                                //and which is called from SQLFreeStmt(SQL_CLOSE)
   SQLEndTran                   //closes all open cursors without leading to infinite recursion if autocommit is on
}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('   CloseCursor called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  case s.state of
    S1,S2..S3,S4:
    begin
    end; {S1,S2..S3,S4}
    S5..S7:
    begin
      {call server SQLCloseCursor}
      //todo do we need to if our cursor.state is not open!!!!??? save time e.g. when called from SQLendTran
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLCLOSECURSOR);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
        if s.prepared then putSQLSMALLINT(0) else putSQLSMALLINT(1);
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLCLOSECURSOR then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('   CloseCursor returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        case resultCode of
          SQL_SUCCESS:
          begin
            s.cursor.state:=csClosed;
            //todo should we reset the cursor name as well? - maybe a future cursor.close method will handle all the details?
            if s.prepared then
              s.state:=S3 {prepared}
            else
              s.state:=S1; {not prepared}
          end; {SQL_SUCCESS}
        else
          //todo what if SQL_ERROR?
          //(else) should never happen!?
        end; {case}
      end; {with}
    end; {S5..S7}
    S8..S10,S11..S12:
    begin
    end; {S8..10,S11.S12}
  else
    //todo unknown state! - should never happen!
  end; {case}
end; {CloseCursor}

///// SQLCloseCursor /////

function SQLCloseCursor  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLCloseCursor called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  case s.state of
    S1,S2..S3,S4:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1,S2..S3,S4}
    S5..S7:
    begin
      result:=CloseCursor(StatementHandle);
      (*todo remove:
      {call server SQLCloseCursor}
      //todo do we need to if our cursor.state is not open!!!!??? save time e.g. when called from SQLendTran
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLCLOSECURSOR);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
        if s.prepared then putSQLSMALLINT(0) else putSQLSMALLINT(1);
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLCLOSECURSOR then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLCloseCursor returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;
        case resultCode of
          SQL_SUCCESS:
          begin
            s.cursor.state:=csClosed;
            //todo should we reset the cursor name as well? - maybe a future cursor.close method will handle all the details?
            if s.prepared then
              s.state:=S3 {prepared}
            else
              s.state:=S1; {not prepared}
          end; {SQL_SUCCESS}
        else
          //todo what if SQL_ERROR?
          //(else) should never happen!?
        end; {case}
      end; {with}
      *)

      //we SQLendTran now if in autocommit mode, so that subsequent queries retrieve data with the latest tran
      //todo remove old Note: the (serious) side-effect of this is that any existing open cursors will be closed!
      //Note: no other open cursors will be closed in this case
      if (s.owner as Tdbc).autocommit then
      begin
        {$IFDEF DEBUGDETAIL}
        log('SQLCloseCursor autocommitting...');
        {$ENDIF}
        if SQLEndTran(SQL_HANDLE_DBC,SQLHANDLE(s.owner as Tdbc),SQL_COMMIT)<>SQL_SUCCESS then
        begin //should never happen: what about state if it does?
          result:=SQL_ERROR;
          //todo: improve/remove the following error: SQLEndTran failure would have added errors to dbc already
          s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
      end;

    end; {S5..S7}
    S8..S10,S11..S12:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S8..10,S11.S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {SQLCloseCursor}

///// SQLColAttribute /////

function SQLColAttribute  (StatementHandle:SQLHSTMT;
		 ColumnNumber:SQLUSMALLINT;
		 FieldIdentifier:SQLUSMALLINT;
		 CharacterAttribute:SQLPOINTER;
		 BufferLength:SQLSMALLINT;
		 StringLength:{UNALIGNED}pSQLSMALLINT;
		 NumericAttribute:SQLPOINTER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  temppSQLINTEGER:pSQLINTEGER;  
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLColAttribute called %d %d %d %p %d',[StatementHandle,ColumnNumber,FieldIdentifier,CharacterAttribute,BufferLength]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

//todo need?  s.diagnostic.clear;

  if (s.state>=S8) {=>..S12} then  //todo or s.active?
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  if s.ird.desc_count=0 then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07005,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
  if ColumnNumber<0 then //note: SQL standard says <1
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;
  if ColumnNumber>s.ird.desc_count then
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ss07009,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  case FieldIdentifier of
    //todo check the spec. description for each of these...
    SQL_DESC_AUTO_UNIQUE_VALUE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_AUTO_UNIQUE_VALUE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_AUTO_UNIQUE_VALUE}
    SQL_DESC_BASE_COLUMN_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_BASE_COLUMN_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_BASE_COLUMN_NAME}
    SQL_DESC_BASE_TABLE_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_BASE_TABLE_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_BASE_TABLE_NAME}
    SQL_DESC_CASE_SENSITIVE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_CASE_SENSITIVE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_CASE_SENSITIVE}
    SQL_DESC_CATALOG_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_CATALOG_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_CATALOG_NAME}
    SQL_DESC_CONCISE_TYPE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_CONCISE_TYPE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_CONCISE_TYPE}
    SQL_DESC_COUNT: //todo ODBC 2 had a different name? - handle it!
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_COUNT, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_COUNT}
    SQL_DESC_DISPLAY_SIZE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_DISPLAY_SIZE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_DISPLAY_SIZE}
    SQL_DESC_FIXED_PREC_SCALE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_FIXED_PREC_SCALE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_FIXED_PREC_SCALE}
    SQL_DESC_LABEL:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LABEL, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_LABEL}

    SQL_DESC_LENGTH:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LENGTH, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_LENGTH}
    SQL_COLUMN_LENGTH: //V2 caller
    begin
      //todo make different to V3
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LENGTH, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_COLUMN_LENGTH}

    SQL_DESC_LITERAL_PREFIX:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LITERAL_PREFIX, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_LITERAL_PREFIX}
    SQL_DESC_LITERAL_SUFFIX:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LITERAL_SUFFIX, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_LITERAL_SUFFIX}
    SQL_DESC_LOCAL_TYPE_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_LOCAL_TYPE_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_LOCAL_TYPE_NAME}
    SQL_DESC_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_NAME}
    SQL_DESC_NULLABLE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_NULLABLE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_NULLABLE}
    SQL_DESC_NUM_PREC_RADIX:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_NUM_PREC_RADIX, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_NUM_PREC_RADIX}
    SQL_DESC_OCTET_LENGTH:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_OCTET_LENGTH, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_OCTET_LENGTH}

    SQL_DESC_PRECISION:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_PRECISION, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_PRECISION}
    SQL_COLUMN_PRECISION: //V2 caller
    begin
      //todo make different to V3
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_PRECISION, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_COLUMN_PRECISION}
    SQL_DESC_SCALE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_SCALE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_SCALE}
    SQL_COLUMN_SCALE: //V2 caller
    begin
      //todo make different to V3
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_SCALE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_COLUMN_SCALE}

    SQL_DESC_SCHEMA_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_SCHEMA_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_SCHEMA_NAME}
    SQL_DESC_SEARCHABLE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_SEARCHABLE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_SEARCHABLE}
    SQL_DESC_TABLE_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_TABLE_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_TABLE_NAME}
    SQL_DESC_TYPE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_TYPE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_TYPE}
    SQL_DESC_TYPE_NAME:
    begin
      new(temppSQLINTEGER); //todo allocate once for thread?
      try
        result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_TYPE_NAME, CharacterAttribute, BufferLength, temppSQLINTEGER);
        stringLength^:=pSQLSMALLINT(temppSQLINTEGER)^;
      finally
        dispose(temppSQLINTEGER);
      end; {try}
    end; {SQL_DESC_TYPE_NAME}
    SQL_DESC_UNNAMED:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_UNNAMED, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_UNNAMED}
    SQL_DESC_UNSIGNED:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_UNSIGNED, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_UNSIGNED}
    SQL_DESC_UPDATABLE:
    begin
      result:=SQLGetDescField(SQLHDESC(s.ird), ColumnNumber, SQL_DESC_UPDATABLE, NumericAttribute, SQL_IS_POINTER, nil);
    end; {SQL_DESC_UPDATABLE}
    //todo Note: this was the complete list! - make sure getDescField/IRD knows about them all!
  else
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY092,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end; {case}
end; {SQLColAttribute}

(*
///// SQLCopyDesc /////

RETCODE SQL_API SQLCopyDesc  (SQLHDESC arg0,
		 SQLHDESC arg1)
{
	log("SQLCopyDesc called\n");
	return(SQL_SUCCESS);
}
*)
///// SQLEndTran /////

function SQLEndTran  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 CompletionType:SQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
  c:Tdbc;

  cNode:PtrTdbcList;
  sNode:PtrTstmtList;

  res:RETCODE;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLEndTran called:%d %d %d',[HandleType,Handle,CompletionType]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  case HandleType of
    SQL_HANDLE_ENV:
    begin
      {Check handle}
      e:=Tenv(Handle);
      if not(e is Tenv) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;

      //todo? e.diagnostic.clear;

      //todo?
      if e.state=E2 {=> C2..C6} then  //todo ?OR e.dbcList<>nil then //todo use finite states...
      begin
        result:=SQL_ERROR;
        e.diagnostic.logError(ssHY010,fail,'',0,0); //todo check result
        exit;
      end;

      {Call SQLEndTran for each connection node} //todo ensure we sync. access to this this list!
      cNode:=e.dbcList;
      while cNode<>nil do
      begin
        res:=SQLEndTran(SQL_HANDLE_DBC,SQLHANDLE(cNode^.dbc),CompletionType); //1 level of recursion...
        if res<>SQL_SUCCESS then result:=res; //pass the worst of the results to caller
        cNode:=cNode^.next;
      end;
    end; {SQL_HANDLE_ENV}
    SQL_HANDLE_DBC:
    begin
      {Check handle}
      c:=Tdbc(Handle);
      if not(c is Tdbc) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;

      //todo? c.diagnostic.clear; //todo check?

      if c.state in [C2,C3] then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08003,fail,'',0,0); //todo check result
        exit;
      end;

      //todo check completionType is one of the two valid types (even though DM should have filtered such garbage)

      if not c.autocommit then
      begin
        {Before we commit or rollback, we must close cursor for each statement on this connection/transaction
         Note: we could have had the server SQLendTran do this, and then tidy our end (s.cursor.state:=csClosed etc.)
               but if the server failed closing some/all the statements/cursors then the client would
               be out of sync.
               So, this way we keep the two ends in sync. no matter what, although we generate more traffic
               (but typically 1 stmt per connection)
         Also, the driver is dictating/pre-empting the server's behaviour towards the cursors at transaction-end:
         -maybe this is bad? although the server will(?) close any open cursors anyway (but may not in future?) //todo ok?
        }
        sNode:=c.stmtList;
        while sNode<>nil do
        begin
          resultCode:=CloseCursor(SQLHSTMT(sNode^.stmt));
          if resultCode<>SQL_SUCCESS then
          begin
            result:=resultCode;
            //todo log what (c or s?) //todo or maybe continue? //todo check how CloseCursor can fail...
            //...I suppose one way is if the stmt is put/paramData - would need to SQLcancel first,so
            //I think it's right that we should error & abort here in such a case... //todo check spec.
            c.diagnostic.logError(ssHY000,resultErrCode,ceFailedClosingCursor,0,0); //todo check result
            exit;
          end;
          sNode:=sNode^.next;
        end;
      end;
      //else we leave any open cursors because autocommit=True:
      //This doesn't fit with the standard (serialisable at least) transaction model but we
      //permit this strange ODBC requirement: the risk (of phantoms/dirty data etc.) is with the user!
      //Note: this extended (bad) behaviour is only allowed via the APIs that support auto-commit
      // - the SQLcloseCursor(HDBC) should take care of closing all dangling cursors

      {Send SQLendTran to server}
      with c.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLENDTRAN);
        putSQLHDBC(Handle);
        putSQLSMALLINT(CompletionType);
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
          exit;
        end;

        {Wait for read to return the response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLENDTRAN then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLEndTran returns %d',[resultCode]));
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
            case resultErrCode of
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seInvalidOption:         resultState:=ssHY000 {DM will catch & return HY0012};
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          exit;
        end;

        if c.state=C6 then
        begin
          if c.stmtList=nil then
            c.state:=C4
          else
            c.state:=C5;
        end;

      end; {with}
    end; {SQL_HANDLE_DBC}
  else
    //error:unknown handleType!
    //DM prevents/handles this situation //todo we should give proper error in these situations in case:
    // 1. no DM is being used - future
    // 2. belt & braces!
  end; {case}
end; {SQLEndTran}

///// SQLFetchScroll /////

function SQLFetchScroll  (StatementHandle:SQLHSTMT;
		 FetchOrientation:SQLSMALLINT;
		 FetchOffset:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  colCount:SQLINTEGER;  //todo word ok?
  rowCount:SQLUINTEGER;
  row:SQLUINTEGER;
  sqlRowStatus:SQLUSMALLINT;
  rowStatusExtra:SQLSMALLINT;      //conversion error/warning in row
  colStatusExtra:SQLSMALLINT;      //conversion error/warning in column
  setStatusExtra:SQLSMALLINT;      //conversion error/warning in row set

  dataPtr:SQLPOINTER;
  lenPtr:pSQLINTEGER;
//todo remove  statusPtr:pSQLUSMALLINT;

  i:SQLINTEGER; //todo word ok?
  rn:SQLSMALLINT;
  adr,idr:TdescRec;

  tempsdw:SDWORD;
  tempNull:SQLSMALLINT;

  offsetSize:SQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLFetchScroll called %d',[StatementHandle]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle S0}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

//todo remove!  s.diagnostic.clear; //todo check

  case s.state of
    S1,S2,S3:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S1,S2,S3}
    S4:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S4}
    S5,S6:
    begin
      //todo may need to call a sub-routine to keep manageable

      //error if not fetch_next (until we work out how best to do other orientations) //todo remove
      if FetchOrientation<>SQL_FETCH_NEXT then //todo remove: debug/dev only
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHY106,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
      //todo then, error if not fetch_next and cursor type was not preset (to handle materialised result sets)

      {call server fetchScroll}
      //todo Replace all AS with casts - speed
      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLFETCHSCROLL);
        putSQLHSTMT(s.ServerStatementHandle); //pass server statement ref
        putSQLSMALLINT(FetchOrientation);
        putSQLINTEGER(FetchOffset);
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLFETCHSCROLL then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo correct?pass details! //todo check result
          exit;
        end;
        //resultCode comes later
        {retrieve any result data}

        {Read row count}
        getSQLUINTEGER(rowCount);
        //todo? check rowCount=array_size - no reason why not... could assume? - but dangerous
        {Initialise the count of non-empty rows in the application's buffer}
        if s.ard.desc_rows_processed_ptr<>nil then
          pSQLuINTEGER(s.ard.desc_rows_processed_ptr)^:=0; //we increment this each time we get a 'real' result row
        //might be slightly quicker (less safe) to set to rowCount now & decrement if we get an empty row - speed?

        //todo: note pSQLINTEGER(intPtr)^:=x is safer than SQLINTEGER(intPtr^):=x
        // - check this is true & if so make sure we use this everywhere!

        {$IFDEF DEBUGDETAIL}
        log(format('SQLFetchScroll returns %d rows',[rowCount]));
        {$ENDIF}

        if s.ard.desc_bind_offset_ptr<>nil then
          offsetSize:=SQLINTEGER(s.ard.desc_bind_offset_ptr^) //get deferred value
        else
          offsetSize:=0; //todo assert rowCount/array_size = 1 - else where do we put the data!!!!

        {$IFDEF DEBUGDETAIL}
        log(format('SQLFetchScroll bind offset size=%d',[offsetSize]));
        {$ENDIF}

        setStatusExtra:=0; //no conversion errors

        for row:=1 to rowCount do
        begin
          {Now get the col count & data for this row}
          getSQLINTEGER(colCount);
          {$IFDEF DEBUGDETAIL}
          log(format('SQLFetchScroll returns %d column data',[colCount]));
          {$ENDIF}
          //todo assert s.ard.desc_count<=colCount ?
          //todo now use get with result checking!!!

          rowStatusExtra:=0; //no conversion errors

          i:=0;
          while i<=colCount-1 do
          begin
            //todo maybe server should sort by col-ref before sending?, although we sort here via getRecord...
            if getSQLSMALLINT(rn)<>ok then
            begin
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit;
            end;
            if s.ard.getRecord(rn,Adr,True)=ok then
            begin
              //todo if this has just been created, then problem - can't happen if we assert desc_count<colCount above?
              with Adr do
              begin
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

                {$IFDEF DEBUGDETAIL}
                log(format('SQLFetchScroll read column %d data: %d bytes, null=%d',[rn,tempsdw,tempNull])); //todo debug only - remove & assumes null terminated pCHAR! which it is from get routines...
                {$ENDIF}
              end; {with}
            end
            else
            begin
              //error, skip this column: need to consume the rest of this column definition anyway -> sink
              //todo or, could abort the whole routine instead?
              //note: currently getRecord cannot fail!
              {$IFDEF DEBUGDETAIL}
              log(format('SQLFetchScroll failed getting ARD desc record %d - rest of column data abandoned...',[rn])); //todo debug error only - remove
              {$ENDIF}
              result:=SQL_ERROR;
              s.diagnostic.logError(ss08S01,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
              exit; //todo: just for now!
            end;

            inc(i);
          end; {while}
          {get row status}
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
          {Add to the count of non-empty rows in the application's buffer}
          if sqlRowStatus<>SQL_ROW_NOROW then
            if s.ard.desc_rows_processed_ptr<>nil then
              inc(pSQLuINTEGER(s.ard.desc_rows_processed_ptr)^); //we increment this each time we get a 'real' result row
        end; {for row}

        getRETCODE(resultCode);
        //todo we should set to SQL_SUCCESS_WITH_INFO if any rowStatus just had a problem - i.e a conversion problem
        // since server wouldn't have known...
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLFetchScroll returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seNotPrepared:           resultState:=ssHY010;
              seNoResultSet:           resultState:=ssHY010{todo ok??};
              seDivisionByZero:        resultState:=ss22012;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
        end;

        {If server returned SQL_SUCCESS, but we just encountered a conversion warning/error
         then modify the result code to SQL_SUCCESS_WITH_INFO as per ODBC spec.}
        if setStatusExtra<>0 then
          if resultCode=SQL_SUCCESS then
            resultCode:=SQL_SUCCESS_WITH_INFO;

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
      end; {with}
    end; {S5,S6}
    S7:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S7}
    S8..S10:
    begin
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {S8..10}
    S11,S12:
    begin
      //todo error or NS
    end; {S11,S12}
  else
    //todo assert unknown state! - should never happen!
  end; {case}
end; {FetchScroll}

///// SQLFreeHandle /////

function SQLFreeHandle  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
  c:Tdbc;
  s:Tstmt;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  lastOne:boolean;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLFreeHandle called:%d %d',[HandleType,Handle]));
  {$ENDIF}

  case HandleType of
    SQL_HANDLE_ENV:
    begin
      {Check handle}
      e:=Tenv(Handle);
      if not(e is Tenv) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;

      e.diagnostic.clear;

      if e.state=E2 {=> C2..C6} then  //todo ?OR e.dbcList<>nil then //todo use finite states...
      begin
        result:=SQL_ERROR;
        e.diagnostic.logError(ssHY010,fail,'',0,0); //todo check result
        exit;
      end;
      e.free; //free Env => e.state:=E0
    end; {SQL_HANDLE_ENV}
    SQL_HANDLE_DBC:
    begin
      {Check handle}
      c:=Tdbc(Handle);
      if not(c is Tdbc) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;

      c.diagnostic.clear; //todo check?

      if (c.state=C3) or (c.state=C4) or (c.state=C5) or (c.state=C6) then  //todo ?OR c.stmtList<>nil then //todo use finite states...
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ssHY010,fail,'',0,0); //todo check result
        exit;
      end;
      if (c.owner as Tenv).RemoveConnection(c)=+1 then (c.owner as Tenv).state:=E1;
      c.free; //free Dbc
    end; {SQL_HANDLE_DBC}
    SQL_HANDLE_STMT:
    begin
      {Check handle C1..C4}
      s:=Tstmt(Handle);
      if not(s is Tstmt) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      //assert c(s.owner) C5/C6
      s.diagnostic.clear; //todo check?

      if (s.state>=S8) {=>..S12} then  //todo or s.active?
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
      {We must notify the server before we delete this object so it can delete its prepare/execute handle for it
       todo: note, maybe the server can auto-create a default handle so the majority of clients
             needn't notify it during this routine unless they allocate >1 stmt = unusual
      }

      {Before we zap the server stmt, we unbind and close in case the caller hasn't done this,
       otherwise calling them during our stmt.free would try to notify the server about the unbinding/closing
       but by then it would be too late - the server handle would have been freed
      }
      SQLfreeStmt(Handle{=SQLHSTMT(s)},SQL_UNBIND); //todo check result
      SQLfreeStmt(Handle{=SQLHSTMT(s)},SQL_CLOSE); //todo check result

      with (s.owner as Tdbc).Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLFREEHANDLE);
        putSQLSMALLINT(HandleType);
        putSQLHSTMT(s.ServerStatementHandle); //i.e. we don't directly pass Handle, but use it to find the server's reference
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLFREEHANDLE then
        begin
          result:=SQL_ERROR;
          s.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLFreeHandle returns %d',[resultCode]));
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
              seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            s.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          exit;
        end;
      end; {with}
      {Ok, now de-allocate our own stmt}
      lastOne:=((s.owner as Tdbc).RemoveStatement(s)=+1);
      case (s.owner as Tdbc).state of
        C5: if lastOne then (s.owner as Tdbc).state:=C4;
        C6: if (s.owner as Tdbc).autocommit then
            begin
              if lastOne then
                (s.owner as Tdbc).state:=C4
              else
                (s.owner as Tdbc).state:=C5;
            end;
      end; {case}
      s.free; //free stmt
    end; {SQL_HANDLE_STMT}
  else
    //todo error:unknown handleType!
  end; {case}

  result:=SQL_SUCCESS;
end; {freeHandle}

///// SQLGetConnectAttr /////

function SQLGetConnectAttr  (ConnectionHandle:SQLHDBC;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;
  tempsw:SWORD;

  //todo re-use(d) getInfo code
  procedure AskServer;
  var
    functionId:SQLUSMALLINT;
    resultCode:RETCODE;
    resultErrCode:SQLINTEGER;
    resultErrText:pUCHAR;
    resultState:TsqlState;
    err:integer;
    tempsw:SWORD;
    tempValue:SQLINTEGER;
  begin
    //pass this info to server now
    with c.Marshal do
    begin
      ClearToSend;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      }
      putFunction(SQL_API_SQLGETCONNECTATTR);
      putSQLHDBC(ConnectionHandle);
      putSQLINTEGER(Attribute);
      if Send<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
        exit;
      end;

      {Wait for response}
      if Read<>ok then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
        exit;
      end;
      {Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      }
      getFunction(functionId);
      if functionId<>SQL_API_SQLGETCONNECTATTR then
      begin
        result:=SQL_ERROR;
        c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
        exit;
      end;
      //todo remove- just get integer instead: if getpUCHAR_SWORD(pUCHAR(Value),BufferLength,tempsw)<>ok then exit;
      //todo remove- just get integer instead: StringLength^:=tempsw;
      if getSQLINTEGER(tempValue)<>ok then exit;
      SQLINTEGER(Value^):=tempValue;
      getRETCODE(resultCode);
      result:=resultCode; //pass it on
      {$IFDEF DEBUGDETAIL}
      //todo remove- just get integer instead:  log(format('SQLGetInfo (server-call) returns %s,[Value]));
      log(format('SQLGetInfo (server-call) returns %p',[Value]));
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
            seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
            seInvalidAttribute:      resultState:=ssHY092;
          else
            resultState:=ss08001; //todo more general failure needed/possible?
          end; {case}
          c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
          if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
        end;
        exit;
      end;
    end; {with}
  end; {AskServer}

begin
  {$IFDEF DEBUGDETAIL2}
  log(format('SQLGetConnectAttr called %d %d %p %p',[ConnectionHandle,Attribute,Value,StringLength]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  c:=Tdbc(ConnectionHandle);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  c.diagnostic.clear;

  case Attribute of
    SQL_ATTR_AUTOCOMMIT: //todo SQL_AUTOCOMMIT is more standardised?
    begin
      if c.autoCommit then SQLUINTEGER(Value^):=SQL_TRUE else SQLUINTEGER(Value^):=SQL_FALSE;
    end; {SQL_ATTR_AUTOCOMMIT}
    SQL_ATTR_CONNECTION_DEAD:
    begin
      if c.clientSocket.Connected then
        SQLUINTEGER(VALUE^):=SQL_CD_TRUE
      else
        SQLUINTEGER(VALUE^):=SQL_CD_FALSE;
    end;
    SQL_ATTR_TXN_ISOLATION: //todo SQL_TXN_ISOLATION is more standardised?
    begin
      AskServer;
    end; {SQL_ATTR_TXN_ISOLATION}
    SQL_ATTR_CURRENT_CATALOG:
    begin
      //todo get catalog name from server!
      //todo G1 is not the server default: test only!
(*todo      strLcopy(pUCHAR(Value),'G1',BufferLength-1);
      SQLINTEGER(StringLength^):=SQLINTEGER(length('G1'));
*)
(*todo remove
      strLcopy(pUCHAR(Value),'',BufferLength-1);
      SQLINTEGER(StringLength^):=SQLINTEGER(length(''));
*)
      result:=SQLGetInfo(ConnectionHandle,
                         SQL_DATABASE_NAME,
		         Value,
		         BufferLength,
		         @tempsw);
      StringLength^:=SQLINTEGER(tempsw);
    end;
  else
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLGetConnectAttr called with unhandled type %d',[Attribute]));
    {$ENDIF}
    exit;
  end; {case}
end; {SQLGetConnectAttr}

///// SQLGetDescField /////

function SQLGetDescField  (DescriptorHandle:SQLHDESC;
		 RecordNumber:SQLSMALLINT;
		 FieldIdentifier:SQLSMALLINT;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  d:Tdesc;
  dr:TdescRec;
begin
//todo remove - pain for testing, getDescRec calls this 7 times! log('SQLGetDescField called');
  {$IFDEF DEBUGDETAIL}
  log(format('SQLGetDescField called %d %d %d %p %d p%',[DescriptorHandle,RecordNumber,FieldIdentifier,Value,BufferLength,StringLength]));
  {$ENDIF}

  {Check handle}
  d:=Tdesc(DescriptorHandle);
  if not(d is Tdesc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

//todo remove!  d.diagnostic.clear;

  case FieldIdentifier of
    {Header}
    SQL_DESC_ALLOC_TYPE:
    begin
      SQLSMALLINT(Value^):=d.desc_alloc_type;
    end; {SQL_DESC_ALLOC_TYPE}
    SQL_DESC_COUNT:
    begin
      SQLSMALLINT(Value^):=d.desc_count;
    end; {SQL_DESC_COUNT}
    SQL_DESC_ARRAY_SIZE:
    begin
      SQLINTEGER(Value^):=d.desc_array_size;
    end; {SQL_DESC_ARRAY_SIZE}
    SQL_DESC_BIND_TYPE:
    begin
      SQLUINTEGER(Value^):=d.desc_bind_type;
    end; {SQL_DESC_BIND_TYPE}
    SQL_DESC_ARRAY_STATUS_PTR:
    begin
      pSQLUSMALLINT(Value^):=d.desc_array_status_ptr;
    end; {SQL_DESC_ARRAY_STATUS_PTR}
    SQL_DESC_BIND_OFFSET_PTR:
    begin
      pSQLINTEGER(Value^):=d.desc_bind_offset_ptr;
    end; {SQL_DESC_BIND_OFFSET_PTR}
    SQL_DESC_ROWS_PROCESSED_PTR:
    begin
      pSQLUINTEGER(Value^):=d.desc_rows_processed_ptr;
    end; {SQL_DESC_ROWS_PROCESSED_PTR}
    //todo etc. - see setDescField...

    {Records}
    SQL_DESC_TYPE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_type;
      end; //todo else error
    end; {SQL_DESC_TYPE}
    SQL_DESC_CONCISE_TYPE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_concise_type;
      end; //todo else error
    end; {SQL_DESC_CONCISE_TYPE}
    SQL_DESC_OCTET_LENGTH:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLINTEGER(Value^):=dr.desc_octet_length;
      end; //todo else error
    end; {SQL_DESC_OCTET_LENGTH}
    SQL_DESC_OCTET_LENGTH_POINTER:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLPOINTER(Value^):=dr.desc_octet_length_pointer;
      end; //todo else error
    end; {SQL_DESC_OCTET_LENGTH_POINTER}
    SQL_DESC_INDICATOR_POINTER:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLPOINTER(Value^):=dr.desc_indicator_pointer;
      end; //todo else error
    end; {SQL_DESC_INDICATOR_POINTER}
    SQL_DESC_LENGTH:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLUINTEGER(Value^):=dr.desc_length;
      end; //todo else error
    end; {SQL_DESC_LENGTH}
    SQL_DESC_DISPLAY_SIZE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        {Rules for display size from ODBC SDK help} //todo relocate if used elsewhere?
        case dr.desc_concise_type of
          SQL_CHAR, SQL_VARCHAR,
          SQL_LONGVARBINARY{SQL_BLOB}, //todo? SQL_CLOB
          SQL_LONGVARCHAR{todo debug test...remove?}:
            SQLUINTEGER(Value^):=dr.desc_length;
          SQL_DECIMAL, SQL_NUMERIC:
            SQLUINTEGER(Value^):=dr.desc_precision+2; //for +/- and .
          SQL_BIT:
            SQLUINTEGER(Value^):=1;
          SQL_SMALLINT:
            SQLUINTEGER(Value^):=6; //todo 5 if unsigned
          SQL_INTEGER:
            SQLUINTEGER(Value^):=11; //todo 10 if unsigned
          SQL_FLOAT:
            SQLUINTEGER(Value^):=24;
          SQL_TYPE_DATE:
            SQLUINTEGER(Value^):=10;
          SQL_TYPE_TIME:
            SQLUINTEGER(Value^):=TIME_MIN_LENGTH; //todo or 9+s if fractions
          SQL_TYPE_TIME_WITH_TIMEZONE:
            SQLUINTEGER(Value^):=TIME_MIN_LENGTH+6; //todo or 9+s if fractions
          SQL_TYPE_TIMESTAMP:
            SQLUINTEGER(Value^):=TIMESTAMP_MIN_LENGTH; //todo or 20+s if fractions
          SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
            SQLUINTEGER(Value^):=TIMESTAMP_MIN_LENGTH+6; //todo or 20+s if fractions
          //todo intervals etc.
        else //todo remove: error instead when we cover everything...
          SQLUINTEGER(Value^):=dr.desc_length;
        end; {case}
      end; //todo else error
    end; {SQL_DESC_DISPLAY_SIZE}
    SQL_DESC_DATA_POINTER:  //todo allowed to read?
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLPOINTER(Value^):=dr.desc_data_ptr;
      end; //todo else error
    end; {SQL_DESC_DATA_POINTER}
    SQL_DESC_NAME:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        strLcopy(pUCHAR(Value),dr.desc_name,BufferLength-1);
        StringLength^:=SQLINTEGER(length(dr.desc_name));
      end; //todo else error
    end; {SQL_DESC_NAME}
    SQL_DESC_UNNAMED:
    begin
      //May be used (e.g. by ADO)? But only for name parameters in stored procs if server supports...
    end;
    SQL_DESC_LABEL:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        strLcopy(pUCHAR(Value),dr.desc_name,BufferLength-1);
        StringLength^:=SQLINTEGER(length(dr.desc_name));
      end; //todo else error
    end; {SQL_DESC_LABEL}
    SQL_DESC_PRECISION:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_precision; //Note: only defined for numerics/times so smallint is ok here
      end; //todo else error
    end; {SQL_DESC_PRECISION}
    SQL_DESC_SCALE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_scale;
      end; //todo else error
    end; {SQL_DESC_SCALE}
    SQL_DESC_NULLABLE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_nullable;
      end; //todo else error
    end; {SQL_DESC_NULLABLE}
    SQL_DESC_UNSIGNED:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        SQLSMALLINT(Value^):=dr.desc_unsigned;
      end; //todo else error
    end; {SQL_DESC_UNSIGNED}
    SQL_DESC_UPDATABLE:
    begin
      SQLSMALLINT(Value^):=SQL_ATTR_READWRITE_UNKNOWN; //todo: get from server?
    end; {SQL_DESC_UPDATABLE}
    SQL_DESC_SEARCHABLE:
    begin
      SQLSMALLINT(Value^):=SQL_PRED_SEARCHABLE; //todo: get from server?
      //todo use all_except_like for non-varchar!
    end; {SQL_DESC_SEARCHABLE}

    SQL_DESC_BASE_COLUMN_NAME:
    begin
      //todo Fix! this is not quite right: we don't want the alias but the underlying column name
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        strLcopy(pUCHAR(Value),dr.desc_name,BufferLength-1);
        StringLength^:=SQLINTEGER(length(dr.desc_name));
      end; //todo else error
    end; {SQL_DESC_BASE_COLUMN_NAME}

    SQL_DESC_SCHEMA_NAME:
    begin
      //TODO fix! just stub for tests...
      strLcopy(pUCHAR(Value),'',BufferLength-1);
      StringLength^:=SQLINTEGER(length(''));
    end; {SQL_DESC_SCHEMA_NAME}
    SQL_DESC_TABLE_NAME:
    begin
      //TODO fix! just stub for tests...
      strLcopy(pUCHAR(Value),'',BufferLength-1);
      StringLength^:=SQLINTEGER(length(''));
      (* avoid AV
      //todo Fix!? check source!
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        strLcopy(pUCHAR(Value),dr.desc_base_table_name,BufferLength-1);
        StringLength^:=SQLINTEGER(length(dr.desc_base_table_name));
      end; //todo else error
      *)
    end; {SQL_DESC_TABLE_NAME}
    SQL_DESC_BASE_TABLE_NAME:
    begin
      //TODO fix! just stub for tests...
      strLcopy(pUCHAR(Value),'',BufferLength-1);
      StringLength^:=SQLINTEGER(length(''));
      (* avoid AV
      //todo Fix!? check source!
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        strLcopy(pUCHAR(Value),dr.desc_base_table_name,BufferLength-1);
        StringLength^:=SQLINTEGER(length(dr.desc_base_table_name));
      end; //todo else error
      *)
    end; {SQL_DESC_BASE_TABLE_NAME}
    SQL_DESC_CATALOG_NAME:
    begin
      //TODO fix! just stub for tests...
      strLcopy(pUCHAR(Value),'',BufferLength-1);
      StringLength^:=SQLINTEGER(length(''));
    end; {SQL_DESC_CATALOG_NAME}
    SQL_DESC_AUTO_UNIQUE_VALUE:
    begin
      SQLUINTEGER(Value^):=SQL_FALSE;
    end; {SQL_DESC_AUTO_UNIQUE_VALUE}
    SQL_DESC_CASE_SENSITIVE:
    begin
      SQLUINTEGER(Value^):=SQL_FALSE;
    end; {SQL_DESC_CASE_SENSITIVE}

    //todo etc...!!!!!!!!!!!
  else
    result:=SQL_ERROR;
    d.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLGetDescField called with unhandled type %d',[FieldIdentifier]));
    {$ENDIF}
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end; {SQLGetDescField}
(*
///// SQLGetDescRec /////

RETCODE SQL_API SQLGetDescRec  (SQLHDESC arg0,
		 SQLSMALLINT arg1,
		 SQLCHAR * arg2,
		 SQLSMALLINT arg3,
		 UNALIGNED SQLSMALLINT * arg4,
		 UNALIGNED SQLSMALLINT * arg5,
		 UNALIGNED SQLSMALLINT * arg6,
		 UNALIGNED SQLINTEGER  * arg7,
		 UNALIGNED SQLSMALLINT * arg8,
		 UNALIGNED SQLSMALLINT * arg9,
		 UNALIGNED SQLSMALLINT * arg10)
{
	log("SQLGetDescRec called\n");
	return(SQL_SUCCESS);
}
*)

///// SQLGetDiagField /////

function SQLGetDiagField  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 RecordNumber:SQLSMALLINT;
		 DiagIdentifier:SQLSMALLINT;
		 DiagInfo:SQLPOINTER;
		 BufferLength:SQLSMALLINT;
		 StringLength:{UNALIGNED}pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
  c:Tdbc;
  s:Tstmt;

  err:PtrTerror;
  response:string;

  odbcVersion:SQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL2}
  log(format('SQLGetDiagField called %d %d %d %d %p %d %p',[HandleType,Handle,RecordNumber,DiagIdentifier,DiagInfo,BufferLength,StringLength]));
  {$ENDIF}

  result:=SQL_SUCCESS; //assume found ok (simplifies field found exit code)

  {Initialise output arguments as per spec.}
  if DiagInfo<>nil then strLcopy(pUCHAR(DiagInfo),'',BufferLength-1); //pSQLCHAR(DiagInfo{todo remove!^}):=#0;
  if StringLength<>nil then SQLSMALLINT(StringLength^):=SQLSMALLINT(0);

  {Get the requested diagnostic record}
  err:=nil;
  case HandleType of
    SQL_HANDLE_ENV:
    begin
      {Check handle}
      e:=Tenv(Handle);
      if not(e is Tenv) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      {Check header fields}
      case DiagIdentifier of
        SQL_DIAG_NUMBER:
        begin
          SQLINTEGER(DiagInfo^):=e.diagnostic.errorCount;
          exit;
        end; {SQL_DIAG_NUMBER}
        //todo rest - note: code is duplicated for each handle type below...maybe easier to use 'resource class' that has diagnostic & other generic info & then sub-class tenv, tdbc etc.?
      //else check if record field below...
      end; {case}
      e.diagnostic.getError(RecordNumber,err); //todo check result
      odbcVersion:=e.odbcVersion;
    end; {SQL_HANDLE_ENV}

    SQL_HANDLE_DBC:
    begin
      {Check handle}
      c:=Tdbc(Handle);
      if not(c is Tdbc) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      {Check header fields}
      case DiagIdentifier of
        SQL_DIAG_NUMBER:
        begin
          SQLINTEGER(DiagInfo^):=c.diagnostic.errorCount;
          exit;
        end; {SQL_DIAG_NUMBER}
        //todo rest
      //else check if record field below...
      end; {case}
      c.diagnostic.getError(RecordNumber,err); //todo check result
      odbcVersion:=(c.owner as Tenv).odbcVersion;
    end; {SQL_HANDLE_DBC}

    SQL_HANDLE_STMT:
    begin
      {Check handle C1..C4}
      s:=Tstmt(Handle);
      if not(s is Tstmt) then
      begin
        result:=SQL_INVALID_HANDLE;
        exit;
      end;
      //assert/check c(s.owner).state=C5/C6
      {Check header fields}
      case DiagIdentifier of
        SQL_DIAG_NUMBER:
        begin
          SQLINTEGER(DiagInfo^):=s.diagnostic.errorCount;
          exit;
        end; {SQL_DIAG_NUMBER}
        SQL_DIAG_DYNAMIC_FUNCTION_CODE:
        begin
          SQLINTEGER(DiagInfo^):=SQL_DIAG_SELECT_CURSOR;
          exit;
        end; {SQL_DIAG_DYNAMIC_FUNCTION_CODE}
        //todo rest
      //else check if record field below...
      end; {case}
      s.diagnostic.getError(RecordNumber,err); //todo check result
      odbcVersion:=((s.owner as Tdbc).owner as Tenv).odbcVersion;
    end; {SQL_HANDLE_STMT}
  else
    result:=SQL_INVALID_HANDLE;
    exit;
  end; {case}

  {Select the field}
  if err<>nil then
  begin
    case DiagIdentifier of

      {Record fields}
      SQL_DIAG_SQLSTATE:
      begin
        if odbcVersion=SQL_OV_ODBC2 then //return old-fashioned state code
          response:=ssStateTextODBC2[err^.sqlstate] //need to include \0! //todo or maybe now we can store state text as normal strings?
        else //return v3 state code
          response:=ssStateText[err^.sqlstate]; //need to include \0! //todo or maybe now we can store state text as normal strings?

        strLcopy(pUCHAR(DiagInfo),pchar(response),BufferLength-1);
        SQLSMALLINT(StringLength^):=SQLSMALLINT(length(response));           //todo check SQLSMALLINT(...) is around every such return fixed type!
        {$IFDEF DEBUGDETAIL2} //todo remove
        log(format('SQLGetDiagField returning %s. Called with SQL_DIAG_SQLSTATE %d %d %d %d',[response,HandleType,RecordNumber,DiagIdentifier,BufferLength]));
        {$ENDIF}
        exit;
      end; {SQL_DIAG_SQLSTATE}
      SQL_DIAG_NATIVE:
      begin
        SQLINTEGER(DiagInfo^):=err^.native;
        exit;
      end; {SQL_DIAG_NATIVE}
      SQL_DIAG_MESSAGE_TEXT:
      begin
        {$IFDEF DEBUGDETAIL2} //todo remove
        log(format('SQLGetDiagField called with SQL_DIAG_MESSAGE_TEXT %d %d %d %d',[HandleType,RecordNumber,DiagIdentifier,BufferLength]));
        {$ENDIF}
        {$IFDEF DEBUGDETAIL2} //todo remove
        log(format('SQLGetDiagField returning %s. Called with SQL_DIAG_MESSAGE_TEXT %d %d %d %d',[err^.text,HandleType,RecordNumber,DiagIdentifier,BufferLength]));
        {$ENDIF}
        response:=err^.text;
        strLcopy(pUCHAR(DiagInfo),pchar(response),BufferLength-1);
        SQLSMALLINT(StringLength^):=SQLSMALLINT(length(response)); //todo remove debug comment: tried SQLSMALLINT cast: if this cast worked, would have put everywhere!
        if BufferLength<length(err^.text) then result:=SQL_SUCCESS_WITH_INFO; //todo if works,put everywhere in this routine at least!
           //Note: should read: if BufferLength<=length(err^.text) then... because bufferLength has to include #0
           // - todo!!!: call returnString routine to do all this
        exit;
      end; {SQL_DIAG_MESSAGE_TEXT}
      SQL_DIAG_MESSAGE_LENGTH, SQL_DIAG_MESSAGE_OCTET_LENGTH:
      begin
        {$IFDEF DEBUGDETAIL2} //todo remove
        log(format('SQLGetDiagField called with SQL_DIAG_MESSAGE_LENGTH %d %d %d %d',[HandleType,RecordNumber,DiagIdentifier,BufferLength]));
        log(format('SQLGetDiagField returning %d. Called with SQL_DIAG_MESSAGE_LENGTH %d %d %d %d',[length(err^.text),HandleType,RecordNumber,DiagIdentifier,BufferLength]));
        {$ENDIF}
        SQLINTEGER(DiagInfo^):=length(err^.text);
        exit;
      end; {SQL_DIAG_MESSAGE_LENGTH, SQL_DIAG_MESSAGE_OCTET_LENGTH}
      SQL_DIAG_CLASS_ORIGIN,SQL_DIAG_SUBCLASS_ORIGIN:
      begin
        if not(copy(ssStateText[err^.sqlstate],1,2)='IM'){todo list all non-standard prefixes here - use const array!!!} then
          response:='ISO 9075' //todo check this is always correct here - use constant
        else
          response:='ODBC 3.0'; //todo ok? or should it be MS ODBC or something? //todo use constant!
        strLcopy(pUCHAR(DiagInfo),pchar(response),BufferLength-1);
        SQLSMALLINT(StringLength^):=SQLSMALLINT(length(response));
        exit;
      end; {SQL_DIAG_CLASS_ORIGIN,SQL_DIAG_SUBCLASS_ORIGIN}

      SQL_DIAG_COLUMN_NUMBER:
      begin
        SQLINTEGER(DiagInfo^):=err^.rn;
        exit;
      end; {SQL_DIAG_COLUMN_NUMBER}
      SQL_DIAG_ROW_NUMBER:
      begin
        SQLINTEGER(DiagInfo^):=err^.row;
        exit;
      end; {SQL_DIAG_ROW_NUMBER}
      SQL_DIAG_CONNECTION_NAME:
      begin
        response:='TODO'; //todo complete
        strLcopy(pUCHAR(DiagInfo),pchar(response),BufferLength-1);
        SQLSMALLINT(StringLength^):=SQLSMALLINT(length(response));
        exit;
      end; {SQL_DIAG_CONNECTION_NAME}
      SQL_DIAG_SERVER_NAME:
      begin
        response:='TODO'; //todo complete
        strLcopy(pUCHAR(DiagInfo),pchar(response),BufferLength-1);
        SQLSMALLINT(StringLength^):=SQLSMALLINT(length(response));
        exit;
      end; {SQL_DIAG_SERVER_NAME}

      //todo etc.
    else
      //todo reinstate: debug!?: result:=SQL_ERROR;
      {$IFDEF DEBUGDETAILWARNING}
      //todo remove:
      log(format('SQLGetDiagField called with unhandled field number %d %d %d %d',[HandleType,RecordNumber,DiagIdentifier,BufferLength]));
      {$ENDIF}
      //SQL/92 says return HY024 invalid attribute, but ODBC & standard say this function cannot log errors!
      exit;
    end; {case}
  end;
  //else drop through to return SQL_NO_DATA   //todo different if recordNumber<1: error 35000, if too big:error 0100 no data - but again we cannot add errors in this function!

  result:=SQL_NO_DATA;
end; {SQLGetDiagField}

///// SQLGetDiagRec /////

(*
function SQLGetDiagRec  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 RecordNumber:SQLSMALLINT;
		 Sqlstate:pSQLCHAR;
		 NativeError:{UNALIGNED}pSQLINTEGER;
		 MessageText:pSQLCHAR;
		 BufferLength:SQLSMALLINT;
		 TextLength:{UNALIGNED}pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
function SQLGetDiagRec  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 RecordNumber:SQLSMALLINT;
		 Sqlstate:pUCHAR;
		 NativeError:{UNALIGNED}pSQLINTEGER;
		 MessageText:pUCHAR;
		 BufferLength:SQLSMALLINT;
		 TextLength:{UNALIGNED}pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  len:SQLSMALLINT;
begin
  {$IFDEF DEBUGDETAIL2}
  log('SQLGetDiagRec called');
  {$ENDIF}

  result:=SQL_SUCCESS; //in the unlikely case that all output pointers are null

  {$IFDEF DEBUGDETAIL2} //todo remove
  if MessageText<>nil then
    log(format('SQLGetDiagRec called with MessageText<>nil %d %d %d %d',[HandleType,RecordNumber,longint(MessageText),BufferLength]));
  if TextLength<>nil then
    log(format('SQLGetDiagRec called with TextLength<>nil %d',[longint(TextLength)]));
  if Sqlstate<>nil then
    log(format('SQLGetDiagRec called with Sqlstate<>nil %d',[longint(Sqlstate)]));
  if NativeError<>nil then
    log(format('SQLGetDiagRec called with NativeError<>nil %d',[longint(NativeError)]));
  {$ENDIF}

  //todo fix: if HandleType=SQL_HANDLE_DBC then BufferLength=2 for some strange reason!?

  //todo may be quicker to read error record here & populate results in one go? but duplicate code... keep it neat!
  {Initialise output arguments as per spec.}
  if Sqlstate<>nil then strLcopy(pUCHAR(Sqlstate),'',6-1); //SQLCHAR(Sqlstate^):=#0;
  if NativeError<>nil then SQLINTEGER(NativeError^):=0;
  if MessageText<>nil then strLcopy(pUCHAR(MessageText),'',BufferLength-1); //SQLCHAR(MessageText^):=#0;
  if TextLength<>nil then SQLSMALLINT(TextLength^):=SQLSMALLINT(0);

  if Sqlstate<>nil then
    {Get sqlstate}
    result:=SQLGetDiagField(HandleType,
                   Handle,
                   RecordNumber,
                   SQL_DIAG_SQLSTATE,
                   Sqlstate,
                   SQL_SQLSTATE_SIZE+1, //todo +1 to be able to accept \0?
                   @len);
  //todo if ok, assert len=5
  if result=SQL_SUCCESS then  {Get native}
    if NativeError<>nil then
      result:=SQLGetDiagField(HandleType,
                     Handle,
                     RecordNumber,
                     SQL_DIAG_NATIVE,
                     NativeError,
                     SQL_IS_INTEGER,
                     @len);

  {$IFDEF DEBUGDETAIL2} //todo remove
  if MessageText<>nil then
    log(format('SQLGetDiagRec still has MessageText<>nil %d %d %d %d',[HandleType,RecordNumber,longint(MessageText),BufferLength]));
  if TextLength<>nil then
    log(format('SQLGetDiagRec still has TextLength<>nil %d',[longint(TextLength)]));
  if Sqlstate<>nil then
    log(format('SQLGetDiagRec still has Sqlstate<>nil %d',[longint(Sqlstate)]));
  if NativeError<>nil then
    log(format('SQLGetDiagRec still has NativeError<>nil %d',[longint(NativeError)]));
  {$ENDIF}


  if result=SQL_SUCCESS then  {Get message text}
    if MessageText<>nil then
      result:=SQLGetDiagField(HandleType,
                     Handle,
                     RecordNumber,
                     SQL_DIAG_MESSAGE_TEXT,
                     MessageText,
                     BufferLength,
                     TextLength);
  {$IFDEF DEBUGDETAIL2} //todo remove
  if Sqlstate<>nil then
    log(format('SQLGetDiagRec returning with %s',[pUCHAR(Sqlstate)]));
  {$ENDIF}
  {$IFDEF DEBUGDETAIL2} //todo remove
  if MessageText<>nil then
    log(format('SQLGetDiagRec returning with %s %d',[pUCHAR(MessageText),SQLSMALLINT(TextLength^)]));
  {$ENDIF}
end; {SQLGetDiagRec}

///// SQLGetEnvAttr /////

function SQLGetEnvAttr  (EnvironmentHandle:SQLHENV;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
begin
  {$IFDEF DEBUGDETAIL2}
  log('SQLGetEnvAttr called');
  {$ENDIF}

  {Check handle}
  e:=Tenv(EnvironmentHandle);
  if not(e is Tenv) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  e.diagnostic.clear;

  case Attribute of
    SQL_ATTR_OUTPUT_NTS:
    begin
      SQLINTEGER(Value^):=e.nullTermination;
    end; {SQL_ATTR_OUTPUT_NTS}
    SQL_ATTR_ODBC_VERSION:
    begin
      SQLINTEGER(Value^):=e.odbcVersion;
    end; {SQL_ATTR_ODBC_VERSION}
  else
    result:=SQL_ERROR;
    e.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end;


///// SQLGetStmtAttr /////

function SQLGetStmtAttr  (StatementHandle:SQLHSTMT;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL2}
  log(format('SQLGetStmtAttr called %d %d %p %d',[StatementHandle,Attribute,Value,BufferLength]));
  {$ENDIF}
  
  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  s.diagnostic.clear;

  if (s.state>=S8) {=>..S12} then  //todo or s.active?
  begin
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY010,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    exit;
  end;

  //todo ODBC spec says most/all of these are actually SQLUINTEGER - so change them!
  // - although function header is SQLINTEGER!

  case Attribute of
    SQL_ATTR_CURSOR_HOLDABLE:
    begin
      //not supported //todo better to return SQL_NONHOLDABLE?
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_CURSOR_HOLDABLE}
    SQL_ATTR_CURSOR_SENSITIVITY:
    begin
      //todo when we support sensitive cursors then
      //SQLINTEGER(Value^):=longint(0 / 1 / 2);
      //else for now not supported - todo maybe better to return HYC00 = not implemented?
      SQLINTEGER(Value^):=SQL_UNSPECIFIED;
    end; {SQL_ATTR_CURSOR_SENSITIVITY}
    SQL_ATTR_CURSOR_SCROLLABLE:
    begin
      //todo when we support scrollable cursors then
      //SQLINTEGER(Value^):=longint(SQL_NONSCROLLABLE / SQL_SCROLLABLE);
      //else for now not supported - todo maybe better to return HYC00 = not implemented?
      SQLINTEGER(Value^):=SQL_NONSCROLLABLE;
    end; {SQL_ATTR_CURSOR_SCROLLABLE}

    SQL_ATTR_APP_ROW_DESC:
    begin
      SQLINTEGER(Value^):=SQLHDESC(s.ard);
    end; {SQL_ATTR_APP_ROW_DESC}
    SQL_ATTR_APP_PARAM_DESC:
    begin
      SQLINTEGER(Value^):=SQLHDESC(s.apd);
    end; {SQL_ATTR_APP_PARAM_DESC}
    SQL_ATTR_IMP_ROW_DESC:
    begin
      SQLINTEGER(Value^):=SQLHDESC(s.ird);
    end; {SQL_ATTR_IMP_ROW_DESC}
    SQL_ATTR_IMP_PARAM_DESC:
    begin
      SQLINTEGER(Value^):=SQLHDESC(s.ipd);
    end; {SQL_ATTR_IMP_PARAM_DESC}

    SQL_ATTR_METADATA_ID:
    begin
      SQLINTEGER(Value^):=longint(s.metaDataId);
    end; {SQL_ATTR_METADATA_ID}

    {from ODBC}
    SQL_ATTR_ASYNC_ENABLE:
    begin
      SQLINTEGER(Value^):=SQL_ASYNC_ENABLE_OFF; //the default - todo neater to use SQL_ASYNC_ENABLE_DEFAULT?
    end; {SQL_ATTR_ASYNC_ENABLE}
    SQL_ATTR_CONCURRENCY:
    begin
      SQLINTEGER(Value^):=(SQL_CONCUR_READ_ONLY OR SQL_CONCUR_VALUES OR SQL_CONCUR_TIMESTAMP); //todo just for now... //todo neater to use SQL_CONCUR_DEFAULT?
      //Note: added non-read-only for ADO from Delphi
    end; {SQL_ATTR_CONCURRENCY}
    SQL_ATTR_CURSOR_TYPE:
    begin
      SQLINTEGER(Value^):=SQL_CURSOR_FORWARD_ONLY; //todo just for now... //todo neater to use SQL_CURSOR_TYPE_DEFAULT?
    end; {SQL_ATTR_CURSOR_TYPE}
    SQL_ATTR_ENABLE_AUTO_IPD:
    begin
      SQLINTEGER(Value^):=SQL_TRUE; //todo is this totally true? I think we currently always define as strings=too basic
    end; {SQL_ATTR_ENABLE_AUTO_IPD}

    SQL_ATTR_NOSCAN:
    begin
      SQLINTEGER(Value^):=SQL_NOSCAN_ON; //i.e. we never scan for escape sequences
    end; {SQL_ATTR_NOSCAN}

    SQL_ATTR_QUERY_TIMEOUT:
    begin
      SQLINTEGER(Value^):=0; //no timeout
    end;
    SQL_ATTR_MAX_ROWS:
    begin
      SQLINTEGER(Value^):=0; //no timeout
    end;

    //for ADO,currently ignored
    SQL_ATTR_RETRIEVE_DATA:
    begin
    end;
    SQL_ROWSET_SIZE:
    begin
    end;

    (*todo remove: set only!
    SQL_ATTR_ROW_STATUS_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ird),1,SQL_DESC_ARRAY_STATUS_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_STATUS_PTR}
    SQL_ATTR_ROWS_FETCHED_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ird),1,SQL_DESC_ROWS_PROCESSED_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROWS_FETCHED_PTR}
    *)

    SQL_ATTR_USE_BOOKMARKS:
    begin
      SQLINTEGER(Value^):=SQL_UB_OFF; //todo neater to use SQL_UB_DEFAULT?
    end; {SQL_ATTR_USE_BOOKMARKS}

    {todo if SQL_ATTR_ROW_NUMBER
      if (s.state = S1..S4) then
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ss24000,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
    }
  else
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY092,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLGetStmtAttr called with unhandled type %d',[Attribute]));
    {$ENDIF}
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end; {SQLGetStmtAttr}

///// SQLSetConnectAttr /////

function SQLSetConnectAttr  (ConnectionHandle:SQLHDBC;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  c:Tdbc;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetConnectAttr called %d %d %p %d',[ConnectionHandle,Attribute,Value,StringLength]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default

  {Check handle}
  c:=Tdbc(ConnectionHandle);
  if not(c is Tdbc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  c.diagnostic.clear;

  case Attribute of
    SQL_ATTR_AUTOCOMMIT: //todo SQL_AUTOCOMMIT is more standardised?
    begin
      //todo we should probably have to do something now if this flips...
      case SQLUINTEGER(Value) of
        SQL_AUTOCOMMIT_OFF: c.autoCommit:=False;
        SQL_AUTOCOMMIT_ON: c.autoCommit:=True;
      //else error! todo!
      end; {case}
    end; {SQL_ATTR_AUTOCOMMIT}
    SQL_ATTR_TXN_ISOLATION: //todo SQL_TXN_ISOLATION is more standardised?
    begin
      with c.Marshal do
      begin
        ClearToSend;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        }
        putFunction(SQL_API_SQLSETCONNECTATTR);
        putSQLHDBC(ConnectionHandle);
        putSQLINTEGER(Attribute);
        putSQLUINTEGER(SQLUINTEGER(Value)); //= isolation level
        if Send<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
          exit;
        end;

        {Wait for response}
        if Read<>ok then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
          exit;
        end;
        {Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        }
        getFunction(functionId);
        if functionId<>SQL_API_SQLSETCONNECTATTR then
        begin
          result:=SQL_ERROR;
          c.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
          exit;
        end;
        getRETCODE(resultCode);
        result:=resultCode; //pass it on
        {$IFDEF DEBUGDETAIL}
        log(format('SQLSetConnectAttr (SQL_ATTR_TXN_ISOLATION %d) returns %d',[SQLUINTEGER(Value),resultCode]));
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
              seInvalidHandle:           begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
              seInvalidTransactionState: begin resultState:=ssHY011; end;
              seInvalidAttribute:        begin resultState:=ssHY024; end;
            else
              resultState:=ss08001; //todo more general failure needed/possible?
            end; {case}
            c.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
            if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
          end;
          exit;
        end;
      end; {with}
    end; {SQL_ATTR_TXN_ISOLATION}

    SQL_ATTR_LOGIN_TIMEOUT:
    begin
      c.login_timeout:=SQLUINTEGER(Value);
    end; {SQL_ATTR_LOGIN_TIMEOUT}


    //for ADO, not implemented
    SQL_CURRENT_QUALIFIER:
    begin
      //todo ADO from Delphi tries to set database/catalog this way...
    end;

    //for ADO (ODBC 2 stmt-level attempts which we shouldn't support)
    SQL_QUERY_TIMEOUT,SQL_MAX_ROWS:
    begin
    end;
  else
    //todo skip this? MSAccess97 seems to crash if we don't handle some of its pre-connection settings...
    result:=SQL_ERROR;
    c.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLSetConnectAttr called with unhandled type %d',[Attribute]));
    {$ENDIF}
    exit;
  end; {case}
end; {SQLSetConnectAttr}

///// SQLSetDescField /////

function SQLSetDescField  (DescriptorHandle:SQLHDESC;
		 RecordNumber:SQLSMALLINT;
		 FieldIdentifier:SQLSMALLINT;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{
 Side-effects
   may need to allocate new desc record space to handle any new recordNumbers
   will (todo: may?) call server if an ARD is bound or unbound
     - so that the server can just send back result data for bound columns to save time & network traffic
}
var
  d:Tdesc;
  dr:TdescRec;

  boundChange:boolean;

  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  resultState:TsqlState;
  tempsw:SWORD;
  err:integer;

  i:integer;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetDescField called %d %d %d %p %d',[DescriptorHandle,RecordNumber,FieldIdentifier,Value,BufferLength]));
  {$ENDIF}

  result:=SQL_SUCCESS; //default
  resultErrText:=nil;

  {Check handle}
  d:=Tdesc(DescriptorHandle);
  if not(d is Tdesc) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

//todo remove!  d.diagnostic.clear;

  //assert owner is stmt...    //todo remove!?
  if not(d.owner is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    //todo log which error? d.diagnostic.logError(ssHY091,fail,'',0,0); //todo check result
    exit;
  end;

  if Tstmt(d.owner).state>=S8 then //todo check we always can cast owner=stmt
  begin
    result:=SQL_ERROR;
    d.diagnostic.logError(ssHY010,fail,'',0,0); //todo check result //todo check d, not s?
    exit;
  end;

  //todo place these next two if blocks into one: if IRD then...
  {Check if the IRD has been populated yet - if not error - we re-use desc_count for this}
  if (d.desc_type=SQL_ATTR_IMP_ROW_DESC) and (d.desc_count=0) then
  begin //too early - the IRD hasn't been populated yet //todo: when do we reset desc_count to 0, on cursor close?
    result:=SQL_ERROR;
    d.diagnostic.logError(ssHY091,fail,'',0,0); //todo check result
    exit;
  end;

  {Check we are allowed to modify this}
  if (d.desc_type=SQL_ATTR_IMP_ROW_DESC) and
     ( (FieldIdentifier<>SQL_DESC_ARRAY_STATUS_PTR) and (FieldIdentifier<>SQL_DESC_ROWS_PROCESSED_PTR) ) then
  begin
    result:=SQL_ERROR;
    d.diagnostic.logError(ssHY016,fail,'',0,0); //todo check result
    exit;
  end;

  //todo more validity checks... based on R/W list

  //also reject unused entries, e.g. IRD.SQL_DESC_DATA_PTR etc.

  //reject/ignore ADO parameter settings
  {Check if the APD has been populated yet - if not error - we re-use desc_count for this}
  if (d.desc_type=SQL_ATTR_APP_PARAM_DESC) and (d.desc_count=0) and (FieldIdentifier=SQL_DESC_OCTET_LENGTH_POINTER) then
  begin //too early - the IRD hasn't been populated yet //todo: when do we reset desc_count to 0, on cursor close?
    //result:=SQL_ERROR;
    //d.diagnostic.logError(ssHY091,fail,'',0,0); //todo check result
    exit; //ignore & don't increment our desc_count
  end;

  if RecordNumber<0 then
  begin
    result:=SQL_ERROR;
    d.diagnostic.logError(ss07009,fail,'',0,0); //todo check result
    exit;
  end;
  //todo if recordNumber=0 and not a header - error

  //todo if not header & not pointer, set pointer=0

  case FieldIdentifier of
    {Header}
    SQL_DESC_COUNT:
    begin
      if SQLSMALLINT(Value)<d.desc_count then
      begin
        {Unbind any bound columns that will be purged as a result}
        for i:=SQLSMALLINT(Value)+1 to d.desc_count do
        begin
          result:=SQLSetDescField(DescriptorHandle,i,SQL_DESC_DATA_POINTER,nil,00); //1 level of recursion
          if result=SQL_ERROR then //todo should probably continue, but retain any error
          begin
            //todo remove: d.diagnostic.logError(ssTODO,fail,'textTODO!',0,0); //todo correct?pass details! //todo check result
            exit;
          end;
        end;
        d.desc_count:=SQLSMALLINT(Value);
        {Now remove any garbage records (i.e. those numbered > new desc_count) - as per ODBC standard}
        d.PurgeRecords;
      end
      else
      begin
        {This may increase the count, but we don't need to do anything else yet
         todo: in future, may help memory allocation to know max-size in advance?}
        d.desc_count:=SQLSMALLINT(Value);
      end;
    end; {SQL_DESC_COUNT}
    SQL_DESC_ARRAY_SIZE:
    begin
      //todo check limit?
      d.desc_array_size:=SQLUINTEGER(Value);
      if (d.desc_type=SQL_ATTR_APP_ROW_DESC) then
      begin
        //pass this info to server now
        with ((d.owner as Tstmt).owner as Tdbc).Marshal do
        begin
          ClearToSend;
          {Note: because we know these marshalled parameters all fit in a buffer together,
           and because the buffer is now empty after the clearToSend,
           we can omit the error result checking in the following put() calls = speed
          }
          //note: it might be easier just to pass serverStmt,array_size
          //but we're trying to keep this function the same on the server because we need it for other things...
          // - we could always call a special serverSetArraySize routine here instead?
          //      or pass it every time we call ServerFetch?
          putFunction(SQL_API_SQLSETDESCFIELD);
          putSQLHSTMT((d.owner as Tstmt).ServerStatementHandle); //pass server statement ref (it has no concept of our desc's)
          putSQLSMALLINT(d.desc_type); //todo don't really need this since server only cares about us setting its ARD responsibilities (currently...)
          //together, the above two are the server's closest concept of our DescriptorHandle
          putSQLSMALLINT(0{todo remove:recordNumber}); //this should be passed as 0, but we make sure the server isn't confused if it's not
          putSQLSMALLINT(FieldIdentifier); //=SQL_DESC_ARRAY_SIZE
          putSQLUINTEGER(SQLUINTEGER(Value)); //= array size
          putSQLINTEGER(BufferLength);
          if Send<>ok then
          begin
            result:=SQL_ERROR;
            d.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
            exit;
          end;

          {Wait for response}
          if Read<>ok then
          begin
            result:=SQL_ERROR;
            d.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
            exit;
          end;
          {Note: because we know these marshalled parameters all fit in a buffer together,
           and because the buffer has been read in total by the Read above because its size was known,
           we can omit the error result checking in the following get() calls = speed
          }
          getFunction(functionId);
          if functionId<>SQL_API_SQLSETDESCFIELD then
          begin
            result:=SQL_ERROR;
            d.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
            exit;
          end;
          getRETCODE(resultCode);
          result:=resultCode; //pass it on
          {$IFDEF DEBUGDETAIL}
          log(format('SQLSetDescField (ARD & ARRAY_SIZE %d) returns %d',[SQLUINTEGER(Value),resultCode]));
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
                seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
                seNotPrepared:           resultState:=ssHY010;
                seUnknownFieldId:        resultState:=ssHY092; //todo ok???
              else
                resultState:=ss08001; //todo more general failure needed/possible?
              end; {case}
              d.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
              if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
            end;
            exit;
          end;
        end; {with}
      end;
      //todo else who cares?
    end; {SQL_DESC_ARRAY_SIZE}
    SQL_DESC_ARRAY_STATUS_PTR:
    begin
      d.desc_array_status_ptr:=Value; //deferred field
    end; {SQL_DESC_ARRAY_STATUS_PTR}
    SQL_DESC_BIND_OFFSET_PTR:
    begin
      d.desc_bind_offset_ptr:=Value; //deferred field
    end; {SQL_DESC_BIND_OFFSET_PTR}
    SQL_DESC_BIND_TYPE:
    begin
      d.desc_bind_type:=SQLUINTEGER(Value);
    end; {SQL_DESC_BIND_TYPE}
    SQL_DESC_ROWS_PROCESSED_PTR:
    begin
      d.desc_rows_processed_ptr:=Value; //deferred field
    end; {SQL_DESC_ROWS_PROCESSED_PTR}
    //todo etc.

    {Records}
    //todo it would be nice to getRecord here, once, since all below will probably need it
    // so use else & start new sub-case & then can error handle getRecord once = simplified code
    // - do same for getDescfield

    //todo: check we haven't confused the ODBC c type definitions and the standard ones
    // - especially the date-time-interval ones - there's loads flying around & it's confusing...
    //I think we only need to check here for C datatypes - never SQL ones(?) todo!
    SQL_DESC_TYPE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_type:=SQLSMALLINT(Value);
        case dr.desc_type of
          SQL_DATETIME:
          begin
            //we assume caller will set dr.desc_datetime_interval_code appropriately
            {set dr.desc_concise_type appropriately}
            case dr.desc_datetime_interval_code of
              SQL_CODE_DATE:                    dr.desc_concise_type:=SQL_TYPE_DATE;
              SQL_CODE_TIME:                    dr.desc_concise_type:=SQL_TYPE_TIME; //what about SQL_TYPE_TIME_WITH_TIMEZONE?
              SQL_CODE_TIMESTAMP:               dr.desc_concise_type:=SQL_TYPE_TIMESTAMP; //what about SQL_TYPE_TIMESTAMP_WITH_TIMEZONE?
            end; {case}
          end;
          SQL_INTERVAL:
          begin
            //we assume caller will set dr.desc_datetime_interval_code appropriately
            //we set dr.desc_concise_type appropriately
          end;
        else
          //todo trying to set to a concise datetime type here should give HY021
          dr.desc_concise_type:=dr.desc_type; //todo or do we leave this to caller?
          dr.desc_datetime_interval_code:=0;  //todo or do we leave this to caller? best not to?
        end; {case}
        //this may also now reset some other values
        case dr.desc_type of
          SQL_CHAR, SQL_VARCHAR
          {SQL_C_CHAR, SQL_C_VARCHAR}:
          begin
            dr.desc_length:=1;
            dr.desc_precision:=0;
          end; {SQL_CHAR, SQL_VARCHAR}
          SQL_DATETIME:
          begin
            if dr.desc_datetime_interval_code in [SQL_CODE_DATE,SQL_CODE_TIME] then
              dr.desc_precision:=0
            else
              if dr.desc_datetime_interval_code=SQL_CODE_TIMESTAMP then
                dr.desc_precision:=6;
          end; {SQL_DATETIME}
          SQL_DECIMAL, SQL_NUMERIC {SQL_C_NUMERIC}:
          begin
            if dr.desc_scale=0 then
              dr.desc_precision:=SQL_MAX_NUMERIC_LEN; //todo max precision for the datatype
          end; {SQL_DECIMAL, SQL_NUMERIC}
          SQL_FLOAT, SQL_C_FLOAT:
          begin
            dr.desc_precision:=8; //todo set to the implementation-defined precision for float
            //todo what about double?
          end; {SQL_FLOAT}
          SQL_INTERVAL:
          begin
            if dr.desc_datetime_interval_code in [SQL_INTERVAL_YEAR..SQL_INTERVAL_MINUTE_TO_SECOND] then
              dr.desc_datetime_interval_precision:=2;
            if dr.desc_datetime_interval_code in [SQL_INTERVAL_SECOND,SQL_INTERVAL_DAY_TO_SECOND,SQL_INTERVAL_HOUR_TO_SECOND,SQL_INTERVAL_MINUTE_TO_SECOND] then
              dr.desc_precision:=6;
          end; {SQL_INTERVAL}
        end; {case}

        //todo also, set desc_octet length to size of type if type is fixed,
        // so that fetch will work properly when column-wise binding
        // (only needed if BindCol is not used to setup column)
        // - true for ARD and APD???

      end; //todo else error
    end; {SQL_DESC_TYPE}
    SQL_DESC_CONCISE_TYPE: //todo re-do!
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_concise_type:=SQLSMALLINT(Value);
        case dr.desc_concise_type of
          SQL_TYPE_DATE, SQL_TYPE_TIME, SQL_TYPE_TIME_WITH_TIMEZONE, SQL_TYPE_TIMESTAMP, SQL_TYPE_TIMESTAMP_WITH_TIMEZONE:
          begin
            dr.desc_type:=SQL_DATETIME;
            //todo should we call above code to set other fields etc?
            case dr.desc_concise_type of
              SQL_TYPE_DATE:                    dr.desc_datetime_interval_code:=SQL_CODE_DATE;
              SQL_TYPE_TIME,
              SQL_TYPE_TIME_WITH_TIMEZONE:      dr.desc_datetime_interval_code:=SQL_CODE_TIME;
              SQL_TYPE_TIMESTAMP,
              SQL_TYPE_TIMESTAMP_WITH_TIMEZONE: dr.desc_datetime_interval_code:=SQL_CODE_TIMESTAMP;
            end; {case}
          end;
          SQL_INTERVAL_YEAR..SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //we assume caller will set dr.desc_datetime_interval_code appropriately
            dr.desc_type:=SQL_INTERVAL; //todo should we call above code to set other fields etc?
            //todo set desc_datetime_interval_code!
          end;
        else
          dr.desc_type:=dr.desc_concise_type; //todo should we call above code to set other fields etc?
          dr.desc_datetime_interval_code:=0;
        end; {case}
      end; //todo else error
    end; {SQL_DESC_CONCISE_TYPE}
    SQL_DESC_DATETIME_INTERVAL_CODE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_datetime_interval_code:=SQLSMALLINT(Value);
      end; //todo else error
    end; {SQL_DESC_DATETIME_INTERVAL_CODE}
    SQL_DESC_DATETIME_INTERVAL_PRECISION:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_datetime_interval_precision:=SQLSMALLINT(Value);
      end; //todo else error
    end; {SQL_DESC_DATETIME_INTERVAL_PRECISION}

    SQL_DESC_OCTET_LENGTH:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_octet_length:=SQLINTEGER(Value);
      end; //todo else error
    end; {SQL_DESC_OCTET_LENGTH}
    SQL_DESC_OCTET_LENGTH_POINTER:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_octet_length_pointer:=Value; //deferred field
      end; //todo else error
    end; {SQL_DESC_OCTET_LENGTH_POINTER}
    SQL_DESC_INDICATOR_POINTER:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_indicator_pointer:=Value; //deferred field
      end; //todo else error
    end; {SQL_DESC_INDICATOR_POINTER}
    SQL_DESC_LENGTH:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_length:=SQLUINTEGER(Value);
      end; //todo else error
    end; {SQL_DESC_LENGTH}
    SQL_DESC_PRECISION:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_precision:=SQLSMALLINT(Value);
      end; //todo else error
    end; {SQL_DESC_PRECISION}
    SQL_DESC_SCALE:
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_scale:=SQLSMALLINT(Value);
      end; //todo else error
    end; {SQL_DESC_SCALE}
    SQL_DESC_DATA_POINTER: //ODBC=..DATA_PTR
    begin
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo if value=0 reset many fields => unbound - may also be able to dec(desc_count)?=>purgeRecords
        boundChange:=False;
        if (Value=nil) and (dr.desc_data_ptr<>nil) then boundChange:=True;
        if (Value<>nil) and (dr.desc_data_ptr=nil) then boundChange:=True;
        //todo consistency check on new Value
        if boundChange and (d.desc_type=SQL_ATTR_APP_ROW_DESC) then
        begin //we need to tell the server that our bound status has changed
          //note: if this errors, we wont have set the pointer - ok?

          //todo maybe in future this will be deferrable or not required
          //todo in future: better to track binding changes here and then
          //     send any changes before each SQLFetch. So most cases there will
          //     be no changes except for first Fetch call. 
          {call server setDescField}
          //todo Replace all AS with casts - speed
          //todo check d always is owned by a stmt - maybe connection? -if so we should not be here!
          //     -either check owner is a stmt or check this is THE implicit ARD...

          //todo in other places where owner could be stmt or dbc and we can still proceed,
          // then maybe we should use d.getDescDBC call/property!
          with ((d.owner as Tstmt).owner as Tdbc).Marshal do
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
            putSQLHSTMT((d.owner as Tstmt).ServerStatementHandle); //pass server statement ref (it has no concept of our desc's)
            putSQLSMALLINT(d.desc_type); //todo don't really need this since server only cares about us setting its ARD responsibilities (currently...)
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
              result:=SQL_ERROR;
              d.diagnostic.logError(ss08S01,fail,'',0,0); //todo check result
              exit;
            end;

            {Wait for response}
            if Read<>ok then
            begin
              result:=SQL_ERROR;
              d.diagnostic.logError(ssHYT00,fail,'',0,0); //todo check result
              exit;
            end;
            {Note: because we know these marshalled parameters all fit in a buffer together,
             and because the buffer has been read in total by the Read above because its size was known,
             we can omit the error result checking in the following get() calls = speed
            }
            getFunction(functionId);
            if functionId<>SQL_API_SQLSETDESCFIELD then
            begin
              result:=SQL_ERROR;
              d.diagnostic.logError(ss08S01,fail,'',0,0); //todo correct?pass details! //todo check result
              exit;
            end;
            getRETCODE(resultCode);
            result:=resultCode; //pass it on
            {$IFDEF DEBUGDETAIL}
            log(format('SQLSetDescField %d (ARD & DATA_PTR bound switch %p) returns %d',[recordNumber,Value,resultCode]));
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
                  seInvalidHandle:         begin result:=SQL_INVALID_HANDLE; resultState:=ssNA{todo need to skip logError}; end;
                  seNotPrepared:           resultState:=ssHY010;
                  seColumnNotBound:        resultState:=ssHY010; //todo ok?
                  seColumnAlreadyBound:    resultState:=ssHY010; //todo ok?
                  seUnknownFieldId:        resultState:=ssHY092; //todo ok???
                else
                  resultState:=ss08001; //todo more general failure needed/possible?
                end; {case}
                d.diagnostic.logError(resultState,resultErrCode,resultErrText,0,0); //todo too vague! todo correct?pass details! //todo check result
                if resultErrText<>nil then freeMem(resultErrText); //todo safe without length?
              end;
              exit;
            end;
          end; {with}
        end; {boundChange}
        {Ok set the pointer}
        //todo maybe (only if debugging?) we could test the pointer is valid somehow... if it is garbage we could crash the client!
        dr.desc_data_ptr:=Value; //deferred field
      end; //todo else error
    end; {SQL_DESC_DATA_POINTER}

    SQL_DESC_PARAMETER_TYPE:
    begin
      //todo for all options: reject if this is not applicable
      //todo reject if not IPD
      if d.GetRecord(recordNumber,dr,True)=ok then
      begin
        //todo check value is a valid type
        dr.desc_parameter_type:=SQLSMALLINT(Value);
      end; //todo else error
    end; {SQL_DESC_PARAMETER_TYPE}

    //ADO - ignore
    SQL_DESC_UNNAMED:
    begin
      //ADO trying to say a parameter is unnamed?
    end;

  else
    result:=SQL_ERROR;
    d.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLSetDescField called with unhandled type %d',[FieldIdentifier]));
    {$ENDIF}
    exit;
  end; {case}
end; {SQLSetDescField}
(*
///// SQLSetDescRec /////

RETCODE SQL_API SQLSetDescRec  (SQLHDESC arg0,
		 SQLSMALLINT arg1,
		 SQLSMALLINT arg2,
		 SQLSMALLINT arg3,
		 SQLINTEGER arg4,
		 SQLSMALLINT arg5,
		 SQLSMALLINT arg6,
		 SQLPOINTER arg7,
		 UNALIGNED SQLINTEGER * arg8,
		 UNALIGNED SQLINTEGER * arg9)
{
	log("SQLSetDescRec called\n");
	return(SQL_SUCCESS);
}
*)
///// SQLSetEnvAttr /////

function SQLSetEnvAttr  (EnvironmentHandle:SQLHENV;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER; //may be treated as integer depending on Attribute
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  e:Tenv;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetEnvAttr called %d %d %p %d',[EnvironmentHandle,Attribute,Value,StringLength]));
  {$ENDIF}

  {Check handle}
  e:=Tenv(EnvironmentHandle);
  if not(e is Tenv) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  e.diagnostic.clear;

  if e.state=E2 then //todo ?OR e.dbcList<>nil then //todo use finite states...
  begin
    result:=SQL_ERROR;
    e.diagnostic.logError(ssHY011,fail,'',0,0); //todo check result
    exit;
  end;

  //todo if c(default?).state=C3 then HY010

  case Attribute of
    SQL_ATTR_OUTPUT_NTS:
    begin
      if SQLINTEGER(Value)=SQL_TRUE then
        e.nullTermination:=SQL_TRUE
      else
        if SQLINTEGER(Value)=SQL_FALSE then
          e.nullTermination:=SQL_FALSE
          //todo ODBC should not set this to false & instead return error HYC00
        else
        begin
          result:=SQL_ERROR;
          e.diagnostic.logError(ssHY024,fail,'',0,0); //todo check result
          exit;
        end;
    end; {SQL_ATTR_OUTPUT_NTS}
    SQL_ATTR_ODBC_VERSION:
    begin
      if SQLINTEGER(Value)=SQL_OV_ODBC3 then
        e.odbcVersion:=SQL_OV_ODBC3  //this affects the behaviour/results elsewhere //todo
      else
        if SQLINTEGER(Value)=SQL_OV_ODBC2 then
          e.odbcVersion:=SQL_OV_ODBC2  //this affects the behaviour/results elsewhere //todo
          //todo maybe deny this option to avoid having to return old SQLSTATEs etc.? NO
          //- there is a not-implemented result we can return here instead
          //  but this would deny ODBC 2.x applications from using us - a large number!?  & there aren't many changes
        else
        begin
          result:=SQL_ERROR;
          e.diagnostic.logError(ssHY024,fail,'',0,0); //todo check result
          exit;
        end;
    end; {SQL_ATTR_ODBC_VERSION}
  else
    result:=SQL_ERROR;
    e.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end;

///// SQLSetStmtAttr /////

function SQLSetStmtAttr  (StatementHandle:SQLHSTMT;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
var
  s:Tstmt;
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLSetStmtAttr called %d %d %p %d',[StatementHandle,Attribute,Value,StringLength]));
  {$ENDIF}

  {Check handle}
  s:=Tstmt(StatementHandle);
  if not(s is Tstmt) then
  begin
    result:=SQL_INVALID_HANDLE;
    exit;
  end;

  s.diagnostic.clear; //todo really?

  //todo: keep in sync with getStmtAttr
  case Attribute of
    SQL_ATTR_CURSOR_HOLDABLE:
    begin
      //not supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_AUTOCOMMIT}
    SQL_ATTR_CURSOR_SENSITIVITY:
    begin
      //todo when we support sensitive cursors then
      //use SQLINTEGER(Value^) //=longint(0 / 1 / 2);
      //else for now not supported
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
    end; {SQL_ATTR_CURSOR_SENSITIVITY}
    SQL_ATTR_CURSOR_SCROLLABLE:
    begin
      //todo when we support scrollable cursors then
      //use SQLINTEGER(Value^) //=longint(SQL_NONSCROLLABLE / SQL_SCROLLABLE);
      //else for now not supported
      begin
        result:=SQL_ERROR;
        s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
        exit;
      end;
    end; {SQL_ATTR_CURSOR_SCROLLABLE}

    SQL_ATTR_APP_ROW_DESC:
    begin
      //todo when supported: checks:remove auto ard?:SQLINTEGER(s.ard):=SQLHDESC(Value^);
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_APP_ROW_DESC}
    SQL_ATTR_APP_PARAM_DESC:
    begin
      //todo when supported: checks:remove auto apd?:SQLINTEGER(s.apd):=SQLHDESC(Value^);
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_APP_PARAM_DESC}

    SQL_ATTR_METADATA_ID:
    begin
      //todo check value is valid
      s.metaDataId:=SQLINTEGER(Value^);
    end; {SQL_ATTR_METADATA_ID}

    {from ODBC}
    SQL_ATTR_ASYNC_ENABLE:
    begin
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_ASYNC_ENABLE}
    SQL_ATTR_CONCURRENCY:
    begin
      //ignore for ADO...
      result:=SQL_SUCCESS; //todo!
      if result=SQL_ERROR then exit;
      (*
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
      *)
    end; {SQL_ATTR_CONCURRENCY}
    SQL_ATTR_CURSOR_TYPE:
    begin
      //set not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_CURSOR_TYPE}
    SQL_ATTR_ENABLE_AUTO_IPD:
    begin
      //set not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_ENABLE_AUTO_IPD}

    SQL_ATTR_NOSCAN:
    begin
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_NOSCAN}

    {These needed for ADO, but not implemented yet}
    SQL_ATTR_PARAM_BIND_OFFSET_PTR:
    begin
      result:=SQL_SUCCESS; //todo!
      if result=SQL_ERROR then exit;
    end;
    SQL_ATTR_PARAM_BIND_TYPE:
    begin
      result:=SQL_SUCCESS; //todo!
      if result=SQL_ERROR then exit;
    end;
    SQL_ATTR_PARAMSET_SIZE:
    begin
      result:=SQL_SUCCESS; //todo!
      if result=SQL_ERROR then exit;
    end;
    SQL_ATTR_PARAMS_PROCESSED_PTR:
    begin
      result:=SQL_SUCCESS; //todo!
      if result=SQL_ERROR then exit;
    end;

    SQL_ATTR_ROW_ARRAY_SIZE:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ard),1,SQL_DESC_ARRAY_SIZE ,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_ARRAY_SIZE}
    SQL_ATTR_ROW_BIND_OFFSET_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ard),1,SQL_DESC_BIND_OFFSET_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_BIND_OFFSET_PTR}
    SQL_ATTR_ROW_BIND_TYPE:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ard),1,SQL_DESC_BIND_TYPE,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_BIND_TYPE}
    SQL_ATTR_ROW_OPERATION_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ard),1,SQL_DESC_ARRAY_STATUS_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_OPERATION_PTR}
    SQL_ATTR_ROW_STATUS_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ird),1,SQL_DESC_ARRAY_STATUS_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROW_STATUS_PTR}
    SQL_ATTR_ROWS_FETCHED_PTR:
    begin
      result:=SQLSetDescField(SQLHDESC(s.ird),1,SQL_DESC_ROWS_PROCESSED_PTR,Value,SQL_IS_POINTER);
      if result=SQL_ERROR then exit;
    end; {SQL_ATTR_ROWS_FETCHED_PTR}

    SQL_ATTR_USE_BOOKMARKS:
    begin
      //not yet supported
      result:=SQL_ERROR;
      s.diagnostic.logError(ssHYC00,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      exit;
    end; {SQL_ATTR_USE_BOOKMARKS}

    //issued by ADO... ignore for now
    SQL_ATTR_QUERY_TIMEOUT:
    begin
      //result:=SQL_ERROR;
      //s.diagnostic.logError(ss01S02,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      //exit;
    end;
    SQL_ATTR_MAX_ROWS:
    begin
      //result:=SQL_ERROR;
      //s.diagnostic.logError(ss01S02,fail,'',SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER); //todo check result
      //exit;
    end;
    //for ADO,currently ignored
    SQL_ATTR_RETRIEVE_DATA:
    begin
    end;
    SQL_ROWSET_SIZE: //?ADO?
    begin
    end;


  else
    result:=SQL_ERROR;
    s.diagnostic.logError(ssHY092,fail,'',0,0); //todo check result
    {$IFDEF DEBUGDETAILWARNING}
    log(format('SQLSetStmtAttr called with unhandled type %d',[Attribute]));
    {$ENDIF}
    exit;
  end; {case}

  result:=SQL_SUCCESS;
end; {SQLSetStmtAttr}

(*
///// SQLBulkOperations /////
//debug ADO
function 	SQLBulkOperations(
				StatementHandle:SQLHSTMT;
				Operation:SQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
begin
  {$IFDEF DEBUGDETAIL}
  log(format('SQLBulkOperations called %d %d',[StatementHandle,Operation]));
  {$ENDIF}
  result:=SQL_SUCCESS;
end; {SQLBulkOperations}
*)

end.

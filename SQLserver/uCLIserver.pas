unit uCLIserver;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}
{$I Defs.inc}

{.$DEFINE DEBUG_LOG} //jkoz only for local debug.
{$IFDEF Debug_Log}
{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2}  //show client SQL
{$ENDIF}

{CLI (=ODBC) server-side routines

 These definition headers are based on the ones in client/ODBC definitions.
 The parameters have been moved into the var section and they are
 unmarshalled at the start of the routines. So the functions have different
 fingerprints (but not really).

   some routines are client-side-only and so are never called here
   client-side-only input parameters aren't needed here, pass dummy values
   client-side-only output parameters aren't needed here, return dummy/no values

   and the remaining parameters are de-marshalled from the client

   plus, the ODBC.dll 'stdcall' is removed from the declarations by not defining SQL_API
     i.e. - we use Pascal calling conventions internally! (hooray!)

 So we retain the similarity of the function definitions to ease maintenance.

 //note: need a way to make the common HDBC confer the Tr/session info
 // - need a server-side AllocConnect & keep reference in client's HDBC structure for passing instead
 // - or maybe use Tr as HDBC directly?
      client: sqlAllocConnect     odbc: return hdbc.create

              sqlConnect                hdbc.serverHdbc:=sqlAllocConnect          server: return tr.create
                                        sqlConnect(hdbc.serverHdbc)                       tr.connect

              ...

              sqlDisconnect             sqlDisconnect(hdbc.serverHdbc)                    tr.disconnect
                                                                                          tr.free

              sqlFreeConnect            hdbc.free

 Protocol overview:
   all routines:
     send functionId followed by parameters
     reply with same functionId (i.e. echo) followed by result-code & any return information
                                                        - or sometimes return info & then result-code (if long data)

   connections start with a handshake which establishes client & server CLI protocol versions

 Notes:
   server columns start at 0, clients at 1: so server always returns column-ref+1.

 todo
   return varying fail codes so we can tell exactly where the function failed

}

interface  //JKOZ: indy Clean up?.

uses uConnectionMgr {for passing thread};

{Include the standard ODBC definitions}
{$define NO_FUNCTIONS}
{$include ODBC.INC}            {removed need for explicit path}

{note: passing thread gives us links to marshalBuffer, tr etc. etc.
  - is there a better way?
  - could make these functions part of the TCMthread class - but this would clog
    the class and I'd rather keep the unmarshalling separate from the thread handling... for now...
}
function handshake(th:TCMthread):integer;

function SQLConnect(th:TCMthread):integer;
function SQLDisconnect(th:TCMthread):integer;
function SQLPrepare(th:TCMthread):integer;
function SQLExecute(th:TCMthread):integer;
function SQLFetchScroll(th:TCMthread):integer;
function SQLGetData(th:TCMthread):integer;
function SQLSetDescField(th:TCMthread):integer;
function SQLGetInfo(th:TCMthread):integer;
function SQLCloseCursor(th:TCMthread):integer;
function SQLCancel(th:TCMthread):integer;
function SQLPutData(th:TCMthread):integer;
function SQLEndTran(th:TCMthread):integer;
function SQLAllocHandle(th:TCMthread):integer;
function SQLFreeHandle(th:TCMthread):integer;
function SQLSetConnectAttr(th:TCMthread):integer;
function SQLGetConnectAttr(th:TCMthread):integer;

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
     uMarshal {in '..\Odbc\uMarshal.pas'}, uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'},
     sysUtils, uGlobal, uGlobalDef,
     uParser, uProcessor{for executePlan}, uIterator, {for Fetch=plan.next}
     uTuple {for returning IRD info},
     uStmt {for returning IPD info},
     uRelation {for sysAuth catalog lookup},
     uTransaction {for SQLcancel to scan others},
     uSyntax {for ntCallRoutine const},
     uDatabase,uServer {for SQLconnect to another catalog}
     ;
     {removed need for explicit path for uMarshal & uMarshalGlobal}

const
  where='uCLIserver';

{Helper/mapping functions - todo put in another unit? - they need ODBC definitions
}
function dataTypeToSQLdataType(dt:TDataType):SQLSMALLINT;
const routine=':dataTypeToSQLdataType';
begin
  case dt of
    ctChar:     result:=SQL_CHAR;
    ctVarChar:  result:=SQL_VARCHAR;
    //ctBit:      result:=SQL_BIT; //Note: this is the ODBC bit, not the standard bit type //check this is ok - ODBC treats differently?
    //ctVarBit:   result:=SQL_BIT_VARYING;
    ctNumeric:  result:=SQL_NUMERIC;
    ctDecimal:  result:=SQL_DECIMAL;
    ctInteger:  result:=SQL_INTEGER;
    ctSmallInt: result:=SQL_SMALLINT;
    ctBigInt:   result:=SQL_BIGINT;
    ctFloat:    result:=SQL_FLOAT; //note: we never return SQL_DOUBLE or SQL_REAL - ok?
    ctDate:     result:=SQL_TYPE_DATE;
    ctTime:     result:=SQL_TYPE_TIME;
    ctTimeWithTimezone: result:=SQL_TYPE_TIME_WITH_TIMEZONE;
    ctTimestamp: result:=SQL_TYPE_TIMESTAMP;
    ctTimestampWithTimezone: result:=SQL_TYPE_TIMESTAMP_WITH_TIMEZONE;
    ctBlob:     result:=SQL_LONGVARBINARY; //todo remove:! SQL_VARBINARY;
    ctClob:     result:=SQL_LONGVARCHAR;
    //todo interval, when server can handle them!
  else
    {$IFDEF DEBUG_LOG}
    log.add('',where+routine,'unknown datatype',vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=0; //currently undefined by ODBC
  end; {case}
end;

function handshake(th:TCMthread):integer;
{
 Notes:
   Contains important notes about get & put error checking at server-side.
}
const routine=':handshake';
var
  clientVersion, clientCLItype:SQLUSMALLINT;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  {Note: this applies to all routines here...
   because we know these marshalled parameters all fit in a buffer together,
   and because the buffer has been read in total by the Read in the caller,
   we could omit the error result checking in the following get() calls = speed
   - currently we check every get() result at the server-side. This guarantees we
   never use garbaged input parameters, at a small speed expense.

   We do need to check some get() parameters in future: long parameter lists
   (and eventually long strings) could be spread over multiple buffers
   => get calls Read & so could error.

   Note+: this handshake routine now calls read because we only now know we are
          a CLI client and so should use the marshal buffer.
  }
  with th.marshal do
  begin
    if Read<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error reading CLI clientVersion',[nil]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;

    if getSQLUSMALLINT(clientVersion)<>ok then exit; //special version marker for initial protocol handshake
    if clientVersion>=0093 then
    begin
      if getSQLUSMALLINT(clientCLItype)<>ok then exit;
    end;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d',[clientVersion]),vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  {make a note of the clientVersion and type and reply with serverVersion}
  th.clientCLIversion:=clientVersion;
  th.clientCLItype:=clientCLItype;
  with th.marshal do
  begin
    clearToSend;
    {Note: this applies to all routines here...
     because we know these marshalled parameters all fit in a buffer together,
     and because the buffer has been cleared by the clearToSend above,
     we could omit the error result checking in the following put() calls = speed
     - currently we check every put() result at the server-side. This guarantees we
     never send garbaged output parameters, at a small speed expense.
     (although it's possible a buffer full has already been sent - what then?
      client should realise this & it's get() will fail...
      Note- whenever we 'if put...<>ok then exit'
      we should actually do 'if put<>ok then begin putAbort; exit; end;'
      to ensure we send an Abort signal if we've already sent something
      so that the client can re-synchronise instead of waiting forever...
      The Abort signal should be picked up by all Get routines to force the
      client to abandon with a comms error...
      (A better idea is to send the Abort signal from the uConnectionMgr.caller
       if one of these routines fails (i.e. we exited early => put failed)
      )

     We do need to check some put() parameters in future: long parameter lists
     (and eventually long strings) could be spread over multiple buffers
     => put calls Send & so could error.
    }
    if putFunction(SQL_API_handshake)<>ok then exit;
    if putSQLUSMALLINT(serverCLIversion)<>ok then exit;
    if th.clientCLIversion>=0093 then
    begin
      if putSQLPOINTER(@th.tr)<>ok then exit; //send the transaction address as future encryption key/validation
    end;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {handshake}

function SQLConnect(th:TCMthread):integer;
const routine=':SQLConnect';
var
  ConnectionHandle:SQLHDBC;
  ServerName:pUCHAR;
  NameLength1:SWORD;
  UserName:pUCHAR;
  NameLength2:SWORD;
  Authentication:pUCHAR;
  NameLength3:SWORD;
  newServerName:string;
  newDB:TDB;

  {Needed because we have no stmt yet}
  resultErrCode:SQLINTEGER;
  resultErrText:string;

  resultCode:RETCODE;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  //assert we have already handshaken - i.e. is clientCLIversion set?

  //assert we are not already connected - i.e. is authID<>0?
  //- client FSM should prevent this, but we should cope in a specified way if ever it happens...
  if th.tr.authID<>InvalidAuthId then
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('User is already connected as auth-id %d, continuing...',[th.tr.authId]),vAssertion); //note =>client protocol error
    {$ELSE}
    ;
    {$ENDIF}

  ServerName:=nil;
  UserName:=nil;
  Authentication:=nil;
  try
    result:=fail;
    with th.marshal do
    begin
      if getSQLHDBC(ConnectionHandle)<>ok then exit;
      if getpUCHAR_SWORD(ServerName,DYNAMIC_ALLOCATION,NameLength1)<>ok then exit;
      if getpUCHAR_SWORD(UserName,DYNAMIC_ALLOCATION,NameLength2)<>ok then exit;
      if getpUCHAR_SWORD(Authentication,DYNAMIC_ALLOCATION,NameLength3)<>ok then exit;
    end; {with}
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('%d %s %s',[ConnectionHandle,ServerName,UserName]),vDebugMedium);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}

    resultCode:=SQL_SUCCESS; //default
    resultErrCode:=seOk; resultErrText:=seOkText;

    //todo: make a note of the connectionHandle - we can at least use it for debugging/assertions
    //      and I think we may need it later...

    //todo check that the db Tr is (pre)connected to is = serverName, else re-pre-connect it now to serverName?
    // - currently we ignore the serverName!
    {We stay with the current server (thread is attached to it)
     but allow reconnection to another db via SERVER.CATALOG
     e.g. CONNECT TO 'thinksql.db1' ...
     currently ignore server prefix so can use CONNECT TO '.db1'}
    if pos('.',serverName)<>0 then
    begin //we have a server catalog specified so reconnect our transaction/connection to it
      newServerName:=copy(serverName,pos('.',serverName)+1,length(serverName));
      //(Ttransaction(stmt.owner).thread as TCMThread).dbServer.findDB(serverName);
      //todo add Ttransaction getServer method (via tcmthread)!
      if th.tr.db=nil then
      begin //without a valid db we won't find the server
        resultCode:=SQL_ERROR;
        resultErrCode:=seFail; resultErrText:=seFailText;
      end
      else
      begin
        newDB:=(th.tr.db.owner as TDBserver).findDB(newServerName); //assumes we're already connected to a db
        if newDB<>nil then
        begin
          {We must finish the current transaction to allow a new tran id to be allocated from the new db etc.}
          th.tr.Disconnect; //note: document/warn that we rollback here!!!
          th.tr.DisconnectFromDB;
          th.tr.ConnectToDB(newDB);
        end
        else
        begin
          resultCode:=SQL_ERROR;
          resultErrCode:=seUnknownCatalog; resultErrText:=seUnknownCatalogText;
        end;
      end;
    end
    else //no server catalog is specified, so connect to the primary one
    begin
      //todo assert (Ttransaction(st.owner).db.owner as TDBserver).getInitialConnectdb<>nil
      //todo assert serverName='' or server name!
      {We must finish the current transaction to allow a new tran id to be allocated from the new db etc.}
      newDB:=(th.tr.db.owner as TDBserver).getInitialConnectdb;
      th.tr.Disconnect; //note: document/warn that we rollback here!!!
      th.tr.DisconnectFromDB;
      th.tr.ConnectToDB(newDB);
    end;

    if resultCode=SQL_SUCCESS then
    begin
      {Note: we need to start a transaction before we can reference any auth tables etc.}
      if th.tr.tranRt.tranId=InvalidStampId.tranId then
      begin
        th.tr.Start;
        //no need to synch. stmt since we don't have one yet!
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,format('Auto-initiating transaction...',[nil]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
      end;

      {Check the username and password are valid & return success or fail}
      case th.tr.Connect(Username,Authentication) of
        ok:begin
            //Authorised & connected

            //I think we need to pass back the thread reference (can't remember why exactly...)
            //although don't we know the caller because they always come through this thread - maybe not in future...
            //the thread-ref will be used in future as the hdbc from the client
           end;
        -2:begin
            resultCode:=SQL_ERROR;
            resultErrCode:=seUnknownAuth; resultErrText:=seUnknownAuthText;
           end;
        -3:begin
            resultCode:=SQL_ERROR;
            //todo be extra secure: i.e. don't let on that user-id was found!: resultErrCode:=seUnknownAuth; resultErrText:=seUnknownAuthText;
            resultErrCode:=seWrongPassword; resultErrText:=seWrongPasswordText;
           end;
        -5:begin
            resultCode:=SQL_ERROR;
            resultErrCode:=seAuthLimitError; resultErrText:=seAuthLimitErrorText;
           end;
      else
        resultCode:=SQL_ERROR;
        resultErrCode:=seFail; resultErrText:=seFailText;
      end; {case}
    end;
    //else error connecting to server/catalog


    with th.marshal do
    begin
      clearToSend;
      if putFunction(SQL_API_SQLCONNECT)<>ok then exit;
      if putRETCODE(resultCode)<>ok then exit;
      {if error, then return error details: local-number, default-text}
      if resultCode=SQL_ERROR then
      begin
        {Note: we always send error count first, i.e. 1 (or 0), to allow for future stacking without protocol change}
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(resultErrCode)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
      end
      else
        if putSQLINTEGER(0)<>ok then exit;
      if Send<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
        {$ENDIF}
        //todo what now? try to report error to client? log in error table? kill connection? etc.?
        exit;
      end;
    end; {with}

    result:=ok;
  finally
    //note: ok to freemem without size? - dangerous?
    if ServerName<>nil then freeMem(ServerName);
    if UserName<>nil then freeMem(UserName);
    if Authentication<>nil then freeMem(Authentication);
  end;
end; {SQLConnect}

function SQLDisconnect(th:TCMthread):integer;
const routine=':SQLDisconnect';
var
  ConnectionHandle:SQLHDBC;

  resultCode:RETCODE;

  {Needed because not at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHDBC(ConnectionHandle)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d',[ConnectionHandle]),vDebugMedium);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  //assert we are not already disconnected
  //- client FSM should prevent this, but we should cope in a specified way if ever it happens...
  if not th.tr.connected then
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('User is already disconnected, continuing...',[nil]),vAssertion); //note =>client protocol error
    {$ELSE}
    ;
    {$ENDIF}

  //note: maybe we should initiate a rollback/commit from here?

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLDISCONNECT)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLDisconnect}


function SQLPrepare(th:TCMthread):integer;
const routine=':SQLPrepare';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;
  StatementText:pUCHAR;
  TextLength:SDWORD;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;

  resultSet:SQLUSMALLINT;
  i:colRef;
  temps:string;
  nextParam:TParamListPtr;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  StatementText:=nil;

  result:=fail;
  try
    with th.marshal do
    begin
      if getSQLHSTMT(StatementHandle)<>ok then exit;
      if getpUCHAR_SDWORD(StatementText,DYNAMIC_ALLOCATION,TextLength)<>ok then exit;
    end; {with}
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('%d',[StatementHandle]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}

    {$IFDEF DEBUGDETAIL2}
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('%s',[StatementText]),vDebugMedium);
    {$ENDIF}
    {$ENDIF}

    resultCode:=SQL_SUCCESS; //default
    resultSet:=SQL_FALSE;

    {Check handle} //note: this check may not be good enough when given garbage! - applies everywhere...
    //note: maybe we could avoid the exists search each time - if we could trust the client... or when we can catch access violations
    s:=Tstmt(StatementHandle);
    if th.tr.existsStmt(s)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError);
      {$ENDIF}
      resultCode:=SQL_INVALID_HANDLE;
      s:=nil; //prevent error stack return
    end
    else
    begin
      s.deleteErrorList; //clear error stack

      //note: need CASE to handle double prepare & control unprepare...

      if s.planActive then //note: is this test ok? good enough? - put here to handle prepare,execute(no resultSet),prepare
      begin
        {Close any existing plan}
        s.CloseCursor(1{=unprepare});
      end;

      {Prepare & set resultSet}
      if PrepareSQL(s,nil,StatementText)<>ok then
      begin
        resultCode:=SQL_ERROR;
      end;
      //todo catch exception here & return fail...?

      resultSet:=SQL_FALSE;
      //todo ensure Insert etc. don't have resultSet:=True (even though they have a plan activated)
      if s.resultSet then resultSet:=SQL_TRUE; //we have a valid iterator plan that will give a result set
      if (resultSet=SQL_TRUE) and (s.sroot.ptree=nil)
      {note: should allow stored-proc results, but need tuple.header etc. below! and ((s.sroot<>nil) and (s.sroot.nType<>ntCallRoutine))
             - actually cannot always determine until executed: e.g. nested calls
             so allow return of result set & its definition after sqlExecute:
                = change to ODBC driver?
      }
      then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Plan is active but no plan tree is available',[nil]),vAssertion);
        {$ENDIF}
        resultSet:=SQL_FALSE;
      end;
    end;

    with th.marshal do
    begin
      clearToSend;
      if putFunction(SQL_API_SQLPREPARE)<>ok then exit;
      if putRETCODE(resultCode)<>ok then exit;
      {if error, then return error details: local-number, default-text}
      if resultCode=SQL_ERROR then
      begin
        if s=nil then
        begin //invalid handle
          if putSQLINTEGER(1)<>ok then exit;
          if putSQLINTEGER(seInvalidHandle)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
        end
        else
        begin //return error stack  //todo use iterator to hide the details
          if putSQLINTEGER(s.errorCount)<>ok then exit;
          errNode:=s.errorList;
          while errNode<>nil do
          begin
            if putSQLINTEGER(errNode.code)<>ok then exit;
            if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
            errNode:=errNode.next;
          end;
          //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
        end;
      end
      else
        if putSQLINTEGER(0)<>ok then exit;

      if putSQLUSMALLINT(resultSet)<>ok then exit;     //does this have a result set? i.e. should client open a cursor?

      if resultSet=SQL_TRUE then
      begin //also return the tuple definition for the client's IRD
        with (s.sroot.ptree as TIterator).iTuple do
        begin
          if putSQLINTEGER(ColCount)<>ok then exit; //return this, even if we defer the column defs themselves?
          //note: the following response should be switchable (by client=statement option) to one of:
          //      1) the server sends back all column defs after prepare (=initial dev!)
          //      2) the client requests each column def after prepare
          // because we may select * => 200 columns, but we might only bind a couple
          // -although shouldn't the IRD contain all 200 anyway? - the spec is not clear,
          //  but sounds like the user can expect the IRD (including COUNT) to be filled after Prepare
          //Our switch still keeps the IRD, but it's populated on the server only, until the user
          //makes a request of it, which would involve network calls... better/faster?
          // - if we stick with the default, we use tuple definition memory on server & duplicate it
          //   on the client - but we don't really care about client memory here!
          {Now send the column definitions}
          i:=0;
          while i<=ColCount-1 do
          begin
            if putSQLSMALLINT(i+1)<>ok then exit; //note we send i+1 since client's columns start at 1 //note we send colRef not fColDef[i].id - that's for our storage use
            temps:=fColDef[i].name;
            if putpSQLCHAR_SWORD(pchar(temps),length(temps))<>ok then exit;
            if putSQLSMALLINT(dataTypeToSQLdataType(fColDef[i].datatype))<>ok then exit;
            if th.clientCLIversion>=0093 then
              {if }putSQLINTEGER(fColDef[i].width){<>ok then exit}
            else
              {if }putSQLSMALLINT(fColDef[i].width){<>ok then exit};
            if putSQLSMALLINT(fColDef[i].scale)<>ok then exit;
            //todo: discover if this column is nullable from sysConstraints!
            //         better to rely on INFO_SCHEMA.COLUMNS? but that involves a lot of overhead...
            if putSQLSMALLINT(SQL_TRUE)<>ok then exit; //note: defaults to nullable for now! no harm done, since will fail if client attempts to insert null

            //todo etc.?

            inc(i);
          end; {while}
        end; {with}
      end; {result set description}

      //also (always) return any parameter definitions for the client's IPD
      with s do
      begin
        if putSQLINTEGER(paramCount)<>ok then exit; //return this, even if 0 = no parameters (pretty common)
        //Note: these definitions may be ignored by the client if auto-populate-IPD switch is set to Off
        {Now send the parameter definitions}
        i:=0;
        nextParam:=paramList; //todo add interface to this & hide the structure!
        while i<=paramCount-1 do
        begin
          if nextParam=nil then
          begin //note: this assertion won't be needed when paramList structure is hidden
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Missing parameter definition, count=%d but list is empty at node %d',[paramCount,i]),vAssertion);
            {$ENDIF}
            exit; //abort
          end;
          //i+1 = idVal if the paramList is FIFO but it currently is LIFO (i.e. the list is reversed)
          // so we pass the actual idVal so the client's 1st param record number = our param with idVal=1
          // - this matters when the client passes us data during execute
          // - and how we match the passed param# to our paramList...
          //todo send paramType e.g. in/inout?...
          if putSQLSMALLINT(strToIntDef(nextParam.paramSnode.idVal,0))<>ok then exit; //note idVals start at 1 which matches client
          temps:=nextParam.paramSnode.idVal; //currently we don't use named parameters, so name=idVal -for future use
          if putpSQLCHAR_SWORD(pchar(temps),length(temps))<>ok then exit;
          if putSQLSMALLINT(dataTypeToSQLdataType(nextParam.paramSnode.dType))<>ok then exit;
          {Pass default width, scale and nulls for the type, since we can't determine these from the parser
           - or can we? - we probably can guess from nearby columns...}
          //note: improve these current guesses whatever we do...
          if th.clientCLIversion>=0093 then
            {if }putSQLINTEGER(1){<>ok then exit}
          else
            {if }putSQLSMALLINT(1){<>ok then exit};
          if putSQLSMALLINT(0)<>ok then exit;
          if putSQLSMALLINT(SQL_TRUE)<>ok then exit;
          //todo etc.?

          inc(i);
          nextParam:=nextParam.next; //traverse paramList //todo hide the structure!
        end; {while}
      end; {with}

      if Send<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
        {$ENDIF}
        //todo what now? try to report error to client? log in error table? kill connection? etc.?
        exit;
      end;
    end; {with}
    result:=ok;
  finally
    if StatementText<>nil then freeMem(StatementText); //size was dynamic //note: ok/dangerous to free without size?
  end; {try}
end; {SQLPrepare}

function SQLExecute(th:TCMthread):integer;
const routine=':SQLExecute';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;

  nextParam:TParamListPtr;
  rowCount, row:SQLUINTEGER;  //todo: rename to paramRow?
  i, colCount:SQLINTEGER;        //todo: rename to param?
  rn:SQLSMALLINT;
  tempNull:SQLSMALLINT;
  tempps:pchar;
  tempptr:SQLPOINTER;
  tempsdw:SDWORD;

  errNode:TErrorNodePtr;

  lateResultSet:SQLUSMALLINT;
  temps:string;

  resultCode:RETCODE;
  resultRowCount:SQLINTEGER;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit; //this should now be our statement handle (i.e. plan handle)

    resultCode:=SQL_SUCCESS; //default

    {Check handle}
    s:=Tstmt(StatementHandle);
    if th.tr.existsStmt(s)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
      {$ENDIF}
      resultCode:=SQL_INVALID_HANDLE;
      lateResultSet:=SQL_FALSE; //compiler warned
      s:=nil; //prevent error stack return
    end
    else
    begin
      s.deleteErrorList; //clear error stack

      //note: need CASE to handle double execute & control unprepare?...
      if s.sroot=nil then
      begin //not prepared
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Error no existing prepared plan',[nil]),vDebugMedium);
        {$ENDIF}
        //todo return error - although client FSM should prevent this!
        resultCode:=SQL_ERROR;
        s.addError(seNotPrepared,seNotPreparedText);
      end;

      {Receive paramCount and param data
       - we load this data straight into the designated ntParam nodes of this plan's syntax tree
       - saves allocating extra desc areas attached to the server.stmt
        - although we could easily add a field to the TparamList structure
       - no down-side? (except syntax tree is less shareable, but so what?)
         - it would be anyway, since we'd optimise the expression code to pull the param value into the tree once
         - else slower expression evaluation (copy data each time) but more reusable syntax tree...

       Note: this routine can also be called from SQLParamData, in which case param rowcount=1,colcount=0
       i.e. no param data is passed - will have already been done during prior (SQLExecute) call
      }
      {Read param row count}
      getSQLUINTEGER(rowCount);
      //note: check rowCount=array_size - no reason why not... could assume? - but dangerous

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('SQLExecute receives %d parameter rows',[rowCount]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      for row:=1 to rowCount do
      begin
        {Now get the col count & data for this param row}
        getSQLINTEGER(colCount);
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('SQLExecute receives %d parameter data',[colCount]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        //todo assert paramCount<=colCount ?

        i:=0;
        while i<=colCount-1 do
        begin
          {Note: we read all the sent parameter data value, even though we may need less} //note: not most efficient way? - make client send correct amount!
          if getSQLSMALLINT(rn)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Failed reading parameter reference %d',[i]),vError);
            {$ENDIF}
            exit; //todo resync
          end;
          // we receive the actual idVal so the client's param record number X = our param with idVal=X
          {Find the matching parameter} //note: improve - use fast method of paramList - speed
          nextParam:=s.paramList; //todo add interface to this & hide the structure!
          while nextParam<>nil do
          begin
            //note: only if paramType=in/inout?...
            if strToIntDef(nextParam.paramSnode.idVal,0)=rn then break;
            nextParam:=nextParam.next;
          end;
          if nextParam=nil then
          begin //note: this assertion won't be needed when paramList structure is hidden
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Missing parameter definition %d, count=%d but list is empty at node %d',[rn,s.paramCount,i]),vAssertion);
            {$ENDIF}
            //added if not null code below...
          end;

          //Note: since the client has probably set the IPD.datatype, we
          // should send/receive it here to set the parameter dtype properly
          // - assuming the client knows better than us, the server???

          begin
            begin
              {Get the null flag}
              if getSQLSMALLINT(tempNull)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(s.who,where+routine,format('Failed reading parameter null indicator %d',[i]),vError);
                {$ENDIF}
                exit; //abort
              end;
              if tempNull=SQL_TRUE then
              begin
                if nextParam<>nil then nextParam.paramSnode.nullval:=True;
                if nextParam<>nil then nextParam.paramSnode.strVal:=''; //needed to remove '?' default, else executePlan thinks we still need more
              end
              else
              begin
                //Note: we only get length+data if not null
                //we assume client has formatted the data correctly
                begin //no conversion required
                  //note: we don't add \0 here - assume client has done it if necessary
                  try
                    if getpDataSDWORD(tempptr,DYNAMIC_ALLOCATION,tempsdw)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(s.who,where+routine,format('Failed reading parameter data %d',[i]),vError);
                      {$ENDIF}
                      exit; //abort
                    end;
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(s.who,where+routine,format('read parameter %d data (length %d): %s',[s.need_param,tempsdw,pchar(tempptr)]),vDebugLow); //todo debug only - remove
                    {$ENDIF}
                    {$ENDIF}
                    if tempsdw=0 then
                    begin
                      //SQL_DATA_AT_EXEC... leave as ? until later
                      //todo assert tempps=nil
                      {$IFDEF DEBUGDETAIL}
                      {$IFDEF DEBUG_LOG}
                      log.add(s.who,where+routine,format('read SQL_DATA_AT_EXEC parameter %d data: nil (%d)',[rn,tempsdw]),vDebugLow); //todo debug only - remove
                      {$ENDIF}
                      {$ENDIF}
                    end
                    else
                    begin
                      if nextParam<>nil then
                      begin

                        //note: only if paramType=in/inout?...
                        if nextParam.paramSnode.strVal='?' then //todo replace '?' with constant/better test
                        begin
                          setLength(nextParam.paramSnode.strVal,tempsdw);
                          move(tempptr^,pchar(nextParam.paramSnode.strVal)^,tempsdw);
                          if (tempsdw<>(length(pchar(nextParam.paramSnode.strVal))+1)) or (tempsdw>300{todo max strlen}) then nextParam.paramSnode.numVal:=tempsdw; //store length in case blob contains #0
                          nextParam.paramSnode.nullval:=False;
                        end;
                      end;
                      //else ignore: note: better to error?!

                    end;
                  finally
                    if tempptr<>nil then freeMem(tempptr); //note: ok with no size //todo explicitly initialise to nil beforehand!
                  end; {try}
                end;

                //tempsdw could be 1 more than length (\0)
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  if nextParam<>nil then log.add(s.who,where+routine,format('parameter %d value after update: %s',[rn,nextParam.paramSnode.strVal]),vDebugLow); //todo debug only - remove
                  {$ENDIF}
                  {$ENDIF}
              end;

              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(s.who,where+routine,format('SQLExecute read parameter %d data: %d bytes, null=%d',[rn,tempsdw,tempNull]),vDebugLow); //todo debug only - remove
              {$ENDIF}
              {$ENDIF}
            end;
          end;

          inc(i);
        end; {while}
      end; {for row}

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('%d',[StatementHandle]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      {Note: this doesn't currently create the result-set - we do this on-the-fly via Fetch
       It does activate the plan == open the cursor
      }
      {We remember the first (if any) missing parameter id for future SQLputData/SQLparamData}
      s.need_param:=ExecutePlan(s,resultRowCount);
      if s.need_param<>ok then
      begin
        if s.need_param>ok then
        begin
          resultCode:=SQL_NEED_DATA;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(s.who,where+routine,format('Aborting execution',[nil]),vDebugMedium);
          {$ENDIF}
          resultCode:=SQL_ERROR; //will return error details to client
        end;
      end;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('returning resultCode=%d, rowCount=%d',[resultCode,resultRowCount]),vDebugMedium);
      {$ENDIF}
      {$ENDIF}

      {Return (late)resultSet now if this is a return cursor: couldn't do this at prepare stage
       else client uses original prepare result}
      lateResultSet:=SQL_FALSE;
      //note: we should ensure Insert etc. don't have resultSet:=True (even though they have a plan activated)
      if s.resultSet and (s.cursorName<>'') then lateResultSet:=SQL_TRUE; //we now have a valid iterator plan that will give a result set
      if (lateResultSet=SQL_TRUE) and (s.sroot.ptree=nil) then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Plan is active but no plan tree is available',[nil]),vAssertion);
        {$ENDIF}
        lateResultSet:=SQL_FALSE;
      end;
    end;
  end; {with}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLEXECUTE)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if putSQLINTEGER(resultRowCount)<>ok then exit; //only valid for insert/update/delete

    if th.clientCLIversion>=0092 then
    begin
      {Now return any late (post-prepare) resultSet definition, i.e. for stored procedure return cursors
       False here doesn't mean we have no result set, it means the client should use the details from SQLprepare}
      if putSQLUSMALLINT(lateResultSet)<>ok then exit;     //does this have a result set? i.e. should client open a cursor?

      if lateResultSet=SQL_TRUE then //Note: this code is copied from SQLprepare
      begin //also return the tuple definition for the client's IRD
        with (s.sroot.ptree as TIterator).iTuple do
        begin
          if putSQLINTEGER(ColCount)<>ok then exit; //return this, even if we defer the column defs themselves?
          //note: the following response should be switchable (by client=statement option) to one of:
          //      1) the server sends back all column defs after prepare (=initial dev!)
          //      2) the client requests each column def after prepare
          // because we may select * => 200 columns, but we might only bind a couple
          // -although shouldn't the IRD contain all 200 anyway? - the spec is not clear,
          //  but sounds like the user can expect the IRD (including COUNT) to be filled after Prepare
          //Our switch still keeps the IRD, but it's populated on the server only, until the user
          //makes a request of it, which would involve network calls... better/faster?
          // - if we stick with the default, we use tuple definition memory on server & duplicate it
          //   on the client - but we don't really care about client memory here!
          {Now send the column definitions}
          i:=0;
          while i<=ColCount-1 do
          begin
            if putSQLSMALLINT(i+1)<>ok then exit; //note we send i+1 since client's columns start at 1 //note we send colRef not fColDef[i].id - that's for our storage use
            temps:=fColDef[i].name;
            if putpSQLCHAR_SWORD(pchar(temps),length(temps))<>ok then exit;
            if putSQLSMALLINT(dataTypeToSQLdataType(fColDef[i].datatype))<>ok then exit;
            if th.clientCLIversion>=0093 then
              {if }putSQLINTEGER(fColDef[i].width){<>ok then exit}
            else
              {if }putSQLSMALLINT(fColDef[i].width){<>ok then exit};
            if putSQLSMALLINT(fColDef[i].scale)<>ok then exit;
            //note: discover if this column is nullable from sysConstraints!
            //              better to rely on INFO_SCHEMA.COLUMNS? but that involves a lot of overhead...
            if putSQLSMALLINT(SQL_TRUE)<>ok then exit; //note: defaults to nullable for now! no harm done, since will fail if client attempts to insert null

            //todo etc.?

            inc(i);
          end; {while}
        end; {with}
      end; {late result set description}
    end;
    //else old client cannot handle this

    {If we need param data, return the param reference to the client driver}
    if resultCode=SQL_NEED_DATA then
      if putSQLSMALLINT(s.need_param)<>ok then exit;

    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLExecute}

function SQLFetchScroll(th:TCMthread):integer;
{
 note: needs to be fast
}
const routine=':SQLFetchScroll';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;
  FetchOrientation:SQLSMALLINT;
  FetchOffset:SQLINTEGER;

  noRow:boolean;
  sqlRowStatus:SQLUSMALLINT;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;

  row:integer;
  i:colRef;
  boundSent:colRef;
  resP:pointer; //=pUCHAR;
  resLen:colOffset; //=SDWORD;
  resNull:boolean; //=SQLSMALLINT;
  bv,bvData:Tblob;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit;
    if getSQLSMALLINT(FetchOrientation)<>ok then exit;
    if getSQLINTEGER(FetchOffset)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d %d',[StatementHandle,FetchOrientation,FetchOffset]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default

  {Again, we assume the caller controls the call sequence
   - this may not be safe enough...
   we do assert the basics, e.g. we have a plan, it's been prepared and executed etc.
   -e.g. planActive=True => cursor open
        - ***applies to all CLI server routines... e.g. can't (re)execute while cursor still open etc.
  }
  {Check handle}
  s:=Tstmt(StatementHandle);
  if th.tr.existsStmt(s)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE;
    s:=nil; //prevent error stack return
  end
  else
  begin
    s.deleteErrorList; //clear error stack

    {Free any previously referenced blob buffer (from SQLgetData)}
    if (th.marshalColumnNumber<>0) then
    begin //this column is not the one we've just cached for chunking so free our buffer
      (s.sroot.ptree as TIterator).iTuple.freeBlobData(th.marshalColumnBlobData);
      th.marshalColumnNumber:=0; //invalid
      th.marshalColumnBlobData.len:=0;
      th.marshalColumnBlobData.rid.pid:=InvalidPageId;
      th.marshalColumnBlobData.rid.sid:=InvalidSlotId;
      th.marshalColumnBlobDataOffset:=0;
    end;

    //note: need CASE to handle double execute & control unprepare?...
    if s.sroot=nil then
    begin //not prepared
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error no existing prepared plan',[nil]),vDebugMedium);
      {$ENDIF}
      //todo return error - although client FSM should prevent this!
      resultCode:=SQL_ERROR;
      s.addError(seNotPrepared,seNotPreparedText);
    end;

    if not s.planActive then
    begin //not executed
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error no existing executed plan/cursor',[nil]),vDebugMedium);
      {$ENDIF}
      //todo return error - although client FSM should prevent this!
      resultCode:=SQL_ERROR;
      s.addError(seNoResultSet,seNoResultSetText);
    end;
  end;

  {Since we may be sending buffer(s) full of info, we need to start with the functionId now
   - we'll add the resultCode to the end after any data}
  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLFETCHSCROLL)<>ok then exit;
  end;

  if th.tr.existsStmt(s)<>ok then
  begin
    {Return 0 rows to keep protocol}
    //note: maybe we must return 1 & dummy row status flag etc.! check client deals sensibly with 0 row result-set!
    if th.marshal.putSQLUINTEGER(0)<>ok then exit;
  end
  else
  begin
    {We return:
        row count
          col count
             col1 null
             if col1 is not null, col1 data
             ...
          row status
          ...
    }
    sqlRowStatus:=SQL_ROW_SUCCESS; //default to keep compiler quiet (the only risky check is after checking rowSetSize=1, but compiler isn't clever enough to know that this guarantees it's been set)

    {Return the number of rows - even if we have less left, we still send dummy rows to pad}
    if th.marshal.putSQLUINTEGER(s.rowsetSize)<>ok then exit;
    {For each row, build the return buffer}
    for row:=1 to s.rowsetSize do
    begin
      noRow:=True; //todo maybe could use sqlRowStatus=SQL_NO_ROW/SQL_ROW_ERROR(sometimes!) instead of this flag?
      sqlRowStatus:=SQL_ROW_SUCCESS; //default
      //note: ensure that if we error on a row below, that we pad enough items into the buffer to allow client to keep in sync!
      // = easier than sending row result 1st...

      {Have we another row of data?}
      if not s.noMore then
      begin
        //note: remove As & use cast - speed - but is it worth it? I suppose we could check the type once after execution instead...
        if (s.sroot.ptree as TIterator).next(s.noMore)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(s.who,where+routine,format('Aborting execution',[nil]),vDebugMedium);
          {$ENDIF}
          sqlRowStatus:=SQL_ROW_ERROR;
          resultCode:=SQL_ERROR; //note: remove?! - check with spec! we don't return any error details from here-ok?
          //clearify: this or exit: resultCode:=SQL_SUCCESS_WITH_INFO;
          //- ensure caller aborts future fetches if it receives this SQL_ERROR - check spec.
          //for now, prevent access violation below:
          s.noMore:=True; //todo too crude? but works!
          //todo should be more severe! return critical error to client...
        end;

        //todo: if still not noMore then pack the resulting tuple into the result buffer
        if not s.noMore then
        begin
          with th.marshal do
          begin
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Returning %d bound column(s)',[s.ColBoundCount]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
            if putSQLINTEGER(s.ColBoundCount)<>ok then exit;
            noRow:=False; //we've returned a real row
            {Now send the column result data}
            i:=0;
            boundSent:=0; //count how many we send = cross-check
            while i<=(s.sroot.ptree as TIterator).iTuple.ColCount-1 do
            begin
              if (i<s.colBound.size) and (s.colBound.bits[i]) then //assumes short-circuit
              begin //this column was bound
                if putSQLSMALLINT(i+1)<>ok then exit; //note: we send i+1 because client columns start at 1 //note we send colRef not fColDef[i].id - that's for our storage use
                if (s.sroot.ptree as TIterator).iTuple.fColDef[i].dataType in [ctBlob,ctClob] then
                begin //indirect blob data //todo in future use cached swizzling & use getDataPointer for blobs (to avoid try finally & possible re-allocation here) -  although likely to only be pulled here & best to forget big blobs asap...
                  (s.sroot.ptree as TIterator).iTuple.GetBlob(i,bv,resNull);
                  if not resNull then
                    try
                      if (s.sroot.ptree as TIterator).iTuple.copyBlobData(s,bv,bvData)>=ok then
                      begin
                        if putSQLSMALLINT(SQL_FALSE)<>ok then exit;
                        //Note: we only send the length+data if not null
                        //Note: we don't try to send in manageable (marshalBufSize?) chunks here: use SQLgetData for that
                        //todo: so if this is too large for buffer, make sure we truncate rather than crash!
                          if putpDataSDWORD(pointer(bvData.rid.pid),bvData.Len)<>ok then exit;
                        //todo etc.?
                        inc(boundSent);
                      end
                      else
                      begin
                        //should never happen
                        {$IFDEF DEBUG_LOG}
                        log.add(s.who,where+routine,format('Failed reading blob data pointer for server column %d',[i]),vDebugError);
                        {$ENDIF}
                        sqlRowStatus:=SQL_ROW_ERROR;
                        //todo put dummy data to pad
                        resultCode:=SQL_SUCCESS_WITH_INFO;
                      end;
                    finally
                      (s.sroot.ptree as TIterator).iTuple.freeBlobData(bvData);
                    end {try}
                  else //null
                  begin
                    if putSQLSMALLINT(SQL_TRUE)<>ok then exit;
                    inc(boundSent);
                  end;
                end
                else
                begin //raw record data
                  if (s.sroot.ptree as TIterator).iTuple.GetDataPointer(i,resP,resLen,resNull)=ok then
                  begin
                    if resNull then
                    begin
                      if putSQLSMALLINT(SQL_TRUE)<>ok then exit;
                    end
                    else
                    begin
                      if putSQLSMALLINT(SQL_FALSE)<>ok then exit;
                      //Note: we only send the length+data if not null
                      if putpDataSDWORD(resP,resLen)<>ok then exit;
                    end;
                    //todo etc.?
                    inc(boundSent);
                  end
                  else
                  begin
                    //should never happen
                    {$IFDEF DEBUG_LOG}
                    log.add(s.who,where+routine,format('Failed reading data pointer for server column %d',[i]),vDebugError);
                    {$ENDIF}
                    sqlRowStatus:=SQL_ROW_ERROR;
                    //todo put dummy data to pad
                    resultCode:=SQL_SUCCESS_WITH_INFO;
                  end;
                end;
              end;

              inc(i);
            end; {while}
            if boundSent<>s.ColBoundCount then
            begin
              //problem! - should never happen! - unless data pointer failed above!
              //todo: send dummy data (with colRef=-1?) to keep client in sync. (but not happy!)
              {$IFDEF DEBUG_LOG}
              log.add(s.who,where+routine,format('Only %d bound columns returned out of %d expected',[boundSent,s.ColBoundCount]),vDebugError);
              {$ENDIF}
              sqlRowStatus:=SQL_ROW_ERROR;
              resultCode:=SQL_SUCCESS_WITH_INFO;
            end;
          end; {with}

          // similar switch for fetch data:
          //      1) client tells server as each column is bound, server makes a note (=initial dev!)
          //         server then sends all bound col data after fetch
          //      3) client tells server which columns are bound at fetch-time
          //         server then sends all bound col data after fetch
          //         -but big overhead, unless we have a 'same as last-time default'?
          //
          //      best if client sends bound column list in a chunk at any time or just-in-time
          //      e.g. bind1,bind2,bind3,prepare=>server-bind(1,2,3),prepare
          //           bind5,bind6,execute=>server-bind(5,6),execute
          //           bind8,bind9,unbind2,fetch=>server-bind(8,9,-2),fetch
          //      so client needs to batch bindings & send changes before retrievals
          //
          //      -maybe for now, easiest to server-bind immediately
        end
        else
          if sqlRowStatus=SQL_ROW_SUCCESS then sqlRowStatus:=SQL_ROW_NOROW; //i.e. only if not already set to error
      end
      else
        sqlRowStatus:=SQL_ROW_NOROW;

      if noRow then //need to add a dummy row (0 columns) to keep client in-sync.
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Returning %d bound column(s)',[s.ColBoundCount]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        {We must always return a column count, even if it's 0}
        if th.marshal.putSQLINTEGER(0)<>ok then exit;
      end;
      {Now add row status flag}
      if th.marshal.putSQLUSMALLINT(sqlRowStatus)<>ok then exit;
      {Will the entire rowset be empty?}
      if (row=1) and (sqlRowStatus=SQL_ROW_NOROW) then resultCode:=SQL_NO_DATA;
    end; {for row}

    {If we had an error & our row-set size=1 then everything is an error}
    if (s.rowsetSize=1) and (sqlRowStatus=SQL_ROW_ERROR) then
    begin
      resultCode:=SQL_ERROR;
      s.addError(seFail,seFailText); //note: general error ok?
    end;
    //else we have multiple rows, so leave resultCode as success or success with info...
  end;

  with th.marshal do
  begin
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLFetchScroll}

function SQLGetData(th:TCMthread):integer;
{
 note: needs to be fast
}
const routine=':SQLGetData';
var
  StatementHandle:SQLHSTMT;
  ColumnNumber:SQLSMALLINT;
  BufferSize:SQLUINTEGER;
  ReturnSize:SDWORD;
  s:Tstmt;

  noRow:boolean;
  sqlRowStatus:SQLUSMALLINT;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;

  row:integer;
  i:colRef;
  boundSent:colRef;
  resP:pointer; //=pUCHAR;
  resLen:colOffset; //=SDWORD;
  resNull:boolean; //=SQLSMALLINT;
  bv,bvData:Tblob;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit;
    if getSQLSMALLINT(ColumnNumber)<>ok then exit;
    if th.clientCLIversion>=0093 then
      {if }getSQLUINTEGER(BufferSize){<>ok then exit} //todo assert BufferSize<=marshalBufSize-sizeof(BufferSize)!
    else //default which restricts blob size since caller may be trying to get more...
      BufferSize:=marshalBufSize-sizeof(BufferSize);
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d %d',[StatementHandle,ColumnNumber,BufferSize]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default

  {Again, we assume the caller controls the call sequence
   - this may not be safe enough...
   we do assert the basics, e.g. we have a plan, it's been prepared and executed etc.
   -e.g. planActive=True => cursor open
        - ***applies to all CLI server routines... e.g. can't (re)execute while cursor still open etc.
  }
  {Check handle}
  s:=Tstmt(StatementHandle);
  if th.tr.existsStmt(s)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE;
    s:=nil; //prevent error stack return
  end
  else
  begin
    s.deleteErrorList; //clear error stack

    //note: need CASE to handle double execute & control unprepare?...
    if s.sroot=nil then
    begin //not prepared
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error no existing prepared plan',[nil]),vDebugMedium);
      {$ENDIF}
      //todo return error - although client FSM should prevent this!
      resultCode:=SQL_ERROR;
      s.addError(seNotPrepared,seNotPreparedText);
    end;

    if not s.planActive then
    begin //not executed
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error no existing executed plan/cursor',[nil]),vDebugMedium);
      {$ENDIF}
      //todo return error - although client FSM should prevent this!
      resultCode:=SQL_ERROR;
      s.addError(seNoResultSet,seNoResultSetText);
    end;
  end;

  {Since we may be sending buffer(s) full of info, we need to start with the functionId now
   - we'll add the resultCode to the end after any data}
  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLGETDATA)<>ok then exit;
  end;

  if th.tr.existsStmt(s)<>ok then
  begin
    {Return 0 rows to keep protocol}
    //todo: maybe we must return 1 & dummy row status flag etc.! check client deals sensibly with 0 row result-set!
    if th.marshal.putSQLUINTEGER(0)<>ok then exit;
  end
  else
  begin
    {Even though we currently only send 1 column of 1 row, we still return:
        row count
          col count
             col1 null
             if col1 is not null, col1 data
             ...
          row status
          ...
     as per the SQLFetchScroll protocol - may help in future?
    }
    sqlRowStatus:=SQL_ROW_SUCCESS; //default to keep compiler quiet (the only risky check is after checking rowSetSize=1, but compiler isn't clever enough to know that this guarantees it's been set)

    {Return the number of rows - even if we have less left, we still send dummy rows to pad}
    if th.marshal.putSQLUINTEGER(1)<>ok then exit;
    {For each row, build the return buffer}
    for row:=1 to 1 do
    begin
      noRow:=True; //todo maybe could use sqlRowStatus=SQL_NO_ROW/SQL_ROW_ERROR(sometimes!) instead of this flag?
      sqlRowStatus:=SQL_ROW_SUCCESS; //default
      //todo ensure: if we error on a row below, that we pad enough items into the buffer to allow client to keep in sync!
      // = easier than sending row result 1st...

      {We use the current/last fetched row of data, but we should still check if it's valid}
      if not s.noMore then
      begin
        //note: remove As & use cast - speed - but is it worth it? I suppose we could check the type once after execution instead...
        {pack the specified column of the tuple into the result buffer}
        with th.marshal do
        begin
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(s.who,where+routine,format('Returning 1 column',[nil]),vDebugLow);
          {$ENDIF}
          {$ENDIF}
          if putSQLINTEGER(1)<>ok then exit;
          noRow:=False; //we've returned a real row
          {Now send the column result data}
          i:=ColumnNumber-1;
          boundSent:=0; //count how many we send = cross-check
          if (ColumnNumber>0) and (ColumnNumber<=(s.sroot.ptree as TIterator).iTuple.ColCount) then
          begin
            if putSQLSMALLINT(i+1)<>ok then exit; //note: we send i+1 because client columns start at 1 //note we send colRef not fColDef[i].id - that's for our storage use
            //todo:  if getData has just been called for this columnNumber, then return the next chunk of data
            //  i.e. pass in the client's buffer length
            //       if this is a blob, keep memory until another column is called or next row etc.
            //       return only enough bytes to fill the client's buffer
            //       if this is a blob, remember where we get to & continue from there on the next call for that column
            //       - this chunking could apply to char/varchar etc, so maybe pass offset to getDataPointer (or better to add offset to putpDataSDWORD)

            {Free any previously referenced blob buffer}
            if (th.marshalColumnNumber<>0) and (ColumnNumber<>th.marshalColumnNumber) then
            begin //this column is not the one we've just cached for chunking so free our buffer
              (s.sroot.ptree as TIterator).iTuple.freeBlobData(th.marshalColumnBlobData);
              th.marshalColumnNumber:=0; //invalid
              th.marshalColumnBlobData.len:=0;
              th.marshalColumnBlobData.rid.pid:=InvalidPageId;
              th.marshalColumnBlobData.rid.sid:=InvalidSlotId;
              th.marshalColumnBlobDataOffset:=0;
            end;

            if (s.sroot.ptree as TIterator).iTuple.fColDef[i].dataType in [ctBlob,ctClob] then
            begin //indirect blob data //todo in future use cached swizzling & use getDataPointer for blobs (to avoid try finally & possible re-allocation here) -  although likely to only be pulled here & best to forget big blobs asap...
              (s.sroot.ptree as TIterator).iTuple.GetBlob(i,bv,resNull); //note: assumes null=>client doesn't call again for same column number
                                                                         //note: we re-get the blob for each chunk (no harm, but no real need since we have marshalColumnBlobData)
              if not resNull then
                begin
                  {If we don't already have a buffer for this blob, get one now (to allow repeated calls for chunking)}
                  if (th.marshalColumnNumber=0) then
                  begin
                    th.marshalColumnNumber:=ColumnNumber;
                    if (s.sroot.ptree as TIterator).iTuple.copyBlobData(s,bv,th.marshalColumnBlobData)<ok then
                    begin
                      //should never happen
                      {$IFDEF DEBUG_LOG}
                      log.add(s.who,where+routine,format('Failed reading blob data pointer for server column %d',[i]),vDebugError);
                      {$ENDIF}
                      resultCode:=SQL_SUCCESS_WITH_INFO;
                      //todo put dummy data to pad //done below...?
                    end;
                    th.marshalColumnBlobDataOffset:=0; //start at 0
                  end;

                  ReturnSize:=th.marshalColumnBlobData.len-th.marshalColumnBlobDataOffset; //ideally return all that's left
                  if ReturnSize>BufferSize then
                  begin //unless client has set a smaller chunk-size limit
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(s.who,where+routine,format('Returning %d bytes of truncated blob data from offset %d (total size=%d) for server column %d to fit client buffer',[BufferSize,th.marshalColumnBlobDataOffset,th.marshalColumnBlobData.len,i]),vDebugMedium);
                    {$ENDIF}
                    {$ENDIF}
                    ReturnSize:=BufferSize; //in which case we return just that & defer the rest for the next call(s)
                    sqlRowStatus:=SQL_ROW_SUCCESS_WITH_INFO;
                    resultCode:=SQL_SUCCESS_WITH_INFO;
                  end;
                  if ReturnSize=0 then
                  begin //called too many times, or 0 bytes
                    sqlRowStatus:=SQL_ROW_NOROW;
                    //=>below: resultCode:=SQL_NO_DATA;
                  end;

                  begin
                    if putSQLSMALLINT(SQL_FALSE)<>ok then exit;
                    //Note: we only send the length+data if not null
                    if putpDataSDWORD(pointer(pchar(th.marshalColumnBlobData.rid.pid)+th.marshalColumnBlobDataOffset),ReturnSize)<>ok then exit;
                    th.marshalColumnBlobDataOffset:=th.marshalColumnBlobDataOffset+ReturnSize; //advance cursor
                    //todo etc.?
                    inc(boundSent);
                  end;
                end
              else //null
              begin
                if putSQLSMALLINT(SQL_TRUE)<>ok then exit;
                inc(boundSent);
              end
            end
            else
            begin //raw record data
              if (s.sroot.ptree as TIterator).iTuple.GetDataPointer(i,resP,resLen,resNull)=ok then
              begin
                if resNull then
                begin
                  if putSQLSMALLINT(SQL_TRUE)<>ok then exit;
                end
                else
                begin
                  if putSQLSMALLINT(SQL_FALSE)<>ok then exit;
                  //Note: we only send the length+data if not null
                  if putpDataSDWORD(resP,resLen)<>ok then exit;
                end;
                //todo etc.?
                inc(boundSent);
              end
              else
              begin
                //should never happen
                {$IFDEF DEBUG_LOG}
                log.add(s.who,where+routine,format('Failed reading data pointer for server column %d',[i]),vDebugError);
                {$ENDIF}
                sqlRowStatus:=SQL_ROW_ERROR;
                //todo put dummy data to pad
                resultCode:=SQL_SUCCESS_WITH_INFO;

                inc(i);
              end;
            end;
          end
          else
          begin
            //ColumnNumber is out of range
            //should never happen
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Column number %d is out of range',[ColumnNumber,1,(s.sroot.ptree as TIterator).iTuple.ColCount]),vDebugError);
            {$ENDIF}
            sqlRowStatus:=SQL_ROW_ERROR;
            //todo put dummy data to pad
            resultCode:=SQL_SUCCESS_WITH_INFO;
          end;

          if boundSent<>1 then
          begin
            //problem! - should never happen! - unless data pointer failed above!
            //todo: send dummy data (with colRef=-1?) to keep client in sync. (but not happy!)
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Only %d columns returned out of %d expected',[boundSent,1]),vDebugError);
            {$ENDIF}
            sqlRowStatus:=SQL_ROW_ERROR;
            resultCode:=SQL_SUCCESS_WITH_INFO;
          end;
        end; {with}
      end
      else
        sqlRowStatus:=SQL_ROW_NOROW;

      if noRow then //need to add a dummy row (0 columns) to keep client in-sync.
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Returning %d columns',[0]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        {We must always return a column count, even if it's 0}
        if th.marshal.putSQLINTEGER(0)<>ok then exit;
      end;
      {Now add row status flag}
      if th.marshal.putSQLUSMALLINT(sqlRowStatus)<>ok then exit;
      {Will the entire rowset be empty?}
      if (row=1) and (sqlRowStatus=SQL_ROW_NOROW) then resultCode:=SQL_NO_DATA;
    end; {for row}

    {If we had an error & our row-set size=1 then everything is an error}
    if (s.rowsetSize=1) and (sqlRowStatus=SQL_ROW_ERROR) then
    begin
      resultCode:=SQL_ERROR;
      s.addError(seFail,seFailText); //todo general error ok?
    end;
    //else we have multiple rows, so leave resultCode as success or success with info...
  end;

  with th.marshal do
  begin
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLGetData}

function SQLSetDescField(th:TCMthread):integer;
const routine=':SQLSetDescField';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;
  desc_type:SQLSMALLINT;
  //together the above two refer to our concept of the client's DescriptorHandle
  RecordNumber:SQLSMALLINT;
  FieldIdentifier:SQLSMALLINT;
  Value:SQLPOINTER;
  BufferLength:SQLINTEGER;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit;
    if getSQLSMALLINT(desc_type)<>ok then exit;
    if getSQLSMALLINT(RecordNumber)<>ok then exit; //Note: client column 1 = server column 0, etc.
    if getSQLSMALLINT(FieldIdentifier)<>ok then exit;
    if getSQLPOINTER(Value)<>ok then exit;
    if getSQLINTEGER(BufferLength)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d %d %d %p %d',[StatementHandle,desc_type,RecordNumber,FieldIdentifier,Value,BufferLength]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default

  {Check handle}
  s:=Tstmt(StatementHandle);
  if th.tr.existsStmt(s)<>ok then
  begin
    {Note: some clients unbind after freeing the stmt, so we shouldn't error here...}
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d (probably unbind after stmt freed=ok)',[StatementHandle]),vDebugWarning); //todo clientError? or totally ignore? (only if was a valid stmt handle?)
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE; //ok, or do we need to return success?
    s:=nil; //prevent error stack return
  end
  else
  begin
    s.deleteErrorList; //clear error stack

    //No need to check for prepared plan

    case FieldIdentifier of
      SQL_DESC_DATA_POINTER:
      begin //track bind/unbind
        if Value=nil then
        begin //unbind the column
          if (recordNumber<=s.colBound.size) and (s.colBound.bits[recordNumber-1]) then //assumes short-circuit
          begin
            s.colBound.bits[recordNumber-1]:=False;
            dec(s.colBoundCount);
            {note: don't bother because will probably re-expand:
             if recordNumber=colBound.size then colBound.size:=colBound.size-1;
            }
          end
          else
          begin
            //note: can't happen, cos client should only notify us of changes
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Column %d was not bound - cannot mark as unbound',[recordNumber-1]),vDebugError); //assertion (but maybe bad client's fault)
            {$ENDIF}
            resultCode:=SQL_ERROR;
            s.addError(seColumnNotBound,seColumnNotBoundText);
          end;
        end
        else
        begin
          if (recordNumber>s.colBound.size) or not s.colBound.bits[recordNumber-1] then //assumes short-circuit
          begin
            //todo: because we increase the allocated colBound.size we should sanity-check the new recordNumber!
            if recordNumber>s.colBound.size then s.colBound.size:=recordNumber;
            //todo ensure we increase in large multiples (e.g. 128?) to save fragmentation?
            s.colBound.bits[recordNumber-1]:=True;
            inc(s.colBoundCount);
          end
          else
          begin
            //note: can't happen, cos client should only notify us of changes
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Column %d was already bound - cannot mark as bound',[recordNumber-1]),vDebugError); //assertion (but maybe bad client's fault)
            {$ENDIF}
            resultCode:=SQL_ERROR; //todo return details?
            s.addError(seColumnAlreadyBound,seColumnAlreadyBoundText);
          end;
        end;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Now %d bound column(s)',[s.ColBoundCount]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end; {SQL_DESC_DATA_POINTER}
      SQL_DESC_ARRAY_SIZE:
      begin //track array size
        s.rowsetSize:=SQLUINTEGER(Value);
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Rowset set to %d',[s.rowsetSize]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end; {SQL_DESC_ARRAY_SIZE}
    else
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error unknown field identifier %d',[FieldIdentifier]),vDebugError);
      {$ENDIF}
      resultCode:=SQL_ERROR;
      s.addError(seUnknownFieldId,seUnknownFieldIdText);
    end; {case}
  end;

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLSETDESCFIELD)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLSetDescField}

function SQLGetInfo(th:TCMthread):integer;
const routine=':SQLGetInfo';
var
  ConnectionHandle:SQLHDBC;
  s:Tstmt;
  info_type:SQLSMALLINT;
  //together the above two refer to our concept of the client's DescriptorHandle
  RecordNumber:SQLSMALLINT;
  FieldIdentifier:SQLSMALLINT;
  Value:SQLPOINTER;
  BufferLength:SQLINTEGER;

  errNode:TErrorNodePtr;

  returnValue:string;

  resultCode:RETCODE;

  {Needed because not at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHDBC(ConnectionHandle)<>ok then exit;
    if getSQLSMALLINT(info_type)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d',[ConnectionHandle,info_type]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  returnValue:='';
  case info_type of
    SQL_DATABASE_NAME:                  returnValue:=th.tr.db.dbName;
    SQL_DBMS_NAME, SQL_SERVER_NAME:     returnValue:=Title;
    SQL_DBMS_VER:                       returnValue:=Version;
    SQL_USER_NAME:                      returnValue:=th.tr.authName;
  else
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Error unknown info_type %d',[info_type]),vDebugError);
    {$ENDIF}
    resultCode:=SQL_ERROR;
    resultErrCode:=seUnknownInfoType; resultErrText:=seUnknownInfoTypeText;
  end; {case}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLGETINFO)<>ok then exit;
    if putpUCHAR_SWORD(pUCHAR(returnValue),length(returnValue))<>ok then exit;

    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLGetInfo}


function SQLCloseCursor(th:TCMthread):integer;
const routine=':SQLCloseCursor';
var
  StatementHandle:SQLHSTMT;
  unprepareFlag:SQLSMALLINT;
  s:Tstmt;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit;
    {The client needs to track whether this statement was explicitly prepared or not
     - to use, everything is prepared before being executed.
     The ODBC client needs to return to prepared or not prepared after this function
     but since we have the prepare plan itself, we need to know what's going to happen.
     For now, the client passes us 1 to delete the prepared plan, or 0 to keep it}
    if getSQLSMALLINT(unprepareFlag)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d',[StatementHandle]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default

  {Again, we assume the caller controls the call sequence
   - this may not be safe enough...
   note: we should probably assert the basics, e.g. we have a plan, it's been prepared and executed etc.
   -e.g. planActive=True => cursor open
        - ***applies to all CLI server routines... e.g. can't (re)execute while cursor still open etc.
  }
  {Check handle}
  s:=Tstmt(StatementHandle);
  if th.tr.existsStmt(s)<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE;
    s:=nil; //prevent error stack return
  end
  else
  begin
    s.deleteErrorList; //clear error stack

    {Free any previously referenced blob buffer (from SQLgetData)}
    if (th.marshalColumnNumber<>0) then
    begin //this column is not the one we've just cached for chunking so free our buffer
      (s.sroot.ptree as TIterator).iTuple.freeBlobData(th.marshalColumnBlobData);
      th.marshalColumnNumber:=0; //invalid
      th.marshalColumnBlobData.len:=0;
      th.marshalColumnBlobData.rid.pid:=InvalidPageId;
      th.marshalColumnBlobData.rid.sid:=InvalidSlotId;
      th.marshalColumnBlobDataOffset:=0;
    end;

    //note: need CASE to handle double execute & control unprepare?...
    if s.sroot=nil then
    begin //not prepared
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error no existing prepared plan',[nil]),vDebugMedium);
      {$ENDIF}
      //todo return error - although client FSM should prevent this!
      resultCode:=SQL_ERROR;
      s.addError(seNotPrepared,seNotPreparedText);
    end;

    //todo assert planActive

    {Close result set}
    s.CloseCursor(unprepareFlag);
  end;

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLCLOSECURSOR)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLCloseCursor}

function SQLCancel(th:TCMthread):integer;
const routine=':SQLCancel';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;

  tempResult:integer;
  noMore:boolean;
  otherTr:TObject; {TTransaction}
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d',[StatementHandle]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default

  {Again, we assume the caller controls the call sequence
   - this may not be safe enough...
   note: we should probably assert the basics, e.g. we have a plan, it's been prepared and executed etc.
   -e.g. planActive=True => cursor open
        - ***applies to all CLI server routines... e.g. can't (re)execute while cursor still open etc.
  }
  {Check handle}
  s:=Tstmt(StatementHandle);

  {Find this handle because we need to find it's owning transaction: it could be in another connection/thread's list}
  tempResult:=(th.tr.db).TransactionScanStart; //Note: this protects us from the transaction we find from disappearing!
  if tempResult<>ok then
  begin
    resultCode:=SQL_ERROR;
  end
  else
  begin
    try
      noMore:=False;
      while not noMore do
      begin
        if (th.tr.db).TransactionScanNext(otherTr,noMore)<>ok then begin resultCode:=SQL_ERROR; break; end;
        if not noMore then
          //with (otherTr as TTransaction) do
          //begin
            {Now scan this transaction's statement list
             Note: this checks sysStmt just in case (since it's in the stmtList)}
            {Loop through all this transaction's statements
            }
            if TTransaction(otherTr).existsStmt(s)=ok then
            begin
              //todo assert planActive


              //todo call SQLCloseCursor...? - leave to original caller?

              //todo if otherTr=th.tr then we need to do something else, e.g. SQLexecute=need_data: SQLcancel

              result:=TTransaction(otherTr).Cancel(s,nil);
              break; //done: can be no more matches
            end;
          //end; {with}
      end; {while}
    finally
      tempResult:=(th.tr.db).TransactionScanStop; //todo check result
    end; {try}

  end;

  if result<>ok then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE;
    s:=nil; //prevent error stack return
  end;

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLCANCEL)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      (*Since this is not necessarily our statement, we won't return its error stack
        if s=nil then*)
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      (*
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
      *)
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      result:=fail; //ok?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLCancel}

function SQLPutData(th:TCMthread):integer;
const routine=':SQLPutData';
var
  StatementHandle:SQLHSTMT;
  s:Tstmt;

  nextParam:TParamListPtr;
  tempNull:SQLSMALLINT;
  tempps:pchar;
  tempptr:SQLPOINTER;
  tempsdw:SDWORD;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;
begin
//  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
//  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHSTMT(StatementHandle)<>ok then exit; //this should now be our statement handle (i.e. plan handle)

    resultCode:=SQL_SUCCESS; //default

    {Check handle}
    s:=Tstmt(StatementHandle);
    if th.tr.existsStmt(s)<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[StatementHandle]),vError); //todo clientError?
      {$ENDIF}
      resultCode:=SQL_INVALID_HANDLE;
      s:=nil; //prevent error stack return
    end
    else
    begin
      s.deleteErrorList; //clear error stack

      //note: need CASE to handle double execute & control unprepare?...
      if s.sroot=nil then
      begin //not prepared
        {$IFDEF DEBUG_LOG}
        log.add(s.who,where+routine,format('Error no existing prepared plan',[nil]),vDebugMedium);
        {$ENDIF}
        //todo return error - although client FSM should prevent this!
        resultCode:=SQL_ERROR;
        s.addError(seNotPrepared,seNotPreparedText);
      end;

        begin
          {Find the first parameter with missing data} //note: improve - use fast method of paramList - speed
          //note: code based on ExecutePlan code that finds first missing parameter initially
          nextParam:=s.paramList; //todo add interface to this & hide the structure!
          while nextParam<>nil do
          begin
            //note: only if paramType=in/inout?...
            if s.need_param=strToIntDef(nextParam.paramSnode.idVal,-1) then break;
            nextParam:=nextParam.next;
          end;
          if nextParam<>nil then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('Putting data into parameter %s',[nextParam.paramSnode.idVal]),vDebugMedium);
            {$ENDIF}
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(s.who,where+routine,format('The current missing parameter cannot be found: %d',[s.need_param]),vError);
            {$ENDIF}
            resultCode:=SQL_ERROR;
            s.addError(seNoMissingParameter,seNoMissingParameterText);
          end;

          //Note: since the client has probably set the IPD.datatype, we
          // should send/receive it here to set the parameter dtype properly
          // - assuming the client knows better than us, the server???

          begin
            if nextParam<>nil then
            begin
              {Get the null flag}
              if getSQLSMALLINT(tempNull)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(s.who,where+routine,format('Failed reading parameter null indicator %d',[s.need_param]),vError);
                {$ENDIF}
                exit; //abort
              end;
              if tempNull=SQL_TRUE then
              begin
                nextParam.paramSnode.nullval:=True;
                nextParam.paramSnode.strVal:=''; //needed to remove '?' default, else executePlan thinks we still need more: ok here? copied from sqlExecute.. test!
              end
              else
              begin
                //Note: we only get length+data if not null
                //we assume client has formatted the data correctly
                begin //no conversion required
                  //note: we don't add \0 here - assume client has done it if necessary
                  try
                    if getpDataSDWORD(tempptr,DYNAMIC_ALLOCATION,tempsdw)<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(s.who,where+routine,format('Failed reading parameter data %d',[s.need_param]),vError);
                      {$ENDIF}
                      exit; //abort
                    end;
  //                {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(s.who,where+routine,format('read parameter %d data: %s',[s.need_param,pchar(tempptr)]),vDebugLow); //todo debug only - remove
                  {$ENDIF}
  //                {$ENDIF}
                    //note: only if paramType=in/inout?...
                    if nextParam.paramSnode.strVal='?' then
                    begin
                      setLength(nextParam.paramSnode.strVal,tempsdw);
                      move(tempptr^,pchar(nextParam.paramSnode.strVal)^,tempsdw);
                      if (tempsdw<>(length(pchar(nextParam.paramSnode.strVal))+1)) or (tempsdw>300{todo max strlen}) then nextParam.paramSnode.numVal:=tempsdw; //store length in case blob contains #0
                      nextParam.paramSnode.nullval:=False;
                    end
                    else //append, i.e. multiple calls to putData
                    begin
                      setLength(nextParam.paramSnode.strVal,length(nextParam.paramSnode.strVal)+tempsdw);
                      tempps:=pchar(nextParam.paramSnode.strVal)+length(nextParam.paramSnode.strVal);
                      move(tempptr^,tempps^,tempsdw);
                      nextParam.paramSnode.numVal:=nextParam.paramSnode.numVal+tempsdw; //store length in case blob contains #0
                    end;
                  finally
                    if tempptr<>nil then freeMem(tempptr); //note: check ok with no size //todo explicitly initialise to nil beforehand!
                  end; {try}
                end;

                //tempsdw could be 1 more than length (\0)
              end;
            end;
          end;
        end; {while}
    end;
  end; {with}
//  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(s.who,where+routine,format('%d',[StatementHandle]),vDebugMedium);
  {$ENDIF}
//  {$ENDIF}

//  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(s.who,where+routine,format('returning resultCode=%d',[resultCode]),vDebugMedium);
  {$ENDIF}
//  {$ENDIF}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLPUTDATA)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;

    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(s.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLPutData}


function SQLEndTran(th:TCMthread):integer;
const routine=':SQLEndTran';
var
  ConnectionHandle:SQLHDBC;
  CompletionType:SQLSMALLINT;

  s:Tstmt;

  errNode:TErrorNodePtr;
  resultCode:RETCODE;

  {Needed because not at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHDBC(ConnectionHandle)<>ok then exit;
    if getSQLSMALLINT(CompletionType)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d',[ConnectionHandle,CompletionType]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  s:=nil;

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  //todo check and close any open stmt/cursors first (maybe return success_with_info if we had to!)?
  //Currently, the client does this for us - but we need to be sure

  case CompletionType of
    SQL_COMMIT:   begin
                    //todo clear sysStmt error stack first!?
                    s:=th.tr.sysStmt;
                    if th.tr.Commit(th.tr.sysStmt)<>ok then begin resultCode:=SQL_ERROR; resultErrCode:=seFail; resultErrText:=seFailText; {todo general error ok?} end;
                  end;
    SQL_ROLLBACK: if th.tr.Rollback(False)<>ok then begin resultCode:=SQL_ERROR; resultErrCode:=seFail; resultErrText:=seFailText; {todo general error ok?} end;
  else
    //note: should never happen - unless rogue client...
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Unknown completion type from client %d',[CompletionType]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_ERROR;
    resultErrCode:=seInvalidOption; resultErrText:=seInvalidOptionText;
  end; {case}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLENDTRAN)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if s=nil then
      begin //invalid handle
        if putSQLINTEGER(1)<>ok then exit;
        if putSQLINTEGER(seInvalidHandle)<>ok then exit;
        if putpUCHAR_SWORD(pUCHAR(seInvalidHandleText),length(seInvalidHandleText))<>ok then exit;
      end
      else
      begin //return error stack  //todo use iterator to hide the details
        if putSQLINTEGER(s.errorCount)<>ok then exit;
        errNode:=s.errorList;
        while errNode<>nil do
        begin
          if putSQLINTEGER(errNode.code)<>ok then exit;
          if putpUCHAR_SWORD(pUCHAR(errNode.text),length(errNode.text))<>ok then exit;
          errNode:=errNode.next;
        end;
        //todo assert errorCount=number returned, else abort! (or maybe prevent going over and pad if too few?)
      end;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //note: what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLEndTran}

function SQLAllocHandle(th:TCMthread):integer;
//Note: currently, we only ever expect a handle type of SQL_HANDLE_STMT to be requested here
const routine=':SQLAllocHandle';
var
  HandleType:SQLSMALLINT;
  InputHandle:SQLHDBC; //should really be more generic/accomodating
  OutputStmt:TStmt;
  OutputHandle:SQLHSTMT; //may need to be more generic in future

  resultCode:RETCODE;

  {Needed because not at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLSMALLINT(HandleType)<>ok then exit;
    if getSQLHDBC(InputHandle)<>ok then exit; 
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d',[HandleType,InputHandle]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;  //note: no real need here or elsewhere - speed, but safer...
                                                 //maybe replace with a stacking system, e.g. logError() - no need?
  OutputHandle:=0; //clear

  case HandleType of
    SQL_HANDLE_STMT:
    begin
      {Note: because we have a thread per connection, we don't need to check the connectionHandle parameter
       - this applies elsewhere as well}
      if th.tr.addStmt(stUser,OutputStmt)=ok then
      begin
        //Note: through the CLI we implicitly treat any cursor operations on this stmt as planHold, i.e. available after commit
        OutputHandle:=SQLHSTMT(OutputStmt);
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,'failed allocating stmt handle, continuing...',vAssertion);
        {$ENDIF}
        resultCode:=SQL_ERROR;
        resultErrCode:=seFail; resultErrText:=seFailText; //note: too generic!
      end;
    end;
  else
    //note: should never happen - unless rogue client...
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Unknown handle type from client %d',[HandleType]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE;
    resultErrCode:=seInvalidHandle; resultErrText:=seInvalidHandleText;
  end; {case}

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('returning %d',[OutputHandle]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLALLOCHANDLE)<>ok then exit;
    if putSQLHSTMT(OutputHandle)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLAllocHandle}

function SQLFreeHandle(th:TCMthread):integer;
//Note: currently, we only ever expect a handle type of SQL_HANDLE_STMT to be requested here

//Also note that we close any open cursor automatically: is this allowed by the spec.?

const routine=':SQLFreeHandle';
var
  HandleType:SQLSMALLINT;
  Handle:SQLHSTMT; //may need to be more generic/accomodating in future

  s:Tstmt;

  resultCode:RETCODE;

  {Needed because may not be at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLSMALLINT(HandleType)<>ok then exit;
    if getSQLHSTMT(Handle)<>ok then exit; 
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d',[HandleType,Handle]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  s:=nil; //for error handler count checking
  case HandleType of
    SQL_HANDLE_STMT:
    begin
      {Check handle}
      s:=Tstmt(Handle);
      if th.tr.existsStmt(s)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,format('Invalid handle from client %d',[Handle]),vError); //todo clientError?
        {$ENDIF}
        resultCode:=SQL_INVALID_HANDLE;
        resultErrCode:=seInvalidHandle; resultErrText:=seInvalidHandleText;
        //we still try to remove it from the list, in case it was somehow partially zapped (impossible!)
      end;

      s.deleteErrorList;

      {Ensure the cursor is closed
       Note: this is just to keep things tidy, from what I've seen so far
             it is the callers responsibility to explicitly close any open cursor
      }
      s.CloseCursor(1{=unprepare});

      if th.tr.removeStmt(s)<>ok then
      begin
        if resultCode=SQL_INVALID_HANDLE then
          {$IFDEF DEBUG_LOG}
          log.add(th.tr.sysStmt.who,where+routine,'failed removing stmt handle from list, continuing...',vError) //half-expected this to fail - keep original error & not an assertion
          {$ENDIF}
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(th.tr.sysStmt.who,where+routine,'failed removing stmt handle from list, continuing...',vAssertion);
          {$ENDIF}
          resultCode:=SQL_ERROR;
          resultErrCode:=seFail; resultErrText:=seFailText; //note: too generic!
        end;
      end;
    end;
  else
    //note: should never happen - unless rogue client...
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Unknown handle type from client %d',[HandleType]),vError); //todo clientError?
    {$ENDIF}
    resultCode:=SQL_INVALID_HANDLE; //correct error?
    resultErrCode:=seInvalidHandle; resultErrText:=seInvalidHandleText;
  end; {case}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLFREEHANDLE)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      //Note: we can't send a statement list of errors because we may have zapped the stmt above
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLFreeHandle}

function SQLSetConnectAttr(th:TCMthread):integer;
const routine=':SQLSetConnectAttr';
var
  ConnectionHandle:SQLHDBC;
  Attribute:SQLINTEGER;
  Value:SQLPOINTER;

  errNode:TErrorNodePtr;

  {Needed because we may have no stmt yet}
  resultErrCode:SQLINTEGER;
  resultErrText:string;

  resultCode:RETCODE;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHDBC(ConnectionHandle)<>ok then exit;
    if getSQLINTEGER(Attribute)<>ok then exit;
    if getSQLPOINTER(Value)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d %p',[ConnectionHandle,Attribute,Value]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  case Attribute of
    SQL_ATTR_TXN_ISOLATION:
    begin //isolation level
      (*todo Re-instate: removed for now because Borland SQLexplorer has an active transaction
                         - maybe assumes auto-commit would endTran for schema Selects?
      if th.tr.Rt.tranId<>InvalidStampId.tranId then
      begin
        resultCode:=SQL_ERROR;
        resultErrCode:=seInvalidTransactionState; resultErrText:=seInvalidTransactionStateText;
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,resultErrText,vError);
        {$ELSE}
        ;
        {$ENDIF}
      end
      else
      *)
      begin
        case SQLUINTEGER(Value) of
          SQL_TRANSACTION_SERIALIZABLE,
          SQL_TRANSACTION_REPEATABLE_READ:  th.tr.isolation:=isSerializable;  //note: repeated read is bumped up
          SQL_TRANSACTION_READ_COMMITTED:   th.tr.isolation:=isReadCommitted;
          SQL_TRANSACTION_READ_UNCOMMITTED: th.tr.isolation:=isReadUncommitted; //todo bump up to readCommitted for better behaviour?
        else
          //note: should never happen - unless rogue client...
          {$IFDEF DEBUG_LOG}
          log.add(th.tr.sysStmt.who,where+routine,format('Unknown isolation level from client %d',[SQLUINTEGER(Value)]),vDebugError); //todo clientError?
          {$ENDIF}
          resultCode:=SQL_ERROR;
          resultErrCode:=seInvalidOption; resultErrText:=seInvalidOptionText;
        end;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(th.tr.sysStmt.who,where+routine,format('Now isolation level = %d',[ord(th.tr.isolation)]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;
    end; {SQL_ATTR_TXN_ISOLATION}
  else
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Error unknown attribute %d',[Attribute]),vDebugError);
    {$ENDIF}
    resultCode:=SQL_ERROR;
    resultErrCode:=seInvalidAttribute; resultErrText:=seInvalidAttributeText;
  end; {case}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLSETCONNECTATTR)<>ok then exit;
    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLSetConnectAttr}

function SQLGetConnectAttr(th:TCMthread):integer;
const routine=':SQLGetConnectAttr';
var
  ConnectionHandle:SQLHDBC;
  Attribute:SQLINTEGER;
  returnValue:SQLINTEGER;
  s:Tstmt;
  info_type:SQLSMALLINT;
  //together the above two refer to our concept of the client's DescriptorHandle
  RecordNumber:SQLSMALLINT;
  FieldIdentifier:SQLSMALLINT;
  Value:SQLPOINTER;
  BufferLength:SQLINTEGER;

  errNode:TErrorNodePtr;

  resultCode:RETCODE;

  {Needed because not at stmt level}
  resultErrCode:SQLINTEGER;
  resultErrText:string;
begin
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,'',vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  result:=fail;
  with th.marshal do
  begin
    if getSQLHDBC(ConnectionHandle)<>ok then exit;
    if getSQLINTEGER(Attribute)<>ok then exit;
  end; {with}
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(th.tr.sysStmt.who,where+routine,format('%d %d',[ConnectionHandle,Attribute]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}

  resultCode:=SQL_SUCCESS; //default
  resultErrCode:=seOk; resultErrText:=seOkText;

  returnValue:=-1;
  case Attribute of
    SQL_ATTR_TXN_ISOLATION:
      case th.tr.isolation of
        isSerializable:    returnValue:=SQL_TRANSACTION_SERIALIZABLE;
        //note: repeated read is bumped up
        isReadCommitted:   returnValue:=SQL_TRANSACTION_READ_COMMITTED;
        isReadUncommitted: returnValue:=SQL_TRANSACTION_READ_UNCOMMITTED; //todo bump up to readCommitted for better behaviour?
      else
        {$IFDEF DEBUG_LOG}
        log.add('',where+routine,'unknown isolation level',vAssertion);
        {$ENDIF}
        resultCode:=SQL_ERROR;
        resultErrCode:=seFail; resultErrText:=seFailText;
      end; {case}
  else
    {$IFDEF DEBUG_LOG}
    log.add(th.tr.sysStmt.who,where+routine,format('Error unknown attribute %d',[Attribute]),vDebugError);
    {$ENDIF}
    resultCode:=SQL_ERROR;
    resultErrCode:=seInvalidAttribute; resultErrText:=seInvalidAttributeText;
  end; {case}

  with th.marshal do
  begin
    clearToSend;
    if putFunction(SQL_API_SQLGETCONNECTATTR)<>ok then exit;
    if putSQLINTEGER(returnValue)<>ok then exit;

    if putRETCODE(resultCode)<>ok then exit;
    {if error, then return error details: local-number, default-text}
    if resultCode=SQL_ERROR then
    begin
      if putSQLINTEGER(1)<>ok then exit;
      if putSQLINTEGER(resultErrCode)<>ok then exit;
      if putpUCHAR_SWORD(pUCHAR(resultErrText),length(resultErrText))<>ok then exit;
    end
    else
      if putSQLINTEGER(0)<>ok then exit;
    if Send<>ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(th.tr.sysStmt.who,where+routine,format('Error sending response',[nil]),vError);
      {$ENDIF}
      //todo what now? try to report error to client? log in error table? kill connection? etc.?
      exit;
    end;
  end; {with}

  result:=ok;
end; {SQLGetConnectAttr}


end.

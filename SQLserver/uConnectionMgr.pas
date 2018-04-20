unit uConnectionMgr;

{       ThinkSQL Relational Database Management System
              Copyright Â© 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}  //affects monitor output detail
{$DEFINE DEBUGCOLUMNDETAIL_BLOB} //debug blob detail & allocation counts (from uTuple)

{$IFDEF FPC}
  {$DEFINE INDY10}
{$ELSE}
  {$DEFINE INDY10}
  {.$DEFINE INDY9}
{$ENDIF}

//{$IFDEF LINUX}
//  {$DEFINE INDY8}       //use old Indy: problem with shutdown - extra thread restarts/stop forever!
//{$ENDIF}

interface

uses uGlobal, uServer, uTransaction, uMarshal, uStmt, SyncObjs{for TEvent},
     IdBaseComponent, IdComponent, IdTCPServer, IdThread, IdObjs, IdTCPConnection, IdYarn,
     uGlobalDef{for Tblob}
   {$IFDEF INDY10}
     ,IdContext
   {$ENDIF}     
     ,uEvsHelpers;

type

  TConnectionMgr=class
  private
    dbserver:TDBserver;       //used to pass to each thread for transaction creation
                              //- in future could have multiple servers per process?
  public
    ss:TEvsTCPServer;

    cmShutdown:TEvent;

    constructor Create(dbs:TDBServer);
    destructor Destroy; override;

    function Start(use_port:string):integer;
    function Stop:integer;

    {$IFDEF INDY9}
    procedure ssOnConnect(aThread: TIdPeerThread); //note: type=TIdServerThreadEvent?
    {$endif}
    {$IFDEF INDY10}
      procedure ssOnConnect(aThread: TIdContext); //note: type=TIdServerThreadEvent?
    {$endif}
  end; {TConnectionMgr}

  TclientType=(ctUnknown,ctDumb,ctCLI);
  TCMthread=class(TIdPeerThread)
  {This represents a 'connection'}
  private
    manager:TConnectionMgr; //used to signal server/cm shutdown

    function getIP:string;
  protected
    {$IFDEF INDY10}
    function Run:Boolean; override;
    {$ENDIF}
  public
    dbserver:TDBserver;    //- in future could have multiple servers per process?

    tr:TTransaction;       //the current connection/session
    marshal:TMarshalBuffer;
    marshalColumnNumber:SQLSMALLINT;      //note partially retrieved column for SQLgetData chunking
    marshalColumnBlobData:Tblob;          //partially retrieved column blob data for SQLgetData chunking
    marshalColumnBlobDataOffset:cardinal; //latest position in (partially) retrieved column blob data for SQLgetData chunking
    sHandle:Tstmt; //direct temporary stmt for ctDumb

    clientType:TclientType; //after initial CLI handshake, all other communication is assumed CLI, else raw/dumb
    clientCLIversion:word;  //store the client's driver version for protocol matching
    clientCLItype:word;     //store the client's driver type: CLI_ODBC, CLI_JDBC, CLI_DBEXPRESS, CLI_ADO_NET

    property IP:string read getIP;

     {$IFDEF INDY9}  constructor Create(ACreateSuspended:Boolean); override; {$endif}
     {$IFDEF INdY10} constructor Create(AConnection: TIdTCPConnection; AYarn: TIdYarn; AList: TIdThreadList = nil); override; {$endif}
    destructor Destroy; override;
    {$IFDEF INDY9}
    procedure Run;override;
    {$endif}
  end; {TCMthread}

implementation

uses sysUtils,
{$IFDEF Debug_Log}
  ulog,
{$ENDIF}  
  uParser,
     {$IFDEF WIN32} //move to uOS
     Windows{for thread timing},
     {$ENDIF}
     uCLIserver,
     IdGlobal, IdException, IdStack{for service lookup}
     {$IFNDEF INDY8}
     , IdIOHandlerSocket{for binding}
     {$ENDIF}
     {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
     , uTuple {for blob debug tracking}
     {$ENDIF}
     , uDatabase {for monitor}
     ;

const
  where='uConnectionMgr';
  who='';
  ENDOFSQLENTRY=';'; //end of command input
  SQLBLOCKSTART1='CREATE';
  SQLBLOCKSTART2a='FUNCTION';
  SQLBLOCKSTART2b='PROCEDURE';
  SQLBLOCKSTART2c='SCHEMA';
  ENDOFSQLBLOCKENTRY='.'; //end of command/block entry input (must be on its own line)
  WELCOME_TEXT=CRLF+'"Welcome to %s. "dddddd tt'+CRLF+
                    '"'+Title+CRLF+
                    Copyright+CRLF+
                    'Version '+uGlobal.Version+'"'+CRLF;

  LICENCE_TEXT1='Licensed to %s';
  LICENCE_TEXT2=' for %s concurrent connections';
  UNLICENCE_TEXT1='Unlicensed. Please visit www.thinksql.co.uk for your free developer licence.';
  EXPIRED_LICENCE_TEXT1='Licence has expired. Please visit www.thinksql.co.uk for details of an updated licence.';

  BACKSPACE=#8; //backspace characters to be removed before processing raw-sql

constructor TConnectionMgr.Create(dbs:TDBserver);
begin
  cmShutdown:=TEvent.Create(nil,False,False,'');
  dbserver:=dbs;
  //JKOZ : Replaced the tcp server with a custom one.
  ss:=TEvsTCPServer.Create(nil); //todo handle exception: maybe no TCP/IP stack installed
//  {$IFDEF INDY9}
//    ss.OnConnect:=ssOnConnectOld;
//  {$endif}
  {.$IFDEF INDY10}
    ss.OnConnect:=ssOnConnect;
  {.$endif}

end; {Create}

destructor TConnectionMgr.Destroy;
const routine=':destroy';
begin
  if ss.Active then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Server socket is still active:',[nil]),vAssertion);
    log.add(who,where+routine,format('Trying to close server socket...',[nil]),vDebugMedium);
    log.status;
    {$ENDIF}
    try
      ss.Active:=False;
    except
      on E:Exception do
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Failed closing server socket: %s',[E.message]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end;
  //todo also assert no active threads/connections
  ss.Free;
  cmShutdown.Free;
  inherited Destroy;
end;

function TConnectionMgr.Start(use_port:string):integer;
{Start the listener thread to accept requests
 IN:       use_port     port/service to listen on

 RETURNS:  ok,
           -2 = failed to start listener (e.g. port busy)
           else fail
}
const routine=':Start';
var
  checkPort:integer;
begin
  result:=Fail;
  ss.ThreadClass:=TCMthread;

  //todo: use thread pooling

  //(*debug port already open
  {$IFNDEF LINUX}
  ss.ReuseSocket:=rsTrue; //try to prevent port already in use after some crashes
  {$ENDIF}
  ss.DefaultPort := strToIntDef(use_port, TCPport); //default to fixed port number

  //ss.Bindings.Add;
  //ss.Bindings.Items[0].Port := TCPport; //fix for 9.03 beta?
  //ss.ReuseSocket:=rsTrue;
  try
    checkPort:=GStack.WSGetServByName(use_port); //see if service has been mapped
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Service %s is mapped to port %d',[use_port,checkPort]),vDebugMedium);
    {$ENDIF}
    ss.DefaultPort:=checkPort; //ok, use service
  except
    //service name not registered
  end; {try}
  //*)

  try
    ss.Active:=True;
  except
    on E:Exception do
    begin
      result:=-2;
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Failed to start TCP server to listen on port %d',[ss.DefaultPort]),vError);
      {$ENDIF}
      exit; //abort
    end;
  end; {try}

  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Listening on host   : %s',[ss.LocalName]),vDebugMedium);
  log.add(who,where+routine,format('Listening on port   : %d',[ss.DefaultPort]),vDebugMedium);
  {$ENDIF}

  result:=ok;
end; {start}

function TConnectionMgr.Stop:integer;
const routine=':stop'; 
var
  i:integer;
begin
  inherited;

  result:=Fail;

  //todo: check all connections are closed

  try
    ss.Active:=False;
  except
    on E:Exception do
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Failed closing server socket: %s',[E.message]),vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
  end; {try}

  //todo wait?

  result:=ok;
end; {stop}


{$IFDEF INDY9}
procedure TConnectionMgr.ssOnConnect(aThread: TIdPeerThread); //note: type=TIdServerThreadEvent?
{$endif}
{$IFDEF INDY10}
procedure TConnectionMgr.ssOnConnect(aThread: TIdContext); //note: type=TIdServerThreadEvent?
{$endif}
const
  routine=':ssOnConnect';
begin
  (AThread as TCMThread).dbserver:=self.dbserver;
  {$IFDEF DEBUG_LOG}
  {$IFNDEF INDY8}
  log.add(who,where+routine,format('Accepted connection from address: %s port:%d',[(AThread.Connection.IOHandler as TIdIOHandlerSocket).Binding.PeerIP,(AThread.Connection.IOHandler as TIdIOHandlerSocket).Binding.PeerPort]),vDebugMedium);
  {$ELSE}
  log.add(who,where+routine,format('Accepted connection from address: %s port:%d',[AThread.Connection.Binding.PeerIP,AThread.Connection.Binding.PeerPort]),vDebugMedium);
  {$ENDIF}
  {$ENDIF}


  (AThread as TCMThread).tr.ConnectToDB((AThread as TCMThread).dbServer.getInitialConnectdb); //todo replace with user selection? - i.e. don't connect implicitly here - defer (or by being here have we an explicit right to connect? - I think so...) - or maybe the two connects are different...and should remain separate...
                                //+: rename this call to LinkToDB
                                //   (we have to here because we need a db to have a transaction and
                                //    to be able to lookup details in sys catalog)
                                //   then later if authId=0 then not connected until explicit
                                //   CONNECT x USER y... (or SQLConnect)
  (AThread as TCMThread).Manager:=self;
end;

{$IFDEF INDY10}
constructor TCMthread.Create(AConnection: TIdTCPConnection; AYarn: TIdYarn; AList: TIdThreadList = nil);
{$endif}
{$IFDEF INDY9}
constructor TCMthread.Create(ACreateSuspended:Boolean);
{$endif}
begin
  inherited Create({$IFDEF INDY10}AConnection, AYarn, AList{$ENDIF}{$IFDEF INDY9}ACreateSuspended{$ENDIF});
  //create transaction for this connection
  begin
    tr:=TTransaction.Create;
    tr.thread:=self;

    marshalColumnNumber:=0; //invalid
    marshalColumnBlobData.len:=0;
    marshalColumnBlobData.rid.pid:=InvalidPageId;
    marshalColumnBlobData.rid.sid:=InvalidSlotId;
    marshalColumnBlobDataOffset:=0;

    clientType:=ctUnknown;
    sHandle:=nil;
  end; {with}
end;

{Client thread code}
destructor TCMthread.destroy;
const routine=':destroy';
begin
  if sHandle<>nil then //remove temporary ctDumb stmt
  begin
    if tr.removeStmt(sHandle)<>ok then
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}
    sHandle:=nil;
  end;

  //rollback if we have an active transaction
  //note: disconnect would be better here, but since we free the tr anyway it shouldn't matter
  if tr.tranRt.tranId<>InvalidStampId.tranId then
    tr.rollback(False); //note: customisable - maybe commit instead?
                        //note: cleaner to commit!
  if tr.db<>nil then
    tr.DisconnectFromDB; //any need here in normal operations? ++ yes: we close any open stmts here

  tr.Free;
  tr:=nil;

  //maybe log/debug thread times...

  //above was in Stop

  if marshalColumnNumber<>0 then
  begin //free missed blob buffer //note: should never happen (unless client aborts)
    //todo assert marshalColumnBlobData.rid.pid<>InvalidPageId, else bug?
    //todo assert rid.sid=InvalidSlotId, i.e. in-memory
    //todo try to use (s.sroot.ptree as TIterator).iTuple.freeBlobData(bvData); (but need s etc. & too late here!)
    {$IFDEF DEBUG_LOG}
    log.add('',where+routine,format('blob buffer data for column %d still cached (size=%d NOTE: not recorded in tuple-blob-free-debug-stats), freeing now & continuing...',[marshalColumnNumber,marshalColumnBlobData.len]),vError);
    {$ENDIF}
    freemem(pointer(marshalColumnBlobData.rid.pid),marshalColumnBlobData.len);
    {$IFDEF DEBUGCOLUMNDETAIL_BLOB}
    uTuple.debugTupleBlobDeallocated:=uTuple.debugTupleBlobDeallocated+marshalColumnBlobData.len;
    inc(uTuple.debugTupleBlobRecDeallocated);
    {$IFDEF DEBUG_LOG}
    log.add('',where+routine,format('Freed blob at %p (len=%d)',[pointer(marshalColumnBlobData.rid.pid),marshalColumnBlobData.len]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    marshalColumnNumber:=0;
    marshalColumnBlobData.len:=0;
    marshalColumnBlobData.rid.pid:=InvalidPageId;
    marshalColumnBlobData.rid.sid:=InvalidSlotId;
  end;

  marshal.free;
  marshal:=nil;
  inherited destroy;
end;

function TCMthread.getIP:string;
begin
  if connection.Connected then
  begin
    {$IFNDEF INDY8}
    result:=(Connection.IOHandler as TIdIOHandlerSocket).Binding.PeerIP;
    //todo getPort = (AThread.Connection.IOHandler as TIdIOHandlerSocket).Binding.PeerPort
    {$ELSE}
    result:=Connection.Binding.PeerIP;
    //todo AThread.Connection.Binding.PeerPort
    {$ENDIF}
  end
  else
    result:='';
end; {getIP}

{$IFDEF INDY9}
procedure TCMthread.Run;
{$ENDIF}
{$IFDEF INDY10}
function TCMthread.Run:Boolean;
{$ENDIF}
const routine=':Run';
type
  dumbMode=(dmNormal,dmCreate,dmBlock);
var
  sql,sqlline: String;
  sqllinepos:integer;
  sqlBlock:dumbMode;
  i:integer;

  {$IFDEF WIN32}
  ftCreationTime,ftExitTime,ftKernelTime,ftUserTime:TFileTime;
  sTime:TSystemTime;
  {$ENDIF}

  functionId:SQLUSMALLINT; //word
  res:integer;

  saveAuthName:string;
  resultRowCount:integer;
begin
  {$IFDEF INDY10}
  Result := False;
  {$ENDIF}
  {Wait for handshake to determine client type/version}
  clientType:=ctDumb; //assume dumb client
  try
    Connection.ReadBuffer(FunctionId,2); //i.e. simulate getFunction without CLI marshal protocol/overhead

    if FunctionId=SQL_API_handshake then
    begin
      clientType:=ctCLI;
      marshal:=TMarshalBuffer.Create(Connection);
      marshal.clearToReceive;
      res:=handshake(self); //get cli & respond
      if res<>ok then raise EConnectionException.Create('Handshake failed'); //todo: add message + define type + ensure correctly disconnects both ends!
    end;

    if clientType=ctDumb then //send welcome message
    begin
      sql:=formatDateTime(WELCOME_TEXT,now);
      sql:=format(sql,[dbserver.name]);
      Connection.WriteLn(sql);

      sql:=format(LICENCE_TEXT1,[dbserver.licence.licensee]);
      if dbserver.licence.maxConnections>0 then
        sql:=sql+format(LICENCE_TEXT2,[format('up to %d',[dbserver.licence.maxConnections])]);
      if dbserver.licence.maxConnections<0 then
      begin
        if (dbserver.licence.expiry<>0) and (dbserver.licence.expiry<date) then
          sql:=format(EXPIRED_LICENCE_TEXT1,[nil])
        else
          sql:=format(UNLICENCE_TEXT1,[nil]);
      end;

      Connection.WriteLn(sql+CRLF);
    end;
  except
    {$IFDEF INDY9}
    Connection.DisconnectSocket;
    Terminate; // a bit redundant? exit will take care of the the termination
    {$ENDIF}
    {$IFDEF INDY10}
    Connection.Disconnect;
    {$ENDIF}
    {$IFDEF INDY10}
    Result := False;
    {$ENDIF}
    exit;
  end; {try}

 {Loop through client's commands until we're terminated}
 while not Terminated and Connection.Connected do
  try
      {Read the client's next command}
      case clientType of
        ctCLI:
        begin
          {Note: we currently have 3 types of native CLI client:
             ODBC
             dbExpress
             JDBC
          }
          marshal.clearToReceive;
          res:=marshal.Read;
          //note: the following may happen if we've just closed the server & disconnected a client & we try to read from it...
          //note: marshal.read should be more careful....?
          if res<>ok then raise EConnectionException.Create('Read failed'); //todo: add message + define type + ensure handles both ends! - don't disconnect?!
        end;
        ctDumb:
        begin
          {Note: we have 2 types of dumb client:
             telnet (one line at a time with possible embedded backspaces)
             ISQLraw (multi-line command prepared & sent in one go)

           in both cases, we treat the input line-by-line
          }
          sql:='';
          sqlline:='';
          sqlBlock:=dmNormal; //inside a block definition? if so we wait for . on its own line, else ; will do
          repeat //note: this pulls a line at a time until one ends in ; (or . is on a line of its own)
            sqlline:=Connection.ReadLn(CRLF,IdTimeoutInfinite{todo reduce & check ReadLnTimedOut!});

            {Remove any backspaces, e.g. from telnet/dumb-terminal}
            if pos(BACKSPACE,sqlline)<>0 then
            begin
              i:=1;
              while i<=length(sqlline) do
              begin
                if (sqlline[i]=BACKSPACE) and (i>1) then
                begin
                  delete(sqlline,i-1,2);
                  i:=i-2;
                end;
                inc(i);
              end;
            end;
            sqllinepos:=0;

            {if we are starting a block, switch to block mode so we expect a different terminator
             Note: these string comparisons are expensive... improve pre-parsing here}
            if sqlBlock=dmNormal then
            begin
              sqlline:=trimLeftWS(sqlline);
              if upperCase(copy(sqlline,1,length(SQLBLOCKSTART1)))=SQLBLOCKSTART1 then
              begin
                sqlBlock:=dmCreate;
                sqllinepos:=pos(SQLBLOCKSTART1,upperCase(sqlline))+length(SQLBLOCKSTART1); //skip to next word in case on same line
              end;
            end;

            if sqlBlock=dmCreate then
              if (upperCase(copy(trimLeftWS(copy(sqlline,sqllinepos+1,length(sqlline))),1,length(SQLBLOCKSTART2a)))=SQLBLOCKSTART2a)
                 or (upperCase(copy(trimLeftWS(copy(sqlline,sqllinepos+1,length(sqlline))),1,length(SQLBLOCKSTART2b)))=SQLBLOCKSTART2b)
                 or (upperCase(copy(trimLeftWS(copy(sqlline,sqllinepos+1,length(sqlline))),1,length(SQLBLOCKSTART2c)))=SQLBLOCKSTART2c) then
              begin
                sqlBlock:=dmBlock
              end
              else
                if trimLeftWS(copy(sqlline,sqllinepos+1,length(sqlline)))<>'' then
                  sqlBlock:=dmNormal;
                //else wait for next line with something on 

            if not( (sqlline=ENDOFSQLBLOCKENTRY) ) then
              sql:=sql+trimRight(sqlline)+CRLF //note: NEED this separator, else syntax errors introduced!
            else
              sql:=sql+CRLF; //note: NEED this separator, else syntax errors introduced!

            //todo use InputLn - echoes the data & remove backspaces?
            //       else/and what about if ;<BS>  !?
          until ( (sqlblock<>dmBlock) and (copy(sql,length(sql)-2,3)=ENDOFSQLENTRY+CRLF) ) //todo: use a better terminator!
                or ( (sqlline=ENDOFSQLBLOCKENTRY) );
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,format('Unknown client type: %d',[ord(clientType)]),vAssertion);
        {$ENDIF}
        raise EConnectionException.Create('Unknown client type'); //todo: add message + define type + ensure correctly disconnects both ends!
      end; {case}

      {Process the next command}
      begin
        if clientType=ctCLI then begin
          {Pass the client's command to the server-side CLI routines}
          if marshal.getFunction(FunctionId)=ok then begin
            case FunctionId of
              SQL_API_handshake:                res:=handshake(self); //todo remove: not expected!

              SQL_API_SQLCONNECT:               res:=SQLConnect(self);

              SQL_API_SQLDISCONNECT:            res:=SQLDisconnect(self);
              SQL_API_SQLPREPARE:               res:=SQLPrepare(self);
              SQL_API_SQLEXECUTE:               res:=SQLExecute(self);
              SQL_API_SQLFETCHSCROLL:           res:=SQLFetchScroll(self);
              SQL_API_SQLGETDATA:               res:=SQLGetData(self);
              SQL_API_SQLSETDESCFIELD:          res:=SQLSetDescField(self);
              SQL_API_SQLGETINFO:               res:=SQLGetInfo(self);
              SQL_API_SQLCLOSECURSOR:           res:=SQLCloseCursor(self);
              SQL_API_SQLCANCEL:                res:=SQLCancel(self);
              SQL_API_SQLPUTDATA:               res:=SQLPutData(self);
              SQL_API_SQLENDTRAN:               res:=SQLEndTran(self);
              SQL_API_SQLALLOCHANDLE:           res:=SQLAllocHandle(self);
              SQL_API_SQLFREEHANDLE:            res:=SQLFreeHandle(self);
              SQL_API_SQLSETCONNECTATTR:        res:=SQLSetConnectAttr(self);
              SQL_API_SQLGETCONNECTATTR:        res:=SQLGetConnectAttr(self);


              {todo - for non-ODBC API clients (only!?), e.g. Monitor/Server window
              SYS_MONITOR:
              SYS_SHUTDOWN:
              }

            else
              res:=ok; //assume ok, since we did nothing! ///note: should be fail?
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,format('Unknown function id sent %d, ignoring buffer of %d bytes',[functionId,marshal.getBufferLen]),vDebugError);
              {$ENDIF}
            end; {case}
            //todo check res (maybe clear marshalbuffer if not ok?)
            // - may be that user will timeout or error because of this error...re-synchronise?
            if res<>ok then begin//todo log marshalbuffer state also
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,format('function id %d failed with result %d',[functionId,res]),vDebugError);
              {$ENDIF}
              //note: maybe we should clear the buffer now to help re-sync? or does next read/loop already do this?
              //we should send ***resync to client so it can emergency-clear its buffer waiting & resync

              //Note: for now do something: we copied this code from the exception routine below!
              {Clear any further input from the client}

              marshal.clearToReceive;
              //todo read all pending from connection

              {Now send the client an invalid function response to cause it to generate a connection error}
              marshal.clearToSend;
              marshal.putFunction(SQL_API_exception); //Note: we ignore the result - may not work here...
              if marshal.Send<>ok then begin
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,format('Error sending error response',[nil]),vDebugMedium);
                {$ENDIF}
                //todo what now? try to report error to client? log in error table? kill connection? etc.?
                raise EConnectionException.Create('Error sending error response'); //todo: add message + define type + ensure correctly disconnects both ends! - BUT better to re-sync if possible!
              end;
            end;
          end;
          //else //todo error!
        end else begin//ctDumb

          {$IFDEF DEBUG_LOG}
          {$IFDEF DEBUGDETAIL}
          log.add(st.who,where+routine,format('Treating as raw SQL text: %s',[sql]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          if sHandle=nil then //allocate a temporary statement (used to use sysStmt but was tripping over self!)
            if tr.addStmt(stUser{implicit},sHandle)=ok then
            else begin
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,'failed allocating temporary stmt handle, continuing...',vAssertion);
              {$ENDIF}
              continue; //i.e. ignore this attempt & continue with outer while loop
            end;

          //note: we should make sure that user has CONNECTed so we have an authId<>0
          // unless this command is a CONNECT command...
          //+ although we do need to allow monitor/shutdown/kill even if limited connections are full!

          if (copy(sql,1,7)='monitor') then //todo Remove- debug only!
          begin
            {Show current db transaction status list = db connections}
            saveAuthName:=tr.authName;
            tr.authName:='MONITOR';      //temporarily display different connection name (for use by monitor application)
            try
              Connection.WriteLn(format('Current connections:',[nil]));
              //initialDB:=getInitialConnectdb;
              if tr.db<>nil then
                try
                  with (tr.db.owner as TDBserver).dbList.locklist do
                    //newDB:=(Ttransaction(stmt.owner).db.owner as TDBserver).findDB(stmt.sroot.leftChild.idVal); //assumes we're already connected to a db
                    for i:=0 to count-1 do begin
                      {
                      if TDB(Items[i])=initialDB then
                        connection.Writeln(' *'+TDB(Items[i]).dbName)
                      else
                      }
                      if Items[i]<>nil then begin
                        connection.Writeln('Catalog '+TDB(Items[i]).dbName+':');
                        Connection.WriteLn(TDB(Items[i]).ShowTransactions);
                      end;
                    end;
                finally
                  (tr.db.owner as TDBserver).dbList.unlockList;
                end {try}
              else
                Connection.WriteLn(format('  <no current catalog>',[nil]));
            finally
              tr.authName:=saveAuthName; //restore
            end; {try}
          end else begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Handle=%d SQL=%s',[handle,sql]),vDebugMedium);
            {$ENDIF}
            if uParser.ExecSQL(sHandle,sql,Connection,resultRowCount)=-999 then begin //shutdown system //note: debug method only...
              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,format('Server requested to shutdown by transaction %s',[tr.sysStmt.who]),vDebugMedium);
              {$ENDIF}
              //todo send client 'shutting down server' confirmation message

              //todo: db.removeTransaction for all current

              {Kill self}
              Connection.Disconnect;
              {pass shutdown signal to main caller to close system}
              if manager<>nil then manager.cmShutdown.SetEvent;
              //todo else assertion!
              Terminate;
            end;
          end;
          {any other code here should be thread-safe
           e.g. use PostMessage etc.
          }
        end;
      end;
  except
    on E:Exception do
    begin
      if not(Connection.Connected) and Connection.ClosedGracefully then
      begin
        {Normal disconnection - go quietly}
        Terminate;
      end
      else
      if E is EConnectionException then
      begin  //abnormal disconnection
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Exception: '+E.message,vError); 
        log.add(tr.sysStmt.who,where+routine,'Exception class: '+E.className,vDebugLow);
        log.add(tr.sysStmt.who,where+routine,'Closing connection!',vDebugLow);
        {$ENDIF}
        Terminate;
      end
      else
      begin  //still connected
        {$IFDEF DEBUG_LOG}
        log.add(tr.sysStmt.who,where+routine,'Exception: '+E.message,vAssertion);
        log.add(tr.sysStmt.who,where+routine,'Exception class: '+E.className,vDebugLow);
        {$ENDIF}

        case clientType of
          ctCLI:
          begin //gracefully pass error back to CLI client
              {Clear any further input from the client}

              marshal.clearToReceive;

              {Now send the client an invalid function response to cause it to generate a connection error}
              marshal.clearToSend;
              marshal.putFunction(SQL_API_exception); //Note: we ignore the result - may not work here...
              if marshal.Send<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,format('Error sending error response',[nil]),vDebugMedium);
                {$ENDIF}
                //todo what now? try to report error to client? log in error table? kill connection? etc.?
                Terminate; //must assume client connection is dead
              end;
          end; {ctCLI}
          ctDumb:
          begin
            if E is EIdSocketError then Terminate; //prevent infinite loop pegging processor
          end; {ctDumb}
        end; {case}
      end;
    end;
  end; {try}
  {$IFDEF INDY10} //this is the last line of execution what was the task it was apparently finished properly.
  Result := True;
  {$ENDIF}
end; {ClientExecute}


end.


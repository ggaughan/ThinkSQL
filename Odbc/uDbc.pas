unit uDbc;

{$define ODBC}

interface

uses IdTCPClient, uDiagnostic, uMain {to access ODBC.inc defs},uGlobal, uStmt, uMarshal;

type
  PtrTstmtList=^TstmtList;
  TstmtList=record
    stmt:Tstmt;
    next:PtrTstmtList;
  end; {TstmtList}

  TdbcState=(C0, //Unallocated environment, unallocated connection
             C1, //Allocated environment, unallocated connection
             C2, //Allocated environment, allocated connection
             C3, //Connection function needs data
             C4, //Connected connection
             C5, //Connected connection, allocated statement
             C6  //Connected connection, transaction in progress. It is possible for a connection to be in
                 //state C6 with no statements allocated on the connection. For example, suppose the
                 //connection is in manual commit mode and is in state C4. If a statement is allocated,
                 //executed (starting a transaction), and then freed, the transaction remains active but there
                 //are no statements on the connection
             );

  Tdbc=class
  private
  public
    owner:TObject; //Tenv
    state:TdbcState;
    clientSocket:TIdTCPClient;
    marshal:TMarshalBuffer; //protect with criticalSection - maybe can use socket.lock?
    diagnostic:Tdiagnostic;

    serverCLIversion:word; //store server's parameter protocol version
    serverTransactionKey:SQLPOINTER; //store server's unique id for future encryption/validation
    DSN:string; //datasource used to connect
    DSNserver:string; //server[.catalog] used to connect

    stmtList:PtrTstmtList;  //maybe hide somewhat //todo protect with critical section (or whole env?)

    login_timeout:integer; //todo: use!
    connection_timeout:integer;

    //todo store SQL_DATA_SOURCE_NAME from initial connection for getInfo
    autoCommit:boolean;

    constructor Create;
    destructor Destroy; override;

    function AddStatement(s:Tstmt):integer;
    function RemoveStatement(s:Tstmt):integer;

  end; {Tdbc}

implementation

const
  //todo take these from a common unit/include file...

  ReceiveTimeout=60000{minutes}*10; //client thread receive timeout in milliseconds  //todo make configurable


constructor Tdbc.Create;
//todo also pass owner in!
begin
  diagnostic:=TDiagnostic.create;
  stmtList:=nil;
//remember: we will want to cache disconnected/created connections in future
  clientSocket:=TIdTCPClient.Create(nil);
  //todo disable Nagle?!?

  clientSocket.Host:='';
  clientSocket.Port:=0;

  marshal:=TMarshalBuffer.create(clientSocket);

  serverCLIversion:=0000;
  serverTransactionKey:=nil;
  DSN:='';
  DSNserver:='';

  login_timeout:=$FFFFFFFF; //todo maximum = timeout 0 to SQL
  connection_timeout:=$FFFFFFFF; //todo maximum = timeout 0 to SQL
  autoCommit:=True; //piss-poor ODBC default //todo get default from external setting?

  state:=C1;
end; {create}
destructor Tdbc.Destroy;
var nextNode:PtrTstmtList;
begin
  marshal.free;
  //clear up any remaining in stmtList //todo ok here? - or should we assert if we find any?
          //we should assert because the FSM should disallow the freeHandle
  while stmtList<>nil do
  begin
    //todo: call RemoveStatement before stmt.free!? -but we don't care here- just zap them...
    (stmtList^.stmt).free;    //remove the stmt (this closes any open cursor, unbinds everything & removes descs)
    nextNode:=stmtList^.next;
    dispose(stmtList);
    stmtList:=nextNode;
  end;

  //todo clear any extra descs attached by user...

  //todo assert state!
  clientSocket.free;
  diagnostic.free;

  inherited;
end; {destroy}

function Tdbc.AddStatement(s:Tstmt):integer;
//todo maybe make part of create
var
  newNode:PtrTstmtList;
begin
//todo use generic list class...

  new(newNode);
  newNode^.stmt:=s;
  newNode^.next:=stmtList;

  stmtList:=newNode;

  Tdbc(s.owner):=self;

  result:=ok;
end; {AddStatement}
function Tdbc.RemoveStatement(s:Tstmt):integer;
//todo maybe make part of destroy
{
 RETURNS:
         ok=ok,
         fail=error, statement not found in list - assertion!?
         +1 = ok, and this was the last one in the list, i.e. no more statements

 Note: doesn't free the statement, just removes it from the dbc's list
}
var
  trailNode:PtrTstmtList;
  oldNode:PtrTstmtList;
begin
//todo use generic list class...

  {Find node}
  oldNode:=stmtList;
  trailNode:=nil;
  while oldNode<>nil do
  begin
    if oldNode^.stmt=s then break; //found //todo Note: assumes pointer equivalence is a valid check
    trailNode:=oldNode;
    oldNode:=oldNode^.next;
  end;

  if oldNode=nil then
  begin
    //could not find this statement in the connection's list of statements => assertion
    log('Could not find this statement in the dbc statement list');
    result:=fail;
    exit;
  end;

  {Zap node}
  if trailNode=nil then
    stmtList:=oldNode.next         //if removing 1st node, link list header
  else
    trailNode.next:=oldNode.next; //link prior node to condemned node's successor
  dispose(oldNode);             //remove old node

  if stmtList=nil then
    result:=+1 //no more statements
  else
    result:=ok;
end; {removeStatement}


end.

unit uEnv;

{$define ODBC}

interface

uses uDbc, uMain {for ODBC.inc},uDiagnostic;

type
  PtrTdbcList=^TdbcList;
  TdbcList=record
    dbc:Tdbc;
    next:PtrTdbcList;
  end; {TdbcList}

  {These states are taken from Microsoft's ODBC SDK (v3.5 appendix B)}
  TenvState=(E0, //Unallocated environment
             E1, //Allocated environment, unallocated connection
             E2  //Allocated environment, allocated connection
             );

  {TODO: we should have a Thandleclass class containing common stuff for Tenv Tdbc and TStmt!}
  Tenv=class
  private
  public
    state:TenvState;
    diagnostic:Tdiagnostic;

    nullTermination:SQLINTEGER;
    {$ifdef ODBC}
    odbcVersion:SQLINTEGER;
    {$endif}

    dbcList:PtrTdbcList; //maybe hide somewhat //todo protect with critical section (or whole env?)

    constructor Create;
    destructor Destroy; override;

    function AddConnection(c:Tdbc):integer;
    function RemoveConnection(c:Tdbc):integer;

  end; {Tenv}

implementation

uses uGlobal;

constructor Tenv.Create;
begin
  diagnostic:=TDiagnostic.create;
  dbcList:=nil;
  {set defaults}
  nullTermination:=SQL_TRUE;
  {$ifdef ODBC}
  odbcVersion:=SQL_OV_ODBC3;
  {$endif}
  state:=E0;
end; {create}
destructor Tenv.Destroy;
begin
  //todo free dbcList etc.
  diagnostic.free;

  inherited;
end; {destroy}

function Tenv.AddConnection(c:Tdbc):integer;
//todo maybe make part of create
var
  newNode:PtrTdbcList;
begin
//todo use generic list class...
//remember: we will want to cache disconnected/created connections in future

  new(newNode);
  newNode^.dbc:=c;
  newNode^.next:=dbcList;

  dbcList:=newNode;

  Tenv(c.owner):=self;

  result:=ok;
end; {addConnection}
function Tenv.RemoveConnection(c:Tdbc):integer;
//todo maybe make part of destroy
{
 RETURNS:
         ok=ok,
         fail=error, connection not found in list - assertion!?
         +1 = ok, and this was the last one in the list, i.e. no more connections

 Note: doesn't free the connection, just removes it from the env's list
}
var
  trailNode:PtrTdbcList;
  oldNode:PtrTdbcList;
begin
//todo use generic list class...
//remember: we will want to cache disconnected/created connections in future

  {Find node}
  oldNode:=dbcList;
  trailNode:=nil;
  while oldNode<>nil do
  begin
    if oldNode^.dbc=c then break; //found //todo Note: assumes pointer equivalence is a valid check
    trailNode:=oldNode;
    oldNode:=oldNode^.next;
  end;

  if oldNode=nil then
  begin
    //could not find this connection in the environment's list of connections => assertion
    log('Could not find this connection in the env connection list');
    result:=fail;
    exit;
  end;

  {Zap node}
  if trailNode=nil then
    dbcList:=oldNode.next         //if removing 1st node, link list header
  else
    trailNode.next:=oldNode.next; //link prior node to condemned node's successor
  dispose(oldNode);             //remove old node

  if dbcList=nil then
    result:=+1 //no more connections
  else
    result:=ok;
end; {removeConnection}


end.

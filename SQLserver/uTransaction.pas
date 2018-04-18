unit uTransaction;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{This class encapsulates information for each active transaction in the
 server.

 Since the transaction object itself exists for the whole session (and the
 individual transactions are started and committed within it) some session
 information is held in this object as well.
 In particular the db reference which is set via the Connect method.
 And the thread reference, used for killing and debugging.

 Also, a number of stmt's can be attached to this transaction. Each one having
 its own parse-prepare-execute-cursor area.

 Note the stmt/stmtId references in this unit are not the same thing:
 When an action is executed atomically, the Wt and Rt stmtId's are updated
 to keep track of which stmt's within this transaction have been rolled-back.
 This will mean that we must close all stmts when we commit or rollback the
 transaction. //todo (or at least close all except read-only-cursors...)
 i.e. the stmtId is a way of creating sub-transactions for atomicity and
 to allow deferred constraint checking.
 ++Note: this implies (I think) that only 1 thread can be used per transaction
         because each stmt must start+stop atomically before the next one
 +++: yes, even psuedo-parallel stmts are not handled,
      e.g. select cursor, insert: cursor loop sees inserts: need stmt.canSee etc.?
 ++++: fixing this: 26/03/02... passing stmt into canSee etc.
        stmt now has fRt/fWt copied from owner(transaction) when tran.starts or stmt is created
        sysStmt/2 is updated whenever transaction is re-started
        transaction tranRt can be read to determine global transaction state
        individual stmt can be left open after transaction commit/rollback
        & active stmt retains original Rt/Wt but uses transaction level rolled-back info = unpredictable
        transaction fWt is used to count to latest stmtId Wt (issued/incremented on stmtStart/stmtCommit etc.)
        so still concept of latest Wt.stmtId = active insert/update/delete
        & previous stmt.ids = committed/rolled-back or open queries
        Inactive stmts are synchronised with the latest stmtCommit to ensure their next call sees own tran's changes

 Note:
 Some naming conventions (in other modules) as at 02/08/99:
   tran = transaction reference of an iterator creator
   tr   = transaction reference of callers of lower level (sub)routines
}

{  JKOZ :001: problem with encapsulation.
               A worker should not reference directly an initiator only through established mechanisms and
               initiator on the other hand can reference and monitor and manage a worker.
               A Worker inform any one registered for updates for its status as he sees fit.
                 That might time intervals or when a change in status occures.
               in short a transaction should not have any access to the thread that initiated but
               the thread can register an event to get inform when the transaction fails or succeds
               with its task.
               The same goes for the task managed by the transaction they should only care who to update.
}

{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2}  //stmt level sub-transactioning
{$DEFINE DEBUGDETAIL3}  //trace tran/stmt memory allocation
{$DEFINE INDY10}  //trace tran/stmt memory allocation

interface

uses uGlobalDef, uGlobal, IdTCPConnection{only for showtrans diags for monitor & kill},
     uSyntax {for parseRoot}, uDatabase, uConstraint,
     uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants},
     classes {for TThread}, sysutils, uStmt, uEvsHelpers
     ;

type
  {Structure for storing user specified immediate/deferred constraints for each transaction
   (Note: if list contains 1 entry with id=0, this indicates ALL)}
  TconstraintTimeOverridePtr=^TconstraintTimeOverride;
  TconstraintTimeOverride=record
    constraintId:integer; //Note: 0=ALL
    constraintTime:TconstraintTime;
    next:TconstraintTimeOverridePtr;
  end; {TconstraintTimeOverride}

  TgeneratedPtr=^Tgenerated;
  Tgenerated=record
    generatorId:integer;
    lastValue:integer;
    next:TgeneratedPtr;
  end; {Tgenerated}

  TTransaction=class
    private
      fdb:Tdb;                //database for current connection
    {$IFDEF INDY9}
      fThread:TThread;        //controlling thread reference (from this we could get the network connection!)
                              //nil = db creation or main thread
    {$ENDIF}
    {$IFDEF INDY10}
      fThread:TObject;//TIdPeerThread;
    {$ENDIF}
      {Note: we use read/write timestamps to allow partial transaction rollbacks:
         Rt.stmtId is the latest successful insert/update/delete statement written (initially 0)
         Wt.stmtId is used to write changes at least 1 ahead of the read-ability (initially 0)
       Note: the tranId's of both are always the same, but the stmtId's may differ
       Note: the stmtId is not the same as the stmt/st
       Note: 26/03/02: the above has changed slightly to allow for open cursors...
                Wt.stmtId is used (only!) to track the last used stmtId
                the Tstmt.Rt.stmtId is now used to check visibility
      }
      fRt:StampId; //default read-as timestamp for stmts
      fWt:StampId; //next write-as timestamp (used to write optimistically and atomically)

      fAuthId:TAuthID;        //=user
      fAuthName:string;       //auth name - used for user functions //todo make a special type
      fSchemaId:TSchemaID;
      fSchemaName:string;     //schema name - used for dubbing relations //todo make a special type
      fSchemaVersionMajor:integer;
      fSchemaVersionMinor:integer;
      fSchemaId_authId:TAuthID;        //=schema owner (at time of connect() at least)
      fCatalogId:TCatalogID;  //not implemented yet - all default to sysCatalogDefinitionCatalogId (1)
      fCatalogName:string;    //catalog name - not implemented yet - all default to dbName
      fauthAdminRole:TadminRoleType; //admin role
      fConnectionName:string; //todo make a special type
                              //todo: in future may need to have an array of these (+ other 'connection' info)
                              //      so that 1 thread can open many connections (but only ever 1 active)
                              //      & same trans for all... but potentially could be over multiple catalogs...
                              //      - may mean introducing a new level, e.g. tr.activeConnection.db
      frid:Trid;              //location of this transactions status row

      fRecovery:boolean;      //flag to lower-level routines that we are special if we are recovering
                              //i.e. we can do some things that a mortal transaction shouldn't be allowed to do.

      stmtList:TPtrstmtList; //todo: make into list...
      stmtListCS:TmultiReadExclusiveWriteSynchronizer;     //stmtList access mutex - used to protect access when adding/removing/cancelling/killing/scanning
      stmtListNextNode:TPtrstmtList;   //cursor for stmtScan: note 1 per transaction is enough?
                                       //- not if asynchronous (e.g. Cancel) hits at same time as another scan, e.g. index rebuild...

      fTimezone:TsqlTimezone;

      {Historical transaction status}
      fisolation:Tisolation;
      fearliestUncommitted:StampId;       //on start, store earliest uncommitted to speed up canSee checking

      fsqlstateSQL_NO_DATA:boolean;       //currently only used by cursor open/fetch to flag EOF to user
      //function fWho:string;

      generatedList:TgeneratedPtr;        //list of latest generated (sequence) values (lifetime = connection)

      function getCurrentDate:TsqlDate;
      function getCurrentTime:TsqlTime;
      function getCurrentTimestamp:TsqlTimestamp;

      function fconnected:boolean;
    public
      sysStmt:Tstmt;  //pointer to initial (system) stmt handle, used for internal SQL commands
                      //todo: protect this from nested double-use else strange errors
                      // - especially check constraint checking!

      constraintList:TConstraint;   //list of current transaction level constraints
      constraintTimeOverride:TconstraintTimeOverridePtr; //list of current user constraint time overrides

      uncommittedCount:integer;
      uncommitted:TtranStatusPtr;
      rolledBackStmtCount:integer;
      rolledBackStmtList:TstmtStatusPtr; //Pointer to any rolled-back stmts => on commit, this will be tsPartRolledBack

      property db:Tdb read fdb;
      {$IFDEF INDY9}
      property Thread:TThread read fThread write fThread;
      {$ENDIF}
      {$IFDEF INDY10}
       property Thread:TObject read fThread write fThread;
      {$ENDIF}

      //todo protect writes via Set routines
      //note: use stmt level versions: 26/03/02
      //property Rt:StampId read fRt write fRt;   //written temporarily by constraint.check
      //property Wt:StampId read fWt;
      property tranRt:StampId read fRt write fRt; //for those who really need to know & don't need stmt level...
                                                  //write is just for garbage collector: todo: use some other, safer way

      property isolation:Tisolation read fisolation write fisolation;
      property connected:boolean read fconnected;

      //property who:string read fWho;
      property authID:TAuthID read fAuthId write fAuthId; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property authName:string read fAuthName write fAuthName; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property schemaID:TSchemaID read fSchemaId write fSchemaId; //todo: ensure this is set when Transaction is created!- i.e. via Logon! //todo ensure we set id & name together!
      property schemaName:string read fSchemaName write fSchemaName; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property SchemaVersionMajor:integer read fSchemaVersionMajor;
      property SchemaVersionMinor:integer read fSchemaVersionMinor;
      property schemaID_authId:TAuthID read fSchemaId_authId write fSchemaId_authId; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property catalogID:TCatalogID read fCatalogId write fCatalogId; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property catalogName:string read fCatalogName write fCatalogName; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property authAdminRole:TadminRoleType read fauthAdminRole write fauthAdminRole; //todo: ensure this is set when Transaction is created!- i.e. via Logon!
      property connectionName:string read fConnectionName write fConnectionName ;

      property recovery:boolean read fRecovery;

      property timezone:TsqlTimezone read fTimezone write fTimezone; //todo: ensure this is set when Transaction is created!- i.e. via Logon!

      property currentDate:TsqlDate read getCurrentDate;
      property currentTime:TsqlTime read getCurrentTime;
      property currentTimestamp:TsqlTimestamp read getCurrentTimestamp;

      property earliestUncommitted:StampId read fearliestUncommitted;

      property sqlstateSQL_NO_DATA:boolean read fsqlstateSQL_NO_DATA write fsqlstateSQL_NO_DATA; //avoid string for now for this single use to save memory re-allocations

      constructor Create;
      destructor Destroy; override;

      function Who:string; //todo remove? called by tdb.showTransactions

      function ConnectToDB(toDB:Tdb):integer;
      function DisconnectFromDB:integer;

      function Before(CheckWt:StampId):boolean;
      function After(CheckWt:StampId):boolean;  //deprecated

      function Connect(Username:string;Authentication:string):integer;
      function Disconnect:integer;

      function Start:integer;
      function Commit(st:Tstmt):integer;
      function Rollback(onlyPartial:boolean):integer;
      function Reset:integer;

      function readUncommittedList:integer; //bodge
      function RemoveUncommittedList(onlyRolledBackTrans:boolean):integer; //needs to be public to reverse readUncommittedList bodge


      function addStmt(sType:TstmtType;var stmtNode:Tstmt):integer;
      function existsStmt(stmtNode:Tstmt):integer;
      function getStmtFromCursorName(s:string;var stmtNode:Tstmt):integer;
      function getStmtFromId(stmtId:StampId;var stmtNode:Tstmt):integer;
      function getSpareStmt(sType:TstmtType;var stmtNode:Tstmt):integer;
      function removeStmt(stmtNode:Tstmt):integer;
      function showStmts:string;

      function StmtScanStart:integer;
      function StmtScanNext(var st:TStmt; var noMore:boolean):integer;
      function StmtScanStop:integer;

      function StmtStart(st:Tstmt):integer;
      function StmtCommit(st:Tstmt):integer;
      function StmtRollback(st:Tstmt):integer;

      function SynchroniseStmts(all:boolean):integer;

      function ConstraintTimeOverridden(constraintId:integer):TconstraintTime;

      function Cancel(st:Tstmt;connection:TIdTCPConnection):integer;
      function Kill(connection:TIdTCPConnection):integer;

      function GetEarliestActiveTranId:StampId;

      function SetLastGeneratedValue(genId,value:integer):integer;
      function GetLastGeneratedValue(genId:integer;var value:integer):integer;

      function ShowTrans(connection:TIdTCPConnection):integer; //debug only - todo remove!

      function DoRecovery:integer;   //covers multiple transactions
  end; {TTransaction}

var
  debugTransStatusCreate:cardinal=0;   //todo remove -or at least make thread-safe & private
  debugTransStatusDestroy:cardinal=0;  //"
  debugStmtStatusCreate:cardinal=0;    //"
  debugStmtStatusDestroy:cardinal=0;   //"

implementation

uses uFile, uServer, uRelation, uTuple, uLog, uPage,
     uConnectionMgr{for access to TCMthread for kill: todo use TIdPeerThread instead}, Math{for power}
     (*,uIterator{for stmt close/clean}, uProcessor {for unprepare - move to uparser?}*)
     ,uOS {for kill sleep}
     ;

const
  where='uTransaction';

//todo get from db header?  NextTranRID:TRid=(pid:startPage; sid:1);


constructor TTransaction.Create;
const routine=':create';
begin
  {Zeroise settings}
  fdb:=nil; //not connected
  fThread:=nil; //no thread set: caller must do this
  frid.pid:=InvalidPageId;
  frid.sid:=InvalidSlotId;
  fRt:=InvalidStampId;
  fWt:=InvalidStampId;
  fAuthId:=InvalidAuthId;
  fAuthName:='';
  fSchemaId:=0;
  fSchemaName:='';
  fSchemaVersionMajor:=-1;
  fSchemaVersionMinor:=-1;
  fCatalogId:=0; //default to system id of 0 (for now- todo)
  fCatalogName:='';
  fConnectionName:=''; //todo default to something - see spec.
  ftimezone:=TIMEZONE_UTC; //default=UTC(GMT)

  //todo set current date/time etc. now (or at stmtStart?)

  stmtListCS:=TmultiReadExclusiveWriteSynchronizer.Create;
  stmtList:=nil; //no allocated statements
  {note: for now (debugging), we create 1 statement per transaction/connection/session
   in future, the client will need to notify the server via allocHandle(stmt)/freehandle(stmt)
   and the server can then keep a list per transaction
  }
  //note: this stmt will only be used for internal use:
  //      ODBC clients will allocate new ones as needed
  //        is it best to always create it here?
  //      what if it's not created here - does the rest of the code care?
  if addStmt(stSystemDDL,sysStmt)=ok then
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'failed creating initial stmt, continuing...',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}

  constraintList:=TConstraint.create(nil,'',0,'',0,nil,false,InvalidStampId,ccUnknown,ceChild); //create dummy header node
  constraintTimeOverride:=nil; //no user overrides

  generatedList:=nil; //no sequences used

  isolation:=DefaultIsolation; //default
  uncommittedCount:=0;
  uncommitted:=nil;
  fearliestUncommitted:=InvalidStampId;

  fRecovery:=False;
end; {create}

destructor TTransaction.Destroy;
const routine=':destroy';
var
  s:Tstmt;
  generatedItem:TgeneratedPtr;
begin
  {if still active - auto rollback}
  if fRt.tranId<>InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is still active - will rollback...',vAssertion); 
    {$ENDIF}
    rollback(False);  //may want user to be able to switch this behaviour - no - too low level here
  end;

  //todo check that fdb=nil - i.e. formally disconnected (i.e/e.g. by creator routine)
  // - still continue even if still connected...
  if db<>nil then DisconnectFromDB; //todo check result, but continue anyway...

  //todo assert/check that authId=InvalidAuthId, i.e. client has disconnected: continue anyway...

  if (uncommittedCount<>0) or (uncommitted<>nil) then
  begin
    //Note we now expect this since commit/rollback defer it for cursor preservation
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'removing uncommitted list...',vDebugLow); 
    {$ENDIF}
    RemoveUncommittedList(False);
  end;

  {Delete any remaining constraint list (should just be header node?) //todo assert if more?}
  //todo assert that all of these have ConstraintTime=csTran - else they should not be here!
  constraintList.clearChain; //todo check result
  {Delete the constraint list head node}
  constraintList.free;

  //todo clean up anything left in constraintTimeOverride (else memory leak!)

  {Clean up any sequence history from generatedList}
  while generatedList<>nil do
  begin
    generatedItem:=generatedList;
    generatedList:=generatedItem.next;
    dispose(generatedItem);
  end;

  if removeStmt(sysStmt)<>ok then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'failed deleting initial stmt, continuing...',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}
  //todo in future, should do this removeStmt for stmtList while stmtList<>nil, i.e. clean up, even if freeHandle was missed


  //todo clean up anything left in stmtList
  {note: for now (debugging), we create 1 statement per transaction/connection/session
   in future, the client will need to notify the server via allocHandle(stmt)/freehandle(stmt)
   and the server can then keep a list per transaction
  }
  {We remove any remaining stmts, e.g. from a rudely terminated JDBC client,
   or genuine constraint-checking stmts which are kept cached to save time}
  //todo cs.beginRead
  while stmtList<>nil do
  begin
    s:=stmtList^.sp;

    {$IFDEF DEBUG_LOG}
    log.add(s.who,where+routine,format(': Cleaning remaining stmt %d (type=%d)...',[s.Rt.stmtId,ord(s.stmtType)]),vDebugLow); //todo client error?
    if not(   (s.stmtType in [stSystemConstraint] )
           or ( (s.stmtType in [stUserCursor]) and (s.planHold or s.planReturn) ) ) then
      log.add(s.who,where+routine,format(': ...remaining stmt %d was not expected to need cleaning up...',[s.Rt.stmtId]),vDebugLow); //todo client error?
    {$ENDIF}

    if removeStmt(s)<>ok then
     {$IFDEF DEBUG_LOG}
     log.add(self.who,where+routine,'  failed deleting stmt, continuing...',vAssertion);
     {$ELSE}
     ;
     {$ENDIF}
  end;

  stmtListCS.Free; //todo check not already free - can't happen?

  inherited Destroy;
end; {destroy}

function TTransaction.ConnectToDB(toDB:Tdb):integer;
{
 Note: nothing much to do with client CONNECT/SQLconnect
       - this just links the transaction to a db so we can proceed to get a transaction id etc.

 If toDB is nil then we fail (e.g. no primary catalog)
}
const routine=':ConnectToDB';
begin
  result:=fail;
  //todo assert/check that authId=InvalidAuthId, i.e. client is not already connected: continue anyway...
  if db<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is already connected to a db',vAssertion); 
    {$ENDIF}
    exit; //abort
  end;
  if toDB=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'No db available/specified for connection',vError); 
    {$ENDIF}
    exit; //abort
  end;
  result:=toDB.addTransaction(self); //todo check result=ok
  fdb:=toDB;
  //todo also set the transaction's catalogId here - based on the db just connected to - i.e. remove from TConnectionMgr.ssOnThreadStart routine
  result:=ok;
end; {connectToDB}

function TTransaction.DisconnectFromDB:integer;
const routine=':DisconnectFromDB';
var
  s:TStmt;
  sl:TPtrstmtList; //todo here: make into list...& protect!!!! +/- to allow safe reads!
begin
  result:=fail;
  //todo assert/check that authId=InvalidAuthId, i.e. client has disconnected: continue anyway...
  if db=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ENDIF}
    exit; //abort
  end;

  {First we close any remaining stmts, e.g. from a rudely terminated JDBC client}
  //todo: maybe this could go in the disconnect routine?
  //todo cs.beginRead
  sl:=stmtList;
  while sl<>nil do
  begin
    s:=sl^.sp;

    s.CloseCursor(1{=unprepare});
    //todo need to close the list as well: call removeStmt() to s.Free;

     sl:=sl^.next;
  end;

  result:=db.removeTransaction(self); //todo check result=ok
  fdb:=nil;
  result:=ok;
end; {disconnectFromDB}

function TTransaction.Who:string;
begin
  {$IFDEF DEBUG_LOG}
  if thread<>nil then
    result:=format('%8.8x)%10.10d:%10.10d',[TIDPeerThread(thread).ThreadId,fRt.tranId,fRt.stmtId]) //jkoz002:use currenthreadid instead to decouple the connection.
  else
  {$ENDIF}
    result:=format('%10.10d:%10.10d',[fRt.tranId,{n/a? we're tran-level:}fRt.stmtId]);
end;

function TTransaction.Before(CheckWt:StampId):boolean;
{Checks if this transaction's timestamp is earlier than the specified timestamp
 IN        : CheckWt       the W timestamp to compare with
 RETURN    : True=this transaction is earlier, else it's later or equal

 Note: this shouldn't be used as a visibility check  (e.g. reading)
       - use CanSee/CannotSee instead which takes account of active transactions
       (this one can be used (initially? may change) for update allowability checking)

       i.e. this is currently called to detect a serialisability-conflict
            which a tranId cannot do with itself, so I think we can safely
            ignore the stmtId's here...
}
const routine=':before';
begin
  if fRt.tranId<CheckWt.tranId then
    result:=True
  else
    //todo maybe check if = and stmtId<stmtId? //no need? since used by routines to check for concurrency conflicts
    //                                                         and a tran cannot conflict with itself:
    result:=False;
end; {Before}

function TTransaction.After(CheckWt:StampId):boolean;
{Checks if this transaction's timestamp is later than the specified timestamp
 IN        : CheckWt       the W timestamp to compare with
 RETURN    : True=this transaction is later, else it's earlier or equal
}
const routine=':after';
begin
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,'deprecated! - use CanSee/IsMe',vDebugError); 
  {$ELSE}
  ;
  {$ENDIF}
  if fRt.tranId>CheckWt.tranId then
    result:=True
  else
    //todo maybe check if = and stmtId>stmtId? //no need? since not used
    result:=False;
end; {After}

function TTransaction.RemoveUncommittedList(onlyRolledBackTrans:boolean):integer;
{Cleanup the uncommitted list
 IN:     onlyRolledBackTrans   True=only remove entries that are tsRolledBack or tsInProgress
                                    (i.e. leave partially rolled-back in list
                                     e.g. used when recovering)
                               False=remove all entries from list = cleanup
}
const routine=':removeUncommittedList';
var
  tranStatus:TtranStatusPtr;
  stmtStatus:TstmtStatusPtr;
begin
  result:=Fail;
  while uncommitted<>nil do
  begin
    tranStatus:=uncommitted;

    {If caller has asked to just delete rolled-back entries, then skip to next tranStatus}
    if onlyRolledBackTrans and (tranStatus.status<>tsRolledBack) and (tranStatus.status<>tsInProgress) then break;

    {Remove any rolled-back stmt list}
    while tranStatus.rolledBackStmtList<>nil do
    begin
      stmtStatus:=tranStatus.rolledBackStmtList;
      tranStatus.rolledBackStmtList:=tranStatus.rolledBackStmtList.next;
      dispose(stmtStatus);
      {$IFDEF DEBUG_LOG}
      {$IFDEF DEBUGDETAIL3}
      inc(debugStmtStatusDestroy);
      {$ENDIF}
      {$ENDIF}
      //todo have a rolledBackstmtCount on each tranStatus?
    end;

    uncommitted:=uncommitted.next;
    dispose(tranStatus);
    {$IFDEF DEBUG_LOG}
    {$IFDEF DEBUGDETAIL3}
    inc(debugTransStatusDestroy);
    {$ENDIF}
    {$ENDIF}
    dec(uncommittedCount);
  end;

  {Now clean the current stmtStatus list, unless caller has only asked for rolled-backs to be removed
   (in which case the list should always be empty anyway - todo assert!)}
  if not(onlyRolledBackTrans) then
  begin
    while rolledBackStmtList<>nil do
    begin
      stmtStatus:=rolledBackStmtList;
      rolledBackStmtList:=rolledBackStmtList.next;
      dispose(stmtStatus);
      {$IFDEF DEBUG_LOG}
      {$IFDEF DEBUGDETAIL3}
      inc(debugStmtStatusDestroy);
      {$ENDIF}
      {$ENDIF}
      dec(rolledBackStmtCount);
    end;
    if rolledBackStmtCount<>0 then
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,'rolled-back-stmt list count is not 0, even after removal of list members! continuing...',vAssertion); 
      {$ELSE}
      ;
      {$ENDIF}
      //todo return fail? else list will become a mess!!!
  end;

  if not(onlyRolledBackTrans) and (uncommittedCount<>0) then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'uncommitted list count is not 0, even after removal of list members!',vAssertion) 
    {$ENDIF}
  else
    result:=ok;
end; {removeUncommittedList}

function TTransaction.readUncommittedList:integer;
{Pseudo-starts a new transaction
 This is a bodge so a transaction can read system tables before starting a transaction
 e.g. needed for SET SCHEMA to read sysSchema and for CONNECT to read sysAuth
      without reading rolled-back rows.
 As soon as the tables have been read, the caller should removeUncommittedList
 ready for the real transaction.start.

 Note: we don't read any partially-rolled back details, nor do we set the tranId.
}
const routine=':readUncommittedList';
var
  sysTranR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
  noMore:boolean;
  tranStatus:TtranStatusPtr;
  getNull:boolean; //make global?
  nextTID:Integer;
  s:string;
begin
  result:=fail;

  if db=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ENDIF}
    exit; //abort
  end
  else
  begin
    //Note: code copied from transaction.start
    if db.catalogRelationStart(sysStmt,sysTran,sysTranR)=ok then
    begin
      try
        with (sysTranR as TRelation) do
        begin
              fearliestUncommitted:=MaxStampId;
              if scanStart(sysStmt)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,'Failed starting re-scan of sysTran',vDebugError);
                {$ENDIF}
                exit; //abort
              end;
              noMore:=False;
              while not noMore do
              begin
                if scanNext(sysStmt,noMore)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,'Failed re-scanning sysTran',vDebugError);
                  {$ENDIF}
                  exit; //abort
                end;
                if not noMore then
                begin //add this to the list
                  begin
                    fTuple.GetInteger(0,nextTID,getnull); //todo check result
                    fTuple.GetString(1,s,getnull); //todo check result

                    {todo:
                     if s=tsInProgress, we should now check if the transaction is still alive
                     - if it's not, we should set it to rolled-back now.
                     Check by querying each Ttransaction object (via dispatcher?) and seeing if any
                     matches this tran-id (or tick the reponses off from a list of tran-ids - bulk speed)
                    }

                    //todo use a binary tree instead => much faster probing...
                    //                                  currently we must look at every one to ensure thisWt is not in list
                    inc(uncommittedCount);
                    new(tranStatus);  //todo pre-allocate chunks...or use buffer pages?
                    {$IFDEF DEBUG_LOG}
                    {$IFDEF DEBUGDETAIL3}
                    inc(debugTransStatusCreate);
                    {$ENDIF}
                    {$ENDIF}
                    tranStatus.tid.tranId:=nextTID;
                    tranStatus.tid.stmtId:=MAX_CARDINAL-1; //todo is this ok for now? todo use const! is 0=as good? {todo:in future read stmtId as the last good Rt.stmtId reached = better algorithm}
                    if length(s)>0 then tranStatus.status:=s[1];
                    if tranStatus.tid.tranId<fearliestUncommitted.tranId then //store earliest to shortcut checking later
                      fearliestUncommitted:=tranStatus.tid;

                    tranStatus.rolledBackStmtList:=nil;

                    {if transaction is partially-rolled-back then we should read from sysTranStmt table...
                     but we don't for this bodge!...}

                    tranStatus.next:=uncommitted;
                    uncommitted:=tranStatus;  //Note: linked in reverse scan order: Head->3->2->1

                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Added tran-id %d [%s] entry into uncommitted list',[nextTID,s]),vdebugLow);
                    {$ENDIF}
                    {$ENDIF}
                  end;
                end;
              end; {while}
              if scanStop(sysStmt)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,'Failed stopping re-scan of sysTran',vDebugError);
                {$ENDIF}
                exit; //abort //todo continue?
              end;
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Read %d into uncommitted list (%d is earliest uncommitted)',[uncommittedCount,fearliestUncommitted.tranId]),vdebugMedium);
              {$ENDIF}
              result:=ok;
        end; {with}
      finally
        if db.catalogRelationStop(sysStmt,sysTran,sysTranR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTran
  end;

  //todo: do we need to refresh sysStmt/2 here as well?
end; {readUncommittedList}

function TTransaction.Start:integer;
{Starts a new transaction
 Reads the next Tid from the sysTran table (1st row is 'special'=NextTran)
 and then increments it ready for the next caller

 Also inserts a status entry for this new transaction into the sysTran table

 Note: fails if the db is missing (e.g. been killed, e.g. by close catalog)
       (unless we're a db creation transaction)
}
const routine=':start';
var
  getNull:boolean; //make global?
  nextTID:Integer;
  s:string;
  NextTranRID:TRid; //todo get from db header?
  noMore:boolean;
  tranStatus:TtranStatusPtr;
  stmtStatus:TstmtStatusPtr;
  n:integer;
  n_null:boolean;

  sysTranR,sysTranStmtR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
begin
  result:=fail;

  if fRt.tranId<>InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is still active - will rollback...',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}
    rollback(False);  //may want user to be able to switch this behaviour - no - too low level here
  end;

  //todo assert uncommittedCount=0 ! & rolledBackStmtCount=0 !
  //Note RemoveUncommittedList here (deferred from commit/rollback) so open cursors would still be ok
  RemoveUncommittedList(False);

  //todo: maybe we should be extra tidy and tran.clearConstraintList
  //      should be no need because commit/rollback should do this i.e. as early as possible to release memory
  //todo: at least assert list is empty! *

  {Note: we set stmtId=MAX so we can read initial NextTranRID which was written as 0:n during db creation}
  fRt.tranId:=0; fRt.stmtId:=MAX_CARDINAL-1;
  SynchroniseStmts(true);  //todo any need here?
  //todo here we could just set sysStmt.fRt.tranId=0 since that's what we use to read with?

  if db=nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Failed starting transaction - database missing',vdebugError);
    {$ENDIF}
    result:=fail;
    exit;
  end
  else
  begin
    //todo in future, db creation must add this & we would not need to scan
    //todo: call separate dispatcher (thread) to getNextTid = central semaphored bottleneck
    // - for now, (workaround?) we use a mutex...
    //todo - maybe move to db unit?

    //Note: this sysTran catalog relation is (and must remain) shared and ensures each
    //      transaction gets its own id with no multi-threading problems
    if db.catalogRelationStart(sysStmt,sysTran,sysTranR)=ok then
    begin
      try
        with (sysTranR as TRelation) do
        begin
    //      NextTranRID.pid:=InvalidPageId;
    //      NextTranRID.sid:=InvalidSlotId;

          //todo: it would be more elegant to use catalogfind wrapper routines here...
          // but aren't we at too low a level now?

          //todo really we should use a systran_generator to get the next tran
          //-would this be fast enough?
          // - need to get access to central sysGenerator, scan for

          if scanStart(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed starting scan of sysTran for 1st row',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          if scanNext(sysStmt,noMore)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed scanning sysTran for 1st row',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          if noMore then
          begin
            fTuple.clear(sysStmt);
            fTuple.SetInteger(0,1,false); //todo replace 1 with InitialTranId const?
            fTuple.SetString(1,tsHeaderRow,false);
            fTuple.insert(sysStmt,NextTranRID); //Note: obviously this bypasses any constraints
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Inserted initial NextTran entry into sysTran at %d:%d',[NextTranRID.pid,NextTranRID.sid]),vdebug);
            {$ELSE}
            ;
            {$ENDIF}
          end
          else
          begin
            NextTranRID:=fTuple.RID;
          end;
          if scanStop(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed stopping 1st row scan of sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          //todo else
          {Now update the NextTran}
          if fTuple.read(sysStmt,NextTranRID,False)<>ok then
          begin
            //error!
            //todo ok to leave fTID=MaxTranId ? makes sense? but ensure caller never uses!
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed reading initial NextTran entry from sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end
          else
          begin //get then set to update tuple columns... todo improve!
            if fTuple.GetInteger(0,NextTID,getNull)=ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Read NextTran entry as %d',[NextTID]),vdebugLow);
              {$ELSE}
              ;
              {$ENDIF}
              //todo increment atomically!
              fTuple.GetString(1,s,getNull); //todo check result
              fTuple.clear(sysStmt); //prepare to insert //todo crap way of updating!
              fTuple.SetInteger(0,NextTID+1,False); //todo check result
              fTuple.SetString(1,pchar(s),getNull); //todo check result
              fTuple.preInsert;
              {todo: I think maybe we should write row 1 with Tid=NextTid+1
                     then selecting from sysTran will only show ourself, i.e. no access to counter except by
                     privileged interal trans++
                     Tried, but became messy & broke - plan & try again
                            - had difficulty updating with Wt=Next with tid=Next+1 etc.
                            - may need to set fRecovery temporarily?
                     Also, when done, remember to remove check for ignore row=1 during scans
              }
              sysStmt.fRt.tranId:=0; sysStmt.fRt.stmtId:=0; //needed to be allowed to update row 1
              sysStmt.fWt.tranId:=0; sysStmt.fWt.stmtId:=0; //needed to be allowed to update row 1
              try
                if fTuple.UpdateOverwrite(sysStmt,NextTranRID)<>ok then
                begin
                  //error!
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,'Failed incrementing NextTran record',vDebugError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  exit; //abort
                end;
              finally
                //todo restore sysStmt.fRt/fWt(no need?) 
              end; {try}
              fRt.tranId:=NextTID; //int -> word - ok? todo make tranId=integer?
              fRt.stmtId:=0;
              fWt.tranId:=NextTID; //int -> word - ok? todo make tranId=integer?
              fWt.stmtId:=0;
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Tran ID set to %d:%d',[fRt.tranId,fRt.stmtId]),vdebugLow);
              {$ENDIF}
              SynchroniseStmts(true);
              {Now add the status row for this transaction
               Note: this insertion will have the Wt of this (self) transaction
               which is good cos no previous ones will see it...neat!}
              fTuple.clear(sysStmt);
              fTuple.SetInteger(0,fRt.tranId,false);  //self
              fTuple.SetString(1,tsInProgress,false);  //state
              fTuple.insert(sysStmt,frid); //store rid for later updates  //Note: obviously this bypasses any constraints
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Inserted transaction status entry into sysTran for %d',[fRt.tranId]),vdebug);
              {$ENDIF}
              {$ENDIF}

              {Crash protection: - ideally these two pages will be the same!}
              {Flush the new next transaction id to disk} //todo move this earlier, asap.
              (db.owner as TDBServer).buffer.flushPage(sysStmt,NextTranRID.pid,nil);  //todo use FlushAndKeep to avoid flush-fail on next call if pages are same
              //note: if we crash now (& on separate pages), a tran-id will never have been used - so what...-no problem
              {Flush the new transaction row to disk}
              (db.owner as TDBServer).buffer.flushPage(sysStmt,frid.pid,nil);

              {If this is the first tran id of the database session, set the offset for the committed array
               i.e. when this transaction commits, we will set db.tranCommitted[fRt.tranId-db.tranCommittedOffset] =[0]}
              if db.tranCommittedOffset=InvalidTranCommittedOffset then db.tranCommittedOffset:=fRt.tranId;
              if (fRt.tranId-db.tranCommittedOffset)>=db.tranCommitted.size then
              begin //need to increase array size
                //todo can we reclaim some existing space & is it worth the hassle? (if so, should we reclaim on commit/rolback/disconnect?)
                //e.g. if earliest active tranId-tranCommittedOffset is a decent size then
                //     we could shuffle down the committed arrays & remove any partial lists for trans in that range
                //     - do this by creating new copies of the 2 arrays + list and then flip them when ready & zap the old ones...
                //     for now, if we commit 1 transaction per second we could handle a 12 hour day with around 10K & because the access if subscripted=no performance loss...
                db.tranCommitted.size:=db.tranCommitted.size+TRAN_COMMITTED_ALLOCATION_SIZE;
              end;
              db.tranCommitted[fRt.tranId-db.tranCommittedOffset]:=False;
              db.tranPartiallyCommitted[fRt.tranId-db.tranCommittedOffset]:=False;

              {Read all inProgress/(part)rolledBack transactions into this transaction's uncommited list}
              //Note: even if another thread has just added another tran-id entry, we won't see it because we only
              //      see rows <= our TranId - neat!
              {Note: we ensure these calls ignore the list we're currently building because we must
                     read it before it goes on the list, so 1 pass will be fine! - neat!
              }
              fearliestUncommitted:=MaxStampId;
              if scanStart(sysStmt)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,'Failed starting re-scan of sysTran',vDebugError);
                {$ENDIF}
                exit; //abort
              end;
      {Open sub-transaction sysTranStmt relation}
      if db.catalogRelationStart(sysStmt,sysTranStmt,sysTranStmtR)=ok then
      begin
        try
              noMore:=False;
              while not noMore do
              begin
                if scanNext(sysStmt,noMore)<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,'Failed re-scanning sysTran',vDebugError);
                  {$ENDIF}
                  exit; //abort
                end;
                if not noMore then
                begin //add this to the list
                  if ((fTuple.RID.pid=NextTranRID.pid) and (fTuple.RID.sid=NextTranRID.sid)) or
                     ((fTuple.RID.pid=fRid.pid) and (fTuple.RID.sid=fRid.sid)) then
                  begin
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Ignoring tran-id row %d:%d for tran-id %d:%d - self or Next tran-id row',[fTuple.RID.pid,fTuple.RID.sid,fRt.tranId,fRt.stmtId]),vdebugLow);
                    {$ENDIF}
                    {$ENDIF}
                  end
                  else
                  begin
                    fTuple.GetInteger(0,nextTID,getnull); //todo check result
                    fTuple.GetString(1,s,getnull); //todo check result

                    {todo:
                     if s=tsInProgress, we should now check if the transaction is still alive
                     - if it's not, we should set it to rolled-back now.
                     Check by querying each Ttransaction object (via dispatcher?) and seeing if any
                     matches this tran-id (or tick the reponses off from a list of tran-ids - bulk speed)
                    }

                    //todo use a binary tree instead => much faster probing...
                    //                                  currently we must look at every one to ensure thisWt is not in list
                    inc(uncommittedCount);
                    new(tranStatus);  //todo pre-allocate chunks...or use buffer pages?
                    {$IFDEF DEBUG_LOG}
                    {$IFDEF DEBUGDETAIL3}
                    inc(debugTransStatusCreate);
                    {$ENDIF}
                    {$ENDIF}
                    tranStatus.tid.tranId:=nextTID;
                    tranStatus.tid.stmtId:=MAX_CARDINAL-1; //todo is this ok for now? todo use const! is 0=as good? {todo:in future read stmtId as the last good Rt.stmtId reached = better algorithm}
                    if length(s)>0 then tranStatus.status:=s[1];
                    if tranStatus.tid.tranId<fearliestUncommitted.tranId then //store earliest to shortcut checking later
                      fearliestUncommitted:=tranStatus.tid;

                    tranStatus.rolledBackStmtList:=nil;

                    {if transaction is partially-rolled-back then read from sysTranStmt table all
                     rolled-back stmts for this tranId into list linking to this node (so we can ignore their data)}
                    if tranStatus.status=tsPartRolledBack then
                    begin
                   //leaving sysTran code...
            if db.findFirstCatalogEntryByInteger(sysStmt,sysTranStmtR,0{todo use const!},tranStatus.tid.tranId)=ok then
              try
                repeat
                  {Found another matching column for this relation}
                  with (sysTranStmtR as TRelation) do
                  begin
                    fTuple.GetInteger(1{todo use const!},n,n_null); //assume never null

                    //todo have a rolledBackStmtCount per rolled-back-history list?
                    new(stmtStatus);  //todo pre-allocate chunks...or use buffer pages?
                    {$IFDEF DEBUG_LOG}
                    {$IFDEF DEBUGDETAIL3}
                    inc(debugStmtStatusCreate);
                    {$ENDIF}
                    {$ENDIF}
                    stmtStatus.tid.tranId:=tranStatus.tid.tranId; //todo .tranId not currently used
                    stmtStatus.tid.stmtId:=n;
                    stmtStatus.next:=tranStatus.rolledBackStmtList;
                    tranStatus.rolledBackStmtList:=stmtStatus;  //Note: linked in reverse scan order: Head->3->2->1

                    {$IFDEF DEBUGDETAIL2}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Added stmt-id %d:%d entry into rolled-back list for %d',[stmtStatus.tid.tranId,stmtStatus.tid.stmtId,fRt.tranId]),vdebugLow);
                    {$ENDIF}
                    {$ENDIF}
                  end; {with}
                until db.findNextCatalogEntryByInteger(sysStmt,sysTranStmtR,0{todo use const!},tranStatus.tid.tranId)<>ok;
                      //todo stop once we're past our tranId if sysTranStmt is sorted... -speed - this logic should be in Find routines...
              finally
                if db.findDoneCatalogEntry(sysStmt,sysTranStmtR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysTranStmt)]),vError); //todo abort?
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}

                   //...continue with sysTran code
                    end;

                    tranStatus.next:=uncommitted;
                    uncommitted:=tranStatus;  //Note: linked in reverse scan order: Head->3->2->1

                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Added tran-id %d [%s] entry into uncommitted list for %d:%d',[nextTID,s,fRt.tranId,fRt.stmtId]),vdebugLow);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    {$ENDIF}
                  end;
                end;
              end; {while}
        finally
          if db.catalogRelationStop(sysStmt,sysTranStmt,sysTranStmtR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTranStmt)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysTranStmt
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Unable to access catalog relation %d',[ord(sysTranStmt)]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}
      end;
              if scanStop(sysStmt)<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,'Failed stopping re-scan of sysTran',vDebugError);
                {$ENDIF}
                exit; //abort //todo continue?
              end;
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Started transaction %d with %d in uncommitted list (%d is earliest uncommitted)',[fRt.tranId,uncommittedCount,fearliestUncommitted.tranId]),vdebugMedium);
              {$ENDIF}
              result:=ok;
            end
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,'Failed reading initial NextTran number from sysTran',vdebugError);
              {$ENDIF}
              exit; //abort
            end;
          end;

        end; {with}
      finally
        if db.catalogRelationStop(sysStmt,sysTran,sysTranR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTran
  end;

  (*todo moved further in to ensure tran-row can be updated by same tran
  //ensure sysStmts keep up: todo any more places we need to synch. these???
  sysStmt.fRt:=self.fRt;
  sysStmt2.fRt:=self.fRt;
  //we should ensure any stmts hanging off this transaction are also updated here
  //i.e. StmtScanStart ..next ..stop
  //(& then remove auto-initiating code in processing modules to do this)
  //++ NO: the whole point is that we can leave open user cursors alone!
  //++ YES!: we still leave them open but must increment all tranIds to keep sane
  //            ... still gives unpredictable results, but more reasonable
  *)
  //+++ BUT: ODBC: create conn + stmt then start tran implicitly on stmt => update stmt.Rt/Wt after conn.start
end; {start}

function TTransaction.Reset:integer;
{Reset transaction status to undo temporary 1-transaction-lifetime settings
 (e.g. called after commit and rollback)
 (If there was a Transaction.Stop, this would be it)
}
var
  cOverride:TconstraintTimeOverridePtr;
begin
  result:=ok;

  {Revert back to default isolation level ready for next transaction}
  isolation:=DefaultIsolation;

  {Remove any constraint overrides}
  while constraintTimeOverride<>nil do
  begin
    cOverride:=constraintTimeOverride;
    constraintTimeOverride:=cOverride.next;
    dispose(cOverride);
  end;
end; {reset}

function TTransaction.Commit(st:Tstmt):integer;
{IN:     st   - stmt - used to return error messages, e.g. deferred constraint failed

 Note:
     this routine (and rollback) should be very safe,
     i.e. no exceptions should prevent them from completing
     (although this commit may call rollback if desperate
      => not truly committed until commit returns ok)
}
const routine=':commit';
var
  sysTranR,sysTranStmtR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
  stmtStatus:TstmtStatusPtr;
  rolledBackWritten:integer;
  rid:Trid;
  //nextNode:TtranNodePtr;
  nextNode:TPtrstmtList;
begin
  result:=Fail;

  {if not inProgress then nothing to do}
  if fRt.tranId=InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not active - cannot commit...',vDebugError); 
    {$ENDIF}
    result:=ok; //don't error in case client does this
    exit; //skip
  end;

  if db=nil then //todo remove for speed
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ENDIF}
    exit; //abort
  end;

  //todo remove: debug log only
  self.constraintList.listChain(st);

  //todo* check tran level constraints (only ones here should be ctTran)
  //         (we will see everything that this transaction has changed - should restrict to this=speed)
  //         Note: we should ignore any that were added by rolled-back stmts
  //               (or better if stmt.rollback does this for us = early, but maybe not guaranteed!?)
  // - if any fail, call tr.rollback instead & return fail
  if (self.constraintList as Tconstraint).checkChain(st,nil{iter n/a},ctTran,ceBoth)<>ok then
  begin
    {Emergency rollback transaction!
     This is nasty, but it's what the spec. says!
     (the user should 'set all immediate' first and test if it succeeds -
      then user has control/info over whether to rollback)}
    result:=Rollback(False);
    //todo report error here if result<>ok, i.e. emergency rollback failed! - unlikely!?
    result:=fail; //even though rollback succeeded
    exit; //abort the transaction commit
  end;

  {Remove any tran level constraints}
  self.constraintList.clearChain;

  {Close any non-hold cursors}
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if (nextNode^.sp.stmtType=stUserCursor)
      and not(nextNode^.sp.planHold)
      then
      begin //found a match
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('non-hold cursor stmt found %d in stmtlist %p',[longint(nextNode^.sp),stmtList]),vDebugLow); //todo remove! no point!?
        {$ENDIF}
        nextNode^.sp.closeCursor(1{=unprepare});
        //todo clean up this stmt entry?
        //todo need to close the list as well: call removeStmt() to nextNode^.sp.Free;
      end;

      nextNode:=nextNode^.next;
    end;
    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}

  {If this transaction has some rolled-back stmts then we must write them to sysTranStmt for
   use by future transactions (todo in future: except any that are after Rt.stmtId)
   (todo in future: If they are all after Rt.stmtId then we can continue with a normal
    total-commit since we could write the Rt.stmtId for future tran CanSee use
    = save disk-read-write-list space & time if last run of stmts were rolled-back)
   (todo in future: If they are all after Rt.stmtId then if Rt.stmtId=0 then
    every stmt was rolled back, so maybe we can forget the commit and just rollback
    the whole transaction here? Safe? Although at the moment a commit of nothing is cheaper
    than a rollback since less storage for future transactions)

    todo+ remove any duplicates (could be added when a cascading chain fails)
  }
  rolledBackWritten:=0;
  if (rolledBackStmtList<>nil) then
  begin

    stmtStatus:=rolledBackStmtList;
    if db.catalogRelationStart(sysStmt,sysTranStmt{todo replace with st?},sysTranStmtR)=ok then
    begin
      try
        with (sysTranStmtR as TRelation) do
        begin
          while stmtStatus<>nil do
          begin
            //todo not used until future use: if stmtStatus.tid.stmtId<fRt.stmtId then //Note: can never check if =, since only Stmtcommit updates, stmtRollback doesn't
            begin
              {Write this stmtId to sysTranStmt}
              fTuple.clear(sysStmt);
              fTuple.SetInteger(0,stmtStatus.tid.tranId,false);  //self
              fTuple.SetInteger(1,stmtStatus.tid.stmtId,false);
              fTuple.insert(sysStmt,rid);  //Note: obviously this bypasses any constraints
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Inserted transaction rolled-back stmt entry into sysTranStmt for %d:%d',[stmtStatus.tid.tranId,stmtStatus.tid.stmtId]),vdebugLow);
              {$ENDIF}

              inc(rolledBackWritten);
            end;
            stmtStatus:=stmtStatus.next;
          end;
        end; {with}
      finally
        if db.catalogRelationStop(sysStmt,sysTranStmt{todo replace with st?},sysTranStmtR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTranStmt)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTranStmt

    //todo future note: (I suppose a quicker/pre check might be if (rolledBackStmtCount=Wt.stmtId-Rt.stmtId) then all in list are rolled-back)?
    if rolledBackWritten>0 then
    begin //we have noted some stmtIds as rolled-back, so we must partially-rollback (=partially-commit!) this transaction
//     {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('%d stmts were rolled back & since %d needed to be noted, we can only partially commit this transaction %d:%d',[rolledBackStmtCount,rolledBackWritten,tranRt.tranId,tranRt.stmtId]),vDebugLow);
      {$ENDIF}
//      {$ENDIF}
      result:=Rollback(True); //Note: this will also tidy this transaction properly
    end
    else
    begin //we didn't need to note any stmtIds as rolled-back, so we can continue and totally-commit this transaction
//     {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('%d stmts were rolled back but none needed to be noted, so we can totally commit this transaction %d:%d',[rolledBackStmtCount,tranRt.tranId,tranRt.stmtId]),vDebugLow);
      {$ENDIF}
//      {$ENDIF}
    end;
  end;

  if rolledBackWritten=0 then
  begin //we now do a standard full commit
    //todo: what if user tries to re-use after we've committed? set tid=-1!? self.destroy?
    if db.catalogRelationStart(sysStmt,sysTran{todo replace with st?},sysTranR)=ok then
    begin
      try
        with (sysTranR as TRelation) do
        begin
          {Crash protection:}
          //todo: if we crash now, this tran-id will be rolled-back on restart - seems ok?
          {Flush the deleted transaction row to disk}
          //todo: before we flush this, we must ensure all pages dirtied by this tran have been flushed!
          //      for now, we must flush all dirty pages! - improve! - speed!
          //todo+: note that we may have used a page dirtied by another transaction indirectly
          //       and we must ensure we flush that page in case the other transaction rollsback
          //       - especially:
          //           dirPage:         we may have added a page to the directory- flush the dir page
          //                            we may have added a new dir page- flush the prev + new dir pages
          //                            (ok because we would dirty these pages?)
          //           allocation:      we may have allocated catalog pages- flush the catalog page map
          //                            (ok because we dirtied it?)
          //           heapfile chains: we may have added a page and linked back to an existing page
          //                            (I think we would have dirtied it, so should be ok)
          //           data pages:      we may have dirtied a page that was allocated by another
          //                            - flush all allocation pages to be sure? i.e. look at page type
          //           index pages:     what if another thread doubles the directory & we add to it but the other rollsback?
          // - certainly its safe to flush everything for now...
          //Note also: if we crash, allocations will be lost but we should be ok to continue? (just orphaned pages?)
          (db.owner as TDBServer).buffer.flushAllPages(sysStmt);

          //todo: if we crash now, this tran-id will be rolled-back on restart - seems ok?

          {Delete this rid entry in the sysTran table => committed}
          //todo ensure if not isMe that we are warned: versioning here would be bad
          sysStmt.fWt.stmtId:=0; //needed to be allowed to delete by ensuring isMe matches original record to avoid versioning: fix 06/05/03
          result:=fTuple.delete(sysStmt{!},frid); //Note: delete by self=obliterate (i.e. don't version!)
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Failed committing transaction',[nil]),vAssertion); 
            {$ENDIF}
            //todo try to rollback - better than nothing?
            exit;
          end;

          (db.owner as TDBServer).buffer.flushPage(sysStmt,frid.pid,nil);
          //Note: we are now committed (if we can trust the OS/disk)

          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Committed tran-id %d:%d at %d:%d',[fRt.tranId,fRt.stmtId,frid.pid,frid.sid]),vdebug);
          {$ENDIF}

          {Now inform any active read-committed transactions that we're now committed}
          //Note: in future we could traverse all active transactions and if they are > us and are read-committed
          //      then we could remove ourself from their uncommitted list (safely by setting status=C or something)
          //      but for now, we'll use the common committed array & make this override any existing list entries...
          //      (only advantage in modifying lists might be to help keep committed array smaller?? - also could reduce list sizes substantially - especially partially-committed stmt lists & we'll duplicate them anyway!)
          db.tranPartiallyCommitted[fRt.tranId-db.tranCommittedOffset]:=False;
          db.tranCommitted[fRt.tranId-db.tranCommittedOffset]:=True;


          frid.pid:=InvalidPageId; //don't try to re-use!
          frid.sid:=InvalidSlotId; //don't try to re-use!
          //Note: defer RemoveUncommittedList until next tran.start (or destroy) so open cursors are still ok
          //           + synchroniseStmts(FALSE!)

          fRt:=InvalidStampId; //de-activate
          fWt:=InvalidStampId; //de-activate
          SynchroniseStmts(false);
          result:=ok;
        end; {with}
      finally
        if db.catalogRelationStop(sysStmt,sysTran{todo replace with st?},sysTranR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTran
  end;

  {Revert back to initial settings}
  Reset;

  (*
  if ok:
  Note: need to store tran info before above (& rollback call) zeroised it! including rolledBackStmtList!
  todo: for all current transactions (for this db):
      if isolation=isReadCommitted then
        if wt>self then
          notify future tran that previous inProgress (us) is now committed
          - i.e. remove us from it's uncommitted list
        else
          if wt<self then
            update central committed-array so older trans can refer to it & see that we have committed
            - i.e. older ones must refer to this central list if they are read-committed & meet future records
            Note: this array needs to be augmented by a rolledBackStmtList-committed-array/list
  *)
end; {commit}

function TTransaction.Rollback(onlyPartial:boolean):integer;
{IN                                                                             
         onlyPartial:   False=normal rollback
                        True=use tsPartRolledBack => partially-committed
                             Assumes caller has added stmt-rolled-back list to disk

 todo: replace onlyPartial with generic SetTranStatus(tsRolledBack).. etc
}
const routine=':rollback';
var
  curTid:integer;
  s:string;
  getnull:boolean;

  sysTranR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
  stmtStatus:TstmtStatusPtr;

  tranStatus:TtranStatusPtr;
  stmtStatusCopy:TstmtStatusPtr;

  nextNode:TPtrstmtList;
begin
  result:=fail;

  {if not inProgress then nothing to do}
  if fRt.tranId=InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not active - cannot rollback...',vDebugError); //todo ignore!?
    {$ELSE}
    ;
    {$ENDIF}
    result:=ok; //don't error in case client does this
    exit; //skip
  end;

  if db=nil then //todo remove for speed
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {Remove any tran level constraints}
  self.constraintList.clearChain;

  {Close any cursors} //todo: also close any open user cli cursors/stmts?
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if (nextNode^.sp.stmtType=stUserCursor)
      and not(nextNode^.sp.planHold)
      then
      begin //found a match
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('non-hold cursor stmt found %d in stmtlist %p',[longint(nextNode^.sp),stmtList]),vDebugLow); //todo remove! no point!?
        {$ENDIF}
        nextNode^.sp.closeCursor(1{=unprepare});
        //todo clean up this stmt entry?
        //todo need to close the list as well: call removeStmt() to nextNode^.sp.Free;
      end;

      nextNode:=nextNode^.next;
    end;
    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}

  //todo?: if fWT=0 (or better if fRt-fWt<=0) then Commit instead of Rollback
  //       = more efficient! less overhead for new trans - speed, especially since most(?) are read-only!

  //todo: what if user tries to re-use after we've commited? set tid=-1!? self.destroy?
  if db.catalogRelationStart(sysStmt,sysTran{todo replace with st?},sysTranR)=ok then
  begin
    try
      with (sysTranR as TRelation) do
      begin
        {Now update the existing tran}
        if fTuple.read(sysStmt,fRID,False)<>ok then
        begin
          //error!
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'Failed reading tran entry from sysTran',vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort TODO pass back error to caller!
        end
        else
        begin //get then set to update tuple columns... todo improve!
          if fTuple.GetInteger(0,curTid,getNull)=ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Read tran entry as %d',[curTid]),vdebugLow);
            {$ENDIF}
            if curTid<>fRt.tranId then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Should have read tran entry as %d, not %d',[fRt.tranId,curTid]),vAssertion); 
              {$ENDIF}
              exit; //abort
            end;

            {Crash protection:}
            //todo: if we crash now, this tran-id will be rolled-back on restart anyway - seems ok?
            {Flush the deleted transaction row to disk}
            //todo: before we flush this, we *don't* have to ensure all pages dirtied by this tran have been flushed!? good!
            //unless...
            if onlyPartial then
            begin //we need to ensure we flush the partially committed records!
              //todo: before we flush this, we must ensure all pages dirtied by this tran have been flushed! *********** how?
              //      for now, we must flush all dirty pages! - improve! - speed!
              (db.owner as TDBServer).buffer.flushAllPages(sysStmt);
            end;

            if True then
            begin //flag needs recording if partial=special case or if we may have done any writing (else we could save a tran slot & effectively do a commit)
              //todo update atomically! ??no need?
              fTuple.GetString(1,s,getNull); //todo check result //todo assert=inProgress!? else something wierd happened, e.g. recovery called while active clients...?
              fTuple.clear(sysStmt); //prepare to insert //todo crap way of updating!
              fTuple.SetWt(fRt); //we need to re-set this before the Update below //Note: we also save the latest Rt.stmtId here=needed (to save time in CanSee)
              fTuple.SetInteger(0,curTid,False); //todo check result
              if onlyPartial then
                fTuple.SetString(1,tsPartRolledBack,getNull) //todo check result
              else
                fTuple.SetString(1,tsRolledBack,getNull); //todo check result
              fTuple.preInsert;
              if fTuple.UpdateOverwrite(sysStmt,fRID)<>ok then
              begin
                //error!
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,'Failed updating tran record',vDebugError);
                {$ENDIF}
                exit; //abort todo pass back error to caller!
              end;
            end
            else //todo: enable this section... i.e. avoid a Select + Disconnect from wasting a tran slot
            begin //we have done nothing that needs a rollback record so zap our tran entry so it can be re-used
              //note: we don't carry through this logic to the in-memory logs below: ok?
              {Delete this rid entry in the sysTran table => effectively committed}
              //todo ensure if not isMe that we are warned: versioning here would be bad
              sysStmt.fWt.stmtId:=0; //needed to be allowed to delete by ensuring isMe matches original record to avoid versioning: fix 06/05/03
              result:=fTuple.delete(sysStmt{!},frid); //Note: delete by self=obliterate (i.e. don't version!)
              if result<>ok then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,format('Failed rolling back transaction via commit-style overwrite',[nil]),vAssertion); 
                {$ENDIF}
                //todo try to rollback - better than nothing?
                exit;
              end;

              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Committed ineffective rolled-back tran-id %d:%d at %d:%d',[fRt.tranId,fRt.stmtId,frid.pid,frid.sid]),vdebug);
              {$ENDIF}
            end;

            //todo we could not flush here if not onlyPartial - no need !! speed!
            (db.owner as TDBServer).buffer.flushPage(sysStmt,frid.pid,nil);

            if onlyPartial then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Part-rolled-back tran-id %d:%d at %d:%d',[fRt.tranId,fRt.stmtId,frid.pid,frid.sid]),vdebug);
              {$ENDIF}

              {Now inform any active read-committed transactions that we're now (partially) committed}
              //Note: in future we could traverse all active transactions and if they are > us and are read-committed
              //      then we could remove ourself from their uncommitted list (safely by setting status=r or something)
              //      but for now, we'll use the common committed array & make this override any existing list entries...
              //      (only advantage in modifying lists might be to help keep committed array smaller??)
              {Store a copy of the stmt-rollback list in tranPartiallyCommittedDetails}
              //todo? inc(tranPartiallyCommittedDetailsCount);
              new(tranStatus);  //todo pre-allocate chunks...or use buffer pages?
              {$IFDEF DEBUG_LOG}
              {$IFDEF DEBUGDETAIL3}
              inc(debugTransStatusCreate);
              {$ENDIF}
              {$ENDIF}
              tranStatus.tid.tranId:=fRt.tranId;
              tranStatus.tid.stmtId:=fRt.stmtId; //Note: we also save the latest Rt.stmtId here=needed (to save time in CanSee)
              tranStatus.status:=tsPartRolledBack;
              tranStatus.rolledBackStmtList:=nil;
              {Add stmt details}
              stmtStatus:=rolledBackStmtList;
              while stmtStatus<>nil do
              begin
                //todo not used until future use: if stmtStatus.tid.stmtId<fRt.stmtId then //Note: can never check if =, since only Stmtcommit updates, stmtRollback doesn't
                begin
                  //todo have a rolledBackStmtCount per rolled-back-history list?
                  new(stmtStatusCopy);  //todo pre-allocate chunks...or use buffer pages?
                  {$IFDEF DEBUG_LOG}
                  {$IFDEF DEBUGDETAIL3}
                  inc(debugStmtStatusCreate);
                  {$ENDIF}
                  {$ENDIF}
                  stmtStatusCopy.tid.tranId:=stmtStatus.tid.tranId; //todo .tranId not currently used
                  stmtStatusCopy.tid.stmtId:=stmtStatus.tid.stmtId;
                  stmtStatusCopy.next:=tranStatus.rolledBackStmtList;
                  tranStatus.rolledBackStmtList:=stmtStatusCopy;  //Note: linked in reverse scan order: Head->3->2->1
                end;
                stmtStatus:=stmtStatus.next;
              end;
              tranStatus.next:=db.tranPartiallyCommittedDetails;
              db.tranPartiallyCommittedDetails:=tranStatus; //Note: linked in reverse order: ->3->2->1

              db.tranPartiallyCommitted[fRt.tranId-db.tranCommittedOffset]:=True;
              db.tranCommitted[fRt.tranId-db.tranCommittedOffset]:=True;
            end
            else
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Rolled-back tran-id %d:%d at %d:%d',[fRt.tranId,fRt.stmtId,frid.pid,frid.sid]),vdebug);
              {$ELSE}
              ;
              {$ENDIF}

              {Now inform any active read-uncommitted transactions that we're now rolled-back}
              //Note: in future we could traverse all active transactions and if they are > us and are read-uncommitted
              //      then we could update our status in their uncommitted list (safely by setting status=R or something)
              //      but for now, we'll use the common committed array & make this override any existing list entries...
              //      (only advantage in modifying lists might be to help keep committed array smaller?? - also could reduce list sizes substantially - especially partially-committed stmt lists & we'll duplicate them anyway!)
              db.tranPartiallyCommitted[fRt.tranId-db.tranCommittedOffset]:=True;
              db.tranCommitted[fRt.tranId-db.tranCommittedOffset]:=False;
            end;
            frid.pid:=InvalidPageId; //don't try to re-use!
            frid.sid:=InvalidSlotId; //don't try to re-use!
            //Note: defer RemoveUncommittedList until next tran.start (or destroy) so open cursors are still ok
            //           + synchroniseStmts(FALSE!)

            fRt:=InvalidStampId; //de-activate
            fWt:=InvalidStampId; //de-activate
            SynchroniseStmts(false);
            result:=ok;
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed reading tran number from sysTran',vdebugError);
            {$ENDIF}
            exit; //abort
          end;
        end;
      end; {with}
    finally
      if db.catalogRelationStop(sysStmt,sysTran{todo replace with st?},sysTranR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end;
  //todo else error - couldn't get access to sysTran

  {Revert back to initial settings}
  Reset;
end; {rollback}

function TTransaction.Connect(Username:string;Authentication:string):integer;
{

 //todo should this routine add a new stmt - or do we leave that to caller?
 // - but can we have more than 1 connection per transaction - I don't think so...

 Note: if this routine fails, we leave the current connection settings alone (for now)
       //maybe in future we should reset them to Invalid?

       Since we haven't yet started a transaction, we temporarily read an uncommitted
       transaction (not sub-stmt) list & read sysAuth using that. We then discard it.

 RETURNS:  ok = authorised & connected
           -2 = unknown username/auth_name
           -3 = wrong authentication/password
           -4 = could not access sysAuth (e.g. database not started)
           -5 = too many connections already (i.e. licence limitation reached)
           else, fail
}
const
  routine=':connect';
  badUsername=-2;
  badPassword=-3;
  badCatalogAccess=-4;
  badConnectionCount=-5;
var
  sysAuthR,sysSchemaR:TObject; {TRelation;} 
  Auth_Id,default_catalog_id,default_schema_id,schemaId_auth_Id:integer;
  auth_Type,password:string;
  schema_name,auth_name:string;
  auth_admin_role:integer;
  auth_Id_null,auth_Type_null,password_null,default_catalog_id_null,default_schema_id_null,schemaId_auth_Id_null,schema_name_null,auth_name_null,auth_admin_role_null:boolean;
  dummy_null:boolean;
  saveStmtId:StampId;
  lt:integer; //connectionLimit
  noMore:boolean;
  otherTr:TObject;
  label le;
begin
  result:=fail;
  if db=nil then //todo remove for speed
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ENDIF}
    exit; //abort
  end;

  {Check that we haven't reached the server's connection limit}
  lt:=cardinal(self); //random input to check for tampering
  if (db.owner as TDBServer).licence.maxConnections>0 then
    if ((db.owner as TDBServer).ip(lt{side-effect overwrites})<>cardinal(self)) or {BSS assumed}(lt>={todo remove = to allow for self in count!?}(db.owner as TDBServer).licence.maxConnections) then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Transaction connection rejected: we already have %d and maximum is %d',[lt,(db.owner as TDBServer).licence.maxConnections]),vError);
      {$ENDIF}

      //todo: allow the connection if we are to be the only ADMIN?

      result:=badConnectionCount;
      goto le; //exit
    end;
  {Check that we have a licence}
  if (db.owner as TDBServer).licence.maxConnections<0 then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Transaction connection rejected: we have no licence',[nil]),vError);
    {$ENDIF}

    result:=badConnectionCount;
    goto le; //exit
  end;

  saveStmtId:=sysStmt.fRt; //should always be InvalidTranId, except for when creating db & information schema
  sysStmt.fRt:=MaxStampId; //ensure we see all entries in system tables (we have to fake our id because we are not in a transaction yet)
  {We haven't started a transaction yet but we need to avoid rolled-back sysAuth rows so we temporarily read them}
  if saveStmtId.tranId=InvalidStampId.tranId then readUncommittedList; //note: check result: currently we chance it even if this fails: better than nothing: risk=read rolled-back default-schema: still connects!
  try
    if db.catalogRelationStart(sysStmt,sysAuth,sysAuthR)=ok then
    begin
      try
        if (sysAuthR as Trelation).tableId=0 then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError); 
          {$ENDIF}
          result:=badCatalogAccess;
          exit;
        end;

        if db.findCatalogEntryByString(sysStmt,sysAuthR,ord(sa_auth_name),UserName)=ok then
        begin
          with (sysAuthR as TRelation) do
          begin
            fTuple.GetInteger(ord(sa_auth_id),Auth_Id,auth_Id_null);
            fTuple.GetString(ord(sa_auth_type),auth_Type,auth_Type_null);
            fTuple.GetString(ord(sa_password),password,password_null);
            fTuple.GetInteger(ord(sa_default_catalog_id),default_catalog_id,default_catalog_id_null);
            fTuple.GetInteger(ord(sa_default_schema_id),default_schema_id,default_schema_id_null);
            fTuple.GetString(ord(sa_auth_name),auth_name,auth_name_null);
            fTuple.GetInteger(ord(sa_admin_role),auth_admin_role,auth_admin_role_null);
            //we don't need to read sa_admin_option yet

            //todo check authType=atUser? fail if atRole? Standard says we default to something if it's a role...
            //todo also fail is password_null? => cannot connect?
            //todo (also?) fail if username=PUBLIC! seInvalidAuth (check above will catch this)
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Found auth %s (%s) in %s with type=%s and admin_role=%d',[UserName,auth_name,sysAuth_table,auth_Type,auth_admin_role]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end; {with}
        end
        else //auth_id not found
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown auth_id %s',[UserName]),vDebugLow);
          {$ENDIF}
          result:=badUsername;
          exit;
        end;
      finally
        if db.catalogRelationStop(sysStmt,sysAuth,sysAuthR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysAuth)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysAuth
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Unable to access catalog relation %d',[ord(sysAuth)]),vDebugError); 
      {$ENDIF}
      result:=badCatalogAccess;
      exit;
    end;

    {We found a user: check password}
    //todo we need to check via a secured encrypt routine...
    //e.g. calculate one-time unique code & store that as password
    //     then to verify, run password-try through same algorithm & compare
    //     i.e. we never store the password, not even in memory!
    if not password_null then //todo temporary to save keystrokes when testing!
      if Authentication<>password then //todo case sensitive etc.!?
      begin
        //todo: applies to all user-errors in this unit: re-use the se...Text for the internal log messages! -save space!
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Mismatching password',[nil]),vDebugLow);
        {$ENDIF}
        result:=BadPassword;
        //todo be extra secure: i.e. don't let on that user-id was found!: result:=fail;
        exit;
      end;

    {We found a valid user}
    {Ok, user is authorised...}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Connected as auth:%d default-schema:%d',[auth_Id,default_schema_id]),vDebugLow);
    {$ENDIF}
    //assumes these can never be null! todo: should assert auth_Id_null=False etc.!
    //todo prove/assert we can never get here unless validated! i.e. set result:=ok earlier & protect this with 'if result<>ok then assertion-fail'
    authID:=auth_Id;
    authName:=auth_Name; //store the name for future user-functions
    catalogID:=default_catalog_id; //todo or shouldn't we set to our own catalog_id - i.e get from th.tr.db
    catalogName:=db.dbName;
    schemaID:=default_schema_id;
    authAdminRole:=TadminRoleType(auth_admin_role); //todo protect cast from garbage!
    {We check the default schema (still) exists (to set schemaId_authId)
     - we also lookup its owner & name because we sometimes need to default a relation.open authId to these
       if no schema has been specified, i.e. we use current schema & so must use its owner authId
       (this is needed for GRANT ownership rights checking)
      Note++: this might not be needed/important now: we re-lookup the table's schema owner during relation.Open
    }
    if db.catalogRelationStart(sysStmt,sysSchema,sysSchemaR)=ok then
    begin
      try
        if db.findCatalogEntryByInteger(sysStmt,sysSchemaR,ord(ss_schema_id),default_schema_id)=ok then
        begin
          with (sysSchemaR as TRelation) do
          begin
            fTuple.GetInteger(ord(ss_auth_id),schemaId_auth_Id,schemaId_auth_Id_null);
            schemaId_authId:=schemaId_auth_Id; //set the value
            fTuple.GetString(ord(ss_schema_name),schema_Name,schema_Name_null);
            fschemaName:=schema_Name; //set the value
            fTuple.GetInteger(ord(ss_schema_version_major),fSchemaVersionMajor,dummy_null);
            fTuple.GetInteger(ord(ss_schema_version_minor),fSchemaVersionMinor,dummy_null);
  //                  {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Found default schema (%d) %s owner=%d',[default_schema_Id,schemaName,schemaId_authId]),vDebugLow);
            {$ENDIF}
  //                  {$ENDIF}
          end; {with}
        end
        else
        begin  //schema not found
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Unknown default schema %d',[default_schema_Id]),vError);
          {$ENDIF}
          exit; //abort //todo continue... not a big deal? means can't GRANT when we should be able to, but if schema not found then maybe we shouldn't be able to!
        end;
      finally
        if db.catalogRelationStop(sysStmt,sysSchema,sysSchemaR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError); //todo abort? fix! else possible server crunch?
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysSchema
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Unable to access catalog relation %d to find %d',[ord(sysSchema),default_schema_id]),vDebugError); 
      {$ENDIF}
      exit; //abort //todo continue... not a big deal? means can't GRANT when we should be able to, but if schema not found then maybe we shouldn't be able to!
    end;
  finally
    if saveStmtId.tranId=InvalidStampId.tranId then removeUncommittedList(False);
    sysStmt.fRt:=saveStmtId; //restore tran id //should always be InvalidTranId, except for when creating db & information schema
  end; {try}

  result:=ok;
  le:
  asm
    nop
    nop
  end;
end; {connect}

function TTransaction.Disconnect:integer;
{This disconnects the user
 i.e. leaves the thread-connection open but from the user's point of view
      closes the Connect function defined above.

 Note: this was written for a direct SQL client's explicit DISCONNECT command
       ODBC clients use another method... (mainly controlled by client/driver)

       //todo: if this works well, we should/could centralise disconnection steps & use this everywhere...

 RETURNS:  ok = disconnected
           else, fail
}
const
  routine=':disconnect';
begin
  result:=fail;
  if db=nil then //todo remove for speed
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not connected to a db',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end;

  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Currently connected as auth:%d schema:%d',[fauthId,fschemaId]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}

  //todo only rollback if tid<>InvalidTranId, i.e. we have an active transaction
  rollback(False); //todo customisable - maybe commit instead?
                                   //todo cleaner to commit!

  //todo finally! to ensure we reset this lot...
  fAuthId:=InvalidAuthId;
  fAuthName:='';
  fSchemaId:=0;
  fSchemaName:='';
  fSchemaVersionMajor:=-1;
  fSchemaVersionMinor:=-1;
  fCatalogId:=0; //default to system id of 0 (for now- todo)
  fCatalogName:='';
  fConnectionName:=''; //todo default to something - see spec.

  result:=ok;
end; {disconnect}


function TTransaction.DoRecovery:integer;
{Recovers after a db crash
 Scans through all uncommitted transactions in sysTran (less than this transaction)
 and sets any inProgress to RolledBack.

 Assumes:
   this transactions has been started & has a TranId greater than all those it can roll-back
   Note: so we could start this process while starting new transactions => no conflict! - neat!
    - although new transactions probably shouldn't treat any existing inProgress as inProgress, but as rolled-back...
   we are the only recovery process - i.e. we assume single access to scanning sysTran
    (not relevant if sysTran is added to every transaction...)

 Side-effects:
   We have to remove our list of uncommitted transactions - we need to fix them, not skip them!

 todo: error handling needs to handle everything here! i.e. never allow abort!

 todo: need to 'delete * from sysIndex where status=isBeingBuilt' & remove all allocated index space for each
       i.e. remove partial indexes that were being (re)built when crash occurred
       Note: garbage collector will reclaim any space occupied by a garbage index entry, e.g. rolled-back/deleted
             Surely isBeingBuilt won't have been committed & will therefore become garbage? todo: Check!
}
const routine=':DoRecovery';
var
  getNull:boolean; //make global?
  nextTID:integer;
  s:string;
  NextTranRID:TRid; //todo get from db header?
  lastRid:Trid;
  noMore:boolean;

  sysTranR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
begin
  result:=fail;

  {if not inProgress then error}
  if fRt.tranId=InvalidStampId.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'transaction is not active - cannot peform recovery...',vAssertion); 
    {$ELSE}
    ;
    {$ENDIF}
    //todo: we should try to continue anyway! - desperate!
    exit; //abort
  end;

  fRecovery:=True; //temporarily set transaction flag to show we are special
  try

    {Note: we must first drop our list of uncommitted transactions (except part-rolled-back ones)
     - we don't want to ignore them, but roll them back}
    //Todo: in fact, this list contains everything we want to process - so scan through *it* to rollback
    //      instead of sysTran again!!! - neat, so do it!
    //- also, maybe call Rollback routine rather than duplicate the code! e.g. create temp-sub-trans...
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Starting db recovery...',vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    RemoveUncommittedList(True); //don't remove part-rolled-back entries, they have been committed

    //todo assert uncommittedCount=number of partRolledBack entries!

    {Read the transaction details from the dbserver's database system table}  //todo see note above to remove this- speed
    if db.catalogRelationStart(sysStmt,sysTran,sysTranR)=ok then
    begin
      try
        with (sysTranR as TRelation) do
        begin
          {Read through all inProgress/rolledBack transactions}
          if scanStart(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed starting recovery scan of sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            //todo check for db corruption & try to fix...
            exit; //abort
          end;
          noMore:=False;
          {Do an initial scan to get the 1st row rid = special}
          if scanNext(sysStmt,noMore)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed recovery scanning sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            //todo check for db corruption & try to fix...
            exit; //abort
          end;
          if noMore then
            NextTranRID:=fTuple.RID;  //1st row= Next tran counter
          while not noMore do
          begin
            if scanNext(sysStmt,noMore)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,'Failed recovery scanning sysTran',vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
              //todo check for db corruption & try to fix...
              exit; //abort
            end;
            if not noMore then
            begin //roll-back this transaction
              if ((fTuple.RID.pid=NextTranRID.pid) and (fTuple.RID.sid=NextTranRID.sid)) or //todo we've just skipped this - no need to check- speed
                 ((fTuple.RID.pid=fRid.pid) and (fTuple.RID.sid=fRid.sid)) then
              begin
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(who,where+routine,format('Ignoring tran-id row %d:%d for tran-id %d:%d - self or Next tran-id row',[fTuple.RID.pid,fTuple.RID.sid,fRt.tranId,fRt.stmtId]),vdebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
              end
              else
              begin
                fTuple.GetInteger(0,nextTID,getnull); //todo check result
                fTuple.GetString(1,s,getnull); //todo check result
                lastRid:=fTuple.RID; //store before clear

                if s=tsInProgress then  //todo: check this is ok
                begin
                  {Rollback this transaction}
                  //todo assert nextTid=fTuple.wt...
                  fTuple.clear(sysStmt); //prepare to insert //todo crap way of updating!
                  fTuple.SetWt(fRt{todo need to use our recovery tranId so we can update in place without versioning: nextTID}); //we need to re-set this before the Update below
                  fTuple.SetInteger(0,nextTid,False); //todo check result
                  fTuple.SetString(1,tsRolledBack,False); //todo check result
                  fTuple.preInsert;
                  if fTuple.UpdateOverwrite(sysStmt,lastRID)<>ok then
                  begin
                    //error!
                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,'Failed rolling back tran record, continuing recovery...',vDebugError);
                    {$ELSE}
                    ;
                    {$ENDIF}
                    //todo check for db corruption & try to fix...
                    //TODO continue anyway - better than aborting in this situation!?
                  end
                  else
                  begin
                    {Crash protection:}
                    //todo: if we crash now, this tran-id will be rolled-back on re-restart anyway - seems ok?
                    {Flush the deleted transaction row to disk}
                    //TODO: before we flush this, we *don't* have to ensure all pages dirtied by this tran have been flushed!? good!
                    //todo we could not flush here - no need !! speed!

                    //we cannot flush here because the scan has it pinned
                    //todo: use DeferredFlush? or don't bother?
                    //(fowner as TDBServer).buffer.flushPage(db,lastRid.pid);

                    {$IFDEF DEBUG_LOG}
                    log.add(who,where+routine,format('Rolled-back tran-id %d at %d:%d',[nextTid,lastrid.pid,lastrid.sid]),vdebug);
                    {$ENDIF}
                  end;
                end;
                //else leave alone:
                //       tsRolledBack         (already rolled-back by user)
                //       tsPartRolledBack     (already committed by user)
                //       tsHeaderRow          (don't modify - but should be invisible anyway)
              end;
            end;
          end;
          if scanStop(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed stopping recovery scan of sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            //todo check for db corruption & try to fix...
            exit; //abort //todo continue?
          end;
          result:=ok;
        end; {with}
      finally
        if db.catalogRelationStop(sysStmt,sysTran,sysTranR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTran
  finally
    fRecovery:=False;
  end; {try}
end; {DoRecovery}

function TTransaction.addStmt(sType:TstmtType;var stmtNode:Tstmt):integer;
{Add a stmt pointer node (and an attached new stmt) to the stmtList
//todo needs protecting
// - i.e. add critical section to root of each sList at caller level!
 IN:      sType        type of stmt to create, e.g. User or SystemDDL
 OUT:     stmtNode     pointer to new node
}
const routine=':addStmt';
var
  newNode:TPtrstmtList;
begin
  result:=ok;

  //todo assert stmtNode=nil?

  stmtlistCS.BeginWrite;
  try
    new(newNode);

    newNode.next:=stmtList;

    newNode^.sp:=Tstmt.Create(self,fRt,fWt);  //todo added ^ after newNode during change from record to class - why didn't it break before???
    newNode^.sp.stmtType:=sType;
    newNode^.sp.sroot:=nil;
    newNode^.sp.planActive:=False;  //todo overkill?
    newNode^.sp.status:=ssInactive; //todo overkill?

    stmtList:=newNode;
    stmtNode:=newNode^.sp; //return the new stmt node
  finally
    stmtlistCS.EndWrite;
  end; {try}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Added stmt pointer node to head of stmtlist: %d',[longint(stmtList^.sp)]),vDebugLow); 
  {$ENDIF}

  //todo catch any exceptions, since they would be nasty!
end; {addStmt}

function TTransaction.existsStmt(stmtNode:Tstmt):integer;
{Check if a stmt pointer node pointer exists in the stmtList
 IN:      stmtNode  pointer to stmt to be found
 RESULT:  ok=found, else not found
}
const routine=':existsStmt';
var
  nextNode:TPtrstmtList;
begin
  result:=ok;

  //todo if stmtNode=nil return not found: speed

  {Find the pointer node with the matching stmt pointer}
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if nextNode^.sp=stmtNode then break; //found
      nextNode:=nextNode^.next;
    end;

    if nextNode=nil then
    begin //not found a match
      result:=fail;
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('stmt %d not found in stmtlist %p',[longint(stmtNode),stmtList]),vDebugLow); 
      {$ENDIF}
    end;

    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}
end; {existsStmt}

function TTransaction.getStmtFromCursorName(s:string;var stmtNode:Tstmt):integer;
{Find a stmt pointer node pointer in the stmtList which matches the specified cursorName
 IN:      s            the cursorName to find
 OUT:     stmtNode     pointer to stmt, (don't use if not found)
 RESULT:  ok=found, else not found

 Note: stmtId.tranID is ignored! Assume caller checks this!
}
const routine=':getStmtFromCursorName';
var
  nextNode:TPtrstmtList;
begin
  result:=ok;
  stmtNode:=nil;

  {Find the pointer node with the matching stmtId}
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if nextNode^.sp.cursorName=s then
      begin
        stmtNode:=nextNode^.sp; //return result
        break; //found
      end;
      nextNode:=nextNode^.next;
    end;

    if nextNode=nil then
    begin //not found a match
      result:=fail;
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('cursor %s not found in stmtlist %p',[s,stmtList]),vDebugLow); 
      {$ENDIF}
      {$ENDIF}
    end;

    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}
end; {getStmtFromCursorName}

function TTransaction.getStmtFromId(stmtId:StampId;var stmtNode:Tstmt):integer;
{Find a stmt pointer node pointer in the stmtList which matches the specified stmtId.
 IN:      stmtId       the stmtId to find
 OUT:     stmtNode     pointer to stmt, (don't use if not found)
 RESULT:  ok=found, else not found

 Note: stmtId.tranID is ignored! Assume caller checks this!
}
const routine=':getStmtFromId';
var
  nextNode:TPtrstmtList;
begin
  result:=ok;
  stmtNode:=nil;

  {Find the pointer node with the matching stmtId}
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if nextNode^.sp.Rt.stmtId=stmtId.stmtId then
      begin
        stmtNode:=nextNode^.sp; //return result
        break; //found
      end;
      nextNode:=nextNode^.next;
    end;

    if nextNode=nil then
    begin //not found a match
      result:=fail;
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('stmtId %d:%d not found in stmtlist %p',[stmtId.tranId,stmtId.stmtId,stmtList]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;

    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}
end; {getStmtFromId}

function TTransaction.getSpareStmt(sType:TstmtType;var stmtNode:Tstmt):integer;
{Find a spare (no syntax-root/plan) stmt node in the stmtList
 If one does not exists, create a new one
 (Note: this mechanism has replaced the need for sysStmt2, previously used for (unnested) constraint-checking)

 IN:      sType        type of spare stmt to find/create, e.g. stSystemConstraint
 OUT:     stmtNode     pointer to found stmt
 RESULT:  ok=found, else not found
}
const routine=':getSpareStmt';
var
  nextNode:TPtrstmtList;
begin
  result:=ok;

  {Find the pointer node for a spare stmt}
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if (nextNode^.sp.stmtType=sType)
      and (nextNode^.sp.status<>ssActive)
      and (nextNode^.sp.sroot=nil) then
      break; //found
      nextNode:=nextNode^.next;
    end;

    if nextNode=nil then
    begin //not found a match
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('spare stmt not found in stmtlist %p, will create a new one...',[stmtList]),vDebugLow); 
      {$ENDIF}
      result:=addStmt(sType,stmtNode);
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('spare stmt found %d in stmtlist %p',[longint(nextNode^.sp),stmtList]),vDebugLow); 
      {$ENDIF}
      stmtNode:=nextNode^.sp;
    end;

    //todo catch any exceptions, since there could be some (should never be!)
  finally
    stmtlistCS.EndRead;
  end; {try}
end; {getSpareStmt}

function TTransaction.removeStmt(stmtNode:Tstmt):integer;
{Remove a stmt pointer node (and free its attached stmt) from the stmtList
//todo needs protecting
// - i.e. add critical section to root of each sList at caller level!
 IN:      stmtNode     pointer to stmt to be removed
}
const routine=':removeStmt';
var
  trailNode,nextNode,nextNode2:TPtrstmtList;
begin
  result:=ok;

  {Find the pointer node with the matching stmt pointer}
  stmtlistCS.BeginWrite;
  try
    trailNode:=nil;
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      if nextNode^.sp=stmtNode then break; //found
      trailNode:=nextNode;
      nextNode:=nextNode^.next;
    end;

    if nextNode<>nil then
    begin //found match, delete it
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Removing stmt %d (%d) from stmtlist %p',[longint(nextNode^.sp),ord(nextNode^.sp.stmtType),stmtList]),vDebugLow); 
      {$ENDIF}

      {Close any non-return cursors, and retain any return cursors by repointing their owners so that the next close will delete them}
      //todo: maybe better to do in call routine sections... because we also might need to return the result cursor/stmt?
      stmtlistCS.BeginRead;
      try
        nextNode2:=stmtList;
        while nextNode2<>nil do
        begin
          if (nextNode2^.sp.stmtType=stUserCursor)
          and (nextNode2^.sp.outer=nextNode^.sp)
          then
          begin //found a match
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('dependent cursor (%d) stmt found %d in stmtlist %p for %d',[ord(nextNode2^.sp.planReturn),longint(nextNode2^.sp),stmtList,longint(nextNode^.sp)]),vDebugLow); 
            {$ENDIF}
            if not(nextNode2^.sp.planReturn) then
              nextNode2^.sp.closeCursor(1{=unprepare})
            else
              nextNode2^.sp.outer:=nextNode^.sp.outer;  //move to this stmt's outer context so we can find it at routine end for result set returning
            //todo clean up this stmt entry?
            //todo need to close the list as well: call removeStmt() to nextNode2^.sp.Free;
          end;
          nextNode2:=nextNode2^.next;
        end;
        //todo catch any exceptions, since there could be some (should never be!)
      finally
        stmtlistCS.EndRead;
      end; {try}


      if nextNode^.sp.sroot<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'stmt seems still to have allocated syntax tree memory, ignoring=memory leak...',vAssertion); 
        {$ENDIF}
        if nextNode^.sp.sroot.atree<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'stmt seems still to have allocated algebra tree memory, ignoring=memory leak...',vAssertion); 
          {$ELSE}
          ;
          {$ENDIF}
        if nextNode^.sp.sroot.ptree<>nil then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,'stmt seems still to have allocated plan tree memory, ignoring=memory leak...',vAssertion); 
          {$ELSE}
          ;
          {$ENDIF}
        //todo etc? parseroot?
      end;
      if nextNode^.sp.sarg<>nil then
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'stmt seems still to have allocated SARG memory, ignoring=memory leak...',vAssertion); 
        {$ELSE}
        ;
        {$ENDIF}

      if nextNode^.sp.errorList<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,'stmt has allocated error stack memory, will delete it now...',vDebugLow); //todo not an error -remove message
        {$ENDIF}
        nextNode^.sp.deleteErrorList; //clear error stack
      end;

      {Update the list to skip over the pointer node}
      //Note: yes here, and elsewhere, it would be neater if we introduced a fixed header node - easier list logic!
      if trailNode<>nil then
        trailNode.next:=nextNode.next  //skip over about-to-be-zapped node
      else
        stmtList:=nextNode.next;          //we're about to zap the 1st node, so update the root pointer to skip over it

      {Ok, now we can zap the stmt}
      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      if nextNode^.sp=nil then
        log.add(who,where+routine,format('Free error',[nil]),vAssertion);
      {$ENDIF}
      {$ENDIF}
      nextNode^.sp.free;  //todo added ^ after nextNode during change from record to class - why didn't it break before???

      {and its pointer node}
      dispose(nextNode);
    end
    else
    begin
      //handle was not found, error!
      result:=fail;
    end;
  finally
    stmtlistCS.EndWrite;
  end; {try}

  //todo catch any exceptions, since they would be nasty!
end; {removeStmt}

function TTransaction.showStmts:string;
{Return formatted list of current statements
 - actually cursors & statements
}
var
  nextNode:TPtrstmtList;
  stype,sstatus:string;
begin
  result:='';
  stmtlistCS.BeginRead;
  try
    nextNode:=stmtList;
    while nextNode<>nil do
    begin
      //todo: note in future, Rt.tranId could be user's 'kill' reference/handle...
      with nextNode^.sp do
      begin
        case stmtType of
          stUser:             stype:='User';
          stUserCursor:       stype:='User cursor';
          stSystemUserCall:   stype:='System user call';
          stSystemDDL:        stype:='System DDL';
          stSystemConstraint: stype:='System constraint';
        else
          stype:='?';
        end; {case}
        case status of
          ssInactive:         sstatus:='Inactive';
          ssActive:           sstatus:='Active';
          ssCancelled:        sstatus:='Cancelled';
        else
          sstatus:='?';
        end; {case}

        result:=result+format('  %8.8d (%8.8d) %-*.*s %10s planActive=%s planHold=%s planReturn=%s resultSet=%s noMore=%s %s',
                              [longint(nextNode^.sp),longint(nextNode^.sp.outer),20,20,stype,sstatus,noYes[planActive],noYes[planHold],noYes[planReturn],noYes[resultSet],noYes[noMore],who])+CRLF;
        if trim(inputText)<>'' then result:=result+format('    %s',[trim(inputText){todo remove CRLF inside}])+CRLF;
      end;

      nextNode:=nextNode.next;
    end;
  finally
    stmtlistCS.EndRead;
  end; {try}
end; {showStmts}

function TTransaction.StmtScanStart:integer;
begin
  result:=Fail;
  stmtlistCS.BeginRead;
  stmtListNextNode:=stmtList;
  result:=ok;
end;
function TTransaction.StmtScanNext(var st:TStmt; var noMore:boolean):integer;
begin
  result:=fail;
  noMore:=False;

  if stmtListNextNode<>nil then
  begin
    st:=stmtListNextNode^.sp;
    stmtListNextNode:=stmtListNextNode.next;
    result:=ok;
  end
  else
  begin
    noMore:=True;
    st:=nil;
    result:=ok;
  end;
end;
function TTransaction.StmtScanStop:integer;
{Note: up to caller to finally do this after StmtScanStart
}
begin
  result:=Fail;
  stmtlistCS.EndRead;
  result:=ok;
end;

{Sub-transactions (stmt) serialisability control routines.

 These algorithms assume that only one thread is used per transaction since this
 guarantees that all stmt-atomic inserts/updates/deletes are performed in one
 go, even if a number of user-stmts are active on this transaction.

 Note++: is this still the case, now stmts carry their own Rt/Wt?
}
//todo: move these to uStmt!
function TTransaction.StmtStart(st:Tstmt):integer;
{Starts a new stmt within a transaction
 Increments the Wt.stmtId by 1 for the next writes to be atomic
 and stamps the stmt Wt/Rt

 Note: the stmt object already exists, this just resets counters etc. for it
}
const routine=':stmtStart';
begin
  result:=ok;

  //todo: maybe we should be extra tidy and stmt.clearConstraintList
  //      (only if previous stmt was insert/update/delete)
  //      should be no need because stmtcommit/stmtrollback should do this i.e. as early as possible to release memory
  //todo: at least assert list is empty! *
  // also (if in future we call stmtstart before addConstraints) then we might expect
  // garbage entries here if a previous routine failed between addconstraints and stmtStart
  // - in this case, the entries would have Wt values = Wt now (since last inc was never reached)

  st.fRt.stmtId:=fWt.stmtId;  //stamp this on the stmt: i.e. potentially read any stmt before this new one
  inc(fWt.stmtId);
  //todo what if we reach limit? could auto-commit & link so that user commit/rollback
  //     goes back & sets flag on tran-status
  //todo at least for now do an auto-commit anyway & raise assertion!

  st.fWt.StmtId:=fWt.stmtId;  //stamp this on the stmt: i.e. write as new one


  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Started stmt-id %d:%d',[st.Wt.tranId,st.Wt.stmtId]),vdebugLow);
  {$ENDIF}
  {$ENDIF}
end; {StmtStart}

function TTransaction.StmtCommit(st:Tstmt):integer;
{Commits the last started stmt within a transaction
 Sets the Rt.stmtId = Wt.stmtId so the last write was commited and atomic and
 any changes can now be read by this transaction.

 So in the normal course of events with no stmt failures/rollbacks:
   stmtStart would       Wt.stmtId++
   stmtCommit would      Rt.stmtId:=Wt.stmtId == Rt.stmtId++
 i.e. 1-step-catch-up

 Note: the stmt object already exists, this just resets counters etc. for it

 Note: we don't need to check that the stmt.tranId=tranId because we don't store
 any stmt commit flag: still, should do this as an assertion? todo

 Note: stmtRollback can undo stmtCommits if they were part of a cascading chain
}
const routine=':stmtCommit';
begin
  result:=ok;

  //todo skip this check and clear if we're not insert/update/delete

  //todo* check statement level constraints (only those with ctStmt)
  //         need to use artificially raised Rt - one for each constraint.Wt
  //         but surely all should be same Wt here? todo assert!
  //         (although FK lookup needs to see all to date)
  // - if any fail, call st.rollback instead & return fail
  if (st.constraintList as Tconstraint).checkChain(st,nil{iter n/a},ctStmt{todo or ctRow},ceBoth)<>ok then
  begin
    {Emergency rollback statement!}
    result:=StmtRollback(st);
    //todo report error here if result<>ok, i.e. emergency rollback failed! - unlikely!?
    result:=fail; //even though rollback succeeded
    exit; //abort the statement commit
  end;

  {Remove any stmt level constraints}
  (st.constraintList as Tconstraint).clearChain;

  fRt.stmtId:=fWt.stmtId; //no need any more now that st has its own rt: todo remove: no: we use it below to set the st!

  //todo remove stmt errors?

  {Update any inactive stmts on this transaction so they see our changes (initially to include sysStmt/2
  for meta data creation/checking)}
  //todo: when we have triggers firing, do we also want to update active/parent stmts... & maybe roll them back!
  Ttransaction(st.owner).SynchroniseStmts(false);
  {Since we are still active, we synchronise ourself too}
  st.fRt:=self.fRt;
  st.fWt:=self.fWt;

  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Committed stmt-id %d:%d',[st.Wt.tranId,st.Wt.stmtId]),vdebugLow);
  {$ENDIF}
  {$ENDIF}
end; {StmtCommit}

function TTransaction.StmtRollback(st:Tstmt):integer;
{Rollback(s!) the stmt within a transaction
 Adds the Wt.stmtId to the current rolled-back-stmt list so future reads will
 ignore its changes.

 Also increments the Rt/Wt.stmtId by 1 to skip the abandoned Wt
 (i.e. canSee when stmtId=stmtId will not assume current & visible)

 If any 'future' stmts have been issued then they are also added to the rolled-back-stmt
 list to support cascaded RI actions. i.e. stmt-savepoints (like nested transactions)
 e.g stmtId:6 cascades 7,8 and 9 and 9 fails (causing stmt-rollback for 6 and 9)
 6's rollback will add 7 and 8 (and 9 again?=ok?) to the rolled-back-stmt list.

 If the stmt's tranId does not match this transaction then we fail the rollback
 since it must be a cursor left open across transaction boundaries
 - otherwise using its stmtId could conflict with the current transaction's stmt with
 the same id! i.e. no way to go back & add the stmt-rollback to the previous tran.
 todo: client should prevent this from happening!

 If we subsequently commit this transaction, it will be given a status of
 'part-rolled-back' and the rolled-back-stmt list will be written to disk
 for future transactions.
 Or if we subsequently rollback this transaction, it will be given the usual
 status of 'rolled-back' and the rolled-back-stmt list won't be needed.

 Note: the stmt object already exists, this just resets counters etc. for it
}
const routine=':stmtRollback';
var
  stmtStatus:TstmtStatusPtr;
begin
  result:=ok;

  if st.Wt.tranId<>fWt.tranId then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Stmt-id %d:%d can no longer be rolled back because rolled-back-stmt list is now for transaction %d',[st.fWt.tranId,st.fWt.stmtId,fWt.tranId]),vAssertion); //todo client error?
    {$ENDIF}
    result:=fail;
    exit;
  end;

  //todo keep in sync. with below
  inc(rolledBackStmtCount);
  new(stmtStatus);  //todo pre-allocate chunks...or use buffer pages?
  {$IFDEF DEBUG_LOG}
  {$IFDEF DEBUGDETAIL3}
  inc(debugStmtStatusCreate);
  {$ENDIF}
  {$ENDIF}
  stmtStatus.tid:=st.Wt; //todo .tranId not currently used
  stmtStatus.next:=rolledBackStmtList;
  rolledBackStmtList:=stmtStatus;  //Note: linked in reverse scan order: Head->3->2->1

  //todo skip this clear if we're not insert/update/delete
  {Remove any stmt level constraints}
  (st.constraintList as Tconstraint).clearChain;

  //Note: even though we're rolling back, we still increment our Rt because we the canSee assumes stmtId=stmtId means it's our record and we can see it: not so, so we move on & let the rolledBackStmtList take care of the gaps
  inc(fWt.stmtId); //actually we increment our Wt again first so we skip over the abandoned one
  fRt.stmtId:=fWt.stmtId; //no need any more now that st has its own rt: todo remove: no: we use it below to set the st!

  //todo remove stmt errors?

  {Update any inactive stmts on this transaction so they see our changes (initially to include sysStmt/2
  for meta data creation/checking)}
  //todo: when we have triggers firing, do we also want to update active/parent stmts... & maybe roll them back!
  Ttransaction(st.owner).SynchroniseStmts(false);
  {Since we are still active, we synchronise ourself too}
  st.fRt:=self.fRt;
  st.fWt:=self.fWt;

  {$IFDEF DEBUGDETAIL2}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Added stmt-id %d:%d as entry in rolled-back-stmt list',[st.Wt.tranId,st.Wt.stmtId]),vdebugLow);
  {$ENDIF}
  {$ENDIF}

  {If there are future stmts which are committed, undo them now - they must be part of our
   chain, i.e. cascading actions}
  if st.Wt.stmtId<fWt.stmtId then
  begin //there are stmt.id(s) between us and the latest stmt id for our transaction
    repeat
      inc(st.fWt.stmtId);

      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('...cascading stmt-rollback to include future stmt-id %d:%d...',[st.Wt.tranId,st.Wt.stmtId]),vdebugLow);
      {$ENDIF}
      {$ENDIF}
      //todo should really find the st(s) and call stmtRollback (especially to clear any stmt constraints)

      //todo keep in sync. with above
      inc(rolledBackStmtCount);
      new(stmtStatus);  //todo pre-allocate chunks...or use buffer pages?
      {$IFDEF DEBUG_LOG}
      {$IFDEF DEBUGDETAIL3}
      inc(debugStmtStatusCreate);
      {$ENDIF}
      {$ENDIF}
      stmtStatus.tid:=st.Wt; //todo .tranId not currently used
      stmtStatus.next:=rolledBackStmtList;
      rolledBackStmtList:=stmtStatus;  //Note: linked in reverse scan order: Head->3->2->1

    until st.Wt.stmtId>=fWt.stmtId;
    //todo now synchronise other st/this tran?
  end;
end; {StmtRollback}


function TTransaction.GetEarliestActiveTranId:StampId;
{Find the earliest active transaction id that this transaction knows about
 - used by garbage collector to determine earliest purgeable records

 //todo: when found, cross check with active thread list to see if it is still active
 // - maybe if it's not we can pick a more recent one? (although would this be totally crash-proof? e.g. may be committing...)
}
const routine=':getEarliestActiveTranId';
var
  tranStatus:TtranStatusPtr;
begin
  result:=self.fRt; //default to self

  tranStatus:=uncommitted;
  while tranStatus<>nil do
  begin
    if tranStatus.status=tsInProgress then
      if tranStatus.tid.tranId<result.tranId then       //note: ordering implied - makes future wrapping of tran ids more difficult
        result:=tranStatus.tid;

    tranStatus:=tranStatus.next;
  end;
end; {GetEarliestActiveTranId}

function TTransaction.SetLastGeneratedValue(genId,value:integer):integer;
{Store latest generated value by this transaction/connection in case user wants to
 refer/re-use it.
 Builds a list of previously accessed generators which currently lasts
 the lifetime of the Ttransaction (i.e. connection)

 IN:     genId           the generator to store
         value           the last used value

 RESULT: ok, else fail
}
var
  genItem:TgeneratedPtr;
begin
  result:=fail;

  genItem:=generatedList;
  while genItem<>nil do
  begin
    if (genItem^.generatorId=genId) then
    begin {match}
      //todo: assert value>genItem^.lastValue? (but no, could have been reset?)
      genItem^.lastValue:=value;
      result:=ok;
      exit; //done
    end;

    {Next}
    genItem:=genItem.next;
  end;

  {Not found, so add to our list}
  new(genItem);  //todo pre-allocate chunks...or use buffer pages?
  genItem^.next:=generatedList;
  generatedList:=genItem;
  genItem^.generatorId:=genId;
  genItem^.lastValue:=value;
  result:=ok;
end; {SetLastGeneratedValue}

function TTransaction.GetLastGeneratedValue(genId:integer;var value:integer):integer;
{Retrieve latest generated value by this transaction/connection
 IN:     genId           the generator to retrieve
 OUT:    value           the last used value

 RESULT: ok, else fail e.g. not generated yet by this connection
}
var
  genItem:TgeneratedPtr;
begin
  result:=fail;
  value:=-1; //safety only //todo remove speed

  genItem:=generatedList;
  while genItem<>nil do
  begin
    if (genItem^.generatorId=genId) then
    begin {match}
      value:=genItem^.lastValue;
      result:=ok;
      exit; //done
    end;

    {Next}
    genItem:=genItem.next;
  end;

  {Not found, returns fail}
end; {SetLastGeneratedValue}


function TTransaction.ShowTrans(connection:TIdTCPConnection):integer;
{DEBUG ONLY - show ALL transactions in the sysTran table
 If we did a normal select, all the interesting rows would be automatically hidden
 because of our neat tuple versioning. e.g. a rolled back tranId is hidded from future ones
                                            by being in their uncommited list => its tran-status row is also invisible!
 This routine pretends to be tran-id MAX with no uncommitted list, so it can temporarily see everything

 //todo in future, just set read-uncommitted to ignore the uncommited list & then select would be enough?

 //todo make the scan safe - i.e. use our own sysTran or mutex?
}
const routine=':showTrans';
var
  saveUncommitted:TtranStatusPtr;
  saveTid:StampId;
  noMore:boolean;

  sysTranR,sysTranStmtR:TObject; //Trelation  //todo move elsewhere: in TTransaction?  speed
begin
  result:=Fail;
  saveUncommitted:=uncommitted;
  saveTid:=fRt;
  uncommitted:=nil;
  fRt:=MaxStampId;
  fWt:=MaxStampId;
  SynchroniseStmts(true);
  try
    {Read the raw transaction details from the dbserver's database system table}
    if db.catalogRelationStart(sysStmt,sysTran,sysTranR)=ok then
    begin
      try
        with (sysTranR as TRelation) do
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%s',[fTuple.ShowHeading]),vDebugHigh);
          {$ELSE}
          ;
          {$ENDIF}
          if connection<>nil then
          begin
            connection.WriteLn(format('%s',[fTuple.ShowHeading]));
            connection.WriteLn(stringOfChar('=',length(fTuple.ShowHeading)));
          end;
          if scanStart(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed starting debug scan of sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          noMore:=False;
          while not noMore do
          begin
            if scanNext(sysStmt,noMore)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,'Failed debug scanning sysTran',vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
              exit; //abort
            end;
            if not noMore then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('%s <%d:%d>',[fTuple.Show(sysStmt),fTuple.rid.pid,fTuple.rid.sid]),vDebugHigh);
              {$ELSE}
              ;
              {$ENDIF}
              if connection<>nil then connection.WriteLn(format('%s <%d:%d>',[fTuple.Show(sysStmt),fTuple.rid.pid,fTuple.rid.sid]));
            end;
          end;
          if scanStop(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed stopping debug scan of sysTran',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort //todo continue?
          end;
        end; {with}
        result:=ok;
      finally
        if db.catalogRelationStop(sysStmt,sysTran,sysTranR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTran)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTran

    if connection<>nil then
    begin
      connection.WriteLn();
    end;

    {Read the raw transaction stmt details from the dbserver's database system table}
    if db.catalogRelationStart(sysStmt,sysTranStmt,sysTranStmtR)=ok then
    begin
      try
        with (sysTranStmtR as TRelation) do
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('%s',[fTuple.ShowHeading]),vDebugHigh);
          {$ELSE}
          ;
          {$ENDIF}
          if connection<>nil then
          begin
            connection.WriteLn(format('%s',[fTuple.ShowHeading]));
            connection.WriteLn(stringOfChar('=',length(fTuple.ShowHeading)));
          end;
          if scanStart(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed starting debug scan of sysTranStmt',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort
          end;
          noMore:=False;
          while not noMore do
          begin
            if scanNext(sysStmt,noMore)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,'Failed debug scanning sysTranStmt',vDebugError);
              {$ELSE}
              ;
              {$ENDIF}
              exit; //abort
            end;
            if not noMore then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('%s <%d:%d>',[fTuple.Show(sysStmt),fTuple.rid.pid,fTuple.rid.sid]),vDebugHigh);
              {$ELSE}
              ;
              {$ENDIF}
              if connection<>nil then connection.WriteLn(format('%s <%d:%d>',[fTuple.Show(sysStmt),fTuple.rid.pid,fTuple.rid.sid]));
            end;
          end;
          if scanStop(sysStmt)<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Failed stopping debug scan of sysTranStmt',vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            exit; //abort //todo continue?
          end;
        end; {with}
        result:=ok;
      finally
        if db.catalogRelationStop(sysStmt,sysTranStmt,sysTranStmtR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Failed releasing catalog relation %d',[ord(sysTranStmt)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end;
    //todo else error - couldn't get access to sysTranStmt

  finally
    fRt:=saveTid;
    fWt:=saveTid;
    SynchroniseStmts(true);
    uncommitted:=saveUncommitted;
  end; {try}
end; {showTrans}

function TTransaction.ConstraintTimeOverridden(constraintId:integer):TconstraintTime;
{Check if the specified constraint is in the override list for this transaction

 RETURNS:  ctTran       - is in list as Deferred
           ctStmt       - is in list as Immediate
           ctNever      - is not in list

 Notes:
   The latest entry is returned, so if the same constraint was overridden twice,
   the second value would be returned.
   If an entry with an Id of 0 is present, it matches ALL constraint ids
   - caller should still check if this applies to each specific constraint
    (e.g. ALL-deferred only actually applies if the constraint is deferrable)
}
var
  cOverride:TconstraintTimeOverridePtr;
begin
  result:=ctNever;

  cOverride:=constraintTimeOverride;
  while cOverride<>nil do
  begin
    if (cOverride^.constraintId=ConstraintId) or (cOverride^.constraintId=0) then
    begin {match}
      result:=cOverride^.constraintTime;
      exit; //done
    end;

    {Next}
    cOverride:=cOverride.next;
  end;
end; {ConstraintTimeOverridden}

function TTransaction.Cancel(st:Tstmt;connection:TIdTCPConnection):integer;
{Cancel active/specified stmt(s)
 - called by another transaction

 Assumes:
   if st=nil then cancels all active stmts for this transaction
}
var
  otherSt:Tstmt;
  noMore:boolean;
begin
  result:=ok;
  {Loop through all this transaction's statements
   Note: this logic is copied from uStmt.exists - todo: in future use a class to hide this detail & protect the list!
  }
  result:=StmtScanStart; //Note: this protects us from the stmt we find from disappearing!
  if result<>ok then exit; //abort
  try
    noMore:=False;
    while not noMore do
    begin
      if StmtScanNext(otherSt,noMore)<>ok then exit;
      if not noMore then
      begin
        if (st=nil) or (otherSt=st) then
          if otherSt.status=ssActive then
          begin
            otherSt.status:=ssCancelled; //this will abort the victim's iterator loop
            {Send error to victim}
            otherSt.addError(seStmtCancelled,format(seStmtCancelledText,[nil]));
            {Return result to killer}
            if connection<>nil then connection.WriteLn(format('Cancelled statement %d on transaction %d',[otherSt.Rt.stmtId,otherSt.Rt.tranId]));
          end;
      end;
    end; {while}
  finally
    result:=StmtScanStop; //todo check result
  end; {try}
end; {Cancel}

function TTransaction.Kill(connection:TIdTCPConnection):integer;
{Kill transaction & disconnect
 - called by another transaction

 Assumes:
}
const routine=':kill';
var
  nextNode:TPtrstmtList;
  saveTranId:cardinal;
begin
  result:=ok;

  {First, try to gently cancel all the active statements}
  Cancel(nil,connection);

  {Now rollback the whole transaction}
  saveTranId:=tranRt.TranId;
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('Forceably rolling back tran %d',[tranRt.tranId]),vDebugLow);
  {$ENDIF}
  rollback(False); //todo return fail if this fails?
  //todo db:=nil !

  {Now disconnect it}
  if thread<>nil then  //JKOZ:001 : Move to the appropriate class this I'm guessing the thread class
    if thread is TCMThread then //e.g. not garbage collector
    begin
      (thread as TCMThread).connection.Disconnect; //this will terminate the thread //todo: disconnectSocket is more powerful?
      try //in case disconnect didn't work
        sleepOS(100);
      {$IFDEF INDY9}
        (thread as TCMThread).connection.DisconnectSocket;
      {$ENDIF}
      {$IFDEF INDY10}
        (thread as TCMThread).connection.Disconnect;
      {$ENDIF}
      except
        {ok}
      end; {try}
      //todo? (thread as TCMThread).Terminate;
    end;  //JKOZ:001 : ends here.

  if connection<>nil then connection.WriteLn(format('Killed transaction %d',[saveTranId]));
end; {Kill}

function TTransaction.SynchroniseStmts(all:boolean):integer;
{Synchronise all stmts with this transaction's Rt/Wt

 IN:    all     True=reset all stmts, even if active
                else just inactive ones (does not necessarily include caller)
}
const routine=':SynchroniseStmts';
var
  otherSt:Tstmt;
  noMore:boolean;
begin
  result:=ok;
  {Loop through all this transaction's statements
   Note: this logic is copied from uStmt.exists - todo: in future use a class to hide this detail & protect the list!
  }
  result:=StmtScanStart; //Note: this protects us from the stmt we find from disappearing!
  if result<>ok then exit; //abort
  try
    noMore:=False;
    while not noMore do
    begin
      if StmtScanNext(otherSt,noMore)<>ok then exit;
      if not noMore then
      begin
        if all or (otherSt.status<>ssActive) then
        begin
          {$IFDEF DEBUG_LOG}
          {$IFDEF DEBUGDETAIL}
          log.add(who,where+routine,format('Synchronising stmt %s with tran %s',[otherSt.who,self.who]),vDebugLow); 
          {$ENDIF}
          {$ENDIF}
          otherSt.fRt:=self.fRt;
          otherSt.fWt:=self.fWt;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          {$IFDEF DEBUGDETAIL}
          log.add(who,where+routine,format('Skipping synchronising active stmt %s with tran %s',[otherSt.who,self.who]),vDebugLow); 
          {$ENDIF}
          {$ENDIF}
        end;
      end;
    end; {while}
  finally
    result:=StmtScanStop; //todo check result
  end; {try}
end; {SynchroniseStmts}

//todo: make these read a fixed timestamp at transaction/statement start!
function TTransaction.getCurrentDate:TsqlDate;
var
  d,m,y:word;
begin
  decodeDate(date,y,m,d);
  result.year:=y;
  result.month:=m;
  result.day:=d;
end; {getCurrentDate}

function TTransaction.getCurrentTime:TsqlTime;
var
  h,m,s,ms:word;
begin
  decodeTime(time,h,m,s,ms);
  //assume local clock is already in local timezone
  //todo: shouldn't we adjust it to UTC and append timezone?
  result.hour:=h;
  result.minute:=m;
  //todo remove: result.second:=s;
  result.scale:=0;
  {Normalise to ease later comparison and hashing}
  result.second:=round(s*power(10,TIME_MAX_SCALE)); //i.e. shift TIME_MAX_SCALE decimal places to the left //todo replace trunc with round everywhere, else errors e.g. trunc(double:1312) -> 1311! //what about int()?
  //todo return ms with appropriate scale
end; {getCurrentTime}

function TTransaction.getCurrentTimestamp:TsqlTimestamp;
begin
  result.date:=getCurrentDate;
  result.time:=getCurrentTime;
end; {getCurrentTimestamp}

function TTransaction.fconnected:boolean;
begin
  result:=(authId<>InvalidAuthId);
end; {fconnected}



end.

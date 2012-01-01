unit uMain;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{This unit is a bit untidy. It was originally a test harness example of a program which
 could make use of the embedded SQL engine, but became the server's main loop
}

//{$DEFINE NO_GARBAGE_COLLECTOR}    //debug
                                    //Note: Garbage Collect Catalog is still available anyway!

{$IFDEF WIN32}
  //{$DEFINE USE_APPLICATION} //Windows application.processMessages to prevent other apps. hanging (also in DPR)
  {$IFNDEF USE_APPLICATION}
    {$DEFINE USE_PROCESS_MESSAGES} //Non-Forms Windows message handler
  {$ENDIF}
{$ENDIF}

interface

procedure Main;


implementation

uses uLog, uServer, uGlobal, uConnectionMgr,
  uOS,
  {$IFDEF WIN32} //todo move to uOS
  Windows,{for getWorkingsetSize}
  {$IFDEF USE_APPLICATION}
  Forms, //for Application
  {$ENDIF}
  {$IFDEF USE_PROCESS_MESSAGES}
  messages, //for WM_QUIT
  {$ENDIF}
  {$ENDIF}
  sysUtils, SyncObjs{for Tevent},
  uPage {for debug count}, uSyntax {for debug count}, uAlgebra {for debug count},
  uTuple{for tuple debug max},
  uVariableSet{for tuple debug max},
  uGarbage, uFile{for debug count}, uRelation{for debug count}, uIterator{for debug count},
  uStmt{for debug count}, uConstraint{for debug count}, uTransaction{for debug count}, uDatabase{for debug count},
  uOptimiser{for debug count},
  uTempTape{for debug count},
  uMarshal{for debug count},
  uRoutine{for debug count};

const
  where='uMain';
  who='';

var
  dbs:TDBserver;
  cm:TConnectionMgr;
                {In theory, one engine (=process)
                            can run multiple servers
                            which can each run multiple databases (=multiple catalogs =(part of a?) cluster)
                            which can each contain multiple schemas

                            this connection manager handles all engine connections (=threads)
                            and then each connects to a particular server+database (=catalog)
                                          as a particular authorisation-id which has a default schema

                            in future:
                              DEFINITION_SCHEMA could reside in an engine-level db
                              and also at this level could/should be the authorisation details
                }
  gc:TGarbageCollector;

procedure Main;
const routine=':Main';
var
  {$IFDEF WIN32}
  minws,maxws:dword;
  ph:thandle;
  {$ENDIF}
  dbfname:string;
  serviceName:string;
  {$IFDEF USE_PROCESS_MESSAGES}
  Msg:TMsg;
  {$ENDIF}
  i:integer;
  s,sc:string;

  startDB:TDB;
begin
  {$IFDEF DEBUG_LOG}
  log.start;
  {$ENDIF}
  try
    {$IFDEF DEBUG_LOG}
    log.add(who,where,'Started',vDebug);
    {$ENDIF}

    dbfname:='db1'; //default
    serviceName:=TCPservice; //default

    {Handle parameters}
    for i:=1 to ParamCount do
    begin
      s:=paramStr(i);
      if (s[1]='/') or (s[1]='-') then
      begin
        delete(s,1,1);
        if pos('=',s)=0 then s:=s+'=';
        sc:=uppercase(trim(copy(s,1,pos('=',s)-1)));
        s:=copy(s,pos('=',s)+1,length(s));
        (* note: removed since nothing can be done yet!
        if sc='MEMORYMANAGER' then
        begin
          if strToIntDef(s,0)=0 then
          begin
            {Turn off MultiMM memory manager (WIN32 only)}
            //if IsMemoryManagerSet then
            //see MultiMM.finalization (but methods are not exposed!)
          end;
          //else assume default=1 => MultiMM for Windows
        end;
        if sc='BUFFERPOOLSIZE' then
        begin
          //set MaxFrames
        end;
        *)

        if sc='SERVICE' then
        begin
          if trim(s)<>'' then serviceName:=s;
          {$IFDEF DEBUG_LOG}
          log.add(who,where,format('  Service overridden with parameter %s',[s]),vDebugHigh);
          {$ENDIF}
        end;
      end
      else
      begin //catalog name
        dbfname:=s;
        {$IFDEF DEBUG_LOG}
        log.add(who,where,format('  Catalog overridden with parameter %s',[s]),vDebugHigh);
        {$ENDIF}
      end;
    end;

    {End of parameters}

    {Check physical memory allocated}
    {$IFDEF WIN32}
    ph:=getCurrentProcess;
    if getProcessWorkingSetSize(ph,minws,maxws) then //note: no good on Win95
      {$IFDEF DEBUG_LOG}
      log.add(who,where,format('Working set size=%d..%d',[minws,maxws]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
    //todo in future we should ensure (using setProcessWorkingSetSize and VirtualLock) that
    //     our buffer manager's pages (at least) are fixed in physical RAM!
    {$ENDIF}

    dbs:=TDBserver.Create;
    try
      dbs.name:=serverName; //todo take name from startup?

      startDB:=dbs.addDB(dbfname);
      if startDB=nil then
        {$IFDEF DEBUG_LOG}
        log.add(who,where,'Failed to re-add db',vdebug);
        {$ELSE}
        ;
        {$ENDIF}
        //abort?
      try
        //todo make db-creation a separate option/program/call...
(*debug - use existing db
        if dbs.db.createdb('G1')=ok then
          dbs.buffer.resetAllFrames(dbs.db)
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Failed creating db',vdebug);
          {$ELSE}
          ;
          {$ENDIF}
*)

        //todo assert = getInitialConnectdb, i.e. primary catalog
        {Open the database}
        if startDB.openDB(dbfname,False)=ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Opened database',vDebug);
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'',vDebug);
          {$ENDIF}
          startDB.status; //debug report
          dbs.buffer.status;
//          dbs.db.dirStatus(tr);
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Failed to open',vdebug);
          {$ENDIF}
          {Remove the unopened database}
          dbs.removeDB(startDB);
          startDB:=nil;
        end;

        {Main loop}
        cm:=TConnectionMgr.Create(dbs); //pass server to connection manager
        try
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Connection manager created',vdebug);
          {$ENDIF}

          if cm.Start(serviceName)<>ok then
            exit; //abort

          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Connection manager started - accepting requests...',vdebug);
          {$ENDIF}

          {$IFNDEF NO_GARBAGE_COLLECTOR}
          gc:=TGarbageCollector.Create(startDB); //pass server to garbage collector
          if gc.suspended then
          begin //never started properly so we free it now (since freeOnTerminate will never take effect)
            {$IFNDEF LINUX}
            gc.free;
            gc:=nil;
            {$ENDIF}
          end;
          {$ENDIF}
          try
            {$IFDEF DEBUG_LOG}
            log.add(who,where,'Connection manager created',vdebug);
            {$ENDIF}
            {$IFDEF USE_APPLICATION} //=>WIN32
            {todo: if we can avoid processMessages we save wake-up time & 200k of EXE!
              Also should give better behaviour under Windows shutdown...
            }
            while (cm.cmShutdown.WaitFor(1000*2)<>wrSignaled) and not Application.Terminated do
            begin
              {$IFDEF DEBUG_LOG}
              //log.add(who,where,'Connection manager shutdown was not signalled after 2 seconds',vAssertion);
              {$ENDIF}
              Application.ProcessMessages;
            end;
            {$ELSE}
              {$IFDEF USE_PROCESS_MESSAGES} //=>WIN32 non-Forms handler
                while (cm.cmShutdown.WaitFor(1000*2)<>wrSignaled) do
                begin
                  if PeekMessage(Msg,0,0,0,PM_REMOVE) then
                  begin
                    if Msg.Message=WM_QUIT then break; //terminated
                    TranslateMessage(Msg);
                    DispatchMessage(Msg);
                  end;
                end;
              {$ELSE} //=>Linux
              if cm.cmShutdown.WaitFor(INFINITY)<>wrSignaled then
              begin
                {$IFDEF DEBUG_LOG}
                log.add(who,where,'Connection manager shutdown was not signalled',vAssertion);
                {$ENDIF}
              end;
              {$ENDIF}
            {$ENDIF}


            cm.Stop;
            sleepOS(1000); //allow client threads to terminate...
            {$IFDEF DEBUG_LOG}
            log.add(who,where,'Connection manager stopped',vdebug);
            {$ENDIF}
          finally
            {$IFNDEF NO_GARBAGE_COLLECTOR}
            {$ENDIF}
          end; {try}
        finally
          cm.Free;
          cm:=nil;
          {$IFDEF DEBUG_LOG}
          log.add(who,where,'Connection manager destroyed',vdebug);
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.status;
          {$ENDIF}
        end; {try}

      finally
        if startDB<>nil then  //we opened/created a db
        begin
          //dbs.buffer.status;

          dbs.removeDB(startDB);
        end;
      end;

    finally
      dbs.Free;
      dbs:=nil;
    end; {try}
    
    {$IFDEF DEBUG_LOG}
    log.add(who,where,format('Tuples created=%d, destroyed=%d (lost=%d)',[uTuple.debugTupleCreate,uTuple.debugTupleDestroy,uTuple.debugTupleCreate-uTuple.debugTupleDestroy]),vDebugHigh);
    log.add(who,where,format('Maximum tuples at once=%d',[uTuple.debugTupleMax]),vDebugHigh);
    log.add(who,where,format('Tuples not cleaned up=%d',[uTuple.debugTupleCount]),vDebugHigh);
    log.add(who,where,format('Tuple rec buffers created=%d, destroyed=%d',[uTuple.debugRecDataCreate,uTuple.debugRecDataDestroy]),vDebugHigh);
    log.add(who,where,format('Tuple recs created=%d, destroyed=%d',[uTuple.debugRecCreate,uTuple.debugRecDestroy]),vDebugHigh);
    log.add(who,where,format('Tuple page lists created=%d, destroyed=%d',[uTuple.debugPagelistCreate,uTuple.debugPagelistDestroy]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,'Page latch total count (lightweight X2): '+intToStr(uPage.debugLatchCount),vDebugHigh);
    log.add(who,where,format('Dynamic allocation=%d, freed=%d',[uMarshal.debugDynamicAllocationGetmem,uMarshal.debugDynamicAllocationFreemem]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,format('Syntax nodes created=%d, destroyed=%d (lost=%d)',[uSyntax.debugSyntaxCreate,uSyntax.debugSyntaxDestroy,uSyntax.debugSyntaxCreate-uSyntax.debugSyntaxDestroy]),vDebugHigh);
    log.add(who,where,format('Extra syntax nodes created by optimiser=%d',[uOptimiser.debugSyntaxExtraCreate]),vDebugHigh);
    log.add(who,where,format('Algebra nodes created=%d, destroyed=%d',[uAlgebra.debugAlgebraCreate,uAlgebra.debugAlgebraDestroy]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,format('File nodes created=%d, destroyed=%d',[uFile.debugFileCreate,uFile.debugFileDestroy]),vDebugHigh);
    log.add(who,where,format('Temp files logically opened=%d, closed=%d',[uTempTape.debugTempTapeBufferCreateNew,uTempTape.debugTempTapeBufferClose]),vDebugHigh);
    log.add(who,where,format('Temp files physically opened=%d, closed=%d',[uTempTape.debugTempTapeCreateNew,uTempTape.debugTempTapeClose]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,format('Relation nodes created=%d, destroyed=%d',[uRelation.debugRelationCreate,uRelation.debugRelationDestroy]),vDebugHigh);
    log.add(who,where,format('Relation index nodes created=%d, destroyed=%d',[uRelation.debugRelationIndexCreate,uRelation.debugRelationIndexDestroy]),vDebugHigh);
    log.add(who,where,format('Relation constraint nodes created=%d, destroyed=%d',[uRelation.debugRelationConstraintCreate,uRelation.debugRelationConstraintDestroy]),vDebugHigh);
    log.add(who,where,format('Catalog relation scans started=%d, stopped=%d',[uDatabase.debugRelationStart,uDatabase.debugRelationStop]),vDebugHigh);
    //todo no problem if not equal (?) so don't show (for now): log.add(who,where,format('Catalog relation search scans started=%d, stopped=%d',[uDatabase.debugFindFirstStart,uDatabase.debugFindFirstStop]),vDebugHigh);
    log.add(who,where,format('Iterator nodes created=%d, destroyed=%d',[uIterator.debugIteratorCreate,uIterator.debugIteratorDestroy]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,format('Stmt nodes created=%d, destroyed=%d',[uStmt.debugStmtCreate,uStmt.debugStmtDestroy]),vDebugHigh);
    log.add(who,where,format('Stmt param nodes created=%d, destroyed=%d',[uStmt.debugStmtParamCreate,uStmt.debugStmtParamDestroy]),vDebugHigh);
    log.add(who,where,format('Stmt error nodes created=%d, destroyed=%d',[uStmt.debugStmtErrorCreate,uStmt.debugStmtErrorDestroy]),vDebugHigh);
    log.add(who,where,format('Routine nodes created=%d, destroyed=%d',[uRoutine.debugRoutineCreate,uRoutine.debugRoutineDestroy]),vDebugHigh);
    log.add(who,where,format('Maximum variable-sets at once=%d',[uVariableSet.debugVariableSetMax]),vDebugHigh);
    log.add(who,where,format('Variable-sets not cleaned up=%d',[uVariableSet.debugVariableSetCount]),vDebugHigh);
    log.add(who,where,'',vDebugHigh);
    log.add(who,where,format('Constraint nodes created=%d, destroyed=%d',[uConstraint.debugConstraintCreate,uConstraint.debugConstraintDestroy]),vDebugHigh);
    log.add(who,where,format('Transaction status nodes created=%d, destroyed=%d',[uTransaction.debugTransStatusCreate,uTransaction.debugTransStatusDestroy]),vDebugHigh);
    log.add(who,where,format('Stmt status nodes created=%d, destroyed=%d',[uTransaction.debugStmtStatusCreate,uTransaction.debugStmtStatusDestroy]),vDebugHigh);
    log.add(who,where,format('Tuple blobs allocated=%d, deallocated=%d (lost=%d)',[uTuple.debugTupleBlobRecAllocated,uTuple.debugTupleBlobRecDeallocated,uTuple.debugTupleBlobRecAllocated-uTuple.debugTupleBlobRecDeallocated]),vDebugHigh);
    log.add(who,where,format('Tuple blob bytes allocated=%d, deallocated=%d (lost=%d)',[uTuple.debugTupleBlobAllocated,uTuple.debugTupleBlobDeallocated,uTuple.debugTupleBlobAllocated-uTuple.debugTupleBlobDeallocated]),vDebugHigh);

    {$ENDIF}

    {$IFDEF WIN32}
    if getProcessWorkingSetSize(ph,minws,maxws) then //note: no good on Win95
      {$IFDEF DEBUG_LOG}
      log.add(who,where,format('Working set size=%d..%d',[minws,maxws]),vDebug);
      {$ELSE}
      ;
      {$ENDIF}
    {$ENDIF}

  finally
    {$IFDEF DEBUG_LOG}
    log.stop;
    {$ENDIF}
  end; {try}
end; {main}


end.


unit uGarbage;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}
//{$DEFINE NO_ACTION}

interface

uses uGlobal, {uServer,} uTransaction, classes, uDatabase;

type
  TGarbageCollector=class(TThread)
    private
      //dbserver:TDBserver;
      fdb:TDB;
      fOriginalRt:StampId;
    public
      tr:TTransaction;       //the current connection/session
      constructor Create(db:TDB);
      destructor Destroy; override;
      procedure execute; override;
  end; {TGarbageCollector}


implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  sysUtils, uOS{for sleep}, uRelation,
     uHeapFile, uHashIndexFile, uPage{for invalidPageId}, uServer;

const
  where='uGarbage';

constructor TGarbageCollector.Create(db:TDB);
{Initialises garbage collector server/db connection
 and finally resumes the thread

 Note: any failure which would prevent execution leaves the thread suspended

 Note: thread is set to freeOnTerminate
}
begin
  inherited Create(True); //i.e. create suspended
  freeOnTerminate:=True;

  //dbserver:=dbs;
  fdb:=db;
  if fdb<>nil then
  begin
    tr:=TTransaction.Create;
    tr.thread := self;

    tr.ConnectToDB(fdb); //   (we have to here because we need a db to have a transaction and
                         //    to be able to lookup details in sys catalog)

    if tr.Start<>ok then //todo ok? //defaults to next tran
      exit; //abort without resuming

    fOriginalRt:=tr.tranRt; //remember our real transaction ref so we can commit successfully
                            //although note below that we never read or write as ourself

    tr.isolation:=isReadCommitted; //read committed records, i.e. only purge records that are earlier than solid record headers
                                   //todo: or maybe set to isGarbageCollector?
                                   //      safer (like index-rebuild) to use isSerializable to ensure we don't clear future records that others may need...?
                                   //      I think we might have been getting away with it because we only currently run at startup (& not for a long time)

    tr.authName:='GARBAGE COLLECTOR'; //todo: use constant
    //todo set authId else others will think we are not connected?? = good for licence counting...
    //todo - why not just connect as GARBAGE_COLLECTOR?

    tr.tranRt:=tr.GetEarliestActiveTranId; //we read as if we were the earliest active transaction & purge any prior garbage
    tr.sysStmt.fRt:=tr.tranRt; //i.e. ensure sysStmt we use to read is also set: 27/03/02
    tr.sysStmt.fWt:=tr.tranRt; //i.e. ensure sysStmt we use to write is also set: 27/03/02
    //note: we currently write as latest tranId (i.e. our Wt)
    // - this could be good because it might prevent older transactions from updating our purged slots = safe but should never happen
    // - otherwise we could make Wt = new Rt for consistency? but doesn't seem as correct... & may be useful to know that we were the tran that purged
    //- also Wt is currently used to restore Rt just before commit to ensure in-place update
    //note+ Wt seems to get set to our updated Rt somewhere along the line (but we now use fOriginalRt to restore before commit)
  end
  else //no catalog is open for us to connect to
    exit; //abort without resuming

  //todo: use uOS...
  {$IFDEF LINUX}
  priority:=0;  //todo: lowest?
  {$ELSE}
  priority:=tpIdle;
  {$ENDIF}

  Resume;
end; {Create}

destructor TGarbageCollector.Destroy;
const routine=':destroy';
begin
  if tr<>nil then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(tr.sysStmt.who,where+routine,format('Garbage collector is being destroyed',[nil]),vDebugLow);
    {$ENDIF}

    {if still active (i.e. not killed by db closedown) - auto commit}
    if tr.tranRt.tranId<>InvalidStampId.tranId then
    begin
      {Before we commit, we must revert back to our original tranId
       (else versioning happens in sysTran = bad! 19/02/03)
      }
      tr.tranRt:=fOriginalRt;
      tr.sysStmt.fRt:=tr.tranRt; //i.e. ensure sysStmt we use to read is also set: 27/03/02
      tr.sysStmt.fWt:=tr.tranRt; //i.e. ensure sysStmt we use to write is also set: 27/03/02
      tr.commit(tr.sysStmt); //rollback instead? - cleaner to commit!
    end
    else
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,'Garbage collector is not connected to a valid db - (create catalog disconnected?) will skip commit',vAssertion);
      {$ELSE}
      ;
      {$ENDIF}

    tr.DisconnectFromDB; //check ok here - assert instead?

    tr.Free;
    tr:=nil;
  end;
  //else failed to start, e.g. missing db

  inherited Destroy;
end; {Destroy}


procedure TGarbageCollector.execute;
{
}
const routine=':execute';
var
  i:integer;
  res:integer;

  sysTableR:TRelation;
  r:TRelation;
  isView:boolean;
  viewDefinition:string;
  rnoMore,noMore:boolean;

  schema_name:string;
  table_auth_id:integer; //auth_id of table schema owner => table owner
  crippledStartPage:integer;
  bigStartPage:int64;
  startPage:PageId; //note: many of these are used for more than one table below
  table_schema_id,table_table_Id:integer;
  filename,tableName,tableType:string;
  indexType:string;
  tableName_null,filename_null,startPage_null,table_table_Id_null:boolean;
  indexType_null,tableType_null,dummy_null:boolean;

  sysSchemaR:TObject; //Trelation
  readBeforeZap:boolean;

  //note: these could both be combined into a higher level object, i.e. TDBFile?
  garbageFile:THeapFile;
  garbageIndexFile:THashIndexFile;
begin
 //todo exit if tr=nil

 try //to avoid strange crash when r fails to open & then tries to free twice...

  {$IFDEF DEBUG_LOG}
  log.add(tr.sysStmt.who,where+routine,formatDateTime('"Garbage collector starting at "c',now),vDebugLow);
  {$ENDIF}
  {$IFDEF DEBUG_LOG}
  log.add(tr.sysStmt.who,where+routine,format('Garbage collector starting as %d with earliest active transaction of %d',[tr.sysStmt.Wt.tranId,tr.sysStmt.Rt.tranId]),vDebugLow);
  {$ENDIF}

  //note: maybe better to use catalogRelationStart with local tr handle?
  if terminated then exit;

  {todo:
        read the last time this was run: could be
             1:in-progress -> read last processed point & move to it & continue...
             2:last-run at tranId=X -> wait until latestTid-lastrun > sweepInterval & then start
  }
  {$IFNDEF NO_ACTION}
  r:=TRelation.create;
  sysTableR:=TRelation.create;
  try
    {Try to open sysTable}
    if sysTableR.open(tr.sysStmt,nil,sysCatalogDefinitionSchemaName,sysTable_table,isView,viewDefinition)=ok then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,format('Garbage collector opened %s',[sysTable_table]),vDebugLow);
      {$ENDIF}
    end
    else
    begin
      {$IFDEF DEBUG_LOG}
      log.add(tr.sysStmt.who,where+routine,format('Garbage collector failed to open %s',[sysTable_table]),vDebugError);
      {$ENDIF}
      Terminate;
      exit; //abort
    end;

    //note: following line was moved here from inside main loop so that we only scan once
    noMore:=False;

    {Main loop}
    while not terminated do
    begin
      //todo wait here or move to continuation point...
      {todo:
            1:in-progress = read next tuple/page/relation until eodb, then do other clean up stuff (phase2)
            2:last-run at tranId=X = wait (=sleep(0?) & continue) here until latestTid-lastrun > sweepInterval & then start at sysTable

            so store: lastRunAsTran
                      lastTableId  (but what if insert at start of sysTable?)
                      lastPageId   (but what if no longer exists?)
            in dbHeader
      }

      if not noMore then
        if sysTableR.scanStart(tr.sysStmt)<>ok then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Garbage collector failed to start scan on %s',[sysTable_table]),vDebugError);
          {$ENDIF}
          Terminate;
          exit; //abort
        end;

      {Process loop}
      while (not terminated) and (not noMore) do
      begin
        if sysTableR.ScanNext(tr.sysStmt,noMore)=ok then
        begin
          if not noMore then
          begin
            sysTableR.fTuple.GetString(ord(st_Table_Type),tableType,tableType_null);

            {todo if in-progress = skip to last table/page}
            if tableType<>ttView then
            begin //base table
              {Try to open relation}
              sysTableR.fTuple.GetInteger(ord(st_Schema_id),table_schema_id,dummy_null);  //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
              {We need to read the schema name}
              if tr.db.catalogRelationStart(tr.sysStmt,sysSchema,sysSchemaR)=ok then
              begin
                try
                  if tr.db.findCatalogEntryByInteger(tr.sysStmt,sysSchemaR,ord(ss_schema_id),table_schema_id)=ok then
                  begin
                    with (sysSchemaR as TRelation) do
                    begin
                      fTuple.GetString(ord(ss_schema_name),schema_name,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      fTuple.GetInteger(ord(ss_auth_id),table_auth_Id,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                      //todo major/minor versions
                      {$IFDEF DEBUGDETAIL}
                      {$IFDEF DEBUG_LOG}
                      //log.add(tr.sysStmt.who,where+routine,format('Found schema %s owner=%d (from table)',[schema_name,table_auth_id]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                    end; {with}
                  end
                  else
                  begin  //schema not found
                    {$IFDEF DEBUG_LOG}
                    log.add(tr.sysStmt.who,where+routine,format('Failed finding table schema details %d',[table_schema_id]),vError);
                    {$ENDIF}
                    continue; //abort - try next relation
                  end;
                finally
                  if tr.db.catalogRelationStop(tr.sysStmt,sysSchema,sysSchemaR)<>ok then
                    {$IFDEF DEBUG_LOG}
                    log.add(tr.sysStmt.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError); //todo abort? fix! else possible server crunch?
                    {$ELSE}
                    ;
                    {$ENDIF}
                end; {try}
              end
              else
              begin  //couldn't get access to sysSchema
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError); 
                {$ENDIF}
                continue; //abort - try next relation
              end;

              sysTableR.fTuple.GetString(ord(st_Table_Name),tableName,tableName_null);

              //note: if we are sysTran then avoid garbage collection - currently assumes tranId=slotId!!!
              //- no it doesn't - we record fRID during transaction.start... so ok to purge...(check!)
              //- actually should never need to purge - should never version!
              //   since commit always overwrite-deletes original slot, leaving it free for re-use
              //   so, purging may reduce maximum page allocation for systran which might not be a good thing!
              //- seemed to purge too much of sysTran? & after crash shows all versions!
              //so for now we'll skip...
              //- this was because tuple.garbageCollect now zaps invisible header records
              //  - assumes they're rolled-back if old & so this purged all rolled-back list!!!

              //todo: we do need to remove any old rolled-back entries from sysTran once we're sure
              //      we've garbage collected any associated records from the whole database...
              if tableName='sysTran' then  //todo use table number or constant...
                continue; //skip
              if tableName='sysTranStmt' then  //todo use table number or constant...
                continue; //skip

              {$IFDEF DEBUG_LOG}
              log.add(tr.sysStmt.who,where+routine,format('Garbage collector processing: %s.%s ',[schema_name,tableName]),vDebugLow);
              {$ENDIF}

              sysTableR.fTuple.GetString(ord(st_file),filename,filename_null);
              sysTableR.fTuple.GetBigInt(ord(st_first_page),bigStartPage,startPage_null);
              StartPage:=bigStartPage;
              sysTableR.fTuple.GetInteger(ord(st_table_id),table_Table_Id,table_table_Id_null);

              //todo: now if inProgressFindingTable, continue if not required table_id... else inProgressFindingPage...
              // => isolate next section into separate routine so in future can garbage(table_id)

              {Note: we use relation here to gain access to all associated indexes}
              if r.open(tr.sysStmt,nil,schema_name,tableName,isView,viewDefinition)=ok then
              begin   
                try
                  //todo ignore virtual relations!

                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(tr.sysStmt.who,where+routine,format('Garbage collector opened %s',[tableName]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  readBeforeZap:=False;
                  {Do we care what we zap?}
                  if tableName=sysTable_table{todo use table number=less ambiguous but not fixed?} then readBeforeZap:=True; //we need to know which tables we can de-allocate
                  if tableName=sysIndex_table{todo use table number=less ambiguous but not fixed?} then readBeforeZap:=True; //we need to know which tables we can de-allocate

                  if r.scanStart(tr.sysStmt)<>ok then
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(tr.sysStmt.who,where+routine,format('Garbage collector failed to start scan on %s',[tableName]),vDebugError);
                    {$ENDIF}
                    continue; //abort - try next relation
                  end;
                  rNoMore:=False;
                  i:=0;

                  while (not Terminated) and (not rNoMore) do
                  begin
                    {todo!!!!
                    if stmt.status=ssCancelled then
                    begin
                      result:=Cancelled;
                      exit;
                    end;
                    }

                    res:=r.ScanNextGarbageCollect(tr.sysStmt,rNoMore,readBeforeZap);  //Note: this garbage collects the next record (& so could in theory read several pages)
                    {Note: if we crash now, we will lose the ability to deallocate any used space since
                           we will have zapped the catalog entry but not the page chain.
                           i.e. garbage collecting is not transactioned(!) so do in reverse.
                           todo: so: 1) pre-read garbage that has allocations (e.g. sysTable, sysIndex etc.)
                                     2) de-allocate from end of chain to start (since start-page is catalogued)
                                     3) re-pass garbage and zap (if nothing allocated)
                                 or: have a clever reclaimer (e.g. dump/reload) - will need anyway...

                     We have to de-allocate here because (e.g. table) records cannot be reclaimed when (e.g. table is) dropped in case the DROP is rolled-back!
                    }
                    {Note: this garbage collecting scans through the whole db file and fills the buffer with
                           pages only we need, possibly throwing other pages out
                           TODO: we must set these buffer frames to 'flush immediately' somehow... scan policy?
                    }
                    if res<>fail then
                    begin
                      if not rNoMore then
                      begin
                        if res=+1 then
                        begin
                          {$IFDEF DEBUGDETAIL}
                          {$IFDEF DEBUG_LOG}
                          if not readBeforeZap then
                            log.add(tr.sysStmt.who,where+routine,format('Garbage collector purged a deleted row',[nil]),vDebugLow)
                          else
                            log.add(tr.sysStmt.who,where+routine,format('Garbage collector purged a deleted row in %s: %s',[r.relname,r.fTuple.Show(tr.sysStmt)]),vDebugLow);
                          {$ENDIF}
                          {$ENDIF}

                          //Note: if not readBeforeZap then we can't see the deleted tuple...

                          //todo: if we are sysTran: then we will have zapped old committed records

                          {Table space de-allocation}
                          if tableName=sysTable_table{todo use table number=less ambiguous but not fixed?} then
                          begin
                            {Note: no one can add any more rows - this table is history}
                            r.fTuple.GetString(ord(st_file),filename,filename_null);
                            r.fTuple.GetBigInt(ord(st_first_page),bigStartPage,startPage_null);
                            StartPage:=bigStartPage;
                            {Now open the heap file and zap it}
                            garbageFile:=nil;
                            garbageFile:=THeapFile.create;
                            try
                              if startPage_null or (garbageFile.openFile(tr.sysStmt,filename,startPage)<>ok) then  {short-circuit}
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(tr.sysStmt.who,where+routine,format('Failed opening file %s',[filename]),vDebugError);
                                {$ENDIF}
                                continue; //next
                              end;
                              if garbageFile.deleteFile(tr.sysStmt)<>ok then
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(tr.sysStmt.who,where+routine,format('Failed deleting file %s',[filename]),vDebugError);
                                {$ENDIF}
                                continue; //next
                              end;
                              {Flush all pages to save any de-allocations and garbage collections, else leave table entry lying around}
                              (tr.db.owner as TDBServer).buffer.flushAllPages(tr.sysStmt);
                            finally
                              garbageFile.free;
                            end; {try}
                          end;

                          {Index space de-allocation}
                          if tableName=sysIndex_table{todo use table number=less ambiguous but not fixed?} then
                          begin
                            {Note: no one can add any more keys - this index is history}
                            r.fTuple.GetString(ord(si_index_Type),indexType,indexType_null);
                            r.fTuple.GetString(ord(si_file),filename,filename_null);
                            r.fTuple.GetBigInt(ord(si_first_page),bigStartPage,startPage_null);
                            StartPage:=bigStartPage;
                            //todo check si_status?
                            {Now open the index file and zap it}
                            garbageIndexFile:=nil;
                            if IndexType=itHash then garbageIndexFile:=THashIndexFile.Create;
                            if garbageIndexFile=nil then
                            begin
                              {$IFDEF DEBUG_LOG}
                              log.add(tr.sysStmt.who,where+routine,format('Unknown index type %s',[IndexType]),vDebugError);
                              {$ENDIF}
                              continue; //next
                            end; {case}
                            try
                              //Note: we don't set owner or indexId or indexState: should really?
                              if startPage_null or (garbageIndexFile.openFile(tr.sysStmt,filename,startPage)<>ok) then  {short-circuit}
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(tr.sysStmt.who,where+routine,format('Failed opening index file %s',[filename]),vDebugError);
                                {$ENDIF}
                                continue; //next
                              end;
                              if garbageIndexFile.deleteFile(tr.sysStmt)<>ok then
                              begin
                                {$IFDEF DEBUG_LOG}
                                log.add(tr.sysStmt.who,where+routine,format('Failed deleting index file %s',[filename]),vDebugError);
                                {$ENDIF}
                                continue; //next
                              end;
                              {Flush all pages to save any de-allocations and garbage collections, else leave index entry lying around}
                              (tr.db.owner as TDBServer).buffer.flushAllPages(tr.sysStmt);
                            finally
                              garbageIndexFile.free;
                            end; {try}
                          end;

                          //todo: if we are sysColumn: chance to remove column data from every row!
                                  //- unless these were a consequence of table drop!
                          //etc.!

                        end;

                        //todo: now if inProgressFindingPage, continue if not required page_id... else inProgress...
                        // => isolate next section into separate routine so in future can garbage(page_id)

                        {todo: ensure we read everything & then vacuum}
                        inc(i);
                        //todo move these comments to tuple.garbagecollect
                        {note: vacuum can:
                          1. mark old delta slots free if no affect on index (excludes 'deletes' and 'pk updates' & so any prior versions)
                             +: quick (single data scan)
                             -: leaves garbage in index + garbage in table

                          2. mark old delta slots free & update indexes (so includes freeing 'deleted' rows)
                             +: leaves clean index + clean table
                                (index page faults are only for 'deleted' or 'pk-mod' rows = rare!)
                             -: slow (single data scan + random index page faults)

                          3. mark old delta slots free & leave indexes (so includes freeing 'deleted' rows)
                             +: leaves clean table
                                quick (single data scan)
                             -: leaves garbage in index (probably needing re-build to clean)

                          Note: scanning & cleaning index leaving table dirty would be very slow for little benefit


                          each of the above can optionally then re-organise each page or not

                          in all cases, new page free space should be updated in table dir-pages (no need to flush)
                          in some cases:
                             1. might be worth re-building index after vacuum 2 instead of mods during (or vacuum 3 & then backup & restore?)
                             2. might be worth re-orging entire table - separate job? e.g. backup & restore!

                          could decide on table-by-table basis!

                          Summary:
                            either 1 or 2
                            OR 3 and index rebuild (but needs to be offline/ex-locked for index rebuild!)
                            Choice depends on table stats & server idleness...
                            Notes in favour of 3:
                              IB up to v5 did 3 (and with bigger keys)!
                              Quickest to run
                              Easiest to implement (could add re-build fix later...)
                              Leaves data clean = bulk of space (& probably no real loss of index speed?)
                              Index entries tend to remain static, except for deletes
                              Deletes could be easily removed from index...?

                        }

                        //todo flush checkpoint=table-id:page-id (e.g. every 10/100 pages or so)
                      end;
                      //else no more
                    end;
                    //todo else error?
                  end; {while scan}

                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  //Note: this total includes purged rows
                  log.add(tr.sysStmt.who,where+routine,format('Garbage collector counted %d rows',[i]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}

                  {Flush all pages to save any de-allocations and garbage collections}
                  (tr.db.owner as TDBServer).buffer.flushAllPages(tr.sysStmt);
                finally
                  r.scanStop(tr.sysStmt);
                  r.close;
                end; {try}
              end
              else
              begin
                {$IFDEF DEBUG_LOG}
                log.add(tr.sysStmt.who,where+routine,format('Garbage collector failed to open %s',[tableName]),vDebugError);
                {$ENDIF}
                //continue...
              end;
            end;
            //else view = no storage
          end
          else
          begin
            {$IFDEF DEBUG_LOG}
            log.add(tr.sysStmt.who,where+routine,format('Garbage collector finished scan of %s',[sysTable_table]),vDebugLow);
            {$ENDIF}
            //todo do phase 2...
          end;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(tr.sysStmt.who,where+routine,format('Garbage collector failed to scan next on %s',[sysTable_table]),vDebugError);
          {$ENDIF}
          Terminate;
          exit; //abort
        end;

        //todo flush checkpoint=table-id

        sleepOS(0); //relinquish rest of time slice - we'll return immediately if nothing else to do
      end; {process loop}

      //todo: only scanStop here if we've just done a scan...
      sysTableR.scanStop(tr.sysStmt);

      //todo!! delete all rolled-back (in-process, assert should be none!?)
      //           entries from sysTran/sysTranStmt that are < our Rt!!!!!
      //           this will reduce all future transaction overheads!!!
      //           Note: flush all first!!! missing rolled-back entries are
      //           a nightmare if incorrect!
      //        ONLY IF WE'VE JUST GARBAGE-COLLECTED EVERY TABLE IN THE DATABASE!

      //todo: skip to next catalog open on this server

      //For now, we terminate this thread after one startup pass...just to be safe...
      //todo we should remove this & give control to the db/server - suicide is hard to debug!
      {$IFDEF DEBUG_LOG}
      if not terminated then
        log.add(tr.sysStmt.who,where+routine,format('Garbage collector has finished & is terminating itself',[nil]),vDebugHigh)
      else
        log.add(tr.sysStmt.who,where+routine,format('Garbage collector has been terminated',[nil]),vDebugHigh);
      {$ENDIF}
      terminate; //todo: safer if db/server does this? & main doesn't create/start us...
      exit;

      sleepOS(0);      //relinquish rest of time slice
      sleepOS(5*1000); //wait before re-checking for sweep
                     //todo: wait much longer than this! - but does it stop us shutting down?
                     //todo: so maybe waitForObject & have main loop send wake-up requests every few minutes...
    end; {main loop}
  finally
    if sysTableR<>nil then
    begin
      sysTableR.Close;
      sysTableR.free;
      sysTableR:=nil;
    end;

    if r<>nil then
    begin
      r.free;
      r:=nil;
    end;
  end; {try}
  {$ENDIF}
 except
   //todo log message?
   terminate;
 end;{try}
end; {execute}


end.

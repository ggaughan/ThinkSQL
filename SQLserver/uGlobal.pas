unit uGlobal;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Global system definitions
 Note: should not use any other unit (ideally)
}

{Note: here seems a good place to put some 'global' comments about the source:

 Comment keywords:
   todo
       obviously stuff to be done. Not always mandatory though. Sometimes
       just suggestions/hints/ideas thought of during coding.
       Modifiers:
         *** or !!!
           usually is important and needs doing urgently.
         future
           suggestion for a future/advanced version
         remove
           remove this section/comment - garbage left lying around
         debug
           remove or surround with compiler debug switch - temporary diagnostics

   speed (& sometimes /memory)
       usually alongside a comment about how to improve the speed of a routine
       (often initial code is simple but slow so major increases are possible)
}
{$I Defs.inc}
interface

uses
 uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for date/time types},
 sysUtils {for Exception}
 ;

type
  TBit=0..31;

  //todo maybe make all these enumerations 32-bit using $MINENUMSIZE 4 - speed? (check doesn't affect storage)
  TriLogic=(isTrue,isFalse,isUnknown);

  //todo: move to a common IterJoin routine?
  TjoinType=(jtInner,jtLeft,jtRight,jtFull,jtUnion);  //Note: if change, update JoinTypeToStr routine

  TsetType=(stUnion,stExcept,stIntersect,
            stUnionAll,stExceptAll,stIntersectAll
           );            //Note: if change, update SetTypeToStr routine

  {from uEvalCondExpr}
  Taggregation=(agNone,agStart,agNext,agStop);  //aggregation stages to either increment or retrieve working totals

  {from uPage}
  PageId=cardinal; {Integer;} //disk block seek reference => theoretical db size of (4 billion * block-size) bytes
                              //done: Note: could use special InvalidPageId value & use cardinal => 4 billion...?

  {from uTransaction}
  StampId=record
            tranId:cardinal;
            stmtId:cardinal;
                             //todo: limits number of insert/update/deletes to 4 billion per transaction = too small? at least assert error if we reach it else strange things happen!
          end; {stampId}
  TAuthId=word;    //maps to db table
  
  TSchemaId=word;  //maps to db table
  TCatalogId=word; //will map to system/db table

  {Structure for storing rolled-back(=aborted) stmts within part-rolled-back transactions
   (both current tran & uncommited history list where status=ptPartRolledBack)}
  TstmtStatusPtr=^TstmtStatus;
  TstmtStatus=record
    tid:StampId; //Note: tranId never used (but may be useful in future structures)
    next:TstmtStatusPtr;
  end; {TstmtStatus}
  {Structure for storing uncommitted transactions with each new transaction}
  TtranStatusPtr=^TtranStatus;
  TtranStatus=record
    tid:StampId; //Note: in future stmtId could be stored & so used for storing lastest Rt.stmtId
    status:string[1];
    rolledBackStmtList:TstmtStatusPtr; //Pointer to rolled-back stmts if status=tsPartRolledBack
    next:TtranStatusPtr;
  end; {TtranStatus}


  {from uStmt}
  TstmtStatusType=(ssInactive,     //todo: in future probably split Inactive into notPrepared & prepared
                   ssActive,
                   ssCancelled
                  );

  TstmtType=(stUser,
             stUserCursor, //todo same as stUser?
             stSystemUserCall,
             stSystemDDL,
             stSystemConstraint
            );

  {from uFile}
  DirSlotId=integer;  //file directory

  {from uTuple}
  ColRef=word;                       //column subscript (depends on MaxCol) (limits # cols=65535 - but so does ODBC, I think (or even 32767!))
                                     //also used to store col count in rec header

  {Base column disk storage types} //Note: ord() stored externally, so only grow at ends
  TstorageType=(stUnknown,stBigInt,stInteger,stSmallInt,stString,stDouble,stComp,stDate,stTime,stTimestamp,stBlob);
  {Base column data types} //Note: keep in synch. with TYPE_INFO table //Note: ord() stored externally, so only grow at ends
  TDataType=(ctUnknown,ctChar,ctVarChar,ctBit,ctVarBit,ctNumeric,
             ctDecimal,ctBigInt,ctInteger,ctSmallInt,ctFloat,
             ctDate,
             ctTime,ctTimeWithTimezone,
             ctTimestamp,ctTimestampWithTimezone,
             ctBlob,ctClob);
    //todo replace stDouble with stComp and store all floats/numeric/decimal as integers with implied decimal places
    //- gives proper accuracy (maybe leave float as double? - just for numeric/decimal e.g. for money)
    //Note: started this process with Set/GetComp...
    //todo: to save disk space we could store times without timezones in a slightly smaller structure (save ~4 bytes per time)
    //      plus could make this 2 bytes & save 2 bytes per time by storing timezone sign in hour/minute 
  //todo remove use constraints instead: Tnulls=array [0..1] of char; {compatible with pchar} //todo replace with boolean (just need to convert to char for disk read/write)

  {Base column definitions (map data types onto storage types)}
  TDataTypeDef=array [ctUnknown..ctClob] of TstorageType;

  {Admin role types} //Note: ord() stored externally (& in info_schema case), so only grow at ends
  TadminRoleType=(atNone,atAdmin);

  {Privilege types} //Note: ord() stored externally (& in info_schema case), so only grow at ends (also grant All loop is based on current ends)
  TprivilegeType=(ptSelect,ptInsert,ptUpdate,ptDelete,ptReferences,ptUsage,ptExecute);

  {Option types} //Note: ord() stored externally in sysOption (but not relied on?)
  ToptionType=(otOptimiser); //todo update range below & in database create/open routines

  //keep these in sync. with the virtualfile definitions: especially the status groupings defined by sysStatus
  {sysServer rows}
  TsysServer=(ssMain);

  {sysStatusGroup rows}
  TsysStatusGroup=(
                   {$IFDEF DEBUG_LOG}
                   ssDebug,
                   {$ENDIF}
                   
                   ssProcess,
                   ssMemory,
                   ssCache,
                   ssTransaction);

  {sysStatus rows}
  TsysStatus=(
              {$IFDEF DEBUG_LOG}
              ssDebugSyntaxCreate,ssDebugSyntaxDestroy,
              {$ENDIF}

              ssProcessUptime,

              ssMemoryManager,ssMemoryHeapAvailable,ssMemoryHeapCommitted,ssMemoryHeapUncommitted,
              ssMemoryHeapAllocated,ssMemoryHeapFree,

              ssCacheHits, ssCacheMisses,

              ssTransactionEarliestUncommitted);

  //todo? move to(/from) uConstraint
  {Constraint rule types} //Note: ord() stored externally, so only grow at ends
  TconstraintRuleType=(rtUnique,rtPrimaryKey,rtForeignKey,rtCheck); //note: not-null is shorthand for check
  {Constraint foreign-key rule match types} //Note: ord() stored externally, so only grow at ends
  TconstraintFKmatchType=(mtSimple,mtPartial,mtFull);
  {Constraint foreign-key referential action types} //Note: ord() stored externally, so only grow at ends
  TconstraintFKactionType=(raNone,raCascade,raRestrict,raSetNull,raSetDefault);

  {Isolation behaviour} //note: text is in TDB.showTransactions
  Tisolation=(isSerializable,isReadCommitted,
              isReadUncommitted,
              isReadCommittedPlusUncommittedDeletions{internal},isReadUncommittedMinusUncommittedDeletions{internal});

  {from uOptimiser}
  {Optimiser algebra node hint}
  ToptimiserSuggestion=(osUnprocessed,osProcessed,osMergeJoin);

  {from uDatabase} //todo move to a new unit - uSysCatalog?
  {System catalog}

  {Each catalog table has a unique reference.
   This will be used by the Tdb and Ttransaction to keep an array of relations
   making up a central/shared and/or local/independent system catalog.
   Currently, only central (Tdb) routines will be used to access both kinds to
   allow future enhancements and centralised incrementation control etc.
  }
  catalogRelationIndex=(sysTran,
                        sysTranStmt,        
                        sysAuth,
                        sysTableColumnPrivilege,
                        sysRoutinePrivilege,
                        sysSchema,
                        sysDomain,
                        sysConstraint,
                        sysConstraintColumn,
                        sysDomainConstraint,
                        sysTableColumnConstraint,
                        sysIndex,
                        sysIndexColumn,
                        sysRoutine,
                        sysParameter,
                        sysGenerator,
                        sysTable,
                        sysColumn
                        //todo etc.
                        //Note: if change start/end - update loops in Tdb routines!
                       );

  {Column definitions needed for sysTable and sysColumn to bootstrap a new database
   & rest of catalog tables are built by SQL after bootstrapping}
  sysTable_columns=(st_Table_Id,
                    st_Table_Name,
                    st_Schema_id,
                    //todo need creator, since in SQL3 creator might not be schema owner
                    st_File,
                    st_First_page,
                    st_Table_Type,
                    st_View_definition,
                    st_Next_Col_id
                    //todo remarks
                    );

  sysColumn_columns=(sc_Table_Id,
                     sc_Column_id,
                     sc_column_name,
                     sc_domain_id,     //populated when created, but not linked - use sc_datatype
                     sc_reserved_1,    //todo remove: not needed
                     sc_datatype,      //one of Tdatatype
                     sc_width,
                     sc_scale,
                     sc_default,       //todo change name -clash with Windows & (reserved SQL word)!=> hard to track bugs! val=61972
                     sc_reserved_2     //todo remove: not needed
                     //todo remarks
                     );

  {Column definitions needed for sysGenerator because we manipulate it directly
   for speed & central/non-versioning updates}
  //todo we also need same thing for sysTran, instead of using 0 and 1!
  //todo we also need same thing for sysTranStmt, instead of using 0,1 and 2!
  sysGenerator_columns=(sg_Generator_Id,
                        sg_Generator_name,
                        sg_Schema_id,
                        sg_start_at,
                        sg_Generator_next,
                        sg_increment,
                        sg_cache_size,
                        sg_cycle
                       );

  {Column definitions needed to sys search sysSchema}
  //todo keep in sync. with creation!
  sysSchema_columns=(ss_catalog_id,
                     ss_auth_id,
                     ss_schema_id,
                     ss_schema_name,
                     ss_schema_version_major,
                     ss_schema_version_minor
                    );

  {Column definitions needed to sys search sysDomain}
  //todo keep in sync. with creation!
  sysDomain_columns=(sd_domain_id,
                     sd_domain_name,
                     sd_schema_id,
                     sd_datatype,
                     sd_width,
                     sd_scale,
                     sd_default
                    );

  {Column definitions needed to sys search sysAuth}
  //todo keep in sync. with creation!
  sysAuth_columns=(sa_auth_id,
                   sa_auth_name,
                   sa_auth_type,
                   sa_password,
                   sa_default_catalog_id,
                   sa_default_schema_id,
                   sa_admin_role,
                   sa_admin_option
                  );

  {Column definitions needed to sys search sysTableColumnPrivilege}
  //todo keep in sync. with creation!
  sysTableColumnPrivilege_columns=(scp_table_id,
                                   scp_column_id,
                                   scp_grantor,
                                   scp_grantee,
                                   scp_privilege,
                                   scp_grant_option
                                  );

  {Column definitions needed to sys search sysRoutinePrivilege}
  //todo keep in sync. with creation!
  sysRoutinePrivilege_columns=(srp_routine_id,
                               srp_grantor,
                               srp_grantee,
                               srp_privilege,
                               srp_grant_option
                              );

  {Column definitions needed to sys search sysOption}
  //todo keep in sync. with creation!
  sysOption_columns=(so_Option_id,
                     so_Option_name,
                     so_Option_value,
                     so_Option_text,
                     so_Option_last_modified
                    );

  {Column definitions needed to sys search and copy into memory object sysConstraint}
  //todo keep in sync. with creation & Tconstraint.create etc.!
  sysConstraint_columns=(sco_constraint_id,
                         sco_constraint_name,
                         sco_schema_id,
                         sco_deferrable,
                         sco_initially_deferred,
                         sco_rule_type,
                         sco_rule_check,
                         sco_FK_parent_table_id,
                         sco_FK_child_table_id,
                         sco_FK_match_type,
                         sco_FK_on_update_action,
                         sco_FK_on_delete_action
                         );

  {Column definitions needed to sys search and copy into memory object sysConstraint}
  //todo keep in sync. with creation & Tconstraint.create etc.!
  sysConstraintColumn_columns=(scc_constraint_id,
                               scc_parent_or_child_table,
                               scc_column_id,
                               scc_column_sequence
                              );

  {Column definitions needed to sys search sysTableColumnConstraint}
  //todo keep in sync. with creation!
  sysTableColumnConstraint_columns=(stc_table_id,
                                    stc_column_id,      //null=parent end of FK
                                    stc_constraint_id
                                    );

(*
  //note: we might be able to avoid creating this table
  //      by over-using the sysColumnPrivilege table with column_id=null=>whole table
  //      -wouldn't be totally neat because we also need domain privilege & couldn't foreign key & share table_id...
  {Column definitions needed to sys search sysTablePrivilege}
  //todo keep in sync. with creation!
  sysTablePrivilege_columns=(stp_table_id,
                             stp_grantor,
                             stp_grantee,
                             stp_privilege,
                             stp_grant_option
                             );
*)

  {Column definitions needed to sys search sysIndex}
  //todo keep in sync. with creation
  SysIndex_columns=(si_index_id,
                    si_index_name,
                    si_table_id,
                    si_index_type,
                    si_index_origin,
                    si_index_constraint_id,
                    si_file,
                    si_first_page,
                    si_status
                   );

  {Column definitions needed to sys search sysIndexColumn}
  //todo keep in sync. with creation
  SysIndexColumn_columns=(sic_index_id,
                          sic_column_id,
                          sic_column_sequence
                         );

  {Column definitions needed for sysRoutine}
  //todo keep in sync. with creation
  SysRoutine_columns=(sr_Routine_Id,
                      sr_Routine_Name,
                      sr_Schema_id,
                      sr_Module_id,
                      //todo need creator, since in SQL3 creator might not be schema owner
                      sr_Routine_Type,
                      sr_Routine_definition,
                      sr_Next_Parameter_id
                      //todo remarks
                      );

  {Column definitions needed for SysParameter}
  //todo keep in sync. with creation
  SysParameter_Columns=(sp_Routine_Id,
                        sp_Parameter_id,
                        sp_Parameter_name,
                        //todo remove sc_domain_id,     //populated when created, but not linked - use sc_datatype
                        sp_variabletype, //one of Tvariabletype
                        sp_datatype,     //one of Tdatatype
                        sp_width,
                        sp_scale,
                        sp_default       //todo change name -clash with Windows & (reserved SQL word)!=> hard to track bugs! val=61972
                        //todo remarks
                        );


  {from uIterSort/uIterGroup}
  {Column sort direction}
  TSortDirection=(sdASC,sdDESC);

  EConnectionException=class(Exception);

  TIndexState=(isOk,isBeingBuilt); //todo future ones may be isBeingRemoved, isCorrupt

  {Variable/parameter types} //Note: ord() stored externally, so only grow at ends
  TVariableType=(vtIn,vtOut,vtInOut,vtResult,vtDeclared);
  VarRef=word;                       //variable/parameter subscript (depends on MaxVar) (limits # vars per block=65535)

const
  Title='ThinkSQL Relational Database Management System';
  Version='01.04.00';
  VersionNumber=104; //100 = 1.00 used for licence checking
  Copyright='Copyright © 2000-2012 Greg Gaughan';

  serverName='THINKSQL'; //also used surfaced in sysServer table 

  licenceFilename='ThinkSQL.lic';

  TCPservice='thinksql';      //TCP/IP service => port (via services file, so user-configurable but installed with default)
                              //todo get from registry/command-line or somewhere: allow multiple servers on same PC in future...
  TCPport=9075;               //TCP/IP port number in case above service is not available

  dbStructureVersionMajor=1; //on-disk structure version stored in db header page (0)
  dbStructureVersionMinor=0; //used to prevent old versions of server opening/using later db versions
                             //also for later versions of server to be able to read older db versions
                             //      also maybe for db conversion programs to recognise db files...

  dbCatalogDefinitionSchemaVersionMajor=1; //system catalog structure version stored in sysSchema
  dbCatalogDefinitionSchemaVersionMinor=01;
  {                                     00    last used 01.02.00 - now store routine definitions as CLOBs
  }

  serverCLIversion=0100;  //used for client/server CLI protocol
  {                0092   last used 00.04.09 beta (ODBC 00.04.09) - now pass bufferSize to SQLgetData for blob chunking + integer size column width + more handshake details
                   0091   last used 00.04.04 beta (ODBC 00.04.02) - now pass stored procedure result sets
  }

  {Function results
   -ve = critical error
     0 = ok
   +ve = warning/info code
  }
  Iterating=-101;  //for executePlan block continuation
  Leaving=-100;    //for executePlan block breakouts
  Cancelled=-99;
  Fail=-1;
  OK=0;
  noData=1; //used by TTuple.read
  SQL_NO_DATA='02000'; //SQLSTATE for cursor checks
  SQL_SUCCESS='00000'; //SQLSTATE for cursor checks

  TAB=#9;
  CR=#13;
  LF=#10;
  CRLF=CR+LF; //CR LF for end of each output line sent to client socket

  LABEL_TERMINATOR=':'; //keep in sync. with lex {label} - used to match leave labels

  {from uPage}
  InvalidPageId:pageId=$FFFFFFFF; //i.e. maxCardinal(32-bit) //old:-1; (*$7FFFFFFE; {while still crippled in catalog}*)

  {from uTransaction}
  InvalidStampId:StampId=(tranId:0;stmtId:0);  //Note: no need when comparing to compare stmtId
  InvalidAuthId=0;
  MAX_WORD=$FFFF; //65535
  MAX_CARDINAL=$FFFFFFFF; //2147483647; //todo increase to 4294967295 since we store 4 bytes!
  MaxStampId:StampId=(tranId:MAX_CARDINAL-1;stmtId:MAX_CARDINAL-1); //todo replace with formula for max(tranId type) //Note: no need when comparing to compare stmtId
                                    //todo ensure we never reach this limit! reserved for all-seeing stuff!
  TRAN_COMMITTED_ALLOCATION_SIZE=8192; //allocation size of array of committed transactions //these are bits, so 8192 = 1024 bytes
                                       // *2 for partially-committed array
  InvalidTranCommittedOffset=MAX_CARDINAL; //initial value during db startup (=max+1)

  DefaultIsolation=isSerializable;

  {Note: db recovery rolls back all active (non-partrolledBack) transactions}
  tsHeaderRow='N';
  tsInProgress='P';
  tsRolledBack='R';
  tsPartRolledBack='r';

  {from uTuple}
  InvalidTableId=0;   //used for default colDef.sourceTableId
  SyntaxTableId=-1;   //used for syntax relation sourceTableId for privilege skipping //Note: could assume InvalidTableId instead, but not as secure?
  MaxCol=300;         //max columns per tuple
                      //Note: we need to be able to extend this (for internal tuples)
                      // when joining relations, e.g. 3 relations => 3*255 potential columns
                      //Use an expandable array? - i.e. retain direct access for speed

  {Maps TDatatype onto TStorageType - keep in sync! - treat like a function}
  DatatypeDef:TDataTypeDef=(stUnknown,                             //not used for storage - just to map ctUnknown
                            stString,stString,stString,stString,   //char,varchar,bit*,varbit*
                            {todo remove stDouble,stDouble,                     //numeric*,decimal*}
                            stComp,stComp,                         //numeric*,decimal*
                            stBigInt,                              //bigint
                            stInteger,stSmallInt,                  //integer,smallint
                            stDouble,                              //float
                            stDate,                                //date*
                            stTime,stTime,                         //time*,timeWithTimezone*
                            stTimestamp,stTimestamp,               //timestamp*,timestampWithTimezone*
                            stBlob,stBlob                          //blob,clob
                            );                                     //*=processed, else raw
  {Column definition defaults for SQL}
  DefaultNumericPrecision=15;
  DefaultNumericScale=0;
  DefaultRealSize=32;        //passed as FLOAT(x)
  DefaultDoubleSize=64;      //passed as FLOAT(x)
  DefaultTimeScale=0;
  DefaultTimestampScale=6;

  {Used for deferrable flags - todo anything else?}
  No='N';
  Yes='Y';

  NoYes:array [boolean] of string=(No,Yes);

  nullShow='<null>';


  {from uDatabase (and some from uTuple)}
  CACHE_GENERATORS_DEFAULT_SIZE=20; //number of generator values to cache per hit
                                    //(note: actually caches 1 less than this, but on disk, appears to be caching in increments of this number)
                                    //Note: must be > 1 to be any use since
                                    // we use a cached number when initialising the cache and again before working out if they're all gone
                                    //0 or 1 => ignore caching

  DB_FILE_EXTENSION='.dat';

  MaxNumericPrecision=17;

  //We don't store unused characters, so these are only a limitation, not a minimum storage amount
  MaxGeneric=128;               //todo extend!
  MaxCatalogName=MaxGeneric;
  MaxAuthName=MaxGeneric;
  MaxSchemaName=MaxGeneric;
  MaxTableName=MaxGeneric;
  MaxColName=MaxGeneric;
  MaxRangeName=MaxGeneric;      //max table range/name length
  MaxFileName=MaxGeneric;

  MaxVarChar=MaxGeneric;        {ML}
  MaxRegularId=MaxGeneric;      {L}
  MaxDomainName=MaxGeneric;
  MaxGeneratorName=MaxGeneric;
  MaxOptionName=MaxGeneric;
  MaxConstraintName=MaxGeneric;
  MaxIndexName=MaxGeneric;

  MaxPassword=MaxGeneric;
  MaxOptionText=MaxGeneric;

  MaxRoutineName=MaxGeneric;
  MaxParameterName=MaxGeneric;

  MaxServerText=MaxGeneric;
  MaxStatusGroupText=MaxGeneric;
  MaxStatusText=MaxGeneric;
  MaxServerStatusText=MaxGeneric;

  sysCatalogDefinitionCatalogId=1;
  //Note: sysCatalog name is dbname
  sysCatalogDefinitionSchemaName='CATALOG_DEFINITION_SCHEMA';
  sysCatalogDefinitionSchemaId=1;
  sysInformationSchemaName='INFORMATION_SCHEMA';

//todo add these to catalogRelation array (or the catalogRelationIndex somehow; getOrdName...)
  sysTable_table='sysTable';
  sysTable_file='$sysTable';
  sysColumn_table='sysColumn';
  sysColumn_file='$sysColumn';

  sysIndex_table='sysIndex';
  sysIndexColumn_table='sysIndexColumn'; 

  sysDomain_table='sysDomain'; //needed?
  sysAuth_table='sysAuth'; //needed?
  sysTableColumnPrivilege_table='sysTableColumnPrivilege'; //needed?
  sysRoutinePrivilege_table='sysRoutinePrivilege'; //needed?
  sysSchema_table='sysSchema'; //needed?
  sysGenerator_table='sysGenerator'; //needed?

  sysOption_table='sysOption'; //needed?
  sysConstraint_table='sysConstraint'; //needed?
  sysConstraintColumn_table='sysConstraintColumn'; //needed?
  sysDomainConstraint_table='sysDomainConstraint'; //needed?
  sysTableColumnConstraint_table='sysTableColumnConstraint'; //needed?
  sysRoutine_table='sysRoutine';
  sysParameter_table='sysParameter';

  //these are virtual relations: add their names to Trelation unit as well as CREATE TABLE in Tdatabase & uDatabaseMaint needs to skip them
  sysTransaction_table='sysTransaction';
  sysServer_table='sysServer';
  sysStatusGroup_table='sysStatusGroup';
  sysStatus_table='sysStatus';
  sysServerStatus_table='sysServerStatus';
  sysCatalog_table='sysCatalog'; //20/01/03 made virtual to keep in sync. with filename
  sysServerCatalog_table='sysServerCatalog';

  {Table type values}
  ttBaseTable='B';
  ttView='V';

  {Auth type values}
  atUser='U';
  atRole='R';

  SYSTEM_AUTHID=1; //_SYSTEM
  SYSTEM_AUTHNAME='_SYSTEM';
  PUBLIC_AUTHID=2; //fixed auth_id role //note: hardcoded in database insert
  DEFAULT_AUTHNAME='DEFAULT'; //standard default user

  {Privilege type values} //todo: only used internally for error/log messages - remove!?
  PrivilegeString:array [ptSelect..ptExecute] of string=('S','I','U','D','R','A','E');

  {Options}
  OptionString:array [otOptimiser..otOptimiser] of string=('OPTIMISER ENABLED');

  {Constraint rule type values} //todo: only used internally for error/log messages - remove!?
  ConstraintRuleString:array [rtUnique..rtCheck] of string=('Unique','PrimaryKey','ForeignKey','Check'); //note: not-null is shorthand for check

  {Constraint table parent/child values}
  ctParent='P';
  ctChild='C';

  {Index type values}
  itHash='H';
  //future use: itBtree='B';

  {Index origin values}
  ioSystem='S';
  ioSystemConstraint='C';
  ioUser='U';

  {from uPage}
  DiskBlocksize=4096;  //512; //4096; //Note: 4096 is minimum with current INFO_SCHEMA view defs //todo test with 4k..32k   //physical block size (including page headers)
  BlockSize=(DiskBlocksize-           //page block data size //Note: minimum of 1 header slot will be taken for heapFiles
               {Account for TPageBlock components}
               sizeof(integer)- //sizeof(byte)- {padded to 4 bytes}
               sizeof(PageId)-
               sizeof(PageId)-
               sizeof(integer)- //sizeof(byte)- {padded to 4 bytes}
               sizeof(cardinal)-
               sizeof(PageId)-
               sizeof(integer) //sizeof(byte)   {padded to 4 bytes} 

               //one byte more for rounding?
               );

  {from uFile}
  MaxRecSize=BlockSize;   //note: is actually less because of header+slot dirs


  MaxVar=100;         //max variables/parameters per set (i.e. per block/call/scope)
                      //Use an expandable array? - i.e. retain direct access for speed

  {Routine type values}
  rtProcedure='P';
  rtFunction='F';

  FunctionReturnParameterName='_result';

  MAX_ROUTINE_NEST=24; //todo increase this to allow any depth (but how to detect infinite recursion/loops?!)

  {sys table values} //todo move to common string unit? but no need to translate ever- these are internal
  StatusGroupString:array [low(TsysStatusGroup)..high(TsysStatusGroup)] of string=({$IFDEF DEBUG_LOG}
                                                                                   'Debug',
                                                                                   {$ENDIF}
                                                                                    'Process','Memory','Cache','Transaction');
  StatusString:array [low(TsysStatus)..high(TsysStatus)] of string=({$IFDEF DEBUG_LOG}
                      'DebugSyntaxCreate','DebugSyntaxDestroy',
                      {$ENDIF}
                      'ProcessUptime',
                      'MemoryManager','MemoryHeapAvailable','MemoryHeapCommitted','MemoryHeapUncommitted',
                      'MemoryHeapAllocated','MemoryHeapFree',
                      'CacheHits','CacheMisses',
                      'TransactionEarliestUncommitted');


  {from uBuffer}
  DefaultMaxFrames=1000; //300; //todo debug only

var
  {Note: globals must be multithread-protected}
  MaxFrames:integer=DefaultMaxFrames; //todo use, but need to make Fframe dynamic array: todo check performance!

// Bit manipulating
function BitSet   (const Value: Cardinal; const TheBit: TBit): Boolean;
function BitOn    (const Value: Cardinal; const TheBit: TBit): cardinal;
function BitOff   (const Value: Cardinal; const TheBit: TBit): cardinal;
function BitToggle(const Value: Cardinal; const TheBit: TBit): cardinal;

//Three valued logic operations
//todo speed them up - macros?
//todo also remove any if they're not used...
function TriOR(const a,b:TriLogic):TriLogic;
function TriAND(const a,b:TriLogic):TriLogic;
function TriNOT(const a:TriLogic):TriLogic;

function TriToStr(const a:TriLogic):string;


function JoinTypeToStr(const a:TJoinType):string;
function SetTypeToStr(const a:TSetType):string;

function maxWORD(a,b:word):word;
function maxSMALLINT(a,b:smallint):smallint;
function maxINTEGER(a,b:integer):integer;
function maxDATATYPE(a,b:TDataType):TDataType;

function CompareDate(dtl,dtr:TsqlDate;var res:shortint):integer;
function CompareTime(tml,tmr:TsqlTime;var res:shortint):integer;
function CompareTimestamp(tsl,tsr:TsqlTimestamp;var res:shortint):integer;

function TrimLeftWS(s:string):string;{$IFDEF D2007up}inline;{$ENDIF}


implementation

const
  where='uGlobal';

{Note: in these bit routines, 0 is the first bit}
function BitSet(const Value: cardinal; const TheBit: TBit): Boolean;
{Checks if a bit is set}
begin
  Result := (Value and (1 shl TheBit)) <> 0;
end;
(* todo: is this faster & Kylix compatible? -speed: timings show no difference (10 million calls, D5)
function IsBit(Value, Pos: Integer): Boolean;
asm
 mov ecx,eax
 xor eax,eax
 and edx,31
 bt ecx,edx
 adc eax,0
end;*)

function BitOn(const Value: cardinal; const TheBit: TBit): cardinal;
begin
  Result := Value or (1 shl TheBit);
end;

function BitOff(const Value: Cardinal; const TheBit: TBit): cardinal;
begin
  Result := Value and ((1 shl TheBit) xor $FFFFFFFF); //todo replace with constant
end;

function BitToggle(const Value: cardinal; const TheBit: TBit): cardinal;
begin
  result := Value xor (1 shl TheBit);
end;

function TriOR(const a,b:TriLogic):TriLogic;
begin
  result:=isTrue;
  if (a=isFalse) and (b=isFalse) then result:=isFalse;
  if (a=isUnknown) and (b<>isTrue) then result:=isUnknown;
  if (b=isUnknown) and (a<>isTrue) then result:=isUnknown;
end; {TriOR}

function TriAND(const a,b:TriLogic):TriLogic;
begin
  result:=isFalse;
  if (a=isTrue) and (b=isTrue) then result:=isTrue;
  if (a=isUnknown) and (b<>isFalse) then result:=isUnknown;
  if (b=isUnknown) and (a<>isFalse) then result:=isUnknown;
end; {TriAND}

function TriNOT(const a:TriLogic):TriLogic;
begin
  result:=isTrue;
  if a=isTrue then result:=isFalse;
  if a=isUnknown then result:=isUnknown;
end; {TriNOT}

function TriToStr(const a:TriLogic):string;
begin
  case a of
    isUnknown: result:='unknown';
    isFalse:   result:='false';
    isTrue:    result:='true';
  end; {case}
end; {TriToStr}

//todo replace with constant arrays!
function JoinTypeToStr(const a:TJoinType):string;
begin
  case a of
    jtInner: result:='inner';
    jtLeft:  result:='left';
    jtRight: result:='right';
    jtFull:  result:='full';
    jtUnion: result:='union';
  else
    result:='?'; //todo assertion?
  end; {case}
end; {JoinTypeToStr}
function SetTypeToStr(const a:TSetType):string;
begin
  case a of
    stUnion:        result:='union';
    stExcept:       result:='except';
    stIntersect:    result:='intersect';
    stUnionAll:     result:='union all';
    stExceptAll:    result:='except all';
    stIntersectAll: result:='intersect all';
  else
    result:='?'; //todo assertion?
  end; {case}
end; {SetTypeToStr}

function maxWORD(a,b:word):word;
begin
  if a>=b then result:=a else result:=b;
end; {maxWORD}

function maxSMALLINT(a,b:smallint):smallint;
begin
  if a>=b then result:=a else result:=b;
end; {maxSMALLINT}

function maxINTEGER(a,b:integer):integer;
begin
  if a>=b then result:=a else result:=b;
end; {maxINTEGER}

function RankDataType(d:TDatatype):integer;
{Currently used to determine which datatype to use for parent when
 combining two children,
 e.g. integer and real -> real
}
begin
  //improve? maybe use ord & define in this order?
  case d of
    ctUnknown:result:=0; //anything is better than not knowing, although we should know everything by the time we're called?
    ctChar:result:=1;
    ctVarChar:result:=2;
    ctBit:result:=3;
    ctVarBit:result:=4;

    ctSmallInt:result:=5;
    ctInteger:result:=6;
    ctBigInt:result:=7;
    ctFloat:result:=8;
    ctNumeric:result:=9; //todo check these two are the right way round
    ctDecimal:result:=10;

    ctDate:result:=11;
    ctTime:result:=12;
    ctTimeWithTimezone:result:=13;
    ctTimestamp:result:=14;
    ctTimestampWithTimezone:result:=15;

    ctClob:result:=16;
    ctBlob:result:=17;
  else
    result:=0;  //todo else assertion!!!!!!!!!!!!!
  end;
end; {RankDataType}
function maxDATATYPE(a,b:TDataType):TDataType;
begin
  if RankDataType(a)>RankDataType(b) then result:=a else result:=b;
end; {maxDATATYPE}

function CompareDate(dtl,dtr:TsqlDate;var res:shortint):integer;
{Compares the current values of two dates
 IN:      dtl
          dtr
 OUT:     res         result
                            -1  dtL<dtR
                             0  dtL=dtR
                            +1  dtL>dtR

 RESULT:  ok, or fail if error

 Assumes:
   caller deals with nulls before calling
}
begin
  result:=ok;

  res:=0;
  if dtl.year>dtr.year then
    res:=+1
  else
    if dtl.year<dtr.year then res:=-1
    else
      if dtl.month>dtr.month then
        res:=+1
      else
        if dtl.month<dtr.month then res:=-1
        else
          if dtl.day>dtr.day then
            res:=+1
          else
            if dtl.day<dtr.day then res:=-1;
end; {CompareDate}

function CompareTime(tml,tmr:TsqlTime;var res:shortint):integer;
{Compares the current values of two times
 IN:      tml
          tmr
 OUT:     res         result
                            -1  tmL<tmR
                             0  tmL=tmR
                            +1  tmL>tmR

 RESULT:  ok, or fail if error

 Assumes:
   caller deals with nulls before calling

   times are already normalised for seconds-scale and time-zone
   times are already normalised to UTC timezone
}
begin
  result:=ok;

  res:=0;
  if tml.hour>tmr.hour then
    res:=+1
  else
    if tml.hour<tmr.hour then res:=-1
    else
      if tml.minute>tmr.minute then
        res:=+1
      else
        if tml.minute<tmr.minute then res:=-1
        else //todo! normalise first!
          if tml.second>tmr.second then
            res:=+1
          else
            if tml.second<tmr.second then res:=-1;
end; {CompareTime}

function CompareTimestamp(tsl,tsr:TsqlTimestamp;var res:shortint):integer;
{Compares the current values of two timestamps
 IN:      tsl
          tsr
 OUT:     res         result
                            -1  tsL<tsR
                             0  tsL=tsR
                            +1  tsL>tsR

 RESULT:  ok, or fail if error

 Assumes:
   caller deals with nulls before calling

   timestamps are already normalised for seconds-scale and time-zone
   timestamps are already normalised to UTC timezone
}
begin
  result:=ok;

  CompareDate(tsl.date,tsr.date,res);
  if res=0 then
    CompareTime(tsl.time,tsr.time,res);
end; {CompareTimestamp}

function TrimLeftWS(s:string):string;{$IFDEF D2007up}inline;{$ENDIF}
{Remove whitespace from the left of the string}
begin
  Result := TrimLeft(s); //trim left removes all characters less than space that includes tab, cr, lf etc for delphi 2007
                         //I do not remember for earlier versions so the rest of the code will execute only for versions smaller than d2007
  {$IFDEF D2007Up} { Delphi 2007- }
  while (Length(Result)>0) and ((Result[1]=TAB) or (Result[1]=CR) or (Result[1]=LF)) do
    delete(result,1,1);
  {$ENDIF}
end; {trimleftWS}


{$IFDEF EXPIRE}
initialization
  if now>37256 then halt(1); //expire 31/12/01
{$ENDIF}


end.

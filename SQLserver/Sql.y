%{
(*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*)


(* pascal constants *)

//{$define yydebug}  //debug to console

uses lexlib,yacclib;

type YYSType = TSyntaxNodePtr;  //override Yacc default type of integer

const
  yywhere='uParser:sql.y';
  yywho='';

var
  node,node2,node3:TSyntaxNodePtr; //general purpose node creator/pointers
  dayCarry:shortint; //throw away time-zone carry

  {To capture check-constraint/view definition text}
  check_start_text:string;
  check_start_at:integer;

%}

%token LEXERROR         /* error returned by lexical analyser - matches nothing in grammar */ 
%token NOMATCH          /* never returned by lexical analyser - used for partial rules */

%token kwCREATE
%token kwSCHEMA
%token kwAUTHORIZATION
%token kwGLOBAL
%token kwLOCAL
%token kwTEMPORARY
%token kwTABLE
%token kwON
%token kwCOMMIT
%token kwDELETE
%token kwPRESERVE
%token kwROWS
%token kwROLLBACK
%token kwWORK
%token kwTRANSACTION
%token kwDIAGNOSTICS
%token kwSIZE
%token kwREAD
%token kwONLY
%token kwWRITE
%token kwISOLATION
%token kwLEVEL
%token kwUNCOMMITTED
%token kwCOMMITTED
%token kwREPEATABLE
%token kwSERIALIZABLE
%token kwCONNECT
%token kwUSER
%token kwCURRENT_USER
%token kwSESSION_USER
%token kwSYSTEM_USER
%token kwCURRENT_DATE
%token kwCURRENT_TIME
%token kwCURRENT_TIMESTAMP
%token kwDISCONNECT
%token kwCURRENT
%token kwGRANT
%token kwPRIVILEGES
%token kwUSAGE
%token kwEXECUTE
%token kwCOLLATION
%token kwTRANSLATION
%token kwPUBLIC
%token kwREVOKE
%token kwFOR
%token kwDROP
%token kwALTER
%token kwADD
%token kwCOLUMN

/* Non SQL/92 implementation-defined keywords */
%token kwPASSWORD                    /* connect db user u [password p] */

%token kwCATALOG                     /* create catalog c */
%token kwSHOWTRANS                   /* (dev?) utility */
%token kwSHUTDOWN
%token kwDEBUG                       /* debug table t */
%token kwINDEX                       /* debug index t */
%token kwSUMMARY                     /* debug qualifier */
%token kwSERVER
%token kwPAGE                        /* debug page n */
%token kwPLAN                        /* debug plan 's' */
%token kwPRINT                       /* debug print expr */
%token kwSEQUENCE
%token kwNEXT_SEQUENCE
%token kwLATEST_SEQUENCE
%token kwSTARTING
%token kwKILL                        /* kill n */
%token kwCANCEL                      /* cancel n */
%token kwREBUILD                     /* rebuild index i */
%token kwBACKUP                      /* backup catalog c */
%token kwGARBAGE                     /* garbage collect catalog c */
%token kwCOLLECT                     /* '' */   

%token kwCURRENT_AUTHID              /* initially for fast information_schema visibilty checks */
%token kwCURRENT_CATALOG             /* initially for ODBC filtering */
%token kwCURRENT_SCHEMA              /* initially for ODBC filtering */

/* End of non SQL/92 implementation-defined keywords */

%token kwSELECT
%token kwAS
%token kwALL
%token kwDISTINCT
%token kwINTO
%token kwFROM
%token kwWHERE
%token kwGROUP
%token kwBY
%token kwORDER
%token kwASC
%token kwDESC
%token kwHAVING

%token kwAVG
%token kwMAX
%token kwMIN
%token kwSUM
%token kwCOUNT

%token kwTO
%token kwAT
%token kwTIME
%token kwZONE

/* AND OR NOT moved with operators */
%token kwIS
%token kwTRUE
%token kwFALSE
%token kwUNKNOWN
%token kwBETWEEN
%token kwLIKE
%token kwESCAPE
%token kwIN
%token kwMATCH
%token kwUNIQUE
%token kwPARTIAL
%token kwFULL
%token kwALL
%token kwANY
%token kwSOME
%token kwEXISTS
%token kwOVERLAPS
%token kwNULL

%token kwCONSTRAINT
%token kwPRIMARY
%token kwKEY
%token kwFOREIGN
%token kwREFERENCES
%token kwUPDATE
%token kwNO
%token kwACTION
%token kwCASCADE
%token kwRESTRICT
%token kwSET
%token kwDEFAULT
%token kwCHECK
%token kwDOMAIN
%token kwINITIALLY
%token kwDEFERRED
%token kwIMMEDIATE
%token kwDEFERRABLE
%token kwCONSTRAINTS

%token kwVIEW
%token kwWITH
%token kwCASCADED
%token kwOPTION

%token kwOUT
%token kwINOUT
%token kwRETURNS
%token kwPROCEDURE
%token kwFUNCTION
%token kwROUTINE
%token kwCALL
%token kwDECLARE
%token kwRETURN

%token kwCURSOR
%token kwOF
%token kwSENSITIVE
%token kwINSENSITIVE
%token kwASENSITIVE
%token kwSCROLL
%token kwHOLD
%token kwOPEN
%token kwCLOSE
%token kwFETCH
%token kwNEXT
%token kwPRIOR
%token kwFIRST
%token kwLAST
%token kwABSOLUTE
%token kwRELATIVE
%token kwSQLSTATE

%token kwINSERT
%token kwVALUES

%token kwCROSS
%token kwJOIN
%token kwNATURAL
%token kwUSING
%token kwINNER
%token kwOUTER
%token kwLEFT
%token kwRIGHT
%token kwUNION
%token kwEXCEPT
%token kwINTERSECT
%token kwCORRESPONDING


%token kwINTEGER
%token kwINT
%token kwSMALLINT
%token kwBIGINT
%token kwFLOAT
%token kwREAL
%token kwDOUBLE
%token kwPRECISION
%token kwNUMERIC
%token kwDECIMAL
%token kwDEC
%token kwCHARACTER
%token kwCHAR
%token kwVARYING
%token kwVARCHAR
%token kwBIT
%token kwDATE
%token kwTIMESTAMP
%token kwINTERVAL
%token kwBLOB
%token kwCLOB
%token kwBINARY
%token kwLARGE
%token kwOBJECT

%token kwCASE
%token kwWHEN
%token kwTHEN
%token kwELSE
%token kwEND
%token kwCOALESCE
%token kwNULLIF

%token kwTRIM
%token kwLEADING
%token kwTRAILING
%token kwBOTH

%token kwCHARACTER_LENGTH
%token kwCHAR_LENGTH
%token kwOCTET_LENGTH

%token kwLOWER
%token kwUPPER
%token kwPOSITION
%token kwSUBSTRING
%token kwCAST

%token kwBEGIN
%token kwATOMIC
%token kwWHILE
%token kwDO
%token kwIF
%token kwELSEIF
%token kwLEAVE
%token kwITERATE
%token kwLOOP
%token kwREPEAT
%token kwUNTIL


%token tIDENTIFIER
%token tLABEL
%token tCATALOG_IDENTIFIER
%token tINTEGER
%token tREAL
%token tSTRING
%token tPARAM
%token tBLOB

%token pCONCAT
%token pCOMMA

%token kwOR
%token kwAND
%token kwNOT
%token pEQUAL
%token pLT
%token pLTEQ
%token pGT
%token pGTEQ
%token pNOTEQUAL
%token pPLUS, pMINUS
%token pASTERISK, pSLASH
%token pSEMICOLON
%token pDOT
%token pLPAREN, pRPAREN

%%

/******************************************
  SQL/92 grammar based on:
    A Guide to The SQL Standard (4th edition)  C.J.Date with Hugh Darwen
    ISO 9075 standard document

  Notes:
    ..._OPT_... productions are used for rules containing []s
    ..._ONE_... productions are used for rules containing {|}s
******************************************/

sql_list:
  sql
  {
  $$:=$1;
  GlobalParseRoot:=$$;
  log.add(yywho,yywhere,format('sql_list (sql) %p',[$$]),vDebug);
  yyaccept;
  }
  | pSEMICOLON
  {
  GlobalParseRoot:=nil;
  log.add(yywho,yywhere,format('sql_list (;) %p',[$$]),vDebug);
  yyaccept;
  }
  | /* nothing */
  {
  GlobalParseRoot:=nil;
  log.add(yywho,yywhere,format('nothing %p',[$$]),vDebug);
  yyaccept;
  }
  | error
  {
  (* $$:=$1; *)
  log.add(yywho,yywhere,format('error in line %d, column %d at token %s ($$=%p)',[yylineno,yycolno,yytext,$$]),vError);
  log.add(yywho,yywhere,format('...%s%s',[yytext,GlobalParseStmt.InputText]),vError);
  GlobalSyntaxErrLine:=yylineno;
  GlobalSyntaxErrCol:=yycolno;
  GlobalSyntaxErrMessage:=format('...%s%s...',[yytext,copy(GlobalParseStmt.InputText,1,30)]);
  GlobalParseRoot:=$1;
  yyabort;
  }
  ;

sql_compound:
  OPT_compound_label kwBEGIN OPT_atomicity
  OPT_sql_compound_list
  kwEND OPT_compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundBlock,ctUnknown,$4,$3);
  if $1<>nil then begin $$.idVal:=$1.idVal; deleteSyntaxTree($1); end;
  log.add(yywho,yywhere,format('sql_compound (block) %p',[$$]),vDebug);
  }
  | OPT_compound_label kwWHILE cond_exp kwDO
  OPT_sql_compound_list
  kwEND kwWHILE OPT_compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundWhile,ctUnknown,$5,$3);
  if $1<>nil then begin $$.idVal:=$1.idVal; deleteSyntaxTree($1); end;
  log.add(yywho,yywhere,format('sql_compound (while) %p',[$$]),vDebug);
  }
  | kwIF condition_then_action
  OPT_elseif_condition_then_action_list
  OPT_else_action
  kwEND kwIF
  {
  chainAppendNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundIf,ctUnknown,$2,$4);
  log.add(yywho,yywhere,format('sql_compound (if) %p',[$$]),vDebug);
  }
  | OPT_compound_label kwLOOP
  OPT_sql_compound_list
  kwEND kwLOOP OPT_compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundLoop,ctUnknown,$3,nil);
  if $1<>nil then begin $$.idVal:=$1.idVal; deleteSyntaxTree($1); end;
  log.add(yywho,yywhere,format('sql_compound (loop) %p',[$$]),vDebug);
  }
  | OPT_compound_label kwREPEAT
  OPT_sql_compound_list
  kwUNTIL cond_exp
  kwEND kwREPEAT OPT_compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundRepeat,ctUnknown,$3,$5);
  if $1<>nil then begin $$.idVal:=$1.idVal; deleteSyntaxTree($1); end;
  log.add(yywho,yywhere,format('sql_compound (repeat) %p',[$$]),vDebug);
  }
  | kwCASE
  OPT_when_condition_then_action_list
  OPT_else_action
  kwEND kwCASE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundCase,ctUnknown,$2,$3);
  log.add(yywho,yywhere,format('sql_compound (case) %p',[$$]),vDebug);
  }
  ;

OPT_atomicity:
  atomicity
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

atomicity:
  kwNOT kwATOMIC
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNotAtomic,ctUnknown,0,0);
  log.add(yywho,yywhere,format('atomicity (not atomic) %p',[$$]),vDebug);
  }
  | kwATOMIC
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAtomic,ctUnknown,0,0);
  log.add(yywho,yywhere,format('atomicity (atomic) %p',[$$]),vDebug);
  }
  ;


condition_then_action:
  cond_exp kwTHEN sql_compound_list
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntIfThen,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('condition_then_action %p',[$$]),vDebug);
  }
  ;

elseif_condition_then_action:
  kwELSEIF condition_then_action
  {
  $$:=$2;
  }
  ;

elseif_condition_then_action_list:
  elseif_condition_then_action_list elseif_condition_then_action /* ensure most effecient stacking in yacc, since long-winded */
  {
  chainAppendNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('elseif_condition_then_action_list (list,e) %p',[$$]),vDebug);
  }
  | elseif_condition_then_action
  {
  $$:=$1;
  log.add(yywho,yywhere,format('elseif_condition_then_action_list (e) %p',[$$]),vDebug);
  }
  ;

OPT_elseif_condition_then_action_list:
  elseif_condition_then_action_list
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;

else_action:
  kwELSE sql_compound_list
  {
  $$:=$2;
  log.add(yywho,yywhere,format('else_action %p',[$$]),vDebug);
  }
  ;

OPT_else_action:
  else_action
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;

when_condition_then_action:
  kwWHEN condition_then_action
  {
  $$:=$2;
  }
  ;

when_condition_then_action_list:
  when_condition_then_action_list when_condition_then_action /* ensure most effecient stacking in yacc, since long-winded */
  {
  chainAppendNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('when_condition_then_action_list (list,e) %p',[$$]),vDebug);
  }
  | when_condition_then_action
  {
  $$:=$1;
  log.add(yywho,yywhere,format('when_condition_then_action_list (e) %p',[$$]),vDebug);
  }
  ;

OPT_when_condition_then_action_list:
  when_condition_then_action_list
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;


sql_compound_element:
  sql pSEMICOLON
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundElement,ctUnknown,$1,nil); (* wrapped to allow separate tree deletion without breaking chain *)
  log.add(yywho,yywhere,format('sql_compound_element (sql ;) %p',[$$]),vDebug);
  }
  | sql_compound pSEMICOLON
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCompoundElement,ctUnknown,$1,nil); (* wrapped to allow separate tree deletion without breaking chain *)
  log.add(yywho,yywhere,format('sql_compound_element (sql_compound ;) %p',[$$]),vDebug);
  }
  /* note no yyaccept here - otherwise keep same as sql_list */
  ;

sql_compound_list:
  sql_compound_list sql_compound_element /* ensure most effecient stacking in yacc, since long-winded */
  {
  chainAppendNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('sql_compound_list (list,e) %p',[$$]),vDebug);
  }
  | sql_compound_element
  {
  $$:=$1;
  log.add(yywho,yywhere,format('sql_compound_list (e) %p',[$$]),vDebug);
  }
  ;

OPT_sql_compound_list:
  sql_compound_list
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;


sql:
  connection
  ;

sql:
  implementation_defined
  ;

sql:
  schema_def
  ;

sql:
  schema_element
  ;

sql:
  ddl
  ;

sql:
  dml
  ;

sql:
  sql_compound
  ;


connection:
  connect
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (connect) %p',[$$]),vDebug);
  }
  | disconnect
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (disconnect) %p',[$$]),vDebug);
  }
  | set_schema
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (set schema) %p',[$$]),vDebug);
  }
  | commit
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (commit) %p',[$$]),vDebug);
  }
  | rollback
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (commit) %p',[$$]),vDebug);
  }
  | set_transaction
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (set transaction) %p',[$$]),vDebug);
  }
  | set_constraints
  {
  $$:=$1;
  log.add(yywho,yywhere,format('connection (set constraints) %p',[$$]),vDebug);
  }
  | kwSHOWTRANS
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSHOWTRANS,ctUnknown,0,0);
  log.add(yywho,yywhere,format('connection (SHOWTRANS) %p',[$$]),vDebug);
  }
  | kwSHUTDOWN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSHUTDOWN,ctUnknown,0,0);
  log.add(yywho,yywhere,format('connection (SHUTDOWN) %p',[$$]),vDebug);
  }
  ;

implementation_defined:
  catalog_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (catalog_def) %p',[$$]),vDebug);
  }
  | user_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (user_def) %p',[$$]),vDebug);
  }
  | user_alteration
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (user_alteration) %p',[$$]),vDebug);
  }
  | user_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (user_drop) %p',[$$]),vDebug);
  }
  | index_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (index_def) %p',[$$]),vDebug);
  }
  | index_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (index_drop) %p',[$$]),vDebug);
  }
  | sequence_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (sequence_def) %p',[$$]),vDebug);
  }
  | sequence_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (sequence_drop) %p',[$$]),vDebug);
  }
  | debug_table
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_table) %p',[$$]),vDebug);
  }
  | debug_index
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_index) %p',[$$]),vDebug);
  }
  | debug_catalog
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_catalog) %p',[$$]),vDebug);
  }
  | debug_server
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_server) %p',[$$]),vDebug);
  }
  | debug_page
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_page) %p',[$$]),vDebug);
  }
  | debug_plan
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_plan) %p',[$$]),vDebug);
  }
  | debug_print
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (debug_print) %p',[$$]),vDebug);
  }
  | kill_tran
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (kill) %p',[$$]),vDebug);
  }
  | cancel_tran
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (cancel) %p',[$$]),vDebug);
  }
  | rebuild_index
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (rebuild_index) %p',[$$]),vDebug);
  }
  | catalog_backup
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (catalog_backup) %p',[$$]),vDebug);
  }
  | catalog_open
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (catalog_open) %p',[$$]),vDebug);
  }
  | catalog_close
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (catalog_close) %p',[$$]),vDebug);
  }
  | catalog_garbage_collect
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined (catalog_garbage_collect) %p',[$$]),vDebug);
  }
  ;

ddl:
  base_table_alteration
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (base_table_alteration) %p',[$$]),vDebug);
  }
  | schema_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (schema_drop) %p',[$$]),vDebug);
  }
  | domain_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (domain_drop) %p',[$$]),vDebug);
  }
  | base_table_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (base_table_drop) %p',[$$]),vDebug);
  }
  | view_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (view_drop) %p',[$$]),vDebug);
  }
  | routine_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (routine_drop) %p',[$$]),vDebug);
  }
  | authorization_drop
  {
  $$:=$1;
  log.add(yywho,yywhere,format('ddl (authorization_drop) %p',[$$]),vDebug);
  }
  ;

dml:
  table_exp    /* select_exp 080699 made more general */
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (table_exp) %p',[$$]),vDebug);
  }
  | table_exp
  table_exp_OPT_orderby
  {
  $$:=$1;
  chainNext($$,$2);
  log.add(yywho,yywhere,format('dml (table_exp order by) %p',[$$]),vDebug);
  }
  | insert
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (insert) %p',[$$]),vDebug);
  }
  | searched_update
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (searched_update) %p',[$$]),vDebug);
  }
  | searched_delete
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (searched_delete) %p',[$$]),vDebug);
  }
  | call_routine
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (call_routine) %p',[$$]),vDebug);
  }
  | declaration
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (declaration) %p',[$$]),vDebug);
  }
  | open
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (open) %p',[$$]),vDebug);
  }
  | close
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (close) %p',[$$]),vDebug);
  }
  | fetch
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (close) %p',[$$]),vDebug);
  }
  | assignment
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (assignment) %p',[$$]),vDebug);
  }
  | return
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (return) %p',[$$]),vDebug);
  }
  | leave
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (leave) %p',[$$]),vDebug);
  }
  | iterate
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (iterate) %p',[$$]),vDebug);
  }
  | single_row_select
  {
  $$:=$1;
  log.add(yywho,yywhere,format('dml (single_row_select) %p',[$$]),vDebug);
  }
  ;

/************************************
  Implementation Defined Commands
         (non SQL/92 stuff)
************************************/

catalog_def:
  kwCREATE kwCATALOG catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateCatalog,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('catalog_def %p',[$$]),vDebug);
  }
  ;

user_def:
  kwCREATE kwUSER user OPT_password
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateUser,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('user_def %p',[$$]),vDebug);
  }
  ;

user_alteration:
  kwALTER kwUSER user user_alteration_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAlterUser,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('user_alteration %p',[$$]),vDebug);
  }
  ;

user_alteration_action:
  kwSET password
  {
  $$:=$2;
  }
  | kwSET kwDEFAULT kwSCHEMA schema
  {
  $$:=$4;
  }
  ;

user_drop:
  kwDROP kwUSER
  user
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropUser,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('user_drop %p',[$$]),vDebug);
  }
  ;

index_def:
  kwCREATE kwINDEX index kwON base_table_OR_view pLPAREN column_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateIndex,ctUnknown,$3,$5);
  chainNext($$,$7);
  log.add(yywho,yywhere,format('index_def %p',[$$]),vDebug);
  }
  ;

sequence_def:
  kwCREATE kwSEQUENCE sequence OPT_starting_at
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateSequence,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('sequence_def %p',[$$]),vDebug);
  }
  ;

sequence_drop:
  kwDROP kwSEQUENCE sequence
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropSequence,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('sequence_drop %p',[$$]),vDebug);
  }
  ;

index_drop:
  kwDROP kwINDEX
  index
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropIndex,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('index_drop %p',[$$]),vDebug);
  }
  ;

debug_table:
  kwDEBUG kwTABLE OPT_summary base_table_OR_view
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGTABLE,ctUnknown,$4,$3);
  log.add(yywho,yywhere,format('debug_table (debug table...) %p',[$$]),vDebug);
  }
  ;

debug_index:
  kwDEBUG kwINDEX OPT_summary base_table_OR_view
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGINDEX,ctUnknown,$4,$3);
  log.add(yywho,yywhere,format('debug_index (debug index...) %p',[$$]),vDebug);
  }
  ;

debug_catalog:
  kwDEBUG kwCATALOG OPT_summary catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGCATALOG,ctUnknown,$4,$3);
  log.add(yywho,yywhere,format('debug_catalog (debug catalog...) %p',[$$]),vDebug);
  }
  ;

debug_server:
  kwDEBUG kwSERVER OPT_summary
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGSERVER,ctUnknown,nil,$3);
  log.add(yywho,yywhere,format('debug_server (debug server...) %p',[$$]),vDebug);
  }
  ;

debug_page:
  kwDEBUG kwPAGE OPT_summary integer
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGPAGE,ctUnknown,$4,$3);
  log.add(yywho,yywhere,format('debug_page (debug page...) %p',[$$]),vDebug);
  }
  ;

debug_plan:
  kwDEBUG kwPLAN OPT_summary lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGPLAN,ctUnknown,$4,$3);
  log.add(yywho,yywhere,format('debug_plan (debug plan...) %p',[$$]),vDebug);
  }
  ;

debug_print:
  kwDEBUG kwPRINT scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDEBUGPRINT,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('debug_print (debug print...) %p',[$$]),vDebug);
  }
  ;

OPT_summary:
  kwSUMMARY
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSummary,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_starting_at:
  kwSTARTING kwAT integer
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntStartingAt,ctUnknown,$3,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

kill_tran:
  kwKILL lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntKillTran,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('kill_tran %p',[$$]),vDebug);
  }
  ;

cancel_tran:
  kwCANCEL lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCancelTran,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('cancel_tran %p',[$$]),vDebug);
  }
  ;

rebuild_index:
  kwREBUILD kwINDEX base_table_OR_view index
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntREBUILDINDEX,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('rebuild_index (rebuild index...) %p',[$$]),vDebug);
  }
  ;

catalog_backup:
  kwBACKUP kwCATALOG kwTO catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntBackupCatalog,ctUnknown,$4,nil);
  log.add(yywho,yywhere,format('catalog_backup %p',[$$]),vDebug);
  }
  ;

catalog_open:
  kwOPEN kwCATALOG catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOpenCatalog,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('catalog_open %p',[$$]),vDebug);
  }
  ;

catalog_close:
  kwCLOSE kwCATALOG catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCloseCatalog,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('catalog_close %p',[$$]),vDebug);
  }
  ;

catalog_garbage_collect:
  kwGARBAGE kwCOLLECT kwCATALOG catalog
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntGarbageCollectCatalog,ctUnknown,$4,nil);
  log.add(yywho,yywhere,format('catalog_garbage_collect %p',[$$]),vDebug);
  }
  ;

index:
  tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntIndex,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('index (identifier) %p, yylval=%p',[$$,yylval]),vDebug);
  }

sequence:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSequence,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('sequence (catalog.schema.sequence) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSequence,ctUnknown,node,$3);
  log.add(yywho,yywhere,format('sequence (schema.sequence) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSequence,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('sequence (sequence) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

/****************
  Connection
*****************/

connect:
  kwCONNECT kwTO lit_param_or_var OPT_asConnection OPT_user OPT_password   /* Note: OPT_password is a non-standard extension */
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntPassword,ctUnknown,nil,nil);  //this is a dummy list head node and will be ignored
  chainNext(node,$6);
  chainNext(node,$5);
  chainNext(node,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConnect,ctUnknown,$3,node);
  log.add(yywho,yywhere,format('connect %p',[$$]),vDebug);
  }
  | kwCONNECT kwTO kwDEFAULT
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConnect,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('connect (to default) %p',[$$]),vDebug);
  }
  ;

disconnect:
  kwDISCONNECT lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDisconnect,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('disconnect %p',[$$]),vDebug);
  }
  | kwDISCONNECT kwDEFAULT
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDisconnect,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('connect (default) %p',[$$]),vDebug);
  }
  | kwDISCONNECT kwCURRENT    /* Note: currently behaves as DEFAULT */
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDisconnect,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('connect (current) %p',[$$]),vDebug);
  }
  | kwDISCONNECT kwALL    /* Note: currently behaves as DEFAULT */
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDisconnect,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('connect (all) %p',[$$]),vDebug);
  }
  ;

set_schema:                /* Note: dynamic SQL use only */
  kwSET kwSCHEMA lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSetSchema,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('set_schema %p',[$$]),vDebug);
  }
  | kwSET kwSCHEMA authID_function_ref
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSetSchema,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('set_schema %p',[$$]),vDebug);
  }
  ;


commit:
  kwCOMMIT OPT_work
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCommit,ctUnknown,0,0);
  log.add(yywho,yywhere,format('commit %p',[$$]),vDebug);
  }
  ;

rollback:
  kwROLLBACK OPT_work
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntRollback,ctUnknown,0,0);
  log.add(yywho,yywhere,format('rollback %p',[$$]),vDebug);
  }
  ;

set_transaction:
  kwSET kwTRANSACTION option_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSetTransaction,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('set_transaction %p',[$$]),vDebug);
  }
  ;

option_commalist:
  option pCOMMA option_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('option_commalist (e,list) %p',[$$]),vDebug);
  }
  | option
  {
  $$:=$1;
  log.add(yywho,yywhere,format('option (e) %p',[$$]),vDebug);
  }
  ;

option:
  kwDIAGNOSTIC kwSIZE integer
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionDiagnostic,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('option (diagnostic size) %p',[$$]),vDebug);
  }
  | kwREAD kwONLY
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionReadOnly,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (read only) %p',[$$]),vDebug);
  }
  | kwREAD kwWRITE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionReadWrite,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (read write) %p',[$$]),vDebug);
  }
  | kwISOLATION kwLEVEL kwREAD kwUNCOMMITTED
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionIsolationReadUncommitted,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (isolation read uncommitted) %p',[$$]),vDebug);
  }
  | kwISOLATION kwLEVEL kwREAD kwCOMMITTED
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionIsolationReadCommitted,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (isolation read committed) %p',[$$]),vDebug);
  }
  | kwISOLATION kwLEVEL kwREPEATABLE kwREAD
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionIsolationRepeatableRead,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (isolation repeatable read) %p',[$$]),vDebug);
  }
  | kwISOLATION kwLEVEL kwSERIALIZABLE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOptionIsolationSerializable,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('option (isolation serializable) %p',[$$]),vDebug);
  }
  ;



/****************
  Data definition
*****************/

schema_def:
  kwCREATE kwSCHEMA kwAUTHORIZATION user OPT_schema
  OPT_default_character_set
  OPT_schema_element_list
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntAuthorization,ctUnknown,$4,nil);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateSchema,ctUnknown,nil,$7);
  chainNext($$,$6);
  chainNext($$,node);
  log.add(yywho,yywhere,format('schema_def authorization %p',[$$]),vDebug);
  }
  | kwCREATE kwSCHEMA schema OPT_authorization
  OPT_default_character_set
  OPT_schema_element_list
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateSchema,ctUnknown,$3,$6);
  chainNext($$,$5);
  chainNext($$,$4);
  log.add(yywho,yywhere,format('schema_def %p',[$$]),vDebug);
  }
  ;

schema_element:
  domain_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element (domain_def) %p',[$$]),vDebug);
  }
  | base_table_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element (base_table_def) %p',[$$]),vDebug);
  }
  | view_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element (view_def) %p',[$$]),vDebug);
  }
  | routine_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element (routine_def) %p',[$$]),vDebug);
  }
  | authorization_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element (authorization_def) %p',[$$]),vDebug);
  }
  | index_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined schema_element (index_def) %p',[$$]),vDebug);
  }
  | sequence_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('implementation_defined schema_element (sequence_def) %p',[$$]),vDebug);
  }
  ;


schema_element_list:
  schema_element_list schema_element /* ensure most effecient stacking in yacc, since long-winded */
  {
  chainAppendNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element_list (list,e) %p',[$$]),vDebug);
  }
  | schema_element
  {
  $$:=$1;
  log.add(yywho,yywhere,format('schema_element_list (e) %p',[$$]),vDebug);
  }
  ;

OPT_schema_element_list:
  schema_element_list
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;


default_def:
  kwDEFAULT default_def_ONE_type
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDefault,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('default_def %p',[$$]),vDebug);
  }
  ;

OPT_default_def:
  default_def
  {
  $$:=$1;
  }
  | /* nothing */  {$$:=nil;}
  ;

default_def_ONE_type:
  literal_BLOB
  | literal_NUM
  | literal_STRING
  | literal_DATE
  | literal_TIME
  | literal_TIMESTAMP
  | literal_INTERVAL
  | literal_BITSTRING
  | niladic_function_ref
  | sequence_expression /* non-standard */
  | kwNULL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNull,ctUnknown,0,0);
  }
  ;

domain_def:
  kwCREATE kwDOMAIN domain OPT_as datatype
  column_def_OPT_default
  domain_def_OPT_constraint
  {
  chainNext($5,$7);
  chainNext($5,$6);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateDomain,ctUnknown,$3,$5);
  log.add(yywho,yywhere,format('domain_def (create domain...) %p',[$$]),vDebug);
  }
  ;

domain_def_OPT_constraint:
  domain_constraint_def
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

base_table_def:
  kwCREATE base_table_def_OPT_temp kwTABLE
  base_table_OR_view   /* parser will ensure we don't use a view here */
  pLPAREN base_table_element_commalist pRPAREN
  base_table_def_OPT_commit
  {
  chainNext($4,$8);
  chainNext($4,$2);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateTable,ctUnknown,$4,$6);
  log.add(yywho,yywhere,format('base_table_def (create table...) %p',[$$]),vDebug);
  }
  ;

base_table_def_OPT_temp:
  kwGLOBAL kwTEMPORARY
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntGlobalTemporary,ctUnknown,0,0);
  log.add(yywho,yywhere,format('base_table_def_OPT_temp (global temporary) %p',[$$]),vDebug);
  }
  | kwLOCAL kwTEMPORARY
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntLocalTemporary,ctUnknown,0,0);
  log.add(yywho,yywhere,format('base_table_def_OPT_temp (local temporary) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

base_table_def_OPT_commit:
  kwON kwCOMMIT kwDELETE kwROWS
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntOnCommitDelete,ctUnknown,0,0);
  log.add(yywho,yywhere,format('base_table_def_OPT_commit (on commit delete rows) %p',[$$]),vDebug);
  }
  | kwON kwCOMMIT kwPRESERVE kwROWS
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntOnCommitPreserve,ctUnknown,0,0);
  log.add(yywho,yywhere,format('base_table_def_OPT_commit (on commit preserve rows) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

base_table_element:
  column_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('base_table_element (column_def) %p',[$$]),vDebug);
  }
  | base_table_constraint_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('base_table_element (base_table_constraint_def) %p',[$$]),vDebug);
  }
  ;

base_table_element_commalist:
  base_table_element pCOMMA base_table_element_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('base_table_element_commalist (e,list) %p',[$$]),vDebug);
  }
  | base_table_element
  {
  $$:=$1;
  log.add(yywho,yywhere,format('base_table_element_commalist (e) %p',[$$]),vDebug);
  }
  ;

column_def:
  column datatype column_def_OPT_default column_def_OPT_constraint
  {
  chainNext($2,$4);
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('column_def (column datatype...) %p',[$$]),vDebug);
  }
  | column domain column_def_OPT_default column_def_OPT_constraint
  {
  chainNext($2,$4);
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('column_def (column domain...) %p',[$$]),vDebug);
  }
  ;

column_def_OPT_default:
  default_def
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

column_def_OPT_constraint:
  column_constraint_def_list
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

view_def:
  kwCREATE kwVIEW base_table_OR_view OPT_column_commalist   /* parser will ensure we don't use a base_table here */
    kwAS table_exp
    view_def_OPT_with
  {
  chainNext($3,$7);
  chainNext($6,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateView,ctUnknown,$3,$6);
  if check_start_text<>'' then  (* store view definition (has leading NAME AS and trailing LEXEME which we remove) *)
    $$.strVal:=copy(check_start_text,1,yyoffset-check_start_at -length(yytext));
  log.add(yywho,yywhere,format('view_def (create view...) %p is at %d,%d (%d,%d %s)',[$$,yylineNo,yycolno,check_start_at,yyoffset,$$.strVal]),vDebug);
  check_start_text:='';
  }
  ;

view_def_OPT_with:
  kwWITH view_def_OPT_with_OPT_type kwCHECK kwOPTION
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntWithCheckOption,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('view_def_OPT_with (with check option) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

view_def_OPT_with_OPT_type:
  kwCASCADED
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCascaded,ctUnknown,0,0);
  }
  | kwLOCAL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntLocal,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

routine_def:
  kwCREATE procedure_or_function routine
  pLPAREN OPT_routine_parameter_commalist pRPAREN
  routine_def_OPT_returns
  sql_compound_element          /* not sql_list to prevent early acceptance */
  {
  chainAppendNext($3,$2);
  if $5<>nil then
  begin
    chainAppendNext($5,$7);
    chainNext($8,$5);
  end
  else
    chainNext($8,$7);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCreateRoutine,ctUnknown,$3,$8);
  if check_start_text<>'' then  (* store routine definition (has leading NAME AS and trailing LEXEME which we remove) *)
    $$.strVal:=copy(check_start_text,1,yyoffset-check_start_at -length(yytext));
  log.add(yywho,yywhere,format('routine_def (create procedure/function...) %p is at %d,%d (%d,%d %s)',[$$,yylineNo,yycolno,check_start_at,yyoffset,$$.strVal]),vDebug);
  check_start_text:='';
  }
  ;

routine_parameter_commalist:
  routine_parameter_def pCOMMA routine_parameter_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('routine_parameter_commalist (e,list) %p',[$$]),vDebug);
  }
  | routine_parameter_def
  {
  $$:=$1;
  log.add(yywho,yywhere,format('routine_parameter_commalist (e) %p',[$$]),vDebug);
  }
  ;

OPT_routine_parameter_commalist:
  routine_parameter_commalist
  {
  $$:=$1;
  }
  | /* nothing */
  {$$:=nil;}
  ;

routine_parameter_def:
  OPT_direction routine_parameter datatype OPT_default_def
  {
  chainNext($3,$1);
  chainNext($3,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntParameterDef,ctUnknown,$2,$3);
  log.add(yywho,yywhere,format('routine_parameter_def (routine_parameter datatype...) %p',[$$]),vDebug);
  }
  ;

routine_def_OPT_returns:
  kwRETURNS datatype
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntResult,ctUnknown,0,0);
  chainNext($2,node);
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntId,ctUnknown,0,0);
  node.idVal:=FunctionReturnParameterName;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntParameterDef,ctUnknown,node,$2);
  log.add(yywho,yywhere,format('routine_def_OPT_returns (returns) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_direction:
  direction
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

direction:
  kwIN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntIn,ctUnknown,0,0);
  log.add(yywho,yywhere,format('direction (in) %p',[$$]),vDebug);
  }
  | kwOUT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntOut,ctUnknown,0,0);
  log.add(yywho,yywhere,format('direction (out) %p',[$$]),vDebug);
  }
  | kwINOUT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntInOut,ctUnknown,0,0);
  log.add(yywho,yywhere,format('direction (inout) %p',[$$]),vDebug);
  }
  ;

procedure_or_function:
  kwPROCEDURE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntProcedure,ctUnknown,0,0);
  }
  | kwFUNCTION
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntFunction,ctUnknown,0,0);
  }
  ;

declaration:
  kwDECLARE cursor OPT_cursor_sensitivity OPT_scroll kwCURSOR
  OPT_cursor_lifetime
  kwFOR table_exp table_exp_OPT_orderby
  OPT_cursor_specification
  {
  chainNext($8,$9);
  chainNext($2,$3);
  chainNext($2,$4);
  chainNext($2,$6);
  chainNext($2,$10);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCursorDeclaration,ctUnknown,$2,$8);
  log.add(yywho,yywhere,format('declaration cursor %p',[$$]),vDebug);
  }
  | kwDECLARE column_commalist datatype OPT_default_def
  {
  chainNext($3,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDeclaration,ctUnknown,$2,$3);
  log.add(yywho,yywhere,format('declaration %p',[$$]),vDebug);
  }
  ;

OPT_cursor_specification:
  kwFOR kwREAD kwONLY
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntForReadOnly,ctUnknown,0,0);
  }
  | kwFOR kwUPDATE kwOF column_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntForUpdate,ctUnknown,$4,nil);
  }
  | kwFOR kwUPDATE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntForUpdate,ctUnknown,nil,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_cursor_lifetime:
  kwWITH kwHOLD kwWITH kwRETURN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorHold,ctUnknown,0,0);
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorReturn,ctUnknown,0,0);
  chainNext($$,node);
  }
  | kwWITH kwRETURN kwWITH kwHOLD
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorReturn,ctUnknown,0,0);
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorHold,ctUnknown,0,0);
  chainNext($$,node);
  }
  | kwWITH kwHOLD
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorHold,ctUnknown,0,0);
  }
  | kwWITH kwRETURN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCursorReturn,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_cursor_sensitivity:
  kwSENSITIVE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSensitive,ctUnknown,0,0);
  }
  | kwINSENSITIVE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntInsensitive,ctUnknown,0,0);
  }
  | kwASENSITIVE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAsensitive,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_scroll:
  kwSCROLL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntScroll,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

open:
  kwOPEN cursor
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOpen,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('open %p',[$$]),vDebug);
  }
  ;

close:
  kwCLOSE cursor
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntClose,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('close %p',[$$]),vDebug);
  }
  ;

fetch:
  kwFETCH cursor OPT_fetch_orientation
  kwINTO target_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntFetch,ctUnknown,$2,$3);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntInto,ctUnknown,$5,nil);
  chainNext($$,node);
  log.add(yywho,yywhere,format('fetch %p',[$$]),vDebug);
  }
  ;

OPT_fetch_orientation:
  kwFROM
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNext,ctUnknown,0,0);
  }
  | kwNEXT kwFROM
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNext,ctUnknown,0,0);
  }
  | kwPRIOR kwFROM
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntPrior,ctUnknown,0,0);
  }
  | kwFIRST kwFROM
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntFirst,ctUnknown,0,0);
  }
  | kwLAST kwFROM
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntLast,ctUnknown,0,0);
  }
  | kwABSOLUTE integer kwFROM
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAbsolute,ctUnknown,$2,nil);
  }
  | kwRELATIVE integer kwFROM
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRelative,ctUnknown,$2,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

assignment:
  kwSET update_assignment
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAssignment,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('assignment %p',[$$]),vDebug);
  }
  ;

return:
  kwRETURN scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntReturn,ctUnknown,nil,$2);
  log.add(yywho,yywhere,format('return %p',[$$]),vDebug);
  }
  ;

leave:
  kwLEAVE compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntLeave,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('leave %p',[$$]),vDebug);
  }
  ;

iterate:
  kwITERATE compound_label_end
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntIterate,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('iterate %p',[$$]),vDebug);
  }
  ;


authorization_def:
  kwGRANT privilege_commalist_or_all kwON accessible_object
  kwTO grantee_commalist authorization_def_OPT_with
  {
  chainNext($4,$2);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntGrant,ctUnknown,$4,$6);
  chainNext($$,$7);
  log.add(yywho,yywhere,format('authorization_def (grant...) %p',[$$]),vDebug);
  }
  ;


deferrability:
  kwINITIALLY kwDEFERRED OPT_deferrable
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInitiallyDeferred,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('deferrability (initially deferred...) %p',[$$]),vDebug);
  }
  | deferrable kwINITIALLY kwDEFERRED
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInitiallyDeferred,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('deferrability (...initially deferred) %p',[$$]),vDebug);
  }
  | kwINITIALLY kwIMMEDIATE OPT_deferrable
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInitiallyImmediate,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('deferrability (initially immediate...) %p',[$$]),vDebug);
  }
  | deferrable kwINITIALLY kwIMMEDIATE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInitiallyImmediate,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('deferrability (...initially immediate) %p',[$$]),vDebug);
  }
  | deferrable
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInitiallyImmediate,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('deferrability (...) %p',[$$]),vDebug);
  }
  ;

OPT_deferrable:
  deferrable
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

deferrable:
  kwNOT kwDEFERRABLE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNotDeferrable,ctUnknown,0,0);
  log.add(yywho,yywhere,format('deferrable (not deferrable) %p',[$$]),vDebug);
  }
  | kwDEFERRABLE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDeferrable,ctUnknown,0,0);
  log.add(yywho,yywhere,format('deferrable (deferrable) %p',[$$]),vDebug);
  }
  ;

privilege_commalist_or_all:
  kwALL kwPRIVILEGES
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAllPrivileges,ctUnknown,0,0);
  log.add(yywho,yywhere,format('privilege_commalist_or_all (all privileges) %p',[$$]),vDebug);
  }
  | privilege_commalist
  {
  $$:=$1;
  }
  ;

privilege_commalist:
  privilege pCOMMA privilege_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('privilege_commalist (e,list) %p',[$$]),vDebug);
  }
  | privilege
  {
  $$:=$1;
  log.add(yywho,yywhere,format('privilege (e) %p',[$$]),vDebug);
  }
  ;

privilege:
  kwSELECT OPT_column_commalist /* SQL-99 allows OPT_column_commalist here */
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeSelect,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('privilege (select) %p',[$$]),vDebug);
  }
  | kwINSERT OPT_column_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeInsert,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('privilege (insert) %p',[$$]),vDebug);
  }
  | kwUPDATE OPT_column_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeUpdate,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('privilege (update) %p',[$$]),vDebug);
  }
  | kwDELETE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeDelete,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('privilege (delete) %p',[$$]),vDebug);
  }
  | kwREFERENCES OPT_column_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeReferences,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('privilege (references) %p',[$$]),vDebug);
  }
  | kwUSAGE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeUsage,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('privilege (usage) %p',[$$]),vDebug);
  }
  | kwEXECUTE
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrivilegeExecute,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('privilege (execute) %p',[$$]),vDebug);
  }
  ;

accessible_object:
  kwDOMAIN domain
  {
  $$:=$2;
  log.add(yywho,yywhere,format('accessible_object (domain) %p',[$$]),vDebug);
  }
  | kwTABLE table
  {
  $$:=$2;
  log.add(yywho,yywhere,format('accessible_object (TABLE table) %p',[$$]),vDebug);
  }
  | kwCHARACTER kwSET character_set
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCharacterSet,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('accessible_object (character_set) %p',[$$]),vDebug);
  }
  | kwCOLLATION collation
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCollation,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('accessible_object (collation) %p',[$$]),vDebug);
  }
  | kwTRANSLATION translation
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTranslation,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('accessible_object (translation) %p',[$$]),vDebug);
  }
  | kwROUTINE routine
  {
  $$:=$2;
  log.add(yywho,yywhere,format('accessible_object (ROUTINE routine) %p',[$$]),vDebug);
  }
  | kwPROCEDURE routine
  {
  $$:=$2;
  log.add(yywho,yywhere,format('accessible_object (PROCEDURE routine) %p',[$$]),vDebug);
  }
  | kwFUNCTION routine
  {
  $$:=$2;
  log.add(yywho,yywhere,format('accessible_object (FUNCTION routine) %p',[$$]),vDebug);
  }
  | table
  {
  $$:=$1;
  log.add(yywho,yywhere,format('accessible_object (table) %p',[$$]),vDebug);
  }
  ;

grantee_commalist:
  grantee pCOMMA grantee_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('grantee_commalist (e,list) %p',[$$]),vDebug);
  }
  | grantee
  {
  $$:=$1;
  log.add(yywho,yywhere,format('grantee_commalist (e) %p',[$$]),vDebug);
  }
  ;

grantee:
  user
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUser,ctUnknown,$1,nil);
  }
  | kwPUBLIC
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUser,ctUnknown,nil,nil);    // Note nil,nil -> PUBLIC
  }
  ;

authorization_def_OPT_with:
  kwWITH kwGRANT kwOPTION
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntWithGrantOption,ctUnknown,0,0);
  log.add(yywho,yywhere,format('authorization_def_OPT_with (with grant option) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

base_table_alteration:
  kwALTER kwTABLE base_table_OR_view   /* parser will ensure we don't use a view here */
  base_table_alteration_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAlterTable,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('base_table_alteration %p',[$$]),vDebug);
  }
  ;

base_table_alteration_action:
  column_alteration_action
  | base_table_constraint_alteration_action
  ;

column_alteration_action:
  kwADD OPT_column column_def
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAddColumn,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('column_alteration_action (add column) %p',[$$]),vDebug);
  }
  | kwALTER OPT_column column column_alteration_alter_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAlterColumn,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('column_alteration_action (alter column) %p',[$$]),vDebug);
  }
  | kwDROP OPT_column column drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropColumn,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('column_alteration_action (drop column) %p',[$$]),vDebug);
  }
  ;

column_alteration_alter_action:
  kwSET default_def
  {
  $$:=$2;
  }
  | kwDROP kwDEFAULT
  {
  $$:=nil;
  }
  ;

base_table_constraint_alteration_action:
  kwADD base_table_constraint_def
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAddConstraint,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('base_table_constraint_alteration_action (add constraint) %p',[$$]),vDebug);
  }
  | kwDROP kwCONSTRAINT constraint drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropConstraint,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('base_table_constraint_alteration_action (drop constraint) %p',[$$]),vDebug);
  }
  ;

schema_drop:
  kwDROP kwSCHEMA
  schema
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropSchema,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('schema_drop %p',[$$]),vDebug);
  }
  ;

domain_drop:
  kwDROP kwDOMAIN
  domain
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropDomain,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('domain_drop %p',[$$]),vDebug);
  }
  ;

base_table_drop:
  kwDROP kwTABLE
  base_table_OR_view   /* parser will ensure we don't use a view here */
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropTable,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('base_table_drop %p',[$$]),vDebug);
  }
  ;

view_drop:
  kwDROP kwVIEW
  base_table_OR_view   /* parser will ensure we don't use a base table here */
  drop_referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropView,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('view_drop %p',[$$]),vDebug);
  }
  ;

routine_drop:
  kwDROP procedure_or_function_or_routine routine
  drop_referential_action
  {
  chainNext($3,$2);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDropRoutine,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('routine_drop %p',[$$]),vDebug);
  }
  ;

procedure_or_function_or_routine:
  procedure_or_function
  {
  $$:=$1;
  }
  | kwROUTINE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntProcedureOrFunction,ctUnknown,0,0);
  }
  ;

authorization_drop:
  kwREVOKE authorization_drop_OPT_for
  privilege_commalist_or_all kwON accessible_object
  kwFROM grantee_commalist drop_referential_action
  {
  chainNext($5,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRevoke,ctUnknown,$5,$7);
  chainNext($$,$8);
  chainNext($$,$2);
  log.add(yywho,yywhere,format('authorization_drop (revoke...) %p',[$$]),vDebug);
  }
  ;

authorization_drop_OPT_for:
  kwGRANT kwOPTION kwFOR
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntWithGrantOption,ctUnknown,0,0);    //we re-use syntax node
  log.add(yywho,yywhere,format('authorization_drop_OPT_for (grant option for) %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

drop_referential_action:
  kwCASCADE
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCascade,ctUnknown,0,0);}
  | kwRESTRICT
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntRestrict,ctUnknown,0,0);}
  ;

/******************
  Data Manipluation
*******************/

/* Note: select_exp is in next section */

insert:
  kwINSERT kwINTO table
    insert_OPT_values
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInsert,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('insert %p',[$$]),vDebug);
  }
  ;

insert_OPT_values:
  OPT_column_commalist table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntInsertValues,ctUnknown,$1,$2);
  }
  | kwDEFAULT kwVALUES
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDefaultValues,ctUnknown,0,0);
  }
  ;

searched_update:
  kwUPDATE table_OPT_as_range kwSET update_assignment_commalist
  select_exp_OPT_where
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUpdate,ctUnknown,$2,$5);
  chainNext($$,$4);
  log.add(yywho,yywhere,format('searched_update %p',[$$]),vDebug);
  }
  ;

update_assignment:
  column pEQUAL kwDEFAULT
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUpdateAssignment,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('update_assignment (column=DEFAULT) %p',[$$]),vDebug);
  }
  | column pEQUAL scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUpdateAssignment,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('update_assignment (column=scalar_exp) %p',[$$]),vDebug);
  }
  ;

update_assignment_commalist:
  update_assignment pCOMMA update_assignment_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | update_assignment
  {
  $$:=$1;
  }
  ;

searched_delete:
  kwDELETE kwFROM table_OPT_as_range select_exp_OPT_where
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDelete,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('searched_delete %p',[$$]),vDebug);
  }
  ;

table_exp_OPT_orderby:
  kwORDER kwBY order_item_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOrderBy,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('table_exp_OPT_orderby %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

order_item:
  column_ref OPT_ascdesc
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOrderItem,$1.dtype(*ctUnknown*),$1,$2);
  log.add(yywho,yywhere,format('order_item (column) %p',[$$]),vDebug);
  log.add(yywho,yywhere,format('  $1.dtype=%d',[ord($1.dtype)]),vDebug);
  }
  | integer OPT_ascdesc     /* Note: deprecated */
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOrderItem,$1.dtype(*ctUnknown*),$1,$2);
  log.add(yywho,yywhere,format('order_item (integer) %p',[$$]),vDebug);
  }
  ;

order_item_commalist:
  order_item pCOMMA order_item_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | order_item
  {
  $$:=$1;
  }
  ;

call_routine:
  kwCALL routine pLPAREN OPT_scalar_exp_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCallRoutine,ctUnknown,$2,$4);
  log.add(yywho,yywhere,format('call_routine (call) %p',[$$]),vDebug);
  }
  ;

/*******************
  Table Expresssions
********************/

table_exp:
  join_table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableExp,ctUnknown,$1,nil);
  }
  | nonjoin_table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableExp,ctUnknown,$1,nil);
  }
  ;

join_table_exp:
  table_ref kwCROSS kwJOIN table_ref
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCrossJoin,ctUnknown,$4,$1);   
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntJoinTableExp,ctUnknown,node,nil);
  log.add(yywho,yywhere,format('join_table_exp (table_ref cross join table_ref) %p',[$$]),vDebug);
  }
  | table_ref OPT_natural join_table_exp_OPT_jointype kwJOIN table_ref
    join_table_exp_OPT_onusing
  {
  (* if $6=nil then *)
    node:=mkNode(GlobalParseStmt.srootAlloc,ntJoin,ctUnknown,$5,$1);
  (* else
    node:=mkNode(GlobalParseStmt.srootAlloc,ntJoin,ctUnknown,$1,$5); *)
  chainNext(node,$6);
  chainNext(node,$2);
  chainNext(node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntJoinTableExp,ctUnknown,node,nil);
  log.add(yywho,yywhere,format('join_table_exp (table_ref [natural] [join type] join table_ref [on/using...]) %p',[$$]),vDebug);
  }
  | pLPAREN join_table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntJoinTableExp,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('join_table_exp (join_table_ref) %p',[$$]),vDebug);
  }
  ;

join_table_exp_OPT_jointype:
  join_type
  | /* nothing */ {$$:=nil;}
  ;

join_table_exp_OPT_onusing:
  kwON cond_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntJoinOn,ctUnknown,$2,nil);
  }
  | kwUSING pLPAREN column_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntJoinUsing,ctUnknown,$3,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

table_ref:
  join_table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('table_ref (join_table_exp) %p',[$$]),vDebug);
  }
  | table table_ref_ascolumn
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('table_ref (table [as]) %p',[$$]),vDebug);
  }
  | table
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('table_ref (table) %p',[$$]),vDebug);
  }
  | pLPAREN table_exp pRPAREN OPT_as range_variable OPT_column_commalist
  {
  chainNext($5,$6);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$2,$5);
  }
/*
  | pLPAREN table_exp pRPAREN table_ref_ascolumn
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$2,$4);
  log.add(yywho,yywhere,format('table_ref ((table_exp) [as]) %p',[$$]),vDebug);
  }
*/
  ;

table_ref_ascolumn:
  kwAS range_variable OPT_column_commalist
  {
  chainNext($2,$3);
  $$:=$2;
  }
  /* conflicts with join keywords */
  | range_variable OPT_column_commalist
  {
  chainNext($1,$2);
  $$:=$1;
  }
  ;

/* this used to be a chain list like any other commalist
   but we needed to adjust parent-child links for view expansions so
   we made it a tree to simplify the tree-juggling code
   (maybe should have altered structure of table_ref syntax nodes to allow them to be chained=neater...??)
*/
table_ref_commalist:
  table_ref_commalist pCOMMA table_ref  
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCrossJoin,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('table_ref_commalist (list,e) %p',[$$]),vDebug);
  }
  | table_ref
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCrossJoin,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('table_ref_commalist (e) %p',[$$]),vDebug);
  }
  ;

join_type:
  kwINNER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntJoinInner,ctUnknown,0,0);
  }
  | kwLEFT OPT_outer
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntJoinLeft,ctUnknown,0,0);
  }
  | kwRIGHT OPT_outer
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntJoinRight,ctUnknown,0,0);
  }
  | kwFULL OPT_outer
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntJoinFull,ctUnknown,0,0);
  }
  | kwUNION
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntJoinUnion,ctUnknown,0,0);
  }
  ;

nonjoin_table_exp:
  nonjoin_table_term
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTableExp,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('nonjoin_table_exp (nonjoin_table_term) %p',[$$]),vDebug);
  }
  | table_exp ONE_unionexcept OPT_all
    nonjoin_table_exp_OPT_corresponding
    table_term
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntUnionExcept,ctUnknown,$1,$5);
  chainNext(node,$4);
  chainNext(node,$3);
  chainNext(node,$2);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTableExp,ctUnknown,node,nil);
  log.add(yywho,yywhere,format('nonjoin_table_exp (table_exp [union/except] [all] [corresponding...] table_term) %p',[$$]),vDebug);
  }
  ;

nonjoin_table_exp_OPT_corresponding:
  kwCORRESPONDING kwBY pLPAREN column_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCorrespondingBy,ctUnknown,$4,nil);
  }
  | kwCORRESPONDING
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCorresponding,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

nonjoin_table_term:
  nonjoin_table_primary
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTableTerm,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('nonjoin_table_term (nonjoin_table_primary) %p',[$$]),vDebug);
  }
  | table_term kwINTERSECT OPT_all
    nonjoin_table_exp_OPT_corresponding
    table_primary
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntIntersect,ctUnknown,$1,$5);
  chainNext(node,$4);
  chainNext(node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTableTerm,ctUnknown,node,nil);
  log.add(yywho,yywhere,format('nonjoin_table_term (table_term intersect [all] [corresponding...] table_primary) %p',[$$]),vDebug);
  }
  ;

table_term:
  join_table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableTerm,ctUnknown,$1,nil);
  }
  | nonjoin_table_term
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableTerm,ctUnknown,$1,nil);
  }
  ;

table_primary:
  join_table_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTablePrimary,ctUnknown,$1,nil);
  }
  | nonjoin_table_primary
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTablePrimary,ctUnknown,$1,nil);
  }
  ;

nonjoin_table_primary:
  pLPAREN nonjoin_table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTablePrimary,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('nonjoin_table_primary ( (nonjoin_table_exp) ) %p',[$$]),vDebug);
  }
  | select_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTablePrimary,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('nonjoin_table_primary ( select_exp ) %p',[$$]),vDebug);
  }
  | kwTABLE table
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTablePrimary,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('nonjoin_table_primary ( TABLE table ) %p',[$$]),vDebug);
  }
  | table_constructor
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNonJoinTablePrimary,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('nonjoin_table_primary ( table_constructor ) %p',[$$]),vDebug);
  }
  ;

table_constructor:
  kwVALUES row_constructor_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableConstructor,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('table_constructor %p',[$$]),vDebug);
  }
  ;

/*row_constructor was moved after numeric_exp*/
row_constructor:
  pLPAREN scalar_exp_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('row_constructor ( scalar_exp_commalist ) %p',[$$]),vDebug);
  }
  /* not needed? above covers it? */
  | pLPAREN table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('row_constructor ( table_exp ) %p',[$$]),vDebug);
  }
  | scalar_exp
  {
  //Note: moving this below the other 2 reduce the conflicts enormously! - not sure any more...
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('row_constructor (scalar_exp) %p',[$$]),vDebug);
  }
  ;

/*
row_constructor:
  scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('row_constructor (scalar_exp) %p',[$$]),vDebug);
  }
  | pLPAREN scalar_exp_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('row_constructor ( scalar_exp_commalist ) %p',[$$]),vDebug);
  }
  | pLPAREN table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('row_constructor ( table_exp ) %p',[$$]),vDebug);
  }
  ;
*/
row_constructor_commalist:
  row_constructor pCOMMA row_constructor_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('row_constructor_commalist ( rc,rcclist ) %p',[$$]),vDebug);
  }
  | row_constructor
  {
  $$:=$1;
  log.add(yywho,yywhere,format('row_constructor_commalist ( rc ) %p',[$$]),vDebug);
  }
  ;


select_exp:
  kwSELECT OPT_alldistinct select_item_commalist
  kwFROM table_ref_commalist
  select_exp_OPT_where
  select_exp_OPT_groupby
  select_exp_OPT_having
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSelect,ctUnknown,$3,$5);
  chainNext($$,$2);
  chainNext($$,$8);
  chainNext($$,$7);
  chainNext($$,$6);
  log.add(yywho,yywhere,format('select_exp %p',[$$]),vDebug);
  log.add(yywho,yywhere,format('  $$.dtype=%d',[ord($$.dtype)]),vDebug);
  }
  ;

select_exp_OPT_where:
  kwWHERE cond_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntWhere,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('select_exp_OPT_where %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

select_exp_OPT_groupby:
  kwGROUP kwBY column_ref_commalist
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntGroupBy,ctUnknown,$3,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

select_exp_OPT_having:
  kwHAVING cond_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntHaving,ctUnknown,$2,nil);
  }
  | /* nothing */ {$$:=nil;}
  ;

select_item_commalist:
  select_item pCOMMA select_item_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | select_item
  {
  $$:=$1;
  }
  ;

select_item:
  scalar_exp select_item_OPT_ascolumn
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSelectItem,$1.dtype(*ctUnknown*),$1,$2);
  log.add(yywho,yywhere,format('select_item (scalar_exp [as...]) %p',[$$]),vDebug);
  log.add(yywho,yywhere,format('  $1.dtype=%d',[ord($1.dtype)]),vDebug);
  }
  | tIDENTIFIER pDOT pASTERISK
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSelectAll,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('select_item (range.*) %p',[$$]),vDebug);
  }
  | pASTERISK
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSelectAll,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('select_item (*) %p',[$$]),vDebug);
  }
  ;

select_item_OPT_ascolumn:
  OPT_as column
  {
  $$:=$2;
  log.add(yywho,yywhere,format('select_item_OPT_ascolumn %p',[$$]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

select_item_OPT_range:
  range_variable pDOT
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

single_row_select:
  kwSELECT OPT_alldistinct select_item_commalist
  kwINTO target_commalist
  kwFROM table_ref_commalist
  select_exp_OPT_where
  select_exp_OPT_groupby
  select_exp_OPT_having
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSelect,ctUnknown,$3,$7);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntInto,ctUnknown,$5,nil);
  chainNext($$,node);
  chainNext($$,$2);
  chainNext($$,$10);
  chainNext($$,$9);
  chainNext($$,$8);
  log.add(yywho,yywhere,format('single_row_select %p',[$$]),vDebug);
  log.add(yywho,yywhere,format('  $$.dtype=%d',[ord($$.dtype)]),vDebug);
  }
  ;

target_commalist:
  routine_parameter pCOMMA target_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | routine_parameter
  {
  $$:=$1;
  }
  ;

/************************
  Conditional Expressions
************************/

cond_exp:
  cond_term
  {
  $$:=$1;
  log.add(yywho,yywhere,format('cond_exp (t) %p',[$$]),vDebug);
  }
  | cond_exp kwOR cond_term
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOR,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('cond_exp (e OR t) %p',[$$]),vDebug);
  }
  ;

cond_term:
  cond_factor
  {
  $$:=$1;
  log.add(yywho,yywhere,format('cond_term (f) %p',[$$]),vDebug);
  }
  | cond_term kwAND cond_factor
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAND,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('cond_term (t AND f) %p',[$$]),vDebug);
  }
  ;

cond_factor:
  cond_test
  {
  $$:=$1;
  log.add(yywho,yywhere,format('cond_factor (cond_test) %p',[$$]),vDebug);
  }
  | kwNOT cond_test
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,$2,nil);
  log.add(yywho,yywhere,format('cond_factor (NOT cond_test) %p',[$$]),vDebug);
  }
  ;

cond_test:
  cond_primary
    cond_test_OPT_is
  {
  if $2=nil then
  begin
    $$:=$1;
    log.add(yywho,yywhere,format('cond_test %p',[$$]),vDebug);
  end
  else
  begin
    if $2.nType=ntNOT then
      linkLeftChild($2.leftChild,$1)
    else
      linkLeftChild($2,$1);
    $$:=$2;
    log.add(yywho,yywhere,format('cond_test (cond_primary IS/IS NOT) %p',[$$]),vDebug);
  end;
  }
  ;

cond_test_OPT_is:
  kwIS OPT_not cond_test_OPT_is_ONE_triLogic
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntIS,ctUnknown,nil,$3);
  if $2=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('is... %p',[$$]),vDebug);
  end
  else
  begin
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('is NOT... %p',[$$]),vDebug);
  end;
  }
  | /* nothing */ {$$:=nil;}
  ;

cond_test_OPT_is_ONE_triLogic:
  kwTRUE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntTrue,ctUnknown,0,0);
  }
  | kwFALSE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntFalse,ctUnknown,0,0);
  }
  | kwUNKNOWN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntUnknown,ctUnknown,0,0);
  }
  ;

cond_primary:
  simple_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('cond_primary (simple_cond) %p',[$$]),vDebug);
  }
  | pLPAREN cond_exp pRPAREN
  {
  $$:=$2;
  log.add(yywho,yywhere,format('cond_primary ( (cond_exp) ) %p',[$$]),vDebug);
  }
  ;

simple_cond:
  all_or_any_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (all_or_any) %p',[$$]),vDebug);
  }
  | comparison_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (comparison_cond) %p',[$$]),vDebug);
  }
  | between_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (between_cond) %p',[$$]),vDebug);
  }
  | like_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (like_cond) %p',[$$]),vDebug);
  }
  | in_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (in_cond) %p',[$$]),vDebug);
  }
  | match_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (match_cond) %p',[$$]),vDebug);
  }
  | exists_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (exists_cond) %p',[$$]),vDebug);
  }
  | unique_cond
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (unique_cond) %p',[$$]),vDebug);
  }
  | test_for_null
  {
  $$:=$1;
  log.add(yywho,yywhere,format('simple_cond (test_for_null) %p',[$$]),vDebug);
  }
  ;

comparison_cond:
  row_constructor comparison_operator row_constructor
  {
  linkLeftChild($2,$1);
  linkRightChild($2,$3);
  $$:=$2;
  log.add(yywho,yywhere,format('comparison_cond %p',[$$]),vDebug);
  }
  ;

comparison_operator:
  pEQUAL
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntEqual,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (=) %p',[$$]),vDebug);
  }
  | pLT
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntLT,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (<) %p',[$$]),vDebug);
  }
  | pLTEQ
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntLTEQ,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (<=) %p',[$$]),vDebug);
  }
  | pGT
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntGT,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (>) %p',[$$]),vDebug);
  }
  | pGTEQ
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntGTEQ,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (>=) %p',[$$]),vDebug);
  }
  | pNOTEQUAL
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNotEqual,ctUnknown,nil,nil);
  log.add(yywho,yywhere,format('comparison_operator (<>) %p',[$$]),vDebug);
  }
  ;

between_cond:
  row_constructor OPT_not kwBETWEEN row_constructor
    kwAND row_constructor
  {
  node2:=mkNode(GlobalParseStmt.srootAlloc,ntGTEQ,ctUnknown,$1,$4);
  node3:=mkNode(GlobalParseStmt.srootAlloc,ntLTEQ,ctUnknown,$1,$6);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntAND,ctUnknown,node2,node3);
  if $2=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('between_cond %p',[$$]),vDebug);
  end
  else
  begin
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('between_cond (NOT) %p',[$$]),vDebug);
  end;
  }
  ;

like_cond:
/*  character_string_exp  -had to reduce stringency here to handle NOT BETWEEN etc.*/
  row_constructor
  OPT_not kwLIKE scalar_exp
  like_cond_OPT_escape
  {
  // note: maybe syntax error here if $1 is not a character expression
  // Brute force optimisation done here: todo move out of parser!
  if ($4.leftChild.nType=ntString) and ($5=nil) then
  begin
    if (pos('%',$4.leftChild.strVal)+pos('_',$4.leftChild.strVal))<>0 then  //note: too crude!
      node:=mkNode(GlobalParseStmt.srootAlloc,ntLike,ctUnknown,$1,$4)
    else
    begin
      node:=mkNode(GlobalParseStmt.srootAlloc,ntRowConstructor,ctUnknown,$4,nil);
      node:=mkNode(GlobalParseStmt.srootAlloc,ntEqual,ctUnknown,$1,node);
      log.add(yywho,yywhere,format('like_cond optimised to =%s %p',[$4.leftChild.strVal,$$]),vDebug);
    end;
  end
  else
    node:=mkNode(GlobalParseStmt.srootAlloc,ntLike,ctUnknown,$1,$4);

  if $2=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('like_cond %p DEBUG:%d',[$$,ord($4.leftChild.nType)]),vDebug);
  end
  else
  begin
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('like_cond (NOT) %p',[$$]),vDebug);
  end;
  }
  ;

like_cond_OPT_escape:
  kwESCAPE scalar_exp
  | /* nothing */ {$$:=nil;}
  ;

in_cond:
  row_constructor OPT_not kwIN pLPAREN table_exp pRPAREN
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntEqual,ctUnknown,nil,nil);
  linkLeftChild(node,$1);
  linkRightChild(node,$5);
  if $2=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('in_cond %p',[$$]),vDebug);
  end
  else
  begin
    //Note: the way we convert NOT IN -> NOT(IN)
    //may not always be exactly correct for tuples: see Page 242/243?
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('in_cond (NOT) %p',[$$]),vDebug);
  end;
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntAny,ctUnknown,0,0);
  chainNext($5,node);
  }
/* scalar_exp- reduced stringency here to allow parsing of other IN constructs */
/* note: much better to have 1 IN rule: row_con [NOT] IN (row_con)   ? */
  | row_constructor OPT_not kwIN pLPAREN scalar_exp_commalist pRPAREN
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntINscalar,ctUnknown,$1,$5);
  if $2=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('in_cond (scalar) %p',[$$]),vDebug);
  end
  else
  begin
    //Note: the way we convert NOT IN -> NOT(IN)
    //may not always be exactly correct for tuples: see Page 242/243?
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('in_cond (scalar) (NOT) %p',[$$]),vDebug);
  end;
  }
  ;

match_cond:
  row_constructor kwMATCH OPT_unique
    OPT_partialfull pLPAREN table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntMatch,ctUnknown,$1,$6);
  chainNext($6,$3);
  chainNext($6,$4);
  log.add(yywho,yywhere,format('match_cond %p',[$$]),vDebug);
  }
  ;

all_or_any_cond:
  row_constructor
    comparison_operator all_or_any_cond_ONE_op pLPAREN table_exp pRPAREN
  {
  linkLeftChild($2,$1);
  linkRightChild($2,$5);
  chainNext($5,$3);
  $$:=$2;
  log.add(yywho,yywhere,format('all_or_any_cond %p',[$$]),vDebug);
  }
  ;

all_or_any_cond_ONE_op:
  kwALL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAll,ctUnknown,0,0);
  log.add(yywho,yywhere,format('all %p',[$$]),vDebug);
  }
  | kwANY
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAny,ctUnknown,0,0);
  log.add(yywho,yywhere,format('any %p',[$$]),vDebug);
  }
  | kwSOME
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAny,ctUnknown,0,0);
  log.add(yywho,yywhere,format('some (=any) %p',[$$]),vDebug);
  }
  ;

exists_cond:
  kwEXISTS pLPAREN table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntExists,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('exists_cond %p',[$$]),vDebug);
  }
  ;

unique_cond:
  kwUNIQUE pLPAREN table_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntIsUnique,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('unique_cond %p',[$$]),vDebug);
  }
  ;

/* overlaps_cond moved after scalar_exp_commalist due to shift/reduce conflict
   e.g. where (1,2)=(1,2)
*/

test_for_null:
  row_constructor kwIS OPT_not kwNULL
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntISnull,ctUnknown,$1,nil);
  if $3=nil then
  begin
    $$:=node;
    log.add(yywho,yywhere,format('test_for_null (IS) %p',[$$]),vDebug);
  end
  else
  begin
    //Note: the way we convert IS NOT NULL -> NOT(IS NULL)
    //is not always exactly correct for tuples: see Page 242/243
    $$:=mkNode(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,node,nil);
    log.add(yywho,yywhere,format('test_for_null (IS NOT) %p',[$$]),vDebug);
  end;
  }
  ;

/************
  Constraints
************/

base_table_constraint_def:
  OPT_constraint
    candidate_key_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('base_table_constraint_def (candidate_key_def) %p',[$$]),vDebug);
  }
  | OPT_constraint
    foreign_key_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('base_table_constraint_def (foreign_key_def) %p',[$$]),vDebug);
  }
  | OPT_constraint
    check_constraint_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('base_table_constraint_def (check) %p',[$$]),vDebug);
  }
  ;

OPT_constraint:
  kwCONSTRAINT constraint
  {
  $$:=$2;
  }
  | /* nothing */ {$$:=nil;}
  ;

candidate_key_def:
  kwPRIMARY kwKEY pLPAREN column_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPrimaryKeyDef,ctUnknown,$4,nil);
  }
  | kwUNIQUE pLPAREN column_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUniqueDef,ctUnknown,$3,nil);
  }
  ;

foreign_key_def:
  kwFOREIGN kwKEY pLPAREN column_commalist pRPAREN references_def
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntForeignKeyDef,ctUnknown,$4,$6);
  }
  ;

references_def:
  kwREFERENCES base_table_OR_view OPT_column_commalist   /* parser will ensure we don't use a view here */
    references_def_OPT_match
    references_def_OPT_ondeleteupdate
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntReferencesDef,ctUnknown,$2,$3);
  chainNext($$,$5);
  chainNext($$,$4);
  }
  ;

references_def_OPT_ondeleteupdate:
  references_def_ondelete
  references_def_onupdate
  {
  $$:=$1;
  chainNext($$,$2);
  }
  | references_def_onupdate
  references_def_ondelete
  {
  $$:=$2;
  chainNext($$,$1);
  }
  | references_def_ondelete
  {
  $$:=$1;
  }
  | references_def_onupdate
  {
  $$:=$1;
  }
  | /* nothing */ {$$:=nil;}
  ;

references_def_OPT_match:
  kwMATCH kwFULL
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMatchFull,ctUnknown,0,0);}
  | kwMATCH kwPARTIAL
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMatchPartial,ctUnknown,0,0);}
  | /* nothing */ {$$:=nil;}
  ;

references_def_ondelete:
  kwON kwDELETE referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOnDelete,ctUnknown,$3,nil);
  }
  ;

references_def_onupdate:
  kwON kwUPDATE referential_action
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOnUpdate,ctUnknown,$3,nil);
  }
  ;

referential_action:
  kwNO kwACTION
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNoAction,ctUnknown,0,0);}
  | kwCASCADE
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCascade,ctUnknown,0,0);}
  | kwSET kwDEFAULT
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSetDefault,ctUnknown,0,0);}
  | kwSET kwNULL
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSetNull,ctUnknown,0,0);}
  ;

check_constraint_def:
  kwCHECK pLPAREN cond_exp pRPAREN
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntCondExpText,ctVarChar,0,0);
  node.strVal:=copy(check_start_text,1,yyoffset-check_start_at);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCheckConstraint,ctUnknown,$3,node);
  log.add(yywho,yywhere,format('check_constraint_def text is at %d,%d (%d,%d %s)',[yylineNo,yycolno,check_start_at,yyoffset,node.strVal]),vDebug);
  check_start_text:='';
  }
  ;

column_constraint_def:
  OPT_constraint
    kwNOT kwNULL OPT_deferrability
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNotNull,ctUnknown,0,0);
  chainNext(node,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,node);
  log.add(yywho,yywhere,format('column_constraint_def (not null) %p',[$$]),vDebug);
  }
  | OPT_constraint kwPRIMARY kwKEY OPT_deferrability
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntPrimaryKey,ctUnknown,0,0);
  chainNext(node,$4);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,node);
  log.add(yywho,yywhere,format('column_constraint_def (primary key) %p',[$$]),vDebug);
  }
  | OPT_constraint kwUNIQUE OPT_deferrability
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntUnique,ctUnknown,0,0);
  chainNext(node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,node);
  log.add(yywho,yywhere,format('column_constraint_def (unique) %p',[$$]),vDebug);
  }
  /* note: what about foreign_key_def ? should be inserted before references_def below
    -> error in SQL4? p405 - I don't think so, table constraints have column lists..
  */
  | OPT_constraint
    references_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('column_constraint_def (references) %p',[$$]),vDebug);
  }
  | OPT_constraint
    check_constraint_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('column_constraint_def (check) %p',[$$]),vDebug);
  }
  ;

column_constraint_def_list:
  column_constraint_def column_constraint_def_list
  {
  chainNext($1,$2);
  $$:=$1;
  }
  | column_constraint_def
  {
  $$:=$1;
  }
  ;

domain_constraint_def:
  OPT_constraint
    check_constraint_def OPT_deferrability
  {
  chainNext($2,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraintDef,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('column_constraint_def (check) %p',[$$]),vDebug);
  }
  ;

constraint_commalist:
  constraint pCOMMA constraint_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('constraint_commalist (e,list) %p',[$$]),vDebug);
  }
  | constraint
  {
  $$:=$1;
  log.add(yywho,yywhere,format('constraint_commalist (e) %p',[$$]),vDebug);
  }
  ;

set_constraints:
  kwSET kwCONSTRAINTS kwALL ONE_deferredimmediate
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSetConstraints,ctUnknown,nil,$4);
  log.add(yywho,yywhere,format('set_constraints (ALL) %p',[$$]),vDebug);
  }
  | kwSET kwCONSTRAINTS constraint_commalist ONE_deferredimmediate
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSetConstraints,ctUnknown,$3,$4);
  log.add(yywho,yywhere,format('set_constraints (constraint_commalist) %p',[$$]),vDebug);
  }
  ;


/*******************
  Scalar Expressions
*******************/
scalar_exp:
  generic_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNumericExp,ctUnknown (*debug CASE? but broke group-by tests: ctFloat*),$1,nil);
  log.add(yywho,yywhere,format('scalar_exp (generic_exp) %p',[$$]),vDebug);
  }
  ;

scalar_exp_commalist:
  scalar_exp pCOMMA scalar_exp_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_exp_commalist (se,seclist) %p',[$$]),vDebug);
  }
  | scalar_exp
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_exp_commalist (se) %p',[$$]),vDebug);
  }
  ;

OPT_scalar_exp_commalist:
  scalar_exp_commalist
  {$$:=$1;}
  | /* nothing */
  {$$:=nil;}
  ;

scalar_exp_commalist_literal_order:
  scalar_exp pCOMMA scalar_exp_commalist_literal_order
  {
  chainAppendNext($1,$3);
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_exp_commalist_literal_order (se,seclist) %p',[$$]),vDebug);
  }
  | scalar_exp
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_exp_commalist_literal_order (se) %p',[$$]),vDebug);
  }
  ;

generic_exp:
  generic_term
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_exp (generic_term) %p',[$$]),vDebug);
  }
  | generic_exp ONE_plusminus generic_term
  {
  linkLeftChild($2,$1);
  linkRightChild($2,$3);
  $$:=$2;
  log.add(yywho,yywhere,format('generic_exp (generic_exp +- generic_term) %p',[$$]),vDebug);
  }
  | generic_concatenation
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_exp (generic_concatenation) %p',[$$]),vDebug);
  }
  /* todo (date - date) start to end - see CH17 - dynamic only? */
  ;

generic_term:
  generic_factor
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_term (generic_factor) %p',[$$]),vDebug);
  }
  | generic_term ONE_multdiv generic_factor
  {
  linkLeftChild($2,$1);
  linkRightChild($2,$3);
  $$:=$2;
  log.add(yywho,yywhere,format('generic_term (generic_term /* generic_factor) %p',[$$]),vDebug);
  }
/*
  | generic_primary / datetime_term_OPT_atzone  todo record opt atzone /
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_term (generic_primary) %p',[$$]),vDebug);
  }
*/
  ;

datetime_term_OPT_atzone:
  kwAT kwLOCAL
  | kwAT kwTIME kwZONE generic_primary
  | /* nothing */
  ;


generic_factor:
  pMINUS generic_primary
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,1,0);
  node.numVal:=0;
  node.nullVal:=false;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntMinus,ctUnknown,node,$2);
  log.add(yywho,yywhere,format('generic_factor (- generic_primary) %p',[$$]),vDebug);
  }
  | pPLUS generic_primary
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,1,0);
  node.numVal:=0;
  node.nullVal:=false;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPlus,ctUnknown,node,$2);
  log.add(yywho,yywhere,format('generic_factor (+ generic_primary) %p',[$$]),vDebug);
  }
  | generic_primary
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_factor (generic_primary) %p',[$$]),vDebug);
  }
  ;

generic_primary:
  column_ref
  | lit_param_or_var
  | scalar_function_ref
  | aggregate_function_ref
  | authID_function_ref
  | datetime_function_ref
  | diagnostic_function_ref
  {
  $$:=$1;
  log.add(yywho,yywhere,format('generic_primary () %p',[$$]),vDebug);
  }
  /* conflicts but tolerable? */
  | pLPAREN table_exp pRPAREN
  {
  $$:=$2;
  log.add(yywho,yywhere,format('generic_primary ( (table_exp) ) %p',[$$]),vDebug);
  }
  /* covered by above? */
  | pLPAREN generic_exp pRPAREN
  {
  $$:=$2;
  log.add(yywho,yywhere,format('generic_primary ( (generic_exp) ) %p',[$$]),vDebug);
  }
  ;

aggregate_function_ref:
  aggregate_function_ref_ONE_fn
    pLPAREN OPT_alldistinct scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAggregate,ctUnknown,$1,$4);
  chainNext($$,$3);
  (* todo check if $1.ntype=ntSum or ntAvg then $4.dtype must be numeric *)
  log.add(yywho,yywhere,format('aggregate_function_ref %p',[$$]),vDebug);
  }
  | kwCOUNT pLPAREN OPT_alldistinct scalar_exp pRPAREN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCount,ctNumeric,0,0);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAggregate,ctUnknown,$$,$4);
  chainNext($$,$3);
  (* only needed because above does not beat below *)
  log.add(yywho,yywhere,format('aggregate_function_ref (COUNT(scalar_exp)) %p',[$$]),vDebug);
  }
  | kwCOUNT pLPAREN pASTERISK pRPAREN
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCount,ctNumeric,0,0);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAggregate,ctNumeric,$$,nil);
  log.add(yywho,yywhere,format('aggregate_function_ref (COUNT(*)) %p',[$$]),vDebug);
  }
  ;

aggregate_function_ref_ONE_fn:
  kwAVG
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAvg,ctNumeric,0,0);}
  | kwMAX
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMax,ctUnknown,0,0);}
  | kwMIN
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMin,ctUnknown,0,0);}
  | kwSUM
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSum,ctNumeric,0,0);}
  | kwCOUNT
  {$$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCount,ctNumeric,0,0);}
  ;

generic_concatenation:
  scalar_exp pCONCAT generic_primary
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConcat,ctVarChar,$1,$3);
  }
  ;


/* moved here, after scalar_exp_commalist - not actually used yet = major conflicts */
overlaps_cond:
/*  pLPAREN scalar_exp pCOMMA scalar_exp pRPAREN
    kwOVERLAPS pLPAREN scalar_exp pCOMMA scalar_exp pRPAREN
todo scalar_exp cause conflict with scalar_exp_commalist
 quick fix: made more specific - too specific -see page 278!
*/
  pLPAREN scalar_exp pCOMMA scalar_exp pRPAREN
    kwOVERLAPS pLPAREN scalar_exp pCOMMA scalar_exp pRPAREN /*note: wrong! */
  {
  $$:=$6;
  log.add(yywho,yywhere,format('overlaps_cond ( (scalar_exp,scalar_exp) OVERLAPS (scalar_exp,scalar_exp) ) %p',[$$]),vDebug);
  }
  ;

/* row constructor was moved here (after numeric_exp) to try to improve reduce/reduce resolution
   e.g. where 12=(2*6) - don't think it had any effect - so moved back
*/


/**************
  Miscellaneous
**************/

catalog:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('catalog %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

schema:
  tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('schema (identifier) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

domain:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDomain,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('domain (catalog.schema.domain) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDomain,ctUnknown,node,$1);
  log.add(yywho,yywhere,format('domain (schema.domain) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDomain,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('domain (domain) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;


column:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('column %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

column_ref:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,node,$5);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnRef,ctUnknown,node,$7);
  log.add(yywho,yywhere,format('column_ref (catalog.schema.table.column) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnRef,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('column_ref (schema.table.column) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,nil,$1);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnRef,ctUnknown,node,$3);
  log.add(yywho,yywhere,format('column_ref (table.column) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntColumnRef,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('column_ref (column) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

table:
  base_table_OR_view
  {
  $$:=$1;
  log.add(yywho,yywhere,format('table (base_table_OR_view) %p',[$$]),vDebug);
  }
  ;

table_OPT_as_range:
  table OPT_as_range
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTableRef,ctUnknown,$1,$2);
  }
  ;

OPT_as_range:
  /* AS mandatory: internal use only (cascade FK) */
  kwAS range_variable
  {
  $$:=$2;
  }
  | /* nothing */ {$$:=nil;}
  ;

base_table_OR_view:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('base_table_OR_view (catalog.schema.table) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,node,$3);
  log.add(yywho,yywhere,format('base_table_OR_view (schema.table) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTable,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('base_table_OR_view (table) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

routine:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRoutine,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('routine (catalog.schema.routine) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRoutine,ctUnknown,node,$3);
  log.add(yywho,yywhere,format('routine (schema.routine) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntRoutine,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('routine (routine) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

routine_parameter:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('routine_parameter %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

compound_label:
  tLABEL
  {
  $$:=$1;
  log.add(yywho,yywhere,format('compound_label %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

OPT_compound_label:
  compound_label
  {
  $$:=$1;
  log.add(yywho,yywhere,format('OPT_compound_label %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | /* nothing */
  {
  $$:=nil;
  }
  ;

compound_label_end:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('compound_label_end %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

OPT_compound_label_end:
  compound_label_end
  {
  $$:=$1;
  log.add(yywho,yywhere,format('OPT_compound_label_end %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | /* nothing */
  {
  $$:=nil;
  }
  ;

constraint:
  tIDENTIFIER pDOT tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCatalog,ctUnknown,nil,$1);
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,node,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraint,ctUnknown,node,$5);
  log.add(yywho,yywhere,format('constraint (catalog.schema.constraint) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER pDOT tIDENTIFIER
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$3);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraint,ctUnknown,node,$1);
  log.add(yywho,yywhere,format('constraint (schema.constraint) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntConstraint,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('constraint (constraint) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

collation:
  tIDENTIFIER pDOT tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$3;
  }
  | tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$1;
  }
  /* todo catalog - need another type */
  ;

translation:
  tIDENTIFIER pDOT tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$3;
  }
  | tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$1;
  }
  /* todo catalog - need another type */
  ;

character_set:
  tIDENTIFIER pDOT tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$3;
  }
  | tIDENTIFIER /*todo lex to distinguish between these id types*/
  {
  $$:=$1;
  }
  /* todo catalog - need another type */
  ;

column_ref_commalist:
  column_ref pCOMMA column_ref_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | column_ref
  {
  $$:=$1;
  }
  ;

param_or_var:
  /* note: dynamic only? */
  kwNULL
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNull,ctVarChar,0,0); (* need some type for select null results *)
  node.nullVal:=true;
  node.dwidth:=length(nullshow); (*note: only really for ISQL demo*)
  $$:=node;
  log.add(yywho,yywhere,format('param_or_var (null) %p',[$$]),vDebug);
  }
  /* note: dynamic insert only */
  | kwDEFAULT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDefault,ctUnknown,0,0);
  log.add(yywho,yywhere,format('param_or_var (default) %p',[$$]),vDebug);
  }
  | tPARAM
  {
  $$:=$1;
  globalParseStmt.addParam($$); (* todo check result *)
  log.add(yywho,yywhere,format('param_or_var (param) %p',[$$]),vDebug);
  }
  ;

lit_param_or_var:
  literal_DATE
  | literal_TIME
  | literal_TIMESTAMP
  | literal_INTERVAL
  | literal_BITSTRING
  | literal_STRING
  | literal_NUM
  | literal_BLOB
  | param_or_var
  ;


niladic_function_ref:
  authID_function_ref
  | datetime_function_ref
  | diagnostic_function_ref
  ;

authID_function_ref:
  kwUSER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentUser,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (user) %p',[$$]),vDebug);
  }
  | kwCURRENT_USER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentUser,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (current_user) %p',[$$]),vDebug);
  }
  | kwSESSION_USER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSessionUser,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (session_user) %p',[$$]),vDebug);
  }
  | kwSYSTEM_USER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSystemUser,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (system_user) %p',[$$]),vDebug);
  }
  | kwCURRENT_AUTHID
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentAuthID,ctInteger,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (current_authid) %p',[$$]),vDebug);
  }
  | kwCURRENT_CATALOG
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentCatalog,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (current_catalog) %p',[$$]),vDebug);
  }
  | kwCURRENT_SCHEMA
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentSchema,ctVarChar,0,0);
  log.add(yywho,yywhere,format('authID_function_ref (current_schema) %p',[$$]),vDebug);
  }
  ;

datetime_function_ref:
  kwCURRENT_DATE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntCurrentDate,ctDate,0,0);
  log.add(yywho,yywhere,format('datetime_function_ref (current date) %p',[$$]),vDebug);
  }
  | kwCURRENT_TIME OPT_integer
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCurrentTime,ctTime,$2,nil);
  log.add(yywho,yywhere,format('datetime_function_ref (current time) %p',[$$]),vDebug);
  }
  | kwCURRENT_TIMESTAMP OPT_integer
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCurrentTimestamp,ctTimestamp,$2,nil);
  log.add(yywho,yywhere,format('datetime_function_ref (current timestamp) %p',[$$]),vDebug);
  }
  ;

diagnostic_function_ref:
  kwSQLSTATE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSQLState,ctVarChar,0,0);
  log.add(yywho,yywhere,format('diagnostic_function_ref (sqlstate) %p',[$$]),vDebug);
  }
  ;

/***********
  Primitives
***********/

/* moved above
catalog:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('catalog %p, yylval=%p',[$$,yylval]),vDebug);
  };
*/

/* column was here
   - moved above table for column_ref to pick up
*/

column_commalist:
  column pCOMMA column_commalist
  {
  chainNext($1,$3);
  $$:=$1;
  }
  | column
  ;

range_variable:       /* Note: the standard refers to this as a correlation name */
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('range_variable %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

cursor:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('cursor %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

datatype:
  /* todo replace all (integer) with (numeric_exp)? - check standard allows */
  ONE_character pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCharacter,ctChar,$3,nil);
  log.add(yywho,yywhere,format('datatype (character(integer)) %p',[$$]),vDebug);
  }
  | ONE_character
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,0,0);
  node.numVal:=1;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCharacter,ctChar,node,nil);
  log.add(yywho,yywhere,format('datatype (character) %p',[$$]),vDebug);
  }
  | ONE_character kwVARYING pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntVarChar,ctVarChar,$4,nil);
  log.add(yywho,yywhere,format('datatype (character varying(integer)) %p',[$$]),vDebug);
  }
  | kwVARCHAR pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntVarChar,ctVarChar,$3,nil);
  log.add(yywho,yywhere,format('datatype (varchar(integer)) %p',[$$]),vDebug);
  }
  | kwBIT pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntBit,ctBit,$3,nil);
  log.add(yywho,yywhere,format('datatype (bit(integer)) %p',[$$]),vDebug);
  }
  | kwBIT kwVARYING pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntVarBit,ctVarBit,$4,nil);
  log.add(yywho,yywhere,format('datatype (bit varying(integer)) %p',[$$]),vDebug);
  }
  | kwNUMERIC pLPAREN integer pCOMMA integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNumeric,ctNumeric,$3,$5);
  log.add(yywho,yywhere,format('datatype (numeric(integer,integer)) %p',[$$]),vDebug);
  }
  | kwNUMERIC pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNumeric,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('datatype (numeric(integer)) %p',[$$]),vDebug);
  }
  | kwNUMERIC
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumeric,ctNumeric,0,0);
  log.add(yywho,yywhere,format('datatype (numeric) %p',[$$]),vDebug);
  }
  | ONE_decimal pLPAREN integer pCOMMA integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDecimal,ctDecimal,$3,$5);
  log.add(yywho,yywhere,format('datatype (decimal(integer,integer)) %p',[$$]),vDebug);
  }
  | ONE_decimal pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntDecimal,ctDecimal,$3,nil);
  log.add(yywho,yywhere,format('datatype (decimal(integer)) %p',[$$]),vDebug);
  }
  | ONE_decimal
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDecimal,ctDecimal,0,0);
  log.add(yywho,yywhere,format('datatype (decimal) %p',[$$]),vDebug);
  }
  | ONE_integer
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntInteger,ctInteger,0,0);
  log.add(yywho,yywhere,format('datatype (integer) %p',[$$]),vDebug);
  }
  | kwSMALLINT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntSmallInt,ctSmallInt,0,0);
  log.add(yywho,yywhere,format('datatype (smallint) %p',[$$]),vDebug);
  }
  | kwBIGINT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntBigInt,ctBigInt,0,0);
  log.add(yywho,yywhere,format('datatype (bigint) %p',[$$]),vDebug);
  }
  | kwFLOAT pLPAREN integer pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntFloat,ctFloat,$3,nil);
  log.add(yywho,yywhere,format('datatype (float(integer)) %p',[$$]),vDebug);
  }
  | kwFLOAT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntFloat,ctFloat,0,0);
  log.add(yywho,yywhere,format('datatype (float) %p',[$$]),vDebug);
  }
  | kwREAL
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,0,0);
  node.numVal:=DefaultRealSize;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntFloat,ctFloat,node,nil);
  log.add(yywho,yywhere,format('datatype (real) %p',[$$]),vDebug);
  }
  | kwDOUBLE kwPRECISION 
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,0,0);
  node.numVal:=DefaultDoubleSize;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntFloat,ctFloat,node,nil);
  log.add(yywho,yywhere,format('datatype (double precision) %p',[$$]),vDebug);
  }
  | kwDATE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDate,ctDate,0,0);
  log.add(yywho,yywhere,format('datatype (date) %p',[$$]),vDebug);
  }
  | kwTIME pLPAREN integer pRPAREN OPT_withtimezone
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTime,ctTime,$3,$5);
  log.add(yywho,yywhere,format('datatype (time(integer)) %p',[$$]),vDebug);
  }
  | kwTIME OPT_withtimezone
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTime,ctTime,nil,$2);
  log.add(yywho,yywhere,format('datatype (time) %p',[$$]),vDebug);
  }
  | kwTIMESTAMP pLPAREN integer pRPAREN OPT_withtimezone
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTimestamp,ctTimestamp,$3,$5);
  log.add(yywho,yywhere,format('datatype (timestamp(integer)) %p',[$$]),vDebug);
  }
  | kwTIMESTAMP OPT_withtimezone
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTimestamp,ctTimestamp,nil,$2);
  log.add(yywho,yywhere,format('datatype (timestamp) %p',[$$]),vDebug);
  }
  | ONE_blob
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,0,0);
  node.numVal:=1024;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntBlob,ctBlob,node,nil);
  log.add(yywho,yywhere,format('datatype (blob) %p',[$$]),vDebug);
  }
  | ONE_blob pLPAREN blob_length pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntBlob,ctBlob,$4,nil);
  log.add(yywho,yywhere,format('datatype (blob(integer)) %p',[$$]),vDebug);
  }
  | ONE_clob
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,0,0);
  node.numVal:=1024;
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntClob,ctClob,node,nil);
  log.add(yywho,yywhere,format('datatype (clob) %p',[$$]),vDebug);
  }
  | ONE_clob pLPAREN blob_length pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntClob,ctClob,$4,nil);
  log.add(yywho,yywhere,format('datatype (clob(integer)) %p',[$$]),vDebug);
  }
  ;

blob_length:
  integer
  {
  $$:=$1;
  log.add(yywho,yywhere,format('blob_length (integer) %p, yylval=%p',[$$,yylval]),vDebug);
  };


OPT_withtimezone:
  kwWITH kwTIME kwZONE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntWithTimezone,ctUnknown,0,0);
  }
  | /* nothing */  {$$:=nil;}
  ;

integer:
  tINTEGER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('integer %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

real:
  tREAL
  {
  $$:=$1;
  log.add(yywho,yywhere,format('real %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

string:
  tSTRING
  {
  $$:=$1;
  log.add(yywho,yywhere,format('string %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

blob:
  tBLOB
  {
  $$:=$1;
  log.add(yywho,yywhere,format('blob %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

literal_DATE:
  kwDATE string
  /* todo check format and give syntax error now? */
  {
  $$:=$2;
  $$.ntype:=ntDate;
  $$.dtype:=ctDate;
  log.add(yywho,yywhere,format('literal_DATE %p, yylval=%p',[$$,yylval]),vDebug);
  try
    strToSqlDate(yylval.strVal);
  except
    (*todo raise better*)
    log.add(yywho,yywhere,format('error in line %d, column %d at token %s ($$=%p)',[yylineno,yycolno,yytext,$$]),vError);
    log.add(yywho,yywhere,format('...%s%s',[yytext,GlobalParseStmt.InputText]),vError);
    GlobalSyntaxErrLine:=yylineno;
    GlobalSyntaxErrCol:=yycolno;
    GlobalSyntaxErrMessage:=format('...%s%s...',[yytext,copy(GlobalParseStmt.InputText,1,30)]);
    yyabort;
  end;
  }
  ;
literal_TIME:
  kwTIME string
  /* todo check format and give syntax error now? */
  {
  $$:=$2; (*todo plus timezone*)
  $$.ntype:=ntTime;
  $$.dtype:=ctTime;
  log.add(yywho,yywhere,format('literal_TIME %p, yylval=%p',[$$,yylval]),vDebug);
  try
    strToSqlTime(TIMEZONE_ZERO,yylval.strVal,dayCarry);
  except
    (*todo raise better*)
    log.add(yywho,yywhere,format('error in line %d, column %d at token %s ($$=%p)',[yylineno,yycolno,yytext,$$]),vError);
    log.add(yywho,yywhere,format('...%s%s',[yytext,GlobalParseStmt.InputText]),vError);
    GlobalSyntaxErrLine:=yylineno;
    GlobalSyntaxErrCol:=yycolno;
    GlobalSyntaxErrMessage:=format('...%s%s...',[yytext,copy(GlobalParseStmt.InputText,1,30)]);
    yyabort;
  end;
  }
  ;
literal_TIMESTAMP:
  kwTIMESTAMP string
  /* todo check format and give syntax error now? */
  {
  $$:=$2; (*todo plus timezone*)
  $$.ntype:=ntTimestamp;
  $$.dtype:=ctTimestamp;
  log.add(yywho,yywhere,format('literal_TIMESTAMP %p, yylval=%p',[$$,yylval]),vDebug);
  try
    strToSqlTimestamp(TIMEZONE_ZERO,yylval.strVal);
  except
    (*todo raise better*)
    log.add(yywho,yywhere,format('error in line %d, column %d at token %s ($$=%p)',[yylineno,yycolno,yytext,$$]),vError);
    log.add(yywho,yywhere,format('...%s%s',[yytext,GlobalParseStmt.InputText]),vError);
    GlobalSyntaxErrLine:=yylineno;
    GlobalSyntaxErrCol:=yycolno;
    GlobalSyntaxErrMessage:=format('...%s%s...',[yytext,copy(GlobalParseStmt.InputText,1,30)]);
    yyabort;
  end;
  }
  ;
literal_INTERVAL:
  kwINTERVAL string
  /* todo check format and give syntax error now? */
  {
  $$:=$2;
  log.add(yywho,yywhere,format('literal_INTERVAL %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
literal_BITSTRING:
  kwBIT string
  /* todo check format and give syntax error now */
  {
  $$:=$2;
  log.add(yywho,yywhere,format('literal_BITSTRING %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
literal_STRING:
  string
  {
  $$:=$1;
  log.add(yywho,yywhere,format('literal_STRING %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
literal_NUM:
  integer
  {
  $$:=$1;
  log.add(yywho,yywhere,format('literal_NUM (integer) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | real
  {
  $$:=$1;
  log.add(yywho,yywhere,format('literal_NUM (real) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ; /* todo & rest */
literal_BLOB:
  blob
  {
  $$:=$1;
  log.add(yywho,yywhere,format('literal_BLOB %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

scalar_function_ref:
  /* +etc. */
  cast_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (cast_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | case_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (case_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | case_shorthand_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (case_shorthand_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | char_length_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (char_length_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | octet_length_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (octet_length_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | trim_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (trim_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | fold_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (fold_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | position_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (position_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | substring_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (substring_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | sequence_expression  /* non-standard */
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (sequence_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | user_function_expression
  {
  $$:=$1;
  log.add(yywho,yywhere,format('scalar_function_ref (user_function_expression) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

user_function_expression:
  routine pLPAREN OPT_scalar_exp_commalist pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUserFunction,ctUnknown,$1,$3);
  log.add(yywho,yywhere,format('user_function_expression %p',[$$]),vDebug);
  }
  ;

cast_expression:
  kwCAST pLPAREN scalar_exp kwAS datatype pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCast,$5.dtype(*ctUnknown*),$3,$5);
  log.add(yywho,yywhere,format('cast_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

case_expression:
  kwCASE
    when_clause_list
    case_OPT_else
  kwEND
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCase,ctUnknown,$2,$3);
  log.add(yywho,yywhere,format('case_expression (condition list) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  |
  kwCASE scalar_exp
    when_clause_type2_list
    case_OPT_else
  kwEND
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntCaseOf,ctUnknown,nil,$3);
  linkLeftChild(node,$2); (* link after, so we use type of when_clause *)
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCase,ctUnknown,node,$4);
  log.add(yywho,yywhere,format('case_expression (of + expression list) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
case_OPT_else:
  kwELSE scalar_exp
  {
  $$:=$2;
  log.add(yywho,yywhere,format('case_OPT_else %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

when_clause:
  kwWHEN cond_exp kwTHEN scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntWhen,ctUnknown,nil,$4); (* note: mkNode to allow mixed children types here *)
  linkLeftChild($$,$2); (* link after, so we use type of THEN *)
  log.add(yywho,yywhere,format('when_clause %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
when_clause_list:
  when_clause_list when_clause
  {
  chainNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('when_clause_list (list,e) %p',[$$]),vDebug);
  }
  |
  when_clause
  {
  $$:=$1;
  log.add(yywho,yywhere,format('when_clause_list (e) %p',[$$]),vDebug);
  }
  ;

when_clause_type2:
  kwWHEN scalar_exp kwTHEN scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntWhenType2,ctUnknown,nil,$4);    (* note: mkNode to allow mixed children types here *)
  linkLeftChild($$,$2); (* link after, so we use type of THEN *)
  log.add(yywho,yywhere,format('when_clause_type2 %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;
when_clause_type2_list:
  when_clause_type2_list when_clause_type2
  {
  chainNext($1,$2);
  $$:=$1;
  log.add(yywho,yywhere,format('when_clause_type2_list (list,e) %p',[$$]),vDebug);
  }
  |
  when_clause_type2
  {
  $$:=$1;
  log.add(yywho,yywhere,format('when_clause_type2_list (e) %p',[$$]),vDebug);
  }
  ;

case_shorthand_expression:
  kwNULLIF pLPAREN scalar_exp pCOMMA scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNullIf,ctUnknown,$3,$5);
  log.add(yywho,yywhere,format('case_shorthand_expression (nullif) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwCOALESCE pLPAREN scalar_exp_commalist_literal_order pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCoalesce,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('case_shorthand_expression (coalesce) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

trim_expression:
  kwTRIM pLPAREN trim_what kwFROM scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTrim,ctUnknown,$3,$5);
  log.add(yywho,yywhere,format('trim_expression (what char) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwTRIM pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTrim,ctUnknown,nil,$3);
  log.add(yywho,yywhere,format('trim_expression (char) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

trim_what:
  scalar_exp
  {
  node:=mkLeaf(GlobalParseStmt.srootAlloc,ntTrimBoth,ctUnknown,0,0);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTrimWhat,ctUnknown,node,$1);
  log.add(yywho,yywhere,format('OPT_trim_what (char) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | trim_where
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTrimWhat,ctUnknown,$1,nil);
  log.add(yywho,yywhere,format('OPT_trim_what (trim_where) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | trim_where scalar_exp
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntTrimWhat,ctUnknown,$1,$2);
  log.add(yywho,yywhere,format('OPT_trim_what (trim_where char) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

trim_where:
  kwLEADING
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntTrimLeading,ctUnknown,0,0);
  log.add(yywho,yywhere,format('trim_where (LEADING) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwTRAILING
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntTrimTrailing,ctUnknown,0,0);
  log.add(yywho,yywhere,format('trim_where (TRAILING) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwBOTH
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntTrimBoth,ctUnknown,0,0);
  log.add(yywho,yywhere,format('trim_where (BOTH) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

char_length_expression:
  kwCHARACTER_LENGTH pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCharLength,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('character_length_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwCHAR_LENGTH pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntCharLength,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('char_length_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

octet_length_expression:
  kwOCTET_LENGTH pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntOctetLength,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('octet_length_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

fold_expression:
  kwLOWER pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntLower,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('fold_expression (LOWER) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwUPPER pLPAREN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUpper,ctUnknown,$3,nil);
  log.add(yywho,yywhere,format('fold_expression (UPPER) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

position_expression:
  kwPOSITION pLPAREN scalar_exp kwIN scalar_exp pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPosition,ctNumeric,$3,$5);
  log.add(yywho,yywhere,format('position_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

substring_expression:
  kwSUBSTRING pLPAREN scalar_exp kwFROM generic_exp kwFOR generic_exp pRPAREN
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSubstringFrom,ctUnknown,$5,$7);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSubstring,ctUnknown,$3,node);
  log.add(yywho,yywhere,format('substring_expression (FOR) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwSUBSTRING pLPAREN scalar_exp kwFROM generic_exp pRPAREN
  {
  node:=mkNode(GlobalParseStmt.srootAlloc,ntSubstringFrom,ctUnknown,$5,nil);
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSubstring,ctUnknown,$3,node);
  log.add(yywho,yywhere,format('substring_expression %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

sequence_expression:
  kwNEXT_SEQUENCE pLPAREN sequence pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntNextSequence,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('sequence_expression (next) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | kwLATEST_SEQUENCE pLPAREN sequence pRPAREN
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntLatestSequence,ctNumeric,$3,nil);
  log.add(yywho,yywhere,format('sequence_expression (latest) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

password:
  kwPASSWORD lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPassword,ctUnknown,$2,nil);
  }
  ;

user:
  tIDENTIFIER
  {
  $$:=$1;
  log.add(yywho,yywhere,format('user %p, yylval=%p',[$$,yylval]),vDebug);
  }
  ;

/************************
  Productions to simplify
   the grammar rules

   note: for all non-noise words, return a leaf or something!
   i.e. ensure we've removed all stubs!
************************/

OPT_as:
  kwAS
  | /* nothing */ {$$:=nil;}
  ;

OPT_all:
  kwALL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAll,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_alldistinct:
  kwALL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntAll,ctUnknown,0,0);
  }
  | kwDISTINCT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDistinct,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

ONE_plusminus:
  pPLUS
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntPlus,ctUnknown,0,0);
  }
  | pMINUS
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMinus,ctUnknown,0,0);
  }
  ;

OPT_plusminus:
  ONE_plusminus
  | /* nothing */ {$$:=nil;}
  ;

ONE_multdiv:
  pASTERISK
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntMultiply,ctUnknown,0,0);
  }
  | pSLASH
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDivide,ctUnknown,0,0);
  }
  ;

OPT_integer:
  pLPAREN integer pRPAREN
  {$$:=$2;}
  | /* nothing */ {$$:=nil;}
  ;

OPT_not:
  kwNOT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNOT,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_unique:
  kwUNIQUE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntUNIQUE,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_partialfull:
  kwPARTIAL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntPARTIAL,ctUnknown,0,0);
  }
  | kwFULL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntFULL,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_deferrability:
  deferrability
  | /* nothing */ {$$:=nil;}
  ;

OPT_column_commalist:
  pLPAREN column_commalist pRPAREN
  {
  $$:=$2;
  }
  | /* nothing */ {$$:=nil;}
  ;

ONE_unionexcept:
  kwUNION
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntUnion,ctUnknown,0,0);
  }
  | kwEXCEPT
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntExcept,ctUnknown,0,0);
  }
  ;

OPT_outer:
  kwOUTER
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntOuter,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_natural:
  kwNATURAL
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntNatural,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_ascdesc:
  kwASC
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntASC,ctUnknown,0,0);
  }
  | kwDESC
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDESC,ctUnknown,0,0);
  }
  | /* nothing */ {$$:=nil;}
  ;

ONE_character:
  kwCHARACTER
  | kwCHAR
  ;

ONE_integer:
  kwINTEGER
  | kwINT
  ;

ONE_decimal:
  kwDECIMAL
  | kwDEC
  ;

ONE_blob:
  kwBINARY kwLARGE kwOBJECT
  | kwBLOB
  ;

ONE_clob:
  ONE_character kwLARGE kwOBJECT
  | kwCLOB
  ;

OPT_work:
  kwWORK
  | /* nothing */
  ;

OPT_column:
  kwCOLUMN
  | /* nothing */
  ;

OPT_schema:
  tIDENTIFIER
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntSchema,ctUnknown,nil,$1);
  log.add(yywho,yywhere,format('schema (identifier) %p, yylval=%p',[$$,yylval]),vDebug);
  }
  | /* nothing */ {$$:=nil;}
  ;

OPT_authorization:
  kwAUTHORIZATION user
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAuthorization,ctUnknown,$2,nil);
  }
  | /* nothing */  {$$:=nil;}
  ;

OPT_asConnection:
  kwAS lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntAsConnection,ctUnknown,$2,nil);
  }
  | /* nothing */  {$$:=nil;}
  ;

OPT_user:
  kwUSER lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntUser,ctUnknown,$2,nil);
  }
  | /* nothing */  {$$:=nil;}
  ;


OPT_password:
  kwPASSWORD lit_param_or_var
  {
  $$:=mkNode(GlobalParseStmt.srootAlloc,ntPassword,ctUnknown,$2,nil);
  }
  | /* nothing */  {$$:=nil;}
  ;

OPT_default_character_set:
  kwDEFAULT kwCHARACTER kwSET character_set
  {
  $$:=$4;
  }
  | /* nothing */  {$$:=nil;}
  ;

OPT_semicolon:
  pSEMICOLON
  | /* nothing */
  ;

ONE_deferredimmediate:
  kwDEFERRED
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntDeferred,ctUnknown,0,0);
  }
  | kwIMMEDIATE
  {
  $$:=mkLeaf(GlobalParseStmt.srootAlloc,ntImmediate,ctUnknown,0,0);
  }
  ;


%%
{$INCLUDE sqllex}
{supporting routines}


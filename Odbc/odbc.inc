{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{This is an 'include' file containing ODBC definitions and function declarations.
 This file has been created separate so it can be used in the
 client, server, and ODBC interface CLI code.

 Note:
 $define SQL_API   in outer unit to declare functions as stdcall, i.e. for the ODBC driver definition
 $define IMPORT    in outer unit to declare functions as external ODBC_DLL, i.e. for the ODBC Delphi interface definition (also need to define ODBC_DLL e.g. 'sqlODBC.dll')

 $define NO_FUNCTIONS in outer unit to omit all function delcarations, i.e. just include types & consts

 Greg: 03/08/99
}

{Note:
 we use a strange combination of 'standard SQL' definitions
 and 'Microsoft ODBC' stub function declarations.
 Hopefully this will give us an ODBC driver that doesn't break the standards - to
 aid this, we $define ODBC for those bits that relate to non-standard portions.

 There are some incompatibilities and we currently use either the standard
 or the ODBC version if ODBC_ONLY is defined...

 This DLL will always be an ODBC driver: be practical! i.e. we're following the ODBC 3.5 docs.
}


//todo tidy unused comments and definitions...

(* FROM ocelot sqlcli.h
   //todo compare with ODBC SDK SQL.h!
/*
C header file for SQL/CLI, from the CD-ROM in Gulutzan + Pelzer's SQL book

All 32-bit C applications which use the standard CLI should include this thus:
#include "sqlcli.h"
All 16-bit C applications which use the standard CLI should include this thus:
#include "sqlcli16.h"

Original:	May 1998
Last modified:	March 1999
By:		Ocelot Computer Services Inc.
Copyright:	None. All values are derived from the SQL standard document,
		and are therefore uncopyrightable. However, as documentation,
		you should leave this initial comment paragraph in place.

Some of the definitions are adjusted to take Microsoft Windows into account.

Some of the definitions are adjusted to take Microsoft ODBC into account, but
if you want all the ODBC extensions you will need to include sql.h + sqlext.h
from the Microsoft ODBC package, instead of this file.

*/

#ifndef __SQL
#define __SQL

/* **** Start: common Windows (not standard) declarations ****
   The declarations in this section are not described in the ANSI standard
   document; nor should they be, since they affect C compilers in Microsoft
   Windows environments, mainly. There are a few differences from ODBC's
   header files too: (a) if it's not WIN32 then we go with "#define SQL_API
   PASCAL FAR", which is what ODBC used to do up until ODBC 2.0 for 16-bit;
   (b) for any names which are neither standard nor ODBC, we have used the
   prefix OCELOT_.
*/
*)
{ Remove the following line if you want pure standard SQL. Defining
   ODBC allows ODBC 2.x prototypes, implementation-defined
   constants, and archaic spellings or conventions. }
{$define ODBC} //Note: this must also be defined (or not) in other units that don't include this file!

(*
/* In sqlcli.h, if WIN32 is undefined, we assume it is defined. In sqlcli16.h,
   if WIN32 is undefined, we assume it is undefined. This is the principal
   difference between sqlcli.h and sqlcli16.h. WIN32 is appropriate for 32-bit
   (Windows 95 / Windows NT) programs and is usually explicit, e.g. Microsoft
   C compilations begin with "cl -DWIN32=1 ...". */
#ifndef WIN32
#define OCELOT_WIN32_DEFINE 1
#define WIN32 1
#endif

/* The Ocelot 32-bit library is like ODBC 3.x; the Ocelot 16-bit library is
   like ODBC 2.x. */
#ifdef WIN32
#define ODBCVER 0x0300
#else
#define	ODBCVER	0x0250
#endif
*)

{Since Delphi's pre-compiler only supports simple ifdef conditions (until Kylix),
 we need the following definitions to simulate version-conditional compilation
 Note: I don't think we can handle nested ifdef..endif's -check/workaround!
}
{#define ODBCVER 0x350 implies the following:}
  {$define ODBCVER_GTEQ_0350}
  {$define ODBCVER_GTEQ_0300}
  {$define ODBCVER_GTEQ_0250}
  //not used:{$define ODBCVER_GTEQ_0201}
{and negates the following:}
  {$undef ODBCVER_LTEQ_0300}
  {$undef ODBCVER_LT_0300}


(*
#ifndef FAR
#define OCELOT_FAR_DEFINE 1
#ifdef WIN32
#define FAR
#else
#define FAR far
#endif
#endif

#ifndef PASCAL
#define OCELOT_PASCAL_DEFINE 1
#define PASCAL pascal
#endif

#ifndef EXPORT
#define EXPORT
#endif

#ifdef WIN32
#define SQL_API  __stdcall
#else
/* In ODBC 3, if 16-bit, the reading here is "#define SQL_API EXPORT CALLBACK"
   but in ODBC 2 it is "#define SQL_API PASCAL FAR", and we'll follow that. */
#define SQL_API PASCAL FAR
#endif
*)
{ HWND is relevant only for ODBC; remove for standard SQL }
type
HWND=integer;

(*
#ifndef FALSE
#define OCELOT_FALSE_DEFINE 1
#define FALSE 0
#endif

#ifndef TRUE
#define OCELOT_TRUE_DEFINE 1
#define TRUE 1
#endif

#ifndef BOOL
#define OCELOT_BOOL_DEFINE 1
typedef int BOOL;
#endif

/* **** End:  common Windows (not standard) declarations **** */

/* In older SQL/CLI versions the types were SDWORD (signed dword) etc.; in the
   newer SQL/CLI versions the types are SQLINTEGER etc. These typedefs are
   supposed to reflect the closest C equivalents to the SQL data type of the
   same name. The old types are deprecated but we allow for compatibility. */
*)
//todo Greg: remove UDWORD, SDWORD, UCHAR etc. in favour of SQLUINTEGER, SQLINTEGER, SQLCHAR etc.
//           also replace RETCODE with SQLRETURN, PTR with SQLPOINTER etc.
//           see SQLTYPES.H below...

//todo remove type
SQLCHAR=char; //todo remove: unsigned char;
pSQLCHAR=pchar; //todo remove? ^SQLCHAR;      //todo ==pchar?
{$ifdef ODBC}
//todo remove UCHAR=byte;
UCHAR=char;
//todo reinstate:worked above & more portable?  //todo remove pUCHAR=^UCHAR;
pUCHAR=pchar;
SCHAR=shortint;  //todo maybe should be char?
{$endif}

SQLINTEGER=longint;
pSQLINTEGER=^SQLINTEGER;
SQLSMALLINT=smallint;
pSQLSMALLINT=^SQLSMALLINT;

{  The standard differs from ODBC when it comes to the definitions of some
   parameters, this affects function prototypes but it's not a big deal.
   With the standard: SQLUSMALLINT and SQLUINTEGER are "signed" (in fact, the
   standard's suggested sqlcli.h simply uses SQLSMALLINT and SQLINTEGER here).
   With ODBC: SQLUSMALLINT and SQLUINTEGER are "unsigned". At the moment we
   follow ODBC i.e. ODBC but hope this anomaly gets resolved. }
{$ifdef ODBC}
SDWORD=longint;
pSDWORD=^SDWORD;
ulongint=cardinal; //todo ok? longint;
UDWORD=ulongint;
pUDWORD=^UDWORD;
SQLUINTEGER=ulongint;
pSQLUINTEGER=^SQLUINTEGER;
SWORD=smallint;
pSWORD=^SWORD;
UWORD=word;
pUWORD=^UWORD;
SQLUSMALLINT=word;
pSQLUSMALLINT=^SQLUSMALLINT;
{$else} //todo duplicate pointer types added above
SDWORD=longint;
UDWORD=longint;
SQLUINTEGER=longint;
SWORD=smallint;
UWORD=smallint;
SQLUSMALLINT=smallint;
{$endif}
SQLDOUBLE=double;
(*
#ifdef ODBC
typedef double          SDOUBLE;
typedef long double     LDOUBLE;
#endif
typedef float           SQLREAL;
*)
SQLPOINTER=pointer;  //typedef void FAR *
pSQLPOINTER=^SQLPOINTER;
{$ifdef ODBC}
PTR=pointer; //typedef void FAR *      
{$endif}
(*
SQLDATE=TsqlDate;
SQLTIME=TsqlTime;
SQLTIMESTAMP=TsqlTimestamp;
typedef unsigned char   SQLINTERVAL;
typedef unsigned char   SQLDECIMAL;
typedef unsigned char   SQLNUMERIC;
typedef unsigned char   SQLBLOB;			/* SQL3 */
typedef long            SQLBLOB_LOCATOR;		/* SQL3 */
typedef unsigned char   SQLCLOB;			/* SQL3 */
typedef long            SQLCLOB_LOCATOR;		/* SQL3 */
typedef long            SQLUDT_LOCATOR;			/* SQL3 */
/* typedef long		SQLRESULT_SET_LOCATOR; */	/* coming in SQL4 */

/* The function return type was SQLINTEGER (32-bit signed dword) for ODBC 2.
   In ODBC 3 and in the standard SQL/CLI it is SQLSMALLINT (16-bit signed
   word). Actually the Ocelot libraries always return a 32-bit register value
   (EAX) for a 32-bit call, a 16-bit register value (AX) for a 16-bit call. */
*)
SQLRETURN=SQLSMALLINT;
{$ifdef ODBC}
RETCODE=SQLRETURN;
{$endif}
(*
*)
{ For all resource handles -- SQLHENV SQLHDBC SQLHSTMT SQLHDESC -- there is a
   significant incompatibility between ODBC and standard SQL/CLI. For ODBC,
   these handles are all "typedef void*". For the standard, these handles are
   all "SQLINTEGER". We go with the standard. Ocelot uses -1 as a constant for
   "universal handle" -- and -1 is obviously no pointer -- which is useful for
   trivial application programs that don't use SQLAllocHandle etc. }
SQLHANDLE=SQLINTEGER;   //universal handle: Greg 15/07/99
pSQLHANDLE=^SQLHANDLE;
SQLHENV=SQLINTEGER;	// handle of an env

{$ifdef ODBC}
HENV=SQLHENV;				// old name, deprecated
{$endif}
SQLHDBC=SQLINTEGER;	// handle of a dbc
{$ifdef ODBC}
HDBC=SQLHDBC;				// old name, deprecated
pHDBC=^HDBC; //for HDBC *
{$endif}
SQLHSTMT=SQLINTEGER;	// handle of a stmt
{$ifdef ODBC}
HSTMT=SQLHSTMT;				// old name, deprecated
{$endif}
SQLHDESC=SQLINTEGER;	// handle of a desc

const
(*
/* Values which may be returned in *Indicator or *StrLen */
*)
SQL_NULL_DATA                              =-1;
SQL_DATA_AT_EXEC                           =-2;

{ Values which may be returned in sqlreturn i.e. API function return value }
SQL_SUCCESS                                 =0;
SQL_SUCCESS_WITH_INFO                       =1;
{$ifdef ODBC}
SQL_STILL_EXECUTING                         =2;
{$endif}
SQL_NEED_DATA                              =99;
SQL_NO_DATA                                =100;
{$ifdef ODBC}
SQL_NO_DATA_FOUND                          =SQL_NO_DATA;	// old name, deprecated
{$endif}
SQL_ERROR                                  =-1;
SQL_INVALID_HANDLE                         =-2;
(*

/* Following macro is for testing whether a return was "either OK or warning".
   It's used frequently, but we prefer to ask "if (return code >= 0) ...". */
#define SQL_SUCCEEDED(rc) (((rc)&(~1))==0)
*)
{ Specials for string sizes. NTS stands for Null-Terminated String. }
SQL_NTS                                    =-3;
(*
#define SQL_NTSL                                  -3L
#ifdef ODBC
/* A "1-byte size + contents string", as in Borland Pascal.  This is not ODBC
   but should not conflict; if you want pure ODBC with your Pascal programs,
   you should use only long strings in your parameters. */
#define SQL_NTS_BYTE		-3003/* "1-byte size + contents string" */
#endif

/* The actual value of "maximum message length" should be implementation
   defined. In fact, Ocelot can return bigger messages, but 512 is the maximum
   in ODBC's .h file. */
#define SQL_MAXIMUM_MESSAGE_LENGTH                512
#ifdef ODBC
#define SQL_MAX_MESSAGE_LENGTH SQL_MAXIMUM_MESSAGE_LENGTH
#endif
*)
{ We use resource-handle numbers in SQLAllocHandle. }
SQL_HANDLE_ENV                              =1;
SQL_HANDLE_DBC                              =2;
SQL_HANDLE_STMT                             =3;
SQL_HANDLE_DESC                             =4;
{ ATTR stands for "attribute"; following are used in SQLSQLGetEnvAttribute,
   SetSetStmtAttribute, etc. }
SQL_ATTR_OUTPUT_NTS                     =10001;	// env attr
(*
#define SQL_ATTR_AUTO_IPD                       10001	/* dbc attr */
*)
SQL_ATTR_APP_ROW_DESC                   =10010;	// stmt attr: ARD
SQL_ATTR_APP_PARAM_DESC                 =10011;	// stmt attr: APD
SQL_ATTR_IMP_ROW_DESC                   =10012;	// stmt attr: IRD
SQL_ATTR_IMP_PARAM_DESC                 =10013;	// stmt attr: IPD
SQL_ATTR_CURSOR_SCROLLABLE              =   -1;	// stmt attr
SQL_ATTR_CURSOR_SENSITIVITY             =   -2;	// stmt attr
SQL_ATTR_CURSOR_HOLDABLE                =   -3;	// stmt attr (SQL3)
SQL_ATTR_METADATA_ID                    =10014;	// stmt attr

{$ifdef ODBC}
SQL_ATTR_READONLY          =0;
SQL_ATTR_WRITE             =1;
SQL_ATTR_READWRITE_UNKNOWN =2;
{$endif}
{$ifdef ODBC}
(*
#define SQLSTATE_SIZE	    5      //Greg - used version in SQLext
#define SQL_MAX_DSN_LENGTH 32
#define SQL_TYPE_MIN   1
*)
SQL_TYPE_NULL  =0;
(*
#define SQL_TYPE_MAX  12
*)
{$endif}
(*
#ifdef ODBC
#define SQL_COLUMN_COUNT            0
#define SQL_COLUMN_NAME             1
*)
SQL_COLUMN_TYPE             =2;
SQL_COLUMN_LENGTH           =3;  //Greg: needed for V2
SQL_COLUMN_PRECISION        =4;  //Greg: needed for V2
SQL_COLUMN_SCALE            =5;  //Greg: needed for V2
SQL_COLUMN_DISPLAY_SIZE     =6;
(*
#define SQL_COLUMN_NULLABLE         7
*)
SQL_COLUMN_UNSIGNED         =8;
SQL_COLUMN_MONEY            =9;
SQL_COLUMN_UPDATABLE       =10;
SQL_COLUMN_AUTO_INCREMENT  =11;
SQL_COLUMN_CASE_SENSITIVE  =12;
SQL_COLUMN_SEARCHABLE      =13;
SQL_COLUMN_TYPE_NAME       =14;
(*
#define SQL_UNSEARCHABLE           0
#define SQL_LIKE_ONLY              1
#define SQL_ALL_EXCEPT_LIKE        2
#define SQL_SEARCHABLE             3
#endif

#ifdef ODBC
/* Following are from an old version of an Ocelot DBMS; all are deprecated. */
/* SQLSetConnectOption label            =       default value */
/* #define SQL_OPT_SQLCODE_SIZE 1200 */ /*	2: indicators are 16-bit */
#define SQL_OPT_SELECT_ROWCOUNT		1201 /*	SQLRowCount ret=0 if SELECT */
#define SQL_OPT_DATE_SEPARATOR_CHAR	1202 /*	"/" */
#define SQL_OPT_DATE_ORDER		1203 /*	MONTH_DAY_YEAR */
#define SQL_OPT_DATE_MONTHSIZE		1204 /*	2 */
#define SQL_OPT_DATE_YEARSIZE		1205 /*	4 */
#define SQL_OPT_TIME_SEPARATOR_CHAR	1206 /*	":" */
#define SQL_OPT_TIME_INCLUDES		1207 /*	SECONDS_INCLUDED */
#define SQL_OPT_COMMIT_FLAGS		1208 /*	0 */
#define SQL_OPT_DBMS_FREE_PUT		1209 /*	0 */
#define SQL_OPT_DBMS_FIELD_DELIMITER	1211 /*	"," */
#define SQL_OPT_DBMS_QUOTE_DELIMITER	1212 /*	0x22 i.e. " */
#define SQL_OPT_DBMS_FILE_DELIMITER	1213 /*	0x26 i.e. control-Z */
#define SQL_OPT_DBMS_DELAY		1214 /*	0 */
#endif

/* Following are from SQL proposals, noted here for documentary purposes.
#define SQL_ATTR_LOB_LOC_POTENTIAL_UPDATABILITY 10020
#define SQL_ATTRLOB_LOC_SENSITIVITY             10025
#define SQL_ATTR_LOB_LOC_HOLDABILITY            10026
#define SQL_ATTR_LOB_LOC_PRODUCTION             10021
#define SQL_ATTR_LOB_LOC_UPDATABILITY           10022
#define SQL_ATTR_LOB_LOC_SOURCE_TABLE           10023
#define SQL_ATTR_LOB_LOC_SOURCE_COLUMN          10024
#define SQL_ATTR_LINK_TO_RS                     10020
#define SQL_LOB_LOC_DIRECT                          1
#define SQL_LOB_LOC_INDIRECT_SUBSTRING              2
#define SQL_LOB_LOC_INDIRECT_SIMPLE                 3
#define SQL_LOB_LOC_INDIRECT_COMPLEX                9
#define SQL_LOB_LOC_NOT_UPDATABLE                   0
#define SQL_LOB_LOC_UPDATABLE                       1
#define SQL_LOB_LOC_INSENSITIVE                     1
#define SQL_LOB_LOC_SENSITIVE                       2
#define SQL_LOB_LOC_NOT_HOLDABLE                    0
#define SQL_LOB_LOC_HOLDABLE                        1
*/
*)
{ IDA field identifiers }
SQL_DESC_COUNT                           =1001;
SQL_DESC_TYPE                            =1002;
SQL_DESC_LENGTH                          =1003;
SQL_DESC_OCTET_LENGTH_POINTER            =1004;
SQL_DESC_PRECISION                       =1005;
SQL_DESC_SCALE                           =1006;
SQL_DESC_DATETIME_INTERVAL_CODE          =1007;
SQL_DESC_NULLABLE                        =1008;
SQL_DESC_INDICATOR_POINTER               =1009;
SQL_DESC_DATA_POINTER                    =1010;
SQL_DESC_NAME                            =1011;
SQL_DESC_UNNAMED                         =1012;
SQL_DESC_OCTET_LENGTH                    =1013;
SQL_DESC_DATETIME_INTERVAL_PRECISION     =1014; //Note: (Greg) this is 26 in the Standard (SQLBindParameter still works for both since call is internal)
(*
#define SQL_DESC_COLLATION_CATALOG               1015
#define SQL_DESC_COLLATION_SCHEMA                1016
#define SQL_DESC_COLLATION_NAME                  1017
#define SQL_DESC_CHARACTER_SET_CATALOG           1018
#define SQL_DESC_CHARACTER_SET_SCHEMA            1019
#define SQL_DESC_CHARACTER_SET_NAME              1020
#define SQL_DESC_PARAMETER_MODE                  1021
#define SQL_DESC_PARAMETER_ORDINAL_POSITION      1022
#define SQL_DESC_PARAMETER_SPECIFIC_CATALOG      1023
#define SQL_DESC_PARAMETER_SPECIFIC_SCHEMA       1024
#define SQL_DESC_PARAMETER_SPECIFIC_NAME         1025
#define SQL_DESC_UDT_CATALOG                     1026
#define SQL_DESC_UDT_SCHEMA                      1027
#define SQL_DESC_UDT_NAME                        1028
#define SQL_DESC_KEY_TYPE                        1029	/* ANSI SQL3 only */
#define SQL_DESC_KEY_MEMBER                      1030	/* ANSI SQL3 only */
#define SQL_DESC_DYNAMIC_FUNCTION                1031	/* ANSI SQL3 only */
#define SQL_DESC_DYNAMIC_FUNCTION_CODE           1032	/* ANSI SQL3 only */
*)
SQL_DESC_ALLOC_TYPE                      =1099;
(*
/* Following are from SQL proposals, noted here for documentary purposes.
   #define SQL_DESC_ACTIVE                          1050
   #define SQL_DESC_PROCEDURE_CATALOG               1051
   #define SQL_DESC_PROCEDURE_SCHEMA                1052
   #define SQL_DESC_PROCEDURE_NAME                  1053
   #define SQL_DESC_PROCEDURE_SPECIFIC              1054
   #define SQL_DESC_RESULT_SET_LOCATOR              1055
   #define SQL_DESC_RESULT_SET_NAME                 1056
   #define SQL_DESC_RESULT_SET_SIZE                 1057
   #define SQL_DESC_RESULT_SET_STRUCTURED           1058
   #define SQL_DESC_RESULT_SET_ORDER_COLUMNS        1059
   #define SQL_DESC_RESULT_SET_ORDER_DIRECTION      1060
*/
*)

{ Identifiers of fields returned for SQLGetDiagField / SQLGetDiagRec. }
SQL_DIAG_RETURNCODE                         =1;
SQL_DIAG_NUMBER                             =2;
SQL_DIAG_ROW_COUNT                          =3;
SQL_DIAG_SQLSTATE                           =4;
SQL_DIAG_NATIVE                             =5;
SQL_DIAG_MESSAGE_TEXT                       =6;
SQL_DIAG_DYNAMIC_FUNCTION                   =7;
SQL_DIAG_CLASS_ORIGIN                       =8;
SQL_DIAG_SUBCLASS_ORIGIN                    =9;
SQL_DIAG_CONNECTION_NAME                   =10;
SQL_DIAG_SERVER_NAME                       =11;
SQL_DIAG_DYNAMIC_FUNCTION_CODE             =12;
SQL_DIAG_MORE                              =13;
SQL_DIAG_CONDITION_NUMBER                  =14;
SQL_DIAG_CONSTRAINT_CATALOG                =15;
SQL_DIAG_CONSTRAINT_SCHEMA                 =16;
SQL_DIAG_CONSTRAINT_NAME                   =17;
SQL_DIAG_CATALOG_NAME                      =18;
SQL_DIAG_SCHEMA_NAME                       =19;
SQL_DIAG_TABLE_NAME                        =20;
SQL_DIAG_COLUMN_NAME                       =21;
SQL_DIAG_CURSOR_NAME                       =22;
SQL_DIAG_MESSAGE_LENGTH                    =23;
SQL_DIAG_MESSAGE_OCTET_LENGTH              =24;
SQL_DIAG_CONDITION_NAME                    =25;
SQL_DIAG_PARAMETER_NAME                    =26;	// ANSI SQL3 only
SQL_DIAG_ROUTINE_CATALOG                   =27;	// ANSI SQL3 only
SQL_DIAG_ROUTINE_SCHEMA                    =28;	// ANSI SQL3 only
SQL_DIAG_ROUTINE_NAME                      =29;	// ANSI SQL3 only
SQL_DIAG_SPECIFIC_NAME                     =30;	// ANSI SQL3 only
SQL_DIAG_TRIGGER_CATALOG                   =31;	// ANSI SQL3 only
SQL_DIAG_TRIGGER_SCHEMA                    =32;	// ANSI SQL3 only
SQL_DIAG_TRIGGER_NAME                      =33;	// ANSI SQL3 only
SQL_DIAG_TRANSACTIONS_COMMITTED            =34;	// ANSI SQL3 only
SQL_DIAG_TRANSACTIONS_ROLLED_BACK          =35;	// ANSI SQL3 only
SQL_DIAG_TRANSACTION_ACTIVE                =36;	// ANSI SQL3 only 

// Codes of various SQL_DIAG_... fields.
SQL_DIAG_ALTER_DOMAIN                       =3;
SQL_DIAG_ALTER_TABLE                        =4;
SQL_DIAG_CALL                               =7;
SQL_DIAG_CREATE_ASSERTION                   =6;
SQL_DIAG_CREATE_CHARACTER_SET               =8;
SQL_DIAG_CREATE_COLLATION                  =10;
SQL_DIAG_CREATE_DOMAIN                     =23;
SQL_DIAG_CREATE_ROW_TYPE                   =17;
SQL_DIAG_CREATE_SCHEMA                     =64;
SQL_DIAG_CREATE_TABLE                      =77;
SQL_DIAG_CREATE_TRANSLATION                =79;
SQL_DIAG_CREATE_VIEW                       =84;
SQL_DIAG_DELETE_WHERE                      =19;
SQL_DIAG_DROP_ASSERTION                    =24;
SQL_DIAG_DROP_CHARACTER_SET                =25;
SQL_DIAG_DROP_COLLATION                    =26;
SQL_DIAG_DROP_DOMAIN                       =27;
SQL_DIAG_DROP_SCHEMA                       =31;
SQL_DIAG_DROP_TABLE                        =32;
SQL_DIAG_DROP_TRANSLATION                  =33;
SQL_DIAG_DROP_VIEW                         =36;
SQL_DIAG_DYNAMIC_DELETE_CURSOR             =54;
SQL_DIAG_DYNAMIC_UPDATE_CURSOR             =55;
{ Following are from SQL proposals, noted here for documentary purposes.
SQL_DIAG_DYNAMIC_UPDATE_LOCATED            =92;
SQL_DIAG_FREE_LOCATOR                      =85;
}
SQL_DIAG_GRANT                             =48;
SQL_DIAG_INSERT                            =50;
SQL_DIAG_REVOKE                            =59;
SQL_DIAG_SELECT                            =41;
SQL_DIAG_SELECT_CURSOR                     =85;
SQL_DIAG_SET_CATALOG                       =66;
SQL_DIAG_SET_CONSTRAINT                    =68;
SQL_DIAG_SET_NAMES                         =72;
SQL_DIAG_SET_SCHEMA                        =74;
SQL_DIAG_SET_SESSION_AUTHORIZATION         =76;
SQL_DIAG_SET_TIME_ZONE                     =71;
SQL_DIAG_SET_TRANSACTION                   =75;
SQL_DIAG_UNKNOWN_STATEMENT                 = 0;
SQL_DIAG_UPDATE_WHERE                      =82;

{ Codes for SQL data types. Some warnings about ODBC incompatibilities:
   (a) SQL_BIT is 14 i.e. the standard SQL/CLI number, not the ODBC number;
   (b) the SQL3 data types are of course not in ODBC. Ocelot's implementation
   does not actually do anything with the "SQL3" or "ODBC" specific types. }
SQL_CHAR                                    =1;
SQL_NUMERIC                                 =2;
SQL_DECIMAL                                 =3;
SQL_INTEGER                                 =4;
SQL_SMALLINT                                =5;
SQL_FLOAT                                   =6;
SQL_REAL                                    =7;
SQL_DOUBLE                                  =8;
SQL_DATETIME                                =9;
SQL_INTERVAL                               =10;
SQL_VARCHAR                                =12;
(*
//we won't expose our standard server BIT types until ODBC knows how to handle them:
SQL_BIT                                    =14;	// NOT ODBC NUMBER!
*)
//SQL_BIT_VARYING                            =15; //we expose this because the server exposes it
(*
#define SQL_UDT                                    17	/* SQL3 */
*)
SQL_UDT_LOCATOR                            =18;	// SQL3
(*
#define SQL_ROW_TYPE                               19	/* SQL3 */
*)
SQL_REF                                    =20;	// SQL3
SQL_BLOB                                   =30;	// SQL3
SQL_BLOB_LOCATOR                           =31;	// SQL3
SQL_CLOB                                   =40;	// SQL3
SQL_CLOB_LOCATOR                           =41;	// SQL3
{$ifdef ODBC}
{Needed for C data types - Greg}
(*todo ODBC 3 uses 90,91,92 instead!
SQL_DATE            =9;
SQL_TIME           =10;
SQL_TIMESTAMP      =11;
*)
SQL_LONGVARCHAR    =-1;				// ODBC
SQL_BINARY         =-2;				// ODBC
SQL_VARBINARY      =-3;				// ODBC
SQL_LONGVARBINARY  =-4;				// ODBC
SQL_BIGINT         =-5;				// ODBC
SQL_TINYINT        =-6;				// ODBC
SQL_BIT            =-7;			        // ODBC  //Greg: conflicts with the standard SQL_BIT

{ Mapping C data type to SQL data types -- ..._C_... indicates C. }
{ We have to support all of these to comply with the ODBC standard - Greg}
SQL_C_CHAR    =SQL_CHAR;
SQL_C_LONG    =SQL_INTEGER;
SQL_C_SHORT   =SQL_SMALLINT;
SQL_C_FLOAT   =SQL_REAL;
SQL_C_DOUBLE  =SQL_DOUBLE;

(* replaced with SQL_C_TYPE_... in ODBC 3
SQL_C_DATE         =SQL_DATE;
SQL_C_TIME         =SQL_TIME;
SQL_C_TIMESTAMP    =SQL_TIMESTAMP;
*)
SQL_C_BINARY       =SQL_BINARY;
SQL_C_BIT          =SQL_BIT; //Greg: note: we don't use standard SQL_BIT here...
SQL_C_TINYINT      =SQL_TINYINT;
{ For SQLBindCol() / SQLBindParameter() }    //moved here: Greg
SQL_DEFAULT                                =99;
SQL_C_DEFAULT =SQL_DEFAULT;
{$endif}

(*
/* Following are from SQL proposals, noted here for documentary purposes.
#define SQL_RESULT_SET                             50
#define SQL_RESULT_SET_LOCATOR                     51
*/
*)
{ Concise codes for temporals. }
SQL_TYPE_DATE                              =91;
SQL_TYPE_TIME                              =92;
SQL_TYPE_TIMESTAMP                         =93;
SQL_TYPE_TIME_WITH_TIMEZONE                =94;
SQL_TYPE_TIMESTAMP_WITH_TIMEZONE           =95;
SQL_INTERVAL_YEAR                         =101;
SQL_INTERVAL_DAY                          =103;
SQL_INTERVAL_DAY_TO_HOUR                  =108;
SQL_INTERVAL_DAY_TO_MINUTE                =109;
SQL_INTERVAL_DAY_TO_SECOND                =110;
SQL_INTERVAL_HOUR                         =104;
SQL_INTERVAL_HOUR_TO_MINUTE               =111;
SQL_INTERVAL_HOUR_TO_SECOND               =112;
SQL_INTERVAL_MINUTE                       =105;
//max: SQL_INTERVAL_MINUTE_TO_SECOND             =113;
SQL_INTERVAL_SECOND                       =106;
//min: SQL_INTERVAL_YEAR                         =101;
SQL_INTERVAL_MONTH                        =102;
SQL_INTERVAL_YEAR_TO_MONTH                =107;
SQL_INTERVAL_MINUTE_TO_SECOND             =113;

{ For SQLGetTypeInfo, "all types" }
SQL_ALL_TYPES                               =0;

(*Greg moved before SQL_C_DEFAULT
{ For SQLBindCol() / SQLBindParameter() }
SQL_DEFAULT                                =99;
*)
(*
/* For SQLGetData() / SQLGetParamData() ... "get data type etc. from APD" */
#define SQL_APD_TYPE                              -99
#define SQL_ARD_TYPE                              -99
*)

{ subcode aka subtype aka datetime_interval_code }
SQL_CODE_DATE                               =1;
SQL_CODE_TIME                               =2;
SQL_CODE_TIMESTAMP                          =3;
(*
#define SQL_CODE_TIME_ZONE                          4
#define SQL_CODE_TIMESTAMP_ZONE                     5

/* codes corresponding to the qualifier of an INTERVAL data type */
#define SQL_DAY                                     3
#define SQL_DAY_TO_HOUR                             8
#define SQL_DAY_TO_MINUTE                           9
#define SQL_DAY_TO_SECOND                          10
#define SQL_HOUR                                    4
#define SQL_HOUR_TO_MINUTE                         11
#define SQL_HOUR_TO_SECOND                         12
#define SQL_MINUTE                                  5
#define SQL_MINUTE_TO_SECOND                       13
#define SQL_MONTH                                   2
#define SQL_SECOND                                  6
#define SQL_YEAR                                    1
#define SQL_YEAR_TO_MONTH                           7

*)
{ For attributes }
SQL_FALSE                                   =0;
SQL_TRUE                                    =1;
SQL_NONSCROLLABLE                           =0;
SQL_SCROLLABLE                              =1;
SQL_NONHOLDABLE                             =0;	// ANSI SQL3
SQL_HOLDABLE                                =1;	// ANSI SQL3

{ For SQLBindParameter }
SQL_PARAM_MODE_IN                           =1;
SQL_PARAM_MODE_OUT                          =4;
SQL_PARAM_MODE_INOUT                        =2;

{ For SQLFetchScroll }
SQL_FETCH_NEXT                              =1;
SQL_FETCH_FIRST                             =2;
SQL_FETCH_LAST                              =3;
SQL_FETCH_PRIOR                             =4;
{$ifdef ODBC}
SQL_FETCH_PREV=SQL_FETCH_PRIOR;			// deprecated
{$endif}
SQL_FETCH_ABSOLUTE                          =5;
SQL_FETCH_RELATIVE                          =6;
{$ifdef ODBC}
SQL_FETCH_RESUME                            =7;
{$endif}

{ Between "#define SQL_ROW_SUCCESS" and "#define SQL_ENTIRE_ROWSET" are not
   specified by the standard SQL/CLI, but these are the reasonable and obvious
   names -- we think. }

SQL_ROW_SUCCESS     =0;
(*
#define SQL_ROW_DELETED     1
#define SQL_ROW_UPDATED     2
*)
SQL_ROW_NOROW       =3;

(*
#define SQL_CASCADE         0
#define SQL_RESTRICT        1
#define SQL_SET_NULL        2
*)

(* see ODBC values below: fuller list
SQL_PARAM_TYPE_UNKNOWN  =0;
SQL_PARAM_INPUT         =1;	{ equivalent of SQL_PARAM_MODE_IN }
SQL_PARAM_INPUT_OUTPUT  =2;
SQL_RESULT_COL          =3;
*)

SQL_CONCUR_READ_ONLY    =1;
SQL_CONCUR_LOCK         =2;
SQL_CONCUR_TIMESTAMP    =3;
SQL_CONCUR_VALUES       =4;

(*
#define SQL_SCROLL_FORWARD_ONLY      0
#define SQL_SCROLL_KEYSET_DRIVEN    -1
#define SQL_SCROLL_DYNAMIC          -2

#define SQL_INDEX_UNIQUE    0
#define SQL_INDEX_ALL       1
#define SQL_ENSURE          1
#define SQL_QUICK           0

#define SQL_TABLE_STAT      0
*)
SQL_INDEX_CLUSTERED =1; //todo debug only
(*
#define SQL_INDEX_HASHED    2
*)
SQL_INDEX_OTHER     =3;

(*
#define SQL_ENTIRE_ROWSET      0
*)
{ For SQLColumns, SQLDescribeCol, etc. }
SQL_NO_NULLS                                =0;
SQL_NULLABLE                                =1;
{$ifdef ODBC}
SQL_NULLABLE_UNKNOWN =2;
{$endif}

(*
#ifdef ODBC
/* The standard SQL/CLI doesn't support ODBC's "temporal struct" definitions,
   the correct thing to do is pass dates to/from "char" variables. But ... */
typedef struct tagDATE_STRUCT
  {
  SWORD year;
  UWORD month;
  UWORD day;
  } DATE_STRUCT;
typedef struct tagTIME_STRUCT
  {
  UWORD hour;
  UWORD minute;
  UWORD second;
  } TIME_STRUCT;
typedef struct tagTIMESTAMP_STRUCT
  {
  SWORD year;
  UWORD month;
  UWORD day;
  UWORD hour;
  UWORD minute;
  UWORD second;
  UDWORD fraction;
  } TIMESTAMP_STRUCT;
#endif
*)
{ For SQLGetTypeInfo etc. }
(*
#define SQL_PRED_NONE                               0
#define SQL_PRED_CHAR                               1
#define SQL_PRED_BASIC                              2
#define SQL_NAMED                                   0
#define SQL_UNNAMED                                 1
*)
SQL_DESC_ALLOC_AUTO                         =1;
SQL_DESC_ALLOC_USER                         =2;
SQL_COMMIT                                  =0;
SQL_ROLLBACK                                =1;
SQL_CLOSE                                   =0;
SQL_DROP                                    =1;
SQL_UNBIND                                  =2;
SQL_RESET_PARAMS                            =3;
(*
#define SQL_REALLOCATE                              4
#define SQL_NULL_HENV                               0
#define SQL_NULL_HDBC                               0
#define SQL_NULL_HSTMT                              0
#define SQL_NULL_HDESC                              0
*)

{For SQLGetFunctions

 Note:Greg: todo: these should all be defined, but we're only defining them as we declare them so we can keep track
 Also, we use these values to enabled the marshalling/unmarshalling of parameters
 - so we 'reserve' some special ones for handshaking etc.
 todo these should probably go in another file, but it's easier to keep them distinct if they're together
}
SQL_API_handshake                        =9999; 
SQL_API_exception                        =9998;
(*
#define SQL_API_SQLALLOCCONNECT                     1
#define SQL_API_SQLALLOCENV                         2
*)
SQL_API_SQLALLOCHANDLE                   =1001;
(*
#define SQL_API_SQLALLOCSTMT                        3
*)
SQL_API_SQLBINDCOL                          =4;
SQL_API_SQLBINDPARAMETER                   =72;
SQL_API_SQLCANCEL                           =5;
SQL_API_SQLCLOSECURSOR                   =1003;
SQL_API_SQLCOLATTRIBUTE                     =6;
SQL_API_SQLCOLUMNPRIVILEGES                =56;
SQL_API_SQLCONNECT                          =7;
(*
#define SQL_API_SQLCOPYDESC                      1004
#define SQL_API_SQLDATASOURCES                     57
*)
SQL_API_SQLDESCRIBECOL                      =8;
(*
/* #define SQL_API_SQLDESCRIBELOCATOR               1030 */	/* SQL4 */
*)
SQL_API_SQLDISCONNECT                       =9;
SQL_API_SQLENDTRAN                       =1005;
SQL_API_SQLERROR                           =10;
SQL_API_SQLEXECDIRECT                      =11;
SQL_API_SQLEXECUTE                         =12;
SQL_API_SQLFETCH                           =13;
SQL_API_SQLFETCHSCROLL                   =1021;
SQL_API_SQLFOREIGNKEYS                     =60;
(*
#define SQL_API_SQLFREECONNECT                     14
#define SQL_API_SQLFREEENV                         15
*)
SQL_API_SQLFREEHANDLE                    =1006;
(*
/* #define SQL_API_SQLFREELOCATOR                   1031 */	/* SQL4 */
*)
SQL_API_SQLFREESTMT                        =16;
SQL_API_SQLGETCONNECTATTR                =1007;
SQL_API_SQLGETCURSORNAME                   =17;
SQL_API_SQLGETDATA                         =43;
SQL_API_SQLGETDESCFIELD                  =1008;
(*
#define SQL_API_SQLGETDESCREC                    1009
*)
SQL_API_SQLGETDIAGFIELD                  =1010;
SQL_API_SQLGETDIAGREC                    =1011;
SQL_API_SQLGETENVATTR                    =1012;
SQL_API_SQLGETFUNCTIONS                    =44;
SQL_API_SQLGETINFO                         =45;
(*
#define SQL_API_SQLGETLENGTH                     1022
#define SQL_API_SQLGETPARAMDATA                  1025
#define SQL_API_SQLGETPOSITION                   1023
*)
SQL_API_SQLGETSTMTATTR                   =1014;
(*
#define SQL_API_SQLGETSUBSTRING                  1024
*)
SQL_API_SQLGETTYPEINFO                     =47;
(*
/* #define SQL_API_SQLLINKRESULTSET                 1027 */	/* SQL4 */
/* #define SQL_API_SQLLOCATEDUPDATE                 1032 */	/* SQL4 */
*)
//
SQL_API_SQLMORERESULTS                     =61; //debug ADO
SQL_API_SQLNUMRESULTCOLS                   =18;
SQL_API_SQLPARAMDATA                       =48;
(*
#define SQL_API_SQLPARAMETERS                    2002
*)
SQL_API_SQLPREPARE                         =19;
SQL_API_SQLPRIMARYKEYS                     =65;
SQL_API_SQLPUTDATA                         =49;
(*
/* #define SQL_API_SQLRESULTSETSTRUCTURE            1028 */	/* SQL4 */
#define SQL_API_SQLROUTINEPRIVILEGES             1026
#define SQL_API_SQLROUTINES                      2003
*)
SQL_API_SQLROWCOUNT                        =20;

SQL_API_SQLSETCONNECTATTR                =1016;
SQL_API_SQLSETCURSORNAME                   =21;
SQL_API_SQLSETDESCFIELD                  =1017;
(*
#define SQL_API_SQLSETDESCREC                    1018
*)
SQL_API_SQLSETENVATTR                    =1019;
(*
/* #define SQL_API_SQLSETLOCATORATTR                1033 */	/* SQL4 */
*)
SQL_API_SQLSETSTMTATTR                   =1020;
SQL_API_SQLSPECIALCOLUMNS                  =52;
SQL_API_SQLTABLEPRIVILEGES                 =70;
(*
/* Following 3 are missing in some implementations */
*)
SQL_API_SQLCOLUMNS          =40;
SQL_API_SQLSTATISTICS       =53;
SQL_API_SQLTABLES           =54;

(*
#ifdef ODBC
/* Following are old (ODBC 2), deprecated, or in ODBC 3 but not in standard */
#define SQL_API_SQLCOLATTRIBUTES     6
#define SQL_API_SQLSETPARAM         22
#define SQL_API_SQLTRANSACT         23
#define SQL_NUM_FUNCTIONS           23
#define SQL_EXT_API_START           40
SQL_API_SQLDRIVERCONNECT    =41;
#define SQL_API_SQLGETCONNECTOPTION 42
#define SQL_API_SQLGETSTMTOPTION    46
#define SQL_API_SQLSETCONNECTOPTION 50
#define SQL_API_SQLSETSTMTOPTION    51
*)
SQL_API_SQLBROWSECONNECT    =55; 
//
SQL_API_SQLDESCRIBEPARAM    =58; //debug ADO
//
SQL_API_SQLEXTENDEDFETCH    =59; //debug ADO - remove!
//
SQL_API_SQLNATIVESQL        =62;  //debug ADO
SQL_API_SQLNUMPARAMS        =63;
(*
#define SQL_API_SQLPARAMOPTIONS     64
*)
SQL_API_SQLPROCEDURECOLUMNS =66;
SQL_API_SQLPROCEDURES       =67;
//
SQL_API_SQLSETPOS           =68; //debug ADO
(*
#define SQL_API_SQLSETSCROLLOPTIONS 69
#define SQL_EXT_API_LAST            70
#define SQL_NUM_EXTENSIONS (SQL_EXT_API_LAST-SQL_EXT_API_START+1)
/* #define SQL_API_SQLDRIVERS	    71 */
#endif
*)

{ For SQLGetInfo }
SQL_MAXIMUM_DRIVER_CONNECTIONS              =0;
SQL_MAXIMUM_CONCURRENT_ACTIVITIES           =1;
SQL_DATA_SOURCE_NAME                        =2;
SQL_FETCH_DIRECTION                         =8;
SQL_SERVER_NAME                            =13;
SQL_SEARCH_PATTERN_ESCAPE                  =14;
SQL_DBMS_NAME                              =17;  //Greg: was missing
SQL_DBMS_VERSION                           =18;
SQL_ACCESSIBLE_TABLES                      =19;
SQL_CURSOR_COMMIT_BEHAVIOR                 =23;
SQL_ACCESSIBLE_ROUTINES                    =24;  //Greg: overridden by SQL_CURSOR_ROLLBACK_BEHAVIOR
SQL_DATA_SOURCE_READ_ONLY                  =25;
SQL_DEFAULT_TRANSACTION_ISOLATION          =26;
SQL_IDENTIFIER_CASE                        =28;
SQL_MAXIMUM_COLUMN_NAME_LENGTH             =30;
SQL_MAXIMUM_CURSOR_NAME_LENGTH             =31;
SQL_MAXIMUM_SCHEMA_NAME_LENGTH             =32;
SQL_MAXIMUM_CATALOG_NAME_LENGTH            =34;
SQL_MAXIMUM_TABLE_NAME_LENGTH              =35;
SQL_SCROLL_CONCURRENCY                     =43;
SQL_TRANSACTION_CAPABLE                    =46;
SQL_USER_NAME                              =47;
SQL_TRANSACTION_ISOLATION_OPTION           =72;
SQL_INTEGRITY                              =73;
SQL_GETDATA_EXTENSIONS                     =81;
SQL_NULL_COLLATION                         =85;
SQL_ALTER_TABLE                            =86;
SQL_ORDER_BY_COLUMNS_IN_SELECT             =90;
SQL_SPECIAL_CHARACTERS                     =94;
SQL_MAXIMUM_COLUMNS_IN_GROUP_BY            =97;
SQL_MAXIMUM_COLUMNS_IN_INDEX               =98; //14/05/00 Greg: added: assumed number by position! Needed by Borland clients!
                                           SQL_MAX_COLUMNS_IN_INDEX               =SQL_MAXIMUM_COLUMNS_IN_INDEX; //Greg
SQL_MAXIMUM_COLUMNS_IN_ORDER_BY            =99;
SQL_MAXIMUM_COLUMNS_IN_SELECT             =100;
SQL_MAXIMUM_COLUMNS_IN_TABLE              =101;
SQL_MAX_INDEX_SIZE                         =102; //28/01/01 Greg: added
SQL_MAX_STATEMENT_LEN                      =105; //28/01/01 Greg: added
//todo Greg removed - clashes with SQL_GETPARAMDATA_EXTENSIONS! SQL_MAXIMUM_STMT_OCTETS                 =20000;
SQL_MAXIMUM_STMT_OCTETS_DATA            =20001;
SQL_MAXIMUM_STMT_OCTETS_SCHEMA          =20002;
SQL_MAXIMUM_TABLES_IN_SELECT              =106;
SQL_MAXIMUM_USER_NAME_LENGTH              =107;
SQL_OUTER_JOIN_CAPABILITIES               =115;
SQL_CURSOR_SENSITIVITY                  =10001;
SQL_DESCRIBE_PARAMETER                  =10002;
SQL_CATALOG_NAME                        =10003;
SQL_COLLATING_SEQUENCE                  =10004;
SQL_MAXIMUM_IDENTIFIER_LENGTH           =10005;
SQL_REF_LENGTH                          =20003;
SQL_GETPARAMDATA_EXTENSIONS             =20000;
// #define SQL_LOB_LOCATOR                         10050 */	/* SQL4 */
// #define SQL_LOB_LOCATOR_PERSISTENCE             10051 */	/* SQL4 */
// #define SQL_LOB_LOCATOR_SENSITIVITY             10052 */	/* SQL4 */
// #define SQL_LOB_LOCATOR_UPDATABILITY            10053 */	/* SQL4 */

(*
#ifdef ODBC
#undef  SQL_TYPE_MIN
#define SQL_TYPE_MIN      -7
#define SQL_ALL_TYPES      0
#define SQL_MODE_READ_WRITE     0
#define SQL_MODE_READ_ONLY      1
#define SQL_DRIVER_NOPROMPT           0
#define SQL_DRIVER_COMPLETE           1
#define SQL_DRIVER_PROMPT             2
#define SQL_DRIVER_COMPLETE_REQUIRED  3
#define SQL_NO_TOTAL           -4
#endif

#ifdef ODBC
#define SQL_INFO_FIRST                       0
#define SQL_ACTIVE_CONNECTIONS               SQL_MAXIMUM_DRIVER_CONNECTIONS
#define SQL_ACTIVE_STATEMENTS                SQL_MAXIMUM_CONCURRENT_ACTIVITIES
#define SQL_DRIVER_HDBC                      3
#define SQL_DRIVER_HENV                      4
#define SQL_DRIVER_HSTMT                     5
*)
SQL_DRIVER_NAME                      =6;
SQL_DRIVER_VER                       =7;
SQL_ODBC_API_CONFORMANCE             =9;
//DM only SQL_ODBC_VER                        =10;
SQL_ROW_UPDATES                     =11;
SQL_ODBC_SAG_CLI_CONFORMANCE        =12;
SQL_ODBC_SQL_CONFORMANCE            =15;
SQL_DATABASE_NAME                   =16;
//SQL_DBMS_NAME                       =17;    //Greg: seems to be part of standard - moved above
SQL_DBMS_VER                        =SQL_DBMS_VERSION;
SQL_ACCESSIBLE_PROCEDURES           =20;
SQL_PROCEDURES                      =21;
SQL_CONCAT_NULL_BEHAVIOR            =22;
SQL_EXPRESSIONS_IN_ORDERBY          =27;
SQL_IDENTIFIER_QUOTE_CHAR           =29;
SQL_MAX_COLUMN_NAME_LEN             =SQL_MAXIMUM_COLUMN_NAME_LENGTH;
SQL_MAX_CURSOR_NAME_LEN             =SQL_MAXIMUM_CURSOR_NAME_LENGTH;
SQL_MAX_OWNER_NAME_LEN              =SQL_MAXIMUM_SCHEMA_NAME_LENGTH;
SQL_MAX_PROCEDURE_NAME_LEN          =33;
SQL_MAX_QUALIFIER_NAME_LEN          =SQL_MAXIMUM_CATALOG_NAME_LENGTH;
SQL_MAX_TABLE_NAME_LEN              =SQL_MAXIMUM_TABLE_NAME_LENGTH;
SQL_MULT_RESULT_SETS                =36;
SQL_MULTIPLE_ACTIVE_TXN             =37;
SQL_OUTER_JOINS                     =38;
SQL_OWNER_TERM                      =39;
SQL_PROCEDURE_TERM                  =40;
SQL_QUALIFIER_NAME_SEPARATOR        =41;
SQL_QUALIFIER_TERM                  =42;
SQL_SCROLL_OPTIONS                  =44;
SQL_TABLE_TERM                      =45;
SQL_TXN_CAPABLE                     =SQL_TRANSACTION_CAPABLE;
SQL_CONVERT_FUNCTIONS               =48;
SQL_NUMERIC_FUNCTIONS               =49;
SQL_STRING_FUNCTIONS                =50;
SQL_SYSTEM_FUNCTIONS                =51;
SQL_TIMEDATE_FUNCTIONS              =52;
(*
#define SQL_CONVERT_BIGINT                  53
#define SQL_CONVERT_BINARY                  54
#define SQL_CONVERT_BIT                     55
#define SQL_CONVERT_CHAR                    56
#define SQL_CONVERT_DATE                    57
#define SQL_CONVERT_DECIMAL                 58
#define SQL_CONVERT_DOUBLE                  59
#define SQL_CONVERT_FLOAT                   60
#define SQL_CONVERT_INTEGER                 61
#define SQL_CONVERT_LONGVARCHAR             62
#define SQL_CONVERT_NUMERIC                 63
#define SQL_CONVERT_REAL                    64
#define SQL_CONVERT_SMALLINT                65
#define SQL_CONVERT_TIME                    66
#define SQL_CONVERT_TIMESTAMP               67
#define SQL_CONVERT_TINYINT                 68
#define SQL_CONVERT_VARBINARY               69
#define SQL_CONVERT_VARCHAR                 70
#define SQL_CONVERT_LONGVARBINARY           71
*)
SQL_TXN_ISOLATION_OPTION            =SQL_TRANSACTION_ISOLATION_OPTION;
(*
#define SQL_ODBC_SQL_OPT_IEF                SQL_INTEGRITY
#define SQL_INFO_LAST                       73
#define SQL_INFO_DRIVER_START               1000
#endif
*)
{ Statement attribute values for cursor sensitivity }
{ ______________________________________________________________
   ANSI Only-SQL3
   ______________________________________________________________
   #define SQL_ASENSITIVE                    0x00000000L
   ______________________________________________________________ }
{ ISO Only-SQL3
   ______________________________________________________________}

SQL_UNSPECIFIED                   =$00000000; //0x00000000L
{   ______________________________________________________________ }
SQL_INSENSITIVE                   =$00000001; //0x00000001L
SQL_SENSITIVE                     =$00000002; //0x00000002L
{ ______________________________________________________________
   ANSI Only-SQL3
   ______________________________________________________________
   / Define SQL_UNSPECIFIED for backwards compatibiltiy        /
   #define SQL_UNSPECIFIED                SQL_ASENSITIVE
   ______________________________________________________________ }
(*
/* null handle used when allocating HENV                     */
#define SQL_NULL_HANDLE                            0L
*)
{ SQL_ALTER_TABLE bitmasks }
SQL_AT_ADD_COLUMN                 =$00000001; //0x00000001L
SQL_AT_DROP_COLUMN                =$00000002; //0x00000002L
SQL_AT_ALTER_COLUMN               =$00000004; //0x00000004L
SQL_AT_ADD_CONSTRAINT             =$00000008; //0x00000008L
SQL_AT_DROP_CONSTRAINT            =$00000010; //0x00000010L
{ SQL_CURSOR_COMMIT_BEHAVIOR values }
SQL_CB_DELETE                               =0;
SQL_CB_CLOSE                                =1;
SQL_CB_PRESERVE                             =2;
{ SQL_FETCH_DIRECTION bitmasks }
SQL_FD_FETCH_NEXT                 =$00000001; //0x00000001L
SQL_FD_FETCH_FIRST                =$00000002; //0x00000002L
SQL_FD_FETCH_LAST                 =$00000004; //0x00000004L
SQL_FD_FETCH_PRIOR                =$00000008; //0x00000008L
SQL_FD_FETCH_ABSOLUTE             =$00000010; //0x00000010L
SQL_FD_FETCH_RELATIVE             =$00000020; //0x00000020L
{$ifdef ODBC}
SQL_FD_FETCH_RESUME               =$00000040; //0x00000040L
{$endif}

{ SQL_GETDATA_EXTENSIONS bitmasks }
SQL_GD_ANY_COLUMN                 =$00000001; //0x00000001L
SQL_GD_ANY_ORDER                  =$00000002; //0x00000002L
{ SQL_GETPARAMDATA_EXTENSIONS bitmasks }
SQL_GPD_ANY_PARAMETER             =$00000001; //0x00000001L
SQL_GPD_ANY_ORDER                 =$00000002; //0x00000002L
{ SQL_IDENTIFIER_CASE values }
SQL_IC_UPPER                                =1;
SQL_IC_LOWER                                =2;
SQL_IC_SENSITIVE                            =3;
SQL_IC_MIXED                                =4;
(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________  
   / SQL_LOB_LOCATOR bitmasks                                 /
   #define SQL_LL_DATA_TYPES                0x00000001L
   #define SQL_LL_SQL                       0x00000002L
   / SQL_LOB_LOCATOR_PERSISTENCE bitmasks                     /
   #define SQL_LLP_HOLDABLE                 0x00000001L
   #define SQL_LLP_FREEABLE                 0x00000002L
   / SQL_LOB_LOCATOR_SENSITIVITY bitmasks                     /
   #define SQL_LLS_INSENSITIVE              0x00000001L
   #define SQL_LLS_SENSITIVE                0x00000002L
   / SQL_LOB_LOCATOR_UPDATABILITY bitmasks                    /
   #define SQL_LLU_DIRECT                   0x00000001L
   #define SQL_LLU_INDIRECT_SUBSTRING       0x00000002L
   #define SQL_LLU_INDIRECT_SIMPLE          0x00000004L
    ______________________________________________________________ */
*)
{ SQL_NULL_COLLATION values }
SQL_NC_HIGH                                 =1;
SQL_NC_LOW                                  =2;
{ SQL_OUTER_JOIN_CAPABILITIES bitmasks }
SQL_OUTER_JOIN_LEFT               =$00000001; //0x00000001L
SQL_OUTER_JOIN_RIGHT              =$00000002; //0x00000002L
SQL_OUTER_JOIN_FULL               =$00000004; //0x00000004L
SQL_OUTER_JOIN_NESTED             =$00000008; //0x00000008L
SQL_OUTER_JOIN_NOT_ORDERED        =$00000010; //0x00000010L
SQL_OUTER_JOIN_INNER              =$00000020; //0x00000020L
SQL_OUTER_JOIN_ALL_COMPARISON_OPS =$00000040; //0x00000040L
{ SQL_SCROLL_CONCURRENCY bitmasks }
SQL_SCCO_READ_ONLY                =$00000001; //0x00000001L
SQL_SCCO_LOCK                     =$00000002; //0x00000002L
SQL_SCCO_OPT_ROWVER               =$00000004; //0x00000004L
{$ifdef ODBC}
SQL_SCCO_OPT_TIMESTAMP            =SQL_SCCO_OPT_ROWVER;
{$endif}
SQL_SCCO_OPT_VALUES               =$00000008; //0x00000008L

{ SQL_TRANSACTION_CAPABLE values }
SQL_TC_NONE                                 =0;
SQL_TC_DML                                  =1;
SQL_TC_ALL                                  =2;
SQL_TC_DDL_COMMIT                           =3;
SQL_TC_DDL_IGNORE                           =4;
{ SQL_TRANSACTION_ISOLATION bitmasks }
SQL_TRANSACTION_READ_UNCOMMITTED  =$00000001; //0x00000001L
SQL_TRANSACTION_READ_COMMITTED    =$00000002; //0x00000002L
SQL_TRANSACTION_REPEATABLE_READ   =$00000004; //0x00000004L
SQL_TRANSACTION_SERIALIZABLE      =$00000008; //0x00000008L
{$ifdef ODBC}
SQL_TXN_READ_UNCOMMITTED          =SQL_TRANSACTION_READ_UNCOMMITTED;
SQL_TXN_READ_COMMITTED            =SQL_TRANSACTION_READ_COMMITTED;
SQL_TXN_REPEATABLE_READ           =SQL_TRANSACTION_REPEATABLE_READ;
SQL_TXN_SERIALIZABLE              =SQL_TRANSACTION_SERIALIZABLE;
SQL_TXN_VERSIONING                =$00000010; //0x00000010L
{$endif}
{ Column types and scopes in SpecialColumns }
SQL_BEST_ROWID                             =1;
SQL_SCOPE_CURROW                           =0;
SQL_SCOPE_TRANSACTION                      =1;
SQL_SCOPE_SESSION                          =2;
SQL_PC_UNKNOWN                             =0;
SQL_PC_NOT_PSEUDO                          =1;
SQL_PC_PSEUDO                              =2;

{$ifdef ODBC}
SQL_ROWVER     =2;
{$endif}

{ Foreign Key UPDATE and DELETE rules }
SQL_CASCADE                                =0;
SQL_RESTRICT                               =1;
SQL_SET_NULL                               =2;
SQL_NO_ACTION                              =3;
SQL_SET_DEFAULT                            =4;

{ Special parameter values }
SQL_ALL_CATALOGS                          ='%';
SQL_ALL_SCHEMAS                           ='%';
SQL_ALL_TABLE_TYPES                       ='%';
//todo remove: SQL_ALL_TABLE_TYPES                       ='''TABLE'',''VIEW''';

//Greg- constants:
SQL_ALL_TABLES                            ='%';
SQL_ALL_COLUMNS                           ='%';


(*
#if ODBC

#define SQL_CVT_CHAR                        0x00000001L
#define SQL_CVT_NUMERIC                     0x00000002L
#define SQL_CVT_DECIMAL                     0x00000004L
#define SQL_CVT_INTEGER                     0x00000008L
#define SQL_CVT_SMALLINT                    0x00000010L
#define SQL_CVT_FLOAT                       0x00000020L
#define SQL_CVT_REAL                        0x00000040L
#define SQL_CVT_DOUBLE                      0x00000080L
#define SQL_CVT_VARCHAR                     0x00000100L
#define SQL_CVT_LONGVARCHAR                 0x00000200L
#define SQL_CVT_BINARY                      0x00000400L
#define SQL_CVT_VARBINARY                   0x00000800L
#define SQL_CVT_BIT                         0x00001000L
#define SQL_CVT_TINYINT                     0x00002000L
#define SQL_CVT_BIGINT                      0x00004000L
#define SQL_CVT_DATE                        0x00008000L
#define SQL_CVT_TIME                        0x00010000L
#define SQL_CVT_TIMESTAMP                   0x00020000L
#define SQL_CVT_LONGVARBINARY               0x00040000L

#define SQL_FN_CVT_CONVERT                  0x00000001L

#define SQL_FN_STR_CONCAT                   0x00000001L
#define SQL_FN_STR_INSERT                   0x00000002L
#define SQL_FN_STR_LEFT                     0x00000004L
#define SQL_FN_STR_LTRIM                    0x00000008L
#define SQL_FN_STR_LENGTH                   0x00000010L
#define SQL_FN_STR_LOCATE                   0x00000020L
#define SQL_FN_STR_LCASE                    0x00000040L
#define SQL_FN_STR_REPEAT                   0x00000080L
#define SQL_FN_STR_REPLACE                  0x00000100L
#define SQL_FN_STR_RIGHT                    0x00000200L
#define SQL_FN_STR_RTRIM                    0x00000400L
#define SQL_FN_STR_SUBSTRING                0x00000800L
#define SQL_FN_STR_UCASE                    0x00001000L
#define SQL_FN_STR_ASCII                    0x00002000L
#define SQL_FN_STR_CHAR                     0x00004000L

#define SQL_FN_NUM_ABS                      0x00000001L
#define SQL_FN_NUM_ACOS                     0x00000002L
#define SQL_FN_NUM_ASIN                     0x00000004L
#define SQL_FN_NUM_ATAN                     0x00000008L
#define SQL_FN_NUM_ATAN2                    0x00000010L
#define SQL_FN_NUM_CEILING                  0x00000020L
#define SQL_FN_NUM_COS                      0x00000040L
#define SQL_FN_NUM_COT                      0x00000080L
#define SQL_FN_NUM_EXP                      0x00000100L
#define SQL_FN_NUM_FLOOR                    0x00000200L
#define SQL_FN_NUM_LOG                      0x00000400L
#define SQL_FN_NUM_MOD                      0x00000800L
#define SQL_FN_NUM_SIGN                     0x00001000L
#define SQL_FN_NUM_SIN                      0x00002000L
#define SQL_FN_NUM_SQRT                     0x00004000L
#define SQL_FN_NUM_TAN                      0x00008000L
#define SQL_FN_NUM_PI                       0x00010000L
#define SQL_FN_NUM_RAND                     0x00020000L

#define SQL_FN_TD_NOW                       0x00000001L
#define SQL_FN_TD_CURDATE                   0x00000002L
#define SQL_FN_TD_DAYOFMONTH                0x00000004L
#define SQL_FN_TD_DAYOFWEEK                 0x00000008L
#define SQL_FN_TD_DAYOFYEAR                 0x00000010L
#define SQL_FN_TD_MONTH                     0x00000020L
#define SQL_FN_TD_QUARTER                   0x00000040L
#define SQL_FN_TD_WEEK                      0x00000080L
#define SQL_FN_TD_YEAR                      0x00000100L
#define SQL_FN_TD_CURTIME                   0x00000200L
#define SQL_FN_TD_HOUR                      0x00000400L
#define SQL_FN_TD_MINUTE                    0x00000800L
#define SQL_FN_TD_SECOND                    0x00001000L

#define SQL_FN_SYS_USERNAME                 0x00000001L
#define SQL_FN_SYS_DBNAME                   0x00000002L
#define SQL_FN_SYS_IFNULL                   0x00000004L
*)

SQL_SO_FORWARD_ONLY                 =$00000001; //0x00000001L
SQL_SO_KEYSET_DRIVEN                =$00000002; //0x00000002L
SQL_SO_DYNAMIC                      =$00000004; //0x00000004L
SQL_SO_MIXED                        =$00000008; //0x00000008L

SQL_QUERY_TIMEOUT       =0;
SQL_MAX_ROWS            =1;
SQL_NOSCAN              =2;
(*
#define SQL_MAX_LENGTH          3
#define SQL_ASYNC_ENABLE        4
*)
SQL_BIND_TYPE           =5;

SQL_BIND_BY_COLUMN      =0;    // Suboption for SQL_BIND_TYPE 

(*
#define SQL_ACCESS_MODE         101
*)
SQL_AUTOCOMMIT          =102;
SQL_LOGIN_TIMEOUT       =103;
SQL_OPT_TRACE           =104;
(*
#define SQL_OPT_TRACEFILE       105
#define SQL_TRANSLATE_DLL       106
#define SQL_TRANSLATE_OPTION    107
*)
SQL_TXN_ISOLATION       =108;
(*
#define SQL_CONNECT_OPT_DRVR_START  1000
#define SQL_FLUSHFILEBUFFERS	2001	/* Ocelot-specific option re COMMIT */

#endif

(* FROM ocelot sqlcli.h
/* Following #ifdef / #endif is not in the standard. */
#ifdef __cplusplus
extern "C" { 			/* Assume C declarations for C++   */
#endif  /* __cplusplus */

/*
*)
{$ifndef NO_FUNCTIONS}
{
FUNCTION PROTOTYPES
-------------------

There are some differences between what's below and what's in the book. We had
to make compromises to accommodate Windows 3.x, and to accommodate ODBC. The
differences should not affect typical application programs. The differences
are:
... The word SQL_API does not appear in the ANSI document for prototypes. In
    32-bit, SQL_API is "#define SQL_API" i.e. it does nothing at all. In
    16-bit, SQL_API is "#define SQL_API PASCAL FAR" i.e. it's necessary.
... The word FAR does not appear in the ANSI document for prototypes. In
    32-bit, FAR is "#define FAR" i.e. it does nothing at all. In
    16-bit, FAR is "#define FAR far" i.e. it's necessary.
... The words SQLUSMALLINT and SQLUINTEGER do not appear in the ANSI document
    for prototypes. In standard SQL/CLI, the types are SQLSMALLINT and
    SQLINTEGER i.e. they are signed. This is incompatible with ODBC, where the
    types are SQLUSMALLINT and SQLUINTEGER i.e. they are unsigned. We have
    chosen to use SQLUSMALLINT and SQLUINTEGER. This should make little
    difference in practice because the arguments involved are always small,
    certainly always less than 32767. Change the typedefs if you want to allow
    the somewhat looser standard prototyping. */
}
(*obsolete
{SQLRETURN SQL_API  SQLAllocConnect(SQLHENV EnvironmentHandle,
 SQLHDBC FAR *ConnectionHandle);}
function SQLAllocConnect  (EnvironmentHandle:HENV;
                   ConnectionHandle:pHDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
(*
SQLRETURN SQL_API  SQLAllocEnv(SQLHENV  FAR *EnvironmentHandle);
*)
{SQLRETURN SQL_API  SQLAllocHandle(SQLSMALLINT HandleType,
 SQLINTEGER InputHandle, SQLINTEGER  FAR *OutputHandle);}
function SQLAllocHandle  (HandleType:SQLSMALLINT;
		 InputHandle:SQLHANDLE;
		 OutputHandle:pSQLHANDLE):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLAllocStmt(SQLHDBC ConnectionHandle,
SQLHSTMT  FAR *StatementHandle);
*)
{SQLRETURN SQL_API  SQLBindCol(SQLHSTMT StatementHandle,
 SQLUSMALLINT ColumnNumber, SQLSMALLINT BufferType,
 SQLPOINTER Data, SQLINTEGER BufferLength,
 SQLINTEGER  FAR *StrLen_or_Ind);}
function SQLBindCol  (StatementHandle:SQLHSTMT;
			ColumnNumber:UWORD;
			BufferType:SQLSMALLINT; {Greg: some ODBC types are -ve! SWORD - I think this is a change from ODBC 2 to 3 = ok}
			Data:PTR;
			BufferLength:SDWORD;
			StrLen_or_Ind:{UNALIGNED}pSDWORD):RETCODE;
                        {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLBindParameter(SQLHSTMT StatementHandle,
 SQLUSMALLINT ParamNumber, SQLSMALLINT InputOutputMode,
 SQLSMALLINT ValueType, SQLSMALLINT ParameterType,
 SQLUINTEGER ColumnSize, SQLSMALLINT DecimalDigits,
 SQLPOINTER ParameterValue, SQLINTEGER BufferLength,
 SQLINTEGER  FAR *StrLen_or_Ind);}
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

{SQLRETURN SQL_API  SQLCancel(SQLHSTMT StatementHandle);}
function SQLCancel  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLCloseCursor(SQLHSTMT StatementHandle);}
function SQLCloseCursor  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}


{ The definition of SQLColAttribute in the standard SQL/CLI document is not
   compatible with ODBC; we assume that's an error and will be corrected. For
   the record, the standard SQL/CLI document -- at time of writing -- says:
 SQLRETURN SQL_API  SQLColAttribute (SQLHSTMT StatementHandle,
 	SQLUSMALLINT ColumnNumber, SQLUSMALLINT FieldIdentifier,
 	SQLCHAR  FAR *CharacterAttribute,
 	SQLINTEGER BufferLength,
 	SQLINTEGER  FAR *StringLength, SQLINTEGER  FAR *NumericAttribute);
}
{SQLRETURN  SQL_API SQLColAttribute (SQLHSTMT StatementHandle,
        SQLSMALLINT ColumnNumber, SQLSMALLINT FieldIdentifier,
        SQLPOINTER CharacterAttribute,
        SQLSMALLINT BufferLength,
        SQLSMALLINT FAR *StringLength, SQLPOINTER NumericAttribute);}
function SQLColAttribute  (StatementHandle:SQLHSTMT;
		 ColumnNumber:SQLUSMALLINT;
		 FieldIdentifier:SQLUSMALLINT;
		 CharacterAttribute:SQLPOINTER;
		 BufferLength:SQLSMALLINT;
		 StringLength:{UNALIGNED}pSQLSMALLINT;
		 NumericAttribute:SQLPOINTER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLColumnPrivileges(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *TableName, SQLSMALLINT NameLength3,
 SQLCHAR  FAR *ColumnName, SQLSMALLINT NameLength4 );}
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

{SQLRETURN SQL_API  SQLColumns(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *TableName, SQLSMALLINT NameLength3,
 SQLCHAR  FAR *ColumnName, SQLSMALLINT NameLength4 );}
function SQLColumns  (StatementHandle:HSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD;
		 ColumnName:pUCHAR;
		 NameLength4:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLConnect(SQLHDBC ConnectionHandle,
 SQLCHAR  FAR *ServerName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *UserName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *Authentication, SQLSMALLINT NameLength3);}
function SQLConnect  (ConnectionHandle:SQLHDBC;
		 ServerName:pUCHAR;
		 NameLength1:SWORD;
		 UserName:pUCHAR;
		 NameLength2:SWORD;
		 Authentication:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLCopyDesc(SQLHDESC SourceDescHandle,
SQLHDESC TargetDescHandle);
SQLRETURN SQL_API  SQLDataSources(SQLHENV EnvironmentHandle,
SQLUSMALLINT Direction, SQLCHAR  FAR *ServerName,
SQLSMALLINT BufferLength1, SQLSMALLINT  FAR *NameLength1,
SQLCHAR  FAR *Description, SQLSMALLINT BufferLength2,
SQLSMALLINT  FAR *NameLength2);
*)
{SQLRETURN SQL_API  SQLDescribeCol(SQLHSTMT StatementHandle,
 SQLUSMALLINT ColumnNumber, SQLCHAR  FAR *ColumnName,
 SQLSMALLINT BufferLength, SQLSMALLINT  FAR *NameLength,
 SQLSMALLINT  FAR *DataType, SQLUINTEGER  FAR *ColumnSize,
 SQLSMALLINT  FAR *DecimalDigits, SQLSMALLINT FAR *Nullable);}
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
(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________
   SQLRETURN  SQLDescribeLocator(SQLHSTMT DiagnosticStmtHandle,
   SQLSMALLINT LocatorType,
   SQLINTEGER Locator, SQLINTEGER Attribute,
   SQLPOINTER Value, SQLINTEGER BufferLength,
   SQLINTEGER  FAR *StringLength);
   ______________________________________________________________ */
*)
{SQLRETURN SQL_API  SQLDisconnect(SQLHDBC ConnectionHandle);}
function SQLDisconnect  (ConnectionHandle:SQLHDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLEndTran(SQLSMALLINT HandleType, SQLINTEGER Handle,
 SQLSMALLINT CompletionType);}
function SQLEndTran  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 CompletionType:SQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLError(SQLHENV EnvironmentHandle,
SQLHDBC ConnectionHandle, SQLHSTMT StatementHandle,
SQLCHAR  FAR *Sqlstate, SQLINTEGER  FAR *NativeError,
SQLCHAR  FAR *MessageText, SQLSMALLINT BufferLength,
SQLSMALLINT  FAR *TextLength);}
function SQLError  (EnvironmentHandle:SQLHENV;
                 ConnectionHandle:SQLHDBC;
		 StatementHandle:SQLHSTMT;
		 Sqlstate:pUCHAR;
		 NativeError:pSQLINTEGER;
		 MessageText:pUCHAR;
		 BufferLength:SQLSMALLINT;
		 TextLength:pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLExecDirect(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *StatementText, SQLINTEGER TextLength);}
function SQLExecDirect  (StatementHandle:HSTMT;
		 StatementText:pUCHAR;
		 TextLength:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLExecute(SQLHSTMT StatementHandle);}
function SQLExecute  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLFetch(SQLHSTMT StatementHandle);}
function SQLFetch  (StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLFetchScroll(SQLHSTMT StatementHandle,
 SQLSMALLINT FetchOrientation, SQLINTEGER FetchOffset);}
function SQLFetchScroll  (StatementHandle:SQLHSTMT;
		 FetchOrientation:SQLSMALLINT;
		 FetchOffset:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLForeignKeys(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *PKCatalogName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *PKSchemaName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *PKTableName, SQLSMALLINT NameLength3,
 SQLCHAR  FAR *FKCatalogName, SQLSMALLINT NameLength4,
 SQLCHAR  FAR *FKSchemaName, SQLSMALLINT NameLength5,
 SQLCHAR  FAR *FKTableName, SQLSMALLINT NameLength6);}
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

(*obsolete
{SQLRETURN SQL_API  SQLFreeConnect(SQLHDBC ConnectionHandle);}
function SQLFreeConnect  (ConnectionHandle:HDBC):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
(*
SQLRETURN SQL_API  SQLFreeEnv(SQLHENV EnvironmentHandle);
*)
{SQLRETURN SQL_API  SQLFreeHandle(SQLSMALLINT HandleType,
 SQLINTEGER Handle);}
function SQLFreeHandle  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________
   SQLRETURN  SQLFreeLocator(SQLHSTMT DiagnosticStmtHandle,
   SQLSMALLINT LocatorType, SQLPOINTER NewLocator);
   ______________________________________________________________ */
*)
{SQLRETURN SQL_API  SQLFreeStmt(SQLHSTMT StatementHandle, SQLUSMALLINT Option);}
function SQLFreeStmt  (StatementHandle:SQLHSTMT;
		 Option:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLGetConnectAttr(SQLHDBC ConnectionHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER BufferLength, SQLINTEGER  FAR *StringLength);}
function SQLGetConnectAttr  (ConnectionHandle:SQLHDBC;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLGetCursorName(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CursorName, SQLSMALLINT BufferLength,
 SQLSMALLINT  FAR *NameLength);}
function SQLGetCursorName  (StatementHandle:HSTMT;
		 CursorName:pUCHAR;
		 BufferLength:SWORD;
		 NameLength:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLGetData(SQLHSTMT StatementHandle,
 SQLUSMALLINT ColumnNumber, SQLSMALLINT TargetType,
 SQLPOINTER TargetValue, SQLINTEGER BufferLength,
 SQLINTEGER  FAR *StrLen_or_Ind);}
function SQLGetData  (StatementHandle:SQLHSTMT;
		 ColumnNumber:UWORD;
		 TargetType:SWORD;
		 TargetValue:PTR;
		 BufferLength:SDWORD;
		 StrLen_or_Ind:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLGetDescField(SQLHDESC DescriptorHandle,
 SQLSMALLINT RecordNumber, SQLSMALLINT FieldIdentifier,
 SQLPOINTER Value, SQLINTEGER BufferLength,
 SQLINTEGER  FAR *StringLength);}
function SQLGetDescField  (DescriptorHandle:SQLHDESC;
		 RecordNumber:SQLSMALLINT;
		 FieldIdentifier:SQLSMALLINT;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLGetDescRec(SQLHDESC DescriptorHandle,
SQLSMALLINT RecordNumber, SQLCHAR  FAR *Name,
SQLSMALLINT BufferLength, SQLSMALLINT  FAR *NameLength,
SQLSMALLINT  FAR *Type, SQLSMALLINT  FAR *SubType,
SQLINTEGER  FAR *Length, SQLSMALLINT  FAR *Precision,
SQLSMALLINT  FAR *Scale, SQLSMALLINT  FAR *Nullable);
*)
{SQLRETURN SQL_API  SQLGetDiagField(SQLSMALLINT HandleType,
 SQLINTEGER Handle, SQLSMALLINT RecordNumber,
 SQLSMALLINT DiagIdentifier, SQLPOINTER DiagInfo,
 SQLSMALLINT BufferLength, SQLSMALLINT  FAR *StringLength);}
function SQLGetDiagField  (HandleType:SQLSMALLINT;
		 Handle:SQLHANDLE;
		 RecordNumber:SQLSMALLINT;
		 DiagIdentifier:SQLSMALLINT;
		 DiagInfo:SQLPOINTER;
		 BufferLength:SQLSMALLINT;
		 StringLength:{UNALIGNED}pSQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLGetDiagRec(SQLSMALLINT HandleType, SQLINTEGER Handle,
 SQLSMALLINT RecordNumber, SQLCHAR  FAR *Sqlstate,
 SQLINTEGER  FAR *NativeError, SQLCHAR  FAR *MessageText,
 SQLSMALLINT BufferLength, SQLSMALLINT  FAR *TextLength);}
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

{SQLRETURN SQL_API  SQLGetEnvAttr(SQLHENV EnvironmentHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER BufferLength, SQLINTEGER  FAR *StringLength);}
function SQLGetEnvAttr  (EnvironmentHandle:SQLHENV;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{SQLRETURN SQL_API  SQLGetFunctions(SQLHDBC ConnectionHandle,
 SQLUSMALLINT FunctionId, SQLUSMALLINT  FAR *Supported);}
function SQLGetFunctions  (ConnectionHandle:SQLHDBC;
		 FunctionId:UWORD;
		 Supported:pUWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{/* The definition of SQLGetInfo in the standard SQL/CLI document is not
   compatible with ODBC; we assume that's an error and will be corrected.
   (In fact it's a long-standing error and was present in the official SQL-92
   document so our assumption is incompatible with the old version of the
   standard but some ISO committee members have acknowledge that this must be
   fixed. For the record, the standard SQL/CLI document -- at time of
   writing -- says:
 SQLRETURN SQL_API  SQLGetInfo(SQLHDBC ConnectionHandle,
            SQLUSMALLINT InfoType, SQLPOINTER InfoValue,
            SQLINTEGER BufferLength, SQLINTEGER  FAR *StringLength);
 */
 SQLRETURN SQL_API  SQLGetInfo(SQLHDBC ConnectionHandle,
           SQLUSMALLINT InfoType, SQLPOINTER InfoValue,
           SQLSMALLINT BufferLength, SQLSMALLINT FAR *StringLength);}
function SQLGetInfo  (ConnectionHandle:SQLHDBC;
		 InfoType:UWORD;
		 InfoValue:PTR;
		 BufferLength:SWORD;
		 StringLength:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLGetLength(SQLHSTMT StatementHandle,
SQLSMALLINT LocatorType, SQLINTEGER Locator,
SQLINTEGER  FAR *StringLength, SQLINTEGER  FAR *IndicatorValue);
SQLRETURN SQL_API  SQLGetParamData(SQLHSTMT StatementHandle,
SQLSMALLINT ParameterNumber, SQLSMALLINT TargetType,
SQLPOINTER TargetValue, SQLINTEGER BufferLength,
SQLINTEGER  FAR *StrLen_or_Ind);
SQLRETURN SQL_API SQLGetPosition(SQLHSTMT StatementHandle,
SQLSMALLINT LocatorType, SQLINTEGER SourceLocator,
SQLINTEGER SearchLocator, SQLCHAR  FAR *SearchLiteral,
SQLINTEGER SearchLiteralLength, SQLINTEGER FromPosition,
SQLINTEGER  FAR *LocatedAt, SQLINTEGER  FAR *IndicatorValue);
*)
{SQLRETURN SQL_API  SQLGetStmtAttr(SQLHSTMT StatementHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER BufferLength, SQLINTEGER  FAR *StringLength);}
function SQLGetStmtAttr  (StatementHandle:SQLHSTMT;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER;
		 StringLength:{UNALIGNED}pSQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLGetSubString(SQLHSTMT StatementHandle,
SQLSMALLINT LocatorType, SQLINTEGER SourceLocator,
SQLINTEGER FromPosition, SQLINTEGER ForLength,
SQLSMALLINT TargetType, SQLPOINTER TargetValue,
SQLINTEGER BufferLength, SQLINTEGER  FAR *StringLength,
SQLINTEGER  FAR *IndicatorValue);
*)
{SQLRETURN SQL_API  SQLGetTypeInfo(SQLHSTMT StatementHandle,
 SQLSMALLINT DataType);}
function SQLGetTypeInfo  (StatementHandle:HSTMT;
		 DataType:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________
   SQLRETURN SQLLinkResultSet(SQLHSTMT StatementHandle),
   SQLSMALLINT LocatorType, SQLINTEGER Locator);
   SQLRETURN  SQLLocatedUpdate(SQLHSTMT DiagnosticStmtHandle,
   SQLSMALLINT LocatorType, SQLINTEGER TargetLocator,
   SQLINTEGER InsertLocator, SQLCHAR  FAR *InserLiteral,
   SQLINTEGER InsertLiteralLength,
   SQLINTEGER FromPosition, SQLINTEGER RemoveLength,
   SQLINTEGER IndicatorValue);
   ______________________________________________________________ */
*)
(*
{SQLRETURN SQL_API  SQLMoreResults(SQLHSTMT StatementHandle);}
//debug ADO
function SQLMoreResults(StatementHandle:SQLHSTMT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
{SQLRETURN SQL_API  SQLNumResultCols(SQLHSTMT StatementHandle,
 SQLSMALLINT  FAR *ColumnCount);}
function SQLNumResultCols  (StatementHandle:SQLHSTMT;
		 ColumnCount:{UNALIGNED} pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{SQLRETURN SQL_API  SQLParamData(SQLHSTMT StatementHandle,
 SQLPOINTER  FAR *Value);}
function SQLParamData  (StatementHandle:SQLHSTMT;
		 Value:pSQLPOINTER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLParameters(SQLHSTMT StatementHandle,
SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
SQLCHAR  FAR *RoutineName, SQLSMALLINT NameLength3,
SQLCHAR  FAR *ParameterName, SQLSMALLINT NameLength4);
*)
{SQLRETURN SQL_API  SQLPrepare(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *StatementText, SQLINTEGER TextLength);}
function SQLPrepare  (StatementHandle:SQLHSTMT;
		 StatementText:pUCHAR;
		 TextLength:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLPrimaryKeys(SQLHSTMT StatementHandle,
SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
SQLCHAR  FAR *TableName, SQLSMALLINT NameLength3);}
function SQLPrimaryKeys  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
{SQLRETURN SQL_API  SQLPutData(SQLHSTMT StatementHandle,
 SQLPOINTER Data, SQLINTEGER StrLen_or_Ind);}
function SQLPutData  (StatementHandle:SQLHSTMT;
		 Data:SQLPOINTER;
		 StrLen_or_Ind:SDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________  
   SQLRETURN SQLResultSetStructure(SQLHSTMT StatementHandle),
   SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
   SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
   SQLCHAR  FAR *RoutineName, SQLSMALLINT NameLength3,
   SQLCHAR  FAR *ParameterName, SQLSMALLINT NameLength4);
   ______________________________________________________________ */
SQLRETURN SQL_API SQLRoutinePrivileges(SQLHSTMT StatementHandle,
SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
SQLCHAR  FAR *RoutineName, SQLSMALLINT NameLength3);
SQLRETURN SQL_API SQLRoutines(SQLHSTMT StatementHandle,
SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
SQLCHAR  FAR *RoutineName, SQLSMALLINT NameLength3,
SQLCHAR  FAR *RoutineType, SQLSMALLINT NameLength4);
*)
{SQLRETURN SQL_API  SQLRowCount(SQLHSTMT StatementHandle,
 SQLINTEGER  FAR *RowCount);}
function SQLRowCount  (StatementHandle:SQLHSTMT;
		 RowCount:{UNALIGNED}pSDWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLSetConnectAttr(SQLHDBC ConnectionHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER StringLength);}
function SQLSetConnectAttr  (ConnectionHandle:SQLHDBC;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLSetCursorName(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CursorName, SQLSMALLINT NameLength);}
function SQLSetCursorName  (StatementHandle:SQLHSTMT;
		 CursorName:pUCHAR;
		 NameLength:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLSetDescField(SQLHDESC DescriptorHandle,
 SQLSMALLINT RecordNumber, SQLSMALLINT FieldIdentifier,
 SQLPOINTER Value, SQLINTEGER BufferLength);}
function SQLSetDescField  (DescriptorHandle:SQLHDESC;
		 RecordNumber:SQLSMALLINT;
		 FieldIdentifier:SQLSMALLINT;
		 Value:SQLPOINTER;
		 BufferLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
SQLRETURN SQL_API  SQLSetDescRec(SQLHDESC DescriptorHandle,
SQLSMALLINT RecordNumber, SQLSMALLINT Type,
SQLSMALLINT SubType, SQLINTEGER Length,
SQLSMALLINT Precision, SQLSMALLINT Scale,
SQLPOINTER Data, SQLINTEGER  FAR *StringLength,
SQLINTEGER  FAR *Indicator);
*)
{SQLRETURN SQL_API  SQLSetEnvAttr(SQLHENV EnvironmentHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER StringLength);}
function SQLSetEnvAttr  (EnvironmentHandle:SQLHENV;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
(*
/* ______________________________________________________________
   SQL4 only (not SQL2 or SQL3)-ANSI and ISO
   ______________________________________________________________
   SQLRETURN  SQLSetLocatorAttr(SQLHSTMT DiagnosticStmtHandle,
   SQLSMALLINT LocatorType,
   SQLINTEGER Locator, SQLINTEGER Attribute,
   SQLPOINTER Value, SQLINTEGER StringLength);
   ______________________________________________________________  */
*)
{SQLRETURN SQL_API  SQLSetStmtAttr(SQLHSTMT StatementHandle,
 SQLINTEGER Attribute, SQLPOINTER Value,
 SQLINTEGER StringLength);}
function SQLSetStmtAttr  (StatementHandle:SQLHSTMT;
		 Attribute:SQLINTEGER;
		 Value:SQLPOINTER;
		 StringLength:SQLINTEGER):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API SQLSpecialColumns(SQLHSTMT StatementHandle,
 SQLUSMALLINT IdentifierType, SQLCHAR  FAR *CatalogName,
 SQLSMALLINT NameLength1, SQLCHAR  FAR *SchemaName,
 SQLSMALLINT NameLength2, SQLCHAR  FAR *TableName,
 SQLSMALLINT NameLength3, SQLUSMALLINT Scope,
 SQLUSMALLINT Nullable);}
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

{SQLRETURN SQL_API SQLTablePrivileges(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *TableName, SQLSMALLINT NameLength3);}
function SQLTablePrivileges  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 TableName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

{SQLRETURN SQL_API  SQLTables(SQLHSTMT StatementHandle,
 SQLCHAR  FAR *CatalogName, SQLSMALLINT NameLength1,
 SQLCHAR  FAR *SchemaName, SQLSMALLINT NameLength2,
 SQLCHAR  FAR *TableName, SQLSMALLINT NameLength3,
 SQLCHAR  FAR *TableType, SQLSMALLINT NameLength4 );}
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

(*
#ifdef ODBC
RETCODE  SQL_API SQLBindCol_Error(		/* not in ODBC or standard */
    HSTMT       hstmt,
    UWORD       icol,
    SWORD       fCType,
    PTR         rgbValue,
    SDWORD      cbValueMax,
    void    FAR *pcbValue);
RETCODE  SQL_API SQLBindDescriptor(		/* not in ODBC or standard */
    HSTMT	hstmt,
    PTR		sqlda,
    UWORD	sqldasize);
RETCODE  SQL_API SQLColAttributes(		/* ODBC 2.x, deprecated */
    HSTMT        hstmt,
    UWORD        icol,
    UWORD        fDescType,
    PTR          rgbDesc,
    SWORD	 cbDescMax,
    SWORD   FAR *pcbDesc,
    SDWORD  FAR *pfDesc);
RETCODE  SQL_API SQLDescribe(			/* not in ODBC or standard */
    HSTMT       hstmt,
    UCHAR   FAR *szSqlStr,
    SDWORD      cbSqlStr);
RETCODE  SQL_API SQLExecPseudocode(		/* not in ODBC or standard */
    HSTMT       hstmt,
    UCHAR  FAR *szSqlStr,
    SDWORD      cbSqlStr);
RETCODE  SQL_API SQLSetParam(			/* ODBC 1.0, deprecated */
    HSTMT       hstmt,
    UWORD       ipar,
    SWORD       fCType,
    SWORD       fSqlType,
    UDWORD      cbColDef,
    SWORD       ibScale,
    PTR         rgbValue,
    SDWORD  FAR *pcbValue);
RETCODE  SQL_API SQLTransact(			/* ODBC, deprecated */
    HENV        henv,
    HDBC        hdbc,
    UWORD       fType);
*)
{RETCODE  SQL_API SQLStatistics(			/* ODBC */
    HSTMT      hstmt,
    UCHAR  FAR *szTableQualifier,
    SWORD      cbTableQualifier,
    UCHAR  FAR *szTableOwner,
    SWORD      cbTableOwner,
    UCHAR  FAR *szTableName,
    SWORD      cbTableName,
    UWORD      fUnique,
    UWORD      fAccuracy);}
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

{RETCODE  SQL_API SQLDriverConnect(		/* ODBC */
    HDBC       hdbc,
    HWND       hwnd,
    UCHAR  FAR *szConnStrIn,
    SWORD      cbConnStrIn,
    UCHAR  FAR *szConnStrOut,
    SWORD      cbConnStrOutMax,
    SWORD  FAR *pcbConnStrOut,
    UWORD      fDriverCompletion);}
function SQLDriverConnect  (hdbc:HDBC;
		 hWnd:HWND;
		 szConnStrIn:pUCHAR;
		 cbConnStrIn:SWORD;
		 szConnStrOut:pUCHAR;
		 cbConnStrOut:SWORD;
		 pcbConnStrOut:{UNALIGNED}pSWORD;
		 fDriverCompletion:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
RETCODE  SQL_API SQLGetConnectOption(		/* ODBC 2, deprecated */
    HDBC       hdbc,
    UWORD      fOption,
    PTR        pvParam);
RETCODE  SQL_API SQLGetStmtOption(		/* ODBC 2, deprecated */
    HSTMT      hstmt,
    UWORD      fOption,
    PTR        pvParam);
RETCODE  SQL_API SQLSetConnectOption(		/* ODBC 2, deprecated */
    HDBC       hdbc,
    UWORD      fOption,
    UDWORD     vParam);
RETCODE  SQL_API SQLSetStmtOption(		/* ODBC 2, deprecated */
    HSTMT      hstmt,
    UWORD      fOption,
    UDWORD     vParam);
*)
{RETCODE  SQL_API SQLBrowseConnect(		/* ODBC */
    HDBC       hdbc,
    UCHAR  FAR *szConnStrIn,
    SWORD      cbConnStrIn,
    UCHAR  FAR *szConnStrOut,
    SWORD      cbConnStrOutMax,
    SWORD  FAR *pcbConnStrOut);}
function SQLBrowseConnect(hdbc:HDBC;
                          szConnStrIn:PUCHAR;
                          cbConnStrIn:SWORD;
                          szConnStrOut:PUCHAR;
                          cbConnStrOutMax:SWORD;
                          pcbConnStrOut:PSWORD):RETCODE;
                          {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
(*
{RETCODE  SQL_API SQLDescribeParam(		/* ODBC */
    HSTMT      hstmt,
    UWORD      ipar,
    SWORD  FAR *pfSqlType,
    UDWORD FAR *pcbColDef,
    SWORD  FAR *pibScale,
    SWORD  FAR *pfNullable);}
//debug ADO
function SQLDescribeParam(
    hstmt:HSTMT;
    ipar:UWORD;
    pfSqlType:PSWORD;
    pcbColDef:PUDWORD;
    pibScale:PSWORD;
    pfNullable:PSWORD):RETCODE;
                          {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
(*
{RETCODE  SQL_API SQLExtendedFetch(		/* ODBC */
    HSTMT      hstmt,
    UWORD      fFetchType,
    SDWORD     irow,
    UDWORD FAR *pcrow,
    UWORD  FAR *rgfRowStatus);}
//debug ADO
function SQLExtendedFetch(
    hstmt:HSTMT;
    fFetchType:UWORD;
    irow:SDWORD;
    pcrow:PUDWORD;
    rgfRowStatus:PUWORD):RETCODE;
                          {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
(*
{RETCODE  SQL_API SQLNativeSql(			/* ODBC */
    HDBC       hdbc,
    UCHAR  FAR *szSqlStrIn,
    SDWORD     cbSqlStrIn,
    UCHAR  FAR *szSqlStr,
    SDWORD     cbSqlStrMax,
    SDWORD FAR *pcbSqlStr);}
//debug ADO
function SQLNativeSql(
    hdbc:HDBC;
    szSqlStrIn:PUCHAR;
    cbSqlStrIn:SDWORD;
    szSqlStr:PUCHAR;
    cbSqlStrMax:SDWORD;
    pcbSqlStr:PSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
{RETCODE  SQL_API SQLNumParams(			/* ODBC */
    HSTMT      hstmt,
    SWORD  FAR *pcpar);}
function SQLNumParams  (hstmt:HSTMT;
		 pcpar:{UNALIGNED}pSWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
(*
RETCODE  SQL_API SQLParamOptions(		/* ODBC */
    HSTMT      hstmt,
    UDWORD     crow,
    UDWORD FAR *pirow);
*)
{RETCODE  SQL_API SQLProcedureColumns(		/* ODBC */
    HSTMT      hstmt,
    UCHAR  FAR *szProcQualifier,
    SWORD      cbProcQualifier,
    UCHAR  FAR *szProcOwner,
    SWORD      cbProcOwner,
    UCHAR  FAR *szProcName,
    SWORD      cbProcName,
    UCHAR  FAR *szColumnName,
    SWORD      cbColumnName);}
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

{RETCODE  SQL_API SQLProcedures(			/* ODBC */
    HSTMT      hstmt,
    UCHAR  FAR *szProcQualifier,
    SWORD      cbProcQualifier,
    UCHAR  FAR *szProcOwner,
    SWORD      cbProcOwner,
    UCHAR  FAR *szProcName,
    SWORD      cbProcName);}
function SQLProcedures  (StatementHandle:SQLHSTMT;
		 CatalogName:pUCHAR;
		 NameLength1:SWORD;
		 SchemaName:pUCHAR;
		 NameLength2:SWORD;
		 RoutineName:pUCHAR;
		 NameLength3:SWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

(*
{RETCODE  SQL_API SQLSetPos(			/* ODBC */
    HSTMT      hstmt,
    UWORD      irow,
    BOOL       fRefresh,
    BOOL       fLock);}
//debug ADO
function SQLSetPos  (hstmt:HSTMT;
		 irow:UWORD;fRefresh:UWORD;fLock:UWORD):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}

*)
(*
{SQLRETURN	SQL_API	SQLBulkOperations(
	SQLHSTMT			StatementHandle,
	SQLSMALLINT			Operation);}
//debug ADO
function 	SQLBulkOperations(
				StatementHandle:SQLHSTMT;
				Operation:SQLSMALLINT):RETCODE;
                 {$ifdef SQL_API} stdcall; {$endif} {$ifdef IMPORT} external ODBC_DLL; {$endif}
*)
(*
RETCODE  SQL_API SQLSetScrollOptions(		/* ODBC */
    HSTMT      hstmt,
    UWORD      fConcurrency,
    SDWORD     crowKeyset,
    UWORD      crowRowset);
#endif

/* Following #ifdef / #endif is not in the standard. */
#ifdef __cplusplus
}                                    /* End of extern "C" { */
#endif  /* __cplusplus */
*)
{$endif}
(*
/* End of standard stuff -- rest of file is Windows-related stuff */

#ifdef OCELOT_PASCAL_DEFINE
#undef PASCAL
#undef OCELOT_PASCAL_DEFINE
#endif

#ifdef OCELOT_FAR_DEFINE
#undef FAR
#undef OCELOT_FAR_DEFINE
#endif

#ifdef OCELOT_HWND_DEFINE
#undef HWND
#undef OCELOT_HWND_DEFINE
#endif

#ifdef OCELOT_TRUE_DEFINE
#undef TRUE
#undef OCELOT_TRUE_DEFINE
#endif

#ifdef OCELOT_FALSE_DEFINE
#undef FALSE
#undef OCELOT_FALSE_DEFINE
#endif

#ifdef OCELOT_BOOL_DEFINE
#undef BOOL
#undef OCELOT_BOOL_DEFINE
#endif

#ifdef OCELOT_WIN32_DEFINE
#undef WIN32
#undef OCELOT_WIN32_DEFINE
#endif

#endif	/* __SQL */
*)



//4 {$ifdef ODBC}
(* FROM ODBC SDK SQLEXT.h

//Note: these definitions are needed for Level 1/Level 2 ODBC features

/*****************************************************************
** SQLEXT.H - This is the include for applications using
**             the Microsoft SQL Extensions
**
** (C) Copyright 1990 - 1997 By Microsoft Corp.
**
**      Updated 05/12/93 for 2.00 specification
**      Updated 05/23/94 for 2.01 specification
**      Updated 10/27/94 for 2.10 specification
**      Updated 04/10/95 for 2.50 specification
**		Updated 07/25/95 for 3.00 specification
**		Updated 01/12/96 for 3.00 preliminary release
*********************************************************************/

#ifndef __SQLEXT
#define __SQLEXT

#ifndef __SQL
#include "sql.h"
#endif

#ifdef __cplusplus
extern "C" {                         /* Assume C declarations for C++ */
#endif  /* __cplusplus */

/* generally useful constants */
*)
const
(*moved to ODBC driver global:
SQL_SPEC_MAJOR     =2;     	// Major version of specification
//todo: too high?=ADO Delphi debug SQL_SPEC_MAJOR     =3;     	// Major version of specification

//todo: too high=MDAC NT 4 pack 3 = fail! SQL_SPEC_MINOR	   =50;     	// Minor version of specification
//todo: too high=MDAC NT 4 pack 3 = fail! SQL_SPEC_STRING   ='03.50';	// String constant for version  //todo add .0000
SQL_SPEC_MINOR	   =00;     	// Minor version of specification
SQL_SPEC_STRING   ='03.00';	// String constant for version  //todo add .0000
*)

SQL_SQLSTATE_SIZE	=5;	// size of SQLSTATE
(*
#define SQL_MAX_DSN_LENGTH	32	/* maximum data source name size */

#define SQL_MAX_OPTION_STRING_LENGTH    256

/* return code SQL_NO_DATA_FOUND is the same as SQL_NO_DATA */
{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_NO_DATA_FOUND	100
{$else} //#else
#define SQL_NO_DATA_FOUND	SQL_NO_DATA
{$endif} //#endif

/* an end handle type */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define	SQL_HANDLE_SENV		5
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
{ env attribute }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_ATTR_ODBC_VERSION				=200;
(*
#define SQL_ATTR_CONNECTION_POOLING			201
#define SQL_ATTR_CP_MATCH					202
*)
{$endif} //#endif  /* ODBCVER >= 0x0300 */
(*
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* values for SQL_ATTR_CONNECTION_POOLING */
#define SQL_CP_OFF							0UL
#define SQL_CP_ONE_PER_DRIVER				1UL
#define SQL_CP_ONE_PER_HENV					2UL
#define SQL_CP_DEFAULT						SQL_CP_OFF

/* values for SQL_ATTR_CP_MATCH */
#define SQL_CP_STRICT_MATCH					0UL
#define SQL_CP_RELAXED_MATCH				1UL
#define SQL_CP_MATCH_DEFAULT				SQL_CP_STRICT_MATCH
*)
{ values for SQL_ATTR_ODBC_VERSION }
SQL_OV_ODBC2						:longint=2{UL};
SQL_OV_ODBC3						:longint=3{UL};
(*
//4 {$endif} //#endif  /* ODBCVER >= 0x0300 */

/* connection attributes */
#define SQL_ACCESS_MODE                 101
#define SQL_AUTOCOMMIT                  102
#define SQL_LOGIN_TIMEOUT               103
#define SQL_OPT_TRACE                   104
#define SQL_OPT_TRACEFILE               105
#define SQL_TRANSLATE_DLL               106
#define SQL_TRANSLATE_OPTION            107
#define SQL_TXN_ISOLATION               108
*)
SQL_CURRENT_QUALIFIER           =109;
(*
SQL_ODBC_CURSORS                =110;
#define SQL_QUIET_MODE                  111
#define SQL_PACKET_SIZE                 112

/* connection attributes with new names */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_ATTR_ACCESS_MODE		SQL_ACCESS_MODE
*)
SQL_ATTR_AUTOCOMMIT			=SQL_AUTOCOMMIT;
(*
{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
*)
SQL_ATTR_CONNECTION_DEAD	=1209;	{ GetConnectAttr only }
(*
{$endif} //#endif /* ODBCVER >= 0x0350 */
#define SQL_ATTR_CONNECTION_TIMEOUT	113
*)
SQL_ATTR_CURRENT_CATALOG	=SQL_CURRENT_QUALIFIER;
(*
#define SQL_ATTR_DISCONNECT_BEHAVIOR	114
#define SQL_ATTR_ENLIST_IN_DTC		1207
#define SQL_ATTR_ENLIST_IN_XA		1208
*)
SQL_ATTR_LOGIN_TIMEOUT		=SQL_LOGIN_TIMEOUT;
(*
#define SQL_ATTR_ODBC_CURSORS		SQL_ODBC_CURSORS
#define SQL_ATTR_PACKET_SIZE		SQL_PACKET_SIZE
#define SQL_ATTR_QUIET_MODE			SQL_QUIET_MODE
#define SQL_ATTR_TRACE				SQL_OPT_TRACE
#define SQL_ATTR_TRACEFILE			SQL_OPT_TRACEFILE
#define SQL_ATTR_TRANSLATE_LIB		SQL_TRANSLATE_DLL
#define SQL_ATTR_TRANSLATE_OPTION	SQL_TRANSLATE_OPTION
*)
SQL_ATTR_TXN_ISOLATION		=SQL_TXN_ISOLATION;
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* SQL_CONNECT_OPT_DRVR_START is not meaningful for 3.0 driver */
{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_CONNECT_OPT_DRVR_START      1000
{$endif} //#endif  /* ODBCVER < 0x0300 */

{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_CONN_OPT_MAX                SQL_PACKET_SIZE
#define SQL_CONN_OPT_MIN                SQL_ACCESS_MODE
{$endif} //#endif /* ODBCVER < 0x0300 */

/* SQL_ACCESS_MODE options */
#define SQL_MODE_READ_WRITE             0UL
#define SQL_MODE_READ_ONLY              1UL
#define SQL_MODE_DEFAULT                SQL_MODE_READ_WRITE
*)

{ SQL_AUTOCOMMIT options }
SQL_AUTOCOMMIT_OFF              =0; //0UL
SQL_AUTOCOMMIT_ON               =1; //1UL
SQL_AUTOCOMMIT_DEFAULT          =SQL_AUTOCOMMIT_ON;

(*
/* SQL_LOGIN_TIMEOUT options */
#define SQL_LOGIN_TIMEOUT_DEFAULT       15UL

/* SQL_OPT_TRACE options */
#define SQL_OPT_TRACE_OFF               0UL
#define SQL_OPT_TRACE_ON                1UL
#define SQL_OPT_TRACE_DEFAULT           SQL_OPT_TRACE_OFF
#define SQL_OPT_TRACE_FILE_DEFAULT      "\\SQL.LOG"

/* SQL_ODBC_CURSORS options */
#define SQL_CUR_USE_IF_NEEDED           0UL
#define SQL_CUR_USE_ODBC                1UL
#define SQL_CUR_USE_DRIVER              2UL
#define SQL_CUR_DEFAULT                 SQL_CUR_USE_DRIVER

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* values for SQL_ATTR_DISCONNECT_BEHAVIOR */
#define SQL_DB_RETURN_TO_POOL			0UL
#define SQL_DB_DISCONNECT				1UL
#define SQL_DB_DEFAULT					SQL_DB_RETURN_TO_POOL

/* values for SQL_ATTR_ENLIST_IN_DTC */
#define SQL_DTC_DONE					0L
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
*)
{ values for SQL_ATTR_CONNECTION_DEAD }
SQL_CD_TRUE					=1;		{ Connection is closed/dead }
SQL_CD_FALSE				=0;		{ Connection is open/available }
(*
{$endif} //#endif /* ODBCVER >= 0x0350 */

/* statement attributes */
#define SQL_QUERY_TIMEOUT		0
#define SQL_MAX_ROWS			1
#define SQL_NOSCAN				2
#define SQL_MAX_LENGTH			3
#define SQL_ASYNC_ENABLE		4	/* same as SQL_ATTR_ASYNC_ENABLE */
#define SQL_BIND_TYPE			5
*)
SQL_CURSOR_TYPE			=6;
SQL_CONCURRENCY			=7;
(*
#define SQL_KEYSET_SIZE			8
*)
SQL_ROWSET_SIZE			=9;
(*
#define SQL_SIMULATE_CURSOR		10
*)
SQL_RETRIEVE_DATA		=11;
SQL_USE_BOOKMARKS		=12;
(*
#define SQL_GET_BOOKMARK		13      /*      GetStmtOption Only */
#define SQL_ROW_NUMBER			14      /*      GetStmtOption Only */
*)

{ statement attributes for ODBC 3.0 }
//3 {$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_ATTR_ASYNC_ENABLE				=4;
SQL_ATTR_CONCURRENCY				=SQL_CONCURRENCY;
SQL_ATTR_CURSOR_TYPE				=SQL_CURSOR_TYPE;
SQL_ATTR_ENABLE_AUTO_IPD			=15;
(*
#define SQL_ATTR_FETCH_BOOKMARK_PTR			16
#define SQL_ATTR_KEYSET_SIZE				SQL_KEYSET_SIZE
#define SQL_ATTR_MAX_LENGTH					SQL_MAX_LENGTH
*)
SQL_ATTR_MAX_ROWS					=SQL_MAX_ROWS;
SQL_ATTR_NOSCAN						=SQL_NOSCAN;
SQL_ATTR_PARAM_BIND_OFFSET_PTR		=17;
SQL_ATTR_PARAM_BIND_TYPE			=18;
(*
#define SQL_ATTR_PARAM_OPERATION_PTR		19
#define SQL_ATTR_PARAM_STATUS_PTR			20
*)
SQL_ATTR_PARAMS_PROCESSED_PTR		=21;
SQL_ATTR_PARAMSET_SIZE				=22;
SQL_ATTR_QUERY_TIMEOUT				=SQL_QUERY_TIMEOUT;
SQL_ATTR_RETRIEVE_DATA				=SQL_RETRIEVE_DATA;
SQL_ATTR_ROW_BIND_OFFSET_PTR		=23;
SQL_ATTR_ROW_BIND_TYPE				=SQL_BIND_TYPE;
(*
#define SQL_ATTR_ROW_NUMBER					SQL_ROW_NUMBER	  	/*GetStmtAttr*/
*)
SQL_ATTR_ROW_OPERATION_PTR			=24;
SQL_ATTR_ROW_STATUS_PTR				=25;
SQL_ATTR_ROWS_FETCHED_PTR			=26;
SQL_ATTR_ROW_ARRAY_SIZE				=27;
(*
#define SQL_ATTR_SIMULATE_CURSOR			SQL_SIMULATE_CURSOR
*)
SQL_ATTR_USE_BOOKMARKS				=SQL_USE_BOOKMARKS;
(*
//3 {$endif} //#endif  /* ODBCVER >= 0x0300 */

{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_STMT_OPT_MAX                SQL_ROW_NUMBER
#define SQL_STMT_OPT_MIN	SQL_QUERY_TIMEOUT
{$endif} //#endif    	/* ODBCVER < 0x0300 */

/* New defines for SEARCHABLE column in SQLGetTypeInfo */

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define	SQL_COL_PRED_CHAR		SQL_LIKE_ONLY
#define	SQL_COL_PRED_BASIC		SQL_ALL_EXCEPT_LIKE
{$endif} //#endif /* ODBCVER >= 0x0300 */



{ whether an attribute is a pointer or not }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_IS_POINTER							=(-4);
SQL_IS_UINTEGER							=(-5);
SQL_IS_INTEGER							=(-6);
(*
#define SQL_IS_USMALLINT						(-7)
*)
SQL_IS_SMALLINT							=(-8);
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* the value of SQL_ATTR_PARAM_BIND_TYPE */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_PARAM_BIND_BY_COLUMN			0UL
#define SQL_PARAM_BIND_TYPE_DEFAULT			SQL_PARAM_BIND_BY_COLUMN
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* SQL_QUERY_TIMEOUT options */
#define SQL_QUERY_TIMEOUT_DEFAULT       0UL

/* SQL_MAX_ROWS options */
#define SQL_MAX_ROWS_DEFAULT            0UL
*)
{ SQL_NOSCAN options }
SQL_NOSCAN_OFF                  =0; //*      1.0 FALSE */
SQL_NOSCAN_ON                   =1; //*      1.0 TRUE */
SQL_NOSCAN_DEFAULT              =SQL_NOSCAN_OFF;

(*
/* SQL_MAX_LENGTH options */
#define SQL_MAX_LENGTH_DEFAULT          0UL
*)
{ values for SQL_ATTR_ASYNC_ENABLE }
SQL_ASYNC_ENABLE_OFF			=0;
SQL_ASYNC_ENABLE_ON				=1;
SQL_ASYNC_ENABLE_DEFAULT        =SQL_ASYNC_ENABLE_OFF;
(*
/* SQL_BIND_TYPE options */
#define SQL_BIND_BY_COLUMN              0UL
#define SQL_BIND_TYPE_DEFAULT           SQL_BIND_BY_COLUMN  /* Default value */

/* SQL_CONCURRENCY options */
#define SQL_CONCUR_READ_ONLY            1
#define SQL_CONCUR_LOCK                 2
#define SQL_CONCUR_ROWVER               3
#define SQL_CONCUR_VALUES               4
#define SQL_CONCUR_DEFAULT              SQL_CONCUR_READ_ONLY /* Default value */
*)

{ SQL_CURSOR_TYPE options }
SQL_CURSOR_FORWARD_ONLY         =0;
SQL_CURSOR_KEYSET_DRIVEN        =1;
SQL_CURSOR_DYNAMIC              =2;
SQL_CURSOR_STATIC               =3;
SQL_CURSOR_TYPE_DEFAULT         =SQL_CURSOR_FORWARD_ONLY;  //* Default value */

(*
/* SQL_ROWSET_SIZE options */
#define SQL_ROWSET_SIZE_DEFAULT         1UL

/* SQL_KEYSET_SIZE options */
#define SQL_KEYSET_SIZE_DEFAULT         0UL

/* SQL_SIMULATE_CURSOR options */
#define SQL_SC_NON_UNIQUE               0UL
#define SQL_SC_TRY_UNIQUE               1UL
#define SQL_SC_UNIQUE                   2UL

/* SQL_RETRIEVE_DATA options */
#define SQL_RD_OFF                      0UL
#define SQL_RD_ON                       1UL
#define SQL_RD_DEFAULT                  SQL_RD_ON
*)

{ SQL_USE_BOOKMARKS options }
SQL_UB_OFF                      =0;
SQL_UB_ON						=1;
SQL_UB_DEFAULT                  =SQL_UB_OFF;

(*
/* New values for SQL_USE_BOOKMARKS attribute */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_UB_FIXED					SQL_UB_ON
#define SQL_UB_VARIABLE					2UL
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* extended descriptor field */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_DESC_ARRAY_SIZE						=20;
SQL_DESC_ARRAY_STATUS_PTR				=21;
SQL_DESC_AUTO_UNIQUE_VALUE				=SQL_COLUMN_AUTO_INCREMENT;
SQL_DESC_BASE_COLUMN_NAME				=22;
SQL_DESC_BASE_TABLE_NAME				=23;
SQL_DESC_BIND_OFFSET_PTR				=24;
SQL_DESC_BIND_TYPE						=25;
SQL_DESC_CASE_SENSITIVE					=SQL_COLUMN_CASE_SENSITIVE;
SQL_COLUMN_QUALIFIER_NAME       =17; //brought forward: Greg
SQL_DESC_CATALOG_NAME					=SQL_COLUMN_QUALIFIER_NAME;
SQL_DESC_CONCISE_TYPE					=SQL_COLUMN_TYPE;
(*
#define SQL_DESC_DATETIME_INTERVAL_PRECISION	26      //Note: (Greg) this is 1014 in ODBC
*)
SQL_DESC_DISPLAY_SIZE					=SQL_COLUMN_DISPLAY_SIZE;
SQL_DESC_FIXED_PREC_SCALE				=SQL_COLUMN_MONEY;
SQL_COLUMN_LABEL                =18; //brought forward: Greg
SQL_DESC_LABEL							=SQL_COLUMN_LABEL;
SQL_DESC_LITERAL_PREFIX					=27;
SQL_DESC_LITERAL_SUFFIX					=28;
SQL_DESC_LOCAL_TYPE_NAME				=29;
(*
#define	SQL_DESC_MAXIMUM_SCALE					30
#define SQL_DESC_MINIMUM_SCALE					31
*)
SQL_DESC_NUM_PREC_RADIX					=32;
SQL_DESC_PARAMETER_TYPE					=33;
SQL_DESC_ROWS_PROCESSED_PTR				=34;
(*
{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
#define SQL_DESC_ROWVER							35
{$endif} //#endif /* ODBCVER >= 0x0350 */
*)
SQL_COLUMN_OWNER_NAME           =16; //brought forward: Greg
SQL_DESC_SCHEMA_NAME					=SQL_COLUMN_OWNER_NAME;
SQL_DESC_SEARCHABLE						=SQL_COLUMN_SEARCHABLE;
SQL_DESC_TYPE_NAME						=SQL_COLUMN_TYPE_NAME;
SQL_COLUMN_TABLE_NAME           =15; //brought forward: Greg
SQL_DESC_TABLE_NAME						=SQL_COLUMN_TABLE_NAME;
SQL_DESC_UNSIGNED						=SQL_COLUMN_UNSIGNED;
SQL_DESC_UPDATABLE						=SQL_COLUMN_UPDATABLE;
(*
{$endif} //#endif /* ODBCVER >= 0x0300 */

*)
{ defines for diagnostics fields }
(*
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_DIAG_CURSOR_ROW_COUNT			(-1249)
*)
SQL_DIAG_ROW_NUMBER					=(-1248);
SQL_DIAG_COLUMN_NUMBER				=(-1247);
(*
{$endif} //#endif /* ODBCVER >= 0x0300 */

/* SQL extended datatypes */
#define SQL_DATE                                9
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_INTERVAL							10
{$endif} //#endif  /* ODBCVER >= 0x0300 */
#define SQL_TIME                                10
#define SQL_TIMESTAMP                           11
#define SQL_LONGVARCHAR                         (-1)
#define SQL_BINARY                              (-2)
#define SQL_VARBINARY                           (-3)
#define SQL_LONGVARBINARY                       (-4)
#define SQL_BIGINT                              (-5)
#define SQL_TINYINT                             (-6)
#define SQL_BIT                                 (-7)
*)
{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
SQL_GUID				=(-11);
{$endif} //#endif  /* ODBCVER >= 0x0350 */

(*
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* interval code */ //Greg - these are equivalent to SQL_YEAR etc.
#define SQL_CODE_YEAR				1
#define SQL_CODE_MONTH				2
#define SQL_CODE_DAY				3
#define SQL_CODE_HOUR				4
#define SQL_CODE_MINUTE				5
#define SQL_CODE_SECOND				6
#define SQL_CODE_YEAR_TO_MONTH			7
#define SQL_CODE_DAY_TO_HOUR			8
#define SQL_CODE_DAY_TO_MINUTE			9
#define SQL_CODE_DAY_TO_SECOND			10
#define SQL_CODE_HOUR_TO_MINUTE			11
#define SQL_CODE_HOUR_TO_SECOND			12
#define SQL_CODE_MINUTE_TO_SECOND		13

#define SQL_INTERVAL_YEAR					(100 + SQL_CODE_YEAR)
#define SQL_INTERVAL_MONTH					(100 + SQL_CODE_MONTH)
#define SQL_INTERVAL_DAY					(100 + SQL_CODE_DAY)
#define SQL_INTERVAL_HOUR					(100 + SQL_CODE_HOUR)
#define SQL_INTERVAL_MINUTE					(100 + SQL_CODE_MINUTE)
#define SQL_INTERVAL_SECOND                	(100 + SQL_CODE_SECOND)
#define SQL_INTERVAL_YEAR_TO_MONTH			(100 + SQL_CODE_YEAR_TO_MONTH)
#define SQL_INTERVAL_DAY_TO_HOUR			(100 + SQL_CODE_DAY_TO_HOUR)
#define SQL_INTERVAL_DAY_TO_MINUTE			(100 + SQL_CODE_DAY_TO_MINUTE)
#define SQL_INTERVAL_DAY_TO_SECOND			(100 + SQL_CODE_DAY_TO_SECOND)
#define SQL_INTERVAL_HOUR_TO_MINUTE			(100 + SQL_CODE_HOUR_TO_MINUTE)
#define SQL_INTERVAL_HOUR_TO_SECOND			(100 + SQL_CODE_HOUR_TO_SECOND)
#define SQL_INTERVAL_MINUTE_TO_SECOND		(100 + SQL_CODE_MINUTE_TO_SECOND)

{$else} //#else
#define SQL_INTERVAL_YEAR                       (-80)
#define SQL_INTERVAL_MONTH                      (-81)
#define SQL_INTERVAL_YEAR_TO_MONTH              (-82)
#define SQL_INTERVAL_DAY                        (-83)
#define SQL_INTERVAL_HOUR                       (-84)
#define SQL_INTERVAL_MINUTE                     (-85)
#define SQL_INTERVAL_SECOND                     (-86)
#define SQL_INTERVAL_DAY_TO_HOUR                (-87)
#define SQL_INTERVAL_DAY_TO_MINUTE              (-88)
#define SQL_INTERVAL_DAY_TO_SECOND              (-89)
#define SQL_INTERVAL_HOUR_TO_MINUTE             (-90)
#define SQL_INTERVAL_HOUR_TO_SECOND             (-91)
#define SQL_INTERVAL_MINUTE_TO_SECOND           (-92)
{$endif} //#endif  /* ODBCVER >= 0x0300 */


{$ifdef ODBCVER_LTEQ_0300} //#if (ODBCVER <= 0x0300)
#define SQL_UNICODE                             (-95)
#define SQL_UNICODE_VARCHAR                     (-96)
#define SQL_UNICODE_LONGVARCHAR                 (-97)
#define SQL_UNICODE_CHAR                        SQL_UNICODE
{$else} //#else
/* The previous definitions for SQL_UNICODE_ are historical and obsolete */

#define	SQL_UNICODE				SQL_WCHAR
#define	SQL_UNICODE_VARCHAR		SQL_WVARCHAR
#define SQL_UNICODE_LONGVARCHAR	SQL_WLONGVARCHAR
#define SQL_UNICODE_CHAR		SQL_WCHAR
{$endif} //#endif

{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_TYPE_DRIVER_START                   SQL_INTERVAL_YEAR
#define SQL_TYPE_DRIVER_END                     SQL_UNICODE_LONGVARCHAR
{$endif} //#endif  /* ODBCVER < 0x0300 */
*)

{ C datatype to SQL datatype mapping      SQL types}
{                                           ------------------- }
(* covered earlier - Greg - probably will be neater to merge the two sections
#define SQL_C_CHAR    SQL_CHAR             /* CHAR, VARCHAR, DECIMAL, NUMERIC */
#define SQL_C_LONG    SQL_INTEGER          /* INTEGER                      */
#define SQL_C_SHORT   SQL_SMALLINT         /* SMALLINT                     */
#define SQL_C_FLOAT   SQL_REAL             /* REAL                         */
#define SQL_C_DOUBLE  SQL_DOUBLE           /* FLOAT, DOUBLE                */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_C_NUMERIC		=SQL_NUMERIC;
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */
#define SQL_C_DEFAULT 99
*)
SQL_SIGNED_OFFSET       =(-20);
SQL_UNSIGNED_OFFSET     =(-22);


{ C datatype to SQL datatype mapping }
{ We have to support all these to comply with the ODBC standard - Greg }
(* changed to SQL_C_TYPE... in ODBC 3 - Greg
SQL_C_DATE       =SQL_DATE;
SQL_C_TIME       =SQL_TIME;
SQL_C_TIMESTAMP  =SQL_TIMESTAMP;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_C_TYPE_DATE					=SQL_TYPE_DATE;
SQL_C_TYPE_TIME					=SQL_TYPE_TIME;
SQL_C_TYPE_TIMESTAMP			=SQL_TYPE_TIMESTAMP;
SQL_C_INTERVAL_YEAR				=SQL_INTERVAL_YEAR;
SQL_C_INTERVAL_MONTH			=SQL_INTERVAL_MONTH;
SQL_C_INTERVAL_DAY				=SQL_INTERVAL_DAY;
SQL_C_INTERVAL_HOUR				=SQL_INTERVAL_HOUR;
SQL_C_INTERVAL_MINUTE			=SQL_INTERVAL_MINUTE;
SQL_C_INTERVAL_SECOND			=SQL_INTERVAL_SECOND;
SQL_C_INTERVAL_YEAR_TO_MONTH	=SQL_INTERVAL_YEAR_TO_MONTH;
SQL_C_INTERVAL_DAY_TO_HOUR		=SQL_INTERVAL_DAY_TO_HOUR;
SQL_C_INTERVAL_DAY_TO_MINUTE	=SQL_INTERVAL_DAY_TO_MINUTE;
SQL_C_INTERVAL_DAY_TO_SECOND	=SQL_INTERVAL_DAY_TO_SECOND;
SQL_C_INTERVAL_HOUR_TO_MINUTE	=SQL_INTERVAL_HOUR_TO_MINUTE;
SQL_C_INTERVAL_HOUR_TO_SECOND	=SQL_INTERVAL_HOUR_TO_SECOND;
SQL_C_INTERVAL_MINUTE_TO_SECOND	=SQL_INTERVAL_MINUTE_TO_SECOND;
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */
#define SQL_C_BINARY     SQL_BINARY
#define SQL_C_BIT        SQL_BIT
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_C_SBIGINT	=(SQL_BIGINT+SQL_SIGNED_OFFSET);	   // SIGNED BIGINT
SQL_C_UBIGINT	=(SQL_BIGINT+SQL_UNSIGNED_OFFSET);   // UNSIGNED BIGINT
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */
#define SQL_C_TINYINT    SQL_TINYINT
*)
SQL_C_SLONG      =(SQL_C_LONG+SQL_SIGNED_OFFSET);    // SIGNED INTEGER
SQL_C_SSHORT     =(SQL_C_SHORT+SQL_SIGNED_OFFSET);   // SIGNED SMALLINT
SQL_C_STINYINT   =(SQL_TINYINT+SQL_SIGNED_OFFSET);   // SIGNED TINYINT
SQL_C_ULONG      =(SQL_C_LONG+SQL_UNSIGNED_OFFSET);  // UNSIGNED INTEGER
SQL_C_USHORT     =(SQL_C_SHORT+SQL_UNSIGNED_OFFSET); // UNSIGNED SMALLINT
SQL_C_UTINYINT   =(SQL_TINYINT+SQL_UNSIGNED_OFFSET); // UNSIGNED TINYINT
SQL_C_BOOKMARK   =SQL_C_ULONG;                       // BOOKMARK

{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
SQL_C_GUID	=SQL_GUID;
{$endif} //#endif  /* ODBCVER >= 0x0350 */

(*
#define SQL_TYPE_NULL                   0
{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_TYPE_MIN                    SQL_BIT
#define SQL_TYPE_MAX                    SQL_VARCHAR
{$endif} //#endif

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_C_VARBOOKMARK		=SQL_C_BINARY;
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
{ define for SQL_DIAG_ROW_NUMBER and SQL_DIAG_COLUMN_NUMBER }
//2 {$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_NO_ROW_NUMBER						=(-1);
SQL_NO_COLUMN_NUMBER					=(-1);
(*
#define SQL_ROW_NUMBER_UNKNOWN					(-2)
#define SQL_COLUMN_NUMBER_UNKNOWN				(-2)
//2 {$endif} //#endif

/* SQLBindParameter extensions */
#define SQL_DEFAULT_PARAM            (-5)
#define SQL_IGNORE                   (-6)
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_COLUMN_IGNORE			SQL_IGNORE
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
SQL_LEN_DATA_AT_EXEC_OFFSET  =(-100);
(*
#define SQL_LEN_DATA_AT_EXEC(length) (-(length)+SQL_LEN_DATA_AT_EXEC_OFFSET)

/* binary length for driver specific attributes */
#define SQL_LEN_BINARY_ATTR_OFFSET	 (-100)
#define SQL_LEN_BINARY_ATTR(length)	 (-(length)+SQL_LEN_BINARY_ATTR_OFFSET)

/* Defines used by Driver Manager when mapping SQLSetParam to SQLBindParameter
*/
#define SQL_PARAM_TYPE_DEFAULT           SQL_PARAM_INPUT_OUTPUT
#define SQL_SETPARAM_VALUE_MAX           (-1L)

/* SQLColAttributes defines */
#define SQL_COLUMN_COUNT                0
#define SQL_COLUMN_NAME                 1
#define SQL_COLUMN_TYPE                 2
#define SQL_COLUMN_LENGTH               3
#define SQL_COLUMN_PRECISION            4
#define SQL_COLUMN_SCALE                5
#define SQL_COLUMN_DISPLAY_SIZE         6
#define SQL_COLUMN_NULLABLE             7
#define SQL_COLUMN_UNSIGNED             8
#define SQL_COLUMN_MONEY                9
#define SQL_COLUMN_UPDATABLE            10
#define SQL_COLUMN_AUTO_INCREMENT       11
#define SQL_COLUMN_CASE_SENSITIVE       12
*)
//moved before desc_column_searchable SQL_COLUMN_SEARCHABLE           =13;
(*
#define SQL_COLUMN_TYPE_NAME            14
*)
//moved before desc_table_name SQL_COLUMN_TABLE_NAME           =15;
//moved before desc_schema_name SQL_COLUMN_OWNER_NAME           16;
//moved before desc_catalog_name SQL_COLUMN_QUALIFIER_NAME       =17;
//moved before desc_label SQL_COLUMN_LABEL                =18;
(*
#define SQL_COLATT_OPT_MAX              SQL_COLUMN_LABEL
{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_COLUMN_DRIVER_START         1000
{$endif} //#endif  /* ODBCVER < 0x0300 */

#define SQL_COLATT_OPT_MIN              SQL_COLUMN_COUNT

/* SQLColAttributes subdefines for SQL_COLUMN_UPDATABLE */
#define SQL_ATTR_READONLY               0
#define SQL_ATTR_WRITE                  1
#define SQL_ATTR_READWRITE_UNKNOWN      2
*)

{ SQLColAttributes subdefines for SQL_COLUMN_SEARCHABLE }
{ These are also used by SQLGetInfo                     }
SQL_UNSEARCHABLE                =0;
SQL_LIKE_ONLY                   =1;
SQL_ALL_EXCEPT_LIKE             =2;
SQL_SEARCHABLE                  =3;
SQL_PRED_SEARCHABLE				=SQL_SEARCHABLE;


{ Special return values for SQLGetData }
SQL_NO_TOTAL                    =(-4);

(*
/********************************************/
/* SQLGetFunctions: additional values for   */
/* fFunction to represent functions that    */
/* are not in the X/Open spec.				*/
/********************************************/

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_API_SQLALLOCHANDLESTD	73
*)
//
SQL_API_SQLBULKOPERATIONS	=24; //debug ADO
(*
{$endif} //#endif /* ODBCVER >= 0x0300 */
#define SQL_API_SQLBINDPARAMETER    72
#define SQL_API_SQLBROWSECONNECT    55    
#define SQL_API_SQLCOLATTRIBUTES    6
#define SQL_API_SQLCOLUMNPRIVILEGES 56
#define SQL_API_SQLDESCRIBEPARAM    58
*)
SQL_API_SQLDRIVERCONNECT	=41;
(*
#define SQL_API_SQLDRIVERS          71
#define SQL_API_SQLEXTENDEDFETCH    59
#define SQL_API_SQLFOREIGNKEYS      60
#define SQL_API_SQLMORERESULTS      61
#define SQL_API_SQLNATIVESQL        62
#define SQL_API_SQLNUMPARAMS        63
#define SQL_API_SQLPARAMOPTIONS     64
#define SQL_API_SQLPRIMARYKEYS      65
#define SQL_API_SQLPROCEDURECOLUMNS 66
#define SQL_API_SQLPROCEDURES       67
#define SQL_API_SQLSETPOS           68
#define SQL_API_SQLSETSCROLLOPTIONS 69
#define SQL_API_SQLTABLEPRIVILEGES  70

/*-------------------------------------------*/
/* SQL_EXT_API_LAST is not useful with ODBC  */
/* version 3.0 because some of the values    */
/* from X/Open are in the 10000 range.       */
/*-------------------------------------------*/

{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_EXT_API_LAST            SQL_API_SQLBINDPARAMETER
#define SQL_NUM_FUNCTIONS           23
#define SQL_EXT_API_START           40
#define SQL_NUM_EXTENSIONS (SQL_EXT_API_LAST-SQL_EXT_API_START+1)
{$endif} //#endif
*)
{/*--------------------------------------------*/
 /* SQL_API_ALL_FUNCTIONS returns an array     */
 /* of 'booleans' representing whether a       */
 /* function is implemented by the driver.     */
 /*                                            */
 /* CAUTION: Only functions defined in ODBC    */
 /* version 2.0 and earlier are returned, the  */
 /* new high-range function numbers defined by */
 /* X/Open break this scheme.   See the new    */
 /* method -- SQL_API_ODBC3_ALL_FUNCTIONS      */
 /*--------------------------------------------*/}
SQL_API_ALL_FUNCTIONS       =0;		// See CAUTION above
(*
/*----------------------------------------------*/
/* 2.X drivers export a dummy function with  	*/
/* ordinal number SQL_API_LOADBYORDINAL to speed*/
/* loading under the windows operating system.  */
/* 						*/
/* CAUTION: Loading by ordinal is not supported */
/* for 3.0 and above drivers.			*/
/*----------------------------------------------*/

#define SQL_API_LOADBYORDINAL       199		/* See CAUTION above */
*)
{/*----------------------------------------------*/
 /* SQL_API_ODBC3_ALL_FUNCTIONS                  */
 /* This returns a bitmap, which allows us to    */
 /* handle the higher-valued function numbers.   */
 /* Use  SQL_FUNC_EXISTS(bitmap,function_number) */
 /* to determine if the function exists.         */
 /*----------------------------------------------*/}
(*
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_API_ODBC3_ALL_FUNCTIONS	=999;
SQL_API_ODBC3_ALL_FUNCTIONS_SIZE	=250;		// array of 250 words
(*
#define SQL_FUNC_EXISTS(pfExists, uwAPI) \
				((*(((UWORD* //Greg-to remove end comment!) (pfExists)) + ((uwAPI) >> 4)) \
					& (1 << ((uwAPI) & 0x000F)) \
 				 ) ? SQL_TRUE : SQL_FALSE \
				)
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{Greg - SQL_FUNC_EXISTS(bitmap,fn)
           newfn:=fn shr 4 (=mult by 16)
           bitmap+newfn AND (1 shl (fn AND 15)  (=the bit) )

 Note: bitOn= Value or (1 shl TheBit);

 pUWORD(longint(Supported)+(1001 div 16))^:=pUWORD(longint(Supported)+(1001 div 16))^ or (1 shl (1001 mod 15) );

}


/************************************************/
/* Extended definitions for SQLGetInfo			*/
/************************************************/

/*---------------------------------*/
/* Values in ODBC 2.0 that are not */
/* in the X/Open spec              */
/*---------------------------------*/

#define SQL_INFO_FIRST                       0		
#define SQL_ACTIVE_CONNECTIONS               0	/* MAX_DRIVER_CONNECTIONS */
#define SQL_ACTIVE_STATEMENTS                1	/* MAX_CONCURRENT_ACTIVITIES */
#define SQL_DRIVER_HDBC                      3
#define SQL_DRIVER_HENV                      4
#define SQL_DRIVER_HSTMT                     5
#define SQL_DRIVER_NAME                      6
#define SQL_DRIVER_VER                       7
#define SQL_ODBC_API_CONFORMANCE             9
#define SQL_ODBC_VER                        10
#define SQL_ROW_UPDATES                     11
#define SQL_ODBC_SAG_CLI_CONFORMANCE        12
#define SQL_ODBC_SQL_CONFORMANCE            15
#define SQL_PROCEDURES                      21
#define SQL_CONCAT_NULL_BEHAVIOR            22
*)
SQL_CURSOR_ROLLBACK_BEHAVIOR        =24;
(*
#define SQL_EXPRESSIONS_IN_ORDERBY          27
#define SQL_MAX_OWNER_NAME_LEN              32	/* MAX_SCHEMA_NAME_LEN */
#define SQL_MAX_PROCEDURE_NAME_LEN          33
#define SQL_MAX_QUALIFIER_NAME_LEN          34	/* MAX_CATALOG_NAME_LEN */
#define SQL_MULT_RESULT_SETS                36
#define SQL_MULTIPLE_ACTIVE_TXN             37
#define SQL_OUTER_JOINS                     38
#define SQL_OWNER_TERM                      39
#define SQL_PROCEDURE_TERM                  40
#define SQL_QUALIFIER_NAME_SEPARATOR        41
#define SQL_QUALIFIER_TERM                  42
#define SQL_SCROLL_OPTIONS                  44
#define SQL_TABLE_TERM                      45
#define SQL_CONVERT_FUNCTIONS               48
#define SQL_NUMERIC_FUNCTIONS               49
#define SQL_STRING_FUNCTIONS                50
#define SQL_SYSTEM_FUNCTIONS                51
#define SQL_TIMEDATE_FUNCTIONS              52
#define SQL_CONVERT_BIGINT                  53
#define SQL_CONVERT_BINARY                  54
#define SQL_CONVERT_BIT                     55
#define SQL_CONVERT_CHAR                    56
#define SQL_CONVERT_DATE                    57
#define SQL_CONVERT_DECIMAL                 58
#define SQL_CONVERT_DOUBLE                  59
#define SQL_CONVERT_FLOAT                   60
#define SQL_CONVERT_INTEGER                 61
#define SQL_CONVERT_LONGVARCHAR             62
#define SQL_CONVERT_NUMERIC                 63
#define SQL_CONVERT_REAL                    64
#define SQL_CONVERT_SMALLINT                65
#define SQL_CONVERT_TIME                    66
#define SQL_CONVERT_TIMESTAMP               67
#define SQL_CONVERT_TINYINT                 68
#define SQL_CONVERT_VARBINARY               69
#define SQL_CONVERT_VARCHAR                 70
#define SQL_CONVERT_LONGVARBINARY           71
#define SQL_ODBC_SQL_OPT_IEF                73		/* SQL_INTEGRITY */
*)
SQL_CORRELATION_NAME                =74;
SQL_NON_NULLABLE_COLUMNS            =75;
(*
#define SQL_DRIVER_HLIB                     76
*)
SQL_DRIVER_ODBC_VER                 =77;

SQL_LOCK_TYPES                      =78;
SQL_POS_OPERATIONS                  =79;
SQL_POSITIONED_STATEMENTS           =80;
SQL_BOOKMARK_PERSISTENCE            =82;
SQL_STATIC_SENSITIVITY              =83;

SQL_FILE_USAGE                      =84;
SQL_COLUMN_ALIAS                    =87;
SQL_GROUP_BY                        =88;
SQL_KEYWORDS                        =89;
SQL_OWNER_USAGE                     =91;
SQL_QUALIFIER_USAGE                 =92;
SQL_QUOTED_IDENTIFIER_CASE          =93;
SQL_SUBQUERIES                      =95;
SQL_UNION                           =96;
SQL_MAX_ROW_SIZE_INCLUDES_LONG      =103; //Greg: =MAX_ROW_SIZE?
SQL_MAX_ROW_SIZE                    =104; //Greg: 28/01/01 added
SQL_MAX_CHAR_LITERAL_LEN            =108;
SQL_TIMEDATE_ADD_INTERVALS          =109;
SQL_TIMEDATE_DIFF_INTERVALS         =110;
SQL_NEED_LONG_DATA_LEN              =111;
SQL_MAX_BINARY_LITERAL_LEN          =112;
SQL_LIKE_ESCAPE_CLAUSE              =113;
SQL_QUALIFIER_LOCATION              =114;

(*
#if (ODBCVER >= 0x0201 && ODBCVER < 0x0300)
#define SQL_OJ_CAPABILITIES         65003  /* Temp value until ODBC 3.0 */
#endif  /* ODBCVER >= 0x0201 && ODBCVER < 0x0300 */

/*----------------------------------------------*/
/* SQL_INFO_LAST and SQL_INFO_DRIVER_START are  */
/* not useful anymore, because  X/Open has      */
/* values in the 10000 range.   You  			*/
/* must contact X/Open directly to get a range	*/
/* of numbers for driver-specific values.	    */
/*----------------------------------------------*/

{$ifdef ODBCVER_LT_0300} //#if (ODBCVER < 0x0300)
#define SQL_INFO_LAST						SQL_QUALIFIER_LOCATION
#define SQL_INFO_DRIVER_START				1000
{$endif} //#endif /* ODBCVER < 0x0300 */

/*-----------------------------------------------*/
/* ODBC 3.0 SQLGetInfo values that are not part  */
/* of the X/Open standard at this time.   X/Open */
/* standard values are in sql.h.				 */
/*-----------------------------------------------*/
*)
//1 {$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_ACTIVE_ENVIRONMENTS					=116;
SQL_ALTER_DOMAIN					=117;


SQL_SQL_CONFORMANCE					=118;
SQL_DATETIME_LITERALS					=119;
SQL_ASYNC_MODE						=10021;	// new X/Open spec
SQL_BATCH_ROW_COUNT					=120;
SQL_BATCH_SUPPORT					=121;
SQL_CATALOG_LOCATION					=SQL_QUALIFIER_LOCATION;
SQL_CATALOG_NAME_SEPARATOR				=SQL_QUALIFIER_NAME_SEPARATOR;
SQL_CATALOG_TERM					=SQL_QUALIFIER_TERM;
SQL_CATALOG_USAGE					=SQL_QUALIFIER_USAGE;
(*
#define	SQL_CONVERT_WCHAR						122
#define SQL_CONVERT_INTERVAL_DAY_TIME			123
#define SQL_CONVERT_INTERVAL_YEAR_MONTH			124
#define	SQL_CONVERT_WLONGVARCHAR				125
#define	SQL_CONVERT_WVARCHAR					126
*)
SQL_CREATE_ASSERTION					=127;
SQL_CREATE_CHARACTER_SET				=128;
SQL_CREATE_COLLATION					=129;
SQL_CREATE_DOMAIN						=130;
SQL_CREATE_SCHEMA						=131;
SQL_CREATE_TABLE						=132;
SQL_CREATE_TRANSLATION					=133;
SQL_CREATE_VIEW							=134;
(*
#define SQL_DRIVER_HDESC						135
*)
SQL_DROP_ASSERTION						=136;
SQL_DROP_CHARACTER_SET					=137;
SQL_DROP_COLLATION						=138;
SQL_DROP_DOMAIN							=139;
SQL_DROP_SCHEMA							=140;
SQL_DROP_TABLE							=141;
SQL_DROP_TRANSLATION					=142;
SQL_DROP_VIEW							=143;
SQL_DYNAMIC_CURSOR_ATTRIBUTES1			=144;
SQL_DYNAMIC_CURSOR_ATTRIBUTES2			=145;
SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES1		=146;
SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES2		=147;
SQL_INDEX_KEYWORDS						=148;
SQL_INFO_SCHEMA_VIEWS					=149;
SQL_KEYSET_CURSOR_ATTRIBUTES1			=150;
SQL_KEYSET_CURSOR_ATTRIBUTES2			=151;
SQL_MAX_ASYNC_CONCURRENT_STATEMENTS		=10022;	// new X/Open spec
SQL_ODBC_INTERFACE_CONFORMANCE			=152;
SQL_PARAM_ARRAY_ROW_COUNTS     			=153;
SQL_PARAM_ARRAY_SELECTS     			=154;
SQL_SCHEMA_TERM						=SQL_OWNER_TERM;
SQL_SCHEMA_USAGE					=SQL_OWNER_USAGE;
SQL_SQL92_DATETIME_FUNCTIONS			=155;
SQL_SQL92_FOREIGN_KEY_DELETE_RULE		=156;
SQL_SQL92_FOREIGN_KEY_UPDATE_RULE		=157;
SQL_SQL92_GRANT							=158;
SQL_SQL92_NUMERIC_VALUE_FUNCTIONS		=159;
SQL_SQL92_PREDICATES					=160;
SQL_SQL92_RELATIONAL_JOIN_OPERATORS		=161;
SQL_SQL92_REVOKE						=162;
SQL_SQL92_ROW_VALUE_CONSTRUCTOR			=163;
SQL_SQL92_STRING_FUNCTIONS				=164;
SQL_SQL92_VALUE_EXPRESSIONS				=165;
SQL_STANDARD_CLI_CONFORMANCE			=166;
SQL_STATIC_CURSOR_ATTRIBUTES1			=167;
SQL_STATIC_CURSOR_ATTRIBUTES2			=168;

SQL_AGGREGATE_FUNCTIONS				=169;
SQL_DDL_INDEX					=170;
(*
#define SQL_DM_VER								171
*)
SQL_INSERT_STATEMENT				=172;
(*
#define SQL_UNION_STATEMENT						SQL_UNION
//1 {$endif} //#endif  /* ODBCVER >= 0x0300 */

#define	SQL_DTC_TRANSITION_COST					1750

/* SQL_ALTER_TABLE bitmasks */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* the following 5 bitmasks are defined in sql.h
*#define SQL_AT_ADD_COLUMN                   	0x00000001L
*#define SQL_AT_DROP_COLUMN                  	0x00000002L
*#define SQL_AT_ADD_CONSTRAINT               	0x00000008L
*/
#define	SQL_AT_ADD_COLUMN_SINGLE				0x00000020L
#define	SQL_AT_ADD_COLUMN_DEFAULT				0x00000040L
#define	SQL_AT_ADD_COLUMN_COLLATION				0x00000080L
#define	SQL_AT_SET_COLUMN_DEFAULT				0x00000100L
#define	SQL_AT_DROP_COLUMN_DEFAULT				0x00000200L
#define	SQL_AT_DROP_COLUMN_CASCADE				0x00000400L
#define	SQL_AT_DROP_COLUMN_RESTRICT				0x00000800L
#define SQL_AT_ADD_TABLE_CONSTRAINT				0x00001000L
#define SQL_AT_DROP_TABLE_CONSTRAINT_CASCADE	0x00002000L
#define SQL_AT_DROP_TABLE_CONSTRAINT_RESTRICT	0x00004000L
#define SQL_AT_CONSTRAINT_NAME_DEFINITION		0x00008000L
#define SQL_AT_CONSTRAINT_INITIALLY_DEFERRED	0x00010000L
#define SQL_AT_CONSTRAINT_INITIALLY_IMMEDIATE	0x00020000L
#define SQL_AT_CONSTRAINT_DEFERRABLE			0x00040000L
#define SQL_AT_CONSTRAINT_NON_DEFERRABLE		0x00080000L
{$endif} //#endif	/* ODBCVER >= 0x0300 */

/* SQL_CONVERT_*  return value bitmasks */

#define SQL_CVT_CHAR                        0x00000001L
#define SQL_CVT_NUMERIC                     0x00000002L
#define SQL_CVT_DECIMAL                     0x00000004L
#define SQL_CVT_INTEGER                     0x00000008L
#define SQL_CVT_SMALLINT                    0x00000010L
#define SQL_CVT_FLOAT                       0x00000020L
#define SQL_CVT_REAL                        0x00000040L
#define SQL_CVT_DOUBLE                      0x00000080L
#define SQL_CVT_VARCHAR                     0x00000100L
#define SQL_CVT_LONGVARCHAR                 0x00000200L
#define SQL_CVT_BINARY                      0x00000400L
#define SQL_CVT_VARBINARY                   0x00000800L
#define SQL_CVT_BIT                         0x00001000L
#define SQL_CVT_TINYINT                     0x00002000L
#define SQL_CVT_BIGINT                      0x00004000L
#define SQL_CVT_DATE                        0x00008000L
#define SQL_CVT_TIME                        0x00010000L
#define SQL_CVT_TIMESTAMP                   0x00020000L
#define SQL_CVT_LONGVARBINARY               0x00040000L
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_CVT_INTERVAL_YEAR_MONTH	    	0x00080000L
#define SQL_CVT_INTERVAL_DAY_TIME	    	0x00100000L
#define	SQL_CVT_WCHAR						0x00200000L
#define	SQL_CVT_WLONGVARCHAR				0x00400000L
#define	SQL_CVT_WVARCHAR					0x00800000L

{$endif} //#endif  /* ODBCVER >= 0x0300 */


/* SQL_CONVERT_FUNCTIONS functions */
#define SQL_FN_CVT_CONVERT                  0x00000001L
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_FN_CVT_CAST						0x00000002L
{$endif} //#endif  /* ODBCVER >= 0x0300 */


/* SQL_STRING_FUNCTIONS functions */

#define SQL_FN_STR_CONCAT                   0x00000001L
#define SQL_FN_STR_INSERT                   0x00000002L
#define SQL_FN_STR_LEFT                     0x00000004L
#define SQL_FN_STR_LTRIM                    0x00000008L
#define SQL_FN_STR_LENGTH                   0x00000010L
#define SQL_FN_STR_LOCATE                   0x00000020L
#define SQL_FN_STR_LCASE                    0x00000040L
#define SQL_FN_STR_REPEAT                   0x00000080L
#define SQL_FN_STR_REPLACE                  0x00000100L
#define SQL_FN_STR_RIGHT                    0x00000200L
#define SQL_FN_STR_RTRIM                    0x00000400L
#define SQL_FN_STR_SUBSTRING                0x00000800L
#define SQL_FN_STR_UCASE                    0x00001000L
#define SQL_FN_STR_ASCII                    0x00002000L
#define SQL_FN_STR_CHAR                     0x00004000L
#define SQL_FN_STR_DIFFERENCE               0x00008000L
#define SQL_FN_STR_LOCATE_2                 0x00010000L
#define SQL_FN_STR_SOUNDEX                  0x00020000L
#define SQL_FN_STR_SPACE                    0x00040000L
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_FN_STR_BIT_LENGTH				0x00080000L
#define SQL_FN_STR_CHAR_LENGTH				0x00100000L
#define SQL_FN_STR_CHARACTER_LENGTH			0x00200000L
#define SQL_FN_STR_OCTET_LENGTH				0x00400000L
#define SQL_FN_STR_POSITION					0x00800000L
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)

{ SQL_SQL92_STRING_FUNCTIONS }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_SSF_CONVERT						=$00000001;
SQL_SSF_LOWER						=$00000002;
SQL_SSF_UPPER						=$00000004;
SQL_SSF_SUBSTRING					=$00000008;
SQL_SSF_TRANSLATE					=$00000010;
SQL_SSF_TRIM_BOTH					=$00000020;
SQL_SSF_TRIM_LEADING				=$00000040;
SQL_SSF_TRIM_TRAILING				=$00000080;
{$endif} //#endif /* ODBCVER >= 0x0300 */

(*
/* SQL_NUMERIC_FUNCTIONS functions */

#define SQL_FN_NUM_ABS                      0x00000001L
#define SQL_FN_NUM_ACOS                     0x00000002L
#define SQL_FN_NUM_ASIN                     0x00000004L
#define SQL_FN_NUM_ATAN                     0x00000008L
#define SQL_FN_NUM_ATAN2                    0x00000010L
#define SQL_FN_NUM_CEILING                  0x00000020L
#define SQL_FN_NUM_COS                      0x00000040L
#define SQL_FN_NUM_COT                      0x00000080L
#define SQL_FN_NUM_EXP                      0x00000100L
#define SQL_FN_NUM_FLOOR                    0x00000200L
#define SQL_FN_NUM_LOG                      0x00000400L
#define SQL_FN_NUM_MOD                      0x00000800L
#define SQL_FN_NUM_SIGN                     0x00001000L
#define SQL_FN_NUM_SIN                      0x00002000L
#define SQL_FN_NUM_SQRT                     0x00004000L
#define SQL_FN_NUM_TAN                      0x00008000L
#define SQL_FN_NUM_PI                       0x00010000L
#define SQL_FN_NUM_RAND                     0x00020000L
#define SQL_FN_NUM_DEGREES                  0x00040000L
#define SQL_FN_NUM_LOG10                    0x00080000L
#define SQL_FN_NUM_POWER                    0x00100000L
#define SQL_FN_NUM_RADIANS                  0x00200000L
#define SQL_FN_NUM_ROUND                    0x00400000L
#define SQL_FN_NUM_TRUNCATE                 0x00800000L
*)

{ SQL_SQL92_NUMERIC_VALUE_FUNCTIONS }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_SNVF_BIT_LENGTH					=$00000001;
SQL_SNVF_CHAR_LENGTH				=$00000002;
SQL_SNVF_CHARACTER_LENGTH			=$00000004;
SQL_SNVF_EXTRACT					=$00000008;
SQL_SNVF_OCTET_LENGTH				=$00000010;
SQL_SNVF_POSITION					=$00000020;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

(*
/* SQL_TIMEDATE_FUNCTIONS functions */

#define SQL_FN_TD_NOW                       0x00000001L
#define SQL_FN_TD_CURDATE                   0x00000002L
#define SQL_FN_TD_DAYOFMONTH                0x00000004L
#define SQL_FN_TD_DAYOFWEEK                 0x00000008L
#define SQL_FN_TD_DAYOFYEAR                 0x00000010L
#define SQL_FN_TD_MONTH                     0x00000020L
#define SQL_FN_TD_QUARTER                   0x00000040L
#define SQL_FN_TD_WEEK                      0x00000080L
#define SQL_FN_TD_YEAR                      0x00000100L
#define SQL_FN_TD_CURTIME                   0x00000200L
#define SQL_FN_TD_HOUR                      0x00000400L
#define SQL_FN_TD_MINUTE                    0x00000800L
#define SQL_FN_TD_SECOND                    0x00001000L
#define SQL_FN_TD_TIMESTAMPADD              0x00002000L
#define SQL_FN_TD_TIMESTAMPDIFF             0x00004000L
#define SQL_FN_TD_DAYNAME                   0x00008000L
#define SQL_FN_TD_MONTHNAME                 0x00010000L
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_FN_TD_CURRENT_DATE				0x00020000L
#define SQL_FN_TD_CURRENT_TIME				0x00040000L
#define SQL_FN_TD_CURRENT_TIMESTAMP			0x00080000L
#define SQL_FN_TD_EXTRACT					0x00100000L
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
{ SQL_SQL92_DATETIME_FUNCTIONS }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_SDF_CURRENT_DATE				=$00000001;
SQL_SDF_CURRENT_TIME				=$00000002;
SQL_SDF_CURRENT_TIMESTAMP			=$00000004;
{$endif} //#endif /* ODBCVER >= 0x0300 */
(*
/* SQL_SYSTEM_FUNCTIONS functions */

#define SQL_FN_SYS_USERNAME                 0x00000001L
#define SQL_FN_SYS_DBNAME                   0x00000002L
#define SQL_FN_SYS_IFNULL                   0x00000004L

/* SQL_TIMEDATE_ADD_INTERVALS and SQL_TIMEDATE_DIFF_INTERVALS functions */

#define SQL_FN_TSI_FRAC_SECOND              0x00000001L
#define SQL_FN_TSI_SECOND                   0x00000002L
#define SQL_FN_TSI_MINUTE                   0x00000004L
#define SQL_FN_TSI_HOUR                     0x00000008L
#define SQL_FN_TSI_DAY                      0x00000010L
#define SQL_FN_TSI_WEEK                     0x00000020L
#define SQL_FN_TSI_MONTH                    0x00000040L
#define SQL_FN_TSI_QUARTER                  0x00000080L
#define SQL_FN_TSI_YEAR                     0x00000100L

/* bitmasks for SQL_DYNAMIC_CURSOR_ATTRIBUTES1,
 * SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES1,
 * SQL_KEYSET_CURSOR_ATTRIBUTES1, and SQL_STATIC_CURSOR_ATTRIBUTES1
 */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* supported SQLFetchScroll FetchOrientation's */
*)
SQL_CA1_NEXT						=$00000001; //0x00000001L;
//debug ADO
//SQL_CA1_ABSOLUTE					=$00000002;
//SQL_CA1_RELATIVE					=$00000004;
//SQL_CA1_BOOKMARK					=$00000008;
(*
/* supported SQLSetPos LockType's */
#define SQL_CA1_LOCK_NO_CHANGE				0x00000040L
#define SQL_CA1_LOCK_EXCLUSIVE				0x00000080L
#define SQL_CA1_LOCK_UNLOCK					0x00000100L

/* supported SQLSetPos Operations */
#define SQL_CA1_POS_POSITION				0x00000200L
#define SQL_CA1_POS_UPDATE					0x00000400L
#define SQL_CA1_POS_DELETE					0x00000800L
#define SQL_CA1_POS_REFRESH					0x00001000L

/* positioned updates and deletes */
#define SQL_CA1_POSITIONED_UPDATE			0x00002000L
#define SQL_CA1_POSITIONED_DELETE			0x00004000L
#define SQL_CA1_SELECT_FOR_UPDATE			0x00008000L

/* supported SQLBulkOperations operations */
#define SQL_CA1_BULK_ADD					0x00010000L
#define SQL_CA1_BULK_UPDATE_BY_BOOKMARK		0x00020000L
#define SQL_CA1_BULK_DELETE_BY_BOOKMARK		0x00040000L
#define SQL_CA1_BULK_FETCH_BY_BOOKMARK		0x00080000L
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* bitmasks for SQL_DYNAMIC_CURSOR_ATTRIBUTES2,
 * SQL_FORWARD_ONLY_CURSOR_ATTRIBUTES2,
 * SQL_KEYSET_CURSOR_ATTRIBUTES2, and SQL_STATIC_CURSOR_ATTRIBUTES2 
 */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
/* supported values for SQL_ATTR_SCROLL_CONCURRENCY */
#define SQL_CA2_READ_ONLY_CONCURRENCY		0x00000001L
#define SQL_CA2_LOCK_CONCURRENCY			0x00000002L
#define SQL_CA2_OPT_ROWVER_CONCURRENCY		0x00000004L
#define SQL_CA2_OPT_VALUES_CONCURRENCY		0x00000008L

/* sensitivity of the cursor to its own inserts, deletes, and updates */
#define SQL_CA2_SENSITIVITY_ADDITIONS		0x00000010L
#define SQL_CA2_SENSITIVITY_DELETIONS		0x00000020L
#define SQL_CA2_SENSITIVITY_UPDATES			0x00000040L

/* semantics of SQL_ATTR_MAX_ROWS */
#define SQL_CA2_MAX_ROWS_SELECT				0x00000080L
#define SQL_CA2_MAX_ROWS_INSERT				0x00000100L
#define SQL_CA2_MAX_ROWS_DELETE				0x00000200L
#define SQL_CA2_MAX_ROWS_UPDATE				0x00000400L
#define SQL_CA2_MAX_ROWS_CATALOG			0x00000800L
#define SQL_CA2_MAX_ROWS_AFFECTS_ALL		(SQL_CA2_MAX_ROWS_SELECT | \
					SQL_CA2_MAX_ROWS_INSERT | SQL_CA2_MAX_ROWS_DELETE | \
					SQL_CA2_MAX_ROWS_UPDATE | SQL_CA2_MAX_ROWS_CATALOG)

/* semantics of SQL_DIAG_CURSOR_ROW_COUNT */
#define SQL_CA2_CRC_EXACT					0x00001000L
#define SQL_CA2_CRC_APPROXIMATE				0x00002000L

/* the kinds of positioned statements that can be simulated */
#define SQL_CA2_SIMULATE_NON_UNIQUE			0x00004000L
#define SQL_CA2_SIMULATE_TRY_UNIQUE			0x00008000L
#define SQL_CA2_SIMULATE_UNIQUE				0x00010000L
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
{ SQL_ODBC_API_CONFORMANCE values }
SQL_OAC_NONE                        =$0000; //0x0000;
SQL_OAC_LEVEL1                      =$0001; //x0001
SQL_OAC_LEVEL2                      =$0002; //0x0002

{ SQL_ODBC_SAG_CLI_CONFORMANCE values }

SQL_OSCC_NOT_COMPLIANT              =$0000;
SQL_OSCC_COMPLIANT                  =$0001;


{ SQL_ODBC_SQL_CONFORMANCE values }
SQL_OSC_MINIMUM                     =$0000; //0x0000
SQL_OSC_CORE                        =$0001; //0x0001
SQL_OSC_EXTENDED                    =$0002; //0x0002

{ SQL_CONCAT_NULL_BEHAVIOR values }

SQL_CB_NULL                         =$0000;
SQL_CB_NON_NULL                     =$0001;

(*
/* SQL_SCROLL_OPTIONS masks */

#define SQL_SO_FORWARD_ONLY                 0x00000001L
#define SQL_SO_KEYSET_DRIVEN                0x00000002L
#define SQL_SO_DYNAMIC                      0x00000004L
#define SQL_SO_MIXED                        0x00000008L
*)
SQL_SO_STATIC                       =$00000010;
(*
/* SQL_FETCH_DIRECTION masks */

/* SQL_FETCH_RESUME is no longer supported
#define SQL_FD_FETCH_RESUME                 0x00000040L
*/
#define SQL_FD_FETCH_BOOKMARK               0x00000080L

/* SQL_TXN_ISOLATION_OPTION masks */
/* SQL_TXN_VERSIONING is no longer supported
#define SQL_TXN_VERSIONING                  0x00000010L
*/
*)

{ SQL_CORRELATION_NAME values }

SQL_CN_NONE                         =$0000;
SQL_CN_DIFFERENT                    =$0001;
SQL_CN_ANY                          =$0002;

{ SQL_NON_NULLABLE_COLUMNS values }

SQL_NNC_NULL                        =$0000;
SQL_NNC_NON_NULL                    =$0001;

(*
/* SQL_NULL_COLLATION values */

#define SQL_NC_START                        0x0002
#define SQL_NC_END                          0x0004

/* SQL_FILE_USAGE values */
*)
SQL_FILE_NOT_SUPPORTED              =$0000;
(*
#define SQL_FILE_TABLE                      0x0001
#define SQL_FILE_QUALIFIER                  0x0002
#define SQL_FILE_CATALOG					SQL_FILE_QUALIFIER	// ODBC 3.0


/* SQL_GETDATA_EXTENSIONS values */

#define SQL_GD_BLOCK                        0x00000004L
#define SQL_GD_BOUND                        0x00000008L
*)
{ SQL_POSITIONED_STATEMENTS masks }
//debug ADO
//SQL_PS_POSITIONED_DELETE            =$00000001;
//SQL_PS_POSITIONED_UPDATE            =$00000002;
//SQL_PS_SELECT_FOR_UPDATE            =$00000004;

{ SQL_GROUP_BY values }

SQL_GB_NOT_SUPPORTED                =$0000;
SQL_GB_GROUP_BY_EQUALS_SELECT       =$0001;
SQL_GB_GROUP_BY_CONTAINS_SELECT     =$0002;
SQL_GB_NO_RELATION                  =$0003;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_GB_COLLATE						=$0004;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{ SQL_OWNER_USAGE masks }

SQL_OU_DML_STATEMENTS               =$00000001;
SQL_OU_PROCEDURE_INVOCATION         =$00000002;
SQL_OU_TABLE_DEFINITION             =$00000004;
SQL_OU_INDEX_DEFINITION             =$00000008;
SQL_OU_PRIVILEGE_DEFINITION         =$00000010;

{ SQL_SCHEMA_USAGE masks }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_SU_DML_STATEMENTS			=SQL_OU_DML_STATEMENTS;
SQL_SU_PROCEDURE_INVOCATION		=SQL_OU_PROCEDURE_INVOCATION;
SQL_SU_TABLE_DEFINITION			=SQL_OU_TABLE_DEFINITION;
SQL_SU_INDEX_DEFINITION			=SQL_OU_INDEX_DEFINITION;
SQL_SU_PRIVILEGE_DEFINITION		=SQL_OU_PRIVILEGE_DEFINITION;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{ SQL_QUALIFIER_USAGE masks }
SQL_QU_DML_STATEMENTS               =$00000001;
SQL_QU_PROCEDURE_INVOCATION         =$00000002;
SQL_QU_TABLE_DEFINITION             =$00000004;
SQL_QU_INDEX_DEFINITION             =$00000008;
SQL_QU_PRIVILEGE_DEFINITION         =$00000010;

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
{ SQL_CATALOG_USAGE masks }
SQL_CU_DML_STATEMENTS			=SQL_QU_DML_STATEMENTS;
SQL_CU_PROCEDURE_INVOCATION		=SQL_QU_PROCEDURE_INVOCATION;
SQL_CU_TABLE_DEFINITION			=SQL_QU_TABLE_DEFINITION;
SQL_CU_INDEX_DEFINITION			=SQL_QU_INDEX_DEFINITION;
SQL_CU_PRIVILEGE_DEFINITION		=SQL_QU_PRIVILEGE_DEFINITION;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{ SQL_SUBQUERIES masks }
SQL_SQ_COMPARISON                   =$00000001;
SQL_SQ_EXISTS                       =$00000002;
SQL_SQ_IN                           =$00000004;
SQL_SQ_QUANTIFIED                   =$00000008;
SQL_SQ_CORRELATED_SUBQUERIES        =$00000010;

{ SQL_UNION masks }
SQL_U_UNION                         =$00000001;
SQL_U_UNION_ALL                     =$00000002;

{ SQL_BOOKMARK_PERSISTENCE values }
//debug ADO
//SQL_BP_CLOSE                        =$00000001;
//SQL_BP_DELETE                       =$00000002;
//SQL_BP_DROP                         =$00000004;
//SQL_BP_TRANSACTION                  =$00000008;
//SQL_BP_UPDATE                       =$00000010;
//SQL_BP_OTHER_HSTMT                  =$00000020;
//SQL_BP_SCROLL                       =$00000040;

{ SQL_STATIC_SENSITIVITY values }
//debug ADO
//SQL_SS_ADDITIONS                    =$00000001;
//SQL_SS_DELETIONS                    =$00000002;
//SQL_SS_UPDATES                      =$00000004;

{ SQL_VIEW values }
SQL_CV_CREATE_VIEW					=$00000001;
SQL_CV_CHECK_OPTION					=$00000002;
SQL_CV_CASCADED						=$00000004;
SQL_CV_LOCAL						=$00000008;
{ SQL_LOCK_TYPES masks }
//debug ADO
SQL_LCK_NO_CHANGE                   =$00000001;
//SQL_LCK_EXCLUSIVE                   =$00000002;
//SQL_LCK_UNLOCK                      =$00000004;

{ SQL_POS_OPERATIONS masks }
//debug ADO
//SQL_POS_POSITION                    =$00000001;
//SQL_POS_REFRESH                     =$00000002;
//SQL_POS_UPDATE                      =$00000004;
//SQL_POS_DELETE                      =$00000008;
//SQL_POS_ADD                         =$00000010;

{ SQL_QUALIFIER_LOCATION values }

SQL_QL_START                        =$0001;
SQL_QL_END                          =$0002;

{* Here start return values for ODBC 3.0 SQLGetInfo *}

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
{ SQL_AGGREGATE_FUNCTIONS bitmasks }
SQL_AF_AVG						=$00000001;
SQL_AF_COUNT					=$00000002;
SQL_AF_MAX						=$00000004;
SQL_AF_MIN						=$00000008;
SQL_AF_SUM						=$00000010;
SQL_AF_DISTINCT					=$00000020;
SQL_AF_ALL		=(SQL_AF_AVG OR SQL_AF_COUNT OR SQL_AF_MAX OR SQL_AF_MIN OR SQL_AF_SUM OR SQL_AF_DISTINCT);

{ SQL_SQL_CONFORMANCE bit masks }
SQL_SC_SQL92_ENTRY				=$00000001; //0x00000001L
SQL_SC_FIPS127_2_TRANSITIONAL	=$00000002; //0x00000002L
SQL_SC_SQL92_INTERMEDIATE		=$00000004; //0x00000004L
SQL_SC_SQL92_FULL				=$00000008; //0x00000008L

{ SQL_DATETIME_LITERALS masks }
SQL_DL_SQL92_DATE						=$00000001;
SQL_DL_SQL92_TIME						=$00000002;
SQL_DL_SQL92_TIMESTAMP					=$00000004;
(*todo
#define SQL_DL_SQL92_INTERVAL_YEAR				0x00000008L
#define SQL_DL_SQL92_INTERVAL_MONTH				0x00000010L
#define SQL_DL_SQL92_INTERVAL_DAY				0x00000020L
#define SQL_DL_SQL92_INTERVAL_HOUR				0x00000040L
#define	SQL_DL_SQL92_INTERVAL_MINUTE			0x00000080L
#define SQL_DL_SQL92_INTERVAL_SECOND			0x00000100L
#define SQL_DL_SQL92_INTERVAL_YEAR_TO_MONTH		0x00000200L
#define SQL_DL_SQL92_INTERVAL_DAY_TO_HOUR		0x00000400L
#define SQL_DL_SQL92_INTERVAL_DAY_TO_MINUTE		0x00000800L
#define SQL_DL_SQL92_INTERVAL_DAY_TO_SECOND		0x00001000L
#define SQL_DL_SQL92_INTERVAL_HOUR_TO_MINUTE	0x00002000L
#define SQL_DL_SQL92_INTERVAL_HOUR_TO_SECOND	0x00004000L
#define SQL_DL_SQL92_INTERVAL_MINUTE_TO_SECOND	0x00008000L
*)
{ SQL_CATALOG_LOCATION values }
SQL_CL_START						=SQL_QL_START;
SQL_CL_END						=SQL_QL_END;

(*
/* values for SQL_BATCH_ROW_COUNT */
#define SQL_BRC_PROCEDURES			0x0000001
#define	SQL_BRC_EXPLICIT			0x0000002
#define	SQL_BRC_ROLLED_UP			0x0000004

/* bitmasks for SQL_BATCH_SUPPORT */
#define SQL_BS_SELECT_EXPLICIT				0x00000001L
#define SQL_BS_ROW_COUNT_EXPLICIT			0x00000002L
#define SQL_BS_SELECT_PROC					0x00000004L
#define SQL_BS_ROW_COUNT_PROC				0x00000008L

/* Values for SQL_PARAM_ARRAY_ROW_COUNTS getinfo */
#define SQL_PARC_BATCH		1
#define SQL_PARC_NO_BATCH	2

/* values for SQL_PARAM_ARRAY_SELECT_BATCH*/
#define SQL_PAS_BATCH				1
#define SQL_PAS_NO_BATCH			2
#define SQL_PAS_NO_SELECT			3

/* Bitmasks for SQL_INDEX_KEYWORDS */
#define SQL_IK_NONE							0x00000000L
#define SQL_IK_ASC							0x00000001L
#define SQL_IK_DESC							0x00000002L
#define SQL_IK_ALL							(SQL_IK_ASC | SQL_IK_DESC)
*)
{ Bitmasks for SQL_INFO_SCHEMA_VIEWS }

SQL_ISV_ASSERTIONS					=$00000001;
SQL_ISV_CHARACTER_SETS				=$00000002;
SQL_ISV_CHECK_CONSTRAINTS			=$00000004;
SQL_ISV_COLLATIONS					=$00000008;
SQL_ISV_COLUMN_DOMAIN_USAGE			=$00000010;
SQL_ISV_COLUMN_PRIVILEGES			=$00000020;
SQL_ISV_COLUMNS						=$00000040;
SQL_ISV_CONSTRAINT_COLUMN_USAGE		=$00000080;
SQL_ISV_CONSTRAINT_TABLE_USAGE		=$00000100;
SQL_ISV_DOMAIN_CONSTRAINTS			=$00000200;
SQL_ISV_DOMAINS						=$00000400;
SQL_ISV_KEY_COLUMN_USAGE			=$00000800;
SQL_ISV_REFERENTIAL_CONSTRAINTS		=$00001000;
SQL_ISV_SCHEMATA					=$00002000;
SQL_ISV_SQL_LANGUAGES				=$00004000;
SQL_ISV_TABLE_CONSTRAINTS			=$00008000;
SQL_ISV_TABLE_PRIVILEGES			=$00010000;
SQL_ISV_TABLES						=$00020000;
SQL_ISV_TRANSLATIONS				=$00040000;
SQL_ISV_USAGE_PRIVILEGES			=$00080000;
SQL_ISV_VIEW_COLUMN_USAGE			=$00100000;
SQL_ISV_VIEW_TABLE_USAGE			=$00200000;
SQL_ISV_VIEWS						=$00400000;

{ Bitmasks for SQL_ASYNC_MODE }

SQL_AM_NONE			=0;
SQL_AM_CONNECTION	=1;
SQL_AM_STATEMENT	=2;

(*
/* Bitmasks for SQL_ALTER_DOMAIN */
#define SQL_AD_CONSTRAINT_NAME_DEFINITION			0x00000001L
#define	SQL_AD_ADD_DOMAIN_CONSTRAINT	 			0x00000002L
#define	SQL_AD_DROP_DOMAIN_CONSTRAINT	 			0x00000004L
#define	SQL_AD_ADD_DOMAIN_DEFAULT   	 			0x00000008L
#define	SQL_AD_DROP_DOMAIN_DEFAULT   	 			0x00000010L
#define SQL_AD_ADD_CONSTRAINT_INITIALLY_DEFERRED	0x00000020L
#define SQL_AD_ADD_CONSTRAINT_INITIALLY_IMMEDIATE	0x00000040L
#define SQL_AD_ADD_CONSTRAINT_DEFERRABLE			0x00000080L
#define SQL_AD_ADD_CONSTRAINT_NON_DEFERRABLE		0x00000100L

*)
{ SQL_CREATE_SCHEMA bitmasks }
SQL_CS_CREATE_SCHEMA				=$00000001;
SQL_CS_AUTHORIZATION				=$00000002;
SQL_CS_DEFAULT_CHARACTER_SET		=$00000004;
(*
/* SQL_CREATE_TRANSLATION bitmasks */
#define	SQL_CTR_CREATE_TRANSLATION			0x00000001L

/* SQL_CREATE_ASSERTION bitmasks */
#define	SQL_CA_CREATE_ASSERTION					0x00000001L
#define	SQL_CA_CONSTRAINT_INITIALLY_DEFERRED	0x00000010L
#define	SQL_CA_CONSTRAINT_INITIALLY_IMMEDIATE	0x00000020L
#define	SQL_CA_CONSTRAINT_DEFERRABLE			0x00000040L
#define	SQL_CA_CONSTRAINT_NON_DEFERRABLE		0x00000080L

/* SQL_CREATE_CHARACTER_SET bitmasks */
#define	SQL_CCS_CREATE_CHARACTER_SET		0x00000001L
#define	SQL_CCS_COLLATE_CLAUSE				0x00000002L
#define	SQL_CCS_LIMITED_COLLATION			0x00000004L

/* SQL_CREATE_COLLATION bitmasks */
#define	SQL_CCOL_CREATE_COLLATION			0x00000001L
*)
{ SQL_CREATE_DOMAIN bitmasks }
SQL_CDO_CREATE_DOMAIN					=$00000001;
SQL_CDO_DEFAULT							=$00000002;
SQL_CDO_CONSTRAINT						=$00000004;
SQL_CDO_COLLATION						=$00000008;
SQL_CDO_CONSTRAINT_NAME_DEFINITION		=$00000010;
SQL_CDO_CONSTRAINT_INITIALLY_DEFERRED	=$00000020;
SQL_CDO_CONSTRAINT_INITIALLY_IMMEDIATE	=$00000040;
SQL_CDO_CONSTRAINT_DEFERRABLE			=$00000080;
SQL_CDO_CONSTRAINT_NON_DEFERRABLE		=$00000100;

{ SQL_CREATE_TABLE bitmasks }
SQL_CT_CREATE_TABLE						=$00000001;
SQL_CT_COMMIT_PRESERVE					=$00000002;
SQL_CT_COMMIT_DELETE					=$00000004;
SQL_CT_GLOBAL_TEMPORARY					=$00000008;
SQL_CT_LOCAL_TEMPORARY					=$00000010;
SQL_CT_CONSTRAINT_INITIALLY_DEFERRED	=$00000020;
SQL_CT_CONSTRAINT_INITIALLY_IMMEDIATE	=$00000040;
SQL_CT_CONSTRAINT_DEFERRABLE			=$00000080;
SQL_CT_CONSTRAINT_NON_DEFERRABLE		=$00000100;
SQL_CT_COLUMN_CONSTRAINT				=$00000200;
SQL_CT_COLUMN_DEFAULT					=$00000400;
SQL_CT_COLUMN_COLLATION					=$00000800;
SQL_CT_TABLE_CONSTRAINT					=$00001000;
SQL_CT_CONSTRAINT_NAME_DEFINITION		=$00002000;
(*
/* SQL_DDL_INDEX bitmasks */
#define SQL_DI_CREATE_INDEX						0x00000001L
#define SQL_DI_DROP_INDEX						0x00000002L

/* SQL_DROP_COLLATION bitmasks */
#define	SQL_DC_DROP_COLLATION					0x00000001L

/* SQL_DROP_DOMAIN bitmasks */
#define	SQL_DD_DROP_DOMAIN						0x00000001L
#define	SQL_DD_RESTRICT							0x00000002L
#define	SQL_DD_CASCADE							0x00000004L

/* SQL_DROP_SCHEMA bitmasks */
#define	SQL_DS_DROP_SCHEMA						0x00000001L
#define SQL_DS_RESTRICT							0x00000002L
#define	SQL_DS_CASCADE							0x00000004L

/* SQL_DROP_CHARACTER_SET bitmasks */
#define	SQL_DCS_DROP_CHARACTER_SET				0x00000001L

/* SQL_DROP_ASSERTION bitmasks */
#define	SQL_DA_DROP_ASSERTION					0x00000001L
*)

{ SQL_DROP_TABLE bitmasks }
SQL_DT_DROP_TABLE						=$00000001;
SQL_DT_RESTRICT							=$00000002;
SQL_DT_CASCADE							=$00000004;
(*
/* SQL_DROP_TRANSLATION bitmasks */
#define	SQL_DTR_DROP_TRANSLATION				0x00000001L
*)
{ SQL_DROP_VIEW bitmasks }
SQL_DV_DROP_VIEW						=$00000001;
SQL_DV_RESTRICT							=$00000002;
SQL_DV_CASCADE							=$00000004;

{ SQL_INSERT_STATEMENT bitmasks }
SQL_IS_INSERT_LITERALS					=$00000001;
SQL_IS_INSERT_SEARCHED					=$00000002;
SQL_IS_SELECT_INTO					=$00000004;


{ SQL_ODBC_INTERFACE_CONFORMANCE values }
SQL_OIC_CORE							=$00000001; //=1; //1UL
SQL_OIC_LEVEL1							=$00000002; //=2; //2UL
SQL_OIC_LEVEL2							=$00000003; //=3; //3UL

{ SQL_SQL92_FOREIGN_KEY_DELETE_RULE bitmasks }
SQL_SFKD_CASCADE						=$00000001;
SQL_SFKD_NO_ACTION						=$00000002;
SQL_SFKD_SET_DEFAULT					=$00000004;
SQL_SFKD_SET_NULL						=$00000008;

{ SQL_SQL92_FOREIGN_KEY_UPDATE_RULE bitmasks }
SQL_SFKU_CASCADE						=$00000001;
SQL_SFKU_NO_ACTION						=$00000002;
SQL_SFKU_SET_DEFAULT					=$00000004;
SQL_SFKU_SET_NULL						=$00000008;

{ SQL_SQL92_GRANT	bitmasks }
SQL_SG_USAGE_ON_DOMAIN					=$00000001;
SQL_SG_USAGE_ON_CHARACTER_SET			=$00000002;
SQL_SG_USAGE_ON_COLLATION				=$00000004;
SQL_SG_USAGE_ON_TRANSLATION				=$00000008;
SQL_SG_WITH_GRANT_OPTION				=$00000010;
SQL_SG_DELETE_TABLE						=$00000020;
SQL_SG_INSERT_TABLE						=$00000040;
SQL_SG_INSERT_COLUMN					=$00000080;
SQL_SG_REFERENCES_TABLE					=$00000100;
SQL_SG_REFERENCES_COLUMN				=$00000200;
SQL_SG_SELECT_TABLE						=$00000400;
SQL_SG_UPDATE_TABLE						=$00000800;
SQL_SG_UPDATE_COLUMN					=$00001000;

{ SQL_SQL92_PREDICATES bitmasks }
SQL_SP_EXISTS							=$00000001;
SQL_SP_ISNOTNULL						=$00000002;
SQL_SP_ISNULL							=$00000004;
SQL_SP_MATCH_FULL						=$00000008;
SQL_SP_MATCH_PARTIAL					=$00000010;
SQL_SP_MATCH_UNIQUE_FULL				=$00000020;
SQL_SP_MATCH_UNIQUE_PARTIAL				=$00000040;
SQL_SP_OVERLAPS							=$00000080;
SQL_SP_UNIQUE							=$00000100;
SQL_SP_LIKE								=$00000200;
SQL_SP_IN								=$00000400;
SQL_SP_BETWEEN							=$00000800;
SQL_SP_COMPARISON						=$00001000;
SQL_SP_QUANTIFIED_COMPARISON			=$00002000;

{ SQL_SQL92_RELATIONAL_JOIN_OPERATORS bitmasks }
SQL_SRJO_CORRESPONDING_CLAUSE			=$00000001;
SQL_SRJO_CROSS_JOIN						=$00000002;
SQL_SRJO_EXCEPT_JOIN					=$00000004;
SQL_SRJO_FULL_OUTER_JOIN				=$00000008;
SQL_SRJO_INNER_JOIN						=$00000010;
SQL_SRJO_INTERSECT_JOIN					=$00000020;
SQL_SRJO_LEFT_OUTER_JOIN				=$00000040;
SQL_SRJO_NATURAL_JOIN					=$00000080;
SQL_SRJO_RIGHT_OUTER_JOIN				=$00000100;
SQL_SRJO_UNION_JOIN						=$00000200;

{ SQL_SQL92_REVOKE bitmasks }
SQL_SR_USAGE_ON_DOMAIN					=$00000001;
SQL_SR_USAGE_ON_CHARACTER_SET			=$00000002;
SQL_SR_USAGE_ON_COLLATION				=$00000004;
SQL_SR_USAGE_ON_TRANSLATION				=$00000008;
SQL_SR_GRANT_OPTION_FOR					=$00000010;
SQL_SR_CASCADE							=$00000020;
SQL_SR_RESTRICT							=$00000040;
SQL_SR_DELETE_TABLE						=$00000080;
SQL_SR_INSERT_TABLE						=$00000100;
SQL_SR_INSERT_COLUMN					=$00000200;
SQL_SR_REFERENCES_TABLE					=$00000400;
SQL_SR_REFERENCES_COLUMN				=$00000800;
SQL_SR_SELECT_TABLE						=$00001000;
SQL_SR_UPDATE_TABLE						=$00002000;
SQL_SR_UPDATE_COLUMN					=$00004000;

{ SQL_SQL92_ROW_VALUE_CONSTRUCTOR bitmasks }
SQL_SRVC_VALUE_EXPRESSION				=$00000001;
SQL_SRVC_NULL							=$00000002;
SQL_SRVC_DEFAULT						=$00000004;
SQL_SRVC_ROW_SUBQUERY					=$00000008;

{ SQL_SQL92_VALUE_EXPRESSIONS bitmasks }
SQL_SVE_CASE							=$00000001;
SQL_SVE_CAST							=$00000002;
SQL_SVE_COALESCE						=$00000004;
SQL_SVE_NULLIF							=$00000008;

{ SQL_STANDARD_CLI_CONFORMANCE bitmasks }
SQL_SCC_XOPEN_CLI_VERSION1				=$00000001;
SQL_SCC_ISO92_CLI						=$00000002;

{ SQL_UNION_STATEMENT bitmasks }
SQL_US_UNION							=SQL_U_UNION;
SQL_US_UNION_ALL						=SQL_U_UNION_ALL;

{$endif} //#endif  /* ODBCVER >= 0x0300 */
(*
/* SQL_DTC_TRANSITION_COST bitmasks */
#define SQL_DTC_ENLIST_EXPENSIVE				0x00000001L
#define SQL_DTC_UNENLIST_EXPENSIVE				0x00000002L

/* additional SQLDataSources fetch directions */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_FETCH_FIRST_USER				31
#define SQL_FETCH_FIRST_SYSTEM				32
{$endif} //#endif  /* ODBCVER >= 0x0300 */


/* Defines for SQLSetPos */
#define SQL_ENTIRE_ROWSET            0

/* Operations in SQLSetPos */
#define SQL_POSITION                 0               /*      1.0 FALSE */
#define SQL_REFRESH                  1               /*      1.0 TRUE */
#define SQL_UPDATE                   2
#define SQL_DELETE                   3

/* Operations in SQLBulkOperations */
#define SQL_ADD                      4
#define	SQL_SETPOS_MAX_OPTION_VALUE			SQL_ADD
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_UPDATE_BY_BOOKMARK		 5
#define SQL_DELETE_BY_BOOKMARK		 6
#define	SQL_FETCH_BY_BOOKMARK		 7

{$endif} //#endif /*  ODBCVER >= 0x0300 */

/* Lock options in SQLSetPos */
#define SQL_LOCK_NO_CHANGE           0               /*      1.0 FALSE */
#define SQL_LOCK_EXCLUSIVE           1               /*      1.0 TRUE */
#define SQL_LOCK_UNLOCK              2

#define	SQL_SETPOS_MAX_LOCK_VALUE		SQL_LOCK_UNLOCK

/* Macros for SQLSetPos */
#define SQL_POSITION_TO(hstmt,irow) SQLSetPos(hstmt,irow,SQL_POSITION,SQL_LOCK_NO_CHANGE)
#define SQL_LOCK_RECORD(hstmt,irow,fLock) SQLSetPos(hstmt,irow,SQL_POSITION,fLock)
#define SQL_REFRESH_RECORD(hstmt,irow,fLock) SQLSetPos(hstmt,irow,SQL_REFRESH,fLock)
#define SQL_UPDATE_RECORD(hstmt,irow) SQLSetPos(hstmt,irow,SQL_UPDATE,SQL_LOCK_NO_CHANGE)
#define SQL_DELETE_RECORD(hstmt,irow) SQLSetPos(hstmt,irow,SQL_DELETE,SQL_LOCK_NO_CHANGE)
#define SQL_ADD_RECORD(hstmt,irow) SQLSetPos(hstmt,irow,SQL_ADD,SQL_LOCK_NO_CHANGE)

/* Column types and scopes in SQLSpecialColumns.  */
SQL_BEST_ROWID                  =1;
SQL_ROWVER                      =2;

/* Defines for SQLSpecialColumns (returned in the result set)
   SQL_PC_UNKNOWN and SQL_PC_PSEUDO are defined in sql.h */
#define SQL_PC_NOT_PSEUDO               1

/* Defines for SQLStatistics */
#define SQL_QUICK                       0
#define SQL_ENSURE                      1

/* Defines for SQLStatistics (returned in the result set) 
   SQL_INDEX_CLUSTERED, SQL_INDEX_HASHED, and SQL_INDEX_OTHER are
   defined in sql.h */
#define SQL_TABLE_STAT                  0


/* Defines for SQLTables */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_ALL_CATALOGS				"%"
#define SQL_ALL_SCHEMAS					"%"
#define SQL_ALL_TABLE_TYPES				"%"
{$endif} //#endif  /* ODBCVER >= 0x0300 */
*)
{ Options for SQLDriverConnect }
SQL_DRIVER_NOPROMPT             =0;
SQL_DRIVER_COMPLETE             =1;
SQL_DRIVER_PROMPT               =2;
SQL_DRIVER_COMPLETE_REQUIRED    =3;
(*
#ifndef RC_INVOKED

SQLRETURN SQL_API SQLDriverConnect(
    SQLHDBC            hdbc,
    SQLHWND            hwnd,
    SQLCHAR 		  *szConnStrIn,
    SQLSMALLINT        cbConnStrIn,
    SQLCHAR           *szConnStrOut,
    SQLSMALLINT        cbConnStrOutMax,
    SQLSMALLINT 	  *pcbConnStrOut,
    SQLUSMALLINT       fDriverCompletion);

#endif /* RC_INVOKED */

/* Level 2 Functions                             */

/* SQLExtendedFetch "fFetchType" values */
#define SQL_FETCH_BOOKMARK               8

/* SQLExtendedFetch "rgfRowStatus" element values */
#define SQL_ROW_SUCCESS                  0
#define SQL_ROW_DELETED                  1
#define SQL_ROW_UPDATED                  2
#define SQL_ROW_NOROW                    3
#define SQL_ROW_ADDED                    4
*)
SQL_ROW_ERROR                    =5;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_ROW_SUCCESS_WITH_INFO		 =6;
(*
#define SQL_ROW_PROCEED					 0
#define SQL_ROW_IGNORE					 1
{$endif} //#endif

/* value for SQL_DESC_ARRAY_STATUS_PTR */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#define SQL_PARAM_SUCCESS				0
#define SQL_PARAM_SUCCESS_WITH_INFO		6
#define SQL_PARAM_ERROR					5
#define SQL_PARAM_UNUSED				7
#define SQL_PARAM_DIAG_UNAVAILABLE		1

#define SQL_PARAM_PROCEED				0
#define SQL_PARAM_IGNORE				1
{$endif} //#endif  /* ODBCVER >= 0x0300 */

/* Defines for SQLForeignKeys (UPDATE_RULE and DELETE_RULE) */
#define SQL_CASCADE                      0
#define SQL_RESTRICT                     1
#define SQL_SET_NULL                     2
{$ifdef ODBCVER_GTEQ_0250} //#if (ODBCVER >= 0x0250)
#define SQL_NO_ACTION			 3
#define SQL_SET_DEFAULT			 4
{$endif} //#endif  /* ODBCVER >= 0x0250 */
*)

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
{ Note that the following are in a different column of SQLForeignKeys than }
{ the previous #defines.   These are for DEFERRABILITY.                    }

SQL_INITIALLY_DEFERRED			=5;
SQL_INITIALLY_IMMEDIATE			=6;
SQL_NOT_DEFERRABLE			=7;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

{ Defines for SQLBindParameter and
                           SQLProcedureColumns (returned in the result set) }
SQL_PARAM_TYPE_UNKNOWN           =0;
SQL_PARAM_INPUT                  =1;
SQL_PARAM_INPUT_OUTPUT           =2;
SQL_RESULT_COL                   =3;
SQL_PARAM_OUTPUT                 =4;
SQL_RETURN_VALUE                 =5;

{ Defines for SQLProcedures (returned in the result set) }
SQL_PT_UNKNOWN                   =0;
SQL_PT_PROCEDURE                 =1;
SQL_PT_FUNCTION                  =2;

//#ifndef RC_INVOKED
(*
{      This define is too large for RC }
SQL_ODBC_KEYWORDS=
'ABSOLUTE,ACTION,ADA,ADD,ALL,ALLOCATE,ALTER,AND,ANY,ARE,AS,'+
'ASC,ASSERTION,AT,AUTHORIZATION,AVG,'+
'BEGIN,BETWEEN,BIT,BIT_LENGTH,BOTH,BY,CASCADE,CASCADED,CASE,CAST,CATALOG,'+
'CHAR,CHAR_LENGTH,CHARACTER,CHARACTER_LENGTH,CHECK,CLOSE,COALESCE,'+
'COLLATE,COLLATION,COLUMN,COMMIT,CONNECT,CONNECTION,CONSTRAINT,'+
'CONSTRAINTS,CONTINUE,CONVERT,CORRESPONDING,COUNT,CREATE,CROSS,CURRENT,'+
'CURRENT_DATE,CURRENT_TIME,CURRENT_TIMESTAMP,CURRENT_USER,CURSOR,'+
'DATE,DAY,DEALLOCATE,DEC,DECIMAL,DECLARE,DEFAULT,DEFERRABLE,'+
'DEFERRED,DELETE,DESC,DESCRIBE,DESCRIPTOR,DIAGNOSTICS,DISCONNECT,'+
'DISTINCT,DOMAIN,DOUBLE,DROP,'+
'ELSE,END,END-EXEC,ESCAPE,EXCEPT,EXCEPTION,EXEC,EXECUTE,'+
'EXISTS,EXTERNAL,EXTRACT,'+
'FALSE,FETCH,FIRST,FLOAT,FOR,FOREIGN,FORTRAN,FOUND,FROM,FULL,'+
'GET,GLOBAL,GO,GOTO,GRANT,GROUP,HAVING,HOUR,'+
'IDENTITY,IMMEDIATE,IN,INCLUDE,INDEX,INDICATOR,INITIALLY,INNER,'+
'INPUT,INSENSITIVE,INSERT,INT,INTEGER,INTERSECT,INTERVAL,INTO,IS,ISOLATION,'+
'JOIN,KEY,LANGUAGE,LAST,LEADING,LEFT,LEVEL,LIKE,LOCAL,LOWER,'+
'MATCH,MAX,MIN,MINUTE,MODULE,MONTH,'+
'NAMES,NATIONAL,NATURAL,NCHAR,NEXT,NO,NONE,NOT,NULL,NULLIF,NUMERIC,'+
'OCTET_LENGTH,OF,ON,ONLY,OPEN,OPTION,OR,ORDER,OUTER,OUTPUT,OVERLAPS,'+
'PAD,PARTIAL,PASCAL,PLI,POSITION,PRECISION,PREPARE,PRESERVE,'+
'PRIMARY,PRIOR,PRIVILEGES,PROCEDURE,PUBLIC,'+
'READ,REAL,REFERENCES,RELATIVE,RESTRICT,REVOKE,RIGHT,ROLLBACK,ROWS'+
'SCHEMA,SCROLL,SECOND,SECTION,SELECT,SESSION,SESSION_USER,SET,SIZE,'+
'SMALLINT,SOME,SPACE,SQL,SQLCA,SQLCODE,SQLERROR,SQLSTATE,SQLWARNING,'+
'SUBSTRING,SUM,SYSTEM_USER,'+
'TABLE,TEMPORARY,THEN,TIME,TIMESTAMP,TIMEZONE_HOUR,TIMEZONE_MINUTE,'+
'TO,TRAILING,TRANSACTION,TRANSLATE,TRANSLATION,TRIM,TRUE,'+
'UNION,UNIQUE,UNKNOWN,UPDATE,UPPER,USAGE,USER,USING,'+
'VALUE,VALUES,VARCHAR,VARYING,VIEW,WHEN,WHENEVER,WHERE,WITH,WORK,WRITE,'+
'YEAR,ZONE';
*)
(*
SQLRETURN SQL_API SQLBrowseConnect(
    SQLHDBC            hdbc,
    SQLCHAR 		  *szConnStrIn,
    SQLSMALLINT        cbConnStrIn,
    SQLCHAR 		  *szConnStrOut,
    SQLSMALLINT        cbConnStrOutMax,
    SQLSMALLINT       *pcbConnStrOut);

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQLRETURN	SQL_API	SQLBulkOperations(
	SQLHSTMT			StatementHandle,
	SQLSMALLINT			Operation);
{$endif} //#endif  /* ODBCVER >= 0x0300 */

SQLRETURN SQL_API SQLColAttributes(
    SQLHSTMT           hstmt,
    SQLUSMALLINT       icol,
    SQLUSMALLINT       fDescType,
    SQLPOINTER         rgbDesc,
    SQLSMALLINT        cbDescMax,
    SQLSMALLINT 	  *pcbDesc,
    SQLINTEGER 		  *pfDesc);

SQLRETURN SQL_API SQLColumnPrivileges(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szCatalogName,
    SQLSMALLINT        cbCatalogName,
    SQLCHAR 		  *szSchemaName,
    SQLSMALLINT        cbSchemaName,
    SQLCHAR 		  *szTableName,
    SQLSMALLINT        cbTableName,
    SQLCHAR 		  *szColumnName,
    SQLSMALLINT        cbColumnName);

SQLRETURN SQL_API SQLDescribeParam(
    SQLHSTMT           hstmt,
    SQLUSMALLINT       ipar,
    SQLSMALLINT 	  *pfSqlType,
    SQLUINTEGER 	  *pcbParamDef,
    SQLSMALLINT 	  *pibScale,
    SQLSMALLINT 	  *pfNullable);

SQLRETURN SQL_API SQLExtendedFetch(
    SQLHSTMT           hstmt,
    SQLUSMALLINT       fFetchType,
    SQLINTEGER         irow,
    SQLUINTEGER 	  *pcrow,
    SQLUSMALLINT 	  *rgfRowStatus);

SQLRETURN SQL_API SQLForeignKeys(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szPkCatalogName,
    SQLSMALLINT        cbPkCatalogName,
    SQLCHAR 		  *szPkSchemaName,
    SQLSMALLINT        cbPkSchemaName,
    SQLCHAR 		  *szPkTableName,
    SQLSMALLINT        cbPkTableName,
    SQLCHAR 		  *szFkCatalogName,
    SQLSMALLINT        cbFkCatalogName,
    SQLCHAR 		  *szFkSchemaName,
    SQLSMALLINT        cbFkSchemaName,
    SQLCHAR 		  *szFkTableName,
    SQLSMALLINT        cbFkTableName);

SQLRETURN SQL_API SQLMoreResults(
    SQLHSTMT           hstmt);

SQLRETURN SQL_API SQLNativeSql(
    SQLHDBC            hdbc,
    SQLCHAR 		  *szSqlStrIn,
    SQLINTEGER         cbSqlStrIn,
    SQLCHAR 		  *szSqlStr,
    SQLINTEGER         cbSqlStrMax,
    SQLINTEGER 		  *pcbSqlStr);

SQLRETURN SQL_API SQLNumParams(
    SQLHSTMT           hstmt,
    SQLSMALLINT 	  *pcpar);

SQLRETURN SQL_API SQLParamOptions(
    SQLHSTMT           hstmt,
    SQLUINTEGER        crow,
    SQLUINTEGER 	  *pirow);

SQLRETURN SQL_API SQLPrimaryKeys(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szCatalogName,
    SQLSMALLINT        cbCatalogName,
    SQLCHAR 		  *szSchemaName,
    SQLSMALLINT        cbSchemaName,
    SQLCHAR 		  *szTableName,
    SQLSMALLINT        cbTableName);

SQLRETURN SQL_API SQLProcedureColumns(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szCatalogName,
    SQLSMALLINT        cbCatalogName,
    SQLCHAR 		  *szSchemaName,
    SQLSMALLINT        cbSchemaName,
    SQLCHAR 		  *szProcName,
    SQLSMALLINT        cbProcName,
    SQLCHAR 		  *szColumnName,
    SQLSMALLINT        cbColumnName);

SQLRETURN SQL_API SQLProcedures(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szCatalogName,
    SQLSMALLINT        cbCatalogName,
    SQLCHAR 		  *szSchemaName,
    SQLSMALLINT        cbSchemaName,
    SQLCHAR 		  *szProcName,
    SQLSMALLINT        cbProcName);

SQLRETURN SQL_API SQLSetPos(
    SQLHSTMT           hstmt,
    SQLUSMALLINT       irow,
    SQLUSMALLINT       fOption,
    SQLUSMALLINT       fLock);

SQLRETURN SQL_API SQLTablePrivileges(
    SQLHSTMT           hstmt,
    SQLCHAR 		  *szCatalogName,
    SQLSMALLINT        cbCatalogName,
    SQLCHAR 		  *szSchemaName,
    SQLSMALLINT        cbSchemaName,
    SQLCHAR 		  *szTableName,
    SQLSMALLINT        cbTableName);

SQLRETURN SQL_API SQLDrivers(
    SQLHENV            henv,
    SQLUSMALLINT       fDirection,
    SQLCHAR 		  *szDriverDesc,
    SQLSMALLINT        cbDriverDescMax,
    SQLSMALLINT 	  *pcbDriverDesc,
    SQLCHAR 		  *szDriverAttributes,
    SQLSMALLINT        cbDrvrAttrMax,
    SQLSMALLINT 	  *pcbDrvrAttr);

SQLRETURN SQL_API SQLBindParameter(
    SQLHSTMT           hstmt,
    SQLUSMALLINT       ipar,
    SQLSMALLINT        fParamType,
    SQLSMALLINT        fCType,
    SQLSMALLINT        fSqlType,
    SQLUINTEGER        cbColDef,
    SQLSMALLINT        ibScale,
    SQLPOINTER         rgbValue,
    SQLINTEGER         cbValueMax,
    SQLINTEGER 		  *pcbValue);


#endif /* RC_INVOKED */

/*---------------------------------------------------------*/
/* SQLAllocHandleStd is implemented to make SQLAllocHandle */
/* compatible with X/Open standard.	 an application should */
/* not call SQLAllocHandleStd directly					   */ 
/*---------------------------------------------------------*/
#ifdef ODBC_STD
#define SQLAllocHandle  SQLAllocHandleStd
#define SQLAllocEnv(phenv)  SQLAllocHandleStd(SQL_HANDLE_ENV, SQL_NULL_HANDLE, phenv)

/* Internal type subcodes */
#define SQL_YEAR						SQL_CODE_YEAR
#define SQL_MONTH						SQL_CODE_MONTH
#define SQL_DAY							SQL_CODE_DAY
#define SQL_HOUR						SQL_CODE_HOUR
#define SQL_MINUTE						SQL_CODE_MINUTE
#define SQL_SECOND						SQL_CODE_SECOND
#define SQL_YEAR_TO_MONTH				SQL_CODE_YEAR_TO_MONTH
#define SQL_DAY_TO_HOUR					SQL_CODE_DAY_TO_HOUR
#define SQL_DAY_TO_MINUTE				SQL_CODE_DAY_TO_MINUTE
#define SQL_DAY_TO_SECOND				SQL_CODE_DAY_TO_SECOND
#define SQL_HOUR_TO_MINUTE				SQL_CODE_HOUR_TO_MINUTE
#define SQL_HOUR_TO_SECOND				SQL_CODE_HOUR_TO_SECOND
#define SQL_MINUTE_TO_SECOND			SQL_CODE_MINUTE_TO_SECOND
#endif /* ODBC_STD */

#ifndef RC_INVOKED
SQLRETURN SQL_API SQLAllocHandleStd(
	SQLSMALLINT		fHandleType,
	SQLHANDLE		hInput,
	SQLHANDLE	   *phOutput);
#endif /* RC_INVOKED */

/*      Deprecated defines from prior versions of ODBC */
#define SQL_DATABASE_NAME               16    /* Use SQLGetConnectOption/SQL_CURRENT_QUALIFIER */
#define SQL_FD_FETCH_PREV               SQL_FD_FETCH_PRIOR
#define SQL_FETCH_PREV                  SQL_FETCH_PRIOR
#define SQL_CONCUR_TIMESTAMP            SQL_CONCUR_ROWVER
#define SQL_SCCO_OPT_TIMESTAMP          SQL_SCCO_OPT_ROWVER
#define SQL_CC_DELETE                   SQL_CB_DELETE
#define SQL_CR_DELETE                   SQL_CB_DELETE
#define SQL_CC_CLOSE                    SQL_CB_CLOSE
#define SQL_CR_CLOSE                    SQL_CB_CLOSE
#define SQL_CC_PRESERVE                 SQL_CB_PRESERVE
#define SQL_CR_PRESERVE                 SQL_CB_PRESERVE
/* SQL_FETCH_RESUME is not supported by 2.0+ drivers 
#define SQL_FETCH_RESUME                7    
*/
#define SQL_SCROLL_FORWARD_ONLY         0L    /*-SQL_CURSOR_FORWARD_ONLY */
#define SQL_SCROLL_KEYSET_DRIVEN        (-1L) /*-SQL_CURSOR_KEYSET_DRIVEN */
#define SQL_SCROLL_DYNAMIC              (-2L) /*-SQL_CURSOR_DYNAMIC */
#define SQL_SCROLL_STATIC               (-3L) /*-SQL_CURSOR_STATIC */

/*      Deprecated functions from prior versions of ODBC */
#ifndef RC_INVOKED

SQLRETURN SQL_API SQLSetScrollOptions(    /*      Use SQLSetStmtOptions */
    SQLHSTMT           hstmt,
    SQLUSMALLINT       fConcurrency,
    SQLINTEGER         crowKeyset,
    SQLUSMALLINT       crowRowset);

#endif /* RC_INVOKED */


#ifdef __cplusplus
}                                     /* End of extern "C" { */
#endif  /* __cplusplus */

#if defined(WIN32) 
#include "sqlucode.h"
#endif

// Tracing section

#define		TRACE_VERSION	1000		// Version of trace API

RETCODE	SQL_API TraceOpenLogFile(LPWSTR,LPWSTR,DWORD);// open a trace log file
RETCODE	SQL_API TraceCloseLogFile();			// Request to close a trace log
VOID	SQL_API TraceReturn(RETCODE,RETCODE);	// Processes trace after FN is called
DWORD	SQL_API TraceVersion();					// Returns trace API version

#endif /* __SQLEXT */

*)

{$endif}




{$ifdef ODBC}
(* FROM ODBC SDK SQLTYPES.h
/*********************************************************************
** SQLTYPES.H - This file defines the types used in ODBC
**
** (C) Copyright 1995-1997 By Microsoft Corp.
**
**		Created 04/10/95 for 2.50 specification
**		Updated 12/11/95 for 3.00 specification
*********************************************************************/

#ifndef __SQLTYPES
#define __SQLTYPES

/* if ODBCVER is not defined, assume version 3.00 */
#ifndef ODBCVER
#define ODBCVER	0x0350
#endif  /* ODBCVER */

#ifdef __cplusplus
extern "C" { 			/* Assume C declarations for C++   */
#endif  /* __cplusplus */

/* environment specific definitions */
#ifndef EXPORT
#define EXPORT
#endif

#ifdef WIN32
#define SQL_API  __stdcall
#else
#define SQL_API
#endif

#ifndef RC_INVOKED

/* API declaration data types */
typedef unsigned char   SQLCHAR;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef signed char     SQLSCHAR;
typedef unsigned char   SQLDATE;
typedef unsigned char   SQLDECIMAL;
typedef double          SQLDOUBLE;
typedef double          SQLFLOAT;
{$endif} //#endif
typedef long            SQLINTEGER;
typedef unsigned long   SQLUINTEGER;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef unsigned char   SQLNUMERIC;
{$endif} //#endif
typedef void *          SQLPOINTER;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef float           SQLREAL;
{$endif} //#endif
typedef short           SQLSMALLINT;
typedef unsigned short  SQLUSMALLINT;
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef unsigned char   SQLTIME;
typedef unsigned char   SQLTIMESTAMP;
typedef unsigned char   SQLVARCHAR;
{$endif} //#endif

/* function return type */
typedef SQLSMALLINT     SQLRETURN;

/* generic data structures */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#if defined(WIN32)
typedef void*					SQLHANDLE;
#else
typedef SQLINTEGER		SQLHANDLE;
#endif	/* defined(WIN32) */
typedef SQLHANDLE               SQLHENV;
typedef SQLHANDLE               SQLHDBC;
typedef SQLHANDLE               SQLHSTMT;
typedef SQLHANDLE               SQLHDESC;
{$else} //#else
#if defined(WIN32)
typedef void*					SQLHENV;
typedef void*					SQLHDBC;
typedef void*					SQLHSTMT;
#else
typedef SQLINTEGER              SQLHENV;
typedef SQLINTEGER              SQLHDBC;
typedef SQLINTEGER              SQLHSTMT;
#endif  /* defined(WIN32) */
{$endif} //#endif /* ODBCVER >= 0x0300 */

/* SQL portable types for C */
typedef unsigned char           UCHAR;
typedef signed char             SCHAR;
*)
type
SQLSCHAR=SCHAR;
(*
typedef long int                SDWORD;
typedef short int               SWORD;
typedef unsigned long int       UDWORD;
typedef unsigned short int      UWORD;
typedef UDWORD                  SQLUINTEGER;

typedef signed long             SLONG;
typedef signed short            SSHORT;
typedef unsigned long           ULONG;
typedef unsigned short          USHORT;
typedef double                  SDOUBLE;
typedef double            		LDOUBLE;
typedef float                   SFLOAT;

typedef void*              		PTR;

typedef void*              		HENV;
typedef void*              		HDBC;
typedef void*              		HSTMT;

typedef signed short            RETCODE;

#if defined(WIN32) || defined(OS2)
typedef HWND                    SQLHWND;
#elif defined (UNIX)
typedef Widget                  SQLHWND;
#else
/* placehold for future O/S GUI window handle definition */
typedef SQLPOINTER              SQLHWND;
#endif

#ifndef	__SQLDATE
#define	__SQLDATE
*)
{ transfer types for DATE, TIME, TIMESTAMP }
(*
typedef struct tagDATE_STRUCT
{
        SQLSMALLINT    year;
        SQLUSMALLINT   month;
        SQLUSMALLINT   day;
} DATE_STRUCT;
*)
type

DATE_STRUCT=record
  year:SQLSMALLINT;
  month:SQLUSMALLINT;
  day:SQLUSMALLINT;
end; {DATE_STRUCT}
(*
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
*)
SQL_DATE_STRUCT=DATE_STRUCT;
(*
{$endif} //#endif  /* ODBCVER >= 0x0300 */

typedef struct tagTIME_STRUCT
{
        SQLUSMALLINT   hour;
        SQLUSMALLINT   minute;
        SQLUSMALLINT   second;
} TIME_STRUCT;
*)
TIME_STRUCT=record
  hour:SQLUSMALLINT;
  minute:SQLUSMALLINT;
  second:SQLUSMALLINT;
end; {TIME_STRUCT}

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_TIME_STRUCT=TIME_STRUCT;
{$endif} //#endif /* ODBCVER >= 0x0300 */
(*
typedef struct tagTIMESTAMP_STRUCT
{
        SQLSMALLINT    year;
        SQLUSMALLINT   month;
        SQLUSMALLINT   day;
        SQLUSMALLINT   hour;
        SQLUSMALLINT   minute;
        SQLUSMALLINT   second;
        SQLUINTEGER    fraction;
} TIMESTAMP_STRUCT;
*)
TIMESTAMP_STRUCT=record
  year:SQLSMALLINT;
  month:SQLUSMALLINT;
  day:SQLUSMALLINT;
  hour:SQLUSMALLINT;
  minute:SQLUSMALLINT;
  second:SQLUSMALLINT;
  fraction:SQLUINTEGER;
end; {TIMESTAMP_STRUCT}

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
SQL_TIMESTAMP_STRUCT=TIMESTAMP_STRUCT;
{$endif} //#endif  /* ODBCVER >= 0x0300 */

(*
/*
 * enumerations for DATETIME_INTERVAL_SUBCODE values for interval data types
 * these values are from SQL-92
 */

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef enum
{
	SQL_IS_YEAR						= 1,
	SQL_IS_MONTH					= 2,
	SQL_IS_DAY						= 3,
	SQL_IS_HOUR						= 4,
	SQL_IS_MINUTE					= 5,
	SQL_IS_SECOND					= 6,
	SQL_IS_YEAR_TO_MONTH			= 7,
	SQL_IS_DAY_TO_HOUR				= 8,
	SQL_IS_DAY_TO_MINUTE			= 9,
	SQL_IS_DAY_TO_SECOND			= 10,
	SQL_IS_HOUR_TO_MINUTE			= 11,
	SQL_IS_HOUR_TO_SECOND			= 12,
	SQL_IS_MINUTE_TO_SECOND			= 13
} SQLINTERVAL;

{$endif} //#endif  /* ODBCVER >= 0x0300 */

{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
typedef struct tagSQL_YEAR_MONTH
{
		SQLUINTEGER		year;
		SQLUINTEGER		month;
} SQL_YEAR_MONTH_STRUCT;

typedef struct tagSQL_DAY_SECOND
{
		SQLUINTEGER		day;
		SQLUINTEGER		hour;
		SQLUINTEGER		minute;
		SQLUINTEGER		second;
		SQLUINTEGER		fraction;
} SQL_DAY_SECOND_STRUCT;

typedef struct tagSQL_INTERVAL_STRUCT
{
	SQLINTERVAL		interval_type;
	SQLSMALLINT		interval_sign;
	union {
		SQL_YEAR_MONTH_STRUCT		year_month;
		SQL_DAY_SECOND_STRUCT		day_second;
	} intval;

} SQL_INTERVAL_STRUCT;

{$endif} //#endif  /* ODBCVER >= 0x0300 */

#endif	/* __SQLDATE	*/

/* the ODBC C types for SQL_C_SBIGINT and SQL_C_UBIGINT */
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
#if (_MSC_VER >= 900)
#define ODBCINT64	__int64
{$endif} //#endif

/* If using other compilers, define ODBCINT64 to the
	approriate 64 bit integer type */
#ifdef ODBCINT64
typedef ODBCINT64	SQLBIGINT;
typedef unsigned ODBCINT64	SQLUBIGINT;
#endif
#endif  /* ODBCVER >= 0x0300 */
*)

{ internal representation of numeric data type }
{$ifdef ODBCVER_GTEQ_0300} //#if (ODBCVER >= 0x0300)
(*
#define SQL_MAX_NUMERIC_LEN		16
typedef struct tagSQL_NUMERIC_STRUCT
{
	SQLCHAR		precision;
	SQLSCHAR	scale;
	SQLCHAR		sign;	/* 1 if positive, 0 if negative */
	SQLCHAR		val[SQL_MAX_NUMERIC_LEN];
} SQL_NUMERIC_STRUCT;
*)
const
SQL_MAX_NUMERIC_LEN=16;
type
pSQL_NUMERIC_STRUCT=^SQL_NUMERIC_STRUCT;
SQL_NUMERIC_STRUCT=record
  precision:SQLCHAR;  //treat as byte
  scale:SQLSCHAR;     //treat as shortint
  sign:SQLCHAR;  // 1 if positive, 0 if negative
  val:array [0..SQL_MAX_NUMERIC_LEN-1] of SQLCHAR;
end; {SQL_NUMERIC_STRUCT}
{$endif} //#endif  /* ODBCVER >= 0x0300 */
(*
{$ifdef ODBCVER_GTEQ_0350} //#if (ODBCVER >= 0x0350)
#ifdef GUID_DEFINED
typedef GUID	SQLGUID;
#else
/* size is 16 */
typedef struct  tagSQLGUID
{
    DWORD Data1;
    WORD Data2;
    WORD Data3;
    BYTE Data4[ 8 ];
} SQLGUID;
#endif  /* GUID_DEFINED */
{$endif} //#endif  /* ODBCVER >= 0x0350 */

typedef unsigned long int       BOOKMARK;

#ifdef _WCHAR_T_DEFINED
typedef wchar_t SQLWCHAR;
#else
typedef unsigned short SQLWCHAR;
#endif

#ifdef UNICODE
typedef SQLWCHAR        SQLTCHAR;
#else
typedef SQLCHAR         SQLTCHAR;
#endif  /* UNICODE */



#endif     /* RC_INVOKED */


#ifdef __cplusplus
}                                    /* End of extern "C" { */
#endif  /* __cplusplus */

#endif /* #ifndef __SQLTYPES */

*)

{$endif}


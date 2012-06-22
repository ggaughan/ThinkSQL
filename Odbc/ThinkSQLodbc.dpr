library ThinkSQLodbc;

{ Important note about DLL memory management: ShareMem must be the
  first unit in your library's USES clause AND your project's (select
  View-Project Source) USES clause if your DLL exports any procedures or
  functions that pass strings as parameters or function results. This
  applies to all strings passed to and from your DLL--even those that
  are nested in records and classes. ShareMem is the interface unit to
  the DELPHIMM.DLL shared memory manager, which must be deployed along
  with your DLL. To avoid using DELPHIMM.DLL, pass string information
  using PChar or ShortString parameters. }


{$DEFINE NO_SQLGETDIAGREC} //hide SQLgetDiagRec to allow SQLerror to be called with correct buffer size
                           //(else most callers would only pass buffer size of 1 & not re-call!)
                           //Note: also needed to be defined in uMain to prevent publication

uses
  SysUtils,
  Classes,
  uMain in 'uMain.pas',
  uEnv in 'uEnv.pas',
  uGlobal in 'uGlobal.pas',
  uDbc in 'uDbc.pas',
  uDiagnostic in 'uDiagnostic.pas',
  uStrings in 'uStrings.pas',
  uStmt in 'uStmt.pas',
  uDesc in 'uDesc.pas',
  uMarshal in 'uMarshal.pas',
  fmConnect in 'fmConnect.pas' {frmConnect},
  uDataType in 'uDataType.pas',
  uMarshalGlobal in 'uMarshalGlobal.pas';

{$R *.res}
{$R version.RES}

exports
  {Note: heading categorisation taken from SQL99 Complete, Really}

  {Essential}                            //Work done
  SQLAllocHandle            index 1,     //90%
  SQLCloseCursor            index 2,     //90%
  SQLConnect                index 3,     //70%
  SQLDisconnect             index 4,     //90%
  SQLEndTran                index 5,
  SQLExecute                index 6,     //60%
  SQLFetchScroll            index 7,     //60%
  SQLFreeHandle             index 8,     //70%
  SQLGetDescField           index 9,     //60%
  SQLGetDiagField           index 10,    //80%
  SQLGetInfo                index 11,    //50%
  SQLGetStmtAttr            index 12,    //80%
  SQLPrepare                index 13,    //70%
  SQLSetCursorName          index 14,
  SQLSetDescField           index 15,    //60%

  {Useful}
  SQLBindCol                index 16,    //60%
  SQLBindParameter          index 17,
  SQLColAttribute           index 18,    //80%
  SQLDescribeCol            index 19,    //90%
  SQLExecDirect             index 20,    //90%
  SQLFetch                  index 21,    //90%
  {$IFNDEF NO_SQLGETDIAGREC}
  SQLGetDiagRec             index 22,    //90%
  {$ENDIF}
  SQLNumResultCols          index 23,    //90%
  SQLRowCount               index 24,    //90%
  SQLGetData                index 25,    //00%
  SQLSetStmtAttr            index 26,

  //leave number gap //TODO*** renumber when done! //todo maybe use ODBC numbers?

  {other stuff we need for ODBC 3.x
   sqlbrowseconnect
   sqlcopydesc sqldescribeparam sqlextendedfetch
   sqlgetdescrec
   sqlmoreresults sqlnativesql
   etc...
  }

  //todo where? MS ODBC only?
  SQLDriverConnect          index 101,
  SQLNumParams              index 102,
  SQLBrowseConnect          index 103,
  (*
  SQLBulkOperations         index 104, //debug ADO
  SQLNativeSql              index 105, //debug ADO
  SQLMoreResults            index 106, //debug ADO
  SQLDescribeParam          index 107, //debug ADO
  SQLExtendedFetch          index 108, //debug ADO
  *)


  {Note: reserve index 199 - in ODBC 2 a dummy function here indicates
         that the functions should be linked by index
  }

  {Minor}
  SQLGetEnvAttr             index 200,  //for ODBC 3
  SQLGetFunctions           index 201,
  SQLGetCursorName          index 202,
  SQLCancel                 index 203,
  SQLParamData              index 204,
  SQLPutData                index 205,

  {Useless - required for ODBC}
  SQLSetEnvAttr             index 220,  //for ODBC 3
  SQLSetConnectAttr         index 221,
  SQLGetConnectAttr         index 222,
  //SQLSetPos                 index 223, //debug ADO

  {Junk - required for ODBC}
  {Note: the good thing about these is that they can be called using existing
         ODBC functions, so they do not form part of the server's true API definition
         and are contained totally within the ODBC driver (helped by the INFORMATION_SCHEMA)}
  SQLTables                 index 230,
  SQLGetTypeInfo            index 231,
  SQLColumns                index 232,
  SQLPrimaryKeys            index 233,
  SQLTablePrivileges        index 234,
  SQLColumnPrivileges       index 235,
  SQLForeignKeys            index 236,
  SQLStatistics             index 237,
  SQLSpecialColumns         index 238,
  SQLProcedures             index 239,
  SQLProcedureColumns       index 240,

  {Obsolescent}
  SQLFreeStmt               index 250,   //needed for ODBC test Bind All etc. & Core conformance!
  SQLError                  index 251    //avoid 1 char message buffer before connected with SQLgetDiagRec
  ;

begin
end.

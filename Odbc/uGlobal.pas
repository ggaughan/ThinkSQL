{$IFNDEF DBEXP_STATIC}
unit uGlobal;

{$IFDEF DEBUG_LOG}
  //use following switch in conjunction with DEBUGDETAIL in uMain
  //todo remove when live!
  //todo also: assumes not re-entrant, i.e. single client (so not Delphi!)
  {$DEFINE DEBUG_LOG_TO_FILE}
  {$DEFINE DEBUG_FLUSH}
  //{$DEFINE DEBUG_LOG_TO_SCREEN}
{$ENDIF}

interface
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}
procedure log(s:string);

const
  ok=0;
  fail=-1;
  CRLF=#13#10;

  driverName='ThinkSQL'; //todo - replace with driver filename!
  driverVer{version}='01.03.0000';

  SQL_SPEC_MAJOR     =3;     	// Major version of specification
  //todo: too high?=ADO Delphi debug SQL_SPEC_MAJOR     =3;     	// Major version of specification

  //todo: too high=MDAC NT 4 pack 3 = fail! SQL_SPEC_MINOR	   =50;     	// Minor version of specification
  //todo: too high=MDAC NT 4 pack 3 = fail! SQL_SPEC_STRING   ='03.50';	// String constant for version  //todo add .0000
  SQL_SPEC_MINOR	   =00;     	// Minor version of specification
  SQL_SPEC_STRING   ='03.00';	// String constant for version  //todo add .0000

  Vendor='ThinkSQL';
  ODBC_component='ODBC ThinkSQL driver';

  SEARCH_PATTERN_ESCAPE='\';
  LIKE_ALL='%';
  LIKE_ONE='_';

  clientCLIversion=0100;             //client parameter passing version
  {                0092   last used 00.04.09 beta (Server 00.04.09) - now pass bufferLen in SQLgetData for blob chunking & widths as integer and handshake sends extra
                   0091   last used 00.04.02 beta (Server 00.04.04) - now pass stored procedure result sets
  }

  {todo: use same as for server -> need to share another constants unit}
  catalog_definition_schemaName='CATALOG_DEFINITION_SCHEMA'; //todo eventually no need - will be invisible - so remove from here to ensure!
  information_schemaName='INFORMATION_SCHEMA';

  defaultHost='localhost';
  defaultService='thinksql';
  defaultPort=9075;
  defaultServer='thinksql'; //default catalog=first one loaded on this server

  {Keyword value pair constant used in sqlDriverConnect and as DSN registry entries}
  kHOST='HOST';
  kSERVICE='SERVICE';
  kSERVER='SERVER';

  INIFilename='ODBC.INI';
  MAX_RETBUF=512; //todo ok?
{$ENDIF}

{$IFNDEF DBEXP_STATIC}

implementation

{$IFDEF DEBUG_LOG_TO_SCREEN}
uses Dialogs;
{$ENDIF}

{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
{$IFDEF DEBUG_LOG_TO_FILE}
var
  logF:text;
{$ENDIF}

procedure log(s:string);
begin
  //todo dump to trace file instead...
  {$IFDEF DEBUG_LOG_TO_FILE}
  writeln(logF,s);
  {$IFDEF DEBUG_FLUSH}
  flush(logF);
  {$ENDIF}
  {$ENDIF}

  {$IFDEF DEBUG_LOG_TO_SCREEN}
  messageDlg(s,mtInformation,[mbok],0);
  {$ENDIF}
end;
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
{$IFDEF DEBUG_LOG_TO_FILE}
initialization
  assignFile(logF,'sqlodbc.log');
  rewrite(logF);

finalization
  closeFile(logF);
{$ENDIF}


end.
{$ENDIF}


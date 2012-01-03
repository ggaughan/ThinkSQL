library sqlthink;

{ Important note about shared object exception handling:  In 
  order for exception handling to work across multiple modules, 
  ShareExcept must be the first unit in your library's USES 
  clause AND your project's (select Project-View Source) USES
  clause if 1) your project loads (either directly or indirectly) 
  more than one Kylix-built shared object, and 2) your project or 
  the shared object are not built with runtime packages (baseclx).
  ShareExcept is the interface unit to the dynamic exception 
  unwinder (libunwind.so.6), which must be deployed along with 
  your shared object. }

uses
  uMainDB in 'uMainDB.pas',
  uLog in 'uLog.pas',
  uSQLDriver in 'uSQLDriver.pas',
  uSQLConnection in 'uSQLConnection.pas',
  uSQLCommand in 'uSQLCommand.pas',
  uGlobalDB in 'uGlobalDB.pas',
  uSQLMetaData in 'uSQLMetaData.pas',
  uSQLCursor in 'uSQLCursor.pas';

{$IFDEF MSWINDOWS}
  {$R *.res}
  {$R version.RES}  
{$ENDIF}

exports
  getSQLDriverTHINKSQL;

begin
end.

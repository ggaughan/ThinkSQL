program ThinkSQLODBCinstall;

uses
  Forms,
  uMain in 'uMain.pas';

{$R *.RES}
{$R version.RES}

begin
  Application.Initialize;
  Application.Title := 'ThinkSQLODBCinstall';
  Application.Run;
  uMain.Main;
end.

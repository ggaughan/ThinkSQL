program ThinkSQLdbExpressInstall;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

uses
  Forms,
  uMain in 'uMain.pas';

{$R *.res}
{$R version.RES}

begin
  Application.Initialize;
  Application.Title := 'ThinkSQLdbExpressInstall';
  Application.Run;
  Main;
end.

program ISQLraw;

uses
  Forms,
  fmISQLmain in 'fmISQLmain.pas' {frmISQLmain},
  fmConnection in 'fmConnection.pas' {frmConnection};

{$R *.res}

begin
  Application.Initialize;
  Application.Title := 'ISQL (raw)';
  Application.CreateForm(TfrmISQLmain, frmISQLmain);
  Application.CreateForm(TfrmConnection, frmConnection);
  Application.Run;
end.

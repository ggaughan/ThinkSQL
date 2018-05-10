program TestSuite;

uses
  Forms,
  fmMain in 'fmMain.pas' {frmMain},
  fmStart in 'fmStart.pas' {frmStart};

{$R *.RES}

begin
  Application.Initialize;
  Application.CreateForm(TfrmStart, frmStart);
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.

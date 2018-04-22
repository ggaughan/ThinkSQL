unit fmStart;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  ExtCtrls, StdCtrls, Buttons, FileCtrl;

type
  TfrmStart = class(TForm)
    pnlClient: TPanel;
    pnlBottom: TPanel;
    btnTest: TBitBtn;
    flbSuites: TFileListBox;
    procedure btnTestClick(Sender: TObject);
    procedure flbSuitesDblClick(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
  end;

var
  frmStart: TfrmStart;

implementation

uses fmMain, iniFiles;

{$R *.DFM}

procedure TfrmStart.btnTestClick(Sender: TObject);
var
  suiteINI:TIniFile;
  suiteTitle:string;
  suitePath:string;
  suiteUsername:string;
  suitePassword:string;
begin
  if flbSuites.itemIndex=-1 then exit;

  suiteINI:=TIniFile.create(flbSuites.FileName);
  try
    suiteTitle:=suiteINI.readString('Title','Title','Test Suite');
    frmMain.pnlTop.caption:=' '+suiteTitle;

    suitePath:=suiteINI.readString('Location','Dir','');
    frmMain.dir:=suitePath;

    suiteUsername:=suiteINI.readString('Connect','Username','DEFAULT');
    suitePassword:=suiteINI.readString('Connect','Password','');

    frmMain.dbTest.Params.Clear;
    frmMain.dbTest.Params.Add('USER NAME='+suiteUsername);
    if suitePassword<>'' then
    begin
      frmMain.dbTest.Params.Add('PASSWORD='+suitePassword);
      frmMain.dbTest.LoginPrompt:=False;
    end
    else
      frmMain.dbTest.LoginPrompt:=True;

    frmMain.dbTest.Open;
    try
      frmMain.ShowModal;
    finally
      frmMain.dbTest.Close;
    end; {try}
  finally
    suiteINI.free;
end; {try}

end;

procedure TfrmStart.flbSuitesDblClick(Sender: TObject);
begin
  btnTest.Click;
end;

end.

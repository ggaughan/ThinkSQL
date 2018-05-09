unit fmStart;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  ExtCtrls, StdCtrls, Buttons, FileCtrl;

type
  TfrmStart = class(TForm)
    pnlClient :TPanel;
    pnlBottom :TPanel;
    btnTest   :TBitBtn;
    flbSuites :TFileListBox;
    procedure btnTestClick      (Sender: TObject);
    procedure flbSuitesDblClick (Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
    constructor Create(aOwner: TComponent); override;
  end;

var
  frmStart: TfrmStart;

implementation

uses
  fmMain, iniFiles, StrUtils;

{$R *.DFM}

function IsRelativePath(const aPath:String):Boolean;
begin
  Result := AnsiStartsText('.\', aPath) or AnsiStartsText('..\', aPath);
end;

procedure TfrmStart.btnTestClick(Sender: TObject);
var
  vSuiteINI      :TIniFile;
  vSuiteTitle    :string;
  vSuitePath     :string;
  vSuiteUsername :string;
  vSuitePassword :string;
begin
  if flbSuites.itemIndex=-1 then exit;

  vSuiteINI:=TIniFile.create(flbSuites.FileName);
  try
    vSuiteTitle:=vSuiteINI.readString('Title','Title','Test Suite');
    frmMain.pnlTop.Caption:=' '+vSuiteTitle;

    vSuitePath  := vSuiteINI.readString('Location','Dir','');
    //ExtractFilePath always returns the ending path delimiter
    if IsRelativePath(vSuitePath) then vSuitePath := ExpandFileName(ExtractFilePath(Application.ExeName)+vSuitePath);
    if not DirectoryExists(vSuitePath) then ShowMessage('Invalid path : ' + vSuitePath);

    frmMain.dir := vSuitePath;

    vSuiteUsername := vSuiteINI.readString('Connect','Username','DEFAULT');
    vSuitePassword := vSuiteINI.readString('Connect','Password','');

    frmMain.dbTest.Params.Clear;
    frmMain.dbTest.Params.Add  ('USER NAME='+vSuiteUsername);
    if vSuitePassword<>'' then begin
      frmMain.dbTest.Params.Add('PASSWORD='+vSuitePassword);
      frmMain.dbTest.LoginPrompt:=False;
    end else
      frmMain.dbTest.LoginPrompt:=True;

    frmMain.dbTest.Open;
    try
      frmMain.ShowModal;
    finally
      frmMain.dbTest.Close;
    end; {try}
  finally
    vSuiteINI.free;
  end; {try}

end;

constructor TfrmStart.Create(aOwner: TComponent);
begin
  inherited;
  flbSuites.Directory := ExtractFilePath(Application.ExeName);
end;

procedure TfrmStart.flbSuitesDblClick(Sender: TObject);
begin
  btnTest.Click;
end;

end.

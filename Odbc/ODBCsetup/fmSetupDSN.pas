unit fmSetupDSN;

interface

uses Windows, SysUtils, Classes, Graphics, Forms, Controls, StdCtrls, 
  Buttons, ExtCtrls, dialogs;

type
  TfrmSetupDSN = class(TForm)
    pnlBottom: TPanel;
    OKBtn: TButton;
    CancelBtn: TButton;
    gbDSN: TGroupBox;
    edDSN: TEdit;
    gbTarget: TGroupBox;
    Server: TLabel;
    edHost: TEdit;
    Port: TLabel;
    edService: TEdit;
    gbLogon: TGroupBox;
    edUID: TEdit;
    Authorization: TLabel;
    Password: TLabel;
    edPWD: TEdit;
    Catalog: TLabel;
    edServer: TEdit;
    procedure OKBtnClick(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
  end;

implementation

{$R *.DFM}

procedure TfrmSetupDSN.OKBtnClick(Sender: TObject);
begin
  if trim(edDSN.text)='' then
  begin
    showMessage('You must supply a data source name');
    modalResult:=mrNone;
  end;
end;

end.

unit fmConnection;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  StdCtrls, Buttons;

type
  TfrmConnection = class(TForm)
    gbTCPIP: TGroupBox;
    edHost: TEdit;
    Label1: TLabel;
    Label2: TLabel;
    edService: TEdit;
    BitBtn1: TBitBtn;
    BitBtn2: TBitBtn;
  private
    { Private declarations }
  public
    { Public declarations }
  end;

var
  frmConnection: TfrmConnection;

implementation

{$R *.dfm}

end.

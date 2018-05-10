unit Unit1;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, AeroButtons, StdCtrls, AdvEdit, AdvEdBtn, AdvFileNameEdit;

type
  TForm1 = class(TForm)
    AdvFileNameEdit1 :TAdvFileNameEdit;
    AeroSpeedButton1 :TAeroSpeedButton;
    procedure AeroSpeedButton1Click(Sender: TObject);
  private
    { Private declarations }
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation
uses StrUtils;
{$R *.dfm}

procedure TForm1.AeroSpeedButton1Click(Sender: TObject);
var
  vStl:TStringList;
  vCntr: Integer;
  procedure SkipToNextLine;//inline;
  begin
    while not AnsiStartsText('{$ENDIF}',Trim(vStl[vCntr])) do
      Inc(vCntr);
    if AnsiStartsText('{$ENDIF}',Trim(vStl[vCntr])) then Inc(vCntr);
  end;
var
  vStr:String;
begin
  if FileExists(AdvFileNameEdit1.FileName) then begin
    vStl := TStringList.Create;
    try
      vStl.LoadFromFile(AdvFileNameEdit1.FileName);
      vCntr := 0;
      while vCntr < vStl.Count do begin
        vStr:= vStl.Strings[vCntr];
        vStr:= Trim(vStr);
        if AnsiStartsText('{$IFDEF DEBUG_LOG}',vStr) then SkipToNextLine
        else if AnsiStartsText('Log.Add',vStr)  then begin
          vStl.Insert(vCntr+1,'{$ENDIF}');
          vStl.Insert(vCntr,'{$IFDEF Debug_Log}');
          Inc(vCntr);
        end;
        inc(vCntr);
      end;
      vStr := ChangeFileExt(advFileNameEdit1.FileName,'.New');
      vStl.SaveToFile(vStr);
      ShowMessage('Saved at '+vStr);
    finally
      vStl.Free;
    end;
  end;
end;

end.

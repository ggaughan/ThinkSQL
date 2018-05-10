unit fmISQLmain;

{Generic test ISQL.
 Not really part of ThinkSQL (not good enough)
 I suppose it could connect to other servers?
}

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  Menus, ExtCtrls, StdCtrls, ComCtrls, Buttons, IdBaseComponent,
  IdComponent, IdTCPConnection, IdTCPClient, ToolWin;

type
  TListener=class(TThread)
    procedure Execute; override;
    procedure UpdateScreen;
  private
    lastText:string;
    connection: TIdTCPClient;
  end;

  TfrmISQLmain = class(TForm)
    pnlHeader: TPanel;
    pnlResult: TPanel;
    MainMenu1: TMainMenu;
    File1: TMenuItem;
    Open1: TMenuItem;
    Exit1: TMenuItem;
    pnlCommand: TPanel;
    Save1: TMenuItem;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    Splitter1: TSplitter;
    Connection1: TMenuItem;
    Connect3: TMenuItem;
    Disconnect2: TMenuItem;
    Help1: TMenuItem;
    About1: TMenuItem;
    Options2: TMenuItem;
    lblSend: TLabel;
    shCircle: TShape;
    IdTCPClient1: TIdTCPClient;
    reResult: TRichEdit;
    reCommand: TRichEdit;
    pnlCommandHeader: TPanel;
    pnlResultHeader: TPanel;
    StatusBar1: TStatusBar;
    pnlFooter: TPanel;
    Panel1: TPanel;
    ToolBar1: TToolBar;
    SpeedButton1: TSpeedButton;
    SpeedButton2: TSpeedButton;
    ToolButton1: TToolButton;
    btnExecute: TBitBtn;
    Querystatus1: TMenuItem;
    procedure Disconnect1Click(Sender: TObject);
    procedure btnExecuteClick(Sender: TObject);
    procedure Options1Click(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure Exit1Click(Sender: TObject);
    procedure Open1Click(Sender: TObject);
    procedure Save1Click(Sender: TObject);
    procedure Connect3Click(Sender: TObject);
    procedure Disconnect2Click(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure SpeedButton1Click(Sender: TObject);
    procedure SpeedButton2Click(Sender: TObject);
    procedure About1Click(Sender: TObject);
    procedure Options2Click(Sender: TObject);
    procedure IdTCPClient1Connected(Sender: TObject);
    procedure IdTCPClient1Disconnected(Sender: TObject);
    procedure Querystatus1Click(Sender: TObject);
  private
    { Private declarations }
    history:TstringList;
    historyCursor:integer;

    networkError:boolean;
    listener:TListener;
  public
    { Public declarations }
    IDservice:string;
  end;


var
  frmISQLmain: TfrmISQLmain;

implementation

{$R *.dfm}
{$R version.RES}

uses fmConnection, IdGlobal, IdStack, IdException;

const
  ENDOFSQLENTRY=';';
  ENDOFSQLENTRYBLOCK='.';
  CRLF=#13#10;
  //todo remove ENDOFSQLRESULTS=#26;    //todo use CTRL+Z for telnet 255; //TODO improve & keep in sync with server code!

  TCPhost='localhost';
  TCPservice='thinkSQL';
  TCPport=9075;

procedure TfrmISQLmain.Disconnect1Click(Sender: TObject);
begin
 IdTCPClient1.Disconnect;
 reResult.clear;
end;

procedure TfrmISQLmain.btnExecuteClick(Sender: TObject);
var
  s:string;
  p:pchar; //todo make global
  sent:integer; //todo "
begin
  s:=trimRight(reCommand.text);
  history.Add(s);
  historyCursor:=history.Count-1;
  (*
  if copy(s,length(s),1)<>ENDOFSQLENTRY then
    s:=s+ENDOFSQLENTRY;   //mark end of transmission, so server can start processing
  *)

  (*
  s:=s+CRLF;
  p:=pchar(s);
  sent:=ClientSocket1.Socket.SendBuf(p^,length(p));
  if sent<>length(p) then
    lblSend.caption:='Not connected'
  else
  begin
    lblSend.caption:='';
    reResult.clear;
    reCommand.SetFocus;
    reCommand.SelectAll; //so next command can just be typed to auto-overwrite
  end;
  *)

  IdTCPClient1.WriteLn(s+CRLF+ENDOFSQLENTRYBLOCK); //mark end of transmission, so server knows when to stop processing & can skip ; within routines

  (*todo remove
  //IdTCPClient1.WriteStrings(reCommand.Lines);
  for sent:=0 to reCommand.Lines.Count-1 do
    IdTCPClient1.writeln(reCommand.Lines[sent]);
  if copy(s,length(s),1)<>ENDOFSQLENTRY then
    IdTCPClient1.Writeln(ENDOFSQLENTRY);   //mark end of transmission, so server can start processing
  *)
  lblSend.caption:='';
  reResult.clear;
  reCommand.SetFocus;
  reCommand.SelectAll; //so next command can just be typed to auto-overwrite
end;


procedure TfrmISQLmain.Options1Click(Sender: TObject);
var
  conOpt:TfrmConnection;
begin
  conOpt:=TfrmConnection.Create(nil);
  try
    conOpt.edHost.Text:=IdTCPClient1.Host;
    conOpt.edService.Text:=IDservice;
    if conOpt.ShowModal=mrOk then
    begin //save changes
      IdTCPClient1.Host:=conOpt.edHost.Text;
      IdTCPClient1.Port:=GStack.WSGetServByName(conOpt.edService.Text);
      IDservice:=conOpt.edService.Text;
    end;
  finally
    conOpt.free;
  end; {try}
end;

procedure TfrmISQLmain.FormClose(Sender: TObject;
  var Action: TCloseAction);
var
  i:integer;
begin
 IdTCPClient1.Disconnect;
 {
 if IdTCPClient1.connected then
 begin
   IdTCPClient1.Disconnect;
   i:=0;
   while (listener<>nil) and (i<3) do
   begin
     sleep(1000);
     inc(i);
   end;
 end;
 }
end;

procedure TfrmISQLmain.Exit1Click(Sender: TObject);
begin
  close;
end;

procedure TfrmISQLmain.Open1Click(Sender: TObject);
begin
  if OpenDialog1.Execute then
  begin
    try
      reCommand.Lines.LoadFromFile(OpenDialog1.filename);
    except
      on E:Exception do
        messageDlg('Load error: '+E.message,mtError,[mbok],0);
    end; {try}
  end;
end;

procedure TfrmISQLmain.Save1Click(Sender: TObject);
begin
  SaveDialog1.FileName:=OpenDialog1.filename; //use last loaded name
  if SaveDialog1.Execute then
  begin
    try
      reCommand.Lines.SaveToFile(SaveDialog1.filename);
    except
      on E:Exception do
        messageDlg('Save error: '+E.message,mtError,[mbok],0);
    end; {try}
  end;
end;


procedure TfrmISQLmain.Connect3Click(Sender: TObject);
begin
(*  Connect2.Click;

  lblSend.caption:='Waiting for connection response...';
  while not ClientSocket1.active and not networkError do
   application.processMessages;
*)
  IdTCPClient1.Connect;

  lblSend.caption:='';

  (*todo remove: no need any more
  reCommand.Lines.Clear;
//  reCommand.Lines.Add('CONNECT TO ''G'' USER ''SYSTEM'' ');
  reCommand.Lines.Add('CONNECT TO DEFAULT');
  btnExecute.Click;
  *)

  //postmessage(btnExecute.handle,WM_LBUTTONDOWN,btnExecute.left+5,btnExecute.top+5);
  //postmessage(btnExecute.handle,WM_LBUTTONUP,btnExecute.left+5,btnExecute.top+5);
end;

procedure TfrmISQLmain.Disconnect2Click(Sender: TObject);
begin
  if not IdTCPClient1.connected then
  begin
    messageDlg('Not connected',mtError,[mbok],0);
    exit;
  end;

  reCommand.Lines.Clear;
  reCommand.Lines.Add('DISCONNECT CURRENT');
  reResult.Clear; //ensure we remove existing end of results
  btnExecute.Click;

  (*todo remove
  //politely wait for acknowledgement from server before disconnecting...
  lblSend.caption:='Waiting for disconnection response...';
  while (copy(reResult.Text,length(reResult.text),1)<>ENDOFSQLRESULTS) and IdTCPClient1.connected and not networkError do
  begin
    sleep(1000);
    application.processMessages; //todo: sleep!
  end;
    //todo add timeout to prevent total hang here...
  *)
  lblSend.caption:='';
  sleep(500); //else disconnect conflicts with send/response

  Disconnect1Click(Sender);
end;

procedure TfrmISQLmain.FormCreate(Sender: TObject);
begin
  history:=TstringList.Create;
  IdTCPClient1.Host:=TCPhost;
  try
    IdTCPClient1.Port:=GStack.WSGetServByName(TCPservice);
    IDservice:=TCPservice;
  except
    IdTCPClient1.Port:=TCPport;
    IDservice:=intToStr(TCPport);
  end; {try}
  reResult.maxLength:=$7FFFFFF0; //avoid 64k limit
  reCommand.maxLength:=$7FFFFFF0; //avoid 64k limit
end;

procedure TfrmISQLmain.FormDestroy(Sender: TObject);
begin
  history.Free;
end;

procedure TfrmISQLmain.SpeedButton1Click(Sender: TObject);
begin
  if historyCursor>0 then
  begin
    dec(historyCursor);
    reCommand.text:=history[historyCursor];
  end;
end;

procedure TfrmISQLmain.SpeedButton2Click(Sender: TObject);
begin
  if historyCursor<history.Count-1 then
  begin
    inc(historyCursor);
    reCommand.text:=history[historyCursor];
  end;
end;

procedure TfrmISQLmain.About1Click(Sender: TObject);
begin
  //todo!
  showmessage('ISQL (raw)'+CRLF+'(C)Copyright 2000-2004 ThinkSQL Ltd');
end;

procedure TfrmISQLmain.Options2Click(Sender: TObject);
begin
  Options1Click(Sender);
end;


procedure TfrmISQLmain.IdTCPClient1Connected(Sender: TObject);
begin
  shCircle.Brush.Color:=clLime;
  StatusBar1.SimpleText:='Connected';

  networkError:=False;

  IdTCPClient1.Writeln(); //prompt for Welcome

  listener:=TListener.Create(True);
  listener.connection:=IdTCPClient1;
  listener.resume;
end;

procedure TfrmISQLmain.IdTCPClient1Disconnected(Sender: TObject);
begin
  if listener<>nil then
  begin
    listener.Terminate;

    shCircle.Brush.Color:=clRed;
    StatusBar1.SimpleText:='Disconnected';
    networkError:=False;

    listener.WaitFor;
    listener.Free;
    listener:=nil;
  end;
end;

procedure TListener.UpdateScreen;
begin
//  frmISQLmain.reResult.text:=frmISQLmain.reResult.text+lastText+EOL;
  frmISQLmain.reResult.Lines.Add(lastText);
end;

procedure TListener.Execute;
begin
  while not Terminated do
  begin
    try
      lastText:=connection.ReadLn(EOL,2000);
      if not connection.ReadLnTimedOut then
        synchronize(UpdateScreen);
    except
      on E:EIdSocketError do
      begin
        //22/01/03 - in case server crashed - avoid infinite loop

        //we can't call connection.disconnect because it would waitfor us!
        frmISQLmain.shCircle.Brush.Color:=clRed;
        frmISQLmain.StatusBar1.SimpleText:='Disconnected';
        frmISQLmain.networkError:=True;

        Terminate;
      end;
      on E:Exception do
      begin
        //ignore, e.g. garbage, e.g debug empty table
      end;
    end; {try}
    if not connection.connected then
    begin
      frmISQLmain.shCircle.Brush.Color:=clRed;
      frmISQLmain.StatusBar1.SimpleText:='Disconnected';
      frmISQLmain.networkError:=True;

      Terminate;
    end;
  end;
end;

procedure TfrmISQLmain.Querystatus1Click(Sender: TObject);
var s:string;
begin
  if not IdTCPClient1.connected then
  begin
    messageDlg('Not connected',mtError,[mbok],0);
    exit;
  end;

  {Save the current text just in case not sent}
  s:=trimRight(reCommand.text);
  if s<>'' then
  begin
    history.Add(s);
    historyCursor:=history.Count-1;
  end;

  reCommand.Lines.Clear;
  reCommand.Lines.Add('SELECT * FROM (VALUES(CURRENT_USER,CURRENT_CATALOG,CURRENT_SCHEMA)) AS QUERY_STATUS("CURRENT_USER","CURRENT_CATALOG","CURRENT_SCHEMA")');
  reResult.Clear; //ensure we remove existing end of results
  btnExecute.Click;
end;

end.

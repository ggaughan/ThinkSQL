unit uEvsHelpers;

interface
uses
  IdYarn, IdObjs, IdContext, IdTCPConnection, IdCustomTCPServer, IdStack, IdStackBSDBase, IdStackWindows, IdGlobal;

type
 TEvsTCPServer = class(TIdCustomTCPServer)
  protected
     procedure CheckOkToBeActive;  override;
  public
  published
    property OnExecute;
  end;

  TIdPeerThread = class(TIdContext)
  private
    FTerminated: Boolean;
    function GetSuspended: Boolean;
  public
    constructor Create(AConnection: TIdTCPConnection; AYarn: TIdYarn; AList: TIdThreadList = nil); override;
    procedure Terminate;
    property Terminated :Boolean read FTerminated;// write FTerminated;
    property Suspended  :Boolean read GetSuspended;
  end;

  TTcpConnectionHelper = class Helper for TIDTcpConnection
  private
    function GetClosedGraceFully: Boolean;
  public
    procedure OpenWriteBuffer;
    procedure WriteBuffer(const aBuffer; aSize:Integer; aNow:Boolean = False);
    procedure CloseWriteBuffer;
    procedure CancelWriteBuffer;
    procedure ReadBuffer(var aBuffer; const aBufferSize:Integer; aNow:Boolean = False);
    procedure Write(const aText: String);
    procedure WriteLN(const aText: String = '');
    function ReadLn(aTerminator: string = LF; const aTimeout: Integer = IdTimeoutDefault; aMaxLineLength: Integer = -1): string;
    property ClosedGraceFully:Boolean read GetClosedGraceFully;
  end;

  TTCPServerHelper = class helper for TIdCustomTCPServer
  private
    function GetThreadClass: TIdContextClass;
    procedure SetThreadClass(const aValue: TIdContextClass);
  public
    property ThreadClass : TIdContextClass read GetThreadClass write SetThreadClass;
  end;

  TStackHelper = class Helper for TIDStack
  public
    function WSGetServByName(const AServiceName: string): Integer;
  end;

implementation
uses
  SysUtils  //for tbytes
  //uGlobal,
  , IdTCPServer, IdResourceStringsCore;
{ TTcpConnectionHelper }

procedure TTcpConnectionHelper.CancelWriteBuffer;
begin
  IOHandler.WriteBufferCancel;
end;

procedure TTcpConnectionHelper.CloseWriteBuffer;
begin
  IOHandler.WriteBufferClose;
end;

function TTcpConnectionHelper.GetClosedGraceFully: Boolean;
begin
  Result := IOHandler.ClosedGracefully;
end;

procedure TTcpConnectionHelper.OpenWriteBuffer;
begin
  IOHandler.WriteBufferOpen;
end;

procedure TTcpConnectionHelper.ReadBuffer(var aBuffer; const aBufferSize: Integer; aNow:Boolean = False);
var
  vBuf :TBytes;
begin
  SetLength(vBuf,aBufferSize);
  IOHandler.ReadBytes(vBuf, aBufferSize, False);
  BytesToRaw(vBuf, aBuffer, aBufferSize);
end;

function TTcpConnectionHelper.ReadLn(aTerminator: string = LF; const aTimeout: Integer = IdTimeoutDefault; aMaxLineLength: Integer = -1): string;
begin
  Result := IOHandler.ReadLn(aTerminator,aTimeout,aMaxLineLength)
end;

procedure TTcpConnectionHelper.WriteBuffer(const aBuffer; aSize:Integer; aNow:Boolean = False);
begin
  IOHandler.Write(RawToBytes(aBuffer, aSize));
end;

procedure TTcpConnectionHelper.Write(const aText: String);
begin
  IOHandler.Write(aText);
end;

procedure TTcpConnectionHelper.WriteLN(const aText: String = '');
begin
  IOHandler.WriteLn(aText);
end;

constructor TIdPeerThread.Create(AConnection: TIdTCPConnection; AYarn: TIdYarn; AList: TIdThreadList);
begin
  inherited;
end;

function TTCPServerHelper.GetThreadClass: TIdContextClass;
begin
  Result := Self.ContextClass;
end;

procedure TTCPServerHelper.SetThreadClass(const aValue: TIdContextClass);
begin
  Self.ContextClass := aValue;
end;


function TStackHelper.WSGetServByName(const AServiceName: string): Integer;
//var
//  ps: PServEnt;
begin
  if Self is TIdStackBSDBase then  Result := TIdStackBSDBase(Self).WSGetServByName(AServiceName)
  else raise EAbstractError.Create(Self.ClassName+'.WSGetServByName is an abstract method.');
//  Self.GetPeerName();
//  ps := GetServByName(PChar(AServiceName), nil);
//  if ps <> nil then
//  begin
//    Result := Ntohs(ps^.s_port);
//  end
//  else
//  begin
//    try
//      Result := StrToInt(AServiceName);
//    except
//      on EConvertError do raise EIdInvalidServiceName.CreateFmt(RSInvalidServiceName, [AServiceName]);
//    end;
//  end;
end;

function TIdPeerThread.GetSuspended: Boolean;
begin
  Result := False;
end;

procedure TIdPeerThread.Terminate;
begin
  FTerminated := True;
end;

{ TEvsTCPServer }

procedure TEvsTCPServer.CheckOkToBeActive;
begin
  inherited CheckOkToBeActive;
  if (not (ContextClass = TIdPeerThread)) and (not Assigned( OnExecute))then
    raise EIdTCPNoOnExecute.Create(RSNoOnExecute);
end;

end.

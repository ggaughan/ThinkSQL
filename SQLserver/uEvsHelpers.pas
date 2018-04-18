unit uEvsHelpers;

interface
uses
  IdYarn, IdObjs, IdContext, IdTCPConnection, IdCustomTCPServer, IdStack, IdStackBSDBase, IdStackWindows, IdGlobal;

type
  DWORD = LongWord;
  BOOL = LongBool;

  TEvsTCPServer = class(TIdCustomTCPServer)
  private
    function GetLocalName: String;
  protected
     procedure CheckOkToBeActive;  override;
  public
    property LocalName:String read GetLocalName;
  published
    property OnExecute;
  end;

  TIdPeerThread = class(TIdContext)
  private
    FTerminated :Boolean;
    FHandle     :THandle;
    function GetSuspended: Boolean;
    function GetHandle: THandle;
    function GetThreadID: LongWord;
  public
    constructor Create(AConnection: TIdTCPConnection; AYarn: TIdYarn; AList: TIdThreadList = nil); override;
    destructor Destroy; override;
    procedure Terminate;
    property Terminated :Boolean read FTerminated;// write FTerminated;
    property Suspended  :Boolean read GetSuspended;
    Property Handle : THandle read GetHandle;
    property ThreadID:LongWord read GetThreadID;
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
    function WSGetHostName:String;
  end;

implementation
uses
  SysUtils  //for tbytes
  //uGlobal,    windows
  , IdTCPServer, IdResourceStringsCore;

function OpenThread( dwDesiredAccess:DWORD;  bInheritHandle:BOOL; dwThreadId:DWORD):THandle; external 'kernel32.dll' name 'OpenThread';
function GetExitCodeThread(hThread:THandle; lpExitCode:DWORD):BOOL; external 'kernel32.dll' name 'GetExitCodeThread';
function CloseHandle(hObject: THandle): BOOL; external 'kernel32.dll' name 'CloseHandle';

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
  FHandle := 0;
end;

function TTCPServerHelper.GetThreadClass: TIdContextClass;
begin
  Result := Self.ContextClass;
end;

procedure TTCPServerHelper.SetThreadClass(const aValue: TIdContextClass);
begin
  Self.ContextClass := aValue;
end;


type
  TCrack = class(TIdStackBSDBase)
  end;
function TStackHelper.WSGetHostName: String;
begin
  if Self is TIdStackBSDBase then  Result := TCrack(Self).ReadHostName //TIdStackBSDBase(Self).WSGetHostName
  else raise EAbstractError.Create(Self.ClassName+'.WSGetServByName is an abstract method.');
end;

function TStackHelper.WSGetServByName(const AServiceName: string): Integer;
begin
  if Self is TIdStackBSDBase then  Result := TIdStackBSDBase(Self).WSGetServByName(AServiceName)
  else raise EAbstractError.Create(Self.ClassName+'.WSGetServByName is an abstract method.');
end;

destructor TIdPeerThread.Destroy;
begin
  if FHandle <> 0 then
    CloseHandle(FHandle);
  inherited;
end;

function TIdPeerThread.GetHandle: THandle;
const
  STANDARD_RIGHTS_REQUIRED = $000F0000;
  SYNCHRONIZE              = $00100000;
  THREAD_ALL_ACCESS        = STANDARD_RIGHTS_REQUIRED or SYNCHRONIZE or $3FF;

begin
  if FHandle = 0 then begin
   //This is a patch to overcome the not a thread class problem it will not be a problem once the observer pattern is in place
    FHandle := OpenThread(THREAD_ALL_ACCESS, False, CurrentThreadId);
  end;
  Result := FHandle
end;

function TIdPeerThread.GetSuspended: Boolean;
begin
  Result := False;
end;

function TIdPeerThread.GetThreadID: LongWord;
begin
  Result  := CurrentThreadId;
end;

procedure TIdPeerThread.Terminate;
begin
  FTerminated := True;
  if FHandle <> 0 then CloseHandle(FHandle);

end;

{ TEvsTCPServer }

procedure TEvsTCPServer.CheckOkToBeActive;
begin
  inherited CheckOkToBeActive;
  if (not ContextClass.InheritsFrom(TIdPeerThread)) and (not Assigned( OnExecute))then
    raise EIdTCPNoOnExecute.Create(RSNoOnExecute);
end;

function TEvsTCPServer.GetLocalName: String;
begin
  Result := GStack.WSGetHostName;
end;

end.

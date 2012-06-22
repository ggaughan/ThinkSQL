unit uMain;

//{$DEFINE COPYFILES}    //attempt to copy dlls from current directory...
{$DEFINE ADD_SERVICE}    //attempt to add service (port) entry

interface
uses windows{for BOOL};

//todo!!!!!! include odbc.inc! - or at least share with ODBCsetup!
const
  ODBC_INSTALLER_DLL='odbccp32.dll';

type
  pUCHAR=pchar;
  pWORD=^WORD;

procedure Main;

implementation

uses Dialogs, sysUtils;

const
  ODBC_INSTALL_INQUIRY	=1;
  ODBC_INSTALL_COMPLETE	=2;

  ODBC_ADD_DSN     =1;
  ODBC_REMOVE_DSN  =3;

  ODBC_ADD_SYS_DSN =4;
  ODBC_REMOVE_SYS_DSN =6;

  driverName='ThinkSQL Driver';
  driverDLL='ThinkSQLodbc.dll';
  setupDLL='ThinkSQLodbcSetup.dll';

  datasourceName='ThinkSQL Default';
  serviceFile='services';
  serviceName='thinksql';
  portNumber=9075;
  serverName='thinksql'; //default catalog=first one started
  serviceDesc='ThinkSQL RDBMS';

function SQLInstallDriverEx(lpszDriver:pUCHAR;
                            lpszPathIn:pUCHAR;
                            lpszPathOut:pUCHAR;
                            cbPathOutMax:WORD;
                            pcbPathOut:pWORD;
                            fRequest:WORD;
                            lpdwUsageCount:LPDWORD):BOOL;
                            stdcall; external ODBC_INSTALLER_DLL;

function SQLConfigDataSource(hwndParent:HWND;
                             fRequest:WORD;
                             lpszDriver:pUCHAR;
                             lpszAttributes:pUCHAR):BOOL;
                             stdcall; external ODBC_INSTALLER_DLL;

function addSlash (s:string):string;
begin
  if s[length(s)]='\' then
    result:=s
  else
    result:=s+'\';
end;

procedure Main;
var
  szDriver,szPathIn,szPathOut,szAttributes:string;
  cbPathOutMax:WORD;
  cbPathOut:pWORD;
  dwUsageCount:LPDWORD;
  i:integer;

  serviceDirectory:string;
  serviceDir:string;
  serviceFilename:string;
  serviceF:text;
  s:string;
  found:boolean;
  l:uint;
begin
  {$IFDEF ADD_SERVICE}
  {First ensure we have the service name set}
  serviceFilename:='';
  setLength(serviceDirectory,101);
  case Win32Platform of
    VER_PLATFORM_WIN32_WINDOWS:
    begin
      l:=GetWindowsDirectory(pchar(serviceDirectory),100);
      setLength(serviceDirectory,l);
      serviceDirectory:=addSlash(serviceDirectory);
    end;
    VER_PLATFORM_WIN32_NT:
    begin
      l:=GetSystemDirectory(pchar(serviceDirectory),100);
      setLength(serviceDirectory,l);
      serviceDirectory:=addSlash(serviceDirectory)+'drivers\etc\';
    end;
  else
    showMessage('Unknown Windows platform'); //todo assume NT?
  end; {case}

  if serviceDirectory<>'' then
  begin
    serviceFilename:=serviceDirectory+serviceFile;
    {See if the service name already exists}
    assignFile(serviceF,serviceFilename);
    try
      reset(serviceF);
      try
        found:=False;
        while not eof(serviceF) do
        begin
          readln(serviceF,s);
          if uppercase(trim(copy(s,1,length(serviceName)+1)))=uppercase(serviceName) then //todo remove comment?: too crude - ignores prefixes
          begin
            found:=True;
          end;
        end;
      finally
        closeFile(serviceF);
      end; {try}
      //todo remove if found then showmessage('Service already exists')
      //            else showmessage('Service does not yet exist')
      if not found then
      begin
        append(serviceF);
        try
          if s<>'' then writeln(serviceF);
          writeln(serviceF,format('%-16.16s %d/tcp                  # %s',[serviceName,portNumber,serviceDesc])); //'	thinksql		 9075/tcp		   # ThinkSQL RDBMS');
        finally
          closeFile(serviceF);
        end; {try}
      end;
    except
      on E:exception do
      begin
        showMessage('Failed adding network service definition ('+E.message+')');
        //network probably missing. Continue with the installation...
      end;
    end; {try}
  end;
  {$ENDIF}

  new(cbPathOut);
  new(dwUsageCount);
  setLength(szPathOut,101);
  try
    szDriver:=format('%s;Driver=%s;Setup=%s;',[driverName,driverDLL,setupDLL]);
    for i:=1 to length(szDriver) do
      if szDriver[i]=';' then szDriver[i]:=#0;

    SQLInstallDriverEx(pchar(szDriver),
                       nil, //todo = system dir:ok? pchar(szPathIn),
                       pchar(szPathOut),
                       100,//cbPathOutMax,
                       cbPathOut,
                       ODBC_INSTALL_INQUIRY,
                       dwUsageCount );

    //todo: remove any existing driver & decrement usage count...
(*SQLConfigDriver (with an fRequest of ODBC_REMOVE_DRIVER) should first be called,
and then SQLRemoveDriver should be called to decrement the component usage count.
todo: needs configDriver in setup dll*)

    if SQLInstallDriverEx(pchar(szDriver),
                              nil, //todo = system dir:ok? pchar(szPathIn),
                              pchar(szPathOut),
                              100,//cbPathOutMax,
                              cbPathOut,
                              ODBC_INSTALL_COMPLETE,
                              dwUsageCount ) then
    begin
      {$IFDEF COPYFILES}
        {Copy the driver files}
        //todo assumes Core files are already there - we should install them if they're not...
        if {not} CopyFile(driverDLL,pchar(szPathOut+driverDLL),FALSE)=FALSE then
          showMessage(format('Failed copying %s to %s',[driverDLL,szPathOut]));
        if {not} CopyFile(setupDLL,pchar(szPathOut+setupDLL),FALSE)=FALSE then
          showMessage(format('Failed copying %s to %s',[setupDLL,szPathOut]));
      {$ENDIF}

      //todo remove: showMessage(format('Installed ODBC driver: %s',[driverName]));

      {Now install the sample data source}
      szDriver:=format('%s',[driverName]);
      szAttributes:=format('DSN=%s;HOST=%s;SERVICE=%s;SERVER=%s;UID=%s;PWD=%s;',[datasourceName,'localhost',serviceName,serverName,'DEFAULT','default']);

      SQLConfigDataSource(0,
       	                  ODBC_REMOVE_DSN,
                          pchar(szDriver),
			  pchar(szAttributes));

      if SQLConfigDataSource(0,
			     ODBC_ADD_DSN,
			     pchar(szDriver),
			     pchar(szAttributes)) then
      begin
        //ok
      end
      else
      begin
        showMessage('Failed installing default data source');
      end;
    end
    else
      showMessage('Failed installing driver');
      //todo call SQLInstallerError to get details!
      //todo return ERRORLEVEL...
      //todo if( ProcessErrorMessages( "SQLInstallDriverEx" ) )
      //              return FALSE;

  finally
    dispose(dwUsageCount);
    dispose(cbPathOut);
  end; {try}
end; {Main}


end.

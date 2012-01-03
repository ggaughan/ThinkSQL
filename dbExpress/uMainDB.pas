{$IFNDEF DBEXP_STATIC}
unit uMainDB;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses DBXpress;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

function getSQLDriverTHINKSQL(VendorLib, SResourceFile:PChar; out pDriver):SQLResult; stdcall;
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses uLog,
     uSQLDriver,
     SysUtils;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}

function getSQLDriverTHINKSQL(VendorLib, SResourceFile:PChar; out pDriver):SQLResult; stdcall;
var
  i:ISQLDriver;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getSQLDriverTHINKSQL called with %s %s',[VendorLib, SResourceFile]),vLow);
  {$ENDIF}

  //Note: we are native so we can ignore the VendorLib

  //todo: it would be nice if we could work out a way to not need a lib at all.
  //      i.e. use the dcu's

  i:=TSQLDriver.create;
  ISQLDriver(pDriver):=i;
  result:=SQL_SUCCESS;
end; {getSQLDriverTHINKSQL}




{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


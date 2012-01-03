{$IFNDEF DBEXP_STATIC}
unit uSQLDriver;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses DBXpress;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

type
  TSQLDriver=class(TInterfacedObject,ISQLDriver)
  private
  public
    function getSQLConnection(out pConn: ISQLConnection): SQLResult; stdcall;
    function SetOption(eDOption: TSQLDriverOption;
                       PropValue: LongInt): SQLResult; stdcall;
    function GetOption(eDOption: TSQLDriverOption; PropValue: Pointer;
                       MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
  end; {TSQLDriver}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses uLog,
     SysUtils,
     uSQLConnection;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
function TSQLDriver.getSQLConnection(out pConn: ISQLConnection): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('getSQLConnection called',vLow);
  {$ENDIF}

  pConn:=TxSQLConnection.create(self);

  result:=SQL_SUCCESS;
end; {getSQLConnection}

function TSQLDriver.SetOption(eDOption: TSQLDriverOption;
                       PropValue: LongInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLDriver.SetOption called %d %d',[ord(eDOption),PropValue]),vLow);
  {$ENDIF}

  case eDOption of

    eDrvRestrict: //reserved
  end; {case}

  result:=SQL_SUCCESS;
end; {SetOption}

function TSQLDriver.GetOption(eDOption: TSQLDriverOption; PropValue: Pointer;
                       MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLDriver.GetOption called %d %d %d',[ord(eDOption),PropValue,MaxLength]),vLow);
  {$ENDIF}

  Length:=0;

  result:=SQL_SUCCESS;
end; {GetOption}



{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


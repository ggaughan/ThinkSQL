unit uOS;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Operating system specific routines
 - this is an attempt to keep all the nasty but necessary IFDEFs out of the way
}

interface

uses uStmt
{$IFDEF WIN32}
  ,Windows;
{$ENDIF}
{$IFDEF LINUX}
  ,IdGlobal;
{$ENDIF}

const
{$IFDEF WIN32}
  INFINITY = INFINITE;
{$ENDIF}

{$IFDEF LINUX}
  INFINITY = LongWord($FFFFFFFF);     { Infinite timeout }
{$ENDIF}

function getSystemUser(st:TStmt;var s:string):integer;

procedure sleepOS(ms:integer);


implementation

uses uGlobal
{$IFDEF LINUX}
  ,uTransaction
{$ENDIF}
;

function getSystemUser(st:TStmt;var s:string):integer;
{Returns the current system user name
 IN:      st - the statement
 OUT:     s  - the user name
 RESULT:  ok, else fail
}
{$IFDEF WIN32}
var
  sLen:DWORD;
{$ENDIF}
begin
  result:=fail;

  {$IFDEF WIN32}
  sLen:=MaxAuthName+1;
  setLength(s,sLen);
  if getUserName(LPTSTR(s),sLen) then result:=ok;
  {$ENDIF}
  {$IFDEF LINUX}
  //todo getlogon(s)
  s:=TTransaction(st.owner).authName;
  result:=ok;
  {$ENDIF}
end; {getSystemUser}

procedure sleepOS(ms:integer);
begin
  {$IFDEF WIN32}
  sleep(ms);
  {$ENDIF}
  {$IFDEF LINUX}
  sleep(ms);
  {$ENDIF}
end; {sleepOS}


end.

{$IFNDEF DBEXP_STATIC}
unit uLog;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE FLUSH_LOG}
//{$DEFINE SHOW_LOG}

interface
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}

type
  Timportance=(vDebug,vLow,vMedium,vHigh,vError,vAssertion,vNone{last});

procedure log(s:string;importance:Timportance); overload;

var
  logNoShow:boolean=False;
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses SysUtils
{$IFDEF SHOW_LOG}
,QDialogs
{$ENDIF}
;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
const
  {$IFDEF DEBUG_LOG}
  verbosity:Timportance=vDebug;
  {$ELSE}
  verbosity:Timportance=vNone;
  {$ENDIF}

  logfilename='sqlthink.log';

var
  logF:text;

procedure log(s:string;importance:Timportance);
begin
  if importance>=verbosity then
  begin
    try
      {$IFDEF DEBUG_LOG}
      writeln(logF,s);
      {$IFDEF FLUSH_LOG}
      flush(logF);
      {$ENDIF}
      {$ENDIF}
    except
      //ignore errors
    end; {try}
    {$IFDEF SHOW_LOG}
    if not logNoShow then
      try
        showmessage(s);
      except
        //ignore
      end; {try}
    {$ENDIF}
  end;
end; {log}

{$ENDIF}

{$IFNDEF DBEXP_STATIC}
initialization
  if verbosity<vNone then
  try
    {$IFDEF DEBUG_LOG}
    assignFile(logF,logfilename);
    rewrite(logF);
    log(formatDateTime('"Log started at "c',now),vHigh);
    log('',vHigh);
    {$ENDIF}
  except
    //ignore errors!
  end; {try}

finalization
  if verbosity<vNone then
  try
    {$IFDEF DEBUG_LOG}
    log(formatDateTime('"Log stopped at "c',now),vHigh);
    closeFile(logF);
    {$ENDIF}
  except
    //ignore errors!
  end; {try}



end.
{$ENDIF}


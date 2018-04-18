unit uLog;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Log manager

 Note:
   access to the log file is currently protected by a critical section.
   This will make it a serious bottleneck - remove (switch off) when timing/live
}

{$I Defs.inc}

interface

uses SyncObjs;

type
  vbType=(vDebugLow, vDebugMedium, vDebug, vDebugHigh, vDebugWarning, vDebugError,
          vFix,
          vAssertion,
          vError, vWarning, vNote, vLow, vMedium, vHigh);

  TLog=class
  private
    Fverbosity:vbType;
    logF:text;
    csLog:TcriticalSection;
    constructor Create(fname:string);
    destructor Destroy; override;
  public
    property verbosity:vbType read Fverbosity write Fverbosity;
    //remove yacc needs it! {$IFDEF DEBUG_LOG} //ensure none refer to this outside of DEBUG_LOG protection
    procedure quick(s:string);
    procedure add(const who:string;const where:string;ms:string;mt:vbType);
    //{$ENDIF}
    procedure LogFlush;
    procedure start;
    procedure Status;
    procedure stop;

    //debug speed switching only - remove?
    procedure hold;
    procedure resume;
  end; {TLog}

const
  where='uLog';
  whereSize=35;      //width of 'where' log column
  whoSize=20;        //width of 'who' log column

  AssertionPrefix='***** ';
  DebugErrorPrefix='+++++ ';
  DebugWarningPrefix='----- ';

  vDefault=vDebugLow;  //debug standard

//  vDefault=vDebugMedium;
//  vDefault=vDebug;     //todo user set
//  vDefault=vDebugHigh; //todo user set

//  vDefault=vHigh; //too high!
//  vDefault=vMedium;

//    vDefault=vAssertion;  //live standard?

var
 log:TLog;
 logOn:boolean=True; //todo remove: only for debug speed switching with hold/resume

implementation

uses SysUtils, uGlobal,
     uPage, uHeapFile,uBuffer{todo remove -only for sizes,};

const
  MAX_LOG_TEXT=4000;  //longest log message that we can handle (format limitation)

  {Note: TODO
   remove
     const who=''
   from all modules, because those that need it aren't transaction-based and so aren't multithread safe.
   (this is okay for some routines, e.g. connection manager startup)
   Check all calls to log.add use 'tr.who'.
  }
  who='';

var
//todo these should be part of class so they're thread safe!
  hs:THeapStatus;
{.$IFDEF Debug_Log}
  startAlloc, endAlloc, startFree, endFree:integer;
{.$ENDIF}
  countDebugErr,countDebugWarning,countErr,countFix,countAssertion,countWarning:integer;

constructor TLog.Create(fname:string);
begin
  verbosity:=vDefault;
  countDebugErr:=0;
  countDebugWarning:=0;
  countErr:=0;
  countFix:=0;
  countAssertion:=0;
  countWarning:=0;
  {.$IFDEF LOG}
  csLog:=TCriticalSection.Create;
  assignFile(logF,fname);
  rewrite(logF);
  writeln(logF,'Log file created: '+formatDateTime('c',now));
  writeln(logF,Title);
  writeln(logF,Copyright);
  writeln(logF,'Version '+uGlobal.Version);
  writeln(logF);
  {.$ENDIF}
end;

destructor TLog.Destroy;
begin
  {.$IFDEF LOG}
  writeln(logF,'Log file closed: '+formatDateTime('c',now));
  closeFile(logF);
  csLog.Free;
  {.$ENDIF}
  inherited;
end;

procedure TLog.start;
begin
  {.$IFDEF LOG}
  writeln(logF,'Log started: '+formatDateTime('c',now));
  status;
  startAlloc:=hs.totalAllocated; startFree:=hs.TotalFree;
  writeln(logF,format('Disk block size=%d',[diskblocksize]));
  writeln(logF,format('Block size=%d',[blocksize]));
  writeln(logF,format('Slot size=%d',[slotSize]));
  writeln(logF,format('Buffer pool=%d',[maxFrames]));
  {.$ENDIF}
end;

procedure TLog.Status;
//todo pass in Who+Where to identify caller
var
  h,m,s,ms:word;
begin
  {.$IFDEF LOG}
  {$IFDEF WIN32}
  hs:=GetHeapStatus;  //todo use uOS for Linux...
  {$ENDIF}
  decodeTime(now,h,m,s,ms);
  add(who,format('%2.2d:%2.2d:%2.2d:%2.2d',[h,m,s,ms])+'  Heap memory',format('total available=%d (committed=%d, uncommitted=%d) overhead=%d',[hs.TotalAddrSpace,hs.totalCommitted,hs.totalUncommitted,hs.Overhead]),vDebug);
  add(who,format('%2.2d:%2.2d:%2.2d:%2.2d',[h,m,s,ms])+'  Free memory',format('allocated=%d, free=%d (unused=%d, freebig=%d, freesmall=%d)',[hs.totalAllocated,hs.TotalFree,hs.Unused,hs.freeBig,hs.freeSmall]),vDebug);
  {.$ENDIF}
end;

procedure TLog.stop;
begin
  {.$IFDEF LOG}
  //todo give error summary
  //     maybe always set logOn...?
  status;
  endAlloc:=hs.totalAllocated; endFree:=hs.TotalFree;
  add(who,'Memory leaked',format('%d bytes',[(endAlloc-startAlloc)]),vDebugHigh);
  add(who,'Error summary','',vDebugHigh);
  add(who,'',format('Debug errors   : %3.3d',[countDebugErr]),vDebugHigh);
  add(who,'',format('Debug warnings : %3.3d',[countDebugWarning]),vDebugHigh);
  add(who,'',format('Fixes          : %3.3d',[countFix]),vHigh);
  add(who,'',format('Warnings       : %3.3d',[countWarning]),vDebugHigh);
  add(who,'',format('Errors         : %3.3d',[countErr]),vHigh);
  add(who,'',format('Assertions     : %3.3d',[countAssertion]),vHigh);
  add(who,'','',vDebug);
  writeln(logF,'Log stopped: '+formatDateTime('c',now));
  writeln(logF);
  {.$ENDIF}
end;

procedure TLog.add(const who:string;const where:string;ms:string;mt:vbType);
begin
  {.$IFDEF LOG}
  if mt>=Fverbosity then
  begin
    if LogOn then
    begin
      csLog.Enter;
      try
        if length(ms)>MAX_LOG_TEXT then ms:=copy(ms,1,MAX_LOG_TEXT-3)+'...';
        if mt=vAssertion then writeln(logF,AssertionPrefix); //highlight!
        if mt=vDebugError then writeln(logF,DebugErrorPrefix); //highlight!
        if mt=vDebugWarning then writeln(logF,DebugWarningPrefix); //highlight!
        writeln(logF,format('%*s:%*s: %s',[whoSize,who,whereSize,where,ms]));
        {Note: 13/05/99 ms was s. For some weird reason, s would point
         to s(TDBserver) in the callers stack - rarely - with big strings
         (optimisation was off).
         So I had to rename the beggar to try & hide it!
         Found problem: if ms>4096 characters after exception, the pointers
         are all garbled - trap overflow!
         -24/06/99 there is a bug fix for this in a Delphi patch for v3 or v4...
        }
        if mt=vAssertion then logFlush; //todo same for debugError?
        {$IFDEF FLUSH_AFTER_EVERY_LOG}
        logFlush;
        {$ENDIF}
      finally
        csLog.Leave;
      end;
    end;
  end;
  if mt=vDebugError then inc(countDebugErr);
  if mt=vDebugWarning then inc(countDebugWarning);
  if mt=vError then inc(countErr);
  if mt=vFix then inc(countFix);
  if mt=vAssertion then inc(countAssertion);
  if mt=vWarning then inc(countWarning);

  {.$ENDIF}
end;

procedure TLog.quick(s:string);
{Quick debug log}
begin
  {.$IFDEF LOG}
  add(who,'quick',s,vDebug);
  {.$ENDIF}
end; {quick}

procedure TLog.LogFlush;
begin
  {.$IFDEF LOG}
  flush(logF);
  {.$ENDIF}
end; {flush}

procedure TLog.Hold;
const routine=':Hold';
begin
  {.$IFDEF LOG}
  add(who,where+routine,'Hold...',vDebug);
  {.$ENDIF}
  logOn:=False;
end; {hold}

procedure TLog.Resume;
const routine=':Resume';
begin
  logOn:=True;
  {.$IFDEF LOG}
  add(who,where+routine,'...Resume',vDebug);
  {.$ENDIF}
end; {resume}

initialization
  log:=TLog.Create('sqlserver.log');

finalization
  log.free;

end.

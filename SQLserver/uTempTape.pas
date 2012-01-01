unit uTempTape;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$DEFINE DEBUGDETAIL}
//{$DEFINE NO_BUFFERING}        //remove when live

{Temporary tape class
 A sequential stream of records, currently stored outside the main database file
 (used by polyphase merge-sort routine & materialisation, e.g. non-correlated sub-selects)
 Note: the file/records have no transaction handling and are assumed to be single-access
 Note: we buffer the records before writing to disk, so small sorts/materialisations are in memory

 Structure of tape=
 [length 0][data 0][length 1][data 1]...[length N][data N]

 i.e. unstructured records end-to-end. Sequentially written and read.
 (although could mark position & seek if required later)

 Example method calls:
   f:=TTempTape.create;
   try
     f:=f.createNew('scratch1');
     while moreData do
       f.writeRecord(rec,recLen);
     f.rewind;
     while not f.noMore do
       f.readRecord(rec,recLen)
     f.close;
     f.delete;
   finally
     f.free;
   end; //try
}

interface

const
//  TapeBlockSize=2048;
  TapeBufferSize=4096; //todo move to global/allow user sizing?
                       //sync. with page size to ensure materialise 1 row is always buffered

type
  TTapeBuffer=array [0..TapeBufferSize-1] of char;

  TTempTape=class
  protected
    fname:string;
    ffile:File;
    fBuf:TTapeBuffer;
    fBuffering:boolean;
    fBufWritePos:integer; //=buffered file size
    fBufReadPos:integer;
    isOpen:boolean;
  public
    property filename:string read fname;
    //property buf:TTapeBuffer read fBuf write fBuf;
    property buffering:boolean read fBuffering write fBuffering;
    property bufWritePos:integer read fBufWritePos write fBufWritePos;
    property bufReadPos:integer read fBufReadPos write fBufReadPos;

    constructor create;

    function CreateNew(name:string):integer;
    function WriteRecord(rec:Pchar;recLen:integer):integer; //limits max record length to 2 billion
    function ReadRecord(rec:Pchar;var recLen:integer):integer;
    function GetPosition:cardinal;
    function FindPosition(p:cardinal):integer;
    function Rewind:integer;
    function Truncate:integer;
    function Close:integer;
    function Delete:integer;
    function noMore:boolean;
  end; {TTempTape}

var
  debugTempTapeCreateNew:integer=0;        //todo remove -or at least make thread-safe & private
  debugTempTapeClose:integer=0;            //"
  debugTempTapeBufferCreateNew:integer=0;  //"
  debugTempTapeBufferClose:integer=0;      //"

implementation

uses uGlobal, sysUtils,uLog;

const where='uTempTape';
      who=''; //todo remove

constructor TTempTape.create;
begin
  isOpen:=False;
  {$IFDEF NO_BUFFERING}
  fBuffering:=False;
  {$ELSE}
  fBuffering:=True;
  {$ENDIF}
  //todo zeroise buf: no need
  bufWritePos:=0;
  bufReadPos:=0;
end; {create}

function TTempTape.CreateNew(name:string):integer;
const routine=':createNew';
begin
  //todo: assert not already open!
  fname:=name;

  if buffering then
  begin
    //fix:19/03/03 was retaining buffer when prepared sorted query was re-executed (even though new tran/sort files)
    //fix:02/04/03 only reset if buffering, else switch from buffer to disk would lose about-to-be-dumped buffer!
    //             todo: really just need to reset bufReadPos here for re-execute? Better to do in close/restart logic?
    //                   - now done in Close routine if buffered, so no need here? assert instead!?
    bufWritePos:=0;
    bufReadPos:=0;

    //defer until we have to (determined by writeRecord)
    inc(debugTempTapeBufferCreateNew); //todo remove
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('deferred starting tape %s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end
  else
  begin
    assignFile(ffile,fname);
    try
      rewrite(ffile,1);
      inc(debugTempTapeCreateNew); //todo remove
      isOpen:=True;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('starting tape %s',[fname]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
  end;
end; {Create}

function TTempTape.WriteRecord(rec:Pchar;recLen:integer):integer;
const routine=':WriteRecord';
begin
  //todo: assert open!

  if buffering then
  begin
    {Check if this rec fits}
    if bufWritePos+sizeof(recLen)+recLen>TapeBufferSize then
    begin //no room in buffer, switch & dump to disk
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('switching from buffered to disk and dumping %d',[bufWritePos]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      buffering:=false; //switch
      createNew(fname); //really create the file
      blockWrite(ffile,fbuf,bufWritePos); //dump everything we've buffered so far
      result:=writeRecord(rec,recLen); //and now write this record to disk
    end
    else
    begin //append to buffer
      move(recLen,fbuf[bufWritePos],sizeof(recLen));
      bufWritePos:=bufWritePos+sizeof(recLen);
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('buffered header=%d',[recLen]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      move(rec^,fbuf[bufWritePos],recLen);
      bufWritePos:=bufWritePos+recLen;
      result:=ok;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('buffered record %s',[rec^]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;
  end
  else
  begin
    try
      blockWrite(ffile,recLen,sizeof(recLen));
      result:=ok;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('written header=%d',[recLen]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
    try
      blockWrite(ffile,rec^,recLen);
      result:=ok;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('written record %s',[rec^]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
    //todo add end marker
  end;
end; {WriteRecord}

function TTempTape.ReadRecord(rec:Pchar;var recLen:integer):integer;
const routine=':ReadRecord';
begin
  //todo: assert open!

  if buffering then
  begin
    if bufReadPos=bufWritePos then begin result:=ok; recLen:=0; exit; end; //todo debug only? todo safer: >=
    move(fbuf[bufReadPos],recLen,sizeof(recLen));
    bufReadPos:=bufReadPos+sizeof(recLen);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('buffer-read header=%d',[recLen]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    move(fbuf[bufReadPos],rec^,recLen);
    bufReadPos:=bufReadPos+recLen;
    result:=ok;
  end
  else
  begin
    if eof(ffile) then begin result:=ok; recLen:=0; exit; end; //todo debug only?
    try
      blockRead(ffile,recLen,sizeof(recLen));
      result:=ok;
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('read header=%d',[recLen]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
    try
      blockRead(ffile,rec^,recLen);
      result:=ok;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
    //todo skip/check end marker
  end;
end; {ReadRecord}

function TTempTape.GetPosition:cardinal;
begin
  if buffering then
  begin
    result:=bufReadPos;
    //Note: if we write more & switch to buffering=false, then old positions should still be valid
  end
  else
  begin
    result:=filePos(ffile);
  end;
end; {GetPosition}
function TTempTape.FindPosition(p:cardinal):integer;
begin
  if buffering then
  begin
    bufReadPos:=p;
    result:=ok;
  end
  else
  begin
    try
      seek(ffile,p);
      result:=ok;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
  end;
end; {FindPosition}


function TTempTape.Rewind:integer;
const routine=':rewind';
begin
  if buffering then
  begin
    bufReadPos:=0;
    inc(debugTempTapeBufferClose); //todo remove
    inc(debugTempTapeBufferCreateNew); //todo remove
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('rewinding buffer %s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end
  else
  begin
    try
      Reset(ffile,1);

      inc(debugTempTapeClose); //todo remove
      inc(debugTempTapeCreateNew); //todo remove

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('rewinding %s',[fname]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      result:=ok;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
  end;
end; {Rewind}

function TTempTape.Truncate:integer;
begin
  //todo: assert open!

  if buffering then
  begin
    bufWritePos:=0;
    bufReadPos:=0;
    result:=ok;
  end
  else
  begin
    try
      system.truncate(ffile);
      //todo any point? we've started using the disk so carry on? buffering:=true;
      result:=ok;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
  end;
end; {Truncate}

function TTempTape.Close:integer;
const routine=':close';
begin
  //todo: assert open!
  if not isOpen {note: includes buffering} then
  begin
    //todo log error/warning if not buffering?
    //fix:02/04/03 reset eof flag in case re-opened, e.g. prepared & restarted
    bufWritePos:=0;
    bufReadPos:=0;

    inc(debugTempTapeBufferClose); //todo remove
    result:=ok;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('closed buffer or unopened file=%s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    exit;
  end;

  try
    closeFile(ffile);

    inc(debugTempTapeClose); //todo remove

    isOpen:=False;
    result:=ok;
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('closed file=%s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  except
    on E:Exception do
    begin
      result:=Fail;
    end;
  end; {try}
end; {Close}

function TTempTape.Delete:integer;
begin
  //todo: assert closed & was open so we have a name!

  if buffering then
  begin
    result:=ok;
  end
  else
  begin
    try
      if deleteFile(fname) then
        result:=ok
      else
        result:=fail;
    except
      on E:Exception do
      begin
        result:=Fail;
      end;
    end; {try}
  end;
end; {Delete}

function TTempTape.noMore:boolean;
const routine=':noMore';
begin
  //todo: assert open!
  if buffering then
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('checking eof for buffer %s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    if bufReadPos=bufWritePos then result:=true else result:=False;
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('checking eof for %s',[fname]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
    if eof(ffile) then result:=true else result:=False;
  end;
end; {noMore}

end.

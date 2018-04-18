{$IFNDEF DBEXP_STATIC}
unit uMarshal;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUG_DETAIL}
//{$DEFINE DEBUG_DETAIL2} //bytes sent (only useful for server build!)

{This is the marshal/unmarshal (put/get) buffer class.
 It passes packed, buffered parameters over the transport layer
 and unpacks them at the other end.

 It's held per connection on the client and the server.

 Hopefully this class can deal with all communication - kind of a layer between
 the connection manager threads and the scktcomp unit. This should ease future
 updates should we use another win-sock unit.

 See the notes in DataComplete for details of the send/receive protocol at this level.


 //todo check: callers assume that if any Get with DYNAMIC_ALLOCATION fails, no memory is allocated

}

interface

uses IdTCPConnection, uMarshalGlobal;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}
{Include the ODBC standard definitions}
{$define NO_FUNCTIONS}
{$include ODBC.INC}


const
  {Marshal buffer size (todo move to separate unit/make configurable?)
   Note: includes 1st integer as bufferLen
  }
  marshalBufSize=16384; {increased 20/01/02 because this is the maximum comms per API call} //4096; //todo ok?
  (*30/01/03: no longer used
  bufSize=4096; {20/01/02 increased from 1024} //todo improve & handle when too small
                //note: if bufsize is small, we can better handle slow connections...less timeout
                //note: marshalBufSize must be a multiple of this bufSize (and the same size or larger!)
                //      otherwise Read could overflow the marshalBuffer = fatal
                //      todo: assert this somewhere - in the initialization?
  *)

  WaitForDataTimeout=5000; //5 seconds poll for data socket to become ready before attempting read/write //todo make shorter? - else client

  //todo move to global?
  DYNAMIC_ALLOCATION=-1; //marshal routines to allocate (used by get... character string routines)

type
  TMarshalBuffer=class
  private
    clientSocket:TIdTCPConnection; //transport link

    communication_timeout:cardinal;

    Buffer:array [0..marshalBufSize-1] of char; //todo protect (the whole TMarshalBuffer!) with criticalSection...
                                                //since multiple client threads could share the same connection
    BufferLen:integer; //todo Word ok?
    BufferPtr:integer; //todo Word ok? //todo rename to BufferPos
  public
    property getBufferLen:integer read BufferLen;

    constructor Create(cs:TIdTCPConnection);
    destructor Destroy; override;

    function SendHandshake:integer;
    function ClearToSend:integer;
    function ClearToReceive:integer;
    function Send:integer;
    function Read:integer;
    function DataComplete:boolean;

    //todo maybe merge some of these?
    function putFunction(FunctionId:SQLUSMALLINT):integer;
    function getFunction(var FunctionId:SQLUSMALLINT):integer;

    function putSQLUSMALLINT(usi:SQLUSMALLINT):integer;
    function getSQLUSMALLINT(var usi:SQLUSMALLINT):integer;
    function putSQLSMALLINT(si:SQLSMALLINT):integer;
    function getSQLSMALLINT(var si:SQLSMALLINT):integer;
    function putSQLINTEGER(i:SQLINTEGER):integer;
    function getSQLINTEGER(var i:SQLINTEGER):integer;
    function putSQLUINTEGER(ui:SQLUINTEGER):integer;
    function getSQLUINTEGER(var ui:SQLUINTEGER):integer;
    function putSQLDOUBLE(d:SQLDOUBLE):integer;
    function getSQLDOUBLE(var d:SQLDOUBLE):integer;
    function putSQLPOINTER(p:SQLPOINTER):integer;
    function getSQLPOINTER(var p:SQLPOINTER):integer;
    function putSQLDATE(d:TsqlDate):integer;
    function getSQLDATE(var d:TsqlDate):integer;
    function putSQLTIME(t:TsqlTime):integer;
    function getSQLTIME(var t:TsqlTime):integer;
    function putSQLTIMESTAMP(ts:TsqlTimestamp):integer;
    function getSQLTIMESTAMP(var ts:TsqlTimestamp):integer;

    function getComp(var c:Comp):integer; //used for retrieving numeric/decimals from server

    (*todo no longer needed
    {Used for partitioning small communications buffers (packets) into/from larger marshal buffer}
    function putBlock(p:pointer;plen:integer):integer;
    function getBlock(p:pointer;var offset:integer;var plen:integer):integer;
    *)

    function putSQLHENV(EnvironmentHandle:SQLHENV):integer;
    function putSQLHDBC(ConnectionHandle:SQLHDBC):integer;
    function getSQLHDBC(var ConnectionHandle:SQLHDBC):integer;
    function putSQLHSTMT(StatementHandle:SQLHSTMT):integer;
    function getSQLHSTMT(var StatementHandle:SQLHSTMT):integer;
    function putRETCODE(r:RETCODE):integer;
    function getRETCODE(var r:RETCODE):integer;

    function putpSQLCHAR_SWORD(psc:pSQLCHAR;sw:SWORD):integer;
    function getpSQLCHAR_SWORD(var psc:pSQLCHAR;allocated:SWORD;var sw:SWORD):integer;

    function putpUCHAR_SWORD(puc:pUCHAR;sw:SWORD):integer;
    function getpUCHAR_SWORD(var puc:pUCHAR;allocated:SWORD;var sw:SWORD):integer;
    function putpUCHAR_SDWORD(puc:pUCHAR;sdw:SDWORD):integer;
    function getpUCHAR_SDWORD(var puc:pUCHAR;allocated:SDWORD;var sdw:SDWORD):integer;

    function getSDWORD(var sdw:SDWORD):integer;
    function getpUCHAR(var puc:pUCHAR;allocated:SDWORD;sdw:SDWORD):integer;

    function getpData(var p:SQLPOINTER;allocated:SDWORD;sdw:SDWORD):integer;
    function getpDataSDWORD(var p:SQLPOINTER;allocated:SDWORD;var sdw:SDWORD):integer;
    function putpDataSDWORD(p:SQLPOINTER;sdw:SDWORD):integer;
  end; {TMarshalBuffer}

{$IFDEF DEBUG_LOG}
var
  debugDynamicAllocationGetmem:cardinal=0;   //todo remove -or at least make private & thread safe
  debugDynamicAllocationFreemem:cardinal=0;   //todo remove -or at least make private & thread safe
{$ENDIF}

{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses IdGlobal, uGlobal, sysUtils {for debug intToStr only}
{$IFDEF DEBUG_DETAIL}
{$IFDEF DEBUG_LOG}
,uLog
{$ENDIF}
{$ENDIF}
,uEvsHelpers;

{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
{Marshalling routines
   parameters are appended into a buffer
   the completed buffer is sent to the server
   the parameters are unpacked from the buffer

   assumes:
     the server knows the types and number of the parameters
}

constructor TMarshalBuffer.Create(cs:TIdTCPConnection);
var
  vt:TBytes;
begin
  clientSocket:=cs;
  communication_timeout:=$FFFFFFFF; //todo maximum = timeout 0 to SQL
  clearToSend; //initially clear buffer - todo overkill?
  bufferLen:=0;
  bufferPtr:=0;
end; {create}
destructor TMarshalBuffer.Destroy;
begin
  //todo maybe assert buffer is empty?
  //todo remove SocketStream.Free;
  //todo remove SocketStream:=nil;

  inherited;
end; {destroy}


function TMarshalBuffer.SendHandshake:integer;
{Send raw handshake}
var
  i:SQLUSMALLINT;
begin
  result:=fail;
  clientSocket.OpenWriteBuffer;
  try
    i:=SQL_API_handshake;
    clientSocket.WriteBuffer(i, sizeof(i)); //we wait to send the data...
    clientSocket.CloseWriteBuffer;
    result:=ok;
  except
    clientSocket.CancelWriteBuffer;
  end;
end; {SendHandshake}
function TMarshalBuffer.ClearToSend:integer;
{Clear before send}
begin
  bufferLen:=sizeof(bufferlen);   //leave room for blocksize header
  bufferPtr:=sizeof(bufferlen);   //skip blocksize header - note no need - use clearToReceive
  result:=ok;
end; {ClearToSend}
function TMarshalBuffer.ClearToReceive:integer;
{Clear before receive}
begin
  bufferPtr:=sizeof(bufferlen);   //skip blocksize header
  bufferLen:=0;   //start copying blocks at 0 - already includes blocksize header from client
  result:=ok;
end; {ClearToReceive}

function TMarshalBuffer.Send:integer;
{Sends a response and then clears the buffer

 RETURNS:
         ok           complete response sent (assumed was marshalled by caller)
         fail         error (try to reserve for caller error distinction)
         -2           read/write=timeout (uses marshaller's timeout parameter)
         -3           read/write=buffer overflow (marshal buffer contains 1st part of response)
         -5           exception  //todo old comments for sendBuf?-remove: = fatal: I think the connection is closed! todo check!
 Note:
   if result is not ok, the send buffer is not cleared. It is up to the caller to clear it
   either after a re-try or before each new buffer fill.

 //todo we should probably log any errors here, since most callers just pass on the failure code
}
const
  routine=':Send';
  {return errors}
  timeout=-2;
  overflow=-3;
  excepted=-5;

  (*todo leave blocking to Indy:
  Data:array [0..bufSize-1] of char;
  dataCount:integer;
  blocklen:integer;
  offset:integer;
  *)
begin
  result:=ok;
  //todo add trailing checksum
  {set data size as 1st word}
  move(bufferLen,buffer[0],sizeof(bufferLen));

  //no need to assert bufferlen<>0 (which would cause repeat..getBlock..until to loop infinitely)
  //because bufferlen is always at least sizeof(bufferlen) & we're always forced to send 0 at minimum

  try
    //todo create this once outside?!!!!  speed & less memory fragmentation
    {todo user ServerClientWinSocket =clientsocket direct instead...
     & send/receive buf - but receive is via event?ok?
     -no may hang forever if lose during read connection!
    }
    {todo: maybe we should send small buffers to fill the bigger marshal buffer to reduce timeouts due to slow connections
     (as per read)
     and this also should take the strain from the winsock stack/buffer (todo how big is this?)
     - todo check best sizes - (auto-)tuneable?
    }

    {todo: I've read in some WinSockets programming book that it's best to:
       send as much as we can in one block rather than fragment it ourselves
       but to expect receivals may be fragmented
     and in (another?) book:
       send a moderate amount at a time (expecting little of other apps)
        (also, if send fails, try reducing bufferLen and re-sending
         i.e. leave to this routine to retry, rather than caller - sounds good)
       receive as much as possible (be as accomodating as possible)

     - so what to do? - probably up the size of the send and receive buffers...
     - I think TCP/IP defaults to 536 byte packets, but can we control/enlarge this?
    }
//debugIndy    clientSocket.OpenWriteBuffer;
    try
      (*todo remove: leave blocking to Indy
      {Repeatedly send until we have a complete transmission}
      offset:=0;
      blocklen:=sizeof(Data);
      repeat
        if getBlock(@data,offset,blocklen)<>ok then
        begin
          //-this overflow should never happen because we control the buffer sizes & offsets here
          result:=overflow;
          exit; //abort to avoid infinite loop
        end;
        //todo maybe send directly from MarshalBuffer  =direct = speed
        //todo we first need to check the pipe is clear - WaitForData or something?
        {Idle poll waiting for socket to become ready to reduce chance of write timeout}
        //todo instate: SocketStream.WaitForData(WaitForDataTimeout);
        clientSocket.WriteBuffer(Data, blocklen); //we wait to send the data...
        {$IFDEF DEBUG_DETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add('',routine,format('Sending %d bytes (new offset=%d, bufferlen=%d)',[blocklen,offset,bufferlen]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        /*todo trap error
        if dataCount <> blocklen then
        begin
          // If we didn't send enough data after connection_timeout then return timeout error
          //todo - actually after 50 days the max would timeout: should wait forever so skip abort & continue to wait if timeout=max!
          //todo remove! ClientSocket.Close; //note: we assume this disconnects immediately (otherwise the code after the break may not be skipped)
          result:=timeout;
          exit; //abort
        end;
        */
      until offset>=bufferLen; //getBlock should have us finish =the bufferLen (since buffer array starts at 0)
                               // (> is just for safety!)
      *)

      //todo remove, moved later: clearToSend; //clear send buffer, once sent ok

      (*todo any use? - if not remove
      if clientSocket{todo remove.Socket}.Connected then
      begin
        //todo remove until client shares servers uLog... log('Read read:'+intToStr(getBufferLen));
        //todo maybe we could always unmarshal the functionId here?
      end;
      *)
    // todo remove (* todo remove

//debugIndy      clientSocket.WriteBuffer(buffer[0], bufferlen); //we wait to send the data...
      clientSocket.WriteBuffer(buffer[0], bufferlen, True); //we wait to send the data...

      {$IFDEF DEBUG_DETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add('',routine,format('Sending %d bytes',[bufferlen]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

//debugIndy      clientSocket.CloseWriteBuffer;

      clearToSend; //clear send buffer, once sent ok
    except
      on E:Exception do
      begin
        result:=excepted;
        {$IFDEF DEBUG_DETAIL}
        {$IFDEF DEBUG_LOG}
        log.add('',routine,format('Failed sending (%d): %s: %s',[bufferLen,E.className,E.message]),vError);
        {$ENDIF}
        {$ENDIF}
        //try
          clearToSend; //clear send buffer
          clientSocket.CancelWriteBuffer;
        //except
        //  result:=excepted;
          exit;
        //end; {try}
      end;
    end; {try}
    //*)
(* todo remove old method - maybe causing handshake to hang client sometimes on Win98?
    //todo send the buffer in small blocks of bufSize - as we Read!
    //todo use WinSocketStream !/?
    x:=clientSocket.SendBuf(buffer,bufferLen);
    //todo remove log('Marshal.Send:'+intToStr(x)+' bytes');
    if x<>bufferLen then
    begin
      result:=notEnough; //todo caller should try a XXXXXX to clear channel & re-send?
      exit; //note: we avoid clearing Send buffer - caller's responsibility
    end;
    clearToSend; //clear send buffer, once sent ok
*)
  except
    (*todo remove
    on E:ESocketError do //todo check this is appropriate kind of exception still -also in Read below
    begin
      result:=excepted;
      //todo pass/interpret E.message somewhere!
      //todo old sendBuf comments: remove?: Note: caller needs to handle fact that this connect has now been terminated - maybe auto-reconnect?
      //see 08S01...
      //todo up to caller to clear send buffer!
      exit;
    end;
    *)
    on E:Exception do
    begin
      result:=excepted;
      {$IFDEF DEBUG_DETAIL}
      {$IFDEF DEBUG_LOG}
      log.add('',routine,format('Failed sending (b) (%d): %s: %s',[bufferLen,E.className,E.message]),vError);
      {$ENDIF}
      {$ENDIF}
      //todo pass/interpret E.message somewhere!
      //todo old sendBuf comments: remove?: Note: caller needs to handle fact that this connect has now been terminated - maybe auto-reconnect?
      //see 08S01...
      //todo up to caller to clear send buffer!
      exit;
    end;
  end; {try}
end; {Send}
function TMarshalBuffer.Read:integer;
{Waits for a response (clears buffer before receiving)
 //todo should really be called Receive, but component has OnRead event...

 RETURNS:
         ok           complete response received (needs unmarshalling by caller)
         fail         error (try to reserve for caller error distinction)
         -2           timeout (uses marshaller's timeout parameter)
         -3           buffer overflow (marshal buffer contains 1st part of response)
         -5           exception

 //todo we should probably log any errors here, since most callers just pass on the failure code
}
const
  {return errors}
  timeout=-2;
  overflow=-3;
  excepted=-5;
var

//todo remove  Data:array [0..bufSize-1] of char;
//todo remove  Data:array [0..sizeof(bufferlen)] of char;
  dataCount:integer;
begin
  result:=ok;
  try
    //todo create this once outside?!!!!  speed
    {todo user ServerClientWinSocket =clientsocket direct instead...
     & send/receive buf - but receive is via event?ok?
     -no may hang forever if lose during read connection!
    }
    {We read small buffers to fill the bigger marshal buffer to reduce timeouts due to slow connections
     and this also should take the strain from the winsock stack/buffer (todo how big is this?)
     - todo check best sizes - (auto-)tuneable?
    }
    try
      ClearToReceive;
      (*todo remove:
      {Repeatedly read until we have a complete transmission}
      repeat
        FillChar(Data, SizeOf(Data), 0); //todo remove? eases debugging if it's cleared
        //todo maybe read directly into MarshalBuffer  =direct = speed
        //todo we first need to check the pipe is clear - WaitForData or something?
        {Idle poll waiting for socket to become ready to reduce chance of read timeout}
        //todo instate: SocketStream.WaitForData(WaitForDataTimeout);
        //dataCount:=clientSocket.CurrentReadBufferSize; //todo wait here for some data...
        //if dataCount <> 0 then
        //begin
        clientSocket.ReadBuffer(data,1); //todo use readInteger + readBuffer to avoid loop! - need timeout!
        //end;
        if putBlock(@data,1)<>ok then
        begin
          //todo remove until client shares servers uLog... log('Read buffer overflow:'+intToStr(getBufferLen));
          //todo fix/workaround! /error 08S01?
          //todo we need to consume the rest, otherwise we can't re-sync!
          // - maybe send to server a re-sync request/handshake?
          //-although this overflow should never happen because server uses same size marshal buffer (?)
          result:=overflow;
          exit; //abort to avoid infinite loop
        end;
      until DataComplete;
      *)

      {Read the block length directly into the marshal buffer}
      //todo in future use readInteger: platform friendlier?
      clientSocket.ReadBuffer(buffer[bufferLen{=0}],sizeof(bufferlen)); //todo need timeout
      bufferLen:=bufferLen+sizeof(bufferlen);
      {Assert we have enough room}
      move(buffer[0],dataCount,sizeof(dataCount));
      dataCount:=dataCount-sizeof(bufferlen); //inclusive
      if bufferLen+dataCount>marshalBufSize then //todo can remove assertion =speed?
      begin
        //todo remove until client shares servers uLog... log('Read buffer overflow:'+intToStr(getBufferLen));
        //todo fix/workaround! /error 08S01?
        //todo we need to consume the rest, otherwise we can't re-sync!
        // - maybe send to server a re-sync request/handshake?
        //-although this overflow should never happen because server uses same size marshal buffer (?)
        result:=overflow;
        exit; //abort to avoid infinite loop
      end;

      {Read the block data directly into the marshal buffer}
      clientSocket.ReadBuffer(buffer[bufferLen],dataCount); //todo need timeout
      bufferLen:=bufferLen+dataCount;

      //todo: assert DataComplete - is this function now obsolete?

      (*todo any use? - if not remove
      if clientSocket{todo remove.Socket}.Connected then
      begin
        //todo remove until client shares servers uLog... log('Read read:'+intToStr(getBufferLen));
        //todo maybe we could always unmarshal the functionId here?
      end;
      *)
    //todo remove (* todo remove
    finally
      (*todo remove
      SocketStream.Free;
      SocketStream:=nil;
      *)
    end;
    //*)
  except
    //todo !!! HandleException; //todo improve!   -or leave to caller to catch? - as long as we don't bring down the server!
    (*todo remove
    on E:ESocketError do
    begin
      result:=excepted;
      //todo pass/interpret E.message somewhere!
      //todo old sendBuf comments?: remove: Note: caller needs to handle fact that this connect has now been terminated - maybe auto-reconnect?
      //see 08S01...
      //todo up to caller to handle/ignore parital/missing receive buffer!
      exit;
    end;
    *)
    on E:Exception do
    begin
      result:=excepted;
      //todo pass/interpret E.message somewhere!
      //todo old sendBuf comments: remove?: Note: caller needs to handle fact that this connect has now been terminated - maybe auto-reconnect?
      //see 08S01...
      //todo up to caller to clear send buffer!
      exit;
    end;
  end;
end; {Read}
function TMarshalBuffer.DataComplete:boolean;
{Check whether the buffer has been totally read yet
 Note:
   the block-size (i.e. the 1st word of every buffer sent & received) is always <= marshal buffer size
   and is used to allow us to send and receive small blocks to make up one big buffer, i.e.
   it tells Read when we have the complete big buffer.

   It does not mean there is not more to come. It is up to the client to get() required results which
   will call the Read routine as needed, i.e. if we need another (or part of a) big buffer.
   Similarly, calling the put() routines call the Send routine to send a full buffer as and when required.

   The sender should still call the Send routine after putting all data, to flush any remaining partial buffer.
    - also sender should still call clearToSend before putting to ensure any previous Send failure is cleared
   And the reader should still call the Read routine before getting any data, to load the initial buffer.
}
var
  x:integer;
begin
  {Skip check if we haven't read the size yet}
  if bufferLen<sizeof(x) then
  begin
    result:=False;
    exit;
  end;

  move(buffer[0],x,sizeof(x));
  if x=bufferLen then
    result:=True
  else
    result:=False;
end; {DataComplete}

function TMarshalBuffer.putFunction(FunctionId:SQLUSMALLINT):integer;
{The 1st item in the marshal buffer is the function id
 - this allows the server to unpack the parameters in the correct way
}
begin
  result:=putSQLUSMALLINT(FunctionId);
end;
function TMarshalBuffer.getFunction(var FunctionId:SQLUSMALLINT):integer;
{The 1st item in the marshal buffer is the function id
 - this allows the server to unpack the parameters in the correct way
}
begin
  result:=getSQLUSMALLINT(FunctionId);
  //todo maybe return fail if functionId is not valid
end;

(*todo no longer needed
function TMarshalBuffer.putBlock(p:pointer;plen:integer):integer;
{Used for receiving small buffers into the larger marshal buffer
 //todo may become obsolete if we receive directly into the marshalBuffer - speed
 //todo+ the Read routine now does this...
}
begin
  if bufferLen+plen>marshalBufSize then //todo can remove assertion =speed?
  begin
    result:=fail; //buffer overflow - should never happen (cos we were originally sent from same size marshal buffer)
    exit;
  end;
  move(p^,buffer[bufferLen],plen);
  bufferLen:=bufferLen+plen;
  result:=ok;
end; {putBlock}
function TMarshalBuffer.getBlock(p:pointer;var offset:integer;var plen:integer):integer;
{Used for sending small buffers from the larger marshal buffer
 //todo may become obsolete if we send directly from the marshalBuffer - speed
 IN:        p               small buffer to receive data
            offset          offset in large buffer - reset by caller before start
            plen            size of small buffer
 OUT:       offset          offset ready for next call (=bufferLen => no more data)
            plen            size of data moved (less than original plen if last block of buffer)

 Assumes:
  p has allocated >= plen
}
begin
  if offset>bufferLen then //todo can remove assertion =speed?
  begin
    result:=fail; //buffer overflow - should never happen (cos caller shouldn't try this)
    exit;
  end;
  if offset+plen>bufferLen then plen:=bufferLen-offset; //not enough for a full buffer
  move(buffer[offset],p^,plen);
  offset:=offset+plen;
  result:=ok;
end; {getBlock}
*)

function TMarshalBuffer.putSQLUSMALLINT(usi:SQLUSMALLINT):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(usi)>marshalBufSize then //todo can remove assertion =speed?
  begin
    result:=Send;
    if result<>ok then exit; //buffer overflow, else we've cleared room for the data
  end;
  if bufferLen+sizeof(usi)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(usi,buffer[bufferLen],sizeof(usi));
  bufferLen:=bufferLen+sizeof(usi);
  result:=ok;
end; {putSQLUSMALLINT}
function TMarshalBuffer.getSQLUSMALLINT(var usi:SQLUSMALLINT):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(usi)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;
  move(buffer[bufferPtr],usi,sizeof(usi));
  bufferPtr:=bufferPtr+sizeof(usi);
  result:=ok;
end; {getSQLUSMALLINT}

function TMarshalBuffer.putSQLSMALLINT(si:SQLSMALLINT):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(si)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(si)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(si,buffer[bufferLen],sizeof(si));
  bufferLen:=bufferLen+sizeof(si);
  result:=ok;
end; {putSQLSMALLINT}
function TMarshalBuffer.getSQLSMALLINT(var si:SQLSMALLINT):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(si)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],si,sizeof(si));
  bufferPtr:=bufferPtr+sizeof(si);
  result:=ok;
end; {getSQLSMALLINT}

function TMarshalBuffer.putSQLINTEGER(i:SQLINTEGER):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(i)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(i)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(i,buffer[bufferLen],sizeof(i));
  bufferLen:=bufferLen+sizeof(i);
  result:=ok;
end; {putSQLINTEGER}
function TMarshalBuffer.getSQLINTEGER(var i:SQLINTEGER):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(i)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],i,sizeof(i));
  bufferPtr:=bufferPtr+sizeof(i);
  result:=ok;
end; {getSQLINTEGER}

function TMarshalBuffer.putSQLUINTEGER(ui:SQLUINTEGER):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(ui)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(ui)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(ui,buffer[bufferLen],sizeof(ui));
  bufferLen:=bufferLen+sizeof(ui);
  result:=ok;
end; {putSQLUINTEGER}
function TMarshalBuffer.getSQLUINTEGER(var ui:SQLUINTEGER):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(ui)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],ui,sizeof(ui));
  bufferPtr:=bufferPtr+sizeof(ui);
  result:=ok;
end; {getSQLUINTEGER}

function TMarshalBuffer.putSQLDOUBLE(d:SQLDOUBLE):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(d)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(d)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(d,buffer[bufferLen],sizeof(d));
  bufferLen:=bufferLen+sizeof(d);
  result:=ok;
end; {putSQLDOUBLE}
function TMarshalBuffer.getSQLDOUBLE(var d:SQLDOUBLE):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(d)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],d,sizeof(d));
  bufferPtr:=bufferPtr+sizeof(d);
  result:=ok;
end; {getSQLDOUBLE}

function TMarshalBuffer.putSQLPOINTER(p:SQLPOINTER):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(p)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(p)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(p,buffer[bufferLen],sizeof(p));
  bufferLen:=bufferLen+sizeof(p);
  result:=ok;
end; {putSQLPOINTER}
function TMarshalBuffer.getSQLPOINTER(var p:SQLPOINTER):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(p)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],p,sizeof(p));
  bufferPtr:=bufferPtr+sizeof(p);
  result:=ok;
end; {getSQLPOINTER}

function TMarshalBuffer.putSQLDATE(d:TsqlDate):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(d)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(d)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(d,buffer[bufferLen],sizeof(d));
  bufferLen:=bufferLen+sizeof(d);
  result:=ok;
end; {putSQLDATE}
function TMarshalBuffer.getSQLDATE(var d:TsqlDate):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(d)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],d,sizeof(d));
  bufferPtr:=bufferPtr+sizeof(d);
  result:=ok;
end; {getSQLDATE}

function TMarshalBuffer.putSQLTIME(t:TsqlTime):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(t)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(t)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(t,buffer[bufferLen],sizeof(t));
  bufferLen:=bufferLen+sizeof(t);
  result:=ok;
end; {putSQLTIME}
function TMarshalBuffer.getSQLTIME(var t:TsqlTime):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(t)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],t,sizeof(t));
  bufferPtr:=bufferPtr+sizeof(t);
  result:=ok;
end; {getSQLTIME}

function TMarshalBuffer.putSQLTIMESTAMP(ts:TsqlTimestamp):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send
}
begin
  if bufferLen+sizeof(ts)>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(ts)>marshalBufSize then //todo can remove assertion =speed?
  begin //can never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(ts,buffer[bufferLen],sizeof(ts));
  bufferLen:=bufferLen+sizeof(ts);
  result:=ok;
end; {putSQLTIMESTAMP}
function TMarshalBuffer.getSQLTIMESTAMP(var ts:TsqlTimestamp):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(ts)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],ts,sizeof(ts));
  bufferPtr:=bufferPtr+sizeof(ts);
  result:=ok;
end; {getSQLTIMESTAMP}


function TMarshalBuffer.getComp(var c:Comp):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read
}
begin
  if bufferPtr+sizeof(c)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],c,sizeof(c));
  bufferPtr:=bufferPtr+sizeof(c);
  result:=ok;
end; {getComp}


function TMarshalBuffer.putSQLHENV(EnvironmentHandle:SQLHENV):integer;
//todo may never be needed - env is client side only...?
begin
  result:=putSQLINTEGER(EnvironmentHandle);
end; {putSQLHENV}

function TMarshalBuffer.putSQLHDBC(ConnectionHandle:SQLHDBC):integer;
begin
  result:=putSQLINTEGER(ConnectionHandle);
end; {putSQLHDBC}
function TMarshalBuffer.getSQLHDBC(var ConnectionHandle:SQLHDBC):integer;
begin
  result:=getSQLINTEGER(ConnectionHandle);
end; {getSQLHDBC}

function TMarshalBuffer.putSQLHSTMT(StatementHandle:SQLHSTMT):integer;
begin
  result:=putSQLINTEGER(StatementHandle);
end; {putSQLHSTMT}
function TMarshalBuffer.getSQLHSTMT(var StatementHandle:SQLHSTMT):integer;
begin
  result:=getSQLINTEGER(StatementHandle);
end; {getSQLHSTMT}

function TMarshalBuffer.putRETCODE(r:RETCODE):integer;
begin
  result:=putSQLSMALLINT(r);
end; {putRETCODE}
function TMarshalBuffer.getRETCODE(var r:RETCODE):integer;
begin
  result:=getSQLSMALLINT(r);
end; {getRETCODE}

function TMarshalBuffer.getSDWORD(var sdw:SDWORD):integer;
begin
  result:=getSQLINTEGER(sdw);
end; {getSDWORD}

function TMarshalBuffer.putpSQLCHAR_SWORD(psc:pSQLCHAR;sw:SWORD):integer;
begin
  //note: trivial cast from pSQLCHAR to pUCHAR
  result:=putpUCHAR_SWORD(pUCHAR(psc),sw);
end; {putpSQLCHAR_SWORD}
function TMarshalBuffer.getpSQLCHAR_SWORD(var psc:pSQLCHAR;allocated:SWORD;var sw:SWORD):integer;
begin
  //note: trivial cast from pSQLCHAR to pUCHAR
  result:=getpUCHAR_SWORD(pUCHAR(psc),allocated,sw);
end; {getpSQLCHAR_SWORD}

function TMarshalBuffer.putpUCHAR_SWORD(puc:pUCHAR;sw:SWORD):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send

 If not null terminated, sends a trailing nullterm character
}
var addnull:boolean;
begin
  //todo handle SQL_NTS - avoid need for separate FixString routine
  if sw<0 then
  begin
    result:=fail; //invalid length - assertion //todo log!
    exit;
  end;

  if length(puc)=sw then //todo remove (puc+sw-1)^<>nullterm then
  begin
   sw:=sw+sizeof(nullterm);
   addnull:=true;
  end
  else
   addnull:=false;

  if bufferLen+sizeof(sw)+sw>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(sw)+sw>marshalBufSize then //todo can remove assertion =speed?
  begin //should never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(sw,buffer[bufferLen],sizeof(sw));
  bufferLen:=bufferLen+sizeof(sw);
  if addnull then //todo remove (puc+sw-1)^<>nullterm then
  begin
    move(puc^,buffer[bufferLen],sw-sizeof(nullterm));
    move(nullterm,buffer[bufferLen+sw-sizeof(nullterm)],sizeof(nullterm));
  end
  else
    move(puc^,buffer[bufferLen],sw);

  bufferLen:=bufferLen+sw;
  result:=ok;
end; {putpUCHAR_SWORD}
function TMarshalBuffer.getpUCHAR_SWORD(var puc:pUCHAR;allocated:SWORD;var sw:SWORD):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read

 Assumes:
   puc has 'allocated' space allocated by caller,
   unless -1 => allocate here (but caller must free!)
 Note:
   returns buffer data up to the allocated length (including 1 character for a null terminator)
}
const routine=':getpUCHAR_SWORD';
var actual:SWORD;
begin
  if bufferPtr+sizeof(sw)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],sw,sizeof(sw));
  bufferPtr:=bufferPtr+sizeof(sw);

  if bufferPtr+sw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  if allocated=DYNAMIC_ALLOCATION then
  begin
    {Now allocate the space for the buffer data
     todo: is here the best place or should the caller read the sw & then allocate & then read buffer?}

    getMem(puc,sw+sizeof(nullterm)); //Note: we add 1 to rebuild the string with a null terminator
    allocated:=sw+sizeof(nullterm);
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add('',routine,format('Dynamic allocation %d',[allocated]),vDebugLow);
    debugDynamicAllocationGetmem:=debugDynamicAllocationGetmem+allocated;
    {$ENDIF}
    {$ENDIF}
  end;

  if (allocated-sizeof(nullterm))<sw then actual:=(allocated-sizeof(nullterm)) else actual:=sw;
  move(buffer[bufferPtr],puc^,actual); //may not read all buffer data
  move(nullterm,(puc+actual)^,sizeof(nullterm));
  bufferPtr:=bufferPtr+sw;
  result:=ok;
end; {getpUCHAR_SWORD}

function TMarshalBuffer.putpUCHAR_SDWORD(puc:pUCHAR;sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send

 If not null terminated, sends a trailing nullterm character
}
var addnull:boolean;
begin
  //todo handle SQL_NTS - avoid need for separate FixString routine
  if sdw<0 then
  begin
    result:=fail; //invalid length - assertion //todo log!
    exit;
  end;

  if length(puc)=sdw then //todo remove (puc+sdw-1)^<>nullterm then
  begin
   sdw:=sdw+sizeof(nullterm);
   addnull:=true;
  end
  else
   addnull:=false;

  if bufferLen+sizeof(sdw)+sdw>marshalBufSize then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;
  if bufferLen+sizeof(sdw)+sdw>marshalBufSize then //todo can remove assertion =speed?
  begin //should never happen!
    result:=fail; //item too big for buffer - needs to be split - todo
    exit; //abort
  end;

  move(sdw,buffer[bufferLen],sizeof(sdw));
  bufferLen:=bufferLen+sizeof(sdw);
  if addnull then //todo remove (puc+sdw-1)^<>nullterm then
  begin
    move(puc^,buffer[bufferLen],sdw-sizeof(nullterm));
    move(nullterm,buffer[bufferLen+sdw-sizeof(nullterm)],sizeof(nullterm));
  end
  else
    move(puc^,buffer[bufferLen],sdw);

  bufferLen:=bufferLen+sdw;
  result:=ok;
end; {putpUCHAR_SDWORD}
function TMarshalBuffer.getpUCHAR_SDWORD(var puc:pUCHAR;allocated:SDWORD;var sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read

 Assumes:
   puc has 'allocated' space allocated by caller,
   unless -1 => allocate here (but caller must free!)
 Note:
   returns buffer data up to the passed length (including 1 character for a null terminator)
}
const routine=':getpUCHAR_SDWORD';
var actual:SDWORD;
begin

//todo call getSDWORD and then getpUCHAR ? - apply to all getp?WORD... double get routines...?
//     -although less overhead reading them together & they do come in pairs...

  if bufferPtr+sizeof(sdw)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  move(buffer[bufferPtr],sdw,sizeof(sdw));
  bufferPtr:=bufferPtr+sizeof(sdw);

  if bufferPtr+sdw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  if allocated=DYNAMIC_ALLOCATION then
  begin
    {Now allocate the space for the buffer data
     todo: is here the best place or should the caller read the sw & then allocate & then read buffer?}

    getMem(puc,sdw+sizeof(nullterm)); //Note: we add 1 to rebuild the string with a null terminator
    allocated:=sdw+sizeof(nullterm);
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add('',routine,format('Dynamic allocation %d',[allocated]),vDebugLow);
    debugDynamicAllocationGetmem:=debugDynamicAllocationGetmem+allocated;
    {$ENDIF}
    {$ENDIF}
  end;

  if (allocated-sizeof(nullterm))<sdw then actual:=(allocated-sizeof(nullterm)) else actual:=sdw;
  move(buffer[bufferPtr],puc^,actual);
  move(nullterm,(puc+actual)^,sizeof(nullterm));
  bufferPtr:=bufferPtr+sdw;
  result:=ok;
end; {getpUCHAR_SDWORD}

function TMarshalBuffer.getpUCHAR(var puc:pUCHAR;allocated:SDWORD;sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read

 Assumes:
   puc has 'allocated' space allocated by caller,
   unless -1 => allocate here (but caller must free!)

   sdw has just been read from marshalBuffer, i.e. this next data is guaranteed to be *exactly* sdw long

 Note:
   returns buffer data up to the passed length (including 1 character for a null terminator)
}
const routine=':getpUCHAR';
var actual:SDWORD;
begin
  if bufferPtr+sdw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end
    else
    begin //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
      result:=fail; //buffer overflow
      exit;
    end;
  end;

  if allocated=DYNAMIC_ALLOCATION then
  begin
    {Now allocate the space for the buffer data
     todo: is here the best place or should the caller read the sw & then allocate & then read buffer?}

    getMem(puc,sdw+sizeof(nullterm)); //Note: we add 1 to rebuild the string with a null terminator
    allocated:=sdw+sizeof(nullterm);
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add('',routine,format('Dynamic allocation %d',[allocated]),vDebugLow);
    debugDynamicAllocationGetmem:=debugDynamicAllocationGetmem+allocated;
    {$ENDIF}
    {$ENDIF}
  end;

  if (allocated-sizeof(nullterm))<sdw then actual:=(allocated-sizeof(nullterm)) else actual:=sdw;
  move(buffer[bufferPtr],puc^,actual);
  move(nullterm,(puc+actual)^,sizeof(nullterm));
  bufferPtr:=bufferPtr+sdw;
  result:=ok;
end; {getpUCHAR}

function TMarshalBuffer.getpData(var p:SQLPOINTER;allocated:SDWORD;sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read

 Assumes:
   p has 'allocated' space allocated by caller,
   unless -1 => allocate here (but caller must free!)

   sdw has just been read from marshalBuffer, i.e. this next data is guaranteed to be *exactly* sdw long

 Note:
   returns buffer data up to the passed length (no null terminator is added)
}
const routine=':getpData';
var
  actual,actualWritten:SDWORD;
  offset,nextSegment:SDWORD;
  target:pointer;
begin
  if bufferPtr+sdw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end;
  end;

  if allocated=DYNAMIC_ALLOCATION then
  begin
    {Now allocate the space for the buffer data
     todo: is here the best place or should the caller read the sw & then allocate & then read buffer?}

    getMem(p,sdw);
    allocated:=sdw;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add('',routine,format('Dynamic allocation %d',[allocated]),vDebugLow);
    debugDynamicAllocationGetmem:=debugDynamicAllocationGetmem+allocated;
    {$ENDIF}
    {$ENDIF}
  end;

  if (allocated)<sdw then actual:=(allocated) else actual:=sdw; //amount to actually store

  if bufferPtr+sdw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end;

    begin //can only happen when reading a large object - we read in multiple segments (or else we must be asking for the wrong data type)
      offset:=0;
      target:=p;
      actualWritten:=0;
      repeat
        nextSegment:=bufferLen-bufferPtr; //size of next segment in remaining buffer
        if actualWritten+nextSegment<=actual then
        begin
          move(buffer[bufferPtr],target^,nextSegment);
          actualWritten:=actualWritten+nextSegment;
          target:=pchar(target)+nextSegment;
        end;
        //else truncated //todo return warning here? //todo maybe could fit more in rather than truncate at block boundary?
        bufferPtr:=bufferPtr+nextSegment;
        //todo could/should avoid final Read... i.e. if offset+nextSegment>=sdw
        if Read<>ok then
        begin
          result:=fail; //buffer overflow
          exit;
        end; //else we've got the next buffer full

        offset:=offset+nextSegment;
      until offset>=sdw; //note > is just for safety //todo assert offset=sdw
      //todo result:=+1? i.e. indicate to caller than segments have been read
    end;
  end
  else
  begin //fits in a single buffer
    move(buffer[bufferPtr],p^,actual);
    bufferPtr:=bufferPtr+sdw;
  end;
  result:=ok;
end; {getpData}

function TMarshalBuffer.getpDataSDWORD(var p:SQLPOINTER;allocated:SDWORD;var sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is left in buffer, but not enough
          else errors as from Read

 Assumes:
   p has 'allocated' space allocated by caller,
   unless -1 => allocate here (but caller must free!)

 Note:
   returns buffer data up to the passed length (no null terminator is added)
}
const routine=':getpDataSDWORD';
var
  actual,actualWritten:SDWORD;
  offset,nextSegment:SDWORD;
  target:pointer;
begin
//todo call getSDWORD and then getpData ? - apply to all getp?WORD... double get routines...?

  if bufferPtr+sizeof(sdw)>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end;
  end;

  move(buffer[bufferPtr],sdw,sizeof(sdw));
  bufferPtr:=bufferPtr+sizeof(sdw);

  if allocated=DYNAMIC_ALLOCATION then
  begin
    {Now allocate the space for the buffer data
     todo: is here the best place or should the caller read the sw & then allocate & then read buffer?}

    getMem(p,sdw);
    allocated:=sdw;
    {$IFDEF DEBUG_DETAIL}
    {$IFDEF DEBUG_LOG}
    log.add('',routine,format('Dynamic allocation %d',[allocated]),vDebugLow);
    debugDynamicAllocationGetmem:=debugDynamicAllocationGetmem+allocated;
    {$ENDIF}
    {$ENDIF}
  end;

  if (allocated)<sdw then actual:=(allocated) else actual:=sdw; //amount to actually store

  if bufferPtr+sdw>bufferLen then
  begin
    if bufferPtr=bufferLen then //todo can remove assertion =speed?
    begin //the buffer is empty
      result:=Read;
      if result<>ok then exit; //abort, else we've got the next buffer full
    end;

    begin //can only happen when reading a large object - we read in multiple segments (or else we must be asking for the wrong data type)
      offset:=0;
      target:=p;
      actualWritten:=0;
      repeat
        nextSegment:=bufferLen-bufferPtr; //size of next segment in remaining buffer
        if actualWritten+nextSegment<=actual then
        begin
          move(buffer[bufferPtr],target^,nextSegment);
          actualWritten:=actualWritten+nextSegment;
          target:=pchar(target)+nextSegment;
        end;
        //else truncated //todo return warning here? //todo maybe could fit more in rather than truncate at block boundary?
        bufferPtr:=bufferPtr+nextSegment;
        //todo could/should avoid final Read... i.e. if offset+nextSegment>=sdw
        if Read<>ok then
        begin
          result:=fail; //buffer overflow
          exit;
        end; //else we've got the next buffer full

        offset:=offset+nextSegment;
      until offset>=sdw; //note > is just for safety //todo assert offset=sdw
      //todo result:=+1? i.e. indicate to caller than segments have been read
    end;
  end
  else
  begin //fits in a single buffer
    move(buffer[bufferPtr],p^,actual);
    bufferPtr:=bufferPtr+sdw;
  end;
  result:=ok;
end; {getpDataSDWORD}

//todo remove: isn't this the same as putpUCHAR_SDWORD????!!!!, ie. no \0 added!
function TMarshalBuffer.putpDataSDWORD(p:SQLPOINTER;sdw:SDWORD):integer;
{RETURNS: ok,
          fail  = probably means data is too big for buffer
          else errors as from Send

 Note: possibly calls Send, which might mean caller is unable to cancel buffer
}
var
  offset,nextSegment:SDWORD;
  source:pointer;
begin
//todo call putSDWORD and then putpData ? - apply to all putp?WORD... double put routines...?

  if sdw<0 then
  begin
    result:=fail; //invalid length - assertion //todo log!
    exit;
  end;

  if (bufferLen>0){no need to send empty buffer if blob} and (bufferLen+sizeof(sdw)+sdw>marshalBufSize) then //todo can remove assertion =speed?
  begin
    if Send<>ok then
    begin
      result:=fail; //buffer overflow
      exit;
    end; //else we've cleared room for the data
  end;

  move(sdw,buffer[bufferLen],sizeof(sdw));
  bufferLen:=bufferLen+sizeof(sdw);

  if bufferLen+sdw>marshalBufSize then //todo can remove assertion =speed?
  begin //can only happen when sending a large object - we send in multiple segments
    offset:=0;
    source:=p;
    repeat
      nextSegment:=marshalBufSize-bufferLen; //max. size of next segment that can fit in remaining buffer
      if nextSegment>(sdw-offset) then nextSegment:=(sdw-offset); //final segment
      move(source^,buffer[bufferLen],nextSegment);
      bufferLen:=bufferLen+nextSegment;
      //todo could/should defer final Send to caller... i.e. if offset+nextSegment>=sdw
      if Send<>ok then
      begin
        result:=fail; //buffer overflow
        exit;
      end; //else we've cleared room for the data

      offset:=offset+nextSegment;
      source:=pchar(source)+nextSegment;
    until offset>=sdw; //note > is just for safety //todo assert offset=sdw
    //todo result:=+1? i.e. indicate to caller than segments have been sent
  end
  else
  begin //fits in a single buffer
    move(p^,buffer[bufferLen],sdw);
    bufferLen:=bufferLen+sdw;
  end;
  result:=ok;
end; {putpDataSDWORD}

{$ENDIF}


{$IFNDEF DBEXP_STATIC}

end.
{$ENDIF}


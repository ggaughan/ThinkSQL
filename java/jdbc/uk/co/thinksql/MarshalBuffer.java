package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import java.io.*;
import java.lang.*;
import java.net.*;
import java.util.*;
import java.sql.*;

import uk.co.thinksql.Global.*;

public class MarshalBuffer
{
  int marshalBufSize=16384; //updated from 4096 for release 0.4 
  
 	
  private Socket clientSocket;
  private InputStream input;
  private BufferedOutputStream output;
  
  private byte buffer[] = new byte[marshalBufSize/*-1*/]; //todo protect (the whole MarshalBuffer!) with criticalSection...
                                                      //since multiple client threads could share the same connection 
                                                      
                                                      
  private int bufferLen;
  private int bufferPtr; //todo rename to BufferPos
  
  public int ClearToSend() {
  //Clear before send
    bufferLen=0; //sizeof(bufferlen);   //leave room for blocksize header
    bufferPtr=0; //sizeof(bufferlen);   //skip blocksize header - note no need - use clearToReceive
    return Global.ok;
  }
  
  public int ClearToReceive() 
  {//Clear before receive
    bufferPtr=0; //sizeof(bufferlen);   //skip blocksize header
    bufferLen=0;   //start copying blocks at 0 - already includes blocksize header from client
    return Global.ok;
  }


  /**
   * Constructor:  Connect to the back end and return
   * a stream connection.
   *
   * @param host the hostname to connect to
   * @param port the port number that the postmaster is sitting on
   * @exception IOException if an IOException occurs below it.
   */
  public MarshalBuffer(String host, int port) throws IOException 
  {
    clientSocket = new Socket(host, port);

    // adds a 10x speed improvement on FreeBSD machines (caused by a bug in their TCP Stack)
    //connection.setTcpNoDelay(true);

    input = new BufferedInputStream(clientSocket.getInputStream(), marshalBufSize);
    output = new BufferedOutputStream(clientSocket.getOutputStream(), marshalBufSize);

    ClearToSend(); //initially clear buffer - todo overkill?
    bufferLen=0;
    bufferPtr=0;
  }

  public int SendHandshake()
  {//Send raw handshake
    byte b[]=new byte[Global.sizeof_short];
    short is;
    
    //clientSocket.OpenWriteBuffer;
    try
    {
      is=Global.SQL_API_handshake; 
      b[0] = (byte)(is & 0xff);
      is >>= Global.sizeof_byte;
      b[1] = (byte)(is & 0xff);
      //System.out.println("HS 0:"+b[0]);
      //System.out.println("HS 1:"+b[1]);
      
      output.write(b,0,Global.sizeof_short); //we wait to send the data...
      output.flush();
      return Global.ok;
    }
    catch (IOException e) {
        return Global.fail;
      }    
  //clientSocket.CancelWriteBuffer;
  }

  /*
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

    {Used for partitioning small communications buffers (packets) into/from larger marshal buffer}
    function putBlock(p:pointer;plen:integer):integer;
    function getBlock(p:pointer;var offset:integer;var plen:integer):integer;

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
  */

  public int Send()
  {/*Sends a response and then clears the buffer

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
   */


    //return errors
    int timeout=-2;
    int overflow=-3;
    int excepted=-5;

    //Data:array [0..bufSize-1] of char;
    //dataCount:integer;
    int blocklen;
    int offset;
    //result:=ok;
    //todo add trailing checksum
  
    //send data size as 1st word
    //move(bufferLen,buffer[0],sizeof(bufferLen)); 
    byte b[]=new byte[Global.sizeof_int];
    int i;
    
    //clientSocket.OpenWriteBuffer;
    try
    {
      i=(bufferLen+Global.sizeof_int); //note + added in Java version (not using getBlock)
      b[0] = (byte)(i & 0xff);
      i >>= Global.sizeof_byte;
      b[1] = (byte)(i & 0xff);
      i >>= Global.sizeof_byte;
      b[2] = (byte)(i & 0xff);
      i >>= Global.sizeof_byte;
      b[3] = (byte)(i & 0xff);
      
      //System.out.println("Send 0:"+b[0]);
      //System.out.println("Send 1:"+b[1]);
      //System.out.println("Send 2:"+b[2]);
      //System.out.println("Send 3:"+b[3]);
      
      output.write(b,0,Global.sizeof_int); //we wait to send the data...

      //System.out.println("Send bufferLen:"+bufferLen);
      //System.out.println("Send buffer0:"+buffer[0]);
      //System.out.println("Send buffer1:"+buffer[1]);
      
      output.write(buffer,0,bufferLen);  
    }
    catch (IOException e) {
        return Global.fail;
      }    

    //todo need to assert bufferlen<>0 (which would cause repeat..getBlock..until to loop infinitely)
    //because bufferlen is not always at least sizeof(bufferlen) & we're not always forced to send 0 at minimum

    try
    {
      //clientSocket.OpenWriteBuffer;
      //try
        
      ClearToSend(); //clear send buffer, once sent ok

      output.flush();
      
      return Global.ok;
    }  
    catch (IOException e) {
        return Global.fail;
    }    
      
  }
  
  public int Read()
  {/* Waits for a response (clears buffer before receiving)
      //todo should really be called Receive, but component has OnRead event...

   RETURNS:
         ok           complete response received (needs unmarshalling by caller)
         fail         error (try to reserve for caller error distinction)
         -2           timeout (uses marshaller's timeout parameter)
         -3           buffer overflow (marshal buffer contains 1st part of response)
         -5           exception

   //todo we should probably log any errors here, since most callers just pass on the failure code
  */
  
    int res;
    //return errors
    int timeout=-2;
    int overflow=-3;
    int excepted=-5;

    //todo remove  Data:array [0..bufSize-1] of char;
    //todo remove  Data:array [0..sizeof(bufferlen)] of char;
    int dataCount=0;


    //try
    //{
      /* We read small buffers to fill the bigger marshal buffer to reduce timeouts due to slow connections
       and this also should take the strain from the winsock stack/buffer (todo how big is this?)
       - todo check best sizes - (auto-)tuneable?
      */
      ClearToReceive();
      //Read the block length directly into the marshal buffer
      //todo in future use readInteger: platform friendlier?
    
      byte bi[]=new byte[Global.sizeof_int];
      int i;
      int debug;

      try
      {     
        //todo remove dataCount=input.read(); //we wait to read the data...
        //while((
        res=input.read(bi,0,Global.sizeof_int); //we wait to read the data...
        //)==-1) { /* nowt */}; 
        if (res==-1) { //eof
          return Global.fail;  
        }
        //todo: could set bufferLen=res?
        //todo call getINTEGER!
        i=0;
        //for (int siz=0; siz<Global.sizeof_short; siz++) {
        for (int siz=Global.sizeof_int-1; siz>=0; siz--) {
          //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
          i<<=Global.sizeof_byte;
          //todo int preserve=(i & 0xFFFFFFFE); //save sign bit
          int b=(int)bi[siz];
          if (b<0) {b=(int)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
          i = (int)(i | b); //i.e. reverse order
          //todo i=(i & preserve); //restore sign bit
          //bufferPtr++;
        }          

        /* todo remove old
        i=0;
        i=(i | bi[3]);
        i <<= Global.sizeof_byte;
        i=(i | bi[2]);
        i <<= Global.sizeof_byte;
        i=(i | bi[1]);
        i <<= Global.sizeof_byte;
        i=(i | bi[0]);
        */
        
        //bufferLen=(bufferLen+Global.sizeof_int);
        
        //Assert we have enough room
        dataCount=i;
        //System.out.println("Read 0:"+bi[0]);
        //System.out.println("Read 1:"+bi[1]);
        //System.out.println("Read 2:"+bi[2]);
        //System.out.println("Read 3:"+bi[3]);
        //System.out.println(dataCount);
      
        dataCount=(dataCount-Global.sizeof_int); //inclusive
        if (bufferLen+dataCount>marshalBufSize) {//todo can remove assertion =speed?
          //todo remove until client shares servers uLog... log('Read buffer overflow:'+intToStr(getBufferLen));
          //todo fix/workaround! /error 08S01?
          //todo we need to consume the rest, otherwise we can't re-sync!
          // - maybe send to server a re-sync request/handshake?
          //-although this overflow should never happen because server uses same size marshal buffer (?)
          return overflow; //abort to avoid infinite loop          
        }
        
        //Read the block data directly into the marshal buffer
        //System.out.println("Reading "+dataCount+" at "+bufferLen);
        
        res=input.read(buffer,bufferLen,dataCount); //todo need timeout
        if (res==-1) { //eof
          return Global.fail;
        }
        
        /*
        for (debug=bufferLen; debug<dataCount; debug++) {         
          System.out.println("read "+debug+"("+(bufferLen+debug)+"):"+buffer[bufferLen+debug]);
        }
        */
          
        bufferLen=(bufferLen+dataCount);
        
        //System.out.println("Read buffer ok:"+bufferLen);
        return Global.ok;
      }
	    catch (IOException e) {
        return Global.fail;
      }    
    //}
  }
 

  /**
   * Sends an integer to the back end
   *
   * @param i the integer to be sent
  */
  public int putSQLINTEGER(int i)
  {
    if (bufferLen+Global.sizeof_int>marshalBufSize) {
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
    }
    if (bufferLen+Global.sizeof_int>marshalBufSize) { //can never happen!
    	return Global.fail; //item too big for buffer - needs to be split - todo
    }


    for (int siz=0; siz<Global.sizeof_int; siz++) {
    	buffer[bufferLen] = (byte)(i & 0xff);
    	bufferLen++;
    	i>>=Global.sizeof_byte;
    }
    return Global.ok;
  }
  public int getSQLINTEGER() //(int i)
  {
    if (bufferPtr+Global.sizeof_int>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.fail; //todo raise exception instead, since result=read-value in java
      }
    }
    int i=0;
    //for (int siz=0; siz<Global.sizeof_short; siz++) {
    for (int siz=Global.sizeof_int-1; siz>=0; siz--) {
      //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
      i<<=Global.sizeof_byte;
      //todo int preserve=(i & 0xFFFFFFFE); //save sign bit
      int b=(int)buffer[bufferPtr+siz];
      if (b<0) {b=(int)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
      i = (int)(i | b); //i.e. reverse order
      //todo i=(i & preserve); //restore sign bit
      //bufferPtr++;
    }          
    bufferPtr=bufferPtr+Global.sizeof_int;
    
    return i; //Global.ok;   
  }

    
  public int putSQLUSMALLINT(short usi)
  {  
    if (bufferLen+Global.sizeof_short>marshalBufSize) {
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
    }
    if (bufferLen+Global.sizeof_short>marshalBufSize) { //can never happen!
    	return Global.fail; //item too big for buffer - needs to be split - todo
    }


    for (int siz=0; siz<Global.sizeof_short; siz++) {
    	buffer[bufferLen] = (byte)(usi & 0xff);
    	bufferLen++;
    	usi>>=Global.sizeof_byte;
    }
    return Global.ok;  
  }
  public short getSQLUSMALLINT() //(short usi)
  {
    if (bufferPtr+Global.sizeof_short>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.fail; //todo raise exception instead, since result=read-value in java
      }
    }
    short usi=0;
    //for (int siz=0; siz<Global.sizeof_short; siz++) {
    for (int siz=Global.sizeof_short-1; siz>=0; siz--) {
      //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
      usi<<=Global.sizeof_byte;
      //todo remove: usi = (short)(usi | (short)buffer[bufferPtr+siz]); //i.e. reverse order
      //todo short preserve=(short)(usi & 0xFFFE); //save sign bit
      short b=(short)buffer[bufferPtr+siz];
      if (b<0) {b=(short)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
      usi = (short)(usi | b); //i.e. reverse order      
      //System.out.println("current value="+usi);
      //todo usi=(short)(usi & preserve); //restore sign bit
      //bufferPtr++;
    }          
    bufferPtr=bufferPtr+Global.sizeof_short;
    
    /*
    short debug=buffer[bufferPtr-1];
    debug<<=8;
    debug=(short)(debug | (short)buffer[bufferPtr-2]);
    
    System.out.println("alternative result="+debug);
    */
      
    return usi; //Global.ok;   
  }

  public int putSQLSMALLINT(short si)
  { 
    return putSQLUSMALLINT(si);    
  }
  public short getSQLSMALLINT() //(short si)
  { 
    return getSQLUSMALLINT() ;    
  }
  
  public int putFunction(short functionId)
  {  
    return putSQLUSMALLINT(functionId);
  }
  public short getFunction() //(short functionId)
  {  
    return getSQLUSMALLINT();
  }

  public int putRETCODE(short si)
  { 
    return putSQLUSMALLINT(si);    
  }
  public short getRETCODE() //(short si)
  { 
    return getSQLSMALLINT();    
  }

  public int putSQLUINTEGER(int ui)
  {
    return putSQLINTEGER(ui);
  }
  public int getSQLUINTEGER() //int ui
  {
    return getSQLINTEGER();
  }

  public int putSQLHDBC(int ConnectionHandle)
  {
    return putSQLINTEGER(ConnectionHandle);
  }
  
  public int putSQLHSTMT(int StatementHandle)
  {
    return putSQLINTEGER(StatementHandle);
  }
  public int getSQLHSTMT() //StatementHandle:SQLHSTMT
  {
    return getSQLINTEGER();
  }
  
  public int getSQLPOINTER() //(int i)
  {
    return getSQLINTEGER();
  }


  public int putpUCHAR_SWORD(String s)
  {
    if (bufferLen+Global.sizeof_short+s.length()>marshalBufSize) {
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
    }
    if (bufferLen+Global.sizeof_short+s.length()>marshalBufSize) { //can never happen!
    	return Global.fail; //item too big for buffer - needs to be split - todo
    }


    short usi=(short)s.length();
    for (int siz=0; siz<Global.sizeof_short; siz++) {
    	buffer[bufferLen] = (byte)(usi & 0xff);
    	bufferLen++;
    	usi>>=Global.sizeof_byte;
    }
    
    //todo copy this in one block: speed
    for (int siz=0; siz<s.length(); siz++) {
    	buffer[bufferLen] = (byte)(s.getBytes()[siz]);
    	bufferLen++;
    }    
    
    return Global.ok;
  }
  public String getpUCHAR_SWORD() //(var puc:pUCHAR;allocated:SWORD;var sw:SWORD):integer;
  {   
    if (bufferPtr+Global.sizeof_short>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.failString; //todo raise exception instead, since result=read-value in java
      }
    }
    short usi=0;

    for (int siz=Global.sizeof_short-1; siz>=0; siz--) {
      //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
      usi<<=Global.sizeof_byte;
      //todo short preserve=(short)(usi & (short)0xFFFE); //save sign bit
      short b=(short)buffer[bufferPtr+siz];
      if (b<0) {b=(short)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
      usi = (short)(usi | b); //i.e. reverse order
      //todo usi=(short)(usi & preserve); //restore sign bit
      //bufferPtr++;
    }          
    bufferPtr=bufferPtr+Global.sizeof_short;

    if (bufferPtr+usi>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.failString; //todo raise exception instead, since result=read-value in java
      }
    }
    
    bufferPtr=bufferPtr+usi;
    
    //System.out.println("getpUCHAR_SWORD "+usi+" from "+bufferPtr+" starting with "+buffer[bufferPtr]/*+buffer[bufferPtr+1]+buffer[bufferPtr+2]+buffer[bufferPtr+3]+buffer[bufferPtr+4]*/);

    return new String(buffer,bufferPtr-usi,(int)usi-1/*remove null terminator for Java*/);
  }  


  public int putpSQLCHAR_SWORD(String s) //(var puc:pUCHAR;allocated:SWORD;var sw:SWORD):integer;
  {
    return putpUCHAR_SWORD(s);
  }
  public String getpSQLCHAR_SWORD() //(var puc:pUCHAR;allocated:SWORD;var sw:SWORD):integer;
  {
    return getpUCHAR_SWORD();
  }


  public int putpUCHAR_SDWORD(String s)
  {
    if (bufferLen+Global.sizeof_int+s.length()>marshalBufSize) {
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
    }
    if (bufferLen+Global.sizeof_int+s.length()>marshalBufSize) { //can never happen!
    	return Global.fail; //item too big for buffer - needs to be split - todo
    }


    int ui=(int)s.length();
    for (int siz=0; siz<Global.sizeof_int; siz++) {
    	buffer[bufferLen] = (byte)(ui & 0xff);
    	bufferLen++;
    	ui>>=Global.sizeof_byte;
    }
    
    //todo copy this in one block: speed
    for (int siz=0; siz<s.length(); siz++) {
    	buffer[bufferLen] = (byte)(s.getBytes()[siz]);
      //System.out.println("putpUCHAR_SDWORD putting"+siz+"("+(bufferLen)+"):"+buffer[bufferLen]);
    	bufferLen++;
    }    
    
    return Global.ok;
  }
  public String getpUCHAR_SDWORD() //(var puc:pUCHAR;allocated:SWORD;var sdw:SDWORD):integer;
  {   
    if (bufferPtr+Global.sizeof_int>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.failString; //todo raise exception instead, since result=read-value in java
      }
    }
    int ui=0;

    for (int siz=Global.sizeof_int-1; siz>=0; siz--) {
      //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
      ui<<=Global.sizeof_byte;
      //todo int preserve=(ui & 0xFFFFFFFE); //save sign bit     
      int b=(int)buffer[bufferPtr+siz];
      if (b<0) {b=(int)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
      ui = (int)(ui | b); //i.e. reverse order     
      //todo ui=(ui & preserve); //restore sign bit
      //bufferPtr++;
    }          
    bufferPtr=bufferPtr+Global.sizeof_int;

    if (bufferPtr+ui>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.failString; //todo raise exception instead, since result=read-value in java
      }
    }
    
    bufferPtr=bufferPtr+ui;
    
    //System.out.println("getpUCHAR_SWORD "+usi+" from "+bufferPtr+" starting with "+buffer[bufferPtr]/*+buffer[bufferPtr+1]+buffer[bufferPtr+2]+buffer[bufferPtr+3]+buffer[bufferPtr+4]*/);

    return new String(buffer,bufferPtr-ui,(int)ui-1/*remove null terminator for Java*/);
  }  



  public /*String*/ byte[] getpDataSDWORD() //var p:SQLPOINTER;allocated:SDWORD;var sdw:SDWORD):integer;
  {      
    if (bufferPtr+Global.sizeof_int>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      else { //the buffer is not quite empty - we must be asking for the wrong data type //todo splits will be handled here
        return Global.failNull; //todo raise exception instead, since result=read-value in java
      }
    }
    int ui=0;

    for (int siz=Global.sizeof_int-1; siz>=0; siz--) {
      //System.out.println("getting"+siz+"("+(bufferPtr+siz)+"):"+buffer[bufferPtr+siz]);
      ui<<=Global.sizeof_byte;
      //todo int preserve=(ui & 0xFFFFFFFE); //save sign bit
      int b=(int)buffer[bufferPtr+siz];
      if (b<0) {b=(int)(b+256);} //when we cast the byte to short, any sign bit will have been stretched to the far left & lost its value
      ui = (int)(ui | b); //i.e. reverse order      
      //todo ui=(ui & preserve); //restore sign bit
      //bufferPtr++;
    }          
    bufferPtr=bufferPtr+Global.sizeof_int;

    if (bufferPtr+ui>bufferLen) {
      if (bufferPtr==bufferLen) { //todo can remove assertion =speed?
        Read(); //todo check result! abort, else we've got the next buffer full
      }
      
      { //can only happen when reading a large object - we read in multiple segments (or else we must be asking for the wrong data type)
        byte[] res=new byte[ui];
        int nextSegment=0;
        int offset=0;
        do {
          nextSegment=bufferLen-bufferPtr; //size of next segment in remaining buffer
          //System.out.println("getpDataSDWORD "+ui+" segment from "+bufferPtr+" for "+nextSegment);
          for (int i=0; i<nextSegment; i++) {res[offset+i]=buffer[bufferPtr+i];}
          bufferPtr=bufferPtr+nextSegment;
          //todo could/should avoid final Read... i.e. if offset+nextSegment>=sdw
          Read(); //todo check result! abort, else we've got the next buffer full
  
          offset=offset+nextSegment;
        } while (offset<ui); 
        //todo assert offset=sdw
        //todo result:=+1? i.e. indicate to caller than segments have been read
        return res; //see todo below about speeding this up
      }
    }
    else { //fits in a single buffer
      bufferPtr=bufferPtr+ui;
    
      //System.out.println("getpUCHAR_SWORD "+usi+" from "+bufferPtr+" starting with "+buffer[bufferPtr]/*+buffer[bufferPtr+1]+buffer[bufferPtr+2]+buffer[bufferPtr+3]+buffer[bufferPtr+4]*/);

      //todo! return new byte[usi](buffer,bufferPtr-usi,(int)usi);
      byte[] res=new byte[ui];
      for (int i=0; i<ui; i++) {res[i]=buffer[bufferPtr-ui+i];}
      return res;
      //return new byte[usi](buffer,bufferPtr-usi,(int)usi);
    
      //    return new String(buffer,bufferPtr-ui,ui/*Note: we don't remove any null terminator for Java*/);
    }
  }  

  public int putpDataSDWORD(byte[] b) //var p:SQLPOINTER;allocated:SDWORD;var sdw:SDWORD):integer;
  {      
    if (bufferLen+Global.sizeof_int+b.length>marshalBufSize) {
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
    }

    int ui=(int)b.length;
    for (int siz=0; siz<Global.sizeof_int; siz++) {
    	buffer[bufferLen] = (byte)(ui & 0xff);
    	bufferLen++;
    	ui>>=Global.sizeof_byte;
    }

    if (bufferLen+Global.sizeof_int+b.length>marshalBufSize) { //can only happen when sending a large object - we send in multiple segments
      int nextSegment=0;
      int offset=0;
      do {
        nextSegment=marshalBufSize-bufferLen; //max. size of next segment that can fit in remaining buffer
        if (nextSegment>(ui-offset)) nextSegment=(ui-offset); //final segment
        //System.out.println("putpDataSDWORD "+ui+" segment from "+bufferLen+" for "+nextSegment);
        for (int siz=0; siz<nextSegment; siz++) {
      	  buffer[bufferLen+siz] = (b[offset+siz]);
          //System.out.println("putpUCHAR_SDWORD putting"+siz+"("+(bufferLen)+"):"+buffer[bufferLen]);
    	    bufferLen++;
        }    
        //todo could/should defer final Send to caller... i.e. if offset+nextSegment>=sdw
    	  if (Send()!=Global.ok) {
    	    return Global.fail; //buffer overflow
    	  }
        //else we've cleared room for the data
  
        offset=offset+nextSegment;
      } while (offset<ui); 
      //todo assert offset=sdw
      //todo result:=+1? i.e. indicate to caller than segments have been sent
      return Global.ok;
    }
    else { //fits in a single buffer
      //todo copy this in one block: speed
      for (int siz=0; siz<b.length; siz++) {
      	buffer[bufferLen] = (byte)(b[siz]);
        //System.out.println("putpUCHAR_SDWORD putting"+siz+"("+(bufferLen)+"):"+buffer[bufferLen]);
    	  bufferLen++;
      }    
    
      return Global.ok;
    }
  }  


  /**
   * Sends an integer to the back end in reverse order.
   *
   * This is required when the backend uses the routines in the
   * src/backend/libpq/pqcomprim.c module.
   *
   * As time goes by, this should become obsolete.
   *
   * @param val the integer to be sent
   * @param siz the length of the integer in bytes (size of structure)
   * @exception IOException if an I/O error occurs
   * /
  public void SendIntegerReverse(int val, int siz) throws IOException
  {
    byte[] buf = bytePoolDim1.allocByte(siz);
    int p=0;
    while (siz-- > 0)
      {
	buf[p++] = (byte)(val & 0xff);
	val >>= 8;
      }
    Send(buf);
  }
  */

  /**
   * Send an array of bytes to the backend
   *
   * @param buf The array of bytes to be sent
   * @exception IOException if an I/O error occurs
   *
  public void Send(byte buf[]) throws IOException
  {
    output.write(buf);
  }
  */

  /**
   * Send an exact array of bytes to the backend - if the length
   * has not been reached, send nulls until it has.
   *
   * @param buf the array of bytes to be sent
   * @param siz the number of bytes to be sent
   * @exception IOException if an I/O error occurs
   *
  public void Send(byte buf[], int siz) throws IOException
  {
    Send(buf,0,siz);
  }
  */

  /**
   * Send an exact array of bytes to the backend - if the length
   * has not been reached, send nulls until it has.
   *
   * @param buf the array of bytes to be sent
   * @param off offset in the array to start sending from
   * @param siz the number of bytes to be sent
   * @exception IOException if an I/O error occurs
   *
  public void Send(byte buf[], int off, int siz) throws IOException
  {
    int i;

    output.write(buf, off, ((buf.length-off) < siz ? (buf.length-off) : siz));
    if((buf.length-off) < siz)
      {
	for (i = buf.length-off ; i < siz ; ++i)
	  {
	    output.write(0);
	  }
      }
  }
  */

  /**
   * Sends a packet, prefixed with the packet's length
   * @param buf buffer to send
   * @exception SQLException if an I/O Error returns
   * /
  public void SendPacket(byte[] buf) throws IOException
  {
    SendInteger(buf.length+4,4);
    Send(buf);
  }
  */

  /**
   * Receives a single character from the backend
   *
   * @return the character received
   * @exception SQLException if an I/O Error returns
   *
  public int ReceiveChar() throws SQLException
  {
    int c = 0;

    try
      {
	c = input.read();
	if (c < 0) throw new SQLException();
      } catch (IOException e) {
	throw new SQLException();
      }
      return c;
  }
  */

  /**
   * Receives an integer from the backend
   *
   * @param siz length of the integer in bytes
   * @return the integer received from the backend
   * @exception SQLException if an I/O error occurs
   * /
  public int ReceiveInteger(int siz) throws SQLException
  {
    int n = 0;

    try
      {
	for (int i = 0 ; i < siz ; i++)
	  {
	    int b = input.read();

	    if (b < 0)
	      throw new SQLException();
	    n = n | (b << (8 * i)) ;
	  }
      } catch (IOException e) {
	throw new SQLException();
      }
      return n;
  }
  */

  /**
   * Receives an integer from the backend
   *
   * @param siz length of the integer in bytes
   * @return the integer received from the backend
   * @exception SQLException if an I/O error occurs
   * /
  public int ReceiveIntegerR(int siz) throws SQLException
  {
    int n = 0;

    try
      {
	for (int i = 0 ; i < siz ; i++)
	  {
	    int b = input.read();

	    if (b < 0)
	      throw new SQLException();
	    n = b | (n << 8);
	  }
      } catch (IOException e) {
	throw new SQLException();
      }
      return n;
  }
  */

  /**
   * Receives a null-terminated string from the backend.  Maximum of
   * maxsiz bytes - if we don't see a null, then we assume something
   * has gone wrong.
   *
   * @param maxsiz maximum length of string
   * @return string from back end
   * @exception SQLException if an I/O error occurs
   * /
  public String ReceiveString(int maxsiz) throws SQLException
  {
    byte[] rst = bytePoolDim1.allocByte(maxsiz);
    return ReceiveString(rst, maxsiz, null);
  }
  */

  /**
   * Receives a null-terminated string from the backend.  Maximum of
   * maxsiz bytes - if we don't see a null, then we assume something
   * has gone wrong.
   *
   * @param maxsiz maximum length of string
   * @param encoding the charset encoding to use.
   * @param maxsiz maximum length of string in bytes
   * @return string from back end
   * @exception SQLException if an I/O error occurs
   * /
  public String ReceiveString(int maxsiz, String encoding) throws SQLException
  {
    byte[] rst = bytePoolDim1.allocByte(maxsiz);
    return ReceiveString(rst, maxsiz, encoding);
  }
  */

  /**
   * Receives a null-terminated string from the backend.  Maximum of
   * maxsiz bytes - if we don't see a null, then we assume something
   * has gone wrong.
   *
   * @param rst byte array to read the String into. rst.length must
   *        equal to or greater than maxsize.
   * @param maxsiz maximum length of string in bytes
   * @param encoding the charset encoding to use.
   * @return string from back end
   * @exception SQLException if an I/O error occurs
   * /
  public String ReceiveString(byte rst[], int maxsiz, String encoding)
      throws SQLException
  {
    int s = 0;

    try
      {
	while (s < maxsiz)
	  {
	    int c = input.read();
	    if (c < 0)
	      throw new SQLException();
 	    else if (c == 0) {
 		rst[s] = 0;
 		break;
 	    } else
	      rst[s++] = (byte)c;
	  }
	if (s >= maxsiz)
	  throw new SQLException();
      } catch (IOException e) {
	throw new SQLException();
      }
      String v = null;
      if (encoding == null)
          v = new String(rst, 0, s);
      else {
          try {
              v = new String(rst, 0, s, encoding);
          } catch (UnsupportedEncodingException unse) {
              throw new SQLException();
          }
      }
      return v;
  }
  */

  /**
   * Read a tuple from the back end.  A tuple is a two dimensional
   * array of bytes
   *
   * @param nf the number of fields expected
   * @param bin true if the tuple is a binary tuple
   * @return null if the current response has no more tuples, otherwise
   *	an array of strings
   * @exception SQLException if a data I/O error occurs
   * /
  public byte[][] ReceiveTuple(int nf, boolean bin) throws SQLException
  {
    int i, bim = (nf + 7)/8;
    byte[] bitmask = Receive(bim);
    byte[][] answer = bytePoolDim2.allocByte(nf);

    int whichbit = 0x80;
    int whichbyte = 0;

    for (i = 0 ; i < nf ; ++i)
      {
	boolean isNull = ((bitmask[whichbyte] & whichbit) == 0);
	whichbit >>= 1;
	if (whichbit == 0)
	  {
	    ++whichbyte;
	    whichbit = 0x80;
	  }
	if (isNull)
	  answer[i] = null;
	else
	  {
	    int len = ReceiveIntegerR(4);
	    if (!bin)
	      len -= 4;
	    if (len < 0)
	      len = 0;
	    answer[i] = Receive(len);
	  }
      }
    return answer;
  }
  */

  /**
   * Reads in a given number of bytes from the backend
   *
   * @param siz number of bytes to read
   * @return array of bytes received
   * @exception SQLException if a data I/O error occurs
   * /
  private byte[] Receive(int siz) throws SQLException
  {
      byte[] answer = bytePoolDim1.allocByte(siz);
    Receive(answer,0,siz);
    return answer;
  }
  */

  /**
   * Reads in a given number of bytes from the backend
   *
   * @param buf buffer to store result
   * @param off offset in buffer
   * @param siz number of bytes to read
   * @exception SQLException if a data I/O error occurs
   * /
  public void Receive(byte[] b,int off,int siz) throws SQLException
  {
    int s = 0;

    try
      {
	while (s < siz)
	  {
	    int w = input.read(b, off+s, siz - s);
	    if (w < 0)
	      throw new SQLException();
	    s += w;
	  }
      } catch (IOException e) {
	  throw new SQLException();
      }
  }
  */

  /**
   * This flushes any pending output to the backend. It is used primarily
   * by the Fastpath code.
   * @exception SQLException if an I/O error occurs
   */
  public void flush() throws SQLException
  {
    try {
      output.flush();
    } catch (IOException e) {
      throw new SQLException();
    }
  }
  

  /**
   * Closes the connection
   *
   * @exception IOException if a IO Error occurs
   */
  public void close() throws IOException
  {
    //output.write("X\0".getBytes());
    output.flush();
    output.close();
    input.close();
    clientSocket.close();
  }

}


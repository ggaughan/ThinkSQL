unit uDataType;

{$DEFINE DEBUGDETAIL}
{$DEFINE DEBUGDETAIL2}
{$DEFINE DEBUGDETAIL3}

//todo: I read somewhere that trunc needed to switch the CPU state and so was
//      slower than round or a cast. Check - speed.

interface

uses uMain {to access ODBC.inc defs}, uMarshal, uDiagnostic, uDesc;

function isValidCtype(dataType:SQLSMALLINT):boolean;

function isBinaryCompatible(Todesc_type,Fromdesc_type:SQLSMALLINT):boolean;

function getAndConvert(Todesc_type:SQLSMALLINT;Fromdesc:TdescRec;
                       dataPtr:SQLPOINTER;desc_octet_length:SQLINTEGER;
                       marshal:TMarshalBuffer; var tempsdw:SDWORD;
                       diag:Tdiagnostic; row:SQLUINTEGER;rn:SQLSMALLINT):integer;

function putAndConvert(Todesc:TdescRec;Fromdesc_type:SQLSMALLINT;
                       dataPtr:SQLPOINTER;tempsdwIN{desc_octet_length}:SQLINTEGER;
                       marshal:TMarshalBuffer; var tempsdw:SDWORD;
                       diag:Tdiagnostic; row:SQLUINTEGER;rn:SQLSMALLINT):integer;

implementation

uses uGlobal, uStrings, sysUtils, Math{for power}, uMarshalGlobal;

const
  ODBC_TIME_FRACTION_SCALE=9; //i.e. fractional parts are in billionths of seconds

function isValidCtype(dataType:SQLSMALLINT):boolean;
{Check if the data type is a valid ODBC C data-type
 RETURNS:   true, else false

 Note: we have to deal with non-SQL-standard clients that do comply with
       ODBC's definitions, so we have to accept all of the possible
       C types. There are lots of them and they're scrappy, but at least
       our back-end types are safe: we just need to provide translations.
}
begin
  case dataType of
    {todo enable - we may someday have a client that supports SQL types natively!?
     - many of these are covered by the ones below, e.g. SQL_C_CHAR=SQL_CHAR etc.
    SQL_CHAR,SQL_NUMERIC,SQL_DECIMAL,SQL_INTEGER,SQL_SMALLINT,SQL_FLOAT,SQL_REAL,SQL_DOUBLE,
    SQL_UDT_LOCATOR,SQL_REF,SQL_BLOB,SQL_BLOB_LOCATOR,SQL_CLOB,SQL_CLOB_LOCATOR}
    SQL_C_CHAR, SQL_C_SSHORT, SQL_C_USHORT, SQL_C_SLONG, SQL_C_ULONG,
    SQL_C_FLOAT, SQL_C_DOUBLE, SQL_C_BIT, SQL_C_STINYINT, SQL_C_UTINYINT,
    SQL_C_SBIGINT, SQL_C_UBIGINT, SQL_C_BINARY,
    {SQL_C_BOOKMARK=SQL_C_ULONG,} {SQL_C_VARBOOKMARK=SQL_C_BINARY,}
    SQL_C_TYPE_DATE, SQL_C_TYPE_TIME, SQL_C_TYPE_TIMESTAMP,
    SQL_C_NUMERIC,
    SQL_C_GUID,
    SQL_C_INTERVAL_YEAR..SQL_C_INTERVAL_MINUTE_TO_SECOND,  {todo check we cover 'All C interval data types'}
    {todo etc?}
    SQL_C_LONG, SQL_C_SHORT, SQL_C_TINYINT, //for ODBC 2 (before they were signed/unsigned)
    SQL_LONGVARBINARY{=SQL_VARBINARY returned from Borland BDE (SQL_C_BINARY is also passed from Borland BDE)},
    SQL_LONGVARCHAR{todo debug test...remove?},

    SQL_C_DEFAULT:
    begin
      result:=True;
    end;
  else
    result:=False;
  end; {case}
end; {isValidCtype}

function isBinaryCompatible(Todesc_type,Fromdesc_type:SQLSMALLINT):boolean;
{Check if the two types (C and SQL) are binary compatible,
 i.e. can the server's data buffer be copied directly with no conversion?

 RETURNS:     true, else false
}
begin
  if
      (
        (Todesc_type=Fromdesc_type) or     //equal
        (Todesc_type=SQL_C_DEFAULT)        //default => user knows best
      )                                    //but
      and (
            (Todesc_type<>SQL_C_NUMERIC) and  //SQL_C_NUMERIC needs extra work //todo check true!
            (Todesc_type<>SQL_C_CHAR) and     //SQL_C_CHAR needs \0 termination //todo get server to add instead!?-speed
                                              //todo SQL_C_WCHAR also...
            (Todesc_type<>SQL_C_TYPE_DATE) and
            (Todesc_type<>SQL_C_TYPE_TIME) and
            (Todesc_type<>SQL_C_TYPE_TIMESTAMP)
                                              //todo + SQL_interval types
          )

  then
    result:=True
  else
    result:=False;
end; {isBinaryCompatible}

function dateToODBCDate(d:TsqlDate):SQL_DATE_STRUCT;
begin
  result.year:=d.year;
  result.month:=d.month;
  result.day:=d.day;
end;
function strToODBCdate(s:string):SQL_DATE_STRUCT;
var
  d:TsqlDate;
begin
  d:=strToSQLDate(s);
  result:=dateToODBCDate(d);
end;

{For params->server}
function ODBCDateToDate(cd:SQL_DATE_STRUCT):TsqlDate;
begin
  result.year:=cd.year;
  result.month:=cd.month;
  result.day:=cd.day;
end;
function ODBCdateToStr(cd:SQL_DATE_STRUCT):string;
var
  d:TsqlDate;
begin
  d:=ODBCDateToDate(cd);
  result:=sqlDateToStr(d);
end;

function timeToODBCTime(t:TsqlTime):SQL_TIME_STRUCT;
begin
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  result.hour:=t.hour;
  result.minute:=t.minute;
  {Denormalise seconds}
  result.second:=trunc(t.second/power(10,TIME_MAX_SCALE)); //i.e. shift TIME_MAX_SCALE decimal places to the right
  //todo what about t.scale?
end;
function strToODBCtime(s:string):SQL_TIME_STRUCT;
var
  t:TsqlTime;
  dayCarry:shortint;
begin
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  t:=strToSQLTime(TIMEZONE_ZERO,s,dayCarry);
  result:=timeToODBCtime(t);
end;

{For params->server}
function ODBCTimeToTime(ct:SQL_TIME_STRUCT):TsqlTime;
begin
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  result.hour:=ct.hour;
  result.minute:=ct.minute;
  result.scale:=0;
  {Normalise to ease later comparison and hashing}
  result.second:=round(ct.second*power(10,TIME_MAX_SCALE)); //i.e. shift TIME_MAX_SCALE decimal places to the left //todo replace trunc with round everywhere, else errors e.g. trunc(double:1312) -> 1311! //what about int()?
end;
function ODBCtimeToStr(ct:SQL_TIME_STRUCT):string;
var
  t:TsqlTime;
  dayCarry:shortint;
begin
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  t:=ODBCTimeToTime(ct);
  result:=sqlTimeToStr(TIMEZONE_ZERO,t,t.scale,dayCarry);
end;

function timestampToODBCTimestamp(ts:TsqlTimestamp):SQL_TIMESTAMP_STRUCT;
var
  sec:double;
begin
  {$IFDEF DEBUGDETAIL2}
  log(format('timestampToODBCTimestamp called %d %d %d %d',[ts.time.hour,ts.time.minute,ts.time.second,ts.time.scale]));
  {$ENDIF}
  result.year:=ts.date.year;
  result.month:=ts.date.month;
  result.day:=ts.date.day;
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  result.hour:=ts.time.hour;
  result.minute:=ts.time.minute;
  {Denormalise seconds}
  sec:=ts.time.second/power(10,TIME_MAX_SCALE); //i.e. shift TIME_MAX_SCALE decimal places to the right
  {$IFDEF DEBUGDETAIL2}
  log(format('timestampToODBCTimestamp calculating %f',[sec]));
  {$ENDIF}
  result.second:=trunc(int(sec));
  {Normalise for ODBC}
  result.fraction:=round(frac(sec)*power(10,ODBC_TIME_FRACTION_SCALE));
  {$IFDEF DEBUGDETAIL2}
  log(format('timestampToODBCTimestamp returning %d %d %d %d',[result.hour,result.minute,result.second,result.fraction]));
  {$ENDIF}
end;
function strToODBCtimestamp(s:string):SQL_TIMESTAMP_STRUCT;
var
  ts:TsqlTimestamp;
begin
  ts:=strToSQLTimestamp(TIMEZONE_ZERO,s);
  result:=timestampToODBCtimestamp(ts);
end;

{For params->server}
function ODBCTimestampToTimestamp(cts:SQL_TIMESTAMP_STRUCT):TsqlTimestamp;
var
  sec:double;
begin
  {$IFDEF DEBUGDETAIL2}
  log(format('ODBCTimestampToTimestamp called %d %d %d %d',[cts.hour,cts.minute,cts.second,cts.fraction]));
  {$ENDIF}
  result.date.year:=cts.year;
  result.date.month:=cts.month;
  result.date.day:=cts.day;
  //todo in future, map 'time with time zone' to time & auto-adjust to 'local' time at server-side(?)
  result.time.hour:=cts.hour;
  result.time.minute:=cts.minute;
  {Denormalise ODBC fractions of seconds}
  sec:=cts.fraction/power(10,ODBC_TIME_FRACTION_SCALE); //i.e. shift ODBC_TIME_FRACTION_SCALE decimal places to the right
  {Set the scale}
  if cts.fraction=0 then
    result.time.scale:=0
  else
    result.time.scale:=length(floatToStr(frac(sec)))-2{i.e. '0.'};  //ok? any need?
  sec:=cts.second+sec;
  {Normalise to ease later comparison and hashing}
  result.time.second:=round(sec*power(10,TIME_MAX_SCALE)); //i.e. shift TIME_MAX_SCALE decimal places to the left //todo replace trunc with round everywhere, else errors e.g. trunc(double:1312) -> 1311! //what about int()?
  {$IFDEF DEBUGDETAIL2}
  log(format('ODBCTimestampToTimestamp returning %d %d %d %d',[result.time.hour,result.time.minute,result.time.second,result.time.scale]));
  {$ENDIF}
end;
function ODBCtimestampToStr(cts:SQL_TIMESTAMP_STRUCT):string;
var
  ts:TsqlTimestamp;
begin
  ts:=ODBCTimestampToTimestamp(cts);
  result:=sqlTimestampToStr(TIMEZONE_ZERO,ts,ts.time.scale);
end;


function getAndConvert(Todesc_type:SQLSMALLINT;Fromdesc:TdescRec;
                       dataPtr:SQLPOINTER;desc_octet_length:SQLINTEGER;
                       marshal:TMarshalBuffer; var tempsdw:SDWORD;
                       diag:Tdiagnostic; row:SQLUINTEGER;rn:SQLSMALLINT):integer;
//todo check which routines we can put 'const' in the parameter list - speed
{Convert data in marshal buffer from server into client's data type in deferred memory buffer

 This is one of the two type-conversion matrices.
 The matrix is structured as a nested Case, e.g.
    A B C      case A
   A             case A,B,C,else not-supported
   B       =>  case B
   C             case A,B,C,else not-supported
               case C
                 case A,B,C,else not-supported
               else unknown type
 Sections of the code are repeated. Needs review to make leaner. todo

 IN:
           Todesc_type        the C data type=target type
           Fromdesc           the SQL column desc (includes: data type=source type)
           dataPtr            the target
           desc_octet_length  the target buffer size
           marshal            the marshal buffer handler
           tempsdw            the data length available in marshal buffer - must read/skip all
           diag               the stmt diagnostic for reporting errors/warnings
           row                the row set number - used for diagnostic postings
           rn                 the record number (column ref) - used for diagnostic postings

 OUT:
           tempsdw            the data length to pass back to the client

 RETURNS:  ok                            -data converted without any problem
           SQL_ROW_ERROR (5)             -an error was logged and the data has not been converted
           SQL_ROW_SUCCESS_WITH_INFO (6) -a warning was logged and the data has been converted (e.g. but truncated)

 Assumes:
   marshal buffer has just returned tempsdw and the data is the next to be read
   desc_octet_length has been allocated enough room for the simple types

 Note:
   if To and From desc_types are binary compatible, calling this routine will add extra overhead (not too much?)
   - it would be quicker for the caller to copy data from the marshal buffer directly

   if tempsdw is passed in as 0, no further data is read from the marshal buffer
    - maybe null - up to caller to determine
}
var
  tempBuf:pUCHAR;
  tempSmallInt:SQLSMALLINT;
  tempInt:SQLINTEGER;
  tempExtended:Extended;
  tempSingle:single;
  tempDouble:SQLDOUBLE;
  tempStr:string;

  i:shortint;
  tempNumeric:SQL_NUMERIC_STRUCT;
  tempComp:comp;
  tempSdate:TsqlDate;
  tempDate:SQL_DATE_STRUCT;
  tempStime:TsqlTime;
  tempTime:SQL_TIME_STRUCT;
  tempStimestamp:TsqlTimestamp;
  tempTimestamp:SQL_TIMESTAMP_STRUCT;
  dayCarry:shortint;

  function convertSQLIntToCInt:integer;
  {Sub-routine to convert a SQL int in tempInt to a C integer in caller's
   dataPtr buffer

   Uses caller variables:
     IN:
        Todesc_type
        row
        rn
     OUT:
        tempInt
        tempsdw
        dataPtr^

   RETURNS:    result for caller to return = ok or SQL_ROW_ERROR
               (Note: if <>ok, caller should propagate the exit)

   Assumes:
     a CASE was used to guard the call to this routine, so we can assume
     here that all cases are handled & there's no need for case..else.

   Side-effects:
     will log errors to diag if necessary
  }
  begin
    result:=ok; //sub-default

    case Todesc_type of
      SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT:
      begin
        if Todesc_type<>SQL_C_UTINYINT then
        begin
          if (TempInt<-128) or (TempInt>127) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          shortint(dataPtr^):=shortint(TempInt);
          tempsdw:=sizeof(shortint);
        end
        else
        begin
          if (TempInt<0) or (TempInt>255) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          byte(dataPtr^):=byte(TempInt);
          tempsdw:=sizeof(byte);
        end;
      end;
      SQL_C_SBIGINT,SQL_C_UBIGINT:
      begin
      end;
      SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT:
      begin
        if Todesc_type<>SQL_C_USHORT then
        begin
          if (TempInt<-32768) or (TempInt>32767) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          move(smallint(TempInt),dataPtr^,sizeof(smallint));
          tempsdw:=sizeof(smallint);
        end
        else
        begin
          if (TempInt<0) or (TempInt>65535) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          move(word(TempInt),dataPtr^,sizeof(word));
          tempsdw:=sizeof(word);
        end;
      end;
      SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
      begin
        if Todesc_type<>SQL_C_ULONG then
        begin
          if (TempInt<-2147483647{todo should end in 8 - compiler errored!}) or (TempInt>2147483647) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          move(longint(TempInt),dataPtr^,sizeof(longint));
          tempsdw:=sizeof(longint);
        end
        else
        begin
          if (TempInt<0) or (TempInt>2147483647{todo should/could be larger!?}) then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss22003,fail,'',row,rn); //todo check result
            exit;
          end;
          move(cardinal(TempInt),dataPtr^,sizeof(cardinal));
          tempsdw:=sizeof(cardinal);
        end;
      end;
    else
      //todo assertion!
    end; {case}
  end; {convertSQLIntToCInt}

begin
  result:=ok; //default
  tempBuf:=nil;
  {$IFDEF DEBUGDETAIL}
  log(format('getAndConvert called %d %d %p %d %d',[Todesc_type,Fromdesc.desc_concise_type,DataPtr,desc_octet_length,tempsdw]));
  {$ENDIF}

  //todo if Todesc_type=SQL_ARD_TYPE then set Todesc_type=Fromdesc.desc_concise_type

  try
    case Fromdesc.desc_concise_type of
      SQL_CHAR, SQL_VARCHAR: //SQL_LONGVARCHAR, SQL_WCHAR, SQL_WVARCHAR, SQL_WLONGVARCHAR
      begin
        case Todesc_type of
          SQL_C_CHAR, SQL_C_DEFAULT:
          begin
            if marshal.getpUCHAR(pUCHAR(dataPtr),desc_octet_length,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of characters = number of octects
          end; {SQL_C_CHAR, SQL_C_DEFAULT}
          (* not in ODBC.h? todo for ODBC 3  - add to all conversions
          SQL_C_WCHAR:
          begin
            if marshal.getpUCHAR(dataPtr,desc_octet_length,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError('08S01',fail,text08S01,row,rn); //todo check result
              exit;
            end;
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError('01004',fail,text01004,row,rn); //todo check result
            end;
            tempsdw:=tempsdw div 2; //return number of characters, not octects
          end; {SQL_C_WCHAR}
          *)
          SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT,
          SQL_C_SBIGINT,SQL_C_UBIGINT,
          SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT,
          SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            //todo if any decimal fraction is present, remove it & log 01S07 & continue
            try
              if tempBuf[0]=nullterm then tempInt:=0 else //TODO ******** DEBUG ONLY! remove
              tempInt:=StrToInt(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}

            result:=convertSQLIntToCInt;
            if result<>ok then exit; //we need to propagate the exit

            (*todo remove- now use a shared subroutine
            case Todesc_type of
              SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT:
              begin
                if Todesc_type<>SQL_C_UTINYINT then
                begin
                  if (TempInt<-128) or (TempInt>127) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  shortint(dataPtr^):=shortint(TempInt);
                  tempsdw:=sizeof(shortint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>255) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  byte(dataPtr^):=byte(TempInt);
                  tempsdw:=sizeof(byte);
                end;
              end;
              SQL_C_SBIGINT,SQL_C_UBIGINT:
              begin
              end;
              SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT:
              begin
                if Todesc_type<>SQL_C_USHORT then
                begin
                  if (TempInt<-32768) or (TempInt>32767) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(smallint(TempInt),dataPtr^,sizeof(smallint));
                  tempsdw:=sizeof(smallint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>65535) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(word(TempInt),dataPtr^,sizeof(word));
                  tempsdw:=sizeof(word);
                end;
              end;
              SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
              begin
                if Todesc_type<>SQL_C_ULONG then
                begin
                  if (TempInt<-2147483647{todo should end in 8 - compiler errored!}) or (TempInt>2147483647) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(longint(TempInt),dataPtr^,sizeof(longint));
                  tempsdw:=sizeof(longint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>2147483647{todo should/could be larger!?}) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(cardinal(TempInt),dataPtr^,sizeof(cardinal));
                  tempsdw:=sizeof(cardinal);
                end;
              end;
            else
              //todo assertion!
            end; {case}
            *)
          end; {numeric}
          SQL_C_FLOAT,
          SQL_C_DOUBLE,
          SQL_C_NUMERIC:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempExtended:=StrToFloat(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            case Todesc_type of
              SQL_C_FLOAT:
              begin
                //todo need a better way than length of string! - could be '000000003'!!! change for all these checks!
                if length(trim(tempBuf))>7 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempSingle:=TempExtended;
                move(tempSingle,dataPtr^,sizeof(single));
                tempsdw:=sizeof(single);
              end;
              SQL_C_DOUBLE:
              begin
                if length(trim(tempBuf))>15 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempDouble:=TempExtended;
                move(TempDouble,dataPtr^,sizeof(double));
                tempsdw:=sizeof(double);
              end;
              SQL_C_NUMERIC:
              begin
                if length(trim(tempBuf))>SQL_MAX_NUMERIC_LEN then //todo bad test
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
(* todo hard way - Comp type already stores as little-endian, so just send that! //todo remove but keep in case
                {Convert to a scaled integer}
                i:=pos('.',trim(tempBuf));
                if i<>0 then
                begin
                  i:=length(trim(tempBuf))-i;
                  tempExtended:=tempExtended*power(10,i); //i.e. shift i decimal places to the left
                  //todo can the above fail? - try?
                  //if so, reduce scale & warn loss of fraction part
                end;
                tempNumeric.scale:=i;  //=SQLSCHAR=shortint

                try
                  tempInt:=trunc(tempExtended); //should lose nothing! todo check/catch any loss
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError('22003',fail,text22003,row,rn); //todo check result
                    exit;
                  end;
                end; {try}
                {Now convert to hex/little endian}
                //todo put into separate routine... & speed it up! - use assembler...
                if tempInt<0 then tempNumeric.sign:=#0 else tempNumeric.sign:=#1;
                tempInt:=abs(tempInt); //remove the sign

                tempStr:=format('%*.*x',[SQL_MAX_NUMERIC_LEN*2,SQL_MAX_NUMERIC_LEN*2,tempInt]); //convert to hex
                for i:=1 to SQL_MAX_NUMERIC_LEN*2 do if tempStr[i]=' ' then tempStr[i]:='0'; //pad with 0's (format documentation lied!)
                for i:=SQL_MAX_NUMERIC_LEN downto 1 do //convert pairs of hex digits into little endian bytes
                begin
                  tempByte:=strToInt('$'+tempStr[(i*2)-1]+tempStr[i*2]); //reverse hex digits in each pair
                  tempNumeric.val[SQL_MAX_NUMERIC_LEN-i]:=char(tempByte);
                end;
                tempNumeric.precision:=SQLCHAR(SQL_MAX_NUMERIC_LEN); //todo get our real max from shared global
                move(tempNumeric,pSQL_NUMERIC_STRUCT(dataPtr)^,sizeof(tempNumeric));
                tempsdw:=sizeof(tempNumeric);
*)
                {Convert to a scaled integer}
                i:=pos('.',trim(tempBuf));
                if i<>0 then
                begin
                  i:=length(trim(tempBuf))-i;
                  //todo better to remove '.' and strToInt() buffer again (cut out intermediate type = no need for power or trunc)
                  try
                    tempExtended:=tempExtended*power(10,i); //i.e. shift i decimal places to the left
                  except
                    on E:Exception do
                    begin
                      //todo: reduce scale & warn loss of fraction part & continue?
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22003,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
                tempNumeric.scale:=i;  //=SQLSCHAR=shortint

                try
                  tempComp:=trunc(tempExtended); //should lose nothing! todo check/catch any loss
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
                {Return as hex/little endian}
                if tempComp<0 then tempNumeric.sign:=#0 else tempNumeric.sign:=#1;
                tempComp:=abs(tempComp); //remove the sign
                move(tempComp,tempNumeric.val,sizeof(tempComp));
                tempNumeric.precision:=SQLCHAR(SQL_MAX_NUMERIC_LEN); //todo get our real max from shared global
                move(tempNumeric,pSQL_NUMERIC_STRUCT(dataPtr)^,sizeof(tempNumeric));
                tempsdw:=sizeof(tempNumeric);
              end; {SQL_C_NUMERIC}
            else
              //todo assertion!
            end; {case}
          end; {float,double,numeric}
          SQL_C_BIT:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempSingle:=StrToFloat(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            if (tempSingle=0) or (tempSingle=1) then
            begin
              byte(dataPtr^):=byte(trunc(tempSingle));
              tempsdw:=sizeof(byte);
            end
            else
            begin
              if (tempSingle>0) or (tempSingle<2) then
              begin
                result:=SQL_ROW_SUCCESS_WITH_INFO;
                diag.logError(ss01S07,fail,'',row,rn); //todo check result
                byte(dataPtr^):=byte(trunc(tempSingle));
                tempsdw:=sizeof(byte);
              end
              else
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end;
          end; {SQL_C_BIT}
          SQL_C_BINARY:
          begin
            if marshal.getpData(dataPtr,desc_octet_length,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
              tempsdw:=desc_octet_length; //return number of characters = number of octects
            end;
            tempsdw:=tempsdw; //return number of bytes = number of octects
          end; {SQL_C_BINARY}
          SQL_C_TYPE_DATE:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempDate:=StrToODBCDate(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempDate,dataPtr^,sizeof(tempDate));
            tempsdw:=sizeof(tempDate);
          end; {SQL_C_TYPE_DATE}
          SQL_C_TYPE_TIME:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempTime:=StrToODBCTime(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempTime,dataPtr^,sizeof(tempTime));
            tempsdw:=sizeof(tempTime);
          end; {SQL_C_TYPE_TIME}
          SQL_C_TYPE_TIMESTAMP:
          begin
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempTimestamp:=StrToODBCTimestamp(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempTimestamp,dataPtr^,sizeof(tempTimestamp));
            tempsdw:=sizeof(tempTimestamp);
          end; {SQL_C_TYPE_TIMESTAMP}
          SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
          SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
          SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {interval}
        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {character}


      SQL_DECIMAL, SQL_NUMERIC: //SQL_BIGINT, SQL_REAL, SQL_TINYINT, SQL_DOUBLE
      begin
        //todo based on approx. numeric code below - keep in sync!
        if tempsdw=0 then
        begin
          //nothing to read from server (null?) - leave for caller
          exit;
        end;
        //read numeric into 8 bytes
        //todo: need precision/scale info to be useful!
        if tempsdw<>sizeof(tempComp) then //todo make into proper assertion: to continue=out of synch!
          log(format('getAndConvert assertion failed: %d server-type-size (%d) <> server-sent-size (%d)',[Fromdesc.desc_concise_type,sizeof(tempComp),tempsdw]));
        if marshal.getComp(tempComp)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

        {Adjust the scale}
        tempDouble:=tempComp/power(10,fromDesc.desc_scale); //i.e. shift scale decimal places to the right

        case Todesc_type of
          SQL_C_CHAR:
          begin
            tempStr:=floatToStr(tempDouble);
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
          SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT,
          SQL_C_SBIGINT,SQL_C_UBIGINT,
          SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT,
          SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
          begin
            tempInt:=trunc(tempDouble);
            result:=convertSQLIntToCInt;
            if result<>ok then exit; //we need to propagate the exit
          end; {numeric}
          SQL_C_FLOAT,
          SQL_C_DOUBLE,
          SQL_C_NUMERIC,
          SQL_C_DEFAULT:
          begin
            case Todesc_type of
              SQL_C_FLOAT:
              begin
                if length(floatToStr(tempDouble))>7 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempSingle:=tempDouble;
                move(tempSingle,dataPtr^,sizeof(single));
                tempsdw:=sizeof(single);
              end;
              SQL_C_DOUBLE, SQL_C_DEFAULT:
              begin
                if length(floatToStr(tempDouble))>15 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                move(tempDouble,dataPtr^,sizeof(double));
                tempsdw:=sizeof(double);
              end;
            else
              //todo assertion!
            end; {case}
          end; {float,double,numeric}
          SQL_C_BIT:
          begin
            if (tempDouble=0) or (tempDouble=1) then
            begin
              byte(dataPtr^):=byte(trunc(tempDouble));
              tempsdw:=sizeof(byte);
            end
            else
            begin
              if (tempDouble>0) or (tempDouble<2) then
              begin
                result:=SQL_ROW_SUCCESS_WITH_INFO;
                diag.logError(ss01S07,fail,'',row,rn); //todo check result
                byte(dataPtr^):=byte(trunc(tempDouble));
                tempsdw:=sizeof(byte);
              end
              else
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end;
          end; {SQL_C_BIT}
          SQL_C_BINARY:
          begin
            move(tempDouble,dataPtr^,sizeof(tempDouble));
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss22003,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of bytes = number of octects
          end; {SQL_C_BINARY}
          SQL_C_TYPE_DATE:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_DATE}
          SQL_C_TYPE_TIME:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIME}
          SQL_C_TYPE_TIMESTAMP:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIMESTAMP}
          SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
          SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
          SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {interval}

        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {precise numeric}
      SQL_FLOAT:
      begin
        if tempsdw=0 then
        begin
          //nothing to read from server (null?) - leave for caller
          exit;
        end;
         //read numeric into 4 bytes
        if tempsdw<>sizeof(tempDouble) then //todo make into proper assertion: to continue=out of synch!
          log(format('getAndConvert assertion failed: %d server-type-size (%d) <> server-sent-size (%d)',[Fromdesc.desc_concise_type,sizeof(tempDouble),tempsdw]));
        if marshal.getSQLDOUBLE(tempDouble)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

        case Todesc_type of
          SQL_C_CHAR:
          begin
            tempStr:=floatToStr(tempDouble);
            if pos('.',tempStr)>desc_octet_length then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss22003,fail,'',row,rn); //todo check result
              exit;
            end;
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
          SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT,
          SQL_C_SBIGINT,SQL_C_UBIGINT,
          SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT,
          SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
          begin
            //if any decimal fraction is present, remove it & log 01S07 & continue
            tempInt:=trunc(tempDouble);
            if tempDouble-tempInt>0.000001 then  //todo tolerance from where!!!!*****
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01S07,fail,'',row,rn); //todo check result
            end;

            result:=convertSQLIntToCInt;
            if result<>ok then exit; //we need to propagate the exit

            (*todo remove- now use a shared subroutine
            //copied from above - todo maybe use a routine: convertSQLIntToCInt
            case Todesc_type of
              SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT:
              begin
                if Todesc_type<>SQL_C_UTINYINT then
                begin
                  if (TempInt<-128) or (TempInt>127) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  shortint(dataPtr^):=shortint(TempInt);
                  tempsdw:=sizeof(shortint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>255) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  byte(dataPtr^):=byte(TempInt);
                  tempsdw:=sizeof(byte);
                end;
              end;
              SQL_C_SBIGINT,SQL_C_UBIGINT:
              begin
              end;
              SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT:
              begin
                if Todesc_type<>SQL_C_USHORT then
                begin
                  if (TempInt<-32768) or (TempInt>32767) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(smallint(TempInt),dataPtr^,sizeof(smallint));
                  tempsdw:=sizeof(smallint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>65535) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(word(TempInt),dataPtr^,sizeof(word));
                  tempsdw:=sizeof(word);
                end;
              end;
              SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
              begin
                if Todesc_type<>SQL_C_ULONG then
                begin
                  if (TempInt<-2147483647{todo should end in 8 - compiler errored!}) or (TempInt>2147483647) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(longint(TempInt),dataPtr^,sizeof(longint));
                  tempsdw:=sizeof(longint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>2147483647{todo should/could be larger!?}) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(cardinal(TempInt),dataPtr^,sizeof(cardinal));
                  tempsdw:=sizeof(cardinal);
                end;
              end;
            else
              //todo assertion!
            end; {case}
            *)
          end; {numeric}
          SQL_C_FLOAT,
          SQL_C_DOUBLE,
          SQL_C_NUMERIC,
          SQL_C_DEFAULT:
          begin
            case Todesc_type of
              SQL_C_FLOAT:
              begin
                if length(floatToStr(tempDouble))>7 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempSingle:=TempDouble;
                move(tempSingle,dataPtr^,sizeof(single));
                tempsdw:=sizeof(single);
              end;
              SQL_C_DOUBLE, SQL_C_DEFAULT:
              begin
                if length(floatToStr(tempDouble))>15 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                move(TempDouble,dataPtr^,sizeof(double));
                tempsdw:=sizeof(double);
              end;
              SQL_C_NUMERIC:
              begin
                {Convert to a canonical string}
                tempBuf:=pchar(floatToStr(tempDouble));

                if length(trim(tempBuf))>SQL_MAX_NUMERIC_LEN then //todo bad test
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                {Convert to a scaled integer}
                i:=pos('.',trim(tempBuf));
                if i<>0 then
                begin
                  i:=length(trim(tempBuf))-i;
                  //todo better to remove '.' and strToInt() buffer again? (cut out intermediate type? - no need for power or trunc)
                  try
                    tempDouble:=tempDouble*power(10,i); //i.e. shift i decimal places to the left
                  except
                    on E:Exception do
                    begin
                      //todo: reduce scale & warn loss of fraction part & continue?
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22003,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
                tempNumeric.scale:=i;  //=SQLSCHAR=shortint

                try
                  tempComp:=trunc(tempDouble); //should lose nothing! todo check/catch any loss
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
                {Return as hex/little endian}
                if tempComp<0 then tempNumeric.sign:=#0 else tempNumeric.sign:=#1;
                tempComp:=abs(tempComp); //remove the sign
                move(tempComp,tempNumeric.val,sizeof(tempComp));
                tempNumeric.precision:=SQLCHAR(SQL_MAX_NUMERIC_LEN); //todo get our real max from shared global
                move(tempNumeric,pSQL_NUMERIC_STRUCT(dataPtr)^,sizeof(tempNumeric));
                tempsdw:=sizeof(tempNumeric);
              end; {SQL_C_NUMERIC}
            else
              //todo assertion!
            end; {case}
          end; {float,double,numeric}
          SQL_C_BIT:
          begin
            if (tempDouble=0) or (tempDouble=1) then
            begin
              byte(dataPtr^):=byte(trunc(tempDouble));
              tempsdw:=sizeof(byte);
            end
            else
            begin
              if (tempDouble>0) or (tempDouble<2) then
              begin
                result:=SQL_ROW_SUCCESS_WITH_INFO;
                diag.logError(ss01S07,fail,'',row,rn); //todo check result
                byte(dataPtr^):=byte(trunc(tempDouble));
                tempsdw:=sizeof(byte);
              end
              else
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end;
          end; {SQL_C_BIT}
          SQL_C_BINARY:
          begin
            move(TempDouble,dataPtr^,sizeof(TempDouble));
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss22003,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of bytes = number of octects
          end; {SQL_C_BINARY}
          SQL_C_TYPE_DATE:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_DATE}
          SQL_C_TYPE_TIME:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIME}
          SQL_C_TYPE_TIMESTAMP:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIMESTAMP}
          SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
          SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
          SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {interval}

        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {SQL_FLOAT}
      SQL_INTEGER, SQL_SMALLINT:
      begin
        if tempsdw=0 then
        begin
          //nothing to read from server (null?) - leave for caller
          exit;
        end;
        if Fromdesc.desc_concise_type=SQL_SMALLINT then
        begin
          (* todo Once the server stores & returns SMALINTs as 2 bytes (not as integers as at 22/09/99!)
          //read numeric into 2 bytes
          if tempsdw<>sizeof(tempSmallint) then //todo make into proper assertion: to continue=out of synch!
            log(format('getAndConvert assertion failed: %d server-type-size (%d) <> server-sent-size (%d)',[Fromdesc_type,sizeof(tempSmallint),tempsdw]));
          if marshal.getSQLSMALLINT(tempSmallInt)<>ok then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss08S01,fail,'',row,rn); //todo check result
            exit;
          end;
          tempInt:=tempSmallInt;
          *)
          //todo temporary fix...- should read 2 bytes SMALLINT but server storage is wrong...
          if tempsdw<>sizeof(tempint) then //todo make into proper assertion: to continue=out of synch!
            log(format('getAndConvert assertion failed: %d server-type-size (%d) <> server-sent-size (%d)',[Fromdesc.desc_concise_type,sizeof(tempint),tempsdw]));
          if marshal.getSQLINTEGER(tempInt)<>ok then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss08S01,fail,'',row,rn); //todo check result
            exit;
          end;
        end
        else
        begin
          //read numeric into 4 bytes
          if tempsdw<>sizeof(tempInt) then //todo make into proper assertion: to continue=out of synch!
            log(format('getAndConvert assertion failed: %d server-type-size (%d) <> server-sent-size (%d)',[Fromdesc.desc_concise_type,sizeof(tempInt),tempsdw]));
          if marshal.getSQLINTEGER(tempInt)<>ok then
          begin
            result:=SQL_ROW_ERROR;
            diag.logError(ss08S01,fail,'',row,rn); //todo check result
            exit;
          end;
        end;

        case Todesc_type of
          SQL_C_CHAR:
          begin
            tempStr:=intToStr(tempInt);
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
          SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT,
          SQL_C_SBIGINT,SQL_C_UBIGINT,
          SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT,
          SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
          //todo moved after now that we call a subroutine: SQL_C_DEFAULT:
          begin
            result:=convertSQLIntToCInt;
            if result<>ok then exit; //we need to propagate the exit

            (*todo remove- now use a shared subroutine
            //copied from above - todo maybe use a routine: convertSQLIntToCInt
            case Todesc_type of
              SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT:
              begin
                if Todesc_type<>SQL_C_UTINYINT then
                begin
                  if (TempInt<-128) or (TempInt>127) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  shortint(dataPtr^):=shortint(TempInt);
                  tempsdw:=sizeof(shortint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>255) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  byte(dataPtr^):=byte(TempInt);
                  tempsdw:=sizeof(byte);
                end;
              end;
              SQL_C_SBIGINT,SQL_C_UBIGINT:
              begin
              end;
              SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT:
              begin
                if Todesc_type<>SQL_C_USHORT then
                begin
                  if (TempInt<-32768) or (TempInt>32767) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(smallint(TempInt),dataPtr^,sizeof(smallint));
                  tempsdw:=sizeof(smallint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>65535) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(word(TempInt),dataPtr^,sizeof(word));
                  tempsdw:=sizeof(word);
                end;
              end;
              SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG,
              SQL_C_DEFAULT:
              begin
                if Todesc_type<>SQL_C_ULONG then
                begin
                  if (TempInt<-2147483647{todo should end in 8 - compiler errored!}) or (TempInt>2147483647) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(longint(TempInt),dataPtr^,sizeof(longint));
                  tempsdw:=sizeof(longint);
                end
                else
                begin
                  if (TempInt<0) or (TempInt>2147483647{todo should/could be larger!?}) then
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                  move(cardinal(TempInt),dataPtr^,sizeof(cardinal));
                  tempsdw:=sizeof(cardinal);
                end;
              end;
            else
              //todo assertion!
            end; {case}
            *)
          end; {numeric}
          SQL_C_DEFAULT:
          begin
            //todo: copied from SQL_C_SLONG logic in convertSQLIntToCInt routine - keep in sync!
            if (TempInt<-2147483647{todo should end in 8 - compiler errored!}) or (TempInt>2147483647) then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss22003,fail,'',row,rn); //todo check result
              exit;
            end;
            move(longint(TempInt),dataPtr^,sizeof(longint));
            tempsdw:=sizeof(longint);
          end; {numeric default}

          SQL_C_FLOAT,
          SQL_C_DOUBLE,
          SQL_C_NUMERIC:
          begin
            case Todesc_type of
              SQL_C_FLOAT:
              begin
                if length(intToStr(tempInt))>7 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempSingle:=tempInt;
                move(tempSingle,dataPtr^,sizeof(single));
                tempsdw:=sizeof(single);
              end;
              SQL_C_DOUBLE:
              begin
                if length(intToStr(tempInt))>15 then {including any decimal point}
                begin
                  result:=SQL_ROW_ERROR;
                  diag.logError(ss22003,fail,'',row,rn); //todo check result
                  exit;
                end;
                TempDouble:=tempInt;
                move(TempDouble,dataPtr^,sizeof(double));
                tempsdw:=sizeof(double);
              end;
              SQL_C_NUMERIC:
              begin
                {Already a (scaled) integer}
                tempNumeric.scale:=0;  //=SQLSCHAR=shortint
                tempComp:=tempInt;

                {Return as hex/little endian}
                if tempComp<0 then tempNumeric.sign:=#0 else tempNumeric.sign:=#1;
                tempComp:=abs(tempComp); //remove the sign
                move(tempComp,tempNumeric.val,sizeof(tempComp));
                tempNumeric.precision:=SQLCHAR(SQL_MAX_NUMERIC_LEN); //todo get our real max from shared global
                move(tempNumeric,pSQL_NUMERIC_STRUCT(dataPtr)^,sizeof(tempNumeric));
                tempsdw:=sizeof(tempNumeric);
              end; {SQL_C_NUMERIC}
            else
              //todo assertion!
            end; {case}
          end; {float,double,numeric}
          SQL_C_BIT:
          begin
            if (tempInt=0) or (tempInt=1) then
            begin
              byte(dataPtr^):=byte(tempInt);
              tempsdw:=sizeof(byte);
            end
            else
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss22018,fail,'',row,rn); //todo check result
              exit;
            end;
          end; {SQL_C_BIT}
          SQL_C_BINARY:
          begin
            move(TempInt,dataPtr^,sizeof(TempInt));
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss22003,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of bytes = number of octects
          end; {SQL_C_BINARY}
          SQL_C_TYPE_DATE:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_DATE}
          SQL_C_TYPE_TIME:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIME}
          SQL_C_TYPE_TIMESTAMP:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {SQL_C_TYPE_TIMESTAMP}
          SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
          SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
          SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {interval}

        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {SQL_INTEGER, SQL_SMALLINT}

      SQL_BIT:
      begin
        //Note: not standard - we use ODBC bit definition here, although server uses standard
        //todo when server BIT can be returned - not sure how yet... 1 byte per 8 bits?
      end; {SQL_BIT}
      SQL_BINARY:
      begin
        //todo when server BINARY/BLOBs? can be returned - not sure how yet...
        //need to return as 2 hex chars per byte
      end; {SQL_BINARY}

      SQL_TYPE_DATE:
      begin
        if marshal.getSQLDATE(tempSdate)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

        case Todesc_type of
          SQL_C_TYPE_DATE:
          begin
            try
              tempDate:=dateToODBCDate(tempSdate);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempDate,dataPtr^,sizeof(tempDate));
            tempsdw:=sizeof(tempDate);
          end; {SQL_C_TYPE_DATE}
          SQL_C_CHAR:
          begin
            tempStr:=sqlDateToStr(tempSdate);
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
        else
          //rest = incomatible
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {SQL_TYPE_DATE}

      SQL_TYPE_TIME:
      begin
        if marshal.getSQLTIME(tempStime)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

        case Todesc_type of
          SQL_C_TYPE_TIME:
          begin
            try
              tempTime:=timeToODBCTime(tempStime);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempTime,dataPtr^,sizeof(tempTime));
            tempsdw:=sizeof(tempTime);
          end; {SQL_C_TYPE_TIME}
          SQL_C_CHAR:
          begin
            tempStr:=sqlTimeToStr(TIMEZONE_ZERO,tempStime,fromDesc.desc_scale,dayCarry);
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
        else
          //rest = incomatible
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {SQL_TYPE_TIME}

      SQL_TYPE_TIMESTAMP:
      begin
        if marshal.getSQLTIMESTAMP(tempStimestamp)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

        case Todesc_type of
          SQL_C_TYPE_TIMESTAMP:
          begin
            try
              tempTimestamp:=timestampToODBCTimestamp(tempStimestamp);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            move(tempTimestamp,dataPtr^,sizeof(tempTimestamp));
            tempsdw:=sizeof(tempTimestamp);
          end; {SQL_C_TYPE_TIME}
          SQL_C_CHAR:
          begin
            tempStr:=sqlTimestampToStr(TIMEZONE_ZERO,tempStimestamp,fromDesc.desc_scale);
            strLcopy(pUCHAR(dataPtr),pchar(tempStr),desc_octet_length-1);
            tempsdw:=length(tempStr); //return number of octets
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
          end; {SQL_C_CHAR}
        else
          //rest = incomatible
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {SQL_TYPE_TIMESTAMP}

      SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH:
      begin
        //todo when server year-month intervals can be returned - not sure how yet...
      end; {SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH}

      SQL_INTERVAL_DAY, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR, SQL_INTERVAL_DAY_TO_SECOND,
      SQL_INTERVAL_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE, SQL_INTERVAL_SECOND, SQL_INTERVAL_HOUR_TO_SECOND,
      SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_MINUTE_TO_SECOND:
      begin
        //todo when server day-time intervals can be returned - not sure how yet...
      end; {day-time interval}

      SQL_LONGVARBINARY,
      SQL_LONGVARCHAR:
      begin
        if marshal.getpData(dataPtr,desc_octet_length,tempsdw)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;
        {$IFDEF DEBUGDETAIL3}
        log(format('getAndConvert reading blob size %d into buffer size %d',[tempsdw,desc_octet_length]));
        {$ENDIF}
        case Todesc_type of
          SQL_LONGVARBINARY, SQL_LONGVARCHAR, SQL_C_BINARY{BDE uses this}, SQL_C_DEFAULT:
          begin
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
              tempsdw:=desc_octet_length; //return number of characters = number of octects
            end;
          end;
          SQL_C_CHAR:
          begin
            //todo SQL_C_CHAR - add null?
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
              tempsdw:=desc_octet_length; //return number of characters = number of octects
            end;
          end;
          //todo clob converts to most others... treat as varchar?
        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {blob}


    else
    //SQL type not supported/recognised?

    //for now =not done yet, so default to plain copy...
    //TODO REMOVE!!!!!!!!!!!!!! - just error- which error code?!
        //note: we don't add a null terminator here
        if marshal.getpData(dataPtr,desc_octet_length,tempsdw)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;

    end; {case}
  finally
    if tempBuf<>nil then //todo check we initialise to nil
      freeMem(tempBuf); //todo check safe without size!
  end; {try}
end; {getAndConvert}

function putAndConvert(Todesc:TdescRec;Fromdesc_type:SQLSMALLINT;
                       dataPtr:SQLPOINTER;tempsdwIN{todo replaced desc_octet_length}:SQLINTEGER;
                       marshal:TMarshalBuffer; var tempsdw:SDWORD; //todo maybe just keep this for in & out? or better to keep symmetrical?
                       diag:Tdiagnostic; row:SQLUINTEGER;rn:SQLSMALLINT):integer;

//notes: tempsdw is passed as the length from the application
//       could be SQL_NTS (user passed or length-ptr=nil) -so we should calculate the length here -length()?
//       could be ...send_later...SQL_DATA_AT_EXEC, in which case we send that (i.e. a -ve length + no data!)

// false null flag has already been sent to server - we don't get here if we're null!
// so we can use the dataPtr
//todo this assertion/algorithm may change..............*******

//Todesc_type and FromDesc_type are left same way round as getAndConvert
// - this makes the code more maintainable
// - todo should rename them then to X and Y or SQL and C or something...
var
  tempBuf:pUCHAR;
  tempSmallInt:SQLSMALLINT;
  tempInt:SQLINTEGER; //todo remove:cardinal;
  tempExtended:Extended;
  tempSingle:single;
  tempDouble:SQLDOUBLE; //todo remove:double;
  tempStr:string;

  i:shortint;
//todo remove  tempByte:byte;
  tempNumeric:SQL_NUMERIC_STRUCT;
  tempComp:comp;
begin
//copied from getAndConvert - keep in synch!!!!!!
  result:=ok; //default
  tempBuf:=nil;
  {$IFDEF DEBUGDETAIL}
  log(format('putAndConvert called %d %d %p %d %d',[Todesc.desc_concise_type,Fromdesc_type,DataPtr,tempsdwIN,tempsdw]));
  {$ENDIF}

  //todo if Fromdesc_type=SQL_ARD_TYPE then set Todesc.desc_type=Fromdesc_type? guess!

  if tempsdw=SQL_DATA_AT_EXEC then
  begin //will send later, so server will leave as ?
    if marshal.putpDataSDWORD(dataPtr,0)<>ok then
    begin
      result:=SQL_ROW_ERROR;
      diag.logError(ss08S01,fail,'',row,rn); //todo check result
      exit;
    end;
    exit; //done
  end;

  try
    case Fromdesc_type of
      SQL_CHAR, SQL_VARCHAR: //SQL_LONGVARCHAR, SQL_WCHAR, SQL_WVARCHAR, SQL_WLONGVARCHAR
      begin
        case Todesc.desc_concise_type of
          SQL_C_CHAR, SQL_C_DEFAULT:
          begin
            if FixStringSDWORD(pUCHAR(dataPtr),tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ssHY090,fail,'',0,0); //todo ok here -was c.diag? //todo check result
              exit;
            end;
            //todo use routine that auto adds null - todo for other putpUCHAR calls...
            if marshal.putpDataSDWORD(dataPtr,tempsdw+sizeof(nullterm){\0})<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            (*todo remove- no equivalent?
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of characters = number of octects
            *)
          end; {SQL_C_CHAR, SQL_C_DEFAULT}
          (* not in ODBC.h? todo for ODBC 3  - add to all conversions
          SQL_C_WCHAR:
          begin
            if marshal.getpUCHAR(dataPtr,desc_octet_length,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw div 2; //return number of characters, not octects
          end; {SQL_C_WCHAR}
          *)
          SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT,
          SQL_C_SBIGINT,SQL_C_UBIGINT,
          SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT,
          SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
          begin
            case Todesc.desc_concise_type of
              SQL_C_STINYINT,SQL_C_UTINYINT,SQL_C_TINYINT:
              begin
                if Todesc.desc_concise_type<>SQL_C_UTINYINT then
                begin
                  try
                    tempStr:=IntToStr(shortint(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end
                else
                begin
                  try
                    tempStr:=IntToStr(byte(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
              end;
              SQL_C_SBIGINT,SQL_C_UBIGINT:
              begin
              end;
              SQL_C_SSHORT,SQL_C_USHORT,SQL_C_SHORT:
              begin
                if Todesc.desc_concise_type<>SQL_C_USHORT then
                begin
                  try
                    tempStr:=IntToStr(smallint(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end
                else
                begin
                  try
                    tempStr:=IntToStr(word(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
              end;
              SQL_C_SLONG,SQL_C_ULONG,SQL_C_LONG:
              begin
                if Todesc.desc_concise_type<>SQL_C_ULONG then
                begin
                  try
                    tempStr:=IntToStr(longint(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end
                else
                begin
                  try
                    tempStr:=IntToStr(cardinal(dataPtr^));
                    tempsdw:=length(tempStr);
                  except
                    on E:Exception do
                    begin
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22018,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
              end;
            else
              //todo assertion!****
            end; {case}
            if marshal.putpDataSDWORD(pchar(tempStr),tempsdw+sizeof(nullterm){include \0})<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
          end; {numeric}
          SQL_C_FLOAT,
          SQL_C_DOUBLE,
          SQL_C_NUMERIC:
          begin
            case Todesc.desc_concise_type of
              SQL_C_FLOAT:
              begin
                try
                  tempStr:=FloatToStr(single(dataPtr^));
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
              end;
              SQL_C_DOUBLE:
              begin
                try
                  tempStr:=FloatToStr(double(dataPtr^));
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
              end;
              SQL_C_NUMERIC:
              begin
                try
                  (*todo: not sure we need this (yet)??
                  {Adjust the value for storage}
                  c:=d*power(10,fColDef[col].scale); //i.e. shift scale decimal places to the left
                  *)
                  tempComp:=Comp(dataPtr^);
                  tempStr:=FloatToStr(tempComp);
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
                (*todo !!!!! add sign & point
                {Convert to a scaled integer}
                i:=pos('.',trim(tempBuf));
                if i<>0 then
                begin
                  i:=length(trim(tempBuf))-i;
                  //todo better to remove '.' and strToInt() buffer again (cut out intermediate type = no need for power or trunc)
                  try
                    tempExtended:=tempExtended*power(10,i); //i.e. shift i decimal places to the left
                  except
                    on E:Exception do
                    begin
                      //todo: reduce scale & warn loss of fraction part & continue?
                      result:=SQL_ROW_ERROR;
                      diag.logError(ss22003,fail,'',row,rn); //todo check result
                      exit;
                    end;
                  end; {try}
                end;
                tempNumeric.scale:=i;  //=SQLSCHAR=shortint

                try
                  tempComp:=trunc(tempExtended); //should lose nothing! todo check/catch any loss
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22003,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
                {Return as hex/little endian}
                if tempComp<0 then tempNumeric.sign:=#0 else tempNumeric.sign:=#1;
                tempComp:=abs(tempComp); //remove the sign
                move(tempComp,tempNumeric.val,sizeof(tempComp));
                tempNumeric.precision:=SQLCHAR(SQL_MAX_NUMERIC_LEN); //todo get our real max from shared global
                move(tempNumeric,pSQL_NUMERIC_STRUCT(dataPtr)^,sizeof(tempNumeric));
                tempsdw:=sizeof(tempNumeric);
                *)
              end; {SQL_C_NUMERIC}
            else
              //todo assertion!
            end; {case}
            if marshal.putpDataSDWORD(pchar(tempStr),tempsdw+sizeof(nullterm){include \0})<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
          end; {float,double,numeric}
          SQL_C_BIT:
          begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
            (*todo
            if marshal.getpUCHAR(tempBuf,DYNAMIC_ALLOCATION,tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            try
              tempSingle:=StrToFloat(tempBuf);
            except
              on E:Exception do
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end; {try}
            if (tempSingle=0) or (tempSingle=1) then
            begin
              byte(dataPtr^):=byte(trunc(tempSingle));
              tempsdw:=sizeof(byte);
            end
            else
            begin
              if (tempSingle>0) or (tempSingle<2) then
              begin
                result:=SQL_ROW_SUCCESS_WITH_INFO;
                diag.logError(ss01S07,fail,'',row,rn); //todo check result
                byte(dataPtr^):=byte(trunc(tempSingle));
                tempsdw:=sizeof(byte);
              end
              else
              begin
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
              end;
            end;
            *)
          end; {SQL_C_BIT}
          SQL_C_TYPE_DATE,
          SQL_C_TYPE_TIME,
          SQL_C_TYPE_TIMESTAMP:
          begin
            case Todesc.desc_concise_type of
              SQL_C_TYPE_DATE:
              begin
                try
                  tempStr:=ODBCdateToStr(SQL_DATE_STRUCT(dataPtr^));
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
              end; {SQL_C_TYPE_DATE}
              SQL_C_TYPE_TIME:
              begin
                try
                  tempStr:=ODBCtimeToStr(SQL_TIME_STRUCT(dataPtr^));
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
              end; {SQL_C_TYPE_TIME}
              SQL_C_TYPE_TIMESTAMP:
              begin
                try
                  tempStr:=ODBCtimestampToStr(SQL_TIMESTAMP_STRUCT(dataPtr^));
                  tempsdw:=length(tempStr);
                except
                  on E:Exception do
                  begin
                    result:=SQL_ROW_ERROR;
                    diag.logError(ss22018,fail,'',row,rn); //todo check result
                    exit;
                  end;
                end; {try}
              end; {SQL_C_TYPE_TIMESTAMP}
            else
              //todo assertion!
            end;
            if marshal.putpDataSDWORD(pchar(tempStr),tempsdw+sizeof(nullterm){include \0})<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
          end; {SQL_C_TYPE_DATE,SQL_C_TYPE_TIME,SQL_C_TYPE_TIMESTAMP}
          SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
          SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
          SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
          begin
            //todo
                result:=SQL_ROW_ERROR;
                diag.logError(ss22018,fail,'',row,rn); //todo check result
                exit;
          end; {interval}
          SQL_C_BINARY{BDE uses this},
          SQL_LONGVARBINARY,SQL_LONGVARCHAR{todo debug test...remove?}:
          begin
            (*n/a
            if FixStringSDWORD(pUCHAR(dataPtr),tempsdw)<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ssHY090,fail,'',0,0); //todo ok here -was c.diag? //todo check result
              exit;
            end;
            *)
            tempsdw:=tempsdwIN;
            if marshal.putpDataSDWORD(dataPtr,tempsdw(*+sizeof(nullterm){\0}*))<>ok then
            begin
              result:=SQL_ROW_ERROR;
              diag.logError(ss08S01,fail,'',row,rn); //todo check result
              exit;
            end;
            (*todo remove- no equivalent?
            if tempsdw>desc_octet_length then
            begin
              result:=SQL_ROW_SUCCESS_WITH_INFO;
              diag.logError(ss01004,fail,'',row,rn); //todo check result
            end;
            tempsdw:=tempsdw; //return number of characters = number of octects
            *)
          end; {SQL_LONGVARBINARY,SQL_LONGVARCHAR}
        else //not a conversion supported by ODBC
          result:=SQL_ROW_ERROR;
          diag.logError(ss07006,fail,'',row,rn); //todo check result
          exit;
        end; {case}
      end; {character}

    else
    //SQL type not supported/recognised?

    //for now =not done yet, so default to plain copy...
    //TODO REMOVE!!!!!!!!!!!!!! - just error- which error code?!
        //note: we don't add a null terminator here
        if marshal.putpDataSDWORD(dataPtr,tempsdwIN)<>ok then
        begin
          result:=SQL_ROW_ERROR;
          diag.logError(ss08S01,fail,'',row,rn); //todo check result
          exit;
        end;
        //todo tempsdw:=desc_octet_length   //i.e. return tempsdw - if its needed at all!!!? todo
    end; {case}
  finally
    if tempBuf<>nil then
      freeMem(tempBuf); //todo check safe without size!
  end; {try}
end;

end.

{$IFNDEF DBEXP_STATIC}
unit uGlobalDB;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses DBXpress;
{$ENDIF}
{$IFNDEF DBEXP_IMPLEMENTATION}

type
  TBit=0..31;

const
  {todo: until SQLresult in DBXpress is made big enough to handle SQL_ERROR, or we have a generic error}
  //todo remove SQL_ERROR2 = $0001 {=DBXERR_NOMEMORY};
  //maybe should use MaxReservedStaticErrors+ ?
  //SQL_ERROR2 = DBX_MAXSTATICERRORS+10;
  //DBXERR_SYNTAX = DBX_MAXSTATICERRORS+20;
  SQL_ERROR2 = MaxReservedStaticErrors+10;
  DBXERR_SYNTAX = MaxReservedStaticErrors+20;

  DBX_TIME_FRACTION_SCALE=3; //milliseconds

  nullchar:char=#0;

  ok=0;
  fail=-1;

  DBTrue=1;
  DBFalse=0;

  EscapeChar='\';
  LIKE_ALL='%';
  LIKE_ONE='_';

  {todo read from server in future}
  MAX_NAME_LEN=128;
  MAX_COL_PER_TABLE=300;
  MAX_PARAM_PER_QUERY=300;
  MAX_ROW_SIZE=4000;
  MAX_SQL_SIZE=32767; //todo should be infinite!

  desc_name_SIZE=30+1; //todo max_col_name_size from server global  //todo replace 1 with unicode friendly sizeof(nullterm)
                       //must keep in sync with sizeof DBINAME in DBXpress



  clientCLIversion=0100;             //client parameter passing version
  {                0092   last used 00.04.09 beta (Server 00.04.09) - now pass bufferLen in SQLgetData for blob chunking & widths as integer and handshake sends extra
                   0091   last used 00.04.01 beta (Server 00.04.04) - now pass stored procedure result sets
  }

  //todo: get these from a common unit shared by ODBC: uMarshalGlobal?
  defaultHost='localhost';
  defaultPort=9075;

  ss08001='Send communication failed';

  ss08S01='Read communication failed';
  ssHYT00=ss08S01;

  ssHY010='Sequence error';


{$IFNDEF DBEXP_STATIC}
//todo: replace odbc.inc with a cut-down version!
{Include the ODBC standard definitions}
{$define NO_FUNCTIONS}
{$include ODBC.INC}
{$ENDIF}

var
  {Global vars used by all routines - not thread safe!}
  functionId:SQLUSMALLINT;
  resultCode:RETCODE;
  resultErrCode:SQLINTEGER;
  resultErrText:pUCHAR;
  tempsw:SWORD;

function returnNumber(i:integer;p:pointer;maxLength:smallint):smallint;
function returnString(s:string;p:pointer;maxLength:smallint):smallint;
function hidenil(p:pchar):string;
function convertType(desc_type:Integer;var sub_type:Word):Word;
function bitSet(const Value: cardinal; const TheBit: TBit): Boolean;
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses SysUtils,
     uLog;
{$ENDIF}
{$IFNDEF DBEXP_INTERFACE}

function returnNumber(i:integer;p:pointer;maxLength:smallint):smallint;
{Safely write the result to memory}
begin
  if maxLength>=sizeof(i) then
  begin
    integer(p^):=i;
    result:=sizeof(i);
  end
  else
  begin
    //todo try writing as smallint if no data loss etc.
    //for now we return error!
    result:=0;
  end;
end; {returnNumber}

function returnString(s:string;p:pointer;maxLength:smallint):smallint;
{Safely write the result to memory}
begin
  if maxLength>=length(s)+1 then
  begin
    strLCopy(pchar(p),pchar(s),maxLength-1);
    result:=length(s); //todo +1?
  end
  else
  begin
    //todo try writing as truncated = data loss
    //for now we return error!
    result:=0;
  end;
end; {returnString}

function hidenil(p:pchar):string;
begin
  if p=nil then
    result:='<nil>'
  else
    result:=p;
end; {hidenil}

function convertType(desc_type:Integer;var sub_type:Word):Word;
{Convert server type to DBXpress type
 IN        desc_type   SQL type from server
 OUT       sub_type    DBXpress subtype if applicable, else 0
 RETURN:   converted DBXpress desc_type

 Note: keep in sync. with metadate column types
}
begin
  result:=fldUNKNOWN;

  sub_type:=0; //n/a

  case desc_type of
    SQL_CHAR:            begin result:=fldZSTRING; sub_type:=fldstFIXED; end;
    SQL_VARCHAR:         result:=fldZSTRING; //pchar

    SQL_LONGVARBINARY:   begin result:=fldBLOB; sub_type:=fldstBINARY; end;
    SQL_LONGVARCHAR:     begin result:=fldBLOB; sub_type:=fldstMEMO; end;

    SQL_NUMERIC, SQL_DECIMAL:      result:=fldBCD;

    SQL_FLOAT:                     result:=fldFLOAT; //double

    SQL_INTEGER, SQL_SMALLINT:     result:=fldINT32; //integer


    //N/A SQL_REAL, SQL_DOUBLE:

    SQL_TYPE_DATE:                 result:=fldDATE;

    SQL_TYPE_TIME:                 result:=fldTIME;

    SQL_TYPE_TIMESTAMP:            result:=fldDATETIME; 


    (* N/A yet
    SQL_TYPE_TIME_WITH_TIMEZONE,
    SQL_TYPE_TIMESTAMP_WITH_TIMEZONE,
    SQL_INTERVAL_YEAR, SQL_INTERVAL_MONTH, SQL_INTERVAL_YEAR_TO_MONTH,
    SQL_INTERVAL_DAY, SQL_INTERVAL_HOUR, SQL_INTERVAL_MINUTE, SQL_INTERVAL_DAY_TO_HOUR, SQL_INTERVAL_DAY_TO_MINUTE, SQL_INTERVAL_HOUR_TO_MINUTE,
    SQL_INTERVAL_SECOND, SQL_INTERVAL_DAY_TO_SECOND, SQL_INTERVAL_HOUR_TO_SECOND, SQL_INTERVAL_MINUTE_TO_SECOND:
    *)
  else
    {$IFDEF DEBUG_LOG}
    log(format('convertType found unknown server column type %d',[desc_type]),vError);
    {$ENDIF}
  end; {case}
end; {convertType}

{Note: in these bit routines, 0 is the first bit}
function bitSet(const Value: cardinal; const TheBit: TBit): Boolean;
{Checks if a bit is set}
begin
  Result:= (Value and (1 shl TheBit)) <> 0;
end;
{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


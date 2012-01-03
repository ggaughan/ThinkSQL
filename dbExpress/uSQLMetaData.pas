{$IFNDEF DBEXP_STATIC}
unit uSQLMetaData;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

uses uSQLConnection,
     DBXpress;
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}
type
  TSQLMetaData=class(TInterfacedObject,ISQLMetaData)
  private
    SQLConnection:TxSQLConnection;
    SQLConnectionRef:ISQLConnection; //purely used to keep ref. count in order

    schema:string;

    errorMessage:string;
    procedure logError(s:string);
  public
    constructor Create(c:TxSQLConnection);

    function SetOption(eDOption: TSQLMetaDataOption;
                     PropValue: LongInt): SQLResult; stdcall;
    function GetOption(eDOption: TSQLMetaDataOption; PropValue: Pointer;
                     MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
    function getObjectList(eObjType: TSQLObjectType; out Cursor: ISQLCursor):
                     SQLResult; stdcall;
    function getTables(TableName: PChar; TableType: LongWord;
                     out Cursor: ISQLCursor): SQLResult; stdcall;
    function getProcedures(ProcedureName: PChar; ProcType: LongWord;
                     out Cursor: ISQLCursor): SQLResult; stdcall;
    function getColumns(TableName: PChar; ColumnName: PChar;
                     ColType: LongWord; Out Cursor: ISQLCursor): SQLResult; stdcall;
    function getProcedureParams(ProcName: PChar; ParamName: PChar;
                     out Cursor: ISQLCursor): SQLResult; stdcall;
    function getIndices(TableName: PChar; IndexType: LongWord;
                     out Cursor: ISQLCursor): SQLResult; stdcall;
    function getErrorMessage(Error: PChar): SQLResult; overload; stdcall;
    function getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
  end; {TSQLMetaData}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses uLog,
     uGlobalDB,
     SysUtils,
     uSQLCursor,
     uSQLCommand;
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
constructor TSQLMetaData.Create(c:TxSQLConnection);
begin
  inherited create;

  SQLConnection:=c;
  SQLConnectionRef:=c;
end; {create}

procedure TSQLMetaData.logError(s:string);
begin
  errorMessage:=s;
end; {logError}


function TSQLMetaData.SetOption(eDOption: TSQLMetaDataOption;
                 PropValue: LongInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLMetaData.SetOption called %d %d',[ord(eDOption),PropValue]),vLow);
  {$ENDIF}

  case eDOption of
    eMetaCatalogName:           ;
    eMetaSchemaName:            begin
                                  //todo => pass 'SET SCHEMA schema' to server!!!!!???
                                  schema:=pchar(PropValue);
                                  {$IFDEF DEBUG_LOG}
                                  log(format('Set schema name %s',[schema]),vLow);
                                  {$ENDIF}
                                end;
    eMetaDatabaseName:          ;
    eMetaDatabaseVersion:       ;
    eMetaTransactionIsoLevel:   ;
    eMetaSupportsTransaction:   ;
    eMetaMaxObjectNameLength:   ;
    eMetaMaxColumnsInTable:     ;
    eMetaMaxColumnsInSelect:    ;
    eMetaMaxRowSize:            ;
    eMetaMaxSQLLength:          ;
    eMetaObjectQuoteChar:       ;
    eMetaSQLEscapeChar:         ;
    eMetaProcSupportsCursor:    ;
    eMetaProcSupportsCursors:   ;
    eMetaSupportsTransactions:  ;
  end; {case}

  result:=SQL_SUCCESS;
end; {SetOption}

function TSQLMetaData.GetOption(eDOption: TSQLMetaDataOption; PropValue: Pointer;
                 MaxLength: SmallInt; out Length: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log(format('TSQLMetaData.GetOption called %d %d',[ord(eDOption),MaxLength]),vLow);
  {$ENDIF}

  case eDOption of
    eMetaCatalogName:           length:=returnString('',PropValue,MaxLength); //todo catalog from server
    eMetaSchemaName:            length:=returnString(schema,PropValue,MaxLength); //todo schema from server = INFORMATION_SCHEMA?
    eMetaDatabaseName:          length:=returnString('',PropValue,MaxLength); //todo db from server
    eMetaDatabaseVersion:       length:=returnString('',PropValue,MaxLength); //todo db-version from server
    eMetaTransactionIsoLevel:   length:=returnNumber(ord(xilREPEATABLEREAD),PropValue,MaxLength); //todo: make stronger via custom... & get from server
    eMetaSupportsTransaction:   length:=returnNumber(DBTrue,PropValue,MaxLength);
    eMetaMaxObjectNameLength:   length:=returnNumber(MAX_NAME_LEN,PropValue,MaxLength); //todo from server
    eMetaMaxColumnsInTable:     length:=returnNumber(MAX_COL_PER_TABLE,PropValue,MaxLength); //todo from server
    eMetaMaxColumnsInSelect:    length:=returnNumber(MAX_COL_PER_TABLE,PropValue,MaxLength); //todo from server
    eMetaMaxRowSize:            length:=returnNumber(MAX_ROW_SIZE,PropValue,MaxLength); //todo from server
    eMetaMaxSQLLength:          length:=returnNumber(MAX_SQL_SIZE,PropValue,MaxLength); //todo from server
    eMetaObjectQuoteChar:       length:=returnString('"',PropValue,MaxLength); //todo from server?
    eMetaSQLEscapeChar:         length:=returnString(EscapeChar,PropValue,MaxLength); //todo from server? - up to client to use in LIKE...ESCAPE syntax!
    eMetaProcSupportsCursor:    length:=returnNumber(DBTrue,PropValue,MaxLength); //todo true in future?
    eMetaProcSupportsCursors:   length:=returnNumber(DBFalse,PropValue,MaxLength); //todo true in future?
    eMetaSupportsTransactions:  length:=returnNumber(DBFalse,PropValue,MaxLength); //todo true in future?
  end; {case}

  result:=SQL_SUCCESS;
end; {GetOption}

function TSQLMetaData.getObjectList(eObjType: TSQLObjectType; out Cursor: ISQLCursor):
                 SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getObjectList called %d',[ord(eObjType)]),vLow);
  {$ENDIF}

  case eObjType of
    eObjTypeDatabase:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           ''''' AS CATALOG_NAME,'+
           ''''' AS SCHEMA_NAME,'+
           'CATALOG_NAME AS OBJECT_NAME,'+
           'FROM INFORMATION_SCHEMA.INFORMATION_SCHEMA_CATALOG_NAME '+
           'ORDER BY OBJECT_NAME';

    eObjTypeDataType:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           ''''' AS CATALOG_NAME,'+
           ''''' AS SCHEMA_NAME,'+
           'TYPE_NAME AS OBJECT_NAME,'+
           'FROM INFORMATION_SCHEMA.TYPE_INFO '+
           'ORDER BY OBJECT_NAME';

    eObjTypeTable:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           'TABLE_CATALOG AS CATALOG_NAME,'+
           'TABLE_SCHEMA AS SCHEMA_NAME,'+
           'TABLE_NAME AS OBJECT_NAME,'+
           'FROM INFORMATION_SCHEMA.TABLES '+
           'WHERE TABLE_TYPE=''BASE TABLE'' '+
           'AND TABLE_SCHEMA=CURRENT_SCHEMA '+ //'''+schema+''' '+
           'ORDER BY OBJECT_NAME';

    eObjTypeView:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           'TABLE_CATALOG AS CATALOG_NAME,'+
           'TABLE_SCHEMA AS SCHEMA_NAME,'+
           'TABLE_NAME AS OBJECT_NAME,'+
           'FROM INFORMATION_SCHEMA.TABLES '+
           'WHERE TABLE_TYPE=''VIEW'' '+
           'AND TABLE_SCHEMA=CURRENT_SCHEMA '+ //'''+schema+''' '+
           'ORDER BY OBJECT_NAME';

    eObjTypeSynonym:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           ''''' AS CATALOG_NAME,'+
           ''''' AS SCHEMA_NAME,'+
           ''''' AS OBJECT_NAME,'+
           'FROM (VALUES(0)) AS SYNONYM '+
           'WHERE 1=0 ';

    eObjTypeProcedure:
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           'ROUTINE_CATALOG AS CATALOG_NAME,'+
           'ROUTINE_SCHEMA AS SCHEMA_NAME,'+
           'ROUTINE_NAME AS OBJECT_NAME,'+
           'FROM INFORMATION_SCHEMA.ROUTINES '+
           'WHERE ROUTINE_TYPE=''PROCEDURE'' '+
           'AND ROUTINE_SCHEMA=CURRENT_SCHEMA '+ //'''+schema+''' '+
           'ORDER BY OBJECT_NAME';

    eObjTypeUser,  //todo implement
    eObjTypeRole,  //todo implement
    eObjTypeUDT:
    begin
      result:=DBXERR_NOTSUPPORTED;
      exit;
    end;
  else
    result:=DBXERR_NOTSUPPORTED;
    exit;
  end; {case}

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getObjectList}

function PatternWhere(const s:string):string;
{Creates a Where clause for a pattern search string
 IN:       s                the column value to search for

 Returns:  (with any escaped wildcard characters removed)
           ='s' if no wildcards (LIKE_ONE,LIKE_ALL)
           or
           LIKE 's' ESCAPE '\' if wildcards
           e.g. TABLE\_NAME  ->  ='TABLE_NAME'
                TABLE_NAME   ->  LIKE 'TABLE_NAME'
                TABLE%       ->  LIKE 'TABLE%'
                TABLE\%      ->  ='TABLE%'

 Note: we ignore LIKE_ONE (_) for now since it's so commonly not escaped by callers! (27/01/02)
       todo: fix... client bug really? maybe check if they've asked about our escape character - most don't!
}
var
  i:integer;
  patterned:boolean;
begin
  //todo if stmt.metadataId=True then search patterns are not accepted

  (*todo remove: odbc only(?)
  if s='' then
  begin
    result:='LIKE '''+LIKE_ALL+''' ';
    exit;
  end;
  *)

  begin
    result:='';
    patterned:=False;
    i:=1;
    while i<=length(s) do
    begin
      if (s[i]=EscapeChar) and (i<length(s)) and ((s[i+1]=LIKE_ALL) or (s[i+1]=LIKE_ONE)) then //assumes boolean short-circuiting
        inc(i) //skip escape character
      else
        if (s[i]=LIKE_ALL) {todo reinstate: or (s[i]=LIKE_ONE)} then patterned:=True; //was not escaped

      result:=result+s[i];
      inc(i);
    end;

    if patterned then
      result:='LIKE '''+result+''' ESCAPE '''+EscapeChar+''' '
    else
      result:='='''+result+''' ';
  end;
end; {PatternWhere}


function TSQLMetaData.getTables(TableName: PChar; TableType: LongWord;
                 out Cursor: ISQLCursor): SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getTables called %s %d',[hidenil(TableName),TableType]),vLow);
  {$ENDIF}

  //todo everywhere we check schema, ensure catalog=CURRENT_CATALOG...
  where:='WHERE TABLE_SCHEMA=CURRENT_SCHEMA '; //'''+schema+''' ';

  if TableName<>nil then
  begin
    where:=where+'AND TABLE_NAME '+patternWhere(TableName); //LIKE '''+TableName+''' ESCAPE '''+EscapeChar+''' ';
  end;

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    SQL:='SELECT '+
         '1 AS REC_NO,'+
         'TABLE_CATALOG AS CATALOG_NAME,'+
         'TABLE_SCHEMA AS SCHEMA_NAME,'+
         'TABLE_NAME,'+
         'CASE TABLE_TYPE '+
         '  WHEN ''BASE TABLE'' THEN 0'+
         '  WHEN ''VIEW'' THEN '+
         '    CASE TABLE_SCHEMA '+
         '      WHEN ''INFORMATION_SCHEMA'' THEN 2'+
         '    ELSE 1'+
         '    END '+
         'ELSE 0 '+     //default to table: todo ok?
         'END AS TABLE_TYPE '+
         'FROM INFORMATION_SCHEMA.TABLES '+
         where+
         'ORDER BY TABLE_NAME';
    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getTables}

function TSQLMetaData.getProcedures(ProcedureName: PChar; ProcType: LongWord;
                 out Cursor: ISQLCursor): SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getProcedures called %s %d',[hidenil(ProcedureName),ProcType]),vLow);
  {$ENDIF}

  where:='WHERE ROUTINE_SCHEMA=CURRENT_SCHEMA '; //'''+schema+''' ';

  if ProcedureName<>nil then
  begin
    where:=where+'AND ROUTINE_NAME '+patternWhere(ProcedureName); //LIKE '''+ProcedureName+''' ESCAPE '''+EscapeChar+''' ';
  end;

  (*todo build ROUTINE_TYPE IN (p,f)
  if bitset(ProcType,eSQLProcedure) then
  if bitset(ProcType,eSQLFunction) then
  *)

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    SQL:='SELECT '+
         '1 AS REC_NO,'+
         'ROUTINE_CATALOG AS CATALOG_NAME,'+
         'ROUTINE_SCHEMA AS SCHEMA_NAME,'+
         'ROUTINE_NAME AS PROC_NAME,'+
         'CASE ROUTINE_TYPE '+
         '  WHEN ''PROCEDURE'' THEN '+intToStr(eSQLProcedure)+
         '  WHEN ''FUNCTION'' THEN '+intToStr(eSQLFunction)+
         ' END AS PROC_TYPE,'+
         '(SELECT COUNT(*) FROM INFORMATION_SCHEMA.PARAMETERS P WHERE P.SPECIFIC_SCHEMA=R.ROUTINE_SCHEMA AND P.SPECIFIC_NAME=R.ROUTINE_NAME AND PARAMETER_MODE IN (''IN'',''INOUT'')) AS IN_PARAMS,'+
         '(SELECT COUNT(*) FROM INFORMATION_SCHEMA.PARAMETERS P WHERE P.SPECIFIC_SCHEMA=R.ROUTINE_SCHEMA AND P.SPECIFIC_NAME=R.ROUTINE_NAME AND PARAMETER_MODE IN (''OUT'',''INOUT'')) AS OUT_PARAMS '+ //todo include results when we return them...
         'FROM INFORMATION_SCHEMA.ROUTINES R '+
         where+
         'ORDER BY PROC_NAME ';
    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getProcedures}

function TSQLMetaData.getColumns(TableName: PChar; ColumnName: PChar;
                 ColType: LongWord; Out Cursor: ISQLCursor): SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getColumns called %s %s %d',[hidenil(TableName),hidenil(ColumnName),ColType]),vLow);
  {$ENDIF}

  where:='WHERE schema_name=CURRENT_SCHEMA '; //'''+schema+''' ';
  where:=where+'AND schema_id<>1 '; //todo replace 1 with constant for sysCatalog
  if TableName<>nil then
    where:=where+'AND TABLE_NAME '+patternWhere(TableName); //LIKE '''+TableName+''' ESCAPE '''+EscapeChar+''' ';

  (*todo reinstate: for some reason never seemed blank but was...
  if (ColumnName<>nil) and (trim(ColumnName)<>'') then
    where:=where+'AND COLUMN_NAME LIKE '''+ColumnName+''' ESCAPE '''+EscapeChar+''' ';
  *)

  //todo + colType filter

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    SQL:='SELECT '+
         '1 AS REC_NO,'+
         'catalog_name AS CATALOG_NAME,'+
         'schema_name AS SCHEMA_NAME,'+
         'TABLE_NAME,'+
         'COLUMN_NAME, '+
         'column_id AS COLUMN_POSITION,'+
         '0 AS COLUMN_TYPE,'+
         'CASE type_name '+              //todo keep in sync with convertType
         '  WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants for DBXpress!
         '  WHEN ''NUMERIC'' THEN 8 '+
         '  WHEN ''DECIMAL'' THEN 8 '+
         '  WHEN ''INTEGER'' THEN 6 '+
         '  WHEN ''SMALLINT'' THEN 6 '+
         '  WHEN ''FLOAT'' THEN 7 '+
         '  WHEN ''REAL'' THEN 7 '+
         '  WHEN ''DOUBLE PRECISION'' THEN 7 '+
         '  WHEN ''CHARACTER VARYING'' THEN 1 '+
         '  WHEN ''DATE'' THEN 2 '+ //todo ok?
         '  WHEN ''TIME'' THEN 10 '+ //todo ok?
         '  WHEN ''TIMESTAMP'' THEN 24 '+
         '  WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
         '  WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 24 '+
         '  WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
         '  WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         'END AS COLUMN_DATATYPE, '+
         'TYPE_NAME AS COLUMN_TYPENAME, '+
         'CASE type_name '+
         '  WHEN ''CHARACTER'' THEN 31 '+ //todo replace with constants for DBXpress!
         '  WHEN ''BINARY LARGE OBJECT'' THEN 23 '+ //todo?34 '+
         '  WHEN ''CHARACTER LARGE OBJECT'' THEN 22 '+ //todo?34 '+
         'ELSE 0 '+
         'END AS COLUMN_SUBTYPE,'+
         'CASE '+
         '    WHEN type_name=''CHARACTER'' '+
         '      OR type_name=''CHARACTER VARYING'' '+
         //todo etc.
         '    THEN width '+
         '    WHEN type_name=''NUMERIC'' '+
         '      OR type_name=''DECIMAL'' '+
         '    THEN width '+
         '    WHEN type_name=''SMALLINT'' THEN 5 '+
         '    WHEN type_name=''INTEGER'' THEN 10 '+
         '    WHEN type_name=''REAL'' THEN 7 '+
         '    WHEN type_name=''FLOAT'' '+
         '      OR type_name=''DOUBLE PRECISION'' '+
         '    THEN 15 '+
         '    WHEN type_name=''DATE'' '+
         '    THEN 10 '+
         '    WHEN type_name=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
         '    THEN 9+scale '+
         '    WHEN type_name=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
         '    THEN 20+scale '+
         '    WHEN type_name=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
         '    THEN 15+scale  '+
         '    WHEN type_name=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
         '    THEN 26+scale '+
         '    WHEN type_name=''BINARY LARGE OBJECT'' '+
         '    THEN width '+
         '    WHEN type_name=''CHARACTER LARGE OBJECT'' '+
         '    THEN width '+
         //todo etc.
         '  END AS COLUMN_PRECISION, '+
         '  CASE '+
         '    WHEN type_name=''DATE'' '+
         '      OR type_name=''TIME'' '+
         '      OR type_name=''TIMESTAMP'' '+
         '      OR type_name=''TIME WITH TIME ZONE'' '+
         '      OR type_name=''TIMESTAMP WITH TIME ZONE'' '+
         '    THEN scale '+
         '    WHEN type_name=''NUMERIC'' '+
         '      OR type_name=''DECIMAL'' '+
         '      OR type_name=''SMALLINT'' '+
         '      OR type_name=''INTEGER'' '+
         '    THEN scale '+
         '  ELSE NULL '+
         '  END AS COLUMN_SCALE, '+
         '  width AS COLUMN_LENGTH, '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                    //Note: outer reference to sysTable...}
         '    WHEN EXISTS (SELECT 1 FROM CATALOG_DEFINITION_SCHEMA.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN 0 '+
         '  ELSE '+
         '    1 '+
         '  END AS COLUMN_NULLABLE '+
         'FROM '+
//not optimised to use indexes yet, so takes over 1 minute when new!: speed
        '    INFORMATION_SCHEMA.TYPE_INFO natural join'+
        '    CATALOG_DEFINITION_SCHEMA.sysColumn natural join'+
        '    CATALOG_DEFINITION_SCHEMA.sysTable natural join'+
        '    CATALOG_DEFINITION_SCHEMA.sysSchema natural join'+
        '    CATALOG_DEFINITION_SCHEMA.sysCatalog '+
        where+
        'ORDER BY COLUMN_NAME ';
    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getColumns}

function TSQLMetaData.getProcedureParams(ProcName: PChar; ParamName: PChar;
                 out Cursor: ISQLCursor): SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getProcedureParams called %s %s',[hidenil(ProcName),hidenil(ParamName)]),vLow);
  {$ENDIF}

  where:='WHERE specific_schema=CURRENT_SCHEMA '; //'''+schema+''' ';
  if ProcName<>nil then
    where:=where+'AND specific_name '+patternWhere(ProcName); //LIKE '''+ProcName+''' ESCAPE '''+EscapeChar+''' ';

  //(*todo reinstate: for some reason never seemed blank but was...
  if (ParamName<>nil) and (trim(ParamName)<>'') then
    where:=where+'AND PARAMETER_NAME '+patternWhere(ParamName); //LIKE '''+ParamName+''' ESCAPE '''+EscapeChar+''' ';
  //*)

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    //the following CASTs are debug only...
    SQL:='SELECT '+
         'ORDINAL_POSITION AS REC_NO,'+
         'specific_catalog AS CATALOG_NAME,'+
         'specific_schema AS SCHEMA_NAME,'+
         'specific_name AS PROC_NAME,'+
         'PARAMETER_NAME AS PARAM_NAME,'+
         'CAST(CASE PARAMETER_MODE '+
         '  WHEN ''IN'' THEN '+intToStr(ord(paramIN))+
         '  WHEN ''INOUT'' THEN '+intToStr(ord(paramINOUT))+
         '  WHEN ''OUT'' THEN '+intToStr(ord(paramOUT))+
         ' ELSE '+intToStr(ord(paramUNKNOWN))+
         ' END as SMALLINT) AS PARAM_TYPE, '+
         'CAST(CASE DATA_TYPE '+              //todo keep in sync with convertType
         '  WHEN ''CHARACTER'' THEN 1 '+ //todo replace with constants for DBXpress!
         '  WHEN ''NUMERIC'' THEN 8 '+
         '  WHEN ''DECIMAL'' THEN 8 '+
         '  WHEN ''INTEGER'' THEN 6 '+
         '  WHEN ''SMALLINT'' THEN 6 '+
         '  WHEN ''FLOAT'' THEN 7 '+
         '  WHEN ''REAL'' THEN 7 '+
         '  WHEN ''DOUBLE PRECISION'' THEN 7 '+
         '  WHEN ''CHARACTER VARYING'' THEN 1 '+
         '  WHEN ''DATE'' THEN 2 '+ //todo ok?
         '  WHEN ''TIME'' THEN 10 '+ //todo ok?
         '  WHEN ''TIMESTAMP'' THEN 24 '+
         '  WHEN ''TIME WITH TIME ZONE'' THEN 10 '+
         '  WHEN ''TIMESTAMP WITH TIME ZONE'' THEN 24 '+
         '  WHEN ''BINARY LARGE OBJECT'' THEN 0-4 '+
         '  WHEN ''CHARACTER LARGE OBJECT'' THEN 0-1 '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         'END as SMALLINT) AS PARAM_DATATYPE, '+
         'CAST(CASE DATA_TYPE '+
         '  WHEN ''CHARACTER'' THEN 31 '+ //todo replace with constants for DBXpress!
         '  WHEN ''BINARY LARGE OBJECT'' THEN 23 '+ //todo?34 '+
         '  WHEN ''CHARACTER LARGE OBJECT'' THEN 22 '+ //todo?34 '+
         'ELSE 0 '+
         'END as SMALLINT) AS PARAM_SUBTYPE,'+
         'DATA_TYPE AS PARAM_TYPENAME, '+
         'CAST(CASE '+
         '    WHEN DATA_TYPE=''CHARACTER'' '+
         '      OR DATA_TYPE=''CHARACTER VARYING'' '+
         //todo etc.
         '    THEN NUMERIC_PRECISION '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '    THEN NUMERIC_PRECISION '+
         '    WHEN DATA_TYPE=''SMALLINT'' THEN 5 '+
         '    WHEN DATA_TYPE=''INTEGER'' THEN 10 '+
         '    WHEN DATA_TYPE=''REAL'' THEN 7 '+
         '    WHEN DATA_TYPE=''FLOAT'' '+
         '      OR DATA_TYPE=''DOUBLE PRECISION'' '+
         '    THEN 15 '+
         '    WHEN DATA_TYPE=''DATE'' '+
         '    THEN 10 '+
         '    WHEN DATA_TYPE=''TIME'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END '+
         '    THEN 9+NUMERIC_SCALE '+
         '    WHEN DATA_TYPE=''TIMESTAMP'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END '+
         '    THEN 20+NUMERIC_SCALE '+
         '    WHEN DATA_TYPE=''TIME WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END '+
         '    THEN 15+NUMERIC_SCALE  '+
         '    WHEN DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
  //todo!         '    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END '+
         '    THEN 26+NUMERIC_SCALE '+
         '    WHEN DATA_TYPE=''BINARY LARGE OBJECT'' '+
         '    THEN NUMERIC_PRECISION '+
         '    WHEN DATA_TYPE=''CHARACTER LARGE OBJECT'' '+
         '    THEN NUMERIC_PRECISION '+
         //todo etc.
         '  END as INTEGER) AS PARAM_PRECISION, '+
         '  CAST(CASE '+
         '    WHEN DATA_TYPE=''DATE'' '+
         '      OR DATA_TYPE=''TIME'' '+
         '      OR DATA_TYPE=''TIMESTAMP'' '+
         '      OR DATA_TYPE=''TIME WITH TIME ZONE'' '+
         '      OR DATA_TYPE=''TIMESTAMP WITH TIME ZONE'' '+
         '    THEN NUMERIC_SCALE '+
         '    WHEN DATA_TYPE=''NUMERIC'' '+
         '      OR DATA_TYPE=''DECIMAL'' '+
         '      OR DATA_TYPE=''SMALLINT'' '+
         '      OR DATA_TYPE=''INTEGER'' '+
         '    THEN NUMERIC_SCALE '+
         '  ELSE NULL '+
         '  END as SMALLINT) AS PARAM_SCALE, '+
         '  CAST(NUMERIC_PRECISION as INTEGER) AS PARAM_LENGTH, '+
         //todo etc.
         //todo join to type_info to get SQL type...?
         (*todo remove
         '  CASE '+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                    //Note: outer reference to sysTable...}
         '    WHEN EXISTS (SELECT 1 FROM CATALOG_DEFINITION_SCHEMA.sysConstraint WHERE '+{sysTable.}'table_id=sysConstraint.FK_child_table_id AND rule_check=''"''||TRIM(column_name)||''" IS NOT NULL'') THEN 0 '+
         '  ELSE '+
         '    1 '+
         '  END AS COLUMN_NULLABLE '+
         *)
         'CAST(1 as SMALLINT) AS PARAM_NULLABLE '+ //since we can't specify not null or use domains for parameters
         'FROM  '+
         'INFORMATION_SCHEMA.PARAMETERS '+
         where+
         'ORDER BY PARAM_NAME';
    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getProcedureParams}

function TSQLMetaData.getIndices(TableName: PChar; IndexType: LongWord;
                 out Cursor: ISQLCursor): SQLResult; stdcall;
var
  SQL,where:string;
begin
  {$IFDEF DEBUG_LOG}
  log(format('getIndices called %s %d',[hidenil(TableName),IndexType]),vLow);
  {$ENDIF}

  where:='WHERE schema_name=CURRENT_SCHEMA '; //'''+schema+''' ';
  where:=where+'AND PS.schema_id<>1 '; //todo replace 1 with constant for sysCatalog
  if TableName<>nil then
  begin
    //todo make this AND... if schema already being searched for
    where:=where+'AND TABLE_NAME '+patternWhere(TableName); //LIKE '''+TableName+''' ESCAPE '''+EscapeChar+''' ';
  end;

  with TSQLCommand.Create(SQLConnection) do //todo no need to store reference! = anonymous
  begin
    if bitSet(IndexType,5{eSQLPrimaryKey}) or (IndexType=0) then //actually a constraint not a bloody index! todo BITmask to get other index details (although who cares?)
    begin
      SQL:='SELECT '+
         '1 AS REC_NO,'+
       '  PC.catalog_name AS CATALOG_NAME, '+
       '  PS.schema_name AS SCHEMA_NAME, '+
       '  PT.table_name AS TABLE_NAME, '+
       '  constraint_name AS INDEX_NAME, '+ //todo index n/a! but could find one if needed (not guaranteed though & bad!)
       '  constraint_name AS PKEY_NAME, '+
       '  PL.column_name AS COLUMN_NAME, '+
       '  column_sequence AS COLUMN_POSITION, '+
         '4 AS INDEX_TYPE,'+  //eSQLPrimaryKey
         '''a'' AS SORT_ORDER,'+
         ''''' AS FILTER '+
       'FROM '+
       ' catalog_definition_schema.sysCatalog PC, '+
       ' catalog_definition_schema.sysSchema PS, '+
       ' catalog_definition_schema.sysColumn PL, '+
       ' catalog_definition_schema.sysTable PT, '+
       ' (catalog_definition_schema.sysConstraintColumn J natural join '+
       ' catalog_definition_schema.sysConstraint ) '+
       where+
       ' AND parent_or_child_table=''C'' '+
//         AND FK_parent_table_id=0
       ' AND rule_type=1 '+
       ' AND FK_child_table_id=PT.table_id '+
       ' AND PT.schema_id=PS.schema_id '+
       ' AND PS.catalog_id=PC.catalog_id '+
       ' AND J.column_id=PL.column_id '+
       ' AND PL.table_id=PT.table_id '+

       //todo ' AND PC.catalog_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,CatalogName),'CURRENT_CATALOG')+
       //' AND PS.schema_name '+overrideWhere(patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,SchemaName),'CURRENT_SCHEMA')+
       //' AND PT.table_name '+patternWhere(((s.owner as Tdbc).owner as Tenv).odbcVersion,TableName)+
       //todo schema/catalog as well

       'ORDER BY INDEX_NAME, COLUMN_POSITION ';
    end {eSQLPrimaryKey}
    else
    begin
      where:='WHERE 0=1 '; //todo remove: debug
      SQL:='SELECT '+
           '1 AS REC_NO,'+
           ''''' AS CATALOG_NAME,'+
           ''''' AS SCHEMA_NAME,'+
           ''''' AS TABLE_NAME,'+
           ''''' AS INDEX_NAME,'+
           ''''' AS PKEY_NAME,'+
           ''''' AS COLUMN_NAME,'+
           '0 AS COLUMN_POSITION,'+
           '0 AS INDEX_TYPE,'+
           ''''' AS SORT_ORDER,'+
           ''''' AS FILTER '+
           'FROM  '+
           '(VALUES (0)) AS INDEXES '+
           where+
           'ORDER BY TABLE_NAME';
    end;

    result:=executeImmediate(pchar(SQL),Cursor);
  end; {with}
end; {getIndices}

function TSQLMetaData.getErrorMessage(Error: PChar): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('TSQLMetaData.getErrorMessage called',vLow);
  {$ENDIF}

  strLCopy(Error,pchar(errorMessage),length(errorMessage));

  result:=SQL_SUCCESS;
end; {getErrorMessage}

function TSQLMetaData.getErrorMessageLen(out ErrorLen: SmallInt): SQLResult; stdcall;
begin
  {$IFDEF DEBUG_LOG}
  log('TSQLMetaData.getErrorMessageLen called',vLow);
  {$ENDIF}

  ErrorLen:=length(errorMessage);

  result:=SQL_SUCCESS;
end; {getErrorMessageLen}


{$ENDIF}


{$IFNDEF DBEXP_STATIC}
end.
{$ENDIF}


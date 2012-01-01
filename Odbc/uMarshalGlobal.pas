{$IFNDEF DBEXP_STATIC}
unit uMarshalGlobal;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Global common system definitions relating to communications
 shared by client & server

 Note: the se...Text strings are only used by the server (only needed for raw clients/log file?)
       - it is up to the client to map them to the appropriate API codes
       - todo move them=speed/size of ODBC dll
       -todo also: put them into an array for indexed access as per SQL states

 - some are also used for internal error codes, e.g. syntax error
 Note: should not use any other unit (ideally)

 //todo replace Parent with Referenced?
}

interface
{$ENDIF}

{$IFNDEF DBEXP_IMPLEMENTATION}
type
  TsqlDate=record
    year:smallint;
    month:shortint;
    day:shortint;
  end; {TsqlDate}

  TsqlTimezone=record //todo: re-define this to use an hour-minute interval
    sign:shortint;     //-1=negative, +1=positive, 0=no timezone
    hour:shortint;
    minute:shortint;
  end; {TsqlTimezone}

  TsqlTime=record
    hour:shortint;
    minute:shortint;
    second:integer;   //Note: stored normalised as SSFFFFFF where number of Fs=TIME_MAX_SCALE
    scale:shortint;   //Note: used when formatting to dictate how many fractional places to display
  end; {TsqlTime}

  TsqlTimestamp=record
    date:TsqlDate;
    time:TsqlTime;
  end; {TsqlTimestamp}


const
  {CLI error result codes} //todo put into separate unit/dll/res file?
  {General}
  seOk=0;                               seOkText='';
  seFail=1;                             seFailText='General error';
  seNotImplementedYet=500;              seNotImplementedYetText='%s has not been implemented yet';

  seInvalidHandle=1000;                 seInvalidHandleText='Invalid handle';

  {Parser error}
  seSyntax=2000;                        seSyntaxText='Syntax error';

  {Syntax analysis error}
  seSyntaxUnknownColumn=2010;           seSyntaxUnknownColumnText='Unknown column reference %s';
  seSyntaxAmbiguousColumn=2020;         seSyntaxAmbiguousColumnText='Ambiguous column reference %s';
  seSyntaxLookupFailed=2030;            seSyntaxLookupFailedText='Failed looking up %s';
  sePrivilegeFailed=2040;               sePrivilegeFailedText='Not privileged %s';
  seSyntaxUnknownTable=2050;            seSyntaxUnknownTableText='Unknown table or view reference %s';
  seSyntaxUnknownSchema=2060;           seSyntaxUnknownSchemaText='Unknown schema reference %s';
  seSyntaxInvalidSchema=2065;           seSyntaxInvalidSchemaText='Invalid schema reference here %s';
  seSyntaxUnknownAuth=2070;             seSyntaxUnknownAuthText='Unknown authorisation reference %s';
  seSyntaxUnknownDomain=2080;           seSyntaxUnknownDomainText='Unknown domain reference %s';
  seSyntaxUnknownTransaction=2090;      seSyntaxUnknownTransactionText='Unknown transaction reference %d';
  seSyntaxUnknownRoutine=2100;          seSyntaxUnknownRoutineText='Unknown procedure or function reference %s';
  seSyntaxUnknownCursor=2110;           seSyntaxUnknownCursorText='Unknown cursor reference %s';
  seSyntaxUnknownSequence=2120;         seSyntaxUnknownSequenceText='Unknown sequence reference %s';
  seSyntaxUnknownConstraint=2130;       seSyntaxUnknownConstraintText='Unknown constraint reference %s';
  seSyntaxUnknownConstraintForThisTable=2135; seSyntaxUnknownConstraintForThisTableText='Constraint reference %s is not for this table';
  seSyntaxInvalidJoin=2150;             seSyntaxInvalidJoinText='This join type currently requires an equi-join, e.g. a USING clause';


  {Syntax not found until runtime}
  seSyntaxInvalidComparison=2400;       seSyntaxInvalidComparisonText='Invalid comparison';
  seSyntaxInvalidSetFunction=2410;      seSyntaxInvalidSetFunctionText='Set function is not applicable to this type';
  seSyntaxNotEnoughViewColumns=2500;    seSyntaxNotEnoughViewColumnsText='Degree of derived table does not match column list'; //note: also used for column aliasing outside of views...
  seSyntaxNotDegreeCompatible=2505;     seSyntaxNotDegreeCompatibleText='Degrees of operands are not the same';
  seSyntaxDegreeIsZero=2507;            seSyntaxDegreeIsZeroText='Degrees of operands cannot be zero';
  seSyntaxInvalidConstraint=2510;       seSyntaxInvalidConstraintText='Invalid constraint type'; //initially relates to domains, left vague so we can use it elsewhere...
  seSyntaxPrivilegeNotApplicable=2520;  seSyntaxPrivilegeNotApplicableText='Privilege is not applicable to this object';
  sePrivilegeGrantFailed=2530;          sePrivilegeGrantFailedText='Not privileged to grant this privilege to this object';
  sePrivilegeRevokeFailed=2531;         sePrivilegeRevokeFailedText='Not privileged to revoke this privilege from this object';
  sePrivilegeCreateTableFailed=2532;    sePrivilegeCreateTableFailedText='Not privileged to create in this schema'; //todo used for more than just tables...ok? rename if so...
  seSyntaxViewNotAllowed=2540;          seSyntaxViewNotAllowedText='Must reference a base table, not a view';
  seSyntaxNotEnoughChildColumns=2550;   seSyntaxNotEnoughChildColumnsText='Degree of child table reference does not match parent column list';
  seSyntaxMissingParentPrimaryKey=2555; seSyntaxMissingParentPrimaryKeyText='Parent table does not have a primary key to use as default reference column(s)';
  seSyntaxDeferrableParentPrimaryKey=2557; seSyntaxDeferrableParentPrimaryKeyText='Parent table''s primary key cannot be deferrable';
  seSyntaxColumnTypesMustMatch=2560;    seSyntaxColumnTypesMustMatchText='Column %s is not compatible with column %s';
  seSyntaxMatchFullAndPartial=2570;     seSyntaxMatchFullAndPartialText='Cannot specify both full and partial match';
  seSyntaxPKcannotBeNull=2580;          seSyntaxPKcannotBeNullText='Primary key cannot be nullable';
  seSyntaxTableAlreadyExists=2600;      seSyntaxTableAlreadyExistsText='Table or view already exists';
  seSyntaxAuthAlreadyExists=2605;       seSyntaxAuthAlreadyExistsText='User already exists';
  seSyntaxDomainAlreadyExists=2607;     seSyntaxDomainAlreadyExistsText='Domain already exists';
  seSyntaxSchemaAlreadyExists=2610;     seSyntaxSchemaAlreadyExistsText='Schema already exists';
  seSyntaxRoutineAlreadyExists=2615;    seSyntaxRoutineAlreadyExistsText='Procedure or function already exists';
  seSyntaxCursorAlreadyExists=2620;     seSyntaxCursorAlreadyExistsText='Cursor already exists';
  seSyntaxSequenceAlreadyExists=2625;   seSyntaxSequenceAlreadyExistsText='Sequence already exists';
  seSyntaxConstraintAlreadyExists=2630; seSyntaxConstraintAlreadyExistsText='Constraint already exists';
  seSyntaxCatalogAlreadyExists=2635;    seSyntaxCatalogAlreadyExistsText='Catalog already exists';
  seSyntaxDefaultNotAllowed=2650;       seSyntaxDefaultNotAllowedText='DEFAULT keyword is only allowed in insert statements';
  seSyntaxNotEnoughParemeters=2655;     seSyntaxNotEnoughParemetersText='Not enough parameters';
  seSyntaxCursorAlreadyOpen=2700;       seSyntaxCursorAlreadyOpenText='Cursor is already open';
  seSyntaxCursorNotOpen=2705;           seSyntaxCursorNotOpenText='Cursor is not open';


  {...}
  {SQLExecute,SQLFetchScroll,SQLCloseCursor,SQLPutData}
  seNotPrepared=3000;                   seNotPreparedText='Not prepared';

  {SQLFetchScroll}
  seNoResultSet=3100;                   seNoResultSetText='No result-set';
  seDivisionByZero=3110;                seDivisionByZeroText='Division by zero';

  {SQLDescField:SQL_DESC_DATA_POINTER}
  seColumnNotBound=3140;                seColumnNotBoundText='Column not bound, cannot unbind';
  seColumnAlreadyBound=3150;            seColumnAlreadyBoundText='Column already bound, cannot bind';
  {SQLDescField}
  seUnknownFieldId=3160;                seUnknownFieldIdText='Unknown field identifier';

  {SQLGetInfo}
  seUnknownInfoType=3165;               seUnknownInfoTypeText='Information type out of range';

  {SQLPutData}
  seNoMissingParameter=3170;            seNoMissingParameterText='No missing parameter';

  {SQLEndTran}
  seInvalidOption=3180;                 seInvalidOptionText='Invalid option';

  {SQLConnect}
  seUnknownAuth=3200;                   seUnknownAuthText='Unknown user'; //see seSyntaxUnknownAuth
  seUnknownCatalog=3205;                seUnknownCatalogText='Unknown catalog';
  seWrongPassword=3210;                 seWrongPasswordText='Password mismatch';
  seAuthAccessError=3215;               seAuthAccessErrorText='Failed accessing authorisation table - check that a catalog is open';
  seAuthLimitError=3217;                seAuthLimitErrorText='Too many connections';

  {SQLDisconnect}
  seUnknownConnection=3220;             seUnknownConnectionText='Unknown connection';

  {SQLSetConnectAttr}
  seInvalidAttribute=3230;              seInvalidAttributeText='Invalid attribute value';

  {General transaction}
  seInvalidTransactionState=3250;       seInvalidTransactionStateText='Invalid transaction state';

  {SQLCancel/Kill}
  seStmtCancelled=3270;                 seStmtCancelledText='Statement cancelled';
  seStmtKilled=3275;                    seStmtKilledText='Transaction killed';

  {...}
  {Evaluation/'runtime' error}
  seOnlyOneRowExpected=3300;            seOnlyOneRowExpectedText='Sub-query must return only 1 row';
  seConstraintViolated=3310;            seConstraintViolatedText='Integrity constraint violation: %s';
                                          seConstraintViolatedUniqueText='(unique constraint)';
                                          seConstraintViolatedPrimaryText='(primary key constraint)';
                                          seConstraintViolatedFKchildText='(foreign key constraint: referenced row does not exist)';
                                          seConstraintViolatedFKparentText='(foreign key constraint: row is referenced)';
                                          seConstraintViolatedCheckText='(check constraint)';
  seSetConstraintFailed=3315;           seSetConstraintFailedText='Set Constraints failed';
  seConstraintCheckFailed=3320;         seConstraintCheckFailedText='Unexpected integrity constraint check error: %s';  //todo make sound more unexpected

  seUpdateTooLate=3400;                 seUpdateTooLateText='Update rejected - row already modified by another (later/earlier active) transaction'; //todo add row details?
  seDeleteTooLate=3410;                 seDeleteTooLateText='Delete rejected - row already modified by another (later/earlier active) transaction'; //todo add row details?

  seInvalidValue=3450;                  seInvalidValueText='Invalid value'; //todo add column/row details?

  {I think should never be needed, since ODBC client FSM will prevent}
  seNotConnected=3910;                  seNotConnectedText='Not connected';

  {server internals}
  seStmtStartFailed=4000;               seStmtStartFailedText='Sub-transaction start failed';

  {Compound/routines}
  seCompoundFail=4100;                  seCompoundFailText='Routine failed to complete';
  seTooManyVariables=4105;              seTooManyVariablesText='Variable declaration limit has been reached';
  seInvalidOutputParameter=4110;        seInvalidOutputParameterText='Invalid output parameter';
  seCannotDeclareVariableHere=4115;     seCannotDeclareVariableHereText='A variable can only be declared inside a routine';
  seCannotSetVariableHere=4120;         seCannotSetVariableHereText='A variable can only be set inside a routine';
  seCannotLeaveHere=4122;               seCannotLeaveHereText='Leave can only be used inside a routine';
  seCannotIterateHere=4123;             seCannotIterateHereText='Iterate can only be used inside a loop';
  seReturnsNotAllowed=4125;             seReturnsNotAllowedText='A procedure cannot have a returns clause';
  seReturnsRequired=4130;               seReturnsRequiredText='A function must have a returns clause';
  seOutNotAllowed=4135;                 seOutNotAllowedText='A function can only have IN parameters';
  seUnknownLabel=4140;                  seUnknownLabelText='Label could not be found: %s';
  seCaseNotFound=4145;                  seCaseNotFoundText='Case not found for case statement';
  seTooMuchNesting=4150;                seTooMuchNestingText='Routine nesting limit has been reached';

  {Maintenance errors}
  seTargetDatabaseIsAlreadyOpen=5000;   seTargetDatabaseIsAlreadyOpenText='Target catalog is already open';
  seDatabaseIsAlreadyOpen=5010;         seDatabaseIsAlreadyOpenText='Catalog is already open';
  seCannotCloseCurrentDatabase=5020;    seCannotCloseCurrentDatabaseText='Cannot close current catalog';
  seAuthHasSchema=5050;                 seAuthHasSchemaText='User owns schema(s)';
  seSchemaHasTable=5060;                seSchemaHasTableText='Schema owns table(s) or view(s)';
  seSchemaHasRoutine=5070;              seSchemaHasRoutineText='Schema owns routine(s)';
  seSchemaHasDomain=5080;               seSchemaHasDomainText='Schema owns domain(s)';
  seSchemaHasSequence=5090;             seSchemaHasSequenceText='Schema owns sequence(s)';
  seSchemaHasConstraint=5100;           seSchemaHasConstraintText='Schema owns constraint(s)';
  seSchemaIsDefault=5110;               seSchemaIsDefaultText='Schema is the default schema for user(s)';
  seConstraintHasConstraint=5120;       seConstraintHasConstraintText='Constraint has dependent constraint(s)';
  seTableHasConstraint=5130;            seTableHasConstraintText='Table candidate key has dependent constraint(s)';
  seTableConstraintNotAdded=5140;       seTableConstraintNotAddedText='Incompatible table constraint has not been added';
  seCatalogFailedToOpen=5150;           seCatalogFailedToOpenText='Could not access the catalog';
  seCatalogInvalid=5160;                seCatalogInvalidText='Catalog file is invalid';
  seCanOnlyDebugCurrentDatabase=5170;   seCanOnlyDebugCurrentDatabaseText='Can only debug current catalog';
  seCatalogTooOld=5180;                 seCatalogTooOldText='Catalog file was created by an older server version';
  seCatalogTooNew=5190;                 seCatalogTooNewText='Catalog file was created by a newer server version';


  nullterm:char=#0; //used to terminate re-constituted (unmarshalled) strings etc.
                    //note: size could be 2 if using unicode

  CLI_ODBC=1;
  CLI_JDBC=2;
  CLI_DBEXPRESS=3;
  CLI_ADO_NET=4;
  CLI_PYTHON_DBAPI=5;

  DATE_FORMAT='%4.4d-%2.2d-%2.2d';
  DATE_MIN_LENGTH=10;
  DATE_ZERO:TsqlDate=(year:0; month:0; day:0);

  TIME_FORMAT='%2.2d:%2.2d:%*.*f';
  TIME_MIN_LENGTH=8;
  TIME_MAX_SCALE=6; //todo increase to whatever time.seconds can hold, i.e. 9  Note: must adjust sqlTimeToStr 0 padding to suit!
  TIME_ZERO:TsqlTime=(hour:0; minute:0; second:0; scale:0 ); //todo: (sign:0; hour:0; timezone:minute:0)!

  TIMEZONE_FORMAT='%1.1s%2.2d:%2.2d';
  signString:array [-1..+1] of string=('-',' ','+');
  TIMEZONE_LENGTH=6;
  TIMEZONE_ZERO:TsqlTimezone=(sign:0; hour:0; minute:0 ); //i.e. sign=0 => no timezone
  TIMEZONE_UTC:TsqlTimezone=(sign:+1; hour:0; minute:0 ); //i.e. UTC (GMT)

  TIME_MAX_LENGTH=TIME_MIN_LENGTH+TIME_MAX_SCALE+1; {+optional TIMEZONE_LENGTH}

  TIMESTAMP_MIN_LENGTH=DATE_MIN_LENGTH+1+TIME_MIN_LENGTH;
  TIMESTAMP_MAX_LENGTH=DATE_MIN_LENGTH+1+TIME_MAX_LENGTH; {+optional TIMEZONE_LENGTH}

function strToSqlDate(s:string):TsqlDate;
function sqlDateToStr(d:TsqlDate):string;
function normaliseSqlTime(t:TsqlTime;timezone:TsqlTimezone;var dayCarry:shortint):TsqlTime;
function strToSqlTime(localTimezone:TsqlTimezone;s:string;var dayCarry:shortint):TsqlTime;
function sqlTimeToStr(localTimezone:TsqlTimezone;t:TsqlTime;scale:shortint;var dayCarry:shortint):string;
function strToSqlTimestamp(localTimezone:TsqlTimezone;s:string):TsqlTimestamp;
function sqlTimestampToStr(localTimezone:TsqlTimezone;ts:TsqlTimestamp;scale:shortint):string;

{$ENDIF}

{$IFNDEF DBEXP_STATIC}
implementation

uses sysUtils, Math {for power};
{$ENDIF}

{$IFNDEF DBEXP_INTERFACE}
function IsLeapYear(year:smallint):Boolean;
begin
  Result := (Year mod 4 = 0) 	{ years divisible by 4 are... }
    and ((Year mod 100 <> 0)	{ ...except century years... }
    or (Year mod 400 = 0));	{ ...unless it's divisible by 400 }
end;
function DaysInMonth(year:smallint;month:shortint):Integer;
const
  DaysPerMonth: array[1..12] of Integer =
    (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);	{ usual numbers of days }
begin
  Result := DaysPerMonth[month];	{ normally, just return number }
  if (Month = 2) and IsLeapYear(year) then Inc(Result);	{ plus 1 in leap February }
end;

function strToSqlDate(s:string):TsqlDate;
{Note: this inverts DATE_FORMAT

 Raises an exception if conversion fails
 If s=empty, returns DATE_ZERO = invalid
}
begin
  if s='' then
  begin
    result:=DATE_ZERO;
    exit;
  end;

  result.year:=strToInt(copy(s,1,4));
  result.month:=strToInt(copy(s,6,2));
  result.day:=strToInt(copy(s,9,2));
  {Check this is a valid date}
  if (result.year<1) or (result.year>9999) then raise EConvertError.create('Invalid year');
  if (result.month<1) or (result.month>12) then raise EConvertError.create('Invalid month');
  if (result.day<1) or (result.day>31) then raise EConvertError.create('Invalid day');
  if result.month in [2,4,6,9,11] then if result.day>30 then raise EConvertError.create('Invalid day');
  if result.month=2 then
    if (result.year mod 4 = 0)           //years divisible by 4 are...
      and ((result.year mod 100 <> 0)    //...except century years...
      or (result.year mod 400 = 0)) then //...unless it's divisible by 400
    begin
      if result.day>29 then raise EConvertError.create('Invalid day');
    end
    else
    begin
      if result.day>28 then raise EConvertError.create('Invalid day');
    end;
end; {strToSqlDate}

//todo apply this everywhere DATE_FORMAT used to be used direct!!!
function sqlDateToStr(d:TsqlDate):string;
begin
  result:=format(DATE_FORMAT,[d.year,d.month,d.day])
end; {sqlDateToStr}

//sqlDateToStr = use DATE_FORMAT

function normaliseSqlTime(t:TsqlTime;timezone:TsqlTimezone;var dayCarry:shortint):TsqlTime;
{

 OUT:    dayCarry = -1 underflow to previous date (caller to adjust)
                    +1 overflow to next date (caller to adjust)
                    0  no carry

 Normalise the time to UTC by adjusting it by timezone
 Actually this routine returns (t - timezone)
}
begin
  result:=t;
  dayCarry:=0;

  {Flip so we can just subtract}
  if timezone.sign=-1 then
  begin
    timezone.hour:=-timezone.hour;
    timezone.minute:=-timezone.minute;
  end;

  {Minutes}
  if timezone.minute<>0 then
  begin
    result.minute:=result.minute-timezone.minute;
    if result.minute<0 then begin result.hour:=result.hour-1; result.minute:=60+result.minute end; //underflow
    if result.minute>=60 then begin result.hour:=result.hour+1; result.minute:=result.minute-60 end; //overflow
  end;

  {Hours}
  if timezone.hour<>0 then
  begin
    result.hour:=result.hour-timezone.hour;
    if result.hour<0 then begin dayCarry:=-1; result.hour:=24+result.hour end; //underflow
    if result.hour>=24 then begin dayCarry:=+1; result.hour:=result.hour-24 end; //overflow
  end;
end; {normaliseSqlTime}

function strToSqlTime(localTimezone:TsqlTimezone;s:string;var dayCarry:shortint):TsqlTime;
{
 IN      : localTimezone   -ve/+ve = adjust by local timezone or specified timezone
                           0       = don't adjust by local timezone, but may adjust if explicitly specified

 OUT:    dayCarry = -1 underflow to previous date (caller to adjust)
                    +1 overflow to next date (caller to adjust)
                    0  no carry

 Returns time with seconds of scale as specified by . position
 Seconds are stored normalised, i.e. TIME_MAX_SCALE digit integer, e.g. SSFFFFFF, so 3.14 (6) => 03140000
 Time is adjusted to UTC by specified timezone offset/local timezone

 Raises an exception if conversion fails
 If s=empty, returns TIME_ZERO = invalid
}
var
  cPos:integer;
  sec:double;
begin
  dayCarry:=0;

  if s='' then
  begin
    result:=TIME_ZERO;
    exit;
  end;

  result.hour:=strToInt(copy(s,1,2));
  result.minute:=strToInt(copy(s,4,2));
  cPos:=pos(signString[-1],s);
  if cPos=0 then
    cPos:=pos(signString[+1],s);
  if cPos=0 then cPos:=length(s)+1;
  sec:=strToFloat(copy(s,7,cPos-7)); //todo def=0? to allow just HH:MM but not according to spec.(?)
  {Adjust the value for storage} //todo check for second out of range here?
  if pos('.',s)>0 then
    result.scale:=(cPos-pos('.',s))-1
  else
    result.scale:=0;
  {Normalise to ease later comparison and hashing}
  result.second:=round(sec*power(10,TIME_MAX_SCALE)); //i.e. shift TIME_MAX_SCALE decimal places to the left //todo replace trunc with round everywhere, else errors e.g. trunc(double:1312) -> 1311! //what about int()?

  {Check this is a valid time}
  if (result.hour<0) or (result.hour>23) then raise EConvertError.create('Invalid hour');
  if (result.minute<0) or (result.minute>59) then raise EConvertError.create('Invalid minute');
  //todo better? if (result.second<1) or (result.second>62) then raise EConvertError.create('Invalid second');
  if (sec<0) or (sec>61999999) then raise EConvertError.create('Invalid second');

  {If a timezone is specified, override the local one}
  if copy(s,cPos,1)=signString[-1] then localTimezone.sign:=-1;
  if copy(s,cPos,1)=signString[+1] then localTimezone.sign:=+1;
  if (copy(s,cPos,1)=signString[-1]) or (copy(s,cPos,1)=signString[+1]) then
  begin
    localTimezone.hour:=strToInt(copy(s,cPos+1,2));
    if (localTimezone.hour<0) or (localTimezone.hour>13) then raise EConvertError.create('Invalid hour');
    localTimezone.minute:=strToInt(copy(s,cPos+4,2));
    if (localTimezone.minute<0) or (localTimezone.minute>59) then raise EConvertError.create('Invalid minute');
  end;

  {Adjust by a timezone, if we are allowed}
  if localTimezone.sign<>0 then
  begin
    {Normalise to UTC}
    result:=normaliseSqlTime(result,localTimezone,dayCarry);
  end;
end; {strToSqlTime}

function sqlTimeToStr(localTimezone:TsqlTimezone;t:TsqlTime;scale:shortint;var dayCarry:shortint):string;
{
 IN      : localTimezone   -ve/+ve = adjust by local timezone or specified timezone
                           0       = don't adjust by local timezone, but may adjust if explicitly specified

 OUT:    dayCarry = -1 underflow to previous date (caller to adjust)
                    +1 overflow to next date (caller to adjust)
                    0  no carry

 Returns time with seconds with fractions formatted to scale (i.e. this routine returns a fixed format string)
 Time is adjusted from UTC to local timezone

 Assumes t.scale is >=0 else this is reset to 0 (should never happen)
}
var
  sec:double;
begin
  if t.scale<0 then t.scale:=0; //todo assertion! -ve's cause format to loop forever! (was cause by scale not var param bug: fixed but retain this assertion to avoid wierd crash)

  dayCarry:=0;

  {Denormalise seconds}
  sec:=t.second/power(10,TIME_MAX_SCALE); //i.e. shift TIME_MAX_SCALE decimal places to the right

  {Adjust the time to the local timezone, if specified}
  if localTimezone.sign<>0 then
  begin
    {Flip to reverse arithmetic}
    localTimezone.sign:=-localTimezone.sign;
    t:=normaliseSqlTime(t,localTimezone,dayCarry);
  end;

  {Adjust the scale}
  result:=format(TIME_FORMAT,[t.hour,t.minute,2+t.scale,t.scale,sec]);
  if sec<10 then //pad single digit second
    if scale<>0 then
      insert('0',result,7)
    else
      result[7]:='0';

  if scale<>0 then
  begin
    if pos('.',result)=0 then result:=result+'.'; //fix if fp missing
    if length(result)<(TIME_MIN_LENGTH+scale+1) then
      result:=result+copy('000000'{todo increase if TIME_MAX_SCALE increases},1,(TIME_MIN_LENGTH+scale+1)-length(result))             //pad fraction with 0s
    else
      if length(result)>(TIME_MIN_LENGTH+scale+1) then result:=copy(result,1,(TIME_MIN_LENGTH+scale+1)); //trunc fraction if stored too much //todo better to prevent it being inserted in first place?
  end;

  if localTimezone.sign<>0 then
  begin
    {Flip back to original sign}
    localTimezone.sign:=-localTimezone.sign;
    result:=result+format(TIMEZONE_FORMAT,[signString[localTimezone.sign],localTimezone.hour,localTimezone.minute]);
  end;
end; {sqlTimeToStr}


function strToSqlTimestamp(localTimezone:TsqlTimezone;s:string):TsqlTimestamp;
{
 Returns timestamp with seconds of scale as specified by . position

 Raises an exception if conversion fails

 If s=empty, returns DATE_ZERO + TIME_ZERO
}
var
  dayCarry:shortint;
begin
  result.date:=strToSqlDate(copy(s,1,pos(' ',s)-1));
  result.time:=strToSqlTime(localTimezone,copy(s,pos(' ',s)+1,length(s)),dayCarry);
  if dayCarry<>0 then
  begin //carry overflow to date
    result.date.day:=result.date.day+dayCarry;
    if result.date.day<1 then
    begin
      result.date.month:=result.date.month-1;
      if result.date.month<1 then begin result.date.year:=result.date.year-1; result.date.month:=12; end; //todo if year<1 then raise error!
      result.date.day:=daysInMonth(result.date.year,result.date.month);
    end;
    if result.date.day>daysInMonth(result.date.year,result.date.month) then
    begin
      result.date.month:=result.date.month+1;
      if result.date.month>12 then begin result.date.year:=result.date.year+1; result.date.month:=1; end; //todo if year>9999 then raise error!
      result.date.day:=1;
    end;
  end;
end; {strToSqlTimestamp}

function sqlTimestampToStr(localTimezone:TsqlTimezone;ts:TsqlTimestamp;scale:shortint):string;
{
 scale specifies format of seconds fraction
 i.e. this routine returns a fixed format string
}
var
  sec:double;
  dayCarry:shortint;
begin
  result:=sqlTimeToStr(localTimezone,ts.time,scale,dayCarry);
  if dayCarry<>0 then
  begin //carry overflow to date
    ts.date.day:=ts.date.day+dayCarry;
    if ts.date.day<1 then
    begin
      ts.date.month:=ts.date.month-1;
      if ts.date.month<1 then begin ts.date.year:=ts.date.year-1; ts.date.month:=12; end; //todo if year<1 then raise error!
      ts.date.day:=daysInMonth(ts.date.year,ts.date.month);
    end;
    if ts.date.day>daysInMonth(ts.date.year,ts.date.month) then
    begin
      ts.date.month:=ts.date.month+1;
      if ts.date.month>12 then begin ts.date.year:=ts.date.year+1; ts.date.month:=1; end; //todo if year>9999 then raise error!
      ts.date.day:=1;
    end;
  end;
  result:=sqlDateToStr(ts.date)+' '+result;
end; {sqlTimestampToStr}
{$ENDIF}

{$IFNDEF DBEXP_STATIC}
initialization
  {Set the decimal separator to be as per the standard (i.e. a dot) rather than whatever the locale default might be}
  DecimalSeparator:='.';


end.
{$ENDIF}


unit uVariableSet;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Provides storage for an array of routine parameters and local variables

 This is used by Tstmt to store current instantiated values of variables/parameters
 and also used by Troutine to define parameter definitions

 Note: these classes are based on the TTuple ones: it was originally thought that
       a tuple could be used to hold the parameter/variable details since they were
       so similar, but the TTuple update routines were too restrictive (once only & left-right).
       In the future, we might need to revert back to using the TTuple if more complex
       parameter passing is needed (e.g. arrays/rows).
}

{$DEFINE SAFETY}  //use assertions
                  //Note: Should be no reason to disable these, except maybe small speed increase & small size reduction
                  //      Disabling them would cause more severe crashes (access violations) if an assertion fails
                  //      - at least with them enabled, the server will generate an assertion error message
                  //        and should abort the routine fairly gracefully
                  //      so if they are ever turned off, the code should be thoroughly re-tested and the limits
                  //      stretched to breaking (probably even then only with selective ones disabled)

{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGVARIABLEDETAIL}  //debug variable reading detail

interface

uses uGlobal, uGlobalDef,
  uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for date/time structures}
;

const
  InvalidVarId=0;     //0 is invalid
  PadChar=' ';        //pad character to fill CHAR() fixed length strings

type
  TVarId=word;                       //unique variable id

  TVarDef=record
    {Definition}
    //note: any modifications may affect server & client CLI get/put parameters
    //also: some of the basics are duplicated throughout the syntax tree nodes
    id:TVarId;                          {used to give parameters a natural order for passing}
    name:string;                        //user reference
    dataType:TDataType;                 //variable type
    Width:integer;                      //storage size (0=variable)
    Scale:smallint;                     //precision
    defaultVal:string;                  //default = initial value //todo so no need, remove?
    defaultNull:boolean;                //default null?           //todo "
    variableType:TvariableType;              //variable/parameter type (direction)
  end; {TVarDef}

  TVarData=record //todo could use Variants, but not sure about efficiency/Windows dependency...
    {Mutually exclusive values}
    nullVal:boolean;    //null
    numVal:double;      //number
    strVal:string;      //string
  end; {TVarData}

  TVariableSet=class
    private
      fVarCount:VarRef;                         //no. variables in this set defines size of fVarData & fVarDef arrays
                                                //Note: we assume a spare one for setting variable defaults from
                                                //Note: varref(0-1) = 0 so protect loops with if varCount>0 then...
      fVarData:array [0..MaxVar-1] of TVarData;      //column data pointers //todo keep private - may not always use array
                                                     //todo: doesn't need to be fixed array????? or does it?-access speed!
      procedure SetVarCount(v:VarRef);
    public
      Owner:Tobject;                            //Tstmt owner (nil = Troutine owner for parameter definitions)
      fVarDef:array [0..MaxVar-1] of TVarDef;      //variable definitions //todo make private - may not always use array
                                                   //todo use GetVarDef...

      property VarCount:VarRef read fVarCount write SetVarCount;

      constructor Create(AOwner:Tobject);
      destructor Destroy; override;

      procedure SetVarDef(st:TObject{Tstmt};v:varRef;varId:TVarId;varName:string;varVariableType:TvariableType; 
                          VarDatatype:TDatatype;varWidth:integer;varScale:smallint; 
                          VarDefaultVal:string;VarDefaultNull:boolean); 
                          //todo use a 'VarSetDef' structure to ease future code changes

      function CopyVarDef(vRefL:varRef;vR:TVariableSet;vRefR:varRef):integer;
      function CopyVariableSetDef(vR:TVariableSet):integer;
      function GetVarBasicDef(v:varRef;var varVariableType:TvariableType;var VarDatatype:TDatatype;var varWidth:integer;var varScale:smallint):integer;

      function OrderVarDef:integer;

      function VarIsNull(v:varRef;var null:boolean):integer;
      function GetString(v:varRef;var s:string;var null:boolean):integer;
      function GetInteger(v:varRef;var i:integer;var null:boolean):integer;
      function GetBigInt(v:varRef;var i:int64;var null:boolean):integer;
      function GetDouble(v:varRef;var d:double;var null:boolean):integer;
      function GetComp(v:varRef;var d:double;var null:boolean):integer;
      function GetNumber(v:varRef;var d:double;var null:boolean):integer;
      function GetDate(v:varRef;var d:TsqlDate;var null:boolean):integer;
      function GetTime(v:varRef;var t:TsqlTime;var null:boolean):integer;
      function GetTimestamp(v:varRef;var ts:TsqlTimestamp;var null:boolean):integer;
      function GetBlob(v:varRef;var b:Tblob;var null:boolean):integer;
      {TODO!
      //etc.
      function GetDataPointer(v:varRef;var p:pointer;var len:integer;var null:boolean):integer;

      function clear(tr:TTransaction):integer;
      function clearToNulls(tr:TTransaction):integer;
      }

      function SetNull(v:varRef):integer;
      function SetString(v:varRef;s:pchar;null:boolean):integer;
      function SetInteger(v:varRef;i:integer;null:boolean):integer;
      function SetBigInt(v:varRef;i:int64;null:boolean):integer;
      function SetDouble(v:varRef;d:double;null:boolean):integer;
      function SetComp(v:varRef;d:double;null:boolean):integer;
      function SetNumber(v:varRef;d:double;null:boolean):integer;   //new - todo test!
      function SetDate(v:varRef;d:TsqlDate;null:boolean):integer;
      function SetTime(v:varRef;t:TsqlTime;null:boolean):integer;
      function SetTimestamp(v:varRef;ts:TsqlTimestamp;null:boolean):integer;
      function SetBlob(st:TObject{Tstmt};v:varRef;b:Tblob;null:boolean):integer;
      //todo etc.

      function CopyColDataDeepGetSet(st:TObject{Tstmt};vRefL:varRef;tRo:TObject{TTuple};cRefR:ColRef):integer;
      function CopyVarDataDeepGetSet(st:TObject{Tstmt};vRefL:varRef;tR:TVariableSet;vRefR:varRef):integer;

      {TODO!
      function CompareVar(tran:TTransaction;varL,varR:varRef;vR:TVariableSet;var res:shortint;var null:boolean):integer;
      }
      function FindVar({todo remove find_node:TSyntaxNodePtr;}const varName:string;{todo remove rangeName:string;}outerRef:TObject{==TStmt};var vSet:TVariableSet;var v:varRef;var varId:TvarId):integer;
      {TODO!
      function FindVarFromId(varId:TvarId;var v:varRef):integer;
      }
      function ShowHeading:string;
      function Show(st:TObject{Tstmt}):string;
      function ShowVar(st:TObject{Tstmt};v:varRef):string;
  end; {TVariableSet}

var
  debugVariableSetMax:integer=0;    //todo: move to a debug stat array
  debugVariableSetCount:integer=0;         //todo remove


implementation

uses uLog, uStmt, sysUtils, uTuple, uTransaction, uOS {for getSystemUser}, Math {for power}
;

const
  where='uVariableSet';
  who='';

constructor TVariableSet.Create(AOwner:Tobject);
const routine=':create';
begin
  Owner:=AOwner; //Tstmt (nil=>Troutine)
  fVarCount:=0;

  inc(debugVariableSetCount); //todo remove
  if debugVariableSetCount>debugVariableSetMax then
  begin
    debugVariableSetMax:=debugVariableSetCount;
  end;
  {$IFDEF DEBUG_LOG}
  if debugVariableSetMax=1 then
    log.add(who,where,format('  VariableSet memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}
end; {Create}
destructor TVariableSet.Destroy;
begin
  dec(debugVariableSetCount); //todo remove

  inherited destroy;
end;

procedure TVariableSet.SetVarCount(v:VarRef);
begin
  //todo: maybe if this routine does nothing special we can remove it and
  //      have the user directly set fvarCount - this should be slightly faster
  //      - but no: this is not used any crucial loops?

  {$IFDEF SAFETY}
  //todo log warnings if v=0 or v>maxCol
  if (*todo remove n/a:(v<0) or*) (v>maxVar) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+':setVarCount',format('Variable count %d is beyond limits 0..%d',[v,maxVar]),vAssertion);
    {$ENDIF}
    //continue anyway - this means we'll get a failure sometime later...
    //todo halt here? - no point?
  end;
  {$ENDIF}

  if v<>fVarCount then
  begin
    fVarCount:=v;
  end;
  //todo also reset VarDef's? or at least a flag to ensure they are redefined before attempting to use them...
end; {SetVarCount}

procedure TVariableSet.SetVarDef(st:TObject{Tstmt};v:varRef;varId:TVarId;varName:string;varVariableType:TvariableType; 
                          VarDatatype:TDatatype;varWidth:integer;varScale:smallint; 
                          VarDefaultVal:string;VarDefaultNull:boolean); 
{Initialises a variable definition

 Note: any default value is use to initialise the variable data now (i.e. at declaration time)

 Note: the varId is used to give the variables a left-right ordering that is used by SQL for:
         parameter passing
       so for new routine definitions, increment the varId from left to right.
}
const routine=':SetVarDef';
var
  defaultS:string;
  dayCarry:shortint;
begin
  {$IFDEF SAFETY}
  {Assert v is a valid subscript => fvarCount must be incremented before defining a new variable}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}

  //todo SAFETY:
  //  track last_varRef set for this set and
  //  if v<>last_varRef+1, debugAssertion!

  with fvarDef[v] do
  begin
    id:=varId;
    name:=varName;
    variableType:=varVariableType;
    dataType:=varDatatype;
    width:=varWidth;
    scale:=varScale;
    defaultVal:=varDefaultVal;
    defaultNull:=varDefaultNull;

    {Now set the default} //Note: this code is copied from iterInsert
    fvarData[v].nullVal:=defaultNull;
    if (defaultVal<>'') or not(defaultNull) then
    begin
      defaultS:=defaultVal;
      {Interpret/evaluate default value
       (todo use uEvalCondExpr! & differentiate between CURRENT_TIME and 'CURRENT_TIME' !)
      }
      {Note: following code snippets copied from uEvalCondExpr: keep in sync!}
      if uppercase(defaultS)='CURRENT_USER' then defaultS:=Ttransaction(Tstmt(st).owner).authName;
      if uppercase(defaultS)='SESSION_USER' then defaultS:=Ttransaction(Tstmt(st).owner).authName;
      if uppercase(defaultS)='SYSTEM_USER' then
      begin
        defaultS:=Ttransaction(Tstmt(st).owner).authName;
        getSystemUser((st as Tstmt),defaultS);
      end;
      //todo: use scale from target column!
      if uppercase(defaultS)='CURRENT_CATALOG' then defaultS:=Ttransaction(Tstmt(st).owner).catalogName;
      if uppercase(defaultS)='CURRENT_SCHEMA' then defaultS:=Ttransaction(Tstmt(st).owner).schemaName;
      if uppercase(defaultS)='CURRENT_DATE' then defaultS:=sqlDateToStr(Ttransaction(Tstmt(st).owner).currentDate);
      if uppercase(defaultS)='CURRENT_TIME' then defaultS:=sqlTimeToStr(TIMEZONE_ZERO,Ttransaction(Tstmt(st).owner).currentTime,0,dayCarry);
      if uppercase(defaultS)='CURRENT_TIMESTAMP' then defaultS:=sqlTimestampToStr(TIMEZONE_ZERO,Ttransaction(Tstmt(st).owner).currentTimestamp,0);

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add((st as TStmt).who,where+routine,format('setting default value to %s',[defaultS]),vDebugLow);
      {$ENDIF}
      {$ENDIF}

      {Convert (cast) & return result}
      if fvarCount<=MaxVar-1 then
      begin
        {Load a spare variable slot with out default string to getSet it properly}
        inc(fvarCount); //needed to avoid Get assertions
        try
          fvarDef[fvarCount-1].dataType:=ctVarChar;
          //todo any need? fvarDef[fvarCount{out of bounds}].width:=0;
          fvarData[fvarCount-1].nullVal:=false;
          fvarData[fvarCount-1].strVal:=defaultS;

          if CopyVarDataDeepGetSet(st,v,self,fvarCount-1)<>ok then
          begin //should never happen  todo!: if we pre-check the default type compatibility during table creation!
            //todo how do we tell the user from here that their default is nonesense? stmt.addError(seInvalidValue,format(seInvalidValueText,[nil]));
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,format('Variable %d default %s is invalid for its type',[v,defaultS]),vAssertion);
            {$ENDIF}
            exit; //abort the operation
          end;
        finally
          dec(fvarCount); //remove our temporary variable
        end; {try}
      end;
      //todo else no spare room for use to set default from... todo inform user at least & default to null?
      //todo: or else always keep 1 slot spare?
      //todo: actually, it would all be ok if the default was null
    end;
    //todo else varData[].nullVal:=true????

  end; {with}
end; {SetVarDef}

function TVariableSet.CopyVarDef(vRefL:varRef;vR:TVariableSet;vRefR:varRef):integer;
{Initialises a variable definition from another variableSet variable
 IN:         vRefL               this variableSet variable to set
             vR                  the source variableSet
             vRefR               the source variableSet variable
 RETURNS:    ok, or fail
}
const routine=':CopyVarDef';
begin
  result:=fail;
  {$IFDEF SAFETY}
  {Assert vRefL is a valid subscript => fvarCount must be incremented before defining a new variable}
  if (vRefL>fvarCount-1) (*todo remove n/a:or (vRefL<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefL,fvarCount]),vAssertion);
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert vRefR is a valid subscript => fvarCount must be incremented before defining a new variable}
  if (vRefR>vR.fvarCount-1) (*todo remove n/a:or (vRefR<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefR,vR.fvarCount]),vAssertion);
    {$ENDIF}
    //continue anyway, otherwise the results will be worse later down the line...
    //todo should really exit here- need result code, i.e. make this a function!
  end;
  {$ENDIF}

  with fvarDef[vRefL] do
  begin
    id:=vR.fvarDef[vRefR].id;
    name:=vR.fvarDef[vRefR].name;
    variableType:=vR.fvarDef[vRefR].variabletype;
    dataType:=vR.fvarDef[vRefR].datatype;
    width:=vR.fvarDef[vRefR].Width;
    scale:=vR.fvarDef[vRefR].Scale;
    defaultVal:=vR.fvarDef[vRefR].defaultVal;
    defaultNull:=vR.fvarDef[vRefR].defaultNull;
  end; {with}
  result:=ok;
end; {CopyVarDef}

function TVariableSet.CopyVariableSetDef(vR:TVariableSet):integer;
{Initialises all variable definitions from another variableSet
 IN:         vR                  the source variableSet
 RETURNS:    ok, or fail

 Note:
   also sets the varCount
   and retains original's varId's

   does not copy (or set) data values
    - so caller will probably need to call clear afterwards

 Assumes:
   source variableSet is defined
}
const routine=':CopyVariableSetDef';
var
  i:varRef;
begin
  result:=fail;

  {Define this set from source set}
  varCount:=vR.varCount;
  if varCount>0 then
    for i:=0 to vR.varCount-1 do
    begin
      result:=CopyVarDef(i,vR,i);
      if result<>ok then exit; //abort
    end;
end; {CopyVariableSetDef}

function TVariableSet.GetVarBasicDef(v:varRef;var varVariableType:TvariableType;var VarDatatype:TDatatype;var varWidth:integer;var varScale:smallint):integer;
{Returns basic variable definition info
}
const routine=':GetVarBasicDef';
begin
  result:=ok;
  {$IFDEF SAFETY}
  {Assert v is a valid subscript}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit; //abort
  end;
  {$ENDIF}

  with fvarDef[v] do
  begin
    varVariableType:=variableType;
    varDatatype:=dataType;
    varWidth:=width;
    varScale:=scale;
  end; {with}
end; {GetVarBasicDef}


{... todo...}

function TVariableSet.OrderVarDef:integer;
{Re-orders all variable definitions (and any data pointers) in Id order
 This is needed to give an original parameter passing order:

 And because the system catalog heap-files don't (currently) retain the ordering
 //todo may be no need for this once we have system catalog indexes...?

 RETURNS:    ok, or fail

 Note:
   this also copies corresponding data arrays
   but this routine is designed to be called immediately after definition, so they
   should not be needed

 Assumes:
   variableSet is defined
}
const routine=':OrderVarDef';
var
  i:varRef;
  tempVarDef:TVarDef;
  tempVarData:TVarData;
begin
  result:=fail;

  //todo improve - this uses a naff bubble sort - use quick-sort (or originally read using an index/sort!)
  if varCount>0 then
    repeat
      i:=0;
      while (i<varCount-1) do
      begin
        if fvarDef[i].id > fvarDef[i+1].id then
          break; //swap these
        inc(i);
      end;

      if i<>varCount-1 then
      begin //swap needed
        {do the swap}
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d has Id %d and has been bubbled up to ref %d',[i,fvarDef[i].id,i+1]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
        tempvarDef:=fvarDef[i];
        fvarDef[i]:=fvarDef[i+1];
        fvarDef[i+1]:=tempvarDef;
        //todo could probably remove rest - speed - although terrible bugs if ever needed!
        tempVarData:=fVarData[i];
        fVarData[i]:=fVarData[i+1];
        fVarData[i+1]:=tempVarData;
      end;
    until i=varCount-1;
  result:=ok;
end; {OrderVarDef}

{...todo...}

function TVariableSet.VarIsNull(v:varRef;var null:boolean):integer;
{Checks whether the variable is null
 IN       : v           - the var subscript (not the id)
 OUT      : null        - true if null, else false
 RETURNS  : +ve=ok, else fail (& so ignore result)

 Note: currently this test is duplicated in the GetX routines
 - keep in sync!
}
const routine=':VarIsNull';
begin
  result:=ok;
  //todo check var id<>0 =reserved

  //todo - remove safety checks from here - done elsewhere
  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  null:=fvarData[v].nullVal;
end; {VarIsNull}

function TVariableSet.GetString(v:varRef;var s:string;var null:boolean):integer;
{Gets the value for a string variable
 IN       : v             - the var subscript (not the id)
 OUT      : s             - the string value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   fixed length CHAR()s will be padded to their full size
   //todo: is this most effecient way? maybe just modify compare/output routines?
}
const routine=':GetString';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stString]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a string (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    s:=nullShow //todo remove - save time - only when safe!
  else
  begin
    s:=fvarData[v].strVal;

    {Now pad the string if it should be a fixed size}
    if fvarDef[v].dataType in [ctChar,ctBit] then //user-specified fixed size //todo also for numeric etc.
      if length(fvarData[v].strVal)<>fvarDef[v].width then
      begin
        s:=s+stringOfChar(PadChar,fvarDef[v].width-length(fvarData[v].strVal)); //todo: quicker way!
        {$IFDEF DEBUGVARIABLEDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d padded from %d to %d',[v,length(fvarData[v].strVal){todo remove nextCOff-Coff},fvarDef[v].width]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%s"',[s]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetString}

function TVariableSet.GetInteger(v:varRef;var i:integer;var null:boolean):integer;
{Gets the value for a integer variable
 IN       : v             - the var subscript (not the id)
 OUT      : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetInteger';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stInteger,stSmallInt]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not an integer (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    i:=-1{=null!} //todo remove - save time - only when safe!
  else
  begin
    i:=trunc(fvarData[v].numVal);

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%d"',[i]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetInteger}

function TVariableSet.GetBigInt(v:varRef;var i:int64;var null:boolean):integer;
{Gets the value for a big integer variable
 IN       : v             - the var subscript (not the id)
 OUT      : i             - the big integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetBigInt';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stBigInt]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a big integer (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    i:=-1{=null!} //todo remove - save time - only when safe!
  else
  begin
    i:=trunc(fvarData[v].numVal);

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%d"',[i]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetBigInt}

function TVariableSet.GetDouble(v:varRef;var d:double;var null:boolean):integer;
{Gets the value for a double variable
 IN       : v             - the var subscript (not the id)
 OUT      : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetDouble';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stDouble]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a double (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    d:=-1{=null!} //todo remove - save time - only when safe!
  else
  begin
    d:=fvarData[v].numVal;

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%f"',[d]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetDouble}

function TVariableSet.GetComp(v:varRef;var d:double;var null:boolean):integer;
{Gets the value for a comp variable

 Note: this is an attempt to handle and store floating point numbers with
       accuracy. We can't easily handle the assumed-point integer arithmetic (yet),
       so we return a double after adjusting it & reading it as a comp - does this help or sometimes confuse?

 IN       : v             - the var subscript (not the id)
 OUT      : d             - the comp value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetComp';
var
  c:comp;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stComp]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a comp (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    d:=-1{=null!} //todo remove - save time - only when safe!
  else
  begin
    c:=fvarData[v].numVal;

    {Adjust the scale}
    d:=c/power(10,fvarDef[v].scale); //i.e. shift scale decimal places to the right

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%f"',[d]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetComp}

function TVariableSet.GetNumber(v:varRef;var d:double;var null:boolean):integer;
{Gets the value for a comp, double or an integer column as a double
 If the variable is an integer, it will be automatically coerced into returning a double
 If the variable is a comp, it will be automatically coerced into returning a double //todo fix by returning a comp?

 IN       : v             - the var subscript (not the id)
 OUT      : d             - the comp value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetNumber';
var
  c:comp;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
    d:=-1{=null!} //todo remove - save time - only when safe!
  else
  begin
    case DataTypeDef[fvarDef[v].datatype] of
    stDouble: d:=fvarData[v].numVal;
    stInteger,stSmallInt,stBigInt: d:=trunc(fvarData[v].numVal);
    stComp: d:=fvarData[v].numVal; //todo ok?
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Variable ref %d is not a number (%d), not got',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
      {$ELSE}
      ;
      {$ENDIF}
      d:=0;
    end; {case}

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%f"',[d]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetNumber}

function TVariableSet.GetDate(v:varRef;var d:TsqlDate;var null:boolean):integer;
{Gets the value for a date variable
 IN       : v             - the var subscript (not the id)
 OUT      : d             - the date value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetDate';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stDate]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a date (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
  begin
    //todo use DATE_ZERO
    d.year:=-1;{=null!} //todo remove - save time - only when safe!
    d.month:=-1;{=null!} //todo remove - save time - only when safe!
    d.day:=-1;{=null!} //todo remove - save time - only when safe!
    result:=ok;
    exit;
  end
  else
  begin
    d:=strToSqlDate(fvarData[v].strVal);

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%s"',[fvarData[v].strVal]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetDate}

function TVariableSet.GetTime(v:varRef;var t:TsqlTime;var null:boolean):integer;
{Gets the value for a date variable
 IN       : v             - the var subscript (not the id)
 OUT      : t             - the time value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetTime';
var
  dayCarry:shortint;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stTime]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a time (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
  begin
    //todo use DATE_ZERO
    t.hour:=-1;{=null!} //todo remove - save time - only when safe!
    t.minute:=-1;{=null!} //todo remove - save time - only when safe!
    t.second:=-1;{=null!} //todo remove - save time - only when safe!
    t.scale:=0;
    result:=ok;
    exit;
  end
  else
  begin
    t:=strToSqlTime(TIMEZONE_ZERO,fvarData[v].strVal,dayCarry);

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%s"',[fvarData[v].strVal]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetTime}

function TVariableSet.GetTimestamp(v:varRef;var ts:TsqlTimestamp;var null:boolean):integer;
{Gets the value for a timestamp variable
 IN       : v             - the var subscript (not the id)
 OUT      : ts            - the timestamp value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':GetTimestamp';
var
  dayCarry:shortint;
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stTimestamp]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a timestamp (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  null:=fvarData[v].nullVal;
  if null then
  begin
    //todo use DATE_ZERO
    ts.date.year:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.month:=-1;{=null!} //todo remove - save time - only when safe!
    ts.date.day:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.hour:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.minute:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.second:=-1;{=null!} //todo remove - save time - only when safe!
    ts.time.scale:=0;
    (*12/01/02 time no longer has timezone...
    ts.time.timezone.sign:=0; {=null!} //todo remove - save time - only when safe!
    ts.time.timezone.hour:=0; {=null!} //todo remove - save time - only when safe!
    ts.time.timezone.minute:=0; {=null!} //todo remove - save time - only when safe!
    *)
    result:=ok;
    exit;
  end
  else
  begin
    ts:=strToSqlTimestamp(TIMEZONE_ZERO,fvarData[v].strVal);

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('returned "%s"',[fvarData[v].strVal]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {GetTimestamp}

function TVariableSet.GetBlob(v:varRef;var b:Tblob;var null:boolean):integer;
begin
  result:=fail;
  //todo HERE!!
  // just return var[].blobVal
  // - up to setBlob to copy disk/memory bytes into new memory (re)allocation of var[].blobval
end; {GetBlob}
{...todo...}

function TVariableSet.SetNull(v:varRef):integer;
{Sets the value for a null variable (of any type)
 IN       : v           - the var subscript (not the id)
 RETURNS  : +ve=ok, else fail
}
const routine=':SetNull';
begin
  result:=ok;
  //todo check var id<>0 =reserved

  //todo - remove safety checks from here - done elsewhere
  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  fvarData[v].nullVal:=True;
  //todo reset the strVal etc as well? no real need, just tidier but slower...
end; {SetNull}

function TVariableSet.SetString(v:varRef;s:pchar;null:boolean):integer;
{Sets the value for a string variable
 IN       : v             - the var subscript (not the id)
          : s             - the string value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail

 Note:
   we first strip trailing spaces from the string (these will be restored for fixed length CHAR()s)
}
const routine=':SetString';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  {$IFDEF SAFETY}
  if (v>fvarCount-1) (*todo remove n/a:or (v<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stString]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a string (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  fvarData[v].nullVal:=null;
  if not null then
  begin
  {We strip trailing spaces            //todo check: and control characters! - bad!!!!!
   from the end of all strings. Char()s will be read back and padded, varchar()s won't
  }
(*todo insert right-trim routine here!
  s:=pchar(trimRight(string(s)));       //todo: too many casts - speed up!
             doesn't work: loses #0
{$IFDEF DEBUGCOLUMNDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('String trimmed to %d (%s)',[length(s),s]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
{$ENDIF}
*)
    fvarData[v].strVal:=s;

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('stored "%s"',[s]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {SetString}

function TVariableSet.SetInteger(v:varRef;i:integer;null:boolean):integer;
{Sets the value for an integer variable
 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetInteger';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    fvarData[v].numVal:=i;

  result:=ok;
end; {SetInteger}

function TVariableSet.SetBigInt(v:varRef;i:int64;null:boolean):integer;
{Sets the value for a big integer variable
 IN       : v             - the var subscript (not the id)
          : i             - the big integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetBigInt';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    fvarData[v].numVal:=i;

  result:=ok;
end; {SetBigInt}

function TVariableSet.SetDouble(v:varRef;d:double;null:boolean):integer;
{Sets the value for a double variable
 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetDouble';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    fvarData[v].numVal:=d;

  result:=ok;
end; {SetDouble}

function TVariableSet.SetComp(v:varRef;d:double;null:boolean):integer;
{Sets the value for a comp variable

 Note: this is an attempt to handle and store floating point numbers with
       accuracy. We can't easily handle the assumed-point integer arithmetic (yet),
       so we input a double and adjust it & store it as a comp - does this help or sometimes confuse?

 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetComp';
var
  c:comp;
begin
  result:=Fail;

  {Adjust the value for storage}
  c:=d*power(10,fvarDef[v].scale); //i.e. shift scale decimal places to the left

  fvarData[v].nullVal:=null;
  if not null then
    fvarData[v].numVal:=c;

  result:=ok;
end; {SetComp}

function TVariableSet.SetNumber(v:varRef;d:double;null:boolean):integer;   //new - todo test!
{Sets the value for a comp, double or an integer variable
 IN       : v             - the var subscript (not the id)
          : d             - the double value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetNumber';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    case DataTypeDef[fvarDef[v].datatype] of
    stDouble: fvarData[v].numVal:=d;
    stInteger,stSmallInt, stBigInt: fvarData[v].numVal:=trunc(d);
    stComp: fvarData[v].numVal:=d; //todo ok?
    else
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Variable ref %d is not a number (%d), not set',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
      {$ELSE}
      ;
      {$ENDIF}
      fvarData[v].nullVal:=True;
    end; {case}

  result:=ok;
end; {SetNumber}

function TVariableSet.SetDate(v:varRef;d:TsqlDate;null:boolean):integer;
{Sets the value for a date variable
 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetDate';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    fvarData[v].strVal:=sqlDateToStr(d);

  result:=ok;
end; {SetDate}

function TVariableSet.SetTime(v:varRef;t:TsqlTime;null:boolean):integer;
{Sets the value for a time variable
 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetTime';
var
  dayCarry:shortint;
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    (*todo
    if tR.fColDef[cRefR].dataType=ctTimeWithTimezone then
      sv:=sqlTimeToStr(tran.timezone,tmv,tR.fColDef[cRefR].scale,dayCarry)
    else
    *)
      fvarData[v].strVal:=sqlTimeToStr(TIMEZONE_ZERO,t,0{todo tR.fColDef[cRefR].scale},dayCarry);

  result:=ok;
end; {SetTime}

function TVariableSet.SetTimestamp(v:varRef;ts:TsqlTimestamp;null:boolean):integer;
{Sets the value for an integer variable
 IN       : v             - the var subscript (not the id)
          : i             - the integer value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetTimestamp';
begin
  result:=Fail;

  fvarData[v].nullVal:=null;
  if not null then
    (*todo
    if tR.fColDef[cRefR].dataType=ctTimestampWithTimezone then
      fvarData[v].strVal:=sqlTimestampToStr(tran.timezone,tsv,tR.fColDef[cRefR].scale)
    else
    *)
    fvarData[v].strVal:=sqlTimestampToStr(TIMEZONE_ZERO,ts,0{todo tR.fColDef[cRefR].scale});

  result:=ok;
end; {SetTimestamp}

function TVariableSet.SetBlob(st:TObject{Tstmt};v:varRef;b:Tblob;null:boolean):integer;
{Sets the value for a blob variable
 IN       : v             - the var subscript (not the id)
          : b             - the blob value
          : null          - true if null, else false
 RETURNS  : +ve=ok, else fail
}
const routine=':SetBlob';
begin
  result:=Fail;
  //todo check col id<>0 =reserved

  (*todo HERE!!
    todo Hopefully blobs aren't allowed as variables....
         else we need blobReadData & copy routines...
         e.g. if b.inmemory then copy-bytes (easy: reuse TTuple.copyBlobData: if b.rid.sid=InvalidSlotId then...)
              else caller should swizzle first from disk->memory & vice-versa...

  {$IFDEF SAFETY}
  if (v>fvarCount-1) /*todo remove n/a:or (v<0)*/ then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[v,fvarCount]),vAssertion);
    {$ENDIF}
    exit;
  end;
  {$ENDIF}

  //todo ? {$IFDEF SAFETY}
  if not(DataTypeDef[fvarDef[v].datatype] in [stBlob]) then
  begin //todo remove
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is not a blob (%d)',[v,ord(fvarDef[v].datatype)]),vAssertion); //critical
    {$ENDIF}
    exit;
  end;
  //{$ENDIF}

  fvarData[v].nullVal:=null;
  if not null then
  begin
    fvarData[v].blobVal:=b; //todo call tuple independent getBlobData routine...

    {$IFDEF DEBUGVARIABLEDETAIL}
    {$IFDEF DEBUG_LOG}
    //todo log.add(who,where+routine,format('stored "%s"',[s]),vDebugLow);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
  *)
end; {SetBlob}

{...todo...}

function TVariableSet.FindVar({todo remove find_node:TSyntaxNodePtr;}const varName:string;{todo remove rangeName:string;}outerRef:TObject{==TStmt};var vSet:TVariableSet;var v:varRef;var varId:TvarId):integer;
{Finds the variable reference and id given its name
 //todo: in most cases, repeated calls to this should be avoided by remembering the mappings
         - see EvalCondExpr callers...

 IN        //todo remove find_node         the ntColumnRef node to search for (cannot include ntTable,ntSchema,ntCatalog)
           varName           the variable name
                               //todo: if find_node is passed, this should not not be used
                               it could be needed to find columns rather than columnRefs, i.e. where no prefix is permitted
           outerRef          the outer stmt reference (used for scope)
                                 - we search the current variableSet first, if we find no match
                                   then we progress up through the chain of outer stmts' variableSets and search each
                                   of those until we find a match (or there are no outer ones left).
                                   This chain of stmts provides scoping, and each can be thought of as
                                   the 'current context'.
 OUT       vSet              the variableSet reference (may not be self if a match was found in an outer context)
           v                 the variable reference/subscript
           varId             the variable id, InvalidVarId if not found
 RESULT    ok, else fail (use varId for real 'failure to find match')
           -2=ambiguous-variable-ref

 Note:
}
const routine=':FindVar';
var
  i:varRef;
begin
  //todo use hash function!

  {$IFDEF SAFETY}
  if (outerRef<>nil) and not(outerRef is TStmt) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('outerRef %p is not a TStmt',[@outerRef]),vAssertion);
    {$ENDIF}
    result:=fail;
    exit;
  end;
  {$ENDIF}

  result:=ok;

  //todo debugAssert that varName=find_node var name

  i:=0;
  vSet:=self; //default result to this variableSet
  varId:=InvalidVarId;
  while (i<=fvarCount-1) do //todo remove (we may need to check for duplicate names): and (varId=InvalidVarId) do
  begin
    {Match if the variable name matches}
    if CompareText(trimRight(fvarDef[i].name),trimRight(varname))=0 then //todo case! use = function
    begin
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Matched variable reference %s',[varName]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      varId:=fvarDef[i].id;
      v:=i;
      break; //full match - done
    end;
    inc(i);
  end; {while}

  {Do we need to search the outer context?}
  {Note: we don't search outer if we've found a match,
   even though there may be another in the outer context with the
   same name - i.e. we hide the outer layers
   and the variable names are thus given a scope which complies with the SQL standard.
  }
  if (varId=InvalidVarId) and (outerRef<>nil) and assigned(TStmt(outerRef).varSet) then
  begin
    {Recurse into outer context to try and find a match
     i.e. this is a non-local variable}
    result:=TStmt(outerRef).varSet.FindVar({todo remove find_node,}varName,{todo remove rangeName,}
                                               TStmt(outerRef).outer{==TStmt},
                                               vSet,v,varId);
    //todo: maybe if we get a result (varId<>InvalidVarId) then
    //we should flag this sub-stmt as being correlated ?
    // - should already know? / don't care...
  end;
end; {FindVar}

{...todo...}

function TVariableSet.CopyColDataDeepGetSet(st:TObject{Tstmt};vRefL:varRef;tRo:TObject{TTuple};cRefR:ColRef):integer;
{Copies the data from one tuple column and stores in a variableSet
 (This is a deep copy: the bytes are actually moved, not just the column data pointers)
 IN:         tran                the caller transaction - may be needed for local timezone
             vRefL               this variableSet variable to copy to
             tR                  the source tuple
             cRefR               the source tuple column
 RETURNS:    ok, or fail

 Assumes:
   target and source tuples/sets are already defined

 Note:
   if column data is not compatible/coercible then we fail,
   but column definitions don't need to read each other's raw data, as we use Get then Set

   Keep in sync with TTuple.CopyColDataDeepGetSet/Update
}
const routine=':CopyColDataDeepGetSet';
var
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv,bvData:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;

  tR:TTuple;
begin
  result:=fail;

  tR:=(tRo as TTuple); //cast

  {$IFDEF SAFETY}
  {Assert vRefL is a valid subscript => fvarCount must be incremented before copying a variable}
  if (vRefL>fvarCount-1) (*todo remove n/a:or (vRefL<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefL,fvarCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert cRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (cRefR>tR.ColCount-1) (*todo remove n/a:or (cRefR<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is beyond tuple size %d',[cRefR,tR.ColCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {Set these in case we read an integer & try to set a string - i.e. coerce to null}
  //todo need to spot such problems in future as errors or 'implicit' coercions e.g. string->integer
  //todo we can remove these now....
  sv_null:=true;
  iv_null:=true;
  biv_null:=true;
  dv_null:=true;
  dtv_null:=true;
  tmv_null:=true;
  tsv_null:=true;

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?
  {Read the data
   and copy the data by setting the target columns (safer than pointers + block copying)
  }
  case tR.fColDef[cRefR].dataType of
    ctChar,ctVarChar,ctBit,ctVarBit:
    begin
      tR.GetString(cRefR,sv,sv_null);
      case fvarDef[vRefL].dataType of
        ctChar,ctVarChar,ctBit,ctVarBit:
          SetString(vRefL,pchar(sv),sv_null);
        ctInteger,ctSmallInt:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              iv:=strToInt(sv); //todo check range for smallint...
              SetInteger(vRefL,iv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBigInt:
        begin
          if sv_null then
            SetBigInt(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              biv:=strToInt64(sv);
              SetBigInt(vRefL,biv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctFloat:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetDouble(vRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctNumeric,ctDecimal:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetComp(vRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          if sv_null then
            SetDate(vRefL,dtv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              dtv:=strToSqlDate(sv);
              SetDate(vRefL,dtv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          if sv_null then
            SetTime(vRefL,tmv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fvarDef[vRefL].dataType=ctTimeWithTimezone then
                tmv:=strToSqlTime(Ttransaction(Tstmt(st).owner).timezone,sv,dayCarry)
              else
                tmv:=strToSqlTime(TIMEZONE_ZERO,sv,dayCarry);
              SetTime(vRefL,tmv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          if sv_null then
            SetTimestamp(vRefL,tsv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fvarDef[vRefL].dataType=ctTimestampWithTimezone then
                tsv:=strToSqlTimestamp(Ttransaction(Tstmt(st).owner).timezone,sv)
              else
                tsv:=strToSqlTimestamp(TIMEZONE_ZERO,sv);
              SetTimestamp(vRefL,tsv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          if sv_null then
            SetBlob(st,vRefL,bv{todo! use BLOB_ZERO},sv_null) //no need to coerce
          else
          begin
            bv.rid.sid:=0; //i.e. in-memory blob
            bv.rid.pid:=pageId(pchar(sv)); //pass syntax data pointer as blob source in memory
            bv.len:=length(sv);
            SetBlob(st,vRefL,bv,sv_null); //sv_null is always false
          end;
        end; {ctBlob,ctClob}
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctInteger,ctSmallInt:
    begin
      tR.GetInteger(cRefR,iv,iv_null);
      case fvarDef[vRefL].dataType of
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(vRefL,iv,iv_null);
        end;
        ctBigInt:
          SetBigInt(vRefL,iv,iv_null);
        ctFloat:
          SetDouble(vRefL,iv,iv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(vRefL,iv,iv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if iv_null then
            SetString(vRefL,'',iv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(iv);
              SetString(vRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBigInt:
    begin
      tR.GetBigInt(cRefR,biv,biv_null);
      case fvarDef[vRefL].dataType of
        ctBigInt:
          SetBigInt(vRefL,biv,biv_null);
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(vRefL,integer(biv),biv_null);
        end;
        ctFloat:
          SetDouble(vRefL,biv,biv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(vRefL,biv,biv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if biv_null then
            SetString(vRefL,'',biv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(biv);
              SetString(vRefL,pchar(sv),biv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctFloat:
    begin
      tR.GetDouble(cRefR,dv,dv_null);
      case fvarDef[vRefL].dataType of
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(vRefL,dv,dv_null);
        end;
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(vRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(vRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(vRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctNumeric,ctDecimal:
    begin
      tR.GetComp(cRefR,dv,dv_null);
      case fvarDef[vRefL].dataType of
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(vRefL,dv,dv_null); //todo fix/check
        end;
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(vRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Column ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(vRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(vRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctDate:
    begin
      tR.GetDate(cRefR,dtv,dtv_null);
      case fvarDef[vRefL].dataType of
        ctDate:
        begin
          SetDate(vRefL,dtv,dtv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if dtv_null then
            SetString(vRefL,'',dtv_null) //no need to coerce
          else
          begin
            try
              sv:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]);
              SetString(vRefL,pchar(sv),dtv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          //todo tsv.time=ZERO_TIME?
          tsv.date:=dtv;
          SetTimestamp(vRefL,tsv,dtv_null);
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Column ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTime,ctTimeWithTimezone:
    begin
      tR.GetTime(cRefR,tmv,tmv_null);
      case fvarDef[vRefL].dataType of
        ctTime,ctTimeWithTimezone:
        begin
          SetTime(vRefL,tmv,tmv_null);
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          tsv.date:=Ttransaction(Tstmt(st).owner).currentDate; //DATE_ZERO;
          tsv.time:=tmv;
          SetTimestamp(vRefL,tsv,tmv_null);
        end;
        ctDate,
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(vRefL,'',tmv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimeWithTimezone then
                sv:=sqlTimeToStr(Ttransaction(Tstmt(st).owner).timezone,tmv,tR.fColDef[cRefR].scale,dayCarry)
              else
                sv:=sqlTimeToStr(TIMEZONE_ZERO,tmv,tR.fColDef[cRefR].scale,dayCarry);
              SetString(vRefL,pchar(sv),tmv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTimestamp,ctTimestampWithTimezone:
    begin
      tR.GetTimestamp(cRefR,tsv,tsv_null);
      //todo: need to retain time-zone if target has one, not normalise
      case fvarDef[vRefL].dataType of
        ctTimestamp,ctTimestampWithTimezone:
        begin
          SetTimestamp(vRefL,tsv,tsv_null);
        end;
        ctTime,ctTimeWithTimezone:
        begin
          //todo data loss error
          SetTime(vRefL,tsv.time,tsv_null);
        end;
        ctDate:
        begin
          //todo data loss error
          SetDate(vRefL,tsv.date,tsv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(vRefL,'',tsv_null) //no need to coerce
          else
          begin
            try
              if tR.fColDef[cRefR].dataType=ctTimestampWithTimezone then
                sv:=sqlTimestampToStr(Ttransaction(Tstmt(st).owner).timezone,tsv,tR.fColDef[cRefR].scale)
              else
                sv:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,tR.fColDef[cRefR].scale);
              SetString(vRefL,pchar(sv),tsv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing column ref %d type %d to type %d',[vRefL,ord(tR.fColDef[cRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBlob,ctClob:
    begin
      tR.GetBlob(cRefR,bv,bv_null);
      case fvarDef[vRefL].dataType of
        ctBlob,ctClob:
          SetBlob(st,vRefL,bv,bv_null);

        ctChar,ctVarChar: //note: conversion not required by standard CAST for ctBlob
        begin
          if bv_null then
            SetString(vRefL,'',bv_null) //no need to coerce
          else
            (*HERE
            try
              if copyBlobData(st,bv,bvData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                  //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
              begin
                SetString(vRefL,pchar(bvData.rid.pid),bv_null);
              end;
            finally
              freeBlobData(bvData);
            end; {try}
            *)
            SetString(vRefL,'[BLOB]',bv_null); //todo debug remove!!!!!!!!!!!!!
        end;

        //todo convert blob to others? note: not required by standard CAST
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctBlob,ctClob}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Column ref %d is of unknown type %d',[cRefR,ord(tR.fColDef[cRefR].dataType)]),vAssertion); //todo error?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  result:=ok;
end; {CopyColDataDeepGetSet}

function TVariableSet.CopyVarDataDeepGetSet(st:TObject{TStmt};vRefL:varRef;tR:TVariableSet;vRefR:varRef):integer;
{Copies the data from one variableSet and stores in a variableSet
 (This is a deep copy: the bytes are actually moved, not just the data pointers)
 IN:         tran                the caller transaction - may be needed for local timezone
             vRefL               this variableSet variable to copy to
             tR                  the source variableSet
             cRefR               the source variableSet variable
 RETURNS:    ok, or fail

 Assumes:
   target and source sets are already defined

 Note:
   if data is not compatible/coercible then we fail,
   but variable definitions don't need to read each other's raw data, as we use Get then Set

   Keep in sync with CopyColDataDeepGetSet/Update
}
const routine=':CopyVarDataDeepGetSet';
var
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;

begin
  result:=fail;

  {$IFDEF SAFETY}
  {Assert vRefL is a valid subscript => fvarCount must be incremented before copying a variable}
  if (vRefL>fvarCount-1) (*todo remove n/a:or (vRefL<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefL,fvarCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}
  {$IFDEF SAFETY}
  {Assert vRefR is a valid subscript => fcolCount must be incremented before copying a column}
  if (vRefR>tR.varCount-1) (*todo remove n/a:or (vRefR<0)*) then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is beyond set size %d',[vRefR,tR.varCount]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;
  {$ENDIF}

  {Set these in case we read an integer & try to set a string - i.e. coerce to null}
  //todo need to spot such problems in future as errors or 'implicit' coercions e.g. string->integer
  //todo we can remove these now....
  sv_null:=true;
  iv_null:=true;
  biv_null:=true;
  dv_null:=true;
  dtv_null:=true;
  tmv_null:=true;
  tsv_null:=true;
  bv_null:=true;

  //todo: do some conversion/type checking. E.g. EvalChar/NumExpr ?
  {Read the data
   and copy the data by setting the target columns (safer than pointers + block copying)
  }
  case tR.fvarDef[vRefR].dataType of
    ctChar,ctVarChar,ctBit,ctVarBit:
    begin
      tR.GetString(vRefR,sv,sv_null);
      case fvarDef[vRefL].dataType of
        ctChar,ctVarChar,ctBit,ctVarBit:
          SetString(vRefL,pchar(sv),sv_null);
        ctInteger,ctSmallInt:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              iv:=strToInt(sv); //todo check range for smallint...
              SetInteger(vRefL,iv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBigInt:
        begin
          if sv_null then
            SetBigInt(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              biv:=strToInt64(sv);
              SetBigInt(vRefL,biv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctFloat:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetDouble(vRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctNumeric,ctDecimal:
        begin
          if sv_null then
            SetInteger(vRefL,0,sv_null) //no need to coerce
          else
          begin
            try
              dv:=strToFloat(sv);
              SetComp(vRefL,dv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          if sv_null then
            SetDate(vRefL,dtv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              dtv:=strToSqlDate(sv);
              SetDate(vRefL,dtv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          if sv_null then
            SetTime(vRefL,tmv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fvarDef[vRefL].dataType=ctTimeWithTimezone then
                tmv:=strToSqlTime(Ttransaction(Tstmt(st).owner).timezone,sv,dayCarry)
              else
                tmv:=strToSqlTime(TIMEZONE_ZERO,sv,dayCarry);
              SetTime(vRefL,tmv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          if sv_null then
            SetTimestamp(vRefL,tsv{todo! use DATE_ZERO},sv_null) //no need to coerce
          else
          begin
            try
              if fvarDef[vRefL].dataType=ctTimestampWithTimezone then
                tsv:=strToSqlTimestamp(Ttransaction(Tstmt(st).owner).timezone,sv)
              else
                tsv:=strToSqlTimestamp(TIMEZONE_ZERO,sv);
              SetTimestamp(vRefL,tsv,sv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          if sv_null then
            SetBlob(st,vRefL,bv{todo! use BLOB_ZERO},sv_null) //no need to coerce
          else
          begin
            bv.rid.sid:=0; //i.e. in-memory blob
            bv.rid.pid:=pageId(pchar(sv)); //pass syntax data pointer as blob source in memory
            bv.len:=length(sv);
            SetBlob(st,vRefL,bv,sv_null); //sv_null is always false
          end;
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctInteger,ctSmallInt:
    begin
      tR.GetInteger(vRefR,iv,iv_null);
      case fvarDef[vRefL].dataType of
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(vRefL,iv,iv_null);
        end;
        ctBigInt:
          SetBigInt(vRefL,iv,iv_null);
        ctFloat:
          SetDouble(vRefL,iv,iv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(vRefL,iv,iv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if iv_null then
            SetString(vRefL,'',iv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(iv);
              SetString(vRefL,pchar(sv),iv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBigInt:
    begin
      tR.GetBigInt(vRefR,biv,biv_null);
      case fvarDef[vRefL].dataType of
        ctBigInt:
          SetBigInt(vRefL,biv,biv_null);
        ctInteger,ctSmallInt:
        begin
          //todo check/warn if target precision/scale < source
          SetInteger(vRefL,integer(biv),biv_null);
        end;
        ctFloat:
          SetDouble(vRefL,biv,biv_null);
        ctNumeric,ctDecimal:
        begin
          SetComp(vRefL,biv,biv_null);
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if biv_null then
            SetString(vRefL,'',biv_null) //no need to coerce
          else
          begin
            try
              sv:=intToStr(biv);
              SetString(vRefL,pchar(sv),biv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctFloat:
    begin
      tR.GetDouble(vRefR,dv,dv_null);
      case fvarDef[vRefL].dataType of
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(vRefL,dv,dv_null);
        end;
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(vRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Variable ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Variable ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(vRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(vRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctNumeric,ctDecimal:
    begin
      tR.GetComp(vRefR,dv,dv_null);
      case fvarDef[vRefL].dataType of
        ctNumeric,ctDecimal:
        begin
          //todo check/warn if target precision/scale < source
          SetComp(vRefL,dv,dv_null); //todo fix/check
        end;
        ctFloat:
        begin
          //todo check/warn if target precision/scale < source
          SetDouble(vRefL,dv,dv_null);
        end;
        ctInteger,ctSmallInt:
        begin
          SetInteger(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Variable ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctBigInt:
        begin
          SetBigInt(vRefL,trunc(dv),dv_null); //potentially lost data
          {$IFDEF DEBUGCOERCION}
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Variable ref %d has been coerced from type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vWarning);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end;
        ctChar,ctVarChar,ctBit,ctVarBit:
        begin
          if dv_null then
            SetString(vRefL,'',dv_null) //no need to coerce
          else
          begin
            try
              sv:=floatToStr(dv);
              SetString(vRefL,pchar(sv),dv_null)
            except
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctDate:
    begin
      tR.GetDate(vRefR,dtv,dtv_null);
      case fvarDef[vRefL].dataType of
        ctDate:
        begin
          SetDate(vRefL,dtv,dtv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if dtv_null then
            SetString(vRefL,'',dtv_null) //no need to coerce
          else
          begin
            try
              sv:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]);
              SetString(vRefL,pchar(sv),dtv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          //todo tsv.time=ZERO_TIME?
          tsv.date:=dtv;
          SetTimestamp(vRefL,tsv,dtv_null);
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTime,ctTimeWithTimezone:
    begin
      tR.GetTime(vRefR,tmv,tmv_null);
      case fvarDef[vRefL].dataType of
        ctTime,ctTimeWithTimezone:
        begin
          SetTime(vRefL,tmv,tmv_null);
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          tsv.date:=Ttransaction(Tstmt(st).owner).currentDate; //DATE_ZERO;
          tsv.time:=tmv;
          SetTimestamp(vRefL,tsv,tmv_null);
        end;
        ctDate,
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(vRefL,'',tmv_null) //no need to coerce
          else
          begin
            try
              if tR.fvarDef[vRefR].dataType=ctTimeWithTimezone then
                sv:=sqlTimeToStr(Ttransaction(Tstmt(st).owner).timezone,tmv,tR.fvarDef[vRefR].scale,dayCarry)
              else
                sv:=sqlTimeToStr(TIMEZONE_ZERO,tmv,tR.fvarDef[vRefR].scale,dayCarry);
              SetString(vRefL,pchar(sv),tmv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctTimestamp,ctTimestampWithTimezone:
    begin
      tR.GetTimestamp(vRefR,tsv,tsv_null);
      //todo: need to retain time-zone if target has one, not normalise
      case fvarDef[vRefL].dataType of
        ctTimestamp,ctTimestampWithTimezone:
        begin
          SetTimestamp(vRefL,tsv,tsv_null);
        end;
        ctTime,ctTimeWithTimezone:
        begin
          //todo data loss error
          SetTime(vRefL,tsv.time,tsv_null);
        end;
        ctDate:
        begin
          //todo data loss error
          SetDate(vRefL,tsv.date,tsv_null);
        end;
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctChar,ctVarChar:
        begin
          if tmv_null then
            SetString(vRefL,'',tsv_null) //no need to coerce
          else
          begin
            try
              if tR.fvarDef[vRefR].dataType=ctTimestampWithTimezone then
                sv:=sqlTimestampToStr(Ttransaction(Tstmt(st).owner).timezone,tsv,tR.fvarDef[vRefR].scale)
              else
                sv:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,tR.fvarDef[vRefR].scale);
              SetString(vRefL,pchar(sv),tsv_null)
            except //todo can remove: speed
              {$IFDEF DEBUG_LOG}
              log.add(who,where+routine,format('Failed coercing ref %d type %d to type %d',[vRefL,ord(tR.fvarDef[vRefR].dataType),ord(fvarDef[vRefL].dataType)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit;
            end; {try}
          end;
        end;
        ctBlob,ctClob:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ELSE}
        ;
        {$ENDIF}
        exit; //abort
      end; {case}
    end;
    ctBlob,ctClob:
    begin
      tR.GetBlob(vRefR,bv,bv_null);
      case fvarDef[vRefL].dataType of
        ctBlob,ctClob:
          SetBlob(st,vRefL,bv,bv_null);

        ctChar,ctVarChar: //note: conversion not required by standard CAST for ctBlob
        begin
          if bv_null then
            SetString(vRefL,'',bv_null) //no need to coerce
          else
            (*HERE
            try
              if copyBlobData(st,bv,bv2)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                  //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
              begin
                SetString(vRefL,pchar(bv2.rid.pid),bv_null);
              end;
            finally
              freeBlobData(bv2);
            end; {try}
            *)
            SetString(vRefL,'[BLOB]',bv_null); //todo debug remove!!!!!!!!!!!!!
        end;

        //todo convert blob to others? note: not required by standard CAST
        ctNumeric,ctDecimal,
        ctFloat,
        ctInteger,ctSmallInt,
        ctBigInt,
        ctBit,ctVarBit:
        begin
          exit; //incompatible
        end;
        ctDate:
        begin
          exit; //incompatible
        end;
        ctTime,ctTimeWithTimezone:
        begin
          exit; //incompatible
        end;
        ctTimestamp,ctTimestampWithTimezone:
        begin
          exit; //incompatible
        end;
      else
        {$IFDEF DEBUG_LOG}
        log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefL,ord(fvarDef[vRefL].dataType)]),vAssertion); //todo error?
        {$ENDIF}
        exit; //abort
      end; {case}
    end; {ctBlob,ctClob}
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRefR,ord(tR.fvarDef[vRefR].dataType)]),vAssertion); //todo error?
    {$ELSE}
    ;
    {$ENDIF}
    exit; //abort
  end; {case}

  result:=ok;
end; {CopyVarDataDeepGetSet}


{...todo...}

function TVariableSet.ShowHeading:string;
{Debug only
 Returns a display of the whole variable sets headings
}
const
  routine=':ShowHeading';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;

  maxSize=100; //todo increase!
var
  i:varRef;
  size:integer;
  s:string;
  sv:string;
begin
  result:='';
  if fvarCount>0 then
    for i:=0 to fvarCount-1 do
    begin
      sv:=fvarDef[i].name;
      //todo display variableType as well
      size:=fvarDef[i].width;
      if size=0 then
      begin
        if fvarDef[i].datatype in [ctChar,ctVarChar,ctBit,ctVarBit] then
          size:=DefaultStringSize;
        if fvarDef[i].dataType in [ctInteger,ctSmallInt,ctBigInt] then
          size:=DefaultIntegerSize;
      end;
      if fvarDef[i].dataType=ctFloat then
        size:=defaultFloatWidth;
      if fvarDef[i].scale<>0 then size:=size+1; //for d.p.

      if length(sv)>size then size:=length(sv);

      if size>maxSize then size:=maxSize;
      s:=format('%-*.*s',[size,size,sv]);

      result:=result+separator+s;
    end;
end; {showHeading}

function TVariableSet.Show(st:TObject{TStmt}):string;
{Debug only
 Returns a display of the whole variable sets values
}
const
  routine=':Show';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;
  defaultBlobSize=100;

  maxSize=100; //todo increase - keep in sync with showHeading!
var
  i:colRef;
  size,scale:integer;
  s:string;
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv:Tblob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;
begin
  result:='';
  {$IFDEF DEBUG_LOG}
  {$IFDEF DEBUGRID}
  //todo need to move to eval & iterRelation... s:=format('%-*s',[8,format('%4.4d:%3.3d',[(owner as Trelation).dbfile.currentRID.pid,(owner as Trelation).dbfile.currentRID.sid])]);
  //todo need to move to eval & iterRelation... result:=result+separator+s;
  {$ENDIF}
  {$ENDIF}
 if fvarCount>0 then //todo remove this assertion - should be no need here...
  for i:=0 to fvarCount-1 do
  begin
    s:='?';
    //if fvarData[i].dataPtr<>nil then //todo debug:avoid crash if tuple data is not initialised
    begin
      if fvarDef[i].dataType in [ctChar,ctVarChar,ctBit,ctVarBit] then
      begin
        GetString(i,sv,sv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultStringSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not sv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctInteger,ctSmallInt] then
      begin
        GetInteger(i,iv,iv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not iv_null then s:=format('%*d',[size,iv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctBigInt] then
      begin
        GetBigInt(i,biv,biv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not biv_null then s:=format('%*d',[size,biv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctNumeric,ctDecimal] then
      begin
        GetComp(i,dv,dv_null);
        size:=fvarDef[i].width;
        scale:=fvarDef[i].scale;
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*.*f',[size,scale,dv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType=ctFloat then
      begin
        GetDouble(i,dv,dv_null);
        size:=defaultFloatWidth;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        //todo why not? if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*s',[size,format('%g',[dv])]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctDate] then
      begin
        GetDate(i,dtv,dtv_null);
        size:=fvarDef[i].width; //todo DATE_MIN_LENGTH fixed?
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dtv_null then s:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctTime,ctTimeWithTimezone] then
      begin
        GetTime(i,tmv,tmv_null);
        size:=fvarDef[i].width; //todo TIME_MIN_LENGTH + fixed?
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tmv_null then
        begin
          if (fvarDef[i].dataType=ctTimeWithTimezone) and (st<>nil) then
            s:=sqlTimeToStr(Ttransaction(Tstmt(st).owner).timezone,tmv,fvarDef[i].scale,dayCarry)
          else
            s:=sqlTimeToStr(TIMEZONE_ZERO,tmv,fvarDef[i].scale,dayCarry);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctTimestamp,ctTimestampWithTimezone] then
      begin
        GetTimestamp(i,tsv,tsv_null);
        size:=fvarDef[i].width; //todo TIMESTAMP_MIN_LENGTH + fixed?
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tsv_null then
        begin
          if (fvarDef[i].dataType=ctTimestampWithTimezone) and (st<>nil) then
            s:=sqlTimestampToStr(Ttransaction(Tstmt(st).owner).timezone,tsv,fvarDef[i].scale)
          else
            s:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,fvarDef[i].scale);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctBlob,ctClob] then
      begin
        GetBlob(i,bv,bv_null);
        size:=defaultBlobSize;
        if not bv_null then
          (*todo HERE!!
          try
            if copyBlobData(st,bv,bvData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                   //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
            begin
              //todo only double & show as hexits if blob, not clob
              size:=fColDef[i].width*2{double since we output as hexits};
              //todo assert size=bvData size
              if size=0 then size:=defaultBlobSize;
              if length(fColDef[i].name)>size then size:=length(fColDef[i].name);
              if size>maxSize then size:=maxSize;
              sv:='';
              iv:=bv.len; if iv>size then iv:=size;
              for j:=0 to iv-1 do //(size div 2)-1 do
              begin
                sv:=sv+intToHex(ord(pchar(bvData.rid.pid)[j]),2);
              end;
            end;
          finally
            freeBlobData(bvData);
          end; {try}
          *)
          sv:='[BLOB]'; //todo debug remove!!!!!!!!!!!!!
        if not bv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;
    end;

    result:=result+separator+s;
  end;
end; {show}

function TVariableSet.ShowVar(st:TObject{Tstmt};v:varRef):string;
{Debug only
 Returns a display of the whole variable sets values
}
const
  routine=':ShowVar';
  separator='|';
  defaultStringSize=20;
  defaultIntegerSize=8;
  defaultFloatWidth=12;

  maxSize=100; //todo increase - keep in sync with showHeading!
var
  i:colRef;
  size,scale:integer;
  s:string;
  sv:string;
  iv:integer;
  biv:int64;
  dv:double;
  dtv:TsqlDate;
  tmv:TsqlTime;
  tsv:TsqlTimestamp;
  dayCarry:shortint;
  bv:TBlob;
  sv_null,iv_null,biv_null,dv_null,dtv_null,tmv_null,tsv_null,bv_null:boolean;
begin
  result:='';
  {$IFDEF DEBUG_LOG}
  {$IFDEF DEBUGRID}
  //todo need to move to eval & iterRelation... s:=format('%-*s',[8,format('%4.4d:%3.3d',[(owner as Trelation).dbfile.currentRID.pid,(owner as Trelation).dbfile.currentRID.sid])]);
  //todo need to move to eval & iterRelation... result:=result+separator+s;
  {$ENDIF}
  {$ENDIF}
 if fvarCount>0 then //todo remove this assertion - should be no need here...
  begin
    s:='?';

    i:=v;

    //if fvarData[i].dataPtr<>nil then //todo debug:avoid crash if tuple data is not initialised
    begin
      if fvarDef[i].dataType in [ctChar,ctVarChar,ctBit,ctVarBit] then
      begin
        GetString(i,sv,sv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultStringSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not sv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctInteger,ctSmallInt] then
      begin
        GetInteger(i,iv,iv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not iv_null then s:=format('%*d',[size,iv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctBigInt] then
      begin
        GetBigInt(i,biv,biv_null);
        size:=fvarDef[i].width;
        if size=0 then size:=DefaultIntegerSize;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not biv_null then s:=format('%*d',[size,biv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctNumeric,ctDecimal] then
      begin
        GetComp(i,dv,dv_null);
        size:=fvarDef[i].width;
        scale:=fvarDef[i].scale;
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*.*f',[size,scale,dv]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType=ctFloat then
      begin
        GetDouble(i,dv,dv_null);
        size:=defaultFloatWidth;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        //todo why not? if size>maxSize then size:=maxSize;
        if not dv_null then s:=format('%*s',[size,format('%g',[dv])]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctDate] then
      begin
        GetDate(i,dtv,dtv_null);
        size:=fvarDef[i].width; //todo DATE_MIN_LENGTH fixed?
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not dtv_null then s:=format(DATE_FORMAT,[dtv.year,dtv.month,dtv.day]) else s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctTime,ctTimeWithTimezone] then
      begin
        GetTime(i,tmv,tmv_null);
        size:=fvarDef[i].width; //todo TIME_MIN_LENGTH + fixed?
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tmv_null then
        begin
          if (fvarDef[i].dataType=ctTimeWithTimezone) and (st<>nil) then
            s:=sqlTimeToStr(Ttransaction(Tstmt(st).owner).timezone,tmv,fvarDef[i].scale,dayCarry)
          else
            s:=sqlTimeToStr(TIMEZONE_ZERO,tmv,fvarDef[i].scale,dayCarry);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctTimestamp,ctTimestampWithTimezone] then
      begin
        GetTimestamp(i,tsv,tsv_null);
        size:=fvarDef[i].width; //todo TIMESTAMP_MIN_LENGTH + fixed?
        if fvarDef[i].scale<>0 then size:=size+1; //for d.p.
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
        if not tsv_null then
        begin
          if (fvarDef[i].dataType=ctTimestampWithTimezone) and (st<>nil) then
            s:=sqlTimestampToStr(Ttransaction(Tstmt(st).owner).timezone,tsv,fvarDef[i].scale)
          else
            s:=sqlTimestampToStr(TIMEZONE_ZERO,tsv,fvarDef[i].scale);
        end
        else
          s:=format('%*s',[size,nullShow]);
      end;
      if fvarDef[i].dataType in [ctBlob,ctClob] then
      begin
        GetBlob(i,bv,bv_null);
        size:=fvarDef[i].width;
        if length(fvarDef[i].name)>size then size:=length(fvarDef[i].name);
        if size>maxSize then size:=maxSize;
          sv:='[BLOB]'; //todo debug remove!!!!!!!!!!!!!
        if not bv_null then s:=format('%-*s',[size,sv]) else s:=format('%*s',[size,nullShow]);
      end;
    end;

    result:=result+separator+s;
  end;
end; {ShowVar}


end.

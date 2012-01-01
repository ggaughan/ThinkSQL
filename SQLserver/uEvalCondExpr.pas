unit uEvalCondExpr;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}


{Expression Evaluation routines
   1. Conditional expression routine which also requires,
   2. Scalar expression evaluation routine

 Tuple comparision routines (move these into Tuple class)

 All accept a syntax tree node.
}

//{$DEFINE DEBUGDETAIL}
//{$DEFINE DEBUGDETAIL2}   //starting of high level SQL constructs
//{$DEFINE DEBUGDETAIL3}
//{$DEFINE DEBUGDETAIL4}   //introduced for 'complete' routines
//{$DEFINE DEBUGDETAIL5}   //compare tuples: display both
//{$DEFINE DEBUGDETAIL6}   //cascade updates: i.e. read old and new values

interface

uses uGlobal, uTuple, uSyntax, uTransaction, uStmt, uIterator;

type
  TCompareFunc=function(r:shortint):TriLogic;

function EvalScalarExp(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;tuple:TTuple;OutCRef:ColRef;aggregate:Taggregation;useOldValues:boolean):integer;
function CompleteScalarExp(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;

function EvalRowConstructor(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;tuple:TTuple;aggregate:Taggregation;predefined:boolean;useOldValues:boolean):integer;
function CompleteRowConstructor(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
function EvalCondExpr(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;var res:TriLogic;aggregate:Taggregation;useOldValues:boolean):integer;
function CompleteCondExpr(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;

function CompResEQ(r:shortint):TriLogic;
function CompResNEQ(r:shortint):TriLogic;
function CompResGT(r:shortint):TriLogic;
function CompResGTEQ(r:shortint):TriLogic;
function CompResLT(r:shortint):TriLogic;
function CompResLTEQ(r:shortint):TriLogic;

function CompareTuples(st:TStmt;tl,tr:TTuple;compareFunc:TCompareFunc;var res:TriLogic):integer;
function MatchTuples(st:TStmt;tl,tr:TTuple;partial:boolean;full:boolean;var res:TriLogic):integer;

function CompleteSelectItem(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;



implementation

uses ulog, sysUtils, uAlgebra, uOptimiser, uProcessor, uIterGroup {for aggregate finalisation access to groupRowCount},
 uRelation {for access to tuple's owner attribute for privilege checking},
 uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}
 ,uOS {for getSystemUser (was Windows & so had to prefix maxSMALLINT with uGlobal)}
 ,Math {for power},
 uIterMaterialise,
 uIterSyntaxRelation {for checking whether to bypass tuple formatting},
 uVariableSet, uRoutine,
 uGlobalDef {for Tblob}
 ;

const
  where='uEvalCondExpr';
  who=''; 

  {Like wildcard characters}
  LIKE_WILDCARD_MANY='%';
  LIKE_WILDCARD_ONE='_';

var
  AllowMaterialise:boolean=True; //set True when live  - variable to allow switch off for runtime debugging/timing

//////////////////// start/next ////////////////////////////////////////////////
function CompResEQ(r:shortint):TriLogic;
begin
  if r=0 then result:=isTrue else result:=isFalse;
end;
function CompResNEQ(r:shortint):TriLogic;
begin
  if r<>0 then result:=isTrue else result:=isFalse;
end;
function CompResGT(r:shortint):TriLogic;
begin
  if r>0 then result:=isTrue else result:=isFalse;
end;
function CompResGTEQ(r:shortint):TriLogic;
begin
  if r>=0 then result:=isTrue else result:=isFalse;
end;
function CompResLT(r:shortint):TriLogic;
begin
  if r<0 then result:=isTrue else result:=isFalse;
end;
function CompResLTEQ(r:shortint):TriLogic;
begin
  if r<=0 then result:=isTrue else result:=isFalse;
end;

function CompareTuples(st:TStmt;tl,tr:TTuple;compareFunc:TCompareFunc;var res:TriLogic):integer;
{Compare 2 tuples for l <compareFunc> r
}
const routine=':compareTuples';
var
  cl,cr:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=isTrue;
  cl:=0;
  cr:=0;

  if tl.ColCount<>tr.ColCount then res:=isFalse; //done! mismatch column valency

  {$IFDEF DEBUGDETAIL5}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('comparing: %s and %s',[tl.Show,tr.Show]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  {$ENDIF}

  //for each column, until we get a mismatch (or unknown)
  while (res=isTrue) and (cl<tl.ColCount) and (cr<tr.ColCount) do
  begin
    result:=tl.CompareCol(st,cl,cr,tr,resComp,resNull);
    if result<>ok then exit; //abort if compare fails
    if resNull then
      res:=isUnknown
    else
      res:=compareFunc(resComp);
//    {$IFDEF DEBUGDETAIL}
{$IFDEF DEBUG_LOG}
//    log.add(st.who,where+routine,format('compared columns %d and %d = %s',[cl,cr,triToStr(res)]),vDebugLow);
{$ELSE}
;
{$ENDIF}
//    {$ENDIF}
    inc(cl);
    inc(cr);
  end;
end; {CompareTuples}

function CompareTupleNull(tl:TTuple;var res:TriLogic):integer;
{Compare a tuple for IS NULL
 Note: only returns isTrue or isFalse
}
var
  cl:colRef;
  resNull:boolean;
begin
  result:=ok;
  res:=isTrue;
  cl:=0;

  //for each column, until we get a mismatch (or unknown)
  while (res=isTrue) and (cl<tl.ColCount) do
  begin
    result:=tl.ColIsNull(cl,resNull);
    if result<>ok then exit; //abort if compare fails
    if not resNull then
      res:=isFalse;
    inc(cl);
  end;
end; {CompareTupleNull}

function MatchTuples(st:TStmt;tl,tr:TTuple;partial:boolean;full:boolean;var res:TriLogic):integer;
{Match 2 tuples l and r
 Note: only returns isTrue or isFalse

 OUT:         res

 Assumes:
   caller matches if tl has any/all nulls depending on partial/full options
   (including 'if full and t1 is not all non-nulls => false' = short-circuit)
   before calling this routine. i.e. this routine does not check tl for nulls
   but simply checks the non-null components. If the caller does not pre-check,
   then using this routine's result alone may be incorrect.
   The 'tl has nulls and it matters' logic was moved from here to save time
   in match loops, since the tl is constant and can be checked once before the
   loop.
}
const routine=':matchTuples';
var
  cl,cr:colRef;
  resComp:shortint;
  resNull:boolean;
begin
  result:=ok;
  res:=isFalse;

  cl:=0;
  cr:=0;

  {Note: this nested if is based on the matrix in A Guide to SQL 4th ed, pages 245/246
         the Unique option is handled by the caller of this routine
         also, the null-related short-circuitry must be handled by the caller
  }

  if partial then
  begin
    begin
      {if all non nulls in tl = counterpart in tr}
      res:=isTrue; //temporary postulate
      if tr.colCount<tl.colCount then res:=isFalse; //otherwise we'd not compare all non-null parts of tl 
                                                                //I think we should return false if ever these two aren't equal???!!!!!!
      while (res=isTrue) and (cl<tl.ColCount) and (cr<tr.ColCount) do
      begin
        result:=tl.ColIsNull(cl,resNull);
        if result<>ok then exit; //abort if compare fails
        if not resNull then
        begin
          result:=tl.CompareCol(st,cl,cr,tr,resComp,resNull);
          if result<>ok then exit; //abort if compare fails
          if resNull then
            res:=isUnknown  //fail if tr has corresponding null
          else
            res:=CompResEQ(resComp);
        end;
        inc(cl);
        inc(cr);
      end; {while}
      if res<>isTrue then res:=isFalse;
    end
  end
  else
    if full then
    begin
      begin
        begin
          {...and if tl=tr}
          result:=CompareTuples(st,tl,tr,compResEQ,res);
          if result<>ok then exit; //abort if compare fails
          if res<>isTrue then res:=isFalse;
        end;
      end
    end
    else
    begin //neither partial nor full
      begin
        {if tl=tr}
        result:=CompareTuples(st,tl,tr,compResEQ,res);
        if result<>ok then exit; //abort if compare fails
        if res<>isTrue then res:=isFalse;
      end;
    end;

end; {MatchTuples}


function Like(x,y:string; z:char):boolean;
{Perform x LIKE y
 Handles % (LIKE_WILDCARD_MANY) and _ (LIKE_WILDCARD_ONE) pattern matching characters in y
 and if z is specified (i.e. not #0), this is used as an escape character for % and _
}
var
  px,py:integer;
begin
  px:=1; py:=1;
  while ((px<=length(x)) and (py<=length(y))) or ((py<=length(y)) and (y[py]=LIKE_WILDCARD_MANY)) do
  begin
    if y[py]=LIKE_WILDCARD_MANY then
    begin
      inc(py);
      repeat
        if py>length(y) then
          result:=True          //i.e. if last y char is % - match all rest of x
        else
          result:=Like(copy(x,px,length(x)),copy(y,py,length(y)),z);
        if result then exit;
        inc(px);
      until px>length(x);
      result:=false;
      exit;
    end;
    if y[py]<>LIKE_WILDCARD_ONE then
    begin
      if y[py]=z then
        inc(py);
      if upcase(x[px])<>upcase(y[py]) then //todo use common case-(in)sensitive routine!
        break;
    end;
    inc(px);
    inc(py);
  end;
  result:=not( (px<=length(x)) or (py<=length(y)) );
end; {Like}

function CompareLike(st:TStmt;tl,tr:TTuple;var res:TriLogic):integer;
{Compare 2 tuple columns for l <like> r
 IN:    st      the stmt (in case blob retrieval needs to hit disk)
        tl      the left tuple
        tr      the right tuple

 OUT:   res     true, false or unknown

 RETURNS: ok, else fail

 Note column 0 of both tuples is used
 Assumes column 0 are both strings/blobs

}
const routine=':CompareLike';
var
  ls,rs:string;
  b,bData:Tblob;
  lsnull,rsnull:boolean;
  EscapeChar:char;
begin
  result:=ok;
  res:=isUnknown;

  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(who,where+routine,format('%s',[tl.Show(nil)]),vDebugLow);
  log.add(who,where+routine,format('%s',[tr.Show(nil)]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  if tl.fColDef[0].dataType in [ctBlob,ctClob] then
  begin
    tl.GetBlob(0,b,lsnull);
    if not lsnull then
      try
        if tl.copyBlobData(st,b,bData)>=ok then
                                             //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
        begin
          ls:='';
          setLength(ls,b.len);
          strMove(pchar(ls),pchar(bData.rid.pid),b.len);
        end;
      finally
        tl.freeBlobData(bData);
      end; {try}
  end
  else
    result:=tl.GetString(0,ls,lsnull); //store result
  if result<>ok then exit;
  if lsnull then exit; //return unknown

  if tr.fColDef[0].dataType in [ctBlob,ctClob] then
  begin
    tr.GetBlob(0,b,rsnull);
    if not rsnull then
      try
        if tr.copyBlobData(st,b,bData)>=ok then 
                                             //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
        begin
          rs:='';
          setLength(rs,b.len);
          strMove(pchar(rs),pchar(bData.rid.pid),b.len);
        end;
      finally
        tr.freeBlobData(bData);
      end; {try}
  end
  else
    result:=tr.GetString(0,rs,rsnull); //store result
  if result<>ok then exit;
  if rsnull then exit; //return unknown

  EscapeChar:=#0; 
  if Like(ls,rs,EscapeChar) then res:=isTrue else res:=isFalse;
end; {CompareLike}

{Note: single expression eval routine: was one for numeric & one for character}
function EvalScalarExp(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;tuple:TTuple;OutCRef:ColRef;aggregate:Taggregation;useOldValues:boolean):integer;
{Evaluate a scalar expression (character/numeric etc.) and return the result in the specified
 tuple column

 IN:
          st              the statement
          iter            the current iterator (links to iTuple) to take column values from
          snode           the syntax node of the child of the ...Exp node
          OutCRef         the column reference in the output tuple to update
                          (must be pre-defined unless we reference a column)
          aggregate       todo! True=recurse into aggregate function expressions to calculate them
                            (used in grouping calculation)
                          False=use the value stored against the aggregate function and don't recurse
                            (used in projection after a grouping)
 OUT:     tuple           a formatted tuple with data in its read-buffer
                          Note: tuple must be created by caller

 RESULT:  ok,
          -2 - divide by zero (Note: error is added to stmt)
          -3 - getSystemUser function failed
          -4 - param could not be converted to a number
          -5 - function calls nested too deeply
          else fail

 Note:
   the data is appended via Set routines, so must be clear beforehand
   (this is for speed - no need to expand/insert)

   //todo check these notes are still valid...
   the predefined output column's definition may be changed, e.g.
   if the caller specifies it as ctFloat, and we read a ctInteger column then
   we return the output coerced as a ctInteger column.

   this routine doesn't complete the output tuple, the caller must do this
   (i.e. preInsert to prepare buffer)

   if a column is referenced, this may change the output tuple column definition
   i.e. this routine may does not guarantee the return of a numeric_exp

   tuple column's may point to data pinned by t (to save time & space)
   (if this cannot be done, the column copy routines will need to Get
   values into local variables and then Set them in the new column)

 todo if this works:
   use instead of evalChar/NumExp everywhere - need extra analysis steps for cond subtrees etc. - DONE
   maybe get rid of ntNumericExp etc. - no need? - should be easy since this routine doesn't use it!!!!
   rename to evalScalarExp? DONE


   ntDefault will leave the datatype as ctUnknown (set from yacc) so iterInsert can act on it

   ntUserFunction could initiate a sub-routine call

 Note:
   this routine will be a bottleneck. Move anything we can from here into the
   completeScalarExp routine.
}
const
  routine=':EvalScalarExp';
  seInternal='sys/se'; //temp column name
var
  n:TSyntaxNodePtr;
  s,s2:string;
  snull,s2null:boolean;
  v,v2:double;
  vnull,v2null:boolean;
  vwidth:integer;
  vscale:smallint;
  tempInt,tempInt2:integer;
  dt,dt2:TsqlDate;
  tm,tm2:TsqlTime;
  ts,ts2:TsqlTimestamp;
  dayCarry:shortint;
  dtnull,dt2null:boolean; //shared for all datetime types
  b,bdata:Tblob;
  bnull:boolean;
  compareRes:shortint;
  cRef:ColRef;
  tempTuple,tempTuple2,cTuple:TTuple;

  vSet:TvariableSet;
  vRef:VarRef;

  {for generator owner/lookup}
  catalog_Id:TcatalogId;
  schema_Id:TschemaId;
  auth_id:TauthId;
  sysGeneratorR:TObject; //Trelation

  {for case-of}
  eqSnode,whenlist:TSyntaxNodePtr;
  res:TriLogic;

  {for trim}
  modifierSnode:TSyntaxNodePtr;

  {for userFunction calls}
  subStmtList:TPtrstmtList; //sub statement for compound recursion
  subSt:TStmt;
  subStrowCount:integer;
  errNode:TErrorNodePtr;
  initialVarCount,i:varRef;
begin
  result:=ok;
  n:=snode;

  //assert we're being called properly
  if snode.nType in [ntNumericExp,ntCharacterExp] then //todo remove this assertion when parser is in sync.
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Root should not be a ..._exp - descend before calling (%d)',[ord(snode.nType)]),vAssertion);
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
    exit; //abort
  end;

  begin
    case n.ntype of
      ntColumnRef:
      begin
        {We already stored the column reference during CompleteScalarExp, so use it rather than re-FindCol - speed}
        cTuple:=(n.cTuple as TTuple);
        cRef:=n.cRef;
        if cTuple=nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Missing tuple for column %s (%d)',[n.rightChild.idVal,n.cRef]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
          result:=Fail;
          exit; //abort
        end;

        {This column type may change the return type, e.g. it may not have been a double expression after all.
         - although this shouldn't happen any more now that we CompleteScalarExp first - todo catch if it does!}
        {Note: we copy the column definition AND data pointer to t's pinned data
         - this saves time & double-checking, but we must assume that t's data
           will continue to exist (& be pinned) as long as tuple requires
        }
        //todo remove the copycolDef- no need since new parse stage will have set the definition??? - but not enough, e.g. name/rangeRef?????...
        //...we should only need to copycolDef once - speed - maybe can check if name=''?
        //note Had to remove because column alias in sub-projection was being lost each next:
        //todo ensure initial setting is ok everywhere!:
        //...actually I'm sure the initial set gives us the exact name/rangeRef that we need...!
        // - well really it's the initial SetProjectHeadings that does the name/rangeRef etc.
        // - will this be ok for non-project nodes? - breaks CASE table_id WHEN...
        // so for now(?) we only copyColDef if the dataType is unknown... - test!
        //Note: we only had to do this cos we did a lazy CASE completion: fix this & then we can remove it!

        //note I think the deep is only needed by group-by... make switchable/detectable? - speed/elegance
        // - maybe only deep copy if aggregate=True? - else shallow is fine - speed/memory!
        //- I think only deep copy if aggregate=agStop! else shallow = speed!!! debug test!

        //Note: technically just use old for right-hand-side but ok for both since lhs=update table
        if useOldValues then
        begin
          result:=tuple.CopyOldColDataDeep(outCref,st,ctuple,cRef);
          {$IFDEF DEBUGDETAIL5}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Used any old values %s instead of %s (%d)',[tuple.show(st),ctuple.Show(st),cRef]),vDebugHigh);
          {$ENDIF}
          {$ENDIF}
        end
        else
          result:=tuple.copyColDataDeep(outCref,st,ctuple,cRef,false);
        if result<>ok then exit; //abort if child aborts
      end;
      ntVariableRef: //was ntColumnRef from parser but complete routine switched to this
      begin
        {We already stored the variable reference during CompleteScalarExp, so use it rather than re-FindVar - speed}
        vSet:=(n.vVariableSet as TVariableSet);
        vRef:=n.vRef;
        if vSet=nil then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Missing set for variable %s (%d)',[n.rightChild.idVal,n.vRef]),vAssertion);
          {$ENDIF}
          result:=Fail;
          exit; //abort
        end;

        {This variable type may change the return type, e.g. it may not have been a double expression after all.
         - although this shouldn't happen any more now that we CompleteScalarExp first - catch if it does!}
        case vSet.fVarDef[vRef].dataType of
          ctChar,ctVarChar,ctBit,ctVarBit:
          begin
            vSet.getString(vRef,s,snull);
            tuple.SetString(outCref,pchar(s),snull);
          end;
          ctInteger,ctSmallInt,ctBigInt,
          ctFloat,
          ctNumeric,ctDecimal:
          begin
            vSet.getNumber(vRef,v,vnull);
            tuple.SetNumber(outCref,v,vnull);
          end;
          ctDate:
          begin
            vSet.getDate(vRef,dt,dtnull);
            tuple.SetDate(outCref,dt,dtnull);
          end;
          ctTime,ctTimeWithTimezone:
          begin
            vSet.getTime(vRef,tm,dtnull);
            tuple.SetTime(outCref,tm,dtnull);
          end;
          ctTimestamp,ctTimestampWithTimezone:
          begin
            vSet.getTimestamp(vRef,ts,dtnull);
            tuple.SetTimestamp(outCref,ts,dtnull);
          end;
          ctBlob,ctClob:
          begin
            vSet.getBlob(vRef,b,snull);
            tuple.SetBlob(st,outCref,b,snull);
          end;
        else
          {$IFDEF DEBUG_LOG}
          log.add(who,where+routine,format('Variable ref %d is of unknown type %d',[vRef,ord(vSet.fVarDef[vRef].dataType)]),vAssertion);
          {$ENDIF}
          result:=Fail;
          exit; //abort
        end; {case}
        if result<>ok then exit; //abort if child aborts
      end; {ntVariableRef}
      ntString:
      begin
        //note would be nice to only set this once if we are in a Project list...? - applies to Number/null below...
        //- so maybe check if n.strVal is '' or if n.nullVal=True or something... & then can do once only-speed
        result:=tuple.SetString(outCref,pchar(n.strVal),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored string literal in exp column %d (%s)',[outCref,n.strVal]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntNumber:
      begin
        result:=tuple.SetNumber(outCref,n.numVal,n.nullval); //n.nullVal is always false //is this still true? what about varying results of a case?
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored numeric literal in exp column %d (%f) type=%d',[outCref,n.numVal,ord(tuple.fColDef[outCref].datatype)]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntDate:
      begin
        //note would be nice to only set this once if we are in a Project list...? - applies to Number/null below...
        //- so maybe check if n.strVal is '' or if n.nullVal=True or something... & then can do once only-speed
        //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
        result:=tuple.SetDate(outCref,strToSqlDate(n.strVal),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored date literal in exp column %d (%s)',[outCref,n.strVal]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntTime:
      begin
        //note would be nice to only set this once if we are in a Project list...? - applies to Number/null below...
        //- so maybe check if n.strVal is '' or if n.nullVal=True or something... & then can do once only-speed
        //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
        if tuple.fColDef[outCref].datatype=ctTimeWithTimezone then
          result:=tuple.SetTime(outCref,strToSqlTime(Ttransaction(st.owner).timezone,n.strVal,dayCarry),n.nullVal) //n.nullVal is always false //is this still true? what about varying results of a case?
        else
          result:=tuple.SetTime(outCref,strToSqlTime(TIMEZONE_ZERO,n.strVal,dayCarry),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
        //todo: error if dayCarry?
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored time literal in exp column %d (%s)',[outCref,n.strVal]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntTimestamp:
      begin
        //note would be nice to only set this once if we are in a Project list...? - applies to Number/null below...
        //- so maybe check if n.strVal is '' or if n.nullVal=True or something... & then can do once only-speed
        //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
        if tuple.fColDef[outCref].datatype=ctTimestampWithTimezone then
          result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(Ttransaction(st.owner).timezone,n.strVal),n.nullVal) //n.nullVal is always false //is this still true? what about varying results of a case?
        else
          result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(TIMEZONE_ZERO,n.strVal),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored timestamp literal in exp column %d (%s)',[outCref,n.strVal]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntBlob,ntClob:
      begin
        //note would be nice to only set this once if we are in a Project list...? - applies to Number/null below...
        //- so maybe check if n.strVal is '' or if n.nullVal=True or something... & then can do once only-speed
        b.rid.sid:=0; //i.e. in-memory blob
        b.rid.pid:=pageId(pchar(n.strVal)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
        b.len:=trunc(n.numVal); //use stored length in case blob contains #0
        result:=tuple.SetBlob(st,outCref,b,n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
        if result<>ok then exit;
        //{$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored blob literal in exp column %d with length=%d (%s)',[outCref,b.len,n.strVal]),vDebugLow);
        {$ENDIF}
        //{$ENDIF}
      end;
      ntNull:
      begin
        result:=tuple.SetNull(outCref);
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored null literal in exp column %d type=%d',[outCref,ord(tuple.fColDef[outCref].datatype)]),vDebugLow);
        {$ELSE}
        ;
        {$ENDIF}
        {$ENDIF}
      end;
      ntDefault:
      begin
        result:=tuple.SetNull(outCref); //ntNull datatype=ctVarChar, this one (ntDefault)=ctUnknown
        if result<>ok then exit;
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Stored default literal in exp column %d type=%d',[outCref,ord(tuple.fColDef[outCref].datatype)]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;
      ntParam:
      begin
        //todo get the param for this slot
        // then replace the data type and node type of this ntParam with the actual type
        // - so the param values are only pulled once into the syntax tree

        //...I think we now poke the param values into the tree as we get them
        // so they're available here as if they were ntNumber or ntStrings
        // without us needing to modify the syntax node type etc.

        // - request from client if missing but we expected that
//fixed 25/05/00 to use tuple-key types...what if not SARGable?        if (DataTypeDef[n.dType] in [stString]) then
        case DataTypeDef[tuple.fColDef[outCref].datatype] of
          stString:
          begin
            {If this string needs to be more generic (i.e. contains #0, or is very long) then we upgrade the target to a Blob now
             (alternatively could downgrade parameter value, i.e. convert to hexits)}
            if n.numVal<>0 then //when this string was passed, it's buffer length was noted if it contained #0s or was very long
            begin //blob parameter
              tuple.fColDef[outCref].datatype:=ctBlob; //switch the target type now //safe? //ok for ctClob?
              b.rid.sid:=0; //i.e. in-memory blob
              b.rid.pid:=pageId(pchar(n.strVal)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
              b.len:=trunc(n.numVal); //use stored length in case blob contains #0
              result:=tuple.SetBlob(st,outCref,b,n.nullval);
            end
            else
              result:=tuple.SetString(outCref,pchar(n.strVal),n.nullval);

            if result<>ok then exit;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Stored param %s (string) in exp column %d (%s) type=%d, null=%d',[n.idVal,outCref,n.strVal,ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;
          stDate:
          begin
            //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
            result:=tuple.SetDate(outCref,strToSqlDate(n.strVal),n.nullval);
            if result<>ok then exit;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Stored param %s (date) in exp column %d (%s) type=%d, null=%d',[n.idVal,outCref,n.strVal,ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end;
          stTime:
          begin
            //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
            if tuple.fColDef[outCref].datatype=ctTimeWithTimezone then
              result:=tuple.SetTime(outCref,strToSqlTime(Ttransaction(st.owner).timezone,n.strVal,dayCarry),n.nullVal) //n.nullVal is always false //is this still true? what about varying results of a case?
            else
              result:=tuple.SetTime(outCref,strToSqlTime(TIMEZONE_ZERO,n.strVal,dayCarry),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
            if result<>ok then exit;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Stored param %s (time) in exp column %d (%s) type=%d, null=%d',[n.idVal,outCref,n.strVal,ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end;
          stTimestamp:
          begin
            //Note: parser has already checked the format //in future might as well retain original parser conversion & re-use here //speed
            if tuple.fColDef[outCref].datatype=ctTimestampWithTimezone then
              result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(Ttransaction(st.owner).timezone,n.strVal),n.nullVal) //n.nullVal is always false //is this still true? what about varying results of a case?
            else
              result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(TIMEZONE_ZERO,n.strVal),n.nullVal); //n.nullVal is always false //is this still true? what about varying results of a case?
            if result<>ok then exit;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Stored param %s (timestamp) in exp column %d (%s) type=%d, null=%d',[n.idVal,outCref,n.strVal,ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
          end;
          stBlob:
          begin
            b.rid.sid:=0; //i.e. in-memory blob
            b.rid.pid:=pageId(pchar(n.strVal)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
            b.len:=trunc(n.numVal); //use stored length in case blob contains #0
            result:=tuple.SetBlob(st,outCref,b,n.nullval);
            if result<>ok then exit;
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Stored param %s (blob) in exp column %d (%s) type=%d, null=%d',[n.idVal,outCref,n.strVal,ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
            {$ENDIF}
            {$ENDIF}
          end;
        else //assume number
          //25/05/00 - always set as string!: tuple.SetNumber(outCref,n.numVal,n.nullval);
          try //too heavyweight? speed
            tuple.SetNumber(outCref,strToFloat(n.strVal),n.nullval); //TODO trap conversion error!
          except //should not happen since most clients will be well behaved at param passing(!)
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Param (%s) could not be converted to a number in exp column %d',[n.strVal,outCRef]),vError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=-4;
            exit; //review behaviour for this user error
          end; {try}

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          {$ELSE}
          ;
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Stored param %s (number) in exp column %d (%f) type=%d, null=%d',[n.idVal,outCref,strToFloat(n.strVal),ord(tuple.fColDef[outCref].datatype),ord(n.nullVal)]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        end; {case}
      end;
      ntConcat:
      begin
        //we currenly assume string/blob children...//ok? - make more flexible, e.g. '2'||3 - & then can relax parser...
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},{//remove use constraints instead: n.leftChild.dnulls}'',True); 
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          //use GetAsString? i.e. allow routine to convert number to string if required
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            if not snull then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s:='';
                  setLength(s,b.len);
                  strMove(pchar(s),pchar(bData.rid.pid),b.len);
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s,snull); //store result
          if result<>ok then exit;

          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.dtype,n.rightChild.dwidth{0},n.rightChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate right expression}
          result:=EvalScalarExp(st,iter,n.rightChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,s2null);
            if not s2null then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s2:='';
                  setLength(s2,b.len);
                  strMove(pchar(s2),pchar(bData.rid.pid),b.len);
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s2,s2null); //store result
          if result<>ok then exit;

          {Return result}
          if snull or s2null then begin s:=''; s2:=''; snull:=true; end else snull:=false;
          n.dwidth:=length(s+s2); //in case higher operator needs this, e.g. concat - too late here?
          if n.dType in [ctBlob,ctClob] then
          begin
            b.rid.sid:=0; //i.e. in-memory blob
            b.rid.pid:=pageId(pchar(s+s2)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
            b.len:=length(s+s2); //use stored length in case blob contains #0
            result:=tuple.SetBlob(st,outCref,b,snull);
          end
          else
            result:=tuple.SetString(outCref,pchar(s+s2),snull);
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntConcat}
      ntPlus,ntMinus,ntMultiply,ntDivide:
      begin
        //we currenly assume numeric children...//ok? - make more flexible, e.g. '2'+3 - & then can relax parser...
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);
          //speed: faster if we work with integers if this is possible...
          //todo: if both sub-expressions return integers then return an integer
          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},'',True);
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          result:=tempTuple.GetNumber(0,v,vnull); //store result
          if result<>ok then exit; //abort if not a number

          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.dtype,n.rightChild.dwidth{0},n.rightChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type - is this still true/needed?
          {evaluate right expression}
          result:=EvalScalarExp(st,iter,n.rightChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          result:=tempTuple.GetNumber(0,v2,v2null); //store result
          if result<>ok then exit; //abort if not a number
          {Return result}
          if vnull or v2null then begin v:=0; v2:=0;{no need to zeroise? speed} vnull:=true; end else vnull:=false;
          case n.ntype of
            //todo put these in separate maths routines...
            ntPlus,ntMinus:
            begin
              {Normalise}
              vscale:=uGlobal.maxSMALLINT(n.leftChild.dscale,n.rightChild.dscale);
              if n.leftChild.dscale<vscale then v:=v*power(10,vscale-n.leftChild.dscale);
              if n.rightChild.dscale<vscale then v2:=v2*power(10,vscale-n.rightChild.dscale);

              case n.ntype of
                ntPlus:v:=v+v2;
                ntMinus:v:=v-v2;
              end; {case}
            end;
            ntMultiply:v:=v*v2;
            ntDivide:
              begin
                if v2=0 then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Divide by zero in exp column %d',[outCRef]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  result:=-2;
                  st.addError(seDivisionByZero,seDivisionByZeroText);
                  exit; //review behaviour for this user error
                end
                else
                begin
                  vscale:=n.leftChild.dscale-n.rightChild.dscale;
                  v:=v/v2;
                  v:=v*power(10,n.dscale-vscale); //adjust result to fit result scale
                end;
              end;
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unknown operator in exp column %d',[outCRef]),vDebugWarning);
            {$ELSE}
            ;
            {$ENDIF}
          end;
          //todo: if both sub-expressions return integers then return an integer
          //was setDouble - debug CASE/group-by
          //use SetFromNumber? i.e. allow routine to convert number to string if required
          result:=tuple.SetNumber(outCref,v,vnull);
          if result<>ok then exit;
          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Calculated and stored %g in exp column %d',[v,outCref]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntPlus,ntMinus,ntMultiply,ntDivide}
      ntAggregate:
      begin
        case aggregate of
          agStart:
          begin
            if n.leftChild.nType=ntCount then
            begin //count starts at 0
              n.nullVal:=false;
              n.numVal:=0;
            end
            else //rest start at null
              n.nullVal:=true;

            {Get current value from syntax tree}
            v2:=n.numVal;
            v2null:=n.nullVal;

            //would be nice to reduce the number of numeric/string type checks we have to do in this routine...
            {Get current value from syntax tree}
            s2:=n.strVal;
            s2null:=n.nullVal;
          end; {agStart}

          agNext:
          begin
            {Get current value from syntax tree}
            v2:=n.numVal;
            v2null:=n.nullVal;

            //would be nice to reduce the number of numeric/string type checks we have to do in this routine...
            {Get current value from syntax tree}
            s2:=n.strVal;
            s2null:=n.nullVal;

            {We 'add' the value of this expression to the existing value.
             The initialisation and finalisation of the aggregate values is
             done by the caller/group-by loop.
             The existing value is kept at this syntax node.
               reason:
                 faster than updating output tuple within group loop
                 updating meant we would need to update for all eval outputs
                          - would have been too slow (& more complicated)
                 neat (only?) way of getting current value into this routine
               downside:
                 we can't share syntax trees (or this node type at least)
            }
            {We need a temporary area because we can only write to the output slot
             once (i.e. we are simply appending to build the result tuple)}
            //actually, we no longer need to return a value if agNext! - so don't! - speed! memory!
            if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
            begin //use cached tuples
              tempTuple:=iter.lTuple;
              iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
            end
            else
              tempTuple:=TTuple.create(nil);
            try
              if n.rightChild<>nil then
              begin
                tempTuple.ColCount:=1;
                tempTuple.clear(st);
                tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.leftChild.dtype,n.rightChild.leftChild.dwidth{0},n.rightChild.leftChild.dscale{0},'',True);
                {evaluate sub-expression}
                result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tempTuple,0,aggregate,useOldValues);
                //                                        ^assume exists
                if result<>ok then exit;
                tempTuple.preInsert; //prepare buffer

                //todo merge with following tests that are same!
                case DataTypeDef[n.dType] of
                  stString:
                  begin
                    result:=tempTuple.GetString(0,s,snull); //store result
                    if result<>ok then exit;
                  end;
                  stDate:
                  begin
                    result:=tempTuple.GetDate(0,dt,dtnull); //store result
                    if result<>ok then exit;

                    {While we're here, convert the old value to allow comparisons}
                    dt2:=strToSqlDate(s2);
                  end;
                  stTime:
                  begin
                    result:=tempTuple.GetTime(0,tm,dtnull); //store result
                    if result<>ok then exit;

                    {While we're here, convert the old value to allow comparisons}
                    if n.dtype=ctTimeWithTimezone then
                      tm2:=strToSqlTime(Ttransaction(st.owner).timezone,s2,dayCarry)
                    else
                      tm2:=strToSqlTime(TIMEZONE_ZERO,s2,dayCarry);
                  end;
                  stTimestamp:
                  begin
                    result:=tempTuple.GetTimestamp(0,ts,dtnull); //store result
                    if result<>ok then exit;

                    {While we're here, convert the old value to allow comparisons}
                    if n.dtype=ctTimestampWithTimezone then
                      ts2:=strToSqlTimestamp(Ttransaction(st.owner).timezone,s2)
                    else
                      ts2:=strToSqlTimestamp(TIMEZONE_ZERO,s2);
                  end;
                  stBlob:
                  begin
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Invalid aggregate for a blob expression (%d)',[ord(n.leftChild.nType)]),vAssertion); //should never happen
                    {$ENDIF}
                  end;
                else //assume number
                  result:=tempTuple.GetNumber(0,v,vnull); //store result
                  if result<>ok then exit;
                  //need to handle when not a number
                  //so need all functions here & cope with all kinds of sub-expressions
                  //else min(char_column) won't work because parser marks type as unknown & as a numeric_exp
                end; {case}
              end
              else //must be count(*), so we ignore value/sub-expression anyway
              begin
                v:=0; vnull:=True;
                s:=''; snull:=True;
              end;

              case DataTypeDef[n.dType] of
                stString:
                begin
                  {Return result via s2}
                  case n.leftChild.nType of
                    ntMax:
                      if not snull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          s2:=s;
                          s2null:=False;
                        end
                        else
                          if s>s2 then //replace > with function! (guaranteed no nulls here)
                          begin
                            s2:=s;
                          end;
                      end;
                    ntMin:
                      if not snull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          s2:=s;
                          s2null:=False;
                        end
                        else
                          if s<s2 then //replace < with function! (guaranteed no nulls here)
                          begin
                            s2:=s;
                          end;
                      end;
                    ntSum, ntAvg: //average same as Sum until finalised by caller
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Invalid aggregate for a character expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //note: should never happen: caught during completion & aborts rather than continue -> null result
                    ntCount:
                      ;
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown aggregate (%d)',[ord(n.leftChild.nType)]),vAssertion);
                    {$ENDIF}
                  end; {case}

                  {Store in syntax node for later use} 
                  n.strVal:=s2;
                  n.nullVal:=s2null;
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Calculated and stored %s in aggregate_exp column %d at syntax node %d',[s2,outCref,longInt(n)]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                end; {stString}
                stDate:
                begin
                  {Return result via s2}
                  case n.leftChild.nType of
                    ntMax:
                      if not dtnull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          s2:=format(DATE_FORMAT,[dt.year,dt.month,dt.day]);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareDate(dt,dt2,compareRes); //(guaranteed no nulls here)
                          if compareRes=+1 then
                          begin
                            s2:=format(DATE_FORMAT,[dt.year,dt.month,dt.day]);
                          end;
                        end;
                      end;
                    ntMin:
                      if not snull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          s2:=format(DATE_FORMAT,[dt.year,dt.month,dt.day]);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareDate(dt,dt2,compareRes); //(guaranteed no nulls here)
                          if compareRes=-1 then
                          begin
                            s2:=format(DATE_FORMAT,[dt.year,dt.month,dt.day]);
                          end;
                        end;
                      end;
                    ntSum, ntAvg: //average same as Sum until finalised by caller
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Invalid aggregate for a date expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //note: should never happen: caught during completion & aborts rather than continue -> null result
                    ntCount:
			;
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown aggregate (%d)',[ord(n.leftChild.nType)]),vAssertion);
                    {$ENDIF}
                  end; {case}

                  {Store in syntax node for later use}
                  n.strVal:=s2;
                  n.nullVal:=s2null;
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Calculated and stored %s in aggregate_exp column %d at syntax node %d',[s2,outCref,longInt(n)]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                end; {stDate}
                stTime:
                begin
                  {Return result via s2}
                  case n.leftChild.nType of
                    ntMax:
                      if not dtnull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          if n.dtype=ctTimeWithTimezone then
                            s2:=sqlTimeToStr(Ttransaction(st.owner).timezone,tm,n.dscale,dayCarry)
                          else
                            s2:=sqlTimeToStr(TIMEZONE_ZERO,tm,n.dscale,dayCarry);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareTime(tm,tm2,compareRes); //(guaranteed no nulls here)
                          if compareRes=+1 then
                          begin
                            if n.dtype=ctTimeWithTimezone then
                              s2:=sqlTimeToStr(Ttransaction(st.owner).timezone,tm,n.dscale,dayCarry)
                            else
                              s2:=sqlTimeToStr(TIMEZONE_ZERO,tm,n.dscale,dayCarry);
                          end;
                        end;
                      end;
                    ntMin:
                      if not snull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          if n.dtype=ctTimeWithTimezone then
                            s2:=sqlTimeToStr(Ttransaction(st.owner).timezone,tm,n.dscale,dayCarry)
                          else
                            s2:=sqlTimeToStr(TIMEZONE_ZERO,tm,n.dscale,dayCarry);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareTime(tm,tm2,compareRes); //(guaranteed no nulls here)
                          if compareRes=-1 then
                          begin
                            if n.dtype=ctTimeWithTimezone then
                              s2:=sqlTimeToStr(Ttransaction(st.owner).timezone,tm,n.dscale,dayCarry)
                            else
                              s2:=sqlTimeToStr(TIMEZONE_ZERO,tm,n.dscale,dayCarry);
                          end;
                        end;
                      end;
                    ntSum, ntAvg: //average same as Sum until finalised by caller
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Invalid aggregate for a time expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //note: should never happen: caught during completion & aborts rather than continue -> null result
                    ntCount:
			 ;
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown aggregate (%d)',[ord(n.leftChild.nType)]),vAssertion);
                    {$ENDIF}
                  end; {case}

                  {Store in syntax node for later use}  
                  n.strVal:=s2;
                  n.nullVal:=s2null;
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Calculated and stored %s in aggregate_exp column %d at syntax node %d',[s2,outCref,longInt(n)]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                end; {stTime}
                stTimestamp:
                begin
                  {Return result via s2}
                  case n.leftChild.nType of
                    ntMax:
                      if not dtnull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          if n.dtype=ctTimestampWithTimezone then
                            s2:=sqlTimestampToStr(Ttransaction(st.owner).timezone,ts,n.dscale)
                          else
                            s2:=sqlTimestampToStr(TIMEZONE_ZERO,ts,n.dscale);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareTimestamp(ts,ts2,compareRes); //(guaranteed no nulls here)
                          if compareRes=+1 then
                          begin
                            if n.dtype=ctTimestampWithTimezone then
                              s2:=sqlTimestampToStr(Ttransaction(st.owner).timezone,ts,n.dscale)
                            else
                              s2:=sqlTimestampToStr(TIMEZONE_ZERO,ts,n.dscale);
                          end;
                        end;
                      end;
                    ntMin:
                      if not snull then
                      begin
                        if s2null then
                        begin //first non-null value found
                          if n.dtype=ctTimestampWithTimezone then
                            s2:=sqlTimestampToStr(Ttransaction(st.owner).timezone,ts,n.dscale)
                          else
                            s2:=sqlTimestampToStr(TIMEZONE_ZERO,ts,n.dscale);
                          s2null:=False;
                        end
                        else
                        begin
                          CompareTimestamp(ts,ts2,compareRes); //(guaranteed no nulls here)
                          if compareRes=-1 then
                          begin
                            if n.dtype=ctTimestampWithTimezone then
                              s2:=sqlTimestampToStr(Ttransaction(st.owner).timezone,ts,n.dscale)
                            else
                              s2:=sqlTimestampToStr(TIMEZONE_ZERO,ts,n.dscale);
                          end;
                        end;
                      end;
                    ntSum, ntAvg: //average same as Sum until finalised by caller
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Invalid aggregate for a timestamp expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //note: should never happen: caught during completion & aborts rather than continue -> null result
                    ntCount:
			;
                  else
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Unknown aggregate (%d)',[ord(n.leftChild.nType)]),vAssertion);
                    {$ENDIF}
                  end; {case}

                  {Store in syntax node for later use}   
                  n.strVal:=s2;
                  n.nullVal:=s2null;
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Calculated and stored %s in aggregate_exp column %d at syntax node %d',[s2,outCref,longInt(n)]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {$ENDIF}
                end; {stTimestamp}
                stBlob:
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Invalid aggregate for a blob expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                  {$ENDIF}
                  //note: should never happen: caught during completion & aborts rather than continue -> null result
                end; {stBlob}
              else //assume number
                {Return result via v2}
                case n.leftChild.nType of
                  ntMax:
                    if not vnull then
                    begin
                      if v2null then
                      begin //first non-null value found
                        v2:=v;
                        v2null:=False;
                      end
                      else
                        if v>v2 then //replace > with function! (guaranteed no nulls here)
                        begin
                          v2:=v;
                        end;
                    end;
                  ntMin:
                    if not vnull then
                    begin
                      if v2null then
                      begin //first non-null value found
                        v2:=v;
                        v2null:=False;
                      end
                      else
                        if v<v2 then //replace < with function! (guaranteed no nulls here)
                        begin
                          v2:=v;
                        end;
                    end;
                  ntSum, ntAvg: //average same as Sum until finalised by caller
                    if not vnull then
                    begin
                      if v2null then
                      begin //first non-null value found
                        v2:=v;
                        v2null:=False;
                      end
                      else
                      begin
                        v2:=v2+v;
                      end;
                    end;
                  ntCount:
			;
                else
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Unknown aggregate (%d)',[ord(n.leftChild.nType)]),vAssertion); 
                  {$ENDIF}
                end; {case}

                {Store in syntax node for later use}
                n.numVal:=v2;
                n.nullVal:=v2null;
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Calculated and stored %g in aggregate_exp column %d at syntax node %d',[v2,outCref,longInt(n)]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
              end; {case}
            finally
              if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
              begin //release cached tuples
                iter.lrInUse:=false;
                tempTuple:=nil; //remove no need: speed
              end
              else
                tempTuple.free;
            end; {try}
          end; {agNext}

          agStop:
          begin
            {Get current value from syntax tree}
            v2:=n.numVal;
            v2null:=n.nullVal;

            //would be nice to reduce the number of numeric/string type checks we have to do in this routine...
            {Get current value from syntax tree}
            s2:=n.strVal;
            s2null:=n.nullVal;

            {Else, we need to read a pre-aggregated sub-tree that was pushed down into
             a IterGroup & is now being eval'ed by a higher node}
            //so we just use the latest values from the tree
            case DataTypeDef[n.dType] of
              stString, stDate, stTime, stTimestamp, stBlob: //note: assume pre-syntax analysis has given us correct info!!!
              begin
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Read and stored %s in aggregate_exp column %d from syntax node %d',[s2,outCref,longInt(n)]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                case n.leftChild.nType of
                  ntCount: s2:=intToStr((iter.parent as TIterGroup).groupRowCount); //counts nulls //try inttoStr except!!!!  //assert iter.outer exists and is iterGroup!

                  ntAvg: {$IFDEF DEBUG_LOG}
                         log.add(st.who,where+routine,format('Invalid aggregate for a character/date/time/timestamp expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
                         {$ELSE}
                         ;
                         {$ENDIF}
                         //fail/abort rather than continue -> null result
                //else we keep the originally read s2 value from the syntax tree
                end; {case}
              end;
            else //assume number
              {$IFDEF DEBUGDETAIL}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Read and stored %g in aggregate_exp column %d from syntax node %d',[v2,outCref,longInt(n)]),vDebugLow);
              {$ENDIF}
              {$ENDIF}
              case n.leftChild.nType of
                ntCount: v2:=(iter.parent as TIterGroup).groupRowCount; //counts nulls //assert iter.outer exists and is iterGroup!
                ntAvg: if (iter.parent as TIterGroup).groupRowCount=0 then
                         v2null:=True //ok? ->infinity
                       else
                       begin
                         v2:=v2 / (iter.parent as TIterGroup).groupRowCount; //counts nulls //assert iter.outer exists and is iterGroup!
                         v2null:=False;
                       end;
              //else we keep the originally read v2 value from the syntax tree
              end; {case}
            end; {case}
          end; {agStop}
        end; {case}

        {Now return the value}
        //we only need to do this if agStop!? (& maybe agNone?) - speed (but setNull in case caller ever tries to use it!?)
        case DataTypeDef[n.dType] of
          stString: //note: assume pre-syntax analysis has given us correct info!!!
          begin
            result:=tuple.SetString(outCref,pchar(s2),s2null); //output latest total
            if result<>ok then exit;
          end;
          stDate:
          begin
            result:=tuple.SetDate(outCref,strToSqlDate(s2),s2null); //output latest total
            if result<>ok then exit;
          end; {stDate}
          stTime:
          begin
            //output latest total
            if tuple.fColDef[outCref].datatype=ctTimeWithTimezone then
              result:=tuple.SetTime(outCref,strToSqlTime(Ttransaction(st.owner).timezone,s2,dayCarry),s2null)
            else
              result:=tuple.SetTime(outCref,strToSqlTime(TIMEZONE_ZERO,s2,dayCarry),s2null);
            if result<>ok then exit;
          end; {stTime}
          stTimestamp:
          begin
            //output latest total
            if tuple.fColDef[outCref].datatype=ctTimestampWithTimezone then
              result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(Ttransaction(st.owner).timezone,s2),s2null)
            else
              result:=tuple.SetTimestamp(outCref,strToSqlTimestamp(TIMEZONE_ZERO,s2),s2null);
            if result<>ok then exit;
          end; {stTimestamp}
          stBlob:
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Invalid aggregate for a blob expression (%d)',[ord(n.leftChild.nType)]),vAssertion);
            {$ENDIF}
            //note: should never happen: caught during completion & aborts rather than continue -> null result
          end; {stBlob}
        else //assume number
          result:=tuple.SetNumber(outCref,v2,v2null); //output latest total
          if result<>ok then exit;
        end; {case}
      end; {ntAggregate}
      ntUserFunction:
      begin
        if st.depth>=MAX_ROUTINE_NEST then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,seTooMuchNestingText+format(' %d',[st.depth]),vError);
          {$ENDIF}
          st.addError(seTooMuchNesting,format(seTooMuchNestingText,[nil]));
          result:=-5;
          exit; //abort the operation
        end;

        subStmtList:=nil; //we never add more than one stmt to this list & we make sure we remove it in this block
        //think about preserving the results of each sub-stmt's processing for future re-use
        //      either by other users or by recursive SQL calls: i.e. need to addStmt for each in compound list...
        //      - attach to ntCompoundBlock node...

        //if level>Max then infinite loop error...

        //we need a way of preparing this function plan once! NOT every call!

        result:=Ttransaction(st.owner).addStmt(stSystemUserCall,subSt);
        if result=ok then
        begin
          try
            subSt.outer:=st; //link children to this parent context for variable/parameter scoping
            subSt.depth:=st.depth+1; //track nesting
            subSt.varSet:=TVariableSet.create(subSt);
            subSt.status:=ssActive; //i.e. cancellable
            {Prepare the called routine's body for this sub-statement}
              result:=CreateCallRoutine(st,n,subSt,true); //Note: we pass our current st for the routine body script, and the new child subSt which will do the processing
              if result<>ok then
                exit; //abort - ok? //improve recovery

              {Now evaluate and load any in parameters}
              if subSt.varSet.VarCount>1{don't count result parameter} then
              begin
                if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
                begin //use cached tuples
                  tempTuple:=iter.lTuple;
                  iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
                end
                else
                  tempTuple:=TTuple.create(nil);
                try
                  tempTuple.ColCount:=1;

                  n:=snode.rightChild;

                  for i:=0 to subSt.varSet.VarCount-2{ignore last parameter=result} do
                  begin //for each routine argument
                    if n<>nil then
                    begin //we have a value to pass
                      if subSt.varSet.fVarDef[i].variableType in [vtIn] then
                      begin //a value is needed
                        tempTuple.clear(st);
                        tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.dtype,n.leftChild.dwidth{0},n.leftChild.dscale{0},{//remove use constraints instead:n.leftChild.dnulls,}'',True{//remove use constraints instead:,''});
                        result:=EvalScalarExp(subSt,nil{not expecting column values here},n.leftChild{descend below ..._exp},tempTuple,0,aggregate,useOldValues);
                        if result<>ok then exit; //aborted by child
                        tempTuple.preInsert; //prepare buffer //needed?
                        result:=subSt.varSet.CopyColDataDeepGetSet(st,i,tempTuple,0);  //Note: deep copy required here
                        if result<>ok then
                        begin
                          st.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                          {Clean-up the syntax tree prepared by the createCallRoutine}
                          if UnPreparePlan(subSt)<>ok then
                            {$IFDEF DEBUG_LOG}
                            log.add(st.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); //assertion
                            {$ELSE}
                            ;
                            {$ENDIF}
                          exit; //abort the operation
                        end;
                      end;
                      //else must be vtInOut/vtOut so assert n.ntype=ntVariableRef

                      n:=n.nextNode; //next parameter in this list
                    end
                    else
                    begin
                      st.addError(seSyntaxNotEnoughParemeters,seSyntaxNotEnoughParemetersText);
                      result:=fail;
                      {Clean-up the syntax tree prepared by the createCallRoutine}
                      if UnPreparePlan(subSt)<>ok then
                        {$IFDEF DEBUG_LOG}
                        log.add(st.who,where+routine,format('Error unpreparing existing plan',[nil]),vDebugError); //assertion
                        {$ELSE}
                        ;
                        {$ENDIF}
                      exit; //abort
                    end;
                  end;
                finally
                  if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
                  begin //release cached tuples
                    iter.lrInUse:=false;
                    tempTuple:=nil;
                  end
                  else
                    tempTuple.free;
                end; {try}
              end;

              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Processing %p function call sub-stmt:',[snode]),vDebug);
              log.add(st.who,where+routine,format('  parameters=%s',[subSt.{parse}varSet.showHeading]),vDebug);
              log.add(st.who,where+routine,format('             %s',[subSt.{parse}varSet.show(st)]),vDebug);
              DisplaySyntaxTree(subSt.{parse}sroot); //debug
              {$ENDIF}

              {We store the current varCount for out parameter checking later (i.e. no need to scan any extra locally declared variables)}
              initialVarCount:=subSt.varSet.VarCount; //useful to variableSet itself, so store it there!
              (*
              {We prevent the planAndExecute routine from zapping our parameter list just yet
               by double-referencing the parameter sub-tree - we then zap it when we've read the out parameter destinations}
              n2:=stmt.sroot.rightChild;
              linkLeftChild(n2,stmt.sroot.rightChild);
              *)

              {Note: compounds can be nested, so be aware of our level}
              {what if this subst were to modify rows in the table modified by st?
                     - especially since we assume in places that a committed st implies prior ones are also, or somthing..)
              }
              result:=PrepareAndExecutePlan(subSt,nil,subStrowCount);
              if result<>ok then
                exit; //abort - ok? //improve recovery

              {$IFDEF DEBUG_LOG}
              //log.add(st.who,where+routine,format('After routine call, tree root = %p',[stmt.sroot]),vDebug);
              {$ENDIF}

              {Now retrieve the result parameter}
                for i:=0 to initialVarCount-1 do //we can safely assume at least 1 variable=result
                begin //for each routine argument
                    if subSt.varSet.fVarDef[i].variableType in [vtResult] then
                    begin //a return value is needed
                      {Convert (cast) & return result}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Function result=%s',[subSt.varSet.ShowVar(st,i)]),vDebug);
                      {$ENDIF}
                      result:=tuple.CopyVarDataDeepGetSet(st,outCref,subSt.varSet,i);
                      if result<>ok then
                      begin
                        st.addError(seInvalidValue,format(seInvalidValueText,[nil]));
                        exit; //abort the operation
                      end;
                    end;
                end;
              (*
              {We prevented the planAndExecute routine from zapping our parameter list
               by double-referencing the parameter sub-tree - now we can zap it}
              unlinkLeftChild(n);
              DeleteSyntaxTree(n2);
              *)
          finally
            if result<>ok then
            begin
              {Copy errors from sub-stmt to caller stmt level}
              errNode:=subSt.errorList;
              while errNode<>nil do
              begin
                st.addError(errNode.code,errNode.text);
                errNode:=errNode.next;
              end;
              subSt.deleteErrorList; //clear subSt error stack

              st.addError(seCompoundFail,seCompoundFailText); //general routine error ok for now?
            end;
            //else?...

            if Ttransaction(st.owner).removeStmt(subSt)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'failed deleting temporary stmt, continuing...',vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
            subSt:=nil;
          end; {try}
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,'failed allocating temporary call stmt handle, continuing...',vAssertion);
          {$ENDIF}
        end;
      end; {ntUserFunction}
      ntCast:
      begin
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);

          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer

          {Convert (cast) & return result}
          result:=tuple.CopyColDataDeepGetSet(st,outCref,tempTuple,0);
          if result<>ok then
          begin
            st.addError(seInvalidValue,format(seInvalidValueText,[nil]));
            exit; //abort the operation
          end;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntCast}
      ntCase:
      begin
        //assert leftChild exists: could be 'CASE END'!?
        //look at left child

        {Initialise}
        if n.leftChild.ntype=ntCaseOf then
        begin
          //assert nextNode exists!
          eqSnode:=n.nextNode; //point to artificial condition node created by completion routine
          whenList:=n.leftChild.rightChild;
        end
        else
        begin
          eqSnode:=nil; //i.e. whenList = full predicates
          whenList:=n.leftChild;
        end;
        try
          {Loop through when list until we get a match}
          //check/make sure we don't do this backwards!
          while whenList<>nil do
          begin
            {Evaluate when condition}
            if eqSnode=nil then
            begin
              {Already fully formed expression, just evaluate it}
              result:=EvalCondExpr(st,iter,whenList.leftChild,res,aggregate,useOldValues); //check aggregate=False is always ok! I think it is... but should't we use aggregate?
              if result<>ok then exit; //abort
            end
            else
            begin
              {We need to (temporarily) link the partial expression to our pre-formed 'Equal' node before evaluation}
              //Note: this happens every loop many times! But the link/unlink is really just a single assignment
              // - (plus a couple of parameter pushes) so it's fairly rapid
              // - but maybe we should avoid it somehow = complete each When node to a full predicate = more space?
              // - space/speed trade-of: currently I think an extra 3 syntax nodes per When is too big (maybe optimiser should decide!)
              linkLeftChild(eqSnode.rightChild,whenList.leftChild);
              try
                result:=EvalCondExpr(st,iter,eqSnode,res,aggregate,useOldValues); //check aggregate=False is always ok! I think it is... but should't we use aggregate?
                if result<>ok then exit; //abort
              finally
                unlinkLeftChild(eqSnode.rightChild);
              end; {try}
            end;
            if res=isTrue then
            begin
              {We've found a match}
              {Note: we've stopped trying to pre-determine whether the result is a character or a numeric
               - i.e. we're moving gradually towards a unified routine called EvalScalarExp that determines
                 at the last minute (as the 2 routines already have to do sometimes)
               -although the whenList.rightChild.dtype is probably passed up ok...so we could determine here=faster?better?

               Note also, that this is a recursive call (so we can have nested CASE statements)
               and we pass the current output target down) -type may change
              }
              //maybe assert exp node exists before calling EvalScalarExp?
              result:=EvalScalarExp(st,iter,whenList.rightChild.leftChild,tuple,OutCRef,aggregate,useOldValues); //ok aggregate ok to pass down, or always False?
              if result<>ok then exit; //abort
              break; //done!
            end;

            whenList:=whenList.nextNode;
          end; {while}

          if whenList=nil then
          begin
            {We didn't find a match in the when clause list, so check the Else}
            if n.rightChild<>nil then
            begin
              //maybe assert exp node exists before calling EvalScalarExp?
              result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tuple,OutCRef,aggregate,useOldValues); //ok aggregate ok to pass down, or always False?
              if result<>ok then exit; //abort
            end
            else //default to null
            begin
              result:=tuple.SetNull(outCref);
              if result<>ok then exit;
            end;
          end;
        finally
        end; {try}

        {$IFDEF DEBUGDETAIL}
{$IFDEF DEBUG_LOG}
{$ELSE}
;
{$ENDIF}
        {$ENDIF}
      end; {ntCase}
      ntNullIf:
      begin
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple2:=iter.lTuple;
          tempTuple:=iter.rTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
        begin
          tempTuple2:=TTuple.create(nil);
          tempTuple:=TTuple.create(nil);
        end;
        tempTuple2.ColCount:=1;
        tempTuple.ColCount:=1;
        try
          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},{//remove use constraints instead: n.leftChild.dnulls}'',True); //remove use constraints instead: ,'');
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer

          tempTuple2.clear(st);
          tempTuple2.SetColDef(0,1,seInternal,0,n.rightChild.leftChild.dtype,n.rightChild.leftChild.dwidth{0},n.rightChild.leftChild.dscale{0},{//remove use constraints instead: n.leftChild.dnulls}'',True); //remove use constraints instead: ,'');
          result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tempTuple2,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple2.preInsert; //prepare buffer

          tempTuple.CompareCol(st,0,0,tempTuple2,compareRes,snull);
          if not snull and (CompResEQ(compareRes)=isTrue) then
            result:=tuple.SetNull(outCref) //return null if =
          else //return 1st parameter
            result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tuple,OutCRef,aggregate,useOldValues); //ok aggregate ok to pass down, or always False?
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple2=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple2:=nil; tempTuple:=nil; //remove no need: speed
          end
          else
          begin
            tempTuple.free;
            tempTuple2.free;
          end;
        end; {try}
      end; {ntNullIf}
      ntCoalesce:
      begin
        whenList:=n.leftChild;

        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        tempTuple.ColCount:=1;
        try
          while whenList<>nil do
          begin
            {evaluate next expression}
            tempTuple.clear(st);
            tempTuple.SetColDef(0,1,seInternal,0,whenList.leftChild.dtype,whenList.leftChild.dwidth{0},whenList.leftChild.dscale{0},{//remove use constraints instead: n.leftChild.dnulls}'',True); //remove use constraints instead: ,'');
            result:=EvalScalarExp(st,iter,whenList.leftChild,tempTuple,0,aggregate,useOldValues);
            if result<>ok then exit;
            tempTuple.preInsert; //prepare buffer
            {Return any non-null result}
            tempTuple.ColIsNull(0,snull);
            if not snull then
            begin
              result:=EvalScalarExp(st,iter,whenList.leftChild,tuple,OutCRef,aggregate,useOldValues); //ok aggregate ok to pass down, or always False?
              break;
            end;

            whenList:=whenList.nextNode;
          end; {while}
          if snull then
            result:=tuple.SetNull(outCref);
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntCoalesce}
      ntTrim:
      begin
        //we currenly assume string/blob children...//ok?
        {Defaults are BOTH and SPACE}
        modifierSnode:=nil;
        if n.dtype in [ctBlob] then
          s2:=#0 //replace with nullchar constant!
        else
          s2:=' '; //replace with SPACE constant!
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;

          if n.leftChild<>nil then
          begin //we have a modifier (what/where)
            modifierSnode:=n.leftChild.leftChild; //set where

            if n.leftChild.rightChild<>nil then
            begin //we have a what, so evaluate it
              tempTuple.clear(st);
              tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.rightChild.leftChild.dtype,n.leftChild.rightChild.leftChild.dwidth{0},n.leftChild.rightChild.leftChild.dscale{0},'',True);
              {evaluate left expression}
              result:=EvalScalarExp(st,iter,n.leftChild.rightChild.leftChild,tempTuple,0,aggregate,useOldValues);
              if result<>ok then exit;
              tempTuple.preInsert; //prepare buffer
              if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
              begin
                tempTuple.GetBlob(0,b,s2null);
                if not s2null then
                  try
                    if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                         //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                    begin
                      s2:='';
                      setLength(s2,b.len);
                      strMove(pchar(s2),pchar(bData.rid.pid),b.len);
                    end;
                  finally
                    tempTuple.freeBlobData(bData);
                  end; {try}
              end
              else
                result:=tempTuple.GetString(0,s2,s2null); //store result
              if result<>ok then exit;

              //also ensure s2null is false! else what?
            end;
            //else default = space/#0
          end; //else default to both space/#0

          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.leftChild.dtype,n.rightChild.leftChild.dwidth{0},n.rightChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate right expression}
          result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            if not snull then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s:='';
                  setLength(s,b.len);
                  strMove(pchar(s),pchar(bData.rid.pid),b.len);
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s,snull); //store result
          if result<>ok then exit;

          {Return result}
          if snull then s:='';
          {$IFDEF DEBUGDETAIL}
          if (modifierSnode=nil) then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Trimming %s from default=BOTH %s',[s2,s]),vDebugLow)
            {$ENDIF}
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Trimming %s from %d %s',[s2,ord(modifierSnode.nType),s]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
          {$ENDIF}
          if (modifierSnode=nil) or (modifierSnode.nType in [ntTrimLeading,ntTrimBoth]) then //assumes boolean short-circuiting
            while (length(s)>0) and (s[1]=s2) do //assumes boolean short-circuiting
              delete(s,1,1);
          if (modifierSnode=nil) or (modifierSnode.nType in [ntTrimTrailing,ntTrimBoth]) then //assumes boolean short-circuiting
            while (length(s)>0) and (s[length(s)]=s2) do //assumes boolean short-circuiting
              delete(s,length(s),1); //make faster - e.g. use dec/counter?
          n.dwidth:=length(s); //in case higher operator needs this, e.g. concat
          if n.dType in [ctBlob,ctClob] then
          begin
            b.rid.sid:=0; //i.e. in-memory blob
            b.rid.pid:=pageId(pchar(s)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
            b.len:=length(s); //use stored length in case blob contains #0
            result:=tuple.SetBlob(st,outCref,b,snull);
          end
          else
            result:=tuple.SetString(outCref,pchar(s),snull);
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntTrim}
      ntCharLength,ntOctetLength:
      begin
        //Note: in future char_length may be less than octet_length, e.g. unicode
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);

          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            //Note: we don't need to read the blob to find its length since we store it in the row
            if snull then
              v:=0
            else
              v:=b.len;
          end
          else
          begin
            result:=tempTuple.GetString(0,s,snull); //store result
            if snull then s:='';
            v:=length(s);
          end;
          if result<>ok then exit;

          {Return result}
          result:=tuple.SetNumber(outCref,v,snull);
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntCharLength,ntOctetLength}
      ntLower,ntUpper:
      begin
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);

          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          if tempTuple.fColDef[0].dataType in [ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            if not snull then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s:='';
                  setLength(s,b.len);
                  strMove(pchar(s),pchar(bData.rid.pid),b.len);
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s,snull); //store result
          if result<>ok then exit;

          {Return result}
          if snull then s:='';
          case n.ntype of
            ntLower: s:=lowercase(s);
            ntUpper: s:=uppercase(s);
          //else assertion!
          end;
          n.dwidth:=length(s); //in case higher operator needs this, e.g. concat
          if n.dType in [ctBlob,ctClob] then
          begin
            b.rid.sid:=0; //i.e. in-memory blob
            b.rid.pid:=pageId(pchar(s)); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
            b.len:=length(s); //use stored length in case blob contains #0
            result:=tuple.SetBlob(st,outCref,b,snull);
          end
          else
            result:=tuple.SetString(outCref,pchar(s),snull);
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntLower,ntUpper}
      ntPosition:
      begin
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          tempTuple.ColCount:=1;
          tempTuple.clear(st);

          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            if not snull then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s:='';
                  setLength(s,b.len);
                  strMove(pchar(s),pchar(bData.rid.pid),b.len);
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s,snull); //store result
          if result<>ok then exit;

          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.leftChild.dtype,n.rightChild.leftChild.dwidth{0},n.rightChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,s2null);
            if not s2null then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s2:='';
                  setLength(s2,b.len);
                  strMove(pchar(s2),pchar(bData.rid.pid),b.len);
                  
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s2,s2null); //store result
          if result<>ok then exit;

          if snull then s:='';
          if s2null then s2:='';

          v:=pos(s,s2);
          if (length(s)=0) and not(snull){does null/'' differ properly?} then v:=1;

          result:=tuple.SetNumber(outCref,v,s2null{ or snull});
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntPosition}
      ntSubstring:
      begin
        {We need a temporary area because we can only write to the output slot
         once (i.e. we are simply appending to build the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          
          tempTuple.ColCount:=1;
          tempTuple.clear(st);

          tempTuple.SetColDef(0,1,seInternal,0,n.leftChild.leftChild.dtype,n.leftChild.leftChild.dwidth{0},n.leftChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type (unlikely for strings?)
          {evaluate left expression}
          result:=EvalScalarExp(st,iter,n.leftChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          
          if tempTuple.fColDef[0].dataType in [ctBlob,ctClob] then
          begin
            tempTuple.GetBlob(0,b,snull);
            if not snull then
              try
                if tempTuple.copyBlobData(st,b,bData)>=ok then 
                                                     //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                begin
                  s:='';
                  setLength(s,b.len);
                  strMove(pchar(s),pchar(bData.rid.pid),b.len);
                  
                end;
              finally
                tempTuple.freeBlobData(bData);
              end; {try}
          end
          else
            result:=tempTuple.GetString(0,s,snull); //store result
          if result<>ok then exit;

          //speed: faster if we work with integers if this is possible...
          //if both sub-expressions return integers then return an integer
          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.leftChild.dtype,n.rightChild.leftChild.dwidth{0},n.rightChild.leftChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type - is this still true/needed?
          {evaluate right left expression}
          result:=EvalScalarExp(st,iter,n.rightChild.leftChild,tempTuple,0,aggregate,useOldValues);
          if result<>ok then exit;
          tempTuple.preInsert; //prepare buffer
          result:=tempTuple.GetNumber(0,v,vnull); //store result
          if result<>ok then exit; //abort if not a number

          v2null:=False;
          v2:=(length(s)-v)+1; //default to all of right portion
          if n.rightChild.rightChild<>nil then
          begin //we have a specified length
            tempTuple.clear(st);
            tempTuple.SetColDef(0,1,seInternal,0,n.rightChild.rightChild.dtype,n.rightChild.rightChild.dwidth{0},n.rightChild.rightChild.dscale{0},'',True); //need to reset because previous Eval may have changed its type - is this still true/needed?
            {evaluate right right expression}
            result:=EvalScalarExp(st,iter,n.rightChild.rightChild,tempTuple,0,aggregate,useOldValues);
            if result<>ok then exit;
            tempTuple.preInsert; //prepare buffer
            result:=tempTuple.GetNumber(0,v2,v2null); //store result
            if result<>ok then exit; //abort if not a number
          end;

          {Return result}
          n.dwidth:=trunc(v2); //in case higher operator needs this, e.g. concat
          if n.dType in [ctBlob,ctClob] then
          begin
            b.rid.sid:=0; //i.e. in-memory blob
            b.rid.pid:=pageId(pchar(copy(s,trunc(v),trunc(v2)))); //pass syntax data pointer as blob source in memory //note: assumes will remain while blob remains!
            //use v2 directly as len: speed
            b.len:=length(copy(s,trunc(v),trunc(v2))); //use stored length in case blob contains #0
            result:=tuple.SetBlob(st,outCref,b,snull);
          end
          else
            result:=tuple.SetString(outCref,pchar(copy(s,trunc(v),trunc(v2))),snull);
          if result<>ok then exit;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntSubstring}

      //note this code is replicated in uIterInsert
      ntNextSequence:
      begin
        {Get next generator value}
        //save this reference once the lookup's been done
        result:=getOwnerDetails(st,n.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,s,schema_Id,s2,auth_id);
        if result<>ok then
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed to find sequence owner',[nil]),vDebugError);
          {$ENDIF}
          case result of
            -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
            -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
          end; {case}
          result:=fail;
          exit; //abort
        end;

        s:=n.leftChild.rightChild.idVal;

        //todo lookup the generator once during pre-evaluation & then here = faster
        tempInt2:=0; //lookup by name
        result:=Ttransaction(st.owner).db.getGeneratorNext(st,schema_Id,s,tempInt2{genId},tempInt);
        if result<>ok then
        begin
          if tempInt2=0 then //=not found
            st.addError(seSyntaxUnknownSequence,format(seSyntaxUnknownSequenceText,[s]));
          exit; //abort
        end;

        {Store this as the current value for this sequence for this transaction so it can be re-used/referenced}
        Ttransaction(st.owner).SetLastGeneratedValue(tempInt2,tempInt);

        result:=tuple.SetNumber(outCref,tempInt,False); //assume never null
        if result<>ok then exit;
      end; {ntNextSequence}
      ntLatestSequence:
      begin
        {Get latest generator value}
        //todo save this reference once the lookup's been done
        if getOwnerDetails(st,n.leftChild.leftChild,'',Ttransaction(st.owner).schemaName,catalog_Id,s,schema_Id,s2,auth_id)<>ok then
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed to find sequence owner',[nil]),vDebugError);
          {$ENDIF}
          case result of
            -2: st.addError(seUnknownCatalog,format(seUnknownCatalogText,['']));
            -3: st.addError(seSyntaxUnknownSchema,format(seSyntaxUnknownSchemaText,['']));
          end; {case}
          result:=fail;
          exit; //abort
        end;

        s:=n.leftChild.rightChild.idVal;

        //todo lookup the generator once during pre-evaluation & then here = faster
        (* code copied from TDB.getGeneratorNext
         maybe we need a Tgenerator class? since we find(~open), create(~createNew) etc.
         or at least put this lookup into a routine: will be needed also by grant etc.
        *)
        {find generatorID for s}
        tempInt2:=0; //not found
        if Ttransaction(st.owner).db.catalogRelationStart(st,sysGenerator,sysGeneratorR)=ok then
        begin
          try
            if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)=ok then
              try
              repeat
              {Found another matching generator for this name}
              with (sysGeneratorR as TRelation) do
              begin
                fTuple.GetInteger(ord(sg_Schema_id),tempInt,vnull);
                if tempInt=schema_Id then
                begin
                  fTuple.GetInteger(ord(sg_Generator_Id),tempInt2,vnull);
                  //already got generatorName
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Found generator relation %s in %s (with generator-id=%d)',[s,sysGenerator_table,tempInt2]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                  result:=ok;
                end;
                //else not for our schema - skip & continue looking
              end; {with}
              until (tempInt2<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysGeneratorR,ord(sg_Generator_name),s)<>ok);
                    //todo stop once we've found a generator_id with our schema_Id, or there are no more matching this name
              finally
                if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysGeneratorR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysGenerator)]),vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}
            //else generator not found
          finally
            if Ttransaction(st.owner).db.catalogRelationStop(st,sysGenerator,sysGeneratorR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysGenerator)]),vError);
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        end
        else
        begin  //couldn't get access to sysGenerator
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysGenerator),s]),vDebugError);
          {$ENDIF}
          result:=fail;
          exit; //abort
        end;

        if tempInt2<>0 then
        begin //found
          {Store the latest value for this sequence for this transaction (null if none so far)}
          if Ttransaction(st.owner).GetLastGeneratedValue(tempInt2,tempInt)<>ok then
            result:=tuple.SetNull(outCref)
          else
            result:=tuple.SetNumber(outCref,tempInt,False); //assume never null
          if result<>ok then exit;
        end;
      end; {ntLatestSequence}
      //is this the right/best place for such niladic functions?
      //maybe we could/should evaluate them here as well? no need!
      // keep this list in sync with iterInsert defaults!
      ntCurrentUser:
      begin
        n.dwidth:=length(Ttransaction(st.owner).authName); //in case higher operator needs this, e.g. concat
        result:=tuple.SetString(outCref,pchar(Ttransaction(st.owner).authName),False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentUser}
      ntSessionUser:
      begin
        n.dwidth:=length(Ttransaction(st.owner).authName); //in case higher operator needs this, e.g. concat
        result:=tuple.SetString(outCref,pchar(Ttransaction(st.owner).authName),False); //assume never null
        if result<>ok then exit;        
      end; {ntSessionUser}
      ntSystemUser:
      begin
        if getSystemUser(st,s)=ok then
        begin
          //should setLength(s,length(s)) again?
          n.dwidth:=length(s); //in case higher operator needs this, e.g. concat
          result:=tuple.SetString(outCref,pchar(s),False); //assume never null
          if result<>ok then exit;
        end
        else
        begin
          //return getlasterror?
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed retrieving system user',[nil]),vError);
          {$ELSE}
          ;
          {$ENDIF}
          result:=-3;
          exit; //todo: review behaviour for this user error
        end;
      end; {ntSystemUser}
      ntCurrentAuthId:
      begin
        result:=tuple.SetInteger(outCref,Ttransaction(st.owner).authID,False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentAuthId}
      ntCurrentCatalog:
      begin
        n.dwidth:=length(Ttransaction(st.owner).catalogName); //in case higher operator needs this, e.g. concat
        result:=tuple.SetString(outCref,pchar(Ttransaction(st.owner).catalogName),False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentCatalog}
      ntCurrentSchema:
      begin
        n.dwidth:=length(Ttransaction(st.owner).schemaName); //in case higher operator needs this, e.g. concat
        result:=tuple.SetString(outCref,pchar(Ttransaction(st.owner).schemaName),False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentSchema}

      ntCurrentDate:
      begin
        result:=tuple.SetDate(outCref,Ttransaction(st.owner).currentDate,False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentDate}
      ntCurrentTime:
      begin
        //todo +1 if fp
        result:=tuple.SetTime(outCref,Ttransaction(st.owner).currentTime,False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentTime}
      ntCurrentTimestamp:
      begin
        //todo +1 if fp
        result:=tuple.SetTimestamp(outCref,Ttransaction(st.owner).currentTimestamp,False); //assume never null
        if result<>ok then exit;
      end; {ntCurrentTimestamp}

      ntSQLState:
      begin
        if Ttransaction(st.owner).sqlstateSQL_NO_DATA then
          result:=tuple.SetString(outCref,pchar(SQL_NO_DATA),False) //assume never null
        else //should return latest error state?
          result:=tuple.SetString(outCref,pchar(SQL_SUCCESS),False); //assume never null
        if result<>ok then exit;
      end; {ntSQLState}


      ntTableExp:
      begin //this is a table expression (i.e. a row subquery => single row only)
        //sub-select returning 1 row/1 column (phew!)- call Process()!
        // also, if not correlate may be able to call once before start...
        {test this copes with all valid syntax}

        //we should createTableExp/CreatePlan once during CompleteScalarExp (or Processor)
        // (and then determine whether it's a correlated subquery or not)
        // & then either execute it the first time only here (if non-correlated)
        // or execute it each time here (if correlated)
        //- so we need a way to hook a ptree to a ntTableExp syntax node...
        //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

        //Note: here (being scalar) if sub-plan is not correlated, then I don't think we need
        // to restart it each time, just refer to the current tuple - i.e. should be only 1 tuple.

        {We need a temporary area because the subquery can only overwrite a whole (empty!) tuple
         (i.e. we must then append the result to the result tuple)}
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tempTuple:=iter.lTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
          tempTuple:=TTuple.create(nil);
        try
          
          tempTuple.ColCount:=1;
          tempTuple.clear(st);
          tempTuple.SetColDef(0,1,seInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True);
          {evaluate sub-select}

          if n.ptree<>nil then
          begin
            result:=RowSubquery(st,(n.ptree as TIterator),tempTuple); //don't re-do if not correlated: use n.ptree.ituple instead of tempTuple...
            //Note: the output tuple has now already been preInsert'ed
            //TODO: error if >1 row returned!
            // also if >1 column! (?check)
            if result=ok then
            begin
              result:=tuple.copyColDef(outCref,tempTuple,0);
              if result<>ok then exit; //abort if child aborts
              result:=tuple.copyColDataDeep(outCref,st,tempTuple,0,false); 
                                                                     //but in future we'll leave the plan until next time => shallow copy might be ok! -speed
              if result<>ok then exit; //abort if child aborts
            end;
            //else zeroise or something?
          end;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tempTuple=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tempTuple:=nil; //remove no need: speed
          end
          else
            tempTuple.free;
        end; {try}
      end; {ntTableExp}
    else
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unrecognised scalar expression node (%d)',[ord(n.nType)]),vDebugWarning); //fill in
      {$ELSE}
      ;
      {$ENDIF}
    end; {case}
  end;
end; {EvalScalarExp}
{end of single evaluation routine}


function EvalRowConstructor(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;tuple:TTuple;aggregate:Taggregation;predefined:boolean;useOldValues:boolean):integer;
{Returns a row constructor (tuple)
 IN:
          st              the statement
          iter            the current iterator (links to iTuple) to take column values from
          snode           the syntax node of the rowConstructor node
          aggregate       todo! True=recurse into aggregate function expressions to calculate them
                           (used in having(=grouping) calculation)
                          False=use the value stored against the aggregate function and don't recurse
                           (used in projection after a grouping & final having test)
          predefined      True=the output tuple is already formatted (e.g. retain any alias details for iterSyntaxRelation)
                          False=format the output tuple from the syntax node(s)
 OUT:     tuple           a formatted tuple with data in its read-buffer
                          Note: tuple must be created by caller

 This is a construct from the SQL grammar that can be one of:
      a scalar expression
      a tuple of scalar expressions (a,b...)
      a table expressions (which can be a sub-select)
        - this is limited by SQL to return a single-row (phew!) = 'rowSubquery'
          so we can execute the sub-select, check count=1 and return the 1st row
          Note: (Guide to SQL standard p168) no rows=behaves as a row of nulls

 Assumes:
   the sub-tree has already been 'completed'
}
const
  routine=':evalRowConstructor';
  rcInternal='sys/rc'; //temp column name
var
  n,nhead:TSyntaxNodePtr;
  nextCol,count:colRef;
begin
  result:=ok;

  if snode.nType=ntRowConstructor then
  begin
    if snode.leftChild=nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('row-constructor (%d) is incomplete - missing left-child: probably a partial case-of node...continuing...',[ord(snode.nType)]),vDebugError); //assertion
      {$ELSE}
      ;
      {$ENDIF}
      exit; //note: result=ok!
    end;

    snode:=snode.leftChild;
    nextCol:=0; //we create a column for each scalar_exp
    if snode.nType=ntTableExp then
    begin //this is a table expression (i.e. a row subquery => single row only)
      //todo we should createTableExp/CreatePlan once during CompleteRowConstructor (or Processor)
      // (and then determine whether it's a correlated subquery or not)
      // & then either execute it the first time only here (if non-correlated)
      // or execute it each time here (if correlated)
      //- so we need a way to hook a ptree to a ntTableExp syntax node...
      //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

      if snode.ptree<>nil then
      begin
        result:=RowSubquery(st,(snode.ptree as TIterator),tuple);
        //Note: the output tuple has now already been preInsert'ed
      end;
    end
    else
    begin //this is a scalar, or scalar list
      if not predefined then
      begin //we need to define the output tuple format
        {We first count each node in the chain to set the tuple size
         - improve?}
        count:=0;
        nhead:=snode;
        while nhead<>nil do
        begin
          inc(count);
          nhead:=nhead.NextNode;
        end;
        tuple.ColCount:=count;
      end;
      tuple.clear(st);
      {For each node in the potential chain (for scalar_exp_commalist)}
      nhead:=snode;
      n:=nhead;
      while n<>nil do
      begin
        {Take the next operator, may involve evaluating further sub-trees}
        n:=n.leftChild; //move to char exp root
        if not predefined then
          tuple.SetColDef(nextCol,nextCol+1,rcInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True)
        else
        begin
          {In some rare cases (e.g. null in 1st row, followed by 0 or '' in subsequent rows: or case results...)
           the column type can change per syntax relation row (not really change, but we don't lookahead so <null> has an arbitrary type)
           so even though we keep the tuple format (column aliases etc.) we do still need to refresh the column types
           //only do this if 1st row=null(?) :speed
          }
          tuple.fColDef[nextCol].dataType:=n.dtype;
          tuple.fColDef[nextCol].width:=n.dwidth;
          tuple.fColDef[nextCol].scale:=n.dscale;
        end;

        result:=EvalScalarExp(st,iter,n,tuple,nextCol,aggregate,useOldValues);
        if result<>ok then exit;
        inc(nextCol);
        nhead:=nhead.nextNode;
        n:=nhead; //if any
      end;
    end;
    tuple.preInsert; //prepare buffer
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Root is not a row-constructor (%d)',[ord(snode.nType)]),vDebugError); //assertion
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end;
end; {EvalRowConstructor}

function EvalCondPredicate(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;var res:TriLogic;aggregate:Taggregation;useOldValues:boolean):integer;
{Evaluate a sub-tree of a condition
 (condExp/condFactor/simpleCond.comparisonCond)
 IN      :
             st          the statement
             iter        the current iterator (links to iTuple) to take column values from
             snode       the syntax sub-tree containing the expression
             aggregate   todo! True=recurse into aggregate function expressions to calculate them
                          (used in having(=grouping) calculation)
                         False=use the value stored against the aggregate function and don't recurse
                          (used in projection after a grouping & final having test)
 OUT     :   res      the 3-valued logic result

 RETURNS :   ok, or fail if error

 Assumes:
   the sub-tree has already been 'completed'
}
const
  routine=':evalCondPredicate';
  rcInternal='sys/EP'; //system column reference
var
  res1,res2:TriLogic;
  tuple1,tuple2:TTuple;
  noMore:boolean;
  {for sub-select}
  ptree:TIterator;        //plan root

  n,nhead:TSyntaxNodePtr;

  {for match unique, partial, full flags}
  matchUnique:integer;
  matchPartial,matchFull:boolean;
  matchShortCircuit:boolean; //skip match loop in some null-related circumstances
  cl:colRef;
  resNull:boolean;
begin
  result:=ok;
  res:=isUnknown;

  {Take the next operator, may involve evaluating further sub-trees}
  case snode.nType of
    ntOR:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('OR (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=EvalCondPredicate(st,iter,snode.leftChild,res1,aggregate,useOldValues); //left operand
      if result<>ok then exit; //abort if child aborts
      result:=EvalCondPredicate(st,iter,snode.rightChild,res2,aggregate,useOldValues); //right operand
      if result<>ok then exit; //abort if child aborts
      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('OR using %s and %s',[TriToStr(res1),TriToStr(res2)]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      res:=TriOR(res1,res2);
    end; {ntOR}
    {Note we added the ntAND later on, since some conditions will not be CNF'd into separate sub-trees
     e.g. CASE expressions.
     Although we should very rarely see this. //check we don't!
    }
    ntAND:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('AND (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=EvalCondPredicate(st,iter,snode.leftChild,res1,aggregate,useOldValues); //left operand
      if result<>ok then exit; //abort if child aborts
      result:=EvalCondPredicate(st,iter,snode.rightChild,res2,aggregate,useOldValues); //right operand
      if result<>ok then exit; //abort if child aborts
      {$IFDEF DEBUGDETAIL3}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('AND using %s and %s',[TriToStr(res1),TriToStr(res2)]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      res:=TriAND(res1,res2);
    end; {ntAND}
    ntNOT:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('NOT (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=EvalCondPredicate(st,iter,snode.leftChild,res1,aggregate,useOldValues); //left operand
      if result<>ok then exit; //abort if child aborts
      res:=TriNOT(res1);
    end; {ntNOT}
    ntEqual,ntLT,ntGT,ntLTEQ,ntGTEQ,ntNotEqual,ntEqualOrNull{internal}:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('=/</>/<=/>=/<> (%p)',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      if snode.rightChild.nType=ntTableExp then
      begin //must be any/all (flag is chained to table-exp, one level down on right)
        case snode.rightChild.nextNode.nType of
          ntAll:
          begin
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('ALL (%p)',[snode.rightChild.nextNode]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            //todo move these into a op-comparison header routine
            if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
            begin //use cached tuples
              tuple1:=iter.lTuple;
              iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
            end
            else
              tuple1:=TTuple.create(nil);
            try
              result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
              if result<>ok then exit; //abort if child aborts;

              //todo we should createTableExp/CreatePlan once during CompleteCondPredicate (or Processor)
              // (and then determine whether it's a correlated subquery or not)
              // & then either execute it the first time only here (if non-correlated)
              // or execute it each time here (if correlated)
              //- so we need a way to hook a ptree to a ntTableExp syntax node...
              //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

              //here, if non-correlated, I think we eventually need to materialise the result
              //set: then subsequent searches can just cursor.restart instead of iter.start - speed

              if snode.rightChild.ptree<>nil then
              begin
                ptree:=(snode.rightChild.ptree as TIterator); 
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Executing (sub)query %p',[@ptree]),vDebugMedium);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {Note: this start doesn't need a prePlan - it was done by CompleteCondPredicate
                   - *** this only works if iter does not need to be so dynamic...
                  }
                  if ptree.start=ok then
                    try
                      noMore:=False;
                      res:=isTrue; //default to true and abort when/if found to be false (cos we're looking for 'all')
                      while not(noMore) and (res=isTrue) do
                      begin
                        result:=ptree.next(noMore);
                        if result<>ok then
                        begin
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,'Aborting execution',vError);
                          {$ELSE}
                          ;
                          {$ENDIF}
                          //fail/exit?
                          break; //don't duplicate error for each tuple!
                        end
                        else
                        begin
                          if not noMore then
                          begin
                            case snode.nType of
                              ntEqual:   result:=CompareTuples(st,tuple1,ptree.iTuple,compResEQ,res);
                              ntLT:      result:=CompareTuples(st,tuple1,ptree.iTuple,compResLT,res);
                              ntGT:      result:=CompareTuples(st,tuple1,ptree.iTuple,compResGT,res);
                              ntLTEQ:    result:=CompareTuples(st,tuple1,ptree.iTuple,compResLTEQ,res);
                              ntGTEQ:    result:=CompareTuples(st,tuple1,ptree.iTuple,compResGTEQ,res);
                              ntNotEqual:result:=CompareTuples(st,tuple1,ptree.iTuple,compResNEQ,res);
                            else
                              {$IFDEF DEBUG_LOG}
                              log.add(st.who,where+routine,format('All: Operator not caught %d',[ord(snode.nType)]),vAssertion);
                              {$ELSE}
                              ;
                              {$ENDIF}
                            end; {case}
                            if result<>ok then
                            begin
                              st.addError(seSyntaxInvalidComparison,seSyntaxInvalidComparisonText);
                              exit; //abort if child aborts;
                            end;
                          end;
                        end;
                        {$IFDEF DEBUGDETAIL2}
                        if res=isFalse then
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('ALL mis-matched: %s, %s',[tuple1.Show(st),ptree.iTuple.show(st)]),vDebugLow);
                          {$ELSE}
                          ;
                          {$ENDIF}
                        {$ENDIF}
                      end; {while}
                    finally
                      ptree.stop;
                    end; {try}
                  //else abort
              end;
            finally
              if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
              begin //release cached tuples
                iter.lrInUse:=false;
                tuple1:=nil; //remove no need: speed
              end
              else
                tuple1.free;
            end; {try}
          end; {ntAll}
          ntAny: //todo merge code with ALL?
          begin
            {$IFDEF DEBUGDETAIL2}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('ANY (%p)',[snode.rightChild.nextNode]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            //todo move these into a op-comparison header routine
            if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
            begin //use cached tuples
              tuple1:=iter.lTuple;
              iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
            end
            else
              tuple1:=TTuple.create(nil);
            try
              result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
              if result<>ok then exit; //abort if child aborts;

              //we should createTableExp/CreatePlan once during CompleteCondPredicate (or Processor)
              // (and then determine whether it's a correlated subquery or not)
              // & then either execute it the first time only here (if non-correlated)
              // or execute it each time here (if correlated)
              //- so we need a way to hook a ptree to a ntTableExp syntax node...
              //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

              //here, if non-correlated, I think we eventually need to materialise the result
              //set: then subsequent searches can just cursor.restart instead of iter.start - speed

              if snode.rightChild.ptree<>nil then
              begin
                ptree:=(snode.rightChild.ptree as TIterator); 
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Executing (sub)query %p',[@ptree]),vDebugMedium);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  {Note: this start doesn't need a prePlan - it was done by CompleteCondPredicate
                   - *** this only works if iter does not need to be so dynamic...
                  }
                  if ptree.start=ok then
                    try
                      noMore:=False;
                      res:=isFalse; //default to false and abort when/if found to be true (cos we're looking for 'any')
                      while not(noMore) and (res=isFalse) do
                      begin
                        result:=ptree.next(noMore);
                        if result<>ok then
                        begin
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,'Aborting execution',vError);
                          {$ELSE}
                          ;
                          {$ENDIF}
                          //fail/exit?
                          break; //don't duplicate error for each tuple!
                        end
                        else
                        begin
                          if not noMore then
                          begin
                            {$IFDEF DEBUG_LOG}
                            {$ELSE}
                            ;
                            {$ENDIF}
                            case snode.nType of
                              ntEqual:   result:=CompareTuples(st,tuple1,ptree.iTuple,compResEQ,res);
                              ntLT:      result:=CompareTuples(st,tuple1,ptree.iTuple,compResLT,res);
                              ntGT:      result:=CompareTuples(st,tuple1,ptree.iTuple,compResGT,res);
                              ntLTEQ:    result:=CompareTuples(st,tuple1,ptree.iTuple,compResLTEQ,res);
                              ntGTEQ:    result:=CompareTuples(st,tuple1,ptree.iTuple,compResGTEQ,res);
                              ntNotEqual:result:=CompareTuples(st,tuple1,ptree.iTuple,compResNEQ,res);
                            else
                              {$IFDEF DEBUG_LOG}
                              log.add(st.who,where+routine,format('Any: Operator not caught %d',[ord(snode.nType)]),vAssertion);
                              {$ELSE}
                              ;
                              {$ENDIF}
                            end; {case}
                            if result<>ok then
                            begin
                              st.addError(seSyntaxInvalidComparison,seSyntaxInvalidComparisonText);
                              exit; //abort if child aborts;
                            end;
                          end;
                        end;
                        {$IFDEF DEBUGDETAIL2}
                        if res=isTrue then
                          {$IFDEF DEBUG_LOG}
                          log.add(st.who,where+routine,format('ANY matched: %s, %s',[tuple1.Show(st),ptree.iTuple.show(st)]),vDebugLow);
                          {$ELSE}
                          ;
                          {$ENDIF}
                        {$ENDIF}
                      end; {while}
                    finally
                      ptree.stop;
                    end; {try}
                  //else abort
              end;
            finally
              if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
              begin //release cached tuples
                iter.lrInUse:=false;
                tuple1:=nil; //remove no need: speed
              end
              else
                tuple1.free;
            end; {try}
          end; {ntAny}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Operator modifier not caught %d',[ord(snode.rightChild.nextNode.nType)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
        end; {case}
      end
      else
      begin //standard
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tuple1:=iter.lTuple;
          tuple2:=iter.rTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
        begin
          //todo move these into a op-comparison header routine
          tuple1:=TTuple.create(nil);
          tuple2:=TTuple.create(nil);
        end;
        try
          result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
          if result<>ok then exit; //abort if child aborts;
          result:=EvalRowConstructor(st,iter,snode.rightChild,tuple2,aggregate,false,useOldValues);
          if result<>ok then exit; //abort if child aborts;
          case snode.nType of
            ntEqual:   begin
                         result:=CompareTuples(st,tuple1,tuple2,compResEQ,res);
                         {Note: kludge to allow index-FK-constraint WHERE clauses to match
                                at higher iterator levels (i.e. prevent filtering in iterSelect after index key 'match'):
                                  We basically coerce WHERE...col=null to give a boolean result
                                  (normally this would/should be a syntax error before we get here
                                   otherwise we'd mis-interpret: 7=null, null=null etc.)
                                  Note: anything else involving null still returns isUnknown
                                  Note+: yes: system generated implicit WHERE conditions, e.g. USING (a) -> A.a=B.a
                                  Note: this is unorthogonal since we don't do the same for <> etc.
                                  Note: only way this can be used is via internal bending (we protect by checking st=sysStmt2)
                                  Note: and then only if equalNulls=True, since unique checking needs null=null to evaluate to false (to allow multiple nulls)
                                  Note: the alternative would be to:
                                          always remove pushed-down SARGs from their original place
                                          then the original index match would not be filtered by a further iterSelect
                                          (this removal should happen anyway (but doesn't just yet) &
                                           if we did take this approach & the FK index was ever missing
                                           then we'd fail finding the tuples in the first place!
                                           So this kludge is more robust (and kind of fills an SQL deficiency anyway!).
                                          )
                         }
                         if (st.stmtType=stSystemConstraint) and (res=isUnknown) and (tuple1.ColCount=1) then
                         begin //a null is involved - is this a 'special' null=null system-allowed expression?
                           if st.equalNulls then //we must be checking a FK constraint, so use the kludge
                           begin
                             result:=tuple2.ColIsNull(0,resNull); //2 first: more likely to write colnull=X than X=colnull (& so X is not null) -speed
                             if result<>ok then exit; //abort if compare fails
                             if resNull then
                             begin
                               result:=tuple1.ColIsNull(0,resNull);
                               if result<>ok then exit; //abort if compare fails
                               if resNull then res:=isTrue; //i.e. flip from isUnknown to isTrue if '(null)=(null)'
                             end;
                           end;
                           //else this feature was not turned on
                         end;
                       end;
            ntEqualOrNull: begin //maybe we should just ignore these comparisons? Since merge-join will have applied them already... but not nested-loop etc.!
                             //Note: we could probably revert back to using ntEqual & test for both child column nodes being flagged as systemNode?
                             //           although join-on now uses this & doesn't neccessarily have nodes that can be flagged, e.g. col=7?
                             result:=CompareTuples(st,tuple1,tuple2,compResEQ,res);
                             if (res=isUnknown) then
                             begin
                               {Since this is an internally generated operator, we treat unknown as true (e.g. X=null, null=X, null=null etc.)
                                e.g. for optimisation of outer-join-using via WHERE clause additions: the merge-join will have already matched NULLs as valid result rows}
                               res:=isTrue; //i.e. flip from isUnknown to isTrue
                             end;
                           end;
            ntLT:      result:=CompareTuples(st,tuple1,tuple2,compResLT,res);
            ntGT:      result:=CompareTuples(st,tuple1,tuple2,compResGT,res);
            ntLTEQ:    result:=CompareTuples(st,tuple1,tuple2,compResLTEQ,res);
            ntGTEQ:    result:=CompareTuples(st,tuple1,tuple2,compResGTEQ,res);
            ntNotEqual:result:=CompareTuples(st,tuple1,tuple2,compResNEQ,res);
          else
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Operator not caught %d',[ord(snode.nType)]),vAssertion);
            {$ELSE}
            ;
            {$ENDIF}
          end; {case}
          if result<>ok then
          begin
            st.addError(seSyntaxInvalidComparison,seSyntaxInvalidComparisonText);
            exit; //abort if child aborts;
          end;
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tuple1:=nil; tuple2:=nil; //remove no need: speed
          end
          else
          begin
            tuple2.free;
            tuple1.free;
          end;
        end; {try}
      end;
    end; {ntEqual, etc.}
    ntExists: //todo maybe merge code with ALL/ANY? (better if separate - there is a SQL design bug with WHERE...EXISTS)
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('EXISTS (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Note: we can ignore the select list here
       - * does not mean all and can/should be replaced by 1 or something for speed
       - or maybe we can drop the whole IterProject layer and just use the raw IterSelect?
       For now, it's up to the user to make it fast
      }
      //todo we should createTableExp/CreatePlan once during CompleteCondPredicate (or Processor)
      // (and then determine whether it's a correlated subquery or not)
      // & then either execute it the first time only here (if non-correlated)
      // or execute it each time here (if correlated)
      //- so we need a way to hook a ptree to a ntTableExp syntax node...
      //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

      //here, if non-correlated, I think we eventually need to materialise the result
      //set: then subsequent searches can just cursor.restart instead of iter.start - speed
      if snode.leftChild.ptree<>nil then
      begin
        ptree:=(snode.leftChild.ptree as TIterator);
          {Note: planRoot may already have been started (to complete the syntax trees)
                 this shouldn't matter to us: restarting shouldn't re-complete so we're ok}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Executing (sub)query %p',[@ptree]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          {Note: this start doesn't need a prePlan - it was done by CompleteCondPredicate
           - *** this only works if iter does not need to be so dynamic...
          }
          if ptree.start=ok then
            try
              noMore:=False;
              res:=isFalse; //default to false and abort when/if found to be true (cos we're looking for any exists)
              while not(noMore) and (res=isFalse) do
              begin
                result:=ptree.next(noMore);
                if result<>ok then
                begin
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,'Aborting execution',vError);
                  {$ELSE}
                  ;
                  {$ENDIF}
                  //fail/exit?
                  break; //don't duplicate error for each tuple!
                end
                else
                begin
                  if not noMore then
                  begin
                    res:=isTrue; //we found a row  //Note: subtle SQL design-flaw/bug because TriValue & TwoValue are being mixed...
                  end;
                end;
                {$IFDEF DEBUGDETAIL2}
                if res=isTrue then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('EXISTS matched: %s',[ptree.iTuple.show(st)]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
                {$ENDIF}
              end; {while}
            finally
              ptree.stop;
            end; {try}
          //else abort
      end;
    end; {ntExists}
    ntMatch:
    begin
      //note: this code is more or less taken from (based on at least) the =Any code
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('MATCH (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Set up any 'unique' limiting clause, and check for other flags}
      matchUnique:=0; //default to no unique clause
      matchPartial:=False;
      matchFull:=False;
      n:=snode.rightChild;
      while n.nextNode<>nil do
      begin
        n:=n.nextNode;
        if n.nType=ntUNIQUE then
        begin
          matchUnique:=1; //we increment this once for the 1st match, so we can tell if we match multiple rows=failed
        end;
        {Note: these next two are mutually exclusive, but this is checked in
         an earlier phase so we can assume we'll only ever get at most 1 of them here}
        if n.nType=ntPARTIAL then
        begin
          matchPartial:=True;
        end;
        if n.nType=ntFULL then
        begin
          matchFull:=True;
        end;
      end; {while}

      if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
      begin //use cached tuples
        tuple1:=iter.lTuple;
        iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
      end
      else
        tuple1:=TTuple.create(nil);
      try
        result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
        if result<>ok then exit; //abort if child aborts;

        //todo we should createTableExp/CreatePlan once during CompleteCondPredicate (or Processor)
        // (and then determine whether it's a correlated subquery or not)
        // & then either execute it the first time only here (if non-correlated)
        // or execute it each time here (if correlated)
        //- so we need a way to hook a ptree to a ntTableExp syntax node...
        //- this would remove the need for ptree in the Tstmt...use sroot.ptree instead

        //here, if non-correlated, I think we eventually need to materialise the result
        //set: then subsequent searches can just cursor.restart instead of iter.start - speed

        {Note if tuple1 (tl) has all/any nulls - this may affect our matching algorithm
         We check here to avoid having to put this logic inside the match loop}
        matchShortCircuit:=False; //skip match loop if set to True here
        res:=isFalse; //default to false
        cl:=0;
        if matchPartial then
        begin
          {Note if tuple1 (tl) is all nulls}
          result:=compareTupleNull(tuple1,res);
          if result<>ok then exit; //abort if compare fails
          if res=isTrue then matchShortCircuit:=True; //definitely true
        end
        else
        begin
          if matchFull then
          begin
            {Note if tuple1 (tl) is all nulls}
            result:=compareTupleNull(tuple1,res);
            if result<>ok then exit; //abort if compare fails
            if res=isFalse then
            begin
              {if tuple1 (tl) is all non-nulls ...and tl=tr}
              res:=isTrue; //temporary postulate
              while (res=isTrue) and (cl<tuple1.ColCount) do
              begin
                result:=tuple1.ColIsNull(cl,resNull);
                if result<>ok then exit; //abort if compare fails
                if resNull then
                  res:=isFalse; //fail if we find a null
                inc(cl);
              end;
              if res=isFalse then matchShortCircuit:=True; //definitely false
            end
            else
              matchShortCircuit:=True; //definitely true
          end
          else
          begin //neither partial nor full
            {Note if any of tuple1 (tl) is null, return true}
            res:=isFalse; //to start loop
            while (res=isFalse) and (cl<tuple1.ColCount) do
            begin
              result:=tuple1.ColIsNull(cl,resNull);
              if result<>ok then exit; //abort if compare fails
              if resNull then res:=isTrue;
              inc(cl);
            end;
            if res=isTrue then matchShortCircuit:=True; //definitely true
          end;
        end;

        if not matchShortCircuit then
        begin //we were not able to short-circuit by checking for nulls in tuple1
          if snode.rightChild.ptree<>nil then
          begin
            ptree:=(snode.rightChild.ptree as TIterator);
              {Note: planRoot may already have been started (to complete the syntax trees)
                     this shouldn't matter to us: restarting shouldn't re-complete so we're ok}
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Executing (sub)query %p',[@ptree]),vDebugMedium);
              {$ELSE}
              ;
              {$ENDIF}
              {Note: this start doesn't need a prePlan - it was done by CompleteCondPredicate
               - *** this only works if iter does not need to be so dynamic...
              }
              if ptree.start=ok then
                try
                  res:=isFalse; //default to false
                  noMore:=False;
                  while not(noMore) and (res=isFalse) do
                  begin
                    result:=ptree.next(noMore);
                    if result<>ok then
                    begin
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,'Aborting execution',vError);
                      {$ELSE}
                      ;
                      {$ENDIF}
                      //fail/exit?
                      break; //don't duplicate error for each tuple!
                    end
                    else
                    begin
                      if not noMore then
                      begin
                        {$IFDEF DEBUG_LOG}
                        {$ELSE}
                        ;
                        {$ENDIF}
                        result:=MatchTuples(st,tuple1,ptree.iTuple,matchPartial,matchFull,res);
                        if result<>ok then
                        begin
                          st.addError(seSyntaxInvalidComparison,seSyntaxInvalidComparisonText);
                          exit; //abort if child aborts;
                        end;
                        if (res=isTrue) then
                        begin
                          if (matchUnique=2) then
                          begin //unique was specified, but this is the 2nd matching row
                            res:=isFalse; //res had just become isTrue but it's too late
                            matchUnique:=3; //bump so we know for sure that we failed (although just checking isFalse should be enough)
                            noMore:=True; //force early exit
                          end;
                          if (matchUnique=1) then
                          begin //unique was specified, and this is the 1st matching row
                            res:=isFalse; //res had just become isTrue but we need to continue looking because unique was specified (and not an overriding match)
                            matchUnique:=2; //bump so we know if we match another = fail, or not =make isTrue
                          end;
                        end; {res=isTrue}
                      end;
                    end;
                  end; {while}
                  if (matchUnique=2) then res:=isTrue; //we did match 1 but we (may have) had to continue searching to check unique
                finally
                  ptree.stop;
                end; {try}
              //else abort
          end;
        end;
        //else short-circuited: tuple1 had all/some null & it mattered
        {$IFDEF DEBUGDETAIL2}
        if res=isTrue then
          {$IFDEF DEBUG_LOG}
          if ptree<>nil then
            log.add(st.who,where+routine,format('MATCH matched: %s, %s',[tuple1.Show(st),ptree.iTuple.show(st)]),vDebugLow)
          else
            log.add(st.who,where+routine,format('MATCH matched: %s',[tuple1.Show(st)]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
        {$ENDIF}
      finally
        if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
        begin //release cached tuples
          iter.lrInUse:=false;
          tuple1:=nil; //remove no need: speed
        end
        else
          tuple1.free;
      end; {try}
    end; {ntMatch}
    ntIsUnique: //todo maybe merge code with ALL/ANY?
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('UNIQUE (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Note: we can currently only handle simple SELECT c1,c2 FROM table (c1,c2 etc must be a key)
            expressions since we use an index to test for uniqueness
            - this should be fine since we really only use this internally for key constraint checks
       For now, it's up to the user to make it legal (else will error)
      }
      if snode.leftChild.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Testing simple SELECT..FROM (sub)query %p',[@snode.leftChild.atree]),vDebugMedium);
        {$ELSE}
        ;
        {$ENDIF}

        //todo move these tests to Complete routine
        if TAlgebraNodePtr(snode.leftChild.atree)^.anType=antProjection then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  antProjection %p',[@TAlgebraNodePtr(snode.leftChild.atree)^.nodeRef]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
        if TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.anType=antSelection then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  Error: should be no where clause in unique expression',[nil]),vError);
          {$ELSE}
          ;
          {$ENDIF}
          result:=Fail;
          exit; //abort
        end;
        if TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.anType=antRelation then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('  antRelation %p=%s',[@TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.nodeRef,TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.rel.schemaName+'.'+TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.rel.relname]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}

        //todo check rel exists (i.e. not a view/join cos no index (currently - what about future - no reason why not...))

        res:=isFalse; //default

        with TAlgebraNodePtr(snode.leftChild.atree)^.leftChild.rel do
        begin
          {Build key definition to pass to relation}
          //Note: this interferes with any index/scans on the rel (should be fine)
          fTupleKey.clearToNulls(st);
          fTupleKey.CopyTupleDef((snode.leftChild.ptree as TIterator).iTuple); //copy just projected portions = key
          fTupleKey.clearKeyIds(st);
          {Assume key is all projected parts}
          n:=TAlgebraNodePtr(snode.leftChild.atree)^.nodeRef;
          cl:=0;
          while n<>nil do
          begin
            if n.nType=ntSelectAll then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('  Error: should be no * projection unique expression',[nil]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit; //abort
            end;
            if n.ntype=ntSelectItem then
            begin
              if n.leftChild.nType in [ntNumericExp,ntCharacterExp] then
              begin
                if n.leftChild.leftChild.nType=ntColumnRef then
                begin
                  if result<>ok then exit; //abort
                  {The following line sets the next projected tuple column(=key) to its source tuple's column id}
                  fTupleKey.SetKeyId(cl,(n.leftChild.leftChild.cTuple as TTuple).fColDef[(n.leftChild.leftChild.cRef)].id); //next column in key
                  inc(cl);
                end;
                //else error
              end;
              //else error
            end;
            //else error

            n:=n.nextNode;
          end; {while}

          fTupleKey.preInsert;
          {$IFDEF DEBUGDETAIL2}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('%s',[fTupleKey.ShowHeading]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
          {$IFDEF DEBUG_LOG}
          {$ELSE}
          ;
          {$ENDIF}
          {$ENDIF}

          {Call relation to find if unique}
          result:=isUnique(st,nil,res);
        end; {with}

        {$IFDEF DEBUGDETAIL2}
        if res=isTrue then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('UNIQUE matched:',[nil]),vDebugLow);
          {$ELSE}
          ;
          {$ENDIF}
        {$ENDIF}
      end;
      //else assertion/error - not prepared properly!
    end; {ntIsUnique}
    ntIsNull:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('isnull (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      //todo move these into a op-comparison header routine
      if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
      begin //use cached tuples
        tuple1:=iter.lTuple;
        iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
      end
      else
        tuple1:=TTuple.create(nil);
      try
        result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
        if result<>ok then exit; //abort if child aborts;
        case snode.nType of
          ntIsNull:   result:=CompareTupleNull(tuple1,res);
          //Note: the way we convert IS NOT NULL -> NOT(IS NULL)
          //is not always exactly correct for tuples: see Page 242/243
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Operator not caught %d',[ord(snode.nType)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
        end; {case}
        if result<>ok then exit; //abort if child aborts;
      finally
        if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
        begin //release cached tuples
          iter.lrInUse:=false;
          tuple1:=nil; //remove no need: speed
        end
        else
          tuple1.free;
      end; {try}
    end; {ntIsNull}
    ntLike:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('like (%p)',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      //todo move these into a op-comparison header routine
      if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
      begin //use cached tuples
        tuple1:=iter.lTuple;
        tuple2:=iter.rTuple;
        iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
      end
      else
      begin
        tuple1:=TTuple.create(nil);
        tuple2:=TTuple.create(nil);
      end;
      try
        tuple1.ColCount:=1;
        tuple1.clear(st);
        tuple1.SetColDef(0,1,rcInternal,0,snode.leftChild.leftChild.leftChild.dtype,snode.leftChild.leftChild.leftChild.dwidth{0},snode.leftChild.leftChild.leftChild.dscale{0},'',True);
        {To ease the syntax rules, we allow a row-constructor on the LHS, but it must only lead to a character-exp}
        //Note: we also allow ntNumericExp, because the parser doesn't determine the type well enough this early
        if snode.leftChild.leftChild.ntype in [ntCharacterExp,ntNumericExp] then
        begin
          result:=EvalScalarExp(st,iter,snode.leftChild.leftChild.leftChild,tuple1,0,agNone,useOldValues); //Note: agNone is ok here since it can only really be used in the having clause: i.e. after aggregate is calculated
          if result<>ok then exit; //abort if child aborts;
          tuple1.preInsert;
          tuple2.ColCount:=1;
          tuple2.clear(st);
          tuple2.SetColDef(0,1,rcInternal,0,snode.rightChild.leftChild.dtype,snode.rightChild.leftChild.dwidth{0},snode.rightChild.leftChild.dscale{0},'',True);
          result:=EvalScalarExp(st,iter,snode.rightChild.leftChild,tuple2,0,agNone,useOldValues); //Note: agNone is ok here since it can only really be used in the having clause: i.e. after aggregate is calculated
          if result<>ok then exit; //abort if child aborts;
          tuple2.preInsert;
          result:=CompareLike(st,tuple1,tuple2,res);
          if result<>ok then exit; //abort if child aborts;
        end
        else
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Left side of Like must be a character expression',[1]),vError);
          {$ELSE}
          ;
          {$ENDIF}
          result:=Fail;
        end;
      finally
        if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
        begin //release cached tuples
          iter.lrInUse:=false;
          tuple1:=nil; tuple2:=nil; //remove no need: speed
        end
        else
        begin
          tuple2.free;
          tuple1.free;
        end;
      end; {try}
    end; {ntLike}
    ntIs:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('is (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=EvalCondPredicate(st,iter,snode.leftChild,res1,aggregate,useOldValues); //left operand
      if result<>ok then exit; //abort if child aborts
      case snode.rightChild.nType of
        ntTrue:    res2:=isTrue;
        ntFalse:   res2:=isFalse;
        ntUnknown: res2:=isUnknown;
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unknown IS test (%d)',[ord(snode.rightChild.nType)]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
      end; {case}
      if result<>ok then exit; //abort if child aborts
      if res1=res2 then
        res:=isTrue
      else
        res:=isFalse;
    end; {ntIs}
    ntInScalar:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('in (scalar) (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {To ease the syntax rules, we allow a row-constructor on the LHS, but it must only lead to a scalar-exp}
      if snode.leftChild.leftChild.ntype in [ntCharacterExp,ntNumericExp] {etc for all scalars} then
      begin                          //^ this test is not rock solid (would allow a chain of scalars)?
        if (iter<>nil) and not iter.lrInUse and (iter.lTuple<>nil) then
        begin //use cached tuples
          tuple1:=iter.lTuple;
          tuple2:=iter.rTuple;
          iter.lrInUse:=true; //avoid recursion re-use (e.g. case=case)
        end
        else
        begin
          tuple1:=TTuple.create(nil);
          tuple2:=TTuple.create(nil);
        end;
        try
          result:=EvalRowConstructor(st,iter,snode.leftChild,tuple1,aggregate,false,useOldValues);
          if result<>ok then exit; //abort if child aborts;
          //only allow single column result - i.e. -> a scalar_exp

          {Process scalar_exp_commalist (Note this code is taken from EvalRowConstructor routine)}
          //Note: maybe better to accept row_constructor here in the grammar since we allow
          //      scalar_commalist and table_exp for IN. Combine both & use same logic
          //      Doing it this way prevents WHERE 5 IN (SELECT X FROM Y) which is no real benefit (but standard?)
          {For each node in the potential chain (for scalar_exp_commalist)}
          res:=isFalse; //assume false until we get a match
          nhead:=snode.rightChild;
          n:=nhead;
          tuple2.ColCount:=1;
          while (n<>nil) and (res=isFalse) do
          begin
            tuple2.clear(st);
            {Take the next operator, may involve evaluating further sub-trees}
            n:=n.leftChild; //move to char exp root
            tuple2.SetColDef(0,1,rcInternal,0,n.dtype,n.dwidth{0},n.dscale{0},'',True);
            result:=EvalScalarExp(st,iter,n,tuple2,0,aggregate,useOldValues);
            if result<>ok then exit;
            tuple2.preInsert;
            result:=CompareTuples(st,tuple1,tuple2,compResEQ,res);
            if result<>ok then
            begin
              st.addError(seSyntaxInvalidComparison,seSyntaxInvalidComparisonText);
              exit; //abort if child aborts;
            end;

            nhead:=nhead.nextNode;
            n:=nhead; //if any
          end; {while}
        finally
          if (iter<>nil) and iter.lrInUse{todo assert} and (tuple1=iter.lTuple) then
          begin //release cached tuples
            iter.lrInUse:=false;
            tuple1:=nil; tuple2:=nil; //remove no need: speed
          end
          else
          begin
            tuple2.free;
            tuple1.free;
          end;
        end; {try}
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Left side of in (scalar) must be a scalar expression',[1]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
      end;
    end; {ntInScalar}

    ntNOP:
    begin
      {$IFDEF DEBUGDETAIL2}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('NOP (%p)',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      if snode.leftChild=nil then
        res:=isTrue //added for optimiser dummy SELECT
      else
        result:=EvalCondPredicate(st,iter,snode.leftChild,res,aggregate,useOldValues); //left operand
      if result<>ok then exit; //abort if child aborts
    end;

    {Note: the orderBy node is chained at the table-exp level and can appear in an expression list
           after optimisation, e.g. 'Using' (due to quirky root copy/chain for garbage collection: see insertSelection)
           we ignore it here}

           //there may be more of these!!! need extensive tests!
    ntOrderBy:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('order-by (%p) - ignoring...',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      res:=isTrue //added for optimiser dummy SELECT
    end;
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unrecognised operator (%d) at %p',[ord(snode.nType),snode]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
  end; {case}
end; {EvalCondPredicate}

function EvalCondExpr(st:TStmt;iter:TIterator;snode:TSyntaxNodePtr;var res:TriLogic;aggregate:Taggregation;useOldValues:boolean):integer;
{Returns the result of the conditional expression in a syntax subtree

 IN      :
             st         the statement
             iter       the current iterator (links to iTuple) to take column values from
             snode      the syntax sub-tree containing the expression
             aggregate  todo! True=recurse into aggregate function expressions to calculate them
                         (used in having(=grouping) calculation)
                        False=use the value stored against the aggregate function and don't recurse
                         (used in projection after a grouping & final having test)
             useOldValues e.g. cascade update - use pre-update tuple columns
 OUT     :   res      the 3-valued logic result

 RETURNS :   ok, or fail if error

 Assumes:
   the syntax tree condition has been re-organised into Conjunctive Normal Form
   CNF. Each conjunction is linked via the NextNode pointers.
   e.g.
       =     ->   ( OR )   ->       <>
      a b        <      >          j  k
                d e    f g

   (although some, e.g. CASE, won't have been)


   the sub-tree has already been 'completed'
}
const routine=':evalCondExpr';
var
  subNode:TSyntaxNodePtr;
begin
  result:=ok;
  res:=isTrue;

  try
    subNode:=snode;
    {For all the sub-trees, as long as the whole predicate can be true,
    or until we know it must be false or unknown}
    //check: do we need to evaluate all to check for unknown? use TriAnd?
    // - not for Where clause - this is boolean
    while (res=isTrue) and (subNode<>nil) do
    begin
      result:=EvalCondPredicate(st,iter,subnode,res,aggregate,useOldValues);
      if result<>ok then
        exit; //abort if any child-tree aborts  //Note res may be isTrue... so?
      subNode:=subNode.nextNode; //any more sub-trees?
    end;

  finally
  end; {try}

  result:=ok;
end; {EvalCondExpr}


//////////////////// prePlan ///////////////////////////////////////////////////
function CompleteScalarExp(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
{

 This, along with other 'complete' routines do the following:
       type-setting:
         recurse down to the base relations to find root types (now that catalog info is available)
         on way back up tree, passes type info up to root taking into account the operators etc.
       type-checking:
         during type setting, checks types are valid for the contexts/operators involved
         gives syntax errors if not

 soon:
       sub-query plan generation and preparation:
         whenever we find a reference to a sub-query, the plan is generated and attached to the syntax tree
         sub-plan.start is called and so it is recursively completed
         the sub-plan is marked as correlated or not
         Note: sub-plans mean we'll need an iter.restart (we don't need to 'complete' etc. every time!)
 future:
       permission checks:
         for each column/table referenced, check user has permissions to select/update etc.
         -may need to pass update-type, e.g. Ins,Del,Upd,Sel into these routines...?

 RETURNS:     ok
              else fail + error(s) logged
}
const routine=':CompleteScalarExp';
var
  n:TSyntaxNodePtr;

  cId:TColId;
  cRef:ColRef;

  cDatatype:TDataType;
  cWidth:integer;
  cScale:smallint;

  cTuple:TTuple;

  vId:TVarId;
  vRef:VarRef;
  vSet:TVariableSet;
  vVariableType:TVariableType;

  {for privilege check}
  grantabilityOption:string;
  table_level_match,authId_level_match:boolean;

  {for case-of}
  eqSnode,tempNode,whenlist:TSyntaxNodePtr;

  {for sub-select}
  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root
  newChildParent:TIterator;
  matNode:TIterator;

  {for cast}
  sysDomainR:TObject; //Trelation
  tempi:integer;
  dummy_null:boolean;

  {for function evaluation}
  r:TRoutine;
  routineType:string;
  routineDefinition:string;
  i:varRef;
begin
  result:=ok;
  n:=snode;

  case n.ntype of
    ntCharacterExp:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      {Pull up type info from child}
      n.dType:=n.leftChild.dType;
      n.dWidth:=n.leftChild.dWidth;
      n.dScale:=n.leftChild.dScale;
    end;
    ntNumericExp:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      {Pull up type info from child}
      n.dType:=n.leftChild.dType;
      n.dWidth:=n.leftChild.dWidth;
      n.dScale:=n.leftChild.dScale;
    end;

    //level down- indent?
    ntColumnRef: //Note: could actually be a variable ref
    begin
      cid:=InvalidColId; //column not found

      if assigned(iter) then
      begin //we have a tuple context so this could be a column reference
        {Get range - depends on catalog.schema parse}
        //todo: if n.leftChild.ntype=ntTable then check if its leftChild is a schema & if so restrict find...
        //assumes we have a right child! -assert!
        result:=iter.iTuple.FindCol(n,n.rightChild.idval,''{cRange todo remove},iter.outer,cTuple,cRef,cid);
        if result<>ok then
        begin
          if result=-2 then
          begin
            st.addError(seSyntaxAmbiguousColumn,format(seSyntaxAmbiguousColumnText,[n.rightChild.idVal]));
          end
          else
          begin
            st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,['column '+n.rightChild.idVal]));
          end;
          exit; //abort if child aborts
        end;
      end;
      //else a)variable reference or b)syntax error has slipped through (e.g. insert into T values defaults)

      if cid=InvalidColId then
      begin
        {This could still be a variable/parameter reference (in this stmt or in an outer stmt block)}
        (*debug fix 12/03/04: if assigned(st.varSet) then
          result:=st.varSet.FindVar(n.rightChild.idval,st.outer,vSet,vRef,vid)
        else
          vid:=InvalidVarId;
        *)
        if assigned(st.varSet) then
          result:=st.varSet.FindVar(n.rightChild.idval,st.outer,vSet,vRef,vid)
        else //could be a cursor SELECT with a WHERE referencing a variable, i.e. one down from proc/var context
          if assigned(st.outer) and assigned(st.outer.varSet) then
            result:=st.outer.varSet.FindVar(n.rightChild.idval,st.outer.outer,vSet,vRef,vid)
          else
            vid:=InvalidVarId;

        if vid=InvalidVarId then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unknown column/variable reference (%s)',[n.rightChild.idVal]),vError);
          if n.leftChild<>nil then
            log.add(st.who,where+routine,format('  searching with prefix: %s',[n.leftChild.rightChild.idVal]),vDebugLow);
          if assigned(iter) then
            log.add(st.who,where+routine,format('  searching tuple: %s',[iter.iTuple.ShowHeading]),vDebugLow)
          else
            log.add(st.who,where+routine,format('  no tuple context available',[nil]),vDebugLow);
          {$ENDIF}
          st.addError(seSyntaxUnknownColumn,format(seSyntaxUnknownColumnText,[n.rightChild.idVal]));
          result:=Fail;
          exit; //abort, no point continuing?
        end
        else
        begin //found a variable match, so store reference for use at evaluation time - speed
          n.ntype:=ntVariableRef; //first change the type so we use n.vVariableSet/vRef as vSet/vRef at eval time
          //Note: this is ok for CASE statements that are evaluated dynamically!
          if n.cTuple<>nil then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('cTuple is not nil for variable %s',[n.rightChild.idVal]),vAssertion);
            {$ENDIF}
          end;
          if n.vVariableSet<>nil then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('vVariableSet is not nil for %s (ok for CASE?)',[n.rightChild.idVal]),vDebugWarning);
            {$ENDIF}
          end;
          if n.vVariableSet=nil then
          begin
            n.vVariableSet:=vSet; //note: vSet could be in an outer st
            n.vRef:=vRef;
          end; //else already set //note: we still go ahead & update the type/size again...shouldn't matter...
          //no privilege checking needed for variables (maybe disallow out variableType RH reference?)

          result:=vSet.GetVarBasicDef(vRef,vVariableType,cDatatype,cWidth,cScale);
          if result<>ok then exit; //abort if child aborts

          n.dType:=cDataType;
          n.dWidth:=cWidth;
          n.dScale:=cScale;

          {$IFDEF DEBUGDETAIL}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Completed syntax variable definition from variable %d',[vRef]),vDebugLow);
          {$ENDIF}
          {$ENDIF}

          exit; //done
        end;
      end;

      {We found a column so store the column reference for use at evaluation time - speed}
      //use the node's cTuple/cRef directly so we don't need local vars & this copying - make sure FindCol only sets if found
      {debug fix: note: we only set if it hasn't already been set by a lower iterator,
       this is for the case when iterGroup actively references the projection anode above
       - note: this fix assumes lower always takes priority over higher levels and that they're called in that order
       - see note in iterGroup.start

      Note: should only happen after aggregate parameter=True?
      Note: should never happen - we remove the iterProject if we have iterGroup
      }
      //Note: this is ok for CASE statements that are evaluated dynamically!
      if n.cTuple<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('cTuple is not nil for %s (ok for CASE?)',[n.rightChild.idVal]),vDebugWarning);
        {$ENDIF}
      end;

      if n.cTuple=nil then
      begin
        n.cTuple:=cTuple;
        n.cRef:=cRef;
      end; //else already set //note: we still go ahead & update the type/size again...shouldn't matter...

      {Now we ensure we have privilege to Select this column
        - we leave it to the CheckTableColumnPrivilege routine to sensibly cache when we're checking for a whole table
        - this needs to be fast!
       //is it true that here we're always needing to Select? I think so...
       //     but are there any internal projections (or something) that need to bypass this check?
      }
      if CheckTableColumnPrivilege(st,0{we don't care who grantor is},Ttransaction(st.owner).authId,{are we always checking our own privilege here?}
                                   False{we don't care about role/authId grantee},authId_level_match,
                                   cTuple.fColDef[cRef].sourceAuthId{=source table owner},
                                   cTuple.fColDef[cRef].sourceTableId{=source table},
                                   cid,table_level_match{we don't care how exact we match},
                                   ptSelect{always?},False{we don't want grant-option search},grantabilityOption)<>ok then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed checking privilege %s on %d:%d for %d',[PrivilegeString[ptSelect],cTuple.fColDef[cRef].sourceTableId,cid,Ttransaction(st.owner).AuthId]),vDebugError);
        {$ENDIF}
        st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[n.rightChild.idVal+' privilege']));
        result:=Fail;
        exit;
      end;
      if grantabilityOption='' then //use constant for no-permission?
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Not privileged to %s on %d:%d for %d',[PrivilegeString[ptSelect],cTuple.fColDef[cRef].sourceTableId,cid,Ttransaction(st.owner).AuthId]),vDebugLow);
        {$ENDIF}
        st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to select '+n.rightChild.idVal]));
        result:=Fail;
        exit;
      end;

      {Ok, we're privileged}
      result:=cTuple.GetColBasicDef(cRef,cDatatype,cWidth,cScale);
      if result<>ok then exit; //abort if child aborts

      n.dType:=cDataType;
      n.dWidth:=cWidth;
      n.dScale:=cScale;
      {If this column correlates to an outer reference, mark this iterator as correlated
       (this information can then be used later when optimising sub-selects)}
      if cTuple<>iter.iTuple then
      begin
        //todo! if cTuple=[system iter+tuple] then don't class as correlated!!! e.g. if references server.name or something!
        iter.correlated:=True;
        {$IFDEF DEBUGDETAIL2}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Flagged iterator as correlated after column definition from column %d matched to an outer level',[cRef]),vDebugLow);
        {$ENDIF}
        {$ENDIF}
      end;

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Completed syntax column definition from column %d',[cRef]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
    end;
    //todo combine these next few fixed literals into 1 case statement!
    ntString:
    begin
      //base literal - already set by lexical analysis
    end;
    ntNumber:
    begin
      //base literal - already set by lexical analysis
    end;
    ntDate:
    begin
      //base literal - already set by lexical analysis
    end;
    ntTime:
    begin
      //base literal - already set by lexical analysis
    end;
    ntTimestamp:
    begin
      //base literal - already set by lexical analysis
    end;
    ntBlob,ntClob:
    begin
      //base literal - already set by lexical analysis
    end;
    ntNull:
    begin
      //base literal - already set by parser
    end;
    ntDefault:
    begin
      //base literal - already set by parser
      //Note: only applies to Insert statements & will actually never be evaluated
      //      Difference between this and ntNull=datatype is ctUnknown for default
    end;
    ntParam:
    begin
      //we need to determine the param definition according to its neighbours
      //and the standard rules... the results will be used to auto-populate the IDP

      //ntParam is not allowed as a Select item...
      //so give syntax error here if used in wrong place...
    end;
    ntConcat:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      result:=CompleteScalarExp(st,iter,n.rightChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      //what if children are different types? - syntax error?
      // or conversion:
      //   either insert dummy convert node
      //   or leave to eval routine(s)
      //   - either way, what will the length be? - max-precision+2 I suppose

      //fail if one is a blob & the other isn't as per spec... for now leave=upgrade to blob=useful?

      //we need to set type to one of children since || could be for blob/clob types as well
      //the type depends on the types of the two children
      n.dType:=maxDATATYPE(n.leftChild.leftChild.dType,n.rightChild.dType);

      {Now take the combined widths as being the maximum possible}
      //should we set type to one of children?: n.dType:=cDataType; - no need always character only from parser
      //should we set scale to one of children?: n.dscale:=cscale;
      n.dwidth:=n.leftChild.leftChild.dwidth+n.rightChild.dwidth;
    end;
    ntPlus,ntMinus,ntMultiply,ntDivide:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      result:=CompleteScalarExp(st,iter,n.rightChild,aggregate); //recursion
      if result<>ok then exit; //abort if child fails
      //what if children are different types? - syntax error?
      // or conversion:
      //   either insert dummy convert node
      //   or leave to eval routine(s)
      //   - either way, what width/scale will we use next? - max-precision & max-scale I suppose

      //we need to set type to one of children since +/-/*// could be for non-numeric types as well (i.e. dates/intervals)
      //the type depends on the types of the two children
      n.dType:=maxDATATYPE(n.leftChild.dType,n.rightChild.dType);
      case n.ntype of
        ntPlus,ntMinus:
        begin
          n.dwidth:=uGlobal.maxINTEGER(n.leftChild.dwidth,n.rightChild.dwidth)+1; //allow 1 for carry over
          n.dscale:=uGlobal.maxSMALLINT(n.leftChild.dscale,n.rightChild.dscale);
        end;
        ntMultiply:
        begin
          n.dwidth:=n.leftChild.dwidth+n.rightChild.dwidth;
          n.dscale:=n.leftChild.dscale+n.rightChild.dscale;
        end;
        ntDivide: //non-commutative
        begin
          n.dwidth:=n.leftChild.dwidth;
          n.dscale:=uGlobal.maxSMALLINT(n.leftChild.dscale,n.rightChild.dscale)+1; //allow for 1 dp fraction //todo maybe should allow 2?
        end;
      //else assertion!
      end; {case}
    end;
    ntAggregate:
    begin
      {Only drill deeper if this is called by a groupBy start,
       (otherwise it's called by a Project node which wouldn't find the column names
       since the lower group-by would have obscured them with sum() etc. and in such
       a case, the tree would have been completed already anyway)
      }
      if aggregate=agStart then
      begin
        n.aggregate:=True; //used by iterGroup - is this still needed?
        if n.rightChild<>nil then
        begin
          result:=CompleteScalarExp(st,iter,n.rightChild,aggregate); //recursion
          if result<>ok then exit; //abort if child fails
          {Pull up type info from child}
          n.dType:=n.rightChild.dType;
          n.dWidth:=n.rightChild.dWidth;
          n.dScale:=n.rightChild.dScale;

          {Check aggregate is applicable for this datatype}
          result:=ok;
          case DataTypeDef[n.dType] of
            stString:
              case n.leftChild.nType of
                ntSum, ntAvg:
                  result:=fail;
              end; {case}
            stDate, stTime, stTimestamp:
              case n.leftChild.nType of
                ntSum, ntAvg:
                  result:=fail;
              end; {case}
            stBlob:
              case n.leftChild.nType of
                ntMax, ntMin,  //note: with a bit of work we could enable these but standard says no
                ntSum, ntAvg:
                  result:=fail;
              end; {case}
           //else assume number => all applicable
          end; {case}
          {Ok?}
          if result<>ok then
          begin
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Set function not applicable to this datatype',[nil]),vError);
            {$ENDIF}
            st.addError(seSyntaxInvalidSetFunction,seSyntaxInvalidSetFunctionText);
            result:=Fail;
            exit;
          end;
        end
        else
        begin
          //must be count(*) which is/should be set to numeric by parser
          n.dType:=ctNumeric;
          n.dWidth:=8; //needs to be max precision or something, e.g. max rows ever possible...
          n.dScale:=0;
        end;
      end; //else check ok to ignore other aggregation values...
           //maybe best place for reset if agStart? no because restart also needs to zeroise...
           //- we should set n.aggregate=True here is agStart & then maybe we can remove crappy uSyntax.hasAggregate routine
    end;

    ntUserFunction:
    begin
      {Load the function definition to
        a) determine the result type & pull it up now
        b) check that the routine exists & is of the expected type - i.e. a function
        in future search a routine cache}
      r:=TRoutine.create;
      try
        {Try to open this routine so we can check the type & its result parameter ref}
        if r.open(st,n.leftChild.leftChild,'',n.leftChild.rightChild.idVal,routineType,routineDefinition)=ok then
        begin
          if routineType=rtFunction then
          begin
            {Now we ensure we have privilege to Execute this function
              - this needs to be fast!
            }
            if CheckRoutinePrivilege(st,0{we don't care who grantor is},Ttransaction(st.owner).authId,{are we always checking our own privilege here?}
                                     False{we don't care about role/authId grantee},authId_level_match,
                                     r.AuthId{=routine owner},
                                     r.routineId{=routine},
                                     ptExecute{always?},False{we don't want grant-option search},grantabilityOption)<>ok then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed checking privilege %s on %d for %d',[PrivilegeString[ptSelect],r.routineId,Ttransaction(st.owner).AuthId]),vDebugError);
              {$ENDIF}
              st.addError(seSyntaxLookupFailed,format(seSyntaxLookupFailedText,[n.leftChild.rightChild.idVal+' privilege']));
              result:=Fail;
              exit;
            end;
            if grantabilityOption='' then //use constant for no-permission?
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Not privileged to %s on %d for %d',[PrivilegeString[ptExecute],r.routineId,Ttransaction(st.owner).AuthId]),vDebugLow);
              {$ENDIF}
              st.addError(sePrivilegeFailed,format(sePrivilegeFailedText,['to execute '+n.leftChild.rightChild.idVal]));
              result:=Fail;
              exit;
            end;

            {Ok, we're privileged}
            for i:=0 to r.fVariableSet.VarCount-1 do
              if r.fVariableSet.fVarDef[i].variableType in [vtResult] then
              begin
                n.dType:=r.fVariableSet.fVarDef[i].dataType;
                n.dWidth:=r.fVariableSet.fVarDef[i].width;
                n.dScale:=r.fVariableSet.fVarDef[i].scale;
              end;
          end
          else
          begin
            result:=-3; //found procedure instead of function //use a better error message!
            st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[n.leftChild.rightChild.idVal])); //show schemaId also?
            exit; //abort
          end;
        end
        else
        begin
          result:=-3; //could not find routine //use local constant
          st.addError(seSyntaxUnknownRoutine,format(seSyntaxUnknownRoutineText,[n.leftChild.rightChild.idVal])); //show schemaId also?
          exit; //abort
        end;
      finally
        {delete the temporary routine - only used for routine preview & variableSet definition}
        r.free;
      end; {try}
      //we need a way of calling createRoutine here & retaining the sub-plan/subst?...

      {Complete the user-supplied parameters}
      n:=n.rightChild;
      while n<>nil do
      begin
        result:=CompleteScalarExp(st,iter{not expecting column values here, but pass anyway},n.leftChild{descend below ..._exp},aggregate); //recursion
        if result<>ok then exit; //aborted by child

        n:=n.nextNode; //next parameter in this list
      end;
    end; {ntUserFunction}
    ntCast:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit;

      {Note: this code was copied from the createTable routine}
      //now we could/should call DetermineDatatype! i.e. single place of interpretation
      n.dType:=ctInteger;
      n.dWidth:=0;
      n.dScale:=0;
      case n.rightChild.nType of
        ntInteger:
        begin
          n.dType:=ctInteger;
        end;
        ntSmallInt:
        begin
          n.dType:=ctSmallInt;
        end;
        ntBigInt:
        begin
          n.dType:=ctBigInt;
        end;
        ntFloat:
        begin
          n.dType:=ctFloat;
          if n.rightChild.leftChild<>nil then
            n.dWidth:=trunc(n.rightChild.leftChild.numVal); //todo replace trunc()s with DoubleToIntSafe()...
            //this specifies number of bits (check?) - we can specify the maximum e.g. 32 or sizeof(double)/8?
            //should we store this in colWidth? - might this be displayed as NUMERIC(p)?
            //It really should alter the colDataType depending on its size but we need to store the user's value as well
          //else we default the size of the float
        end;
        ntNumeric:
        begin
          n.dType:=ctNumeric;
          if n.rightChild.leftChild<>nil then
            n.dWidth:=trunc(n.rightChild.leftChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dWidth:=DefaultNumericPrecision;
          if n.rightChild.rightChild<>nil then
            n.dScale:=trunc(n.rightChild.rightChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dScale:=DefaultNumericScale;
        end;
        ntDecimal:
        begin
          n.dType:=ctDecimal;
          if n.rightChild.leftChild<>nil then
            n.dWidth:=trunc(n.rightChild.leftChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dWidth:=DefaultNumericPrecision;
          {Up the allowed colWidth (now or when Get?) if the storage allows (but still need to retain original def)}
          if n.rightChild.rightChild<>nil then
            n.dScale:=trunc(n.rightChild.rightChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dScale:=DefaultNumericScale;
        end;
        ntCharacter:
        begin
          n.dType:=ctChar;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal); //replace trunc()s with DoubleToIntSafe()...
          //check max width not breached (& total record length)
        end;
        ntVarChar:
        begin
          n.dType:=ctVarChar;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal); //don't store here?
          //check max width not breached (& total record length)
        end;
        ntBit:
        begin
          n.dType:=ctBit;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal);
          //check max width not breached (& total record length)
        end;
        ntVarBit:
        begin
          n.dType:=ctBit;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal); //don't store here?
          //check max width not breached (& total record length)
        end;
        ntDate:
        begin
          n.dType:=ctDate;
          n.dWidth:=DATE_MIN_LENGTH;
        end;
        ntTime:
        begin
          n.dType:=ctTime;
          if n.rightChild.rightChild<>nil then
            if n.rightChild.rightChild.nType=ntWithTimezone then n.dType:=ctTimeWithTimezone;
          if n.rightChild.leftChild<>nil then
            n.dScale:=trunc(n.rightChild.leftChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dScale:=DefaultTimeScale;
          n.dWidth:=TIME_MIN_LENGTH+n.dScale;
          if n.dType=ctTimeWithTimezone then n.dWidth:=n.dWidth+TIMEZONE_LENGTH;
        end;
        ntTimestamp:
        begin
          n.dType:=ctTimestamp;
          if n.rightChild.rightChild<>nil then
            if n.rightChild.rightChild.nType=ntWithTimezone then n.dType:=ctTimestampWithTimezone;
          if n.rightChild.leftChild<>nil then
            n.dScale:=trunc(n.rightChild.leftChild.numVal) //replace trunc()s with DoubleToIntSafe()...
          else
            n.dScale:=DefaultTimestampScale;
          n.dWidth:=TIMESTAMP_MIN_LENGTH+n.dScale;
          if n.dType=ctTimestampWithTimezone then n.dWidth:=n.dWidth+TIMEZONE_LENGTH;
        end;
        ntBlob:
        begin
          n.dType:=ctBlob;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal); //replace trunc()s with DoubleToIntSafe()...
        end;
        ntClob:
        begin
          n.dType:=ctClob;
          n.dWidth:=trunc(n.rightChild.leftChild.numVal); //replace trunc()s with DoubleToIntSafe()...
        end;

        ntDomain:
        begin
          {find domainID for n.rightChild.rightChild.idVal}
          if Ttransaction(st.owner).db.catalogRelationStart(st,sysDomain,sysDomainR)=ok then
          begin
            try
              if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysDomainR,ord(sd_domain_name),n.rightChild.rightChild.idVal)=ok then
              begin
                with (sysDomainR as TRelation) do
                begin
                  fTuple.GetInteger(ord(sd_datatype),tempi,dummy_null);
                  n.dType:=TDataType(tempi); //we have to assume datatype is (still) valid //check what happens if it's not- exception?
                  fTuple.GetInteger(ord(sd_width),tempi,dummy_null);
                  n.dWidth:=tempi;
                  fTuple.GetInteger(ord(sd_scale),tempi,dummy_null);
                  n.dScale:=tempi;

//                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Found domain %s with width=%d, scale=%d',[n.rightChild.rightChild.idVal,n.dWidth,n.dScale]),vDebugLow);
                  {$ELSE}
                  ;
                  {$ENDIF}
//                  {$ENDIF}
                end; {with}
              end
              else
              begin  //domain not found
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Unknown domain %s',[n.rightChild.rightChild.idVal]),vError);
                {$ELSE}
                ;
                {$ENDIF}
                st.addError(seSyntaxUnknownDomain,format(seSyntaxUnknownDomainText,[n.rightChild.rightChild.idVal]));
                result:=fail;
                exit; //abort
              end;
            finally
              if Ttransaction(st.owner).db.catalogRelationStop(st,sysDomain,sysDomainR)<>ok then
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysDomain)]),vError);
                {$ELSE}
                ;
                {$ENDIF}
            end; {try}
          end
          else
          begin  //couldn't get access to sysDomain
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysDomain),n.rightChild.rightChild.idVal]),vDebugError);
            {$ELSE}
            ;
            {$ENDIF}
            result:=fail;
            exit; //abort
          end;
        end; {ntDomain}
      else
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unknown datatype %d',[ord(n.rightChild.nType)]),vDebugError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=fail;
        exit; //abort
      end; {case}

    end; {ntCast}
    ntCase:
    begin
      n.dType:=ctUnknown; //don't assume anything yet (e.g. null is untyped)
      if n.leftChild.ntype=ntCaseOf then
      begin
        {Augment the case tree to include a complete expression to plug the partial When's into at eval-time}
        eqSnode:=mkNode(st.srootAlloc,ntRowConstructor,ctUnknown,n.leftChild.leftChild,nil);
        tempNode:=mkNode(st.srootAlloc,ntRowConstructor,ctUnknown,nil,nil);
        eqSnode:=mkNode(st.srootAlloc,ntEqual,ctUnknown,eqSnode,tempNode);
        chainNext(n,eqSnode); //left & right are full, so we have to chain
        //assert rightChild exists!
        eqSnode:=n.nextNode; //point to new artificial condition node
        whenList:=n.leftChild.rightChild; //when list
      end
      else
      begin
        eqSnode:=nil; //i.e. whenList = already fully formed predicates
        whenList:=n.leftChild;
      end;

      {Loop through when list to make sure conditions and results are all valid/compatible (and to type the result expressions)}
      //check/make sure we don't do this backwards! - although it doesn't really matter here!
      while whenList<>nil do
      begin
        {Complete when condition}
        if eqSnode=nil then
        begin
          {Already fully formed expression, just complete it}
          result:=CompleteCondExpr(st,iter,whenList.leftChild,aggregate); //check aggregate=False is always ok! I think it is... but shouldn't we pass aggregate?
          if result<>ok then exit; //abort
        end
        else
        begin
          {We need to (temporarily) link the partial expression to our pre-formed 'Equal' node before completion}
          linkLeftChild(eqSnode.rightChild,whenList.leftChild);
          try
            result:=CompleteCondExpr(st,iter,eqSnode,aggregate); //check aggregate=False is always ok! I think it is... but shouldn't we pass aggregate?
            if result<>ok then exit; //abort
          finally
            unlinkLeftChild(eqSnode.rightChild);
          end; {try}
        end;
        {No type info to pull up - we use the result-expressions for this}

        {Now complete the resulting expression (even though we may never need to use it)}
        result:=CompleteScalarExp(st,iter,whenList.rightChild.leftChild,aggregate); //recursion
        if result<>ok then exit;

        if whenList.rightChild.leftChild.nType<>ntNull then
        begin
          {Pull up type info from child}
          //if not compatible(n.dtype,n2.rightChild.leftChild.dType) then syntax error
          // - maybe except 1st check - cos initial n.dtype may be wrong/unknown
          // - remember to copy code in else checks below!
          //causes ODBC problem: prepared type changed! n.dType:=maxDATATYPE(n.dType,whenList.rightChild.leftChild.dType);  //error if different ones...? check spec.
          n.dType:=whenList.rightChild.leftChild.dType;  //uses last one - error if different ones...? check spec.
          n.dwidth:=uGlobal.maxINTEGER(n.dwidth,whenList.rightChild.leftChild.dWidth); //use max so we can handle any
          n.dscale:=uGlobal.maxSMALLINT(n.dscale,whenList.rightChild.leftChild.dScale); //use max so we can handle any
        end;

        whenList:=whenList.nextNode;
      end; {while}
      if n.rightChild<>nil then //we have an else clause, so check its type info
      begin
        result:=CompleteScalarExp(st,iter,n.rightChild.leftChild,aggregate); //recursion
        if result<>ok then exit;

        if n.rightChild.leftChild.nType<>ntNull then
        begin
          {Pull up type info from child, unless we have a vague child!}
          if not( assigned(n.rightChild.leftChild) and (n.rightChild.leftChild.nType=ntNull) ) then
          begin
            //causes ODBC problem: prepared type changed! n.dType:=maxDATATYPE(n.dType,n.rightChild.leftChild.dType);  //error if different ones...? check spec.
            n.dType:=n.rightChild.leftChild.dType;  //uses last one - error if different ones...? check spec.
            n.dwidth:=uGlobal.maxINTEGER(n.dwidth,n.rightChild.leftChild.dWidth); //use max so we can handle any
            n.dscale:=uGlobal.maxSMALLINT(n.dscale,n.rightChild.leftChild.dScale); //use max so we can handle any
          end;
          //else leave as last main result
        end;
        //else leave as last main result
      end;
    end; {ntCase}
    ntNullIf:
    begin
      result:=CompleteScalarExp(st,iter,n.rightChild.leftChild,aggregate); //recursion
      if result<>ok then exit;

      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit;

      {Pull up type info from child}
      n.dType:=n.leftChild.leftChild.dType;  //error if different ones...? check spec.
      n.dwidth:=uGlobal.maxINTEGER(n.dwidth,n.leftChild.leftChild.dWidth); //use max so we can handle any
      n.dscale:=uGlobal.maxSMALLINT(n.dscale,n.leftChild.leftChild.dScale); //use max so we can handle any
    end; {ntNullIf}
    ntCoalesce:
    begin
      whenList:=n.leftChild;
      n.dType:=ctUnknown; //don't assume anything yet (e.g. null is untyped)

      while whenList<>nil do
      begin
        {Now complete the resulting expression (even though we may never need to use it)}
        result:=CompleteScalarExp(st,iter,whenList.leftChild,aggregate); //recursion
        if result<>ok then exit;

        if whenList.leftChild.nType<>ntNull then
        begin
          {Pull up type info from child}
          //if not compatible(n.dtype,n2.rightChild.leftChild.dType) then syntax error
          // - maybe except 1st check - cos initial n.dtype may be wrong/unknown
          // - remember to copy code in else checks below!
          ////causes ODBC problem: prepared type changed! n.dType:=maxDATATYPE(n.dType,whenList.leftChild.dType);  //error if different ones...? check spec.
          n.dType:=whenList.leftChild.dType;  //uses last one - error if different ones...? check spec.
          n.dwidth:=uGlobal.maxINTEGER(n.dwidth,whenList.leftChild.dWidth); //use max so we can handle any
          n.dscale:=uGlobal.maxSMALLINT(n.dscale,whenList.leftChild.dScale); //use max so we can handle any
        end;

        whenList:=whenList.nextNode;
      end; {while}

    end; {ntCoalesce}
    ntTrim:
    begin
      if n.leftChild<>nil then
      begin //we have a modifier (what/where)
        if n.leftChild.rightChild<>nil then
        begin //we have a what
          result:=CompleteScalarExp(st,iter,n.leftChild.rightChild.leftChild,aggregate); //recursion
          if result<>ok then exit;
        end; //else default to space
      end; //else default to both space

      result:=CompleteScalarExp(st,iter,n.rightChild.leftChild,aggregate); //recursion
      if result<>ok then exit;
      {Pull up type info from child}
      n.dType:=n.rightChild.leftChild.dType;  //error if different ones...? check spec.
      //fail if one is a blob & the other isn't as per spec... for now leave=useful?
      n.dwidth:=uGlobal.maxINTEGER(n.dwidth,n.rightChild.leftChild.dWidth); //use max so we can handle any
      n.dscale:=uGlobal.maxSMALLINT(n.dscale,n.rightChild.leftChild.dScale); //use max so we can handle any
    end; {ntTrim}
    ntCharLength, ntOctetLength:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      {Default type info}
      n.dwidth:=uGlobal.MaxNumericPrecision;
      n.dscale:=0;
      if result<>ok then exit;
    end; {ntCharLength, ntOctetLength}
    ntUpper, ntLower:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit;
      {Pull up type info from child}
      n.dType:=n.leftChild.leftChild.dType;
      n.dwidth:=uGlobal.maxINTEGER(n.dwidth,n.leftChild.leftChild.dWidth); //use max so we can handle any
      n.dscale:=uGlobal.maxSMALLINT(n.dscale,n.leftChild.leftChild.dScale); //use max so we can handle any
    end; {ntUpper,ntLower}
    ntPosition:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit;
      result:=CompleteScalarExp(st,iter,n.rightChild.leftChild,aggregate); //recursion
      if result<>ok then exit;
      //fail if one is a blob & the other isn't as per spec... for now leave=useful?
      {Default type info}
      n.dwidth:=uGlobal.MaxNumericPrecision;
      n.dscale:=0;
    end; {ntPosition}
    ntSubstring:
    begin
      result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      if result<>ok then exit;
      {Pull up type info from child}
      n.dType:=n.leftChild.leftChild.dType;
      n.dwidth:=uGlobal.maxINTEGER(n.dwidth,n.leftChild.leftChild.dWidth); //use max so we can handle any
      n.dscale:=uGlobal.maxSMALLINT(n.dscale,n.leftChild.leftChild.dScale); //use max so we can handle any

      result:=CompleteScalarExp(st,iter,n.rightChild.leftChild,aggregate); //recursion
      if n.rightChild.rightChild<>nil then
        result:=CompleteScalarExp(st,iter,n.rightChild.rightChild,aggregate); //recursion
      if result<>ok then exit;
    end; {ntSubstring}

    ntNextSequence,
    ntLatestSequence:
    begin
      //find (& store) generator's owner & check privileged to access it!

      //result:=CompleteScalarExp(st,iter,n.leftChild.leftChild,aggregate); //recursion
      result:=ok;
      if result<>ok then exit;
      {Default type info}
      n.dwidth:=uGlobal.MaxNumericPrecision;
      n.dscale:=0;
    end; {ntNextSequence, ntLatestSequence}
    //is this the right/best place for such niladic functions?
    //maybe we could/should evaluate them here as well? no need!
    //keep this list in sync with iterInsert defaults!
    ntCurrentUser,ntSessionUser,ntSystemUser,ntCurrentCatalog,ntCurrentSchema:
    begin
      n.dwidth:=20; //default width ok? use constant at least...
      result:=ok;
    end; {ntCurrentUser etc.}
    ntCurrentAuthId:
    begin
      result:=ok;
    end;
    ntCurrentDate:
    begin
      n.dwidth:=DATE_MIN_LENGTH; //in case higher operator needs this, e.g. concat
      result:=ok;
    end; {}
    ntCurrentTime:
    begin
      n.dscale:=DefaultTimeScale;
      if n.leftChild<>nil then n.dscale:=trunc(n.leftChild.numval);
      n.dwidth:=TIME_MIN_LENGTH+n.dscale; //in case higher operator needs this, e.g. concat
      result:=ok;
    end; {}
    ntCurrentTimestamp:
    begin
      n.dscale:=DefaultTimestampScale;
      if n.leftChild<>nil then n.dscale:=trunc(n.leftChild.numval);
      n.dwidth:=TIMESTAMP_MIN_LENGTH+n.dscale; //in case higher operator needs this, e.g. concat
      result:=ok;
    end;
    ntSQLState:
    begin
      n.dwidth:=length(SQL_SUCCESS); //in case higher operator needs this, e.g. concat
      result:=ok;
    end;

    ntTableExp:
    begin
      {This is assumed to be completed by the creator of the ntTableExp structure
      //No: here is where we need to build the TableExp... and link it to the syntax node
      // - also complete the sub-query and check whether the sub-completion references outer = correlated
      }
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('SUB_SELECT (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      atree:=nil;
      ptree:=nil;
      {Assert we haven't already a plan attached}
      if snode.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.nType),snode.atree]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      if snode.ptree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.nType),longint(snode.ptree)]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      result:=CreateTableExp(st,snode,atree);
      if result=ok then
      begin
        snode.atree:=atree; //link to syntax tree for later destruction
        if CreatePlan(st,snode,atree,ptree)=ok then
        begin
          snode.ptree:=ptree; //link to syntax tree for use at evaluation time
          {Now is the best time to start this sub-plan
           -but until we have iter start/restart stages, we continue to (re)start at every eval}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          result:=(ptree as TIterator).prePlan(iter);
          if result=ok then
          begin
            if not (ptree as TIterator).correlated then
            begin
              if AllowMaterialise then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                matNode.leftChild:=ptree;
                ptree:=matNode;
                snode.ptree:=ptree; //link to syntax tree for for later destruction
              end;
            end;

            result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
            if result<>ok then exit;        
            //we can now defer until eval: result:=(ptree as TIterator).start(iter);
            {Pull up type info from child}
            //assert we have at least 1 column - else range error/crash
            n.dType:=(ptree as TIterator).iTuple.fColDef[0].dataType;
            n.dwidth:=(ptree as TIterator).iTuple.fColDef[0].width;
            n.dscale:=(ptree as TIterator).iTuple.fColDef[0].scale;
          end;
        end
        else result:=Fail; //if ok here then do to all if createplans...
        //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
      end;
    end; {ntTableExp}
  //else
  // error? - we're not expecting to have to handle any other node type here? yet!
  end; {case}
end; {CompleteScalarExp}

function CompleteSelectItem(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
{Complete's a select item's syntax tree info, now that we have catalog info available

 IN:
          st              the statement
          iter            the current iterator (links to iTuple) to take column info from
          snode           the syntax node of the selectItem
          aggregate       todo! True=select item it being analysed by a GroupBy, so drill-down into aggregate trees
                          False=analysed by Project, so any aggregates will have already been analysed already
                                so don't drill down into them (otherwise columns will no longer be found
                                since GroupBy masks the source relations with sum() etc.)

 RETURNS: ok,
          -2 = invalid use of 'default' keyword
          else fail

 Notes:
 Currently designed only for updating ntSelectItem sub-trees,
 but could be made more general for all expressions.

 todo:
   if this routine is successful we could:
     just have a single evaluation routine? DONE
     remove type checking from the evaluation routine(s) PART-DONE
     have this routine log syntax errors, not the eval routine(s)
     remove most/all comments in eval routine(s) about 'shouldn't this have been caught before now?'
     check all iterators (etc?!) for over-detection/checking of types
   ultimately if this routine is used for whole syntax tree we could:
     remove the half-hearted passing up of type info during parsing -speed
      -i.e. mkleaf/mkNode may as well not bother since we'd always overwrite their efforts
}
const routine=':CompleteSelectItem';
var
  n:TSyntaxNodePtr;
begin
  result:=ok;
  n:=snode;

  if n.ntype=ntSelectItem then
  begin
    {Now this could be a character_exp, numeric_exp or whatever,
     so we descend into it. Luckily (hopefully) here we don't have to be
     concerned with the different 'exp' types created by the parser since
     we're trying to establish whether the types are bogus or not
    }
    result:=CompleteScalarExp(st,iter,n.leftChild,aggregate);
    if result<>ok then exit; //abort if child aborts

    {Check there are no 'Default' keywords - only allowed in insert statements}
    if n.leftChild.dType=ctUnknown then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format(seSyntaxDefaultNotAllowedText,[nil]),vError);
      {$ENDIF}
      result:=-2;
      st.addError(seSyntaxDefaultNotAllowed,seSyntaxDefaultNotAllowedText);
      exit; //review behaviour for this user error
    end;

    {Pull up type info from child}
    n.dType:=n.leftChild.dType;
    n.dWidth:=n.leftChild.dWidth;
    n.dScale:=n.leftChild.dScale;
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Root should be a select_item (%d)',[ord(snode.nType)]),vDebugError); //assertion
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
  end;
end; {CompleteSelectItem}


function CompleteRowConstructor(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
{Completes a row constructor (tuple), now that we have relation info
 IN:
          st              the statement
          iter            the current iterator (links to iTuple) to take column definitions from
          snode           the syntax node of the rowConstructor node
          aggregate       todo! True=recurse into aggregate function expressions to define them
                           (used in having(=grouping) calculation)
                          False=use the definition already stored against the aggregate function and don't recurse
                           (used in projection after a grouping & final having test)

 This is a construct from the SQL grammar that can be one of:
      a scalar expression
      a tuple of scalar expressions (a,b...)
      a table expressions (which can be a sub-select)
        - this is limited by SQL to return a single-row (phew!) = 'rowSubquery'
          so we can execute the sub-select, check count=1 and return the 1st row
          Note: (Guide to SQL standard p168) no rows=behaves as a row of nulls
}
const
  routine=':completeRowConstructor';
var
  n,nhead:TSyntaxNodePtr;
  {for sub-select}
  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root

  newChildParent:TIterator;
  matNode:TIterator;
begin
  result:=ok;

  if snode.nType=ntRowConstructor then
  begin
    if snode.leftChild=nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('row-constructor (%d) is incomplete - missing left-child: probably a partial case-of node...continuing...',[ord(snode.nType)]),vDebugError); //assertion
      {$ELSE}
      ;
      {$ENDIF}
      exit; //note: result=ok!
    end;

    snode:=snode.leftChild;
    if snode.nType=ntTableExp then
    begin //this is a table expression (i.e. a row subquery => single row only)
      {test this copes with all valid syntax
       e.g. ( (table_exp), scalar, scalar ) etc. i.e. sub-queries nested in lists  - I think it does}
      //this will be handled/completed by the CreateTableExp routines : result:=CompleteCreateTableExp(st,snode);
      //No: here is where we need to build the TableExp... and link it to the syntax node
      // - also complete the sub-query and check whether the sub-completion references outer = correlated
      atree:=nil;
      ptree:=nil;
      {Assert we haven't already a plan attached}
      if snode.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.nType),snode.atree]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      if snode.ptree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.nType),longint(snode.ptree)]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      result:=CreateTableExp(st,snode,atree);
      if result=ok then
      begin
        snode.atree:=atree; //link to syntax tree for destroying later
        if CreatePlan(st,snode,atree,ptree)=ok then
        begin
          snode.ptree:=ptree; //link to syntax tree for use at evaluation time
          {Now is the best time to start this sub-plan
           -but until we split rowSubquery into complete & (re)eval stages, we continue to (re)start at every eval}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          result:=(ptree as TIterator).prePlan(iter);
          if result=ok then
          begin
            if not (ptree as TIterator).correlated then
            begin
              //seeing as this subquery should return no more than 1 row,
              //        we'd be better not materialising to disk & just retaining the iTuple in memory - speed & less handles/memory
              if AllowMaterialise then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                matNode.leftChild:=ptree;
                ptree:=matNode;
                snode.ptree:=ptree; //link to syntax tree for for later destruction
              end;
            end;

            result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
            if result<>ok then exit;        
          end;
        end
        else
          result:=Fail;
        //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
      end;

      //no point pulling up type-info - all could be different: explicitly set to unknown -or maybe SQL3.row
    end
    else
    begin //this is a scalar, or scalar list
      {For each node in the potential chain (for scalar_exp_commalist)}
      nhead:=snode;
      n:=nhead;
      while n<>nil do
      begin
        {Take the next operator, may involve completing further sub-trees}
        result:=CompleteScalarExp(st,iter,n,aggregate);
        if result<>ok then exit;

        //no point pulling up type-info - all could be different: explicitly set to unknown -or maybe SQL3.row

        nhead:=nhead.nextNode;
        n:=nhead; //if any
      end;
    end;
  end
  else
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Root is not a row-constructor (%d)',[ord(snode.nType)]),vDebugError); //assertion
    {$ELSE}
    ;
    {$ENDIF}
    result:=Fail;
  end;
end; {CompleteRowConstructor}

function CompleteCondPredicate(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
{Complete a sub-tree of a condition, now that we have relation info
 (condExp/condFactor/simpleCond.comparisonCond)
 IN      :
             st          the statement
             iter        the current iterator (links to iTuple) to take column definitions from
             snode       the syntax sub-tree containing the expression
             aggregate   todo! True=recurse into aggregate function expressions to complete them
                          (used in having(=grouping) calculation)
                         False=use the definition already stored against the aggregate function and don't recurse
                          (used in projection after a grouping & final having test)

 RETURNS :   ok, or fail if error
}
const
  routine=':completeCondPredicate';
var
  n,nhead:TSyntaxNodePtr;
  {for sub-select}
  atree:TAlgebraNodePtr;  //algebra root
  ptree:TIterator;        //plan root

  matchPartial,matchFull:boolean;

  newChildParent:TIterator;
  matNode:TIterator;
begin
  result:=ok;

  {Take the next operator, may involve completing further sub-trees}
  case snode.nType of
    ntOR:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('OR (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=CompleteCondPredicate(st,iter,snode.leftChild,aggregate); //left operand
      if result<>ok then exit; //abort if child aborts
      result:=CompleteCondPredicate(st,iter,snode.rightChild,aggregate); //right operand
      if result<>ok then exit; //abort if child aborts
    end; {ntOR}
    {Note we added the ntAND later on, since some conditions will not be CNF'd into separate sub-trees
     e.g. CASE expressions.
     Although we should very rarely see this. //check we don't!
    }
    ntAND:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('AND (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=CompleteCondPredicate(st,iter,snode.leftChild,aggregate); //left operand
      if result<>ok then exit; //abort if child aborts
      result:=CompleteCondPredicate(st,iter,snode.rightChild,aggregate); //right operand
      if result<>ok then exit; //abort if child aborts
    end; {ntAND}
    ntNOT:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('NOT (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=CompleteCondPredicate(st,iter,snode.leftChild,aggregate); //left operand
      if result<>ok then exit; //abort if child aborts
    end; {ntNOT}
    ntEqual,ntLT,ntGT,ntLTEQ,ntGTEQ,ntNotEqual,ntEqualOrNull{internal}:
    begin
      //todo reject if either side contains a blob & < > <= >= as per spec.
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('=/</>/<=/>=/<> (%p)',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      if snode.rightChild.nType=ntTableExp then
      begin //must be any/all (flag is chained to table-exp, one level down on right)
        case snode.rightChild.nextNode.nType of
          ntAll:
          begin
            {$IFDEF DEBUGDETAIL4}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('ALL (%p)',[snode.rightChild.nextNode]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
            if result<>ok then exit; //abort if child aborts;
            //this will be handled/completed by the CreateTableExp routines : result:=CompleteCreateTableExp(st,snode.rightChild);
            //No: here is where we need to build the TableExp... and link it to the syntax node
            // - also complete the sub-query and check whether the sub-completion references outer = correlated
            atree:=nil;
            ptree:=nil;
            {Assert we haven't already a plan attached}
            if snode.rightChild.atree<>nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.rightChild.nType),snode.rightChild.atree]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit;
            end;
            if snode.rightChild.ptree<>nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.rightChild.nType),longint(snode.rightChild.ptree)]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit;
            end;
            result:=CreateTableExp(st,snode.rightChild,atree);
            if result=ok then
            begin
              snode.rightChild.atree:=atree; //link to syntax tree for later destruction
              if CreatePlan(st,snode.rightChild,atree,ptree)=ok then
              begin
                snode.rightChild.ptree:=ptree; //link to syntax tree for use at evaluation time
                {Now is the best time to start this sub-plan
                 -but until we have iter start/restart stages, we continue to (re)start at every eval}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
                {$ELSE}
                ;
                {$ENDIF}
                result:=(ptree as TIterator).prePlan(iter);
                if result=ok then
                begin
                  if not (ptree as TIterator).correlated then
                  begin
                    if AllowMaterialise then
                    begin
                      {$IFDEF DEBUGDETAIL2}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                      matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                      matNode.leftChild:=ptree;
                      ptree:=matNode;
                      snode.rightChild.ptree:=ptree; //link to syntax tree for for later destruction
                    end;
                  end;
                  result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
                  if result<>ok then exit;        
                  //we can now defer until eval: result:=(ptree as TIterator).start(iter);
                end;
              end
              else result:=Fail;
              //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
            end;
          end; {ntAll}
          ntAny: //todo merge code with ALL!
          begin
            {$IFDEF DEBUGDETAIL4}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('ANY (%p)',[snode.rightChild.nextNode]),vDebugLow);
            {$ELSE}
            ;
            {$ENDIF}
            {$ENDIF}
            //todo move these into a op-comparison header routine
            result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
            if result<>ok then exit; //abort if child aborts;
            //this will be handled/completed by the CreateTableExp routines : result:=CompleteCreateTableExp(st,snode.rightChild);
            //No: here is where we need to build the TableExp... and link it to the syntax node
            // - also complete the sub-query and check whether the sub-completion references outer = correlated
            atree:=nil;
            ptree:=nil;
            {Assert we haven't already a plan attached}
            if snode.rightChild.atree<>nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.rightChild.nType),snode.rightChild.atree]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit;
            end;
            if snode.rightChild.ptree<>nil then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.rightChild.nType),longint(snode.rightChild.ptree)]),vAssertion);
              {$ELSE}
              ;
              {$ENDIF}
              result:=Fail;
              exit;
            end;
            result:=CreateTableExp(st,snode.rightChild,atree);
            if result=ok then
            begin
              snode.rightChild.atree:=atree; //link to syntax tree for later destruction
              if CreatePlan(st,snode.rightChild,atree,ptree)=ok then
              begin
                snode.rightChild.ptree:=ptree; //link to syntax tree for use at evaluation time
                {Now is the best time to start this sub-plan
                 -but until we have iter start/restart stages, we continue to (re)start at every eval}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
                {$ELSE}
                ;
                {$ENDIF}
                result:=(ptree as TIterator).prePlan(iter);
                if result=ok then
                begin
                  if not (ptree as TIterator).correlated then
                  begin
                    if AllowMaterialise then
                    begin
                      {$IFDEF DEBUGDETAIL2}
                      {$IFDEF DEBUG_LOG}
                      log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                      {$ENDIF}
                      {$ENDIF}
                      matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                      matNode.leftChild:=ptree;
                      ptree:=matNode;
                      snode.rightChild.ptree:=ptree; //link to syntax tree for for later destruction
                    end;
                  end;
                  result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
                  if result<>ok then exit;        
                  //we can now defer until eval time: result:=(ptree as TIterator).start(iter);
                end;
              end
              else result:=Fail;
              //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
            end;
          end; {ntAny}
        else
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Operator modifier not caught %d',[ord(snode.rightChild.nextNode.nType)]),vAssertion);
          {$ELSE}
          ;
          {$ENDIF}
        end; {case}
      end
      else
      begin //standard
        result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
        if result<>ok then exit; //abort if child aborts;
        result:=CompleteRowConstructor(st,iter,snode.rightChild,aggregate);
        if result<>ok then exit; //abort if child aborts;
      end;
    end; {ntEqual, etc.}
    ntExists: //maybe merge code with ALL/ANY? (better if separate - there is a SQL design bug with WHERE...EXISTS)
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('EXISTS (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Note: we can ignore the select list here
       - * does not mean all and can/should be replaced by 1 or something for speed
       - or maybe we can drop the whole IterProject layer and just use the raw IterSelect?
       For now, it's up to the user to make it fast
      }
      //this will be handled/completed by the CreateTableExp routines : result:=CompleteCreateTableExp(st,snode.leftChild);
      //No: here is where we need to build the TableExp... and link it to the syntax node
      // - also complete the sub-query and check whether the sub-completion references outer = correlated
      atree:=nil;
      ptree:=nil;
      {Assert we haven't already a plan attached}
      if snode.leftChild.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.leftChild.nType),snode.leftChild.atree]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      if snode.leftChild.ptree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.leftChild.nType),longint(snode.leftChild.ptree)]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      result:=CreateTableExp(st,snode.leftChild,atree);
      if result=ok then
      begin
        snode.leftChild.atree:=atree; //link to syntax node for later destruction
        if CreatePlan(st,snode.leftChild,atree,ptree)=ok then
        begin
          snode.leftChild.ptree:=ptree; //link to syntax tree for use at evaluation time
          {Now is the best time to start this sub-plan
           -but until we have iter start/restart stages, we continue to (re)start at every eval}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          result:=(ptree as TIterator).prePlan(iter);
          if result=ok then
          begin
            if not (ptree as TIterator).correlated then
            begin
              if AllowMaterialise then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                matNode.leftChild:=ptree;
                ptree:=matNode;
                snode.leftChild.ptree:=ptree; //link to syntax tree for for later destruction
              end;
            end;
            
            result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
            if result<>ok then exit;        
            //we can now defer until eval: result:=(ptree as TIterator).start(iter);
          end;
        end
        else result:=Fail;
        //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
      end;
    end; {ntExists}
    ntMatch:
    begin
      //note: this code is more or less taken from the =Any code - share?
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('MATCH (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Check any flags are valid}
      matchPartial:=False;
      matchFull:=False;
      n:=snode.rightChild;
      while n.nextNode<>nil do
      begin
        n:=n.nextNode;
        //we don't care about any unique flag at this stage
        {Note: these next two are mutually exclusive, check now
         (else would be sloppy to let through & would default to Partial since that's the 1st if in matchTUples)}
        if n.nType=ntPARTIAL then
        begin
          matchPartial:=True;
        end;
        if n.nType=ntFULL then
        begin
          matchFull:=True;
        end;
      end; {while}
      if matchPartial and matchFull then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Cannot specify match partial and full',[nil]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        st.addError(seSyntaxMatchFullAndPartial,format(seSyntaxMatchFullAndPartialText,[nil]));
        result:=Fail;
        exit; //abort - could continue and default to partial? no: sloppy
      end;

      result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
      if result<>ok then exit; //abort if child aborts;
      //this will be handled/completed by the CreateTableExp routines : result:=CompleteCreateTableExp(st,snode.rightChild);
      //No: here is where we need to build the TableExp... and link it to the syntax node
      // - also complete the sub-query and check whether the sub-completion references outer = correlated
      atree:=nil;
      ptree:=nil;
      {Assert we haven't already a plan attached}
      if snode.rightChild.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.rightChild.nType),snode.rightChild.atree]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      if snode.rightChild.ptree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.rightChild.nType),longint(snode.rightChild.ptree)]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      result:=CreateTableExp(st,snode.rightChild,atree);
      if result=ok then
      begin
        snode.rightChild.atree:=atree; //link to syntax tree for later destruction
        if CreatePlan(st,snode.rightChild,atree,ptree)=ok then
        begin
          snode.rightChild.ptree:=ptree; //link to syntax tree for use at evaluation time
          {Now is the best time to start this sub-plan
           -but until we have iter start/restart stages, we continue to (re)start at every eval}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          result:=(ptree as TIterator).prePlan(iter);
          if result=ok then
          begin
            if not (ptree as TIterator).correlated then
            begin
              if AllowMaterialise then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                matNode.leftChild:=ptree;
                ptree:=matNode;
                snode.rightChild.ptree:=ptree; //link to syntax tree for for later destruction
              end;
            end;

            result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
            if result<>ok then exit;        
            //we can now defer until eval: result:=(ptree as TIterator).start(iter);
          end;
        end
        else result:=Fail;
        //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
      end;
    end; {ntMatch}
    ntIsUnique: //maybe merge code with ALL/ANY?
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('UNIQUE (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {Note: we can currently only handle simple SELECT c1,c2 FROM table (c1,c2 etc must be a key)
            expressions since we use an index to test for uniqueness
            - this should be fine since we really only use this internally for key constraint checks
       For now, it's up to the user to make it legal (else will error)

       Note: in future can default to True if: use Distinct/union all etc. i.e. guranteed unique by definition
      }
      atree:=nil;
      ptree:=nil;
      {Assert we haven't already a plan attached}
      if snode.leftChild.atree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query algebra plan (%d) has already been assigned %p',[ord(snode.leftChild.nType),snode.leftChild.atree]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      if snode.leftChild.ptree<>nil then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Sub-query plan (%d) has already been assigned %d',[ord(snode.leftChild.nType),longint(snode.leftChild.ptree)]),vAssertion);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
        exit;
      end;
      //todo: could optimise so that we only open 1 index for the relation... since we currently restrict to simple SELECT..FROM with index-key column(s) - speed
      result:=CreateTableExp(st,snode.leftChild,atree);
      if result=ok then
      begin
        snode.leftChild.atree:=atree; //link to syntax node for later destruction
        //we need to create the plan, even though we won't use it, because we need the column refs etc.

        //check we are dealing with a simple base table & key-column list!
        //do we need to set snode.leftchild.ptree=nil to be safe?

        if CreatePlan(st,snode.leftChild,atree,ptree)=ok then
        begin
          snode.leftChild.ptree:=ptree; //link to syntax tree for use at evaluation time
          {Now is the best time to start this sub-plan
           -but until we have iter start/restart stages, we continue to (re)start at every eval}
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Starting prepared sub-query plan %d',[longint(ptree)]),vDebugMedium);
          {$ELSE}
          ;
          {$ENDIF}
          result:=(ptree as TIterator).prePlan(iter);
          if result=ok then
          begin
            if not (ptree as TIterator).correlated then
            begin
              if AllowMaterialise then
              begin
                {$IFDEF DEBUGDETAIL2}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Sub-select is not correlated so will be materialised',[nil]),vDebugLow);
                {$ENDIF}
                {$ENDIF}
                matNode:=TIterMaterialise.create(st); //will be cleaned up by normal method
                matNode.leftChild:=ptree;
                ptree:=matNode;
                snode.leftChild.ptree:=ptree; //link to syntax tree for for later destruction
              end;
            end;

            result:=(ptree as TIterator).optimise(st.sarg,newChildParent);
            if result<>ok then exit;        
            //we can now defer until eval: result:=(ptree as TIterator).start(iter);
          end;
        end
        else result:=Fail;
        //else in future: delete atree now, since we won't have snode.atree in future & snode.ptree.anodeRef won't be available if createPlan fails!
      end;
    end; {ntIsUnique}
    ntIsNull:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('isnull (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
      if result<>ok then exit; //abort if child aborts;
    end; {ntIsNull}
    ntLike:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('like (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {To ease the syntax rules, we allow a row-constructor on the LHS, but it must only lead to a character-exp}
      //Note: we also allow ntNumericExp, because the parser doesn't determine the type well enough this early
      if snode.leftChild.leftChild.ntype in [ntCharacterExp,ntNumericExp] then
      begin
        result:=CompleteScalarExp(st,iter,snode.leftChild.leftChild.leftChild,agNone);
        if result<>ok then exit; //abort if child aborts;
        result:=CompleteScalarExp(st,iter,snode.rightChild.leftChild,agNone);
        if result<>ok then exit; //abort if child aborts;
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Left side of Like must be a character expression',[1]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
      end;
    end; {ntLike}
    ntIs:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('is (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      result:=CompleteCondPredicate(st,iter,snode.leftChild,aggregate); //left operand
      if result<>ok then exit; //abort if child aborts
    end; {ntIs}
    ntInScalar:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('in (scalar) (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      {To ease the syntax rules, we allow a row-constructor on the LHS, but it must only lead to a scalar-exp}
      if snode.leftChild.leftChild.ntype in [ntCharacterExp,ntNumericExp] {etc for all scalars} then
      begin                          //^ this test is not rock solid (would allow a chain of scalars)?
        result:=CompleteRowConstructor(st,iter,snode.leftChild,aggregate);
        if result<>ok then exit; //abort if child aborts;
        //only allow single column result - i.e. -> a scalar_exp
        //if tuple1 is null then return isUnknown

        {Complete scalar_exp_commalist (Note this code is taken from RowConstructor routine)}
        //Note: maybe better to accept row_constructor here in the grammar since we allow
        //      scalar_commalist and table_exp for IN. Combine both & use same logic
        //      Doing it this way prevents WHERE 5 IN (SELECT X FROM Y) which is no real benefit (but standard?)
        {For each node in the potential chain (for scalar_exp_commalist)}
        nhead:=snode.rightChild;
        n:=nhead;
        while (n<>nil) do
        begin
          {Take the next operator, may involve completing further sub-trees}
          result:=CompleteScalarExp(st,iter,n,aggregate);
          if result<>ok then exit; //abort if child aborts;
          nhead:=nhead.nextNode;
          n:=nhead; //if any
        end; {while}
      end
      else
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Left side of in (scalar) must be a scalar expression',[1]),vError);
        {$ELSE}
        ;
        {$ENDIF}
        result:=Fail;
      end;
    end; {ntInScalar}

    ntNOP:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('NOP (%p)',[snode]),vDebugLow);
      {$ELSE}
      ;
      {$ENDIF}
      {$ENDIF}
      //would be nice if we could remove this node here? -speed
      if snode.leftChild=nil then
        //added for optimiser dummy SELECT
      else
        result:=CompleteCondPredicate(st,iter,snode.leftChild,aggregate); //left operand
      if result<>ok then exit; //abort if child aborts
    end;

    {Note: the orderBy node is chained at the table-exp level and can appear in an expression list
           after optimisation, e.g. 'Using' (due to quirky root copy/chain for garbage collection: see insertSelection)
           we ignore it here}

           //there may be more of these!!! need extensive tests!
    ntOrderBy:
    begin
      {$IFDEF DEBUGDETAIL4}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('order-by (%p) - ignoring...',[snode]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      //would be nice if we could remove this node here? -speed
    end;
  else
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unrecognised operator (%d) at %p',[ord(snode.nType),snode]),vDebugError);
    {$ELSE}
    ;
    {$ENDIF}
    result:=fail;
  end; {case}
  //maybe set dtype to unknown or SQL3.boolean/tri-logic? - any need?
end; {CompleteCondPredicate}

function CompleteCondExpr(st:Tstmt;iter:TIterator;snode:TSyntaxNodePtr;aggregate:Taggregation):integer;
{Complete's a conditional expression's syntax tree info, now that we have catalog info available

 IN      :
             st         the statement
             iter       the current iterator (links to iTuple) to take column definitions from
             snode      the syntax sub-tree containing the expression
             aggregate  todo! True=recurse into aggregate function expressions to complete them
                         (used in having(=grouping) calculation)
                        False=use the definition already stored against the aggregate function and don't recurse
                         (used in projection after a grouping & final having test)

 RETURNS :   ok, or fail if error

 Assumes:
   the syntax tree condition has been re-organised into Conjunctive Normal Form
   CNF. Each conjunction is linked via the NextNode pointers.
   e.g.
       =     ->   ( OR )   ->       <>
      a b        <      >          j  k
                d e    f g

   (although some, e.g. CASE, won't have been)
}
const routine=':completeCondExpr';
var
  subNode:TSyntaxNodePtr;
begin
  result:=ok;

  try
    subNode:=snode;
    {For all the sub-trees}
    while (subNode<>nil) do
    begin
      result:=CompleteCondPredicate(st,iter,subnode,aggregate);
      if result<>ok then
        exit; //abort if any child-tree aborts  //Note res may be isTrue... so?

      //no point pulling up type info?

      subNode:=subNode.nextNode; //any more sub-trees?
    end;

  finally
  end; {try}

  result:=ok;
end; {CompleteCondExpr}


end.

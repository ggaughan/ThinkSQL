unit uRoutine;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Stores a routine (procedure/function) definition
}

interface

uses uVariableSet, uGlobal, uStmt, uSyntax;

type
  TRoutine=class
    private
      fname:string;           //name
      fRoutineType:string;    //rtProcedure or rtFunction
      fCatalogName:string;    //catalog name
      fSchemaName:string;     //schema name
      fAuthId:TAuthId;        //auth_id of schema owner (at time of opening, although can it change?)
      fCatalogId:integer;     //catalog_id in system catalog
      fSchemaId:integer;      //schema_id in system catalog (originally used for GRANT adding privilege rows)
      fRoutineId:integer;     //routine_id in system catalog (originally used for GRANT adding privilege rows)
    public
      fVariableSet:TVariableSet;                //this is only the parameter definition set: it must be instantiated in the stmt
      property routineName:string read fname;   //reference from Processor (etc?)
      property catalogName:string read fcatalogName; //reference from Processor (etc?)
      property schemaName:string read fschemaName;   //reference from Processor (etc?)
      property authId:TAuthId read fAuthId;
      property schemaId:integer read fSchemaId;
      property routineId:integer read fRoutineId;

      constructor Create;
      destructor Destroy; override;

      function Open(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;var routineType:string;var routineDefinition:string):integer;
      function CreateNew(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;const routineType:string;const routineDefinition:string):integer;
      function Close:integer;
  end; {TRoutine}

var
  debugRoutineCreate:integer=0;   //todo remove -or at least make private
  debugRoutineDestroy:integer=0;  //"

implementation

uses
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  uTransaction, sysUtils, uRelation{for getOwnerDetails}, uGlobalDef,
  uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}
;

const
  where='uRoutine';
  who='';

constructor TRoutine.create;
begin
  {Create this routine's variableSet definition}
inherited Create;
  inc(debugRoutineCreate);
  {$IFDEF DEBUG_LOG}
  if debugRoutineCreate=1 then
    log.add(who,where,format('  Routine memory size=%d',[instanceSize]),vDebugLow);
  {$ENDIF}
  fVariableSet:=TVariableSet.Create(self);
end; {Create}
destructor TRoutine.Destroy;
const routine=':destroy';
begin
  {Destroy variableSet}
  fVariableSet.free;

  inc(debugRoutineDestroy); //todo remove

  inherited destroy;
end; {Destroy}


function TRoutine.Open(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;var routineType:string;var routineDefinition:string):integer;
{Defines the parameter (variable) set for this routine
 IN       :  st           the statement
          :  find_node    the ntSchema node to search for
          :  schema name  the schema name in case find_node is nil //will be phased out
                                  //although may always need for bootstrap & GC etc.
          //todo pass catalog and schema names
          :  name         the routine name (procedure or function)
 OUT:
          :  routineType         the routine type: rtProcedure or rtFunction //todo pass in as a filter?
          :  routineDefinition   the routine definition

 RETURN   :  +ve=ok
             -2 = unknown catalog
             -3 = unknown schema
             else fail


 Side-effects
   Initialises variable set definition
}
const
  routine=':Open';
var
  s:string;
  n:integer;
  catalog_Id:TcatalogId;
  schema_Id:TschemaId; //schema id of name passed into routine (schemaId is Tr's)
  tempi:integer;
  catalog_name:string;
  routine_auth_id:TauthId; //auth_id of routine schema owner => routine owner
  routine_schema_Id:integer; //schema id of current lookup loop routine
  routine_routine_Id:integer;

  needToFindRoutineOwner:boolean;

  s_null,n_null,routine_routine_Id_null,dummy_null:boolean;
  routineDefinition_null:boolean;
  i:VarRef;

  sysRoutineR, sysParameterR, sysSchemaR:TObject; //Trelation   //todo maybe able to share some as common lookupR? any point?
  tempResult:integer;
  b,bdata:Tblob;
begin
  result:=Fail;
  //todo need a test! if fVariableSet.VarCount=0 then //todo is this the best test for being open? No!! could have 0 parameters!
  if false then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s is already open',[fname]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;

  routine_routine_Id:=0; routine_routine_Id_null:=true;
  needToFindRoutineOwner:=False;

  {Find the parameter definitions}
  begin
    {Find the routine in sysSchema/sysRoutine}
    //todo use future indexed relation.Find() method}
    //Note: we directly access sysRoutine columns
    // - this is bad or good? (rules out system metadata updates via versioning... so!)
      //if we issued SELECT..FROM sysParameter we'd be much more protected/maintainable!

    {first, find the schema id for this routine} //todo check if this is ok if this is the sysSchema table?
    //todo if we ever open routines in db-startup, we may need to default some ids here due to bootstrapping... see createNew
    begin
      begin
        tempResult:=uRelation.getOwnerDetails(st,find_node,schema_name,Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,routine_auth_Id);
        if tempResult<>ok then
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed to find %s',[schema_name]),vDebugError);
          {$ENDIF}
          result:=tempResult;
          exit; //abort
        end;
      end;
    end;

    {Now lookup routine in sysRoutine and get the definition}
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysRoutine,sysRoutineR)=ok then
    begin
      try
        if Ttransaction(st.owner).db.findFirstCatalogEntryByString(st,sysRoutineR,ord(sr_routine_name),name)=ok then
          try
            repeat
              {Found another matching routine for this schema}
              with (sysRoutineR as TRelation) do
              begin
                fTuple.GetInteger(ord(sr_Schema_id),routine_schema_id,dummy_null);  //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                if routine_schema_id=schema_Id then
                begin
                  //todo: also check routineType matches (if we can have a function and a procedure with the same names?) 

                  fTuple.GetInteger(ord(sr_routine_id),routine_routine_Id,routine_routine_Id_null);
                  fTuple.GetString(ord(sr_routine_Type),routineType,dummy_null);
                  if (Ttransaction(st.owner).SchemaVersionMajor<=1) and (Ttransaction(st.owner).SchemaVersionMinor<=00) then
                    fTuple.GetString(ord(sr_routine_definition),routineDefinition,routineDefinition_null)
                  else
                  begin
                    fTuple.GetBlob(ord(sr_routine_definition),b,routineDefinition_null);
                    if not routineDefinition_null then
                      try
                        if fTuple.copyBlobData(st,b,bData)>=ok then //todo use a buffer cache to avoid try..finally etc. here!
                                                             //perhaps just leave freeBlobData to tuple.free/clear(optional)! neatest & best way...
                        begin
                          routineDefinition:='';
                          setLength(routineDefinition,b.len);
                          strMove(pchar(routineDefinition),pchar(bData.rid.pid),b.len);
                        end;
                      finally
                        fTuple.freeBlobData(bData);
                      end; {try}
                  end;
                  {$IFDEF DEBUGDETAIL}
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Found routine %s in %s with id=%d and type=%s, routineDef=%s',[name,sysRoutine_table,routine_routine_Id,routineType,routineDefinition]),vDebugLow);
                  {$ENDIF}
                  {$ENDIF}
                end;
                //else not for our schema - skip & continue looking
              end; {with}
            until (routine_routine_Id<>0) or (Ttransaction(st.owner).db.findNextCatalogEntryByString(st,sysRoutineR,ord(sr_routine_name),name)<>ok);
                  //todo stop once we've found a routine_id with our schema_Id, or there are no more matching this name
          finally
            if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysRoutineR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysRoutine)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        //else routine not found
      //todo move this finally till after we've read the parameters,
      // else someone could drop the routine & we'd fail - or would we? sysCatalog info is versioned! so we'd probably be ok!!!!!
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysRoutine,sysRoutineR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysRoutine)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysTable
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysRoutine)]),vDebugError); 
      {$ELSE}
      ;
      {$ENDIF}
    end;

    if routine_routine_Id<>0 then
    begin
      {Now we've found the routine, if we didn't look up the schema details already, do it now}
      //todo: note: this can be removed I think since needToFindTableOwner is no longer set True
      //- although may be needed for SQL99 because table-owners could be other than schema owner...
      if needToFindRoutineOwner then
      begin
        if Ttransaction(st.owner).db.catalogRelationStart(st,sysSchema,sysSchemaR)=ok then
        begin
          try
            if Ttransaction(st.owner).db.findCatalogEntryByInteger(st,sysSchemaR,ord(ss_schema_id),routine_schema_id)=ok then
            begin
              with (sysSchemaR as TRelation) do
              begin
                fTuple.GetInteger(ord(ss_schema_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                schema_Id:=tempi;
                fTuple.GetInteger(ord(ss_auth_id),tempi,dummy_null); //when we use dummy_null we assume these can never be null, or at least if they are then the value is sensibly 0
                routine_auth_Id:=tempi;
                {$IFDEF DEBUGDETAIL}
                {$IFDEF DEBUG_LOG}
                log.add(st.who,where+routine,format('Found schema %s (%d) owner=%d (from routine)',[schema_name,schema_Id,routine_auth_id]),vDebugLow);
                {$ELSE}
                ;
                {$ENDIF}
                {$ENDIF}
              end; {with}
            end
            else
            begin  //schema not found
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed finding routine schema details %d',[routine_schema_id]),vError);
              {$ELSE}
              ;
              {$ENDIF}
              exit; //abort
            end;
          finally
            if Ttransaction(st.owner).db.catalogRelationStop(st,sysSchema,sysSchemaR)<>ok then
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysSchema)]),vError); 
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        end
        else
        begin  //couldn't get access to sysSchema
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError);
          {$ELSE}
          ;
          {$ENDIF}
          exit; //abort
        end;
      end;


      fAuthId:=routine_auth_Id; //store for later reference
      fSchemaId:=routine_schema_id; //store for later reference
      fRoutineId:=routine_routine_Id; //store for later reference
      {Now load the parameter definitions for the routine}
      if Ttransaction(st.owner).db.catalogRelationStart(st,sysParameter,sysParameterR)=ok then
      begin
        try
          begin
            //todo use future relation.Find() method}
            fVariableSet.varCount:=0; //Note: I think this is the only place we set this to 0 - else we could assert<>0 in uVariableSet.SetVarCount...

            if Ttransaction(st.owner).db.findFirstCatalogEntryByInteger(st,sysParameterR,ord(sp_routine_id),routine_routine_Id)=ok then
              try
                repeat
                  {Found another matching parameter for this routine}
                  with (sysParameterR as TRelation) do
                  begin
                    fTuple.GetInteger(ord(sp_parameter_id),n,n_null); //assume never null
                    self.fVariableSet.fVarDef[self.fVariableSet.varCount].id:=n;
                    fTuple.GetString(ord(sp_parameter_name),s,s_null); //assume never null
                    self.fVariableSet.fVarDef[self.fVariableSet.varCount].name:=s;

                    fTuple.GetInteger(ord(sp_variabletype),n,n_null);
                    self.fVariableSet.fvarDef[self.fVariableSet.varCount].variableType:=TvariableType(n);
                    fTuple.GetInteger(ord(sp_datatype),n,n_null); //todo cross-ref domain id? assume never null
                    //todo assert ord(first)<=n<=ord(last)
                    self.fVariableSet.fvarDef[self.fVariableSet.varCount].dataType:=TDataType(n);
                    fTuple.GetInteger(ord(sp_width),n,n_null); //assume never null
                    self.fVariableSet.fvarDef[self.fVariableSet.varCount].width:=n;
                    fTuple.GetInteger(ord(sp_scale),n,n_null); //assume never null
                    self.fVariableSet.fvarDef[self.fVariableSet.varCount].scale:=n;

                    fTuple.GetString(ord(sp_default),s,s_null);
                    if not s_null then self.fVariableSet.fvarDef[self.fVariableSet.varCount].defaultVal:=s;
                    self.fVariableSet.fvarDef[self.fVariableSet.varCount].defaultNull:=s_null;
                    //todo check that these ^ are cleared since we don't always blank them

                    //todo & rest of var definition
                    {$IFDEF DEBUGDETAIL}
                    {$IFDEF DEBUG_LOG}
                    log.add(st.who,where+routine,format('Found (%d) parameter %s in %s with id=%d',[ord(self.fVariableSet.fvarDef[self.fVariableSet.varCount].variableType),self.fVariableSet.fvarDef[self.fVariableSet.varCount].name,sysColumn_table,self.fVariableSet.fvarDef[self.fVariableSet.varCount].id]),vDebugLow);
                    {$ENDIF}
                    {$ENDIF}
                    self.fVariableSet.varCount:=self.fVariableSet.varCount+1; //add this parameter
                  end; {with}
                until Ttransaction(st.owner).db.findNextCatalogEntryByInteger(st,sysParameterR,ord(sp_routine_id),routine_routine_Id)<>ok;
                      //todo stop once we're past our routine_id if sysParameter is sorted... -speed - this logic should be in Find routines...
              finally
                if Ttransaction(st.owner).db.findDoneCatalogEntry(st,sysParameterR)<>ok then
                  {$IFDEF DEBUG_LOG}
                  log.add(st.who,where+routine,format('Failed ending scan on catalog relation %d',[ord(sysParameter)]),vError); 
                  {$ELSE}
                  ;
                  {$ENDIF}
              end; {try}
            //else routine has no parameters = ok
          end;
        finally
          if Ttransaction(st.owner).db.catalogRelationStop(st,sysParameter,sysParameterR)<>ok then
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysParameter)]),vError); 
            {$ELSE}
            ;
            {$ENDIF}
        end; {try}
      end
      else
      begin  //couldn't get access to sysParameter
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysParameter)]),vDebugError); 
        {$ELSE}
        ;
        {$ENDIF}
      end;

      {Now ensure our parameter definitions are in Id order, because the heapfile scan doesn't guarantee this}
      self.fVariableSet.OrderVarDef;
      //todo check result!
    end;
    //else routine name not found (for this schema)
  end;

  if routine_routine_Id<>0 then
  begin
    //todo compile it now?
    fname:=name;
    froutineType:=routineType;
    fCatalogName:=catalog_name;
    fSchemaName:=schema_name;
    //todo set ..ids as well?
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s %s opened',[schema_name,name]),vDebugMedium);
    log.add(st.who,where+routine,self.fVariableSet.showHeading,vDebugMedium);
    {$ENDIF}
    {$ENDIF}
    result:=ok;
  end
  else
  begin
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s %s not found',[schema_name,name]),vError) //todo remove error: ok if called by createNew!
    {$ENDIF}
    {$ENDIF}
  end;
end; {Open}

function TRoutine.CreateNew(st:TStmt;find_node:TSyntaxNodePtr;schema_name:string;const name:string;const routineType:string;const routineDefinition:string):integer;
{Adds the routine definition to the system catalog
 IN       :  st                the statement
          :  find_node         the ntSchema node to search for
          :  schema name       the schema name (must already exist) in case find_node is nil //will be phased out
                                                            //although may always need for initial bootstrap creations
          :  name              the routine name
          :  routineType       the routine type: rtProcedure or rtFunction
          :  routineDefinition the routine definition
 RETURN   :  +ve=ok,
             -2 = routine already exists
             -3 = not privileged to add to this schema
             -4 = unknown catalog
             -5 = unknown schema
             else fail

 Side-effects
   Add the routine and parameter definitions to the system catalog

 Notes:
   Don't call Open afterwards - just use

   We check whether we're privileged or not, e.g. schema auth_id=tr.authId
   (otherwise UserA could create a table in a schema owned by UserB and so not have privileges to it!)
}
const routine=':createNew';
var
  i:varRef;
  rid:Trid;
  routine_Id,genId:integer;
  s:string;
  null:boolean;

  auth_id:TauthId; //auth_id of schema => routine owner
  catalog_Id:TcatalogId;
  schema_Id:TschemaId; //schema id of name passed into routine (schemaId is Tr's)
  catalog_name:string;

  sysRoutineR, sysParameterR:TObject; //Trelation
  rDefinition:string;
  rType:string;
  tempResult:integer;
  b:Tblob;
begin
  result:=fail;
  //todo need a test! if fVariableSet.VarCount=0 then //todo is this the best test for being open? No!! could have 0 parameters!
  if false then
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s is already open',[fname]),vAssertion);
    {$ENDIF}
    exit; //abort
  end;

  {first, find the schema id for this routine} //todo check if this is ok if this is the sysSchema table?
  if schema_name=sysCatalogDefinitionSchemaName then
  begin
    //we only *need* to assume this before sysSchema is open (currently if db.createdb is creating sys routines)
    // - otherwise we have a chicken and egg loop: trying to find schema id for (or before) schema id routine
    // but it's faster anyway to always assume it (although the routines are only created once per db)
    schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation/open algorithm
    auth_id:=Ttransaction(st.owner).authId; //use default if none specified
                     //todo? assert =our default schema's authid - for SQL92 but not for SQL3? check specs!
                     //Note: this creates a loophole: any authId can create tables in sysCatalogDefinitionSchemaName!
  end
  else
  begin
    {Now we've defaulted the schema name, should we still skip checks because of bootstrap?}
    if schema_name=sysCatalogDefinitionSchemaName then
    begin
      //we only *need* to assume this before sysSchema is open (currently if db.createdb is creating sys tables)
      // - otherwise we have a chicken and egg loop: trying to find schema id for (or before) schema id table
      // but it's faster anyway to always assume it (although the relations are only created once per db)
      schema_Id:=sysCatalogDefinitionSchemaId; //assumed based on catalog creation/open algorithm
      auth_id:=Ttransaction(st.owner).authId; //use default if none specified
                       //todo? assert =our default schema's authid - for SQL92 but not for SQL3? check specs!
                       //Note: this creates a loophole: any authId can create tables in sysCatalogDefinitionSchemaName!
    end
    else
    begin {Now lookup the schema_id and compare it's auth_id with this user's - if they don't match we fail}
      tempResult:=uRelation.getOwnerDetails(st,find_node,schema_name,Ttransaction(st.owner).schemaName,catalog_Id,catalog_name,schema_Id,schema_name,auth_Id);
      if tempResult<>ok then
      begin  //couldn't get access to sysSchema
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Unable to access catalog relation %d to find %s',[ord(sysSchema),schema_name]),vDebugError); 
        {$ENDIF}
        case tempResult of -2: result:=-4; -3: result:=-5; end; {case}
        exit; //abort
      end;
      {Now check that we are privileged to add entries to this schema}
      if auth_Id<>Ttransaction(st.owner).authId then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('%d not privileged to insert into schema authorised by %d',[Ttransaction(st.owner).authId,auth_id]),vError);
        {$ENDIF}
        result:=-3;
        exit; //abort
      end;
    end;
  end;

  {Check this routine is not already in sysRoutine: if it is, return error}
  if open(st,find_node,schema_name,name,rType,rDefinition)<>fail then  //i.e. +2 = opened routine ok
  begin
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s already exists',[fname]),vError);
    {$ENDIF}
    result:=-2;
    close;
    exit; //abort
  end;

  {todo: compile the routine now ready for use?}

  {Add entry to sysRoutine}
  //todo: obviously using INSERT...INTO would be safer
  if Ttransaction(st.owner).db.catalogRelationStart(st,sysRoutine,sysRoutineR)=ok then
  begin
    try
      //now we could do: if Ttransaction(st.owner).db.findCatalogEntryByString(st,sysRoutineR,ord(sr_routine_name),name)=ok then already exists
      //-but we'll leave that to caller/elsewhere
      with (sysRoutineR as TRelation) do
      begin
        fTuple.clear(st);
        //todo check results!
        {Note: it is *vital* that these are added in sequential order - else strange things happen!}
        genId:=0; //lookup by name
        (Ttransaction(st.owner).db).getGeneratorNext(st,sysCatalogDefinitionSchemaId,'sysRoutine_generator',genId,Routine_Id); //todo check result!
        fTuple.SetInteger(ord(sr_routine_id),Routine_Id,false);
        fTuple.SetString(ord(sr_routine_name),pchar(name),false);  //assume never null
        fTuple.SetInteger(ord(sr_schema_id),schema_Id,false);
        fTuple.SetInteger(ord(sr_module_id),0{todo future use},false);
        fTuple.SetString(ord(sr_routine_Type),pchar(routineType),false); //assume never null
        if (Ttransaction(st.owner).SchemaVersionMajor<=1) and (Ttransaction(st.owner).SchemaVersionMinor<=00) then
          fTuple.SetString(ord(sr_routine_definition),pchar(routineDefinition),False) //todo remove://assume never null
        else
        begin
          b.rid.sid:=0; //i.e. in-memory blob
          b.rid.pid:=pageId(pchar(routineDefinition)); //pass data pointer as blob source in memory //note: assumes will remain while blob remains!
          b.len:=length(routineDefinition); //todo use stored length in case blob contains #0 
          fTuple.SetBlob(st,ord(sr_routine_definition),b,False); //todo remove://assume never null
          //todo if result<>ok then exit;
        end;
        fTuple.SetInteger(ord(sr_Next_parameter_id),self.fVariableSet.fvarDef[self.fVariableSet.varCount-1].id+1,false);  //future parameter ids start at final varId +1 //todo assume last in array=highest var id! ok?
        fTuple.insert(st,rid); //Note: obviously this bypasses any constraints
      end; {with}
      fAuthId:=auth_Id; //store for later reference
      fSchemaId:=schema_Id; //store for later reference
      fRoutineId:=routine_Id; //store for later reference
      {$IFDEF DEBUGDETAIL5}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Inserted %s %s into %s',[schema_name,name,sysRoutine_table]),vdebug);
      {$ENDIF}
      {$ENDIF}
      
    //todo move this finally till after we've added the parameters,
    // else someone could drop the routine & we'd fail - or would we? sysCatalog info is versioned! so we'd probably be ok!
    finally
      if Ttransaction(st.owner).db.catalogRelationStop(st,sysRoutine,sysRoutineR)<>ok then
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysRoutine)]),vError); 
        {$ELSE}
        ;
        {$ENDIF}
    end; {try}
  end
  else
  begin  //couldn't get access to sysTable
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysRoutine)]),vDebugError); 
    {$ELSE}
    ;
    {$ENDIF}
  end;

  {Now add this routine's parameter entries to sysParameter}
  if self.fVariableSet.varCount>0 then
  begin
    if Ttransaction(st.owner).db.catalogRelationStart(st,sysParameter,sysParameterR)=ok then
    begin
      try
        with (sysParameterR as TRelation) do
        begin
          for i:=0 to self.fVariableSet.varCount-1 do
          begin
            //todo check results!
            {Note: it is *vital* that these are added in sequential order - else strange things happen!}
            fTuple.clear(st);
            fTuple.SetInteger(ord(sp_routine_id),routine_Id,false);
            fTuple.SetInteger(ord(sp_parameter_id),self.fVariableSet.fvarDef[i].id,false);
            s:=self.fVariableSet.fvarDef[i].name;
            fTuple.SetString(ord(sp_parameter_name),pchar(s),false); //assume never null
            fTuple.SetInteger(ord(sp_variabletype),ord(self.fVariableSet.fvarDef[i].variableType),false);
            fTuple.SetInteger(ord(sp_datatype),ord(self.fVariableSet.fvarDef[i].dataType),false);
            fTuple.SetInteger(ord(sp_width),self.fVariableSet.fvarDef[i].width,false);
            fTuple.SetInteger(ord(sp_scale),self.fVariableSet.fvarDef[i].scale,false);
            fTuple.SetString(ord(sp_default),pchar(self.fVariableSet.fvarDef[i].defaultVal),self.fVariableSet.fvarDef[i].defaultNull);
            fTuple.insert(st,rid); //Note: obviously this bypasses any constraints
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Inserted parameter %s of %s into %s',[self.fVariableSet.fvarDef[i].name,name,sysParameter_table]),vdebugLow);
            {$ENDIF}
            {$ENDIF}
          end;
        end; {with}
        {$IFDEF DEBUGDETAIL5}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Inserted %s parameters into %s',[name,sysParameter_table]),vdebug);
        {$ENDIF}
        {$ENDIF}
      finally
        if Ttransaction(st.owner).db.catalogRelationStop(st,sysParameter,sysParameterR)<>ok then
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Failed releasing catalog relation %d',[ord(sysParameter)]),vError); 
          {$ELSE}
          ;
          {$ENDIF}
      end; {try}
    end
    else
    begin  //couldn't get access to sysColumn
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Unable to access catalog relation %d',[ord(sysParameter)]),vDebugError); 
      {$ELSE}
      ;
      {$ENDIF}
    end;
  end;
  //else no parameters

  begin
    fname:=name;
    froutineType:=routineType;
    fSchemaName:=schema_name;
    fCatalogName:=catalog_name;
    //todo set ..ids here?
    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,format('Routine %s %s created (auth_id=%d)',[schema_name,name,auth_id]),vDebug);
    {$ENDIF}
    {$ENDIF}
  end;

  result:=ok;
end; {CreateNew}

function TRoutine.Close:integer;
{Close the routine
 RETURN   :  +ve=ok, else fail

 Side effects:
}
const routine=':Close';
begin
  result:=fail;
  //todo need a test! if fVariableSet.VarCount=0 then //todo is this the best test for being open? No!! could have 0 parameters!
  if false then
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,'Routine is not open',vAssertion)
    {$ENDIF}
  else
  begin
    //todo maybe here we should unprepare?

    {$IFDEF DEBUGDETAIL5}
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Routine %s closed',[fname]),vDebug);
    {$ENDIF}
    {$ENDIF}
    //todo reset variableSet definitions to aid debugging?
    result:=ok;
  end;
end; {Close}


end.

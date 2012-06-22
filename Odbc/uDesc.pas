unit uDesc;

interface

uses uMain {to access ODBC.inc defs}, uDiagnostic;

const
  desc_name_SIZE=30+1; //todo max_col_name_size from server global  //todo replace 1 with unicode friendly sizeof(nullterm)

type
  TdescRec=class
  private
  public
    RecordNumber:SQLSMALLINT;
    desc_auto_unique_value:SQLINTEGER;
    desc_base_column_name:pSQLCHAR;
    desc_base_table_name:pSQLCHAR;
    desc_name:pSQLCHAR;
    //todo etc.
    desc_data_ptr:SQLPOINTER;                 //deferred
    desc_octet_length:SQLINTEGER;
    desc_length:SQLUINTEGER;
    desc_octet_length_pointer:SQLPOINTER;     //deferred
    desc_indicator_pointer:SQLPOINTER;        //deferred
    //todo etc.
    desc_concise_type:SQLSMALLINT;
    desc_type:SQLSMALLINT;                    //Note: this is lossy for date/time types- internally always use desc_concise_type instead!
    desc_datetime_interval_code:SQLSMALLINT;
    desc_datetime_interval_precision:SQLSMALLINT;
    desc_precision:SQLINTEGER; //07/01/03 was SQLSMALLINT pre-blobs;
    desc_scale:SQLSMALLINT;
    desc_nullable:SQLSMALLINT;
    desc_unsigned:SQLSMALLINT;
    //todo etc.
    desc_parameter_type:SQLSMALLINT;          //desc_parameter_mode in standard
    //todo etc.
    next:TdescRec;

    constructor Create;
    destructor Destroy; override;
    procedure resetDefaults;
  end; {TdescRec}

  Tdesc=class
  private
    {Records}
    descRecList:TdescRec;
  public
    owner:TObject; //Tstmt  //todo could be Tdbc ?? check?
    diagnostic:Tdiagnostic;

    desc_type:SQLSMALLINT; {used to identify desc type when passed into routines without stmt.
                            We use pre-defined 'standard' values just because they're there.
                            Would be much better to use Pascal types! //todo?
                            One of SQL_ATTR_APP_ROW_DESC,SQL_ATTR_APP_PARAM_DESC,SQL_ATTR_IMP_ROW_DESC,SQL_ATTR_IMP_PARAM_DESC}

    {Header}
    desc_alloc_type:SQLSMALLINT;
    desc_array_size:SQLuINTEGER;
    desc_array_status_ptr:SQLPOINTER;    //deferred
    desc_bind_offset_ptr:SQLPOINTER;     //deferred
    desc_bind_type:SQLUINTEGER;
    //todo etc.
    desc_count:SQLSMALLINT;     //todo: limits cols to 32765 ?
    desc_rows_processed_ptr:pSQLuINTEGER;

    constructor Create(dtype:SQLSMALLINT);
    destructor Destroy; override;

    function GetRecord(rNumber:SQLSMALLINT;var dr:TDescRec;AddIfNotExist:boolean):integer;
    function PurgeRecords:integer;
  end; {Tdesc}

implementation

uses uGlobal;

constructor Tdesc.Create(dtype:SQLSMALLINT);
{
 IN:        dtype   = desc_type

 Notes:
   it is up to the creator to set desc_alloc_type to SQL_DESC_ALLOC_AUTO if it is an implicit creation
   Also, currently we don't check the value of dtype!

   //todo also pass owner in! could be stmt or dbc?
}
begin
  diagnostic:=TDiagnostic.create;
  desc_type:=dtype;
  //todo check the type is valid - wouldn't have to if we used Pascal types!
  descRecList:=nil;
  desc_alloc_type:=SQL_DESC_ALLOC_USER; //default to user requested creation
  desc_array_size:=1; //single-row fetch
  desc_array_status_ptr:=nil;
  desc_bind_offset_ptr:=nil;
  desc_bind_type:=SQL_BIND_BY_COLUMN; //default
  desc_count:=0;
end; {create}
destructor Tdesc.Destroy;
var
  i:integer;
  res:integer;
begin
  {clear up any remaining in descRecList}
  if desc_count<>0 then
  begin
    //todo is this an assertion error, or the best way of cleaning up bound columns?
    //- if it is an error log it now!!!
    // - normally FreeStmt(sql_unbind) would do this - any other ways?

    //we needn't tell the server about such unbindings if each desc had a unique
    //handle - although then the server would have garbage lying around = bad
    //maybe a neater way would be to send server a bind/unbind(from-to) command
    //=> less traffic - but user binds one at a time... but still we can mass-unbind...

    {22/11/99: since this is called after freehandle(stmt) has been called on the server
               there is no need to unbind columns on the server, since such actions will
               fail & generate a server 'invalid handle' error.
               So, for now, we skip this code if SQL_DESC_ALLOC_AUTO
               because in future, e.g. non-implicit descs, we may need to call it //TODO

               Although, this doesn't seem to have fixed the problem, since other clients
               unbind their columns after freeing the stmt, so we need the server to
               silently ignore such unbindings...
               still, keeping this code here avoids traffic... 
    }

    if desc_alloc_type<>SQL_DESC_ALLOC_AUTO then
    begin
      {Unbind any bound columns}
      for i:=1 to desc_count do
      begin
        res:=SQLSetDescField(SQLHDESC(self),i,SQL_DESC_DATA_POINTER,nil,00);
        if res=SQL_ERROR then //todo should probably log this error (again!) somehow, but we must continue here!
        begin
          //todo remove!: d.diagnostic.logError('TODO!',fail,'textTODO!'); //todo correct?pass details! //todo check result
          //todo remove! exit;
        end;
      end;
    end;
    desc_count:=0;
    PurgeRecords; //todo check result?
  end;
  diagnostic.free;

  inherited;
end; {destroy}

function Tdesc.GetRecord(rNumber:SQLSMALLINT;var dr:TDescRec;AddIfNotExist:boolean):integer;
{Find the desc record with the specified record number.
 If AddIfNotExist and one doesn't exist, create it and increase the desc_count accordingly
 IN:            rNumber              - the record number
                AddIfNotExist        - True-> if one doesn't exist, create it and increase the desc_count accordingly
                                       False->returns fail if not found
 OUT:           dr                   - the TdescRec reference (only use if result=ok - then guranteed ok?!//todo check!)
 RETURNS:       ok, else fail
}
var
  curDr, trailDr:TdescRec;
begin
  result:=fail;
  //to improve the search routines we build & keep the list in recordNumber order
  //- maybe improve speed by using double-links instead of trailer etc..
  // also search locally from last searched position

  curDr:=descRecList;
  trailDr:=nil;
  while curDr<>nil do
  begin
    if curDr.RecordNumber>=rNumber then break; //found or found correct insertion place
    trailDr:=curDr;
    curDr:=curDr.next;
  end;

  if (curDr=nil) or (curDr.RecordNumber<>rNumber) then //Note: boolean s-c.
  begin //not found, create a new record
    if AddIfNotExist then
    begin
      //todo maybe if curDr=nil, then caller should manually increase desc_count first
      // - if so, reject here if rNumber>desc_count
      curDr:=TdescRec.create;
      curDr.RecordNumber:=rNumber;
      {Increase the desc_count (automatically) if necessary}
      if rNumber>desc_count then desc_count:=rNumber;
      {Now link into the ordered list}
      if trailDr=nil then
      begin //this is to be inserted at the head of the list
        curDr.next:=descRecList;
        descRecList:=curDr;
      end
      else
      begin
        curDr.next:=trailDr.next;
        trailDr.next:=curDr;
      end;
    end
    else
      exit; //returns fail if caller asked for no record to be created 
  end;

  dr:=curDr;

  result:=ok;
end; {GetRecord}

function Tdesc.PurgeRecords:integer;
{Remove any garbage records (i.e. those numbered > desc_count) - as per ODBC standard

 Assumes:
   the server has been informed that the dead column are now unbound

 RETURNS:       ok, else fail
}
var
  curDr, trailDr, nextDr:TdescRec;
begin
  result:=fail;
  //to improve the search routines we build & keep the list in recordNumber order
  //- maybe improve speed by using double-links instead of trailer etc..
  // also search locally from last searched position

  {Because these are stored in recordNumber order, once we find one larger than
   desc_count, we can delete the rest of the list}
  curDr:=descRecList;
  trailDr:=nil;
  while curDr<>nil do
  begin
    if curDr.RecordNumber>desc_count then break; //found correct place to delete from
    trailDr:=curDr;
    curDr:=curDr.next;
  end;

  if (curDr<>nil) then
  begin //found some greater than desc_count, zap from here to end of list
    while curDr<>nil do
    begin
      nextDr:=curDr.next;
      //todo assert dataPtr=nil - else may=> server thinks it's still bound
      curDr.free;
      curDr:=nextDr;
    end;
    if trailDr=nil then
      descRecList:=curDr
    else
      trailDr.next:=curDr;
  end;

  result:=ok;
end; {PurgeRecords}

////// TDescRec


constructor TdescRec.Create;
begin
  {Defaults}
  desc_data_ptr:=nil;  //=0 => unbound
  desc_type:=SQL_C_DEFAULT;

  {todo any need to reset these? - use resetDefaults
  desc_scale:SQLSMALLINT;
  desc_precision:SQLSMALLINT;
  desc_nullable:SQLSMALLINT;
  }
  {Pre-allocate space}
  getmem(desc_name,desc_name_SIZE);
  //todo etc.
end; {create}
destructor TdescRec.Destroy;
begin
  freemem(desc_name,desc_name_SIZE);
  //todo etc.

  inherited;
end; {destroy}

procedure TdescRec.resetDefaults;
{Used if the type is reset (etc.)
}
begin
  desc_data_ptr:=nil;
  //todo etc.
end; {resetDefaults}



end.

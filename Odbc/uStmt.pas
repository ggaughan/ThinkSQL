unit uStmt;

interface

uses uMain {for ODBC.inc},uDiagnostic, uDesc;

type
  TcursorState=(csClosed,
                csOpen
                //todo etc.
               );
  Tcursor=record
    state:TcursorState;
    name:string; //todo limit?
    scrollable:boolean;
    //todo Trid
    //todo handle to TIterator?
  end; {Tcursor}


  TstmtState=(S0, //Unallocated statement
              S1, //Allocated statement
              S2, //Prepared statement. No result set will be created
              S3, //Prepared statement. A (possibly empty) result set will be created
              S4, //Statement executed and no result set was created
              S5, //Statement executed and a (possibly empty) result set was created. The cursor is open and positioned before the first row of the result set.
              S6, //Cursor positioned with SQLFetch or SQLFetchScroll.
              S7, //Cursor positioned with SQLExtendedFetch
              S8, //Function needs data. SQLParamData has not been called
              S9, //Function needs data. SQLPutData has not been called
              S10,//Function needs data. SQLPutData has been called
              S11,//Still executing. A statement is left in this state after a function that is executed asynchronously returns SQL_STILL_EXECUTING. A statement is temporarily in this state while any function that accepts a statement handle is executing. Temporary residence in state S11 is not shown in any state tables except the state table for SQLCancel. While a statement is temporarily in state S11, the function can be canceled by calling SQLCancel from another thread.
              S12 //Asynchronous execution canceled. In S12, an application must call the canceled function until it returns a value other than SQL_STILL_EXECUTING. The function was canceled successfully only if the function returns SQL_ERROR and SQLSTATE HY008 (Operation canceled). If it returns any other value, such as SQL_SUCCESS, the cancel operation failed and the function executed normally.
              );

  Tstmt=class
  private
  public
    owner:TObject; //Tdbc
    state:TstmtState;
    diagnostic:Tdiagnostic;

    //todo make private & provide properties to read/write them
    ard:Tdesc;
    apd:Tdesc;
    ird:Tdesc;
    ipd:Tdesc;

    //todo maybe statementText to store SQL text - but could be massive = waste of memory?

    prepared:boolean; {also used to pass to closeCursor on server to remove plan or not}
    resultSet:boolean;
    cursor:Tcursor;
    rowCount:SQLINTEGER;

    //todo add latestParamRn here: set by SQLExecute/SQLParamData and referenced by SQLPutData: then can chunk

    ServerStatementHandle:integer; {-> stmtPlan ref on server}

    metadataId:integer;

    constructor Create;
    destructor Destroy; override;
  end; {Tstmt}

function GetDefaultCursorName:string;


implementation

uses sysUtils;

constructor Tstmt.Create;
//todo also pass owner in!
begin
  diagnostic:=TDiagnostic.create;
  {Implicitly allocated descriptors}
  ard:=Tdesc.create(SQL_ATTR_APP_ROW_DESC);
  Tstmt(ard.owner):=self;
  ard.desc_alloc_type:=SQL_DESC_ALLOC_AUTO;

  apd:=Tdesc.create(SQL_ATTR_APP_PARAM_DESC);
  apd.desc_alloc_type:=SQL_DESC_ALLOC_AUTO;
  Tstmt(apd.owner):=self;

  ird:=Tdesc.create(SQL_ATTR_IMP_ROW_DESC);
  ird.desc_alloc_type:=SQL_DESC_ALLOC_AUTO;
  Tstmt(ird.owner):=self;

  ipd:=Tdesc.create(SQL_ATTR_IMP_PARAM_DESC);
  ipd.desc_alloc_type:=SQL_DESC_ALLOC_AUTO;
  Tstmt(ipd.owner):=self;

  {default attributes}
//todo  metadataId:=1; //todo ?check correct setting
  metadataId:=SQL_FALSE; 

  prepared:=False;
  resultSet:=False;

  cursor.state:=csClosed;
  cursor.name:='';
  cursor.scrollable:=false;

  rowCount:=0;


  ServerStatementHandle:=0;

  state:=S0;
end; {create}
destructor Tstmt.Destroy;
begin
  //todo: assert ServerStatementHandle has been unprepared on server
  // freeStmt(..unbind)?
  // freeStmt(..close)?
  //todo assert state!

  //todo: note: we shouldn't need to call these here:
  //      caller should have done it explicitly
  //      or freeHandle will have done it implicitly
  //      So, we can ignore any Fail results... i.e. expect fail 'invalid handle'! //todo assert if not!?
  //       - or actually handle is still valid here, so may return OK and do nothing because state=not-open...
  //      TODO: what if we lost the connection and are just tidying up here,
  //            won't calling the server to close/unbind create more problems? better to just free our own
  //            resources?
  //      Also, sqlDisconnect routine (Xcurrently) used to! assumes these are called here...      
  SQLfreeStmt(SQLHSTMT(self),SQL_UNBIND); //todo check result?
  SQLfreeStmt(SQLHSTMT(self),SQL_CLOSE); //todo check result?

  ipd.free;
  ird.free;
  apd.free;
  ard.free;

  diagnostic.free;

  inherited;
end; {destroy}

function GetDefaultCursorName:string;
begin
  result:='SQLCUR_'+intToStr(trunc(random*999999));  //todo improve! & guarantee unique!
end; {GetDefaultCursorName}

end.

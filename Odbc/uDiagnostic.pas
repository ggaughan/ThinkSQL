unit uDiagnostic;

{Storage for holding ODBC diagnostic information
 - this may be better at the server-end - especially for stmt resources? todo
}

{$DEFINE DEBUGDETAIL}

interface

uses uMain {to access ODBC.inc defs};

type
  TsqlState=(ssFirst,
             ss01002,ss01004,ss01S00,ss01S02,ss01S07,
             ss07005,ss07006,ss07009,
             ss08001,ss08002,ss08003,ss08004,ss08S01,
             ss21S01,
             ss22002,ss22003,ss22012,ss22018,
             ss24000,
             ss25000,
             ss42000,ss42S01,ss42S02,ss42S22,
             ssHY000,ssHY003,ssHY004,ssHY010,ssHY011,ssHY016,ssHY024,ssHY090,ssHY091,ssHY092,ssHY096,ssHY097,ssHY098,ssHY099,ssHY106,
             ssHYC00,ssHYT00,ssHYT01,

             ssNA,
             ssTODO,
             ssLast
            );

  TsqlStateText=array [0..SQL_SQLSTATE_SIZE-1] of char; // string[SQL_SQLSTATE_SIZE];

  PtrTerror=^Terror;
  Terror=record
    sqlstate:TsqlState;
    native:integer;
    text:string;
    row:SQLINTEGER;  //only applies to stmts
    rn:SQLINTEGER;   //only applies to stmts
    //todo etc.
    next:PtrTerror;
  end; {Terror}

  Tdiagnostic=class
  private
    ferrorCount:integer;
    ferrorNextToRead:integer; //for SQLerror
    errorList:PtrTerror;
    function addError(e:PtrTerror):integer;

  public
    property errorCount:integer read ferrorCount;
    property errorNextToRead:integer read ferrorNextToRead write ferrorNextToRead;

    constructor create;
    destructor destroy; override;

    function logError(sqlstate:TsqlState;native:integer; text:string;row:SQLINTEGER;rn:SQLINTEGER):integer;
    function getError(rnum:integer;var e:PtrTerror):integer;
    procedure clear;
  end; {Tdiagnostic}

implementation

uses uGlobal, uStrings, sysUtils;

constructor Tdiagnostic.create;
begin
  ferrorCount:=0;
  errorList:=nil;
end; {create}
destructor Tdiagnostic.destroy;
begin
  {remove any remaining allocated memory
   this should not be necessary if the connection was disconnected properly,
   but we can't guarantee this I don't think.
  }
  self.clear;
  //todo assert errorlist=nil
  
  inherited destroy;
end; {destroy}

procedure Tdiagnostic.clear;
var
  zap:PtrTerror;
begin
  while errorList<>nil do
  begin
    zap:=errorList;
    errorList:=errorList^.next;
    //todo de-allocate text?
    dispose(zap);
    //todo assert that we dispose ferrorCount nodes
  end;
  ferrorCount:=0;
  ferrorNextToRead:=0;
end; {clear}

function Tdiagnostic.addError(e:PtrTerror):integer;
{Link the error node into the error list}
var
  trailNode,node:PtrTerror;
begin
//todo needs to be a prioritised insertion, sorted by e^.row -according to ODBC, for stmts at least
//todo also needs to be sorted by error state code... see spec.
  {Find the correct place for this node}
  trailNode:=nil;
  node:=errorlist;
  if node<>nil then  //todo would be tidier with a fixed header node!
  begin
    while (node.Next<>nil) and (node.row<e.row){todo replace with isMoreCriticalThan function} do
    begin
      trailNode:=node;
      node:=node.next;
    end;

    if trailNode<>nil then
    begin
      e^.next:=trailNode;
      trailNode.next:=e;
    end
    else
    begin //insert before current 1st node (node=errorlist)
      e^.next:=node.next;
      node.next:=e;
    end;
  end
  else
  begin
    errorList:=e;
  end;
(*todo remove old code
  e^.next:=errorList;
  errorList:=e;
*)
  result:=ok;
end; {addError}

function Tdiagnostic.logError(sqlstate:TsqlState;native:integer;{todo remove: need to copy memory! const }text:string;row:SQLINTEGER;rn:SQLINTEGER):integer;
{Create a new error node and add it to the list

//maybe return the err pointer so the caller can add extra field values?
//or don't use this function & be like getError: caller creates error & fills it then calls addError directly

//todo check all callers don't just use SQL_NO_ROW_NUMBER,SQL_NO_COLUMN_NUMBER when they should pass info!
}
var
  err:PtrTerror;
  s:string;
begin
  //todo if sqlState=ssTODO then assertion when live!
  new(err);
  err^.next:=nil;
  err^.sqlstate:=sqlstate; //todo remove:ssStateText[sqlstate];
  err^.native:=native;
  s:='['+Vendor+']['+ODBC_component+'] '+ssErrText[sqlState]+':'{todo colon ok?}+text; //todo insert : if text<>'' //if this is empty - use a lookup table to fill in the default/standard messages
  err^.text:=s; //explicitly make a copy? //todo remove comment-no need??
  err^.row:=row;
  err^.rn:=rn;
  inc(ferrorCount);
  result:=addError(err);
  {$IFDEF DEBUGDETAIL}
  log(format('logError: %d %s  ',[err^.native,err^.text]));
  {$ENDIF}
end; {logError}

function Tdiagnostic.getError(rnum:integer;var e:PtrTerror):integer;
{  IN:      rnum     error number starting at 1
   OUT:     e        error pointer, nil if not found
}
var
  cur:PtrTerror;
  curnum:integer;
begin
//todo improve speed/structure!
  e:=nil;
  curnum:=0;
  cur:=errorList;
  while (cur<>nil) and (curnum<rnum) do
  begin
    inc(curnum);
    if curnum=rnum then e:=cur; //found! set result
    cur:=cur^.next;
  end;
  result:=ok;
end;


end.

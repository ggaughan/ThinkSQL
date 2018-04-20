unit uParser;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGPARSER}
//{$DEFINE DEBUGDETAIL}

{Parses a SQL statement and creates a parse tree (superseded by ExecSQL)

 Also contains ExecSQL (stub?) to parse + execute a list of statements
}

//TODO!
//       It's looking like we need to keep ExecSQL for dumb clients, but bad for maintenance, so:
//       convert ExecSQL to:
//         still add iterOutput (rename to iterOutputTextToDumbClient or some such)
//         call SQLprepare, SQLexecute and SQLFetch until noMore...


interface

uses
{$IFDEF Debug_log}
  uLog,
{$ENDIF}
  sysUtils, uTransaction, uStmt, uServer, uSyntax, uProcessor, uIterator,
  uGlobal, Math{for power in lex install_num}, SyncObjs,
  IdTCPConnection,
  uMarshalGlobal {in '..\Odbc\uMarshalGlobal.pas'} {for se* error constants}  {todo: put in implementation section!}
;

function ExecSQL(st:TStmt;{const }sql:string;connection:TIdTCPConnection;var resultRowCount:integer):integer;

function ParseSubSQL(st:TStmt;const sql:string;var sroot:TSyntaxNodePtr):integer;
function PrepareSQL(st:TStmt;iter:TIterator;const sql:string):integer;

var
  CSparserMutex:TCriticalSection;  //protect single threaded parser routine //todo remove need in future
  GlobalParseRoot:TSyntaxNodePtr;     //return parse tree root to parser (not multithread-protected)
  GlobalSyntaxErrLine,GlobalSyntaxErrCol:integer{word}; //used to return parser error details //todo too small=could break?
  GlobalSyntaxErrMessage:string;         //used to return parser error context


implementation
uses
  uEvsHelpers
  ,lexlib,yacclib;//moved here from sql.pas because d2007 deadlocks it self.

{$INCLUDE SQL}        //this includes the yacc/lex parser engine
                      //built from sqllex.l and sql.y

{const/var/uses already included here}

function ExecSQL(st:TStmt;{const }sql:string;connection:TIdTCPConnection;var resultRowCount:integer):integer;
{Parses and executes a set of SQL statements
 IN:
              tr          the current transaction
              st          the current statement
              sql         the statement list to be parsed
              connection  the client connection to send formatted output results to
                          -nil=none = sink
 OUT:         resultRowCount
 RESULT:      0=ok,
              -2=need parameter (should never happen here)
              -999=shutdown server //debug only!
              else syntax error (todo: but missed if followed by ok statements)

 Note: the syntax tree nodes are not deleted by this routine

 Assumes: if not tr.connected then we have not CONNECTed yet, so we implicitly connect to default
}
const
  where='uParser';
  routine=':ExecSQL';

  ErrNeedParam=-2;

  {Pre-parse to avoid connection}
  CONNECTSQL='CONNECT';
  SHUTDOWNSQL='SHUTDOWN';
  CREATECATALOGSQL='CREATE CATALOG';
  KILLSQL='KILL';
var
  n:integer;
  h,m,sec,ms:word;
  start,stop:TdateTime;

  errText:string;

  errNode:TErrorNodePtr;
  //resultRowCount:integer;

  serverName,username,password,connectionName:string;
  dummyResult:integer;
begin
  result:=fail;

  try
    st.deleteErrorList; //clear error stack

    st.InputText:=sql; //initialise (overwrites!) the stmt's input buffer ready for the parse loop below...
    repeat
      try
        {Since we can be via directSQL, we may need to implicitly connect}
        //todo protect in case no catalog is available & we're trying to create one!
        // - although offloading this whole create catalog business would save a lot of hassle/space!
        if (not Ttransaction(st.owner).connected) and (upperCase(copy(trimleftWS(st.InputText),1,length(CONNECTSQL)))<>CONNECTSQL)
                              and (upperCase(copy(trimleftWS(st.InputText),1,length(SHUTDOWNSQL)))<>SHUTDOWNSQL)
                              and (upperCase(copy(trimleftWS(st.InputText),1,length(KILLSQL)))<>KILLSQL)
                              and (upperCase(copy(trimleftWS(st.InputText),1,length(CREATECATALOGSQL)))<>CREATECATALOGSQL) then
        begin
          {$IFDEF DEBUG_LOG}
          log.add(st.who,where+routine,format('Not connected - will implicitly connect',[nil]),vDebugLow);
          {$ENDIF}
          password:='';
          serverName:=''; //todo choose current server/catalog
          {Default the connection name to the server name as per the spec.}
          connectionName:=serverName;
          {todo: if the connection name already exists - fail here with error 08002}
          userName:=DEFAULT_AUTHNAME;

          {Check the username and password are valid & continue with user command or fail}
          dummyResult:=Ttransaction(st.owner).Connect(username,password);
          case dummyResult of
            ok:begin
                //Authorised & connected
                Ttransaction(st.owner).ConnectionName:=connectionName;
               end;
            -2:begin
                st.addError(seUnknownAuth,seUnknownAuthText);
               end;
            -3:begin
                //todo be extra secure: i.e. don't let on that user-id was found!: st.addError(seUnknownAuth,seUnknownAuthText);
                st.addError(seWrongPassword,seWrongPasswordText);
               end;
            -4:begin
                st.addError(seAuthAccessError,seAuthAccessErrorText);
               end;
            -5:begin
                st.addError(seAuthLimitError,seAuthLimitErrorText);
               end;
          else
            st.addError(seFail,seFailText); //todo general error ok?
          end; {case}

          if dummyResult<>ok then
          begin
            st.addError(seNotConnected,seNotConnectedText); 
            result:=Fail;
            exit;
          end;
          //else we continue with the original command now we're connected
        end;

        {Prepare}
        result:=PrepareSQL(st,nil,''{InputText already set to allow batch});
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('  prepareSQL returns %d',[result]),vDebugMedium);
        {$ENDIF}
        {$ENDIF}
        try
          if result<>ok then
          begin
            exit; //abort batch //todo continue?
          end;

          if st.sroot<>nil then //a plan was created
          begin
            {Process the plan}
            start:=now;

            result:=ExecutePlan(st,resultRowCount);
            st.need_param:=result; //store which parameter is missing
            {$IFDEF DEBUGDETAIL}
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('  ExecutePlan returns %d',[result]),vDebugMedium);
            {$ENDIF}
            {$ENDIF}
            if result<>ok then
            begin
              if result>ok then
              begin
                result:=ErrNeedParam;
                if connection<>nil then
                  connection.WriteLn(seSyntaxText{todo improve: e.g. missing param not allowed in directSQL});
                exit; //abort batch //todo continue?
              end
              else
              begin
                exit; //abort batch //todo continue?
              end;
            end;

            {If this plan returned a cursor, loop through it and return the rows}
            if st.planActive then
            begin //executed & cursor pending
                resultRowCount:=0;
                if connection<>nil then
                begin
                  connection.WriteLn(format('%s',[(st.sroot.ptree as TIterator).iTuple.ShowHeading]));
                  connection.WriteLn(stringOfChar('=',length((st.sroot.ptree as TIterator).iTuple.ShowHeading)));
                end;

                while not st.noMore do
                begin
                  //todo remove As & use cast - speed - but is it worth it? I suppose we could check the type once after execution instead...
                  result:=(st.sroot.ptree as TIterator).next(st.noMore);
                  if result<>ok then
                  begin
                    //for now, prevent access violation below:
                    st.noMore:=True; //todo too crude? but works!
                    //todo should be more severe! return critical error to client...
                    exit; //abort batch //todo continue?: assume an error has been added to the st already... todo add another here just in case?
                  end;

                  if not st.noMore then
                  begin
                    inc(resultRowCount);
                    if connection<>nil then connection.WriteLn(format('%s',[(st.sroot.ptree as TIterator).iTuple.Show(st)]));
                  end;
                end; {while}
            end; {cursor}

            stop:=now;

            {Show rows affected/selected - ignore things like 'create table' which return -1}
            if resultRowCount<>-1 then
            begin
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,format('%d row(s) affected',[resultRowCount]),vDebugHigh);
              {$ENDIF}
              if connection<>nil then
                if resultRowCount=1 then  //todo use common plural routine if needed elsewhere
                  connection.WriteLn(format('%d row affected',[resultRowCount]))
                else
                  connection.WriteLn(format('%d rows affected',[resultRowCount]));
            end;

            //stop:=now; //moved earlier to not include extra microseconds!
            decodeTime(stop-start,h,m,sec,ms);
            if connection<>nil then
            begin
              connection.WriteLn(format('Processing time: %2.2d:%2.2d:%2.2d:%3.3d (tran-id=%d:%d)',[h,m,sec,ms,st.Rt.tranId,st.Rt.stmtId]));
              connection.WriteLn();
            end;
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Processing time: %2.2d:%2.2d:%2.2d:%3.3d (tran-id=%d:%d)',[h,m,sec,ms,st.Rt.tranId,st.Rt.stmtId]),vDebug);
            {$ENDIF}
          end;
        finally
          {Close result set}
          st.CloseCursor(1{=unprepare});
          //todo need to remove any subst that are now ownerless...
          //CLI does this on freeHandle & cursor.close self-removes:
          // but direct SQL (here) will retain until connection is closed since we use same stmt throughout (currently)
        end; {try}
      finally
        if (result<>ok) and (result<>-999) then
        begin
          {Output any errors to the console}
          errNode:=st.errorList;
          if errNode=nil then
            if connection<>nil then
              connection.WriteLn(format('Error %5.5d: %s',[seFail,seFailText{$IFDEF DEBUG_LOG}+' (debug='+inttostr(result)+')'{$ENDIF}]));
          while errNode<>nil do
          begin
            //todo output errNode.code?
            if connection<>nil then
              connection.WriteLn(format('Error %5.5d: %s',[errNode.code,errNode.text]));
            errNode:=errNode.next;
          end;
        end;
        //todo delete the error list here? e.g. st.deleteErrorList
      end; {try}

      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'remaining sql='+st.InputText,vDebugLow);
      {$ENDIF}
      {$ENDIF}
    until (trim(st.InputText)='') or (result=-999); //handle batches of statements
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,'...so quiting repeat',vDebugLow);
    {$ENDIF}
    {$ENDIF}
  except
    on E:Exception do //todo leave to outer connection manager handler?
    begin
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Process error: '+E.message,vError);
      {$ENDIF}
      if connection<>nil then
      begin
        connection.WriteLn('Process error: '+E.message);
      end;
    end;
  end; {try}
end; {ExecSQL}


function ParseSubSQL(st:TStmt;const sql:string;var sroot:TSyntaxNodePtr):integer;
{Parses a SQL sub-tree statement
 Currently only for view definition expansion, so plan preparation and integration of
 sub-syntax tree into main tree is left to caller. This routine is just a way of
 accessing the parser in a shared manner.
 //todo in future use a common parser access routine for this & prepareSQL routines
 //todo: still need this now we've moved parser globals from tr to st?

 IN:
              tr       the current transaction
              st       the current statement
              sql      the statement to be parsed
 OUT:
              sroot    the parsed syntax tree root

 RESULT:      0=ok,
              else fail = syntax error
                   //todo need to stack errors as we go as per client diagnostics

 Note: the syntax tree nodes are not deleted by this routine

 Note: portions of this routine have been taken from the PrepareSQL routine
}
const
  where='uParser';
  routine=':ParseSubSQL';
var
  n:integer;

  saveSroot,saveParseRoot:TSyntaxNodePtr;
  saveInputText:string; //ensure we preserve any existing (outer) sql associated with st
begin
  result:=fail;

//TODO need to preserve caller's inputtext & parseroot position in this sub-routine...! for view expansion
{$IFDEF DEBUG_LOG}
if st.sarg<>nil then log.add(st.who,where+routine,'Stmt sarg is already in use!: '+sql,vDebugError);
{$ENDIF}

  saveInputText:=st.InputText; //store current text
  saveSroot:=st.sroot;
  saveParseRoot:=st.ParseRoot;

  st.InputText:=sql; //initialise (overwrites!) the stmt's input buffer ready for the parse loop below...
  try
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,sql,vDebugLow);
    {$ENDIF}
    {$ENDIF}
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.status; //memory display
    {$ENDIF}
    {$ENDIF}
    //05/08/02: disaster! causes writeln = IOerror 103! yydebug:=True;
    sroot:=Ptr(1);  //set to not nil to start loop going... //todo crying out for repeat until!
  //todo do once for CLI  while (n=0) and (tr.ParseRoot<>nil) do //(bufptr>0) or (yyInputText<>'') do   //todo must be a better (quicker) test
  //todo: SQLMoreResults allows batches... standard only in procedures though... research... we can handle it if we need to...
  //do once for now!
    begin
  {$IFDEF DEBUG_LOG}
  //todo debug bufptr internals from lexLib to show next sql statement...   log.add(where+routine,'Entering parser...'+yyInputText+yyline,vDebugLow);
  {$ENDIF}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Entering parser...',vDebugLow);
      {$ENDIF}
      {$ENDIF}
      {For now, we protect the parser with a mutex
       //todo make multithreaded
      }
          CSparserMutex.Enter;
          try
            GlobalParseRoot:=nil;
            GlobalParseStmt:=st;
            param_count:=0; //initialise param counting
            {Initialise parser}
            yylineno:=1;
            yycolno:=0;
            yyOffset:=0;

            {$IFNDEF DEBUGPARSER}
            {$IFDEF DEBUG_LOG}
            log.hold;
            try
            {$ENDIF}
            {$ENDIF}
            n:=yyparse;  //parses next statement from buffer (so won't run on for ages...)
            {$IFNDEF DEBUGPARSER}
            {$IFDEF DEBUG_LOG}
            finally
              log.resume;
            end; {try}
            {$ENDIF}
            {$ENDIF}
            sroot:=GlobalParseRoot;
          finally
            CSparserMutex.Leave;
          end; {try}

      {Processing now continues in a multithreaded manner...}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Parse returns: %d with ParseRoot=%p',[n,sroot]),vDebug);
      {$ENDIF}
      {$ENDIF}
      if n<>0 then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Parse error: %d',[n]),vError);
        {$ENDIF}
  //      if csocket<>nil then csocket.SendText(format('Parse error: %d',[n]));
        result:=fail;
        st.addError(seSyntax,seSyntaxText); //todo need more info: line+column + last-token etc.

        //todo result:=-ve = fail = error
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Parse tree root: %p',[sroot]),vDebug);
        {$ENDIF}
        {$ENDIF}
        result:=ok;
      end;
    end; //todo once only for CLI {while}
    //todo catch exceptions here & return error to caller?
  finally
    st.ParseRoot:=saveParseRoot;
    st.sroot:=saveSroot;
    st.InputText:=saveInputText; //restore the stmt's input buffer ready
  end; {try}
end; {ParseSubSQL}

function PrepareSQL(st:TStmt;iter:TIterator;const sql:string):integer;
{Parses and prepares execution plan for a (set of:todo?) SQL statements
 IN:
              tr       the current transaction
              iter     the super-context needed to pass to preparePlan, nil if n/a
              sql      the statement (todo list?) to be parsed
                       Note: if blank, assumes st.InputText has been set, e.g. for a batch
 OUT:
              st       the prepared statement plan

 RESULT:      0=ok,
              else fail = syntax error (todo: but missed if followed by ok statements)
                   //todo need to stack errors as we go as per client diagnostics

 Note: the syntax tree nodes are not deleted by this routine

 Note: portions of this routine have been copied into the Parse routine
       for use in parsing view definitions at runtime

   Note: preserves any existing SQL inputText/parseRoot/sroot etc. associated with the stmt
    //todo: this might not be enough, but should be to enable createSchema to nest calls successfully...
}
const
  where='uParser';
  routine=':PrepareSQL';
var
  n:integer;
  h,m,sec,ms:word;
  start,stop:TdateTime;

  saveParseRoot:TSyntaxNodePtr;
  saveInputText:string; //ensure we preserve any existing (outer) sql associated with st
begin
  result:=fail;

{$IFDEF DEBUG_LOG}
if st.sroot<>nil then log.add(st.who,where+routine,'Stmt is already in use!: '+sql,vAssertion);
{$ENDIF}
{$IFDEF DEBUG_LOG}
if st.ParseRoot<>nil then log.add(st.who,where+routine,'Stmt ParseRoot is already in use! will be handled here: '+sql,vAssertion);
{$ENDIF}
{$IFDEF DEBUG_LOG}
if sql<>'' then //allow batches to continue, but others to be nested
  if st.inputText<>'' then log.add(st.who,where+routine,'Stmt inputText is already in use! will be handled here:'+sql,vAssertion);
{$ENDIF}

  {Store any existing SQL details, in case this is a nested call, e.g. within create schema}
  //although this debug fix might not do the trick... //todo re-vamp...
  saveParseRoot:=st.ParseRoot;
  saveInputText:=st.InputText;
  try
    if sql<>'' then //allow batches to continue
      st.InputText:=sql; //initialise (overwrites!) the stmt's input buffer ready for the parse loop below...
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(st.who,where+routine,sql,vDebugLow);
    {$ENDIF}
    {$ENDIF}
    {$IFDEF DEBUG_LOG}
    log.status; //memory display
    {$ENDIF}
    //05/08/02: disaster! causes writeln = IOerror 103! yydebug:=True;
    st.ParseRoot:=Ptr(1);  //set to not nil to start loop going... //todo crying out for repeat until!
  //todo do once for CLI  while (n=0) and (tr.ParseRoot<>nil) do //(bufptr>0) or (yyInputText<>'') do   //todo must be a better (quicker) test
  //todo: SQLMoreResults allows batches... standard only in procedures though... research... we can handle it if we need to...
  //do once for now!
    begin
  {$IFDEF DEBUG_LOG}
  //todo debug bufptr internals from lexLib to show next sql statement...   log.add(where+routine,'Entering parser...'+yyInputText+yyline,vDebugLow);
  {$ENDIF}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,'Entering parser...',vDebugLow);
      {$ENDIF}
      {$ENDIF}
      {For now, we protect the parser with a mutex
       //todo make multithreaded
      }
          CSparserMutex.Enter;
          try
            GlobalParseRoot:=nil;
            GlobalParseStmt:=st;
            param_count:=0; //initialise param counting
            {Initialise parser}
            yylineno:=1;
            yycolno:=0;
            yyOffset:=0;

            {$IFNDEF DEBUGPARSER}
            {$IFDEF DEBUG_LOG}
            log.hold;
            try
            {$ENDIF}
            {$ENDIF}
            n:=yyparse;  //parses next statement from buffer (so won't run on for ages...)
            {$IFNDEF DEBUGPARSER}
            {$IFDEF DEBUG_LOG}
            finally
              log.resume;
            end; {try}
            {$ENDIF}
            {$ENDIF}
            st.ParseRoot:=GlobalParseRoot;
            st.syntaxErrLine:=GlobalSyntaxErrLine;
            st.syntaxErrCol:=GlobalSyntaxErrCol;
            st.syntaxErrMessage:=GlobalSyntaxErrMessage;
          finally
            CSparserMutex.Leave;
          end; {try}

      {Processing now continues in a multithreaded manner...}
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(st.who,where+routine,format('Parse returns: %d with ParseRoot=%p',[n,st.ParseRoot]),vDebug);
      {$ENDIF}
      {$ENDIF}
      if n<>0 then
      begin
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Parse error: %d',[n]),vError);
        {$ENDIF}
  //      if csocket<>nil then csocket.SendText(format('Parse error: %d',[n]));
        result:=fail;
        st.addError(seSyntax,seSyntaxText+format(' at line %d column %d near %s',[st.SyntaxErrLine,st.SyntaxErrCol,st.SyntaxErrMessage])); //todo need more info: line+column + last-token etc.

        //todo result:=-ve = fail = error
      end
      else
      begin
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(st.who,where+routine,format('Parse tree root: %p',[st.ParseRoot]),vDebug);
        {$ENDIF}
        {$ENDIF}
        if st.ParseRoot<>nil then
        begin
          try
            start:=now;

            st.sroot:=st.ParseRoot; //set part of result
            result:=PreparePlan(st,iter);

            stop:=now;
            decodeTime(stop-start,h,m,sec,ms);

            //Note: if the last command was commit/rollback, because these auto-start the next tran, tr.tid will now=next tran-id
            //      todo - maybe save starting tran-id with start time?
            {$IFDEF DEBUG_LOG}
            log.add(st.who,where+routine,format('Prepare time: %2.2d:%2.2d:%2.2d:%3.3d (tran-id=%d:%d)',[h,m,sec,ms,st.Rt.tranId,st.Rt.stmtId]),vDebug);
            {$ENDIF}
          except
            on E:Exception do
              {$IFDEF DEBUG_LOG}
              log.add(st.who,where+routine,'Prepare error: '+E.message,vError);
              {$ELSE}
              ;
              {$ENDIF}
          end; {try}
        end
        else
        begin
          result:=ok; //allow empty trees, e.g. ;
          st.sroot:=nil; //zeroise to be safe
        end;
      end;
    end; //todo once only for CLI {while}
    //todo catch exceptions here & return error to caller?
  finally
    //restore the stmt's input buffer ready

    if sql<>'' then //allow batches to continue, but others to be nested
    begin
      st.InputText:=saveInputText;
      st.ParseRoot:=saveParseRoot;
    end;
  end; {try}
end; {PrepareSQL}

initialization
  CSparserMutex:=TCriticalSection.Create;

finalization
  //todo maybe
  //closeHandle(hParserMutex); //no need?
  CSparserMutex.Free;


end.

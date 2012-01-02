package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/


import java.sql.*;
import java.util.*;
import java.io.*;

import uk.co.thinksql.StatementSQL.*;
import uk.co.thinksql.DatabaseMetaDataSQL.*;
import uk.co.thinksql.Global.*;
import uk.co.thinksql.GlobalUtil.*;

/**
 * <P>A Connection represents a session with a specific
 * database. Within the context of a Connection, SQL statements are
 * executed and results are returned.
 *
 * <P>A Connection's database is able to provide information
 * describing its tables, its supported SQL grammar, its stored
 * procedures, the capabilities of this connection, etc. This
 * information is obtained with the getMetaData method.
 *
 * <P><B>Note:</B> By default the Connection automatically commits
 * changes after executing each statement. If auto commit has been
 * disabled, an explicit commit must be done or database changes will
 * not be saved.
 *
 * @see DriverManager#getConnection
 * @see Statement 
 * @see ResultSet
 * @see DatabaseMetaData
 */
public class ConnectionSQL implements java.sql.Connection {

  public MarshalBuffer marshalBuffer;
  public boolean fAutocommit=true; //todo should default to true!

  public String furl;
  protected String fHost;
  protected int fPort;
  protected String fCatalog;
  protected String fServer;
  public String fUsername;
  protected String fPassword;
  
  
  private short functionId;
  private short resultCode;
  public int resultErrCode; //used by driver if connection fails
  public String resultErrText; //used by driver if connection fails
  
  public short serverCLIversion; //store server's parameter protocol version
  private int /*SQLPOINTER*/serverTransactionKey; //store server's unique id for future encryption/validation
  
  public int state=Global.stateClosed; 
  protected boolean fReadOnly=false;
  
  //todo make private or constructor? 
  protected int openConnection(String url, String host, int port, String catalog, String server, String username, String password) throws SQLException {
    //todo: pass username/password via url...	
    	
    furl = url;

    fCatalog = catalog;
    fPort = port;
    fHost = host;
    fServer=server;
    fUsername=username;
    fPassword=password;

    // Now make the initial connection
    try {
      marshalBuffer = new MarshalBuffer(fHost, fPort);
    } 
    catch (IOException e) {
      throw new SQLException ();
    }

    // Now we need to construct and send a startup packet
    //{
      if (marshalBuffer.SendHandshake()!=Global.ok) { //send raw handshake
        throw new SQLException (Global.seHandshakeFailedText,Global.ss08001,Global.seHandshakeFailed);     
      }
      //Now the server knows we're using CLI protocol we can use the marshal buffer
      marshalBuffer.putSQLUSMALLINT(Global.clientCLIversion); //special version marker for initial protocol handshake
      if (Global.clientCLIversion>=93) { //todo no need to check here!
        marshalBuffer.putSQLUSMALLINT(Global.CLI_JDBC); 
      }
      if (marshalBuffer.Send()!=Global.ok) {
        throw new SQLException (Global.seHandshakeFailedText,Global.ss08001,Global.seHandshakeFailed);     
      }      

      //Wait for handshake response
      if (marshalBuffer.Read()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      /*Note: because we know these marshalled parameters all fit in a buffer together,
        and because the buffer has been read in total by the Read above because its size was known,
        we can omit the error result checking in the following get() calls = speed
      */
      functionId=marshalBuffer.getFunction();
      if (functionId!=Global.SQL_API_handshake) {
        GlobalUtil.logError("Failed functionId="+functionId);
        throw new SQLException (Global.seHandshakeFailedText,Global.ss08001,Global.seHandshakeFailed);     
      }
      serverCLIversion=marshalBuffer.getSQLUSMALLINT(); //note server's protocol  
      if (serverCLIversion>=93) {
        serverTransactionKey=marshalBuffer.getSQLPOINTER(); //note server's transaction key
      }

      GlobalUtil.logError("Connected: serverCLIversion="+serverCLIversion);
  
      
      /*Now SQLconnect*/
      //todo when marshalling user+password -> encrypt the password!!!!
      marshalBuffer.ClearToSend();
      /*Note: because we know these marshalled parameters all fit in a buffer together,
        and because the buffer is now empty after the clearToSend,
        we can omit the error result checking in the following put() calls = speed
      */
      marshalBuffer.putFunction(Global.SQL_API_SQLCONNECT);
      marshalBuffer.putSQLHDBC(0/*(int)(this)*/);
      if (fCatalog.equals("")) 
        marshalBuffer.putpUCHAR_SWORD(fServer);
      else 
        marshalBuffer.putpUCHAR_SWORD(fServer+"."+fCatalog);
      marshalBuffer.putpUCHAR_SWORD(fUsername);
      marshalBuffer.putpUCHAR_SWORD(fPassword);
      if (marshalBuffer.Send()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }

      /*Wait for read to return the response*/
      if (marshalBuffer.Read()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      /*Note: because we know these marshalled parameters all fit in a buffer together,
        and because the buffer has been read in total by the Read above because its size was known,
        we can omit the error result checking in the following get() calls = speed
      */
      functionId=marshalBuffer.getFunction();
      if (functionId!=Global.SQL_API_SQLCONNECT) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      resultCode=marshalBuffer.getRETCODE();
      
      GlobalUtil.logError("connect returns="+resultCode);
      
      //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
      /*if error, then get error details: local-number, default-text*/
      int errCount=marshalBuffer.getSQLINTEGER(); //error count
      if (resultCode==Global.SQL_ERROR) {
        for (int err=1;err<=errCount;err++) {
          resultErrCode=marshalBuffer.getSQLINTEGER();
          resultErrText=marshalBuffer.getpUCHAR_SWORD();
          GlobalUtil.logError("server error="+resultErrText);
        }
        return Global.fail; //abort
      }
      
      /*Ok, we're connected*/
      state=Global.stateOpen;
  
      return Global.ok;
	  //}
  }

    /**
     * SQL statements without parameters are normally
     * executed using Statement objects. If the same SQL statement 
     * is executed many times, it is more efficient to use a 
     * PreparedStatement
     *
     * @return a new Statement object 
     */
    public Statement createStatement() throws SQLException {
      StatementSQL stmt = new StatementSQL(this); 
      return stmt;
    }
    public Statement createStatement(int resultSetType, int resultSetConcurrency) throws SQLException {
      Statement stmt = createStatement(); 
      //todo: set stmt resultSetType & resultSetConcurrency
      return stmt;
    }

    /**
     * A SQL statement with or without IN parameters can be
     * pre-compiled and stored in a PreparedStatement object. This
     * object can then be used to efficiently execute this statement
     * multiple times.
     *
     * <P><B>Note:</B> This method is optimized for handling
     * parametric SQL statements that benefit from precompilation. If
     * the driver supports precompilation, prepareStatement will send
     * the statement to the database for precompilation. Some drivers
     * may not support precompilation. In this case, the statement may
     * not be sent to the database until the PreparedStatement is
     * executed.  This has no direct affect on users; however, it does
     * affect which method throws certain SQLExceptions.
     *
     * @param sql a SQL statement that may contain one or more '?' IN
     * parameter placeholders
     *
     * @return a new PreparedStatement object containing the
     * pre-compiled statement 
     */
    public PreparedStatement prepareStatement(String sql) throws SQLException {
      PreparedStatementSQL pstmt = new PreparedStatementSQL(this,sql); 
      return pstmt;
    }
    public PreparedStatement prepareStatement(String sql, int a, int b) throws SQLException {
      PreparedStatement pstmt = prepareStatement(sql); 
      //todo: set pstmt resultSetType & resultSetConcurrency
      return pstmt;
    }

    /**
     * A SQL stored procedure call statement is handled by creating a
     * CallableStatement for it. The CallableStatement provides
     * methods for setting up its IN and OUT parameters, and
     * methods for executing it.
     *
     * <P><B>Note:</B> This method is optimized for handling stored
     * procedure call statements. Some drivers may send the call
     * statement to the database when the prepareCall is done; others
     * may wait until the CallableStatement is executed. This has no
     * direct affect on users; however, it does affect which method
     * throws certain SQLExceptions.
     *
     * @param sql a SQL statement that may contain one or more '?'
     * parameter placeholders. Typically this  statement is a JDBC
     * function call escape string.
     *
     * @return a new CallableStatement object containing the
     * pre-compiled SQL statement 
     */
    public CallableStatement prepareCall(String sql) throws SQLException {
      return null;
    }
    public CallableStatement prepareCall(String sql, int a, int b) throws SQLException {
      return null;
    }
						
    /**
     * A driver may convert the JDBC sql grammar into its system's
     * native SQL grammar prior to sending it; nativeSQL returns the
     * native form of the statement that the driver would have sent.
     *
     * @param sql a SQL statement that may contain one or more '?'
     * parameter placeholders
     *
     * @return the native form of this statement
     */
    public String nativeSQL(String sql) throws SQLException {
      return sql;
    }

    /**
     * If a connection is in auto-commit mode, then all its SQL
     * statements will be executed and committed as individual
     * transactions.  Otherwise, its SQL statements are grouped into
     * transactions that are terminated by either commit() or
     * rollback().  By default, new connections are in auto-commit
     * mode.
     *
     * The commit occurs when the statement completes or the next
     * execute occurs, whichever comes first. In the case of
     * statements returning a ResultSet, the statement completes when
     * the last row of the ResultSet has been retrieved or the
     * ResultSet has been closed. In advanced cases, a single
     * statement may return multiple results as well as output
     * parameter values. Here the commit occurs when all results and
     * output param values have been retrieved.
     *
     * @param autoCommit true enables auto-commit; false disables
     * auto-commit.  
     */
    public void setAutoCommit(boolean autoCommit) throws SQLException {
      fAutocommit=autoCommit;
    }

    /**
     * Get the current auto-commit state.
     * @return Current state of auto-commit mode.
     * @see #setAutoCommit 
     */
    public boolean getAutoCommit() throws SQLException {
      return fAutocommit;
    }

    /**
     * Commit makes all changes made since the previous
     * commit/rollback permanent and releases any database locks
     * currently held by the Connection. This method should only be
     * used when auto commit has been disabled.
     *
     * @see #setAutoCommit 
     */
    public void commit() throws SQLException {
      //todo: we must close any open command/cursors first! leave to user...
  
      /*Send SQLendTran to server*/
      marshalBuffer.ClearToSend();
      /*Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      */
      marshalBuffer.putFunction(Global.SQL_API_SQLENDTRAN);
      marshalBuffer.putSQLHDBC(0/*SQLHDBC(this)*/);  //todo pass TranId?
      marshalBuffer.putSQLSMALLINT(Global.SQL_COMMIT);
      if (marshalBuffer.Send()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
  
      /*Wait for read to return the response*/
      if (marshalBuffer.Read()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      /*Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      */
      functionId=marshalBuffer.getFunction();
      if (functionId!=Global.SQL_API_SQLENDTRAN) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      resultCode=marshalBuffer.getRETCODE();
      
      GlobalUtil.logError("SQLEndTran returns="+resultCode);
      
      //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
      /*if error, then get error details: local-number, default-text*/
      int errCount=marshalBuffer.getSQLINTEGER(); //error count
      if (resultCode==Global.SQL_ERROR) {
        for (int err=1;err<=errCount;err++) {
          resultErrCode=marshalBuffer.getSQLINTEGER();
          resultErrText=marshalBuffer.getpUCHAR_SWORD();
          GlobalUtil.logError("server error="+resultErrText);
        }
        //todo remove: never will happen: exit;
      }
       
      //return Global.SQL_SUCCESS;
    }

    /**
     * Rollback drops all changes made since the previous
     * commit/rollback and releases any database locks currently held
     * by the Connection. This method should only be used when auto
     * commit has been disabled.
     *
     * @see #setAutoCommit 
     */
    public void rollback() throws SQLException {
      //todo: we must close any open command/cursors first! leave to user...
  
      /*Send SQLendTran to server*/
      marshalBuffer.ClearToSend();
      /*Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer is now empty after the clearToSend,
       we can omit the error result checking in the following put() calls = speed
      */
      marshalBuffer.putFunction(Global.SQL_API_SQLENDTRAN);
      marshalBuffer.putSQLHDBC(0/*SQLHDBC(this)*/);  //todo pass TranId?
      marshalBuffer.putSQLSMALLINT(Global.SQL_ROLLBACK);
      if (marshalBuffer.Send()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
  
      /*Wait for read to return the response*/
      if (marshalBuffer.Read()!=Global.ok) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      /*Note: because we know these marshalled parameters all fit in a buffer together,
       and because the buffer has been read in total by the Read above because its size was known,
       we can omit the error result checking in the following get() calls = speed
      */
      functionId=marshalBuffer.getFunction();
      if (functionId!=Global.SQL_API_SQLENDTRAN) {
        throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
      }
      resultCode=marshalBuffer.getRETCODE();
      
      GlobalUtil.logError("SQLEndTran returns="+resultCode);
      
      //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
      /*if error, then get error details: local-number, default-text*/
      int errCount=marshalBuffer.getSQLINTEGER(); //error count
      if (resultCode==Global.SQL_ERROR) {
        for (int err=1;err<=errCount;err++) {
          resultErrCode=marshalBuffer.getSQLINTEGER();
          resultErrText=marshalBuffer.getpUCHAR_SWORD();
          GlobalUtil.logError("server error="+resultErrText);
        }
        //todo remove: never will happen: exit;
      }
       
      //return Global.SQL_SUCCESS;
    }

    /**
     * In some cases, it is desirable to immediately release a
     * Connection's database and JDBC resources instead of waiting for
     * them to be automatically released; the close method provides this
     * immediate release. 
     *
     * <P><B>Note:</B> A Connection is automatically closed when it is
     * garbage collected. Certain fatal errors also result in a closed
     * Connection.
     */
    public void close() throws SQLException {
      if (disconnect()==Global.SQL_SUCCESS) {
        state=Global.stateClosed;
      }
    }
     
     
    //todo make private? 
    protected int disconnect() throws SQLException {
      //Negotiate disconnection
      
      try {
      //todo: check that from here on, we never return ERROR!
        marshalBuffer.ClearToSend();
        /*Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer is now empty after the clearToSend,
         we can omit the error result checking in the following put() calls = speed
        */
        marshalBuffer.putFunction(Global.SQL_API_SQLDISCONNECT);
        marshalBuffer.putSQLHDBC(0/*(int)(this)*/);
        if (marshalBuffer.Send()!=Global.ok) {
          throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
        }
    
        /* Wait for read to return the response */
        if (marshalBuffer.Read()!=Global.ok) {
          throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
        }
        /*Note: because we know these marshalled parameters all fit in a buffer together,
         and because the buffer has been read in total by the Read above because its size was known,
         we can omit the error result checking in the following get() calls = speed
        */
        functionId=marshalBuffer.getFunction();
        if (functionId!=Global.SQL_API_SQLDISCONNECT) {
          throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
        }
        resultCode=marshalBuffer.getRETCODE();
        //todo any point?: result:=resultCode;
        GlobalUtil.logError("disconnect returns="+resultCode);
        
        //todo check resultCode=SQL_SUCCESS - any point? can the server refuse?
        /*if error, then get error details: local-number, default-text*/
        int errCount=marshalBuffer.getSQLINTEGER(); //error count
        if (resultCode==Global.SQL_ERROR) {
          for (int err=1;err<=errCount;err++) {
            resultErrCode=marshalBuffer.getSQLINTEGER();
            resultErrText=marshalBuffer.getpUCHAR_SWORD();
            GlobalUtil.logError("server error="+resultErrText);           
          }
          //todo remove: never will happen: exit;
        }
      //end; {with}
    
      /*Try to disconnect from the server*/
      //try {
        marshalBuffer.close(); //close this connection
      //}
      //catch (IOException e) {
      //  return Global.SQL_SUCCESS_WITH_INFO;
      //}      
        return Global.SQL_SUCCESS;
      }
      catch (Exception e) {
        return Global.SQL_SUCCESS_WITH_INFO;
        //todo interpret E.message?
        //todo GlobalUtil.logError(E.message); //todo remove: just warn & assume?
      }         
    }

    /**
     * Tests to see if a Connection is closed.
     *
     * @return true if the connection is closed; false if it's still open
     */
    public boolean isClosed() throws SQLException {
      return (state==Global.stateClosed);
    }

    //======================================================================
    // Advanced features:

    /**
     * A Connection's database is able to provide information
     * describing its tables, its supported SQL grammar, its stored
     * procedures, the capabilities of this connection, etc. This
     * information is made available through a DatabaseMetaData
     * object.
     *
     * @return a DatabaseMetaData object for this Connection 
     */
    public DatabaseMetaData getMetaData() throws SQLException {
      return new DatabaseMetaDataSQL(this);
    }


    public Map getTypeMap() throws SQLException {
      return null;
    }

    public void setTypeMap(Map a) throws SQLException {
      
    }


    /**
     * You can put a connection in read-only mode as a hint to enable 
     * database optimizations.
     *
     * <P><B>Note:</B> setReadOnly cannot be called while in the
     * middle of a transaction.
     *
     * @param readOnly true enables read-only mode; false disables
     * read-only mode.  
     */
    public void setReadOnly(boolean readOnly) throws SQLException {
      fReadOnly=readOnly;
    }

    /**
     * Tests to see if the connection is in read-only mode.
     *
     * @return true if connection is read-only
     */
    public boolean isReadOnly() throws SQLException {
      return fReadOnly;
    }

    /**
     * A sub-space of this Connection's database may be selected by setting a
     * catalog name. If the driver does not support catalogs it will
     * silently ignore this request.
     */
    public void setCatalog(String catalog) throws SQLException {
      fCatalog=catalog;
    }

    /**
     * Return the Connection's current catalog name.
     *
     * @return the current catalog name or null
     */
    public String getCatalog() throws SQLException {
      return fCatalog;
    }

    /**
     * Transactions are not supported. 
     */
    int TRANSACTION_NONE	     = 0;

    /**
     * Dirty reads, non-repeatable reads and phantom reads can occur.
     */
    int TRANSACTION_READ_UNCOMMITTED = 1;

    /**
     * Dirty reads are prevented; non-repeatable reads and phantom
     * reads can occur.
     */
    int TRANSACTION_READ_COMMITTED   = 2;

    /**
     * Dirty reads and non-repeatable reads are prevented; phantom
     * reads can occur.     
     */
    int TRANSACTION_REPEATABLE_READ  = 4;

    /**
     * Dirty reads, non-repeatable reads and phantom reads are prevented.
     */
    int TRANSACTION_SERIALIZABLE     = 8;

    /**
     * You can call this method to try to change the transaction
     * isolation level using one of the TRANSACTION_* values.
     *
     * <P><B>Note:</B> setTransactionIsolation cannot be called while
     * in the middle of a transaction.
     *
     * @param level one of the TRANSACTION_* isolation values with the
     * exception of TRANSACTION_NONE; some databases may not support
     * other values
     *
     * @see DatabaseMetaData#supportsTransactionIsolationLevel 
     */
    public void setTransactionIsolation(int level) throws SQLException {
    }

    /**
     * Get this Connection's current transaction isolation mode.
     *
     * @return the current TRANSACTION_* mode value
     */
    public int getTransactionIsolation() throws SQLException {
      return TRANSACTION_SERIALIZABLE;
    }

    /**
     * The first warning reported by calls on this Connection is
     * returned.  
     *
     * <P><B>Note:</B> Subsequent warnings will be chained to this
     * SQLWarning.
     *
     * @return the first SQLWarning or null 
     */
    public SQLWarning getWarnings() throws SQLException {
      return null;
    }

    /**
     * After this call, getWarnings returns null until a new warning is
     * reported for this Connection.  
     */
    public void clearWarnings() throws SQLException {
    }


    /**
     * Overides finalize()
     */
    public void finalize() throws Throwable
    {
  	  close();
    }

};


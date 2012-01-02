package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import uk.co.thinksql.Global.*;
import uk.co.thinksql.ConnectionSQL.*;

import java.sql.*;

/**
 * This class provides information about the database as a whole.
 *
 * <P>Many of the methods here return lists of information in ResultSets.
 * You can use the normal ResultSet methods such as getString and getInt 
 * to retrieve the data from these ResultSets.  If a given form of
 * metadata is not available, these methods should throw a SQLException.
 *
 * <P>Some of these methods take arguments that are String patterns.  These
 * arguments all have names such as fooPattern.  Within a pattern String, "%"
 * means match any substring of 0 or more characters, and "_" means match
 * any one character. Only metadata entries matching the search pattern 
 * are returned. If a search pattern argument is set to a null ref, it means 
 * that argument's criteria should be dropped from the search.
 * 
 * <P>A SQLException will be thrown if a driver does not support a meta
 * data method.  In the case of methods that return a ResultSet,
 * either a ResultSet (which may be empty) is returned or a
 * SQLException is thrown.
 */
public class DatabaseMetaDataSQL implements java.sql.DatabaseMetaData {

  public ConnectionSQL fCon;
  
  //todo create these when needed inside the methods... better scoping
  private short functionId;
  private short resultCode;
  private int resultErrCode;
  private String resultErrText;

  //todo ok?
  public DatabaseMetaDataSQL(ConnectionSQL con) throws SQLException {
    fCon=con;     
  }
  
  //----------------------------------------------------------------------
  // First, a variety of minor information about the target database.

    /**
     * Can all the procedures returned by getProcedures be called by the
     * current user?
     *
     * @return true if so
     */
  public boolean allProceduresAreCallable() throws SQLException {
    return true;
  }

    /**
     * Can all the tables returned by getTable be SELECTed by the
     * current user?
     *
     * @return true if so 
     */
  public boolean allTablesAreSelectable() throws SQLException {
    return true;
  }

    /**
     * What's the url for this database?
     *
     * @return the url or null if it can"t be generated
     */
  public String getURL() throws SQLException {
    return fCon.furl;
  }

    /**
     * What's our user name as known to the database?
     *
     * @return our database user name
     */
  public String getUserName() throws SQLException {
    return fCon.fUsername;
  }

    /**
     * Is the database in read-only mode?
     *
     * @return true if so
     */
  public boolean isReadOnly() throws SQLException {
    return false;
  }

    /**
     * Are NULL values sorted high?
     *
     * @return true if so
     */
  public boolean nullsAreSortedHigh() throws SQLException {
    return false;
  }

    /**
     * Are NULL values sorted low?
     *
     * @return true if so
     */
  public boolean nullsAreSortedLow() throws SQLException {
    return false;
  }

    /**
     * Are NULL values sorted at the start regardless of sort order?
     *
     * @return true if so 
     */
  public boolean nullsAreSortedAtStart() throws SQLException {
    return true;
  }

    /**
     * Are NULL values sorted at the end regardless of sort order?
     *
     * @return true if so
     */
  public boolean nullsAreSortedAtEnd() throws SQLException {
    return false;
  }

    /**
     * What's the name of this database product?
     *
     * @return database product name
     */
  public String getDatabaseProductName() throws SQLException {
    return askServer(Global.SQL_DBMS_NAME);
  }

    /**
     * What's the version of this database product?
     *
     * @return database version
     */
  public String getDatabaseProductVersion() throws SQLException {
    return askServer(Global.SQL_DBMS_VERSION);
  }

    /**
     * What's the name of this JDBC driver?
     *
     * @return JDBC driver name
     */
  public String getDriverName() throws SQLException {
    return Global.DriverName;
  }

    /**
     * What's the version of this JDBC driver?
     *
     * @return JDBC driver version
     */
  public String getDriverVersion() throws SQLException {
    return Global.DriverVersion;
  }

    /**
     * What's this JDBC driver's major version number?
     *
     * @return JDBC driver major version
     */
  public int getDriverMajorVersion() {
    return Global.DriverMajorVersion;
  }

    /**
     * What's this JDBC driver's minor version number?
     *
     * @return JDBC driver minor version number
     */
  public int getDriverMinorVersion() {
    return Global.DriverMinorVersion;
  }

    /**
     * Does the database store tables in a local file?
     *
     * @return true if so
     */
  public boolean usesLocalFiles() throws SQLException {
    return false;
  }

    /**
     * Does the database use a file for each table?
     *
     * @return true if the database uses a local file for each table
     */
  public boolean usesLocalFilePerTable() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case unquoted SQL identifiers as
     * case sensitive and as a result store them in mixed case?
     *
     * A JDBC-Compliant driver will always return false.
     *
     * @return true if so 
     */
  public boolean supportsMixedCaseIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case unquoted SQL identifiers as
     * case insensitive and store them in upper case?
     *
     * @return true if so 
     */
  public boolean storesUpperCaseIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case unquoted SQL identifiers as
     * case insensitive and store them in lower case?
     *
     * @return true if so 
     */
  public boolean storesLowerCaseIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case unquoted SQL identifiers as
     * case insensitive and store them in mixed case?
     *
     * @return true if so 
     */
  public boolean storesMixedCaseIdentifiers() throws SQLException {
    return true;
  }

    /**
     * Does the database treat mixed case quoted SQL identifiers as
     * case sensitive and as a result store them in mixed case?
     *
     * A JDBC-Compliant driver will always return false.
     *
     * @return true if so
     */
  public boolean supportsMixedCaseQuotedIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case quoted SQL identifiers as
     * case insensitive and store them in upper case?
     *
     * @return true if so 
     */
  public boolean storesUpperCaseQuotedIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case quoted SQL identifiers as
     * case insensitive and store them in lower case?
     *
     * @return true if so 
     */
  public boolean storesLowerCaseQuotedIdentifiers() throws SQLException {
    return false;
  }

    /**
     * Does the database treat mixed case quoted SQL identifiers as
     * case insensitive and store them in mixed case?
     *
     * @return true if so 
     */
  public boolean storesMixedCaseQuotedIdentifiers() throws SQLException {
    return true;
  }

    /**
     * What's the string used to quote SQL identifiers?
     * This returns a space " " if identifier quoting isn't supported.
     *
     * A JDBC-Compliant driver always uses a double quote character.
     *
     * @return the quoting string
     */
  public String getIdentifierQuoteString() throws SQLException {
    return "\"";
  }

    /**
     * Get a comma separated list of all a database's SQL keywords
     * that are NOT also SQL92 keywords.
     *
     * @return the list 
     */
  public String getSQLKeywords() throws SQLException {
    return "";
  }

    /**
     * Get a comma separated list of math functions.
     *
     * @return the list
     */
  public String getNumericFunctions() throws SQLException {
    return "";
  }

    /**
     * Get a comma separated list of string functions.
     *
     * @return the list
     */
  public String getStringFunctions() throws SQLException {
    return "";
  }

    /**
     * Get a comma separated list of system functions.
     *
     * @return the list
     */
  public String getSystemFunctions() throws SQLException {
    return "";
  }

    /**
     * Get a comma separated list of time and date functions.
     *
     * @return the list
     */
  public String getTimeDateFunctions() throws SQLException {
    return "";
  }

    /**
     * This is the string that can be used to escape "_" or "%" in
     * the string pattern style catalog search parameters.
     *
     * <P>The "_" character represents any single character.
     * <P>The "%" character represents any sequence of zero or 
     * more characters.
     * @return the string used to escape wildcard characters
     */
  public String getSearchStringEscape() throws SQLException {
    return Global.EscapeChar;
  }

    /**
     * Get all the "extra" characters that can be used in unquoted
     * identifier names (those beyond a-z, A-Z, 0-9 and _).
     *
     * @return the string containing the extra characters 
     */
  public String getExtraNameCharacters() throws SQLException {
    return "";
  }

    //--------------------------------------------------------------------
    // Functions describing which features are supported.

    /**
     * Is "ALTER TABLE" with add column supported?
     *
     * @return true if so
     */
  public boolean supportsAlterTableWithAddColumn() throws SQLException {
    return false;
  }

    /**
     * Is "ALTER TABLE" with drop column supported?
     *
     * @return true if so
     */
  public boolean supportsAlterTableWithDropColumn() throws SQLException {
    return false;
  }

    /**
     * Is column aliasing supported? 
     *
     * <P>If so, the SQL AS clause can be used to provide names for
     * computed columns or to provide alias names for columns as
     * required.
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so 
     */
  public boolean supportsColumnAliasing() throws SQLException {
    return true;
  }

    /**
     * Are concatenations between NULL and non-NULL values NULL?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean nullPlusNonNullIsNull() throws SQLException {
    return true;
  }

    /**
     * Is the CONVERT function between SQL types supported?
     *
     * @return true if so
     */
  public boolean supportsConvert() throws SQLException {
    return false;
  }

    /**
     * Is CONVERT between the given SQL types supported?
     *
     * @param fromType the type to convert from
     * @param toType the type to convert to     
     * @return true if so
     * @see Types
     */
  public boolean supportsConvert(int fromType, int toType) throws SQLException {
    return false;
  }

    /**
     * Are table correlation names supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsTableCorrelationNames() throws SQLException {
    return true;
  }

    /**
     * If table correlation names are supported, are they restricted
     * to be different from the names of the tables?
     *
     * @return true if so 
     */
  public boolean supportsDifferentTableCorrelationNames() throws SQLException {
    return false;
  }

    /**
     * Are expressions in "ORDER BY" lists supported?
     *
     * @return true if so
     */
  public boolean supportsExpressionsInOrderBy() throws SQLException {
    return false;
  }

    /**
     * Can an "ORDER BY" clause use columns not in the SELECT?
     *
     * @return true if so
     */
  public boolean supportsOrderByUnrelated() throws SQLException {
    return false;
  }

    /**
     * Is some form of "GROUP BY" clause supported?
     *
     * @return true if so
     */
  public boolean supportsGroupBy() throws SQLException {
    return true;
  }

    /**
     * Can a "GROUP BY" clause use columns not in the SELECT?
     *
     * @return true if so
     */
  public boolean supportsGroupByUnrelated() throws SQLException {
    return false;
  }

    /**
     * Can a "GROUP BY" clause add columns not in the SELECT
     * provided it specifies all the columns in the SELECT?
     *
     * @return true if so
     */
  public boolean supportsGroupByBeyondSelect() throws SQLException {
    return false;
  }

    /**
     * Is the escape character in "LIKE" clauses supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsLikeEscapeClause() throws SQLException {
    return true;
  }

    /**
     * Are multiple ResultSets from a single execute supported?
     *
     * @return true if so
     */
  public boolean supportsMultipleResultSets() throws SQLException {
    return false;
  }

    /**
     * Can we have multiple transactions open at once (on different
     * connections)?
     *
     * @return true if so
     */
  public boolean supportsMultipleTransactions() throws SQLException {
    return true;
  }

    /**
     * Can columns be defined as non-nullable?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsNonNullableColumns() throws SQLException {
    return true;
  }

    /**
     * Is the ODBC Minimum SQL grammar supported?
     *
     * All JDBC-Compliant drivers must return true.
     *
     * @return true if so
     */
  public boolean supportsMinimumSQLGrammar() throws SQLException {
    return true;
  }

    /**
     * Is the ODBC Core SQL grammar supported?
     *
     * @return true if so
     */
  public boolean supportsCoreSQLGrammar() throws SQLException {
    return true;
  }

    /**
     * Is the ODBC Extended SQL grammar supported?
     *
     * @return true if so
     */
  public boolean supportsExtendedSQLGrammar() throws SQLException {
    return true;
  }

    /**
     * Is the ANSI92 entry level SQL grammar supported?
     *
     * All JDBC-Compliant drivers must return true.
     *
     * @return true if so
     */
  public boolean supportsANSI92EntryLevelSQL() throws SQLException {
    return true;
  }

    /**
     * Is the ANSI92 intermediate SQL grammar supported?
     *
     * @return true if so
     */
  public boolean supportsANSI92IntermediateSQL() throws SQLException {
    return true;
  }

    /**
     * Is the ANSI92 full SQL grammar supported?
     *
     * @return true if so
     */
  public boolean supportsANSI92FullSQL() throws SQLException {
    return true;
  }

    /**
     * Is the SQL Integrity Enhancement Facility supported?
     *
     * @return true if so
     */
  public boolean supportsIntegrityEnhancementFacility() throws SQLException {
    return true;
  }

    /**
     * Is some form of outer join supported?
     *
     * @return true if so
     */
  public boolean supportsOuterJoins() throws SQLException {
    return true;
  }

    /**
     * Are full nested outer joins supported?
     *
     * @return true if so
     */
  public boolean supportsFullOuterJoins() throws SQLException {
    return true;
  }

    /**
     * Is there limited support for outer joins?  (This will be true
     * if supportFullOuterJoins is true.)
     *
     * @return true if so
     */
  public boolean supportsLimitedOuterJoins() throws SQLException {
    return false;
  }

    /**
     * What's the database vendor's preferred term for 'schema"?
     *
     * @return the vendor term
     */
  public String getSchemaTerm() throws SQLException {
    return "schema";
  }

    /**
     * What's the database vendor's preferred term for "procedure"?
     *
     * @return the vendor term
     */
  public String getProcedureTerm() throws SQLException {
    return "procedure";
  }

    /**
     * What's the database vendor's preferred term for "catalog"?
     *
     * @return the vendor term
     */
  public String getCatalogTerm() throws SQLException {
    return "catalog";
  }

    /**
     * Does a catalog appear at the start of a qualified table name?
     * (Otherwise it appears at the end)
     *
     * @return true if it appears at the start 
     */
  public boolean isCatalogAtStart() throws SQLException {
    return true;
  }

    /**
     * What's the separator between catalog and table name?
     *
     * @return the separator string
     */
  public String getCatalogSeparator() throws SQLException {
    return ".";
  }

    /**
     * Can a schema name be used in a data manipulation statement?
     *
     * @return true if so
     */
  public boolean supportsSchemasInDataManipulation() throws SQLException {
    return true;
  }

    /**
     * Can a schema name be used in a procedure call statement?
     *
     * @return true if so
     */
  public boolean supportsSchemasInProcedureCalls() throws SQLException {
    return true;
  }

    /**
     * Can a schema name be used in a table definition statement?
     *
     * @return true if so
     */
  public boolean supportsSchemasInTableDefinitions() throws SQLException {
    return true;
  }

    /**
     * Can a schema name be used in an index definition statement?
     *
     * @return true if so
     */
  public boolean supportsSchemasInIndexDefinitions() throws SQLException {
    return false;
  }

    /**
     * Can a schema name be used in a privilege definition statement?
     *
     * @return true if so
     */
  public boolean supportsSchemasInPrivilegeDefinitions() throws SQLException {
    return true;
  }

    /**
     * Can a catalog name be used in a data manipulation statement?
     *
     * @return true if so
     */
  public boolean supportsCatalogsInDataManipulation() throws SQLException {
    return true;
  }

    /**
     * Can a catalog name be used in a procedure call statement?
     *
     * @return true if so
     */
  public boolean supportsCatalogsInProcedureCalls() throws SQLException {
    return true;
  }

    /**
     * Can a catalog name be used in a table definition statement?
     *
     * @return true if so
     */
  public boolean supportsCatalogsInTableDefinitions() throws SQLException {
    return true;
  }

    /**
     * Can a catalog name be used in an index definition statement?
     *
     * @return true if so
     */
  public boolean supportsCatalogsInIndexDefinitions() throws SQLException {
    return false;
  }

    /**
     * Can a catalog name be used in a privilege definition statement?
     *
     * @return true if so
     */
  public boolean supportsCatalogsInPrivilegeDefinitions() throws SQLException {
    return true;
  }


    /**
     * Is positioned DELETE supported?
     *
     * @return true if so
     */
  public boolean supportsPositionedDelete() throws SQLException {
    return false;
  }

    /**
     * Is positioned UPDATE supported?
     *
     * @return true if so
     */
  public boolean supportsPositionedUpdate() throws SQLException {
    return false;
  }

    /**
     * Is SELECT for UPDATE supported?
     *
     * @return true if so
     */
  public boolean supportsSelectForUpdate() throws SQLException {
    return false;
  }

    /**
     * Are stored procedure calls using the stored procedure escape
     * syntax supported?
     *
     * @return true if so 
     */
  public boolean supportsStoredProcedures() throws SQLException {
    return true;
  }

    /**
     * Are subqueries in comparison expressions supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsSubqueriesInComparisons() throws SQLException {
    return true;
  }

    /**
     * Are subqueries in "exists" expressions supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsSubqueriesInExists() throws SQLException {
    return true;
  }

    /**
     * Are subqueries in "in" statements supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsSubqueriesInIns() throws SQLException {
    return true;
  }

    /**
     * Are subqueries in quantified expressions supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsSubqueriesInQuantifieds() throws SQLException {
    return true;
  }

    /**
     * Are correlated subqueries supported?
     *
     * A JDBC-Compliant driver always returns true.
     *
     * @return true if so
     */
  public boolean supportsCorrelatedSubqueries() throws SQLException {
    return true;
  }

    /**
     * Is SQL UNION supported?
     *
     * @return true if so
     */
  public boolean supportsUnion() throws SQLException {
    return true;
  }

    /**
     * Is SQL UNION ALL supported?
     *
     * @return true if so
     */
  public boolean supportsUnionAll() throws SQLException {
    return true;
  }

    /**
     * Can cursors remain open across commits? 
     * 
     * @return true if cursors always remain open; false if they might not remain open
     */
  public boolean supportsOpenCursorsAcrossCommit() throws SQLException {
    return true;
  }

    /**
     * Can cursors remain open across rollbacks?
     * 
     * @return true if cursors always remain open; false if they might not remain open
     */
  public boolean supportsOpenCursorsAcrossRollback() throws SQLException {
    return true;
  }

    /**
     * Can statements remain open across commits?
     * 
     * @return true if statements always remain open; false if they might not remain open
     */
  public boolean supportsOpenStatementsAcrossCommit() throws SQLException {
    return false;
  }

    /**
     * Can statements remain open across rollbacks?
     * 
     * @return true if statements always remain open; false if they might not remain open
     */
  public boolean supportsOpenStatementsAcrossRollback() throws SQLException {
    return false;
  }

  

    //----------------------------------------------------------------------
    // The following group of methods exposes various limitations 
    // based on the target database with the current driver.
    // Unless otherwise specified, a result of zero means there is no
    // limit, or the limit is not known.
  
    /**
     * How many hex characters can you have in an inline binary literal?
     *
     * @return max literal length
     */
  public int getMaxBinaryLiteralLength() throws SQLException {
    return 0;
  }

    /**
     * What's the max length for a character literal?
     *
     * @return max literal length
     */
  public int getMaxCharLiteralLength() throws SQLException {
    return 0;
  }

    /**
     * What's the limit on column name length?
     *
     * @return max literal length
     */
  public int getMaxColumnNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of columns in a "GROUP BY" clause?
     *
     * @return max number of columns
     */
  public int getMaxColumnsInGroupBy() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of columns allowed in an index?
     *
     * @return max columns
     */
  public int getMaxColumnsInIndex() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of columns in an "ORDER BY" clause?
     *
     * @return max columns
     */
  public int getMaxColumnsInOrderBy() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of columns in a 'sELECT" list?
     *
     * @return max columns
     */
  public int getMaxColumnsInSelect() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of columns in a table?
     *
     * @return max columns
     */
  public int getMaxColumnsInTable() throws SQLException {
    return 0;
  }

    /**
     * How many active connections can we have at a time to this database?
     *
     * @return max connections
     */
  public int getMaxConnections() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum cursor name length?
     *
     * @return max cursor name length in bytes
     */
  public int getMaxCursorNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of an index (in bytes)?  
     *
     * @return max index length in bytes
     */
  public int getMaxIndexLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length allowed for a schema name?
     *
     * @return max name length in bytes
     */
  public int getMaxSchemaNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of a procedure name?
     *
     * @return max name length in bytes
     */
  public int getMaxProcedureNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of a catalog name?
     *
     * @return max name length in bytes
     */
  public int getMaxCatalogNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of a single row?
     *
     * @return max row size in bytes
     */
  public int getMaxRowSize() throws SQLException {
    return 0;
  }

    /**
     * Did getMaxRowSize() include LONGVARCHAR and LONGVARBINARY
     * blobs?
     *
     * @return true if so 
     */
  public boolean doesMaxRowSizeIncludeBlobs() throws SQLException {
    return false;
  }

    /**
     * What's the maximum length of a SQL statement?
     *
     * @return max length in bytes
     */
  public int getMaxStatementLength() throws SQLException {
    return 0;
  }

    /**
     * How many active statements can we have open at one time to this
     * database?
     *
     * @return the maximum 
     */
  public int getMaxStatements() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of a table name?
     *
     * @return max name length in bytes
     */
  public int getMaxTableNameLength() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum number of tables in a SELECT?
     *
     * @return the maximum
     */
  public int getMaxTablesInSelect() throws SQLException {
    return 0;
  }

    /**
     * What's the maximum length of a user name?
     *
     * @return max name length  in bytes
     */
  public int getMaxUserNameLength() throws SQLException {
    return 0;
  }

    //----------------------------------------------------------------------

    /**
     * What's the database's default transaction isolation level?  The
     * values are defined in java.sql.Connection.
     *
     * @return the default isolation level 
     * @see Connection
     */
  public int getDefaultTransactionIsolation() throws SQLException {
    return java.sql.Connection.TRANSACTION_SERIALIZABLE;
  }

    /**
     * Are transactions supported? If not, commit is a noop and the
     * isolation level is TRANSACTION_NONE.
     *
     * @return true if transactions are supported 
     */
  public boolean supportsTransactions() throws SQLException {
    return true;
  }

    /**
     * Does the database support the given transaction isolation level?
     *
     * @param level the values are defined in java.sql.Connection
     * @return true if so 
     * @see Connection
     */
  public boolean supportsTransactionIsolationLevel(int level) throws SQLException {
    return true;
  }

    /**
     * Are both data definition and data manipulation statements
     * within a transaction supported?
     *
     * @return true if so 
     */
  public boolean supportsDataDefinitionAndDataManipulationTransactions()
  throws SQLException {
    return true;
  }

    /**
     * Are only data manipulation statements within a transaction
     * supported?
     *
     * @return true if so
     */
  public boolean supportsDataManipulationTransactionsOnly()
  throws SQLException {
    return false;
  }

    /**
     * Does a data definition statement within a transaction force the
     * transaction to commit?
     *
     * @return true if so 
     */
  public boolean dataDefinitionCausesTransactionCommit()
  throws SQLException {
    return false;
  }

    /**
     * Is a data definition statement within a transaction ignored?
     *
     * @return true if so 
     */
  public boolean dataDefinitionIgnoredInTransactions()
  throws SQLException {
    return false;
  }
  
public boolean supportsResultSetType(int type)
                              throws SQLException {
                                return false;
                              }
                              
public boolean supportsResultSetConcurrency(int type,
                                            int concurrency)
                                     throws SQLException{
                                       return false;
                                     }
                              
public boolean ownUpdatesAreVisible(int type)
                             throws SQLException {
                               return false;
                             }
  
public boolean ownDeletesAreVisible(int type)
                             throws SQLException {
                               return false;
                             }
                             
public boolean ownInsertsAreVisible(int type)
                             throws SQLException {                              
                               return false;
                             }

public boolean othersUpdatesAreVisible(int type)
                                throws SQLException {
                                  return false;
                                }
                                
public boolean othersDeletesAreVisible(int type)
                                throws SQLException {
                                  return false;
                                }

public boolean othersInsertsAreVisible(int type)
                                throws SQLException {
                                  return false;
                                }
                                  
public boolean updatesAreDetected(int type)
                           throws SQLException{
                             return false;
                           }
                                  
public boolean deletesAreDetected(int type)
                           throws SQLException {
                             return false;
                           }

public boolean insertsAreDetected(int type)
                           throws SQLException {
                             return false;
                           }

public boolean supportsBatchUpdates()
                             throws SQLException {
                               return false;
                             }
                             

/* s = pattern
   returns:          
            LIKE 's' ESCAPE 'escapechar', if s contains wildcard
            = 's', if not
            
   Note: for now _ is treated as literal since it's so common & no caller escapes it properly
*/
private String patternWhere(String s) {  
  char LIKE_ALL='%';
  char LIKE_ONE='_';
  int i;
  boolean patterned;

  String r="";
  patterned=false;
  
  i=1;
  while (i<=s.length()) {
      if ( (s.charAt(i-1)==Global.EscapeChar.charAt(0)) && (i<s.length()) && ((s.charAt(i)==LIKE_ALL) || (s.charAt(i)==LIKE_ONE)) ) { //assumes boolean short-circuiting
        i++; //skip escape character
      }
      else {
        if ( (s.charAt(i-1)==LIKE_ALL) /* todo reinstate later || (s.charAt(i-1)==LIKE_ONE) */ ) {patterned=true;} //was not escaped
      }

      r=r+s.charAt(i-1);
      i++;
  }

  if (patterned) {
    r="LIKE '"+r+"' ESCAPE '"+Global.EscapeChar+"' ";
  }
  else {
    r="='"+r+"' ";
  }
  
  return r;
}                                  
                                  


    /**
     * Get a description of stored procedures available in a
     * catalog.
     *
     * <P>Only procedure descriptions matching the schema and
     * procedure name criteria are returned.  They are ordered by
     * PROCEDURE_SCHEM, and PROCEDURE_NAME.
     *
     * <P>Each procedure description has the the following columns:
     *  <OL>
     *  <LI><B>PROCEDURE_CAT</B> String => procedure catalog (may be null)
     *  <LI><B>PROCEDURE_SCHEM</B> String => procedure schema (may be null)
     *  <LI><B>PROCEDURE_NAME</B> String => procedure name
     *  <LI> reserved for future use
     *  <LI> reserved for future use
     *  <LI> reserved for future use
     *  <LI><B>REMARKS</B> String => explanatory comment on the procedure
     *  <LI><B>PROCEDURE_TYPE</B> short => kind of procedure:
     *      <UL>
     *      <LI> procedureResultUnknown - May return a result
     *      <LI> procedureNoResult - Does not return a result
     *      <LI> procedureReturnsResult - Returns a result
     *      </UL>
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schemaPattern a schema name pattern; ' retrieves those
     * without a schema
     * @param procedureNamePattern a procedure name pattern 
     * @return ResultSet - each row is a procedure description 
     * @see #getSearchStringEscape 
     */
  public ResultSet getProcedures(String catalog, String schemaPattern,
   String procedureNamePattern) throws SQLException {
    String where="WHERE 1=1 ";
 
    if (schemaPattern!=null) {
      where=where+"AND ROUTINE_SCHEMA='"+schemaPattern+"' ";
    }   
  
    if (procedureNamePattern!=null) {
      where=where+"AND ROUTINE_NAME "+patternWhere(procedureNamePattern); //LIKE '"+procedureNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
 
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "ROUTINE_CATALOG AS PROCEDURE_CAT,"+
           "ROUTINE_SCHEMA AS PROCEDURE_SCHEM,"+
           "ROUTINE_NAME AS PROCEDURE_NAME,"+
           "NULL,"+
           "NULL,"+
           "NULL,"+
           "'' AS REMARKS,"+           
           "CASE ROUTINE_TYPE "+
           "  WHEN 'PROCEDURE' THEN "+procedureNoResult+
           "  WHEN 'FUNCTION' THEN "+procedureReturnsResult+   //todo: needs union in getProcedureColumns
           " ELSE "+procedureResultUnknown+
           " END AS PROCEDURE_TYPE "+
           "FROM INFORMATION_SCHEMA.ROUTINES "+
           where+
           "ORDER BY PROCEDURE_SCHEM, PROCEDURE_NAME";
      return s.executeQuery(SQL);
  }

    /**
     * PROCEDURE_TYPE - May return a result.
     */
  int procedureResultUnknown  = 0;
    /**
     * PROCEDURE_TYPE - Does not return a result.
     */
  int procedureNoResult    = 1;
    /**
     * PROCEDURE_TYPE - Returns a result.
     */
  int procedureReturnsResult  = 2;

    /**
     * Get a description of a catalog's stored procedure parameters
     * and result columns.
     *
     * <P>Only descriptions matching the schema, procedure and
     * parameter name criteria are returned.  They are ordered by
     * PROCEDURE_SCHEM and PROCEDURE_NAME. Within this, the return value,
     * if any, is first. Next are the parameter descriptions in call
     * order. The column descriptions follow in column number order.
     *
     * <P>Each row in the ResultSet is a parameter description or
     * column description with the following fields:
     *  <OL>
     *  <LI><B>PROCEDURE_CAT</B> String => procedure catalog (may be null)
     *  <LI><B>PROCEDURE_SCHEM</B> String => procedure schema (may be null)
     *  <LI><B>PROCEDURE_NAME</B> String => procedure name
     *  <LI><B>COLUMN_NAME</B> String => column/parameter name 
     *  <LI><B>COLUMN_TYPE</B> Short => kind of column/parameter:
     *      <UL>
     *      <LI> procedureColumnUnknown - nobody knows
     *      <LI> procedureColumnIn - IN parameter
     *      <LI> procedureColumnInOut - INOUT parameter
     *      <LI> procedureColumnOut - OUT parameter
     *      <LI> procedureColumnReturn - procedure return value
     *      <LI> procedureColumnResult - result column in ResultSet
     *      </UL>
     *  <LI><B>DATA_TYPE</B> short => SQL type from java.sql.Types
     *  <LI><B>TYPE_NAME</B> String => SQL type name
     *  <LI><B>PRECISION</B> int => precision
     *  <LI><B>LENGTH</B> int => length in bytes of data
     *  <LI><B>SCALE</B> short => scale
     *  <LI><B>RADIX</B> short => radix
     *  <LI><B>NULLABLE</B> short => can it contain NULL?
     *      <UL>
     *      <LI> procedureNoNulls - does not allow NULL values
     *      <LI> procedureNullable - allows NULL values
     *      <LI> procedureNullableUnknown - nullability unknown
     *      </UL>
     *  <LI><B>REMARKS</B> String => comment describing parameter/column
     *  </OL>
     *
     * <P><B>Note:</B> Some databases may not return the column
     * descriptions for a procedure. Additional columns beyond
     * REMARKS can be defined by the database.
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schemaPattern a schema name pattern; ' retrieves those
     * without a schema 
     * @param procedureNamePattern a procedure name pattern 
     * @param columnNamePattern a column name pattern 
     * @return ResultSet - each row is a stored procedure parameter or 
     *      column description 
     * @see #getSearchStringEscape 
     */
  public ResultSet getProcedureColumns(String catalog,
   String schemaPattern,
   String procedureNamePattern, 
   String columnNamePattern) throws SQLException {

    String where="WHERE 1=1 ";
 
    if (schemaPattern!=null) {
      where=where+"AND SPECIFIC_SCHEMA='"+schemaPattern+"' ";
    }   
  
    if (procedureNamePattern!=null) {
      where=where+"AND SPECIFIC_NAME "+patternWhere(procedureNamePattern); //'"+procedureNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }

    /*todo reinstate: for some reason never seemed blank but was...*/
    if (columnNamePattern!=null) {
      where=where+"AND PARAMETER_NAME "+patternWhere(columnNamePattern); //'"+columnNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    /**/

    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "  SPECIFIC_CATALOG AS PROCEDURE_CAT, "+
           "  SPECIFIC_SCHEMA AS PROCEDURE_SCHEM, "+
           "  SPECIFIC_NAME AS PROCEDURE_NAME, "+
           "  PARAMETER_NAME AS COLUMN_NAME, "+
           "  CASE PARAMETER_MODE "+
           "    WHEN 'IN' THEN "+procedureColumnIn+
           "    WHEN 'INOUT' THEN "+procedureColumnInOut+
           "    WHEN 'OUT' THEN "+procedureColumnOut+
           "  ELSE "+procedureColumnUnknown+
           "  END AS COLUMN_TYPE, "+

           "CASE DATA_TYPE "+              //todo keep in sync with convertType
           "  WHEN 'CHARACTER' THEN "+java.sql.Types.CHAR+" "+ //todo replace with constants for DBXpress!
           "  WHEN 'NUMERIC' THEN "+java.sql.Types.NUMERIC+" "+
           "  WHEN 'DECIMAL' THEN "+java.sql.Types.DECIMAL+" "+
           "  WHEN 'INTEGER' THEN "+java.sql.Types.INTEGER+" "+
           "  WHEN 'SMALLINT' THEN "+java.sql.Types.SMALLINT+" "+
           "  WHEN 'FLOAT' THEN "+java.sql.Types.FLOAT+" "+
           "  WHEN 'REAL' THEN "+java.sql.Types.REAL+" "+
           "  WHEN 'DOUBLE PRECISION' THEN "+java.sql.Types.DOUBLE+" "+
           "  WHEN 'CHARACTER VARYING' THEN "+java.sql.Types.VARCHAR+" "+
           "  WHEN 'DATE' THEN "+java.sql.Types.DATE+" "+ //todo ok?
           "  WHEN 'TIME' THEN "+java.sql.Types.TIME+" "+ //todo ok?
           "  WHEN 'TIMESTAMP' THEN "+java.sql.Types.TIMESTAMP+" "+
           "  WHEN 'TIME WITH TIME ZONE' THEN "+java.sql.Types.TIME+" "+
           "  WHEN 'TIMESTAMP WITH TIME ZONE' THEN "+java.sql.Types.TIMESTAMP+" "+
           "  WHEN 'BINARY LARGE OBJECT' THEN "+java.sql.Types.LONGVARBINARY+" "+ //todo BLOB
           "  WHEN 'CHARACTER LARGE OBJECT' THEN "+java.sql.Types.LONGVARCHAR+" "+ //todo CLOB
           //todo etc.
           //todo join to type_info to get SQL type...?
           "END AS DATA_TYPE, "+
           "DATA_TYPE AS TYPE_NAME, "+
           //"CASE type_name "+
           //"  WHEN 'CHARACTER' THEN 31 "+ //todo replace with constants for DBXpress!
           //"ELSE 0 "+
           //"END AS COLUMN_SUBTYPE,"+
           "CASE "+
           "    WHEN DATA_TYPE='CHARACTER' "+
           "      OR DATA_TYPE='CHARACTER VARYING' "+
           //todo etc.
           "    THEN CHARACTER_MAXIMUM_LENGTH "+
           "    WHEN DATA_TYPE='NUMERIC' "+
           "      OR DATA_TYPE='DECIMAL' "+
           "    THEN CHARACTER_MAXIMUM_LENGTH "+
           "    WHEN DATA_TYPE='SMALLINT' THEN 5 "+
           "    WHEN DATA_TYPE='INTEGER' THEN 10 "+
           "    WHEN DATA_TYPE='REAL' THEN 7 "+
           "    WHEN DATA_TYPE='FLOAT' "+
           "      OR DATA_TYPE='DOUBLE PRECISION' "+
           "    THEN 15 "+
           "    WHEN DATA_TYPE='DATE' "+
           "    THEN 10 "+
           "    WHEN DATA_TYPE='TIME' "+
    //todo!         "    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END "+
           "    THEN 9+NUMERIC_SCALE "+
           "    WHEN DATA_TYPE='TIMESTAMP' "+
    //todo!         "    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END "+
           "    THEN 20+NUMERIC_SCALE "+
           "    WHEN DATA_TYPE='TIME WITH TIME ZONE' "+
    //todo!         "    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END "+
           "    THEN 15+NUMERIC_SCALE  "+
           "    WHEN DATA_TYPE='TIMESTAMP WITH TIME ZONE' "+
    //todo!         "    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END "+
           "    THEN 26+NUMERIC_SCALE "+
           "    WHEN DATA_TYPE='BINARY LARGE OBJECT' "+
           "    THEN CHARACTER_MAXIMUM_LENGTH "+
           "    WHEN DATA_TYPE='CHARACTER LARGE OBJECT' "+
           "    THEN CHARACTER_MAXIMUM_LENGTH "+
           //todo etc.
           "  END AS \"PRECISION\", "+
           "CHARACTER_MAXIMUM_LENGTH AS LENGTH, "+
           "  CASE "+
           "    WHEN DATA_TYPE='DATE' "+
           "      OR DATA_TYPE='TIME' "+
           "      OR DATA_TYPE='TIMESTAMP' "+
           "      OR DATA_TYPE='TIME WITH TIME ZONE' "+
           "      OR DATA_TYPE='TIMESTAMP WITH TIME ZONE' "+
           "    THEN NUMERIC_SCALE "+
           "    WHEN DATA_TYPE='NUMERIC' "+
           "      OR DATA_TYPE='DECIMAL' "+
           "      OR DATA_TYPE='SMALLINT' "+
           "      OR DATA_TYPE='INTEGER' "+
           "    THEN NUMERIC_SCALE "+
           "  ELSE NULL "+
           "  END AS SCALE, "+
           "NUMERIC_PRECISION_RADIX AS RADIX, "+ //todo ok? should be 10 sometimes - get from TYPE_INFO!
           //"  width AS COLUMN_LENGTH, "+
           //todo etc.
           //todo join to type_info to get SQL type...?
           /*
           "  CASE "+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                      //Note: outer reference to sysTable...}
           "    WHEN EXISTS (SELECT 1 FROM CATALOG_DEFINITION_SCHEMA.sysConstraint WHERE "+(*sysTable.*)"table_id=sysConstraint.FK_child_table_id AND rule_check='"+"\""+"'||TRIM(column_name)||'"+"\""+" IS NOT NULL') THEN 0 "+
           "  ELSE "+
           "    1 "+
           "  END AS NULLABLE, "+
           */
           procedureNullable+" AS NULLABLE, "+
           "'' AS REMARKS "+
           //"  FROM (VALUES ('','','','',0,0,'',0,0,0,0,0,'')) AS TT(PROCEDURE_CAT,PROCEDURE_SCHEM,PROCEDURE_NAME,COLUMN_NAME,COLUMN_TYPE,DATA_TYPE,TYPE_NAME,PRECISION,LENGTH,SCALE,RADIX,NULLABLE,REMARKS) "+
           "FROM INFORMATION_SCHEMA.PARAMETERS "+          
           where+
           "ORDER BY PROCEDURE_SCHEM, PROCEDURE_NAME "; //, ORDINAL_POSITION ";
           
      //todo: needs union with ROUTINES to return result parameters for functions...
                 
      return s.executeQuery(SQL);
  }

    /**
     * COLUMN_TYPE - nobody knows.
     */
  int procedureColumnUnknown = 0;

    /**
     * COLUMN_TYPE - IN parameter.
     */
  int procedureColumnIn = 1;

    /**
     * COLUMN_TYPE - INOUT parameter.
     */
  int procedureColumnInOut = 2;

    /**
     * COLUMN_TYPE - OUT parameter.
     */
  int procedureColumnOut = 4;
    /**
     * COLUMN_TYPE - procedure return value.
     */
  int procedureColumnReturn = 5;

    /**
     * COLUMN_TYPE - result column in ResultSet.
     */
  int procedureColumnResult = 3;

    /**
     * TYPE NULLABLE - does not allow NULL values.
     */
    int procedureNoNulls = 0;

    /**
     * TYPE NULLABLE - allows NULL values.
     */
    int procedureNullable = 1;

    /**
     * TYPE NULLABLE - nullability unknown.
     */
    int procedureNullableUnknown = 2;


    /**
     * Get a description of tables available in a catalog.
     *
     * <P>Only table descriptions matching the catalog, schema, table
     * name and type criteria are returned.  They are ordered by
     * TABLE_TYPE, TABLE_SCHEM and TABLE_NAME.
     *
     * <P>Each table description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>TABLE_TYPE</B> String => table type.  Typical types are "TABLE",
     *      "VIEW",  'SYSTEM TABLE", "GLOBAL TEMPORARY", 
     *      "LOCAL TEMPORARY", "ALIAS", 'sYNONYM".
     *  <LI><B>REMARKS</B> String => explanatory comment on the table
     *  </OL>
     *
     * <P><B>Note:</B> Some databases may not return information for
     * all tables.
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schemaPattern a schema name pattern; ' retrieves those
     * without a schema
     * @param tableNamePattern a table name pattern 
     * @param types a list of table types to include; null returns all types 
     * @return ResultSet - each row is a table description
     * @see #getSearchStringEscape 
     */
  public ResultSet getTables(String catalog, String schemaPattern,
   String tableNamePattern, String types[]) throws SQLException {

    String where="WHERE 1=1 ";
    boolean system_tables=false;
 
    if (tableNamePattern!=null) {
      where=where+"AND TABLE_NAME "+patternWhere(tableNamePattern); //'"+tableNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }

    if (types!=null) {
      where=where+"AND (";
      for (int i=0;i<types.length;i++) {
        if (types[i].equals("TABLE")) {
          where=where+"TABLE_TYPE='BASE TABLE'";
        }
        if (types[i].equals("VIEW")) {
          where=where+"(TABLE_TYPE='VIEW' AND TABLE_SCHEMA<>'INFORMATION_SCHEMA')";
        }
        if (types[i].equals("SYSTEM TABLE")) {
          system_tables=true; //prevent another schema filter below, i.e. always list INFORMATION_SCHEMA views as system tables
          where=where+"(TABLE_TYPE='VIEW' AND TABLE_SCHEMA='INFORMATION_SCHEMA')"; 
        }
        
        if ((i+1)<types.length) {
          where=where+" OR ";
        }
      }
      where=where+") ";
    }

    if ((schemaPattern!=null) && (system_tables==false)) {
      where=where+"AND TABLE_SCHEMA='"+schemaPattern+"' ";
    }   
   
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "TABLE_CATALOG AS TABLE_CAT,"+
           "TABLE_SCHEMA AS TABLE_SCHEM,"+
           "TABLE_NAME,"+
           "CASE TABLE_TYPE "+
           "  WHEN 'BASE TABLE' THEN 'TABLE'"+
           "  WHEN 'VIEW' THEN "+
           "    CASE TABLE_SCHEMA "+
           "      WHEN 'INFORMATION_SCHEMA' THEN 'SYSTEM TABLE'"+
           "    ELSE 'VIEW'"+
           "    END "+
           "ELSE 'TABLE' "+     //default to table: todo ok?
           "END AS TABLE_TYPE,"+
           "'' AS REMARKS "+
           "FROM INFORMATION_SCHEMA.TABLES "+
           where+
           "ORDER BY TABLE_NAME";
      return s.executeQuery(SQL);
  }

    /**
     * Get the schema names available in this database.  The results
     * are ordered by schema name.
     *
     * <P>The schema column is:
     *  <OL>
     *  <LI><B>TABLE_SCHEM</B> String => schema name
     *  </OL>
     *
     * @return ResultSet - each row has a single String column that is a
     * schema name 
     */
  public ResultSet getSchemas() throws SQLException {
    //String where="WHERE TABLE_SCHEMA='+schemaPattern+' ";
   
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "SCHEMA_NAME AS TABLE_SCHEM "+
           "FROM INFORMATION_SCHEMA.SCHEMATA "+
           "ORDER BY TABLE_SCHEM";
           
      /* 18/06/03: failed alternative for potentially more useful version
      String SQL="SELECT DISTINCT DEFAULT_SCHEMA_NAME AS TABLE_SCHEM FROM INFORMATION_SCHEMA.USERS "+
           "WHERE USER_NAME=CURRENT_USER OR CURRENT_USER='ADMIN' "+ //Note: special visibility for Admin user (though via USERS so not extra special)
           "ORDER BY TABLE_SCHEM";
      */
      return s.executeQuery(SQL);
  }

    /**
     * Get the catalog names available in this database.  The results
     * are ordered by catalog name.
     *
     * <P>The catalog column is:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => catalog name
     *  </OL>
     *
     * @return ResultSet - each row has a single String column that is a
     * catalog name 
     */
  public ResultSet getCatalogs() throws SQLException {
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "CATALOG_NAME AS TABLE_CAT "+
           "FROM INFORMATION_SCHEMA.INFORMATION_SCHEMA_CATALOG_NAME "+
           "ORDER BY TABLE_CAT";
      return s.executeQuery(SQL);
  }

    /**
     * Get the table types available in this database.  The results
     * are ordered by table type.
     *
     * <P>The table type is:
     *  <OL>
     *  <LI><B>TABLE_TYPE</B> String => table type.  Typical types are "TABLE",
     *      "VIEW",  'sYSTEM TABLE", "GLOBAL TEMPORARY", 
     *      "LOCAL TEMPORARY", "ALIAS", 'sYNONYM".
     *  </OL>
     *
     * @return ResultSet - each row has a single String column that is a
     * table type 
     */
  public ResultSet getTableTypes() throws SQLException {
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "  TABLE_TYPE "+
           "  FROM (VALUES ('TABLE'),('VIEW'),('SYSTEM TABLE')) AS TT(TABLE_TYPE) ";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of table columns available in a catalog.
     *
     * <P>Only column descriptions matching the catalog, schema, table
     * and column name criteria are returned.  They are ordered by
     * TABLE_SCHEM, TABLE_NAME and ORDINAL_POSITION.
     *
     * <P>Each column description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>COLUMN_NAME</B> String => column name
     *  <LI><B>DATA_TYPE</B> short => SQL type from java.sql.Types
     *  <LI><B>TYPE_NAME</B> String => Data source dependent type name
     *  <LI><B>COLUMN_SIZE</B> int => column size.  For char or date
     *      types this is the maximum number of characters, for numeric or
     *      decimal types this is precision.
     *  <LI><B>BUFFER_LENGTH</B> is not used.
     *  <LI><B>DECIMAL_DIGITS</B> int => the number of fractional digits
     *  <LI><B>NUM_PREC_RADIX</B> int => Radix (typically either 10 or 2)
     *  <LI><B>NULLABLE</B> int => is NULL allowed?
     *      <UL>
     *      <LI> columnNoNulls - might not allow NULL values
     *      <LI> columnNullable - definitely allows NULL values
     *      <LI> columnNullableUnknown - nullability unknown
     *      </UL>
     *  <LI><B>REMARKS</B> String => comment describing column (may be null)
     *   <LI><B>COLUMN_DEF</B> String => default value (may be null)
     *  <LI><B>SQL_DATA_TYPE</B> int => unused
     *  <LI><B>SQL_DATETIME_SUB</B> int => unused
     *  <LI><B>CHAR_OCTET_LENGTH</B> int => for char types the 
     *       maximum number of bytes in the column
     *  <LI><B>ORDINAL_POSITION</B> int  => index of column in table 
     *      (starting at 1)
     *  <LI><B>IS_NULLABLE</B> String => "NO" means column definitely 
     *      does not allow NULL values; "YES" means the column might 
     *      allow NULL values.  An empty string means nobody knows.
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schemaPattern a schema name pattern; ' retrieves those
     * without a schema
     * @param tableNamePattern a table name pattern 
     * @param columnNamePattern a column name pattern 
     * @return ResultSet - each row is a column description
     * @see #getSearchStringEscape 
     */
  public ResultSet getColumns(String catalog, String schemaPattern,
   String tableNamePattern, String columnNamePattern) throws SQLException {
    
    String where="WHERE 1=1 ";
 
    if (schemaPattern!=null) {
      where=where+"AND schema_name='"+schemaPattern+"' ";
    }
  
    if (tableNamePattern!=null) {
      where=where+"AND TABLE_NAME "+patternWhere(tableNamePattern); //'"+tableNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    
    /*todo reinstate: for some reason never seemed blank but was...*/
    if (columnNamePattern!=null) {
      where=where+"AND COLUMN_NAME "+patternWhere(columnNamePattern); //'"+columnNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    /**/

 
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
         "catalog_name AS TABLE_CAT,"+
         "schema_name AS TABLE_SCHEM,"+
         "TABLE_NAME,"+
         "COLUMN_NAME, "+
         //"0 AS COLUMN_TYPE,"+
         "CASE type_name "+              //todo keep in sync with convertType
         "  WHEN 'CHARACTER' THEN "+java.sql.Types.CHAR+" "+ //todo replace with constants for DBXpress!
         "  WHEN 'NUMERIC' THEN "+java.sql.Types.NUMERIC+" "+
         "  WHEN 'DECIMAL' THEN "+java.sql.Types.DECIMAL+" "+
         "  WHEN 'INTEGER' THEN "+java.sql.Types.INTEGER+" "+
         "  WHEN 'SMALLINT' THEN "+java.sql.Types.SMALLINT+" "+
         "  WHEN 'FLOAT' THEN "+java.sql.Types.FLOAT+" "+
         "  WHEN 'REAL' THEN "+java.sql.Types.REAL+" "+
         "  WHEN 'DOUBLE PRECISION' THEN "+java.sql.Types.DOUBLE+" "+
         "  WHEN 'CHARACTER VARYING' THEN "+java.sql.Types.VARCHAR+" "+
         "  WHEN 'DATE' THEN "+java.sql.Types.DATE+" "+ //todo ok?
         "  WHEN 'TIME' THEN "+java.sql.Types.TIME+" "+ //todo ok?
         "  WHEN 'TIMESTAMP' THEN "+java.sql.Types.TIMESTAMP+" "+
         "  WHEN 'TIME WITH TIME ZONE' THEN "+java.sql.Types.TIME+" "+
         "  WHEN 'TIMESTAMP WITH TIME ZONE' THEN "+java.sql.Types.TIMESTAMP+" "+
         "  WHEN 'BINARY LARGE OBJECT' THEN "+java.sql.Types.LONGVARBINARY+" "+ //todo BLOB
         "  WHEN 'CHARACTER LARGE OBJECT' THEN "+java.sql.Types.LONGVARCHAR+" "+ //todo CLOB
         //todo etc.
         //todo join to type_info to get SQL type...?
         "END AS DATA_TYPE, "+
         "TYPE_NAME, "+
         //"CASE type_name "+
         //"  WHEN 'CHARACTER' THEN 31 "+ //todo replace with constants for DBXpress!
         //"ELSE 0 "+
         //"END AS COLUMN_SUBTYPE,"+
         "CASE "+
         "    WHEN type_name='CHARACTER' "+
         "      OR type_name='CHARACTER VARYING' "+
         //todo etc.
         "    THEN width "+
         "    WHEN type_name='NUMERIC' "+
         "      OR type_name='DECIMAL' "+
         "    THEN width "+
         "    WHEN type_name='SMALLINT' THEN 5 "+
         "    WHEN type_name='INTEGER' THEN 10 "+
         "    WHEN type_name='REAL' THEN 7 "+
         "    WHEN type_name='FLOAT' "+
         "      OR type_name='DOUBLE PRECISION' "+
         "    THEN 15 "+
         "    WHEN type_name='DATE' "+
         "    THEN 10 "+
         "    WHEN type_name='TIME' "+
  //todo!         "    THEN CASE WHEN scale>0 THEN 9+scale ELSE 8 END END "+
         "    THEN 9+scale "+
         "    WHEN type_name='TIMESTAMP' "+
  //todo!         "    THEN CASE WHEN scale>0 THEN 20+scale ELSE 19 END END "+
         "    THEN 20+scale "+
         "    WHEN type_name='TIME WITH TIME ZONE' "+
  //todo!         "    THEN CASE WHEN scale>0 THEN 15+scale ELSE 14 END END "+
         "    THEN 15+scale  "+
         "    WHEN type_name='TIMESTAMP WITH TIME ZONE' "+
  //todo!         "    THEN CASE WHEN scale>0 THEN 26+scale ELSE 25 END END "+
         "    THEN 26+scale "+
         "    WHEN type_name='BINARY LARGE OBJECT' "+
         "    THEN width "+
         "    WHEN type_name='CHARACTER LARGE OBJECT' "+
         "    THEN width "+
         //todo etc.
         "  END AS COLUMN_SIZE, "+
         "0 AS BUFFER_LENGTH, "+
         "  CASE "+
         "    WHEN type_name='DATE' "+
         "      OR type_name='TIME' "+
         "      OR type_name='TIMESTAMP' "+
         "      OR type_name='TIME WITH TIME ZONE' "+
         "      OR type_name='TIMESTAMP WITH TIME ZONE' "+
         "    THEN scale "+
         "    WHEN type_name='NUMERIC' "+
         "      OR type_name='DECIMAL' "+
         "      OR type_name='SMALLINT' "+
         "      OR type_name='INTEGER' "+
         "    THEN scale "+
         "  ELSE NULL "+
         "  END AS DECIMAL_DIGITS, "+
         "NUM_PREC_RADIX, "+ //todo ok? should be 10 sometimes - get from TYPE_INFO!
         //"  width AS COLUMN_LENGTH, "+
         //todo etc.
         //todo join to type_info to get SQL type...?
         ///*
         "  CASE "+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                    //Note: outer reference to sysTable...}
         "    WHEN EXISTS (SELECT 1 FROM CATALOG_DEFINITION_SCHEMA.sysConstraint WHERE "+/*sysTable.*/"table_id=sysConstraint.FK_child_table_id AND rule_check='"+"\""+"'||TRIM(column_name)||'"+"\""+" IS NOT NULL') THEN 0 "+
         "  ELSE "+
         "    1 "+
         "  END AS NULLABLE, "+
         //*/
         //procedureNullableUnknown+" AS NULLABLE, "+ //debug: avoid error - if ok do to procedureColumns...
         "'' AS REMARKS, "+
         "\"default\" AS COLUMN_DEF, "+
         "SQL_DATA_TYPE, "+
         "SQL_DATETIME_SUB, "+
         "width AS CHAR_OCTET_LENGTH, "+
         "column_id AS ORDINAL_POSITION,"+
         "  CASE "+ //todo note: this only looks for create-table system not-null checks - would also need to check for user/domain (c is not null) as well? better? but non-standard?
                    //Note: outer reference to sysTable...}
         "    WHEN EXISTS (SELECT 1 FROM CATALOG_DEFINITION_SCHEMA.sysConstraint WHERE "+/*sysTable.*/"table_id=sysConstraint.FK_child_table_id AND rule_check='"+"\""+"'||TRIM(column_name)||'"+"\""+" IS NOT NULL') THEN 'NO' "+
         "  ELSE "+
         "    'YES' "+
         "  END AS IS_NULLABLE "+
         //"'' AS IS_NULLABLE "+        
         "FROM "+
//not optimised to use indexes yet, so takes over 1 minute when new!: speed
        "    INFORMATION_SCHEMA.TYPE_INFO natural join"+
        "    CATALOG_DEFINITION_SCHEMA.sysColumn natural join"+
        "    CATALOG_DEFINITION_SCHEMA.sysTable natural join"+
        "    CATALOG_DEFINITION_SCHEMA.sysSchema natural join"+
        "    CATALOG_DEFINITION_SCHEMA.sysCatalog "+
        where+
        "ORDER BY TABLE_SCHEM, TABLE_NAME, ORDINAL_POSITION ";
      return s.executeQuery(SQL);
  }

    /**
     * COLUMN NULLABLE - might not allow NULL values.
     */
    int columnNoNulls = 0;

    /**
     * COLUMN NULLABLE - definitely allows NULL values.
     */
    int columnNullable = 1;

    /**
     * COLUMN NULLABLE - nullability unknown.
     */
    int columnNullableUnknown = 2;

    /**
     * Get a description of the access rights for a table's columns.
     *
     * <P>Only privileges matching the column name criteria are
     * returned.  They are ordered by COLUMN_NAME and PRIVILEGE.
     *
     * <P>Each privilige description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>COLUMN_NAME</B> String => column name
     *  <LI><B>GRANTOR</B> => grantor of access (may be null)
     *  <LI><B>GRANTEE</B> String => grantee of access
     *  <LI><B>PRIVILEGE</B> String => name of access (SELECT, 
     *      INSERT, UPDATE, REFRENCES, ...)
     *  <LI><B>IS_GRANTABLE</B> String => "YES" if grantee is permitted 
     *      to grant to others; "NO" if not; null if unknown 
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name; ' retrieves those without a schema
     * @param table a table name
     * @param columnNamePattern a column name pattern 
     * @return ResultSet - each row is a column privilege description
     * @see #getSearchStringEscape 
     */
  public ResultSet getColumnPrivileges(String catalog, String schema,
   String table, String columnNamePattern) throws SQLException {

    //todo handle catalog if not null
    String where="WHERE 1=1 ";
 
    if (schema!=null) {
      where=where+"AND TABLE_SCHEMA='"+schema+"' ";
    }   
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog
    
    where=where+"AND TABLE_NAME='"+table+"' "; 
  
    if (columnNamePattern!=null) {
      where=where+"AND COLUMN_NAME "+patternWhere(columnNamePattern); //'"+columnNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
         "  TABLE_CATALOG AS TABLE_CAT, "+
//todo         "  """" AS table_cat, "+
         "  TABLE_SCHEMA AS TABLE_SCHEM, "+
//todo         "  """" AS table_schem, "+
         "  TABLE_NAME, "+
         "  COLUMN_NAME, "+
         "  GRANTOR, "+
         "  GRANTEE, "+
         "  PRIVILEGE_TYPE AS PRIVILEGE, "+
         "  IS_GRANTABLE "+
         "FROM "+
         "  INFORMATION_SCHEMA.COLUMN_PRIVILEGES "+
         where+
         " AND TABLE_CATALOG=CURRENT_CATALOG "+
         "ORDER BY COLUMN_NAME, PRIVILEGE ";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of the access rights for each table available
     * in a catalog. Note that a table privilege applies to one or
     * more columns in the table. It would be wrong to assume that
     * this priviledge applies to all columns (this may be true for
     * some systems but is not true for all.)
     *
     * <P>Only privileges matching the schema and table name
     * criteria are returned.  They are ordered by TABLE_SCHEM,
     * TABLE_NAME, and PRIVILEGE.
     *
     * <P>Each privilige description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>GRANTOR</B> => grantor of access (may be null)
     *  <LI><B>GRANTEE</B> String => grantee of access
     *  <LI><B>PRIVILEGE</B> String => name of access (SELECT, 
     *      INSERT, UPDATE, REFRENCES, ...)
     *  <LI><B>IS_GRANTABLE</B> String => "YES" if grantee is permitted 
     *      to grant to others; "NO" if not; null if unknown 
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schemaPattern a schema name pattern; ' retrieves those
     * without a schema
     * @param tableNamePattern a table name pattern 
     * @return ResultSet - each row is a table privilege description
     * @see #getSearchStringEscape 
     */
  public ResultSet getTablePrivileges(String catalog, String schemaPattern,
   String tableNamePattern) throws SQLException {
    
    //todo handle catalog if not null
    String where="WHERE 1=1 ";
 
    if (schemaPattern!=null) {
      where=where+"AND TABLE_SCHEMA "+patternWhere(schemaPattern); //'"+schemaPattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog
  
    if (tableNamePattern!=null) {
      where=where+"AND TABLE_NAME "+patternWhere(tableNamePattern); //'"+tableNamePattern+"' ESCAPE '"+Global.EscapeChar+"' ";
    }
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
         "  TABLE_CATALOG AS TABLE_CAT, "+
//todo         "  """" AS table_cat, "+
         "  TABLE_SCHEMA AS TABLE_SCHEM, "+
//todo         "  """" AS table_schem, "+
         "  TABLE_NAME, "+
         "  GRANTOR, "+
         "  GRANTEE, "+
         "  PRIVILEGE_TYPE AS PRIVILEGE, "+
         "  IS_GRANTABLE "+
         "FROM "+
         "  INFORMATION_SCHEMA.TABLE_PRIVILEGES "+
         where+
         " AND TABLE_CATALOG=CURRENT_CATALOG ";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of a table's optimal set of columns that
     * uniquely identifies a row. They are ordered by SCOPE.
     *
     * <P>Each column description has the following columns:
     *  <OL>
     *  <LI><B>SCOPE</B> short => actual scope of result
     *      <UL>
     *      <LI> bestRowTemporary - very temporary, while using row
     *      <LI> bestRowTransaction - valid for remainder of current transaction
     *      <LI> bestRowSession - valid for remainder of current session
     *      </UL>
     *  <LI><B>COLUMN_NAME</B> String => column name
     *  <LI><B>DATA_TYPE</B> short => SQL data type from java.sql.Types
     *  <LI><B>TYPE_NAME</B> String => Data source dependent type name
     *  <LI><B>COLUMN_SIZE</B> int => precision
     *  <LI><B>BUFFER_LENGTH</B> int => not used
     *  <LI><B>DECIMAL_DIGITS</B> short   => scale
     *  <LI><B>PSEUDO_COLUMN</B> short => is this a pseudo column 
     *      like an Oracle ROWID
     *      <UL>
     *      <LI> bestRowUnknown - may or may not be pseudo column
     *      <LI> bestRowNotPseudo - is NOT a pseudo column
     *      <LI> bestRowPseudo - is a pseudo column
     *      </UL>
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name; ' retrieves those without a schema
     * @param table a table name
     * @param scope the scope of interest; use same values as SCOPE
     * @param nullable include columns that are nullable?
     * @return ResultSet - each row is a column description 
     */
  public ResultSet getBestRowIdentifier(String catalog, String schema,
   String table, int scope, boolean nullable) throws SQLException {
      //todo replace with real data
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "  SCOPE, "+
           "  COLUMN_NAME, "+
           "  DATA_TYPE, "+
           "  TYPE_NAME, "+
           "  COLUMN_SIZE, "+
           "  BUFFER_LENGTH, "+
           "  DECIMAL_DIGITS, "+
           "  PSEUDO_COLUMN "+
           "  FROM (VALUES (0,'',0,'',0,0,0,0)) AS TT(SCOPE,COLUMN_NAME,DATA_TYPE,TYPE_NAME,COLUMN_SIZE,BUFFER_LENGTH,DECIMAL_DIGITS,PSEUDO_COLUMN) "+
           "  WHERE COLUMN_NAME<>'' ";  //temp to ignore all dummy rows
      return s.executeQuery(SQL);
  }
  
    /**
     * BEST ROW SCOPE - very temporary, while using row.
     */
  int bestRowTemporary   = 0;

    /**
     * BEST ROW SCOPE - valid for remainder of current transaction.
     */
  int bestRowTransaction = 1;

    /**
     * BEST ROW SCOPE - valid for remainder of current session.
     */
  int bestRowSession     = 2;

    /**
     * BEST ROW PSEUDO_COLUMN - may or may not be pseudo column.
     */
  int bestRowUnknown  = 0;

    /**
     * BEST ROW PSEUDO_COLUMN - is NOT a pseudo column.
     */
  int bestRowNotPseudo  = 1;

    /**
     * BEST ROW PSEUDO_COLUMN - is a pseudo column.
     */
  int bestRowPseudo  = 2;

    /**
     * Get a description of a table's columns that are automatically
     * updated when any value in a row is updated.  They are
     * unordered.
     *
     * <P>Each column description has the following columns:
     *  <OL>
     *  <LI><B>SCOPE</B> short => is not used
     *  <LI><B>COLUMN_NAME</B> String => column name
     *  <LI><B>DATA_TYPE</B> short => SQL data type from java.sql.Types
     *  <LI><B>TYPE_NAME</B> String => Data source dependent type name
     *  <LI><B>COLUMN_SIZE</B> int => precision
     *  <LI><B>BUFFER_LENGTH</B> int => length of column value in bytes
     *  <LI><B>DECIMAL_DIGITS</B> short   => scale
     *  <LI><B>PSEUDO_COLUMN</B> short => is this a pseudo column 
     *      like an Oracle ROWID
     *      <UL>
     *      <LI> versionColumnUnknown - may or may not be pseudo column
     *      <LI> versionColumnNotPseudo - is NOT a pseudo column
     *      <LI> versionColumnPseudo - is a pseudo column
     *      </UL>
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name; ' retrieves those without a schema
     * @param table a table name
     * @return ResultSet - each row is a column description 
     */
  public ResultSet getVersionColumns(String catalog, String schema,
    String table) throws SQLException {
      //todo replace with real data
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "  SCOPE, "+
           "  COLUMN_NAME, "+
           "  DATA_TYPE, "+
           "  TYPE_NAME, "+
           "  COLUMN_SIZE, "+
           "  BUFFER_LENGTH, "+
           "  DECIMAL_DIGITS, "+
           "  PSEUDO_COLUMN "+
           "  FROM (VALUES (0,'',0,'',0,0,0,0)) AS TT(SCOPE,COLUMN_NAME,DATA_TYPE,TYPE_NAME,COLUMN_SIZE,BUFFER_LENGTH,DECIMAL_DIGITS,PSEUDO_COLUMN) "+
           "  WHERE COLUMN_NAME<>'' ";  //temp to ignore all dummy rows
      return s.executeQuery(SQL);
  }
  
    /**
     * VERSION COLUMNS PSEUDO_COLUMN - may or may not be pseudo column.
     */
  int versionColumnUnknown  = 0;

    /**
     *  VERSION COLUMNS PSEUDO_COLUMN - is NOT a pseudo column.
     */
  int versionColumnNotPseudo  = 1;

    /**
     *  VERSION COLUMNS PSEUDO_COLUMN - is a pseudo column.
     */
  int versionColumnPseudo  = 2;

    /**
     * Get a description of a table's primary key columns.  They
     * are ordered by COLUMN_NAME.
     *
     * <P>Each primary key column description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>COLUMN_NAME</B> String => column name
     *  <LI><B>KEY_SEQ</B> short => sequence number within primary key
     *  <LI><B>PK_NAME</B> String => primary key name (may be null)
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name pattern; ' retrieves those
     * without a schema
     * @param table a table name
     * @return ResultSet - each row is a primary key column description 
     */
  public ResultSet getPrimaryKeys(String catalog, String schema,
   String table) throws SQLException {
    //todo handle catalog if not null
    String where="WHERE PT.TABLE_NAME='"+table+"' ";
 
    if (schema!=null) {
      where=where+"AND PS.schema_name='"+schema+"' ";
    }
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog 
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
         "  PC.catalog_name AS TABLE_CAT, "+
         "  PS.schema_name AS TABLE_SCHEM, "+
         "  PT.table_name AS TABLE_NAME, "+
         "  PL.column_name AS COLUMN_NAME, "+
         "  column_sequence AS KEY_SEQ, "+
         "  constraint_name AS PK_NAME "+
         "FROM "+
         " CATALOG_DEFINITION_SCHEMA.sysCatalog PC, "+
         " CATALOG_DEFINITION_SCHEMA.sysSchema PS, "+
         " CATALOG_DEFINITION_SCHEMA.sysColumn PL, "+
         " CATALOG_DEFINITION_SCHEMA.sysTable PT, "+
         " (CATALOG_DEFINITION_SCHEMA.sysConstraintColumn J natural join "+
         " CATALOG_DEFINITION_SCHEMA.sysConstraint ) "+
         where+
         " AND parent_or_child_table='C' "+
//         AND FK_parent_table_id=0
         " AND rule_type=1 "+
         " AND FK_child_table_id=PT.table_id "+
         " AND PT.schema_id=PS.schema_id "+
         " AND PS.catalog_id=PC.catalog_id "+
         " AND J.column_id=PL.column_id "+
         " AND PL.table_id=PT.table_id "+

         " AND PC.catalog_name=CURRENT_CATALOG "+
         //todo schema/catalog as well
         "ORDER BY COLUMN_NAME";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of the primary key columns that are
     * referenced by a table's foreign key columns (the primary keys
     * imported by a table).  They are ordered by PKTABLE_CAT,
     * PKTABLE_SCHEM, PKTABLE_NAME, and KEY_SEQ.
     *
     * <P>Each primary key column description has the following columns:
     *  <OL>
     *  <LI><B>PKTABLE_CAT</B> String => primary key table catalog 
     *      being imported (may be null)
     *  <LI><B>PKTABLE_SCHEM</B> String => primary key table schema
     *      being imported (may be null)
     *  <LI><B>PKTABLE_NAME</B> String => primary key table name
     *      being imported
     *  <LI><B>PKCOLUMN_NAME</B> String => primary key column name
     *      being imported
     *  <LI><B>FKTABLE_CAT</B> String => foreign key table catalog (may be null)
     *  <LI><B>FKTABLE_SCHEM</B> String => foreign key table schema (may be null)
     *  <LI><B>FKTABLE_NAME</B> String => foreign key table name
     *  <LI><B>FKCOLUMN_NAME</B> String => foreign key column name
     *  <LI><B>KEY_SEQ</B> short => sequence number within foreign key
     *  <LI><B>UPDATE_RULE</B> short => What happens to 
     *       foreign key when primary is updated:
     *      <UL>
     *      <LI> importedNoAction - do not allow update of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - change imported key to agree 
     *               with primary key update
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been updated
     *      <LI> importedKeySetDefault - change imported key to default values 
     *               if its primary key has been updated
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      </UL>
     *  <LI><B>DELETE_RULE</B> short => What happens to 
     *      the foreign key when primary is deleted.
     *      <UL>
     *      <LI> importedKeyNoAction - do not allow delete of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - delete rows that import a deleted key
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been deleted
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      <LI> importedKeySetDefault - change imported key to default if 
     *               its primary key has been deleted
     *      </UL>
     *  <LI><B>FK_NAME</B> String => foreign key name (may be null)
     *  <LI><B>PK_NAME</B> String => primary key name (may be null)
     *  <LI><B>DEFERRABILITY</B> short => can the evaluation of foreign key 
     *      constraints be deferred until commit
     *      <UL>
     *      <LI> importedKeyInitiallyDeferred - see SQL92 for definition
     *      <LI> importedKeyInitiallyImmediate - see SQL92 for definition 
     *      <LI> importedKeyNotDeferrable - see SQL92 for definition 
     *      </UL>
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name pattern; ' retrieves those
     * without a schema
     * @param table a table name
     * @return ResultSet - each row is a primary key column description 
     * @see #getExportedKeys 
     */
  public ResultSet getImportedKeys(String catalog, String schema,
   String table) throws SQLException {
    //todo handle catalog if not null
    String where="WHERE CT.TABLE_NAME='"+table+"' ";
 
    if (schema!=null) {
      where=where+"AND CS.schema_name='"+schema+"' ";
    }
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog 
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
               " PC.catalog_name AS PKTABLE_CAT, "+
               " PS.schema_name AS PKTABLE_SCHEM, "+
               " PT.table_name AS PKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=P.column_id and table_id=FK_parent_table_id) AS PKCOLUMN_NAME, "+
               " CC.catalog_name AS FKTABLE_CAT, "+
               " CS.schema_name AS FKTABLE_SCHEM, "+
               " CT.table_name AS FKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=C.column_id and table_id=FK_child_table_id) AS FKCOLUMN_NAME, "+
               " P.column_sequence AS KEY_SEQ, "+
               " CASE FK_on_update_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS UPDATE_RULE, "+
               " CASE FK_on_delete_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS DELETE_RULE, "+
               " constraint_name AS FK_NAME, "+
               " null AS PK_NAME, "+
               " CASE initially_deferred "+
               "   WHEN 'Y' THEN "+importedKeyInitiallyDeferred+" "+
               " ELSE"+
               "   CASE \"deferrable\" "+
               "     WHEN 'Y' THEN "+importedKeyInitiallyImmediate+" "+
               "   ELSE "+
               "     "+importedKeyNotDeferrable+" "+
               "   END "+
               " END AS DEFERRABILITY "+
               "FROM "+
               " catalog_definition_schema.sysConstraint S, "+
               " catalog_definition_schema.sysConstraintColumn P, "+
               " catalog_definition_schema.sysConstraintColumn C, "+

               " catalog_definition_schema.sysTable PT, catalog_definition_schema.sysSchema PS, "+
               " catalog_definition_schema.sysCatalog PC, "+
               
               " catalog_definition_schema.sysTable CT, catalog_definition_schema.sysSchema CS, "+
               " catalog_definition_schema.sysCatalog CC "+
         where+
         " AND S.constraint_id=P.constraint_id and P.parent_or_child_table='P' "+
         " AND S.constraint_id=C.constraint_id and C.parent_or_child_table='C' "+
         " AND PT.table_id=FK_parent_table_id AND PS.schema_id=PT.schema_id "+
         " AND PC.catalog_id=PS.catalog_id "+
         " AND CT.table_id=FK_child_table_id AND CS.schema_id=CT.schema_id "+
         " AND CC.catalog_id=CS.catalog_id "+
         
         " AND rule_type=2 "+
         " AND CC.catalog_name=CURRENT_CATALOG "+
         //todo schema/catalog as well
         "ORDER BY PKTABLE_CAT, PKTABLE_SCHEM, PKTABLE_NAME, KEY_SEQ";
      return s.executeQuery(SQL);   
  }

    /**
     * IMPORT KEY UPDATE_RULE and DELETE_RULE - for update, change
     * imported key to agree with primary key update; for delete,
     * delete rows that import a deleted key.
     */
  int importedKeyCascade  = 0;

    /**
     * IMPORT KEY UPDATE_RULE and DELETE_RULE - do not allow update or
     * delete of primary key if it has been imported.  
     */
  int importedKeyRestrict = 1;

    /**
     * IMPORT KEY UPDATE_RULE and DELETE_RULE - change imported key to
     * NULL if its primary key has been updated or deleted.
     */
  int importedKeySetNull  = 2;

    /**
     * IMPORT KEY UPDATE_RULE and DELETE_RULE - do not allow update or
     * delete of primary key if it has been imported.  
     */
  int importedKeyNoAction = 3;

    /**
     * IMPORT KEY UPDATE_RULE and DELETE_RULE - change imported key to
     * default values if its primary key has been updated or deleted.
     */
  int importedKeySetDefault  = 4;

    /**
     * IMPORT KEY DEFERRABILITY - see SQL92 for definition
     */
  int importedKeyInitiallyDeferred  = 5;

    /**
     * IMPORT KEY DEFERRABILITY - see SQL92 for definition
     */
  int importedKeyInitiallyImmediate  = 6;

    /**
     * IMPORT KEY DEFERRABILITY - see SQL92 for definition
     */
  int importedKeyNotDeferrable  = 7;

    /**
     * Get a description of the foreign key columns that reference a
     * table's primary key columns (the foreign keys exported by a
     * table).  They are ordered by FKTABLE_CAT, FKTABLE_SCHEM,
     * FKTABLE_NAME, and KEY_SEQ.
     *
     * <P>Each foreign key column description has the following columns:
     *  <OL>
     *  <LI><B>PKTABLE_CAT</B> String => primary key table catalog (may be null)
     *  <LI><B>PKTABLE_SCHEM</B> String => primary key table schema (may be null)
     *  <LI><B>PKTABLE_NAME</B> String => primary key table name
     *  <LI><B>PKCOLUMN_NAME</B> String => primary key column name
     *  <LI><B>FKTABLE_CAT</B> String => foreign key table catalog (may be null)
     *      being exported (may be null)
     *  <LI><B>FKTABLE_SCHEM</B> String => foreign key table schema (may be null)
     *      being exported (may be null)
     *  <LI><B>FKTABLE_NAME</B> String => foreign key table name
     *      being exported
     *  <LI><B>FKCOLUMN_NAME</B> String => foreign key column name
     *      being exported
     *  <LI><B>KEY_SEQ</B> short => sequence number within foreign key
     *  <LI><B>UPDATE_RULE</B> short => What happens to 
     *       foreign key when primary is updated:
     *      <UL>
     *      <LI> importedNoAction - do not allow update of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - change imported key to agree 
     *               with primary key update
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been updated
     *      <LI> importedKeySetDefault - change imported key to default values 
     *               if its primary key has been updated
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      </UL>
     *  <LI><B>DELETE_RULE</B> short => What happens to 
     *      the foreign key when primary is deleted.
     *      <UL>
     *      <LI> importedKeyNoAction - do not allow delete of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - delete rows that import a deleted key
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been deleted
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      <LI> importedKeySetDefault - change imported key to default if 
     *               its primary key has been deleted
     *      </UL>
     *  <LI><B>FK_NAME</B> String => foreign key name (may be null)
     *  <LI><B>PK_NAME</B> String => primary key name (may be null)
     *  <LI><B>DEFERRABILITY</B> short => can the evaluation of foreign key 
     *      constraints be deferred until commit
     *      <UL>
     *      <LI> importedKeyInitiallyDeferred - see SQL92 for definition
     *      <LI> importedKeyInitiallyImmediate - see SQL92 for definition 
     *      <LI> importedKeyNotDeferrable - see SQL92 for definition 
     *      </UL>
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name pattern; ' retrieves those
     * without a schema
     * @param table a table name
     * @return ResultSet - each row is a foreign key column description 
     * @see #getImportedKeys 
     */
  public ResultSet getExportedKeys(String catalog, String schema,
   String table) throws SQLException {
    //todo handle catalog if not null
    String where="WHERE PT.TABLE_NAME='"+table+"' ";
 
    if (schema!=null) {
      where=where+"AND PS.schema_name='"+schema+"' ";
    }
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog 
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
               " PC.catalog_name AS PKTABLE_CAT, "+
               " PS.schema_name AS PKTABLE_SCHEM, "+
               " PT.table_name AS PKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=P.column_id and table_id=FK_parent_table_id) AS PKCOLUMN_NAME, "+
               " CC.catalog_name AS FKTABLE_CAT, "+
               " CS.schema_name AS FKTABLE_SCHEM, "+
               " CT.table_name AS FKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=C.column_id and table_id=FK_child_table_id) AS FKCOLUMN_NAME, "+
               " P.column_sequence AS KEY_SEQ, "+
               " CASE FK_on_update_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS UPDATE_RULE, "+
               " CASE FK_on_delete_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS DELETE_RULE, "+
               " constraint_name AS FK_NAME, "+
               " null AS PK_NAME, "+
               " CASE initially_deferred "+
               "   WHEN 'Y' THEN "+importedKeyInitiallyDeferred+" "+
               " ELSE"+
               "   CASE \"deferrable\" "+
               "     WHEN 'Y' THEN "+importedKeyInitiallyImmediate+" "+
               "   ELSE "+
               "     "+importedKeyNotDeferrable+" "+
               "   END "+
               " END AS DEFERRABILITY "+
               "FROM "+
               " catalog_definition_schema.sysConstraint S, "+
               " catalog_definition_schema.sysConstraintColumn P, "+
               " catalog_definition_schema.sysConstraintColumn C, "+

               " catalog_definition_schema.sysTable PT, catalog_definition_schema.sysSchema PS, "+
               " catalog_definition_schema.sysCatalog PC, "+
               
               " catalog_definition_schema.sysTable CT, catalog_definition_schema.sysSchema CS, "+
               " catalog_definition_schema.sysCatalog CC "+
         where+
         " AND S.constraint_id=P.constraint_id and P.parent_or_child_table='P' "+
         " AND S.constraint_id=C.constraint_id and C.parent_or_child_table='C' "+
         " AND PT.table_id=FK_parent_table_id AND PS.schema_id=PT.schema_id "+
         " AND PC.catalog_id=PS.catalog_id "+
         " AND CT.table_id=FK_child_table_id AND CS.schema_id=CT.schema_id "+
         " AND CC.catalog_id=CS.catalog_id "+
                 
         " AND rule_type=2 "+
         " AND PC.catalog_name=CURRENT_CATALOG "+
         //todo schema/catalog as well
         "ORDER BY FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, KEY_SEQ";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of the foreign key columns in the foreign key
     * table that reference the primary key columns of the primary key
     * table (describe how one table imports another's key.) This
     * should normally return a single foreign key/primary key pair
     * (most tables only import a foreign key from a table once.)  They
     * are ordered by FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, and
     * KEY_SEQ.
     *
     * <P>Each foreign key column description has the following columns:
     *  <OL>
     *  <LI><B>PKTABLE_CAT</B> String => primary key table catalog (may be null)
     *  <LI><B>PKTABLE_SCHEM</B> String => primary key table schema (may be null)
     *  <LI><B>PKTABLE_NAME</B> String => primary key table name
     *  <LI><B>PKCOLUMN_NAME</B> String => primary key column name
     *  <LI><B>FKTABLE_CAT</B> String => foreign key table catalog (may be null)
     *      being exported (may be null)
     *  <LI><B>FKTABLE_SCHEM</B> String => foreign key table schema (may be null)
     *      being exported (may be null)
     *  <LI><B>FKTABLE_NAME</B> String => foreign key table name
     *      being exported
     *  <LI><B>FKCOLUMN_NAME</B> String => foreign key column name
     *      being exported
     *  <LI><B>KEY_SEQ</B> short => sequence number within foreign key
     *  <LI><B>UPDATE_RULE</B> short => What happens to 
     *       foreign key when primary is updated:
     *      <UL>
     *      <LI> importedNoAction - do not allow update of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - change imported key to agree 
     *               with primary key update
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been updated
     *      <LI> importedKeySetDefault - change imported key to default values 
     *               if its primary key has been updated
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      </UL>
     *  <LI><B>DELETE_RULE</B> short => What happens to 
     *      the foreign key when primary is deleted.
     *      <UL>
     *      <LI> importedKeyNoAction - do not allow delete of primary 
     *               key if it has been imported
     *      <LI> importedKeyCascade - delete rows that import a deleted key
     *      <LI> importedKeySetNull - change imported key to NULL if 
     *               its primary key has been deleted
     *      <LI> importedKeyRestrict - same as importedKeyNoAction 
     *                                 (for ODBC 2.x compatibility)
     *      <LI> importedKeySetDefault - change imported key to default if 
     *               its primary key has been deleted
     *      </UL>
     *  <LI><B>FK_NAME</B> String => foreign key name (may be null)
     *  <LI><B>PK_NAME</B> String => primary key name (may be null)
     *  <LI><B>DEFERRABILITY</B> short => can the evaluation of foreign key 
     *      constraints be deferred until commit
     *      <UL>
     *      <LI> importedKeyInitiallyDeferred - see SQL92 for definition
     *      <LI> importedKeyInitiallyImmediate - see SQL92 for definition 
     *      <LI> importedKeyNotDeferrable - see SQL92 for definition 
     *      </UL>
     *  </OL>
     *
     * @param primaryCatalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param primarySchema a schema name pattern; ' retrieves those
     * without a schema
     * @param primaryTable the table name that exports the key
     * @param foreignCatalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param foreignSchema a schema name pattern; ' retrieves those
     * without a schema
     * @param foreignTable the table name that imports the key
     * @return ResultSet - each row is a foreign key column description 
     * @see #getImportedKeys 
     */
  public ResultSet getCrossReference(
   String primaryCatalog, String primarySchema, String primaryTable,
   String foreignCatalog, String foreignSchema, String foreignTable)
   throws SQLException {
    //todo handle catalog if not null
    String where="WHERE PT.TABLE_NAME='"+primaryTable+"' AND CT.TABLE_NAME='"+foreignTable+"' ";
 
    if (primarySchema!=null) {
      where=where+"AND PS.schema_name='"+primarySchema+"' ";
    }
    if (foreignSchema!=null) {
      where=where+"AND CS.schema_name='"+foreignSchema+"' ";
    }
    //todo needed? where=where+"AND schema_id<>1 "; //todo replace 1 with constant for sysCatalog 
    
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
    String SQL="SELECT "+
               " PC.catalog_name AS PKTABLE_CAT, "+
               " PS.schema_name AS PKTABLE_SCHEM, "+
               " PT.table_name AS PKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=P.column_id and table_id=FK_parent_table_id) AS PKCOLUMN_NAME, "+
               " CC.catalog_name AS FKTABLE_CAT, "+
               " CS.schema_name AS FKTABLE_SCHEM, "+
               " CT.table_name AS FKTABLE_NAME, "+
               " (SELECT column_name from catalog_definition_schema.sysColumn where column_id=C.column_id and table_id=FK_child_table_id) AS FKCOLUMN_NAME, "+
               " P.column_sequence AS KEY_SEQ, "+
               " CASE FK_on_update_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS UPDATE_RULE, "+
               " CASE FK_on_delete_action"+          
               "   WHEN 0 THEN "+importedKeyNoAction+" "+
               "   WHEN 1 THEN "+importedKeyCascade+" "+
               "   WHEN 2 THEN "+importedKeyRestrict+" "+
               "   WHEN 3 THEN "+importedKeySetNull+" "+
               "   WHEN 4 THEN "+importedKeySetDefault+" "+
               " END AS DELETE_RULE, "+
               " constraint_name AS FK_NAME, "+
               " null AS PK_NAME, "+
               " CASE initially_deferred "+
               "   WHEN 'Y' THEN "+importedKeyInitiallyDeferred+" "+
               " ELSE"+
               "   CASE \"deferrable\" "+
               "     WHEN 'Y' THEN "+importedKeyInitiallyImmediate+" "+
               "   ELSE "+
               "     "+importedKeyNotDeferrable+" "+
               "   END "+
               " END AS DEFERRABILITY "+
               "FROM "+
               " catalog_definition_schema.sysConstraint S, "+
               " catalog_definition_schema.sysConstraintColumn P, "+
               " catalog_definition_schema.sysConstraintColumn C, "+

               " catalog_definition_schema.sysTable PT, catalog_definition_schema.sysSchema PS, "+
               " catalog_definition_schema.sysCatalog PC, "+
               
               " catalog_definition_schema.sysTable CT, catalog_definition_schema.sysSchema CS, "+
               " catalog_definition_schema.sysCatalog CC "+
         where+
         " AND S.constraint_id=P.constraint_id and P.parent_or_child_table='P' "+
         " AND S.constraint_id=C.constraint_id and C.parent_or_child_table='C' "+
         " AND PT.table_id=FK_parent_table_id AND PS.schema_id=PT.schema_id "+
         " AND PC.catalog_id=PS.catalog_id "+
         " AND CT.table_id=FK_child_table_id AND CS.schema_id=CT.schema_id "+
         " AND CC.catalog_id=CS.catalog_id "+
         
         " AND rule_type=2 "+
         " AND PC.catalog_name=CURRENT_CATALOG "+
         //todo schema/catalog as well
         "ORDER BY FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, KEY_SEQ";
      return s.executeQuery(SQL);
  }

    /**
     * Get a description of all the standard SQL types supported by
     * this database. They are ordered by DATA_TYPE and then by how
     * closely the data type maps to the corresponding JDBC SQL type.
     *
     * <P>Each type description has the following columns:
     *  <OL>
     *  <LI><B>TYPE_NAME</B> String => Type name
     *  <LI><B>DATA_TYPE</B> short => SQL data type from java.sql.Types
     *  <LI><B>PRECISION</B> int => maximum precision
     *  <LI><B>LITERAL_PREFIX</B> String => prefix used to quote a literal 
     *      (may be null)
     *  <LI><B>LITERAL_SUFFIX</B> String => suffix used to quote a literal 
            (may be null)
     *  <LI><B>CREATE_PARAMS</B> String => parameters used in creating 
     *      the type (may be null)
     *  <LI><B>NULLABLE</B> short => can you use NULL for this type?
     *      <UL>
     *      <LI> typeNoNulls - does not allow NULL values
     *      <LI> typeNullable - allows NULL values
     *      <LI> typeNullableUnknown - nullability unknown
     *      </UL>
     *  <LI><B>CASE_SENSITIVE</B> boolean=> is it case sensitive?
     *  <LI><B>SEARCHABLE</B> short => can you use "WHERE" based on this type:
     *      <UL>
     *      <LI> typePredNone - No support
     *      <LI> typePredChar - Only supported with WHERE .. LIKE
     *      <LI> typePredBasic - Supported except for WHERE .. LIKE
     *      <LI> typeSearchable - Supported for all WHERE ..
     *      </UL>
     *  <LI><B>UNSIGNED_ATTRIBUTE</B> boolean => is it unsigned?
     *  <LI><B>FIXED_PREC_SCALE</B> boolean => can it be a money value?
     *  <LI><B>AUTO_INCREMENT</B> boolean => can it be used for an 
     *      auto-increment value?
     *  <LI><B>LOCAL_TYPE_NAME</B> String => localized version of type name 
     *      (may be null)
     *  <LI><B>MINIMUM_SCALE</B> short => minimum scale supported
     *  <LI><B>MAXIMUM_SCALE</B> short => maximum scale supported
     *  <LI><B>SQL_DATA_TYPE</B> int => unused
     *  <LI><B>SQL_DATETIME_SUB</B> int => unused
     *  <LI><B>NUM_PREC_RADIX</B> int => usually 2 or 10
     *  </OL>
     *
     * @return ResultSet - each row is a SQL type description 
     */
  public ResultSet getTypeInfo() throws SQLException {
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous

    String SQL="SELECT TYPE_NAME,"+
         "CASE type_name "+ //keep in sync with getColumns
         "  WHEN 'CHARACTER' THEN "+java.sql.Types.CHAR+" "+ //todo replace with constants for DBXpress!
         "  WHEN 'NUMERIC' THEN "+java.sql.Types.NUMERIC+" "+
         "  WHEN 'DECIMAL' THEN "+java.sql.Types.DECIMAL+" "+
         "  WHEN 'INTEGER' THEN "+java.sql.Types.INTEGER+" "+
         "  WHEN 'SMALLINT' THEN "+java.sql.Types.SMALLINT+" "+
         "  WHEN 'FLOAT' THEN "+java.sql.Types.FLOAT+" "+
         "  WHEN 'REAL' THEN "+java.sql.Types.REAL+" "+
         "  WHEN 'DOUBLE PRECISION' THEN "+java.sql.Types.DOUBLE+" "+
         "  WHEN 'CHARACTER VARYING' THEN "+java.sql.Types.VARCHAR+" "+
         "  WHEN 'DATE' THEN "+java.sql.Types.DATE+" "+ //todo ok?
         "  WHEN 'TIME' THEN "+java.sql.Types.TIME+" "+ //todo ok?
         "  WHEN 'TIMESTAMP' THEN "+java.sql.Types.TIMESTAMP+" "+
         "  WHEN 'TIME WITH TIME ZONE' THEN "+java.sql.Types.TIME+" "+
         "  WHEN 'TIMESTAMP WITH TIME ZONE' THEN "+java.sql.Types.TIMESTAMP+" "+
         "  WHEN 'BINARY LARGE OBJECT' THEN "+java.sql.Types.LONGVARBINARY+" "+ //todo BLOB
         "  WHEN 'CHARACTER LARGE OBJECT' THEN "+java.sql.Types.LONGVARCHAR+" "+ //todo CLOB
         //todo etc.
         //todo join to type_info to get SQL type...?
         "END AS DATA_TYPE, "+
         "COLUMN_SIZE AS \"PRECISION\","+
         "LITERAL_PREFIX,"+
         "LITERAL_SUFFIX,"+
         "CREATE_PARAMS,"+
         "NULLABLE,"+
         "CASE_SENSITIVE,"+
         "SEARCHABLE,"+
         "UNSIGNED_ATTRIBUTE,"+
         "FIXED_PREC_SCALE,"+
         "AUTO_UNIQUE_VALUE AS AUTO_INCREMENT,"+
         "LOCAL_TYPE_NAME,"+
         "MINIMUM_SCALE,"+
         "MAXIMUM_SCALE,"+
         "SQL_DATA_TYPE,"+
         "SQL_DATETIME_SUB,"+
         "NUM_PREC_RADIX "+
         "FROM INFORMATION_SCHEMA.TYPE_INFO ";
      return s.executeQuery(SQL);
  }
  
    /**
     * TYPE NULLABLE - does not allow NULL values.
     */
    int typeNoNulls = 0;

    /**
     * TYPE NULLABLE - allows NULL values.
     */
    int typeNullable = 1;

    /**
     * TYPE NULLABLE - nullability unknown.
     */
    int typeNullableUnknown = 2;

    /**
     * TYPE INFO SEARCHABLE - No support.
     */
  int typePredNone = 0;

    /**
     * TYPE INFO SEARCHABLE - Only supported with WHERE .. LIKE.
     */
  int typePredChar = 1;

    /**
     * TYPE INFO SEARCHABLE -  Supported except for WHERE .. LIKE.
     */
  int typePredBasic = 2;

    /**
     * TYPE INFO SEARCHABLE - Supported for all WHERE ...
     */
  int typeSearchable  = 3;

    /**
     * Get a description of a table's indices and statistics. They are
     * ordered by NON_UNIQUE, TYPE, INDEX_NAME, and ORDINAL_POSITION.
     *
     * <P>Each index column description has the following columns:
     *  <OL>
     *  <LI><B>TABLE_CAT</B> String => table catalog (may be null)
     *  <LI><B>TABLE_SCHEM</B> String => table schema (may be null)
     *  <LI><B>TABLE_NAME</B> String => table name
     *  <LI><B>NON_UNIQUE</B> boolean => Can index values be non-unique? 
     *      false when TYPE is tableIndexStatistic
     *  <LI><B>INDEX_QUALIFIER</B> String => index catalog (may be null); 
     *      null when TYPE is tableIndexStatistic
     *  <LI><B>INDEX_NAME</B> String => index name; null when TYPE is 
     *      tableIndexStatistic
     *  <LI><B>TYPE</B> short => index type:
     *      <UL>
     *      <LI> tableIndexStatistic - this identifies table statistics that are
     *           returned in conjuction with a table's index descriptions
     *      <LI> tableIndexClustered - this is a clustered index
     *      <LI> tableIndexHashed - this is a hashed index
     *      <LI> tableIndexOther - this is some other style of index
     *      </UL>
     *  <LI><B>ORDINAL_POSITION</B> short => column sequence number 
     *      within index; zero when TYPE is tableIndexStatistic
     *  <LI><B>COLUMN_NAME</B> String => column name; null when TYPE is 
     *      tableIndexStatistic
     *  <LI><B>ASC_OR_DESC</B> String => column sort sequence, "A" => ascending, 
     *      "D" => descending, may be null if sort sequence is not supported; 
     *      null when TYPE is tableIndexStatistic  
     *  <LI><B>CARDINALITY</B> int => When TYPE is tableIndexStatistic, then 
     *      this is the number of rows in the table; otherwise, it is the 
     *      number of unique values in the index.
     *  <LI><B>PAGES</B> int => When TYPE is  tableIndexStatisic then 
     *      this is the number of pages used for the table, otherwise it 
     *      is the number of pages used for the current index.
     *  <LI><B>FILTER_CONDITION</B> String => Filter condition, if any.  
     *      (may be null)
     *  </OL>
     *
     * @param catalog a catalog name; ' retrieves those without a
     * catalog; null means drop catalog name from the selection criteria
     * @param schema a schema name pattern; ' retrieves those without a schema
     * @param table a table name  
     * @param unique when true, return only indices for unique values; 
     *     when false, return indices regardless of whether unique or not 
     * @param approximate when true, result is allowed to reflect approximate 
     *     or out of data values; when false, results are requested to be 
     *     accurate
     * @return ResultSet - each row is an index column description 
     */
  public ResultSet getIndexInfo(String catalog, String schema, String table,
   boolean unique, boolean approximate) throws SQLException {
      //todo replace with real data
    StatementSQL s=new StatementSQL(fCon); //todo no need to store reference! = anonymous
      String SQL="SELECT "+
           "  TABLE_CAT, "+
           "  TABLE_SCHEM, "+
           "  TABLE_NAME, "+
           "  NON_UNIQUE, "+
           "  INDEX_QUALIFIER, "+
           "  INDEX_NAME, "+
           "  TYPE, "+
           "  ORDINAL_POSITION, "+
           "  COLUMN_NAME, "+
           "  ASC_OR_DESC, "+
           "  CARDINALITY, "+
           "  PAGES, "+
           "  FILTER_CONDITION "+
           "  FROM (VALUES ('','','',0,'','','',0,0,'','',0,0,'')) AS TT(TABLE_CAT,TABLE_SCHEM,TABLE_NAME,NON_UNIQUE,INDEX_QUALIFIER,INDEX_NAME,TYPE,ORDINAL_POSITION,COLUMN_NAME,ASC_OR_DESC,CARDINALITY,PAGES,FILTER_CONDITION) "+
           "  WHERE TABLE_CAT<>'' ";  //temp to ignore all dummy rows
      return s.executeQuery(SQL);
}

    /**
     * INDEX INFO TYPE - this identifies table statistics that are
     * returned in conjuction with a table's index descriptions
     */
  short tableIndexStatistic = 0;

    /**
     * INDEX INFO TYPE - this identifies a clustered index
     */
  short tableIndexClustered = 1;

    /**
     * INDEX INFO TYPE - this identifies a hashed index
     */
  short tableIndexHashed    = 2;

    /**
     * INDEX INFO TYPE - this identifies some other form of index
     */
  short tableIndexOther     = 3;


public ResultSet getUDTs(String catalog,
                         String schemaPattern,
                         String typeNamePattern,
                         int[] types)
                  throws SQLException {
                     return null;
                  }

public Connection getConnection()
                         throws SQLException {
                            return fCon;
                         }                             


private String askServer(short infoType) throws SQLException {
String infoValue;
  //pass this info to server now
  fCon.marshalBuffer.ClearToSend();
  /*Note: because we know these marshalled parameters all fit in a buffer together,
   and because the buffer is now empty after the clearToSend,
   we can omit the error result checking in the following put() calls = speed
  */
  //note: it might be easier just to pass serverStmt,array_size
  //but we're trying to keep this function the same on the server because we need it for other things...
  // - we could always call a special serverSetArraySize routine here instead?
  //      or pass it every time we call ServerFetch?
  fCon.marshalBuffer.putFunction(Global.SQL_API_SQLGETINFO);
  fCon.marshalBuffer.putSQLHDBC(0/*(int)(this)*/);
  fCon.marshalBuffer.putSQLSMALLINT(infoType);
  if (fCon.marshalBuffer.Send()!=Global.ok) {
    throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
  }

  /*Wait for response*/
  if (fCon.marshalBuffer.Read()!=Global.ok) {
    throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
  }
  /*Note: because we know these marshalled parameters all fit in a buffer together,
   and because the buffer has been read in total by the Read above because its size was known,
   we can omit the error result checking in the following get() calls = speed
  */
  functionId=fCon.marshalBuffer.getFunction();
  if (functionId!=Global.SQL_API_SQLGETINFO) {
    GlobalUtil.logError("AskServer Failed functionId="+functionId);
    throw new SQLException (Global.seConnectionFailedText,Global.ss08S01,Global.seConnectionFailed);     
  }

  infoValue=fCon.marshalBuffer.getpUCHAR_SWORD();

  resultCode=fCon.marshalBuffer.getRETCODE();
  //result:=resultCode; //pass it on //todo fix for DBX first!!!!!
  GlobalUtil.logError("AskServer returns "+resultCode);

  /*if error, then get error details: local-number, default-text*/
  int errCount=fCon.marshalBuffer.getSQLINTEGER(); //error count
  if (resultCode==Global.SQL_ERROR) {
    for (int err=1;err<=errCount;err++) {
      resultErrCode=fCon.marshalBuffer.getSQLINTEGER();
      resultErrText=fCon.marshalBuffer.getpUCHAR_SWORD();
      GlobalUtil.logError("server error="+resultErrText);
    }
    //todo remove: never will happen: exit;
  }
  
  return infoValue;
}

};


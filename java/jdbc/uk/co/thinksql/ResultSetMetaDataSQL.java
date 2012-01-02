package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import java.sql.*;

import uk.co.thinksql.ResultSetSQL.*;

/**
 * A ResultSetMetaData object can be used to find out about the types 
 * and properties of the columns in a ResultSet.
 */

public class ResultSetMetaDataSQL implements java.sql.ResultSetMetaData {

  private ResultSetSQL frs;

  public ResultSetMetaDataSQL(ResultSetSQL rs) {
    frs=rs;     
  }
  
  /**
   * What's the number of columns in the ResultSet?
   *
   * @return the number
   */
  public int getColumnCount() throws SQLException {
    return frs.fStmt.colCount;
  }

  /**
   * Is the column automatically numbered, thus read-only?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isAutoIncrement(int column) throws SQLException {
    return false;
  }

  /**
   * Does a column's case matter?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isCaseSensitive(int column) throws SQLException {
    return false;
  }	

  /**
   * Can the column be used in a where clause?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isSearchable(int column) throws SQLException {
    return true;
  }

  /**
   * Is the column a cash value?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isCurrency(int column) throws SQLException {
    return false;
  }

  /**
   * Can you put a NULL in this column?		
   *
   * @param column the first column is 1, the second is 2, ...
   * @return columnNoNulls, columnNullable or columnNullableUnknown
   */
  public int isNullable(int column) throws SQLException {
    switch (frs.fStmt.col[column-1].iNullOffset) {
      case 0:return columnNoNulls; //break
      case 1:return columnNullable; //break
    default: return columnNullableUnknown;
    };
  }

  /**
   * Does not allow NULL values.
   */
  int columnNoNulls = 0;

  /**
   * Allows NULL values.
   */
  int columnNullable = 1;

  /**
   * Nullability unknown.
   */
  int columnNullableUnknown = 2;

  /**
   * Is the column a signed number?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isSigned(int column) throws SQLException {
    switch (frs.fStmt.col[column-1].iFldType) {
      case Global.SQL_INTEGER: 
      case Global.SQL_SMALLINT: 
      case Global.SQL_FLOAT: 
      case Global.SQL_NUMERIC: 
      case Global.SQL_DECIMAL: return true; //break
      
     default: return false;
    };
  }

  /**
   * What's the column's normal max width in chars?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return max width
   */
  public int getColumnDisplaySize(int column) throws SQLException {
    return frs.fStmt.col[column-1].iUnits1+frs.fStmt.col[column-1].iUnits1; //todo ok?
  }

  /**
   * What's the suggested column title for use in printouts and
   * displays?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so 
   */
  public String getColumnLabel(int column) throws SQLException {	
    return frs.fStmt.col[column-1].colName;
  }

  /**
   * What's a column's name?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return column name
   */
  public String getColumnName(int column) throws SQLException {
    return frs.fStmt.col[column-1].colName;
  }

  /**
   * What's a column's table's schema?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return schema name or "" if not applicable
   */
  public String getSchemaName(int column) throws SQLException {
    return ""; //todo get from server?
  }

  /**
   * What's a column's number of decimal digits?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return precision
   */
  public int getPrecision(int column) throws SQLException {
    return frs.fStmt.col[column-1].iUnits1;
  }

  /**
   * What's a column's number of digits to right of the decimal point?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return scale
   */
  public int getScale(int column) throws SQLException {	
    return frs.fStmt.col[column-1].iUnits2;
  }

  /**
   * What's a column's table name? 
   *
   * @return table name or "" if not applicable
   */
  public String getTableName(int column) throws SQLException {
    return ""; //todo get from server?
  }

  /**
   * What's a column's table's catalog name?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return column name or "" if not applicable.
   */
  public String getCatalogName(int column) throws SQLException {
    return ""; //todo get from server?
  }

  /**
   * What's a column's SQL type?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return SQL type
   * @see Types
   */
  public int getColumnType(int column) throws SQLException {
    return frs.fStmt.col[column-1].iFldType; //todo double-check no mapping needed
  }

  /**
   * What's a column's data source specific type name?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return type name
   */
  public String getColumnTypeName(int column) throws SQLException {
    switch (frs.fStmt.col[column-1].iFldType) {
      case Global.SQL_INTEGER: return "integer"; //break
      case Global.SQL_SMALLINT: return "smallint"; //break
      
      case Global.SQL_FLOAT: return "float"; //break
      
      case Global.SQL_NUMERIC: return "numeric"; //break
      case Global.SQL_DECIMAL: return "decimal"; //break
      
      case Global.SQL_CHAR: return "character"; //break
      case Global.SQL_VARCHAR: return "character varying"; //break
      
      case Global.SQL_TYPE_DATE: return "date"; //break 
      case Global.SQL_TYPE_TIME: return "time";  //break
      case Global.SQL_TYPE_TIMESTAMP: return "timestamp"; //break  
      
      case Global.SQL_LONGVARCHAR: return "character large object"; //break
      case Global.SQL_LONGVARBINARY: return "binary large object"; //break
      
     default: return "unknown";
    };
  }

  /**
   * Is a column definitely not writable?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isReadOnly(int column) throws SQLException {
    return false;
  }

  /**
   * Is it possible for a write on the column to succeed?
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isWritable(int column) throws SQLException {
    return true;
  }

  /**
   * Will a write on the column definitely succeed?	
   *
   * @param column the first column is 1, the second is 2, ...
   * @return true if so
   */
  public boolean isDefinitelyWritable(int column) throws SQLException {
    return false;
  }
  
  public String getColumnClassName(int column)
                          throws SQLException{
    switch (frs.fStmt.col[column-1].iFldType) {
      case Global.SQL_INTEGER: return "java.lang.Integer"; //break
      case Global.SQL_SMALLINT: return "java.lang.Short"; //break
      
      case Global.SQL_FLOAT: return "java.lang.Double"; //break
      
      case Global.SQL_NUMERIC: return "java.math.BigDecimal"; //break
      case Global.SQL_DECIMAL: return "java.math.BigDecimal"; //break
      
      case Global.SQL_CHAR: return "java.lang.String"; //break
      case Global.SQL_VARCHAR: return "java.lang.String"; //break
      
      case Global.SQL_TYPE_DATE: return "java.sql.Date"; //break 
      case Global.SQL_TYPE_TIME: return "java.sql.Time";  //break
      case Global.SQL_TYPE_TIMESTAMP: return "java.sql.Timestamp"; //break  
      
      //todo case Global.SQL_LONGVARCHAR: return "java.sql.Clob"; //break
      //todo case Global.SQL_LONGVARBINARY: return "java.sql.Blob"; //break
      case Global.SQL_LONGVARCHAR: return "java.lang.String"; //break
      case Global.SQL_LONGVARBINARY: return "java.lang.String"; //break
      
     default: throw new SQLException (Global.seInvalidConversionText,Global.ssNA,Global.seInvalidConversion); //todo assertion!    
    };
  }                      


};


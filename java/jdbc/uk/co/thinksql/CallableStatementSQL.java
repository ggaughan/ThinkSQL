package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import java.sql.*;
import java.math.*;
//import java.io.Reader;
//import java.util.Calendar;

import uk.co.thinksql.ConnectionSQL.*;
import uk.co.thinksql.PreparedStatementSQL.*;

/**
 * <P>CallableStatement is used to execute SQL stored procedures.
 *
 * <P>JDBC provides a stored procedure SQL escape that allows stored
 * procedures to be called in a standard way for all RDBMS's. This
 * escape syntax has one form that includes a result parameter and one
 * that does not. If used, the result parameter must be registered as
 * an OUT parameter. The other parameters may be used for input,
 * output or both. Parameters are refered to sequentially, by
 * number. The first parameter is 1.
 *
 * <P><CODE>
 * {?= call <procedure-name>[<arg1>,<arg2>, ...]}<BR>
 * {call <procedure-name>[<arg1>,<arg2>, ...]}
 * </CODE>
 *    
 * <P>IN parameter values are set using the set methods inherited from
 * PreparedStatement. The type of all OUT parameters must be
 * registered prior to executing the stored procedure; their values
 * are retrieved after execution via the get methods provided here.
 *
 * <P>A Callable statement may return a ResultSet or multiple
 * ResultSets. Multiple ResultSets are handled using operations
 * inherited from Statement.
 *
 * <P>For maximum portability, a call's ResultSets and update counts
 * should be processed prior to getting the values of output
 * parameters.
 *
 * @see Connection#prepareCall
 * @see ResultSet 
 */
 
public class CallableStatementSQL extends PreparedStatementSQL implements java.sql.CallableStatement {

  	public CallableStatementSQL(ConnectionSQL connection, String sql) throws SQLException {
  	  super(connection,sql);
    }
    
    /**
     * Before executing a stored procedure call, you must explicitly
     * call registerOutParameter to register the java.sql.Type of each
     * out parameter.
     *
     * <P><B>Note:</B> When reading the value of an out parameter, you
     * must use the getXXX method whose Java type XXX corresponds to the
     * parameter's registered SQL type.
     *
     * @param parameterIndex the first parameter is 1, the second is 2,...
     * @param sqlType SQL type code defined by java.sql.Types;
     * for parameters of type Numeric or Decimal use the version of
     * registerOutParameter that accepts a scale value
     * @see Type 
     */
    public void registerOutParameter(int parameterIndex, int sqlType)
    throws SQLException {
    }

    /**
     * Use this version of registerOutParameter for registering
     * Numeric or Decimal out parameters.
     *
     * <P><B>Note:</B> When reading the value of an out parameter, you
     * must use the getXXX method whose Java type XXX corresponds to the
     * parameter's registered SQL type.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param sqlType use either java.sql.Type.NUMERIC or java.sql.Type.DECIMAL
     * @param scale a value greater than or equal to zero representing the 
     *              desired number of digits to the right of the decimal point
     * @see Type 
     */
    public void registerOutParameter(int parameterIndex, int sqlType, int scale)
    throws SQLException {
    }

    /**
     * An OUT parameter may have the value of SQL NULL; wasNull reports 
     * whether the last value read has this special value.
     *
     * <P><B>Note:</B> You must first call getXXX on a parameter to
     * read its value and then call wasNull() to see if the value was
     * SQL NULL.
     *
     * @return true if the last parameter read was SQL NULL 
     */
    public boolean wasNull() throws SQLException {
      return false;
    }

    /**
     * Get the value of a CHAR, VARCHAR, or LONGVARCHAR parameter as a Java String.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public String getString(int parameterIndex) throws SQLException {
      return null;
    }

    /**
     * Get the value of a BIT parameter as a Java boolean.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is false
     */
    public boolean getBoolean(int parameterIndex) throws SQLException {
      return false;
    }

    /**
     * Get the value of a TINYINT parameter as a Java byte.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public byte getByte(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of a SMALLINT parameter as a Java short.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public short getShort(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of an INTEGER parameter as a Java int.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public int getInt(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of a BIGINT parameter as a Java long.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public long getLong(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of a FLOAT parameter as a Java float.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public float getFloat(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of a DOUBLE parameter as a Java double.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is 0
     */
    public double getDouble(int parameterIndex) throws SQLException {
      return 0;
    }

    /**
     * Get the value of a NUMERIC parameter as a java.math.BigDecimal object.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param scale a value greater than or equal to zero representing the 
     *              desired number of digits to the right of the decimal point
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public java.math.BigDecimal getBigDecimal(int parameterIndex, int scale)
    throws SQLException {
      return null;
    }

    /**
     * Get the value of a SQL BINARY or VARBINARY parameter as a Java byte[]
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public byte[] getBytes(int parameterIndex) throws SQLException {
      return null;
    }

    /**
     * Get the value of a SQL DATE parameter as a java.sql.Date object
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public java.sql.Date getDate(int parameterIndex) throws SQLException {
      return null;
    }

    /**
     * Get the value of a SQL TIME parameter as a java.sql.Time object.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public java.sql.Time getTime(int parameterIndex) throws SQLException {
      return null;
    }

    /**
     * Get the value of a SQL TIMESTAMP parameter as a java.sql.Timestamp object.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @return the parameter value; if the value is SQL NULL, the result is null
     */
    public java.sql.Timestamp getTimestamp(int parameterIndex)
    throws SQLException {
      return null;
    }

    //----------------------------------------------------------------------
    // Advanced features:


    /**
     * Get the value of a parameter as a Java object.
     *
     * <p>This method returns a Java object whose type coresponds to the SQL
     * type that was registered for this parameter using registerOutParameter.
     *
     * <p>Note that this method may be used to read
     * datatabase-specific, abstract data types. This is done by
     * specifying a targetSqlType of java.sql.types.OTHER, which
     * allows the driver to return a database-specific Java type.
     *
     * @param parameterIndex The first parameter is 1, the second is 2, ...
     * @return A java.lang.Object holding the OUT parameter value.
     * @see Types 
     */
    public Object getObject(int parameterIndex) throws SQLException {
      return null;
    }

    public Array getArray(int i) throws SQLException
    {
      return null;
    }

    public java.math.BigDecimal getBigDecimal(int i) throws SQLException
    {
      return null;
    }

    public Blob getBlob(int i) throws SQLException
    {
      return null;
    }

    public Clob getClob(int i) throws SQLException
    {
      return null;
    }

    public Object getObject(int i,java.util.Map map) throws SQLException
    {
      return null;
    }

    public Ref getRef(int i) throws SQLException
    {
      return null;
    }

    public java.sql.Date getDate(int i,java.util.Calendar cal) throws SQLException
    {
      return null;
    }

    public Time getTime(int i,java.util.Calendar cal) throws SQLException
    {
      return null;
    }

    public Timestamp getTimestamp(int i,java.util.Calendar cal) throws SQLException
    {
      return null;
    }

    public void registerOutParameter(int parameterIndex, int sqlType,String typeName) throws SQLException
    {
    }


};


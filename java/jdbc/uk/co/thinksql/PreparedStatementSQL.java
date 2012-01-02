package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import java.sql.*;
//import java.io.Reader;
//import java.util.Calendar;

import uk.co.thinksql.ConnectionSQL.*;
import uk.co.thinksql.StatementSQL.*;

/**
 * <P>A SQL statement is pre-compiled and stored in a
 * PreparedStatement object. This object can then be used to
 * efficiently execute this statement multiple times. 
 *
 * <P><B>Note:</B> The setXXX methods for setting IN parameter values
 * must specify types that are compatible with the defined SQL type of
 * the input parameter. For instance, if the IN parameter has SQL type
 * Integer then setInt should be used.
 *
 * <p>If arbitrary parameter type conversions are required then the
 * setObject method should be used with a target SQL type.
 *
 * @see Connection#prepareStatement
 * @see ResultSet 
 */

public class PreparedStatementSQL extends StatementSQL implements java.sql.PreparedStatement 
{
	
  	public PreparedStatementSQL(ConnectionSQL connection, String sql) throws SQLException {
  	  super(connection);
      super.prepared=true; //used for server resource deallocation after 1st call to closeCursor
  	  super.doPrepare(sql);
    }

    /**
     * A prepared SQL query is executed and its ResultSet is returned.
     *
     * @return a ResultSet that contains the data produced by the
     * query; never null
     */
    public ResultSet executeQuery() throws SQLException {
      //try {
        if (super.fResultSet!=null) {
          super.fResultSet.close(); //close any previous resultSet before creating a new one //todo any need? automatic on resultSet.close?
          super.fResultSet=null;
        }

        //todo remove doPrepare(sql);       
        //todo assert prepared
        super.doExecute();
        //todo check resultSet, else exception!?
        return super.getResultSet();
      //}
      //catch (SQLException e) {
      //  throw new SQLException ();
      //}
    }

    /**
     * Execute a SQL INSERT, UPDATE or DELETE statement. In addition,
     * SQL statements that return nothing such as SQL DDL statements
     * can be executed.
     *
     * @return either the row count for INSERT, UPDATE or DELETE; or 0
     * for SQL statements that return nothing
     */
    public int executeUpdate() throws SQLException {
      //try {
        if (super.fResultSet!=null) {
          super.fResultSet.close(); //close any previous resultSet before creating a new one //todo: we could allow update/insert/deletes & keep one open resultSet... //todo any need? automatic on resultSet.close?
          super.fResultSet=null;
        }
        
        //todo remove doPrepare(sql);       
        //todo assert prepared
        super.doExecute();
        //todo check !resultSet, else exception!?
        return super.getUpdateCount();
      //}
      //catch (SQLException e) {
      //  throw new SQLException ();
      //}
    }

    /**
     * Set a parameter to SQL NULL.
     *
     * <P><B>Note:</B> You must specify the parameter's SQL type.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param sqlType SQL type code defined by java.sql.Types
     */
    public void setNull(int parameterIndex, int sqlType) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        super.param[parameterIndex-1].isNull=true;
        GlobalUtil.logError("setNull");
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java boolean value.  The driver converts this
     * to a SQL BIT value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setBoolean(int parameterIndex, boolean x) throws SQLException {
    }

    /**
     * Set a parameter to a Java byte value.  The driver converts this
     * to a SQL TINYINT value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setByte(int parameterIndex, byte x) throws SQLException {
    }

    /**
     * Set a parameter to a Java short value.  The driver converts this
     * to a SQL SMALLINT value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setShort(int parameterIndex, short x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=Integer.toString(x)+'\0';
        GlobalUtil.logError("setShort working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java int value.  The driver converts this
     * to a SQL INTEGER value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setInt(int parameterIndex, int x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=Integer.toString(x)+'\0';
        GlobalUtil.logError("setInt working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java long value.  The driver converts this
     * to a SQL BIGINT value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setLong(int parameterIndex, long x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=Long.toString(x)+'\0';
        GlobalUtil.logError("setLong working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java float value.  The driver converts this
     * to a SQL FLOAT value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setFloat(int parameterIndex, float x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=Double.toString(x)+'\0';
        GlobalUtil.logError("setFloat working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java double value.  The driver converts this
     * to a SQL DOUBLE value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setDouble(int parameterIndex, double x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=Double.toString(x)+'\0';
        GlobalUtil.logError("setDouble working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a java.lang.BigDecimal value.  The driver converts
     * this to a SQL NUMERIC value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setBigDecimal(int parameterIndex, java.math.BigDecimal x)
    throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=x.toString()+'\0';
        GlobalUtil.logError("setBigDecimal working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java String value.  The driver converts this
     * to a SQL VARCHAR or LONGVARCHAR value (depending on the arguments
     * size relative to the driver's limits on VARCHARs) when it sends
     * it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setString(int parameterIndex, String x) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=x+'\0';
          /* todo move to rest of setX
          fldINT32:   s:=intToStr(integer(pBuffer^));
          fldFLOAT:   s:=floatToStr(double(pBuffer^));
          fldBCD:     s:=bcdToStr(Tbcd(pBuffer^));
          fldDATETIME:s:=SQLTimSt.SQLTimeStampToStr(DATE_FORMAT+' hh:nn:ss.zzz',SQLTimSt.TSQLTimeStamp(pBuffer^)); //todo in future convert to native timestamp & use native toStr routines
          fldDATE:    s:=FormatDateTime(DATE_FORMAT,TDateTime(pBuffer^));
          fldTIME:    s:=FormatDateTime('hh:nn:ss.zzz',TDateTime(pBuffer^));
          */
        GlobalUtil.logError("setString working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a Java array of bytes.  The driver converts
     * this to a SQL VARBINARY or LONGVARBINARY (depending on the
     * argument's size relative to the driver's limits on VARBINARYs)
     * when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value 
     */
    public void setBytes(int parameterIndex, byte x[]) throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        super.param[parameterIndex-1].isNull=false;
        String s=new String(x)+'\0';
          /* todo move to rest of setX
          fldINT32:   s:=intToStr(integer(pBuffer^));
          fldFLOAT:   s:=floatToStr(double(pBuffer^));
          fldBCD:     s:=bcdToStr(Tbcd(pBuffer^));
          fldDATETIME:s:=SQLTimSt.SQLTimeStampToStr(DATE_FORMAT+' hh:nn:ss.zzz',SQLTimSt.TSQLTimeStamp(pBuffer^)); //todo in future convert to native timestamp & use native toStr routines
          fldDATE:    s:=FormatDateTime(DATE_FORMAT,TDateTime(pBuffer^));
          fldTIME:    s:=FormatDateTime('hh:nn:ss.zzz',TDateTime(pBuffer^));
          */
        GlobalUtil.logError("setString working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a java.sql.Date value.  The driver converts this
     * to a SQL DATE value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setDate(int parameterIndex, java.sql.Date x)
    throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=x.toString()+'\0';
        GlobalUtil.logError("setDate working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a java.sql.Time value.  The driver converts this
     * to a SQL TIME value when it sends it to the database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value
     */
    public void setTime(int parameterIndex, java.sql.Time x) 
    throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=x.toString()+'\0';
        GlobalUtil.logError("setTime working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * Set a parameter to a java.sql.Timestamp value.  The driver
     * converts this to a SQL TIMESTAMP value when it sends it to the
     * database.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the parameter value 
     */
    public void setTimestamp(int parameterIndex, java.sql.Timestamp x)
    throws SQLException {
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }
    
        /*Convert from user type to server parameter type*/
        String s;
        super.param[parameterIndex-1].isNull=false;
        s=x.toString()+'\0';
        GlobalUtil.logError("setTimestamp working with "+s);
        super.param[parameterIndex-1].bufferLen=s.length();
        super.param[parameterIndex-1].buffer=s;   
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
     * When a very large ASCII value is input to a LONGVARCHAR
     * parameter, it may be more practical to send it via a
     * java.io.InputStream. JDBC will read the data from the stream
     * as needed, until it reaches end-of-file.  The JDBC driver will
     * do any necessary conversion from ASCII to the database char format.
     * 
     * <P><B>Note:</B> This stream object can either be a standard
     * Java stream object or your own subclass that implements the
     * standard interface.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the java input stream which contains the ASCII parameter value
     * @param length the number of bytes in the stream 
     */
    public void setAsciiStream(int parameterIndex, java.io.InputStream x,
    int length) throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
    }

    /**
     * When a very large UNICODE value is input to a LONGVARCHAR
     * parameter, it may be more practical to send it via a
     * java.io.InputStream. JDBC will read the data from the stream
     * as needed, until it reaches end-of-file.  The JDBC driver will
     * do any necessary conversion from UNICODE to the database char format.
     * 
     * <P><B>Note:</B> This stream object can either be a standard
     * Java stream object or your own subclass that implements the
     * standard interface.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...  
     * @param x the java input stream which contains the
     * UNICODE parameter value 
     * @param length the number of bytes in the stream 
     */
    public void setUnicodeStream(int parameterIndex, java.io.InputStream x,
    int length) throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
    }

    /**
     * When a very large binary value is input to a LONGVARBINARY
     * parameter, it may be more practical to send it via a
     * java.io.InputStream. JDBC will read the data from the stream
     * as needed, until it reaches end-of-file.
     * 
     * <P><B>Note:</B> This stream object can either be a standard
     * Java stream object or your own subclass that implements the
     * standard interface.
     *
     * @param parameterIndex the first parameter is 1, the second is 2, ...
     * @param x the java input stream which contains the binary parameter value
     * @param length the number of bytes in the stream 
     */
    public void setBinaryStream(int parameterIndex, java.io.InputStream x,
    int length) throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
    }

    /**
     * <P>In general, parameter values remain in force for repeated use of a
     * Statement. Setting a parameter value automatically clears its
     * previous value.  However, in some cases it is useful to immediately
     * release the resources used by the current parameter values; this can
     * be done by calling clearParameters.
     */
    public void clearParameters() throws SQLException {
      for (int i=0; i<paramCount; i++) {param[i].bufferLen=0; param[i].isNull=false;}
    }

    //----------------------------------------------------------------------
    // Advanced features:

    /**
     * <p>Set the value of a parameter using an object; use the
     * java.lang equivalent objects for integral values.
     *
     * <p>The given Java object will be converted to the targetSqlType
     * before being sent to the database.
     *
     * <p>Note that this method may be used to pass datatabase-
     * specific abstract data types. This is done by using a Driver-
     * specific Java type and using a targetSqlType of
     * java.sql.types.OTHER.
     *
     * @param parameterIndex The first parameter is 1, the second is 2, ...
     * @param x The object containing the input parameter value
     * @param targetSqlType The SQL type (as defined in java.sql.Types) to be 
     * sent to the database. The scale argument may further qualify this type.
     * @param scale For java.sql.Types.DECIMAL or java.sql.Types.NUMERIC types
     *          this is the number of digits after the decimal.  For all other
     *          types this value will be ignored,
     * @see Types 
     */
    public void setObject(int parameterIndex, Object x, int targetSqlType,
    int scale) throws SQLException {
      //throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
      if ((parameterIndex-1)<=super.paramCount) {
        /*Free any previous param buffer*/
        if (super.param[parameterIndex-1].buffer!=null) {
          //todo buffer=""?
          super.param[parameterIndex-1].bufferLen=0;
        }

        GlobalUtil.logError("setObject working with "+x);
    
        switch (targetSqlType) {
          case java.sql.Types.INTEGER: { Integer i=(Integer)x; setInt(parameterIndex, i.intValue()); break; }
          case java.sql.Types.SMALLINT: { Short s=(Short)x; setShort(parameterIndex, s.shortValue()); break; }
          
          case java.sql.Types.FLOAT: { Float f=(Float)x; setFloat(parameterIndex, f.floatValue()); break; }
          
          //todo use scale?
          case java.sql.Types.NUMERIC:
          case java.sql.Types.DECIMAL: { setBigDecimal(parameterIndex, (java.math.BigDecimal)x); break; }
          
          case java.sql.Types.CHAR:
          case java.sql.Types.VARCHAR: { setString(parameterIndex, (String)x); break; }
          
          case java.sql.Types.DATE: { setDate(parameterIndex, (Date)x); break; }
          case java.sql.Types.TIME: { setTime(parameterIndex, (Time)x); break; }
          case java.sql.Types.TIMESTAMP: { setTimestamp(parameterIndex, (Timestamp)x); break; }
                       
          //todo set these as java.sql.Clob and Blob:
          case java.sql.Types.LONGVARCHAR: throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);
          case java.sql.Types.LONGVARBINARY: throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);

          default: throw new SQLException (Global.seInvalidConversionText,Global.ssNA,Global.seInvalidConversion); //todo assertion!    
        }       
      }
      else { //todo: should allow user to set more params than server says we have!
        throw new SQLException (Global.seInvalidParameterIndexText,Global.ssNA,Global.seInvalidParameterIndex);     
      }     
    }

    /**
      * This method is like setObject above, but assumes a scale of zero.
      */
    public void setObject(int parameterIndex, Object x, int targetSqlType)
    throws SQLException {
      setObject(parameterIndex,x,targetSqlType,0);
    }

    /**
     * <p>Set the value of a parameter using an object; use the
     * java.lang equivalent objects for integral values.
     *
     * <p>The JDBC specification specifies a standard mapping from
     * Java Object types to SQL types.  The given argument java object
     * will be converted to the corresponding SQL type before being
     * sent to the database.
     *
     * <p>Note that this method may be used to pass datatabase
     * specific abstract data types, by using a Driver specific Java
     * type.
     *
     * @param parameterIndex The first parameter is 1, the second is 2, ...
     * @param x The object containing the input parameter value 
     */
    public void setObject(int parameterIndex, Object x) throws SQLException {
      setObject(parameterIndex,x.toString(),java.sql.Types.VARCHAR); //todo ok?
    }

    /**
     * Some prepared statements return multiple results; the execute
     * method handles these complex statements as well as the simpler
     * form of statements handled by executeQuery and executeUpdate.
     *
     * @see Statement#execute
     */
    public boolean execute() throws SQLException {
      //try {
        if (super.fResultSet!=null) {
          super.fResultSet.close(); //close any previous resultSet before creating a new one //todo: we could allow update/insert/deletes & keep one open resultSet... //todo any need? automatic on resultSet.close?
          super.fResultSet=null;
        }

        /* todo remove old?
        if (fResultSet!=null) {
          close(); //close any previous resultSet before creating a new one //todo: we could allow update/insert/deletes & keep one open resultSet... //todo any need? automatic on resultSet.close?
        }
        */
        
        super.doExecute();
        
        return super.resultSet; //true or false
      //}
      //catch (SQLException e) {
      //  throw new SQLException ();
      //}          
    }
    
public void addBatch()
              throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public void setCharacterStream(int parameterIndex,
                               java.io.Reader reader,
                               int length)
                        throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public void setRef(int i,
                   Ref x)
            throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}
     
public void setBlob(int i,
                    Blob x)
             throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}    
    
public void setClob(int i,
                    Clob x)
             throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}    

public void setArray(int i,
                     Array x)
              throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public ResultSetMetaData getMetaData()
                              throws SQLException {
  return super.fResultSet.getMetaData();
}

public void setDate(int parameterIndex,
                    Date x,
                    java.util.Calendar cal)
             throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public void setTime(int parameterIndex,
                    Time x,
                    java.util.Calendar cal)
             throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public void setTimestamp(int parameterIndex,
                         Timestamp x,
                         java.util.Calendar cal)
                  throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}

public void setNull(int paramIndex,
                    int sqlType,
                    String typeName)
             throws SQLException {
      throw new SQLException (Global.seNotImplementedYetText,Global.ssHYC00,Global.seNotImplementedYet);     
}



};


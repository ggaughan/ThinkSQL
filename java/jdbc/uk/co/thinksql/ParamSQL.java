package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

/*
  Parameter definition

*/


public class ParamSQL {
  //   desc:SPParamDesc;
  public int iParamNum;
  public String colName;
  public short iDataType;
  public short iArgType;
  public int iUnits1;
  public short iUnits2;
  //todo n/a  public short iNullOffset;    
  
  public String buffer;
  public int bufferLen;
  public boolean isNull;

  /* todo remove 
  public int iFldNum;
  public short iFldType;
  //todo iSubType
  public short iUnits1;
  public short iUnits2;
  public short iNullOffset;    
  
  public String colName;
  //todo! public byte[] data;
  public String data;
  */
}

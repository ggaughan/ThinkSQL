package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

/*
  Column definition

*/


public class ColumnSQL {
  public int iFldNum;
  public short iFldType;
  //todo iSubType
  public int iUnits1;
  public short iUnits2;
  public short iNullOffset;    
  
  public String colName;
  //todo! public byte[] data;
  public byte[] data;

}

package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

public interface Global
{
  boolean debug=false; //logError to trace = false when live
  
  short clientCLIversion  =100;  //client parameter passing version
  /*                      0092   last used 00.04.09 beta (Server 00.04.09) - now pass bufferLen in SQLgetData for blob chunking & widths as integer and handshake sends extra
                          0091   last used 00.04.02 beta (Server 00.04.04) - now pass stored procedure result sets
  */

  short CLI_ODBC=1;
  short CLI_JDBC=2;
  short CLI_DBEXPRESS=3;
  short CLI_ADO_NET=4;
  
  
  //Constants //todo prefix with static? speed
  String DriverName="ThinkSQLDriver";
  String DriverVersion="1.04.00";
  int DriverMajorVersion=1;
  int DriverMinorVersion=04;
  
  int ok=0;
  int fail=-1;
  String failString="";
  byte[] failNull=null;


  int stateClosed=0, stateOpen=1;

  short sizeof_short=2;
  short sizeof_int=4;
  short sizeof_long=8;
  short sizeof_float=4;
  short sizeof_double=8;
  short sizeof_byte=8; //in bits!
  
  short sizeof_date=4;
    short sizeof_dateY=2;
    short sizeof_dateM=1;
    short sizeof_dateD=1;
    
  short sizeof_time=7;
    short sizeof_timeH=1;
    short sizeof_timeM=1;
    short sizeof_timeS=4;     //Note: stored normalised as SSFFFFFF where number of Fs=TIME_MAX_SCALE
    short sizeof_timeSc=1;    //Note: used when formatting to dictate how many fractional places to display

  short TIME_MAX_SCALE=6; //todo increase to whatever time.seconds can hold, i.e. 9  Note: must adjust sqlTimeToStr 0 padding to suit!

  
  int MAX_COL_PER_TABLE=300;
  int MAX_PARAM_PER_QUERY=300;
  
  int SQL_FALSE                                   =0;
  int SQL_TRUE                                    =1; 
  
  //parameter types
  short ptInput = 0; //todo sync. with dbExpress!
  short ptOutput = 1; //todo "
  
  String EscapeChar="\\";
  
  int SQL_ERROR=-1;
  int SQL_ERROR2=SQL_ERROR;
  int SQL_SUCCESS=0;
  int SQL_SUCCESS_WITH_INFO=1;
  int SQL_STILL_EXECUTING=2;
  int SQL_NEED_DATA=99;
  int SQL_NO_DATA=100;
  
  
  short SQL_CHAR                                    =1;
  short SQL_NUMERIC                                 =2;
  short SQL_DECIMAL                                 =3;
  short SQL_INTEGER                                 =4;
  short SQL_SMALLINT                                =5;
  short SQL_FLOAT                                   =6;
  short SQL_REAL                                    =7;
  short SQL_DOUBLE                                  =8;
  short SQL_DATETIME                                =9;
  short SQL_INTERVAL                               =10;
  short SQL_VARCHAR                                =12;
  
  short SQL_TYPE_DATE                              =91;
  short SQL_TYPE_TIME                              =92;
  short SQL_TYPE_TIMESTAMP                         =93;

  short SQL_LONGVARCHAR                            =-1;
  //short SQL_BINARY         =-2;				
  //short SQL_VARBINARY      =-3;			
  short SQL_LONGVARBINARY                          =-4;
  //future use: short SQL_BIGINT         =-5;				
    
  
  short SQL_API_SQLCONNECT                          =7;
  short SQL_API_SQLDISCONNECT                       =9;
  short SQL_API_SQLEXECUTE                          =12;
  short SQL_API_SQLPREPARE                          =19;
  short SQL_API_SQLGETDATA                          =43;
  short SQL_API_SQLGETINFO                          =45;

  short SQL_API_SQLALLOCHANDLE                      =1001;
  short SQL_API_SQLCLOSECURSOR                      =1003;
  short SQL_API_SQLENDTRAN                          =1005; 
  short SQL_API_SQLFREEHANDLE                       =1006;
  short SQL_API_SQLFETCHSCROLL                      =1021;
  
  
  short SQL_API_handshake  =9999;
  
  short SQL_HANDLE_STMT                             =3; 

  short SQL_ROLLBACK=1;
  short SQL_COMMIT=0;
  
  short SQL_FETCH_NEXT                              =1;
  
  short SQL_DBMS_NAME                              =17;  //Greg: was missing
  short SQL_DBMS_VERSION                           =18;
  
  
  //Errors: keep in synch with uMarshalGlobal.pas
  int seNotImplementedYet=500;   String seNotImplementedYetText="Not implemented yet";
  int seHandshakeFailed=1500;    String seHandshakeFailedText="Handshake failed";
  int seConnectionFailed=1502;   String seConnectionFailedText="Communication link failure";
  
  //Java only? Renumber...
  int seInvalidColumnIndex=1600; String seInvalidColumnIndexText="Invalid column index";
  int seInvalidConversion=1602;  String seInvalidConversionText="Invalid data conversion";
  int seInvalidParameterIndex=1604; String seInvalidParameterIndexText="Invalid parameter index";
  
  
  String ss08001="08001";
  String ss08S01="08S01";
  String ss42000="42000";
  String ssHY000="HY000";
  String ssHY010="HT010";
  String ssHYC00="HYC00"; //optional feature not implemented yet
  
  String ssNA="NA"; //todo: replace references!
  
  
}

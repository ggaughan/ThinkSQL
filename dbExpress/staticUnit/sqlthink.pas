{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Link dbExpress driver units into one big unit (dcu)
 to allow static linking into Delphi applications with no extra files needed,
 e.g.
   uses sqlthink, crtl, midaslib

 (Assumes Indy IdTCPClient and IdTCPConnection etc. are available to user for linking)

 Note: includes each dbExpress sub-unit twice, and flips compiler switches to include interface
       or implementation sections as needed. This way we can share the same code as
       the dbExpress DLL/so.
}

unit sqlthink;

interface

{$DEFINE DBEXP_STATIC}

{$DEFINE DBEXP_INTERFACE}

uses
   DBXpress, //uGlobalDB, uMainDB
   IdTCPClient, //uSQLConnection
   IdTCPConnection //uMarshal
  ;
  {$INCLUDE uMarshalGlobal}
  {$INCLUDE uMarshal}
  {$INCLUDE uGlobalDB}
  {$INCLUDE uLog}
  {$INCLUDE uMainDB}    //not necessary here?
  {$INCLUDE uSQLDriver}
  {$INCLUDE uSQLConnection}
  {$INCLUDE uSQLCommand}
  {$INCLUDE uSQLCursor}
  {$INCLUDE uSQLMetadata}

{$UNDEF DBEXP_INTERFACE}

implementation

{$DEFINE DBEXP_IMPLEMENTATION}

uses SysUtils, {uLog} //uGlobalDB
     {$IFDEF SHOW_LOG}
     ,QDialogs //uLog
     {$ENDIF}
     {,uSQLDriver} //uMainDB
     DB {for TFieldType}, {uSQLCursor,} SQLTimSt,FmtBCD, //uSQLCommand
     Math{for power}, //uSQLCursor
     SQLExpr //for RegisterDbXpressLib
  ;
  {$INCLUDE uMarshalGlobal}
  {$INCLUDE uMarshal}
  {$INCLUDE uGlobalDB}
  {$INCLUDE uLog}               //note: initialization/finalization not linked here!
  {$INCLUDE uMainDB}
  {$INCLUDE uSQLDriver}
  {$INCLUDE uSQLConnection}
  {$INCLUDE uSQLCommand}
  {$INCLUDE uSQLCursor}
  {$INCLUDE uSQLMetadata}

{$UNDEF DBEXP_IMPLEMENTATION}

initialization
  {Set the decimal separator to be as per the standard (i.e. a dot) rather than whatever the locale default might be}
  DecimalSeparator:='.';        //uMarshalGlobal.initialization

  {Reister our getSQLdriver routine}
  RegisterDbXpressLib(@getSQLDriverTHINKSQL);

end.


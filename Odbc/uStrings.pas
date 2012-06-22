unit uStrings;

{Standard text
 //todo use a dll or resource file for these? international
}

interface

uses uDiagnostic;

const
  state01='01';   text01='warning-';
  state07='07';   text07='dynamic SQL error-';
  state08='08';   text08='connection exception-';
  state21='21';   text21='todo';
  state22='22';   text22='data exception-';
  state24='24';
  state25='25';
  state37='37';
  state42='42';   text42='syntax error or access rule violation'; //Note no ending -
  stateHY='HY';   textHY='CLI-specific condition-';
  stateS0='S0';
  stateS1='S1';


  //todo remove constant duplication - put into code...
  ssStateText:array [ssFirst..ssLast] of TsqlStateText=(
   ''{first},

   state01+'002',
   state01+'004',
   state01+'S00',
   state01+'S02',
   state01+'S07',

   state07+'005',
   state07+'006',
   state07+'009',

   state08+'001',
   state08+'002',
   state08+'003',
   state08+'004',
   state08+'S01',

   state21+'S01',

   state22+'002',
   state22+'003',
   state22+'012',
   state22+'018',

   state24+'000',

   state25+'000',

   state42+'000',
   state42+'S01',
   state42+'S02',
   state42+'S22',

   stateHY+'000',
   stateHY+'003',
   stateHY+'004',
   stateHY+'010',
   stateHY+'011',
   stateHY+'016',
   stateHY+'024',
   stateHY+'090',
   stateHY+'091',
   stateHY+'092',
   stateHY+'096',
   stateHY+'097',
   stateHY+'098',
   stateHY+'099',
   stateHY+'106',
   stateHY+'C00',
   stateHY+'T00',
   stateHY+'T01',

   '', //NA, i.e. server responds with invalid handle
   'TODO!',
   ''{last}
  );

  //Now we duplicate the above for the ODBC v2 state codes //todo keep in sync!
  ssStateTextODBC2:array [ssFirst..ssLast] of TsqlStateText=(
   ''{first},

   state01+'002',
   state01+'004',
   state01+'S00',
   state01+'S02',
   state01+'S07',

   state24+'000',  //state07+'005',
   state07+'006',
   stateS1+'002',  //state07+'009',    //todo only in some routines

   state08+'001',
   state08+'002',
   state08+'003',
   state08+'004',
   state08+'S01',

   state21+'S01',

   state22+'002',
   state22+'003',
   state22+'012',
   state22+'005',  //state22+'018',

   state24+'000',

   state25+'000',

   state37+'000',  //state42+'000',
   stateS0+'001',  //state42+'S01',
   stateS0+'002',  //state42+'S02',
   stateS0+'022',  //state42+'S22',

   stateS1+'000',  //stateHY+'000',
   stateS1+'003',  //stateHY+'003',
   stateS1+'004',  //stateHY+'004',
   stateS1+'010',  //stateHY+'010',
   stateS1+'011',  //stateHY+'011',
   stateHY+'016',
   stateS1+'009',  //stateHY+'024',
   stateHY+'090',  //stateHY+'090',
   stateS1+'091',  //stateHY+'091',
   stateS1+'009',  //stateHY+'092',
   stateS1+'096',  //stateHY+'096',
   stateS1+'097',  //stateHY+'097',
   stateS1+'098',  //stateHY+'098',
   stateS1+'099',  //stateHY+'099',
   stateS1+'106',  //stateHY+'106',
   stateS1+'C00',  //stateHY+'C00',
   stateS1+'T00',  //stateHY+'T00',
   stateHY+'T01',

   '',  //NA, i.e. server responds with invalid handle
   'TODO!',
   ''{last}
  );


  //todo remove (large!) constant duplication (or does Delphi do it for us?) - put into code...
  ssErrText:array [ssFirst..ssLast] of string=(
   ''{first},

   text01{002}+'disconnect error',
   text01{004}+'string data, right truncation',
   text01{S00}+'invalid connection string attribute',
   text01{S02}+'option value changed',
   text01{S07}+'fractional truncation',

   text07{005}+'prepared statement not a cursor-specification',
   text07{006}+'restricted data type attribute violation',
   text07{009}+'invalid descriptor index',

   text08{001}+'SQL-client unable to establish SQL-connection',
   text08{002}+'connection name in use',
   text08{003}+'connection does not exist',
   text08{004}+'SQL-server rejected establishment of SQL-connection',
   text08{S01}+'communication link failure',

   text21{S01}+'degree of derived table does not match column list', //todo

   text22{002}+'null value, no indicator parameter',
   text22{003}+'numeric value out of range',
   text22{012}+'division by zero',
   text22{018}+'data is not a numeric literal TODO!',

   {24000}'invalid cursor state',
   {25000}'invalid transaction state',

   text42{000},
   text42{S01}+'-base table or view already exists',
   text42{S02}+'-base table or view not found', //todo
   text42{S22}+'-column not found', //todo

   textHY{000}+'general error', //todo
   textHY{003}+'invalid data type in application descriptor',
   textHY{004}+'invalid data type',
   textHY{010}+'function sequence error',
   textHY{011}+'attribute cannot be set now',
   textHY{016}+'cannot modify an implementation row descriptor',
   textHY{024}+'invalid attribute value',
   textHY{090}+'invalid string length or buffer length',
   textHY{091}+'invalid descriptor field identifier',
   textHY{092}+'invalid attribute/option identifier',
   textHY{096}+'invalid information type',
   textHY{097}+'column type out of range',
   textHY{098}+'scope type out of range',
   textHY{099}+'nullable type out of range',
   textHY{106}+'invalid fetch orientation',
   textHY{C00}+'optional feature not implemented',
   textHY{T00}+'timeout expired',
   textHY{T01}+'connection timeout expired',

   '',    //NA, i.e. server responds with invalid handle
   'TODO!'{retain until no more ssTODOs},
   ''{last}
  );

{Non-ODBC strings for general client errors}
  ceFailedClosingCursor='Failed closing cursor';


implementation

end.

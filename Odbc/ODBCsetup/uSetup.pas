unit uSetup;

interface

uses windows{for BOOL};

//todo!!!!!! include odbc.inc!
const
  ODBC_INSTALLER_DLL='odbccp32.dll';

type
  pUCHAR=pchar;


function ConfigDSN (hwndParent:HWND;
                    fRequest:WORD;
                    lpszDriver:pUCHAR;
                    lpszAttributes:pUCHAR):BOOL;
                    stdcall;

implementation

uses dialogs, sysUtils, controls{for mrok}, fmSetupDSN;

function SQLWriteDSNToIni (lpszDSN:pUCHAR;
                           lpszDriver:pUCHAR):BOOL; stdcall; external ODBC_INSTALLER_DLL;
function SQLRemoveDSNFromIni (lpszDSN:pUCHAR):BOOL; stdcall; external ODBC_INSTALLER_DLL;
function SQLWritePrivateProfileString(lpszSection:pUCHAR;
                                      lpszEntry:pUCHAR;
                                      lpszString:pUCHAR;
                                      lpszFilename:pUCHAR):BOOL; stdcall; external ODBC_INSTALLER_DLL;
function SQLGetPrivateProfileString(lpszSection:pUCHAR;
                                    lpszEntry:pUCHAR;
                                    lpszDefault:pUCHAR;
                                    RetBuffer:pUCHAR;
                                    cbRetBuffer:INTEGER;
                                    lpszFilename:pUCHAR):INTEGER; stdcall; external ODBC_INSTALLER_DLL;

const
  ODBC_ADD_DSN     =1;               // Add data source
  ODBC_CONFIG_DSN  =2;               // Configure (edit) data source
  ODBC_REMOVE_DSN  =3;               // Remove data source


{***************** Installation routines **************************************}
//todo: use odbcinst.h instead of hardcoding here...


//todo: copied from odbc driver - share same code!
function parseNextKeywordValuePair(var kvps:string;var keyword:string;var value:string):boolean;
{Parses a keyword-value pair string to get the next pair
 IN:      kvps          the un-parsed keyword-value pair string
 OUT:     kvps          the remaining un-parsed keyword-value pair string
          keyword       the keyword of the next pair
          value         the value of the next pair
 RESULT:  true = next pair was available
          false = end - nothing more to parse

 Note:
   missing pairs are skipped, e.g. ';;A=B' will return the pair A,B - the empty pair is ignored
   an incomplete pair is not returned, e.g. 'A;C=D' will return the pair C,D - A is ignored
}
const
  ASSIGNMENT='=';
  SEPARATOR=';';
var
  gettingKeyword:boolean;
begin
  result:=false;
  keyword:='';
  value:='';
  gettingKeyword:=true;
  while kvps<>'' do
  begin
    case kvps[1] of
      ASSIGNMENT:
      begin
        if gettingKeyword then
        begin
          gettingKeyword:=False; //start getting value
        end
        else
        begin
          value:=value+kvps[1]; //part of value
        end;
      end; {ASSIGNMENT}
      SEPARATOR:
      begin
        if gettingKeyword then
        begin
          keyword:=''; //reset - end of partial/empty pair - skip over and start on next pair //todo log error if keyword was <>''?
        end
        else
        begin
          result:=True;
          kvps:=copy(kvps,2,length(kvps)); //reduce string by 1
          exit; //done!
        end;
      end; {SEPARATOR}
    else
      if gettingKeyword then
      begin
        keyword:=keyword+kvps[1];
      end
      else
      begin
        value:=value+kvps[1];
      end;
    end; {case}
    kvps:=copy(kvps,2,length(kvps)); //reduce string by 1
  end; {while more characters}

  if not gettingKeyword then result:=True; //we read the final pair at the end of the string
end; {parseNextKeywordValuePair}


function ConfigDSN (hwndParent:HWND;
                    fRequest:WORD;
                    lpszDriver:pUCHAR;
                    lpszAttributes:pUCHAR):BOOL;
                    stdcall;
const
  {Keyword value pair constants}
  kvpAssignment='=';
  kvpSeparator=';';

  INIFilename='ODBC.INI';

  kUID='UID';
  kPWD='PWD';
  kDSN='DSN';

  kDRIVER='DRIVER';

  kHOST='HOST';    //address
  kSERVICE='SERVICE'; //port
  kSERVER='SERVER'; //server[.catalog]

  MAX_RETBUF=512;
var
  frmSetupDSN: TfrmSetupDSN;

  kvps:string;
  keyword,value:string;

  tempUID, tempPWD, tempDSN:string;
  tempDRIVER:string;
  tempHOST,tempSERVICE,tempSERVER:string;

  done:boolean;

  retBuf:array [0..MAX_RETBUF-1] of char;
begin
  result:=FALSE;

  //showmessage(format('ConfigDSN: frequest=%d lpszDriver=%s lpszAttributes=%s',[frequest,lpszDriver,lpszAttributes]));

  {Parse the connection string}
  kvps:=lpszAttributes; //todo: ok in all cases?
  tempUID:='';
  tempPWD:='';
  tempDSN:='';
  tempDRIVER:='';
  tempHOST:='';
  tempSERVICE:='';
  tempSERVER:='';
  while parseNextKeywordValuePair(kvps,keyword,value) do
  begin
    keyword:=uppercase(trim(keyword));
    done:=False;

    {match keywords and use the value, unless it's already been specified - i.e. ignore duplicates & use 1st instance
     - todo this doesn't exactly match the spec. since 'UID=;UID=Second' would use Second (but 'UID=First;UID=Second' wouldn't at least)
    }
    if keyword=kUID then begin if tempUID='' then tempUID:=value; done:=true; end;
    if keyword=kPWD then begin if tempPWD='' then tempPWD:=value; done:=true; end;
    if keyword=kDSN then begin if tempDSN='' then tempDSN:=value; done:=true; end;

    if keyword=kDRIVER then begin if tempDRIVER='' then tempDRIVER:=value; done:=true; end;
    //todo more logic for driver/dsn...

    if keyword=kHOST then begin if tempHOST='' then tempHOST:=value; done:=true; end;
    if keyword=kSERVICE then begin if tempSERVICE='' then tempSERVICE:=value; done:=true; end;
    if keyword=kSERVER then begin if tempSERVER='' then tempSERVER:=value; done:=true; end;


    {todo re-instate? - currently just ignore...
    if not done then
    begin
      result:=SQL_SUCCESS_WITH_INFO;
      c.diagnostic.logError(ss01S00,fail,'',0,0); //todo check result
      //try to continue with connect
    end;
    }
  end; {while more pairs}

  case fRequest of
    //todo share code between config/add!
    ODBC_CONFIG_DSN:
    begin
      if hwndParent<>0 then
      begin
        frmSetupDSN:=TfrmSetupDSN.Create(nil);
        try
          {Read DSN parameters}
          if SQLGetPrivateProfileString(pchar(tempDSN),kUID,'DEFAULT',retBuf,sizeof(retBuf),INIfilename)=0 then
            retBuf:='';
          tempUID:=retBuf;
          if SQLGetPrivateProfileString(pchar(tempDSN),kPWD,'DEFAULT',retBuf,sizeof(retBuf),INIfilename)=0 then
            retBuf:='';
          tempPWD:=retBuf;
          if SQLGetPrivateProfileString(pchar(tempDSN),kHOST,'localhost',retBuf,sizeof(retBuf),INIfilename)=0 then
            retBuf:='';
          tempHOST:=retBuf;
          if SQLGetPrivateProfileString(pchar(tempDSN),kSERVICE,'thinksql',retBuf,sizeof(retBuf),INIfilename)=0 then
            retBuf:='';
          tempSERVICE:=retBuf;
          if SQLGetPrivateProfileString(pchar(tempDSN),kSERVER,'thinksql',retBuf,sizeof(retBuf),INIfilename)=0 then
            retBuf:='';
          tempSERVER:=retBuf;

          //todo etc.

          frmSetupDSN.edDSN.text:=tempDSN;
          frmSetupDSN.edUID.text:=tempUID;
          frmSetupDSN.edPWD.text:=tempPWD; //todo encrypted?
          frmSetupDSN.edHOST.text:=tempHOST;
          frmSetupDSN.edSERVICE.text:=tempSERVICE;
          frmSetupDSN.edSERVER.text:=tempSERVER;
          if frmSetupDSN.ShowModal=mrOk then
          begin
            if frmSetupDSN.edDSN.text<>tempDSN then
            begin //changed DSN name, so delete old one & add new one
              //todo check results!!!

              //todo check tempDSN is valid/exists...
              SQLRemoveDSNFromIni(pchar(tempDSN));
              {Remove any existing parameters}
              SQLWritePrivateProfileString(pchar(tempDSN),nil,nil,INIfilename);

              SQLWriteDSNToIni(pchar(frmSetupDSN.edDSN.text),lpszDriver);
            end;

            {Store DSN parameters}
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kUID,pchar(frmSetupDSN.edUID.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kPWD,pchar(frmSetupDSN.edPWD.text),INIfilename); //todo encrypt? (on edit re-write all)
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kHOST,pchar(frmSetupDSN.edHOST.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kSERVICE,pchar(frmSetupDSN.edSERVICE.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kSERVER,pchar(frmSetupDSN.edSERVER.text),INIfilename);
            //todo etc.

            result:=TRUE; //todo ok!?
          end;
        finally
          frmSetupDSN.free;
        end; {try}
      end;
      //todo else non-interactive...
    end; {ODBC_CONFIG_DSN}

    ODBC_ADD_DSN:
    begin
      //todo add form for connect option specification etc.
      if hwndParent<>0 then
      begin //can interact with user via dialog
        frmSetupDSN:=TfrmSetupDSN.Create(nil);
        try
          {Set some defaults for new DSNs}
          //todo ensure these match driver defaults etc.!
          if tempUID='' then tempUID:='DEFAULT'; //todo remove after beta!?
          if tempHOST='' then tempHOST:='localhost';
          if tempSERVICE='' then tempSERVICE:='thinksql';
          if tempSERVER='' then tempSERVER:='thinksql'; //& default catalog=first one to be started on that server

          //todo check if lpszAttributes contains all the info/defaults we need
          //todo if not, read from driver default values
          frmSetupDSN.edDSN.text:=tempDSN;
          frmSetupDSN.edUID.text:=tempUID;
          frmSetupDSN.edPWD.text:=tempPWD;
          frmSetupDSN.edHOST.text:=tempHOST;
          frmSetupDSN.edSERVICE.text:=tempSERVICE;
          frmSetupDSN.edSERVER.text:=tempSERVER;
          if frmSetupDSN.ShowModal=mrOk then
          begin
            result:=SQLWriteDSNToIni(pchar(frmSetupDSN.edDSN.text),lpszDriver);
            {Store DSN parameters}
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kUID,pchar(frmSetupDSN.edUID.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kPWD,pchar(frmSetupDSN.edPWD.text),INIfilename); //todo encrypt!
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kHOST,pchar(frmSetupDSN.edHOST.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kSERVICE,pchar(frmSetupDSN.edSERVICE.text),INIfilename);
            SQLWritePrivateProfileString(pchar(frmSetupDSN.edDSN.text),kSERVER,pchar(frmSetupDSN.edSERVER.text),INIfilename);
            //todo etc.
          end;
        finally
          frmSetupDSN.free;
        end; {try}
      end
      else
      begin //no user interaction
        if (tempDSN<>'') and (tempUID<>'') and (tempHOST<>'') and (tempSERVICE<>'') and (tempSERVER<>'') then
        begin
          result:=SQLWriteDSNToIni(pchar(tempDSN),lpszDriver);
          {Store DSN parameters}
          SQLWritePrivateProfileString(pchar(tempDSN),kUID,pchar(tempUID),INIfilename);
          SQLWritePrivateProfileString(pchar(tempDSN),kPWD,pchar(tempPWD),INIfilename); //todo encrypt!
          SQLWritePrivateProfileString(pchar(tempDSN),kHOST,pchar(tempHOST),INIfilename);
          SQLWritePrivateProfileString(pchar(tempDSN),kSERVICE,pchar(tempSERVICE),INIfilename);
          SQLWritePrivateProfileString(pchar(tempDSN),kSERVER,pchar(tempSERVER),INIfilename);
          //todo etc.
        end;
      end;
    end; {ODBC_ADD_DSN}

    ODBC_REMOVE_DSN:
    begin
      {Note: ODBC administrator program has already asked for confirmation}
      //todo check tempDSN is valid/exists...
      result:=SQLRemoveDSNFromIni(pchar(tempDSN));
    end; {ODBC_REMOVE_DSN}
  else
    //todo assertion
  end; {case}

end; {ConfigDSN}

//todo add configDriver...



end.

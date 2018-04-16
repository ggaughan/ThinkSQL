unit uServer;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Server includes:
   instances of db files in use
   shared memory items across system

   actually links buffer manager and database(s)
   without it, DB(s) would talk directly to BufMgr - better?
}

interface

uses uGlobal, uBuffer, uDatabase, Classes {for TList},
     IdTCPConnection{debug only}, uStmt;

type
  TLicence=record
    //version 1
    licensee:string[40];
    licenseeId:cardinal;
    licenseeType:cardinal;      //0=beta-tester, 1=any developer, 2=specific developer, 3=specific user, 4=unknown user (licenseeId=0)
    licenseeMAC:string[12];     //if set, tie to MAC address

    licensor:string[40];
    licensorId:cardinal;        //0=ThinkSQL
    licensorType:cardinal;      //0=ThinkSQL, 1=Re-seller, 2=VAR
    licensorSerial:string[14];  //serial number unique to licensor: full serial number=licensorId.licensorSerial

    granted:Tdatetime;
    maxConnections:integer;
    grantedVersion:cardinal;    //000=beta, 100=version 1.00, etc.
    expiry:Tdatetime;

    quantity:string[4];         //order qty
    reserved1:cardinal;
    //end-version 1
    //checksum checkpoint
  end; {TLicence}

  TLicenceUpdate=record
    //type 1
    licensorId:cardinal;      //0=ThinkSQL
    licensorUpdate:cardinal;  //update number unique to licensor: full update number=licensorId.licensorUpdate

    granted:Tdatetime;
    maxConnections:integer;
  end; {TLicenceUpdate}


  TDBserver=class
    private
      FdbList:TThreadList;

      Fname:string;         //the server name

      FlicenceFile:File;
      Flicence:TLicence;
      FlicenceChecksum:array [0..19] of byte;

      FlicenceUpdate:TLicenceUpdate;
    public
      buffer:TBufMgr; 

      startTime:TDateTime;

      property name:string read Fname write Fname;  //todo use Set method

      property licence:TLicence read FLicence;

      property dbList:TThreadList read FdbList; //expose threadlist of dbs (for monitor)

      constructor Create;
      destructor Destroy; override;

      function addDB(name:string):TDB;
      function findDB(name:string):TDB;
      function removeDB(db:TDB):integer;

      function getInitialConnectdb:TDB;

      function readLicence(ipt:integer):integer;
      function ip(var j:integer):integer; //getConnectionCount
      function debugDump(st:Tstmt;connection:TIdTCPConnection;summary:boolean):integer;
  end; {TDBserver}

const
  //BAD_LICENSEE='?';
  //BAD_MAXCONNECTIONS=1;
  //BAD_EXPIRY=0;

  Key:array [0..9] of char=(#165,#183,#159,#19,#04,#51,#144,#117,#90,#75);

var
  licenceVersion:cardinal=1;

(*
procedure encrypt(d:pchar;s:cardinal);
procedure decrypt(d:pchar;s:cardinal);
function calculateChecksum(d:pchar;s:cardinal):cardinal;
*)

implementation

uses uLog, {for coCreateGuid+inttohex ActiveX,} sysUtils,
     uTransaction, {for getConnectionCount}
     DCPtwofish, DCPsha1
     ,uEvsHelpers
     ;

const
  where='uServer';
  who='';

(*not yet
function Get_MACAddress : string;
var
  g : TGUID;
  i : byte;
begin
  result := '';
  CoCreateGUID(g);
  for i:= 2 to 7 do
    result := result + IntToHex(g.D4[i], 2);
end;
*)

constructor TDBserver.Create;
begin
  //Fgetdb:=nil;
  FdbList:=TThreadList.create;
  FdbList.duplicates:=dupAccept;

  Fname:='THINKSQL';

  {Now read the license file. Initially this will tell us:
     maximum number of connections (use for setting thread pool size & limiting users)
     expiration date

   Since this is a fairly empty unit so far, we include the license code in it...
  }
//  if readLicence(cardinal(self))<>cardinal(self){todo check against time} then
//  begin
//    Flicence.licensee:='?';
//    Flicence.maxConnections:=strtoint(format('%d',[-1]));
    //Flicence.expiry:=0;
//  end;

  buffer:=TBufMgr.create;

  startTime:=now;
end; {Create}

destructor TDBserver.Destroy;
const routine=':destroy';
var i:integer;
begin
  {Close & destroy any open dbs}
  try
    with FdbList.LockList do
    begin
      Pack;
      {$IFDEF DEBUG_LOG}
      if count>0 then log.add(who,where+routine,'Server DB list is not empty, will close now: '+inttostr(count),vAssertion);
      {$ENDIF}
      //free them now!
      for i:=count-1 downto 0 do
        try
          TDB(Items[i]).free;
        except
          on E:Exception do
          begin //ignore errors - something's probably wrong so continue to clean up
            {$IFDEF DEBUG_LOG}
            log.add(who,where+routine,'Exception: '+E.message,vError); 
            {$ENDIF}
          end;
        end; {try}
    end;
  finally
    FdbList.UnlockList;
  end; {try}

  FdbList.free;

  buffer.Free;
  inherited Destroy;
end;

function TDBserver.addDB(name:string):TDB;
{Creates and adds a new db component to the server
 IN      : name          the reference name of the database
 RETURN  : Tdb reference=OK, nil=error (e.g. name already exists)
}
const routine=':addDB';
var
  newDB:TDB;  //pointer to new db to be added in server's list
  i:integer;
begin
  result:=nil;

  {Make sure this name doesn't already exist in the list before we add it}
  try
    with FdbList.locklist do
      for i:=0 to count-1 do
        if (Items[i]<>nil) and (uppercase(TDB(Items[i]).dbName)=uppercase(name)) then
        begin //found
          exit; //abort
        end;

    newDB:=TDB.Create(self,name);
    FdbList.Add(newDB);

    result:=newDB;
  finally
    FdbList.unlockList;
  end; {try}
end; {addDB}

function TDBserver.findDB(name:string):TDB;
{Finds the specified db if it already attached to the server
 IN      : name
 RETURN  : Tdb reference=OK found, else nil=not found

 Note: case insensitive
}
var i:integer;
begin
  result:=nil;
  try
    with FdbList.locklist do
      for i:=0 to count-1 do
        if (Items[i]<>nil) and (uppercase(TDB(Items[i]).dbName)=uppercase(name)) then
        begin //found
          result:=TDB(Items[i]);
          break;
        end;
  finally
    FdbList.unlockList;
  end; {try}
end; {findDB}

function TDBserver.removeDB(db:TDB):integer;
{Removes and destroys a db component from the server
 IN      : db           the reference of the database
 RETURN  : +ve=ok, else fail

 Note: if the reference is not found in the server's list no attempt is made
       to destroy the db via the reference
}
const routine=':removeDB';
begin
  result:=ok;

  try
    with FdbList.locklist do
      if Remove(db)=-1 then result:=fail;
  finally
    FdbList.unlockList;
  end; {try}

  if result=ok then db.free; //todo only if result=ok, e.g. create catalog zapped old one & umain is trying to release it
end; {removeDB}

function TDBserver.getInitialConnectdb:TDB;
{Returns an initial (default) db for new connections to use to read sysAuth etc.

 Note: this is now used to indicate the 'primary' catalog for the server,
 i.e. the one who's ADMIN can control the server
}
const routine=':getInitialConnectdb';
begin
  try
    with FdbList.locklist do
      if count=0 then result:=nil else result:=first;
  finally
    FdbList.unlockList;
  end; {try}

  asm   //hacker scare
    nop
    nop
    nop
    nop
    nop
    nop
  end;
end; {getInitialConnectdb}


(*
procedure encrypt(d:pchar;s:cardinal);
var i:cardinal;
begin
  for i:=0 to s-1 do
    byte((d+i)^):=($D6 xor byte((d+i)^)) xor (Key[i mod (high(Key)+1)]+i);
end;
procedure decrypt(d:pchar;s:cardinal);
var i:cardinal;
begin
  for i:=0 to s-1 do
    byte((d+i)^):=($D6 xor byte((d+i)^)) xor (Key[i mod (high(Key)+1)]+i);
end;
function calculateChecksum(d:pchar;s:cardinal):cardinal;
var i:cardinal;
begin
  result:=0;
  for i:=0 to s-1 do
    result:=result+byte((d+i)^);
end;
*)

function TDBserver.readLicence(ipt:integer):integer;
{Read the server license file details

 This makes no decisions based on the information: just reads it

 RETURN: +ve=ok (if = ipt)
         -2=error opening/reading file
         -3=checksum error
         -4=licence has expired
         else fail
}
var
  dcp:TDCP_twofish;
  hash:TDCP_sha1;
  checksumCheck:array [0..19] of byte;
  passKey:string;
begin
  result:=fail;

  fillchar(Flicence,sizeof(Flicence),0); //must blank all to keep clean checksum

  asm   //hacker scare
    nop
    nop
    nop
    nop
    nop
    nop
  end;

  dcp:=TDCP_twofish.create(nil);
  hash:=TDCP_sha1.create(nil);
  try
    passKey:=Key;
    dcp.InitStr(passKey,TDCP_sha1);
    try
      assignFile(FlicenceFile,licenceFilename);
      FileMode:=0;  {Set file access to read only: note not threadsafe}
      try
        reset(FlicenceFile,1);
      finally
        FileMode:=2;  {Set file access back to read/write}
      end;
      try
        blockread(FlicenceFile,licenceVersion,sizeof(licenceVersion)); //unencrypted
        if licenceVersion>=1 then begin
          blockread(FlicenceFile,Flicence,sizeof(Flicence));
          dcp.decrypt(Flicence,Flicence,sizeof(Flicence));
        end; //1

        //IFNDEF SUPPORTED_VERSION if grantedVersion<>VersionNumber then exit with -5
        //todo check expiry

        {Ensure the checksum is correct}
        hash.init;
        hash.Update(Flicence,sizeof(Flicence));
        hash.Final(checksumCheck);
        blockread(FlicenceFile,FlicenceChecksum,sizeof(FlicenceChecksum));
        {dcp.decrypt(FlicenceChecksum,FlicenceChecksum,sizeof(FlicenceChecksum));}
        if not comparemem(@FlicenceChecksum,@checksumCheck,sizeof(FlicenceChecksum)) then
        begin //tampered!
          result:=-3;
          exit; //abort
        end;

        {todo: block any suspect licensorId.licensorSerial here
        }
        {todo: check the version = our version
               & not expired etc.
        }
        if (Flicence.expiry<>0) and (Flicence.expiry<date) then
        begin //licence has expired
          result:=-4;
          exit; //abort
        end;

        {Now read any updates}
        while not eof(FlicenceFile) do
        begin
          blockread(FlicenceFile,FlicenceUpdate,sizeof(FlicenceUpdate));
          dcp.decrypt(FlicenceUpdate,FlicenceUpdate,sizeof(FlicenceUpdate));

          {Increase max connections}
          Flicence.maxConnections:=Flicence.maxConnections+FlicenceUpdate.maxConnections;

          {Ensure the checksum is correct}
          hash.init;
          hash.Update(FlicenceUpdate,sizeof(FlicenceUpdate));
          hash.Final(checksumCheck);
          blockread(FlicenceFile,FlicenceChecksum,sizeof(FlicenceChecksum));
          {dcp.decrypt(FlicenceChecksum,FlicenceChecksum,sizeof(FlicenceChecksum));}
          if not comparemem(@FlicenceChecksum,@checksumCheck,sizeof(FlicenceChecksum)) then
          begin //tampered!
            result:=-3;
            exit; //abort
          end;
        end;

        result:=ipt;
        //todo result:=time & caller must check
      finally
        closeFile(FlicenceFile);
      end; {try}
    except
      result:=-2;
      //silence!
    end; {try}
  finally
    hash.free;
    dcp.burn;
    dcp.free;
  end; {try}
end; {readLicense}

function TDBserver.ip(var j:integer):integer;
{Get connection count (innocuous name to confuse hackers)

 IN :     j = random seed (not used) caller insists result=j (else assumes error)
 OUT:     j = connections in use
 RETURNS: original j = ok, else fail
}
var
  i:integer;
  e:boolean;
  t:Tobject;
begin
  result:=j+5;
  j:=0;
  try
    with FdbList.locklist do
    begin
      for i:=0 to count-1 do
        if Items[i]<>nil then
        begin
          if TDB(Items[i]).TransactionScanStart<>ok then exit; //abort //Note: this protects us from the transaction we find from disappearing!
          try
            e:=False;
            while not e do
            begin
              if TDB(Items[i]).TransactionScanNext(t,e)<>ok then exit;
              if not e then
                if {(TTransaction(t)<>self) and} (TTransaction(t).authID<>InvalidAuthId) then //this is not us & is connected
                  inc(j);
                {Note garbage collectors are discounted because their authId is left invalid: they do connect, but don't logon in the normal way}
            end; {while}
          finally
            TDB(Items[i]).TransactionScanStop; //todo check result
          end; {try}
        end;
      result:=result-3;
      asm
        nop
      end;
      result:=result-2;
    end; {with}
  finally
    FdbList.unlockList;
  end; {try}
end; {ip=getConnectionCount}

function TDBserver.debugDump(st:Tstmt;connection:TIdTCPConnection;summary:boolean):integer;
const routine=':debugDump';
var
  i:integer;
  initialDB:TDB;
begin
  result:=ok;

  if connection<>nil then
  begin
    connection.Writeln('Server: '+FName);
    connection.Writeln(formatDateTime('"Started at "c',startTime));
    connection.Writeln(format('Maximum connections=%d',[FLicence.maxConnections]));
    ip(i);
    connection.Writeln(format('Active connections=%d',[i]));
    connection.Writeln;
    connection.Writeln('Open catalogs:');
    initialDB:=getInitialConnectdb;
    try
      with FdbList.locklist do
        for i:=0 to count-1 do
          if TDB(Items[i])=initialDB then
            connection.Writeln(' *'+TDB(Items[i]).dbName)
          else
            connection.Writeln('  '+TDB(Items[i]).dbName);
    finally
      FdbList.unlockList;
    end; {try}
    //todo buffer summary

    if not summary then
    begin
      //todo debug buffer frames!
    end;
    connection.Writeln;
  end;
end; {debugDump}

end.

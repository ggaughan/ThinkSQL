unit uMain;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

interface

procedure Main;

implementation

uses IniFiles, Registry, classes, windows;

const
  InstalledDrivers='Installed Drivers';
  Section='ThinkSQL';
    GetDriverFunc='GetDriverFunc';
    LibraryName='LibraryName';
    VendorLib='VendorLib';
    BlobSize='BlobSize';
    Database='Database';
    HostName='HostName';
    Password='Password';
    User_Name='User_Name';


procedure Main;
var
  r:TRegistry;
  f:TMemIniFile;
  filename:string;
  s:TStrings;
begin
  {Find out where the DBExpress driver ini file lives}
  r:=TRegistry.Create;
  try
    r.RootKey:=HKEY_CURRENT_USER;
    if r.OpenKey('\Software\Borland\DBExpress', False) then
    begin
      filename:=r.ReadString('Driver Registry File');
      r.CloseKey;
    end
    else
      exit; //no DBExpress - don't bother trying to install
  finally
    r.Free;
  end; {try}

  {Now add our section to the ini file if it doesn't already exist}
  s:=TStringList.create;
  f:=TMemIniFile.Create(filename);
  try
    if f.ReadString(InstalledDrivers,Section,'')='' then
    begin  //doesn't already exist, so add our driver details
      f.WriteString(InstalledDrivers,Section,'1');

      f.WriteString(Section,GetDriverFunc,'getSQLDriverTHINKSQL');
      f.WriteString(Section,LibraryName,'sqlthink.dll');
      f.WriteString(Section,VendorLib,'sqlthink.dll');
      f.WriteString(Section,BlobSize,'-1');
      f.WriteString(Section,Database,'thinksql');
      f.WriteString(Section,HostName,'localhost');
      f.WriteString(Section,Password,'');
      f.WriteString(Section,User_Name,'DEFAULT');

      f.UpdateFile;
    end;
    //else would return 1, i.e. installed
  finally
    f.Free;
    s.free;
  end;
end; {Main}

end.

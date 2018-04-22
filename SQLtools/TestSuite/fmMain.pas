unit fmMain;

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, Dialogs,
  ComCtrls, ExtCtrls, StdCtrls, Buttons, FileCtrl, DBTables, Db, Grids,
  DBGrids;

type
  TfrmMain = class(TForm)
    pnlTop: TPanel;
    pnlClient: TPanel;
    pnlBottom: TPanel;
    StatusBar1: TStatusBar;
    PageControl1: TPageControl;
    tsTest: TTabSheet;
    Panel1: TPanel;
    Panel2: TPanel;
    btnBase: TBitBtn;
    btnTest: TBitBtn;
    flbTests: TFileListBox;
    qryTest: TQuery;
    dsTest: TDataSource;
    dbTest: TDatabase;
    bmCopyToBase: TBatchMove;
    tBase: TTable;
    Panel3: TPanel;
    dbgTest: TDBGrid;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    memoTest: TMemo;
    tsDifferences: TTabSheet;
    pnlLeft: TPanel;
    pnlRight: TPanel;
    Splitter3: TSplitter;
    dbgLeft: TDBGrid;
    dbgRight: TDBGrid;
    tLeft: TTable;
    tRight: TTable;
    dsLeft: TDataSource;
    dsRight: TDataSource;
    memoLeft: TMemo;
    memoRight: TMemo;
    btnSelectAll: TBitBtn;
    tsReport: TTabSheet;
    reReport: TRichEdit;
    procedure FormShow(Sender: TObject);
    procedure btnBaseClick(Sender: TObject);
    procedure flbTestsChange(Sender: TObject);
    procedure btnTestClick(Sender: TObject);
    procedure btnSelectAllClick(Sender: TObject);
  private
    { Private declarations }
    function executeSQLfromFile(filename:string):boolean;
    function saveResultsToFile(filename:string):boolean;
    procedure logTimeToFile(filename:string);
  public
    { Public declarations }
    dir:string;
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.DFM}

const
  BASE_EXTENSION='.base';
  TEST_EXTENSION='.test';
  ASCII_FILE_EXTENSION='.txt';  //fixed by BDE
  ASCII2_FILE_EXTENSION='.sch'; //fixed by BDE
  BASE_TIME_EXTENSION='.base_time';
  TEST_TIME_EXTENSION='.test_time';

  TEST_REPORT_FILENAME='"test"YYMMDD".txt"';

var
  startTime,endTime:TDateTime;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  {Point file list box at tests}
  if not setCurrentDir(dir) then
    showmessage('Failed setting directory')
  else
  begin
    flbTests.Directory:=dir;
    flbTests.Update;
    tLeft.databaseName:=flbTests.Directory;
    tRight.databaseName:=flbTests.Directory;
  end;
end;

procedure TfrmMain.btnBaseClick(Sender: TObject);
var
  i:integer;
  overwrite:integer;
begin
  tRight.Close;
  tLeft.Close;

  {Create base line for the selected test(s)}
  for i:=0 to flbTests.Items.Count-1 do
  begin
    if flbTests.Selected[i] then
    begin
      if fileExists(flbTests.Items.Strings[flbTests.ItemIndex]+BASE_EXTENSION+ASCII_FILE_EXTENSION)
         and fileExists(flbTests.Items.Strings[flbTests.ItemIndex]+TEST_EXTENSION+ASCII_FILE_EXTENSION) then
        begin
          overwrite:=messageDlg('Test results exist for '+extractFilename(flbTests.Items.Strings[i])+'. Overwrite the current base?',mtWarning,[mbYes,mbNo,mbAbort],0);
          case overwrite of
            mrNo : continue; //skip
            mrAbort: exit;   //abort
          end; {case}
        end;

      if executeSQLfromFile(flbTests.Items.Strings[i]) then
      begin
        if not saveResultsToFile(extractFilename(flbTests.Items.Strings[i])+BASE_EXTENSION) then
          showMessage('Failed creating base')
        else //log the time for future benchmarking
          logTimeToFile(flbTests.Items.Strings[i]+BASE_TIME_EXTENSION);
      end
      else
        showMessage('Failed running base '+extractFilename(flbTests.Items.Strings[i]));
    end;
  end;
end;

procedure TfrmMain.logTimeToFile(filename:string);
var
  timeReport:textFile;
  h,m,s,s100:word;
begin
  assignFile(timeReport,filename);
  rewrite(timeReport);
  try
    decodeTime(endTime-startTime,h,m,s,s100);
    writeln(timeReport,format('Time=%2.2d:%2.2d:%2.2d:%2.2d',[h,m,s,s100]));
  finally
    closeFile(timeReport);
  end; {try}
end; {logTimeToFile}

function TfrmMain.executeSQLfromFile(filename:string):boolean;
{Side effects:
  updates unit global startTime & endTime
}
begin
  result:=False;

  with qryTest do
  begin
    close; //close previous results

    sql.Clear;
    sql.LoadFromFile(filename);
    try
      startTime:=now;
      open;
      result:=True;
      endTime:=now;
    except
      on E:Exception do
      begin
        result:=False;
      end;
    end; {try}
  end; {with}
end; {executeSQLfromFile}

function TfrmMain.saveResultsToFile(filename:string):boolean;
begin
  result:=False;

  tBase.databaseName:=flbTests.Directory;
  tBase.TableName:=filename;
  try
    bmCopyToBase.Execute;
    result:=True;
    statusBar1.SimpleText:=format('%d row(s) written to %s',[bmCopyToBase.movedCount,tBase.TableName]);
  except
    on E:Exception do
      result:=False;
  end; {try}
end; {saveResultsToFile}

procedure TfrmMain.flbTestsChange(Sender: TObject);
begin
  if flbTests.Items.Count>0 then
  begin
    if flbTests.SelCount=1 then
    begin
      memoTest.Lines.LoadFromFile(flbTests.Items.Strings[flbTests.ItemIndex]);
      (* todo remove:
      btnBase.enabled:=not fileExists(flbTests.Items.Strings[flbTests.ItemIndex]+BASE_EXTENSION+ASCII_FILE_EXTENSION)
                       or not fileExists(flbTests.Items.Strings[flbTests.ItemIndex]+TEST_EXTENSION+ASCII_FILE_EXTENSION);
      *)


      btnTest.enabled:=fileExists(flbTests.Items.Strings[flbTests.ItemIndex]+BASE_EXTENSION+ASCII_FILE_EXTENSION);
    end
    else
    begin
      memoTest.Lines.Clear;
      btnTest.enabled:=True;
    end;
  end;
end;

procedure TfrmMain.btnTestClick(Sender: TObject);
var
  i:integer;
  report:textFile;
  reportFilename:string;
  selectedCount,errorCount,differenceCount:integer;
begin
  {Create test for the selected test(s) & compare the results with the base}
  selectedCount:=0;
  errorCount:=0;
  differenceCount:=0;

  tRight.Close;
  tLeft.Close;

  reportFilename:=formatDateTime(TEST_REPORT_FILENAME,now);
  assignFile(report,reportFilename);
  rewrite(report);
  try
    writeln(report,format('Test Report started at %s',[formatDateTime('c',now)]));
    writeln(report,format('%s',[flbTests.Directory]));
    writeln(report);

    for i:=0 to flbTests.Items.Count-1 do
    begin
      if flbTests.Selected[i] then
      begin
        inc(selectedCount);

        if executeSQLfromFile(flbTests.Items.Strings[i]) then
        begin
          if saveResultsToFile(extractFilename(flbTests.Items.Strings[i])+TEST_EXTENSION) then
            try
              {First log the time for future benchmarking}
              logTimeToFile(flbTests.Items.Strings[i]+TEST_TIME_EXTENSION);

              {Check for differences}
              memoRight.Lines.LoadFromFile(flbTests.Items.Strings[i]+TEST_EXTENSION+ASCII_FILE_EXTENSION);
              memoLeft.Lines.LoadFromFile(flbTests.Items.Strings[i]+BASE_EXTENSION+ASCII_FILE_EXTENSION);
              if compareStr(memoLeft.text,memoRight.text)<>0 then
              begin
                if flbTests.SelCount=1 then PageControl1.activePage:=tsDifferences;
                inc(differenceCount);
                writeln(report,format('%s: %s',['Failed',flbTests.Items.Strings[i]]));
                writeln(report,'BASE:');
                writeln(report,format('%s',[memoLeft.text]));
                writeln(report,'TEST:');
                writeln(report,format('%s',[memoRight.text]));
              end
              else
              begin
                (*todo reinstate
                memoRight.Lines.LoadFromFile(flbTests.Items.Strings[i]+TEST_EXTENSION+ASCII2_FILE_EXTENSION);
                memoLeft.Lines.LoadFromFile(flbTests.Items.Strings[i]+BASE_EXTENSION+ASCII2_FILE_EXTENSION);
                if compareStr(memoLeft.text,memoRight.text)<>0 then
                begin
                  PageControl1.activePage:=tsDifferences;
                  statusBar1.SimpleText:=format('Test columns differ from base',[nil]);
                end;
                *)

                writeln(report,format('%s: %s',['Passed',flbTests.Items.Strings[i]]));
              end;

              try
                if flbTests.SelCount=1 then
                begin
                  {Show tables in difference tab}
                  tRight.databaseName:=flbTests.Directory;
                  tLeft.databaseName:=flbTests.Directory;
                  tRight.TableName:=extractFilename(flbTests.Items.Strings[i])+TEST_EXTENSION;
                  tLeft.TableName:=extractFilename(flbTests.Items.Strings[i])+BASE_EXTENSION;
                  tRight.Open;
                  tLeft.Open;
                end;
              except
                on E:Exception do
                  ; //nothing - especially inc(errorCount) after our Pass
              end; {try}

            except
              on E:Exception do
              begin
                inc(errorCount);
                writeln(report,format('%s: %s',['Error ',flbTests.Items.Strings[i]]));
              end;
            end {try}
          else
          begin
            inc(errorCount);
            writeln(report,format('%s: %s',['Error ',flbTests.Items.Strings[i]]));
          end;
        end
        else
        begin
          inc(errorCount);
          writeln(report,format('%s: %s',['Error ',flbTests.Items.Strings[i]]));
        end;
      end;
    end;
  finally
    writeln(report);
    writeln(report,format('Summary:',[nil]));
    writeln(report,format('Errors: %d',[errorCount]));
    writeln(report,format('Passed: %d',[selectedCount-errorCount-differenceCount]));
    writeln(report,format('Failed: %d',[differenceCount]));
    writeln(report);
    writeln(report,format('Total : %d',[selectedCount]));
    writeln(report,format('Test Report finished at %s',[formatDateTime('c',now)]));

    closeFile(report);

    statusBar1.SimpleText:=format('Passed: %d  Failed: %d  Errors: %d  Total: %d',[
                                           (selectedCount-errorCount-differenceCount),
                                           differenceCount,
                                           errorCount,
                                           selectedCount]);
    reReport.Lines.LoadFromFile(reportFilename);
  end; {try}
end;

procedure TfrmMain.btnSelectAllClick(Sender: TObject);
var i:integer;
begin
  for i:=0 to flbTests.Items.Count-1 do
    flbTests.Selected[i]:=True;
end;

end.

unit uIterMaterialise;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

//{$DEFINE DEBUGDETAIL}

{
 Note:
   this assumes the child iterator is not an iterSort
   - ok because the syntax does not allow subselects with ORDER BYs
   - otherwise we'd materialise twice!

   - what about group by? - uses iterSort... keep final temp-file instead of iterMaterialise?
   - rare in subselects?
}

interface

uses uIterator, uTransaction, uStmt, uSyntax, uTempTape, uGlobal;

type
  TIterMaterialise=class(TIterator)
    private
      rowCount:integer;   //keep count of rows materialised so far
      currentRow:integer; //keep track of cached rows so far
      noMoreLeft:boolean; //keep track of whether we've cached everything
      started:boolean;    //keep track of whether we've started the sub-iter

      cacheBuf:array [0..MaxRecSize-1] of char;  //read buffer area
      cacheBufLen:integer;                       //read buffer length of current record
      cache:TTempTape;
    public
      stopped:boolean;    //keep track of whether we've stopped the sub-iter
      
      function status:string; override;

      constructor create(S:TStmt);
      destructor destroy; override;

      function prePlan(outerRef:TIterator):integer; override;
      function optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer; override;
      function start:integer; override;  //begin
      function stop:integer ;override;   //end
      function next(var noMore:boolean):integer; override;   //loop
  end; {TIterMaterialise}

const
  FNAME='mat%4.4d%4.4d_%4.4d';  //temporary filename template (tran stmt,plan-node) //todo make unique to server etc.

implementation

uses uLog, sysUtils, uTuple;

const
  where='uIterMaterialise';

constructor TIterMaterialise.create(S:TStmt);
begin
  inherited create(s);
  started:=False;
  stopped:=False;
  rowCount:=0;
  currentRow:=0;
  noMoreLeft:=False;
  {Create the temporary cache}
  cache:=TTempTape.create;

  {Note: the preplan is not called until optimise, so we set the flag here to prevent caller error}
  preplanned:=True;
end; {create}

destructor TIterMaterialise.destroy;
const routine=':destroy';
begin
  {Close and destroy the temporary cache}
  //todo! we need some kind of reStart to close and delete and reset started/stopped/rowCount for next execution of main!
  cache.close;
  cache.delete;
  cache.free;
  inherited destroy;
end; {destroy}


function TIterMaterialise.status:string;
begin
  {$IFDEF DEBUG_LOG}
  result:=format('TIterMaterialise [current row=%d out of %d row(s) cached]',[currentRow,rowCount]);
  {$ELSE}
  result:='';
  {$ENDIF}
end; {status}

function TIterMaterialise.prePlan(outerRef:TIterator):integer;
{PrePlans the materialise process
 RETURNS:  ok, else fail
}
const routine=':prePlan';
begin
//note: this is never called! (work is done in optimise routine instead & preplanned flag is set during create)

  result:=inherited prePlan(outerRef);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s preplanning',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}
  if assigned(leftChild) then
  begin
    result:=leftChild.prePlan(outer);   //recurse down tree
    if result<>ok then exit; //aborted by child
    correlated:=leftChild.correlated;

    {Define this ituple from leftChild.ituple}
    //todo is there a way to share the same memory or tuple?
    // - maybe destroy this one & point iTuple at leftChild's?
    iTuple.CopyTupleDef(leftChild.iTuple);
  end;

  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s',[iTuple.ShowHeading]),vDebugHigh); //debug
  {$ELSE}
  ;
  {$ENDIF}
end; {prePlan}

function TIterMaterialise.optimise(var SARGlist:TSyntaxNodePtr;var newChildParent:TIterator):integer;
{Optimise the prepared plan from a local perspective

 IN:       SARGlist         list of SARGs
 OUT:      newChildParent   child inserted new parent, so caller should relink to it
 RETURNS:  ok, else fail
}
const routine=':optimise';
begin
  {Note: since preplan is not called for the Materialise iterator, we do this now}
  iTuple.CopyTupleDef(leftChild.iTuple);

  result:=inherited optimise(SARGlist,newChildParent);
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s optimising',[self.status]),vDebugLow);
  {$ELSE}
  ;
  {$ENDIF}

  if assigned(leftChild) then
  begin
    result:=leftChild.optimise(SARGlist,newChildParent);   //recurse down tree
  end;
  if result<>ok then exit; //aborted by child
  if newChildParent<>nil then
  begin
    {Child has inserted an intermediate node - re-link to new child for execution calls}
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('linking to new leftChild: %s',[newChildParent.Status]),vDebugLow);
    {$ELSE}
    ;
    {$ENDIF}
    {$ENDIF}
    leftChild:=newChildParent;
    newChildParent:=nil; //don't continue passing up!
  end;
  //todo: same for rightChild if we could have one

  //check if any of our SARGs are now marked 'pushed' & remove them from ourself if so
end; {optimise}

function TIterMaterialise.start:integer;
{Start the materialise process
 RETURNS:  ok, else fail
}
const routine=':start';
var
  r:integer;
begin
  result:=inherited start;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s starting',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  //todo! we need some kind of reStart to close and delete and reset started/stopped/rowCount for next execution of main!

  if not started then
  begin //really start for the 1st time
    r:=trunc(random(9999)); //todo DEBUG ONLY - REMOVE!! need to make file unique to trans+node! i.e. SYS-getNextFilename!
    //todo: if the outer loop is small & this subselect is small (e.g. 1 row = we may know this from the syntax, i.e. row subselect)
    //      it may be worth not materialising to save the temp-file costs - speed - leave to materialise creator!
    result:=cache.CreateNew(format(FNAME,[stmt.Rt.tranId,stmt.Rt.stmtId,r]));

    if assigned(leftChild) then
    begin
      result:=leftChild.start;   //recurse down tree
      if result<>ok then exit; //aborted by child
    end;
    started:=True;
  end
  else
  begin //restart using cache
    cache.rewind;
  end;
  currentRow:=0;
end; {start}

function TIterMaterialise.stop:integer;
{Stop the output process
 RETURNS:  ok, else fail
}
const routine=':stop';
begin
  result:=inherited stop;
  {$IFDEF DEBUGDETAIL}
  {$IFDEF DEBUG_LOG}
  log.add(stmt.who,where+routine,format('%s stopping',[self.status]),vDebugLow);
  {$ENDIF}
  {$ENDIF}

  if not stopped then
  begin
    if noMoreLeft then
    begin //really stop for 1st time
      if assigned(leftChild) then result:=leftChild.stop;   //recurse down tree
      {$IFDEF DEBUGDETAIL}
      {$IFDEF DEBUG_LOG}
      log.add(stmt.who,where+routine,format('All %d row(s) cached',[rowCount]),vDebugLow);
      {$ENDIF}
      {$ENDIF}
      stopped:=True;
    end;
  end
  else
  begin //stop cache
  end;
end; {stop}

function TIterMaterialise.next(var noMore:boolean):integer;
{Get the next tuple from the materialise process
 Note: this routine's ituple may well have pointers to the child's ituple
       (because of the copy method used) and so we must
       ensure that the child's is not unpinned until we have finished with
       it.
 RETURNS:  ok, else fail
}
const routine=':next';
var
  i:ColRef;
begin
//  inherited next;
  result:=ok;
{$IFDEF DEBUG_LOG}
//  log.add(stmt.who,where+routine,format('%s next',[self.status]),vDebugLow);
{$ELSE}
;
{$ENDIF}
  if stmt.status=ssCancelled then
  begin
    result:=Cancelled;
    exit;
  end;

  if currentRow<rowCount then
  begin //use next cached row
    //todo assert not cache.noMore
    result:=cache.readRecord(cacheBuf,cacheBufLen);
    if result<>ok then exit; //abort

    result:=iTuple.CopyBufferToData(cacheBuf,cacheBufLen);
    {$IFDEF DEBUGDETAIL}
    {$IFDEF DEBUG_LOG}
    log.add(stmt.who,where+routine,format('(cached) %s',[iTuple.Show(stmt)]),vDebugHigh);
    {$ENDIF}
    {$ENDIF}
    inc(currentRow);
  end
  else //read & return next row (if any more left)
  begin
    if noMoreLeft then
    begin
      noMore:=True;
    end
    else
    begin //read & return next row & cache it
      if assigned(leftChild) then result:=leftChild.next(noMore);   //recurse down tree
      if result<>ok then exit; //abort
      if not noMore then
      begin //copy leftchild.iTuple to this.iTuple (point?)
        iTuple.clear(stmt); //speed - fastClear?
        for i:=0 to leftChild.iTuple.ColCount-1 do
        begin
          if iTuple.fColDef[i].dataType<>leftChild.iTuple.fColDef[i].datatype then
            iTuple.CopyColDef(i,leftChild.iTuple,i); //DEBUG only to fix when # suddenly changes to $ - remove!!
                                                     //Did fix problem - but need to remove this overhead!!!
                                                     // e.g. problem: select 1,(select "s" from sysTable) from sysTable
                                                     //                                 ^
          iTuple.CopyColDataPtr(i,leftChild.iTuple,i);
        end;

        //todo: put some kind of limit here so we don't fill the disk!
        //      e.g. if rowCount>10000 or if tempDiskAllocation<currentTempFileAllocation
        //      - if we do limit here, we can just not increase rowCount:
        //        i.e. cache 1st section, but re-iterate over last section
        //        - to do so, we'd need to re-start properly each time we tried to go past rowCount,
        //        i.e. proper-start & .next rowCount times to skip to position & then .next
        //        - this would still be of benefit for callers such as exists/all/any/etc. in case they exit early
        //        => in fact it would behave like a buffer, delaying or avoiding the real latter reads 

        {Now materialise this tuple - the whole point of this extra layer!}
        {$IFDEF DEBUGDETAIL}
        {$IFDEF DEBUG_LOG}
        log.add(stmt.who,where+routine,format('%s',[iTuple.Show(stmt)]),vDebugHigh);
        {$ENDIF}
        {$ENDIF}
        result:=iTuple.CopyDataToFixedBuffer(cacheBuf,cacheBufLen); //todo skip this step?
        result:=cache.WriteRecord(cacheBuf,cacheBufLen);

        //todo: would be nice to keep/add primary index to this cached relation!

        inc(rowCount);
        inc(currentRow);
      end
      else
        noMoreLeft:=True;
    end;
  end;
end; {next}


end.

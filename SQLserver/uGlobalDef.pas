unit uGlobalDef;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Common db definitions
 Placed here to avoid circular references
 - try to keep simple base types in uGlobal
}

interface

uses uGlobal;

type
  SlotId=word;            //(limits # of slots to 65535)

  Trid=record             //RID - unique record/tuple reference //Note: Oracle had to change to (file,page,slot) - plan ahead!
    pid:PageId;           //page
    sid:SlotId;           //slot
  end; {Trid}

  {Blob on disk storage}
  Tblob=record
    rid:Trid;             //Note: when sid=InvalidSlotId then pid->memory (e.g. new or in-memory tuples), else ->disk
    len:cardinal;         //size in bytes (either in memory or on disk)
  end; {TBlob}


const
  InvalidSlotId=0;        //points to header slot = invalid & before all others
  //fails for some reason...
  //InvalidTrid:Trid=(PageId:InvalidPageId;SlotId:InvalidSlotId);


implementation




end.

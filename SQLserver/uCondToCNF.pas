unit uCondToCNF;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{Routines to convert a conditional expression to its canonical
 conjunctive normal form.

 The routine accepts a syntax tree node and will modify the tree as required
}

interface//JKOZ : Indy Clean;

uses uSyntax;

function CondToCNF(srootAlloc:TSyntaxNodePtr;var snode:TSyntaxNodePtr):integer;

implementation

uses uGlobal,
{$IFDEF Debug_Log}
  uLog,
{$ENDIF}  
  SysUtils;

{$IFDEF Debug_Log}
const
  where='uCondToCNF';
  who='';
{$ENDIF}  

function PushORs(srootAlloc:TSyntaxNodePtr;snode:TSyntaxNodePtr):integer;
{Pushes OR nodes down into AND nodes
 IN             : snode           the original condition root
 OUT            : snode           points to the root of the updated tree
                                  (same physical node, but may have changed)
 RESULT         : ok, or fail if error

 Assumes:
   AND and OR always have two sub-trees
}
{$IFDEF Debug_Log}
const routine=':PushORs';
{$ENDIF}
var
  stemp:TSyntaxNodePtr;
begin
//todo assert the assumptions & check no nil pointers

  result:=ok;
  if snode<>nil then
  begin
    //recurse down the tree (use infix order)
    if (snode.leftChild<>nil) then if PushORs(srootAlloc,snode.leftChild)<>ok then exit; //abort to avoid circles? possible if corrupt?

    {Push OR down inside AND}
    if (snode.nType=ntOR) and (snode.leftChild.ntype=ntAND) then
    begin
      {      V                    &
          &     C      ->     V1     V2
         A B                 A  C   B  C
      }
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Pushing OR inside AND(l) at %p',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {create new right child, V2}
      stemp:=mkNode(srootAlloc,ntOR,ctUnknown,snode.leftChild.rightChild{B},snode.rightChild{C}); //note: memory
      {We're moving the sub-trees (B, C), not re-referencing them (yet), so don't update ref counts}
      dec(snode.leftChild.rightChild.refCount);
      dec(snode.rightChild.refCount);

      //note: should copy line,col from root OR node
      {Link in new node in place of old C (which still exists & V2 now points to)}
      linkRightChild(snode,stemp);
      {Reset left node type, V1}
      snode.leftChild.nType:=ntOR;
      {and repoint it's right child to C (in its new position)
       Note: this is the second pointer to this sub-tree, so we save space & can re-use processing!}
      linkRightChild(snode.leftChild,snode.rightChild.rightChild);
      {now update the root node type}
      snode.nType:=ntAND; //done
    end;
    //Mirror... retaining original L..R order
    if (snode.nType=ntOR) and (snode.rightChild.ntype=ntAND) then
    begin
      {      V                    &
          C     &      ->     V2     V1
               A B           C  A   C  B
      }
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Pushing OR inside AND(r) at %p',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {create new left child, V2}
      stemp:=mkNode(srootAlloc,ntOR,ctUnknown,snode.leftChild{C},snode.rightChild.leftChild{A}); //note: memory
      {We're moving the sub-trees (C, A), not re-referencing them (yet), so don't update ref counts}
      dec(snode.leftChild.refCount);
      dec(snode.rightChild.leftChild.refCount);

      //note: should copy line,col from root OR node
      {Link in new node in place of old C (which still exists & V2 now points to)}
      linkLeftChild(snode,stemp);
      {Reset right node type, V1}
      snode.rightChild.nType:=ntOR;
      {and repoint it's left child to C (in its new position)
       Note: this is the second pointer to this sub-tree, so we save space & can re-use processing!}
      linkLeftChild(snode.rightChild,snode.leftChild.leftChild);
      {now update the root node type}
      snode.nType:=ntAND; //done
    end;

    //recurse down the tree (use infix order)
    if (snode.rightChild<>nil) then if PushORs(srootAlloc,snode.rightChild)<>ok then exit; //abort to avoid circles? possible if corrupt?

  end;
end; {PushORs}

function DeMorgan(srootAlloc:TSyntaxNodePtr;snode:TSyntaxNodePtr):integer;
{Pushes NOT nodes down into AND and OR nodes according to DeMorgan's laws
 IN             : snode           the original condition root
 OUT            : snode           points to the root of the updated tree
                                  (same physical node, but may have changed)
 RESULT         : ok, or fail if error

 Assumes:
   AND and OR always have two sub-trees, and NOT has only one left sub-tree
}
const routine=':deMorgan';
var
  stemp:TSyntaxNodePtr;
begin
  result:=ok;
  if snode<>nil then
  begin
    {Push NOT down inside AND}
    if (snode.nType=ntNOT) and (snode.leftChild.ntype=ntAND) then
    begin
      {      ¬                  V
          &            ->     ¬   ¬
         A B                 A   B
      }
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Pushing NOT inside AND at %p',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {Create a new NOT for the right child}
      stemp:=mkNode(srootAlloc,ntNOT,ctUnknown,snode.leftChild.rightChild,nil); //B now has two links
      {Link the new child to what will become the new OR}
      linkRightChild(snode,stemp);
      {Convert the AND to a NOT}
      snode.leftChild.nType:=ntNOT;
      {Unlink B from the converted NOT - it's now linked to the new NOT}
      unlinkRightChild(snode.leftChild);
      {Convert the root NOT to an OR}
      snode.nType:=ntOR;
    end;

    {Push NOT down inside OR}
    if (snode.nType=ntNOT) and (snode.leftChild.ntype=ntOR) then
    begin
      {      ¬                  &
          V            ->     ¬   ¬
         A B                 A   B
      }
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Pushing NOT inside OR at %p',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {Create a new NOT for the right child}
      stemp:=mkNode(srootAlloc,ntNOT,ctUnknown,snode.leftChild.rightChild,nil); //B now has two links
      {Link the new child to what will become the new AND}
      linkRightChild(snode,stemp);
      {Convert the OR to a NOT}
      snode.leftChild.nType:=ntNOT;
      {Unlink B from the converted NOT - it's now linked to the new NOT}
      unlinkRightChild(snode.leftChild);
      {Convert the root NOT to an AND}
      snode.nType:=ntAND;
    end;

    {Cancel NOTs}
    if (snode.nType=ntNOT) and (snode.leftChild.ntype=ntNOT) then
    begin
      {     ¬                  A                        NOP
          ¬            ->               actually->    NOP
         A                                           A
      }
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Cancelling out 2 NOTs at %p',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}
      {We daren't zap them (or replace the root) yet, in case other pointers to this tree are screwed up
       Instead we make the two NOTs NOPs}
      snode.nType:=ntNOP;
      snode.leftChild.nType:=ntNOP;
    end;


    //recurse down the tree
    if (snode.leftChild<>nil) then if DeMorgan(srootAlloc,snode.leftChild)<>ok then exit; //abort to avoid circles? possible if corrupt?
    if (snode.rightChild<>nil) then if DeMorgan(srootAlloc,snode.rightChild)<>ok then exit; //abort to avoid circles? possible if corrupt?

  end;
end; {DeMorgan}

function ChopANDs(var snode:TSyntaxNodePtr;tnode:TSyntaxNodePtr):integer;
{Chops single tree into separate chained sub-trees
 IN             : snode           the original condition root to chain everything to
                  tnode           the current root being examined (recursive)
 OUT            : snode           points to the root of the 1st sub-tree in chain
                                  (original root (tnode) may have been deleted)
 RESULT         : ok, or fail if error

 Assumes:
   AND always has two sub-trees
   snode has initially no chain

 Warning:
   if run twice on the same tree, this will reduce it by 1 subtree each time
}
const routine=':ChopANDs';
begin
  result:=ok;
  if tnode<>nil then
  begin
    //chain last first, so right sub-tree traveral first (post-order)
    if tnode.rightChild<>nil then //not needed - assume AND has two children?
      if tnode.nType=ntAND then
        if tnode.rightChild.nType<>ntAND then
        begin
          ChainNext(snode,tnode.rightChild);
          unlinkRightChild(tnode);
        end
        else
          result:=ChopANDs(snode,tnode.rightChild);

    if tnode.leftChild<>nil then //not needed - assume AND has two children?
      if tnode.nType=ntAND then
        if tnode.leftChild.nType<>ntAND then
        begin
          ChainNext(snode,tnode.leftChild);
          unlinkLeftChild(tnode);

          {if we've re-chained both children of this node, then we have no more use for it,
           so zap it now since(/if?) nothing else points to it}
          if (tnode<>snode) and (tnode.refCount<=1){no need, always 1?} and (tnode.rightChild=nil) then
          begin
          end;
        end
        else
          result:=ChopANDs(snode,tnode.leftChild);

    if tnode=snode then
    begin
      {old root, finally replace it with the new 1st chain root}
      //Warning: if run twice on the same tree, this will reduce it by 1 subtree each time
      if snode.nextNode<>nil then
      begin
        snode:=snode.nextNode;
      end;
    end;
  end;
end; {ChopANDs}

function CondToCNF(srootAlloc:TSyntaxNodePtr;var snode:TSyntaxNodePtr):integer;
{Converts a syntax tree condition into an equivalent chain of sub-trees
 in conjunctive normal form.
 IN             : snode           the original condition root (with no chain)
 OUT            : snode           points to the initial root in the chain
 RESULT         : ok, or fail if error

 Assumes:
   see sub-routines' assumptions
}
const routine=':condToCNF';
begin
//todo assert the assumptions & check no nil pointers
//        if any intermediate result<>ok then abort?!

  result:=ok;
  if snode.NextNode=nil then
  begin //virgin tree
    if snode<>nil then
    begin
      {$IFDEF DEBUG_LOG}
      log.add(who,where+routine,format('Converting %p to CNF',[snode]),vDebugMedium);
      {$ELSE}
      ;
      {$ENDIF}

      {Push NOT nodes down tree into AND and OR nodes}
      result:=DeMorgan(srootAlloc,snode);

      {Push OR nodes down tree into AND nodes}
      result:=PushORs(srootAlloc,snode);

      {Chop into separate chained sub-trees along the AND lines
       (AND nodes are all at top of tree now)
       Note: this will  probably change snode (1st param is var) to return}
      result:=ChopANDs(snode,snode);
    end;
  end
  else
    {$IFDEF DEBUG_LOG}
    log.add(who,where+routine,format('Syntax tree %p has already been converted to CNF - retaining...',[snode]),vDebugWarning);
    {$ELSE}
    ;
    {$ENDIF}
end; {CondToCNF}

end.

program ThinkSQL;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{$IFDEF WIN32}
  //{$DEFINE USE_APPLICATION} //Windows application.processMessages to prevent other apps. hanging (also in uMain)
  {$IFNDEF DEBUG_LOG} //use Delphi MM for development testing
    {$DEFINE USE_MULTIMM}     //Use Windows non-Borland memory manager (MultiMM)
  {$ENDIF}
{$ENDIF}

uses
  {$IFDEF USE_MULTIMM}  //Note: ensure this doesn't get lost when we add new units!
  MultiMM in 'MultiMM.pas',
  HPMM in 'HPMM.pas',
  {$ENDIF}
  {$IFDEF USE_APPLICATION}
  Forms,
  {$ENDIF}
  uLog in 'uLog.pas',
  uPage in 'uPage.pas',
  uGlobal in 'uGlobal.pas',
  uDatabase in 'uDatabase.pas',
  uServer in 'uServer.pas',
  uBuffer in 'uBuffer.pas',
  uHeapFile in 'uHeapFile.pas',
  uTuple in 'uTuple.pas',
  uRelation in 'uRelation.pas',
  uFile in 'uFile.pas',
  uTransaction in 'uTransaction.pas',
  uParser in 'uParser.pas',
  uSyntax in 'uSyntax.pas',
  uProcessor in 'uProcessor.pas',
  uAlgebra in 'uAlgebra.pas',
  uIterator in 'uIterator.pas',
  uOptimiser in 'uOptimiser.pas',
  uIterProject in 'uIterProject.pas',
  uIterSelect in 'uIterSelect.pas',
  uIterJoinNestedLoop in 'uIterJoinNestedLoop.pas',
  uIterRelation in 'uIterRelation.pas',
  uEvalCondExpr in 'uEvalCondExpr.pas',
  uCondToCNF in 'uCondToCNF.pas',
  uIterGroup in 'uIterGroup.pas',
  uIterMaterialise in 'uIterMaterialise.pas',
  uIterSyntaxRelation in 'uIterSyntaxRelation.pas',
  uIterInsert in 'uIterInsert.pas',
  uIterSort in 'uIterSort.pas',
  uIterJoinMerge in 'uIterJoinMerge.pas',
  uIterDelete in 'uIterDelete.pas',
  uGlobalDef in 'uGlobalDef.pas',
  uMain in 'uMain.pas',
  uConnectionMgr in 'uConnectionMgr.pas',
  uIterUpdate in 'uIterUpdate.pas',
  uCLIserver in 'uCLIserver.pas',
  uStmt in 'uStmt.pas',
  uConstraint in 'uConstraint.pas',
  uIndexFile in 'uIndexFile.pas',
  uHashIndexFile in 'uHashIndexFile.pas',
  uGarbage in 'uGarbage.pas',
  uVirtualFile in 'uVirtualFile.pas',
  uIterSet in 'uIterSet.pas',
  uIterJoin in 'uIterJoin.pas',
  uOS in 'uOS.pas',
  uIterStmt in 'uIterStmt.pas',
  uRoutine in 'uRoutine.pas',
  uVariableSet in 'uVariableSet.pas',
  uIterInto in 'uIterInto.pas',
  uTempTape in 'uTempTape.pas',
  uDatabaseMaint in 'uDatabaseMaint.pas';

{$IFDEF WIN32}
{$R *.RES}
{$R version.RES}
{$ENDIF}

begin
  {$IFDEF WIN32}
  {$IFDEF USE_APPLICATION}
    Application.Initialize; //note: only needed for OLE automation?
    Application.Title := 'ThinkSQL';
  Application.Run; //start Window message processing loop
  {$ENDIF}
  {$ENDIF}
  uMain.main;
end.

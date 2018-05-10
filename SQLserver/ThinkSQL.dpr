program ThinkSQL;

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}
{$I Defs.inc}
{.$I Optional.use} // this include must be at the top of the uses clause bellow. Adding and removing files from the project deletes it.
uses
  {$I Optional.use}
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
  uDatabaseMaint in 'uDatabaseMaint.pas',
  uMarshalGlobal in '..\Odbc\uMarshalGlobal.pas',
  uMarshal in '..\Odbc\uMarshal.pas',
  uEvsHelpers in 'uEvsHelpers.pas',
  uThinkSQLAPI in '..\Evosi\uThinkSQLAPI.pas';

{$IFDEF WIN32}
{$R *.RES}
{$R version.RES}
{$ENDIF}

begin
  {$IFDEF WINDOWNS}
  {$IFDEF USE_APPLICATION}
    Application.Initialize; //note: only needed for OLE automation?
    Application.Title := 'ThinkSQL';
  Application.Run; //start Window message processing loop
  {$ENDIF}
  {$ENDIF}
  uMain.main;
end.

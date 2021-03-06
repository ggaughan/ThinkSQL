title ThinkSQL ODBC Driver Setup

"c:\program files\borland\delphi5\bin\brcc32" version.rc >build.log

if exist ThinkSQLodbcSetup.cfg (
	findstr /R /I /V "^-D" ThinkSQLodbcSetup.cfg >dcc32.cfg

	del ThinkSQLodbcSetup.cfg  
)

echo %date% %time% >>build.log

if /I "%1"=="TEST" (
	echo TEST >>build.log
	"c:\program files\borland\delphi5\bin\dcc32" -B -DDEBUG_LOG ThinkSQLodbcSetup.dpr >>build.log
) else (
	echo LIVE >>build.log
	"c:\program files\borland\delphi5\bin\dcc32" -B -$O+ -$R- -$Q- ThinkSQLodbcSetup.dpr >>build.log

       copy ThinkSQLodbcSetup.exe c:\ThinkSQLSource >>build.log
       copy ThinkSQLodbcSetup.dll c:\ThinkSQLSource >>build.log

	echo ThinkSQLodbcSetup: >>c:\ThinkSQLSource\success.log
	findstr /R "^[0-9] lines, " build.log >>c:\ThinkSQLSource\success.log
) 
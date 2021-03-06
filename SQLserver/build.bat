title ThinkSQL Server

"c:\program files\borland\delphi5\bin\brcc32" version.rc >build.log

if exist thinksql.cfg (
	findstr /R /I /V "^-D" thinksql.cfg >dcc32.cfg

	del thinksql.cfg  
)

echo %date% %time% >>build.log

if /I "%1"=="TEST" (
	echo TEST >>build.log
	"c:\program files\borland\delphi5\bin\dcc32" -B -DDEBUG_LOG thinksql.dpr >>build.log
) else (
	echo LIVE >>build.log
	"c:\program files\borland\delphi5\bin\dcc32" -B -$O+ -$R- -$Q- thinksql.dpr >>build.log

       copy thinksql.exe c:\ThinkSQLSource >>build.log
       copy thinksql.dll c:\ThinkSQLSource >>build.log

	echo thinksql: >>c:\ThinkSQLSource\success.log
	findstr /R "^[0-9] lines, " build.log >>c:\ThinkSQLSource\success.log
) 
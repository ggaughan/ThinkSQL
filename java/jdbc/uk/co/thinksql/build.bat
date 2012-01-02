title ThinkSQL JDBC Driver

echo %date% %time% >build.log

del C:\Java\jdbc\uk\co\thinksql\*.class
"C:\jdk1.3.1\bin\javac" -classpath c:\java\jdbc ThinkSQLDriver.java >>build.log
cd c:\java\jdbc
call C:\Java\jdbc\makeJar.bat

copy ThinkSQLDriver.jar c:\ThinkSQLSource >>build.log
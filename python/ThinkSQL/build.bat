title Python DB-API module

echo %date% %time% >build.log

python setup.py sdist >>build.log

copy dist\ThinkSQL*.zip c:\ThinkSQLSource >>build.log
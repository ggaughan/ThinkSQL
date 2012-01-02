A Pure Python DB-API 2.0 compliant interface to ThinkSQL

            Copyright © 2000-2012  Greg Gaughan

               http://www.thinksql.co.uk
========================================================

Installation
------------
Unpack the file to a temporary directory and run:

  python setup.py install


Usage
-----
Import the module into a Python program and create connections and cursors e.g.

    import ThinkSQL
    
    test=ThinkSQL.connect(host='localhost', user='RESTAURANT')
    
    results1=test.cursor()
    
    results1.execute("SELECT * FROM MENU_ITEM_GROUP")
    
    print [col[0] for col in results1.description]  #display the column headers
    
    for row in results1:
        print row
    
    results1.close()
    test.close()


Notes
-----
cursor.fetchmany(size) with a size>1 is much more efficient than repeated 
calls to fetchone() because the server returns multiple result rows at once.

cursor.executemany() with a sequence of parameter lists is much more 
efficient than repeated calls to execute() because the SQL statement is 
automatically prepared once (parsed, security checked, optimised etc.) and 
then subsequent executions just involve parameter passing.

Use ThinkSQL.Binary(bdata) to pass bdata as a BLOB parameter, e.g.
    ...
    bdata=open('image.jpg','rb').read()
    s1.execute("INSERT INTO picture_table (image) VALUES (?)", (ThinkSQL.Binary(bdata),))

You can use the standard type objects to check the column type, e.g.
    if results1.description[0][1]==ThinkSQL.NUMBER:
       #column 0 is numeric...
       
Ensure the fixedpoint module <http://fixedpoint.sourceforge.net/> is installed
for accurate NUMERIC/DECIMAL results.       
       
History
-------
01.03.01
Increased default timeout to 30 seconds

01.03.00
Initial release included with ThinkSQL server

01.02.03:
Return numeric/decimals as FixedPoint if the module is available.
Return date/time/timestamps as datetime.date/time/datetimes

01.02.02:
Fix bug with column count

01.02.01:
Fix blob buffer read/write

01.02.00
Initial release

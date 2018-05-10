select * from 
Table1
 LEFT OUTER JOIN
 Table2
 ON Table1.a = Table2.a      -- join condition
    AND Table2.c = 't';      -- single table condition
    


SELECT * FROM
(select 1 from (values(1)) as Z) as W , 
(select * from (select * from "first" left OUTER JOIN second ON ("first".B=second.B)) as X) as Y

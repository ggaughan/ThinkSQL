CREATE USER GROUPTEST;
CREATE SCHEMA "GROUPTEST" AUTHORIZATION "GROUPTEST"
  Create table A1
  (Descrizione varchar(50),
  Qty float)
  
  Create table A2
  (Descrizione varchar(50),
  Qty float)
;

COMMIT;

CONNECT TO 'THINKSQL' USER 'GROUPTEST';

insert into A1 values ('Mele',10),('Mele', 15),('Pere', 5),('Pere', 7);
insert into A2 values ('Mele', 3),('Mele', 4),('Pere', 5),('Pere', 3);

COMMIT; 

SELECT * FROM A1;
SELECT * FROM A2;
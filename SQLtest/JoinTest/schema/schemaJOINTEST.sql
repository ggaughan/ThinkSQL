CREATE USER JOINTEST;
CREATE SCHEMA "JOINTEST" AUTHORIZATION "JOINTEST"
	CREATE TABLE "FIRST"	(ONE INTEGER not null,
				 B VARCHAR(10),
				 PRIMARY KEY (ONE) )
				
	CREATE TABLE SECOND	(TWO INTEGER not null,
				 B VARCHAR(10),
				 PRIMARY KEY (TWO) )
				 
	create table table1(a integer, b char(1))
	create table table2(a integer, c char(1))
	
	create table t1(c1 integer not null primary key)
	create table t2(c1 integer not null primary key)
;

COMMIT;

CONNECT TO 'THINKSQL' USER 'JOINTEST';

INSERT INTO "FIRST" VALUES	(1,'A');
INSERT INTO "FIRST" VALUES	(3,'C');
INSERT INTO "FIRST" VALUES	(4,'D');

INSERT INTO SECOND VALUES	(1,'A');
INSERT INTO SECOND VALUES	(2,'B');
INSERT INTO SECOND VALUES	(4,'D');


insert into table1 values (1,'w'),(2,'x'),(3,'y'),(4,'z');
insert into table2 values (1,'r'),(2,'s'),(3,'t');

insert into t1 values (1),(2),(3),(5);
insert into t2 values (2),(4),(5),(7);


COMMIT; 

SELECT * FROM "FIRST";
SELECT * FROM SECOND;

SELECT * FROM table1;
SELECT * FROM table2;

SELECT * FROM t1;
SELECT * FROM t2;

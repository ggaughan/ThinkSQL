-- RI test 9
create table parent (id integer not null primary key, name varchar(10));
create table child (id integer not null primary key, parent_id integer references parent ON UPDATE SET NULL, name varchar(10));
create table grandchild (id integer not null primary key, parent_id integer references child, name varchar(10));
insert into parent values (1,'Main'), (2,'Second');
insert into child values (10,1,'MainA'),(20,1,'MainB'),(30,1,'MainC'),(40,2,'SecondA');
insert into grandchild values (100,30,'MainCc');

select * from parent;
select * from child;
select * from grandchild;

update parent set id=5 where id=1;
-- EXPECT succeed & children 10-30 parent=NULL: grandchild exists, but so what

select * from parent;
select * from child;
select * from grandchild;

ROLLBACK;

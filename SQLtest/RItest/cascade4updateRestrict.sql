-- RI test 4
create table parent (id integer not null primary key, name varchar(10));
create table child (id integer not null primary key, parent_id integer references parent ON DELETE CASCADE ON UPDATE CASCADE, name varchar(10));
create table grandchild (id integer not null primary key, parent_id integer references child ON DELETE CASCADE, name varchar(10));
insert into parent values (1,'Main'), (2,'Second');
insert into child values (10,1,'MainA'),(20,1,'MainB'),(30,1,'MainC'),(40,2,'SecondA');
insert into grandchild values (100,30,'MainCc');

select * from parent;
select * from child;
select * from grandchild;

update parent set id=5 where id=1;
-- EXPECT succeed: grandchild exists, so what

update parent set id=6 where id=2;
-- EXPECT succeed: grandchild cascades

select * from parent;
select * from child;
select * from grandchild;

ROLLBACK;

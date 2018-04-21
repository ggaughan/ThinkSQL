-- RI Test 14

create table selfparent (id integer not null primary key, pid integer references selfparent ON UPDATE SET NULL, name varchar(10));
insert into selfparent values (1,2,'A'), (2,3,'B'), (3,1,'C');

select * from selfparent;

update selfparent set id=11 where id=1;
-- EXPECT: succeed: child set null 

select * from selfparent;

ROLLBACK;

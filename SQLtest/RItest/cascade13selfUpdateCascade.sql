-- RI Test 13

create table selfparent (id integer not null primary key, pid integer references selfparent ON DELETE CASCADE ON UPDATE CASCADE, name varchar(10));
insert into selfparent values (1,2,'A'), (2,3,'B'), (3,1,'C');

select * from selfparent;

update selfparent set id=10 where id=1;
-- EXPECT: succceed: child cascades 

select * from selfparent;

ROLLBACK;

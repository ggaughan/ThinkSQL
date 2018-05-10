-- RI Test 10

create table selfparent (id integer not null primary key, pid integer references selfparent, name varchar(10));
insert into selfparent values (1,2,'A'), (2,3,'B'), (3,1,'C');

select * from selfparent;

delete from selfparent where id=1;
-- EXPECT: fail: child exists

select * from selfparent;

ROLLBACK;

-- RI Test 15

create table selfparent (id integer not null primary key, pid integer references selfparent ON DELETE SET NULL, name varchar(10));
insert into selfparent values (1,2,'A'), (2,3,'B'), (3,1,'C');

select * from selfparent;

delete from selfparent where id=1;
-- EXPECT: succceed: child cascade delete 

select * from selfparent;

ROLLBACK;

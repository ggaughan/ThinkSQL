-- RI Test 16 from Bruce Horowitz IDEC 1992

create table T (C1 char(2) not null primary key, C2 char(2) references T(C1) ON UPDATE CASCADE);

insert into T values ('v1','v2'),('v2','v1');

select * from T;

update T set C1=C2;
-- EXPECT: 
--	ideal = (v2,v1),(v1,v2)
--	could give (v2,v1),(v1,v1) or (v2,v2),(v1,v2) depending on update order
--	actually fails with (as at 26/05/02) PK constraint error because duplicates at end of stmt
--		- caused because update sees cascaded action results
--			- could fix by making invisible, but usually(?) want to respect cascade actions immediately, e.g. deletes?
--			- tried this: but need to be visible for child FK insert parent-check
--			- tried being clever & got non-ideal result, but simple self-cascade update then failed
--			- for now, tough...

select * from T;

ROLLBACK;

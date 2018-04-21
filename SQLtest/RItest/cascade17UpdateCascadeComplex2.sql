-- RI Test 17 from Bruce Horowitz IDEC 1992

--currently cannot chicken & egg these definitions, so safe... but when we can check it!
create table T1 (A char(2) not null primary key references T2(B) ON UPDATE CASCADE);
create table T2 (B char(2) not null primary key references T1(A) ON UPDATE CASCADE);

insert into T1 values ('v1');
insert into T2 values ('v1');

select * from T1;
select * from T2;

update T1 set A='v2' WHERE A='v1';
-- EXPECT: 
--	ideal = stop infinte loop by detecting update of same (for use, versioning should help?)
--	could give infinite loop
--	actually fails with (as at 26/05/02) PK constraint error because duplicates at end of stmt

select * from T1;
select * from T2;

ROLLBACK;

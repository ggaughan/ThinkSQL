drop table calendar restrict;

create table calendar (calendar_id integer not null primary key, left_pin integer);
insert into calendar values (1,2), (3,4), (5,6);

drop procedure p_testproc restrict;
commit;
create procedure p_testproc()
begin
  declare a, b integer;

  set a = 0;

  declare curs cursor for
    select
      calendar_id
    from
      calendar
    where
      left_pin >= a
    for read only;

  open curs;
  fetch curs into b;

  while sqlstate<>'02000' do
    debug print b;
    
    fetch curs into b;
  end while;

  close curs;

end;
commit;

call p_testproc()
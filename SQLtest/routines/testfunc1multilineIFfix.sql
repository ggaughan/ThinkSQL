drop function testfunc1 restrict;

create function testfunc1() returns numeric(6,2)
begin 
  declare r numeric(6,2);
 
  if current_user in ('restaurant','settest') then
    select max(price) into r from restaurant.menu_item;
  else
    set r=null;
    set r=3.14;
    set r=0.00;
  end if;

  return r;
end;

values(testfunc1());
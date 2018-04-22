create function test1(a integer) returns integer
begin
  return (select max(menu_item_no) from restaurant.menu_item);
end;
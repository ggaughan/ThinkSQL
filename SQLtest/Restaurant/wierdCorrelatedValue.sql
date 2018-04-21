-- A bit strange, but we allow it (correlated value) - should just return 1st row 
select * from menu_item where price=(select * from (values (menu_item.price)) as Y)

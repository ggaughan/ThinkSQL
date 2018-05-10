select 'Joe''s Restaurant recommends for your '
    || menu_item_group_name
    || ': '
    || menu_item_name
  from menu_item       a,
       menu_item_group b
 where a.menu_item_group_no = b.menu_item_group_no 
   and menu_item_no = (select min(menu_item_no)
                         from menu_item
                        where menu_item_group_no = a.menu_item_group_no
                          and price = (select max(price)
                                           from menu_item
                                          where menu_item_group_no =
a.menu_item_group_no) ) 
SELECT A.menu_item_name as menu_item_name
FROM db1.restaurant.menu_item A, menu_item B
WHERE A.menu_item_no=B.menu_item_no
ORDER BY menu_item_name
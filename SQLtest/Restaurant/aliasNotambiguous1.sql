SELECT A.menu_item_name, B.menu_item_name
FROM db1.restaurant.menu_item A, menu_item B
WHERE A.menu_item_no=B.menu_item_no
ORDER BY B.menu_item_name
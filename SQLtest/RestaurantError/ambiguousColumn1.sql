--Error
SELECT
a.menu_item_no , b.menu_item_no 
FROM
menu_item a , menu_item b 
WHERE a.menu_item_no = b.menu_item_no
AND a.menu_item_no = 1
ORDER BY menu_item_no   --needs a prefix!

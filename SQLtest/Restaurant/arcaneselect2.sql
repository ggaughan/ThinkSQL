SELECT *
FROM menu_item
where price > all
(select price from menu_item
where price < 4.00)
-- slow subquery
SELECT *
FROM menu_item
where price not in (
select price from menu_item where price in (1.20, 5.45))
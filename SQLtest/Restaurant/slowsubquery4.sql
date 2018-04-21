-- slow subquery - is correlated
SELECT *
FROM menu_item
where price not in (
select price from menu_item I where (select count(*) from menu_item I2 where I.price=I2.price)>1
)
--Hmmm, this took 13 seconds on a PentiumII/350 MHz.
SELECT *
FROM menu_item
where price not in (
select price from menu_item where price in (
select price from menu_item where price >= 1.20 and price <= 1.20
and price >= 5.45 and price <= 5.45
))


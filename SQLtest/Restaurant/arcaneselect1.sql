-- arcane select queries...
SELECT *
FROM menu_item
where price <> ANY
(select price from menu_item
where price = 1.20)
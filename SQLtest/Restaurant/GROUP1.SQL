-- complex aggregates & grouping seems to work
SELECT menu_item_group_no, sum(price), avg(price), count(*)
FROM menu_item
group by  menu_item_group_no
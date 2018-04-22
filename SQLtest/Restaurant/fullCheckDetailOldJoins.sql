SELECT * 
FROM 
	RESTAURANT."SERVER", 
	RESTAURANT.CHECK_HEADER,
	RESTAURANT.MENU_ITEM_GROUP, 
	RESTAURANT.MENU_ITEM, 
	RESTAURANT.CHECK_DETAIL
WHERE
"server".server_no=check_header.server_no
and check_header.check_no=check_detail.check_no
and menu_item.menu_item_no=check_detail.menu_item_no
and menu_item.menu_item_group_no=menu_item_group.menu_item_group_no
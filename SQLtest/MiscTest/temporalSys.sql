-- Always should fail!
SELECT CURRENT_DATE, CURRENT_TIME, CURRENT_TIMESTAMP
FROM (VALUES(1)) AS X
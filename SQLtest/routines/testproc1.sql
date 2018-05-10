-- testproc1
-- Tests multiple cursors, if in loop and return cursors

CREATE PROCEDURE testproc1()
BEGIN
  DECLARE testproc1internal CURSOR FOR
    SELECT menu_item_no FROM restaurant.menu_item;

  CREATE LOCAL TEMPORARY TABLE testproc1table(n INTEGER);

  DECLARE testproc1return CURSOR WITH RETURN FOR
    SELECT * FROM testproc1table;

  DECLARE a INTEGER;
  OPEN testproc1internal;
  WHILE SQLSTATE<>'02000' DO
    FETCH testproc1internal INTO a;
    IF a>=300 THEN
      INSERT INTO testproc1table VALUES (a);
    END IF;
  END WHILE;
  CLOSE testproc1internal;

  OPEN testproc1return;
END;

-----------------

CALL testproc1();
DROP TABLE testproc1table CASCADE;  --not required once LOCAL TEMPORARY TABLE is implemented

CALL testproc1();
DROP TABLE testproc1table CASCADE;  --not required once LOCAL TEMPORARY TABLE is implemented


ROLLBACK;
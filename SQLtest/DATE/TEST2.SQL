select * from P
where (WEIGHT,WEIGHT)=(select WEIGHT,WEIGHT from P where WEIGHT=14)
;
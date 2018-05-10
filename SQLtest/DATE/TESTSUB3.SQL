select * from S 
where
STATUS=(select max(STATUS) from S)
or STATUS=(select min(STATUS) from S)
;
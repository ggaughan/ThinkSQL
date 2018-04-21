select SNAME, CITY, count(*)
from S
group by CITY
having count(*)>1
;
select sno, sname, status city, pct, apct
from s
natural join 
  ( select sno, count(*) as pct
    from sp
    group by sp.sno ) as pointless1
  natural join 
  ( select city, avg(pct) as apct
    from s
       natural join 
       ( select sno, count(*) as pct
         from sp
         group by sno ) as pointless2
    group by city ) as pointless3
where pct>apct
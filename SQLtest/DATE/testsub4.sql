select distinct s.sname
from s
where s.sno in 
  ( select sp.sno
    from sp
    where sp.pno in
      ( select p.pno
        from p
        where p.color='red' ) )
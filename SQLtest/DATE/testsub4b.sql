select distinct sname
from s
where sno in 
  ( select sno
    from sp
    where pno in
      ( select pno
        from p
        where color='red' ) )
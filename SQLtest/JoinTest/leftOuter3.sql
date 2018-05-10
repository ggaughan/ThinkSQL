--Compare with leftOuter2 which uses nestedLoop rather than mergeJoin 
select * from "first" left outer join second using (b);

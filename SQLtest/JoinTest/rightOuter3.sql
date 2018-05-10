--Compare with rightOuter2 which uses nestedLoop rather than mergeJoin 
select * from "first" right outer join second using (b)
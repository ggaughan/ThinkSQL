--Compare with rightOuter3 which uses mergeJoin rather than nestedLoop
select "first".b,one,two from "first" right outer join second on ("first".b=second.b);

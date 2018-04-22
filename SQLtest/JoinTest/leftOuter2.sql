--Compare with leftOuter3 which uses mergeJoin rather than nestedLoop
select "first".b,one,two from "first" left outer join second on ("first".b=second.b);

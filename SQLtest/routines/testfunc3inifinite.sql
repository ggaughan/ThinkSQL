create function test1(a integer) returns integer
begin
  declare b integer default 0;

  loop
    set b=b+1;
  end loop;

end;
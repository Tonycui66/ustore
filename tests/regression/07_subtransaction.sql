-- =========================================================================
-- 07_subtransaction.sql
-- 子事务可见性与回滚边界 (undo CONTAINS_SUBXACT 路径)
-- =========================================================================
drop table if exists ust_sub_t;
create table ust_sub_t (id int primary key, v int) with (storage_type=ustore);

insert into ust_sub_t values (1, 10), (2, 20), (3, 30);

-- 子事务函数: 内部失败只回滚子块
create or replace function fn_sub_update() returns int language plpgsql as $$
declare
  lv int;
begin
  perform * from ust_sub_t where 1=0; -- noop
  begin
    update ust_sub_t set v = v + 1 where id = 1;
    -- 触发异常 -> 子块回滚
    raise exception 'must_rollback_subxact';
  exception when others then
    raise notice 'subxact rolled back';
  end;
  return 0;
end $$;

select fn_sub_update();
select v from ust_sub_t where id = 1;   -- 仍为 10

-- savepoint 内套子事务: 回滚嵌套后外层保持
do $$
begin
  update ust_sub_t set v = v + 1 where id = 2;
  savepoint sp_outer;
  begin
    update ust_sub_t set v = v + 1 where id = 3;
    raise exception 'nested_fail';
  exception when others then
    rollback to sp_outer;
  end;
end $$;
select * from ust_sub_t order by id;  -- id2=21, id3=30

drop table ust_sub_t;
drop function fn_sub_update();

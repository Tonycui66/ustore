\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 07_subtransaction.sql
-- 子事务可见性与回滚边界 (undo CONTAINS_SUBXACT 路径)
-- =========================================================================

drop table if exists ust_sub_t;
drop function if exists fn_sub_update();

create table ust_sub_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_sub_t values (1, 10), (2, 20), (3, 30);

-- 异常块产生子事务，异常只回滚内部修改。
create or replace function fn_sub_update() returns int
language plpgsql
as $$
begin
    begin
        update ust_sub_t set v = v + 1 where id = 1;
        raise exception 'must_rollback_subxact';
    exception when others then
        null;
    end;
    return 0;
end;
$$;

select fn_sub_update();
select pg_temp.ustore_assert_eq(
    (select v from ust_sub_t where id = 1),
    10,
    'exception subtransaction must roll back its own update'
);

-- 内层子事务失败，不得撤销外层更新。
do $$
begin
    update ust_sub_t set v = v + 1 where id = 2;
    begin
        update ust_sub_t set v = v + 1 where id = 3;
        raise exception 'nested_fail';
    exception when others then
        null;
    end;
end;
$$;

select pg_temp.ustore_assert_eq(
    (select v from ust_sub_t where id = 2),
    21,
    'outer update must survive an inner subtransaction rollback'
);
select pg_temp.ustore_assert_eq(
    (select v from ust_sub_t where id = 3),
    30,
    'inner subtransaction update must be rolled back'
);

drop table ust_sub_t;
drop function fn_sub_update();

\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 06_transaction_rollback.sql
-- 回滚 / undo 应用: 整事务、savepoint、undo 链和事务边界
-- =========================================================================

drop table if exists ust_rb_t;
create table ust_rb_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_rb_t
select g, g * 10
  from generate_series(1, 100) g;

begin;
    update ust_rb_t set v = -1 where id <= 50;
    delete from ust_rb_t where id > 50;
rollback;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_rb_t),
    100::bigint,
    'full rollback must restore deleted rows'
);
select pg_temp.ustore_assert_eq(
    (
        select count(*)
          from ust_rb_t
         where id <= 50
           and v = id * 10
    ),
    50::bigint,
    'full rollback must restore all updated values'
);

-- Savepoint 只撤销子块，保留 savepoint 之前的更新。
begin;
    update ust_rb_t set v = v + 1 where id = 1;
    savepoint sp1;
    update ust_rb_t set v = v + 100 where id = 1;
    rollback to savepoint sp1;
    select pg_temp.ustore_assert_eq(
        (select v from ust_rb_t where id = 1),
        11,
        'ROLLBACK TO SAVEPOINT must keep the outer update'
    );
    update ust_rb_t set v = v + 10 where id = 1;
commit;
select pg_temp.ustore_assert_eq(
    (select v from ust_rb_t where id = 1),
    21,
    'savepoint rollback must preserve the intended final value'
);

-- 同一行在 undo 链上连续更新后整体回滚。
begin;
    update ust_rb_t set v = 1 where id = 2;
    update ust_rb_t set v = 2 where id = 2;
    update ust_rb_t set v = 3 where id = 2;
rollback;
select pg_temp.ustore_assert_eq(
    (select v from ust_rb_t where id = 2),
    20,
    'multi-update undo chain must restore the original value'
);

begin;
    update ust_rb_t set v = 999 where id = 3;
commit;
begin;
    update ust_rb_t set v = -999 where id = 4;
rollback;
select pg_temp.ustore_assert_eq(
    (select v from ust_rb_t where id = 3),
    999,
    'committed transaction must survive a later rollback'
);
select pg_temp.ustore_assert_eq(
    (select v from ust_rb_t where id = 4),
    40,
    'rolled-back transaction must not affect committed rows'
);

drop table ust_rb_t;

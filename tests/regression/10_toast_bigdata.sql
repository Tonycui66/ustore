\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 10_toast_bigdata.sql
-- 大字段/TOAST: 插入、更新、部分回滚、整体回滚和删除
-- =========================================================================

drop table if exists ust_toast_t;
create table ust_toast_t (
    id int primary key,
    big text
) with (storage_type=ustore);

insert into ust_toast_t values
    (1, repeat('x', 20000)),
    (2, repeat('y', 30000));

select pg_temp.ustore_assert_true(
    exists (
        select 1
          from pg_class
         where oid = 'ust_toast_t'::regclass
           and reltoastrelid <> 0
    ),
    'large USTORE tuple must create a TOAST relation'
);
select pg_temp.ustore_assert_eq(
    (select length(big) from ust_toast_t where id = 1),
    20000,
    '20K TOAST value must be readable without truncation'
);
select pg_temp.ustore_assert_eq(
    (select length(big) from ust_toast_t where id = 2),
    30000,
    '30K TOAST value must be readable without truncation'
);

begin;
    update ust_toast_t set big = repeat('z', 40000) where id = 1;
    savepoint sp;
    update ust_toast_t set big = repeat('w', 60000) where id = 1;
    rollback to savepoint sp;
    select pg_temp.ustore_assert_eq(
        (select length(big) from ust_toast_t where id = 1),
        40000,
        'ROLLBACK TO SAVEPOINT must preserve the first large value'
    );
rollback;

select pg_temp.ustore_assert_eq(
    (select length(big) from ust_toast_t where id = 1),
    20000,
    'full rollback must restore the original TOAST value'
);
select pg_temp.ustore_assert_eq(
    (select sum(length(big)) from ust_toast_t),
    50000::bigint,
    'all TOAST values must remain readable after rollback'
);

delete from ust_toast_t where id = 2;
vacuum (analyze) ust_toast_t;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_toast_t),
    1::bigint,
    'TOAST tuple deletion must remove exactly the selected row'
);

drop table ust_toast_t;

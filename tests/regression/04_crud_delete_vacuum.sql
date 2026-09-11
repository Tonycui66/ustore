\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 04_crud_delete_vacuum.sql
-- USTORE 删除、空间复用、VACUUM 和删除回滚
-- =========================================================================

drop table if exists ust_delete_t;
create table ust_delete_t (
    id int primary key,
    v text
) with (storage_type=ustore);

insert into ust_delete_t
select g, 'val-' || g
  from generate_series(1, 2000) g;

delete from ust_delete_t where id % 10 = 0;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_delete_t),
    1800::bigint,
    'partial delete must leave exactly 1800 visible rows'
);

delete from ust_delete_t where id between 1 and 500;
insert into ust_delete_t
select 100000 + g, 'reuse-' || g
  from generate_series(1, 500) g;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_delete_t),
    1800::bigint,
    'reinserted rows must replace the deleted row count'
);

vacuum (analyze) ust_delete_t;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_delete_t),
    1800::bigint,
    'VACUUM must not change visible row count'
);

begin;
    delete from ust_delete_t where id >= 100000;
rollback;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_delete_t where id >= 100000),
    500::bigint,
    'rollback must restore all rows deleted in the transaction'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_delete_t),
    1800::bigint,
    'rollback must restore the complete visible row count'
);

drop table ust_delete_t;

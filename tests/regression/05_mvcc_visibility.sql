\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 05_mvcc_visibility.sql
-- USTORE 单会话 MVCC 语义
-- 跨事务隔离和锁等待由 tests/concurrency/08_run.sh 验证。
-- =========================================================================

drop table if exists ust_mvcc_t;
create table ust_mvcc_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_mvcc_t values (1, 10), (2, 20), (3, 30);

begin;
    update ust_mvcc_t set v = v + 1 where id = 1;
    select pg_temp.ustore_assert_eq(
        (select v from ust_mvcc_t where id = 1),
        11,
        'current transaction must see its own update'
    );
rollback;
select pg_temp.ustore_assert_eq(
    (select v from ust_mvcc_t where id = 1),
    10,
    'rollback must restore the old version'
);

begin isolation level repeatable read;
    select pg_temp.ustore_assert_eq(
        (select sum(v) from ust_mvcc_t),
        60::bigint,
        'repeatable-read transaction must see the initial snapshot'
    );
    update ust_mvcc_t set v = v + 100 where id = 2;
    select pg_temp.ustore_assert_eq(
        (select v from ust_mvcc_t where id = 2),
        120,
        'repeatable-read transaction must see its own update'
    );
commit;
select pg_temp.ustore_assert_eq(
    (select sum(v) from ust_mvcc_t),
    160::bigint,
    'committed update must be visible to the next transaction'
);

begin isolation level serializable read only;
    select pg_temp.ustore_assert_eq(
        (select sum(v) from ust_mvcc_t),
        160::bigint,
        'serializable read-only snapshot must contain committed changes'
    );
commit;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_mvcc_t),
    3::bigint,
    'MVCC snapshot must not create phantom rows'
);

drop table ust_mvcc_t;

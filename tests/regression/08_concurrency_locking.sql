\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 08_concurrency_locking.sql
-- 单会话锁语法与重复更新冒烟测试
-- 真正的多会话锁等待、超时和提交后重试由 tests/concurrency/08_run.sh 执行。
-- =========================================================================

drop table if exists ust_conc_t;
create table ust_conc_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_conc_t values (1, 1), (2, 2), (3, 3);

begin;
    select id, v from ust_conc_t where id = 1 for update;
rollback;
begin;
    select id, v from ust_conc_t where id = 1 for no key update;
rollback;
begin;
    select id, v from ust_conc_t where id = 1 for share;
rollback;
begin;
    select id, v from ust_conc_t where id = 1 for key share;
rollback;

do $$
begin
    for i in 1..50 loop
        update ust_conc_t set v = v + 1 where id = 2;
    end loop;
end;
$$;
select pg_temp.ustore_assert_eq(
    (select v from ust_conc_t where id = 2),
    52,
    '50 repeated updates must accumulate without lost updates'
);

set lock_timeout = '50ms';
reset lock_timeout;

\echo 'Run tests/concurrency/08_run.sh for real multi-session lock tests.'

drop table ust_conc_t;

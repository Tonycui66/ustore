\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 12_fault_injection_whitebox.sql
-- 白盒故障注入后的数据一致性检查
--
-- 该脚本不能单独制造故障。执行器必须先在目标构建中启用 WHITEBOX 并设置桩，
-- 然后运行本脚本检查注入失败后的表、索引和事务状态。
-- =========================================================================

drop table if exists ust_wb_t;
create table ust_wb_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_wb_t
select g, g
  from generate_series(1, 50) g;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_wb_t),
    50::bigint,
    'fault-injection fixture must contain all rows'
);

\echo 'Arm an UHEAP_* or UNDO_* whitebox stub, run the target DML/rollback, then rerun the checks below.'

-- 目标 DML 注入失败后，若事务已回滚，以下两项必须成立。
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_wb_t),
    50::bigint,
    'failed DML must not leave partially visible rows'
);
select pg_temp.ustore_assert_true(
    (select min(v) >= 1 and max(v) <= 50 from ust_wb_t),
    'all row values must remain within the original range after rollback'
);

drop table ust_wb_t;

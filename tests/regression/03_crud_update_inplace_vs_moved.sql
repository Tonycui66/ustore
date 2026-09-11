\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 03_crud_update_inplace_vs_moved.sql
-- USTORE 更新语义: 等宽更新、增宽更新、键列更新、回滚
-- 说明: 本脚本验证黑盒语义；in-place/moved 的页级判定需白盒或 pagehack。
-- =========================================================================

drop table if exists ust_update_t;
create table ust_update_t (
    id int primary key,
    c int,
    padding varchar(200)
) with (storage_type=ustore);

insert into ust_update_t
select g, 0, 'AAAAAAAAAA'
  from generate_series(1, 100) g;

begin;
    update ust_update_t set c = c + 1 where id between 1 and 100;
    update ust_update_t set c = c + 1 where id between 1 and 100;
commit;

select pg_temp.ustore_assert_eq(
    (select min(c) from ust_update_t),
    2,
    'all rows must reach c=2 after two repeated in-place updates'
);
select pg_temp.ustore_assert_eq(
    (select max(c) from ust_update_t),
    2,
    'no row may be lost or updated an unexpected number of times'
);

-- 增宽更新后读取新值。
update ust_update_t
   set padding = repeat('B', 150)
 where id = 1;
select pg_temp.ustore_assert_eq(
    (select length(padding) from ust_update_t where id = 1),
    150,
    'widening update must expose the new value'
);

-- 回滚增宽更新后必须恢复旧值。
begin;
    update ust_update_t set padding = repeat('C', 180) where id = 2;
rollback;
select pg_temp.ustore_assert_eq(
    (select length(padding) from ust_update_t where id = 2),
    10,
    'rollback must restore the old tuple version after a widening update'
);

-- 键列更新必须同步维护 UBtree。
begin;
    update ust_update_t set id = id + 10000 where id = 3;
commit;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_update_t where id = 3),
    0::bigint,
    'old key must not remain visible after key update'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_update_t where id = 10003),
    1::bigint,
    'new key must be visible after key update'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_update_t),
    100::bigint,
    'key update must not duplicate or lose rows'
);

drop table ust_update_t;

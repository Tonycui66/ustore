\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 02_crud_insert.sql
-- USTORE 插入: 单行 / 批量 / INSERT..SELECT / 回滚 / 约束
-- =========================================================================

drop table if exists ust_insert_t;
create table ust_insert_t (
    id int primary key,
    v text,
    backend int
) with (storage_type=ustore);

insert into ust_insert_t values (1, 'one', 0);
insert into ust_insert_t values
    (2, 'two', 0),
    (3, 'three', 0),
    (4, 'four', 0);
insert into ust_insert_t
select g, 'row-' || g, 0
  from generate_series(5, 50) g;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_insert_t),
    50::bigint,
    'single-row, multi-row and INSERT SELECT must load all expected rows'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_insert_t where v like 'row-%'),
    46::bigint,
    'INSERT SELECT must preserve all generated rows'
);

select pg_temp.ustore_assert_error(
    $sql$insert into ust_insert_t values (1, 'duplicate', 0)$sql$,
    '23505',
    'duplicate primary key insert must fail'
);

-- 同一事务内同一行多次更新后整体回滚，undo 链必须全部撤销。
begin;
    insert into ust_insert_t values (100, 'v1', 1);
    update ust_insert_t set v = 'v1.1' where id = 100;
    update ust_insert_t set v = 'v1.2' where id = 100;
    select pg_temp.ustore_assert_eq(
        (select v from ust_insert_t where id = 100),
        'v1.2'::text,
        'current transaction must see its latest inserted version'
    );
rollback;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_insert_t where id = 100),
    0::bigint,
    'rollback must remove the row inserted in the rolled-back transaction'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_insert_t),
    50::bigint,
    'rollback must restore the original row count'
);

drop table ust_insert_t;

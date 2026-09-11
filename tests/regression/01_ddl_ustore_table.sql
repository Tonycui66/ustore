\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 01_ddl_ustore_table.sql
-- USTORE: 建表 / 表参数 / UBtree 索引 / DDL 兼容性
-- =========================================================================

drop table if exists ust_ddl_basic;
drop table if exists ust_ddl_default;
drop table if exists ust_ddl_part;
drop table if exists ust_ddl_unlogged;

-- 显式声明 USTORE。
create table ust_ddl_basic (
    id int primary key,
    name varchar(32),
    ts timestamp
) with (storage_type=ustore);

select pg_temp.ustore_assert_true(
    exists (
        select 1
          from pg_class c
         where c.oid = 'ust_ddl_basic'::regclass
           and c.reloptions is not null
           and array_to_string(c.reloptions, ',') like '%storage_type=ustore%'
    ),
    'explicit storage_type=ustore must be visible in pg_class.reloptions'
);

-- enable_default_ustore_table 开启后，普通建表也必须使用 USTORE。
set enable_default_ustore_table = on;
create table ust_ddl_default (id int, v text);
select pg_temp.ustore_assert_true(
    exists (
        select 1
          from pg_class c
         where c.oid = 'ust_ddl_default'::regclass
           and c.reloptions is not null
           and array_to_string(c.reloptions, ',') like '%storage_type=ustore%'
    ),
    'enable_default_ustore_table=on must create a USTORE table'
);
reset enable_default_ustore_table;

-- 显式 UBtree 索引，包含普通索引和 include 索引。
create index ust_ddl_basic_idx on ust_ddl_basic using ubtree(name);
create index ust_ddl_basic_inc on ust_ddl_basic using ubtree(id) include(name);

select pg_temp.ustore_assert_true(
    (
        select count(*) > 0
          from pg_index i
          join pg_class idx on idx.oid = i.indexrelid
          join pg_am am on am.oid = idx.relam
         where i.indrelid = 'ust_ddl_basic'::regclass
    ),
    'USTORE table must have at least one index'
);
select pg_temp.ustore_assert_eq(
    (
        select count(*)
          from pg_index i
          join pg_class idx on idx.oid = i.indexrelid
          join pg_am am on am.oid = idx.relam
         where i.indrelid = 'ust_ddl_basic'::regclass
           and am.amname <> 'ubtree'
    ),
    0::bigint,
    'all indexes on an USTORE table must use ubtree access method'
);

-- ALTER 与 TRUNCATE 不得破坏 USTORE 表。
alter table ust_ddl_basic add column note text;
alter table ust_ddl_basic alter column name type varchar(128);

insert into ust_ddl_basic values
    (1, 'alice', now(), 'n1'),
    (2, 'bob', now(), null);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_ddl_basic),
    2::bigint,
    'ALTER TABLE must preserve table usability'
);

truncate table ust_ddl_basic;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_ddl_basic),
    0::bigint,
    'TRUNCATE must remove all visible rows'
);

-- 分区表 + USTORE。
create table ust_ddl_part (id int, region text) with (storage_type=ustore)
partition by range(id)
(
    partition p1 values less than (100),
    partition p2 values less than (maxvalue)
);
insert into ust_ddl_part values (10, 'ap'), (200, 'eu');
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_ddl_part),
    2::bigint,
    'USTORE partitioned table must accept rows in all partitions'
);

-- unlogged + USTORE 是版本能力检查；不支持时用例应失败而不是静默跳过。
create unlogged table ust_ddl_unlogged (id int) with (storage_type=ustore);
select pg_temp.ustore_assert_true(
    exists (
        select 1
          from pg_class c
         where c.oid = 'ust_ddl_unlogged'::regclass
           and c.reloptions is not null
           and array_to_string(c.reloptions, ',') like '%storage_type=ustore%'
    ),
    'UNLOGGED table must preserve the requested USTORE storage type'
);

drop table ust_ddl_basic;
drop table ust_ddl_default;
drop table ust_ddl_part;
drop table ust_ddl_unlogged;

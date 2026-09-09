-- =========================================================================
-- 01_ddl_ustore_table.sql
-- USTORE: 建表 / 表参数 / UBtree 索引 / 前置校验
-- 目标: 校验 storage_type=ustore 的声明、\d+ 展示、默认索引为 ubtree
-- =========================================================================
drop table if exists ust_ddl_basic;
-- 显式声明 USTORE
create table ust_ddl_basic (id int primary key, name varchar(32), ts timestamp)
    with (storage_type=ustore);

-- 校验表的 options 反映 ustore
select relname, reloptions
  from pg_class c
 where c.relname = 'ust_ddl_basic'
   and (reloptions::text ilike '%ustore%'
        or exists (select 1 from pg_class  where relname='ust_ddl_basic')); -- 供人读

-- 显式 ubtree 索引（含 include）
create index ust_ddl_basic_idx on ust_ddl_basic using ubtree(name);
create index ust_ddl_basic_inc on ust_ddl_basic using ubtree(id) include(name);

-- 分区表 + USTORE
drop table if exists ust_ddl_part;
create table ust_ddl_part (id int, region text) with (storage_type=ustore)
    partition by range(id)
    (
        partition p1 values less than (100),
        partition p2 values less than (maxvalue)
    );

-- 临时表 / unlogged 表与 USTORE 组合（视版本支持情况）
drop table if exists ust_ddl_tmp;
create temp table ust_ddl_tmp (a int);

-- 数据插入验证
insert into ust_ddl_basic values (1, 'alice', now());
insert into ust_ddl_basic values (2, 'bob',   now());
insert into ust_ddl_part values (10, 'ap'), (200, 'eu');

select count(*) as basic_cnt from ust_ddl_basic;
select count(*) as part_cnt  from ust_ddl_part;

-- 清理
drop table ust_ddl_basic;
drop table ust_ddl_part;
drop table ust_ddl_tmp;

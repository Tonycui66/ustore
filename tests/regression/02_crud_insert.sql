-- =========================================================================
-- 02_crud_insert.sql
-- USTORE 插入: 单行 / 批量 / INSERT..SELECT / 事务内多次插入 undo 链
-- =========================================================================
drop table if exists ust_insert_t;
create table ust_insert_t (id int, v text, backend int) with (storage_type=ustore);

-- 单行插入
insert into ust_insert_t values (1, 'one', 0);

-- 多行批量（触发 MultiInsert 路径）
insert into ust_insert_t values (2, 'two', 0), (3, 'three', 0), (4, 'four', 0);

-- INSERT ... SELECT
insert into ust_insert_t select g, 'row-'||g, 0 from generate_series(5, 50) g;

-- 同一事务内对同一行多次改版本(叠加 undo 链)
begin;
  insert into ust_insert_t values (100, 'v1', 1);
  update ust_insert_t set v='v1.1' where id=100;
  update ust_insert_t set v='v1.2' where id=100;
  -- 本会话读最新
  select id, v from ust_insert_t where id=100;
rollback;   -- 全部丢弃
-- rollback 后该行不存在
select count(*) as inserted_after_rollback from ust_insert_t where id=100;

-- 校验最终记录数
select count(*) as total_rows,
       count(*) filter (where v like 'row-%') as gen_rows
  from ust_insert_t;

drop table ust_insert_t;

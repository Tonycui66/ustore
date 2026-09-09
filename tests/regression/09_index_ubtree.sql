-- =========================================================================
-- 09_index_ubtree.sql
-- UBtree 索引: 唯一约束、键列更新、索引一致性、删除与回收
-- =========================================================================
drop table if exists ust_idx_t;
create table ust_idx_t (id int, code text, extra int) with (storage_type=ustore);
create unique index ust_idx_t_code on ust_idx_t using ubtree(code);

insert into ust_idx_t values (1, 'a', 10), (2, 'b', 20), (3, 'c', 30);

-- 唯一冲突: 应报错
-- insert into ust_idx_t values (4, 'a', 40);  -- ERROR: duplicate key value

-- 键列更新(触发索引项更新 undo: UNDO_UBT_INSERT/DELETE)
update ust_idx_t set code = 'bb' where id = 2;
-- 更新后索引扫描验证
select id, code from ust_idx_t where code = 'bb';  -- 1 行

-- 使用确定性扫描(bitmap/seqscan)做一致性校验
set enable_indexscan = off; set enable_bitmapscan = off;
select count(*) from ust_idx_t where code = 'c';
reset enable_indexscan; reset enable_bitmapscan;

-- 大量插入/删除测索引空间回收
insert into ust_idx_t select g, 'k'||g, g from generate_series(100, 999) g;
select count(*) as idx_rows from ust_idx_t where code >= 'k100' and code <= 'k999';
delete from ust_idx_t where extra >= 500;
vacuum ust_idx_t;
analyze ust_idx_t;

select count(*) from ust_idx_t;
drop table ust_idx_t;

-- =========================================================================
-- 03_crud_update_inplace_vs_moved.sql
-- 就地更新(In-place) vs 行迁移: 长度不变(id+v varchar 定宽)->就地; 变超宽->可能迁移
-- 观察点: 数据/DML 一致性、回滚后旧值恢复
-- =========================================================================
drop table if exists ust_update_t;
create table ust_update_t (id int primary key, c int, padding varchar(200)) with (storage_type=ustore);

-- 密集更新(触发大量 in-place)
insert into ust_update_t select g, 0, 'AAAAAAAAAA' from generate_series(1, 100) g;

begin;
  update ust_update_t set c = c + 1 where id between 1 and 100;
  update ust_update_t set c = c + 1 where id between 1 and 100;
commit;

-- 期望所有行 c=2
select min(c) as min_c, max(c) as max_c from ust_update_t;  -- 应为 2,2

-- 增宽列: 定宽改超阈值宽字符串(行长增长 -> 需要更多空间)
update ust_update_t set padding = repeat('B', 150) where id = 1;
select id, c, length(padding) as pad_len from ust_update_t where id = 1;

-- 回滚事务: 新值被丢弃,旧值(AAAA..)恢复
begin;
  update ust_update_t set padding = repeat('C', 180) where id = 2;
rollback;
select length(padding) as pad_len_after_rollback from ust_update_t where id = 2; -- 10

-- 键列更新(触发索引与 excl 锁语义)
begin;
  update ust_update_t set id = id + 10000 where id = 3;
commit;
select count(*) as moved_tuples from ust_update_t where id = 10003;

drop table ust_update_t;

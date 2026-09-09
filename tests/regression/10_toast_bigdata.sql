-- =========================================================================
-- 10_toast_bigdata.sql
-- 大字段/TOAST: 行长超阈值切分到 toast 表, 更新/回滚/删除后 toast 一致性
-- =========================================================================
drop table if exists ust_toast_t;
create table ust_toast_t (id int primary key, big text) with (storage_type=ustore);

-- 插入大字段(>8K, 触发 TOAST)
insert into ust_toast_t values (1, repeat('x', 20000)), (2, repeat('y', 30000));

-- 按需取用完整大字段
select id, length(big) as big_len from ust_toast_t order by id;
-- 期望: 1 -> 20000, 2 -> 30000

-- 大字段上做更新(in-place 或迁移)并回滚恢复旧值
begin;
  update ust_toast_t set big = repeat('z', 40000) where id = 1;
  savepoint sp;
  update ust_toast_t set big = repeat('w', 60000) where id = 1;
  rollback to sp;
  select length(big) as after_partial_rb from ust_toast_t where id = 1;  -- 40000
rollback;
select length(big) as restored_len from ust_toast_t where id = 1;        -- 20000

-- 通过聚合读回每一列(校验无 toast 损坏)
select sum(id) as id_sum, sum(length(big)) as total_chars from ust_toast_t;

-- 删除大字段行的回收
delete from ust_toast_t where id = 2;
vacuum ust_toast_t;
select count(*) from ust_toast_t;  -- 1

drop table ust_toast_t;

-- =========================================================================
-- 05_mvcc_visibility.sql
-- USTORE MVCC 可见性: Read Committed / Repeatable Read 下的读写可见
-- 本文件为单会话语义; 并发安排见 08_concurrency_locking.sql
-- =========================================================================
drop table if exists ust_mvcc_t;
create table ust_mvcc_t (id int primary key, v int) with (storage_type=ustore);

insert into ust_mvcc_t values (1, 10), (2, 20), (3, 30);

-- Read Committed: 提交后立即可见; 未提交事务修改不可见
begin;
  update ust_mvcc_t set v = v + 1 where id = 1;
  -- 本会话(自身事务)可见新值
  select * from ust_mvcc_t where id = 1;   -- 11
rollback;
-- 回滚后恢复
select * from ust_mvcc_t where id = 1;     -- 10

-- Repeatable Read 一致性快照: 事务首次读之后固定视图
begin isolation level repeatable read;
  select sum(v) as snap_1 from ust_mvcc_t;   -- 60
  update ust_mvcc_t set v = v + 100 where id = 2;  -- 自身修改可见
  select * from ust_mvcc_t where id = 2;     -- 120 (本会话)
commit;

-- 隔离级别串行化下的只读快照
begin isolation level serializable read only;
  select sum(v) as serial_snap from ust_mvcc_t;  -- 60 + 100 = 160
commit;

-- deleted/expired 行不应被旧快照读取后有"幽灵"
select count(*) from ust_mvcc_t;  -- 3

drop table ust_mvcc_t;

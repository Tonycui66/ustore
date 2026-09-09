-- =========================================================================
-- 06_transaction_rollback.sql
-- 回滚 / undo 应用: 单事务全回滚、savepoint 部分回滚、回滚后旧值精确恢复
-- 观察点: undo 链批量应用(VerifyAndDoUndoActions)后数据一致性
-- =========================================================================
drop table if exists ust_rb_t;
create table ust_rb_t (id int primary key, v int) with (storage_type=ustore);

insert into ust_rb_t select g, g*10 from generate_series(1, 100) g;

-- 场景1: 整事务回滚
begin;
  update ust_rb_t set v = -1 where id <= 50;
  delete from ust_rb_t where id > 50;
rollback;
select count(*) as all_back, sum(case when id<=50 and v=id*10 then 1 else 0 end) as half_ok
  from ust_rb_t;  -- 100, 50

-- 场景2: savepoint 局部回滚(恢复中间版本)
begin;
  update ust_rb_t set v = v + 1 where id = 1;
  savepoint sp1;
  update ust_rb_t set v = v + 100 where id = 1;
  rollback to sp1;
  -- 只保留 +1
  select id, v from ust_rb_t where id = 1;   -- 1 -> 11
  update ust_rb_t set v = v + 10 where id = 1;
commit;
select id, v from ust_rb_t where id = 1;     -- 21

-- 场景3: 同一行多版本更新后整体回滚(old value 经 undo 恢复)
begin;
  update ust_rb_t set v = 1  where id = 2;
  update ust_rb_t set v = 2  where id = 2;
  update ust_rb_t set v = 3  where id = 2;
rollback;
select id, v from ust_rb_t where id = 2;     -- 20

-- 场景4: 部分 commit 部分 rollback(两个独立事务)
begin; update ust_rb_t set v = 999 where id = 3; commit;
begin; update ust_rb_t set v = -999 where id = 4; rollback;
select * from ust_rb_t where id in (3,4) order by id;  -- 3->999, 4->40

drop table ust_rb_t;

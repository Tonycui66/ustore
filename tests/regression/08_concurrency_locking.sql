-- =========================================================================
-- 08_concurrency_locking.sql
-- 并发更新 & 行锁: SELECT ... FOR UPDATE/SHARE, 多会话对同一行更新
-- 运行说明: 本文件需多个并发会话。推荐用 gsql \\parallel 或在应用侧并发驱动；
--           单会话部分(锁模式、锁冲突检测)可直接执行。
-- =========================================================================
drop table if exists ust_conc_t;
create table ust_conc_t (id int primary key, v int) with (storage_type=ustore);
insert into ust_conc_t values (1, 1), (2, 2), (3, 3);

-- 单会话: 四种行锁模式均可执行
select id, v from ust_conc_t where id=1 for update;
select id, v from ust_conc_t where id=1 for no key update;
select id, v from ust_conc_t where id=1 for share;
select id, v from ust_conc_t where id=1 for key share;
commit;

-- 并发块(需多会话): 两个事务同时 UPDATE 同一行 -> 排他等待,最终一致
-- session A:
--   begin;
--   update ust_conc_t set v = v + 10 where id = 1;
--   perform pg_sleep(2);
--   commit;
-- session B (并发):
--   begin;
--   update ust_conc_t set v = v + 10 where id = 1;  -- 会等待 A 提交后: 读到新版本再 +10
--   commit;
-- 结果: id=1 的 v 加两次 = 21

-- 单会话模拟快速并发更新(自增重试语义)
do $$
begin
  for i in 1..50 loop
    update ust_conc_t set v = v + 1 where id = 2;
  end loop;
end $$;
select v from ust_conc_t where id = 2;  -- 52

-- 锁等待超时语义: 默认会阻塞; 显式 lock_timeout 时超时报错由调用方处理
set lock_timeout = 50;
-- 在无并发场景不会触发, 仅作语法演示
-- (并发会话中应期待: ERROR: canceling statement due to lock timeout)
reset lock_timeout;

drop table ust_conc_t;

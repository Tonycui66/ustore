-- =========================================================================
-- 12_fault_injection_whitebox.sql  [构建受限]
-- 白盒故障注入: 使用 USTORE 白盒桩验证失败路径与回滚正确性
-- 前提: 需 ENABLE_WHITEBOX / cassert 构建; 桩名见 knl_whitebox_test.h
-- 运行时通过 guc 或测试框架设置桩; 以下为桩清单与预期行为, 供接入测试框架使用
-- =========================================================================
-- DML 失败桩
--   UHEAP_INSERT            : 插入路径注入失败
--   UHEAP_MULTI_INSERT      : 批量插入失败
--   UHEAP_DELETE            : 删除路径失败
--   UHEAP_UPDATE            : 更新路径失败
--   UHEAP_FETCH             : 行读取失败
--   UHEAP_LOCK_TUPLE        : 行加锁失败
--   UHEAP_PAGE_PRUNE        : 页清理失败
--   UHEAP_REPAIR_FRAGMENTATION : 碎片整理失败
-- 回滚 / undo 路径桩
--   UHEAP_UNDO_ACTION       : undo 应用失败
--   UNDO_UPDATE_BEFORE_UPDATE / UNDO_UPDATE_AFTER_UPDATE
--   UNDO_RECYCL_ESPACE      : undo 空间回收失败
--   UNDO_EXTEND_FILE / UNDO_EXTEND_LOG : undo 扩展失败
-- TOAST 路径桩
--   UHEAP_TOAST_DELETE / UHEAP_TOAST_INSERT_UPDATE
-- xlog 路径桩
--   UHEAP_XLOG_INSERT / DELETE / UPDATE / CLEAN / MULTI_INSERT ...

-- 示例(接入测试框架后按框架语法注入):
-- 以下 SQL 仅说明在注入发生后, 表数据应整体回滚到一致状态:

drop table if exists ust_wb_t;
create table ust_wb_t (id int primary key, v int) with (storage_type=ustore);
insert into ust_wb_t select g, g from generate_series(1, 50) g;

-- 注入"删除在第 N 次调用时失败"后, 期望 DELETE 语句报 ERROR 且无数据损坏
-- (示例仅占位; 具体由测试框架注入):
--   begin; delete from ust_wb_t where id<=10; -- 注入 UHEAP_DELETE 第1次失败
--   rollback; end;
select count(*) from ust_wb_t;  -- 50

-- 注入"undo 应用失败"后, 回滚应保证最终一致性
--   update ust_wb_t set v = v + 1; -- 注入 UHEAP_UNDO_ACTION 失败
--   rollback;
select min(v)>=1 and max(v)<=50 as consistent from ust_wb_t;

drop table ust_wb_t;

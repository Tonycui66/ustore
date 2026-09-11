# USTORE 测试点与测试策略

> 本文从源码（`opengauss-mirror/openGauss-server` master）出发，梳理 USTORE 的测试维度和策略，
> 并把每个测试点对应到相关源码/白盒桩/系统函数，为编写可执行的测试用例提供清单与优先级。
>
> 对应落地场景和验收标准见 [`ustore_test_scenarios.md`](ustore_test_scenarios.md)。

---

## 1. 测试分层总览

```
Level 1  黑盒功能回归（SQL 级，plpgsql / psql 脚本）
Level 2  并发/事务语义（多 session，\\parallel，显式 begin/commit/rollback）
Level 3  存储/性能/资源（页满、TOAST、undo 水位、空间回收）
Level 4  崩溃恢复 / 重放（crash, restart, standby, redo）
Level 5  故障注入 / 白盒（WHITEBOX 桩触发逆向路径、随机失败）
Level 6  工具与视图（gs_undo_* 系列函数、pagehack/ubtdump、ps 监控）
```

优先级建议（回归冒烟 → 专项）：
`Level 1 > Level 2 > Level 4(关键 DML 崩溃) > Level 3 > Level 5 > Level 6`。
金融/OLTP 场景最关注 **Update in-place + 并发可见性 + undo 回收 + 崩溃恢复**。

---

## 2. 测试点清单（Map 到源码）

### 2.1 建表 / DDL 与存取方式（Level 1）
- [ ] `create table ... with(storage_type=ustore)`；`\d+` 显示 `Ustore` 与 `Options: storage_type=ustore`。
- [ ] `enable_default_ustore_table=on` 后默认表为 USTORE。
- [ ] USTORE 表默认索引为 UBtree；`create index ... using ubtree(...)`。
- [ ] 分区表 / 普通表 / TOAST / 临时表 / unlogged 表 的 USTORE 建表与 DDL（`knl_uheap.cpp`、`cat` 表 reloptions）。
- [ ] 对 USTORE 表执行 ALTER（加列/改类型/分区交换）、TRUNCATE、DROP 的兼容性。

### 2.2 核心 DML 正确性（Level 1）
- [ ] 单行/批量 INSERT（`RelationPutUTuple`）、`MultiInsert`、`INSERT ... SELECT`。
- [ ] UPDATE：**in-place 更新**（长度不增/增且页有空闲）与**行迁移**（长度超页：`UNDO_UPDATE`），列顺序不变。
- [ ] DELETE（`UHeapDelete`）、`UPDATE` 后再 DELETE。
- [ ] 更新主键 / 唯一键（需 ubtree 索引维护 `UNDO_UBT_INSERT/DELETE`）。
- [ ] 大数据量同一事务多次修改同一行（undo 链叠加）。
- [ ] 空表/大量删除后页复用（`UPageRepairFragmentation`、自由空间）。

### 2.3 MVCC 与可见性（Level 1 + Level 2）
- [ ] 读已提交 / 可重复读 / 串行化 隔离级别下的 INSERT-UPDATE-DELETE 可见性（`UHeapTupleSatisfiesVisibility`）。
- [ ] 多版本行内容正确性：`SET` 后新会话读旧值 / 本会话读新值。
- [ ] `globalFrozenXid` 快速路径：对已 old 事务的行不加 undo 回溯即可读。
- [ ] td 槽复用（`UHEAP_INVALID_XACT_SLOT`）：多事务在**同一页同一槽**上陆续更新，可见性仍正确。
- [ ] 子事务(`SUBTRANSACTION`)的可见性；`SAVEPOINT` 回滚后恢复旧值。
- [ ] 闪回（如 `FLASHBACK QUERY` / `timecapsule`，按版本能力）。

### 2.4 事务与回滚（Level 1 + Level 2）/ undo 应用
- [ ] 单事务 ROLLBACK 后数据恢复（全部 DML 类型）。
- [ ] Savepoint 部分回滚；子事务失败只回滚子事务。
- [ ] 异步回滚：`undo_worker_count` 开启时，崩溃/中止事务由 undo worker 完成回滚（`VerifyAndDoUndoActions`、`knl_undolauncher.cpp`）。
- [ ] `UHeapExecPendingUndoActions`：读到"正在回滚"的行会先执行对方 undo 再继续。
- [ ] 批量 undo 应用顺序正确（`FetchUndoRecordRange` 按 (reloid, blkno) 页级排序应用）。

### 2.5 并发 / 锁（Level 2）——重点
- [ ] 多 session UPDATE 同一行：排他等待、`TM_BeingModified` 重试、最终一致性。
- [ ] `SELECT ... FOR UPDATE / FOR SHARE / FOR NO KEY UPDATE / FOR KEY SHARE`（`UHeapLockTuple`，行 flag 锁位与 `UHEAP_MULTI_LOCKERS`）。
- [ ] 更新键列 vs 仅非键列（键列 → excl lock，事务冲突行为差异）。
- [ ] 锁等待超时 / `lock_timeout`；等待者根据 undo worker 完成回滚后继续。
- [ ] bulk 插入与并发的页面扩展、仅加行指针的竞争（`UHeapWaitForTDSlot`）。

### 2.6 索引 UBtree（Level 1 + Level 2）
- [ ] 主键/唯一约束冲突；并发插入唯一键（`ubtinsert.cpp`）。
- [ ] in-place 更新键列时索引 TID 不跳转（对比 ASTORE HOT 计数）。
- [ ] 索引扫描 / 唯一扫描 / 排序正确性。
- [ ] 大量删除后索引空间回收（`ubtrecycle.cpp`、PCR 状态推进）。
- [ ] 索引崩溃恢复（`ubtxlog.cpp`）：插入后崩溃，索引与表一致。

### 2.7 页满 / 存储边界（Level 3）
- [ ] 页满时 UPDATE（`UPageIsFull` → 行迁移 / 强制扩展）。
- [ ] 页内 td 槽数量超过阈值扩展 TD 数组（`TD_THRESHOLD_FOR_PAGE_SWITCH=32`；单页 TD 扩展）。
- [ ] toast 化边界：行长接近 8K/32K（`USTORE_TOAST_TUPLE_THRESHOLD`）时 UPDATE/回滚/toast 引用重建。
- [ ] 大对象序列、`bytea/text` 外存列的增删改。

### 2.8 UNDO 空间 / 回收（Level 3 + Level 6）
- [ ] `gs_undo_meta / gs_undo_translot / gs_undo_record` 内容正确、随 DML 增长/回收正确变动。
- [ ] `undo_retention_time` 内不回收、超期可回收；`undo_space_limit_size` 限流触发（error 提示）。
- [ ] 大量长事务导致 undo 累积、discard worker 推进 `frozenXid/recycleXid` 后空间回落。
- [ ] 终止长事务后 undo 随之回收；`undo_worker_count=0` 与 >0 行为差异。
- [ ] `gs_undo_dump_xid` 等 dump 工具可正常输出。

### 2.9 崩溃 / 恢复 / WAL（Level 4）
- [ ] INSERT/DELETE/UPDATE/MultiInsert 后 `pg_ctl` kill -9 / crash，重启后数据一致、undo 可回滚。
- [ ] 崩溃点在 undo 写入后、数据页 WAL 前/后（靠 redo 重放 + undo worker 收尾）。
- [ ] 主备/热备只读一致性（`hotStandbyRecycleXid`）。
- [ ] `LogUHeapPageShiftBase`（冻结合并 & 页 xid 平移）后崩溃恢复。
- [ ] 大事务单事务 undo 超 `undo_limit_size_transaction` 的约束行为。

### 2.10 故障注入 / 白盒（Level 5）
- [ ] 使用 `WHITEBOX` 桩对 `UHEAP_INSERT / DELETE / UPDATE / LOCK_TUPLE / FETCH` 注入"第 N 次失败"（`knl_whitebox_test.h`）。
- [ ] `UNDO_UPDATE_BEFORE/ AFTER_UPDATE`、`UNDO_RECYCL_ESPACE`、`UNDO_EXTEND_*` 等 undo 路径失败注入。
- [ ] `UHEAP_TOAST_DELETE / INSERT_UPDATE` 失败注入。
- [ ] 断言违规：`UHEAP_UPDATED` 路径触发 assert（仅 debug 构建）。
- [ ] 随机失败回归（开启 `ustore_verify_level` 跑一轮 DML 后 `UpageVerify`）。

### 2.11 工具 / 监控（Level 6）
- [ ] `pagehack`、`ubtdump` 解析 USTORE 数据页/索引页。
- [ ] `pg_stat_*`、gs 会话视图反映 undo 使用（undo 会话、zone）。
- [ ] `\\d+`、`information_schema`、`pg_class.reloptions` 反映 USTORE。

---

## 3. 测试环境与前置

```bash
# openGauss 编译时建议
--with-blocksize=8 --enable-cassert   # 需要 assert 跑白盒桩
--enable-Whitebox                     # 启用 WHITEBOX 桩（回归用）
# postgresql.conf
undo_zone_count=16384
enable_default_ustore_table=on        # 或建表时 with(storage_type=ustore)
undo_retention_time=450
undo_worker_count=1
```

- 每个用例头部 `drop table if exists ...`、尾部 `drop table` 保持幂等。
- 隔离性用例尽量用独立数据库，避免 `gs_undo_*` 列受其他测试污染。

---

## 4. 质量属性 / 非功能策略
- **随机失败**：脚本一轮 DML 后开 `ustore_verify_level=fast` 执行 `UpageVerify`/`UndoRecordVerify`（见 `knl_uverify.h`）。
- **回归复用 openGauss 自带用例**：`src/test/regress/sql/{test_ustore_*}.sql`（如 `test_ustore_insert_update`、`test_ustore_concurrent_delete_and_update`、`ustore_ddl`、`test_ustore_toast`）可作基线，本仓库用例与之互补。
- **压测**：sysbench / 自写并发 UPDATE 脚本，关注 in-place 命中率、undo 增速、空间回收曲线。

---

## 5. 用例组织（本仓库 `tests/`）
- `tests/regression/` 下的 SQL 按编号与主题分文件，均可直接在 psql 顺序执行：
  - `01_ddl_ustore_table.sql`
  - `02_crud_insert.sql`
  - `03_crud_update_inplace_vs_moved.sql`
  - `04_crud_delete_vacuum.sql`
  - `05_mvcc_visibility.sql`
  - `06_transaction_rollback.sql`
  - `07_subtransaction.sql`
  - `08_concurrency_locking.sql`
  - `09_index_ubtree.sql`
  - `10_toast_bigdata.sql`
  - `11_undo_space_views.sql`
  - `12_fault_injection_whitebox.sql`（标注需 ENABLE_WHITEBOX 构建）

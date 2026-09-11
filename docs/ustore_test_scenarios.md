# USTORE 测试场景与验收标准

本文在原有测试策略基础上补齐可执行场景、断言方式和环境边界。原有 12 个脚本保留编号，
回归脚本统一通过 `tests/harness/ustore_assert.sql` 做结果校验，避免“SQL 无报错但结果错误”的假通过。

## 1. 测试分组

| 分组 | 目标 | 执行方式 |
|---|---|---|
| 基础回归 | DDL、CRUD、事务、索引、TOAST、UNDO 视图 | `tests/run_regression.sh` |
| 并发语义 | 多连接锁等待、超时、提交后重试 | `tests/concurrency/08_run.sh` |
| 崩溃恢复 | 已提交 WAL 重放、未提交事务恢复 | `tests/recovery/13_run_crash_recovery.sh` |
| 白盒故障注入 | 指定代码路径失败后的数据一致性 | 接入目标构建的 WHITEBOX 框架 |

## 2. 场景矩阵

### P0 数据正确性

| 场景 | 前置 | 操作 | 验收 |
|---|---|---|---|
| 显式 USTORE 建表 | 全新表 | `with (storage_type=ustore)` | `reloptions` 包含 `storage_type=ustore` |
| 默认 USTORE 建表 | `enable_default_ustore_table=on` | 普通建表 | 新表仍为 USTORE |
| 默认 UBtree | USTORE 表 | 建立主键和普通索引 | 所有相关索引的 access method 均为 `ubtree` |
| INSERT 路径 | 空表 | 单行、MultiInsert、`INSERT ... SELECT` | 行数、主键值和重复键错误符合预期 |
| UPDATE 路径 | 已有数据 | 等宽更新、增宽更新、键列更新、回滚 | 值精确恢复，旧键不可见，新键可见 |
| DELETE/VACUUM | 已有数据 | 删除、空间复用、回滚、VACUUM | 可见行数准确，回滚后数据恢复 |

### P0 事务与 MVCC

| 场景 | 操作 | 验收 |
|---|---|---|
| 整事务回滚 | UPDATE + DELETE 后回滚 | 所有旧值恢复 |
| Savepoint 回滚 | 子块失败和 `ROLLBACK TO` | 只回滚子块，外层修改保留 |
| 自身可见性 | 事务内插入、更新、删除 | 当前会话读取最新版本 |
| 并发更新等待 | 会话 A 持锁，会话 B `UPDATE` | B 等待；设置 `lock_timeout` 后按预期超时 |
| 锁释放后重试 | A 提交，B 重新执行 | 最终结果包含两次更新，无丢失更新 |

### P1 索引与存储边界

| 场景 | 操作 | 验收 |
|---|---|---|
| 唯一索引冲突 | 插入/更新为重复值 | SQLSTATE `23505` |
| 索引路径一致性 | 键列更新后分别走索引扫描和顺序扫描 | 两种路径结果完全一致 |
| TOAST | 插入 20K/30K 文本，更新、回滚、删除 | 长度精确恢复，TOAST relation 存在且数据可完整读回 |
| 页满与行迁移 | 页内空间不足后更新 | 数据正确；白盒构建另行验证 in-place/moved 路径和 TD 槽 |
| 页槽复用 | 多事务反复更新同一页同一 TD 槽 | 可见性正确，无残留旧版本 |

### P1 恢复

| 场景 | 操作 | 验收 |
|---|---|---|
| 已提交 DML 崩溃恢复 | 提交 UPDATE/DELETE 后 immediate stop/restart | 表数据和 UBtree 查询结果一致 |
| 未提交事务恢复 | 活动事务持有修改时终止后端并重启 | 未提交修改全部不可见，事务槽可继续复用 |
| 恢复后继续写入 | 恢复完成后执行 INSERT/UPDATE/DELETE | 后续事务正常，无页或 UNDO 结构损坏 |

### P2 UNDO 与故障注入

| 场景 | 操作 | 验收 |
|---|---|---|
| UNDO 视图可读性 | DML 后调用 `gs_undo_meta`、`gs_undo_translot` | 函数可执行，返回结构稳定 |
| 长事务 UNDO 累积 | 长事务持续修改并保持不提交 | UNDO 水位增长，事务终止后可回收 |
| retention/limit | 调整 `undo_retention_time`、`undo_space_limit_size` | 保留和限流行为符合 GUC 语义 |
| DML 路径注入 | `UHEAP_INSERT/DELETE/UPDATE/FETCH` 第 N 次失败 | 语句报错后事务可回滚，表与索引一致 |
| UNDO/TOAST/XLOG 路径注入 | 对应白盒桩失败 | 无悬挂 undo 链、无 TOAST 引用损坏、恢复后数据一致 |

## 3. 断言原则

1. 所有结果必须由 `ustore_assert_true`、`ustore_assert_eq` 或 `ustore_assert_error` 校验。
2. 预期失败必须校验 SQLSTATE，不能只捕获任意异常。
3. 回归脚本必须使用 `ON_ERROR_STOP=1`，任一断言失败立即返回非零状态。
4. 真实并发、崩溃、白盒故障注入不能伪装成单会话 SQL；必须由独立执行器管理多个连接和进程。
5. 破坏性恢复用例只能在一次性 openGauss 实例上运行，并要求显式设置 `ALLOW_DESTRUCTIVE_RECOVERY=1`。

## 4. 覆盖缺口

以下场景依赖目标版本、构建选项或专用工具，当前只提供接口或场景模板，不能在普通 SQL 回归中可靠完成：

- in-place 与行迁移的页级判定，需要 `pagehack`、调试视图或白盒计数。
- TD 槽阈值、页碎片整理和页复用，需要页级检查工具。
- UBtree PCR 回收和 UNDO discard worker 水位，需要长事务和后台 worker 观察。
- 主备、redo 以及具体崩溃点注入，需要独立集群与恢复执行器。

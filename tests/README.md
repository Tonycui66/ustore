# USTORE 测试用例

本目录提供 USTORE 的黑盒回归、真并发、崩溃恢复和白盒故障注入测试。
基础用例中的预期结果均通过断言校验，任一失败会返回非零退出码。

## 目录结构

```text
tests/
├── harness/                  # 公共断言函数
├── regression/               # SQL 黑盒回归
├── concurrency/              # 多会话并发执行器
├── recovery/                 # 崩溃恢复执行器
├── whitebox/                 # 白盒故障注入框架
└── run_regression.sh         # 回归测试入口
```

## 基础回归

运行环境需要 openGauss 实例，并包含 USTORE、UBtree 和 UNDO 子系统。
`11_undo_space_views.sql` 还要求目标版本提供 `gs_undo_*` 系统函数。

```bash
GSQL=gsql DB=postgres tests/run_regression.sh
```

也可以单独执行某个用例：

```bash
gsql -X -d postgres -v ON_ERROR_STOP=1 \
  -f tests/regression/01_ddl_ustore_table.sql
```

`12_fault_injection_whitebox.sql` 默认跳过，只有外部执行器已设置白盒桩时才应运行。

## 用例清单

| 文件 | 场景 | 主要验收 |
| --- | --- | --- |
| `01_ddl_ustore_table.sql` | USTORE 建表、默认表、UBtree、ALTER/TRUNCATE | reloptions、索引 access method、DDL 后可用性 |
| `02_crud_insert.sql` | 单行、MultiInsert、INSERT SELECT、重复键 | 行数、主键冲突 SQLSTATE、回滚 |
| `03_crud_update_inplace_vs_moved.sql` | 等宽/增宽/键列更新、回滚 | 新旧值、旧键消失、行数不变 |
| `04_crud_delete_vacuum.sql` | 删除、空间复用、VACUUM、回滚 | 可见行数、删除恢复 |
| `05_mvcc_visibility.sql` | 单会话 MVCC、RR、serializable read-only | 自身可见性、回滚快照、无幽灵行 |
| `06_transaction_rollback.sql` | 整事务、SAVEPOINT、多版本 undo 链 | 精确恢复旧值 |
| `07_subtransaction.sql` | 异常子事务和嵌套子事务 | 只撤销子块，外层修改保留 |
| `08_concurrency_locking.sql` | 锁语法和重复更新冒烟 | 50 次更新不丢失 |
| `09_index_ubtree.sql` | 唯一索引、键更新、索引/顺序扫描一致性 | 唯一冲突、扫描结果完全一致 |
| `10_toast_bigdata.sql` | TOAST 插入、更新、回滚、删除 | TOAST relation、长度、数据完整 |
| `11_undo_space_views.sql` | `gs_undo_*` 可读性和 DML 后状态 | 系统函数返回非空、checkpoint 后数据正确 |
| `12_fault_injection_whitebox.sql` | 故障注入后的数据一致性 | 表、索引、行值均保持完整 |

## 专项执行

真并发锁等待和超时：

```bash
GSQL=gsql DB=postgres tests/concurrency/08_run.sh
```

该执行器使用两个独立连接，验证 `lock_timeout` 的 SQLSTATE `55P03`，
以及锁释放后重试不会产生丢失更新。

崩溃恢复：

```bash
ALLOW_DESTRUCTIVE_RECOVERY=1 \
PGDATA=/path/to/opengauss/data \
GSQL=gsql \
GS_CTL=gs_ctl \
tests/recovery/13_run_crash_recovery.sh
```

该执行器只能在一次性实例上运行，会使用 `gs_ctl stop -m immediate` 模拟崩溃。

白盒故障注入：

```bash
GSQL=gsql DB=postgres \
tests/whitebox/run_injection_case.sh /path/to/case
```

case 目录需要提供 `setup.sql`、`inject_and_trigger.sql`、`verify.sql`，
具体桩语法由目标 openGauss 构建决定。

## 约定

- 所有文件使用 `ON_ERROR_STOP=1`。
- 结果由 `pg_temp.ustore_assert_*` 校验，不依赖人工阅读查询输出。
- 预期错误必须校验 SQLSTATE。
- 破坏性恢复测试要求 `ALLOW_DESTRUCTIVE_RECOVERY=1`。
- in-place/moved、页槽和 UBtree 回收等页级判定需要目标构建的 pagehack 或白盒能力。

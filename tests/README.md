# USTORE 测试用例

本目录提供围绕 openGauss USTORE 存储引擎的**可执行 SQL 测试用例**，按主题拆分，可在 psql 中逐个执行或作为回归脚本串行执行。

## 运行前提
- 目标环境：openGauss（含 USTORE、UBtree、undo 子系统）的可用实例。
- 建表采用 `with (storage_type=ustore)`；或 `SET enable_default_ustore_table=on` 后默认建表。
- 部分用例（并行并发、白盒故障注入、undo 系统视图）对构建/参数有额外要求，已在文件头注明：
  - `08_concurrency_locking.sql`：需要能开多个 session（psql 下建议使用 `\parallel` 或独立连接）。
  - `12_fault_injection_whitebox.sql`：需 `--enable-cassert` + 启用 WHITEBOX（`ENABLE_WHITEBOX`）的内部构建。
  - `11_undo_space_views.sql`：依赖 `gs_undo_*` 系统函数（openGauss 企业/社区版均提供）。

## 示例执行
```bash
gsql -d postgres -f tests/regression/01_ddl_ustore_table.sql
# 或一次性运行全部
for f in tests/regression/*.sql; do echo "== $f =="; gsql -d postgres -f "$f"; done
```

## 用例清单
| 文件 | 主题 | 对应源码关注点 |
| --- | --- | --- |
| 01_ddl_ustore_table.sql | USTORE 建表/索引/DML 前置 | reloptions、UBtree 默认索引 |
| 02_crud_insert.sql | 插入正确性与自增/OID | `RelationPutUTuple`、MultiInsert |
| 03_crud_update_inplace_vs_moved.sql | 就地更新 vs 行迁移 | in-place 更新、UNDO_UPDATE |
| 04_crud_delete_vacuum.sql | 删除 + 页清理/VACUUM | `UHeapDelete`、`UHeapPagePrune` |
| 05_mvcc_visibility.sql | 多版本可见性隔离级别 | `UHeapTupleSatisfiesVisibility` |
| 06_transaction_rollback.sql | 回滚与 undo 应用 | `VerifyAndDoUndoActions` |
| 07_subtransaction.sql | 子事务 / savepoint | 子事务 undo、部分回滚 |
| 08_concurrency_locking.sql | 并发更新与行锁 | `UHeapLockTuple`、TUPLESATISFIES_UPDATE |
| 09_index_ubtree.sql | UBtree 索引 | `ubtinsert/search/ubtrecycle` |
| 10_toast_bigdata.sql | 大字段 TOAST | `knl_ut uptoaster.cpp` |
| 11_undo_space_views.sql | undo 空间与视图 | `gs_undo_*` |
| 12_fault_injection_whitebox.sql | 白盒故障注入（构建受限） | `knl_whitebox_test.h` 桩 |

> 说明：用例按 openGauss SQL 语法编写，部分带 `-- ...` 断言语义的 CHECK 采用"可重跑的幂等脚本 + DO 块断言"，运行后以无 SQL 错误为准。


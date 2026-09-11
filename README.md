# USTORE 引擎源码研读 · 测试点 · 测试用例

> 面向 openGauss / GaussDB 的 **USTORE（就地更新 / In-place Update）存储引擎** 的学习与测试总结。
> 源码研读基于官方镜像仓库 `opengauss-mirror/openGauss-server`（master）中的
> `src/gausskernel/storage/access/ustore`、`.../ubtree` 及其头文件。

## 目录
- [USTORE 引擎完整逻辑梳理](docs/ustore_engine_overview.md)
  - 存储布局（UPage / TD 槽 / 行格式 / UNDO 记录）
  - MVCC 与可见性、DML 流程（Insert/Update/Delete）、回滚与 undo 应用
  - UNDO 分区与回收、WAL/崩溃恢复、UBtree 索引、TOAST
  - 参数、系统视图（`gs_undo_*`）与白盒测试桩
- [测试点与测试策略](docs/ustore_test_strategy.md)
  - 六层测试分层、覆盖矩阵（逐条映射到源码）
  - 环境前置、质量属性、故障注入清单
- [测试场景与验收标准](docs/ustore_test_scenarios.md)
  - P0/P1/P2 场景、断言原则、专项测试分组
- [测试用例](tests/README.md)
  - 12 个带断言的 SQL 用例（DDL、CRUD、MVCC、事务、索引、TOAST、undo、白盒）
  - 多会话并发、崩溃恢复和白盒故障注入执行器

## 快速开始
```bash
# 源码研读入口（引擎逻辑）
open docs/ustore_engine_overview.md

# 测试用例入口
open tests/README.md

# 在 openGauss 环境执行基础回归（需 USTORE）
GSQL=gsql DB=postgres tests/run_regression.sh

# 真并发专项
tests/concurrency/08_run.sh

# 崩溃恢复专项（只在一次性实例执行）
ALLOW_DESTRUCTIVE_RECOVERY=1 PGDATA=/path/to/data \
  tests/recovery/13_run_crash_recovery.sh
```

## 说明
- 行为基于 openGauss master 源码；个别运行时细节（GUC 名、`gs_undo_*` 列名、ORID 能力）以目标版本为准。
- 基础用例使用 SQL 断言；并发、崩溃恢复和白盒用例必须使用对应的独立执行器。

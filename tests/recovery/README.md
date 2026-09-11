# 崩溃恢复测试

该执行器只允许在一次性 openGauss 实例上运行，会执行 `gs_ctl stop -m immediate`
模拟非正常停机。

覆盖两个场景：

1. 已提交 INSERT/UPDATE/DELETE 在 immediate stop/restart 后仍然可见。
2. 活动事务中的 UPDATE/DELETE/INSERT 在崩溃恢复后全部不可见。

执行：

```bash
ALLOW_DESTRUCTIVE_RECOVERY=1 \
PGDATA=/path/to/opengauss/data \
GSQL=gsql \
GS_CTL=gs_ctl \
tests/recovery/13_run_crash_recovery.sh
```

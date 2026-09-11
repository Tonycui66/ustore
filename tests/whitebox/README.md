# 白盒故障注入

白盒桩的开启语法由目标 openGauss 构建和测试框架决定，因此仓库不伪造通用 GUC。
`run_injection_case.sh` 接受一个 case 目录，并按以下顺序执行：

| 文件 | 必需 | 作用 |
|---|---|---|
| `setup.sql` | 是 | 创建表和基线数据 |
| `inject_and_trigger.sql` | 是 | 在同一个连接内设置故障桩并执行目标 DML，必须报错 |
| `cleanup.sql` | 否 | 清除桩或后台状态 |
| `verify.sql` | 是 | 校验失败后的事务、表和索引一致性 |

执行：

```bash
GSQL=gsql DB=postgres \
tests/whitebox/run_injection_case.sh /path/to/case
```

建议至少建立以下 case：

- `UHEAP_INSERT`、`UHEAP_MULTI_INSERT`、`UHEAP_DELETE`、`UHEAP_UPDATE`
- `UHEAP_LOCK_TUPLE`、`UHEAP_FETCH`
- `UHEAP_UNDO_ACTION`、`UNDO_UPDATE_BEFORE_UPDATE`、`UNDO_UPDATE_AFTER_UPDATE`
- `UNDO_RECYCL_ESPACE`、`UNDO_EXTEND_FILE`、`UNDO_EXTEND_LOG`
- `UHEAP_TOAST_DELETE`、`UHEAP_TOAST_INSERT_UPDATE`
- `UHEAP_XLOG_INSERT`、`UHEAP_XLOG_DELETE`、`UHEAP_XLOG_UPDATE`、`UHEAP_XLOG_CLEAN`

每个 case 都应验证 SQLSTATE、失败后的可见数据、UBtree 查询结果和事务可继续使用。

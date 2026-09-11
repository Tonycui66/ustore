# 并发测试

`08_run.sh` 启动两个独立 `gsql` 会话：

1. 会话 A 获取 advisory lock 作为握手信号，然后更新同一行并持有行锁 3 秒。
2. 执行器确认 advisory lock 已被持有后，启动会话 B。
3. 会话 B 设置 `lock_timeout=300ms`，必须因行锁等待而返回 `55P03`。
4. 会话 A 提交后，会话 B 重新执行更新。
5. 最终值必须为 21，证明没有丢失更新。

执行：

```bash
GSQL=gsql DB=postgres tests/concurrency/08_run.sh
```

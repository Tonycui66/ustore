# USTORE 引擎完整逻辑梳理

> 说明：本梳理基于 openGauss 官方镜像仓库 `opengauss-mirror/openGauss-server`（master）的真实源码。
> 所有 USTORE 相关源码集中在 `src/gausskernel/storage/access/ustore/`、`src/gausskernel/storage/access/ubtree/`
> 及其头文件 `src/include/access/ustore/*.h`、`src/include/access/ubtree.h`。
> 文中所列的源码路径均为该仓库中的相对路径，便于对照研读。

---

## 1. 什么是 USTORE

openGauss（GaussDB Kernel）默认的行存储引擎是 **ASTORE**（追加更新 / Append-Update），沿用传统 Heap 思路：

- 每行在**行头**上保存 `xmin / xmax`，旧版本行与新版本行**都留在数据页**上；
- 提交状态记录在 **CLOG** 中；
- 跨页（非 HOT）UPDATE 会写入新版本行并让旧版本行留作垃圾，垃圾回收依赖 VACUUM，空间回收效率低、索引 TID 需要随版本更新而跳转。

**USTORE**（"In-place Update" 引擎）改变了这一模型：

- **最新有效数据** 放在数据页上，页内尽量 **in-place 更新**；
- **旧版本（垃圾）数据统一放到独立的 UNDO（Undo Space）** 中管理；
- 数据页因此不会因为频繁更新而膨胀，旧版本便于集中回收；
- UNDO 子系统采用 **NUMA-aware** 设计，多核扩展性好；
- 配套 **UBtree** 多版本索引与 **undo（含闪回/回收站）** 能力。

一句话：*ASTORE 用"多行版本留在数据页"实现 MVCC，USTORE 用"最新版本留页 + 旧版本进 UNDO 链"实现 MVCC*。

---

## 2. 源码模块地图

| 模块 | 源码文件 | 职责 |
| --- | --- | --- |
| 表访问方法（DML 主流程） | `ustore/knl_uheap.cpp` | Insert / Update / Delete / MultiInsert / Lock / Fetch 入口、undo 记录构造、WAL 生成 |
| 可见性 / MVCC | `ustore/knl_uvisibility.cpp` | 相可见性判定、TD 槽解析、undo 链回溯 |
| undo 应用（回滚） | `ustore/knl_undoaction.cpp` | Rollback / Undo Worker 逐条回放 undo 记录 |
| 页管理 | `ustore/knl_upage.cpp` | UPage 增删 item、自由空间、行指针 |
| 页清理 | `ustore/knl_pruneuheap.cpp` | 清理 dead/deleted 行指针并压缩 |
| 懒式 VACUUM | `ustore/knl_uvacuumlazy.cpp` | 收集死元组、回收、冻结合并 |
| 扫描 | `ustore/knl_uscan.cpp` | 全表/序列扫描与并行 |
| 行构造 / 解构 | `ustore/knl_utuple.cpp` | 将 disk tuple 物化为 Slot 等 |
| TOAST | `ustore/knl_utuptoaster.cpp` | 大字段压缩与外存 |
| 物理日志（redo） | `ustore/knl_uredo.cpp`、`knl_uextremeredo.cpp` | 崩溃恢复重放 |
| undo 记录结构 | `ustore/knl_uundorecord.cpp`、`knl_uundovec.cpp` | undo 记录编解码与批量向量 |
| undo 子系统 | `ustore/undo/knl_uundoapi.cpp` | undo 日志打开/遍历/落盘 |
| undo 分区(zone) | `ustore/undo/knl_uundozone.cpp` | zone 管理与元数据 |
| undo 空间 | `ustore/undo/knl_uundospace.cpp` | 段文件管理 |
| undo 事务槽 | `ustore/undo/knl_uundotxn.cpp` | 事务级 undo 槽 |
| undo 回收 | `ustore/undo/knl_uundorecycle.cpp` | discard / 空间回收 |
| undo WAL | `ustore/undo/knl_uundoxlog.cpp` | undo 自身的日志 |
| 索引 UBtree | `access/ubtree/*.cpp` | ubtree 插入/搜索/分裂/回收/xlog |
| 核心头文件 | `include/access/ustore/*.h`、`include/access/ubtree.h`、`ubtreepcr.h` | 数据结构与接口 |

---

## 3. 存储布局与核心数据结构

### 3.1 数据页布局（UPage）

USTORE 数据页头为 `UHeapPageHeaderData`，页由三部分组成（见 `knl_upage.h`）：

```
+------------------------------------------------------------------+
| UHeapPageHeaderData (pd_flags, pd_prune_xid, td_count, lsn, ...) |
| Transaction Directory (TD[])                                    |
| RowPtr[] (行指针 / line pointer)                                |
| 行数据 (UHeapDiskTuple ...)                                      |
+------------------------------------------------------------------+
```

- **TD 槽（Transaction Directory）**：每页维护一个 TD 数组，一个 TD 槽（`TD` 结构体，`knl_utype.h`）只占 16 字节：
  ```c
  typedef struct TD {
      TransactionId xactid;      // 64bit：事务 ID 或 CSN（用最高位区分 XID/CSN）
      UndoRecPtr undo_record_ptr; // 64bit：undo 指针
  } TD;
  ```
  一个事务在页上首次加载时分配一个 TD 槽（`td_count` 扩展，`UPageExtendTDSlots`）；同页内同一事务的所有行可共享该槽。`td_id`（8 bit）就是行指向的 TD 槽编号。
- **RowPtr（行指针）**：与 ASTORE 的 ItemId 类似，但带 `flags`（`RP_NORMAL / RP_DELETED / RP_UNUSED / RP_UNUSED_IN_PLACE` 等）和可见性位；被删除的行指针会标记为 deleted 并保留 td 槽信息，直到 prune 阶段才真正变成 unused。
- 页级标志：`UHEAP_HAS_FREE_LINES`、`UHEAP_PAGE_FULL`、`UHP_ALL_VISIBLE`（`knl_upage.h` 顶部的 `pd_flags` 位定义）。

### 3.2 元组格式（UHeapDiskTupleData）

USTORE 的行头很"瘦"（`knl_utuple.h`）：

```c
typedef struct UHeapDiskTupleData {
    ShortTransactionId xid;   // 修改该行的短事务 ID
    uint16 td_id : 8, reserved : 8; // 指向的 TD 槽
    uint16 flag;               // 行级标志（见下）
    uint16 flag2;              // 列数(natts)等
    uint8  t_hoff;
    uint8  data[];             // NULL 位图 + 列数据
} UHeapDiskTupleData;
```

**没有 `xmin / xmax` 字段**——这是与 ASTORE 最大差异：
- 行的"最终版本/可见版本"信息通过 **TD 槽里的 xactid + undo 指针** 解析；
- flag 位保留：`UHEAP_DELETED`、`UHEAP_INPLACE_UPDATED`、`UHEAP_UPDATED`、各种锁位（key-share / no-key-exclusive / shared / exclusive/multi-locker）、`UHEAP_INVALID_XACT_SLOT`（td 槽被复用）、frozen 位等。

### 3.3 UNDO 记录

每个 undo 记录以 `UndoRecordHeader` 开头（`knl_uundorecord.h`，22 字节，紧凑无 padding）：

```c
typedef struct {
    TransactionId xid;   // 事务 ID
    CommandId cid;       // 命令 ID
    Oid reloid, relfilenode;
    uint8 utype;         // 记录类型
    uint8 uinfo;         // 附加信息位（见后）
} UndoRecordHeader;
```

`utype`（`knl_uundotype.h`）取值：

| 类型 | 含义 |
| --- | --- |
| `UNDO_INSERT` / `UNDO_MULTI_INSERT` | 插入（含多值插入） |
| `UNDO_DELETE` | 删除 |
| `UNDO_INPLACE_UPDATE` | 页内原位更新 |
| `UNDO_UPDATE` | 更新（行迁移到新页） |
| `UNDO_UBT_INSERT` / `UNDO_UBT_DELETE` | 索引(ubtree)版本记录 |
| `UNDO_ITEMID_UNUSED` | 行指针置未用（prune/vacuum 产生） |

`uinfo` 位决定头部后追加哪些可选块：`UNDO_UREC_INFO_PAYLOAD / TRANSAC / BLOCK / OLDTD / CONTAINS_SUBXACT / HAS_PARTOID / HAS_TABLESPACEOID`，分别对应旧 TD(xid 与旧 undo 指针)、块号偏移、前一条 undo 指针（构成块级与事务级双向链）、分区 OID、表空间 OID、子事务标记等。

### 3.4 UNDO 指针（UndoRecPtr）

`UndoRecPtr` 是一个 64 bit 值（`knl_uundotype.h`）：

```
| zone id (20 bit) | offset (44 bit) |
```

- 高 20 bit 是 **undo zone（分区）ID**；`UNDO_ZONE_COUNT = 1024 * 1024`。
- 低 44 bit 是日志内的 byte offset（最大 16 TB / zone）；offset 又可按 `BLCKSZ` 换算成段文件内的 block 号与页内偏移。
- `INVALID_UNDO_REC_PTR = 0` 表示无。

### 3.5 UNDO Zone 与事务槽

- **Zone 划分**：`UNDO_ZONE_COUNT` 个 zone 平均分成 3 级持久化级别：`UNDO_PERMANENT`（普通表）、`UNDO_UNLOGGED`（未日志表）、`UNDO_TEMP`（临时表）。一个 zone 自带：
  - **undo space**：实际 undo 日志段文件（8K 块，`UNDOSEG_SIZE = 1MB` 一个段）；
  - **slot space**：事务槽（transaction slot），记录事务的 undo 链。
- **Zone 元数据**（`UndoZoneMetaInfo`，`knl_uundozone.h`）每事务/每区持久化：
  - `insertURecPtr`（写入位）、`discardURecPtr`（可回收水位）、`forceDiscardURecPtr`（强制回收水位）、`recycleXid`、`frozenXid`；
  - zone 内存里还维护 `frozenSlotPtr / allocateTSlotPtr / recycleTSlotPtr` 等。
- **globalFrozenXid / globalRecycleXid**：内存中维护的全局水线。可见性判断时，凡是 xid 早于 `globalFrozenXid`（或回收水位）的 TD 槽可直接视为 **frozen**，无需再回溯 undo——这是 USTORE 可见性加速的关键。
- 内存中还维护一组 **undo discard worker / launcher / worker**（`knl_undolauncher.cpp`、`knl_undoworker.cpp`、`knl_undorequest.cpp`）负责推进回收。

---

## 4. 核心机制逐项研读

### 4.1 INSERT（`UHeapPrepareInsert` / `RelationPutUTuple` / MultiInsert）

1. 构造 `UHeapDiskTuple`，`td_id` 初始置为 **frozen 槽**（`UHEAPTUP_SLOT_FROZEN`），清空可见性位；
2. 若行超阈值或含外存列，走 `UHeapToastInsertOrUpdate`（TOAST）；
3. `UHeapInsert` 系列：加 buffer（exclusive）锁 → `UHeapPagePrepareForXid`（必要时给本事务登记/复用一个 TD 槽）→ `UPageAddItem` 把行写入页；
4. 关键：插入不需要先写 undo 就产生旧版本，但 **需要本事务的 undo 链**（事务槽）以支持回滚——`UHeapPrepareUndoInsert` 构造一条 `UNDO_INSERT`，进入临界区后 `InsertPreparedUndo` 立即落 undo 并在页标记本事务修改位；`undo::UpdateTransactionSlot` 把该记录挂到事务槽；
5. 最后写 WAL（`LogUHeapInsert`）、更新 FSM。`whitbox` 桩 `UHEAP_INSERT_FAILED` 可注入"第 N 次插入失败"。

### 4.2 DELETE（`UHeapDelete`）

1. 加 buffer exclusive 锁 → `UHeapPagePrepareForXid` → 取行指针；
2. `UHeapTupleSatisfiesUpdate` 判断是否可见/是否被其他事务修改（冲突则 `UHeapWait` 等待或返回 `TM_BeingModified` → 重试 `check_tup_satisfies_update`，最多 `DML_MAX_RETRY_TIMES`）；
3. 从当前 TD/undo 解析出**旧版本** `oldTD`，`UHeapPrepareUndoDelete` 构造 `UNDO_DELETE`（uinfo 带 `OLDTD` + payload 里的旧行）；
4. 临界区内：`InsertPreparedUndo` → `UHeapPageSetUndo`（把页上 TD 槽改为 {本事务 xid, undo 指针}）→ 行 set `UHEAP_DELETED | UHEAP_XID_EXCL_LOCK` 并写短 xid → `undo::UpdateTransactionSlot`；
5. `UPageSetPrunable(fxid)` 留下清理线索；之后 `UHeapPagePrune` 或 VACUUM 在确认该 xid 已提交且对所有快照不可见后，把 deleted 行指针改为 unused、重排页（`UPageRepairFragmentation`）。
6. 写 WAL、更新 FSM，`UHeapFinalizeDML`。

**删除后如何让读者"看不见"**：该事务提交后，其他事务读到此行 → TD 槽 xid 已提交 → 行进 `UHEAP_DELETED` 位 → 判定删除者已提交 → 沿 undo 定位到旧版本 → 若旧版本对当前快照可见则拼接返回（deleted 位仅标记"此版本不是最新"）。

### 4.3 UPDATE（`UHeapUpdate`）— in-place 与行迁移

Update 是 USTORE 的灵魂，分两种（行 flag 区分）：

- **In-place 更新**（`UNDO_INPLACE_UPDATE`）：新列值在**原行位置**直接覆盖写入，长度允许（页内放得下）且不需要移动时；旧值版本 via undo。
  - 由于行位置不变，**索引 TID 无需变化**，这是 USTORE 相对 ASTORE HOT 的核心收益（非 HOT 时不产生索引跳转开销）。
  - 若只改了尾部且很快，会尝试 XOR 优化（`UndoXorDelta`，见 `UNDO_UREC_INFO` 与 `InplaceUpdate` 相关逻辑），只记录差异，进一步省空间。
- **行迁移更新**（`UNDO_UPDATE`，非 in-place）：列变宽、长度超页放不下时，旧行置 `UHEAP_UPDATED`（并 `UHEAP_XID_EXCL_LOCK`），新行插入（同页新位置或新页）。旧行相当于"失效指针"，指向新版本（通过 undo / 链）。
- 需要在 **新旧两页** 分别登记 TD 槽确保原子性（`UHeapReserveDualPageTDSlot`），实际修改发生在临界区内（先新页后旧页），通过日志保证崩溃一致。
- `UHeapPrepareUndoUpdate` 同时构造：旧行版本的 undo（记录改动前旧值/旧 TD）与新行的 undo。

### 4.4 可见性 / MVCC 判定（`UHeapTupleSatisfiesVisibility`、`UHeapTupleGetTransInfo`、`FetchTransInfoFromUndo`）

判定流程（简述，`knl_uvisibility.cpp:176`）：

1. **从行指针定位 TD 槽**：normal 行从 `tuple->td_id` 取；deleted 行从 RowPtr 的 td 槽取（此时行头可能已被改）；
2. **快速路径（frozen）**：若 TD 槽 `xactid` 早于 `globalFrozenXid`（或事务自身 / 自身已锁 / LOCK 且是自己持有），直接判定为 frozen → 该版本即当前可见版本；
3. **槽被复用（invalid slot）**：若行 `UHEAP_INVALID_XACT_SLOT` 位被置（td 槽已被别的事务复用），仍可尝试用 TD 里 xid 可见性提示；不可见才走 `FetchTransInfoFromUndo` 深度回溯；
4. **undo 链回溯**：从行 TD 的 undo 指针出发沿链遍历历史 undo 记录，找到"对当前 xid/cid 可见"的那个版本（`GetTupleFromUndoRecord`），把旧版本物化出来（`CopyTupleFromUndoRecord`），根据 `UTupleTidOp`（NEW/MODIFIED/GONE）决定返回当前行还是旧版本行。遍历状态 `UndoTraversalState`：`COMPLETE / STOP / ABORT / END / ENDCHAIN`，分别处理正常命中、早于 frozen 可见、被强制丢弃、已放弃链、链尾无旧版本。
5. **提交状态**：借助 `UHeapXidVisibleInSnapshot`（内部走 `TransactionIdDidCommit` / CSN），以 snapshot 判可见。

> 小结：USTORE 的可见性 = *TD 槽快速路径（frozen/xid 提示） + undo 链逐版本回溯 + 提交流程（CLOG/CSN）*，把"哪个 CSN/XID 对当前快照可见"等价到"沿 undo 链找到最早对快照可见的版本"。

### 4.5 回滚 / undo 应用（`knl_undoaction.cpp`）

- `VerifyAndDoUndoActions`：从 `fromUrecptr` 按事务的 undo 链批量 `FetchUndoRecordRange` 取回一批，按 (reloid, blkno) 排序后**页级聚合**逐条应用，减少 buffer/lock 次数；支持 `maintenance_work_mem` 上限（`MAX_UNDO_APPLY_SIZE`）。
- 每条 undo 按 `utype` 分发：
  - `UNDO_INSERT / MULTI_INSERT` → 把新行删掉（置 unused，回收行指针）；
  - `UNDO_DELETE` → 把旧行内容从 payload 恢复、清除 deleted 位；
  - `UNDO_INPLACE_UPDATE / UPDATE` → 把旧值写回原位 / 移除新行并恢复旧行；
  - `UNDO_ITEMID_UNUSED` → 行指针恢复。
  - 支持子事务（`UNDO_UREC_INFO_CONTAINS_SUBXACT`）与 TOAST 回滚（`OldToNewChunkIdMapping` 记录旧/新 chunk）。
- 事务异常退出时，由回滚处理统一调 `CheckAndDoUndoActions`；崩溃后由 **undo launcher / worker** 异步补做 `ABORT` 回滚；在线即用 `knl_uundorecv` 后台恢复。

### 4.6 页清理（Prune）与 VACUUM

- **Prune（`knl_pruneuheap.cpp`）**：
  - 带 `pd_prune_xid`（页上有未提交删除/更新留下"), 当事务提交且小于 `oldestXmin` 判定可清理；
  - `UHeapPagePruneGuts`：对 deleted 行目录，若其提交且对全局不可见 → 标记 dead → 收集为 dead offsets；dead 相最终逐出为 unused；
  - `UPageRepairFragmentation`：把行上移合并空闲空间；`LogUHeapClean` 产生清理日志。
  - 与 ASTORE 的 `lazy vacuum` 类似地维护 `latestRemovedXid`，用于 SQL 空洞语义。
- **Lazy VACUUM（`knl_uvacuumlazy.cpp`）**：与 heap lazy vacuum 同构，两阶段：
  - **Phase 1 扫描（`LazyScanUHeap`）**：遍历所有 UPage，用 `TidStore` 收集 dead item，统计 `tupsVacuumed / nkeep / nunused`，并按需推进 `frozenXid`、冻结 TD 槽（`UHeapPageFreezeTransSlots`）与 in-place 冻结行；
  - **Phase 2 回收（`LazyVacuumUHeap` / `LazyVacuumUPage`）**：把 dead offsets 置 unused、压缩、按 undo `UNDO_ITEMID_UNUSED` 写回收记录、推进页水位。
  - 索引侧由 `LazyVacuumUHeapIndex` 删除对应 item，配合 ubtree PCR 回收。

### 4.7 UNDO 回收（Discard / Recycle）

- zone 内维护 `insert / discard / forceDiscard` 三条水位与 `recycleXid / frozenXid`（`knl_uundozone.cpp`、`knl_uundorecycle.cpp`）；
- **undo discard worker**（`knl_undolauncher.cpp`）周期性检查，将"所有早于 `oldestXmin` / 保留期的 undo 记录"标记 discard 或 force-discard（early visible、在 `globalRecycleXid` 之前）；
- 空间池 `UndoSpace` 按段回收、重建空闲位图；frozen 槽逐步推进 `frozenXid` 表高压线；
- 每 bookkeeping 时刻调用 **undo redo**（`knl_uundoxlog.cpp`）保证崩溃后可判定回收水位，host 上 `knl_uundoxlog.cpp` 负责 undo 段自身的日志。

### 4.8 WAL / 崩溃恢复（`knl_uredo.cpp`、`knl_uextremeredo.cpp`）

- 数据页 DML 写普通 WAL：`LogUHeapInsert / Delete / Update / MultiInsert / Clean / FreezeTDSlot / InvalidTDSlot` 等；`LogUHeapNewPage` 写新页。
- UNDO 段自身也写日志（undo redo），undo 参与"页锁序"以保证集群与副本一致；
- 重放时数据页 + undo 页按 LSN 追踪恢复；`UHeapAbortSpeculative` 处理 speculation insert abort；`RestoreXactFromUndoRecord` 用于在恢复/热备上重建事务状态；
- 热备可见性通过 `standby_recycle_xid`（`hotStandbyRecycleXid`）保证只读一致性（`TransactionIdOlderThanAllUndo` 里分支）。

### 4.9 索引 UBtree（`ubtree/*.cpp`）

- UBtree 只服务 USTORE 表；`create index ... using ubtree(...)`（USTORE 表默认索引就是 ubtree）。
- 与传统 btree 对比：**行在页内 in-place 更新时 TID 不变**，索引无需插入"新版本"指向；因此 UBtree 采用**多版本索引（PCR, Page Consistency Representation 相关，见 `include/access/ubtreepcr.h`）** 在索引页记录 ITEM 的 TD/可见性（`TD status`：`ACTIVE / COMMITTED / DELETED / CSN / FROZEN`），支持：
  - 索引键删除/插入的可见性判断与回收（`ubtrecycle.cpp`、`ubtinsert.cpp`、`ubtsearch.cpp`）；
  - PCR 快照一致性：带 PCR 高度（`UBTPCR_PAGE/AQO` 等），为非 in-place 更新的索引条目维护版本；
  - 索引分裂、重分布、排序（`ubtsplitloc*.cpp`、`ubtsort.cpp`、`ubtutils.cpp`）；
  - 崩溃恢复（`ubtxlog.cpp`）。
- `ubtdump.cpp` 提供 ubtree 页 dump（调试）。

### 4.10 TOAST（`knl_ut uptoaster.cpp`）

- 行超 `USTORE_TOAST_TUPLE_THRESHOLD` 或有 external 列时，`UHeapToastInsertOrUpdate` 将长列拆到 toast 表，tuple 头置 `UHEAP_HASEXTERNAL`；
- 回滚时 undo payload 含 toast 引用，undo 应用需重建旧 toast（chunk 映射）；
- 提供 `UHeapToastDelete` / drill。白盒桩 `UHEAP_TOAST_DELETE_FAILED / UHEAP_TOAST_INSERT_UPDATE_FAILED` 可注入。

### 4.11 ORID（rowid / 对象行 ID）

- openGauss 企业版 USTORE 提供 `rowid` 列用于便捷定位与闪回；本 mirror(master) 源码未包含 ORID（`/orid` 目录），因此本梳理不展开，仅在测试里保留行定位相关的用例说明（不同版本需按目标版本实现为准）。

---

## 5. 并发控制

- 页级锁：`BUFFER_LOCK_EXCLUSIVE / SHARE`（Buffer Manager）；UNDO zone 用 `UNDO_ZONE_LOCK` 组锁与 zone LWLock。
- 行的"版本锁"：tuple 上没有 xmax，而是**行 flag 锁位 + TD 槽 xid**：
  - `UHEAP_XID_KEYSHR_LOCK`(key-share) / `UHEAP_XID_NOKEY_EXCL_LOCK`(no-key update) / `UHEAP_XID_EXCL_LOCK`(delete/update key) / `UHEAP_MULTI_LOCKERS`(多个锁持者)；
  - `UHeapLockTuple` 对 `SELECT ... FOR UPDATE/SHARE` 处理行锁，`UHeapTupleSatisfiesUpdate` 做冲突检测，冲突等待方 `UHeapWait`（可用 taglock / sleep），并支持 subtransaction lock。
- `UHeapExecPendingUndoActions`：读取路径若发现行被其他事务修改并处于回滚中，先执行对方未完成 undo 再继续。
- DML 均带 `retryTimes` / 缓冲区环路避让（`UHeapWaitForTDSlot / SleepOrWaitForTDSlot`）。

---

## 6. 关键参数、视图与工具（测试可直接使用）

**GUC（postgresql.conf）**：
- `undo_zone_count`：undo zone 数量，推荐 16384；改后需重启。
- `enable_default_ustore_table`：置 `on` 后默认建 USTORE 表。
- `undo_retention_time`、`undo_worker_count`、`undo_space_limit_size`、`undo_limit_size_transaction`：回收水位、后台 worker 数、单事务/整体 undo 上限。
- `ustore_verify_level`：USTORE 语言级校验等级（`DEBUG_VERIFY / ALL_VERIFY / FAST` 等，控制 `UpageVerify/UndoRecordVerify`）。
- `enable_ustore_partial_seqscan`：部分序列扫描优化。
> 具体参数名以目标 openGauss 版本官方文档为准。

**系统函数（可黑盒验证 undo 状态）**：
- `gs_undo_meta(zone, level, node)` → 列：`zoneId, persistType, insert, discard, end, used, lsn, pid`
- `gs_undo_translot(start, end)` → 列：`groupId, xactId, startUndoPtr, endUndoPtr, lsn, slot_states`
- `gs_undo_record(xid)` → 列：`undoptr, xid, cid, reloid, relfilenode, utype, blkprev, blockno, uoffset, prevurp, payloadlen`
- dump 系列：`gs_undo_meta_dump_zone / _spaces / _slot`、`gs_undo_translot_dump_slot`、`gs_undo_dump_xid`。

**白盒/故障注入**：`include/access/ustore/knl_whitebox_test.h` 定义了一批 `WHITEBOX_TEST_STUB` 桩（`UHEAP_INSERT/DELETE/UPDATE/LOCK_TUPLE`、`UHEAP_XLOG_*`、`UHEAP_UNDO_ACTION`、`UHEAP_TOAST_*`、`UNDO_*` 等），结合回归测试的 `\parallel`、`SELECT pg_sleep()`、`WHITEBOX` 参数即可做并发/崩溃/随机失败注入测试。

---

## 7. 与 ASTORE 的行为差异速查（测试关注）

| 维度 | ASTORE | USTORE |
| --- | --- | --- |
| 建表声明 | 默认 | `with(storage_type=ustore)` 或 `enable_default_ustore_table=on` |
| MVCC 版本 | 行头 xmin/xmax + CLOG | TD 槽 + UNDO 链 |
| 索引 | btree + HOT | ubtree + PCR 多版本索引 |
| Update 旧版本 | 留在数据页 | in-place 或进 undo |
| 并发可见性 | `HeapTupleSatisfies*` | `UHeapTupleSatisfiesVisibility` + undo 回溯 |
| 在线回滚 | 全量回滚 | undo 批量页级应用 + 异步 undo worker |
| 闪回 / 回收站 | 较受限 | 优于 undo 支持更完整 |

---

*本文档依据 openGauss master 源码整理；具体行为以所面向 openGauss/GaussDB 版本为准。*

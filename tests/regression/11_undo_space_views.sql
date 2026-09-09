-- =========================================================================
-- 11_undo_space_views.sql
-- UNDO 空间与系统视图: gs_undo_meta / gs_undo_translot / gs_undo_record
-- 观察点: DML 产生 undo; checkpoint 后 slot 状态; 事务级 undo 链
-- 运行说明: 需 openGauss 已启用 USTORE; 函数列名以版本为准(regress 基线见
--           test_ustore_undo_view).
-- =========================================================================
drop table if exists ust_undo_t;
create table ust_undo_t (id int primary key, v int) with (storage_type=ustore);

-- 产生一批 undo
insert into ust_undo_t select g, g from generate_series(1, 100) g;
update ust_undo_t set v = v + 1 where id <= 10;
delete from ust_undo_t where id > 90;

-- 读 undo zone 元数据(zone 0 永久区; 多 zone 环境zone id 因节点而异)
select * from gs_undo_meta(0, -1, 0);
-- 读事务槽
select * from gs_undo_translot(0, -1);

-- checkpoint 前/后事务槽状态可观察到(热数据区)
checkpoint;

select count(*) as alive_rows from ust_undo_t;

-- dump 工具(存在性/可调用性)
select count(*) > 0 as zone_dump_ok   from gs_undo_meta_dump_zone(0, false);
select count(*) > 0 as slot_dump_ok   from gs_undo_translot_dump_slot(0, false);

drop table ust_undo_t;

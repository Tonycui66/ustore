-- =========================================================================
-- 04_crud_delete_vacuum.sql
-- 删除 + 页清理(prune) + 懒式 VACUUM: dead 行最终回收、可见性不受影响
-- 观察点: delete 后 td 槽/行指针状态; vacuum 后 free space 回收
-- =========================================================================
drop table if exists ust_delete_t;
create table ust_delete_t (id int primary key, v text) with (storage_type=ustore);

insert into ust_delete_t select g, 'val-'||g from generate_series(1, 2000) g;

-- 删除部分行
delete from ust_delete_t where id % 10 = 0;
select count(*) as alive_after_delete from ust_delete_t;  -- 1800

-- 多次删除后同一区域再插入(空间复用)
delete from ust_delete_t where id between 1 and 500;
insert into ust_delete_t select 100000 + g, 'reuse-'||g from generate_series(1, 500) g;

-- VACUUM 触发页清理与 dead item 回收
vacuum (analyze) ust_delete_t;

select count(*) as alive_after_vacuum from ust_delete_t;

-- 回滚删除场景: 删除被回滚 -> 数据恢复
begin;
  delete from ust_delete_t where id >= 100000;
rollback;
select sum(case when id>=100000 then 1 else 0 end) as retained from ust_delete_t; -- 500

drop table ust_delete_t;

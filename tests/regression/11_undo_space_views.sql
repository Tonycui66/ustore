\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 11_undo_space_views.sql
-- UNDO 系统函数可读性与 DML 后可见性
-- 列名和返回结构以目标 openGauss 版本为准。
-- =========================================================================

drop table if exists ust_undo_t;
create table ust_undo_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_undo_t
select g, g
  from generate_series(1, 100) g;
update ust_undo_t set v = v + 1 where id <= 10;
delete from ust_undo_t where id > 90;

do $$
declare
    v_meta_count bigint;
    v_slot_count bigint;
begin
    select count(*) into v_meta_count from gs_undo_meta(0, -1, 0);
    if v_meta_count = 0 then
        raise exception 'gs_undo_meta returned no rows';
    end if;

    select count(*) into v_slot_count from gs_undo_translot(0, -1);
    if v_slot_count = 0 then
        raise exception 'gs_undo_translot returned no rows';
    end if;
end;
$$;

checkpoint;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_undo_t),
    90::bigint,
    'DML count must remain correct after checkpoint'
);

do $$
declare
    v_zone_rows bigint;
    v_slot_rows bigint;
begin
    select count(*) into v_zone_rows
      from gs_undo_meta_dump_zone(0, false);
    if v_zone_rows = 0 then
        raise exception 'gs_undo_meta_dump_zone returned no rows';
    end if;

    select count(*) into v_slot_rows
      from gs_undo_translot_dump_slot(0, false);
    if v_slot_rows = 0 then
        raise exception 'gs_undo_translot_dump_slot returned no rows';
    end if;
end;
$$;

drop table ust_undo_t;

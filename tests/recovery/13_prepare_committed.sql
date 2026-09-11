\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

drop table if exists ust_recovery_t;
create table ust_recovery_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_recovery_t
select g, g
  from generate_series(1, 100) g;
update ust_recovery_t set v = v + 1 where id <= 10;
delete from ust_recovery_t where id > 90;

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_t),
    90::bigint,
    'committed recovery fixture must contain 90 rows'
);
select pg_temp.ustore_assert_eq(
    (select v from ust_recovery_t where id = 1),
    2,
    'committed recovery fixture must include updated data'
);

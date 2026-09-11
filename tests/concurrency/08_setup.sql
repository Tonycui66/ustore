\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

drop table if exists ust_conc_t;
create table ust_conc_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_conc_t values (1, 1);
select pg_temp.ustore_assert_eq(
    (select v from ust_conc_t where id = 1),
    1,
    'concurrency fixture must start from v=1'
);

\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

insert into ust_recovery_t values (1000, 1000);
update ust_recovery_t set v = 7 where id = 1000;
delete from ust_recovery_t where id = 90;

select pg_temp.ustore_assert_eq(
    (select v from ust_recovery_t where id = 1000),
    7,
    'post-recovery INSERT/UPDATE must work'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_t where id = 90),
    0::bigint,
    'post-recovery DELETE must work'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_t),
    90::bigint,
    'post-recovery DML must leave a consistent row count'
);

drop table ust_recovery_t;

\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_t),
    90::bigint,
    'crash recovery must preserve the committed row count'
);
select pg_temp.ustore_assert_eq(
    (select v from ust_recovery_t where id = 1),
    2,
    'crash recovery must preserve committed updates'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_t where id > 90),
    0::bigint,
    'crash recovery must not resurrect committed deletes'
);
select pg_temp.ustore_assert_eq(
    (select v from ust_recovery_t where id = 90),
    90,
    'UBtree lookup after recovery must return the committed row'
);

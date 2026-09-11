\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

select pg_temp.ustore_assert_eq(
    (select v from ust_recovery_uncommitted_t where id = 1),
    1,
    'crash recovery must undo an uncommitted UPDATE'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_uncommitted_t where id = 2),
    1::bigint,
    'crash recovery must undo an uncommitted DELETE'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_uncommitted_t where id = 100),
    0::bigint,
    'crash recovery must remove an uncommitted INSERT'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_recovery_uncommitted_t),
    10::bigint,
    'uncommitted recovery must restore the original row count'
);

drop table ust_recovery_uncommitted_t;

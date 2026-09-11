\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

select pg_temp.ustore_assert_eq(
    (select v from ust_conc_t where id = 1),
    21,
    'committed updates from both sessions must accumulate without a lost update'
);

drop table ust_conc_t;

\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

set application_name = 'ustore_recovery_uncommitted';

drop table if exists ust_recovery_uncommitted_t;
create table ust_recovery_uncommitted_t (
    id int primary key,
    v int
) with (storage_type=ustore);

insert into ust_recovery_uncommitted_t
select g, g
  from generate_series(1, 10) g;

begin;
update ust_recovery_uncommitted_t set v = 999 where id = 1;
delete from ust_recovery_uncommitted_t where id = 2;
insert into ust_recovery_uncommitted_t values (100, 100);
select pg_sleep(60);
rollback;

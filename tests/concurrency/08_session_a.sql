\set ON_ERROR_STOP on

-- The advisory lock is a runner handshake. The row lock is held until COMMIT.
begin;
select pg_advisory_lock(918081);
update ust_conc_t set v = v + 10 where id = 1;
select pg_sleep(3);
commit;
select pg_advisory_unlock(918081);

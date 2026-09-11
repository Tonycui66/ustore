\set ON_ERROR_STOP on
\set VERBOSITY verbose

begin;
set local lock_timeout = '300ms';
update ust_conc_t set v = v + 10 where id = 1;
commit;

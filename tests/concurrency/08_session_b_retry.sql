\set ON_ERROR_STOP on

begin;
update ust_conc_t set v = v + 10 where id = 1;
commit;

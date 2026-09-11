\set ON_ERROR_STOP on
\ir ../harness/ustore_assert.sql

-- =========================================================================
-- 09_index_ubtree.sql
-- UBtree: 唯一约束、键列更新、索引与顺序扫描一致性、删除
-- =========================================================================

drop table if exists ust_idx_t;
create table ust_idx_t (
    id int,
    code text,
    extra int
) with (storage_type=ustore);

create unique index ust_idx_t_code on ust_idx_t using ubtree(code);

insert into ust_idx_t values
    (1, 'a', 10),
    (2, 'b', 20),
    (3, 'c', 30);

select pg_temp.ustore_assert_error(
    $sql$insert into ust_idx_t values (4, 'a', 40)$sql$,
    '23505',
    'unique UBtree index must reject duplicate keys'
);

update ust_idx_t set code = 'bb' where id = 2;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_idx_t where code = 'b'),
    0::bigint,
    'old UBtree key must disappear after key update'
);
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_idx_t where code = 'bb'),
    1::bigint,
    'new UBtree key must be visible after key update'
);

insert into ust_idx_t
select g, 'k' || g, g
  from generate_series(100, 999) g;
analyze ust_idx_t;

-- 同一查询分别强制走索引和顺序扫描，结果必须完全一致。
set enable_seqscan = off;
set enable_bitmapscan = off;
create temp table ust_idx_index_path as
select id, code, extra
  from ust_idx_t
 where code >= 'k100'
   and code <= 'k999';
reset enable_seqscan;
reset enable_bitmapscan;

set enable_indexscan = off;
set enable_bitmapscan = off;
create temp table ust_idx_seq_path as
select id, code, extra
  from ust_idx_t
 where code >= 'k100'
   and code <= 'k999';
reset enable_indexscan;
reset enable_bitmapscan;

select pg_temp.ustore_assert_eq(
    (
        select count(*)
          from (
                (select * from ust_idx_index_path
                 except
                 select * from ust_idx_seq_path)
                union all
                (select * from ust_idx_seq_path
                 except
                 select * from ust_idx_index_path)
               ) diff
    ),
    0::bigint,
    'UBtree and sequential scan results must be identical'
);

delete from ust_idx_t where extra >= 500;
vacuum (analyze) ust_idx_t;
select pg_temp.ustore_assert_eq(
    (select count(*) from ust_idx_t),
    403::bigint,
    'delete and VACUUM must preserve the expected surviving rows'
);

drop table ust_idx_t;

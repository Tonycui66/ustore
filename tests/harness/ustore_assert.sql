\set ON_ERROR_STOP on

-- Shared assertions for the USTORE regression scripts.
-- Functions live in pg_temp so they disappear with the test session.

create or replace function pg_temp.ustore_assert_true(
    p_condition boolean,
    p_message text
) returns void
language plpgsql
as $$
begin
    if p_condition is distinct from true then
        raise exception 'USTORE ASSERTION FAILED: %', p_message;
    end if;
end;
$$;

create or replace function pg_temp.ustore_assert_eq(
    p_actual anyelement,
    p_expected anyelement,
    p_message text
) returns void
language plpgsql
as $$
begin
    if p_actual is distinct from p_expected then
        raise exception
            'USTORE ASSERTION FAILED: %; actual=%, expected=%',
            p_message, p_actual, p_expected;
    end if;
end;
$$;

create or replace function pg_temp.ustore_assert_error(
    p_sql text,
    p_sqlstate text,
    p_message text
) returns void
language plpgsql
as $$
declare
    v_sqlstate text;
begin
    begin
        execute p_sql;
    exception when others then
        v_sqlstate := sqlstate;
        if p_sqlstate is not null and v_sqlstate <> p_sqlstate then
            raise exception
                'USTORE ASSERTION FAILED: %; expected SQLSTATE %, got %',
                p_message, p_sqlstate, v_sqlstate;
        end if;
        return;
    end;

    raise exception 'USTORE ASSERTION FAILED: %; statement unexpectedly succeeded',
        p_message;
end;
$$;

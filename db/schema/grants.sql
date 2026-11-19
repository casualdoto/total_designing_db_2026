do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'inspector') then
        create role inspector with login password 'NetoSQL2025';
    else
        alter role inspector with login password 'NetoSQL2025';
    end if;

    execute 'alter role inspector set search_path = khrestianovskii_food, exts';
end
$$;

grant all privileges on schema khrestianovskii_food to inspector;
grant usage on schema exts to inspector;
grant usage on schema information_schema to inspector;
grant usage on schema pg_catalog to inspector;
grant all privileges on all tables in schema khrestianovskii_food to inspector;
grant all privileges on all sequences in schema khrestianovskii_food to inspector;
grant execute on all routines in schema khrestianovskii_food to inspector;

alter default privileges in schema khrestianovskii_food
    grant all privileges on tables to inspector;

alter default privileges in schema khrestianovskii_food
    grant all privileges on sequences to inspector;

alter default privileges in schema khrestianovskii_food
    grant execute on routines to inspector;

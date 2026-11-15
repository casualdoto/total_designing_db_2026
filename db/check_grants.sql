-- Администратор: после grants.sql. Проверяет повторный запуск и DEFAULT PRIVILEGES.
-- Пароль и атрибуты роли сравниваются внутри БД, без вывода секрета в протокол.
BEGIN;
CREATE TEMP TABLE inspector_role_before AS
SELECT to_jsonb(a) AS attributes,
    (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.setdatabase) FROM pg_db_role_setting s WHERE s.setrole=a.oid) AS settings
FROM pg_authid a WHERE a.rolname='inspector';
\ir schema/grants.sql
DO $$ BEGIN
    IF NOT EXISTS(SELECT FROM inspector_role_before b JOIN pg_authid a ON a.rolname='inspector'
        WHERE b.attributes=to_jsonb(a) AND b.settings IS NOT DISTINCT FROM
        (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.setdatabase) FROM pg_db_role_setting s WHERE s.setrole=a.oid)) THEN
        RAISE EXCEPTION 'Повторный grants.sql изменил пароль или настройки inspector';
    END IF;
END; $$;
CREATE TABLE khrestianovskii_food.__food109_table(id uuid);
CREATE TYPE khrestianovskii_food.__food109_enum AS ENUM('probe');
CREATE FUNCTION khrestianovskii_food.__food109_function() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE PROCEDURE khrestianovskii_food.__food109_procedure() LANGUAGE plpgsql AS 'BEGIN NULL; END;';
DO $$ DECLARE privilege text; routine oid; BEGIN
    FOREACH privilege IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] LOOP
        IF NOT EXISTS(SELECT FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a
            WHERE c.oid='khrestianovskii_food.__food109_table'::regclass AND a.grantee='inspector'::regrole
            AND a.privilege_type=privilege) THEN RAISE EXCEPTION 'DEFAULT PRIVILEGES table: %',privilege; END IF;
    END LOOP;
    IF NOT EXISTS(SELECT FROM pg_type t CROSS JOIN LATERAL aclexplode(t.typacl) a
        WHERE t.oid='khrestianovskii_food.__food109_enum'::regtype AND a.grantee='inspector'::regrole AND a.privilege_type='USAGE') THEN
        RAISE EXCEPTION 'DEFAULT PRIVILEGES enum';
    END IF;
    FOREACH routine IN ARRAY ARRAY['khrestianovskii_food.__food109_function()'::regprocedure::oid,
        'khrestianovskii_food.__food109_procedure()'::regprocedure::oid] LOOP
        IF NOT EXISTS(SELECT FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a
            WHERE p.oid=routine AND a.grantee='inspector'::regrole AND a.privilege_type='EXECUTE') THEN
            RAISE EXCEPTION 'DEFAULT PRIVILEGES routine';
        END IF;
    END LOOP;
END; $$;
ROLLBACK;
\echo 'OK: grants.sql повторяем, роль сохранена, DEFAULT PRIVILEGES проверены'

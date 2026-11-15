-- FOOD-109/110. Запускать через реальное TCP-подключение inspector, без SET ROLE:
-- psql -X -h 127.0.0.1 -U inspector -d <база> -v ON_ERROR_STOP=1 -f db/check_inspector.sql
-- Данные сохраняются: весь сценарий завершается ROLLBACK.
BEGIN;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;

CREATE FUNCTION pg_temp.assert(p_ok boolean,p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',p_message; END IF;
END;
$$;

SELECT pg_temp.assert(session_user='inspector' AND current_user='inspector'
    AND inet_client_addr() IS NOT NULL,'настоящая TCP-сессия inspector');
SELECT pg_temp.assert((SELECT rolcanlogin AND NOT rolsuper AND NOT rolcreaterole AND NOT rolcreatedb
    FROM pg_roles WHERE rolname=current_user),'аудитор без административных полномочий');
SELECT pg_temp.assert(has_schema_privilege(current_user,'khrestianovskii_food','USAGE')
    AND has_schema_privilege(current_user,'khrestianovskii_food','CREATE')
    AND has_schema_privilege(current_user,'exts','USAGE')
    AND has_schema_privilege(current_user,'information_schema','USAGE')
    AND has_schema_privilege(current_user,'pg_catalog','USAGE'),'права на схемы');
DO $$ DECLARE obj record; privilege text; BEGIN
    FOR obj IN SELECT oid,relname,relkind FROM pg_class
        WHERE relnamespace='khrestianovskii_food'::regnamespace AND relkind IN ('r','v')
    LOOP
        FOREACH privilege IN ARRAY CASE WHEN obj.relkind='r' THEN
            ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] ELSE ARRAY['SELECT'] END
        LOOP
            PERFORM pg_temp.assert(has_table_privilege(current_user,obj.oid,privilege),obj.relname || ': ' || privilege);
        END LOOP;
    END LOOP;
    FOR obj IN SELECT oid,typname FROM pg_type WHERE typnamespace='khrestianovskii_food'::regnamespace AND typtype='e' LOOP
        PERFORM pg_temp.assert(has_type_privilege(current_user,obj.oid,'USAGE'),'enum ' || obj.typname);
    END LOOP;
    FOR obj IN SELECT oid,proname FROM pg_proc WHERE pronamespace='khrestianovskii_food'::regnamespace LOOP
        PERFORM pg_temp.assert(has_function_privilege(current_user,obj.oid,'EXECUTE'),'routine ' || obj.proname);
    END LOOP;
END; $$;
SELECT pg_temp.assert((SELECT count(*)=13 FROM information_schema.tables
    WHERE table_schema='khrestianovskii_food' AND table_type='BASE TABLE'),'information_schema.tables');
SELECT pg_temp.assert((SELECT count(*)=13 FROM pg_catalog.pg_tables WHERE schemaname='khrestianovskii_food'),'pg_catalog.pg_tables');
SELECT pg_temp.assert(has_function_privilege(current_user,'exts.uuid_generate_v4()','EXECUTE')
    AND exts.uuid_generate_v4() IS NOT NULL,'UUID из exts');

CALL erase_test_data();
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert((SELECT count(*)=10 FROM client) AND (SELECT count(*)=50 FROM "order"),'генератор под inspector');
DO $$ DECLARE r uuid; c uuid; n bigint; BEGIN
    SELECT restaurant_id INTO STRICT r FROM restaurant LIMIT 1;
    SELECT product_category_id INTO STRICT c FROM product_category LIMIT 1;
    SELECT count(*) INTO n FROM product;
    CALL add_product(r,c,'Проверка доступа',250,4.5,'доступно','Описание');
    PERFORM pg_temp.assert((SELECT count(*)=n+1 FROM product),'add_product');
END; $$;
SELECT pg_temp.assert((SELECT count(*)=10 FROM get_statistic()),'get_statistic');
CALL courier_salary();
SELECT pg_temp.assert((SELECT count(*)=10 FROM courier_pay WHERE year=extract(year FROM current_date)
    AND month=extract(month FROM current_date)),'courier_salary');
SELECT pg_temp.assert(EXISTS(SELECT FROM how_much_money),'how_much_money');
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
DO $$ DECLARE t record; n bigint; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='khrestianovskii_food' LOOP
        EXECUTE format('SELECT count(*) FROM khrestianovskii_food.%I',t.tablename) INTO n;
        PERFORM pg_temp.assert(n=0,'очистка ' || t.tablename);
    END LOOP;
END; $$;
ROLLBACK;
\echo 'OK: FOOD-109/110; реальное подключение inspector, изменения отменены'

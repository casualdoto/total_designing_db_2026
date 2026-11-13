-- FOOD-102/103. psql -v ON_ERROR_STOP=1 -f db/check_test_data.sql
-- Только тестовая БД, после schema/*.sql и grants.sql. Все изменения откатываются.
\timing on
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;
SELECT setseed(0.102);

CREATE FUNCTION pg_temp.assert(p_ok boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', p_message; END IF;
END;
$$;

CREATE FUNCTION pg_temp.check_counts(n int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record; actual bigint;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('client', n), ('courier', n), ('product_category', n), ('restaurant', n), ('legal_entity', n),
        ('address', 5*n), ('product', 5*n), ('order', 5*n), ('review', 5*n), ('payment', 5*n),
        ('client_address', 4*n), ('courier_pay', 6*n)) AS t(tbl, expected)
    LOOP
        EXECUTE format('SELECT count(*) FROM khrestianovskii_food.%I', r.tbl) INTO actual;
        PERFORM pg_temp.assert(actual = r.expected, format('%s: %s вместо %s', r.tbl, actual, r.expected));
    END LOOP;
    PERFORM pg_temp.assert((SELECT count(*) BETWEEN 5*n AND 25*n FROM order_structure), 'число позиций');
END;
$$;

CREATE FUNCTION pg_temp.check_data()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE field_info record; invalid bigint;
BEGIN
    -- Каждое varchar-поле проверяется по размерности из каталога, не по списку вручную.
    FOR field_info IN SELECT table_name, column_name, character_maximum_length AS n
        FROM information_schema.columns WHERE table_schema = 'khrestianovskii_food'
        AND data_type = 'character varying'
    LOOP
        EXECUTE format('SELECT count(*) FROM khrestianovskii_food.%I WHERE %I IS NOT NULL
            AND char_length(%I) NOT BETWEEN 1 AND %s', field_info.table_name, field_info.column_name, field_info.column_name, field_info.n)
        INTO invalid;
        PERFORM pg_temp.assert(invalid = 0, format('длина %s.%s', field_info.table_name, field_info.column_name));
    END LOOP;
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM client WHERE password !~ '^[0-9a-f]{32}$'
        OR phone_number !~ '^[0-9]{1,11}$'), 'формат клиента');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM courier WHERE phone_number !~ '^[0-9]{1,11}$'), 'телефон курьера');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM legal_entity
        WHERE inn !~ '^[0-9]{10}([0-9]{2})?$' OR ogrn !~ '^[0-9]{13}([0-9]{2})?$'), 'реквизиты');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM restaurant WHERE settlement_account !~ '^[0-9]{20}$'
        OR work_end <= work_start), 'счёт и график');
    PERFORM pg_temp.assert(NOT EXISTS (
        SELECT photo_url FROM product WHERE photo_url IS NOT NULL AND photo_url !~ '^https://cdn[.]foodexpress[.]ru/img/[0-9a-f]{32}[.]jpg$'
        UNION ALL SELECT photo_url FROM review WHERE photo_url IS NOT NULL AND photo_url !~ '^https://cdn[.]foodexpress[.]ru/img/[0-9a-f]{32}[.]jpg$'
    ), 'URL');
    PERFORM pg_temp.assert(EXISTS (SELECT FROM courier WHERE status <> 'уволен'), 'активный курьер');
    PERFORM pg_temp.assert(EXISTS (SELECT FROM "order" WHERE status = 'доставлен'
        AND order_timestamp >= date_trunc('month', localtimestamp)), 'текущая доставка');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM courier WHERE hire_date < current_date - 180
        OR hire_date > current_date OR dismissal_date < hire_date OR dismissal_date > current_date
        OR (status = 'уволен') <> (dismissal_date IS NOT NULL)), 'даты курьера');

    FOR field_info IN SELECT * FROM (VALUES ('order', 'order_timestamp'), ('order', 'delivery_timestamp'),
        ('payment', 'transaction_timestamp'), ('review', 'review_timestamp')) AS t(tbl, col)
    LOOP
        EXECUTE format('SELECT count(*) FROM khrestianovskii_food.%I WHERE %I < greatest(
            localtimestamp - interval ''180 days'', localtimestamp - interval ''6 months'',
            date_trunc(''month'', localtimestamp) - interval ''5 months'') OR %I > localtimestamp',
            field_info.tbl, field_info.col, field_info.col) INTO invalid;
        PERFORM pg_temp.assert(invalid = 0, format('интервал %s.%s', field_info.tbl, field_info.col));
    END LOOP;
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM "order" o JOIN courier c USING(courier_id)
        WHERE o.order_timestamp < c.hire_date OR o.order_timestamp::date > c.dismissal_date
        OR o.delivery_timestamp::date > c.dismissal_date
        OR o.delivery_timestamp < o.order_timestamp
        OR (o.status = 'доставлен') <> (o.delivery_timestamp IS NOT NULL)), 'хронология заказов');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM payment p JOIN "order" o USING(order_id)
        WHERE p.transaction_timestamp < o.order_timestamp OR p.transaction_timestamp > o.delivery_timestamp), 'время оплаты');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM review r JOIN "order" o USING(order_id)
        WHERE r.review_timestamp < coalesce(o.delivery_timestamp, o.order_timestamp)), 'время отзыва');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM "order" o LEFT JOIN client_address a
        USING(client_id, address_id) WHERE a.client_id IS NULL), 'адрес заказа');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM order_structure s JOIN "order" o USING(order_id)
        JOIN product p USING(product_id) WHERE p.restaurant_id <> o.restaurant_id), 'ресторан блюда');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM restaurant r JOIN client_address a USING(address_id)), 'разделение адресов');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM address a LEFT JOIN restaurant r USING(address_id)
        LEFT JOIN client_address c USING(address_id) WHERE r.restaurant_id IS NULL AND c.client_id IS NULL), 'все адреса используются');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM "order" o LEFT JOIN payment p USING(order_id)
        GROUP BY o.order_id HAVING count(p.payment_id) <> 1 OR count(*) FILTER(WHERE p.status = 'успех') <> 1), 'одна успешная оплата');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM order_totals WHERE total_amount < 1000
        OR commission <> round(order_amount * 0.1, 2) OR total_amount <> order_amount + commission
        OR pay_status <> 'оплачен'), 'суммы заказа');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM payment_details p JOIN order_totals o USING(order_id)
        WHERE p.amount <> o.total_amount), 'сумма платежа');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM review_details r JOIN "order" o USING(order_id)
        WHERE r.client_id <> o.client_id OR NOT (
            (r.entity_type = 'заказ' AND r.entity_id = o.order_id)
            OR (r.entity_type = 'ресторан' AND r.entity_id = o.restaurant_id)
            OR (r.entity_type = 'блюдо' AND EXISTS (SELECT FROM order_structure s
                WHERE s.order_id = r.order_id AND s.product_id = r.entity_id)))), 'объект и автор отзыва');
    PERFORM pg_temp.assert(NOT EXISTS (SELECT FROM product p WHERE p.rating IS DISTINCT FROM
        (SELECT round(avg(r.rating), 2) FROM review r WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id))
        AND NOT EXISTS (SELECT FROM restaurant p WHERE p.rating IS DISTINCT FROM
        (SELECT round(avg(r.rating), 2) FROM review r WHERE r.entity_type = 'ресторан' AND r.entity_id = p.restaurant_id)), 'средние рейтинги');
END;
$$;

-- Независимое ожидание: предыдущий месяц определяет коэффициент следующего.
CREATE FUNCTION pg_temp.check_pay()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE invalid bigint;
BEGIN
    WITH RECURSIVE delivered AS (
        SELECT courier_id, date_trunc('month', order_timestamp)::date AS m,
            count(*) AS cnt, sum(commission) AS commission
        FROM order_totals WHERE status = 'доставлен'
        GROUP BY courier_id, date_trunc('month', order_timestamp)::date
    ), monthly AS (
        SELECT c.courier_id, c.dismissal_date, g.m::date AS m, coalesce(d.cnt, 0) AS cnt,
            coalesce(d.commission, 0) AS commission,
            CASE WHEN coalesce(d.cnt,0) < 151 THEN 0.1 WHEN d.cnt < 251 THEN 0.2
                 WHEN d.cnt < 501 THEN 0.3 ELSE 0.5 END AS next_coefficient
        FROM courier c CROSS JOIN generate_series(date_trunc('month', localtimestamp) - interval '5 months',
            date_trunc('month', localtimestamp), interval '1 month') g(m)
        LEFT JOIN delivered d ON d.courier_id = c.courier_id AND d.m = g.m::date
    ), expected AS (
        SELECT m.*, 0.1::numeric AS coefficient FROM monthly m
        WHERE m.m = (date_trunc('month', localtimestamp) - interval '5 months')::date
        UNION ALL
        SELECT m.*, CASE WHEN e.dismissal_date < e.m + interval '1 month'
            THEN e.coefficient ELSE e.next_coefficient END
        FROM expected e JOIN monthly m ON m.courier_id = e.courier_id AND m.m = e.m + interval '1 month'
    )
    SELECT count(*) INTO invalid FROM expected e FULL JOIN courier_pay p
        ON p.courier_id = e.courier_id AND p.year = extract(year FROM e.m) AND p.month = extract(month FROM e.m)
    LEFT JOIN courier c ON c.courier_id = e.courier_id
    WHERE e.courier_id IS NULL OR p.courier_id IS NULL OR p.coefficient_used <> e.coefficient
        OR p.amount <> round(e.commission * e.coefficient, 2)
        OR (e.m = date_trunc('month', localtimestamp)::date AND c.coefficient <>
            CASE WHEN c.status = 'уволен' THEN e.coefficient ELSE e.next_coefficient END);
    PERFORM pg_temp.assert(invalid = 0, 'история выплат и коэффициентов');
END;
$$;

-- Снимок объектов схемы: очистка должна сохранять даже их OID.
CREATE TEMP TABLE objects_before ON COMMIT DROP AS
SELECT 'class' AS kind, oid FROM pg_class WHERE relnamespace = 'khrestianovskii_food'::regnamespace
UNION ALL SELECT 'proc', oid FROM pg_proc WHERE pronamespace = 'khrestianovskii_food'::regnamespace
UNION ALL SELECT 'type', oid FROM pg_type WHERE typnamespace = 'khrestianovskii_food'::regnamespace
UNION ALL SELECT 'trigger', oid FROM pg_trigger WHERE tgrelid IN
    (SELECT oid FROM pg_class WHERE relnamespace = 'khrestianovskii_food'::regnamespace);

CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(0);
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(10), pg_temp.check_data(), pg_temp.check_pay();
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(0);
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(1);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(1), pg_temp.check_data(), pg_temp.check_pay();

-- Повторный вызов должен сохранить все прежние строки без изменений.
CREATE TEMP TABLE saved_rows(tbl text, row_data jsonb) ON COMMIT DROP;
DO $$ DECLARE t text; BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'khrestianovskii_food' LOOP
        EXECUTE format('INSERT INTO saved_rows SELECT %L, to_jsonb(t) FROM khrestianovskii_food.%I t', t, t);
    END LOOP;
END; $$;
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(10);
DO $$ DECLARE t text; missing boolean; BEGIN
    FOR t IN SELECT DISTINCT tbl FROM saved_rows LOOP
        EXECUTE format('SELECT EXISTS(SELECT row_data FROM saved_rows WHERE tbl = %L
            EXCEPT SELECT to_jsonb(t) FROM khrestianovskii_food.%I t)', t, t) INTO missing;
        PERFORM pg_temp.assert(NOT missing, 'старые данные: ' || t);
    END LOOP;
    FOR i IN 1..10 LOOP CALL insert_test_data(10); END LOOP;
END; $$;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(111), pg_temp.check_data(), pg_temp.check_pay();

-- Ошибка аргумента должна возникать до любых изменений.
DO $$ DECLARE n int; before_count bigint; BEGIN
    SELECT count(*) INTO before_count FROM client;
    FOREACH n IN ARRAY ARRAY[NULL::int, 0, -1, 429496730, 2147483647] LOOP
        BEGIN
            CALL insert_test_data(n);
            RAISE EXCEPTION 'Принят недопустимый аргумент %', n;
        EXCEPTION WHEN invalid_parameter_value THEN NULL;
        END;
    END LOOP;
    PERFORM pg_temp.assert((SELECT count(*) = before_count FROM client), 'атомарность неверных аргументов');
END; $$;

-- Детерминированные границы выражений длины; случайность не гарантирует их покрытия.
DO $$ DECLARE n int; k int; s text; BEGIN
    FOREACH n IN ARRAY ARRAY[11,20,50,80,100,150] LOOP
        FOREACH k IN ARRAY ARRAY[1,n] LOOP
            SELECT string_agg(substring('абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                1 + floor(random()*33)::int, 1), '') INTO s FROM generate_series(1,33);
            PERFORM pg_temp.assert(char_length(substring(repeat(s, ceil(n/33.0)::int),1,k)) = k,
                format('граница длины %s/%s', k,n));
            PERFORM pg_temp.assert(char_length(substring(repeat(md5(random()::text),ceil(n/32.0)::int),1,k)) = k,
                format('граница MD5 %s/%s', k,n));
        END LOOP;
    END LOOP;
END; $$;

SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(0);
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(1000);
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(1000), pg_temp.check_data(), pg_temp.check_pay();

-- Граничные нагрузки маловероятны при случайном распределении 5n заказов на n курьеров.
-- Поэтому исполняем реальный блок расчёта из установленной процедуры на отдельной
-- фикстуре, а ожидаемые выплаты проверяем независимым check_pay().
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL insert_test_data(8);
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
DELETE FROM courier_pay;
DO $$
DECLARE
    ids uuid[];
    oids uuid[] := ARRAY[]::uuid[];
    counts int[] := ARRAY[0,150,151,250,251,500,501,501];
    coefs numeric[] := ARRAY[0.1,0.1,0.2,0.2,0.3,0.3,0.5,0.1];
    c uuid; a uuid; r uuid; p uuid; o uuid;
    i int; j int; source text; payroll text[];
    prev_month timestamp := date_trunc('month', localtimestamp) - interval '1 month';
BEGIN
    SELECT array_agg(courier_id ORDER BY courier_id) INTO ids FROM courier;
    UPDATE courier SET status = 'свободен', dismissal_date = NULL, coefficient = 0.1;
    UPDATE courier SET status = 'уволен', dismissal_date = (prev_month + interval '15 days')::date
    WHERE courier_id = ids[8];
    SELECT client_id, address_id INTO c,a FROM client_address LIMIT 1;
    SELECT product_id, restaurant_id INTO p,r FROM product LIMIT 1;
    FOR i IN 1..8 LOOP
        FOR j IN 1..counts[i] LOOP
            o := exts.uuid_generate_v4();
            oids := array_append(oids, o);
            INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id,
                order_timestamp,delivery_timestamp,status)
            VALUES(o,ids[i],c,a,r,prev_month + interval '1 day',prev_month + interval '25 hours','доставлен');
            INSERT INTO order_structure VALUES(o,p,1,1000);
            INSERT INTO payment VALUES(exts.uuid_generate_v4(),o,'карта',exts.uuid_generate_v4()::text,
                prev_month + interval '1 day','успех');
        END LOOP;
    END LOOP;
    source := pg_get_functiondef('khrestianovskii_food.insert_test_data(integer)'::regprocedure);
    payroll := regexp_match(source, '(?s)(FOR v_pay IN.*?WHERE c.courier_id = x.courier_id;)');
    PERFORM pg_temp.assert(payroll IS NOT NULL, 'найден реальный блок расчёта выплат');
    EXECUTE format('DO $pay$ DECLARE v_pay record; v_orders uuid[] := %L::uuid[];
        v_couriers uuid[] := %L::uuid[]; v_dismissals date[] := %L::date[];
        v_coefficients numeric[] := array_fill(0.1::numeric,ARRAY[8]);
        value int := 8; v_month date := %L::date; v_now timestamp := localtimestamp;
        BEGIN %s END; $pay$', oids, ids,
        ARRAY[NULL::date,NULL,NULL,NULL,NULL,NULL,NULL,(prev_month + interval '15 days')::date],
        (date_trunc('month',localtimestamp) - interval '5 months')::date, payroll[1]);
    FOR i IN 1..8 LOOP
        PERFORM pg_temp.assert((SELECT coefficient_used = coefs[i] FROM courier_pay
            WHERE courier_id = ids[i] AND year = extract(year FROM current_date)
                AND month = extract(month FROM current_date)), 'порог доставок ' || counts[i]);
    END LOOP;
END;
$$;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_pay();
SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.check_counts(0);
SELECT pg_temp.assert(NOT EXISTS (
    SELECT kind, oid FROM objects_before EXCEPT
    (SELECT 'class', oid FROM pg_class WHERE relnamespace = 'khrestianovskii_food'::regnamespace
     UNION ALL SELECT 'proc', oid FROM pg_proc WHERE pronamespace = 'khrestianovskii_food'::regnamespace
     UNION ALL SELECT 'type', oid FROM pg_type WHERE typnamespace = 'khrestianovskii_food'::regnamespace
     UNION ALL SELECT 'trigger', oid FROM pg_trigger WHERE tgrelid IN
        (SELECT oid FROM pg_class WHERE relnamespace = 'khrestianovskii_food'::regnamespace))
), 'сохранность объектов схемы');
ROLLBACK;
\echo 'OK: FOOD-102/103; все тестовые изменения отменены'

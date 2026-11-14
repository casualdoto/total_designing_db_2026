-- FOOD-107. После schema/*.sql и grants.sql:
-- psql -v ON_ERROR_STOP=1 -f db/check_courier_salary.sql
-- Только тестовая БД; под inspector; все изменения откатываются.
\timing on
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;

CREATE FUNCTION pg_temp.assert(p_ok boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %', p_message; END IF;
END;
$$;

CREATE FUNCTION pg_temp.expect_pay(p_id uuid, p_amount numeric, p_used numeric, p_next numeric)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.assert((SELECT amount=p_amount AND coefficient_used=p_used FROM courier_pay
        WHERE courier_id=p_id AND year=extract(year FROM current_date) AND month=extract(month FROM current_date)),
        format('выплата %s: сумма %s, коэффициент %s',p_id,p_amount,p_used));
    PERFORM pg_temp.assert((SELECT coefficient=p_next FROM courier WHERE courier_id=p_id), 'коэффициент следующего месяца');
END;
$$;

CREATE FUNCTION pg_temp.add_orders(p_courier uuid, p_count int, p_time timestamp,
    p_status khrestianovskii_food.order_status DEFAULT 'доставлен',
    p_quantity numeric DEFAULT 1, p_price numeric DEFAULT 1000, p_extra boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE ids uuid[]; v_client uuid; v_address uuid; v_restaurant uuid; products uuid[];
BEGIN
    SELECT ca.client_id,ca.address_id INTO STRICT v_client,v_address FROM client_address ca LIMIT 1;
    SELECT restaurant_id INTO STRICT v_restaurant FROM restaurant LIMIT 1;
    SELECT array_agg(product_id ORDER BY product_id) INTO products FROM product WHERE restaurant_id=v_restaurant;
    SELECT array_agg(exts.uuid_generate_v4()) INTO ids FROM generate_series(1,p_count);
    INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id,order_timestamp,delivery_timestamp,status)
    SELECT id,p_courier,v_client,v_address,v_restaurant,p_time,
        CASE WHEN p_status='доставлен' THEN greatest(p_time,localtimestamp) END,p_status FROM unnest(ids) g(id);
    INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
    SELECT id,products[1],p_quantity,p_price FROM unnest(ids) g(id);
    IF p_extra THEN
        INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
        SELECT id,products[2],0.5,2000.01 FROM unnest(ids) g(id);
    END IF;
    INSERT INTO payment(order_id,type,transaction_id,status)
    SELECT id,'карта',exts.uuid_generate_v4()::text,'успех' FROM unnest(ids) g(id);
END;
$$;

CALL erase_test_data();
CALL courier_salary();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM courier_pay), 'пустая схема');
SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(10);
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE generated_pay ON COMMIT DROP AS SELECT * FROM courier_pay;
CREATE TEMP TABLE history_before ON COMMIT DROP AS SELECT * FROM courier_pay
WHERE year<>extract(year FROM current_date) OR month<>extract(month FROM current_date);
CALL courier_salary();
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM generated_pay EXCEPT SELECT * FROM courier_pay)
    UNION ALL (SELECT * FROM courier_pay EXCEPT SELECT * FROM generated_pay)), 'после генератора выплаты согласованы');

SET CONSTRAINTS ALL DEFERRED;
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
DELETE FROM courier_pay WHERE year=extract(year FROM current_date) AND month=extract(month FROM current_date);
CREATE TEMP TABLE salary_fixture(i int PRIMARY KEY, id uuid, cnt int, used numeric, next_coefficient numeric) ON COMMIT DROP;
INSERT INTO salary_fixture
SELECT row_number() OVER(ORDER BY courier_id),courier_id,0,0.1,0.1 FROM courier;
DO $$
DECLARE
    cs uuid[]; counts int[] := ARRAY[0,150,151,250,251,500,501];
    rates numeric[] := ARRAY[0.5,0.4,0.3,0.2,0.1,0.5,0.2,0.3,0.4,0.2];
    next_rates numeric[] := ARRAY[0.1,0.1,0.2,0.2,0.3,0.3,0.5];
    v_start timestamp := date_trunc('month',localtimestamp);
    v_i int; excluded khrestianovskii_food.order_status;
BEGIN
    SELECT array_agg(f.id ORDER BY f.i) INTO cs FROM salary_fixture f;
    UPDATE courier SET status='свободен',dismissal_date=NULL;
    FOR v_i IN 1..10 LOOP
        UPDATE courier SET coefficient=rates[v_i] WHERE courier_id=cs[v_i];
        UPDATE salary_fixture f SET used=rates[v_i] WHERE f.i=v_i;
    END LOOP;
    UPDATE courier SET status='уволен',dismissal_date=current_date WHERE courier_id IN (cs[8],cs[9]);
    FOR v_i IN 1..7 LOOP
        PERFORM pg_temp.add_orders(cs[v_i],counts[v_i],v_start,'доставлен',1,1000,v_i=2);
        UPDATE salary_fixture f SET cnt=counts[v_i],next_coefficient=next_rates[v_i] WHERE f.i=v_i;
    END LOOP;
    -- 0.5*2000.11 + 0.5*2000.01 = 2000.06; комиссия 200.01 на заказ;
    -- две комиссии * 0.3 = 120.006 -> 120.01, а не 120.00.
    PERFORM pg_temp.add_orders(cs[8],2,v_start,'доставлен',0.5,2000.11,true);
    PERFORM pg_temp.add_orders(cs[10],1,v_start);
    -- Предыдущий месяц, доставка в текущем: исключаем по order_timestamp.
    PERFORM pg_temp.add_orders(cs[10],1,v_start-interval '1 microsecond');
    PERFORM pg_temp.add_orders(cs[10],1,v_start-interval '1 month');
    -- Верхняя граница текущего месяца исключительна.
    PERFORM pg_temp.add_orders(cs[10],1,v_start+interval '1 month');
    FOREACH excluded IN ARRAY array_remove(enum_range(NULL::khrestianovskii_food.order_status),'доставлен') LOOP
        PERFORM pg_temp.add_orders(cs[10],1,v_start,excluded);
    END LOOP;
END;
$$;
SET CONSTRAINTS ALL IMMEDIATE;
CALL courier_salary();
DO $$ DECLARE f record; BEGIN
    FOR f IN SELECT * FROM salary_fixture WHERE i<=7 ORDER BY i LOOP
        PERFORM pg_temp.expect_pay(f.id,f.cnt*CASE WHEN f.i=2 THEN 200 ELSE 100 END*f.used,f.used,f.next_coefficient);
    END LOOP;
    PERFORM pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=8),120.01,0.3,0.3);
    PERFORM pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=9),0,0.4,0.4);
    PERFORM pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=10),20,0.2,0.1);
    RAISE NOTICE 'OK: пороги, дробные количества, несколько позиций, округление, статусы, границы месяца, увольнение';
END;
$$;

CREATE TEMP TABLE pay_snapshot ON COMMIT DROP AS SELECT * FROM courier_pay;
CREATE TEMP TABLE courier_snapshot ON COMMIT DROP AS SELECT * FROM courier;
CALL courier_salary();
CALL courier_salary();
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM pay_snapshot EXCEPT SELECT * FROM courier_pay)
    UNION ALL (SELECT * FROM courier_pay EXCEPT SELECT * FROM pay_snapshot)), 'повторные вызовы: выплаты неизменны');
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM courier_snapshot EXCEPT SELECT * FROM courier)
    UNION ALL (SELECT * FROM courier EXCEPT SELECT * FROM courier_snapshot)), 'повторные вызовы: коэффициенты неизменны');

SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.add_orders((SELECT id FROM salary_fixture WHERE i=2),1,date_trunc('month',localtimestamp));
SET CONSTRAINTS ALL IMMEDIATE;
CALL courier_salary();
SELECT pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=2),12040,0.4,0.2);
UPDATE product SET price=0;
CALL courier_salary();
SELECT pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=2),12040,0.4,0.2);

SET CONSTRAINTS ALL DEFERRED;
DELETE FROM payment WHERE order_id IN (SELECT order_id FROM "order" WHERE courier_id=(SELECT id FROM salary_fixture WHERE i=8));
DELETE FROM order_structure WHERE order_id IN (SELECT order_id FROM "order" WHERE courier_id=(SELECT id FROM salary_fixture WHERE i=8));
DELETE FROM "order" WHERE courier_id=(SELECT id FROM salary_fixture WHERE i=8);
SET CONSTRAINTS ALL IMMEDIATE;
CALL courier_salary();
SELECT pg_temp.expect_pay((SELECT id FROM salary_fixture WHERE i=8),0,0.3,0.3);
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM history_before EXCEPT SELECT * FROM courier_pay)
    UNION ALL (SELECT * FROM courier_pay WHERE year<>extract(year FROM current_date)
        OR month<>extract(month FROM current_date) EXCEPT SELECT * FROM history_before)), 'история других месяцев сохранена');

-- 51 * round(5*99999.99*0.1,2) * 0.4 = 1020000, больше numeric(8,2).
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.add_orders((SELECT id FROM salary_fixture WHERE i=9),51,date_trunc('month',localtimestamp),'доставлен',5,99999.99);
SET CONSTRAINTS ALL IMMEDIATE;
TRUNCATE pay_snapshot,courier_snapshot;
INSERT INTO pay_snapshot SELECT * FROM courier_pay;
INSERT INTO courier_snapshot SELECT * FROM courier;
DO $$ DECLARE failed boolean := false; BEGIN
    BEGIN CALL courier_salary();
    EXCEPTION WHEN numeric_value_out_of_range THEN failed := true;
    END;
    PERFORM pg_temp.assert(failed,'переполнение должно быть отклонено с 22003');
    PERFORM pg_temp.assert(NOT EXISTS(
        (SELECT * FROM pay_snapshot EXCEPT SELECT * FROM courier_pay)
        UNION ALL (SELECT * FROM courier_pay EXCEPT SELECT * FROM pay_snapshot)), 'атомарность выплат при переполнении');
    PERFORM pg_temp.assert(NOT EXISTS(
        (SELECT * FROM courier_snapshot EXCEPT SELECT * FROM courier)
        UNION ALL (SELECT * FROM courier EXCEPT SELECT * FROM courier_snapshot)), 'атомарность коэффициентов при переполнении');
    RAISE NOTICE 'OK: повторные вызовы, новые доставки, исторические цены, история выплат и атомарность';
END;
$$;
SELECT pg_temp.assert((SELECT NOT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, khrestianovskii_food']
    FROM pg_proc WHERE oid='khrestianovskii_food.courier_salary()'::regprocedure), 'права и фиксированный search_path');
ROLLBACK;
\echo 'OK: FOOD-107; все тестовые изменения отменены'

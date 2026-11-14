-- FOOD-108. После schema/*.sql и grants.sql:
-- psql -v ON_ERROR_STOP=1 -f db/check_how_much_money.sql
-- Только тестовая БД; под inspector; все изменения откатываются.
\timing on
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;

CREATE FUNCTION pg_temp.assert(p_ok boolean, p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL: %',p_message; END IF;
END;
$$;

CREATE FUNCTION pg_temp.report_order(p_time timestamp, p_status khrestianovskii_food.order_status,
    p_quantity numeric DEFAULT 1, p_price numeric DEFAULT 1000, p_extra boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE id uuid := exts.uuid_generate_v4(); v_client uuid; v_address uuid;
    v_courier uuid; v_restaurant uuid; products uuid[];
BEGIN
    SELECT ca.client_id,ca.address_id INTO STRICT v_client,v_address FROM client_address ca LIMIT 1;
    SELECT courier_id INTO STRICT v_courier FROM courier LIMIT 1;
    SELECT restaurant_id INTO STRICT v_restaurant FROM restaurant LIMIT 1;
    SELECT array_agg(product_id ORDER BY product_id) INTO products FROM product WHERE restaurant_id=v_restaurant;
    INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id,order_timestamp,delivery_timestamp,status)
    VALUES(id,v_courier,v_client,v_address,v_restaurant,p_time,
        CASE WHEN p_status='доставлен' THEN p_time+interval '1 day' END,p_status);
    INSERT INTO order_structure VALUES(id,products[1],p_quantity,p_price);
    IF p_extra THEN INSERT INTO order_structure VALUES(id,products[2],0.5,2000.01); END IF;
    INSERT INTO payment(order_id,type,transaction_id,status)
    VALUES(id,'карта',exts.uuid_generate_v4()::text,'успех');
    RETURN id;
END;
$$;

CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM how_much_money), 'пустая схема');
SELECT pg_temp.assert((SELECT array_agg(column_name::text ORDER BY ordinal_position) =
    ARRAY['year_month','sum_no_commission','sum_with_commission','commission','prev_commission','commission_diff','courier_pay','net_profit']
    AND array_agg(data_type::text ORDER BY ordinal_position) =
    ARRAY['text','numeric','numeric','numeric','numeric','numeric','numeric','numeric']
    FROM information_schema.columns WHERE table_schema='khrestianovskii_food' AND table_name='how_much_money'), 'контракт восьми колонок');
SELECT pg_temp.assert((SELECT relkind='v' AND reloptions @> ARRAY['security_invoker=true']
    FROM pg_class WHERE oid='khrestianovskii_food.how_much_money'::regclass), 'обычное представление, security_invoker');
SELECT pg_temp.assert(pg_get_viewdef('khrestianovskii_food.how_much_money'::regclass,true) ~* 'WITH RECURSIVE'
    AND pg_get_viewdef('khrestianovskii_food.how_much_money'::regclass,true) !~* 'generate_series', 'рекурсивный календарь');

SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(2);
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
DELETE FROM courier_pay;
UPDATE courier SET hire_date=date '2023-01-01';
INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
SELECT 2023,11,courier_id,1000,0.1 FROM courier;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM how_much_money), 'выплаты без доставок не задают календарь');
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.report_order(timestamp '2023-11-01','создан');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM how_much_money), 'только недоставленные заказы');
INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
SELECT 2023,12,courier_id,CASE WHEN courier_id=(SELECT min_id FROM (SELECT courier_id AS min_id FROM courier ORDER BY courier_id LIMIT 1) x)
    THEN 25 ELSE 15 END,0.1 FROM courier;
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.report_order(timestamp '2023-12-31 23:59:59','доставлен');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert((SELECT count(*)=1 FROM how_much_money), 'один месяц, выплаты за ноябрь не расширяют календарь');
SELECT pg_temp.assert((SELECT year_month='2023-12' AND sum_no_commission=1000 AND sum_with_commission=1100
    AND commission=100 AND prev_commission IS NULL AND commission_diff IS NULL AND courier_pay=40 AND net_profit=60
    FROM how_much_money), 'первый месяц, сумма выплат двух курьеров, месяц создания вместо доставки');

SET CONSTRAINTS ALL DEFERRED;
DO $$ DECLARE excluded khrestianovskii_food.order_status; BEGIN
    FOREACH excluded IN ARRAY array_remove(enum_range(NULL::khrestianovskii_food.order_status),'доставлен') LOOP
        PERFORM pg_temp.report_order(timestamp '2024-01-15',excluded,50,1000);
    END LOOP;
    PERFORM pg_temp.report_order(timestamp '2024-03-03','доставлен',0.5,2000.11,true);
    PERFORM pg_temp.report_order(timestamp '2024-03-04','доставлен',0.5,2000.11,true);
END; $$;
INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
SELECT 2024,2,courier_id,CASE WHEN courier_id=(SELECT courier_id FROM courier ORDER BY courier_id LIMIT 1)
    THEN 20 ELSE 30 END,0.1 FROM courier;
INSERT INTO courier_pay(year,month,courier_id,amount,coefficient_used)
SELECT 2024,4,courier_id,500,0.1 FROM courier;
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE expected ON COMMIT DROP AS
SELECT * FROM (VALUES
    ('2023-12'::text,1000::numeric,1100::numeric,100::numeric,NULL::numeric,NULL::numeric,40::numeric,60::numeric),
    ('2024-01',0,0,0,100,-100,0,0),
    ('2024-02',0,0,0,0,0,50,-50),
    ('2024-03',4000.12,4400.14,400.02,0,400.02,0,400.02)
) AS t(year_month,sum_no_commission,sum_with_commission,commission,prev_commission,commission_diff,courier_pay,net_profit);
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM expected EXCEPT SELECT * FROM how_much_money)
    UNION ALL (SELECT * FROM how_much_money EXCEPT SELECT * FROM expected)), 'все суммы, декабрь-январь, два пробела календаря, отрицательная прибыль и округления');
UPDATE product SET price=0;
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM expected EXCEPT SELECT * FROM how_much_money)
    UNION ALL (SELECT * FROM how_much_money EXCEPT SELECT * FROM expected)), 'текущие цены не меняют отчёт');
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.report_order(timestamp '2024-02-29 23:59:59','доставлен');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert((SELECT sum_no_commission=1000 AND commission=100 AND prev_commission=0
    AND commission_diff=100 AND courier_pay=50 AND net_profit=50 FROM how_much_money WHERE year_month='2024-02'), '29 февраля и актуальность без REFRESH');
SELECT pg_temp.assert((SELECT prev_commission=100 AND commission_diff=300.02
    FROM how_much_money WHERE year_month='2024-03'), 'LAG видит обновлённый предыдущий месяц');
UPDATE "order" SET status='отменён',delivery_timestamp=NULL WHERE order_timestamp=timestamp '2024-03-03';
SELECT pg_temp.assert((SELECT sum_no_commission=2000.06 AND sum_with_commission=2200.07
    AND commission=200.01 AND commission_diff=100.01 FROM how_much_money WHERE year_month='2024-03'), 'изменение статуса отражается сразу');
UPDATE "order" SET status='отменён',delivery_timestamp=NULL WHERE order_timestamp=timestamp '2024-03-04';
SELECT pg_temp.assert((SELECT count(*)=3 AND max(year_month)='2024-02' FROM how_much_money), 'границы сокращаются по доставкам, не выплатам');

SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL insert_test_data(1000);
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE reference_orders ON COMMIT DROP AS
SELECT date_trunc('month',order_timestamp)::date AS m,sum(order_amount) AS no_commission,
    sum(total_amount) AS with_commission,sum(commission) AS commission
FROM order_totals WHERE status='доставлен' GROUP BY date_trunc('month',order_timestamp)::date;
CREATE TEMP TABLE reference_pay ON COMMIT DROP AS
SELECT make_date(year,month,1) AS m,sum(amount) AS amount FROM courier_pay GROUP BY year,month;
CREATE TEMP TABLE reference_base ON COMMIT DROP AS
SELECT g.m::date,coalesce(o.no_commission,0) AS no_commission,coalesce(o.with_commission,0) AS with_commission,
    coalesce(o.commission,0) AS commission,coalesce(p.amount,0) AS pay
FROM generate_series((SELECT min(m) FROM reference_orders)::timestamp,
    (SELECT max(m) FROM reference_orders)::timestamp,interval '1 month') g(m)
LEFT JOIN reference_orders o ON o.m=g.m::date LEFT JOIN reference_pay p ON p.m=g.m::date;
CREATE TEMP TABLE load_expected ON COMMIT DROP AS
SELECT to_char(c.m,'YYYY-MM') AS year_month,c.no_commission,c.with_commission,c.commission,
    p.commission AS prev_commission,c.commission-p.commission AS commission_diff,c.pay,c.commission-c.pay AS net_profit
FROM reference_base c LEFT JOIN reference_base p ON p.m=(c.m-interval '1 month')::date;
SELECT pg_temp.assert(NOT EXISTS(
    (SELECT * FROM load_expected EXCEPT SELECT * FROM how_much_money)
    UNION ALL (SELECT * FROM how_much_money EXCEPT SELECT * FROM load_expected)), 'независимая сверка всех восьми колонок на генерации 1000');
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM how_much_money WHERE year_month !~ '^[0-9]{4}-[0-9]{2}$'), 'формат YYYY-MM');
ROLLBACK;
\echo 'OK: FOOD-108; все тестовые изменения отменены'

-- FOOD-106. После schema/*.sql и grants.sql:
-- psql -v ON_ERROR_STOP=1 -f db/check_get_statistic.sql
-- Только тестовая БД; под inspector, все данные откатываются.
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

CREATE FUNCTION pg_temp.make_order(p_restaurant uuid, p_client uuid, p_courier uuid,
    p_status khrestianovskii_food.order_status, p_products uuid[], p_quantities numeric[], p_prices numeric[])
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE id uuid := exts.uuid_generate_v4(); address uuid;
BEGIN
    SELECT address_id INTO STRICT address FROM client_address WHERE client_id=p_client LIMIT 1;
    INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id,status,delivery_timestamp)
    VALUES(id,p_courier,p_client,address,p_restaurant,p_status,
        CASE WHEN p_status='доставлен' THEN localtimestamp END);
    INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
    SELECT id,s.product_id,s.quantity,s.price FROM unnest(p_products,p_quantities,p_prices) s(product_id,quantity,price);
    INSERT INTO payment(order_id,type,transaction_id,status)
    VALUES(id,'карта',exts.uuid_generate_v4()::text,'успех');
    RETURN id;
END;
$$;

CALL erase_test_data();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT pg_temp.assert(NOT EXISTS(SELECT FROM get_statistic()), 'пустая схема');
CREATE TEMP TABLE result_contract ON COMMIT DROP AS SELECT * FROM get_statistic();
SELECT pg_temp.assert((SELECT array_agg(a.attname::text ORDER BY a.attnum) =
    ARRAY['restaurant_name','best_product_name','total_amount','avg_amount','best_user']
    AND array_agg(a.atttypid ORDER BY a.attnum) =
    ARRAY['text'::regtype::oid,'text'::regtype::oid,'numeric'::regtype::oid,'numeric'::regtype::oid,'text'::regtype::oid]
    FROM pg_attribute a WHERE a.attrelid='pg_temp.result_contract'::regclass AND a.attnum>0 AND NOT a.attisdropped), 'имена, порядок и типы колонок');
SELECT pg_temp.assert((SELECT provolatile='v' AND NOT prosecdef
    AND proconfig @> ARRAY['search_path=pg_catalog, khrestianovskii_food']
    FROM pg_proc WHERE oid='khrestianovskii_food.get_statistic()'::regprocedure), 'VOLATILE, SECURITY INVOKER, search_path');

SET CONSTRAINTS ALL DEFERRED;
CALL insert_test_data(4);
DELETE FROM review;
DELETE FROM payment;
DELETE FROM order_structure;
DELETE FROM "order";
CREATE TEMP TABLE fixture_restaurants(i int PRIMARY KEY, id uuid) ON COMMIT DROP;
CREATE TEMP TABLE fixture_clients(i int PRIMARY KEY, id uuid) ON COMMIT DROP;
INSERT INTO fixture_restaurants SELECT row_number() OVER(ORDER BY restaurant_id),restaurant_id FROM restaurant;
INSERT INTO fixture_clients SELECT row_number() OVER(ORDER BY client_id),client_id FROM client;
DO $$
DECLARE rs uuid[]; cs uuid[]; ps uuid[]; v_courier uuid; ignored uuid;
    names text[] := ARRAY['empty','undelivered','mixed','ties'];
    excluded khrestianovskii_food.order_status;
    i int;
BEGIN
    SELECT array_agg(f.id ORDER BY f.i) INTO rs FROM fixture_restaurants f;
    SELECT array_agg(f.id ORDER BY f.i) INTO cs FROM fixture_clients f;
    SELECT courier_id INTO v_courier FROM khrestianovskii_food.courier LIMIT 1;
    FOR i IN 1..4 LOOP UPDATE restaurant SET restaurant_name=names[i] WHERE restaurant_id=rs[i]; END LOOP;
    UPDATE restaurant SET status='неактивен' WHERE restaurant_id=rs[3];
    SELECT array_agg(product_id ORDER BY product_id) INTO ps FROM product WHERE restaurant_id=rs[3];
    UPDATE product SET product_name='same' WHERE product_id IN (ps[1],ps[2]);
    UPDATE product SET product_name='leader' WHERE product_id=ps[3];
    ignored := pg_temp.make_order(rs[3],cs[1],v_courier,'доставлен',ARRAY[ps[1],ps[3]],ARRAY[5,4.5],ARRAY[100,200]);
    -- Проверяем всю историю: доставленный заказ старше окна генератора.
    UPDATE khrestianovskii_food.courier SET hire_date=current_date-365 WHERE courier_id=v_courier;
    UPDATE "order" SET order_timestamp=localtimestamp-interval '300 days',
        delivery_timestamp=localtimestamp-interval '300 days'+interval '1 hour' WHERE order_id=ignored;
    ignored := pg_temp.make_order(rs[3],cs[1],v_courier,'доставлен',ARRAY[ps[2],ps[3]],ARRAY[5,4],ARRAY[200,250]);
    ignored := pg_temp.make_order(rs[3],cs[2],v_courier,'доставлен',ps,ARRAY[0.001,0.001,0.001,0.5,0.5],ARRAY[0.01,0.01,0.01,4000.01,4000.01]);
    -- Клиент 2 имеет больше позиций и трат, клиент 1 — больше заказов.
    FOREACH excluded IN ARRAY array_remove(enum_range(NULL::khrestianovskii_food.order_status),'доставлен') LOOP
        ignored := pg_temp.make_order(rs[3],cs[3],v_courier,excluded,ARRAY[ps[4]],ARRAY[100],ARRAY[1000]);
    END LOOP;
    SELECT array_agg(product_id ORDER BY product_id) INTO ps FROM product WHERE restaurant_id=rs[2];
    FOREACH excluded IN ARRAY array_remove(enum_range(NULL::khrestianovskii_food.order_status),'доставлен') LOOP
        ignored := pg_temp.make_order(rs[2],cs[3],v_courier,excluded,ARRAY[ps[1]],ARRAY[100],ARRAY[1000]);
    END LOOP;
    SELECT array_agg(product_id ORDER BY product_id) INTO ps FROM product WHERE restaurant_id=rs[4];
    UPDATE product SET product_name=CASE WHEN product_id=ps[1] THEN 'tie_a' ELSE 'tie_b' END
    WHERE product_id IN (ps[1],ps[2]);
    ignored := pg_temp.make_order(rs[4],cs[3],v_courier,'доставлен',ps[1:2],ARRAY[1,1],ARRAY[1000,1000]);
    ignored := pg_temp.make_order(rs[4],cs[4],v_courier,'доставлен',ps[1:2],ARRAY[1,1],ARRAY[1000,1000]);
END;
$$;
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE actual ON COMMIT DROP AS SELECT * FROM get_statistic();
SELECT pg_temp.assert((SELECT count(*)=4 FROM actual), 'одна строка на ресторан');
SELECT pg_temp.assert((SELECT count(*)=2 FROM actual WHERE restaurant_name IN ('empty','undelivered')
    AND total_amount=0 AND avg_amount=0 AND best_product_name IS NULL AND best_user IS NULL), 'нулевые рестораны');
SELECT pg_temp.assert((SELECT total_amount=8140.01 AND avg_amount=8140.01/3
    AND best_product_name='leader' AND best_user=(SELECT login FROM client WHERE client_id=(SELECT id FROM fixture_clients WHERE i=1))
    FROM actual WHERE restaurant_name='mixed'), 'суммы, округление, дробные количества, частота покупок, одинаковые имена блюд');
SELECT pg_temp.assert((SELECT total_amount=4400 AND avg_amount=2200
    AND best_product_name IN ('tie_a','tie_b') FROM actual WHERE restaurant_name='ties'), 'суммы при ничьей');
DO $$ DECLARE t record; i int; BEGIN
    FOR i IN 1..40 LOOP
        SELECT * INTO STRICT t FROM get_statistic() WHERE restaurant_name='ties';
        PERFORM pg_temp.assert(t.best_product_name IN ('tie_a','tie_b') AND t.best_user IN
            (SELECT c.login FROM client c JOIN fixture_clients f ON f.id=c.client_id WHERE f.i IN (3,4)), 'победители только среди лидеров');
    END LOOP;
END; $$;
UPDATE product SET price=0;
SELECT pg_temp.assert((SELECT total_amount=8140.01 AND avg_amount=8140.01/3
    AND best_product_name='leader' FROM get_statistic() WHERE restaurant_name='mixed'), 'историческая цена');
UPDATE restaurant SET restaurant_name='duplicate' WHERE restaurant_id IN (SELECT id FROM fixture_restaurants WHERE i IN (3,4));
SELECT pg_temp.assert((SELECT count(*)=2 AND sum(total_amount)=12540.01 FROM get_statistic()
    WHERE restaurant_name='duplicate'), 'одинаковые имена ресторанов не объединяются');

SET CONSTRAINTS ALL DEFERRED;
CALL erase_test_data();
CALL insert_test_data(1000);
SET CONSTRAINTS ALL IMMEDIATE;
-- Уникальные имена нужны только тесту для однозначного сопоставления с UUID.
UPDATE restaurant SET restaurant_name=restaurant_id::text;
CREATE TEMP TABLE load_actual ON COMMIT DROP AS SELECT * FROM get_statistic();
SELECT pg_temp.assert((SELECT count(*)=1000 AND count(DISTINCT restaurant_name)=1000 FROM load_actual), '1000 ресторанов без повторов');
CREATE TEMP TABLE reference_money ON COMMIT DROP AS
SELECT restaurant_id,sum(total_amount) AS total_amount,avg(total_amount) AS avg_amount
FROM order_totals WHERE status='доставлен' GROUP BY restaurant_id;
-- Независимый эталон использует готовое представление, контрольные подзапросы
-- допустимы в тесте, но не в промышленной функции.
DO $$ DECLARE invalid bigint; BEGIN
    SELECT count(*) INTO invalid FROM load_actual a
    JOIN restaurant r ON r.restaurant_id::text=a.restaurant_name
    LEFT JOIN reference_money m ON m.restaurant_id=r.restaurant_id
    WHERE a.total_amount IS DISTINCT FROM coalesce(m.total_amount,0)
       OR a.avg_amount IS DISTINCT FROM coalesce(m.avg_amount,0)
       OR (EXISTS(SELECT FROM "order" o WHERE o.restaurant_id=r.restaurant_id AND o.status='доставлен') AND (
           NOT EXISTS(SELECT FROM product p JOIN order_structure s USING(product_id) JOIN "order" o USING(order_id)
               WHERE o.restaurant_id=r.restaurant_id AND o.status='доставлен' AND p.product_name=a.best_product_name
               GROUP BY p.product_id HAVING sum(s.quantity) >= ALL (
                   SELECT sum(s2.quantity) FROM order_structure s2 JOIN "order" o2 USING(order_id)
                   WHERE o2.restaurant_id=r.restaurant_id AND o2.status='доставлен' GROUP BY s2.product_id))
           OR NOT EXISTS(SELECT FROM client c JOIN "order" o USING(client_id)
               WHERE o.restaurant_id=r.restaurant_id AND o.status='доставлен' AND c.login=a.best_user
               GROUP BY c.client_id HAVING count(*) >= ALL (
                   SELECT count(*) FROM "order" o2 WHERE o2.restaurant_id=r.restaurant_id AND o2.status='доставлен'
                   GROUP BY o2.client_id))))
       OR (NOT EXISTS(SELECT FROM "order" o WHERE o.restaurant_id=r.restaurant_id AND o.status='доставлен')
           AND (a.best_product_name IS NOT NULL OR a.best_user IS NOT NULL));
    PERFORM pg_temp.assert(invalid=0, 'независимая сверка на 1000');
    RAISE NOTICE 'OK: независимая сверка сумм, средних и лидеров на 1000 ресторанах';
END; $$;

-- EXPLAIN настоящего SQL-тела, а не непрозрачного Function Scan.
SET LOCAL max_parallel_workers_per_gather=0;
DO $$
DECLARE source text; plan jsonb; node jsonb; base_scans int := 0; measured text;
BEGIN
    SELECT prosrc INTO source FROM pg_proc WHERE oid='khrestianovskii_food.get_statistic()'::regprocedure;
    PERFORM pg_temp.assert(source !~* '\m(lateral|over)\M', 'без LATERAL и окон');
    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || source INTO plan;
    FOR node IN
        WITH RECURSIVE nodes(n) AS (
            SELECT plan->0->'Plan' UNION ALL
            SELECT child FROM nodes CROSS JOIN LATERAL jsonb_array_elements(coalesce(n->'Plans','[]'::jsonb)) child
        ) SELECT n FROM nodes
    LOOP
        PERFORM pg_temp.assert(coalesce(node->>'Node Type','') NOT IN ('WindowAgg','Function Scan')
            AND coalesce(node->>'Parent Relationship','') <> 'SubPlan', 'без окон и коррелированных SubPlan');
        PERFORM pg_temp.assert(coalesce(node->>'Relation Name','') NOT IN ('payment','review'), 'без платежей/отзывов');
        IF node->>'Relation Name' IN ('order','order_structure') THEN
            base_scans := base_scans+1;
            PERFORM pg_temp.assert((node->>'Actual Loops')::numeric=1, 'один проход базовой таблицы');
            RAISE NOTICE 'EXPLAIN scan: %; node=%; loops=%; rows=%', node->>'Relation Name',
                node->>'Node Type',node->>'Actual Loops',node->>'Actual Rows';
        END IF;
    END LOOP;
    PERFORM pg_temp.assert(base_scans=2, 'по одному узлу чтения заказов и позиций');
    measured := format('Execution Time=%s ms; Shared Hit Blocks=%s; Shared Read Blocks=%s',
        plan->0->>'Execution Time',plan->0->'Plan'->>'Shared Hit Blocks',plan->0->'Plan'->>'Shared Read Blocks');
    RAISE NOTICE 'OK: EXPLAIN: %',measured;
END;
$$;
ROLLBACK;
\echo 'OK: FOOD-106; все тестовые изменения отменены'

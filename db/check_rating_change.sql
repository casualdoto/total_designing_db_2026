-- FOOD-105. После schema/*.sql и grants.sql:
-- psql -v ON_ERROR_STOP=1 -f db/check_rating_change.sql
-- Все фикстуры создаются под inspector и откатываются.
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

CREATE FUNCTION pg_temp.expect_rating(p_type khrestianovskii_food.review_entity_type, p_id uuid, p_expected numeric)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual numeric;
BEGIN
    IF p_type = 'блюдо' THEN SELECT rating INTO STRICT actual FROM product WHERE product_id = p_id;
    ELSE SELECT rating INTO STRICT actual FROM restaurant WHERE restaurant_id = p_id;
    END IF;
    PERFORM pg_temp.assert(actual IS NOT DISTINCT FROM p_expected,
        format('%s %s: рейтинг %s вместо %s',p_type,p_id,actual,p_expected));
END;
$$;

-- Нужны только новые рестораны; старые данные тест не меняет.
CREATE TEMP TABLE restaurants_before ON COMMIT DROP AS SELECT restaurant_id FROM restaurant;
CALL insert_test_data(2);
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
DECLARE
    rs uuid[]; ps uuid[] := ARRAY[]::uuid[]; os uuid[] := ARRAY[]::uuid[];
    client uuid; address uuid; courier uuid; category uuid;
    new_name text; product_id_added uuid; order_id_added uuid; review_id_added uuid;
    i int; j int; k int; failed boolean;
BEGIN
    SELECT array_agg(r.restaurant_id ORDER BY r.restaurant_id) INTO rs FROM restaurant r
    WHERE NOT EXISTS(SELECT FROM restaurants_before b WHERE b.restaurant_id = r.restaurant_id);
    DELETE FROM review r USING "order" o WHERE r.order_id = o.order_id AND o.restaurant_id = ANY(rs);
    SELECT o.client_id,o.address_id,o.courier_id INTO client,address,courier
    FROM "order" o WHERE o.restaurant_id = ANY(rs) LIMIT 1;
    SELECT product_category_id INTO category FROM product WHERE restaurant_id = rs[1] LIMIT 1;

    -- Четыре блюда: по два на ресторан. Четвёртое служит нетронутым агрегатом.
    FOR i IN 1..4 LOOP
        new_name := exts.uuid_generate_v4()::text;
        CALL add_product(rs[1+(i-1)/2],category,new_name,1000,4.5,'доступно','Описание');
        SELECT p.product_id INTO STRICT product_id_added FROM product p
        WHERE p.restaurant_id = rs[1+(i-1)/2] AND p.product_name = new_name;
        ps := array_append(ps,product_id_added);
    END LOOP;
    FOR i IN 1..6 LOOP
        k := 1+(i-1)/3;
        order_id_added := exts.uuid_generate_v4();
        os := array_append(os,order_id_added);
        INSERT INTO "order"(order_id,courier_id,client_id,address_id,restaurant_id)
        VALUES(order_id_added,courier,client,address,rs[k]);
        INSERT INTO order_structure(order_id,product_id,quantity,unit_price)
        VALUES(order_id_added,ps[1+(k-1)*2],1,1000),(order_id_added,ps[2+(k-1)*2],1,1000);
        INSERT INTO payment(order_id,type,transaction_id,status)
        VALUES(order_id_added,'карта',exts.uuid_generate_v4()::text,'успех');
    END LOOP;
    SET CONSTRAINTS ALL IMMEDIATE;

    -- Один многострочный INSERT; три разных заказа дают три допустимых отзыва.
    INSERT INTO review(entity_type,entity_id,order_id,description,rating)
    SELECT 'блюдо',ps[1],os[g.i],'Отзыв',g.i+2 FROM generate_series(1,3) g(i);
    PERFORM pg_temp.expect_rating('блюдо',ps[1],4);
    DELETE FROM review WHERE entity_type='блюдо' AND entity_id=ps[1] AND rating=3;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],4.5);
    DELETE FROM review WHERE entity_type='блюдо' AND entity_id=ps[1];
    PERFORM pg_temp.expect_rating('блюдо',ps[1],NULL);

    INSERT INTO review(entity_type,entity_id,order_id,description,rating)
    SELECT 'ресторан',rs[1],os[g.i],'Отзыв',g.i+2 FROM generate_series(1,3) g(i);
    PERFORM pg_temp.expect_rating('ресторан',rs[1],4);
    DELETE FROM review WHERE entity_type='ресторан' AND entity_id=rs[1] AND rating=3;
    PERFORM pg_temp.expect_rating('ресторан',rs[1],4.5);
    DELETE FROM review WHERE entity_type='ресторан' AND entity_id=rs[1];
    PERFORM pg_temp.expect_rating('ресторан',rs[1],NULL);
    RAISE NOTICE 'OK: 3/4/5 -> 4 -> 4.5 -> NULL для блюда и ресторана';

    INSERT INTO review(entity_type,entity_id,order_id,description,rating)
    VALUES('блюдо',ps[1],os[1],'Отзыв',3) RETURNING review_id INTO review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],3);
    UPDATE review SET rating=4.2 WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],4.2);
    -- Даже изменения текста/фото должны запускать пересчёт.
    UPDATE product SET rating=1 WHERE product_id=ps[1];
    UPDATE review SET description='Другой текст' WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],4.2);
    UPDATE product SET rating=1 WHERE product_id=ps[1];
    UPDATE review SET photo_url='https://example.com/photo.jpg' WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],4.2);

    UPDATE review SET entity_id=ps[2] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[1],NULL);
    PERFORM pg_temp.expect_rating('блюдо',ps[2],4.2);
    UPDATE review SET entity_type='ресторан',entity_id=rs[1] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[2],NULL);
    PERFORM pg_temp.expect_rating('ресторан',rs[1],4.2);
    UPDATE review SET entity_type='заказ',entity_id=os[1] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('ресторан',rs[1],NULL);
    PERFORM pg_temp.expect_rating('блюдо',ps[2],NULL);
    UPDATE review SET rating=5 WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[4],4.5);
    UPDATE review SET entity_type='ресторан',entity_id=rs[1] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('ресторан',rs[1],5);
    UPDATE review SET entity_id=rs[2],order_id=os[4] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('ресторан',rs[1],NULL);
    PERFORM pg_temp.expect_rating('ресторан',rs[2],5);
    UPDATE review SET entity_type='блюдо',entity_id=ps[3] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('ресторан',rs[2],NULL);
    PERFORM pg_temp.expect_rating('блюдо',ps[3],5);
    UPDATE review SET entity_id=ps[1],order_id=os[1] WHERE review_id=review_id_added;
    PERFORM pg_temp.expect_rating('блюдо',ps[3],NULL);
    PERFORM pg_temp.expect_rating('блюдо',ps[1],5);
    RAISE NOTICE 'OK: UPDATE оценки, текста, фото, переносы сущностей и типов';

    -- Проверяем атомарность при отложенной ошибке принадлежности отзыва заказу.
    failed := false;
    BEGIN
        SET CONSTRAINTS ALL DEFERRED;
        UPDATE review SET entity_id=ps[3] WHERE review_id=review_id_added;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN check_violation THEN failed := true;
    END;
    PERFORM pg_temp.assert(failed,'невалидный перенос должен быть отклонён');
    PERFORM pg_temp.expect_rating('блюдо',ps[1],5);
    PERFORM pg_temp.expect_rating('блюдо',ps[3],NULL);
    PERFORM pg_temp.assert((SELECT entity_id=ps[1] FROM review WHERE review_id=review_id_added), 'отзыв откатился');
    failed := false;
    BEGIN
        UPDATE review SET rating=2 WHERE review_id=review_id_added;
        PERFORM pg_temp.expect_rating('блюдо',ps[1],2);
        RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='откат под-транзакции';
    EXCEPTION WHEN no_data_found THEN failed := true;
    END;
    PERFORM pg_temp.assert(failed,'контрольный откат');
    PERFORM pg_temp.expect_rating('блюдо',ps[1],5);
    DELETE FROM review WHERE review_id=review_id_added;

    -- Дробное среднее и многострочные UPDATE/DELETE для обеих разновидностей.
    FOR j IN 1..2 LOOP
        INSERT INTO review(entity_type,entity_id,order_id,description,rating)
        SELECT CASE WHEN j=1 THEN 'блюдо' ELSE 'ресторан' END::khrestianovskii_food.review_entity_type,
            CASE WHEN j=1 THEN ps[1] ELSE rs[1] END,os[g.i],'Отзыв',
            CASE WHEN g.i=3 THEN 5 ELSE 4 END FROM generate_series(1,3) g(i);
        IF j=1 THEN PERFORM pg_temp.expect_rating('блюдо',ps[1],4.33);
        ELSE PERFORM pg_temp.expect_rating('ресторан',rs[1],4.33); END IF;
    END LOOP;
    UPDATE review SET rating=3 WHERE order_id=ANY(os);
    PERFORM pg_temp.expect_rating('блюдо',ps[1],3);
    PERFORM pg_temp.expect_rating('ресторан',rs[1],3);
    DELETE FROM review WHERE order_id=ANY(os);
    PERFORM pg_temp.expect_rating('блюдо',ps[1],NULL);
    PERFORM pg_temp.expect_rating('ресторан',rs[1],NULL);
    PERFORM pg_temp.expect_rating('блюдо',ps[4],4.5);
    PERFORM pg_temp.expect_rating('ресторан',rs[2],NULL);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'OK: дробные средние, многострочные операции, откаты и незатронутые рейтинги';
END;
$$;

SELECT pg_temp.assert((SELECT NOT prosecdef AND prorettype='trigger'::regtype
    AND proconfig @> ARRAY['search_path=pg_catalog, khrestianovskii_food']
    FROM pg_proc WHERE oid='khrestianovskii_food.rating_change()'::regprocedure), 'контракт функции и права');
ROLLBACK;
\echo 'OK: FOOD-105; все тестовые изменения отменены'

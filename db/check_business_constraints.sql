-- psql -v ON_ERROR_STOP=1 -f db/check_business_constraints.sql
-- Запускать на тестовой БД после db/schema/01_types.sql, 02_tables.sql,
-- 03_business_constraints.sql и grants.sql. Все данные откатываются.
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;

CREATE FUNCTION pg_temp.expect_failure(p_sql text, p_code text DEFAULT '23514')
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = p_code THEN
            RAISE NOTICE 'OK: %', p_sql;
            RETURN;
        END IF;
        RAISE;
    END;
    RAISE EXCEPTION 'Ожидалась ошибка %, но запрос принят: %', p_code, p_sql;
END;
$$;

DO $$
DECLARE
    c uuid := exts.uuid_generate_v4();
    a uuid := exts.uuid_generate_v4();
    l uuid := exts.uuid_generate_v4();
    r uuid := exts.uuid_generate_v4();
    r2 uuid := exts.uuid_generate_v4();
    cat uuid := exts.uuid_generate_v4();
    courier uuid := exts.uuid_generate_v4();
    p uuid := exts.uuid_generate_v4();
    p2 uuid := exts.uuid_generate_v4();
    other_product uuid := exts.uuid_generate_v4();
    o uuid := exts.uuid_generate_v4();
    o2 uuid := exts.uuid_generate_v4();
    review uuid := exts.uuid_generate_v4();
BEGIN
    INSERT INTO client VALUES (c, c::text, md5(c::text), 'test-phone');
    INSERT INTO address(address_id, street, house_number) VALUES (a, a::text, '1');
    INSERT INTO client_address VALUES (c, a);
    INSERT INTO legal_entity VALUES (l, '1234567890', '1234567890123');
    INSERT INTO restaurant(restaurant_id, restaurant_name, address_id, description,
                           work_start, work_end, legal_entity_id, settlement_account)
    VALUES (r, 'Ресторан 1', a, 'Тест', '09:00', '22:00', l, '12345678901234567890');
    INSERT INTO address(address_id, street, house_number)
    VALUES (r2, r2::text, '1');
    INSERT INTO restaurant(restaurant_id, restaurant_name, address_id, description,
                           work_start, work_end, legal_entity_id, settlement_account)
    VALUES (r2, 'Ресторан 2', r2, 'Тест', '09:00', '22:00', l, '12345678901234567890');
    INSERT INTO courier(courier_id, last_name, first_name, patronymic, phone_number, hire_date)
    VALUES (courier, 'Тест', 'Тест', 'Тест', 'test-phone', current_date);
    INSERT INTO product_category VALUES (cat, 'Тест');
    INSERT INTO product(product_id, product_name, product_category_id, price, restaurant_id, description)
    VALUES (p, 'Блюдо', cat, 1000, r, 'Тест'),
           (p2, 'Блюдо 2', cat, 1000, r, 'Тест'),
           (other_product, 'Чужое блюдо', cat, 1000, r2, 'Тест');
    INSERT INTO "order"(order_id, courier_id, client_id, address_id, restaurant_id)
    VALUES (o, courier, c, a, r), (o2, courier, c, a, r);
    INSERT INTO order_structure VALUES (o, p, 1, 1000), (o2, p2, 1, 1000);
    INSERT INTO payment(order_id, type, transaction_id, status)
    VALUES (o, 'карта', o::text, 'успех'), (o2, 'карта', o2::text, 'успех');
    INSERT INTO review(review_id, order_id, entity_type, entity_id, description, rating)
    VALUES (review, o, 'блюдо', p, 'Тест', 5);
    INSERT INTO review(order_id, entity_type, entity_id, description, rating)
    VALUES (o, 'ресторан', r, 'Тест', 5), (o, 'заказ', o, 'Тест', 5);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: заказ с позициями, оплатой и тремя типами отзывов';

    PERFORM pg_temp.expect_failure(format(
        'INSERT INTO "order"(courier_id,client_id,address_id,restaurant_id) VALUES (%L,%L,%L,%L)',
        courier, c, a, r));
    PERFORM pg_temp.expect_failure(format('DELETE FROM order_structure WHERE order_id=%L', o));
    PERFORM pg_temp.expect_failure(format('UPDATE order_structure SET unit_price=900 WHERE order_id=%L', o));
    PERFORM pg_temp.expect_failure(format('UPDATE order_structure SET quantity=0.5 WHERE order_id=%L', o));
    PERFORM pg_temp.expect_failure(format('UPDATE order_structure SET order_id=%L WHERE order_id=%L', o2, o));
    PERFORM pg_temp.expect_failure(format('UPDATE order_structure SET product_id=%L WHERE order_id=%L', other_product, o));
    PERFORM pg_temp.expect_failure(format('UPDATE "order" SET restaurant_id=%L WHERE order_id=%L', r2, o));
    PERFORM pg_temp.expect_failure(format('UPDATE product SET restaurant_id=%L WHERE product_id=%L', r2, p));
    PERFORM pg_temp.expect_failure(format('DELETE FROM payment WHERE order_id=%L', o));
    PERFORM pg_temp.expect_failure(format('UPDATE payment SET status=''ошибка'' WHERE order_id=%L', o));
    PERFORM pg_temp.expect_failure(format('UPDATE payment SET order_id=%L WHERE order_id=%L', o2, o), '23505');
    PERFORM pg_temp.expect_failure(format(
        'INSERT INTO payment(order_id,type,transaction_id,status) VALUES (%L,''карта'',%L,''успех'')',
        o, exts.uuid_generate_v4()::text), '23505');
    PERFORM pg_temp.expect_failure(format(
        'INSERT INTO review(order_id,entity_type,entity_id,description,rating) VALUES (%L,''блюдо'',%L,''Тест'',5)',
        o, exts.uuid_generate_v4()));
    PERFORM pg_temp.expect_failure(format(
        'INSERT INTO review(order_id,entity_type,entity_id,description,rating) VALUES (%L,''блюдо'',%L,''Тест'',5)',
        o, p2));
    PERFORM pg_temp.expect_failure(format('UPDATE review SET entity_type=''ресторан'' WHERE review_id=%L', review));
    PERFORM pg_temp.expect_failure(format('UPDATE review SET entity_id=%L WHERE review_id=%L', r2, review));
    PERFORM pg_temp.expect_failure(format('UPDATE review SET order_id=%L WHERE review_id=%L', o2, review));

    -- Проверяем защиту от удаления оценённого блюда при непустом заказе.
    INSERT INTO order_structure VALUES (o, p2, 1, 1000);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    PERFORM pg_temp.expect_failure(format('DELETE FROM order_structure WHERE order_id=%L AND product_id=%L', o, p));

    -- Временное отсутствие успешной оплаты внутри транзакции разрешено.
    DELETE FROM payment WHERE order_id = o;
    INSERT INTO payment(order_id, type, transaction_id, status)
    VALUES (o, 'наличные', exts.uuid_generate_v4()::text, 'успех');
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: замена успешной оплаты в одной транзакции';

    -- Ровно 1000 после округления: 909.09 + 90.91.
    DELETE FROM review WHERE order_id = o;
    DELETE FROM order_structure WHERE order_id = o AND product_id = p2;
    UPDATE order_structure SET unit_price = 909.09 WHERE order_id = o;
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'OK: граничная сумма 1000';

    DELETE FROM payment WHERE order_id = o;
    DELETE FROM order_structure WHERE order_id = o;
    DELETE FROM "order" WHERE order_id = o;
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'OK: удаление заказа вместе с зависимыми записями';
END;
$$;
ROLLBACK;

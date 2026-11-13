-- FOOD-104. После schema/*.sql и grants.sql:
-- psql -v ON_ERROR_STOP=1 -f db/check_add_product.sql
-- Под inspector; все данные и временные функции откатываются.
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

CALL insert_test_data(1);
SET CONSTRAINTS ALL IMMEDIATE;
CREATE TEMP TABLE products_before ON COMMIT DROP AS SELECT * FROM product;

DO $$
DECLARE
    r uuid; c uuid; n bigint; s khrestianovskii_food.product_status; added product%ROWTYPE;
    ids uuid[];
BEGIN
    SELECT restaurant_id INTO r FROM restaurant LIMIT 1;
    SELECT product_category_id INTO c FROM product_category LIMIT 1;
    SELECT array_agg(product_id), count(*) INTO ids,n FROM product;
    CALL add_product(p_restaurant_id => r, p_product_category_id => c,
        p_name => 'Блюдо', p_price => 250, p_rating => 4.5, p_status => 'доступно',
        p_description => 'Описание', p_photo_url => 'https://example.com/photo.jpg');
    PERFORM pg_temp.assert((SELECT count(*) = n+1 FROM product), 'ровно одна новая строка');
    SELECT * INTO STRICT added FROM product WHERE NOT (product_id = ANY(ids));
    PERFORM pg_temp.assert(added.product_name = 'Блюдо' AND added.price = 250
        AND added.restaurant_id = r AND added.product_category_id = c
        AND added.rating = 4.5 AND added.status = 'доступно' AND added.description = 'Описание'
        AND added.photo_url = 'https://example.com/photo.jpg', 'переданные атрибуты сохранены');
    PERFORM pg_temp.assert(added.product_id::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', 'UUID v4 из DEFAULT');
    PERFORM pg_temp.assert(NOT EXISTS(SELECT FROM review WHERE entity_type = 'блюдо'
        AND entity_id = added.product_id), 'начальный рейтинг без отзыва разрешён');

    SELECT array_agg(product_id) INTO ids FROM product;
    CALL add_product(r,c,'Я',0,NULL,'доступно','Описание');
    SELECT * INTO STRICT added FROM product WHERE NOT (product_id = ANY(ids));
    PERFORM pg_temp.assert(added.product_name = 'Я' AND added.price = 0
        AND added.photo_url IS NULL AND added.rating IS NULL, 'имя 1, цена 0, фото по умолчанию, рейтинг NULL');

    SELECT array_agg(product_id) INTO ids FROM product;
    CALL add_product(r,c,repeat('Я',100),99999.994,0,'доступно','Описание',NULL);
    SELECT * INTO STRICT added FROM product WHERE NOT (product_id = ANY(ids));
    PERFORM pg_temp.assert(char_length(added.product_name) = 100 AND added.product_name = repeat('Я',100)
        AND added.price = 99999.99 AND added.rating = 0 AND added.photo_url IS NULL,
        'имя 100 символов без обрезки, максимальная цена, рейтинг 0, явный NULL фото');

    FOREACH s IN ARRAY enum_range(NULL::khrestianovskii_food.product_status) LOOP
        SELECT array_agg(product_id) INTO ids FROM product;
        CALL add_product(r,c,'Статус',1.234,5,s,'Описание');
        SELECT * INTO STRICT added FROM product WHERE NOT (product_id = ANY(ids));
        PERFORM pg_temp.assert(added.status = s AND added.price = 1.23 AND added.rating = 5,
            'enum, округление цены, рейтинг 5');
    END LOOP;
    SELECT array_agg(product_id) INTO ids FROM product;
    CALL add_product(r,c,'Округление',1.235,4.555,'доступно','Описание');
    SELECT * INTO STRICT added FROM product WHERE NOT (product_id = ANY(ids));
    PERFORM pg_temp.assert(added.price = 1.24 AND added.rating = 4.56, 'точность numeric таблицы');
    RAISE NOTICE 'OK: атрибуты, UUID, NULL, границы и все enum';
END;
$$;

DO $$
DECLARE
    base jsonb; args jsonb; t record; before_rows jsonb; after_rows jsonb;
    got_code text; got_message text; missing_r uuid := exts.uuid_generate_v4();
    missing_c uuid := exts.uuid_generate_v4();
BEGIN
    SELECT jsonb_build_object('r', (SELECT restaurant_id FROM restaurant LIMIT 1),
        'c', (SELECT product_category_id FROM product_category LIMIT 1),
        'name','Блюдо','price',250,'rating',4.5,'status','доступно',
        'description','Описание','photo','https://example.com/photo.jpg') INTO base;
    PERFORM pg_temp.assert(NOT EXISTS(SELECT FROM restaurant WHERE restaurant_id = missing_r)
        AND NOT EXISTS(SELECT FROM product_category WHERE product_category_id = missing_c), 'несуществующие ID');
    FOR t IN SELECT * FROM (VALUES
        ('ресторан отсутствует', jsonb_build_object('r',missing_r), '23503', 'restaurant_id'),
        ('категория отсутствует', jsonb_build_object('c',missing_c), '23503', 'product_category_id'),
        ('ресторан NULL','{"r":null}'::jsonb,'23502','restaurant_id'),
        ('категория NULL','{"c":null}'::jsonb,'23502','product_category_id'),
        ('название NULL','{"name":null}'::jsonb,'23502','product_name'),
        ('цена NULL','{"price":null}'::jsonb,'23502','price'),
        ('статус NULL','{"status":null}'::jsonb,'23502','status'),
        ('описание NULL','{"description":null}'::jsonb,'23502','description'),
        ('название пустое','{"name":""}'::jsonb,'23514','Название'),
        ('описание пустое','{"description":""}'::jsonb,'23514','Описание'),
        ('101 символ',jsonb_build_object('name',repeat('Я',101)),'22001','100'),
        ('отрицательная цена','{"price":-1}'::jsonb,'23514','Цена'),
        ('цена до округления','{"price":-0.001}'::jsonb,'23514','Цена'),
        ('рейтинг ниже 0','{"rating":-0.001}'::jsonb,'23514','Рейтинг'),
        ('рейтинг выше 5','{"rating":5.001}'::jsonb,'23514','Рейтинг'),
        ('цена NaN','{"price":"NaN"}'::jsonb,'23514','Цена'),
        ('цена Infinity','{"price":"Infinity"}'::jsonb,'23514','Цена'),
        ('цена -Infinity','{"price":"-Infinity"}'::jsonb,'23514','Цена'),
        ('рейтинг NaN','{"rating":"NaN"}'::jsonb,'23514','Рейтинг'),
        ('рейтинг Infinity','{"rating":"Infinity"}'::jsonb,'23514','Рейтинг'),
        ('рейтинг -Infinity','{"rating":"-Infinity"}'::jsonb,'23514','Рейтинг'),
        ('переполнение','{"price":100000}'::jsonb,'22003','numeric(7,2)'),
        ('переполнение при округлении','{"price":99999.995}'::jsonb,'22003','numeric(7,2)'),
        ('неизвестный enum','{"status":"несуществующий"}'::jsonb,'22P02','несуществующий')
    ) AS cases(label,patch,code,message_part)
    LOOP
        args := base || t.patch;
        SELECT jsonb_agg(to_jsonb(p) ORDER BY product_id) INTO before_rows FROM product p;
        got_code := NULL;
        BEGIN
            EXECUTE format('CALL khrestianovskii_food.add_product(%L::uuid,%L::uuid,%L,%L::numeric,%L::numeric,
                %L::khrestianovskii_food.product_status,%L,%L)', args->>'r',args->>'c',args->>'name',
                args->>'price',args->>'rating',args->>'status',args->>'description',args->>'photo');
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS got_code = RETURNED_SQLSTATE, got_message = MESSAGE_TEXT;
        END;
        PERFORM pg_temp.assert(got_code IS NOT DISTINCT FROM t.code,
            format('%s: SQLSTATE %s вместо %s',t.label,got_code,t.code));
        PERFORM pg_temp.assert(position(t.message_part IN got_message) > 0, 'понятное сообщение: ' || t.label);
        IF t.label = 'ресторан отсутствует' THEN
            PERFORM pg_temp.assert(position(missing_r::text IN got_message) > 0, 'ID ресторана в ошибке');
        ELSIF t.label = 'категория отсутствует' THEN
            PERFORM pg_temp.assert(position(missing_c::text IN got_message) > 0, 'ID категории в ошибке');
        END IF;
        SELECT jsonb_agg(to_jsonb(p) ORDER BY product_id) INTO after_rows FROM product p;
        PERFORM pg_temp.assert(before_rows IS NOT DISTINCT FROM after_rows, 'атомарность: ' || t.label);
        RAISE NOTICE 'OK: % [%]',t.label,got_code;
    END LOOP;
END;
$$;

SELECT pg_temp.assert(NOT EXISTS(SELECT to_jsonb(p) FROM products_before p
    EXCEPT SELECT to_jsonb(p) FROM product p), 'старые блюда не изменены');
SELECT pg_temp.assert((SELECT NOT prosecdef AND proconfig @> ARRAY['search_path=pg_catalog, khrestianovskii_food']
    FROM pg_proc WHERE oid = 'khrestianovskii_food.add_product(uuid,uuid,text,numeric,numeric,khrestianovskii_food.product_status,text,text)'::regprocedure),
    'SECURITY INVOKER и фиксированный search_path');
ROLLBACK;
\echo 'OK: FOOD-104; все тестовые изменения отменены'

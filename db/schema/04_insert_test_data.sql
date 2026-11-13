-- FOOD-102. После 03_business_constraints.sql, перед grants.sql.
CREATE OR REPLACE PROCEDURE khrestianovskii_food.insert_test_data(value int)
LANGUAGE plpgsql
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_alphabet constant text := 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя';
    v_now timestamp := localtimestamp;
    v_month date := (date_trunc('month', localtimestamp) - interval '5 months')::date;
    v_start timestamp := greatest(v_month::timestamp,
        localtimestamp - interval '180 days', localtimestamp - interval '6 months');
    v_clients uuid[];
    v_addresses uuid[];
    v_couriers uuid[];
    v_restaurants uuid[];
    v_categories uuid[];
    v_products uuid[];
    v_orders uuid[];
    v_prices numeric[];
    v_dismissals date[];
    v_coefficients numeric[];
    v_restaurant_statuses khrestianovskii_food.restaurant_status[] := enum_range(NULL::khrestianovskii_food.restaurant_status);
    v_product_statuses khrestianovskii_food.product_status[] := enum_range(NULL::khrestianovskii_food.product_status);
    v_courier_statuses khrestianovskii_food.courier_status[] := enum_range(NULL::khrestianovskii_food.courier_status);
    v_order_statuses khrestianovskii_food.order_status[] := enum_range(NULL::khrestianovskii_food.order_status);
    v_payment_types khrestianovskii_food.payment_type[] := enum_range(NULL::khrestianovskii_food.payment_type);
    v_payment_statuses khrestianovskii_food.payment_status[] := enum_range(NULL::khrestianovskii_food.payment_status);
    v_review_types khrestianovskii_food.review_entity_type[] := enum_range(NULL::khrestianovskii_food.review_entity_type);
    v_courier_status khrestianovskii_food.courier_status;
    v_order_status khrestianovskii_food.order_status;
    v_review_type khrestianovskii_food.review_entity_type;
    v_seed text;
    v_digits text;
    v_legal_id uuid;
    v_first_product uuid;
    v_entity_id uuid;
    v_i int;
    v_j int;
    v_client int;
    v_restaurant int;
    v_courier int;
    v_product int;
    v_offset int;
    v_positions int;
    v_order_time timestamp;
    v_delivery_time timestamp;
    v_deadline timestamp;
    v_review_time timestamp;
    v_open time;
    v_pay record;
BEGIN
    IF value IS NULL OR value <= 0 OR value > 2147483647 / 5 THEN
        RAISE EXCEPTION 'value должен быть целым от 1 до %', 2147483647 / 5
            USING ERRCODE = '22023';
    END IF;

    -- Массивы содержат только сгенерированные ID, не готовые слова.
    SELECT array_agg(exts.uuid_generate_v4()), array_agg(exts.uuid_generate_v4()),
           array_agg(exts.uuid_generate_v4()), array_agg(exts.uuid_generate_v4())
    INTO v_clients, v_couriers, v_restaurants, v_categories
    FROM generate_series(1, value);
    SELECT array_agg(exts.uuid_generate_v4()), array_agg(exts.uuid_generate_v4()),
           array_agg(exts.uuid_generate_v4())
    INTO v_addresses, v_products, v_orders FROM generate_series(1, value * 5);
    v_prices := array_fill(0::numeric, ARRAY[value * 5]);
    v_dismissals := array_fill(NULL::date, ARRAY[value]);
    v_coefficients := array_fill(0.1::numeric, ARRAY[value]);

    FOR v_i IN 1..value * 5 LOOP
        LOOP
            -- Случайная основа, затем repeat + substring (паттерн 2a).
            SELECT string_agg(substring(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
            INTO v_seed FROM generate_series(1, 33);
            INSERT INTO khrestianovskii_food.address(address_id, street, house_number, apartment_office)
            VALUES (v_addresses[v_i],
                substring(repeat(v_seed, 5), 1, 1 + floor(random() * 150)::int),
                substring(v_seed, 1, 1 + floor(random() * 20)::int),
                CASE WHEN random() < 0.25 THEN NULL
                     ELSE substring(v_seed, 1, 1 + floor(random() * 20)::int) END)
            ON CONFLICT (street, house_number, apartment_office) DO NOTHING;
            EXIT WHEN FOUND;
        END LOOP;
    END LOOP;

    FOR v_i IN 1..value LOOP
        LOOP
            SELECT string_agg(substring(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
            INTO v_seed FROM generate_series(1, 33);
            SELECT string_agg(substring('0123456789', 1 + floor(random() * 10)::int, 1), '')
            INTO v_digits FROM generate_series(1, 11);
            INSERT INTO khrestianovskii_food.client(client_id, login, password, phone_number)
            VALUES (v_clients[v_i],
                substring(repeat(v_seed, 2), 1, 1 + floor(random() * 50)::int),
                md5(random()::text), substring(v_digits, 1, 1 + floor(random() * 11)::int))
            ON CONFLICT DO NOTHING;
            EXIT WHEN FOUND;
        END LOOP;

        INSERT INTO khrestianovskii_food.product_category(product_category_id, product_category_name)
        VALUES (v_categories[v_i], substring(repeat(v_seed, 3), 1, 1 + floor(random() * 80)::int));

        v_courier_status := v_courier_statuses[1 + floor(random() * cardinality(v_courier_statuses))::int];
        IF v_i = 1 THEN
            -- Активный курьер обязателен даже при value = 1.
            v_courier_status := (array_remove(v_courier_statuses, 'уволен'::khrestianovskii_food.courier_status))[
                1 + floor(random() * (cardinality(v_courier_statuses) - 1))::int];
        END IF;
        IF v_courier_status = 'уволен' THEN
            v_dismissals[v_i] := current_date - floor(random() * extract(day FROM current_date))::int;
        END IF;
        INSERT INTO khrestianovskii_food.courier(courier_id, last_name, first_name, patronymic,
            phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES (v_couriers[v_i],
            substring(repeat(v_seed, 2), 1, 1 + floor(random() * 50)::int),
            substring(repeat(v_seed, 2), 1, 1 + floor(random() * 50)::int),
            substring(repeat(v_seed, 2), 1, 1 + floor(random() * 50)::int),
            substring(v_digits, 1, 1 + floor(random() * 11)::int),
            v_courier_status, v_start::date, v_dismissals[v_i], 0.1);

        v_legal_id := exts.uuid_generate_v4();
        LOOP
            SELECT string_agg(substring('0123456789', 1 + floor(random() * 10)::int, 1), '')
            INTO v_digits FROM generate_series(1, 20);
            INSERT INTO khrestianovskii_food.legal_entity(legal_entity_id, inn, ogrn)
            VALUES (v_legal_id,
                substring(v_digits, 1, 10 + 2 * floor(random() * 2)::int),
                substring(v_digits, 1, 13 + 2 * floor(random() * 2)::int))
            ON CONFLICT DO NOTHING;
            EXIT WHEN FOUND;
        END LOOP;
        v_open := time '00:00' + random() * interval '12 hours';
        INSERT INTO khrestianovskii_food.restaurant(restaurant_id, restaurant_name, address_id,
            description, work_start, work_end, legal_entity_id, settlement_account, status)
        VALUES (v_restaurants[v_i],
            substring(repeat(v_seed, 4), 1, 1 + floor(random() * 100)::int), v_addresses[v_i],
            substring(repeat(v_seed, 5), 1, 1 + floor(random() * 150)::int),
            v_open, v_open + interval '1 hour' + random() * interval '10 hours',
            v_legal_id, v_digits,
            v_restaurant_statuses[1 + floor(random() * cardinality(v_restaurant_statuses))::int]);
    END LOOP;

    INSERT INTO khrestianovskii_food.client_address(client_id, address_id)
    SELECT v_clients[1 + (i - 1) / 4], v_addresses[value + i]
    FROM generate_series(1, value * 4) g(i);

    FOR v_i IN 1..value * 5 LOOP
        SELECT string_agg(substring(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
        INTO v_seed FROM generate_series(1, 33);
        v_prices[v_i] := round((1000 + random() * 4000)::numeric, 2);
        INSERT INTO khrestianovskii_food.product(product_id, product_name, product_category_id,
            price, restaurant_id, photo_url, status, description)
        VALUES (v_products[v_i],
            substring(repeat(v_seed, 4), 1, 1 + floor(random() * 100)::int),
            v_categories[1 + floor(random() * value)::int], v_prices[v_i],
            v_restaurants[1 + (v_i - 1) / 5],
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
            v_product_statuses[1 + floor(random() * cardinality(v_product_statuses))::int],
            substring(repeat(v_seed, 5), 1, 1 + floor(random() * 150)::int));
    END LOOP;

    FOR v_i IN 1..value * 5 LOOP
        SELECT string_agg(substring(v_alphabet, 1 + floor(random() * 33)::int, 1), '')
        INTO v_seed FROM generate_series(1, 33);
        v_client := 1 + floor(random() * value)::int;
        v_restaurant := 1 + floor(random() * value)::int;
        v_courier := 1 + floor(random() * value)::int;
        v_deadline := least(v_now, coalesce(v_dismissals[v_courier]::timestamp
            + interval '1 day' - interval '1 microsecond', v_now));
        v_order_time := v_start + random() * (v_deadline - v_start);
        v_order_status := v_order_statuses[1 + floor(random() * cardinality(v_order_statuses))::int];
        IF v_i = 1 THEN
            v_courier := 1;
            v_deadline := v_now;
            v_order_time := date_trunc('month', v_now)
                + random() * (v_now - date_trunc('month', v_now));
            v_order_status := v_order_statuses[array_position(v_order_statuses, 'доставлен')];
        END IF;
        v_delivery_time := CASE WHEN v_order_status = 'доставлен' THEN
            v_order_time + random() * least(interval '2 hours', v_deadline - v_order_time) END;
        INSERT INTO khrestianovskii_food."order"(order_id, courier_id, client_id, address_id,
            restaurant_id, order_timestamp, delivery_timestamp, status, description)
        VALUES (v_orders[v_i], v_couriers[v_courier], v_clients[v_client],
            v_addresses[value + (v_client - 1) * 4 + 1 + floor(random() * 4)::int],
            v_restaurants[v_restaurant], v_order_time, v_delivery_time, v_order_status,
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE substring(repeat(v_seed, 5), 1, 1 + floor(random() * 150)::int) END);

        -- Циклический срез даёт разные блюда одного ресторана без сканов.
        v_offset := floor(random() * 5)::int;
        v_positions := 1 + floor(random() * 5)::int;
        FOR v_j IN 0..v_positions - 1 LOOP
            v_product := (v_restaurant - 1) * 5 + 1 + (v_offset + v_j) % 5;
            INSERT INTO khrestianovskii_food.order_structure(order_id, product_id, quantity, unit_price)
            VALUES (v_orders[v_i], v_products[v_product],
                CASE WHEN v_j = 0 THEN 1 ELSE (1 + floor(random() * 6)) / 2.0 END,
                v_prices[v_product]);
            IF v_j = 0 THEN v_first_product := v_products[v_product]; END IF;
        END LOOP;
        LOOP
            INSERT INTO khrestianovskii_food.payment(payment_id, order_id, type,
                transaction_id, transaction_timestamp, status)
            VALUES (exts.uuid_generate_v4(), v_orders[v_i],
                v_payment_types[1 + floor(random() * cardinality(v_payment_types))::int],
                substring(repeat(md5(random()::text), 4), 1, 1 + floor(random() * 100)::int),
                v_order_time + random() * (coalesce(v_delivery_time, v_deadline) - v_order_time),
                v_payment_statuses[array_position(v_payment_statuses, 'успех')])
            ON CONFLICT (transaction_id) DO NOTHING;
            EXIT WHEN FOUND;
        END LOOP;

        v_review_type := v_review_types[1 + floor(random() * cardinality(v_review_types))::int];
        v_entity_id := CASE v_review_type WHEN 'блюдо' THEN v_first_product
            WHEN 'ресторан' THEN v_restaurants[v_restaurant] ELSE v_orders[v_i] END;
        v_review_time := coalesce(v_delivery_time, v_order_time);
        INSERT INTO khrestianovskii_food.review(review_id, review_timestamp, entity_id,
            entity_type, order_id, description, photo_url, rating)
        VALUES (exts.uuid_generate_v4(), v_review_time + random() * (v_now - v_review_time),
            v_entity_id, v_review_type, v_orders[v_i],
            substring(repeat(v_seed, 5), 1, 1 + floor(random() * 150)::int),
            CASE WHEN random() < 0.25 THEN NULL
                 ELSE 'https://cdn.foodexpress.ru/img/' || md5(random()::text) || '.jpg' END,
            1 + floor(random() * 5));
    END LOOP;

    UPDATE khrestianovskii_food.product p SET rating = r.rating
    FROM (SELECT entity_id, round(avg(rating), 2) AS rating
          FROM khrestianovskii_food.review WHERE order_id = ANY(v_orders) AND entity_type = 'блюдо'
          GROUP BY entity_id) r WHERE p.product_id = r.entity_id;
    UPDATE khrestianovskii_food.restaurant p SET rating = r.rating
    FROM (SELECT entity_id, round(avg(rating), 2) AS rating
          FROM khrestianovskii_food.review WHERE order_id = ANY(v_orders) AND entity_type = 'ресторан'
          GROUP BY entity_id) r WHERE p.restaurant_id = r.entity_id;

    -- Один агрегат по новым заказам; выплаты идут хронологически.
    FOR v_pay IN
        WITH amounts AS (
            SELECT order_id, round(sum(quantity * unit_price), 2) AS amount
            FROM khrestianovskii_food.order_structure WHERE order_id = ANY(v_orders) GROUP BY order_id
        ), delivered AS (
            SELECT o.courier_id, date_trunc('month', o.order_timestamp)::date AS month_start,
                count(*) AS cnt, sum(round(a.amount * 0.1, 2)) AS commission
            FROM khrestianovskii_food."order" o JOIN amounts a USING (order_id)
            WHERE o.status = 'доставлен' GROUP BY o.courier_id, date_trunc('month', o.order_timestamp)::date
        )
        SELECT c.i, m.month_start::date AS month_start,
            coalesce(d.cnt, 0) AS cnt, coalesce(d.commission, 0) AS commission
        FROM generate_series(1, value) c(i)
        CROSS JOIN generate_series(v_month::timestamp, date_trunc('month', v_now), interval '1 month') m(month_start)
        LEFT JOIN delivered d ON d.courier_id = v_couriers[c.i] AND d.month_start = m.month_start::date
        ORDER BY m.month_start, c.i
    LOOP
        INSERT INTO khrestianovskii_food.courier_pay(year, month, courier_id, amount, coefficient_used)
        VALUES (extract(year FROM v_pay.month_start)::smallint, extract(month FROM v_pay.month_start)::smallint,
            v_couriers[v_pay.i], round(v_coefficients[v_pay.i] * v_pay.commission, 2), v_coefficients[v_pay.i]);
        IF v_dismissals[v_pay.i] IS NULL
           OR v_dismissals[v_pay.i] >= v_pay.month_start + interval '1 month' THEN
            v_coefficients[v_pay.i] := CASE WHEN v_pay.cnt <= 150 THEN 0.1
                WHEN v_pay.cnt <= 250 THEN 0.2 WHEN v_pay.cnt <= 500 THEN 0.3 ELSE 0.5 END;
        END IF;
    END LOOP;
    UPDATE khrestianovskii_food.courier c SET coefficient = x.coefficient
    FROM unnest(v_couriers, v_coefficients) AS x(courier_id, coefficient)
    WHERE c.courier_id = x.courier_id;
END;
$$;

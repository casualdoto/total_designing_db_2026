CREATE OR REPLACE PROCEDURE khrestianovskii_food.erase_test_data()
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
BEGIN
    TRUNCATE TABLE
        khrestianovskii_food.review,
        khrestianovskii_food.payment,
        khrestianovskii_food.order_structure,
        khrestianovskii_food.courier_pay,
        khrestianovskii_food."order",
        khrestianovskii_food.client_address,
        khrestianovskii_food.product,
        khrestianovskii_food.restaurant,
        khrestianovskii_food.client,
        khrestianovskii_food.courier,
        khrestianovskii_food.product_category,
        khrestianovskii_food.address;
END;
$$;

CREATE OR REPLACE PROCEDURE khrestianovskii_food.insert_test_data(value integer)
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, exts, pg_temp
AS $$
DECLARE
    i integer;
    j integer;
    v_count integer;
    v_id uuid;
    v_client_idx integer;
    v_restaurant_idx integer;
    v_product_idx integer;
    v_month_offset integer;
    v_address_number bigint := (SELECT count(*) FROM khrestianovskii_food.address);
    v_restaurant_number bigint := (SELECT count(*) FROM khrestianovskii_food.restaurant);
    v_streets text[] := ARRAY['Лесная', 'Садовая', 'Центральная', 'Парковая', 'Полевая', 'Набережная'];
    v_restaurant_names text[] := ARRAY['Тёплая кухня', 'Соседи', 'Обед рядом', 'Ложка', 'Сковорода', 'Городское кафе'];
    v_dish_names text[] := ARRAY['Борщ', 'Куриная котлета с пюре', 'Овощной салат', 'Паста с грибами', 'Сырники'];
    v_category_names text[] := ARRAY['Супы', 'Горячие блюда', 'Салаты', 'Десерты', 'Напитки'];
    v_courier_names text[] := ARRAY['Иванов Алексей Сергеевич', 'Петров Михаил Андреевич', 'Смирнова Анна Олеговна', 'Волков Дмитрий Игоревич', 'Соколова Мария Павловна', 'Орлов Максим Викторович'];
    v_month timestamp;
    v_order_timestamp timestamp;
    v_coefficient numeric(2,1);
    v_new_coefficient numeric(2,1);
    v_deliveries integer;
    v_commission numeric(14,2);
    v_phone varchar(11);
    v_next_idx integer;
    v_order_status khrestianovskii_food.order_status;
    v_clients uuid[] := ARRAY[]::uuid[];
    v_couriers uuid[] := ARRAY[]::uuid[];
    v_restaurants uuid[] := ARRAY[]::uuid[];
    v_categories uuid[] := ARRAY[]::uuid[];
    v_addresses uuid[] := ARRAY[]::uuid[];
    v_products uuid[] := ARRAY[]::uuid[];
    v_restaurant_statuses khrestianovskii_food.restaurant_status[] := enum_range(NULL::khrestianovskii_food.restaurant_status);
    v_product_statuses khrestianovskii_food.product_status[] := enum_range(NULL::khrestianovskii_food.product_status);
    v_courier_statuses khrestianovskii_food.courier_status[] := enum_range(NULL::khrestianovskii_food.courier_status);
    v_order_statuses khrestianovskii_food.order_status[] := enum_range(NULL::khrestianovskii_food.order_status);
    v_order_pay_statuses khrestianovskii_food.order_pay_status[] := enum_range(NULL::khrestianovskii_food.order_pay_status);
    v_payment_statuses khrestianovskii_food.payment_status[] := enum_range(NULL::khrestianovskii_food.payment_status);
    v_payment_types khrestianovskii_food.payment_type[] := enum_range(NULL::khrestianovskii_food.payment_type);
    v_review_types khrestianovskii_food.review_entity_type[] := enum_range(NULL::khrestianovskii_food.review_entity_type);
BEGIN
    IF value IS NULL OR value < 1 THEN
        RAISE EXCEPTION 'Для генерации требуется целое количество больше нуля';
    END IF;
    IF value > 2147483647 / 5 THEN
        RAISE EXCEPTION 'Запрошенный объём данных превышает предел: 429496729';
    END IF;

    v_count := value * 5;

    FOR i IN 1..value LOOP
        v_id := exts.uuid_generate_v4();
        LOOP
            v_phone := '7' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0');
            EXIT WHEN NOT EXISTS (SELECT 1 FROM khrestianovskii_food.client WHERE phone_number = v_phone);
        END LOOP;
        INSERT INTO khrestianovskii_food.client(client_id, login, password, phone_number)
        VALUES (
            v_id,
            'client_' || v_id::text,
            md5(random()::text),
            v_phone
        );
        v_clients := array_append(v_clients, v_id);

        v_id := exts.uuid_generate_v4();
        INSERT INTO khrestianovskii_food.courier
            (courier_id, fio, phone_number, status, hire_date, dismissal_date, coefficient)
        VALUES (
            v_id,
            v_courier_names[((i - 1) % cardinality(v_courier_names)) + 1],
            '7' || lpad(floor(random() * 10000000000)::bigint::text, 10, '0'),
            CASE WHEN value > 1 AND i = value THEN v_courier_statuses[4]
                 ELSE v_courier_statuses[1] END,
            date_trunc('month', current_date - interval '5 months')::date,
            CASE WHEN value > 1 AND i = value THEN current_date ELSE NULL END,
            0.1
        );
        v_couriers := array_append(v_couriers, v_id);

        v_id := exts.uuid_generate_v4();
        INSERT INTO khrestianovskii_food.product_category(product_category_id, product_category_name)
        VALUES (v_id, v_category_names[((i - 1) % cardinality(v_category_names)) + 1]);
        v_categories := array_append(v_categories, v_id);
    END LOOP;

    FOR i IN 1..v_count LOOP
        LOOP
            v_address_number := v_address_number + 1;
            INSERT INTO khrestianovskii_food.address(street, house_number, apartment_office)
            VALUES (
                v_streets[((i - 1) % cardinality(v_streets)) + 1],
                v_address_number::text,
                CASE WHEN i % 4 = 0 THEN NULL ELSE (1 + (i % 200))::text END
            )
            ON CONFLICT (street, house_number, apartment_office) DO NOTHING
            RETURNING address_id INTO v_id;
            EXIT WHEN FOUND;
        END LOOP;
        v_addresses := array_append(v_addresses, v_id);
    END LOOP;

    FOR i IN 1..value LOOP
        v_id := exts.uuid_generate_v4();
        INSERT INTO khrestianovskii_food.restaurant
            (restaurant_id, restaurant_name, address_id, description, work_start,
             work_end, company_details, rating, status)
        VALUES (
            v_id,
            v_restaurant_names[((i - 1) % cardinality(v_restaurant_names)) + 1] || ' №' || (v_restaurant_number + i)::text,
            v_addresses[i],
            'Описание ресторана для проверки, запись ' || i,
            time '09:00', time '22:00', 'Реквизиты учебного набора: ' || v_id::text,
            NULL, v_restaurant_statuses[1]
        );
        v_restaurants := array_append(v_restaurants, v_id);
    END LOOP;

    FOR i IN 1..(value * 4) LOOP
        v_client_idx := ((i - 1) % value) + 1;
        INSERT INTO khrestianovskii_food.client_address(client_id, address_id)
        VALUES (v_clients[v_client_idx], v_addresses[value + i]);
    END LOOP;

    FOR i IN 1..v_count LOOP
        v_restaurant_idx := ((i - 1) / 5) + 1;
        v_id := exts.uuid_generate_v4();
        INSERT INTO khrestianovskii_food.product
            (product_id, product_name, product_category_id, price, restaurant_id,
             photo_url, rating, status, description)
        VALUES (
            v_id,
            v_dish_names[((i - 1) % cardinality(v_dish_names)) + 1],
            v_categories[((i - 1) % value) + 1],
            1000 + (i % 10) * 100,
            v_restaurants[v_restaurant_idx],
            NULL,
            NULL, v_product_statuses[1], 'Описание позиции меню для проверки, запись ' || i
        );
        v_products := array_append(v_products, v_id);
    END LOOP;

    FOR i IN 1..v_count LOOP
        v_client_idx := ((i - 1) % value) + 1;
        v_restaurant_idx := (((i - 1) / 5) % value) + 1;
        v_product_idx := (v_restaurant_idx - 1) * 5 + ((i - 1) % 5) + 1;
        v_month_offset := (i - 1) % 6;
        v_month := date_trunc('month', localtimestamp) - (5 - v_month_offset) * interval '1 month';
        v_order_timestamp := v_month +
            (least(localtimestamp, v_month + interval '1 month') - v_month) * random() * 0.8;
        v_order_status := v_order_statuses[((i - 1) % 5) + 1];
        v_next_idx := (v_restaurant_idx - 1) * 5 + (i % 5) + 1;
        v_id := exts.uuid_generate_v4();
        INSERT INTO khrestianovskii_food."order"
            (order_id, courier_id, client_id, address_id, restaurant_id,
             order_timestamp, delivery_timestamp, order_amount, status, pay_status, description)
        VALUES (
            v_id,
            v_couriers[v_client_idx],
            v_clients[v_client_idx],
            v_addresses[value + v_client_idx],
            v_restaurants[v_restaurant_idx],
            v_order_timestamp, CASE WHEN v_order_status = 'доставлен' THEN v_order_timestamp + (least(localtimestamp, v_month + interval '1 month') - v_order_timestamp) * 0.5 ELSE NULL END,
            (SELECT sum(price * CASE WHEN product_id = v_products[v_product_idx] THEN 1.5 ELSE 0.5 END) FROM khrestianovskii_food.product WHERE product_id IN (v_products[v_product_idx], v_products[v_next_idx])),
            v_order_status,
            v_order_pay_statuses[array_position(v_order_pay_statuses, 'ожидает'::khrestianovskii_food.order_pay_status)],
            'Заказ из проверочного набора, запись ' || i
        );
        INSERT INTO khrestianovskii_food.order_structure(order_id, product_id, quantity, unit_price)
        SELECT v_id, p.product_id, CASE WHEN p.product_id = v_products[v_product_idx] THEN 1.5 ELSE 0.5 END, p.price
        FROM khrestianovskii_food.product p WHERE p.product_id IN (v_products[v_product_idx], v_products[v_next_idx]);

        INSERT INTO khrestianovskii_food.payment
            (payment_id, order_id, type, amount, transaction_id, transaction_timestamp, status)
        SELECT exts.uuid_generate_v4(), v_id, v_payment_types[1], o.total_amount,
               'test-' || exts.uuid_generate_v4()::text, v_order_timestamp,
               v_payment_statuses[array_position(v_payment_statuses, 'успех'::khrestianovskii_food.payment_status)]
        FROM khrestianovskii_food."order" o WHERE o.order_id = v_id;

        INSERT INTO khrestianovskii_food.review
            (review_id, client_id, review_timestamp, entity_id, entity_type,
             order_id, description, photo_url, rating)
        VALUES (
            exts.uuid_generate_v4(), v_clients[v_client_idx], v_order_timestamp + (least(localtimestamp, v_month + interval '1 month') - v_order_timestamp) * 0.75,
            CASE v_review_types[((i - 1) % 3) + 1]
                WHEN 'блюдо' THEN v_products[v_product_idx]
                WHEN 'ресторан' THEN v_restaurants[v_restaurant_idx]
                ELSE v_id
            END,
            v_review_types[((i - 1) % 3) + 1], v_id,
            'Отзыв из проверочного набора, запись ' || i,
            CASE WHEN i % 4 = 0 THEN NULL ELSE 'https://cdn.foodexpress.ru/reviews/' || v_id::text || '.jpg' END,
            (i % 5) + 1
        );
    END LOOP;

    FOR i IN 1..value LOOP
        v_coefficient := 0.1;
        FOR j IN REVERSE 5..0 LOOP
            v_month := date_trunc('month', localtimestamp) - j * interval '1 month';
            SELECT count(*)::integer, coalesce(sum(commission), 0)
            INTO v_deliveries, v_commission
            FROM khrestianovskii_food."order"
            WHERE courier_id = v_couriers[i]
              AND status = 'доставлен'
              AND date_trunc('month', delivery_timestamp) = v_month;

            INSERT INTO khrestianovskii_food.courier_pay(year, month, courier_id, amount, coefficient_used)
            VALUES (
                extract(year FROM v_month)::integer,
                extract(month FROM v_month)::integer,
                v_couriers[i], round(v_commission * v_coefficient, 2), v_coefficient
            )
            ON CONFLICT (year, month, courier_id) DO UPDATE
            SET amount = EXCLUDED.amount, coefficient_used = EXCLUDED.coefficient_used;

            v_new_coefficient := CASE
                WHEN v_deliveries <= 150 THEN 0.1
                WHEN v_deliveries <= 250 THEN 0.2
                WHEN v_deliveries <= 500 THEN 0.3
                ELSE 0.5
            END;
            v_coefficient := v_new_coefficient;
        END LOOP;
        UPDATE khrestianovskii_food.courier
        SET coefficient = v_coefficient
        WHERE courier_id = v_couriers[i] AND status <> 'уволен';
    END LOOP;
END;
$$;

-- FOOD-104. Установить после 05_erase_test_data.sql, перед grants.sql.
CREATE OR REPLACE PROCEDURE khrestianovskii_food.add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name text,
    p_price numeric,
    p_rating numeric,
    p_status khrestianovskii_food.product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_column text;
    v_constraint text;
BEGIN
    v_column := CASE
        WHEN p_restaurant_id IS NULL THEN 'restaurant_id'
        WHEN p_product_category_id IS NULL THEN 'product_category_id'
        WHEN p_name IS NULL THEN 'product_name'
        WHEN p_price IS NULL THEN 'price'
        WHEN p_status IS NULL THEN 'status'
        WHEN p_description IS NULL THEN 'description'
    END;
    IF v_column IS NOT NULL THEN
        RAISE EXCEPTION 'Поле блюда % обязательно (BR-5.1/5.2, BR-11.3)', v_column
            USING ERRCODE = '23502', COLUMN = v_column;
    END IF;
    IF char_length(p_name) = 0 THEN
        RAISE EXCEPTION 'Название блюда не должно быть пустым (BR-5.2, паттерн 2a)'
            USING ERRCODE = '23514', COLUMN = 'product_name';
    END IF;
    IF char_length(p_name) > 100 THEN
        RAISE EXCEPTION 'Название блюда должно содержать от 1 до 100 символов; получено %', char_length(p_name)
            USING ERRCODE = '22001', COLUMN = 'product_name';
    END IF;
    IF char_length(p_description) = 0 THEN
        RAISE EXCEPTION 'Описание блюда не должно быть пустым (BR-5.2, BR-11.3)'
            USING ERRCODE = '23514', COLUMN = 'description';
    END IF;
    -- Диапазоны проверяются до округления при записи в numeric(7,2)/(3,2).
    IF p_price::text IN ('NaN', 'Infinity', '-Infinity') OR p_price < 0 THEN
        RAISE EXCEPTION 'Цена блюда должна быть конечным неотрицательным числом (BR-5.3); получено %', p_price
            USING ERRCODE = '23514', COLUMN = 'price';
    END IF;
    IF round(p_price, 2) > 99999.99 THEN
        RAISE EXCEPTION 'Цена блюда % не помещается в numeric(7,2) после округления', p_price
            USING ERRCODE = '22003', COLUMN = 'price';
    END IF;
    IF p_rating IS NOT NULL AND
       (p_rating::text IN ('NaN', 'Infinity', '-Infinity') OR p_rating NOT BETWEEN 0 AND 5) THEN
        RAISE EXCEPTION 'Рейтинг блюда должен быть от 0 до 5 или NULL (BR-5.4); получено %', p_rating
            USING ERRCODE = '23514', COLUMN = 'rating';
    END IF;

    -- Начальный рейтинг принимается по уточнению FOOD-104; последующий
    -- пересчёт по отзывам относится к FOOD-105. UUID берётся из DEFAULT.
    BEGIN
        INSERT INTO khrestianovskii_food.product(product_name, product_category_id,
            price, restaurant_id, photo_url, rating, status, description)
        VALUES (p_name, p_product_category_id, p_price, p_restaurant_id,
            p_photo_url, p_rating, p_status, p_description);
    EXCEPTION WHEN foreign_key_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint = 'product_restaurant_id_fkey' THEN
            RAISE EXCEPTION 'Ресторан с restaurant_id = % не существует (BR-5.1)', p_restaurant_id
                USING ERRCODE = '23503', CONSTRAINT = v_constraint, COLUMN = 'restaurant_id';
        ELSIF v_constraint = 'product_product_category_id_fkey' THEN
            RAISE EXCEPTION 'Категория с product_category_id = % не существует (BR-5.1)', p_product_category_id
                USING ERRCODE = '23503', CONSTRAINT = v_constraint, COLUMN = 'product_category_id';
        ELSE
            RAISE;
        END IF;
    END;
END;
$$;

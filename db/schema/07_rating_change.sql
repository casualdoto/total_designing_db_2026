-- FOOD-105. После существующих скриптов схемы, перед grants.sql.
BEGIN;

CREATE INDEX IF NOT EXISTS review_entity_rating_idx
    ON khrestianovskii_food.review(entity_type, entity_id);

CREATE OR REPLACE FUNCTION khrestianovskii_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_types khrestianovskii_food.review_entity_type[] := ARRAY[]::khrestianovskii_food.review_entity_type[];
    v_ids uuid[] := ARRAY[]::uuid[];
    v_target record;
    v_rating numeric;
BEGIN
    IF TG_OP <> 'INSERT' THEN
        IF OLD.entity_type IN ('блюдо', 'ресторан') THEN
            v_types := array_append(v_types, OLD.entity_type);
            v_ids := array_append(v_ids, OLD.entity_id);
        END IF;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        IF NEW.entity_type IN ('блюдо', 'ресторан') THEN
            v_types := array_append(v_types, NEW.entity_type);
            v_ids := array_append(v_ids, NEW.entity_id);
        END IF;
    END IF;

    -- Блокируем все затронутые агрегаты до чтения отзывов. Разные заказы
    -- могут одновременно менять отзывы одной сущности; блокировки заказа
    -- из FOOD-101 сами по себе этого не сериализуют.
    FOR v_target IN
        SELECT DISTINCT entity_type, entity_id FROM unnest(v_types, v_ids) AS t(entity_type, entity_id)
        ORDER BY entity_type, entity_id
    LOOP
        IF v_target.entity_type = 'блюдо' THEN
            PERFORM 1 FROM khrestianovskii_food.product
            WHERE product_id = v_target.entity_id FOR NO KEY UPDATE;
        ELSE
            PERFORM 1 FROM khrestianovskii_food.restaurant
            WHERE restaurant_id = v_target.entity_id FOR NO KEY UPDATE;
        END IF;
    END LOOP;

    FOR v_target IN
        SELECT DISTINCT entity_type, entity_id FROM unnest(v_types, v_ids) AS t(entity_type, entity_id)
        ORDER BY entity_type, entity_id
    LOOP
        -- Отдельный запрос после ожидания блокировки получает свежий снимок
        -- при READ COMMITTED. Без отзывов AVG возвращает NULL.
        SELECT round(avg(r.rating), 2) INTO v_rating
        FROM khrestianovskii_food.review r
        WHERE r.entity_type = v_target.entity_type AND r.entity_id = v_target.entity_id;
        IF v_target.entity_type = 'блюдо' THEN
            UPDATE khrestianovskii_food.product SET rating = v_rating
            WHERE product_id = v_target.entity_id;
        ELSE
            UPDATE khrestianovskii_food.restaurant SET rating = v_rating
            WHERE restaurant_id = v_target.entity_id;
        END IF;
    END LOOP;
    RETURN NULL; -- AFTER-триггер не изменяет строку отзыва.
END;
$$;

CREATE OR REPLACE TRIGGER review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.review
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.rating_change();

COMMIT;

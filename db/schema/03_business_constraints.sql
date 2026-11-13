BEGIN;

CREATE FUNCTION khrestianovskii_food.check_order_integrity(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_restaurant_id uuid;
    v_amount numeric;
BEGIN
    SELECT restaurant_id INTO v_restaurant_id
    FROM khrestianovskii_food."order" WHERE order_id = p_order_id;
    IF NOT FOUND THEN
        RETURN; -- Заказ мог быть удалён в той же транзакции.
    END IF;

    SELECT round(sum(quantity * unit_price), 2) INTO v_amount
    FROM khrestianovskii_food.order_structure WHERE order_id = p_order_id;
    IF v_amount IS NULL THEN
        RAISE EXCEPTION 'Заказ % должен содержать хотя бы одну позицию (BR-7.14)', p_order_id
            USING ERRCODE = '23514';
    END IF;
    IF v_amount + round(v_amount * 0.10, 2) < 1000 THEN
        RAISE EXCEPTION 'Общая сумма заказа % должна быть не менее 1000 рублей (BR-7.11)', p_order_id
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM khrestianovskii_food.order_structure s
        JOIN khrestianovskii_food.product p USING (product_id)
        WHERE s.order_id = p_order_id AND p.restaurant_id <> v_restaurant_id
    ) THEN
        RAISE EXCEPTION 'Все блюда заказа % должны принадлежать ресторану заказа (BR-7.3)', p_order_id
            USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM khrestianovskii_food.payment
        WHERE order_id = p_order_id AND status = 'успех'
    ) THEN
        RAISE EXCEPTION 'Заказ % должен иметь успешную оплату (BR-8.1)', p_order_id
            USING ERRCODE = '23514';
    END IF;
    -- Не более одного успеха уже обеспечивает payment_one_success_per_order.
    IF EXISTS (
        SELECT 1 FROM khrestianovskii_food.review r
        WHERE r.order_id = p_order_id AND NOT (
            (r.entity_type = 'заказ' AND r.entity_id = p_order_id)
            OR (r.entity_type = 'ресторан' AND r.entity_id = v_restaurant_id)
            OR (r.entity_type = 'блюдо' AND EXISTS (
                SELECT 1 FROM khrestianovskii_food.order_structure s
                WHERE s.order_id = p_order_id AND s.product_id = r.entity_id
            ))
        )
    ) THEN
        RAISE EXCEPTION 'Объект отзыва должен относиться к заказу % (BR-9.1/9.2)', p_order_id
            USING ERRCODE = '23514';
    END IF;
END;
$$;

-- Запись родительской строки сериализует изменения одного заказа, включая
-- конкурентное удаление разных позиций/изменение оплаты и отзывов.
-- При REPEATABLE READ конфликт приводит к serialization_failure.
CREATE FUNCTION khrestianovskii_food.lock_order_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_ids uuid[] := ARRAY[]::uuid[];
    v_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        IF NEW.restaurant_id IS NOT DISTINCT FROM OLD.restaurant_id THEN
            RETURN NEW;
        END IF;
        SELECT array_agg(DISTINCT order_id) INTO v_ids
        FROM khrestianovskii_food.order_structure WHERE product_id = OLD.product_id;
    ELSE
        IF TG_OP <> 'INSERT' THEN
            v_ids := array_append(v_ids, OLD.order_id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            v_ids := array_append(v_ids, NEW.order_id);
        END IF;
    END IF;

    FOR v_order_id IN SELECT DISTINCT id FROM unnest(v_ids) AS ids(id) ORDER BY id LOOP
        UPDATE khrestianovskii_food."order" SET order_id = order_id
        WHERE order_id = v_order_id;
    END LOOP;

    IF TG_TABLE_NAME = 'order_structure' AND TG_OP <> 'DELETE' THEN
        -- Не даём параллельно сменить ресторан блюда до конца транзакции.
        PERFORM 1 FROM khrestianovskii_food.product
        WHERE product_id = NEW.product_id FOR SHARE;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_structure_integrity_lock
BEFORE INSERT OR UPDATE OR DELETE ON khrestianovskii_food.order_structure
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.lock_order_integrity();

CREATE TRIGGER payment_integrity_lock
BEFORE INSERT OR UPDATE OR DELETE ON khrestianovskii_food.payment
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.lock_order_integrity();

CREATE TRIGGER review_integrity_lock
BEFORE INSERT OR UPDATE OR DELETE ON khrestianovskii_food.review
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.lock_order_integrity();

CREATE TRIGGER product_integrity_lock
BEFORE UPDATE OF restaurant_id ON khrestianovskii_food.product
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.lock_order_integrity();

CREATE FUNCTION khrestianovskii_food.enforce_order_integrity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        FOR v_order_id IN
            SELECT DISTINCT order_id FROM khrestianovskii_food.order_structure
            WHERE product_id = NEW.product_id
        LOOP
            PERFORM khrestianovskii_food.check_order_integrity(v_order_id);
        END LOOP;
    ELSE
        IF TG_OP <> 'INSERT' THEN
            PERFORM khrestianovskii_food.check_order_integrity(OLD.order_id);
        END IF;
        IF TG_OP <> 'DELETE' THEN
            PERFORM khrestianovskii_food.check_order_integrity(NEW.order_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER order_integrity
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.enforce_order_integrity();

CREATE CONSTRAINT TRIGGER order_structure_integrity
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.enforce_order_integrity();

CREATE CONSTRAINT TRIGGER payment_integrity
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.enforce_order_integrity();

CREATE CONSTRAINT TRIGGER review_integrity
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.review
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.enforce_order_integrity();

CREATE CONSTRAINT TRIGGER product_order_integrity
AFTER UPDATE OF restaurant_id ON khrestianovskii_food.product
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.enforce_order_integrity();

-- Проверяем также существующие данные при установке ограничений.
DO $$
DECLARE v_order_id uuid;
BEGIN
    FOR v_order_id IN SELECT order_id FROM khrestianovskii_food."order" LOOP
        PERFORM khrestianovskii_food.check_order_integrity(v_order_id);
    END LOOP;
END;
$$;

COMMIT;

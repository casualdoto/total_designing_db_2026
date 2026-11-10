CREATE OR REPLACE FUNCTION khrestianovskii_food.validate_order_product()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_order_restaurant uuid;
    v_product_restaurant uuid;
BEGIN
    SELECT restaurant_id INTO v_order_restaurant
    FROM khrestianovskii_food."order" WHERE order_id = NEW.order_id;
    SELECT restaurant_id INTO v_product_restaurant
    FROM khrestianovskii_food.product WHERE product_id = NEW.product_id;
    IF v_order_restaurant IS DISTINCT FROM v_product_restaurant THEN
        RAISE EXCEPTION 'Позиция отклонена: выбранное блюдо относится к другому ресторану';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_product_restaurant_check
BEFORE INSERT OR UPDATE OF order_id, product_id ON khrestianovskii_food.order_structure
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.validate_order_product();

CREATE OR REPLACE FUNCTION khrestianovskii_food.prevent_restaurant_change_with_orders()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        IF EXISTS (
            SELECT 1
            FROM khrestianovskii_food.order_structure os
            JOIN khrestianovskii_food."order" o USING (order_id)
            WHERE os.product_id = OLD.product_id AND o.restaurant_id <> NEW.restaurant_id
        ) THEN
            RAISE EXCEPTION 'Смена ресторана для блюда нарушит состав существующих заказов';
        END IF;
    ELSIF TG_TABLE_NAME = 'order' THEN
        IF EXISTS (
            SELECT 1 FROM khrestianovskii_food.review
            WHERE order_id = OLD.order_id AND entity_type = 'ресторан'
              AND entity_id <> NEW.restaurant_id
        ) THEN
            RAISE EXCEPTION 'У заказа есть отзыв на текущий ресторан: заменить ресторан нельзя';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM khrestianovskii_food.order_structure os
            JOIN khrestianovskii_food.product p USING (product_id)
            WHERE os.order_id = OLD.order_id AND p.restaurant_id <> NEW.restaurant_id
        ) THEN
            RAISE EXCEPTION 'Смена ресторана невозможна: в заказе остаются блюда прежнего ресторана';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER product_restaurant_change_check
BEFORE UPDATE OF restaurant_id ON khrestianovskii_food.product
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.prevent_restaurant_change_with_orders();
CREATE TRIGGER order_restaurant_change_check
BEFORE UPDATE OF restaurant_id ON khrestianovskii_food."order"
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.prevent_restaurant_change_with_orders();

CREATE OR REPLACE FUNCTION khrestianovskii_food.assert_order_amount()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'order_structure' THEN
        IF TG_OP = 'UPDATE' AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
            PERFORM khrestianovskii_food.assert_order_amount_for(OLD.order_id);
        END IF;
    END IF;
    v_order_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
    PERFORM khrestianovskii_food.assert_order_amount_for(v_order_id);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION khrestianovskii_food.assert_order_amount_for(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_expected numeric(14,2);
    v_actual numeric(14,2);
    v_count bigint;
BEGIN
    SELECT order_amount INTO v_actual
    FROM khrestianovskii_food."order" WHERE order_id = p_order_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    SELECT count(*), round(coalesce(sum(quantity * unit_price), 0), 2)
    INTO v_count, v_expected
    FROM khrestianovskii_food.order_structure WHERE order_id = p_order_id;
    IF v_count = 0 OR v_expected <> v_actual THEN
        RAISE EXCEPTION 'Стоимость позиций равна %, а в заказе указано %: необходимо согласовать суммы', v_expected, v_actual;
    END IF;
END;
$$;

CREATE CONSTRAINT TRIGGER order_amount_check_order
AFTER INSERT OR UPDATE ON khrestianovskii_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.assert_order_amount();
CREATE CONSTRAINT TRIGGER order_amount_check_lines
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.order_structure
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.assert_order_amount();

CREATE OR REPLACE FUNCTION khrestianovskii_food.assert_payment_amounts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM khrestianovskii_food.payment p
        JOIN khrestianovskii_food."order" o USING (order_id)
        WHERE o.order_id = NEW.order_id AND p.amount <> o.total_amount
    ) THEN
        RAISE EXCEPTION 'После изменения заказа обнаружен платёж с другой суммой';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER order_payment_amount_check
AFTER UPDATE ON khrestianovskii_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.assert_payment_amounts();

CREATE OR REPLACE FUNCTION khrestianovskii_food.validate_review()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_order_restaurant uuid;
BEGIN
    SELECT restaurant_id INTO v_order_restaurant
    FROM khrestianovskii_food."order" WHERE order_id = NEW.order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Отзыв нельзя сохранить: указанный заказ не найден';
    END IF;

    CASE NEW.entity_type
        WHEN 'блюдо' THEN
            IF NOT EXISTS (
                SELECT 1 FROM khrestianovskii_food.order_structure os
                WHERE os.order_id = NEW.order_id AND os.product_id = NEW.entity_id
            ) THEN
                RAISE EXCEPTION 'Оценивать можно только блюда из состава указанного заказа';
            END IF;
        WHEN 'ресторан' THEN
            IF NEW.entity_id <> v_order_restaurant THEN
                RAISE EXCEPTION 'Выбранный ресторан не обслуживал указанный заказ';
            END IF;
        WHEN 'заказ' THEN
            IF NEW.entity_id <> NEW.order_id THEN
                RAISE EXCEPTION 'Объект оценки должен указывать на тот же заказ, к которому привязан отзыв';
            END IF;
    END CASE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER review_target_check
BEFORE INSERT OR UPDATE OF client_id, order_id, entity_id, entity_type ON khrestianovskii_food.review
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.validate_review();

CREATE OR REPLACE FUNCTION khrestianovskii_food.prevent_reviewed_product_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM khrestianovskii_food.review r
        WHERE r.entity_type = 'блюдо'
          AND r.order_id = OLD.order_id
          AND r.entity_id = OLD.product_id
    ) THEN
        IF TG_OP = 'DELETE' THEN
            RAISE EXCEPTION 'Изменение состава отклонено: на эту позицию ссылается отзыв';
        END IF;
        IF (OLD.order_id, OLD.product_id) IS DISTINCT FROM (NEW.order_id, NEW.product_id) THEN
            RAISE EXCEPTION 'Изменение состава отклонено: на эту позицию ссылается отзыв';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER reviewed_order_product_immutable
BEFORE UPDATE OF order_id, product_id OR DELETE ON khrestianovskii_food.order_structure
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.prevent_reviewed_product_change();

CREATE OR REPLACE FUNCTION khrestianovskii_food.refresh_review_rating(
    p_entity_type khrestianovskii_food.review_entity_type,
    p_entity_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_rating numeric(3,2);
BEGIN
    IF p_entity_type = 'блюдо' THEN
        SELECT round(avg(rating), 2) INTO v_rating
        FROM khrestianovskii_food.review
        WHERE entity_type = p_entity_type AND entity_id = p_entity_id;
        UPDATE khrestianovskii_food.product SET rating = v_rating WHERE product_id = p_entity_id;
    ELSIF p_entity_type = 'ресторан' THEN
        SELECT round(avg(rating), 2) INTO v_rating
        FROM khrestianovskii_food.review
        WHERE entity_type = p_entity_type AND entity_id = p_entity_id;
        UPDATE khrestianovskii_food.restaurant SET rating = v_rating WHERE restaurant_id = p_entity_id;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION khrestianovskii_food.rating_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM khrestianovskii_food.refresh_review_rating(OLD.entity_type, OLD.entity_id);
    END IF;
    IF TG_OP <> 'DELETE'
       AND (TG_OP = 'INSERT' OR (NEW.entity_type, NEW.entity_id) IS DISTINCT FROM (OLD.entity_type, OLD.entity_id)) THEN
        PERFORM khrestianovskii_food.refresh_review_rating(NEW.entity_type, NEW.entity_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.review
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.rating_change();

CREATE OR REPLACE FUNCTION khrestianovskii_food.validate_payment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_total numeric(14,2);
BEGIN
    SELECT total_amount INTO v_total FROM khrestianovskii_food."order" WHERE order_id = NEW.order_id;
    IF v_total IS NULL OR NEW.amount <> v_total THEN
        RAISE EXCEPTION 'Платёж отклонён: его сумма отличается от суммы к оплате';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER payment_amount_check
BEFORE INSERT OR UPDATE OF order_id, amount ON khrestianovskii_food.payment
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.validate_payment();

CREATE OR REPLACE FUNCTION khrestianovskii_food.validate_order_pay_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_expected khrestianovskii_food.order_pay_status;
BEGIN
    SELECT CASE
        WHEN bool_or(status = 'успех') THEN 'оплачен'::khrestianovskii_food.order_pay_status
        WHEN bool_or(status = 'в_обработке') THEN 'ожидает'::khrestianovskii_food.order_pay_status
        WHEN count(*) > 0 THEN 'ошибка'::khrestianovskii_food.order_pay_status
        ELSE 'ожидает'::khrestianovskii_food.order_pay_status
    END INTO v_expected
    FROM khrestianovskii_food.payment WHERE order_id = NEW.order_id;
    IF NEW.pay_status IS DISTINCT FROM v_expected THEN
        RAISE EXCEPTION 'Статус оплаты не соответствует результатам платёжных попыток';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER order_pay_status_check
BEFORE UPDATE OF pay_status ON khrestianovskii_food."order"
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.validate_order_pay_status();

CREATE OR REPLACE FUNCTION khrestianovskii_food.sync_order_pay_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_order_id uuid := CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
    v_status khrestianovskii_food.order_pay_status;
BEGIN
    SELECT CASE
        WHEN bool_or(status = 'успех') THEN 'оплачен'::khrestianovskii_food.order_pay_status
        WHEN bool_or(status = 'в_обработке') THEN 'ожидает'::khrestianovskii_food.order_pay_status
        WHEN count(*) > 0 THEN 'ошибка'::khrestianovskii_food.order_pay_status
        ELSE 'ожидает'::khrestianovskii_food.order_pay_status
    END INTO v_status
    FROM khrestianovskii_food.payment WHERE order_id = v_order_id;
    UPDATE khrestianovskii_food."order" SET pay_status = v_status WHERE order_id = v_order_id;
    IF TG_OP = 'UPDATE' AND OLD.order_id <> NEW.order_id THEN
        PERFORM khrestianovskii_food.sync_order_pay_status_for(OLD.order_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION khrestianovskii_food.sync_order_pay_status_for(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_status khrestianovskii_food.order_pay_status;
BEGIN
    SELECT CASE
        WHEN bool_or(status = 'успех') THEN 'оплачен'::khrestianovskii_food.order_pay_status
        WHEN bool_or(status = 'в_обработке') THEN 'ожидает'::khrestianovskii_food.order_pay_status
        WHEN count(*) > 0 THEN 'ошибка'::khrestianovskii_food.order_pay_status
        ELSE 'ожидает'::khrestianovskii_food.order_pay_status
    END INTO v_status
    FROM khrestianovskii_food.payment WHERE order_id = p_order_id;
    UPDATE khrestianovskii_food."order" SET pay_status = v_status WHERE order_id = p_order_id;
END;
$$;

CREATE TRIGGER payment_order_status
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.payment
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.sync_order_pay_status();

CREATE OR REPLACE FUNCTION khrestianovskii_food.assert_one_successful_payment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_order_id uuid := CASE WHEN TG_TABLE_NAME = 'order' THEN NEW.order_id
                            WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END;
    v_success_count bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM khrestianovskii_food."order" WHERE order_id = v_order_id) THEN
        RETURN NULL;
    END IF;
    SELECT count(*) INTO v_success_count FROM khrestianovskii_food.payment
    WHERE order_id = v_order_id AND status = 'успех';
    IF v_success_count <> 1 THEN
        RAISE EXCEPTION 'Заказ нельзя зафиксировать без единственного успешного платежа';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER order_payment_success_check
AFTER INSERT OR UPDATE ON khrestianovskii_food."order"
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.assert_one_successful_payment();
CREATE CONSTRAINT TRIGGER payment_success_check
AFTER INSERT OR UPDATE OR DELETE ON khrestianovskii_food.payment
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION khrestianovskii_food.assert_one_successful_payment();

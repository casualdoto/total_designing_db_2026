-- FOOD-107. Установить после существующих объектов, перед grants.sql.
CREATE OR REPLACE PROCEDURE khrestianovskii_food.courier_salary()
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, khrestianovskii_food
AS $$
DECLARE
    v_start timestamp := date_trunc('month', localtimestamp);
    v_end timestamp := date_trunc('month', localtimestamp) + interval '1 month';
    v_year smallint := extract(year FROM localtimestamp)::smallint;
    v_month smallint := extract(month FROM localtimestamp)::smallint;
    v_couriers uuid[];
BEGIN
    -- Фиксируем и блокируем один и тот же набор курьеров в порядке UUID.
    -- Второй вызов ждёт здесь, затем читает уже сохранённые coefficient_used.
    SELECT array_agg(locked.courier_id ORDER BY locked.courier_id) INTO v_couriers
    FROM (
        SELECT c.courier_id FROM khrestianovskii_food.courier c
        ORDER BY c.courier_id FOR UPDATE
    ) locked;
    IF v_couriers IS NULL THEN RETURN; END IF;

    -- Отдельный запрос после блокировок получает свежий снимок при READ COMMITTED.
    WITH order_commissions AS (
        SELECT o.order_id, o.courier_id,
            round(round(sum(s.quantity * s.unit_price), 2) * 0.10, 2) AS commission
        FROM khrestianovskii_food."order" o
        JOIN khrestianovskii_food.order_structure s ON s.order_id = o.order_id
        WHERE o.courier_id = ANY(v_couriers) AND o.status = 'доставлен'
          AND o.order_timestamp >= v_start AND o.order_timestamp < v_end
        GROUP BY o.order_id, o.courier_id
    ), deliveries AS (
        SELECT o.courier_id, count(*) AS cnt, sum(o.commission) AS commission
        FROM order_commissions o GROUP BY o.courier_id
    ), payroll AS MATERIALIZED (
        SELECT c.courier_id, coalesce(d.cnt, 0) AS cnt,
            coalesce(p.coefficient_used, c.coefficient) AS coefficient_used,
            round(coalesce(d.commission, 0) * coalesce(p.coefficient_used, c.coefficient), 2) AS amount
        FROM khrestianovskii_food.courier c
        LEFT JOIN deliveries d ON d.courier_id = c.courier_id
        LEFT JOIN khrestianovskii_food.courier_pay p ON p.courier_id = c.courier_id
            AND p.year = v_year AND p.month = v_month
        WHERE c.courier_id = ANY(v_couriers)
    ), paid AS (
        INSERT INTO khrestianovskii_food.courier_pay(year, month, courier_id, amount, coefficient_used)
        SELECT v_year, v_month, p.courier_id, p.amount, p.coefficient_used
        FROM payroll p ORDER BY p.courier_id
        ON CONFLICT (year, month, courier_id) DO UPDATE SET amount = EXCLUDED.amount
        RETURNING courier_id
    )
    UPDATE khrestianovskii_food.courier c
    SET coefficient = CASE WHEN p.cnt <= 150 THEN 0.1 WHEN p.cnt <= 250 THEN 0.2
        WHEN p.cnt <= 500 THEN 0.3 ELSE 0.5 END
    FROM payroll p JOIN paid w ON w.courier_id = p.courier_id
    WHERE c.courier_id = p.courier_id AND c.status <> 'уволен';
END;
$$;

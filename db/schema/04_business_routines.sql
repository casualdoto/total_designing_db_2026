CREATE OR REPLACE PROCEDURE khrestianovskii_food.add_product(
    p_restaurant_id uuid,
    p_product_category_id uuid,
    p_name varchar,
    p_price numeric,
    p_rating numeric,
    p_status khrestianovskii_food.product_status,
    p_description text,
    p_photo_url text DEFAULT NULL
)
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, exts, pg_temp
AS $$
BEGIN
    INSERT INTO khrestianovskii_food.product
        (product_id, product_name, product_category_id, price, restaurant_id,
         photo_url, rating, status, description)
    VALUES
        (exts.uuid_generate_v4(), p_name, p_product_category_id, p_price,
         p_restaurant_id, p_photo_url, p_rating, p_status, p_description);
EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'Блюдо не добавлено: проверьте идентификаторы ресторана и категории';
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'Блюдо не добавлено: обязательные поля или значения заполнены некорректно';
END;
$$;

CREATE OR REPLACE FUNCTION khrestianovskii_food.get_statistic()
RETURNS TABLE (
    restaurant_name varchar,
    best_product_name varchar,
    total_amount numeric,
    avg_amount numeric,
    best_user varchar
)
LANGUAGE sql
SET search_path = khrestianovskii_food, pg_temp
AS $$
    WITH delivered_orders AS MATERIALIZED (
        SELECT order_id, restaurant_id, client_id, total_amount
        FROM khrestianovskii_food."order"
        WHERE status = 'доставлен'
    ),
    order_totals AS (
        SELECT restaurant_id, sum(total_amount) AS total_amount,
               avg(total_amount) AS avg_amount
        FROM delivered_orders
        GROUP BY restaurant_id
    ),
    product_sales AS (
        SELECT d.restaurant_id, os.product_id,
               sum(os.quantity) AS quantity_sold
        FROM delivered_orders d
        JOIN khrestianovskii_food.order_structure os USING (order_id)
        GROUP BY d.restaurant_id, os.product_id
    ),
    best_products AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, product_id
        FROM product_sales
        ORDER BY restaurant_id, quantity_sold DESC, random()
    ),
    client_orders AS (
        SELECT d.restaurant_id, d.client_id, count(*) AS order_count
        FROM delivered_orders d
        GROUP BY d.restaurant_id, d.client_id
    ),
    best_clients AS (
        SELECT DISTINCT ON (restaurant_id) restaurant_id, client_id
        FROM client_orders
        ORDER BY restaurant_id, order_count DESC, random()
    )
    SELECT r.restaurant_name, p.product_name,
           coalesce(ot.total_amount, 0), ot.avg_amount, c.login
    FROM khrestianovskii_food.restaurant r
    LEFT JOIN order_totals ot USING (restaurant_id)
    LEFT JOIN best_products bp USING (restaurant_id)
    LEFT JOIN best_clients bc USING (restaurant_id)
    LEFT JOIN khrestianovskii_food.product p ON p.product_id = bp.product_id
    LEFT JOIN khrestianovskii_food.client c ON c.client_id = bc.client_id
    ORDER BY r.restaurant_name
$$;

CREATE OR REPLACE PROCEDURE khrestianovskii_food.courier_salary()
LANGUAGE plpgsql
SET search_path = khrestianovskii_food, pg_temp
AS $$
DECLARE
    v_month_start timestamp := date_trunc('month', localtimestamp);
    v_year integer := extract(year FROM v_month_start)::integer;
    v_month integer := extract(month FROM v_month_start)::integer;
BEGIN
    -- Один набор итогов за месяц используется и для выплат, и для новых ставок.
    WITH monthly_deliveries AS (
        SELECT courier_id, count(*) AS delivery_count, sum(commission) AS commission_sum
        FROM khrestianovskii_food."order"
        WHERE status = 'доставлен'
          AND delivery_timestamp >= v_month_start
          AND delivery_timestamp < v_month_start + interval '1 month'
        GROUP BY courier_id
    ), payroll AS MATERIALIZED (
        SELECT c.courier_id,
               coalesce(d.delivery_count, 0) AS delivery_count,
               coalesce(d.commission_sum, 0) AS commission_sum,
               coalesce(cp.coefficient_used, c.coefficient) AS coefficient_used
        FROM khrestianovskii_food.courier c
        LEFT JOIN monthly_deliveries d ON d.courier_id = c.courier_id
        LEFT JOIN khrestianovskii_food.courier_pay cp
          ON cp.courier_id = c.courier_id AND cp.year = v_year AND cp.month = v_month
    ), saved_pay AS (
        INSERT INTO khrestianovskii_food.courier_pay
            (year, month, courier_id, amount, coefficient_used)
        SELECT v_year, v_month, courier_id,
               round(commission_sum * coefficient_used, 2), coefficient_used
        FROM payroll
        ON CONFLICT (year, month, courier_id) DO UPDATE
        SET amount = EXCLUDED.amount
        RETURNING courier_id
    )
    UPDATE khrestianovskii_food.courier c
    SET coefficient = CASE
        WHEN p.delivery_count <= 150 THEN 0.1
        WHEN p.delivery_count <= 250 THEN 0.2
        WHEN p.delivery_count <= 500 THEN 0.3
        ELSE 0.5
    END
    FROM payroll p
    JOIN saved_pay s ON s.courier_id = p.courier_id
    WHERE c.courier_id = p.courier_id AND c.status <> 'уволен';
END;
$$;

CREATE OR REPLACE VIEW khrestianovskii_food.how_much_money AS
WITH RECURSIVE bounds AS (
    SELECT date_trunc('month', min(delivery_timestamp)) AS first_month,
           date_trunc('month', max(delivery_timestamp)) AS last_month
    FROM khrestianovskii_food."order"
    WHERE status = 'доставлен'
), months(month_start, last_month) AS (
    SELECT first_month, last_month FROM bounds WHERE first_month IS NOT NULL
    UNION ALL
    SELECT month_start + interval '1 month', last_month
    FROM months WHERE month_start < last_month
), order_totals AS (
    SELECT date_trunc('month', delivery_timestamp) AS month_start,
           sum(order_amount) AS sum_no_commission,
           sum(total_amount) AS sum_with_commission
    FROM khrestianovskii_food."order"
    WHERE status = 'доставлен'
    GROUP BY date_trunc('month', delivery_timestamp)
), pay_totals AS (
    SELECT make_date(year, month, 1)::timestamp AS month_start,
           sum(amount) AS courier_pay
    FROM khrestianovskii_food.courier_pay
    GROUP BY year, month
), month_values AS (
    SELECT m.month_start,
           coalesce(ot.sum_no_commission, 0)::numeric AS sum_no_commission,
           coalesce(ot.sum_with_commission, 0)::numeric AS sum_with_commission,
           (coalesce(ot.sum_with_commission, 0) - coalesce(ot.sum_no_commission, 0))::numeric AS commission,
           coalesce(pt.courier_pay, 0)::numeric AS courier_pay
    FROM months m
    LEFT JOIN order_totals ot USING (month_start)
    LEFT JOIN pay_totals pt USING (month_start)
), lagged AS (
    SELECT month_start, sum_no_commission, sum_with_commission, commission,
           lag(commission) OVER (ORDER BY month_start) AS prev_commission,
           courier_pay
    FROM month_values
)
SELECT to_char(month_start, 'YYYY-MM')::text AS year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission - prev_commission AS commission_diff,
       courier_pay,
       commission - courier_pay AS net_profit
FROM lagged;

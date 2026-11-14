-- FOOD-106. Установить после существующих объектов, перед grants.sql.
CREATE OR REPLACE FUNCTION khrestianovskii_food.get_statistic()
RETURNS TABLE (
    restaurant_name text,
    best_product_name text,
    total_amount numeric,
    avg_amount numeric,
    best_user text
)
LANGUAGE sql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, khrestianovskii_food
AS $$
WITH delivered_lines AS MATERIALIZED (
    -- Базовые заказы и позиции читаются одним JOIN. Платежи не нужны.
    SELECT o.order_id, o.restaurant_id, o.client_id, s.product_id, s.quantity, s.unit_price
    FROM khrestianovskii_food."order" o
    JOIN khrestianovskii_food.order_structure s ON s.order_id = o.order_id
    WHERE o.status = 'доставлен'
), order_amounts AS (
    SELECT l.order_id, l.restaurant_id, l.client_id,
           round(sum(l.quantity * l.unit_price), 2) AS amount
    FROM delivered_lines l
    GROUP BY l.order_id, l.restaurant_id, l.client_id
), delivered_totals AS MATERIALIZED (
    -- Те же округления и комиссия, что в order_totals, без расчёта оплаты.
    SELECT a.order_id, a.restaurant_id, a.client_id,
           a.amount + round(a.amount * 0.10, 2) AS amount
    FROM order_amounts a
), restaurant_stats AS (
    SELECT d.restaurant_id, sum(d.amount) AS total_amount, avg(d.amount) AS avg_amount
    FROM delivered_totals d
    GROUP BY d.restaurant_id
), product_quantities AS MATERIALIZED (
    SELECT l.restaurant_id, l.product_id, sum(l.quantity) AS quantity
    FROM delivered_lines l
    GROUP BY l.restaurant_id, l.product_id
), product_maxima AS (
    SELECT q.restaurant_id, max(q.quantity) AS quantity
    FROM product_quantities q GROUP BY q.restaurant_id
), best_products AS (
    SELECT q.restaurant_id,
           (array_agg(q.product_id))[1 + floor(random() * count(*))::int] AS product_id
    FROM product_quantities q
    JOIN product_maxima m ON m.restaurant_id = q.restaurant_id AND m.quantity = q.quantity
    GROUP BY q.restaurant_id
), client_counts AS MATERIALIZED (
    -- delivered_totals содержит ровно одну строку на заказ, не на позицию.
    SELECT d.restaurant_id, d.client_id, count(*) AS purchases
    FROM delivered_totals d
    GROUP BY d.restaurant_id, d.client_id
), client_maxima AS (
    SELECT c.restaurant_id, max(c.purchases) AS purchases
    FROM client_counts c GROUP BY c.restaurant_id
), best_clients AS (
    SELECT c.restaurant_id,
           (array_agg(c.client_id))[1 + floor(random() * count(*))::int] AS client_id
    FROM client_counts c
    JOIN client_maxima m ON m.restaurant_id = c.restaurant_id AND m.purchases = c.purchases
    GROUP BY c.restaurant_id
)
SELECT r.restaurant_name::text, p.product_name::text,
       coalesce(s.total_amount, 0), coalesce(s.avg_amount, 0), c.login::text
FROM khrestianovskii_food.restaurant r
LEFT JOIN restaurant_stats s ON s.restaurant_id = r.restaurant_id
LEFT JOIN best_products bp ON bp.restaurant_id = r.restaurant_id
LEFT JOIN khrestianovskii_food.product p ON p.product_id = bp.product_id
LEFT JOIN best_clients bc ON bc.restaurant_id = r.restaurant_id
LEFT JOIN khrestianovskii_food.client c ON c.client_id = bc.client_id;
$$;

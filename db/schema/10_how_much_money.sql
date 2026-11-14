-- FOOD-108. Установить после существующих объектов, перед grants.sql.
CREATE OR REPLACE VIEW khrestianovskii_food.how_much_money
WITH (security_invoker = true)
AS
WITH RECURSIVE order_amounts AS (
    SELECT o.order_id, date_trunc('month', o.order_timestamp)::date AS month_start,
           round(sum(s.quantity * s.unit_price), 2) AS amount
    FROM khrestianovskii_food."order" o
    JOIN khrestianovskii_food.order_structure s ON s.order_id = o.order_id
    WHERE o.status = 'доставлен'
    GROUP BY o.order_id, date_trunc('month', o.order_timestamp)::date
), monthly_orders AS MATERIALIZED (
    SELECT a.month_start, sum(a.amount) AS sum_no_commission,
           sum(a.amount + round(a.amount * 0.10, 2)) AS sum_with_commission
    FROM order_amounts a GROUP BY a.month_start
), bounds AS (
    SELECT min(o.month_start) AS first_month, max(o.month_start) AS last_month
    FROM monthly_orders o
), calendar(month_start, last_month) AS (
    SELECT b.first_month, b.last_month FROM bounds b WHERE b.first_month IS NOT NULL
    UNION ALL
    SELECT (c.month_start + interval '1 month')::date, c.last_month
    FROM calendar c WHERE c.month_start < c.last_month
), monthly_pay AS (
    SELECT make_date(p.year, p.month, 1) AS month_start, sum(p.amount) AS amount
    FROM khrestianovskii_food.courier_pay p GROUP BY p.year, p.month
), filled_months AS (
    SELECT c.month_start,
           coalesce(o.sum_no_commission, 0) AS sum_no_commission,
           coalesce(o.sum_with_commission, 0) AS sum_with_commission,
           coalesce(o.sum_with_commission, 0) - coalesce(o.sum_no_commission, 0) AS commission,
           coalesce(p.amount, 0) AS courier_pay
    FROM calendar c
    LEFT JOIN monthly_orders o ON o.month_start = c.month_start
    LEFT JOIN monthly_pay p ON p.month_start = c.month_start
), compared_months AS (
    SELECT f.*, lag(f.commission) OVER (ORDER BY f.month_start) AS prev_commission
    FROM filled_months f
)
SELECT to_char(m.month_start, 'YYYY-MM') AS year_month,
       m.sum_no_commission, m.sum_with_commission, m.commission, m.prev_commission,
       m.commission - m.prev_commission AS commission_diff, m.courier_pay,
       m.commission - m.courier_pay AS net_profit
FROM compared_months m;

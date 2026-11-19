create or replace view how_much_money as
with recursive
  bounds as (
    select
      date_trunc('month', min(delivery_timestamp))::date as first_m,
      date_trunc('month', max(delivery_timestamp))::date as last_m
    from
      "order"
    where
      status = 'доставлен'
  ),
  months (m) as (
    select
      first_m
    from
      bounds
    where
      first_m is not null
    union all
    select
      (months.m + interval '1 month')::date
    from
      months
      cross join bounds b
    where
      months.m < b.last_m
  ),
  orders_m as (
    select
      date_trunc('month', delivery_timestamp)::date as m,
      sum(order_amount) as sum_no_commission,
      sum(total_amount) as sum_with_commission
    from
      "order"
    where
      status = 'доставлен'
    group by
      1
  ),
  pay_m as (
    select
      make_date(year, month, 1) as m,
      sum(amount) as courier_pay
    from
      courier_pay
    group by
      1
  ),
  base as (
    select
      mo.m,
      coalesce(o.sum_no_commission, 0) as sum_no_commission,
      coalesce(o.sum_with_commission, 0) as sum_with_commission,
      coalesce(o.sum_with_commission, 0) - coalesce(o.sum_no_commission, 0) as commission,
      coalesce(p.courier_pay, 0) as courier_pay
    from
      months mo
      left join orders_m o on o.m = mo.m
      left join pay_m p on p.m = mo.m
  )
select
  to_char(m, 'YYYY-MM')::text as year_month,
  sum_no_commission::numeric,
  sum_with_commission::numeric,
  commission::numeric,
  lag(commission) over (
    order by
      m
  )::numeric as prev_commission,
  (
    commission - lag(commission) over (
      order by
        m
    )
  )::numeric as commission_diff,
  courier_pay::numeric,
  (commission - courier_pay)::numeric as net_profit
from
  base
order by
  m;
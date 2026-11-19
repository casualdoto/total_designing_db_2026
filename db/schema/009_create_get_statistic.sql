create or replace function get_statistic () returns table (
  restaurant_name varchar(100),
  best_product_name varchar(100),
  total_amount numeric,
  avg_amount numeric,
  best_user varchar(50)
) language plpgsql as $$
begin
    return query
    with delivered_orders as materialized (
        select
            o.order_id,
            o.restaurant_id,
            o.client_id,
            o.total_amount
        from "order" o
        where o.status = 'доставлен'
    ),

    restaurant_totals as (
        select
            d.restaurant_id,
            sum(d.total_amount) as sum_amount,
            avg(d.total_amount) as average_amount
        from delivered_orders d
        group by d.restaurant_id
    ),

    product_counts as (
        select
            d.restaurant_id,
            os.product_id,
            sum(os.quantity) as quantity
        from delivered_orders d
        join order_structure os using (order_id)
        group by d.restaurant_id, os.product_id
    ),

    best_products as (
        select distinct on (pc.restaurant_id)
            pc.restaurant_id,
            p.product_name
        from product_counts pc
        join product p using (product_id)
        order by pc.restaurant_id, pc.quantity desc, random()
    ),

    user_counts as (
        select
            d.restaurant_id,
            d.client_id,
            count(*) as order_count
        from delivered_orders d
        group by d.restaurant_id, d.client_id
    ),

    best_users as (
        select distinct on (uc.restaurant_id)
            uc.restaurant_id,
            c.login
        from user_counts uc
        join client c using (client_id)
        order by uc.restaurant_id, uc.order_count desc, random()
    )

    select
        r.restaurant_name,
        bp.product_name,
        rt.sum_amount,
        rt.average_amount,
        bu.login
    from restaurant r
    left join restaurant_totals rt using (restaurant_id)
    left join best_products bp using (restaurant_id)
    left join best_users bu using (restaurant_id);
end;
$$;
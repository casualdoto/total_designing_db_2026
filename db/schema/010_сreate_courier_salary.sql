create or replace procedure courier_salary () language plpgsql as $$
declare
    v_start date := date_trunc('month', current_date)::date;
    v_end   date := (date_trunc('month', current_date) + interval '1 month')::date;
    v_year  int  := extract(year from current_date)::int;
    v_month int  := extract(month from current_date)::int;
begin
    with m as (
        select courier_id,
               count(*) as cnt,
               sum(commission) as sum_comm
        from "order"
        where status = 'доставлен'
          and delivery_timestamp >= v_start
          and delivery_timestamp <  v_end
        group by courier_id
    ),
    calc as (
        select c.courier_id,
               c.status,
               coalesce(m.cnt, 0)      as cnt,
               coalesce(m.sum_comm, 0) as sum_comm,
               coalesce(p.coefficient_used, c.coefficient) as coef_used
        from courier c
        left join m on m.courier_id = c.courier_id
        left join courier_pay p
               on p.year = v_year
              and p.month = v_month
              and p.courier_id = c.courier_id
        where c.dismissal_date is null
           or c.dismissal_date >= v_start
    ),
    upsert as (
        insert into courier_pay (year, month, courier_id, amount, coefficient_used)
        select v_year,
               v_month,
               courier_id,
               round(coef_used * sum_comm, 2),
               coef_used
        from calc
        on conflict (year, month, courier_id) do update
           set amount           = excluded.amount,
               coefficient_used = excluded.coefficient_used
        returning courier_id
    )
    update courier c
       set coefficient = case
                             when calc.cnt <= 150 then 0.1
                             when calc.cnt <= 250 then 0.2
                             when calc.cnt <= 500 then 0.3
                             else 0.5
                         end
      from calc
     where calc.courier_id = c.courier_id
       and calc.status <> 'уволен';
end;
$$;
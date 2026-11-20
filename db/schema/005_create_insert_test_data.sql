create or replace procedure insert_test_data (value int) language plpgsql as $$
declare
    v_n     int := value;
    v_now   timestamp := localtimestamp;
    v_today date      := current_date;
    v_lo    timestamp := date_trunc('month', localtimestamp) - interval '5 months';
    v_hi    timestamp := localtimestamp - interval '2 hours';

    v_coef_min         numeric := 0.1;
    v_min_order_amount numeric := 910;

    v_cat_ids    uuid[];
    v_cour_ids   uuid[];
    v_cour_hire  date[];
    v_cour_dism  date[];
    v_addr_ids   uuid[];
    v_rest_ids   uuid[];
    v_client_ids uuid[];
    v_prod_ids   uuid[];
    v_courier_rows jsonb;
    v_order_seed_rows jsonb;
    v_line_rows jsonb;
    v_order_rows jsonb;
    v_delivery_rows jsonb;
    v_review_rows jsonb;

    v_cour_active courier_status[];
    v_cat_cnt     int;
    v_phone_next  bigint;
    v_deliv_cnt   int;
    v_k           int;
    v_month_start date;
    v_month_end   date;

begin
    if v_n is null or v_n < 1 then
        raise exception 'параметр value должен быть целым числом >= 1';
    end if;

    v_cat_cnt := v_n;

    v_cour_active := array(
        select e
        from unnest(enum_range(null::courier_status)) as e
        where e <> 'уволен'
    );

    select coalesce(max(substr(phone_number, 3)::bigint), 0)
      into v_phone_next
      from client
     where phone_number ~ '^\+7[0-9]{10}$';

    v_phone_next := greatest(v_phone_next, 8999999999) + 1;

    if v_phone_next + 3::bigint * v_n > 9999999999 then
        raise exception 'закончились свободные номера телефонов для клиентов';
    end if;

    select array_agg(exts.uuid_generate_v4() order by i)
      into v_cat_ids
      from generate_series(1, v_n) as gs(i);

    insert into product_category (
        product_category_id,
        product_category_name
    )
    select v_cat_ids[i],
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   1 + floor(random() * 100)::int + i * 0
               )
               ), ''))
    from generate_series(1, v_n) as gs(i);

    select jsonb_agg(to_jsonb(s))
      into v_courier_rows
      from (
    select s.idx,
           s.courier_id,
           s.status,
           s.hire_date,
           case
               when s.status = 'уволен'
               then s.hire_date + 10
                    + floor(s.u * (v_today - s.hire_date - 10))::int
           end as dismissal_date,
           s.last_name,
           s.first_name,
           s.middle_name,
           '+79' || lpad((900000000 + s.idx)::text, 9, '0') as phone_number
    from (
        select i as idx,
               exts.uuid_generate_v4() as courier_id,
               v_today - (60 + floor(random() * 121))::int as hire_date,
               random() as u,
               (
                   select array_to_string(array(
                       select
                       substr(
                           'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                           floor(random() * 33)::int + 1,
                           1
                       )
                   from generate_series(
                       1,
                       1 + floor(random() * 49)::int + i * 0
                   )
                   ), '')) as last_name,
               (
                   select array_to_string(array(
                       select
                       substr(
                           'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                           floor(random() * 33)::int + 1,
                           1
                       )
                   from generate_series(
                       1,
                       1 + floor(random() * 49)::int + i * 0
                   )
                   ), '')) as first_name,
               case
                   when random() < 0.5 then (
                       select array_to_string(array(
                           select
                           substr(
                               'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                               floor(random() * 33)::int + 1,
                               1
                           )
                       from generate_series(
                           1,
                           1 + floor(random() * 49)::int + i * 0
                       )
                       ), ''))
               end as middle_name,
               case
                   when i > 1 and random() < 0.2
                   then 'уволен'::courier_status
                   else v_cour_active[
                       1 + floor(random() * cardinality(v_cour_active))::int
                   ]
               end as status
        from generate_series(1, v_n) as gs(i)
    ) s
      ) s;

    insert into courier (
        courier_id,
        last_name,
        first_name,
        middle_name,
        phone_number,
        status,
        hire_date,
        dismissal_date,
        coefficient
    )
    select courier_id,
           last_name,
           first_name,
           middle_name,
           phone_number,
           status,
           hire_date,
           dismissal_date,
           v_coef_min
    from jsonb_to_recordset(v_courier_rows) as c(
        idx int, courier_id uuid, status courier_status, hire_date date,
        dismissal_date date, last_name varchar, first_name varchar,
        middle_name varchar, phone_number varchar
    );

    select array_agg(courier_id order by idx),
           array_agg(hire_date order by idx),
           array_agg(dismissal_date order by idx)
      into v_cour_ids, v_cour_hire, v_cour_dism
      from jsonb_to_recordset(v_courier_rows) as c(
          idx int, courier_id uuid, status courier_status, hire_date date,
          dismissal_date date
      )
      where status != 'уволен';

    select array_agg(exts.uuid_generate_v4() order by i)
      into v_addr_ids
      from generate_series(1, 5 * v_n) as gs(i);

    insert into address (
        address_id,
        street,
        house_number,
        apartment_office
    )
    select v_addr_ids[i],
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   1 + floor(random() * 100)::int + i * 0
               )
               ), '')),
           (1 + floor(random() * 150))::int::text,
           case
               when i > v_n and random() < 0.8
               then (1 + floor(random() * 400))::int::text
           end
    from generate_series(1, 5 * v_n) as gs(i);

    select array_agg(exts.uuid_generate_v4() order by i)
      into v_rest_ids
      from generate_series(1, v_n) as gs(i);

    insert into restaurant (
        restaurant_id,
        restaurant_name,
        address_id,
        description,
        work_start,
        work_end,
        company_details,
        status
    )
    select v_rest_ids[s.i],
           s.restaurant_name,
           v_addr_ids[s.i],
           array_to_string(
               array(
                   select substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
                   from generate_series(
                       1,
                       15 + floor(random() * 36)::int + s.i * 0
                   )
               ),
               ''
           ),
           make_time(s.h1, s.m1, 0),
           make_time(s.h2, s.m2, 0),
           'ООО «' || s.restaurant_name || '», ИНН '
               || lpad(s.inn::text, 10, '0')
               || ', ОГРН '
               || lpad(s.ogrn::text, 13, '0')
               || ', р/с ' || s.settlement_account,
           s.st
    from (
        select i as i,
               (
                   select array_to_string(array(
                       select
                       substr(
                           'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                           floor(random() * 33)::int + 1,
                           1
                       )
                   from generate_series(
                       1,
                       1 + floor(random() * 100)::int + i * 0
                   )
                   ), '')) as restaurant_name,
               7 + floor(random() * 5)::int as h1,
               20 + floor(random() * 4)::int as h2,
               (array[0, 30])[1 + floor(random() * 2)::int] as m1,
               (array[0, 30])[1 + floor(random() * 2)::int] as m2,
               floor(random() * 1e10)::bigint as inn,
               floor(random() * 1e13)::bigint as ogrn,
               (
                   select array_to_string(array(
                       select floor(random() * 10 + i * 0)::int::text
                       from generate_series(1, 20)
                   ), '')
               ) as settlement_account,
               case
                   when random() < 0.85
                   then 'активен'::restaurant_status
                   else (enum_range(null::restaurant_status))[
                       1 + floor(
                           random() * cardinality(
                               enum_range(null::restaurant_status)
                           )
                       )::int
                   ]
               end as st
        from generate_series(1, v_n) as gs(i)
    ) s;

    insert into restaurant_legal_details (
        restaurant_id,
        legal_name,
        inn,
        ogrn,
        settlement_account
    )
    select r.restaurant_id,
           parsed.parts[1],
           parsed.parts[2],
           parsed.parts[3],
           parsed.parts[4]
    from restaurant r
    cross join lateral regexp_match(
        r.company_details,
        '^(.+), ИНН ([0-9]{10}), ОГРН ([0-9]{13}), р/с ([0-9]{20})$'
    ) as parsed(parts)
    where r.restaurant_id = any(v_rest_ids);

    if (
        select count(*)
        from restaurant_legal_details
        where restaurant_id = any(v_rest_ids)
    ) <> v_n then
        raise exception 'не удалось нормализовать реквизиты ресторанов';
    end if;

    select array_agg(exts.uuid_generate_v4() order by i)
      into v_client_ids
      from generate_series(1, v_n) as gs(i);

    insert into client (
        client_id,
        login,
        password,
        phone_number
    )
    select v_client_ids[i],
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   1 + floor(random() * 33)::int + i * 0
               )
               ), '')) || '_' || substr(replace(v_client_ids[i]::text, '-', ''), 1, 16),
           md5(random()::text),
           '+7' || (
               v_phone_next
               + (i - 1)::bigint * 3
               + floor(random() * 3)::bigint
           )::text
    from generate_series(1, v_n) as clients(i);

    insert into client_address (
        client_id,
        address_id
    )
    select v_client_ids[i], v_addr_ids[v_n + address_slot * v_n + i]
    from generate_series(1, v_n) as clients(i)
    cross join generate_series(0, 3) as slots(address_slot);

    select array_agg(exts.uuid_generate_v4() order by i)
      into v_prod_ids
      from generate_series(1, 5 * v_n) as gs(i);

    insert into product (
        product_id,
        product_name,
        product_category_id,
        price,
        restaurant_id,
        photo_url,
        rating,
        status,
        description
    )
    select v_prod_ids[s.k],
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   1 + floor(random() * 100)::int + s.k * 0
               )
               ), '')),
           v_cat_ids[s.c],
           case
               when random() < 0.2
               then (5 + floor(random() * 31)::int) * 10
               else (15 + floor(random() * 226)::int) * 10
           end,
           v_rest_ids[s.r],
           case
               when random() < 0.7
               then 'https://cdn.foodexpress.ru/img/'
                    || md5(random()::text) || '.jpg'
           end,
           null,
           case
               when random() < 0.75
               then 'доступно'::product_status
               else (enum_range(null::product_status))[
                   1 + floor(
                       random() * cardinality(
                           enum_range(null::product_status)
                       )
                   )::int
               ]
           end,
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   15 + floor(random() * 36)::int + s.k * 0
               )
               ), ''))
    from (
        select k,
               (k - 1) / 5 + 1 as r,
               1 + floor(random() * v_n)::int as c
        from generate_series(1, 5 * v_n) as gs(k)
    ) s;

    select jsonb_agg(to_jsonb(o))
      into v_order_seed_rows
      from (
    select i as idx,
           exts.uuid_generate_v4() as order_id,
           1 + floor(random() * v_n)::int as r_idx,
           (i - 1) % v_n + 1 as cl_idx,
           1 + floor(random() * cardinality(v_cour_ids))::int as c_idx,
           1 + floor(random() * 5)::int as cnt,
           floor(random() * 5)::int as sft,
           random() as u_ts,
           random() as u_dl,
           case
               when i % 2 = 1 or random() < 0.4
               then 'доставлен'::order_status
               else (enum_range(null::order_status))[
                   1 + floor(
                       random() * cardinality(
                           enum_range(null::order_status)
                       )
                   )::int
               ]
           end as status
    from generate_series(1, 5 * v_n) as gs(i)
      ) o;

    select jsonb_agg(to_jsonb(l))
      into v_line_rows
      from (
    select o.idx,
           o.order_id,
           x.pos,
           x.product_id,
           x.quantity,
           p.price
    from jsonb_to_recordset(v_order_seed_rows) as o(
        idx int, order_id uuid, r_idx int, cl_idx int, c_idx int,
        cnt int, sft int, u_ts double precision, u_dl double precision,
        status order_status
    )
    cross join lateral (
        select t as pos,
               v_prod_ids[
                   (o.r_idx - 1) * 5 + (o.sft + t) % 5 + 1
               ] as product_id,
               1 + floor(random() * 3)::int as quantity
        from generate_series(0, o.cnt - 1) as gs(t)
    ) x
    join product p on p.product_id = x.product_id
      ) l;

    select jsonb_agg(to_jsonb(l))
      into v_line_rows
      from (
    select l.idx,
           l.order_id,
           l.pos,
           l.product_id,
           l.quantity + case
               when l.pos = 0 and a.amount < v_min_order_amount
               then ceil((v_min_order_amount - a.amount) / l.price)::int
               else 0
           end as quantity,
           l.price
    from jsonb_to_recordset(v_line_rows) as l(
        idx int, order_id uuid, pos int, product_id uuid, quantity int,
        price numeric
    )
    join (
        select order_id, sum(price * quantity) as amount
        from jsonb_to_recordset(v_line_rows) as line(
            idx int, order_id uuid, pos int, product_id uuid, quantity int,
            price numeric
        )
        group by order_id
    ) a on a.order_id = l.order_id
      ) l;

    select jsonb_agg(to_jsonb(m))
      into v_order_rows
      from (
    select m.idx,
           m.order_id,
           m.client_id,
           m.restaurant_id,
           m.courier_id,
           m.address_id,
           m.status,
           m.order_timestamp,
           case
               when m.status = 'доставлен'
               then m.order_timestamp
                    + (15 + floor(m.u_dl * 76)::int) * interval '1 minute'
           end as delivery_timestamp,
           m.order_amount,
           round(m.order_amount * 0.10, 2) as commission,
           m.order_amount
               + round(m.order_amount * 0.10, 2) as total_amount,
           m.description
    from (
        select b.*,
               b.lo + (b.hi - b.lo) * b.u_ts as order_timestamp
        from (
            select o.idx,
                   o.order_id,
                   o.status,
                   o.u_ts,
                   o.u_dl,
                   v_client_ids[o.cl_idx] as client_id,
                   v_rest_ids[o.r_idx] as restaurant_id,
                   v_cour_ids[o.c_idx] as courier_id,
                   -- Первые четыре заказа клиента используют все его адреса.
                   v_addr_ids[v_n + v_n * case
                       when o.idx <= 4 * v_n then (o.idx - 1) / v_n
                       else floor(random() * 4)::int
                   end + o.cl_idx] as address_id,
                   a.order_amount,
                   case
                       when o.status in ('в_доставке', 'доставлен')
                       then greatest(v_lo, v_cour_hire[o.c_idx]::timestamp)
                       else v_lo
                   end as lo,
                   case
                       when o.status in ('в_доставке', 'доставлен')
                            and v_cour_dism[o.c_idx] is not null
                       then least(
                           v_hi,
                           v_cour_dism[o.c_idx]::timestamp - interval '3 hours'
                       )
                       else v_hi
                   end as hi,
                   (
                       select array_to_string(array(
                           select
                           substr(
                               'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                               floor(random() * 33)::int + 1,
                               1
                           )
                       from generate_series(
                           1,
                           10 + floor(random() * 31)::int + o.idx * 0
                       )
                       ), '')) as description
            from jsonb_to_recordset(v_order_seed_rows) as o(
                idx int, order_id uuid, r_idx int, cl_idx int, c_idx int,
                cnt int, sft int, u_ts double precision, u_dl double precision,
                status order_status
            )
            join (
                select order_id,
                       round(sum(price * quantity), 2) as order_amount
                from jsonb_to_recordset(v_line_rows) as line(
                    idx int, order_id uuid, pos int, product_id uuid,
                    quantity int, price numeric
                )
                group by order_id
            ) a on a.order_id = o.order_id
        ) b
    ) m
      ) m;

    insert into "order" (
        order_id,
        courier_id,
        client_id,
        address_id,
        restaurant_id,
        order_timestamp,
        delivery_timestamp,
        order_amount,
        commission,
        total_amount,
        status,
        pay_status,
        description
    )
    select order_id,
           courier_id,
           client_id,
           address_id,
           restaurant_id,
           order_timestamp,
           delivery_timestamp,
           order_amount,
           commission,
           total_amount,
           status,
           'оплачен',
           description
    from jsonb_to_recordset(v_order_rows) as o(
        idx int, order_id uuid, client_id uuid, restaurant_id uuid,
        courier_id uuid, address_id uuid, status order_status,
        order_timestamp timestamp, delivery_timestamp timestamp,
        order_amount numeric, commission numeric, total_amount numeric,
        description text
    );

    insert into order_structure (
        order_id,
        product_id,
        quantity
    )
    select order_id,
           product_id,
           quantity
    from jsonb_to_recordset(v_line_rows) as l(
        idx int, order_id uuid, pos int, product_id uuid, quantity int,
        price numeric
    );

    insert into payment (
        payment_id,
        order_id,
        payment_type,
        amount,
        transaction_id,
        transaction_timestamp,
        status
    )
    select exts.uuid_generate_v4(),
           o.order_id,
           (enum_range(null::payment_type))[
               1 + floor(
                   random() * cardinality(
                       enum_range(null::payment_type)
                   )
               )::int
           ],
           o.total_amount,
           exts.uuid_generate_v4(),
           o.order_timestamp
               + (1 + floor(random() * 10)::int) * interval '1 minute',
           'успех'::payment_status
    from jsonb_to_recordset(v_order_rows) as o(
        idx int, order_id uuid, client_id uuid, restaurant_id uuid,
        courier_id uuid, address_id uuid, status order_status,
        order_timestamp timestamp, delivery_timestamp timestamp,
        order_amount numeric, commission numeric, total_amount numeric,
        description text
    );

    select count(*)
      into v_deliv_cnt
      from jsonb_to_recordset(v_order_rows) as o(
          idx int, order_id uuid, client_id uuid, restaurant_id uuid,
          courier_id uuid, address_id uuid, status order_status,
          order_timestamp timestamp, delivery_timestamp timestamp,
          order_amount numeric, commission numeric, total_amount numeric,
          description text
      )
     where status = 'доставлен';

    select jsonb_agg(to_jsonb(d))
      into v_delivery_rows
      from (
    select row_number() over (order by o.idx) as rn,
           o.order_id,
           o.client_id,
           o.restaurant_id,
           o.delivery_timestamp,
           t.cnt,
           floor(random() * (t.cnt + 2))::int as sh
    from jsonb_to_recordset(v_order_rows) as o(
        idx int, order_id uuid, client_id uuid, restaurant_id uuid,
        courier_id uuid, address_id uuid, status order_status,
        order_timestamp timestamp, delivery_timestamp timestamp,
        order_amount numeric, commission numeric, total_amount numeric,
        description text
    )
    join jsonb_to_recordset(v_order_seed_rows) as t(
        idx int, order_id uuid, r_idx int, cl_idx int, c_idx int,
        cnt int, sft int, u_ts double precision, u_dl double precision,
        status order_status
    ) on t.order_id = o.order_id
    where o.status = 'доставлен'
      ) d;

    select jsonb_agg(to_jsonb(r))
      into v_review_rows
      from (
    select exts.uuid_generate_v4() as review_id,
           x.client_id,
           x.order_id,
           least(
               v_now,
               x.delivery_timestamp
                   + (10 + floor(x.u_ts * 120)::int) * interval '1 minute'
           ) as review_timestamp,
           case
               when x.ci = 0 then x.order_id
               when x.ci = 1 then x.restaurant_id
               else l.product_id
           end as entity_id,
           case
               when x.ci = 0 then 'заказ'::review_entity_type
               when x.ci = 1 then 'ресторан'::review_entity_type
               else 'блюдо'::review_entity_type
           end as entity_type,
           (
               select array_to_string(array(
                   select
                   substr(
                       'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
                       floor(random() * 33)::int + 1,
                       1
                   )
               from generate_series(
                   1,
                   15 + floor(random() * 46)::int + x.ci * 0
               )
               ), '')) as description,
           case
               when random() < 0.2
               then 'https://cdn.foodexpress.ru/img/'
                    || md5(random()::text) || '.jpg'
           end as photo_url,
           x.rating
    from (
        select d.client_id,
               d.order_id,
               d.restaurant_id,
               d.delivery_timestamp,
               ((k - 1) / v_deliv_cnt + d.sh) % (d.cnt + 2) as ci,
               1 + floor(power(random(), 0.5) * 5)::int as rating,
               random() as u_ts
        from generate_series(1, 5 * v_n) as gs(k)
        join jsonb_to_recordset(v_delivery_rows) as d(
            rn bigint, order_id uuid, client_id uuid, restaurant_id uuid,
            delivery_timestamp timestamp, cnt int, sh int
        )
          on d.rn = (k - 1) % v_deliv_cnt + 1
    ) x
    left join jsonb_to_recordset(v_line_rows) as l(
        idx int, order_id uuid, pos int, product_id uuid, quantity int,
        price numeric
    )
      on l.order_id = x.order_id
     and l.pos = x.ci - 2
      ) r;

    insert into review (
        review_id,
        client_id,
        review_timestamp,
        entity_id,
        entity_type,
        order_id,
        description,
        photo_url,
        rating
    )
    select review_id,
           client_id,
           review_timestamp,
           entity_id,
           entity_type,
           order_id,
           description,
           photo_url,
           rating
    from jsonb_to_recordset(v_review_rows) as r(
        review_id uuid, client_id uuid, order_id uuid,
        review_timestamp timestamp, entity_id uuid,
        entity_type review_entity_type, description text, photo_url text,
        rating int
    );

    update product p
       set rating = r.avg_rating
      from (
          select entity_id,
                 round(avg(rating), 2) as avg_rating
          from jsonb_to_recordset(v_review_rows) as r(
              review_id uuid, client_id uuid, order_id uuid,
              review_timestamp timestamp, entity_id uuid,
              entity_type review_entity_type, description text,
              photo_url text, rating int
          )
          where entity_type = 'блюдо'
          group by entity_id
      ) r
     where p.product_id = r.entity_id;

    update restaurant t
       set rating = r.avg_rating
      from (
          select entity_id,
                 round(avg(rating), 2) as avg_rating
          from jsonb_to_recordset(v_review_rows) as r(
              review_id uuid, client_id uuid, order_id uuid,
              review_timestamp timestamp, entity_id uuid,
              entity_type review_entity_type, description text,
              photo_url text, rating int
          )
          where entity_type = 'ресторан'
          group by entity_id
      ) r
     where t.restaurant_id = r.entity_id;

    for v_k in reverse 5..0 loop

        v_month_start := (
            date_trunc('month', v_now) - v_k * interval '1 month'
        )::date;

        v_month_end := (
            v_month_start + interval '1 month'
        )::date;

        insert into courier_pay (
            year,
            month,
            courier_id,
            amount,
            coefficient_used
        )
        select extract(year from v_month_start)::int,
               extract(month from v_month_start)::int,
               c.courier_id,
               round(c.coefficient * coalesce(m.sum_comm, 0), 2),
               c.coefficient
        from courier c
        left join (
            select courier_id,
                   sum(commission) as sum_comm,
                   count(*) as cnt
            from jsonb_to_recordset(v_order_rows) as o(
                idx int, order_id uuid, client_id uuid, restaurant_id uuid,
                courier_id uuid, address_id uuid, status order_status,
                order_timestamp timestamp, delivery_timestamp timestamp,
                order_amount numeric, commission numeric, total_amount numeric,
                description text
            )
            where status = 'доставлен'
              and courier_id is not null
              and delivery_timestamp >= v_month_start
              and delivery_timestamp < v_month_end
            group by courier_id
        ) m on m.courier_id = c.courier_id
        where exists (
            select 1
            from jsonb_to_recordset(v_courier_rows) as generated(
                courier_id uuid
            )
            where generated.courier_id = c.courier_id
        );

        update courier c
           set coefficient = case
                          when coalesce(m.cnt, 0) <= 150 then 0.1
                          when m.cnt <= 250 then 0.2
                          when m.cnt <= 500 then 0.3
                          else 0.5
                      end
          from (
              select generated.courier_id,
                     generated.dismissal_date,
                     orders.cnt
              from jsonb_to_recordset(v_courier_rows) as generated(
                  courier_id uuid, dismissal_date date
              )
              left join (
                  select courier_id, count(*) as cnt
                  from jsonb_to_recordset(v_order_rows) as o(
                      idx int, order_id uuid, client_id uuid,
                      restaurant_id uuid, courier_id uuid, address_id uuid,
                      status order_status, order_timestamp timestamp,
                      delivery_timestamp timestamp, order_amount numeric,
                      commission numeric, total_amount numeric,
                      description text
                  )
                  where status = 'доставлен'
                    and courier_id is not null
                    and delivery_timestamp >= v_month_start
                    and delivery_timestamp < v_month_end
                  group by courier_id
              ) orders on orders.courier_id = generated.courier_id
          ) m
         where m.courier_id = c.courier_id
           and (
               m.dismissal_date is null
               or m.dismissal_date >= v_month_end
           );

    end loop;

    raise notice
        'insert_test_data(%): добавлено заказов - %, отзывов - %, записей courier_pay - %',
        v_n, 5 * v_n, 5 * v_n, 6 * v_n;

end;
$$;

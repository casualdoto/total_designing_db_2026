create or replace function check_order_product_restaurant () returns trigger language plpgsql as $$
declare
    v_order_restaurant uuid;
    v_product_restaurant uuid;
begin
    if tg_op = 'DELETE' then
        return old;
    end if;

    select restaurant_id
    into v_order_restaurant
    from "order"
    where order_id = new.order_id;

    select restaurant_id
    into v_product_restaurant
    from product
    where product_id = new.product_id;

    if v_order_restaurant is distinct from v_product_restaurant then
        raise exception
            'блюдо не относится к ресторану заказа';
    end if;

    return new;
end;
$$;

create constraint trigger trg_check_order_product_restaurant
after insert
or
update on order_structure deferrable initially deferred for each row
execute function check_order_product_restaurant ();

create or replace function prevent_product_restaurant_change () returns trigger language plpgsql as $$
begin
    if new.restaurant_id is distinct from old.restaurant_id
       and exists (
           select 1
           from order_structure os
           join "order" o on o.order_id = os.order_id
           where os.product_id = old.product_id
             and o.restaurant_id <> new.restaurant_id
       ) then

        raise exception
            'нельзя изменить ресторан блюда: оно уже входит в заказы другого ресторана';
    end if;

    return new;
end;
$$;

create trigger trg_prevent_product_restaurant_change before
update of restaurant_id on product for each row
execute function prevent_product_restaurant_change ();

create or replace function prevent_order_restaurant_change () returns trigger language plpgsql as $$
begin
    if new.restaurant_id is distinct from old.restaurant_id
       and exists (
           select 1
           from order_structure os
           join product p on p.product_id = os.product_id
           where os.order_id = old.order_id
             and p.restaurant_id <> new.restaurant_id
       ) then

        raise exception
            'нельзя изменить ресторан заказа: в нём есть блюда другого ресторана';
    end if;

    return new;
end;
$$;

create trigger trg_prevent_order_restaurant_change before
update of restaurant_id on "order" for each row
execute function prevent_order_restaurant_change ();

create or replace function prevent_product_price_change () returns trigger language plpgsql as $$
begin
    if new.price is distinct from old.price
       and exists (
           select 1
           from order_structure
           where product_id = old.product_id
       ) then

        raise exception
            'нельзя изменить цену блюда, если оно уже входит в заказ';
    end if;

    return new;
end;
$$;

create trigger trg_prevent_product_price_change before
update of price on product for each row
execute function prevent_product_price_change ();

create or replace function check_order_has_products () returns trigger language plpgsql as $$
declare
    v_order_id uuid;
begin
    if tg_op = 'DELETE' then
        v_order_id := old.order_id;
    else
        v_order_id := new.order_id;
    end if;

    if exists (
        select 1
        from "order"
        where order_id = v_order_id
    ) and not exists (
        select 1
        from order_structure
        where order_id = v_order_id
    ) then

        raise exception
            'заказ должен содержать хотя бы одно блюдо';
    end if;

    return null;
end;
$$;

create or replace function check_affected_orders_have_products () returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then

        perform check_order_has_products();

    elsif tg_op = 'DELETE' then

        perform check_order_has_products();

    else

        if old.order_id is distinct from new.order_id then
            if exists (
                select 1
                from "order"
                where order_id = old.order_id
            ) and not exists (
                select 1
                from order_structure
                where order_id = old.order_id
            ) then
                raise exception
                    'заказ должен содержать хотя бы одно блюдо';
            end if;
        end if;

        if exists (
            select 1
            from "order"
            where order_id = new.order_id
        ) and not exists (
            select 1
            from order_structure
            where order_id = new.order_id
        ) then
            raise exception
                'заказ должен содержать хотя бы одно блюдо';
        end if;

    end if;

    return null;
end;
$$;

create or replace function assert_order_has_products (p_order_id uuid) returns void language plpgsql as $$
begin
    if exists (
        select 1
        from "order"
        where order_id = p_order_id
    ) and not exists (
        select 1
        from order_structure
        where order_id = p_order_id
    ) then

        raise exception
            'заказ должен содержать хотя бы одно блюдо';
    end if;
end;
$$;

create or replace function check_affected_orders_have_products () returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then

        perform assert_order_has_products(new.order_id);

    elsif tg_op = 'DELETE' then

        perform assert_order_has_products(old.order_id);

    else

        perform assert_order_has_products(old.order_id);

        if new.order_id is distinct from old.order_id then
            perform assert_order_has_products(new.order_id);
        end if;

    end if;

    return null;
end;
$$;

create constraint trigger trg_order_has_products
after insert on "order" deferrable initially deferred for each row
execute function check_affected_orders_have_products ();

create constraint trigger trg_order_structure_has_products
after insert
or
update
or delete on order_structure deferrable initially deferred for each row
execute function check_affected_orders_have_products ();

create or replace function assert_order_products_amount (p_order_id uuid) returns void language plpgsql as $$
declare
    v_order_amount numeric;
    v_products_amount numeric;
begin
    select order_amount
    into v_order_amount
    from "order"
    where order_id = p_order_id;

    if not found then
        return;
    end if;

    select round(coalesce(sum(p.price * os.quantity), 0), 2)
    into v_products_amount
    from order_structure os
    join product p on p.product_id = os.product_id
    where os.order_id = p_order_id;

    if v_order_amount <> v_products_amount then
        raise exception
            'сумма заказа не соответствует сумме блюд';
    end if;
end;
$$;

create or replace function check_affected_orders_amount () returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then

        perform assert_order_products_amount(new.order_id);

    elsif tg_op = 'DELETE' then

        perform assert_order_products_amount(old.order_id);

    else

        perform assert_order_products_amount(old.order_id);

        if new.order_id is distinct from old.order_id then
            perform assert_order_products_amount(new.order_id);
        end if;

    end if;

    return null;
end;
$$;

create constraint trigger trg_check_order_products_amount
after insert
or
update on "order" deferrable initially deferred for each row
execute function check_affected_orders_amount ();

create constraint trigger trg_check_products_amount
after insert
or
update
or delete on order_structure deferrable initially deferred for each row
execute function check_affected_orders_amount ();

create or replace function prevent_order_total_change_after_payment () returns trigger language plpgsql as $$
begin
    if new.total_amount is distinct from old.total_amount
       and exists (
           select 1
           from payment
           where order_id = old.order_id
       ) then

        raise exception
            'нельзя изменить сумму заказа после создания платежа';
    end if;

    return new;
end;
$$;

create trigger trg_prevent_order_total_change before
update of total_amount on "order" for each row
execute function prevent_order_total_change_after_payment ();

create or replace function check_payment_amount () returns trigger language plpgsql as $$
declare
    v_total_amount numeric;
begin
    select total_amount
    into v_total_amount
    from "order"
    where order_id = new.order_id;

    if not found then
        raise exception 'заказ для платежа не найден';
    end if;

    if new.amount <> v_total_amount then
        raise exception
            'сумма платежа не соответствует сумме заказа';
    end if;

    return new;
end;
$$;

create trigger trg_check_payment_amount before insert
or
update on payment for each row
execute function check_payment_amount ();

create or replace function refresh_order_pay_status (p_order_id uuid) returns void language plpgsql as $$
declare
    v_pay_status order_payment_status;
begin
    if not exists (
        select 1
        from "order"
        where order_id = p_order_id
    ) then
        return;
    end if;

    if exists (
        select 1
        from payment
        where order_id = p_order_id
          and status = 'успех'
    ) then

        v_pay_status := 'оплачен';

    elsif exists (
        select 1
        from payment
        where order_id = p_order_id
    ) and not exists (
        select 1
        from payment
        where order_id = p_order_id
          and status <> 'ошибка'
    ) then

        v_pay_status := 'ошибка';

    else

        v_pay_status := 'ожидает';

    end if;

    update "order"
    set pay_status = v_pay_status
    where order_id = p_order_id;
end;
$$;

create or replace function update_order_pay_status () returns trigger language plpgsql as $$
begin
    if tg_op = 'INSERT' then

        perform refresh_order_pay_status(new.order_id);

    elsif tg_op = 'DELETE' then

        perform refresh_order_pay_status(old.order_id);

    else

        perform refresh_order_pay_status(old.order_id);

        if new.order_id is distinct from old.order_id then
            perform refresh_order_pay_status(new.order_id);
        end if;

    end if;

    return null;
end;
$$;

create trigger trg_update_order_pay_status
after insert
or
update
or delete on payment for each row
execute function update_order_pay_status ();

create or replace function check_review_eligibility () returns trigger language plpgsql as $$
declare
    v_order_client uuid;
    v_order_restaurant uuid;
begin
    select client_id, restaurant_id
    into v_order_client, v_order_restaurant
    from "order"
    where order_id = new.order_id;

    if not found then
        raise exception 'заказ для отзыва не найден';
    end if;

    if v_order_client is distinct from new.client_id then
        raise exception
            'клиент, оставляющий отзыв, не является клиентом заказа';
    end if;

    if new.entity_type = 'заказ' then

        if new.entity_id is distinct from new.order_id then
            raise exception
                'неверный идентификатор заказа для отзыва';
        end if;

    elsif new.entity_type = 'ресторан' then

        if new.entity_id is distinct from v_order_restaurant then
            raise exception
                'ресторан не входит в состав заказа';
        end if;

    elsif new.entity_type = 'блюдо' then

        if not exists (
            select 1
            from order_structure os
            join product p on p.product_id = os.product_id
            where os.order_id = new.order_id
              and os.product_id = new.entity_id
        ) then
            raise exception
                'блюдо не входило в состав заказа';
        end if;

    else

        raise exception
            'неподдерживаемый тип объекта отзыва';

    end if;

    return new;
end;
$$;

create trigger trg_check_review_eligibility before insert
or
update on review for each row
execute function check_review_eligibility ();

create or replace function prevent_removing_reviewed_product () returns trigger language plpgsql as $$
begin
    if exists (
        select 1
        from review
        where order_id = old.order_id
          and entity_id = old.product_id
          and entity_type = 'блюдо'
    ) then

        raise exception
            'нельзя удалить блюдо из заказа: на него уже оставлен отзыв';
    end if;

    return old;
end;
$$;

create or replace function prevent_removing_reviewed_product () returns trigger language plpgsql as $$
begin
    if tg_op = 'DELETE'
       or old.order_id is distinct from new.order_id
       or old.product_id is distinct from new.product_id then

        if exists (
            select 1
            from review
            where order_id = old.order_id
              and entity_id = old.product_id
              and entity_type = 'блюдо'
        ) then

            raise exception
                'нельзя удалить или перенести блюдо: на него уже оставлен отзыв';
        end if;
    end if;

    if tg_op = 'DELETE' then
        return old;
    end if;

    return new;
end;
$$;

create trigger trg_prevent_removing_reviewed_product before delete
or
update on order_structure for each row
execute function prevent_removing_reviewed_product ();
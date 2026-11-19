create or replace function rating_change () returns trigger language plpgsql as $$
begin
    if tg_op in ('UPDATE', 'DELETE') then

        if old.entity_type = 'блюдо' then

            update product
            set rating = (
                select avg(rating)
                from review
                where entity_type = 'блюдо'
                  and entity_id = old.entity_id
            )
            where product_id = old.entity_id;

        elsif old.entity_type = 'ресторан' then

            update restaurant
            set rating = (
                select avg(rating)
                from review
                where entity_type = 'ресторан'
                  and entity_id = old.entity_id
            )
            where restaurant_id = old.entity_id;

        end if;

    end if;

    if tg_op in ('INSERT', 'UPDATE') then

        if new.entity_type = 'блюдо' then

            update product
            set rating = (
                select avg(rating)
                from review
                where entity_type = 'блюдо'
                  and entity_id = new.entity_id
            )
            where product_id = new.entity_id;

        elsif new.entity_type = 'ресторан' then

            update restaurant
            set rating = (
                select avg(rating)
                from review
                where entity_type = 'ресторан'
                  and entity_id = new.entity_id
            )
            where restaurant_id = new.entity_id;

        end if;

    end if;

    return null;
end;
$$;

create trigger trg_rating_change
after insert
or
update
or delete on review for each row
execute function rating_change ();
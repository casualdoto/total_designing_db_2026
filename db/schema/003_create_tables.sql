create table client (
    client_id uuid primary key default exts.uuid_generate_v4(),
    login varchar(50) not null unique,
    password varchar(32) not null,
    phone_number varchar(12) not null unique
);

create table address (
    address_id uuid primary key default exts.uuid_generate_v4(),
    street varchar(100) not null,
    house_number varchar(10) not null,
    apartment_office varchar(10)
);

create table client_address (
    client_id uuid references client(client_id) on delete cascade,
    address_id uuid references address(address_id),

    primary key (client_id, address_id)
);

create table restaurant (
    restaurant_id uuid primary key default exts.uuid_generate_v4(),
    restaurant_name varchar(100) not null,
    address_id uuid not null references address(address_id) unique,
    description text not null,
    work_start time not null,
    work_end time not null,
    company_details text not null,
    rating numeric(3,2),
    status restaurant_status not null,

    constraint check_rating_range check (rating >= 0 and rating <= 5),
    constraint check_working_hours check (work_end > work_start)
);

create table restaurant_legal_details (
    restaurant_id uuid primary key references restaurant(restaurant_id) on delete cascade,
    legal_name varchar(150) not null,
    inn varchar(12) not null,
    ogrn varchar(15) not null,
    settlement_account varchar(20) not null
);

create table courier (
    courier_id uuid primary key default exts.uuid_generate_v4(),
    FIO varchar(150) not null,
    phone_number varchar(12) not null,
    status courier_status not null,
    hire_date date not null,
    dismissal_date date,
    coefficient numeric(2,1) not null default 0.1,

    constraint check_courier_status check (status != 'уволен' or dismissal_date is not null),
    check (coefficient >= 0.1 and coefficient <= 0.5)
);

create table courier_name (
    courier_id uuid primary key references courier(courier_id) on delete cascade,
    last_name varchar(49) not null,
    first_name varchar(49) not null,
    middle_name varchar(49)
);

create table courier_pay (
    year integer not null,
    month integer not null,
    courier_id uuid not null references courier(courier_id),
    amount numeric(12,2) not null,
    coefficient_used numeric(2,1) not null,

    primary key (year, month, courier_id),

    check (year > 0),
    check (month between 1 and 12),
    check (amount >= 0),
    check (coefficient_used >= 0.1 and coefficient_used <= 0.5)
);

create table product_category (
    product_category_id uuid primary key default exts.uuid_generate_v4(),
    product_category_name varchar(100) not null
);

create table product (
    product_id uuid primary key default exts.uuid_generate_v4(),
    product_name varchar(100) not null,
    product_category_id uuid not null references product_category(product_category_id),
    price numeric(12,2) not null,
    restaurant_id uuid not null references restaurant(restaurant_id),
    photo_url text,
    rating numeric(3,2),
    status product_status not null,
    description text not null,

    check (price >= 0),
    check (rating >= 0 and rating <= 5)
);

create table "order" (
    order_id uuid primary key default exts.uuid_generate_v4(),
    courier_id uuid not null references courier(courier_id),
    client_id uuid not null references client(client_id),
    address_id uuid not null references address(address_id),
    restaurant_id uuid not null references restaurant(restaurant_id),
    order_timestamp timestamp not null default current_timestamp,
    delivery_timestamp timestamp,
    order_amount numeric(12,2) not null,
    commission numeric(12,2) not null,
    total_amount numeric(12,2) not null,
    status order_status not null,
    pay_status order_payment_status not null,
    description text not null,

    constraint check_order_amount check (order_amount >= 0),
    constraint check_commission check (
        commission = round(order_amount * 0.10, 2)
    ),
    constraint check_total_amount check (
        total_amount = order_amount + commission
    ),
    constraint check_min_order_amount check (
        total_amount >= 1000
    ),
    constraint check_delivery_timestamp check (
        delivery_timestamp is null
        or delivery_timestamp >= order_timestamp
    ),
    constraint check_delivery_time_required check (
        status != 'доставлен'
        or delivery_timestamp is not null
    ),
    constraint fk_order_client_address foreign key (client_id, address_id)
        references client_address(client_id, address_id)
);

create table payment (
    payment_id uuid primary key default exts.uuid_generate_v4(),
    order_id uuid not null references "order"(order_id),
    payment_type payment_type not null,
    amount numeric(12,2) not null,
    transaction_id uuid not null unique,
    transaction_timestamp timestamp not null default current_timestamp,
    status payment_status not null,

    check (amount > 0)
);

create unique index payment_one_success_per_order
    on payment (order_id)
    where status = 'успех';

create table review (
    review_id uuid primary key default exts.uuid_generate_v4(),
    client_id uuid not null references client(client_id),
    review_timestamp timestamp not null default current_timestamp,
    entity_id uuid not null,
    entity_type review_entity_type not null,
    order_id uuid not null references "order"(order_id),
    description text not null,
    photo_url text,
    rating numeric(3,2) not null,

    constraint check_review_rating check (
        rating >= 1 and rating <= 5
    ),

    unique (order_id, entity_id, entity_type)
);

create table order_structure (
    order_id uuid not null references "order"(order_id),
    product_id uuid not null references product(product_id),
    quantity numeric(10,3) not null,

    primary key (order_id, product_id),

    constraint check_quantity check (quantity > 0)
);
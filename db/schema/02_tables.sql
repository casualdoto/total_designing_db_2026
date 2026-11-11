CREATE TABLE khrestianovskii_food.client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(50) NOT NULL UNIQUE,
    password char(32) NOT NULL CHECK (password ~ '^[0-9a-f]{32}$'),
    phone_number varchar(11) NOT NULL UNIQUE
);

CREATE TABLE khrestianovskii_food.address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(150) NOT NULL,
    house_number varchar(20) NOT NULL,
    apartment_office varchar(20),
    UNIQUE NULLS NOT DISTINCT (street, house_number, apartment_office)
);

CREATE TABLE khrestianovskii_food.client_address (
    client_id uuid NOT NULL REFERENCES khrestianovskii_food.client(client_id),
    address_id uuid NOT NULL REFERENCES khrestianovskii_food.address(address_id),
    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE khrestianovskii_food.legal_entity (
    legal_entity_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    inn varchar(12) NOT NULL UNIQUE CHECK (inn ~ '^[0-9]{10}([0-9]{2})?$'),
    ogrn varchar(15) NOT NULL UNIQUE CHECK (ogrn ~ '^[0-9]{13}([0-9]{2})?$')
);

CREATE TABLE khrestianovskii_food.restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(100) NOT NULL,
    address_id uuid NOT NULL UNIQUE REFERENCES khrestianovskii_food.address(address_id),
    description text NOT NULL,
    work_start time NOT NULL,       
    work_end time NOT NULL,
    legal_entity_id uuid NOT NULL REFERENCES khrestianovskii_food.legal_entity(legal_entity_id),
    settlement_account varchar(20) NOT NULL CHECK (settlement_account ~ '^[0-9]{20}$'),
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status khrestianovskii_food.restaurant_status NOT NULL DEFAULT 'активен',
    CHECK (work_end > work_start)
);

CREATE TABLE khrestianovskii_food.courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    last_name varchar(50) NOT NULL,
    first_name varchar(50) NOT NULL,
    patronymic varchar(50) NOT NULL,
    phone_number varchar(11) NOT NULL,
    status khrestianovskii_food.courier_status NOT NULL DEFAULT 'свободен',
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1,
    CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date),
    CHECK (status <> 'уволен' OR dismissal_date IS NOT NULL)
);

CREATE TABLE khrestianovskii_food.courier_pay (
    year smallint NOT NULL CHECK (year BETWEEN 1 AND 9999),
    month smallint NOT NULL CHECK (month BETWEEN 1 AND 12),
    courier_id uuid NOT NULL REFERENCES khrestianovskii_food.courier(courier_id),
    amount numeric(8,2) NOT NULL CHECK (amount >= 0),
    coefficient_used numeric(2,1) NOT NULL CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);

CREATE TABLE khrestianovskii_food.product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(80) NOT NULL
);

CREATE TABLE khrestianovskii_food.product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(100) NOT NULL,
    product_category_id uuid NOT NULL REFERENCES khrestianovskii_food.product_category(product_category_id),
    price numeric(7,2) NOT NULL CHECK (price >= 0),
    restaurant_id uuid NOT NULL REFERENCES khrestianovskii_food.restaurant(restaurant_id),
    photo_url text,
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status khrestianovskii_food.product_status NOT NULL DEFAULT 'доступно',
    description text NOT NULL
);

CREATE TABLE khrestianovskii_food."order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES khrestianovskii_food.courier(courier_id),
    client_id uuid NOT NULL REFERENCES khrestianovskii_food.client(client_id),
    address_id uuid NOT NULL REFERENCES khrestianovskii_food.address(address_id),
    restaurant_id uuid NOT NULL REFERENCES khrestianovskii_food.restaurant(restaurant_id),
    order_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    status khrestianovskii_food.order_status NOT NULL DEFAULT 'создан',
    description text,
    CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp),
    CHECK ((status = 'доставлен') = (delivery_timestamp IS NOT NULL)),
    FOREIGN KEY (client_id, address_id)
        REFERENCES khrestianovskii_food.client_address(client_id, address_id)
);

CREATE TABLE khrestianovskii_food.order_structure (
    order_id uuid NOT NULL REFERENCES khrestianovskii_food."order"(order_id),
    product_id uuid NOT NULL REFERENCES khrestianovskii_food.product(product_id),
    quantity numeric(6,3) NOT NULL CHECK (quantity > 0),
    unit_price numeric(7,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE khrestianovskii_food.payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES khrestianovskii_food."order"(order_id),
    type khrestianovskii_food.payment_type NOT NULL,
    transaction_id varchar(100) NOT NULL UNIQUE,
    transaction_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    status khrestianovskii_food.payment_status NOT NULL
);
CREATE UNIQUE INDEX payment_one_success_per_order
    ON khrestianovskii_food.payment(order_id) WHERE status = 'успех';

CREATE TABLE khrestianovskii_food.review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    entity_id uuid NOT NULL,
    entity_type khrestianovskii_food.review_entity_type NOT NULL,
    order_id uuid NOT NULL,
    description text NOT NULL,
    photo_url text,
    rating numeric(2,1) NOT NULL CHECK (rating BETWEEN 1 AND 5),
    FOREIGN KEY (order_id) REFERENCES khrestianovskii_food."order"(order_id),
    UNIQUE (order_id, entity_type, entity_id)
);

-- Расчётные атрибуты доступны для чтения без повторного хранения в базовых таблицах.
CREATE VIEW khrestianovskii_food.order_totals AS
WITH amounts AS (
    SELECT order_id, round(sum(quantity * unit_price), 2)::numeric(8,2) AS order_amount
    FROM khrestianovskii_food.order_structure
    GROUP BY order_id
), payments AS (
    SELECT order_id,
           CASE WHEN bool_or(status = 'успех') THEN 'оплачен'
                WHEN bool_or(status = 'в_обработке') THEN 'ожидает'
                ELSE 'ошибка' END::khrestianovskii_food.order_pay_status AS pay_status
    FROM khrestianovskii_food.payment
    GROUP BY order_id
)
SELECT o.*,
       coalesce(a.order_amount, 0)::numeric(8,2) AS order_amount,
       round(coalesce(a.order_amount, 0) * 0.10, 2)::numeric(8,2) AS commission,
       (coalesce(a.order_amount, 0) + round(coalesce(a.order_amount, 0) * 0.10, 2))::numeric(8,2) AS total_amount,
       coalesce(p.pay_status, 'ожидает'::khrestianovskii_food.order_pay_status) AS pay_status
FROM khrestianovskii_food."order" o
LEFT JOIN amounts a USING (order_id)
LEFT JOIN payments p USING (order_id);

CREATE VIEW khrestianovskii_food.payment_details AS
SELECT p.*, o.total_amount AS amount
FROM khrestianovskii_food.payment p
JOIN khrestianovskii_food.order_totals o USING (order_id);

CREATE VIEW khrestianovskii_food.review_details AS
SELECT r.*, o.client_id
FROM khrestianovskii_food.review r
JOIN khrestianovskii_food."order" o USING (order_id);

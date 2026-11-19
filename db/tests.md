# Протокол для самопроверки

Протокол можно заполнить для самопроверки.

Преподаватель использует этот протокол при проверке работы.

**Перед сдачей обязательно проверь работу каждого сценария. При сбое работу могут вернуть на доработку без дальнейшей проверки и комментариев. Если лимит доработок исчерпан, возможен незачёт.**

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | `17.12` |
| Дата проверки | 20.11.2026 |
| Схема | `khrestianovskii_food` |
| Роль-аудитор | `inspector` |

Выполняй проверки под ролью `inspector`, если для шага не указана другая роль.

Для каждой проверки запиши фактический результат и вердикт. Укажи `OK` при успехе или `FAIL: <причина>` при ошибке.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: бэкап схемы восстановился без ошибок после подготовки `exts` с `uuid-ossp`.
Вердикт: `OK`.

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO khrestianovskii_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: `inspector`.
Вердикт: `OK`.

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `<фамилия>_food`.
Факт: `khrestianovskii_food`.
Вердикт: `OK`.

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.
Факт: `uuid-ossp`, схема `exts`.
Вердикт: `OK`.

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N штук).
Факт: `address`, `client`, `client_address`, `courier`, `courier_name`, `courier_pay`, `how_much_money`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `restaurant_legal_details`, `review` (14 + 1 представление).
Вердикт: `OK`.

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'khrestianovskii_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

Ожидается: пусто.
Факт: пусто.
Вердикт: `OK`.

### B.5. Enum-типы

```sql
SELECT t.typname, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS values
FROM pg_type t
JOIN pg_enum e ON t.oid = e.enumtypid
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'khrestianovskii_food'
GROUP BY t.typname
ORDER BY t.typname;
```

Ожидается: 8 типов со значениями из constraints.md.
Факт: имена и значения всех 8 типов совпадают с `constraints.md`.
Вердикт: `OK`.

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'khrestianovskii_food'::regnamespace
ORDER BY tbl, conname;
```

Ожидается: не менее 15 FK, все из erd.md.
Факт: 18 FK
Вердикт: `OK`.

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.
Факт: после восстановления 0 строк. После C.2 все 10 паролей — hex-строки длиной 32.
Вердикт: `OK`.

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: `OK`.

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: `OK`.

### C.3. Распределение строк (BR-11.7)

```sql
SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
ORDER BY tbl;
```

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Факт: по 10 в `client`, `courier`, `product_category`, `restaurant`, по 50 в остальных пяти таблицах.
Вердикт: `OK`.

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT count(*) AS total_addresses,
       count(*) FILTER (WHERE r.address_id IS NOT NULL) AS restaurant_addresses,
       count(*) FILTER (WHERE r.address_id IS NULL AND EXISTS (
           SELECT 1 FROM client_address ca WHERE ca.address_id = a.address_id
       )) AS client_addresses,
       count(*) FILTER (WHERE r.address_id IS NULL AND EXISTS (
           SELECT 1 FROM "order" o WHERE o.address_id = a.address_id
       )) AS order_addresses
FROM address a
LEFT JOIN restaurant r ON r.address_id = a.address_id;
```

Ожидается: 50 всего, 10 ресторанных, остальные 40 привязаны к клиентам и используются в заказах.
Факт: 50 всего, 10 ресторанных, 40 клиентских в `client_address` и в заказах.
Вердикт: `OK`.

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT 'client' AS tbl, count(*) AS empty_cnt FROM client
 WHERE login = '' OR password = '' OR phone_number = ''
UNION ALL SELECT 'address', count(*) FROM address
 WHERE street = '' OR house_number = '' OR apartment_office = ''
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
 WHERE restaurant_name = '' OR description = '' OR company_details = ''
UNION ALL SELECT 'courier', count(*) FROM courier
 WHERE phone_number = ''
UNION ALL SELECT 'product_category', count(*) FROM product_category
 WHERE product_category_name = ''
UNION ALL SELECT 'product', count(*) FROM product
 WHERE product_name = '' OR description = '' OR photo_url = ''
UNION ALL SELECT 'order', count(*) FROM "order"
 WHERE description = ''
UNION ALL SELECT 'review', count(*) FROM review
 WHERE description = '' OR photo_url = '';
```

Ожидается: 0.
Факт: 0
Вердикт: `OK`.

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT 'client' AS tbl, count(*) AS null_cnt FROM client
 WHERE client_id IS NULL OR login IS NULL OR password IS NULL OR phone_number IS NULL
UNION ALL SELECT 'address', count(*) FROM address
 WHERE address_id IS NULL OR street IS NULL OR house_number IS NULL
UNION ALL SELECT 'client_address', count(*) FROM client_address
 WHERE client_id IS NULL OR address_id IS NULL
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
 WHERE restaurant_id IS NULL OR restaurant_name IS NULL OR address_id IS NULL
    OR description IS NULL OR work_start IS NULL OR work_end IS NULL
    OR company_details IS NULL OR status IS NULL
UNION ALL SELECT 'courier', count(*) FROM courier
 WHERE courier_id IS NULL OR phone_number IS NULL OR status IS NULL
    OR hire_date IS NULL OR coefficient IS NULL
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay
 WHERE year IS NULL OR month IS NULL OR courier_id IS NULL
    OR amount IS NULL OR coefficient_used IS NULL
UNION ALL SELECT 'product_category', count(*) FROM product_category
 WHERE product_category_id IS NULL OR product_category_name IS NULL
UNION ALL SELECT 'product', count(*) FROM product
 WHERE product_id IS NULL OR product_name IS NULL OR product_category_id IS NULL
    OR price IS NULL OR restaurant_id IS NULL OR status IS NULL OR description IS NULL
UNION ALL SELECT 'order', count(*) FROM "order"
 WHERE order_id IS NULL OR courier_id IS NULL OR client_id IS NULL
    OR address_id IS NULL OR restaurant_id IS NULL OR order_timestamp IS NULL
    OR order_amount IS NULL OR commission IS NULL OR total_amount IS NULL
    OR status IS NULL OR pay_status IS NULL OR description IS NULL
UNION ALL SELECT 'payment', count(*) FROM payment
 WHERE payment_id IS NULL OR order_id IS NULL OR payment_type IS NULL OR amount IS NULL
    OR transaction_id IS NULL OR transaction_timestamp IS NULL OR status IS NULL
UNION ALL SELECT 'review', count(*) FROM review
 WHERE review_id IS NULL OR client_id IS NULL OR review_timestamp IS NULL
    OR entity_id IS NULL OR entity_type IS NULL OR order_id IS NULL
    OR description IS NULL OR rating IS NULL
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
 WHERE order_id IS NULL OR product_id IS NULL OR quantity IS NULL
ORDER BY 1;
```

Ожидается: 0.
Факт: 0
Вердикт: `OK`.

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.
Факт: 10.
Вердикт: `OK`.

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

```sql
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM "order" o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp
LIMIT 20;
```

Ожидается: `amount = expected_amount` в каждой строке.
Факт: `amount = expected_amount` в каждой строке.
Вердикт: `OK`.

### C.9. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок, данные добавляются или заменяются (по решению студента, задокументированному в constraints.md).
Факт: без ошибок, данные добавляются.
Вердикт: `OK`.

---

## D. Проверки бизнес-правил на сгенерированных данных

### D.1. Все FK валидны (нет orphans)

```sql
SELECT 'order_structure → order' AS fk, count(*) AS orphans
FROM order_structure os
LEFT JOIN "order" o ON os.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_structure → product', count(*)
FROM order_structure os
LEFT JOIN product p ON os.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'payment → order', count(*)
FROM payment pmt
LEFT JOIN "order" o ON pmt.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'review → order', count(*)
FROM review r
LEFT JOIN "order" o ON r.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'courier_pay → courier', count(*)
FROM courier_pay cp
LEFT JOIN courier c ON cp.courier_id = c.courier_id
WHERE c.courier_id IS NULL
UNION ALL
SELECT 'client_address → client', count(*)
FROM client_address ca
LEFT JOIN client c ON ca.client_id = c.client_id
WHERE c.client_id IS NULL
UNION ALL
SELECT 'client_address → address', count(*)
FROM client_address ca
LEFT JOIN address a ON ca.address_id = a.address_id
WHERE a.address_id IS NULL;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: `OK`.

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

```sql
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

```sql
SELECT order_id, count(*) AS cnt
FROM payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;
```

Ожидается: пусто.
Факт: пусто.
Вердикт: `OK`.

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: пусто.
Вердикт: `OK`.

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: пусто.
Вердикт: `OK`.

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: 0.
Вердикт: `OK`.

### D.14. Рейтинг блюд/ресторанов соответствует отзывам (BR-9.6)

```sql
-- product.rating = AVG(review.rating) по отзывам на блюдо
SELECT p.product_id, p.rating,
       (SELECT round(avg(r.rating), 2) FROM review r
        WHERE r.entity_type = 'блюдо' AND r.entity_id = p.product_id) AS expected
FROM product p
WHERE p.rating IS NOT NULL
LIMIT 20;
```

Ожидается: `rating = expected`.
Факт: `rating = expected`.
Вердикт: `OK`.

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) AS before FROM product;

DO $$
DECLARE
    v_restaurant_id uuid;
    v_category_id uuid;
BEGIN
    SELECT restaurant_id INTO STRICT v_restaurant_id FROM restaurant LIMIT 1;
    SELECT product_category_id INTO STRICT v_category_id FROM product_category LIMIT 1;

    CALL add_product(
        p_restaurant_id => v_restaurant_id,
        p_product_category_id => v_category_id,
        p_name => 'Тестовое блюдо',
        p_price => 250,
        p_rating => 4.5,
        p_status => 'доступно',
        p_description => 'Описание'
    );
END $$;

SELECT count(*) AS after FROM product;
```

Ожидается: `after = before + 1`.
Факт: 550 → 551.
Вердикт: `OK`.

### E.2. `add_product` — падает на несуществующий ресторан

```sql
CALL add_product(
    p_restaurant_id => '00000000-0000-0000-0000-000000000000',
    -- остальные аргументы
);
```

Ожидается: ошибка с внятным сообщением.
Факт: ОШИБКА: Ресторан с идентификатором 00000000-0000-0000-0000-000000000000 не существует.
Вердикт: `OK`.

### E.3. `rating_change` — пересчитывает рейтинг

```sql
-- Выбрать заказ, блюдо и клиента
SELECT p.product_id, p.rating FROM product p WHERE p.rating IS NOT NULL LIMIT 1;

-- Вставить отзыв на это блюдо
INSERT INTO review (review_id, client_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
VALUES (
    exts.uuid_generate_v4(),
    (SELECT client_id FROM client LIMIT 1),
    localtimestamp,
    <product_id>,
    'блюдо',
    (SELECT order_id FROM "order" LIMIT 1),
    'Тестовый отзыв',
    5
);

SELECT rating FROM product WHERE product_id = <product_id>;
```

Ожидается: `rating` пересчитан.
Факт: отзыв на 1 по заказу клиента с этим блюдом снизил рейтинг с 5 до 3.
Вердикт: `OK`.

### E.4. `rating_change` — удаление отзыва

```sql
-- Удалить отзыв из E.3
DELETE FROM review WHERE review_id = <review_id>;

SELECT rating FROM product WHERE product_id = <product_id>;
```

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: после удаления рейтинг вернулся с 3 к 5. После удаления последнего отзыва — `NULL`.
Вердикт: `OK`.

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: 110 строк на 110 ресторанов, колонки совпадают. `best_user` содержит логин при наличии доставленных заказов, как в FOOD-106.
Вердикт: `OK`.

### E.6. `courier_salary()`

```sql
-- До
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;

CALL courier_salary();

-- После
SELECT courier_id, coefficient FROM courier ORDER BY courier_id;
SELECT year, month, courier_id, amount, coefficient_used
FROM courier_pay
ORDER BY year DESC, month DESC, courier_id
LIMIT 20;
```

Ожидается:
- `courier.coefficient` пересчитан для работающих (по BR-10.2).
- У уволенных — не изменился.
- `courier_pay` содержит запись за текущий месяц.

Факт: коэффициенты работающих пересчитаны, уволенных оставлены прежними. За текущий месяц 110 корректных выплат.
Вердикт: `OK`.

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

Ожидается: количество не изменилось (idempotency / обновление).
Факт: количество не изменилось (110).
Вердикт: `OK`.

---

## F. Представление `how_much_money`

### F.1. Колонки

```sql
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'khrestianovskii_food'
  AND table_name = 'how_much_money'
ORDER BY ordinal_position;
```

Ожидается: `year_month` (text), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (numeric).
Факт: `year_month` (text), `sum_no_commission`, `sum_with_commission`, `commission`, `prev_commission`, `commission_diff`, `courier_pay`, `net_profit` (numeric).
Вердикт: `OK`.

### F.2. Месяцы покрыты

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Факт: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Вердикт: `OK`.

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;
```

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.
Факт: на сгенерированных данных пропусков нет. При искусственном разрыве месяц без доставок появился с нулевыми суммами.
Вердикт: `OK`.

### F.4. Корректность сумм

```sql
SELECT year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission_diff,
       courier_pay,
       net_profit
FROM how_much_money
ORDER BY year_month
LIMIT 10;
```

Ожидается:
- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.

Факт:
- `commission = sum_with_commission - sum_no_commission`.
- `commission_diff = commission - prev_commission` (NULL для первого месяца).
- `net_profit = commission - courier_pay`.
Вердикт: `OK`.

---

## G. Права `inspector`

### G.1. Права на схему

```sql
SELECT
    nspname AS schema_name,
    has_schema_privilege('inspector', nspname, 'USAGE')  AS usage,
    has_schema_privilege('inspector', nspname, 'CREATE') AS create
FROM pg_namespace
WHERE nspname = 'khrestianovskii_food';
```

Ожидается: `USAGE`, `CREATE` (полный доступ).
Факт: `USAGE`, `CREATE` (полный доступ).
Вердикт: `OK`.

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'khrestianovskii_food'
GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
Факт: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER`.
Вердикт: `OK`.

### G.3. `information_schema` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N (количество таблиц).
Факт: 15 (14 + 1 view).
Вердикт: `OK`.

### G.4. `pg_catalog` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N.
Факт: 14
Вердикт: `OK`.

### G.5. Все процедуры/функции работают под `inspector`

```sql
SET ROLE inspector;
SET search_path TO khrestianovskii_food, exts;

CALL erase_test_data();
CALL insert_test_data(10);
CALL courier_salary();
SELECT * FROM get_statistic();
SELECT * FROM how_much_money LIMIT 5;

RESET ROLE;
```

Ожидается: без `permission denied`.
Факт: без `permission denied`.
Вердикт: `OK`.

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS cnt,
       (SELECT coalesce(sum(commission), 0) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS commission_sum
FROM courier c;
```

Ожидается: два SubPlan, каждый — скан `"order"`. Время растёт линейно от числа курьеров.
Факт: 0,400 мс, два `SubPlan` по 10 сканов `"order"`.
Вердикт: `OK`.

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN "order" o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

Ожидается: один `Hash Right Join` / `Hash Left Join`, один скан `"order"`. Время меньше, чем в H.1.
Факт: 0,134 мс, один `Hash Left Join`, один скан `"order"`.
Вердикт: `OK`.

### H.3. Применить к `get_statistic`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: во внутреннем плане один скан `"order"`, без `LATERAL` и оконных функций.
Вердикт: `OK`.

---

## I. Очистка и повторная генерация

### I.1. `erase_test_data` очищает всё

```sql
CALL erase_test_data();

SELECT 'client' AS tbl, count(*) FROM client
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'address', count(*) FROM address
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'review', count(*) FROM review
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay;
```

Ожидается: все 0.
Факт: все 0.
Вердикт: `OK`.

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: без ошибок.
Вердикт: `OK`.

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50.
Факт: 50.
Вердикт: `OK`.

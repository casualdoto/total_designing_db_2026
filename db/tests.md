# Протокол для самопроверки

Заполняется по желанию. 

По данному протоколу работа будет проверяться преподавателем.

**Если на каком-то этапе функционал оказывается нерабочим, значит учащийся проигнорировал обязательное тестирование и работа может быть отправлена на доработку без проверки и комментариев или по работе может быть проставлен незачет, если лимит доработок исчерпан.**

## Окружение

Автоматические проверки ограничений FOOD-101: `db/check_business_constraints.sql`.
Проверены 2026-11-13 на PostgreSQL 15 в отдельном контейнере под ролью
`inspector`: корректный заказ, отклонение нарушений при изменениях состава,
цены, ресторана, оплаты и отзывов, граничная сумма 1000 ₽, замена оплаты
и удаление заказа. Все проверки прошли; тестовые данные откатываются.

Порядок установки на тестовой БД с готовым `exts.uuid_generate_v4()`:

```sh
psql -v ON_ERROR_STOP=1 -f db/schema/01_types.sql -f db/schema/02_tables.sql -f db/schema/03_business_constraints.sql -f db/schema/04_insert_test_data.sql -f db/schema/05_erase_test_data.sql -f db/schema/06_add_product.sql -f db/schema/grants.sql
psql -v ON_ERROR_STOP=1 -f db/check_business_constraints.sql
psql -v ON_ERROR_STOP=1 -f db/check_test_data.sql
psql -v ON_ERROR_STOP=1 -f db/check_add_product.sql
```

Проверки FOOD-102/103: `db/check_test_data.sql`. Скрипт работает в транзакции
под `inspector`, принудительно выполняет отложенные ограничения и в конце
делает ROLLBACK, сохраняя исходные данные. Генерация и очистка требуют обычного
для схемы режима DEFERRED; после ручного `SET CONSTRAINTS ALL IMMEDIATE`
перед следующим CALL нужно вернуть `SET CONSTRAINTS ALL DEFERRED`.

Вычисляемые атрибуты проверяются через `order_totals` и `payment_details`,
автор отзыва — через `review_details`. FOOD-105–110 и восстановление бэкапа
этим прогоном не проверяются.

### Результаты FOOD-104 — 2026-11-14

| Проверка | Факт | Вердикт |
|---|---|---|
| Все атрибуты и ID | Добавляется ровно одна строка, значения сохраняются, DEFAULT создаёт UUID v4 | OK |
| Необязательные поля | Фото можно не передавать или явно передать NULL; рейтинг допускает NULL | OK |
| Начальный рейтинг | Переданное 4.5 сохраняется без отзывов по согласованному уточнению FOOD-104 | OK |
| Границы | Названия 1/100 кириллических символов, цена 0 и 99999.99, рейтинги 0/5, все enum; округление numeric | OK |
| Родительские записи | Несуществующие ресторан/категория: 23503, понятное сообщение и ID | OK |
| Обязательные поля и длины | Шесть обязательных NULL: 23502; пустые имя/описание: 23514; имя 101 символ: 22001 | OK |
| Числовые ошибки | Отрицательная цена, рейтинг вне диапазона, NaN/Infinity/-Infinity: 23514; переполнение, включая округление: 22003 | OK |
| Атомарность и права | После каждой ошибки набор блюд прежний; SECURITY INVOKER и search_path проверены | OK |

Генератор FOOD-102 по-прежнему добавляет блюда напрямую и не вызывает `add_product`.
Регрессия FOOD-101–103 повторно выполнена 2026-11-14: оба существующих скрипта
прошли, включая генерацию с 1000, повторные вызовы, выплаты и очистку.

### Результаты FOOD-102/103 — 2026-11-13

| Проверка | Факт | Вердикт |
|---|---|---|
| C.1–C.4: чистая схема, `insert_test_data(10)`, распределение | По 10 клиентов, курьеров, категорий, ресторанов и юрлиц; по 50 адресов, блюд, заказов, отзывов и платежей; 40 связей адресов, 60 выплат | OK |
| C.5–C.7: строки, форматы, NULL, работающий курьер | Длины всех varchar соответствуют каталогу; граничные выражения 1/N, включая 150, проверены отдельно; ограничения выполнены | OK |
| C.8: выплаты | Шесть месяцев на каждого курьера, суммы и цепочка коэффициентов проверены независимо | OK |
| C.9: повторные вызовы | После `1`, `10` и десяти вызовов `10` — 111 клиентов, по 555 основных дочерних строк; прежние строки сохранены | OK |
| D.1–D.14: бизнес-правила | Отложенные ограничения выполнены; суммы, связность, даты, отзывы и рейтинги проверены | OK |
| I.1–I.3: очистка и повторная генерация | Все 13 таблиц пусты, повторная очистка успешна, генерация после очистки работает; OID объектов сохранены | OK |
| Неверные аргументы | NULL, 0, -1 и переполнение отклонены с SQLSTATE 22023 | OK |
| Контрольный объём | `insert_test_data(1000)`: 1000 клиентов, по 5000 заказов/платежей/отзывов, 6000 выплат | OK |
| Пороги выплат | 0, 150, 151, 250, 251, 500, 501 доставок и увольнение; выполнен настоящий блок расчёта процедуры на отдельной фикстуре | OK |

Граничная фикстура извлекает блок выплат из `pg_get_functiondef`, поскольку
при случайном распределении `5n` заказов по `n` курьерам нагрузка 501 доставка
на одного курьера практически недостижима. Ожидаемый результат рассчитывается
независимо от этого блока. Оба проверочных скрипта завершаются ROLLBACK.

| Параметр | Значение |
|---|---|
| PostgreSQL version | PostgreSQL 15.19 (Debian), отдельный Docker-контейнер |
| Дата проверки | 2026-11-13 |
| Схема | `khrestianovskii_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.

Заполняй «Факт» и «Вердикт» по каждой проверке. «Вердикт»: `OK` / `FAIL: <что именно>`.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: ___
Вердикт: ___

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO khrestianovskii_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: ___
Вердикт: ___

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `khrestianovskii_food`.
Факт: ___

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.
Факт: ___

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N штук).
Факт: ___

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'khrestianovskii_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

Ожидается: пусто.
Факт: ___

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
Факт: ___

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'khrestianovskii_food'::regnamespace
ORDER BY tbl, conname;
```

Ожидается: не менее 15 FK, все из erd.md.
Факт: ___

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.
Факт: ___

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

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

Ожидается: `client`, `courier`, `product_category`, `restaurant` — по 10;
`address`, `product`, `order`, `review`, `payment` — по 50.
Дополнительно: `legal_entity` — 10, `client_address` — 40, `courier_pay` — 60.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
-- и аналогично для других varchar-полей с NOT NULL
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM order_totals WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
-- и аналогично для других NOT NULL полей
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.8. `courier_pay` консистентен с правилами (BR-10.2)

```sql
SELECT cp.year, cp.month, cp.courier_id, cp.amount, cp.coefficient_used,
       round(coalesce((
           SELECT sum(o.commission)
           FROM order_totals o
           WHERE o.courier_id = cp.courier_id
             AND o.status = 'доставлен'
             AND extract(year  from o.order_timestamp) = cp.year
             AND extract(month from o.order_timestamp) = cp.month
       ), 0) * cp.coefficient_used, 2) AS expected_amount
FROM courier_pay cp
LIMIT 20;
```

Ожидается: `amount = expected_amount` в каждой строке.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### C.9. Повторный вызов не ломает

```sql
DO $$
BEGIN
    FOR i IN 1..10 LOOP
        CALL insert_test_data(10);
    END LOOP;
END $$;
```

Ожидается: без ошибок; каждый вызов добавляет новый набор, прежние строки сохраняются (см. constraints.md).
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

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
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM order_totals WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM order_totals WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM order_totals
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.7. Все блюда в заказе из одного ресторана (BR-7.3)

```sql
SELECT count(DISTINCT os.order_id)
FROM order_structure os
JOIN "order" o ON os.order_id = o.order_id
JOIN product p ON os.product_id = p.product_id
WHERE p.restaurant_id != o.restaurant_id;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.8. Ровно одна успешная оплата на заказ (BR-8.1)

```sql
SELECT order_id, count(*) AS cnt
FROM payment
WHERE status = 'успех'
GROUP BY order_id
HAVING count(*) != 1;
```

Ожидается: пусто.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment_details p
JOIN order_totals o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

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
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
-- После insert_test_data(1) или на другой непустой тестовой схеме.
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;
DO $$
DECLARE r uuid; c uuid; n bigint;
BEGIN
    SELECT restaurant_id INTO STRICT r FROM restaurant LIMIT 1;
    SELECT product_category_id INTO STRICT c FROM product_category LIMIT 1;
    SELECT count(*) INTO n FROM product;
    CALL add_product(p_restaurant_id => r, p_product_category_id => c,
        p_name => 'Тестовое блюдо', p_price => 250, p_rating => 4.5,
        p_status => 'доступно', p_description => 'Описание');
    IF (SELECT count(*) FROM product) <> n + 1 THEN
        RAISE EXCEPTION 'Ожидалась одна новая строка';
    END IF;
    RAISE NOTICE 'OK: добавлено одно блюдо';
END;
$$;
ROLLBACK;
```

Ожидается: `after = before + 1`.
Факт: проверено 2026-11-14 скриптом db/check_add_product.sql; атрибуты и UUID проверены отдельно.
Вердикт: OK

### E.2. `add_product` — падает на несуществующий ресторан

```sql
BEGIN;
SET LOCAL ROLE inspector;
SET LOCAL search_path = khrestianovskii_food, exts, pg_catalog;
DO $$
DECLARE c uuid; missing_id uuid := exts.uuid_generate_v4();
BEGIN
    SELECT product_category_id INTO STRICT c FROM product_category LIMIT 1;
    IF EXISTS (SELECT FROM restaurant WHERE restaurant_id = missing_id) THEN
        RAISE EXCEPTION 'Тестовый ID должен отсутствовать';
    END IF;
    BEGIN
        CALL add_product(missing_id,c,'Блюдо',250,NULL,'доступно','Описание');
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'OK: % [%]',SQLERRM,SQLSTATE;
        RETURN;
    END;
    RAISE EXCEPTION 'Ожидалась ошибка 23503';
END;
$$;
ROLLBACK;
```

Ожидается: ошибка с внятным сообщением.
Факт: проверено 2026-11-14 скриптом db/check_add_product.sql; аналогично проверена отсутствующая категория.
Вердикт: OK

### E.3. `rating_change` — пересчитывает рейтинг

```sql
-- Выбрать заказ, блюдо и клиента
SELECT p.product_id, p.rating FROM product p WHERE p.rating IS NOT NULL LIMIT 1;

-- Вставить отзыв на это блюдо
INSERT INTO review (review_id, review_timestamp, entity_id, entity_type, order_id, description, rating)
VALUES (
    exts.uuid_generate_v4(),
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
Факт: ___

### E.4. `rating_change` — удаление отзыва

```sql
-- Удалить отзыв из E.3
DELETE FROM review WHERE review_id = <review_id>;

SELECT rating FROM product WHERE product_id = <product_id>;
```

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: ___

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: ___

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

Факт: ___

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

Ожидается: количество не изменилось (idempotency / обновление).
Факт: ___

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
Факт: ___

### F.2. Месяцы покрыты

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Факт: ___

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;
```

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.
Факт: ___

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

Факт: ___

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

Ожидается: `khrestianovskii_food`, `true`, `true` (полный доступ).
Факт: ___

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'khrestianovskii_food'
GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
Факт: ___

### G.3. `information_schema` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N (количество таблиц).
Факт: ___

### G.4. `pg_catalog` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N.
Факт: ___

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
Факт: ___

---

## H. Оптимизация `get_statistic` (BR-11.8)

### H.1. `EXPLAIN ANALYZE` — паттерн «избыточные подзапросы»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       (SELECT count(*) FROM "order" o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS cnt,
       (SELECT coalesce(sum(commission), 0) FROM order_totals o WHERE o.courier_id = c.courier_id AND o.status = 'доставлен') AS commission_sum
FROM courier c;
```

Ожидается: два SubPlan, каждый — скан `"order"`. Время растёт линейно от числа курьеров.
Факт: время ___ мс, план ___

### H.2. `EXPLAIN ANALYZE` — паттерн «один JOIN»

```sql
EXPLAIN ANALYZE
SELECT c.courier_id,
       count(o.order_id) AS cnt,
       coalesce(sum(o.commission), 0) AS commission_sum
FROM courier c
LEFT JOIN order_totals o ON o.courier_id = c.courier_id AND o.status = 'доставлен'
GROUP BY c.courier_id;
```

Ожидается: один `Hash Right Join` / `Hash Left Join`, один скан `"order"`. Время меньше, чем в H.1.
Факт: время ___ мс, план ___

### H.3. Применить к `get_statistic`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: ___

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
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay
UNION ALL SELECT 'legal_entity', count(*) FROM legal_entity;
```

Ожидается: все 0.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50.
Факт: проверено 2026-11-13 скриптом db/check_test_data.sql; см. таблицу результатов выше.
Вердикт: OK


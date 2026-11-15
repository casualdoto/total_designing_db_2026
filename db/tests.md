# Протокол для самопроверки

Заполнено по фактическим проверкам восстановленной схемы 15 ноября 2026 года.

По данному протоколу работа будет проверяться преподавателем.

**Если на каком-то этапе функционал оказывается нерабочим, значит учащийся проигнорировал обязательное тестирование и работа может быть отправлена на доработку без проверки и комментариев или по работе может быть проставлен незачет, если лимит доработок исчерпан.**

## Окружение

| Параметр | Факт |
|---|---|
| Дата проверки | 2026-11-15, Europe/Moscow |
| PostgreSQL | 15.19 (Debian), временный Docker-контейнер |
| Часовой пояс сервера | Etc/UTC; даты данных рассчитываются по времени сервера |
| Схема | khrestianovskii_food |
| Пользователь | Реальный TCP-вход inspector с паролем, без административных полномочий |
| Архив | foodexpress_khrestianovskii.backup, 76096 байт, custom, без данных |
| SHA-256 архива | 65e8996b39da528f9bb8317ec42e082611c81f3e3562d0add7459ad11fbe3960 |
| Контрольный набор | insert_test_data(10), seed=0.115: 50 заказов, 159 позиций, 9 работающих курьеров |
| Набор H.1–H.3 | 1000 курьеров и 5000 заказов, seed=0.115; все замеры на одном наборе |

Порядок установки на тестовой БД с готовым `exts.uuid_generate_v4()`:

```sh
psql -v ON_ERROR_STOP=1 -f db/schema/01_types.sql -f db/schema/02_tables.sql -f db/schema/03_business_constraints.sql -f db/schema/04_insert_test_data.sql -f db/schema/05_erase_test_data.sql -f db/schema/06_add_product.sql -f db/schema/07_rating_change.sql -f db/schema/08_get_statistic.sql -f db/schema/09_courier_salary.sql -f db/schema/10_how_much_money.sql -f db/schema/grants.sql
psql -v ON_ERROR_STOP=1 -f db/check_business_constraints.sql
psql -v ON_ERROR_STOP=1 -f db/check_test_data.sql
psql -v ON_ERROR_STOP=1 -f db/check_add_product.sql
psql -v ON_ERROR_STOP=1 -f db/check_rating_change.sql
psql -v ON_ERROR_STOP=1 -f db/check_get_statistic.sql
psql -v ON_ERROR_STOP=1 -f db/check_courier_salary.sql
psql -v ON_ERROR_STOP=1 -f db/check_how_much_money.sql
psql -X -h 127.0.0.1 -U inspector -d foodexpress_restore -W -v ON_ERROR_STOP=1 -f db/check_inspector.sql
psql -X -U postgres -d foodexpress_restore -v ON_ERROR_STOP=1 -f db/check_grants.sql
```

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: 15.11.2026 архив foodexpress_khrestianovskii.backup восстановлен в новом PostgreSQL 15.19 через pg_restore --exit-on-error --single-transaction --no-owner --no-acl; ошибок нет. exts подготовлена отдельно, все бизнес-таблицы после restore пусты.
Вердикт: OK

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO khrestianovskii_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: current_user и session_user = inspector; дополнительно подтверждён настоящий TCP-вход с паролем, без SUPERUSER/CREATEDB/CREATEROLE (db/check_inspector.sql).
Вердикт: OK

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `khrestianovskii_food`.
Факт: Возвращена одна схема khrestianovskii_food.
Вердикт: OK

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.
Факт: Расширение uuid-ossp версии 1.1 установлено в схеме exts; exts.uuid_generate_v4() доступна inspector.
Вердикт: OK

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N штук).
Факт: Запрос вернул 17 объектов: 13 базовых таблиц, включая legal_entity, и 4 представления — order_totals, payment_details, review_details, how_much_money.
Вердикт: OK

### B.4. Все PK — `uuid`

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'khrestianovskii_food'
  AND column_name LIKE '%_id'
  AND data_type != 'uuid';
```

Ожидается: пусто.
Факт: Запрос вернул 2 строки: payment.transaction_id и payment_details.transaction_id имеют тип varchar(100). Это внешний идентификатор провайдера (BR-8.3). Отдельная проверка всех *_id в PK/FK нашла 0 не-UUID; календарные year/month составного PK courier_pay не являются ID сущностей.
Вердикт: OK

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
Факт: Найдены 8 enum: restaurant_status, product_status, courier_status, order_status, order_pay_status, payment_status, payment_type, review_entity_type; значения совпадают с constraints.md.
Вердикт: OK

### B.6. FK-ограничения

```sql
SELECT conname, conrelid::regclass AS tbl, confrelid::regclass AS ref
FROM pg_constraint
WHERE contype = 'f'
  AND connamespace = 'khrestianovskii_food'::regnamespace
ORDER BY tbl, conname;
```

Ожидается: не менее 15 FK, все из erd.md.
Факт: Найдены 16 FK, включая составной order(client_id, address_id) → client_address; ограничения и отклонение невалидных изменений подтверждены db/check_business_constraints.sql.
Вердикт: OK

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.
Факт: В контрольном наборе все 10 паролей имеют длину 32 и формат [0-9a-f]{32}; нарушений 0.
Вердикт: OK

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: После erase_test_data все 13 таблиц пусты; отложенные ограничения выполнены без ошибок.
Вердикт: OK

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: CALL insert_test_data(10) на чистой схеме завершился успешно под inspector.
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
Факт: client/courier/product_category/restaurant/legal_entity — по 10; address/product/order/review/payment — по 50; client_address — 40, courier_pay — 60, order_structure — 159 в контрольном наборе.
Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.
Факт: 10 разных ресторанных адресов, 50 адресов всего, 40 клиентских адресов; все клиентские адреса привязаны, ресторанные не используются как клиентские.
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
-- и аналогично для других varchar-полей с NOT NULL
```

Ожидается: 0.
Факт: Пустых или слишком длинных значений во всех varchar-полях не найдено; границы длины 1/N, включая 150, проверены отдельно в db/check_test_data.sql.
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM order_totals WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
-- и аналогично для других NOT NULL полей
```

Ожидается: 0.
Факт: NULL в обязательных полях не найдено; ограничения NOT NULL выполнены, допустимые NULL и согласованность рейтингов проверены db/check_test_data.sql.
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.
Факт: В контрольном наборе 9 работающих курьеров из 10; отдельный запуск с value=1 также сохраняет работающего курьера.
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
Факт: Все 60 выплат сверены с commission доставленных заказов по order_timestamp; расхождений amount/expected_amount — 0. История коэффициентов проверена db/check_test_data.sql.
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
Факт: Десять повторных вызовов по 10 завершились без ошибок; данные добавляются, прежние строки сохраняются, FK и расчёты остаются валидными (db/check_test_data.sql).
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
Факт: Каждая из 7 приведённых проверок вернула 0 сирот; генерация и принудительное выполнение отложенных ограничений прошли.
Вердикт: OK

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM order_totals WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: 0 заказов с total_amount < 1000.
Вердикт: OK

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM order_totals WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.
Факт: 0 расхождений между commission и round(order_amount * 0.10, 2).
Вердикт: OK

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM order_totals
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.
Факт: 0 расхождений общей суммы со стоимостью блюд плюс комиссия.
Вердикт: OK

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: 0 доставок раньше времени создания заказа.
Вердикт: OK

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.
Факт: 0 заказов с адресом, не привязанным к клиенту.
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
Факт: 0 заказов с блюдами другого ресторана.
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
Факт: Пустой результат: у каждого из 50 заказов ровно один успешный платёж; отсутствие оплаты также проверено отдельным автоматическим сценарием.
Вердикт: OK

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment_details p
JOIN order_totals o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.
Факт: 0 расхождений payment_details.amount и order_totals.total_amount.
Вердикт: OK

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: Пустой результат: дубликатов пар client_id/address_id нет.
Вердикт: OK

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: Пустой результат: дубликатов пар order_id/product_id нет.
Вердикт: OK

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: 0 ресторанов с work_end <= work_start.
Вердикт: OK

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: 0 увольнений раньше даты найма.
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
Факт: Приведённый SELECT вернул 13 блюд с ненулевым рейтингом; во всех строках rating = expected. Автоматический сценарий дополнительно сверил все блюда и рестораны, включая NULL без отзывов.
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
Факт: Валидный CALL добавил ровно одну строку, атрибуты сохранены, UUID v4 создан DEFAULT; проверено db/check_add_product.sql.
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
Факт: Отсутствующие ресторан и категория отклонены с SQLSTATE 23503 и ID в сообщении; частичной вставки нет (db/check_add_product.sql).
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
Факт: На согласованных заказах db/check_rating_change.sql подтвердил среднее оценок 3/4/5 = 4, UPDATE оценки/текста/фото и пересчёт обеих сущностей при переносе. SQL выше — шаблон с подстановкой валидных product_id/order_id, не буквальный запуск с заполнителями.
Вердикт: OK

### E.4. `rating_change` — удаление отзыва

```sql
-- Удалить отзыв из E.3
DELETE FROM review WHERE review_id = <review_id>;

SELECT rating FROM product WHERE product_id = <product_id>;
```

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: Удаление оценки 3 из 3/4/5 даёт 4.5; удаление последнего отзыва даёт NULL. Проверено для блюда и ресторана, включая откат (db/check_rating_change.sql).
Вердикт: OK

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: Возвращены 10 строк на 10 ресторанов; на нагрузочной фикстуре — 1000 на 1000. best_user — логин клиента; лидеры, ничьи, пустые рестораны и суммы проверены db/check_get_statistic.sql.
Вердикт: OK

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

Факт: Созданы/обновлены 10 выплат текущего месяца. Пороги 0/150/151/250/251/500/501 проверены; работающим назначен коэффициент следующего месяца (он может совпадать с прежним), уволенным не изменён (db/check_courier_salary.sql).
Вердикт: OK

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

Ожидается: количество не изменилось (idempotency / обновление).
Факт: Два повторных CALL сохранили выплаты и коэффициенты, дубликатов нет. После добавления доставки сумма обновилась с прежним coefficient_used, порог 150→151 пересчитан (db/check_courier_salary.sql).
Вердикт: OK

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
Факт: Ровно 8 колонок в ожидаемом порядке: year_month — text, остальные — numeric; формат YYYY-MM подтверждён db/check_how_much_money.sql.
Вердикт: OK

### F.2. Месяцы покрыты

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Факт: На контрольной генерации отчёт содержит 6 месяцев 2026-06…2026-11 без разрывов; границы совпадают с месяцами первого/последнего доставленного заказа по order_timestamp.
Вердикт: OK

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
SELECT year_month FROM how_much_money
WHERE sum_no_commission = 0 OR sum_no_commission IS NULL;
```

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.
Факт: В отдельной фикстуре 2023-12…2024-03 присутствуют 2024-01 и 2024-02 без доставок с нулевыми суммами заказов; переход года и високосный февраль проверены (db/check_how_much_money.sql).
Вердикт: OK

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

Факт: Все формулы и восемь колонок сверены независимо на генерации 1000. В первой строке prev_commission/commission_diff — NULL; без доставок и выплат net_profit=0, при выплатах 50 без доставок net_profit=-50 по согласованному уточнению.
Вердикт: OK

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
Факт: khrestianovskii_food: USAGE=true, CREATE=true; exts, information_schema и pg_catalog доступны.
Вердикт: OK

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'khrestianovskii_food'
GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
Факт: Все 13 таблиц имеют SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER для inspector; 4 представления доступны для SELECT. Запрос прав охватывает 17 объектов; DEFAULT PRIVILEGES отдельно проверены db/check_grants.sql.
Вердикт: OK

### G.3. `information_schema` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N (количество таблиц).
Факт: Запрос вернул 17 объектов: 13 базовых таблиц и 4 представления. Отдельно с table_type='BASE TABLE' — 13.
Вердикт: OK

### G.4. `pg_catalog` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N.
Факт: Запрос вернул 13 базовых таблиц; pg_tables не включает представления.
Вердикт: OK

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
Факт: Все вызовы прошли через реальный TCP-вход inspector с паролем, без permission denied; проверены также add_product и оба системных каталога. Все тестовые изменения отменены (db/check_inspector.sql).
Вердикт: OK

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
Факт: 2398.252 мс на 1000 курьерах и 5000 заказах. Два SubPlan: каждый выполняет Seq Scan по order с Actual Loops=1000; order_structure читается один раз. Корневой узел — Index Only Scan по courier.
Вердикт: OK

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
Факт: 14.715 мс на том же наборе. Aggregate + Hash Join, без SubPlan; order и order_structure читаются по одному разу (Actual Loops=1).
Вердикт: OK

### H.3. Применить к `get_statistic`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: Внешний EXPLAIN: Function Scan, 22.791 мс. Отдельный EXPLAIN SQL-тела: 22.800 мс; Hash Join/CTE, по одному проходу order и order_structure, без WindowAgg, LATERAL и коррелированных SubPlan; названия выбираются индексными JOIN по UUID.
Вердикт: OK

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
Факт: После очистки все 13 таблиц имеют count(*)=0; объекты схемы и их OID сохранены (db/check_test_data.sql).
Вердикт: OK

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: Повторный вызов на пустой схеме завершился без ошибок.
Вердикт: OK

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50.
Факт: После очистки CALL insert_test_data(10) снова создал 50 заказов и ожидаемые количества строк остальных таблиц; FK и отложенные проверки выполнены.
Вердикт: OK


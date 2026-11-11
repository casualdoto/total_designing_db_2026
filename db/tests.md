# Протокол для самопроверки

Заполненный протокол фактического прогона по шаблону templates/tests.md. 

## Окружение

| Параметр | Значение |
|---|---|
| PostgreSQL version | PostgreSQL 15.17 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit |
| Дата проверки | 2026-11-10 |
| Схема | `khrestianovskii_food` |
| Роль-аудитор | `inspector` |

Все проверки — под `inspector`, если не указано иное.
Пароль NetoSQL2025 задаётся только при создании новой роли inspector.
Если роль уже существует, grants.sql сохраняет её пароль и атрибуты;
для подключения используется её действующий пароль.

Для каждой проверки заполнены «Факт» и «Вердикт». «Вердикт»: `OK` / `FAIL: <что именно>`.

---

## A. Подготовка

### A.1. Восстановление бэкапа

Ожидается: без ошибок.
Факт: Архив 72511 байт восстановлен в пустую foodexpress_template, pg_restore --exit-on-error завершился с кодом 0. exts/uuid-ossp подготовлены заранее; grants.sql применён администратором.
Вердикт: OK

### A.2. Переключение на inspector

```sql
SET ROLE inspector;
SET search_path TO khrestianovskii_food, exts;
SELECT current_user;
```

Ожидается: `inspector`.
Факт: inspector
Вердикт: OK

---

## B. FOOD-101: Структура схемы

### B.1. Схема существует

```sql
SELECT schema_name FROM information_schema.schemata
WHERE schema_name LIKE '%_food';
```

Ожидается: `khrestianovskii_food`.
Факт: khrestianovskii_food. 
Вердикт: OK

### B.2. Схема `exts` с `uuid-ossp`

```sql
SELECT extname, extnamespace::regnamespace AS schema
FROM pg_extension WHERE extname = 'uuid-ossp';
```

Ожидается: `uuid-ossp`, схема `exts`.
Факт: uuid-ossp|exts
Вердикт: OK

### B.3. Все 12 исходных таблиц + N после нормализации

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food'
ORDER BY table_name;
```

Ожидается: `address`, `client`, `client_address`, `courier`, `courier_pay`, `order`, `order_structure`, `payment`, `product`, `product_category`, `restaurant`, `review` (12 + N штук).
Факт: address, client, client_address, courier, courier_pay, how_much_money, order, order_structure, payment, product, product_category, restaurant, review. 12 базовых таблиц и одно представление how_much_money; information_schema.tables включает оба вида объектов.
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
Факт: payment|transaction_id|character varying. Это внешний идентификатор провайдера по BR-8.3. Дополнительная проверка UUID идентификаторов сущностей и связей без transaction_id: нарушений 0. Исходный запрос проверяет все имена с _id, а не только PK.
Вердикт: FAIL: ожидаемая пустая выборка не получена из-за внешнего transaction_id; ошибка критерия проверки, UUID ключей подтверждены

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
Факт: 8 типов: courier_status|{свободен,занят,на_доставке,уволен}; order_pay_status|{ожидает,оплачен,ошибка}; order_status|{создан,готовится,в_доставке,доставлен,отменён}; payment_status|{успех,ошибка,в_обработке}; payment_type|{карта,наличные,безнал}; product_status|{доступно,нет_в_наличии,архив}; restaurant_status|{активен,неактивен}; review_entity_type|{блюдо,ресторан,заказ}. Значения сопоставлены с constraints.md.
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
Факт: 15 внешних ключей; все связи ERD представлены, принадлежность отзыва клиенту заказа обеспечена составным FK. Получено строк: 15.
Вердикт: OK

### B.7. Пароль — MD5

```sql
SELECT length(password) AS len, password
FROM client LIMIT 5;
```

Ожидается: `len = 32`, hex-строка.
Факт: Повторено после C.2: 5 строк, длина 32 и hex; среди всех 10 клиентов нарушений 0. До генерации выборка была пустой.
Вердикт: OK

---

## C. FOOD-102: `insert_test_data(value)`

### C.1. Чистая схема

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: CALL завершился с кодом 0; схема очищена.
Вердикт: OK

### C.2. Первый запуск

```sql
CALL insert_test_data(10);
```

Ожидается: без ошибок.
Факт: CALL insert_test_data(10) завершился с кодом 0.
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

Ожидается: 10, 10, 10, 10, 50, 50, 50, 50, 50.
Факт: address|50; client|10; courier|10; order|50; payment|50; product|50; product_category|10; restaurant|10; review|50. Распределение соответствует BR-11.7.
Вердикт: OK

### C.4. Адреса ресторанов vs клиентов (BR-11.7)

```sql
SELECT 'restaurant addresses' AS cat, count(*) FROM restaurant WHERE address_id IS NOT NULL
UNION ALL
SELECT 'total addresses', count(*) FROM address;
```

Ожидается: 10 ресторанных адресов, 50 всего → 40 клиентских.
Факт: restaurant addresses|10; total addresses|50; уникальных клиентских адресов 40.
Вердикт: OK

### C.5. Нет пустых строк (BR-11.3)

```sql
SELECT count(*) FROM client WHERE login = '' OR password = '' OR phone_number = '';
-- и аналогично для других varchar-полей с NOT NULL
```

Ожидается: 0.
Факт: 0 пустых строк у клиентов; дополнительно проверены обязательные varchar/char/text всех базовых таблиц: нарушений 0.
Вердикт: OK

### C.6. Нет NULL там, где запрещено (BR-11.3)

```sql
SELECT count(*) FROM "order" WHERE client_id IS NULL OR restaurant_id IS NULL
  OR courier_id IS NULL OR address_id IS NULL OR total_amount IS NULL;
-- и аналогично для других NOT NULL полей
```

Ожидается: 0.
Факт: 0 нарушений в запросе заказа; дополнительно все NOT NULL поля базовых таблиц проверены по каталогу: нарушений 0.
Вердикт: OK

### C.7. Минимум один активный курьер (BR-6.6)

```sql
SELECT count(*) FROM courier WHERE status != 'уволен';
```

Ожидается: `>= 1`.
Факт: 9 активных курьеров из 10.
Вердикт: OK

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
Факт: Запрос шаблона показал 20 согласованных выплат; полная проверка: всего и расхождений = 60|0. В шаблоне месяц берётся по order_timestamp; в сгенерированных заказах создание и доставка находятся в одном месяце.
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

Ожидается: без ошибок, данные добавляются или заменяются (по решению студента, задокументированному в constraints.md).
Факт: 10 дополнительных вызовов прошли без ошибок. Клиентов, заказов, выплат после первой порции и повторов: 110|550|660; данные добавляются.
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
Факт: order_structure → order|0; order_structure → product|0; payment → order|0; review → order|0; courier_pay → courier|0; client_address → client|0; client_address → address|0. Все 7 счётчиков равны 0.
Вердикт: OK

### D.2. Минимальная сумма заказа (BR-1.8)

```sql
SELECT count(*) FROM "order" WHERE total_amount < 1000;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.3. Комиссия = 10% (BR-1.4)

```sql
SELECT count(*) FROM "order" WHERE round(order_amount * 0.10, 2) != commission;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.4. `total_amount = order_amount + commission`

```sql
SELECT count(*) FROM "order"
WHERE round(order_amount + commission, 2) != total_amount;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.5. Дата доставки не раньше создания (BR-7.13)

```sql
SELECT count(*) FROM "order"
WHERE delivery_timestamp IS NOT NULL AND delivery_timestamp < order_timestamp;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.6. Адрес доставки принадлежит клиенту (BR-7.4)

```sql
SELECT count(*) FROM "order" o
LEFT JOIN client_address ca
  ON ca.client_id = o.client_id AND ca.address_id = o.address_id
WHERE ca.client_id IS NULL;
```

Ожидается: 0.
Факт: 0. 
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
Факт: 0. 
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
Факт: Исходный запрос вернул 0 строк. Дополнительный LEFT JOIN от всех заказов проверил также отсутствие успешных оплат: нарушений 0.
Вердикт: OK

### D.9. Сумма оплаты = `total_amount` заказа (BR-8.4)

```sql
SELECT count(*) FROM payment p
JOIN "order" o ON p.order_id = o.order_id
WHERE p.amount != o.total_amount;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.10. Нет дубликатов в `client_address` (BR-2.5)

```sql
SELECT client_id, address_id, count(*)
FROM client_address
GROUP BY client_id, address_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: Пустая выборка (0 строк).
Вердикт: OK

### D.11. Нет дубликатов в `order_structure` (BR-7.16)

```sql
SELECT order_id, product_id, count(*)
FROM order_structure
GROUP BY order_id, product_id
HAVING count(*) > 1;
```

Ожидается: пусто.
Факт: Пустая выборка (0 строк).
Вердикт: OK

### D.12. `work_end > work_start` (BR-4.4)

```sql
SELECT count(*) FROM restaurant WHERE work_end <= work_start;
```

Ожидается: 0.
Факт: 0. 
Вердикт: OK

### D.13. `dismissal_date >= hire_date` (BR-6.3)

```sql
SELECT count(*) FROM courier
WHERE dismissal_date IS NOT NULL AND dismissal_date < hire_date;
```

Ожидается: 0.
Факт: 0. 
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
Факт: 20 показанных рейтингов блюд совпали со средним. Полная проверка блюд и ресторанов, включая NULL без отзывов: расхождения 0|0.
Вердикт: OK

---

## E. Функции и процедуры

### E.1. `add_product` — успешный вызов

```sql
SELECT count(*) AS before FROM product;
DO $$
DECLARE v_restaurant_id uuid; v_category_id uuid;
BEGIN
 SELECT restaurant_id INTO v_restaurant_id FROM restaurant LIMIT 1;
 SELECT product_category_id INTO v_category_id FROM product_category LIMIT 1;
 CALL add_product(p_restaurant_id=>v_restaurant_id,p_product_category_id=>v_category_id,
  p_name=>'Тестовое блюдо',p_price=>250,p_rating=>4.5,p_status=>'доступно',p_description=>'Описание',p_photo_url=>NULL);
END $$;
SELECT count(*) AS after FROM product;
```

Ожидается: `after = before + 1`.
Факт: До 550, после 551. Прирост 1. Вариант CALL с подзапросами из шаблона заменён на SELECT INTO и CALL внутри DO: PostgreSQL не допускает подзапрос непосредственно в аргументе CALL.
Вердикт: OK

### E.2. `add_product` — падает на несуществующий ресторан

```sql
DO $$
DECLARE v_category_id uuid;
BEGIN
 SELECT product_category_id INTO v_category_id FROM product_category LIMIT 1;
 CALL add_product(p_restaurant_id=>'00000000-0000-0000-0000-000000000000'::uuid,
  p_product_category_id=>v_category_id,p_name=>'Ошибка ресторана',p_price=>250,
  p_rating=>NULL,p_status=>'доступно',p_description=>'Отрицательная проверка',p_photo_url=>NULL);
END $$;
```

Ожидается: ошибка с внятным сообщением.
Факт: psql завершился с ожидаемым кодом 3; сообщение: «Блюдо не добавлено: проверьте идентификаторы ресторана и категории». Остальные аргументы-заглушки заполнены корректными значениями.
Вердикт: OK

### E.3. `rating_change` — пересчитывает рейтинг

```sql
INSERT INTO review(review_id,client_id,review_timestamp,entity_id,entity_type,order_id,description,rating)
VALUES ('591a4fe9-580e-47da-bc6d-47e9338efb38'::uuid,'a32995bd-24ac-406e-a2ec-519a19d0dfe4'::uuid,localtimestamp,
 '9ff86b31-f16a-4481-bb03-279264271069'::uuid,'блюдо','015fb3e5-5bd7-42d9-aaff-ea9d5dd1818c'::uuid,'Тестовый отзыв',5);
SELECT rating FROM product WHERE product_id='9ff86b31-f16a-4481-bb03-279264271069'::uuid;
```

Ожидается: `rating` пересчитан.
Факт: Заказ, клиент и блюдо выбраны совместно через order_structure; повторного отзыва на объект в этом заказе не было. Рейтинг до 2, после и независимое среднее: 3.50|3.50. Заглушки заменены реальными UUID.
Вердикт: OK

### E.4. `rating_change` — удаление отзыва

```sql
DELETE FROM review WHERE review_id='591a4fe9-580e-47da-bc6d-47e9338efb38'::uuid;
SELECT rating FROM product WHERE product_id='9ff86b31-f16a-4481-bb03-279264271069'::uuid;
```

Ожидается: если других отзывов нет — `rating IS NULL`; иначе — пересчитан.
Факт: Удалён именно отзыв из E.3. Рейтинг после удаления 2.00, совпадает с исходным 2; другие отзывы сохранены.
Вердикт: OK

### E.5. `get_statistic()`

```sql
SELECT * FROM get_statistic();
```

Ожидается:
- Колонки: `restaurant_name`, `best_product_name`, `total_amount`, `avg_amount`, `best_user`.
- По одной строке на ресторан.
- `best_user` = `client.login` (не NULL при наличии заказов).

Факт: Получены пять контрактных колонок. Строк, разных ресторанов и нарушений полноты/total>=avg: 110|110|0. best_user содержит логин.
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

Факт: Процедура прошла. Текущих выплат, изменённых ставок уволенных и работающих со ставкой не 0.1: 110|0|0. На этом наборе доставок меньше 151, поэтому пересчитанная ставка работающих остаётся 0.1; у уволенных ставка сохранена.
Вердикт: OK

### E.7. `courier_salary()` — повторный вызов

```sql
CALL courier_salary();
SELECT count(*) FROM courier_pay
WHERE year = extract(year from current_date)
  AND month = extract(month from current_date);
```

Ожидается: количество не изменилось (idempotency / обновление).
Факт: Количество выплат за текущий месяц 110. Контрольные суммы количества, сумм и coefficient_used до/после совпали; дубликаты не появились.
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
Факт: year_month|text; sum_no_commission|numeric; sum_with_commission|numeric; commission|numeric; prev_commission|numeric; commission_diff|numeric; courier_pay|numeric; net_profit|numeric. Всего 8 колонок, типы соответствуют контракту.
Вердикт: OK

### F.2. Месяцы покрыты

```sql
SELECT * FROM how_much_money ORDER BY year_month;
```

Ожидается: месяцы от первого доставленного заказа до последнего (не пропущено ни одного).
Факт: Период и число месяцев: 2026-06|2026-11|6. Проверена непрерывность от июня до ноября 2026 года.
Вердикт: OK

### F.3. Месяцы без заказов присутствуют (BR-11.9)

```sql
BEGIN;
UPDATE "order" SET status='отменён',delivery_timestamp=NULL
WHERE status='доставлен' AND delivery_timestamp>=DATE '2026-07-01'
  AND delivery_timestamp<DATE '2026-07-01'+interval '1 month';
SELECT year_month,sum_no_commission,sum_with_commission,commission,courier_pay,net_profit
FROM how_much_money WHERE sum_no_commission=0 OR sum_no_commission IS NULL;
ROLLBACK;
```

Ожидается: если в какие-то месяцы заказов не было — они есть в результате.
Факт: На исходных данных месяцев без доставок не было. В откатываемой транзакции убраны доставки промежуточного месяца. year_month|оборот без комиссии|с комиссией|комиссия|выплаты|прибыль: 2026-07|0|0|0|627.00|-627.00. Месяц сохранился, обороты и комиссия нулевые; выплаты фактические. Изменения отменены командой ROLLBACK.
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

Факт: Показаны все 6 месяцев. Независимая сверка комиссий, LAG, разницы и прибыли: нарушений 0. У первого месяца prev_commission и commission_diff равны NULL.
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
Факт: khrestianovskii_food|t|t
Вердикт: OK

### G.2. Права на таблицы

```sql
SELECT table_name, string_agg(privilege_type, ', ') AS privs
FROM information_schema.role_table_grants
WHERE grantee = 'inspector' AND table_schema = 'khrestianovskii_food'
GROUP BY table_name;
```

Ожидается: у каждой таблицы `SELECT, INSERT, UPDATE, DELETE` (или `ALL`).
Факт: Запрос вернул права на 13 объектов: 12 таблиц и представление. Недостающих SELECT/INSERT/UPDATE/DELETE/TRUNCATE у базовых таблиц: 0.
Вердикт: OK

### G.3. `information_schema` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM information_schema.tables
WHERE table_schema = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N (количество таблиц).
Факт: 13 объектов доступны. Уточнение шаблона: information_schema.tables включает 12 таблиц и how_much_money, поэтому результат 13, а не только число базовых таблиц.
Вердикт: OK

### G.4. `pg_catalog` читается под `inspector`

```sql
SET ROLE inspector;
SELECT count(*) FROM pg_catalog.pg_tables
WHERE schemaname = 'khrestianovskii_food';
RESET ROLE;
```

Ожидается: 12 + N.
Факт: 12. 
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
Факт: Все вызовы прошли без permission denied. Пользователь, клиентов, заказов, строк статистики и месяцев: inspector|10|50|10|6. После erase_test_data создана новая порция; add_product отдельно выполнен в E.1.
Вердикт: OK

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
Факт: время 874.300 мс (включая JIT 181.652 мс); план содержит 2 SubPlan с отдельными сканами заказов для каждого курьера. Перед H.1 добавлена порция insert_test_data(1000), администратор выполнил ANALYZE; курьеров|заказов = 1010|5050.
Вердикт: OK

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
Факт: время 2.867 мс; Hash Right Join, один скан заказов, одна агрегация. В H.1 874.300 мс на том же наборе.
Вердикт: OK

### H.3. Применить к `get_statistic`

```sql
EXPLAIN ANALYZE SELECT * FROM get_statistic();
```

Ожидается: без `LATERAL`, без множественных подзапросов к одной таблице, без оконных функций там, где хватает агрегата.
Факт: Вызов функции: Function Scan, 24.736 мс. Дополнительно выполнен EXPLAIN ANALYZE тела функции из pg_proc.prosrc: 15.691 мс; сканов базовой order=1, materialized CTE delivered_orders, HashAggregate и Hash Join, без LATERAL/коррелированных SubPlan/WindowAgg. Один внешний Function Scan сам по себе не раскрывает оптимизацию.
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
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay;
```

Ожидается: все 0.
Факт: client|0; courier|0; product_category|0; restaurant|0; address|0; product|0; order|0; review|0; payment|0; order_structure|0; client_address|0; courier_pay|0. Все 12 счётчиков равны 0.
Вердикт: OK

### I.2. Повторный `erase_test_data` не падает

```sql
CALL erase_test_data();
```

Ожидается: без ошибок.
Факт: Повторный CALL erase_test_data() завершился без ошибки, код psql 0.
Вердикт: OK

### I.3. После очистки `insert_test_data` снова работает

```sql
CALL insert_test_data(10);
SELECT count(*) FROM "order";
```

Ожидается: 50.
Факт: 50 заказов после новой генерации. Все связи и объекты сохранены, повторное заполнение работает.
Вердикт: OK


## Итог прогона

Выполнены все 54 пункта A.1–I.3. Вердикт OK — 53, FAIL — 1.
B.4 выявил неточность запроса шаблона: внешний payment.transaction_id является
строкой по BR-8.3 и не должен проверяться как UUID-ключ. Идентификаторы сущностей
и связей проверены дополнительно, нарушений типов нет.

Исправлены только исполняемые примеры тестов с заглушками и подзапросами в CALL;
SQL реализации и архив не менялись. После I.3 в отдельной тестовой БД находятся
10 клиентов и 50 заказов. Рабочая БД foodexpress-manual не затрагивалась.

Завершение, пользователь, клиентов, заказов: 2026-11-10 16:50:22.267467|inspector|10|50.
SHA256 проверенного архива: B14433A09853706388A2AC421D2B0DA514BF978122A07B8C6C376E77DB0EC88C.

## Дополнительная проверка grants.sql — 2026-11-11

Проверено в отдельном контейнере foodexpress-grants-20261111, PostgreSQL 15.17,
с обязательной SCRAM-аутентификацией по TCP. Рабочая роль inspector не изменялась.

| Сценарий | Факт | Вердикт |
|---|---|---|
| Роль отсутствует | grants.sql создал inspector; TCP-вход с начальным NetoSQL2025 успешен | OK |
| Роль существует с другим паролем и CONNECTION LIMIT 7 | Повторный grants.sql сохранил пароль и все атрибуты pg_authid; это проверено сравнением снимков без вывода хеша пароля | OK |
| Подключение существующей роли после выдачи прав | TCP-вход с ранее установленным тестовым паролем успешен; права USAGE и CREATE на khrestianovskii_food подтверждены | OK |

В grants.sql больше нет ALTER ROLE с заменой пароля. Архив схемы не менялся:
роль и её пароль не входят в schema-only backup, права выдаёт отдельный grants.sql.

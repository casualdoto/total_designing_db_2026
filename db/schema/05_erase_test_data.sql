-- FOOD-103. После 04_insert_test_data.sql, перед grants.sql.
CREATE OR REPLACE PROCEDURE khrestianovskii_food.erase_test_data()
LANGUAGE plpgsql
SET search_path = pg_catalog, khrestianovskii_food
AS $$
BEGIN
    -- DELETE сохраняет объекты схемы и выполняет существующие триггеры.
    -- Отложенные проверки заказов выполняются после удаления самих заказов.
    DELETE FROM khrestianovskii_food.review;
    DELETE FROM khrestianovskii_food.payment;
    DELETE FROM khrestianovskii_food.order_structure;
    DELETE FROM khrestianovskii_food."order";
    DELETE FROM khrestianovskii_food.courier_pay;
    DELETE FROM khrestianovskii_food.client_address;
    DELETE FROM khrestianovskii_food.product;
    DELETE FROM khrestianovskii_food.restaurant;
    DELETE FROM khrestianovskii_food.client;
    DELETE FROM khrestianovskii_food.courier;
    DELETE FROM khrestianovskii_food.product_category;
    DELETE FROM khrestianovskii_food.address;
    DELETE FROM khrestianovskii_food.legal_entity;
END;
$$;

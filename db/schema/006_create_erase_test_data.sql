create or replace procedure erase_test_data () language plpgsql as $$
begin
    delete from review;
    delete from payment;
    delete from order_structure;
    delete from courier_pay;
    delete from courier_name;
    delete from "order";
    delete from client_address;
    delete from product;
    delete from product_category;
    delete from restaurant_legal_details;
    delete from courier;
    delete from restaurant;
    delete from client;
    delete from address;
end;
$$;
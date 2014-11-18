DROP FUNCTION IF EXISTS transactions.post_purchase
(
    _book_name                              national character varying(12),
    _office_id                              integer,
    _user_id                                integer,
    _login_id                               bigint,
    _value_date                             date,
    _cost_center_id                         integer,
    _reference_number                       national character varying(24),
    _statement_reference                    text,
    _cash_repository_id                     integer,
    _is_credit                              boolean,
    _party_code                             national character varying(12),
    _price_type_id                          integer,
    _shipper_id                             integer,
    _shipping_charge                        money_strict2,        
    _store_id                               integer,
    _tran_ids                               bigint[],
    _details                                transactions.stock_detail_type[],
    _attachments                            core.attachment_type[]
);

CREATE FUNCTION transactions.post_purchase
(
    _book_name                              national character varying(12),
    _office_id                              integer,
    _user_id                                integer,
    _login_id                               bigint,
    _value_date                             date,
    _cost_center_id                         integer,
    _reference_number                       national character varying(24),
    _statement_reference                    text,
    _cash_repository_id                     integer,
    _is_credit                              boolean,
    _party_code                             national character varying(12),
    _price_type_id                          integer,
    _shipper_id                             integer,
    _shipping_charge                        money_strict2,        
    _store_id                               integer,
    _tran_ids                               bigint[],
    _details                                transactions.stock_detail_type[],
    _attachments                            core.attachment_type[]
)
RETURNS bigint
AS
$$
    DECLARE _party_id                       bigint;
    DECLARE _transaction_master_id          bigint;
    DECLARE _stock_master_id                bigint;
    DECLARE _shipping_address_id            integer;
    DECLARE _grand_total                    money_strict;
    DECLARE _discount_total                 money_strict2;
    DECLARE _tax_total                      money_strict2;
    DECLARE _payable                        money_strict2;
    DECLARE _default_currency_code          national character varying(12);
    DECLARE _is_periodic                    boolean = office.is_periodic_inventory(_office_id);
    DECLARE _cost_of_goods                  money_strict;
    DECLARE _tran_counter                   integer;
    DECLARE _transaction_code               text;
BEGIN
    _party_id                               := core.get_party_id_by_party_code(_party_code);
    _default_currency_code                  := transactions.get_default_currency_code_by_office_id(_office_id);

    CREATE TEMPORARY TABLE temp_stock_details
    (
        stock_master_id                     bigint, 
        tran_type                           transaction_type, 
        store_id                            integer,
        item_code                           national character varying(12),
        item_id                             integer, 
        quantity                            integer_strict,
        unit_name                           national character varying(50),
        unit_id                             integer,
        base_quantity                       decimal,
        base_unit_id                        integer,                
        price                               money_strict,
        cost_of_goods_sold                  money_strict2 DEFAULT(0),
        discount                            money_strict2,
        tax_rate                            decimal_strict2,
        tax                                 money_strict2
    ) ON COMMIT DROP;

    INSERT INTO temp_stock_details(store_id, item_code, quantity, unit_name, price, discount, tax_rate, tax)
    SELECT store_id, item_code, quantity, unit_name, price, discount, tax_rate, tax
    FROM explode_array(_details);

    UPDATE temp_stock_details 
    SET
        tran_type                           = 'Dr',
        item_id                             = core.get_item_id_by_item_code(item_code),
        unit_id                             = core.get_unit_id_by_unit_name(unit_name),
        base_quantity                       = core.get_base_quantity_by_unit_name(unit_name, quantity),
        base_unit_id                        = core.get_base_unit_id_by_unit_name(unit_name);


    SELECT SUM(tax)                         INTO _tax_total FROM temp_stock_details;
    SELECT SUM(discount)                    INTO _discount_total FROM temp_stock_details;
    SELECT SUM(price * quantity)            INTO _grand_total FROM temp_stock_details;

    _payable                                := _grand_total - COALESCE(_discount_total, 0) + COALESCE(_tax_total, 0) + COALESCE(_shipping_charge, 0);

    CREATE TEMPORARY TABLE temp_transaction_details
    (
        transaction_master_id       BIGINT, 
        tran_type                   transaction_type, 
        account_id                  integer, 
        statement_reference         text, 
        cash_repository_id          integer, 
        currency_code               national character varying(12), 
        amount_in_currency          money_strict, 
        local_currency_code         national character varying(12), 
        er                          decimal_strict, 
        amount_in_local_currency    money_strict
    ) ON COMMIT DROP;


    IF(_is_periodic = true) THEN
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Dr', core.get_account_id_by_parameter('Purchase'), _statement_reference, _default_currency_code, _grand_total, 1, _default_currency_code, _grand_total;                         
    ELSE
        --Perpetutal Inventory Accounting System
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Dr', core.get_account_id_by_parameter('Inventory'), _statement_reference, _default_currency_code, _grand_total, 1, _default_currency_code, _grand_total;                         
    END IF;

    IF(_tax_total > 0) THEN
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Dr', core.get_account_id_by_parameter('Purchase.Tax'), _statement_reference, _default_currency_code, _tax_total, 1, _default_currency_code, _tax_total;
    END IF;


    IF(_discount_total > 0) THEN
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Cr', core.get_account_id_by_parameter('Purchase.Discount'), _statement_reference, _default_currency_code, _discount_total, 1, _default_currency_code, _discount_total;
    END IF;

    IF(_is_credit = true) THEN
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Cr', core.get_account_id_by_party_id(_party_id), _statement_reference, _default_currency_code, _payable, 1, _default_currency_code, _payable;
    ELSE
        INSERT INTO temp_transaction_details(tran_type, account_id, statement_reference, cash_repository_id, currency_code, amount_in_currency, er, local_currency_code, amount_in_local_currency)
        SELECT 'Cr', core.get_cash_account_id(), _statement_reference, _cash_repository_id, _default_currency_code, _payable, 1, _default_currency_code, _payable;
    END IF;


    _transaction_master_id  := nextval(pg_get_serial_sequence('transactions.transaction_master', 'transaction_master_id'));
    _stock_master_id        := nextval(pg_get_serial_sequence('transactions.stock_master', 'stock_master_id'));
    _tran_counter           := transactions.get_new_transaction_counter(_value_date);
    _transaction_code       := transactions.get_transaction_code(_value_date, _office_id, _user_id, _login_id);

    UPDATE temp_transaction_details     SET transaction_master_id   = _transaction_master_id;
    UPDATE temp_stock_details           SET stock_master_id         = _stock_master_id;
    
    INSERT INTO transactions.transaction_master(transaction_master_id, transaction_counter, transaction_code, book, value_date, user_id, login_id, office_id, cost_center_id, reference_number, statement_reference) 
    SELECT _transaction_master_id, _tran_counter, _transaction_code, _book_name, _value_date, _user_id, _login_id, _office_id, _cost_center_id, _reference_number, _statement_reference;


    INSERT INTO transactions.transaction_details(value_date, transaction_master_id, tran_type, account_id, statement_reference, cash_repository_id, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency)
    SELECT _value_date, transaction_master_id, tran_type, account_id, statement_reference, cash_repository_id, currency_code, amount_in_currency, local_currency_code, er, amount_in_local_currency
    FROM temp_transaction_details
    ORDER BY tran_type DESC;


    INSERT INTO transactions.stock_master(value_date, stock_master_id, transaction_master_id, party_id, price_type_id, is_credit, shipper_id, shipping_charge, store_id, cash_repository_id)
    SELECT _value_date, _stock_master_id, _transaction_master_id, _party_id, _price_type_id, _is_credit, _shipper_id, _shipping_charge, _store_id, _cash_repository_id;
            
    INSERT INTO transactions.stock_details(value_date, stock_master_id, tran_type, store_id, item_id, quantity, unit_id, base_quantity, base_unit_id, price, cost_of_goods_sold, discount, tax_rate, tax)
    SELECT _value_date, stock_master_id, tran_type, store_id, item_id, quantity, unit_id, base_quantity, base_unit_id, price, cost_of_goods_sold, discount, tax_rate, tax FROM temp_stock_details;

    IF(_tran_ids != NULL::bigint[]) THEN
        INSERT INTO transactions.stock_master_non_gl_relations(stock_master_id, non_gl_stock_master_id)
        SELECT _stock_master_id, explode_array(_tran_ids);
    END IF;

    IF(_attachments != ARRAY[NULL::core.attachment_type]) THEN
        INSERT INTO core.attachments(user_id, resource, resource_key, resource_id, original_file_name, file_extension, file_path, comment)
        SELECT _user_id, 'transactions.transaction_master', 'transaction_master_id', _transaction_master_id, original_file_name, file_extension, file_path, comment 
        FROM explode_array(_attachments);
    END IF;
    
    RETURN _transaction_master_id;


END
$$
LANGUAGE plpgsql;
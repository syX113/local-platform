TRUNCATE TABLE depot_transactions, taxes, order_items, orders, customers RESTART IDENTITY CASCADE;

INSERT INTO customers (
  customer_code,
  customer_name,
  region,
  segment,
  created_at
)
SELECT
  'CUST-' || TO_CHAR(customer_number, 'FM0000'),
  'Customer ' || customer_number,
  (ARRAY['EMEA', 'AMER', 'APAC'])[((customer_number - 1) % 3) + 1],
  (ARRAY['enterprise', 'mid-market', 'self-serve'])[((customer_number - 1) % 3) + 1],
  DATE_TRUNC('day', NOW()) - ((60 - customer_number) * INTERVAL '1 day')
FROM GENERATE_SERIES(1, 12) AS customer_number;

INSERT INTO orders (
  order_id,
  customer_id,
  status,
  sales_channel,
  source_system,
  order_created_at
)
SELECT
  'ORD-' || TO_CHAR(order_number, 'FM00000'),
  ((order_number - 1) % 12) + 1,
  (ARRAY['created', 'paid', 'shipped'])[((order_number - 1) % 3) + 1],
  (ARRAY['web', 'mobile', 'partner'])[((order_number - 1) % 3) + 1],
  'postgres_sample_seed',
  DATE_TRUNC('hour', NOW()) - (((order_number - 1) % 10) * INTERVAL '1 day') - (order_number * INTERVAL '1 hour')
FROM GENERATE_SERIES(1, 30) AS order_number;

INSERT INTO order_items (
  item_id,
  order_id,
  sku,
  product_name,
  quantity,
  unit_price
)
SELECT
  'ITEM-' || TO_CHAR(order_number, 'FM00000') || '-' || TO_CHAR(item_number, 'FM00'),
  'ORD-' || TO_CHAR(order_number, 'FM00000'),
  'SKU-' || TO_CHAR(((order_number * 7 + item_number * 3) % 250) + 100, 'FM000'),
  'Product ' || (((order_number * 7 + item_number * 3) % 50) + 1),
  ((order_number + item_number) % 3) + 1,
  ROUND(((((order_number * 13 + item_number * 17) % 700) + 150)::NUMERIC) / 10, 2)
FROM GENERATE_SERIES(1, 30) AS order_number
CROSS JOIN LATERAL GENERATE_SERIES(1, ((order_number - 1) % 3) + 1) AS item_number;

INSERT INTO taxes (
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  effective_at,
  created_at
)
SELECT
  'TAX-' || TO_CHAR(tax_number, 'FM000'),
  'Tax ' || tax_number,
  (ARRAY['EMEA', 'AMER', 'APAC', 'LATAM'])[((tax_number - 1) % 4) + 1],
  ROUND((ARRAY[0.045, 0.070, 0.0815, 0.1000, 0.1195, 0.2000])[(tax_number % 6) + 1]::NUMERIC, 4),
  DATE_TRUNC('day', NOW()) - ((90 - tax_number) * INTERVAL '1 day'),
  DATE_TRUNC('day', NOW()) - ((120 - tax_number) * INTERVAL '1 day')
FROM GENERATE_SERIES(1, 8) AS tax_number;

INSERT INTO depot_transactions (
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  transaction_at,
  source_system
)
SELECT
  'DPT-' || TO_CHAR(transaction_number, 'FM00000'),
  ((transaction_number - 1) % 12) + 1,
  (ARRAY['DEPOT-A', 'DEPOT-B', 'DEPOT-C', 'DEPOT-D'])[((transaction_number - 1) % 4) + 1],
  (ARRAY['load', 'unload', 'transfer'])[((transaction_number - 1) % 3) + 1],
  ROUND(((((transaction_number * 19 + 250) % 900) + 100)::NUMERIC) / 10, 2),
  DATE_TRUNC('minute', NOW()) - (((transaction_number - 1) % 12) * INTERVAL '1 day') - (transaction_number * 7 * INTERVAL '1 minute'),
  'postgres_sample_seed'
FROM GENERATE_SERIES(1, 18) AS transaction_number;

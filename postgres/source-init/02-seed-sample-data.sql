TRUNCATE TABLE order_items, orders, customers RESTART IDENTITY CASCADE;

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
  DATE_TRUNC('day', NOW()) - MAKE_INTERVAL(days => 60 - customer_number)
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
  DATE_TRUNC('hour', NOW()) - MAKE_INTERVAL(days => ((order_number - 1) % 10), hours => order_number)
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

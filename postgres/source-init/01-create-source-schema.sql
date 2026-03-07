CREATE TABLE IF NOT EXISTS customers (
  customer_id BIGSERIAL PRIMARY KEY,
  customer_code TEXT NOT NULL UNIQUE,
  customer_name TEXT NOT NULL,
  region TEXT NOT NULL,
  segment TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
  order_id TEXT PRIMARY KEY,
  customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
  status TEXT NOT NULL CHECK (status IN ('created', 'paid', 'shipped')),
  sales_channel TEXT NOT NULL,
  source_system TEXT NOT NULL,
  order_created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS order_items (
  item_id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  sku TEXT NOT NULL,
  product_name TEXT NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_price NUMERIC(12, 2) NOT NULL CHECK (unit_price > 0)
);

CREATE OR REPLACE VIEW raw_orders_export AS
SELECT
  o.order_id,
  c.customer_code AS customer_id,
  o.status,
  COUNT(oi.item_id)::INTEGER AS item_count,
  ROUND(SUM(oi.quantity * oi.unit_price), 2)::NUMERIC(12, 2) AS order_total,
  o.order_created_at
FROM orders AS o
JOIN customers AS c ON c.customer_id = o.customer_id
JOIN order_items AS oi ON oi.order_id = o.order_id
GROUP BY o.order_id, c.customer_code, o.status, o.order_created_at;

CREATE OR REPLACE VIEW raw_order_items_export AS
SELECT
  oi.order_id,
  oi.item_id,
  oi.sku,
  oi.quantity,
  oi.unit_price,
  ROUND(oi.quantity * oi.unit_price, 2)::NUMERIC(12, 2) AS line_total,
  o.order_created_at AS loaded_at
FROM order_items AS oi
JOIN orders AS o ON o.order_id = oi.order_id;

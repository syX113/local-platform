from __future__ import annotations

import dlt

from pipeline_support import current_load_batch, fetch_rows, run_filesystem_pipeline

ICEBERG_TABLE_NAMES = ("raw_orders", "raw_order_items", "raw_customers")


ORDERS_EXPORT_SQL = """
select
  order_id,
  customer_id,
  status,
  item_count,
  order_total,
  order_created_at,
  :load_batch as load_batch
from raw_orders_export
order by order_created_at, order_id
"""

ORDER_ITEMS_EXPORT_SQL = """
select
  order_id,
  item_id,
  sku,
  quantity,
  unit_price,
  line_total,
  loaded_at
from raw_order_items_export
order by order_id, item_id
"""

CUSTOMERS_EXPORT_SQL = """
select
  customer_id,
  customer_name,
  region,
  segment,
  order_count,
  total_order_value,
  first_order_at,
  latest_order_at,
  customer_created_at,
  :load_batch as load_batch
from raw_customers_export
order by customer_id
"""
@dlt.resource(name="raw_orders", write_disposition="replace")
def raw_orders(load_batch: str):
    yield from fetch_rows(ORDERS_EXPORT_SQL, {"load_batch": load_batch})


@dlt.resource(name="raw_order_items", write_disposition="replace")
def raw_order_items():
    yield from fetch_rows(ORDER_ITEMS_EXPORT_SQL)


@dlt.resource(name="raw_customers", write_disposition="replace")
def raw_customers(load_batch: str):
    yield from fetch_rows(CUSTOMERS_EXPORT_SQL, {"load_batch": load_batch})


def main() -> None:
    load_batch = current_load_batch()
    run_filesystem_pipeline(
        default_pipeline_name="local_platform_ingest",
        default_dataset_name="landing",
        table_names=ICEBERG_TABLE_NAMES,
        resources=[
            raw_orders(load_batch=load_batch),
            raw_order_items(),
            raw_customers(load_batch=load_batch),
        ],
    )


if __name__ == "__main__":
    main()

from __future__ import annotations

import dlt

from pipeline_support import current_load_batch, fetch_rows, run_filesystem_pipeline

ICEBERG_TABLE_NAMES = ("raw_customers",)


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


@dlt.resource(name="raw_customers", write_disposition="replace")
def raw_customers(load_batch: str):
    yield from fetch_rows(CUSTOMERS_EXPORT_SQL, {"load_batch": load_batch})


def main() -> None:
    load_batch = current_load_batch()
    run_filesystem_pipeline(
        default_pipeline_name="local_platform_customers_ingest",
        default_dataset_name="postgres",
        table_names=ICEBERG_TABLE_NAMES,
        resources=[raw_customers(load_batch=load_batch)],
    )


if __name__ == "__main__":
    main()

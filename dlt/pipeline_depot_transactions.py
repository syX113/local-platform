from __future__ import annotations

import dlt

from pipeline_support import current_load_batch, fetch_rows, run_filesystem_pipeline

ICEBERG_TABLE_NAMES = ("raw_depot_transactions",)


DEPOT_TRANSACTIONS_EXPORT_SQL = """
select
  transaction_id,
  customer_id,
  depot_code,
  transaction_type,
  amount,
  transaction_at,
  source_system,
  loaded_at,
  :load_batch as load_batch
from raw_depot_transactions_export
order by transaction_at, transaction_id
"""


@dlt.resource(name="raw_depot_transactions", write_disposition="replace")
def raw_depot_transactions(load_batch: str):
    yield from fetch_rows(DEPOT_TRANSACTIONS_EXPORT_SQL, {"load_batch": load_batch})


def main() -> None:
    load_batch = current_load_batch()
    run_filesystem_pipeline(
        default_pipeline_name="local_platform_depot_transactions_ingest",
        default_dataset_name="postgres",
        table_names=ICEBERG_TABLE_NAMES,
        resources=[raw_depot_transactions(load_batch=load_batch)],
    )


if __name__ == "__main__":
    main()

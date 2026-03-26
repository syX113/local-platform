from __future__ import annotations

import dlt

from pipeline_support import current_load_batch, fetch_rows, run_filesystem_pipeline

ICEBERG_TABLE_NAMES = ("raw_taxes",)


TAXES_EXPORT_SQL = """
select
  tax_code,
  tax_name,
  jurisdiction,
  rate,
  effective_at,
  loaded_at,
  :load_batch as load_batch
from raw_taxes_export
order by tax_code
"""


@dlt.resource(name="raw_taxes", write_disposition="replace")
def raw_taxes(load_batch: str):
    yield from fetch_rows(TAXES_EXPORT_SQL, {"load_batch": load_batch})


def main() -> None:
    load_batch = current_load_batch()
    run_filesystem_pipeline(
        default_pipeline_name="local_platform_taxes_ingest",
        default_dataset_name="postgres",
        table_names=ICEBERG_TABLE_NAMES,
        resources=[raw_taxes(load_batch=load_batch)],
    )


if __name__ == "__main__":
    main()

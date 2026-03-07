#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
from textwrap import dedent

from scaffold_gitlab_pipeline import create_ingestion_child_pipeline
from scaffold_support import ROOT_DIR, ensure_new_file, require_slug


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Scaffold a new PostgreSQL -> Airflow/dlt -> MinIO/Iceberg ingestion pipeline."
    )
    parser.add_argument("slug", help="Pipeline slug, for example retail_orders")
    parser.add_argument("--dag-id", help="Airflow DAG id. Defaults to <slug>_ingest")
    parser.add_argument("--namespace", help="Iceberg namespace. Defaults to the slug")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    slug = require_slug(args.slug)
    dag_id = args.dag_id or f"{slug}_ingest"
    namespace = args.namespace or slug

    dlt_script = ROOT_DIR / "dlt" / f"{slug}_pipeline.py"
    dag_file = ROOT_DIR / "airflow" / "dags" / f"{slug}_pipeline.py"
    verify_script = ROOT_DIR / "scripts" / f"verify-{slug}-ingestion-promotion.sh"
    child_pipeline = ROOT_DIR / ".gitlab" / "ci" / f"{slug}-ingestion-promotion.yml"
    sql_dir = ROOT_DIR / "dlt" / "sql" / slug
    artifact_dir = f"artifacts/{slug}-ingestion"

    ensure_new_file(
        sql_dir / "raw_orders.sql",
        dedent(
            """\
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
        ),
    )
    ensure_new_file(
        sql_dir / "raw_order_items.sql",
        dedent(
            """\
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
        ),
    )
    ensure_new_file(
        dlt_script,
        dedent(
            f"""\
            from __future__ import annotations

            from pathlib import Path

            import dlt

            from pipeline_support import current_load_batch, fetch_rows, run_filesystem_pipeline


            SQL_DIR = Path(__file__).resolve().parent / "sql" / "{slug}"
            ICEBERG_TABLE_NAMES = ("raw_orders", "raw_order_items")

            RAW_ORDERS_SQL = (SQL_DIR / "raw_orders.sql").read_text(encoding="utf-8")
            RAW_ORDER_ITEMS_SQL = (SQL_DIR / "raw_order_items.sql").read_text(encoding="utf-8")


            @dlt.resource(name="raw_orders", write_disposition="replace")
            def raw_orders(load_batch: str):
                yield from fetch_rows(RAW_ORDERS_SQL, {{"load_batch": load_batch}})


            @dlt.resource(name="raw_order_items", write_disposition="replace")
            def raw_order_items():
                yield from fetch_rows(RAW_ORDER_ITEMS_SQL)


            def main() -> None:
                run_filesystem_pipeline(
                    default_pipeline_name="{dag_id}",
                    default_dataset_name="{namespace}",
                    table_names=ICEBERG_TABLE_NAMES,
                    resources=[
                        raw_orders(load_batch=current_load_batch()),
                        raw_order_items(),
                    ],
                )


            if __name__ == "__main__":
                main()
            """
        ),
    )
    ensure_new_file(
        dag_file,
        dedent(
            f"""\
            from __future__ import annotations

            import os
            from datetime import datetime

            from airflow import DAG
            from airflow.operators.empty import EmptyOperator
            from airflow.operators.python import PythonOperator
            from airflow.providers.docker.operators.docker import DockerOperator

            from platform_support import docker_environment, seed_source_postgres


            with DAG(
                dag_id="{dag_id}",
                description="Seeds PostgreSQL sample data and writes Iceberg tables to MinIO for the {slug} ingestion flow.",
                schedule=None,
                start_date=datetime(2024, 1, 1),
                catchup=False,
                tags=["local-platform", "postgres", "dlt", "iceberg", "{slug}"],
            ) as dag:
                start = EmptyOperator(task_id="start")

                seed = PythonOperator(
                    task_id="seed_source_postgres",
                    python_callable=seed_source_postgres,
                )

                run_dlt = DockerOperator(
                    task_id="run_dlt_pipeline",
                    image=os.environ.get("DLT_RUNNER_IMAGE", "local-platform/dlt-extractor:dev"),
                    docker_url=os.environ.get("DOCKER_URL", "unix:///var/run/docker.sock"),
                    command="python /opt/platform/dlt/{slug}_pipeline.py",
                    network_mode=os.environ.get("PLATFORM_DOCKER_NETWORK", "local-platform-net"),
                    mount_tmp_dir=False,
                    auto_remove="force",
                    tty=True,
                    environment=docker_environment(
                        {{
                            "DLT_PIPELINE_NAME": "{dag_id}",
                            "ICEBERG_NAMESPACE": "{namespace}",
                        }}
                    ),
                )

                finish = EmptyOperator(task_id="finish")

                start >> seed >> run_dlt >> finish
            """
        ),
    )
    ensure_new_file(
        verify_script,
        dedent(
            f"""\
            #!/usr/bin/env bash
            set -euo pipefail

            ROOT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")/.." && pwd)"
            cd "${{ROOT_DIR}}"

            source "${{ROOT_DIR}}/scripts/common.sh"
            ensure_platform_env

            ARTIFACT_DIR="${{ROOT_DIR}}/{artifact_dir}"
            rm -rf "${{ARTIFACT_DIR}}"
            mkdir -p "${{ARTIFACT_DIR}}"

            export SNOWFLAKE_ACCOUNT=""
            export SNOWFLAKE_USER=""
            export SNOWFLAKE_PASSWORD=""
            export OPEN_CATALOG_URI=""
            export OPEN_CATALOG_NAME=""
            export OPEN_CATALOG_CLIENT_ID=""
            export OPEN_CATALOG_CLIENT_SECRET=""
            export SNOWFLAKE_LOCAL_RAW_SYNC="false"

            ./scripts/test-airflow-dag.sh "${{1:-2026-03-07}}" "{dag_id}" "/opt/airflow/dags/{slug}_pipeline.py" | tee "${{ARTIFACT_DIR}}/airflow_dag.log"

            source_counts="$(
              docker compose exec -T source-postgres-db \\
                psql -U "${{SOURCE_POSTGRES_USER}}" -d "${{SOURCE_POSTGRES_DB}}" -At -F ',' -c "
                  select
                    (select count(*) from customers),
                    (select count(*) from orders),
                    (select count(*) from order_items),
                    (select count(*) from raw_orders_export),
                    (select count(*) from raw_order_items_export);
                "
            )"
            printf '%s\\n' "${{source_counts}}" | tee "${{ARTIFACT_DIR}}/source_counts.csv"

            IFS=',' read -r customer_count order_count order_item_count raw_orders_count raw_order_items_count <<<"${{source_counts}}"

            [ "${{customer_count}}" = "12" ] || {{ echo "expected 12 customers, got ${{customer_count}}" >&2; exit 1; }}
            [ "${{order_count}}" = "30" ] || {{ echo "expected 30 orders, got ${{order_count}}" >&2; exit 1; }}
            [ "${{order_item_count}}" = "60" ] || {{ echo "expected 60 order items, got ${{order_item_count}}" >&2; exit 1; }}
            [ "${{raw_orders_count}}" = "30" ] || {{ echo "expected 30 raw orders export rows, got ${{raw_orders_count}}" >&2; exit 1; }}
            [ "${{raw_order_items_count}}" = "60" ] || {{ echo "expected 60 raw order item export rows, got ${{raw_order_items_count}}" >&2; exit 1; }}

            catalog_rows="$(
              docker compose exec -T airflow-metadata-db \\
                psql -U "${{AIRFLOW_METADATA_DB_USER}}" -d iceberg_catalog -At -F ',' -c "
                  select table_namespace, table_name, metadata_location
                  from iceberg_tables
                  where table_namespace = '{namespace}'
                  order by table_name;
                "
            )"
            printf '%s\\n' "${{catalog_rows}}" | tee "${{ARTIFACT_DIR}}/iceberg_catalog.csv"

            catalog_count="$(printf '%s\\n' "${{catalog_rows}}" | sed '/^$/d' | wc -l | tr -d ' ')"
            [ "${{catalog_count}}" = "2" ] || {{ echo "expected 2 Iceberg catalog entries, got ${{catalog_count}}" >&2; exit 1; }}
            printf '%s\\n' "${{catalog_rows}}" | grep -q '^{namespace},raw_order_items,' || {{ echo "missing {namespace}.raw_order_items catalog entry" >&2; exit 1; }}
            printf '%s\\n' "${{catalog_rows}}" | grep -q '^{namespace},raw_orders,' || {{ echo "missing {namespace}.raw_orders catalog entry" >&2; exit 1; }}

            docker compose run --rm --no-deps dlt-extractor python - <<'PY' | tee "${{ARTIFACT_DIR}}/minio_iceberg_summary.txt"
            from io import BytesIO
            import json

            import boto3
            import pyarrow.parquet as pq

            s3 = boto3.client(
                "s3",
                endpoint_url="http://lakehouse-object-store:9000",
                aws_access_key_id="minioadmin",
                aws_secret_access_key="minioadmin123",
                region_name="us-east-1",
            )

            response = s3.list_objects_v2(Bucket="lakehouse", Prefix="platform/{namespace}/")
            keys = [obj["Key"] for obj in response.get("Contents", [])]
            metadata_keys = sorted(key for key in keys if "/metadata/" in key and key.endswith(".metadata.json"))
            parquet_keys = sorted(key for key in keys if key.endswith(".parquet"))

            if len(metadata_keys) < 4:
                raise SystemExit(f"expected at least 4 metadata files, found {{len(metadata_keys)}}")
            if len(parquet_keys) != 2:
                raise SystemExit(f"expected 2 parquet data files, found {{len(parquet_keys)}}")

            print(f"metadata_files={{len(metadata_keys)}}")
            print(f"parquet_files={{len(parquet_keys)}}")

            row_totals = {{}}
            for key in metadata_keys:
                body = s3.get_object(Bucket="lakehouse", Key=key)["Body"].read()
                doc = json.loads(body)
                print(
                    "metadata",
                    key,
                    f"format_version={{doc.get('format-version')}}",
                    f"current_snapshot_id={{doc.get('current-snapshot-id')}}",
                )

            for key in parquet_keys:
                payload = s3.get_object(Bucket="lakehouse", Key=key)["Body"].read()
                row_count = pq.read_table(BytesIO(payload)).num_rows
                table_name = key.split("/")[2]
                row_totals[table_name] = row_totals.get(table_name, 0) + row_count

            expected = {{"raw_orders": 30, "raw_order_items": 60}}
            for table_name, expected_rows in expected.items():
                actual_rows = row_totals.get(table_name)
                if actual_rows != expected_rows:
                    raise SystemExit(f"expected {{expected_rows}} rows for {{table_name}}, found {{actual_rows}}")
                print(f"parquet_rows {{table_name}}={{actual_rows}}")

            print("ingestion_promotion=passed")
            PY

            cat > "${{ARTIFACT_DIR}}/summary.txt" <<EOF
            Ingestion promotion succeeded.
            dag.id={dag_id}
            iceberg.namespace={namespace}
            source.customers=${{customer_count}}
            source.orders=${{order_count}}
            source.order_items=${{order_item_count}}
            source.raw_orders_export=${{raw_orders_count}}
            source.raw_order_items_export=${{raw_order_items_count}}
            iceberg.catalog_entries=${{catalog_count}}
            EOF
            """
        ),
    )
    verify_script.chmod(0o755)

    create_ingestion_child_pipeline(
        slug=slug,
        child_pipeline_path=child_pipeline,
        verify_script_path=f"./scripts/{verify_script.name}",
        artifact_dir=artifact_dir,
        workflow_name=f"{slug.replace('_', ' ').title()} Ingestion Promotion",
        registry_job_name=f"promote_{slug}_ingestion_pipeline",
    )

    print(f"created airflow DAG: {dag_file.relative_to(ROOT_DIR)}")
    print(f"created dlt pipeline: {dlt_script.relative_to(ROOT_DIR)}")
    print(f"created GitLab child pipeline: {child_pipeline.relative_to(ROOT_DIR)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

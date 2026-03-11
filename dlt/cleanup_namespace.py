from __future__ import annotations

import os
from urllib.parse import urlparse

import boto3

from dlt.common.libs.pyiceberg import get_catalog


def main() -> None:
    namespace = os.environ["ICEBERG_NAMESPACE"]
    bucket_uri = os.environ["OBJECT_STORE_BUCKET"]
    parsed = urlparse(bucket_uri)
    bucket = parsed.netloc
    prefix = parsed.path.lstrip("/").rstrip("/")
    data_prefix = f"{prefix}/{namespace}/" if prefix else f"{namespace}/"

    catalog = get_catalog()
    try:
        tables = list(catalog.list_tables(namespace))
    except Exception:
        tables = []

    for table_ident in tables:
        if isinstance(table_ident, tuple):
            full_name = ".".join(table_ident)
        else:
            full_name = f"{namespace}.{table_ident}"
        try:
            catalog.drop_table(full_name)
        except Exception:
            pass

    client = boto3.client(
        "s3",
        endpoint_url=os.environ["OBJECT_STORE_ENDPOINT_URL"],
        aws_access_key_id=os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
        region_name=os.environ["OBJECT_STORE_REGION"],
    )

    deleted = 0
    continuation_token: str | None = None
    while True:
        kwargs: dict[str, str] = {"Bucket": bucket, "Prefix": data_prefix}
        if continuation_token:
            kwargs["ContinuationToken"] = continuation_token
        response = client.list_objects_v2(**kwargs)
        objects = [{"Key": item["Key"]} for item in response.get("Contents", [])]
        if objects:
            deleted += len(objects)
            client.delete_objects(Bucket=bucket, Delete={"Objects": objects})
        if not response.get("IsTruncated"):
            break
        continuation_token = response.get("NextContinuationToken")

    print(
        {
            "namespace": namespace,
            "bucket": bucket,
            "prefix": data_prefix,
            "deleted_objects": deleted,
        }
    )


if __name__ == "__main__":
    main()

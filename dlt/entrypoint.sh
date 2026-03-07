#!/usr/bin/env sh
set -eu

mkdir -p /opt/platform/.dlt

cat > /opt/platform/.dlt/secrets.toml <<EOF
[destination.filesystem]
bucket_url = "${OBJECT_STORE_BUCKET}"

[destination.filesystem.credentials]
aws_access_key_id = "${OBJECT_STORE_ACCESS_KEY_ID}"
aws_secret_access_key = "${OBJECT_STORE_SECRET_ACCESS_KEY}"
endpoint_url = "${OBJECT_STORE_ENDPOINT_URL}"
region_name = "${OBJECT_STORE_REGION}"

[destination.filesystem.kwargs]
use_ssl = ${OBJECT_STORE_USE_SSL}

[iceberg_catalog]
iceberg_catalog_name = "default"
iceberg_catalog_type = "${ICEBERG_CATALOG_TYPE}"
EOF

if [ "${ICEBERG_CATALOG_TYPE}" = "rest" ]; then
  cat >> /opt/platform/.dlt/secrets.toml <<EOF
[iceberg_catalog.iceberg_catalog_config]
uri = "${OPEN_CATALOG_URI}"
type = "rest"
warehouse = "${OPEN_CATALOG_NAME}"
credential = "${OPEN_CATALOG_CLIENT_ID}:${OPEN_CATALOG_CLIENT_SECRET}"
scope = "${OPEN_CATALOG_SCOPE}"
header.X-Iceberg-Access-Delegation = "${OPEN_CATALOG_ACCESS_DELEGATION}"
py-io-impl = "pyiceberg.io.pyarrow.PyArrowFileIO"
client.access-key-id = "${OBJECT_STORE_ACCESS_KEY_ID}"
client.secret-access-key = "${OBJECT_STORE_SECRET_ACCESS_KEY}"
client.region = "${OBJECT_STORE_REGION}"
s3.endpoint = "${OBJECT_STORE_ENDPOINT_URL}"
s3.access-key-id = "${OBJECT_STORE_ACCESS_KEY_ID}"
s3.secret-access-key = "${OBJECT_STORE_SECRET_ACCESS_KEY}"
s3.region = "${OBJECT_STORE_REGION}"
s3.force-virtual-addressing = false
EOF
else
  cat >> /opt/platform/.dlt/secrets.toml <<EOF
[iceberg_catalog.iceberg_catalog_config]
type = "sql"
uri = "${ICEBERG_SQL_URI}"
warehouse = "${OBJECT_STORE_BUCKET}"
py-io-impl = "pyiceberg.io.pyarrow.PyArrowFileIO"
client.access-key-id = "${OBJECT_STORE_ACCESS_KEY_ID}"
client.secret-access-key = "${OBJECT_STORE_SECRET_ACCESS_KEY}"
client.region = "${OBJECT_STORE_REGION}"
s3.endpoint = "${OBJECT_STORE_ENDPOINT_URL}"
s3.access-key-id = "${OBJECT_STORE_ACCESS_KEY_ID}"
s3.secret-access-key = "${OBJECT_STORE_SECRET_ACCESS_KEY}"
s3.region = "${OBJECT_STORE_REGION}"
s3.force-virtual-addressing = false
EOF
fi

python /opt/platform/dlt/init_catalog.py

exec "$@"

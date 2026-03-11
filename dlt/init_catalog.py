from __future__ import annotations

import os

from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import NamespaceAlreadyExistsError


def catalog_config() -> dict[str, str]:
    base = {
        "warehouse": os.environ["OBJECT_STORE_BUCKET"],
        "py-io-impl": "pyiceberg.io.pyarrow.PyArrowFileIO",
        "client.access-key-id": os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
        "client.secret-access-key": os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
        "client.region": os.environ["OBJECT_STORE_REGION"],
        "s3.endpoint": os.environ["OBJECT_STORE_ENDPOINT_URL"],
        "s3.access-key-id": os.environ["OBJECT_STORE_ACCESS_KEY_ID"],
        "s3.secret-access-key": os.environ["OBJECT_STORE_SECRET_ACCESS_KEY"],
        "s3.region": os.environ["OBJECT_STORE_REGION"],
        "s3.force-virtual-addressing": "false",
    }

    catalog_type = os.environ["ICEBERG_CATALOG_TYPE"]
    if catalog_type == "rest":
        base.update(
            {
                "type": "rest",
                "uri": os.environ["OPEN_CATALOG_URI"],
                "warehouse": os.environ["OPEN_CATALOG_NAME"],
                "credential": f"{os.environ['OPEN_CATALOG_CLIENT_ID']}:{os.environ['OPEN_CATALOG_CLIENT_SECRET']}",
                "scope": os.environ["OPEN_CATALOG_SCOPE"],
                "header.X-Iceberg-Access-Delegation": os.environ["OPEN_CATALOG_ACCESS_DELEGATION"],
            }
        )
    else:
        base.update(
            {
                "type": "sql",
                "uri": os.environ["ICEBERG_SQL_URI"],
            }
        )

    return base


def main() -> None:
    catalog = load_catalog(os.environ.get("ICEBERG_CATALOG_NAME", "default"), **catalog_config())
    namespace = (os.environ.get("ICEBERG_NAMESPACE", "landing"),)
    try:
        catalog.create_namespace(namespace)
    except NamespaceAlreadyExistsError:
        pass


if __name__ == "__main__":
    main()

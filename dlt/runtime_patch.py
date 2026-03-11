from __future__ import annotations

from collections.abc import Mapping
from typing import Any


def _flatten_mapping(source: Mapping[str, Any], prefix: str = "") -> dict[str, Any]:
    flattened: dict[str, Any] = {}

    for key, value in source.items():
        flat_key = f"{prefix}.{key}" if prefix else str(key)
        if isinstance(value, Mapping):
            flattened.update(_flatten_mapping(value, flat_key))
        else:
            flattened[flat_key] = value

    return flattened


def patch_pyiceberg_catalog_loading() -> None:
    import dlt.common.libs.pyiceberg as dlt_pyiceberg
    from pyiceberg.catalog.sql import SqlCatalog
    from pyiceberg.exceptions import NamespaceAlreadyExistsError
    from sqlalchemy.exc import IntegrityError

    if getattr(dlt_pyiceberg, "_local_platform_flatten_patch", False):
        return

    def _wrap(loader_name: str) -> None:
        original_loader = getattr(dlt_pyiceberg, loader_name)

        def patched_loader(*args: Any, **kwargs: Any):
            catalog = original_loader(*args, **kwargs)
            properties = getattr(catalog, "properties", None)
            if isinstance(properties, Mapping):
                catalog.properties = _flatten_mapping(properties)
            return catalog

        setattr(dlt_pyiceberg, loader_name, patched_loader)

    _wrap("_load_catalog_from_config")
    _wrap("_load_catalog_from_pyiceberg")

    original_create_namespace = SqlCatalog.create_namespace

    def patched_create_namespace(self: SqlCatalog, namespace: str | tuple[str, ...], properties: Mapping[str, Any] | None = None) -> None:
        try:
            original_create_namespace(self, namespace, properties or {})
        except NamespaceAlreadyExistsError:
            return
        except IntegrityError as exc:
            message = str(exc).lower()
            if "iceberg_namespace_properties_pkey" in message or "duplicate key value violates unique constraint" in message:
                return
            raise

    SqlCatalog.create_namespace = patched_create_namespace
    dlt_pyiceberg._local_platform_flatten_patch = True

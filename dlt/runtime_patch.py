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
    dlt_pyiceberg._local_platform_flatten_patch = True

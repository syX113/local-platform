#!/usr/bin/env python3
from __future__ import annotations

from scaffold_support import load_pipeline_registry, render_root_pipeline


def main() -> int:
    render_root_pipeline(load_pipeline_registry())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

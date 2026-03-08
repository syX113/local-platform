from __future__ import annotations

import re
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
SLUG_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")


def require_slug(slug: str) -> str:
    if not SLUG_PATTERN.match(slug):
        raise SystemExit(
            "slug must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"
        )
    return slug


def upper_identifier(slug: str) -> str:
    return slug.upper()


def ensure_new_file(path: Path, content: str) -> None:
    if path.exists():
        raise SystemExit(f"refusing to overwrite existing file: {path.relative_to(ROOT_DIR)}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")

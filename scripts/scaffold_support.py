from __future__ import annotations

import json
import re
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
PIPELINE_REGISTRY_FILE = ROOT_DIR / ".gitlab" / "ci" / "pipeline-registry.json"
RENDERED_ROOT_PIPELINE_FILE = ROOT_DIR / ".gitlab" / "ci" / "generated" / "root-pipeline.yml"
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


def load_pipeline_registry() -> list[dict[str, object]]:
    if not PIPELINE_REGISTRY_FILE.exists():
        return []

    document = json.loads(PIPELINE_REGISTRY_FILE.read_text(encoding="utf-8"))
    return document.get("jobs", [])


def save_pipeline_registry(entries: list[dict[str, object]]) -> None:
    PIPELINE_REGISTRY_FILE.parent.mkdir(parents=True, exist_ok=True)
    PIPELINE_REGISTRY_FILE.write_text(
        json.dumps({"jobs": entries}, indent=2) + "\n",
        encoding="utf-8",
    )


def render_root_pipeline(entries: list[dict[str, object]]) -> None:
    stages: list[str] = []
    for entry in entries:
        stage = str(entry["stage"])
        if stage not in stages:
            stages.append(stage)

    lines = ["stages:"]
    for stage in stages:
        lines.append(f"  - {stage}")

    for entry in entries:
        lines.extend(["", f"{entry['job_name']}:", f"  stage: {entry['stage']}"])
        needs = entry.get("needs", [])
        if needs:
            lines.append("  needs:")
            for need in needs:
                lines.append(f"    - {need}")
        lines.extend(
            [
                "  trigger:",
                "    include:",
                f"      - local: {entry['include']}",
                "    strategy: depend",
            ]
        )

    RENDERED_ROOT_PIPELINE_FILE.parent.mkdir(parents=True, exist_ok=True)
    RENDERED_ROOT_PIPELINE_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")


def register_child_pipeline(
    *,
    job_name: str,
    stage: str,
    include_path: str,
    needs: list[str] | None = None,
) -> None:
    entries = load_pipeline_registry()

    if any(entry["job_name"] == job_name for entry in entries):
        raise SystemExit(f"pipeline registry already contains job {job_name}")
    if any(entry["include"] == include_path for entry in entries):
        raise SystemExit(f"pipeline registry already contains include {include_path}")

    entries.append(
        {
            "job_name": job_name,
            "stage": stage,
            "include": include_path,
            "needs": needs or [],
        }
    )
    save_pipeline_registry(entries)
    render_root_pipeline(entries)

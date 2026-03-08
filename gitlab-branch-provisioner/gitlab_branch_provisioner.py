from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT_DIR = Path(os.environ.get("LOCAL_PLATFORM_ROOT", Path.cwd()))
STATE_DIR = Path(
    os.environ.get(
        "GITLAB_BRANCH_PROVISIONER_STATE_DIR",
        ROOT_DIR / "gitlab-branch-provisioner" / "state",
    )
)
STATE_FILE = STATE_DIR / "managed-branches.json"
BOOTSTRAP_ENV = ROOT_DIR / "gitlab-runner" / "generated" / "bootstrap.env"
PROJECTS_ENV = ROOT_DIR / "gitlab-runner" / "generated" / "projects.env"
GITLAB_URL = os.environ.get("GITLAB_URL_INTERNAL", "http://gitlab").rstrip("/")
WEBHOOK_HOST = os.environ.get("GITLAB_BRANCH_PROVISIONER_HOST", "0.0.0.0")
WEBHOOK_PORT = int(os.environ.get("GITLAB_BRANCH_PROVISIONER_PORT", "8090"))
WEBHOOK_TOKEN = os.environ.get("GITLAB_BRANCH_PROVISIONER_WEBHOOK_TOKEN", "")
ZERO_SHA = "0" * 40
STATE_LOCK = threading.Lock()


def log(message: str) -> None:
    print(message, flush=True)


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def gitlab_slug(raw: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return slug[:63] or "local"


def file_token(project_kind: str, project_slug: str, branch_name: str) -> str:
    token = re.sub(r"[^a-z0-9]+", "_", f"{project_kind}_{project_slug}_{branch_name}".lower()).strip("_")
    return token[:120] or "local"


def env_path_for(project_kind: str, project_slug: str, branch_name: str) -> Path:
    return STATE_DIR / project_kind / f"{file_token(project_kind, project_slug, branch_name)}.env"


def load_state() -> list[dict[str, str]]:
    if not STATE_FILE.exists():
        return []
    return json.loads(STATE_FILE.read_text(encoding="utf-8"))


def save_state(entries: list[dict[str, str]]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(entries, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def gitlab_api(token: str, path: str) -> Any:
    request = Request(
        f"{GITLAB_URL}/api/v4{path}",
        headers={"PRIVATE-TOKEN": token},
    )
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def wait_for_bootstrap() -> tuple[str, list[dict[str, str]]]:
    while True:
        bootstrap_env = load_env_file(BOOTSTRAP_ENV)
        projects_env = load_env_file(PROJECTS_ENV)

        token = bootstrap_env.get("GITLAB_BOOTSTRAP_PAT", "")
        if not token or not projects_env:
            log("branch provisioner waiting for GitLab bootstrap metadata")
            time.sleep(5)
            continue

        projects = [
            {
                "kind": "sdp",
                "id": projects_env.get("GITLAB_SDP_PROJECT_ID", ""),
                "path": projects_env.get("GITLAB_SDP_PROJECT_PATH", ""),
            },
            {
                "kind": "edp",
                "id": projects_env.get("GITLAB_EDP_PROJECT_ID", ""),
                "path": projects_env.get("GITLAB_EDP_PROJECT_PATH", ""),
            },
        ]

        if not all(project["id"] and project["path"] for project in projects):
            log("branch provisioner waiting for complete project metadata")
            time.sleep(5)
            continue

        try:
            gitlab_api(token, "/version")
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            log(f"branch provisioner waiting for GitLab API: {exc}")
            time.sleep(5)
            continue

        return token, projects


def branch_list(token: str, project_id: str) -> list[dict[str, Any]]:
    return gitlab_api(token, f"/projects/{project_id}/repository/branches?per_page=100")


def project_details(token: str, project_id: str) -> dict[str, Any]:
    return gitlab_api(token, f"/projects/{project_id}")


def key_for(entry: dict[str, str]) -> str:
    return f"{entry['project_kind']}::{entry['project_slug']}::{entry['branch_name']}"


def state_map() -> dict[str, dict[str, str]]:
    return {key_for(entry): entry for entry in load_state()}


def persist_state(known: dict[str, dict[str, str]]) -> None:
    save_state(sorted(known.values(), key=lambda item: (item["project_kind"], item["branch_name"])))


def run_manage(action: str, project_kind: str, project_slug: str, branch_name: str, default_branch: str) -> None:
    command = [
        "bash",
        str(ROOT_DIR / "scripts" / "manage-branch-sandbox.sh"),
        action,
        project_kind,
        project_slug,
        branch_name,
        default_branch,
    ]
    completed = subprocess.run(
        command,
        cwd=ROOT_DIR,
        check=False,
        capture_output=True,
        text=True,
        env=os.environ.copy(),
    )
    if completed.stdout:
        print(completed.stdout, end="", flush=True)
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr, flush=True)
    if completed.returncode != 0:
        raise RuntimeError(f"branch sandbox command failed: {' '.join(command)}")


def current_branch_entries(token: str, projects: list[dict[str, str]]) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    for project in projects:
        details = project_details(token, project["id"])
        default_branch = details.get("default_branch") or "main"
        project_slug = gitlab_slug(details.get("path_with_namespace", f"root/{project['path']}"))
        for branch in branch_list(token, project["id"]):
            branch_name = branch["name"]
            if branch_name == default_branch:
                continue
            entries.append(
                {
                    "project_id": project["id"],
                    "project_kind": project["kind"],
                    "project_path": project["path"],
                    "project_slug": project_slug,
                    "default_branch": default_branch,
                    "branch_name": branch_name,
                }
            )
    return entries


def ensure_entry(entry: dict[str, str]) -> None:
    env_path = env_path_for(entry["project_kind"], entry["project_slug"], entry["branch_name"])
    key = key_for(entry)

    with STATE_LOCK:
        known = state_map()
        if key in known and env_path.exists():
            return

    log(f"detected branch sandbox target {entry['project_kind']}:{entry['branch_name']} -> provision")
    run_manage(
        "provision",
        entry["project_kind"],
        entry["project_slug"],
        entry["branch_name"],
        entry["default_branch"],
    )

    with STATE_LOCK:
        known = state_map()
        known[key] = entry
        persist_state(known)


def destroy_entry(entry: dict[str, str]) -> None:
    env_path = env_path_for(entry["project_kind"], entry["project_slug"], entry["branch_name"])
    key = key_for(entry)

    with STATE_LOCK:
        known = state_map()
        if key not in known and not env_path.exists():
            return

    log(f"branch disappeared from GitLab {entry['project_kind']}:{entry['branch_name']} -> destroy")
    run_manage(
        "destroy",
        entry["project_kind"],
        entry["project_slug"],
        entry["branch_name"],
        entry["default_branch"],
    )

    with STATE_LOCK:
        known = state_map()
        known.pop(key, None)
        persist_state(known)


def reconcile_once() -> tuple[str, list[dict[str, str]]]:
    token, projects = wait_for_bootstrap()
    desired_entries = current_branch_entries(token, projects)
    current = {key_for(entry): entry for entry in desired_entries}

    with STATE_LOCK:
        known = state_map()

    for key, entry in current.items():
        env_path = env_path_for(entry["project_kind"], entry["project_slug"], entry["branch_name"])
        if key in known and env_path.exists():
            continue
        log(f"startup reconciliation provisioning {entry['project_kind']}:{entry['branch_name']}")
        run_manage(
            "provision",
            entry["project_kind"],
            entry["project_slug"],
            entry["branch_name"],
            entry["default_branch"],
        )
        known[key] = entry

    for key, entry in list(known.items()):
        if key in current:
            continue
        env_path = env_path_for(entry["project_kind"], entry["project_slug"], entry["branch_name"])
        if not env_path.exists():
            known.pop(key, None)
            continue
        log(f"startup reconciliation destroying stale sandbox {entry['project_kind']}:{entry['branch_name']}")
        run_manage(
            "destroy",
            entry["project_kind"],
            entry["project_slug"],
            entry["branch_name"],
            entry["default_branch"],
        )
        known.pop(key, None)

    with STATE_LOCK:
        persist_state(known)

    log("startup reconciliation complete")
    return token, projects


def branch_name_from_ref(ref: str) -> str:
    prefix = "refs/heads/"
    if not ref.startswith(prefix):
        return ""
    return ref[len(prefix):]


def project_lookup(projects: list[dict[str, str]], payload: dict[str, Any]) -> dict[str, str] | None:
    project = payload.get("project", {})
    payload_project_id = str(project.get("id", ""))
    payload_path = project.get("path_with_namespace", "")

    for candidate in projects:
        if payload_project_id and payload_project_id == candidate["id"]:
            details = project_details(wait_for_bootstrap()[0], candidate["id"])
            return {
                "project_id": candidate["id"],
                "project_kind": candidate["kind"],
                "project_path": candidate["path"],
                "project_slug": gitlab_slug(details.get("path_with_namespace", payload_path or f"root/{candidate['path']}")),
                "default_branch": details.get("default_branch") or "main",
            }

    payload_slug = gitlab_slug(payload_path)
    for candidate in projects:
        candidate_slug = gitlab_slug(f"root/{candidate['path']}")
        if payload_slug == candidate_slug:
            details = project_details(wait_for_bootstrap()[0], candidate["id"])
            return {
                "project_id": candidate["id"],
                "project_kind": candidate["kind"],
                "project_path": candidate["path"],
                "project_slug": gitlab_slug(details.get("path_with_namespace", payload_path or f"root/{candidate['path']}")),
                "default_branch": details.get("default_branch") or "main",
            }

    return None


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "LocalPlatformBranchProvisioner/1.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send_json(HTTPStatus.OK, {"status": "ok"})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/gitlab/webhook":
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        if WEBHOOK_TOKEN:
            provided_token = self.headers.get("X-Gitlab-Token", "")
            if provided_token != WEBHOOK_TOKEN:
                self._send_json(HTTPStatus.FORBIDDEN, {"error": "invalid webhook token"})
                return

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing payload"})
            return

        try:
            payload = json.loads(self.rfile.read(content_length))
        except json.JSONDecodeError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid json"})
            return

        try:
            self.handle_payload(payload)
        except Exception as exc:  # noqa: BLE001
            log(f"branch provisioner webhook failed: {exc}")
            self._send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})
            return

        self._send_json(HTTPStatus.OK, {"status": "accepted"})

    def handle_payload(self, payload: dict[str, Any]) -> None:
        object_kind = payload.get("object_kind", "")
        if object_kind != "push":
            log(f"ignoring unsupported webhook kind: {object_kind or '<empty>'}")
            return

        token, projects = wait_for_bootstrap()
        _ = token
        project_info = project_lookup(projects, payload)
        if not project_info:
            log("ignoring webhook for unmanaged GitLab project")
            return

        branch_name = branch_name_from_ref(payload.get("ref", ""))
        if not branch_name:
            log("ignoring webhook without branch ref")
            return

        if branch_name == project_info["default_branch"]:
            return

        entry = {
            **project_info,
            "branch_name": branch_name,
        }

        before = payload.get("before", "")
        after = payload.get("after", "")

        if after == ZERO_SHA:
            destroy_entry(entry)
            return

        # Branch creation and ordinary pushes both ensure the same stable sandbox.
        if before == ZERO_SHA:
            log(f"received branch-create webhook for {project_info['project_kind']}:{branch_name}")
        else:
            log(f"received branch-update webhook for {project_info['project_kind']}:{branch_name}")
        ensure_entry(entry)


def main() -> int:
    log("starting GitLab branch provisioner")
    reconcile_once()
    server = ThreadingHTTPServer((WEBHOOK_HOST, WEBHOOK_PORT), WebhookHandler)
    log(f"branch provisioner listening on http://{WEBHOOK_HOST}:{WEBHOOK_PORT}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

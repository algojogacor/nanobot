"""Supabase Storage sync for nanobot runtime state.

This module keeps nanobot's file-based runtime state restart-safe in
environments with ephemeral disks such as Koyeb. It backs up the instance
runtime directory (config, WhatsApp auth, legacy sessions, etc.) and, when the
workspace lives outside that runtime directory, the workspace as a separate
archive section.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

from supabase import Client, create_client


_EXCLUDED_RUNTIME_TOPLEVEL = {
    "bridge",  # rebuilt locally as needed
    "logs",
    "config.json",
}


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _enabled() -> bool:
    return bool(_env("SUPABASE_URL") and _env("SUPABASE_SERVICE_ROLE_KEY"))


def _log(message: str) -> None:
    print(f"[supabase-sync] {message}", flush=True)


def _client() -> Client:
    url = _env("SUPABASE_URL")
    key = _env("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
    return create_client(url, key)


def _bucket_name() -> str:
    return _env("SUPABASE_STORAGE_BUCKET", "nanobot-private")


def _object_path() -> str:
    return _env("SUPABASE_STATE_OBJECT", _env("SUPABASE_WORKSPACE_OBJECT", "nanobot/state.zip"))


def _config_path() -> Path:
    from nanobot.config.loader import get_config_path

    return get_config_path().expanduser()


def _runtime_dir() -> Path:
    return _config_path().parent


def _load_raw_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _resolve_workspace_from_config(config_path: Path) -> Path:
    raw = _load_raw_config(config_path)
    workspace = (
        raw.get("agents", {})
        .get("defaults", {})
        .get("workspace", "~/.nanobot/workspace")
    )
    return Path(str(workspace)).expanduser()


def _workspace_dir() -> Path:
    explicit = _env("SUPABASE_WORKSPACE_PATH")
    if explicit:
        return Path(explicit).expanduser()
    return _resolve_workspace_from_config(_config_path())


def _ensure_bucket(client: Client) -> None:
    bucket = _bucket_name()
    existing = client.storage.list_buckets()
    for item in existing:
        name = getattr(item, "name", None)
        if name is None and isinstance(item, dict):
            name = item.get("name")
        if name == bucket:
            return
    client.storage.create_bucket(bucket, options={"public": False})
    _log(f"created bucket '{bucket}'")


def _safe_remove_dir_contents(path: Path) -> None:
    if not path.exists():
        return
    for child in path.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()


def _copy_tree_contents(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)


def _is_relative_to(path: Path, base: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(base.resolve(strict=False))
        return True
    except ValueError:
        return False


def _build_metadata(runtime_dir: Path, workspace_dir: Path) -> dict[str, Any]:
    workspace_external = not _is_relative_to(workspace_dir, runtime_dir)
    return {
        "version": 1,
        "config_path": str(_config_path()),
        "runtime_dir": str(runtime_dir),
        "workspace_path": str(workspace_dir),
        "workspace_external": workspace_external,
    }


def _write_zip_tree(zf: zipfile.ZipFile, src_root: Path, zip_prefix: str, *, exclude_top: set[str] | None = None) -> None:
    if not src_root.exists():
        return
    exclude_top = exclude_top or set()
    for path in src_root.rglob("*"):
        rel = path.relative_to(src_root)
        if rel.parts and rel.parts[0] in exclude_top:
            continue
        arcname = f"{zip_prefix}/{rel.as_posix()}"
        if path.is_dir():
            continue
        zf.write(path, arcname)


def restore_state() -> int:
    if not _enabled():
        _log("skipping restore because Supabase Storage is not configured")
        return 0

    client = _client()
    _ensure_bucket(client)
    bucket = _bucket_name()
    object_path = _object_path()

    try:
        blob = client.storage.from_(bucket).download(object_path)
    except Exception as exc:  # noqa: BLE001
        _log(f"no remote backup found at '{bucket}/{object_path}': {exc}")
        return 0

    runtime_dir = _runtime_dir()
    runtime_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="nanobot-restore-") as temp_dir:
        archive_path = Path(temp_dir) / "state.zip"
        archive_path.write_bytes(blob)
        extract_dir = Path(temp_dir) / "extract"
        extract_dir.mkdir(parents=True, exist_ok=True)

        with zipfile.ZipFile(archive_path) as zf:
            zf.extractall(extract_dir)

        restored_runtime = extract_dir / "runtime"
        if restored_runtime.exists():
            _safe_remove_dir_contents(runtime_dir)
            _copy_tree_contents(restored_runtime, runtime_dir)

        metadata_path = extract_dir / "metadata.json"
        metadata = {}
        if metadata_path.exists():
            try:
                metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                metadata = {}

        workspace_external = bool(metadata.get("workspace_external"))
        restored_workspace = extract_dir / "workspace"
        if workspace_external and restored_workspace.exists():
            workspace_dir = _workspace_dir()
            workspace_dir.mkdir(parents=True, exist_ok=True)
            _safe_remove_dir_contents(workspace_dir)
            _copy_tree_contents(restored_workspace, workspace_dir)

    _log(f"restored runtime state from '{bucket}/{object_path}'")
    return 0


def backup_state() -> int:
    if not _enabled():
        _log("skipping backup because Supabase Storage is not configured")
        return 0

    runtime_dir = _runtime_dir()
    workspace_dir = _workspace_dir()
    if not runtime_dir.exists():
        _log(f"skipping backup because runtime dir does not exist: {runtime_dir}")
        return 0

    has_runtime_data = any(
        child.name not in _EXCLUDED_RUNTIME_TOPLEVEL
        for child in runtime_dir.iterdir()
    )
    has_workspace_data = workspace_dir.exists() and any(workspace_dir.iterdir())
    if not has_runtime_data and not has_workspace_data:
        _log("skipping backup because runtime and workspace are empty")
        return 0

    client = _client()
    _ensure_bucket(client)
    bucket = _bucket_name()
    object_path = _object_path()

    metadata = _build_metadata(runtime_dir, workspace_dir)

    with tempfile.TemporaryDirectory(prefix="nanobot-backup-") as temp_dir:
        archive_path = Path(temp_dir) / "state.zip"
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("metadata.json", json.dumps(metadata, ensure_ascii=False, indent=2))
            _write_zip_tree(
                zf,
                runtime_dir,
                "runtime",
                exclude_top=_EXCLUDED_RUNTIME_TOPLEVEL,
            )
            if metadata["workspace_external"] and workspace_dir.exists():
                _write_zip_tree(zf, workspace_dir, "workspace")

        with archive_path.open("rb") as handle:
            client.storage.from_(bucket).upload(
                path=object_path,
                file=handle,
                file_options={"content-type": "application/zip", "upsert": "true"},
            )

    _log(f"uploaded runtime state to '{bucket}/{object_path}'")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in {"restore", "backup"}:
        print("usage: python -m nanobot.supabase_sync [restore|backup]", file=sys.stderr)
        return 2

    if argv[1] == "restore":
        return restore_state()
    return backup_state()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

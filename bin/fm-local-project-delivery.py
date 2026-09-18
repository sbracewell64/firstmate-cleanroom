#!/usr/bin/env python3
"""Bind and verify immutable admission manifests for governed local deliveries.

Usage:
  fm-local-project-delivery.py bind --programme FILE --root DIR --step ID \
      --project PROJECT|auto --ref refs/heads/BRANCH --delivery-id ID \
      --maker ID --checker ID --route independent-checker|no-mistakes
  fm-local-project-delivery.py verify --admission FILE --programme FILE \
      --root DIR --step ID

The programme step's terminal_predicate.local_delivery object is the policy
owner for the exact artifact family and optional destination owner.
`bind` derives every candidate and byte identity, validates all facts before
publishing one mode-0600 manifest under FM_HOME/data/local-project-delivery,
and refuses a reused delivery identity.
`verify` re-reads the same programme, source, registered project, Git objects,
and working destination without changing state.

Exit 0 means ADMITTED/ACCEPTED, 4 is a typed REFUSED result, and 5 is CNO.
Every invocation prints exactly one JSON result.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
from pathlib import Path, PurePosixPath
from typing import Any

SCHEMA = "fm-local-project-delivery-admission/v1"
POLICY_SCHEMA = "fm-local-project-delivery-policy/v1"
SLUG = re.compile(r"^[A-Za-z0-9._-]+$")
HEX = re.compile(r"^[0-9a-f]+$")


class Verdict(Exception):
    def __init__(self, status: str, reason: str, detail: str):
        super().__init__(detail)
        self.status = status
        self.reason = reason
        self.detail = detail


class NotOwner(Exception):
    pass


def refuse(reason: str, detail: str) -> None:
    raise Verdict("REFUSED", reason, detail)


def cno(reason: str, detail: str) -> None:
    raise Verdict("CNO", reason, detail)


def exact_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        refuse("SCHEMA_UNSUPPORTED", f"{label} has unsupported fields: {','.join(unknown)}")


def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise ValueError(f"duplicate object key: {key}")
        out[key] = value
    return out


def open_directory(path: Path) -> int:
    absolute = Path(os.path.abspath(path))
    parts = absolute.parts
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(parts[0], flags)
    try:
        for part in parts[1:]:
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def verify_directory_identity(path: Path, fd: int, label: str) -> None:
    held = os.fstat(fd)
    current = os.stat(path, follow_symlinks=False)
    if (held.st_dev, held.st_ino, held.st_mode) != (current.st_dev, current.st_ino, current.st_mode):
        refuse("IDENTITY_CHANGED", f"{label} changed while it was being read")


def directory_identity(path: Path) -> dict[str, int]:
    value = os.stat(path, follow_symlinks=False)
    return {"device": value.st_dev, "inode": value.st_ino, "mode": value.st_mode}


def capture(path: Path, *, private: bool = False, anchor_fd: int | None = None, anchor_path: Path | None = None) -> tuple[bytes, str, int]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    absolute = Path(os.path.abspath(path))
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    if anchor_fd is not None and anchor_path is not None:
        anchor = Path(os.path.abspath(anchor_path))
        try:
            relative = absolute.relative_to(anchor)
        except ValueError:
            refuse("PATH_UNSAFE", f"{path} is outside {anchor_path}")
        parts = relative.parts
        if not parts or any(part in ("", ".", "..") for part in parts):
            refuse("PATH_UNSAFE", f"{path} is not a safe anchored path")
        directory_fd = os.dup(anchor_fd)
    else:
        parts = absolute.parts
        directory_fd = os.open(parts[0], directory_flags)
    try:
        for part in parts[:-1]:
            next_fd = os.open(part, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        fd = os.open(parts[-1], flags, dir_fd=directory_fd)
    except OSError as exc:
        os.close(directory_fd)
        cno("SOURCE_UNREADABLE", f"cannot open {path}: {exc.strerror}")
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            refuse("IDENTITY_TYPE_MISMATCH", f"{path} is not a regular file")
        if private and (stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1 or before.st_uid != os.getuid()):
            refuse("MANIFEST_AUTHENTICITY", f"{path} is not a same-user single-link mode-0600 file")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(fd)
        identity = (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
        identity_after = (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        if identity != identity_after:
            refuse("IDENTITY_CHANGED", f"{path} changed while it was read")
        if anchor_fd is not None and anchor_path is not None:
            anchor_identity = os.fstat(anchor_fd)
            current_anchor = os.stat(anchor_path, follow_symlinks=False)
            if (anchor_identity.st_dev, anchor_identity.st_ino, anchor_identity.st_mode) != (current_anchor.st_dev, current_anchor.st_ino, current_anchor.st_mode):
                refuse("IDENTITY_CHANGED", f"{anchor_path} changed while {path} was read")
        data = b"".join(chunks)
        return data, hashlib.sha256(data).hexdigest(), stat.S_IMODE(before.st_mode)
    finally:
        os.close(fd)
        os.close(directory_fd)


def load_json(path: Path, *, private: bool = False, anchor_fd: int | None = None, anchor_path: Path | None = None) -> tuple[dict[str, Any], bytes, str]:
    data, digest, _ = capture(path, private=private, anchor_fd=anchor_fd, anchor_path=anchor_path)
    try:
        value = json.loads(data, object_pairs_hook=object_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        refuse("IDENTITY_UNREADABLE", f"{path} is not unambiguous JSON: {exc}")
    if not isinstance(value, dict):
        refuse("IDENTITY_UNREADABLE", f"{path} is not a JSON object")
    return value, data, digest


def run(args: list[str], *, cwd: Path | None = None, input_bytes: bytes | None = None) -> bytes:
    try:
        result = subprocess.run(args, cwd=cwd, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as exc:
        cno("IDENTITY_UNREADABLE", f"cannot run {args[0]}: {exc}")
    if result.returncode != 0:
        cno("IDENTITY_UNREADABLE", f"{' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def git(repo: Path, *args: str) -> str:
    return run(["git", "-C", str(repo), *args]).decode().strip()


def safe_relative(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or any(ord(ch) < 32 for ch in value):
        refuse("PATH_UNSAFE", f"{label} must be a non-empty relative POSIX path")
    path = PurePosixPath(value)
    if path.is_absolute() or value != path.as_posix() or any(part in ("", ".", "..") for part in path.parts):
        refuse("PATH_UNSAFE", f"{label} is not a normalized relative POSIX path: {value}")
    return value


def under(root: Path, relative: str) -> Path:
    parts = PurePosixPath(relative).parts
    target = root.joinpath(*parts)
    current = root
    for part in parts[:-1]:
        current /= part
        if current.is_symlink():
            refuse("PATH_UNSAFE", f"{relative} has a symlinked parent")
    parent = target.parent.resolve(strict=True)
    try:
        parent.relative_to(root)
    except ValueError:
        refuse("PATH_UNSAFE", f"{relative} resolves outside {root}")
    return target


def require_slug(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SLUG.fullmatch(value):
        refuse("IDENTITY_MALFORMED", f"{label} must be a slug")
    return value


def require_oid(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) not in (40, 64) or not HEX.fullmatch(value):
        refuse("IDENTITY_MALFORMED", f"{label} must be an exact Git object id")
    return value


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def project_mode(script_dir: Path, home: Path, project: str, registry_data: bytes | None = None) -> str:
    registry = home / "data/projects.md"
    try:
        data = registry_data if registry_data is not None else capture(registry)[0]
        entries = []
        for line in data.decode(errors="strict").splitlines():
            fields = line.split(maxsplit=2)
            if len(fields) < 2 or fields[0] != "-" or fields[1] != project:
                continue
            match = re.fullmatch(
                r"- ([A-Za-z0-9._-]+)(?: \[([^\[\]]*)\])? - .+ \(added [0-9]{4}-[0-9]{2}-[0-9]{2}\)",
                line,
            )
            if match is None:
                refuse("OWNER_MODE_MALFORMED", f"project {project} has malformed registry posture")
            annotation = match.group(2)
            if annotation is None:
                entries.append("no-mistakes")
                continue
            tokens = annotation.split()
            modes = {"no-mistakes", "direct-PR", "local-only", "no-mistakes-prod-only"}
            recognized = [token for token in tokens if token in modes]
            if len(recognized) != 1 or any(token != "+yolo" and token not in modes for token in tokens) or tokens.count("+yolo") > 1:
                refuse("OWNER_MODE_MALFORMED", f"project {project} has ambiguous registry posture")
            entries.append(recognized[0])
    except (UnicodeError, Verdict) as exc:
        if isinstance(exc, Verdict):
            raise
        cno("OWNER_MISSING", f"project registry is unreadable: {exc}")
    if len(entries) != 1:
        cno("OWNER_MISSING", f"project {project} does not have one readable registry posture")
    if entries[0] not in {"no-mistakes", "direct-PR", "local-only", "no-mistakes-prod-only"}:
        refuse("OWNER_MODE_MALFORMED", f"project {project} has unsupported registry posture {entries[0]}")
    if entries[0] != "local-only":
        raise NotOwner(f"project {project} is not registered local-only")
    if registry_data is not None:
        return "local-only"
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    result = subprocess.run(
        [str(script_dir / "fm-project-mode.sh"), "--require-registered", "--raw", project],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        cno("OWNER_MISSING", f"project {project} has no readable exact registry owner: {result.stderr.decode(errors='replace').strip()}")
    mode = result.stdout.decode().strip().split()
    if not mode or mode[0] != "local-only":
        refuse("OWNER_MODE_MISMATCH", f"project {project} registry posture changed while it was read")
    return mode[0]


def registered_projects(home: Path) -> tuple[list[str], str, bytes]:
    registry = home / "data/projects.md"
    try:
        data, digest, _ = capture(registry)
    except Verdict as exc:
        cno("OWNER_MISSING", f"project registry is unreadable: {exc.detail}")
    projects: list[str] = []
    for line in data.decode(errors="strict").splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "-" and SLUG.fullmatch(fields[1]):
            projects.append(fields[1])
    return projects, digest, data


def parse_tree_entry(repo: Path, head: str, path: str) -> tuple[str, str, str]:
    raw = run(["git", "-C", str(repo), "ls-tree", "-z", head, "--", path])
    rows = [row for row in raw.split(b"\0") if row]
    if not rows:
        refuse("FAMILY_INCOMPLETE", f"candidate does not track {path}")
    if len(rows) != 1:
        cno("DESTINATION_UNREADABLE", f"candidate does not track exactly one object at {path}")
    try:
        meta, found = rows[0].split(b"\t", 1)
        mode, obj_type, oid = meta.decode().split(" ")
        found_path = found.decode()
    except (ValueError, UnicodeDecodeError):
        cno("DESTINATION_UNREADABLE", f"candidate tree entry for {path} is unreadable")
    if found_path != path:
        refuse("DESTINATION_PATH_MISMATCH", f"candidate returned {found_path}, not {path}")
    return mode, obj_type, oid


def parse_index_entry(repo: Path, path: str, expected_mode: str, expected_oid: str) -> None:
    raw = run(["git", "-C", str(repo), "ls-files", "--stage", "-z", "--", path])
    rows = [row for row in raw.split(b"\0") if row]
    if len(rows) != 1:
        refuse("DESTINATION_INDEX_MISMATCH", f"destination index does not have one stage-0 entry at {path}")
    try:
        meta, found = rows[0].split(b"\t", 1)
        mode, oid, stage = meta.decode().split(" ")
        found_path = found.decode()
    except (ValueError, UnicodeDecodeError):
        refuse("DESTINATION_INDEX_MISMATCH", f"destination index entry at {path} is unreadable")
    if found_path != path or stage != "0" or mode != expected_mode or oid != expected_oid:
        refuse("DESTINATION_INDEX_MISMATCH", f"destination index entry at {path} differs from the admitted tree entry")


def git_blob(repo: Path, head: str, path: str) -> bytes:
    return run(["git", "-C", str(repo), "show", f"{head}:{path}"])


def policy_for(programme: dict[str, Any], step: str) -> dict[str, Any]:
    steps = programme.get("steps")
    if not isinstance(steps, list):
        refuse("PROGRAMME_MALFORMED", "programme steps must be an array")
    matches = [entry for entry in steps if isinstance(entry, dict) and entry.get("id") == step]
    if len(matches) != 1:
        refuse("ACTION_MISMATCH", f"programme must contain exactly one step {step}")
    terminal = matches[0].get("terminal_predicate")
    if not isinstance(terminal, dict) or terminal.get("kind") != "accepted_owner_evidence":
        refuse("ACTION_MISMATCH", f"step {step} is not governed by accepted owner evidence")
    policy = terminal.get("local_delivery")
    if not isinstance(policy, dict) or policy.get("schema") != POLICY_SCHEMA:
        refuse("REQUIRED_BINDING_MISSING", f"step {step} has no {POLICY_SCHEMA} owner-bound family")
    exact_keys(policy, {"schema", "owner_project", "maker_checker", "qualification_routes", "artifacts", "preservation"}, "local_delivery policy")
    if policy.get("maker_checker") != "distinct":
        refuse("POLICY_UNSUPPORTED", "local delivery policy must require distinct maker and checker")
    routes = policy.get("qualification_routes")
    if not isinstance(routes, list) or not routes or any(route not in ("independent-checker", "no-mistakes") for route in routes):
        refuse("POLICY_UNSUPPORTED", "local delivery policy has unsupported qualification routes")
    artifacts = policy.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        refuse("FAMILY_INCOMPLETE", f"step {step} has no complete artifact family")
    normalized: list[dict[str, str]] = []
    for index, row in enumerate(artifacts):
        if not isinstance(row, dict):
            refuse("FAMILY_INCOMPLETE", f"artifact {index} is not an object")
        exact_keys(row, {"source", "destination", "git_mode"}, f"artifact {index}")
        source = safe_relative(row.get("source"), f"artifact {index} source")
        destination = safe_relative(row.get("destination"), f"artifact {index} destination")
        mode = row.get("git_mode")
        if mode not in ("100644", "100755"):
            refuse("DESTINATION_MODE_MISMATCH", f"artifact {index} mode must be 100644 or 100755")
        normalized.append({"source": source, "destination": destination, "git_mode": mode})
    if len({row["source"] for row in normalized}) != len(normalized) or len({row["destination"] for row in normalized}) != len(normalized):
        refuse("FAMILY_INCOMPLETE", "artifact source and destination paths must be unique")
    policy = dict(policy)
    policy["artifacts"] = normalized
    return policy


def source_identity(root: Path) -> dict[str, Any]:
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        return {"kind": "local-root", "root": str(root), "head": None, "tree": None}
    top = Path(result.stdout.decode().strip()).resolve()
    if top != root:
        refuse("SOURCE_IDENTITY_MISMATCH", f"source root {root} is nested inside a different Git owner {top}")
    head = git(root, "rev-parse", "HEAD^{commit}")
    tree = git(root, "rev-parse", "HEAD^{tree}")
    return {"kind": "local-git", "root": str(root), "head": head, "tree": tree}


def build_candidate(
    *, home: Path, programme: dict[str, Any], root: Path, step: str,
    policy: dict[str, Any], project: str, ref: str,
    delivery_id: str, maker: str, checker: str, route: str, script_dir: Path,
    require_cwd: bool, registry_sha256: str, enforce_pinned_owner: bool = True,
    registry_data: bytes | None = None,
) -> dict[str, Any]:
    pinned = policy.get("owner_project")
    if pinned is not None and (not isinstance(pinned, str) or not SLUG.fullmatch(pinned)):
        refuse("OWNER_PROJECT_MISMATCH", "policy owner_project must be a slug when present")
    if enforce_pinned_owner and pinned is not None and project != pinned:
        refuse("OWNER_PROJECT_MISMATCH", f"project {project} is not the pinned owner {pinned}")
    require_slug(project, "project")
    project_mode(script_dir, home, project, registry_data=registry_data)
    repo = (home / "projects" / project)
    try:
        repo_real = repo.resolve(strict=True)
        projects_real = (home / "projects").resolve(strict=True)
        repo_real.relative_to(projects_real)
    except (OSError, ValueError):
        cno("PROJECT_UNAVAILABLE", f"project {project} is unavailable under this home")
    try:
        top = Path(git(repo_real, "rev-parse", "--show-toplevel")).resolve(strict=True)
    except Verdict as exc:
        cno("PROJECT_UNAVAILABLE", exc.detail)
    if top != repo_real:
        refuse("OWNER_PROJECT_MISMATCH", f"project {project} path is not its repository root")
    if require_cwd and Path.cwd().resolve() != repo_real:
        refuse("WORKING_DIRECTORY_MISMATCH", f"bind must run from {repo_real}")
    source_root_fd = open_directory(root)
    destination_root_fd = open_directory(repo_real)
    if not ref.startswith("refs/heads/") or not SLUG.fullmatch(ref.removeprefix("refs/heads/")):
        refuse("IDENTITY_MALFORMED", "ref must name one exact local branch")
    head = git(repo_real, "rev-parse", f"{ref}^{{commit}}")
    tree = git(repo_real, "rev-parse", f"{head}^{{tree}}")
    require_oid(head, "head")
    require_oid(tree, "tree")

    top_levels = {PurePosixPath(row["destination"]).parts[0] for row in policy["artifacts"]}
    if not any(git(repo_real, "ls-tree", "-d", head, "--", top_level) for top_level in top_levels):
        raise NotOwner(f"project {project} does not contain the governed artifact family")

    artifacts: list[dict[str, Any]] = []
    for row in policy["artifacts"]:
        source_path = under(root, row["source"])
        source_bytes, source_sha, _ = capture(source_path, anchor_fd=source_root_fd, anchor_path=root)
        mode, obj_type, oid = parse_tree_entry(repo_real, head, row["destination"])
        if obj_type != "blob":
            refuse("DESTINATION_TYPE_MISMATCH", f"{row['destination']} is {obj_type}, not blob")
        if mode != row["git_mode"]:
            refuse("DESTINATION_MODE_MISMATCH", f"{row['destination']} is mode {mode}, expected {row['git_mode']}")
        parse_index_entry(repo_real, row["destination"], mode, oid)
        destination_bytes = git_blob(repo_real, head, row["destination"])
        destination_sha = hashlib.sha256(destination_bytes).hexdigest()
        if source_sha != destination_sha:
            refuse("SOURCE_DESTINATION_MISMATCH", f"{row['source']} and {row['destination']} differ")
        destination_file = under(repo_real, row["destination"])
        work_bytes, work_sha, work_mode = capture(destination_file, anchor_fd=destination_root_fd, anchor_path=repo_real)
        expected_fs = 0o755 if mode == "100755" else 0o644
        if work_mode != expected_fs:
            refuse("DESTINATION_MODE_MISMATCH", f"{destination_file} is mode {work_mode:04o}, expected {expected_fs:04o}")
        if work_sha != destination_sha or work_bytes != destination_bytes:
            refuse("DESTINATION_READBACK_MISMATCH", f"working destination {row['destination']} differs from candidate {head}")
        artifacts.append({
            "source": row["source"], "destination": row["destination"], "git_mode": mode,
            "file_mode": f"{expected_fs:04o}", "object_id": oid, "sha256": source_sha,
        })
    verify_directory_identity(root, source_root_fd, "source root")
    verify_directory_identity(repo_real, destination_root_fd, "destination root")

    preservation: dict[str, Any] | None = None
    declared_preservation = policy.get("preservation")
    if declared_preservation is not None:
        if not isinstance(declared_preservation, dict):
            refuse("POLICY_UNSUPPORTED", "preservation must be an object")
        exact_keys(declared_preservation, {"current", "rollback"}, "preservation policy")
        preservation = {}
        for role, expected_kind in (("current", "json_generation"), ("rollback", "git_tree")):
            spec = declared_preservation.get(role)
            if not isinstance(spec, dict):
                refuse("PRESERVATION_MISMATCH", f"preservation {role} is absent")
            exact_keys(spec, {"kind", "path", "generation"}, f"preservation {role}")
            path = safe_relative(spec.get("path"), f"preservation {role} path")
            generation = spec.get("generation")
            if spec.get("kind") != expected_kind or type(generation) is not int or generation < 1:
                refuse("PRESERVATION_MISMATCH", f"preservation {role} has unsupported identity")
            mode, obj_type, oid = parse_tree_entry(repo_real, head, path)
            if role == "current":
                if obj_type != "blob" or mode not in ("100644", "100755"):
                    refuse("PRESERVATION_MISMATCH", f"current generation owner {path} is not a regular blob")
                raw = git_blob(repo_real, head, path)
                try:
                    doc = json.loads(raw, object_pairs_hook=object_pairs)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    refuse("PRESERVATION_MISMATCH", f"current generation owner {path} is unreadable JSON")
                if not isinstance(doc, dict) or doc.get("generation") != generation:
                    refuse("PRESERVATION_MISMATCH", f"current generation at {path} is not {generation}")
                preservation[role] = {"kind": expected_kind, "path": path, "generation": generation, "object_id": oid, "sha256": hashlib.sha256(raw).hexdigest()}
            else:
                if obj_type != "tree" or mode != "040000":
                    refuse("PRESERVATION_MISMATCH", f"rollback generation owner {path} is not a Git tree")
                preservation[role] = {"kind": expected_kind, "path": path, "generation": generation, "object_id": oid}

    verify_directory_identity(root, source_root_fd, "source root")
    verify_directory_identity(repo_real, destination_root_fd, "destination root")

    programme_id = require_slug(programme.get("programme_id"), "programme_id")
    programme_generation = programme.get("schema")
    if not isinstance(programme_generation, str) or not programme_generation:
        refuse("PROGRAMME_MALFORMED", "programme schema is required")
    manifest_sha = hashlib.sha256(canonical(artifacts)).hexdigest()
    source = source_identity(root)
    verify_directory_identity(root, source_root_fd, "source root")
    verify_directory_identity(repo_real, destination_root_fd, "destination root")
    candidate: dict[str, Any] = {
        "schema": SCHEMA,
        "admission_id": delivery_id,
        "delivery_id": delivery_id,
        "home": str(home),
        "context": {"working_directory": str(repo_real)},
        "owner": {"project": project, "mode": "local-only", "registry_sha256": registry_sha256},
        "source": {**source, "root_identity": directory_identity(root)},
        "destination": {"project": project, "root": str(repo_real), "root_identity": directory_identity(repo_real), "ref": ref, "head": head, "tree": tree},
        "action": {
            "programme_id": programme_id,
            "programme_generation": programme_generation,
            "step": step,
            "local_delivery_policy_sha256": hashlib.sha256(canonical(policy)).hexdigest(),
        },
        "requirements": {"maker": maker, "checker": checker, "maker_checker": "distinct"},
        "qualification": {"route": route},
        "artifacts": artifacts,
        "manifest_sha256": manifest_sha,
        "preservation": preservation,
    }
    os.close(source_root_fd)
    os.close(destination_root_fd)
    return candidate


def validate_admission(
    doc: dict[str, Any], *, home: Path, programme: dict[str, Any],
    root: Path, step: str, script_dir: Path,
) -> dict[str, Any]:
    exact_keys(doc, {"schema", "admission_id", "delivery_id", "home", "context", "owner", "source", "destination", "action", "requirements", "qualification", "artifacts", "manifest_sha256", "preservation"}, "admission")
    if doc.get("schema") != SCHEMA:
        refuse("SCHEMA_UNSUPPORTED", f"admission schema is not {SCHEMA}")
    admission_id = require_slug(doc.get("admission_id"), "admission_id")
    if doc.get("delivery_id") != admission_id:
        refuse("ADMISSION_REPLAY", "admission and delivery identities differ")
    if doc.get("home") != str(home):
        refuse("HOME_MISMATCH", f"admission belongs to {doc.get('home')}, not {home}")
    action = doc.get("action")
    if not isinstance(action, dict):
        refuse("ACTION_MISMATCH", "admission action is absent")
    policy = policy_for(programme, step)
    _, registry_sha256, registry_data = registered_projects(home)
    expected_action = {
        "programme_id": programme.get("programme_id"), "programme_generation": programme.get("schema"),
        "step": step, "local_delivery_policy_sha256": hashlib.sha256(canonical(policy)).hexdigest(),
    }
    if action != expected_action:
        if action.get("local_delivery_policy_sha256") != expected_action["local_delivery_policy_sha256"]:
            refuse("PROGRAMME_POLICY_MISMATCH", "local delivery policy differs from the admitted generation")
        refuse("ACTION_MISMATCH", "admission action does not name this exact programme and step")
    owner = doc.get("owner")
    destination = doc.get("destination")
    source = doc.get("source")
    requirements = doc.get("requirements")
    qualification = doc.get("qualification")
    context = doc.get("context")
    if not all(isinstance(value, dict) for value in (owner, destination, source, requirements, qualification, context)):
        refuse("IDENTITY_MALFORMED", "admission owner/source/destination/context/requirements/qualification must be objects")
    project = owner.get("project")
    if owner.get("mode") != "local-only" or destination.get("project") != project:
        refuse("OWNER_PROJECT_MISMATCH", "owner and destination project/mode differ")
    pinned = policy.get("owner_project")
    if pinned is not None and project != pinned:
        refuse("OWNER_PROJECT_MISMATCH", f"admission owner {project} is not pinned owner {pinned}")
    maker = requirements.get("maker")
    checker = requirements.get("checker")
    if maker == checker:
        refuse("MAKER_CHECKER_COLLAPSE", "maker and checker must be distinct")
    require_slug(maker, "maker")
    require_slug(checker, "checker")
    route = qualification.get("route")
    if route not in policy["qualification_routes"]:
        refuse("QUALIFICATION_ROUTE_MISMATCH", f"route {route} is not allowed for step {step}")
    ref = destination.get("ref")
    if not isinstance(ref, str):
        refuse("IDENTITY_MALFORMED", "destination ref is absent")
    rebuilt = build_candidate(
        home=home, programme=programme, root=root, step=step,
        policy=policy, project=project, ref=ref,
        delivery_id=admission_id, maker=maker, checker=checker, route=route,
        script_dir=script_dir, require_cwd=False,
        registry_sha256=registry_sha256,
        registry_data=registry_data,
    )
    _, current_registry_sha256, _ = registered_projects(home)
    if current_registry_sha256 != registry_sha256:
        refuse("OWNER_REGISTRY_CHANGED", "project registry changed during admission verification")
    if doc.get("manifest_sha256") != rebuilt["manifest_sha256"]:
        refuse("MANIFEST_DIGEST_MISMATCH", "artifact manifest digest differs from current exact family")
    if doc.get("artifacts") != rebuilt["artifacts"]:
        declared = doc.get("artifacts")
        if isinstance(declared, list) and [
            {key: row.get(key) for key in ("source", "destination", "git_mode")} for row in declared if isinstance(row, dict)
        ] != policy["artifacts"]:
            refuse("FAMILY_MISMATCH", "admission artifact family differs from programme policy")
        refuse("MANIFEST_AUTHENTICITY", "admission artifact identities differ from current source or destination")
    if destination.get("head") != rebuilt["destination"]["head"]:
        refuse("CANDIDATE_HEAD_MISMATCH", "destination ref moved from the admitted head")
    if destination.get("tree") != rebuilt["destination"]["tree"]:
        refuse("CANDIDATE_TREE_MISMATCH", "admitted destination tree differs from its head")
    for key in ("owner", "source", "destination", "context", "requirements", "qualification", "preservation"):
        if doc.get(key) != rebuilt.get(key):
            if key == "preservation":
                refuse("PRESERVATION_MISMATCH", "current or rollback generation identity changed")
            refuse("MANIFEST_AUTHENTICITY", f"admission {key} identity differs from current facts")
    return rebuilt


def owner_candidates(
    *, home: Path, programme: dict[str, Any], root: Path, step: str,
    policy: dict[str, Any], ref: str, delivery_id: str, maker: str,
    checker: str, route: str, script_dir: Path,
) -> tuple[list[tuple[str, dict[str, Any]]], str]:
    registered, registry_sha256, registry_data = registered_projects(home)
    candidates: list[tuple[str, dict[str, Any]]] = []
    blocking: list[Verdict] = []
    for project in registered:
        try:
            candidate = build_candidate(
                home=home, programme=programme, root=root, step=step,
                policy=policy, project=project, ref=ref,
                delivery_id=delivery_id, maker=maker, checker=checker, route=route,
                script_dir=script_dir, require_cwd=False,
                registry_sha256=registry_sha256,
                registry_data=registry_data,
                enforce_pinned_owner=False,
            )
            candidates.append((project, candidate))
        except NotOwner:
            continue
        except Verdict as exc:
            blocking.append(exc)
    if blocking and candidates:
        raise blocking[0]
    if blocking and not candidates:
        cno("OWNER_MISSING", f"no registered local-only project owns the complete {step} family")
    return candidates, registry_sha256


def reject_symlink_chain(root: Path, relative_parts: tuple[str, ...], label: str) -> None:
    current = root
    for part in relative_parts:
        current /= part
        try:
            if stat.S_ISLNK(os.lstat(current).st_mode):
                refuse("PATH_UNSAFE", f"{label} contains a symlink: {current}")
        except FileNotFoundError:
            continue


def publish(home: Path, candidate: dict[str, Any], registry_sha256: str) -> tuple[Path, str]:
    _, current_registry_sha256, _ = registered_projects(home)
    if current_registry_sha256 != registry_sha256:
        refuse("OWNER_REGISTRY_CHANGED", "project registry changed before admission publication")
    for label, identity in (("source root", candidate["source"]), ("destination root", candidate["destination"])):
        path = Path(identity["root"])
        if directory_identity(path) != identity["root_identity"]:
            refuse("IDENTITY_CHANGED", f"{label} changed before admission publication")
    directory = home / "data/local-project-delivery/admissions"
    final_name = f"{candidate['admission_id']}.json"
    data = json.dumps(candidate, sort_keys=True, indent=2, ensure_ascii=False).encode() + b"\n"
    reject_symlink_chain(home, ("data", "local-project-delivery", "admissions"), "admission directory")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    home_fd = os.open(home, directory_flags)
    data_fd = local_fd = admissions_fd = temp_fd = None
    temp_name = None
    try:
        data_fd = os.open("data", directory_flags, dir_fd=home_fd)
        try:
            os.mkdir("local-project-delivery", 0o700, dir_fd=data_fd)
        except FileExistsError:
            pass
        local_fd = os.open("local-project-delivery", directory_flags, dir_fd=data_fd)
        os.fchmod(local_fd, 0o700)
        try:
            os.mkdir("admissions", 0o700, dir_fd=local_fd)
        except FileExistsError:
            pass
        admissions_fd = os.open("admissions", directory_flags, dir_fd=local_fd)
        os.fchmod(admissions_fd, 0o700)
        temp_name = f".{final_name}.{os.getpid()}.tmp"
        temp_fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600, dir_fd=admissions_fd)
        offset = 0
        while offset < len(data):
            offset += os.write(temp_fd, data[offset:])
        os.fsync(temp_fd)
        os.close(temp_fd)
        temp_fd = None
        try:
            os.link(temp_name, final_name, src_dir_fd=admissions_fd, dst_dir_fd=admissions_fd, follow_symlinks=False)
        except FileExistsError:
            refuse("ADMISSION_REPLAY", f"delivery identity {candidate['admission_id']} already has an admission")
        os.unlink(temp_name, dir_fd=admissions_fd)
        temp_name = None
        os.fsync(admissions_fd)
        return directory / final_name, hashlib.sha256(data).hexdigest()
    finally:
        if temp_fd is not None:
            os.close(temp_fd)
        if temp_name is not None and admissions_fd is not None:
            try:
                os.unlink(temp_name, dir_fd=admissions_fd)
            except OSError:
                pass
        for fd in (admissions_fd, local_fd, data_fd, home_fd):
            if fd is not None:
                os.close(fd)


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="command", required=True)
    bind = sub.add_parser("bind")
    bind.add_argument("--programme", required=True)
    bind.add_argument("--root", required=True)
    bind.add_argument("--step", required=True)
    bind.add_argument("--project", required=True)
    bind.add_argument("--ref", required=True)
    bind.add_argument("--delivery-id", required=True)
    bind.add_argument("--maker", required=True)
    bind.add_argument("--checker", required=True)
    bind.add_argument("--route", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--admission", required=True)
    verify.add_argument("--programme", required=True)
    verify.add_argument("--root", required=True)
    verify.add_argument("--step", required=True)
    return ap


def main() -> int:
    args = parser().parse_args()
    script_dir = Path(__file__).resolve().parent
    home_value = os.environ.get("FM_HOME")
    if not home_value:
        cno("HOME_UNREADABLE", "FM_HOME is required")
    home = Path(home_value).resolve(strict=True)
    programme_path = Path(args.programme).resolve(strict=True)
    root = Path(args.root).resolve(strict=True)
    programme, _, _ = load_json(programme_path)
    step = require_slug(args.step, "step")
    policy = policy_for(programme, step)

    if args.command == "bind":
        delivery_id = require_slug(args.delivery_id, "delivery_id")
        maker = require_slug(args.maker, "maker")
        checker = require_slug(args.checker, "checker")
        if maker == checker:
            refuse("MAKER_CHECKER_COLLAPSE", "maker and checker identities must be distinct")
        route = args.route
        if route not in policy["qualification_routes"]:
            refuse("QUALIFICATION_ROUTE_MISMATCH", f"route {route} is not allowed for step {step}")
        requested_project = args.project
        if requested_project != "auto":
            require_slug(requested_project, "project")
        candidates, registry_sha256 = owner_candidates(
            home=home, programme=programme, root=root, step=step, policy=policy,
            ref=args.ref, delivery_id=delivery_id, maker=maker, checker=checker,
            route=route, script_dir=script_dir,
        )
        if not candidates:
            cno("OWNER_MISSING", f"no registered local-only project owns the complete {step} family")
        if len(candidates) != 1:
            refuse("OWNER_AMBIGUOUS", f"more than one project owns the complete {step} family: {','.join(name for name, _ in candidates)}")
        project, candidate = candidates[0]
        pinned = policy.get("owner_project")
        if pinned is not None and project != pinned:
            refuse("OWNER_PROJECT_MISMATCH", f"unique lawful owner {project} is not the pinned owner {pinned}")
        if requested_project != "auto" and project != requested_project:
            refuse("OWNER_PROJECT_MISMATCH", f"project {requested_project} is not the unique lawful owner {project}")
        if Path.cwd().resolve() != Path(candidate["destination"]["root"]):
            refuse("WORKING_DIRECTORY_MISMATCH", f"bind must run from {candidate['destination']['root']}")
        _, current_registry_sha256, _ = registered_projects(home)
        if current_registry_sha256 != registry_sha256:
            refuse("OWNER_REGISTRY_CHANGED", "project registry changed during owner census")
        path, digest = publish(home, candidate, registry_sha256)
        print(json.dumps({"status": "ADMITTED", "reason_code": None, "path": str(path), "sha256": digest, "project": project, "head": candidate["destination"]["head"], "tree": candidate["destination"]["tree"], "manifest_sha256": candidate["manifest_sha256"]}, sort_keys=True))
        return 0

    admission_path = Path(args.admission)
    data_path = home / "data"
    data_fd = open_directory(data_path)
    try:
        doc, _, digest = load_json(admission_path, private=True, anchor_fd=data_fd, anchor_path=data_path)
    finally:
        os.close(data_fd)
    rebuilt = validate_admission(
        doc, home=home, programme=programme, root=root, step=step, script_dir=script_dir,
    )
    print(json.dumps({"status": "ACCEPTED", "reason_code": None, "path": str(admission_path.resolve()), "sha256": digest, "admission": rebuilt}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Verdict as verdict:
        print(json.dumps({"status": verdict.status, "reason_code": verdict.reason, "detail": verdict.detail}, sort_keys=True))
        raise SystemExit(5 if verdict.status == "CNO" else 4)
    except (OSError, UnicodeError) as exc:
        print(json.dumps({"status": "CNO", "reason_code": "IDENTITY_UNREADABLE", "detail": str(exc)}, sort_keys=True))
        raise SystemExit(5)

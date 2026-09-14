#!/usr/bin/env bash
# fm-enforcement-caller-check.sh - prove every enforce-style entry point in bin/
# names a real enforcing call site.
#
# Usage:
#   bin/fm-enforcement-caller-check.sh
#   bin/fm-enforcement-caller-check.sh --root <repo> [--inventory <path>]
#
# An invariant is not active merely because it is documented. An enforce,
# validate or refuse capability that no production caller reaches is UNPROVEN,
# not active, and this check is what says so mechanically.
#
# The check discovers candidate entry points from the tracked tree with fixed
# rules this script owns, then requires docs/enforcement-points.json to declare
# every discovered candidate. A declared `enforced` entry must name at least one
# call site that exists, sits on the production surface, and actually references
# the entry point; a test that calls the capability is NOT evidence that the
# guarded path reaches it. The one exception is an entry whose guarded path is
# the repository itself: there the CI suite walk is the production path, so a
# `ci-suite` call site is accepted only after this check proves the harness
# really schedules that test into a CI lane. Discovery rules and the accepted
# kinds are pinned in this script, so an inventory edit can narrow neither.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

# Discovery rules. Pinned here, never read from the inventory, so a declaration
# can never shrink the set of capabilities that must be accounted for.
SCRIPT_NAME_SEGMENTS = frozenset({"check", "enforce", "guard", "lint", "refuse", "validate", "verify"})
SUBCOMMAND_VERBS = ("admit", "assert", "enforce", "guard", "qualify", "refuse", "validate", "verify")
FLAG_VERBS = ("assert", "check", "enforce", "guard", "refuse", "require", "validate", "verify")
FUNCTION_VERBS = ("assert", "enforce", "guard", "refuse", "require", "validate", "verify")

SUBCOMMAND_RE = re.compile(r"^\s{0,4}([a-z0-9|_-]+)\)")
# A dispatcher is a `case` on the script's own argument stream: `$1` itself, or
# a variable this file assigned directly from `$1`. Deliberately narrow, so an
# unrelated internal `case` is not harvested as a subcommand table.
CASE_SUBJECT_RE = re.compile(r'^\s*case\s+"?\$\{?([A-Za-z_0-9][A-Za-z0-9_]*)\b')
ESAC_RE = re.compile(r"^\s*esac\b")
ARG_ASSIGN_RE = re.compile(
    r'^\s*(?:local\s+|declare\s+|readonly\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(?:"?\$\{?1\b)'
)
# An alias group is discovered on every alternative: `--enforce|--enforce-all)`.
FLAG_RE = re.compile(r"^\s{0,8}(--[a-z][a-z0-9-]*(?:\|--[a-z][a-z0-9-]*)*)\)")
FUNCTION_RE = re.compile(r"^(fm_[a-z0-9_]+)\(\)")

# Emitted operator text is not a call. A heredoc body and the argument text of
# printf/echo/cat are dropped before matching, but a command substitution inside
# them survives, so a genuine call that sits inside an emitted string counts.
HEREDOC_RE = re.compile(
    r"(?<!<)<<(?!<)(-?)(?:'([A-Za-z_][A-Za-z0-9_]*)'"
    r"|\"([A-Za-z_][A-Za-z0-9_]*)\""
    r"|\\([A-Za-z_][A-Za-z0-9_]*)"
    r"|([A-Za-z_][A-Za-z0-9_]*))"
)
OUTPUT_COMMAND_RE = re.compile(r"^\s*(?:printf|echo|cat)\b")
SPLIT_OPERATORS = ("&&", "||", ";;", ";", "|", "&")
COMMAND_SUB_RE = re.compile(r"\$\((?P<paren>[^()]*(?:\([^()]*\)[^()]*)*)\)|`(?P<tick>[^`]*)`")
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"(?<![:\\])//.*$")

HASH_COMMENT_SUFFIXES = (".sh", ".yaml", ".yml")
SLASH_COMMENT_SUFFIXES = (".mjs", ".js", ".ts")

# Surfaces a running firstmate or its automated gates actually execute.
PRODUCTION_SURFACES = (
    "bin/*.sh",
    "bin/*.mjs",
    "bin/backends/*.sh",
    ".github/workflows/*.yml",
    ".no-mistakes.yaml",
    ".claude/settings.json",
    ".codex/hooks.json",
    ".cursor/hooks.json",
    ".grok/hooks/*.json",
    ".opencode/plugins/*.js",
    ".pi/extensions/*.ts",
)

ALLOWED_KINDS = ("enforced", "operator-invoked", "not-enforcement")
ALLOWED_GUARDS = ("runtime", "repository")
ALLOWED_VIA = ("production", "ci-suite")
# How far after a script reference a subcommand token still reads as that call.
CALL_WINDOW = 200


class CheckError(Exception):
    """One deterministic enforcement-caller failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def read_text(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def verb_match(name: str, verbs: tuple[str, ...]) -> bool:
    return any(re.match(rf"^{verb}([-_]|$)", name) for verb in verbs)


def function_verb_match(name: str, verbs: tuple[str, ...]) -> bool:
    return any(f"_{verb}_" in f"_{name}_" for verb in verbs)


def dispatch_subjects(lines: list[str]) -> set[str]:
    """`$1` plus every variable this file assigns directly from `$1`."""
    subjects = {"1"}
    for line in lines:
        assigned = ARG_ASSIGN_RE.match(line)
        if assigned:
            subjects.add(assigned.group(1))
    return subjects


def discover_functions(rel: str, lines: list[str], found: dict[str, str]) -> None:
    for line in lines:
        match = FUNCTION_RE.match(line)
        if match and function_verb_match(match.group(1), FUNCTION_VERBS):
            found[f"{rel}:{match.group(1)}"] = "function"


def discover_dispatch_and_flags(rel: str, lines: list[str], found: dict[str, str]) -> None:
    subjects = dispatch_subjects(lines)
    in_dispatch = False
    for line in lines:
        if in_dispatch:
            if ESAC_RE.match(line):
                in_dispatch = False
            else:
                match = SUBCOMMAND_RE.match(line)
                if match:
                    for label in match.group(1).split("|"):
                        if verb_match(label, SUBCOMMAND_VERBS):
                            found[f"{rel}:{label}"] = "subcommand"
        else:
            subject = CASE_SUBJECT_RE.match(line)
            if subject and subject.group(1) in subjects:
                in_dispatch = True
        flag = FLAG_RE.match(line)
        if flag:
            for alias in flag.group(1).split("|"):
                if verb_match(alias[2:], FLAG_VERBS):
                    found[f"{rel}:{alias}"] = "flag"


def discover(root: Path, tracked: list[str]) -> dict[str, str]:
    """Map candidate entry-point id -> discovery axis."""
    found: dict[str, str] = {}
    for rel in tracked:
        if not (fnmatch.fnmatch(rel, "bin/*.sh") or fnmatch.fnmatch(rel, "bin/backends/*.sh")):
            continue
        stem = Path(rel).stem
        lines = read_text(root, rel).splitlines()
        discover_functions(rel, lines, found)
        if stem.endswith("-lib"):
            # A sourced library has no argument stream and no name of its own on
            # the command line; only its functions are entry points.
            continue
        if set(stem.split("-")) & SCRIPT_NAME_SEGMENTS:
            found[rel] = "script"
        discover_dispatch_and_flags(rel, lines, found)
    return found


def split_id(entry_id: str) -> tuple[str, str | None]:
    path, _, token = entry_id.partition(":")
    return path, token or None


def axis_for(entry_id: str, discovered: dict[str, str]) -> str:
    """Discovery axis, inferred from the id shape for a declared-only entry."""
    axis = discovered.get(entry_id)
    if axis is not None:
        return axis
    _, token = split_id(entry_id)
    if token is None:
        return "script"
    if token.startswith("--"):
        return "flag"
    if token.startswith("fm_"):
        return "function"
    return "subcommand"


def is_production(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pattern) for pattern in PRODUCTION_SURFACES)


def command_substitutions(text: str) -> str:
    """The executable part of an emitted string: what `$(...)` and backticks run."""
    return " ".join(
        match.group("paren") or match.group("tick") or ""
        for match in COMMAND_SUB_RE.finditer(text)
    )


def shell_segments(line: str) -> list[str]:
    """Split a shell line at its unquoted control operators, operators kept.

    Quoting, command substitutions and backticks are tracked, so a `;` or `|`
    inside emitted text never splits and a real pipeline always does.
    """
    segments: list[str] = []
    current: list[str] = []
    quote: str | None = None
    depth = 0
    backtick = False
    index = 0
    size = len(line)
    while index < size:
        char = line[index]
        if quote is not None:
            current.append(char)
            if char == "\\" and quote == '"' and index + 1 < size:
                current.append(line[index + 1])
                index += 2
                continue
            if char == quote:
                quote = None
            index += 1
            continue
        if char == "\\" and index + 1 < size:
            current.append(char)
            current.append(line[index + 1])
            index += 2
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            index += 1
            continue
        if char == "`":
            backtick = not backtick
            current.append(char)
            index += 1
            continue
        if char == "$" and index + 1 < size and line[index + 1] == "(":
            depth += 1
            current.append("$(")
            index += 2
            continue
        if char == ")" and depth:
            depth -= 1
            current.append(char)
            index += 1
            continue
        if depth == 0 and not backtick:
            operator = next((op for op in SPLIT_OPERATORS if line.startswith(op, index)), None)
            if operator is not None:
                segments.append("".join(current) + operator)
                current = []
                index += len(operator)
                continue
        current.append(char)
        index += 1
    segments.append("".join(current))
    return segments


def strip_emitted_arguments(line: str) -> str:
    """Drop the argument text of printf/echo/cat, keeping the rest of the line.

    Only the emitting command's own segment is dropped, so a real command on the
    other side of a pipe - `printf %s "$p" | bin/fm-x.sh --guard` - still counts.
    """
    return "".join(
        command_substitutions(segment) if OUTPUT_COMMAND_RE.match(segment) else segment
        for segment in shell_segments(line)
    )


def shell_executable_text(text: str) -> str:
    """Shell source with comments, heredoc bodies and emitted argument text gone."""
    kept: list[str] = []
    pending: tuple[str, bool, bool] | None = None
    for line in text.splitlines():
        if pending is not None:
            terminator, expands, dashed = pending
            candidate = line.lstrip("\t") if dashed else line
            if candidate.rstrip() == terminator:
                pending = None
                continue
            kept.append(command_substitutions(line) if expands else "")
            continue
        if line.lstrip().startswith("#"):
            continue
        opener = HEREDOC_RE.search(line)
        kept.append(strip_emitted_arguments(line))
        if opener:
            terminator = opener.group(2) or opener.group(3) or opener.group(4) or opener.group(5)
            pending = (terminator, opener.group(5) is not None, opener.group(1) == "-")
    return "\n".join(kept)


def executable_text(rel: str, text: str) -> str:
    """Drop the parts of a caller that cannot execute, per language.

    A capability named in a comment or in emitted operator text is prose, not a
    call, and reading it as one would report an enforcing caller where none
    exists. JSON has no comment syntax, so its content is left as written.
    """
    if rel.endswith(".sh"):
        return shell_executable_text(text)
    if rel.endswith(HASH_COMMENT_SUFFIXES):
        return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    if rel.endswith(SLASH_COMMENT_SUFFIXES):
        body = BLOCK_COMMENT_RE.sub(" ", text)
        return "\n".join(LINE_COMMENT_RE.sub("", line) for line in body.splitlines())
    return text


# One run reads the same caller for many entry points; stripping it once keeps
# the walk linear in tracked files rather than files times entry points.
_EXECUTABLE_CACHE: dict[str, str] = {}


def executable_source(root: Path, rel: str) -> str:
    cached = _EXECUTABLE_CACHE.get(rel)
    if cached is None:
        cached = executable_text(rel, read_text(root, rel))
        _EXECUTABLE_CACHE[rel] = cached
    return cached


def names_it(text: str, owner_base: str, token: str | None, axis: str) -> bool:
    """Does this raw file text mention the capability at all, call or prose?"""
    needle = token if axis == "function" and token is not None else owner_base
    return needle in text


def references(text: str, owner_base: str, token: str | None, axis: str) -> bool:
    """Does this file text read as a call of the entry point?"""
    if axis == "function":
        assert token is not None
        if token not in text:
            return False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("#") or FUNCTION_RE.match(line):
                continue
            if re.search(rf"\b{re.escape(token)}\b", stripped):
                return True
        return False
    if owner_base not in text:
        return False
    if token is None:
        return True
    if axis == "flag":
        return re.search(rf"(?<![\w-]){re.escape(token)}(?![\w-])", text) is not None
    pattern = re.compile(rf"\b{re.escape(token)}\b")
    start = 0
    while True:
        at = text.find(owner_base, start)
        if at < 0:
            return False
        if pattern.search(text, at, at + len(owner_base) + CALL_WINDOW):
            return True
        start = at + 1


def ci_scheduled_tests(root: Path) -> set[str]:
    """Test scripts the harness itself schedules into a CI lane."""
    runner = root / "bin/fm-test-run.sh"
    if not runner.is_file():
        fail("cannot prove CI scheduling: bin/fm-test-run.sh is missing")
    lanes = subprocess.run(
        [str(runner), "--list-ci-lanes"],
        check=False,
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if lanes.returncode != 0:
        fail(f"cannot prove CI scheduling: --list-ci-lanes failed: {lanes.stderr.strip()}")
    scheduled: set[str] = set()
    for lane in sorted({line.strip() for line in lanes.stdout.splitlines() if line.strip()}):
        listed = subprocess.run(
            [str(runner), "--list", "--lane", lane],
            check=False,
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if listed.returncode != 0:
            fail(f"cannot prove CI scheduling: --list --lane {lane} failed: {listed.stderr.strip()}")
        scheduled.update(line.strip() for line in listed.stdout.splitlines() if line.strip())
    return scheduled


def load_inventory(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"inventory is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"inventory is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("inventory root must be an object")
    if data.get("version") != 1:
        fail("inventory version must be 1")
    entries = data.get("entryPoints")
    if not isinstance(entries, list) or not entries:
        fail("entryPoints must be a non-empty array")
    return data


def required_text(entry: dict, field: str, entry_id: str) -> str:
    value = entry.get(field)
    if not isinstance(value, str) or not value.strip():
        fail(f"{entry_id}: {field} must be a non-empty string")
    return value


def entry_exists(root: Path, entry_id: str, axis: str) -> None:
    path, token = split_id(entry_id)
    if not (root / path).is_file():
        fail(f"{entry_id}: declared entry point no longer exists")
    if token is None:
        return
    text = read_text(root, path)
    if axis == "flag":
        present = re.search(rf"^\s{{0,8}}(?:--[a-z0-9-]+\|)*{re.escape(token)}(?:\||\))", text, re.M)
    elif axis == "function":
        present = re.search(rf"^{re.escape(token)}\(\)", text, re.M)
    else:
        present = re.search(rf"^\s{{0,4}}(?:[a-z0-9|_-]*\|)?{re.escape(token)}(?:\||\))", text, re.M)
    if not present:
        fail(f"{entry_id}: declared capability is no longer defined in {path}")


def where_referenced(root: Path, tracked: list[str], entry_id: str, axis: str) -> dict[str, list[str]]:
    path, token = split_id(entry_id)
    owner_base = Path(path).name
    seen: dict[str, list[str]] = {"production": [], "test": [], "other": []}
    for rel in tracked:
        if rel == path and axis != "function":
            continue
        if not (root / rel).is_file():
            continue
        if not references(executable_source(root, rel), owner_base, token, axis):
            continue
        if is_production(rel):
            seen["production"].append(rel)
        elif rel.startswith("tests/"):
            seen["test"].append(rel)
        else:
            seen["other"].append(rel)
    return seen


def check_call_sites(
    root: Path,
    entry: dict,
    entry_id: str,
    axis: str,
    guards: str,
    scheduled: set[str],
    tracked: list[str],
) -> int:
    sites = entry.get("callSites")
    if not isinstance(sites, list) or not sites:
        found = where_referenced(root, tracked, entry_id, axis)
        fail(
            f"{entry_id}: enforce-style entry point with no declared production call site "
            f"(referenced only in {summarize(found)}); wire an enforcing caller or declare "
            f"the entry as operator-invoked with its reason"
        )
    path, token = split_id(entry_id)
    owner_base = Path(path).name
    for index, site in enumerate(sites):
        if not isinstance(site, dict):
            fail(f"{entry_id}: callSites[{index}] must be an object")
        site_path = required_text(site, "path", entry_id)
        via = site.get("via")
        if via not in ALLOWED_VIA:
            fail(f"{entry_id}: callSites[{index}].via must be one of {', '.join(ALLOWED_VIA)}")
        if site_path == path and axis != "function":
            fail(f"{entry_id}: {site_path} is the entry point itself, not a caller")
        if not (root / site_path).is_file():
            fail(f"{entry_id}: declared call site is missing: {site_path}")
        if not references(executable_source(root, site_path), owner_base, token, axis):
            fail(f"{entry_id}: declared call site {site_path} does not call it")
        if via == "production":
            if not is_production(site_path):
                fail(
                    f"{entry_id}: declared call site {site_path} is not on the production surface; "
                    f"a test or document is not evidence of production enforcement"
                )
            continue
        if guards != "repository":
            fail(
                f"{entry_id}: a ci-suite call site is only evidence for an entry that guards the "
                f"repository; a runtime invariant needs a production caller"
            )
        if not fnmatch.fnmatch(site_path, "tests/*.test.sh"):
            fail(f"{entry_id}: ci-suite call site {site_path} is not a tests/*.test.sh script")
        if site_path not in scheduled:
            fail(
                f"{entry_id}: ci-suite call site {site_path} is not scheduled into any CI lane, "
                f"so no automated gate reaches this capability"
            )
    return len(sites)


def check_rejected_call_sites(root: Path, entry: dict, entry_id: str, axis: str) -> int:
    """Assert every recorded near-miss really is still rejected by the matcher.

    A sweep that found a declared call site to be prose keeps that find here, so
    weakening the executable-reference rule fails loudly on a real file.
    """
    sites = entry.get("rejectedCallSites")
    if sites is None:
        return 0
    if not isinstance(sites, list) or not sites:
        fail(f"{entry_id}: rejectedCallSites must be a non-empty array when it is present")
    path, token = split_id(entry_id)
    owner_base = Path(path).name
    for index, site in enumerate(sites):
        if not isinstance(site, dict):
            fail(f"{entry_id}: rejectedCallSites[{index}] must be an object")
        site_path = required_text(site, "path", entry_id)
        required_text(site, "reason", entry_id)
        if not (root / site_path).is_file():
            fail(f"{entry_id}: rejected call site is missing: {site_path}")
        raw = read_text(root, site_path)
        if not names_it(raw, owner_base, token, axis):
            fail(
                f"{entry_id}: rejected call site {site_path} does not name the capability at all, "
                f"so it records no near miss"
            )
        if references(executable_source(root, site_path), owner_base, token, axis):
            fail(
                f"{entry_id}: rejected call site {site_path} now reads as a real call; either the "
                f"executable-reference rule was weakened or the site became a genuine caller"
            )
    return len(sites)


def summarize(found: dict[str, list[str]]) -> str:
    parts = [f"{label}: {', '.join(paths)}" for label, paths in found.items() if paths]
    return "; ".join(parts) if parts else "no file at all"


def check_function_call_site(root: Path, entry_id: str, tracked: list[str]) -> None:
    found = where_referenced(root, tracked, entry_id, "function")
    if not found["production"]:
        fail(
            f"{entry_id}: enforce-style library function with no production call site "
            f"(referenced only in {summarize(found)}); a test caller is not evidence that the "
            f"guarded path reaches it"
        )


def validate(root: Path, inventory_path: Path) -> dict[str, int]:
    data = load_inventory(inventory_path)
    tracked = git_tracked(root)
    discovered = discover(root, tracked)
    entries = data["entryPoints"]

    ids: list[str] = []
    by_id: dict[str, dict] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            fail(f"entryPoints[{index}] must be an object")
        entry_id = required_text(entry, "id", f"entryPoints[{index}]")
        ids.append(entry_id)
        by_id[entry_id] = entry

    duplicates = sorted(name for name, count in Counter(ids).items() if count != 1)
    if duplicates:
        fail("entry points declared more than once: " + ", ".join(duplicates))

    undeclared = sorted(set(discovered) - set(ids))
    if undeclared:
        fail(
            "undeclared enforce-style entry point(s) in bin/: "
            + ", ".join(undeclared)
            + "; declare each in "
            + str(inventory_path.name)
            + " with its invariant, kind, and enforcing call site"
        )

    scheduled: set[str] | None = None
    counts = {
        "entries": len(ids),
        "enforced": 0,
        "operator": 0,
        "not_enforcement": 0,
        "call_sites": 0,
        "rejected": 0,
    }
    for entry_id in sorted(ids):
        entry = by_id[entry_id]
        axis = axis_for(entry_id, discovered)
        kind = entry.get("kind")
        if kind not in ALLOWED_KINDS:
            fail(f"{entry_id}: kind must be one of {', '.join(ALLOWED_KINDS)}")
        required_text(entry, "invariant", entry_id)
        entry_exists(root, entry_id, axis)
        counts["rejected"] += check_rejected_call_sites(root, entry, entry_id, axis)
        if kind == "not-enforcement":
            required_text(entry, "reason", entry_id)
            counts["not_enforcement"] += 1
            continue
        if kind == "operator-invoked":
            required_text(entry, "reason", entry_id)
            documented = entry.get("documentedAt")
            if not isinstance(documented, list) or not documented:
                fail(f"{entry_id}: an operator-invoked entry point must name where it is documented")
            for where in documented:
                if not isinstance(where, str) or not (root / where).is_file():
                    fail(f"{entry_id}: documentedAt names a missing file: {where!r}")
                if Path(entry_id.partition(':')[0]).name not in read_text(root, where):
                    fail(f"{entry_id}: documentedAt file {where} does not name it")
            counts["operator"] += 1
            continue
        guards = entry.get("guards")
        if guards not in ALLOWED_GUARDS:
            fail(f"{entry_id}: guards must be one of {', '.join(ALLOWED_GUARDS)}")
        if axis == "function":
            check_function_call_site(root, entry_id, tracked)
        if scheduled is None and any(
            isinstance(site, dict) and site.get("via") == "ci-suite"
            for site in entry.get("callSites") or []
        ):
            scheduled = ci_scheduled_tests(root)
        counts["call_sites"] += check_call_sites(
            root, entry, entry_id, axis, guards, scheduled or set(), tracked
        )
        counts["enforced"] += 1
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prove every enforce-style entry point in bin/ has an enforcing call site."
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory or (root / "docs/enforcement-points.json")
    if not inventory_path.is_absolute():
        inventory_path = root / inventory_path
    try:
        counts = validate(root, inventory_path)
    except CheckError as exc:
        print(f"fm-enforcement-caller-check: {exc}", file=sys.stderr)
        return 1
    print(
        "fm-enforcement-caller-check: ok "
        f"entries={counts['entries']} enforced={counts['enforced']} "
        f"operator_invoked={counts['operator']} not_enforcement={counts['not_enforcement']} "
        f"call_sites={counts['call_sites']} rejected_call_sites={counts['rejected']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

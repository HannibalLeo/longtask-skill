#!/usr/bin/env python3
"""Table-driven fixture runner for longtask dual-harness contracts."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "fixtures" / "_runner" / "manifest.json"
SHARED_SCHEMA_ROOT = REPO_ROOT / "shared" / "schemas"


def _collect_refs(node: Any) -> list[str]:
    refs: list[str] = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                refs.append(value)
            refs.extend(_collect_refs(value))
    elif isinstance(node, list):
        for item in node:
            refs.extend(_collect_refs(item))
    return refs


def _resolve_ref_file(schema_file: Path, ref_value: str) -> Path | None:
    if ref_value.startswith("#"):
        return None
    if "://" in ref_value:
        return None
    file_part = ref_value.split("#", 1)[0]
    if not file_part:
        return None
    return (schema_file.parent / file_part).resolve()


def _classify_schema_path(path: str) -> str:
    normalized = path.strip().lstrip("./")
    if not normalized.endswith(".schema.json"):
        return "not-schema"
    if normalized.startswith("shared/schemas/"):
        return "active-authority"
    allowed_patterns = (
        "docs/**",
        "openspec/**",
        "migration/**",
        "migrations/**",
        "**/migration/**",
        "**/migrations/**",
        "**/archive/**",
    )
    if any(fnmatch.fnmatch(normalized, pat) for pat in allowed_patterns):
        return "allowed-non-executable"
    return "rejected-duplicate-active"


def _run_case_schema_parse(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    pattern = case["schema_glob"]
    matched = sorted(p for p in REPO_ROOT.glob(pattern) if p.is_file())
    errors: list[str] = []
    for schema_path in matched:
        try:
            json.loads(schema_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            rel = schema_path.relative_to(REPO_ROOT).as_posix()
            errors.append(f"{rel}: {exc}")
    details = {
        "schema_glob": pattern,
        "matched": [p.relative_to(REPO_ROOT).as_posix() for p in matched],
        "errors": errors,
    }
    return len(matched) > 0 and not errors, details


def _run_case_ref_resolution(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    schema_paths = [REPO_ROOT / p for p in case["schema_paths"]]
    failures: list[str] = []
    checked_refs: list[dict[str, str]] = []
    for schema_path in schema_paths:
        rel_schema = schema_path.relative_to(REPO_ROOT).as_posix()
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        refs = _collect_refs(schema)
        for ref in refs:
            resolved = _resolve_ref_file(schema_path, ref)
            if resolved is None:
                checked_refs.append({"schema": rel_schema, "ref": ref, "resolved": "<inline-or-uri>"})
                continue
            rel_resolved = resolved.relative_to(REPO_ROOT).as_posix() if resolved.exists() else "<missing>"
            checked_refs.append({"schema": rel_schema, "ref": ref, "resolved": rel_resolved})
            if not resolved.exists():
                failures.append(f"{rel_schema}: unresolved ref '{ref}' -> {resolved}")
                continue
            if not resolved.is_file():
                failures.append(f"{rel_schema}: ref '{ref}' resolved to non-file path")
                continue
            if SHARED_SCHEMA_ROOT not in resolved.parents:
                failures.append(f"{rel_schema}: ref '{ref}' escapes shared/schemas ({rel_resolved})")
    return not failures, {"checked_refs": checked_refs, "failures": failures}


def _run_case_duplicate_rejection(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    sample_candidates = case.get("sample_candidates", [])
    sample_classification = [
        {"path": p, "classification": _classify_schema_path(p)} for p in sample_candidates
    ]
    expected_rejected = sorted(case.get("expected_rejected", []))
    actual_rejected = sorted(
        item["path"] for item in sample_classification if item["classification"] == "rejected-duplicate-active"
    )

    repo_candidates = sorted(
        p.relative_to(REPO_ROOT).as_posix()
        for p in REPO_ROOT.glob("**/*.schema.json")
        if p.is_file() and SHARED_SCHEMA_ROOT not in p.parents
    )
    repo_classification = [
        {"path": p, "classification": _classify_schema_path(p)} for p in repo_candidates
    ]
    repo_rejected = [
        item["path"] for item in repo_classification if item["classification"] == "rejected-duplicate-active"
    ]

    ok = actual_rejected == expected_rejected and not repo_rejected
    details = {
        "sample_classification": sample_classification,
        "expected_rejected": expected_rejected,
        "actual_rejected": actual_rejected,
        "repo_external_schema_classification": repo_classification,
        "repo_rejected_duplicates": repo_rejected,
    }
    return ok, details


def _run_case_allowed_doc_migration(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    sample_paths = case["sample_paths"]
    expected_allowed = sorted(case["expected_allowed"])
    actual_allowed = sorted(p for p in sample_paths if _classify_schema_path(p) == "allowed-non-executable")
    details = {
        "sample_paths": sample_paths,
        "expected_allowed": expected_allowed,
        "actual_allowed": actual_allowed,
        "classifications": [{"path": p, "classification": _classify_schema_path(p)} for p in sample_paths],
    }
    return actual_allowed == expected_allowed, details


def _compare_expected_fields(actual: Any, expected: Any, path: str = "root") -> list[str]:
    mismatches: list[str] = []
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {type(actual).__name__}"]
        for key, expected_value in expected.items():
            if key not in actual:
                mismatches.append(f"{path}.{key}: missing key")
                continue
            mismatches.extend(_compare_expected_fields(actual[key], expected_value, f"{path}.{key}"))
        return mismatches
    if isinstance(expected, list):
        if actual != expected:
            mismatches.append(f"{path}: expected {expected!r}, got {actual!r}")
        return mismatches
    if actual != expected:
        mismatches.append(f"{path}: expected {expected!r}, got {actual!r}")
    return mismatches


def _run_case_contract_case(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    actual = case.get("actual")
    expected = case.get("expected")
    if expected is None:
        return False, {"error": "missing_expected"}
    mismatches = _compare_expected_fields(actual, expected)
    return not mismatches, {"actual": actual, "expected": expected, "mismatches": mismatches}


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _expand_tokens(value: Any, tokens: dict[str, str]) -> Any:
    if isinstance(value, str):
        for key, token_value in tokens.items():
            value = value.replace(f"{{{key}}}", token_value)
        return value
    if isinstance(value, list):
        return [_expand_tokens(item, tokens) for item in value]
    if isinstance(value, dict):
        return {k: _expand_tokens(v, tokens) for k, v in value.items()}
    return value


def _run_case_wrapper_exec(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    wrapper_relpath = case.get("wrapper_path", "claude/lib/codex-wrapper.sh")
    wrapper_abs = (REPO_ROOT / wrapper_relpath).resolve()
    if not wrapper_abs.exists():
        return False, {"error": "missing_wrapper", "wrapper_path": wrapper_relpath}

    with tempfile.TemporaryDirectory(prefix="wrapper-matrix-") as tmp:
        tmp_dir = Path(tmp)
        bin_dir = tmp_dir / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        args_file = tmp_dir / "codex-args.bin"
        stdin_file = tmp_dir / "codex-stdin.txt"
        fake_script_marker = tmp_dir / "fake-script-used.txt"
        prompt_file = tmp_dir / "prompt.txt"
        output_schema_file = tmp_dir / "schema.json"
        last_message_file = tmp_dir / "last-message.json"

        prompt_text = case.get("prompt_text", "")
        prompt_file.write_text(prompt_text, encoding="utf-8")
        output_schema_file.write_text('{"type":"object"}\n', encoding="utf-8")
        last_message_file.write_text("{}\n", encoding="utf-8")

        tokens = {
            "PROMPT_FILE": str(prompt_file),
            "OUTPUT_SCHEMA_FILE": str(output_schema_file),
            "LAST_MESSAGE_FILE": str(last_message_file),
        }

        fake_codex = case.get("fake_codex", {})
        fake_codex_script = """#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CODEX_ARGS_FILE:?}"
: "${FAKE_CODEX_STDIN_FILE:?}"
: "${FAKE_CODEX_SLEEP_BEFORE_IO:=0}"
if [ "$FAKE_CODEX_SLEEP_BEFORE_IO" != "0" ]; then
  sleep "$FAKE_CODEX_SLEEP_BEFORE_IO"
fi
printf '%s\\0' "$@" > "$FAKE_CODEX_ARGS_FILE"
cat > "$FAKE_CODEX_STDIN_FILE"
printf '%s' "${FAKE_CODEX_STDOUT:-}"
printf '%s' "${FAKE_CODEX_STDERR:-}" >&2
exit "${FAKE_CODEX_EXIT:-0}"
"""
        _write_executable(bin_dir / "codex", fake_codex_script)

        fake_script = """#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_SCRIPT_MARKER:?}"
printf 'invoked\\n' >> "$FAKE_SCRIPT_MARKER"
if [ "$#" -lt 3 ] || [ "${1:-}" != "-q" ] || [ "${2:-}" != "/dev/null" ]; then
  echo "unexpected script(1) args: $*" >&2
  exit 97
fi
shift 2
"$@"
"""
        _write_executable(bin_dir / "script", fake_script)

        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env.get('PATH', '')}"
        env["FAKE_CODEX_ARGS_FILE"] = str(args_file)
        env["FAKE_CODEX_STDIN_FILE"] = str(stdin_file)
        env["FAKE_SCRIPT_MARKER"] = str(fake_script_marker)
        env["FAKE_CODEX_STDOUT"] = str(fake_codex.get("stdout", ""))
        env["FAKE_CODEX_STDERR"] = str(fake_codex.get("stderr", ""))
        env["FAKE_CODEX_EXIT"] = str(fake_codex.get("exit", 0))
        env["FAKE_CODEX_SLEEP_BEFORE_IO"] = str(fake_codex.get("sleep_before_io", 0))
        for key, value in case.get("env", {}).items():
            env[key] = str(value)

        invoke_args = _expand_tokens(case.get("invoke_args", ["{PROMPT_FILE}"]), tokens)
        cmd = ["bash", str(wrapper_abs), *invoke_args]
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            env=env,
            input=case.get("stdin_text", ""),
            text=True,
            capture_output=True,
        )

        actual_argv: list[str] = []
        if args_file.exists():
            raw = args_file.read_bytes()
            if raw:
                actual_argv = [x.decode("utf-8") for x in raw.split(b"\0") if x]
        actual_stdin = stdin_file.read_text(encoding="utf-8") if stdin_file.exists() else ""
        script_invoked = fake_script_marker.exists()

        expected = _expand_tokens(case.get("expected", {}), tokens)
        mismatches: list[str] = []
        if "exit_code" in expected and proc.returncode != expected["exit_code"]:
            mismatches.append(f"exit_code: expected {expected['exit_code']!r}, got {proc.returncode!r}")
        if "stdout" in expected and proc.stdout != expected["stdout"]:
            mismatches.append(f"stdout: expected {expected['stdout']!r}, got {proc.stdout!r}")
        if "stderr" in expected and proc.stderr != expected["stderr"]:
            mismatches.append(f"stderr: expected {expected['stderr']!r}, got {proc.stderr!r}")
        if "stderr_first_line" in expected:
            actual_first = proc.stderr.splitlines()[0] if proc.stderr.splitlines() else ""
            if actual_first != expected["stderr_first_line"]:
                mismatches.append(
                    f"stderr_first_line: expected {expected['stderr_first_line']!r}, got {actual_first!r}"
                )
        if "argv" in expected and actual_argv != expected["argv"]:
            mismatches.append(f"argv: expected {expected['argv']!r}, got {actual_argv!r}")
        if "stdin" in expected and actual_stdin != expected["stdin"]:
            mismatches.append(f"stdin: expected {expected['stdin']!r}, got {actual_stdin!r}")
        if "script_invoked" in expected and script_invoked != expected["script_invoked"]:
            mismatches.append(f"script_invoked: expected {expected['script_invoked']!r}, got {script_invoked!r}")
        for expected_line in expected.get("stderr_contains", []):
            if expected_line not in proc.stderr:
                mismatches.append(f"stderr_contains: missing {expected_line!r}")

        details = {
            "command": cmd,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "actual_argv": actual_argv,
            "actual_stdin": actual_stdin,
            "script_invoked": script_invoked,
            "mismatches": mismatches,
        }
        return not mismatches, details


def _snapshot_path(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        return {"exists": True, "type": "symlink", "target": os.readlink(path)}
    if not path.exists():
        return {"exists": False}
    if path.is_file():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        st = path.stat()
        return {"exists": True, "type": "file", "size": st.st_size, "sha256": digest}
    if path.is_dir():
        entries: list[dict[str, Any]] = []
        for root, dirs, files in os.walk(path):
            root_path = Path(root)
            for name in sorted(dirs + files):
                full = root_path / name
                rel = full.relative_to(path).as_posix()
                if full.is_symlink():
                    entries.append({"path": rel, "type": "symlink", "target": os.readlink(full)})
                elif full.is_dir():
                    entries.append({"path": rel, "type": "dir"})
                else:
                    st = full.stat()
                    entries.append({"path": rel, "type": "file", "size": st.st_size})
        return {"exists": True, "type": "dir", "entries": entries}
    return {"exists": True, "type": "other"}


def _parse_transcript(stdout_text: str) -> dict[str, Any]:
    result: dict[str, Any] = {"entries": []}
    entry_re = re.compile(r"^ENTRY name=([^ ]+) status=([^ ]+) target=([^ ]+) backup=([^ ]+)$")
    next_re = re.compile(r"^NEXT verify_command=(.+)$")
    for raw in stdout_text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("LONGTASK_CODEX_HOME="):
            result["codex_home"] = line.split("=", 1)[1]
            continue
        if line.startswith("LONGTASK_SOURCE_DIR="):
            result["source_dir"] = line.split("=", 1)[1]
            continue
        if line.startswith("ACTION "):
            result["action"] = line.split(" ", 1)[1]
            continue
        entry_match = entry_re.match(line)
        if entry_match:
            result["entries"].append(
                {
                    "name": entry_match.group(1),
                    "status": entry_match.group(2),
                    "target": entry_match.group(3),
                    "backup": entry_match.group(4),
                }
            )
            continue
        next_match = next_re.match(line)
        if next_match:
            result["next_verify_command"] = next_match.group(1)
    return result


def _run_case_temp_home_shell_script(case: dict[str, Any]) -> tuple[bool, dict[str, Any]]:
    script_path = (REPO_ROOT / case["script_path"]).resolve()
    if not script_path.exists():
        return False, {"error": "missing_script", "script_path": case["script_path"]}

    real_home = Path(os.path.expanduser("~")).resolve()
    real_codex_home = Path(os.environ.get("CODEX_HOME", str(real_home / ".codex"))).resolve()

    with tempfile.TemporaryDirectory(prefix="install-temp-home-") as tmp:
        tmp_root = Path(tmp)
        temp_codex_home = tmp_root / "codex-home"
        temp_codex_home.mkdir(parents=True, exist_ok=True)

        tokens = {
            "SOURCE_DIR": str(REPO_ROOT),
            "TEMP_ROOT": str(tmp_root),
            "TEMP_CODEX_HOME": str(temp_codex_home),
            "BACKUP_ROOT": str(temp_codex_home / "longtask-backups"),
            "REAL_HOME": str(real_home),
            "REAL_CODEX_HOME": str(real_codex_home),
        }

        setup = _expand_tokens(case.get("setup", {}), tokens)
        for d in setup.get("dirs", []):
            (Path(d)).mkdir(parents=True, exist_ok=True)
        for f in setup.get("files", []):
            p = Path(f["path"])
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f.get("content", ""), encoding="utf-8")
        for s in setup.get("symlinks", []):
            p = Path(s["path"])
            p.parent.mkdir(parents=True, exist_ok=True)
            if p.exists() or p.is_symlink():
                p.unlink()
            p.symlink_to(s["target"])

        real_home_probes = [Path(p) for p in _expand_tokens(case.get("real_home_probes", []), tokens)]
        probe_before = {p.as_posix(): _snapshot_path(p) for p in real_home_probes}

        env = os.environ.copy()
        env["HOME"] = str(tmp_root)
        for key, value in _expand_tokens(case.get("env", {}), tokens).items():
            env[str(key)] = str(value)

        args = _expand_tokens(case.get("args", []), tokens)
        cmd = ["bash", str(script_path), *args]
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            env=env,
            text=True,
            capture_output=True,
        )

        probe_after = {p.as_posix(): _snapshot_path(p) for p in real_home_probes}
        real_home_unchanged = probe_before == probe_after

        expected = _expand_tokens(case.get("expected", {}), tokens)
        transcript = _parse_transcript(proc.stdout)
        mismatches: list[str] = []

        if "exit_code" in expected and proc.returncode != expected["exit_code"]:
            mismatches.append(f"exit_code: expected {expected['exit_code']!r}, got {proc.returncode!r}")

        expected_transcript = expected.get("transcript", {})
        if expected_transcript:
            for key in ("codex_home", "source_dir", "action", "next_verify_command"):
                if key in expected_transcript and transcript.get(key) != expected_transcript[key]:
                    mismatches.append(f"transcript.{key}: expected {expected_transcript[key]!r}, got {transcript.get(key)!r}")
            if "entries" in expected_transcript and transcript.get("entries") != expected_transcript["entries"]:
                mismatches.append(
                    f"transcript.entries: expected {expected_transcript['entries']!r}, got {transcript.get('entries')!r}"
                )

        for needle in expected.get("stdout_contains", []):
            if needle not in proc.stdout:
                mismatches.append(f"stdout_contains: missing {needle!r}")
        for needle in expected.get("stderr_contains", []):
            if needle not in proc.stderr:
                mismatches.append(f"stderr_contains: missing {needle!r}")
        for needle in expected.get("stdout_not_contains", []):
            if needle in proc.stdout:
                mismatches.append(f"stdout_not_contains: found unexpected {needle!r}")

        assert_fs = _expand_tokens(case.get("assert_fs", {}), tokens)
        for item in assert_fs.get("path_exists", []):
            if not Path(item).exists() and not Path(item).is_symlink():
                mismatches.append(f"path_exists: missing {item}")
        for item in assert_fs.get("path_absent", []):
            if Path(item).exists() or Path(item).is_symlink():
                mismatches.append(f"path_absent: expected absent {item}")
        for item in assert_fs.get("symlink_targets", []):
            p = Path(item["path"])
            expected_target = item["target"]
            if not p.is_symlink():
                mismatches.append(f"symlink_targets: not a symlink {p}")
                continue
            actual_target = str((p.parent / os.readlink(p)).resolve())
            expected_norm = str(Path(expected_target).resolve())
            if actual_target != expected_norm:
                mismatches.append(f"symlink_targets: expected {p} -> {expected_target}, got {actual_target}")

        if case.get("assert_real_home_unchanged", False) and not real_home_unchanged:
            mismatches.append("real_home_probes_changed")

        details = {
            "command": cmd,
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "transcript": transcript,
            "expected": expected,
            "real_home_probes_before": probe_before,
            "real_home_probes_after": probe_after,
            "real_home_unchanged": real_home_unchanged,
            "mismatches": mismatches,
        }
        return not mismatches, details


CASE_DISPATCH = {
    "schema_parse": _run_case_schema_parse,
    "ref_resolution": _run_case_ref_resolution,
    "duplicate_active_schema_rejection": _run_case_duplicate_rejection,
    "allowed_doc_migration_references": _run_case_allowed_doc_migration,
    "contract_case": _run_case_contract_case,
    "wrapper_exec_case": _run_case_wrapper_exec,
    "temp_home_shell_script_case": _run_case_temp_home_shell_script,
}


def _load_manifest(manifest_path: Path) -> dict[str, Any]:
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Run longtask fixture groups.")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--group", action="append", default=[])
    args = parser.parse_args()

    manifest_path = Path(args.manifest).resolve()
    try:
        manifest = _load_manifest(manifest_path)
    except Exception as exc:  # pragma: no cover
        print(json.dumps({"status": "error", "error": f"manifest_load_failed: {exc}"}), flush=True)
        return 2

    canonical_groups = manifest.get("canonical_groups", [])
    groups = manifest.get("groups", {})
    selected_groups = args.group or canonical_groups
    unknown = sorted(set(selected_groups) - set(canonical_groups))
    if unknown:
        print(
            json.dumps(
                {
                    "status": "error",
                    "error": "unknown_group",
                    "unknown_groups": unknown,
                    "allowed_groups": canonical_groups,
                },
                indent=2,
                sort_keys=True,
            ),
            flush=True,
        )
        return 2

    case_results: list[dict[str, Any]] = []
    group_summary: dict[str, dict[str, int]] = {}
    any_failure = False

    for group_name in selected_groups:
        group_cfg = groups.get(group_name, {})
        case_paths = group_cfg.get("cases", [])
        group_pass = 0
        group_fail = 0
        for case_path in case_paths:
            case_abs = (REPO_ROOT / case_path).resolve()
            case_data = json.loads(case_abs.read_text(encoding="utf-8"))
            case_type = case_data["case_type"]
            handler = CASE_DISPATCH.get(case_type)
            if handler is None:
                result = {
                    "group": group_name,
                    "case_id": case_data.get("case_id", case_abs.name),
                    "case_path": case_path,
                    "pass": False,
                    "error": f"unknown_case_type:{case_type}",
                }
                case_results.append(result)
                any_failure = True
                group_fail += 1
                continue
            passed, details = handler(case_data)
            result = {
                "group": group_name,
                "case_id": case_data.get("case_id", case_abs.name),
                "case_path": case_path,
                "pass": passed,
                "details": details,
            }
            case_results.append(result)
            if passed:
                group_pass += 1
            else:
                group_fail += 1
                any_failure = True
        group_summary[group_name] = {"pass": group_pass, "fail": group_fail, "total": group_pass + group_fail}

    report = {
        "status": "pass" if not any_failure else "fail",
        "manifest_path": manifest_path.relative_to(REPO_ROOT).as_posix(),
        "selected_groups": selected_groups,
        "group_summary": group_summary,
        "case_results": case_results,
    }
    print(json.dumps(report, indent=2, sort_keys=True), flush=True)
    return 0 if not any_failure else 1


if __name__ == "__main__":
    sys.exit(main())

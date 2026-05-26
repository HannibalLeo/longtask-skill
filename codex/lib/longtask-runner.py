#!/usr/bin/env python3
"""Fallback deterministic control plane for the longtask skill.

Native Codex subagents are the preferred path in the Codex app. This runner is
kept for CI/CLI environments where native subagents are unavailable.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from fnmatch import fnmatch
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROMPTS = ROOT / "prompts"
SCHEMAS = ROOT / "schemas"
WRAPPER = ROOT / "lib" / "codex-wrapper.sh"


REQUIRED_FIELDS = {
    "source_requirements",
    "goals",
    "file_scope",
    "do_not_touch",
    "verify_cmd",
    "verify_passes_when",
    "dod",
}

FINAL_COMMAND_KEYS = ("final_verify_cmd", "final_e2e2_cmd", "final_smoke_cmd")

DANGEROUS_COMMAND_PATTERNS = [
    r"\bgit\s+push\b",
    r"\bgh\s+pr\s+create\b",
    r"\bgh\s+release\b",
    r"\b(vercel|netlify|fly|railway)\s+deploy\b",
    r"\bdocker\s+push\b",
    r"\bkubectl\s+(apply|delete|rollout)\b",
    r"\bterraform\s+apply\b",
]


@dataclass
class Phase:
    name: str
    title: str
    block: str
    fields: dict[str, Any] = field(default_factory=dict)

    @property
    def goals(self) -> str:
        return str(self.fields.get("goals", "")).strip()

    @property
    def file_scope(self) -> list[str]:
        return as_list(self.fields.get("file_scope", []))

    @property
    def do_not_touch(self) -> list[str]:
        return as_list(self.fields.get("do_not_touch", []))

    @property
    def verify_cmd(self) -> str:
        return str(self.fields.get("verify_cmd", "")).strip()

    @property
    def verify_passes_when(self) -> str:
        return str(self.fields.get("verify_passes_when", "")).strip()

    @property
    def max_retry_rounds(self) -> int:
        value = self.fields.get("max_retry_rounds", 3)
        try:
            return max(1, int(value))
        except Exception:
            return 3


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    text = str(value).strip()
    if not text:
        return []
    if text.startswith("[") and text.endswith("]"):
        return [str(item).strip() for item in parse_value(text)]
    return [text]


def parse_value(raw: str) -> Any:
    text = raw.strip()
    if not text:
        return ""
    if text in {"true", "True"}:
        return True
    if text in {"false", "False"}:
        return False
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if text.startswith("[") and text.endswith("]"):
        try:
            value = ast.literal_eval(text)
            if isinstance(value, list):
                return value
        except Exception:
            inner = text[1:-1].strip()
            if not inner:
                return []
            return [part.strip().strip("'\"") for part in inner.split(",")]
    if (text.startswith('"') and text.endswith('"')) or (
        text.startswith("'") and text.endswith("'")
    ):
        return text[1:-1]
    return text


def parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    raw = text[4:end]
    meta: dict[str, Any] = {}
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        meta[key.strip()] = parse_value(value)
    return meta, text[end + 5 :]


def parse_fields(block: str) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", stripped)
        if not match:
            continue
        key, value = match.groups()
        fields[key] = parse_value(value)
    return fields


def parse_spec(spec_path: Path) -> tuple[dict[str, Any], list[Phase]]:
    text = spec_path.read_text(encoding="utf-8")
    meta, body = parse_frontmatter(text)
    matches = list(re.finditer(r"(?m)^(#{1,6})\s*(P\d+)\b[:\-\s]*(.*)$", body))
    phases: list[Phase] = []
    for index, match in enumerate(matches):
        start = match.start()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        block = body[start:end].strip()
        name = match.group(2)
        title = match.group(3).strip()
        phases.append(Phase(name=name, title=title, block=block, fields=parse_fields(block)))
    return meta, phases


def dangerous_command_reason(command: str) -> str | None:
    for pattern in DANGEROUS_COMMAND_PATTERNS:
        if re.search(pattern, command):
            return pattern
    return None


def validate_spec_contract(meta: dict[str, Any], phases: list[Phase]) -> list[str]:
    errors: list[str] = []
    for phase in phases:
        missing = sorted(REQUIRED_FIELDS - set(phase.fields))
        if missing:
            errors.append(f"{phase.name}: missing {', '.join(missing)}")
        reason = dangerous_command_reason(phase.verify_cmd)
        if reason:
            errors.append(f"{phase.name}: verify_cmd contains externally visible action ({reason})")
    for key in FINAL_COMMAND_KEYS:
        command = str(meta.get(key, "")).strip()
        reason = dangerous_command_reason(command)
        if reason:
            errors.append(f"{key} contains externally visible action ({reason})")
    if not meta.get("source_spec_path"):
        errors.append("missing source_spec_path")
    if not meta.get("source_spec_sha256"):
        errors.append("missing source_spec_sha256")
    if not meta.get("final_verify_cmd"):
        errors.append("missing final_verify_cmd")
    if not meta.get("final_e2e2_cmd") and not meta.get("final_smoke_cmd"):
        errors.append("missing final E2E2 gate: set final_e2e2_cmd or an explicitly equivalent final_smoke_cmd")
    if not meta.get("final_report_path"):
        errors.append("missing final_report_path")
    return errors


def run(cmd: list[str], cwd: Path, check: bool = True, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stdout}")
    return proc


def git_root(repo: Path) -> Path:
    proc = run(["git", "rev-parse", "--show-toplevel"], repo)
    return Path(proc.stdout.strip())


def spec_sha(spec_path: Path) -> str:
    return hashlib.sha256(spec_path.read_bytes()).hexdigest()


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=str(path.parent), delete=False
    ) as tmp:
        json.dump(data, tmp, ensure_ascii=False, indent=2, sort_keys=True)
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    tmp_path.replace(path)


def clean_goal(goal: str) -> str:
    goal = re.sub(r"\s+", " ", goal.strip())
    if not goal:
        return "phase"
    return goal[:72]


def render_template(path: Path, values: dict[str, str]) -> str:
    text = path.read_text(encoding="utf-8")
    for key, value in values.items():
        text = text.replace("{" + key + "}", value)
    return text


def status_paths(repo: Path, ignore_paths: set[str] | None = None) -> list[str]:
    ignore_paths = ignore_paths or set()
    proc = run(["git", "status", "--porcelain=v1"], repo)
    paths: list[str] = []
    for line in proc.stdout.splitlines():
        if not line:
            continue
        path = line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        if path.startswith(".longtask/"):
            continue
        if path in ignore_paths:
            continue
        paths.append(path)
    return sorted(set(paths))


def diff_text(repo: Path) -> str:
    status = run(["git", "status", "--short"], repo).stdout
    diff = run(["git", "diff", "HEAD", "--"], repo).stdout
    return f"git status --short:\n{status}\n\ngit diff HEAD:\n{diff}"


def matches_any(path: str, patterns: list[str]) -> bool:
    if not patterns:
        return False
    normalized = path.replace(os.sep, "/")
    for pattern in patterns:
        p = pattern.strip().replace(os.sep, "/")
        if not p:
            continue
        if p.endswith("/**") and normalized.startswith(p[:-3].rstrip("/") + "/"):
            return True
        if p.endswith("/") and normalized.startswith(p):
            return True
        if fnmatch(normalized, p) or fnmatch(normalized, p.lstrip("./")):
            return True
        if normalized == p or normalized.startswith(p.rstrip("/") + "/"):
            return True
    return False


def validate_scope(phase: Phase, changed: list[str]) -> list[str]:
    violations: list[str] = []
    for path in changed:
        if matches_any(path, phase.do_not_touch):
            violations.append(f"{path} matches do_not_touch")
        if not matches_any(path, phase.file_scope):
            violations.append(f"{path} is outside file_scope")
    return violations


def invoke_codex(
    repo: Path,
    prompt: str,
    run_id: str,
    log_path: Path,
    schema_path: Path | None = None,
    last_message_path: Path | None = None,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path = log_path.with_suffix(".prompt.md")
    prompt_path.write_text(prompt, encoding="utf-8")
    env = os.environ.copy()
    env["CODEX_LONGTASK_REPO"] = str(repo)
    cmd = ["bash", str(WRAPPER), str(prompt_path), run_id]
    if schema_path is not None:
        cmd.append(str(schema_path))
    if last_message_path is not None:
        cmd.append(str(last_message_path))
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            cmd,
            cwd=str(repo),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
            log.write(line)
        return proc.wait()


def verifier_passes(result: dict[str, Any]) -> tuple[bool, str]:
    dod = result.get("dod_results") or []
    all_dod = bool(dod) and all(bool(item.get("passed")) for item in dod)
    no_hacking = not result.get("reward_hacking_signals")
    verdict_pass = result.get("verdict") == "PASS"
    exit_zero = result.get("verify_cmd_exit") == 0
    if verdict_pass and all_dod and no_hacking and exit_zero:
        return True, "PASS"
    if verdict_pass and not all_dod:
        return False, "VERIFIER_INCONSISTENT_PASS_BUT_DOD_FAIL"
    if not verdict_pass and all_dod and no_hacking and exit_zero:
        return False, "VERIFIER_INCONSISTENT_FAIL_BUT_EVIDENCE_PASS"
    if result.get("reward_hacking_signals"):
        return False, "REWARD_HACKING_SIGNAL"
    return False, "FAIL"


def validate_verifier_result(result: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(result, dict):
        return ["result is not a JSON object"]
    required = {
        "verdict": str,
        "summary": str,
        "verify_cmd_exit": int,
        "verify_cmd_excerpt": str,
        "reward_hacking_signals": list,
        "dod_results": list,
        "root_cause_hint": str,
    }
    for key, expected_type in required.items():
        if key not in result:
            errors.append(f"missing {key}")
        elif not isinstance(result[key], expected_type):
            errors.append(f"{key} has wrong type")
    if result.get("verdict") not in {"PASS", "FAIL"}:
        errors.append("verdict must be PASS or FAIL")
    dod = result.get("dod_results")
    if isinstance(dod, list):
        if not dod:
            errors.append("dod_results must not be empty")
        for index, item in enumerate(dod):
            if not isinstance(item, dict):
                errors.append(f"dod_results[{index}] is not an object")
                continue
            for key in ("bullet", "passed", "evidence"):
                if key not in item:
                    errors.append(f"dod_results[{index}] missing {key}")
            if "passed" in item and not isinstance(item["passed"], bool):
                errors.append(f"dod_results[{index}].passed has wrong type")
    return errors


def ensure_clean_workspace(repo: Path, allow_dirty: bool, ignore_paths: set[str]) -> None:
    changed = status_paths(repo, ignore_paths)
    if changed and not allow_dirty:
        joined = "\n".join(f"  {path}" for path in changed[:50])
        raise RuntimeError(
            "workspace has pre-existing changes; use an isolated worktree or --allow-dirty:\n"
            + joined
        )


def phase_by_name(phases: list[Phase], name: str) -> int:
    for index, phase in enumerate(phases):
        if phase.name == name:
            return index
    raise RuntimeError(f"unknown phase: {name}")


def dry_run(spec_path: Path, meta: dict[str, Any], phases: list[Phase]) -> int:
    print(f"Spec: {spec_path}")
    print(f"Phases: {', '.join(phase.name for phase in phases) or '<none>'}")
    print(
        "Top-level: "
        f"final_verify_cmd={bool(meta.get('final_verify_cmd'))} "
        f"final_e2e2_cmd={bool(meta.get('final_e2e2_cmd'))} "
        f"final_smoke_cmd={bool(meta.get('final_smoke_cmd'))} "
        f"final_report_path={bool(meta.get('final_report_path'))}"
    )
    errors = validate_spec_contract(meta, phases)
    for phase in phases:
        print(f"- {phase.name}: {phase.goals or phase.title}")
        print(f"  scope: {phase.file_scope}")
        print(f"  verify: {phase.verify_cmd}")
    if errors:
        print("DRY-RUN FAIL")
        for error in errors:
            print(f"- {error}")
        return 1
    print("DRY-RUN OK - no codex/git side effects.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a normalized longtask implementation plan/execution spec.")
    parser.add_argument("spec", type=Path)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--from", dest="from_phase")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--no-commit", action="store_true")
    args = parser.parse_args()

    repo = git_root(args.repo.resolve())
    spec_path = args.spec.resolve()
    if not spec_path.exists():
        raise RuntimeError(f"spec not found: {spec_path}")
    ignore_paths: set[str] = set()
    try:
        ignore_paths.add(spec_path.relative_to(repo).as_posix())
    except ValueError:
        pass

    meta, phases = parse_spec(spec_path)
    if not phases:
        raise RuntimeError("spec contains no Pn phases")
    contract_errors = validate_spec_contract(meta, phases)
    if args.dry_run:
        return dry_run(spec_path, meta, phases)
    if contract_errors:
        raise RuntimeError("invalid spec contract:\n" + "\n".join(f"- {error}" for error in contract_errors))

    ensure_clean_workspace(repo, args.allow_dirty or args.resume, ignore_paths)

    spec_base = spec_path.stem
    state_path = repo / ".longtask" / "state" / f"{spec_base}.json"
    logs_dir = repo / ".longtask" / "logs" / spec_base
    reports_dir = repo / ".longtask" / "reports" / spec_base
    state = load_json(
        state_path,
        {
            "mode": "exec-fallback",
            "spec_path": str(spec_path),
            "spec_sha256": spec_sha(spec_path),
            "source_spec_path": str(meta.get("source_spec_path", "")),
            "source_spec_sha256": str(meta.get("source_spec_sha256", "")),
            "implementation_plan_path": str(spec_path),
            "implementation_plan_sha256": spec_sha(spec_path),
            "base_head": run(["git", "rev-parse", "HEAD"], repo).stdout.strip(),
            "started_at": now_iso(),
            "phases": {},
        },
    )
    if state.get("spec_sha256") != spec_sha(spec_path):
        if args.resume:
            raise RuntimeError("spec changed since state was written; restart without --resume")
        state = {
            "mode": "exec-fallback",
            "spec_path": str(spec_path),
            "spec_sha256": spec_sha(spec_path),
            "source_spec_path": str(meta.get("source_spec_path", "")),
            "source_spec_sha256": str(meta.get("source_spec_sha256", "")),
            "implementation_plan_path": str(spec_path),
            "implementation_plan_sha256": spec_sha(spec_path),
            "base_head": run(["git", "rev-parse", "HEAD"], repo).stdout.strip(),
            "started_at": now_iso(),
            "phases": {},
        }
    atomic_write_json(state_path, state)

    start_index = phase_by_name(phases, args.from_phase) if args.from_phase else 0
    last_result: dict[str, Any] | None = None
    last_changed_paths = ""

    for phase in phases[start_index:]:
        phase_state = state["phases"].setdefault(phase.name, {"status": "PENDING"})
        if args.resume and phase_state.get("status") == "PASS":
            print(f"{phase.name} already PASS; skipping")
            continue

        missing = sorted(REQUIRED_FIELDS - set(phase.fields))
        if missing:
            raise RuntimeError(f"{phase.name} missing required fields: {', '.join(missing)}")

        print(f"== {phase.name} starting: {phase.goals or phase.title}")
        phase_state.update({"status": "RUNNING", "started_at": now_iso(), "rounds": 0})
        atomic_write_json(state_path, state)

        passed = False
        for round_no in range(1, phase.max_retry_rounds + 1):
            phase_state["rounds"] = round_no
            phase_state["last_heartbeat"] = now_iso()
            atomic_write_json(state_path, state)

            values = {
                "Pn": phase.name,
                "spec_path": str(spec_path),
                "repo_root": str(repo),
                "phase_block": phase.block,
            }
            worker_prompt = render_template(PROMPTS / "worker.md", values)
            if round_no > 1 and last_result is not None:
                retry_prefix = render_template(
                    PROMPTS / "retry-worker.md",
                    {
                        "Pn": phase.name,
                        "N-1": str(round_no - 1),
                        "max": str(phase.max_retry_rounds),
                        "verifier_json": json.dumps(last_result, ensure_ascii=False, indent=2),
                        "changed_paths": last_changed_paths,
                    },
                )
                worker_prompt = retry_prefix + "\n\n" + worker_prompt

            print(f"-- {phase.name} round {round_no}/{phase.max_retry_rounds}: worker")
            worker_exit = invoke_codex(
                repo,
                worker_prompt,
                f"{spec_base}-{phase.name}-r{round_no}-worker",
                logs_dir / f"{phase.name}-r{round_no}-worker.jsonl",
            )
            if worker_exit != 0:
                phase_state.update({"status": "BLOCKED", "reason": f"WORKER_EXIT_{worker_exit}"})
                atomic_write_json(state_path, state)
                return worker_exit

            abort_log = Path(f"/tmp/{phase.name}-abort.log")
            if abort_log.exists():
                reason = abort_log.read_text(encoding="utf-8", errors="replace").strip()
                phase_state.update({"status": "BLOCKED", "reason": "WORKER_ABORT", "detail": reason})
                atomic_write_json(state_path, state)
                print(f"{phase.name} BLOCKED: {reason}")
                return 1

            changed = status_paths(repo, ignore_paths)
            if not changed:
                phase_state.update({"status": "BLOCKED", "reason": "NO_DIFF"})
                atomic_write_json(state_path, state)
                print(f"{phase.name} BLOCKED: worker produced no code diff")
                return 1

            violations = validate_scope(phase, changed)
            if violations:
                report_path = reports_dir / f"{phase.name}-scope-violation.md"
                report_path.parent.mkdir(parents=True, exist_ok=True)
                report_path.write_text("\n".join(f"- {item}" for item in violations) + "\n", encoding="utf-8")
                phase_state.update({"status": "ESCALATE", "reason": "SCOPE_VIOLATION", "report": str(report_path)})
                atomic_write_json(state_path, state)
                print(f"{phase.name} ESCALATE: scope violation, see {report_path}")
                return 1

            before_b = status_paths(repo, ignore_paths)
            last_changed_paths = "\n".join(changed)
            verifier_values = {
                "Pn": phase.name,
                "spec_path": str(spec_path),
                "repo_root": str(repo),
                "phase_block": phase.block,
                "verify_cmd": phase.verify_cmd,
                "verify_passes_when": phase.verify_passes_when,
                "changed_paths": last_changed_paths,
            }
            verifier_prompt = render_template(PROMPTS / "verifier.md", verifier_values)
            verdict_path = reports_dir / f"{phase.name}-r{round_no}-verdict.json"

            print(f"-- {phase.name} round {round_no}/{phase.max_retry_rounds}: verifier")
            verifier_exit = invoke_codex(
                repo,
                verifier_prompt,
                f"{spec_base}-{phase.name}-r{round_no}-verifier",
                logs_dir / f"{phase.name}-r{round_no}-verifier.jsonl",
                SCHEMAS / "verifier-result.schema.json",
                verdict_path,
            )
            if verifier_exit != 0:
                phase_state.update({"status": "BLOCKED", "reason": f"VERIFIER_EXIT_{verifier_exit}"})
                atomic_write_json(state_path, state)
                return verifier_exit

            after_b = status_paths(repo, ignore_paths)
            if after_b != before_b:
                phase_state.update({"status": "ESCALATE", "reason": "VERIFIER_MUTATED_WORKTREE"})
                atomic_write_json(state_path, state)
                print(f"{phase.name} ESCALATE: verifier changed the worktree")
                return 1

            try:
                last_result = json.loads(verdict_path.read_text(encoding="utf-8"))
            except Exception as exc:
                phase_state.update({"status": "ESCALATE", "reason": "VERIFIER_MALFORMED_JSON", "detail": str(exc)})
                atomic_write_json(state_path, state)
                print(f"{phase.name} ESCALATE: verifier wrote malformed JSON")
                return 1
            verifier_errors = validate_verifier_result(last_result)
            if verifier_errors:
                phase_state.update(
                    {
                        "status": "ESCALATE",
                        "reason": "VERIFIER_SCHEMA_INVALID",
                        "detail": verifier_errors,
                        "verdict": str(verdict_path),
                    }
                )
                atomic_write_json(state_path, state)
                print(f"{phase.name} ESCALATE: verifier JSON failed schema checks")
                return 1
            ok, reason = verifier_passes(last_result)
            if ok:
                if args.no_commit:
                    commit = "<no-commit>"
                else:
                    run(["git", "add", "--", *changed], repo)
                    message = f"[longtask:{spec_base}:{phase.name}] {clean_goal(phase.goals or phase.title)}"
                    run(["git", "commit", "-m", message], repo)
                    commit = run(["git", "rev-parse", "--short", "HEAD"], repo).stdout.strip()
                phase_state.update(
                    {
                        "status": "PASS",
                        "completed_at": now_iso(),
                        "commit": commit,
                        "changed_files": changed,
                        "verdict": str(verdict_path),
                    }
                )
                atomic_write_json(state_path, state)
                print(f"== {phase.name} PASS commit={commit}")
                passed = True
                if args.no_commit:
                    state["stopped_after"] = phase.name
                    state["stop_reason"] = "NO_COMMIT"
                    atomic_write_json(state_path, state)
                    print("--no-commit requested; stopping before later phases")
                    return 0
                break

            print(f"-- {phase.name} round {round_no} verifier result: {reason}")
            phase_state.update({"status": "RETRYING", "last_failure": reason, "verdict": str(verdict_path)})
            atomic_write_json(state_path, state)

        if not passed:
            report_path = reports_dir / f"{phase.name}-blocked.md"
            report_path.parent.mkdir(parents=True, exist_ok=True)
            report_path.write_text(
                f"# {phase.name} blocked\n\n"
                f"Rounds: {phase.max_retry_rounds}\n\n"
                f"Last verifier result:\n\n```json\n"
                f"{json.dumps(last_result or {}, ensure_ascii=False, indent=2)}\n```\n",
                encoding="utf-8",
            )
            phase_state.update({"status": "BLOCKED", "reason": "MAX_RETRIES", "report": str(report_path)})
            atomic_write_json(state_path, state)
            print(f"{phase.name} BLOCKED: see {report_path}")
            return 1

    final_results: list[dict[str, Any]] = []
    final_commands: list[tuple[str, Any]] = [("final_verify_cmd", meta.get("final_verify_cmd"))]
    if meta.get("final_e2e2_cmd"):
        final_commands.append(("final_e2e2_cmd", meta.get("final_e2e2_cmd")))
    else:
        final_commands.append(("final_smoke_cmd", meta.get("final_smoke_cmd")))
    for key, final_cmd in final_commands:
        if not final_cmd:
            raise RuntimeError(f"missing required final command: {key}")
        print(f"== {key}: {final_cmd}")
        proc = subprocess.run(str(final_cmd), cwd=str(repo), shell=True)
        final_results.append(
            {
                "type": key,
                "cmd": str(final_cmd),
                "exit_code": proc.returncode,
                "completed_at": now_iso(),
            }
        )
        state["final_verification"] = final_results
        atomic_write_json(state_path, state)
        if proc.returncode != 0:
            print(f"{key} failed")
            return proc.returncode

    state["completed_at"] = now_iso()
    atomic_write_json(state_path, state)
    print(f"LONGTASK PASS state={state_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"longtask-runner: {exc}", file=sys.stderr)
        raise SystemExit(1)

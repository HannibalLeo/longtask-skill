#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/install-codex.sh [--source-dir DIR] [--codex-home DIR] [--dry-run] [--force-backup] [--backup-conflicts] [--help]

Install only:
  ${CODEX_HOME}/skills/codex-longtask
  ${CODEX_HOME}/skills/codex-longtask-code
EOF
}

abspath() {
  python3 - "$1" <<'PY'
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

resolve_symlink_abs_target() {
  python3 - "$1" <<'PY'
import os,sys
path=sys.argv[1]
if not os.path.islink(path):
    print("")
    raise SystemExit(0)
raw=os.readlink(path)
base=os.path.dirname(path)
print(os.path.abspath(os.path.join(base, raw)))
PY
}

is_within_dir() {
  python3 - "$1" "$2" <<'PY'
import os,sys
path=os.path.abspath(sys.argv[1])
base=os.path.abspath(sys.argv[2])
try:
    common=os.path.commonpath([path, base])
except ValueError:
    print("false")
    raise SystemExit(0)
print("true" if common == base else "false")
PY
}

SOURCE_DIR="${PWD}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
DRY_RUN=0
FORCE_BACKUP=0
BACKUP_CONFLICTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-dir)
      [[ $# -ge 2 ]] || { echo "missing value for --source-dir" >&2; exit 2; }
      SOURCE_DIR="$2"
      shift 2
      ;;
    --codex-home)
      [[ $# -ge 2 ]] || { echo "missing value for --codex-home" >&2; exit 2; }
      CODEX_HOME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force-backup)
      FORCE_BACKUP=1
      shift
      ;;
    --backup-conflicts)
      BACKUP_CONFLICTS=1
      shift
      ;;
    --force)
      FORCE_BACKUP=1
      echo "WARNING deprecated_flag=--force use=--force-backup" >&2
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SOURCE_DIR="$(abspath "$SOURCE_DIR")"
CODEX_HOME="$(abspath "$CODEX_HOME")"
SKILLS_DIR="${CODEX_HOME}/skills"
BACKUP_ROOT="${CODEX_HOME}/longtask-backups"
RUN_BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%dT%H%M%S)"
if [[ -n "${LONGTASK_BACKUP_STAMP:-}" ]]; then
  RUN_BACKUP_DIR="${BACKUP_ROOT}/${LONGTASK_BACKUP_STAMP}"
fi

action="install"
if [[ "$DRY_RUN" -eq 1 ]]; then
  action="dry-run"
fi

echo "LONGTASK_CODEX_HOME=${CODEX_HOME}"
echo "LONGTASK_SOURCE_DIR=${SOURCE_DIR}"
echo "ACTION ${action}"

mkdir -p "${SKILLS_DIR}"
if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "${BACKUP_ROOT}"
fi

overall_rc=0
skills=(codex-longtask codex-longtask-code)

for skill in "${skills[@]}"; do
  src="${SOURCE_DIR}/skills/${skill}"
  dst="${SKILLS_DIR}/${skill}"
  status=""
  backup_path="null"

  if [[ "$(is_within_dir "$dst" "$CODEX_HOME")" != "true" ]]; then
    status="ERROR_PATH_ESCAPE"
    overall_rc=1
    echo "ENTRY name=${skill} status=${status} target=null backup=null"
    continue
  fi

  if [[ ! -e "$dst" && ! -L "$dst" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      status="SKIPPED_DRY_RUN"
      echo "ENTRY name=${skill} status=${status} target=${src} backup=null"
      continue
    fi
    ln -s "$src" "$dst"
    status="INSTALLED"
    echo "ENTRY name=${skill} status=${status} target=${src} backup=null"
    continue
  fi

  if [[ -L "$dst" ]]; then
    resolved_target="$(resolve_symlink_abs_target "$dst")"
    if [[ "$resolved_target" == "$src" ]]; then
      status="UNCHANGED"
      echo "ENTRY name=${skill} status=${status} target=${src} backup=null"
      continue
    fi
    if [[ "$(is_within_dir "$resolved_target" "$SOURCE_DIR")" == "true" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        status="SKIPPED_DRY_RUN"
        echo "ENTRY name=${skill} status=${status} target=${src} backup=null"
        continue
      fi
      rm -f "$dst"
      ln -s "$src" "$dst"
      status="REPLACED_OWNED"
      echo "ENTRY name=${skill} status=${status} target=${src} backup=null"
      continue
    fi
    if [[ "$FORCE_BACKUP" -eq 1 && "$BACKUP_CONFLICTS" -eq 1 ]]; then
      backup_path="${RUN_BACKUP_DIR}/${skill}.bak"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        status="SKIPPED_DRY_RUN"
        echo "ENTRY name=${skill} status=${status} target=${src} backup=${backup_path}"
        continue
      fi
      mkdir -p "$RUN_BACKUP_DIR"
      mv "$dst" "$backup_path"
      ln -s "$src" "$dst"
      status="BACKED_UP_CONFLICT"
      echo "ENTRY name=${skill} status=${status} target=${src} backup=${backup_path}"
      continue
    fi
    status="CONFLICT_FOREIGN_SYMLINK"
    overall_rc=1
    echo "ENTRY name=${skill} status=${status} target=${resolved_target:-null} backup=null"
    continue
  fi

  if [[ "$FORCE_BACKUP" -eq 1 && "$BACKUP_CONFLICTS" -eq 1 ]]; then
    backup_path="${RUN_BACKUP_DIR}/${skill}.bak"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      status="SKIPPED_DRY_RUN"
      echo "ENTRY name=${skill} status=${status} target=${src} backup=${backup_path}"
      continue
    fi
    mkdir -p "$RUN_BACKUP_DIR"
    mv "$dst" "$backup_path"
    ln -s "$src" "$dst"
    status="BACKED_UP_CONFLICT"
    echo "ENTRY name=${skill} status=${status} target=${src} backup=${backup_path}"
    continue
  fi

  status="CONFLICT_NON_SYMLINK"
  overall_rc=1
  echo "ENTRY name=${skill} status=${status} target=${dst} backup=null"
done

echo "NEXT verify_command=bash scripts/run-fixtures.sh --group install-temp-home-safety"
exit "$overall_rc"

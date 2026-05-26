#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/uninstall-codex.sh [--source-dir DIR] [--codex-home DIR] [--dry-run] [--restore-backup DIR] [--help]
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
RESTORE_BACKUP=""

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
    --restore-backup)
      [[ $# -ge 2 ]] || { echo "missing value for --restore-backup" >&2; exit 2; }
      RESTORE_BACKUP="$2"
      shift 2
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
if [[ -n "$RESTORE_BACKUP" ]]; then
  RESTORE_BACKUP="$(abspath "$RESTORE_BACKUP")"
fi

action="uninstall"
if [[ -n "$RESTORE_BACKUP" ]]; then
  action="restore"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  action="dry-run"
fi

echo "LONGTASK_CODEX_HOME=${CODEX_HOME}"
echo "LONGTASK_SOURCE_DIR=${SOURCE_DIR}"
echo "ACTION ${action}"

overall_rc=0
skills=(codex-longtask codex-longtask-code)

if [[ -n "$RESTORE_BACKUP" ]]; then
  if [[ "$(is_within_dir "$RESTORE_BACKUP" "$BACKUP_ROOT")" != "true" ]]; then
    for skill in "${skills[@]}"; do
      echo "ENTRY name=${skill} status=ERROR_PATH_ESCAPE target=null backup=${RESTORE_BACKUP}"
    done
    echo "NEXT verify_command=bash scripts/run-fixtures.sh --group install-temp-home-safety"
    exit 1
  fi

  for skill in "${skills[@]}"; do
    dst="${SKILLS_DIR}/${skill}"
    backup_path="${RESTORE_BACKUP}/${skill}.bak"

    if [[ ! -e "$backup_path" && ! -L "$backup_path" ]]; then
      echo "ENTRY name=${skill} status=SKIPPED_ABSENT target=null backup=${backup_path}"
      continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "ENTRY name=${skill} status=SKIPPED_DRY_RUN target=${dst} backup=${backup_path}"
      continue
    fi

    if [[ -L "$dst" ]]; then
      resolved_target="$(resolve_symlink_abs_target "$dst")"
      if [[ "$(is_within_dir "$resolved_target" "$SOURCE_DIR")" == "true" ]]; then
        rm -f "$dst"
      else
        echo "ENTRY name=${skill} status=SKIPPED_FOREIGN target=${resolved_target:-null} backup=${backup_path}"
        continue
      fi
    elif [[ -e "$dst" ]]; then
      echo "ENTRY name=${skill} status=SKIPPED_NON_SYMLINK target=${dst} backup=${backup_path}"
      continue
    fi

    mv "$backup_path" "$dst"
    echo "ENTRY name=${skill} status=RESTORED_BACKUP target=${dst} backup=${backup_path}"
  done

  echo "NEXT verify_command=bash scripts/run-fixtures.sh --group install-temp-home-safety"
  exit "$overall_rc"
fi

for skill in "${skills[@]}"; do
  dst="${SKILLS_DIR}/${skill}"

  if [[ "$(is_within_dir "$dst" "$CODEX_HOME")" != "true" ]]; then
    echo "ENTRY name=${skill} status=ERROR_PATH_ESCAPE target=null backup=null"
    overall_rc=1
    continue
  fi

  if [[ ! -e "$dst" && ! -L "$dst" ]]; then
    echo "ENTRY name=${skill} status=SKIPPED_ABSENT target=null backup=null"
    continue
  fi

  if [[ ! -L "$dst" ]]; then
    echo "ENTRY name=${skill} status=SKIPPED_NON_SYMLINK target=${dst} backup=null"
    continue
  fi

  resolved_target="$(resolve_symlink_abs_target "$dst")"
  if [[ "$(is_within_dir "$resolved_target" "$SOURCE_DIR")" != "true" ]]; then
    echo "ENTRY name=${skill} status=SKIPPED_FOREIGN target=${resolved_target:-null} backup=null"
    continue
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "ENTRY name=${skill} status=SKIPPED_DRY_RUN target=${dst} backup=null"
    continue
  fi

  rm -f "$dst"
  echo "ENTRY name=${skill} status=REMOVED target=${dst} backup=null"
done

echo "NEXT verify_command=bash scripts/run-fixtures.sh --group install-temp-home-safety"
exit "$overall_rc"

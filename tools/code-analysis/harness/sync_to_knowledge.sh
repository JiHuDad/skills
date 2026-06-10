#!/usr/bin/env bash
# sync_to_knowledge.sh — Copy sdd-export/joern/ to the knowledge-layer repo.
#
# Usage (run from knowledge-layer repo root):
#   bash /path/to/block-ws/tools/code-analysis/harness/sync_to_knowledge.sh \
#        --src  /path/to/block-ws/sdd-export/joern \
#        --dest sdd/joern
#
# Options:
#   --src  <path>     sdd-export/joern directory in block workspace (required)
#   --dest <path>     destination directory in knowledge-layer repo (required)
#   --auto-commit     commit after sync without prompting (default: prompt)
#   --max-age <days>  warn if manifest source_commit is N+ commits behind HEAD
#                     (default: 20)
set -euo pipefail

SRC=""
DEST=""
AUTO_COMMIT=0
MAX_AGE=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)         SRC="$2";        shift 2 ;;
    --dest)        DEST="$2";       shift 2 ;;
    --auto-commit) AUTO_COMMIT=1;   shift   ;;
    --max-age)     MAX_AGE="$2";    shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

err()  { echo "ERROR: $*" >&2; }
info() { echo "INFO:  $*"; }
warn() { echo "WARN:  $*"; }

if [[ -z "$SRC" || -z "$DEST" ]]; then
  echo "Usage: sync_to_knowledge.sh --src <block-ws>/sdd-export/joern --dest sdd/joern" >&2
  exit 1
fi
if [[ ! -d "$SRC" ]]; then
  err "Source directory not found: $SRC"
  err "Run export_analysis.sh in block workspace first."
  exit 1
fi

# ── freshness check ──────────────────────────────────────────────────────────
MANIFEST="$SRC/manifest.json"
if [[ -f "$MANIFEST" ]]; then
  SOURCE_COMMIT=$(python3 -c "import json,sys; d=json.load(open('$MANIFEST')); print(d.get('source_commit','unknown'))")
  GENERATED=$(python3 -c "import json,sys; d=json.load(open('$MANIFEST')); print(d.get('generated','unknown'))")
  CPG_SHA=$(python3 -c "import json,sys; d=json.load(open('$MANIFEST')); print(d.get('cpg_sha256','unknown'))")

  info "Manifest: generated=$GENERATED, source=$SOURCE_COMMIT, cpg=$CPG_SHA"

  if [[ "$SOURCE_COMMIT" != "unknown" ]]; then
    # Check how many commits the block-ws source is behind its HEAD
    BEHIND=$(git -C "$SRC" rev-list "${SOURCE_COMMIT}..HEAD" --count 2>/dev/null \
             || git rev-list "${SOURCE_COMMIT}..HEAD" --count 2>/dev/null \
             || echo "unknown")

    if [[ "$BEHIND" =~ ^[0-9]+$ && "$BEHIND" -gt "$MAX_AGE" ]]; then
      warn "분석이 소스 HEAD보다 ${BEHIND}커밋 뒤처져 있습니다 (기준: ${MAX_AGE})."
      warn "block workspace에서 gen_cpg.sh + export_analysis.sh를 다시 실행 권장."
      echo ""
      read -r -p "계속 진행하시겠습니까? [y/N] " REPLY
      if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "중단됨."; exit 0
      fi
    elif [[ "$BEHIND" =~ ^[0-9]+$ && "$BEHIND" -gt 0 ]]; then
      info "분석이 ${BEHIND}커밋 뒤처져 있습니다. (허용 범위 내)"
    else
      info "신선도 확인: 최신 상태"
    fi
  fi
else
  warn "manifest.json 없음 — 신선도 확인 불가."
fi

# ── rsync ────────────────────────────────────────────────────────────────────
mkdir -p "$DEST"

info "동기화 중: $SRC → $DEST"
rsync -av --delete "$SRC"/ "$DEST"/

# ── diff summary ─────────────────────────────────────────────────────────────
echo ""
info "변경 요약 (git diff --stat):"
git diff --stat "$DEST" 2>/dev/null || true

CHANGED_FILES=$(git status --short "$DEST" 2>/dev/null | wc -l | tr -d ' ')

if [[ "$CHANGED_FILES" -eq 0 ]]; then
  info "변경 없음 — 지식층이 이미 최신 상태입니다."
  exit 0
fi

# ── commit ───────────────────────────────────────────────────────────────────
if [[ "$AUTO_COMMIT" -eq 1 ]]; then
  REPLY="y"
else
  echo ""
  read -r -p "변경된 ${CHANGED_FILES}개 파일을 커밋하시겠습니까? [y/N] " REPLY
fi

if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  git add "$DEST"
  git commit -m "$(cat <<EOF
sync: joern analysis from block-ws @${SOURCE_COMMIT:-unknown}

generated: ${GENERATED:-unknown}
cpg_sha256: ${CPG_SHA:-unknown}
files changed: ${CHANGED_FILES}
EOF
)"
  info "커밋 완료."
else
  info "커밋 건너뜀. 수동으로 검토 후 커밋하세요:"
  echo "  git add $DEST"
  echo "  git commit -m 'sync: joern analysis @${SOURCE_COMMIT:-unknown}'"
fi

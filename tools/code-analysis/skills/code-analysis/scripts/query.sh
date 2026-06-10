#!/usr/bin/env bash
# Joern query runner for the joern-code-analysis skill.
# Wraps joern --script execution and extracts LLM-consumable JSON output.
#
# Usage:
#   query.sh --cpg <path> --query <name> [OPTIONS]
#
# Queries:    callgraph | cfg_summary | dataflow | compare_variants | env_branches
# Common:     --timeout <sec>    (default: 60)
#             --max-results <n>  (default: 20)
# callgraph:  --target <funcName> --depth <n=2>
# cfg_summary:--target <funcName>
# dataflow:   --source <funcName> --sink <funcName>
# compare_variants: --cpg-b <path_to_second_cpg>
# env_branches:     --target <funcName>  (omit to scan all)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"

CPG_PATH=""
QUERY=""
TIMEOUT=60
MAX_RESULTS=20
TARGET=""
DEPTH=2
SOURCE=""
SINK=""
CPG_B=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpg)         CPG_PATH="$2";     shift 2 ;;
    --query)       QUERY="$2";        shift 2 ;;
    --timeout)     TIMEOUT="$2";      shift 2 ;;
    --max-results) MAX_RESULTS="$2";  shift 2 ;;
    --target)      TARGET="$2";       shift 2 ;;
    --depth)       DEPTH="$2";        shift 2 ;;
    --source)      SOURCE="$2";       shift 2 ;;
    --sink)        SINK="$2";         shift 2 ;;
    --cpg-b)       CPG_B="$2";        shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── error JSON helper ────────────────────────────────────────────────────────
json_err() {
  local status="$1" msg="$2"
  # escape double-quotes in msg
  msg="${msg//\"/\\\"}"
  printf '{"schema_version":"1.0","query":"%s","status":"%s","error_message":"%s","truncated":false}\n' \
    "${QUERY:-unknown}" "$status" "$msg"
}

# ── validate inputs ──────────────────────────────────────────────────────────
if [[ -z "$CPG_PATH" ]]; then
  json_err "error" "--cpg is required"
  exit 1
fi
if [[ ! -f "$CPG_PATH" ]]; then
  json_err "cpg_not_found" \
    "CPG not found at $CPG_PATH. Run harness/gen_cpg.sh first, then re-run this query."
  exit 2
fi
if [[ -z "$QUERY" ]]; then
  json_err "error" "--query is required (callgraph|cfg_summary|dataflow|compare_variants|env_branches)"
  exit 1
fi

QUERY_SCRIPT="$QUERIES_DIR/${QUERY}.sc"
if [[ ! -f "$QUERY_SCRIPT" ]]; then
  json_err "error" "Unknown query '$QUERY'. Script not found: $QUERY_SCRIPT"
  exit 1
fi

if [[ -z "${JOERN_HOME:-}" ]]; then
  json_err "error" "JOERN_HOME is not set. Source your shell profile after install_joern.sh."
  exit 4
fi

JOERN_BIN="$JOERN_HOME/joern"
if [[ ! -x "$JOERN_BIN" ]]; then
  json_err "error" "joern binary not found: $JOERN_BIN"
  exit 4
fi

# ── export env vars for Scala scripts ───────────────────────────────────────
export JOERN_CPG_PATH="$CPG_PATH"
export JOERN_QUERY="$QUERY"
export JOERN_TARGET="$TARGET"
export JOERN_DEPTH="$DEPTH"
export JOERN_MAX_RESULTS="$MAX_RESULTS"
export JOERN_SOURCE="$SOURCE"
export JOERN_SINK="$SINK"
export JOERN_CPG_B_PATH="${CPG_B:-}"

# ── run query with timeout ───────────────────────────────────────────────────
TMPOUT=$(mktemp)
TMPERR=$(mktemp)
trap "rm -f '$TMPOUT' '$TMPERR'" EXIT

EXIT_CODE=0
timeout "$TIMEOUT" "$JOERN_BIN" \
  --script "$QUERY_SCRIPT" \
  --param "cpgFile=$CPG_PATH" \
  >"$TMPOUT" 2>"$TMPERR" || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 124 ]]; then
  json_err "timeout" "Query timed out after ${TIMEOUT}s. Use --timeout to increase."
  exit 3
fi

if [[ $EXIT_CODE -ne 0 ]]; then
  SNIPPET=$(head -5 "$TMPERR" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-300)
  json_err "error" "Joern exited with code $EXIT_CODE: $SNIPPET"
  exit 4
fi

# ── extract JSON between BEGIN_JSON / END_JSON markers ───────────────────────
JSON_OUTPUT=$(sed -n '/^BEGIN_JSON$/,/^END_JSON$/{/^BEGIN_JSON$/d;/^END_JSON$/d;p}' "$TMPOUT")

if [[ -z "$JSON_OUTPUT" ]]; then
  SNIPPET=$(head -5 "$TMPOUT" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-300)
  json_err "error" "No JSON output from Joern. Stdout: $SNIPPET"
  exit 6
fi

printf '%s\n' "$JSON_OUTPUT"

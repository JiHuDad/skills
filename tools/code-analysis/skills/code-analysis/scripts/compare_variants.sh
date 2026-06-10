#!/usr/bin/env bash
# Compare two CPGs (variant A vs variant B) and output a diff JSON.
# Runs compare_variants.sc twice then computes set difference in Python.
#
# Usage:
#   compare_variants.sh --cpg-a <cpg_a.bin> --cpg-b <cpg_b.bin> [--timeout 120] [--max-results 500]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CPG_A=""
CPG_B=""
TIMEOUT=120
MAX_RESULTS=500

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpg-a)       CPG_A="$2";       shift 2 ;;
    --cpg-b)       CPG_B="$2";       shift 2 ;;
    --timeout)     TIMEOUT="$2";     shift 2 ;;
    --max-results) MAX_RESULTS="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

err_json() {
  local msg="$1"
  msg="${msg//\"/\\\"}"
  printf '{"schema_version":"1.0","query":"compare_variants","status":"error","error_message":"%s","truncated":false}\n' "$msg"
}

if [[ -z "$CPG_A" || -z "$CPG_B" ]]; then
  err_json "--cpg-a and --cpg-b are both required"
  exit 1
fi
for f in "$CPG_A" "$CPG_B"; do
  if [[ ! -f "$f" ]]; then
    err_json "CPG not found: $f. Run harness/gen_cpg.sh first."
    exit 2
  fi
done

# Run query on both CPGs
TMP_A=$(mktemp); TMP_B=$(mktemp)
trap "rm -f '$TMP_A' '$TMP_B'" EXIT

"$SCRIPT_DIR/query.sh" --cpg "$CPG_A" --query compare_variants \
  --timeout "$TIMEOUT" --max-results "$MAX_RESULTS" > "$TMP_A"

"$SCRIPT_DIR/query.sh" --cpg "$CPG_B" --query compare_variants \
  --timeout "$TIMEOUT" --max-results "$MAX_RESULTS" > "$TMP_B"

# Diff in Python (avoids jq dependency)
python3 - "$TMP_A" "$TMP_B" "$CPG_A" "$CPG_B" <<'PYEOF'
import json, sys

file_a, file_b, path_a, path_b = sys.argv[1:]

with open(file_a) as f: data_a = json.load(f)
with open(file_b) as f: data_b = json.load(f)

if data_a.get("status") != "ok":
    print(json.dumps(data_a, indent=2)); sys.exit(0)
if data_b.get("status") != "ok":
    print(json.dumps(data_b, indent=2)); sys.exit(0)

funcs_a = {fn["name"]: fn for fn in data_a["result"]["functions"]}
funcs_b = {fn["name"]: fn for fn in data_b["result"]["functions"]}

set_a = set(funcs_a.keys())
set_b = set(funcs_b.keys())

only_a    = sorted(set_a - set_b)
only_b    = sorted(set_b - set_a)
in_both   = set_a & set_b

changed = []
for name in sorted(in_both):
    ca = set(funcs_a[name].get("callees", []))
    cb = set(funcs_b[name].get("callees", []))
    added_in_b   = sorted(cb - ca)
    removed_in_b = sorted(ca - cb)
    if added_in_b or removed_in_b:
        changed.append({
            "function":          name,
            "added_calls_in_b":  added_in_b,
            "removed_calls_in_b":removed_in_b
        })

truncated = data_a.get("truncated", False) or data_b.get("truncated", False)
summary = (f"{len(only_a)} functions only in A, "
           f"{len(only_b)} only in B, "
           f"{len(changed)} with changed call graph")

result = {
    "schema_version": "1.0",
    "query": "compare_variants",
    "status": "ok",
    "target": {"cpg_a": path_a, "cpg_b": path_b},
    "truncated": truncated,
    "result": {
        "only_in_variant_a":  only_a,
        "only_in_variant_b":  only_b,
        "shared_functions":   len(in_both),
        "changed_call_graph": changed,
        "summary":            summary
    }
}
print(json.dumps(result, indent=2))
PYEOF

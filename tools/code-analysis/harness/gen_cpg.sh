#!/usr/bin/env bash
# Generate (or update) a Joern CPG from a source directory.
# Supports incremental builds via SHA-256 hash and multi-variant CPG generation.
#
# Usage: gen_cpg.sh [OPTIONS] <source_dir>
#
# Options:
#   --out <path>               Output CPG path (default: <source_dir>/cpg.bin)
#   --lang <c|cpp|java>        Language (auto-detect if omitted)
#   -Xmx <size>                JVM heap size (default: 4g)
#   --force                    Regenerate even if hash matches
#   --define <MACRO[=VAL]>     Preprocessor define (repeatable; C/C++ only)
#   --variant-config <file>    JSON file listing define sets for multi-variant run
#                              Format: {"variants":[{"name":"..","defines":["A=1"]}]}
set -euo pipefail

OUT_CPG=""
LANG=""
XMX="4g"
FORCE=0
VARIANT_CONFIG=""
EXTRA_DEFINES=""
SRC_DIR=""

err()  { echo "ERROR: $*" >&2; }
info() { echo "INFO:  $*" >&2; }

json_ok()    { printf '{"status":"ok","cpg_path":"%s","duration_sec":%s}\n'       "$1" "$2"; }
json_skip()  { printf '{"status":"skipped","reason":"up-to-date","cpg_path":"%s"}\n' "$1"; }
json_error() { printf '{"status":"error","code":%s,"message":"%s"}\n'             "$1" "$2"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)            OUT_CPG="$2";           shift 2 ;;
    --lang)           LANG="$2";              shift 2 ;;
    -Xmx)             XMX="$2";               shift 2 ;;
    --force)          FORCE=1;                shift   ;;
    --define)         EXTRA_DEFINES="$EXTRA_DEFINES -D$2"; shift 2 ;;
    --variant-config) VARIANT_CONFIG="$2";    shift 2 ;;
    --*)              err "Unknown option: $1"; exit 1 ;;
    *)                SRC_DIR="$1";           shift   ;;
  esac
done

if [[ -z "$SRC_DIR" ]]; then
  err "Usage: gen_cpg.sh [OPTIONS] <source_dir>"
  exit 1
fi

if [[ ! -d "$SRC_DIR" ]]; then
  json_error 1 "Source directory not found: $SRC_DIR"
  exit 1
fi

if [[ -z "${JOERN_HOME:-}" ]]; then
  json_error 4 "JOERN_HOME is not set. Run install_joern.sh first."
  exit 4
fi

JOERN_PARSE="$JOERN_HOME/joern-parse"
if [[ ! -x "$JOERN_PARSE" ]]; then
  json_error 4 "joern-parse not found: $JOERN_PARSE"
  exit 4
fi

# ── language auto-detect ────────────────────────────────────────────────────
if [[ -z "$LANG" ]]; then
  C_COUNT=$(find "$SRC_DIR" \( -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.cc" \) 2>/dev/null | wc -l)
  J_COUNT=$(find "$SRC_DIR" -name "*.java" 2>/dev/null | wc -l)

  if   [[ "$C_COUNT" -gt "$J_COUNT" ]]; then LANG="c"
  elif [[ "$J_COUNT" -gt "$C_COUNT" ]]; then LANG="java"
  elif [[ "$C_COUNT" -eq 0 ]]; then
    json_error 2 "No C/C++ or Java source files found in $SRC_DIR"
    exit 2
  else
    json_error 2 "Equal number of C and Java files. Specify --lang c|java."
    exit 2
  fi
fi

case "$LANG" in
  c|cpp) LANG_FLAG="--language C"       ;;
  java)  LANG_FLAG="--language JAVASRC" ;;
  *)     json_error 2 "Unknown language: $LANG (use c, cpp, or java)"; exit 2 ;;
esac

# ── multi-variant mode ───────────────────────────────────────────────────────
if [[ -n "$VARIANT_CONFIG" ]]; then
  if [[ ! -f "$VARIANT_CONFIG" ]]; then
    json_error 1 "variant-config file not found: $VARIANT_CONFIG"
    exit 1
  fi
  # Requires python3 (present on most systems; no network use)
  python3 - "$VARIANT_CONFIG" "$SRC_DIR" "$LANG_FLAG" "$XMX" "$JOERN_PARSE" <<'PYEOF'
import json, sys, os, subprocess, time, hashlib

cfg_file, src_dir, lang_flag, xmx, joern_parse = sys.argv[1:]
with open(cfg_file) as f:
    cfg = json.load(f)

results = []
for variant in cfg.get("variants", []):
    name    = variant["name"]
    defines = variant.get("defines", [])
    out_cpg = os.path.join(src_dir, f"cpg_{name}.bin")
    define_flags = " ".join(f"-D{d}" for d in defines)

    cmd = f'{joern_parse} {lang_flag} --output {out_cpg} {define_flags} {src_dir}'
    env = dict(os.environ, _JAVA_OPTIONS=f"-Xmx{xmx}")
    t0 = time.time()
    r  = subprocess.run(cmd, shell=True, capture_output=True, text=True, env=env)
    elapsed = int(time.time() - t0)

    if r.returncode == 0:
        results.append({"name": name, "status": "ok", "cpg_path": out_cpg,
                         "defines": defines, "duration_sec": elapsed})
    else:
        results.append({"name": name, "status": "error",
                         "message": r.stderr[:200].replace('"',"'")})

print(json.dumps({"status": "ok", "variants": results}, indent=2))
PYEOF
  exit 0
fi

# ── single CPG mode ──────────────────────────────────────────────────────────
OUT_CPG="${OUT_CPG:-$SRC_DIR/cpg.bin}"
HASH_FILE="${OUT_CPG}.sha256"

compute_hash() {
  find "$SRC_DIR" \( -name "*.c" -o -name "*.cpp" -o -name "*.h" \
                     -o -name "*.cc" -o -name "*.java" \) \
    -type f | sort | xargs sha256sum 2>/dev/null | sha256sum | awk '{print $1}'
}

if [[ "$FORCE" -eq 0 && -f "$OUT_CPG" && -f "$HASH_FILE" ]]; then
  CURRENT=$(compute_hash)
  STORED=$(cat "$HASH_FILE")
  if [[ "$CURRENT" == "$STORED" ]]; then
    json_skip "$OUT_CPG"
    exit 0
  fi
fi

info "Generating CPG: lang=$LANG, -Xmx$XMX"
info "  source : $SRC_DIR"
info "  output : $OUT_CPG"

START=$(date +%s)
export _JAVA_OPTIONS="-Xmx${XMX}"

# shellcheck disable=SC2086
if ! "$JOERN_PARSE" $LANG_FLAG --output "$OUT_CPG" $EXTRA_DEFINES "$SRC_DIR" \
     2>&1 | while IFS= read -r line; do info "$line"; done; then
  json_error 3 "joern-parse failed. Check stderr above for details."
  exit 3
fi

DURATION=$(( $(date +%s) - START ))
compute_hash > "$HASH_FILE"
json_ok "$OUT_CPG" "$DURATION"

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A **Joern-based static code analysis skill** that generates and queries Code Property Graphs (CPGs) for C/C++ and Java codebases. It is split into two distinct runtime contexts:

- **Harness** (`tools/code-analysis/harness/`) — runs **outside** agent sessions (CI, pre-commit, manual). Handles CPG generation via `joern-parse`. Heavy, slow.
- **Skill** (`tools/code-analysis/skills/code-analysis/`) — runs **inside** agent sessions. Queries an existing CPG via Joern Scala scripts. Fast, read-only.

The primary purpose is enabling data-driven design documentation: grounding call-graph, control-flow, and taint-analysis claims in actual CPG results rather than LLM inference.

## Environment Requirements

```bash
JOERN_HOME   # path to installed Joern directory (set by install_joern.sh)
JAVA_HOME    # or JDK_HOME — JDK 17+ required
# bash 4.x+, python3 (stdlib only), no network access required at runtime
```

## Key Commands

### One-time Joern setup (air-gapped)

```bash
export JOERN_TAR=/path/to/joern-cli-X.Y.Z-all.zip
export JOERN_INSTALL=/opt/joern          # default
export JDK_HOME=/opt/jdk-17             # if system java unavailable
bash tools/code-analysis/harness/install_joern.sh
# then add the printed export lines to ~/.bashrc
```

### Generate a CPG (run outside agent session)

```bash
# Auto-detect language
bash tools/code-analysis/harness/gen_cpg.sh --out /workspace/cpg.bin /path/to/src

# Force a specific language
bash tools/code-analysis/harness/gen_cpg.sh --lang java --out /workspace/cpg.bin /path/to/src

# Large codebase
bash tools/code-analysis/harness/gen_cpg.sh -Xmx8g --out /workspace/cpg.bin /path/to/src

# Force regeneration (ignore incremental hash check)
bash tools/code-analysis/harness/gen_cpg.sh --force --out /workspace/cpg.bin /path/to/src

# Multi-variant (#ifdef) CPGs
bash tools/code-analysis/harness/gen_cpg.sh \
  --variant-config tests/fixtures/sample_c/variants.json /path/to/src
# → produces cpg_platform_linux.bin, cpg_platform_windows.bin
```

### Run a query (inside agent session)

```bash
SKILL=tools/code-analysis/skills/code-analysis/scripts

# Call graph (who calls what, BFS to depth N)
bash $SKILL/query.sh --cpg /workspace/cpg.bin --query callgraph \
  --target "functionName" --depth 2

# Control-flow complexity metrics
bash $SKILL/query.sh --cpg /workspace/cpg.bin --query cfg_summary \
  --target "functionName"

# Taint / data-flow reachability
bash $SKILL/query.sh --cpg /workspace/cpg.bin --query dataflow \
  --source "recvPacket" --sink "execCmd"

# Environment/platform-sensitive branches
bash $SKILL/query.sh --cpg /workspace/cpg.bin --query env_branches
bash $SKILL/query.sh --cpg /workspace/cpg.bin --query env_branches --target "configure"

# Diff two variant CPGs
bash $SKILL/scripts/compare_variants.sh \
  --cpg-a /path/to/cpg_platform_linux.bin \
  --cpg-b /path/to/cpg_platform_windows.bin
```

Common flags for all queries: `--timeout <sec>` (default 60), `--max-results <n>` (default 20).

### Validate against fixture (manual test)

```bash
# Build CPG from C fixture
bash tools/code-analysis/harness/gen_cpg.sh --lang c --out /tmp/test.cpg tests/fixtures/sample_c

# Expected: callers=[parse_msg], depth 2 → [parse_msg, recv_packet]
bash tools/code-analysis/skills/code-analysis/scripts/query.sh \
  --cpg /tmp/test.cpg --query callgraph --target exec_cmd --depth 2

# Expected: reachable=true, hops=3
bash tools/code-analysis/skills/code-analysis/scripts/query.sh \
  --cpg /tmp/test.cpg --query dataflow --source recv_packet --sink exec_cmd
```

### Batch export for knowledge-layer integration

```bash
cp tools/code-analysis/harness/modules-config.example.json modules-config.json
# edit modules-config.json: cpg path, module names, target functions, source/sink pairs

bash tools/code-analysis/harness/export_analysis.sh --config modules-config.json
# → sdd-export/joern/{manifest.json, index.md, modules/*.md, variants/}

# Sync to a separate knowledge-layer repo
bash tools/code-analysis/harness/sync_to_knowledge.sh \
  --src sdd-export/joern --dest sdd/joern
```

## Architecture

### Data flow

```
Source Code
  → gen_cpg.sh (joern-parse)
  → cpg.bin  [+ cpg.bin.sha256 for incremental builds]
  → query.sh (joern --script <query>.sc, env vars passed as JOERN_*)
  → Scala script prints BEGIN_JSON … END_JSON
  → query.sh extracts JSON block via sed
  → schema-validated JSON to stdout
```

### Incremental CPG builds

`gen_cpg.sh` computes a SHA-256 over all source files and stores it alongside the `.bin`. On subsequent runs it skips `joern-parse` if the hash matches. Override with `--force`.

### Scala query pattern

All `.sc` scripts follow the same contract:
1. Read parameters from environment variables (`JOERN_CPG_PATH`, `JOERN_TARGET`, `JOERN_DEPTH`, `JOERN_SOURCE`, `JOERN_SINK`, `JOERN_MAX_RESULTS`).
2. The CPG object is pre-loaded by Joern via `--param cpgFile=<path>`.
3. Emit `println("BEGIN_JSON")` → JSON string → `println("END_JSON")`.
4. `query.sh` uses `sed` to extract only what is between the markers, discarding all Joern REPL noise.

### Output contract (frozen)

Every query — including failures — returns a JSON object conforming to `tools/code-analysis/contracts/analysis_output.schema.json` (schema v1.0). Required top-level fields: `schema_version`, `query`, `status`, `truncated`. When `status == "ok"` the `result` field is required; otherwise `error_message` is required.

| `status` | exit code | meaning |
|---|---|---|
| `ok` | 0 | success |
| `cpg_not_found` | 2 | `.bin` file missing — run `gen_cpg.sh` |
| `timeout` | 3 | increase `--timeout` or reduce `--depth` |
| `error` | 4 | Joern crash, bad function name, `JOERN_HOME` unset |

Never silently ignore a non-`ok` status — always surface `error_message` to the user.

### Schema versioning

Bump `MINOR` for additive changes (new fields). Bump `MAJOR` for breaking changes (removed or renamed fields). Store previous-version schemas in `contracts/` as `analysis_output.schema.vX.Y.json`.

## SKILL.md Trigger Conditions

`tools/code-analysis/skills/code-analysis/SKILL.md` defines when to invoke queries. Summary: **always run a query before writing or modifying a `design.md` that touches existing code**. Specifically:

- Call graph questions ("what calls X?") → `callgraph`
- Data-flow/taint questions → `dataflow`
- Refactoring impact estimation → `callgraph` at depth 2+
- Complexity before refactoring → `cfg_summary` (CC > 10 → consider splitting)
- `#ifdef`/platform variant analysis → `env_branches` + `compare_variants`

Do not guess call chains or data-flow paths from source text alone.

## Test Fixtures

`tests/fixtures/sample_c/` — intentional taint path: `recv_packet → parse_msg → exec_cmd` (C).  
`tests/fixtures/sample_java/` — equivalent Java taint path in `Processor.java`.  
`tests/fixtures/sample_c/variants.json` — multi-variant definitions for `#ifdef` testing.

The C fixture has a deliberate unsafe `strncpy`+`system()` chain so that `dataflow --source recv_packet --sink exec_cmd` always returns `reachable: true`.

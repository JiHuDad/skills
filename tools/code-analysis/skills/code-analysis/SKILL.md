---
name: joern-code-analysis
description: >
  MANDATORY — use this skill before writing or modifying any design.md that
  touches existing code. Specifically trigger on: (1) design.md authoring when
  existing functions are being changed; (2) call-graph or dependency questions
  ("what calls X?", "what does Y call?"); (3) data-flow / taint analysis ("does
  user input reach this function?"); (4) refactoring impact estimation ("what
  breaks if I rename/remove Z?"); (5) environment/platform branching analysis
  ("which code paths differ between prod and staging?", "#ifdef variant diff");
  (6) cyclomatic complexity and dead-code checks before refactoring. Do NOT
  guess call chains or data flows from source text alone — run the query first.
---

## Prerequisites

Before any query, verify the CPG exists and is fresh:

```bash
ls -lh /path/to/cpg.bin          # file must exist
cat /path/to/cpg.bin.sha256       # saved hash from last gen_cpg.sh run
```

If the CPG is missing or older than the most recent source commit:

1. **Tell the user** — do not silently skip.
2. Instruct them to run (outside the agent session):
   ```bash
   cd tools/code-analysis/harness
   bash gen_cpg.sh --out /workspace/cpg.bin /path/to/src
   ```
3. Wait for confirmation that the CPG is ready, then continue.

---

## SDD Integration Rules

When writing or reviewing a `design.md` that modifies existing code:

1. For every function listed in the "Changed" section, run **callgraph** at depth 2.
2. Paste the `result.callers` list into the design.md `## Current Structure` section
   as a "Impact Scope" table.
3. If any change touches a data-processing function, run **dataflow** to confirm
   no unintended source→sink paths are introduced or severed.
4. If the codebase has `#ifdef` variants or runtime env branches, run
   **env_branches** and, for significant changes, **compare_variants** to document
   which variants are affected.

---

## Query Reference

### 1. `callgraph` — who calls what

**When**: understanding impact before refactoring, documenting API surface.

```bash
./scripts/query.sh \
  --cpg /workspace/cpg.bin \
  --query callgraph \
  --target "functionName" \
  --depth 2              # increase for wider blast radius
```

Output key fields:
- `result.callers` — functions that call the target (upstream)
- `result.callees` — functions the target calls (downstream)
- `truncated: true` → rerun with `--depth 1` or `--max-results 50`

---

### 2. `cfg_summary` — complexity metrics

**When**: before refactoring a "complex" function, or flagging technical debt.

```bash
./scripts/query.sh \
  --cpg /workspace/cpg.bin \
  --query cfg_summary \
  --target "functionName"
```

Output: `basic_blocks`, `branch_points`, `cyclomatic_complexity`, `unreachable_blocks`.

Rule of thumb: CC > 10 → consider splitting before modifying.

---

### 3. `dataflow` — taint / data-flow reachability

**When**: security review, understanding data propagation, verifying sanitisation.

```bash
./scripts/query.sh \
  --cpg /workspace/cpg.bin \
  --query dataflow \
  --source "recvPacket" \
  --sink "execCmd"
```

Output: `reachable` bool + `paths` list with hop-by-hop summaries.

If `reachable: false` but you expected a path, check:
- Source and sink names are exact (case-sensitive).
- CPG was generated with the correct `--lang` flag.
- Try a shallower intermediate function as the sink.

---

### 4. `env_branches` — environment/config-sensitive branches

**When**: documenting multi-environment behaviour for design.md, or auditing
platform-specific code paths before a cross-env refactor.

```bash
# Scan entire codebase
./scripts/query.sh \
  --cpg /workspace/cpg.bin \
  --query env_branches

# Restrict to one function
./scripts/query.sh \
  --cpg /workspace/cpg.bin \
  --query env_branches \
  --target "configure"
```

Output: list of `{function, file, line, condition}` for every branch whose
condition references env/config/platform/mode/feature/flag/getenv patterns.

---

### 5. `compare_variants` — diff two environment CPGs

**When**: `#ifdef`-heavy codebases; understanding which functions exist only
under certain compile-time flags; writing a "Platform Differences" section in
design.md.

Step 1 — generate per-variant CPGs (harness, outside session):
```bash
bash harness/gen_cpg.sh \
  --variant-config tests/fixtures/sample_c/variants.json \
  /path/to/src
# → cpg_platform_linux.bin, cpg_platform_windows.bin
```

Step 2 — compare:
```bash
./scripts/compare_variants.sh \
  --cpg-a /path/to/src/cpg_platform_linux.bin \
  --cpg-b /path/to/src/cpg_platform_windows.bin
```

Output key fields:
- `only_in_variant_a` — functions that exist only in variant A
- `only_in_variant_b` — functions that exist only in variant B
- `changed_call_graph` — shared functions whose callees differ between variants

Paste `summary` field directly into design.md `## Platform Variants` section.

---

## Combining Queries for a Complete SDD Analysis

Example: "I'm changing `parse_msg` in a multi-platform codebase."

```bash
# 1. Who will be affected?
query.sh --cpg cpg.bin --query callgraph --target parse_msg --depth 3

# 2. Is this function complex?
query.sh --cpg cpg.bin --query cfg_summary --target parse_msg

# 3. Does tainted data reach a dangerous sink via parse_msg?
query.sh --cpg cpg.bin --query dataflow --source recv_packet --sink exec_cmd

# 4. Are there env-specific branches inside parse_msg?
query.sh --cpg cpg.bin --query env_branches --target parse_msg

# 5. Does parse_msg behave differently across platforms?
compare_variants.sh --cpg-a cpg_linux.bin --cpg-b cpg_windows.bin
```

---

## 지식층 Export 워크플로우

분석 결과를 별도 지식층 repo(knowledge-layer)에 저장할 때 사용한다.
블록 워크스페이스와 지식층 repo가 서로 다른 경우의 표준 흐름이다.

### Step 1 — modules-config.json 작성 (최초 1회)

```bash
cp tools/code-analysis/harness/modules-config.example.json modules-config.json
# 편집: cpg 경로, 모듈명, 분석할 함수, dataflow source/sink 설정
```

### Step 2 — 분석 실행 및 export (블록 워크스페이스)

```bash
# CPG가 최신인지 확인 (변경 있으면 재생성)
bash tools/code-analysis/harness/gen_cpg.sh --out /workspace/cpg.bin src/

# 모든 모듈 분석 실행 → sdd-export/joern/ 생성
bash tools/code-analysis/harness/export_analysis.sh --config modules-config.json

# 결과 확인
ls sdd-export/joern/modules/
cat sdd-export/joern/manifest.json
```

출력 구조:
```
sdd-export/joern/
├── manifest.json        ← 생성일, 소스 커밋, CPG 해시
├── index.md             ← 전체 모듈 요약
├── modules/
│   ├── auth.md          ← callgraph + dataflow + env_branches
│   └── socket.md
└── variants/            ← platform diff (variant_config 설정 시)
```

### Step 3 — 지식층 repo에 동기화 (검토 후 수동)

```bash
# 지식층 repo 루트에서 실행
bash /path/to/block-ws/tools/code-analysis/harness/sync_to_knowledge.sh \
  --src  /path/to/block-ws/sdd-export/joern \
  --dest sdd/joern

# 변경 diff 확인 → y 입력 시 자동 커밋
# CI/자동화 환경에서는 --auto-commit 플래그 사용
```

### 신선도 경고

`sync_to_knowledge.sh`는 manifest의 `source_commit`과 현재 HEAD를 비교한다.
20커밋 이상 뒤처진 경우 경고 후 진행 여부를 묻는다 (`--max-age`로 조정).

```
WARN: 분석이 소스 HEAD보다 35커밋 뒤처져 있습니다.
      block workspace에서 gen_cpg.sh + export_analysis.sh 재실행 권장.
계속 진행하시겠습니까? [y/N]
```

### 충돌 방지 규칙

- `sdd/joern/` 전체는 **자동 생성 전용** — 사람이 직접 편집하지 않는다
- 기존 `sdd/.analysis/`, `sdd/modules/` 등은 sync 경로에 포함되지 않아 안전하다
- `sdd/traceability.md`에 `sdd/joern/index.md` 링크만 추가하면 기존 SDD와 연결된다

---

## Error Handling

Every query returns a schema-compliant JSON even on failure:

| `status` | Meaning | Action |
|----------|---------|--------|
| `cpg_not_found` | CPG file missing | Run `gen_cpg.sh`, confirm path |
| `timeout` | Query exceeded `--timeout` | Increase timeout or reduce `--depth` |
| `error` | Joern crash or bad input | Check `error_message`, verify function name spelling |

**Never silently ignore a non-ok status.** Report it to the user with the
`error_message` value.

---

## Platform Adapter Notes (Codex / other agents)

This skill is pure bash + file I/O. No Claude-specific APIs are used.

| Requirement | Value |
|-------------|-------|
| Shell | bash 4.x+ (`/usr/bin/env bash`) |
| Runtime | `python3` (stdlib only, no pip) |
| Java | JDK 17+ (set `JAVA_HOME` or `JDK_HOME`) |
| Network | None — fully air-gapped |
| CPG format | Joern 2.x binary CPG (`cpg.bin`) |

To use from Codex: set `JOERN_HOME` env var, call `query.sh` directly as
a subprocess, parse stdout JSON.

---

## File Locations

```
tools/code-analysis/
├── harness/
│   ├── install_joern.sh      # one-time setup
│   ├── gen_cpg.sh            # CPG generation (run outside agent session)
│   └── README.md             # air-gapped setup guide
├── contracts/
│   └── analysis_output.schema.json
└── skills/code-analysis/
    ├── SKILL.md              # this file
    ├── scripts/
    │   ├── query.sh          # main entry point
    │   ├── compare_variants.sh
    │   └── queries/
    │       ├── callgraph.sc
    │       ├── cfg_summary.sc
    │       ├── dataflow.sc
    │       ├── env_branches.sc
    │       └── compare_variants.sc
    └── references/
        └── cpgql_cheatsheet.md
```

For CPGQL syntax and advanced traversal patterns, see
`references/cpgql_cheatsheet.md`.

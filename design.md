# Design: Joern 기반 CFG/DFG 코드 분석 Skill + Harness

## 1. 컴포넌트 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                     에이전트 세션 외부 (Harness)                  │
│                                                                   │
│  소스 디렉토리 ──→ gen_cpg.sh ──→ cpg.bin                        │
│                  (joern-parse)   (증분 빌드)                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                          cpg.bin
                              │
┌─────────────────────────────────────────────────────────────────┐
│                     에이전트 세션 내 (Skill)                       │
│                                                                   │
│  query.sh ──→ joern --script <query>.sc ──→ 원시 Scala 출력      │
│      │                                           │                │
│      │                              JSON 정규화 + 스키마 검증     │
│      └──────────────────────────────────→ LLM 소비용 JSON       │
└─────────────────────────────────────────────────────────────────┘
```

**핵심 설계 결정**: Joern은 Scala REPL 기반이므로 `.sc` 스크립트가 JSON을 직접 `println`으로 출력하고, `query.sh`가 stderr를 필터링하여 첫 번째 유효 JSON 블록만 캡처한다.

## 2. Harness 상세 설계

### 2-1. `install_joern.sh`

```
입력 환경변수:
  JOERN_TAR    : Joern 배포판 tar.gz 경로 (필수)
  JOERN_INSTALL: 설치 대상 디렉토리 (기본: /opt/joern)
  JDK_HOME     : 사전 반입된 JDK 경로 (기본: 시스템 java)

동작:
  1. JOERN_TAR 존재 확인 → 없으면 EXIT_CODE=1 + 에러 메시지
  2. JOERN_INSTALL 디렉토리에 압축 해제
  3. joern 바이너리 실행 권한 설정
  4. joern --version 실행으로 설치 검증
  5. JOERN_HOME 내보내기 스니펫 출력 (사용자가 .bashrc에 추가)

종료 코드:
  0: 성공
  1: JOERN_TAR 없음
  2: 압축 해제 실패
  3: 설치 검증 실패
```

### 2-2. `gen_cpg.sh`

```
인터페이스:
  gen_cpg.sh [OPTIONS] <source_dir>

OPTIONS:
  --out <path>      출력 CPG 경로 (기본: <source_dir>/cpg.bin)
  --lang <c|cpp|java>  언어 지정 (미지정: 확장자 자동 감지)
  -Xmx <size>       JVM 힙 크기 (기본: 4g)
  --force           해시 일치해도 재생성 강제

자동 감지 로직:
  .c/.cpp/.h 파일 수 vs .java 파일 수 비교 → 다수 언어 선택
  동수일 경우 --lang 필수 요구

증분 빌드 로직:
  1. <out>.sha256 파일 존재 확인
  2. find <source_dir> -name "*.c" -o -name "*.java" ... | sort | sha256sum 계산
  3. 저장된 해시와 비교 → 일치 시 "CPG up-to-date, skipping" 출력 후 EXIT 0
  4. joern-parse 실행 후 새 해시 저장

에러 출력 포맷 (stderr + JSON to stdout):
  성공: {"status": "ok", "cpg_path": "...", "duration_sec": N}
  스킵: {"status": "skipped", "reason": "up-to-date", "cpg_path": "..."}
  실패: {"status": "error", "code": N, "message": "..."}

종료 코드:
  0: 성공 또는 스킵
  1: 소스 디렉토리 없음
  2: 언어 감지 실패 (동수)
  3: joern-parse 실패
  4: JOERN_HOME 미설정
```

### 2-3. `harness/README.md` 핵심 내용

**사전 반입 목록 (폐쇄망용)**:
- `joern-cli-X.Y.Z-all.zip` — GitHub Releases: joernio/joern
- `openjdk-17_linux-x64_bin.tar.gz` — jdk.java.net/17 (또는 Eclipse Temurin)
- (선택) `joern-cli-X.Y.Z-all.zip`에 포함된 scala-repl 자체 번들

## 3. 출력 계약 스키마 (`analysis_output.schema.json`)

```json
{
  "$schema": "https://json-schema.org/draft/2020-12",
  "$id": "analysis_output.schema.json",
  "title": "Joern Analysis Output",
  "type": "object",
  "required": ["schema_version", "query", "status"],
  "properties": {
    "schema_version": {"type": "string", "const": "1.0"},
    "query": {
      "type": "string",
      "enum": ["callgraph", "cfg_summary", "dataflow"]
    },
    "status": {
      "type": "string",
      "enum": ["ok", "error", "timeout", "cpg_not_found"]
    },
    "error_message": {"type": "string"},
    "target": {"type": "object"},
    "truncated": {"type": "boolean"},
    "result": {"type": "object"}
  }
}
```

각 쿼리별 `result` 서브스키마는 아래 섹션에 정의. `status != "ok"`인 경우 `result` 없이 `error_message`만 포함.

### 3-1. callgraph result 스키마

```json
{
  "function": "string",           // 대상 함수명
  "depth": "integer",             // 요청 depth
  "callers": [                    // 이 함수를 호출하는 함수 목록
    {
      "name": "string",
      "file": "string",
      "line": "integer",
      "depth_from_target": "integer"
    }
  ],
  "callees": [                    // 이 함수가 호출하는 함수 목록
    {
      "name": "string",
      "file": "string",
      "line": "integer",
      "depth_from_target": "integer"
    }
  ],
  "total_callers": "integer",
  "total_callees": "integer"
}
```

### 3-2. cfg_summary result 스키마

```json
{
  "function": "string",
  "basic_blocks": "integer",
  "branch_points": "integer",
  "unreachable_blocks": "integer",
  "cyclomatic_complexity": "integer",
  "summary": "string"             // "N blocks, M branches, K unreachable"
}
```

### 3-3. dataflow result 스키마

```json
{
  "source": "string",
  "sink": "string",
  "reachable": "boolean",
  "paths": [
    {
      "summary": "string",        // "funcA → funcB(arg x) → funcC(arg y)"
      "hops": "integer",
      "nodes": ["string"]         // 경유 함수/변수 이름 목록
    }
  ],
  "total_paths_found": "integer"
}
```

## 4. Skill 상세 설계

### 4-1. `query.sh`

```
인터페이스:
  query.sh --cpg <path> --query <name> [QUERY_OPTIONS]

공통 옵션:
  --cpg <path>       cpg.bin 경로 (필수)
  --query <name>     callgraph | cfg_summary | dataflow
  --timeout <sec>    쿼리 타임아웃 (기본: 60)
  --max-results <n>  최대 결과 수 (기본: 20)

쿼리별 추가 옵션:
  callgraph:  --target <funcName> --depth <n=2>
  cfg_summary: --target <funcName>
  dataflow:   --source <funcName> --sink <funcName>

동작:
  1. cpg.bin 존재 확인 → 없으면 cpg_not_found JSON 출력 + EXIT 2
  2. JOERN_HOME/bin/joern --script <query>.sc 실행
     환경변수로 인자 전달: JOERN_CPG_PATH, JOERN_TARGET 등
  3. stdout에서 JSON 블록 추출 (BEGIN_JSON/END_JSON 마커 방식)
  4. 타임아웃 초과 시 프로세스 종료 + timeout JSON 출력
  5. 스키마 준수 JSON을 stdout으로 출력

JSON 마커 방식:
  Joern 스크립트가 println("BEGIN_JSON") → println(jsonStr) → println("END_JSON") 출력
  query.sh가 sed로 마커 사이 내용만 추출
```

### 4-2. `queries/callgraph.sc` 설계

```scala
// Joern Scala 스크립트
// 환경변수: JOERN_CPG_PATH, JOERN_TARGET, JOERN_DEPTH, JOERN_MAX_RESULTS

val targetFunc = System.getenv("JOERN_TARGET")
val depth = Option(System.getenv("JOERN_DEPTH")).getOrElse("2").toInt
val maxResults = Option(System.getenv("JOERN_MAX_RESULTS")).getOrElse("20").toInt

// CPG는 --script 실행 시 --param으로 로드되므로 cpg 객체가 이미 존재

// callers: 대상 함수를 호출하는 함수
val callers = cpg.method.name(targetFunc)
  .caller
  .map(m => (m.name, m.filename, m.lineNumber.getOrElse(-1)))
  .l
  .take(maxResults)

// callees: 대상 함수가 호출하는 함수  
val callees = cpg.method.name(targetFunc)
  .callee
  .map(m => (m.name, m.filename, m.lineNumber.getOrElse(-1)))
  .l
  .take(maxResults)

// JSON 직렬화 후 마커 출력
val json = buildCallgraphJson(targetFunc, depth, callers, callees, maxResults)
println("BEGIN_JSON")
println(json)
println("END_JSON")
```

**N-depth 구현**: depth > 1인 경우 재귀적으로 `.caller.caller` 체이닝 대신 BFS로 확장. Scala 스크립트 내에서 큐 기반 순회로 구현.

### 4-3. `queries/cfg_summary.sc` 설계

```
cpg.method.name(targetFunc)의:
  - .cfg.l.size → 전체 CFG 노드 수
  - .cfg.isControlStructure.l.size → 분기점 수 (if/while/for/switch)
  - cyclomatic_complexity = 분기점 수 + 1 (McCabe)
  - unreachable: .cfg.filterNot(node => node.dominates.nonEmpty || node.isEntryNode) 근사치

실제 도달불가 블록 계산은 Joern 내장 dominance frontier가 없으므로
  → basic block 중 predecessor가 없고 entry block이 아닌 것으로 근사
```

### 4-4. `queries/dataflow.sc` 설계

```
Joern Taint Analysis API 사용:
  val source = cpg.method.name(sourceName).parameter
  val sink = cpg.method.name(sinkName).parameter
  val paths = source.reachableByFlows(sink).l.take(maxPaths)

각 경로를 요약 문자열로 변환:
  "funcA → funcB(param x) → funcC(param y)"

paths.size > maxPaths → truncated: true
```

## 5. `SKILL.md` 구조 설계

```markdown
---
name: joern-code-analysis
description: >
  [트리거 조건 — 아래 상황에서 반드시 이 스킬을 먼저 실행:]
  design.md에 기존 코드 변경이 포함될 때 / 함수 호출 관계 파악 필요 시 /
  데이터 흐름·taint 경로 분석 필요 시 / 리팩토링 영향 범위 산정 시 /
  보안 취약점 경로 추적 시
---

## 전제 조건 확인
## SDD 연동 규칙
## 쿼리 사용 가이드
  ### callgraph — 호출 관계
  ### cfg_summary — 복잡도
  ### dataflow — 데이터 흐름
## CPG 부재/만료 처리
## 에러 처리
## 플랫폼 어댑터 노트 (Codex)
```

## 6. 테스트 픽스처 설계

### `tests/fixtures/sample_c/`

```c
// main.c — 의도적 taint 경로 포함
#include <string.h>
#include <stdlib.h>

void exec_cmd(char *cmd) { system(cmd); }          // sink

void parse_msg(char *buf) {
    char cmd[256];
    strncpy(cmd, buf, 255);
    exec_cmd(cmd);                                  // taint 전파
}

void recv_packet(char *data) {
    parse_msg(data);                                // source
}

int main() { return 0; }
```

이 파일의 기대 결과:
- `callgraph --target exec_cmd`: callers=[parse_msg], depth=2에서 callers=[parse_msg, recv_packet]
- `dataflow --source recv_packet --sink exec_cmd`: reachable=true, hops=3

### `tests/fixtures/sample_java/`

```java
// Processor.java — 동일 목적
public class Processor {
    public void execCmd(String cmd) { Runtime.getRuntime().exec(cmd); }  // sink
    public void parseMsg(String buf) { execCmd(buf); }
    public void recvPacket(String data) { parseMsg(data); }              // source
}
```

## 7. 에러 처리 표준

모든 실패 상황에서 스키마 준수 JSON + 적절한 종료코드:

| 상황 | status | 종료코드 |
|------|--------|---------|
| 정상 | "ok" | 0 |
| CPG 파일 없음 | "cpg_not_found" | 2 |
| 쿼리 타임아웃 | "timeout" | 3 |
| Joern 실행 실패 | "error" | 4 |
| 함수명 없음 | "error" | 5 |
| 스키마 위반 | "error" | 6 |

```json
{
  "schema_version": "1.0",
  "query": "callgraph",
  "status": "cpg_not_found",
  "error_message": "CPG not found at /path/to/cpg.bin. Run harness/gen_cpg.sh first.",
  "truncated": false
}
```

## 8. 버전 관리 정책

- `schema_version` 필드는 `MAJOR.MINOR` 형식
- 하위 호환 변경(필드 추가): MINOR 증가
- 하위 비호환 변경(필드 제거/타입 변경): MAJOR 증가
- `contracts/` 디렉토리에 이전 버전 스키마 보관 (`analysis_output.schema.v0.9.json`)

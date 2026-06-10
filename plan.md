# Plan: Joern 기반 CFG/DFG 코드 분석 Skill + Harness

## 1. 배경 및 목표 요약

SDD 워크플로우에서 `design.md` 작성 시 기존 코드 구조 서술이 LLM 추측이 아닌 **실제 정적 분석 결과(CPG/CFG/DFG/콜그래프)에 근거**하도록 Joern 기반 분석 파이프라인을 구축한다.

산출물:
- **Harness**: 코드베이스 → CPG(`cpg.bin`) 생성·갱신 스크립트 (에이전트 세션 외부 실행)
- **Skill**: 기존 CPG에 쿼리 실행 후 LLM 소비용 요약 JSON 반환 (open agent skills 표준)

## 2. 제약 조건 정리

| 제약 | 구현 방침 |
|------|-----------|
| 폐쇄망(air-gapped) | 인터넷 다운로드 없음. Joern tar + JDK 사전 반입 가정. README에 반입 목록 명시 |
| Cross-agent 호환 | 순수 bash + 파일 기반. claude CLI 전용 기능 사용 금지 |
| 출력 계약 고정 | `contracts/analysis_output.schema.json`으로 JSON 스키마 고정. 변경 시 `schema_version` 필드 증가 |
| 대상 언어 | C/C++ (`c2cpg`), Java (`javasrc2cpg`) 지원 |
| 에이전트 내 CPG 생성 금지 | `gen_cpg.sh`는 harness 영역. 스킬은 쿼리만 실행 |

## 3. 디렉토리 구조 (확정)

리포가 새로 시작이므로 제안 구조를 그대로 채택한다. (기존 컨벤션 없음)

```
tools/code-analysis/
├── harness/
│   ├── install_joern.sh        # 로컬 tar에서 Joern 설치
│   ├── gen_cpg.sh              # joern-parse 래퍼 (증분 빌드 포함)
│   └── README.md               # 사전 반입 목록, CPG 갱신 시점 가이드
├── contracts/
│   └── analysis_output.schema.json
└── skills/code-analysis/
    ├── SKILL.md
    ├── scripts/
    │   ├── query.sh            # joern --script 래퍼
    │   └── queries/
    │       ├── callgraph.sc
    │       ├── cfg_summary.sc
    │       └── dataflow.sc
    └── references/
        └── cpgql_cheatsheet.md

tests/
└── fixtures/
    ├── sample_c/               # CFG/dataflow 테스트용 C 소스
    └── sample_java/            # CFG/dataflow 테스트용 Java 소스
```

`tests/fixtures/`는 수용 기준 검증용 샘플 코드 디렉토리. 루트 레벨에 별도 분리.

## 4. 구현 Phase 계획

### Phase 0 — 문서 (현재)
- [x] `plan.md` 작성
- [x] `design.md` 작성
- [ ] 사용자 승인 → 구현 시작

### Phase 1 — Harness
**파일**: `install_joern.sh`, `gen_cpg.sh`, `harness/README.md`

deliverable:
- `install_joern.sh`: `JOERN_TAR` 환경변수 경로에서 설치, `JOERN_HOME` 설정
- `gen_cpg.sh`: 언어 자동감지, 증분 빌드(SHA-256 해시 비교), `--lang`, `-Xmx` 옵션
- `tests/fixtures/sample_c/` : 의도적 taint 경로 포함 샘플 C 코드 2~3개 파일
- `tests/fixtures/sample_java/` : 동일 목적 Java 샘플

커밋: `feat: add joern harness scripts and test fixtures`

### Phase 2 — 출력 계약 스키마 + callgraph 쿼리 (end-to-end)
**파일**: `contracts/analysis_output.schema.json`, `query.sh`, `queries/callgraph.sc`

deliverable:
- JSON 스키마 `schema_version: "1.0"` 확정
- `query.sh`: `--cpg`, `--query`, `--target`, `--depth`, `--timeout` 인자 파싱
- `callgraph.sc`: caller/callee N-depth, 결과 LLM 요약 JSON 출력
- CPG 부재 시 에러 JSON 출력 후 종료코드 2

커밋: `feat: add output contract schema and callgraph query`

### Phase 2.5 — Variant 분석 (Multi-environment)
**파일**: `queries/env_branches.sc`, `queries/compare_variants.sc`, `scripts/compare_variants.sh`

deliverable:
- `env_branches.sc`: if/switch에서 env/mode/platform/config 패턴 감지
- `compare_variants.sc`: 단일 CPG 함수 인벤토리 덤프 (compare_variants.sh의 재료)
- `compare_variants.sh`: 두 CPG를 각각 질의 후 Python으로 set-diff → `only_in_a/b + changed_call_graph` JSON
- `gen_cpg.sh --variant-config` 옵션으로 variants.json 읽어 다중 CPG 생성
- `tests/fixtures/sample_c/platform.c` + `variants.json`: `#ifdef` 픽스처

커밋: `feat: add variant analysis queries (env_branches, compare_variants)`

### Phase 3 — cfg_summary + dataflow 쿼리
**파일**: `queries/cfg_summary.sc`, `queries/dataflow.sc`

deliverable:
- `cfg_summary.sc`: basic block 수, 분기점, 도달불가 블록
- `dataflow.sc`: source→sink 도달성, 경로 상위 N개, `truncated` 플래그
- 수용 기준: 테스트 픽스처에서 알려진 taint 경로 탐지 확인

커밋: `feat: add cfg_summary and dataflow queries`

### Phase 4 — SKILL.md + 치트시트 + 시나리오 검증
**파일**: `SKILL.md`, `references/cpgql_cheatsheet.md`

deliverable:
- `SKILL.md`: frontmatter, SDD 연동 규칙, 쿼리 사용 시점, 500줄 이내
- `cpgql_cheatsheet.md`: 실행 검증된 CPGQL 패턴만 수록
- 시나리오 검증: "X 함수 수정 시 영향 범위?" 프롬프트로 스킬 트리거 확인

커밋: `feat: add SKILL.md and cpgql reference`

## 5. 수용 기준 추적

- [ ] 폐쇄망: install → gen_cpg → query 전 과정 인터넷 없이 동작
- [ ] C/C++ 샘플 callgraph → 스키마 준수 JSON
- [ ] Java 샘플 callgraph → 스키마 준수 JSON
- [ ] dataflow 쿼리 → 알려진 taint 경로 탐지
- [ ] 출력 JSON이 `analysis_output.schema.json` 검증 통과
- [ ] SKILL.md만 읽은 에이전트가 쿼리 올바르게 실행 가능
- [ ] CPG 부재 시 명확한 안내 메시지 + 종료코드 2
- [ ] `env_branches` 쿼리가 `platform.c`의 `getenv`/`platform` 분기를 탐지
- [ ] `compare_variants.sh`로 linux vs windows CPG diff JSON 반환
- [ ] `variants.json` + `gen_cpg.sh --variant-config`로 다중 CPG 생성

## 6. 리스크 및 대응

| 리스크 | 대응 |
|--------|------|
| Joern 버전별 CPGQL API 차이 | SKILL.md와 치트시트에 검증된 버전 명시. 쿼리 스크립트 상단에 `// Tested: Joern X.Y.Z` 주석 |
| 대형 코드베이스 타임아웃 | `query.sh`에 `--timeout`(초) 옵션. 초과 시 `{"error": "timeout"}` JSON 반환 |
| C/C++ 빌드 시스템 복잡성 | `gen_cpg.sh`는 헤더-only 분석 모드(`--override-java-home`)도 지원. 컴파일 실패 시 경고 JSON 포함 출력 |
| Scala 스크립트 실행 환경 | Joern 번들 JDK 사용. `JAVA_HOME` 환경변수 재정의 방지 로직 포함 |

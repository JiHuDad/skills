# Harness: CPG 생성 도구

Joern CPG(`cpg.bin`)를 소스 코드에서 생성·갱신하는 스크립트 모음.
**에이전트 세션 외부**에서 실행한다. CPG 생성은 무거운 작업이므로 CI 훅이나 사전 준비 단계에서 수행한다.

---

## 폐쇄망(Air-gapped) 사전 반입 목록

아래 파일을 인터넷이 연결된 환경에서 미리 다운로드하여 반입한다.

| 파일 | 출처 | 비고 |
|------|------|------|
| `joern-cli-X.Y.Z-all.zip` | `github.com/joernio/joern/releases` | 최신 stable 권장 |
| `openjdk-17_linux-x64_bin.tar.gz` | `jdk.java.net/17` 또는 Eclipse Temurin | JDK 17+ 필수 |

> Joern 2.x 이상을 권장한다. 1.x는 CPGQL API가 다를 수 있다.

---

## 설치

```bash
export JOERN_TAR=/path/to/joern-cli-X.Y.Z-all.zip
export JOERN_INSTALL=/opt/joern          # 설치 대상 (기본값)
export JDK_HOME=/opt/jdk-17              # 번들 JDK 경로 (시스템 java가 없을 때)

bash install_joern.sh

# 출력된 export 명령을 ~/.bashrc 에 추가
export JOERN_HOME=/opt/joern/joern-cli
export PATH="$JOERN_HOME:$PATH"
```

---

## CPG 생성

### 기본 사용

```bash
# C/C++ 프로젝트 (언어 자동 감지)
bash gen_cpg.sh /path/to/src

# Java 프로젝트
bash gen_cpg.sh --lang java --out /workspace/cpg.bin /path/to/src

# 메모리 확장 (대형 코드베이스)
bash gen_cpg.sh -Xmx8g --out /workspace/cpg.bin /path/to/src
```

출력 JSON (stdout):
```json
{"status":"ok","cpg_path":"/workspace/cpg.bin","duration_sec":42}
{"status":"skipped","reason":"up-to-date","cpg_path":"/workspace/cpg.bin"}
{"status":"error","code":3,"message":"joern-parse failed..."}
```

### 증분 빌드

소스 파일 SHA-256 해시를 `cpg.bin.sha256`에 저장하여 변경이 없으면 재생성을 건너뛴다.

```bash
bash gen_cpg.sh /path/to/src          # 변경 없으면 "skipped" 출력
bash gen_cpg.sh --force /path/to/src  # 강제 재생성
```

### 다중 환경 변형(Multi-variant) CPG

`#ifdef`로 환경이 분기되는 코드베이스를 분석할 때 사용한다.

```bash
# variants.json 예시
cat tests/fixtures/sample_c/variants.json

bash gen_cpg.sh --variant-config tests/fixtures/sample_c/variants.json /path/to/src
# → cpg_platform_linux.bin, cpg_platform_windows.bin 생성
```

variants.json 포맷:
```json
{
  "variants": [
    {"name": "platform_linux",   "defines": ["PLATFORM_LINUX=1",   "MAX_CONN=100"]},
    {"name": "platform_windows", "defines": ["PLATFORM_WINDOWS=1", "MAX_CONN=50"]}
  ]
}
```

---

## CPG 갱신 시점 가이드

| 시점 | 방법 |
|------|------|
| CI pre-merge | CI 훅에서 소스 변경 감지 시 `gen_cpg.sh` 실행 |
| 개발자 로컬 | pre-commit hook으로 `gen_cpg.sh` 실행 (증분이라 빠름) |
| 정기 배치 | 야간 크론으로 `--force` 재생성 |

---

## 종료 코드

| 코드 | 의미 |
|------|------|
| 0 | 성공 또는 증분 스킵 |
| 1 | 소스 디렉토리 없음 또는 파일 없음 |
| 2 | 언어 감지 실패 |
| 3 | joern-parse 실패 |
| 4 | JOERN_HOME 미설정 |

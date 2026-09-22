# WidgetRAG shell 설치형 기동 스크립트

용역 요구사항 2번 — **shell script 방식 기동 확인** 산출물.
IDE·수작업 없이 셸 커맨드 절차만으로 전체 스택을 설치·기동·검증·종료한다.
계획서의 실행 형태 2종 중 **"shell 설치형"** 에 해당한다 (Docker Compose 형태는 별도).

> **실증 환경(Ubuntu Linux GPU VM) 전용** — 전 구성요소 네이티브(Docker 없음)이며,
> macOS 등 로컬 우회 경로는 두지 않는다. 로컬 검증이 필요하면 Docker Compose(B) 트랙을 사용.

## 기동 절차 — 커맨드 2개

요구사항 예시(`npm install` 후 `npm run prod`)와 동일한 2단계 인터페이스:

```bash
cd scripts/local
./install.sh     # ← npm install 에 해당: 도구 설치 + 설정 생성 (최초 1회)
./start.sh       # ← npm run prod 에 해당: 인프라→앱 전체 기동 + 헬스 체크
```

종료와 상태 점검:

```bash
./stop.sh                              # 전체 종료 (역순, 데이터 유지)
./50-verify.sh                         # 상태 점검 + SQLite 기능 등가성 (FK·WAL 동시 쓰기·트리거)
CLIENT_CODE=shop_xxxx ./50-verify.sh   # RAG 챗봇 스모크 테스트 + 타임존 검증까지
RUNS=5 CLIENT_CODE=... ./50-verify.sh  # 반복 검증 — N회 연속 자동판정, verify-history.tsv 누적
FORM=aws-shell RUNS=5 ... ./50-verify.sh  # 결과표에 환경 이름 태깅 — CSP 간·형태 간 비교용
                                          # (미지정 시 shell-native)
```

## 서비스별 표준 커맨드 (래퍼가 내부에서 수행하는 순정 절차)

마이그레이션 도구가 식별·이전해야 할 대상이 바로 이 커맨드들이다 (실행 파일·의존 패키지·환경변수):

| 서비스 | 의존성 설치 (`npm install` 상당) | 기동 (`npm run prod` 상당) |
|---|---|---|
| AI 서버 (FastAPI) | `python3.12 -m venv .venv && .venv/bin/pip install -r requirements_exaone.txt` | Linux: systemd `widgetrag-ai` (ExecStart=`.venv/bin/uvicorn main_exaone:app --host 0.0.0.0 --port 8000`) |
| 백엔드 (Spring Boot) | `./mvnw package -DskipTests` | Linux: systemd `widgetrag-backend` (ExecStart=`java -jar target/backend-*.jar --spring.profiles.active=local`, 환경변수는 `/etc/widgetrag/widgetrag.env`) |
| 프론트엔드 (정적) | 빌드 불필요 | Linux: systemd `widgetrag-frontend` (ExecStart=`python3 -m http.server 5500 --directory frontend`) |
| LLM (Ollama) | `ollama pull gemma3:4b` (기본 — Gemma 약관 OLA 표기) | 시스템 서비스 (systemd) |
| SQLite (임베디드) | 설치 불필요 — 백엔드 jar에 드라이버 포함 | 없음 (백엔드 프로세스 내장, DB 파일: `~/widgetrag-data/widgetrag.db`) |
| OpenSearch 2.18 | 공식 apt 저장소 + `apt install opensearch=2.18.0` | systemd 서비스 |

## 단계별 실행 (상세 — 래퍼의 내부 구성)

문제 격리나 부분 재실행이 필요할 때는 번호 스크립트를 직접 사용한다:

```bash
./bootstrap.sh            # [진입점] git clone + NVIDIA 드라이버(재부팅 자동 재개) + 형태 진입 — 신규 VM·postCommands용
#                           --start: shell 설치형(A) 무인 기동 · --compose: Docker Compose(B) 무인 기동 (../compose/setup.sh)
./10-install-tools.sh     # [Phase A] 도구 설치 (apt — JDK·Python·OpenSearch·Ollama)
./20-start-infra.sh       # [Phase B] OpenSearch(systemd) + Ollama + 모델 확보
./30-setup-config.sh      # [Phase C] application-local.yaml 생성 + 저장 디렉토리
./40-start-apps.sh        # [Phase D~F] AI 서버(venv) → 백엔드(java -jar) → 프론트 기동
./50-verify.sh            # 6개 구성요소 + 모델 헬스 체크 + SQLite 기능 등가성 (RUNS=N 반복 검증)
./60-export-data.sh       # [이관] 데이터 내보내기 — WAL 체크포인트 + SHA-256 매니페스트 + (선택) 오브젝트 스토리지 업로드
./61-import-data.sh       # [이관] 데이터 가져오기 — 복원 + 용량·개수·해시 정합성 검증
./62-export-index.sh      # [이관] 색인 내보내기 — OpenSearch 스냅샷 (무중지·증분, 방법③)
./63-import-index.sh      # [이관] 색인 가져오기 — 스냅샷 복원 + 인덱스별 문서 수 대조
./90-stop-all.sh          # 전체 종료 (= stop.sh)
./91-wipe-data.sh --yes   # 완전 삭제 — "완전 삭제 후 복구" 리허설용 (이관 패키지 자족성 증명)
```

- 모든 스크립트는 **멱등** — 여러 번 실행해도 안전하고, 이미 떠 있는 것은 건너뛴다.
- 공통 설정은 [env.sh](env.sh) — 실행 전 환경변수로 덮어쓸 수 있다.
- 앱 프로세스는 nohup 백그라운드로 뜨며 로그는 `logs/`, PID는 `pids/`에 남는다.

## E2E 스모크 테스트

최초 1회는 브라우저에서 회사 가입 → 관리자 승인 → CSV 업로드가 필요하다
(가입: `http://localhost:5500/login/company-signup.html`).
이후에는 발급받은 클라이언트 코드로 챗봇까지 자동 검증:

```bash
CLIENT_CODE=shop_xxxxxxxx ./50-verify.sh
```

## 순수 형태 원칙

Track A(shell 설치형)는 **전 구성요소 네이티브**다 — 이 VM에는 Docker 자체가 없고,
OpenSearch는 apt 직접 설치 + systemd, 앱 3종도 systemd 유닛으로 뜬다.
스크립트는 Ubuntu Linux 전용이며 다른 OS에서는 기동을 거부한다 (env.sh 가드).
Docker Compose 형태(전부 컨테이너)는 별도 트랙 — 프로젝트 루트의 `docker-compose.yml` 사용.

## 주요 환경변수 (env.sh 기본값)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `WIDGETRAG_ADMIN_PASSWORD` | (미지정 시 무작위 생성) | 관리자 계정 비밀번호 — 미지정이면 최초 실행에서 자동 생성되어 `scripts/local/.admin-password`(600)에 저장·재사용 |
| `OLLAMA_MODEL` | `exaone3.5:7.8b` | 레지스트리 차단 시 HuggingFace 경유 자동 폴백 |
| `PYTHON_BIN` | `python3.12` | venv 생성용 — 3.14는 torch 미지원 |
| `STORAGE_DIR` | `~/widgetrag-data` | CSV 업로드 파일 저장 경로 |

## Ubuntu GPU VM (실증 이관 대상 환경) 이식 시

- `10-install-tools.sh`가 Ubuntu 분기를 포함하나, **NVIDIA 드라이버는 선행 설치 필요**
  (CUDA Toolkit은 불필요 — pip torch·Ollama가 런타임 자체 번들)
- AI 서버 임베딩은 CUDA 자동 감지(`main_exaone.py`), Ollama도 GPU 자동 사용
- 상세 절차는 `WidgetRAG-EC2기동-가이드.html` 참고

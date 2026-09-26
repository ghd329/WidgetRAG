# WidgetRAG shell 설치형 기동 스크립트

용역 요구사항 2번 — **shell script 방식 기동 확인** 산출물.
IDE·수작업 없이 셸 커맨드 절차만으로 전체 스택을 설치·기동·검증·종료한다.
계획서의 실행 형태 2종 중 **"shell 설치형"** 에 해당한다 (Docker Compose 형태는 [`../compose/`](../compose/)).

> **실증 환경(Ubuntu Linux GPU VM) 전용** — 전 구성요소 네이티브(Docker 없음)이며,
> macOS 등 로컬 우회 경로는 두지 않는다. 로컬 검증이 필요하면 Docker Compose(B) 트랙을 사용.
> 진입 방식 · 이관 패키지 · 검증 기준은 LexAI(`legal-rag-chatbot` `deploy/native/`)와 같다.

## 새 환경에 올릴 때 — 한 줄

사람이 하는 일은 **VM 생성과 SSH 접속까지**다. 그 뒤는 이 한 줄이 코드 확보 · GPU 드라이버 ·
설치 · 데이터 복원 · 기동 · 검증을 무인으로 수행한다 (이관 도구의 postCommands 페이로드와 동일).

```bash
curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/local/bootstrap.sh | bash
```

이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주면 색인 · DB · 업로드 파일까지 받아 복원한다.

```bash
curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/20260924-1030 bash
```

- 드라이버가 없는 인스턴스면 설치 후 **스스로 재부팅하고, 부팅이 끝나면 같은 지점부터 자동으로 이어서 진행한다**.
  진행 상황은 `sudo journalctl -u widgetrag-bootstrap-resume -f`.
  `curl | bash` 앞에 붙인 환경변수(`SNAPSHOT_URI` 등)도 재부팅 뒤까지 넘어간다 (root 600 환경 파일).
- **root 로 실행되면**(CB-Tumblebug `postCommands`) uid 1000 사용자로 저장소를 받고 그 사용자로 이어서 실행한다 —
  서비스가 `/root` 아래에 깔려 나중에 사람이 SSH 로 붙었을 때 아무것도 안 보이는 상황을 막는다.
- **파이프로 실행해도 안전하다** — 받은 저장소의 사본으로 갈아타 `</dev/null` 로 다시 실행하므로,
  안쪽 명령이 stdin 을 읽어도 스크립트 본문이 잘리지 않는다 (LexAI 결함 4).
- TTY 가 없으면 색상 제어문자를 출력하지 않고, apt 는 비대화형으로 동작한다.

| 환경변수 | 기본값 | 용도 |
| --- | --- | --- |
| `BRANCH` | 기존 clone 의 브랜치 → `feat/20260922-change-sqlite` | 받을 브랜치 |
| `COMMIT` | — | 커밋 고정 (실증 재현성) |
| `SNAPSHOT_URI` | — | 이관 패키지 위치 (`s3://` · `gs://` · `https://` · 로컬 경로) |
| `S3_ENDPOINT_URL` | — | S3 호환 스토리지 주소 (NCP 등) |
| `FORCE_RESTORE=1` | — | DB · 색인이 이미 있어도 패키지로 덮어씀 (기본은 건너뜀) |
| `NO_DRIVER=1` | — | GPU 이미지를 쓰는 경우 드라이버 설치 생략 |
| `NO_START=1` | — | 준비만 하고 기동은 하지 않음 (= `--install`) |
| `TARGET_USER` | uid 1000 | root 로 실행될 때 서비스를 돌릴 사용자 |

첫 실행이 자신을 `/usr/local/bin/bootstrap.sh` 로 설치하므로, 이후에는 `bootstrap.sh` 만 치면 된다.

## 이미 올라간 환경에서 — 커맨드 2개

요구사항 예시(`npm install` 후 `npm run prod`)와 동일한 2단계 인터페이스:

```bash
cd scripts/local
./install.sh     # ← npm install 에 해당: 도구 설치 + 설정 생성 (최초 1회)
./start.sh       # ← npm run prod 에 해당: 인프라 → 패키지 복원 → 앱 → 검증, 단계별 소요 시간 출력
./stop.sh        # 전체 종료 (역순, 데이터 유지)
```

`start.sh` 는 백지 상태에서도, 이미 다 깔린 상태에서도 그대로 동작한다. 단계별 소요 시간을
마지막에 출력하므로 "새 환경에서 몇 분 걸리나"(이관 예상 시간)를 재는 용도로도 쓴다.

## 합격 기준 검증

두 실행 형태가 **같은 판정 코드**([`../verify.sh`](../verify.sh))와 같은 결과표를 쓴다.
`50-verify.sh` 는 이 형태의 경로 · 포트를 채워 그 파일을 부른다.

```bash
./50-verify.sh                              # 구성요소 · 프론트 · 인증 · 채팅 · 데이터 · 로그
FORM=aws-shell RUNS=5 ./50-verify.sh        # 환경 이름 태깅 · 웜 응답 5회로 p50/p95
REPEAT=5 ./50-verify.sh                     # 검증 전체를 5회 연속 — 전 회차 PASS 여야 성공
VERIFY_ADMIN_PASSWORD=<소스 비밀번호> ./50-verify.sh   # 이관된 DB 의 관리자 로그인까지 판정
EXPECT_TRIGGERS=0 ./50-verify.sh            # 트리거 수를 소스 값과 대조
```

- 채팅할 회사는 자동으로 고른다 (상품이 가장 많은 승인된 회사 — `CLIENT_CODE` 로 지정 가능).
- 채팅은 브라우저와 같은 경로(프론트의 `/api` 프록시)로 보내고, **추천 상품 > 0 · fallback 아님 · p95 < 180초**를 본다.
- 데이터 없는 새 환경(가입 · 업로드 전)은 채팅을 건너뛰고 WARN. 이관 패키지를 복원한 환경은 데이터가 없으면 FAIL.
- 결과는 `~/widgetrag-run/results.csv` 에 한 줄씩 쌓인다 (LexAI 와 같은 열):

```
timestamp,form,runs,pass,fail,cold_sec,p50_sec,p95_sec,sources,os_docs,db_msgs,result
```

## 이관 패키지 — 두 형태 공용

상태 데이터(색인 · DB · 업로드 파일)만 옮기고, 프로그램 · 미들웨어 · 모델은 타겟에서 새로 마련한다.
패키지 형식은 실행 형태와 무관하다 — **Shell 설치형에서 뜬 패키지를 Docker Compose 에, 그 반대로도 복원된다.**

```bash
# [소스] 서비스를 멈추지 않고 패키지 생성 — UPLOAD_URI 를 주면 업로드까지
UPLOAD_URI=s3://버킷/widgetrag/$(date +%Y%m%d-%H%M) bash ../package.sh backup

# [타겟] 위 한 줄 진입물에 SNAPSHOT_URI 로 넘기면 끝 (이미 올라간 환경이면)
SNAPSHOT_URI=s3://버킷/widgetrag/20260924-1030 ./start.sh
```

| 파일 | 내용 |
| --- | --- |
| `opensearch-snapshots.tar.gz` | 색인 스냅샷 저장소 (안에 `contents.tsv` — 풀자마자 개수 · 용량 · 해시 3종 대조) |
| `widgetrag.db` | SQLite — `VACUUM INTO` 로 뜬 일관된 단일 파일 (서비스 중에도 안전) |
| `uploads.tar.gz` | 업로드 CSV (안에 `contents.tsv`) |
| `doccount.tsv` | 인덱스별 문서 수 — 복원 후 대조 |
| `package.env` | 원본 형태 · 업로드 경로 접두사 — 복원 시 `product.storage_path` 재작성에 사용 |
| `checksums.sha256` | 위 파일들의 SHA-256 — 전송 직후 대조 |

복원은 **앱 첫 기동 전**에 한다 — 백엔드는 기동할 때 색인이 없으면 빈 색인을, DB 가 없으면 빈 DB 와
관리자 계정을 만든다. `start.sh` 가 인프라 → `35-restore-package.sh` → 앱 순서로 이를 지킨다.
타겟에 DB · 색인이 이미 있으면 복원을 건너뛴다 (재실행 안전, 덮어쓰려면 `FORCE_RESTORE=1`).
관리자 비밀번호는 패키지에 넣지 않는다 — 이관된 DB 의 계정은 **소스의 비밀번호**로 로그인한다.

## 접속

외부 포트는 열지 않는다(보안 그룹은 22 만). 두 형태 모두 같은 터널 하나로 들어온다.

```bash
ssh -i <키> -N -L 8081:localhost:80 ubuntu@<IP>      # 이후 브라우저로 http://localhost:8081
```

프론트는 nginx 로 뜨고 `/api` · `/widget.js` 를 백엔드로 프록시한다 (Docker Compose 형태와 같은
`frontend/nginx.conf` 에서 생성). 화면과 API 가 같은 오리진이라 콘솔 · 데모샵 모두 이 주소로 동작한다.
최초 1회는 회사 가입(`/login/company-signup.html`) → 관리자 승인 → CSV 업로드가 필요하다.

## 서비스별 표준 커맨드 (래퍼가 내부에서 수행하는 순정 절차)

마이그레이션 도구가 식별·이전해야 할 대상이 바로 이 커맨드들이다 (실행 파일·의존 패키지·환경변수).
앱 3종의 실행 명령(ExecStart)과 환경변수(EnvironmentFile `/etc/widgetrag/widgetrag.env`)가 표준 위치에 드러난다.

| 서비스 | 의존성 설치 (`npm install` 상당) | 기동 (`npm run prod` 상당) |
|---|---|---|
| AI 서버 (FastAPI) | `python3.12 -m venv .venv && .venv/bin/pip install -r requirements_exaone.txt` | systemd `widgetrag-ai` (ExecStart=`.venv/bin/uvicorn main_exaone:app --host 0.0.0.0 --port 8000`) |
| 백엔드 (Spring Boot) | `./mvnw package -DskipTests` | systemd `widgetrag-backend` (ExecStart=`java -jar target/backend-*.jar --spring.profiles.active=local`) |
| 프론트엔드 (정적 + /api 프록시) | 빌드 불필요 · `apt install nginx` | systemd `widgetrag-frontend` (ExecStart=`nginx -c /etc/widgetrag/frontend-nginx.conf -g 'daemon off;'`) |
| LLM (Ollama) | `ollama pull gemma3:4b` (기본 — Gemma 약관 OLA 표기) | 시스템 서비스 (systemd) |
| SQLite (임베디드) | 설치 불필요 — 백엔드 jar에 드라이버 포함 | 없음 (백엔드 프로세스 내장, DB 파일: `~/widgetrag-data/widgetrag.db`) |
| OpenSearch 2.18 | 공식 apt 저장소 + `apt install opensearch=2.18.0` | systemd 서비스 (`path.repo=/var/lib/opensearch/snapshots`) |

## 단계별 실행 (상세 — 래퍼의 내부 구성)

문제 격리나 부분 재실행이 필요할 때는 번호 스크립트를 직접 사용한다:

```bash
./bootstrap.sh            # [진입점] 코드 확보 + NVIDIA 드라이버(재부팅 자동 재개) + install → start (기본 --start)
./10-install-tools.sh     # [Phase A] 도구 설치 (apt — JDK·Python·nginx·pigz·OpenSearch·Ollama)
./20-start-infra.sh       # [Phase B] OpenSearch(systemd) + Ollama + 모델 확보
./30-setup-config.sh      # [Phase C] application-local.yaml 생성 (값이 바뀌었을 때만 백업 후 갱신)
./35-restore-package.sh   # [이관] 패키지 복원 — SNAPSHOT_URI 또는 ~/widgetrag-package, 없으면 건너뜀
./40-start-apps.sh        # [Phase D~F] AI 서버(venv) → 백엔드(java -jar) → 프론트(nginx)
./50-verify.sh            # 합격 기준 검증 (공용 ../verify.sh — results.csv 누적)
./64-export-model.sh      # [이관·선택] LLM 모델 내보내기 — 패키지와 별도, 모델까지 옮길 때 (vLLM 실증 경로 원형)
./65-import-model.sh      # [이관·선택] LLM 모델 가져오기 — 복원 + ollama 인식(경로 재연결) 자동 판정
./90-stop-all.sh          # 전체 종료 (= stop.sh)
./91-wipe-data.sh --yes   # 완전 삭제 — "완전 삭제 후 복구" 리허설용 (이관 패키지 자족성 증명)
bash ../package.sh backup|fetch|restore   # 이관 패키지 도구 (두 형태 공용)
```

- 모든 스크립트는 **멱등** — 여러 번 실행해도 안전하고, 이미 된 것은 건너뛴다.
- 공통 설정은 [env.sh](env.sh) — 실행 전 환경변수로 덮어쓸 수 있다.
- 앱 로그는 journald — `journalctl -u widgetrag-backend -f` (widgetrag-ai / widgetrag-frontend 동일).

## 주요 환경변수 (env.sh 기본값)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `WIDGETRAG_ADMIN_PASSWORD` | (미지정 시 무작위 생성) | 관리자 계정 비밀번호 — 최초 실행에서 자동 생성되어 `scripts/local/.admin-password`(600)에 저장·재사용 |
| `OLLAMA_MODEL` | `gemma3:4b` | 레지스트리 차단 시 HuggingFace 경유 자동 폴백 |
| `LLM_TEMPERATURE` · `LLM_SEED` | `0.7` · (없음) | 이관 전후 동등성 비교는 `0` · `42` 처럼 결정적 설정으로 |
| `APP_TZ` | `Asia/Seoul` | 앱의 시각 기준 (`TZ` 로 넘어감) — VM 이미지의 기본 타임존과 무관하게 고정 |
| `PORT_FRONTEND` | `80` | 5500/5501/3000 은 쓰지 말 것 — `api.js` 가 로컬 개발로 보고 `:8080` 을 직접 부른다 |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:8081,http://127.0.0.1:8081` | 터널 오리진 — Docker Compose 형태의 `.env` 와 같은 값 |
| `PUBLIC_BASE_URL` | `http://localhost:8081` | 위젯 설치 코드의 `widget.js` 주소 기준 |
| `STORAGE_DIR` | `~/widgetrag-data` | SQLite DB + CSV 업로드 파일 |
| `PACKAGE_DIR` | `~/widgetrag-package` | 받은 이관 패키지 |
| `PYTHON_BIN` | `python3.12` | venv 생성용 — 3.14는 torch 미지원 |

## 이 스크립트들이 막아 주는 함정

전부 실제로 한 번씩 겪었거나(WidgetRAG · LexAI) 실측으로 확인한 것들이다.

| 함정 | 증상 · 대응 |
| --- | --- |
| `curl \| bash` 에서 안쪽 명령이 stdin 을 읽음 | 남은 본문이 사라져 종료코드 0 으로 조용히 끝남 → 저장소 사본으로 `</dev/null` 재실행 |
| postCommands 가 root 로 실행 | 서비스가 `/root` 아래에 깔림 → uid 1000 사용자로 전환 |
| 재부팅 후 환경변수 유실 | 재개 유닛이 `SNAPSHOT_URI` 없이 돌아 복원이 빠짐 → root 600 환경 파일로 전달 |
| 백엔드가 먼저 떠서 빈 색인 · 빈 DB 생성 | 복원이 "이미 있음"으로 막히거나 덮어씀 → 앱 기동 전에 복원 (`35-restore-package.sh`) |
| 실행 중 `.db` 만 복사 | `-wal` 의 최근 쓰기 누락 → `VACUUM INTO` 로 일관된 단일 파일 |
| 업로드 경로가 절대경로로 DB 에 저장됨 | 저장 경로가 다른 곳(A↔B, CSP 마다 다른 기본 사용자)으로 옮기면 파일 삭제가 조용히 실패 → 복원 시 접두사 재작성 |
| 스냅샷 파일 소유자 불일치 | 컨테이너(uid 1000) ↔ 네이티브(opensearch) 사이에서 `access_denied` → 복원 시 소유권 정정 |
| `opensearch.yml` 을 일반 사용자로 읽음 | 못 읽은 걸 "없음"으로 보고 `path.repo` 를 덧붙이면 중복 키로 기동 실패 → `sudo grep` |
| 타임존 미지정 | VM 이미지마다 UTC/KST 가 달라 기록 시각이 9시간 어긋남 → `TZ` 고정 + 검증 |
| 첫 응답을 기준선으로 씀 | 모델 VRAM 로드가 섞임 → 콜드 1회 + 웜 `RUNS` 회로 p50/p95 |

## 순수 형태 원칙

Track A(shell 설치형)는 **전 구성요소 네이티브**다 — 이 VM에는 Docker 자체가 없고,
OpenSearch는 apt 직접 설치 + systemd, 앱 3종도 systemd 유닛으로 뜬다.
스크립트는 Ubuntu Linux 전용이며 다른 OS에서는 기동을 거부한다 (env.sh 가드).
두 형태는 같은 포트(80 · 9200)와 GPU 를 쓰므로 **같은 VM 에 동시에 띄우지 않는다** — 형태별로 VM 을 둔다.
Docker Compose 형태(전부 컨테이너)는 [`../compose/`](../compose/) — 타겟은 저장소를 clone하지 않고
배포 파일만 raw 로 받아 실행한다 (타겟에 소스·git 불필요 — 이미지가 곧 산출물).

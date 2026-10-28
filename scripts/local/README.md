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
  설치 전에 커널 메타 패키지를 올려 드라이버 모듈 · 헤더의 커널 ABI 를 맞추고, 설치 뒤에는 패키지 상태 · 모듈 파일로
  성공을 확인한 뒤에만 재부팅한다 (미구성이면 재부팅하지 않고 멈춘다 — 저장소에 새 커널이 올라와 이미지의 헤더가 뒤처진 경우).
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
| `NVIDIA_DRIVER_SERIES` | (빈 값) | 설치할 드라이버 시리즈. 빈 값이면 `ubuntu-drivers` 추천판(LexAI 네이티브와 같은 방식) — 날짜 · 이미지에 따라 버전이 달라질 수 있다. 소스 · 타겟을 같은 버전으로 맞추려면 `595` 처럼 지정(`ubuntu-drivers install nvidia:595`), 지정판이 구성되지 않으면 추천판으로 진행. 성공 여부는 ubuntu-drivers 의 종료 코드가 아니라 패키지 상태(`dpkg`) · 모듈 파일로 판정한다 |
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

상태 데이터(색인 · DB · 업로드 파일)에 더해, 소스가 Shell 설치형이면 **실행 파일 층**(scripts · backend jar · frontend ·
ai-server 소스 + pip 잠금 목록)을 함께 싣는다 — 계획서의 "실행 파일 · 스크립트 · 의존 패키지 · 환경변수 이전".
미들웨어(OpenSearch · Ollama · nginx · Java)와 모델은 타겟에서 같은 버전으로 다시 마련하고 버전 · digest 를 대조한다.
패키지 형식은 실행 형태와 무관하다 — **Shell 설치형에서 뜬 패키지를 Docker Compose 에, 그 반대로도 복원된다**
(Compose 타겟은 실행 파일 층을 받아만 두고 쓰지 않는다 — 거기서는 이미지가 실행 파일).

```bash
# [소스] 서비스를 멈추지 않고 패키지 생성 — GOLDEN=1 이면 LLM 골든 답변까지, UPLOAD_URI 를 주면 업로드까지
GOLDEN=1 RUNTIME=native bash ../package.sh backup            # → ~/widgetrag-backup/<시각>/

# [타겟 · 권장] rsync/scp 로 ~/widgetrag-package 에 넣고 진입물을 SNAPSHOT_URI 없이 — 트리를 풀어 빌드 없이 기동한다
rsync -a 소스:~/widgetrag-backup/<시각>/ ~/widgetrag-package/
curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/local/bootstrap.sh | COMPARE=1 bash
#   ※ 같은 디렉토리를 SNAPSHOT_URI 로 주면 fetch 가 "원본 = 목적지" 로 거부한다

# [타겟] 오브젝트 스토리지 경유 — 이미 올라간 환경이면 start.sh 에 (처음이면 bootstrap.sh 에)
SNAPSHOT_URI=s3://버킷/widgetrag/<시각> ./start.sh
```

| 파일 | 내용 |
| --- | --- |
| `opensearch-snapshots.tar.gz` | 색인 스냅샷 저장소 (안에 `contents.tsv` — 풀자마자 개수 · 용량 · 해시 3종 대조) |
| `widgetrag.db` | SQLite — `VACUUM INTO` 로 뜬 일관된 단일 파일 (서비스 중에도 안전) |
| `uploads.tar.gz` | 업로드 CSV (안에 `contents.tsv`) |
| `doccount.tsv` | 인덱스별 문서 수 — 복원 후 대조 |
| `package.env` | 원본 형태 · 업로드 경로 접두사 — 복원 시 `product.storage_path` 재작성에 사용. `APP_*` 로 소스의 LLM 설정 · 모델 · TZ 도 담는다 |
| `checksums.sha256` | 위 파일들의 SHA-256 — 전송 직후 대조 |
| `package-files.tsv` | 패키지 파일 전부의 바이트 · SHA-256 (아래 파일 포함) — `fetch` 가 이 목록대로 받아 대조한다 |
| `app-tree.tar.gz` | **실행 파일 층** (소스가 Shell 일 때) — `scripts/` · `backend/target/backend-*.jar` · `frontend/` · `ai-server/`(소스 + `requirements-lock.txt`) + 루트의 `app-tree.env` · `app-manifest.tsv` |
| `app-wheels.tar.gz` | `WITH_WHEELS=1` 일 때만 — 잠금 목록의 wheel (폐쇄망용, 수 GB) |
| `baseline-app.tsv` · `baseline-env.tsv` | 실행 파일 기준선(jar · 트리 · pip 잠금 · 설치된 pip 목록 · 커밋 — 완전 일치) · 실행 환경 기준선(java · python · nginx · OpenSearch · Ollama · 드라이버 · GPU · 모델 — 차이는 WARN) |
| `baseline-db.tsv` · `baseline-rag*.tsv` · `golden.json` | 데이터 · 색인 · LLM 응답 기준선 (아래 "이관 동등성 테스트") |

복원은 **앱 첫 기동 전**에 한다 — 백엔드는 기동할 때 색인이 없으면 빈 색인을, DB 가 없으면 빈 DB 와
관리자 계정을 만든다. `start.sh` 가 인프라 → `35-restore-package.sh` → 앱 순서로 이를 지킨다.

### 실행 파일 이전 (Shell → Shell)

타겟을 저장소에서 다시 빌드하면 "이전"이 아니라 "재구축"이고, 그 사이 pip 가 다른 torch 를 풀어 오면 임베딩이 달라져
동등성이 깨진다. 그래서 소스에서 **돌고 있던 산출물을 그대로** 옮긴다.

| 구성요소 | 옮기는 것 | 타겟이 하는 일 |
| --- | --- | --- |
| 백엔드 | 빌드된 `backend/target/backend-*.jar` | 빌드 없이 그대로 기동 (`./mvnw` 호출 안 함). 설정은 `/etc/widgetrag/application-local.yaml` 에 새로 생성 |
| 프론트 | `frontend/` 디렉토리 통째 (빌드 없음) | nginx 설정을 타겟 경로로 다시 생성 |
| AI 서버 | 소스 `ai-server/*.py` + `requirements-lock.txt`(소스 venv 의 `pip freeze --all`) | venv 를 **잠금 목록 그대로** 다시 만든다 — venv 자체는 절대 경로가 박혀 옮길 수 없다 |
| 스크립트 | `scripts/` 전체 (진입물 · 생성기 · 검증기) | 패키지 안의 `bootstrap.sh` 로 갈아타 소스와 같은 스크립트로 기동 |
| 환경변수 | `package.env` 의 `APP_LLM_TEMPERATURE` · `APP_LLM_SEED` · `APP_OLLAMA_MODEL` · `APP_TZ` (비밀값 제외) | 명시 지정이 없으면 소스 값을 기본값으로 쓴다 |
| 유닛 · nginx 설정 · venv · 모델 · 미들웨어 | 옮기지 않음 | 생성기 · 버전 고정 설치 · digest 대조로 같게 만든다 |

- 진입물의 동작: `bootstrap.sh` 는 `SNAPSHOT_URI` 또는 `PACKAGE_DIR` 에 `app-tree.tar.gz` 가 있으면 git clone 대신 그 트리를
  `TARGET_DIR` 에 풀고(해시 · 파일 목록 대조) 그 안의 스크립트로 이어 간다. 이미 같은 트리가 있으면 건너뛰고, git clone 이
  있으면 `.bak.<시각>` 으로 비켜 둔다 (`CODE_SOURCE=auto|package|git`). 트리 루트의 `app-tree.env` 가 "패키지 모드"의 표식이다.
- 검증: `COMPARE=1` 의 T1-3 에 `app:jar` · `app:scripts` · `app:frontend` · `app:ai-server` · `app:pip-lock` · `app:pip-installed` · `app:code_ref`
  행이 붙는다 (완전 일치). `runtime:*` 행(java · python · nginx · OpenSearch · Ollama · 드라이버 · GPU · 모델 digest)은 달라도 WARN.
- 한계: 소스가 Compose(B)이면 실행 파일 층이 없어 Shell 타겟은 저장소 clone 으로 돌아간다(`app:mode` WARN) — B→A 의 코드 확보 방식은 **결정 필요**.
  wheel 동봉(`WITH_WHEELS=1`)과 apt 패키지(.deb) 동봉 여부도 **결정 필요** — 지금은 잠금 목록 + 버전 고정 설치가 기본이다.
타겟에 DB · 색인이 이미 있으면 복원을 건너뛴다 (재실행 안전, 덮어쓰려면 `FORCE_RESTORE=1`).
관리자 비밀번호는 패키지에 넣지 않는다 — 이관된 DB 의 계정은 **소스의 비밀번호**로 로그인한다.

## 이관 동등성 테스트

소스에서 패키지를 뜰 때 기준선(데이터 해시 · LLM 골든 답변)을 함께 싣고, 타겟 검증의 7절이 그것과 대조한다.
기본은 꺼져 있다(`COMPARE=0`) — 테스트할 때만 켠다.

```bash
# [소스] 결정적 설정으로 재기동 → 기준선 + 골든(질문 5개 × 2회)까지 패키지 생성
#   RUNTIME=native 를 적는다 — 같은 VM 에 Docker Compose 가 떠 있으면 자동 판별이 compose 를 골라 B 의 기준선을 뜬다
LLM_TEMPERATURE=0 LLM_SEED=42 ./40-start-apps.sh
RUNTIME=native GOLDEN=1 UPLOAD_URI=s3://버킷/widgetrag/$(date +%Y%m%d-%H%M) bash ../package.sh backup

# [타겟] 같은 결정적 설정으로 복원 · 기동 · 대조 (이미 올라간 환경이면 COMPARE=1 ./50-verify.sh)
curl -fsSL <bootstrap 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/<시각> LLM_TEMPERATURE=0 LLM_SEED=42 COMPARE=1 bash
```

- 결과는 `~/widgetrag-run/migration-compare.csv` 에 행 단위로 쌓이고, 증적(원시 응답 · 해시 · 차이)은
  `~/widgetrag-run/migration-<시각>/` — 요약은 그 안의 `summary.txt`.
- **테스트1** (데이터 이관): ① 서비스 · 컨테이너 수와 역할 ② 패키지 파일별 용량 · SHA-256 ③ 데이터 내용 —
  DB 테이블별 행 해시(`chat_log` 는 이관 시점까지, 업로드 경로 접두사는 정규화) · 색인 문서 해시 · 업로드 파일.
- **테스트2** (LLM 응답 동일성): 골든 질문마다 **추천 상품(검색 결과) 목록 · 순서 동일 + fallback 아님**이면 통과 기준이고,
  답변 문자열은 **환경(GPU · 드라이버 · Ollama 버전 · 모델 digest)이 소스와 모두 같을 때만** 바이트 단위 동일을 요구한다 (다르면 FAIL).
  환경이 하나라도 다르면 문장 차이는 WARN 으로 두고 유사도 · 차이 파일(`golden-diff/`)을 남긴다 — GPU 가 바뀌면 온도 0 · seed 고정이어도 문장이 갈릴 수 있다.
  추천 상품이 다르거나 응답이 비정상이면 FAIL, temperature · seed · 모델이 다르면 비교가 성립하지 않아 FAIL.
- Shell 설치형은 Ollama 를 `OLLAMA_VERSION=0.34.3`(env.sh 기본값 — Docker Compose llm 이미지와 같은 버전)으로 설치한다.
  이미 다른 버전이 깔려 있으면 `10-install-tools.sh` 가 경고만 한다 (재설치 명령을 함께 출력).
- `GOLDEN_CHECK=0` 이면 테스트2 만 건너뛴다 (SKIP).
- `package.sh` 는 같은 디렉토리의 `migcheck.py`(해시 · 판정 계산)를 쓴다 — `backup` 도 이것이 없으면 멈춘다.
  저장소에 함께 있으니 따로 복사해 쓸 때는 둘을 같이 옮긴다.

## 접속

외부 포트는 열지 않는다(보안 그룹은 22 만). 두 형태 모두 같은 터널 하나로 들어온다. 보안 그룹에 80 을 열어 공인 IP 로 직접 들어와도
콘솔이 동작한다 — 세션 쿠키를 HTTP 에서도 저장되게 둔다(`SESSION_SECURE=false` · `SESSION_SAME_SITE=lax`, Docker Compose 형태와 같은 값).

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
| AI 서버 (FastAPI) | `python3 -m venv .venv && .venv/bin/pip install -r requirements_exaone.txt` (이관 트리면 `requirements-lock.txt` 그대로) | systemd `widgetrag-ai` (ExecStart=`.venv/bin/uvicorn main_exaone:app --host 0.0.0.0 --port 8000`) |
| 백엔드 (Spring Boot) | `./mvnw package -DskipTests` (이관 트리면 소스의 jar 그대로) | systemd `widgetrag-backend` (ExecStart=`java -jar target/backend-*.jar --spring.profiles.active=local --spring.config.additional-location=file:/etc/widgetrag/`) |
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
./30-setup-config.sh      # [Phase C] /etc/widgetrag/application-local.yaml 생성 (jar 밖 — 값이 바뀌었을 때만 백업 후 갱신)
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
| `WIDGETRAG_ADMIN_PASSWORD` | `env.sh` 기본값 | 관리자 계정 비밀번호 — 쓴 값은 `scripts/local/.admin-password`(600)에 저장 · 재사용하고, 이미 저장된 값이 있으면 그것을 쓴다. `bootstrap.sh` 앞에 붙이면 재부팅 재개까지 넘어간다 |
| `OLLAMA_MODEL` | `gemma3:4b` | 레지스트리 차단 시 HuggingFace 경유 자동 폴백 |
| `OLLAMA_VERSION` | `0.34.3` | Ollama 고정 버전 — Docker Compose llm 이미지와 같게 (교차 이관 LLM 응답 일치의 전제). 빈 값이면 최신 |
| `OLLAMA_KEEP_ALIVE` | `24h` | 모델을 VRAM 에 올려 둔 채 유지하는 시간 (systemd 드롭인으로 적용). 기동 때 모델을 미리 올려 두므로 첫 질문에 적재 시간이 붙지 않고, 대량 업로드 뒤에도 모델이 CPU 로 밀리지 않는다 |
| `LLM_TEMPERATURE` · `LLM_SEED` | `0.7` · (없음) | 이관 전후 동등성 비교는 `0` · `42` 처럼 결정적 설정으로 |
| `APP_TZ` | `Asia/Seoul` | 앱의 시각 기준 (`TZ` 로 넘어감) — VM 이미지의 기본 타임존과 무관하게 고정 |
| `PORT_FRONTEND` | `80` | 5500/5501/3000 은 쓰지 말 것 — `api.js` 가 로컬 개발로 보고 `:8080` 을 직접 부른다 |
| `CORS_ALLOWED_ORIGINS` | `http://localhost:8081,http://127.0.0.1:8081` | 터널 오리진 — Docker Compose 형태의 `.env` 와 같은 값 |
| `PUBLIC_BASE_URL` | `http://localhost:8081` | 위젯 설치 코드의 `widget.js` 주소 기준 |
| `SESSION_SECURE` · `SESSION_SAME_SITE` | `false` · `lax` | 콘솔 세션 쿠키 — Docker Compose 형태의 `.env` 와 같은 값. HTTPS 종단을 붙이면 `true` · `none` (`none` 은 `true` 와 함께만) |
| `STORAGE_DIR` | `~/widgetrag-data` | SQLite DB + CSV 업로드 파일 |
| `PACKAGE_DIR` | `~/widgetrag-package` | 받은 이관 패키지 — rsync 로 여기 넣으면 `SNAPSHOT_URI` 없이 복원 · 트리 전개까지 된다 |
| `CODE_SOURCE` | `auto` | `bootstrap.sh` 의 코드 확보 — `auto`: 패키지에 실행 파일 층이 있으면 그 트리, 없으면 clone · `package`: 트리만(없으면 실패) · `git`: 항상 clone |
| `WITH_WHEELS` | `0` | `package.sh backup` 때 잠금 목록의 wheel 을 동봉 (폐쇄망용 — 수 GB) |
| `PYTHON_BIN` | `python3` | venv 생성용 — OS 기본 파이썬(22.04 는 3.10, 24.04 는 3.12, LexAI 네이티브와 같은 방식). 3.10 미만이면 멈추고, 3.14 이상은 경고만 |

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
| 설정 파일이 jar 안에 구워짐 | `src/main/resources` 에 쓴 `application-local.yaml` 을 Maven 이 jar 에 넣어 소스 VM 의 절대 경로가 박힘 → `/etc/widgetrag/` 에 두고 `--spring.config.additional-location` 으로 읽음 (jar 를 그대로 옮길 수 있다) |
| 타겟에서 pip 가 다른 torch 를 받음 | 임베딩 값이 달라 검색 · 답변이 갈림 → 소스 venv 의 `pip freeze --all` 잠금 목록으로 설치하고 `app:pip-installed` 행으로 증명 |

## 순수 형태 원칙

Track A(shell 설치형)는 **전 구성요소 네이티브**다 — 이 VM에는 Docker 자체가 없고,
OpenSearch는 apt 직접 설치 + systemd, 앱 3종도 systemd 유닛으로 뜬다.
스크립트는 Ubuntu Linux 전용이며 다른 OS에서는 기동을 거부한다 (env.sh 가드).
두 형태는 같은 포트(80 · 9200)와 GPU 를 쓰므로 **같은 VM 에 동시에 띄우지 않는다** — 형태별로 VM 을 둔다.
Docker Compose 형태(전부 컨테이너)는 [`../compose/`](../compose/) — 타겟은 저장소를 clone하지 않고
배포 파일만 raw 로 받아 실행한다 (타겟에 소스·git 불필요 — 이미지가 곧 산출물).

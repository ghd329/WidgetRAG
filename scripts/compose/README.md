# Docker Compose 배포 스크립트

이관 대상 환경의 **실행 형태 2종 중 컨테이너 쪽** 진입물이다.
Shell 설치형은 [`../local/`](../local/) — 진입 방식 · 이관 패키지 · 검증 기준은 두 형태가 같고,
LexAI(`legal-rag-chatbot` `deploy/compose/`)와도 같은 방식이다.

## 새 환경에 올릴 때 — 한 줄

사람이 하는 일은 **VM 생성과 SSH 접속까지**다.

```bash
curl -fsSL https://raw.githubusercontent.com/ghd329/WidgetRAG/feat/20260922-change-sqlite/scripts/compose/deploy.sh | bash
```

이관 패키지가 오브젝트 스토리지에 있으면 위치를 알려주면 색인 · DB · 업로드 파일까지 복원한다.
Shell 설치형에서 뜬 패키지도 그대로 된다 (형식이 같다 — [`../package.sh`](../package.sh)).

```bash
curl -fsSL <위 주소> | SNAPSHOT_URI=s3://버킷/widgetrag/20260924-1030 bash
```

다른 CSP 의 레지스트리에서 받으려면 접두사만 바꾼다.

```bash
curl -fsSL <위 주소> | REGISTRY_PREFIX=asia-northeast3-docker.pkg.dev/<프로젝트>/<저장소> IMAGE_TAG=v0.3.0 bash
```

## Shell 설치형과 갈리는 지점

이 스크립트는 **저장소와 독립적으로 동작한다.** 타겟에 git 도 소스도 필요 없다 — 이미지가 곧 산출물이다.

| | Shell 설치형 (`bootstrap.sh`) | Docker Compose (`deploy.sh`) |
| --- | --- | --- |
| 타겟에 놓이는 것 | 저장소 전체 (clone) | 배포 파일 4개 + 이미지 |
| 빌드 | 타겟에서 Maven · pip | 없음 (pull 전용 — `build: !reset null`) |
| GPU | 호스트 드라이버만 | 드라이버 + **nvidia-container-toolkit** |
| 서비스 관리 | `systemctl` (`widgetrag-*`) | `docker compose` |
| 데이터 위치 | 호스트 `~/widgetrag-data` | 네임드 볼륨 `upload-data` · `opensearch-data` |

받는 파일은 이렇다 (배포 디렉토리 `~/widgetrag-deploy`):

```
docker-compose.yml            서비스 정의 (build: 포함 — 아래 오버레이가 지움)
docker-compose.images.yml     build: 제거 + image: 지정 (REGISTRY_PREFIX · IMAGE_TAG)
package.sh                    이관 패키지 수신 · 복원 · 생성 (두 형태 공용)
verify.sh                     합격 기준 검증 (두 형태 공용)
.env                          생성됨 — 관리자 비밀번호 무작위 발급 (600)
snapshots/                    OpenSearch path.repo(/mnt/snapshots) — 색인 스냅샷을 주고받는 곳
```

## 스크립트가 하는 일

1. root 로 실행되면 uid 1000 사용자로, 파이프로 들어오면 디스크 사본으로 다시 실행
2. 기본 도구 (curl · sqlite3 · pigz …)
3. NVIDIA 드라이버 — 없으면 설치 후 **스스로 재부팅하고, 부팅이 끝나면 같은 지점부터 자동으로 이어서 진행**
   (`sudo journalctl -u widgetrag-compose-resume -f`)
4. Docker 엔진 + Compose v2.24+ + nvidia-container-toolkit → **매번 컨테이너를 하나 띄워 GPU 통과 확인**
5. 배포 파일 수신 · `.env` 생성
6. 이미지 pull → `SNAPSHOT_URI` 가 있으면 패키지 수신(체크섬 확인)
7. **앱보다 먼저 복원** — 컨테이너 · 볼륨만 만들고(`up --no-start`) DB · 업로드 파일을 볼륨에 넣은 뒤,
   opensearch 만 올려 색인을 복원하고 나서 전체를 올린다 (backend 는 기동할 때 빈 DB · 빈 색인을 만든다)
8. 서비스 준비 대기 (backend healthy · 모델 적재 · AI 서버 · 프론트)
9. 합격 기준 검증 — Shell 설치형과 같은 판정 · 같은 결과표(`~/widgetrag-run/results.csv`)

여러 번 실행해도 안전하다. DB · 색인이 이미 있으면 복원을 건너뛴다 (덮어쓰려면 `FORCE_RESTORE=1`).

### GPU 통과 확인을 매번 하는 이유

toolkit 이 없거나 설정이 틀리면 **에러 없이 CPU 로 폴백한다.** 컨테이너는 전부 정상으로 보이는데
응답만 느려지고, AI 서버 호출 타임아웃(180초)에 걸려 채팅이 실패하기 시작한다. 증상이 늦게,
엉뚱한 곳에서 드러나므로 기동 전에 실제로 확인한다.

## 환경변수

전부 선택 사항이다.

| 이름 | 기본값 | 설명 |
| --- | --- | --- |
| `BRANCH` | `feat/20260922-change-sqlite` | 배포 파일을 받을 브랜치 |
| `REPO_RAW` | `https://raw.githubusercontent.com/ghd329/WidgetRAG` | 포크 · 사내 미러 |
| `WORK_DIR` | `~/widgetrag-deploy` | 배포 디렉토리 (사본을 직접 실행하면 그 디렉토리) |
| `REGISTRY_PREFIX` | `yjp8842` | Docker Hub 계정 또는 레지스트리 주소 (ECR · GAR · NCR) |
| `IMAGE_TAG` | `v0.3.0` | **고정 태그를 쓴다** — `latest` 는 어느 이미지가 떴는지 추적이 안 된다 |
| `SNAPSHOT_URI` | — | 이관 패키지 위치 (`s3://` · `gs://` · `https://` · 로컬 경로) |
| `S3_ENDPOINT_URL` | — | S3 호환 스토리지 주소 (NCP 등) |
| `FORCE_RESTORE=1` | — | DB · 색인이 이미 있어도 패키지로 덮어씀 |
| `LLM_TEMPERATURE` · `LLM_SEED` | `0.7` · — | 동등성 비교용 결정적 설정 — 지정하면 `.env` 에 반영 |
| `NO_DRIVER=1` · `NO_START=1` · `SKIP_VERIFY=1` | — | 드라이버 생략 · 준비만 · 검증 생략 |
| `TARGET_USER` | uid 1000 | root 로 실행될 때 배포할 사용자 |

## 이관 도구 연동

이 한 줄이 CB-Tumblebug 의 `postCommands` 에 그대로 실리는 페이로드다. root 로 실행돼도
uid 1000 사용자로 스스로 전환하므로 배포물이 `/root` 아래에 갇히지 않는다.

## 일상 운영

```bash
cd ~/widgetrag-deploy
sudo docker compose ps                  # 상태
sudo docker compose logs -f backend     # 로그
sudo docker compose down                # 종료 (볼륨은 유지)
bash deploy.sh                          # 재기동 · 갱신
bash package.sh backup                  # 이관 패키지 생성 (UPLOAD_URI=s3://… 면 업로드까지)
```

**`docker compose down -v` 는 쓰지 않는다** — DB · 색인 볼륨까지 지워진다.

## 주의

- 같은 VM 에서 Shell 설치형과 **동시에 띄울 수 없다** — 포트(80 · 9200)와 GPU VRAM 이 겹친다. 형태별로 VM 을 따로 둔다.
- 보안 그룹은 22 만 열고 SSH 터널로 접속한다: `ssh -N -L 8081:localhost:80 ubuntu@<IP>` → `http://localhost:8081`
- 외부 포트는 frontend 의 80 뿐이다. caddy 는 이관 검증에 맞춰 뺐다(frontend 의 nginx 가 `/api` 를 프록시).
  HTTPS 가 필요하면 CSP 로드밸런서에서 종료한다.
- 관리자 비밀번호는 패키지에 넣지 않는다 — 이관된 DB 의 계정은 소스의 비밀번호로 로그인한다.

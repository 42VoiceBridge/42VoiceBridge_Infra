# AI 컨테이너 배포 가이드

[ADR 0005](adr/0005-ai-serving-topology.md)에 따라 AI 추론 서버를 BE와 **같은 EC2의 별도 컨테이너**로 실행한다. 2026-10-03 기준으로 코드와 오프라인 테스트까지 끝났고 **AWS에는 적용하지 않았다.** 실제 배포와 메모리 실측은 `terraform apply` 승인 이후에 진행한다. 프론트엔드 CI/CD는 이 문서의 범위가 아니다.

## 구성

```
EC2 m5.large (루트 EBS 40 GiB gp3)
├─ /data  ← 별도 EBS gp3 20 GiB (암호화, prevent_destroy), UUID로 fstab 등록
│   └─ ai/
│       ├─ hf/                 Hugging Face 모델 캐시   → 컨테이너 /data/hf
│       ├─ adapters/           개인화 LoRA 어댑터       → 컨테이너 /data/adapters
│       ├─ enroll/             등록 음성 수신 데이터    → 컨테이너 /data/enroll
│       ├─ jobs/               학습 작업 상태           → 컨테이너 /data/jobs
│       └─ script_pool.json    프롬프트 풀(수동 업로드) → 컨테이너 /data/script_pool.json
└─ Docker 네트워크 "voicebridge"
    ├─ voicebridge-be   호스트 80 → 8080 게시
    └─ voicebridge-ai   포트 게시 없음, http://voicebridge-ai:8000 (네트워크 내부에서만)
```

| 항목 | 값 | 비고 |
|---|---|---|
| 이미지 | `ghcr.io/42voicebridge/42voicebridge_ai:sha-<40자 SHA>` | 스크립트가 이 이름 형식만 허용 |
| 헬스체크 | 호스트에서 컨테이너 IP로 `GET /v1/health` → 200 | 5초 × 120회 = 최대 600초. 근거는 ADR 0005 |
| 재시작 정책 | `unless-stopped` | EC2 재부팅 후 자동 기동. AI 모델 로딩이 끝나기 전에는 BE의 AI 호출이 실패할 수 있다 |
| 로그 | json-file 10 MB × 3 | 디스크가 차지 않도록 순환 |
| 컨테이너 환경변수 | `HF_HOME=/data/hf`, `ALLOW_CPU_TRAIN=1` | 나머지(`HOST=0.0.0.0`, `PORT=8000`, `ASR_ADAPTERS`, `PROMPT_POOL`, `ENROLL_DIR`, `JOB_DIR`)는 AI 이미지의 Dockerfile이 지정한다. `ALLOW_CPU_TRAIN`이 없으면 CPU에서 학습기가 실행을 거부한다 |
| 실행 사용자 | uid 10001(비루트) | 앱이 `/data` 아래에 직접 디렉터리를 만들므로 배포 스크립트가 `/data/ai`와 하위 디렉터리를 이 사용자 소유로 맞춘다 |
| IAM | **변경 없음** | 모델은 HF에서 받고 S3는 쓰지 않는다. 프롬프트 풀 전달만 기존 앱 버킷 권한(`GetObject`)을 쓴다 |

`/data`가 마운트돼 있지 않으면 AI 배포는 이미지 pull 전에 거부된다. 루트 디스크에 조용히 쓰면 EC2 교체 때 모델 캐시와 어댑터가 사라지기 때문이다.

## 배포 체크리스트

### A. Terraform 적용 전 (운영자)

- [ ] `terraform plan` 결과에서 `aws_ebs_volume.data`(20 GiB gp3, 암호화), `aws_volume_attachment.data`, 루트 볼륨 40 GiB가 의도대로인지 확인한다.
- [ ] **이미 EC2가 생성돼 있다면** `user_data`는 최초 부팅 때만 실행되므로 데이터 볼륨이 자동으로 포맷·마운트되지 않는다. 인스턴스를 교체(`terraform apply -replace=aws_instance.app`)하거나 SSM으로 직접 마운트해야 한다. EC2가 아직 없다면 해당 없음.
- [ ] 적용 후 Infra Actions의 **SSM deploy (manual)** `mode=check`가 `Data volume mounted at /data`를 출력하는지 확인한다.

### B. AI 배포 전 (운영자, 수동)

- [ ] **`script_pool.json`을 AI팀 내부 폴더(`sw_challenge/`)에서 받아 올린다.** 이 파일은 코드·이미지로 오지 않는다. 없으면 `/v1/enroll/next-prompts`가 **503**을 반환한다(AI 서버 자체는 정상 기동). 절차는 아래 "프롬프트 풀 업로드".
- [ ] **GHCR 인증 확인(확인 필요, 운영자 직접):** BE와 같은 앱 시크릿의 `GHCR_USERNAME`/`GHCR_READ_TOKEN`을 AI 이미지 pull에도 그대로 쓴다(스크립트가 `ghcr.io` 단위로 로그인). 아래 항목은 시크릿 값을 열어보지 않고 GitHub 설정 화면에서 확인한다.
  - 토큰이 **classic PAT**인가? fine-grained PAT는 GHCR 패키지를 지원하지 않는다.
  - 토큰에 `read:packages` 범위가 있고, 소유 조직이 SSO를 요구하면 토큰에 SSO 승인이 되어 있는가?
  - `42voicebridge_ai` 패키지가 비공개라면 이 토큰의 사용자가 패키지 읽기 권한(조직 멤버십 또는 패키지 접근 설정)을 갖는가? 공개 패키지면 두 필드는 필요 없다.
  - **확인하지 않고 배포하면 첫 배포에서 `docker pull` 인증 실패로 드러날 수 있다.** 이 경우 AI 배포는 BE를 건드리지 않고 실패한다.
- [x] **AI 이미지 환경변수 확인:** AI 레포 Dockerfile 기준으로 필요한 값은 이미지가 지정하고, 배포 스크립트는 `HF_HOME`과 `ALLOW_CPU_TRAIN=1`만 추가한다(AI팀 확인 2026-10-03).
- [ ] AI 저장소 `main`의 `sha-<40자>` 이미지가 GHCR에 게시됐는지 확인한다.

### C. 배포 순서

1. **AI 배포:** Infra Actions → **SSM deploy (manual)** → `mode=deploy`, `ai_sha=<AI main 40자 SHA>`. 로그에 `Deployed ...; /v1/health returned 200.`이 나와야 한다. 첫 기동은 이미지 pull과 모델 다운로드 때문에 수 분 걸린다(워크플로 제한 60분, AI SSM 명령 제한 30분).
2. **Secrets Manager 갱신(운영자, AWS 콘솔):** `voicebridge/dev/app`의 `AI_SERVER_BASE_URL` 값을 `http://voicebridge-ai:8000`으로 설정한다. 값이 아니라 필드 하나만 추가·수정하며 다른 필드는 건드리지 않는다.
3. **BE 재배포:** `mode=deploy`, `be_sha=<BE main 40자 SHA>`. **BE는 컨테이너 시작 시점에만 시크릿을 읽으므로** 2번 이후에 BE를 다시 배포해야 새 주소가 반영된다. `ai_sha`와 `be_sha`를 함께 입력하면 AI → BE 순서로 한 번에 처리하지만, 2번 갱신이 먼저 끝나 있어야 한다.
4. **확인:** BE에서 AI를 호출하는 기능을 스모크 테스트한다. 앞서 `script_pool.json`을 올렸다면 `/v1/enroll/next-prompts`가 200이어야 한다.

### D. 배포 후

- [ ] 아래 "메모리 실측"을 수행하고 결과를 `deploy-step.md`에 기록한다.
- [ ] EC2를 재부팅해 `/data`가 자동 마운트되고 두 컨테이너가 다시 올라오는지 확인한다.

## 프롬프트 풀 업로드

`script_pool.json`은 AI팀 내부 파일이다. 앱 S3 버킷(퍼블릭 액세스 차단)의 `ai/script_pool.json`에 올리면, AI 배포 시 스크립트가 **EC2의 `/data/ai/script_pool.json`이 없을 때만** 내려받는다. 기존 EC2 역할의 `GetObject` 권한을 그대로 쓰므로 새 IAM이 필요 없다.

```bash
# 운영자 PC 또는 CloudShell, 관리자 자격 증명으로 실행
bucket=$(terraform -chdir=infra/environments/dev/2_storage output -raw s3_bucket_name)
aws s3 cp ./script_pool.json "s3://$bucket/ai/script_pool.json" --region ap-northeast-2
```

- 내려받은 파일이 올바른 JSON이 아니면 AI 배포는 실패하고 손상된 파일은 설치하지 않는다.
- 이미 `/data/ai/script_pool.json`이 있으면 덮어쓰지 않는다(AI가 런타임에 파일을 바꿀 가능성을 고려한 보수적 동작). **갱신하려면** S3에 새 파일을 올린 뒤 EC2의 기존 파일을 지우고(SSM Session Manager 또는 SSH) AI를 다시 배포한다.
- 파일을 올리지 않고 배포하면 배포는 성공하지만 로그에 `WARNING: ... /v1/enroll/next-prompts will return 503 ...`가 나온다.

## 데이터 볼륨 삭제와 비용 정리

`aws_ebs_volume.data`에는 `prevent_destroy`가 걸려 있다. 따라서 **`3_application`에서 단순 `terraform destroy`를 실행하면 오류로 중단된다**(실수로 어댑터가 삭제되는 것을 막기 위한 의도된 동작). 두 경로 중 하나를 선택한다.

| 목적 | 방법 |
|---|---|
| 데이터는 보존하고 EC2 비용만 중지 | `terraform destroy -target=aws_volume_attachment.data -target=aws_eip.app -target=aws_instance.app`. 볼륨은 남고 월 약 $2 안팎(20 GiB gp3, 서울 단가 기준 추정치)이 계속 든다. `1_base`를 다시 만들어도 퍼블릭 서브넷은 항상 첫 번째 AZ(`names[0]`)라 같은 AZ에 다시 붙는다. 이후 `1_base`·`2_storage`는 기존 역순 절차로 지운다. |
| 데이터까지 완전 삭제 | 필요하면 먼저 스냅샷을 만든다(`aws ec2 create-snapshot --volume-id <id>`, `terraform output data_volume_id`). 그 뒤 `ec2.tf`에서 `prevent_destroy`를 제거하는 변경을 **별도 커밋으로 리뷰**한 뒤 `terraform destroy`를 실행한다. 임시로 로컬에서만 지우는 방식은 쓰지 않는다. |

## 메모리 실측 (apply 승인 이후)

m5.large(2 vCPU, 8 GiB)에서 BE와 AI를 함께 띄운 실측은 아직 없다. 두 컨테이너를 모두 배포한 뒤 SSM Run Command 또는 SSH로 다음을 기록한다.

```bash
free -m                                   # available이 핵심 지표
docker stats --no-stream                  # 컨테이너별 CPU·메모리
docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'   # BE·AI 이미지 크기
df -h / /data                             # 루트 40 GiB, 데이터 20 GiB 여유
docker inspect -f '{{.State.StartedAt}}' voicebridge-ai          # 기동 시각(배포 로그의 healthy 시각과 비교)
```

- 측정 시나리오: (1) 유휴 상태, (2) AI에 추론 요청을 보내는 동안 BE도 요청 처리, (3) 첫 기동(모델 다운로드 포함)의 소요 시간. 추론과 학습은 구분해서 기록한다.
- 판단: `available` 메모리가 부하 시 안정적으로 남지 않으면 먼저 인스턴스 크기 상향(예: `m5.xlarge`, 변수 `instance_type`)을 검토하고, 그래도 부족하면 ADR 0005의 재검토 조건에 따라 AI 전용 EC2를 검토한다. 메모리 상한(`--memory`)은 실측값을 근거로 정한다.

## 알려진 한계

- BE는 AI 컨테이너의 기동 완료를 기다리지 않는다. EC2 재부팅 직후에는 AI 모델 로딩이 끝날 때까지 AI 의존 기능이 실패할 수 있다.
- `/data`가 `nofail`로 등록돼 있어 볼륨이 분리된 채 부팅하면 마운트되지 않은 상태로 올라온다. 이 경우 다음 AI 배포가 거부되지만, 이미 실행 중인 컨테이너는 루트 디스크에 쓸 수 있다. `mode=check`로 마운트 여부를 확인한다.
- 데이터 볼륨 스냅샷 자동화는 없다.
- 컨테이너 메모리·CPU 상한은 실측 전이라 설정하지 않았다.

## 오프라인 검증

AWS 자격 증명 없이 다음을 실행할 수 있다. [infra-tests 워크플로](../.github/workflows/infra-tests.yml)가 PR마다 같은 검사를 수행한다.

```bash
shellcheck -x scripts/ssm/*.sh scripts/ssm/test/*.sh infra/environments/dev/3_application/tests/*.sh
bash scripts/ssm/test/deploy-ec2.test.sh                                   # EC2 배포 스크립트(스텁 docker/aws)
bash scripts/ssm/test/run.test.sh                                          # Actions 쪽 run.sh 흐름(스텁 terraform/aws)
bash scripts/ssm/test/deploy-ai-workflow.test.sh                           # deploy-ai 이벤트 payload 검증
bash infra/environments/dev/3_application/tests/user_data_mount.test.sh   # 볼륨 포맷·마운트 분기
cd infra/environments/dev/3_application && terraform init -backend=false && terraform test
```

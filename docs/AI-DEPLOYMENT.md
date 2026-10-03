# AI 인스턴스 배포 가이드

[ADR 0006](adr/0006-three-instance-topology.md)에 따라 AI 추론 서버는 **전용 EC2**에서 실행한다(예전의 같은 EC2 구성은 [ADR 0005](adr/0005-ai-serving-topology.md)가 대체됨). 2026-10-03 기준으로 코드와 오프라인 테스트까지 끝났고 **AWS에는 적용하지 않았다.** AI 서버의 사실(이미지·포트·메모리 실측)은 AI 레포의 `docs/INFRA_AI_배포_정보_2026-10-03.md`와 Dockerfile을 읽어 확인했다.

## 구성

```
AI 인스턴스 (EC2, 초기 시험 사양 m5.xlarge, root gp3 40 GiB, SSH 없음·SSM만)
├─ 사설 IP 10.0.1.20 (고정)   ← AI_SERVER_BASE_URL=http://10.0.1.20:8000 (BE가 호출)
├─ ai-sg: 8000은 be-sg에서만 허용 (AI는 인증이 없어 이 규칙이 유일한 접근 통제)
├─ /data  ← 별도 EBS gp3 20 GiB (암호화, prevent_destroy, DLM 일일 스냅샷), UUID로 fstab 등록
│   └─ ai/
│       ├─ hf/                 Hugging Face 모델 캐시    → 컨테이너 /data/hf
│       ├─ adapters/           개인화 LoRA 어댑터        → 컨테이너 /data/adapters
│       ├─ enroll/             등록 음성 수신 데이터     → 컨테이너 /data/enroll
│       ├─ jobs/               학습 작업 상태            → 컨테이너 /data/jobs
│       └─ script_pool.json    프롬프트 풀(수동 업로드)  → 컨테이너 /data/script_pool.json
└─ 컨테이너 voicebridge-ai  (호스트 8000 → 컨테이너 8000, Docker 네트워크 없음)
```

| 항목 | 값 | 비고 |
|---|---|---|
| 이미지 | `<AI_IMAGE_REPOSITORY>:sha-<40자 SHA>` | AI CI 기준 `ghcr.io/42voicebridge/42voicebridge_ai`. 크기 1.61GB(CPU 전용 PyTorch). 스크립트는 `ghcr.io/42voicebridge/<패키지>:sha-<40자>` 형식만 실행 |
| 헬스체크 | 호스트에서 `GET http://127.0.0.1:8000/v1/health` → 200 | 5초 × 120회 = 최대 600초. **서버가 모델 적재를 끝낸 뒤에 포트를 열기 때문에 200이면 준비 완료**이고, 그 전에는 연결이 거부된다. 첫 기동에는 모델(약 1GB) 다운로드와 CPU 적재 시간이 든다. Docker `HEALTHCHECK`는 이미지에 의도적으로 없다(적재 중 재시작 루프 방지) |
| 재시작 | 기동 중 `RestartCount > 0`이면 지연이 아니라 실패로 보고 이전 컨테이너 복원 | |
| 재시작 정책 | `unless-stopped` | 재부팅 후 자동 기동. 모델 적재가 끝나기 전에는 BE의 AI 호출이 실패할 수 있다 |
| 로그 | json-file 10 MB × 3 | |
| 환경변수 | 배포 스크립트: `HF_HOME=/data/hf`, `ALLOW_CPU_TRAIN=1`. 이미지(Dockerfile): `HOST=0.0.0.0`, `PORT=8000`, `ASR_ADAPTERS`, `PROMPT_POOL`, `ENROLL_DIR`, `JOB_DIR` | `ALLOW_CPU_TRAIN`이 없으면 CPU에서 학습기가 실행을 거부한다 |
| 실행 사용자 | uid 10001(비루트) | 앱이 `/data` 아래에 직접 디렉터리를 만들므로 배포 스크립트가 `/data/ai`와 하위 디렉터리를 이 사용자 소유로 맞춘다 |
| IAM | AI 역할: SSM, `deploy/scripts/*` 읽기, GHCR 시크릿 읽기, **`ai/*` 읽기** | 녹음 데이터와 BE 시크릿은 읽지 못한다. 모델은 HF에서 받고 S3는 쓰지 않는다 |

`/data`가 마운트돼 있지 않으면 AI 배포는 이미지 pull 전에 거부된다. 루트 디스크에 조용히 쓰면 인스턴스 교체 때 모델 캐시와 어댑터가 사라지기 때문이다.

### AI 팀 실측 (사양 확정의 근거, 한계 포함)

| 항목 | 값 | 한계 |
|---|---|---|
| 모델 적재 후 대기 | 517 MiB | 컨테이너 4GB 제한, **arm64**에서 측정(EC2는 amd64) |
| 전사 3건 후 | 1.67 GiB | **3건이라 상한이 아니다.** 오래 돌렸을 때는 확인되지 않았다 |
| 첫 요청 / 이후 | 3.9초 / 0.65초 | |
| CPU 학습 | 17.6분(GPU 18초), 어댑터가 바이트 단위로 동일 | **H100 서버의 CPU에서 측정**이라 2~4 vCPU 인스턴스에서는 더 걸린다. 학습 중 메모리는 측정된 적이 없다. 학습 타임아웃 기본값 5400초 |

그래서 AI 인스턴스 사양은 **초기 시험 사양**이다. 추론만 보면 메모리는 작지만 CPU 학습의 속도와 메모리는 확인되지 않았다. 확정 절차는 [사양 확정 절차](OPERATIONS-SIZING.md).

## 배포 체크리스트

### A. Terraform 적용 전·후 (운영자)

- [ ] 레이어를 순서대로 plan → 검토 → apply 한다([CI/CD 흐름](CICD-FLOW.md#초기-인프라-프로비저닝-레이어별로-순서대로)). `3_application` plan에서 AI 인스턴스에만 데이터 볼륨·attachment·DLM 정책이 붙는지 확인한다.
- [ ] **이미 EC2가 있다면** `user_data`는 최초 부팅에만 실행되어 데이터 볼륨이 자동 마운트되지 않는다. plan에서 인스턴스 교체가 보이면 의도한 것인지 확인하고 `allow_destroy`로 적용한다. 없다면 해당 없음.
- [ ] apply 직후 자동으로 `check`가 실행되어 `Data volume mounted at /data`가 나오는지 확인한다(`ssm-deploy`의 `check`로 수동 실행도 가능).

### B. AI 배포 전 (운영자, 수동)

- [ ] **`script_pool.json`을 AI팀 내부 폴더(`sw_challenge/`)에서 받아 올린다.** 코드·이미지로 오지 않는다(AI 이미지가 이런 파일을 담지 않도록 CI가 검사한다). 없으면 `/v1/enroll/next-prompts`가 **503**을 반환한다(AI 서버 자체는 정상 기동). 절차는 아래 "프롬프트 풀 업로드".
- [ ] **GHCR 인증:** AI 패키지가 비공개로 보인다(AI팀이 인증 없는 API가 `Requires authentication`을 반환함을 확인; 공개 전환은 팀 결정). 전용 시크릿 `voicebridge/dev/ghcr`에 `GHCR_USERNAME`, `GHCR_READ_TOKEN`을 만든다. 토큰은 **classic PAT**(fine-grained는 GHCR을 지원하지 않는다)이고 `read:packages` 범위가 있어야 하며 조직이 SSO를 요구하면 토큰에 SSO 승인이 되어 있어야 한다. 세 패키지(BE·AI·FE)를 모두 읽을 수 있어야 한다. **AI·FE는 이 시크릿이 반드시 있어야 배포된다**(BE만 전환 기간 폴백). 확인하지 않고 배포하면 첫 배포에서 pull 인증 실패로 드러난다.
- [ ] AI 레포 `main`의 `sha-<40자>` 이미지가 GHCR에 게시됐는지 확인한다. 이벤트 배포가 아니라 수동이면 `ssm-deploy`의 `ai_sha`로 실행한다.

### C. 배포 순서

1. **AI 배포:** AI CI가 `deploy-ai`를 보내거나, 수동으로 `ssm-deploy`(`mode=deploy`, `ai_sha`). 로그에 `Deployed ...; /v1/health returned 200.`이 나와야 한다. 첫 기동은 이미지 pull과 모델 다운로드 때문에 수 분 걸린다(AI SSM 명령 제한 30분).
2. **앱 시크릿 갱신(운영자, AWS 콘솔):** `voicebridge/dev/app`의 `AI_SERVER_BASE_URL` 필드를 `terraform output ai_base_url` 값(`http://10.0.1.20:8000`)으로 설정한다. 다른 필드는 건드리지 않는다.
3. **BE 재배포:** BE는 컨테이너 시작 시점에만 시크릿을 읽으므로 2번 이후에 BE를 다시 배포해야 새 주소가 반영된다.
4. **연결 확인:** BE 인스턴스에서 AI 헬스를 호출한다(아래 확인 명령). 다른 보안그룹에서는 막히는지도 확인한다.

### D. 배포 후

- [ ] [사양 확정 절차](OPERATIONS-SIZING.md)대로 `measure`로 지표를 수집하고 결과를 `deploy-step.md`에 기록한다. 학습 요청 중 메모리·시간도 측정한다.
- [ ] 인스턴스를 재부팅해 `/data`가 자동 마운트되고 컨테이너가 다시 올라오는지 확인한다.

### 확인 명령

```bash
# AI 인스턴스에서(SSM): 헬스와 마운트
curl -s http://127.0.0.1:8000/v1/health | head -c 300
mountpoint /data && df -h /data
docker logs --tail 50 voicebridge-ai

# BE 인스턴스에서(SSM): BE → AI 연결 (200이어야 한다)
curl -s -o /dev/null -w '%{http_code}\n' http://10.0.1.20:8000/v1/health
```

## 프롬프트 풀 업로드

`script_pool.json`은 AI팀 내부 파일이다. 앱 S3 버킷(퍼블릭 액세스 차단)의 `ai/script_pool.json`에 올리면, AI 배포 시 스크립트가 **AI 인스턴스의 `/data/ai/script_pool.json`이 없을 때만** 내려받는다. AI 인스턴스 역할은 `ai/*` 읽기만 갖는다.

```bash
# 운영자 PC 또는 CloudShell, 관리자 자격 증명으로 실행
bucket=$(terraform -chdir=infra/environments/dev/2_storage output -raw s3_bucket_name)
aws s3 cp ./script_pool.json "s3://$bucket/ai/script_pool.json" --region ap-northeast-2
```

- 내려받은 파일이 올바른 JSON이 아니면 AI 배포는 실패하고 손상된 파일은 설치하지 않는다.
- 이미 있는 파일은 덮어쓰지 않는다(AI가 런타임에 파일을 바꿀 가능성을 고려한 보수적 동작). **갱신하려면** S3에 새 파일을 올린 뒤 AI 인스턴스의 기존 파일을 지우고(SSM Session Manager) AI를 다시 배포한다.
- 파일 없이 배포하면 배포는 성공하지만 로그에 `WARNING: ... /v1/enroll/next-prompts will return 503 ...`가 나온다.
- 이 데이터가 AI-Hub 파생 데이터라 재배포 조건이 불확실하다고 AI팀이 밝혔다. 버킷 접근을 최소로 유지하고 이미지·로그·워크플로 출력에 내용을 남기지 않는다.

## 데이터 보호

상태 데이터(어댑터, 등록 음성, 학습 작업, 모델 캐시, 프롬프트 풀)는 인스턴스가 교체돼도 유지되어야 한다. `prevent_destroy`, DLM 일일 스냅샷, 삭제 전 최종 스냅샷, 복원 절차는 [데이터 보호 가이드](DATA-PROTECTION.md)에 있다.

## 알려진 한계

- BE는 AI의 기동 완료를 기다리지 않는다. 재부팅 직후에는 모델 적재가 끝날 때까지 AI 의존 기능이 실패할 수 있다.
- `/data`가 `nofail`로 등록돼 있어 볼륨이 분리된 채 부팅하면 마운트되지 않은 상태로 올라온다. 이 경우 다음 AI 배포는 거부되지만 이미 실행 중인 컨테이너는 루트 디스크에 쓸 수 있다. `check`로 마운트 여부를 확인한다.
- 컨테이너 메모리·CPU 상한은 실측 전이라 설정하지 않았다.
- CPU 학습 중 같은 인스턴스의 추론 응답 시간은 측정되지 않았다. 학습이 추론에 영향을 주면 학습 전용 인스턴스 분리를 검토한다.

## 오프라인 검증

AWS 자격 증명 없이 실행할 수 있다. [infra-tests 워크플로](../.github/workflows/infra-tests.yml)가 PR마다 같은 검사를 수행한다.

```bash
shellcheck -x scripts/ssm/*.sh scripts/ssm/test/*.sh scripts/ci/*.sh scripts/ci/test/*.sh infra/environments/dev/3_application/tests/*.sh
bash scripts/ssm/test/deploy-ec2.test.sh                                   # EC2 배포 스크립트(스텁 docker/aws)
bash scripts/ssm/test/run.test.sh                                          # run.sh 흐름(스텁 terraform/aws)
bash scripts/ci/test/validate-and-verify.test.sh                           # 이벤트 검증·출처 검증
bash scripts/ci/test/infra-lock.test.sh                                    # apply/배포 락
bash scripts/ci/test/tf-layer.test.sh                                      # 레이어별 plan/apply
bash scripts/ci/test/workflows.test.sh                                     # 워크플로 구조·안전 규칙
bash infra/environments/dev/3_application/tests/user_data_mount.test.sh   # 볼륨 포맷·마운트 분기
for l in 1_base 2_storage 3_application; do (cd infra/environments/dev/$l && terraform init -backend=false && terraform validate && { [ -d tests ] && terraform test; }); done
```

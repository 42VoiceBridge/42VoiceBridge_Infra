# 배포 진행 상황

최종 갱신: 2026-10-03 (Asia/Seoul)

이 문서는 배포 작업의 현재 상태를 추적한다. `[x]`는 사용자 확인 또는 실행 결과가 있는 항목, `[ ]`는 진행 중·미확인·미완료 항목이다. 상태를 갱신할 때는 완료 근거와 남은 작업을 함께 적고, 비밀값은 기록하지 않는다. **"코드 구현·오프라인 테스트 완료"와 "AWS에서 확인됨"을 구분한다.**

## 현재 상태

### 확인된 것

- [x] Terraform state용 S3 버킷 `42voicebridge-tfstate` 생성. 사용자 확인: 서울 리전 `ap-northeast-2`, 버전 관리 활성화, 퍼블릭 액세스 차단.
- [x] 세 Terraform 레이어를 서로 다른 S3 state 경로에 연결하고 S3 네이티브 잠금(`use_lockfile`) 설정. DynamoDB는 쓰지 않는다. [ADR 0001](docs/adr/0001-terraform-state-s3.md)
- [x] `github-deploy-user`의 AWS 액세스 키를 Infra 저장소 Actions Secrets에 등록(사용자 확인, 값은 확인하지 않음).
- [x] [CD 준비 점검](.github/workflows/cd-preflight.yml)에서 AWS 인증, S3 버킷 리전, 세 레이어 `terraform init`·`validate` 성공. [성공한 실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/36981904406). `apply`는 하지 않았다.
- [x] 운영자 확인: 서울 리전 Secrets Manager에 CLOVA Voice Client ID·Secret 및 JWT 서명용 값을 등록(시크릿 이름·필드명은 미확인), GHCR 자격 증명 `GHCR_USERNAME`/`GHCR_READ_TOKEN`(PAT)을 시크릿에 등록했다고 보고(어느 시크릿인지, PAT 종류는 미확인).
- [x] 각 레포를 읽어 확인(2026-10-03): AI(포트 8000, 40자 SHA 태그, `HOST=0.0.0.0`, uid 10001, 모델 적재 후 포트 오픈, 메모리 실측), FE(nginx 80, API `/api/v1/**`, `VITE_API_URL` 빌드 시점 고정), BE(포트 8080, 헬스 엔드포인트 없음, `validate`).
- [x] PR #10(ADR 0006) 리뷰 후 `main` 머지(커밋 `2889467`). 이벤트 워크플로(`deploy-ai`/`deploy-backend`/`deploy-frontend`)가 이제부터 트리거 가능.
- [x] **1_base → 2_storage → 3_application 순서로 실제 AWS에 plan·apply 완료**(레이어당 1회 이상 재시도, 아래 "적용 중 발견·수정한 문제" 참고).
  - 1_base: VPC, 서브넷 3개, IGW, 라우트테이블+연결, 보안그룹 5개(fe/be/ai/rds/redis). 전부 신규 생성, 삭제 없음.
  - 2_storage: RDS(`db.t3.micro`, 20GB), ElastiCache(`cache.m5.large`), S3 `voicebridge-recordings-*`.
  - 3_application: EC2 3대(FE/BE/AI, 사양은 임시 축소 — 아래 참고), IAM 역할·프로필·정책, FE Elastic IP(`ec2-3-34-9-37.ap-northeast-2.compute.amazonaws.com`), AI 데이터 EBS + DLM 스냅샷 정책.
- [x] `ssm-deploy.yml`(`mode=check`)로 세 인스턴스 SSM 연결·Docker·AI `/data` 마운트 전부 정상 확인. [실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/37131599678)

### 코드·오프라인 테스트 완료 (AWS 적용·실행은 전)

- [x] **[ADR 0006](docs/adr/0006-three-instance-topology.md): FE·BE·AI 개별 인스턴스**(ADR 0005 대체). 고정 사설 IP, 보안그룹 체인(fe→be→ai, be→rds/redis), BE 8080 통일, FE Elastic IP + Caddy HTTPS 엣지, 역할별 최소 권한 IAM(세 역할 모두 `deploy/scripts/*` 읽기와 GHCR 시크릿), AI 데이터 EBS + DLM 스냅샷.
- [x] 배포 스크립트 `be`/`ai`/`fe`, GHCR 전용 시크릿(BE만 폴백), `run.sh`(인스턴스별 대상·순서·기록·`redeploy`·`measure`).
- [x] 이벤트 워크플로 `deploy-ai`/`deploy-backend`/`deploy-frontend`(형식 검증 + 소스 레포 main 포함 확인 + 락), apply·배포 상호 배제 락, 레이어별 `Terraform plan`/`apply`(순서 강제, 저장된 plan만, 삭제·교체 방지, 잠금 유지).
- [x] 오프라인 검증: shellcheck, 스크립트·워크플로 테스트 7종, `terraform fmt`/`validate`/mock `terraform test` 20개. 일부러 깨뜨린 변형으로 실제로 실패를 잡는지 확인. [검증 가이드](docs/INFRA-VERIFICATION.md)
- [x] 문서: [네트워크·엣지](docs/NETWORK-AND-EDGE.md), [CI/CD 흐름](docs/CICD-FLOW.md), [AI 배포](docs/AI-DEPLOYMENT.md), [데이터 보호](docs/DATA-PROTECTION.md), [사양 확정](docs/OPERATIONS-SIZING.md), [후속 작업](docs/FOLLOW-UPS.md).

### 적용 중 발견·수정한 문제 (2026-10-03)

실제 AWS 적용 전까지는 드러나지 않던 문제 4개. 전부 `main`에 커밋·반영했다.

- [x] **RDS·EC2 인스턴스 사이즈가 이 AWS 계정의 Free Tier 제한에 걸림**(`FreeTierRestrictionError`/`InvalidParameterCombination`). 설계값인 `db.r5.large`, BE `m5.large`, AI `m5.xlarge`가 전부 거부됨(FE `t3.small`만 통과). RDS는 `db.t3.micro`(20GB)로, BE·AI는 `t3.small`로 **임시 축소**했다 — 정식 사양은 미확정이며 실측 후 [사양 확정 절차](docs/OPERATIONS-SIZING.md)로 재조정 필요.
- [x] **EC2 AMI 필터 버그**: `al2023-ami-*-x86_64` 필터가 ECS 최적화 변종(`al2023-ami-ecs-hvm-...`)까지 매칭해 `most_recent`로 뽑혀, 세 인스턴스가 전부 의도와 다른 AMI로 떴다(`docker images`에 `ecs-agent` 등이 보여 발견). 필터를 `al2023-ami-2*-x86_64`로 좁혔다.
- [x] **`dnf install -y docker jq curl` 실패**: 최신 AL2023 AMI가 기본으로 `curl-minimal`을 포함하는데 풀 버전 `curl` 설치가 충돌(`--allowerasing` 필요). dnf가 전체 실패해 Docker가 끝내 설치되지 않았다(`/var/log/cloud-init-output.log`로 확인). `--allowerasing` 추가.
- [x] **`user_data` 변경이 인스턴스에 반영되지 않음**: `aws_instance`는 `user_data` 변경을 기본적으로 in-place 업데이트로만 처리하는데, 이미 부팅된 인스턴스는 cloud-init이 user_data를 다시 실행하지 않는다. `user_data_replace_on_change = true`를 추가해 교체를 강제하도록 고쳤다.
- [x] **AI 데이터 볼륨 마운트 실패**: `mkfs -L voicebridge-data`의 레이블이 17자인데 XFS 레이블은 최대 12자라 포맷 자체가 거부됐다(`/var/log/voicebridge-data-volume.log`로 확인). 레이블을 `vb-data`로 줄였다.

### 미확인·미완료

- [ ] **`voicebridge/dev/ghcr` 시크릿 미생성 — 앱 배포가 AI 단계에서 막힘.** GHCR 자격 증명을 `voicebridge/dev/app`에 넣어뒀다는 보고가 있었으나 AI·FE 역할은 그 시크릿을 읽을 IAM 권한이 없다(BE만 가능, 전환기 폴백). `voicebridge/dev/app`을 가리키도록 임시로 바꿔 동작은 확인했지만 AI·FE가 BE의 DB·Redis 자격 증명까지 읽게 되는 부작용이 있어 원복했다. 운영자가 내일 `voicebridge/dev/ghcr`를 별도로 생성하기로 함.
- [ ] GitHub Actions에서의 실제 이벤트 실행(재사용 워크플로, 아티팩트, S3 조건부 쓰기 락)은 여전히 미확인. 이벤트 워크플로는 `main`에 머지됐으니(완료) 각 레포 CI가 실제로 호출하는지만 남음.
- [ ] 배포용 IAM 사용자에 `locks/dev/*`, SSM Parameter Store `/voicebridge/dev/deployed/*` 권한이 있는지.
- [ ] **인스턴스 사양은 AWS 계정의 Free Tier 제한 때문에 임시로 축소된 상태**(RDS `db.t3.micro`, BE·AI `t3.small`, ElastiCache만 원래 `cache.m5.large`로 통과). 원래 설계값(BE `m5.large`, AI `m5.xlarge`, RDS `db.r5.large`)으로 되돌리려면 AWS 계정 플랜 업그레이드가 먼저 필요하다. 메모리·CPU 실측으로 정식 사양 확정 필요. 비용(약 $0.9/시간)은 추정치이며 현재 축소된 사양으로는 더 낮다.
- [ ] SSH와 SSM 중 최종 접속·배포 방식 결정. [ADR 0004](docs/adr/0004-ec2-access-method.md)는 `Pending`(SSH는 BE에만 남김).
- [ ] Let's Encrypt 발급(EIP 공개 DNS 이름), GHCR pull(PAT 권한 범위) 모두 실제 앱 배포 시점에 확인 필요 — 아직 컨테이너가 하나도 안 떠서 미확인.

## 다음 작업 순서

### 1. 적용 전 (운영자) — 완료

- [x] AWS 읽기·쓰기 키를 Infra 저장소 Secrets에 등록.
- [x] Infra 저장소 Variables 설정: `BE_/AI_/FE_IMAGE_REPOSITORY`, `SSH_ALLOWED_CIDR`, `SSH_KEY_NAME`.
- [x] PR #10 리뷰·머지(`2889467`).
- [ ] `voicebridge/dev/ghcr` 시크릿 생성(classic PAT, `read:packages`, 세 패키지, SSO 승인). **아직 남음 — AI·FE는 이게 없으면 배포되지 않는다.**

### 2. 레이어별 프로비저닝 — 완료

- [x] `1_base` plan → 검토 → apply → `2_storage` plan → 검토 → apply → `3_application` plan → 검토 → apply. 과정에서 발견한 문제 4개는 위 "적용 중 발견·수정한 문제" 참고.
- [x] `3_application` apply 후 수동 `check`(SSM, Docker, AI `/data` 마운트) 통과 확인. [실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/37131599678)
- [ ] apply 후 확인(네트워크 양성·음성 테스트, IAM 음성 테스트, HTTPS)은 아직: [검증 가이드](docs/INFRA-VERIFICATION.md#5-apply-후-확인-실제-aws).

### 3. 앱 배포 — 다음 작업

- [ ] **`voicebridge/dev/ghcr` 시크릿 생성 후 `ssm-deploy.yml`(`mode=deploy`)를 AI/BE/FE SHA와 함께 재실행.** BE `2b21d4a`, AI `f08764b`, FE `f1638fa`(2026-10-03 기준 각 레포 `main` 최신 커밋 — 재실행 시점에 다시 확인).
- [ ] AI: `script_pool.json` 업로드, `ai_sha` 배포, `/v1/health` 200 확인. [AI 배포 가이드](docs/AI-DEPLOYMENT.md)
- [ ] 앱 시크릿에 `AI_SERVER_BASE_URL=http://10.0.1.20:8000`(`terraform output ai_base_url`) 등록 후 BE 배포.
- [ ] FE 배포, HTTPS 확인. FE 레포의 같은 출처 API 지원 필요([네트워크·엣지](docs/NETWORK-AND-EDGE.md#fe-레포에-요청할-변경-같은-출처-api)).
- [ ] RDS 초기 스키마/마이그레이션(BE 작업). BE `prod`는 `validate`라 빈 DB에서는 앱이 뜨지 않는다.
- [ ] 이벤트 연동: AI·FE는 구현됨, **BE CI에 `deploy-backend` 전송 추가**. 토큰은 각 소스 레포의 Secret(Variable 금지).

### 4. 측정과 정리

- [ ] [사양 확정 절차](docs/OPERATIONS-SIZING.md)(`measure`)로 시나리오 A~F 측정, 결과를 이 문서에 기록하고 사양 확정.
- [ ] 복원 리허설(스냅샷에서 볼륨 생성 후 마운트): [데이터 보호](docs/DATA-PROTECTION.md#절차-4-스냅샷에서-복원).
- [ ] 테스트 종료 시 [데이터 보호 가이드](docs/DATA-PROTECTION.md)의 절차 2(데이터 보존) 또는 3(완전 삭제)으로 정리, 이후 `2_storage → 1_base`. state 버킷은 마지막까지 유지.
- [ ] 후속 작업([호출 방식, AWS 키, 도메인, 권한 축소 등](docs/FOLLOW-UPS.md)).

## 갱신 기록

| 날짜 | 변경 사항 | 근거 |
|---|---|---|
| 2026-10-03 | 최초 작성. S3 backend와 준비 점검 완료, SSM·앱 시크릿·배포 및 BE 연결은 미완료 또는 미확인으로 정리 | 저장소 코드·문서 및 [준비 점검 실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/36981904406) |
| 2026-10-03 | SSM을 우선 배포 경로로 구현하고 SSH를 유지. EC2 권한, 수동 워크플로, 배포 스크립트를 추가했으며 실제 AWS 적용·검증은 대기 | [SSM 배포 절차](docs/SSM-DEPLOYMENT.md), [ADR 0004](docs/adr/0004-ec2-access-method.md) |
| 2026-10-03 | 운영자 확인에 따라 NCP 인증 정보 두 개와 JWT 서명용 값의 서울 리전 Secrets Manager 등록을 반영. 앱 시크릿 이름·필드명과 AI URL은 미확인 | 사용자 보고, [필수 필드 목록](docs/SSM-DEPLOYMENT.md) |
| 2026-10-03 | AI 모델 학습 완료·배포 전이라는 운영자 보고를 반영하고 AI 서빙 위치를 보류 결정으로 기록 | [ADR 0005](docs/adr/0005-ai-serving-topology.md) |
| 2026-10-03 | AI 저장소 최신 `main`의 HTTP·학습 작업 구현 상태와 GPU 지양·짧은 CPU 테스트·AWS 크레딧 제약을 반영. EC2 중지 후에도 남는 RDS·Redis·스토리지 비용 확인 필요 | AI 저장소 `main` (`588f651`), [ADR 0005](docs/adr/0005-ai-serving-topology.md) |
| 2026-10-03 | AI 제외 초기 BE 배포를 위해 SSM 스크립트에서 `AI_SERVER_BASE_URL`을 선택값으로 변경. 나머지 앱 시크릿 필드 세 개는 계속 필수 | [SSM 배포 스크립트](scripts/ssm/deploy-ec2.sh), [SSM 절차](docs/SSM-DEPLOYMENT.md) |
| 2026-10-03 | AI 제외 BE 선배포 범위와 수동 적용·SSM 검증·자동 연동의 순서를 별도 문서에 기록 | [BE 선배포 문서](docs/BE-ONLY-DEPLOYMENT.md) |
| 2026-10-03 | SSM 구현·배포 문서의 형식과 Terraform 구성을 검증하고 `main`에 커밋·푸시. 실제 AWS 적용은 계속 미완료 | Terraform 세 레이어 `validate`, `fmt -check`, Bash 문법, 워크플로 YAML 검사 |
| 2026-10-03 | AI 서빙 위치를 같은 EC2의 별도 컨테이너로 확정하고 데이터 볼륨·AI 배포 코드·오프라인 테스트를 구현. AWS 적용과 실측은 전 | [ADR 0005](docs/adr/0005-ai-serving-topology.md), [AI 배포 가이드](docs/AI-DEPLOYMENT.md) |
| 2026-10-03 | AI팀 전달 반영: `deploy-ai` 이벤트 수신 워크플로 추가(이미지 경로는 payload를 신뢰하지 않고 Infra 변수와 SHA로 조립), AI 데이터 디렉터리 `enroll`·`jobs` 및 소유권(uid 10001) 보정, `ALLOW_CPU_TRAIN=1` 전달, ADR 0005에 CPU 학습 정정과 메모리 실측(517 MiB 대기, 1.67 GiB 전사 3건 후) 반영. `main` 반영 전에는 이벤트가 워크플로를 실행하지 않음 | [deploy-ai.yml](.github/workflows/deploy-ai.yml), [ADR 0005](docs/adr/0005-ai-serving-topology.md), AI 저장소 `docs/INFRA_AI_배포_정보_2026-10-03.md` |
| 2026-10-03 | 운영자 결정으로 FE·BE·AI를 개별 인스턴스로 분리(ADR 0006, ADR 0005 대체). Terraform(보안그룹 5개, 인스턴스 3대, 고정 사설 IP, FE EIP, 역할별 IAM, AI 데이터 볼륨 + DLM), 배포 스크립트·`run.sh`, 이벤트 워크플로 3종, 락, 레이어별 plan/apply, 문서와 오프라인 테스트를 구현. 리뷰 지적 반영: 세 역할의 `deploy/scripts/*` 읽기 누락, 초기 레이어별 순서, BE 포트 8080 통일, FE→BE 주소 고정, GHCR 시크릿 분리의 동시 전환, apply·배포 충돌, `-lock=false` 철회(잠금은 S3 네이티브이며 DynamoDB 아님). AWS 적용·plan·실측은 전 | [ADR 0006](docs/adr/0006-three-instance-topology.md), [검증 가이드](docs/INFRA-VERIFICATION.md), [후속 작업](docs/FOLLOW-UPS.md) |
| 2026-10-03 | PR #10 머지 후 1_base → 2_storage → 3_application을 실제 AWS에 plan·apply. 과정에서 Free Tier 제한(RDS·BE·AI 인스턴스 사이즈 임시 축소), AMI 필터가 ECS 변종을 잘못 선택, `dnf install docker`가 `curl-minimal`과 충돌, `user_data` 변경이 재부팅으로 반영되지 않음, XFS 레이블 12자 초과로 AI `/data` 마운트 실패 — 4개 문제를 발견해 전부 수정. `check` 모드로 세 인스턴스 SSM·Docker·AI 마운트 정상 확인. 실제 앱 배포(`deploy` 모드)는 `voicebridge/dev/ghcr` 시크릿 미생성으로 AI 단계에서 보류(`voicebridge/dev/app`으로의 임시 전환은 보안 경계상 원복) | 워크플로 실행 기록(`terraform-plan`/`terraform-apply`/`ssm-deploy` 다수), 커밋 `2889467`→`f9eba55` |

# 배포 진행 상황

최종 갱신: 2026-10-03 (Asia/Seoul)

이 문서는 배포 작업의 현재 상태를 추적한다. `[x]`는 사용자 확인 또는 실행 결과가 있는 항목, `[ ]`는 진행 중·미확인·미완료 항목이다. 상태를 갱신할 때는 완료 근거와 남은 작업을 함께 적고, 비밀값은 기록하지 않는다.

## 현재 상태

- [x] Terraform state용 S3 버킷 `42voicebridge-tfstate` 생성. 사용자 확인: 서울 리전 `ap-northeast-2`, 버전 관리 활성화, 퍼블릭 액세스 차단.
- [x] 세 Terraform 레이어를 서로 다른 S3 state 경로에 연결하고 잠금 파일 설정. [ADR 0001](docs/adr/0001-terraform-state-s3.md)
- [x] `github-deploy-user`의 AWS 액세스 키를 Infra 저장소 Actions Secrets에 등록. 사용자 확인이며 키 값은 이 저장소에서 확인하지 않음.
- [x] [CD 준비 점검](.github/workflows/cd-preflight.yml)에서 AWS 인증, S3 버킷 리전, 세 레이어 `terraform init`·`validate` 성공. [성공한 실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/36981904406). 이 실행은 `apply`를 하지 않았다.
- [x] BE CI가 GHCR 이미지를 게시 중이라고 사용자 확인. BE `main`에서 Infra를 호출하는 연결은 아직 확인되지 않음.
- [x] 운영자 확인: 서울 리전 Secrets Manager에 CLOVA Voice Client ID·Client Secret 및 JWT 서명용 값 3개를 등록. 시크릿 이름·필드명·값 자체는 이 저장소에서 확인하지 않음.
- [x] AI를 제외한 초기 BE 배포에서는 SSM 스크립트가 `AI_SERVER_BASE_URL` 없이 동작하도록 변경. AI 의존 기능은 AI 서버 배포 전까지 사용할 수 없다.
- [x] AI를 제외한 BE 선배포 범위·선행 조건·실행 순서를 [별도 문서](docs/BE-ONLY-DEPLOYMENT.md)에 정리.
- [x] [ADR 0005](docs/adr/0005-ai-serving-topology.md)를 Accepted로 확정: AI는 같은 EC2의 별도 컨테이너. 데이터 EBS 볼륨(gp3 20 GiB, `/data`), 루트 40 GiB, Docker 네트워크 `voicebridge`, SSM의 AI 배포 컴포넌트, `/v1/health` 헬스체크를 코드로 구현하고 오프라인 테스트로 검증했다. [AI 배포 가이드](docs/AI-DEPLOYMENT.md)
- [ ] AI 컨테이너의 AWS 적용·실제 배포는 전. 남은 것: `terraform plan`(AWS 자격 증명 필요) 검토·승인 후 `apply`, GHCR 토큰 종류·권한 확인, `script_pool.json` 수동 업로드, 같은 `m5.large`에서 BE+AI 메모리 실측. GPU는 현재 계획에 포함하지 않음.
- [x] EC2 역할의 `AmazonSSMManagedInstanceCore` 연결, 앱 시크릿 읽기 권한, SSM 수동 배포 워크플로와 스크립트를 로컬 코드에 구현. [SSM 배포 절차](docs/SSM-DEPLOYMENT.md). 적용·실제 연결 검증은 아직 전.
- [ ] SSH와 SSM 중 최종 접속·배포 방식 결정. [ADR 0004](docs/adr/0004-ec2-access-method.md)는 `Pending`.
- [ ] Terraform `apply`, EC2 생성, SSM 관리 대상 등록, 앱 배포는 아직 확인되지 않음. SSM 수동 워크플로는 `apply`하지 않으며 배포 코드는 미실증.

## 다음 작업 순서

### 1. 로컬 변경 정리

- [x] SSM 코드·문서를 검증하고 `main`에 커밋·푸시한다. `.idea/`는 배포 변경에 포함하지 않는다.
- [x] SSM을 먼저 검증하고 그동안 SSH 입력·보안그룹은 유지하기로 결정. 첫 `apply`에는 EC2 키 페어와 제한된 `ssh_allowed_cidr`가 계속 필요하다.

### 2. 앱 실행 값 준비

- [x] 운영자 확인: NCP CLOVA Voice 인증 정보 두 개와 JWT 서명용 값을 서울 리전 Secrets Manager에 등록했다. BE 서버용 카카오 API 키 환경변수는 없다.
- [ ] 시크릿 이름이 `voicebridge/dev/app`인지, 키가 `NCP_TTS_API_KEY_ID`, `NCP_TTS_API_KEY`, `JWT_SECRET`인지 확인한다. `AI_SERVER_BASE_URL`은 AI 서버 배포 후 추가한다. 실제 값은 코드, Terraform 변수, GitHub 로그에 넣지 않는다.
- [x] AI 모델 아티팩트 조사: 베이스 모델은 런타임에 Hugging Face에서 받고 어댑터·프롬프트 풀은 로컬 디스크에만 있어 새 IAM이 필요 없다. 프롬프트 풀(`script_pool.json`)은 AI팀 내부 파일이라 배포 전에 수동 업로드가 필요하다.
- [ ] AI 배포 후 `AI_SERVER_BASE_URL`을 `http://voicebridge-ai:8000`으로 등록하고 BE를 다시 배포한다. BE 컨테이너 안의 `127.0.0.1`을 AI 주소로 사용하지 않는다. AI 이미지가 `HF_HOME` 외에 요구하는 환경변수가 있는지 AI팀에 확인한다.
- [ ] CPU 추론과 BE 연결부터 테스트한다. 사용자별 어댑터 학습은 AI 코드에서 GPU가 기본 요구사항이며 CPU 모드는 짧은 테스트용이므로 실제 CPU 학습 시간·메모리를 확인하기 전 배포 완료로 표시하지 않는다.
- [x] EC2 앱 역할에 `voicebridge/dev/app`의 `secretsmanager:GetSecretValue` 권한을 코드로 추가했다. 실제 적용은 아직 전. [환경변수 명세](docs/ENVIRONMENT-VARIABLES.md)
- [ ] GHCR 패키지 공개 여부를 확인한다. 비공개라면 EC2의 이미지 읽기 인증 방법을 준비한다.

### 3. Infra 배포 워크플로 구현

- [ ] Infra Actions에서 Terraform을 `1_base → 2_storage → 3_application` 순서로 `plan`·`apply`하도록 구성한다. 필요한 Terraform 입력값의 저장 위치를 정하고 실행을 직렬화한다. 현재 워크플로는 준비 점검만 한다.
- [x] SSM 수동 워크플로와 EC2 배포 스크립트 구현. `check`와 BE SHA 기준 `deploy` 모드를 제공하고 배포 실패 시 기존 컨테이너 복원을 시도한다. 실제 실행은 아직 전.
- [ ] EC2가 Systems Manager 관리 대상에 등록되는지 `check` 모드로 확인한다. SSM Agent, EC2 Instance Profile, 아웃바운드 연결을 점검한다.
- [ ] BE 커밋의 GHCR 이미지를 `deploy` 모드로 배포하고 앱 기능을 확인한다. 현재 HTTP 응답 확인은 전용 health endpoint 검증보다 약하다.
- [ ] RDS 초기 스키마/마이그레이션을 준비한다. BE `prod` 설정은 기존 스키마 검증을 사용하므로 빈 DB에서는 앱 시작 전에 스키마가 필요하다.

### 4. BE 저장소 연결

- [ ] Infra 저장소에 `repository_dispatch`를 보낼 GitHub 토큰을 준비하고 **BE 저장소 Secrets**에 `INFRA_DISPATCH_TOKEN`으로 등록한다. 발급·등록 여부는 현재 미확인이다.
- [ ] BE `main`의 테스트·GHCR 이미지 게시 성공 후 `deploy-backend` 이벤트를 보내도록 BE CI를 연결한다. `client_payload`에 `ref: refs/heads/main`과 BE 커밋 SHA를 포함한다. [ADR 0002](docs/adr/0002-main-branch-cd.md)

### 5. 통합 검증과 운영 정리

- [ ] 첫 `apply` 전에 예상 비용과 입력값을 확인한다. 인프라 생성 후 세 레이어의 S3 state 객체와 EC2·RDS·Redis·앱용 S3 생성 결과를 확인한다.
- [ ] BE `main` → GHCR → Infra 이벤트 → Terraform → SSM → 앱 상태 확인을 한 번 끝까지 검증한다.
- [ ] SSH/SSM 최종 방식을 결정하고 [ADR 0004](docs/adr/0004-ec2-access-method.md)의 전환 조건을 충족하면 `Accepted`로 갱신한다.
- [ ] 테스트 종료 시 `3_application → 2_storage → 1_base` 순서로 `destroy`한다. state 버킷은 모든 state 확인과 `destroy`가 끝날 때까지 유지한다.
- [ ] 초기 CD 동작 후 `github-deploy-user`의 광범위한 권한을 축소하고, 추후 OIDC 전환 시 장기 액세스 키를 폐기한다. [ADR 0003](docs/adr/0003-github-deploy-identity.md)

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

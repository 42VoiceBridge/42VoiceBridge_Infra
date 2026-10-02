# CD 준비 상태와 수동 설정

2026-10-02 기준. AWS 콘솔 설정은 운영자가 제공한 내용과 IAM 권한 화면을 기준으로 기록했다. 이 저장소에서 AWS 계정에 직접 접속해 검증한 기록은 아니다.

## 현재 확인된 설정

| 항목 | 현재 상태 |
|---|---|
| Terraform state용 S3 버킷 | `42voicebridge-tfstate`를 AWS 루트 사용자로 로그인하여 생성 |
| 버킷 설정 | 버전 관리 활성화, 퍼블릭 액세스 차단, 그 외 생성 옵션은 기본값으로 설정했다고 전달받음 |
| 버킷 리전 | 운영자 콘솔 확인: Asia Pacific (Seoul), `ap-northeast-2` |
| IAM 사용자 | `github-deploy-user`에 아래 정책 7개가 직접 연결된 화면 확인 |
| AWS 배포 액세스 키 | 운영자 확인: `github-deploy-user`에서 발급해 Infra 저장소 Actions Secrets에 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`로 등록 완료. 값 자체는 이 저장소에서 확인하지 않음 |
| Terraform 코드 | 세 레이어의 S3 backend, 서로 다른 state key, S3 잠금 파일 및 상위 레이어의 S3 `terraform_remote_state` 설정 완료. 운영자 확인: 기존 로컬 state 없음. AWS에서 실제 `terraform init` 실행 결과는 아직 확인 전 |
| CD 워크플로 | `.github/workflows/cd-preflight.yml`에 수동 실행과 BE `deploy-backend` 이벤트를 받는 준비 점검 추가. AWS 인증·버킷 리전·S3 backend 초기화·Terraform 검증만 수행하며 `apply`와 앱 배포는 아직 구현되지 않음. BE `main` 연동도 아직 미구현 |

IAM 사용자에 직접 연결된 정책:

| 정책 | 현재 용도 / 비고 |
|---|---|
| `AmazonEC2FullAccess` | VPC, EC2, 보안그룹, EIP 등 |
| `AmazonElastiCacheFullAccess` | Redis |
| `AmazonRDSFullAccess` | MySQL RDS |
| `AmazonS3FullAccess` | S3 리소스 및 state 버킷. 현재는 모든 버킷에 대한 광범위한 권한 |
| `AmazonSSMFullAccess` | 향후 SSM 명령 배포. 현재는 모든 SSM 리소스에 대한 광범위한 권한 |
| `IAMFullAccess` | EC2 역할, 정책, Instance Profile. 다른 IAM 사용자·역할도 변경할 수 있는 광범위한 권한 |
| `IAMUserChangePassword` | IAM 사용자 암호 변경용. Terraform/CD 실행에는 필요하지 않음 |

위 목록은 **현재 연결된 정책의 기록**이며, CD용 최소 권한 정책이라는 뜻은 아니다. 초기 CD는 이 사용자로 연결하고, 권한 축소는 배포가 동작한 뒤 진행할 후속 작업으로 남긴다. 축소 전에는 `IAMFullAccess` 등 프로젝트 외 리소스까지 접근할 수 있는 권한이 유지된다. AWS 액세스 키는 운영자 확인에 따라 **이 Infra 저장소의 Actions Secrets**에 등록됐다. 루트 계정의 액세스 키는 CD에 사용하지 않는다.

키 생성 화면의 **Access key ID**는 GitHub Secret `AWS_ACCESS_KEY_ID`, **Secret access key**는 `AWS_SECRET_ACCESS_KEY`에 각각 넣는다. 실제 키 값은 코드나 문서에 기록하지 않는다.

## 결정과 코드의 상태

- [ADR 0001](adr/0001-terraform-state-s3.md): 앱 리소스와 분리한 S3 버킷에 Terraform state를 보관한다.
- [ADR 0002](adr/0002-main-branch-cd.md): BE `main` 푸시와 이미 검증된 GHCR 이미지를 배포 흐름에 사용한다.
- [ADR 0003](adr/0003-github-deploy-identity.md): 전용 IAM 사용자의 AWS 키를 CD에 사용하되, 현재의 전체 접근 정책을 배포용 권한으로 축소한다.

이 ADR들은 설계 결정을 기록한다. Terraform S3 backend는 코드에 반영됐지만 AWS에서 초기화 결과는 아직 확인하지 않았다. IAM 권한 축소, BE 워크플로, SSM 배포는 아직 코드에 반영되지 않았다. Infra에는 배포 전 준비 점검 워크플로가 있다.

## 다음 작업 순서

1. 콘솔에서 `42voicebridge-tfstate`의 버전 관리와 퍼블릭 액세스 차단을 다시 확인한다. 리전은 운영자 확인에 따라 `ap-northeast-2`로 설정했다. state 버킷은 `2_storage`의 녹음/TTS 버킷과 별개이며 앱 자원보다 오래 유지한다.
2. Infra 저장소의 Actions에서 `CD preflight (no deployment)`를 수동 실행해 AWS 인증과 세 S3 backend 초기화를 확인한다. state key 경로는 `dev/1_base/terraform.tfstate`, `dev/2_storage/terraform.tfstate`, `dev/3_application/terraform.tfstate`다. 기존 로컬 state가 없다고 확인됐으므로 migration은 하지 않는다. 첫 `apply` 전에는 S3에 state 객체가 없어도 정상이다.
3. EC2 역할에 SSM 관리 권한을 붙이고 배포 방식에 따라 현재 Terraform의 SSH 키 페어·22번 포트 요구사항을 정리한다. SSM 방식으로 확정하기 전에는 기존 SSH 설정을 그대로 취급한다.
4. BE 저장소에서 `main` 이미지 게시 성공 후 Infra 저장소의 CD 워크플로를 호출한다. BE에는 Infra 저장소의 `repository_dispatch`를 호출할 GitHub 토큰이 필요하다. Infra 워크플로가 `1_base → 2_storage → 3_application` 순서로 적용하고, 전달받은 BE 커밋의 GHCR 이미지로 배포한다. GHCR 패키지가 비공개라면 EC2의 이미지 읽기 인증도 준비한다.
5. **후속 작업:** CD 동작 확인 후 `github-deploy-user` 정책을 state 버킷, 프로젝트 리소스, 앱 EC2 역할의 `iam:PassRole`, 대상 EC2의 SSM 명령 범위로 축소한다. `IAMUserChangePassword`가 불필요하다면 제거한다. OIDC 전환 시 액세스 키를 비활성화·삭제한다.
6. 테스트가 끝난 뒤 `3_application → 2_storage → 1_base` 순서로 종료하는 절차를 마련한다. **state 버킷은 모든 `destroy`가 끝날 때까지 삭제하지 않는다.**

환경변수와 자격증명의 관리 주체·저장 위치·읽기 권한은 [배포 환경변수 명세](ENVIRONMENT-VARIABLES.md)에 정리했다. 애플리케이션 변수의 원본 설명은 [BE 배포 문서](https://github.com/42VoiceBridge/42VoiceBridge_BE/blob/develop/docs/DEPLOYMENT.md)를 따른다. 현재 인프라 실행 절차는 [GUIDE.md](GUIDE.md)를 참고한다.

BE 연동을 추가할 때는 이미지 게시 성공 후 `repository_dispatch`의 `event_type`을 `deploy-backend`로 호출하고, `client_payload`에 `ref: refs/heads/main`과 40자리 소문자 커밋 `sha`를 전달한다. 이 이벤트를 받아도 현재 워크플로는 준비 점검만 실행한다.

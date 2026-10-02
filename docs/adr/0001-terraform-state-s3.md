# ADR 0001: Terraform state를 별도 S3 버킷에 보관

- 날짜: 2026-10-02
- 상태: Accepted
- 구현 상태: 버킷 생성 완료. S3 backend, 레이어 간 remote state 참조, S3 잠금 파일 설정 완료. GitHub Actions에서 세 레이어 초기화·검증 성공.

## 배경

기존 `1_base`, `2_storage`, `3_application`은 각각 로컬 `terraform.tfstate`를 사용하도록 설계됐다. GitHub Actions의 새로운 실행 환경에서 로컬 파일을 자동으로 재사용할 수 없어 반복 `apply`와 `destroy`에 사용할 공유 state가 필요하다. 운영자는 기존 로컬 state가 없다고 확인했다.

## 결정

Terraform state 전용 S3 버킷 `42voicebridge-tfstate`를 앱 리소스와 별도로 유지한다. 운영자가 AWS 루트 사용자로 로그인하여 버킷을 생성했고, 버전 관리와 퍼블릭 액세스 차단을 설정했다. 그 외 생성 옵션은 기본값으로 설정했다고 전달받았다. 운영자가 확인한 버킷 리전은 `ap-northeast-2`다.

세 레이어는 같은 버킷에서 `dev/1_base/terraform.tfstate`, `dev/2_storage/terraform.tfstate`, `dev/3_application/terraform.tfstate`를 각각 사용한다. backend의 `use_lockfile = true`로 S3 잠금 파일을 사용한다. `2_storage`와 `3_application`의 `terraform_remote_state`도 이 원격 state를 읽는다.

## 결과

- 앱용 EC2, RDS, Redis, 녹음/TTS S3를 삭제할 때도 state 버킷은 유지한다. 마지막 `destroy`와 state 확인이 끝난 후에만 정리한다.
- 버전 관리로 이전 state 버전도 보관되므로 저장량과 요청 수에 따라 S3 요금이 발생한다.
- state에는 민감한 정보가 포함될 수 있다. 퍼블릭 액세스를 차단하고, state 버킷에 대한 IAM 접근을 배포 주체와 관리자에게만 허용한다.
- 기존 local state로 이미 자원을 만들었다면 빈 원격 state에서 재생성하지 않고 기존 state를 이전해야 한다.

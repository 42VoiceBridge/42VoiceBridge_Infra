# Troubleshooting 0001: GitHub Actions에서 Terraform provider 체크섬 불일치

- 날짜: 2026-10-02
- 관련 워크플로: [CD preflight](../../.github/workflows/cd-preflight.yml)

## 에러가 발생한 상황

Infra 저장소의 `CD preflight (no deployment)` [첫 실행](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/36981415567)에서 AWS 인증과 `42voicebridge-tfstate` 버킷 리전 확인이 통과했다. `1_base`의 `terraform init`도 S3 backend 연결에 성공했지만, 이어진 `terraform validate`에서 다음 오류가 발생했다.

```text
Successfully configured the backend "s3"!
Warning: Provider lock file not updated
Error: registry.terraform.io/hashicorp/aws: the cached package for
registry.terraform.io/hashicorp/aws 5.100.0 (in .terraform/providers)
does not match any of the checksums recorded in the dependency lock file
```

워크플로는 `terraform apply`를 실행하지 않았으므로 이 실패로 인프라 자원이나 state 객체가 생성되지는 않았다.

## 원인 발견 과정

1. 실패 단계가 S3 연결 이후의 `terraform validate`임을 로그에서 확인했다. 따라서 AWS 자격증명이나 버킷 접근보다 provider 검증을 먼저 조사했다.
2. 각 레이어의 `.terraform.lock.hcl`을 확인했다. 로컬 macOS ARM(`darwin_arm64`)에서 기록한 `h1:` 체크섬과 provider 배포 파일의 `zh:` 체크섬은 있었지만, GitHub Actions의 Linux x86-64(`linux_amd64`)용 `h1:` 체크섬은 없었다.
3. 워크플로의 `terraform init -lockfile=readonly`는 잠금 파일을 갱신하지 않는다. 로그에는 `Provider lock file not updated` 경고가 있었고, 설치된 Linux provider를 확인하는 `validate`가 체크섬 불일치로 멈췄다. Linux 체크섬을 추가한 뒤 재실행에 성공한 결과까지 종합하면, 플랫폼별 체크섬 누락이 원인이었다.

Terraform은 provider 버전과 체크섬을 잠금 파일에 기록하고, 설치된 provider가 기록된 체크섬과 일치하는지 확인한다. 플랫폼별 체크섬을 미리 기록하는 방법은 [Terraform 잠금 파일 문서](https://developer.hashicorp.com/terraform/language/files/dependency-lock)와 [`terraform providers lock` 문서](https://developer.hashicorp.com/terraform/cli/commands/providers/lock)에 설명돼 있다.

## 시도한 해결법

저장소 루트에서 각 레이어에 대해 두 실행 플랫폼의 체크섬을 요청했다.

```bash
terraform -chdir=infra/environments/dev/1_base providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=infra/environments/dev/2_storage providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform -chdir=infra/environments/dev/3_application providers lock -platform=darwin_arm64 -platform=linux_amd64
```

명령 실행 결과 `1_base`와 `3_application`의 `hashicorp/aws`, `2_storage`의 `hashicorp/aws`와 `hashicorp/random`에 Linux용 `h1:` 체크섬이 추가됐다. 세 레이어의 provider 버전은 그대로 유지됐다.

## 최종적으로 해결된 방법

변경된 세 `.terraform.lock.hcl`을 [커밋 `bd77872`](https://github.com/42VoiceBridge/42VoiceBridge_Infra/commit/bd77872)로 푸시하고 준비 점검을 다시 실행했다. [재실행 결과](https://github.com/42VoiceBridge/42VoiceBridge_Infra/actions/runs/36981904406), AWS 인증, S3 버킷 리전 확인, 세 레이어의 `terraform init`과 `terraform validate`가 모두 통과했다.

## 재발 방지

provider를 추가하거나 Terraform 실행 플랫폼을 바꾸면 해당 플랫폼을 포함해 `terraform providers lock`을 실행하고 변경된 잠금 파일을 커밋한다. 워크플로의 `-lockfile=readonly`는 유지해 누락된 체크섬이나 의도하지 않은 provider 변경을 검증 중에 발견한다.

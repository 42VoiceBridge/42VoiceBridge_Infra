# ADR 0003: 전용 IAM 사용자로 CD의 AWS API를 호출

- 날짜: 2026-10-02
- 상태: Accepted
- 구현 상태: `github-deploy-user` 생성 및 AWS 관리형 정책 연결 확인. 운영자 확인으로 액세스 키의 Infra Actions Secrets 등록 완료. 준비 점검 워크플로에 AWS 인증 연결, 실제 실행 결과 확인 전. 권한 축소는 초기 CD 동작 확인 후 진행할 후속 작업.

## 배경

Infra GitHub Actions가 Terraform과 앱 배포를 실행하려면 AWS API 자격증명이 필요하다. 현재 선택한 방식은 전용 IAM 사용자의 액세스 키다. 이 사용자는 인프라 생성·삭제와 배포 명령을 모두 수행하므로 앱 배포만 하는 사용자보다 강한 권한이 필요하다.

## 결정

루트 액세스 키 대신 `github-deploy-user`를 사용한다. AWS 키는 **Infra 저장소의 Actions Secrets**에 등록한다. BE 저장소는 Infra의 CD를 호출하는 GitHub 토큰만 사용하며 AWS 키를 보관하지 않는다. 현재 직접 연결된 7개 정책은 [CD 준비 상태](../DEPLOYMENT-SETUP.md)에 기록한다. 초기 CD를 먼저 연결하고, 프로젝트의 Terraform 자원·state 버킷·배포 대상에 맞춘 권한 축소는 후속 작업으로 진행한다.

## 결과

- `IAMFullAccess`, `AmazonS3FullAccess`, `AmazonSSMFullAccess` 등은 프로젝트 외 리소스까지 접근할 수 있다. 초기 배포 후 이 범위를 축소하는 작업을 추적한다.
- 사용자 정책에는 Terraform의 EC2/VPC·RDS·ElastiCache·S3·IAM 작업, state 버킷 접근, 대상 EC2의 SSM 명령이 필요하다. `iam:PassRole`은 앱 EC2 역할로 제한한다.
- EC2 자체에는 별도 Instance Profile이 필요하다. EC2의 SSM 관리 권한과 앱 비밀값 읽기 권한은 `github-deploy-user`의 정책과 별도로 설정한다.
- 액세스 키는 Infra GitHub Actions Secrets에 등록했다는 운영자 확인을 받았다. 코드·문서·Terraform state에 값을 기록하지 않는다.

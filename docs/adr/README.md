# 배포 관련 ADR

ADR은 합의한 설계 선택과 그 이유를 기록한다. `Accepted`는 방향을 정했다는 뜻이며, 구현 완료 여부는 각 문서의 `구현 상태`를 확인한다.

| 번호 | 결정 | 구현 상태 |
|---|---|---|
| [0001](0001-terraform-state-s3.md) | Terraform state를 별도 S3 버킷에 보관 | S3 backend 코드 반영, AWS 연결 점검 성공 |
| [0002](0002-main-branch-cd.md) | BE `main`과 GHCR 이미지로 CD 수행 | Infra 준비 점검 워크플로 추가, 실제 배포 구현 전 |
| [0003](0003-github-deploy-identity.md) | 전용 IAM 사용자 키로 AWS API 호출 | 키의 Infra Secrets 등록 및 준비 점검 워크플로의 AWS 인증 성공. 권한 축소는 후속 작업 |

현재 콘솔 설정은 [CD 준비 상태](../DEPLOYMENT-SETUP.md)에 기록한다.

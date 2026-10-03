# 배포 관련 ADR

ADR은 설계 선택과 그 이유를 기록한다. `Accepted`는 방향을 정했다는 뜻이며 `Superseded`는 뒤의 ADR이 대체했다는 뜻이다. 구현 완료 여부는 각 문서의 `구현 상태`를 확인한다. ADR 0004의 `Pending`은 SSH와 SSM 중 최종 운영 방식을 아직 확정하지 않았다는 뜻이다.

| 번호 | 결정 | 상태 | 구현 상태 |
|---|---|---|---|
| [0001](0001-terraform-state-s3.md) | Terraform state를 별도 S3 버킷에 보관 | Accepted | S3 backend 코드 반영, AWS 연결 점검 성공 |
| [0002](0002-main-branch-cd.md) | BE `main`과 GHCR 이미지로 CD 수행 | Accepted | Infra 준비 점검과 수동 SSM 배포 코드 구현, 자동 연동·실제 배포 전 |
| [0003](0003-github-deploy-identity.md) | 전용 IAM 사용자 키로 AWS API 호출 | Accepted | 키의 Infra Secrets 등록 및 준비 점검 워크플로의 AWS 인증 성공. 권한 축소는 후속 작업 |
| [0004](0004-ec2-access-method.md) | 앱 EC2 접속·배포 방식 선택 | Pending | SSM 역할·수동 배포 코드 구현, SSH 설정 유지, 실제 SSM 배포 전 |
| [0005](0005-ai-serving-topology.md) | AI 추론 서버 배포 위치: 같은 EC2의 별도 컨테이너 | Superseded (0006) | 대체됨. AI 서버 관련 사실(실측·CPU 학습·상태 데이터)은 기록으로 유효 |
| [0006](0006-three-instance-topology.md) | FE·BE·AI 개별 인스턴스, 고정 사설 IP, FE 엣지(HTTPS), 역할별 IAM, 락·레이어별 apply | Accepted | Terraform·SSM·워크플로·테스트 구현, AWS 적용·실측 전. [인프라 검증 가이드](../INFRA-VERIFICATION.md) |

현재 콘솔 설정은 [CD 준비 상태](../DEPLOYMENT-SETUP.md)에 기록한다.

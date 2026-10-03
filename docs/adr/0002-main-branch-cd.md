# ADR 0002: BE main 푸시로 인프라와 애플리케이션 배포

- 날짜: 2026-10-02
- 상태: Accepted
- 구현 상태: Infra 쪽은 코드로 구현했다(2026-10-03). **BE뿐 아니라 AI·FE도 같은 방식**으로 호출한다: `deploy-backend`/`deploy-ai`/`deploy-frontend` 이벤트를 각각 받는 워크플로, 형식·출처 검증, 락, 인스턴스별 SSM 배포, 레이어별 plan/apply. 송신 쪽은 AI·FE CI가 구현됐고 **BE CI는 미구현**이다. AWS 적용과 실제 이벤트 실행은 전. 자세한 내용은 [CI/CD 흐름](../CICD-FLOW.md), 인스턴스 구성은 [ADR 0006](0006-three-instance-topology.md).
- 갱신(2026-10-03): 이 ADR의 "Infra CD가 Terraform을 적용한다"는 **자동 apply가 아니다.** 초기 프로비저닝과 인프라 변경은 레이어별 plan/apply 워크플로를 수동으로 실행하고, 이벤트는 서비스 배포(이미지 교체)만 일으킨다. 호출 방식과 토큰 권한은 [후속 작업](../FOLLOW-UPS.md#2-호출-방식과-토큰).

## 배경

BE 저장소의 CI가 이미 GHCR에 컨테이너 이미지를 게시한다. 앱은 이 저장소의 Terraform이 만드는 EC2에서 실행할 예정이다. 배포 기준 브랜치는 BE `main`이다.

## 결정

BE `main` 푸시에서 CI 테스트와 GHCR 이미지 게시가 성공하면 BE 워크플로가 Infra 저장소에 배포 이벤트를 보낸다. Infra 저장소의 CD 워크플로가 Terraform을 `1_base → 2_storage → 3_application` 순서로 적용하고, 이벤트로 전달된 BE 커밋의 GHCR 이미지(`sha-<commit>` 또는 digest)를 EC2에 배포한다. EC2에서 BE Git 저장소를 다시 받아 빌드하지 않는다.

## 결과

- 배포 이미지의 커밋을 추적할 수 있고, 이미지 게시 실패 시 배포를 시작하지 않는다.
- BE 워크플로에는 Infra 저장소의 `repository_dispatch`를 호출할 GitHub 토큰이 필요하다. 이 토큰은 BE 저장소에 보관하며 AWS 액세스 키와 다르다. GHCR 패키지가 비공개인 경우 EC2의 이미지 읽기 인증도 필요하다.
- Infra CD 워크플로는 저장소의 기본 브랜치에 있어야 하고, 수신한 BE 커밋과 이미지 식별자를 확인한 뒤 배포한다.
- `main` 푸시마다 `terraform apply`를 실행하면 자원이 없을 때 생성되고, 있으면 변경을 적용한다. 자동 `destroy`는 이 결정에 포함하지 않는다. 대회 테스트 후 종료 절차를 별도로 마련한다.
- 앱 설정, 상태 확인, 실패 복구 방식은 워크플로 구현 시 구체화한다.

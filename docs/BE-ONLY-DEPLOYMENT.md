# AI를 제외한 BE 선배포

최종 확인: 2026-10-03 (Asia/Seoul). AI 서버와 모델은 아직 AWS에 배포되지 않았다. 먼저 BE, RDS, Redis, 앱 S3 및 SSM 배포 경로를 검증한다. `AI_SERVER_BASE_URL`은 이 단계에서 생략할 수 있지만 AI 의존 기능은 사용할 수 없다.

## 현재 상태

| 항목 | 확인된 상태 |
|---|---|
| Terraform state | 서울 리전의 별도 버킷 `42voicebridge-tfstate` 생성, 세 레이어 backend 준비 점검 성공. 첫 `apply` 전에는 state 객체가 없을 수 있음 |
| 배포용 AWS 인증 | `github-deploy-user`의 키를 Infra 저장소 Actions Secrets에 등록했다고 운영자가 확인. 실제 값은 저장소에 보관하지 않음 |
| BE 이미지 | BE CI가 GHCR에 게시 중이라고 운영자가 확인. 대상 이미지의 공개 여부와 배포할 `main` SHA는 별도 확인 필요 |
| 앱 비밀값 | 운영자가 서울 리전 Secrets Manager에 NCP 인증 정보 두 개와 JWT 서명 값을 등록했다고 확인. **시크릿 이름과 JSON 필드명이 배포 코드와 일치하는지는 미확인** |
| SSM | EC2 역할·수동 Actions 워크플로·배포 스크립트를 코드에 반영. Terraform 적용, EC2 등록 및 실제 배포 성공은 미확인 |
| 자동 CD | BE `main` → Infra 이벤트 연결 및 Terraform `apply` 워크플로는 미구현. 현재 이벤트는 준비 점검만 실행 |

## 다음 실행 순서

1. 서울 리전의 앱 시크릿 이름이 기본값 `voicebridge/dev/app`인지 확인한다. 다르면 Terraform의 `app_secret_name`에 실제 이름을 지정한다. JSON에는 `JWT_SECRET`, `NCP_TTS_API_KEY_ID`, `NCP_TTS_API_KEY`가 각각 있어야 한다. NCP의 계정 API Access Key가 아닌 **CLOVA Voice 애플리케이션 Client ID/Secret**을 사용한다. 비밀값은 문서, Terraform 변수, Actions 로그에 기록하지 않는다.
2. GHCR 패키지 공개 여부를 확인한다. 비공개라면 앱 시크릿에 `GHCR_USERNAME`, `GHCR_READ_TOKEN`을 추가하고 대상 패키지 읽기 권한을 확인한다. BE `main`의 전체 40자리 SHA로 `sha-<SHA>` 이미지가 게시됐는지도 확인한다.
3. RDS **초기 스키마 또는 마이그레이션 방법**을 준비한다. BE `prod` 설정의 `ddl-auto: validate`는 빈 DB에 테이블을 생성하지 않으므로, 이를 해결하기 전에는 앱 구동 성공을 기대할 수 없다.
4. 예상 비용과 Terraform 입력을 확인한 뒤 `1_base → 2_storage → 3_application` 순서로 `plan`·`apply`한다. 현재 `ssh_key_name`과 제한된 `ssh_allowed_cidr` 입력은 여전히 필요하다. 이 단계는 현재 수동이며 [SSM 워크플로](SSM-DEPLOYMENT.md)가 인프라를 만들지 않는다.
5. Infra Actions의 **SSM deploy (manual)**에서 `mode=check`를 실행해 EC2의 SSM 등록과 Docker 준비를 확인한다. 이어 `mode=deploy`에 BE `main` 이미지의 전체 SHA를 넣어 배포한다. HTTP 응답 확인은 약한 검사이므로 DB 연결과 핵심 BE 기능을 별도로 확인한다.
6. 수동 배포가 검증되면 Infra의 Terraform `plan`·`apply` 실행과 BE `main` 이미지 게시 성공 후 `repository_dispatch` 호출을 연결한다. 호출용 `INFRA_DISPATCH_TOKEN`은 **BE 저장소 Secrets**에 둔다. AWS 키는 Infra 저장소 Secrets에 둔다.
7. 짧은 테스트를 마치면 `3_application → 2_storage → 1_base` 순서로 `destroy`한다. 단 `3_application`의 데이터 EBS 볼륨에는 `prevent_destroy`가 걸려 있어 단순 `terraform destroy`는 중단된다. 삭제 방법은 [AI 배포 가이드](AI-DEPLOYMENT.md#데이터-볼륨-삭제와-비용-정리)를 따른다. EC2만 중지해도 RDS, Redis, 스토리지 비용은 계속 발생할 수 있다. state 버킷은 모든 레이어 정리와 state 확인이 끝날 때까지 유지한다.

AI는 [ADR 0005](adr/0005-ai-serving-topology.md)에 따라 같은 EC2의 별도 컨테이너로 배포한다. 절차는 [AI 배포 가이드](AI-DEPLOYMENT.md)에 있다. AI 배포 후 앱 시크릿에 `AI_SERVER_BASE_URL=http://voicebridge-ai:8000`을 추가하고 BE를 다시 배포해 연결을 검증한다. 진행 여부와 완료 근거는 [배포 진행표](../deploy-step.md)에 갱신한다.

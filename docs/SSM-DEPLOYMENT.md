# SSM 배포 경로

2026-10-03 기준으로 코드 경로를 구현했다. Terraform `apply`, EC2의 SSM 등록, 앱 배포 성공은 아직 확인되지 않았다. 현재 SSH 키 페어와 22번 포트는 유지한다. [ADR 0004](adr/0004-ec2-access-method.md)의 상태도 실제 검증 전까지 `Pending`이다.

## 실행 구조

1. 운영자가 Infra 저장소 `main`에서 **SSM deploy (manual)**을 실행한다. `check`는 SSM 연결과 Docker 준비 상태를 확인한다. `deploy`는 BE `main`에 게시된 이미지의 **전체 40자리 커밋 SHA**를 입력받는다.
2. Actions는 S3에 저장된 `3_application` state에서 EC2 ID를 읽고 SSM의 `Online` 상태를 확인한다. `deploy` 시에는 `2_storage` state에서 RDS·Redis·앱 S3 정보를 읽는다. 워크플로는 Terraform `apply`를 실행하지 않는다.
3. Actions가 [EC2 배포 스크립트](../scripts/ssm/deploy-ec2.sh)를 앱 S3 버킷의 `deploy/scripts/<SHA-256>.sh`에 올린다. SSM Run Command에는 다운로드·해시 검증·실행 명령과 리소스 주소만 전달한다. 시크릿 값은 전달하지 않는다.
4. EC2가 자신의 Instance Profile로 앱 시크릿과 RDS 관리형 시크릿을 읽고 `ghcr.io/42voicebridge/42voicebridge_be:sha-<BE 커밋>` 이미지를 실행한다. 기존 컨테이너는 새 컨테이너가 응답할 때까지 보관하고, 실패하면 다시 시작한다.

## 선행 조건

- `1_base → 2_storage → 3_application` 순서로 Terraform을 **수동 적용**하고, 세 state와 EC2가 실제 생성돼 있어야 한다. 이 워크플로는 인프라 생성을 맡지 않는다. 현재 `ssh_key_name`과 `ssh_allowed_cidr` 입력이 계속 필요하다.
- 앱용 Secrets Manager 시크릿 `voicebridge/dev/app`을 같은 AWS 계정의 `ap-northeast-2`에 생성한다. AI를 제외한 BE 배포에는 아래 세 필드가 필요하다. 비밀값을 문서·Terraform 변수·GitHub Secrets에 복제하지 않는다.

  계정·IAM 역할과 콘솔 생성 절차는 [Secrets Manager 개념 문서](concepts/aws-secrets-manager.md)에 정리했다.

  ```json
  {
    "JWT_SECRET": "실제-값",
    "NCP_TTS_API_KEY_ID": "실제-값",
    "NCP_TTS_API_KEY": "실제-값"
  }
  ```

  AI 서버를 배포한 뒤에는 `AI_SERVER_BASE_URL`을 실제 연결 주소로 추가한다. 생략하면 BE는 기존 로컬 기본 주소를 사용하며 AI 의존 기능은 작동하지 않는다. GHCR 패키지가 비공개면 같은 시크릿에 `GHCR_USERNAME`, `GHCR_READ_TOKEN` 두 필드를 모두 추가한다. 토큰에는 대상 패키지의 `read:packages` 권한이 필요하다. 공개 패키지면 두 필드를 생략한다. 앱 시크릿은 AWS 관리자 계정으로 생성·수정하고 EC2 역할에 해당 이름의 `GetSecretValue`만 허용한다.
- RDS 초기 스키마를 준비한다. BE `prod`의 Hibernate 설정은 `validate`이므로 빈 DB에서 앱이 시작되지 않는다.
- EC2가 SSM·S3·Secrets Manager·GHCR에 연결할 수 있어야 한다. 현재 앱 EC2는 퍼블릭 서브넷과 아웃바운드 허용 보안그룹을 사용한다. AL2023 user data가 Docker와 `jq`를 설치하고 SSM Agent를 활성화한다.
- Infra 저장소 Actions Secrets의 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`와 SSM 명령 권한이 필요하다. 기존 `github-deploy-user` 권한을 사용하고 권한 축소는 후속 작업으로 둔다.

## 실행과 확인

GitHub Actions → **SSM deploy (manual)** → `Run workflow`에서 `main`을 선택한다.

1. `mode=check`를 실행한다. `SSM and Docker ready`가 출력되어야 한다.
2. BE `main` CI가 `sha-<전체 SHA>` 이미지를 GHCR에 게시했는지 확인한다.
3. `mode=deploy`, `be_sha=<전체 SHA>`로 실행한다. SSM 명령 ID, 배포 결과와 HTTP 응답 확인 결과가 로그에 출력된다.

현재 상태 확인은 컨테이너가 계속 실행 중이고 `http://127.0.0.1/`가 **어떤 HTTP 응답이든** 반환하는 수준이다. BE에 전용 health endpoint가 없으므로 4xx/5xx도 HTTP 응답으로 간주한다. 앱의 실제 기능과 DB 연결은 별도 스모크 테스트로 확인해야 한다.

실패 시 Actions 로그의 SSM command ID로 AWS Systems Manager의 Run Command 실행 결과를 확인한다. 새 컨테이너의 실행 또는 HTTP 응답 확인이 실패하면 스크립트가 이전 컨테이너를 복원한다. 앱 시크릿과 RDS 시크릿 값은 SSM 명령이나 Actions 로그에 출력하지 않는다.

BE `main` → Infra 이벤트 자동 연결과 Terraform `apply` 워크플로는 아직 별도 작업이다. 현재 `repository_dispatch`는 [준비 점검](../.github/workflows/cd-preflight.yml)만 실행한다.

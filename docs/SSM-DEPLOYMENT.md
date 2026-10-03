# SSM 배포 경로

2026-10-03 기준으로 코드 경로를 구현했다. **Terraform `apply`, 인스턴스의 SSM 등록, 앱 배포 성공은 아직 확인되지 않았다.** 구조의 결정은 [ADR 0006](adr/0006-three-instance-topology.md), 이벤트·락·레이어별 apply는 [CI/CD 흐름](CICD-FLOW.md)을 본다. 현재 SSH 키 페어와 22번 포트는 **BE 인스턴스에만** 유지하고 AI·FE는 SSM으로만 접근한다. [ADR 0004](adr/0004-ec2-access-method.md)의 상태는 실제 검증 전까지 `Pending`이다.

## 실행 구조

1. 트리거는 두 가지다. **이벤트**: BE/AI/FE 저장소 CI가 이미지를 게시한 뒤 `deploy-backend`/`deploy-ai`/`deploy-frontend`를 보내면 해당 워크플로가 그 컴포넌트만 배포한다. **수동**: Infra `main`에서 **SSM deploy (manual)**을 실행한다(`check`, `measure`, `deploy`, `redeploy`).
2. 배포 전에 payload 형식과 소스 레포 `main` 포함 여부를 확인하고 락을 잡는다(Terraform apply와 겹치지 않게).
3. [`run.sh`](../scripts/ssm/run.sh)가 `3_application` state에서 **해당 컴포넌트의 인스턴스 ID**를 보내기 직전에 읽고 SSM `Online`을 확인한다. `deploy`는 `2_storage` state에서 RDS·Redis·앱 S3 정보도 읽는다. 순서는 **AI → BE → FE**이고 앞이 실패하면 뒤는 배포하지 않는다.
4. [`deploy-ec2.sh`](../scripts/ssm/deploy-ec2.sh)를 앱 S3 버킷의 `deploy/scripts/<SHA-256>.sh`에 올린다. SSM Run Command에는 다운로드·해시 검증·실행 명령과 리소스 주소만 전달한다. 시크릿 값은 전달하지 않는다. **각 인스턴스 역할이 이 경로를 읽을 수 있어야 한다**(`deploy/scripts/*`의 `s3:GetObject`).
5. 인스턴스가 자신의 Instance Profile로 GHCR 시크릿(BE는 앱·RDS 시크릿도)을 읽고 `<*_IMAGE_REPOSITORY>:sha-<커밋>` 이미지를 실행한다. 기존 컨테이너는 새 컨테이너가 헬스체크를 통과할 때까지 보관하고, 실패하면 다시 시작한다.
6. 성공한 배포는 SSM Parameter Store(`/voicebridge/dev/deployed/<컴포넌트>`)에 기록한다. 인스턴스가 교체되면 `redeploy`가 이 기록으로 복원한다.

## 컴포넌트별 배포 계약

| | 호스트 포트 | 헬스체크 | 대기 | 비고 |
|---|---|---|---|---|
| BE | **8080** → 8080 | `127.0.0.1:8080`이 어떤 HTTP 응답이든 반환(BE에 헬스 엔드포인트 없음, 4xx/5xx도 응답으로 간주) | 180초 | `AI_SERVER_BASE_URL`은 앱 시크릿에서 읽는다 |
| AI | **8000** → 8000 | `127.0.0.1:8000/v1/health` = 200, 재시작 감지 | 600초 | `/data` 마운트 필수, 프롬프트 풀·소유권 준비, [AI 배포 가이드](AI-DEPLOYMENT.md) |
| FE | 엣지 80/443 | FE(nginx) 컨테이너 IP `:80` = 200, Caddy 20초 동안 실행 유지, `https://<호스트>/`로 신뢰 인증서 확인(**실패는 경고**) | 120초 + HTTPS 180초 | [네트워크·엣지 가이드](NETWORK-AND-EDGE.md) |

보안그룹은 호스트 포트 기준이라 위 포트가 SG 규칙(`be-sg` 8080, `ai-sg` 8000, `fe-sg` 80/443)과 일치해야 한다. 앱의 실제 기능과 DB 연결은 별도 스모크 테스트로 확인해야 한다.

## 선행 조건

- `1_base → 2_storage → 3_application`을 **레이어별로 순서대로** plan → 검토 → apply 한다([CI/CD 흐름](CICD-FLOW.md#초기-인프라-프로비저닝-레이어별로-순서대로)). 세 state와 세 인스턴스가 실제 생성돼 있어야 한다. 배포 워크플로는 인프라를 만들지 않는다. plan에 필요한 `SSH_ALLOWED_CIDR`, `SSH_KEY_NAME`은 Infra 저장소 Variables에 둔다.
- 앱용 시크릿 `voicebridge/dev/app`(BE 값)과 **GHCR 전용 시크릿 `voicebridge/dev/ghcr`**를 같은 AWS 계정의 `ap-northeast-2`에 만든다. 비밀값을 문서·Terraform 변수·GitHub Secrets에 복제하지 않는다. 계정·IAM 역할과 콘솔 생성 절차는 [Secrets Manager 개념 문서](concepts/aws-secrets-manager.md).

  ```json
  // voicebridge/dev/app  — BE 역할만 읽는다
  { "JWT_SECRET": "실제-값", "NCP_TTS_API_KEY_ID": "실제-값", "NCP_TTS_API_KEY": "실제-값",
    "AI_SERVER_BASE_URL": "http://10.0.1.20:8000" }
  // voicebridge/dev/ghcr — BE, AI, FE 역할이 읽는다
  { "GHCR_USERNAME": "깃허브-사용자", "GHCR_READ_TOKEN": "classic PAT (read:packages)" }
  ```

  - `AI_SERVER_BASE_URL`은 AI를 배포한 뒤 `terraform output ai_base_url` 값을 넣고 BE를 다시 배포한다(생략하면 AI 의존 기능이 작동하지 않는다).
  - **GHCR 자격 증명 분리는 값과 IAM을 동시에 바꾸지 않아도 되게 설계했다:** BE는 `voicebridge/dev/ghcr`를 먼저 읽고, 시크릿이 없거나 필드가 비어 있으면 기존 앱 시크릿의 `GHCR_*`로 되돌아간다(경고 출력). AI·FE는 앱 시크릿 읽기 권한이 없어 **`ghcr` 시크릿이 반드시 있어야** 배포된다. 순서: ① `ghcr` 시크릿 생성 ② 배포 성공 확인 ③ 앱 시크릿의 `GHCR_*` 필드 제거. 패키지가 공개면 두 필드를 생략할 수 있다. 토큰은 **classic PAT**(fine-grained는 GHCR 미지원)이고 `read:packages` 범위가 BE·AI·FE 세 패키지에 있어야 하며 조직 SSO 승인이 필요할 수 있다.
- RDS 초기 스키마를 준비한다. BE `prod`의 Hibernate 설정은 `validate`이므로 빈 DB에서 앱이 시작되지 않는다.
- 인스턴스가 SSM·S3·Secrets Manager·GHCR에 연결할 수 있어야 한다. 세 인스턴스는 퍼블릭 서브넷과 아웃바운드 허용 보안그룹을 쓴다(NAT가 없다). AL2023 user data가 Docker와 `jq`를 설치하고 SSM Agent를 활성화한다.
- Infra 저장소 Actions Secrets의 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`와 필요한 권한은 [후속 작업](FOLLOW-UPS.md#1-aws-키)을 본다(`locks/dev/*`와 SSM Parameter Store 권한 포함).

## 수동 실행과 확인

GitHub Actions → **SSM deploy (manual)** → `Run workflow`에서 `main`을 선택한다.

1. `mode=check`: 세 인스턴스 각각의 SSM 연결, Docker, AI의 `/data` 마운트를 확인한다.
2. 소스 레포 `main` CI가 `sha-<전체 SHA>` 이미지를 GHCR에 게시했는지 확인한다.
3. `mode=deploy`에 `be_sha`, `ai_sha`, `fe_sha` 중 필요한 것을 **전체 40자 SHA**로 넣는다. 컴포넌트별 SSM 명령 ID, 배포 결과, 헬스 확인 결과가 로그에 출력된다.
4. `mode=measure`: 사양 확정용 지표 수집(읽기 전용, [사양 확정 절차](OPERATIONS-SIZING.md)). `mode=redeploy`: 마지막 성공 배포로 복원.

실패 시 Actions 로그의 SSM command ID로 AWS Systems Manager의 Run Command 실행 결과를 확인한다. 새 컨테이너가 헬스체크를 통과하지 못하면 스크립트가 이전 컨테이너를 복원한다. 시크릿 값은 SSM 명령이나 Actions 로그에 출력하지 않는다.

## 이벤트로 받는 배포

[CI/CD 흐름](CICD-FLOW.md#레포별-이벤트)에 이벤트 표, 검증, 락, 문제 해결을 정리했다. 요약:

- `deploy-ai`, `deploy-backend`, `deploy-frontend` 이벤트가 각각 [`deploy-ai.yml`](../.github/workflows/deploy-ai.yml), [`deploy-backend.yml`](../.github/workflows/deploy-backend.yml), [`deploy-frontend.yml`](../.github/workflows/deploy-frontend.yml)을 실행한다. **`main`에 머지되기 전에는 이벤트가 와도 워크플로가 실행되지 않는다.**
- `cd-preflight`는 더 이상 이벤트를 받지 않고 수동 점검(AWS 접근, backend, 구성 검증)만 한다.

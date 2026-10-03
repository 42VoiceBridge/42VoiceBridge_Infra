# 배포 환경변수와 자격증명 관리 명세

2026-10-03 기준. [BE 배포 문서](https://github.com/42VoiceBridge/42VoiceBridge_BE/blob/develop/docs/DEPLOYMENT.md), BE의 `application.yml`·`application-prod.yml`, 이 저장소의 Terraform 설정을 대조했다. 운영자가 서울 리전 Secrets Manager에 NCP 인증 정보 두 개와 JWT 서명 값을 등록했다고 확인했다. 시크릿 이름·JSON 필드명과 실제 AWS 자원 적용·앱 배포는 아직 확인되지 않았다. 실제 비밀값은 이 문서에 기록하지 않는다.

## 주체와 저장소

| 주체 | 역할 |
|---|---|
| AWS 관리자 | 초기 state 버킷 생성, 앱용 비밀값 등록·변경, IAM 권한 관리. 루트 사용자로 상시 운영하지 않음 |
| `github-deploy-user` | Infra GitHub Actions에서 Terraform 및 배포용 AWS API 호출. 앱 비밀값을 직접 사용할 필요 없음 |
| Infra GitHub Actions | Terraform output을 조회하고 EC2 배포 명령을 보냄. AWS 키는 **Infra 저장소 Secrets**에서만 읽음 |
| BE GitHub Actions | 테스트, GHCR 이미지 게시, Infra 배포 이벤트 호출. AWS 키를 읽지 않음 |
| 인스턴스 역할(`voicebridge-be-role`, `voicebridge-ai-role`, `voicebridge-fe-role`) | **BE**: 앱 버킷 읽기·쓰기, RDS 비밀번호와 `voicebridge/dev/app` 읽기. **AI**: `ai/*`(프롬프트 풀) 읽기만. **FE**: 추가 권한 없음. **세 역할 공통**: SSM Agent 등록, `deploy/scripts/*` 다운로드, `voicebridge/dev/ghcr` 읽기. Terraform 코드에 정의됨; 실제 적용 미확인 |

## 백엔드 실행 환경변수

| 변수 | 값의 생성·관리 주체 | 원본 저장 위치 / EC2에 전달할 방법 | 필요한 읽기 권한과 현재 상태 |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | 배포 설정 담당자 | 배포 스크립트에서 `prod`로 지정 | EC2 앱 프로세스가 읽음. **코드 구현, 실행 미확인** |
| `DB_URL` | Terraform이 만든 RDS endpoint와 DB 이름으로 배포 과정에서 조합 | `2_storage`의 `rds_endpoint`, `db_name` outputs → `jdbc:mysql://<endpoint>/<db_name>?serverTimezone=Asia/Seoul&characterEncoding=UTF-8` → EC2 환경변수 | Infra 워크플로가 state/output을 읽고 EC2 앱이 사용. **코드 구현, 실행 미확인** |
| `DB_USERNAME` | `2_storage` Terraform 입력 `db_username` 관리자가 설정. 현재 기본값 `voicebridge_admin` | RDS 관리형 시크릿의 `username`을 EC2에서 조회 → 앱 환경변수 | EC2 앱 역할이 해당 RDS 시크릿을 읽음. **코드 구현, 실행 미확인** |
| `DB_PASSWORD` | RDS가 자동 생성·관리 | RDS 관리형 AWS Secrets Manager 시크릿. ARN은 `2_storage`의 `rds_secret_arn` output → EC2에서 조회 후 앱에 전달 | EC2 앱 역할의 해당 ARN에 대한 `secretsmanager:GetSecretValue`는 **현재 Terraform에 정의됨**. 값은 GitHub Secrets에 복제하지 않음 |
| `REDIS_HOST`, `REDIS_PORT` | Terraform이 만든 Redis endpoint/port | `2_storage`의 `redis_endpoint`, `redis_port` outputs → EC2 환경변수 | Infra 워크플로가 state/output을 읽고 EC2 앱이 사용. **코드 구현, 실행 미확인** |
| `S3_BUCKET` | Terraform이 생성 | `2_storage`의 `s3_bucket_name` output → EC2 환경변수 | EC2 앱 역할에 해당 앱 버킷의 객체 읽기·쓰기 권한은 **현재 Terraform에 정의됨**. state 버킷 이름을 넣지 않음 |
| `AWS_REGION` | 인프라 설정 담당자 | Terraform의 `aws_region`과 동일하게 지정. 현재 기본값 `ap-northeast-2` | EC2 앱이 S3 클라이언트 리전으로 사용. **코드 구현, 실행 미확인** |
| `JWT_SECRET` | 배포 관리자가 생성·교체 | AWS Secrets Manager `voicebridge/dev/app` → EC2에서 조회 후 환경변수 | 운영자 확인: 값 등록 완료. **시크릿 이름·필드명 및 역할 적용 미확인** |
| `AI_SERVER_BASE_URL` | AI 인스턴스의 고정 사설 IP 주소 `http://10.0.1.20:8000`(ADR 0006, `terraform output ai_base_url`). 배포 관리자가 등록 | AWS Secrets Manager `voicebridge/dev/app` → EC2 환경변수. **AI 제외 초기 BE 배포에서는 생략 가능** | 실제 AI 주소가 없으면 AI 의존 기능은 작동하지 않음. BE의 `127.0.0.1:8000` 기본값은 컨테이너 안에서 AI 서버를 찾지 못함. BE는 시작 시점에만 값을 읽으므로 변경 후 BE를 다시 배포해야 함 |
| `NCP_TTS_API_KEY_ID`, `NCP_TTS_API_KEY` | NCP **AI·NAVER API → Application**의 CLOVA Voice Client ID / Client Secret을 발급·교체, AWS 관리자가 앱용 시크릿에 등록 | AWS Secrets Manager `voicebridge/dev/app` → EC2 환경변수. NCP 계정의 API Authentication Key(Access Key ID / Secret Key)와 구별 | 운영자 확인: 값 두 개 등록 완료. **시크릿 이름·필드명 및 역할 적용 미확인**. GitHub Secrets에 둘 값이 아님 |
| `FFMPEG_PATH`, `FFPROBE_PATH` | 이미지·런타임 설정 담당자 | 현재 BE 설정 기본값은 각각 `ffmpeg`, `ffprobe`. 기본 경로가 유효하면 별도 환경변수 불필요 | EC2 컨테이너 내부 프로그램 경로. 비밀값 아님 |

`application-prod.yml`은 `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`에 기본값을 주지 않는다. `SPRING_PROFILES_ACTIVE=prod`를 설정해야 이 구성이 적용된다. 앱의 `DB_PASSWORD`를 시작 시 환경변수로 전달하는 방식이라면 RDS 비밀번호 회전 후 새 값을 반영하려면 재시작 또는 재배포가 필요하다.

## CI/CD와 이미지 접근 자격증명

| 이름 | 발급·관리 주체 | 저장 위치 / 사용하는 주체 | 필요한 권한과 현재 상태 |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS 관리자가 `github-deploy-user`에서 발급·교체 | **Infra 저장소 Actions Secrets** → Infra CD 워크플로 | Terraform state/프로젝트 자원과 대상 EC2 배포 권한. 현재 IAM 사용자에는 광범위한 정책 7개가 연결됨. **운영자 확인: 키 발급·Secrets 등록 완료** |
| `INFRA_DISPATCH_TOKEN` | Infra 저장소에 접근할 수 있는 GitHub 계정/조직이 **레포마다 따로** 발급(fine-grained, Infra 레포 하나로 제한) | **BE·AI·FE 각 저장소 Actions Secrets**(Variables 금지: 평문이고 로그에서 마스킹되지 않는다). 각 CI가 이미지 게시 후 이벤트 전송에 사용 | 현재 방식(`repository_dispatch`)은 Infra 레포 `Contents: write`가 필요하다. AI·FE CI는 `secrets.`에서 읽도록 구현됨, BE는 미구현. 실제 저장 위치·노출 여부는 **미확인**. 호출 방식과 권한은 [후속 작업](FOLLOW-UPS.md#2-호출-방식과-토큰) |
| BE 이미지 게시용 `GITHUB_TOKEN` | GitHub Actions가 BE 워크플로마다 제공 | BE 워크플로 실행 시에만 사용 | GHCR 게시에 필요한 `packages: write`. 현재 BE CI가 사용. Infra로 보내는 dispatch 토큰과 구분 |
| `GHCR_USERNAME`, `GHCR_READ_TOKEN` | GHCR 패키지가 **비공개인 경우에만** GitHub에서 발급(AI 패키지는 비공개로 보인다는 AI팀 확인) | AWS Secrets Manager **`voicebridge/dev/ghcr`**(앱 시크릿과 분리). 두 필드를 함께 등록. 공개 패키지면 생략 | **classic PAT**의 `read:packages`(fine-grained는 GHCR 미지원), BE·AI·FE 세 패키지, 조직 SSO 승인. 세 인스턴스 역할이 읽음. BE는 전환 기간 동안 기존 앱 시크릿으로 폴백. 토큰 종류·권한은 **미확인** |

AWS 키 생성 화면의 **Access key ID**는 `AWS_ACCESS_KEY_ID`, **Secret access key**는 `AWS_SECRET_ACCESS_KEY`에 해당한다. 현재 IAM 정책의 권한 축소는 초기 CD 동작 확인 후 진행할 후속 작업이다.

## Infra 저장소 Variables (비밀 아님)

| 이름 | 용도 | 비고 |
|---|---|---|
| `BE_IMAGE_REPOSITORY`, `AI_IMAGE_REPOSITORY`, `FE_IMAGE_REPOSITORY` | 이미지 경로 `ghcr.io/42voicebridge/<패키지>` | 배포 이미지는 항상 이 값 + `:sha-<40자>`로 조립한다(이벤트 payload의 경로는 신뢰하지 않음). AI·BE는 각 CI 기준 `42voicebridge_ai`, `42voicebridge_be`. 자리 표시자가 남아 있으면 형식 검증에서 중단 |
| `SSH_ALLOWED_CIDR` | `1_base` plan 입력(BE의 SSH 허용 CIDR) | `0.0.0.0/0`은 워크플로가 거부 |
| `SSH_KEY_NAME` | `3_application` plan 입력(BE의 EC2 키 페어 이름) | AI·FE에는 SSH 키가 없다 |

## 컴포넌트별 컨테이너 환경변수 (배포 스크립트가 지정)

| 컴포넌트 | 값 | 출처 |
|---|---|---|
| BE | `SPRING_PROFILES_ACTIVE`, `DB_*`, `REDIS_*`, `S3_BUCKET`, `AWS_REGION`, `JWT_SECRET`, `NCP_TTS_*`, `AI_SERVER_BASE_URL` | 위 표. 시크릿에서 읽어 env-file로 전달(명령줄에 노출하지 않음) |
| AI | `HF_HOME=/data/hf`, `ALLOW_CPU_TRAIN=1` (나머지는 AI 이미지의 Dockerfile) | [AI 배포 가이드](AI-DEPLOYMENT.md) |
| FE | (없음) `VITE_API_URL` 등은 **이미지 빌드 시점**에 FE CI가 번들에 넣는다 | [네트워크·엣지 가이드](NETWORK-AND-EDGE.md#fe-레포에-요청할-변경-같은-출처-api) |
| FE 엣지(Caddy) | 공개 호스트(`fe_public_host`)와 BE 업스트림(`be_upstream`)을 Caddyfile로 생성 | Terraform 출력 |

## 카카오 로그인과 AWS 키

현재 BE는 클라이언트가 `/api/v1/auth/kakao`에 보낸 `kakaoAccessToken`을 카카오 사용자 정보 API에 전달한다. **BE 서버용 카카오 API 키 환경변수는 현재 없다.** 클라이언트의 카카오 앱 설정과 이 표의 서버·CD 비밀값을 혼동하지 않는다.

앱 S3 접근에는 EC2 Instance Profile을 사용한다. 따라서 **백엔드 컨테이너에 AWS 액세스 키를 주입하지 않는다.** Terraform state 버킷 `42voicebridge-tfstate` 역시 앱의 `S3_BUCKET`과 별개다.

현재 AWS 수동 설정과 구현 순서는 [CD 준비 상태](DEPLOYMENT-SETUP.md), 설계 결정은 [ADR 목록](adr/README.md)을 참고한다.

AI를 제외한 첫 BE 배포의 확인 순서는 [BE 선배포 문서](BE-ONLY-DEPLOYMENT.md)에 정리했다.

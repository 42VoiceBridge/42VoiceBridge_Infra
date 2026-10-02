# 배포 환경변수와 자격증명 관리 명세

2026-10-02 기준. [BE 배포 문서](https://github.com/42VoiceBridge/42VoiceBridge_BE/blob/develop/docs/DEPLOYMENT.md), BE의 `application.yml`·`application-prod.yml`, 이 저장소의 Terraform 설정을 대조했다. 아래의 **예정**은 저장소에 CD 코드나 AWS 시크릿 생성이 아직 확인되지 않은 상태를 뜻한다. 실제 비밀값은 이 문서에 기록하지 않는다.

## 주체와 저장소

| 주체 | 역할 |
|---|---|
| AWS 관리자 | 초기 state 버킷 생성, 앱용 비밀값 등록·변경, IAM 권한 관리. 루트 사용자로 상시 운영하지 않음 |
| `github-deploy-user` | Infra GitHub Actions에서 Terraform 및 배포용 AWS API 호출. 앱 비밀값을 직접 사용할 필요 없음 |
| Infra GitHub Actions | Terraform output을 조회하고 EC2 배포 명령을 보냄. AWS 키는 **Infra 저장소 Secrets**에서만 읽음 |
| BE GitHub Actions | 테스트, GHCR 이미지 게시, Infra 배포 이벤트 호출. AWS 키를 읽지 않음 |
| EC2 앱 역할(`voicebridge-app-role`) | 실행 중 앱 S3 접근과 RDS 비밀번호 읽기. 앱용 시크릿 읽기 권한은 **추가 예정** |

## 백엔드 실행 환경변수

| 변수 | 값의 생성·관리 주체 | 원본 저장 위치 / EC2에 전달할 방법 | 필요한 읽기 권한과 현재 상태 |
|---|---|---|---|
| `SPRING_PROFILES_ACTIVE` | 배포 설정 담당자 | 배포 스크립트에서 `prod`로 지정 | EC2 앱 프로세스가 읽음. **설정 예정** |
| `DB_URL` | Terraform이 만든 RDS endpoint와 DB 이름으로 배포 과정에서 조합 | `2_storage`의 `rds_endpoint` output → `jdbc:mysql://<endpoint>/<db_name>?serverTimezone=Asia/Seoul&characterEncoding=UTF-8` → EC2 환경변수 | Infra 워크플로가 state/output을 읽고 EC2 앱이 사용. **연결 예정** |
| `DB_USERNAME` | `2_storage` Terraform 입력 `db_username` 관리자가 설정. 현재 기본값 `voicebridge_admin` | Terraform 변수 → EC2 환경변수 | Infra 워크플로와 EC2 앱이 사용. **연결 예정** |
| `DB_PASSWORD` | RDS가 자동 생성·관리 | RDS 관리형 AWS Secrets Manager 시크릿. ARN은 `2_storage`의 `rds_secret_arn` output → EC2에서 조회 후 앱에 전달 | EC2 앱 역할의 해당 ARN에 대한 `secretsmanager:GetSecretValue`는 **현재 Terraform에 정의됨**. 값은 GitHub Secrets에 복제하지 않음 |
| `REDIS_HOST`, `REDIS_PORT` | Terraform이 만든 Redis endpoint/port | `2_storage`의 `redis_endpoint`, `redis_port` outputs → EC2 환경변수 | Infra 워크플로가 state/output을 읽고 EC2 앱이 사용. **연결 예정** |
| `S3_BUCKET` | Terraform이 생성 | `2_storage`의 `s3_bucket_name` output → EC2 환경변수 | EC2 앱 역할에 해당 앱 버킷의 객체 읽기·쓰기 권한은 **현재 Terraform에 정의됨**. state 버킷 이름을 넣지 않음 |
| `AWS_REGION` | 인프라 설정 담당자 | Terraform의 `aws_region`과 동일하게 지정. 현재 기본값 `ap-northeast-2` | EC2 앱이 S3 클라이언트 리전으로 사용. **배포 설정 예정** |
| `JWT_SECRET` | 배포 관리자가 생성·교체 | **예정:** AWS Secrets Manager의 앱용 시크릿 → EC2 환경변수 | EC2 앱 역할에 앱용 시크릿 `GetSecretValue` 권한 **추가 필요**. 로컬 개발 기본값을 prod에 사용하지 않음 |
| `AI_SERVER_BASE_URL` | AI팀이 실제 배포 주소 제공, 배포 관리자가 등록 | **예정:** 배포 설정 → EC2 환경변수. URL 자체에 인증정보가 있다면 비밀값으로 취급 | EC2 앱이 외부 AI 서버 호출에 사용. **실제 주소 확인 필요** |
| `NCP_TTS_API_KEY_ID`, `NCP_TTS_API_KEY` | NCP 관리자가 발급·교체, AWS 관리자가 앱용 시크릿에 등록 | **예정:** AWS Secrets Manager의 앱용 시크릿 → EC2 환경변수 | EC2 앱 역할에 해당 시크릿 `GetSecretValue` 권한 **추가 필요**. `github-deploy-user`나 GitHub Secrets에 둘 값이 아님 |
| `FFMPEG_PATH`, `FFPROBE_PATH` | 이미지·런타임 설정 담당자 | 현재 BE 설정 기본값은 각각 `ffmpeg`, `ffprobe`. 기본 경로가 유효하면 별도 환경변수 불필요 | EC2 컨테이너 내부 프로그램 경로. 비밀값 아님 |

`application-prod.yml`은 `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`에 기본값을 주지 않는다. `SPRING_PROFILES_ACTIVE=prod`를 설정해야 이 구성이 적용된다. 앱의 `DB_PASSWORD`를 시작 시 환경변수로 전달하는 방식이라면 RDS 비밀번호 회전 후 새 값을 반영하려면 재시작 또는 재배포가 필요하다.

## CI/CD와 이미지 접근 자격증명

| 이름 | 발급·관리 주체 | 저장 위치 / 사용하는 주체 | 필요한 권한과 현재 상태 |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | AWS 관리자가 `github-deploy-user`에서 발급·교체 | **Infra 저장소 Actions Secrets** → Infra CD 워크플로 | Terraform state/프로젝트 자원과 대상 EC2 배포 권한. 현재 IAM 사용자에는 광범위한 정책 7개가 연결됨. **운영자 확인: 키 발급·Secrets 등록 완료** |
| `INFRA_DISPATCH_TOKEN` | Infra 저장소에 쓸 권한이 있는 GitHub 계정/조직 | **BE 저장소 Actions Secrets** → BE CI의 `repository_dispatch` 호출 | Infra 저장소에 대한 GitHub `Contents: write` 권한이 있는 fine-grained token 또는 동등한 GitHub App 권한. **발급·등록 여부 미확인** |
| BE 이미지 게시용 `GITHUB_TOKEN` | GitHub Actions가 BE 워크플로마다 제공 | BE 워크플로 실행 시에만 사용 | GHCR 게시에 필요한 `packages: write`. 현재 BE CI가 사용. Infra로 보내는 dispatch 토큰과 구분 |
| GHCR 이미지 읽기 토큰 | GHCR 패키지가 **비공개인 경우에만** GitHub에서 발급 | **예정:** EC2가 안전하게 읽을 저장소(예: 앱용 AWS Secrets Manager 시크릿). 공개 패키지면 불필요 | GHCR 패키지 `read:packages`. EC2가 이미지 pull에 사용. 패키지 공개 여부 미확인 |

AWS 키 생성 화면의 **Access key ID**는 `AWS_ACCESS_KEY_ID`, **Secret access key**는 `AWS_SECRET_ACCESS_KEY`에 해당한다. 현재 IAM 정책의 권한 축소는 초기 CD 동작 확인 후 진행할 후속 작업이다.

## 카카오 로그인과 AWS 키

현재 BE는 클라이언트가 `/api/v1/auth/kakao`에 보낸 `kakaoAccessToken`을 카카오 사용자 정보 API에 전달한다. **BE 서버용 카카오 API 키 환경변수는 현재 없다.** 클라이언트의 카카오 앱 설정과 이 표의 서버·CD 비밀값을 혼동하지 않는다.

앱 S3 접근에는 EC2 Instance Profile을 사용한다. 따라서 **백엔드 컨테이너에 AWS 액세스 키를 주입하지 않는다.** Terraform state 버킷 `42voicebridge-tfstate` 역시 앱의 `S3_BUCKET`과 별개다.

현재 AWS 수동 설정과 구현 순서는 [CD 준비 상태](DEPLOYMENT-SETUP.md), 설계 결정은 [ADR 목록](adr/README.md)을 참고한다.

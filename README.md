# 42VoiceBridge_Infra

[42VoiceBridge_BE](https://github.com/42VoiceBridge/42VoiceBridge_BE) 백엔드가 올라가는 AWS 인프라를 Terraform으로 관리하는 저장소입니다. EC2(앱) + RDS MySQL + ElastiCache Redis + S3(녹음/TTS 오디오)로 구성되어 있으며, AI 서버와 네이버 클로바 보이스는 이 인프라 범위 밖의 외부 서비스입니다.

> ⚠️ 상시 가동하지 않고 테스트할 때만 `apply` → 끝나면 즉시 `destroy` 합니다. 자세한 비용/실행 순서는 [`docs/GUIDE.md`](docs/GUIDE.md) 참고.

## 기술 스택

| 구분 | 기술 |
|---|---|
| IaC | Terraform, 계층형 3-layer 구조 (`1_base` → `2_storage` → `3_application`) |
| State | `42voicebridge-tfstate` S3 backend — 레이어별 별도 경로와 S3 잠금 파일 사용, 상위 레이어는 `terraform_remote_state`로 하위 값을 참조 |
| Cloud | AWS ap-northeast-2 (서울 리전) |
| Compute | EC2 (Amazon Linux 2023) + Elastic IP |
| Database | RDS MySQL 8.0 — 마스터 비밀번호는 AWS Secrets Manager가 자동 관리 |
| Cache | ElastiCache Redis 7.1 |
| Storage | S3 — 녹음/TTS 오디오 저장, 퍼블릭 액세스 완전 차단 |
| Network | VPC — 퍼블릭 서브넷 1개(앱) + 프라이빗 서브넷 2개(RDS/Redis), NAT 게이트웨이 없음 |
| IAM | EC2 Instance Profile — S3 읽기/쓰기 + Secrets Manager 읽기만 최소 권한으로 부여 |

## 아키텍처

```mermaid
graph TB
    USER["사용자 / 42VoiceBridge_BE 클라이언트"]

    subgraph AWS["AWS ap-northeast-2"]
        IGW["Internet Gateway"]

        subgraph VPC["VPC (10.0.0.0/16)"]
            subgraph PUB["퍼블릭 서브넷"]
                EC2["EC2 (app-sg)<br/>Elastic IP, Spring Boot"]
            end

            subgraph PRIV["프라이빗 서브넷 x2 (AZ 분리)"]
                RDS["RDS MySQL 8.0<br/>(rds-sg)"]
                REDIS["ElastiCache Redis 7.1<br/>(redis-sg)"]
            end
        end

        S3["S3<br/>(녹음/TTS 오디오)"]
        SM["Secrets Manager<br/>(RDS 마스터 비밀번호)"]
    end

    USER -- "HTTP/HTTPS" --> IGW --> EC2
    EC2 -- "3306, app-sg → rds-sg 허용" --> RDS
    EC2 -- "6379, app-sg → redis-sg 허용" --> REDIS
    EC2 -- "IAM Instance Profile" --> S3
    EC2 -- "secretsmanager:GetSecretValue" --> SM
    RDS -.비밀번호 자동 관리.-> SM
```

- **app-sg**: SSH(본인 IP만) + HTTP/HTTPS만 인바운드 허용.
- **rds-sg / redis-sg**: app-sg에서 오는 트래픽만 각각 3306/6379로 허용 — 인터넷에서 직접 접근 불가.
- 프라이빗 서브넷에는 NAT 게이트웨이를 두지 않았습니다 (RDS/Redis는 아웃바운드 인터넷이 필요 없고, 비용도 절감).
- S3는 VPC 밖의 리소스지만 EC2의 IAM Instance Profile을 통해서만 접근합니다.

## CI/CD 파이프라인

아래는 **구현 예정인 배포 흐름**입니다. BE의 `main` 푸시가 시작점이며, 이미지 빌드와 AWS 배포는 서로 다른 저장소의 워크플로에서 수행합니다.

```mermaid
sequenceDiagram
    participant BE as BE GitHub Actions
    participant GHCR as GHCR
    participant INFRA as Infra GitHub Actions
    participant STATE as state용 S3
    participant AWS as AWS
    participant EC2 as 앱 EC2

    BE->>BE: main 푸시 후 테스트 및 이미지 빌드
    BE->>GHCR: 커밋 SHA 태그로 이미지 게시
    BE->>INFRA: repository_dispatch (BE 커밋 SHA 전달)
    INFRA->>STATE: Terraform state 읽기 및 잠금
    INFRA->>AWS: Terraform apply (1_base → 2_storage → 3_application)
    AWS-->>INFRA: EC2 등 생성 또는 갱신
    INFRA->>EC2: SSM으로 배포 명령 전달
    EC2->>GHCR: 해당 SHA의 이미지 pull
    EC2-->>INFRA: 앱 실행 및 상태 확인 결과
```

- BE 워크플로는 GHCR 게시가 성공한 뒤 Infra 저장소를 호출합니다. 호출용 GitHub 토큰은 **BE 저장소 Secrets**에 둡니다.
- Infra 워크플로가 Terraform과 EC2 배포를 실행합니다. 배포 IAM 사용자의 AWS 키는 **Infra 저장소 Secrets**에 둡니다.
- [`cd-preflight.yml`](.github/workflows/cd-preflight.yml)은 수동 실행 또는 BE의 `deploy-backend` 이벤트로 AWS 접근, state 버킷 리전, S3 backend 초기화, Terraform 형식·구성을 검사합니다. **아직 Terraform apply나 EC2 배포는 하지 않습니다.** 첫 state 객체는 해당 레이어의 첫 `apply` 때 생성됩니다.
- 테스트 후 인프라 종료는 배포와 별도 절차로 `3_application → 2_storage → 1_base` 순서로 진행합니다. 자세한 결정과 준비 상태는 [CD 준비 문서](docs/DEPLOYMENT-SETUP.md)에 기록합니다.

## 레이어 구조

단일 파일 대신 `1_base`(VPC/서브넷/보안그룹) → `2_storage`(RDS/Redis/S3) → `3_application`(EC2/IAM) 3개 레이어로 나눠 관리합니다. 의존 방향, 실행/destroy 순서, 레이어별 output 조회 방법 등 실제로 손 움직이기 전에 필요한 내용은 전부 [`docs/GUIDE.md`](docs/GUIDE.md)에 있습니다.

## 운영

| 역할 | 담당 |
|---|---|
| 인프라 설계, 운영 | 김주영 |

## 더 알아보기

- 인프라 구조, 비용 경고, 실행/destroy 순서, 연결 정보 조회, `.env` 작성법: [`docs/GUIDE.md`](docs/GUIDE.md)
- CD용 AWS 수동 설정 현황과 남은 작업: [`docs/DEPLOYMENT-SETUP.md`](docs/DEPLOYMENT-SETUP.md)
- 환경변수·토큰의 관리 주체, 저장 위치, 읽기 권한: [`docs/ENVIRONMENT-VARIABLES.md`](docs/ENVIRONMENT-VARIABLES.md)
- 배포 관련 설계 결정: [`docs/adr/README.md`](docs/adr/README.md)
- 애플리케이션이 필요로 하는 환경변수 전체 목록: [42VoiceBridge_BE의 `docs/DEPLOYMENT.md`](https://github.com/42VoiceBridge/42VoiceBridge_BE/blob/develop/docs/DEPLOYMENT.md)

# 후속 작업: 인스턴스 분리 작업이 끝난 뒤 해야 할 것

[ADR 0006](adr/0006-three-instance-topology.md) 구현(PR #10) 이후에 남은 일이다. 운영자 결정으로 **호출 방식**과 **AWS 키**는 이번 작업에서 다루지 않고 이 문서로 남긴다. 2026-10-03 기준이며, 확인하지 못한 것은 "미확인"이라고 표시했다.

## 우선순위 한눈에

| 순서 | 항목 | 왜 | 담당 |
|---|---|---|---|
| 1 | **AWS 키**(plan용·CI용) 준비 | 이게 없으면 `plan`도 실행되지 않는다 | 운영자 |
| 2 | **호출 방식**과 토큰 정리 | 이벤트로 배포가 실행되는 구조라 토큰이 곧 배포 권한이다 | 운영자 + 각 레포 |
| 3 | BE: RDS 초기 스키마, 헬스 엔드포인트, 카카오 값 등록(이벤트 전송은 구현됨) | BE 배포·로그인이 막혀 있다 | BE 팀 |
| 4 | FE: 같은 출처 API(`VITE_API_URL` 빈 값) | 프록시 구조에서 호스트가 바뀌어도 같은 이미지를 쓰려면 필요 | FE 팀 |
| 5 | 도메인과 카카오 도메인 등록 | 안정적인 HTTPS와 로그인 | 운영자 |
| 6 | 이미지 다이제스트 고정 | 태그 덮어쓰기 방지 | Infra + 각 레포 |
| 7 | 배포용 IAM 사용자 권한 축소 | 현재 정책 7개가 광범위하다 | 운영자 |
| 8 | 지표 수집 자동화, 알람 | 사양 확정과 장애 감지 | Infra |

---

## 1. AWS 키

> **키 값은 채팅, 코드, 문서, 로그에 붙여넣지 않는다.** 클라우드 세션용 키는 세션 환경 설정(클라우드 환경 메뉴 → Edit)에 환경변수로 넣는다. Secrets Manager는 앱 실행 값용이라 `plan`용 키 저장소가 될 수 없다(`plan` 자체가 AWS 접근을 요구한다).

### 1-1. 지금 상태

- 클라우드 세션의 `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`는 길이 14자의 플레이스홀더라(실제 키는 20자, 40자) S3 backend 인증이 `InvalidClientTokenId`로 실패한다. 그래서 이 세션에서는 `terraform plan`을 실행하지 못했다.
- Infra 저장소 Actions Secrets에는 `github-deploy-user`의 키가 등록돼 있다고 운영자가 확인했다(미확인: 실제 권한 범위. 정책 7개가 광범위하게 연결돼 있다고 한다).

### 1-2. 세션/로컬 **plan용 키** (별도로 만든다)

- `github-deploy-user`처럼 쓰기 권한이 있는 키를 세션에 넣지 않는다. plan 전용 IAM 사용자를 만든다.
- 이 레포는 **S3 네이티브 잠금**(`use_lockfile = true`)을 쓰고 DynamoDB는 쓰지 않는다. 그래서 필요한 것은 DynamoDB 권한이 아니라 **state 읽기 + 해당 키의 `.tflock` 객체 생성·삭제 + 리소스 조회**다.
- **잠금은 유지한다. `-lock=false`를 쓰지 않는다.** 읽기 전용 권한만으로 plan하려면 잠금을 꺼야 하는데, 공동 state에서는 권장되지 않는다. plan은 state를 바꾸지 않지만 잠금 파일은 쓴다.
- 아래는 **초안**이다. 이 세션에서 HashiCorp 문서를 읽지 못했고 실제로 실행해 보지 못해 **첫 plan 실행으로 검증해야 한다.** 부족하면 AccessDenied에서 필요한 동작을 확인해 추가한다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "StateList",
      "Effect": "Allow", "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::42voicebridge-tfstate" },
    { "Sid": "StateRead",
      "Effect": "Allow", "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::42voicebridge-tfstate/dev/*" },
    { "Sid": "StateLockFile",
      "Effect": "Allow", "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::42voicebridge-tfstate/dev/*.tflock" }
  ]
}
```

여기에 **리소스 조회 권한**을 AWS 관리형 정책으로 더한다.

- `ViewOnlyAccess`(+ 필요하면 `SecurityAudit`)를 권한다. **`ReadOnlyAccess`는 쓰지 않는 것을 권한다.** 모든 S3 객체의 `GetObject`를 포함하므로 사용자 **녹음 데이터**까지 읽을 수 있다.
- 미확인: 두 정책이 이 구성의 refresh에 충분한지(예: IAM·DLM·RDS·ElastiCache 조회). 첫 plan에서 AccessDenied가 나오면 부족한 동작만 좁게 추가한다.
- 키는 90일 이내에 교체하고, 쓰지 않을 때는 비활성화한다.

### 1-3. **CI용 키**(`github-deploy-user`, Infra Actions Secrets)가 이 구성에서 필요로 하는 권한

현재 광범위하게 열려 있으므로 우선은 아래가 **포함돼 있는지** 확인한다. 권한 축소는 7번 항목.

| 용도 | 필요한 권한 |
|---|---|
| Terraform state와 잠금 | `dev/*`의 `s3:GetObject/PutObject/DeleteObject`(state와 `.tflock`), 버킷 `ListBucket` |
| **배포·apply 락**(새로 추가됨) | state 버킷의 `locks/dev/*`에 `s3:PutObject`(조건부 쓰기)·`GetObject`·`DeleteObject`, `locks/dev/` 접두사 `ListBucket`. **정책이 `dev/*`로 제한돼 있으면 `locks/`가 빠져 락 획득이 실패한다** |
| 배포 스크립트 업로드 | 앱 버킷 `deploy/scripts/*`에 `s3:PutObject` |
| SSM 배포 | `ssm:SendCommand`(문서 `AWS-RunShellScript`, 대상 인스턴스), `ssm:GetCommandInvocation`, `ssm:DescribeInstanceInformation` |
| **배포 기록**(새로 추가됨) | `ssm:PutParameter`, `ssm:GetParameter` on `arn:aws:ssm:ap-northeast-2:<계정>:parameter/voicebridge/dev/deployed/*`. 없으면 배포는 성공하되 기록 경고가 나오고 인스턴스 교체 후 복원(`redeploy`)이 되지 않는다 |
| Terraform 적용 | EC2, VPC, RDS, ElastiCache, S3, IAM(역할·인스턴스 프로파일·정책), DLM, EBS, EIP 관리 권한 |

- **apply 전에 확인할 권한 공백(미확인):** 현재 연결된 정책 7개([배포 설정 문서](DEPLOYMENT-SETUP.md))에는 **DLM(`dlm:*`) 권한이 보이지 않는다.** `AmazonEC2FullAccess`는 `ec2:*`이지 `dlm:*`이 아니다. 스냅샷 정책(`aws_dlm_lifecycle_policy`) 생성이 `AccessDenied`로 막히면 `3_application` apply가 인스턴스 생성 뒤 중간에 멈춘다. apply 전에 `dlm:*`(또는 `CreateLifecyclePolicy`, `GetLifecyclePolicy`, `UpdateLifecyclePolicy`, `DeleteLifecyclePolicy`, `TagResource`)을 허용하는 인라인 정책을 배포 사용자에 추가한다. `iam:PassRole`(DLM 역할)은 `IAMFullAccess`가 이미 포함한다.
- S3 조건부 쓰기(`--if-none-match`)는 비교적 최근 AWS CLI가 필요하다. 미확인: GitHub 러너의 CLI 버전에서 동작하는지(첫 실행에서 확인).

---

## 2. 호출 방식과 토큰

### 2-1. 지금 상태

| 보내는 쪽 | 방식 | 토큰 | 상태 |
|---|---|---|---|
| AI CI | `repository_dispatch`(`deploy-ai`) | `secrets.INFRA_DISPATCH_TOKEN` | 구현됨 |
| FE CI | `repository_dispatch`(`deploy-frontend`) | `secrets.INFRA_DISPATCH_TOKEN` | 구현됨 |
| BE CI | (없음) | | **미구현** |

- 두 CI 모두 토큰을 `secrets.`에서 읽는다. 운영자의 초기 설명에는 "Repository Variable에 저장"이라는 말이 있었지만 **그것이 사실인지는 확인되지 않았다**(현재 CI 코드는 Secret을 읽는다). **Variable 또는 코드·로그에 노출됐을 가능성이 조금이라도 있으면 즉시 Secret으로 옮기고 재발급한다.** 노출 여부를 확인하는 방법: 각 레포 Settings → Secrets and variables에서 이름이 Secrets에 있는지 Variables에 있는지 본다.
- Infra 쪽은 payload 값을 신뢰하지 않는다(형식 검증, 소스 레포 `main` 포함 확인, 이미지 경로는 Infra 변수로 조립). 그래도 **토큰이 곧 배포 권한**이다. 토큰이 유출되면 공격자는 "소스 레포 main에 있는 커밋"을 임의로 재배포하게 만들 수 있다.

### 2-2. 선택지

| | `repository_dispatch`(현재) | `workflow_dispatch` API |
|---|---|---|
| fine-grained 토큰 권한 | **`Contents: write`** (Infra 레포) | **`Actions: write`** (Infra 레포) |
| 토큰이 유출되면 | 이벤트 발송뿐 아니라 **Infra 레포에 코드 푸시**까지 가능(`main`이 보호되지 않았다면) → 그 코드가 AWS 키로 실행될 수 있다 | 코드 푸시는 불가능. 다만 **Infra의 다른 수동 워크플로도 실행할 수 있다**: `ssm-deploy`(임의 SHA 배포), `terraform-plan`, **`terraform-apply`** |
| 입력 | `client_payload`(자유 JSON) | 워크플로 입력(타입·필수 여부 선언) |
| 받는 쪽 | `repository_dispatch` 워크플로(기본 브랜치) | 대상 워크플로를 `workflow_dispatch`로 선언 |
| 현재 구현 | AI·FE 송신 코드와 Infra 수신 워크플로가 이미 이 방식이다 | 송신 CI 3곳, 수신 워크플로, 토큰 권한, 문서를 **함께** 바꿔야 한다 |

핵심 사실:

- `workflow_dispatch`는 코드 쓰기 권한이 필요 없어서 **"코드를 못 올린다"는 이유만으로 안전하다고 결론 내리면 안 된다.** 토큰 하나로 apply 워크플로까지 실행할 수 있기 때문이다.
- 그런데 이 구성의 `terraform-apply.yml`은 **`main`에서만, 수동으로, 저장된 plan 파일만, 삭제·교체는 `allow_destroy`가 있어야** 적용된다. 이는 어느 정도의 안전 장치지만 **사람의 승인 게이트는 아니다.** 토큰 보유자가 plan 실행 ID를 알면 apply를 돌릴 수 있다(plan 아티팩트가 있는 한).
- Private 저장소에서 GitHub Environment의 **Required reviewers**가 요금제상 가능한지는 **미확인**이다(문서 사이트가 이 세션에서 차단됨). 설정 화면(Settings → Environments)에서 선택이 되는지로 확인한다. 운영자 결정으로 이번에는 승인 게이트를 두지 않았고 PR 승인과 수동 실행이 확인 절차다.

### 2-3. 추천 (결정은 운영자)

1. **지금은 `repository_dispatch`를 유지한다**(AI·FE가 이미 구현했고 BE만 추가하면 된다). 단 토큰은 **레포마다 따로 발급한 fine-grained 토큰**으로, 대상은 **Infra 레포 하나**로만 제한하고 **Secret**으로 둔다. 레포별로 따로 발급하면 하나가 유출돼도 그 토큰만 폐기하면 된다.
2. Infra `main` 브랜치 보호(PR 필수)가 가능하면 켠다. 가능 여부는 요금제에 따라 미확인이다. 불가능하면 `Contents: write` 토큰의 위험이 커지므로 아래 3번을 앞당긴다.
3. **`workflow_dispatch`로 전환**하려면: ① 송신 CI의 `curl` 대상을 `POST /repos/42VoiceBridge/42VoiceBridge_Infra/actions/workflows/<파일>/dispatches`로, 본문을 `{"ref":"main","inputs":{...}}`로 바꾼다 ② 수신 워크플로를 `workflow_dispatch` 입력(`sha` 등)으로 바꾼다 ③ 토큰 권한을 `Actions: write`로 바꾼다 ④ **apply 워크플로를 보호**한다(Environment 승인이 가능하면 그것, 아니면 apply를 CI에서 빼고 운영자가 직접 실행) ⑤ 이 문서와 [CI/CD 흐름](CICD-FLOW.md), 오프라인 테스트를 갱신한다.
4. 어떤 방식이든: 토큰 만료일을 짧게(90일 이하) 정하고 교체 일정을 둔다. GitHub App으로 바꾸면 토큰 수명이 짧아지고 권한도 세분된다(작업량이 늘어난다).

### 2-4. 확인 체크리스트

- [ ] 각 소스 레포(BE·AI·FE)의 `INFRA_DISPATCH_TOKEN`이 Secrets에 있고 Variables에는 **없다**
- [ ] 토큰이 Infra 레포 하나로 제한돼 있다(fine-grained), 권한이 최소다
- [ ] 소스 레포의 이벤트 전송 단계가 **`main` 푸시에서만** 실행된다(공개 레포의 PR·포크에서는 토큰을 쓰지 않는다. AI·FE CI는 이미 그렇게 되어 있다)
- [ ] 노출 가능성이 있었다면 재발급했다
- [ ] BE CI에 `deploy-backend` 이벤트 전송이 추가됐다(`ref=refs/heads/main`, 40자 `sha`)

---

## 3. BE 레포

- [x] CI 성공·이미지 게시 후 `deploy-backend` 이벤트 전송: **BE `develop`에 구현됨**(PR #48, `ref`와 40자 `sha` 전송). 토큰은 `secrets.INFRA_DISPATCH_TOKEN`. Infra PR이 `main`에 머지돼야 실제로 배포가 실행된다. 송신 단계 주석의 "cd-preflight" 설명은 이제 `deploy-backend.yml`이 받으므로 갱신 필요
- [ ] **카카오 서버 설정:** BE가 인가 코드를 서버에서 교환하므로 앱 시크릿에 `KAKAO_CLIENT_ID`, `KAKAO_CLIENT_SECRET`, `KAKAO_REDIRECT_URI`가 필요하다. 값은 FE 주소 확정 후 등록([환경변수 명세](ENVIRONMENT-VARIABLES.md#카카오-로그인과-aws-키))
- [ ] **RDS 초기 스키마/마이그레이션 방법.** `prod`는 `ddl-auto: validate`라 빈 DB에서는 앱이 뜨지 않는다. Flyway 같은 도구나 초기 SQL이 필요하다
- [ ] 헬스 엔드포인트(예: `/actuator/health`). 지금 Infra는 8080이 **어떤 HTTP 응답이든 하면** 성공으로 본다(4xx/5xx 포함). 헬스가 생기면 배포 검사를 200 확인으로 강화할 수 있다
- [ ] `AI_SERVER_BASE_URL`을 앱 시크릿에 `terraform output ai_base_url` 값으로 등록하는 절차 숙지
- [ ] AI 응답 실패(503, 콜드스타트) 처리

## 4. FE 레포

- [ ] **같은 출처 API 지원:** `API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:8080'`의 `||`를 `??`로 바꾸고 레포 Variables `VITE_API_URL`을 빈 값으로 둔다. 그러면 요청이 `/api/v1/...`(같은 출처)로 가고 Infra의 프록시가 BE로 넘긴다. 그렇지 않으면 호스트(EIP)가 바뀔 때마다 이미지를 다시 빌드해야 한다([네트워크·엣지 가이드](NETWORK-AND-EDGE.md#fe-레포에-요청할-변경-같은-출처-api))
- [ ] 카카오 로그인 허용 도메인 등록(아래 5번)

## 5. 도메인

- [ ] 도메인을 확보하면 DNS A 레코드를 `terraform output fe_public_ip`로 연결하고 `fe_domain`을 설정한 뒤 plan → apply → FE 재배포
- [ ] 카카오 개발자 콘솔에 FE의 정확한 https 출처를 등록(도메인이 없으면 EIP 공개 DNS 이름이 바뀔 때마다 재등록)
- [ ] 도메인 구입비는 AWS 크레딧 대상이 아닐 수 있다(미확인)

## 6. 이미지 다이제스트 고정

태그(`sha-<커밋>`)는 같은 이름으로 덮어쓸 수 있다. 소스 레포 CI의 단계 요약에는 이미 다이제스트가 기록된다(AI CI 확인). payload에 다이제스트를 싣고 Infra가 `이미지@sha256:...`로 pull하며 태그가 가리키는 다이제스트와 같은지 검증하면 덮어쓰기 위험이 줄어든다. 송신 CI 3곳과 배포 스크립트·테스트를 함께 바꿔야 한다.

## 7. 배포용 IAM 사용자 권한 축소

`github-deploy-user`에 광범위한 정책 7개가 연결돼 있다([ADR 0003](adr/0003-github-deploy-identity.md)). 이제 이벤트 한 번으로 배포가 실행되는 구조라 권한 축소의 우선순위가 올라갔다. 위 1-3의 표를 기준으로 필요한 동작만 남기고, 인프라 생성(apply)과 서비스 배포(SSM)를 서로 다른 사용자로 나누는 것도 검토한다.

## 8. 지표와 알람

- CloudWatch 에이전트로 메모리·디스크 지표 수집, CPU·메모리·디스크 알람, 스냅샷 생성 실패 알람([사양 확정 절차](OPERATIONS-SIZING.md))
- 지금은 `measure` 모드로 수동 수집만 가능하다

## 이번 작업에서 의도적으로 하지 않은 것

- Environment 승인 게이트(운영자 결정: PR 승인과 수동 실행으로 대신)
- 호출 방식 변경, AWS 키 발급·교체(이 문서로 이관)
- 내부 DNS(Route 53), ALB, 다중 AZ
- 컨테이너 메모리·CPU 상한(실측 후)

# ADR 0006: FE·BE·AI를 개별 인스턴스로 분리

- 날짜: 2026-10-03
- 상태: Accepted
- 대체: [ADR 0005](0005-ai-serving-topology.md)(같은 EC2의 별도 컨테이너)
- 구현 상태: Terraform(`1_base` 보안그룹, `3_application` 인스턴스·IAM·볼륨·스냅샷), SSM 배포 스크립트, 레포별 배포 워크플로, 레이어별 plan/apply 워크플로와 오프라인 테스트까지 **코드로 구현**했다. **AWS에는 아직 적용하지 않았고 `plan`도 실행하지 못했다**(AWS 자격 증명 대기). 첫 배포에서 확인할 항목은 [인프라 검증 가이드](../INFRA-VERIFICATION.md)에 있다.

## 배경

[ADR 0005](0005-ai-serving-topology.md)는 AI를 BE와 같은 EC2의 별도 컨테이너로 두기로 했다. 이후 운영자가 FE·BE·AI를 같은 VPC의 **개별 인스턴스**로 운영하기로 정했고, 각 레포의 CI가 이미지를 게시한 뒤 Infra 레포의 워크플로를 호출해 해당 인스턴스의 이미지만 교체하는 흐름을 확정했다. 운영자는 AWS 크레딧(약 $100) 안에서 짧게 켜서 테스트한다.

확인된 사실(각 레포를 읽어 확인, 2026-10-03):

| | 포트 | 이미지 | 특이사항 |
|---|---|---|---|
| FE | nginx 80 | `<FE_IMAGE_REPOSITORY>:sha-<40자>` | API 경로는 `/api/v1/**`. `VITE_API_URL`은 **빌드 시점에 번들에 고정**된다. 마이크(`getUserMedia`)를 쓰므로 HTTPS가 필요하다. |
| BE | 8080 | `ghcr.io/42voicebridge/42voicebridge_be:sha-<40자>` | 헬스 엔드포인트가 없고, `prod`는 `ddl-auto: validate`라 빈 DB에서는 뜨지 않는다. CORS는 `*`. |
| AI | 8000 | `ghcr.io/42voicebridge/42voicebridge_ai:sha-<40자>` | 인증이 없다. 모델 적재 후에 포트를 연다. 상태 데이터 `/data`가 필요하다([ADR 0005](0005-ai-serving-topology.md)). |

## 결정

1. **FE·BE·AI를 퍼블릭 서브넷의 개별 EC2에 둔다.** 프라이빗 서브넷에는 NAT가 없어 GHCR pull, Hugging Face 다운로드, SSM 연결이 불가능하므로 세 인스턴스 모두 퍼블릭 서브넷이다. 인바운드는 보안그룹으로 통제한다.
2. **트래픽은 한 방향으로만 흐른다:** 인터넷 → `fe-sg`(80/443) → `be-sg`(8080) → `ai-sg`(8000), `be-sg` → `rds-sg`(3306)/`redis-sg`(6379). BE와 AI는 인터넷에 직접 공개하지 않는다. AI는 인증이 없으므로 `ai-sg`가 유일한 접근 통제다.
3. **고정 사설 IP:** BE `10.0.1.10`, AI `10.0.1.20`, FE `10.0.1.30`. 인스턴스를 교체해도 FE 프록시 목적지(`http://10.0.1.10:8080`)와 `AI_SERVER_BASE_URL`(`http://10.0.1.20:8000`)이 바뀌지 않는다. 내부 DNS(Route 53)는 부품이 늘어 보류한다.
4. **포트 계약:** BE 호스트 8080 = 컨테이너 8080, AI 호스트 8000 = 컨테이너 8000. 예전의 호스트 `80 → 8080` 매핑은 폐기한다. 보안그룹이 호스트 포트 기준이므로 스크립트와 SG의 값이 일치해야 한다(Terraform 테스트와 스크립트 테스트가 각각 검증한다).
5. **FE는 공개 엣지다.** FE 인스턴스에 Elastic IP를 붙이고 **Caddy**가 80/443을 받아 Let's Encrypt 인증서를 자동 발급·갱신한다. `/api/*`는 경로를 바꾸지 않고 BE 사설 IP로 프록시하고 나머지는 FE(nginx) 컨테이너로 보낸다. 같은 출처이므로 CORS와 http/https 혼합 콘텐츠 문제가 없고 BE를 공개하지 않아도 된다. 도메인이 없으면 **EIP의 공개 DNS 이름**(`ec2-<ip>.ap-northeast-2.compute.amazonaws.com`)으로 발급하고, 도메인이 생기면 변수 `fe_domain` 하나만 바꾼다. 자세한 내용과 한계는 [네트워크·엣지 가이드](../NETWORK-AND-EDGE.md).
6. **최소 권한 IAM(역할 3개).** 세 역할 모두 SSM 등록, `deploy/scripts/*` `s3:GetObject`(배포 스크립트를 EC2가 S3에서 내려받아 실행한다), GHCR 시크릿 읽기가 필요하다. AI는 추가로 `ai/*`(프롬프트 풀)만 읽고, **BE만** 앱·RDS 시크릿과 버킷 읽기·쓰기를 갖는다. SSH 키와 22번 포트는 BE에만 둔다(AI·FE는 SSM으로만 접근, [ADR 0004](0004-ec2-access-method.md)).
7. **GHCR 자격 증명 분리:** 전용 시크릿 `voicebridge/dev/ghcr`(`GHCR_USERNAME`, `GHCR_READ_TOKEN`)를 세 역할이 읽는다. 값과 IAM을 동시에 바꾸지 않도록 BE만 전환 기간 동안 기존 앱 시크릿으로 폴백한다.
8. **AI 상태 데이터:** AI 인스턴스에만 별도 EBS(gp3 20 GiB, 암호화, `prevent_destroy`)를 `/data`에 마운트한다. `prevent_destroy`는 설정에 블록이 있을 때만 막으므로, **DLM 일일 스냅샷(7개 보존)**과 삭제 전 최종 스냅샷 절차를 함께 둔다([데이터 보호 가이드](../DATA-PROTECTION.md)).
9. **배포 파이프라인:** 각 레포 CI가 `deploy-backend`/`deploy-ai`/`deploy-frontend` 이벤트를 보내면 Infra의 해당 워크플로가 payload 형식 검증과 **소스 레포 `main` 포함 여부 확인** 후 해당 인스턴스에만 SSM으로 배포한다. 이미지 경로는 payload가 아니라 Infra 변수(`*_IMAGE_REPOSITORY`)와 SHA로만 조립한다. 흐름은 [CI/CD 흐름](../CICD-FLOW.md).
10. **apply와 배포의 충돌 방지:** S3 조건부 쓰기 락으로 Terraform apply와 서비스 배포가 겹치지 않게 하고, 성공한 배포를 SSM Parameter Store에 기록해 인스턴스 교체 후 마지막 배포로 복원한다.
11. **레이어별 순차 apply:** 하위 레이어 state가 없는 첫 배포에서는 한 번에 전체 plan이 불가능하다(실제로 `Unable to find remote state`로 실패하는 것을 재현). 그래서 `1_base → 2_storage → 3_application`을 레이어마다 plan → 검토 → 저장된 plan apply로 진행하고, 상위 레이어는 하위 레이어 적용 전에는 거부한다. 잠금은 유지한다(`-lock=false` 금지).

## 근거

- **장애 격리:** CPU 학습(17.6분 이상)과 추론이 BE와 같은 호스트의 CPU·메모리를 두고 경쟁하지 않는다. AI 메모리 상한을 실측 없이 걸 필요도 없다.
- **독립 배포:** 세 컴포넌트를 각자 교체·복원할 수 있고, 한 컴포넌트의 실패가 다른 컴포넌트 인스턴스를 건드리지 않는다.
- **최소 권한:** AI·FE 인스턴스가 BE의 JWT·DB 값이나 녹음 데이터를 읽지 못한다.

## 트레이드오프

- **비용 증가(추정):** 인스턴스 3대와 공인 IPv4 주소가 늘어난다. 기존 가이드의 시간당 약 $0.61에 AI `m5.xlarge`와 FE `t3.small`을 더하면 약 $0.9/시간으로 추정하지만 **요금 계산기로 검증한 값이 아니다.** $100 크레딧은 상시 가동 기준 며칠 분량일 수 있어 켜는 시간을 제한해야 한다.
- **부품 증가:** 보안그룹, IAM 역할, 엣지(Caddy), 락, 배포 기록이 늘어난다. 모두 오프라인 테스트로 동작을 검증했지만 실제 AWS에서의 동작은 첫 배포에서 확인해야 한다.
- **도메인 없는 HTTPS는 한계가 있다:** EIP 공개 DNS 이름은 EIP를 다시 만들면 바뀌고, 카카오 로그인은 허용 도메인(Redirect/웹 도메인) 등록이 필요해 이름이 바뀌면 재등록해야 한다. 안정적인 운영에는 도메인이 필요하다.
- **퍼블릭 서브넷의 AI:** AI에 공인 IP가 붙는다(아웃바운드용). 인바운드는 `ai-sg`가 BE에서만 허용한다.
- **AMI 변경은 무시한다(`ignore_changes = [ami]`).** `most_recent` AMI는 새 이미지가 나올 때마다 세 인스턴스의 교체를 계획하는데, 교체는 재배포와 데이터 영향이 있어 의도했을 때만 하도록 했다. 대신 새 AMI 반영은 수동이며 부팅 시 `dnf update`로 패치한다.
- **고정 사설 IP는 단일 AZ·단일 서브넷 전제**다. 다중 AZ가 필요해지면 내부 DNS나 로드 밸런서를 검토한다.

## 사양과 사실의 취급

- 인스턴스 사양(BE `m5.large`, AI `m5.xlarge`, FE `t3.small`)은 **초기 시험 사양**이다. AI 메모리 실측은 추론 3건 기준(대기 517 MiB, 3건 후 1.67 GiB)뿐이고 학습 중 메모리는 측정된 적이 없다. 배포 후 측정으로 확정한다([사양 확정 절차](../OPERATIONS-SIZING.md)).
- 비용 수치는 모두 추정이다.

## 재검토 조건

1. 실측 결과 AI가 `m5.xlarge`로 부족하거나 남으면 사양을 조정한다.
2. 도메인을 확보하면 `fe_domain`을 설정하고 카카오 등록 도메인을 갱신한다.
3. 다중 AZ나 무중단 배포가 필요해지면 ALB와 내부 DNS를 검토한다.
4. 호출 방식(`repository_dispatch` 대 `workflow_dispatch`)과 배포용 AWS 키 권한 축소는 [후속 작업](../FOLLOW-UPS.md)에서 다룬다.

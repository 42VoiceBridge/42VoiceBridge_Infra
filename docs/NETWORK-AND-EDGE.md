# 네트워크·주소·HTTPS(엣지) 가이드

[ADR 0006](adr/0006-three-instance-topology.md)의 네트워크 계약을 한 곳에 모았다. 2026-10-03 기준으로 코드와 오프라인 테스트까지 구현했고 **AWS에는 적용하지 않았다.** "첫 배포에서 확인"이라고 적은 항목은 이 세션에서 직접 검증하지 못한 것이다.

## 주소와 포트 계약

세 인스턴스는 모두 퍼블릭 서브넷(`10.0.1.0/24`)에 있다. 프라이빗 서브넷에는 NAT가 없어 이미지 pull, 모델 다운로드, SSM 연결이 불가능하기 때문이다.

| 컴포넌트 | 사설 IP(고정) | 공인 주소 | 호스트 포트 → 컨테이너 | 누가 접근하나 |
|---|---|---|---|---|
| FE (nginx + Caddy 엣지) | `10.0.1.30` | **Elastic IP** | 엣지 80, 443 (FE nginx는 포트를 게시하지 않음) | 인터넷 |
| BE | `10.0.1.10` | 자동 공인 IP(아웃바운드용, 고정 아님) | **8080 → 8080** | `fe-sg`만 |
| AI | `10.0.1.20` | 자동 공인 IP(아웃바운드용, 고정 아님) | **8000 → 8000** | `be-sg`만 |
| RDS MySQL | (엔드포인트) | 없음 | 3306 | `be-sg`만 |
| ElastiCache Redis | (엔드포인트) | 없음 | 6379 | `be-sg`만 |

- 사설 IP는 변수 `be_private_ip`, `ai_private_ip`, `fe_private_ip`(`3_application`)로 정한다. 서브넷 안의 `.4`~`.254`만 허용하고 서로 겹치면 plan에서 거부한다(AWS 예약 주소 `.0`~`.3`, `.255` 제외).
- **포트는 호스트 기준이다.** 보안그룹은 호스트에 도달하는 포트를 보므로 `deploy-ec2.sh`의 `--publish`와 SG 규칙이 일치해야 한다. 예전 BE 매핑(호스트 `80 → 컨테이너 8080`)은 폐기했고 `8080 → 8080`으로 통일했다. 불일치를 막기 위해 Terraform 테스트(`1_base/tests`, `3_application/tests`)와 스크립트 테스트가 각각 같은 값을 검사한다.
- **BE가 AI를 부르는 주소:** `AI_SERVER_BASE_URL=http://10.0.1.20:8000`. `terraform output ai_base_url`로 값을 확인해 앱 시크릿 `voicebridge/dev/app`에 등록한다. BE는 시작 시점에만 읽으므로 변경 후 BE를 다시 배포한다.
- **FE가 BE를 부르는 주소:** `terraform output be_upstream`(`http://10.0.1.10:8080`). 배포 스크립트가 Caddyfile에 넣는다.

## 보안그룹 허용 관계

```
인터넷 ──80/443──▶ fe-sg ──8080──▶ be-sg ──8000──▶ ai-sg
                                      ├──3306──▶ rds-sg
                                      └──6379──▶ redis-sg
```

| 대상 | 포트 | 허용 출처 | 비고 |
|---|---|---|---|
| `fe-sg` | 80, 443 | 0.0.0.0/0 | 80은 Let's Encrypt HTTP-01 검증과 https 리다이렉트에 필요 |
| `be-sg` | 8080 | `fe-sg` | BE를 인터넷에 직접 공개하지 않는다 |
| `be-sg` | 22 | 지정한 CIDR(`ssh_allowed_cidr`) | SSM 검증 전까지 BE에만 유지([ADR 0004](adr/0004-ec2-access-method.md)) |
| `ai-sg` | 8000 | `be-sg` | **AI는 인증이 없어 이 규칙이 유일한 접근 통제다.** SSH 없음 |
| `rds-sg` | 3306 | `be-sg` | |
| `redis-sg` | 6379 | `be-sg` | |

모든 보안그룹의 아웃바운드는 전체 허용이다(GHCR, Hugging Face, Let's Encrypt, SSM 엔드포인트 접근).

BE에 직접 접속해 보고 싶다면 인터넷에서는 불가능하다. SSM Session Manager 포트 포워딩이나 FE 인스턴스를 경유한다.

## FE 엣지와 HTTPS

브라우저가 마이크(`getUserMedia`)를 쓰려면 HTTPS가 필요하다. FE 인스턴스에 Caddy 컨테이너(`voicebridge-edge`)를 두고 다음처럼 동작시킨다.

```
브라우저 ──https──▶ Caddy(:443, 80) ──/api/*──▶ http://10.0.1.10:8080 (BE, 경로 그대로)
                                      └─ 그 외 ─▶ voicebridge-fe:80 (nginx, SPA)
```

- 사이트 주소가 **호스트 이름**이면 Caddy가 Let's Encrypt 인증서를 자동으로 발급하고 갱신하며 http를 https로 리다이렉트한다. 갱신도 자동이라 별도 cron이 필요 없다. 인증서는 Docker 명명된 볼륨(`voicebridge-caddy-data`)에 보관해 컨테이너를 교체해도 유지된다.
- **같은 출처:** 브라우저는 FE 하나의 https 출처만 호출하므로 CORS와 http/https 혼합 콘텐츠 문제가 없다. BE의 CORS 설정(`*`)은 필요 없어진다.
- `/api/*`는 **경로 접두사를 제거하지 않는다.** BE가 `/api/v1/**`를 서비스하고 FE가 `/api/v1/...`를 호출하기 때문이다.
- 엣지 배포는 FE 컨테이너를 먼저 교체(실패 시 롤백)하고, Caddy는 약 20초 동안 계속 실행 중인지 확인한다. 이후 `https://<호스트>/`가 신뢰되는 인증서로 200을 반환하는지 최대 180초 확인한다. **HTTPS가 확인되지 않아도 롤백하지 않고 경고로 남긴다**(도메인·DNS·방화벽 같은 외부 요소 때문일 수 있고 앱 자체는 정상이기 때문). 경고가 나오면 FE 인스턴스에서 `docker logs voicebridge-edge`를 확인한다.

### 도메인이 없을 때 (현재 상태)

AWS가 도메인을 주지는 않는다. 대신 Elastic IP에는 **공개 DNS 이름**이 자동으로 붙는다.

```
ec2-203-0-113-10.ap-northeast-2.compute.amazonaws.com    ← EIP 203.0.113.10의 예
```

- `fe_domain`이 비어 있으면 Terraform이 `fe_public_host`를 이 이름으로 내보내고(`terraform output fe_public_host`) 배포 스크립트가 이 이름으로 인증서를 발급받는다. 구입한 도메인 없이 HTTPS를 쓸 수 있다.
- **확인 필요(첫 배포):** Let's Encrypt가 이 이름으로 인증서를 발급해 주는지는 이 세션에서 직접 검증하지 못했다. 일반적으로 사용되는 방식이지만 실패하면 `docker logs voicebridge-edge`에 사유가 남고 배포 로그에 "HTTPS ... was not verified" 경고가 나온다.
- **한계:**
  - EIP를 새로 만들면(예: FE 인스턴스 또는 EIP 리소스를 destroy 후 재생성) **주소가 바뀐다.** 새 이름으로 인증서를 다시 발급받고 FE 이미지의 API 주소와 카카오 설정도 맞춰야 한다. Terraform에서 EIP를 지우지 않는 한 유지된다.
  - Let's Encrypt는 같은 이름의 중복 발급 횟수에 한도가 있다. 반복해서 destroy/apply하며 시험하면 한도에 걸릴 수 있다.
  - 이 주소는 사람이 외우기 어렵다.
- **도메인이 생기면:** ① DNS의 A 레코드를 `terraform output fe_public_ip` 값으로 연결 ② `3_application`의 변수 `fe_domain`을 설정(예: `app.example.com`) ③ plan 검토 후 apply ④ FE 재배포(엣지가 새 호스트로 다시 발급). 코드 변경은 필요 없다.

## FE 레포에 요청할 변경 (같은 출처 API)

FE 레포(`src/api/*.ts`)는 `API_BASE_URL = import.meta.env.VITE_API_URL || 'http://localhost:8080'`를 쓰고 `VITE_API_URL`은 **이미지 빌드 시점에 번들에 고정**된다. 같은 출처 프록시 구조에서는 API 주소가 비어 있어야(상대 경로) 호스트가 바뀌어도 같은 이미지를 쓸 수 있는데, 지금 코드는 빈 값을 `localhost:8080`으로 되돌린다.

두 가지 중 하나를 FE 팀이 선택해야 한다.

| 방식 | FE 쪽 변경 | 장단점 |
|---|---|---|
| **A. 같은 출처(추천)** | `||`를 `??`로 바꿔 `VITE_API_URL`이 빈 문자열이면 그대로 쓰고, FE 레포 Variables `VITE_API_URL`을 빈 값으로 둔다(요청 경로는 `/api/v1/...`). | 호스트가 바뀌어도 이미지를 다시 빌드하지 않는다. Infra의 프록시 구조와 맞는다. |
| B. 절대 주소 | `VITE_API_URL`을 최종 https 주소(예: `https://ec2-....compute.amazonaws.com`)로 두고 빌드. | 코드 변경은 없지만 **호스트(EIP)가 바뀔 때마다 FE 이미지를 다시 빌드·배포**해야 한다. |

둘 다 FE 레포에서 하는 일이며 Infra 코드는 어느 쪽이든 동작한다(방식 B에서는 프록시가 `/api/*`를 받아 BE로 넘기는 기능을 쓰지 않을 뿐이다).

## 카카오 로그인

FE는 카카오 JavaScript 키(`VITE_KAKAO_JAVASCRIPT_KEY`)로 로그인한다. 카카오 개발자 콘솔은 **허용된 웹 도메인/리다이렉트 URI**만 받으므로 FE가 서비스되는 정확한 https 출처를 등록해야 한다. 도메인 없는 EIP 공개 DNS 이름을 쓰면 EIP가 바뀔 때마다 재등록이 필요하다. 이 설정은 카카오 콘솔에서 하는 일이라 이 레포의 코드나 문서로는 대신할 수 없다. 안정적인 로그인에는 도메인이 필요하다.

## 이 구조에서 확인하는 방법

배포 후 확인 명령은 [인프라 검증 가이드](INFRA-VERIFICATION.md)에 있다.

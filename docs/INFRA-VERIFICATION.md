# 인프라 검증 가이드 (다른 인프라 담당자용)

[PR #10](https://github.com/42VoiceBridge/42VoiceBridge_Infra/pull/10)의 인스턴스 분리 구성을 **다른 사람이 직접 확인**할 수 있도록 정리했다. 순서는 ① 무엇이 검증됐고 무엇이 아닌지 → ② 오프라인 검증 재현 → ③ 코드 리뷰 포인트 → ④ plan 검토 → ⑤ apply 후 확인 → ⑥ 증거 기록이다. 결정과 배경은 [ADR 0006](adr/0006-three-instance-topology.md).

## 1. 검증 상태: 무엇이 확인됐고 무엇이 아닌가

| 구분 | 상태 | 근거 |
|---|---|---|
| Terraform 문법·구성(`1_base`, `2_storage`, `3_application`) | **확인됨** | `terraform fmt`, `validate` |
| 보안그룹 접근 체인, 인스턴스 사양·고정 IP·SSH 키, 역할별 IAM 정책 내용, 볼륨·스냅샷 정책, 출력 주소, 변수 검증 | **확인됨(mock)** | `terraform test`(mock 프로바이더) 20개. 위험하게 바꾼 변형으로 실제로 실패를 잡는지도 확인 |
| 배포 스크립트 동작(롤백, 마운트 거부, 포트, GHCR 폴백, 엣지 설정, 입력 삽입 방지) | **확인됨(스텁)** | docker/aws를 스텁으로 대체한 테스트 105개 |
| `run.sh` 흐름(인스턴스별 대상, 순서, 실패 시 중단, 기록·복원) | **확인됨(스텁)** | 테스트 57개 |
| 이벤트 검증·출처 검증·락(경쟁 포함)·레이어별 plan/apply·워크플로 구조 | **확인됨(스텁/YAML)** | 테스트 28 + 29 + 47 + 46개 |
| `terraform plan`이 실제 AWS에서 의도한 리소스를 만드는지 | **미확인** | AWS 자격 증명 대기 |
| 실제 EC2에서 user_data(볼륨 포맷·마운트), 배포, TLS 발급 | **미확인** | AWS에 적용하지 않음 |
| 실제 GHCR pull(PAT 권한), Hugging Face 다운로드 시간 | **미확인** | |
| Let's Encrypt가 EIP 공개 DNS 이름으로 인증서를 발급하는지 | **미확인** | 첫 배포에서 확인([네트워크·엣지 가이드](NETWORK-AND-EDGE.md)) |
| GitHub Actions에서의 실제 실행(재사용 워크플로, 아티팩트 다운로드, `--if-none-match` 락) | **미확인** | 워크플로를 실행한 적이 없다. `infra-tests`(오프라인)만 GitHub에서 실행된다 |

스텁 테스트는 스크립트 논리를 검증할 뿐 실제 Docker/AWS의 동작을 대신하지 않는다. 아래 4~5단계가 그 간극을 메운다.

## 2. 오프라인 검증 재현 (AWS 자격 증명 불필요)

저장소 루트에서 다음을 실행한다. CI의 [`infra-tests`](../.github/workflows/infra-tests.yml)가 같은 검사를 PR마다 수행한다.

```bash
shellcheck -x scripts/ssm/*.sh scripts/ssm/test/*.sh scripts/ci/*.sh scripts/ci/test/*.sh \
  infra/environments/dev/3_application/tests/*.sh
for t in scripts/ssm/test/deploy-ec2.test.sh scripts/ssm/test/run.test.sh \
         scripts/ci/test/validate-and-verify.test.sh scripts/ci/test/infra-lock.test.sh \
         scripts/ci/test/tf-layer.test.sh scripts/ci/test/workflows.test.sh \
         infra/environments/dev/3_application/tests/user_data_mount.test.sh; do
  echo "== $t"; bash "$t" | tail -1
done
terraform fmt -check -recursive infra/environments/dev
for l in 1_base 2_storage 3_application; do
  (cd infra/environments/dev/$l && terraform init -backend=false -lockfile=readonly -input=false \
    && terraform validate && { [ -d tests ] && terraform test; })
done
```

모든 테스트 파일은 마지막 줄에 `통과 N, 실패 0`을 출력해야 한다. **테스트가 실제로 문제를 잡는지** 직접 확인하려면 규칙을 일부러 깨뜨려 본다. 예: `1_base/security_group.tf`에서 `ai-sg`의 `security_groups = [aws_security_group.be.id]`를 `cidr_blocks = ["0.0.0.0/0"]`로 바꾸고 `terraform test`를 실행하면 `AI는_BE에서만_8000을_받고_SSH가_없다`가 실패해야 한다(확인 후 되돌린다).

## 3. 코드 리뷰 포인트

| 파일 | 반드시 확인할 것 |
|---|---|
| `1_base/security_group.tf` | **`ai-sg` 8000이 `be-sg`에서만 열려 있다**(AI는 인증이 없어 유일한 방어선). `be-sg` 8080은 `fe-sg`에서만. `rds-sg`·`redis-sg`는 `be-sg`에서만. `fe-sg`에만 인터넷(80/443). AI·FE에 22번 없음 |
| `3_application/iam.tf` | 세 역할 모두 `deploy/scripts/*` `s3:GetObject`와 GHCR 시크릿 읽기가 있다(빠지면 해당 인스턴스 배포가 첫 단계에서 실패). **AI는 `ai/*`만**, **BE만** 앱·RDS 시크릿과 버킷 쓰기 |
| `3_application/{be,ai,fe}.tf` | 고정 `private_ip`, 인스턴스별 SG와 프로파일, AI·FE에 `key_name` 없음, 데이터 볼륨은 AI에만 |
| `3_application/ai.tf` | `prevent_destroy`, 암호화, `Backup=ai-data` 태그, DLM 정책(7개 보존) |
| `scripts/ssm/deploy-ec2.sh` | `--publish`가 SG 계약과 일치(BE 8080:8080, AI 8000:8000), 이미지 형식 검사, FE의 호스트·업스트림 검증, AI의 `/data` 마운트 확인 |
| `scripts/ssm/run.sh` | 인스턴스 ID를 보내기 직전에 조회, AI → BE → FE 순서, 실패 시 중단 |
| `scripts/ci/*.sh`, `.github/workflows/*.yml` | `run:`에 `${{ }}` 직접 삽입 없음, apply는 `main`·수동 전용·저장된 plan만, 락 해제는 획득한 경우에만, `-lock=false`·`-auto-approve` 없음 |

체크포인트:
- [ ] 보안그룹 체인이 위 표와 같은가
- [ ] 역할별 IAM이 최소 권한인가(아래 5단계의 음성 테스트로 실제 확인)
- [ ] 시크릿 값, 토큰, 키가 코드·문서·테스트에 없는가(`git grep -i -E 'AKIA|ghp_|secret_access'`)
- [ ] 문서의 수치(비용·사양)가 "추정"으로 표기되어 있는가

## 4. plan 검토 (적용 전)

레이어마다 **Terraform plan (one layer)** 워크플로를 실행하고 요약과 `tfplan-<레이어>` 아티팩트를 검토한다([CI/CD 흐름](CICD-FLOW.md#초기-인프라-프로비저닝-레이어별로-순서대로)). 하위 레이어를 apply하기 전에는 상위 레이어를 plan할 수 없다.

### 기대 리소스(코드의 `resource` 블록 기준 예상, plan과 대조)

| 레이어 | 개수 | 내용 |
|---|---|---|
| `1_base` | 12 | VPC, IGW, 서브넷 3(퍼블릭 1 + 프라이빗 2), 라우팅 테이블 + 연결, 보안그룹 5(`fe`, `be`, `ai`, `rds`, `redis`) |
| `2_storage` | 8 | RDS(서브넷 그룹 포함), ElastiCache(서브넷 그룹 포함), S3 버킷 + 퍼블릭 차단 + 버저닝, `random_id` |
| `3_application` | **24** | EC2 3(`be`, `ai`, `fe`), EBS 볼륨 1 + attachment 1, EIP 1 + association 1, IAM 역할 4(노드 3 + DLM 1), 인스턴스 프로파일 3, 정책 연결 4(SSM 3 + DLM 1), 인라인 정책 5(공통 3 + BE + AI), DLM 정책 1 |

위 개수는 코드에서 센 **예상치**이고 실제 plan의 `Plan: N to add`와 대조해야 한다. 다르면 이유를 확인한다.

### 위험 신호 (하나라도 있으면 중단하고 확인)

- [ ] plan에 **destroy 또는 replace**가 있다 → 요약에 대상이 나열된다. 첫 배포에서는 0이어야 한다. 이미 인스턴스가 있었다면 의도한 교체인지 확인하고, 데이터 볼륨의 수동 스냅샷을 먼저 만든다
- [ ] plan 아티팩트(`tfplan`)에는 plan이 다루는 값이 그대로 들어 있다(바이너리, 암호화되지 않음). 현재 구성에는 비밀값이 없다(RDS 비밀번호는 AWS가 관리). 비밀값을 다루는 리소스를 추가했다면 아티팩트 보존 기간(7일)과 접근 범위를 다시 검토한다. 파괴 감지용 JSON 플랜은 아티팩트에 남기지 않는다
- [ ] `aws_security_group.ai` 인바운드가 `cidr_blocks`를 가진다 / `be`가 0.0.0.0/0을 연다
- [ ] 인스턴스 `key_name`이 AI·FE에 설정돼 있다
- [ ] 인스턴스에 `ignore_changes = [ami]`가 있다(새 AMI가 나와도 교체가 계획되지 않는다. AMI를 올리려면 의도적으로 제거하거나 `-replace`를 쓴다)
- [ ] `aws_ebs_volume.data`가 암호화돼 있지 않거나 크기가 20이 아니다, `Backup` 태그가 없다
- [ ] IAM 정책의 `Resource`가 `*`이다(이 구성에는 없어야 한다)
- [ ] `1_base` plan 입력의 `ssh_allowed_cidr`가 `0.0.0.0/0`이다(워크플로가 거부한다)

## 5. apply 후 확인 (실제 AWS)

레이어를 하나씩 적용한 뒤 확인한다. `3_application` apply 직후에는 워크플로가 자동으로 `check`(SSM, Docker, AI `/data` 마운트)를 실행한다.

### 5-1. 인스턴스·주소

```bash
cd infra/environments/dev/3_application
terraform output   # be/ai/fe_instance_id, be/ai_private_ip, be_upstream, ai_base_url, fe_public_ip, fe_public_host
```

- [ ] 사설 IP가 `10.0.1.10`(BE), `10.0.1.20`(AI), `10.0.1.30`(FE)이다
- [ ] Infra Actions → SSM deploy (manual) → `check`가 세 인스턴스 모두 통과한다

### 5-2. 네트워크 경로 (양성 + **음성** 테스트)

SSM 세션 또는 `aws ssm send-command`로 인스턴스 안에서 실행한다.

| 어디서 | 명령 | 기대 |
|---|---|---|
| BE 인스턴스 | `curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.0.1.20:8000/v1/health` | **200** (BE → AI) |
| **FE 인스턴스** | `curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.0.1.20:8000/v1/health` | **타임아웃(000)** — FE는 `be-sg`가 아니므로 막혀야 한다 |
| FE 인스턴스 | `curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.0.1.10:8080/` | HTTP 응답(401/403/404 등, 000이 아님) (FE → BE) |
| 운영자 PC(인터넷) | `curl --max-time 5 http://<BE 공인 IP>:8080/` 및 `http://<AI 공인 IP>:8000/` | **타임아웃** — BE·AI는 인터넷에 공개되지 않는다 |
| 운영자 PC(인터넷) | `curl -I https://<fe_public_host>/` | 200과 유효한 인증서 |
| BE 인스턴스 | RDS·Redis 엔드포인트에 접속 | 성공(BE → RDS/Redis). FE·AI에서는 실패해야 한다 |

### 5-3. IAM 음성 테스트 (최소 권한이 실제로 지켜지는가)

각 인스턴스에서(`BUCKET`은 `terraform -chdir=../2_storage output -raw s3_bucket_name`):

| 어디서 | 명령 | 기대 |
|---|---|---|
| AI, FE, BE | `aws s3 cp s3://$BUCKET/deploy/scripts/<해시>.sh -` | 성공(배포 스크립트 다운로드) |
| AI | `aws s3 ls s3://$BUCKET/` 또는 녹음 객체 읽기 | **AccessDenied** (`ai/*`만 허용) |
| AI | `aws s3 ls s3://$BUCKET/ai/` | 성공 |
| AI, FE | `aws secretsmanager get-secret-value --secret-id voicebridge/dev/app` | **AccessDenied** |
| 모든 인스턴스 | GHCR 시크릿 읽기 가능 여부는 **값을 출력하지 않고** 확인한다: 해당 컴포넌트의 이미지 배포(pull)가 성공하면 읽을 수 있는 것이다 | 배포 성공 |
| BE | 앱·RDS 시크릿 읽기 가능 여부도 BE 배포 성공으로 확인한다 | 배포 성공 |

> `get-secret-value`는 성공하면 시크릿 값을 출력한다. 그래서 **AccessDenied가 나와야 하는** AI·FE의 앱 시크릿 호출에만 쓴다. 만약 이 호출이 성공해 값이 출력되면 권한이 과다한 것이므로 즉시 중단하고 출력된 값이 로그·채팅에 남지 않았는지 확인한 뒤 보고한다. 읽을 수 있어야 하는 시크릿(GHCR, BE의 앱·RDS)은 값을 출력하지 말고 배포 성공 여부로 확인한다.

### 5-4. AI 데이터 볼륨

AI 인스턴스에서:

```bash
findmnt /data && df -h /data          # 별도 20 GiB 볼륨이 /data에 마운트
ls -ld /data/ai /data/ai/*            # 소유자 10001(컨테이너 사용자)
grep -c voicebridge /etc/fstab || grep /data /etc/fstab   # UUID로 등록
cat /var/log/voicebridge-data-volume.log
```

- [ ] 재부팅 후에도 `/data`가 자동 마운트되고 컨테이너가 올라온다
- [ ] 기존 데이터가 있는 볼륨은 재부팅·인스턴스 교체 후에도 **포맷되지 않는다**(`mkfs` 로그 없음)
- [ ] `aws ec2 describe-volumes`의 `DeleteOnTermination`이 `false`, DLM 정책 `ENABLED`, 첫 스냅샷 생성([데이터 보호 가이드](DATA-PROTECTION.md#적용-후-확인))

### 5-5. HTTPS와 FE 엣지

FE 인스턴스에서:

```bash
docker ps --format '{{.Names}} {{.Status}}'        # voicebridge-fe, voicebridge-edge
docker logs --tail 80 voicebridge-edge             # 인증서 발급/갱신 로그
HOST=$(terraform -chdir=infra/environments/dev/3_application output -raw fe_public_host)   # 운영자 PC에서 조회
echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -issuer -dates
```

- [ ] 발급자가 Let's Encrypt이고 유효 기간이 남아 있다
- [ ] **발급이 실패하면** 배포는 롤백되지 않고 "HTTPS ... was not verified" 경고가 나온다. 이름, DNS, 80번 포트 접근, 발급 한도를 확인한다
- [ ] http로 접속하면 https로 리다이렉트된다

### 5-6. 배포 파이프라인

- [ ] `ssm-deploy`의 `deploy`로 AI → BE → FE를 순서대로 배포하고 각 로그의 성공 메시지를 확인한다
- [ ] AI가 실패하도록(없는 SHA 등) 했을 때 BE·FE가 배포되지 않는다
- [ ] 실제 `deploy-ai`/`deploy-frontend` 이벤트로 워크플로가 실행되고(`main`에 머지된 뒤), 형식·출처 검증과 락 획득·해제 로그가 나온다
- [ ] `3_application`을 교체가 포함되도록 apply한 뒤 새 인스턴스가 마지막 성공 배포로 복원된다(`post-apply`)
- [ ] 같은 시각에 apply와 배포를 시작하면 배포가 대기하는지(락 로그) 확인한다
- [ ] 락이 남지 않았는지: `aws s3 ls s3://42voicebridge-tfstate/locks/dev/` 가 비어 있어야 한다

### 5-7. 사양 측정

[사양 확정 절차](OPERATIONS-SIZING.md)의 시나리오 A~F를 수행하고 결과를 기록한다.

## 6. 알려진 미검증·제한 (확인 후 지울 것)

- Let's Encrypt가 EIP 공개 DNS 이름으로 발급하는지, 발급 한도에 걸리는지
- `put-object --if-none-match`(S3 조건부 쓰기)를 쓰는 락이 GitHub 러너의 AWS CLI에서 동작하는지(필요 버전 확인)
- 배포용 IAM 사용자에 `locks/dev/*` 쓰기, SSM Parameter Store `/voicebridge/dev/deployed/*` 쓰기·읽기 권한이 있는지([후속 작업](FOLLOW-UPS.md))
- BE CI가 아직 `deploy-backend`를 보내지 않는다. BE의 RDS 초기 스키마 방법과 헬스 엔드포인트가 없다
- FE가 같은 출처 API(`VITE_API_URL` 빈 값)를 지원해야 한다([네트워크·엣지 가이드](NETWORK-AND-EDGE.md#fe-레포에-요청할-변경-같은-출처-api))
- 카카오 로그인에 등록된 도메인이 FE 주소와 일치해야 한다

## 7. 증거 기록

확인한 항목은 `deploy-step.md`의 진행 로그에 날짜, 확인자, 실행한 명령과 결과 요약(비밀값 제외), 해당 Actions 실행 링크를 남긴다. "확인됨"은 실제로 실행한 근거가 있을 때만 쓴다.

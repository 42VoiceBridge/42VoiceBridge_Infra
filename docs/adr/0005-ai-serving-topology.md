# ADR 0005: AI 추론 서버 배포 위치

- 날짜: 2026-10-03
- 상태: Accepted (같은 EC2, 별도 컨테이너). 메모리 실측 결과에 따라 재검토할 수 있다.
- 구현 상태: 코드 구현 완료(Terraform 데이터 볼륨, SSM 배포 스크립트의 AI 컴포넌트, 헬스체크, 오프라인 테스트). **AWS에는 아직 적용하지 않았다.** 같은 EC2에서 BE와 AI를 함께 띄운 CPU·메모리 실측은 없다. 절차는 [AI 배포 가이드](../AI-DEPLOYMENT.md).

## 배경

BE는 `AI_SERVER_BASE_URL`로 HTTP AI 서버를 호출한다. 현재 Infra는 BE용 EC2 `m5.large`(2 vCPU, 8 GiB) 한 대만 정의한다. AI 저장소(조사 시점 `main` `2e4caf4`)는 다음과 같다.

- 독립 Dockerfile이 있고 이미 GHCR에 `ghcr.io/42voicebridge/42voicebridge_ai:sha-<commit>`로 게시된다. 컨테이너 포트는 8000이며 외부 공개를 전제하지 않는다.
- 모델 가중치는 이미지에도 S3에도 없다. 베이스 모델(`openai/whisper-small`)은 런타임에 Hugging Face Hub에서 받아 `HF_HOME=/data/hf`에 캐시한다. 개인화 LoRA 어댑터는 `/data/adapters`, 프롬프트 풀(`script_pool.json`)은 `/data/script_pool.json`의 로컬 디스크에만 존재한다. 셋 다 S3를 쓰지 않으므로 **새 IAM 정책은 필요 없다.**
- 헬스체크는 `GET /v1/health`다. 첫 모델 로딩이 오래 걸려 재시작 루프가 생기지 않도록 Docker `HEALTHCHECK`는 의도적으로 두지 않았다.
- 학습기는 GPU가 없으면 기본적으로 실행을 거부한다(`ALLOW_CPU_TRAIN=1`은 짧은 테스트용). 운영자는 GPU를 가급적 피하고 AWS 크레딧 안에서 서버를 짧게 켜서 테스트한다. 따라서 이번 범위는 **CPU 추론과 BE 연결**이다.

## 검토한 방식

1. **BE 이미지에 AI 코드를 합침:** 배포 단위는 하나지만 Java와 Python·PyTorch 의존성, 이미지 크기, 모델 교체 주기가 함께 묶인다.
2. **별도 AI 이미지, 같은 EC2 (선택):** BE와 AI 컨테이너를 각각 실행한다. 보안그룹 변경이 없고 인스턴스·네트워크 비용이 늘지 않는다. BE의 CPU·8 GiB 메모리를 공유한다는 것이 단점이다.
3. **별도 AI 이미지, 별도 EC2:** 자원을 AI 요구에 맞출 수 있고 장애가 격리된다. 대신 `ai-sg` 신규 생성, 퍼블릭 서브넷 또는 NAT, 인스턴스·스토리지 비용, Terraform·SSM 경로 추가가 필요하다.

## 결정

**같은 EC2에서 AI를 별도 컨테이너로 실행한다.** 이미지는 CI에서 빌드한 독립 AI 이미지를 쓰며 EC2 안에서 소스를 빌드하지 않는다.

- **네트워크:** 사용자 정의 Docker 네트워크 `voicebridge`에 BE(`voicebridge-be`)와 AI(`voicebridge-ai`)를 함께 붙인다. AI 포트(8000)는 호스트에 게시하지 않으므로 보안그룹 변경이 없다. BE는 `AI_SERVER_BASE_URL=http://voicebridge-ai:8000`으로 호출한다. 이 값은 계속 Secrets Manager에서 읽으며 스크립트에 고정하지 않는다. 기본 bridge는 컨테이너 이름 DNS가 없어 쓰지 않는다.
- **상태 데이터:** 모델 캐시, 어댑터, 프롬프트 풀은 EC2가 교체되면 함께 사라지는 상태 데이터다. 루트 볼륨과 분리된 **EBS gp3 20 GiB 추가 볼륨**(암호화, `prevent_destroy`)을 `/data`에 마운트하고 호스트의 `/data/ai`를 컨테이너의 `/data`로 바인드한다. 루트 볼륨은 BE·AI 이미지(PyTorch 포함)를 담도록 30 GiB에서 40 GiB로 늘린다.
- **배포 경로:** 기존 SSM 수동 배포 경로를 확장한다. `deploy-ec2.sh`는 `be`와 `ai` 두 컴포넌트를 지원하고, 워크플로는 `ai_sha`를 추가로 받는다. 둘을 함께 배포하면 AI를 먼저 배포하고, AI가 실패하면 BE는 건드리지 않는다.
- **헬스체크:** AI는 `GET /v1/health`가 200을 반환할 때까지 5초 간격으로 최대 600초 기다린다. 첫 기동에서 약 1 GB의 베이스 모델을 내려받고 CPU로 로딩하는 시간을 BE(180초)보다 충분히 길게 잡은 값이며, 이미지 pull 시간은 별도다. 컨테이너가 재시작되면(`RestartCount > 0`) 지연이 아니라 실패로 보고 이전 컨테이너로 되돌린다.

## 트레이드오프

- **장애 격리 약화:** AI가 메모리를 과도하게 쓰면 같은 호스트의 BE에 영향을 줄 수 있다. 현재는 컨테이너 메모리 상한을 두지 않았다. 실측 후 필요하면 `--memory` 상한을 둔다.
- **볼륨 수명:** `prevent_destroy` 때문에 `terraform destroy`가 3_application 전체를 한 번에 지우지 못한다(의도된 보호). 비용 정리 절차는 [GUIDE](../GUIDE.md)와 [AI 배포 가이드](../AI-DEPLOYMENT.md)에 있다.
- **단일 AZ·단일 볼륨:** 볼륨은 인스턴스와 같은 AZ에 있고 스냅샷 자동화는 없다. 어댑터는 재생성이 어려운 데이터이므로 학습 결과를 쌓기 시작하면 백업 정책이 필요하다.
- **프롬프트 풀 수동 전달:** `script_pool.json`은 AI팀 내부 파일이라 코드·이미지에 없다. 배포 전에 운영자가 올려야 하며 없으면 `/v1/enroll/next-prompts`가 503을 반환한다.

## 재검토 조건

1. 같은 `m5.large`에서 BE와 AI를 함께 실행한 실측(메모리 여유, CPU, 시작 시간, 요청 지연)이 부족하다고 나오면 인스턴스 크기 상향을 먼저 검토한다.
2. 상향으로도 수용되지 않거나 장애 격리가 필요해지면 AI 전용 CPU EC2를 검토한다. 그때는 `ai-sg`, 서브넷 접근 경로, 별도 배포 대상이 필요하다.
3. GPU는 현재 계획에 포함하지 않는다. 사용자별 학습을 운영에서 돌릴 계획이 생기면 별도 ADR로 다룬다.

테스트 후 EC2만 중지해도 EBS·Elastic IP 비용은 남고, 현재 Terraform의 RDS·ElastiCache는 별도 과금된다. ElastiCache는 사용하지 않으면 삭제해야 비용이 멈춘다. 비용 실증은 EC2 한 대뿐 아니라 세 Terraform 레이어 전체를 기준으로 한다.

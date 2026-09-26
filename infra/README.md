# 42VoiceBridge AWS Infra (Terraform)

EC2(앱) + RDS MySQL + ElastiCache Redis + S3(녹음/TTS 오디오)로 구성된
42VoiceBridge 백엔드 인프라입니다. AI 서버와 네이버 클로바 보이스는 이 인프라
범위 밖의 외부 서비스입니다.

## ⚠️ 반드시 읽으세요: 비용 경고

이 구성은 **서울 리전 기준 24/7 가동 시 시간당 약 $0.61, 월 약 $445**가
발생합니다 (EC2 m5.large + RDS db.r5.large + ElastiCache cache.m5.large 기준).

**친구 AWS 계정 예산은 $100입니다. 절대 상시 가동하지 마세요.**

> **테스트가 끝나면 반드시 `terraform destroy`를 실행하세요.**
> `apply` 상태로 며칠만 방치해도 예산을 초과할 수 있습니다.

## 사전 준비

1. AWS 콘솔 → EC2 → 키 페어(Key Pairs)에서 새 키 페어를 생성하고 `.pem` 파일을
   안전하게 보관하세요. 이 키 페어 이름을 `ssh_key_name` 변수에 사용합니다.
2. `terraform.tfvars.example`을 복사해 `terraform.tfvars`를 만들고 실제 값을
   채웁니다 (이 파일은 `.gitignore`에 포함되어 커밋되지 않습니다).

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

   - `ssh_allowed_cidr`: 본인 IP만 허용 (예: `1.2.3.4/32`). **`0.0.0.0/0` 금지.**
   - `ssh_key_name`: 위에서 만든 키 페어 이름.

3. AWS 자격증명이 설정되어 있어야 합니다 (`aws configure` 또는 환경변수).

## 실행 순서

```bash
cd infra
terraform init
terraform plan
terraform apply
```

`apply` 결과의 output에서 EC2 퍼블릭 IP, RDS 엔드포인트, ElastiCache 엔드포인트,
S3 버킷명을 확인할 수 있습니다.

## 테스트가 끝나면

```bash
terraform destroy
```

**절대 잊지 마세요.** 위 비용 경고 참고.

## RDS 비밀번호 확인하기

RDS 마스터 비밀번호는 코드에 없으며 AWS Secrets Manager가 자동 관리합니다
(`manage_master_user_password = true`). 아래 방법으로 확인하세요.

**CLI:**

```bash
SECRET_ARN=$(terraform output -raw rds_secret_arn)
aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
  --query 'SecretString' --output text | jq .
```

**콘솔:** AWS 콘솔 → Secrets Manager → 시크릿 목록에서 RDS 인스턴스와 연결된
시크릿을 선택 → "Retrieve secret value".

## EC2 접속 후 `.env` 작성 예시

```bash
ssh -i /path/to/key.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

EC2에 접속한 뒤, 애플리케이션 `.env`를 아래와 같이 채웁니다.

```env
DB_HOST=<terraform output rds_endpoint 값>
DB_PORT=3306
DB_NAME=voicebridge
DB_USERNAME=voicebridge_admin
DB_PASSWORD=<위 Secrets Manager 조회 결과의 password 값>

REDIS_HOST=<terraform output redis_endpoint 값>
REDIS_PORT=<terraform output redis_port 값>

S3_BUCKET=<terraform output s3_bucket_name 값>
AWS_REGION=ap-northeast-2
```

애플리케이션은 `DefaultCredentialsProvider`를 사용하므로 액세스 키를 `.env`에
넣을 필요가 없습니다 — EC2에 붙은 IAM Instance Profile이 S3 접근 권한을
제공합니다.

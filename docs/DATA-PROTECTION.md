# AI 데이터 볼륨 보호: 백업, 삭제, 복원 절차

AI 인스턴스의 `/data`(별도 EBS)에는 **재생성이 어려운 데이터**가 있다: 개인화 LoRA 어댑터, 등록 음성(`enroll`), 학습 작업 상태, 그리고 모델 캐시·프롬프트 풀(다시 받을 수는 있다). 코드는 2026-10-03 기준으로 구현했고 **AWS에는 적용하지 않았다.** "확인 필요"는 실제 적용 후 확인할 항목이다.

## 보호 계층과 한계

| 계층 | 하는 일 | **막지 못하는 것** |
|---|---|---|
| 별도 EBS 볼륨 | 인스턴스를 교체·종료해도 볼륨은 남는다(루트 볼륨과 분리). 확인 필요: 적용 후 `DeleteOnTermination`이 `false`인지 | 볼륨 자체의 삭제 |
| `prevent_destroy` | 설정에 리소스 블록이 **있는 동안** `terraform destroy`와 교체를 오류로 막는다 | **블록을 코드에서 지우면 그대로 삭제가 계획되고 실행된다.** state가 사라져도 보호되지 않는다. 콘솔·CLI의 직접 삭제도 막지 못한다 |
| 암호화 | 볼륨과 스냅샷이 암호화된다(AWS 관리형 키) | 접근 권한이 있는 주체의 읽기 |
| **DLM 일일 스냅샷** | 태그 `Backup=ai-data`인 볼륨을 매일 UTC 18:00(한국 03:00)에 스냅샷하고 **7개를 보존**한다(변수 `data_snapshot_retention`) | 최근 24시간 이내의 변경, 7일을 넘긴 과거, 같은 리전·계정 장애 |

`prevent_destroy`의 한계는 로컬에서 재현해 확인했다. 블록이 있으면 `destroy`가 `Instance cannot be destroyed`로 막히지만, 블록을 지운 뒤 plan은 `will be destroyed`를 계획한다. 그래서 **스냅샷이 실제 백업**이고 `prevent_destroy`는 실수 방지용 안전핀이다.

### 스냅샷의 성격

- 스냅샷은 **크래시 일관성**(crash-consistent)이다. 쓰는 도중의 파일은 일관되지 않을 수 있다. 학습 작업이나 등록 음성 수신이 진행 중이 아닐 때 찍은 것이 안전하다. 중요한 시점(삭제·교체 전)에는 아래 수동 스냅샷을 쓴다.
- DLM은 **자신이 만든 스냅샷만** 보존 개수에 따라 지운다. 수동으로 만든 스냅샷은 지우지 않으므로 직접 정리해야 한다(비용: 증분 저장이라 변경량만큼 든다. 정확한 단가는 AWS 요금 계산기로 확인).
- 스냅샷은 같은 리전에 있다. 리전 장애나 계정 문제까지 막으려면 다른 리전·계정으로의 복사가 필요하지만 이번 범위에는 없다.

## 적용 후 확인

```bash
VOL=$(terraform -chdir=infra/environments/dev/3_application output -raw data_volume_id)

# 1) 인스턴스가 종료돼도 볼륨이 남는지 (DeleteOnTermination=false)
aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].Attachments[0].DeleteOnTermination'

# 2) DLM 정책이 켜져 있고 이 볼륨 태그를 대상으로 하는지
aws dlm get-lifecycle-policies --query 'Policies[?State==`ENABLED`]'
aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].Tags'

# 3) 첫 스냅샷이 생겼는지 (적용 후 첫 UTC 18:00 이후)
aws ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values="$VOL" \
  --query 'Snapshots[].[SnapshotId,StartTime,State]' --output table
```

## 절차 1: 수동 스냅샷 (위험한 변경 전)

인스턴스 교체, 사양 변경, 볼륨 삭제 같은 작업 전에 반드시 한다. 가능하면 학습·등록이 진행 중이 아닐 때 한다.

```bash
VOL=$(terraform -chdir=infra/environments/dev/3_application output -raw data_volume_id)
SNAP=$(aws ec2 create-snapshot --volume-id "$VOL" --description "manual before <작업 내용>" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Retention,Value=manual},{Key=Project,Value=voicebridge}]' \
  --query SnapshotId --output text)
aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"     # 완료될 때까지 기다린다
aws ec2 describe-snapshots --snapshot-ids "$SNAP" --query 'Snapshots[0].[State,Progress,Encrypted]'
echo "$SNAP"                                              # 기록해 둔다
```

`State`가 `completed`일 때만 백업으로 인정한다.

## 절차 2: EC2는 지우고 데이터는 남기기 (비용 정리)

테스트가 끝났을 때 인스턴스·EIP 비용은 멈추고 데이터는 보존한다.

```bash
cd infra/environments/dev/3_application
terraform destroy \
  -target=aws_volume_attachment.data -target=aws_instance.ai -target=aws_instance.be \
  -target=aws_eip_association.fe -target=aws_eip.fe -target=aws_instance.fe
```

- 볼륨(`aws_ebs_volume.data`)은 남는다. 남겨 둔 동안 EBS 비용(20 GiB gp3, 월 약 $2 안팎의 추정치)과 스냅샷 비용이 계속 든다.
- `-target`은 Terraform이 권장하지 않는 예외 도구다. 의존 관계 때문에 추가 대상을 요구할 수 있으니 출력되는 plan을 읽고 진행한다. 이 절차 전에도 수동 스냅샷을 만든다.
- 이후 `2_storage`, `1_base`는 기존 역순 절차로 지운다. `1_base`를 다시 만들어도 퍼블릭 서브넷은 항상 첫 번째 AZ(`names[0]`)라 같은 AZ에 다시 붙는다.
- **EIP를 지우면 FE의 공개 주소(도메인 없을 때 EIP 공개 DNS 이름)가 바뀐다.** [네트워크·엣지 가이드](NETWORK-AND-EDGE.md) 참고.

## 절차 3: 데이터까지 완전 삭제

1. **수동 스냅샷**을 만들고 `completed`를 확인한다(절차 1). 스냅샷 ID를 기록한다.
2. 정말 지울 것인지 AI팀·운영자가 확인한다. 어댑터에는 사용자 개인 데이터(AI-Hub 파생 데이터 포함)가 들어 있다.
3. `ai.tf`에서 `prevent_destroy`를 제거하는 변경을 **별도 커밋·PR로 리뷰**한다. 로컬에서 임시로 지우고 되돌리는 방식은 쓰지 않는다(되돌리는 것을 잊으면 보호가 사라진다).
4. 머지 후 `terraform destroy`를 실행한다. apply 워크플로를 쓴다면 plan이 볼륨 삭제를 나열하므로 검토하고 `allow_destroy=true`로 진행한다.
5. 필요 없어진 수동 스냅샷과 DLM 스냅샷의 정리 시점을 정한다(남아 있는 동안 비용이 든다).

## 절차 4: 스냅샷에서 복원

볼륨이 삭제됐거나 데이터가 손상된 경우다.

1. 복원할 스냅샷을 고른다.
   ```bash
   aws ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values=<예전 볼륨 ID> \
     --query 'Snapshots[].[SnapshotId,StartTime,State]' --output table
   ```
2. **볼륨이 이미 없는 경우(삭제 후 재생성):** `3_application` 변수 `data_snapshot_id`에 `snap-...`을 지정하고 plan → 검토 → apply 한다. Terraform이 그 스냅샷에서 새 볼륨을 만든다. 볼륨 크기(`data_volume_size_gb`)는 스냅샷 크기 이상이어야 한다.
3. **볼륨이 남아 있지만 손상된 경우:** 같은 변수를 바꾸면 볼륨 교체가 계획되고 `prevent_destroy`가 막는다. 이는 의도된 동작이다. 먼저 현재 볼륨의 수동 스냅샷을 만들고(절차 1), 교체가 맞다고 판단되면 절차 3의 2~4번처럼 보호를 해제하는 변경을 별도로 리뷰한 뒤 진행한다.
4. 복원 후 확인: AI 인스턴스에서 `mountpoint /data`와 `ls /data/ai/adapters`, AI 헬스(`/v1/health`)와 어댑터 목록을 확인한다. user_data는 **기존 파일시스템이 있으면 포맷하지 않고** 그대로 마운트한다(blkid가 시그니처를 발견하면 `mkfs`를 건너뛴다. 오프라인 테스트로 검증).
5. 다음 정기 스냅샷이 정상적으로 생기는지 확인한다(새 볼륨에도 `Backup=ai-data` 태그가 붙는다).

## 책임과 점검 주기

| 항목 | 주기 | 담당 |
|---|---|---|
| DLM 스냅샷이 생성되고 있는지(최근 24시간 이내) | 학습 데이터를 쌓기 시작한 뒤 주 1회 | 운영자 |
| 수동 스냅샷 정리 | 작업 종료 시 | 운영자 |
| 복원 절차 리허설(스냅샷에서 볼륨 생성 후 마운트) | 실제 어댑터가 쌓이기 전에 1회 | 운영자 |

복원 리허설을 한 번도 하지 않은 백업은 검증된 백업이 아니다. 첫 적용 후 한 번 해 보는 것을 권한다.

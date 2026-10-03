# 트러블슈팅 기록

발생한 문제와 조사·해결 과정을 번호순으로 기록한다. 배포 관련 설계 결정은 [ADR 목록](../adr/README.md)을 참고한다.

| 번호 | 문제 | 해결 요약 |
|---|---|---|
| [0001](0001-terraform-provider-checksum.md) | CD 준비 점검에서 Terraform provider 체크섬 불일치 | macOS와 GitHub Linux runner의 체크섬을 잠금 파일에 기록하고 재실행으로 확인 |

# sslip.io는 가입·DNS 설정 없이 IP를 그대로 호스트명에 인코딩해 resolve해주는 무료 서비스다.
# ec2-3-34-9-37...compute.amazonaws.com으로는 Let's Encrypt가 발급을 거부해서(정책상 금지)
# FE Elastic IP(3.34.9.37)를 가리키는 이 이름으로 바꾼다. 실 도메인을 사면 이 파일을 지우고
# terraform.tfvars에 그 도메인을 넣으면 된다.
fe_domain = "3-34-9-37.sslip.io"

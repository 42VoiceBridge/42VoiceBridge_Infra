# FE·BE·AI 3대 공통 요소. 인스턴스별 정의는 be.tf, ai.tf, fe.tf에 있다.

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# 프라이빗 서브넷에는 NAT가 없어 GHCR pull, Hugging Face 다운로드, SSM 연결이 불가능하므로
# 세 인스턴스 모두 퍼블릭 서브넷에 둔다. 인바운드는 보안그룹으로 통제한다.
# 볼륨 AZ와 고정 사설 IP 검증도 이 서브넷 정보를 쓴다.
data "aws_subnet" "app" {
  id = data.terraform_remote_state.base.outputs.public_subnet_id
}

locals {
  subnet_id = data.terraform_remote_state.base.outputs.public_subnet_id

  # 퍼블릭 서브넷은 /24이므로 앞 3옥텟(예: "10.0.1.")이 같으면 같은 서브넷 안의 주소다.
  subnet_prefix = "${join(".", slice(split(".", cidrhost(data.aws_subnet.app.cidr_block, 0)), 0, 3))}."
}

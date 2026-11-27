# ============================================================================
# 5G Core AIOps Demo — 主入口（Provider / VPC / 网络 / 安全组 / IAM 委托）
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.96"
    }
  }

  backend "local" {}
}

provider "huaweicloud" {
  region = var.region
  # AK/SK 从环境变量读取，不硬编码：
  #   export HW_ACCESS_KEY="..."
  #   export HW_SECRET_KEY="..."
}

# ----------------------------------------------------------------------------
# VPC + 子网（3 AZ：public/private 三套）
# ----------------------------------------------------------------------------
resource "huaweicloud_vpc" "main" {
  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
}

# 三个可用区（cn-north-4 为 a/b/c）
locals {
  azs = ["${var.region}a", "${var.region}b", "${var.region}c"]
}

resource "huaweicloud_vpc_subnet" "public" {
  count      = 3
  name       = "${var.project_name}-public-${local.azs[count.index]}"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = cidrsubnet(var.vpc_cidr, 8, 101 + count.index) # 10.0.101/102/103.0/24
  gateway_ip = cidrhost(cidrsubnet(var.vpc_cidr, 8, 101 + count.index), 1)
  # CCE / ELB 子网发现标签
  tags = merge(var.tags, {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

resource "huaweicloud_vpc_subnet" "private" {
  count      = 3
  name       = "${var.project_name}-private-${local.azs[count.index]}"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = cidrsubnet(var.vpc_cidr, 8, 1 + count.index) # 10.0.1/2/3.0/24
  gateway_ip = cidrhost(cidrsubnet(var.vpc_cidr, 8, 1 + count.index), 1)
  tags = merge(var.tags, {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# DCS Redis 专用子网
resource "huaweicloud_vpc_subnet" "redis" {
  count      = 3
  name       = "${var.project_name}-redis-${local.azs[count.index]}"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = cidrsubnet(var.vpc_cidr, 8, 51 + count.index) # 10.0.51/52/53.0/24
  gateway_ip = cidrhost(cidrsubnet(var.vpc_cidr, 8, 51 + count.index), 1)
}

# ----------------------------------------------------------------------------
# NAT 网关 + EIP（private 子网出网）
# ----------------------------------------------------------------------------
resource "huaweicloud_vpc_eip" "nat" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.project_name}-nat-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_nat_gateway" "main" {
  name        = "${var.project_name}-nat"
  spec        = "1"
  vpc_id      = huaweicloud_vpc.main.id
  subnet_id   = huaweicloud_vpc_subnet.public[0].id
  description = "NAT for private subnets egress"
}

resource "huaweicloud_nat_snat_rule" "main" {
  nat_gateway_id = huaweicloud_nat_gateway.main.id
  subnet_id      = huaweicloud_vpc_subnet.private[0].id
  floating_ip_id = huaweicloud_vpc_eip.nat.id
}

# ----------------------------------------------------------------------------
# 安全组（Redis SG 规则单独在 redis.tf 管理）
# ----------------------------------------------------------------------------
resource "huaweicloud_networking_secgroup" "node" {
  name        = "${var.project_name}-node"
  description = "CCE node security group"
}

resource "huaweicloud_networking_secgroup" "redis" {
  name        = "${var.project_name}-redis"
  description = "DCS Redis security group (scenario-1 SG change target)"
}

# 节点基础放行（节点间 + 从 pod 网段访问 Redis 6379 由 redis SG 单独控制）
resource "huaweicloud_networking_secgroup_rule" "node_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = huaweicloud_networking_secgroup.node.id
}

# 允许 pod 网段（private 子网）访问 Redis 6379 —— Scenario 1 会撤销这条规则
resource "huaweicloud_networking_secgroup_rule" "redis_from_pods" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6379
  port_range_max    = 6379
  remote_ip_prefix  = huaweicloud_vpc_subnet.private[0].cidr
  security_group_id = huaweicloud_networking_secgroup.redis.id
}

# ----------------------------------------------------------------------------
# IAM 委托（agency）
#  - cce_agency：让 CCE 管理节点/依赖资源（CCE 托管集群必需）
#  - agent_agency：让 FunctionGraph（AIOps 智能体）访问 CCE/LTS/CES/CTS/VPC/CSMS
# ----------------------------------------------------------------------------
resource "huaweicloud_identity_agency" "cce" {
  name                  = "${var.project_name}-cce"
  description           = "Agency for CCE to manage cluster dependencies"
  delegated_service_name = "op_svc_cce"
  project_role {
    project = var.region
    roles   = ["CCE Administrator"]
  }
}

resource "huaweicloud_identity_agency" "agent" {
  name                    = "${var.project_name}-agent"
  description             = "Agency for AIOps agent (FunctionGraph) to query CCE/LTS/CES/CTS/VPC"
  duration                = "FOREVER"
  # 由 FunctionGraph 服务（op_svc_cff）扮演该委托，函数才能经其拿临时凭证
  delegated_service_name  = "op_svc_cff"

  project_role {
    project = var.region
    roles = [
      "CCE FullAccess",
      "LTS FullAccess",
      "CES FullAccess",
      "CTS FullAccess",
      "VPC FullAccess",
    ]
  }
}

# 集群访问凭据（apiserver 地址 + CA + 只读 SA token）由 deploy.sh 在集群侧
# 创建只读 ServiceAccount 并写入 infra/agent.auto.tfvars（agent.tf 经 user_data
# 注入函数），不落盘真实凭据。此处保留一个 CSMS 占位密钥便于后续托管化。
resource "huaweicloud_csms_secret" "cluster_creds" {
  name        = "${var.project_name}-cluster-creds"
  description = "Read-only kube-apiserver credentials for the AIOps agent"
  secret_type = "COMMON"  # CSMS secret_type 合法值：COMMON/RDS/RDS-FG/GaussDB-FG（非 text）
  secret_text = jsonencode({
    apiserver = "REPLACE_AFTER_DEPLOY"
    ca_cert   = "REPLACE_AFTER_DEPLOY"
    token     = "REPLACE_AFTER_DEPLOY"
  })
}

data "huaweicloud_account" "current" {}

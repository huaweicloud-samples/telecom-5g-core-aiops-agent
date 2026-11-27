# ============================================================================
# 5G Core AIOps Demo — 变量定义（华为云）
# 区域默认 cn-north-4，与既有迁移项目保持一致。
# 所有计费相关的规格都在这里显式写死，apply 前请确认。
# ============================================================================

variable "region" {
  description = "华为云区域"
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "项目名称，用作资源命名前缀"
  type        = string
  default     = "devops-agent-5g"
}

variable "cluster_name" {
  description = "CCE 集群名称"
  type        = string
  default     = "devops-agent-5g"
}

variable "cluster_version" {
  description = "Kubernetes 版本（CCE 支持版本，按目标 region 实际可用值确认）"
  type        = string
  default     = "v1.30"
}

variable "domain_name" {
  description = "华为云账号域名（IAM 委托归属域 delegated_domain_name），需替换为实际域名"
  type        = string
  default     = "your-huaweicloud-domain"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

# CCE 控制面规格（标准集群）。不同 region 可用规格不同，apply 前请在控制台确认。
variable "cce_flavor_id" {
  description = "CCE 集群控制面规格"
  type        = string
  default     = "cce.s1.small"
}

# 节点规格：s6.large.2（2vCPU / 4GB）
variable "node_flavor" {
  description = "CCE 节点规格（ECS flavor）"
  type        = string
  default     = "s6.large.2"
}

# CCE 节点登录密钥对（ECS 密钥对，需提前在控制台创建）。
# 节点池要求 key_pair 或 password 二者至少其一；此处用 key_pair（不落明文密码）。
# apply 前必须在 terraform.tfvars 中填入真实密钥对名称。
variable "node_key_pair" {
  description = "CCE 节点登录密钥对名称（提前在控制台创建，apply 前必填）"
  type        = string
}

# app 节点池上限。Scenario 2 通过
# `terraform apply -var="app_node_pool_max=2" -target=huaweicloud_cce_node_pool.app`
# 临时压低上限，模拟成本管控导致的扩容天花板。
variable "app_node_pool_max" {
  description = "CCE app 节点池最大节点数（Scenario 2 临时压低用）"
  type        = number
  default     = 3
}

# DCS Redis 单节点规格
variable "dcs_flavor" {
  description = "DCS Redis 单节点规格"
  type        = string
  default     = "redis.single.xu1.tiny.128"
}

# 增强型 ELB 规格。不同 region 可用 flavor 不同，apply 前确认。
variable "elb_flavor_id" {
  description = "独享型 ELB 规格"
  type        = string
  default     = "elb.p3s2.1small1"
}

variable "tags" {
  description = "全局标签"
  type        = map(string)
  default = {
    Project     = "devops-agent-5g"
    Environment = "demo"
    ManagedBy   = "terraform"
  }
}

# ----------------------------------------------------------------------------
# 集群只读访问凭据（AIOps 智能体访问 kube-apiserver 用）
# 由 deploy.sh 创建只读 ServiceAccount 并生成 token 后，填入本变量。
# 也可通过 CSMS 密钥托管（main.tf 中已建占位 secret）。
# ----------------------------------------------------------------------------
variable "kube_apiserver" {
  description = "CCE kube-apiserver 地址（https://...）"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kube_ca_b64" {
  description = "kube-apiserver CA 证书（base64）"
  type        = string
  default     = ""
  sensitive   = true
}

variable "kube_token" {
  description = "只读 ServiceAccount 长期 token"
  type        = string
  default     = ""
  sensitive   = true
}

variable "maas_model_name" {
  description = "盘古大模型部署名（MaaS 上实际部署的模型）"
  type        = string
  default     = "pangu-nlp-2024-12"
}

# 盘古大模型 MaaS API Key（OpenAI 兼容端点鉴权用）。
# 从环境变量 MAAS_API_KEY 注入，不硬编码（云 AK/SK 绝不落盘；
# 此处为模型服务 Key，同样按敏感数据处理，仅经 tfvars/user_data 本地传递）。
variable "maas_api_key" {
  description = "盘古 MaaS API Key（OpenAI 兼容端点鉴权）"
  type        = string
  default     = ""
  sensitive   = true
}

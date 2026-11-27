# ============================================================================
# CCE 集群 + 节点池
#  - system 节点池：污点 CriticalAddonsOnly
#  - app 节点池：开启节点池弹性伸缩（Scenario 2/4 调 max 模拟天花板）
# ============================================================================

# 集群 apiserver 公网访问 EIP：让本地 kubectl 与 AIOps 智能体（FunctionGraph，
# 运行在 VPC 之外）能够访问 kube-apiserver。私网访问仍保留。
resource "huaweicloud_vpc_eip" "cluster_apiserver" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.project_name}-cluster-apiserver-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_cce_cluster" "main" {
  name                   = var.cluster_name
  cluster_type           = "VirtualMachine"
  flavor_id              = var.cce_flavor_id
  vpc_id                 = huaweicloud_vpc.main.id
  subnet_id              = huaweicloud_vpc_subnet.private[0].id
  container_network_type = "vpc-router"
  description            = "5G Core AIOps demo cluster"

  # 集群访问：绑定 EIP 开启公网 apiserver 访问（智能体跨 VPC 调用需要）
  # 注意：此处必须填 EIP 的 IP 地址（.address），不是资源 id（provider 校验）
  eip = huaweicloud_vpc_eip.cluster_apiserver.address

  tags = var.tags
}

# metrics-server 插件（HPA 依赖）
# 其余插件（coredns / kube-proxy）由 CCE 默认安装。
resource "huaweicloud_cce_addon" "metrics_server" {
  cluster_id    = huaweicloud_cce_cluster.main.id
  template_name = "metrics-server"
  # version 可留空使用最新；若 provider 报缺版本，请在控制台查可用版本后填入
}

# ----------------------------------------------------------------------------
# system 节点池（tainted CriticalAddonsOnly，固定 2 节点）
# ----------------------------------------------------------------------------
resource "huaweicloud_cce_node_pool" "system" {
  cluster_id         = huaweicloud_cce_cluster.main.id
  name               = "system"
  os                 = "Huawei Cloud EulerOS 2.0"  # API 必填；v1.30 cn-north-4 实测 EulerOS 2.9 被拒（CCE.01400018）
  key_pair           = var.node_key_pair
  flavor_id          = var.node_flavor
  initial_node_count = 2
  min_node_count     = 2
  max_node_count     = 3
  subnet_id          = huaweicloud_vpc_subnet.private[0].id
  availability_zone  = local.azs[0]
  scall_enable       = false

  labels = {
    role = "system"
  }

  taints {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NoSchedule"
  }

  root_volume {
    size       = 40
    volumetype = "SSD"
  }

  data_volumes {
    size       = 100
    volumetype = "SSD"
  }

  tags = merge(var.tags, { pool = "system" })
}

# ----------------------------------------------------------------------------
# app 节点池（承载 5G NF；开启节点池弹性伸缩，初始 2、上限 3）
# Scenario 2 通过调低 max_node_count 模拟 ASG 天花板。
# ----------------------------------------------------------------------------
resource "huaweicloud_cce_node_pool" "app" {
  cluster_id         = huaweicloud_cce_cluster.main.id
  name               = "app"
  os                 = "Huawei Cloud EulerOS 2.0"  # API 必填；v1.30 cn-north-4 实测 EulerOS 2.9 被拒（CCE.01400018）
  key_pair           = var.node_key_pair
  flavor_id          = var.node_flavor
  initial_node_count = 2
  min_node_count     = 2
  max_node_count     = var.app_node_pool_max
  subnet_id          = huaweicloud_vpc_subnet.private[0].id
  availability_zone  = local.azs[0]
  scall_enable       = true

  labels = {
    role = "app"
  }

  root_volume {
    size       = 40
    volumetype = "SSD"
  }

  data_volumes {
    size       = 100
    volumetype = "SSD"
  }

  tags = merge(var.tags, { pool = "app" })
}

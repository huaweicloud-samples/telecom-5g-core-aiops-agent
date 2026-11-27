# ============================================================================
# 独享型 ELB + EIP —— 暴露 AMF 作为 N2 入口
# CCE ELB Ingress 控制器通过 kubernetes.io/elb.id 注解复用此 ELB。
# 调试期建议用安全组把入站锁到运维者 IP。
# ============================================================================

resource "huaweicloud_vpc_eip" "ingress" {
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name        = "${var.project_name}-ingress-bw"
    size        = 5
    share_type  = "PER"
    charge_mode = "traffic"
  }
}

resource "huaweicloud_elb_loadbalancer" "ingress" {
  name = "${var.project_name}-ingress"
  # 独享型 ELB：loadbalancer_type 留空（gateway 是网关型 GWLB，不适用）
  # 独享型 ELB 用 L7 规格（ingress 走 HTTP/HTTPS）；L4 场景改用 l4_flavor_id
  # l7_flavor_id 必须是 flavor 的 UUID（API 不接受规格名，SYS.0400）
  # cn-north-4 实测最小 L7 规格：L7_flavor.elb.s1.small (66da67e5-e36b-4c9a-8c06-197ae9e92988)
  l7_flavor_id      = "66da67e5-e36b-4c9a-8c06-197ae9e92988"
  ipv4_eip_id       = huaweicloud_vpc_eip.ingress.id
  vpc_id            = huaweicloud_vpc.main.id
  availability_zone = [local.azs[0]]
  # 独享型 ELB 的 ipv4_subnet_id 必须用子网的 ipv4_subnet_id（Neutron 侧），不是 VPC 层 .id
  # ELB 需要子网的 ipv4_subnet_id
  ipv4_subnet_id    = huaweicloud_vpc_subnet.public[0].ipv4_subnet_id
}

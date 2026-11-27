# ============================================================================
# DCS Redis —— NRF 服务注册后端
# 单节点小规格，demo 足够。Scenario 1 通过安全组规则切断 Pod→Redis 连接。
# ============================================================================

resource "huaweicloud_dcs_instance" "redis" {
  name              = "${var.project_name}-redis"
  engine            = "Redis"
  engine_version    = "7.0"
  capacity          = 0.125
  flavor            = var.dcs_flavor
  vpc_id            = huaweicloud_vpc.main.id
  subnet_id         = huaweicloud_vpc_subnet.redis[0].id
  # DCS Redis 4.0+ 基础版不支持安全组（DCS.4872），访问控制走白名单；
  # 不配白名单 = VPC 内互通。Scenario 1 的「切断 Pod→Redis」改由脚本
  # 操作 DCS 白名单实现（见 scripts-5g/scenario-1-sg-change.sh）。
  availability_zones = [local.azs[0]]  # 新字段名（旧字段 available_zones 已废弃且报 invalid AZ code）

  # DCS 单节点实例默认仅私网、无公网 IP，Redis 不应公网暴露，
  # 因此无需额外的 enable_publicip 字段。

  tags = merge(var.tags, { Demo = "scenario-1-sg-change" })
}

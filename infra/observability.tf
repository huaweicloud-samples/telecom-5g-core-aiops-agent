# ============================================================================
# 可观测性：LTS 日志 + AOM 容器洞察
#  - LTS：NF 日志采集与检索
#  - AOM：CCE 容器洞察指标
# 在 CCE 控制台「日志」页为 demo-5g 命名空间配置 LTS 采集策略后，
# NF 的 stdout 日志会进入下方 LTS 日志流，供智能体检索。
# ============================================================================

resource "huaweicloud_lts_group" "app" {
  group_name  = "${var.project_name}-app"
  ttl_in_days = 7
}

resource "huaweicloud_lts_stream" "nf" {
  group_id    = huaweicloud_lts_group.app.id
  stream_name = "5g-core-nf"
  ttl_in_days = 7
}

# AOM 应用运维管理：CCE 容器洞察指标会自动上报到 AOM，
# 智能体可通过 AOM 查询 Pod/节点/集群级指标。
# 此处仅声明一个 AOM 应用，便于在控制台定位命名空间级指标。
resource "huaweicloud_aom_application" "demo" {
  name        = "${var.project_name}-demo"
  description = "5G core demo application for AOM container insights"
}

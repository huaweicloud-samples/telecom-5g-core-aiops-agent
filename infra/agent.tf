# ============================================================================
# AIOps 智能体
# ----------------------------------------------------------------------------
# 本函数用 FunctionGraph（Python3.9）+ 盘古大模型（ModelArts MaaS OpenAI 兼容端点）
# 实现跨层运维智能体：通过工具调用查询 CCE / LTS / CES / CTS / VPC，
# 实现 Pod 日志 → 安全组 → 审计日志的跨层根因定位。
#
# 触发：APIG 触发器暴露 HTTP 端点（共享 APIG，无需专享实例）。
# 代码：打包 zip 上传到 OBS（code_type=obs），由 src/agent/build_and_deploy.py 上传。
# ============================================================================

# 函数代码桶
resource "huaweicloud_obs_bucket" "fgs_code" {
  bucket        = "${var.project_name}-fgs-code"
  acl           = "private"
  force_destroy = true

  tags = merge(var.tags, { Usage = "function-code" })
}

# OBS 数据面不认 agency 临时凭证，需通过显式桶策略放行 Domain 级角色。
# 注意：OBS 原生桶策略（policy_format=obs）格式 ≠ IAM 策略——
#   Principal 必须是对象 {"ID": [...]}，Version 必须是 "2008-10-17"
resource "huaweicloud_obs_bucket_policy" "fgs_code" {
  bucket = huaweicloud_obs_bucket.fgs_code.bucket
  policy = jsonencode({
    Version = "2008-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { ID = ["domain/${data.huaweicloud_account.current.id}:agency/${huaweicloud_identity_agency.agent.name}"] }
      Action = ["GetObject", "PutObject"]
      Resource = ["${huaweicloud_obs_bucket.fgs_code.bucket}/*"]
    }]
  })
}

# FunctionGraph 函数：AIOps 智能体
resource "huaweicloud_fgs_function" "agent" {
  name        = "${var.project_name}-agent"
  app         = "default"  # 函数所属应用分组（API package 必填，默认 default）
  agency      = huaweicloud_identity_agency.agent.name
  handler     = "index.handler"
  memory_size = 512
  timeout     = 120
  runtime     = "Python3.9"

  code_type = "obs"
  code_url  = "https://${huaweicloud_obs_bucket.fgs_code.bucket}.obs.${var.region}.myhuaweicloud.com/agent.zip"

  # 运行期代码经 build_and_deploy.py 上传，让出 code_url 所有权避免反复重传
  user_data = jsonencode({
    for k, v in {
      REGION         = var.region
      AGENCY_NAME    = huaweicloud_identity_agency.agent.name
      KUBE_APISERVER = var.kube_apiserver
      KUBE_CA_B64    = var.kube_ca_b64
      KUBE_TOKEN     = var.kube_token
      MAAS_ENDPOINT  = "https://api.modelarts-maas.com/v2"
      MAAS_API_KEY   = var.maas_api_key
      MODEL_NAME     = var.maas_model_name
    } : k => v if v != ""
  })

  # 运行期代码经 build_and_deploy.py 上传，让出 code_url 所有权避免反复重传
  lifecycle {
    ignore_changes = [code_url, code_type]
  }
}

# APIG 触发器：暴露 HTTP 端点（需要 APIG 共享版 group_id / 专享版实例，当前账号无专享实例；
# 共享版 event_data 需要 group_id/env_id 且新用户可能不支持，先跳过，控制台手动创建或后续补）
# event_data 为 APIG 触发器必填字段：描述 API 分组 / API / 环境。
# resource "huaweicloud_fgs_function_trigger" "apig" {
#   function_urn = huaweicloud_fgs_function.agent.urn
#   type         = "APIG"
#   event_data = jsonencode({
#     group_name   = "${var.project_name}-apig-group"
#     env_name     = "RELEASE"
#     protocol     = "HTTPS"
#     auth         = "IAM"
#     name         = "${var.project_name}-agent-api"
#     path         = "/aiops"
#     method       = "ANY"
#     match_mode   = "NORMAL"
#     backend_type = "FUNCTION"
#     type         = "public"
#     enable_cors  = false
#   })
# }

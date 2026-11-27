# ============================================================================
# 输出
# ============================================================================

output "region" {
  value = var.region
}

output "cluster_id" {
  description = "CCE 集群 ID"
  value       = huaweicloud_cce_cluster.main.id
}

output "cluster_name" {
  value = huaweicloud_cce_cluster.main.name
}

output "redis_connect_address" {
  description = "DCS Redis 连接地址（私网 IP，填入 k8s-5g/namespace.yaml 的 redis-host）"
  value       = huaweicloud_dcs_instance.redis.private_ip
  sensitive   = true
}

output "redis_port" {
  value = huaweicloud_dcs_instance.redis.port
}

output "redis_security_group_id" {
  description = "DCS Redis 安全组 ID（保留占位；DCS 4.0+ 基础版不支持安全组，访问控制走白名单）"
  value       = huaweicloud_networking_secgroup.redis.id
}

output "redis_instance_id" {
  description = "DCS Redis 实例 ID（Scenario 1 操作白名单用：DCS 不支持安全组，改由脚本调 API 增删白名单）"
  value       = huaweicloud_dcs_instance.redis.id
}

output "redis_allowed_cidr" {
  description = "允许访问 Redis 6379 的来源 CIDR（app 节点/ pod 子网，Scenario 1 撤销的是它）"
  value       = huaweicloud_vpc_subnet.private[0].cidr
}

output "app_node_pool_id" {
  description = "app 节点池 ID（Scenario 2 调 max_node_count 模拟 ASG 天花板）"
  value       = huaweicloud_cce_node_pool.app.id
}

output "elb_id" {
  description = "独享型 ELB ID（ingress.yaml 的 kubernetes.io/elb.id 注解）"
  value       = huaweicloud_elb_loadbalancer.ingress.id
}

output "agent_function_id" {
  value = huaweicloud_fgs_function.agent.id
}

output "agent_agency_name" {
  value = huaweicloud_identity_agency.agent.name
}

output "fgs_code_bucket" {
  value = huaweicloud_obs_bucket.fgs_code.bucket
}

output "next_steps" {
  value = <<-EOT

    ┌─────────────────────────────────────────────────────────────┐
    │ NEXT STEPS                                                   │
    │                                                              │
    │ 1. 配置 kubectl（CCE 控制台「集群 / kubectl」页下载 kubeconfig）│
    │    或：kubectl config set-cluster ... --server=<apiserver>    │
    │                                                              │
    │ 2. 部署 5G Core NF：                                         │
    │    ./deploy.sh                                               │
    │    （deploy.sh 会把 redis-host 注入 namespace.yaml，并创建    │
    │     智能体只读 SA + token，回写 terraform.tfvars 的 kube_*）  │
    │                                                              │
    │ 3. 部署 AIOps 智能体函数代码：                               │
    │    cd src/agent && python build_and_deploy.py --region ...   │
    │                                                              │
    │ 4. 验证：./verify.sh                                         │
    │ 5. 跑场景：./scripts-5g/scenario-1-sg-change.sh inject       │
    │    然后把症状贴给智能体（APIG 触发器 URL）让它跨层定位根因  │
    └─────────────────────────────────────────────────────────────┘
  EOT
}

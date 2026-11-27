# 部署指南

按本指南完成从零到可演示的全过程。所有凭据通过环境变量注入，**不写入任何文件**。

## 0. 准备

```bash
export HW_ACCESS_KEY="<HW_ACCESS_KEY>" # 占位符，真实值来自控制台
export HW_SECRET_KEY="<HW_SECRET_KEY>"
export MAAS_API_KEY="<MAAS_API_KEY>" # 盘古 MaaS API Key（智能体运行期用）

# 工具检查
./prerequisites.sh
```

## 1. 基础设施（Terraform）

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，至少填写 domain_name（IAM 委托归属域）
vi terraform.tfvars
terraform init
terraform plan # 核对资源清单
terraform apply # 确认后继续
```

`apply` 完成后，`terraform output` 会给出 `cluster_id` / `redis_connect_address` / `elb_id` / `fgs_code_bucket` 等，供后续步骤使用。

## 2. 5G 核心网 + 智能体只读凭据（deploy.sh）

```bash
cd ..
./deploy.sh
```

脚本会：

1. 从 Terraform 输出读取 Redis 地址 / ELB ID；
2. 获取 CCE kubeconfig（优先 `hcloud cce get-kubeconfig`，失败则从控制台下载 `kubeconfig.yaml`）；
3. 注入 `namespace.yaml`（Redis 地址）与 `ingress.yaml`（ELB ID）并部署全部 NF；
4. 创建只读 ServiceAccount `aiops-readonly` + ClusterRoleBinding，生成 token；
5. 把 `kube_apiserver` / `kube_ca_b64` / `kube_token` / `maas_api_key` 写入 `infra/agent.auto.tfvars`（该文件含集群 token，请加入 `.gitignore`）。

## 3. 智能体函数（build_and_deploy.py）

```bash
cd src/agent
python build_and_deploy.py --region cn-north-4
```

脚本会平台锁定安装 `huaweicloudsdk*` + `openai`，打包 zip（含护栏：缺核心 SDK 或体积 < 200KB 直接报错），并上传到 OBS 代码桶。函数经 `code_type=obs` 拉取代码（OBS 桶策略放行 agent agency 读取）。

> 构建机若为 Windows / macOS / arm，务必保留 `--platform manylinux2014_x86_64 --python-version 39 --only-binary=:all:`，否则原生模块在 FGS（Linux x86_64）加载即崩、日志全空。

## 4. 验证

```bash
./verify.sh
```

覆盖：kubectl 连通、命名空间、Pod 状态、NRF↔Redis 连通、端到端 UE 注册、CCE 节点 Ready、AMF HPA、CES 告警规则数量。

## 5. 跑场景

```bash
./scripts-5g/scenario-1-sg-change.sh inject
./scripts-5g/scenario-2-asg-ceiling.sh inject
./scripts-5g/scenario-3-bad-deploy.sh inject
./scripts-5g/scenario-4-scaling-storm.sh inject
```

每个场景的 `inject` / `restore` 成对。把症状描述 POST 给 FunctionGraph 的 APIG 端点，智能体即跨层定位根因。

## 6. 清理

```bash
# 复原场景
for s in scenario-1-sg-change scenario-2-asg-ceiling scenario-3-bad-deploy scenario-4-scaling-storm; do
./scripts-5g/$s.sh restore; done
# 销毁基础设施
cd infra && terraform destroy
```

# telecom-5g-core-aiops-agent · 5G 核心网 AIOps 运维演示

![License: MIT No Attribution](https://img.shields.io/badge/License-MIT--No--Attribution-green.svg)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-cn--north--4-red)
![Status](https://img.shields.io/badge/build-passing-brightgreen)

## 1. 简介 / Overview

### 简介


本仓库是一套**运行在华为云上的 5G 核心网可观测性 / AIOps 演示**：用一组轻量网络功能（NRF / AMF / SMF / UPF / PCF）模拟 5G 核心网，并把注册信息写入 DCS Redis；再叠加一个自建的 **AIOps 智能体**（FunctionGraph + 盘古大模型），能够跨层关联 CCE（K8s）、VPC 安全组、CTS 审计、CES 告警，自动定位「Pod 日志 → 安全组 → 审计日志」这类跨层根因。

适用对象：云原生 / 运营商云 / DevOps 团队，希望直观演示「智能体如何辅助 SRE 做跨云服务根因定位」。

---

## 2. 目录

- [1. 简介 / Overview](#1-简介--overview)
- [2. 目录](#2-目录)
- [3. 架构图](#3-架构图)
- [4. 方案亮点](#4-方案亮点)
- [5. 涉及云服务](#5-涉及云服务)
- [6. 前置条件](#6-前置条件)
- [7. 快速开始](#7-快速开始)
- [8. 分步部署](#8-分步部署)
- [9. 使用方法 / 验证](#9-使用方法--验证)
- [10. 清理资源](#10-清理资源)
- [11. 详细说明](#11-详细说明)
- [12. 依赖](#12-依赖)
- [13. FAQ / 故障排除](#13-faq--故障排除)
- [14. 贡献指南](#14-贡献指南)
- [15. 许可证](#15-许可证)
- [16. 联系方式 / 维护者](#16-联系方式--维护者)

---

## 3. 架构图

```
┌─────────────────────────────────────────┐
外部 RAN/压测 ───────▶ │ CCE ELB (独享型, ingress.yaml) │
(UE 模拟器流量) │ │ 暴露 AMF N2 入口 │
└────────┼──────────────────────────────────┘
▼
┌─────────────────────────────────────────┐
│ CCE 集群 (VirtualMachine, VPC-Network) │
│ ├─ system 节点池 (CriticalAddonsOnly) │
│ └─ app 节点池 (弹性伸缩, role=app) │
│ ├─ nrf (服务注册/发现, 依赖 Redis) │
│ ├─ amf (UE 注册入口, 含 HPA) │
│ ├─ smf / upf / pcf │
│ └─ ue-simulator (压测流量生成) │
└───────────────┬─────────────────────────┘
│ Redis 6379 (VPC 内)
┌───────────────▼─────────────────────────┐
│ DCS Redis (单节点, redis.single.xu1) │
└─────────────────────────────────────────┘

跨层可观测 / 告警：
├─ LTS NF 日志采集
├─ AOM 容器洞察 / 应用监控
├─ CES 5G-Core-* 告警规则 (6 条)
├─ CTS 审计 (谁改了安全组 / 集群资源)
└─ VPC SG Redis 6379 入方向规则 (Scenario 1 改动点)

AIOps 智能体：
┌──────────────────────────────────────────────┐
│ FunctionGraph (Python3.9) + 盘古大模型 MaaS │
│ APIG 触发器暴露 HTTP 端点 │
│ 工具: kube_* / vpc_* / cts_* / ces_* │
│ 经 agent agency 临时凭证调用上述云服务 │
└──────────────────────────────────────────────┘
```

---

## 4. 方案亮点

- **Serverless 智能体**：AIOps 推理跑在 FunctionGraph 上，按调用触发，无需常驻资源；盘古大模型经 MaaS OpenAI 兼容端点调用。
- **跨层根因定位**：智能体不止看 K8s，还能查 VPC 安全组规则、CTS 审计、CES 告警，复现「跨服务关联」能力。
- **基础设施即代码**：VPC / CCE / DCS / ELB / 函数 / 告警全部 Terraform 声明式管理，场景注入也是 `terraform -target` 驱动，无散落脚本凭据。
- **四个可复现故障场景**：安全组误改、节点池天花板、坏镜像发布、HPA 震荡，覆盖典型 5G 核心网运维痛点。

---

## 5. 涉及云服务

- VPC（虚拟私有云）
- CCE（云容器引擎）
- DCS（分布式缓存服务）
- ELB（弹性负载均衡）
- FunctionGraph（函数工作流）
- LTS（日志服务）/ AOM（应用运维管理）
- CES（云监控）/ CTS（云审计）
- IAM（统一身份认证）
- OBS（对象存储服务）

---

## 6. 前置条件

- 华为云账号（区域 `cn-north-4`），具备 VPC / CCE / DCS / ELB / FunctionGraph / IAM 创建权限。
- 本地工具：`hcloud`（华为云 CLI）、`terraform`（>= 1.5）、`kubectl`、`jq`。
- 凭据以**环境变量**注入，**绝不写入代码或配置文件**：
```bash
export HW_ACCESS_KEY="<HW_ACCESS_KEY>" # 占位符，真实值不落盘
export HW_SECRET_KEY="<HW_SECRET_KEY>"
```
- 盘古大模型 MaaS：在 ModelArts Studio 开通模型并获取 API Key（运行时经 `MAAS_API_KEY` 注入函数，详见部署步骤）。
- 区域约束：部分规格（cce_flavor_id / elb_flavor_id）在不同 region 可用值不同，`apply` 前请在控制台确认。

---

## 7. 快速开始

```bash
# 1. 准备凭据与工具
export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
export HW_SECRET_KEY="<HW_SECRET_KEY>"

# 2. 初始化并部署基础设施
cd infra
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars # 填写 domain_name（IAM 委托归属域）
terraform init
terraform apply

# 3. 部署 5G 核心网 + 生成智能体只读凭据
cd ..
./deploy.sh

# 4. 验证
./verify.sh

# 5. 构建并部署 AIOps 智能体函数
cd src/agent
export MAAS_API_KEY="<MAAS_API_KEY>"
python build_and_deploy.py --region cn-north-4

# 6. 跑场景（把症状贴给智能体 HTTP 端点让它定位根因）
./scripts-5g/scenario-1-sg-change.sh inject
```

---

## 8. 分步部署

1. **基础设施（Terraform）**：`infra/` 定义 VPC（3 AZ / public / private / redis 子网）、NAT + SNAT、安全组（含 `redis_from_pods` 6379 规则）、IAM 委托（cce / agent）、CCE 集群 + 双节点池、DCS Redis、独享 ELB + EIP、LTS/AOM、6 条 CES 告警、FunctionGraph 函数 + OBS 代码桶 + APIG 触发器。
2. **K8s 工作负载（deploy.sh）**：从 Terraform 输出读取 DCS Redis 地址 / ELB ID，注入 `namespace.yaml` / `ingress.yaml`；按依赖顺序部署 NRF → PCF/UPF/SMF → AMF（含 HPA）→ UE 模拟器；创建智能体只读 ServiceAccount 并把 apiserver/CA/token 写入 `infra/agent.auto.tfvars`。
3. **智能体函数（build_and_deploy.py）**：平台锁定安装 `huaweicloudsdk*` + `openai`，打包 zip 上传 OBS，函数经 `code_type=obs` 拉取代码（OBS 桶策略放行 agent agency 读取）。

---

## 9. 使用方法 / 验证

### 使用方法与验证


```bash
# 健康检查
./verify.sh

# 跑场景 1：Redis 安全组被误改 → NRF 失联 → 全网 PDU 会话失败
./scripts-5g/scenario-1-sg-change.sh inject
# 把 "demo-5g 命名空间 AMF 日志显示 NRF 发现失败..." 这类描述
# POST 给 FunctionGraph 的 APIG 端点，智能体会查 CTS 审计 + VPC 安全组定位根因
curl -X POST <APIG_ENDPOINT> -H 'Content-Type: application/json' \
-d '{"prompt":"demo-5g 的 AMF 日志显示 NRF 发现失败，PDU 会话建立失败，查根因"}'
# 复原：
./scripts-5g/scenario-1-sg-change.sh restore
```

预期：智能体返回「Redis 6379 入方向规则被删除 + CTS 显示 XX 时间某操作」式结论。注意：6 条 CES 告警规则定义在 `alarms.tf.disabled`，因 provider 1.96 指标白名单 bug 当前未启用，Scenario 1 不会触发 CES 告警；根因定位由智能体经 CTS / VPC / AOM 实时查询完成。

部署完成后请按本节步骤自行验证，确认业务功能可用，方可视为交付完成。

---

## 10. 清理资源

```bash
# 复原所有场景
for s in scenario-1-sg-change scenario-2-asg-ceiling scenario-3-bad-deploy scenario-4-scaling-storm; do
./scripts-5g/$s.sh restore; done

# 销毁全部基础设施（OBS 桶 force_destroy=true 会清空代码包）
cd infra && terraform destroy
```

---

## 11. 详细说明

- `infra/`：Terraform 根模块。各资源分组在 `main.tf`(网络/安全组/IAM)、`cce.tf`、`redis.tf`、`ingress.tf`、`observability.tf`、`alarms.tf.disabled`、`agent.tf`、`outputs.tf`、`variables.tf`。
- `k8s-5g/`：5G NF 为 provider-agnostic 的 Python 桩（`python:3.12-slim` + 原生 socket RESP 访问 Redis），仅依赖 `nodeSelector: role=app`（对应 app 节点池标签）。`ingress.yaml` 用 CCE ELB 注解 `kubernetes.io/elb.id` 绑定独享 ELB。
- `src/agent/`：`index.py`（handler + 工具调用循环 + 跨层工具）、`model_adapter.py`（模型抽象层）、`build_and_deploy.py`（打包 + OBS 上传）、`requirements.txt`。
- `scripts-5g/`：四个故障场景的注入 / 复原脚本，全部以 Terraform 或 kubectl 驱动。
- 智能体工具：`kube_get_pods` / `kube_get_pod_logs` / `kube_get_nodes`（纯 urllib 访问 K8s API）、`vpc_list_secgroup_rules`、`cts_find_sg_changes`、`ces_list_alarms`（华为云 SDK，懒加载）。

---

## 12. 依赖

- 华为云 Terraform Provider（`huaweicloud`，~> 1.96）
- 华为云 Python SDK（`huaweicloudsdkcore/ces/vpc/cts`）
- 盘古大模型（ModelArts MaaS，OpenAI 兼容端点）
- 5G 核心网网络功能为演示用轻量桩。

---

## 13. FAQ / 故障排除

### FAQ


- **函数「执行失败 + 日志全空」**：几乎总是打包缺 SDK 依赖。确认 `build_and_deploy.py` 用 `--platform manylinux2014_x86_64 --python-version 39 --only-binary=:all:` 安装；产物应 > 2MB；且**不要**自带 `obs` / `cryptography` 原生模块（FGS 已内置）。
- **函数读 OBS 代码报 403**：OBS 数据面不认 agency 临时凭证，必须靠 `huaweicloud_obs_bucket_policy`（已声明，Principal 为 `domain/<domain_id>:agency/<agent_name>`）。
- **改了 agency 权限后仍 403**：FunctionGraph 热实例缓存旧临时凭证，需控制台「清理实例」或 `terraform apply -replace` 冷启动。
- **kubectl 拿不到 kubeconfig**：`deploy.sh` 优先用 `hcloud cce get-kubeconfig`；失败则从 CCE 控制台下载并保存到 `kubeconfig.yaml`。

---

## 14. 贡献指南

欢迎提交 Issue 与 PR。请遵循仓库内现有目录结构与代码风格。

---

## 15. 许可证

本实践采用 **MIT No Attribution** 许可证，详见仓库根目录 [`LICENSE`](LICENSE) 文件。

---

## 16. 联系方式 / 维护者
| 项 | 内容 |
|---|---|
| **创建者** | [dgc-git](https://github.com/dgc-git) |
| **维护者** | [dgc-git](https://github.com/dgc-git) |
| **联系方式** | GitHub Issues / PR（见[第 14 节](#14-贡献指南)） |

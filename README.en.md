# telecom-5g-core-aiops-agent

![License: MIT No Attribution](https://img.shields.io/badge/License-MIT--No--Attribution-green.svg)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-cn--north--4-red)
![Status](https://img.shields.io/badge/build-passing-brightgreen)

## 1. Overview

### Overview

This repository is a **5G core network observability / AIOps demo running on Huawei Cloud**: a set of lightweight network functions (NRF / AMF / SMF / UPF / PCF) simulate a 5G core network, and registration information is written to DCS Redis. On top of that, a self-built **AIOps agent** (FunctionGraph + Pangu LLM) correlates CCE (K8s), VPC security groups, CTS audit, and CES alarms across layers, automatically locating cross-layer root causes such as "Pod log → security group → audit log".

Target audience: cloud-native / carrier cloud / DevOps teams who want a visual demonstration of "how an agent helps SREs locate cross-service root causes".

---

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture Diagram](#3-architecture-diagram)
- [4. Highlights](#4-highlights)
- [5. Cloud Services Used](#5-cloud-services-used)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-Step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Cleanup](#10-cleanup)
- [11. Detailed Explanation](#11-detailed-explanation)
- [12. Dependencies](#12-dependencies)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

---

## 3. Architecture Diagram

```
┌─────────────────────────────────────────┐
External RAN/load test ──────▶ │ CCE ELB (Dedicated, ingress.yaml) │
(UE simulator traffic) │ │ Exposes the AMF N2 entry point │
└────────┼──────────────────────────────────┘
▼
┌─────────────────────────────────────────┐
│ CCE cluster (VirtualMachine, VPC-Network) │
│ ├─ system node pool (CriticalAddonsOnly) │
│ └─ app node pool (autoscaling, role=app) │
│ ├─ nrf (service registration/discovery, depends on Redis) │
│ ├─ amf (UE registration entry point, with HPA) │
│ ├─ smf / upf / pcf │
│ └─ ue-simulator (load test traffic generator) │
└───────────────┬─────────────────────────┘
│ Redis 6379 (within VPC)
┌───────────────▼─────────────────────────┐
│ DCS Redis (single node, redis.single.xu1) │
└─────────────────────────────────────────┘

Cross-layer observability / alarms:
├─ LTS NF log collection
├─ AOM container insight / application monitoring
├─ CES 5G-Core-* alarm rules (6)
├─ CTS audit (who changed security groups / cluster resources)
└─ VPC SG Redis 6379 inbound rule (changed in Scenario 1)

AIOps agent:
┌──────────────────────────────────────────────┐
│ FunctionGraph (Python3.9) + Pangu LLM MaaS │
│ APIG trigger exposes the HTTP endpoint │
│ Tools: kube_* / vpc_* / cts_* / ces_* │
│ Calls the above cloud services via agent agency temporary credentials │
└──────────────────────────────────────────────┘
```

---

## 4. Highlights

- **Serverless agent**: AIOps inference runs on FunctionGraph, triggered per invocation with no resident resources; the Pangu LLM is called through an MaaS OpenAI-compatible endpoint.
- **Cross-layer root cause location**: the agent looks beyond K8s and also queries VPC security group rules, CTS audit, and CES alarms, reproducing "cross-service correlation" capabilities.
- **Infrastructure as code**: VPC / CCE / DCS / ELB / functions / alarms are all managed declaratively with Terraform, and scenario injection is driven by `terraform -target` — no loose scripts holding credentials.
- **Four reproducible failure scenarios**: security group misconfiguration, node pool ceiling, bad image release, and HPA flapping, covering typical 5G core network O&M pain points.

---

## 5. Cloud Services Used

- VPC (Virtual Private Cloud)
- CCE (Cloud Container Engine)
- DCS (Distributed Cache Service)
- ELB (Elastic Load Balance)
- FunctionGraph
- LTS (Log Tank Service) / AOM (Application Operations Management)
- CES (Cloud Eye Service) / CTS (Cloud Trace Service)
- IAM (Identity and Access Management)
- OBS (Object Storage Service)

---

## 6. Prerequisites

- A Huawei Cloud account (region `cn-north-4`) with permissions to create VPC / CCE / DCS / ELB / FunctionGraph / IAM resources.
- Local tools: `hcloud` (Huawei Cloud CLI), `terraform` (>= 1.5), `kubectl`, `jq`.
- Credentials are provided via **environment variables** and **never written into code or configuration files**:

```bash
export HW_ACCESS_KEY="<HW_ACCESS_KEY>" # placeholder; the real value is never written to disk
export HW_SECRET_KEY="<HW_SECRET_KEY>"
```

- Pangu LLM MaaS: enable the model in ModelArts Studio and obtain an API Key (provided to the function at runtime via `MAAS_API_KEY`; see the deployment steps).
- Region constraint: some flavors (`cce_flavor_id` / `elb_flavor_id`) have different available values in different regions; confirm them in the console before `apply`.

---

## 7. Quick Start

```bash
# 1. Prepare credentials and tools
export HW_ACCESS_KEY="<HW_ACCESS_KEY>"
export HW_SECRET_KEY="<HW_SECRET_KEY>"

# 2. Initialize and deploy the infrastructure
cd infra
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars # fill in domain_name (the IAM agency domain)
terraform init
terraform apply

# 3. Deploy the 5G core network + generate the agent's read-only credentials
cd ..
./deploy.sh

# 4. Verify
./verify.sh

# 5. Build and deploy the AIOps agent function
cd src/agent
export MAAS_API_KEY="<MAAS_API_KEY>"
python build_and_deploy.py --region cn-north-4

# 6. Run a scenario (paste the symptoms into the agent's HTTP endpoint to locate the root cause)
./scripts-5g/scenario-1-sg-change.sh inject
```

---

## 8. Step-by-Step Deployment

1. **Infrastructure (Terraform)**: `infra/` defines the VPC (3 AZs / public / private / redis subnets), NAT + SNAT, security groups (including the `redis_from_pods` 6379 rule), IAM agencies (cce / agent), the CCE cluster + dual node pools, DCS Redis, a dedicated ELB + EIP, LTS/AOM, 6 CES alarms, and the FunctionGraph function + OBS code bucket + APIG trigger.
2. **K8s workloads (deploy.sh)**: reads the DCS Redis address / ELB ID from Terraform outputs and injects them into `namespace.yaml` / `ingress.yaml`; deploys NRF → PCF/UPF/SMF → AMF (with HPA) → UE simulator in dependency order; creates the agent's read-only ServiceAccount and writes the apiserver/CA/token into `infra/agent.auto.tfvars`.
3. **Agent function (build_and_deploy.py)**: installs `huaweicloudsdk*` + `openai` with locked platforms, packages a zip and uploads it to OBS, and the function pulls the code via `code_type=obs` (the OBS bucket policy allows the agent agency to read).

---

## 9. Usage / Verification

### Usage and Verification

```bash
# Health check
./verify.sh

# Run Scenario 1: the Redis security group is accidentally changed → NRF loses contact → all PDU sessions fail
./scripts-5g/scenario-1-sg-change.sh inject
# Post a description like "AMF logs in namespace demo-5g show NRF discovery failure..."
# to the FunctionGraph APIG endpoint; the agent queries CTS audit + VPC security groups to locate the root cause
curl -X POST <APIG_ENDPOINT> -H 'Content-Type: application/json' \
-d '{"prompt":"demo-5g 的 AMF 日志显示 NRF 发现失败，PDU 会话建立失败，查根因"}'
# Restore:
./scripts-5g/scenario-1-sg-change.sh restore
```

Expected: the agent returns a conclusion like "the Redis 6379 inbound rule was deleted + CTS shows an operation at XX time". Note: the 6 CES alarm rules are defined in `alarms.tf.disabled` and are currently not enabled due to a provider 1.96 metric-whitelist bug, so Scenario 1 does not trigger a CES alarm; root-cause location is performed by the agent through live CTS / VPC / AOM queries.

After deployment, follow these steps to verify that the business functionality works before considering the delivery complete.

---

## 10. Cleanup

```bash
# Restore all scenarios
for s in scenario-1-sg-change scenario-2-asg-ceiling scenario-3-bad-deploy scenario-4-scaling-storm; do
./scripts-5g/$s.sh restore; done

# Destroy all infrastructure (the OBS bucket with force_destroy=true will be emptied)
cd infra && terraform destroy
```

---

## 11. Detailed Explanation

- `infra/`: the Terraform root module. Resources are grouped in `main.tf` (network/security groups/IAM), `cce.tf`, `redis.tf`, `ingress.tf`, `observability.tf`, `alarms.tf.disabled`, `agent.tf`, `outputs.tf`, and `variables.tf`.
- `k8s-5g/`: the 5G NFs are provider-agnostic Python stubs (`python:3.12-slim` + native socket RESP access to Redis) that only depend on `nodeSelector: role=app` (matching the app node pool label). `ingress.yaml` binds the dedicated ELB with the CCE ELB annotation `kubernetes.io/elb.id`.
- `src/agent/`: `index.py` (handler + tool invocation loop + cross-layer tools), `model_adapter.py` (model abstraction layer), `build_and_deploy.py` (packaging + OBS upload), and `requirements.txt`.
- `scripts-5g/`: injection / restoration scripts for the four failure scenarios, all driven by Terraform or kubectl.
- Agent tools: `kube_get_pods` / `kube_get_pod_logs` / `kube_get_nodes` (pure urllib access to the K8s API), `vpc_list_secgroup_rules`, `cts_find_sg_changes`, and `ces_list_alarms` (Huawei Cloud SDK, lazily loaded).

---

## 12. Dependencies

- Huawei Cloud Terraform Provider (`huaweicloud`, ~> 1.96)
- Huawei Cloud Python SDK (`huaweicloudsdkcore/ces/vpc/cts`)
- Pangu LLM (ModelArts MaaS, OpenAI-compatible endpoint)
- The 5G core network functions are lightweight stubs for demonstration purposes.

---

## 13. FAQ / Troubleshooting

- **Function "execution failed + empty log"**: almost always a missing SDK dependency in the package. Confirm `build_and_deploy.py` installs with `--platform manylinux2014_x86_64 --python-version 39 --only-binary=:all:`; the artifact should be > 2MB; and **do not** bundle the native modules `obs` / `cryptography` (already built into FGS).
- **Function reading OBS code returns 403**: the OBS data plane does not accept agency temporary credentials; `huaweicloud_obs_bucket_policy` must be used (already declared, with Principal `domain/<domain_id>:agency/<agent_name>`).
- **Still 403 after changing agency permissions**: FunctionGraph warm instances cache old temporary credentials; use the console "clear instances" action or `terraform apply -replace` for a cold start.
- **kubectl cannot obtain kubeconfig**: `deploy.sh` first uses `hcloud cce get-kubeconfig`; if that fails, download it from the CCE console and save it as `kubeconfig.yaml`.

---

## 14. Contributing

Issues and PRs are welcome. Please follow the existing directory structure and code style in the repository.

---

## 15. License

This practice is licensed under **MIT No Attribution**; see the [`LICENSE`](LICENSE) file in the repository root.

---

## 16. Contact / Maintainers
| Item | Content |
|---|---|
| **Creator** | [dgc-git](https://github.com/dgc-git) |
| **Maintainer** | [dgc-git](https://github.com/dgc-git) |
| **Contact** | GitHub Issues / PR (see [Section 14](#14-contributing)) |

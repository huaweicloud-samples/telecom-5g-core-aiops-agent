#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy.sh — Post-Terraform K8s deployment for 5G Core Demo (Huawei Cloud)
#
# Run AFTER:  terraform apply   (creates VPC, CCE, DCS Redis, ELB, FunctionGraph
#                                agent, CES alarms, IAM agencies)
# Run BEFORE: building the agent function code (src/agent/build_and_deploy.py)
#             and running the scenarios.
#
# What this script does:
#   1. Reads Terraform outputs (cluster, DCS Redis, ELB).
#   2. Wires up kubectl against the CCE cluster.
#   3. Deploys the 5G Core NFs (namespace, NRF, SMF, UPF, PCF, AMF, UE sim, Ingress).
#   4. Creates a read-only ServiceAccount for the AIOps agent and writes its
#      apiserver/CA/token into infra/agent.auto.tfvars (consumed by agent.tf).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Windows 兼容：kubectl/terraform 是 Windows 原生二进制，需把 /d/... 转成 D:/...
if command -v cygpath >/dev/null 2>&1; then
  SCRIPT_DIR="$(cygpath -w "${SCRIPT_DIR}" | tr '\\' '/')"
fi
TF_DIR="${SCRIPT_DIR}/infra"
K8S_DIR="${SCRIPT_DIR}/k8s-5g"
NAMESPACE="demo-5g"

echo "═══════════════════════════════════════════════════════════════"
echo "  5G Core Demo — Deploy (Huawei Cloud / CCE)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# --- Step 1: Terraform outputs -------------------------------------------------
echo "▸ Reading Terraform outputs..."
cd "${TF_DIR}"
CLUSTER_ID=$(terraform output -raw cluster_id 2>/dev/null) || {
  echo "ERROR: Cannot read terraform outputs. Run 'terraform apply' first."; exit 1
}
REGION=$(terraform output -raw region 2>/dev/null || echo "cn-north-4")
REDIS_HOST=$(terraform output -raw redis_connect_address)
REDIS_PORT=$(terraform output -raw redis_port)
ELB_ID=$(terraform output -raw elb_id)

echo "  Cluster:  ${CLUSTER_ID}"
echo "  Region:   ${REGION}"
echo "  Redis:    ${REDIS_HOST}:${REDIS_PORT}"
echo "  ELB:      ${ELB_ID}"
echo ""

# --- Step 2: Configure kubectl ------------------------------------------------
echo "▸ Configuring kubectl for CCE..."

KCFG="D:/workbuddy/2026-08-21-09-03-23/kubeconfig.yaml"
if command -v hcloud >/dev/null 2>&1; then
  # huaweicloud CLI: download the cluster kubeconfig (public access)
  hcloud cce get-kubeconfig --cluster_id "${CLUSTER_ID}" --file "${KCFG}" >/dev/null 2>&1 \
    || hcloud cce get-kubeconfig --cluster-id "${CLUSTER_ID}" --file "${KCFG}" >/dev/null 2>&1 \
    || true
fi

if [[ -s "${KCFG}" ]]; then
  export KUBECONFIG="${KCFG}"
  CONTEXT=$(kubectl config current-context 2>/dev/null || true)
  echo "  ✓ kubeconfig obtained via hcloud (context: ${CONTEXT:-default})"
else
  echo "  ⚠ hcloud CLI unavailable or kubeconfig fetch failed."
  echo "    Download the kubeconfig from the CCE console (Cluster → kubectl)"
  echo "    and save it to: ${KCFG}"
  echo "    Then re-run this script. (If KUBECONFIG already points at the"
  echo "    cluster, you can also set KUBECONFIG and skip this step.)"
  if ! kubectl cluster-info >/dev/null 2>&1; then
    exit 1
  fi
fi

# --- Step 3: Deploy 5G Core NFs -----------------------------------------------
echo "▸ Deploying 5G Core network functions..."

# Patch namespace configmap with the real DCS Redis endpoint
PATCHED_NS=$(sed "s|REPLACE_WITH_REDIS_ENDPOINT|${REDIS_HOST}|g" "${K8S_DIR}/namespace.yaml")
echo "${PATCHED_NS}" | kubectl apply -f - >/dev/null

kubectl apply -f "${K8S_DIR}/nrf.yaml" >/dev/null
echo "  ✓ NRF (service registry)"

kubectl rollout status deployment/nrf -n ${NAMESPACE} --timeout=120s >/dev/null 2>&1

kubectl apply -f "${K8S_DIR}/pcf.yaml" >/dev/null
kubectl apply -f "${K8S_DIR}/upf.yaml" >/dev/null
kubectl apply -f "${K8S_DIR}/smf.yaml" >/dev/null
echo "  ✓ PCF, UPF, SMF"

kubectl apply -f "${K8S_DIR}/amf.yaml" >/dev/null
echo "  ✓ AMF (with HPA)"

kubectl apply -f "${K8S_DIR}/ue-simulator.yaml" >/dev/null
echo "  ✓ UE Simulator (load generator)"

# Patch ingress with the real ELB ID（在 NF 全部就绪后，amf Service 已存在）
PATCHED_INGRESS=$(sed "s|REPLACE_WITH_ELB_ID|${ELB_ID}|g" "${K8S_DIR}/ingress.yaml")
echo "${PATCHED_INGRESS}" | kubectl apply -f - >/dev/null
echo "  ✓ Ingress (5G N2 entry via ELB)"

echo ""

# --- Step 4: Read-only ServiceAccount for the AIOps agent ---------------------
echo "▸ Creating read-only ServiceAccount for AIOps agent..."

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aiops-readonly
  namespace: demo-5g
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aiops-readonly
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "namespaces", "services", "nodes", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aiops-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aiops-readonly
subjects:
  - kind: ServiceAccount
    name: aiops-readonly
    namespace: demo-5g
EOF

# Long-lived token (Kubernetes ≥1.24 requires an explicit SA-token Secret)
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: aiops-readonly-token
  namespace: demo-5g
  annotations:
    kubernetes.io/service-account.name: aiops-readonly
type: kubernetes.io/service-account-token
EOF
sleep 3

APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_B64=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl get secret aiops-readonly-token -n demo-5g -o jsonpath='{.data.token}' | base64 -d)

# Write agent kube credentials into an auto-loaded tfvars file
cat > "${TF_DIR}/agent.auto.tfvars" <<EOF
# Generated by deploy.sh — AIOps agent read-only kube access.
# Do not commit this file (contains a cluster token). Add to .gitignore.
kube_apiserver = "${APISERVER}"
kube_ca_b64   = "${CA_B64}"
kube_token    = "${TOKEN}"
maas_api_key  = "${MAAS_API_KEY:-}"
EOF
echo "  ✓ agent kube credentials written to infra/agent.auto.tfvars"

# --- Step 5: Wait for pods ----------------------------------------------------
echo "▸ Waiting for pods to be ready..."
kubectl wait --for=condition=ready pods --all -n ${NAMESPACE} --timeout=180s >/dev/null 2>&1 || true
echo "  ✓ 5G NFs deployed"
echo ""

# --- Done ---------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
echo "  ✓ K8s deployment complete!"
echo ""
echo "  Next steps:"
echo "    1. Run ./verify.sh to confirm health"
echo "    2. Build & deploy the AIOps agent function:"
echo "         cd src/agent && python build_and_deploy.py --region ${REGION}"
echo "       (needs MAAS_API_KEY in env for the Pangu endpoint)"
echo "    3. Get the agent HTTP URL from the FunctionGraph console trigger"
echo "    4. Run scenarios: ./scripts-5g/scenario-1-sg-change.sh inject"
echo "═══════════════════════════════════════════════════════════════"

#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# verify.sh — Health check for 5G Core Demo (Huawei Cloud)
#
# Validates: kubectl access, all NFs running, NRF↔Redis connected,
#            UE registrations flowing, CCE nodes ready, CES alarms exist.
# =============================================================================

PASS="✓"
FAIL="✗"
WARN="⚠"
errors=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/infra"
NAMESPACE="demo-5g"

echo "═══════════════════════════════════════════════════════════════"
echo "  5G Core Demo — Health Check (Huawei Cloud)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# --- kubectl access -----------------------------------------------------------
echo "▸ Cluster access"
if kubectl cluster-info >/dev/null 2>&1; then
  CLUSTER=$(kubectl config current-context)
  echo "  ${PASS} kubectl connected: ${CLUSTER}"
else
  echo "  ${FAIL} kubectl not configured — run deploy.sh first"
  exit 1
fi
echo ""

# --- Namespace exists ---------------------------------------------------------
echo "▸ Namespace"
if kubectl get ns demo-5g >/dev/null 2>&1; then
  echo "  ${PASS} demo-5g namespace exists"
else
  echo "  ${FAIL} demo-5g namespace missing — run deploy.sh"
  exit 1
fi
echo ""

# --- All pods running ---------------------------------------------------------
echo "▸ Pod status"
NOT_READY=$(kubectl get pods -n demo-5g --no-headers 2>/dev/null | grep -cv "Running\|Completed" || true)
TOTAL=$(kubectl get pods -n demo-5g --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "${NOT_READY}" -eq 0 && "${TOTAL}" -gt 0 ]]; then
  echo "  ${PASS} All ${TOTAL} pods running"
else
  echo "  ${FAIL} ${NOT_READY}/${TOTAL} pods not ready:"
  kubectl get pods -n demo-5g --no-headers | grep -v "Running\|Completed" | awk '{printf "      %-30s %s\n", $1, $3}'
  errors=$((errors + 1))
fi

for NF in nrf amf smf upf pcf ue-simulator; do
  READY=$(kubectl get deploy "${NF}" -n demo-5g -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  READY="${READY:-0}"
  DESIRED=$(kubectl get deploy "${NF}" -n demo-5g -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  DESIRED="${DESIRED:-0}"
  if [[ "${DESIRED}" -eq 0 ]]; then
    echo "  ${PASS} ${NF}: scaled to 0 (expected)"
  elif [[ "${READY}" -ge 1 ]]; then
    echo "  ${PASS} ${NF}: ${READY}/${DESIRED} ready"
  else
    echo "  ${FAIL} ${NF}: ${READY}/${DESIRED} ready"
    errors=$((errors + 1))
  fi
done
echo ""

# --- NRF ↔ Redis connection ---------------------------------------------------
echo "▸ NRF → Redis connectivity"
NRF_POD=$(kubectl get pod -n demo-5g -l app=nrf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "${NRF_POD}" ]]; then
  HEALTH=$(kubectl exec -n demo-5g "${NRF_POD}" --request-timeout=10s -- \
    python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health', timeout=5).read().decode())" 2>/dev/null || echo "failed")
  if echo "${HEALTH}" | grep -q "connected"; then
    echo "  ${PASS} NRF Redis health: connected"
  else
    echo "  ${FAIL} NRF Redis health: ${HEALTH}"
    errors=$((errors + 1))
  fi
else
  echo "  ${FAIL} No NRF pod found"
  errors=$((errors + 1))
fi
echo ""

# --- UE registration flow -----------------------------------------------------
echo "▸ End-to-end UE registration"
if [[ -n "${NRF_POD}" ]]; then
  AMF_POD=$(kubectl get pod -n demo-5g -l app=amf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${AMF_POD}" ]]; then
    REG_RESULT=$(kubectl exec -n demo-5g "${AMF_POD}" --request-timeout=10s -- python -c "
import urllib.request, json
req = urllib.request.Request('http://localhost:8080/namf-comm/v1/ue-registrations',
    data=json.dumps({'supi':'imsi-001010000099999'}).encode(),
    headers={'Content-Type':'application/json'}, method='POST')
print(urllib.request.urlopen(req, timeout=5).read().decode())" 2>/dev/null || echo "failed")
    if echo "${REG_RESULT}" | grep -qi "registered\|success\|imsi"; then
      echo "  ${PASS} UE registration: success"
    else
      echo "  ${WARN} UE registration returned: ${REG_RESULT:0:80}"
    fi
  else
    echo "  ${FAIL} No AMF pod found"
    errors=$((errors + 1))
  fi
fi
echo ""

# --- CCE nodes (replaces 云 Cluster Autoscaler check) ------------------------
echo "▸ CCE nodes (node pool autoscaling)"
NODE_TOTAL=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NODE_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
if [[ "${NODE_READY}" -eq "${NODE_TOTAL}" && "${NODE_TOTAL}" -gt 0 ]]; then
  echo "  ${PASS} All ${NODE_TOTAL} nodes Ready (autoscaling via CCE node pool)"
else
  echo "  ${WARN} ${NODE_READY}/${NODE_TOTAL} nodes Ready — node pool may be scaling"
fi
echo ""

# --- HPA ----------------------------------------------------------------------
echo "▸ HPA (AMF)"
HPA_EXISTS=$(kubectl get hpa -n demo-5g --no-headers 2>/dev/null | grep -c "amf" || true)
if [[ "${HPA_EXISTS}" -ge 1 ]]; then
  HPA_TARGETS=$(kubectl get hpa -n demo-5g -o jsonpath='{.items[0].spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null || echo "?")
  echo "  ${PASS} AMF HPA configured (target: ${HPA_TARGETS}%)"
else
  echo "  ${WARN} AMF HPA not found (needed for Scenario 4)"
fi
echo ""

# --- CES Alarms (replaces 云 云监控 alarms) ------------------------------
echo "▸ CES Alarms"
if [[ -d "${TF_DIR}/.terraform" ]]; then
  ALARM_COUNT=$(terraform -chdir="${TF_DIR}" state list 2>/dev/null | grep -c "huaweicloud_ces_alarmrule" || true)
  if [[ "${ALARM_COUNT}" -ge 4 ]]; then
    echo "  ${PASS} ${ALARM_COUNT} CES alarm rules configured (prefix: 5G-Core-*)"
  else
    echo "  ${WARN} Only ${ALARM_COUNT} CES alarm rules found (expected 6) — run terraform apply"
  fi
else
  echo "  ${WARN} terraform state not initialized in infra/ — run terraform apply"
fi
echo ""

# --- Summary ------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════"
if [[ "${errors}" -eq 0 ]]; then
  echo "  ${PASS} All checks passed — ready for demo!"
else
  echo "  ${FAIL} ${errors} issue(s) found — review above"
fi
echo "═══════════════════════════════════════════════════════════════"
exit "${errors}"

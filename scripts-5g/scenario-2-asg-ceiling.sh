#!/bin/bash
# =============================================================================
# Scenario 2 (5G): "Pods won't schedule during busy hour"
#
# Simulates: Peak traffic drives AMF HPA scale-up, but the nodes are already
# saturated with platform workloads and the node pool is capped at max capacity.
# New AMF pods are stuck in Pending — subscriber registrations degrade.
#
# Failure chain: Nodes loaded with platform workloads → node pool max capped →
# AMF replicas requested > schedulable → FailedScheduling events →
# subscribers queue → registration timeouts.
#
# On CCE the node pool ceiling is the app node pool's max_node_count, managed
# by Terraform (variable `app_node_pool_max`). We override it with `-var` and
# target only the app node pool resource — no separate API credentials needed.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NAMESPACE="demo-5g"
TF_DIR="${SCRIPT_DIR}/../infra"

get_app_pool_id() {
  tf_output app_node_pool_id
}

case "${1:-inject}" in
  inject)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  5G SCENARIO 2: Node Pool Ceiling During Busy Hour"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    APP_POOL=$(get_app_pool_id)
    echo "  App node pool: ${APP_POOL}"

    # Cap node pool at 2 nodes (simulate cost-control policy)
    terraform -chdir="${TF_DIR}" apply \
      -var="app_node_pool_max=2" \
      -target='huaweicloud_cce_node_pool.app' \
      -auto-approve > /dev/null
    echo "  ✗ Node pool capped at max=2 (simulating cost-control policy)"

    # Wait for node count to stabilize
    echo "  ⏳ Waiting for node scale-in (30s)..."
    sleep 30

    # Deploy platform workload that fills node capacity
    # Simulates real-world: telemetry, monitoring, log shippers consuming CPU
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telemetry-collector
  namespace: ${NAMESPACE}
  labels:
    app: telemetry-collector
    component: platform
spec:
  replicas: 4
  selector:
    matchLabels:
      app: telemetry-collector
  template:
    metadata:
      labels:
        app: telemetry-collector
        component: platform
    spec:
      nodeSelector:
        role: app
      containers:
        - name: collector
          image: busybox:1.36
          command: ["sh", "-c", "while true; do echo 'collecting metrics'; sleep 30; done"]
          resources:
            requests:
              cpu: 600m
              memory: 128Mi
            limits:
              cpu: 600m
              memory: 128Mi
EOF
    echo "  ✗ Platform telemetry-collector deployed (4 × 600m CPU — fills node headroom)"

    # Wait for filler pods to schedule
    sleep 10

    # Remove HPA so manual scaling simulates ops team response
    kubectl delete hpa amf-hpa -n ${NAMESPACE} 2>/dev/null || true
    echo "  ✗ AMF HPA removed (simulating manual capacity increase)"

    # Scale AMF beyond what remains on the saturated nodes
    kubectl scale deployment amf -n ${NAMESPACE} --replicas=8
    echo "  ✗ AMF scaled to 8 replicas (simulating busy hour demand)"

    # Start UE simulator to show pressure
    kubectl patch deployment ue-simulator -n ${NAMESPACE} \
      -p '{"spec":{"replicas":2}}' 2>/dev/null || true
    echo "  ✓ UE simulator started (mass UE attach in progress)"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ FAILURE INJECTED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  📟 EXPECTED ALARMS (check within 2-3 minutes):"
    echo "     • 5G-Core-AMF-Replicas-Unavailable  (pods can't schedule)"
    echo "     • 5G-Core-Cluster-Node-Capacity-Saturated (node CPU ≥ 80%)"
    echo ""
    echo "  🔍 OBSERVE (once alarms fire):"
    echo "     kubectl get pods -n ${NAMESPACE} -l app=amf"
    echo "     kubectl describe pod <pending-amf-pod> -n ${NAMESPACE}"
    echo ""
    echo "  🤖 AIOps AGENT PROMPT:"
    echo "     \"AMF pods in demo-5g namespace are stuck in Pending state."
    echo "      We're seeing subscriber registration timeouts during peak"
    echo "      busy hour. Investigate why AMF cannot scale.\""
    echo ""
    echo "  🔄 RESTORE: $0 restore"
    echo ""
    ;;

  restore)
    echo "Restoring node pool and AMF scaling..."

    # Remove capacity filler
    kubectl delete deployment telemetry-collector -n ${NAMESPACE} 2>/dev/null || true
    echo "  ✓ Telemetry-collector removed"

    # Restore node pool ceiling
    terraform -chdir="${TF_DIR}" apply \
      -var="app_node_pool_max=3" \
      -target='huaweicloud_cce_node_pool.app' \
      -auto-approve > /dev/null
    echo "  ✓ Node pool restored (max=3)"

    kubectl scale deployment amf -n ${NAMESPACE} --replicas=2
    echo "  ✓ AMF scaled back to 2 replicas"

    kubectl patch deployment ue-simulator -n ${NAMESPACE} \
      -p '{"spec":{"replicas":0}}' 2>/dev/null || true
    echo "  ✓ UE simulator stopped"

    # Restore HPA from manifest
    kubectl apply -f "${SCRIPT_DIR}/../k8s-5g/amf.yaml" 2>/dev/null || true
    echo "  ✓ AMF HPA restored"

    echo ""
    echo "  ✅ Cluster will stabilize within 2-3 minutes."
    echo "     Alarms will return to OK once pods are rescheduled."
    ;;

  *)
    echo "Usage: $0 [inject|restore]"
    exit 1
    ;;
esac

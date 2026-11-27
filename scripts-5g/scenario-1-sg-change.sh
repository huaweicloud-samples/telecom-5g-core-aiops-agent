#!/bin/bash
# =============================================================================
# Scenario 1 (5G): "Who changed the Redis access whitelist?"
#
# Simulates: A team member modifies the DCS Redis access whitelist, blocking
# port 6379 from the CCE pod subnet. NRF loses its Redis backend, causing a
# cascade failure across the entire 5G core.
#
# Failure chain: whitelist restricted → NRF can't reach Redis → NRF returns
# 503 on all discovery requests → AMF/SMF can't discover peers → PDU sessions
# fail network-wide.
#
# Platform note: DCS Redis 4.0+ basic editions do NOT support security groups
# (DCS.4872); access control is via IP whitelists. "inject" enables the
# whitelist with only an unrelated CIDR (simulating someone restricting
# access); "restore" disables the whitelist (VPC-internal access restored).
# Long-lived Redis connections survive whitelist changes — NRF must be
# restarted to force reconnection (mirrors real-world behaviour: whitelist
# applies to new connections only).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# DCS 实例 ID（terraform output）
DCS_INSTANCE=$(tf_output redis_instance_id)
REGION=$(tf_output region)
NAMESPACE="demo-5g"

# 通过华为云 DCS SDK 操作白名单（通过环境变量提供 AK/SK，不落盘）
apply_whitelist() {
  local enable="$1"
  HW_ACCESS_KEY="${HW_ACCESS_KEY:-}" HW_SECRET_KEY="${HW_SECRET_KEY:-}" \
  python3 - "$enable" "$DCS_INSTANCE" <<'PYEOF'
import os, sys
enable = sys.argv[1] == "true"
inst = sys.argv[2]
from huaweicloudsdkcore.auth.credentials import BasicCredentials
from huaweicloudsdkdcs.v2.region.dcs_region import DcsRegion
from huaweicloudsdkdcs.v2.dcs_client import DcsClient
from huaweicloudsdkdcs.v2 import model as m
creds = BasicCredentials(os.environ["HW_ACCESS_KEY"], os.environ["HW_SECRET_KEY"])
client = DcsClient.new_builder().with_credentials(creds).with_region(DcsRegion.value_of("cn-north-4")).build()
body = m.ModifyIpWhitelistBody(
    enable_whitelist=enable,
    whitelist=[m.Whitelist(group_name="fault_inject", ip_list=["192.168.99.0/24"])]
)
client.update_ip_whitelist(m.UpdateIpWhitelistRequest(instance_id=inst, body=body))
print("whitelist enable=" + str(enable))
PYEOF
}

restart_nrf() {
  echo "  ⟳ Restarting NRF to force Redis reconnection..."
  kubectl rollout restart deployment/nrf -n "${NAMESPACE}" > /dev/null
  sleep 30
}

case "${1:-inject}" in
  inject)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  5G SCENARIO 1: Redis Whitelist Change — Connectivity Severed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  DCS instance: ${DCS_INSTANCE}"
    echo "  Enabling whitelist (only 192.168.99.0/24 allowed) — pods can no longer reach Redis:6379"
    echo ""

    apply_whitelist true
    restart_nrf

    echo "  ✗ Restricted: CCE pods → Redis:6379"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ✅ FAILURE INJECTED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  📟 EXPECTED SYMPTOMS (check within 1-2 minutes):"
    echo "     • NRF /health returns 503 (redis connection refused)"
    echo "     • AMF/SMF discovery failures (can't reach NRF)"
    echo ""
    echo "  🔍 OBSERVE (once symptoms appear):"
    echo "     kubectl logs -l nf-type=nrf -n demo-5g --tail=5"
    echo "     kubectl logs -l nf-type=amf -n demo-5g --tail=5"
    echo ""
    echo "  🤖 AIOps AGENT PROMPT:"
    echo "     \"The 5G core NFs in demo-5g namespace are failing to establish"
    echo "      PDU sessions. AMF logs show NRF discovery failures starting"
    echo "      about 1 minute ago. Investigate.\""
    echo ""
    echo "  🔄 RESTORE: $0 restore"
    echo ""
    ;;

  restore)
    echo "Restoring Redis whitelist (disabling)..."
    apply_whitelist false
    restart_nrf

    echo "  ✓ Restored: CCE pods → Redis:6379"
    echo ""
    echo "  ✅ Redis connectivity restored. Restart other NFs to re-register:"
    echo "     kubectl rollout restart deployment/amf deployment/smf deployment/pcf deployment/upf -n demo-5g"
    echo "     NRF will re-register NFs within 30s."
    ;;

  *)
    echo "Usage: $0 [inject|restore]"
    exit 1
    ;;
esac

#!/usr/bin/env bash
# =============================================================================
# prerequisites.sh — Check that all required tools are installed
# (Huawei Cloud port: 命令行工具 → huaweicloud CLI, plus Terraform/kubectl/jq)
#
# Run this BEFORE starting. It checks for required CLI tools and prints install
# instructions for anything missing.
# =============================================================================

PASS="✓"
FAIL="✗"
missing=0

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  5G Core Demo — Prerequisites Check (Huawei Cloud)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

check_tool() {
  local name="$1"
  local cmd="$2"
  local install_mac="$3"
  local install_linux="$4"

  if command -v "$cmd" >/dev/null 2>&1; then
    version=$("$cmd" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+[\.0-9]*' | head -1)
    echo "  ${PASS} ${name} (${version:-installed})"
  else
    echo "  ${FAIL} ${name} — not found"
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "    Install: ${install_mac}"
    else
      echo "    Install: ${install_linux}"
    fi
    missing=$((missing + 1))
  fi
}

echo "▸ Required tools"
echo ""

check_tool "huaweicloud CLI" "hcloud" \
  "brew install huaweicloudcli" \
  "curl -k -L https://obs.cn-north-1.myhuaweicloud.com/cloud-cli/latest/hcloud_install.sh -o ./hcloud_install.sh && bash ./hcloud_install.sh"

check_tool "Terraform" "terraform" \
  "brew install terraform" \
  "sudo apt-get install -y terraform  (or: https://developer.hashicorp.com/terraform/install)"

check_tool "kubectl" "kubectl" \
  "brew install kubectl" \
  "curl -LO \"https://dl.k8s.io/release/\$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\" && sudo install kubectl /usr/local/bin/"

check_tool "jq" "jq" \
  "brew install jq" \
  "sudo apt-get install -y jq"

echo ""

# Check huaweicloud credentials (env vars, consistent with the provider)
echo "▸ Huawei Cloud credentials (env: HW_ACCESS_KEY / HW_SECRET_KEY)"
echo ""
if [[ -n "${HW_ACCESS_KEY:-}" && -n "${HW_SECRET_KEY:-}" ]]; then
  echo "  ${PASS} Credentials found in environment"
else
  echo "  ${FAIL} HW_ACCESS_KEY / HW_SECRET_KEY not set"
  echo "    Run: export HW_ACCESS_KEY=\"...\"  (do NOT hardcode in any file)"
  echo "    Run: export HW_SECRET_KEY=\"...\""
  missing=$((missing + 1))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [[ "${missing}" -eq 0 ]]; then
  echo "  ${PASS} All prerequisites met — ready to start!"
  echo ""
  echo "  Next: cd infra && cp terraform.tfvars.example terraform.tfvars"
  echo "        vi terraform.tfvars   # set domain_name"
  echo "        terraform init && terraform apply"
else
  echo "  ${FAIL} ${missing} item(s) missing — install and re-run"
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""
exit "${missing}"

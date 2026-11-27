#!/bin/bash
# Common helpers for 5G demo scenario scripts (Huawei Cloud)
#
# Environment notes:
#  - hcloud CLI is used for ad-hoc queries
#  - terraform state lives in ../infra
#  - kubectl context is obtained from CCE via deploy.sh

# Verify prerequisites
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform required"; exit 1; }
command -v kubectl    >/dev/null 2>&1 || { echo "ERROR: kubectl required"; exit 1; }
command -v jq         >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }

# Verify kubectl context is set
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "$CURRENT_CONTEXT" ]]; then
  echo "ERROR: No kubectl context set. Run:"
  echo "  ./deploy.sh   (generates CCE kubeconfig and sets the context)"
  exit 1
fi

# Helper: read a terraform output from the infra/ directory
tf_output() {
  local name="$1"
  terraform -chdir="${SCRIPT_DIR}/../infra" output -raw "$name" 2>/dev/null || true
}

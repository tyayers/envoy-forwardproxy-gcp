#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-all}"

clean_dir() {
  local dir="$1"
  rm -rf "${dir}/.terraform" "${dir}"/.terraform* "${dir}"/terraform.tfstate*
}

case "$TARGET" in
  cloud-run)
    echo "Cleaning tf/cloud-run state and caches..."
    clean_dir "./tf/cloud-run"
    ;;
  mig)
    echo "Cleaning tf/mig state and caches..."
    clean_dir "./tf/mig"
    ;;
  all)
    echo "Cleaning tf/cloud-run and tf/mig state and caches..."
    clean_dir "./tf/cloud-run"
    clean_dir "./tf/mig"
    ;;
  *)
    echo "Usage: $0 [cloud-run|mig|all]"
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
REGION="${GOOGLE_CLOUD_LOCATION:?Set GOOGLE_CLOUD_LOCATION}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
NAME="${NAME:-envoy-cr}"
PROXY_CIDR="${PROXY_CIDR:-10.20.2.0/23}"
PSC_NAT_CIDR="${PSC_NAT_CIDR:-10.20.4.0/24}"
VPC_EGRESS="${VPC_EGRESS:-private-ranges-only}"
ACTION="${1:-deploy}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "$ACTION" == "destroy" ]]; then
  echo "Destroying Cloud Run Envoy forward proxy resources in ${PROJECT_ID} (${REGION})..."
  gcloud compute service-attachments delete "${NAME}-psc-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute forwarding-rules delete "${NAME}-ilb-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute addresses delete "${NAME}-ilb-ip-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute target-http-proxies delete "${NAME}-http-proxy-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute url-maps delete "${NAME}-url-map-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute backend-services delete "${NAME}-backend-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute network-endpoint-groups delete "${NAME}-neg-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud run services delete "${NAME}-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute networks subnets delete "${NAME}-psc-nat-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute networks subnets delete "${NAME}-proxy-subnet-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  exit 0
fi

gcloud services enable compute.googleapis.com run.googleapis.com --project="$PROJECT_ID"

EXISTING_PROXY_SUBNET=$(gcloud compute networks subnets list \
  --project="$PROJECT_ID" \
  --network="$NETWORK" \
  --regions="$REGION" \
  --filter="purpose=REGIONAL_MANAGED_PROXY AND role=ACTIVE" \
  --format="value(name)" | head -n 1)

if [[ -z "$EXISTING_PROXY_SUBNET" ]]; then
  gcloud compute networks subnets create "${NAME}-proxy-subnet-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network="$NETWORK" \
    --range="$PROXY_CIDR" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE
fi

if ! gcloud compute networks subnets describe "${NAME}-psc-nat-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute networks subnets create "${NAME}-psc-nat-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network="$NETWORK" \
    --range="$PSC_NAT_CIDR" \
    --purpose=PRIVATE_SERVICE_CONNECT
fi

gcloud run deploy "${NAME}-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --image="docker.io/envoyproxy/envoy:v1.32-latest" \
  --port=8080 \
  --args="^;^--config-yaml;$(cat "${REPO_ROOT}/envoy/envoy.yaml")" \
  --ingress=internal-and-cloud-load-balancing \
  --no-invoker-iam-check \
  --no-default-url \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --vpc-egress="$VPC_EGRESS" \
  --min-instances=0 \
  --max-instances=5

gcloud compute network-endpoint-groups describe "${NAME}-neg-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute network-endpoint-groups create "${NAME}-neg-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --network-endpoint-type=serverless \
  --cloud-run-service="${NAME}-${REGION}"

if ! gcloud compute backend-services describe "${NAME}-backend-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute backend-services create "${NAME}-backend-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --protocol=HTTP

  gcloud compute backend-services add-backend "${NAME}-backend-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network-endpoint-group="${NAME}-neg-${REGION}" \
    --network-endpoint-group-region="$REGION"
fi

gcloud compute url-maps describe "${NAME}-url-map-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute url-maps create "${NAME}-url-map-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --default-service="${NAME}-backend-${REGION}"

gcloud compute target-http-proxies describe "${NAME}-http-proxy-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute target-http-proxies create "${NAME}-http-proxy-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --url-map="${NAME}-url-map-${REGION}" \
  --url-map-region="$REGION"

gcloud compute addresses describe "${NAME}-ilb-ip-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute addresses create "${NAME}-ilb-ip-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --subnet="$SUBNET"

gcloud compute forwarding-rules describe "${NAME}-ilb-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute forwarding-rules create "${NAME}-ilb-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --address="${NAME}-ilb-ip-${REGION}" \
  --ports=80 \
  --target-http-proxy="${NAME}-http-proxy-${REGION}" \
  --target-http-proxy-region="$REGION"

gcloud compute service-attachments describe "${NAME}-psc-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute service-attachments create "${NAME}-psc-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --producer-forwarding-rule="${NAME}-ilb-${REGION}" \
  --connection-preference=ACCEPT_AUTOMATIC \
  --nat-subnets="${NAME}-psc-nat-${REGION}"

echo ""
echo "Service Attachment:"
echo "projects/${PROJECT_ID}/regions/${REGION}/serviceAttachments/${NAME}-psc-${REGION}"

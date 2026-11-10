#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
REGION="${GOOGLE_CLOUD_LOCATION:?Set GOOGLE_CLOUD_LOCATION}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
NAME="${NAME:-envoy-mig}"
PSC_NAT_CIDR="${PSC_NAT_CIDR:-10.20.5.0/24}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"
MIG_SIZE="${MIG_SIZE:-1}"
CREATE_NAT="${CREATE_NAT:-true}"
ACTION="${1:-deploy}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "$ACTION" == "destroy" ]]; then
  echo "Destroying GCE MIG Envoy forward proxy resources in ${PROJECT_ID} (${REGION})..."
  gcloud compute service-attachments delete "${NAME}-psc-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute forwarding-rules delete "${NAME}-ilb-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute addresses delete "${NAME}-ilb-ip-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute backend-services delete "${NAME}-backend-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute instance-groups managed delete "${NAME}-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute instance-templates delete "${NAME}-${REGION}" --project="$PROJECT_ID" --quiet || true
  gcloud compute health-checks delete "${NAME}-hc-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute firewall-rules delete "${NAME}-allow-ingress-${REGION}" --project="$PROJECT_ID" --quiet || true
  gcloud compute routers nats delete "${NAME}-nat-${REGION}" --router="${NAME}-router-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute routers delete "${NAME}-router-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  gcloud compute networks subnets delete "${NAME}-psc-nat-${REGION}" --project="$PROJECT_ID" --region="$REGION" --quiet || true
  exit 0
fi

gcloud services enable compute.googleapis.com --project="$PROJECT_ID"

if [[ "$CREATE_NAT" == "true" ]]; then
  gcloud compute routers describe "${NAME}-router-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
  gcloud compute routers create "${NAME}-router-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --network="$NETWORK"

  gcloud compute routers nats describe "${NAME}-nat-${REGION}" --router="${NAME}-router-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
  gcloud compute routers nats create "${NAME}-nat-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --router="${NAME}-router-${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-custom-subnet-ip-ranges="$SUBNET"
fi

gcloud compute networks subnets describe "${NAME}-psc-nat-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute networks subnets create "${NAME}-psc-nat-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --network="$NETWORK" \
  --range="$PSC_NAT_CIDR" \
  --purpose=PRIVATE_SERVICE_CONNECT

gcloud compute firewall-rules describe "${NAME}-allow-ingress-${REGION}" --project="$PROJECT_ID" >/dev/null 2>&1 || \
gcloud compute firewall-rules create "${NAME}-allow-ingress-${REGION}" \
  --project="$PROJECT_ID" \
  --network="$NETWORK" \
  --allow=tcp:80,tcp:8080 \
  --source-ranges="35.191.0.0/16,130.211.0.0/22,${PSC_NAT_CIDR},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
  --target-tags="${NAME}-${REGION}"

gcloud compute instance-templates describe "${NAME}-${REGION}" --project="$PROJECT_ID" >/dev/null 2>&1 || \
gcloud compute instance-templates create "${NAME}-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --machine-type="$MACHINE_TYPE" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --no-address \
  --image-family=cos-stable \
  --image-project=cos-cloud \
  --tags="${NAME}-${REGION}" \
  --scopes=logging-write,monitoring-write,storage-ro \
  --metadata=google-logging-enabled=true \
  --metadata-from-file="user-data=${REPO_ROOT}/envoy/cloud-init.yaml"

gcloud compute health-checks describe "${NAME}-hc-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute health-checks create http "${NAME}-hc-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --port=8080 \
  --request-path=/healthz

gcloud compute instance-groups managed describe "${NAME}-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute instance-groups managed create "${NAME}-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --base-instance-name="$NAME" \
  --size="$MIG_SIZE" \
  --template="${NAME}-${REGION}" \
  --health-check="projects/${PROJECT_ID}/regions/${REGION}/healthChecks/${NAME}-hc-${REGION}" \
  --initial-delay=120

if ! gcloud compute backend-services describe "${NAME}-backend-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute backend-services create "${NAME}-backend-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --load-balancing-scheme=INTERNAL \
    --protocol=TCP \
    --health-checks="${NAME}-hc-${REGION}" \
    --health-checks-region="$REGION"

  gcloud compute backend-services add-backend "${NAME}-backend-${REGION}" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --instance-group="${NAME}-${REGION}" \
    --instance-group-region="$REGION" \
    --balancing-mode=CONNECTION
fi

gcloud compute addresses describe "${NAME}-ilb-ip-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute addresses create "${NAME}-ilb-ip-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --subnet="$SUBNET"

gcloud compute forwarding-rules describe "${NAME}-ilb-${REGION}" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1 || \
gcloud compute forwarding-rules create "${NAME}-ilb-${REGION}" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --load-balancing-scheme=INTERNAL \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --address="${NAME}-ilb-ip-${REGION}" \
  --ip-protocol=TCP \
  --ports=80,8080 \
  --allow-global-access \
  --backend-service="${NAME}-backend-${REGION}" \
  --backend-service-region="$REGION"

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

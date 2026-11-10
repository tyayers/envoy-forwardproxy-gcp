# Envoy Forward Proxy for Apigee X Southbound PSC

Deploy a private **Envoy dynamic forward proxy** behind an Internal Load Balancer and **Private Service Connect (PSC) Service Attachment** so a single Apigee X Southbound Endpoint Attachment can dynamically reach any HTTP/HTTPS target inside your local VPC.

```text
envoy/
├── envoy.yaml           # Shared Envoy dynamic forward-proxy config (HTTP, HTTPS, CONNECT, /healthz)
└── cloud-init.yaml      # COS cloud-init bundle for direct gcloud MIG deployments
tf/
├── cloud-run/           # Default: Cloud Run (Direct VPC Egress) + Internal ALB + PSC Service Attachment
└── mig/                 # GCE Regional MIG (COS) + Internal Passthrough NLB + PSC Service Attachment
sh/
├── deploy-cloud-run.sh  # Idempotent gcloud deploy/destroy for Cloud Run
├── deploy-mig.sh        # Idempotent gcloud deploy/destroy for GCE MIG
└── tfclean.sh           # Clean local Terraform caches/state
```

Set your project, region, and target VPC/subnet:

```sh
export GOOGLE_CLOUD_PROJECT="your-project-id"
export GOOGLE_CLOUD_LOCATION="us-central1"
export NETWORK="default"
export SUBNET="default"
```

---

## 1. Cloud Run Forward Proxy (Default — Cheapest & Easiest)

Scales to zero (`min_instances=0`), uses **Direct VPC Egress** (no VPC Access Connector VMs), and exposes Envoy privately via an Internal Application Load Balancer and PSC Service Attachment.

### Deploy with Terraform (`tf/cloud-run`)

```sh
terraform -chdir=tf/cloud-run init
terraform -chdir=tf/cloud-run apply \
  -var "project_id=$GOOGLE_CLOUD_PROJECT" \
  -var "region=$GOOGLE_CLOUD_LOCATION" \
  -var "network=$NETWORK" \
  -var "subnet=$SUBNET"

export SERVICE_ATTACHMENT=$(terraform -chdir=tf/cloud-run output -raw service_attachment)
```

> Add `-var "create_network=true"` if deploying into a new VPC, or `-var "create_proxy_subnet=false"` if your VPC already has an active `REGIONAL_MANAGED_PROXY` subnet in `$GOOGLE_CLOUD_LOCATION`.

### Deploy with `gcloud`

Run `./sh/deploy-cloud-run.sh`, or run the `gcloud` commands directly from the repository root:

```sh
gcloud services enable compute.googleapis.com run.googleapis.com \
  --project="$GOOGLE_CLOUD_PROJECT"

# Skip proxy-subnet creation if your VPC already has an ACTIVE REGIONAL_MANAGED_PROXY subnet in the region
gcloud compute networks subnets create "envoy-cr-proxy-subnet-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network="$NETWORK" --range="10.20.2.0/23" \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE

gcloud compute networks subnets create "envoy-cr-psc-nat-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network="$NETWORK" --range="10.20.4.0/24" \
  --purpose=PRIVATE_SERVICE_CONNECT

gcloud run deploy "envoy-cr-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --image="docker.io/envoyproxy/envoy:v1.32-latest" \
  --port=8080 \
  --args="^;^--config-yaml;$(cat envoy/envoy.yaml)" \
  --ingress=internal-and-cloud-load-balancing \
  --no-invoker-iam-check --no-default-url \
  --network="$NETWORK" --subnet="$SUBNET" \
  --vpc-egress=private-ranges-only \
  --min-instances=0 --max-instances=5

gcloud compute network-endpoint-groups create "envoy-cr-neg-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network-endpoint-type=serverless \
  --cloud-run-service="envoy-cr-$GOOGLE_CLOUD_LOCATION"

gcloud compute backend-services create "envoy-cr-backend-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --load-balancing-scheme=INTERNAL_MANAGED --protocol=HTTP

gcloud compute backend-services add-backend "envoy-cr-backend-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network-endpoint-group="envoy-cr-neg-$GOOGLE_CLOUD_LOCATION" \
  --network-endpoint-group-region="$GOOGLE_CLOUD_LOCATION"

gcloud compute url-maps create "envoy-cr-url-map-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --default-service="envoy-cr-backend-$GOOGLE_CLOUD_LOCATION"

gcloud compute target-http-proxies create "envoy-cr-http-proxy-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --url-map="envoy-cr-url-map-$GOOGLE_CLOUD_LOCATION" \
  --url-map-region="$GOOGLE_CLOUD_LOCATION"

gcloud compute addresses create "envoy-cr-ilb-ip-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --subnet="$SUBNET"

gcloud compute forwarding-rules create "envoy-cr-ilb-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --network="$NETWORK" --subnet="$SUBNET" \
  --address="envoy-cr-ilb-ip-$GOOGLE_CLOUD_LOCATION" --ports=80 \
  --target-http-proxy="envoy-cr-http-proxy-$GOOGLE_CLOUD_LOCATION" \
  --target-http-proxy-region="$GOOGLE_CLOUD_LOCATION"

gcloud compute service-attachments create "envoy-cr-psc-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --producer-forwarding-rule="envoy-cr-ilb-$GOOGLE_CLOUD_LOCATION" \
  --connection-preference=ACCEPT_AUTOMATIC \
  --nat-subnets="envoy-cr-psc-nat-$GOOGLE_CLOUD_LOCATION"

export SERVICE_ATTACHMENT="projects/$GOOGLE_CLOUD_PROJECT/regions/$GOOGLE_CLOUD_LOCATION/serviceAttachments/envoy-cr-psc-$GOOGLE_CLOUD_LOCATION"
```

---

## 2. GCE MIG Forward Proxy

Runs Envoy on Container-Optimized OS (`cos-stable`) in a Regional Managed Instance Group behind an L4 Internal Passthrough Network Load Balancer and PSC Service Attachment.

### Deploy with Terraform (`tf/mig`)

```sh
terraform -chdir=tf/mig init
terraform -chdir=tf/mig apply \
  -var "project_id=$GOOGLE_CLOUD_PROJECT" \
  -var "region=$GOOGLE_CLOUD_LOCATION" \
  -var "network=$NETWORK" \
  -var "subnet=$SUBNET"

export SERVICE_ATTACHMENT=$(terraform -chdir=tf/mig output -raw service_attachment)
```

> Add `-var "create_network=true"` for a new VPC, or `-var "create_nat=false"` if `$SUBNET` already has Cloud NAT in `$GOOGLE_CLOUD_LOCATION`.

### Deploy with `gcloud`

Run `./sh/deploy-mig.sh`, or run the `gcloud` commands directly from the repository root:

```sh
gcloud services enable compute.googleapis.com --project="$GOOGLE_CLOUD_PROJECT"

# Skip router/NAT creation if your subnet already has Cloud NAT in the region
gcloud compute routers create "envoy-mig-router-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network="$NETWORK"

gcloud compute routers nats create "envoy-mig-nat-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --router="envoy-mig-router-$GOOGLE_CLOUD_LOCATION" \
  --auto-allocate-nat-external-ips \
  --nat-custom-subnet-ip-ranges="$SUBNET"

gcloud compute networks subnets create "envoy-mig-psc-nat-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --network="$NETWORK" --range="10.20.5.0/24" \
  --purpose=PRIVATE_SERVICE_CONNECT

gcloud compute firewall-rules create "envoy-mig-allow-ingress-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --network="$NETWORK" \
  --allow=tcp:80,tcp:8080 \
  --source-ranges="35.191.0.0/16,130.211.0.0/22,10.20.5.0/24,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
  --target-tags="envoy-mig-$GOOGLE_CLOUD_LOCATION"

gcloud compute instance-templates create "envoy-mig-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --machine-type=e2-micro --network="$NETWORK" --subnet="$SUBNET" --no-address \
  --image-family=cos-stable --image-project=cos-cloud \
  --tags="envoy-mig-$GOOGLE_CLOUD_LOCATION" \
  --scopes=logging-write,monitoring-write,storage-ro \
  --metadata=google-logging-enabled=true \
  --metadata-from-file="user-data=envoy/cloud-init.yaml"

gcloud compute health-checks create http "envoy-mig-hc-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --port=8080 --request-path=/healthz

gcloud compute instance-groups managed create "envoy-mig-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --base-instance-name=envoy-mig --size=1 \
  --template="envoy-mig-$GOOGLE_CLOUD_LOCATION" \
  --health-check="projects/$GOOGLE_CLOUD_PROJECT/regions/$GOOGLE_CLOUD_LOCATION/healthChecks/envoy-mig-hc-$GOOGLE_CLOUD_LOCATION" \
  --initial-delay=120

gcloud compute backend-services create "envoy-mig-backend-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --load-balancing-scheme=INTERNAL --protocol=TCP \
  --health-checks="envoy-mig-hc-$GOOGLE_CLOUD_LOCATION" \
  --health-checks-region="$GOOGLE_CLOUD_LOCATION"

gcloud compute backend-services add-backend "envoy-mig-backend-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --instance-group="envoy-mig-$GOOGLE_CLOUD_LOCATION" \
  --instance-group-region="$GOOGLE_CLOUD_LOCATION" \
  --balancing-mode=CONNECTION

gcloud compute addresses create "envoy-mig-ilb-ip-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --subnet="$SUBNET"

gcloud compute forwarding-rules create "envoy-mig-ilb-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --load-balancing-scheme=INTERNAL --ip-protocol=TCP --ports=80,8080 \
  --network="$NETWORK" --subnet="$SUBNET" \
  --address="envoy-mig-ilb-ip-$GOOGLE_CLOUD_LOCATION" \
  --allow-global-access \
  --backend-service="envoy-mig-backend-$GOOGLE_CLOUD_LOCATION" \
  --backend-service-region="$GOOGLE_CLOUD_LOCATION"

gcloud compute service-attachments create "envoy-mig-psc-$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" --region="$GOOGLE_CLOUD_LOCATION" \
  --producer-forwarding-rule="envoy-mig-ilb-$GOOGLE_CLOUD_LOCATION" \
  --connection-preference=ACCEPT_AUTOMATIC \
  --nat-subnets="envoy-mig-psc-nat-$GOOGLE_CLOUD_LOCATION"

export SERVICE_ATTACHMENT="projects/$GOOGLE_CLOUD_PROJECT/regions/$GOOGLE_CLOUD_LOCATION/serviceAttachments/envoy-mig-psc-$GOOGLE_CLOUD_LOCATION"
```

---

## 3. Add Service Attachment in Apigee X & Route Traffic

### Register the Endpoint Attachment in Apigee X

Pass `-var "create_apigee_endpoint_attachment=true"` during `terraform apply`, or create it via the Apigee API:

```sh
export APIGEE_ORG="$GOOGLE_CLOUD_PROJECT"

curl -fsS -X POST \
  "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/endpointAttachments?endpointAttachmentId=envoy-psc-$GOOGLE_CLOUD_LOCATION" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d "{
    \"location\": \"$GOOGLE_CLOUD_LOCATION\",
    \"serviceAttachment\": \"$SERVICE_ATTACHMENT\"
  }"

# Retrieve the private PSC IP assigned inside Apigee X (wait until connectionState is ACCEPTED)
export ENDPOINT_HOST=$(curl -fsS \
  "https://apigee.googleapis.com/v1/organizations/$APIGEE_ORG/endpointAttachments/envoy-psc-$GOOGLE_CLOUD_LOCATION" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" | jq -r '.host')
echo "Apigee PSC Target Host: $ENDPOINT_HOST"
```

### Forward Apigee Proxy Traffic into Your VPC

Point your Apigee `TargetEndpoint` at `http://<ENDPOINT_HOST>` and set `X-Target-Host` to any private IP, internal DNS name (`*.internal` / Cloud DNS private zone), or `https://` target reachable from the Envoy VPC:

```xml
<!-- apiproxy/policies/AM-SetTargetHost.xml -->
<AssignMessage name="AM-SetTargetHost">
  <Set>
    <Headers>
      <!-- Examples: 10.128.0.5:8080, my-svc.corp.internal:8080, or https://internal-api.corp.internal -->
      <Header name="X-Target-Host">10.128.0.5:8080</Header>
    </Headers>
  </Set>
</AssignMessage>
```

```xml
<!-- apiproxy/targets/default.xml -->
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request>
      <Step><Name>AM-SetTargetHost</Name></Step>
    </Request>
  </PreFlow>
  <HTTPTargetConnection>
    <URL>http://REPLACE_WITH_ENDPOINT_HOST</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
```

> Envoy resolves `X-Target-Host` via VPC DNS, strips `X-Target-Host` / `X-Target-Scheme`, rewrites `Host` (`:authority`), and forwards HTTP or HTTPS traffic into the local VPC.

---

## Teardown

```sh
# Terraform (Cloud Run or MIG)
terraform -chdir=tf/cloud-run destroy -var "project_id=$GOOGLE_CLOUD_PROJECT" -var "region=$GOOGLE_CLOUD_LOCATION"
terraform -chdir=tf/mig destroy -var "project_id=$GOOGLE_CLOUD_PROJECT" -var "region=$GOOGLE_CLOUD_LOCATION"

# gcloud scripts
./sh/deploy-cloud-run.sh destroy
./sh/deploy-mig.sh destroy
```

---

## Terraform Variables

| Variable | Default | Used In | Description |
|---|---|---|---|
| `project_id` | *(required)* | Both | GCP Project ID |
| `region` | *(required)* | Both | GCP region |
| `network` | `"default"` | Both | Existing VPC network (when `create_network=false`) |
| `subnet` | `"default"` | Both | Existing VPC subnet (when `create_network=false`) |
| `create_network` | `false` | Both | Auto-create a dedicated VPC and subnet |
| `psc_subnet` | `null` | Both | Existing `PRIVATE_SERVICE_CONNECT` subnet (auto-created if `null`) |
| `psc_nat_cidr_range` | `10.20.4.0/24` / `10.20.5.0/24` | Both | PSC NAT subnet CIDR when `psc_subnet=null` |
| `create_proxy_subnet` | `true` | `cloud-run` | Create `REGIONAL_MANAGED_PROXY` subnet (`false` if VPC already has one) |
| `vpc_egress` | `"PRIVATE_RANGES_ONLY"` | `cloud-run` | Direct VPC Egress mode (`PRIVATE_RANGES_ONLY` or `ALL_TRAFFIC`) |
| `create_nat` | `true` | `mig` | Create Cloud Router + Cloud NAT for private MIG instances |
| `machine_type` | `"e2-micro"` | `mig` | Compute Engine machine type |
| `mig_size` | `1` | `mig` | Regional MIG instance count |
| `create_apigee_endpoint_attachment` | `false` | Both | Also create the `EndpointAttachment` in Apigee X |

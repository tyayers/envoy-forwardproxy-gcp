locals {
  network_id = var.create_network ? google_compute_network.vpc[0].id : (
    can(regex("/", var.network)) ? var.network : "projects/${var.project_id}/global/networks/${var.network}"
  )
  subnet_id = var.create_network ? google_compute_subnetwork.subnet[0].id : (
    can(regex("/", var.subnet)) ? var.subnet : "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.subnet}"
  )
  network_name = element(reverse(split("/", local.network_id)), 0)
  subnet_name  = element(reverse(split("/", local.subnet_id)), 0)

  psc_subnet_id = var.psc_subnet != null ? (
    can(regex("/", var.psc_subnet)) ? var.psc_subnet : "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.psc_subnet}"
  ) : google_compute_subnetwork.psc_nat[0].id

  is_drz          = var.drz_location != null && var.drz_location != "" && lower(var.drz_location) != "global"
  apigee_endpoint = local.is_drz ? "https://${lower(var.drz_location)}-apigee.googleapis.com/v1/" : "https://apigee.googleapis.com/v1/"
  apigee_org_id   = coalesce(var.apigee_org_id, "organizations/${var.project_id}")
}

provider "google" {
  project                = var.project_id
  region                 = var.region
  apigee_custom_endpoint = local.apigee_endpoint
}

resource "google_project_service" "apis" {
  for_each           = toset(["compute.googleapis.com", "run.googleapis.com"])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

/* Optional VPC & Primary Subnet */

resource "google_compute_network" "vpc" {
  count                   = var.create_network ? 1 : 0
  name                    = "${var.name}-vpc-${var.region}"
  auto_create_subnetworks = false
  project                 = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  count                    = var.create_network ? 1 : 0
  name                     = "${var.name}-subnet-${var.region}"
  ip_cidr_range            = var.subnet_cidr_range
  region                   = var.region
  network                  = google_compute_network.vpc[0].id
  private_ip_google_access = true
  project                  = var.project_id
}

/* Regional Proxy-Only Subnet (for Internal Application Load Balancer) */

resource "google_compute_subnetwork" "proxy_subnet" {
  count         = var.create_proxy_subnet ? 1 : 0
  name          = "${var.name}-proxy-subnet-${var.region}"
  ip_cidr_range = var.proxy_subnet_cidr_range
  region        = var.region
  network       = local.network_id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  project       = var.project_id

  depends_on = [google_project_service.apis]
}

/* PSC NAT Subnet (for Service Attachment) */

resource "google_compute_subnetwork" "psc_nat" {
  count         = var.psc_subnet == null ? 1 : 0
  name          = "${var.name}-psc-nat-${var.region}"
  ip_cidr_range = var.psc_nat_cidr_range
  region        = var.region
  network       = local.network_id
  purpose       = "PRIVATE_SERVICE_CONNECT"
  project       = var.project_id

  depends_on = [google_project_service.apis]
}

/* Cloud Run Envoy Forward Proxy (Direct VPC Egress) */

resource "google_cloud_run_v2_service" "envoy" {
  name                 = "${var.name}-${var.region}"
  location             = var.region
  project              = var.project_id
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  invoker_iam_disabled = true
  default_uri_disabled = true
  deletion_protection  = false

  template {
    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    vpc_access {
      egress = var.vpc_egress
      network_interfaces {
        network    = local.network_name
        subnetwork = local.subnet_name
      }
    }

    containers {
      image = var.envoy_image
      args  = ["--config-yaml", file("${path.module}/../../envoy/envoy.yaml")]

      ports {
        container_port = 8080
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_compute_subnetwork.subnet,
  ]
}

/* Regional Internal Application Load Balancer + Serverless NEG */

resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "${var.name}-neg-${var.region}"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.envoy.name
  }
}

resource "google_compute_region_backend_service" "ilb_backend" {
  name                  = "${var.name}-backend-${var.region}"
  region                = var.region
  project               = var.project_id
  protocol              = "HTTP"
  load_balancing_scheme = "INTERNAL_MANAGED"

  backend {
    group          = google_compute_region_network_endpoint_group.serverless_neg.id
    balancing_mode = ""
  }
}

resource "google_compute_region_url_map" "ilb_url_map" {
  name            = "${var.name}-url-map-${var.region}"
  region          = var.region
  project         = var.project_id
  default_service = google_compute_region_backend_service.ilb_backend.id
}

resource "google_compute_region_target_http_proxy" "ilb_proxy" {
  name    = "${var.name}-http-proxy-${var.region}"
  region  = var.region
  project = var.project_id
  url_map = google_compute_region_url_map.ilb_url_map.id
}

resource "google_compute_address" "ilb_ip" {
  name         = "${var.name}-ilb-ip-${var.region}"
  region       = var.region
  project      = var.project_id
  address_type = "INTERNAL"
  subnetwork   = local.subnet_id
}

resource "google_compute_forwarding_rule" "ilb" {
  name                  = "${var.name}-ilb-${var.region}"
  region                = var.region
  project               = var.project_id
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.ilb_proxy.id
  network               = local.network_id
  subnetwork            = local.subnet_id
  ip_address            = google_compute_address.ilb_ip.address

  depends_on = [google_compute_subnetwork.proxy_subnet]
}

/* Private Service Connect Service Attachment */

resource "google_compute_service_attachment" "envoy_psc" {
  name                  = "${var.name}-psc-${var.region}"
  region                = var.region
  project               = var.project_id
  description           = "PSC Service Attachment for Cloud Run Envoy forward proxy"
  enable_proxy_protocol = false
  connection_preference = "ACCEPT_AUTOMATIC"
  nat_subnets           = [local.psc_subnet_id]
  target_service        = google_compute_forwarding_rule.ilb.id
}

/* Optional Apigee X Endpoint Attachment */

resource "google_apigee_endpoint_attachment" "apigee_psc" {
  count                  = var.create_apigee_endpoint_attachment ? 1 : 0
  org_id                 = local.apigee_org_id
  endpoint_attachment_id = "${var.name}-${var.region}"
  location               = var.region
  service_attachment     = google_compute_service_attachment.envoy_psc.id
}

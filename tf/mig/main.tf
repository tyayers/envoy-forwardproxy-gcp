locals {
  network_id = var.create_network ? google_compute_network.vpc[0].id : (
    can(regex("/", var.network)) ? var.network : "projects/${var.project_id}/global/networks/${var.network}"
  )
  subnet_id = var.create_network ? google_compute_subnetwork.subnet[0].id : (
    can(regex("/", var.subnet)) ? var.subnet : "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.subnet}"
  )

  psc_subnet_id = var.psc_subnet != null ? (
    can(regex("/", var.psc_subnet)) ? var.psc_subnet : "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.psc_subnet}"
  ) : google_compute_subnetwork.psc_nat[0].id

  instance_tag    = "${var.name}-${var.region}"
  is_drz          = var.drz_location != null && var.drz_location != "" && lower(var.drz_location) != "global"
  apigee_endpoint = local.is_drz ? "https://${lower(var.drz_location)}-apigee.googleapis.com/v1/" : "https://apigee.googleapis.com/v1/"
  apigee_org_id   = coalesce(var.apigee_org_id, "organizations/${var.project_id}")
}

provider "google" {
  project                = var.project_id
  region                 = var.region
  apigee_custom_endpoint = local.apigee_endpoint
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

/* Optional VPC, Subnet, and Cloud NAT */

resource "google_compute_network" "vpc" {
  count                   = var.create_network ? 1 : 0
  name                    = "${var.name}-vpc-${var.region}"
  auto_create_subnetworks = false
  project                 = var.project_id

  depends_on = [google_project_service.compute]
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

resource "google_compute_router" "router" {
  count   = var.create_nat ? 1 : 0
  name    = "${var.name}-router-${var.region}"
  region  = var.region
  network = local.network_id
  project = var.project_id

  depends_on = [google_project_service.compute]
}

resource "google_compute_router_nat" "nat" {
  count                              = var.create_nat ? 1 : 0
  name                               = "${var.name}-nat-${var.region}"
  router                             = google_compute_router.router[0].name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = local.subnet_id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
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

  depends_on = [google_project_service.compute]
}

/* Firewall: Allow GCP Health Checks, PSC NAT, and Internal VPC Traffic to Envoy MIG */

resource "google_compute_firewall" "envoy_ingress" {
  name      = "${var.name}-allow-ingress-${var.region}"
  network   = local.network_id
  project   = var.project_id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }

  source_ranges = distinct([
    "35.191.0.0/16",
    "130.211.0.0/22",
    var.psc_nat_cidr_range,
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
  ])

  target_tags = [local.instance_tag]

  depends_on = [google_project_service.compute]
}

/* Envoy Regional MIG (Container-Optimized OS + cloud-init) */

resource "google_compute_region_instance_template" "envoy" {
  name_prefix  = "${var.name}-${var.region}-"
  region       = var.region
  project      = var.project_id
  machine_type = var.machine_type
  tags         = [local.instance_tag]

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
  }

  network_interface {
    network    = local.network_id
    subnetwork = local.subnet_id
  }

  metadata = {
    google-logging-enabled = "true"
    user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      envoy_config = trimspace(file("${path.module}/../../envoy/envoy.yaml"))
      envoy_image  = var.envoy_image
    })
  }

  service_account {
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.metricWriter",
      "https://www.googleapis.com/auth/devstorage.read_only",
    ]
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_project_service.compute]
}

resource "google_compute_region_health_check" "envoy" {
  name    = "${var.name}-hc-${var.region}"
  region  = var.region
  project = var.project_id

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }

  depends_on = [google_project_service.compute]
}

resource "google_compute_region_instance_group_manager" "envoy" {
  name               = "${var.name}-${var.region}"
  base_instance_name = var.name
  region             = var.region
  project            = var.project_id
  target_size        = var.mig_size

  version {
    instance_template = google_compute_region_instance_template.envoy.id
  }

  auto_healing_policies {
    health_check      = google_compute_region_health_check.envoy.id
    initial_delay_sec = 120
  }

  depends_on = [google_compute_router_nat.nat]
}

/* Internal Passthrough Network Load Balancer */

resource "google_compute_region_backend_service" "ilb_backend" {
  name                  = "${var.name}-backend-${var.region}"
  region                = var.region
  project               = var.project_id
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_region_health_check.envoy.id]

  backend {
    group          = google_compute_region_instance_group_manager.envoy.instance_group
    balancing_mode = "CONNECTION"
  }
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
  load_balancing_scheme = "INTERNAL"
  ports                 = ["80", "8080"]
  backend_service       = google_compute_region_backend_service.ilb_backend.id
  network               = local.network_id
  subnetwork            = local.subnet_id
  ip_address            = google_compute_address.ilb_ip.address
  allow_global_access   = true
}

/* Private Service Connect Service Attachment */

resource "google_compute_service_attachment" "envoy_psc" {
  name                  = "${var.name}-psc-${var.region}"
  region                = var.region
  project               = var.project_id
  description           = "PSC Service Attachment for GCE MIG Envoy forward proxy"
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

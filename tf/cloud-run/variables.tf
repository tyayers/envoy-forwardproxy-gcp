variable "project_id" {
  description = "GCP Project ID."
  type        = string
}

variable "region" {
  description = "GCP region for Cloud Run, Internal Load Balancer, and PSC Service Attachment."
  type        = string
}

variable "name" {
  description = "Resource name prefix."
  type        = string
  default     = "envoy-cr"
}

variable "create_network" {
  description = "Create a new VPC network and primary subnet instead of using an existing VPC."
  type        = bool
  default     = false
}

variable "network" {
  description = "Existing VPC network name or ID when create_network is false."
  type        = string
  default     = "default"
}

variable "subnet" {
  description = "Existing VPC subnetwork name or ID when create_network is false."
  type        = string
  default     = "default"
}

variable "subnet_cidr_range" {
  description = "Primary subnet CIDR range when create_network is true."
  type        = string
  default     = "10.20.0.0/24"
}

variable "create_proxy_subnet" {
  description = "Create a regional proxy-only subnet (purpose=REGIONAL_MANAGED_PROXY). Set false if the VPC already has an ACTIVE proxy-only subnet in the region."
  type        = bool
  default     = true
}

variable "proxy_subnet_cidr_range" {
  description = "CIDR range for the regional proxy-only subnet when create_proxy_subnet is true."
  type        = string
  default     = "10.20.2.0/23"
}

variable "psc_subnet" {
  description = "Optional existing PSC NAT subnet name or ID (purpose=PRIVATE_SERVICE_CONNECT). If null, one is created."
  type        = string
  default     = null
}

variable "psc_nat_cidr_range" {
  description = "CIDR range for the PSC NAT subnet when psc_subnet is null."
  type        = string
  default     = "10.20.4.0/24"
}

variable "vpc_egress" {
  description = "Cloud Run Direct VPC Egress mode: 'PRIVATE_RANGES_ONLY' (default, no Cloud NAT needed) or 'ALL_TRAFFIC'."
  type        = string
  default     = "PRIVATE_RANGES_ONLY"

  validation {
    condition     = contains(["PRIVATE_RANGES_ONLY", "ALL_TRAFFIC"], var.vpc_egress)
    error_message = "Allowed values for vpc_egress are 'PRIVATE_RANGES_ONLY' or 'ALL_TRAFFIC'."
  }
}

variable "envoy_image" {
  description = "Envoy container image."
  type        = string
  default     = "docker.io/envoyproxy/envoy:v1.32-latest"
}

variable "min_instances" {
  description = "Minimum Cloud Run container instances (0 scales to zero)."
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum Cloud Run container instances."
  type        = number
  default     = 5
}

variable "create_apigee_endpoint_attachment" {
  description = "Optionally create the Apigee X EndpointAttachment in the target Apigee organization."
  type        = bool
  default     = false
}

variable "apigee_org_id" {
  description = "Optional Apigee Organization ID (defaults to 'organizations/<project_id>' when create_apigee_endpoint_attachment is true)."
  type        = string
  default     = null
}

variable "drz_location" {
  description = "Optional Apigee Data Residency Zone ('eu', 'us', 'in') or null for global."
  type        = string
  default     = null
}

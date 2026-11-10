variable "project_id" {
  description = "GCP Project ID."
  type        = string
}

variable "region" {
  description = "GCP region for the MIG, Internal Load Balancer, and PSC Service Attachment."
  type        = string
}

variable "name" {
  description = "Resource name prefix."
  type        = string
  default     = "envoy-mig"
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
  default     = "10.20.1.0/24"
}

variable "psc_subnet" {
  description = "Optional existing PSC NAT subnet name or ID (purpose=PRIVATE_SERVICE_CONNECT). If null, one is created."
  type        = string
  default     = null
}

variable "psc_nat_cidr_range" {
  description = "CIDR range for the PSC NAT subnet when psc_subnet is null."
  type        = string
  default     = "10.20.5.0/24"
}

variable "create_nat" {
  description = "Create a Cloud Router and Cloud NAT for the target subnet so private MIG instances can pull the Envoy image. Set false if the VPC already has Cloud NAT in this region."
  type        = bool
  default     = true
}

variable "machine_type" {
  description = "Compute Engine machine type for Envoy MIG instances."
  type        = string
  default     = "e2-micro"
}

variable "mig_size" {
  description = "Number of instances in the Regional Managed Instance Group."
  type        = number
  default     = 1
}

variable "envoy_image" {
  description = "Envoy container image."
  type        = string
  default     = "docker.io/envoyproxy/envoy:v1.32-latest"
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

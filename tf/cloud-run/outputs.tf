output "service_attachment" {
  description = "PSC Service Attachment URI to register as an Endpoint Attachment in Apigee X."
  value       = "projects/${var.project_id}/regions/${var.region}/serviceAttachments/${google_compute_service_attachment.envoy_psc.name}"
}

output "ilb_ip_address" {
  description = "Internal Load Balancer IP address in the target VPC."
  value       = google_compute_address.ilb_ip.address
}

output "cloud_run_service" {
  description = "Cloud Run Envoy forward-proxy service name."
  value       = google_cloud_run_v2_service.envoy.name
}

output "network" {
  description = "Target VPC network."
  value       = local.network_id
}

output "subnet" {
  description = "Target VPC subnetwork."
  value       = local.subnet_id
}

output "apigee_endpoint_attachment_host" {
  description = "Apigee X Endpoint Attachment target host/IP (when create_apigee_endpoint_attachment is true)."
  value       = try(google_apigee_endpoint_attachment.apigee_psc[0].host, null)
}

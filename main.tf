/**
 * # GKE Autopilot cluster deployment demo
 *
 * The Terraform code provided in this file serves as a foundation for creating a landing zone within the Google Cloud Platform (GCP) environment.
 *
 * The code encompasses the orchestration of essential components, including the creation of a Google Cloud Project, establishment of the network infrastructure, and deployment of a Google Kubernetes Engine (GKE) cluster.i
 *
 * Leveraging Infrastructure as Code (IaC) principles, this Terraform script ensures consistency, repeatability, and version control for the entire landing zone setup.
 *
 * The modular structure of the code allows for easy customization and scalability, accommodating various configurations to meet specific project requirements. Whether deploying a new landing zone or updating an existing one, this Terraform code streamlines the process, providing a comprehensive and efficient solution for managing the GCP landing zone's foundational elements. Refer to the accompanying documentation for detailed instructions on utilizing and adapting the Terraform code to suit your organization's needs.
 *
 * ![](docs/architecture.png)
 */

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

data "google_client_config" "default" {}

variable "env" {
  type        = string
  description = "Environment name for the landing zone"
}

variable "billing_account" {
  description = "Billing account used by the GCP project"
  default     = "01097E-D138F9-1AE94C"
}

variable "region" {
  description = "Region used to deploy GCP resources"
  default     = "europe-west1"
}

## Project
resource "random_string" "project_id" {
  length  = 6
  special = false
}

resource "google_project" "project" {
  name       = format("%s-project", var.env)
  project_id = format("%s-%s", var.env, lower(random_string.project_id.result))

  folder_id           = "578947305407"
  billing_account     = var.billing_account
  auto_create_network = false
}

## Network
resource "google_project_service" "compute" {
  project = google_project.project.project_id

  service            = "compute.googleapis.com"
  disable_on_destroy = "false"
}

resource "google_compute_network" "network" {
  name    = format("demo-gke-%s", var.env)
  project = google_project.project.project_id

  auto_create_subnetworks = false

  depends_on = [
    google_project_service.compute,
  ]
}

## Firewall
resource "google_compute_firewall" "cloud-icmp" {
  name    = "cloud-ingress-icmp-rfc1918"
  project = google_project.project.project_id

  network   = google_compute_network.network.self_link
  priority  = 900
  direction = "INGRESS"

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]
}

resource "google_compute_firewall" "cloud-allow-internal" {
  name    = "cloud-ingress-tcp-rfc1918"
  project = google_project.project.project_id

  network = google_compute_network.network.self_link

  priority  = 1000
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = [80]
  }

  source_ranges = ["10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]
}

resource "google_compute_firewall" "cloud-iap-tcp" {
  name    = "cloud-ingress-tcp-iap"
  project = google_project.project.project_id

  network   = google_compute_network.network.self_link
  priority  = 900
  direction = "INGRESS"


  allow {
    protocol = "tcp"
  }

  source_ranges = ["35.235.240.0/20"]
}



## Cloud nat
resource "google_compute_subnetwork" "nat" {
  name    = "${var.env}-nat-subnetwork"
  project = google_project.project.project_id

  ip_cidr_range            = "192.168.0.0/24"
  region                   = var.region
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}


resource "google_compute_router" "router" {
  name    = "egress"
  project = google_project.project.project_id

  region  = google_compute_subnetwork.nat.region
  network = google_compute_network.network.id
}

resource "google_compute_router_nat" "nat" {
  name    = "nat"
  project = google_project.project.project_id

  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}


resource "google_compute_subnetwork" "gke" {
  name    = "${var.env}-subnetwork"
  project = google_project.project.project_id

  ip_cidr_range            = "192.168.1.0/24"
  region                   = var.region
  network                  = google_compute_network.network.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.0.0.0/14"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.4.0.0/19"
  }
}

resource "google_project_service" "container" {
  project = google_project.project.project_id

  service            = "container.googleapis.com"
  disable_on_destroy = "false"
}

resource "google_container_cluster" "cluster" {
  name    = "${var.env}-gke"
  project = google_project.project.project_id

  location = var.region

  network    = google_compute_network.network.self_link
  subnetwork = google_compute_subnetwork.gke.self_link

  # Enabling Autopilot for this cluster
  enable_autopilot    = true
  deletion_protection = false

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  depends_on = [google_project_service.container]
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.cluster.master_auth.0.cluster_ca_certificate)
}

resource "kubernetes_namespace" "customer" {
  metadata {
    annotations = {
      name = "customer"
    }

    labels = {
      usage = "customer"
    }

    name = "customer"
  }
}

resource "kubernetes_limit_range" "example" {
  metadata {
    name      = "default-limits"
    namespace = kubernetes_namespace.customer.metadata[0].name
  }
  spec {
    limit {
      type = "Pod"
      max = {
        cpu    = "200m"
        memory = "1024Mi"
      }
    }
    limit {
      type = "PersistentVolumeClaim"
      min = {
        storage = "24M"
      }
    }
    limit {
      type = "Container"
      default = {
        cpu    = "50m"
        memory = "24Mi"
      }
    }
  }
}

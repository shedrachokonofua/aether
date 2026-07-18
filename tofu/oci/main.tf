# Offsite Oracle Cloud (ca-toronto-1) estate resources.
#
# Parity with tofu/google/: tls key + local_file into secrets/, provider-prefixed
# outputs consumed via tf_outputs in the ansible inventory.
#
# Auth is keyless: the root provider uses OCI session-token (`auth = "SecurityToken"`,
# profile oci-aether). `task login` mints it via Keycloak->UPST token-exchange
# (federation.tf); `oci session authenticate` is only the one-time bootstrap for the
# first-ever apply. No static API signing key is committed.
#
# Boxes:
#   aether-adguard-secondary  VM.Standard.E2.1.Micro (x86, Always-Free)  -> offsite AdGuard
#   aether-oci-a1             VM.Standard.A1.Flex 2 OCPU / 12 GB (ARM, Always-Free) -> bare workhorse
#                             (Oracle cut the A1 Always-Free allowance from 4/24 to
#                             2/12 on 2026-06-15; 4/24 on PAYG would bill ~$28/mo)
#
# Network exposure: security list opens only TCP/22 (key-only bootstrap; tighten to the
# home WAN once WireGuard is up) and UDP/51820 (direct home<->OCI WireGuard peer). :53 and
# service ports are filtered at the host firewall on the wg interface, NOT here — an OCI
# security list only sees the outer VCN packet, never the tunneled inner traffic.

terraform {
  required_providers {
    oci   = { source = "oracle/oci" }
    tls   = { source = "hashicorp/tls" }
    local = { source = "hashicorp/local" }
  }
}

variable "tenancy_ocid" {
  type        = string
  description = "OCI tenancy OCID (compartment parent). Not secret."
}

variable "compartment_name" {
  type    = string
  default = "aether"
}

variable "vcn_cidr" {
  type        = string
  default     = "10.20.0.0/24"
  description = "OCI-internal VCN CIDR; kept distinct from all estate/WG prefixes."
}

resource "oci_identity_compartment" "aether" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "Aether offsite estate resources"
  enable_delete  = true
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  ad = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

# --- Network -----------------------------------------------------------------
resource "oci_core_vcn" "aether" {
  compartment_id = oci_identity_compartment.aether.id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "aether-vcn"
  dns_label      = "aether"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = oci_identity_compartment.aether.id
  vcn_id         = oci_core_vcn.aether.id
  display_name   = "aether-igw"
}

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.aether.id
  vcn_id         = oci_core_vcn.aether.id
  display_name   = "aether-public-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = oci_identity_compartment.aether.id
  vcn_id         = oci_core_vcn.aether.id
  display_name   = "aether-public-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH bootstrap (key-only). Tighten source to the home WAN IP after WireGuard is up.
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id    = oci_identity_compartment.aether.id
  vcn_id            = oci_core_vcn.aether.id
  cidr_block        = var.vcn_cidr
  display_name      = "aether-public-subnet"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_security_list.public.id]
  dns_label         = "public"
}

# --- Images (latest Canonical Ubuntu 24.04 per shape/arch; avoids stale OCIDs) ---
data "oci_core_images" "ubuntu_arm" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# --- SSH keys (mirror tofu/google/uptime-monitor.tf) -------------------------
resource "tls_private_key" "a1" {
  algorithm = "ED25519"
}

resource "local_file" "a1_private_key" {
  content         = tls_private_key.a1.private_key_openssh
  filename        = "${path.module}/../../secrets/oci_a1_private_key.pem"
  file_permission = "0600"
}

# --- Instances ---------------------------------------------------------------
resource "oci_core_instance" "a1" {
  compartment_id      = oci_identity_compartment.aether.id
  availability_domain = local.ad
  display_name        = "aether-oci-a1"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    # Full current A1 Always-Free allowance (2 OCPU / 12 GB since 2026-06-15).
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = "oci-a1"
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_arm.images[0].id
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.a1.public_key_openssh
  }
}

# --- Outputs (re-exported at root via outputs.tf, consumed by inventory) -----
output "a1_ip" {
  value       = oci_core_instance.a1.public_ip
  description = "Public IP of the offsite A1 workhorse"
}

output "a1_public_key" {
  value = tls_private_key.a1.public_key_openssh
}

output "a1_private_key" {
  value     = tls_private_key.a1.private_key_openssh
  sensitive = true
}

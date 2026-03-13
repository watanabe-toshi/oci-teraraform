terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
  region           = var.region
}

############################
# Variables
############################

variable "tenancy_ocid" {}
variable "user_ocid" {}
variable "fingerprint" {}
variable "private_key_path" {}
variable "region" {}

variable "compartment_ocid" {
  type = string
}

variable "my_global_ip_cidr" {
  description = "例: 203.0.113.10/32"
  type        = string
}

variable "instance_display_name" {
  type    = string
  default = "windows-rdp-micro-01"
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

# 無料枠寄りの固定shape
variable "shape" {
  type    = string
  default = "VM.Standard.E2.1.Micro"
}

variable "windows_version" {
  type    = string
  default = "Server 2022"
}

############################
# AD
############################

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

############################
# Windows Image
############################

data "oci_core_images" "windows" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Windows"
  operating_system_version = var.windows_version
  shape                    = var.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  ad_name  = data.oci_identity_availability_domains.ads.availability_domains[0].name
  image_id = data.oci_core_images.windows.images[0].id
}

############################
# Network
############################

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "win-vcn"
  dns_label      = "winvcn"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "win-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.subnet_cidr
  display_name               = "public-subnet"
  dns_label                  = "pubsub"
  route_table_id             = oci_core_route_table.public.id
  prohibit_public_ip_on_vnic = false
}

############################
# NSG
############################

resource "oci_core_network_security_group" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "win-nsg"
}

resource "oci_core_network_security_group_security_rule" "rdp_ingress" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6"

  source      = var.my_global_ip_cidr
  source_type = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 3389
      max = 3389
    }
  }

  description = "Allow RDP only from my global IP"
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"

  destination      = "0.0.0.0/0"
  destination_type = "CIDR_BLOCK"

  description = "Allow all outbound"
}

############################
# Windows Instance
############################

resource "oci_core_instance" "windows" {
  availability_domain = local.ad_name
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_display_name
  shape               = var.shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.this.id]
    display_name     = "win-vnic"
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }
}

output "windows_public_ip" {
  value = oci_core_instance.windows.public_ip
}

output "windows_image_name" {
  value = data.oci_core_images.windows.images[0].display_name
}
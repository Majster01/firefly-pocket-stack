# firefly-pocket-stack infrastructure — one server, one firewall, one SSH key.
#
# Deliberately thin. The value here is not automation of a four-resource
# build; it is that the firewall rules and machine spec are written down and
# reproducible rather than clicked into a console and forgotten.
#
#   terraform init
#   terraform apply -var-file=terraform.tfvars

terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.server_name}-admin"
  public_key = var.ssh_public_key
}

# Enforced at Hetzner's edge, so blocked traffic never reaches the machine.
# Everything the stack needs is proxied by Caddy on 80/443; Postgres and the
# AI categorizer are never published to the host at all, so they need no rule.
resource "hcloud_firewall" "fireflyx" {
  name = "${var.server_name}-fw"

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_source_ips
  }

  rule {
    description = "HTTP (ACME challenges and the redirect to HTTPS)"
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTPS"
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }

  rule {
    description = "HTTP/3"
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "fireflyx" {
  name        = var.server_name
  server_type = var.server_type
  location    = var.location
  image       = "ubuntu-24.04"

  ssh_keys     = [hcloud_ssh_key.admin.id]
  firewall_ids = [hcloud_firewall.fireflyx.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    admin_user     = var.admin_user
    ssh_public_key = var.ssh_public_key
    timezone       = var.timezone
    repo_url       = var.repo_url
  })

  # IPv4 costs EUR 0.50/mo net and is genuinely required — do not drop it to
  # save the line item. Checked September 2026: three endpoints this stack
  # depends on publish NO AAAA record at all.
  #
  #   api.enablebanking.com   the bank connection, i.e. the entire point
  #   ghcr.io                 where the AI categorizer image lives
  #   api.backblazeb2.com     the offsite backup target
  #
  # Docker Hub, Gemini, Let's Encrypt and the Ubuntu repos are all fine over
  # IPv6, so an IPv6-only box boots — it just cannot reach your bank, pull the
  # categorizer, or back anything up. A NAT64/DNS64 gateway would work around
  # it, but that puts a translation layer in the path of the bank sync and the
  # backups to save EUR 0.50. Re-test the AAAA records before revisiting.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Weekly automatic snapshots of the whole machine, as the coarsest recovery
  # layer beneath restic. Roughly EUR 0.48/month at this disk size.
  backups = var.enable_hetzner_backups

  labels = {
    project = "fireflyx"
  }

  lifecycle {
    # The disk holds the Postgres volume. Never let a routine attribute change
    # silently rebuild this machine.
    prevent_destroy = true

    # Changing user_data forces a new server, and it only ever runs on the
    # first boot anyway: editing cloud-init.yaml must not plan a replacement.
    ignore_changes = [user_data]
  }
}

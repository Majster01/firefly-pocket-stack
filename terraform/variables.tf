variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write access."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Public key allowed to log in, e.g. contents of ~/.ssh/id_ed25519.pub."
  type        = string
}

variable "ssh_source_ips" {
  description = <<-EOT
    CIDRs allowed to reach SSH. Lock this to your own address if it is static
    — it is the single highest-value restriction available here. Leave the
    default open only if your address changes; fail2ban then does the work.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "server_name" {
  description = "Server name in the Hetzner console."
  type        = string
  default     = "fireflyx"
}

variable "server_type" {
  description = <<-EOT
    cx23 (2 vCPU / 4 GB / 40 GB) is comfortable: the whole stack idles around
    1.5 GB, leaving headroom for imports and Postgres cache.

    Note cx22 is retired — the API no longer returns it, so it cannot be
    ordered. cx23 is its direct replacement.

    Alternatives checked against live nbg1 pricing:
      cpx11  same price, but only 2 GB RAM — too tight for this stack
      cax11  ARM, same specs, EUR 0.50/mo more. Every image in the stack is
             published for arm64, the three this project builds included, so
             it works; it is simply no longer the cheaper option.
  EOT
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location. fsn1/nbg1 (Germany) or hel1 (Finland) keep data in the EU."
  type        = string
  default     = "fsn1"
}

variable "admin_user" {
  description = "Non-root sudo user created on the machine."
  type        = string
  default     = "fireflyx"
}

variable "timezone" {
  description = "Host timezone. Cron runs in this zone, so it must match the TZ in compose/.env."
  type        = string
  default     = "Europe/Ljubljana"
}

variable "enable_hetzner_backups" {
  description = <<-EOT
    Automatic whole-machine backups, billed at 20% of the server price
    (EUR 1.10/mo net, EUR 1.34 gross).

    Intended to be TEMPORARY. This machine is fully reproducible from
    Terraform + cloud-init + the repo, so the only irreplaceable thing is the
    data — and restic->B2 covers that. These backups only buy a ~5 minute
    restore instead of a ~40 minute rebuild.

    Turn this off once BOTH are true:
      1. RESTIC_REPOSITORY is configured in compose/.env, and
      2. scripts/restore-test.sh has passed at least once.

    Until then, leave it on: with restic unconfigured, disabling this would
    mean no backups at all. Toggling it does not rebuild the server.
  EOT
  type        = bool
  default     = true
}

variable "repo_url" {
  description = <<-EOT
    Where the server clones this repository on its first boot. HTTPS only,
    because cloud-init has no deploy key. A private fork is cloned from its
    SSH address afterwards: see README "Set it up".
  EOT
  type        = string
  default     = "https://github.com/Majster01/firefly-pocket-stack.git"

  validation {
    condition     = startswith(var.repo_url, "https://")
    error_message = "repo_url must be an https:// address."
  }
}

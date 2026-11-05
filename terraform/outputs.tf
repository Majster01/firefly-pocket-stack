output "server_ipv4" {
  description = "Point the A records for all three subdomains at this address."
  value       = hcloud_server.fireflyx.ipv4_address
}

output "server_ipv6" {
  description = "Optional AAAA record target."
  value       = hcloud_server.fireflyx.ipv6_address
}

output "ssh_command" {
  description = "How to get in."
  value       = "ssh ${var.admin_user}@${hcloud_server.fireflyx.ipv4_address}"
}

output "dns_records_required" {
  description = "DNS must resolve BEFORE first compose start, or Caddy cannot get certificates."
  value = {
    firefly = "A  firefly.<your-domain>  -> ${hcloud_server.fireflyx.ipv4_address}"
    pico    = "A  pico.<your-domain>     -> ${hcloud_server.fireflyx.ipv4_address}"
    next    = "A  next.<your-domain>     -> ${hcloud_server.fireflyx.ipv4_address}"
    import  = "A  import.<your-domain>   -> ${hcloud_server.fireflyx.ipv4_address}"
  }
}

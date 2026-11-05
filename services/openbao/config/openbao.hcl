# OpenBao on cassette-lab — single-node, LAN-only, auto-unseal via static key.
#
# LAN-only: the container listens on 0.0.0.0 (bridge network) but the host
# publishes only on 192.168.86.4 (see docker-compose.yml ports).
ui = true

api_addr     = "https://192.168.86.4:8200"
cluster_addr = "https://127.0.0.1:8201"

storage "raft" {
  # Single node — no retry_join (that's how other nodes join THIS one).
  path    = "/openbao/data"
  node_id = "bao-node-1"
  # Production tuning default (avoids the 5x perf multiplier default).
  performance_multiplier = 1
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/tls/fullchain.pem"
  tls_key_file  = "/openbao/tls/privkey.pem"
}

# Auto-unseal on (re)boot from a root-only key file on the host.
#   openssl rand -out /etc/openbao/secrets/unseal.key 32
# Keep a copy in the off-host pass store — whoever holds this key can unseal.
seal "static" {
  current_key_id = "bootstrap"
  current_key    = "file:///openbao/secrets/unseal.key"
}

default_lease_ttl = "168h"
max_lease_ttl      = "720h"
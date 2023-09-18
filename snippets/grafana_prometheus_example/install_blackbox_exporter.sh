#!/bin/bash

###
# Install blackbox exporter in Grafana server
###

# Download exporters
cd /tmp && wget https://github.com/prometheus/blackbox_exporter/releases/download/v0.23.0/blackbox_exporter-0.23.0.linux-amd64.tar.gz

# Install exporter binaries
cd /tmp && tar xvf blackbox_exporter-*.*-amd64.tar.gz && mv blackbox_exporter-*.*-amd64/blackbox_exporter /usr/local/bin/

# Install exporter configuration
mkdir /etc/blackbox_exporter
tee /etc/blackbox_exporter/blackbox.yml<<EOF
modules:
  http_2xx:
    prober: http
  http_post_2xx:
    prober: http
    http:
      method: POST
  tcp_connect:
    prober: tcp
  pop3s_banner:
    prober: tcp
    tcp:
      query_response:
      - expect: "^+OK"
      tls: true
      tls_config:
        insecure_skip_verify: false
  grpc:
    prober: grpc
    grpc:
      tls: true
      preferred_ip_protocol: "ip4"
  grpc_plain:
    prober: grpc
    grpc:
      tls: false
      service: "service1"
  ssh_banner:
    prober: tcp
    tcp:
      query_response:
      - expect: "^SSH-2.0-"
      - send: "SSH-2.0-blackbox-ssh-check"
  irc_banner:
    prober: tcp
    tcp:
      query_response:
      - send: "NICK prober"
      - send: "USER prober prober prober :prober"
      - expect: "PING :([^ ]+)"
        send: "PONG ${1}"
      - expect: "^:[^ ]+ 001"
  icmp:
    prober: icmp
  icmp_ttl5:
    prober: icmp
    timeout: 5s
    icmp:
      ttl: 5
EOF

# Init service users
useradd -Urs /bin/false blackbox_exporter || echo "blackbox_exporter user already exists"

# Install blackbox_exporter service
tee /etc/systemd/system/blackbox_exporter.service<<EOF
[Unit]
Description=Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
Type=simple
ExecStart=/usr/bin/blackbox_exporter --config.file /etc/blackbox_exporter/blackbox.yml

[Install]
WantedBy=multi-user.target
EOF

# Update systemctl
systemctl enable blackbox_exporter && systemctl start blackbox_exporter

# Remove artifacts
cd /tmp && rm -rf blackbox_exporter*
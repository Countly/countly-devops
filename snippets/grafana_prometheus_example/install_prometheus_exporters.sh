#!/bin/bash

###
# Install requried exporters on nodes
###

# Download exporters
cd /tmp && wget https://github.com/prometheus/node_exporter/releases/download/v1.5.0/node_exporter-1.5.0.linux-amd64.tar.gz && wget https://github.com/percona/mongodb_exporter/releases/download/v0.37.0/mongodb_exporter-0.37.0.linux-amd64.tar.gz

# Install exporter binaries
cd /tmp && tar xvf node_exporter-*.*-amd64.tar.gz && tar xvf mongodb_exporter-*.*-amd64.tar.gz && mv node_exporter-*.*-amd64/node_exporter /usr/local/bin/ && mv mongodb_exporter-*.*-amd64/mongodb_exporter /usr/local/bin/

# Init service users
useradd -Urs /bin/false node_exporter || echo "node_exporter user already exists" && useradd -Urs /bin/false mongodb_exporter || echo "mongodb_exporter user already exists"

# Install node_exporter service
tee /etc/systemd/system/node_exporter.service<<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --collector.cpu --collector.cpufreq --collector.systemd

[Install]
WantedBy=multi-user.target
EOF

# Install mongodb_exporter service
tee /etc/systemd/system/mongodb_exporter.service<<EOF
[Unit]
Description=MongoDB Exporter
After=network.target

[Service]
User=mongodb_exporter
Group=mongodb_exporter
Type=simple
ExecStart=/usr/local/bin/mongodb_exporter --mongodb.uri=mongodb://127.0.0.1:27017/admin?ssl=false --web.listen-address=:9216 --compatible-mode --collector.indexstats --collector.collstats --collector.diagnosticdata

[Install]
WantedBy=multi-user.target
EOF

# Update systemctl
systemctl enable node_exporter && systemctl enable mongodb_exporter && systemctl start node_exporter && systemctl start mongodb_exporter

# Remove artifacts
cd /tmp && rm -rf mongodb_exporter* && rm -rf node_exporter*
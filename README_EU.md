# Home Internet Quality Monitor

Prometheus + Grafana + Blackbox Exporter based monitoring system for detecting and documenting home Internet outages.

The project is designed for situations where an Internet Service Provider (ISP) periodically loses connectivity and you need objective, timestamped evidence for support tickets and incident investigation.

## What this project does

The monitoring system checks Internet connectivity every **15 seconds** using four independent probes:

| Target | Protocol | Purpose |
|---|---|---|
| `google.com` | ICMP | Verify IP-level connectivity |
| `google.com` | HTTPS | Verify DNS/TCP/TLS/HTTP connectivity |
| `ya.ru` | ICMP | Verify IP-level connectivity to an independent destination |
| `ya.ru` | HTTPS | Verify application-layer connectivity |

When all four probes transition from `UP` to `DOWN`, a host-side helper automatically:

- runs `mtr` against `google.com`;
- runs `mtr` against `ya.ru`;
- runs `traceroute` against both destinations when available;
- runs `ping` against both destinations;
- records DNS resolution information;
- records the route selected by the local host;
- stores all diagnostic output with a timestamp.

The result is a historical record showing not only **when** the Internet disappeared, but also what the network path looked like during the outage.

---

## Architecture

```text
                         INTERNET
                            |
              +-------------+-------------+
              |                           |
          google.com                    ya.ru
              |                           |
              +-------------+-------------+
                            |
                       ISP NETWORK
                            |
                       HOME ROUTER
                            |
                            v
                 +----------------------+
                 | Ubuntu 24.04 Host    |
                 |                      |
                 | Docker Compose       |
                 |                      |
                 | +------------------+ |
                 | | Blackbox Exporter| |
                 | |      :9115       | |
                 | +--------+---------+ |
                 |          |           |
                 | +--------v---------+ |
                 | | Prometheus       | |
                 | |      :9090       | |
                 | +--------+---------+ |
                 |          |           |
                 | +--------v---------+ |
                 | | Grafana          | |
                 | |      :3000       | |
                 | +------------------+ |
                 |                      |
                 | systemd timer        |
                 |       |              |
                 |       v              |
                 | outage trace helper  |
                 |       |              |
                 |       +--> MTR       |
                 |       +--> traceroute|
                 |       +--> ping      |
                 |       +--> DNS       |
                 +----------------------+
```

### Components

#### Prometheus

Prometheus polls the Blackbox Exporter every 15 seconds and stores probe results and timing metrics.

#### Blackbox Exporter

Blackbox Exporter performs external network probes:

- ICMP;
- HTTPS/HTTP.

It exposes the results to Prometheus.

#### Grafana

Grafana visualizes:

- current probe state;
- Internet availability;
- probe duration;
- ICMP RTT;
- failed probes;
- complete outages;
- outage periods over arbitrary time ranges.

#### Outage trace helper

The helper runs directly on the Linux host rather than inside the Blackbox Exporter container.

This is intentional.

Blackbox Exporter is responsible for probing. It does not provide a generic `mtr`/`traceroute` diagnostic workflow.

Running MTR on the host also ensures that the diagnostic path originates from the same network environment as the user's actual Internet connection.

---

# Requirements

## Hardware

The project does not require dedicated hardware.

A small Linux machine, mini-PC, Raspberry Pi-class system, NAS, or VM can be used.

The monitoring host should ideally remain powered on continuously.

## Operating system

The tested target environment is:

```text
Ubuntu Server 24.04
```

## Software

Required:

- Docker
- Docker Compose plugin
- `mtr`
- `traceroute`
- `ping`
- `curl`
- `jq`
- systemd

Install diagnostic tools:

```bash
sudo apt update
sudo apt install -y mtr-tiny traceroute iputils-ping curl jq
```

---

# Project structure

Recommended directory layout:

```text
/opt/internet-monitor/
├── docker-compose.yml
├── prometheus/
│   ├── prometheus.yml
│   └── rules/
│       └── internet.yml
├── blackbox/
│   └── blackbox.yml
├── grafana/
│   └── provisioning/
│       └── datasources/
│           └── prometheus.yml
├── scripts/
│   └── internet-outage-trace.sh
├── traces/
│   ├── google.com/
│   └── ya.ru/
└── state/
```

Create the directories:

```bash
sudo mkdir -p /opt/internet-monitor/{prometheus/rules,blackbox,grafana/provisioning/datasources,traces,scripts,state}
sudo chmod 755 /opt/internet-monitor
```

---

# Version matrix

The deployment uses the following image tags:

| Component | Version |
|---|---:|
| Prometheus | `v3.13.2` |
| Grafana | `13.1.3` |
| Blackbox Exporter | `v0.28.0` |

Images are explicitly version-pinned instead of using `latest`.

This makes deployments reproducible and avoids unexpected upgrades.

---

# Docker Compose

Create:

```text
/opt/internet-monitor/docker-compose.yml
```

with:

```yaml
services:

  prometheus:
    image: prom/prometheus:v3.13.2
    container_name: internet-prometheus
    restart: unless-stopped

    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=180d
      - --storage.tsdb.retention.size=20GB
      - --web.enable-lifecycle

    ports:
      - "127.0.0.1:9090:9090"

    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus

    depends_on:
      - blackbox-exporter

    networks:
      - monitoring


  blackbox-exporter:
    image: quay.io/prometheus/blackbox-exporter:v0.28.0
    container_name: internet-blackbox
    restart: unless-stopped

    command:
      - --config.file=/config/blackbox.yml

    cap_add:
      - NET_RAW

    ports:
      - "127.0.0.1:9115:9115"

    volumes:
      - ./blackbox/blackbox.yml:/config/blackbox.yml:ro

    networks:
      - monitoring


  grafana:
    image: grafana/grafana:13.1.3
    container_name: internet-grafana
    restart: unless-stopped

    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"

    ports:
      - "3000:3000"

    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro

    depends_on:
      - prometheus

    networks:
      - monitoring


volumes:
  prometheus_data:
  grafana_data:


networks:
  monitoring:
    driver: bridge
```

## Security note

Do not expose Prometheus or Blackbox Exporter directly to the Internet.

The example binds both services to:

```text
127.0.0.1
```

Grafana is exposed on port `3000`.

If Grafana needs to be accessed remotely, put it behind an authenticated reverse proxy or VPN.

---

# Why `CAP_NET_RAW` is required

The Blackbox Exporter ICMP prober requires the ability to create raw network sockets.

The container therefore has:

```yaml
cap_add:
  - NET_RAW
```

Do **not** use:

```yaml
privileged: true
```

`NET_RAW` provides the required capability without making the container fully privileged.

An alternative Linux configuration is to allow the relevant user/group to use ping sockets through:

```text
net.ipv4.ping_group_range
```

but this deployment uses `CAP_NET_RAW` explicitly because it is simple and predictable.

---

# Blackbox Exporter configuration

Create:

```text
/opt/internet-monitor/blackbox/blackbox.yml
```

```yaml
modules:

  icmp:
    prober: icmp
    timeout: 10s

    icmp:
      preferred_ip_protocol: ip4


  http_2xx:
    prober: http
    timeout: 10s

    http:
      method: GET
      preferred_ip_protocol: ip4

      valid_status_codes:
        - 200
        - 201
        - 202
        - 203
        - 204
        - 205
        - 206
        - 207
        - 208
        - 226

      fail_if_ssl: false
      fail_if_not_ssl: false

      tls_config:
        insecure_skip_verify: false

      follow_redirects: true
```

The HTTPS probe performs a real HTTP GET.

Conceptually, the HTTPS test covers:

```text
DNS
 |
 v
TCP
 |
 v
TLS
 |
 v
HTTP GET
 |
 v
HTTP response
```

This is stronger than testing only TCP port 443.

---

# Prometheus configuration

Create:

```text
/opt/internet-monitor/prometheus/prometheus.yml
```

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s


rule_files:
  - /etc/prometheus/rules/*.yml


scrape_configs:

  - job_name: blackbox

    metrics_path: /probe

    params:
      module:
        - icmp

    static_configs:

      - targets:
          - google.com

        labels:
          probe_target: google
          probe_type: icmp

      - targets:
          - ya.ru

        labels:
          probe_target: ya
          probe_type: icmp

    relabel_configs:

      - source_labels:
          - __address__
        target_label: __param_target

      - source_labels:
          - __param_target
        target_label: instance

      - target_label: __address__
        replacement: blackbox-exporter:9115


  - job_name: blackbox-https

    metrics_path: /probe

    params:
      module:
        - http_2xx

    static_configs:

      - targets:
          - https://google.com

        labels:
          probe_target: google
          probe_type: https

      - targets:
          - https://ya.ru

        labels:
          probe_target: ya
          probe_type: https

    relabel_configs:

      - source_labels:
          - __address__
        target_label: __param_target

      - source_labels:
          - __param_target
        target_label: instance

      - target_label: __address__
        replacement: blackbox-exporter:9115
```

The important Blackbox Exporter relabeling sequence is:

```text
__address__
    |
    v
__param_target
    |
    v
instance

__address__
    |
    v
blackbox-exporter:9115
```

Prometheus therefore requests:

```text
/probe?target=google.com&module=icmp
```

from the Blackbox Exporter rather than directly scraping Google.

---

# Grafana datasource provisioning

Create:

```text
/opt/internet-monitor/grafana/provisioning/datasources/prometheus.yml
```

```yaml
apiVersion: 1

datasources:

  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

---

# Starting the stack

Change the Grafana password in `docker-compose.yml`.

Then:

```bash
cd /opt/internet-monitor

docker compose config
```

If the configuration is valid:

```bash
docker compose pull
docker compose up -d
```

Check the containers:

```bash
docker compose ps
```

Expected containers:

```text
internet-prometheus
internet-blackbox
internet-grafana
```

Check logs:

```bash
docker compose logs --tail=100
```

---

# Testing Blackbox Exporter

## ICMP

```bash
curl 'http://127.0.0.1:9115/probe?target=google.com&module=icmp'
```

The result should contain:

```text
probe_success 1
```

Test Yandex:

```bash
curl 'http://127.0.0.1:9115/probe?target=ya.ru&module=icmp'
```

## HTTPS

```bash
curl 'http://127.0.0.1:9115/probe?target=https://google.com&module=http_2xx'
```

And:

```bash
curl 'http://127.0.0.1:9115/probe?target=https://ya.ru&module=http_2xx'
```

Both should contain:

```text
probe_success 1
```

---

# Testing Prometheus

Open:

```text
http://127.0.0.1:9090
```

Run:

```promql
probe_success
```

Expected probes:

```text
google.com        ICMP
ya.ru             ICMP
https://google.com HTTPS
https://ya.ru      HTTPS
```

You can also query:

```promql
probe_success{probe_target="google"}
```

and:

```promql
probe_success{probe_target="ya"}
```

---

# Important Prometheus metrics

## Probe status

```promql
probe_success
```

Values:

```text
1 = probe successful
0 = probe failed
```

## Probe duration

```promql
probe_duration_seconds
```

This represents the overall duration of the probe.

## ICMP timing

```promql
probe_icmp_duration_seconds
```

This is useful for observing ICMP RTT.

---

# How to interpret the probes

The four probes are intentionally redundant.

## Normal state

```text
Google ICMP      UP
Google HTTPS     UP
Ya.ru ICMP       UP
Ya.ru HTTPS      UP
```

Everything is working.

## Complete Internet outage

```text
Google ICMP      DOWN
Google HTTPS     DOWN
Ya.ru ICMP       DOWN
Ya.ru HTTPS      DOWN
```

This is strong evidence of a general Internet connectivity failure.

## ICMP down, HTTPS up

```text
Google ICMP      DOWN
Google HTTPS     UP
```

This does not necessarily mean the Internet is unavailable.

Possible explanations include:

- ICMP filtering;
- destination-specific ICMP behavior;
- packet loss;
- transient routing problems.

## ICMP up, HTTPS down

```text
Google ICMP      UP
Google HTTPS     DOWN
```

The network layer may still be working while the problem is higher in the stack:

- DNS;
- TCP;
- TLS;
- HTTP;
- remote application;
- filtering.

---

# Outage tracing

Blackbox Exporter is intentionally not used to run MTR.

The trace helper runs on the Linux host because MTR should originate from the same network environment as the monitored connection.

## Install tools

```bash
sudo apt update
sudo apt install -y mtr-tiny traceroute iputils-ping curl jq
```

---

# Trace helper

Create:

```text
/opt/internet-monitor/scripts/internet-outage-trace.sh
```

```bash
#!/usr/bin/env bash

set -uo pipefail

PROMETHEUS_URL="http://127.0.0.1:9090"

TRACE_DIR="/opt/internet-monitor/traces"

STATE_DIR="/opt/internet-monitor/state"

LOCK_FILE="/run/internet-outage-trace.lock"

TARGETS=(
    "google.com"
    "ya.ru"
)

mkdir -p "${TRACE_DIR}"
mkdir -p "${STATE_DIR}"

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    exit 0
fi


get_probe_status() {

    local target="$1"
    local probe_type="$2"

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 5 \
        --get \
        --data-urlencode \
            "query=probe_success{probe_target=\"${target}\",probe_type=\"${probe_type}\"}" \
        "${PROMETHEUS_URL}/api/v1/query" |
        jq -r '
            if .status == "success" and (.data.result | length) > 0
            then .data.result[0].value[1]
            else "unknown"
            end
        '
}


run_mtr() {

    local target="$1"
    local timestamp="$2"

    local target_dir="${TRACE_DIR}/${target}"

    mkdir -p "${target_dir}"

    local output_file="${target_dir}/${timestamp}.log"

    {
        echo "============================================================"
        echo "Internet outage detected"
        echo "Target: ${target}"
        echo "Timestamp: $(date --iso-8601=seconds)"
        echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
        echo "============================================================"
        echo

        echo "### DNS"
        echo

        getent ahostsv4 "${target}" || true

        echo
        echo "### MTR"
        echo

        mtr \
            --report \
            --report-cycles 20 \
            --no-dns \
            --show-ips \
            "${target}" || true

        echo
        echo "### Traceroute"
        echo

        if command -v traceroute >/dev/null 2>&1; then
            traceroute \
                -n \
                -w 1 \
                -q 2 \
                -m 30 \
                "${target}" || true
        else
            echo "traceroute is not installed"
        fi

        echo
        echo "### Ping"
        echo

        ping \
            -4 \
            -c 10 \
            -W 1 \
            "${target}" || true

        echo
        echo "### Route"
        echo

        ip route get "$(getent ahostsv4 "${target}" | awk 'NR==1 {print $1}')" 2>/dev/null || true

        echo
        echo "============================================================"
        echo "Trace finished"
        echo "============================================================"

    } >> "${output_file}" 2>&1
}


timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"

google_icmp="$(get_probe_status "google" "icmp")"
google_https="$(get_probe_status "google" "https")"

ya_icmp="$(get_probe_status "ya" "icmp")"
ya_https="$(get_probe_status "ya" "https")"


current_state="${google_icmp}:${google_https}:${ya_icmp}:${ya_https}"

state_file="${STATE_DIR}/current.state"

previous_state="unknown"

if [[ -f "${state_file}" ]]; then
    previous_state="$(cat "${state_file}")"
fi

printf '%s\n' "${current_state}" > "${state_file}"


echo "$(date --iso-8601=seconds) current=${current_state} previous=${previous_state}" \
    >> "${STATE_DIR}/helper.log"


all_down="false"

if [[ "${google_icmp}" == "0" ]] &&
   [[ "${google_https}" == "0" ]] &&
   [[ "${ya_icmp}" == "0" ]] &&
   [[ "${ya_https}" == "0" ]]; then

    all_down="true"

fi


if [[ "${all_down}" != "true" ]]; then
    exit 0
fi


if [[ "${previous_state}" == "${current_state}" ]]; then
    exit 0
fi


echo "$(date --iso-8601=seconds) INTERNET OUTAGE DETECTED" \
    >> "${STATE_DIR}/helper.log"


for target in "${TARGETS[@]}"; do
    run_mtr "${target}" "${timestamp}"
done
```

Make it executable:

```bash
sudo chmod +x /opt/internet-monitor/scripts/internet-outage-trace.sh
```

---

# How the helper works

The helper queries Prometheus for four values:

```text
Google ICMP
Google HTTPS
Ya.ru ICMP
Ya.ru HTTPS
```

It combines them into a state:

```text
1:1:1:1
```

or:

```text
0:0:0:0
```

A transition such as:

```text
1:1:1:1
      |
      v
0:0:0:0
```

is treated as a complete Internet outage.

The helper then creates:

```text
traces/google.com/YYYY-MM-DD_HH-MM-SS.log
traces/ya.ru/YYYY-MM-DD_HH-MM-SS.log
```

The lock prevents overlapping trace runs.

The helper also stores the previous state so that a long outage does not generate a new MTR every 15 seconds.

---

# systemd timer

A 15-second interval is not suitable for traditional cron.

Use systemd.

Create:

```text
/etc/systemd/system/internet-outage-trace.service
```

```ini
[Unit]
Description=Internet outage traceroute/MTR helper
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/opt/internet-monitor/scripts/internet-outage-trace.sh
```

Create:

```text
/etc/systemd/system/internet-outage-trace.timer
```

```ini
[Unit]
Description=Run internet outage detection every 15 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=1s
Persistent=false

[Install]
WantedBy=timers.target
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable the timer:

```bash
sudo systemctl enable --now internet-outage-trace.timer
```

Check:

```bash
systemctl status internet-outage-trace.timer
```

And:

```bash
systemctl list-timers | grep internet-outage
```

Run the helper manually for testing:

```bash
sudo /opt/internet-monitor/scripts/internet-outage-trace.sh
```

---

# Cron alternative

If systemd timers are not available, cron can be used, but standard cron has a one-minute resolution.

Example:

```cron
* * * * * /opt/internet-monitor/scripts/internet-outage-trace.sh
```

For a 15-second monitoring interval, systemd is preferred.

---

# Grafana dashboard

The dashboard should contain at least:

- current Google ICMP status;
- current Google HTTPS status;
- current Ya.ru ICMP status;
- current Ya.ru HTTPS status;
- probe duration;
- ICMP RTT;
- availability percentage;
- failed probe count;
- complete outage count;
- time-series graph showing all probe states.

The following dashboard JSON can be imported into Grafana.

```json
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "graphTooltip": 1,
  "panels": [
    {
      "type": "stat",
      "title": "Google ICMP",
      "id": 1,
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 0,
        "y": 0
      },
      "targets": [
        {
          "expr": "probe_success{probe_target=\"google\",probe_type=\"icmp\"}",
          "legendFormat": "Google ICMP",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {
                  "text": "DOWN"
                },
                "1": {
                  "text": "UP"
                }
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "value": null,
                "color": "red"
              },
              {
                "value": 1,
                "color": "green"
              }
            ]
          }
        }
      }
    },
    {
      "type": "stat",
      "title": "Google HTTPS",
      "id": 2,
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 6,
        "y": 0
      },
      "targets": [
        {
          "expr": "probe_success{probe_target=\"google\",probe_type=\"https\"}",
          "legendFormat": "Google HTTPS",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {
                  "text": "DOWN"
                },
                "1": {
                  "text": "UP"
                }
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "value": null,
                "color": "red"
              },
              {
                "value": 1,
                "color": "green"
              }
            ]
          }
        }
      }
    },
    {
      "type": "stat",
      "title": "Ya ICMP",
      "id": 3,
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 12,
        "y": 0
      },
      "targets": [
        {
          "expr": "probe_success{probe_target=\"ya\",probe_type=\"icmp\"}",
          "legendFormat": "Ya ICMP",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {
                  "text": "DOWN"
                },
                "1": {
                  "text": "UP"
                }
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "value": null,
                "color": "red"
              },
              {
                "value": 1,
                "color": "green"
              }
            ]
          }
        }
      }
    },
    {
      "type": "stat",
      "title": "Ya HTTPS",
      "id": 4,
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 18,
        "y": 0
      },
      "targets": [
        {
          "expr": "probe_success{probe_target=\"ya\",probe_type=\"https\"}",
          "legendFormat": "Ya HTTPS",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": {
                  "text": "DOWN"
                },
                "1": {
                  "text": "UP"
                }
              }
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "value": null,
                "color": "red"
              },
              {
                "value": 1,
                "color": "green"
              }
            ]
          }
        }
      }
    },
    {
      "type": "timeseries",
      "title": "Internet availability",
      "id": 5,
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 4
      },
      "targets": [
        {
          "expr": "probe_success{job=~\"blackbox|blackbox-https\"}",
          "legendFormat": "{{probe_target}} {{probe_type}}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "min": 0,
          "max": 1,
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "value": null,
                "color": "red"
              },
              {
                "value": 1,
                "color": "green"
              }
            ]
          }
        }
      },
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "bottom"
        },
        "tooltip": {
          "mode": "all"
        }
      }
    },
    {
      "type": "timeseries",
      "title": "Probe duration / RTT",
      "id": 6,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 12
      },
      "targets": [
        {
          "expr": "probe_duration_seconds{job=\"blackbox\"}",
          "legendFormat": "{{probe_target}} ICMP",
          "refId": "A"
        },
        {
          "expr": "probe_duration_seconds{job=\"blackbox-https\"}",
          "legendFormat": "{{probe_target}} HTTPS",
          "refId": "B"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        }
      }
    },
    {
      "type": "timeseries",
      "title": "ICMP RTT",
      "id": 7,
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 12
      },
      "targets": [
        {
          "expr": "probe_icmp_duration_seconds{job=\"blackbox\"}",
          "legendFormat": "{{probe_target}}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        }
      }
    },
    {
      "type": "stat",
      "title": "Availability",
      "id": 8,
      "gridPos": {
        "h": 6,
        "w": 8,
        "x": 0,
        "y": 20
      },
      "targets": [
        {
          "expr": "100 * avg(avg_over_time(probe_success{job=~\"blackbox|blackbox-https\"}[$__range]))",
          "legendFormat": "Availability",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "decimals": 3,
          "min": 0,
          "max": 100
        }
      }
    },
    {
      "type": "stat",
      "title": "Failed probes",
      "id": 9,
      "gridPos": {
        "h": 6,
        "w": 8,
        "x": 8,
        "y": 20
      },
      "targets": [
        {
          "expr": "sum(sum_over_time((probe_success{job=~\"blackbox|blackbox-https\"} == bool 0)[$__range:15s]))",
          "legendFormat": "Failures",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        }
      }
    },
    {
      "type": "stat",
      "title": "Complete outages",
      "id": 10,
      "gridPos": {
        "h": 6,
        "w": 8,
        "x": 16,
        "y": 20
      },
      "targets": [
        {
          "expr": "sum(sum_over_time(((probe_success{probe_type=\"icmp\"} == bool 0) and on(probe_target) (probe_success{probe_type=\"https\"} == bool 0))[$__range:15s]))",
          "legendFormat": "Outages",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        }
      }
    }
  ],
  "refresh": "15s",
  "schemaVersion": 41,
  "tags": [
    "internet",
    "blackbox",
    "isp",
    "network"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-24h",
    "to": "now"
  },
  "title": "Home Internet Quality",
  "uid": "home-internet-quality",
  "version": 1
}
```

Import it through:

```text
Grafana
  -> Dashboards
  -> Import
  -> paste JSON
```

---

# Alerting

Recommended alerting strategy:

Do not trigger a critical alert after a single failed probe.

With a 15-second scrape interval, use at least:

```text
for: 1m
```

This requires several consecutive failures.

Create:

```text
/opt/internet-monitor/prometheus/rules/internet.yml
```

```yaml
groups:

  - name: internet-monitoring

    interval: 15s

    rules:

      - alert: InternetGoogleICMPDown
        expr: probe_success{probe_target="google",probe_type="icmp"} == 0
        for: 1m

        labels:
          severity: critical

        annotations:
          summary: "Google ICMP unavailable"
          description: "Google ICMP probe has been failing for more than 1 minute."


      - alert: InternetGoogleHTTPSDown
        expr: probe_success{probe_target="google",probe_type="https"} == 0
        for: 1m

        labels:
          severity: critical

        annotations:
          summary: "Google HTTPS unavailable"
          description: "Google HTTPS probe has been failing for more than 1 minute."


      - alert: InternetYandexICMPDown
        expr: probe_success{probe_target="ya",probe_type="icmp"} == 0
        for: 1m

        labels:
          severity: critical

        annotations:
          summary: "Ya.ru ICMP unavailable"
          description: "Ya.ru ICMP probe has been failing for more than 1 minute."


      - alert: InternetYandexHTTPSDown
        expr: probe_success{probe_target="ya",probe_type="https"} == 0
        for: 1m

        labels:
          severity: critical

        annotations:
          summary: "Ya.ru HTTPS unavailable"
          description: "Ya.ru HTTPS probe has been failing for more than 1 minute."


      - alert: CompleteInternetOutage
        expr: |
          (
            probe_success{probe_target="google",probe_type="icmp"} == 0
          )
          and
          (
            probe_success{probe_target="google",probe_type="https"} == 0
          )
          and
          (
            probe_success{probe_target="ya",probe_type="icmp"} == 0
          )
          and
          (
            probe_success{probe_target="ya",probe_type="https"} == 0
          )

        for: 1m

        labels:
          severity: critical

        annotations:
          summary: "Complete Internet outage"
          description: "ICMP and HTTPS probes to Google and Ya.ru have been unavailable for more than 1 minute."


      - alert: InternetHighLatency
        expr: |
          probe_duration_seconds{job="blackbox"} > 0.2

        for: 2m

        labels:
          severity: warning

        annotations:
          summary: "High Internet probe latency"
          description: "Internet probe latency is above 200ms for more than 2 minutes."
```

After changing Prometheus configuration:

```bash
cd /opt/internet-monitor
docker compose restart prometheus
```

Check loaded rules:

```bash
curl -s http://127.0.0.1:9090/api/v1/rules | jq
```

---

# Understanding MTR results

Example:

```text
HOST: google.com

HOST:                   Loss%   Snt   Last   Avg  Best  Wrst StDev
 1. 192.168.1.1          0.0%    20    0.8   0.9   0.7   1.3   0.1
 2. 10.10.0.1            0.0%    20    4.1   4.0   3.7   4.8   0.3
 3. 100.64.1.1           0.0%    20    7.2   7.4   6.9   9.1   0.5
 4. 172.16.20.1          0.0%    20   11.0  10.9  10.4  12.8   0.6
 5. 185.x.x.x            0.0%    20   14.2  14.3  13.9  16.1   0.5
 6. 203.x.x.x            0.0%    20   18.4  18.7  18.0  21.3   0.8
 7. 72.14.x.x           100.0%    20     -     -     -     -     -
 8. 142.250.x.x         100.0%    20     -     -     -     -     -
```

The important pattern is not simply:

```text
hop 7 = 100% loss
```

because routers may rate-limit or completely suppress ICMP responses.

The stronger indication is:

```text
hop 6 = 0%
hop 7 = 100%
hop 8 = 100%
destination = 100%
```

and then, after the outage:

```text
hop 7 = 0%
destination = 0%
```

This indicates that the loss begins somewhere after the last consistently responding hop and continues toward the destination.

## Important limitation

MTR cannot prove that the router which reports packet loss is itself broken.

For example:

```text
hop 3 = 50% loss
hop 4 = 0% loss
destination = 0% loss
```

usually indicates ICMP rate limiting rather than actual packet loss affecting forwarded traffic.

Never claim that a specific router is defective based only on loss reported for that hop.

---

# Why two destinations are important

A single destination is insufficient for strong ISP diagnostics.

For example, if only Google fails:

```text
Google      DOWN
Ya.ru       UP
```

the problem may be destination-specific.

If both destinations fail simultaneously:

```text
Google      DOWN
Ya.ru       DOWN
```

the probability of a destination-specific problem is much lower.

Even better:

```text
Google ICMP      DOWN
Google HTTPS     DOWN
Ya.ru ICMP       DOWN
Ya.ru HTTPS      DOWN
```

This represents a complete loss of external connectivity from the monitoring point.

---

# Recommended additional probe: local gateway

For stronger diagnostics, add the local router as another ICMP target.

For example:

```text
192.168.1.1
```

This creates an additional diagnostic layer:

```text
Monitoring host
      |
      v
Local router
      |
      v
ISP gateway
      |
      v
Internet
```

Interpretation:

### Local router DOWN

```text
Local router    DOWN
Google          DOWN
Ya.ru           DOWN
```

Investigate:

- LAN;
- Wi-Fi;
- Ethernet;
- local router;
- power;
- local host.

### Local router UP, Internet DOWN

```text
Local router    UP
Google          DOWN
Ya.ru           DOWN
```

This is much stronger evidence that the failure is outside the local network.

---

# Recommended additional probe: ISP first hop

After collecting several MTR reports, identify the first router beyond the home router.

For example:

```text
1. 192.168.1.1
2. 100.64.x.x
3. 10.x.x.x
4. ...
```

The first ISP-side address can then be monitored directly.

The resulting monitoring chain becomes:

```text
LOCAL ROUTER
     |
     v
ISP GATEWAY
     |
     v
GOOGLE
     |
     v
YA.RU
```

This makes incident analysis substantially easier.

---

# Evidence collection

Trace files are stored under:

```text
/opt/internet-monitor/traces/
```

Example:

```text
/opt/internet-monitor/traces/google.com/2026-08-25_21-15-00.log
/opt/internet-monitor/traces/ya.ru/2026-08-25_21-15-00.log
```

List all incidents:

```bash
find /opt/internet-monitor/traces -type f -print
```

Inspect an incident:

```bash
cat /opt/internet-monitor/traces/google.com/2026-08-25_21-15-00.log
```

The log contains:

- timestamp;
- hostname;
- DNS resolution;
- MTR;
- traceroute;
- ping;
- route selection.

---

# Example of an ISP incident

A useful incident record might look like:

```text
2026-08-25 21:15:00
Google ICMP      DOWN
Google HTTPS     DOWN
Ya.ru ICMP       DOWN
Ya.ru HTTPS      DOWN
```

MTR:

```text
192.168.1.1       0%
ISP hop #1        0%
ISP hop #2        0%
ISP hop #3        0%
ISP hop #4       100%
ISP hop #5       100%
Google           100%
```

The connection recovers at:

```text
2026-08-25 21:22:42
```

This allows the incident to be described objectively:

> Between 21:15:00 and 21:22:42 the monitoring host lost connectivity to both Google and Ya.ru at both ICMP and HTTPS levels. The local gateway remained reachable. MTR traces captured during the incident showed that connectivity stopped progressing after the ISP-side routing path.

This is substantially more useful than a subjective report such as:

> "The Internet was not working."

---

# Important limitations

## ICMP is not proof of Internet availability by itself

Some networks block or rate-limit ICMP.

This is why the project uses both:

```text
ICMP
```

and:

```text
HTTPS
```

## MTR is not proof of a broken router

A hop showing loss may simply be rate-limiting diagnostic packets.

Always examine whether the loss continues to subsequent hops and the final destination.

## DNS can be a separate failure

If HTTPS probes fail while ICMP probes work, DNS may be involved.

This is one reason the helper records DNS resolution as well.

## Destination-specific failures are possible

Google and Ya.ru provide independent destinations, but they are still external services.

For higher confidence, add additional stable targets such as:

- an ISP gateway;
- a well-known public resolver;
- another independent network;
- a server under your own control.

---

# Operational recommendations

## Keep Prometheus data for a long period

For ISP investigations, short retention is often useless.

The example keeps:

```text
180 days
```

This makes it possible to demonstrate:

```text
17 outages in 30 days
```

instead of only showing today's problem.

## Keep trace logs separately

MTR/traceroute files are much smaller than a full Prometheus history and can be archived independently.

## Do not run MTR continuously

MTR generates additional diagnostic traffic.

Run it when an outage is detected, not every 15 seconds.

## Use multiple destinations

At least:

```text
Google
Ya.ru
```

is recommended.

More destinations can be added later.

---

# Troubleshooting

## Blackbox ICMP returns `probe_success 0`

Check the container capabilities:

```bash
docker inspect internet-blackbox \
    --format '{{json .HostConfig.CapAdd}}'
```

Expected output should include:

```text
NET_RAW
```

Check the logs:

```bash
docker compose logs blackbox-exporter
```

Test directly:

```bash
curl 'http://127.0.0.1:9115/probe?target=google.com&module=icmp'
```

---

## Prometheus has no probe metrics

Check:

```bash
docker compose logs prometheus
```

Validate the configuration:

```bash
docker exec internet-prometheus \
    promtool check config /etc/prometheus/prometheus.yml
```

---

## Helper cannot query Prometheus

Check:

```bash
curl http://127.0.0.1:9090/-/ready
```

Expected:

```text
Prometheus Server is Ready.
```

Check:

```bash
curl -s http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=probe_success' | jq
```

---

## No trace files are created

Run the helper manually:

```bash
sudo /opt/internet-monitor/scripts/internet-outage-trace.sh
```

Check:

```bash
cat /opt/internet-monitor/state/helper.log
```

Check systemd:

```bash
systemctl status internet-outage-trace.timer
```

And:

```bash
journalctl -u internet-outage-trace.service
```

---

# Future improvements

The current implementation is intentionally simple, but it can be extended significantly.

Recommended next steps:

1. Add monitoring of the local router.
2. Add monitoring of the first ISP gateway.
3. Add a dedicated public DNS target.
4. Add more independent Internet destinations.
5. Add Alertmanager.
6. Send outage notifications to Telegram, email, Discord, etc.
7. Add Grafana annotations for outage start/end.
8. Build an automatic incident table.
9. Correlate MTR results with Prometheus outage timestamps.
10. Store a compact JSON incident record in addition to raw logs.
11. Add IPv6 monitoring separately from IPv4.
12. Add packet-loss metrics independent of `probe_success`.
13. Add periodic TCP checks.
14. Add a second monitoring host outside the ISP network for correlation.
15. Export incident reports as Markdown/PDF.

---

# IPv6

IPv6 should ideally be monitored separately.

Do not assume:

```text
IPv4 works
```

means:

```text
IPv6 works
```

and vice versa.

A future configuration can add dedicated probes using:

```yaml
preferred_ip_protocol: ip6
```

and create separate Prometheus series.

---

# Stronger evidence with an external monitoring point

The strongest possible architecture is:

```text
                         INTERNET
                            |
             +--------------+--------------+
             |                             |
         HOME ISP                     External VPS
             |                             |
             v                             v
       Monitoring host              Independent probe
             |                             |
             +-------------+---------------+
                           |
                           v
                       Analysis
```

If the home monitoring host reports:

```text
DOWN
```

while an external VPS continues to see the Internet normally, the problem is very likely specific to the home ISP path.

If many customers connected to the same ISP report outages at the same time, correlation becomes even stronger.

---

# Data interpretation cheat sheet

| Observation | Likely interpretation |
|---|---|
| Local router DOWN | Local LAN/router problem |
| Local router UP, Internet DOWN | Problem beyond local network |
| Google ICMP DOWN, Ya.ru ICMP UP | Destination/path-specific issue |
| ICMP UP, HTTPS DOWN | Higher-layer problem |
| ICMP + HTTPS down for both targets | Strong evidence of general Internet outage |
| MTR hop loss, later hops healthy | Probably ICMP rate limiting |
| MTR loss starts at a hop and continues to destination | Possible routing/link failure after that hop |
| High RTT before outage | Congestion may precede the outage |
| Multiple independent destinations fail simultaneously | Stronger evidence of ISP-side problem |

---

# License

Choose the license appropriate for your repository.

For example, MIT:

```text
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files, to deal in the Software
without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

# Summary

This project provides a lightweight observability stack for home Internet quality monitoring:

```text
Blackbox Exporter
        |
        v
    Prometheus
        |
        v
     Grafana
```

with an independent diagnostic path:

```text
systemd timer
      |
      v
outage helper
      |
      +--> MTR
      +--> traceroute
      +--> ping
      +--> DNS
      +--> route information
```

The key design principle is to collect **multiple independent measurements** rather than relying on a single ping.

The resulting dataset can answer:

- When did the outage start?
- When did it end?
- How long did it last?
- Did ICMP fail?
- Did HTTPS fail?
- Did multiple independent destinations fail?
- Was latency increasing before the outage?
- Was the local gateway reachable?
- At what point did the external route stop progressing?
- Did the route recover after the ISP recovered?

That turns an intermittent home Internet problem into a measurable and reproducible network incident.
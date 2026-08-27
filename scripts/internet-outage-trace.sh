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

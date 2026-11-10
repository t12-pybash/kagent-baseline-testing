#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR="results/$(date +%Y%m%d-%H%M%S)-scale"
mkdir -p "$RESULTS_DIR"

PROM_URL="${PROM_URL:?PROM_URL is required. Example: export PROM_URL=http://prometheus-operated.monitoring.svc.cluster.local:9090}"
SCALE=17
SETTLE_SECS=150   # 2.5 min -- enough for Prometheus [2m] rate window to cover all pods
WAIT_TIMEOUT=1200  # seconds -- ceiling for all 102 pods to reach Ready

AGENTS=(
  baseline-go-minimal
  baseline-python-minimal
  baseline-go-k8s-tools
  baseline-go-promql
  baseline-go-long-context
  baseline-go-multiturn
)

cleanup() {
  echo "" >&2
  echo "Scaling all deployments back to 1..." >&2
  for agent in "${AGENTS[@]}"; do
    kubectl scale deployment -n kagent "$agent" --replicas=1 2>/dev/null || true
    echo "  scaled down $agent" >&2
  done
}
trap cleanup EXIT

# --- Scale up ---
echo "Scaling all 6 agent deployments to ${SCALE} replicas (${SCALE} x 6 = $((SCALE * 6)) pods total)..." >&2
for agent in "${AGENTS[@]}"; do
  kubectl scale deployment -n kagent "$agent" --replicas="$SCALE"
  echo "  scaled $agent to ${SCALE}" >&2
done

# --- Wait for all 102 pods to reach 1/1 Ready ---
TARGET=$(( ${#AGENTS[@]} * SCALE ))
DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT ))
echo "" >&2
echo "Waiting for all ${TARGET} pods to reach Ready (timeout ${WAIT_TIMEOUT}s)..." >&2
while true; do
  READY=$(kubectl get pods -n kagent 2>/dev/null \
    | grep "^baseline-" | grep -c "1/1" || echo 0)
  echo "  ${READY}/${TARGET} ready..." >&2
  [[ "$READY" -ge "$TARGET" ]] && { echo "All ${TARGET} pods ready." >&2; break; }
  [[ "$(date +%s)" -gt "$DEADLINE" ]] && { echo "Timeout waiting for pods." >&2; exit 1; }
  sleep 10
done

echo "" >&2
echo "All $((SCALE * ${#AGENTS[@]})) pods ready. Settling ${SETTLE_SECS}s for CPU rate window..." >&2
sleep "$SETTLE_SECS"

# --- Scrape aggregate metrics ---
echo "" >&2
echo "Scraping Prometheus..." >&2
echo "agent,replicas,total_mem_bytes,mem_per_pod_bytes,total_cpu_millicores,cpu_per_pod_millicores" | tee "$RESULTS_DIR/scale-resources.csv"

for agent in "${AGENTS[@]}"; do
  total_mem=$(curl -sk "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=sum(container_memory_rss{namespace=\"kagent\",pod=~\"${agent}-.*\",container!=\"\"})" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['data']['result']
print(int(float(r[0]['value'][1])) if r else 0)
" 2>/dev/null || echo "0")

  total_cpu=$(curl -sk "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=sum(rate(container_cpu_usage_seconds_total{namespace=\"kagent\",pod=~\"${agent}-.*\",container!=\"\"}[2m]))*1000" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['data']['result']
print(round(float(r[0]['value'][1]), 4) if r else 0)
" 2>/dev/null || echo "0")

  mem_per_pod=$(python3 -c "print(${total_mem} // ${SCALE})")
  cpu_per_pod=$(python3 -c "print(round(${total_cpu} / ${SCALE}, 4))")

  echo "${agent},${SCALE},${total_mem},${mem_per_pod},${total_cpu},${cpu_per_pod}" | tee -a "$RESULTS_DIR/scale-resources.csv"
done

# --- Summary ---
python3 - "$RESULTS_DIR/scale-resources.csv" <<'PYEOF'
import sys, csv

rows = list(csv.DictReader(open(sys.argv[1])))

SCALE = int(rows[0]['replicas'])
PROJECT_TO = 100

print(f"\n{'Agent':<28} {'Pods':>5} {'Total Mem':>12} {'Mem/Pod':>10} {'Total CPU(m)':>13} {'CPU/Pod(m)':>11}")
print("-" * 85)

total_fleet_mem = 0
total_fleet_cpu = 0

for r in rows:
    agent = r['agent']
    total_mem = int(r['total_mem_bytes'])
    mem_per_pod = int(r['mem_per_pod_bytes'])
    total_cpu = float(r['total_cpu_millicores'])
    cpu_per_pod = float(r['cpu_per_pod_millicores'])
    total_fleet_mem += total_mem
    total_fleet_cpu += total_cpu
    mem_mb = total_mem / 1024 / 1024
    per_mb = mem_per_pod / 1024 / 1024
    print(f"{agent:<28} {SCALE:>5} {mem_mb:>10.1f}MB {per_mb:>8.1f}MB {total_cpu:>13.2f} {cpu_per_pod:>11.4f}")

print("-" * 85)
print(f"{'TOTAL fleet (' + str(SCALE * len(rows)) + ' pods)':<28} {SCALE*len(rows):>5} {total_fleet_mem/1024/1024:>10.1f}MB {'':>10} {total_fleet_cpu:>13.2f}")

print(f"\n--- Projected to {PROJECT_TO} pods per type ({PROJECT_TO * len(rows)} total) ---")
proj_mem = 0
proj_cpu = 0
for r in rows:
    mem = int(r['mem_per_pod_bytes']) * PROJECT_TO
    cpu = float(r['cpu_per_pod_millicores']) * PROJECT_TO
    proj_mem += mem
    proj_cpu += cpu
    print(f"  {r['agent']:<28}  mem={mem/1024/1024:>8.1f}MB  cpu={cpu:>7.2f}m")
print(f"  {'TOTAL':<28}  mem={proj_mem/1024/1024/1024:>7.2f}GB  cpu={proj_cpu:>7.2f}m")
PYEOF

echo ""
echo "Done. Results in $RESULTS_DIR/"

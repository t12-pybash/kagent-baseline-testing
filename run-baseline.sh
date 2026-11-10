#!/usr/bin/env bash
set -euo pipefail

# Configuration -- set these for your environment before running.
# KAGENT_DOMAIN: hostname suffix for agent A2A endpoints, e.g. kagent.example.com
#                agents are addressed as https://${agent}.${KAGENT_DOMAIN}/
# PROM_URL:      Prometheus base URL for resource scraping, e.g. http://prometheus:9090
# LITELLM_URL:   (optional) LiteLLM spend log endpoint -- only needed if the Python ADK
#                agent does not surface token counts in its A2A response metadata
: "${KAGENT_DOMAIN:?Set KAGENT_DOMAIN to your agent hostname suffix}"
: "${PROM_URL:?Set PROM_URL to your Prometheus base URL}"
LITELLM_URL="${LITELLM_URL:-}"

RESULTS_DIR="results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

AGENTS=(
  "baseline-go-minimal:What is the purpose of a Kubernetes readiness probe?"
  "baseline-python-minimal:What is the purpose of a Kubernetes readiness probe?"
  "baseline-go-k8s-tools:List all pods in the kagent namespace."
  "baseline-go-promql:Write a PromQL query for CPU usage percentage across all nodes."
  "baseline-go-long-context:What CNI is running on this cluster and what namespace is it in?"
  "baseline-go-multiturn:What is the monitoring stack on this cluster?"
)

RUNS_PER_AGENT=17

run_agent() {
  local agent=$1
  local prompt=$2
  local run=$3
  local context_id="ctx-$(date +%s%N)-${RANDOM}"
  local msg_id="msg-$(date +%s%N)-${RANDOM}"
  # prompt variation busts kagent session cache (contextId alone is not enough)
  local url="https://${agent}.${KAGENT_DOMAIN}/"

  local start_ts=$(date +%s%3N)

  local response
  response=$(curl -sk -X POST "${url}" \
    -H "Content-Type: application/json" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"id\": \"${run}\",
      \"method\": \"message/send\",
      \"params\": {
        \"message\": {
          \"messageId\": \"${msg_id}\",
          \"contextId\": \"${context_id}\",
          \"role\": \"user\",
          \"parts\": [{\"kind\": \"text\", \"text\": \"${prompt} [run ${run}]\"}]
        }
      }
    }")

  local end_ts=$(date +%s%3N)
  local latency_ms=$(( end_ts - start_ts ))

  local state prompt_tokens output_tokens
  state=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',{}).get('status',{}).get('state','error'))" 2>/dev/null || echo "parse_error")
  prompt_tokens=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); meta=d.get('result',{}).get('metadata',{}); print(meta.get('adk_usage_metadata',{}).get('promptTokenCount',0))" 2>/dev/null || echo "0")
  output_tokens=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); meta=d.get('result',{}).get('metadata',{}); print(meta.get('adk_usage_metadata',{}).get('candidatesTokenCount',0))" 2>/dev/null || echo "0")

  # Python ADK doesn't surface adk_usage_metadata -- fall back to LiteLLM spend log if configured
  if [[ "$prompt_tokens" == "0" && "$output_tokens" == "0" && -n "$LITELLM_URL" ]]; then
    local litellm_log
    litellm_log=$(curl -sk "${LITELLM_URL}/spend/logs?limit=1" 2>/dev/null || echo "[]")
    prompt_tokens=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); r=d[0] if isinstance(d,list) and d else {}; print(r.get('prompt_tokens',0))" "$litellm_log" 2>/dev/null || echo "0")
    output_tokens=$(python3 -c "import sys,json; d=json.loads(sys.argv[1]); r=d[0] if isinstance(d,list) and d else {}; print(r.get('completion_tokens',0))" "$litellm_log" 2>/dev/null || echo "0")
  fi

  echo "${agent},${run},${state},${prompt_tokens},${output_tokens},${latency_ms}"
}

scrape_resources() {
  local agent=$1
  local pod
  pod=$(kubectl get pods -n kagent -l "app.kubernetes.io/name=${agent}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$pod" ]]; then
    echo "${agent},unknown,0,0"
    return
  fi

  local mem_bytes cpu_rate
  mem_bytes=$(curl -sk "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=container_memory_rss{namespace=\"kagent\",pod=\"${pod}\",container!=\"\"}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(int(float(r[0]['value'][1])) if r else 0)" 2>/dev/null || echo "0")

  cpu_rate=$(curl -sk "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=rate(container_cpu_usage_seconds_total{namespace=\"kagent\",pod=\"${pod}\",container!=\"\"}[2m])" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); r=d['data']['result']; print(float(r[0]['value'][1])*1000 if r else 0)" 2>/dev/null || echo "0")

  echo "${agent},${pod},${mem_bytes},${cpu_rate}"
}

echo "agent,run,state,prompt_tokens,output_tokens,latency_ms" | tee "$RESULTS_DIR/results.csv"
echo "agent,pod,mem_bytes,cpu_millicores" > "$RESULTS_DIR/resources.csv"

for entry in "${AGENTS[@]}"; do
  agent="${entry%%:*}"
  prompt="${entry#*:}"

  echo "--- Starting agent: $agent ---" >&2

  for i in $(seq 1 $RUNS_PER_AGENT); do
    result=$(run_agent "$agent" "$prompt" "$i")
    echo "$result" | tee -a "$RESULTS_DIR/results.csv"
  done

  # scrape resources at peak (end of run while pod is still warm)
  resources=$(scrape_resources "$agent")
  echo "$resources" | tee -a "$RESULTS_DIR/resources.csv"
done


echo ""
echo "Done. Results in $RESULTS_DIR/"
echo ""

python3 - "$RESULTS_DIR/results.csv" "$RESULTS_DIR/resources.csv" <<'PYEOF'
import sys, csv
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
agents = defaultdict(list)
for r in rows:
    agents[r['agent']].append(r)

resources = {}
for r in csv.DictReader(open(sys.argv[2])):
    resources[r['agent']] = r

print(f"\n{'Agent':<28} {'Runs':>4} {'PromptTok':>9} {'OutputTok':>9} {'AvgLatMs':>9} {'Errors':>6} {'MemMB':>7} {'CPUm':>6}")
print("-" * 85)
for agent, runs in sorted(agents.items()):
    total = len(runs)
    errors = sum(1 for r in runs if r['state'] not in ('completed','input-required'))
    avg_prompt = sum(int(r['prompt_tokens']) for r in runs) / total
    avg_output = sum(int(r['output_tokens']) for r in runs) / total
    avg_lat = sum(int(r['latency_ms']) for r in runs) / total
    res = resources.get(agent, {})
    mem_mb = int(res.get('mem_bytes', 0)) / 1024 / 1024
    cpu_m = float(res.get('cpu_millicores', 0))
    print(f"{agent:<28} {total:>4} {avg_prompt:>9.0f} {avg_output:>9.0f} {avg_lat:>9.0f} {errors:>6} {mem_mb:>7.1f} {cpu_m:>6.2f}")
PYEOF

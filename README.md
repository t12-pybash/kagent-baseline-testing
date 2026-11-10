# kagent baseline test

A load and resource baseline for 6 kagent agent types. Measures pod memory, CPU, token usage, latency, and cost per run against a live kagent installation.

## Agent types

| # | Name | Runtime | Tools | Purpose |
|---|------|---------|-------|---------|
| 01 | go-minimal | Go | none | Minimal Go runtime baseline |
| 02 | python-minimal | Python | none | Python ADK runtime baseline |
| 03 | go-k8s-tools | Go | k8s MCP (get/describe/logs) | Tool-use overhead |
| 04 | go-promql | Go | none | Domain-specific system prompt |
| 05 | go-long-context | Go | none | Large system prompt simulating RAG context |
| 06 | go-multiturn | Go | none | Stateful multi-turn conversation |

## Prerequisites

- kagent installed and agents deployed (`kubectl apply -f agents/`)
- Each agent reachable via its A2A HTTP endpoint
- Prometheus available for resource scraping
- `kubectl` context pointing at the target cluster
- `curl`, `python3` on the machine running the script

## Running

```bash
export KAGENT_DOMAIN="kagent.example.com"      # agent hostname suffix
export PROM_URL="http://prometheus:9090"        # Prometheus base URL
export LITELLM_URL="http://litellm:4000"        # optional, Python ADK token fallback

chmod +x run-baseline.sh
./run-baseline.sh
```

Results are written to `results/<timestamp>/`:
- `results.csv` -- per-run state, token counts, latency
- `resources.csv` -- pod memory and CPU at end of run

## Manifests

`manifests/network/httproutes.yaml` exposes each agent via a Gateway API HTTPRoute. Replace the `<gateway-name>`, `<gateway-namespace>`, and `<cluster-domain>` placeholders before applying.

`manifests/network/allow-from-kagent.yaml` is a NetworkPolicy allowing the kagent namespace to reach a model serving endpoint (LiteLLM or equivalent) in the ai-platform namespace.

## Results

`results/20261109-153609/` contains the reference run against Claude Sonnet 5.5 (102 total agent runs, 17 per type). See `kagent-baseline-report.html` for the full analysis.

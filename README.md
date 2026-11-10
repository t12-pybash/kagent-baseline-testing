# kagent baseline test

Idle pod footprint baseline for 6 kagent agent types. Measures memory RSS and CPU per pod at scale (17 replicas per type, 102 pods concurrent) against a live kagent installation.

See `kagent-baseline-report.html` for the full analysis and results.

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

- kagent installed (`kubectl apply -f agents/`)
- Prometheus available and scraped -- kube-state-metrics and cAdvisor required
- `kubectl` context pointing at the target cluster
- `curl`, `python3` available on the machine running the script

## Running the scale test

```bash
export PROM_URL="http://prometheus-operated.monitoring.svc.cluster.local:9090"
chmod +x run-scale-test.sh
./run-scale-test.sh
```

The script scales all 6 deployments to 17 replicas, waits for all 102 pods to reach Ready, settles 150s for the Prometheus `rate()` window to stabilise, scrapes aggregate memory and CPU, prints a summary, then scales back down to 1 replica.

Results are written to `results/<timestamp>-scale/scale-resources.csv`.

## Reference results

`results/20261110-202924-scale/scale-resources.csv` contains the reference run on a 2-node bare-metal cluster (bare-metal results should be representative -- kagent's Go runtime overhead is independent of the underlying infrastructure).

| Agent type | Mem/pod | CPU/pod |
|------------|---------|---------|
| go-minimal | 6.6 MB | 0.77 m |
| python-minimal | 218.8 MB | 1.59 m |
| go-k8s-tools | 7.7 MB | 0.70 m |
| go-promql | 6.6 MB | 0.70 m |
| go-long-context | 6.6 MB | 0.85 m |
| go-multiturn | 6.6 MB | 0.71 m |

## Agent resource requests

All agent CRs are configured with minimal resource requests to allow high-density scheduling:

- Go types: `cpu: 1m`, `memory: 32Mi` (limits: 2 CPU, 1Gi)
- Python type: `cpu: 1m`, `memory: 256Mi` (limits: 2 CPU, 1Gi)

Adjust `modelConfig` in each agent YAML to match your cluster's ModelConfig name.

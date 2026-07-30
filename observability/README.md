# Observability Utilities

Read-only tools for checking operational observability systems before, during, and after incidents.

This area is the tooling companion for observability field notes on `trinidadmarroquin.com`, including SLO burn-rate alerting, SLO dashboards, incident review, and on-call escalation practices.

## Safety Model

- These utilities are read-only.
- They use HTTP GET APIs only.
- They do not create, update, delete, mute, silence, reload, restart, patch, or export production configuration.
- They do not print bearer tokens.
- They avoid exporting full dashboard JSON or sensitive query bodies.

## Prerequisites

- `bash`
- `curl`
- `jq`
- Optional: `column` for aligned table output

The tools assume the caller already has network access and appropriate read permissions for the target observability service.

## Environment Variables

- `PROMETHEUS_URL`: Prometheus base URL.
- `ALERTMANAGER_URL`: Alertmanager base URL.
- `GRAFANA_URL`: Grafana base URL.
- `GRAFANA_TOKEN`: Grafana API token with read access to dashboards and datasources.

Prefer environment variables or a local shell session over putting tokens in command history. Do not commit tokens, URLs, generated output, or environment-specific reports.

## Incident Response Questions

| Question | Utility |
| --- | --- |
| Are targets scrapeable? | `prometheus/prometheus-target-health-report.sh` |
| Are alerts configured with owner, severity, runbook, and dashboard context? | `prometheus/prometheus-rule-audit.sh` |
| Are Alertmanager routes understandable? | `alertmanager/alertmanager-route-audit.sh` |
| Are silences present that may affect incident visibility? | `alertmanager/alertmanager-silence-report.sh` |
| Do Grafana dashboards have datasource references? | `grafana/grafana-dashboard-datasource-audit.sh` |
| Which dashboards appear related to SLOs, burn-rate alerting, incidents, or escalation? | `grafana/grafana-dashboard-datasource-audit.sh` |

## Prometheus

### `prometheus-target-health-report.sh`

Reports unhealthy active scrape targets, including scrape pool, job, instance, health, last scrape time, last error, and scrape URL.

```bash
PROMETHEUS_URL=https://prometheus.example.com \
  ./observability/prometheus/prometheus-target-health-report.sh

./observability/prometheus/prometheus-target-health-report.sh \
  --url http://localhost:9090 \
  --output json
```

### `prometheus-rule-audit.sh`

Summarizes alerting rules and highlights common review gaps:

- inactive, pending, and firing counts
- missing `severity` labels
- missing runbook annotations
- missing dashboard annotations
- possible SLO or burn-rate rule names

```bash
PROMETHEUS_URL=https://prometheus.example.com \
  ./observability/prometheus/prometheus-rule-audit.sh
```

## Alertmanager

### `alertmanager-route-audit.sh`

Summarizes route and receiver information exposed by the Alertmanager status API. It also checks active alert groups for missing `team`, `owner`, or `severity` labels where detectable.

```bash
ALERTMANAGER_URL=https://alertmanager.example.com \
  ./observability/alertmanager/alertmanager-route-audit.sh
```

### `alertmanager-silence-report.sh`

Reports active and pending silences without creating or expiring silences.

```bash
ALERTMANAGER_URL=https://alertmanager.example.com \
  ./observability/alertmanager/alertmanager-silence-report.sh
```

## Grafana

### `grafana-dashboard-datasource-audit.sh`

Reports dashboard titles, folders, datasource references, dashboards missing datasource references, and dashboards likely related to SLO or incident-response workflows by title/tag search.

It does not print panel queries or export full dashboard JSON.

```bash
export GRAFANA_URL=https://grafana.example.com
export GRAFANA_TOKEN=REDACTED

./observability/grafana/grafana-dashboard-datasource-audit.sh
./observability/grafana/grafana-dashboard-datasource-audit.sh --output json
```

## Limitations

- API compatibility depends on Prometheus, Alertmanager, and Grafana versions.
- These tools report what the APIs expose; they do not prove that alerting strategy, escalation policy, or dashboard design is correct.
- Alertmanager route parsing is intentionally lightweight and does not replace config review.
- Grafana datasource reference detection depends on dashboard JSON structure and may miss plugin-specific references.
- These utilities should support incident review, not replace human operational judgment.

## Publication Assessment

- Security: examples use documentation-safe domains only.
- Ownership: generic observability inspection techniques.
- Safety: read-only diagnostics using HTTP GET APIs.
- Status: `READY WITH CHANGES` until reviewed with real sanitized fixture data or local test services.

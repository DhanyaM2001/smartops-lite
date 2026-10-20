"""SmartOps-Lite — MTTR Aggregator (Module 9.0).

Every 5 minutes an EventBridge schedule fires this Lambda, which:
  1. Scans the `smartops-incidents` DDB table for rows in the last `WINDOW_MINUTES`
     (default 60).
  2. Computes 4 metric families:
       - IncidentCount (total + per reason)
       - MTTRSeconds (avg time from ingestedAt → acknowledgedAt, per reason)
       - AckRatePercent (0-100)
       - RCASourceCount (groq / fallback / none)
  3. Publishes as custom CloudWatch metrics under the `SmartOps` namespace.

Grafana Cloud reads those metrics via its CloudWatch data source. See
`dashboards/grafana/mttr-dashboard.json` for the panel wiring.
"""

__version__ = "0.1.0"

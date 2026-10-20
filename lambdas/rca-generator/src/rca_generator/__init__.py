"""SmartOps-Lite RCA-generator Lambda.

Consumes IncidentDetected events from the smartops-controller (Module 4),
persists them to DynamoDB, and posts a plain-text ping to Slack.

Design goals for Module 5.0:
  - Zero external Python dependencies. boto3 is pre-bundled in the Lambda
    Python runtime; Slack uses stdlib urllib.request. Keeps the deployment
    zip < 50 KB and cold-starts < 300 ms.
  - Idempotent by incidentId. DynamoDB PutItem is unconditional — the
    controller already dedups on (namespace, pod, container, reason), and
    even if it didn't, re-writes carry the same key.
  - Fails LOUD (raise) on schema errors so EventBridge retries; fails
    SOFT (log + continue) on Slack errors so DDB writes are never blocked
    by an outage of a downstream side-effect.

Module 6 will layer Groq LLM enrichment + Block Kit Slack formatting.
"""

__version__ = "0.1.0"

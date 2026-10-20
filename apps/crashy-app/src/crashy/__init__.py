"""crashy-app — a deliberately-failing FastAPI microservice.

Consumed by SmartOps-Lite's K8s controller (Module 4) to exercise the
incident-triage pipeline: /crash, /oom, /500, /slow reproduce the four
failure signatures the controller detects.
"""

__version__ = "0.1.0"

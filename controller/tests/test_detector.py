"""Unit tests for detector.detect() — all pure, no K8s I/O."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from smartops_controller.detector import (
    BAD_TERMINATED_REASONS,
    BAD_WAITING_REASONS,
    detect,
)


def _pod(
    *,
    namespace: str = "demo",
    name: str = "crashy-abc",
    uid: str = "uid-123",
    node: str = "node-1",
    phase: str = "Running",
    labels: dict[str, str] | None = None,
    container_statuses: list[dict[str, Any]] | None = None,
    message: str = "",
) -> SimpleNamespace:
    """Build a fake pod that quacks like `V1Pod` well enough for detect()."""
    return SimpleNamespace(
        metadata=SimpleNamespace(
            namespace=namespace,
            name=name,
            uid=uid,
            labels=labels or {},
        ),
        spec=SimpleNamespace(node_name=node),
        status=SimpleNamespace(
            phase=phase,
            message=message,
            container_statuses=[SimpleNamespace(**cs) for cs in (container_statuses or [])],
        ),
    )


def _cs(
    *,
    name: str = "crashy",
    restart_count: int = 0,
    waiting_reason: str = "",
    terminated_reason: str = "",
    exit_code: int | None = None,
    message: str = "",
) -> dict[str, Any]:
    """Container status factory."""
    state = SimpleNamespace(
        waiting=SimpleNamespace(reason=waiting_reason, message=message) if waiting_reason else None,
        terminated=None,
        running=None,
    )
    last_state = SimpleNamespace(
        waiting=None,
        terminated=SimpleNamespace(
            reason=terminated_reason, exit_code=exit_code, message=message
        )
        if terminated_reason
        else None,
        running=None,
    )
    return {
        "name": name,
        "restart_count": restart_count,
        "state": state,
        "last_state": last_state,
    }


def test_healthy_pod_yields_no_incidents():
    pod = _pod(container_statuses=[_cs(name="crashy", restart_count=0)])
    assert detect(pod) == []


def test_crash_loop_backoff_is_detected():
    pod = _pod(
        container_statuses=[
            _cs(
                name="crashy",
                restart_count=5,
                waiting_reason="CrashLoopBackOff",
                message="Back-off 5m0s restarting failed container",
            )
        ]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    inc = incidents[0]
    assert inc.reason == "CrashLoopBackOff"
    assert inc.restart_count == 5
    assert inc.container_name == "crashy"
    assert inc.pod_name == "crashy-abc"
    assert inc.namespace == "demo"


def test_oom_killed_is_detected():
    pod = _pod(
        container_statuses=[
            _cs(
                name="crashy",
                restart_count=1,
                terminated_reason="OOMKilled",
                exit_code=137,
            )
        ]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "OOMKilled"
    assert incidents[0].exit_code == 137


def test_error_exit_with_zero_code_is_ignored():
    """Some runtimes report `reason=Error, exit_code=0` on normal termination."""
    pod = _pod(
        container_statuses=[_cs(name="c", terminated_reason="Error", exit_code=0)]
    )
    assert detect(pod) == []


def test_error_exit_with_nonzero_code_is_reported():
    pod = _pod(
        container_statuses=[_cs(name="c", terminated_reason="Error", exit_code=42)]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].exit_code == 42


def test_image_pull_backoff_detected():
    pod = _pod(container_statuses=[_cs(name="c", waiting_reason="ImagePullBackOff")])
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "ImagePullBackOff"


def test_pod_phase_failed_is_detected():
    pod = _pod(phase="Failed", message="something went catastrophically wrong")
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "PodFailed"
    assert incidents[0].container_name == "<pod>"


def test_dedup_key_shape():
    pod = _pod(container_statuses=[_cs(name="c", waiting_reason="CrashLoopBackOff")])
    inc = detect(pod)[0]
    assert inc.dedup_key() == ("demo", "crashy-abc", "c", "CrashLoopBackOff")


def test_multiple_containers_multiple_incidents():
    pod = _pod(
        container_statuses=[
            _cs(name="c1", waiting_reason="CrashLoopBackOff"),
            _cs(name="c2", terminated_reason="OOMKilled", exit_code=137),
        ]
    )
    incidents = detect(pod)
    reasons = sorted(i.reason for i in incidents)
    assert reasons == ["CrashLoopBackOff", "OOMKilled"]


def test_zone_extracted_from_labels():
    pod = _pod(
        labels={"topology.kubernetes.io/zone": "ap-south-1a"},
        container_statuses=[_cs(name="c", waiting_reason="CrashLoopBackOff")],
    )
    incidents = detect(pod)
    assert incidents[0].zone == "ap-south-1a"


def test_oom_beats_crashloopbackoff_for_same_container():
    """OOM (or other specific terminated reason) beats CrashLoopBackOff.

    Kubernetes routinely surfaces `waiting: CrashLoopBackOff` for a container
    whose previous instance was actually killed by the OOM killer — reporting
    "CrashLoopBackOff" would hide the root cause and confuse the RCA prompt.
    The detector now prefers the specific terminated reason and carries the
    exit code through, so `make chaos-oom` surfaces as "OOMKilled" end-to-end.

    Any other waiting reason (ImagePullBackOff, CreateContainerConfigError, …)
    still wins over last-state — those aren't hiding a deeper cause.
    """
    pod = _pod(
        container_statuses=[
            _cs(
                name="c",
                waiting_reason="CrashLoopBackOff",
                terminated_reason="OOMKilled",
                exit_code=137,
            )
        ]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "OOMKilled"
    assert incidents[0].exit_code == 137


def test_crashloopbackoff_alone_still_reports_crashloopbackoff():
    """Regression guard: no terminated data → keep the CrashLoopBackOff reason."""
    pod = _pod(
        container_statuses=[_cs(name="c", waiting_reason="CrashLoopBackOff")]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "CrashLoopBackOff"


def test_crashloopbackoff_with_zero_exit_error_still_reports_crashloopbackoff():
    """Runtime quirk: reason='Error' + exit_code=0 → treat as noise, keep CLBO."""
    pod = _pod(
        container_statuses=[
            _cs(
                name="c",
                waiting_reason="CrashLoopBackOff",
                terminated_reason="Error",
                exit_code=0,
            )
        ]
    )
    incidents = detect(pod)
    assert len(incidents) == 1
    assert incidents[0].reason == "CrashLoopBackOff"


def test_all_bad_reasons_recognized():
    """Sanity: exhaustive coverage of the reason lists."""
    for reason in BAD_WAITING_REASONS:
        pod = _pod(container_statuses=[_cs(name="c", waiting_reason=reason)])
        assert len(detect(pod)) == 1, f"missed waiting reason: {reason}"

    for reason in BAD_TERMINATED_REASONS:
        pod = _pod(
            container_statuses=[_cs(name="c", terminated_reason=reason, exit_code=1)]
        )
        assert len(detect(pod)) == 1, f"missed terminated reason: {reason}"


def test_incident_to_dict_stable_schema():
    pod = _pod(container_statuses=[_cs(name="c", waiting_reason="CrashLoopBackOff")])
    inc = detect(pod)[0]
    d = inc.to_dict()
    for key in (
        "schemaVersion",
        "incidentId",
        "namespace",
        "podName",
        "podUid",
        "containerName",
        "reason",
        "restartCount",
        "nodeName",
        "zone",
        "timestamp",
        "message",
        "exitCode",
        "labels",
    ):
        assert key in d, f"schema drift: {key} missing"
    assert d["schemaVersion"] == "1.0"

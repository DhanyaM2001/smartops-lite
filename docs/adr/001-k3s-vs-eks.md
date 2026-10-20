# ADR-001: K3s on EC2 instead of Amazon EKS

**Status:** Accepted
**Date:** 2026-08-04
**Deciders:** dhanym

## Context

The project needs a Kubernetes cluster on AWS. The two dominant options are:

- **Amazon EKS** — AWS-managed control plane, industry default for K8s on AWS.
- **K3s** — a CNCF-conformant lightweight K8s distribution (by SUSE/Rancher) that runs on any Linux VM.

Constraints:
- Hard $0 monthly AWS spend target.
- 20-day timeline.
- Author is showcasing "Kubernetes on AWS" for a Cloud/DevOps/SRE resume story.

## Decision

**Use K3s on 2× EC2 t3.micro (multi-AZ).**

## Rationale

### Cost — the dominant driver

| Option | Control plane cost | Data plane cost | Monthly total (2 workers) |
|---|---|---|---|
| EKS | **$72/mo** (~$0.10/hr) | 2× t3.micro (free tier) | **~$72** |
| K3s on EC2 | $0 (runs on same instance as workloads) | 2× t3.micro (free tier) | **$0** |

At $72/mo, EKS alone breaks the "strict $0" constraint. Even one EKS session per week ($0.10 × 3hr = $0.30/day, ~$6/mo) is 3× the total project budget.

### Functional equivalence — matters for resume claims

- K3s is [CNCF-certified Kubernetes conformant](https://www.cncf.io/certification/software-conformance/) — the same test suite as EKS, GKE, AKS, kind, minikube.
- Every `kubectl` command, every Helm chart, every YAML manifest works identically.
- K3s is used **in production** by Rancher/SUSE for edge, and by companies like Roblox and Shopify for edge/lightweight workloads.
- On the resume, "Kubernetes" is accurate. In the README, we explicitly call out the choice ("used K3s in place of EKS for cost; production topology would use EKS").

### What we lose by choosing K3s

- No AWS-managed control plane (we're on the hook for cluster upgrades).
- No native AWS Load Balancer Controller (mitigated: NGINX Ingress).
- No IRSA out-of-the-box (mitigated: we can either install `pod-identity-webhook` on K3s, or use an SSM RunCommand-based Lambda→cluster bridge — simpler for the remediator).
- Slightly less "click-through" familiar to a hiring manager expecting EKS.

### What we gain

- $0 spend.
- Faster cluster spin-up (~90 sec vs ~10 min for EKS).
- Fewer moving parts to debug.
- A more interesting decision to *explain* in interviews ("here's why we chose K3s; here are the trade-offs; here's when we'd switch to EKS at scale").

## Consequences

### Positive
- Hard $0 constraint met.
- Cluster is entirely destroyed by `terraform destroy` (EKS orphans can linger).
- We learn K8s at a deeper level (managing the control plane ourselves = more Linux/networking exposure).

### Negative
- Author must know how to operate K3s (upgrades, disaster recovery, backups) if project is extended.
- Some AWS-native integrations (Load Balancer Controller, EBS CSI driver auto-provisioning) don't come for free.

### Mitigations
- README + interview prep explicitly cover *when* one would switch to EKS (any prod system with SLA > 99.5%, multi-tenancy, or team > 2 people).
- Terraform code has a **feature flag `use_eks`** (documented in code) → in principle switching to EKS is a one-var change. We won't test this in the 20-day window but the door is open.

## Alternatives briefly considered

- **kind on local machine only** — rejected: doesn't demonstrate "on AWS" for the resume story.
- **Minikube on EC2** — rejected: minikube is dev-only, not conformant for production claims.
- **k0s on EC2** — similar to K3s; K3s chosen because of better community + tooling (`k3sup`).
- **Standalone kubeadm on EC2** — rejected: much slower to bootstrap, no upgrade tooling.
- **KubeEdge / MicroShift** — rejected: too niche, distracts from AWS story.

## References

- [K3s docs](https://docs.k3s.io/)
- [CNCF Kubernetes Conformance list](https://www.cncf.io/certification/software-conformance/)
- Cost calc: `aws pricing get-products --service-code AmazonEKS` (Aug 2026)

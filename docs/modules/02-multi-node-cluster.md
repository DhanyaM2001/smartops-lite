# Module 2 — Multi-node K3s (add agent in AZ-b)

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins.

**Duration:** ~15 min (5 min for TF apply + ~5 min for cloud-init on the agent).
**Prerequisites:** Module 1 complete — K3s server node running, `~/.kube/config-smartops` present.
**Deliverable:** 2-node K3s cluster spanning AZ-a (server) + AZ-b (agent), ready for anti-affinity workloads.
**Cost impact:** Doubles compute to 2 × t3.micro. Still free-tier eligible (750 hr/mo per instance).

---

## What lands in this module

**No new files.** Module 2 is a wiring change on top of the reusable modules already built in Module 1.

**Changed files:**
- `infra/envs/dev/variables.tf` — added `enable_agent` (default `true`) and `agent_instance_type` (default `t3.micro`)
- `infra/envs/dev/main.tf` — added `module "k3s_agent"` block (uses `count = var.enable_agent ? 1 : 0`)
- `infra/envs/dev/outputs.tf` — added `k3s_agent_*` outputs (return `null` when disabled) and `expected_node_count`
- `scripts/verify.sh` — Module 2 gate now reads `expected_node_count` from TF and also checks that nodes span ≥2 AZs

**New docs:**
- `docs/modules/02-multi-node-cluster.md` (this file)

---

## Architecture

```
    ┌──────────────────────────────────────────────────────┐
    │  ap-south-1                                          │
    │  ┌──────────────────────────────────────────────┐   │
    │  │ VPC 10.0.0.0/16                              │   │
    │  │                                              │   │
    │  │  ┌──────────────────┐  ┌──────────────────┐ │   │
    │  │  │ AZ-a             │  │ AZ-b             │ │   │
    │  │  │ 10.0.1.0/24      │  │ 10.0.2.0/24      │ │   │
    │  │  │                  │  │                  │ │   │
    │  │  │ ┌──────────────┐ │  │ ┌──────────────┐ │ │   │
    │  │  │ │ K3s SERVER   │ │  │ │ K3s AGENT    │ │ │   │
    │  │  │ │ (Module 1)   │ │  │ │ (Module 2)   │ │ │   │
    │  │  │ │              │ │  │ │              │ │ │   │
    │  │  │ │ role=server  │ │  │ │ role=agent   │ │ │   │
    │  │  │ │ writes SSM   │◄─┼──┼─┤ reads SSM   │ │ │   │
    │  │  │ │ join_token   │ │  │ │ join_token  │ │ │   │
    │  │  │ │ server_url   │ │  │ │ server_url  │ │ │   │
    │  │  │ └──────────────┘ │  │ └──────────────┘ │ │   │
    │  │  └──────────────────┘  └──────────────────┘ │   │
    │  │                                              │   │
    │  │  Intra-SG: allow-all (nodes talk to each     │   │
    │  │  other over the flannel VXLAN overlay).      │   │
    │  └──────────────────────────────────────────────┘   │
    └──────────────────────────────────────────────────────┘
```

**Key insight:** the same `infra/modules/k3s` module powers both nodes. The
`role` variable flips the cloud-init template's install branch. This is what
kept Module 2 to ~4 file edits instead of 15.

---

## Handshake (how the agent finds the server)

The server-agent join dance is fully asynchronous — no Terraform runtime
dependency between them:

1. **Server bootstraps** (via cloud-init):
   - Installs K3s server
   - Waits for its own kubeconfig at `/etc/rancher/k3s/k3s.yaml`
   - Writes to SSM:
     - `/smartops/dev/kubeconfig` (SecureString) — for your laptop
     - `/smartops/dev/k3s_join_token` (SecureString) — for agents
     - `/smartops/dev/k3s_server_url` (String) — for agents

2. **Agent bootstraps** (via cloud-init):
   - Polls SSM for both `k3s_join_token` and `k3s_server_url`
   - Retries every 5 s, up to 60 times (5 min ceiling)
   - Once both are present, runs `K3S_URL=... K3S_TOKEN=... curl -sfL https://get.k3s.io | sh -`
   - Agent registers itself with the server

If the agent gives up (5 min server-still-not-ready), you'll see it in
`cloud-init-output.log` on the agent — force-recreate via `terraform
apply -replace=module.k3s_agent[0].aws_instance.this`.

---

## Steps to execute

### 1. Verify Module 1 state

```bash
make kube-config
```

Expect it to write `~/.kube/config-smartops`, which means the K3s server in AZ-a has finished booting. (`make status` shows this too, but its cost line calls Cost Explorer, $0.01 per run.)

### 2. Apply Module 2

```bash
make tf-plan
# Expect: 1 new resource — 1 aws_instance (the agent)
make tf-apply
```

TF finishes in ~30 s. The agent EC2 then spends ~3–5 min in cloud-init
before it registers with the server.

### 3. Watch the agent join

```bash
export KUBECONFIG=~/.kube/config-smartops
watch -n5 kubectl get nodes -o wide
```

You should see the second node transition:
```
NAME           STATUS     ROLES                  AGE   VERSION
ip-10-0-1-xx   Ready      control-plane,master   1h    v1.29.x+k3s1
ip-10-0-2-yy   NotReady   <none>                 45s   v1.29.x+k3s1   ← joining
```
then:
```
ip-10-0-1-xx   Ready      control-plane,master   1h    v1.29.x+k3s1
ip-10-0-2-yy   Ready      <none>                 2m    v1.29.x+k3s1   ← done
```

The sample output is from when this module was written; the recorded run had K3s `v1.36.4+k3s1` (the installer uses the stable channel).

### 4. Verify

```bash
make verify
```

The Module 2 block now reports:
- ✔ `2 node(s) Ready (matches expected=2)`
- ✔ `nodes span 2 distinct AZ(s) — anti-affinity possible`

If the agent hasn't joined yet, it reports:
- `— 1 of 2 node(s) Ready — agent may still be joining` (SKIP, not fail)

### 5. Quick anti-affinity demo (without Helm)

We won't have the crashy-app Helm chart until Module 3, but you can prove
anti-affinity works right now:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-spread
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels: { app: nginx-spread }
  template:
    metadata:
      labels: { app: nginx-spread }
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - topologyKey: topology.kubernetes.io/zone
              labelSelector:
                matchLabels: { app: nginx-spread }
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits:   { cpu: 100m, memory: 64Mi }
EOF

# Wait a few seconds, then check:
kubectl get pods -l app=nginx-spread -o wide
```

Expect the two pods on **different nodes in different AZs**. Clean up:
```bash
kubectl delete deployment nginx-spread
```

### 6. End of day

```bash
make eod
```

Destroys both nodes + everything else Module 1+2 created. `terraform
destroy` handles the order: agent EC2 first, then server, then VPC.

---

## Toggling back to Module 1 (single-node)

If you want to test the cheaper single-node mode:

```bash
# 1. Edit infra/envs/dev/terraform.tfvars — or use the CLI:
cd infra/envs/dev
terraform apply -var="enable_agent=false" -auto-approve
```

Result: agent EC2 destroyed, server unchanged. `kubectl get nodes` will
show 1 node again. Cost drops back to Module-1 baseline.

To go back to multi-node, `-var="enable_agent=true"` (or drop the flag —
default is `true`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply` succeeds but agent stuck in `NotReady` after 10 min | SSM params never populated by server | SSM Run Command on server: `cat /var/log/cloud-init-output.log \| tail -50`. If server never uploaded params, agent's cloud-init will time out. |
| Agent EC2 exists but never appears in `kubectl get nodes` | Cloud-init on agent failed before running k3s installer | SSM Run Command on agent: `journalctl -u k3s-agent -n 100` or `tail -100 /var/log/cloud-init-output.log` |
| Agent joined but same AZ as server (both `NAME: ip-10-0-1-*`) | You edited `public_subnet_cidrs` to a single CIDR | Restore two CIDRs, re-apply. VPC won't be recreated. |
| `kubectl get nodes` — cert error | Kubeconfig has old server IP after a server rebuild | `make kube-config` again |
| Server rebuilt, agent still connected to old server IP | K3s agent cached the server URL | Recreate agent: `terraform apply -replace=module.k3s_agent[0].aws_instance.this` |
| Verify says "all N nodes in same AZ" | Two subnets in same AZ (misconfigured `public_subnet_cidrs`) | Ensure CIDRs are spread — the VPC module maps them 1:1 to `available_zones.names` |

---

## What this unblocks for future modules

- **Module 3 (Helm + crashy-app):** now we can deploy 2 replicas with pod anti-affinity across AZs and prove HA. Also 2 nodes means we can drain one and see pods reschedule.
- **Module 4 (controller):** the K8s controller pod schedules on either node — RBAC + IRSA (added in Module 4) work identically on multi-node.
- **Module 5 (EventBridge):** node role's IAM policy already scopes SSM access — will just add `events:PutEvents` inline permission.
- **Module 7 (chaos scenarios):** `chaos-crash` on a node = the whole node terminates — with 2 nodes we can survive it. Very good demo material.

# Module 1 — Terraform: VPC + single-node K3s

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins.

**Duration:** ~90 min (mostly waiting for `terraform apply` and cloud-init).
**Prerequisites:** Module 0 complete (SSM secrets stored, `scripts/.backend-values` present).
**Deliverable:** A single-node K3s cluster on EC2 t3.micro, reachable via SSM port-forward.
**Cost impact:** ~$0/day on free tier (t3.micro is 750 hr/mo free; EBS 20 GB is under the 30 GB free ceiling).

---

## What lands in this module

```
infra/
├── envs/dev/
│   ├── versions.tf              (Terraform + provider pins)
│   ├── providers.tf             (AWS provider with default_tags)
│   ├── backend.tf               (partial S3 backend — init supplies rest)
│   ├── variables.tf             (env-level knobs)
│   ├── main.tf                  (wires modules together)
│   ├── outputs.tf               (kubeconfig cmd + tunnel cmd + IDs)
│   └── terraform.tfvars.example
└── modules/
    ├── vpc/                     (10.0.0.0/16, 2 public subnets, IGW, RT)
    ├── security-group/          (K3s SG: intra-cluster + egress-all)
    ├── iam/                     (node role: SSM + SSM put/get + KMS)
    └── k3s/                     (EC2 instance + cloud-init bootstrap)
```

---

## The architecture

```
    ┌─────────────────────────────────────────────┐
    │  Your laptop (WSL Ubuntu)                    │
    │                                              │
    │  aws ssm start-session --target i-...       │
    │   └─ port-forward :6443 → EC2:6443          │
    │                                              │
    │  kubectl --kubeconfig=~/.kube/config-smartops│
    │   ├─ pulled from SSM SecureString           │
    │   └─ server: https://127.0.0.1:6443         │
    └─────────────────────────────────────────────┘
                          │ AWS SSM
                          ▼
    ┌─────────────────────────────────────────────┐
    │  ap-south-1                                  │
    │  ┌─────────────────────────────────────┐    │
    │  │ VPC 10.0.0.0/16                      │    │
    │  │  ┌────────────────┐ ┌──────────────┐│    │
    │  │  │ Public subnet A │ │Public subnetB││    │
    │  │  │ 10.0.1.0/24     │ │10.0.2.0/24   ││    │
    │  │  │                 │ │              ││    │
    │  │  │ ┌─────────────┐ │ │  (Module 2   ││    │
    │  │  │ │ K3s server  │ │ │  adds agent  ││    │
    │  │  │ │ t3.micro    │ │ │  here)       ││    │
    │  │  │ └─────────────┘ │ │              ││    │
    │  │  └────────────────┘ └──────────────┘│    │
    │  │           │                          │    │
    │  │           ▼                          │    │
    │  │        IGW                           │    │
    │  └───────────┬──────────────────────────┘    │
    │              ▼                                │
    │         Internet                              │
    └───────────────────────────────────────────────┘

    SSM Parameter Store:
      /smartops/dev/kubeconfig       ← uploaded by cloud-init
      /smartops/dev/k3s_join_token   ← for Module 2 agent
      /smartops/dev/k3s_server_url   ← for Module 2 agent
      /smartops/dev/slack_webhook    ← Module 0
      /smartops/dev/groq_api_key     ← Module 0
```

Key design choices:
- **No open ports.** Port 22 (SSH) and 6443 (K8s API) are closed to the internet. All access is via AWS SSM Session Manager, which uses IAM auth over the AWS backbone.
- **Public subnets, no NAT.** Egress uses the IGW directly. NAT gateway would be $32/mo per AZ.
- **Cloud-init installs K3s, not us.** The EC2 boots, runs `bootstrap-k3s.sh`, and uploads its own kubeconfig to SSM. Our laptop pulls it from there.
- **Multi-AZ subnets from day 1**, but only one instance for now — Module 2 fills the second AZ.

---

## Steps to execute (after Module 0)

### 1. Verify Module 0 state

```bash
make verify-secrets
```

Expect two rows, `slack_webhook` and `groq_api_key`, and check that `scripts/.backend-values` exists (written by `make bootstrap-backend`). `make status` shows the bucket and lock table too, but its cost line calls Cost Explorer, which is $0.01 per run.

If anything is missing, complete Module 0 first ([`INSTALL.md` §4](../INSTALL.md#4-bootstrap-the-state-backend-and-secrets-once)).

### 2. Terraform init

```bash
make tf-init
```

Under the hood:
- Sources `scripts/.backend-values` (bucket, table, region)
- Runs `terraform init -reconfigure -backend-config=...`
- Downloads AWS + cloudinit providers
- Locks the state via DynamoDB

If you ever migrate to a new account, delete `scripts/.terraform/` locally and re-run `make bootstrap-backend` then `make tf-init`.

### 3. Terraform plan

```bash
make tf-plan
```

Expect ~20 resources to be created:
- 1 VPC
- 1 IGW
- 2 subnets + 1 route table + 2 route table associations
- 1 security group + ingress/egress rules
- 1 IAM role + 1 policy + 1 policy attachment + 1 instance profile
- 1 EC2 instance
- (data lookups for AMI, caller identity, region — not real resources)

### 4. Terraform apply

```bash
make tf-apply
```

Runtime: ~2 min for TF, then ~3 min for cloud-init to install K3s and upload the kubeconfig.

After apply, verify cloud-init finished on the EC2:
```bash
INSTANCE_ID=$(cd infra/envs/dev && terraform output -raw k3s_server_instance_id)
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status --long"]' \
  --query 'Command.CommandId' --output text
# then
aws ssm get-command-invocation --command-id <ID> --instance-id $INSTANCE_ID \
  --query 'StandardOutputContent'
```

Expect `status: done`.

### 5. Fetch the kubeconfig

```bash
make kube-config
```

Under the hood, it waits (up to 30 × 10 s) until `/smartops/dev/k3s_server_instance_id` in SSM matches the current server, then runs `eval "$(terraform output -raw kubeconfig_fetch_cmd)"`, which expands to:
```
aws ssm get-parameter --name /smartops/dev/kubeconfig --with-decryption \
  --query Parameter.Value --output text --region ap-south-1
```
… rewrites the server URL to `https://127.0.0.1:6443` (the tunnel) and writes `~/.kube/config-smartops` with mode 600.

### 6. Open the API tunnel + talk to the cluster

```bash
# In one terminal — leave it running
make kube-api-tunnel

# In another terminal
export KUBECONFIG=~/.kube/config-smartops
kubectl get nodes
# NAME              STATUS   ROLES                  AGE   VERSION
# ip-10-0-1-xxx     Ready    control-plane,master   3m    v1.29.x+k3s1
```

The sample output is from when this module was written. The K3s installer uses the stable channel, so the version changes; the recorded run had `v1.36.4+k3s1`.

Alternative (skip the tunnel): edit `$KUBECONFIG` to keep the public-IP endpoint, then add a temporary ingress rule to your SG allowing 6443 from your IP. Simpler but leaves the API server exposed.

### 7. Verify

```bash
make verify --module 2
```

Expect all Module 0 + Module 1 checks to pass. Module 3+ still SKIP because we haven't built those yet.

### 8. End of day

```bash
make eod
```

Destroys the EC2 + VPC + IAM role + SG. Keeps the tf-state bucket, DDB lock, SSM secrets. Next morning, `make tf-apply` + `make kube-config` gets you back to a working cluster in ~5 min.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init` fails: "bucket not found" | Ran before `make bootstrap-backend` | `make bootstrap-backend` first |
| `terraform init` fails: "backend config missing" | `scripts/.backend-values` deleted or corrupted | Re-run `make bootstrap-backend` |
| `terraform apply` times out on instance | AMI filter didn't match — Canonical moved to a new naming scheme | Check `data.aws_ami.ubuntu` filter in `infra/envs/dev/main.tf` |
| `make kube-config` returns empty | Cloud-init hasn't finished uploading yet, or IAM role misses SSM PutParameter | Wait 60s, retry. If still empty, SSM Run Command on the instance: `cat /var/log/cloud-init-output.log \| tail -50` |
| `kubectl get nodes` — `x509: cert not valid for 127.0.0.1` | Server cert lacks a SAN for 127.0.0.1 | Cloud-init already sets `--tls-san <public-ip>`. Use the public IP in kubeconfig instead of tunneling; or generate a new cert including 127.0.0.1 |
| `kubectl` — connection refused | SSM tunnel dropped | Restart `aws ssm start-session ...` |
| Node status `NotReady` | K3s still starting; can take 60-90s after cloud-init reports done | `kubectl describe node` shows what's missing |
| `make tf-destroy` — VPC hangs | Some ENI still attached from a Lambda or stale ALB | `bash scripts/teardown.sh` — force-terminates EC2 + retries destroy |

---

## What we still need for later modules

Marked here so we don't forget when Module 2+ arrives:

- **Module 2:** second EC2 (agent role). Cloud-init already handles agent role — we just need another `module "k3s_agent"` block using `role = "agent"` and subnet index 1.
- **Module 3 (crashy-app):** open port 80/443 on SG once we deploy an Ingress controller.
- **Module 4 (controller):** need IRSA. Requires enabling OIDC provider — will add to IAM module.
- **Module 5 (EventBridge):** attach `events:PutEvents` policy to the node role's inline policy.
- **Module 8 (CI):** GitHub Actions needs an OIDC role to `terraform plan` — separate IAM role, will land in `infra/envs/dev/ci-oidc.tf`.

---

## What could go wrong (blast-radius awareness)

| Risk | Blast radius | Mitigation |
|---|---|---|
| Forgetting to `make eod` | t3.micro at ~$0.0104/hr = $0.25/day | Optional zero-spend budget (set up by hand), `make check-orphans` in EOD |
| Cloud-init secret leak via SSM | Slack webhook + Groq key exposed if IAM policy is too permissive | Role's SSM read is scoped to `/smartops/dev/*` only |
| tf-state corruption | Can't `terraform destroy` cleanly | S3 versioning is on — roll back to previous state version. Or `scripts/teardown.sh` force-cleans |
| Someone runs `terraform apply` from two machines simultaneously | Corrupt state | DynamoDB lock prevents this |
| Public IP scan → SSM daemon has CVE | Root compromise | SSM agent auto-updates, IMDSv2 required, no port 22, no admin key on box |

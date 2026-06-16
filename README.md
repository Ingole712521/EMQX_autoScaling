# EMQX on AWS — Production Demo

End-to-end **EMQX 5.8** cluster on AWS: one **core** node (cluster coordination + dashboard), **auto-scaled replicants** (MQTT traffic via NLB), step scaling **+1 / −1**, and automated proof/load scripts.

**Default region:** `ap-south-1`  
**Primary stack:** Terraform at the **repo root** (where `terraform.tfvars` lives)  
**Scripts:** PowerShell Core (`.ps1`) with Bash wrappers (`.sh`) for Git Bash / Linux

---

## Table of contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Installation by platform](#installation-by-platform)
   - [Windows](#windows)
   - [macOS](#macos)
   - [Linux](#linux)
   - [Git Bash / WSL (Windows)](#git-bash--wsl-windows)
4. [AWS account setup](#aws-account-setup)
5. [Project configuration](#project-configuration)
6. [Deploy](#deploy)
7. [Verify and prove](#verify-and-prove)
8. [Load testing and autoscaling demo](#load-testing-and-autoscaling-demo)
9. [Access URLs](#access-urls)
10. [Tear down](#tear-down)
11. [Recommended demo order](#recommended-demo-order)
12. [Troubleshooting](#troubleshooting)
13. [Project layout](#project-layout)
14. [Security and cost](#security-and-cost)
15. [Further reading](#further-reading)

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────┐
│  NLB :1883 TCP  │  cross-zone, flow-hash per connection
└────────┬────────┘
         │  target group (healthy = MQTT :1883)
         ▼
┌─────────────────────────────┐
│  ASG: replicants (1–4)      │  OSS peer nodes, join via SSM seeds
│  public subnets, ELB health  │
└────────┬────────────────────┘
         │  cluster (5369/4370)
         ▼
┌─────────────────────────────┐
│  EC2 core (1 node + EIP)    │  OSS peer node, dashboard :18083
│  publishes SSM discovery    │
└─────────────────────────────┘
```

| Component | Role |
|-----------|------|
| **Core** | Fixed node + dashboard at `http://<core-eip>:18083`; not behind NLB |
| **Replicants** | ASG nodes; all MQTT client traffic via NLB |
| **NLB** | Distributes TCP connections across healthy replicants |
| **SSM** | Cluster discovery parameters (`/emqx-prod/core-private-ip`, `/emqx-prod/cluster-seeds`) |

Detailed diagram: [`docs/architecture.md`](docs/architecture.md).  
Optional modular stack (3 cores, private subnets): [`terraform/`](terraform/) — separate `terraform apply` from that folder.

### Autoscaling

| Action | Trigger |
|--------|---------|
| **Scale out +1** | NLB `ProcessedBytes` **or** ASG `NetworkIn` (Maximum) > ~5 KB/s for **2×60s**, or CPU > 25% |
| **Scale in −1** | ASG average CPU < **5%** for **2×30s** |
| **Cooldown** | 60s scale-out; 0s scale-in |
| **Bounds** | min = 1, max = 4 replicants |

### Performance tuning (bootstrap)

All EC2 nodes apply [EMQX Linux performance tuning](https://docs.emqx.com/en/emqx/latest/performance/tune.html) during user-data bootstrap via `userdata/emqx-performance-tune.sh`:

| Layer | Settings applied |
|-------|------------------|
| **Swap** | Disabled (`swapoff`, commented in `/etc/fstab`) |
| **File descriptors** | `fs.file-max`, `limits.conf`, systemd `LimitNOFILE` (default 2,097,152) |
| **Process limits** | `nproc` limits + systemd `LimitNPROC` |
| **TCP / kernel** | `somaxconn`, `tcp_max_syn_backlog`, `netdev_max_backlog`, port range, socket buffers, `tcp_fin_timeout`, conntrack (when available) |
| **EMQX VM** | `node.max_ports`, core-only `node.dist_buffer_size` |
| **EMQX MQTT** | Listener `acceptors` + `max_connections`, session `max_inflight`, `max_awaiting_rel` |

Tune via `terraform.tfvars` (optional):

```hcl
emqx_tune_nofile              = 2097152
emqx_tune_max_ports           = 2097152
emqx_tune_acceptors           = 64
emqx_tune_max_connections     = 1024000
emqx_tune_dist_buffer_size_kb = 2097151   # core node only
```

Validation is logged to `/var/log/emqx-bootstrap.log` (`PERF:` lines). After deploy, instance refresh replicants if you change tuning values.

---

## Prerequisites

Install these on the machine you use to run Terraform and scripts:

| Tool | Version | Purpose |
|------|---------|---------|
| **Terraform** | ≥ 1.5 | Deploy AWS infrastructure |
| **AWS CLI** | v2 | Credentials, SSM, health checks |
| **PowerShell Core (`pwsh`)** | ≥ 7 | Run `.ps1` deploy/verify/load scripts |
| **Python 3** | ≥ 3.9 | MQTT probe, load tests, proof script |
| **Git** | any | Clone repo |

Optional:

| Tool | Purpose |
|------|---------|
| **Git Bash** (Windows) | Run `.sh` wrappers and multi-line `aws` commands |
| **SSH client** | Troubleshoot EC2 (`ssh -i key.pem ubuntu@<core-ip>`) |

**AWS permissions:** IAM user/role with EC2, VPC, ELB, Auto Scaling, CloudWatch, SSM, and IAM (for instance profiles).  
**Python:** All platforms use a project `.venv/` (auto-created on first run; gitignored). Same dependencies everywhere.

### Cross-platform script reference

Every workflow has **two equivalent entry points** — use whichever fits your shell:

| Task | PowerShell (all OS) | Bash (macOS / Linux / Git Bash / WSL) |
|------|---------------------|----------------------------------------|
| Full deploy + load | `pwsh -File ./scripts/deploy_and_load_test.ps1` | `bash ./scripts/deploy_and_load_test.sh` |
| Watch bootstrap | `pwsh -File ./scripts/watch_bootstrap.ps1` | `bash ./scripts/watch_bootstrap.sh` |
| Verify deployment | `pwsh -File ./scripts/verify_deployment.ps1` | `bash ./scripts/verify_deployment.sh` |
| Full proof | `pwsh -File ./scripts/prove_emqx_cluster.ps1 -DashboardPassword "..."` | `bash ./scripts/prove_emqx_cluster.sh -DashboardPassword "..."` |
| Staged load test | `pwsh -File ./scripts/run_staged_load_test.ps1 -FromTerraform` | `FROM_TERRAFORM=true bash ./scripts/run_staged_load_test.sh` |
| Sustained load test | `pwsh -File ./scripts/run_sustained_load_test.ps1 -FromTerraform -Clients 100` | `FROM_TERRAFORM=true CLIENTS=100 bash ./scripts/run_sustained_load_test.sh` |
| Fix MQTT auth (SSM) | `pwsh -File ./scripts/fix_mqtt_anonymous_ssm.ps1` | `bash ./scripts/fix_mqtt_anonymous_ssm.sh` |

**Supported environments:** Windows 10/11 (PowerShell 5.1 or `pwsh`), macOS (Intel/Apple Silicon), Linux (Ubuntu/Debian/Fedora), WSL2, Git Bash.

**Shared libraries:** `scripts/lib/PlatformHelpers.ps1` (port tests, venv, browser) and `scripts/lib/common.sh` + `ensure_venv.sh` (Bash parity).

---

## Installation by platform

Clone the repo first (all platforms):

```bash
git clone <repo-url>
cd emqx
```

All commands below assume you are in the **project root** (directory containing `terraform.tfvars.example`).

---

### Windows

#### 1. Install tools

| Tool | How to install |
|------|----------------|
| Terraform | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) or `winget install Hashicorp.Terraform` |
| AWS CLI v2 | [AWS CLI install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) or `winget install Amazon.AWSCLI` |
| PowerShell Core | `winget install Microsoft.PowerShell` — use **`pwsh`**, not Windows PowerShell 5.1, for best cross-platform parity |
| Python 3 | [python.org](https://www.python.org/downloads/) — check **“Add Python to PATH”** during install |

#### 2. Configure AWS

```powershell
aws configure
# Enter: Access Key ID, Secret Access Key, region ap-south-1, output json
```

#### 3. Configure Terraform variables

```powershell
copy terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

Edit at minimum:

- `emqx_node_cookie` — random secret for EMQX cluster
- `emqx_dashboard_password` — dashboard login password

#### 4. Run scripts

```powershell
# One-shot: apply + bootstrap wait + dashboard + load test
pwsh -File .\scripts\deploy_and_load_test.ps1

# Or step by step
terraform init
terraform apply
pwsh -File .\scripts\watch_bootstrap.ps1
pwsh -File .\scripts\verify_deployment.ps1
pwsh -File .\scripts\prove_emqx_cluster.ps1 -DashboardPassword "YOUR_PASSWORD"
```

Legacy Windows PowerShell also works for most scripts; **`pwsh` is recommended**.

---

### macOS

#### 1. Install tools (Homebrew)

```bash
# Install Homebrew if needed: https://brew.sh
brew install powershell python terraform awscli git
```

Verify:

```bash
pwsh --version
python3 --version
terraform --version
aws --version
```

#### 2. Configure AWS

```bash
aws configure
# region: ap-south-1
```

#### 3. Configure Terraform variables

```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars   # or code terraform.tfvars
```

Set `emqx_node_cookie` and `emqx_dashboard_password`.

#### 4. Run scripts

```bash
pwsh -File ./scripts/deploy_and_load_test.ps1

# Or step by step
terraform init && terraform apply
pwsh -File ./scripts/watch_bootstrap.ps1
pwsh -File ./scripts/verify_deployment.ps1
pwsh -File ./scripts/prove_emqx_cluster.ps1 -DashboardPassword "YOUR_PASSWORD"
```

**Python:** First script run creates `.venv/` and installs `loadtest/requirements.txt` automatically.  
**Port checks:** Uses cross-platform `Test-TcpPortOpen` (not Windows-only `Test-NetConnection`).

Alternative — Bash wrappers (no PowerShell required for load tests):

```bash
FROM_TERRAFORM=true ./scripts/run_staged_load_test.sh
FROM_TERRAFORM=true CLIENTS=100 ./scripts/run_sustained_load_test.sh
```

---

### Linux

#### 1. Install tools

**Ubuntu / Debian:**

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git curl unzip

# Terraform
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install

# PowerShell Core
# See: https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu
```

**Fedora / RHEL:** use `dnf install` equivalents or vendor install guides for Terraform, AWS CLI, and `pwsh`.

#### 2. Configure AWS and Terraform

```bash
aws configure
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

#### 3. Run scripts

Same as macOS:

```bash
pwsh -File ./scripts/deploy_and_load_test.ps1
```

Or Bash-only for load tests:

```bash
chmod +x scripts/*.sh scripts/lib/ensure_venv.sh
FROM_TERRAFORM=true ./scripts/run_sustained_load_test.sh
```

---

### Git Bash / WSL (Windows)

Use **Git Bash** or **WSL** for long `aws` CLI one-liners (line continuation with `\`).

**Deploy script** — prefers `pwsh`, falls back to `powershell.exe`:

```bash
./scripts/deploy_and_load_test.sh
./scripts/deploy_and_load_test.sh -SkipApply
```

**Load tests:**

```bash
FROM_TERRAFORM=true ./scripts/run_staged_load_test.sh
FROM_TERRAFORM=true CLIENTS=200 ./scripts/run_sustained_load_test.sh
```

**Proof script (Python directly):**

```bash
export EMQX_CORE_IP=$(terraform output -raw emqx_core_public_ip)
export MQTT_HOST=$(terraform output -raw mqtt_nlb_dns_name)
export ASG_NAME=$(terraform output -raw replicant_asg_name)
export EMQX_DASHBOARD_PASSWORD='YOUR_PASSWORD'
export AWS_REGION=ap-south-1

PYTHON=$(./scripts/lib/ensure_venv.sh "$(pwd)")
"$PYTHON" -m pip install -q -r loadtest/requirements.txt
"$PYTHON" scripts/prove_emqx_cluster.py \
  --core-ip "$EMQX_CORE_IP" \
  --mqtt-host "$MQTT_HOST" \
  --asg-name "$ASG_NAME" \
  --dashboard-password "$EMQX_DASHBOARD_PASSWORD"
```

**Note:** Do not run `.ps1` files directly in Git Bash. Use `pwsh -File ./scripts/...` or the `.sh` wrappers.

---

## AWS account setup

1. Create an IAM user or use SSO with programmatic access.
2. Attach policies (or equivalent custom policy) for: EC2, VPC, ELB, Auto Scaling, CloudWatch, SSM, IAM (pass role).
3. Configure credentials:

   ```bash
   aws configure
   ```

4. Verify:

   ```bash
   aws sts get-caller-identity
   aws ec2 describe-regions --region ap-south-1 --query "Regions[0].RegionName"
   ```

5. Ensure your local IP is allowed in `dashboard_allowed_cidr` and `ssh_allowed_cidr` in `terraform.tfvars` (default `0.0.0.0/0` is open — tighten for production).

---

## Project configuration

Copy the example file and edit secrets **before** first `terraform apply`:

```bash
cp terraform.tfvars.example terraform.tfvars   # macOS / Linux
copy terraform.tfvars.example terraform.tfvars # Windows
```

| Variable | Required | Description |
|----------|----------|-------------|
| `emqx_node_cookie` | **Yes** | EMQX cluster cookie (keep secret) |
| `emqx_dashboard_password` | **Yes** | Dashboard password for user `admin` |
| `aws_region` | No | Default `ap-south-1` |
| `project_name` | No | Resource prefix; default `emqx-prod` |
| `dashboard_allowed_cidr` | No | CIDR allowed to reach dashboard `:18083` |
| `ssh_allowed_cidr` | No | CIDR allowed for SSH `:22` |
| `replicant_min_size` / `max_size` | No | ASG bounds (default 1–4) |

**Never commit `terraform.tfvars`** — it is gitignored.

---

## Deploy

### Option A — Automated (recommended for demo)

```bash
pwsh -File ./scripts/deploy_and_load_test.ps1
```

This runs: `terraform init` → `terraform apply` → bootstrap watcher → opens dashboard → starts staged load test in a new terminal.

Skip Terraform if infrastructure already exists:

```bash
pwsh -File ./scripts/deploy_and_load_test.ps1 -SkipApply
```

### Option B — Manual

```bash
terraform init
terraform apply
```

After apply, EMQX installs on EC2 (**5–15 minutes**). Watch progress:

```bash
pwsh -File ./scripts/watch_bootstrap.ps1
```

Useful outputs:

```bash
terraform output
terraform output -raw mqtt_nlb_dns_name
terraform output -raw emqx_core_public_ip
terraform output -raw emqx_dashboard_url
terraform output -raw replicant_asg_name
```

---

## Verify and prove

| Step | Command | What it checks |
|------|---------|----------------|
| Quick verify | `pwsh -File ./scripts/verify_deployment.ps1` | Dashboard + MQTT ports, NLB target health, MQTT probe |
| MQTT probe only | `pwsh -File ./scripts/verify_deployment.ps1` (includes probe) or run via staged load preflight | Single publish via NLB |
| Full proof | `pwsh -File ./scripts/prove_emqx_cluster.ps1 -DashboardPassword "YOUR_PASSWORD"` | Cluster API, NLB, load spread, ASG |

Password can also be set via environment:

```powershell
$env:EMQX_DASHBOARD_PASSWORD = "YOUR_PASSWORD"
pwsh -File ./scripts/prove_emqx_cluster.ps1
```

With 2+ replicants, use more load clients:

```bash
pwsh -File ./scripts/prove_emqx_cluster.ps1 -DashboardPassword "YOUR_PASSWORD" -LoadClients 50
```

Expected final line: `=== SUMMARY: ALL CHECKS PASSED ===`

---

## Load testing and autoscaling demo

| Script | Purpose |
|--------|---------|
| `run_staged_load_test.ps1 -FromTerraform` | Fixed stages: scale out then scale in |
| `run_sustained_load_test.ps1 -FromTerraform -Clients 100` | Runs until **Ctrl+C**; drives ASG during demo |

```bash
pwsh -File ./scripts/run_staged_load_test.ps1 -FromTerraform
pwsh -File ./scripts/run_sustained_load_test.ps1 -FromTerraform -Clients 100
```

Softer load (fewer disconnects):

```powershell
$env:PUBLISH_INTERVAL = "0.02"
$env:PAYLOAD_SIZE = "4096"
$env:MESSAGES_PER_BURST = "3"
pwsh -File ./scripts/run_sustained_load_test.ps1 -FromTerraform -Clients 100
```

**Load distribution notes:**

- Clients connect to **NLB DNS only** (not core IP, not dashboard).
- NLB sticks TCP sessions — equal connections on every node is not expected.
- After scale-out to 2+ nodes, stop load, wait for healthy NLB targets, then restart load or re-run proof.

Check autoscaling during load:

```bash
aws autoscaling describe-auto-scaling-groups \
  --region ap-south-1 \
  --auto-scaling-group-names emqx-prod-replicants-asg \
  --query "AutoScalingGroups[0].DesiredCapacity" --output text
```

Expected: `1` idle, `2+` under load.

---

## Access URLs

| Service | URL / endpoint |
|---------|----------------|
| **Dashboard** | `http://<CORE_PUBLIC_IP>:18083` — user `admin`, password from `terraform.tfvars` |
| **MQTT clients** | `tcp://<NLB_DNS>:1883` — from `terraform output -raw mqtt_nlb_dns_name` |

Core IP: `terraform output -raw emqx_core_public_ip`

---

## Tear down

When the demo is finished, destroy all AWS resources to stop charges:

```bash
terraform destroy
```

Confirm when prompted. Wait until destroy completes before closing the session.

---

## Recommended demo order

1. `terraform apply`
2. `pwsh -File ./scripts/watch_bootstrap.ps1`
3. `pwsh -File ./scripts/verify_deployment.ps1`
4. Open dashboard → **Nodes** tab
5. `pwsh -File ./scripts/run_sustained_load_test.ps1 -FromTerraform -Clients 100`
6. Watch ASG **DesiredCapacity** → 2; dashboard shows connections on 2+ replicants
7. `pwsh -File ./scripts/prove_emqx_cluster.ps1 -DashboardPassword "..."`
8. Screenshot: Nodes table + ASG Activity + proof **PASS**
9. **Ctrl+C** to stop load; wait for scale-in to 1
10. `terraform destroy`

Full command reference: [`docs/COMMANDS-REFERENCE.txt`](docs/COMMANDS-REFERENCE.txt)

---

## Troubleshooting

| Problem | What to do |
|---------|------------|
| MQTT probe fails right after apply | Wait for bootstrap (`watch_bootstrap.ps1`); check NLB target health |
| NLB targets `initial` / `unhealthy` | Bootstrap takes 5–15 min; `sudo tail -50 /var/log/emqx-bootstrap.log` on core via SSH |
| Anonymous MQTT auth on old instances | `pwsh -File ./scripts/fix_mqtt_anonymous_ssm.ps1` |
| Changed userdata / bootstrap script | Instance refresh: see [`docs/COMMANDS-REFERENCE.txt`](docs/COMMANDS-REFERENCE.txt) §12 |
| Verify performance tuning on a node | `grep PERF /var/log/emqx-bootstrap.log` and `sysctl fs.file-max net.core.somaxconn` |
| Scale stayed at 1 during load | Check CloudWatch alarms; increase client count or run sustained test longer |
| Stopped nodes in dashboard | SSH to core: `sudo emqx ctl cluster status`; force-leave dead nodes |
| `python` not found (macOS) | Use `python3` or run any `.ps1` script first (creates `.venv`) |
| `.ps1` fails in Git Bash | Use `pwsh -File ./scripts/...` not `./script.ps1` |

**SSH to core:**

```bash
ssh -i /path/to/your-key.pem ubuntu@$(terraform output -raw emqx_core_public_ip)
sudo tail -50 /var/log/emqx-bootstrap.log
sudo systemctl status emqx
sudo emqx ctl cluster status
```

**Refresh replicants after code changes:**

```bash
aws autoscaling start-instance-refresh \
  --region ap-south-1 \
  --auto-scaling-group-name emqx-prod-replicants-asg \
  --preferences MinHealthyPercentage=50,InstanceWarmup=600
```

---

## Project layout

| Path | Purpose |
|------|---------|
| `*.tf` (root) | Primary stack: VPC, core, NLB, ASG, autoscaling |
| `terraform.tfvars.example` | Template for secrets and sizing |
| `userdata/emqx-bootstrap.sh` | Core + replicant install, join, validation |
| `userdata/emqx-performance-tune.sh` | OS + EMQX performance tuning (sysctl, limits, listener caps) |
| `scripts/*.ps1` | Deploy, verify, prove, load test (PowerShell Core) |
| `scripts/*.sh` | Bash wrappers — same behavior on macOS, Linux, Git Bash, WSL |
| `scripts/lib/PlatformHelpers.ps1` | Cross-platform port tests, Python `.venv`, browser, terminals |
| `scripts/lib/common.sh` | Shared Bash helpers (`emqx_run_pwsh`, terraform output) |
| `scripts/lib/ensure_venv.sh` | Creates/returns `.venv` Python on any OS |
| `loadtest/staged_load.py` | Staged / sustained MQTT load via NLB |
| `loadtest/requirements.txt` | `paho-mqtt`, `requests` |
| `terraform/` | Optional modular stack (3 cores, private subnets) |
| `docs/COMMANDS-REFERENCE.txt` | Full command cheat sheet |
| `docs/architecture.md` | Architecture diagram (Mermaid) |
| `loadtest/mqtt_common.py` | Shared MQTT helpers (`connack_ok`) |

---

## Security and cost

**Security**

- MQTT on replicants accepts traffic **only from the NLB security group**
- Dashboard restricted by `dashboard_allowed_cidr`
- Do not commit `terraform.tfvars`, `.pem` keys, or AWS credentials
- Replace default cookie and dashboard password before any shared demo

**Cost**

- Brief demo in `ap-south-1`: 1 core + 1–4 `t3.small` replicants + NLB + data transfer
- Always run `terraform destroy` when finished

---

## Further reading

- [`docs/COMMANDS-REFERENCE.txt`](docs/COMMANDS-REFERENCE.txt) — every command, AWS CLI checks, common mistakes
- [`docs/architecture.md`](docs/architecture.md) — detailed architecture
- [`terraform/`](terraform/) — alternate modular Terraform layout

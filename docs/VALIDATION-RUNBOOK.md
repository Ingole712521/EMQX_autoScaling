# Validation runbook — resilience + message durability

After `terraform apply`, run these from the **project root** (`job/`).

## Prerequisites

```powershell
$env:EMQX_DASHBOARD_PASSWORD = "your-password-from-tfvars"
.\scripts\prove_emqx_cluster.ps1   # baseline cluster OK
```

## 1. Cluster resilience

```powershell
# Dry run — shows which instance would be terminated
.\scripts\run_resilience_test.ps1 -DryRun

# Replicant termination during MQTT load
.\scripts\run_resilience_test.ps1 -Scenario replicant-terminate -LoadClients 100

# Core reboot during MQTT load
.\scripts\run_resilience_test.ps1 -Scenario core-reboot -LoadClients 100
```

**Pass:** Client count recovers to ≥80% within 30s after replicant failure; cluster status shows running nodes.

## 2. Message durability

Terminal 1 (subscriber — start first):

```powershell
python loadtest/durability_test.py --host (terraform output -raw mqtt_nlb_dns_name) --mode sub --qos 1
```

Terminal 2 (publisher — trigger scale-out or terminate replicant mid-run):

```powershell
.\scripts\run_durability_test.ps1 -FromTerraform -Count 100000 -Rate 2000
# Full: -Count 1000000 -Rate 5000
```

**Pass:**

```json
{"sent": 100000, "received_unique": 100000, "lost": 0, "duplicates": 0}
```

## 3. Terraform resources involved

| Resource | Purpose |
|----------|---------|
| `aws_autoscaling_lifecycle_hook.replicant_terminate` | Pause termination for EMQX drain |
| `emqx-lifecycle-drain.service` on replicants | Stops EMQX and completes hook |
| `aws_instance.load_generator` | Optional EC2 for in-VPC tests |
| `EMQX_MQTT__MAX_MQUEUE_LEN` etc. | Session queue for durable subscribers |

## 4. Evidence for submission

- Screenshot: ASG activity during replicant termination
- Output: `run_resilience_test.ps1` PASS summary
- Output: `durability_test.py` FINAL RESULT with lost=0
- Log: `/var/log/emqx-lifecycle-drain.log` on terminated replicant (if accessible before instance ends)

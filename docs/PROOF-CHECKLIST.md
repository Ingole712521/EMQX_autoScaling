# EMQX proof checklist

Run from **project root** after `terraform apply` (root stack, `project_name = emqx-prod`).

## 1. Deploy and wait for bootstrap

```powershell
.\scripts\deploy_and_load_test.ps1
# or: terraform apply && .\scripts\watch_bootstrap.ps1
```

Bootstrap log: `/var/log/emqx-bootstrap.log` — marker `/var/log/emqx-bootstrap.ok` when done.

## 2. Verify

```powershell
.\scripts\verify_deployment.ps1
.\scripts\prove_emqx_cluster.ps1
```

| Check | PASS means |
|-------|------------|
| NLB target health | At least one replicant **healthy** on :1883 |
| MQTT via NLB | Connect + publish OK |
| Cluster API | ≥ 2 nodes (core + replicant) |
| Load spread | With ASG≥2: connections on 2+ replicants after load |

If MQTT fails on existing instances:

```powershell
.\scripts\fix_mqtt_anonymous_ssm.ps1
aws autoscaling start-instance-refresh --auto-scaling-group-name emqx-prod-replicants-asg --region ap-south-1
```

## 3. Autoscaling load test

```powershell
.\scripts\run_staged_load_test.ps1 -FromTerraform
```

Watch **EC2 → Auto Scaling Groups → emqx-prod-replicants-asg** — desired capacity should rise during heavy stages and fall after `scale-in`.

## 4. Cluster resilience validation

```powershell
.\scripts\run_resilience_test.ps1 -DryRun
.\scripts\run_resilience_test.ps1 -Scenario replicant-terminate
.\scripts\run_resilience_test.ps1 -Scenario core-reboot
```

See `docs/VALIDATION-RUNBOOK.md` for full steps.

## 5. Message durability validation

```powershell
# Terminal 1: subscriber
python loadtest/durability_test.py --host (terraform output -raw mqtt_nlb_dns_name) --mode sub

# Terminal 2: publisher (run during scale-out, scale-in, or replicant termination)
.\scripts\run_durability_test.ps1 -FromTerraform -Count 100000 -Rate 2000
```

**PASS:** `lost = 0`, `received_unique >= sent`.

## 6. PASS criteria for submission

- [ ] Core dashboard shows cluster with core + all replicants  
- [ ] NLB targets all **healthy** under load  
- [ ] `prove_emqx_cluster.ps1` exits 0  
- [ ] ASG scaled **out** during staged test (desired 2+)  
- [ ] ASG scaled **in** after light stage (back toward 1)  
- [ ] `run_resilience_test.ps1` — replicant termination PASS  
- [ ] `run_durability_test.ps1` — 100K+ messages, lost=0  

## Load on each node

- **Core** does not receive NLB MQTT traffic.  
- **Replicants** receive client connections from NLB (TCP flow hash).  
- Perfect balance is not required; with 50+ clients and 2+ nodes, proof expects traffic on multiple replicants.

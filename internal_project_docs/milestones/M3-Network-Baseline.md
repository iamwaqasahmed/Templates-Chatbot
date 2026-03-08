# M3 — Network Baseline (VPC, Subnets, Routing, Endpoints, Security Patterns) — Technical Design v1

M3 builds the secure, multi-AZ network foundation that every later milestone depends on (ALB/ECS, Redis, DynamoDB access patterns, VPC endpoints, logging, etc.). The goal is a network that is safe by default, scales cleanly, and is cost-aware across dev/staging/prod.

---

## 1. Objectives & Outcomes

### Objectives

- Create a **multi-AZ VPC** with clearly separated subnet tiers.
- Ensure **compute (ECS tasks) and data stores are not publicly reachable**.
- **Minimize NAT usage** by using VPC Endpoints for AWS services.
- Establish **baseline network observability** (VPC Flow Logs).
- Provide **reusable Terraform module(s)** consistent with M2.

### Outcomes (end of M3)

- **network** stack exists in each env (dev/staging/prod) using remote state.
- **VPC** with:
  - Public subnets (ALB/NAT)
  - Private app subnets (ECS tasks)
  - Private data subnets (Redis/Aurora later)
- **Route tables** + IGW + NAT (HA pattern, env-configurable).
- **Gateway endpoints** (S3, DynamoDB) + **interface endpoints** (ECR, Logs, Secrets, SSM, STS, KMS, etc.).
- **Flow logs** enabled (CloudWatch Logs or S3).
- **Baseline security group patterns** ready for M5/M9/M8.

---

## 2. Network Topology (Reference Architecture)

### Subnet tiers (per AZ)

| Tier | Purpose |
|------|---------|
| **Public subnets** | Internet-facing ALB, NAT Gateways |
| **Private-app subnets** | ECS/Fargate tasks (no public IPs) |
| **Private-data subnets** | ElastiCache Redis + Aurora (later); no direct internet route |

### ASCII layout

```
             Internet
                |
              [IGW]
                |
      +---------------------+
      | Public Subnets (AZa,b,c)
      |  - ALB (public)
      |  - NAT GW (per AZ optional)
      +---------------------+
          |          |
          |          v
          |     NAT Gateway
          v
+---------------------------+
| Private-App Subnets (AZa,b,c)
|  - ECS/Fargate tasks
|  - No public IP
|  - Egress via NAT OR VPC endpoints
+---------------------------+
               |
               v
+---------------------------+
| Private-Data Subnets (AZa,b,c)
|  - Redis (later)
|  - Aurora (later)
|  - No internet route
+---------------------------+
```

**VPC Endpoints (Interface)** live in private subnets. **Gateway endpoints** attach to route tables (private).

---

## 3. CIDR & IP Planning (don’t regret later)

### Recommended default

- **VPC CIDR:** /16 (e.g. `10.60.0.0/16`)
- Allocate per AZ:
  - **Public:** /24 each
  - **Private-app:** /20 each (more headroom for scale)
  - **Private-data:** /24 or /23 each (depends on expected DB/cache growth)

### Example for 3 AZs

| Tier | AZ 1 | AZ 2 | AZ 3 |
|------|------|------|------|
| **Public** | 10.60.0.0/24 | 10.60.1.0/24 | 10.60.2.0/24 |
| **Private-app** | 10.60.16.0/20 | 10.60.32.0/20 | 10.60.48.0/20 |
| **Private-data** | 10.60.80.0/24 | 10.60.81.0/24 | 10.60.82.0/24 |

**Rule:** Oversize private-app. Fargate scale + endpoints + future services consume IPs.

---

## 4. Routing Strategy

| Route table | Default route | Notes |
|-------------|----------------|--------|
| **Public** | 0.0.0.0/0 → IGW | Associated with public subnets only |
| **Private-app** (per AZ) | Prefer VPC endpoints for AWS traffic (no NAT). 0.0.0.0/0 → NAT GW (same AZ) for non-AWS internet egress (OpenAI, etc.) | In dev: 1 NAT for cost; in prod: NAT per AZ |
| **Private-data** | No default internet route | Only internal VPC routing + VPC endpoints (if needed). Keep Redis/Aurora isolated from outbound internet |

---

## 5. NAT Strategy (Cost vs Resilience)

Support both patterns via Terraform variables:

| Pattern | Use case | Behavior |
|---------|----------|----------|
| **A — Prod** | `nat_mode = "per_az"` (recommended) | 1 NAT GW per AZ → higher availability, avoids cross-AZ data charges. Used for external API calls (OpenAI), OS/package fetch (rare in containers) |
| **B — Dev** | `nat_mode = "single"` (cost optimized) | Single NAT in one AZ; private subnets in other AZs route to it. Lower cost, lower resilience (acceptable for dev only) |
| **C** | `nat_mode = "none"` | Works if you only use AWS services via VPC endpoints and avoid external calls |

**M3 provides toggle:** `nat_mode = "per_az"` | `"single"` | `"none"`

---

## 6. VPC Endpoints (critical for security + cost)

### Gateway endpoints (no hourly cost)

- **S3** (gateway endpoint)
- **DynamoDB** (gateway endpoint)

Attach to route tables for **private-app** (and optionally private-data if needed).

### Interface endpoints (hourly cost, reduce NAT & exposure)

**Recommended baseline list for private-app:**

- `com.amazonaws.<region>.ecr.api`
- `com.amazonaws.<region>.ecr.dkr`
- `com.amazonaws.<region>.logs` (CloudWatch Logs)
- `com.amazonaws.<region>.secretsmanager`
- `com.amazonaws.<region>.ssm`
- `com.amazonaws.<region>.ssmmessages`
- `com.amazonaws.<region>.ec2messages`
- `com.amazonaws.<region>.sts`
- `com.amazonaws.<region>.kms` (if you use KMS calls from workloads)

### Security group for interface endpoints

- **Inbound:** 443 from `sg_app_tasks` (and possibly `sg_ci_bastion` if added later)
- **No inbound from the world**

### DNS

- Set **`private_dns_enabled = true`** for interface endpoints so AWS SDKs hit private IPs automatically.

---

## 7. Baseline Security Controls (Network Layer)

### 7.1 Subnet and public exposure rules

- ECS tasks run in **private-app** subnets, `assign_public_ip = false`.
- Redis/Aurora run in **private-data** subnets, no public accessibility.

### 7.2 Security group model (baseline templates)

Create SGs in M3 even if attached later:

| SG | Inbound | Outbound |
|----|---------|----------|
| **sg_alb_public** | 443 from 0.0.0.0/0 (temporary; M5 can restrict to CloudFront/WAF) | 443/HTTP to sg_app_tasks (or all egress; tighten later) |
| **sg_app_tasks** | From sg_alb_public on app port (e.g. 8000) | 443 to VPC endpoints; 0.0.0.0/0 via NAT only if needed |
| **sg_redis** (later: ElastiCache) | 6379 from sg_app_tasks only | default (or restrict) |
| **sg_db** (later: Aurora) | 5432 from sg_app_tasks only | default (or restrict) |
| **sg_vpce** | 443 from sg_app_tasks | default |

### 7.3 NACLs

For M3, use **default NACLs** (stateless NACLs are easy to misconfigure). Security groups provide the main enforcement. Add custom NACLs later if needed for “enterprise hardening” once traffic patterns are stable.

---

## 8. Network Observability (Flow Logs)

### Requirements

- Enable **VPC flow logs** for: VPC (preferred) or at least private subnets.
- **Deliver to:** CloudWatch Logs (easy to query + alarms) or S3 (cheaper for long retention).

### Recommended baseline

- **CloudWatch Logs** in dev/staging (fast troubleshooting).
- **S3** in prod (cost + retention); optionally also CW for hot window.
- **Log retention:** 14–30 days in CloudWatch; longer in S3 via lifecycle rules.

---

## 9. Terraform Implementation (Module Design)

### 9.1 Module: `modules/network`

**Resources included**

- `aws_vpc`
- `aws_internet_gateway`
- `aws_subnet` (public / private-app / private-data in N AZs)
- `aws_route_table` + `aws_route_table_association`
- `aws_eip` + `aws_nat_gateway` (per config)
- `aws_vpc_endpoint` (gateway + interface)
- `aws_cloudwatch_log_group` + `aws_iam_role` for flow logs (if CW)
- `aws_flow_log`

### 9.2 Inputs (variables)

```hcl
variable "project" { type = string }
variable "env"     { type = string }
variable "region"  { type = string }

variable "vpc_cidr"   { type = string }   # e.g., 10.60.0.0/16
variable "az_count"   { type = number }  # 2 or 3 (recommend 3)
variable "enable_ipv6" { type = bool, default = false }

variable "subnet_cidrs" {
  type = object({
    public       = list(string)
    private_app  = list(string)
    private_data = list(string)
  })
}

variable "nat_mode" {
  type    = string
  default = "per_az" # "single" | "per_az" | "none"
}

variable "enable_flow_logs" { type = bool, default = true }
variable "flow_logs_destination" {
  type    = string
  default = "cloudwatch" # "cloudwatch" | "s3"
}

variable "enable_endpoints" { type = bool, default = true }
variable "interface_endpoints" {
  type    = list(string)
  default = ["ecr.api", "ecr.dkr", "logs", "secretsmanager", "ssm", "ssmmessages", "ec2messages", "sts", "kms"]
}
```

### 9.3 Outputs

```hcl
output "vpc_id" {}
output "public_subnet_ids" {}
output "private_app_subnet_ids" {}
output "private_data_subnet_ids" {}

output "public_route_table_id" {}
output "private_app_route_table_ids" {}
output "private_data_route_table_ids" {}

output "nat_gateway_ids" {}
output "vpc_endpoint_ids" {}
```

---

## 10. Live Stack Layout (consistent with M2)

Create:

- `infra/terraform/live/dev/network/`
- `infra/terraform/live/staging/network/`
- `infra/terraform/live/prod/network/`

Each includes:

- `versions.tf` (backend s3)
- `providers.tf` (default_tags)
- `main.tf` (calling `module "network"`)
- `variables.tf`, `outputs.tf`
- `terraform.tfvars` (CIDRs, az_count, nat_mode)

**Backend key example:** `chatbot/dev/network/terraform.tfstate`

---

## 11. Operational Runbooks (M3)

### Runbook: Choosing NAT mode per environment

| Env | Recommendation |
|-----|----------------|
| **Dev** | `nat_mode = "single"` (or `"none"` if only AWS endpoints) |
| **Staging** | `nat_mode = "per_az"` (recommended) |
| **Prod** | `nat_mode = "per_az"` (recommended) |

### Runbook: Adding a new endpoint

1. Add service name to `interface_endpoints`.
2. Apply network stack.
3. Confirm DNS resolves to private IP in private-app subnet.

### Runbook: CIDR expansion (avoid if possible)

- If you might outgrow /16, plan a **second VPC** later and connect (TGW/peering). Expanding in-place is painful. Better to start with /16.

---

## 12. Security “Definition of Done” for M3

M3 is complete when:

- [ ] VPC spans 3 AZs (or 2 if region constraints), with public / private-app / private-data subnets
- [ ] ECS tasks can run without public IPs (validated via later milestone smoke test)
- [ ] Gateway endpoints for S3 + DynamoDB exist and are used by private route tables
- [ ] Interface endpoints exist with private DNS enabled
- [ ] NAT exists per env policy; prod uses per-AZ NAT
- [ ] Flow logs enabled with retention configured
- [ ] No data subnet has default internet route

---

## 13. Notes for Later Milestones

| Milestone | Relevance |
|-----------|-----------|
| **M5 (Edge)** | Optionally lock ALB inbound to CloudFront + WAF strategy |
| **M8 (Redis)** | Place ElastiCache in private-data subnets and attach sg_redis |
| **M9 (ECS/Fargate)** | Deploy tasks into private-app subnets and ALB in public subnets |
| **M10 (Observability)** | Add dashboards/alarms using flow logs + ALB metrics |

# M2 — Terraform Foundation + Remote State + Environment Isolation (Technical Design v1)

M2 makes infrastructure work safe, repeatable, auditable, and scalable across environments. When M2 is done, you have:

- Remote state + locking
- Strong environment isolation
- CI deploy identity (OIDC)
- Standard module + live layout
- Baseline guardrails (tags, encryption, least privilege, drift checks)

---

## 1. Outcomes and Deliverables

### Deliverables

- **Terraform project layout:** `infra/terraform/modules` + `infra/terraform/live/{dev,staging,prod}`
- **Bootstrap stack** that creates:
  - S3 state bucket (versioned, encrypted with KMS, access logged, blocked public)
  - DynamoDB lock table (PITR enabled)
  - KMS key for state encryption (with tight key policy)
- **CI identity** using GitHub Actions OIDC:
  - IAM OIDC provider (per AWS account)
  - Role: `terraform-deployer` (scoped to repo/branch)
  - Permissions boundary / least privilege policy pattern
- **Standard tagging + naming conventions**
- **Terraform pinning:** pinned Terraform version, pinned provider versions, committed `terraform.lock.hcl`
- **Plan/apply workflow:** PR = plan + artifact; main = plan; prod apply = manual approval gate
- **Drift detection skeleton** (scheduled plan job)

### Exit criteria (Definition of Done)

- [ ] `terraform init` / `terraform plan` works in dev/staging/prod using remote state
- [ ] Locking works (parallel plan/apply won't corrupt state)
- [ ] CI can assume role via OIDC (no long-lived AWS keys)
- [ ] State is encrypted, versioned, access logged, and non-public
- [ ] Consistent tagging enforced across stacks

---

## 2. Environment Isolation Model (recommended)

**Best practice (recommended): separate AWS accounts per env**

- `chatbot-dev` AWS account
- `chatbot-staging` AWS account
- `chatbot-prod` AWS account

**Benefits:** Blast-radius isolation, cleaner IAM, safer experimentation.

**Acceptable fallback (if 1 account only)**

- Separate VPCs and IAM boundaries per env
- Separate state prefixes per env
- Strong tagging + SCP-like guardrails are harder, but still workable

In either case: use **separate Terraform “live” directories per env** and **separate remote state keys**.

---

## 3. Terraform Layout and Stack Strategy

### Directory structure

```
infra/terraform/
  bootstrap/                 # executed once per account to create state backend
    main.tf
    variables.tf
    outputs.tf

  modules/
    state-backend/           # optional: if you want to module-ize bootstrap resources
    iam-oidc-github/
    tagging/

  live/
    dev/
      foundation/            # starts in M2 (backend already exists), more later
        main.tf
        versions.tf
        providers.tf
        variables.tf
        outputs.tf
        terraform.tfvars
    staging/
      foundation/
        ...
    prod/
      foundation/
        ...
```

### Stack model

Use **multiple stacks** instead of one mega-root:

| Stack | Milestone | Contents |
|-------|-----------|----------|
| **foundation** | M2 | IAM roles, OIDC, maybe baseline KMS keys/log buckets |
| **network** | M3 | VPC/subnets/endpoints |
| **edge** | M5 | CloudFront/WAF/ACM/Route53 |
| **compute** | M9 | ECS/ALB/ECR |
| **data** | M7/M8 | DynamoDB/Redis/S3 |
| **observability** | M10 | Alarms/dashboards |

This keeps state smaller, reduces blast radius, and makes applies safer.

---

## 4. Remote State Design (S3 + DynamoDB)

### State bucket requirements

- SSE-KMS encryption
- Versioning enabled
- Block public access
- Bucket policy to enforce TLS and encryption
- Server access logging to a separate log bucket
- (Optional) Object Lock for compliance (often not needed early)

### Lock table requirements

- DynamoDB table for state locking
- PITR enabled
- Tags applied

### State key convention

Examples:

- `chatbot/dev/foundation/terraform.tfstate`
- `chatbot/dev/network/terraform.tfstate`
- `chatbot/prod/compute/terraform.tfstate`

---

## 5. Bootstrap Stack (run once per account)

**Why:** You can't use a remote backend until the bucket/table exist. Bootstrap is a small Terraform stack that runs with **local state once**, then you switch the rest to remote state.

### `infra/terraform/bootstrap/variables.tf`

```hcl
variable "project" { type = string }
variable "env"     { type = string }
variable "region"  { type = string }

variable "state_bucket_name" { type = string }
variable "lock_table_name"   { type = string }

variable "log_bucket_name"   { type = string }
```

### `infra/terraform/bootstrap/main.tf` (core resources)

```hcl
terraform {
  required_version = "~> 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "Terraform"
    }
  }
}

resource "aws_kms_key" "tf_state" {
  description             = "${var.project}-${var.env} terraform state key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_s3_bucket" "logs" {
  bucket = var.log_bucket_name
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tf_state.arn
    }
  }
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/state/"
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute { name = "LockID" type = "S" }

  point_in_time_recovery { enabled = true }
}
```

### Bootstrap runbook

1. `cd infra/terraform/bootstrap`
2. `terraform init`
3. `terraform apply -auto-approve` (dev first, then staging/prod accounts)
4. Record outputs: state bucket name, lock table name, KMS key ARN

---

## 6. Remote Backend Configuration for Live Stacks

Use backend config in a `backend.hcl` file (recommended) to avoid hardcoding.

### Example: `infra/terraform/live/dev/foundation/backend.hcl`

```hcl
bucket         = "chatbot-dev-tfstate-123456"
key            = "chatbot/dev/foundation/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "chatbot-dev-tflock"
encrypt        = true
kms_key_id     = "arn:aws:kms:us-east-1:123456789012:key/..."
```

### `versions.tf`

```hcl
terraform {
  required_version = "~> 1.6"
  backend "s3" {}
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
```

### Init command

```bash
terraform init -backend-config=backend.hcl
```

---

## 7. IAM for CI/CD (GitHub OIDC) — No Long-Lived AWS Keys

### Goals

- GitHub Actions can run `terraform plan` / `terraform apply` by assuming a role.
- Role assumption constrained to: your GitHub org/repo, specific branches (e.g. main only for apply), specific environments.

### Resources to create (in foundation stack)

- IAM OIDC provider for GitHub
- IAM role: `terraform-deployer`
- Policy: least privilege for the stacks it manages
- Optional: permissions boundary

### Trust policy (tight conditions)

- Allow only your repo
- Allow only certain refs (branch/tag)

**Example trust policy snippet:**

```hcl
data "aws_iam_policy_document" "github_trust" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main",
        "repo:YOUR_ORG/YOUR_REPO:pull_request"
      ]
    }
  }
}
```

### Permission model (best practice)

- Start with broader permissions during early milestones, but still scoped: restrict by region, restrict by resource tags (where possible).
- Gradually tighten as modules solidify.
- **Important:** Terraform needs read permissions broadly (Describe/List) even when writes are limited.

---

## 8. Terraform Coding Standards (enforced in M2)

### Provider pinning & lockfile

- `required_providers` pinned
- `terraform.lock.hcl` committed
- CI fails if `terraform fmt` or `terraform validate` fails

### Default tags

Use `default_tags` on the AWS provider in every stack:

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.env
      ManagedBy   = "Terraform"
      CostCenter  = "chatbot"
      DataClass   = "PII-Possible"
    }
  }
}
```

### Naming convention (consistent, searchable)

Example: `${project}-${env}-${region}-${component}`

- `chatbot-prod-us-east-1-alb`
- `chatbot-dev-us-east-1-redis`

### Variables and tfvars

- Each env stack has `terraform.tfvars` with: project, env, region, account IDs where needed.
- **No secrets in tfvars (ever).**

---

## 9. CI Workflows (Plan/Apply Discipline)

| Workflow | Behavior |
|----------|----------|
| **PR** | `terraform fmt -check`, `terraform validate`, `terraform plan` (for dev stacks at minimum); upload plan output as artifact / PR comment (optional) |
| **Main branch** | Plan for staging/prod (no apply) |
| **Drift detection** (scheduled daily) | `terraform plan -detailed-exitcode`; non-zero → alert (Slack/email later milestone) |
| **Apply** (gated) | Dev: auto-apply allowed; Staging: manual approval; Prod: manual approval + protected environment in GitHub |

---

## 10. Security Guardrails for Terraform State

### Mandatory controls

**State bucket**

- Block public access
- Deny non-TLS (`aws:SecureTransport=false`)
- Encryption enforced (SSE-KMS)
- Versioning enabled
- Access logs enabled

**IAM**

- Only CI role + break-glass admin can access state

**Break-glass**

- Separate admin role for emergencies, monitored usage

---

## 11. Operational Runbooks (M2 level)

### Runbook: migrating local state → S3 backend

1. After bootstrap, run: `terraform init -backend-config=backend.hcl -migrate-state`
2. Verify state exists in S3 and lock table works

### Runbook: stuck state lock

1. Identify lock item in DynamoDB
2. Only break-glass role may remove it after verifying no apply is running

### Runbook: drift

1. Run plan with same vars
2. If drift is expected → apply
3. If drift is unexpected → investigate who/what changed infra

---

## 12. M2 Acceptance Checklist

- [ ] Separate dev/staging/prod directories exist with clean structure
- [ ] Remote backend works in each env (S3 + DynamoDB lock)
- [ ] State bucket is encrypted, versioned, logged, non-public
- [ ] CI can assume AWS role via GitHub OIDC
- [ ] Provider pinning + lockfile committed
- [ ] Standard tags applied automatically
- [ ] PR runs plans; prod applies are gated

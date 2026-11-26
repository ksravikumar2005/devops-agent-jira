# Step-by-Step Installation & Deployment Guide

This guide details the complete walkthrough for installing, configuring, and verifying the **AWS DevOps Agent to Jira Cloud Integration**.

---

## 1. Prerequisites Checklist

Before beginning deployment, ensure you have the following:

- [ ] **AWS CloudShell Access**: Login to your AWS Management Console and launch CloudShell in your target region (e.g. `us-east-1` or `us-west-2`).
- [ ] **IAM Permissions**: Permission to create and manage:
  - AWS CloudFormation Stacks (`cloudformation:*`)
  - AWS Lambda Functions & Function URLs (`lambda:*`)
  - Amazon DynamoDB Tables (`dynamodb:*`)
  - AWS Secrets Manager Secrets (`secretsmanager:*`)
  - Amazon EventBridge Rules (`events:*`)
  - AWS IAM Roles & Policies (`iam:*`)
- [ ] **AWS DevOps Agent Space**: An active DevOps Agent Space in your region.
- [ ] **Atlassian Jira Cloud Account**:
  - Admin access to Atlassian Jira Cloud.
  - A designated project (e.g., `OPS`, `INC`, or `ITSM`).
  - An Atlassian Cloud API Token for authentication.

---

## 2. Generating an Atlassian API Token

1. Log in to **[Atlassian Security > API Tokens](https://id.atlassian.com/manage-profile/security/api-tokens)**.
2. Click **Create API token** *(choose the standard option, not "with scopes", so it inherits basic auth permissions)*.
3. In the creation modal:
   - **Name**: Enter `aws_devops_agent`.
   - **Expires on**: Select your preferred expiration date (up to 1 year).

<p align="center">
  <img src="images/create-jira-api-token.png" alt="Create Atlassian API Token" width="550" />
</p>

4. Click **Create**.
5. Copy and store the generated token immediately; Atlassian will not display it again. You will paste this token into the CloudShell setup wizard.

---

## 3. Verifying Your Jira API Key (Pre-Flight Check)

Before running the deployment wizard, you can verify your credentials directly using `curl`:

```bash
# Verify authentication
curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
  -H "Accept: application/json" \
  "https://YOUR_ORG.atlassian.net/rest/api/3/myself"

# Verify project access
curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
  -H "Accept: application/json" \
  "https://YOUR_ORG.atlassian.net/rest/api/3/project/YOUR_PROJECT_KEY"
```

A successful response returns `HTTP/2 200` with user details (such as `displayName` and `accountId`).

---

## 3. Deploy via AWS CloudShell

### Step 3.1: Launch AWS CloudShell
1. Open the [AWS Management Console](https://console.aws.amazon.com/).
2. Click the **CloudShell icon** (`>_`) in the top navigation bar.

### Step 3.2: Clone the Project
```bash
git clone https://github.com/ksravikumar2005/devops-agent-jira.git
cd devops-agent-jira
```

### Step 3.3: Execute Setup Wizard
```bash
bash cloudshell-setup.sh
```

### Step 3.4: Follow the Interactive Prompts
1. **Target Region**: Confirm your AWS region (default: current region).
2. **Agent Space**: Choose or enter either your Agent Space Name (e.g. `DevOpsSpace-Prod`) or Space ID (e.g. `3f1e5f09-659d-4073-a7a5-2b5ca9e633bd`). The script automatically resolves names to the underlying ID.
3. **Jira Base URL**: Enter your Atlassian Cloud domain, e.g., `https://mycompany.atlassian.net` (trailing slashes are sanitized automatically).
4. **Jira User Email**: Enter your Atlassian login email.
5. **Jira API Token**: Paste your generated Atlassian API token.
6. **Jira Project Key**: Enter your target project key (e.g., `KAN`).
7. **Jira Issue Type**: Choose `Task`, `Bug`, or `Incident` (default: auto-detected from project metadata).

The script automatically executes a live pre-flight check against Jira REST API v3, provisions CloudFormation, stores credentials in Secrets Manager, enables DynamoDB state tracking, creates EventBridge rules, and outputs your secured Webhook URL.

---

## 4. Register Inbound Webhook in Jira Cloud (Secured with Shared Secret)

To enable Jira to securely notify AWS DevOps Agent when tickets are created or commented with `/investigate`, the endpoint is protected by a **cryptographic shared secret token**:

1. Retrieve your secured `JiraWebhookUrl`:
   ```bash
   WEBHOOK_URL=$(aws cloudformation describe-stacks \
     --stack-name devops-agent-jira-integration \
     --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
     --output text)

   WEBHOOK_TOKEN=$(aws secretsmanager get-secret-value \
     --secret-id "devops-agent/jira-credentials" \
     --query "SecretString" --output text | jq -r '.webhook_secret_token')

   echo "Secured Webhook URL: ${WEBHOOK_URL}?token=${WEBHOOK_TOKEN}"
   ```
2. In Atlassian Jira Cloud:
   - Click the gear icon (**Settings ⚙️**) in the top right header.
   - Navigate to **System > Webhooks** (under *Advanced* in the left sidebar).
   - Click **+ Create a Webhook** (top right).
   - Configure:
     - **Name**: `AWS DevOps Agent Integration`
     - **Status**: `Enabled`
     - **URL**: Paste your secured `JiraWebhookUrl` (including the `?token=...` parameter).
     - **Issue related events**:
       - Check **Issue**: `created`, `updated`
       - Check **Comment**: `created`
     - *(Optional JQL Filter)*: `project = "KAN"`
   - Click **Save**. Any incoming requests without this secret token are immediately blocked with **HTTP 403 Forbidden**.

---

## 5. Verification & Testing Scenarios

You can verify the integration using either of the two automated scenarios:

```text
==> [6/6] End-to-End Integration Verification
Choose an automated scenario to verify the live integration:

  1) Outbound: Trigger REAL Investigation in AWS DevOps Agent
     Creates an authentic backlog task in your DevOps Agent Space using AWS CLI.
     DevOps Agent starts analyzing, emits native 'aws.aidevops' to EventBridge,
     creates a live Jira ticket in KAN, and posts diagnostic updates & RCA.

  2) Inbound: Create Incident in Jira & Trigger AWS DevOps Agent
     Creates a new live incident ticket in Jira (KAN) via REST API.
     The webhook receiver triggers AWS DevOps Agent to start an investigation,
     acknowledges with the Task ID, and sends investigation details back to Jira.

  3) Skip Verification (Complete setup directly)

Select verification scenario [1/2/3] (default: 1):
```

---

## 6. Verification: Real Investigation vs. Synthetic Testing

### Option A: Trigger a REAL DevOps Agent Investigation (Recommended)
Trigger an actual backlog task of type `INVESTIGATION` inside your live AWS DevOps Agent Space using the official AWS CLI. AWS DevOps Agent will autonomously analyze your infrastructure and emit authentic `aws.aidevops` lifecycle events (`Investigation Created`, `Investigation In Progress`, `Investigation Completed`) to EventBridge:

```bash
bash scripts/create-real-investigation.sh
```

Or invoke directly via the official AWS CLI:
```bash
aws devops-agent create-backlog-task \
    --agent-space-id "3f1e5f09-659d-4073-a7a5-2b5ca9e633bd" \
    --task-type "INVESTIGATION" \
    --title "Investigate Latency Spike on Order Processing Microservice" \
    --description "Autonomous root cause analysis across CloudWatch, X-Ray, and ECS logs" \
    --priority "HIGH" \
    --region "us-east-1"
```

### Option B: Synthetic Test Suite
You can manually trigger synthetic tests anytime using the included test runner:

```bash
bash scripts/test-integration.sh
```

Or test Lambda directly:
```bash
bash scripts/test-integration.sh --direct
```

Or trigger using the Python CLI simulator:
```bash
python3 scripts/simulate-investigation.py --region us-east-1 --space-id 3f1e5f09-659d-4073-a7a5-2b5ca9e633bd
```

---

## 6. CloudWatch Logs Inspection

To observe live Lambda processing and API payloads:

```bash
aws logs tail "/aws/lambda/devops-agent-jira-integration-EventHandler" --follow
```

---

## 7. Teardown & Clean Up

To delete all created resources (CloudFormation stack, Secrets Manager secret, DynamoDB table):

### Via Setup Script:
```bash
# Interactive confirmation
bash cloudshell-setup.sh --cleanup

# Automated (skip confirmation prompt)
bash cloudshell-setup.sh --cleanup --force
```

### Via Cleanup Script:
```bash
bash scripts/cleanup.sh
```

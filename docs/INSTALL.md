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

## 4. Deployment using AWS CloudShell (Interactive)

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
2. **Agent Space ID**: The wizard attempts to discover your Agent Space using `aws aidevops list-agent-spaces`. If found, press `Enter` to use it, or enter your custom Space ID.
3. **Jira Base URL**: Enter your Atlassian Cloud domain, e.g., `https://mycompany.atlassian.net` (do not worry about accidental trailing slashes like `https://mycompany.atlassian.net/` — the script and Lambda automatically strip them to prevent `//` path bugs).
4. **Jira User Email**: Enter the email of the Jira administrator or service account.
5. **Jira API Token**: Paste your API token (input is masked for security).
6. **Jira Project Key**: Enter the key of the project where incident tickets should be created (e.g., `OPS`).
7. **Jira Issue Type**: Choose `Incident`, `Bug`, or `Task` (default: `Incident`).

The script automatically executes a live pre-flight check against Jira REST API v3 `/rest/api/3/myself` and `/rest/api/3/project/{KEY}` to verify connectivity before deploying any AWS resources.

---

## 4. Verification & Testing

Upon successful deployment, the script offers to run an automated synthetic test:

```text
Would you like to run an automated synthetic investigation test? [Y/n]: Y
```

When confirmed, it will:
1. Emit a synthetic `Investigation Created` event to Amazon EventBridge.
2. Wait 6 seconds and query the DynamoDB state table `devops-agent-jira-mappings`.
3. Print the created Jira Issue Key (e.g., `OPS-42`) with a direct link.
4. Emit an `Investigation Completed` event with simulated Root Cause Analysis (RCA) findings.
5. Print confirmation that the RCA findings were added as a comment.

---

## 5. Manual CLI Test

You can manually trigger tests anytime using the included test runner:

```bash
bash scripts/test-integration.sh
```

Or trigger using the Python CLI simulator:
```bash
python3 scripts/simulate-investigation.py --region us-east-1 --space-id default
```

---

## 6. CloudWatch Logs Inspection

To observe live Lambda processing and API payloads:

```bash
aws logs tail "/aws/lambda/devops-agent-jira-integration-EventHandler" --follow
```

---

## 7. Teardown & Clean Up

To delete all created resources:

```bash
bash scripts/cleanup.sh
```

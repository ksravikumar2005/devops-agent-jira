# AWS DevOps Agent to Atlassian Jira Cloud Integration

[![AWS](https://img.shields.io/badge/AWS-EventBridge%20%7C%20Lambda%20%7C%20DynamoDB-orange.svg)](https://aws.amazon.com/)
[![Jira](https://img.shields.io/badge/Jira%20Cloud-REST%20API%20v3%20(ADF)-blue.svg)](https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/)
[![CloudShell Ready](https://img.shields.io/badge/AWS%20CloudShell-Interactive%20Setup-green.svg)](https://aws.amazon.com/cloudshell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Autonomous Incident Management & AI-Powered Root Cause Analysis (RCA) Bridge**  
> Connects **AWS DevOps Agent** operational investigation lifecycle events directly into **Atlassian Jira Cloud** using Amazon EventBridge, AWS Lambda, and Amazon DynamoDB.

Based on the official AWS DevOps Architecture:
- [AWS DevOps Blog: Integrate AWS DevOps Agent with third-party tools using Amazon EventBridge](https://aws.amazon.com/blogs/devops/integrate-aws-devops-agent-with-third-party-tools-using-amazon-eventbridge/)
- [aws-samples/sample-aws-devops-agent-eventbridge-integration](https://github.com/aws-samples/sample-aws-devops-agent-eventbridge-integration)

---

## 🌟 Core Capabilities: Bi-Directional Closed-Loop Integration

This solution provides a complete, production-ready, bi-directional integration between **Atlassian Jira Cloud** and **AWS DevOps Agent**:

### 1. Inbound Investigation Trigger (Jira ➡️ AWS DevOps Agent)
* **Trigger Investigations from Jira**: Whenever an incident or alert ticket is submitted in Jira (or when an engineer adds the `/investigate` slash command or label `aws-devops-agent`), the solution automatically prompts AWS DevOps Agent to initiate an autonomous diagnostic investigation on your AWS environment.
* **Instant Acknowledgment**: The integration immediately posts a reply comment on the Jira ticket confirming the AWS DevOps Agent **Task ID** and providing a direct deep link to view real-time diagnostics in the AWS Console.

### 2. Outbound Ticket Creation & Updates (AWS DevOps Agent ➡️ Jira)
* **Automated Ticket Creation from Non-Jira Sources**: Whenever a new investigation begins in AWS DevOps Agent—triggered by **any non-Jira source** (such as Amazon CloudWatch alarms, AWS Console, AWS CLI, automated EventBridge rules, or third-party monitoring)—the integration automatically creates a corresponding Jira ticket in your target project (`KAN`).
* **Continuous Diagnostic & RCA Updates**: As the agent investigates your infrastructure, it streams diagnostic step updates directly into the Jira ticket comments. When the analysis concludes, it automatically appends the complete **Root Cause Analysis (RCA)**, affected AWS resource ARNs, and recommended remediation actions, and applies the `rca-completed` label!

---

## 🗺️ Complete End-to-End Implementation Sequence

Follow this complete step-by-step sequence to go from zero to a live, bi-directional production integration:

```mermaid
flowchart LR
    S1["1. Set Up Jira<br/>(Site, Token & Project)"] --> S2["2. Set Up DevOps Agent<br/>(Create Space)"]
    S2 --> S3["3. Deploy in CloudShell<br/>(git clone & setup wizard)"]
    S3 --> S4["4. Register Webhook<br/>(Paste secured URL in Jira)"]
    S4 --> S5["5. Live Verification<br/>(Test Outbound & Inbound)"]
```

| Step | Action | Description |
| :--- | :--- | :--- |
| **1** | **Set Up Atlassian Jira Cloud** | Sign up/sign in, note your target Project Key (`KAN`), and generate a standard API token from Atlassian Security. |
| **2** | **Set Up AWS DevOps Agent** | Create or locate your Agent Space in the AWS Console (`us-east-1`), noting either your Space Name or Space ID. |
| **3** | **Deploy via AWS CloudShell** | Clone this repository in CloudShell and execute `bash cloudshell-setup.sh` to provision the entire serverless infrastructure. |
| **4** | **Configure Jira Inbound Webhook** | Copy the generated Secured Webhook URL (`?token=...`) into Jira **Settings > System > Webhooks**. |
| **5** | **Verify & Test Bi-Directional Flow** | Run Scenario 1 (DevOps Agent ➔ Jira) and Scenario 2 (Jira ➔ DevOps Agent) to confirm ticket creation, status updates, and RCA comments. |

---

## 🔍 Verifying Your Jira API Key (Pre-Flight Check)

Before running the deployment, verify your Jira Cloud URL, user email, and API token directly from AWS CloudShell or your local terminal:

```bash
# 1. Test Jira Authentication (Returns HTTP 200 with your user profile details)
curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
  -H "Accept: application/json" \
  "https://YOUR_ORG.atlassian.net/rest/api/3/myself"

# 2. Test Project Access (Verify your project key, e.g. KAN or OPS)
curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
  -H "Accept: application/json" \
  "https://YOUR_ORG.atlassian.net/rest/api/3/project/YOUR_PROJECT_KEY"
```

> [!TIP]
> **Expected Outcome**: An `HTTP/2 200 OK` response with a JSON payload containing your `displayName` and `accountId`.  
> - If you receive `HTTP 401 Unauthorized`, verify that your email matches your Atlassian login and regenerate your API token.  
> - If you receive `HTTP 404 Not Found`, ensure your project key matches the exact uppercase code shown under the **Key** column in Jira (e.g. `KAN`).

---

## 🚀 1-Line Quickstart (AWS CloudShell)

Open **[AWS CloudShell](https://console.aws.amazon.com/cloudshell/)** in the region where your AWS DevOps Agent Space is located and paste:

```bash
git clone https://github.com/ksravikumar2005/devops-agent-jira.git && cd devops-agent-jira && bash cloudshell-setup.sh
```

The interactive wizard will:
1. Verify CloudShell dependencies and AWS STS credentials.
2. Auto-discover your active AWS DevOps Agent Space.
3. Securely prompt for and validate your Jira Cloud URL, Admin Email, and API Token via live pre-flight checks.
4. Provision AWS Secrets Manager secret, DynamoDB state tracking table, and IAM execution roles.
5. Deploy the serverless integration layer (CloudFormation template + Python 3.12 Lambda).
6. Configure the Amazon EventBridge rule filtering `aws.aidevops` lifecycle events.
7. Offer two live verification scenarios:
   - **Scenario 1**: Trigger a REAL investigation in AWS DevOps Agent and verify live Jira ticket creation and RCA updates.
   - **Scenario 2**: Create a live incident in Jira and verify inbound triggering of AWS DevOps Agent with acknowledgment.

---

## 📐 Architecture Overview

```mermaid
sequenceDiagram
    autonumber
    participant DA as AWS DevOps Agent
    participant EB as Amazon EventBridge (default bus)
    participant L as AWS Lambda (Event Handler)
    participant SM as AWS Secrets Manager
    participant DDB as Amazon DynamoDB (State Table)
    participant JIRA as Atlassian Jira Cloud

    Note over DA,EB: Incident or Anomaly Detected
    DA->>EB: Emit Event (source: "aws.aidevops", detail-type: "Investigation Created")
    EB->>L: Trigger Lambda with Event Payload
    L->>SM: Retrieve Cached Jira Credentials
    L->>JIRA: POST /rest/api/3/issue (Create Ticket with ADF Context & Console Link)
    JIRA-->>L: Returns Jira Issue Key (e.g. OPS-142)
    L->>DDB: Save Mapping (taskId <-> jiraIssueKey, status: "PENDING")

    Note over DA,EB: Autonomous Diagnostic Analysis
    DA->>EB: Emit Event ("Investigation In Progress")
    EB->>L: Trigger Lambda
    L->>DDB: Lookup Jira Issue Key by taskId
    L->>JIRA: POST /rest/api/3/issue/{key}/comment (Add Step Progress Update)

    Note over DA,EB: Diagnostics & RCA Concluded
    DA->>EB: Emit Event ("Investigation Completed", RCA & Recommendations)
    EB->>L: Trigger Lambda
    L->>DDB: Lookup Jira Issue Key
    L->>JIRA: POST /rest/api/3/issue/{key}/comment (Publish Full RCA & Action Items)
    L->>JIRA: PUT /rest/api/3/issue/{key} (Add labels: rca-completed, transition to In Progress)
    L->>DDB: Update status to "COMPLETED"
```

### Key Architectural Components

| Component | Resource | Purpose |
| :--- | :--- | :--- |
| **Event Source** | `aws.aidevops` | DevOps Agent emits lifecycle events on investigation trigger, step progress, and completion. |
| **Event Router** | **Amazon EventBridge** | Evaluates rule pattern `{"source": ["aws.aidevops"], "detail-type": [{"prefix": "Investigation"}]}`. |
| **Execution Layer** | **AWS Lambda** (Python 3.12) | Formats rich Atlassian Document Format (ADF) payloads, calls Jira Cloud REST API v3, and queries DynamoDB. Zero pip packaging dependencies. |
| **State Tracking** | **Amazon DynamoDB** | Maps DevOps Agent `taskId` to Jira `issueKey` with PITR and AWS managed encryption. |
| **Security Layer** | **AWS Secrets Manager** | Encrypts Jira Base URL, Admin Email, API Token, and project keys with KMS. |
| **Bi-directional Webhook** | **Lambda Function URL** | Enables Jira Cloud webhooks (e.g. `/investigate` comment or manual incident assignment) to trigger autonomous investigations. |

### 🛡️ Idempotency & Duplicate Prevention Architecture

To prevent duplicate tickets, redundant comments, or infinite ping-pong loops, the architecture enforces **four layers of strict idempotency guards** backed by Amazon DynamoDB:

1. **Outbound Event Deduplication**: When EventBridge delivers `Investigation Created`, Lambda first checks DynamoDB for `taskId`. If a record already exists (e.g. from an EventBridge retry or an investigation that originated from Jira), Lambda aborts immediately without calling Jira.
2. **Duplicate RCA Protection**: When `Investigation Completed` arrives, Lambda checks if DynamoDB status is already `COMPLETED`. If so, it skips posting duplicate RCA comments.
3. **Inbound Jira Update Deduplication**: When an engineer performs routine edits on a Jira ticket (changing assignees, modifying descriptions, or moving cards on a Kanban board), the webhook checks DynamoDB for an active investigation (`JIRA#{issue_key}`). Routine field updates are safely acknowledged without spawning duplicate tasks.
4. **Echo / Ping-Pong Loop Prevention**: When an investigation is triggered from Jira, the webhook registers `taskId ↔ issue_key` in DynamoDB *before* DevOps Agent starts. When DevOps Agent emits its native `Investigation Created` event to EventBridge, the Event Handler Lambda finds the existing mapping and skips creating a duplicate ticket!

---

## 📦 What's Getting Deployed

When you deploy this integration, the setup script provisions the following infrastructure in your AWS account and establishes the Jira Cloud bridge:

```text
[AWS DevOps Agent Space] ──► [Amazon EventBridge Rule]
                                    │
                                    ▼
                          [AWS Lambda Handler] ◄──► [AWS Secrets Manager]
                                    │
                  ┌─────────────────┴─────────────────┐
                  ▼                                   ▼
        [Amazon DynamoDB]                 [Atlassian Jira Cloud]
     (State & Mapping Table)             (Issues, Comments, RCA)
                  ▲                                   │
                  │                                   ▼
    [Lambda Webhook Receiver] ◄────────────── [Jira Webhook (/investigate)]
```

### 1. AWS CloudFormation Stack (`devops-agent-jira-integration`)
| Provisioned AWS Resource | Resource Name / Identifier | Purpose |
| :--- | :--- | :--- |
| **AWS Secrets Manager Secret** | `devops-agent/jira-credentials` | Encrypted with AWS KMS; securely stores Jira Base URL, email, API token, project key (`KAN`), and issue type (`Task`). |
| **Amazon DynamoDB Table** | `devops-agent-jira-mappings` | Pay-per-request billing, PITR enabled, server-side encrypted; maps DevOps Agent `taskId` to Jira `issueKey`. |
| **AWS Lambda: Event Handler** | `devops-agent-jira-integration-EventHandler` | Python 3.12 (256 MB, 60s timeout); processes EventBridge `aws.aidevops` lifecycle events and manages Jira issues via REST API v3. |
| **Amazon EventBridge Rule** | `devops-agent-jira-integration-InvestigationRule` | Filters events with `source: ["aws.aidevops"]` and `detail-type: [{"prefix": "Investigation"}]` to trigger the Lambda handler. |
| **AWS Lambda: Webhook Receiver** | `devops-agent-jira-integration-WebhookReceiver` | Python 3.12 with public HTTPS Function URL; receives inbound Jira webhooks (e.g. `/investigate` comments) for bi-directional incident management. |
| **Lambda Function URL** | `https://<id>.lambda-url.<region>.on.aws/` | Inbound webhook endpoint for Jira with CORS enabled. |
| **IAM Execution Role** | `devops-agent-jira-integration-ExecutionRole` | Least-privilege role scoped to DynamoDB table, Secrets Manager secret ARN, EventBridge, and CloudWatch Logs. |
| **CloudWatch Log Groups** | `/aws/lambda/devops-agent-jira-integration-*` | 30-day retention logging for diagnostics and auditability. |

### 2. Atlassian Jira Cloud Resources Synchronized
| Jira Resource | Details |
| :--- | :--- |
| **Automated Investigation Issues** | Automatically created in project `KAN` with summary, context panel, and deep link to the AWS Console DevOps Agent Space. |
| **Diagnostic Journal Comments** | Appends step-by-step progress notes to the Jira ticket as the agent correlates logs, metrics, and traces. |
| **Root Cause Analysis (RCA)** | Success panel containing root cause summary, affected resource ARNs, and recommended remediations. |
| **Labels & Tags** | Attaches `aws-devops-agent`, `automated-investigation`, `rca-completed`, and `aws-<region>`. |
| **Workflow Status Transitions** | Automatically transitions ticket status (e.g. to *In Progress*). |

---

## 📋 Minimum Requirements

Before deploying this integration, ensure your environment meets the following baseline requirements:

### 1. AWS Account & Services
| Requirement | Minimum Specification | Details |
| :--- | :--- | :--- |
| **AWS Account** | Standard / Organizations Member | Access to the AWS Management Console and CloudShell. |
| **Target Region** | `us-east-1` (or supported region) | Region where your AWS DevOps Agent Space is active. |
| **AWS DevOps Agent** | Active Agent Space | Configured Agent Space (`aspc-xxxx`) in your target AWS account. |
| **IAM Permissions** | Administrator or Custom Policy | Deployment requires permissions to provision:<br>• `cloudformation:*`<br>• `lambda:*` (including Function URLs)<br>• `dynamodb:*`<br>• `events:*` (EventBridge Rules & Bus PutEvents)<br>• `secretsmanager:*`<br>• `iam:CreateRole`, `iam:PutRolePolicy`, `iam:PassRole` |
| **Shell Environment** | **AWS CloudShell** *(Recommended)* | Native CloudShell comes pre-configured with AWS CLI v2, `jq`, `zip`, Python 3, and authenticated session credentials. |

### 2. Atlassian Jira Cloud
| Requirement | Minimum Specification | Details |
| :--- | :--- | :--- |
| **Jira Edition** | Jira Cloud (Standard, Premium, Enterprise) | Jira Cloud site (e.g., `https://<organization>.atlassian.net`). *Note: Jira Server/Data Center requires self-hosted endpoint access.* |
| **User Role** | Site Administrator or Project Admin | Account must have permission to create issues, add comments, update labels, and create webhooks in the target project. |
| **Authentication** | Atlassian API Token | Generated at [id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens). |
| **Target Project** | 1 Active Project | Project Key (e.g. `OPS`, `INC`, `PROD`, `DEVOPS`) with issue type `Incident`, `Bug`, or `Task`. |

### 3. Local Machine Tooling *(Only needed if NOT using AWS CloudShell)*
If deploying from your local workstation instead of AWS CloudShell:
- **OS**: Linux, macOS, or Windows with WSL / Git Bash.
- **AWS CLI**: v2.15.0 or higher, authenticated via `aws configure` or AWS IAM Identity Center (SSO).
- **Utilities**: `bash` (4.x+), `curl`, `jq` (1.6+), `zip`.
- **Python**: Python 3.10+ (if running synthetic simulation scripts locally).
- **Node.js & npm** *(Optional)*: Node.js 18+ and `aws-cdk` (only required if deploying via the TypeScript CDK stack).

---

## 🛠️ Step-by-Step Implementation Guide

Follow the five sequenced steps below to configure, deploy, secure, and verify the integration:

---

### Step 1: Set Up Atlassian Jira Cloud & API Credentials

1. **Access Jira Cloud**: Sign in to your Atlassian site (e.g., `https://mycompany.atlassian.net`).
   > [!TIP]
   > You can copy your Jira Base URL directly from your browser's address bar:
   >
   > <p align="center">
   >   <img src="docs/images/jira-base-url-address-bar.png" alt="Copy Jira Base URL from Address Bar" width="650" />
   > </p>

2. **Designate a Project**: Identify your target Project Key (e.g., `KAN` or `OPS`).
3. **Generate an Atlassian API Token**:
   - Navigate to **[Atlassian Security > API Tokens](https://id.atlassian.com/manage-profile/security/api-tokens)**.
   - Click **Create API token** *(select the standard option, not "with scopes")*.
   - **Name**: `aws_devops_agent`.
   - **Expires on**: Select your preferred expiration (up to 1 year).

   <p align="center">
     <img src="docs/images/create-jira-api-token.png" alt="Create Atlassian API Token" width="550" />
   </p>

   - Click **Create** and copy the token immediately.

4. **Verify Connectivity (Pre-Flight Check)**:
   Run these curl checks from CloudShell or your terminal to verify API authentication and project permissions:
   ```bash
   # Test Authentication
   curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
     -H "Accept: application/json" \
     "https://mycompany.atlassian.net/rest/api/3/myself"

   # Test Project Access
   curl -s -i -u "YOUR_EMAIL:YOUR_API_TOKEN" \
     -H "Accept: application/json" \
     "https://mycompany.atlassian.net/rest/api/3/project/KAN"
   ```

5. **Issue Types & Permissions**:
   - **Team-managed projects**: Use issue type **`Task`** or **`Bug`** (the integration auto-detects this).
   - **Company-managed / ITSM projects**: Use **`Incident`**, **`Bug`**, or **`Task`**.
   - Ensure custom fields are not marked as strictly *Required* on the issue creation screen.

---

### Step 2: Set Up AWS DevOps Agent Space

1. In the AWS Management Console, navigate to **AWS DevOps Agent** in your target region (e.g. `us-east-1`).
2. Open **Agent spaces** and click the **Create agent space** button:

   <p align="center">
     <img src="docs/images/create-agent-space.png" alt="Create Agent Space" width="700" />
   </p>

3. **Step 1 - Agent Space Properties**:
   - **Agent space name**: Enter a name (e.g., `jira-integration` or `DevOpsSpace-Prod`).
   - **Description**: Enter a description (e.g., `AWS DevOps Agent to Atlassian Jira Cloud Integration`).
   - **Enable web app**: Select *Auto-create a new DevOps Agent role*.
   - Click **Next**.

   <p align="center">
     <img src="docs/images/create-agent-space-1.png" alt="Agent Space Properties" width="700" />
   </p>

4. **Step 2 - Agent Scope**:
   - **Account scope**: Select *Individual accounts* (or Organization scope if managing across AWS Organizations).
   - **Primary account role**: Select *Auto-create a new DevOps Agent role*.
   - Click **Next**.

   <p align="center">
     <img src="docs/images/create-agent-space-2.png" alt="Agent Scope" width="700" />
   </p>

5. **Step 3 - Additional Configuration (Optional)**:
   - **Content safety guardrail**: Enabled by default to screen prompts and violations.
   - **Encryption**: Keep *AWS owned key* (or select Customer managed KMS key).
   - Click **Next**.

   <p align="center">
     <img src="docs/images/create-agent-space-3.png" alt="Additional Configuration" width="700" />
   </p>

6. **Step 4 - Review and Create**:
   - Review your settings and click **Create agent space**.

   <p align="center">
     <img src="docs/images/create-agent-space-4.png" alt="Review and Create Agent Space" width="700" />
   </p>

7. **Locate your Agent Space Name or Space ID**:
   Once created, you can use either your **Agent Space Name** (e.g., `jira-integration`) or your **Space ID UUID**:
   > [!TIP]
   > You can copy the Space ID (UUID format, e.g. `3f1e5f09-659d-4073-a7a5-2b5ca9e633bd`) directly from the console's top breadcrumb navigation:
   >
   > <p align="center">
   >   <img src="docs/images/aws-devops-agent-space-id.png" alt="AWS DevOps Agent Space ID Breadcrumb" width="650" />
   > </p>
   > *(The setup script supports entering either the Space Name or the Space ID and automatically resolves names to the underlying ID).*

8. *(Optional)* Under **Capability Providers**, you can enable the **Atlassian Remote MCP Server** (`https://mcp.atlassian.com/v2/mcp`) so the agent's AI reasoning loop can query Jira and Confluence runbooks during investigations.

---

### Step 3: Deploy via AWS CloudShell

#### Option A: Interactive Wizard (Recommended)
1. Open **[AWS CloudShell](https://console.aws.amazon.com/cloudshell/)** in your target region (`us-east-1`).
2. Clone the repository and execute the setup wizard:
   ```bash
   git clone https://github.com/ksravikumar2005/devops-agent-jira.git
   cd devops-agent-jira
   bash cloudshell-setup.sh
   ```

   <p align="center">
     <img src="docs/images/cloudshell-setup.png" alt="CloudShell Setup Wizard Launch" width="700" />
   </p>

3. Follow the interactive prompts:
   - **Target Region**: Confirm `us-east-1`.
   - **Agent Space**: Enter your Space Name or Space ID (e.g. `jira-integration`).
   - **Jira Base URL**: Enter `https://mycompany.atlassian.net` (trailing slashes are sanitized automatically).
     > <p align="center">
     >   <img src="docs/images/jira-base-url-address-bar.png" alt="Copy Jira Base URL from Address Bar" width="650" />
     > </p>
   - **Email & Token**: Enter your Jira email and paste your API token.
   - **Project Key**: Enter `KAN`.
   - **Issue Type**: Automatically selects `Task` for team-managed projects.

   <p align="center">
     <img src="docs/images/cloudshell-setup-1.png" alt="CloudShell Interactive Setup & Verification" width="700" />
   </p>

4. **Automated Live Verification**:
   The script prompts you to run live verification. Scenario 1 submits an actual investigation to AWS DevOps Agent, routes it to EventBridge, creates a live ticket in Jira (`KAN-5`), and prints your secured Webhook URL:

   <p align="center">
     <img src="docs/images/cloudshell-setup-2.png" alt="CloudShell Verification Success" width="700" />
   </p>

#### Option B: Headless Non-Interactive Mode (Zero Prompts)
```bash
export AWS_REGION="us-east-1"
export AGENT_SPACE_NAME="DevOpsSpace-Prod" # Or export AGENT_SPACE_ID="..."
export JIRA_URL="https://mycompany.atlassian.net"
export JIRA_EMAIL="admin@mycompany.com"
export JIRA_TOKEN="your_atlassian_api_token"
export JIRA_PROJECT="KAN"
export JIRA_ISSUE_TYPE="Task"
export TEST_SCENARIO="1"

bash cloudshell-setup.sh --non-interactive
```

#### What Gets Automated:
* Deploys the CloudFormation stack (`devops-agent-jira-integration`).
* Stores credentials and generates a 32-character cryptographic shared secret token in AWS Secrets Manager (`devops-agent/jira-credentials`).
* Provisions the DynamoDB state table (`devops-agent-jira-mappings`) with idempotency guards.
* Configures the EventBridge rule filtering `aws.aidevops` events and creates Lambda functions.
* Outputs your **Secured Webhook URL** with the token query parameter.

---

### Step 4: Register Secured Webhook in Jira

To allow Jira to securely notify AWS DevOps Agent, register the secured webhook:

1. Retrieve your full secured URL from CloudFormation & Secrets Manager:
   ```bash
   WEBHOOK_URL=$(aws cloudformation describe-stacks \
     --stack-name devops-agent-jira-integration \
     --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
     --output text)

   WEBHOOK_TOKEN=$(aws secretsmanager get-secret-value \
     --secret-id "devops-agent/jira-credentials" \
     --query "SecretString" --output text | jq -r '.webhook_secret_token')

   echo -e "\nSecured Webhook URL:\n${WEBHOOK_URL}?token=${WEBHOOK_TOKEN}\n"
   ```
   *(You can also view the raw `JiraWebhookUrl` output directly in the AWS CloudFormation Console)*:

   <p align="center">
     <img src="docs/images/cloudformation-jira-webhook-1.png" alt="CloudFormation Outputs Tab JiraWebhookUrl" width="700" />
   </p>

2. In Atlassian Jira Cloud:
   - Click the gear icon (**Settings ⚙️**) in the top right header.
   - Navigate to **System > Webhooks** (under *Advanced* in the left sidebar).
   - Click **+ Create a Webhook** (top right).
   - Configure:
     - **Name**: `AWS DevOps Agent Integration`
     - **Status**: `Enabled`
     - **URL**: Paste your full secured URL (including `?token=...`). Any request lacking this cryptographic token is rejected with **HTTP 403 Forbidden**.

     <p align="center">
       <img src="docs/images/jira-webhook-2.png" alt="Jira Webhook Configuration" width="700" />
     </p>

     - **Issue related events**:
       - Check **Issue**: `created`, `updated`
       - Check **Comment**: `created` (and `updated`)

     <p align="center">
       <img src="docs/images/jira-webhook-3.png" alt="Jira Webhook Events Checklist" width="700" />
     </p>

     - *(Optional JQL Filter)*: `project = "KAN"`
   - Scroll to the bottom of the page and click **Create**.

---

### Step 5: Live Verification & Testing

Verify both directions of the incident management lifecycle:

#### Scenario 1: Outbound Flow (AWS DevOps Agent ➡️ Jira)
Trigger a real autonomous investigation from CloudShell using the official AWS CLI:
```bash
bash scripts/create-real-investigation.sh \
  "Investigate High Latency Anomaly on Checkout API" \
  "CloudWatch metrics indicate elevated p99 latency exceeding 4500ms on ALB target group."
```

You can view the active investigation in your **AWS DevOps Agent Incident Response Dashboard**:

<p align="center">
  <img src="docs/images/investigation-devops-agent-1.png" alt="AWS DevOps Agent Incident Response Dashboard" width="700" />
</p>

* **Observed in Jira**:
  1. A new incident ticket is automatically created in project `KAN`.
  2. Diagnostic journal updates stream into ticket comments.
  3. When complete, the full **Root Cause Analysis (RCA)**, affected resources, and remediation action items are posted directly into the Jira ticket comments, and the label `rca-completed` is applied!

#### Scenario 2: Inbound Flow (Jira ➡️ AWS DevOps Agent)
Test triggering DevOps Agent from Jira:
1. Open any existing ticket (e.g. `KAN-4`) or create a new ticket in project `KAN`.
2. In the comment box, type:
   ```text
   /investigate
   ```
   *(or attach the label `aws-devops-agent` to the ticket)*.
3. **Observed in Jira**:
   - The webhook receiver authenticates the shared secret token.
   - AWS DevOps Agent starts an investigation in AWS and immediately replies on the ticket with the **Task ID** and AWS Console deep link.
   - When the investigation concludes, the agent posts the full Root Cause Analysis (RCA) and remediation steps back to that same Jira ticket!

---

## 🧹 Teardown & Cleanup Options

When you need to remove the integration and delete all provisioned AWS resources:

### Option 1: Via the Setup Script
```bash
# Interactive cleanup (prompts for confirmation)
bash cloudshell-setup.sh --cleanup

# Automated non-interactive cleanup (skips confirmation prompt)
bash cloudshell-setup.sh --cleanup --force
```

### Option 2: Using the Dedicated Cleanup Script
```bash
bash scripts/cleanup.sh
```

### Resources Cleaned Up:
- **CloudFormation Stack**: Deletes `devops-agent-jira-integration` (Lambda functions, EventBridge rule, IAM roles, log groups).
- **AWS Secrets Manager**: Permanently removes `devops-agent/jira-credentials` without recovery delay.
- **Amazon DynamoDB**: Drops the state tracking table `devops-agent-jira-mappings`.

---

### Method B: AWS CloudFormation Direct Deployment

If deploying via CI/CD or AWS CloudFormation Console:

1. Store your credentials in AWS Secrets Manager:
   ```bash
   aws secretsmanager create-secret \
     --name "devops-agent/jira-credentials" \
     --description "Jira Cloud credentials for DevOps Agent" \
     --secret-string '{"jira_base_url":"https://mycompany.atlassian.net","jira_user_email":"admin@mycompany.com","jira_api_token":"YOUR_TOKEN","jira_project_key":"OPS","jira_issue_type":"Incident"}'
   ```

2. Package and deploy `template.yaml`:
   ```bash
   # Package Lambda code
   cd src/lambda && zip -r /tmp/lambda.zip ./*.py && cd ../..

   # Deploy CloudFormation stack
   aws cloudformation deploy \
     --template-file template.yaml \
     --stack-name devops-agent-jira-integration \
     --parameter-overrides \
       SecretName="devops-agent/jira-credentials" \
       DynamoDBTableName="devops-agent-jira-mappings" \
       AgentSpaceId="default" \
     --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

   # Update Lambda function code
   aws lambda update-function-code \
     --function-name devops-agent-jira-integration-EventHandler \
     --zip-file fileb:///tmp/lambda.zip
   ```

---

### Method C: AWS CDK (TypeScript) Deployment

For teams using Infrastructure as Code (IaC) pipelines:

```bash
cd cdk
npm install
npx cdk bootstrap
npx cdk deploy --context secretName="devops-agent/jira-credentials"
```

---

## 📊 Useful Jira Filters & Dashboards (JQL)

Monitor and manage your AWS DevOps Agent incidents in Jira using these pre-built JQL queries:

* **All Active DevOps Agent Tickets**:
  ```jql
  project = "KAN" AND labels = "aws-devops-agent" AND statusCategory != Done ORDER BY created DESC
  ```
* **Tickets with Completed Root Cause Analysis**:
  ```jql
  project = "KAN" AND labels = "rca-completed" ORDER BY updated DESC
  ```
* **High & Critical Cloud Incidents**:
  ```jql
  project = "KAN" AND labels = "aws-devops-agent" AND priority in (High, Highest, Critical)
  ```

---

## 🧪 Synthetic & Direct Testing Utilities

In addition to live AWS investigations (Step 5), the repository includes automated simulation scripts to test webhook handling and EventBridge event ingestion:

```bash
bash scripts/test-integration.sh
```

Or test Lambda directly without publishing to EventBridge:
```bash
bash scripts/test-integration.sh --direct
```

Or run the Python simulator:
```bash
python3 scripts/simulate-investigation.py --region us-east-1 --space-id 3f1e5f09-659d-4073-a7a5-2b5ca9e633bd
```

### What you will observe in Jira:
1. **Ticket Creation**: A new issue created in your project with summary `[AWS DevOps Agent] Synthetic Test: Spikeline Latency Anomaly...`
2. **Context Block**: ADF Info panel with AWS Account ID, Region, Agent Space ID, Task ID, and a direct link to the AWS DevOps Agent Console.
3. **Investigation Update**: An informational comment noting log ingestion and trace correlation.
4. **Root Cause Analysis (RCA)**: A formatted green success panel with root cause analysis, affected resources bullet list, recommended remediations, and links to trace artifacts.

---

## 📁 Repository Structure

```text
devops-agent-jira/
├── README.md                      # Complete overview and quickstart guide
├── cloudshell-setup.sh            # 1-line CloudShell entrypoint script
├── setup-jira-integration.sh      # Interactive, validated bash setup wizard
├── template.yaml                  # AWS CloudFormation deployment template
├── .env.example                   # Environment configuration template
├── .gitignore                     # Standard Git ignore rules
├── LICENSE                        # MIT License
│
├── docs/                          # Detailed operational documentation
│   ├── ARCHITECTURE.md            # Technical architecture, schemas & data models
│   ├── INSTALL.md                 # Detailed step-by-step setup guide
│   └── JIRA_CONFIGURATION.md      # Jira issue types, fields & webhook guides
│
├── src/
│   └── lambda/                    # Production serverless source code (Python 3.12)
│       ├── event_handler.py       # Main EventBridge consumer & router
│       ├── jira_client.py         # Zero-dependency Jira Cloud REST API v3 client (ADF)
│       ├── webhook_receiver.py    # Inbound Jira webhook listener
│       └── requirements.txt       # Python runtime dependencies
│
├── cdk/                           # AWS CDK TypeScript alternative deployment
│   ├── bin/cdk.ts                 # CDK entry point
│   ├── lib/devops-agent-jira-stack.ts  # CDK Stack definition
│   ├── package.json               # Node.js dependencies
│   ├── tsconfig.json              # TypeScript configuration
│   └── cdk.json                   # CDK toolkit configuration
│
├── events/                        # Sample EventBridge test payloads
│   ├── sample-investigation-created.json
│   ├── sample-investigation-in-progress.json
│   ├── sample-investigation-completed.json
│   └── sample-investigation-failed.json
│
└── scripts/                       # Operational & testing utilities
    ├── test-integration.sh        # End-to-end EventBridge test emitter
    ├── simulate-investigation.py  # Python simulation & verification utility
    └── cleanup.sh                 # Safe teardown & resource removal script
```

---

## 🛡️ Security & Compliance

- **No Hardcoded Credentials**: API tokens, base URLs, and emails are strictly stored in AWS Secrets Manager and retrieved dynamically at runtime.
- **Least Privilege IAM**: The Lambda execution role has targeted policies restricted to the designated Secrets Manager secret, DynamoDB table ARN, and EventBridge buses.
- **Data Protection**: DynamoDB is configured with Point-In-Time Recovery (PITR) and AES-256 AWS managed encryption at rest. All API communication with Atlassian Cloud occurs over HTTPS (TLS 1.3).

---

## 🤝 Contributing

Contributions, feature requests, and issue reports are welcome! Please open an issue or pull request to [https://github.com/ksravikumar2005/devops-agent-jira](https://github.com/ksravikumar2005/devops-agent-jira).

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

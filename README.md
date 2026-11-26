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

Repository Target: [https://github.com/ksravikumar2005/devops-agent-jira](https://github.com/ksravikumar2005/devops-agent-jira)

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
7. Execute an automated synthetic investigation test that creates a live Jira ticket and appends a simulated Root Cause Analysis (RCA)!

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

## 🛠️ Step-by-Step Installation

### Prerequisites
1. **AWS Account**: An active AWS account with permissions to deploy CloudFormation, Lambda, DynamoDB, Secrets Manager, and EventBridge.
2. **AWS DevOps Agent Space**: Configured in your AWS region (e.g., `us-east-1` or `us-west-2`).
3. **Jira Cloud Admin Access**:
   - Access to your Atlassian Jira Cloud instance (e.g., `https://yourcompany.atlassian.net`).
   - An Atlassian API Token generated from [https://id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens).
   - An existing Jira Project Key (e.g., `OPS`, `INC`, `PROD`).

---

### 🔑 Generating your Atlassian API Token

1. Navigate to **[Atlassian Security > API Tokens](https://id.atlassian.com/manage-profile/security/api-tokens)**.
2. Click **Create API token** *(choose the standard option, not "with scopes", so it inherits basic auth permissions)*.
3. In the creation dialog:
   - **Name**: Enter a descriptive name such as `aws_devops_agent`.
   - **Expires on**: Choose an expiration date (tokens can last up to 1 year).

<p align="center">
  <img src="docs/images/create-jira-api-token.png" alt="Create Atlassian API Token" width="550" />
</p>

4. Click **Create**.
5. **Copy the token immediately**: Store it securely. You will paste this token into the CloudShell interactive setup script.

---

### 🔍 Verifying Your Jira API Key (Pre-Flight Check)

Before running the deployment, you can quickly test your Jira URL, email, and API token directly from AWS CloudShell or your local terminal:

```bash
# 1. Test Jira Authentication (Returns HTTP 200 with your profile details)
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
> If you receive `HTTP 401 Unauthorized`, verify that your email matches your Atlassian login and regenerate the API token.  
> If you receive `HTTP 404 Not Found`, ensure your project key matches the exact code shown under the **Key** column in Jira.

---

### Method A: AWS CloudShell Deployment

#### Option 1: Interactive Wizard (Default)
1. Open AWS CloudShell in your browser.
2. Clone this repository and run the setup wizard:
   ```bash
   git clone https://github.com/ksravikumar2005/devops-agent-jira.git
   cd devops-agent-jira
   bash cloudshell-setup.sh
   ```
3. Follow the interactive prompts:
   - Confirm your target AWS Region.
   - Choose or enter your AWS DevOps Agent Space ID.
     > [!TIP]
     > **Locating Your Agent Space ID**: In the AWS Console, open **AWS DevOps Agent > Agent spaces** and click on your space. You can copy the Space ID (UUID format, e.g. `3f1e5f09-659d-4073-a7a5-2b5ca9e633bd`) directly from the console's top breadcrumb navigation:
     >
     > <p align="center">
     >   <img src="docs/images/aws-devops-agent-space-id.png" alt="AWS DevOps Agent Space ID Breadcrumb" width="650" />
     > </p>
   - Input your Jira URL (`https://mycompany.atlassian.net`), User Email, and API Token.
     > [!TIP]
     > **Copying Your Jira Base URL**: You can copy the base URL directly from your browser's address bar when signed into Jira (everything up to `.atlassian.net`):
     >
     > <p align="center">
     >   <img src="docs/images/jira-base-url-address-bar.png" alt="Copy Jira Base URL from Address Bar" width="650" />
     > </p>
     >
     > *(Note: Accidental trailing slashes like `https://mycompany.atlassian.net/` are automatically sanitized and stripped by the setup script and Lambda integration to prevent double-slash API path errors).*
   - Specify your Jira Project Key (`OPS` or `KAN`) and Issue Type (`Task`, `Bug`, or `Incident`). The script automatically detects valid issue types for your project.
   - Allow the script to run the live pre-flight check and synthetic test.

#### Option 2: Environment Variables / Headless Mode (Zero Prompts)
You can export environment variables in CloudShell to run a completely automated setup without any interactive prompts:

```bash
# 1. Export configuration variables
export AWS_REGION="us-east-1"
export AGENT_SPACE_ID="3f1e5f09-659d-4073-a7a5-2b5ca9e633bd"
export JIRA_URL="https://aws-devops-agent.atlassian.net"
export JIRA_EMAIL="ksravikumar2005@gmail.com"
export JIRA_TOKEN="your_atlassian_api_token"
export JIRA_PROJECT="KAN"
export JIRA_ISSUE_TYPE="Task"
export RUN_TEST=true

# 2. Run automated setup
bash cloudshell-setup.sh --non-interactive
```

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

## ⚙️ Jira-Side Configuration Guide

To ensure your Atlassian Jira Cloud instance receives tickets and supports bidirectional investigation commands, perform the following setup steps:

### 1. User Permissions
Ensure your Atlassian user account (or service bot) has permissions in your target project (`KAN`):
- **Browse Projects**: View project and issues.
- **Create Issues**: Allows opening automated investigation tickets.
- **Add Comments**: Allows posting root cause analysis (RCA) and diagnostic progress.
- **Edit Issues**: Allows attaching labels (`aws-devops-agent`, `rca-completed`).

### 2. Issue Types & Required Fields
- **Team-managed projects** (Kanban/Scrum): Use issue type **`Task`** or **`Bug`** (the integration automatically detects this).
- **Company-managed / ITSM projects**: Use **`Incident`**, **`Bug`**, or **`Task`**.
- **Important**: In **Project settings > Issue types**, verify that custom fields (e.g. *Component*, *Version*, *Assignee*) are **NOT** marked as **Required** on the creation screen, as missing custom fields will cause Jira to reject automated API creation.

### 3. Register Inbound Webhook (Bi-directional Incident Management)
Enable engineers to trigger autonomous investigations directly from Jira:

1. Obtain your `JiraWebhookUrl` output from CloudFormation:
   ```bash
   aws cloudformation describe-stacks \
     --stack-name devops-agent-jira-integration \
     --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
     --output text
   ```
2. In Jira Cloud:
   - Click the gear icon (**Settings ⚙️**) in the top right header.
   - Navigate to **System > Webhooks** (under Advanced).
   - Click **+ Create a Webhook**.
   - Configure:
     - **Name**: `AWS DevOps Agent Integration`
     - **Status**: `Enabled`
     - **URL**: Paste your `JiraWebhookUrl`.
     - **Issue related events**:
       - Check **Issue**: `created`, `updated`
       - Check **Comment**: `created`
     - *(Optional JQL Filter)*: `project = "KAN"`
   - Click **Save**.

### 4. How Engineers Use It Inside Jira
- **Comment Trigger**: Type `/investigate` on any existing Jira ticket to trigger an automated AWS DevOps Agent investigation.
- **Label Trigger**: Apply the label `trigger-investigation` or `aws-devops-agent` to any issue.
- **JQL Incident Dashboard**:
  ```jql
  project = "KAN" AND labels = "aws-devops-agent" ORDER BY created DESC
  ```

---

## 🧪 Verification & Synthetic Testing

Run the included automated integration test script to inject synthetic `aws.aidevops` events:

```bash
bash scripts/test-integration.sh
```

Or run the Python simulator:
```bash
python3 scripts/simulate-investigation.py --region us-east-1 --space-id default
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

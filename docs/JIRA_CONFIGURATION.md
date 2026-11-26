# Jira Cloud Configuration & Incident Management Guide

This guide details all configuration steps required inside **Atlassian Jira Cloud** to enable seamless, bi-directional incident management with **AWS DevOps Agent**.

---

## 1. Atlassian API Token Creation

The integration authenticates using HTTP Basic Authentication with your Atlassian account email and an API token.

1. Navigate to: **[Atlassian Security > API Tokens](https://id.atlassian.com/manage-profile/security/api-tokens)**.
2. Click **Create API token** *(choose the standard option, not "with scopes")*.
3. In the modal:
   - **Name**: `aws_devops_agent`
   - **Expires on**: Select your preferred expiration date (up to 1 year).
4. Click **Create** and copy the token immediately.

<p align="center">
  <img src="images/create-jira-api-token.png" alt="Create Jira API Token" width="550" />
</p>

---

## 2. Jira Project Permissions

Ensure the Atlassian user account associated with the API token has sufficient permissions in your target project (e.g. `KAN`, `OPS`, or `INC`):

1. In Jira, navigate to your project.
2. Click **Project settings** (in the left navigation sidebar).
3. Select **Access** (in Team-managed projects) or **Permissions** (in Company-managed projects).
4. Verify your user has at least **Member** or **Administrator** role with the following permissions:
   - ✅ **Browse Projects**: View the project and verify existence.
   - ✅ **Create Issues**: Open automated incident and investigation tickets.
   - ✅ **Add Comments**: Post step-by-step telemetry updates and Root Cause Analysis (RCA) findings.
   - ✅ **Edit Issues**: Update issue labels (e.g. `rca-completed`, `aws-us-east-1`).
   - ✅ **Transition Issues**: Move tickets from *To Do* to *In Progress* / *Done*.

---

## 3. Issue Types Configuration

### A. Team-Managed Software Projects (e.g., Kanban / Scrum)
In **Team-managed software** projects, the default issue types are **`Task`** and **`Bug`**:
- When running the setup wizard, select **`Task`** or **`Bug`** as your active issue type.
- *(Optional)* To add `Incident` to a team-managed project:
  1. Go to **Project settings > Issue types**.
  2. Click **+ Add issue type**.
  3. Name it **`Incident`**, choose an icon, and click **Create**.

### B. Company-Managed / Jira Service Management Projects
In **Company-managed** or **ITSM** projects, issue types like **`Incident`**, **`Problem`**, and **`Service Request`** are already standard:
- Select **`Incident`** when running the setup wizard.

---

## 4. Issue Creation Screen Fields (Avoid Blocking Required Fields)

When the AWS Lambda function creates a ticket via the REST API, it sends:
- **Project**: Target Project Key (e.g. `KAN`)
- **Summary**: Investigation title with symptom
- **Description**: Rich Atlassian Document Format (ADF) context block
- **Issue Type**: e.g. `Task`, `Bug`, or `Incident`
- **Labels**: `aws-devops-agent`, `automated-investigation`

> [!IMPORTANT]
> **Check Required Fields**:  
> In **Project settings > Issue types**, ensure custom fields (such as *Affects Version*, *Component*, or *Assignee*) are **NOT** marked as **Required** on the initial creation screen. If a custom field is marked as strictly Required, Jira will reject API issue creation unless that specific field is provided.

---

## 5. Inbound Webhook Setup (Bi-Directional Incident Management)

To allow engineers to trigger autonomous AWS DevOps Agent investigations directly from Jira:

### Step 5.1: Retrieve the Webhook URL
From your CloudFormation stack outputs:
```bash
aws cloudformation describe-stacks \
  --stack-name devops-agent-jira-integration \
  --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
  --output text
```
*(Example: `https://3ra5eo6jjd5orsf4xvtwy6onbe0dvkyr.lambda-url.us-east-1.on.aws/`)*

### Step 5.2: Register the Webhook in Jira
1. In Jira, click the **Settings icon** (gear ⚙️ in the top right header).
2. Click **System**.
3. In the left sidebar, scroll down to **Advanced** and click **Webhooks**.
4. Click **+ Create a Webhook** (top right).
5. Configure the webhook settings:
   - **Name**: `AWS DevOps Agent Integration`
   - **Status**: `Enabled`
   - **URL**: Paste your `JiraWebhookUrl` from Step 5.1.
   - **Issue related events**:
     - Check **Issue**: `created`, `updated`
     - Check **Comment**: `created`
   - *(Optional JQL Filter)*: Restrict events to your project:
     ```jql
     project = "KAN"
     ```
6. Click **Save** at the bottom of the page.

---

## 6. How Engineers Use the Jira Integration

### 1. Automated Outbound Incident Creation
* When AWS DevOps Agent detects an anomaly (e.g. CloudWatch alarm, latency surge, or HTTP 5xx spike), it emits an `Investigation Created` event.
* A Jira ticket is created automatically with direct links to the AWS DevOps Agent Space.
* When investigation concludes, the full **Root Cause Analysis (RCA)**, affected AWS ARNs, and recommended remediation steps are posted as an ADF comment.

### 2. Manual Inbound Investigation Triggers
Engineers can command AWS DevOps Agent directly from Jira:
* **Slash Command**: On any Jira ticket, type a comment:
  ```text
  /investigate
  ```
  The webhook receiver catches the comment and dispatches an autonomous investigation in your AWS DevOps Agent Space.
* **Label Trigger**: Add the label `trigger-investigation` or `aws-devops-agent` to any issue.

---

## 7. Useful Jira Filters & Dashboards (JQL)

Create saved filters and dashboard gadgets to monitor autonomous AI investigations:

### Active Automated Investigations:
```jql
project = "KAN" AND labels = "aws-devops-agent" AND statusCategory != Done ORDER BY created DESC
```

### Investigations with Completed RCA:
```jql
project = "KAN" AND labels = "rca-completed" ORDER BY updated DESC
```

### Failed or Incomplete Investigations:
```jql
project = "KAN" AND labels = "investigation-failed" ORDER BY updated DESC
```

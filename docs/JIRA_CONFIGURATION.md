# Jira Cloud Configuration & Incident Management Guide

This document describes how to configure your Atlassian Jira Cloud instance to maximize incident triage and support bi-directional workflows with AWS DevOps Agent.

---

## 1. Jira Project Setup

### Recommended Issue Types
AWS DevOps Agent integration can create issues using any standard Jira issue type:
- **`Incident`** (Recommended for Jira Service Management / ITSM)
- **`Bug`** (Recommended for Software / Scrum / Kanban projects)
- **`Task`** (Standard generic task)

Ensure the project user or service account has permissions to:
- **Create Issues**
- **Add Comments**
- **Edit Issues** (Labels, Priorities)
- **Transition Issues** (Change status)

---

## 2. Recommended Labels & Components

The integration automatically attaches the following labels:
- `aws-devops-agent`
- `automated-investigation`
- `rca-completed` (added upon investigation completion)
- `aws-{region}` (e.g. `aws-us-east-1`)

You can create Jira Filters and Dashboards using JQL:

```jql
project = "OPS" AND labels = "aws-devops-agent" ORDER BY created DESC
```

To see open automated investigations:
```jql
project = "OPS" AND labels = "aws-devops-agent" AND statusCategory != Done
```

---

## 3. Configuring Inbound Jira Webhooks (Bi-directional)

To allow on-call engineers to trigger autonomous investigations directly from Jira:

1. Obtain your `JiraWebhookUrl` from CloudFormation:
   ```bash
   aws cloudformation describe-stacks \
     --stack-name devops-agent-jira-integration \
     --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
     --output text
   ```
2. In Jira Cloud:
   - Click the gear icon (**Settings**) in the top right.
   - Navigate to **System > Webhooks** (under Advanced).
   - Click **+ Create a Webhook**.
   - **Name**: `AWS DevOps Agent Bridge`
   - **Status**: Enabled
   - **URL**: Paste your `JiraWebhookUrl`.
   - **Events**:
     - Check **Issue**: `created`
     - Check **Comment**: `created`
   - Click **Save**.

### How Engineers Trigger Investigations from Jira:
- **Command trigger**: In any Jira issue comment, type:
  ```text
  /investigate
  ```
  The webhook receiver detects the slash command and triggers an automated AWS DevOps Agent investigation for the associated space.
- **Label trigger**: Create or update any issue with the label `trigger-investigation` or `aws-devops-agent`.

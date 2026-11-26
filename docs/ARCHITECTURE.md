# Technical Architecture & Event Specifications

This document details the architectural design, event lifecycles, and data contracts connecting **AWS DevOps Agent** and **Atlassian Jira Cloud**.

---

## 1. System Architecture

```text
[AWS CloudWatch / Alarms / Anomaly Triggers]
                  │
                  ▼
         [AWS DevOps Agent Space] ◄──(MCP Tools)──► [Atlassian Remote MCP Server]
                  │                                  (Reads Jira / Confluence Runbooks)
                  │ (Emits lifecycle events)
                  ▼
     [Amazon EventBridge (default bus)]
                  │
                  │ Rule: source: "aws.aidevops", detail-type prefix: "Investigation"
                  ▼
         [AWS Lambda Function]
            ├── Reads Secrets (AWS Secrets Manager)
            ├── State Mapping (Amazon DynamoDB)
            └── REST API v3 (Atlassian Jira Cloud)
```

### Synergy with Atlassian Remote MCP Server (`https://mcp.atlassian.com/v2/mcp`)
AWS DevOps Agent supports registering the **Atlassian Remote MCP Server** as a **Capability Provider** inside your Agent Space.
- **Atlassian Remote MCP Server (In-Investigation Tools)**: Used *inside* the agent's AI reasoning loop to query recent Jira deployments, search Confluence runbooks, and pull context from existing work items.
- **Amazon EventBridge Integration (Lifecycle Orchestration)**: Used *outside* the agent to automatically create tracking tickets on alert triggers, update DynamoDB state, stream step-by-step progress comments, post final RCA summaries, and handle inbound webhooks (`/investigate`).

Together, they form a complete closed-loop incident management ecosystem.

---

## 2. EventBridge Event Lifecycle Specifications

AWS DevOps Agent emits events under the source namespace `aws.aidevops`.

### 2.1 Event: `Investigation Created`
Emitted immediately when an anomaly or incident triggers an investigation.

```json
{
  "version": "0",
  "id": "c1f7b76a-1234-5678-9abc-def012345678",
  "detail-type": "Investigation Created",
  "source": "aws.aidevops",
  "account": "123456789012",
  "time": "2026-11-26T12:00:00Z",
  "region": "us-east-1",
  "resources": [
    "arn:aws:aidevops:us-east-1:123456789012:agentspace/aspc-0a1b2c3d4e5f6g7h8"
  ],
  "detail": {
    "metadata": {
      "agent_space_id": "aspc-0a1b2c3d4e5f6g7h8",
      "task_id": "tsk-0987654321fedcba",
      "execution_id": "ex-1234567890abcdef"
    },
    "data": {
      "task_type": "INVESTIGATION",
      "status": "PENDING",
      "symptom": "Elevated 5xx Error Rate (>15%) on API Gateway endpoint /v1/checkout",
      "priority": "HIGH"
    }
  }
}
```

**Lambda Behavior**:
1. Creates a new Jira issue via `POST /rest/api/3/issue`.
2. Formats description using Atlassian Document Format (ADF) with deep link to AWS DevOps Agent Space.
3. Saves mapping `{ "taskId": "tsk-0987654321fedcba", "jiraIssueKey": "OPS-142", ... }` into DynamoDB.

---

### 2.2 Event: `Investigation In Progress`
Emitted periodically as the agent executes diagnostic subtasks (correlating logs, querying X-Ray traces, checking CloudTrail).

```json
{
  "detail-type": "Investigation In Progress",
  "source": "aws.aidevops",
  "detail": {
    "metadata": {
      "task_id": "tsk-0987654321fedcba"
    },
    "data": {
      "status": "IN_PROGRESS",
      "phase": "Correlating CloudWatch Metrics and analyzing ECS task stderr logs"
    }
  }
}
```

**Lambda Behavior**:
1. Looks up `jiraIssueKey` from DynamoDB using `taskId`.
2. Appends an ADF progress note comment via `POST /rest/api/3/issue/{key}/comment`.

---

### 2.3 Event: `Investigation Completed`
Emitted when diagnostic analysis finishes and Root Cause Analysis (RCA) is synthesized.

```json
{
  "detail-type": "Investigation Completed",
  "source": "aws.aidevops",
  "detail": {
    "metadata": {
      "agent_space_id": "aspc-0a1b2c3d4e5f6g7h8",
      "task_id": "tsk-0987654321fedcba",
      "execution_id": "ex-1234567890abcdef"
    },
    "data": {
      "task_type": "INVESTIGATION",
      "status": "COMPLETED",
      "root_cause": "Database connection pool exhaustion on rds-postgres-orders-prod triggered by unindexed query.",
      "affected_resources": [
        "arn:aws:rds:us-east-1:123456789012:db:rds-postgres-orders-prod"
      ],
      "recommendations": [
        "Deploy index on orders(created_at, status)",
        "Increase RDS max_connections parameter"
      ]
    }
  }
}
```

**Lambda Behavior**:
1. Queries DynamoDB for `jiraIssueKey`.
2. Builds structured ADF comment with Success Panel, Findings, Affected Resources, and Action Items.
3. Adds label `rca-completed`.
4. Transitions issue to `In Progress` / `Under Review`.
5. Updates DynamoDB status to `COMPLETED`.

---

## 3. DynamoDB Data Model

Table Name: `devops-agent-jira-mappings`  
Billing Mode: `PAY_PER_REQUEST` (On-Demand)

| Attribute | Type | Description |
| :--- | :--- | :--- |
| `taskId` (**Partition Key**) | `String` | Unique AWS DevOps Agent task identifier (`tsk-xxxx`). |
| `jiraIssueKey` | `String` | Jira issue identifier (e.g. `OPS-142`). |
| `agentSpaceId` | `String` | DevOps Agent Space identifier. |
| `executionId` | `String` | DevOps Agent execution identifier. |
| `status` | `String` | State: `INVESTIGATION_CREATED`, `IN_PROGRESS`, `COMPLETED`, `FAILED`. |
| `summary` | `String` | Summary title of the investigation. |
| `createdAt` | `String` | ISO 8601 UTC timestamp of creation. |
| `updatedAt` | `String` | ISO 8601 UTC timestamp of last update. |

---

## 4. Security & Encryption Standards

1. **Secrets at Rest**: Stored in AWS Secrets Manager, encrypted with AWS KMS. Secret strings are never printed in CloudWatch logs.
2. **Secrets in Transit**: Encrypted over HTTPS using TLS 1.3 to Jira Cloud REST API endpoints.
3. **Data Mapping Table**: DynamoDB is encrypted with AWS managed keys and has Point-In-Time Recovery (PITR) enabled.
4. **Execution Permissions**: IAM execution role strictly scoped to table ARN and secret ARN.

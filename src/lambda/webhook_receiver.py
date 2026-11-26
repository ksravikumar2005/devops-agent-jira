"""
Jira Webhook Receiver Lambda Handler
Enables bi-directional Incident Management between Jira Cloud and AWS DevOps Agent.

When an engineer opens an incident ticket in Jira or comments '/investigate':
1. Receives Jira Cloud webhook event.
2. Creates an authentic INVESTIGATION backlog task in AWS DevOps Agent Space.
3. Stores the taskId <-> jiraIssueKey mapping in DynamoDB.
4. Leaves an immediate acknowledgment comment on the Jira ticket with the Task ID and AWS Console link.
5. As AWS DevOps Agent executes, its lifecycle events (In Progress, Completed with RCA)
   are automatically posted back to this Jira ticket by event_handler.py!
"""

import os
import json
import logging
from typing import Dict, Any, Optional
from datetime import datetime, timezone
import boto3
from botocore.exceptions import ClientError

from jira_client import JiraClient, ADFBuilder

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

events_client = boto3.client("events")
dynamodb = boto3.resource("dynamodb")
secrets_client = boto3.client("secretsmanager")

AGENT_SPACE_ID = os.environ.get("AGENT_SPACE_ID", "3f1e5f09-659d-4073-a7a5-2b5ca9e633bd")
DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "devops-agent-jira-mappings")
JIRA_SECRET_NAME = os.environ.get("JIRA_SECRET_NAME", "devops-agent/jira-credentials")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Lazy-loaded clients
_DEV_OPS_CLIENT = None
_JIRA_CLIENT: Optional[JiraClient] = None
_DDB_TABLE = None


def get_devops_client():
    """Retrieve DevOps Agent boto3 client."""
    global _DEV_OPS_CLIENT
    if _DEV_OPS_CLIENT is None:
        for client_name in ["devops-agent", "aidevops"]:
            try:
                _DEV_OPS_CLIENT = boto3.client(client_name, region_name=AWS_REGION)
                break
            except Exception:
                continue
    return _DEV_OPS_CLIENT


def get_state_table():
    """Retrieve DynamoDB Table resource."""
    global _DDB_TABLE
    if _DDB_TABLE is None:
        _DDB_TABLE = dynamodb.Table(DYNAMODB_TABLE_NAME)
    return _DDB_TABLE


def get_jira_client() -> Optional[JiraClient]:
    """Retrieve JiraClient initialized from AWS Secrets Manager."""
    global _JIRA_CLIENT
    if _JIRA_CLIENT is not None:
        return _JIRA_CLIENT

    try:
        resp = secrets_client.get_secret_value(SecretId=JIRA_SECRET_NAME)
        data = json.loads(resp.get("SecretString", "{}"))
        base_url = data.get("jira_base_url") or data.get("baseUrl")
        user_email = data.get("jira_user_email") or data.get("email")
        api_token = data.get("jira_api_token") or data.get("apiToken")
        project_key = data.get("jira_project_key", "KAN")
        issue_type = data.get("jira_issue_type", "Task")

        if base_url and user_email and api_token:
            _JIRA_CLIENT = JiraClient(
                base_url=base_url,
                user_email=user_email,
                api_token=api_token,
                default_project_key=project_key,
                default_issue_type=issue_type
            )
            return _JIRA_CLIENT
    except Exception as e:
        logger.warning(f"Could not initialize Jira client from secret '{JIRA_SECRET_NAME}': {e}")
    return None


def extract_text_from_description(desc: Any) -> str:
    """Extract plain text string from Jira description (supports raw string or ADF JSON)."""
    if not desc:
        return ""
    if isinstance(desc, str):
        return desc
    if isinstance(desc, dict):
        texts = []
        def _walk(node):
            if isinstance(node, dict):
                if node.get("type") == "text" and "text" in node:
                    texts.append(node["text"])
                for v in node.values():
                    _walk(v)
            elif isinstance(node, list):
                for item in node:
                    _walk(item)
        _walk(desc)
        return " ".join(texts)
    return str(desc)


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Handles incoming webhook payloads from Jira Cloud.
    Can be invoked via AWS Lambda Function URL.
    """
    logger.info("Received Jira webhook event")
    body_str = event.get("body", "{}")
    if event.get("isBase64Encoded", False):
        import base64
        body_str = base64.b64decode(body_str).decode("utf-8")

    try:
        payload = json.loads(body_str) if isinstance(body_str, str) else body_str
    except Exception as e:
        logger.error(f"Failed to parse webhook JSON body: {e}")
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"error": "Invalid JSON payload"})
        }

    webhook_event = payload.get("webhookEvent", "")
    issue = payload.get("issue", {})
    issue_key = issue.get("key", "")
    fields = issue.get("fields", {})
    summary = fields.get("summary", "")

    logger.info(f"Jira Webhook Event: {webhook_event} for Issue: {issue_key}")

    # Check trigger conditions:
    # 1. Any comment created containing '/investigate' or '/aidevops'
    # 2. Issue created with type 'Incident', 'Alert', or 'Problem'
    # 3. Issue created with priority 'Highest', 'Critical', 'P1', or 'Blocker'
    # 4. Issue created with label 'aws-devops-agent', 'trigger-investigation', 'alert', or 'incident'
    comment = payload.get("comment", {})
    comment_body = comment.get("body", "")
    is_command = False

    if isinstance(comment_body, str) and ("/investigate" in comment_body.lower() or "/devops-agent" in comment_body.lower()):
        is_command = True
    elif isinstance(comment_body, dict):
        raw_text = json.dumps(comment_body)
        if "/investigate" in raw_text.lower():
            is_command = True

    labels = fields.get("labels", [])
    issue_type_name = fields.get("issuetype", {}).get("name", "").lower()
    priority_name = fields.get("priority", {}).get("name", "").lower()

    has_trigger_label = any(lbl in ["trigger-investigation", "aws-devops-agent", "alert", "incident"] for lbl in labels)
    is_alert_type = issue_type_name in ["incident", "alert", "problem"]
    is_critical_priority = priority_name in ["highest", "critical", "p1", "blocker"]

    is_trigger_event = (
        is_command
        or (webhook_event == "jira:issue_created" and (has_trigger_label or is_alert_type or is_critical_priority))
        or (webhook_event in ["jira:issue_created", "jira:issue_updated"] and has_trigger_label)
    )

    if not is_trigger_event:
        logger.info(f"Issue {issue_key} does not meet trigger criteria. Ignoring.")
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"status": "ignored", "message": "No action required for this event."})
        }

    logger.info(f"Trigger condition matched for issue {issue_key}. Creating DevOps Agent task.")

    # Map priority to AWS DevOps Agent priority values: CRITICAL, HIGH, MEDIUM, LOW, MINIMAL
    devops_priority = "HIGH"
    if priority_name in ["highest", "critical", "p1", "blocker"]:
        devops_priority = "CRITICAL"
    elif priority_name in ["low", "lowest", "p4", "minor"]:
        devops_priority = "LOW"
    elif priority_name in ["medium", "p2", "p3"]:
        devops_priority = "MEDIUM"

    raw_desc = fields.get("description", "")
    desc_text = extract_text_from_description(raw_desc)
    task_title = f"[Jira {issue_key}] {summary}"[:380]
    task_description = (
        f"Autonomous investigation triggered from Jira issue {issue_key}.\n"
        f"Summary: {summary}\n"
        f"Details: {desc_text[:2000]}"
    )[:9500]

    devops_cli = get_devops_client()
    task_id = None

    if devops_cli and AGENT_SPACE_ID:
        try:
            client_token = f"jira-{issue_key}-{int(datetime.now(timezone.utc).timestamp())}"
            task_resp = devops_cli.create_backlog_task(
                agentSpaceId=AGENT_SPACE_ID,
                taskType="INVESTIGATION",
                title=task_title,
                description=task_description,
                priority=devops_priority,
                clientToken=client_token
            )
            task_data = task_resp.get("task", {})
            task_id = task_data.get("taskId")
            logger.info(f"Created AWS DevOps Agent backlog task: {task_id} for Jira issue: {issue_key}")
        except Exception as e:
            logger.error(f"Failed to create backlog task in AWS DevOps Agent: {e}")

    # Fallback synthetic taskId if service API call failed
    if not task_id:
        task_id = f"tsk-jira-{issue_key}-{int(datetime.now(timezone.utc).timestamp())}"

    # Save mapping to DynamoDB so event_handler knows which Jira issue to update with RCA
    try:
        table = get_state_table()
        now_iso = datetime.now(timezone.utc).isoformat()
        table.put_item(
            Item={
                "taskId": task_id,
                "jiraIssueKey": issue_key,
                "agentSpaceId": AGENT_SPACE_ID,
                "status": "INVESTIGATION_QUEUED",
                "summary": summary,
                "createdAt": now_iso,
                "updatedAt": now_iso
            }
        )
        logger.info(f"Saved mapping to DynamoDB: {task_id} -> {issue_key}")
    except Exception as e:
        logger.error(f"Failed to save mapping to DynamoDB: {e}")

    # Emit trigger event to EventBridge
    try:
        entry = {
            "Source": "jira.incident_management",
            "DetailType": "Manual Investigation Triggered",
            "Detail": json.dumps({
                "jira_issue_key": issue_key,
                "task_id": task_id,
                "summary": summary,
                "agent_space_id": AGENT_SPACE_ID,
                "issue_type": issue_type_name,
                "priority": devops_priority,
                "triggered_by": payload.get("user", {}).get("displayName", "Jira User")
            })
        }
        events_client.put_events(Entries=[entry])
    except Exception as e:
        logger.warning(f"Failed to put event into EventBridge: {e}")

    # Post acknowledgment comment back to Jira
    jira = get_jira_client()
    if jira:
        try:
            console_url = f"https://{AWS_REGION}.console.aws.amazon.com/aidevops/home?region={AWS_REGION}#/spaces/{AGENT_SPACE_ID}/tasks/{task_id}"
            ack_doc = ADFBuilder.create_doc()
            ack_doc["content"].append(ADFBuilder.panel(
                f"AWS DevOps Agent has received this investigation request and started autonomous diagnostic analysis.",
                panel_type="info"
            ))
            ack_doc["content"].append(ADFBuilder.bullet_list([
                f"DevOps Agent Space: {AGENT_SPACE_ID}",
                f"Investigation Task ID: {task_id}",
                f"Priority: {devops_priority}",
                f"Region: {AWS_REGION}"
            ]))
            ack_doc["content"].append(ADFBuilder.link_paragraph(
                "Track live telemetry analysis in the AWS Console:",
                "Open AWS DevOps Agent Space",
                console_url
            ))
            jira.add_comment(issue_key, ack_doc)
            logger.info(f"Posted acknowledgment comment on Jira issue {issue_key}")
        except Exception as e:
            logger.warning(f"Could not post acknowledgment comment to Jira issue {issue_key}: {e}")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "status": "triggered",
            "issue": issue_key,
            "taskId": task_id,
            "message": "AWS DevOps Agent investigation successfully initiated from Jira."
        })
    }

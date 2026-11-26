"""
Jira Webhook Receiver Lambda Handler
Enables bi-directional Incident Management between Jira Cloud and AWS DevOps Agent.

Handles:
1. Issue Created: Trigger investigation if labeled 'aws-devops-agent', or type 'Incident'/'Alert', or critical priority.
2. Issue Updated:
   - Routine field updates (assignee, description, status): Safely ignored or status synced to DynamoDB to prevent duplicate investigations.
   - Closed / Resolved: Marks investigation record in DynamoDB as RESOLVED.
   - Slash Command: If an engineer comments '/investigate', dispatches a fresh autonomous investigation.
3. Bidirectional Loop:
   - Registers taskId <-> jiraIssueKey in DynamoDB.
   - Posts immediate acknowledgment with console tracking link.
   - Event Handler Lambda updates the ticket with live progress and Root Cause Analysis (RCA).
"""

import os
import json
import logging
from typing import Dict, Any, Optional
from datetime import datetime, timezone
import hmac
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

# Lazy-loaded clients and cached secret
_DEV_OPS_CLIENT = None
_JIRA_CLIENT: Optional[JiraClient] = None
_DDB_TABLE = None
_WEBHOOK_SECRET_TOKEN: Optional[str] = None


def get_expected_webhook_token() -> Optional[str]:
    """Retrieve expected webhook secret token from environment or AWS Secrets Manager."""
    global _WEBHOOK_SECRET_TOKEN
    if _WEBHOOK_SECRET_TOKEN is not None:
        return _WEBHOOK_SECRET_TOKEN

    env_token = os.environ.get("WEBHOOK_SECRET_TOKEN")
    if env_token:
        _WEBHOOK_SECRET_TOKEN = env_token
        return _WEBHOOK_SECRET_TOKEN

    try:
        resp = secrets_client.get_secret_value(SecretId=JIRA_SECRET_NAME)
        data = json.loads(resp.get("SecretString", "{}"))
        sec = data.get("webhook_secret_token") or data.get("webhookSecret") or data.get("secret_token")
        if sec:
            _WEBHOOK_SECRET_TOKEN = str(sec).strip()
            return _WEBHOOK_SECRET_TOKEN
    except Exception as e:
        logger.warning(f"Could not load webhook secret token from secret '{JIRA_SECRET_NAME}': {e}")
    return None


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

    # --------------------------------------------------------------------------
    # 0. Enforce Shared Secret Token Authentication (Security Perimeter)
    # --------------------------------------------------------------------------
    expected_token = get_expected_webhook_token()
    if expected_token:
        # Check query string parameters (e.g. ?token=... or ?secret=...)
        query_params = event.get("queryStringParameters") or {}
        provided_token = query_params.get("token") or query_params.get("secret")

        # Also check HTTP headers (e.g. x-webhook-token, x-api-key)
        if not provided_token:
            headers = event.get("headers") or {}
            lower_headers = {k.lower(): v for k, v in headers.items()}
            provided_token = lower_headers.get("x-webhook-token") or lower_headers.get("x-api-key")

        if not provided_token or not hmac.compare_digest(str(provided_token), str(expected_token)):
            logger.warning("Rejected unauthorized webhook request: missing or invalid shared secret token.")
            return {
                "statusCode": 403,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"error": "Forbidden: Invalid or missing webhook secret token."})
            }
        logger.info("✓ Webhook shared secret token successfully authenticated.")

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
    status_obj = fields.get("status", {})
    current_status_name = status_obj.get("name", "").lower()

    logger.info(f"Jira Webhook Event: {webhook_event} for Issue: {issue_key} (Status: {current_status_name})")

    table = get_state_table()
    now_iso = datetime.now(timezone.utc).isoformat()

    # --------------------------------------------------------------------------
    # 1. Handle Issue Resolution / Closure
    # --------------------------------------------------------------------------
    if current_status_name in ["done", "resolved", "closed", "cancelled", "completed"]:
        logger.info(f"Issue {issue_key} status is '{current_status_name}'. Updating state in DynamoDB.")
        try:
            table.update_item(
                Key={"taskId": f"JIRA#{issue_key}"},
                UpdateExpression="SET #s = :s, updatedAt = :u",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "RESOLVED", ":u": now_iso}
            )
        except Exception as e:
            logger.debug(f"Reverse lookup record JIRA#{issue_key} not found or update error: {e}")

        # If it was just a status update to Done, no new investigation needed
        if webhook_event == "jira:issue_updated" and not payload.get("comment"):
            return {
                "statusCode": 200,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"status": "resolved_tracked", "issue": issue_key})
            }

    # --------------------------------------------------------------------------
    # 2. Check Trigger Conditions
    # --------------------------------------------------------------------------
    comment = payload.get("comment", {})
    comment_body = comment.get("body", "")
    is_command = False

    if isinstance(comment_body, str) and ("/investigate" in comment_body.lower() or "/devops-agent" in comment_body.lower()):
        is_command = True
    elif isinstance(comment_body, dict):
        raw_text = json.dumps(comment_body)
        if "/investigate" in raw_text.lower():
            is_command = True

    raw_labels = fields.get("labels", [])
    normalized_labels = {str(l).lower().strip().replace("_", "-") for l in raw_labels} | {str(l).lower().strip() for l in raw_labels}
    trigger_targets = {"trigger-investigation", "aws-devops-agent", "awsdevopsagent", "alert", "incident"}
    has_trigger_label = bool(normalized_labels & trigger_targets)

    issue_type_name = fields.get("issuetype", {}).get("name", "").lower()
    priority_name = fields.get("priority", {}).get("name", "").lower()
    is_alert_type = issue_type_name in ["incident", "alert", "problem"]
    is_critical_priority = priority_name in ["highest", "critical", "p1", "blocker"]

    logger.info(f"Trigger check for {issue_key}: is_command={is_command}, labels={raw_labels}, has_trigger_label={has_trigger_label}, issue_type={issue_type_name}, priority={priority_name}")

    # --------------------------------------------------------------------------
    # 3. Idempotency Check on Issue Updates
    # --------------------------------------------------------------------------
    # If the issue is simply updated (e.g. assignee changed, summary edited, or comment added)
    # and the user did NOT explicitly run /investigate:
    if webhook_event == "jira:issue_updated" and not is_command:
        try:
            existing = table.get_item(Key={"taskId": f"JIRA#{issue_key}"}).get("Item")
            if existing and existing.get("status") in ["IN_PROGRESS", "INVESTIGATION_QUEUED"]:
                active_task = existing.get("activeTaskId", "unknown")
                logger.info(f"Issue {issue_key} is already being investigated under task {active_task}. Ignoring routine update.")
                return {
                    "statusCode": 200,
                    "headers": {"Content-Type": "application/json"},
                    "body": json.dumps({
                        "status": "already_active",
                        "issue": issue_key,
                        "activeTaskId": active_task,
                        "message": "Investigation already in progress. Update ignored to prevent duplicate tasks."
                    })
                }
        except Exception as e:
            logger.warning(f"Error checking active investigation for {issue_key}: {e}")

    # Determine if investigation should be launched
    is_trigger_event = (
        is_command
        or (webhook_event == "jira:issue_created" and (has_trigger_label or is_alert_type or is_critical_priority))
        or (webhook_event == "jira:issue_updated" and has_trigger_label)
    )

    if not is_trigger_event:
        logger.info(f"Issue {issue_key} update does not require a new investigation. Ignoring.")
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"status": "ignored", "message": "No investigation triggered for this update."})
        }

    logger.info(f"Trigger condition matched for issue {issue_key}. Launching AWS DevOps Agent investigation.")

    # --------------------------------------------------------------------------
    # 4. Dispatch Backlog Task to AWS DevOps Agent
    # --------------------------------------------------------------------------
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

    # --------------------------------------------------------------------------
    # 5. Persist State to DynamoDB
    # --------------------------------------------------------------------------
    try:
        # Primary lookup: taskId -> Jira issue
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
        # Reverse lookup: JIRA#issue_key -> taskId (prevents duplicate tasks on routine updates)
        table.put_item(
            Item={
                "taskId": f"JIRA#{issue_key}",
                "activeTaskId": task_id,
                "agentSpaceId": AGENT_SPACE_ID,
                "status": "IN_PROGRESS",
                "createdAt": now_iso,
                "updatedAt": now_iso
            }
        )
        logger.info(f"Saved mappings to DynamoDB: {task_id} <-> {issue_key}")
    except Exception as e:
        logger.error(f"Failed to save mapping to DynamoDB: {e}")

    # --------------------------------------------------------------------------
    # 6. Publish Event to EventBridge
    # --------------------------------------------------------------------------
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

    # --------------------------------------------------------------------------
    # 7. Post Acknowledgment Comment on Jira Ticket
    # --------------------------------------------------------------------------
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

"""
Jira Webhook Receiver Lambda Handler
Enables bi-directional Incident Management between Jira Cloud and AWS DevOps Agent.
Receives Jira Cloud webhooks (e.g. comment created with '/investigate' or issue assigned to DevOps Agent)
and triggers an autonomous investigation in AWS DevOps Agent Space or publishes to EventBridge.
"""

import os
import json
import logging
from typing import Dict, Any

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

events_client = boto3.client("events")
agent_space_id = os.environ.get("AGENT_SPACE_ID", "")
devops_client = None

try:
    devops_client = boto3.client("devops-agent")
except Exception:
    try:
        devops_client = boto3.client("aidevops")
    except Exception:
        devops_client = None


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Handles incoming webhook payloads from Jira Cloud.
    Can be invoked via AWS Lambda Function URL or API Gateway HTTP API.
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
    # 1. Comment created containing '/investigate' or '/aidevops'
    # 2. Issue created with label 'aws-devops-agent' or 'trigger-investigation'
    comment = payload.get("comment", {})
    comment_body = comment.get("body", "")
    is_command = False

    if isinstance(comment_body, str) and ("/investigate" in comment_body.lower() or "/devops-agent" in comment_body.lower()):
        is_command = True
    elif isinstance(comment_body, dict):
        # ADF parsing for command
        raw_text = json.dumps(comment_body)
        if "/investigate" in raw_text.lower():
            is_command = True

    labels = fields.get("labels", [])
    has_trigger_label = "trigger-investigation" in labels or "aws-devops-agent" in labels

    if is_command or (webhook_event == "jira:issue_created" and has_trigger_label):
        logger.info(f"Trigger condition matched for issue {issue_key}. Dispatching investigation trigger.")

        # Emit an event to EventBridge or invoke DevOps Agent API directly
        try:
            entry = {
                "Source": "jira.incident_management",
                "DetailType": "Manual Investigation Triggered",
                "Detail": json.dumps({
                    "jira_issue_key": issue_key,
                    "summary": summary,
                    "agent_space_id": agent_space_id,
                    "triggered_by": payload.get("user", {}).get("displayName", "Jira User")
                })
            }
            events_client.put_events(Entries=[entry])
            logger.info(f"Dispatched manual investigation event for {issue_key}")

            return {
                "statusCode": 200,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "status": "triggered",
                    "issue": issue_key,
                    "message": "DevOps Agent investigation successfully queued."
                })
            }
        except Exception as e:
            logger.error(f"Failed to dispatch investigation event: {e}")
            return {
                "statusCode": 500,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"error": str(e)})
            }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"status": "ignored", "message": "No action required for this event."})
    }

"""
AWS DevOps Agent to Jira EventBridge Integration Handler
Handles lifecycle events from 'aws.aidevops' and updates Jira Cloud issues via REST API v3.
State is maintained in Amazon DynamoDB to map task_id <-> Jira issue keys.
"""

import os
import json
import logging
from datetime import datetime, timezone
from typing import Dict, Any, Optional

import boto3
from botocore.exceptions import ClientError
from jira_client import JiraClient, ADFBuilder

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())

# AWS Clients
secrets_client = boto3.client("secretsmanager")
dynamodb = boto3.resource("dynamodb")
aidevops_client = None

try:
    # Attempt to initialize DevOps Agent / AI DevOps client if supported in region
    aidevops_client = boto3.client("devops-agent")
except Exception:
    try:
        aidevops_client = boto3.client("aidevops")
    except Exception:
        aidevops_client = None

# Environment configuration
SECRET_NAME = os.environ.get("JIRA_SECRET_NAME", "devops-agent/jira-credentials")
DYNAMODB_TABLE_NAME = os.environ.get("DYNAMODB_TABLE_NAME", "devops-agent-jira-mappings")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Global caches for warm containers
_CACHED_JIRA_CLIENT = None
_CACHED_DDB_TABLE = None


def get_jira_client() -> JiraClient:
    """Retrieve Jira credentials from Secrets Manager with caching."""
    global _CACHED_JIRA_CLIENT
    if _CACHED_JIRA_CLIENT is not None:
        return _CACHED_JIRA_CLIENT

    logger.info(f"Retrieving Jira credentials from secret: {SECRET_NAME}")
    try:
        response = secrets_client.get_secret_value(SecretId=SECRET_NAME)
        secret_data = json.loads(response["SecretString"])

        base_url = secret_data.get("jira_base_url") or secret_data.get("baseUrl")
        user_email = secret_data.get("jira_user_email") or secret_data.get("email")
        api_token = secret_data.get("jira_api_token") or secret_data.get("apiToken")
        project_key = secret_data.get("jira_project_key", "OPS")
        issue_type = secret_data.get("jira_issue_type", "Incident")

        if not base_url or not user_email or not api_token:
            raise ValueError("Secret must contain 'jira_base_url', 'jira_user_email', and 'jira_api_token'.")

        _CACHED_JIRA_CLIENT = JiraClient(
            base_url=base_url,
            user_email=user_email,
            api_token=api_token,
            default_project_key=project_key,
            default_issue_type=issue_type
        )
        return _CACHED_JIRA_CLIENT
    except ClientError as e:
        logger.error(f"Failed to fetch secret '{SECRET_NAME}': {e}")
        raise


def get_state_table():
    """Retrieve DynamoDB Table resource with caching."""
    global _CACHED_DDB_TABLE
    if _CACHED_DDB_TABLE is None:
        _CACHED_DDB_TABLE = dynamodb.Table(DYNAMODB_TABLE_NAME)
    return _CACHED_DDB_TABLE


def get_mapped_issue_key(task_id: str) -> Optional[str]:
    """Look up mapped Jira issue key for a given DevOps Agent taskId."""
    table = get_state_table()
    try:
        resp = table.get_item(Key={"taskId": task_id})
        item = resp.get("Item")
        if item:
            return item.get("jiraIssueKey")
    except Exception as e:
        logger.warning(f"Error querying DynamoDB for taskId {task_id}: {e}")
    return None


def save_mapping(task_id: str, issue_key: str, agent_space_id: str, execution_id: str, status: str, summary: str):
    """Save taskId <-> Jira issueKey relationship to DynamoDB."""
    table = get_state_table()
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        table.put_item(
            Item={
                "taskId": task_id,
                "jiraIssueKey": issue_key,
                "agentSpaceId": agent_space_id,
                "executionId": execution_id,
                "status": status,
                "summary": summary,
                "createdAt": now_iso,
                "updatedAt": now_iso
            }
        )
        logger.info(f"Saved mapping: {task_id} -> {issue_key}")
    except Exception as e:
        logger.error(f"Failed to save mapping to DynamoDB: {e}")


def update_mapping_status(task_id: str, status: str):
    """Update investigation status and timestamp in DynamoDB."""
    table = get_state_table()
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        table.update_item(
            Key={"taskId": task_id},
            UpdateExpression="SET #s = :s, updatedAt = :u",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": status, ":u": now_iso}
        )
    except Exception as e:
        logger.warning(f"Failed to update mapping status in DynamoDB for {task_id}: {e}")


def build_console_url(agent_space_id: str, task_id: str, region: str = "us-east-1") -> str:
    """Generate AWS Console deep link for the DevOps Agent Space / Task."""
    return f"https://{region}.console.aws.amazon.com/aidevops/home?region={region}#/spaces/{agent_space_id}/tasks/{task_id}"


def handle_investigation_created(event: Dict[str, Any], jira: JiraClient):
    """
    Handle 'Investigation Created' event:
    1. Parse investigation identifiers and symptom context
    2. Create a new Jira Incident / Issue
    3. Persist taskId <-> Jira key in DynamoDB
    """
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})
    region = event.get("region", AWS_REGION)
    account_id = event.get("account", "Unknown")

    task_id = metadata.get("task_id") or metadata.get("taskId") or "UNKNOWN_TASK"
    agent_space_id = metadata.get("agent_space_id") or metadata.get("agentSpaceId") or "UNKNOWN_SPACE"
    execution_id = metadata.get("execution_id") or metadata.get("executionId") or "UNKNOWN_EXECUTION"

    # Extract human-readable symptom/title
    symptom = (
        data.get("symptom")
        or data.get("title")
        or data.get("description")
        or f"Autonomous Operational Investigation for Space {agent_space_id}"
    )

    summary = f"[AWS DevOps Agent] {symptom}"
    console_link = build_console_url(agent_space_id, task_id, region)

    # Build Jira ADF Description
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        "AWS DevOps Agent has autonomously detected an anomaly and initiated a diagnostic investigation.",
        panel_type="info"
    ))
    doc["content"].append(ADFBuilder.heading("Investigation Context", level=3))
    doc["content"].append(ADFBuilder.bullet_list([
        f"AWS Account ID: {account_id}",
        f"AWS Region: {region}",
        f"DevOps Agent Space: {agent_space_id}",
        f"Investigation Task ID: {task_id}",
        f"Execution ID: {execution_id}",
        f"Trigger Source: {event.get('source', 'aws.aidevops')}",
        f"Detection Time: {event.get('time', datetime.now(timezone.utc).isoformat())}"
    ]))
    doc["content"].append(ADFBuilder.heading("DevOps Agent Console Link", level=3))
    doc["content"].append(ADFBuilder.link_paragraph(
        "View real-time agent execution and diagnostics in the AWS Console:",
        "Open AWS DevOps Agent Space",
        console_link
    ))

    # Priority mapping
    priority = "High" if "critical" in symptom.lower() or "sev-1" in symptom.lower() else "Medium"

    # Create issue in Jira
    created = jira.create_issue(
        summary=summary,
        description_adf=doc,
        priority=priority,
        labels=["aws-devops-agent", "incident-management", "automated-investigation", f"aws-{region}"]
    )
    issue_key = created["key"]

    # Save to DynamoDB
    save_mapping(
        task_id=task_id,
        issue_key=issue_key,
        agent_space_id=agent_space_id,
        execution_id=execution_id,
        status="INVESTIGATION_CREATED",
        summary=summary
    )


def handle_investigation_in_progress(event: Dict[str, Any], jira: JiraClient):
    """
    Handle 'Investigation In Progress' event:
    Append an informational comment to the existing Jira issue.
    """
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})
    task_id = metadata.get("task_id") or metadata.get("taskId")

    if not task_id:
        logger.warning("No taskId found in In Progress event")
        return

    issue_key = get_mapped_issue_key(task_id)
    if not issue_key:
        logger.warning(f"No existing Jira issue mapped for taskId {task_id}. Skipping update.")
        return

    phase = data.get("phase") or data.get("current_step") or "Evidence collection and telemetry log correlation"
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        f"Investigation update: {phase}",
        panel_type="note"
    ))
    doc["content"].append(ADFBuilder.paragraph(
        f"AWS DevOps Agent is actively querying CloudWatch metrics, OpenSearch logs, and X-Ray traces to isolate root cause."
    ))

    jira.add_comment(issue_key, doc)
    update_mapping_status(task_id, "IN_PROGRESS")


def handle_investigation_completed(event: Dict[str, Any], jira: JiraClient):
    """
    Handle 'Investigation Completed' event:
    Synthesize Root Cause Analysis (RCA) and append comprehensive comment.
    """
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})
    region = event.get("region", AWS_REGION)

    task_id = metadata.get("task_id") or metadata.get("taskId")
    agent_space_id = metadata.get("agent_space_id") or metadata.get("agentSpaceId") or ""
    execution_id = metadata.get("execution_id") or metadata.get("executionId") or ""

    if not task_id:
        logger.warning("No taskId found in Completed event")
        return

    issue_key = get_mapped_issue_key(task_id)
    if not issue_key:
        logger.warning(f"No Jira issue found for completed task {task_id}.")
        return

    # Attempt to extract findings from event payload or default synthesis
    root_cause = data.get("root_cause") or data.get("findings") or data.get("summary")
    recommendations = data.get("recommendations", [])
    affected_resources = data.get("affected_resources", [])

    if not root_cause:
        root_cause = "Automated investigation concluded. Root-cause hypothesis generated from correlated CloudWatch alarms and application log telemetry."

    console_link = build_console_url(agent_space_id, task_id, region)

    # Build ADF Comment
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        "AWS DevOps Agent Investigation Concluded Successfully",
        panel_type="success"
    ))
    doc["content"].append(ADFBuilder.heading("Root Cause Analysis (RCA)", level=3))
    doc["content"].append(ADFBuilder.paragraph(str(root_cause), bold=False))

    if affected_resources:
        doc["content"].append(ADFBuilder.heading("Affected Resources", level=4))
        resource_items = [str(r) for r in affected_resources]
        doc["content"].append(ADFBuilder.bullet_list(resource_items))

    if recommendations:
        doc["content"].append(ADFBuilder.heading("Recommended Remediations", level=4))
        rec_items = [str(rec) for rec in recommendations]
        doc["content"].append(ADFBuilder.bullet_list(rec_items))

    doc["content"].append(ADFBuilder.heading("Agent Journal & Trace Artifacts", level=4))
    doc["content"].append(ADFBuilder.link_paragraph(
        "Examine full execution timeline, journal records, and telemetry traces in AWS:",
        "View Completed Investigation in AWS DevOps Agent",
        console_link
    ))

    # Add comment to Jira
    jira.add_comment(issue_key, doc)
    jira.update_issue_labels(issue_key, ["rca-completed", "aws-aidevops-analyzed"])

    # Attempt workflow transition if configured (e.g. In Progress or Review)
    jira.transition_issue(issue_key, "In Progress")

    update_mapping_status(task_id, "COMPLETED")
    logger.info(f"Appended RCA comment to Jira issue {issue_key} for task {task_id}")


def handle_investigation_failed(event: Dict[str, Any], jira: JiraClient):
    """
    Handle 'Investigation Failed' event:
    Alert engineering on-call that autonomous investigation encountered an error.
    """
    detail = event.get("detail", {})
    metadata = detail.get("metadata", {})
    data = detail.get("data", {})
    region = event.get("region", AWS_REGION)

    task_id = metadata.get("task_id") or metadata.get("taskId")
    agent_space_id = metadata.get("agent_space_id") or metadata.get("agentSpaceId") or ""
    reason = data.get("error_message") or data.get("reason") or "Investigation timed out or hit diagnostic limits."

    if not task_id:
        return

    issue_key = get_mapped_issue_key(task_id)
    if not issue_key:
        return

    console_link = build_console_url(agent_space_id, task_id, region)
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        f"Autonomous investigation failed: {reason}",
        panel_type="error"
    ))
    doc["content"].append(ADFBuilder.paragraph(
        "Manual triage is required. Please check CloudWatch logs and the DevOps Agent console."
    ))
    doc["content"].append(ADFBuilder.link_paragraph(
        "Direct link:",
        "AWS DevOps Agent Console",
        console_link
    ))

    jira.add_comment(issue_key, doc)
    jira.update_issue_labels(issue_key, ["investigation-failed"])
    update_mapping_status(task_id, "FAILED")


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    AWS Lambda entry point for Amazon EventBridge 'aws.aidevops' events.
    """
    logger.info(f"Received EventBridge event: {json.dumps(event)}")
    detail_type = event.get("detail-type", "")

    jira = get_jira_client()

    try:
        if detail_type == "Investigation Created":
            handle_investigation_created(event, jira)
        elif detail_type in ["Investigation In Progress", "Investigation Updated"]:
            handle_investigation_in_progress(event, jira)
        elif detail_type == "Investigation Completed":
            handle_investigation_completed(event, jira)
        elif detail_type in ["Investigation Failed", "Investigation Timed Out", "Investigation Cancelled"]:
            handle_investigation_failed(event, jira)
        else:
            logger.info(f"Unhandled detail-type '{detail_type}'. Checking if it matches prefix 'Investigation'...")
            if detail_type.startswith("Investigation"):
                handle_investigation_in_progress(event, jira)
            else:
                logger.info(f"Ignoring non-investigation event detail-type: {detail_type}")

        return {"statusCode": 200, "message": f"Successfully processed {detail_type}"}
    except Exception as e:
        logger.error(f"Error handling event {detail_type}: {str(e)}", exc_info=True)
        # Re-raise so EventBridge can retry or DLQ can capture if configured
        raise

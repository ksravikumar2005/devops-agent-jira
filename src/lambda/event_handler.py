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


def get_task_item(task_id: str) -> Optional[Dict[str, Any]]:
    """Look up full DynamoDB item for a given DevOps Agent taskId."""
    table = get_state_table()
    try:
        resp = table.get_item(Key={"taskId": task_id})
        return resp.get("Item")
    except Exception as e:
        logger.warning(f"Error querying DynamoDB for taskId {task_id}: {e}")
    return None


def get_mapped_issue_key(task_id: str) -> Optional[str]:
    """Look up mapped Jira issue key for a given DevOps Agent taskId."""
    item = get_task_item(task_id)
    return item.get("jiraIssueKey") if item else None


def save_mapping(task_id: str, issue_key: str, agent_space_id: str, execution_id: str, status: str, summary: str):
    """Save taskId <-> Jira issueKey relationship to DynamoDB with conditional write safety."""
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

    # Idempotency Guard: Prevent duplicate Jira issue creation if event is retried
    existing_key = get_mapped_issue_key(task_id)
    if existing_key:
        logger.info(f"Idempotency Guard: Task '{task_id}' is already mapped to Jira issue '{existing_key}'. Skipping duplicate creation.")
        return

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


def fetch_investigation_details(
    agent_space_id: str,
    task_id: str,
    execution_id: Optional[str] = None,
    region: str = "us-east-1"
) -> Dict[str, Any]:
    """
    Directly query AWS DevOps Agent API to extract the full Root Cause Analysis (RCA),
    recommendations, diagnostic findings, and journal records.
    """
    results: Dict[str, Any] = {
        "root_cause": None,
        "recommendations": [],
        "affected_resources": [],
        "findings": [],
        "execution_id": execution_id
    }

    client = None
    for c_name in ["devops-agent", "aidevops"]:
        try:
            client = boto3.client(c_name, region_name=region)
            break
        except Exception:
            continue

    if not client:
        logger.warning("Could not instantiate devops-agent boto3 client for details extraction.")
        return results

    # 1. Fetch Task Details
    try:
        task_resp = client.get_backlog_task(agentSpaceId=agent_space_id, taskId=task_id)
        task = task_resp.get("task", {})
        if not results["execution_id"]:
            results["execution_id"] = task.get("executionId")

        status_reason = task.get("statusReason")
        if status_reason and not results["root_cause"]:
            results["root_cause"] = status_reason

        # Inspect supportMetadata / metadata
        meta = task.get("metadata") or {}
        if isinstance(meta, dict):
            for k in ["rootCause", "root_cause", "findings", "summary", "conclusion"]:
                if meta.get(k):
                    results["root_cause"] = meta.get(k)
                    break
            if meta.get("recommendations") and isinstance(meta.get("recommendations"), list):
                results["recommendations"].extend(meta.get("recommendations"))
            if meta.get("affectedResources") and isinstance(meta.get("affectedResources"), list):
                results["affected_resources"].extend(meta.get("affectedResources"))
    except Exception as e:
        logger.warning(f"Error calling get_backlog_task for {task_id}: {e}")

    # 2. Fetch Recommendations
    try:
        recs_resp = client.list_recommendations(agentSpaceId=agent_space_id, taskId=task_id)
        for rec in recs_resp.get("recommendations", []):
            rec_title = rec.get("title", "")
            rec_priority = rec.get("priority", "HIGH")
            rec_content = rec.get("content", {})
            summary = rec_content.get("summary", "")
            spec = rec_content.get("spec", "")

            rec_text = f"[{rec_priority}] {rec_title}"
            if summary and summary != rec_title:
                rec_text += f" - {summary}"
            if spec:
                rec_text += f"\nRemediation Steps: {spec}"
            results["recommendations"].append(rec_text)
    except Exception as e:
        logger.warning(f"Error calling list_recommendations for {task_id}: {e}")

    # 3. Fetch Journal Records for In-depth Findings
    active_exec_id = results["execution_id"]
    if active_exec_id:
        try:
            j_resp = client.list_journal_records(
                agentSpaceId=agent_space_id,
                executionId=active_exec_id,
                order="DESC",
                maxItems=25
            )
            for r in j_resp.get("records", []):
                content = r.get("content")
                rtype = str(r.get("recordType", "")).upper()
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, dict):
                    text = (
                        content.get("summary")
                        or content.get("text")
                        or content.get("analysis")
                        or content.get("findings")
                        or content.get("message")
                        or json.dumps(content)
                    )

                if text:
                    # Look for conclusion or RCA markers
                    if any(k in rtype for k in ["CONCLUSION", "SUMMARY", "HYPOTHESIS", "ANALYSIS", "RCA", "RESULT"]):
                        if not results["root_cause"] or len(text) > len(str(results["root_cause"])):
                            results["root_cause"] = text
                    # Collect findings
                    if len(text) > 20 and not any(text in f for f in results["findings"]):
                        results["findings"].append(f"• [{rtype}] {text[:600]}")
        except Exception as e:
            logger.warning(f"Error calling list_journal_records for execution {active_exec_id}: {e}")

    return results


def handle_investigation_completed(event: Dict[str, Any], jira: JiraClient):
    """
    Handle 'Investigation Completed' event:
    1. Parse investigation identifiers and query DevOps Agent API for full RCA.
    2. Format rich Root Cause Analysis, findings, recommendations, and affected resources.
    3. Post comment to Jira, apply 'rca-completed' label, and update DynamoDB state.
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

    task_item = get_task_item(task_id)
    if not task_item:
        logger.warning(f"No DynamoDB record found for completed task {task_id}.")
        return

    issue_key = task_item.get("jiraIssueKey")
    if not issue_key:
        logger.warning(f"No Jira issue mapped for completed task {task_id}.")
        return

    # Extract findings from event payload
    root_cause = data.get("root_cause") or data.get("findings") or data.get("summary") or data.get("conclusion")
    recommendations = data.get("recommendations", [])
    affected_resources = data.get("affected_resources", [])
    findings_list = []

    # Deep Query to AWS DevOps Agent service to retrieve full RCA, Journal findings & recommendations
    if agent_space_id and task_id:
        logger.info(f"Querying AWS DevOps Agent API for full RCA on task {task_id} in space {agent_space_id}...")
        api_details = fetch_investigation_details(agent_space_id, task_id, execution_id, region)
        if api_details.get("root_cause"):
            root_cause = api_details["root_cause"]
        if api_details.get("recommendations"):
            recommendations = list(dict.fromkeys(recommendations + api_details["recommendations"]))
        if api_details.get("affected_resources"):
            affected_resources = list(dict.fromkeys(affected_resources + api_details["affected_resources"]))
        if api_details.get("findings"):
            findings_list = api_details["findings"][:5]

    if not root_cause:
        if recommendations:
            root_cause = f"Autonomous analysis complete. AWS DevOps Agent identified {len(recommendations)} recommended remediation actions."
        elif findings_list:
            root_cause = "Autonomous diagnostic investigation completed with the findings detailed below."
        else:
            root_cause = "Automated investigation concluded. Root cause analysis generated from correlated CloudWatch alarms, metrics, and application log telemetry."

    console_link = build_console_url(agent_space_id, task_id, region)

    # Build ADF Comment
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        "AWS DevOps Agent Investigation Concluded Successfully",
        panel_type="success"
    ))
    doc["content"].append(ADFBuilder.heading("Root Cause Analysis (RCA)", level=3))
    doc["content"].append(ADFBuilder.paragraph(str(root_cause), bold=False))

    if recommendations:
        doc["content"].append(ADFBuilder.heading("Actionable Recommendations & Remediations", level=4))
        rec_items = [str(rec) for rec in recommendations]
        doc["content"].append(ADFBuilder.bullet_list(rec_items))

    if findings_list:
        doc["content"].append(ADFBuilder.heading("Diagnostic Evidence & Journal Highlights", level=4))
        doc["content"].append(ADFBuilder.bullet_list(findings_list))

    if affected_resources:
        doc["content"].append(ADFBuilder.heading("Affected AWS Resources", level=4))
        resource_items = [str(r) for r in affected_resources]
        doc["content"].append(ADFBuilder.bullet_list(resource_items))

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
    logger.info(f"Appended detailed RCA comment to Jira issue {issue_key} for task {task_id}")


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

    task_item = get_task_item(task_id)
    if not task_item:
        return

    issue_key = task_item.get("jiraIssueKey")
    if not issue_key:
        return

    # Idempotency Guard: Avoid duplicate failure notifications if event is re-delivered
    if task_item.get("status") == "FAILED":
        logger.info(f"Idempotency Guard: Task '{task_id}' has already been processed as FAILED on '{issue_key}'. Skipping duplicate comment.")
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

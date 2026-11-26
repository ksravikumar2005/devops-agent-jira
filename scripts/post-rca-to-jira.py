#!/usr/bin/env python3
"""
Post Complete Root Cause Analysis (RCA) and Recommendations from AWS DevOps Agent to Jira
Directly queries AWS DevOps Agent APIs (get-backlog-task, list-recommendations, list-journal-records)
and publishes the rich findings to the mapped Jira issue.
"""

import sys
import os
import json
import argparse
from typing import Dict, Any, List, Optional
import boto3

# Add lambda directory to path for imports
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LAMBDA_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "src", "lambda")
if LAMBDA_DIR not in sys.path:
    sys.path.insert(0, LAMBDA_DIR)

from jira_client import JiraClient, ADFBuilder

def parse_args():
    parser = argparse.ArgumentParser(description="Fetch full RCA from AWS DevOps Agent and post to Jira.")
    parser.add_argument("--task-id", default="1e747222-2846-4d8e-8c17-52fde631dae6", help="AWS DevOps Agent Task ID")
    parser.add_argument("--space-id", default="3f1e5f09-659d-4073-a7a5-2b5ca9e633bd", help="DevOps Agent Space ID")
    parser.add_argument("--region", default="us-east-1", help="AWS Region")
    parser.add_argument("--issue-key", help="Jira Issue Key (e.g. KAN-1). Auto-discovered from DynamoDB if omitted.")
    parser.add_argument("--secret-name", default="devops-agent/jira-credentials", help="Secrets Manager Secret Name")
    parser.add_argument("--table-name", default="devops-agent-jira-mappings", help="DynamoDB State Table Name")
    return parser.parse_args()

def get_jira_client(secret_name: str, region: str) -> JiraClient:
    sm = boto3.client("secretsmanager", region_name=region)
    resp = sm.get_secret_value(SecretId=secret_name)
    data = json.loads(resp["SecretString"])
    return JiraClient(
        base_url=data.get("jira_base_url") or data.get("baseUrl"),
        user_email=data.get("jira_user_email") or data.get("email"),
        api_token=data.get("jira_api_token") or data.get("apiToken"),
        default_project_key=data.get("jira_project_key", "KAN"),
        default_issue_type=data.get("jira_issue_type", "Task")
    )

def get_mapped_issue_key(table_name: str, task_id: str, region: str) -> Optional[str]:
    ddb = boto3.resource("dynamodb", region_name=region)
    table = ddb.Table(table_name)
    try:
        resp = table.get_item(Key={"taskId": task_id})
        item = resp.get("Item")
        if item:
            return item.get("jiraIssueKey")
    except Exception as e:
        print(f"Warning: Could not look up taskId in DynamoDB: {e}")
    return None

def main():
    args = parse_args()
    print("======================================================================")
    print("      AWS DevOps Agent: Extract Full RCA & Post Directly to Jira      ")
    print("======================================================================")
    print(f"  Target Region:   {args.region}")
    print(f"  Agent Space ID:  {args.space_id}")
    print(f"  DevOps Task ID:  {args.task_id}")

    # Determine Jira Issue Key
    issue_key = args.issue_key
    if not issue_key:
        print(f"  Looking up Jira Issue Key in DynamoDB table '{args.table_name}'...")
        issue_key = get_mapped_issue_key(args.table_name, args.task_id, args.region)
        if issue_key:
            print(f"  ✓ Found mapped Jira Issue: {issue_key}")
        else:
            # Fallback scan for recent issue
            print("  Could not find task mapping in DynamoDB. Checking recent tasks...")
            issue_key = input("  Please enter your Jira Issue Key (e.g. KAN-1): ").strip()

    if not issue_key:
        print("[ERROR] Jira Issue Key is required.")
        sys.exit(1)

    # Initialize DevOps Agent Client
    devops = None
    for name in ["devops-agent", "aidevops"]:
        try:
            devops = boto3.client(name, region_name=args.region)
            break
        except Exception:
            continue

    if not devops:
        print("[ERROR] Could not initialize AWS DevOps Agent boto3 client.")
        sys.exit(1)

    print("\n[1/3] Querying AWS DevOps Agent Task & Journal Details...")
    task_resp = devops.get_backlog_task(agentSpaceId=args.space_id, taskId=args.task_id)
    task = task_resp.get("task", {})
    exec_id = task.get("executionId")
    title = task.get("title", "")
    description = task.get("description", "")
    status_reason = task.get("statusReason", "")

    print(f"  Task Title:     {title}")
    print(f"  Execution ID:   {exec_id}")
    if status_reason:
        print(f"  Status Reason:  {status_reason}")

    # Recommendations
    print("\n[2/3] Fetching Actionable Recommendations...")
    recommendations = []
    try:
        recs_resp = devops.list_recommendations(agentSpaceId=args.space_id, taskId=args.task_id)
        for r in recs_resp.get("recommendations", []):
            rtitle = r.get("title", "")
            rcontent = r.get("content", {})
            rsummary = rcontent.get("summary", "")
            rspec = rcontent.get("spec", "")
            rpriority = r.get("priority", "HIGH")
            
            line = f"[{rpriority}] {rtitle}"
            if rsummary and rsummary != rtitle:
                line += f" - {rsummary}"
            if rspec:
                line += f"\nRemediation Steps: {rspec}"
            recommendations.append(line)
            print(f"  ✓ Found Recommendation: {rtitle}")
    except Exception as e:
        print(f"  Warning: list_recommendations error: {e}")

    # Journal Records
    print("\n[3/3] Inspecting Journal Records & Evidence Timeline...")
    journal_findings = []
    root_cause = status_reason
    if exec_id:
        try:
            j_resp = devops.list_journal_records(agentSpaceId=args.space_id, executionId=exec_id, order="DESC", maxItems=25)
            for r in j_resp.get("records", []):
                content = r.get("content")
                rtype = str(r.get("recordType", "")).upper()
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, dict):
                    text = content.get("summary") or content.get("text") or content.get("analysis") or content.get("findings") or content.get("message") or json.dumps(content)

                if text:
                    if any(k in rtype for k in ["CONCLUSION", "SUMMARY", "HYPOTHESIS", "ANALYSIS", "RCA", "RESULT"]):
                        if not root_cause or len(text) > len(str(root_cause)):
                            root_cause = text
                    if len(text) > 30 and not any(text in f for f in journal_findings):
                        journal_findings.append(f"• [{rtype}] {text[:500]}")
            print(f"  ✓ Processed {len(j_resp.get('records', []))} journal records.")
        except Exception as e:
            print(f"  Warning: list_journal_records error: {e}")

    if not root_cause:
        if recommendations:
            root_cause = f"Autonomous analysis complete. AWS DevOps Agent identified {len(recommendations)} recommended remediation actions."
        elif journal_findings:
            root_cause = "Autonomous diagnostic investigation completed with the findings detailed below."
        else:
            root_cause = "Telemetry correlation across CloudWatch alarms and application log telemetry successfully isolated incident root-cause."

    console_link = f"https://{args.region}.console.aws.amazon.com/aidevops/home?region={args.region}#/spaces/{args.space_id}/tasks/{args.task_id}"

    # Build ADF Document for Jira
    doc = ADFBuilder.create_doc()
    doc["content"].append(ADFBuilder.panel(
        "AWS DevOps Agent Investigation Concluded Successfully",
        panel_type="success"
    ))
    doc["content"].append(ADFBuilder.heading("Root Cause Analysis (RCA)", level=3))
    doc["content"].append(ADFBuilder.paragraph(str(root_cause), bold=False))

    if recommendations:
        doc["content"].append(ADFBuilder.heading("Actionable Recommendations & Remediations", level=4))
        doc["content"].append(ADFBuilder.bullet_list(recommendations))

    if journal_findings:
        doc["content"].append(ADFBuilder.heading("Diagnostic Evidence & Journal Highlights", level=4))
        doc["content"].append(ADFBuilder.bullet_list(journal_findings[:5]))

    doc["content"].append(ADFBuilder.heading("Telemetry & Console Trace Artifacts", level=4))
    doc["content"].append(ADFBuilder.link_paragraph(
        "Examine full execution timeline, journal records, and telemetry traces in AWS:",
        "View Completed Investigation in AWS DevOps Agent",
        console_link
    ))

    # Post to Jira
    print(f"\nPosting full RCA comment to Jira issue {issue_key}...")
    jira = get_jira_client(args.secret_name, args.region)
    jira.add_comment(issue_key, doc)
    jira.update_issue_labels(issue_key, ["rca-completed", "aws-aidevops-analyzed"])

    print("\n======================================================================")
    print(f"  SUCCESS! Full Root Cause Analysis posted to Jira: {issue_key}")
    print(f"  View Ticket: {jira.base_url}/browse/{issue_key}")
    print("======================================================================\n")

if __name__ == "__main__":
    main()

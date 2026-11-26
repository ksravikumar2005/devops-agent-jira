#!/usr/bin/env python3
"""
Create a Jira Issue using Jira Cloud REST API v3
Supports reading credentials from AWS Secrets Manager or environment variables.
"""

import sys
import os
import json
import urllib.request
import urllib.error
import base64

REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
SECRET_NAME = os.environ.get("JIRA_SECRET_NAME", "devops-agent/jira-credentials")

def get_credentials():
    # 1. Environment variables
    base_url = os.environ.get("JIRA_URL")
    email = os.environ.get("JIRA_EMAIL")
    token = os.environ.get("JIRA_TOKEN")
    project = os.environ.get("JIRA_PROJECT", "KAN")
    issue_type = os.environ.get("JIRA_ISSUE_TYPE", "Task")

    # 2. Try Secrets Manager if any credential is missing
    if not (base_url and email and token):
        try:
            import boto3
            sm = boto3.client("secretsmanager", region_name=REGION)
            val = sm.get_secret_value(SecretId=SECRET_NAME)
            data = json.loads(val["SecretString"])
            base_url = base_url or data.get("jira_base_url") or data.get("baseUrl")
            email = email or data.get("jira_user_email") or data.get("email")
            token = token or data.get("jira_api_token") or data.get("apiToken")
            project = project or data.get("jira_project_key", "KAN")
            issue_type = issue_type or data.get("jira_issue_type", "Task")
        except Exception as e:
            pass

    # Defaults
    base_url = (base_url or "https://aws-devops-agent.atlassian.net").rstrip("/")
    email = email or "ksravikumar2005@gmail.com"
    project = project or "KAN"
    issue_type = issue_type or "Task"

    return base_url, email, token, project, issue_type

def main():
    base_url, email, token, project, issue_type = get_credentials()

    if not token:
        print("[ERROR] Jira API token not found in environment or AWS Secrets Manager.")
        print("Please export JIRA_TOKEN='your_token'")
        sys.exit(1)

    summary = sys.argv[1] if len(sys.argv) > 1 else "High Latency Anomaly on Order Checkout Microservice"
    description = sys.argv[2] if len(sys.argv) > 2 else "CloudWatch metrics detect p99 latency spiking above 4200ms on ALB target group. ECS memory utilization elevated."

    auth_str = base64.b64encode(f"{email}:{token}".encode("utf-8")).decode("utf-8")
    headers = {
        "Authorization": f"Basic {auth_str}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }

    payload = {
        "fields": {
            "project": {"key": project},
            "summary": summary,
            "description": {
                "type": "doc",
                "version": 1,
                "content": [
                    {
                        "type": "paragraph",
                        "content": [
                            {"type": "text", "text": description}
                        ]
                    }
                ]
            },
            "issuetype": {"name": issue_type},
            "labels": ["aws-devops-agent", "incident-management", "alert"]
        }
    }

    url = f"{base_url}/rest/api/3/issue"
    req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")

    print(f"Creating Jira ticket in {base_url} (Project: {project}, Type: {issue_type})...")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            key = data.get("key")
            print("\n========================================================")
            print(f"SUCCESS! Jira Issue Created: {key}")
            print(f"Direct Link: {base_url}/browse/{key}")
            print(f"Labels:      aws-devops-agent, incident-management, alert")
            print("========================================================\n")
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8")
        print(f"\n[ERROR] HTTP {e.code}: {err}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()

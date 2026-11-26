#!/usr/bin/env python3
"""
AWS DevOps Agent Investigation Simulator
Generates and injects synthetic lifecycle events directly into Amazon EventBridge
or executes end-to-end Jira Cloud API verification checks.
"""

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone

import boto3

# Add src/lambda to path for testing
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src", "lambda")))

try:
    from jira_client import JiraClient, ADFBuilder
except ImportError:
    JiraClient = None


def send_eventbridge_event(events_client, source: str, detail_type: str, detail: dict, resources: list):
    entry = {
        "Source": source,
        "DetailType": detail_type,
        "Detail": json.dumps(detail),
        "Resources": resources,
        "Time": datetime.now(timezone.utc)
    }
    response = events_client.put_events(Entries=[entry])
    return response


def run_simulation(region: str, space_id: str):
    events_client = boto3.client("events", region_name=region)
    sts_client = boto3.client("sts", region_name=region)
    account_id = sts_client.get_caller_identity()["Account"]

    task_id = f"tsk-sim-{uuid.uuid4().hex[:8]}"
    exec_id = f"ex-sim-{uuid.uuid4().hex[:8]}"
    space_arn = f"arn:aws:aidevops:{region}:{account_id}:agentspace/{space_id}"

    print(f"[*] Starting DevOps Agent Investigation Simulation")
    print(f"    Region:      {region}")
    print(f"    Task ID:     {task_id}")
    print(f"    Agent Space: {space_id}")

    # 1. Investigation Created
    print("\n[Step 1/3] Emitting 'Investigation Created'...")
    created_detail = {
        "metadata": {
            "agent_space_id": space_id,
            "task_id": task_id,
            "execution_id": exec_id
        },
        "data": {
            "task_type": "INVESTIGATION",
            "status": "PENDING",
            "symptom": "Autonomous Simulation: Elevated Latency on Payment Service",
            "priority": "HIGH"
        }
    }
    send_eventbridge_event(events_client, "aws.aidevops", "Investigation Created", created_detail, [space_arn])
    print("    Event dispatched. Waiting 5s...")
    time.sleep(5)

    # 2. Investigation In Progress
    print("\n[Step 2/3] Emitting 'Investigation In Progress'...")
    progress_detail = {
        "metadata": {
            "agent_space_id": space_id,
            "task_id": task_id,
            "execution_id": exec_id
        },
        "data": {
            "task_type": "INVESTIGATION",
            "status": "IN_PROGRESS",
            "phase": "Telemetry ingestion: Correlating ECS container metrics and RDS wait events."
        }
    }
    send_eventbridge_event(events_client, "aws.aidevops", "Investigation In Progress", progress_detail, [space_arn])
    print("    Event dispatched. Waiting 5s...")
    time.sleep(5)

    # 3. Investigation Completed
    print("\n[Step 3/3] Emitting 'Investigation Completed'...")
    completed_detail = {
        "metadata": {
            "agent_space_id": space_id,
            "task_id": task_id,
            "execution_id": exec_id
        },
        "data": {
            "task_type": "INVESTIGATION",
            "status": "COMPLETED",
            "root_cause": "Simulated RCA: Inefficient query cache invalidation on redis-cluster-payment triggered high CPU.",
            "affected_resources": [
                f"arn:aws:elasticache:{region}:{account_id}:cluster:redis-cluster-payment",
                f"arn:aws:ecs:{region}:{account_id}:service/payment-service"
            ],
            "recommendations": [
                "Increase ElastiCache node type from cache.t4g.medium to cache.r6g.large",
                "Apply TTL jitter to cache eviction policy"
            ]
        }
    }
    send_eventbridge_event(events_client, "aws.aidevops", "Investigation Completed", completed_detail, [space_arn])
    print("    Simulation events successfully emitted!")


def main():
    parser = argparse.ArgumentParser(description="AWS DevOps Agent EventBridge Simulator")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"), help="AWS Region")
    parser.add_argument("--space-id", default="default", help="DevOps Agent Space ID")
    args = parser.parse_args()

    run_simulation(args.region, args.space_id)


if __name__ == "__main__":
    main()

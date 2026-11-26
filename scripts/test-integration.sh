#!/usr/bin/env bash
# ==============================================================================
# Test Script: Publish Sample AWS DevOps Agent Events to Amazon EventBridge
# ==============================================================================

set -eo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== AWS DevOps Agent EventBridge Integration Tester ==="
echo "Target AWS Region: ${REGION}"

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
echo "AWS Account: ${ACCOUNT_ID}"

TASK_ID="tsk-synthetic-$(date +%s)"
EXEC_ID="ex-synthetic-$(date +%s)"
SPACE_ID="aspc-default-demo"

# Support --direct flag to test Lambda directly without EventBridge
DIRECT_MODE=false
if [[ "$*" == *"--direct"* ]]; then
    DIRECT_MODE=true
    echo "Running in DIRECT Lambda invocation mode."
fi

echo -e "\n[1/3] Emitting 'Investigation Created'..."
CREATED_DETAIL=$(jq -n \
  --arg task "$TASK_ID" \
  --arg exec "$EXEC_ID" \
  --arg space "$SPACE_ID" \
  '{
    metadata: {
      agent_space_id: $space,
      task_id: $task,
      execution_id: $exec
    },
    data: {
      task_type: "INVESTIGATION",
      status: "PENDING",
      symptom: "Test Alert: Elevated Error Rate on Checkout Microservice",
      priority: "HIGH"
    }
  }')

if [ "$DIRECT_MODE" = true ]; then
    EVENT_PAYLOAD=$(jq -n \
      --arg task "$TASK_ID" \
      --arg exec "$EXEC_ID" \
      --arg space "$SPACE_ID" \
      --arg region "$REGION" \
      --arg acct "$ACCOUNT_ID" \
      --argjson detail "$CREATED_DETAIL" \
      '{
        version: "0",
        id: "direct-test-1",
        "detail-type": "Investigation Created",
        source: "custom.aidevops",
        account: $acct,
        time: (now | todateiso8601),
        region: $region,
        resources: [("arn:aws:aidevops:" + $region + ":" + $acct + ":agentspace/" + $space)],
        detail: $detail
      }')
    aws lambda invoke \
      --function-name "devops-agent-jira-integration-EventHandler" \
      --payload "$(echo "$EVENT_PAYLOAD" | base64)" \
      --region "$REGION" /tmp/lambda-out-1.json > /dev/null
    cat /tmp/lambda-out-1.json && echo ""
    rm -f /tmp/lambda-out-1.json
else
    ENTRY_FILE="/tmp/test-eb-$$.json"
    cat << EOF > "$ENTRY_FILE"
[
  {
    "Source": "custom.aidevops",
    "DetailType": "Investigation Created",
    "Detail": $(echo "$CREATED_DETAIL" | jq -c . | jq -R .),
    "Resources": ["arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${SPACE_ID}"]
  }
]
EOF

    aws events put-events --entries "file://${ENTRY_FILE}" --region "$REGION"
    rm -f "$ENTRY_FILE"
fi

echo "Sent Investigation Created event for Task: ${TASK_ID}"
echo "Waiting 6 seconds for Jira issue creation..."
sleep 6

echo -e "\n[2/3] Emitting 'Investigation In Progress'..."
PROGRESS_DETAIL=$(jq -n \
  --arg task "$TASK_ID" \
  --arg exec "$EXEC_ID" \
  --arg space "$SPACE_ID" \
  '{
    metadata: {
      agent_space_id: $space,
      task_id: $task,
      execution_id: $exec
    },
    data: {
      task_type: "INVESTIGATION",
      status: "IN_PROGRESS",
      phase: "Correlating CloudWatch Metrics and analyzing ECS task stderr logs"
    }
  }')

if [ "$DIRECT_MODE" = true ]; then
    EVENT_PAYLOAD_2=$(jq -n \
      --arg task "$TASK_ID" \
      --arg exec "$EXEC_ID" \
      --arg space "$SPACE_ID" \
      --arg region "$REGION" \
      --arg acct "$ACCOUNT_ID" \
      --argjson detail "$PROGRESS_DETAIL" \
      '{
        version: "0",
        id: "direct-test-2",
        "detail-type": "Investigation In Progress",
        source: "custom.aidevops",
        account: $acct,
        time: (now | todateiso8601),
        region: $region,
        detail: $detail
      }')
    aws lambda invoke \
      --function-name "devops-agent-jira-integration-EventHandler" \
      --payload "$(echo "$EVENT_PAYLOAD_2" | base64)" \
      --region "$REGION" /tmp/lambda-out-2.json > /dev/null
    rm -f /tmp/lambda-out-2.json
else
    PROG_ENTRY="/tmp/test-prog-$$.json"
    cat << EOF > "$PROG_ENTRY"
[
  {
    "Source": "custom.aidevops",
    "DetailType": "Investigation In Progress",
    "Detail": $(echo "$PROGRESS_DETAIL" | jq -c . | jq -R .),
    "Resources": ["arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${SPACE_ID}"]
  }
]
EOF

    aws events put-events --entries "file://${PROG_ENTRY}" --region "$REGION"
    rm -f "$PROG_ENTRY"
fi

echo "Sent Investigation In Progress event."
sleep 4

echo -e "\n[3/3] Emitting 'Investigation Completed' with Root Cause Analysis (RCA)..."
COMPLETED_DETAIL=$(jq -n \
  --arg task "$TASK_ID" \
  --arg exec "$EXEC_ID" \
  --arg space "$SPACE_ID" \
  '{
    metadata: {
      agent_space_id: $space,
      task_id: $task,
      execution_id: $exec
    },
    data: {
      task_type: "INVESTIGATION",
      status: "COMPLETED",
      root_cause: "High memory utilization on RDS instance rds-orders-db caused by runaway query without index on customer_id.",
      affected_resources: [
        "arn:aws:rds:us-east-1:123456789012:db:rds-orders-db",
        "arn:aws:ecs:us-east-1:123456789012:service/orders-cluster/orders-api"
      ],
      recommendations: [
        "Add index on orders(customer_id)",
        "Enable RDS Performance Insights"
      ]
    }
  }')

if [ "$DIRECT_MODE" = true ]; then
    EVENT_PAYLOAD_3=$(jq -n \
      --arg task "$TASK_ID" \
      --arg exec "$EXEC_ID" \
      --arg space "$SPACE_ID" \
      --arg region "$REGION" \
      --arg acct "$ACCOUNT_ID" \
      --argjson detail "$COMPLETED_DETAIL" \
      '{
        version: "0",
        id: "direct-test-3",
        "detail-type": "Investigation Completed",
        source: "custom.aidevops",
        account: $acct,
        time: (now | todateiso8601),
        region: $region,
        detail: $detail
      }')
    aws lambda invoke \
      --function-name "devops-agent-jira-integration-EventHandler" \
      --payload "$(echo "$EVENT_PAYLOAD_3" | base64)" \
      --region "$REGION" /tmp/lambda-out-3.json > /dev/null
    rm -f /tmp/lambda-out-3.json
else
    COMP_ENTRY="/tmp/test-comp-$$.json"
    cat << EOF > "$COMP_ENTRY"
[
  {
    "Source": "custom.aidevops",
    "DetailType": "Investigation Completed",
    "Detail": $(echo "$COMPLETED_DETAIL" | jq -c . | jq -R .),
    "Resources": ["arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${SPACE_ID}"]
  }
]
EOF

    aws events put-events --entries "file://${COMP_ENTRY}" --region "$REGION"
    rm -f "$COMP_ENTRY"
fi

echo "Sent Investigation Completed event."
echo "Waiting 5 seconds for final RCA comment publishing..."
sleep 5

# Query DynamoDB for the created issue
echo -e "\nFetching created Jira Issue details from DynamoDB..."
MAPPED_KEY=$(aws dynamodb get-item \
  --table-name "devops-agent-jira-mappings" \
  --key "{\"taskId\": {\"S\": \"${TASK_ID}\"}}" \
  --region "$REGION" \
  --query "Item.jiraIssueKey.S" \
  --output text 2>/dev/null || echo "")

# Read secret to extract Jira base URL
JIRA_URL=$(aws secretsmanager get-secret-value \
  --secret-id "devops-agent/jira-credentials" \
  --region "$REGION" \
  --query "SecretString" \
  --output text 2>/dev/null | jq -r '.jira_base_url // empty' 2>/dev/null || echo "")

if [ -n "$MAPPED_KEY" ] && [ "$MAPPED_KEY" != "None" ]; then
    echo -e "\n========================================================"
    echo -e "SUCCESS! Jira ticket created and RCA posted:"
    echo -e "  Task ID:   ${TASK_ID}"
    echo -e "  Issue Key: ${MAPPED_KEY}"
    if [ -n "$JIRA_URL" ]; then
        echo -e "  Direct URL: ${JIRA_URL}/browse/${MAPPED_KEY}"
    fi
    echo -e "========================================================"
else
    echo -e "\nCould not find mapped issue key in DynamoDB. Recent logs:"
    aws logs tail "/aws/lambda/devops-agent-jira-integration-EventHandler" --region "$REGION" --since 5m --format short 2>/dev/null || true
fi

echo -e "\n=== Test sequence finished ==="

#!/usr/bin/env bash
# ==============================================================================
# Trigger a REAL Investigation in AWS DevOps Agent Space
# ==============================================================================
# This script creates an actual backlog task of type INVESTIGATION inside your
# AWS DevOps Agent Space using the official AWS CLI (aws devops-agent).
#
# When created, AWS DevOps Agent autonomously investigates and emits authentic
# 'aws.aidevops' -> 'Investigation Created' EventBridge events.
#
# Our EventBridge rule catches this real event, invokes the Lambda handler,
# and creates a real Jira ticket in project 'KAN'!
# ==============================================================================

set -eo pipefail

# Text styling
BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
YELLOW="\033[33m"
NC="\033[0m"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Discover or fallback Agent Space ID
SPACE_ID="${AGENT_SPACE_ID:-}"
if [ -z "$SPACE_ID" ]; then
    SPACE_ID=$(aws devops-agent list-agent-spaces --region "$REGION" --query "agentSpaces[0].agentSpaceId" --output text 2>/dev/null || echo "")
fi
if [ -z "$SPACE_ID" ] || [ "$SPACE_ID" = "None" ]; then
    SPACE_ID="3f1e5f09-659d-4073-a7a5-2b5ca9e633bd"
fi

TITLE="${1:-Investigate High Latency Anomaly and 5xx Spike on Checkout Service}"
DESCRIPTION="${2:-Autonomous incident investigation to analyze correlated CloudWatch metrics, OpenSearch logs, and X-Ray traces across the checkout microservice fleet.}"

echo -e "${CYAN}======================================================================${NC}"
echo -e "${BOLD}       AWS DevOps Agent: Trigger Real Autonomous Investigation       ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "  Target AWS Region:   ${BOLD}${REGION}${NC}"
echo -e "  DevOps Agent Space:  ${BOLD}${SPACE_ID}${NC}"
echo -e "  Investigation Title: ${BOLD}${TITLE}${NC}\n"

# Verify CLI command exists
if ! command -v aws &>/dev/null; then
    echo -e "${RED}[ERROR] AWS CLI is not installed or not in PATH.${NC}"
    exit 1
fi

echo -e "  Submitting backlog task to AWS DevOps Agent (${BOLD}aws devops-agent create-backlog-task${NC})..."
CLIENT_TOKEN="token-$(date +%s)-$RANDOM"

TASK_OUTPUT=$(aws devops-agent create-backlog-task \
    --agent-space-id "$SPACE_ID" \
    --task-type "INVESTIGATION" \
    --title "$TITLE" \
    --description "$DESCRIPTION" \
    --priority "HIGH" \
    --client-token "$CLIENT_TOKEN" \
    --region "$REGION" \
    --output json 2>&1)

TASK_ID=$(echo "$TASK_OUTPUT" | jq -r '.taskId // .task.taskId // empty' 2>/dev/null || echo "")

if [ -n "$TASK_ID" ]; then
    echo -e "\n  ${GREEN}✓ Real DevOps Agent Investigation Task Created!${NC}"
    echo -e "  DevOps Task ID: ${BOLD}${TASK_ID}${NC}"
    echo -e "\n  ${CYAN}What is happening right now in AWS:${NC}"
    echo -e "  1. AWS DevOps Agent has autonomously started analyzing your AWS infrastructure."
    echo -e "  2. The AWS service emitted an authentic ${BOLD}'aws.aidevops'${NC} -> ${BOLD}'Investigation Created'${NC} event."
    echo -e "  3. EventBridge rule caught the event and routed it to your Lambda function."
    echo -e "  4. Lambda is creating a real Jira ticket on your board right now!"

    echo -e "\n  Polling DynamoDB table 'devops-agent-jira-mappings' for the mapped Jira issue..."
    
    MAPPED_KEY=""
    for i in {1..8}; do
        echo -n "  Waiting for Jira creation (attempt $i/8)... "
        sleep 4
        MAPPED_KEY=$(aws dynamodb get-item \
            --table-name "devops-agent-jira-mappings" \
            --key "{\"taskId\": {\"S\": \"${TASK_ID}\"}}" \
            --region "$REGION" \
            --query "Item.jiraIssueKey.S" \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$MAPPED_KEY" ] && [ "$MAPPED_KEY" != "None" ]; then
            echo -e "${GREEN}Found!${NC}"
            break
        fi
        echo "pending..."
    done

    JIRA_URL=$(aws secretsmanager get-secret-value \
        --secret-id "devops-agent/jira-credentials" \
        --region "$REGION" \
        --query "SecretString" \
        --output text 2>/dev/null | jq -r '.jira_base_url // empty' 2>/dev/null || echo "")

    if [ -n "$MAPPED_KEY" ] && [ "$MAPPED_KEY" != "None" ]; then
        echo -e "\n${GREEN}======================================================================${NC}"
        echo -e "${GREEN}${BOLD} SUCCESS! Live Jira ticket created from Real AWS DevOps Agent Event!${NC}"
        echo -e "${GREEN}======================================================================${NC}"
        echo -e "  DevOps Task ID:    ${BOLD}${TASK_ID}${NC}"
        echo -e "  Jira Issue Key:    ${BOLD}${MAPPED_KEY}${NC}"
        if [ -n "$JIRA_URL" ]; then
            echo -e "  Live Ticket URL:   ${BLUE}${BOLD}${JIRA_URL}/browse/${MAPPED_KEY}${NC}"
        fi
        echo -e "======================================================================\n"
    else
        echo -e "\n  ${YELLOW}[NOTE] DynamoDB record not populated yet. Check Lambda execution logs:${NC}"
        echo -e "  ${BOLD}aws logs tail \"/aws/lambda/devops-agent-jira-integration-EventHandler\" --since 5m --region ${REGION}${NC}\n"
    fi
else
    echo -e "\n  ${RED}[ERROR] Failed to create backlog task in AWS DevOps Agent:${NC}"
    echo "$TASK_OUTPUT"
    echo -e "\n  Check that your Agent Space ID '${SPACE_ID}' exists in region '${REGION}'."
    echo -e "  Run 'aws devops-agent list-agent-spaces --region ${REGION}' to view available spaces.\n"
    exit 1
fi

#!/usr/bin/env bash
# ==============================================================================
# AWS DevOps Agent to Jira Cloud Integration - Interactive CloudShell Setup
# ==============================================================================
# This interactive bash script configures the bi-directional integration
# between AWS DevOps Agent investigation events and Atlassian Jira Cloud.
# 
# Works natively in AWS CloudShell without external package dependencies.
# ==============================================================================

set -eo pipefail

# Text styling
BOLD="\033[1m"
GREEN="\033[32m"
BLUE="\033[34m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
NC="\033[0m" # No Color

# Defaults
STACK_NAME="devops-agent-jira-integration"
SECRET_NAME="devops-agent/jira-credentials"
TABLE_NAME="devops-agent-jira-mappings"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${CYAN}"
cat << "EOF"
  ___  _ _ _  ___             ___              _         _ _          
 / _ \/ | | |/   \_____ _____/ _ \___  ___ ___| |_      | (_)___ _ _  
/ /_\ \ | | / /\ / _ \ V / _ \ | |/ -_)/ -_) -_)  _|     | | / _/ '_ \ 
/_/   \_\__//_/ /_/\___/\_/ \___/_|\___|\___|\___|\__|   _/ |_\__/_.__/ 
                                                        |__/          
   AWS DevOps Agent <---> Atlassian Jira Cloud Incident Integration
EOF
echo -e "${NC}"

echo -e "${BOLD}Welcome to the AWS DevOps Agent to Jira Integration Setup!${NC}"
echo -e "This wizard will configure EventBridge routing, DynamoDB state mapping, and"
echo -e "secure Jira Cloud API synchronization from inside AWS CloudShell.\n"

# ------------------------------------------------------------------------------
# 1. Environment & Prerequisite Checks
# ------------------------------------------------------------------------------
echo -e "${BLUE}==> [1/6] Validating CloudShell Environment & AWS Permissions...${NC}"

if ! command -v aws &> /dev/null; then
    echo -e "${RED}[ERROR] AWS CLI is not installed or not in PATH.${NC}"
    exit 1
fi

if ! command -v zip &> /dev/null; then
    echo -e "${YELLOW}[!] 'zip' utility not found. Attempting to install...${NC}"
    sudo yum install -y zip || sudo apt-get install -y zip || true
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}[!] 'jq' utility not found. Attempting to install...${NC}"
    sudo yum install -y jq || sudo apt-get install -y jq || true
fi

# Detect AWS Account & Region
CURRENT_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "")
if [ -z "$CURRENT_ACCOUNT_ID" ]; then
    echo -e "${RED}[ERROR] Unable to authenticate with AWS STS. Check your CloudShell session credentials.${NC}"
    exit 1
fi

DETECTED_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}}"
echo -e "  Authenticated AWS Account: ${GREEN}${CURRENT_ACCOUNT_ID}${NC}"
echo -e "  Current AWS Region:        ${GREEN}${DETECTED_REGION}${NC}\n"

# Prompt for Region confirmation
read -rp "Enter target AWS Region [${DETECTED_REGION}]: " USER_REGION
TARGET_REGION="${USER_REGION:-$DETECTED_REGION}"
export AWS_DEFAULT_REGION="$TARGET_REGION"
export AWS_REGION="$TARGET_REGION"

# ------------------------------------------------------------------------------
# 2. DevOps Agent Space Discovery
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [2/6] Discovering AWS DevOps Agent Space...${NC}"
DISCOVERED_SPACE=""
if aws aidevops list-agent-spaces --region "$TARGET_REGION" &>/dev/null; then
    SPACES_JSON=$(aws aidevops list-agent-spaces --region "$TARGET_REGION" --output json 2>/dev/null || echo "{}")
    DISCOVERED_SPACE=$(echo "$SPACES_JSON" | jq -r '.agentSpaces[0].agentSpaceId // empty' 2>/dev/null || echo "")
fi

if [ -n "$DISCOVERED_SPACE" ]; then
    echo -e "  Found active DevOps Agent Space: ${GREEN}${DISCOVERED_SPACE}${NC}"
    read -rp "Use this Agent Space ID? [Y/n]: " CONFIRM_SPACE
    if [[ "$CONFIRM_SPACE" =~ ^[Nn] ]]; then
        read -rp "Enter your AWS DevOps Agent Space ID: " AGENT_SPACE_ID
    else
        AGENT_SPACE_ID="$DISCOVERED_SPACE"
    fi
else
    echo -e "  ${YELLOW}No DevOps Agent Space auto-detected via CLI.${NC}"
    read -rp "Enter your AWS DevOps Agent Space ID (or press Enter for 'default'): " INPUT_SPACE
    AGENT_SPACE_ID="${INPUT_SPACE:-default}"
fi

# ------------------------------------------------------------------------------
# 3. Jira Cloud Admin Credentials & Pre-Flight Validation
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [3/6] Configuring Atlassian Jira Cloud Connection...${NC}"
echo -e "${YELLOW}Note: You will need a Jira Cloud API token from:${NC}"
echo -e "👉 ${CYAN}https://id.atlassian.com/manage-profile/security/api-tokens${NC}\n"

JIRA_VALID=false
while [ "$JIRA_VALID" = false ]; do
    read -rp "Jira Base URL (e.g. https://myorg.atlassian.net): " JIRA_URL
    JIRA_URL=$(echo "$JIRA_URL" | sed 's:/*$::') # Remove trailing slash

    read -rp "Jira Admin / User Email: " JIRA_EMAIL

    # Prompt password securely
    prompt="Jira API Token: "
    JIRA_TOKEN=""
    while IFS= read -p "$prompt" -r -s -n 1 char; do
        if [[ $char == $'\0' ]]; then
            break
        elif [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
            if [ -n "$JIRA_TOKEN" ]; then
                prompt=$'\b \b'
                JIRA_TOKEN="${JIRA_TOKEN%?}"
            else
                prompt=''
            fi
        else
            prompt='*'
            JIRA_TOKEN+="$char"
        fi
    done
    echo ""

    read -rp "Jira Project Key (e.g. OPS, INC, DEVOPS) [OPS]: " INPUT_PROJECT
    JIRA_PROJECT="${INPUT_PROJECT:-OPS}"

    read -rp "Jira Issue Type (e.g. Incident, Bug, Task) [Incident]: " INPUT_ITYPE
    JIRA_ISSUE_TYPE="${INPUT_ITYPE:-Incident}"

    echo -e "\n  ${CYAN}Testing Jira Cloud API connection...${NC}"
    AUTH_HEADER="Basic $(echo -n "${JIRA_EMAIL}:${JIRA_TOKEN}" | base64)"
    
    HTTP_RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: ${AUTH_HEADER}" -H "Accept: application/json" "${JIRA_URL}/rest/api/3/myself" || echo "000")
    HTTP_CODE=$(echo "$HTTP_RESP" | tail -n1)
    HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

    if [ "$HTTP_CODE" -eq 200 ]; then
        DISPLAY_NAME=$(echo "$HTTP_BODY" | jq -r '.displayName // .name // "User"' 2>/dev/null || echo "User")
        echo -e "  ${GREEN}✓ Successfully authenticated as Jira user: ${BOLD}${DISPLAY_NAME}${NC}"

        # Verify Project exists
        PROJ_RESP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: ${AUTH_HEADER}" "${JIRA_URL}/rest/api/3/project/${JIRA_PROJECT}")
        if [ "$PROJ_RESP" -eq 200 ]; then
            echo -e "  ${GREEN}✓ Project '${JIRA_PROJECT}' exists and is accessible.${NC}"
            JIRA_VALID=true
        else
            echo -e "  ${YELLOW}[WARNING] Connected to Jira, but Project '${JIRA_PROJECT}' returned HTTP ${PROJ_RESP}.${NC}"
            read -rp "Continue with project '${JIRA_PROJECT}' anyway? [y/N]: " FORCE_PROJ
            if [[ "$FORCE_PROJ" =~ ^[Yy] ]]; then
                JIRA_VALID=true
            fi
        fi
    else
        echo -e "  ${RED}[FAILED] Authentication failed with HTTP status ${HTTP_CODE}.${NC}"
        echo -e "  Response: ${HTTP_BODY}"
        read -rp "Would you like to re-enter your credentials? [Y/n]: " RETRY
        if [[ "$RETRY" =~ ^[Nn] ]]; then
            echo -e "${RED}Aborting setup.${NC}"
            exit 1
        fi
    fi
done

# ------------------------------------------------------------------------------
# 4. Provision Secrets Manager Secret
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [4/6] Storing Jira Credentials in AWS Secrets Manager...${NC}"

SECRET_PAYLOAD=$(jq -n \
  --arg url "$JIRA_URL" \
  --arg email "$JIRA_EMAIL" \
  --arg token "$JIRA_TOKEN" \
  --arg proj "$JIRA_PROJECT" \
  --arg itype "$JIRA_ISSUE_TYPE" \
  '{
    jira_base_url: $url,
    jira_user_email: $email,
    jira_api_token: $token,
    jira_project_key: $proj,
    jira_issue_type: $itype
  }')

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$TARGET_REGION" &>/dev/null; then
    echo -e "  Secret '${SECRET_NAME}' already exists. Updating secret value..."
    aws secretsmanager put-secret-value \
        --secret-id "$SECRET_NAME" \
        --secret-string "$SECRET_PAYLOAD" \
        --region "$TARGET_REGION" > /dev/null
    echo -e "  ${GREEN}✓ Secret updated successfully.${NC}"
else
    echo -e "  Creating new secret '${SECRET_NAME}'..."
    aws secretsmanager create-secret \
        --name "$SECRET_NAME" \
        --description "Jira Cloud credentials for AWS DevOps Agent EventBridge Integration" \
        --secret-string "$SECRET_PAYLOAD" \
        --region "$TARGET_REGION" > /dev/null
    echo -e "  ${GREEN}✓ Secret created successfully.${NC}"
fi

# ------------------------------------------------------------------------------
# 5. Build Lambda Package & Deploy CloudFormation Stack
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [5/6] Deploying CloudFormation Stack & Serverless Infrastructure...${NC}"

TEMP_ZIP="/tmp/devops-agent-jira-package-$$.zip"
echo -e "  Packaging Lambda functions into ${TEMP_ZIP}..."

cd "${SCRIPT_DIR}/src/lambda"
zip -q -r "$TEMP_ZIP" ./*.py
cd "$SCRIPT_DIR"

echo -e "  Deploying CloudFormation stack: ${BOLD}${STACK_NAME}${NC} in ${TARGET_REGION}..."

aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/template.yaml" \
    --stack-name "$STACK_NAME" \
    --parameter-overrides \
        SecretName="$SECRET_NAME" \
        DynamoDBTableName="$TABLE_NAME" \
        AgentSpaceId="$AGENT_SPACE_ID" \
        LogLevel="INFO" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$TARGET_REGION"

echo -e "  ${GREEN}✓ CloudFormation resources provisioned.${NC}"

# Upload packaged Lambda code
LAMBDA_FUNCTION_NAME="${STACK_NAME}-EventHandler"
WEBHOOK_FUNCTION_NAME="${STACK_NAME}-WebhookReceiver"

echo -e "  Updating Lambda code for ${LAMBDA_FUNCTION_NAME}..."
aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file "fileb://${TEMP_ZIP}" \
    --region "$TARGET_REGION" > /dev/null

echo -e "  Updating Lambda code for ${WEBHOOK_FUNCTION_NAME}..."
aws lambda update-function-code \
    --function-name "$WEBHOOK_FUNCTION_NAME" \
    --zip-file "fileb://${TEMP_ZIP}" \
    --region "$TARGET_REGION" > /dev/null

rm -f "$TEMP_ZIP"
echo -e "  ${GREEN}✓ Lambda functions updated and active.${NC}"

# Fetch stack outputs
WEBHOOK_URL=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$TARGET_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='JiraWebhookUrl'].OutputValue" \
    --output text 2>/dev/null || echo "")

# ------------------------------------------------------------------------------
# 6. Verification & End-to-End Synthetic Test
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [6/6] End-to-End Integration Verification${NC}"
read -rp "Would you like to run an automated synthetic investigation test? [Y/n]: " RUN_TEST

if [[ ! "$RUN_TEST" =~ ^[Nn] ]]; then
    echo -e "\n  ${CYAN}Triggering simulated 'Investigation Created' event...${NC}"
    TEST_TASK_ID="tsk-test-$(date +%s)"
    TEST_EXEC_ID="ex-test-$(date +%s)"

    TEST_EVENT_JSON=$(jq -n \
      --arg task "$TEST_TASK_ID" \
      --arg space "$AGENT_SPACE_ID" \
      --arg exec "$TEST_EXEC_ID" \
      --arg region "$TARGET_REGION" \
      --arg acct "$CURRENT_ACCOUNT_ID" \
      '{
        version: "0",
        id: "test-event-uuid",
        "detail-type": "Investigation Created",
        source: "aws.aidevops",
        account: $acct,
        time: (now | todateiso8601),
        region: $region,
        resources: [("arn:aws:aidevops:" + $region + ":" + $acct + ":agentspace/" + $space)],
        detail: {
          metadata: {
            agent_space_id: $space,
            task_id: $task,
            execution_id: $exec
          },
          data: {
            task_type: "INVESTIGATION",
            status: "PENDING",
            symptom: "Synthetic Test: Spikeline Latency Anomaly on OrderProcessingService",
            priority: "HIGH"
          }
        }
      }')

    aws events put-events \
        --entries "[{\"Source\": \"aws.aidevops\", \"DetailType\": \"Investigation Created\", \"Detail\": $(echo "$TEST_EVENT_JSON" | jq -c '.detail' | jq -R .), \"Resources\": [\"arn:aws:aidevops:${TARGET_REGION}:${CURRENT_ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}\"]}]" \
        --region "$TARGET_REGION" > /dev/null

    echo -e "  Event emitted to EventBridge. Waiting 6 seconds for Lambda execution..."
    sleep 6

    # Query DynamoDB for created issue
    MAPPED_ISSUE=$(aws dynamodb get-item \
        --table-name "$TABLE_NAME" \
        --key "{\"taskId\": {\"S\": \"$TEST_TASK_ID\"}}" \
        --region "$TARGET_REGION" \
        --query "Item.jiraIssueKey.S" \
        --output text 2>/dev/null || echo "")

    if [ -n "$MAPPED_ISSUE" ] && [ "$MAPPED_ISSUE" != "None" ]; then
        echo -e "  ${GREEN}✓ SUCCESS! Real Jira issue created: ${BOLD}${MAPPED_ISSUE}${NC}"
        echo -e "  Direct Link: ${CYAN}${JIRA_URL}/browse/${MAPPED_ISSUE}${NC}\n"

        # Now send Investigation Completed event to append RCA
        echo -e "  ${CYAN}Triggering simulated 'Investigation Completed' with Root Cause Analysis (RCA)...${NC}"
        COMPLETED_DETAIL=$(jq -n \
          --arg task "$TEST_TASK_ID" \
          --arg space "$AGENT_SPACE_ID" \
          --arg exec "$TEST_EXEC_ID" \
          '{
            metadata: {
              agent_space_id: $space,
              task_id: $task,
              execution_id: $exec
            },
            data: {
              status: "COMPLETED",
              root_cause: "Thread starvation in database connection pool caused by unindexed query scanning table 'orders'. Correlated CPU spike on rds-mysql-prod.",
              affected_resources: [
                "arn:aws:rds:us-east-1:123456789012:db:orders-cluster-primary",
                "arn:aws:ecs:us-east-1:123456789012:service/checkout-api"
              ],
              recommendations: [
                "Apply composite index (customer_id, created_at) on table 'orders'",
                "Scale connection pool maximum from 50 to 120 connections",
                "Enable RDS Performance Insights slow query logger"
              ]
            }
          }')

        aws events put-events \
            --entries "[{\"Source\": \"aws.aidevops\", \"DetailType\": \"Investigation Completed\", \"Detail\": $(echo "$COMPLETED_DETAIL" | jq -c . | jq -R .), \"Resources\": [\"arn:aws:aidevops:${TARGET_REGION}:${CURRENT_ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}\"]}]" \
            --region "$TARGET_REGION" > /dev/null

        sleep 5
        echo -e "  ${GREEN}✓ RCA comment and findings successfully published to ${MAPPED_ISSUE}!${NC}"
    else
        echo -e "  ${YELLOW}[NOTE] Could not immediately confirm issue key in DynamoDB. Check CloudWatch logs:${NC}"
        echo -e "  /aws/lambda/${LAMBDA_FUNCTION_NAME}"
    fi
fi

# ------------------------------------------------------------------------------
# Summary & Next Steps
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}       DEPLOYMENT COMPLETE! AWS DEVOPS AGENT + JIRA IS ACTIVE                ${NC}"
echo -e "${GREEN}==============================================================================${NC}"
echo -e "  AWS Region:             ${BOLD}${TARGET_REGION}${NC}"
echo -e "  Secrets Manager Secret: ${BOLD}${SECRET_NAME}${NC}"
echo -e "  DynamoDB State Table:   ${BOLD}${TABLE_NAME}${NC}"
echo -e "  EventBridge Rule:       ${BOLD}${STACK_NAME}-InvestigationRule${NC}"
echo -e "  Lambda Event Handler:   ${BOLD}${LAMBDA_FUNCTION_NAME}${NC}"
echo -e "  Jira Project:           ${BOLD}${JIRA_PROJECT} (${JIRA_URL})${NC}"

if [ -n "$WEBHOOK_URL" ] && [ "$WEBHOOK_URL" != "None" ]; then
    echo -e "\n${CYAN}--- Bi-directional Jira Webhook Endpoint ---${NC}"
    echo -e "  Jira Webhook URL:       ${BOLD}${WEBHOOK_URL}${NC}"
    echo -e "  To trigger investigations directly from Jira:"
    echo -e "  1. In Jira, navigate to Settings > System > Webhooks."
    echo -e "  2. Register this URL and listen for 'Issue Created' or 'Comment Created'."
    echo -e "  3. Commenting '/investigate' on any ticket will trigger autonomous AWS analysis!"
fi

echo -e "\n${BOLD}Thank you for deploying AWS DevOps Agent to Jira integration!${NC}\n"

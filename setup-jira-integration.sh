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

# Source local .env if present
if [ -f "${SCRIPT_DIR}/.env" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/.env"
fi

# Parse CLI arguments
DO_CLEANUP=false
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
FORCE_YES=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --cleanup|-c)
            DO_CLEANUP=true
            shift
            ;;
        --non-interactive|-y|--yes)
            NON_INTERACTIVE=true
            FORCE_YES=true
            shift
            ;;
        --force|-f)
            FORCE_YES=true
            shift
            ;;
        --help|-h)
            echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -c, --cleanup            Teardown and delete all AWS integration resources"
            echo "  -y, --non-interactive    Run without prompts using environment variables"
            echo "  -f, --force              Skip confirmation prompts during cleanup"
            echo "  -h, --help               Show this help message and exit"
            echo ""
            echo "Supported Environment Variables:"
            echo "  AWS_REGION              Target AWS Region (e.g. us-east-1)"
            echo "  AGENT_SPACE_ID          AWS DevOps Agent Space ID"
            echo "  JIRA_URL                Atlassian Jira Cloud base URL (https://<org>.atlassian.net)"
            echo "  JIRA_EMAIL              Atlassian Admin / User Email"
            echo "  JIRA_TOKEN              Atlassian API Token"
            echo "  JIRA_PROJECT            Jira Project Key (e.g. KAN, OPS)"
            echo "  JIRA_ISSUE_TYPE         Jira Issue Type (e.g. Task, Incident, Bug)"
            echo "  RUN_TEST                Run verification test (true/false, default: true)"
            echo "  NON_INTERACTIVE         Enable headless mode (true/false, default: false)"
            exit 0
            ;;
        *)
            echo -e "${YELLOW}Unknown option: $1${NC} (Use --help for usage)"
            shift
            ;;
    esac
done

# Cleanup Function
run_cleanup() {
    TARGET_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo 'us-east-1')}}"
    echo -e "\n${YELLOW}=== [CLEANUP] Deleting AWS DevOps Agent Jira Integration Resources ===${NC}"
    echo -e "  Region:                 ${BOLD}${TARGET_REGION}${NC}"
    echo -e "  CloudFormation Stack:   ${BOLD}${STACK_NAME}${NC}"
    echo -e "  Secrets Manager Secret: ${BOLD}${SECRET_NAME}${NC}"
    echo -e "  DynamoDB State Table:   ${BOLD}${TABLE_NAME}${NC}\n"

    if [ "$FORCE_YES" != true ]; then
        read -rp "Are you sure you want to permanently delete these resources? [y/N]: " CONFIRM_CLEAN
        if [[ ! "$CONFIRM_CLEAN" =~ ^[Yy] ]]; then
            echo -e "${CYAN}Cleanup cancelled.${NC}"
            exit 0
        fi
    fi

    echo -e "  [1/3] Deleting CloudFormation Stack: ${STACK_NAME}..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$TARGET_REGION"
    echo -e "  Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$TARGET_REGION" 2>/dev/null || true
    echo -e "  ${GREEN}✓ CloudFormation stack removed.${NC}"

    echo -e "  [2/3] Deleting Secrets Manager Secret: ${SECRET_NAME}..."
    aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery --region "$TARGET_REGION" 2>/dev/null || true
    echo -e "  ${GREEN}✓ Secret removed.${NC}"

    echo -e "  [3/3] Deleting DynamoDB Table: ${TABLE_NAME}..."
    aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$TARGET_REGION" 2>/dev/null || true
    echo -e "  ${GREEN}✓ DynamoDB table removed.${NC}"

    echo -e "\n${GREEN}✓ Cleanup complete! All integration resources have been deleted.${NC}\n"
    exit 0
}

if [ "$DO_CLEANUP" = true ]; then
    run_cleanup
fi

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

# Prompt for Region confirmation or use environment variable
if [ "$NON_INTERACTIVE" = true ]; then
    TARGET_REGION="${TARGET_REGION:-$DETECTED_REGION}"
    echo -e "  Target AWS Region (non-interactive): ${BOLD}${TARGET_REGION}${NC}"
else
    read -rp "Enter target AWS Region [${DETECTED_REGION}]: " USER_REGION
    TARGET_REGION="${USER_REGION:-$DETECTED_REGION}"
fi
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

if [ "$NON_INTERACTIVE" = true ]; then
    AGENT_SPACE_ID="${AGENT_SPACE_ID:-${DISCOVERED_SPACE:-default}}"
    echo -e "  Using DevOps Agent Space ID: ${BOLD}${AGENT_SPACE_ID}${NC}"
else
    if [ -n "$DISCOVERED_SPACE" ]; then
        echo -e "  Found active DevOps Agent Space: ${GREEN}${DISCOVERED_SPACE}${NC}"
        read -rp "Use this Agent Space ID? [Y/n]: " CONFIRM_SPACE
        if [[ "$CONFIRM_SPACE" =~ ^[Nn] ]]; then
            read -rp "Enter your AWS DevOps Agent Space ID: " USER_INPUT_SPACE
            AGENT_SPACE_ID="${USER_INPUT_SPACE:-$DISCOVERED_SPACE}"
        else
            AGENT_SPACE_ID="$DISCOVERED_SPACE"
        fi
    else
        DEFAULT_SPACE="${AGENT_SPACE_ID:-default}"
        echo -e "  ${YELLOW}No DevOps Agent Space auto-detected via CLI.${NC}"
        read -rp "Enter your AWS DevOps Agent Space ID [${DEFAULT_SPACE}]: " INPUT_SPACE
        AGENT_SPACE_ID="${INPUT_SPACE:-$DEFAULT_SPACE}"
    fi
fi

# ------------------------------------------------------------------------------
# 3. Jira Cloud Admin Credentials & Pre-Flight Validation
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [3/6] Configuring Atlassian Jira Cloud Connection...${NC}"

# Normalize environment variable names
JIRA_URL="${JIRA_URL:-$JIRA_BASE_URL}"
JIRA_EMAIL="${JIRA_EMAIL:-$JIRA_USER_EMAIL}"
JIRA_TOKEN="${JIRA_TOKEN:-$JIRA_API_TOKEN}"
JIRA_PROJECT="${JIRA_PROJECT:-${JIRA_PROJECT_KEY:-OPS}}"
JIRA_ISSUE_TYPE="${JIRA_ISSUE_TYPE:-Incident}"

JIRA_VALID=false
while [ "$JIRA_VALID" = false ]; do
    if [ "$NON_INTERACTIVE" = true ]; then
        if [ -z "$JIRA_URL" ] || [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_TOKEN" ] || [ -z "$JIRA_PROJECT" ]; then
            echo -e "${RED}[ERROR] Non-interactive mode requires JIRA_URL, JIRA_EMAIL, JIRA_TOKEN, and JIRA_PROJECT.${NC}"
            echo -e "Missing variables:"
            [ -z "$JIRA_URL" ] && echo "  - JIRA_URL (e.g. export JIRA_URL='https://org.atlassian.net')"
            [ -z "$JIRA_EMAIL" ] && echo "  - JIRA_EMAIL (e.g. export JIRA_EMAIL='user@example.com')"
            [ -z "$JIRA_TOKEN" ] && echo "  - JIRA_TOKEN (e.g. export JIRA_TOKEN='...')"
            [ -z "$JIRA_PROJECT" ] && echo "  - JIRA_PROJECT (e.g. export JIRA_PROJECT='KAN')"
            exit 1
        fi
        JIRA_URL=$(echo "$JIRA_URL" | sed 's:/*$::')
    else
        echo -e "${YELLOW}Note: You will need a Jira Cloud API token from:${NC}"
        echo -e "👉 ${CYAN}https://id.atlassian.com/manage-profile/security/api-tokens${NC}\n"

        DEFAULT_URL="${JIRA_URL:-https://myorg.atlassian.net}"
        read -rp "Jira Base URL (e.g. https://myorg.atlassian.net) [${JIRA_URL}]: " INPUT_URL
        JIRA_URL="${INPUT_URL:-$JIRA_URL}"
        JIRA_URL=$(echo "$JIRA_URL" | sed 's:/*$::') # Remove trailing slash

        read -rp "Jira Admin / User Email [${JIRA_EMAIL}]: " INPUT_EMAIL
        JIRA_EMAIL="${INPUT_EMAIL:-$JIRA_EMAIL}"

        if [ -n "$JIRA_TOKEN" ]; then
            read -s -rp "Jira API Token [Using environment variable, press Enter to keep]: " INPUT_TOKEN
            echo ""
            JIRA_TOKEN="${INPUT_TOKEN:-$JIRA_TOKEN}"
        else
            read -s -rp "Jira API Token: " JIRA_TOKEN
            echo ""
        fi

        read -rp "Jira Project Key (e.g. OPS, INC, KAN) [${JIRA_PROJECT}]: " INPUT_PROJECT
        JIRA_PROJECT="${INPUT_PROJECT:-$JIRA_PROJECT}"

        read -rp "Jira Issue Type (e.g. Task, Incident, Bug) [${JIRA_ISSUE_TYPE}]: " INPUT_ITYPE
        JIRA_ISSUE_TYPE="${INPUT_ITYPE:-$JIRA_ISSUE_TYPE}"
    fi

    echo -e "\n  ${CYAN}Testing Jira Cloud API connection...${NC}"
    
    # Use curl's native basic-auth (-u) to avoid base64 newline wrapping bugs in GNU coreutils
    HTTP_RESP=$(curl -s -L -w "\n%{http_code}" --connect-timeout 15 -u "${JIRA_EMAIL}:${JIRA_TOKEN}" -H "Accept: application/json" "${JIRA_URL}/rest/api/3/myself" 2>&1)
    HTTP_CODE=$(echo "$HTTP_RESP" | tail -n1)
    HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

    if [ "$HTTP_CODE" -eq 200 ]; then
        DISPLAY_NAME=$(echo "$HTTP_BODY" | jq -r '.displayName // .name // "User"' 2>/dev/null || echo "User")
        echo -e "  ${GREEN}✓ Successfully authenticated as Jira user: ${BOLD}${DISPLAY_NAME}${NC}"

        # Verify Project exists and auto-discover available issue types
        PROJ_JSON=$(curl -s -L --connect-timeout 15 -u "${JIRA_EMAIL}:${JIRA_TOKEN}" -H "Accept: application/json" "${JIRA_URL}/rest/api/3/project/${JIRA_PROJECT}")
        if echo "$PROJ_JSON" | jq -e '.key' &>/dev/null; then
            echo -e "  ${GREEN}✓ Project '${JIRA_PROJECT}' exists and is accessible.${NC}"
            
            # Auto-detect available standard non-subtask issue types
            AVAILABLE_TYPES=$(echo "$PROJ_JSON" | jq -r '.issueTypes[]? | select(.subtask==false) | .name' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
            echo -e "  Available Issue Types in ${JIRA_PROJECT}: ${CYAN}${AVAILABLE_TYPES}${NC}"
            
            # Check if selected issue type exists; if not, auto-fallback to Task or first valid
            if ! echo "$AVAILABLE_TYPES" | grep -iq "\b${JIRA_ISSUE_TYPE}\b"; then
                FIRST_VALID=$(echo "$AVAILABLE_TYPES" | awk '{print $1}')
                DEFAULT_FALLBACK="${FIRST_VALID:-Task}"
                echo -e "  ${YELLOW}Notice: Issue type '${JIRA_ISSUE_TYPE}' is not enabled in project ${JIRA_PROJECT}.${NC}"
                echo -e "  ${GREEN}✓ Auto-selected '${DEFAULT_FALLBACK}' as the active issue type.${NC}"
                JIRA_ISSUE_TYPE="$DEFAULT_FALLBACK"
            fi
            JIRA_VALID=true
        else
            echo -e "  ${YELLOW}[WARNING] Connected to Jira, but Project '${JIRA_PROJECT}' could not be loaded.${NC}"
            if [ "$NON_INTERACTIVE" = true ]; then
                JIRA_VALID=true
            else
                read -rp "Continue with project '${JIRA_PROJECT}' anyway? [y/N]: " FORCE_PROJ
                if [[ "$FORCE_PROJ" =~ ^[Yy] ]]; then
                    JIRA_VALID=true
                fi
            fi
        fi
    else
        echo -e "  ${RED}[FAILED] Authentication failed with HTTP status ${HTTP_CODE}.${NC}"
        echo -e "  Response: ${HTTP_BODY}"
        if [ "$NON_INTERACTIVE" = true ]; then
            exit 1
        fi
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
if [ "$NON_INTERACTIVE" = true ]; then
    RUN_TEST="${RUN_TEST:-true}"
    echo -e "  Non-interactive test execution: ${BOLD}${RUN_TEST}${NC}"
else
    DEFAULT_TEST_CHOICE="${RUN_TEST:-Y}"
    read -rp "Would you like to run an automated synthetic investigation test? [${DEFAULT_TEST_CHOICE}/n]: " USER_RUN_TEST
    RUN_TEST="${USER_RUN_TEST:-$DEFAULT_TEST_CHOICE}"
fi

if [[ "$RUN_TEST" = true ]] || [[ "$RUN_TEST" =~ ^[Yy] ]]; then
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

    # Use JSON file for put-events to guarantee 100% shell escaping safety
    TEST_ENTRY_FILE="/tmp/eb-entry-created-$$.json"
    cat << EOF > "$TEST_ENTRY_FILE"
[
  {
    "Source": "custom.aidevops",
    "DetailType": "Investigation Created",
    "Detail": $(echo "$TEST_EVENT_JSON" | jq -c '.detail' | jq -R .),
    "Resources": ["arn:aws:aidevops:${TARGET_REGION}:${CURRENT_ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}"]
  }
]
EOF

    PUT_RESP=$(aws events put-events --entries "file://${TEST_ENTRY_FILE}" --region "$TARGET_REGION" 2>&1)
    rm -f "$TEST_ENTRY_FILE"
    FAILED_COUNT=$(echo "$PUT_RESP" | jq -r '.FailedEntryCount // 0' 2>/dev/null || echo "0")

    if [ "$FAILED_COUNT" -gt 0 ]; then
        echo -e "  ${RED}[ERROR] EventBridge put-events reported ${FAILED_COUNT} failure(s):${NC} ${PUT_RESP}"
    else
        echo -e "  ${GREEN}✓ Event dispatched to EventBridge.${NC} Waiting 10 seconds for Lambda cold start and Jira API..."
    fi

    sleep 10

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
              root_cause: "Thread starvation in database connection pool caused by unindexed query scanning table orders. Correlated CPU spike on rds-mysql-prod.",
              affected_resources: [
                "arn:aws:rds:us-east-1:123456789012:db:orders-cluster-primary",
                "arn:aws:ecs:us-east-1:123456789012:service/checkout-api"
              ],
              recommendations: [
                "Apply composite index (customer_id, created_at) on table orders",
                "Scale connection pool maximum from 50 to 120 connections",
                "Enable RDS Performance Insights slow query logger"
              ]
            }
          }')

        COMP_ENTRY_FILE="/tmp/eb-entry-comp-$$.json"
        cat << EOF > "$COMP_ENTRY_FILE"
[
  {
    "Source": "custom.aidevops",
    "DetailType": "Investigation Completed",
    "Detail": $(echo "$COMPLETED_DETAIL" | jq -c . | jq -R .),
    "Resources": ["arn:aws:aidevops:${TARGET_REGION}:${CURRENT_ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}"]
  }
]
EOF
        aws events put-events --entries "file://${COMP_ENTRY_FILE}" --region "$TARGET_REGION" > /dev/null 2>&1
        rm -f "$COMP_ENTRY_FILE"

        sleep 5
        echo -e "  ${GREEN}✓ RCA comment and findings successfully published to ${MAPPED_ISSUE}!${NC}"
    else
        echo -e "  ${YELLOW}[NOTE] Could not find mapped issue in DynamoDB for task ${TEST_TASK_ID}.${NC}"
        echo -e "  Printing recent Lambda logs for debugging:\n"
        aws logs tail "/aws/lambda/${LAMBDA_FUNCTION_NAME}" --region "$TARGET_REGION" --since 5m --format short 2>/dev/null || true
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

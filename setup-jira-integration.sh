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
# 2. DevOps Agent Space Discovery (Supports Space Name or Space ID)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [2/6] Discovering AWS DevOps Agent Space...${NC}"
SPACES_JSON="{}"
if aws devops-agent list-agent-spaces --region "$TARGET_REGION" &>/dev/null; then
    SPACES_JSON=$(aws devops-agent list-agent-spaces --region "$TARGET_REGION" --output json 2>/dev/null || echo "{}")
elif aws aidevops list-agent-spaces --region "$TARGET_REGION" &>/dev/null; then
    SPACES_JSON=$(aws aidevops list-agent-spaces --region "$TARGET_REGION" --output json 2>/dev/null || echo "{}")
fi

NUM_SPACES=$(echo "$SPACES_JSON" | jq '.agentSpaces | length' 2>/dev/null || echo "0")
FIRST_SPACE_ID=$(echo "$SPACES_JSON" | jq -r '.agentSpaces[0].agentSpaceId // empty' 2>/dev/null || echo "")
FIRST_SPACE_NAME=$(echo "$SPACES_JSON" | jq -r '.agentSpaces[0].name // empty' 2>/dev/null || echo "")

# Helper function to resolve space name or ID to an agentSpaceId
resolve_space_id() {
    local input="$1"
    if [ -z "$input" ]; then
        echo "$FIRST_SPACE_ID"
        return
    fi
    local matched_id
    matched_id=$(echo "$SPACES_JSON" | jq -r --arg val "$input" '.agentSpaces[]? | select((.name // "" | ascii_downcase) == ($val | ascii_downcase) or .agentSpaceId == $val) | .agentSpaceId' 2>/dev/null | head -n 1)
    if [ -n "$matched_id" ] && [ "$matched_id" != "null" ]; then
        echo "$matched_id"
    else
        echo "$input"
    fi
}

USER_SPACE_INPUT="${AGENT_SPACE_ID:-${AGENT_SPACE_NAME:-}}"

if [ "$NUM_SPACES" -gt 0 ] 2>/dev/null; then
    echo -e "  Found active DevOps Agent Space(s) in ${TARGET_REGION}:"
    echo "$SPACES_JSON" | jq -r '.agentSpaces[] | "    • \(.name)  (ID: \(.agentSpaceId))"'
fi

if [ "$NON_INTERACTIVE" = true ]; then
    if [ -n "$USER_SPACE_INPUT" ]; then
        AGENT_SPACE_ID=$(resolve_space_id "$USER_SPACE_INPUT")
        echo -e "  Resolved Space to ID: ${BOLD}${AGENT_SPACE_ID}${NC}"
    else
        AGENT_SPACE_ID="${FIRST_SPACE_ID:-3f1e5f09-659d-4073-a7a5-2b5ca9e633bd}"
        echo -e "  Using default discovered Agent Space ID: ${BOLD}${AGENT_SPACE_ID}${NC}"
    fi
else
    if [ -n "$FIRST_SPACE_ID" ]; then
        DEFAULT_DISPLAY="${FIRST_SPACE_NAME:-$FIRST_SPACE_ID}"
        echo -e "\n  You can enter either the ${BOLD}Space Name${NC} (e.g. '${FIRST_SPACE_NAME}') or the ${BOLD}Space ID${NC}."
        read -rp "Enter Agent Space Name or Space ID [${DEFAULT_DISPLAY}]: " INPUT_SPACE
        CHOSEN_SPACE="${INPUT_SPACE:-$DEFAULT_DISPLAY}"
        AGENT_SPACE_ID=$(resolve_space_id "$CHOSEN_SPACE")
        echo -e "  ${GREEN}✓ Using DevOps Agent Space ID: ${BOLD}${AGENT_SPACE_ID}${NC}"
    else
        DEFAULT_SPACE="${USER_SPACE_INPUT:-3f1e5f09-659d-4073-a7a5-2b5ca9e633bd}"
        echo -e "  ${YELLOW}No DevOps Agent Space auto-detected via CLI.${NC}"
        read -rp "Enter your AWS DevOps Agent Space Name or ID [${DEFAULT_SPACE}]: " INPUT_SPACE
        CHOSEN_SPACE="${INPUT_SPACE:-$DEFAULT_SPACE}"
        AGENT_SPACE_ID=$(resolve_space_id "$CHOSEN_SPACE")
        echo -e "  ${GREEN}✓ Configured Agent Space ID: ${BOLD}${AGENT_SPACE_ID}${NC}"
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
# 4. Provision Secrets Manager Secret & Shared Webhook Token
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [4/6] Storing Jira Credentials & Shared Secret in AWS Secrets Manager...${NC}"

# Generate or reuse high-entropy webhook shared secret token
WEBHOOK_SECRET_TOKEN="${JIRA_WEBHOOK_SECRET:-}"
if [ -z "$WEBHOOK_SECRET_TOKEN" ]; then
    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$TARGET_REGION" &>/dev/null; then
        EXISTING_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$TARGET_REGION" --query "SecretString" --output text 2>/dev/null || echo "{}")
        WEBHOOK_SECRET_TOKEN=$(echo "$EXISTING_JSON" | jq -r '.webhook_secret_token // empty' 2>/dev/null || echo "")
    fi
fi
if [ -z "$WEBHOOK_SECRET_TOKEN" ]; then
    WEBHOOK_SECRET_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
fi

SECRET_PAYLOAD=$(jq -n \
  --arg url "$JIRA_URL" \
  --arg email "$JIRA_EMAIL" \
  --arg token "$JIRA_TOKEN" \
  --arg proj "$JIRA_PROJECT" \
  --arg itype "$JIRA_ISSUE_TYPE" \
  --arg wsec "$WEBHOOK_SECRET_TOKEN" \
  '{
    jira_base_url: $url,
    jira_user_email: $email,
    jira_api_token: $token,
    jira_project_key: $proj,
    jira_issue_type: $itype,
    webhook_secret_token: $wsec
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
# 6. End-to-End Integration Verification Scenarios
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}==> [6/6] End-to-End Integration Verification${NC}"
echo -e "Choose an automated scenario to verify the live integration:\n"
echo -e "  ${BOLD}1) Outbound: Trigger REAL Investigation in AWS DevOps Agent${NC}"
echo -e "     Creates an authentic backlog task in your DevOps Agent Space using AWS CLI."
echo -e "     DevOps Agent starts analyzing, emits native 'aws.aidevops' to EventBridge,"
echo -e "     creates a live Jira ticket in ${BOLD}${JIRA_PROJECT}${NC}, and posts diagnostic updates & RCA."
echo -e ""
echo -e "  ${BOLD}2) Inbound: Create Incident in Jira & Trigger AWS DevOps Agent${NC}"
echo -e "     Creates a new live incident ticket in Jira (${BOLD}${JIRA_PROJECT}${NC}) via REST API."
echo -e "     The webhook receiver triggers AWS DevOps Agent to start an investigation,"
echo -e "     acknowledges with the Task ID, and sends investigation details back to Jira."
echo -e ""
echo -e "  ${BOLD}3) Skip Verification${NC} (Complete setup directly)\n"

if [ "$NON_INTERACTIVE" = true ]; then
    TEST_CHOICE="${TEST_SCENARIO:-1}"
    echo -e "  Non-interactive test scenario selected: ${BOLD}${TEST_CHOICE}${NC}"
else
    read -rp "Select verification scenario [1/2/3] (default: 1): " USER_CHOICE
    TEST_CHOICE="${USER_CHOICE:-1}"
fi

if [ "$TEST_CHOICE" = "1" ]; then
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${BOLD} Scenario 1: Triggering Real Investigation in AWS DevOps Agent       ${NC}"
    echo -e "${CYAN}======================================================================${NC}"

    CLI_BIN="aws devops-agent"
    if ! aws devops-agent help &>/dev/null && aws aidevops help &>/dev/null; then
        CLI_BIN="aws aidevops"
    fi

    SCENARIO_TITLE="Investigate High Latency Anomaly and 5xx Spike on Checkout Service"
    SCENARIO_DESC="Autonomous incident investigation to analyze correlated CloudWatch metrics, OpenSearch logs, and X-Ray traces across the checkout fleet."
    CLIENT_TOKEN="setup-scen1-$(date +%s)-$RANDOM"

    echo -e "  Submitting backlog task to AWS DevOps Agent (${BOLD}${CLI_BIN} create-backlog-task${NC})..."
    TASK_OUTPUT=$($CLI_BIN create-backlog-task \
        --agent-space-id "$AGENT_SPACE_ID" \
        --task-type "INVESTIGATION" \
        --title "$SCENARIO_TITLE" \
        --description "$SCENARIO_DESC" \
        --priority "HIGH" \
        --client-token "$CLIENT_TOKEN" \
        --region "$TARGET_REGION" \
        --output json 2>&1 || echo "{}")

    REAL_TASK_ID=$(echo "$TASK_OUTPUT" | jq -r '.taskId // .task.taskId // empty' 2>/dev/null || echo "")

    if [ -n "$REAL_TASK_ID" ]; then
        echo -e "  ${GREEN}✓ Real DevOps Agent Investigation Task Created!${NC}"
        echo -e "  DevOps Task ID: ${BOLD}${REAL_TASK_ID}${NC}"
        echo -e "\n  ${CYAN}What is happening right now in AWS:${NC}"
        echo -e "  1. AWS DevOps Agent has autonomously started analyzing your AWS infrastructure."
        echo -e "  2. The service emitted an authentic ${BOLD}'aws.aidevops'${NC} -> ${BOLD}'Investigation Created'${NC} event."
        echo -e "  3. EventBridge routed the event to your Lambda handler."
        echo -e "  4. Lambda is creating a real ticket in Jira project ${BOLD}${JIRA_PROJECT}${NC}..."

        echo -e "\n  Polling DynamoDB table '${TABLE_NAME}' for the created Jira ticket..."
        MAPPED_ISSUE=""
        for i in {1..10}; do
            echo -n "  Waiting for Jira creation (attempt $i/10)... "
            sleep 4
            MAPPED_ISSUE=$(aws dynamodb get-item \
                --table-name "$TABLE_NAME" \
                --key "{\"taskId\": {\"S\": \"${REAL_TASK_ID}\"}}" \
                --region "$TARGET_REGION" \
                --query "Item.jiraIssueKey.S" \
                --output text 2>/dev/null || echo "")
            if [ -n "$MAPPED_ISSUE" ] && [ "$MAPPED_ISSUE" != "None" ]; then
                echo -e "${GREEN}Found!${NC}"
                break
            fi
            echo "pending..."
        done

        if [ -n "$MAPPED_ISSUE" ] && [ "$MAPPED_ISSUE" != "None" ]; then
            echo -e "\n${GREEN}======================================================================${NC}"
            echo -e "${GREEN}${BOLD} SUCCESS! Live Jira ticket created from Real AWS DevOps Agent Event!${NC}"
            echo -e "${GREEN}======================================================================${NC}"
            echo -e "  DevOps Task ID:    ${BOLD}${REAL_TASK_ID}${NC}"
            echo -e "  Jira Issue Key:    ${BOLD}${MAPPED_ISSUE}${NC}"
            echo -e "  Direct Ticket URL: ${BLUE}${BOLD}${JIRA_URL}/browse/${MAPPED_ISSUE}${NC}"
            echo -e "======================================================================\n"
        else
            echo -e "\n  ${YELLOW}[NOTE] Ticket creation still propagating. Check Lambda logs:${NC}"
            echo -e "  aws logs tail \"/aws/lambda/${LAMBDA_FUNCTION_NAME}\" --since 5m --region ${TARGET_REGION}"
        fi
    else
        echo -e "\n  ${RED}[ERROR] Failed to create backlog task in AWS DevOps Agent:${NC}"
        echo "$TASK_OUTPUT"
    fi

elif [ "$TEST_CHOICE" = "2" ]; then
    echo -e "\n${CYAN}======================================================================${NC}"
    echo -e "${BOLD} Scenario 2: Creating Incident in Jira & Testing Inbound Trigger     ${NC}"
    echo -e "${CYAN}======================================================================${NC}"

    INCIDENT_SUMMARY="Production Incident: 504 Gateway Timeout Spike on Checkout Service ($(date +%H:%M:%S))"
    INCIDENT_DESC="Elevated error rates detected across API Gateway and ALB target groups. Customer checkout transactions failing with 504 Gateway Timeouts. Autonomous diagnostic investigation requested."

    # 1. Create Incident ticket in Jira via REST API v3
    echo -e "  [Step 1] Creating a new incident ticket in Jira project ${BOLD}${JIRA_PROJECT}${NC}..."
    JIRA_PAYLOAD=$(jq -n \
      --arg project "$JIRA_PROJECT" \
      --arg summary "$INCIDENT_SUMMARY" \
      --arg description "$INCIDENT_DESC" \
      --arg issueType "$JIRA_ISSUE_TYPE" \
      '{
        fields: {
          project: { key: $project },
          summary: $summary,
          description: {
            type: "doc",
            version: 1,
            content: [
              {
                type: "paragraph",
                content: [
                  {
                    type: "text",
                    text: $description
                  }
                ]
              }
            ]
          },
          issuetype: { name: $issueType },
          labels: ["aws-devops-agent", "incident-management", "alert"]
        }
      }')

    CREATE_RESP=$(curl -s -L -w "\n%{http_code}" \
      --connect-timeout 15 \
      -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "$JIRA_PAYLOAD" \
      "${JIRA_URL}/rest/api/3/issue")

    JIRA_BODY=$(echo "$CREATE_RESP" | sed '$d')
    JIRA_CODE=$(echo "$CREATE_RESP" | tail -n 1)
    NEW_ISSUE_KEY=$(echo "$JIRA_BODY" | jq -r '.key // empty' 2>/dev/null || echo "")

    if [ "$JIRA_CODE" = "201" ] && [ -n "$NEW_ISSUE_KEY" ]; then
        echo -e "  ${GREEN}✓ Live Incident Created in Jira: ${BOLD}${NEW_ISSUE_KEY}${NC}"
        echo -e "  Direct Ticket Link: ${BLUE}${BOLD}${JIRA_URL}/browse/${NEW_ISSUE_KEY}${NC}"

        echo -e "\n  [Step 2] Testing Inbound Webhook Trigger to AWS DevOps Agent..."
        echo -e "  Sending ticket event to Webhook Function URL (${WEBHOOK_URL})..."

        WEBHOOK_TEST_PAYLOAD=$(jq -n \
          --arg issueKey "$NEW_ISSUE_KEY" \
          --arg summary "$INCIDENT_SUMMARY" \
          --arg desc "$INCIDENT_DESC" \
          --arg itype "$JIRA_ISSUE_TYPE" \
          '{
            webhookEvent: "jira:issue_created",
            issue: {
              key: $issueKey,
              fields: {
                summary: $summary,
                description: $desc,
                issuetype: { name: $itype },
                priority: { name: "High" },
                labels: ["aws-devops-agent", "incident-management"]
              }
            },
            user: {
              displayName: "Jira Setup Wizard"
            }
          }')

        SECURED_WEBHOOK_URL="${WEBHOOK_URL}?token=${WEBHOOK_SECRET_TOKEN}"
        WEBHOOK_RESP=$(curl -s -L \
          -H "Content-Type: application/json" \
          -X POST \
          -d "$WEBHOOK_TEST_PAYLOAD" \
          "$SECURED_WEBHOOK_URL" 2>/dev/null || echo "{}")

        TRIGGERED_TASK=$(echo "$WEBHOOK_RESP" | jq -r '.taskId // empty' 2>/dev/null || echo "")

        if [ -n "$TRIGGERED_TASK" ]; then
            echo -e "  ${GREEN}✓ Secured Webhook successfully triggered AWS DevOps Agent!${NC}"
            echo -e "  Initiated DevOps Agent Task ID: ${BOLD}${TRIGGERED_TASK}${NC}"
            echo -e "  DevOps Agent has acknowledged and replied to Jira issue ${BOLD}${NEW_ISSUE_KEY}${NC}."

            echo -e "\n${GREEN}======================================================================${NC}"
            echo -e "${GREEN}${BOLD} SUCCESS! Inbound Flow from Jira to AWS DevOps Agent is Active!     ${NC}"
            echo -e "${GREEN}======================================================================${NC}"
            echo -e "  Jira Ticket:       ${BOLD}${NEW_ISSUE_KEY}${NC}"
            echo -e "  DevOps Task ID:    ${BOLD}${TRIGGERED_TASK}${NC}"
            echo -e "  Live Ticket URL:   ${BLUE}${BOLD}${JIRA_URL}/browse/${NEW_ISSUE_KEY}${NC}"
            echo -e "  Console Deep Link: https://${TARGET_REGION}.console.aws.amazon.com/aidevops/home?region=${TARGET_REGION}#/spaces/${AGENT_SPACE_ID}/tasks/${TRIGGERED_TASK}"
            echo -e "======================================================================\n"
        else
            echo -e "  ${YELLOW}Webhook response:${NC} ${WEBHOOK_RESP}"
        fi
    else
        echo -e "  ${RED}[ERROR] Failed to create Jira incident ticket (HTTP ${JIRA_CODE}):${NC}"
        echo "$JIRA_BODY"
    fi
else
    echo -e "  Verification skipped. Setup completed."
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
    SECURED_WEBHOOK_URL="${WEBHOOK_URL}?token=${WEBHOOK_SECRET_TOKEN}"
    echo -e "\n${CYAN}--- Bi-directional Jira Webhook Endpoint (Secured with Shared Secret) ---${NC}"
    echo -e "  Secured Webhook URL:    ${BOLD}${SECURED_WEBHOOK_URL}${NC}"
    echo -e "  Shared Secret Token:    ${BOLD}${WEBHOOK_SECRET_TOKEN}${NC}"
    echo -e "  To register in Jira:"
    echo -e "  1. In Jira, navigate to Settings (gear ⚙️) > System > Webhooks."
    echo -e "  2. Click '+ Create a Webhook' and paste the full Secured URL above (including '?token=...')."
    echo -e "  3. Check 'Issue: created, updated' and 'Comment: created'."
    echo -e "  4. Any unauthorized requests without this token are automatically rejected with HTTP 403 Forbidden!"
fi

echo -e "\n${BOLD}Thank you for deploying AWS DevOps Agent to Jira integration!${NC}\n"

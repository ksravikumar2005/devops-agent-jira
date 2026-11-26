#!/usr/bin/env bash
# ==============================================================================
# Script: Create a Ticket in Atlassian Jira Cloud
# ==============================================================================
# Creates an issue in your Jira project using Jira REST API v3.
#
# Credentials:
#   Automatically fetched from AWS Secrets Manager ('devops-agent/jira-credentials')
#   or from environment variables (JIRA_URL, JIRA_EMAIL, JIRA_TOKEN, JIRA_PROJECT).
#
# Labels:
#   Includes 'aws-devops-agent' so that if your webhook is configured,
#   AWS DevOps Agent will immediately begin an autonomous investigation!
# ==============================================================================

set -eo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
YELLOW="\033[33m"
NC="\033[0m"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
SECRET_NAME="${JIRA_SECRET_NAME:-devops-agent/jira-credentials}"

# 1. Fetch credentials from Secrets Manager if not set in environment
if [ -z "$JIRA_URL" ] || [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_TOKEN" ]; then
    if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
        echo -e "${CYAN}Retrieving Jira credentials from AWS Secrets Manager ('${SECRET_NAME}')...${NC}"
        SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --query "SecretString" --output text 2>/dev/null || echo "{}")
        JIRA_URL="${JIRA_URL:-$(echo "$SECRET_JSON" | jq -r '.jira_base_url // .baseUrl // empty')}"
        JIRA_EMAIL="${JIRA_EMAIL:-$(echo "$SECRET_JSON" | jq -r '.jira_user_email // .email // empty')}"
        JIRA_TOKEN="${JIRA_TOKEN:-$(echo "$SECRET_JSON" | jq -r '.jira_api_token // .apiToken // empty')}"
        JIRA_PROJECT="${JIRA_PROJECT:-$(echo "$SECRET_JSON" | jq -r '.jira_project_key // empty')}"
        JIRA_ISSUE_TYPE="${JIRA_ISSUE_TYPE:-$(echo "$SECRET_JSON" | jq -r '.jira_issue_type // empty')}"
    fi
fi

# Fallback defaults
JIRA_URL="${JIRA_URL:-https://aws-devops-agent.atlassian.net}"
JIRA_EMAIL="${JIRA_EMAIL:-ksravikumar2005@gmail.com}"
JIRA_PROJECT="${JIRA_PROJECT:-KAN}"
JIRA_ISSUE_TYPE="${JIRA_ISSUE_TYPE:-Task}"

# Clean trailing slashes
JIRA_URL="${JIRA_URL%/}"

# Command line arguments or prompts
SUMMARY="${1:-}"
DESCRIPTION="${2:-}"

if [ -z "$SUMMARY" ]; then
    SUMMARY="High Latency and 504 Gateway Timeouts on Checkout API"
fi

if [ -z "$DESCRIPTION" ]; then
    DESCRIPTION="Correlated CloudWatch metrics indicate elevated p99 latency exceeding 4500ms on ALB target group 'tg-checkout-fleet'. Multiple ECS tasks reporting memory saturation."
fi

# Validate token exists
if [ -z "$JIRA_TOKEN" ]; then
    echo -e "${RED}[ERROR] Jira API Token not found.${NC}"
    echo -e "Please export JIRA_TOKEN or ensure secret '${SECRET_NAME}' exists in region '${REGION}'."
    echo -e "Example: export JIRA_TOKEN='your_atlassian_api_token'"
    exit 1
fi

echo -e "\n${CYAN}======================================================================${NC}"
echo -e "${BOLD}                     Creating Jira Cloud Issue                       ${NC}"
echo -e "${CYAN}======================================================================${NC}"
echo -e "  Jira Base URL:    ${BOLD}${JIRA_URL}${NC}"
echo -e "  User Email:       ${BOLD}${JIRA_EMAIL}${NC}"
echo -e "  Project Key:      ${BOLD}${JIRA_PROJECT}${NC}"
echo -e "  Issue Type:       ${BOLD}${JIRA_ISSUE_TYPE}${NC}"
echo -e "  Summary:          ${BOLD}${SUMMARY}${NC}"
echo -e "  Auto-Trigger:     ${GREEN}Label 'aws-devops-agent' attached${NC}\n"

# Verify project issue types to prevent invalid issue type errors
PROJ_INFO=$(curl -s -L --connect-timeout 10 -u "${JIRA_EMAIL}:${JIRA_TOKEN}" -H "Accept: application/json" "${JIRA_URL}/rest/api/3/project/${JIRA_PROJECT}" 2>/dev/null || echo "{}")
VALID_TYPES=$(echo "$PROJ_INFO" | jq -r '.issueTypes[]? | select(.subtask==false) | .name' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')

if [ -n "$VALID_TYPES" ]; then
    if ! echo "$VALID_TYPES" | grep -iq "\b${JIRA_ISSUE_TYPE}\b"; then
        FIRST_VALID=$(echo "$VALID_TYPES" | awk '{print $1}')
        echo -e "  ${YELLOW}Notice: Issue type '${JIRA_ISSUE_TYPE}' is not in project ${JIRA_PROJECT}.${NC}"
        echo -e "  ${GREEN}✓ Auto-switching issue type to: ${FIRST_VALID:-Task}${NC}"
        JIRA_ISSUE_TYPE="${FIRST_VALID:-Task}"
    fi
fi

# Construct Atlassian Document Format (ADF) payload
PAYLOAD=$(jq -n \
  --arg project "$JIRA_PROJECT" \
  --arg summary "$SUMMARY" \
  --arg description "$DESCRIPTION" \
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
      priority: { name: "High" },
      labels: ["aws-devops-agent", "incident-management", "alert"]
    }
  }')

echo -e "  Sending issue creation request to Jira REST API v3..."
RESPONSE=$(curl -s -L -w "\n%{http_code}" \
  --connect-timeout 15 \
  -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" \
  "${JIRA_URL}/rest/api/3/issue")

HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

# Retry without priority if priority field is rejected by project screen layout
if [ "$HTTP_CODE" = "400" ] && echo "$HTTP_BODY" | grep -iq "priority"; then
    echo -e "  ${YELLOW}Priority field not on project screen. Retrying without priority...${NC}"
    PAYLOAD_NO_PRIORITY=$(echo "$PAYLOAD" | jq 'del(.fields.priority)')
    RESPONSE=$(curl -s -L -w "\n%{http_code}" \
      --connect-timeout 15 \
      -u "${JIRA_EMAIL}:${JIRA_TOKEN}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "$PAYLOAD_NO_PRIORITY" \
      "${JIRA_URL}/rest/api/3/issue")
    HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
fi

ISSUE_KEY=$(echo "$HTTP_BODY" | jq -r '.key // empty' 2>/dev/null || echo "")

if [ "$HTTP_CODE" = "201" ] && [ -n "$ISSUE_KEY" ]; then
    echo -e "\n${GREEN}======================================================================${NC}"
    echo -e "${GREEN}${BOLD}               SUCCESS! Jira Issue Created Successfully              ${NC}"
    echo -e "${GREEN}======================================================================${NC}"
    echo -e "  Issue Key:         ${BOLD}${ISSUE_KEY}${NC}"
    echo -e "  Direct Issue Link: ${BLUE}${BOLD}${JIRA_URL}/browse/${ISSUE_KEY}${NC}"
    echo -e "  Project:           ${BOLD}${JIRA_PROJECT}${NC}"
    echo -e "  Summary:           ${BOLD}${SUMMARY}${NC}"
    echo -e "  Labels:            aws-devops-agent, incident-management, alert"
    echo -e "\n${CYAN}Bi-directional Automation Note:${NC}"
    echo -e "  Because the 'aws-devops-agent' label is attached, your Jira Webhook will"
    echo -e "  notify AWS DevOps Agent to autonomously start diagnostic analysis!"
    echo -e "======================================================================\n"
else
    echo -e "\n${RED}[ERROR] Failed to create Jira issue (HTTP ${HTTP_CODE}):${NC}"
    echo "$HTTP_BODY" | jq . 2>/dev/null || echo "$HTTP_BODY"
    echo ""
    exit 1
fi

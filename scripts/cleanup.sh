#!/usr/bin/env bash
# ==============================================================================
# Teardown Script: Delete CloudFormation Stack, Secret, and DynamoDB State Table
# ==============================================================================

set -eo pipefail

STACK_NAME="devops-agent-jira-integration"
SECRET_NAME="devops-agent/jira-credentials"
TABLE_NAME="devops-agent-jira-mappings"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

echo "WARNING: This will permanently delete the following resources in ${REGION}:"
echo "  - CloudFormation Stack: ${STACK_NAME}"
echo "  - Secrets Manager Secret: ${SECRET_NAME}"
echo "  - DynamoDB Table: ${TABLE_NAME}"
read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

echo -e "\n[1/3] Deleting CloudFormation Stack: ${STACK_NAME}..."
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
echo "Stack deleted."

echo -e "\n[2/3] Deleting Secrets Manager Secret: ${SECRET_NAME}..."
aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
echo "Secret deleted."

echo -e "\n[3/3] Deleting DynamoDB Table: ${TABLE_NAME}..."
aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null || true
echo "Table deleted."

echo -e "\nCleanup complete!"

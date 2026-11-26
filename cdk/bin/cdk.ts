#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { DevOpsAgentJiraStack } from '../lib/devops-agent-jira-stack';

const app = new cdk.App();

const secretName = app.node.tryGetContext('secretName') || 'devops-agent/jira-credentials';
const tableName = app.node.tryGetContext('tableName') || 'devops-agent-jira-mappings';
const agentSpaceId = app.node.tryGetContext('agentSpaceId') || 'default';

new DevOpsAgentJiraStack(app, 'DevOpsAgentJiraStack', {
  secretName,
  tableName,
  agentSpaceId,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'us-east-1',
  },
  description: 'AWS DevOps Agent to Jira Cloud EventBridge Integration Stack',
});

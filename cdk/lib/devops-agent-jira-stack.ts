import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as iam from 'aws-cdk-lib/aws-iam';

export interface DevOpsAgentJiraStackProps extends cdk.StackProps {
  readonly secretName?: string;
  readonly tableName?: string;
  readonly agentSpaceId?: string;
}

export class DevOpsAgentJiraStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: DevOpsAgentJiraStackProps) {
    super(scope, id, props);

    const secretName = props?.secretName || 'devops-agent/jira-credentials';
    const tableName = props?.tableName || 'devops-agent-jira-mappings';
    const agentSpaceId = props?.agentSpaceId || 'default';

    // 1. DynamoDB Table for Task ID <-> Jira Issue Key Mapping
    const mappingTable = new dynamodb.Table(this, 'DevOpsAgentJiraTable', {
      tableName,
      partitionKey: { name: 'taskId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // 2. Reference Existing Secrets Manager Secret
    const jiraSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'JiraCredentialsSecret',
      secretName
    );

    // 3. Outbound Integration Lambda Function (Python 3.12)
    const eventHandlerLambda = new lambda.Function(this, 'EventHandlerLambda', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'event_handler.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../src/lambda')),
      timeout: cdk.Duration.seconds(60),
      memorySize: 256,
      environment: {
        JIRA_SECRET_NAME: secretName,
        DYNAMODB_TABLE_NAME: mappingTable.tableName,
        LOG_LEVEL: 'INFO',
      },
      description: 'Synchronizes AWS DevOps Agent lifecycle events to Jira Cloud',
    });

    // Grant Permissions
    mappingTable.grantReadWriteData(eventHandlerLambda);
    jiraSecret.grantRead(eventHandlerLambda);
    eventHandlerLambda.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['aidevops:*', 'devops-agent:*'],
        resources: ['*'],
      })
    );

    // 4. Amazon EventBridge Rule for 'aws.aidevops' source
    const eventRule = new events.Rule(this, 'DevOpsAgentInvestigationRule', {
      description: 'Filters AWS DevOps Agent investigation events for Jira routing',
      eventPattern: {
        source: ['aws.aidevops', 'custom.aidevops', 'devops.agent.test'],
        detailType: [{ prefix: 'Investigation' } as any],
      },
    });

    eventRule.addTarget(new targets.LambdaFunction(eventHandlerLambda));

    // 5. Inbound Webhook Receiver Lambda Function (Optional Bi-directional)
    const webhookReceiverLambda = new lambda.Function(this, 'WebhookReceiverLambda', {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'webhook_receiver.lambda_handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '../../src/lambda')),
      timeout: cdk.Duration.seconds(30),
      memorySize: 256,
      environment: {
        AGENT_SPACE_ID: agentSpaceId,
        LOG_LEVEL: 'INFO',
      },
      description: 'Inbound Jira Cloud webhook endpoint for bidirectional incident triage',
    });

    webhookReceiverLambda.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['events:PutEvents'],
        resources: ['*'],
      })
    );

    const functionUrl = webhookReceiverLambda.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
      cors: {
        allowedMethods: [lambda.HttpMethod.POST, lambda.HttpMethod.GET],
        allowedOrigins: ['*'],
        allowedHeaders: ['*'],
      },
    });

    // Outputs
    new cdk.CfnOutput(this, 'TableNameOutput', {
      value: mappingTable.tableName,
      description: 'DynamoDB State Table Name',
      exportName: 'DevOpsAgentJira-TableName',
    });

    new cdk.CfnOutput(this, 'LambdaArnOutput', {
      value: eventHandlerLambda.functionArn,
      description: 'Event Handler Lambda ARN',
      exportName: 'DevOpsAgentJira-LambdaArn',
    });

    new cdk.CfnOutput(this, 'EventRuleArnOutput', {
      value: eventRule.ruleArn,
      description: 'EventBridge Rule ARN',
      exportName: 'DevOpsAgentJira-RuleArn',
    });

    new cdk.CfnOutput(this, 'WebhookUrlOutput', {
      value: functionUrl.url,
      description: 'Jira Inbound Webhook Function URL',
      exportName: 'DevOpsAgentJira-WebhookUrl',
    });
  }
}

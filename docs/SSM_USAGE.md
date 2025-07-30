# SSM Parameter Store Usage

The deployment workflow automatically stores AMI information in AWS Systems Manager Parameter Store for easy access by your application code. The workflow uses an **incremental update strategy** - it updates existing AMIs instead of creating new ones each time, making deployments faster and more efficient.

## AMI Update Strategy

### How it Works
1. **First deployment**: Creates a fresh AMI from Ubuntu base
2. **Subsequent deployments**: 
   - Launches instance from existing ComfyUI AMI
   - Updates only the Docker image
   - Creates new AMI to replace the old one
   - Cleans up the previous AMI

### Benefits
- ⚡ **Faster builds**: Only Docker image updates, not full system setup
- 🔄 **Consistent environment**: Preserves system configuration across updates
- 💾 **Efficient storage**: Only one AMI per environment (no accumulation)
- 🎯 **Reliable updates**: Proven base system with incremental changes

## Parameter Structure

### Latest AMI ID
- **Path**: `/comfyui/ami/{environment}/latest`
- **Type**: String
- **Value**: The AMI ID (e.g., `ami-0123456789abcdef0`)
- **Description**: Latest ComfyUI AMI ID for the environment

### Latest AMI Metadata
- **Path**: `/comfyui/ami/{environment}/metadata`
- **Type**: String (JSON)
- **Value**: Detailed metadata about the latest AMI
- **Description**: Complete deployment information

### Historical Records
- **Path**: `/comfyui/ami/{environment}/history/{ami-id}`
- **Type**: String (JSON)
- **Value**: Historical metadata for specific AMI
- **Description**: Preserved for audit trail

## Usage Examples

### AWS CLI
```bash
# Get latest AMI ID for production
aws ssm get-parameter --name '/comfyui/ami/prod/latest' --region us-east-1

# Get latest AMI metadata for development
aws ssm get-parameter --name '/comfyui/ami/dev/metadata' --region us-east-1
```

### Python (boto3)
```python
import boto3
import json

def get_latest_ami_id(environment='prod', region='us-east-1'):
    """Get the latest ComfyUI AMI ID for an environment."""
    ssm = boto3.client('ssm', region_name=region)
    
    try:
        response = ssm.get_parameter(Name=f'/comfyui/ami/{environment}/latest')
        return response['Parameter']['Value']
    except ssm.exceptions.ParameterNotFound:
        raise ValueError(f"No AMI found for environment: {environment}")

def get_latest_ami_metadata(environment='prod', region='us-east-1'):
    """Get the latest ComfyUI AMI metadata for an environment."""
    ssm = boto3.client('ssm', region_name=region)
    
    try:
        response = ssm.get_parameter(Name=f'/comfyui/ami/{environment}/metadata')
        return json.loads(response['Parameter']['Value'])
    except ssm.exceptions.ParameterNotFound:
        raise ValueError(f"No AMI metadata found for environment: {environment}")

# Usage
ami_id = get_latest_ami_id('prod')
metadata = get_latest_ami_metadata('prod')

print(f"Latest AMI: {ami_id}")
print(f"Docker Image: {metadata['docker_image']}")
print(f"Created: {metadata['creation_date']}")
```

### Node.js (AWS SDK v3)
```javascript
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const ssm = new SSMClient({ region: "us-east-1" });

async function getLatestAmiId(environment = 'prod') {
  try {
    const command = new GetParameterCommand({
      Name: `/comfyui/ami/${environment}/latest`
    });
    const response = await ssm.send(command);
    return response.Parameter.Value;
  } catch (error) {
    throw new Error(`Failed to get AMI ID for ${environment}: ${error.message}`);
  }
}

async function getLatestAmiMetadata(environment = 'prod') {
  try {
    const command = new GetParameterCommand({
      Name: `/comfyui/ami/${environment}/metadata`
    });
    const response = await ssm.send(command);
    return JSON.parse(response.Parameter.Value);
  } catch (error) {
    throw new Error(`Failed to get AMI metadata for ${environment}: ${error.message}`);
  }
}

// Usage
const amiId = await getLatestAmiId('prod');
const metadata = await getLatestAmiMetadata('prod');

console.log(`Latest AMI: ${amiId}`);
console.log(`Docker Image: ${metadata.docker_image}`);
console.log(`Created: ${metadata.creation_date}`);
```

### Terraform
```hcl
data "aws_ssm_parameter" "comfyui_ami" {
  name = "/comfyui/ami/${var.environment}/latest"
}

resource "aws_instance" "comfyui" {
  ami           = data.aws_ssm_parameter.comfyui_ami.value
  instance_type = var.instance_type
  
  tags = {
    Name        = "comfyui-${var.environment}"
    Environment = var.environment
  }
}
```

## Metadata Schema

The metadata JSON includes:
```json
{
  "ami_id": "ami-0123456789abcdef0",
  "docker_image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/comfyui:prod-latest",
  "environment": "prod",
  "creation_date": "2024-01-15T10:30:00Z",
  "branch": "main",
  "commit_sha": "abc123def456",
  "region": "us-east-1",
  "workflow_run_id": "123456789",
  "workflow_run_number": "42"
}
```

## Deployment Behavior

### First Deployment (Fresh AMI)
- Uses latest Ubuntu 22.04 LTS as base
- Installs Docker, ComfyUI, and all dependencies
- Creates new AMI with consistent naming: `comfyui-multitenant-{env}`
- Stores AMI ID in SSM parameters

### Subsequent Deployments (AMI Updates)
- Launches instance from existing ComfyUI AMI
- Pulls new Docker image
- Updates Docker configuration
- Creates new AMI with same name (replaces old one)
- Cleans up previous AMI and snapshots
- Updates SSM parameters with new AMI ID

### Rollback Strategy
- Historical AMI metadata is preserved in SSM
- Can manually launch from previous Docker image if needed
- AMI naming remains consistent for easy identification

## IAM Permissions

Your application needs the following IAM permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": [
        "arn:aws:ssm:*:*:parameter/comfyui/ami/*/latest",
        "arn:aws:ssm:*:*:parameter/comfyui/ami/*/metadata",
        "arn:aws:ssm:*:*:parameter/comfyui/ami/*/history/*"
      ]
    }
  ]
}
```

## Error Handling

Always handle cases where:
- Parameters don't exist (environment not deployed yet)
- Invalid JSON in metadata parameters
- Network/permission errors when accessing SSM

## AMI Lifecycle Management

The new approach provides:
- **Consistent AMI naming**: Always `comfyui-multitenant-{env}` (no timestamps)
- **Automatic cleanup**: Previous AMI is removed when new one is ready
- **Incremental updates**: Only Docker image changes, system stays stable
- **Historical tracking**: Metadata preserved for audit purposes
- **Single AMI per environment**: No accumulation or manual cleanup needed

## Migration Notes

If you have multiple AMIs from the old approach:
1. The workflow will identify the newest existing AMI
2. Use it as the base for updates
3. Future deployments will maintain single AMI per environment
4. Manual cleanup of very old AMIs may be needed initially

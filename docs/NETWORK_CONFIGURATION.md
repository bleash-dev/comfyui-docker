# Network Configuration Guide

This document explains how the GitHub Actions workflow selects VPC and subnet resources for EC2 instance deployment.

## Preferred Resources

The workflow is configured to prefer specific CDK-managed resources:

### VPC Selection Priority

1. **Primary Target**: `viral-comm-api-viral-community-stack-dev/viral-comm-api-common-networking-dev/viral-comm-api-proxy-vpc-dev`
   - Full CDK resource name with stack path
   - Matches resources created by the viral-comm-api CDK stack

2. **Fallback Pattern**: `*proxy-vpc-dev`
   - Matches any VPC with name ending in "proxy-vpc-dev"
   - Handles cases where full path isn't used in tags

3. **Default VPC**: Uses AWS default VPC if available
   - Standard fallback for regions with default VPC

4. **Any VPC**: Uses the first available VPC in the region
   - Last resort fallback

### Subnet Selection Priority

Within the selected VPC, the workflow looks for:

1. **Primary Target**: `*vpc-proxy-subnetSubnet1*`
   - Matches the specific proxy subnet
   - CDK naming pattern for subnet resources

2. **CDK Logical ID**: `*vpc-proxy-subnetSubnet1*` via CloudFormation logical ID tag
   - Searches CDK logical ID tags for the subnet name
   - Handles CDK resource naming variations

3. **Generic Pattern**: `*SubnetSubnet1*`
   - Broader pattern for CDK-generated subnet names
   - Catches variations in naming conventions

4. **Public Subnet**: Any subnet with `map-public-ip-on-launch=true`
   - Ensures instance gets public IP for remote access
   - Required for GitHub Actions runner connectivity

5. **Any Subnet**: First available subnet in the VPC
   - Final fallback

## Resource Validation

The workflow validates that:

- Both VPC and subnet are successfully identified
- Resources exist and are accessible
- Proper tags and configurations are in place

## Logging and Monitoring

The workflow provides detailed logging including:

- Resource search attempts and results
- Fallback triggers and reasons
- Final resource selection summary
- Success/warning indicators for preferred vs fallback resources

## Security Groups

The workflow also attempts to find and use CDK-managed security groups with similar fallback logic:

1. **Preferred**: CDK-managed security groups with appropriate tags
2. **Fallback**: Default security group for the VPC
3. **Validation**: Ensures required ports (8188, 22) are accessible

## Troubleshooting

### Common Issues

1. **VPC Not Found**
   - Check CDK stack deployment status
   - Verify tag naming conventions
   - Ensure proper AWS permissions

2. **Subnet Not Found**
   - Verify subnet exists in the selected VPC
   - Check CDK logical ID naming
   - Ensure subnet has proper public access configuration

3. **Security Group Issues**
   - Validate security group rules for ports 8188 and 22
   - Check CDK security group deployment
   - Verify inbound rules for health checks

### Manual Resource Discovery

You can manually discover resources using AWS CLI:

```bash
# Find VPCs by name pattern
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*proxy-vpc-dev*"

# Find subnets in a specific VPC
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-xxxxxxxx" "Name=tag:Name,Values=*SubnetSubnet1*"

# Check security groups
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=vpc-xxxxxxxx"
```

## Configuration Updates

To modify the preferred resources:

1. Update the `PREFERRED_VPC_NAME` variable in the workflow
2. Update the `PREFERRED_SUBNET_NAME` pattern
3. Test the changes in a development environment
4. Update this documentation

## Best Practices

- Always test network configuration changes in a staging environment
- Monitor workflow logs for fallback usage patterns
- Keep CDK stack naming conventions consistent
- Ensure security groups have appropriate rules for ComfyUI (port 8188)

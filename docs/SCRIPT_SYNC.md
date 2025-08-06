# Script Sync to S3 for ComfyUI AMI

This workflow automatically syncs the latest scripts to S3, ensuring that ComfyUI AMI instances always have access to the most recent code when they start or restart.

## How It Works

### Automatic Syncing
The workflow automatically triggers when:
- Scripts are pushed to `main` branch (syncs to **prod** environment)
- Scripts are pushed to `dev` branch (syncs to **dev** environment)
- Any files in the `scripts/` directory are changed
- The `tenant_manager.py` file is changed

### Manual Syncing
You can also manually trigger the sync:
1. Go to **Actions** tab in GitHub
2. Select **Sync Scripts to S3** workflow
3. Click **Run workflow**
4. Choose environment (`dev` or `prod`)
5. Optionally enable **Force sync** to sync all files regardless of changes

## S3 Structure

Scripts are synced to the following S3 locations:
- **Dev**: `s3://viral-comm-api-ec2-deployments-dev/comfyui-ami/dev/`
- **Prod**: `s3://viral-comm-api-ec2-deployments-prod/comfyui-ami/prod/`

## AMI Integration

### Automatic Sync on Service Start
The ComfyUI multitenant service automatically syncs scripts from S3 every time it starts:
1. Service starts → `ExecStartPre` runs `/usr/local/bin/sync-scripts-from-s3`
2. Latest scripts are downloaded from S3
3. `tenant_manager.py` is updated if a new version exists
4. Service proceeds to start with the latest scripts

### Manual Sync on Running Instances
To manually sync scripts on a running instance:
```bash
# Sync scripts and restart service
sudo update-scripts

# Check sync status
sudo comfyui-monitor
```

## IAM Permissions Required

The AMI instances need the following S3 permissions:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::viral-comm-api-ec2-deployments-*",
        "arn:aws:s3:::viral-comm-api-ec2-deployments-*/comfyui-ami/*"
      ]
    }
  ]
}
```

## What Gets Synced

- All files in the `scripts/` directory (`.sh` and `.py` files)
- The `tenant_manager.py` file
- Scripts are made executable automatically
- Old/deleted files are removed from S3 (via `--delete` flag)

## Monitoring

### GitHub Actions
- View sync status in the **Actions** tab
- Each run shows which files were synced
- Failed syncs will show error details

### On AMI Instances
```bash
# Check overall system status including script sync
sudo comfyui-monitor

# View service logs (includes sync output)
sudo journalctl -u comfyui-multitenant -f

# Check when scripts were last updated
stat -c "Modified: %Y (%y)" /scripts
```

## Deployment Metadata

The workflow also creates deployment metadata in S3 at:
- `s3://viral-comm-api-ec2-deployments-{env}/comfyui-ami/{env}/deployment-metadata.json`

This contains information about:
- Last sync timestamp
- Git commit hash
- Changed files
- Who triggered the sync

## Troubleshooting

### Scripts Not Syncing
1. Check GitHub Actions for failed runs
2. Verify IAM permissions on AMI instances
3. Check S3 bucket access

### Service Not Starting After Script Sync
1. Check script syntax: `bash -n /scripts/script-name.sh`
2. View service logs: `sudo journalctl -u comfyui-multitenant -n 50`
3. Test script sync manually: `sudo /usr/local/bin/sync-scripts-from-s3`

### Manual Recovery
If automated sync fails, you can manually restore:
```bash
# Restore from backup (if available)
sudo cp -r /tmp/scripts-backup-* /scripts/

# Or manually download from S3
sudo aws s3 sync s3://viral-comm-api-ec2-deployments-dev/comfyui-ami/dev/ /scripts/

# Restart service
sudo systemctl restart comfyui-multitenant
```

## Best Practices

1. **Test in Dev First**: Always test script changes in the `dev` environment before promoting to `prod`
2. **Monitor Deployments**: Check GitHub Actions after pushing script changes
3. **Validate AMI Behavior**: Use the test instance scripts to verify AMI behavior after script changes
4. **Use Force Sync Sparingly**: Only use force sync when you need to ensure all files are re-uploaded

## Related Files

- **Workflow**: `.github/workflows/sync-scripts-to-s3.yml`
- **AMI Preparation**: `scripts/prepare_ami.sh` (creates the sync utility)
- **Sync Script**: `/usr/local/bin/sync-scripts-from-s3` (on AMI instances)
- **Manual Sync**: `/usr/local/bin/update-scripts` (on AMI instances)
- **Monitoring**: `/usr/local/bin/comfyui-monitor` (on AMI instances)

#!/bin/bash

# Manage Instance Script
# Start, stop, status, and terminate build instances

set -e

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

print_usage() {
    echo "Usage: $0 <command> <instance-name>"
    echo ""
    echo "Manage build instances"
    echo ""
    echo "Commands:"
    echo "  start        Start a stopped instance"
    echo "  stop         Stop a running instance"
    echo "  restart      Restart an instance"
    echo "  status       Show instance status and details"
    echo "  terminate    Terminate an instance (permanent)"
    echo "  connect      Show connection information"
    echo "  logs         Get instance logs via SSM"
    echo "  list         List all build instances"
    echo ""
    echo "Examples:"
    echo "  $0 status my-build-instance"
    echo "  $0 stop my-build-instance"
    echo "  $0 start my-build-instance"
    echo "  $0 terminate my-build-instance"
    echo "  $0 list"
}

# Validate arguments
if [[ $# -lt 1 ]]; then
    print_usage
    exit 1
fi

COMMAND="$1"
INSTANCE_NAME="${2:-}"

# Validate AWS CLI
validate_aws_cli

# Helper function to find instance
find_instance() {
    local instance_name="$1"
    
    if [[ -z "$instance_name" ]]; then
        log_error "Instance name required"
        return 1
    fi
    
    local instance_id
    instance_id=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$instance_name" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        log_error "Instance '$instance_name' not found"
        return 1
    fi
    
    echo "$instance_id"
}

# Command implementations
cmd_start() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    log_step "Starting instance: $instance_name"
    
    # Check current state
    local current_state
    current_state=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$AWS_REGION")
    
    case "$current_state" in
        "running")
            log_info "Instance is already running"
            return 0
            ;;
        "pending")
            log_info "Instance is already starting"
            ;;
        "stopped")
            log_info "Starting stopped instance..."
            aws ec2 start-instances --instance-ids "$instance_id" --region "$AWS_REGION" >/dev/null
            ;;
        *)
            log_error "Cannot start instance in state: $current_state"
            return 1
            ;;
    esac
    
    log_info "Waiting for instance to be running..."
    wait_for_instance_state "$instance_id" "running"
    
    # Get new IP address
    local public_ip
    public_ip=$(get_instance_ip "$instance_id")
    
    log_success "Instance is now running!"
    if [[ -n "$public_ip" && "$public_ip" != "None" ]]; then
        log_info "Public IP: $public_ip"
    fi
}

cmd_stop() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    log_step "Stopping instance: $instance_name"
    
    # Check current state
    local current_state
    current_state=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "$AWS_REGION")
    
    case "$current_state" in
        "stopped")
            log_info "Instance is already stopped"
            return 0
            ;;
        "stopping")
            log_info "Instance is already stopping"
            ;;
        "running")
            log_info "Stopping running instance..."
            aws ec2 stop-instances --instance-ids "$instance_id" --region "$AWS_REGION" >/dev/null
            ;;
        *)
            log_error "Cannot stop instance in state: $current_state"
            return 1
            ;;
    esac
    
    log_info "Waiting for instance to be stopped..."
    wait_for_instance_state "$instance_id" "stopped"
    
    log_success "Instance is now stopped!"
}

cmd_restart() {
    local instance_name="$1"
    
    log_step "Restarting instance: $instance_name"
    
    cmd_stop "$instance_name"
    if [[ $? -eq 0 ]]; then
        sleep 2
        cmd_start "$instance_name"
    fi
}

cmd_status() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    log_header "Instance Status: $instance_name"
    
    # Get detailed instance information
    local instance_info
    instance_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[InstanceId,State.Name,InstanceType,PublicIpAddress,PrivateIpAddress,LaunchTime,Tags[?Key==`Purpose`].Value|[0],Placement.AvailabilityZone]' \
        --output text \
        --region "$AWS_REGION")
    
    read -r id state type public_ip private_ip launch_time purpose az <<< "$instance_info"
    
    log_info "Basic Information:"
    echo "   Instance ID: $id"
    echo "   Name: $instance_name"
    echo "   State: $state"
    echo "   Type: $type"
    echo "   Purpose: ${purpose:-Unknown}"
    echo "   Availability Zone: $az"
    echo "   Launch Time: $launch_time"
    echo ""
    
    log_info "Network Information:"
    echo "   Public IP: ${public_ip:-None}"
    echo "   Private IP: $private_ip"
    echo ""
    
    # Show connection info if running
    if [[ "$state" == "running" && -n "$public_ip" && "$public_ip" != "None" ]]; then
        log_info "Connection Information:"
        echo "   SSH: Use EC2 Instance Connect or key pair"
        echo "   Quick connect: ssh -i ~/.ssh/your-key.pem ubuntu@$public_ip"
        echo ""
    fi
    
    # Show cost information
    local uptime_hours
    if [[ "$state" == "running" ]]; then
        uptime_hours=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --query 'Reservations[0].Instances[0].LaunchTime' \
            --output text \
            --region "$AWS_REGION" | xargs -I {} date -d {} +%s)
        uptime_hours=$(( ($(date +%s) - uptime_hours) / 3600 ))
        
        log_info "Cost Information:"
        echo "   Uptime: ~$uptime_hours hours"
        echo "   Approximate cost: Varies by instance type and region"
        echo ""
    fi
    
    # Show management commands
    log_info "Management Commands:"
    case "$state" in
        "running")
            echo "   Stop: $0 stop $instance_name"
            echo "   Restart: $0 restart $instance_name"
            echo "   Terminate: $0 terminate $instance_name"
            echo "   Logs: $0 logs $instance_name"
            ;;
        "stopped")
            echo "   Start: $0 start $instance_name"
            echo "   Terminate: $0 terminate $instance_name"
            ;;
        *)
            echo "   Status: $0 status $instance_name"
            echo "   Terminate: $0 terminate $instance_name"
            ;;
    esac
}

cmd_terminate() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    # Get instance details for confirmation
    local instance_info
    instance_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[State.Name,InstanceType,LaunchTime]' \
        --output text \
        --region "$AWS_REGION")
    
    read -r state type launch_time <<< "$instance_info"
    
    log_warning "⚠️  TERMINATING INSTANCE: $instance_name"
    echo "   Instance ID: $instance_id"
    echo "   Type: $type"
    echo "   State: $state"
    echo "   Launch Time: $launch_time"
    echo ""
    log_warning "This action is PERMANENT and cannot be undone!"
    echo ""
    
    read -p "Are you sure you want to terminate this instance? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled"
        return 0
    fi
    
    log_step "Terminating instance..."
    aws ec2 terminate-instances --instance-ids "$instance_id" --region "$AWS_REGION" >/dev/null
    
    log_success "Instance termination initiated"
    log_info "Instance will be terminated shortly"
    
    # Clean up saved instance info
    rm -f "/tmp/ami-build-${instance_name}.env"
}

cmd_connect() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    log_header "Connection Information: $instance_name"
    
    # Get instance details
    local instance_info
    instance_info=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress,KeyName,SecurityGroups[0].GroupId]' \
        --output text \
        --region "$AWS_REGION")
    
    read -r state public_ip private_ip key_name sg_id <<< "$instance_info"
    
    log_info "Instance Details:"
    echo "   Instance ID: $instance_id"
    echo "   State: $state"
    echo "   Public IP: ${public_ip:-None}"
    echo "   Private IP: $private_ip"
    echo "   Key Pair: ${key_name:-None}"
    echo "   Security Group: $sg_id"
    echo ""
    
    if [[ "$state" != "running" ]]; then
        log_warning "Instance is not running (state: $state)"
        echo "Start it first: $0 start $instance_name"
        return 1
    fi
    
    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        log_warning "No public IP assigned to instance"
        return 1
    fi
    
    log_info "Connection Methods:"
    
    if [[ -n "$key_name" && "$key_name" != "None" ]]; then
        echo "   SSH with key: ssh -i ~/.ssh/$key_name.pem ubuntu@$public_ip"
    fi
    
    echo "   EC2 Instance Connect: Use AWS Console or aws ec2-instance-connect send-ssh-public-key"
    echo ""
    
    log_info "Quick Tests:"
    echo "   Test HTTP: curl http://$public_ip"
    echo "   Test SSH: ssh -o ConnectTimeout=5 ubuntu@$public_ip"
}

cmd_logs() {
    local instance_name="$1"
    local instance_id
    
    instance_id=$(find_instance "$instance_name")
    if [[ $? -ne 0 ]]; then return 1; fi
    
    log_header "Instance Logs: $instance_name"
    
    # Check if SSM is available
    local ssm_status
    ssm_status=$(aws ssm describe-instance-information \
        --filters "Key=InstanceIds,Values=$instance_id" \
        --region "$AWS_REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>/dev/null || echo "")
    
    if [[ "$ssm_status" == "Online" ]]; then
        log_success "SSM agent is online, fetching logs..."
        
        local command_id
        command_id=$(aws ssm send-command \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=[
                "echo === User Data Log ===",
                "tail -50 /var/log/user-data.log 2>/dev/null || echo No user data log found",
                "echo === System Status ===",
                "systemctl status docker --no-pager -l || echo Docker not found",
                "echo === Disk Usage ===",
                "df -h",
                "echo === Memory Usage ===",
                "free -h",
                "echo === Recent System Logs ===",
                "journalctl --since \"30 minutes ago\" --no-pager -n 30 || echo No recent logs"
            ]' \
            --region "$AWS_REGION" \
            --query 'Command.CommandId' \
            --output text)
        
        sleep 3
        
        aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$AWS_REGION" \
            --query 'StandardOutputContent' \
            --output text
    else
        log_warning "SSM agent not available or not online"
        log_info "Alternative options:"
        echo "   1. Use EC2 Instance Connect to SSH and check logs manually"
        echo "   2. Check EC2 console for system logs"
        echo "   3. Wait a few minutes for SSM agent to come online"
    fi
}

cmd_list() {
    log_header "Build Instances"
    
    # Get all instances with Purpose=AMI-Building tag
    local instances
    instances=$(aws ec2 describe-instances \
        --filters "Name=tag:Purpose,Values=AMI-Building" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
        --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,State.Name,InstanceType,PublicIpAddress,LaunchTime]' \
        --output text \
        --region "$AWS_REGION" 2>/dev/null)
    
    if [[ -z "$instances" ]]; then
        log_info "No build instances found"
        return 0
    fi
    
    echo "$instances" | while read -r name instance_id state type public_ip launch_time; do
        # Format launch time
        local formatted_time
        formatted_time=$(date -d "$launch_time" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$launch_time")
        
        # Add status indicator
        local status_icon
        case "$state" in
            "running") status_icon="🟢" ;;
            "stopped") status_icon="🔴" ;;
            "pending") status_icon="🟡" ;;
            "stopping") status_icon="🟠" ;;
            *) status_icon="⚪" ;;
        esac
        
        echo "   $status_icon $name ($instance_id) - $state - $type - ${public_ip:-No IP} - $formatted_time"
    done
    
    echo ""
    log_info "Management Commands:"
    echo "   Status: $0 status <instance-name>"
    echo "   Start/Stop: $0 start|stop <instance-name>"
    echo "   Connect: $0 connect <instance-name>"
    echo "   Terminate: $0 terminate <instance-name>"
}

# Main command dispatcher
case "$COMMAND" in
    "start")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for start command"
            print_usage
            exit 1
        fi
        cmd_start "$INSTANCE_NAME"
        ;;
    "stop")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for stop command"
            print_usage
            exit 1
        fi
        cmd_stop "$INSTANCE_NAME"
        ;;
    "restart")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for restart command"
            print_usage
            exit 1
        fi
        cmd_restart "$INSTANCE_NAME"
        ;;
    "status")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for status command"
            print_usage
            exit 1
        fi
        cmd_status "$INSTANCE_NAME"
        ;;
    "terminate")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for terminate command"
            print_usage
            exit 1
        fi
        cmd_terminate "$INSTANCE_NAME"
        ;;
    "connect")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for connect command"
            print_usage
            exit 1
        fi
        cmd_connect "$INSTANCE_NAME"
        ;;
    "logs")
        if [[ -z "$INSTANCE_NAME" ]]; then
            log_error "Instance name required for logs command"
            print_usage
            exit 1
        fi
        cmd_logs "$INSTANCE_NAME"
        ;;
    "list")
        cmd_list
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_usage
        exit 1
        ;;
esac

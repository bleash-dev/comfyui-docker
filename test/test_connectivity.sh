#!/bin/bash

# Connectivity Diagnosis Script
# Helps diagnose why ComfyUI instances might not be accessible from the internet

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [public-ip] [optional-port]"
    echo ""
    echo "Examples:"
    echo "  $0 1.2.3.4          # Test default ports 80 and 8188"
    echo "  $0 1.2.3.4 8188     # Test specific port"
    echo ""
    echo "This script helps diagnose connectivity issues by testing:"
    echo "  - Basic network connectivity (ping)"
    echo "  - Port accessibility (telnet/nc)"
    echo "  - HTTP response (curl)"
    echo "  - Security group configuration"
}

test_basic_connectivity() {
    local ip="$1"
    
    echo -e "${BLUE}🏓 Testing basic connectivity to $ip...${NC}"
    
    # Test ping (ICMP)
    if ping -c 3 -W 5 "$ip" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Ping successful - basic network connectivity works${NC}"
    else
        echo -e "${YELLOW}⚠️ Ping failed - this is often normal due to ICMP blocking${NC}"
    fi
    
    # Test DNS resolution if hostname provided
    if [[ "$ip" =~ [a-zA-Z] ]]; then
        echo -e "${BLUE}🔍 Testing DNS resolution...${NC}"
        if nslookup "$ip" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ DNS resolution works${NC}"
        else
            echo -e "${RED}❌ DNS resolution failed${NC}"
            return 1
        fi
    fi
}

test_port_connectivity() {
    local ip="$1"
    local port="$2"
    local timeout="${3:-5}"
    
    echo -e "${BLUE}🔌 Testing port $port connectivity...${NC}"
    
    # Test with nc (netcat)
    if command -v nc >/dev/null 2>&1; then
        if timeout "$timeout" nc -z "$ip" "$port" 2>/dev/null; then
            echo -e "${GREEN}✅ Port $port is accessible (nc test)${NC}"
            return 0
        else
            echo -e "${RED}❌ Port $port is NOT accessible (nc test)${NC}"
        fi
    fi
    
    # Test with telnet
    if command -v telnet >/dev/null 2>&1; then
        if timeout "$timeout" bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null; then
            echo -e "${GREEN}✅ Port $port is accessible (telnet test)${NC}"
            return 0
        else
            echo -e "${RED}❌ Port $port is NOT accessible (telnet test)${NC}"
        fi
    fi
    
    # Test with curl for HTTP ports
    if [[ "$port" == "80" || "$port" == "8080" || "$port" == "8188" ]]; then
        echo -e "${BLUE}🌐 Testing HTTP connectivity on port $port...${NC}"
        if timeout "$timeout" curl -s --connect-timeout "$timeout" "http://$ip:$port" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ HTTP service responds on port $port${NC}"
            return 0
        else
            echo -e "${RED}❌ HTTP service does not respond on port $port${NC}"
        fi
    fi
    
    return 1
}

test_http_response() {
    local ip="$1"
    local port="$2"
    
    echo -e "${BLUE}🌐 Testing HTTP response from $ip:$port...${NC}"
    
    local url="http://$ip:$port"
    
    # Get HTTP response
    local response
    response=$(curl -s -w "HTTPSTATUS:%{http_code}\nREDIRECT_URL:%{redirect_url}\nRESPONSE_TIME:%{time_total}" \
        --connect-timeout 10 \
        --max-time 30 \
        "$url" 2>/dev/null || echo "FAILED")
    
    if [[ "$response" == "FAILED" ]]; then
        echo -e "${RED}❌ Failed to connect to $url${NC}"
        return 1
    fi
    
    local http_code
    http_code=$(echo "$response" | grep "HTTPSTATUS:" | cut -d: -f2)
    
    local response_time
    response_time=$(echo "$response" | grep "RESPONSE_TIME:" | cut -d: -f2)
    
    local body
    body=$(echo "$response" | sed '/HTTPSTATUS:/d; /REDIRECT_URL:/d; /RESPONSE_TIME:/d')
    
    echo -e "${BLUE}📊 HTTP Response Details:${NC}"
    echo "   Status Code: $http_code"
    echo "   Response Time: ${response_time}s"
    
    case "$http_code" in
        200)
            echo -e "${GREEN}✅ Success! Service is responding properly${NC}"
            if [[ "${#body}" -gt 0 && "${#body}" -lt 500 ]]; then
                echo -e "${BLUE}📄 Response preview:${NC}"
                echo "$body" | head -5
            fi
            return 0
            ;;
        301|302|307|308)
            echo -e "${YELLOW}⚠️ Redirect response - service may be running but redirecting${NC}"
            ;;
        404)
            echo -e "${YELLOW}⚠️ Service is running but endpoint not found${NC}"
            ;;
        500|502|503|504)
            echo -e "${YELLOW}⚠️ Service is accessible but has internal errors${NC}"
            ;;
        000)
            echo -e "${RED}❌ Connection refused or timed out${NC}"
            ;;
        *)
            echo -e "${YELLOW}⚠️ Unexpected HTTP status: $http_code${NC}"
            ;;
    esac
    
    return 1
}

check_security_group_for_ip() {
    local public_ip="$1"
    
    echo -e "${BLUE}🔍 Looking up security group for IP $public_ip...${NC}"
    
    # Find instance by public IP
    local instance_id
    instance_id=$(aws ec2 describe-instances \
        --filters "Name=ip-address,Values=$public_ip" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --region us-east-1 2>/dev/null || echo "")
    
    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        echo -e "${YELLOW}⚠️ Could not find instance with public IP $public_ip in us-east-1${NC}"
        echo -e "${BLUE}💡 You can manually check security groups if you know the instance ID${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Found instance: $instance_id${NC}"
    
    # Get security groups
    local sg_ids
    sg_ids=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
        --output text \
        --region us-east-1)
    
    echo -e "${BLUE}🔒 Security Groups: $sg_ids${NC}"
    
    # Check security group rules
    for sg_id in $sg_ids; do
        echo -e "${BLUE}📋 Rules for Security Group $sg_id:${NC}"
        
        aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].IpPermissions[*].[IpProtocol,FromPort,ToPort,IpRanges[0].CidrIp,Description]' \
            --output table \
            --region us-east-1 2>/dev/null || echo "Could not retrieve rules"
        
        # Check for common ports
        echo -e "${BLUE}🔍 Checking for common ports in $sg_id:${NC}"
        
        local rules
        rules=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --query 'SecurityGroups[0].IpPermissions[*].[FromPort,ToPort,IpProtocol,IpRanges[*].CidrIp]' \
            --output text \
            --region us-east-1 2>/dev/null || echo "")
        
        # Check for port 80
        if echo "$rules" | grep -q -E "80\s+80\s+tcp.*0\.0\.0\.0/0"; then
            echo -e "${GREEN}   ✅ Port 80 (HTTP) is open to 0.0.0.0/0${NC}"
        else
            echo -e "${RED}   ❌ Port 80 (HTTP) is not open to the internet${NC}"
        fi
        
        # Check for port 8188
        if echo "$rules" | grep -q -E "8188\s+8188\s+tcp.*0\.0\.0\.0/0"; then
            echo -e "${GREEN}   ✅ Port 8188 (ComfyUI) is open to 0.0.0.0/0${NC}"
        else
            echo -e "${RED}   ❌ Port 8188 (ComfyUI) is not open to the internet${NC}"
        fi
        
        # Check for SSH
        if echo "$rules" | grep -q -E "22\s+22\s+tcp"; then
            echo -e "${GREEN}   ✅ Port 22 (SSH) is available${NC}"
        else
            echo -e "${YELLOW}   ⚠️ Port 22 (SSH) is not open${NC}"
        fi
    done
}

perform_comprehensive_test() {
    local ip="$1"
    local port="${2:-}"
    
    echo -e "${BLUE}🔬 Comprehensive Connectivity Test for $ip${NC}"
    echo "=================================================="
    
    # Test basic connectivity
    test_basic_connectivity "$ip"
    echo ""
    
    # Test specific port if provided
    if [[ -n "$port" ]]; then
        test_port_connectivity "$ip" "$port"
        if [[ "$port" == "80" || "$port" == "8080" || "$port" == "8188" ]]; then
            echo ""
            test_http_response "$ip" "$port"
        fi
    else
        # Test common ports
        echo -e "${BLUE}🔌 Testing common ports...${NC}"
        
        # Test HTTP (80)
        echo ""
        echo -e "${BLUE}--- Testing Port 80 (HTTP) ---${NC}"
        if test_port_connectivity "$ip" "80"; then
            test_http_response "$ip" "80"
        fi
        
        # Test ComfyUI (8188)
        echo ""
        echo -e "${BLUE}--- Testing Port 8188 (ComfyUI) ---${NC}"
        if test_port_connectivity "$ip" "8188"; then
            test_http_response "$ip" "8188"
        fi
    fi
    
    echo ""
    
    # Check security groups if possible
    if command -v aws >/dev/null 2>&1; then
        check_security_group_for_ip "$ip"
    else
        echo -e "${YELLOW}⚠️ AWS CLI not available - cannot check security groups${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}🎯 Summary and Recommendations:${NC}"
    echo "============================================="
    
    # Test results summary
    local port80_works=false
    local port8188_works=false
    
    if timeout 5 nc -z "$ip" 80 2>/dev/null || timeout 5 bash -c "echo >/dev/tcp/$ip/80" 2>/dev/null; then
        port80_works=true
    fi
    
    if timeout 5 nc -z "$ip" 8188 2>/dev/null || timeout 5 bash -c "echo >/dev/tcp/$ip/8188" 2>/dev/null; then
        port8188_works=true
    fi
    
    if [[ "$port80_works" == true && "$port8188_works" == true ]]; then
        echo -e "${GREEN}🎉 All tests passed! Instance is fully accessible.${NC}"
    elif [[ "$port80_works" == true ]]; then
        echo -e "${YELLOW}⚠️ Basic web server works, but ComfyUI port 8188 is not accessible.${NC}"
        echo -e "${BLUE}💡 Check:${NC}"
        echo "   1. ComfyUI service is running on the instance"
        echo "   2. Security group allows port 8188 from 0.0.0.0/0"
        echo "   3. Instance firewall (ufw/iptables) allows port 8188"
    elif [[ "$port8188_works" == true ]]; then
        echo -e "${YELLOW}⚠️ ComfyUI port works, but basic web server (port 80) is not accessible.${NC}"
        echo -e "${BLUE}💡 This might be normal if only ComfyUI is needed.${NC}"
    else
        echo -e "${RED}❌ Neither port is accessible. Possible issues:${NC}"
        echo -e "${BLUE}💡 Check:${NC}"
        echo "   1. Instance is running and has a public IP"
        echo "   2. Security group allows inbound traffic on ports 80 and 8188"
        echo "   3. Network ACLs allow traffic"
        echo "   4. Route table has internet gateway route"
        echo "   5. Instance has services running on these ports"
        echo "   6. Instance OS firewall is not blocking ports"
    fi
    
    echo ""
    echo -e "${BLUE}🛠️ Next Steps:${NC}"
    echo "   • If using test instance script: ./scripts/test_instance.sh logs [instance-name]"
    echo "   • Check AWS Console → EC2 → Security Groups"
    echo "   • Check AWS Console → VPC → Network ACLs"
    echo "   • Check AWS Console → VPC → Route Tables"
    echo "   • SSH to instance and check: sudo netstat -tlnp"
}

# Main script
if [[ $# -eq 0 ]]; then
    print_usage
    exit 1
fi

PUBLIC_IP="$1"
PORT="${2:-}"

if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}❌ Public IP address required${NC}"
    print_usage
    exit 1
fi

perform_comprehensive_test "$PUBLIC_IP" "$PORT"

#!/bin/bash
# Usage: ./validate_eni_cleanup.sh <eni-id> <region>

if [ $# -ne 2 ]; then
    echo "Usage: $0 <eni-id> <region>"
    exit 1
fi

ENI_ID="$1"
REGION="$2"

echo "Getting ENI details..."
ENI_DETAILS=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI_ID" --region "$REGION" --query 'NetworkInterfaces[0].{SubnetId:SubnetId,SecurityGroups:Groups[*].GroupId}' --output json 2>/dev/null)

if [ $? -ne 0 ] || [ "$ENI_DETAILS" = "null" ]; then
    echo "❌ ERROR: Could not retrieve ENI details for $ENI_ID"
    exit 1
fi

ENI_SUBNET=$(echo "$ENI_DETAILS" | jq -r '.SubnetId')
ENI_SG=$(echo "$ENI_DETAILS" | jq -r '.SecurityGroups[0]')

echo "Checking service-linked role..."
SLR_CHECK=$(aws iam get-role --role-name AWSServiceRoleForBedrockAgentCoreNetwork --region "$REGION" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Service-linked role AWSServiceRoleForBedrockAgentCoreNetwork not found"
    echo "SOLUTION: Create a new agent in VPC mode to automatically create the service-linked role"
    exit 1
fi
echo "✅ Service-linked role exists"

echo ""
echo "Checking for VPC configuration overlaps..."
echo "ENI ID: $ENI_ID"
echo "ENI Subnet: $ENI_SUBNET"
echo "ENI Security Group: $ENI_SG"
echo ""

# Get all agent runtimes
AGENTS=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" --query 'agentRuntimes[*].agentRuntimeId' --output text)

if [ -z "$AGENTS" ]; then
    echo "✅ No active agents found - safe to proceed with cleanup"
    exit 0
fi

echo "Found active agents. Checking VPC configurations..."
OVERLAP_FOUND=false

for AGENT_ID in $AGENTS; do
    echo "Checking agent: $AGENT_ID"
    
    # Get agent runtime details
    NETWORK_CONFIG=$(aws bedrock-agentcore-control get-agent-runtime \
        --agent-runtime-id "$AGENT_ID" \
        --region "$REGION" \
        --query 'networkConfiguration' \
        --output json 2>/dev/null)
    
    if [ "$NETWORK_CONFIG" != "null" ] && [ -n "$NETWORK_CONFIG" ]; then
        NETWORK_MODE=$(echo "$NETWORK_CONFIG" | jq -r '.networkMode' 2>/dev/null)
        
        if [ "$NETWORK_MODE" = "VPC" ]; then
            AGENT_SUBNETS=$(echo "$NETWORK_CONFIG" | jq -r '.networkModeConfig.subnets[]?' 2>/dev/null)
            AGENT_SGS=$(echo "$NETWORK_CONFIG" | jq -r '.networkModeConfig.securityGroups[]?' 2>/dev/null)
            
            # Check for subnet overlap
            if echo "$AGENT_SUBNETS" | grep -q "$ENI_SUBNET"; then
                # Check for security group overlap
                if echo "$AGENT_SGS" | grep -q "$ENI_SG"; then
                    echo "❌ OVERLAP FOUND: Agent $AGENT_ID uses same subnet ($ENI_SUBNET) and security group ($ENI_SG)"
                    OVERLAP_FOUND=true
                fi
            fi
        fi
    fi
done

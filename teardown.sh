#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/.deploy_state" 2>/dev/null || true
export AWS_DEFAULT_REGION="$REGION"

echo "🧹 Starting teardown..."

# -------------------------------
# Helpers
# -------------------------------
exists_asg() {
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$1" \
    --query 'AutoScalingGroups[0].AutoScalingGroupName' \
    --output text 2>/dev/null | grep -q "$1"
}

exists_alb() {
  aws elbv2 describe-load-balancers \
    --load-balancer-arns "$1" >/dev/null 2>&1
}

exists_tg() {
  aws elbv2 describe-target-groups \
    --target-group-arns "$1" >/dev/null 2>&1
}

exists_listener() {
  aws elbv2 describe-listeners \
    --listener-arns "$1" >/dev/null 2>&1
}

exists_lt() {
  aws ec2 describe-launch-templates \
    --launch-template-names "$1" >/dev/null 2>&1
}

exists_rds() {
  aws rds describe-db-instances \
    --db-instance-identifier "$1" >/dev/null 2>&1
}

exists_subnet_group() {
  aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$1" >/dev/null 2>&1
}

exists_dynamodb_table() {
  aws dynamodb describe-table \
    --table-name "$1" >/dev/null 2>&1
}    


# -------------------------------
# ASG
# -------------------------------
if [ -n "${ASG_NAME:-}" ] && exists_asg "$ASG_NAME"; then
  echo "Terminating ASG instances..."

  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --min-size 0 \
    --desired-capacity 0

  echo "Waiting for instances to terminate..."
  while true; do
    COUNT=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --query 'AutoScalingGroups[0].Instances | length(@)' \
      --output text)

    [ "$COUNT" = "0" ] && break
    echo "Instances remaining: $COUNT — waiting..."
    sleep 15
  done

  echo "Deleting ASG: $ASG_NAME"
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --force-delete
else
  echo "ASG not found, skipping..."
fi

# -------------------------------
# Launch Template
# -------------------------------
if [ -n "${LT_NAME:-}" ] && exists_lt "$LT_NAME"; then
  echo "Deleting Launch Template: $LT_NAME"
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME"
else
  echo "Launch Template not found, skipping..."
fi

# -------------------------------
# ALB + Listener
# -------------------------------
if [ -n "${LISTENER_ARN:-}" ] && exists_listener "$LISTENER_ARN"; then
  echo "Deleting ALB listener"
  aws elbv2 delete-listener --listener-arn "$LISTENER_ARN"
else
  echo "Listener not found, skipping..."
fi

if [ -n "${ALB_ARN:-}" ] && exists_alb "$ALB_ARN"; then
  echo "Deleting ALB: $ALB_ARN"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"

  echo "Waiting for ALB deletion..."
  while exists_alb "$ALB_ARN"; do
    echo "ALB still deleting..."
    sleep 10
  done
else
  echo "ALB not found, skipping..."
fi

# -------------------------------
# Target Group
# -------------------------------
if [ -n "${TG_ARN:-}" ] && exists_tg "$TG_ARN"; then
  echo "Deleting target group: $TG_ARN"
  aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
else
  echo "Target group not found, skipping..."
fi

# -------------------------------
# RDS
# -------------------------------
if [ -n "${DB_INSTANCE_ID:-}" ] && exists_rds "$DB_INSTANCE_ID"; then
  echo "Deleting RDS: $DB_INSTANCE_ID"
  aws rds delete-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --final-db-snapshot-identifier "week14-final-snapshot-$(date +%Y%m%d)" \
    --delete-automated-backups
  
  echo "⏳ Waiting for RDS deletion (3-5 min)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID"
else
  echo "RDS not found, skipping..."
fi

# -------------------------------
# Subnet Group
# -------------------------------
if [ -n "${DB_SUBNET_GROUP_NAME:-}" ] && exists_subnet_group "$DB_SUBNET_GROUP_NAME"; then
  echo "Deleting subnet group: $DB_SUBNET_GROUP_NAME"
  aws rds delete-db-subnet-group \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME"
else
  echo "Subnet group not found, skipping..."
fi

# -------------------------------
# DynamoDB table
# -------------------------------
if [ -n "${DYNAMODB_TABLE_NAME:-}" ] && exists_dynamodb_table "$DYNAMODB_TABLE_NAME"; then
  echo "Deleting dynamodb table: $DYNAMODB_TABLE_NAME"
  aws dynamodb delete-table \
    --table-name "$DYNAMODB_TABLE_NAME"
else
  echo "Dynamodb table not found, skipping..."
fi

# -------------------------------
# S3 Bucket
# -------------------------------
if [ -n "${BUCKET_NAME:-}" ]; then
  echo "Deleting S3 bucket contents: $BUCKET_NAME"
  aws s3 rm "s3://$BUCKET_NAME" --recursive 2>/dev/null || true

  echo "Deleting S3 bucket: $BUCKET_NAME"
  aws s3 rb "s3://$BUCKET_NAME" 2>/dev/null || true
else
  echo "S3 bucket not found, skipping..."
fi

# -------------------------------
# NAT Gateway
# -------------------------------
if [ -n "${NAT_ID:-}" ]; then
  echo "Deleting NAT gateway: $NAT_ID"
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_ID" >/dev/null 2>&1 || true

  echo "Waiting for NAT deletion..."
  while true; do
    STATE=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' \
      --output text 2>/dev/null || echo "deleted")

    [ "$STATE" = "deleted" ] && break
    echo "NAT state: $STATE — waiting..."
    sleep 10
  done
else
  echo "NAT not found, skipping..."
fi

# -------------------------------
# Elastic IP
# -------------------------------
if [ -n "${ALLOCATION_ID:-}" ]; then
  echo "Releasing Elastic IP"
  aws ec2 release-address --allocation-id "$ALLOCATION_ID" 2>/dev/null || true
fi

# -------------------------------
# Bastion Instance
# -------------------------------
if [ -n "${BASTION_INSTANCE_ID:-}" ]; then
  echo "Terminating bastion instance: $BASTION_INSTANCE_ID"

  aws ec2 terminate-instances \
    --instance-ids "$BASTION_INSTANCE_ID" \
    >/dev/null 2>&1 || true

  aws ec2 wait instance-terminated \
    --instance-ids "$BASTION_INSTANCE_ID" \
    >/dev/null 2>&1 || true
else
  echo "Bastion instance not found, skipping..."
fi

# -------------------------------
# Security Groups
# -------------------------------
if [ -n "${RDS_SG_ID:-}" ]; then
  echo "Deleting RDS SG"
  aws ec2 delete-security-group --group-id "$RDS_SG_ID" >/dev/null 2>&1 || true
fi

if [ -n "${APP_SG_ID:-}" ]; then
  echo "Deleting App SG"
  aws ec2 delete-security-group --group-id "$APP_SG_ID" >/dev/null 2>&1 || true
fi

if [ -n "${ALB_SG_ID:-}" ]; then
  echo "Deleting ALB SG"
  aws ec2 delete-security-group --group-id "$ALB_SG_ID" >/dev/null 2>&1 || true
fi

if [ -n "${BASTION_SG_ID:-}" ]; then
  echo "Deleting bastion SG"
  aws ec2 delete-security-group --group-id "$BASTION_SG_ID" >/dev/null 2>&1 || true
fi

# -------------------------------
# Route Tables
# -------------------------------
echo "Deleting route tables..."

aws ec2 disassociate-route-table --association-id "${PRIVATE_RT_ASSOC_1_ID:-}" 2>/dev/null || true
aws ec2 disassociate-route-table --association-id "${PRIVATE_RT_ASSOC_2_ID:-}" 2>/dev/null || true
aws ec2 delete-route-table --route-table-id "${PRIVATE_ROUTE_TABLE_ID:-}" 2>/dev/null || true

aws ec2 disassociate-route-table --association-id "${PUBLIC_RT_ASSOC_1_ID:-}" 2>/dev/null || true
aws ec2 disassociate-route-table --association-id "${PUBLIC_RT_ASSOC_2_ID:-}" 2>/dev/null || true
aws ec2 delete-route-table --route-table-id "${PUBLIC_ROUTE_TABLE_ID:-}" 2>/dev/null || true

# -------------------------------
# IGW
# -------------------------------
if [ -n "${IGW_ID:-}" ]; then
  echo "Deleting IGW"
  aws ec2 detach-internet-gateway \
    --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" 2>/dev/null || true

  aws ec2 delete-internet-gateway \
    --internet-gateway-id "$IGW_ID" 2>/dev/null || true
fi

# -------------------------------
# Subnets
# -------------------------------
echo "Deleting subnets..."
for subnet in \
  ${PUBLIC_SUBNET_1_ID:-} \
  ${PUBLIC_SUBNET_2_ID:-} \
  ${PRIVATE_SUBNET_1_ID:-} \
  ${PRIVATE_SUBNET_2_ID:-}; do

  [ -n "$subnet" ] && aws ec2 delete-subnet --subnet-id "$subnet" 2>/dev/null || true
done

# -------------------------------
# VPC
# -------------------------------
if [ -n "${VPC_ID:-}" ]; then
  echo "Deleting VPC: $VPC_ID"
  aws ec2 delete-vpc --vpc-id "$VPC_ID" 2>/dev/null || true
fi

# -------------------------------
# Key Pair
# -------------------------------
if [ -n "${KEY_NAME:-}" ]; then
  echo "Deleting key pair: $KEY_NAME"
  aws ec2 delete-key-pair --key-name "$KEY_NAME" 2>/dev/null || true
fi

# -------------------------------
# IAM Role and Instance Profile
# -------------------------------
if [ -n "${IAM_INSTANCE_PROFILE_NAME:-}" ]; then
  echo "Removing role from instance profile..."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
    --role-name "$IAM_ROLE_NAME" \
    >/dev/null 2>&1 || true

  echo "Deleting instance profile..."
  aws iam delete-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
    >/dev/null 2>&1 || true
fi

if [ -n "${IAM_ROLE_NAME:-}" ]; then
  echo "Detaching policies from IAM role..."

  aws iam detach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
    >/dev/null 2>&1 || true

  aws iam detach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess \
    >/dev/null 2>&1 || true

  aws iam delete-role \
    --role-name "$IAM_ROLE_NAME" \
    >/dev/null 2>&1 || true
fi

# -------------------------------
# Cleanup
# -------------------------------
rm -f "$SCRIPT_DIR/.deploy_state"

# Only delete .pem if VPC is confirmed deleted
if [ -z "$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" 2>/dev/null)" ]; then
    rm -f "$SCRIPT_DIR/$KEY_NAME.pem"
    echo "🔑 Key file removed"
fi

echo "🗑️ Cleanup completed successfully!"

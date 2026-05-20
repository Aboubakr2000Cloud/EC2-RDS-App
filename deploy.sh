#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/.deploy_state" 2>/dev/null || true
export AWS_DEFAULT_REGION="$REGION"

run_part_a() {

  echo "Deploying infrastructure..."

  # Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --query 'Vpc.VpcId' \
  --output text \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=week14-database},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
echo "VPC created: $VPC_ID"  

# Enable DNS hostnames and support
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support

# Create IGW
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --tag-specifications "ResourceType=internet-gateway,Tags=[
    {Key=Name,Value=week14-igw},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Attach to VPC
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

# Create public subnet 1
PUBLIC_SUBNET_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_1_CIDR" \
  --availability-zone "$AZ_1" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week14-public-subnet-1},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Create public subnet 2
PUBLIC_SUBNET_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PUBLIC_SUBNET_2_CIDR" \
  --availability-zone "$AZ_2" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week14-public-subnet-2},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
echo "Public subnets: $PUBLIC_SUBNET_1_ID, $PUBLIC_SUBNET_2_ID"

# Create private subnet 1
PRIVATE_SUBNET_1_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_1_CIDR" \
  --availability-zone "$AZ_1" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week14-private-subnet-1},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Create private subnet 2
PRIVATE_SUBNET_2_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_SUBNET_2_CIDR" \
  --availability-zone "$AZ_2" \
  --query 'Subnet.SubnetId' \
  --output text \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=week14-private-subnet-2},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")

echo "Private subnets: $PRIVATE_SUBNET_1_ID, $PRIVATE_SUBNET_2_ID"

# Enable auto-assign public IP on public subnet 1
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --map-public-ip-on-launch
  
# Enable auto-assign public IP on public subnet 2
aws ec2 modify-subnet-attribute \
  --subnet-id "$PUBLIC_SUBNET_2_ID" \
  --map-public-ip-on-launch
  
# Create public route table
PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week14-public-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]" 2>/dev/null)

echo "Public route table: $PUBLIC_ROUTE_TABLE_ID"

# Add 0.0.0.0/0 route to IGW
aws ec2 create-route \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID"
  
# Associate public route table with public subnets
PUBLIC_RT_ASSOC_1_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --query 'AssociationId' \
  --output text)

PUBLIC_RT_ASSOC_2_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_2_ID" \
  --query 'AssociationId' \
  --output text)
  
# Allocate an Elastic IP for the NAT Gateway
ALLOCATION_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)
  
# Tag elastic IP
aws ec2 create-tags \
  --resources "$ALLOCATION_ID" \
  --tags Key=Name,Value=week14-eip \
         Key=Project,Value=$PROJECT_TAG \
         Key=Week,Value=$WEEK_TAG
         
# Create NAT Gateway in public subnet 1
NAT_ID=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUBLIC_SUBNET_1_ID" \
  --allocation-id "$ALLOCATION_ID" \
  --query 'NatGateway.NatGatewayId' \
  --output text \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=week14-nat},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]")
  
# Wait for the NAT Gateway to be available
echo "Waiting for NAT Gateway to become available..."

while true; do
    STATE=$(aws ec2 describe-nat-gateways \
      --nat-gateway-ids "$NAT_ID" \
      --query 'NatGateways[0].State' \
      --output text)
    [ "$STATE" = "available" ] && break
    echo "NAT state: $STATE — waiting..."
    sleep 10
done  
 
echo "NAT Gateway: $NAT_ID (available)" 
 
# Create private route table
PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=week14-private-rt},
    {Key=Project,Value=$PROJECT_TAG},
    {Key=Week,Value=$WEEK_TAG}
  ]" 2>/dev/null)

echo "Private route table: $PRIVATE_ROUTE_TABLE_ID"

# Add 0.0.0.0/0 route to NAT
aws ec2 create-route \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id "$NAT_ID"
  
# Associate private route table with private subnets
PRIVATE_RT_ASSOC_1_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_1_ID" \
  --query 'AssociationId' \
  --output text)
  
PRIVATE_RT_ASSOC_2_ID=$(aws ec2 associate-route-table \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_2_ID" \
  --query 'AssociationId' \
  --output text)  
  
# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
EOF
}

if [ -f "$SCRIPT_DIR/.deploy_state" ]; then
  echo "Infrastructure already exists. Loading state..."
else
  run_part_a
fi

source "$SCRIPT_DIR/.deploy_state"

run_part_b() {

: "${VPC_ID:?Missing VPC_ID}"

MY_IP=$(curl -s checkip.amazonaws.com)

  BASTION_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$BASTION_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

  if [ "$BASTION_SG_ID" = "None" ]; then
     echo "Creating Bastion SG..."
  
     BASTION_SG_ID=$(aws ec2 create-security-group \
     --vpc-id "$VPC_ID" \
     --group-name "$BASTION_SG_NAME" \
     --description "Week 12 Bastion SG" \
     --query 'GroupId' \
     --output text)

     aws ec2 create-tags \
       --resources "$BASTION_SG_ID" \
       --tags Key=Name,Value=week14-bastion-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null

     aws ec2 authorize-security-group-ingress \
       --group-id "$BASTION_SG_ID" \
       --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null
  fi
  
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$ALB_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
  
  if [ "$ALB_SG_ID" = "None" ]; then
     echo "Creating Application load balancer SG..."
  
     ALB_SG_ID=$(aws ec2 create-security-group \
     --vpc-id "$VPC_ID" \
     --group-name "$ALB_SG_NAME" \
     --description "Week 14 Application load balancer SG" \
     --query 'GroupId' \
     --output text)

     aws ec2 create-tags \
       --resources "$ALB_SG_ID" \
       --tags Key=Name,Value=week14-ALB-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null

     aws ec2 authorize-security-group-ingress \
       --group-id "$ALB_SG_ID" \
       --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
       
      aws ec2 authorize-security-group-ingress \
       --group-id "$ALB_SG_ID" \
       --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null
  fi

echo "ALB SG: $ALB_SG_ID"

APP_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$APP_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

  if [ "$APP_SG_ID" = "None" ]; then
    echo "Creating App SG..."

    APP_SG_ID=$(aws ec2 create-security-group \
      --vpc-id "$VPC_ID" \
      --group-name "$APP_SG_NAME" \
      --description "Week 14 App SG" \
      --query 'GroupId' \
      --output text)

    aws ec2 create-tags \
      --resources "$APP_SG_ID" \
      --tags Key=Name,Value=week14-app-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SG_ID" \
      --protocol tcp --port 80 --source-group "$ALB_SG_ID" >/dev/null

    aws ec2 authorize-security-group-ingress \
      --group-id "$APP_SG_ID" \
      --protocol tcp --port 22 --source-group "$BASTION_SG_ID" >/dev/null

  fi

echo "APP SG: $APP_SG_ID"

RDS_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$RDS_SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
  
  if [ "$RDS_SG_ID" = "None" ]; then
    echo "Creating RDS SG..."
    
    RDS_SG_ID=$(aws ec2 create-security-group \
      --group-name "$RDS_SG_NAME" \
      --description "Week 14 RDS SG" \
      --vpc-id "$VPC_ID" \
      --query 'GroupId' --output text)
  
    aws ec2 create-tags \
      --resources "$RDS_SG_ID" \
      --tags Key=Name,Value=week14-rds-sg Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG" >/dev/null
      
    aws ec2 authorize-security-group-ingress \
      --group-id "$RDS_SG_ID" --protocol tcp --port 3306 --source-group "$APP_SG_ID" >/dev/null
  fi
  
echo "RDS SG: $RDS_SG_ID"

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
ALB_SG_ID="$ALB_SG_ID"
APP_SG_ID="$APP_SG_ID"
RDS_SG_ID="$RDS_SG_ID"

PART_B_DONE=true
EOF
sleep 15
}

if [ "${PART_B_DONE:-false}" = "true" ]; then
  echo "Security groups already exists. Loading state..."
else
  run_part_b
fi

run_part_c() {

  : "${ALB_SG_ID:?Missing ALB_SG_ID}"
  : "${PRIVATE_SUBNET_1_ID:?Missing PUBLIC_SUBNET_1_ID}"
  : "${PRIVATE_SUBNET_2_ID:?Missing PUBLIC_SUBNET_2_ID}"
  : "${VPC_ID:?Missing VPC_ID}"
  : "${RDS_SG_ID:?Missing RDS_SG_ID}"
  
# Check if DB Subnet Group already exists
if aws rds describe-db-subnet-groups \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    >/dev/null 2>&1; then
    echo "DB Subnet Group already exists."
else
    echo "Creating DB Subnet Group..."
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --db-subnet-group-description "Week 14 DB subnets" \
        --subnet-ids "$PRIVATE_SUBNET_1_ID" "$PRIVATE_SUBNET_2_ID"
fi

# Check if RDS instance already exists
if aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    >/dev/null 2>&1; then
    echo "RDS instance already exists."
else
    echo "Creating RDS instance..."
    aws rds create-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine "$DB_ENGINE" \
        --engine-version "$DB_ENGINE_VERSION" \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASSWORD" \
        --db-name "$DB_NAME" \
        --allocated-storage "$DB_ALLOCATED_STORAGE" \
        --storage-type gp3 \
        --vpc-security-group-ids "$RDS_SG_ID" \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --no-multi-az \
        --no-publicly-accessible \
        --backup-retention-period 1 \
        --tags Key=Project,Value="$PROJECT_TAG" Key=Week,Value="$WEEK_TAG"
fi

# Wait for RDS to be available
echo "⏳ Waiting for RDS (this takes 5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"

# Get the RDS endpoint
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_INSTANCE_ID" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
echo "✅ RDS endpoint: $RDS_ENDPOINT"

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "S3 bucket already exists: $BUCKET_NAME"
else
    echo "Creating S3 bucket: $BUCKET_NAME"

    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
fi

aws s3 cp "$SCRIPT_DIR/app/" "s3://$BUCKET_NAME/app/" --recursive
aws s3 cp "$SCRIPT_DIR/migrations/" "s3://$BUCKET_NAME/migrations/" --recursive

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
ALB_SG_ID="$ALB_SG_ID"
APP_SG_ID="$APP_SG_ID"
RDS_SG_ID="$RDS_SG_ID"
# ---- Part C ----
DB_SUBNET_GROUP_NAME="$DB_SUBNET_GROUP_NAME"
RDS_ENDPOINT="$RDS_ENDPOINT"
DB_INSTANCE_ID="$DB_INSTANCE_ID"

PART_B_DONE=true
PART_C_DONE=true
EOF
}

if [ "${PART_C_DONE:-false}" = "true" ]; then
  echo "RDS already exists. Loading state..."
else
  run_part_c
fi

run_part_d() {

  : "${ALB_SG_ID:?Missing ALB_SG_ID}"
  : "${BASTION_SG_ID:?Missing BASTION_SG_ID}"
  : "${PUBLIC_SUBNET_1_ID:?Missing PUBLIC_SUBNET_1_ID}"
  : "${PUBLIC_SUBNET_2_ID:?Missing PUBLIC_SUBNET_2_ID}"
  : "${PRIVATE_SUBNET_1_ID:?Missing PRIVATE_SUBNET_1_ID}"
  : "${PRIVATE_SUBNET_2_ID:?Missing PRIVATE_SUBNET_2_ID}"
  : "${VPC_ID:?Missing VPC_ID}"
  : "${ALB_NAME:?Missing ALB_NAME}"
  : "${LT_NAME:?Missing LT_NAME}"
  : "${ASG_NAME:?Missing ASG_NAME}"
  : "${RDS_ENDPOINT:?Missing RDS_ENDPOINT}"

# Create key pair
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text > "$KEY_NAME.pem"
  chmod 400 "$KEY_NAME.pem"
fi

# Substitute real values into userdata template
export DB_HOST="$RDS_ENDPOINT"
export DB_USER="$DB_USER"
export DB_PASSWORD="$DB_PASSWORD"
export DB_NAME="$DB_NAME"
export BUCKET_NAME="$BUCKET_NAME"
envsubst < "$SCRIPT_DIR/userdata.sh" > /tmp/userdata_rendered.sh
USER_DATA_B64=$(base64 -w0 /tmp/userdata_rendered.sh)
rm /tmp/userdata_rendered.sh

# Try to find an existing bastion instance
BASTION_INSTANCE_ID=$(aws ec2 describe-instances \
    --filters \
        "Name=tag:Name,Values=${PROJECT_TAG}-bastion" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

if [[ -n "$BASTION_INSTANCE_ID" && "$BASTION_INSTANCE_ID" != "None" ]]; then
    echo "Bastion already exists: $BASTION_INSTANCE_ID"
else
    echo "Creating bastion host..."

    BASTION_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$BASTION_SG_ID" \
        --subnet-id "$PUBLIC_SUBNET_1_ID" \
        --associate-public-ip-address \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}-bastion},{Key=Project,Value=${PROJECT_TAG}},{Key=Week,Value=${WEEK_TAG}}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    aws ec2 wait instance-running --instance-ids "$BASTION_INSTANCE_ID"

    echo "Bastion created: $BASTION_INSTANCE_ID"
fi

echo "Ensuring DynamoDB table exists..."

if ! aws dynamodb describe-table \
    --table-name week14-api-logs \
    --region "$REGION" \
    >/dev/null 2>&1; then

    aws dynamodb create-table \
      --table-name week14-api-logs \
      --attribute-definitions \
          AttributeName=endpoint,AttributeType=S \
          AttributeName=timestamp,AttributeType=S \
      --key-schema \
          AttributeName=endpoint,KeyType=HASH \
          AttributeName=timestamp,KeyType=RANGE \
      --billing-mode PAY_PER_REQUEST \
      --region "$REGION"

    aws dynamodb wait table-exists \
      --table-name week14-api-logs \
      --region "$REGION"

    echo "DynamoDB table created."
else
    echo "DynamoDB table already exists."
fi

echo "Ensuring IAM role and instance profile exist..."

# Create trust policy file
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create IAM role if missing
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    aws iam create-role \
      --role-name "$IAM_ROLE_NAME" \
      --assume-role-policy-document file:///tmp/trust-policy.json
fi

# Attach S3 read policy
aws iam attach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess \
  >/dev/null 2>&1 || true
  
# Create temporary DynamoDB policy file
cat > /tmp/dynamodb-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:${REGION}:*:table/week14-*"
    }
  ]
}
EOF

# Attach inline policy to EC2 IAM role
aws iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "DynamoDBAccessPolicy" \
  --policy-document file:///tmp/dynamodb-policy.json  

# Create instance profile if missing
if ! aws iam get-instance-profile \
    --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
    >/dev/null 2>&1; then

    aws iam create-instance-profile \
      --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME"

    aws iam add-role-to-instance-profile \
      --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" \
      --role-name "$IAM_ROLE_NAME"
fi

# Allow IAM propagation
sleep 15

# Cleanup temporary file
rm -f /tmp/trust-policy.json
rm -f /tmp/dynamodb-policy.json

# Create Launch Template
LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text 2>/dev/null || echo "None") 
  
if [ "$LT_ID" = "None" ]; then
  echo "Creating launch template"

# Base64-encode userdata for the launch template
LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "$LT_NAME" \
  --version-description "v1" \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --output text \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$INSTANCE_TYPE\",
    \"KeyName\": \"$KEY_NAME\",
    \"SecurityGroupIds\": [\"$APP_SG_ID\"],
    \"IamInstanceProfile\": {
      \"Name\": \"$IAM_INSTANCE_PROFILE_NAME\"
    },
    \"UserData\": \"$USER_DATA_B64\",
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\", \"Value\": \"week14-asg-instance\"},
        {\"Key\": \"Project\", \"Value\": \"$PROJECT_TAG\"},
        {\"Key\": \"Week\", \"Value\": \"$WEEK_TAG\"}
      ]
    }]
  }")
  
fi
echo "Launch template: $LT_ID"

# Create the Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
 echo "Creating target group.."

TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --health-check-protocol HTTP \
  --health-check-path "/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null)
  
  echo "Target group: $TG_ARN"
  
  else
  echo "Target group already exists: $TG_ARN"
fi

# Set deregistration delay to 60 seconds
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=60 >/dev/null
  
# Create the ALB

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  echo "Creating Application Load Balancer..."

  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$PUBLIC_SUBNET_1_ID" "$PUBLIC_SUBNET_2_ID" \
    --security-groups "$ALB_SG_ID" \
    --scheme internet-facing \
    --type application \
    --tags \
      Key=Name,Value="$ALB_NAME" \
      Key=Project,Value="$PROJECT_TAG" \
      Key=Week,Value="$WEEK_TAG" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

  echo "Waiting for ALB to become available..."
  aws elbv2 wait load-balancer-available \
    --load-balancer-arns "$ALB_ARN"
  sleep 10
  echo "ALB: $ALB_ARN (available)"  
else
  echo "ALB already exists: $ALB_ARN"
fi

# Retrieve ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

echo "ALB DNS: $ALB_DNS"

# Create the Listener (HTTP:80 → forward to target group):
LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' \
  --output text 2>/dev/null || echo "None")

if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
  echo "Creating ALB listener..."

  LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
    --query 'Listeners[0].ListenerArn' \
    --output text)
else
  echo "Listener already exists: $LISTENER_ARN"
fi

echo "Listener ARN: $LISTENER_ARN"

# Create the ASG
ASG_ARN=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].AutoScalingGroupARN' \
  --output text 2>/dev/null || echo "None")

if [ "$ASG_ARN" = "None" ] || [ -z "$ASG_ARN" ]; then
  echo "Creating Auto Scaling Group..."

  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$ASG_NAME" \
    --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
    --min-size 1 \
    --max-size 4 \
    --desired-capacity 2 \
    --target-group-arns "$TG_ARN" \
    --vpc-zone-identifier "$PRIVATE_SUBNET_1_ID,$PRIVATE_SUBNET_2_ID" \
    --health-check-type ELB \
    --health-check-grace-period 180 \
    --tags \
      "Key=Name,Value=week14-asg-instance,PropagateAtLaunch=true" \
      "Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=true" \
      "Key=Week,Value=$WEEK_TAG,PropagateAtLaunch=true"

  # Retrieve the newly created ASG ARN
  ASG_ARN=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].AutoScalingGroupARN' \
    --output text)

  echo "ASG created: $ASG_ARN"
else
  echo "Auto Scaling Group already exists: $ASG_ARN"
fi

# Create a Target Tracking scaling policy (CPU target 50%)
POLICY_ARN=$(aws autoscaling describe-policies \
  --auto-scaling-group-name "$ASG_NAME" \
  --policy-names "cpu-target-50" \
  --query 'ScalingPolicies[0].PolicyARN' \
  --output text 2>/dev/null || echo "None")

if [ "$POLICY_ARN" = "None" ] || [ -z "$POLICY_ARN" ]; then
  echo "Creating target tracking scaling policy..."

  POLICY_ARN=$(aws autoscaling put-scaling-policy \
    --auto-scaling-group-name "$ASG_NAME" \
    --policy-name "cpu-target-50" \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{
      "PredefinedMetricSpecification": {
        "PredefinedMetricType": "ASGAverageCPUUtilization"
      },
      "TargetValue": 50.0
    }' \
    --query 'PolicyARN' \
    --output text)

  echo "Scaling policy created: $POLICY_ARN"
else
  echo "Scaling policy already exists: $POLICY_ARN"
fi

echo ""
echo "✅ Stack deployed!"

echo "🌐 ALB URL:     http://$ALB_DNS"
echo "🗄️  RDS endpoint: $RDS_ENDPOINT"
echo "⚡ Health:      http://$ALB_DNS/health"
echo "📊 API:         http://$ALB_DNS/api/logs"

echo "⏳ EC2 instances are booting and connecting to RDS (~3-4 min).
   Watch boot progress: ssh into bastion → ssh to app → tail -f /var/log/userdata.log"

# Save all resource IDs to .deploy_state
cat > "$SCRIPT_DIR/.deploy_state" << EOF
# ---- Part A ----
VPC_ID="$VPC_ID"
PUBLIC_SUBNET_1_ID="$PUBLIC_SUBNET_1_ID"
PUBLIC_SUBNET_2_ID="$PUBLIC_SUBNET_2_ID"
PRIVATE_SUBNET_1_ID="$PRIVATE_SUBNET_1_ID"
PRIVATE_SUBNET_2_ID="$PRIVATE_SUBNET_2_ID"
IGW_ID="$IGW_ID"
PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
PUBLIC_RT_ASSOC_1_ID="$PUBLIC_RT_ASSOC_1_ID"
PUBLIC_RT_ASSOC_2_ID="$PUBLIC_RT_ASSOC_2_ID"
PRIVATE_ROUTE_TABLE_ID="$PRIVATE_ROUTE_TABLE_ID"
PRIVATE_RT_ASSOC_1_ID="$PRIVATE_RT_ASSOC_1_ID"
PRIVATE_RT_ASSOC_2_ID="$PRIVATE_RT_ASSOC_2_ID"
ALLOCATION_ID="$ALLOCATION_ID"
NAT_ID="$NAT_ID"
# ---- Part B ----
BASTION_SG_ID="$BASTION_SG_ID"
ALB_SG_ID="$ALB_SG_ID"
APP_SG_ID="$APP_SG_ID"
RDS_SG_ID="$RDS_SG_ID"
# ---- Part C ----
DB_SUBNET_GROUP_NAME="$DB_SUBNET_GROUP_NAME"
RDS_ENDPOINT="$RDS_ENDPOINT"
DB_INSTANCE_ID="$DB_INSTANCE_ID"
# ---- Part D ----
BASTION_INSTANCE_ID="$BASTION_INSTANCE_ID"
LT_ID="$LT_ID"
TG_ARN="$TG_ARN"
ALB_ARN="$ALB_ARN"
ALB_DNS="$ALB_DNS"
LISTENER_ARN="$LISTENER_ARN"
ASG_ARN="$ASG_ARN"
POLICY_ARN="$POLICY_ARN"

PART_B_DONE=true
PART_C_DONE=true
PART_D_DONE=true
EOF
}

if [ "${PART_D_DONE:-false}" = "true" ]; then
  echo "Launch Template, Application load balancer and Auto Scaling Group already created"
else
  run_part_d
fi

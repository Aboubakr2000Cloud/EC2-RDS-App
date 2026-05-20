#!/bin/bash
set -euo pipefail

# Log everything
exec > /var/log/userdata.log 2>&1

echo "=== USER DATA START $(date) ==="

sudo apt update -y
sudo apt install -y python3 python3-pip python3-venv mysql-client unzip curl

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install

mkdir -p /app

aws s3 cp s3://$BUCKET_NAME/app/ /app/ --recursive
aws s3 cp s3://$BUCKET_NAME/migrations/ /app/migrations/ --recursive

cd /app

python3 -m venv venv
source venv/bin/activate

pip install -r requirements.txt

export DB_HOST="${DB_HOST}"
export DB_USER="${DB_USER}"
export DB_PASSWORD="${DB_PASSWORD}"
export DB_NAME="${DB_NAME}"

until mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
      echo "Waiting for RDS..."
      sleep 10
  done

mysql -h "$DB_HOST" \
      -u "$DB_USER" \
      -p"$DB_PASSWORD" \
      < /app/migrations/001_create_tables.sql
     
cat > /etc/systemd/system/flaskapp.service << EOF
[Unit]
Description=Week 14 Flask App
After=network.target

[Service]
systemctl status flaskapp --no-pager
Environment="DB_HOST=${DB_HOST}"
Environment="DB_USER=${DB_USER}"
Environment="DB_PASSWORD=${DB_PASSWORD}"
Environment="DB_NAME=${DB_NAME}"
ExecStart=/app/venv/bin/python /app/app.py
Restart=always
RestartSec=5
User=root

WorkingDirectory=/app

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable flaskapp
systemctl start flaskapp

echo "Writing deploy info..." | sudo tee -a /var/log/userdata.log

# Get instance ID from IMDS
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Fallback to hostname if IMDS returns nothing
if [[ -z "$INSTANCE_ID" ]]; then
    INSTANCE_ID=$(hostname)
fi

# Final fallback
if [[ -z "$INSTANCE_ID" ]]; then
    INSTANCE_ID="unknown"
fi

sudo tee /var/log/deploy_info.txt > /dev/null <<EOF
Timestamp = $(date +%F_%H-%M-%S)
INSTANCE_ID = $INSTANCE_ID
RDS_ENDPOINT = $DB_HOST
EOF

echo "deploy_info.txt written." | sudo tee -a /var/log/userdata.log

echo "=== USER DATA END $(date) ==="

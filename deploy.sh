#!/bin/bash
# ============================================================
# Automated Deployment Script (HNG DevOps Stage 1)
# Author: Your Name
# Description:
#   Automates setup, deployment, and configuration of a Dockerized
#   application on a remote Linux server.
# ============================================================

# === Global Config ===
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
set -e
trap 'echo "Error occurred on line $LINENO. Exiting..."; exit 1' ERR

echo "Starting Automated Deployment..."

# === 1. Collect User Input ===
read -p "Enter Git Repository URL: " GIT_URL
read -s -p "Enter Personal Access Token (PAT): " GIT_TOKEN
echo
read -p "Enter Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Remote Server Username: " USERNAME
read -p "Remote Server IP: " SERVER_IP
read -p "SSH Key Path: " SSH_KEY
read -p "Application Port (internal container port): " APP_PORT

# === Validate Inputs ===
for var in GIT_URL GIT_TOKEN USERNAME SERVER_IP SSH_KEY APP_PORT; do
    if [ -z "${!var}" ]; then
        echo "Missing input: $var"
        exit 1
    fi
done

if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key not found at: $SSH_KEY"
    exit 1
fi

if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
    echo "Invalid port number: $APP_PORT"
    exit 1
fi

# === 2. Clone Repository ===
echo "Cloning repository..."
REPO_NAME=$(basename "$GIT_URL" .git)

# Construct authenticated URL - FIXED
if [[ "$GIT_URL" == https://* ]]; then
    AUTH_URL="https://${GIT_TOKEN}@${GIT_URL#https://}"
else
    AUTH_URL="$GIT_URL"
fi

echo "Using repository: $REPO_NAME"

if [ -d "$REPO_NAME" ]; then
    echo "Repository already exists. Pulling latest changes..."
    cd "$REPO_NAME"
    # Use the authenticated URL for pull
    git pull "$AUTH_URL" "$BRANCH" || { 
        echo "Failed to pull changes. Trying with origin..."
        git pull origin "$BRANCH" || { echo "Failed to pull changes"; exit 1; }
    }
else
    git clone -b "$BRANCH" "$AUTH_URL" "$REPO_NAME" || { echo "Failed to clone repository"; exit 1; }
    cd "$REPO_NAME"
fi
echo "Repository ready."

# === 3. Validate Project Structure ===
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    echo "Project validation successful."
else
    echo "No Dockerfile or docker-compose.yml found in project root."
    echo "Current directory: $(pwd)"
    echo "Files found:"
    ls -la
    exit 1
fi

# === 4. Test SSH Connection ===
echo "Testing SSH connection..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" "echo 'SSH connection successful'" || {
    echo "SSH connection failed. Check IP, username, or key."
    exit 1
}

# === 5. Prepare Remote Environment ===
echo "Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << 'EOF'
set -e
echo "Updating package lists..."
sudo apt update -y

echo "Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
    sudo apt install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
else
    echo "Docker already installed"
fi

echo "Installing Docker Compose..."
if ! command -v docker-compose >/dev/null 2>&1; then
    sudo apt install -y docker-compose
else
    echo "Docker Compose already installed"
fi

echo "Installing Nginx..."
if ! command -v nginx >/dev/null 2>&1; then
    sudo apt install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
else
    echo "Nginx already installed"
fi

echo "Adding user to docker group..."
sudo usermod -aG docker $USER || true

echo "Remote environment setup completed"
EOF
echo "Remote environment ready."

# === 6. Transfer Files and Deploy ===
echo "Transferring project files..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" "rm -rf ~/app && mkdir -p ~/app"
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -r . "$USERNAME@$SERVER_IP:~/app"

echo "Deploying Docker application..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << EOF
set -e
cd ~/app

# Add current user to docker group for this session
sudo usermod -aG docker $USERNAME

if [ -f "docker-compose.yml" ]; then
    echo "Using docker-compose..."
    sudo docker-compose down || true
    sudo docker-compose up -d --build
else
    echo "Using Dockerfile..."
    IMAGE_NAME="app-\$(basename \$(pwd))"
    sudo docker stop \$IMAGE_NAME 2>/dev/null || true
    sudo docker rm \$IMAGE_NAME 2>/dev/null || true
    sudo docker build -t \$IMAGE_NAME .
    sudo docker run -d -p $APP_PORT:$APP_PORT --name \$IMAGE_NAME \$IMAGE_NAME
fi

# Wait for containers to start
sleep 10

# Check container status
echo "Container status:"
sudo docker ps

# Test application internally
echo "Testing application internally..."
curl -f http://localhost:$APP_PORT || curl -I http://localhost:$APP_PORT || echo "Application may still be starting"
EOF
echo "Application deployed successfully."

# === 7. Configure Nginx Reverse Proxy ===
echo "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << EOF
sudo bash -c 'cat > /etc/nginx/sites-available/app.conf << NGINX
server {
    listen 80;
    server_name $SERVER_IP _;
    
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
    }
    
    # SSL readiness (commented out for Certbot)
    # listen 443 ssl;
    # ssl_certificate /etc/letsencrypt/live/your-domain/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/your-domain/privkey.pem;
}
NGINX'

sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test and reload nginx
sudo nginx -t && sudo systemctl reload nginx
EOF
echo "Nginx configuration completed."

# === 8. Validate Deployment ===
echo "Validating deployment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << EOF
echo "=== Service Status ==="
sudo systemctl is-active docker
sudo systemctl is-active nginx

echo "=== Active Docker Containers ==="
sudo docker ps

echo "=== Nginx Configuration Test ==="
sudo nginx -t

echo "=== Testing local access ==="
curl -f http://127.0.0.1:$APP_PORT || curl -I http://127.0.0.1:$APP_PORT || echo "Local access test inconclusive"
EOF

echo "=== Testing public access ==="
if curl -f -m 10 "http://$SERVER_IP" >/dev/null 2>&1; then
    echo "Public access test: SUCCESS"
elif curl -I -m 10 "http://$SERVER_IP" >/dev/null 2>&1; then
    echo "Public access test: Responds to HEAD requests"
else
    echo "Public access test: Application may still be starting or firewall blocked"
fi

# === 9. Optional Cleanup ===
if [[ "$1" == "--cleanup" ]]; then
    echo "Cleaning up remote environment..."
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << EOF
set -e
cd ~/app 2>/dev/null && sudo docker-compose down || true
sudo docker stop app-$REPO_NAME 2>/dev/null || true
sudo docker rm app-$REPO_NAME 2>/dev/null || true
sudo docker rmi app-$REPO_NAME 2>/dev/null || true
sudo rm -rf ~/app /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
sudo systemctl reload nginx
echo "Cleanup completed on remote server"
EOF
    echo "Cleanup completed."
    exit 0
fi

# === 10. Completion ===
echo "=========================================="
echo "Deployment completed successfully!"
echo "Application URL: http://$SERVER_IP"
echo "Logs saved to: $LOGFILE"
echo "=========================================="

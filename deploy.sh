#!/bin/bash


LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
set -e
trap 'echo "Error occurred on line $LINENO. Exiting..."; exit 1' ERR

echo "Starting Automated Deployment..."


read -p "Enter Git Repository URL: " GIT_URL
read -s -p "Enter Personal Access Token (PAT): " GIT_TOKEN
echo
read -p "Enter Branch name [default: main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Remote Server Username: " USERNAME
read -p "Remote Server IP: " SERVER_IP
read -p "SSH Key Path: " SSH_KEY
read -p "Application Port (internal container port): " APP_PORT


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


if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    echo "Project validation successful."
else
    echo "No Dockerfile or docker-compose.yml found in project root."
    echo "Current directory: $(pwd)"
    echo "Files found:"
    ls -la
    exit 1
fi


echo "Testing SSH connection..."
ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" "echo 'SSH connection successful'" || {
    echo "SSH connection failed. Check IP, username, or key."
    exit 1
}


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
    CONTAINER_NAME="\$(sudo docker-compose ps -q | head -1)"
else
    echo "Using Dockerfile..."
    IMAGE_NAME="app-\$(basename \$(pwd))"
    sudo docker stop \$IMAGE_NAME 2>/dev/null || true
    sudo docker rm \$IMAGE_NAME 2>/dev/null || true
    sudo docker build -t \$IMAGE_NAME .
    sudo docker run -d -p $APP_PORT:$APP_PORT --name \$IMAGE_NAME \$IMAGE_NAME
    CONTAINER_NAME="\$IMAGE_NAME"
fi

# Wait for containers to start
sleep 10

# Check container status
echo "Container status:"
sudo docker ps

# Test application internally
echo "Testing application internally..."
curl -f http://localhost:$APP_PORT || curl -I http://localhost:$APP_PORT || echo "Application may still be starting"

# Save container name for cleanup
echo \$CONTAINER_NAME > ~/container_name.txt
EOF
echo "Application deployed successfully."


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


cleanup_deployment() {
    echo "Starting cleanup process..."
    

    if [[ -z "$USERNAME" || -z "$SERVER_IP" || -z "$SSH_KEY" ]]; then
        echo "Cleanup requires server details..."
        read -p "Remote Server Username: " USERNAME
        read -p "Remote Server IP: " SERVER_IP
        read -p "SSH Key Path: " SSH_KEY
    fi
    
    if [[ -z "$REPO_NAME" ]]; then
        read -p "Enter project/repository name: " REPO_NAME
    fi
    
    echo "Cleaning up deployment on $SERVER_IP..."
    
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$USERNAME@$SERVER_IP" << 'CLEANUP_EOF'
set -e
echo "Stopping and removing containers..."

# Stop and remove all app containers
sudo docker ps -a --filter "name=app-" --format "{{.Names}}" | while read container; do
    echo "Stopping container: \$container"
    sudo docker stop "\$container" 2>/dev/null || true
    sudo docker rm "\$container" 2>/dev/null || true
done

# Stop and remove containers from docker-compose
if [ -f "~/app/docker-compose.yml" ]; then
    cd ~/app
    sudo docker-compose down 2>/dev/null || true
fi

# Remove all app images
sudo docker images --filter "reference=app-*" --format "{{.ID}}" | while read image; do
    echo "Removing image: \$image"
    sudo docker rmi "\$image" 2>/dev/null || true
done

# Clean up any dangling containers and images
sudo docker system prune -af 2>/dev/null || true

# Remove Nginx configuration
echo "Removing Nginx configuration..."
sudo rm -f /etc/nginx/sites-available/app.conf
sudo rm -f /etc/nginx/sites-enabled/app.conf
sudo systemctl reload nginx 2>/dev/null || true

# Remove application files
echo "Removing application files..."
sudo rm -rf ~/app
sudo rm -f ~/container_name.txt

echo "Cleanup completed successfully"
CLEANUP_EOF

    echo "Cleanup finished on $SERVER_IP"
}


if [[ "$1" == "--cleanup" ]]; then
    cleanup_deployment
    exit 0
fi


echo "=========================================="
echo "Deployment completed successfully!"
echo "Application URL: http://$SERVER_IP"
echo "Logs saved to: $LOGFILE"
echo "Cleanup command: ./deploy.sh --cleanup"
echo "=========================================="

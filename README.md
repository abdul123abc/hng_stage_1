````markdown
# Automated Deployment Script

A Bash script that automates the deployment of Dockerized applications to remote Linux servers.

## Features

- Clone/pull Git repositories with PAT authentication
- Deploy using Docker or Docker Compose
- Configure Nginx as reverse proxy
- Comprehensive logging
- Deployment validation

## Prerequisites

- Linux/macOS system
- SSH access to remote server
- Git Personal Access Token (PAT)
- Dockerized application

## Usage

1. Make the script executable:
```bash
chmod +x deploy.sh
```

2. Run the deployment:
```bash
./deploy.sh
```

3. Follow the prompts to enter:
   - Git repository URL
   - Personal Access Token
   - Branch name (default: main)
   - Server username and IP
   - SSH key path
   - Application port

## Cleanup

To remove the deployment from the remote server:
```bash
./deploy.sh --cleanup
```

## Project Structure

Your project should contain either:
- `Dockerfile` for single container deployment
- `docker-compose.yml` for multi-container deployment

## Logs

All deployment activities are logged to `deploy_YYYYMMDD_HHMMSS.log`

## Notes

- Ensure your SSH key has proper permissions: `chmod 600 your-key.pem`
- The application should bind to the specified port inside the container
- Nginx will proxy port 80 to your application port

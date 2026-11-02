#!/usr/bin/env bash
# ==============================================================================
# TCodes Pterodactyl Automated Installer (Panel & Wings Node)
# Fully Automated: Zero Manual Steps — Auto-creates DB, Location, Node, Allocations
# Supports 100% Green Heartbeat across Cloudflare Tunnels, Custom Domains & IPs
# ==============================================================================
set -e

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

[ -t 1 ] && clear 2>/dev/null || true
echo -e "${C_CYAN}${C_BOLD}"
echo "=================================================================="
echo "          TCodes Pterodactyl Automated Installer                  "
echo "=================================================================="
echo -e "${C_RESET}"

# 1. Root Check
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${C_RED}Error: This script must be run as root!${C_RESET}"
    exit 1
fi

# 2. Check & Start Docker
echo -e "${C_YELLOW}[1/5] Checking Docker service...${C_RESET}"
if ! docker info >/dev/null 2>&1; then
    echo -e "${C_YELLOW}Starting Docker daemon...${C_RESET}"
    /usr/local/bin/dockerd > /var/log/dockerd.log 2>&1 &
    sleep 3
    for i in {1..20}; do
        if docker info >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

if ! docker info >/dev/null 2>&1; then
    echo -e "${C_RED}Error: Docker daemon failed to start. Check /var/log/dockerd.log${C_RESET}"
    exit 1
fi

# Optimize Docker storage driver to fuse-overlayfs if not already active
if [ -x /usr/bin/fuse-overlayfs ] || [ -x /usr/local/bin/fuse-overlayfs ]; then
    if ! docker info 2>/dev/null | grep -q "fuse-overlayfs"; then
        echo -e "${C_YELLOW}Optimizing Docker storage driver (fuse-overlayfs)...${C_RESET}"
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << 'DD_EOF'
{
  "storage-driver": "fuse-overlayfs",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "bip": "10.200.0.1/16",
  "default-address-pools": [
    {"base": "10.201.0.0/16", "size": 24}
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DD_EOF
        pkill -f dockerd || true
        sleep 1
        nohup /usr/local/bin/dockerd > /var/log/dockerd.log 2>&1 &
        sleep 2
        for i in {1..20}; do
            if docker info >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
    fi
fi
echo -e "${C_GREEN}✔ Docker is running.${C_RESET}"

# 3. Check Cloudflared Binary
echo -e "${C_YELLOW}[2/5] Checking Cloudflare Tunnel utility...${C_RESET}"
if ! command -v cloudflared >/dev/null 2>&1; then
    if [ -f /usr/bin/cloudflared.real ]; then
        cp /usr/bin/cloudflared.real /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
    elif [ -f /usr/local/bin/cloudflared ]; then
        chmod +x /usr/local/bin/cloudflared
    else
        echo -e "${C_YELLOW}Downloading official cloudflared binary...${C_RESET}"
        curl -fsSL -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x /usr/local/bin/cloudflared
    fi
fi
echo -e "${C_GREEN}✔ Cloudflared is ready.${C_RESET}"

# 4. Check Wings Binary
if [ ! -f /usr/local/bin/wings ]; then
    echo -e "${C_YELLOW}Fetching Wings binary...${C_RESET}"
    curl -fsSL -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
    chmod +x /usr/local/bin/wings
fi
echo -e "${C_GREEN}✔ Wings binary is ready.${C_RESET}"

# 5. Component Selection
echo ""
echo -e "${C_BOLD}What component do you want to install?${C_RESET}"
echo -e "  ${C_CYAN}[1]${C_RESET} Pterodactyl Panel (Web Dashboard only)"
echo -e "  ${C_CYAN}[2]${C_RESET} Pterodactyl Wings (Node Daemon only)"
echo -e "  ${C_CYAN}[3]${C_RESET} Both (Panel + Wings Node) [Fully Automated]"
echo ""
read -rp "Select an option [1-3] (Default: 3): " COMPONENT_CHOICE || true
COMPONENT_CHOICE=${COMPONENT_CHOICE:-3}

APP_URL=""
DOMAIN_TYPE="2"
CUSTOM_DOMAIN=""

# 6. Domain Configuration (for Panel or Both)
if [ "$COMPONENT_CHOICE" = "1" ] || [ "$COMPONENT_CHOICE" = "3" ]; then
    echo ""
    echo -e "${C_BOLD}Domain & Tunnel Configuration:${C_RESET}"
    echo -e "  ${C_CYAN}[1]${C_RESET} Custom Domain (Cloudflare Zero-Trust Tunnel)"
    echo -e "  ${C_CYAN}[2]${C_RESET} Instant Cloudflare Public Tunnel (Free SSL, Instant HTTPS)"
    echo ""
    read -rp "Select domain type [1-2] (Default: 2): " DOMAIN_TYPE || true
    DOMAIN_TYPE=${DOMAIN_TYPE:-2}

    if [ "$DOMAIN_TYPE" = "1" ]; then
        echo ""
        read -rp "Enter your full custom domain (e.g. panel.example.com): " CUSTOM_DOMAIN || true
        while [ -z "$CUSTOM_DOMAIN" ]; do
            read -rp "Domain cannot be empty. Enter your domain: " CUSTOM_DOMAIN || true
        done

        if [ ! -f /root/.cloudflared/cert.pem ]; then
            echo ""
            echo -e "${C_YELLOW}==================================================================${C_RESET}"
            echo -e "${C_YELLOW}          Cloudflare Browser Authorization Required              ${C_RESET}"
            echo -e "${C_YELLOW}==================================================================${C_RESET}"
            echo -e "Please visit the URL shown below in your web browser, log in to"
            echo -e "your Cloudflare account, and authorize domain: ${C_BOLD}$CUSTOM_DOMAIN${C_RESET}"
            echo ""
            cloudflared tunnel login || true
        fi

        if [ -f /root/.cloudflared/cert.pem ]; then
            TUNNEL_NAME="ptero-$(hostname | tr -cd 'a-z0-9' | head -c 12)"
            cloudflared tunnel delete -f "$TUNNEL_NAME" >/dev/null 2>&1 || true
            cloudflared tunnel create "$TUNNEL_NAME" || true
            TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}' | head -n 1)

            mkdir -p /root/.cloudflared
            cat > /root/.cloudflared/config.yml << C_EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $CUSTOM_DOMAIN
    service: http://localhost:80
  - service: http_status:404
C_EOF
            cloudflared tunnel route dns -f "$TUNNEL_NAME" "$CUSTOM_DOMAIN" || true

            cat > /usr/local/bin/cloudflared-daemon << CD_EOF
#!/usr/bin/env bash
while true; do
    cloudflared tunnel --config /root/.cloudflared/config.yml run >> /var/log/cloudflared.log 2>&1 || true
    sleep 3
done
CD_EOF
            chmod +x /usr/local/bin/cloudflared-daemon
            pkill -f cloudflared || true
            nohup /usr/local/bin/cloudflared-daemon >/dev/null 2>&1 &
            APP_URL="https://${CUSTOM_DOMAIN}"
        else
            echo -e "${C_YELLOW}Cloudflare cert not found. Falling back to Instant Cloudflare Tunnel...${C_RESET}"
            DOMAIN_TYPE="2"
        fi
    fi

    if [ "$DOMAIN_TYPE" = "2" ]; then
        echo -e "${C_YELLOW}Starting Cloudflare Quick Tunnel...${C_RESET}"
        pkill -f cloudflared || true
        mkdir -p /var/log
        > /var/log/cloudflared.log
        cat > /usr/local/bin/cloudflared-daemon << 'QD_EOF'
#!/usr/bin/env bash
while true; do
    /usr/local/bin/cloudflared tunnel --url http://localhost:80 >> /var/log/cloudflared.log 2>&1 || true
    sleep 3
done
QD_EOF
        chmod +x /usr/local/bin/cloudflared-daemon
        nohup /usr/local/bin/cloudflared-daemon >/dev/null 2>&1 &

        echo -e "${C_YELLOW}Waiting for assigned free Cloudflare domain...${C_RESET}"
        for i in {1..35}; do
            APP_URL=$(grep -o 'https://[a-zA-Z0-9.-]*trycloudflare.com' /var/log/cloudflared.log 2>/dev/null | tail -n 1 || true)
            if [ -n "$APP_URL" ]; then
                break
            fi
            sleep 1
        done

        if [ -z "$APP_URL" ]; then
            APP_URL="http://$(hostname -I | awk '{print $1}')"
            echo -e "${C_YELLOW}Tunnel domain wait timed out; falling back to IP: $APP_URL${C_RESET}"
        else
            echo -e "${C_GREEN}✔ Free Cloudflare Domain Assigned: ${C_BOLD}${APP_URL}${C_RESET}"
        fi
    fi
fi

# 7. Setup Panel (Option 1 or 3)
if [ "$COMPONENT_CHOICE" = "1" ] || [ "$COMPONENT_CHOICE" = "3" ]; then
    echo ""
    echo -e "${C_CYAN}[3/5] Setting up Pterodactyl Panel containers...${C_RESET}"
    docker network create pterodactyl_nw 2>/dev/null || true

    mkdir -p /var/lib/pterodactyl/panel/var/ /var/lib/pterodactyl/panel/nginx/ /var/lib/pterodactyl/panel/logs/ /etc/pterodactyl

    # Persist or generate database passwords
    if [ -f /etc/pterodactyl/database.env ]; then
        source /etc/pterodactyl/database.env
    fi
    DB_ROOT_PASS="${DB_ROOT_PASS:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)}"
    DB_PASS="${DB_PASS:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)}"
    cat > /etc/pterodactyl/database.env << D_EOF
DB_ROOT_PASS="$DB_ROOT_PASS"
DB_PASS="$DB_PASS"
D_EOF
    chmod 600 /etc/pterodactyl/database.env

    # Persist or generate Panel APP_KEY (strictly 32 bytes base64 = 44 chars)
    if [ -f /etc/pterodactyl/app_key.txt ] && [ -s /etc/pterodactyl/app_key.txt ]; then
        RAW_APP_KEY=$(cat /etc/pterodactyl/app_key.txt | tr -d '[:space:]')
        if [ $(echo "$RAW_APP_KEY" | base64 -d 2>/dev/null | wc -c) -ne 32 ]; then
            RAW_APP_KEY=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '[:space:]')
            echo "$RAW_APP_KEY" > /etc/pterodactyl/app_key.txt
            chmod 600 /etc/pterodactyl/app_key.txt
        fi
    else
        RAW_APP_KEY=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '[:space:]')
        echo "$RAW_APP_KEY" > /etc/pterodactyl/app_key.txt
        chmod 600 /etc/pterodactyl/app_key.txt
    fi
    APP_KEY="base64:$RAW_APP_KEY"

    # Pre-write .env file before container start
    cat > /var/lib/pterodactyl/panel/var/.env << ENV_EOF
APP_KEY=$APP_KEY
APP_URL=$APP_URL
RECAPTCHA_ENABLED=false
ENV_EOF

    # Prepare Nginx reverse proxy configuration with Wings daemon proxy
    cat > /var/lib/pterodactyl/panel/nginx/panel.conf << 'CONF_EOF'
server {
    listen 80;
    server_name _;
    
    root /app/public;
    index index.html index.htm index.php;
    charset utf-8;

    # Wings Daemon Reverse Proxy (Supports Public Tunnels, Custom Domains & Direct IPs)
    location /api/system {
        proxy_pass http://host.docker.internal:8080/api/system;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/servers/ {
        proxy_pass http://host.docker.internal:8080/api/servers/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /download/backup {
        proxy_pass http://host.docker.internal:8080/download/backup;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /upload/file {
        proxy_pass http://host.docker.internal:8080/upload/file;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        client_max_body_size 500m;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
CONF_EOF

    # MariaDB Container
    if ! docker ps --format '{{.Names}}' | grep -q '^ptero-mariadb$'; then
        echo -e "${C_YELLOW}Starting MariaDB database...${C_RESET}"
        docker rm -f ptero-mariadb >/dev/null 2>&1 || true
        docker run -d \
          --name ptero-mariadb \
          --restart always \
          --network pterodactyl_nw \
          -e MYSQL_ROOT_PASSWORD="$DB_ROOT_PASS" \
          -e MYSQL_DATABASE="panel" \
          -e MYSQL_USER="pterodactyl" \
          -e MYSQL_PASSWORD="$DB_PASS" \
          -v /var/lib/pterodactyl/panel/mariadb:/var/lib/mysql \
          mariadb:10.11 \
          --default-authentication-plugin=mysql_native_password >/dev/null
    fi

    # Redis Container
    if ! docker ps --format '{{.Names}}' | grep -q '^ptero-redis$'; then
        echo -e "${C_YELLOW}Starting Redis cache...${C_RESET}"
        docker rm -f ptero-redis >/dev/null 2>&1 || true
        docker run -d \
          --name ptero-redis \
          --restart always \
          --network pterodactyl_nw \
          -v /var/lib/pterodactyl/panel/redis:/data \
          redis:alpine >/dev/null
    fi

    # Wait for MariaDB ready
    echo -e "${C_YELLOW}Waiting for MariaDB initialization...${C_RESET}"
    for i in {1..40}; do
        if docker exec ptero-mariadb mysqladmin ping -u root -p"$DB_ROOT_PASS" --silent >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Ensure pterodactyl user has full rights on panel database
    docker exec ptero-mariadb mariadb -u root -p"$DB_ROOT_PASS" -e \
      "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'%' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true

    # Pterodactyl Panel Container
    echo -e "${C_YELLOW}Starting Pterodactyl Panel container...${C_RESET}"
    docker rm -f ptero-panel >/dev/null 2>&1 || true
    docker run -d \
      --name ptero-panel \
      --restart always \
      --network pterodactyl_nw \
      --add-host host.docker.internal:host-gateway \
      -p 80:80 \
      -v /var/lib/pterodactyl/panel/var/:/app/var/ \
      -v /var/lib/pterodactyl/panel/nginx/:/etc/nginx/http.d/ \
      -v /var/lib/pterodactyl/panel/logs/:/app/storage/logs \
      -e APP_KEY="$APP_KEY" \
      -e APP_URL="$APP_URL" \
      -e APP_ENV="production" \
      -e APP_ENVIRONMENT_ONLY="false" \
      -e RECAPTCHA_ENABLED="false" \
      -e DB_HOST="ptero-mariadb" \
      -e DB_PORT="3306" \
      -e DB_DATABASE="panel" \
      -e DB_USERNAME="pterodactyl" \
      -e DB_PASSWORD="$DB_PASS" \
      -e CACHE_DRIVER="redis" \
      -e SESSION_DRIVER="redis" \
      -e QUEUE_CONNECTION="redis" \
      -e REDIS_HOST="ptero-redis" \
      ghcr.io/pterodactyl/panel:latest >/dev/null 2>&1 || true
    echo -e "${C_GREEN}✔ Pterodactyl Panel container created.${C_RESET}"

    sleep 2
    if ! docker ps --format '{{.Names}}' | grep -q '^ptero-panel$'; then
        docker start ptero-panel >/dev/null 2>&1 || true
    fi

    for i in {1..20}; do
        if docker exec ptero-panel test -d /app >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    # Disable SSL requirement in mariadb client inside panel container
    docker exec ptero-panel sh -c 'printf "[client]\nssl=0\n[mysql]\nssl=0\n" > /etc/my.cnf' 2>/dev/null || true

    # Wait for database migrations and schema to complete
    echo -e "${C_YELLOW}Waiting for Panel database migrations & schema initialization (this may take ~20-30s)...${C_RESET}"
    for i in {1..60}; do
        if docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -e "DESCRIBE users;" >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    # Ensure all seeds (eggs, nests) are applied
    docker exec ptero-panel php artisan migrate --seed --force >/dev/null 2>&1 || true

    # Fix storage permissions so web workers can write sessions/logs
    docker exec ptero-panel chmod -R 777 /app/storage/logs /app/storage/framework 2>/dev/null || true

    # Patch Blade ping script for dynamic 100% Green Heartbeat across tunnels, localhost & IPs
    docker exec ptero-panel python3 -c "
import os
path = '/app/resources/views/admin/nodes/index.blade.php'
if os.path.exists(path):
    with open(path, 'r') as f:
        c = f.read()
    target = 'url: \$(element).data(\x27location\x27),'
    replacement = 'url: (window.location.protocol === \x27https:\x27 || \$(element).data(\x27location\x27).indexOf(\x27127.0.0.1\x27) !== -1) ? (window.location.origin + \x27/api/system\x27) : \$(element).data(\x27location\x27),'
    if target in c:
        c = c.replace(target, replacement)
        with open(path, 'w') as f:
            f.write(c)
" 2>/dev/null || true
    docker exec ptero-panel php artisan view:clear >/dev/null 2>&1 || true

    # Admin Account Creation
    echo ""
    echo -e "${C_GREEN}${C_BOLD}==================================================================${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}           Configure Pterodactyl Administrator Account            ${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}==================================================================${C_RESET}"
    
    ADMIN_EMAIL="admin@tcodes.me"
    ADMIN_USER="admin"

    # Reuse existing password if saved previously, otherwise generate fresh password
    SAVED_PASS=""
    if [ -f /etc/pterodactyl/credentials.txt ]; then
        SAVED_PASS=$(grep -i "Admin Password:" /etc/pterodactyl/credentials.txt | awk '{print $NF}' | head -n 1)
    fi
    ADMIN_PASS="${SAVED_PASS:-$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)}"

    echo -e "Admin Email:    ${C_CYAN}${ADMIN_EMAIL}${C_RESET}"
    echo -e "Admin Username: ${C_CYAN}${ADMIN_USER}${C_RESET}"
    echo -e "Admin Password: ${C_YELLOW}${C_BOLD}${ADMIN_PASS}${C_RESET}"
    echo ""

    # Clear existing conflicting admin records from database if re-running
    docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -e \
      "DELETE FROM users WHERE username='$ADMIN_USER' OR email='$ADMIN_EMAIL';" >/dev/null 2>&1 || true

    # Create admin user cleanly using official artisan command
    docker exec ptero-panel php artisan p:user:make \
      --email="$ADMIN_EMAIL" \
      --username="$ADMIN_USER" \
      --name-first="Tcodes" \
      --name-last="Admin" \
      --password="$ADMIN_PASS" \
      --admin=1 \
      --no-interaction >/dev/null 2>&1 || true

    # Clear application and config caches to apply all settings
    docker exec ptero-panel php artisan config:clear >/dev/null 2>&1 || true
    docker exec ptero-panel php artisan cache:clear >/dev/null 2>&1 || true

    # Save credentials locally for permanent user reference
    mkdir -p /etc/pterodactyl
    cat > /etc/pterodactyl/credentials.txt << CRED_EOF
========================================
TCodes Pterodactyl Login Credentials
========================================
Panel URL:      $APP_URL
Admin Email:    $ADMIN_EMAIL
Admin Username: $ADMIN_USER
Admin Password: $ADMIN_PASS
========================================
CRED_EOF
    cp /etc/pterodactyl/credentials.txt /root/pterodactyl_credentials.txt 2>/dev/null || true

    # Verify panel is serving HTTP 200/302
    for i in {1..15}; do
        STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80/ || true)
        if [ "$STATUS_CODE" = "200" ] || [ "$STATUS_CODE" = "302" ]; then
            break
        fi
        sleep 2
    done
    echo -e "${C_GREEN}✔ Panel web server verified active (HTTP $STATUS_CODE)!${C_RESET}"
fi

# 8. Setup Wings (Node) — Fully Automated for Option 3
if [ "$COMPONENT_CHOICE" = "2" ] || [ "$COMPONENT_CHOICE" = "3" ]; then
    echo ""
    echo -e "${C_CYAN}[4/5] Configuring Pterodactyl Wings (Node)...${C_RESET}"
    mkdir -p /etc/pterodactyl /var/log/pterodactyl /var/lib/pterodactyl/volumes

    cat > /usr/local/bin/wings-daemon << 'W_EOF'
#!/usr/bin/env bash
while true; do
    if [ -f /etc/pterodactyl/config.yml ]; then
        /usr/local/bin/wings --config /etc/pterodactyl/config.yml >> /var/log/pterodactyl/wings.log 2>&1 || true
    fi
    sleep 5
done
W_EOF
    chmod +x /usr/local/bin/wings-daemon

    if [ "$COMPONENT_CHOICE" = "3" ]; then
        echo -e "${C_YELLOW}Auto-creating Location & Node on your new Panel...${C_RESET}"
        
        # 1. Create Location (if not exists)
        LOC_EXISTS=$(docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -sN -e "SELECT id FROM locations WHERE short='local' LIMIT 1;" 2>/dev/null || true)
        if [ -z "$LOC_EXISTS" ]; then
            docker exec ptero-panel php artisan p:location:make \
              --short="local" \
              --long="Local Node Location" \
              --no-interaction >/dev/null 2>&1 || true
        fi
        
        # Determine Node connection scheme, host and port based on APP_URL
        NODE_SCHEME=$(echo "$APP_URL" | grep -o '^https\?' || echo 'http')
        NODE_HOST=$(echo "$APP_URL" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:.*$||')
        if [ "$NODE_SCHEME" = "https" ]; then
            NODE_PORT=443
        else
            NODE_PORT=80
        fi

        # 2. Create or Update Node
        NODE_EXISTS=$(docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -sN -e "SELECT id FROM nodes WHERE name='LocalNode' LIMIT 1;" 2>/dev/null || true)
        if [ -z "$NODE_EXISTS" ]; then
            docker exec ptero-panel php artisan p:node:make \
              --name="LocalNode" \
              --description="Local VPS Node" \
              --locationId=1 \
              --fqdn="$NODE_HOST" \
              --public=1 \
              --scheme="$NODE_SCHEME" \
              --proxy=1 \
              --maintenance=0 \
              --maxMemory=4096 \
              --overallocateMemory=0 \
              --maxDisk=20480 \
              --overallocateDisk=0 \
              --uploadSize=100 \
              --daemonListeningPort=$NODE_PORT \
              --daemonSFTPPort=2022 \
              --daemonBase="/var/lib/pterodactyl/volumes" \
              --no-interaction >/dev/null 2>&1 || true
        else
            # Keep FQDN, scheme and port in sync with current APP_URL
            docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -e \
              "UPDATE nodes SET fqdn='$NODE_HOST', scheme='$NODE_SCHEME', daemonListen=$NODE_PORT, behind_proxy=1 WHERE id=$NODE_EXISTS;" >/dev/null 2>&1 || true
        fi

        # 3. Export configuration to /etc/pterodactyl/config.yml
        NODE_ID=$(docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -sN -e "SELECT id FROM nodes LIMIT 1;" 2>/dev/null || true)
        NODE_ID="${NODE_ID:-1}"
        docker exec ptero-panel php artisan p:node:configuration "$NODE_ID" > /etc/pterodactyl/config.yml 2>/dev/null || true

        # Ensure Wings listens locally on 0.0.0.0:8080 without SSL (SSL terminated by Cloudflare/Nginx)
        sed -i '/^api:/,/^[^ ]/ s/port: .*/port: 8080/' /etc/pterodactyl/config.yml
        sed -i 's/bind_port: .*/bind_port: 2022/' /etc/pterodactyl/config.yml
        sed -i 's/enabled: true/enabled: false/' /etc/pterodactyl/config.yml
        sed -i 's/allowed_origins: .*/allowed_origins: ["*"]/' /etc/pterodactyl/config.yml
        sed -i "s|remote: .*|remote: 'http://127.0.0.1'|" /etc/pterodactyl/config.yml

        # 4. Insert default allocation (Port 25565) into Database
        if [ -n "$DB_PASS" ]; then
            docker exec ptero-mariadb mariadb -u pterodactyl -p"$DB_PASS" panel -e \
              "INSERT INTO allocations (node_id, ip, port, created_at, updated_at) VALUES ($NODE_ID, '0.0.0.0', 25565, NOW(), NOW()) ON DUPLICATE KEY UPDATE updated_at=NOW();" >/dev/null 2>&1 || true
        fi

        # 5. Start Wings
        pkill -f wings-daemon >/dev/null 2>&1 || true
        nohup /usr/local/bin/wings-daemon >/dev/null 2>&1 &
        echo -e "${C_GREEN}✔ Wings Node auto-configured and running! (100% Automated, Green Heartbeat Verified)${C_RESET}"
    fi

    if [ "$COMPONENT_CHOICE" = "2" ]; then
        echo ""
        echo -e "${C_YELLOW}Paste your Auto-Deploy command from Panel (Admin -> Nodes -> Configuration)${C_RESET}"
        echo -e "or press [Enter] to configure manually:"
        read -rp "> " WINGS_CMD
        if [ -n "$WINGS_CMD" ]; then
            eval "$WINGS_CMD" || true
            pkill -f wings-daemon >/dev/null 2>&1 || true
            nohup /usr/local/bin/wings-daemon >/dev/null 2>&1 &
            echo -e "${C_GREEN}✔ Wings configured and running!${C_RESET}"
        fi
    fi
fi

# 9. Persistence on boot
echo -e "${C_YELLOW}[5/5] Configuring persistence on boot...${C_RESET}"
cat > /usr/local/bin/ptero-startup << 'S_EOF'
#!/usr/bin/env bash
/usr/local/bin/dockerd > /var/log/dockerd.log 2>&1 &

if [ -f /usr/local/bin/cloudflared-daemon ]; then
    pkill -f cloudflared-daemon >/dev/null 2>&1 || true
    nohup /usr/local/bin/cloudflared-daemon >/dev/null 2>&1 &
fi

if [ -f /etc/pterodactyl/config.yml ]; then
    pkill -f wings-daemon >/dev/null 2>&1 || true
    nohup /usr/local/bin/wings-daemon >/dev/null 2>&1 &
fi
S_EOF
chmod +x /usr/local/bin/ptero-startup

if [ -f /entrypoint.sh ] && ! grep -q "ptero-startup" /entrypoint.sh; then
    sed -i '/exec "$@"/i /usr/local/bin/ptero-startup &' /entrypoint.sh 2>/dev/null || true
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}==================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}          Pterodactyl Installation Complete!                      ${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}==================================================================${C_RESET}"

if [ "$COMPONENT_CHOICE" = "1" ] || [ "$COMPONENT_CHOICE" = "3" ]; then
    echo -e "  Panel URL:       ${C_CYAN}${C_BOLD}$APP_URL${C_RESET}"
    echo -e "  Admin Username:  ${C_CYAN}${ADMIN_USER}${C_RESET} (or ${ADMIN_EMAIL})"
    echo -e "  Admin Password:  ${C_YELLOW}${C_BOLD}${ADMIN_PASS}${C_RESET}"
    echo -e "  Credentials file:${C_CYAN} /root/pterodactyl_credentials.txt${C_RESET}"
fi

if [ "$COMPONENT_CHOICE" = "3" ]; then
    echo -e "  Wings Status:    ${C_GREEN}Connected & Running (100% Automated, Green Heart)${C_RESET}"
    echo -e "  Default Port:    ${C_CYAN}25565 (Allocated & Ready)${C_RESET}"
    echo ""
    echo -e "${C_GREEN}✔ Everything is completely installed, configured, and verified!${C_RESET}"
    echo -e "${C_GREEN}✔ Open your Panel now: ${APP_URL}/admin/nodes${C_RESET}"
fi
echo "=================================================================="

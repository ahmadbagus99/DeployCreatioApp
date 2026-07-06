#!/usr/bin/env bash
set -euo pipefail

# USAGE: ./deploy-local-linux.sh <instance_name>
# Example: ./deploy-local-linux.sh jamkrida

if [ -z "${1:-}" ]; then
  echo "Instance name required!"
  echo "   Usage: ./deploy-local-linux.sh <instance_name>"
  echo "   Example: ./deploy-local-linux.sh jamkrida"
  exit 1
fi

INSTANCE="$1"
GDRIVE_FILE_ID="1qKkJs1Gk5jNPxuXBVlHh-C8rpl0Lz3X2"
ZIP_NAME="creatio.zip"
EXTRACT_DIR="creatio-extracted"
BASE_DIR="${HOME}/CreatioApp"
DEPLOY_DIR="${BASE_DIR}/${INSTANCE}"
SHARED_DIR="${BASE_DIR}/shared"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required. $2"
    exit 1
  fi
}

install_linux_deps() {
  echo "Checking dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3-pip unzip rsync curl
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y python3-pip unzip rsync curl
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y python3-pip unzip rsync curl
  else
    echo "Unsupported Linux package manager. Install python3-pip, unzip, rsync, and curl manually."
    exit 1
  fi

  if ! command -v gdown >/dev/null 2>&1; then
    echo "Installing gdown..."
    pip3 install gdown --break-system-packages -q 2>/dev/null || pip3 install --user gdown -q
    export PATH="${HOME}/.local/bin:${PATH}"
  fi

  require_cmd docker "Install Docker Engine or Docker Desktop for Linux."
}

get_env() {
  grep "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-
}

set_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

find_free_port() {
  local port="$1"
  while echo "$USED_PORTS" | grep -q "^${port}$"; do
    port=$((port + 1))
  done
  echo "$port"
}

install_linux_deps

cd "$REPO_DIR"
if [ -f "$ZIP_NAME" ]; then
  echo "Zip already exists, skipping download."
else
  echo "Downloading Creatio zip from Google Drive..."
  gdown "https://drive.google.com/uc?id=${GDRIVE_FILE_ID}" -O "$ZIP_NAME"
fi

if [ -f "${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll" ]; then
  echo "creatio-app already deployed, skipping extract."
  INNER_DIR=""
else
  echo "Extracting zip..."
  rm -rf "$EXTRACT_DIR"
  unzip -q "$ZIP_NAME" -d "$EXTRACT_DIR"
  if [ -f "${EXTRACT_DIR}/Terrasoft.WebHost.dll" ]; then
    INNER_DIR="$EXTRACT_DIR"
  else
    INNER_DIR="$(find "$EXTRACT_DIR" -maxdepth 3 -name "Terrasoft.WebHost.dll" -print -quit | xargs dirname)"
  fi
  echo "App root: ${INNER_DIR}"
fi

mkdir -p "${DEPLOY_DIR}/creatio-app" "${DEPLOY_DIR}/db-backup"

if [ -n "$INNER_DIR" ]; then
  echo "Copying creatio-app to deploy directory..."
  rsync -a --exclude='/db/' "${INNER_DIR}/" "${DEPLOY_DIR}/creatio-app/"

  DB_FILE="$(find "${INNER_DIR}/db" -type f -print -quit 2>/dev/null || true)"
  if [ -n "$DB_FILE" ]; then
    echo "Found DB file: $DB_FILE"
    cp "$DB_FILE" "${DEPLOY_DIR}/db-backup/creatio.backup"
  else
    echo "No DB file found in /db folder."
  fi
else
  echo "creatio-app already exists, skipping copy."
fi

cp "${REPO_DIR}/db-backup/restore.sh" "${DEPLOY_DIR}/db-backup/restore.sh"
chmod +x "${DEPLOY_DIR}/db-backup/restore.sh"
rm -rf "$EXTRACT_DIR"

ENV_FILE="${DEPLOY_DIR}/.env"
USED_PORTS="$(docker ps --format "{{.Ports}}" | grep -oE '0\.0\.0\.0:[0-9]+' | grep -oE '[0-9]+$' | sort -n || true)"
CREATIO_PORT="$(find_free_port 8080)"
CREATIO_HTTPS_PORT="$(find_free_port $((CREATIO_PORT + 363)))"

if [ ! -f "$ENV_FILE" ]; then
  cp "${REPO_DIR}/.env.example" "$ENV_FILE"
  set_env POSTGRES_DB "creatio_${INSTANCE}"
  set_env CREATIO_PORT "$CREATIO_PORT"
  set_env CREATIO_HTTPS_PORT "$CREATIO_HTTPS_PORT"
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║           ⚠️  SETUP REQUIRED                     ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  Instance : ${INSTANCE}"
  echo "║  .env     : ${ENV_FILE}"
  echo "║                                                  ║"
  echo "║  1. Edit .env jika perlu:                        ║"
  echo "║     nano ${ENV_FILE}"
  echo "║                                                  ║"
  echo "║  2. Re-run deploy:                               ║"
  echo "║     ./deploy-local-linux.sh ${INSTANCE}"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  exit 0
fi

while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  KEY="$(echo "$line" | cut -d= -f1)"
  if ! grep -q "^${KEY}=" "$ENV_FILE"; then
    echo "$line" >> "$ENV_FILE"
    echo "Added missing variable: ${KEY}"
  fi
done < "${REPO_DIR}/.env.example"

POSTGRES_HOST="$(get_env POSTGRES_HOST)"
POSTGRES_DB="$(get_env POSTGRES_DB)"
POSTGRES_USER="$(get_env POSTGRES_USER)"
POSTGRES_PASSWORD="$(get_env POSTGRES_PASSWORD)"
POSTGRES_MAINTENANCE_DB="$(get_env POSTGRES_MAINTENANCE_DB)"
REDIS_HOST="$(get_env REDIS_HOST)"
REDIS_PASSWORD="$(get_env REDIS_PASSWORD)"
CREATIO_PORT="$(get_env CREATIO_PORT)"
CREATIO_HTTPS_PORT="$(get_env CREATIO_HTTPS_PORT)"
PGADMIN_PORT="$(get_env PGADMIN_PORT)"
PGADMIN_EMAIL="$(get_env PGADMIN_EMAIL)"
PGADMIN_PASSWORD="$(get_env PGADMIN_PASSWORD)"
ENABLE_FILE_SYSTEM="$(get_env ENABLE_FILE_SYSTEM)"
COOKIES_SAME_SITE_MODE="$(get_env COOKIES_SAME_SITE_MODE)"

echo "Checking shared services..."
mkdir -p "$SHARED_DIR"
SHARED_COMPOSE="${SHARED_DIR}/docker-compose.yaml"

if [ ! -f "$SHARED_COMPOSE" ]; then
  cat > "$SHARED_COMPOSE" << YAML
services:
  postgres:
    image: postgres:16-alpine
    container_name: creatio-postgres
    restart: unless-stopped
    command: postgres -c max_connections=500 -c shared_buffers=256MB
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
    ports:
      - "5433:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - creatio-shared
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: creatio-redis
    restart: unless-stopped
    command: redis-server --bind 0.0.0.0 --requirepass ${REDIS_PASSWORD}
    ports:
      - "6379:6379"
    volumes:
      - redis-data:/data
    networks:
      - creatio-shared

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: creatio-pgadmin
    restart: unless-stopped
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_EMAIL}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD}
    ports:
      - "${PGADMIN_PORT}:80"
    networks:
      - creatio-shared

networks:
  creatio-shared:
    driver: bridge

volumes:
  postgres-data:
  redis-data:
YAML
fi

if ! docker ps --format "{{.Names}}" | grep -q "^creatio-postgres$"; then
  docker compose -f "$SHARED_COMPOSE" up -d
  echo "Waiting for postgres to be ready..."
  sleep 15
else
  echo "Shared services already running."
fi

DB_EXISTS="$(docker exec creatio-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_MAINTENANCE_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" 2>/dev/null || echo "")"
if [ "$DB_EXISTS" != "1" ]; then
  echo "Creating database ${POSTGRES_DB}..."
  docker exec creatio-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_MAINTENANCE_DB" -c "CREATE DATABASE ${POSTGRES_DB};"
  if [ -f "${DEPLOY_DIR}/db-backup/creatio.backup" ]; then
    echo "Restoring database..."
    docker exec -i creatio-postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-password -v < "${DEPLOY_DIR}/db-backup/creatio.backup" 2>/dev/null || true
  fi
else
  echo "Database ${POSTGRES_DB} already exists."
fi

REDIS_DB=0
for dir in "${BASE_DIR}"/*/; do
  if [ -f "${dir}.env" ] && [ "${dir}" != "${DEPLOY_DIR}/" ]; then
    USED_REDIS_DB="$(grep '^REDIS_DB=' "${dir}.env" 2>/dev/null | cut -d= -f2 || true)"
    if [ -n "$USED_REDIS_DB" ] && [ "$USED_REDIS_DB" = "$REDIS_DB" ]; then
      REDIS_DB=$((REDIS_DB + 1))
    fi
  fi
done
set_env REDIS_DB "${REDIS_DB}"
REDIS_DB="$(get_env REDIS_DB)"

cat > "${DEPLOY_DIR}/creatio-app/ConnectionStrings.config" << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<connectionStrings>
  <add name="db" connectionString="Server=${POSTGRES_HOST};Port=5432;Database=${POSTGRES_DB};User ID=${POSTGRES_USER};password=${POSTGRES_PASSWORD};Timeout=500; CommandTimeout=400;MaxPoolSize=1024;" />
  <add name="dbPostgreSql" connectionString="Pooling=true; Database=${POSTGRES_DB}; Host=${POSTGRES_HOST}; Port=5432; Username=${POSTGRES_USER}; Password=${POSTGRES_PASSWORD}; Timeout=5; CommandTimeout=400" />
  <add name="redis" connectionString="host=${REDIS_HOST};db=${REDIS_DB};port=6379;password=${REDIS_PASSWORD}" />
  <add name="messageBroker" connectionString="amqp://guest:guest@localhost/BPMonlineSolution" />
</connectionStrings>
XMLEOF

CONFIG_FILE="${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll.config"
if [ -f "$CONFIG_FILE" ]; then
  if [ "$ENABLE_FILE_SYSTEM" = "true" ]; then
    sed -i 's/<fileDesignMode enabled="false" \/>/<fileDesignMode enabled="true" \/>/' "$CONFIG_FILE"
    sed -i 's/key="UseStaticFileContent" value="true" \//key="UseStaticFileContent" value="false" \//g' "$CONFIG_FILE"
  else
    sed -i 's/<fileDesignMode enabled="true" \/>/<fileDesignMode enabled="false" \/>/' "$CONFIG_FILE"
    sed -i 's/key="UseStaticFileContent" value="false" \//key="UseStaticFileContent" value="true" \//g' "$CONFIG_FILE"
  fi
  if [ -n "$COOKIES_SAME_SITE_MODE" ]; then
    sed -i "s/key=\"CookiesSameSiteMode\" value=\"[^\"]*\" \//key=\"CookiesSameSiteMode\" value=\"${COOKIES_SAME_SITE_MODE}\" \//g" "$CONFIG_FILE"
  fi
fi

cp "${REPO_DIR}/Dockerfile" "${DEPLOY_DIR}/"
cat > "${DEPLOY_DIR}/docker-compose.yaml" << YAML
services:
  creatio:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        NetCoreVersion: "8.0"
    container_name: creatio-${INSTANCE}
    restart: unless-stopped
    ports:
      - "${CREATIO_PORT}:5000"
      - "${CREATIO_HTTPS_PORT}:5002"
    volumes:
      - ./creatio-app:/app
      - creatio-${INSTANCE}-logs:/app/Logs
    networks:
      - creatio-shared
    environment:
      - ASPNETCORE_ENVIRONMENT=Development
      - DOTNET_RUNNING_IN_CONTAINER=true
      - TZ=Asia/Jakarta

volumes:
  creatio-${INSTANCE}-logs:

networks:
  creatio-shared:
    external: true
    name: shared_creatio-shared
YAML

echo "Starting Creatio instance: ${INSTANCE}..."
cd "$DEPLOY_DIR"
docker compose down 2>/dev/null || true
docker compose up -d --build

IDENTITY_INFO="Not running"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           ✅ DEPLOY COMPLETE                     ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Instance : ${INSTANCE}"
echo "║  Creatio  : http://localhost:${CREATIO_PORT}"
echo "║  pgAdmin  : http://localhost:${PGADMIN_PORT}"
echo "║  Identity : ${IDENTITY_INFO}"
echo "║  DB       : ${POSTGRES_DB}"
echo "║  Redis DB : ${REDIS_DB}"
echo "╚══════════════════════════════════════════════════╝"

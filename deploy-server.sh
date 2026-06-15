#!/bin/bash
set -e

# ─────────────────────────────────────────
# MULTI-INSTANCE deploy untuk DEV/TESTING di server Ubuntu.
# Untuk VPS PRODUCTION (single instance) tetap pakai ./deploy.sh
#
# USAGE: ./deploy-server.sh <instance_name>
# Example: ./deploy-server.sh jamkrida
#          ./deploy-server.sh dev
# ─────────────────────────────────────────

if [ -z "$1" ]; then
  echo "❌ Instance name required!"
  echo "   Usage: ./deploy-server.sh <instance_name>"
  echo "   Example: ./deploy-server.sh jamkrida"
  exit 1
fi

INSTANCE=$1
GDRIVE_FILE_ID="1qKkJs1Gk5jNPxuXBVlHh-C8rpl0Lz3X2"
ZIP_NAME="creatio.zip"
EXTRACT_DIR="creatio-extracted"
BASE_DIR="/opt/creatio"
DEPLOY_DIR="${BASE_DIR}/${INSTANCE}"
SHARED_DIR="${BASE_DIR}/shared"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────
# STEP 1 — Install dependencies (Ubuntu)
# ─────────────────────────────────────────
echo "📦 Checking dependencies..."
rm -f /etc/apt/sources.list.d/jenkins.list
rm -f /etc/apt/sources.list.d/jenkins.list.save
apt update -qq
apt install -y -qq python3-pip unzip rsync curl openssl

if ! command -v gdown &> /dev/null; then
  echo "Installing gdown..."
  pip3 install gdown --break-system-packages -q
fi

if ! command -v docker &> /dev/null; then
  echo "🐳 Docker not found. Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  echo "✅ Docker installed."
fi

# ─────────────────────────────────────────
# STEP 2 — Download zip dari Google Drive
# ─────────────────────────────────────────
cd ${REPO_DIR}

if [ -f "${ZIP_NAME}" ]; then
  echo "⬇️  Zip already exists, skipping download."
else
  echo "⬇️  Downloading Creatio zip from Google Drive..."
  gdown "https://drive.google.com/uc?id=${GDRIVE_FILE_ID}" -O ${ZIP_NAME}
fi

# ─────────────────────────────────────────
# STEP 3 — Extract zip
# ─────────────────────────────────────────
if [ -f "${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll" ]; then
  echo "📂 creatio-app already deployed, skipping extract."
  INNER_DIR=""
else
  echo "📂 Extracting zip..."
  rm -rf ${EXTRACT_DIR}
  unzip -q ${ZIP_NAME} -d ${EXTRACT_DIR}
  if [ -f "${EXTRACT_DIR}/Terrasoft.WebHost.dll" ]; then
    INNER_DIR=${EXTRACT_DIR}
  else
    INNER_DIR=$(find ${EXTRACT_DIR} -name "Terrasoft.WebHost.dll" -maxdepth 3 | xargs dirname | head -1)
  fi
  echo "📁 App root: ${INNER_DIR}"
fi

# ─────────────────────────────────────────
# STEP 4 — Siapkan folder deploy
# ─────────────────────────────────────────
mkdir -p ${DEPLOY_DIR}/creatio-app
mkdir -p ${DEPLOY_DIR}/db-backup

if [ -n "$INNER_DIR" ]; then
  echo "🔧 Copying creatio-app to deploy directory..."
  rsync -a --exclude='/db/' ${INNER_DIR}/ ${DEPLOY_DIR}/creatio-app/

  DB_FILE=$(find ${INNER_DIR}/db -type f | head -1)
  if [ -n "$DB_FILE" ]; then
    echo "🗄️  Found DB file: $DB_FILE"
    cp "$DB_FILE" ${DEPLOY_DIR}/db-backup/creatio.backup
  else
    echo "⚠️  No DB file found in /db folder!"
  fi
else
  echo "🔧 creatio-app already exists, skipping copy."
  echo "🗄️  DB backup already exists, skipping copy."
fi

cp ${REPO_DIR}/db-backup/restore.sh ${DEPLOY_DIR}/db-backup/restore.sh
chmod +x ${DEPLOY_DIR}/db-backup/restore.sh

echo "🧹 Cleaning up extract folder..."
rm -rf ${EXTRACT_DIR}
docker image prune -f 2>/dev/null || true
echo "✅ Cleanup done."

# ─────────────────────────────────────────
# STEP 5 — Setup .env
# ─────────────────────────────────────────
ENV_FILE="${DEPLOY_DIR}/.env"

# Auto assign port
BASE_PORT=8080
USED_PORTS=$(docker ps --format "{{.Ports}}" | grep -oE '0\.0\.0\.0:[0-9]+' | grep -oE '[0-9]+$' | sort -n)

find_free_port() {
  local port=$1
  while echo "$USED_PORTS" | grep -q "^${port}$"; do
    port=$((port + 1))
  done
  echo $port
}

CREATIO_PORT=$(find_free_port $BASE_PORT)
CREATIO_HTTPS_PORT=$(find_free_port $((CREATIO_PORT + 363)))

if [ ! -f "$ENV_FILE" ]; then
  cp ${REPO_DIR}/.env.example ${ENV_FILE}
  sed -i "s/^POSTGRES_DB=.*/POSTGRES_DB=creatio_${INSTANCE}/" "$ENV_FILE"
  sed -i "s/^CREATIO_PORT=.*/CREATIO_PORT=${CREATIO_PORT}/" "$ENV_FILE"
  sed -i "s/^CREATIO_HTTPS_PORT=.*/CREATIO_HTTPS_PORT=${CREATIO_HTTPS_PORT}/" "$ENV_FILE"

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
  echo "║     ./deploy-server.sh ${INSTANCE}"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  exit 0
fi

# Tambahkan variable yang missing dari .env.example
while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  KEY=$(echo "$line" | cut -d= -f1)
  if ! grep -q "^${KEY}=" "$ENV_FILE"; then
    echo "$line" >> "$ENV_FILE"
    echo "➕ Added missing variable: ${KEY}"
  fi
done < ${REPO_DIR}/.env.example

# Load nilai dari .env
POSTGRES_HOST=$(grep '^POSTGRES_HOST=' $ENV_FILE | cut -d= -f2)
POSTGRES_DB=$(grep '^POSTGRES_DB=' $ENV_FILE | cut -d= -f2)
POSTGRES_USER=$(grep '^POSTGRES_USER=' $ENV_FILE | cut -d= -f2)
POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' $ENV_FILE | cut -d= -f2-)
REDIS_HOST=$(grep '^REDIS_HOST=' $ENV_FILE | cut -d= -f2)
REDIS_PASSWORD=$(grep '^REDIS_PASSWORD=' $ENV_FILE | cut -d= -f2-)
CREATIO_PORT=$(grep '^CREATIO_PORT=' $ENV_FILE | cut -d= -f2)
CREATIO_HTTPS_PORT=$(grep '^CREATIO_HTTPS_PORT=' $ENV_FILE | cut -d= -f2)
PGADMIN_PORT=$(grep '^PGADMIN_PORT=' $ENV_FILE | cut -d= -f2)
PGADMIN_EMAIL=$(grep '^PGADMIN_EMAIL=' $ENV_FILE | cut -d= -f2)
PGADMIN_PASSWORD=$(grep '^PGADMIN_PASSWORD=' $ENV_FILE | cut -d= -f2-)
ENABLE_FILE_SYSTEM=$(grep '^ENABLE_FILE_SYSTEM=' $ENV_FILE | cut -d= -f2)
COOKIES_SAME_SITE_MODE=$(grep '^COOKIES_SAME_SITE_MODE=' $ENV_FILE | cut -d= -f2)

# ─────────────────────────────────────────
# STEP 6 — Pastikan shared services jalan
# ─────────────────────────────────────────
echo "🔍 Checking shared services (postgres, redis, pgadmin)..."
mkdir -p ${SHARED_DIR}

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
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

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

if ! docker ps | grep -q "creatio-postgres"; then
  echo "🐳 Starting shared services..."
  docker compose -f "$SHARED_COMPOSE" up -d
  echo "⏳ Waiting for postgres to be ready..."
  sleep 15
else
  echo "✅ Shared services already running."
fi

# Buat DB dan restore kalau belum ada
POSTGRES_MAINTENANCE_DB=$(grep '^POSTGRES_MAINTENANCE_DB=' $ENV_FILE | cut -d= -f2)

DB_EXISTS=$(docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_MAINTENANCE_DB} -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_DB}'" 2>/dev/null || echo "")

if [ "$DB_EXISTS" != "1" ]; then
  echo "🗄️  Creating database ${POSTGRES_DB}..."
  docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_MAINTENANCE_DB} -c "CREATE DATABASE ${POSTGRES_DB};"

  if [ -f "${DEPLOY_DIR}/db-backup/creatio.backup" ]; then
    echo "🔄 Restoring database..."
    docker exec -i creatio-postgres pg_restore \
      -U ${POSTGRES_USER} \
      -d ${POSTGRES_DB} \
      --no-password \
      -v \
      < ${DEPLOY_DIR}/db-backup/creatio.backup 2>/dev/null || true
    echo "✅ Database restored."
  fi
else
  echo "✅ Database ${POSTGRES_DB} already exists."
fi

# Auto assign Redis db number
REDIS_DB=0
for dir in ${BASE_DIR}/*/; do
  if [ -f "${dir}.env" ] && [ "${dir}" != "${DEPLOY_DIR}/" ] && [ "${dir}" != "${SHARED_DIR}/" ]; then
    USED_REDIS_DB=$(grep '^REDIS_DB=' "${dir}.env" 2>/dev/null | cut -d= -f2)
    if [ -n "$USED_REDIS_DB" ] && [ "$USED_REDIS_DB" = "$REDIS_DB" ]; then
      REDIS_DB=$((REDIS_DB + 1))
    fi
  fi
done

if ! grep -q "^REDIS_DB=" "$ENV_FILE"; then
  echo "REDIS_DB=${REDIS_DB}" >> "$ENV_FILE"
fi
REDIS_DB=$(grep '^REDIS_DB=' $ENV_FILE | cut -d= -f2)

# ─────────────────────────────────────────
# STEP 7 — Generate ConnectionStrings.config
# ─────────────────────────────────────────
echo "⚙️  Generating ConnectionStrings.config from .env..."

cat > ${DEPLOY_DIR}/creatio-app/ConnectionStrings.config << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<connectionStrings>
  <add name="db" connectionString="Server=${POSTGRES_HOST};Port=5432;Database=${POSTGRES_DB};User ID=${POSTGRES_USER};password=${POSTGRES_PASSWORD};Timeout=500; CommandTimeout=400;MaxPoolSize=1024;" />
  <add name="dbPostgreSql" connectionString="Pooling=true; Database=${POSTGRES_DB}; Host=${POSTGRES_HOST}; Port=5432; Username=${POSTGRES_USER}; Password=${POSTGRES_PASSWORD}; Timeout=5; CommandTimeout=400" />
  <add name="redis" connectionString="host=${REDIS_HOST};db=${REDIS_DB};port=6379;password=${REDIS_PASSWORD}" />
  <add name="dbMssqlCore" connectionString="Data Source=tscore-ms-01\mssql2008; Initial Catalog=BPMonlineCore; Persist Security Info=True; MultipleActiveResultSets=True; Integrated Security=SSPI; Pooling = true; Max Pool Size = 100; Async = true" />
  <add name="dbMssqlUnitTest" connectionString="Data Source=TSAppHost-02; Initial Catalog=BPMonlineUnitTest; Persist Security Info=True; MultipleActiveResultSets=True; User ID=UnitTest; Password=UnitTest; Async = true" />
  <add name="tempDirectoryPath" connectionString="%TEMP%/%USER%/%APPLICATION%" />
  <add name="consumerInfoServiceUri" connectionString="http://sso.bpmonline.com:4566/ConsumerInfoService.svc" />
  <add name="consumerInfoServiceAccessInfoPageUri" connectionString="http://sso.bpmonline.com:4566/AccessInfoPage.aspx" />
  <add name="logstashConfigFolderPath" connectionString="%TEMP%\%APPLICATION%\LogstashConfig" />
  <add name="elasticsearchCredentials" connectionString="User=gs-es; Password=DEQpJMfKqUVTWg9wYVgi;" />
  <add name="influx" connectionString="url=http://10.0.7.161:30359; user=; password=; batchIntervalMs=5000" />
  <add name="clientPerformanceLoggerServiceUri" connectionString="http://tsbuild-k8s-m1:30001/" />
  <add name="messageBroker" connectionString="amqp://guest:guest@localhost/BPMonlineSolution" />
</connectionStrings>
XMLEOF

echo "✅ ConnectionStrings.config generated."

# ─────────────────────────────────────────
# STEP 8 — Update Terrasoft.WebHost.dll.config
# ─────────────────────────────────────────
echo "⚙️  Updating Terrasoft.WebHost.dll.config..."

CONFIG_FILE="${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll.config"

if [ -f "$CONFIG_FILE" ]; then
  if [ "$ENABLE_FILE_SYSTEM" = "true" ]; then
    sed -i 's/<fileDesignMode enabled="false" \/>/<fileDesignMode enabled="true" \/>/' "$CONFIG_FILE"
    sed -i 's/key="UseStaticFileContent" value="true" \//key="UseStaticFileContent" value="false" \//g' "$CONFIG_FILE"
    echo "   ✅ FileSystem mode enabled."
  else
    sed -i 's/<fileDesignMode enabled="true" \/>/<fileDesignMode enabled="false" \/>/' "$CONFIG_FILE"
    sed -i 's/key="UseStaticFileContent" value="false" \//key="UseStaticFileContent" value="true" \//g' "$CONFIG_FILE"
    echo "   ✅ FileSystem mode disabled."
  fi

  if [ -n "$COOKIES_SAME_SITE_MODE" ]; then
    sed -i "s/key=\"CookiesSameSiteMode\" value=\"[^\"]*\" \//key=\"CookiesSameSiteMode\" value=\"${COOKIES_SAME_SITE_MODE}\" \//g" "$CONFIG_FILE"
    echo "   ✅ CookiesSameSiteMode set to ${COOKIES_SAME_SITE_MODE}."
  fi
  echo "✅ Terrasoft.WebHost.dll.config updated."
else
  echo "⚠️  Terrasoft.WebHost.dll.config not found, skipping."
fi

# ─────────────────────────────────────────
# STEP 8b — Setup OAuth 2.0
# ─────────────────────────────────────────
ENABLE_OAUTH=$(grep '^ENABLE_OAUTH=' $ENV_FILE | cut -d= -f2)
OAUTH_IDENTITY_URL=$(grep '^OAUTH_IDENTITY_URL=' $ENV_FILE | cut -d= -f2)
OAUTH_CLIENT_ID=$(grep '^OAUTH_CLIENT_ID=' $ENV_FILE | cut -d= -f2)
OAUTH_CLIENT_SECRET=$(grep '^OAUTH_CLIENT_SECRET=' $ENV_FILE | cut -d= -f2-)
IDENTITY_COMPOSE=""

if [ "$ENABLE_OAUTH" = "true" ]; then
  echo "🔐 Setting up OAuth 2.0..."

  # Auto-assign port Identity Service kalau belum pernah di-assign.
  # Disimpan ke .env biar stabil tiap re-run.
  OAUTH_IDENTITY_PORT=$(grep '^OAUTH_IDENTITY_PORT=' $ENV_FILE | cut -d= -f2)
  if [ -z "$OAUTH_IDENTITY_PORT" ]; then
    # port yang dipakai = container running + port tersimpan di instance lain
    USED_PORTS=$(
      {
        docker ps --format "{{.Ports}}" | grep -oE '0\.0\.0\.0:[0-9]+' | grep -oE '[0-9]+$'
        for dir in ${BASE_DIR}/*/; do
          [ "${dir}" = "${SHARED_DIR}/" ] && continue
          [ -f "${dir}.env" ] && grep -hE '^(CREATIO_PORT|CREATIO_HTTPS_PORT|OAUTH_IDENTITY_PORT)=' "${dir}.env" | cut -d= -f2
        done
      } | sort -n -u
    )
    OAUTH_IDENTITY_PORT=$(find_free_port 9080)
    echo "OAUTH_IDENTITY_PORT=${OAUTH_IDENTITY_PORT}" >> "$ENV_FILE"
    echo "   ➕ Auto-assigned OAuth Identity port: ${OAUTH_IDENTITY_PORT}"
  fi

  # Susun OAUTH_IDENTITY_URL dari IP server + port, lalu persist ke .env
  SERVER_IP=$(curl -s -4 ifconfig.me)
  OAUTH_IDENTITY_URL="http://${SERVER_IP}:${OAUTH_IDENTITY_PORT}"
  if grep -q '^OAUTH_IDENTITY_URL=' "$ENV_FILE"; then
    sed -i "s|^OAUTH_IDENTITY_URL=.*|OAUTH_IDENTITY_URL=${OAUTH_IDENTITY_URL}|" "$ENV_FILE"
  else
    echo "OAUTH_IDENTITY_URL=${OAUTH_IDENTITY_URL}" >> "$ENV_FILE"
  fi
  echo "   🔗 Identity URL: ${OAUTH_IDENTITY_URL}"

  # ── Siapkan Identity Service (extract zip → cert → appsettings per-instance) ──
  IDENTITY_DIR="${DEPLOY_DIR}/identity"
  IDENTITY_ZIP="${DEPLOY_DIR}/creatio-app/IdentityService.zip"

  if [ ! -f "${IDENTITY_DIR}/IdentityService.dll" ]; then
    if [ -f "$IDENTITY_ZIP" ]; then
      echo "   📂 Extracting IdentityService.zip..."
      mkdir -p "$IDENTITY_DIR"
      unzip -q -o "$IDENTITY_ZIP" -d "$IDENTITY_DIR"
    else
      echo "   ❌ IdentityService.zip tidak ditemukan di creatio-app. OAuth gagal disiapkan."
      exit 1
    fi
  fi

  # Generate sertifikat openssl.pfx kalau belum ada (dibutuhkan IdentityService di /app).
  # Generate langsung pakai openssl (script bawaan zip ber-line-ending CRLF, tidak dipakai).
  if [ ! -f "${IDENTITY_DIR}/openssl.pfx" ]; then
    echo "   🔑 Generating openssl.pfx..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 1095 \
      -keyout "${IDENTITY_DIR}/.key.pem" -out "${IDENTITY_DIR}/.cert.pem" \
      -subj "/C=CY/L=Nicosia/O=CREATIO EMEA LTD" >/dev/null 2>&1
    openssl pkcs12 -export -out "${IDENTITY_DIR}/openssl.pfx" \
      -inkey "${IDENTITY_DIR}/.key.pem" -in "${IDENTITY_DIR}/.cert.pem" \
      -passout pass: >/dev/null 2>&1
    rm -f "${IDENTITY_DIR}/.key.pem" "${IDENTITY_DIR}/.cert.pem"
    if [ ! -f "${IDENTITY_DIR}/openssl.pfx" ]; then
      echo "   ❌ Gagal generate openssl.pfx (cek instalasi openssl)."
      exit 1
    fi
  fi

  # Generate appsettings.json khusus instance ini.
  # Pakai appsettings.json bawaan zip sebagai basis, lalu modif via python3
  # (DB, CORS, dan Clients) — biar struktur nested yang rumit tetap utuh.
  REDIRECT_BASE="${OAUTH_IDENTITY_REDIRECT:-http://${SERVER_IP}:${CREATIO_PORT}}"
  echo "   ⚙️  Writing identity appsettings.json (DB=${POSTGRES_DB}, redirect=${REDIRECT_BASE})..."
  python3 - "${IDENTITY_DIR}/appsettings.json" "${POSTGRES_HOST}" "${POSTGRES_DB}" "${POSTGRES_USER}" "${POSTGRES_PASSWORD}" "${REDIRECT_BASE}" "${OAUTH_CLIENT_ID}" "${OAUTH_CLIENT_SECRET}" << 'PY'
import json, sys
path, host, db, user, pw, base, cid, secret = sys.argv[1:9]
with open(path, encoding="utf-8-sig") as f:
    cfg = json.load(f)
conn = f"Host={host};Port=5432;Database={db};Username={user};Password={pw}"
cfg["DbProvider"] = "Postgres"
# Versi IdentityService dari zip membaca "DatabaseConnectionString" (bukan
# "PostgresConnection"). Set keduanya supaya cocok lintas versi.
cfg["DatabaseConnectionString"] = conn
cfg["PostgresConnection"] = conn
cfg["AllowedCorsOrigins"] = json.dumps([base])
try:
    clients = json.loads(cfg.get("Clients", "[]"))
except (ValueError, TypeError):
    clients = []
if not clients:
    clients = [{}]
c = clients[0]
c["ClientId"] = cid
c.setdefault("ClientName", "CreatioClient")
c["Secrets"] = [secret]
c["RedirectUris"] = [base, base + "/lib", base + "/lib/"]
c["PostLogoutRedirectUris"] = [base]
cfg["Clients"] = json.dumps(clients)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("   ✅ identity appsettings.json updated")
PY

  # Blok service identity yang akan disisipkan ke docker-compose instance (STEP 9)
  IDENTITY_COMPOSE="
  identity:
    build:
      context: ./identity
      dockerfile: Dockerfile-OAuth
    container_name: creatio-identity-${INSTANCE}
    restart: unless-stopped
    ports:
      - \"${OAUTH_IDENTITY_PORT}:80\"
    networks:
      - creatio-shared
"
  echo "   🐳 Identity Service akan di-deploy: creatio-identity-${INSTANCE} (port ${OAUTH_IDENTITY_PORT})."

  docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    UPDATE \"AdminUnitFeatureState\"
    SET \"FeatureState\" = 1
    WHERE \"FeatureId\" = (
      SELECT \"Id\" FROM \"Feature\"
      WHERE \"Code\" = 'OAuth20Integration'
    )" 2>/dev/null || true

  docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    UPDATE \"SysSettingsValue\" SET \"TextValue\" = '${OAUTH_IDENTITY_URL}'
    WHERE \"SysSettingsId\" = (SELECT \"Id\" FROM \"SysSettings\" WHERE \"Code\" = 'OAuth20IdentityServerUrl');" 2>/dev/null || true

  docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    UPDATE \"SysSettingsValue\" SET \"TextValue\" = '${OAUTH_CLIENT_ID}'
    WHERE \"SysSettingsId\" = (SELECT \"Id\" FROM \"SysSettings\" WHERE \"Code\" = 'OAuth20IdentityServerClientId');" 2>/dev/null || true

  docker exec creatio-postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    UPDATE \"SysSettingsValue\" SET \"TextValue\" = '${OAUTH_CLIENT_SECRET}'
    WHERE \"SysSettingsId\" = (SELECT \"Id\" FROM \"SysSettings\" WHERE \"Code\" = 'OAuth20IdentityServerClientSecret');" 2>/dev/null || true

  echo "   ✅ OAuth 2.0 configured."
else
  echo "🔐 OAuth 2.0 disabled, skipping."
fi

# ─────────────────────────────────────────
# STEP 9 — Buat docker-compose per instance
# ─────────────────────────────────────────
echo "🐳 Preparing docker-compose for instance ${INSTANCE}..."

cp ${REPO_DIR}/Dockerfile ${DEPLOY_DIR}/

cat > ${DEPLOY_DIR}/docker-compose.yaml << YAML
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
${IDENTITY_COMPOSE}
volumes:
  creatio-${INSTANCE}-logs:

networks:
  creatio-shared:
    external: true
    name: shared_creatio-shared
YAML

# ─────────────────────────────────────────
# STEP 10 — Start container
# ─────────────────────────────────────────
echo "🚀 Starting Creatio instance: ${INSTANCE}..."
cd ${DEPLOY_DIR}
docker compose down 2>/dev/null || true
docker compose up -d --build

SERVER_IP=$(curl -s -4 ifconfig.me)

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           ✅ DEPLOY COMPLETE                     ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Instance : ${INSTANCE}"
echo "║  Creatio  : http://${SERVER_IP}:${CREATIO_PORT}"
echo "║  pgAdmin  : http://${SERVER_IP}:${PGADMIN_PORT}"
echo "║  DB       : ${POSTGRES_DB}"
echo "║  Redis DB : ${REDIS_DB}"
if [ "$ENABLE_OAUTH" = "true" ]; then
echo "║  Identity : ${OAUTH_IDENTITY_URL}"
fi
echo "╚══════════════════════════════════════════════════╝"

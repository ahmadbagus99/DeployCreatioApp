#!/bin/bash
set -e

# ─────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────
GDRIVE_FILE_ID="1qKkJs1Gk5jNPxuXBVlHh-C8rpl0Lz3X2"
ZIP_NAME="creatio.zip"
EXTRACT_DIR="creatio-extracted"
DEPLOY_DIR="/opt/creatio"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────
# STEP 1 — Install dependencies
# ─────────────────────────────────────────
echo "📦 Checking dependencies..."
rm -f /etc/apt/sources.list.d/jenkins.list
rm -f /etc/apt/sources.list.d/jenkins.list.save
apt update -qq
apt install -y -qq python3-pip unzip rsync curl

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
fi
echo "📁 App root: ${INNER_DIR}"

# ─────────────────────────────────────────
# STEP 4 — Siapkan folder deploy
# ─────────────────────────────────────────
if [ -f "${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll" ]; then
  echo "🔧 creatio-app already exists, skipping copy."
else
  echo "🔧 Copying creatio-app to deploy directory..."
  mkdir -p ${DEPLOY_DIR}/creatio-app
  rsync -a --exclude='/db/' ${INNER_DIR}/ ${DEPLOY_DIR}/creatio-app/
fi

if [ -f "${DEPLOY_DIR}/db-backup/creatio.backup" ]; then
  echo "🗄️  DB backup already exists, skipping copy."
else
  mkdir -p ${DEPLOY_DIR}/db-backup
  DB_FILE=$(find ${INNER_DIR}/db -type f | head -1)
  if [ -n "$DB_FILE" ]; then
    echo "🗄️  Found DB file: $DB_FILE"
    cp "$DB_FILE" ${DEPLOY_DIR}/db-backup/creatio.backup
  else
    echo "⚠️  No DB file found in /db folder!"
  fi
fi

cp docker-compose.yaml ${DEPLOY_DIR}/
cp Dockerfile ${DEPLOY_DIR}/
cp db-backup/restore.sh ${DEPLOY_DIR}/db-backup/restore.sh
chmod +x ${DEPLOY_DIR}/db-backup/restore.sh

echo "🧹 Cleaning up to free disk space..."
rm -rf ${EXTRACT_DIR}
docker system prune -af --volumes 2>/dev/null || true
echo "✅ Cleanup done."

# ─────────────────────────────────────────
# STEP 5 — Setup .env
# ─────────────────────────────────────────
if [ ! -f "${DEPLOY_DIR}/.env" ]; then
  cp ${REPO_DIR}/.env.example ${DEPLOY_DIR}/.env
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║           ⚠️  SETUP REQUIRED                     ║"
  echo "╠══════════════════════════════════════════════════╣"
  echo "║  .env file created at:                           ║"
  echo "║  /opt/creatio/.env                               ║"
  echo "║                                                  ║"
  echo "║  1. Edit .env:                                   ║"
  echo "║     nano /opt/creatio/.env                       ║"
  echo "║                                                  ║"
  echo "║  2. Re-run deploy:                               ║"
  echo "║     ./deploy.sh                                  ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  exit 0
fi

# Tambahkan variable yang missing dari .env.example
while IFS= read -r line; do
  [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
  KEY=$(echo "$line" | cut -d= -f1)
  if ! grep -q "^${KEY}=" "${DEPLOY_DIR}/.env"; then
    echo "$line" >> "${DEPLOY_DIR}/.env"
    echo "➕ Added missing variable: ${KEY}"
  fi
done < ${REPO_DIR}/.env.example

# ─────────────────────────────────────────
# STEP 6 — Generate ConnectionStrings.config
# ─────────────────────────────────────────
echo "⚙️  Generating ConnectionStrings.config from .env..."

POSTGRES_HOST=$(grep '^POSTGRES_HOST=' ${DEPLOY_DIR}/.env | cut -d= -f2)
POSTGRES_DB=$(grep '^POSTGRES_DB=' ${DEPLOY_DIR}/.env | cut -d= -f2)
POSTGRES_USER=$(grep '^POSTGRES_USER=' ${DEPLOY_DIR}/.env | cut -d= -f2)
POSTGRES_PASSWORD=$(grep '^POSTGRES_PASSWORD=' ${DEPLOY_DIR}/.env | cut -d= -f2-)
REDIS_HOST=$(grep '^REDIS_HOST=' ${DEPLOY_DIR}/.env | cut -d= -f2)
REDIS_PASSWORD=$(grep '^REDIS_PASSWORD=' ${DEPLOY_DIR}/.env | cut -d= -f2-)
CREATIO_PORT=$(grep '^CREATIO_PORT=' ${DEPLOY_DIR}/.env | cut -d= -f2)
PGADMIN_PORT=$(grep '^PGADMIN_PORT=' ${DEPLOY_DIR}/.env | cut -d= -f2)

cat > ${DEPLOY_DIR}/creatio-app/ConnectionStrings.config << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<connectionStrings>
  <add name="db" connectionString="Server=${POSTGRES_HOST};Port=5432;Database=${POSTGRES_DB};User ID=${POSTGRES_USER};password=${POSTGRES_PASSWORD};Timeout=500; CommandTimeout=400;MaxPoolSize=1024;" />
  <add name="dbPostgreSql" connectionString="Pooling=true; Database=${POSTGRES_DB}; Host=${POSTGRES_HOST}; Port=5432; Username=${POSTGRES_USER}; Password=${POSTGRES_PASSWORD}; Timeout=5; CommandTimeout=400" />
  <add name="redis" connectionString="host=${REDIS_HOST};db=0;port=6379;password=${REDIS_PASSWORD}" />
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
# STEP 6b — Update Terrasoft.WebHost.dll.config
# ─────────────────────────────────────────
echo "⚙️  Updating Terrasoft.WebHost.dll.config..."

CONFIG_FILE="${DEPLOY_DIR}/creatio-app/Terrasoft.WebHost.dll.config"
ENABLE_FILE_SYSTEM=$(grep '^ENABLE_FILE_SYSTEM=' ${DEPLOY_DIR}/.env | cut -d= -f2)
COOKIES_SAME_SITE_MODE=$(grep '^COOKIES_SAME_SITE_MODE=' ${DEPLOY_DIR}/.env | cut -d= -f2)

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
# STEP 6c — Setup OAuth 2.0
# ─────────────────────────────────────────
ENABLE_OAUTH=$(grep '^ENABLE_OAUTH=' ${DEPLOY_DIR}/.env | cut -d= -f2)
OAUTH_IDENTITY_URL=$(grep '^OAUTH_IDENTITY_URL=' ${DEPLOY_DIR}/.env | cut -d= -f2)
OAUTH_CLIENT_ID=$(grep '^OAUTH_CLIENT_ID=' ${DEPLOY_DIR}/.env | cut -d= -f2)
OAUTH_CLIENT_SECRET=$(grep '^OAUTH_CLIENT_SECRET=' ${DEPLOY_DIR}/.env | cut -d= -f2-)

if [ "$ENABLE_OAUTH" = "true" ]; then
  echo "🔐 Setting up OAuth 2.0..."

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
# STEP 7 — Docker compose up
# ─────────────────────────────────────────
echo "🐳 Starting containers..."
cd ${DEPLOY_DIR}
docker compose down -v 2>/dev/null || true
docker compose up -d --build

SERVER_IP=$(curl -s -4 ifconfig.me)

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║           ✅ DEPLOY COMPLETE                     ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  Creatio  : http://${SERVER_IP}:${CREATIO_PORT}"
echo "║  pgAdmin  : http://${SERVER_IP}:${PGADMIN_PORT}"
if [ "$ENABLE_OAUTH" = "true" ]; then
echo "║  Identity : ${OAUTH_IDENTITY_URL}"
fi
echo "╚══════════════════════════════════════════════════╝"

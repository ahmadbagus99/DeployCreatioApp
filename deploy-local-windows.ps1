param(
  [Parameter(Mandatory = $true)]
  [string]$Instance
)

$ErrorActionPreference = "Stop"

$GDriveFileId = "1qKkJs1Gk5jNPxuXBVlHh-C8rpl0Lz3X2"
$ZipName = "creatio.zip"
$ExtractDirName = "creatio-extracted"
$BaseDir = "C:\CreatioApp"
$DeployDir = Join-Path $BaseDir $Instance
$SharedDir = Join-Path $BaseDir "shared"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $DeployDir ".env"
$BoxV = [char]0x2551
$BoxTop = "$([char]0x2554)$(([char]0x2550).ToString() * 50)$([char]0x2557)"
$BoxMid = "$([char]0x2560)$(([char]0x2550).ToString() * 50)$([char]0x2563)"
$BoxBottom = "$([char]0x255A)$(([char]0x2550).ToString() * 50)$([char]0x255D)"
$BoxBlank = "$BoxV                                                  $BoxV"
$WarnIcon = "$([char]0x26A0)$([char]0xFE0F)"
$DoneIcon = "$([char]0x2705)"

function Assert-Command {
  param([string]$Name, [string]$InstallHint)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name is required. $InstallHint"
  }
}

function Assert-DockerRunning {
  cmd.exe /c "docker info >nul 2>nul"
  if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running or the active Docker context is unavailable. Start Docker Desktop, wait until it is ready, then re-run: .\deploy-local-windows.ps1 $Instance"
  }
}

function Get-PythonCommand {
  foreach ($name in @("py", "python", "python3")) {
    if (Get-Command $name -ErrorAction SilentlyContinue) {
      return $name
    }
  }
  throw "Python is required. Install Python 3 and re-run this script."
}

function Invoke-Python {
  param([string[]]$PythonArgs)
  & $script:PythonCommand @PythonArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Python command failed: $($PythonArgs -join ' ')"
  }
}

function Get-EnvValue {
  param([string]$Key)
  $line = Get-Content $EnvFile -Encoding UTF8 | Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -Last 1
  if (-not $line) { return "" }
  return ($line -split "=", 2)[1]
}

function Set-EnvValue {
  param([string]$Key, [string]$Value)
  $lines = if (Test-Path $EnvFile) { @(Get-Content $EnvFile -Encoding UTF8) } else { @() }
  $found = $false
  $updated = foreach ($line in $lines) {
    if ($line -match "^$([regex]::Escape($Key))=") {
      $found = $true
      "$Key=$Value"
    } else {
      $line
    }
  }
  if (-not $found) {
    $updated += "$Key=$Value"
  }
  Set-Content -Path $EnvFile -Value $updated -Encoding UTF8
}

function Add-MissingEnvValues {
  $example = Join-Path $RepoDir ".env.example"
  foreach ($line in Get-Content $example -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
      continue
    }
    $key = ($line -split "=", 2)[0]
    if (-not (Select-String -Path $EnvFile -Pattern "^$([regex]::Escape($key))=" -Quiet)) {
      Add-Content -Path $EnvFile -Value $line -Encoding UTF8
      Write-Host "Added missing variable: $key"
    }
  }
}

function Get-UsedPorts {
  $ports = docker ps --format "{{.Ports}}" | Select-String -AllMatches "0\.0\.0\.0:(\d+)|:::(\d+)"
  $result = @()
  foreach ($matchInfo in $ports) {
    foreach ($match in $matchInfo.Matches) {
      $value = if ($match.Groups[1].Value) { $match.Groups[1].Value } else { $match.Groups[2].Value }
      $result += [int]$value
    }
  }
  return $result | Sort-Object -Unique
}

function Find-FreePort {
  param([int]$StartPort, [int[]]$UsedPorts)
  $port = $StartPort
  while ($UsedPorts -contains $port) {
    $port++
  }
  return $port
}

function Copy-AppWithoutDb {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /E /XD (Join-Path $Source "db") | Out-Host
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed with exit code $LASTEXITCODE"
  }
}

function Write-ConnectionStrings {
  param(
    [string]$Path,
    [string]$PostgresHost,
    [string]$PostgresDb,
    [string]$PostgresUser,
    [string]$PostgresPassword,
    [string]$RedisHost,
    [string]$RedisPassword,
    [string]$RedisDb
  )

  $ConnectionStringsContent = @"
<?xml version="1.0" encoding="utf-8"?>
<connectionStrings>
  <add name="db" connectionString="Server=$PostgresHost;Port=5432;Database=$PostgresDb;User ID=$PostgresUser;password=$PostgresPassword;Timeout=500; CommandTimeout=400;MaxPoolSize=1024;" />
  <add name="dbPostgreSql" connectionString="Pooling=true; Database=$PostgresDb; Host=$PostgresHost; Port=5432; Username=$PostgresUser; Password=$PostgresPassword; Timeout=5; CommandTimeout=400" />
  <add name="redis" connectionString="host=$RedisHost;db=$RedisDb;port=6379;password=$RedisPassword" />
  <add name="messageBroker" connectionString="amqp://guest:guest@localhost/BPMonlineSolution" />
</connectionStrings>
"@
  Set-Content -Path $Path -Value $ConnectionStringsContent -Encoding UTF8
}

function Update-WebHostConfig {
  param([string]$Path, [string]$EnableFileSystem, [string]$CookiesSameSiteMode)
  if (-not (Test-Path $Path)) {
    Write-Host "Terrasoft.WebHost.dll.config not found, skipping."
    return
  }

  $content = Get-Content -Path $Path -Raw
  if ($EnableFileSystem -eq "true") {
    $content = $content -replace '<fileDesignMode enabled="false" />', '<fileDesignMode enabled="true" />'
    $content = $content -replace 'key="UseStaticFileContent" value="true" /', 'key="UseStaticFileContent" value="false" /'
  } else {
    $content = $content -replace '<fileDesignMode enabled="true" />', '<fileDesignMode enabled="false" />'
    $content = $content -replace 'key="UseStaticFileContent" value="false" /', 'key="UseStaticFileContent" value="true" /'
  }
  if ($CookiesSameSiteMode) {
    $content = $content -replace 'key="CookiesSameSiteMode" value="[^"]*" /', "key=`"CookiesSameSiteMode`" value=`"$CookiesSameSiteMode`" /"
  }
  Set-Content -Path $Path -Value $content -Encoding UTF8
}

function Restore-Database {
  param([string]$BackupPath, [string]$PostgresUser, [string]$PostgresDb)
  if (-not (Test-Path $BackupPath)) {
    return
  }

  Write-Host "Restoring database..."
  $restoreCommand = 'docker exec -i creatio-postgres pg_restore -U "{0}" -d "{1}" --no-password -v < "{2}"' -f $PostgresUser, $PostgresDb, $BackupPath
  cmd.exe /c $restoreCommand
  if ($LASTEXITCODE -ne 0) {
    Write-Host "pg_restore exited with code $LASTEXITCODE. Continuing because some restores report non-fatal object conflicts."
  }
}

Write-Host "Checking dependencies..."
Assert-Command docker "Install Docker Desktop and make sure it is running."
Assert-Command robocopy "robocopy is included with Windows. Run this script from Windows PowerShell."
Assert-DockerRunning
$script:PythonCommand = Get-PythonCommand

if (-not (Get-Command gdown -ErrorAction SilentlyContinue)) {
  Write-Host "Installing gdown..."
  Invoke-Python @("-m", "pip", "install", "gdown", "-q")
}

Set-Location $RepoDir
$ZipPath = Join-Path $RepoDir $ZipName
if (Test-Path $ZipPath) {
  Write-Host "Zip already exists, skipping download."
} else {
  Write-Host "Downloading Creatio zip from Google Drive..."
  Invoke-Python @("-m", "gdown", "https://drive.google.com/uc?id=$GDriveFileId", "-O", $ZipPath)
}

$CreatioDll = Join-Path $DeployDir "creatio-app\Terrasoft.WebHost.dll"
$ExtractDir = Join-Path $RepoDir $ExtractDirName
if (Test-Path $CreatioDll) {
  Write-Host "creatio-app already deployed, skipping extract."
  $InnerDir = $null
} else {
  Write-Host "Extracting zip..."
  if (Test-Path $ExtractDir) {
    Remove-Item -LiteralPath $ExtractDir -Recurse -Force
  }
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractDir -Force
  if (Test-Path (Join-Path $ExtractDir "Terrasoft.WebHost.dll")) {
    $InnerDir = $ExtractDir
  } else {
    $dll = Get-ChildItem -Path $ExtractDir -Filter "Terrasoft.WebHost.dll" -Recurse | Select-Object -First 1
    if (-not $dll) {
      throw "Terrasoft.WebHost.dll not found in extracted zip."
    }
    $InnerDir = $dll.Directory.FullName
  }
  Write-Host "App root: $InnerDir"
}

New-Item -ItemType Directory -Force -Path (Join-Path $DeployDir "creatio-app") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DeployDir "db-backup") | Out-Null

if ($InnerDir) {
  Write-Host "Copying creatio-app to deploy directory..."
  Copy-AppWithoutDb -Source $InnerDir -Destination (Join-Path $DeployDir "creatio-app")

  $DbDir = Join-Path $InnerDir "db"
  $DbFile = if (Test-Path $DbDir) { Get-ChildItem -Path $DbDir -File -Recurse | Select-Object -First 1 } else { $null }
  if ($DbFile) {
    Write-Host "Found DB file: $($DbFile.FullName)"
    Copy-Item -LiteralPath $DbFile.FullName -Destination (Join-Path $DeployDir "db-backup\creatio.backup") -Force
  } else {
    Write-Host "No DB file found in /db folder."
  }
} else {
  Write-Host "creatio-app already exists, skipping copy."
}

Copy-Item -LiteralPath (Join-Path $RepoDir "db-backup\restore.sh") -Destination (Join-Path $DeployDir "db-backup\restore.sh") -Force
if (Test-Path $ExtractDir) {
  Remove-Item -LiteralPath $ExtractDir -Recurse -Force
}

$usedPorts = @(Get-UsedPorts)
$CreatioPort = Find-FreePort -StartPort 8080 -UsedPorts $usedPorts
$CreatioHttpsPort = Find-FreePort -StartPort ($CreatioPort + 363) -UsedPorts $usedPorts

if (-not (Test-Path $EnvFile)) {
  Copy-Item -LiteralPath (Join-Path $RepoDir ".env.example") -Destination $EnvFile -Force
  Set-EnvValue POSTGRES_DB "creatio_$Instance"
  Set-EnvValue CREATIO_PORT "$CreatioPort"
  Set-EnvValue CREATIO_HTTPS_PORT "$CreatioHttpsPort"
  Write-Host ""
  Write-Host $BoxTop
  Write-Host "$BoxV           $WarnIcon  SETUP REQUIRED                     $BoxV"
  Write-Host $BoxMid
  Write-Host "$BoxV  Instance : $Instance"
  Write-Host "$BoxV  .env     : $EnvFile"
  Write-Host $BoxBlank
  Write-Host "$BoxV  1. Edit .env jika perlu:                        $BoxV"
  Write-Host "$BoxV     notepad $EnvFile"
  Write-Host $BoxBlank
  Write-Host "$BoxV  2. Re-run deploy:                               $BoxV"
  Write-Host "$BoxV     .\deploy-local-windows.ps1 $Instance"
  Write-Host $BoxBottom
  Write-Host ""
  exit 0
}

Add-MissingEnvValues

$PostgresHost = Get-EnvValue POSTGRES_HOST
$PostgresDb = Get-EnvValue POSTGRES_DB
$PostgresUser = Get-EnvValue POSTGRES_USER
$PostgresPassword = Get-EnvValue POSTGRES_PASSWORD
$PostgresMaintenanceDb = Get-EnvValue POSTGRES_MAINTENANCE_DB
$RedisHost = Get-EnvValue REDIS_HOST
$RedisPassword = Get-EnvValue REDIS_PASSWORD
$CreatioPort = Get-EnvValue CREATIO_PORT
$CreatioHttpsPort = Get-EnvValue CREATIO_HTTPS_PORT
$PgAdminPort = Get-EnvValue PGADMIN_PORT
$PgAdminEmail = Get-EnvValue PGADMIN_EMAIL
$PgAdminPassword = Get-EnvValue PGADMIN_PASSWORD
$EnableFileSystem = Get-EnvValue ENABLE_FILE_SYSTEM
$CookiesSameSiteMode = Get-EnvValue COOKIES_SAME_SITE_MODE

Write-Host "Checking shared services..."
New-Item -ItemType Directory -Force -Path $SharedDir | Out-Null
$SharedCompose = Join-Path $SharedDir "docker-compose.yaml"
if (-not (Test-Path $SharedCompose)) {
  $SharedComposeContent = @(
    "services:",
    "  postgres:",
    "    image: postgres:16-alpine",
    "    container_name: creatio-postgres",
    "    restart: unless-stopped",
    "    command: postgres -c max_connections=500 -c shared_buffers=256MB",
    "    environment:",
    "      POSTGRES_USER: $PostgresUser",
    "      POSTGRES_PASSWORD: $PostgresPassword",
    "      POSTGRES_DB: postgres",
    "    ports:",
    '      - "5433:5432"',
    "    volumes:",
    "      - postgres-data:/var/lib/postgresql/data",
    "    networks:",
    "      - creatio-shared",
    "    healthcheck:",
    "      test: [`"CMD-SHELL`", `"pg_isready -U $PostgresUser`"]",
    "      interval: 10s",
    "      timeout: 5s",
    "      retries: 10",
    "",
    "  redis:",
    "    image: redis:7-alpine",
    "    container_name: creatio-redis",
    "    restart: unless-stopped",
    "    command: redis-server --bind 0.0.0.0 --requirepass $RedisPassword",
    "    ports:",
    '      - "6379:6379"',
    "    volumes:",
    "      - redis-data:/data",
    "    networks:",
    "      - creatio-shared",
    "",
    "  pgadmin:",
    "    image: dpage/pgadmin4:latest",
    "    container_name: creatio-pgadmin",
    "    restart: unless-stopped",
    "    environment:",
    "      PGADMIN_DEFAULT_EMAIL: $PgAdminEmail",
    "      PGADMIN_DEFAULT_PASSWORD: $PgAdminPassword",
    "    ports:",
    ('      - "{0}:80"' -f $PgAdminPort),
    "    networks:",
    "      - creatio-shared",
    "",
    "networks:",
    "  creatio-shared:",
    "    driver: bridge",
    "",
    "volumes:",
    "  postgres-data:",
    "  redis-data:"
  )
Set-Content -Path $SharedCompose -Value $SharedComposeContent -Encoding UTF8
}

$postgresRunning = docker ps --format "{{.Names}}" | Where-Object { $_ -eq "creatio-postgres" }
if (-not $postgresRunning) {
  docker compose -f $SharedCompose up -d
  Write-Host "Waiting for postgres to be ready..."
  Start-Sleep -Seconds 15
} else {
  Write-Host "Shared services already running."
}

$dbExists = docker exec creatio-postgres psql -U $PostgresUser -d $PostgresMaintenanceDb -tAc "SELECT 1 FROM pg_database WHERE datname='$PostgresDb'" 2>$null
if (($dbExists | Out-String).Trim() -ne "1") {
  Write-Host "Creating database $PostgresDb..."
  docker exec creatio-postgres psql -U $PostgresUser -d $PostgresMaintenanceDb -c "CREATE DATABASE $PostgresDb;"
  $BackupPath = Join-Path $DeployDir "db-backup\creatio.backup"
  Restore-Database -BackupPath $BackupPath -PostgresUser $PostgresUser -PostgresDb $PostgresDb
} else {
  Write-Host "Database $PostgresDb already exists."
}

$RedisDb = 0
Get-ChildItem -Path $BaseDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $DeployDir } | ForEach-Object {
  $otherEnv = Join-Path $_.FullName ".env"
  if (Test-Path $otherEnv) {
    $line = Get-Content $otherEnv -Encoding UTF8 | Where-Object { $_ -match "^REDIS_DB=" } | Select-Object -First 1
    if ($line) {
      $usedRedisDb = [int](($line -split "=", 2)[1])
      if ($usedRedisDb -eq $RedisDb) {
        $script:RedisDb++
      }
    }
  }
}
Set-EnvValue REDIS_DB "$RedisDb"
$RedisDb = Get-EnvValue REDIS_DB

Write-ConnectionStrings `
  -Path (Join-Path $DeployDir "creatio-app\ConnectionStrings.config") `
  -PostgresHost $PostgresHost `
  -PostgresDb $PostgresDb `
  -PostgresUser $PostgresUser `
  -PostgresPassword $PostgresPassword `
  -RedisHost $RedisHost `
  -RedisPassword $RedisPassword `
  -RedisDb $RedisDb

Update-WebHostConfig -Path (Join-Path $DeployDir "creatio-app\Terrasoft.WebHost.dll.config") -EnableFileSystem $EnableFileSystem -CookiesSameSiteMode $CookiesSameSiteMode

Copy-Item -LiteralPath (Join-Path $RepoDir "Dockerfile") -Destination (Join-Path $DeployDir "Dockerfile") -Force
$ComposePath = Join-Path $DeployDir "docker-compose.yaml"
$ComposeContent = @(
  "services:",
  "  creatio:",
  "    build:",
  "      context: .",
  "      dockerfile: Dockerfile",
  "      args:",
  '        NetCoreVersion: "8.0"',
  "    container_name: creatio-$Instance",
  "    restart: unless-stopped",
  "    ports:",
  ('      - "{0}:5000"' -f $CreatioPort),
  ('      - "{0}:5002"' -f $CreatioHttpsPort),
  "    volumes:",
  "      - ./creatio-app:/app",
  "      - creatio-$Instance-logs:/app/Logs",
  "    networks:",
  "      - creatio-shared",
  "    environment:",
  "      - ASPNETCORE_ENVIRONMENT=Development",
  "      - DOTNET_RUNNING_IN_CONTAINER=true",
  "      - TZ=Asia/Jakarta",
  "",
  "volumes:",
  "  creatio-$Instance-logs:",
  "",
  "networks:",
  "  creatio-shared:",
  "    external: true",
  "    name: shared_creatio-shared"
)
Set-Content -Path $ComposePath -Value $ComposeContent -Encoding UTF8

Write-Host "Starting Creatio instance: $Instance..."
Set-Location $DeployDir
cmd.exe /c "docker compose down >nul 2>nul"
docker compose up -d --build

$IdentityInfo = "Not running"

Write-Host ""
Write-Host $BoxTop
Write-Host "$BoxV           $DoneIcon DEPLOY COMPLETE                     $BoxV"
Write-Host $BoxMid
Write-Host "$BoxV  Instance : $Instance"
Write-Host "$BoxV  Creatio  : http://localhost:$CreatioPort"
Write-Host "$BoxV  pgAdmin  : http://localhost:$PgAdminPort"
Write-Host "$BoxV  Identity : $IdentityInfo"
Write-Host "$BoxV  DB       : $PostgresDb"
Write-Host "$BoxV  Redis DB : $RedisDb"
Write-Host $BoxBottom

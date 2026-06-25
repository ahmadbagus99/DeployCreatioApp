# DeployCreatioApp

Auto deploy Creatio dari Google Drive ke server.

## Struktur Repo

```
DeployCreatioApp/
├── Dockerfile
├── docker-compose.yaml
├── deploy.sh           
├── .env.example
├── .gitignore
└── db-backup/
    └── restore.sh      ← auto restore DB saat postgres init
```

## Cara Deploy ke Server Baru

```bash
# 1. Clone repo
git clone https://github.com/ahmadbagus99/DeployCreatioApp.git
cd DeployCreatioApp

# 2. Jalankan deploy script
chmod +x deploy.sh
./deploy.sh
```

Script otomatis akan:
1. Download zip Creatio dari Google Drive
2. Extract dan pisahkan creatio-app & DB
3. Setup folder `/opt/creatio`
4. Buat `.env` dari template (edit jika perlu)
5. `docker compose up -d --build`
6. Postgres auto restore DB saat pertama init

## Re-deploy (update versi baru)

Upload zip baru ke Google Drive dengan File ID yang sama, lalu:

```bash
./deploy.sh
```

> ⚠️ Script akan `docker compose down -v` dulu — semua data di volume akan terhapus dan DB di-restore ulang dari backup.

## Manual Edit .env

```bash
nano /opt/creatio/.env
```

---

# Production Setup (Lengkap)

Dokumentasi semua yang disiapkan/diinstall di server produksi — dari deployment, CI/CD, enhance performa load page, sampai integrasi RabbitMQ.

> ⚠️ Semua password/secret di bawah pakai **placeholder** (`<...>`). Nilai asli simpan di secret store / password manager, JANGAN commit ke repo.

## Arsitektur Singkat

```
                    nginx + Let's Encrypt (HTTP/2, gzip, brotli, cache)
                                   │  https://<instance>.<domain>
                                   ▼
  ┌──────────────── VPS (Ubuntu, Docker) ────────────────┐
  │  creatio-<instance> :8080   ← app (production mode)   │
  │  identity-<instance> :9080  ← OAuth 2.0               │
  │  creatio-postgres :5432     ← shared                  │
  │  creatio-redis              ← shared                  │
  │  creatio-pgadmin :5050      ← shared (opsional)       │
  │  jenkins :5001              ← CI/CD                   │
  │  clio:local (image)         ← deploy tool             │
  └───────────────────────────────────────────────────────┘
                                   │ AMQP :8989
                                   ▼
            RabbitMQ broker (server terpisah, dikelola tim lain)
```

## 1. Base Server

```bash
# Docker + Compose
curl -fsSL https://get.docker.com | sh

# Firewall
ufw allow OpenSSH
ufw allow 80 && ufw allow 443
ufw enable

# Tools bantu
apt install -y expect rsync
```

## 2. Shared Infrastructure (sekali, dipakai semua instance)

Container bersama: **PostgreSQL** (`creatio-postgres`, :5432), **Redis** (`creatio-redis`), **pgAdmin** (`creatio-pgadmin`, :5050). Dibuat lewat docker-compose (lihat `docker-compose.yaml`).

## 3. Per-Instance Creatio

```bash
./deploy-server.sh <instance>      # contoh: ./deploy-server.sh jamkrida
```

Otomatis: assign port, buat DB `creatio_<instance>`, redis db-index, deploy app + Identity Service (kalau `ENABLE_OAUTH=true`).

**Catatan deploy-server.sh** (bug yang sudah di-handle):
- `appsettings.json` punya UTF-8 BOM → baca dengan `utf-8-sig`
- cert generator bundled CRLF → generate inline `openssl`
- Identity Service baca key `DatabaseConnectionString` (bukan `PostgresConnection`) → tulis keduanya

Instance `jamkrida` (referensi): Creatio :8080, Identity :9080, pgAdmin :5050, DB `creatio_jamkrida`, redis db 0. Login `Supervisor / <password>`.

## 4. Akses Database (DBeaver)

Pakai **SSH tunnel** (jangan expose port Postgres langsung):
- SSH tab: `<VPS_IP>:22`, user `root`
- Main tab: `localhost:5432`, db `creatio_<instance>`, user `creatio_user`, pass `<db-pass>`

## 5. ⭐ Enhance Performa Load Page

### a. Production Mode
File `Terrasoft.WebHost.dll.config` (backup dulu: `cp ...dll.config{,.bak}`):

```xml
<fileDesignMode enabled="false" />
<add key="UseStaticFileContent" value="true" />
```

→ serve bundled/hashed client resources (bukan unbundled yang lambat). Restart container setelah ubah.

> Konsekuensi: CI **wajib pakai clio** (file-system mode `LoadPackagesToDB` tidak jalan di production mode). clio `push-workspace` otomatis generate static content tiap deploy → UI tetap cepat.

### b. nginx + Let's Encrypt
Reverse proxy `https://<instance>.<domain>` → `127.0.0.1:8080`, dengan:
- **HTTP/2**
- **gzip + brotli** (kompresi)
- **immutable cache** untuk `/core/<hash>/` (bundle hashed → cache aman, hash berubah otomatis bust)
- timeout besar untuk compile:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_connect_timeout 600s;
    proxy_send_timeout    600s;
    proxy_read_timeout    600s;  # rebuild/compile bisa > 60s → hindari 504
}
```

```bash
certbot --nginx -d <instance>.<domain>
nginx -t && systemctl reload nginx
```

## 6. CI/CD — clio (mode produksi)

### clio sebagai Docker image
```bash
# /opt/clio/Dockerfile.clio
# FROM mcr.microsoft.com/dotnet/sdk:8.0
# RUN dotnet tool install clio -g
docker build -t clio:local -f /opt/clio/Dockerfile.clio /opt/clio
```

### Workspace + deploy script
- `/opt/clio/ws-<instance>/` — `.clio/workspaceSettings.json` + `packages/`
- `/opt/clio/deploy-<instance>.sh` — generate workspaceSettings + jalankan:

```bash
docker run --rm --network host -v /opt/clio/ws-<instance>:/work clio:local \
  "clio reg-web-app <instance> -u http://localhost:8080 -l Supervisor -p '<password>' -i true -m true && \
   clio push-workspace -e <instance> --skip-backup true"
```

`push-workspace` = install → compile → generate static content → restart (idempotent, ~5 menit).

### Jenkins
- Container `jenkins`, UI :5001
- Pipeline: **Pull** (repo branch `vNET`, credential PAT `github-jamkrida`) → **rsync** packages ke VPS → **Deploy** (`ssh <SERVER> "bash /opt/clio/deploy-<instance>.sh"`) → **Warm-up** (poll domain 302/200 lalu login → trigger OnAppStart)
- Credentials: `github-jamkrida` (GitHub PAT), `creatio-server` (SSH key)
- `options { disableConcurrentBuilds() }` — cegah restart saat compile jalan

> ⚠️ `rsync` + `python3` saat ini diinstall ke container Jenkins yang **ephemeral** (hilang kalau container di-recreate). Fix permanen: bikin custom Dockerfile `FROM jenkins/jenkins:lts`.

## 7. Integrasi RabbitMQ (Outbound + Inbound)

Broker **eksternal & shared**: `<broker-ip>:8989` vhost `creatio` (UI :8080). Di sisi Creatio cukup set `ConnectionStrings.config`:

```xml
<!-- koneksi utama -->
<add name="messageBroker"
     connectionString="amqp://<user>:<pass>@<broker-ip>:8989/creatio" />

<!-- outbound per-target (exchange kosong = default exchange, routingKey = nama queue) -->
<add name="integration.mitraportal.mq"
     connectionString="host=<broker-ip>;port=8989;vhost=creatio;username=<user>;password=<pass>;exchange=;routingKey=q.creatio.to-mitra" />
<add name="integration.fms.mq"
     connectionString="host=<broker-ip>;port=8989;vhost=creatio;username=<user>;password=<pass>;exchange=;routingKey=q.creatio.to-fms" />
```

> Setelah edit `ConnectionStrings.config` → **restart container** (dibaca saat app start).

**Topologi:**
- **Inbound** (External → Creatio, 1-hop): publish ke `integration.in` → `InboundConsumer` → dispatch by handler (Source + EntityName + Operation) → create data
- **Outbound** (Creatio → External, 2-hop): `integration.out` (staging) → `OutboundConsumer` sortir by target → queue per-target:
  - `q.creatio.to-mitra` (MitraPortal)
  - `q.creatio.to-fms` (FMS)
- Tiap queue per-target: TTL 24h + dead-letter ke `dlx.jamkrida` → `dlq.jamkrida`

**User RabbitMQ** (least-privilege, read-only ke queue masing-masing) — buat di broker:
```bash
rabbitmqctl add_user mitraportal_user '<pass>'
rabbitmqctl set_permissions -p creatio mitraportal_user "^$" "^$" "^q\.creatio\.to-mitra$"
rabbitmqctl add_user fms_user '<pass>'
rabbitmqctl set_permissions -p creatio fms_user "^$" "^$" "^q\.creatio\.to-fms$"
```

**Consumer eksternal (MitraPortal/FMS, PHP)** — `php-amqplib`:
- connect `<broker-ip>:8989` vhost `creatio`, consume queue masing-masing
- `queue_declare` pakai **passive** (queue sudah ada dengan args khusus) atau skip declare
- **manual ack**; gagal → `basic_nack(requeue=false)` → masuk DLQ (hindari requeue loop)
- jalankan sebagai **daemon** (systemd/supervisord) + heartbeat + reconnect loop

> ⚠️ **TODO penting**: Business Process timer `CoreRabbitMQKeepAlive` (tiap 1–2 menit, panggil `RabbitMQSupervisor.EnsureRunning`) — karena `OnAppStart` intermiten tidak ke-invoke, consumer butuh pemicu dari Creatio scheduler agar auto-start tiap restart.

## Checklist Install Server

```
[ ] Docker + Docker Compose
[ ] UFW firewall
[ ] Postgres + Redis + pgAdmin (shared containers)
[ ] Creatio app + Identity Service (per instance, via deploy-server.sh)
[ ] nginx + certbot (Let's Encrypt)
[ ] Production-mode config (fileDesignMode=false, UseStaticFileContent=true)
[ ] nginx tuning (HTTP/2, gzip, brotli, immutable cache, timeout 600s)
[ ] clio Docker image (clio:local) + workspace + deploy script
[ ] Jenkins container (+ rsync/python3 — idealnya custom image)
[ ] ConnectionStrings.config (messageBroker + integration.*.mq)
[ ] RabbitMQ users (mitraportal_user, fms_user) di broker
[ ] BP timer CoreRabbitMQKeepAlive (TODO)
```

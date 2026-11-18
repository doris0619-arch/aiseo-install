#!/usr/bin/env bash
# AISEO 一行安裝（正式版主機用）。放在公開倉庫 aiseo-install；原始在開發版 tools/release/install.sh。
#
#   curl -fsSL https://raw.githubusercontent.com/doris0619-arch/aiseo-install/main/install.sh | sudo bash -s -- <安裝碼> [--domain aiseo.example.com] [--email 管理者信箱] [--web-port 3111]
#
# 支援：Ubuntu 22.04／24.04、Debian 12（root 權限；主機已有 MySQL 就沿用，不另裝 MariaDB）。可以重跑：已有的設定、主金鑰、資料庫密碼不會被換掉。
# 安裝位置：/opt/aiseo（程式在 releases/<版本>，current 指向使用中的版本；資料在 data/）。
# 本程式不含任何金鑰；安裝碼是唯讀下載權限，只存在這台主機 /etc/aiseo/release.key（600）。
set -Eeuo pipefail

BASE=/opt/aiseo
DATA=$BASE/data
RUNTIME=$DATA/runtime
SECRETS=$RUNTIME/secrets
NODE_DIR=$BASE/node
KEY_FILE=/etc/aiseo/release.key
API_PORT=3100
WEB_PORT=""   # 網頁埠：沒指定就用 3101，被占用時自動往後找空的；裝過的沿用 app.env

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "第 $LINENO 行出錯，安裝中止。修好後可以直接重跑同一行指令。"' ERR

# ── 參數 ──
CODE="" DOMAIN="" EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --web-port) WEB_PORT=${2:-}; shift 2 ;;
    AISEO1.*) CODE=$1; shift ;;
    *) die "看不懂的參數：$1" ;;
  esac
done
[ "$(id -u)" = 0 ] || die "要用 root 執行（指令前面加 sudo）"
[ -n "$CODE" ] || [ -f "$KEY_FILE" ] || die "缺少安裝碼（AISEO1. 開頭那一長串）"
DOMAIN=${DOMAIN#https://}; DOMAIN=${DOMAIN#http://}; DOMAIN=${DOMAIN%%/*}
# 重跑沒帶 --domain：沿用上次的網域（不然網址會被改回 http://IP）
if [ -z "$DOMAIN" ] && [ -f "$SECRETS/app.env" ]; then
  DOMAIN=$(sed -n 's#^AISEO_PUBLIC_URL=https://\([^/]*\).*#\1#p' "$SECRETS/app.env" | head -1)
fi

# ── 0. 檢查主機 ──
say "檢查主機"
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:22.04 | ubuntu:24.04 | debian:12) ok "$PRETTY_NAME" ;;
  *) die "不支援的系統：$PRETTY_NAME（只支援 Ubuntu 22.04／24.04、Debian 12）" ;;
esac
case "$(uname -m)" in x86_64) ARCH=x64 ;; aarch64) ARCH=arm64 ;; *) die "不支援的 CPU：$(uname -m)" ;; esac
MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$MEM" -ge 3500 ] || printf '  ! 記憶體只有 %s MB，建議至少 4GB\n' "$MEM"
[ ! -d /www/server/panel ] || printf '  ! 偵測到寶塔面板：本程式會自己裝 Nginx／MariaDB／Redis，可能和寶塔裝的衝突，建議用乾淨主機\n'
in_use() { ss -ltn "sport = :$1" | grep -q LISTEN; }
if [ -f "$SECRETS/app.env" ]; then
  OLD_WEB=$(sed -n 's/^AISEO_WEB_PORT=\([0-9]*\).*/\1/p' "$SECRETS/app.env")
  [ -n "$WEB_PORT" ] || WEB_PORT=${OLD_WEB:-3101}
  [ "$WEB_PORT" = "${OLD_WEB:-3101}" ] || ! in_use "$WEB_PORT" || die "連接埠 $WEB_PORT 已被其他程式使用，換一個 --web-port"
else
  in_use $API_PORT && die "連接埠 $API_PORT 已被其他程式使用（AISEO 後端固定用這個埠）"
  if [ -n "$WEB_PORT" ]; then in_use "$WEB_PORT" && die "連接埠 $WEB_PORT 已被其他程式使用，換一個 --web-port"
  else
    WEB_PORT=3101
    while in_use $WEB_PORT; do WEB_PORT=$((WEB_PORT + 1)); [ $WEB_PORT -le 3199 ] || die "3101～3199 都被占用，請用 --web-port 指定"; done
  fi
fi
case "$WEB_PORT" in '' | *[!0-9]*) die "--web-port 要是數字" ;; esac
[ "$WEB_PORT" != "$API_PORT" ] || die "網頁埠不能和後端同一個（$API_PORT）"
ok "網頁埠 $WEB_PORT"

# ── 1. 系統套件 ──
say "安裝系統套件（Nginx、MariaDB、Redis、憑證工具）"
export DEBIAN_FRONTEND=noninteractive
# 主機已經有 MySQL／MariaDB 就沿用（兩者套件互斥，硬裝 MariaDB 會把原本的 MySQL 移除）
if dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q 'ok installed'; then DB_PKGS="" DB_SVC=mysql
else DB_PKGS="mariadb-server mariadb-client" DB_SVC=mariadb; fi
apt-get update -qq
apt-get install -y -qq curl ca-certificates git openssh-client xz-utils zip unzip openssl \
  nginx $DB_PKGS redis-server certbot python3-certbot-nginx >/dev/null
systemctl enable --now $DB_SVC redis-server nginx >/dev/null 2>&1
ok "系統套件（資料庫：$([ -z "$DB_PKGS" ] && echo "沿用原本的 MySQL" || echo MariaDB)）"

# ── 2. Node 22（裝在 /opt/aiseo/node，不動系統原本的 Node） ──
say "安裝 Node 22"
if ! "$NODE_DIR/bin/node" -v 2>/dev/null | grep -q '^v22\.'; then
  TMP=$(mktemp -d)
  curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt -o "$TMP/SUMS"
  TARBALL=$(grep -oE "node-v22\.[0-9.]+-linux-$ARCH\.tar\.xz" "$TMP/SUMS" | head -1)
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/$TARBALL" -o "$TMP/$TARBALL"
  (cd "$TMP" && grep " $TARBALL\$" SUMS | sha256sum -c --quiet) || die "Node 下載檔驗證失敗"
  rm -rf "$NODE_DIR" && mkdir -p "$NODE_DIR"
  tar -xJf "$TMP/$TARBALL" -C "$NODE_DIR" --strip-components=1
  rm -rf "$TMP"
fi
export PATH="$NODE_DIR/bin:$PATH" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
corepack enable >/dev/null
[ -x "$NODE_DIR/bin/pm2" ] || npm install -g --silent pm2@6 >/dev/null
ok "Node $(node -v)、PM2 $(pm2 -v 2>/dev/null | tail -1)"

# ── 3. 下載程式（用安裝碼：唯讀，只能讀 aiseo-release） ──
say "下載 AISEO"
mkdir -p /etc/aiseo && chmod 700 /etc/aiseo
if [ -n "$CODE" ]; then
  node -e '
    const j = JSON.parse(Buffer.from(process.argv[1].slice(7), "base64url").toString());
    if (!j.r || !j.k) throw new Error("bad");
    require("fs").writeFileSync("/etc/aiseo/release.key", j.k.trim() + "\n", { mode: 0o600 });
    require("fs").writeFileSync("/etc/aiseo/release.repo", j.r + "\n", { mode: 0o600 });
  ' "$CODE" 2>/dev/null || die "安裝碼格式不對（要完整複製 AISEO1. 開頭的整串）"
fi
REPO=$(cat /etc/aiseo/release.repo)
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/etc/aiseo/known_hosts"
rm -rf "$BASE/download"
git clone -q --depth 1 "git@github.com:$REPO.git" "$BASE/download" 2>/dev/null || die "下載失敗：安裝碼無效、已被撤銷，或這台主機連不到 GitHub"
read -r VERSION PKG SHA < <(node -e 'const m=require(process.argv[1]); console.log(m.version, m.path, m.sha256)' "$BASE/download/latest.json")
echo "$SHA  $BASE/download/$PKG" | sha256sum -c --quiet || die "安裝檔驗證失敗（sha256 不符）"
REL=$BASE/releases/$VERSION
if [ ! -f "$REL/.installed" ]; then
  rm -rf "$REL" && mkdir -p "$REL"
  tar -xzf "$BASE/download/$PKG" -C "$REL" --strip-components=1
fi
rm -rf "$BASE/download"
ok "版本 $VERSION"

# 執行資料放 data/，每個版本用捷徑共用（換版本不會動到資料）
mkdir -p "$SECRETS" "$RUNTIME/logs" "$DATA/pm2" && chmod 700 "$SECRETS"
[ -L "$REL/runtime" ] || { rm -rf "$REL/runtime"; ln -s "$RUNTIME" "$REL/runtime"; }
# Next 建置時寫進去的路徑換成這台的
for f in "$REL/apps/web/.next/required-server-files.json" "$REL/apps/web/.next/required-server-files.js"; do
  if [ -f "$f" ]; then sed -i "s#__AISEO_ROOT__#$REL#g" "$f"; fi
done

# ── 4. 設定檔（只在第一次產生；之後重跑沿用） ──
say "產生設定"
if [ -n "$DOMAIN" ]; then PUBLIC_URL="https://$DOMAIN"; SECURE=1; else
  IP=$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  PUBLIC_URL="http://$IP"; SECURE=0
fi
if [ ! -f "$SECRETS/app.env" ]; then
  DBPASS=$(openssl rand -hex 24)
  cat >"$SECRETS/app.env" <<EOF
# AISEO 執行設定（安裝程式產生，權限 600）。不要複製到其他地方、不要貼到對話裡。
AISEO_DB_URL=mysql://aiseo:$DBPASS@127.0.0.1:3306/aiseo
AISEO_REDIS_URL=redis://127.0.0.1:6379/0
AISEO_REDIS_PREFIX=aiseo:
AISEO_API_PORT=$API_PORT
AISEO_WEB_PORT=$WEB_PORT
# 主金鑰：遺失＝資料庫裡的 API 金鑰全部解不開。請另外抄一份存到安全的地方。
AISEO_MASTER_KEY=$(openssl rand -base64 32)
AISEO_COOKIE_SECURE=$SECURE
AISEO_PUBLIC_URL=$PUBLIC_URL
EOF
  chmod 600 "$SECRETS/app.env"
  ok "已產生新設定與主金鑰"
else
  sed -i "s#^AISEO_PUBLIC_URL=.*#AISEO_PUBLIC_URL=$PUBLIC_URL#; s#^AISEO_COOKIE_SECURE=.*#AISEO_COOKIE_SECURE=$SECURE#" "$SECRETS/app.env"
  if grep -q '^AISEO_WEB_PORT=' "$SECRETS/app.env"; then sed -i "s#^AISEO_WEB_PORT=.*#AISEO_WEB_PORT=$WEB_PORT#" "$SECRETS/app.env"
  else echo "AISEO_WEB_PORT=$WEB_PORT" >>"$SECRETS/app.env"; fi
  ok "沿用原本的設定（主金鑰、資料庫密碼不變）"
fi
DBPASS=$(sed -n 's#^AISEO_DB_URL=mysql://aiseo:\([^@]*\)@.*#\1#p' "$SECRETS/app.env")

# ── 5. 資料庫 ──
say "建立資料庫"
mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS aiseo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'aiseo'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
ALTER USER 'aiseo'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON aiseo.* TO 'aiseo'@'127.0.0.1';
GRANT ALL PRIVILEGES ON aiseo_drill.* TO 'aiseo'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
ok "資料庫 aiseo"

# ── 6. 安裝套件、建資料表、建管理者 ──
say "安裝程式套件（約 2～5 分鐘）"
cd "$REL"
corepack pnpm install --frozen-lockfile --reporter=silent
corepack pnpm --filter @aiseo/db exec prisma migrate deploy >/dev/null
corepack pnpm --filter @aiseo/db run seed
bash scripts/build-wp-plugin.sh >/dev/null 2>&1 || printf '  ! WP 外掛打包略過（沒有 https 網址時不開自動更新，之後可重跑）\n'
bash scripts/build-standard-kit.sh >/dev/null 2>&1 || true
touch "$REL/.installed"
ln -sfn "$REL" "$BASE/current"
ok "套件、資料表、管理者"

# ── 7. 開機自動啟動、備份、監控 ──
say "設定開機自動啟動"
ENVLINES="Environment=PM2_HOME=$DATA/pm2
Environment=PATH=$NODE_DIR/bin:/usr/local/bin:/usr/bin:/bin"
cat >/etc/systemd/system/aiseo-pm2.service <<EOF
[Unit]
Description=AISEO (aiseo-api, aiseo-worker, aiseo-web)
After=network-online.target $DB_SVC.service redis-server.service
Wants=network-online.target $DB_SVC.service redis-server.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
$ENVLINES
ExecStart=$NODE_DIR/bin/pm2 startOrRestart $BASE/current/ecosystem.config.cjs
ExecStop=$NODE_DIR/bin/pm2 kill
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
unit() { # 名稱 說明 指令 排程
  cat >"/etc/systemd/system/aiseo-$1.service" <<EOF
[Unit]
Description=$2
After=$DB_SVC.service

[Service]
Type=oneshot
$ENVLINES
ExecStart=$NODE_DIR/bin/node $BASE/current/$3
EOF
  cat >"/etc/systemd/system/aiseo-$1.timer" <<EOF
[Unit]
Description=$2 timer

[Timer]
OnCalendar=$4
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
}
unit backup "AISEO daily database backup" "tools/backup-db.mjs --keep 14" "*-*-* 03:40:00"
unit monitor "AISEO system monitor" "tools/monitor.mjs" "*:0/5"
unit drill "AISEO weekly restore drill" "tools/restore-drill.mjs" "Sun *-*-* 04:30:00"
# 一鍵更新：設定頁按「更新」→ API 啟動這個服務（跟 PM2 分開跑，重開 AISEO 時不會把自己砍掉）
mkdir -p "$BASE/bin"
install -m 700 "$REL/scripts/aiseo-update.sh" "$BASE/bin/aiseo-update"
cat >/etc/systemd/system/aiseo-update.service <<EOF
[Unit]
Description=AISEO one-click update
After=network-online.target $DB_SVC.service

[Service]
Type=oneshot
$ENVLINES
ExecStart=$BASE/bin/aiseo-update
TimeoutStartSec=1800
EOF
systemctl daemon-reload
systemctl enable aiseo-pm2.service aiseo-backup.timer aiseo-monitor.timer aiseo-drill.timer >/dev/null 2>&1
systemctl restart aiseo-pm2.service
systemctl start aiseo-backup.timer aiseo-monitor.timer aiseo-drill.timer
ok "aiseo-api、aiseo-worker、aiseo-web 已啟動"

# ── 8. Nginx＋HTTPS ──
say "設定網址"
NAME=${DOMAIN:-_}
cat >/etc/nginx/sites-available/aiseo.conf <<EOF
server {
    listen 80;
    server_name $NAME;
    client_max_body_size 50m;
    location / {
        proxy_pass http://127.0.0.1:$WEB_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade_aiseo;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }
}
EOF
cat >/etc/nginx/conf.d/aiseo-map.conf <<'EOF'
map $http_upgrade $connection_upgrade_aiseo { default upgrade; '' ''; }
EOF
ln -sf /etc/nginx/sites-available/aiseo.conf /etc/nginx/sites-enabled/aiseo.conf
if [ -z "$DOMAIN" ]; then rm -f /etc/nginx/sites-enabled/default; fi
nginx -t -q && systemctl reload nginx
if [ -n "$DOMAIN" ]; then
  if certbot --nginx -n --agree-tos --redirect -d "$DOMAIN" ${EMAIL:+-m "$EMAIL"} ${EMAIL:---register-unsafely-without-email} >/dev/null 2>&1; then
    ok "HTTPS：$PUBLIC_URL"
  else
    printf '  ! HTTPS 憑證申請失敗：請確認 %s 已指向這台主機的 IP、80／443 埠有開，再重跑一次\n' "$DOMAIN"
  fi
fi

# ── 9. 檢查 ──
say "檢查"
for i in $(seq 1 30); do curl -fsS "http://127.0.0.1:$API_PORT/api/health" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "http://127.0.0.1:$API_PORT/api/health" >/dev/null && ok "API 正常" || printf '  ! API 還沒回應，看 %s/logs/api.err.log\n' "$RUNTIME"
curl -fsS -o /dev/null "http://127.0.0.1:$WEB_PORT/login" && ok "網頁正常" || printf '  ! 網頁還沒回應，看 %s/logs/web.err.log\n' "$RUNTIME"

cat <<EOF

────────────────────────────────────────
 AISEO $VERSION 安裝完成
 網址：$PUBLIC_URL
 第一次登入的帳號密碼：cat $SECRETS/initial-admin.txt
   （登入後請馬上改密碼，然後刪掉這個檔）
 主金鑰在 $SECRETS/app.env 的 AISEO_MASTER_KEY，
   請另外抄一份存到安全的地方（遺失＝存在 AISEO 裡的 API 金鑰全部要重填）
────────────────────────────────────────
EOF

#!/usr/bin/env bash
# Installs (or updates) the Vodia User Portal Guide on a fresh Ubuntu or Amazon Linux server,
# served by nginx on port 80. Run the same command again any time to pull the latest version.
#
#   sudo bash install.sh <git-repo-url> [domain] [email]
#
#   <git-repo-url>  e.g. https://github.com/you/vodia-user-guide.git
#   [domain]        optional, e.g. guide.example.com (its DNS must already point at this server)
#   [email]         optional, for the free HTTPS certificate (needs the domain too)
set -euo pipefail

REPO="${1:?Usage: sudo bash install.sh <git-repo-url> [domain] [email]}"
DOMAIN="${2:-}"
EMAIL="${3:-}"
DIR=/var/www/vodia-guide
BRANCH="${BRANCH:-main}"

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
say(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Installing nginx and git"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq || echo "(some package sources could not be refreshed; continuing)"
  apt-get install -y -qq nginx git
  CONF=/etc/nginx/sites-available/vodia-guide
  ENABLED=/etc/nginx/sites-enabled/vodia-guide
elif command -v dnf >/dev/null; then
  dnf install -y -q nginx git
  CONF=/etc/nginx/conf.d/vodia-guide.conf
  ENABLED=""
else
  echo "Unsupported system: needs apt-get (Ubuntu/Debian) or dnf (Amazon Linux)."; exit 1
fi

say "Getting the guide from $REPO"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch --depth 1 origin "$BRANCH"
  git -C "$DIR" reset --hard "origin/$BRANCH"
else
  rm -rf "$DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$DIR"
fi
chmod -R a+rX "$DIR"
# The guide can sit at the top of the repository or inside a folder (e.g. vodia-user-guide-site/)
SITE="$DIR"
if [ ! -f "$SITE/public/index.html" ]; then
  # look for the guide's own content file, so other projects in the same repo are never picked
  FOUND=$(find "$DIR" -maxdepth 5 -path "$DIR/.git" -prune -o -path '*/public/data/guide.json' -print | sort | head -n 1)
  [ -n "$FOUND" ] && SITE=$(dirname "$(dirname "$(dirname "$FOUND")")")
fi
[ -f "$SITE/public/index.html" ] || { echo "No public/index.html found in the repository. Is this the right repo?"; exit 1; }
echo "Serving: $SITE/public"

say "Configuring nginx on port 80"
LISTEN6=""
[ -f /proc/net/if_inet6 ] && LISTEN6="listen [::]:80 default_server;"
cat > "$CONF" <<NGINX
server {
    listen 80 default_server;
    $LISTEN6
    server_name ${DOMAIN:-_};

    root $SITE/public;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-cache";
        add_header X-Content-Type-Options nosniff;
    }
    location /images/ { expires 1d; }
    location /tools/  { return 404; }     # authoring helper, not for students
    location ~ /\.    { deny all; }       # hide .git and other dot files
}
NGINX
if [ -n "$ENABLED" ]; then
  ln -sf "$CONF" "$ENABLED"
  rm -f /etc/nginx/sites-enabled/default
else
  # Amazon Linux ships its own port-80 default server inside nginx.conf; switch it off
  sed -i 's/^\(\s*listen\s\+80\)\s*default_server;/\1;/; s/^\(\s*listen\s\+\[::\]:80\)\s*default_server;/\1;/' /etc/nginx/nginx.conf
fi
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl restart nginx 2>/dev/null || service nginx restart

if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
  say "Getting a free HTTPS certificate for $DOMAIN"
  if command -v apt-get >/dev/null; then apt-get install -y -qq certbot python3-certbot-nginx
  else dnf install -y -q certbot python3-certbot-nginx || { python3 -m pip install -q certbot certbot-nginx; }
  fi
  certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos -n --redirect || echo "Certificate step failed: check that $DOMAIN points to this server and port 443 is open, then re-run."
fi

IP=$(curl -s --max-time 3 http://checkip.amazonaws.com 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+){3}$' || true)
[ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$IP" ] || IP="YOUR-SERVER-IP"
say "Done"
echo "Guide version: $(git -C "$DIR" log -1 --format='%h %s (%cr)')"
if [ -n "$DOMAIN" ]; then echo "Open: http${EMAIL:+s}://$DOMAIN"; else echo "Open: http://$IP"; fi
echo "To update later, run the same command again."

# Deploy To Laravel Forge On AWS

This app is a Node.js service, not a Laravel/PHP app. Use Forge to manage the AWS server, Nginx, SSL, and a daemon that keeps `server.js` running.

## 1. Server Requirements

- Node.js 18 LTS or newer
- Nginx
- A persistent data directory outside the site checkout
- Enough memory for headless Chromium/WhatsApp Web

On Ubuntu, Puppeteer may need system Chromium dependencies. If WhatsApp startup fails with browser launch errors, install Chrome or Chromium dependencies on the server, then set `CHROME_EXECUTABLE_PATH` if needed.

## 2. Forge Site

Create a normal Forge site for your domain, for example:

```text
patrol.example.com
```

Connect the site to this GitHub repo.

## 3. Environment

Create a persistent data directory on the server:

```bash
mkdir -p /home/forge/.whatsapp-scheduler-bot
```

In the Forge site root, create `.env`:

```bash
HOST=127.0.0.1
PORT=3000
DATA_DIR=/home/forge/.whatsapp-scheduler-bot
```

Runtime files stored there:

- `config.json`
- `send-history.json`
- `.wwebjs_auth/`

Do not delete `.wwebjs_auth/` unless you want to force a fresh WhatsApp QR login.

## 4. Deploy Script

Use this Forge deploy script:

```bash
cd /home/forge/YOUR-DOMAIN.com
git pull origin $FORGE_SITE_BRANCH
npm ci --omit=dev
mkdir -p /home/forge/.whatsapp-scheduler-bot
```

Replace `YOUR-DOMAIN.com` with the actual Forge site path.

## 5. Daemon

Create a Forge daemon:

```text
Command: npm start
Directory: /home/forge/YOUR-DOMAIN.com
User: forge
Processes: 1
```

After each deploy, restart the daemon from Forge.

## 6. Nginx

Edit the Forge site's Nginx config and proxy traffic to Node:

```nginx
location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Enable SSL in Forge after DNS points to the AWS instance.

## 7. First Login

Open the domain, scan the QR code with:

```text
WhatsApp > Settings > Linked Devices > Link a Device
```

Keep the daemon running. Scheduled messages only send while the AWS instance and daemon are online.

# 🛡️ WatchPoint — Guard Patrol & WhatsApp Automation Platform

WatchPoint is an end-to-end security guard patrol and automated WhatsApp dispatch system. It combines a high-performance **Node.js Automation Engine**, a native **iOS Guard Application (SwiftUI)**, and a **Master Admin Web Dashboard** for real-time supervisory control.

---

## 🏗️ System Architecture

```text
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│        📱 WatchPoint iOS App         │       │     🌐 Master Admin Web Console      │
│   (Guard Sign In, Live GPS Patrol,   │       │   (1-Click PIN Reset, Schedules,     │
│    Checkpoints, Face ID App Lock)    │       │    Checkpoints, Live QR Pairing)     │
└──────────────────┬───────────────────┘       └──────────────────┬───────────────────┘
                   │ HTTPS REST API                               │ HTTPS REST API
                   ▼                                              ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                       🚀 WatchPoint Node.js Backend Engine                          │
│                                                                                     │
│  • Persistent Session Store (90-Day Sliding Auth Window in sessions.json)           │
│  • Geofencing Engine (GPS Distance, Ingress Detection, Anti-Spam Interval Spacing)  │
│  • Multi-Account Runtime Engine (Isolated Chromium Sessions per Guard)              │
│  • WhatsApp Web Client Automation (Remote Web Version Cache & Desktop User-Agent)   │
└──────────────────────────────────────────┬──────────────────────────────────────────┘
                                           │ WebSocket / CDP Handshake
                                           ▼
                                💬 WhatsApp Multi-Device
                             (Destination Group / Channels)
```

---

## ⚡ Key Capabilities

1. **Native iOS App (`WatchPoint`)**:
   - **Phone & Security PIN Login**: Fast authentication designed for guard shifts.
   - **Live GPS Checkpoint Geofencing**: Background GPS tracking verifies physical arrival at checkpoints (Lat/Lng radius).
   - **Zero Footer Clutter**: Internal metadata (`Checkpoint:`, `Guard:`) is stripped so only clean patrol messages reach client WhatsApp groups.
   - **Biometric Security**: Built-in Face ID / Touch ID App Lock.

2. **Master Admin Web Console (`/admin`)**:
   - **Direct Browser Management**: Accessible via web link on any phone, tablet, or desktop.
   - **1-Click PIN Reset**: Instantly reset forgotten guard PINs without manual file editing.
   - **Live WhatsApp Session Hub**: Embedded live pairing QR codes, instant reconnect, and device unlinking.
   - **Shift Timetable Builder**: Configure automated shift reporting hours, randomized intervals, and active days.
   - **Interactive Checkpoints Manager**: Add/edit/remove checkpoints with custom geofence radii.
   - **Real-Time Activity Stream**: Filterable log feed for arrivals, dispatches, cooldown skips, and errors.

3. **Robust Backend Engine (`server.js`)**:
   - **Persistent Sessions**: Disk-backed auth in `sessions.json` prevents accidental guard logouts during server restarts.
   - **Multi-Device Compatibility**: Remote `webVersionCache` prevents "Invalid QR Code / Unable to link device" errors.
   - **Duplicate Guard Prevention**: Enforces unique phone numbers (HTTP 409 Conflict).

---

## 🚀 Server Installation & Quick Start

### 1. Prerequisites
- **Node.js**: v20.x or v22.x LTS (`node -v`)
- **Git**: Installed and configured
- **Chromium / Chrome**: Required by Puppeteer on Linux

On Ubuntu / Debian systems:
```bash
sudo apt update
sudo apt install -y nodejs npm git chromium-browser libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libgbm1 libasound2
```

### 2. Clone & Install Dependencies
```bash
git clone https://github.com/web-dev-nav/whatsapp-scheduler-bot.git
cd whatsapp-scheduler-bot
npm install
```

### 3. Environment Configuration (`.env`)
Create or edit your `.env` file in the project root:

```ini
# Server Binding
HOST=0.0.0.0
PORT=3000

# Master Admin & Patrol Security Secret
PATROL_TOKEN=your-master-secret-token-here

# Data Storage Directory (holds accounts.json, sessions.json, checkpoints)
DATA_DIR=/home/navjot/.whatsapp-scheduler-bot

# Session Lifetime (Default: 2160 hours = 90 days with sliding extension)
SESSION_TOKEN_TTL_HOURS=2160
```

### 4. Running the Server

#### Development / Direct Run:
```bash
npm run ui
```

#### Production Systemd Service (Recommended on Linux):
Create `/etc/systemd/system/whatsapp-scheduler.service`:
```ini
[Unit]
Description=WatchPoint WhatsApp Patrol Scheduler
After=network.target

[Service]
Type=simple
User=navjot
WorkingDirectory=/home/navjot/Downloads/whatsapp-scheduler-bot
ExecStart=/usr/bin/npm run ui
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now whatsapp-scheduler.service
sudo systemctl status whatsapp-scheduler.service
```

---

## 🌐 Master Admin Web Console Guide

Access the Master Admin Console directly in any browser:
```text
https://YOUR-SERVER-DOMAIN:PORT/admin?token=YOUR_PATROL_TOKEN
```
*(or navigate to `/admin` and enter your master `PATROL_TOKEN` at the prompt)*

### Dashboard Modules:
- **👥 Guards & Accounts**: View all registered guards, 1-click **Reset PIN**, pair WhatsApp sessions, or register new guard profiles.
- **📱 WhatsApp Session**: View live connection status, scan auto-refreshing QR codes, change target WhatsApp group, or force reconnect.
- **⏰ Shift Schedules**: Enable automated timed shift check-ins, set shift start/end hours (e.g. 20:00 to 08:00), active days, and randomized interval ranges.
- **📍 Checkpoints & Patrol**: Add/edit GPS checkpoints, adjust minimum message spacing, configure checkpoint re-entry cooldowns, and trigger test dispatches.
- **📋 Activity Logs**: Live streaming audit log with filter chips (**Patrol GPS**, **Schedules**, **Errors**).

---

## 📱 iOS App (`WatchPoint`) Setup Guide

The native iOS guard app is located in [`ios/WatchPoint/`](ios/WatchPoint/).

### 1. Open the Xcode Project
```bash
open ios/WatchPoint/WatchPoint.xcodeproj
```

### 2. Configure Capabilities & Permissions
The app is pre-configured with the necessary Apple capabilities in `Info.plist`:
- **Location When In Use & Always** (`NSLocationAlwaysAndWhenInUseUsageDescription`): Required for background checkpoint arrival detection.
- **Face ID** (`NSFaceIDUsageDescription`): Required for biometric app lock.
- **Background Modes**: Location Updates.

### 3. Set Backend Server URL
1. Build and run the app on your physical iPhone or Simulator (`Cmd + R`).
2. On initial launch, tap **Configure Server** (or open **Account → Server**).
3. Set your production server URL:
   ```text
   https://hp-server.tailed5092.ts.net:10000
   ```
4. Sign in with your registered **Phone Number** and **4-digit Security PIN**.

---

## 📡 REST API Reference

All requests accept and return standard `application/json`. Authenticate with `X-Admin-Token` (master admin) or `X-Account-Auth` (guard session token).

### 1. Master Admin Endpoints
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/admin/auth` | Authenticates master `PATROL_TOKEN`. |
| `GET` | `/api/admin/overview` | Returns server health, all guards, WhatsApp states, and configs. |
| `POST` | `/api/admin/reset-pin` | Resets a guard's security PIN (`{ accountId, newPin }`). |
| `POST` | `/api/admin/whatsapp/reconnect` | Forces WhatsApp client to restart and generate a fresh QR code. |
| `POST` | `/api/admin/whatsapp/logout` | Unlinks the active WhatsApp session. |
| `PUT` | `/api/admin/config` | Updates schedule timetable & destination chat settings. |
| `PUT` | `/api/admin/patrol-state` | Updates GPS checkpoints, message template, and cooldowns. |

### 2. Guard Authentication & Account Endpoints
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/accounts` | Lists public guard profiles (`id`, `name`, `hasPassword`). |
| `POST` | `/api/accounts` | Registers a new guard (`{ name, password }`). Returns 409 if phone exists. |
| `POST` | `/api/accounts/auth` | Signs in guard (`{ account, password }`). Returns 90-day session `token`. |
| `POST` | `/api/accounts/password` | Changes guard password with active session token. |
| `DELETE` | `/api/accounts?account=...` | Deletes a guard profile and wipes their runtime. |

### 3. Patrol & Location Endpoints
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/patrol/location` | Ingests GPS coordinate (`{ latitude, longitude, accuracy, timestamp }`). Triggers message on geofence arrival. |
| `GET` | `/api/patrol/state` | Returns registered checkpoints, radius, and message template. |
| `GET` | `/api/patrol/status` | Returns delivery spacing countdown (`minutesUntilAvailable`, `nextAvailableAt`). |
| `POST` | `/api/patrol/trigger` | Triggers a test dispatch (`{ source, checkpointName, dryRun }`). |

### 4. Telemetry & Logs
| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `GET` | `/api/health` | System health, uptime, connected accounts, and engine version. |
| `GET` | `/api/logs?account=...` | Retrieves recent activity log entries. |
| `DELETE` | `/api/logs?account=...` | Clears activity logs. |

---

## 🛠️ Troubleshooting & FAQ

### 1. "Cannot link new device. Try again later" on WhatsApp
- **WhatsApp Linked Devices Limit**: WhatsApp allows a maximum of 4 linked devices per phone number. Open **WhatsApp → Settings → Linked Devices** on your phone, tap inactive sessions, and choose **Log Out**.
- **Anti-Spam Cooldown**: If several QR codes were scanned in quick succession, switch your phone from Wi-Fi to Cellular (or wait 10 minutes) before scanning again.

### 2. Session Auto-Logout on iPhone
- Ensure the server is running version `1.3.0` with persistent sessions enabled (`sessions.json`).
- Guard session tokens now have a **90-day sliding window** and persist across server reboots.

### 3. GPS Geofence Checkpoint Not Triggering
- Ensure location permissions in iOS Settings are set to **"Always Allow"** with **"Precise Location"** enabled.
- Verify that your checkpoint radius is at least `50m` to accommodate GPS jitter in indoor or low-reception areas.

---

## 📜 License
Internal proprietary software for guard patrol operations and automated WhatsApp dispatches.

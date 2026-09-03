# SiteSync ChirpStack

A ChirpStack LoRaWAN network server packaged so the same stack can be deployed
at every customer site, and so that changing a setting later does not require
knowing Linux.

**One rule: you edit `.env`, then run `./sitesync apply`. Nothing else.**

---

## Installing a new site

On a machine with Docker installed:

```bash
git clone <this repo> chirpstack && cd chirpstack
bash setup.sh
```

`setup.sh` asks about eight questions, generates the passwords, writes `.env`,
checks its own work and offers to start the site. Total time is a few minutes.

To have the site come back automatically after a power cut:

```bash
sudo bash systemd/install.sh
```

---

## Changing something later

Open `.env` in any text editor. Every setting has a comment above it saying
what it does and what the valid values are. Change what you need, save, then:

```bash
./sitesync apply
```

`apply` checks your settings **before** it changes anything, so a typo gets a
plain-English explanation rather than a broken site.

If you are ever unsure what state things are in:

```bash
./sitesync doctor
```

---

## The commands

| Command | What it does |
| --- | --- |
| `./sitesync status` | Is it running, and what URL do I use? |
| `./sitesync apply` | I edited `.env` — make it take effect |
| `./sitesync doctor` | Check everything and explain any problem |
| `./sitesync logs [name]` | Watch what a service is saying |
| `./sitesync start` / `stop` / `restart` | The obvious things |
| `./sitesync backup` | Save the database and settings to `backups/` |
| `./sitesync restore FILE` | Put a backup back (asks first) |
| `./sitesync update` | Move to newer software, backing up first |
| `./sitesync pin` | Lock exact versions so the next site matches this one |
| `./sitesync mqtt add\|list\|reset\|remove` | Manage who may connect to MQTT |
| `./sitesync mqtt-info` | Print ChirpStack's own MQTT details |
| `./sitesync ca` | Export the self-signed certificate so browsers trust it |

---

## The settings that matter most

### `REGION`

The single most important setting. It configures the network server, both
gateway bridges, and the MQTT topic prefixes **together**, so they cannot drift
out of sync — which is the classic way these deployments break.

```
REGION=us915_0
```

Valid values are the file names in `configuration/chirpstack/region_*.toml`.

### `TLS_MODE`

How the web interface is secured. Change the word, run `./sitesync apply`.

| Value | What you need | What you get |
| --- | --- | --- |
| `self-signed` | nothing at all | HTTPS immediately; a one-time browser warning |
| `off` | nothing at all | plain HTTP, no encryption |
| `letsencrypt` | a public domain pointing here, ports 80 + 443 open | real trusted HTTPS, renews itself |
| `custom` | your own `certs/cert.pem` and `certs/key.pem` | HTTPS with your certificate |

**No customer is ever required to obtain a certificate.** `self-signed` is the
default and works on a machine with no domain name and no internet connection.
Moving to `letsencrypt` later is a one-word change; nothing else moves.

Run `./sitesync ca` to export the self-signed certificate and install it on the
handful of computers that use the interface — the warning then disappears
without anyone buying anything.

### `MQTT_TLS`

Deliberately separate from `TLS_MODE`, because browsers and gateways have
different needs. `off`, `self-signed` or `custom`. The unencrypted port stays
open in every mode, so gateways can be migrated one at a time rather than all
at once.

---

## MQTT users (so you are not the one adding them)

External MQTT users are dashboards, historians, Node-RED, or a gateway running
its own bridge. ChirpStack's own connection is separate and lives in `.env`.

You never write MQTT permission rules. You pick a **role**, and the rules are
generated:

| Role | Can do |
| --- | --- |
| `integration` | read application data only — the common case |
| `integration-rw` | read application data, and send downlinks |
| `gateway` | publish gateway events/state, subscribe to commands |
| `gateway:EUI` | the same, locked to one gateway ID |

```bash
./sitesync mqtt add acme-dashboard integration   # shows the password once
./sitesync mqtt list                             # who exists and what they may do
./sitesync mqtt reset acme-dashboard             # they lost it; gives a new one
./sitesync mqtt remove old-gateway
./sitesync mqtt show acme-dashboard              # connection details for a ticket
```

Each of these reloads the broker with `SIGHUP`, so **nothing disconnects** —
no restart, no dropped gateways.

**Passwords are stored hashed and cannot be looked up.** That is deliberate: it
means a lost password is a self-service reset that anyone on site can run,
rather than a phone call. The reset command is the answer to "who do I ask?"

The list of users lives in `mqtt-users.conf`, one line per user. You can equally
add someone by editing that file and running `./sitesync apply` — a new line
gets a generated password printed once, and a deleted line revokes the login.
The file backs up with everything else, so a rebuilt machine comes back with the
same users.

---

## What is and is not encrypted

`TLS_MODE` covers the **web interface and REST API only**.

- The Semtech UDP packet forwarder on port 1700 has **no encryption at all** —
  the protocol does not support it. Keep that traffic on a trusted network.
- MQTT is controlled separately by `MQTT_TLS`.
- Basics Station on port 3001 is plain unless you configure certificates in
  `configuration/chirpstack-gateway-bridge/`.

Do not tell a customer "TLS is on" and mean all of it.

---

## Layout

```
.env                    the only file you edit          (never committed)
mqtt-users.conf         who may connect to MQTT         (never committed)
.env.example            the annotated template
setup.sh                first-time wizard
sitesync                every day-to-day command
scripts/                what sitesync actually runs
certs/                  your certificates, if any       (never committed)
backups/                ./sitesync backup writes here   (never committed)
systemd/                start-on-boot installer
configuration/
  caddy/modes/          one short file per TLS_MODE — readable without knowing Caddy
  chirpstack/           network server + one file per region
  chirpstack-gateway-bridge/
  mosquitto/            broker; conf.d/ is generated from .env
  postgresql/initdb/
```

---

## Deploying the same thing twice

The image versions live in `.env` (`CHIRPSTACK_VERSION` and friends). They ship
as major-version tags, which means a site installed today and one installed in
six months may not match.

For a fleet you want to be identical, replace them with exact published tags —
for example `CHIRPSTACK_VERSION=4.13.0` — and use that `.env` as the template
for every new site. `./sitesync pin` shows what a running site is actually on.

---

## Importing the device profile library

Optional, and it needs `make`:

```bash
make import-device-profiles
```

---

## Notes for whoever maintains this

- The stack is reached through Caddy, which owns ports 80/443 and the REST API
  port. ChirpStack's own 8080 is deliberately not published.
- Postgres and Redis have healthchecks and ChirpStack waits on them, which
  fixes the start-up race in the upstream compose file.
- Container logs are capped by `LOG_MAX_SIZE` and `LOG_MAX_FILES` so an
  unattended edge box cannot fill its disk.
- `configuration/mosquitto/conf.d/` and `certs/` are generated. Do not hand-edit
  them; change `.env` and run `./sitesync apply`.
- Scripts must keep Unix line endings. `.gitattributes` enforces this — without
  it, a checkout on Windows produces `bad interpreter: /bin/bash^M` on Linux.

Based on [chirpstack/chirpstack-docker](https://github.com/chirpstack/chirpstack-docker).

# SiteSync ChirpStack

A ChirpStack LoRaWAN network server packaged so the same stack can be deployed
at every customer site, and so that changing a setting later does not require
knowing Linux.

**One rule: you edit `.env`, then run `./sitesync apply`. Nothing else.**

---

## The lifecycle of an installation

| Phase | Command | Where | How often |
| --- | --- | --- | --- |
| **Build** | `os-provisioning/build/prepare-airgap.sh --latest` | your connected machine | once per release |
| **Transfer** | copy the folder | USB or scp | once per site |
| **Install** | `sudo bash install.sh` | the customer VM | once |
| **Configure** | (part of install, step 40) | the customer VM | once per site |
| **Operate** | `./sitesync ...` | the customer VM | forever |
| **Update** | `--images-only` artifact | the customer VM | occasionally |
| **Remove** | `sudo bash uninstall.sh` | the customer VM (ships in the artifact) | rarely |

The artifact carries **everything**: Docker Engine as an offline apt repo, the
container images, and a snapshot of this stack. Nothing is placed by hand on
site, and the target never needs an internet connection.

`install.sh` is a thin wrapper that runs the numbered steps in
`os-provisioning/target/steps/` in order (in this repo; they are copied into every artifact):

```
00-preflight       checks the machine BEFORE anything is changed
10-docker-engine   installs Docker from the offline package repo
20-load-images     loads the container images and confirms each one
30-install-stack   puts the stack in /opt/sitesync
40-configure-site  asks the site questions, writes .env
50-verify          starts it, runs doctor, prints the address
```

The numbering is not decoration. A failure names a step and stops, having
attempted nothing after it, and everything printed is also written to
`/var/log/sitesync-airgap/`. Once the cause is fixed:

```bash
sudo bash install.sh --resume     # carry on from the step that failed
sudo bash install.sh --redo 20    # re-run one step
```

`00-preflight` is deliberately first and changes nothing. It checks the Ubuntu
release and architecture against what the artifact was built for, conflicting
container packages, disk space, systemd, and that every archive named in
`AIRGAP_INFO` actually arrived. **A preflight failure leaves the machine exactly
as it was found** — the difference between "fix it and re-run" and "rebuild the VM."

Step 30 never overwrites a configured site: it preserves `.env`, `certs/`,
`mqtt-users.conf` and `backups/`, refreshes everything else, and leaves the
previous copy beside it as `…​.replaced-<timestamp>`. That is also how you ship
a fix to `sitesync` itself to an existing site.

**Artifacts are customer-agnostic.** No site settings are baked in at build
time, so one artifact serves every customer and the answers all come from the
wizard on site — the same reasoning as `--data-root` being an install-time flag.

**Every container image travels as a tar in the artifact.** The image list is
read out of `docker-compose.yml` itself (`--from-compose`), with every profile
enabled, so it cannot fall out of step with what the stack runs. Before the
bundle is written, the builder re-reads the compose file and refuses to build if
any image it references is missing — a missing image is otherwise invisible
until a container will not start on a machine with no internet.

Nothing in `stack/` pulls an image at runtime except `eclipse-mosquitto`, which
is bundled and is used to hash MQTT passwords. Generating a self-signed MQTT
certificate uses the host's `openssl` rather than a container, for the same
reason; `doctor` reports if it is missing.

**No secrets ever travel in an artifact.** The bundler excludes `.env`,
`certs/*.pem`, `mqtt-users.conf` and the generated broker files, then greps the
finished tarball for them and refuses to build if any are present. The exclude
list is not trusted on its own.

---

## Installing a new site

**From an airgap artifact** (the normal path — see the lifecycle above):

```bash
tar xf airgap-noble-cs4.x.x-<date>.tar
cd airgap-noble-cs4.x.x-<date>
sudo bash install.sh
```

That is the whole job. It ends with a configured, running site.

**From a git checkout**, on a machine that already has Docker:

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

It also reloads the services that read their configuration from a file on disk
— the web server and the MQTT broker. This is not optional housekeeping: Docker
only recreates a container when its *definition* changes, so editing a mounted
config file otherwise has no effect at all and the site keeps running the
settings it started with.

The web server's configuration is **validated before anything is touched**. If
it is not valid, nothing changes and the error is printed — a bad edit cannot
take the site down. If it is valid, the web server is restarted, which costs
about a second on the web interface and touches no other service. (A restart
rather than a live reload, because `caddy reload` needs the admin API and this
stack switches that off.)

Hand-editing files under `configuration/chirpstack/` is the exception — those
are read once at startup, so run `./sitesync restart` after changing them.

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
| `./sitesync region list\|add\|remove` | See or change which sub-bands this site serves |
| `./sitesync mqtt add\|list\|reset\|remove` | Manage who may connect to MQTT |
| `./sitesync mqtt-info` | Print ChirpStack's own MQTT details |
| `./sitesync ca` | Export the self-signed certificate so browsers trust it |

---

## The settings that matter most

### `RF_REGION` and `SERVED_REGIONS`

Two settings, matching the two questions an operator actually has: *what radio
is this?* and *what do my gateways transmit on?*

```bash
RF_REGION=US915
SERVED_REGIONS="us915_0:1700 us915_12:1701"
```

`RF_REGION` is the region on the gateway's datasheet — `US915`, `EU868`,
`AU915`, `AS923`, `CN470`, and so on. It does **not** decide what the server
enables. It is the fence: every sub-band in `SERVED_REGIONS` has to belong to
it, so a typo that would leave gateways connected but deaf is caught before
anything starts.

`SERVED_REGIONS` is one entry per sub-band this site serves, and it drives both
what ChirpStack enables and what containers run. A region is enabled because
something serves it — never merely because it belongs to `RF_REGION`.

Each entry is `sub-band:how`, where `how` is either a UDP port or the word
`forwarder`:

```bash
SERVED_REGIONS="us915_0:1700 us915_12:1701 us915_1:forwarder"
```

| `how` | What runs | When to use it |
|---|---|---|
| a port | a Gateway Bridge container listening on that UDP port | the gateway speaks the Semtech UDP packet-forwarder protocol — almost all of them, out of the box |
| `forwarder` | nothing; the region is enabled and no container is created | the gateway runs ChirpStack's own MQTT Forwarder and publishes to the broker itself |

A `forwarder` entry exists because such a site has no bridge at all, and would
otherwise have no way to enable its region. Those gateways need an MQTT login
of their own — `./sitesync mqtt add NAME gateway`.

There is no limit on the number. `1700/udp` is the standard Semtech
packet-forwarder port, so the first bridge entry should normally use it.

Editing this by hand is rarely necessary:

```bash
./sitesync region list             # what is served, and how
./sitesync region add              # asks which sub-band, and bridge or forwarder
./sitesync region remove us915_12  # confirms first
```

`doctor` checks that every sub-band belongs to `RF_REGION`, that no two bridges
share a port, that each served region has its `region_*.toml` file, and that
the generated `chirpstack.toml` actually matches `SERVED_REGIONS` — a mismatch
there means gateways connect and uplinks silently go nowhere, which is the
failure this design exists to prevent.

> Sites built before 2026-09 used `GATEWAY_BRIDGES`, which held only the port
> form. It is still read, and the first `./sitesync apply` rewrites it to
> `SERVED_REGIONS`, leaving the old line commented out above it.

**Two generated files** come out of this, both listed in `.gitignore`:
`configuration/chirpstack/chirpstack.toml` (from `chirpstack.toml.template`,
which is the file to edit for anything else ChirpStack-side) and
`compose/gateways.yml` (the bridge services — Compose cannot loop, so they are
generated, and `COMPOSE_FILE` in `.env` loads both files).

**BasicStation is not currently wired up.** Configs exist only for the
8-channel sub-bands, not the 16- or 64-channel plans, so offering it would
produce containers that die on startup. UDP works for every plan.

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

## Pointing at a different broker

Every component reads its broker URL from one line. There are no broker URLs
anywhere else — not in the 39 region files, not in the gateway bridge configs.

```bash
MQTT_BROKER_URL=tcp://mosquitto:1883        # the bundled broker (default)
MQTT_BROKER_URL=ssl://mqtt.customer.com:8883    # a broker they already run
```

If that broker uses a private or self-signed certificate, drop the CA file in
`certs/` and name it:

```bash
MQTT_CA_CERT=/certs/customer-ca.pem
```

Then `./sitesync apply`. `doctor` cross-checks the two: it catches a missing CA
file, a `ssl://` URL pointing at a port that is not listening, an unrecognised
scheme, and a CA set on a plaintext connection.

Note the difference between the two MQTT settings, because it is easy to
conflate them:

- `MQTT_TLS` — whether the **bundled** broker offers an encrypted listener.
  Irrelevant if you point at an external broker.
- `MQTT_BROKER_URL` — how ChirpStack and the bridges **connect out**.

---

## Certificate lifetimes (what can expire, and what cannot)

**Nothing here expires and silently breaks.** The two self-signed certificates
behave very differently, so it is worth knowing which is which.

| | Lifetime | Renews itself? |
| --- | --- | --- |
| Web interface, `TLS_MODE=self-signed` | 12 hours | **Yes** — Caddy reissues continuously |
| ...its root authority (what you install on browsers) | **10 years** | n/a |
| MQTT, `MQTT_TLS=self-signed` | **10 years** | No — but `doctor` warns a year ahead |
| `letsencrypt` | 90 days | **Yes** — Caddy renews at 60 days |
| `custom` | whatever you were issued | No — `doctor` warns a year ahead |

`./sitesync doctor` checks every certificate on disk and reports as `ok` above a
year, a `note` inside a year, and a `PROBLEM` inside 90 days — so a renewal is
something you notice on a routine check, not on the morning it breaks.

To replace the MQTT certificate, delete `certs/mqtt-cert.pem` and
`certs/mqtt-key.pem` and run `./sitesync apply`. A new one is generated, and the
new `certs/mqtt-ca.pem` goes out to the clients.

### The thing that actually bites

Expiry is not the real risk — **losing the certificate authority is.**

With `TLS_MODE=self-signed`, Caddy's root authority lives in the `caddydata`
Docker volume, not in this folder. If that volume is lost — a rebuilt machine, a
replaced disk, or someone running `docker compose down -v` — Caddy generates a
completely new authority. Every browser where someone installed the old root
starts warning again, and you get the phone call.

`./sitesync backup` saves that authority, and `./sitesync restore` puts it back,
so a rebuilt machine comes up with the same one and nobody notices. This is the
main reason to take a backup before touching a working site.

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

# Installing on the server

This is the guide for the person standing in front of the customer's server.

You will be given **one file** — something like
`airgap-noble-cs4.11.0-20260908.tar`. Everything needed is inside it. The
server does **not** need an internet connection at any point.

You do not need to know Linux. Every command you need is written out below.
Type them exactly, or copy and paste them.

---

## Before you start

You need:

- [ ] The `.tar` file, on a USB stick or already copied to the server
- [ ] A terminal on the server — either at the keyboard, or over SSH
- [ ] An account on the server that can use `sudo`
- [ ] Its password
- [ ] **Free disk space.** The installer requires 8 GB free on `/var/lib` plus
      4 GB wherever Ignition goes, and refuses to start without it. Aim for
      40 GB on the VM so you are not fighting it — see *"Not enough disk
      space"* in Troubleshooting.
- [ ] The site's network address — a DNS name like `chirpstack.acme.local`, or
      an IP like `192.168.1.50`. You will be asked for it near the end.
- [ ] Which **radio region** the gateways are certified for (US915, EU868, …).
      It is printed on the gateway's datasheet.

Set aside **30–60 minutes**. Most of that is waiting.

> **A note about `sudo`.** `sudo` means "do this as the administrator". The
> first time you use it, it asks for **your own** password, not a separate
> administrator password. Nothing appears on screen as you type it — that is
> normal, not a broken keyboard. Type it and press Enter.

---

## Step 1 — Get the file onto the server

**If you are sitting at the server** with a USB stick, copy the file into your
home folder using the file manager, or plug it in and run:

```bash
cp /media/*/airgap-*.tar ~/
```

**If you are working from your own laptop over the network**, from your
laptop's terminal:

```bash
scp airgap-noble-cs4.11.0-20260908.tar youruser@192.168.1.50:~/
```

Replace the filename, the username and the IP with the real ones. Then connect
to the server:

```bash
ssh youruser@192.168.1.50
```

---

## Step 2 — Unpack it

In the terminal **on the server**:

```bash
cd ~
tar xf airgap-noble-cs4.11.0-20260908.tar
```

Use the real filename. If you are not sure what it is, `ls *.tar` lists it.

This creates a folder with the same name. Go into it:

```bash
cd airgap-noble-cs4.11.0-20260908
```

Have a look at what you have — this is optional but takes two seconds:

```bash
cat README.txt
```

---

## Step 3 — Run the installer

```bash
sudo bash install.sh
```

That is the whole job. It runs seven steps in order and **stops at the first
real problem**, leaving the machine in a state you can restart from.

The first thing it prints is the log path. **Write it down.** It looks like:

```
Log: /var/log/sitesync-airgap/install-20260908-174449.log
```

If you have to call for help, that path is the only thing anyone will ask you
for.

### What happens, in order

| Step | What it does | Roughly |
|---|---|---|
| — | Checks the files copied over intact | seconds |
| **00** | Checks the machine before changing anything | seconds |
| **10** | Installs Docker Engine from the offline package repo | 1–2 min |
| **15** | Installs the Ignition gateway on the machine itself | 5–15 min |
| **20** | Loads the container images | 2–5 min |
| **30** | Installs the stack to `/opt/sitesync` | seconds |
| **40** | **Asks you the site questions**, then offers to start the site | 5 min |
| **50** | Checks the result and prints the addresses | 1–2 min |

Step 00 changes nothing. If it fails, the machine is exactly as you found it.

### It will ask you two things

**At the very start — where everything should be installed.** You only see this
if the machine has a second drive:

```
   This machine has a second drive:

     /data                        458 GB free

   Installing everything on /data:
     stack      /data/sitesync   (also reachable as /opt/sitesync)
     docker     /data/docker
     ignition   /data/ignition

   Answering no uses the OS disk instead:
     /opt/sitesync, /var/lib/docker, /usr/local/bin/ignition

   Install everything on /data? [Y/n]:
```

**Press Enter** if the drive was put there for this. That is the usual case —
the OS disk on these machines is small, and the database, container images and
Ignition all grow.

`/opt/sitesync` keeps working either way: it becomes a symlink to the real
location, so every command in this document is unchanged. It is a symlink, not
a stray copy — leave it alone.

If there is no second drive, nothing is asked and everything goes on the OS
disk.

**During step 15 — where to install Ignition.** You only see this if you did
*not* answer the question above (no second drive, or you declined it):

```
   Where should Ignition be installed?
   Press Enter for the default, or type a full path.

   Location [/usr/local/bin/ignition]:
```

**Press Enter.** The default is the vendor's own location and is correct unless
someone has specifically told you otherwise.

**During step 40 — eight questions about the site.** These are covered in the
next section.

### Installing only some of it

By default you get everything in the artifact. To install one piece — adding
Ignition to a machine that already runs ChirpStack, say, or standing up Docker
before a maintenance window:

```bash
sudo bash install.sh --only-ignition       # just the Ignition gateway
sudo bash install.sh --only-docker         # just Docker Engine
sudo bash install.sh --only-chirpstack     # images, stack and site questions
sudo bash install.sh --no-ignition         # everything except Ignition
```

`--only-*` may be repeated (`--only-docker --only-chirpstack`). The installer
prints a **Plan** before it starts, listing exactly what it will touch — read
it before you answer anything.

---

## Step 4 — The eight site questions

This is the only part that needs your judgement. Press **Enter** to accept the
suggestion shown in `[brackets]` — the suggestions are usually right.

Every answer can be changed later by editing one file. Nothing here is
permanent.

| # | Question | What to answer |
|---|---|---|
| **1** | Who is this site for? | A short lowercase name, no spaces — `acme`. Then the full name for reports — `Acme Manufacturing`. |
| **2** | Which radio region? | From the gateway's datasheet. `US915` in North America, `EU868` in Europe. The list of valid options is printed on screen. |
| **2b** | Which sub-bands does this site serve? | First it asks whether your gateways use the plain UDP packet forwarder — **almost always yes, press Enter**. Then: **press Enter at each prompt** — first sub-band, UDP port 1700, then "no" to adding another. Only add more if different gateways use different channel plans. Regions with a single frequency plan skip the rest. See below if your gateways run the MQTT Forwarder instead. |
| **3** | What address will people type in their browser? | **The most important answer here.** See below. |
| **4** | How should the web interface be secured? | **Press Enter for `1) self-signed`** unless the customer already has a certificate. Browsers show a one-time warning that you click past. |
| **5** | Should MQTT require a login? | **Yes** (press Enter). A password is generated for you; see it later with `./sitesync mqtt-info`. |
| **6** | Should MQTT traffic be encrypted? | **No** (press Enter) if the gateways are on the same network or a VPN. Yes only if they cross the public internet. |
| **7** | Which gateway protocols does this site use? | **Yes to both** (press Enter twice) unless you have been told otherwise. Unused ones cost nothing. The REST API is no longer asked about — it is required on every SiteSync site and is always installed. |
| **8** | Generating secrets | Nothing to answer. It generates them. |

### About question 2b — gateway bridge or MQTT Forwarder

Question 2b asks how gateway traffic reaches this machine. There are two
answers and you need to know which one before you start:

**A gateway bridge here (the usual answer).** The gateway sends the plain
Semtech UDP packet-forwarder protocol at this machine, which listens on a UDP
port — 1700 by default. Almost every gateway ships configured this way. Say
**yes** to the "plain UDP packet forwarder" question and give a port.

**The gateway's own MQTT Forwarder.** Some gateways run ChirpStack's MQTT
Forwarder themselves and publish straight to this site's broker. Nothing
listens on a UDP port for them, so no bridge container is created. Say **no**
to the "plain UDP packet forwarder" question.

Those gateways each need an MQTT login, which you create after the install:

```bash
cd /opt/sitesync
./sitesync mqtt add gw-north gateway
```

That prints the username and password once. Put them into the gateway's
forwarder configuration, along with the sub-band name (`us915_0`) as its topic
prefix.

If you are not sure which one you have, it is a bridge. Ask before choosing the
other.

### About question 3 — get this one right

The address must be **exactly** what people will type in their browser. It is
not a label:

- The security certificate is issued for that exact value, and
- the web server only answers to that exact value.

Get it wrong and the site refuses connections from other machines, or shows a
certificate warning that never goes away no matter what anyone clicks.

The installer suggests the machine's own IP address. Use that unless there is a
DNS name pointing here — a DNS name is better, because it survives the IP
changing.

**Do not answer `localhost`** unless ChirpStack will only ever be used from this
one machine. Nobody else on the network will be able to reach it.

### At the end

It asks **"Start the site now"** — say **yes** (press Enter).

---

## Step 5 — Check it worked

Step 50 runs automatically and prints a summary. You are looking for two
things.

**ChirpStack**, reachable at the address you gave in question 3:

```
https://192.168.1.50
```

**Ignition**, on port 8088:

```
http://192.168.1.50:8088
```

Open both in a browser to confirm.

> **Important — do this before you leave.** The first visit to the Ignition
> address runs the commissioning wizard, where the admin password is set.
> **Until that is done, anyone on the network can do it.** Either walk the
> customer through it now, or do it yourself and hand over the password.

You can re-print the summary at any time:

```bash
cd /opt/sitesync
./sitesync status
```

---

## Step 6 — Finish up

**Make it start after a power cut.** This is not automatic — do it:

```bash
cd /opt/sitesync
sudo bash systemd/install.sh
```

**Log out and back in.** The install added your account to the `docker` and
`sitesync` groups, and neither takes effect until you do. Until then
`./sitesync` needs `sudo`, and some commands will say the password file is not
readable in this session — that message is harmless and goes away after you log
back in.

**Give the other admins access.** The site is owned by the `sitesync` group so
it does not belong to whoever happened to install it. For each person who
should be able to run `./sitesync` without `sudo`:

```bash
sudo usermod -aG sitesync,docker THEIR_NAME
```

They log out and back in once, and that is all.

**Everyday commands**, all run from `/opt/sitesync`:

| Command | What it does |
|---|---|
| `./sitesync status` | Is it running, and what is the address |
| `./sitesync doctor` | Check the settings for problems |
| `./sitesync logs` | Watch what a service is saying |
| `./sitesync region list` | Which sub-bands this site serves |
| `./sitesync region add` | Serve another sub-band — see below |
| `./sitesync mqtt-info` | Show the generated MQTT username and password |
| `nano .env` then `./sitesync apply` | Change any setting from setup |

### Adding a sub-band later

When a customer buys gateways on a different channel plan, you do not edit any
files:

```bash
cd /opt/sitesync
./sitesync region add
```

It lists the sub-bands not yet in use, asks which one, asks for a UDP port
(suggesting the next free one) or whether that gateway runs its own MQTT
Forwarder, and then applies the change — including restarting ChirpStack so the
new region actually loads. Point the gateway at the port it prints.

`./sitesync region remove us915_12` undoes it, after confirming. Gateways on
that sub-band stop reaching the site; devices, applications and stored data are
untouched.

---

## If something goes wrong

The installer stops at the first real problem and tells you three things: what
failed, where the log is, and how to carry on. **Nothing after the failed step
was attempted.**

Once you have fixed the cause, you do not start over. Run:

```bash
sudo bash install.sh --resume
```

That skips every step that already succeeded and picks up where it stopped.

To force one specific step to run again, e.g. step 20:

```bash
sudo bash install.sh --redo 20
```

### Every step-00 check, and what to do

Step 00 runs before anything is changed. A failure here means the machine is
untouched.

| Message | What it means | What to do |
|---|---|---|
| `this artifact was built for Ubuntu 'X' but this machine is 'Y'` | Wrong bundle for this server | Ask the office for a bundle built with `--codename Y`. The Docker packages genuinely will not work otherwise. |
| `this machine is X but the artifact was built for Y` (architecture) | Wrong CPU architecture | Ask for a bundle built with `--arch X`. Nothing here will run. |
| `these conflict with Docker Engine and must be removed first` | An old or different Docker is installed | Run the `apt-get remove` command it prints. For a snap: `sudo snap remove docker`. |
| `Ignition is already installed on this machine` | A gateway is already here; this installer installs, it does not upgrade | Three choices, all printed on screen: remove it with `sudo bash uninstall.sh`, ask for a bundle built `--skip-ignition`, or install alongside with `--ignition-dir /opt/ignition-new`. |
| `only NNNN MB free on /var/lib` | Not enough disk | See *"Not enough disk space"* below. |
| `<file> is named in AIRGAP_INFO but is not in this folder` | The copy is incomplete | Copy the whole folder over again. Do not copy files individually. |
| `this machine is not running systemd` | Not a normal Ubuntu Server (a container, or WSL) | This needs a real VM or physical machine. Escalate. |
| `port(s) N are already in use` | **Warning, not a failure** | The install continues. ChirpStack's ports can be moved during setup; Ignition's 8088/8043 cannot. Find out what is holding them. |

### Not enough disk space

```
FAILED: only 6234 MB free on /var/lib, and the images need about 8192 MB.
```

Three options, in order of preference:

1. **Give the VM a bigger disk.** 40 GB is comfortable. This is the real fix.
2. **Install onto a data drive**, if the machine has a second disk. This puts
   the stack, Docker's data and Ignition all on it:
   ```bash
   sudo bash install.sh --install-root /data
   ```
   The installer normally offers this on its own; you only need the flag if you
   answered no, or if the drive was mounted after you started.
3. **Free space.** If this machine has been used for testing before, the usual
   culprits are old install logs and Ignition backups that the uninstaller
   deliberately keeps:
   ```bash
   du -sh /var/log/sitesync-airgap /root /home/* /var/cache/apt
   sudo rm -f /var/log/sitesync-airgap/ignition-data-*.tar.gz
   sudo apt-get clean
   ```

### Other errors, by step

| Message | Step | What to do |
|---|---|---|
| `must run as root: sudo bash install.sh` | — | You forgot `sudo`. Run it again with `sudo` in front. |
| `AIRGAP_INFO missing - this folder is not a complete artifact` | — | You are in the wrong folder, or only part of it copied. `cd` into the unpacked folder; if it is incomplete, copy it again. |
| `checksum mismatch - re-copy the whole folder` | — | The transfer corrupted something. Copy the whole `.tar` again and re-unpack. Do not try to fix individual files. |
| `Docker Engine install failed` | 10 | Read the lines above it — this is `apt` talking. Send the log. |
| `docker.service would not start` | 10 | Usually a `--data-root` on an unsuitable filesystem. Try without `--data-root`, or check the message for `xfs with ftype=0` / `nfs`. |
| `only NNNN MB free on <dir>, and Ignition needs about 4096 MB` | 15 | Choose a location on a bigger disk when it asks, or free space and `--resume`. |
| `the Ignition install failed` | 15 | Send the log. Everything before this step is fine; `--resume` after the fix. |
| `no systemd unit was created for Ignition` | 15 | **Warning, not a failure.** A known 8.1 installer defect — the gateway runs now but will not survive a reboot. Worth fixing before you leave. Escalate. |
| `the gateway is not answering on port 8088 yet` | 15 | **Warning, not a failure.** It can be slow on a cold first start. Check with `sudo systemctl status Ignition-Gateway` and `sudo tail -50 /usr/local/bin/ignition/logs/wrapper.log`. |
| `these images did not load: ...` | 20 | The image bundle is incomplete or the disk filled up. Check space, then `--redo 20`. |
| `the stack snapshot is missing <file>` | 30 | The artifact was built wrong. This is an office problem, not a site problem — ask for a rebuilt bundle. |
| `this machine has an older install at /opt/sitesync-chirpstack` | 30 | **Warning.** An install from before Sept 2026. If it holds a configured site, stop and re-run with `--install-dir /opt/sitesync-chirpstack` to keep it. |
| `setup did not complete` | 40 | Nothing is lost. Run it again: `cd /opt/sitesync && sudo bash setup.sh` |
| `No terminal available, so the questions cannot be asked here` | 40 | You ran the installer with output redirected. Finish at the console: `cd /opt/sitesync && sudo bash setup.sh` |

### Starting completely over

On a **test machine only** — this destroys every container, image and volume on
the box, including the ChirpStack database:

```bash
sudo bash uninstall.sh
```

It asks you to type `wipe` to confirm, and archives Ignition's data to
`/var/log/sitesync-airgap/` first. It has no business on a customer VM.

Preview what it would do without changing anything:

```bash
sudo bash uninstall.sh --dry-run
```

---

## When you call for help

Have these ready:

1. **The log path** printed at the very top of the run —
   `/var/log/sitesync-airgap/install-YYYYMMDD-HHMMSS.log`. Everything you saw
   on screen is in there.
2. Which step number failed.
3. What `cat AIRGAP_INFO` says, from the artifact folder.

Send the log file itself. It is the one thing that answers most questions
without a phone call:

```bash
ls -lt /var/log/sitesync-airgap/
```

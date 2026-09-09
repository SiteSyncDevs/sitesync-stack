# Building the install bundle

This is the **office half** of the job. Everything here runs on your own
machine, with internet. Nothing in this document touches a customer server.

The output is a single `.tar` file — the *artifact* — containing Docker Engine,
the ChirpStack container images, the stack itself, the Ignition gateway
installer, and the installer that runs it all. You hand that one file over, and
the person at the site follows
[`installing-on-target.md`](installing-on-target.md).

> **Which half am I in?** If the path starts with `os-provisioning/build/`, it
> runs on your laptop. If it starts with `os-provisioning/target/`, it runs on
> the customer's server.

---

## 1. What your build machine needs

A Linux machine (or WSL) with internet access and:

| Requirement | Why | Check it |
|---|---|---|
| Docker, running | The container images are pulled through it | `docker info` |
| `curl`, `gpg`, `python3`, `tar`, `gzip`, `sha256sum` | Downloads and packing | `which curl gpg python3` |
| `dpkg-scanpackages` **or** `apt-ftparchive` | Builds the offline apt repo | `apt install dpkg-dev` |
| ~15 GB free disk | Images plus a 1.5 GB Ignition installer plus the packed artifact | `df -h .` |

You do **not** need root, and your machine does **not** need to be the same
Ubuntu release as the target — the target release is chosen with a flag.

---

## 2. Survey the target first (recommended)

The bundle is built for one specific Ubuntu release and architecture. Building
a `noble` bundle for a `jammy` box produces an artifact that fails at step 00,
on site, in front of the customer.

Ask whoever has access to the server to run the read-only survey and send you
the file. It changes nothing and needs no network:

```bash
bash target-survey.sh -o survey.txt
```

`target-survey.sh` ships inside every artifact, and also lives at
`os-provisioning/target/target-survey.sh`. Its exit code is `0` if the box is
usable, `1` if it found a blocker.

Then build straight from it:

```bash
cd os-provisioning/build
./prepare-airgap.sh --latest --from-survey /path/to/survey.txt
```

That reads `SURVEY_CODENAME` and `SURVEY_ARCH` out of the file so the bundle
matches the actual machine. If the survey says `VERDICT: BLOCKED`, the build
still runs but warns you — the install will fail until the blockers are fixed.

No survey available? Skip to the next section; the defaults target
Ubuntu 24.04 (`noble`) on `amd64`, which is the SiteSync standard.

---

## 3. Build it

### The normal case — a complete new site

```bash
cd os-provisioning/build
./prepare-airgap.sh --latest
```

That single command produces everything a bare Ubuntu 24.04 server needs:

| Payload | What it is |
|---|---|
| `docker-offline-*.tar.gz` | Docker Engine as a complete offline apt repo, dependencies and recommends included |
| `chirpstack-images-*.tar.gz` | Every container image the compose file references, all profiles |
| `stack.tar.gz` | A snapshot of `stack/` — compose file, `configuration/`, `sitesync`, `setup.sh` |
| `ignition-*-linux-64.tar.gz` | The vendor Ignition `.run`, checksum-verified |
| `install.sh` + `steps/` | The installer, copied verbatim from `os-provisioning/target/` |
| `AIRGAP_INFO`, `VERSIONS.txt`, `SHA256SUMS`, `README.txt` | What is inside and how to prove it arrived intact |

`--latest` also reads the real version out of each pulled image and stamps it
into `VERSIONS.txt` and the artifact name, e.g.
`airgap-noble-cs4.11.0-20260908.tar`.

Expect this to take 10–25 minutes, mostly the Ignition download and the image
pulls. The finished file lands in `artifacts/`.

### The other cases

| Situation | Command |
|---|---|
| Site already has Docker; just needs new images | `./prepare-airgap.sh --images-only` |
| Target is 22.04, not 24.04 | `./prepare-airgap.sh --latest --codename jammy` |
| Target is ARM | `./prepare-airgap.sh --latest --arch arm64` |
| Site already runs Ignition — don't ship 1.5 GB again | `./prepare-airgap.sh --latest --skip-ignition` |
| Match an existing site's Ignition version | `./prepare-airgap.sh --latest --ignition-version 8.1.53` |
| Reproduce an exact past build (rollback) | `./prepare-airgap.sh --skip-docker --from-list records/<name>.pinned` |
| Your build host has no internet for Ignition | Download the `.run` by hand, then `--ignition-run ./ignition-8.1.54-linux-64-installer.run` |

`--images-only` implies `--latest --skip-docker --skip-ignition`. An image
update is about containers; re-shipping the engine and a gateway installer to a
site that has both would be a two-gigabyte no-op.

Full flag list: `./prepare-airgap.sh --help`.

---

## 4. Keep a build record (recommended for anything you ship)

```bash
./prepare-airgap.sh --latest --records ./records
```

This writes three small text files into the directory you name — `./records`
here, not next to the artifact — plus a `README.md` explaining them the first
time:

- `<name>.pinned` — the exact image digests. **This is your rollback path.**
  Rebuilding with `--from-list records/<name>.pinned` pulls those exact
  digests, so you get the same images back — which is what you want at 2am when
  an update went badly. (The artifact itself is not byte-identical; it carries
  a fresh build timestamp.)
- `<name>.versions` — human-readable, what shipped.
- `builds.log` — one append-only line per build.

The same `images.pinned` ships either way, inside the
`chirpstack-images-*.tar.gz` payload. `--records` just extracts a copy
somewhere durable so you don't have to unpack the artifact to roll back.

---

## 5. Check what you built before handing it over

```bash
cd artifacts
tar tf airgap-noble-*.tar | head           # the folder is in there
tar xf airgap-noble-*.tar
cat airgap-noble-*/VERSIONS.txt            # what versions shipped
cat airgap-noble-*/AIRGAP_INFO             # codename, arch, mode, payloads
```

`AIRGAP_INFO` is the file the installer reads. `AIRGAP_CODENAME` and
`AIRGAP_ARCH` must match the target machine, or step 00 refuses to run.

**Secrets:** the builder excludes `.env`, certificates, `mqtt-users.conf` and
the generated broker files from the stack snapshot, then greps the finished
archive for them and *refuses to build* if any are found. You do not need to
check this by hand — but if a build fails with `refusing to build: the stack
snapshot contains secrets`, that guard did its job and something new needs
adding to the exclude list in `prepare-airgap.sh`.

---

## 6. Hand it off

Copy one file — the `.tar` in `artifacts/` — onto a USB stick, or `scp` it to
the server. Nothing else needs to travel with it; the instructions, the
checksums and the uninstaller are all inside.

Tell the person on site:

```bash
tar xf airgap-noble-cs4.11.0-20260908.tar
cd airgap-noble-cs4.11.0-20260908
sudo bash install.sh
```

and point them at [`installing-on-target.md`](installing-on-target.md).

Two options worth mentioning to them if either applies to the machine:

```bash
# the VM has a second drive -- puts the stack, Docker and Ignition all on it
sudo bash install.sh --install-root /data

# only part of the artifact is wanted on this box
sudo bash install.sh --only-ignition
sudo bash install.sh --no-ignition
```

The installer offers the data drive on its own if it finds one, so the first is
only needed when they declined it or mounted the drive afterwards.

> The artifact also carries an `install-all.sh` shim, because that was the name
> before 2026-09 and it is written down in older runbooks. It forwards to
> `install.sh` and prints a note.

---

## Build-time troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `docker daemon not reachable on THIS host` | The image bundler pulls through your local Docker | Start Docker, or `--skip-images` |
| `need dpkg-scanpackages ... or apt-ftparchive` | No tool to index the offline apt repo | `sudo apt install dpkg-dev` |
| `Docker has no '<codename>' suite` | Typo, or Docker doesn't publish for that release | The script lists the suites it found; pick one |
| `the Ignition bundle failed` | The vendor download resolver broke, or no internet | Download the `.run` from inductiveautomation.com by hand and pass `--ignition-run ./file.run`, or `--skip-ignition` |
| `refusing to build: the stack snapshot contains secrets` | A per-site file slipped past the exclude list | Do not override. Remove the file from `stack/`, or add it to the exclude list in `prepare-airgap.sh` |
| `<dir> does not look like the stack repo (no ...)` | `--stack-dir` points somewhere wrong | Point it at `stack/`, or `--skip-stack` if the target already has it |
| `--latest and --from-list are opposites` | You asked for both current and reproduced images | Pick one |
| `expected exactly one ... tarball, got N` | An inner bundler produced zero or more than one tarball in the staging directory | Read the bundler's own output above it — this is a symptom, not the cause |
| `survey has no usable SURVEY_CODENAME` | Truncated or hand-edited survey file | Re-run `target-survey.sh -o survey.txt` on the target |

Check the Ignition download resolver is still working without downloading
1.5 GB:

```bash
./ignition-bundle.sh --resolve-only
```

---

## Reference

- `os-provisioning/build/prepare-airgap.sh` — the one command; orchestrates the three bundlers
- `os-provisioning/build/docker-offline-bundle.sh` — Docker Engine offline apt repo
- `os-provisioning/build/chirpstack-image-bundle.sh` — container images
- `os-provisioning/build/ignition-bundle.sh` — the bare-metal Ignition gateway

Each is independently runnable and independently documented via `--help`.

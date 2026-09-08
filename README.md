# SiteSync Stack

A ChirpStack LoRaWAN network server packaged so the same deployment can be
repeated at every customer site, including sites with no internet connection.

The repository has two halves, and the split is the important thing about it:

```
stack/              Everything that ends up on a customer machine.
                    Installed to /opt/sitesync.
                    This directory, and only this directory, ships.

os-provisioning/
  build/            Runs on YOUR machine. Builds the offline install artifact.
                    Never leaves your laptop.
  target/           Runs on the CUSTOMER's machine. Copied into every artifact.
```

If you are wondering "does this run on my laptop or on the customer's VM?", the
path answers it.

## Where to start

- **Building an install artifact** →
  [`docs/building-the-bundle.md`](docs/building-the-bundle.md). Runs on your
  machine, with internet. The short version:

  ```bash
  os-provisioning/build/prepare-airgap.sh --latest
  ```

  Produces one file in `artifacts/` containing Docker Engine, the container
  images, the Ignition gateway installer, and a snapshot of `stack/`.

- **Installing it at a site** →
  [`docs/installing-on-target.md`](docs/installing-on-target.md). Written for a
  technician with no Linux background; covers the site questions and every
  error the installer can produce. The short version, on the target:

  ```bash
  sudo bash install-all.sh
  ```

- **Operating or configuring a site afterwards** →
  [`stack/README.md`](stack/README.md). That one ships to the machine.

## Why the stack lives in its own directory

The artifact is built by archiving `stack/`. Because that is a directory
boundary rather than a list of exclusions, there is no way for build tooling,
build output, or repository machinery to be shipped to a customer by accident.
Only per-site secrets are excluded by name — `.env`, certificates,
`mqtt-users.conf` and the generated broker files — and the bundler then searches
the finished archive for them and refuses to build if it finds any. The exclude
list is not trusted on its own.

Based on [chirpstack/chirpstack-docker](https://github.com/chirpstack/chirpstack-docker).

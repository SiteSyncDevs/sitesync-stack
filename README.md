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

- **Operating or configuring a site** → [`stack/README.md`](stack/README.md).
  That is the document a technician needs, and it ships to the machine.
- **Building an install artifact** →

  ```bash
  os-provisioning/build/prepare-airgap.sh --latest
  ```

  Produces one file in `artifacts/` containing Docker Engine, the container
  images, and a snapshot of `stack/`. Hand it over, and on the target:

  ```bash
  sudo bash install-all.sh
  ```

## Why the stack lives in its own directory

The artifact is built by archiving `stack/`. Because that is a directory
boundary rather than a list of exclusions, there is no way for build tooling,
build output, or repository machinery to be shipped to a customer by accident.
Only per-site secrets are excluded by name — `.env`, certificates,
`mqtt-users.conf` and the generated broker files — and the bundler then searches
the finished archive for them and refuses to build if it finds any. The exclude
list is not trusted on its own.

Based on [chirpstack/chirpstack-docker](https://github.com/chirpstack/chirpstack-docker).

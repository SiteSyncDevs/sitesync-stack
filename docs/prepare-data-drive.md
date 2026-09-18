# Preparing a data drive

Read this **before** `installing-on-target.md` if the server has a second,
blank drive that you want SiteSync installed on.

A drive attached to a VM is not usable straight away. It arrives like a new
external disk still in its box: the machine can see it, but it has no
filesystem, no name, and no folder to reach it through. Until you do the four
things below, Linux will not show it and the SiteSync installer will not offer
it.

You do not need to know Linux. Every command is written out.

> **About the placeholders.** Commands below contain `<ANGLE-BRACKET>`
> placeholders. Replace the whole thing, brackets included, with your real
> value. Nothing you paste should still have `<` or `>` in it.
>
> | Placeholder | Means | Example |
> |---|---|---|
> | `<DISK>` | The blank drive's name, no `/dev/` | `sdb` |
> | `<PARTITION>` | The partition you create on it, from Step 4 | `sdb1` |
> | `<BUNDLE>` | The unpacked installer folder in your home directory | `airgap-noble-cs4.11.0-20260908` |

---

## Do you actually need this?

Run this on the server:

```bash
lsblk
```

You will see something like:

```
NAME   SIZE TYPE MOUNTPOINTS
sda     40G disk
├─sda1   1G part /boot/efi
└─sda2  39G part /
sdb    500G disk
```

`sda` is the OS disk — its partitions have **mountpoints** (`/`, `/boot/efi`),
which means Linux is already using them.

`sdb` has a size but **no mountpoint and no partitions underneath it**. That is
an attached, unprepared drive. That is what this guide fixes.

**If every drive already has a mountpoint**, there is nothing to do here — go
to `installing-on-target.md`.

**If you see no second drive at all**, it was never attached to the VM. That is
a job for whoever manages the hypervisor (VMware, Proxmox, Hyper-V, the cloud
console), not something you can fix from inside the server.

---

## Before you start

You need:

- [ ] A terminal on the server, and an account that can use `sudo`
- [ ] To know **how big the data drive is supposed to be**. This is the only
      thing that tells you which drive is the right one. Ask before you start
      if you do not know.

Set aside **10 minutes**.

> **The data drive does not hold the installer.** The `.tar` file and the
> folder it unpacks into live in your home directory, which is on the **OS
> disk**, and they run from there. That does not change once the data drive
> exists.
>
> So the OS disk still needs room for both at once — the `.tar` plus a full
> unpacked copy of it, several gigabytes each. Check before you copy anything:
>
> ```bash
> df -h /
> ```
>
> A machine with a small OS disk and a large data drive can still run out of
> space here, and the installer's own space check will not catch it: that check
> looks at where the software is being **installed**, not at where the bundle
> is being unpacked. If `/` is tight, ask for a bigger OS disk before you
> start. You can delete the `.tar` and the unpacked folder once the install is
> finished and verified.

> ## Read this once before you type anything
>
> Step 4 **erases the drive you name, completely and permanently.** There is no
> undo, no recycle bin, and no "are you sure".
>
> Name the wrong drive and you destroy either the server's operating system or
> a customer's existing data. Both mean starting the whole machine again.
>
> This is the only dangerous part of installing SiteSync. Step 3 exists purely
> so you cannot get it wrong — do not skip it, even if the drive looks obvious.

---

## Step 1 — List the drives

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

This is the same command as before with more columns. Example:

```
NAME   SIZE TYPE FSTYPE MOUNTPOINT
sda     40G disk
├─sda1   1G part vfat   /boot/efi
└─sda2  39G part ext4   /
sdb    500G disk
```

The drive you want has **all** of these:

- `TYPE` is `disk`
- `FSTYPE` is **empty** — no filesystem on it yet
- `MOUNTPOINT` is **empty** — Linux is not using it
- nothing indented underneath it — no partitions
- the size matches what you were told to expect

In the example that is `sdb`, so `<DISK>` is `sdb` everywhere below.

> **On some VMs the name looks different.** A drive may be `vdb`, `nvme0n1`, or
> `xvdb` instead of `sdb`. The name does not matter — the five checks above do.
> Use whatever name your own output shows.

---

## Step 2 — Confirm nothing is using it

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT /dev/<DISK>
```

You want to see the drive and **nothing else** — no partitions, no filesystem,
no mountpoint:

```
NAME  SIZE FSTYPE MOUNTPOINT
sdb   500G
```

**Stop and ask for help if you see anything in the `FSTYPE` or `MOUNTPOINT`
columns.** That drive already holds something. On a re-install it is usually
the previous installation's data, and formatting it throws that away.

---

## Step 3 — Prove it is not the OS disk

Do this even though Step 1 and 2 looked fine. It takes five seconds and it is
the check that catches the mistake that cannot be undone.

```bash
lsblk -nso NAME "$(findmnt -no SOURCE /)" | tail -1
```

That prints the name of the drive the operating system is running from — for
example `sda`. It follows the OS back to the physical drive it sits on, so it
gives the right answer even on a server built with LVM, where the obvious
commands report a partition or a volume name instead.

**If it prints the same name as your `<DISK>`, stop.** You picked the OS disk.
Go back to Step 1.

If it prints a different name, you have the right drive. Continue.

---

## Step 4 — Partition and format it

Two commands. The first divides the drive up; the second puts a filesystem on
it, which is what actually makes it usable.

**This erases `/dev/<DISK>`.** Read the name in your command out loud against
what Step 3 printed before you press Enter.

```bash
sudo parted /dev/<DISK> --script mklabel gpt mkpart data ext4 0% 100%
```

> The word `ext4` in that line is only a label written into the partition
> table. It does not format anything — that is the next command.

Now find out what the new partition is called:

```bash
lsblk -o NAME,SIZE,TYPE /dev/<DISK>
```

```
NAME   SIZE TYPE
sdb    500G disk
└─sdb1 500G part
```

The indented `part` line is your `<PARTITION>` — `sdb1` here.

> **Do not guess this name.** It is usually the drive name with `1` on the end,
> but NVMe drives insert a `p`: `nvme0n1` becomes `nvme0n1p1`, not `nvme0n11`.
> Read it from the output above.

Format it:

```bash
sudo mkfs.ext4 -L sitesync-data /dev/<PARTITION>
```

It prints a few lines and finishes in a second or two. `ext4` is the ordinary
Linux filesystem and is what SiteSync expects.

---

## Step 5 — Mount it at /data

"Mounting" attaches the drive to a folder. From then on, anything written to
that folder goes on the drive.

```bash
sudo mkdir -p /data
sudo mount /dev/<PARTITION> /data
```

Check it:

```bash
df -h /data
```

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdb1       492G   28K  467G   1% /data
```

The `Mounted on` column must say `/data`, and the size must be the drive's
size. If it says `/` instead, the mount did not happen — the drive is not
attached and you would be installing onto the OS disk without knowing.

---

## Step 6 — Make it come back after a reboot

**Do not skip this.** Step 5 mounts the drive *until the next reboot*. Nothing
so far tells the server to mount it again at startup.

Skip this step and the install will work perfectly today. Then the customer
reboots the server, the drive does not come back, and **Docker refuses to
start** — the SiteSync install is configured to stop rather than quietly write
to an empty folder on the OS disk. The site is down, and the cause is a step
that was missed weeks earlier.

Get the drive's permanent ID:

```bash
sudo blkid -s UUID -o value /dev/<PARTITION>
```

It prints a long string like `4f9a2b7c-1d3e-4a5b-8c6d-9e0f1a2b3c4d`. This is
the drive's own identity. Use it rather than `/dev/sdb1`, because device names
can change between boots — a drive that is `sdb` today can be `sdc` after
hardware is added, and the server would mount the wrong thing or nothing.

Add the line, substituting the UUID the command just printed:

```bash
echo "UUID=<THE-UUID-FROM-ABOVE> /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

> `nofail` means "if this drive is missing at boot, carry on anyway". Without
> it, a failed drive leaves the server stuck at a rescue prompt that needs
> someone at the keyboard — on a machine in a locked cabinet, that is an
> engineer visit. With it, the server boots and you can log in and investigate.

Test that the line is correct **now**, while you are still here:

```bash
sudo umount /data && sudo mount -a && df -h /data
```

That unmounts the drive and re-mounts it using only what you wrote in
`/etc/fstab`. If `df` still shows `/data` with the right size, the line works
and the drive will return after a reboot.

> **If `mount -a` prints an error, fix it before going any further.** A bad
> `/etc/fstab` is the one thing here that can stop a server booting properly.
> Re-check the UUID against `blkid`, then run `sudo mount -a` again until it is
> silent.

---

## Step 7 — Check it before you install

```bash
findmnt /data
```

If that prints a line, the drive is mounted and the installer will find it.

Now run the install. The installer runs from your **home directory**, not from
the data drive — that is correct and does not need changing:

```bash
cd ~/<BUNDLE>
sudo bash install.sh
```

> **Do not move the bundle onto `/data`.** It is meant to run where it was
> unpacked. The data drive is for the software the installer *puts down*
> (`/data/sitesync`, `/data/docker`, `/data/ignition`), not for the installer
> itself.

Near the very start it will offer:

```
   This machine has a second drive:

     /data                        467 GB free

   Install everything on /data? [Y/n]:
```

**Press Enter.** That is the whole point of what you just did. Continue with
`installing-on-target.md` from there.

> **If the installer does not offer the drive**, it did not see a mounted
> filesystem with at least 10 GB free. Run `df -h /data` again — almost always
> the mount silently came undone, or `/data` was created but never mounted.

---

## If something goes wrong

| Message | What it means | What to do |
|---|---|---|
| `Device or resource busy` on `parted` or `mkfs` | Something is using the drive — it is mounted, or it is the wrong drive | Run `lsblk` again. If it has a mountpoint, it is **not** a blank drive. Go back to Step 2. |
| `Partition(s) ... are being used` | Same as above | Do not force it. Re-check with Step 3. |
| `mkfs.ext4: No such file or directory` | The partition name is wrong | You probably guessed it. Read it from `lsblk -o NAME,SIZE,TYPE /dev/<DISK>` as in Step 4. |
| `mount: /data: special device ... does not exist` | The UUID in `/etc/fstab` is wrong or mistyped | `sudo blkid -s UUID -o value /dev/<PARTITION>`, then fix the line with `sudo nano /etc/fstab`. |
| `wrong fs type, bad option, bad superblock` | The partition was never formatted | Run the `mkfs.ext4` command from Step 4. |
| `df -h /data` shows `/` as the filesystem | The drive is not mounted; you are looking at a plain folder on the OS disk | `sudo mount -a`, then check again. Do not install until this is right. |
| Installer says `only NNNN MB free on /var/lib` | It is installing to the OS disk, not the data drive | The drive is not mounted, or you answered `n` to the offer. Check `findmnt /data`, then re-run with `sudo bash install.sh --install-root /data`. |

### If the server has already been installed onto the OS disk

You do not have to redo the install to move it. Prepare the drive as above,
then see *"Not enough disk space"* in `installing-on-target.md` — the installer
takes `--install-root /data` and `--resume`.

---

## What this looked like, start to finish

For a drive that turned out to be `sdb`, with partition `sdb1`:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT      # find it
lsblk -no PKNAME "$(findmnt -no SOURCE /)"      # prove it is not the OS disk
sudo parted /dev/sdb --script mklabel gpt mkpart data ext4 0% 100%
sudo mkfs.ext4 -L sitesync-data /dev/sdb1
sudo mkdir -p /data
sudo mount /dev/sdb1 /data
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdb1) /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo umount /data && sudo mount -a && df -h /data
```

Use it to check your own work, not to paste — `sdb` and `sdb1` are from the
example, and on your server they may be something else entirely.

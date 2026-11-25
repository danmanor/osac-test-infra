# VAST-over-SNAT lab spike — 2026-11-24

Throwaway spike on `rdu-infra-edge-06.ecosys.eng.rdu2.dc.redhat.com`, following the
design in `docs/superpowers/specs/2026-11-24-lab-vast-storage-snat-design.md`.
The role in `infra/netris/roles/lab_vast_storage` is written from this record.

## Host

| Item | Value |
|---|---|
| Host | `rdu-infra-edge-06` |
| Cores | 80 |
| Memory total / available | 385045 MiB / 240013 MiB (measured 2026-11-24) |
| Free on `/` | 2.5 TiB |
| `h03` | shut off (kept off) |
| Netris subnets | `192.168.124.0/24` absent from the controller's subnet and V-Net lists |

### Data bridge

`br-vast` created with NetworkManager: `192.168.124.1/24`, `bridge.stp no`,
`ipv6.method disabled`.

Ruling: the base image lives in the libvirt image directory, not `/home/test/cache`, because libvirt runs qemu as uid 107 and cannot traverse the 0700 home. A staging copy under `/home/test` is fine only until it is moved.

Note: a portless Linux bridge reports `DOWN` in `ip -br addr` even with the
address configured. The address is what matters; the link comes up when the
guest tap is attached. Verification after the VM is defined checks the tap.

## Image

| Item | Value |
|---|---|
| Source | developer machine `/home/dmanor/Downloads/vast_5_4.qcow2` |
| Destination | `/var/lib/libvirt/images/vast/vast_5_4.qcow2` (libvirt image dir; qemu cannot read `/home/test`, which is 0700) |
| Virtual size | 1 TiB |
| File size | 23.2 GiB |
| sha256 | `be2cbdab375760873aa50d2e6a8aca16cf61bc2f4453605b15b4a35ed0186dd7` |

### Install (guest) — what the base image does not do

`install.sh` assumes docker is already installed, the appliance's resolv.conf
points at VAST-internal resolvers, and its own bootstrap copies `vman.sh` into
`/vast/deploy` only on the happy path. The working sequence:

1. `dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo`
   and `dnf -y install docker-ce docker-ce-cli containerd.io`; set
   `ip_resolve=4` in `/etc/dnf/dnf.conf` (the AAAA answers hang dnf here) and
   point resolv.conf at the lab resolvers.
2. `systemctl enable --now docker`, `usermod -aG docker centos`, then
   `sg docker -c 'cd /home/centos && ./install.sh'` (30–40 minutes: image
   import into `127.0.0.1:5000`, VMS start).
3. `install.sh` ends with a cluster create that fails (`./vman.sh: No such file
   or directory`). Copy `vman.sh` from
   `/vast/bundles/upgrades/2209349/vman.sh` to `/vast/deploy`.
4. The image's nginx has an **empty listen block** (r212 §6). Set
   `listen 192.168.16.60:80/443` between the `# Addresses start/end` markers
   with `docker exec -u root vast_vms python3`, then `nginx -t` and start it.
   After a `vman stop`, `docker restart vast_vms` leaves every supervised
   service STOPPED; `docker exec -u root vast_vms supervisorctl start all`
   brings the API back (HTTP 200).
5. Create the loopback cluster:
   `cd /vast/deploy && sg docker -c "./vman.sh release-5-4-1-sp3-2209349
   /vast/deploy/ssh_key.pem vcli -u admin -p 123456 -c cluster create
   --build release-5-4-1-sp3-2209349 --vsettings
   CAS_OVER_RPC=true,IN_CLUSTER_COMMUNICATION_TCP=true
   --name lb-release-5-4-1-sp3-2209349 --loopback"`.
   Success is state `ONLINE` from the API, not the UI.

## VAST object commands

_(filled by Task 4)_

## Cluster bring-up

### Boot disk: the initramfs trap

The appliance image ships a VMware OVA initramfs with no `virtio_blk` (and no
`ahci`), so a virtio or SATA disk drops the guest into dracut emergency mode:
`/dev/disk/by-uuid/9914d65e-... does not exist`. IDE boots, because
`ata_piix` is built into the kernel.

The fix is applied **offline**, before the first virtio boot, not through an
IDE boot and guest SSH:

1. `qemu-nbd -c /dev/nbd0 --format=qcow2 <overlay>`; mount `/dev/nbd0p3` on
   `/mnt/vastroot` (the 1 TiB disk is `p1` 1G `/boot`, `p2` 820M swap,
   `p3` xfs `/`).
2. `echo 'add_drivers+=" virtio_blk virtio_net "' > /etc/dracut.conf.d/90-virtio.conf`
   inside the mount, then `chroot /mnt/vastroot dracut --regenerate-all --force`.
   `virtio_pci` is built into the kernel; asking dracut to install it fails the
   build, so it is deliberately omitted.
3. Write the static `ifcfg-eth0`/`ifcfg-eth1`, `route-eth1`, and the ARP/
   rp_filter sysctl file; `restorecon` them (`net_conf_t`).
4. Unmount, `qemu-nbd -d /dev/nbd0`, define the domain with virtio, boot.

The role must do this on a fresh overlay and keep a host-side
`<overlay>.prepared` marker so a redeploy does not repeat it.

### Guest network

| NIC | Address | Route |
|---|---|---|
| `eth0` | `192.168.16.60/20`, gw `192.168.16.1` | default |
| `eth1` | `192.168.124.11/24` | `198.51.100.0/24 via 192.168.124.1 dev eth1` |

`sudo -n` works for `centos`; the lab key is `/root/.ssh/lab-vast`.

## SNAT evidence

_(filled by Task 5)_

## Hub path

_(filled by Task 5)_

## Sizing and the management DB (after the first ONLINE)

- The platform busy-polls: at 16 vCPU `qemu-kvm` held ~13.4 cores, the guest
  load was ~75, and only a few threads did real work. The 1 TiB loopback format
  and the management-DB copy were CPU-bound, not disk-bound (host raw write
  914 MB/s, guest-visible writes < 1 MB/s).
- At **32 vCPU** ACTIVATING fell from ~66 to ~52 min, CNODE module format from
  ~66 to ~29 min, and the management-DB `pg_basebackup` from ~0.5 to ~3 MB/min
  (finished in ~35 min for 133 MB). Keep 128 GiB; memory is the host constraint.
- The VMS rejects writes (`VMS is degraded. reason: UPDATING_CLUSTERED_DB`)
  until that copy finishes and replication is streaming. Do not restart Docker
  or the VMS services during the copy: that is what lost the cluster record in
  the first attempt, and `post_start` + `disable_mgmt_ha` made it worse.
- Clean sequence that works: `start --with-db-cleanup` and wait for it to exit,
  create the cluster, wait for ONLINE, wait for the DB copy and streaming, then
  create objects. The role implements this order.

## Time budget (for the post-run brainstorm)

Measured on this host, one clean deploy:

| Phase | 16 vCPU | 32 vCPU | Notes |
|---|---|---|---|
| Image copy from a laptop | ~1.5 h | — | one-time; 23 GiB over ~4 MB/s |
| Offline overlay prep + IDE boot | ~6 min | ~6 min | one-time per overlay |
| `install.sh` (unpack + image import + bootstrap) | ~40 min | ~40 min | docker install included |
| Cluster ACTIVATING (1 TiB loopback format) | ~66 min | ~52 min (CNODE 29) | CPU-bound, not disk-bound |
| Management-DB copy + replication catch-up | hours at 16 vCPU | ~35 min | CPU-bound NFS path |

Candidate levers, strongest first:

1. **Golden overlay snapshot** (the same idea as the lab's OCP SNO snapshot):
   deploy once, let it reach ONLINE with the DB copied, then keep that overlay
   as a golden image and give each deployment a copy-on-write overlay from it.
   That removes install + format + DB copy from every subsequent deploy, which
   is ~2 h of the current ~2.5 h.
2. Pre-install docker (and keep the registry populated) in the golden image so
   `install.sh`'s unpack/import is skipped.
3. If a fresh cluster identity is required per deploy, snapshot **after
   install but before `cluster create`**; every deploy then pays only the
   ACTIVATING cost, not the installer.
4. Reduce the loopback footprint (`loopback_conf.yml` dboxes: fewer/smaller
   SSD/NVRAM drives) if the platform accepts it — directly cuts the format.
5. Keep 32 vCPU (done) and add an iothread/multiqueue if the block path ever
   becomes the limiter.

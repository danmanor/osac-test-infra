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

## VAST object commands

_(filled by Task 4)_

## Cluster bring-up

_(filled by Tasks 2 and 3)_

## SNAT evidence

_(filled by Task 5)_

## Hub path

_(filled by Task 5)_

# Changelog

All notable changes to this project are documented here.

## [0.2.0] - 2026-09-24

### Added

- Cluster-wide governor capability discovery and intersection.
- Datacenter UI governor selectors limited to governors available on every
  CPU policy on every node.
- Clear prerequisite and no-common-governor messages in the UI.
- Intel P-state active/passive and Proxmox VE bootloader configuration guide.

### Changed

- Enabling a policy now fails closed for incomplete, stale, or incompatible
  node capability reports.
- Node-level available governors now represent the intersection across local
  CPU policies rather than their union.

## [0.1.0] - 2026-09-24

Initial public release.

### Added

- Cluster-wide policy stored in `/etc/pve/dc-powersave.cfg`.
- Node-local systemd controller with safe boot and workload protection.
- Runtime detection for guests, migrations, and Proxmox tasks.
- CPU governor selection through `cpupower` with capability verification.
- Authenticated Proxmox API endpoints and Datacenter → Power Management UI.
- Idempotent installer for Proxmox VE 8 and newer.
- Design documentation and Perl test coverage for policy and runtime behavior.

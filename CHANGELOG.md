# Changelog

All notable changes to this project are documented here.

## [0.2.1-beta.1] - 2026-10-07

### Fixed

- A concurrent read during a policy save could see an empty configuration
  file and silently report the node as disabled; saves now replace the file
  atomically.
- Losing a previously enabled shared configuration now stays an error instead
  of turning into `DISABLED` after one reconciliation.
- Rerunning the installer now restarts the controller and reloads the PVE API
  daemons, so upgrades take effect without a reboot.
- Overlapping status refreshes in the Power Management UI no longer duplicate
  node rows; all status columns are HTML-encoded.
- The design guide now shows the `cpupower` command the backend actually runs.

### Changed

- CI adds Perl coverage, Python helper tests, JavaScript syntax checks,
  SonarQube Cloud analysis and a guarded tag-based release workflow. Tags with
  a pre-release suffix are published as GitHub pre-releases.

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

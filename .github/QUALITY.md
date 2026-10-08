# Proxmox PowerSave CI and release checks

The required `quality` job runs on pushes to `main`, pull requests targeting
`main`, and manual dispatches. Repository permissions are read-only and all
third-party GitHub Actions are pinned to immutable commits.

## Core Perl validation

Perl remains the authoritative implementation language for the controller and
API modules. CI therefore uses Perl-native checks rather than relying on
SonarQube Cloud for unsupported Perl analysis:

- `prove -Ilib t` under Devel::Cover.
- Standalone compilation of `lib/PVE/DC/**` and `bin/pve-dc-powersave`.
- Perl::Critic bug-prevention and security policies from `.perlcriticrc`.
- A persisted text coverage report as a CI artifact. Statement coverage must remain at or above 80% (current measurement: 85.0%).

## Supporting code validation

- ShellCheck for `scripts/install.sh` and `scripts/uninstall.sh`.
- Python behavior tests for the Proxmox integration helper on Python 3.11 and
  Python 3.13, matching the supported Proxmox VE 8/9 generations.
- Python coverage exported as `coverage.xml`, with a 45% floor for the root-only integration helper (current measurement: 49%).
- JavaScript syntax validation for `web/dc-powersave.js`.
- Systemd unit validation in an isolated temporary filesystem.

## SonarQube Cloud

SonarQube Cloud CI analysis is enabled for the supported Python and JavaScript
sources. The Python coverage report is imported into Sonar. JavaScript remains
statically analyzed but is excluded from coverage until browser-level tests are
added. Perl quality and coverage stay authoritative in the native CI gate
because SonarQube Cloud does not provide a Perl analyzer.

## Releases

Pushing a `vX.Y.Z` tag (or a pre-release tag such as `vX.Y.Z-beta.1`) starts a
guarded release. The tag must match the first
semantic-version entry in `CHANGELOG.md`, and the tagged commit must already
be contained in `main`. The release workflow reruns the native tests and
validation, then creates a versioned source tarball and `SHA256SUMS` and
publishes them with generated GitHub release notes.

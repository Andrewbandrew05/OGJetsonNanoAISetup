# Python 3.9 Upgrade

Ubuntu 18.04 (Bionic) doesn't ship Python 3.9, and the deadsnakes PPA that
`wyoming-piper` used to rely on for it no longer publishes builds for
Bionic - there's no distro package left to grab. This script builds Python
3.9 from source instead, via `make altinstall`, so it lands at
`/usr/local/bin/python3.9` without touching the system's default `python3`
at all.

Idempotent - if `python3.9` is already on `PATH`, it skips the build
entirely. Safe to run standalone (`sudo ./python39_upgrade.sh`) or as part
of `setup.sh`, where it runs right after GUI removal so it's ready before
`wyoming-piperSetup/install-wyoming-piper.sh` needs it.

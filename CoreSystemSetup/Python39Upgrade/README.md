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

## Uninstalling

`sudo ./uninstall-python39.sh` (or via `uninstall.sh
--uninstallPython39`) - `make altinstall` has no `make uninstall` target
and the build directory is gone by the time you'd need this, so this
manually removes the known set of files it installed
(`/usr/local/bin/python3.9`/`pip3.9`/etc., `/usr/local/lib/python3.9`,
`/usr/local/include/python3.9*`, its pkgconfig file and man page). Never
touches `/usr/bin/python3`, the system default.

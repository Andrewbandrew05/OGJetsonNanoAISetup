# System Upgrade

Runs a routine `apt-get update && apt-get upgrade` to bring already-installed
packages up to date.

Deliberately uses `apt-get upgrade`, not `dist-upgrade`/`full-upgrade`:
plain `upgrade` only updates packages that are already installed, within
their current dependency constraints, and never removes a package or pulls
in a new one to satisfy a changed dependency chain. `dist-upgrade` can do
both of those things, which is exactly the kind of surprise cascade this
project has otherwise gone out of its way to avoid (see
`CoreSystemSetup/GuiRemoval`) - not worth the risk here for a routine
update step.

In `setup.sh`, this always runs right before Tailscale (if both are
selected), regardless of where either appears in the menu or which flags
were used - the idea being to bring the system fully up to date right
before the very last step. Safe to run standalone too:
`sudo ./system_upgrade.sh`.

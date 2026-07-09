# JTOP Installation

This script will install JTOP on your jetson nano. This is an incredibly helpful system monitoring tool that I highly recommend downloading.

Also adds the invoking user to the `jtop` group so you can run `jtop`
without `sudo` - log out/in (or reboot) for that group membership to take
effect, then just run `jtop`.

To remove it: `sudo ./uninstall-jtop.sh` (or via `uninstall.sh
--uninstallJtop`) - uninstalls the pip package and removes the user from
the `jtop` group.

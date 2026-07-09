# GUI Removal Tool

WARNING: Run this script over ssh or you'll end up with a nasty surprise when your gui disappears

By default, this script just switches the boot target to text console and
disables the display manager service - nothing gets uninstalled, so it's
fast and fully reversible.

Add `--purge-packages` if you also want to reclaim the disk space the
desktop stack uses by actually uninstalling it. This is slower and more
invasive, and removes packages one at a time via `dpkg --remove` rather
than `apt-get remove`/`autoremove` - `dpkg` has no dependency solver, so it
can never cascade into removing anything beyond the exact package matched;
if something else still depends on one, `dpkg` just refuses rather than
working around it. See the comments at the top of `jetson_nano_headless.sh`
for the full reasoning.

Tested against a JetPack image downloaded 2026-07-07: reliably removes a
good chunk of unused desktop packages on that image. No guarantee it
catches everything on every image variant (package names/versions can
differ across JetPack releases), but it is guaranteed not to remove
anything that would stop the board from booting - worst case is less disk
space reclaimed than ideal, never a broken system.

## Uninstalling

`sudo ./uninstall-gui-removal.sh` (or via `uninstall.sh --uninstallGui`) -
always switches the boot target back to `graphical.target` and re-enables
known display managers (`gdm3`, `gdm`, `lightdm`, `sddm`, `xdm`, `slim`,
`lxdm`) for next boot; it doesn't force-start the GUI in your current
session. If you used `--purge-packages`, it also finds the **oldest**
`/root/pkg_list_before_headless_*.txt` snapshot (the true pre-removal
baseline), diffs it against the packages currently installed, and offers
to reinstall exactly what's missing - not a fixed guess list, the actual
packages this specific run removed.

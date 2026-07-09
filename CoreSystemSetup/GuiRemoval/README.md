# GUI Removal Tool

WARNING: Run this script over ssh or you'll end up with a nasty surprise when your gui disappears

By default, this script just switches the boot target to text console and
disables the display manager service - nothing gets uninstalled, so it's
fast and fully reversible.

Add `--purge-packages` if you also want to reclaim the disk space the
desktop stack uses by actually uninstalling it. This is slower and more
invasive, so it simulates the removal first and refuses to touch anything
boot-critical (kernel, `nvidia-l4t-*`, `initramfs-tools`, etc.) - see the
comments at the top of `jetson_nano_headless.sh` for details.

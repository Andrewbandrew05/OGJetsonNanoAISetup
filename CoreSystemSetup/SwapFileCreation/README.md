# Swap File Creation
This script will create a 4GB swap file on the jetson nano to help protect against memory overflows. As I understand it, this swap file will rarely be used outside of initial model loading and code compilation.

Note: The stock jetson image already has some zram (fancy fast swap) set up, this is just extra insurance. The overall install footprint of this setup isn't that large so it doesn't hurt anything.

Idempotent - if `/swapfile` is already active, it does nothing; if it
exists but isn't active, it just re-activates it rather than recreating
it.

## Uninstalling

`sudo ./uninstall-swap.sh` (or via `uninstall.sh --uninstallSwap`) -
`swapoff`s and deletes `/swapfile`, and removes its line from `/etc/fstab`.

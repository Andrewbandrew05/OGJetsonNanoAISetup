# SSH Hardener
This script will disable password based ssh login, requiring you to use the secure SSH key you setup earlier in the setup process. I highly recommend doing this as it provides better security.

Safety net: it checks for an existing, non-empty `~/.ssh/authorized_keys`
for the invoking user *before* touching anything, and refuses to proceed if
none is found - otherwise disabling password auth would lock you out. Add
your key first (`ssh-copy-id user@nano-ip`), then run this. It also backs
up the original `sshd_config` (timestamped, in `/etc/ssh/`) and validates
the new config with `sshd -t` before restarting the service, restoring the
backup automatically if validation fails.

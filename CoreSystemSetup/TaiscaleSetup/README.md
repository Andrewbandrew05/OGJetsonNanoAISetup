# Tailscale Setup

Installs Tailscale, enables the `tailscaled` service, and then authenticates
the device. Highly recommended for all your SSH/Wyoming/server needs - it's
a secure, low-overhead way to reach the Nano without exposing anything on
your LAN or the internet directly.

By default this ends by running `tailscale up`, which prints a login URL
and **blocks until you open it in a browser and authenticate**. That's
intentional: in `setup.sh`, this always runs last, so it's meant to be the
one thing left on screen once everything else has finished unattended.

It waits for you to press Enter before actually generating that login URL.
The URL expires after a few minutes - if it's generated while nobody's
watching (very possible partway through a long unattended run), it goes
stale before anyone sees it. Pressing Enter is the "someone's actually here
now" signal, so the URL only gets created once you're ready to click it
right away.

Env vars to change that behavior:
- `TAILSCALE_AUTHKEY=tskey-...` - authenticate non-interactively with a
  pre-generated auth key instead of waiting on the login URL.
- `TAILSCALE_UP_ARGS="--ssh --advertise-exit-node"` - extra flags passed
  through to `tailscale up` (either mode).
- `TAILSCALE_SKIP_UP=1` - skip `tailscale up` entirely; just install and
  enable the service, and print the manual `sudo tailscale up` command to
  run later instead.

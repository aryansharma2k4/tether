# tether

A persistent terminal on my laptop, reachable from my phone, over any network.

Open a session from Termux, use it — files, reading, Claude Code — and have it
survive the phone changing networks, losing signal, sleeping, and being killed
by Android. The laptop travels; the session does not care.

---

## How it works

```
   Android phone                                        Laptop (CachyOS)
  ┌───────────────┐                                    ┌──────────────────┐
  │ Termux widget │                                    │  zellij "tether" │
  │      ↓        │                                    │        ↑         │
  │     mosh ─────┼──── UDP 60000-61000 ───────────────┼──→ mosh-server   │
  │      ↑        │      (session survives IP change)  │        ↑         │
  │     ssh ──────┼──── TCP 22, handshake only ────────┼──→ sshd          │
  └───────┬───────┘                                    └────────┬─────────┘
          │                                                     │
          └──────────── Tailscale (WireGuard) ──────────────────┘
                    direct if possible, DERP relay if not
                          traverses CGNAT either way
```

Four layers, each solving exactly one problem:

| Layer | Problem it solves |
|---|---|
| **Tailscale** | Reaching a laptop with no public IP, from behind CGNAT, on someone else's wifi. |
| **sshd, tailnet-bound** | Authentication — and *not* being visible on the local network. |
| **mosh** | The connection surviving IP changes, sleep, and dead zones. |
| **zellij** | The session surviving the connection ending entirely. |

The split between mosh and zellij is the part worth internalising: mosh keeps
the *connection* alive across network churn, zellij keeps the *session* alive
when the connection is gone for good. Neither substitutes for the other. Kill
Termux and mosh dies; the zellij session does not.

---

## Decided

Not up for revisiting. Recorded so the reasoning survives.

- **Tailscale** for transport. WireGuard mesh, works from behind CGNAT, no
  port forwarding, no public exposure, no VPS in the middle.
- **sshd bound to the tailnet interface only**, key-only auth, no root login.
  On public wifi there is no socket on that interface to find. Not filtered —
  absent.
- **mosh** for the connection. Predictive local echo makes a phone keyboard
  bearable, and the UDP protocol reconnects across IP changes without a
  handshake.
- **zellij** for persistence, one session named `tether`.
- **Widget attaches-or-creates** (`zellij attach -c tether`). No laptop-side
  daemon, no lingering user unit. The session is born on first connect and
  persists until the laptop reboots.
- **On AC the lid may close; on battery it still suspends.** A laptop that
  never sleeps in a bag is a dead battery and a hot chassis. Reachability on
  battery is not worth that trade.

---

## Layout

```
laptop/
  sshd/10-tether.conf                        key-only auth, tailnet-only bind
  logind/10-tether.conf                      awake on AC, suspends on battery
  systemd/sshd.service.d/
    10-tether-tailnet.conf                   the boot-order fix (see below)
  install.sh                                 the only thing you run as root
phone/setup.md                               Termux, keys, widget
docs/runbook.md                              connecting, and the debug ladder
```

Every file carries its reasoning in comments. The commit messages carry the
"why now" for anything not obvious from the diff.

---

## The one non-obvious failure mode

Binding sshd to the Tailscale address means sshd cannot start until that
address exists. At boot it races tailscaled and loses, `bind()` returns
`Cannot assign requested address`, and sshd exits.

The stock unit's `Restart=always` looks like it covers this. It does not: the
bind failure takes milliseconds, `RestartSec` defaults to 100ms, and systemd's
default rate limit is 5 starts per 10s. sshd exhausts its restart budget in
under a second and systemd marks the unit `failed` **permanently**. Tailscale
comes up ten seconds later, the address appears, `tailscale status` is green,
the host answers pings — and there is no sshd. You find out from the phone,
away from the laptop, and the fix needs the physical keyboard.

`laptop/systemd/sshd.service.d/10-tether-tailnet.conf` orders sshd after
tailscaled, waits for the address to actually land on the interface, and sets
`StartLimitIntervalSec=0` with `RestartSec=10s` so it retries forever rather
than giving up. Full detail in that file and in `docs/runbook.md` § 6.

---

## Install

**Order matters.** The phone's public key has to be on the laptop before the
installer runs, because the installer disables password authentication and
refuses to proceed without a usable `authorized_keys`.

1. Packages, at the laptop:

   ```sh
   sudo pacman -S --needed mosh zellij
   ```

2. Tailscale, at the laptop. **This needs a browser login — do it yourself:**

   ```sh
   sudo systemctl enable --now tailscaled
   sudo tailscale up
   ```

3. Phone side through step 4 of [`phone/setup.md`](phone/setup.md) — install
   Tailscale and Termux packages, generate a key, get the pubkey into
   `~/.ssh/authorized_keys` on the laptop.

4. Install the drop-ins:

   ```sh
   sudo ./laptop/install.sh
   ```

   It prints what it intends to do and waits for you to type `yes`. It
   validates the merged sshd config in a sandbox before touching `/etc`,
   reloads rather than restarts, and rolls back if anything goes wrong.

5. Enable sshd, at the keyboard:

   ```sh
   sudo systemctl enable --now sshd
   ```

6. Finish [`phone/setup.md`](phone/setup.md) — ssh config, mosh, widget.

7. Reboot once and confirm you can still get in. This is the real test of the
   ordering fix, and the cheapest time to find out is while standing next to
   the machine.

---

## Manual, on purpose

Things this repo will not do for you, and why:

- **`tailscale up`** — browser login. Cannot be scripted, should not be
  faked.
- **Installing packages** — `install.sh` detects what is missing and prints
  the pacman command rather than invoking a package manager on your behalf.
- **Firewall rules** — `ufw` is active here and will drop mosh's UDP range.
  The installer detects this and prints
  `sudo ufw allow in on tailscale0`. Editing someone's firewall is not a
  side effect an installer should have.
- **`systemctl enable --now sshd`** — starting a listener is a decision you
  make once you have confirmed key auth works, not something a script does
  while you are not looking.
- **`systemctl restart systemd-logind`** — logind has no `ExecReload`, and a
  restart can disturb a running Hyprland session. Do it at the keyboard, or
  let the next reboot apply it.
- **Restarting sshd, ever** — a restart drops every session including the one
  you would use to fix a bad config. `install.sh` only ever reloads. The unit
  override applies on the next boot.

---

## Safety rule

Any change to sshd config, forever:

> Keep the current session open. `sshd -t`. `systemctl reload sshd`. Open a
> **second** session and confirm it works. Only then close the first.

`install.sh` follows this and will roll back if a reload kills the daemon.
Follow it yourself for anything you change by hand.

---

## Known limits

- **On battery with the lid shut, the laptop is asleep and unreachable.**
  Deliberate. There is no wake-on-tailnet — a suspended machine has no
  network stack.
- **Both ends behind hard NAT** (symmetric, or carrier-grade on mobile data)
  means Tailscale stays on a DERP relay. It works; it is just slower. mosh
  hides this better than ssh would.
- **Idle-suspend has no AC/battery split in logind** — there is no
  `IdleActionExternalPower`. It is pinned to `ignore`, which is already the
  default. If you ever want idle-suspend on battery only, that needs a second
  component (hypridle with a power-source check), not a logind setting.
- **A captive portal** leaves Tailscale looking connected while nothing
  passes. Load any plain-HTTP page and see if you get redirected.
- **The zellij session does not survive a laptop reboot.** The next tap
  recreates it, empty.

# tether — runbook

## Connect

Tap the **tether** widget. That is the whole happy path.

Equivalently, from a Termux shell:

```sh
mosh tether -- zellij attach -c tether
```

Detach with `Ctrl-p d`. Do not type `exit` in the last pane — that destroys
the session rather than leaving it for next time.

Nothing needs doing when the network changes. mosh has no TCP connection to
lose; it will show `[mosh] Last contact N seconds ago` at the top of the
screen while it re-establishes and then carry on mid-keystroke.

---

## When it doesn't work

Work down this list in order. Each rung assumes the ones above it passed, and
they are ordered by how often they are the actual answer.

### 0. What does the failure look like?

The symptom narrows it before you run anything:

| Symptom | Start at |
|---|---|
| `mosh: Connecting...` then hangs forever | rung 4 (UDP) |
| `ssh: connect to host ... Connection refused` | rung 5 (sshd) |
| `ssh: connect to host ... No route to host` / timeout | rung 1 (tailnet) |
| `Could not resolve hostname` | rung 1 (MagicDNS) |
| `Permission denied (publickey)` | rung 6 (auth) |
| Connects, but painfully laggy | rung 3 (DERP relay) |
| Was fine, laptop went quiet, now unreachable | rung 2 (asleep) |

---

### 1. Is Tailscale up on both ends?

**Phone:** open the Tailscale app. It should say Connected and list the
laptop. Android drops the VPN more readily than you would like — battery
optimisation, a captive portal, or a reboot with always-on VPN not enabled.

**Laptop** (needs some access, so this is really a check for later):

```sh
tailscale status
systemctl is-active tailscaled
```

From the phone, the cheapest end-to-end test that skips ssh entirely:

```sh
ping <100.x.y.z>
```

If ping works and ssh does not, the transport is fine and the problem is on
rung 4 or 5. If ping fails, it is the tailnet.

**Captive portals.** Campus and hotel wifi will happily associate you and then
black-hole everything until you load their splash page. Tailscale will look
connected and nothing will pass. Open any plain-HTTP page in a browser and see
whether you get redirected. This is a common cause of "it worked yesterday".

---

### 2. Is the laptop actually awake?

A suspended laptop has no network stack. There is no wake-on-tailnet, and no
amount of debugging on the phone will fix it.

By design (`laptop/logind/10-tether.conf`):

- **On AC**, lid closed → stays up and reachable.
- **On battery**, lid closed → suspends. Deliberately.

So: is it plugged in? If it is in a bag on battery with the lid shut, it is
asleep and that is working as intended.

If it *is* on AC and still went to sleep, at the keyboard check what logind
thinks it is doing:

```sh
systemctl show systemd-logind -p HandleLidSwitch \
  -p HandleLidSwitchExternalPower -p IdleAction
```

Expect `ignore` for the ExternalPower one. If it still says `suspend`, the
drop-in is installed but not loaded — logind has no `ExecReload`, so it needs
`sudo systemctl restart systemd-logind` or a reboot.

Then check nothing is overriding it:

```sh
systemd-inhibit --list        # a handle-lid-switch lock beats logind entirely
journalctl -b -u systemd-logind | grep -i lid
journalctl -b -1 -n 30        # last lines before the previous boot ended
```

`systemctl status systemd-suspend` will also show when it last suspended.

---

### 3. Direct or relayed?

Tailscale prefers a direct peer-to-peer path and falls back to a DERP relay
when it cannot get one. Relayed works, but every keystroke round-trips through
Tailscale's infrastructure — noticeably laggy, and the usual explanation for
"connected but horrible".

From the laptop:

```sh
tailscale status
```

Read the last column for the phone's row:

- `direct 203.0.113.5:41641` — direct. Good.
- `relay "fra"` — going through the Frankfurt DERP. Working, just slower.
- `idle` — no traffic recently; not a fault.

Test a specific peer and watch which path it picks:

```sh
tailscale ping <peer>
```

It reports each attempt and will often show it starting on DERP and upgrading
to direct after a second or two. If it never upgrades, both ends are behind
NAT that will not cooperate — symmetric NAT, or carrier-grade NAT on mobile
data. Campus networks are frequently the culprit.

```sh
tailscale netcheck
```

Look at the NAT mapping lines and `PortMapping`. Hard NAT on both ends means
permanently relayed, and there is nothing to fix from here — it is not broken,
it is just slow. mosh tolerates this much better than ssh does, which is part
of why it is in the stack.

---

### 4. Is mosh's UDP getting through?

mosh handshakes over ssh and then speaks UDP on a port in **60000–61000**,
one port per session. A hang at `mosh: Connecting...` after ssh clearly works
is almost always this.

First prove ssh is fine, which isolates it:

```sh
ssh tether echo ok
```

If that prints `ok` and mosh hangs, it is UDP.

**The firewall is the usual answer.** `ufw` is active on this laptop. Check
for a rule covering the tailscale interface:

```sh
sudo ufw status verbose
```

If there is nothing for `tailscale0`, mosh's UDP is being dropped. The tailnet
is authenticated transport, so allowing it wholesale is reasonable:

```sh
sudo ufw allow in on tailscale0
```

Narrower if you prefer:

```sh
sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp
```

Then confirm a server actually spawns. On the laptop, while a connection
attempt is in flight:

```sh
pgrep -a mosh-server
ss -lunp | grep mosh
```

No `mosh-server` at all means it never got started — that is an ssh or PATH
problem, not UDP. A `mosh-server` that is listening while the client still
hangs means the UDP packets are being dropped between you and it.

Stale `mosh-server` processes accumulate from sessions that were never cleanly
closed. They are harmless but confusing when reading `pgrep` output; clear
them with `pkill -f mosh-server` once you are sure nothing live is attached.

---

### 5. Is sshd listening where you think?

```sh
sudo ss -lntp | grep sshd
```

Expect **exactly** the tailnet addresses:

```
LISTEN 0 128 100.x.y.z:22    0.0.0.0:*  users:(("sshd",...))
LISTEN 0 128 [fd7a:...]:22   [::]:*     users:(("sshd",...))
```

- **`0.0.0.0:22` in that list** — sshd is exposed on every interface,
  including whatever wifi you are on. The drop-in is not taking effect.
  `ListenAddress` is cumulative, so something else is *adding* that bind:

  ```sh
  grep -rn ListenAddress /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
  sudo sshd -T | grep -i listenaddress
  ```

- **Nothing listed at all** — see the next section.

Check the effective config rather than reading files, since OpenSSH's
first-value-wins ordering makes files misleading:

```sh
sudo sshd -T | grep -iE 'passwordauth|permitrootlogin|listenaddress|allowusers'
```

---

### 6. sshd is dead after a boot — the ordering trap

**The failure mode.** sshd is bound to the Tailscale address only. If it
starts before tailscale0 has that address, `bind()` fails with
`Cannot assign requested address` and sshd exits immediately. The stock unit's
`Restart=always` does *not* save you: the failure takes milliseconds, the
default `RestartSec` is 100ms, and systemd's default rate limit is 5 starts
per 10 seconds — so sshd burns through its entire restart budget in under a
second and systemd marks the unit `failed` permanently. Tailscale then comes
up, everything looks healthy, `tailscale status` is green, the host answers
pings, and there is no sshd.

`laptop/systemd/sshd.service.d/10-tether-tailnet.conf` is what prevents this:
it orders sshd after tailscaled, waits up to 90s for the address to actually
appear on the interface, and sets `StartLimitIntervalSec=0` with
`RestartSec=10s` so sshd retries forever instead of giving up.

**Diagnosing it** (at the keyboard, since by definition you cannot ssh in):

```sh
systemctl status sshd
journalctl -b -u sshd | grep -i 'bind\|address'
```

The tell is `Cannot assign requested address` followed by
`start request repeated too quickly`.

**Recovery:**

```sh
tailscale status                  # is the tailnet actually up?
sudo systemctl reset-failed sshd  # clear the rate-limit lockout
sudo systemctl start sshd
```

**Verify the override is loaded** — this is worth doing once after install,
because `daemon-reload` loads it but only a *start* applies it:

```sh
systemctl cat sshd | grep -A2 StartLimitIntervalSec
systemctl show sshd -p StartLimitIntervalSec -p RestartSec -p After
```

`StartLimitIntervalSec=0` and `RestartSec=10s` mean you are covered.

---

### 7. `Permission denied (publickey)`

Transport is fine; auth is not.

```sh
ssh -vvv tether 2>&1 | grep -iE 'offering|authentications that can continue'
```

On the laptop:

```sh
sudo journalctl -u sshd -n 50
ls -la ~/.ssh/                 # authorized_keys must be 600, ~/.ssh 700
ssh-keygen -l -f ~/.ssh/authorized_keys
```

sshd refuses keys from a group- or world-writable home directory and logs
`Authentication refused: bad ownership or modes`. That one catches everyone at
least once.

Also confirm the username matches `AllowUsers` in the drop-in — a user not
listed there is rejected regardless of key.

---

## Changing sshd config later

The rule that keeps this safe:

1. **Keep your current session open.** Every time.
2. `sudo sshd -t` — validate before doing anything.
3. `sudo systemctl reload sshd` — reload, never restart. A reload preserves
   existing sessions and leaves the old daemon running if the new config is
   rejected.
4. Open a **second** connection and confirm it works.
5. Only then close the first.

`laptop/install.sh` does all of this for you, including rolling back if the
reload kills the daemon. Follow the same sequence for anything you change by
hand.

Restarting sshd remotely is the one action that can strand you: it drops every
session including the one you would use to fix it, and if the new config is
bad there is nothing left to connect to. If a restart is genuinely needed —
the unit override changes are the only case here — do it at the keyboard or on
the next reboot.

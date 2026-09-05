# tether — phone side (Termux)

Manual steps. Nothing here is scripted, because most of it is one-time and a
couple of steps need a browser or the Android share sheet.

> **Order matters.** Do the key transfer (step 4) *before* running
> `laptop/install.sh`. That script disables password authentication and will
> refuse to run if the laptop has no `authorized_keys` — which is the correct
> behaviour, but it means the phone's key has to arrive first.

---

## 1. Tailscale (the Android app, not a Termux package)

Install **Tailscale** from Play Store or F-Droid and sign in to the same
tailnet as the laptop. It runs as an Android system VPN, so Termux traffic
goes through it with no Termux-side configuration at all — there is no
`pkg install tailscale`, and you do not need one.

Confirm the laptop appears in the app's machine list before continuing.
Note its MagicDNS name and `100.x` address; both are used below.

Android will ask to allow a VPN connection. Accept it, and turn on
**Settings → Run as VPN → always-on** if you want the tailnet up without
opening the app.

---

## 2. Packages

```sh
pkg update
pkg install openssh mosh termux-api
```

- `openssh` — key generation and the ssh transport mosh handshakes over.
- `mosh` — the client.
- `termux-api` — optional, used below for `termux-clipboard-set`. Needs the
  **Termux:API** app installed too.

**Termux:Widget** is a separate APK, not a package. Install it from the same
source as Termux itself — F-Droid *or* GitHub releases, never a mix. Termux
add-ons must be signed with the same key as the base app or Android refuses
to let them talk to each other, and the failure looks like the widget simply
listing nothing.

---

## 3. Key

```sh
ssh-keygen -t ed25519 -C "termux@phone" -f ~/.ssh/id_ed25519
```

Use a passphrase or not — your call. A passphrase on a phone key is
defensible (the device is the thing most likely to be lost) but you will type
it on a soft keyboard on every reconnect, and mosh reconnects do *not*
re-handshake ssh, so it is once per session rather than once per network
change. `ssh-agent` in Termux does not survive the app being killed.

---

## 4. Get the pubkey onto the laptop

```sh
cat ~/.ssh/id_ed25519.pub
```

`ssh-copy-id` is not available to you yet — sshd on the laptop is not
listening, and once it is, password auth is off. So this is a one-time
out-of-band transfer. Pick one:

**Taildrop** (cleanest). Termux → share `id_ed25519.pub` (or use the
Tailscale app's share sheet) → send to the laptop. It lands in the laptop's
Taildrop directory. Requires Taildrop enabled for the tailnet.

**Clipboard.** `termux-clipboard-set < ~/.ssh/id_ed25519.pub`, then paste
into whatever channel you already have open on both devices.

**Type it.** It is one line of about 100 characters. Faster than debugging a
transfer method.

Then, **at the laptop**:

```sh
install -d -m 700 ~/.ssh
cat >> ~/.ssh/authorized_keys   # paste the line, then Ctrl-D
chmod 600 ~/.ssh/authorized_keys
ssh-keygen -l -f ~/.ssh/authorized_keys   # sanity check
```

Now run `laptop/install.sh`.

---

## 5. ssh config on the phone

`~/.ssh/config`:

```
Host tether
    HostName        <magicdns-name-or-100.x.y.z>
    User            aryan
    IdentityFile    ~/.ssh/id_ed25519
    IdentitiesOnly  yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

```sh
chmod 600 ~/.ssh/config
```

Prefer the MagicDNS name if MagicDNS is on; prefer the `100.x` literal if you
want connections to work even when DNS is being interfered with by whatever
captive-portal resolver the local wifi has forced on you. The literal is
stable for the life of the node.

Verify plain ssh works before involving mosh — it isolates auth problems from
transport problems:

```sh
ssh tether
```

---

## 6. mosh

```sh
mosh tether -- zellij attach -c tether
```

- `mosh` opens an ssh connection only to start `mosh-server` on the far end,
  then drops it and speaks its own UDP protocol. That is why the session
  survives changing networks, losing signal, and the phone sleeping — there
  is no TCP connection left to break.
- `zellij attach -c tether` attaches to the session named `tether`, creating
  it if it does not exist. First run creates it; every run after that lands
  back exactly where you left off.

If mosh exits complaining about the locale, Termux's environment did not
carry a UTF-8 locale across:

```sh
mosh --server="LANG=C.UTF-8 mosh-server" tether -- zellij attach -c tether
```

---

## 7. One-tap widget

Termux:Widget runs scripts from `~/.shortcuts`.

```sh
mkdir -p ~/.shortcuts
cat > ~/.shortcuts/tether <<'SH'
#!/data/data/com.termux/files/usr/bin/bash
# Keep Android from freezing Termux the moment the screen goes off. Without
# this the mosh client gets suspended and the session appears to hang on
# resume until the UDP flow re-establishes.
termux-wake-lock
trap 'termux-wake-unlock' EXIT

exec mosh tether -- zellij attach -c tether
SH
chmod +x ~/.shortcuts/tether
chmod 700 ~/.shortcuts
```

Then long-press the home screen → Widgets → **Termux:Widget** → drop it
somewhere → pick `tether`.

`termux-wake-lock` needs no special permission but does put a persistent
notification up while held. That notification is also the fastest way to
tell whether Termux is actually still alive in the background.

---

## 8. Making the terminal usable on a phone

`~/.termux/termux.properties`:

```
extra-keys = [ \
 ['ESC','/','-','HOME','UP','END','PGUP'], \
 ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN'] \
]
```

`termux-reload-settings` to apply.

Ctrl and Esc are the two you cannot work without — zellij's default modifier
is Ctrl, and Claude Code wants Esc. Volume-down doubles as Ctrl if you prefer
it to the on-screen row.

Worth knowing for zellij on a small screen:

- `Ctrl-p d` — detach. **Detach, do not exit.** Detaching is what leaves the
  session running for the next tap; `exit` in the last pane destroys it.
- `Ctrl-p n` / `Ctrl-t n` — new pane / new tab.
- `Ctrl-o w` — session manager.

The session survives you killing Termux, losing the network, and the phone
rebooting. It does not survive the laptop rebooting, or the laptop
suspending on battery with the lid shut — see `laptop/logind/10-tether.conf`
for why that is deliberate.

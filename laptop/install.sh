#!/usr/bin/env bash
#
# tether -- install the laptop-side drop-ins.
#
# Design rule, from which everything else follows: THIS SCRIPT MUST NEVER
# LOCK YOU OUT. Concretely that means
#
#   * every check that could indicate a lockout runs BEFORE anything is
#     written, and aborts rather than warns;
#   * the new sshd config is validated in a throwaway sandbox before it is
#     allowed anywhere near /etc;
#   * sshd is RELOADED, never restarted -- a reload keeps existing sessions
#     alive and, on failure, leaves the old daemon running;
#   * every file replaced is backed up, and any failure after the first
#     write rolls the whole set back and revalidates;
#   * it refuses to disable password auth unless a usable authorized_keys
#     already exists.
#
# It does not install packages, does not touch the firewall, does not run
# `tailscale up`, and does not restart sshd or logind. Where one of those is
# needed it tells you the exact command and stops.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/tether/${STAMP}"

SSHD_SRC="${REPO_DIR}/laptop/sshd/10-tether.conf"
SSHD_DST="/etc/ssh/sshd_config.d/10-tether.conf"
LOGIND_SRC="${REPO_DIR}/laptop/logind/10-tether.conf"
LOGIND_DST="/etc/systemd/logind.conf.d/10-tether.conf"
UNIT_SRC="${REPO_DIR}/laptop/systemd/sshd.service.d/10-tether-tailnet.conf"
UNIT_DST="/etc/systemd/system/sshd.service.d/10-tether-tailnet.conf"

WORK=""
INSTALLED=()   # files written this run, for rollback

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s==>%s %s%s%s\n' "$C" "$N" "$B" "$*" "$N"; }
ok()    { printf '  %s[ ok ]%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s[warn]%s %s\n' "$Y" "$N" "$*"; }
fail()  { printf '  %s[fail]%s %s\n' "$R" "$N" "$*"; }
die()   { printf '\n%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

cleanup() { if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi; }
trap cleanup EXIT

# Restore every file this run replaced, then prove sshd's config is sane
# again. Called only on a failure that happens after the first write.
rollback() {
  fail "rolling back"
  local dst base
  for dst in "${INSTALLED[@]:-}"; do
    [[ -n "$dst" ]] || continue
    base="$(basename "$dst")"
    if [[ -f "${BACKUP_DIR}/${base}" ]]; then
      cp -a -- "${BACKUP_DIR}/${base}" "$dst" && info "  restored ${dst}"
    else
      rm -f -- "$dst" && info "  removed  ${dst} (did not exist before)"
    fi
  done
  if sshd -t 2>/dev/null; then
    ok "sshd config valid again after rollback"
  else
    fail "sshd config STILL invalid after rollback -- do not close any open session"
    sshd -t || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# 0. must be root
# --------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "must run as root: sudo ${BASH_SOURCE[0]}"

# The account that will actually log in. Single source of truth is the
# AllowUsers line in the sshd drop-in, so the two can never drift.
TETHER_USER="$(awk '/^[[:space:]]*AllowUsers[[:space:]]/ {print $2; exit}' "$SSHD_SRC" || true)"
[[ -n "$TETHER_USER" ]] || die "could not read AllowUsers from ${SSHD_SRC}"

printf '\n%s tether -- laptop installer %s\n\n' "${B}" "${N}"

# ==========================================================================
# PREFLIGHT -- nothing is written until every one of these passes
# ==========================================================================
step "Preflight"

for f in "$SSHD_SRC" "$LOGIND_SRC" "$UNIT_SRC"; do
  [[ -f "$f" ]] || die "missing repo file: $f"
done
ok "repo files present"

for c in sshd tailscale ip systemctl ss; do
  command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done
ok "required commands present"

# mosh and zellij are not needed to install these configs, but they are the
# whole point of the setup, and finding out they are missing from the phone
# on a train is worse than finding out here.
missing=()
for c in mosh-server zellij; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if (( ${#missing[@]} )); then
  fail "missing: ${missing[*]}"
  die "install them first, then re-run:

    sudo pacman -S --needed mosh zellij"
fi
ok "mosh-server and zellij present"

# --- the account must be able to get in by key -----------------------------
# This is the lockout guard. Password auth is about to be turned off; if
# there is no usable key on disk, that is a one-way door.
USER_HOME="$(getent passwd "$TETHER_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "no home directory for user '${TETHER_USER}'"
AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"

if [[ ! -s "$AUTH_KEYS" ]]; then
  fail "no usable ${AUTH_KEYS}"
  die "This config disables password authentication. Installing it with no
authorized key would lock you out of ssh entirely.

Put the PHONE's public key there first (see phone/setup.md), verify you
can log in with it, and only then re-run this script."
fi
KEY_COUNT="$(grep -cvE '^\s*(#|$)' "$AUTH_KEYS" || true)"
(( KEY_COUNT > 0 )) || die "${AUTH_KEYS} contains no key lines"
ok "${AUTH_KEYS}: ${KEY_COUNT} key(s)"

# ssh-keygen -l is the real test of whether sshd will accept the file.
if ! ssh-keygen -l -f "$AUTH_KEYS" >/dev/null 2>&1; then
  die "${AUTH_KEYS} is not parseable as a public key file"
fi
ok "authorized_keys parses as valid public keys"

# --- tailnet must be up, or there is no address to bind --------------------
if ! systemctl is-active --quiet tailscaled; then
  die "tailscaled is not running.

Start it and authenticate (this opens a browser, so do it yourself):

    sudo systemctl enable --now tailscaled
    sudo tailscale up

then re-run this script."
fi

TS4="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
TS6="$(tailscale ip -6 2>/dev/null | head -n1 || true)"
[[ -n "$TS4" ]] || die "tailscale has no IPv4 address -- run 'sudo tailscale up' (browser login) first"
[[ -n "$TS6" ]] || die "tailscale has no IPv6 address -- unexpected; check 'tailscale status'"

# tailscaled knowing the address is not the same as the kernel having
# assigned it, and bind(2) only cares about the latter.
ip -o -4 addr show dev tailscale0 2>/dev/null | grep -qF "$TS4" \
  || die "${TS4} is not assigned to tailscale0 -- the interface is not up yet"
ok "tailnet address: ${TS4} / ${TS6} (present on tailscale0)"

# --- ufw would silently eat mosh ------------------------------------------
UFW_NOTE=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ufw status 2>/dev/null | grep -q 'tailscale0'; then
    ok "ufw is active and has a tailscale0 rule"
  else
    UFW_NOTE=1
    warn "ufw is ACTIVE with no tailscale0 rule -- mosh's UDP will be dropped"
  fi
fi

# ==========================================================================
# RENDER + VALIDATE IN A SANDBOX -- still nothing written to /etc
# ==========================================================================
step "Render and validate (sandbox, nothing touched in /etc yet)"

WORK="$(mktemp -d /tmp/tether-install.XXXXXX)"
chmod 0755 "$WORK"
RENDERED="${WORK}/10-tether.conf"

sed -e "s|__TAILSCALE_IPV4__|${TS4}|g" \
    -e "s|__TAILSCALE_IPV6__|${TS6}|g" \
    "$SSHD_SRC" > "$RENDERED"

if grep -qE '__TAILSCALE_IPV[46]__' "$RENDERED"; then
  die "unsubstituted placeholder left in rendered config"
fi
ok "rendered ${SSHD_SRC##*/} with the live tailnet addresses"

# Build a complete throwaway sshd config: the real one, with its Include
# repointed at a directory holding the real drop-ins plus ours. This is what
# lets `sshd -t` judge the FINAL merged config before /etc is modified.
SANDBOX_D="${WORK}/sshd_config.d"
mkdir -p "$SANDBOX_D"
shopt -s nullglob
for f in /etc/ssh/sshd_config.d/*.conf; do
  # ours supersedes any existing copy
  if [[ "$(basename "$f")" == "10-tether.conf" ]]; then continue; fi
  cp -aL -- "$f" "$SANDBOX_D/"
done
shopt -u nullglob
cp -- "$RENDERED" "${SANDBOX_D}/10-tether.conf"

SANDBOX_CONF="${WORK}/sshd_config"
sed -e "s|^\([[:space:]]*[Ii]nclude[[:space:]]\+\).*sshd_config\.d.*|\1${SANDBOX_D}/*.conf|" \
    /etc/ssh/sshd_config > "$SANDBOX_CONF"
grep -qF "$SANDBOX_D" "$SANDBOX_CONF" \
  || die "could not repoint the Include in the sandbox config -- refusing to guess"

# --- syntax ---------------------------------------------------------------
if ! sshd -t -f "$SANDBOX_CONF"; then
  die "the merged config is INVALID. Nothing has been changed."
fi
ok "sshd -t: merged config is syntactically valid"

# --- effective values -----------------------------------------------------
# Ordering rules make it easy to write a drop-in that parses fine and does
# nothing. Do not trust the ordering; assert what sshd will actually do.
EFF="$(sshd -T -f "$SANDBOX_CONF" 2>/dev/null)" || die "sshd -T failed on the merged config"

assert_eff() { # key expected
  local got; got="$(grep -i "^$1 " <<<"$EFF" | head -n1 | awk '{print $2}')"
  if [[ "${got,,}" == "${2,,}" ]]; then
    ok "effective $1 = $got"
  else
    fail "effective $1 = ${got:-<unset>} (expected $2)"
    die "the drop-in is being overridden by another file -- check the lexical
order of /etc/ssh/sshd_config.d/*.conf and whether the Include in
/etc/ssh/sshd_config comes before the directive that beat us."
  fi
}
assert_eff passwordauthentication no
assert_eff permitrootlogin no
assert_eff kbdinteractiveauthentication no
assert_eff pubkeyauthentication yes
assert_eff permitemptypasswords no

# ListenAddress is cumulative, not first-wins -- another file adding a
# wildcard bind cannot be overridden from ours, only detected.
mapfile -t EFF_LISTEN < <(grep -i '^listenaddress ' <<<"$EFF" | awk '{print $2}' | sort)
mapfile -t WANT_LISTEN < <(printf '%s\n' "${TS4}:22" "[${TS6}]:22" | sort)
if [[ "${EFF_LISTEN[*]}" == "${WANT_LISTEN[*]}" ]]; then
  ok "effective listen addresses = ${EFF_LISTEN[*]} (tailnet only)"
else
  fail "effective listen addresses = ${EFF_LISTEN[*]:-<none>}"
  fail "expected                  = ${WANT_LISTEN[*]}"
  die "sshd would listen somewhere other than the tailnet. ListenAddress is
cumulative, so some other config file is ADDING a bind that this drop-in
cannot remove. Find it and delete that line:

    grep -rn ListenAddress /etc/ssh/sshd_config /etc/ssh/sshd_config.d/"
fi

# --- the unit override ----------------------------------------------------
if ! systemd-analyze verify "$UNIT_SRC" >/dev/null 2>&1; then
  warn "systemd-analyze could not verify the drop-in standalone (normal for a"
  warn "drop-in fragment); continuing -- it is re-checked by daemon-reload"
fi

# ==========================================================================
# PLAN + CONFIRM
# ==========================================================================
step "Plan"

show() { # src dst
  if [[ -f "$2" ]]; then
    if cmp -s "$1" "$2"; then printf '  %-52s %s\n' "$2" "(unchanged)"
    else printf '  %-52s %s\n' "$2" "REPLACE (backup kept)"; fi
  else
    printf '  %-52s %s\n' "$2" "create"
  fi
}
info "Files:"
show "$RENDERED"    "$SSHD_DST"
show "$LOGIND_SRC"  "$LOGIND_DST"
show "$UNIT_SRC"    "$UNIT_DST"
info ""
info "Backups:            ${BACKUP_DIR}"
info ""
info "Actions after copy:"
info "  systemctl daemon-reload           (picks up the sshd unit override)"
if systemctl is-active --quiet sshd; then
  info "  sshd -t                           (validate installed config)"
  info "  systemctl reload sshd             (RELOAD -- not restart)"
else
  info "  sshd -t                           (validate installed config)"
  info "  sshd is not running -- it will NOT be started for you"
fi
info ""
info "This script will NOT:"
info "  - restart sshd, or start it if it is stopped"
info "  - restart systemd-logind (it has no ExecReload; needs a restart you run)"
info "  - install packages, run 'tailscale up', or touch the firewall"
info ""

if [[ ! -t 0 ]]; then
  die "stdin is not a terminal -- refusing to run unattended"
fi
printf '%sProceed?%s type %syes%s: ' "$B" "$N" "$B" "$N"
read -r reply
[[ "$reply" == "yes" ]] || die "aborted -- nothing was changed"
info ""

# ==========================================================================
# APPLY
# ==========================================================================
step "Apply"

install -d -m 0700 "$BACKUP_DIR"

put() { # src dst mode
  local src="$1" dst="$2" mode="$3"
  install -d -m 0755 "$(dirname "$dst")"
  if [[ -f "$dst" ]]; then cp -a -- "$dst" "${BACKUP_DIR}/$(basename "$dst")"; fi
  # Write to a temp file in the destination dir and rename, so the file is
  # never observed half-written by a daemon reading it concurrently.
  local tmp; tmp="$(mktemp "${dst}.tether.XXXXXX")"
  cat -- "$src" > "$tmp"
  chown root:root "$tmp"; chmod "$mode" "$tmp"
  mv -f -- "$tmp" "$dst"
  INSTALLED+=("$dst")
  ok "installed ${dst}"
}

put "$RENDERED"   "$SSHD_DST"   0644
put "$LOGIND_SRC" "$LOGIND_DST" 0644
put "$UNIT_SRC"   "$UNIT_DST"   0644

# From here on, any failure must undo the writes.
trap 'rollback; cleanup' ERR

systemctl daemon-reload
ok "systemctl daemon-reload"

# Validate the REAL config now in place. The sandbox pass should make this a
# formality; run it anyway, because "should" is not a guarantee and this is
# the last checkpoint before touching a running daemon.
if ! sshd -t; then
  die "installed config failed validation"
fi
ok "sshd -t: installed config is valid"

trap - ERR

# ==========================================================================
# RELOAD
# ==========================================================================
step "Reload"

if systemctl is-active --quiet sshd; then
  info "  reloading sshd (existing sessions are preserved)"
  if systemctl reload sshd; then
    sleep 1
    if systemctl is-active --quiet sshd; then
      ok "sshd reloaded and still active"
    else
      fail "sshd is no longer active after reload"
      rollback
      die "sshd died on reload and the config was rolled back. DO NOT close any
open session. Run 'systemctl status sshd' and 'journalctl -u sshd -n 50'."
    fi
  else
    fail "reload command failed"
    rollback
    die "reload failed; config rolled back. Do not close any open session."
  fi

  info ""
  info "  sockets sshd is listening on now:"
  ss -lntp 2>/dev/null | awk 'NR==1 || /sshd/ {print "    " $0}'
else
  warn "sshd is not running -- nothing to reload"
  info ""
  info "  Nothing is listening yet. When you are ready, and while sitting at"
  info "  the machine, enable and start it:"
  info ""
  info "      sudo systemctl enable --now sshd"
  info ""
  info "  Then from the phone, confirm you can actually log in BEFORE you"
  info "  rely on it."
fi

# ==========================================================================
# WHAT IS STILL ON YOU
# ==========================================================================
info ""
step "Manual steps remaining"

info ""
info "1. ${B}Verify before you trust it.${N}"
info "   Keep your current session open. From a SECOND terminal (or the"
info "   phone), confirm a fresh login works:"
info ""
info "       ssh ${TETHER_USER}@${TS4}"
info ""
info "   Only close the first session once the second one has worked."
info ""
info "2. ${B}The sshd unit override is not active yet.${N}"
info "   daemon-reload loaded it, but the ordering and restart settings only"
info "   take effect on the next START of sshd -- a reload does not re-apply"
info "   them. It will be in force after the next reboot. Do not restart sshd"
info "   remotely to hurry this along."
info ""
info "3. ${B}logind changes are not active yet.${N}"
info "   systemd-logind has no ExecReload, so the lid policy needs:"
info ""
info "       sudo systemctl restart systemd-logind"
info ""
info "   That can disturb a running Hyprland session, so either do it at the"
info "   keyboard when you do not mind, or just let the next reboot apply it."
info "   Check what is in force with:"
info ""
info "       busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \\"
info "         org.freedesktop.login1.Manager HandleLidSwitchExternalPower"
info ""
info "   Expect: s \"ignore\". An empty string means unset, i.e. logind is"
info "   falling back to HandleLidSwitch and has not read the drop-in yet." 
info ""
if (( UFW_NOTE )); then
  info "4. ${B}ufw will drop mosh.${N}"
  info "   ufw is active and has no rule for the tailscale interface. mosh"
  info "   uses UDP 60000-61000 and will hang at 'mosh: Connecting...'."
  info "   The tailnet is authenticated transport, so allowing it wholesale"
  info "   is reasonable:"
  info ""
  info "       sudo ufw allow in on tailscale0"
  info ""
  info "   Narrower, if you prefer:"
  info ""
  info "       sudo ufw allow in on tailscale0 to any port 60000:61000 proto udp"
  info ""
fi

printf '%sdone%s\n\n' "$G" "$N"

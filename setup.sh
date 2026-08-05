#!/usr/bin/env sh
#
# Installs these dotfiles into $HOME and sets up zsh with the zim framework.
#
# Safe to re-run: every step checks for its own result first, and files already
# in $HOME are backed up before being replaced.
#
#   ./setup.sh              install
#   ./setup.sh --no-install skip the package manager, just copy and configure
#   ./setup.sh --no-chsh    do not change the login shell
#

set -eu

DOTFILES_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BACKUP_SUFFIX=".bak-$(date +%Y%m%d%H%M%S)"
do_install=1
do_chsh=1

for arg in "$@"; do
  case ${arg} in
    --no-install) do_install=0 ;;
    --no-chsh) do_chsh=0 ;;
    -h | --help)
      sed -n '3,11s/^# \{0,1\}//p' "$0"
      exit 0
      ;;
    *)
      echo "setup.sh: unrecognized argument ${arg}" >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m==>\033[0m %s\n' "$*" >&2
  exit 1
}

# sudo is absent from most container images, and pointless when already root.
if [ "$(id -u)" -eq 0 ]; then
  as_root() { "$@"; }
elif command -v sudo >/dev/null 2>&1; then
  as_root() { sudo "$@"; }
else
  as_root() { die "need root to run '$*', but sudo is not installed"; }
fi

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# zsh, git and curl are needed by the shell config itself; rsync copies this
# repo into $HOME. One branch per package manager, so supporting a distro means
# adding a branch rather than forking the whole script -- which is how the apt
# and zypper versions of this drifted apart in the first place.
install_packages() {
  packages='zsh git curl rsync'

  if command -v apt-get >/dev/null 2>&1; then
    log "installing ${packages} with apt"
    as_root apt-get update
    # Through `env`, because sudo drops the caller's environment.
    # shellcheck disable=SC2086
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ${packages}
  elif command -v zypper >/dev/null 2>&1; then
    log "installing ${packages} with zypper"
    # shellcheck disable=SC2086
    as_root zypper --non-interactive install ${packages}
  elif command -v dnf >/dev/null 2>&1; then
    log "installing ${packages} with dnf"
    # shellcheck disable=SC2086
    as_root dnf install -y ${packages}
  elif command -v pacman >/dev/null 2>&1; then
    log "installing ${packages} with pacman"
    # shellcheck disable=SC2086
    as_root pacman -Sy --needed --noconfirm ${packages}
  elif command -v apk >/dev/null 2>&1; then
    log "installing ${packages} with apk"
    # shellcheck disable=SC2086
    as_root apk add ${packages}
  elif command -v brew >/dev/null 2>&1; then
    log "installing ${packages} with brew"
    # shellcheck disable=SC2086
    brew install ${packages}
  else
    warn "no supported package manager found; install ${packages} yourself"
  fi
}

if [ "${do_install}" -eq 1 ]; then
  install_packages
fi

for cmd in zsh git curl rsync; do
  command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is not installed"
done

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Everything here that is not repository plumbing belongs in $HOME. --backup
# keeps a timestamped copy of whatever is about to be overwritten, so a
# hand-edited ~/.zshrc survives; unchanged files are not touched at all, so
# re-running leaves no backups behind.
log "copying dotfiles into ${HOME}"
rsync -a --human-readable --itemize-changes \
  --backup --suffix="${BACKUP_SUFFIX}" \
  --exclude '.git' \
  --exclude '.github' \
  --exclude '.claude' \
  --exclude '.gitignore' \
  --exclude 'setup.sh' \
  --exclude 'README.md' \
  --exclude 'LICENSE' \
  --exclude '*.zwc' \
  "${DOTFILES_DIR}/" "${HOME}/"

# Sourced at the end of ~/.zshrc, and deliberately not in the repo, so create
# it here -- but only when it is not already there, or setup.sh would be one
# stray run away from truncating the real one.
if [ ! -e "${HOME}/.zsh_secrets" ]; then
  log "creating ~/.zsh_secrets"
  (
    umask 077
    cat >"${HOME}/.zsh_secrets" <<'EOF'
# Sourced by ~/.zshrc. Never committed -- per-machine exports and anything
# secret goes here rather than in ~/.zshrc.
EOF
  )
fi

# ---------------------------------------------------------------------------
# Zim
# ---------------------------------------------------------------------------

# ~/.zshrc bootstraps zimfw on its own the first time a shell starts, but doing
# it here means the install output lands in this run rather than in the middle
# of someone's first prompt, and that a broken ~/.zimrc fails the setup.
ZIM_HOME=${ZDOTDIR:-${HOME}}/.zim

if [ ! -e "${ZIM_HOME}/zimfw.zsh" ]; then
  log "downloading zimfw"
  curl -fsSL --create-dirs -o "${ZIM_HOME}/zimfw.zsh" \
    https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
fi

log "installing zim modules"
ZIM_HOME=${ZIM_HOME} zsh -c 'source ${ZIM_HOME}/zimfw.zsh init' </dev/null

# ---------------------------------------------------------------------------
# Login shell
# ---------------------------------------------------------------------------

# The old script hardcoded /bin/zsh, which is a symlink to /usr/bin/zsh on some
# distros and absent on others; ask the shell where it actually is.
if [ "${do_chsh}" -eq 1 ]; then
  zsh_path=$(command -v zsh)

  # Login shells outside /etc/shells are refused by chsh and treated as
  # restricted accounts by some daemons, so register it before switching.
  if ! grep -qxF "${zsh_path}" /etc/shells 2>/dev/null; then
    log "adding ${zsh_path} to /etc/shells"
    printf '%s\n' "${zsh_path}" | as_root tee -a /etc/shells >/dev/null
  fi

  current_shell=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)
  if [ "${current_shell}" = "${zsh_path}" ]; then
    :
  elif command -v usermod >/dev/null 2>&1; then
    log "setting the login shell to ${zsh_path}"
    as_root usermod --shell "${zsh_path}" "$(id -un)"
  else
    # No usermod on macOS, and chsh there wants an interactive password.
    warn "could not set the login shell; run: chsh -s ${zsh_path}"
  fi
fi

log "done. start a new shell, or run: exec zsh"

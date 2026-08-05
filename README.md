# dotfiles

Zsh on the [zim](https://zimfw.sh) framework, plus a handful of local modules.

## Install

```sh
git clone git@github.com:gmsantos/dotfiles.git
cd dotfiles
./setup.sh
```

`setup.sh` installs `zsh git curl rsync` with whichever package manager it
finds (apt, zypper, dnf, pacman, apk, brew), copies everything here into
`$HOME`, installs the zim modules, and makes zsh the login shell. It is safe to
re-run: anything it would overwrite in `$HOME` is backed up with a timestamped
suffix first.

- `--no-install` skips the package manager.
- `--no-chsh` leaves the login shell alone.

## Layout

| Path                       | What it is                                        |
| -------------------------- | ------------------------------------------------- |
| `.zshrc`                   | zsh and zim module configuration                   |
| `.zimrc`                   | the module list zim installs from                  |
| `.zshenv`                  | `skip_global_compinit`, so zim owns the one compinit |
| `.zsh/modules/`            | local zim modules, loaded by path from `.zimrc`    |
| `.config/git/ignore`       | global gitignore                                   |
| `.local/bin/xdg-browser`   | `$BROWSER` shim that silences WSL interop noise    |

## Local modules

- **wsl-theme** — follows the Windows apps theme under WSL and repaints the
  shell to match. Caches the answer and re-queries in the background.
- **kubecontext** — the current context and namespace for prompts, read from
  the kubeconfig in zsh instead of shelling out to `kubectl`.
- **kubeswitch** — `ktx` and `kns` to switch context and namespace, by name,
  by unique substring, `-` for the previous one, or from a picker.
- **prompt-adaptive** — the prompt. Three lines, and legible on both light and
  dark backgrounds.

Each is documented in the header of its own `init.zsh`.

## Secrets

`~/.zshrc` sources `~/.zsh_secrets` when it exists. Tokens and per-machine
exports go there; it is mode 600 and never committed. `setup.sh` creates an
empty one if it is missing.

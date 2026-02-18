# dotfiles

It all started as a gist to keep track of my dotfiles: https://gist.github.com/uhop/f11632fa81bff6fa4c25300656dce6e7

Now I decided to use [chezmoi](https://www.chezmoi.io/) to manage them across computers.

# Installation

Generic instructions (see platform-specific notes below):

- Install [brew](https://brew.sh/) on MacOS or Linux.
- Install `chezmoi`:
  ```bash
  brew install chezmoi
  ```
- Initialize dotfiles:
  ```bash
  chezmoi init --apply uhop
  ```
- Reboot.

**Important!** If you are not me, change your name and email in the global `git` config:

```bash
git config --global user.name "Your Name"
```

```bash
git config --global user.email "you@example.com"
```

And update your GitHub user name in `.chezmoi.toml.tmpl` and at the bottom of `.bashrc`.

## Maintenance

Over time a system should be updated. There are the following scripts that help to do that:

1. `upd` &mdash; runs updates on all relevant services: `apt`, `snap`, `flatpak`, `brew`, `bun`.

2. `cln` &mdash; runs cleanups on all relevant services (see above) and updates `node`.

Use `upd -c` to run `upd` followed by `cln`.

## Installed tools

The choice of tools and aliases is influenced by:

- https://www.askapache.com/linux/bash_profile-functions-advanced-shell/
- https://dev.to/flrnd/must-have-command-line-tools-109f
- https://remysharp.com/2018/08/23/cli-improved
- https://www.cyberciti.biz/tips/bash-aliases-mac-centos-linux-unix.html
- https://opensource.com/article/22/11/modern-linux-commands
- https://github.com/ibraheemdev/modern-unix
- VIM:
  - https://github.com/amix/vimrc

The following tools are installed and aliased:

- `wget`, `httpie` &mdash; like `curl`.
- `age`, `gpg` &mdash; encryption utilities.
- `meld` &mdash; a visual diff/merge utility.
- `diff-so-fancy` &mdash; a nice `diff` pager.
- `tealdeer`, `cheat` &mdash; a `man` replacement. Alternatives: `tldr`.
- `exa` &mdash; better `ls`.
- `lsr` &mdash; better and faster `ls` (uses `io_uring` on Linux).
- `bat` &mdash; better `cat`.
- `fd` &mdash; better `find`.
- `ncdu`, `dust` &mdash; better `du`.
- `ag`, `ripgrep` &mdash; better `ack`.
  - `ig` &mdash; like `rg` but interactive, part of `igrep`.
- `tig`, `lazygit` &mdash; text interface for `git`.
  - `onefetch` &mdash; `git` stats.
- `broot` &mdash; better `tree`.
- `prettyping`, `gping` &mdash; better `ping`.
- `htop` &mdash; better `top`.
- `btop` &mdash; better `top`.
- `bottom` &mdash; a system monitor (as `btm`).
- `awscli`, `aws-iam-authenticator`, `kubernetes-cli`, `helm`, `sops`, `gh`, `hub`, `nginx`, `net-tools`, `xh` &mdash; useful utilities for web development.
- `parallel` &mdash; shell parallelization.
- `fzf` &mdash; a command-line fuzzy finder.
- `micro` &mdash; an editor. Alternatives: `nano`.
- `jq` &mdash; JSON manipulations.
- `tmux` &mdash; the venerable terminal multiplexor.
- `golang`, `python3`, `pyenv`, `rustc`, `wabt`, `zig` &mdash; language environments we use and love.
- `brotli` &mdash; better than `gzip`, used by HTTP.
- `mc` &mdash; Midnight Commander for file manipulations.
- `yazi` &mdash; Yet Another terminal file manager
- `alacritty` &mdash; no-nonsense terminal.
- `kitty` &mdash; no-nonsense terminal.
- `duf` &mdash; a disk utility.
- `hyperfine` &mdash; benchmarking better than `time`.
- `zoxide` &mdash; better `cd`.
- `node`, `nvm`, `deno`, `bun` &mdash; JavaScript environments.
- `pnpm` &mdash; `node`-compatible package manager.
- `helix` &mdash; a modal text editor.
- `whalebrew` &mdash; like `brew` but for Docker images.
- `xc` &mdash; a task runner.
- `mosh` &mdash; a mobile shell (alternative to `ssh`).
- `et` &mdash; an Eternal Terminal (alternative to `ssh`, not pre-installed).
- `ttyd` &mdash; a tool to share a terminal over the web.
- `lnav` &mdash; a log navigator
- `sd` &mdash; better `sed`.
- `uv` &mdash; fast Python package manager.
- `gcp` &mdash; advanced file copy utility.
- `tree` &mdash; show file directories as trees.
- `doas` &mdash; a (better) alternative to `sudo`.
- `etckeeper` &mdash; `git`-backed storage for `/etc` files (Linux only).
- `mas` &mdash; Mac App Store CLI (not pre-installed).
- `sshfs` &mdash; `sftp`-based user-level file system.
- `agrep` &mdash; fuzzy `grep` of the `tre` package.
- `bandwhich`, `bmon` &mdash; real-time network monitoring.
- `q` &mdash; a command-line DNS client.

Check `.bash_aliases` for a list of aliases.

# Platform-specific notes

## Ubuntu (Debian)

### Installation

These instructions assume a newly installed OS. Otherwise, adjust accordingly.

- Install your private ssh keys suitable to access github, if you use them. Otherwise github-based installations will fail.
- Install prerequisites:
  ```bash
  sudo apt install build-essential curl git git-gui gitk micro
  ```
- Install `brew`:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```
  - The exact installation instructions can change from time to time. Check https://brew.sh/ if you encounter any problems.
- Restart the session or initialize `brew`:
  ```bash
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  ```
- Install `chezmoi`:
  ```bash
  brew install chezmoi
  ```
- Initialize dotfiles:
  ```bash
  chezmoi init --apply uhop
  ```
  - The initial script installs various utilities using `apt`. Thus it requires a `sudo` password. Don't be alarmed.
    Inspect `run_onchange_before_install-packages.sh.tmpl` for more details.
- Reboot.

### Fonts

Fonts on Linux (Ubuntu): see https://askubuntu.com/questions/3697/how-do-i-install-fonts

- Download font, e.g., Hack Nerd Font and/or FiraCode Nerd Font from https://www.nerdfonts.com/font-downloads
- Unzip its archive to `~/.local/share/fonts/`.
- Run:
  ```bash
  fc-cache -fv
  ```

FiraCode Nerd Font is used for `code` (Visual Studio Code). It supports common programming ligatures.
Hack Nerd Font is used as a monospaced font for terminals (e.g., `gnome-terminal`) and similar programs (`git-gui`, `gitk`, &hellip;).

These dotfiles assume that these fonts are preinstalled and use them as appropriate.

### Video

Restricted soft on Ubuntu to play videos:

```bash
sudo apt install ubuntu-restricted-extras vlc libdvd-pkg
```

```bash
sudo dpkg-reconfigure libdvd-pkg
```

More on videos: https://www.omgubuntu.co.uk/2022/08/watch-bluray-discs-in-vlc-on-ubuntu-with-makemkv

### Cut-and-paste

To support cut-and-paste in the micro editor:

- Use the default (`"external"`) for the clipboard option.
- Install a proper command-line clipboard tool:
  - For Wayland:
    ```bash
    sudo apt install wl-clipboard
    ```
  - For X11 (realistically only one could be installed):
    ```bash
    sudo apt install xclip xsel
    ```
  - You may install all of them for a good measure:
    ```bash
    sudo apt install wl-clipboard xclip xsel
    ```

### Keyboard shortcuts

<kbd>F10</kbd> doesn't work in a terminal: https://superuser.com/questions/1543538/f10-key-not-working-in-terminal-mc-ubuntu-19-10

### Titan security key

See: https://support.google.com/titansecuritykey/answer/9148044?hl=en

A key should be registered only once. When I attempted to do so, I was misleadingly informed that
"this device cannot be used to create passkeys". When it happened, press "Use other device",
which will switch from the current computer to the key and now everything will go smoothly.

### Windows on Ubuntu (LXD)

See the following articles:

- https://ubuntu.com/tutorials/how-to-install-a-windows-11-vm-using-lxd#1-overview
- https://discussion.scottibyte.com/t/windows-11-lxd-virtual-machine-updated-november-2023/88

Useful commands:

- Start the `win11` instance:
  ```bash
  lxc start win11
  ```
  - Start and connect:
    ```bash
    lxc start win11 --console=vga
    ```
- Connect to the running instance:
  ```bash
  lxc console win11 --type=vga
  ```

If RDP is enabled in Windows, you can use `Remmina` to connect. Usually it is a faster option.
OTOH, connecting console allows to see the boot process and updates before Windows is loaded.

### Docker

- Docker: https://docs.docker.com/engine/install/ubuntu/
- `lazydocker`: https://github.com/jesseduffield/lazydocker
- `dive`: https://github.com/wagoodman/dive

Periodically Docker system needs to be cleaned up. Use:

```bash
docker system prune -a
```

This will remove all unused containers, networks, images, and build cache.

To remove all and volumes **not used by currently running containers**:

```bash
docker system prune -a --volumes
```

To remove everything (see above) without asking confirmation use "force":

```bash
docker system prune -af --volumes
```

Time to time `AppArmor` interferes with `Docker` operations, which result in failures with
"permission denied" errors. Frequently it can be helped with:

```bash
sudo aa-remove-unknown
```

### Ubuntu on Mac

Enabling <kbd>Fn</kbd> keys:

- https://help.ubuntu.com/community/AppleKeyboard
- https://askubuntu.com/questions/33514/use-function-keys-without-pressing-the-fn-button-in-the-mac-keyboard

Video driver:

- https://askubuntu.com/questions/1295423/ubuntu-20-04-on-imac-mid-2011-cant-adjust-brightness
  - This answer worked for my MacBook Air: https://askubuntu.com/a/1478635

## GUI

### Package managers

I use `apt`, `snap`, `flatpak`, `brew` and `AppImageLauncher`. Most GUI apps are installed with `flatpak`.
They are installed manually using Win-A (Cmd-A) from Gnome.

- `flatpak`
  - `flatseal` &mdash; `flatpak` permission editor.
  - `calibre` &mdash; an e-book manager.
  - `gear lever` &mdash; an AppImage manager.
  - `telegram` &mdash; a social network.
  - Web browsers (used for testing):
    - Brave
    - Chromium
    - Google Chrome
    - Microsoft Edge
  - Communications:
    - Slack
    - Zoom
  - `steam` &mdash; the game launcher from Valve.
  - `wezterm` &mdash; a modern terminal.
- `snap`
  - `code` &mdash; Visual Studio Code.
  - `firefox` &mdash; a web browser (it comes preinstalled).
  - `postman` &mdash; a tool for debugging network services.
    - It is available as a flatpak, but apparently it is completely unusable.
  - `skype` &mdash; communications
    - It is available as a flatpak, but apparently it is completely unusable.
  - _Note:_ if `snap-store` cannot be updated (because it is running) use:
    `snap-store --quit && snap refresh snap-store`
- AppImages
  - `gear lever` is used via `flatpak`. See above.
  - `AppImageLauncher` can be used. It is installed using the official `.deb` file or the PPA: https://github.com/TheAssassin/AppImageLauncher/wiki/Install-on-Ubuntu-or-Debian

## MacOS

The default shell is `zsh`. I use `bash`. The latter is included but a very old version
(something related to licensing issues). It is recommended to install the latest version with `brew`:

```bash
brew install bash
echo $(brew --prefix)/bin/bash | sudo tee -a /private/etc/shells
chsh -s $(brew --prefix)/bin/bash
```

For more info see:

- https://phoenixnap.com/kb/change-zsh-to-bash-mac

Make sure that scripts start with `#!/usr/bin/env bash` instead of `#!/bin/bash`. The former
is the new `bash`, while the latter is the old one.

# Application-specific notes

## tmux

The alias to invoke `ssh` with `tmux` is `ssht`: `ssht srv`.

When running locally `tmux` uses the standard prefix: <kbd>Ctrl+b</kbd>.
If you are running a remote session from a local session press <kbd>Ctrl+b</kbd>
twice to send commands to the remote session. For example, to detach from the remote session,
but not the local one: <kbd>Ctrl+b</kbd> <kbd>Ctrl+b</kbd> <kbd>d</kbd>.

When running `tmux` for the first time, install plugins by pressing <kbd>Prefix</kbd>+<kbd>I</kbd>.
To update plugins, press <kbd>Prefix</kbd>+<kbd>U</kbd>. Note that `I` and `U` are uppercase.

See "Kitty terminal" below if you run Kitty with `tmux` remotely.

## Micro

Currently installed plugins (including the default ones) can be listed using:

```bash
mic -plugin list
```

The list of recommended plugins can be found here: `~/.config/micro/plugins.txt`.

The `prettier` plugin is installed manually: https://github.com/claromes/micro-prettier

Consider its cousin for Python: https://github.com/claromes/micro-yapf

The rest of plugins (excluding default plugins) are installed using:

```bash
mic -plugin install fzf
```

Links on customization:

- https://claromes.com/blog/customizing-my-micro-editor.html

## Kitty terminal

See for details on installing: https://sw.kovidgoyal.net/kitty/binary/

`tmux` will complain that `xterm-kitty` is unknown. The solution is to copy
`.terminfo` to the remote server:
[Tmux under Kitty terminal](https://unix.stackexchange.com/questions/470676/tmux-under-kitty-terminal).

Example:

```bash
scp -r ~/.terminfo REMOTE:~./terminfo
```

Where `REMOTE` is the remote server you are copying `.terminfo` to.

Another (better) solution is to install `kitty-terminfo` system-wide, which solves the problem
for other users including the super user:

```bash
# on Debian
sudo apt install kitty-terminfo
```

## GNOME

I used the following articles as a guidance:

- https://www.howtogeek.com/improve-ubuntu-without-using-the-terminal/
- https://www.howtogeek.com/i-always-install-these-gnome-extensions-on-my-linux-computers/

This is the list of user-installed extensions I use:

- ArcMenu, moderately useful, usually disabled
- Clipboard History
- Dash to Dock &mdash; doesn't work for me, sometimes locks GNOME (?), disabled
- Dash to Panel &mdash; not sure I like how it works, disabled
- GSConnect &mdash; sometimes not available in newer versions
- Just Perfection
- LAN IP Address
- Tray Icons: Reloaded
- User id in top panel &mdash; not updated and deemed incompatible with GNOME 46, disabled
  - Hostname On Panel &mdash; similar to the previous one but just a hostname
- Vitals &mdash; useful, but I usually disable it on low-powered systems

## MakeMKV

The best way is to install it on Linux via PPA:

- https://connectwww.com/how-to-install-makemkv-on-ubuntu-mkv-converter/61127/

## doas

`doas` should be configured before the first use. The configuration lives in `/etc/doas.conf`.
The typical minimal configuration looks like that:

```txt
permit persist keepenv setenv { PATH XAUTHORITY LANG LC_ALL } :sudo
```

The following configuration allows to run common maintenance commands
without asking password:

```txt
permit persist keepenv setenv { PATH XAUTHORITY LANG LC_ALL } :sudo

permit nopass :sudo cmd apt args update
permit nopass :sudo cmd apt args upgrade
permit nopass :sudo cmd apt args -y upgrade
permit nopass :sudo cmd apt args upgrade -y
permit nopass :sudo cmd apt args autoremove
permit nopass :sudo cmd apt args -y autoremove
permit nopass :sudo cmd apt args autoremove -y
permit nopass :sudo cmd apt args autoclean
permit nopass :sudo cmd apt args -y autoclean
permit nopass :sudo cmd apt args autoclean -y

permit nopass :sudo cmd snap args refresh

permit nopass :sudo cmd ping
permit nopass :sudo cmd prettyping

permit nopass :sudo cmd aa-remove-unknown
```

For good measure make this file readable only for `root`:

```bash
sudo chown -c root:root /etc/doas.conf
sudo chmod -c 0400 /etc/doas.conf
```

On initial setup the config described above is installed if no config is available.

**If `doas` is available and its config exists, it is aliased as `sudo` in `.bash_aliases`.**

For more details see:

- https://wiki.debian.org/Doas
- https://manpages.debian.org/bookworm/opendoas/doas.1.en.html
- https://manpages.debian.org/bookworm/opendoas/doas.conf.5.en.html

## etckeeper

See: https://wiki.archlinux.org/title/Etckeeper

I add manually `*.mount` to `/etc/.gitignore`:

```bash
sudoedit /etc/.gitignore
```

## ufw

```bash
# mosh
sudo ufw allow 60000:61000/udp
# et
sudo ufw allow 2022/tcp
```

## TeX/LaTeX

On Linux we can install with `apt` (or other system package manager) the following packages:

- `texlive` &mdash; the core of TeX + most common TeX/LaTeX packages.
- `texworks` &mdash; the GUI editor for TeX files.
- `texmaker` &mdash; the GUI editor for TeX files.
- `latexmk` &mdash; the utility to run process iteratively in multiple passes. Useful for
  getting labels and pages correctly.

On Mac `texlive` is available with `brew`.

One of popular choices of mutiplatform GUI editors is `LyX`.

This system does not install TeX by default.

## flatpak

Flatpak has an annoying issue with permissions. Everything works locally, but when run remotely
via `ssh` it starts to ask for password on every operation several times per item it processes.

The solution is to create a rules file allowing remote sessions to run flatpak commands without
password. The file should be named as `/usr/local/share/polkit-1/rules.d/90-flatpak-ssh.rules`
and should look like that:

```js
polkit.addRule(function (action, subject) {
  if (
    action.id.indexOf('org.freedesktop.Flatpak.') == 0 &&
    (subject.isInGroup('sudo') || subject.isInGroup('wheel'))
  ) {
    return polkit.Result.YES;
  }
  return polkit.Result.NOT_HANDLED;
});
```

Then the system should be restarted for good measure. Or you can try to reload polkit:

```bash
sudo systemctl restart polkit
```

This addition allows to perform any flatpak operations for any member of `sudo` (Debian)
or `wheel` (Fedora) groups without asking password. Unlike the stock rules it doesn't check
if the session is local or active, and doesn't list 5 different operations by their names.
See the stock rules in `/usr/share/polkit-1/rules.d/org.freedesktop.Flatpak.rules`
for comparison.

### Chrome

For some reason Chrome packaged as Flatpak cannot print to actual printers. Only to PDF.
Apparently it needs some additional permissions (can be set by Flatseal):

- Printing system (under Socket) `socket=cups` is set by default.
- All user files (under Filesystem) `filesystem=home` **should be set**.

Other custom settings I use:

- Other files (under Filesystem):
  - `~/.local/share/icons`
  - `~/.local/share/applications`
- GPU acceleration (under Device) `device=dri`.

## CUPS

For some reason GNOME CUPS tools have problems: they set up a network printer
but it is very slow. Sources recommend to use native CUPS utilities to set it up.
For example, use "Administration" on https://localhost:631

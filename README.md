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
- `bat` &mdash; better `cat`.
- `fd` &mdash; better `find`.
- `ncdu`, `dust` &mdash; better `du`.
- `ag`, `ripgrep` &mdash; better `ack`.
- `tig`, `lazygit` &mdash; text interface for `git`.
  - `onefetch` &mdash; `git` stats.
- `broot` &mdash; better `tree`.
- `prettyping`, `gping` &mdash; better `ping`.
- `htop` &mdash; better `top`.
- `btop` &mdash; better `top`.
- `awscli`, `aws-iam-authenticator`, `kubernetes-cli`, `helm`, `gh`, `hub`, `nginx`, `net-tools`, `xh` &mdash; useful utilities for web development.
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
- `bottom` &mdash; a system monitor.
- `node`, `nvm`, `deno`, `bun` &mdash; JavaScript environments.
- `helix` &mdash; a modal text editor.
- `whalebrew` &mdash; like `brew` but for Docker images.
- `xc` &mdash; a task runner.
- `mosh` &mdash; a mobile shell.
- `lnav` &mdash; a log navigator
- `sd` &mdash; better `sed`.
- `uv` &mdash; fast Python package manager.
- `gcp` &mdash; advanced file copy utility.

Check `.bash_aliases` for a list of aliases.

# Platform-specific notes

## Ubuntu (Debian)

### Installation

These instructions assume a newly installed OS. Otherwise, adjust accordingly.

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

* https://ubuntu.com/tutorials/how-to-install-a-windows-11-vm-using-lxd#1-overview
* https://discussion.scottibyte.com/t/windows-11-lxd-virtual-machine-updated-november-2023/88

Useful commands:

* Start the `win11` instance:
  ```bash
  lxc start win11
  ```
  * Start and connect:
    ```bash
    lxc start win11 --console=vga
    ```
* Connect to the running instance:
  ```bash
  lxc console win11 --type=vga
  ```

If RDP is enabled in Windows, you can use `Remmina` to connect. Usually it is a faster option.
OTOH, connecting console allows to see the boot process and updates before Windows is loaded.

### Docker

* Docker: https://docs.docker.com/engine/install/ubuntu/
* `lazydocker`: https://github.com/jesseduffield/lazydocker
* `dive`: https://github.com/wagoodman/dive

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
  - *Note:* if `snap-store` cannot be updated (because it is running) use:
    `snap-store --quit && snap refresh snap-store`
- AppImages
  - `gear lever` is used via `flatpak`. See above.
  - `AppImageLauncher` can be used. It is installed using the official `.deb` file or the PPA: https://github.com/TheAssassin/AppImageLauncher/wiki/Install-on-Ubuntu-or-Debian

# Application-specific notes

## tmux

The alias to invoke `ssh` with `tmux` is `ssht`: `ssht srv`.

When running locally `tmux` uses
the standard prefix: <kbd>Ctrl</kbd>+<kbd>b</kbd>. When invoked remotely through `ssht` it uses
the prefix: <kbd>Ctrl</kbd>+<kbd>a</kbd>. This way you can use different prefixes for local and
remote sessions.

When running `tmux` for the first time, install plugins by pressing <kbd>Prefix</kbd>+<kbd>I</kbd>.
To update plugins, press <kbd>Prefix</kbd>+<kbd>U</kbd>. Note that `I` and `U` are uppercase.

See "Kitty terminal" below if you run Kitty with `tmux` remotely.

## Micro

The `prettier` plugin is installed manually: https://github.com/claromes/micro-prettier

Consider its cousin for Python: https://github.com/claromes/micro-yapf

The rest of plugins (excluding default plugins) are installed using:

```bash
mic -plugin install fzf
```

The list of recommended plugins can be found here: `~/.config/micro/plugins.txt`.

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

## GNOME

I used the following articles as a guidance:

* https://www.howtogeek.com/improve-ubuntu-without-using-the-terminal/
* https://www.howtogeek.com/i-always-install-these-gnome-extensions-on-my-linux-computers/

This is the list of user-installed extensions I use:

* ArcMenu
* Clipboard History
* Dash to Dock &mdash; doesn't work for me, sometimes locks GNOME (?), disabled
* Dash to Panel &mdash; not sure I like how it works, disabled
* GSConnect &mdash; sometimes not available in newer versions
* Just Perfection
* LAN IP Address
* Tray Icons: Reloaded
* User id in top panel
* Vitals &mdash; useful, but I usually disable it on low-powered systems

## MakeMKV

The best way is to install it on Linux via PPA:

* https://connectwww.com/how-to-install-makemkv-on-ubuntu-mkv-converter/61127/

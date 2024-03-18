# dotfiles

It all started as a gist to keep track of my dotfiles: https://gist.github.com/uhop/f11632fa81bff6fa4c25300656dce6e7

Now I decided to use [chezmoi](https://www.chezmoi.io/) to manage them across computers.

# Installation

Generic instructions (see platform-specific notes below):

* Install [brew](https://brew.sh/) on MacOS or Linux.
* Install `chezmoi`:
  ```bash
  brew install chezmoi
  ```
* Initialize dotfiles:
  ```bash
  chezmoi init --apply uhop
  ```
* Reboot.

## Installed tools

The choice of tools and aliases is influenced by:

* https://www.askapache.com/linux/bash_profile-functions-advanced-shell/
* https://dev.to/flrnd/must-have-command-line-tools-109f
* https://remysharp.com/2018/08/23/cli-improved
* https://www.cyberciti.biz/tips/bash-aliases-mac-centos-linux-unix.html
* https://opensource.com/article/22/11/modern-linux-commands
* https://github.com/ibraheemdev/modern-unix
* VIM:
  * https://github.com/amix/vimrc

The following tools are installed and aliased:

* `wget`, `httpie` &mdash; like `curl`.
* `age`, `gpg` &mdash; encryption utilities.
* `meld` &mdash; a visual diff/merge utility.
* `diff-so-fancy` &mdash; a nice `diff` pager.
* `tealdeer` &mdash; a `man` replacement. Alternatives: `tldr`, `cheat`.
* `exa` &mdash; better `ls`.
* `bat` &mdash; better `cat`.
* `fd` &mdash; better `find`.
* `ncdu` &mdash; better `du`. Alternatives: `dust`.
* `ag` &mdash; better `ack`. Alternatives: `ripgrep`.
* `tig`, `lazygit` &mdash; text interface for `git`.
* `broot` &mdash; better `tree`.
* `prettyping` &mdash; better `ping`.
* `htop` &mdash; better `top`.
* `awscli`, `kubernetes-cli`, `nginx` &mdash; useful utilities for web development.
* `parallel` &mdash; shell parallelization.
* `fzf` &mdash; a command-line fuzzy finder.
* `micro` &mdash; an editor. Alternatives: `nano`.

Check `.bash_aliases` for a list of aliases.

# Platform-specific notes

## Ubuntu (Debian)

### Installation

These instructions assume a newly installed OS. Otherwise, adjust accordingly.

* Install prerequisites:
  ```bash
  sudo apt install build-essential curl git git-gui gitk micro
  ```
* Install `brew`:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```
  * The exact installation instructions can change from time to time. Check https://brew.sh/ if you encounter any problems.
* Restart the session or initialize `brew`:
  ```bash
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  ```
* Install `chezmoi`:
  ```bash
  bash install chezmoi
  ```
* Initialize dotfiles:
  ```bash
  chezmoi init --apply uhop
  ```
  * The initial script installs various utilities using `apt`. Thus it requires a `sudo` password. Don't be alarmed.
    Inspect `run_onchange_before_install-packages.sh.tmpl` for more details.
* Reboot.

### Fonts

Fonts on Linux (Ubuntu): see https://askubuntu.com/questions/3697/how-do-i-install-fonts

* Download font, e.g., Hack Nerd Font and/or FiraCode Nerd Font from https://www.nerdfonts.com/font-downloads
* Unzip its archive to `~/.local/share/fonts/`.
* Run:
  ```bash
  fc-cache -fv
  ```

FiraCode Nerd Font is used for `code` (Visual Studio Code). It supports common programming ligatures.
Hack Nerd Font is used as a monospaced font for terminals (e.g., `gnome-terminal`) and similar programs (`git-gui`, `gitk`, &hellip;).

These dotfiles assume that these fonts are preinstalled and use them as appropriate.

### Video

Restricted soft on Ubuntu to play videos:

* ```bash
  sudo apt install ubuntu-restricted-extras vlc libdvd-pkg
  ```
* ```bash
  sudo dpkg-reconfigure libdvd-pkg
  ```

More on videos: https://www.omgubuntu.co.uk/2022/08/watch-bluray-discs-in-vlc-on-ubuntu-with-makemkv

### Cut-and-paste

To support cut-and-paste in the micro editor:

* Use the default (`"external"`) for the clipboard option.
* Install a proper command-line clipboard tool:
  * For Wayland:
    ```bash
    sudo apt install wl-clipboard
    ```
  * For X11 (realistically only one could be installed):
    ```bash
    sudo apt install xclip xsel
    ```
  * You may install all of them for a good measure:
    ```bash
    sudo apt install wl-clipboard xclip xsel
    ```

## GUI

### Package managers

I use `apt`, `snap`, `flatpak`, and `brew`. Most GUI apps are installed with `flatpak`. They are installed manually using Win-A (Cmd-A) from Gnome.

* `flatpak`
  * `flatseal` &mdash; `flatpak` permission editor.
  * Web browsers (used for testing):
    * Brave
    * Chromium
    * Google Chrome
    * Microsoft Edge
  * Communications:
    * Skype
    * Slack
    * Zoom
  * `steam` &mdash; the game launcher from Valve.
  * `wezterm` &mdash; a modern terminal.
* `snap`
  * `code` &mdash; Visual Studio Code. 
  * `firefox` &mdash; a web browser (it comes preinstalled).
  * `postman` &mdash; a tool for debugging network services.

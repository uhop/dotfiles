# Ansible replacement plan

We use Ansible playbooks and they work. Still, I want to explore replacing it.

## Reasons

What I like:

- Agentless. I can run a playbook against any server, a list of servers, or a predefined group.

What I don't like:

- No visible logs.
  - Fine when everything works. When it fails, I want a full error log.
  - Sometimes I want to review successful runs.
  - Sometimes I want to act on output. Example: `upd` (`executable_upd.tmpl`) can report that a reboot is recommended; I want to catch that and tell the user which servers to reboot.
- The output is visually loose while tasks run.
- Without visible logging every task looks idle or hung. There is no "where are we?" or "how much is left?".
- By default it doesn't run tasks on different servers in parallel.

## Analysis

Ansible uses `ssh` as transport and requires `python3` on the target. Both are reasonable: `ssh` is always available and the user controls authentication; `python3` is widely available and is already installed on all my setups (alongside `node`).

`bash` is also always available, except on Windows, which we don't support anyway.

Ansible needs no special agent or server, which is attractive: no new attack surface, no extra setup.

## Possible alternative

[Remotely](https://raw.githubusercontent.com/markasoftware/remotely/refs/heads/master/remotely.sh) looks promising. It is written in `bash`, agentless, and uses `ssh` as transport.

It opens a control socket once and reuses it for subsequent `ssh` and `rsync` calls over the same connection. That covers running remote commands and shipping files in both directions.

What I don't like about it:

- It uses environment variables to designate the target host. The variable names are too verbose for casual use.
- No way to apply the same operations to multiple servers at once.
- No notion of inventory or groups.
- No way to monitor `stdout`/`stderr` programmatically and surface meaningful status (failed, succeeded, reboot required, warning, ...).

## Proposal

Borrow Remotely's control-socket idea and build a small `bash` library that runs commands remotely and transfers files (via `sftp` and/or `rsync`).

The library is called `playbash` — it runs `bash` playbooks on remote hosts. Eventually it could be extracted into its own project.

The API might look like this (all names are placeholders):

```bash
# create and return a sock file for this host
local connection=$(playbash_connect "$HOST")

# upload a file
playbash_upload "$connection" ./from/file "./to/file"

# upload a folder
playbash_upload "$connection" ./from/folder/ "./to/folder/"

# run a command remotely
playbash_run "$connection" "do something"

# download a file
playbash_download "$connection" ./from/file ./to/file

# clean up
playbash_close "$connection"
```

A "playbook" is then just a `bash` script that uses this API, with predefined parameters (host, connection and transfer options) and a known location on disk. A runner consumes an inventory file and takes two arguments:

- a playbook name
- the host(s) or group(s) it applies to

A separate debug runner can execute a playbook locally or against a single host and stream all output verbatim.

## Possible implementation details

If `playbash_run` fails, the user should see `stderr` at the end. While it runs, we can show the last 3-5 lines of `stdout` scrolling.

We can define markers that let a command flag a warning or suggest a follow-up action (e.g. "reboot"). For the latter we can even ask the user whether to do it now.

We can also monitor output (via `tee` or `script`) for trigger words and emit warnings or actions. These triggers will likely be specific to our utilities.

(See ./private_dot_local/libs/bootstrap.sh and ./dev-docs/tty-simulation.md for notes on `tee` and `script`.)

We still need to decide how we run remote commands. One option: a small `bash` runner that we upload first; it receives a playbook, runs it, and reports back `stdout`, `stderr` on failure, and any warnings/actions.

The user-facing details still need to be worked out.

## Addendum: pyinfra

I looked at `pyinfra` and it looks too complicated for what I need:

- It has a notion of operations, which are Python modules responsible for `apk`, `apt`, `zfs`, `brew`, and so on. I think it is an overkill for what I need.
  - I want to run shell commands (see below for more details).
- It runs all steps in parallel on various hosts waiting for their completion before proceeding with the next step.
  - I want to run commands on different hosts independently, in isolation.
- Its "playbook" scripts are specialized and cannot be run as scripts.
  - I would like, if possible, my "playbook" scripts to be plain shell files.
    - I want to be able to run them locally by hand, so I can debug them when needed.

I think I should scale down the scope.

## Scope

Let me define my wants first.

### What I have now

My main want is to run maintenance scripts daily and weekly. Such scripts update various
components on a remote or local system. Usually I run them manually using `ssh` (or `ssht`)
and locally in a terminal visually inspecting their output.

These scripts are already preinstalled on all managed systems via `chezmoi`. I have 5-10 systems
I manage. All of them but one are Linux (Ubuntu), one is Mac. None of them is virtual.

The daily script:

- Updates `chezmoi` by running `chezmoi update`.
- Updates the system running `upd -y`.
- Refreshes and restarts docker images, if they are present running `dcms`.

The weekly script does all that and adds a cleanup by running `upd -cy`, which runs `cln`
after `upd`.

Pain points:

- `chezmoi update` does not require `sudo`, unless it does. If I modified what packages should be preinstalled, it immediately drops to `sudo` to install system packages. When it happens (rarely), I have to run it manually entering my password. Otherwise it works fine.
- On Linux:
  - Sometimes `apt` or `snap` (part of `upd`) update system components and require a reboot. I detect this in `upd` and `cln` and print a highly visible message recommending a reboot, even suggesting how to do it. Running these commands blindly, without seeing the output, robs the user of this opportunity. This feature only works on Linux at the moment.
  - Sometimes `docker-ce` components are updated by `apt`. It doesn't trigger a reboot warning, but docker stops working properly, for example it cannot restart containers. When it happens, the remedy is to restart computer or, possibly, restart the docker daemon(s). I usually do the former.
    - This is different from updates of `AppArmor` by `apt`/`snap`, which affects the ability to start/stop containers. `dcm` (`executable_dcm`) takes it into account by running `sudo aa-remove-unknown` and retrying when restarting fails.
- On Mac:
  - Running some commands used by `upd` on Mac requires `sudo`.
    - Technically Linux also requires `sudo` for `apt` and `snap`, but I avoid the prompt by substituting `sudo` with `doas` and whitelisting the commands used in regular maintenance, so no password is asked. Installing `doas` on Mac is a more involved process, so I haven't done it.
  - Cleaning up unused docker images doesn't work properly on Mac because it needs a running docker daemon, which is not always the case (it is started manually when needed). `cln` detects that docker is present and tries to prune unused images, which fails and aborts the whole script.
    - That part can be improved in the script itself by detecting whether the daemon is actually running.

### Proposed scope

Unlike `ansible` and `pyinfra`, all I want is the following operations:

- Run an existing CLI command on a remote host.
  - I want to be notified if something went wrong.
  - I want to be notified of warnings, notices, and suggested actions.
  - (optional) I want to review the log of a successful run.
  - In most cases the necessary commands can be distributed by separate means, e.g., `chezmoi`.
- Upload a file or a folder.
  - It could be a prerequisite for running a command.
  - It could be a command with its dependencies that I want to run next.
- Download a file or a folder.
  - It could be a log I want to analyze locally.

Obviously file operations are not complete without removal, but I can do that
with a CLI command.

The previous considerations still apply:

- Agentless (`ssh` as a transport).
- A shell script as a playbook (I prefer it to be directly runnable locally).
- Helpers for writing a playbook script.
  - Such helpers should automatically detect whether they are run manually or by the special runner and scale down some functionality — e.g., skip writing to the proposed sidecar file (formalized warnings, actions, ...) when its path is not set via an environment variable.
- A playbook runner that provides a nice TUI and orchestrates execution on remote hosts.
  - Written in Node?
  - I would prefer zero dependencies, where possible and where it makes sense.
  - See `~/Open/console-toolkit/` for how ANSI symbols can be used and what text manipulations are available.
    - If the borrowing is small, we can copy from that project.
    - If the borrowing is large, we can create a separate project for the runner and publish it on NPM.
    - The same applies to the other referenced projects.
  - Another project worth inspecting is `~/Open/dollar-shell/`, which provides runners for processes and shell commands on Node/Bun/Deno. It can be used to run `ssh`/`sftp`/`rsync`.
  - Yet another project to look at is `~/Open/stream-chain/`, which contains a JSONL parser and stream manipulation utilities.
- Some way to group hosts, possibly using an inventory file.
  - All listed hosts can be members of a special group `all`, like in `ansible`.

In general, I am open to a complete rewrite of the inventory in a different form/format. Ditto for
playbooks. With 5-10 hosts and ~5 playbooks, it is easy.

### Unsolved: sudo password

It is still unclear what to do about the sporadic need for a `sudo` password. Running the whole script
as `sudo` is not an option: non-`sudo` parts still work, but they will create files owned by a
different user, forcing them to be run as `sudo` from then on and breaking other scripts that use
those files.

Supplying a `sudo` password as text seems insecure.

One possible approach: if we detect that a password is being asked for, we can abort the script
and inform the user, so they can run it manually.

For now, we can punt on this and assume that scripts never ask questions.

Some background: I use security certificates to log in to remote computers without passwords.
In fact, password authentication is turned off for `ssh`. When logging in locally or running `sudo`,
I use a text password. If we could instruct `sudo` to use certificates instead, that would be lovely.

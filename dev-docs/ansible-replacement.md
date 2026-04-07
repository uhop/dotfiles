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

The library is called `tether` — the persistent ssh control socket *is* a tether to the host. Eventually it could be extracted into its own project.

The API might look like this (all names are placeholders):

```bash
# create and return a sock file for this host
local connection=$(tether_connect "$HOST")

# upload a file
tether_upload "$connection" ./from/file "./to/file"

# upload a folder
tether_upload "$connection" ./from/folder/ "./to/folder/"

# run a command remotely
tether_run "$connection" "do something"

# download a file
tether_download "$connection" ./from/file ./to/file

# clean up
tether_close "$connection"
```

A "playbook" is then just a `bash` script that uses this API, with predefined parameters (host, connection and transfer options) and a known location on disk. A runner consumes an inventory file and takes two arguments:

- a playbook name
- the host(s) or group(s) it applies to

A separate debug runner can execute a playbook locally or against a single host and stream all output verbatim.

## Possible implementation details

If `tether_run` fails, the user should see `stderr` at the end. While it runs, we can show the last 3-5 lines of `stdout` scrolling.

We can define markers that let a command flag a warning or suggest a follow-up action (e.g. "reboot"). For the latter we can even ask the user whether to do it now.

We can also monitor output (via `tee` or `script`) for trigger words and emit warnings or actions. These triggers will likely be specific to our utilities.

(See ./private_dot_local/libs/bootstrap.sh and ./dev-docs/tty-simulation.md for notes on `tee` and `script`.)

We still need to decide how we run remote commands. One option: a small `bash` runner that we upload first; it receives a playbook, runs it, and reports back `stdout`, `stderr` on failure, and any warnings/actions.

The user-facing details still need to be worked out.

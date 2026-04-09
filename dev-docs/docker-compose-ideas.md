# Docker Compose management ideas

## Background

I manage multiple Docker Compose setups and need a tool to streamline their lifecycle.

## Existing tools

The main tool for updating images daily (run manually) is `update.sh`:

```bash
#!/bin/bash

docker compose pull
docker compose up -d

# docker compose pull && docker compose up -d —force-recreate && docker image prune -a
```

The commented-out line is an alternative that also force-recreates containers and prunes unused images.

To bring a setup down there is `down.sh`:

```bash
#!/bin/bash

# sudo aa-remove-unknown

docker compose down
```

The commented-out line is needed when AppArmor prevents Docker from managing containers, which happens occasionally. The typical failure sequence:

- `./update.sh` fails with a security-related error.
- I run `sudo aa-remove-unknown`, then `./down.sh`.
  - Running `./update.sh` immediately after doesn't always work.
- A second `./update.sh` succeeds (pull is a no-op the second time).

The happy path — just run `./update.sh` — often requires manual intervention.

### Current implementation

Each setup lives in its own subdirectory under `~/servers` with a `compose.yml`, `update.sh`,
`down.sh`, and other config files. The shell scripts are copied per directory and run manually.

## General ideas

A single utility that can:

- **Update** all services (pull + up)
- **Bring down** a setup
- **Stop / start** a setup
- **Handle AppArmor** issues automatically
- Provide a happy path that just works

### AppArmor handling

`sudo aa-remove-unknown` removes stale AppArmor profiles that block Docker.
The utility should detect AppArmor-related failures and automatically run the fix, then retry.

Note: on Linux I alias `sudo` to `doas` and can configure passwordless access for
`aa-remove-unknown`, which keeps the flow non-interactive.

## Implementation ideas

Bash script in `private_dot_local/bin/` using `options.bash` for argument parsing.

Short name candidates — see plan document.

### Future directions

- Update/restart all setups under `~/servers` at once.
- Operate on remote servers via `playbash` or similar.
- Schedule updates with `cron` or `systemd` timers.
- Notify when services are updated (log file, email, or push notification).

# Playbash debugging

It looks like the problem is that we cannot detect a password prompt (from `ssh`) when
running remotely on Mac. It works locally on Mac, it works in both combinations on Linux,
but doesn't work running remotely (from Linux).

When debugging we switched from `script` to a Python wrapper, yet the problem is still
present.

I think the whole debacle is because of systemic problems with the approach.

Questions:

- Do we really have a difference between local and remote executions?
  - We have different paths for running locally vs. remotely: `runLocally()` vs. `runRemote()`. How do we know that we don't see some difference between code in these two paths.
- The AI agent suggested that there is a major difference between BSD `script` and Linux `script`: the former buffers ouput so it doesn't reach our regular expression matcher. Do we have a clean repro of that?
  - We debug `upd` utiltity that can ask for a sudo password.
    - Linux uses `doas` as a `sudo` replacement, which is configured not to ask for password in `upd` cases. Mac doesn't use `doas` (hard to install) and uses `sudo` that asks for password always. Are we going to see the same problem switching to `sudo` on Linux?

## Minimal runner

Instead of debugging huge `playbash` utility we should distill the problem with
a **minimally reproducible case**. No local vs. remote cases for now &mdash; all cases
should be remote through `ssh` (it is possible to use `ssh` from the same computer).

Running locally as a remote case via `ssh` allows to log all aspects of our runner
in a local file, which can be inspected later.

## Minimal payload

The utility we run should be minimal.

The initial version should be as simple as possible. Example:

```bash
echo Start
read -p "Pattern:" answer
echo "Finish. Answer: $answer"
```

The example above doesn't use `sudo` at all and we can try to match "Pattern:"
or any other text.

If it works with our minimal runner we can try to use more complicated script:

```bash
echo Start
command sudo ls
echo Finish
```

It will trigger a password prompt and it avoids `doas`.

We can use it as a debugging target.

## Local runner

We already use a local runner written as a Python script that is sourced from
a local file to a remote `python3` running remotely using `ssh`.

We need to make sure that the runner (`playbash-wrap.py`) runs locally as we want
without `ssh`. After that we should run it with `ssh`. If it fails in this configuration,
it means that there is a problem with `ssh` bridge. Solving the bridge problems is something
that can be done later if we confirm the problem.

The current size of the local runner of scripts is quite small, but, if it proves to be
a problem, we should scale it down opting for a minimally possible version too.

## Tracing/logging

Instead of relying on subtle side-effects or guessing what is going on, we should trace
all actions and events in a local file (even with `ssh` we are running locally).
It will help understand the problem. Having a minimally reproducible case it should be easy
to add traces/logs.

Problem with stream events? Log all stream events. And so on.

## Clean up

All unsuccessful attempts to solve the problem left some unnecessary code in the codebase.
Instead of rolling back after a failure, we added more code in the next attempts.
We should avoid this trap and work with minimal code every single time, then, when we solved
the problem, we should thoroughly clean up the `playbash`-related code removing all
unnecessary code and opting for a minimizing the codebase.

# Summary

We should start as small as possible: the runner (a stand-in for `playbash`), a script
(what we run remotely), and the local runner (the harness that runs the script on a remote end).

We should use the current computer for `ssh`, so it is much easier to debug.

We should use logging/tracing to undersyand the actual flow.

Then, when we learn how to deal with it, we can scale it up back to the actual `playbash`
codebase.

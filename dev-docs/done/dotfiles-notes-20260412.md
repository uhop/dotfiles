# dotfiles notes

My notes on this project.

## Small tasks

- Verify that we install `micro` on Red Hat via `brew`. We consistently use `micro` in our shell environment, so it should be installed. Otherwise, we have a problem.
- Let's use upd -ry for daily/weekly maintenance. See `playbash-daily` and `playbash-weekly`.
- Note that env with args defaults to the regular env. See `Shell-Environment.ms` in the wiki.
- Split the home wiki page into sections: initial setup, general information and day-to-day operations.

## Periodic tasks

What to do about periodic tasks? `cron`? Isn't it obsolete already? Anything else? I want to be notified about bad runs. Email?

We need to develop a detailed plan (ultraplan?) how to deal with it. It may be just some
information in the wiki. Or it can include some helpers (utilities?).

## Git helpers duplications

I outlined my workflow in `Workflow-git.md`. Additionally I use `gbr` to list and delete branches.
I want to keep commands in those workflows.

We have some overlap in git helpers described in `Workflow-git.md`, `Get-Configuration.md` and
`Shell-Environment.md`. There are very similar helpers, not identical, nut with a significant overlap.
We need to analyze this difference and decide what to keep and what to prune.

## rsync-based transfers

`Shell-Environment.md` defines a table of `rsync`-based transfers.

Some information is not correct: in all `r*` commands the initial "r" stands for `rsync`,
not "recursive".

Again, `cpg` is very similar to `rcp` and `mvg` is like `rmv`. We need to analyze the difference
and pick just one of two.

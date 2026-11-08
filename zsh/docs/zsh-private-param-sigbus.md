# zsh/param/private SIGBUS — `local -P` re-declared in for-loop body

Upstream bug, hit 2026-11-08 (dotfiles commits `3d24c87` → `f8e90bb`). Not yet filed
upstream — kept here until we send it to zsh-workers@zsh.org (zsh takes bugs by
mailing list only; zsh-users/zsh GitHub is a mirror).

## Repro (zsh 5.9, macOS arm64 + Fedora fc44 x86_64, 100%)

```zsh
zsh -c 'zmodload zsh/param/private; f(){ for d in a b; do local -P g=$d; done; echo survived }; f; echo rc=$?'
```

Output — prints `survived`, then exit 138 (SIGBUS) before `echo rc`:

```
f:private: can't change scope of existing param: g
survived
```

Mechanism: `local -P` = private param flag added by the zsh/param/private module
(loaded by plugins in interactive shells only — plain `zsh -c` without the module
errors `local: bad option: -P`, which masks the bug). First loop iteration declares
private `g`; second errors `can't change scope of existing param: g` and corrupts
state; function exit crashes in `unsetparam_pm` ← `endparamscope` ← `runshfunc`.

No crash: `local` without `-P` in the same loop; two sequential `local -P g=..`
declarations without a loop.

## Impact here

`zsh/znap.zsh` patch function declared `local -P f=...` inside its probe loop
(commit `3d24c87`). Every interactive shell SIGBUS/SIGSEGV'd on both macOS and
Linux — T3 Code `ctrl+`` terminal flash-close, ghostty "failed to launch the
requested command". Fix `f8e90bb`: declare locals outside the loop body.

Rule: never `local -P` (or `private`) inside a loop body.

## Draft report for zsh-workers@zsh.org

Subject: SIGSEGV/SIGBUS at function exit: `local -P` (zsh/param/private)
re-declared in for-loop body — zsh 5.9

Reliable crash on released zsh 5.9 (macOS arm64, Darwin 25; Fedora x86_64,
zsh 5.9-21.fc44), 100% reproducible. Possibly related to workers/51966 (same
crash site, `private` in loop body), which could not be reproduced on git HEAD
at the time.

```zsh
zsh -c 'zmodload zsh/param/private; f(){ for d in a b; do local -P g=$d; done; echo survived }; f; echo rc=$?'
```

Output (exit 138, SIGBUS):

```
f:private: can't change scope of existing param: g
survived
```

`survived` prints; shell crashes before `echo rc`. First loop iteration declares
the private `g`; second prints `private: can't change scope of existing param: g`
and appears to corrupt state such that scope teardown at function exit crashes.

Variants tested (no crash): `local g` without `-P` in same position;
`local -P g=1; local -P g=2` sequentially without loop; single `local -P` in a
loop body iterating once.

Stack (Fedora, coredumpctl): `unsetparam_pm` ← `endparamscope` ← `runshfunc`.

Found in the wild: zsh-autocomplete/znap startup path re-declared `local -P`
inside a loop — killed every interactive shell on both Linux and macOS.

Git HEAD untested; if already fixed there, a backport note for 5.9.x would help,
since Fedora and Homebrew ship it. Not subscribed — CC me on replies.

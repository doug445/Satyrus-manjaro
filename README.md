# Satyrus-manjaro

[![lint](https://github.com/doug445/Satyrus-manjaro/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/Satyrus-manjaro/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Free and open source](https://img.shields.io/badge/Free%20and%20open%20source-brightgreen.svg)](LICENSE)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)](#requirements)
[![Tests: 137](https://img.shields.io/badge/tests-137%20passing-brightgreen.svg)](#testing)
[![No runtime deps](https://img.shields.io/badge/runtime%20deps-pacman%20%2B%20coreutils-lightgrey.svg)](#requirements)

**Use the AUR on Manjaro without breaking your system.** A small suite of
`pacman` and `yay` wrappers that closes the three failure modes behind almost
every "Manjaro AUR disaster": the **partial upgrade** caused by Manjaro's
two-week lag behind Arch, the **stale-soname breakage** that hits every AUR
package after Manjaro finally catches up, and the **unpinned source** — a VCS
checkout with no commit, or a download with no checksum — that lets an AUR
PKGBUILD build something other than what you reviewed.

> **Not on Manjaro yet? Install [EndeavourOS](https://endeavouros.com/)
> instead, and you will never need this.** EndeavourOS is Arch — Arch's own
> repositories, on Arch's schedule — behind a friendly graphical installer.
> There is no two-week lag, so the AUR builds against exactly the libraries you
> have, and the lag that causes the two worst failures below does not exist.
> The best fix for Manjaro's AUR problem is not running Manjaro.
>
> **Already on Manjaro and staying?** Then read on. This is how you keep the
> AUR from breaking it.

**Why the name "Satyrus-manjaro"?**

In ancient Athens, the great orator Demosthenes suffered from a severe stutter, weak breath, and a debilitating inability to articulate his words. He was laughed out of the assembly until he met Satyrus, a master actor who took him under his wing. Satyrus forced Demosthenes through a brutal regimen of mechanical correction—speaking with pebbles in his mouth and shouting over the crashing surf—until his broken delivery was forged into flawless, peerless articulation.

Manjaro is my Demosthenes.

Manjaro is infamous for its "two-week delay" on syncing upstream Arch packages—a delay ostensibly meant to test for stability, but which rarely changes anything. Instead, it artificially desyncs the core system from the Arch User Repository (AUR). When you try to build an AUR package, it expects upstream Arch dependencies, chokes on Manjaro's artificially aged packages, and breaks the system.

**Satyrus-manjaro** is the mentor that fixes the stutter. It bypasses the artificial delays and dependency fractures, forcing Manjaro to correctly resolve, build, and articulate AUR packages without breaking the system.

It is six short bash scripts, no daemon, no runtime dependency beyond pacman,
coreutils, binutils and fakeroot, and 137 tests in CI, 66 of which run real
`pacman` transactions on a loop device — plus an integration suite that runs
on a real Manjaro install, against the real `chrootbuild` and the live AUR.

**Here because of an error message?** Two step-by-step guides, each usable
without installing anything:

- `error while loading shared libraries: libfoo.so.N: cannot open shared object file`
  after a Manjaro update →
  [AUR package broken after a Manjaro update](https://doug445.github.io/Satyrus-manjaro/aur-package-broken-after-manjaro-update/)
- `error: failed to prepare transaction (could not satisfy dependencies)` with
  chaotic-aur or BlackArch enabled →
  [Manjaro "could not satisfy dependencies"](https://doug445.github.io/Satyrus-manjaro/manjaro-partial-upgrade-could-not-satisfy-dependencies/)

---

## Quick start

```bash
git clone https://github.com/doug445/Satyrus-manjaro.git
cd Satyrus-manjaro
./deploy.sh
```

`deploy.sh` installs any missing dependency (asking first; a package your
repositories do not carry is skipped with a warning, not fatal), copies the six
tools into `/usr/local/bin`, installs the logrotate rule and the monthly
drift-audit timer, and stops. It also offers a yay config that keeps yay's
PKGBUILD diff menu on — a pin proves *which* source builds, only reading it
tells you what it does — and switches off the edit and clean menus. It never
replaces an existing config without showing the diff and asking. It is
idempotent: a file that already matches is not rewritten, and anything it does
replace is backed up to `<path>.bak-YYYYmmdd-HHMMSS` first.

Then use it:

```bash
safeup                 # pacman -Syu, with the partial-upgrade guard
safeup --check         # what it would do — no root, nothing changed, real DB untouched
safeup --aur           # repo upgrade, then aurupdate, then the rebuild scan
aurinstall <pkg>       # yay -S, with the pin-check gate — built in a chroot when possible
aurupdate              # yay -Sua, with the pin-check gate
aur-rebuild-check      # what needs rebuilding after a library or python bump
```

> **The protection is in the wrappers, and only there.** `pacman -Syu`,
> `yay -S`, `yay -Syu` and Pamac all still work after you install this, and
> none of them goes through a single check described on this page. Nothing
> here hooks, replaces or restricts the real package managers — on purpose,
> see [Nothing here is enforcement](#nothing-here-is-enforcement) — so the
> suite protects exactly the commands you run through it and no others. One
> `yay -Syu` out of habit is one unguarded upgrade. Alias the habit away, as
> below, and keep a bare `yay -S` for what it then is: a deliberate override.

Suggested aliases, which `deploy.sh` deliberately does **not** write for you:

```bash
alias pupdate='safeup'
alias yinstall='aurinstall'
alias yupdate='safeup ; aurupdate'
```

---

## What actually goes wrong, and what closes it

Manjaro's lag produces two failures that look unrelated and are really the same
clock running in opposite directions. A third, orthogonal risk comes from the
AUR itself.

| # | Failure | When it bites | What closes it |
|---|---|---|---|
| 1 | **Partial upgrade.** A third-party binary repo (BlackArch, chaotic-aur) rebuilt against Arch's `libfoo 2.0`. Manjaro still ships `1.0`. Installing the new package drags in a dependency Manjaro cannot satisfy. | While Manjaro is behind | `safeup` probes every pending foreign upgrade's version-constrained deps against what is installed and what the same upgrade brings in (`pacman -T`, then `pacman -Sddp`), and `--ignore`s the ones that cannot be satisfied *yet* |
| 2 | **Stale soname.** Manjaro finally ships `libfoo 2.0`. Every AUR package you built against `1.0` now fails to resolve its `DT_NEEDED` and dies at runtime — often silently, often days later. | When Manjaro catches up | `aur-rebuild-check` reads the `DT_NEEDED` entries of every AUR-owned ELF, looks each one up the way the loader would — without loading or running the file — and names the packages that need rebuilding |
| 3 | **Unpinned source.** A PKGBUILD's `source=` is `git+https://…` with no commit — or a tarball URL whose checksum is `SKIP`, which makepkg accepts and then verifies nothing. What you audited last week is not what builds today. Tags do not help — upstream can move a tag. | Any time you install or upgrade | `aur-pin-check` refuses any VCS source not pinned to an immutable revision (`#commit=<sha>` for git and fossil, `#revision=` for hg, svn and bzr), re-verifies allowlisted tags against their recorded SHA on every run, and refuses any other download that neither a real checksum nor a signature verifies |

### How honest is "solves it completely"?

Completely, for the three failures above — that is what the test suite
demonstrates, package by package. For the third, that means against a careless
or drifting maintainer, not a hostile one: see
[What the pin check cannot do](#what-the-pin-check-cannot-do). And not
completely for Manjaro in general. Read
[What this does not do](#what-this-does-not-do) before you rely on it.

---

## The tools

| Tool | Wraps | What it adds |
|---|---|---|
| **`safeup`** | `pacman -Syu` | Auto-detects foreign repos from `pacman.conf` (anything outside `core`/`extra`/`multilib`/`community` and their `-testing` variants). Judges each pending upgrade by the copy pacman will actually install — the first repo in `pacman.conf` order that carries it — and holds a foreign one whose version-constrained dependency is satisfied neither now (`pacman -T`) nor by the same upgrade (`pacman -Sddp`). The pre-flight runs against a private snapshot of the sync databases, so the real one is never refreshed without being upgraded. On `installing X breaks dependency … required by Y` for an AUR `Y`, upgrades anyway with `--assume-installed` standing in for Y's stale dependency and names `Y` for a rebuild — a repo library is never held back; if `Y` comes from a repo, stops with nothing changed. `--check` reports without root and changes nothing; `--aur` chains `aurupdate`, and the rebuild of any AUR package the upgrade broke, after a clean repo upgrade. Chains into `aur-rebuild-check` on success. Logs every hold and every needed rebuild to `/var/log/safeup.log`. |
| **`aur-rebuild-check`** | — | Reads the dynamic section of every ELF owned by every `pacman -Qmq` package (`readelf` — the file is never loaded or run) — found by magic bytes, so `/opt/<app>/<exe>` counts — and reports each `DT_NEEDED` that the object's own `RUNPATH`, `ld.so.cache` and the default library directories cannot supply. Also flags a package with files under a `/usr/lib/python3.X/` that is not the installed python's: the pure-Python breakage a soname scan cannot see. A tree whose own interpreter is still installed (`python311` from the AUR) is live, not stale. Filters the two false positives that otherwise flag `-bin` packages forever: privately bundled libraries resolved through an `$ORIGIN` RPATH, and optional sonames named in `AUR_REBUILD_IGNORE_SONAMES`. `--fix` offers `yay -S --rebuild`, after `aur-pin-check --deps` has passed the set. |
| **`aur-pin-check`** | — | Fetches `.SRCINFO` from AUR cgit (resolving a split package to its pkgbase through the RPC) and rejects any `git`/`hg`/`svn`/`bzr`/`fossil` source — in `source =` or any `source_<arch> =` — that is not pinned to an immutable revision. `#tag=` and `#branch=` are rejected on principle. Any other remote source must be verified by a real checksum or a detached signature: one whose checksums are all `SKIP` is rejected, because makepkg then checks nothing. Has a TOFU allowlist for tag-pinned upstreams. Reads the PKGBUILD too, as text, and rejects one whose source arrays name an unpinned VCS source the `.SRCINFO` hides, or whose checksum arrays say `SKIP` where the `.SRCINFO` shows a hash. `--deps` also checks every AUR dependency the build would pull in; `--from-aur` checks a name even when a binary repo carries it. Names are URL-encoded, so `aewm++` works. On rejection it tells you whether the package was deleted from the AUR, or is an installed orphan you should simply remove. |
| **`aurinstall`** | `yay -S` | Runs the pin-check gate first — on the package and every AUR dependency it pulls in — and refuses to exec `yay` if it fails. Then builds in Manjaro's own `chrootbuild` when that will work — dependency chains included, deps first — pin-checking the clones it is about to build and offering the PKGBUILDs for review first, falling back to `yay` with a stated reason when it will not, and installs the result (one `[Y/n]` away on a terminal; `--install`/`--no-install` decide for scripts). See [Building in a chroot](#building-in-a-chroot). |
| **`aurupdate`** | `yay -Sua` | Pin-checks every package with a pending AUR upgrade, and every AUR dependency those upgrades pull in, before any of them build. |
| **`remove-versioned-kernel`** | `pacman -Rns` | Evicts `linuxNN`, `linuxNN-headers` and every `linuxNN-*` extramodule that depends on the kernel (`-nvidia`, `-r8168`, `-zfs`, …) in one transaction, then prunes exactly those names from `IgnorePkg` — nothing else is touched, nothing is added. Refuses to remove the running kernel (by module-directory owner *and* by `uname -r` version) or the last one you have. |

### How the six scripts fit together

```
 UPGRADE                                   AUR INSTALL / AUR UPGRADE

 safeup                                    aurinstall <pkg>        aurupdate
   │                                           │                      │  yay -Qua
   ├─ private snapshot of the sync DBs         └──────────┬───────────┘
   │    pre-flight: pacman -T, -Sddp                      ▼
   │    unsatisfiable foreign pkg → --ignore      aur-pin-check --deps
   │                                              reads .SRCINFO and PKGBUILD
   ├─ sudo pacman -Syu                            as text; runs neither
   │    pacman refuses anything inconsistent        │
   │    — it is the backstop, not safeup            ├─ REJECT → stop, nothing built
   │                                                │
   ├─ --aur ───────────────► aurupdate              └─ pass
   │                                                    │
   └─ aur-rebuild-check                    aurinstall ──┼─► chrootbuild -b <branch>
        readelf on every AUR-owned ELF                  │    (clone, re-check the
        │                                               │     clone, build, pacman -U)
        └─ --fix ──► aur-pin-check ──► yay              └─► yay   (fallback, stated)
                                           aurupdate ──────► yay -Sua

 remove-versioned-kernel    stands alone: pacman -Rns, then the IgnorePkg line
```

Every arrow into `yay` or `chrootbuild` passes through `aur-pin-check` first.
Nothing reaches `pacman` except through `pacman` itself: the suite decides what
to ask for, and pacman decides whether the transaction is sound.

### Building in a chroot

`aurinstall --chroot` hands the actual build to
[`chrootbuild`](https://gitlab.manjaro.org/tools/development-tools/manjaro-chrootbuild),
from Manjaro's own `manjaro-chrootbuild` package (suggested on the Manjaro
forum by linux-aarhus). The two tools answer different questions:

| | Question it answers |
|---|---|
| `aur-pin-check` | **Which source** am I building? |
| `chrootbuild` | **Against which libraries**, and where? |

The second one matters specifically because of the lag. An AUR PKGBUILD assumes
current Arch; building it against your own installed libraries is what produces
a package linked to a soname Manjaro Stable does not have. `chrootbuild` builds
inside a chroot synced to a chosen Manjaro branch, so the result links against
the libraries you actually run — a **build-time** fix for the breakage
`aur-rebuild-check` can only report after the fact. Build dependencies land in
the chroot and never touch your system.

```bash
aurinstall <pkg>              # auto: chroot when it will work, else yay
aurinstall --chroot <pkg>     # force the chroot; refuse rather than fall back
aurinstall --no-chroot <pkg>  # force plain yay
aurinstall --chroot --clean <pkg>   # recreate the chroot from scratch first
aurinstall --install <pkg>    # chroot mode: install the result without asking
aurinstall --no-install <pkg> # chroot mode: build only, keep the package
```

**The chroot is the default when it will work.** A gate checks three things
first, and falls back to `yay` — always saying which one tripped — rather than
failing:

- `manjaro-chrootbuild` is not installed.
- The dependency chain will not build — there is a cycle, or the chain is
  deeper than `AURINSTALL_MAX_CHAIN` (10). A member missing from the AUR
  altogether (a dead source: no build order fixes that) is refused earlier,
  by the pin check, on every path. **Resolvable chains are built**, deps
  first, as one `chrootbuild` run chained with `-n`
  (`-p dep2 -n -p dep1 -n -p target`), and every chained dependency is
  pin-checked exactly like a named target — in the clone that is about to
  build — because an unvetted dep is the same supply-chain hole as an unvetted
  target. The `-n` form was posted on the Manjaro forum by linux-aarhus, as was
  the failure case the resolver refuses on.
- The package is a `*-bin`. Nothing is compiled, so a chroot cannot change what
  gets installed. It *would* still isolate the PKGBUILD's own execution — a
  real if smaller benefit — so `--chroot` forces it anyway if you want that.

On a survey of one real system's 49 AUR packages, 42 were chroot-eligible, 7
had AUR dependencies and 1 was a `-bin`. The fallback is never silent: a tool
that quietly does something other than what you assumed is the failure mode
this whole suite exists to prevent. `--chroot` makes it an error instead, and
`AURINSTALL_MODE=auto|chroot|yay` sets the default.

The wrapper also files down two sharp edges:

- **`chrootbuild`'s default branch is `unstable`.** Passing the wrong branch
  still exits 0 and silently produces exactly the mismatch you were avoiding.
  `aurinstall` always passes an explicit `-b`, detected from
  `pacman-mirrors --get-branch` (override with `AURINSTALL_BRANCH`).
- **`chrootbuild` has no AUR dependency resolution.** `aurinstall` reads
  `.SRCINFO` first, computes the build order itself, and refuses up front —
  naming the reason — only when the chain cannot resolve.

After the build, the result is installed with `pacman -U`: that is what you
asked for when you typed `aurinstall`. On a terminal it is one `[Y/n]` prompt
away, so you can stop and inspect first; `--install` and `--no-install` settle
it without a prompt. With `PKGDEST` unset, the built package is kept in the
directory you ran from, so a declined install can still be applied later.

`manjaro-chrootbuild` lives in Manjaro's `extra` and `deploy.sh` installs it
along with everything else. If it is missing, the gate says so and falls back to
`yay` rather than failing.

### Why `.SRCINFO` and not `PKGBUILD`

`aur-pin-check` reads `.SRCINFO`, which is the post-evaluation, static form of a
PKGBUILD. Parsing it means vetting an untrusted package name never executes that
package's code. A pin-checker that sourced the `PKGBUILD` to read `source=`
would be running the thing it was asked to decide about.

### Why `#tag=` is rejected

A tag is a mutable pointer. Upstream can move it, or a compromised or careless
maintainer can move it silently. If you genuinely need a tag-pinned package,
the allowlist records the SHA that tag pointed at **when you vetted it**, and
`aur-pin-check` re-resolves the tag with `git ls-remote` on every run. The day
it stops matching, the package is refused. Trust on first use, verified
forever after — never blanket trust.

```
# /etc/aur-pin-check/allowlist.conf
# <pkg>  <exact source spec from .SRCINFO>  <expected 40-hex SHA>
byobu  git+https://github.com/dustinkirkland/byobu#tag=7.17  cd6dfa0e4918573e03d9881c7750640693c2d15f
```

### Why `SKIP` is rejected

`sha256sums=('SKIP')` is makepkg's way of saying "do not check this source". It
exists for VCS sources, where there is no file to hash and the commit pin is
the integrity. makepkg accepts it for any source, though, and a tarball URL
under `SKIP` is then exactly as mutable as an unpinned branch: the server can
send something different tomorrow and the build will not notice. Up to 1.7.0
that walked through the gate, on the stated ground that "sha256sums cover it".

A remote source now has to be verified by something: a real checksum at its own
position, in the array for its own architecture, or a detached signature
(`.sig`, `.sign`, `.asc`) listed beside it, which makepkg checks and refuses
the build without. `cksums` does not count — it is a CRC. A local file is not a
download: it ships in the AUR repository next to the PKGBUILD and is read with
it. There is no allowlist row for this one, because a moving download has no
revision to record; if you have read the PKGBUILD and want it anyway, the
override is the same as ever — `yay -S <pkg>`, on purpose.

---

## Security model and limitations

Three checks, each of which reads and decides and then gets out of the way:
`safeup` reads the sync databases, `aur-rebuild-check` reads ELF headers,
`aur-pin-check` reads `.SRCINFO` and the PKGBUILD as text. None of them runs
what it inspects, and none of them is the last word — pacman is, for
transactions, and you are, for PKGBUILDs.

### Nothing here is enforcement

These are wrappers. They sit in `/usr/local/bin` beside the real tools and add
checks to the commands you run **through them**. They do not hook pacman, do
not replace `yay`, and do not stop anything:

| You run | What checks it |
|---|---|
| `safeup`, `aurinstall`, `aurupdate`, `aur-rebuild-check --fix` | everything on this page |
| `pacman -Syu`, `pacman -S <pkg>` | pacman's own dependency resolution; no partial-upgrade pre-flight, no rebuild scan |
| `yay -S <pkg>`, `yay -Syu`, `yay -Sua` | nothing here — no pin check, no checksum check, no chroot |
| Pamac ("Add/Remove Software"), with or without its AUR switch | nothing here |
| any other AUR helper, or `makepkg -si` in a clone | nothing here |

That is a decision, not an oversight. A gate that could not be bypassed would
have to own the package manager, and a tool that owns the package manager is a
tool you cannot repair the package manager with. A gate you can step around —
by typing the real command, knowing that you are — is one you will leave
installed. So the bypass stays, and the cost is yours to manage: **the suite is
exactly as consistent as your use of it.** Use the aliases from
[Quick start](#quick-start), and if Pamac is on the machine, leave its AUR
switch off.

### "But this automates `pacman --ignore`"

It does, and that deserves a real answer rather than reassurance. `--ignore` is
listed on the Arch wiki as a way to **cause** partial upgrades, so a tool that
reaches for it automatically is right to be treated with suspicion.

**`--ignore` suppresses an upgrade. It does not suppress dependency
resolution.** pacman still resolves the entire transaction and refuses one that
would leave a dependency unsatisfied. Here is that being tested rather than
asserted — `consumer 1.0` requires `libX=1.0`, both have upgrades pending, and
`libX` is ignored so that `consumer 2.0` would need a `libX 2.0` that will not
be installed:

```console
$ pacman -Syu --noconfirm --ignore libX
warning: ignoring package libX-2.0-1
warning: cannot resolve "libX=2.0", a dependency of "consumer"
error: failed to prepare transaction (could not satisfy dependencies)
:: unable to satisfy dependency 'libX=2.0' required by consumer
                                                            exit 1

$ pacman -Q                       # nothing moved
consumer 1.0-1
libX 1.0-1

$ pacman -Dk                      # pacman's own consistency audit
No database errors have been found!
```

You cannot `--ignore` your way into an unsatisfied dependency. **pacman is the
backstop, not this script** — which is the correct arrangement, because pacman
is the thing that actually knows.

That transcript is section 19 of
[`tests/loopback-core-test.sh`](tests/loopback-core-test.sh) and runs in CI on
every push, against real pacman transactions. It is deliberately a test of
*pacman's* behaviour rather than of this code: the safety argument for the whole
suite rests on that property, nothing here would notice if a future pacman
changed it, and the consequence would be silent. The same section then asserts
that a real `safeup` hold inherits it — `pacman -Dk` still reports a consistent
system afterwards.

Beyond that guarantee, **what** gets held matters:

- It only holds a package from a **foreign** repo whose version-constrained
  dependency is **already unsatisfiable** — one that cannot install correctly
  at that moment regardless. A Manjaro repo package is never held.
- It holds the **new** version back, so the package keeps the dependencies it
  already had and stays in the state it was already working in. The classic
  dangerous pattern is pinning a *library* while upgrading its dependents; this
  is the opposite direction.
- When a Manjaro upgrade breaks an **AUR** package's dependency
  (`installing X breaks dependency … required by Y`), the library still goes
  ahead. The repo upgrade lands in full, with `--assume-installed` standing in
  for Y's stale dependency, and Y is named for a rebuild; `safeup --aur`
  rebuilds it straight away. The AUR package is the one that is out of date,
  so it is the one left broken until it is rebuilt. If Y comes from a repo,
  the mirrors disagree mid-sync: nothing changes and `safeup` says to wait.
  (Up to 1.5.0 this path held the library — the very pattern above.)
- The realistic alternative is not a clean full upgrade. It is a refused
  transaction, or a person reaching for `--ignore` by hand with worse aim.
- Every hold, and every AUR package left needing a rebuild, is printed and
  written to `/var/log/safeup.log`. A silent
  indefinite pin is the real long-term hazard, so a hold is made into a
  *deferred* upgrade you can chase rather than a package that quietly stops
  updating.

**The limitation, stated plainly:** `safeup` does not pre-check whether a
package it holds is itself required by something else in the same transaction.
It relies on pacman refusing, and then acts on pacman's own message. The transcript above
is why that is acceptable — but it works that way because pacman is sound, not
because this script is clever, and you should know which of those you are
trusting.

### What this does not do

Stating this plainly is the point of the section. This suite is narrow on
purpose, and a tool that oversells itself is worse than no tool.

- **It does not make Manjaro track Arch.** The lag is Manjaro's design choice.
  This handles the consequences; it does not remove the cause. If you want
  Arch's timing, run Arch — or [EndeavourOS](https://endeavouros.com/), which
  is Arch with an installer.
- **It does not audit what a PKGBUILD *does*.** Pinning proves you will build
  the same commit you reviewed. It says nothing about whether that commit is
  malicious. Read the PKGBUILD.
- **It does not sandbox builds by default.** `makepkg` runs upstream's build
  system on your machine with your user's privileges. `aurinstall --chroot`
  moves the build into an isolated chroot (see below), which is a real
  improvement in blast radius and in *which libraries you link against* — but a
  chroot is build isolation, not a security boundary, and it does not make a
  hostile PKGBUILD safe.
- **It cannot fix a package that genuinely needs a newer library.** Holding it
  is the correct outcome, not a workaround — you wait for Manjaro, or you
  rebuild from source, or you get it from somewhere else.
- **It does not replace backups or snapshots.** A held package is a deferred
  upgrade, not a rollback.
- **A package deleted from the AUR still serves its old git repo through cgit,
  indefinitely.** `aur-pin-check` warns you when a rejected package is no longer
  in the AUR index, because in that case the "just override it" advice is
  actively dangerous — the PKGBUILD you are about to trust may be years stale.

### What the pin check cannot do

Up to 1.5.0 the gate skipped repo-carried names that the chroot then built from
the AUR, never checked AUR dependencies on the yay path, trusted `.SRCINFO`
without looking at the PKGBUILD, and could not fetch a name with a `+` in it.
1.6.0 closes all four, with a test for each that fails against 1.5.0. Up to
1.7.0 a tarball passed on the assumption that its checksum array held a
checksum; `SKIP` there verifies nothing, and 1.8.0 refuses it. What is left is
what no static check can close:

- **A hostile maintainer.** The PKGBUILD is now read too, and a `.SRCINFO`
  that hides an unpinned source from it is refused. But a PKGBUILD is code: one
  that assembles its URL at run time, or does its damage in `build()`, passes
  any check that does not run it. That is why yay's diff menu is back on and
  `aurinstall` offers the PKGBUILDs (`v`) before a chroot build. Read them.
- **The yay path's window.** The gate reads the AUR, then yay fetches it
  again. A push in between is built unseen. The chroot path has no such
  window: it checks the clone it is about to build.
- **A weak checksum.** `md5sums` and `sha1sums` count as verification, because
  makepkg treats them as such and forging a file to match an existing digest
  is still out of reach for either. They are not what you would choose today.
- **A dependency only another AUR package provides.** It cannot be resolved by
  name, so it is refused, with a hint: install the provider first, then retry.

---

## Requirements

**Manjaro.** This is scoped to Manjaro deliberately: the problem it solves is
created by Manjaro's Stable branch trailing Arch, and `aurinstall --chroot`
wraps `manjaro-chrootbuild`, which is Manjaro's own tool. On Arch itself there
is no lag to guard against, and none on EndeavourOS, which uses Arch's
repositories directly.

Runtime dependencies are `pacman`, `curl`, `git`, `awk`, `coreutils` and
`readelf` from `binutils` — all of which a Manjaro install already has — plus
`fakeroot` (from `base-devel`) for `safeup --check`'s no-root database snapshot, `logrotate` for
the log rotation, `libnotify` for the drift-audit notification, `yay` for
`aurinstall` and `aurupdate`, and **`manjaro-chrootbuild`**, which `aurinstall`
uses to build by default.

`deploy.sh` installs whatever is missing, after asking. `manjaro-chrootbuild` is
24 KiB with no dependencies of its own — the ~1.1 GiB chroot it manages is
created lazily under `/var/lib/chrootbuild` on your first build, not at install
time.

Everything is bash. There is no language runtime to install, which is
deliberate: a tool that repairs a broken package manager cannot depend on
packages installed by that package manager.

---

## Testing

Three suites. Two are hermetic — 137 assertions, run in CI on every push. The
third is the opposite on purpose: it runs on a real Manjaro install.

```bash
bash tests/pin-fixture-test.sh            # 71 assertions — no root, no disk, no network
sudo bash tests/loopback-core-test.sh     # 66 assertions — root; touches no real disk
bash tests/manjaro-integration-test.sh    # 11 assertions — Manjaro only; no root, changes nothing
bash tests/manjaro-integration-test.sh --build   # 14 — adds one real chroot build (sudo)
shellcheck -S warning $(git ls-files '*.sh') bin/*
```

**`tests/loopback-core-test.sh`** builds a 512 MB file-backed loop device,
formats it ext4, and constructs a complete throwaway `pacman` root inside it:
private `RootDir`/`DBPath`/`CacheDir`, private `file://` repositories built with
the real `repo-add`, and real `.pkg.tar.gz` packages. It then drives the real
`pacman` through the actual scenarios — a foreign package with an unsatisfiable
`libfoo>=2.0`, an `installing X breaks dependency … required by Y` transaction,
an unrecoverable failure — and asserts on installed versions afterwards. The
`aur-rebuild-check` cases build genuine shared objects with `cc` that carry a
genuine unresolvable `DT_NEEDED` — and one section puts a recording `ldd` first
on `PATH` and asserts it is never called.

**No real disk and no real package database is touched.** The only thing on
`PATH` is a wrapper that adds `--config <throwaway config>`; dependency
resolution, ABI-break detection and file ownership are all done by the genuine
pacman.

**`tests/pin-fixture-test.sh`** exercises the pinning policy against synthetic
`.SRCINFO` fixtures and the allowlist against **real local git repositories** —
including moving a tag and asserting that the next run refuses the package.

**`tests/manjaro-integration-test.sh`** covers what the other two cannot. CI's
loopback job runs in an Arch container, because that is what GitHub can run;
it proves pacman's behaviour and this code's, but it never meets Manjaro's own
`pacman.conf`, `pacman-mirrors`, the `manjaro-chrootbuild` Manjaro actually
ships, or the live AUR — and every fixture stubs exactly those. This suite
runs on a real Manjaro install, as an ordinary user, and changes nothing. It
checks that branch detection answers with a branch `chrootbuild` accepts; that
the installed `chrootbuild` still takes the flags `aurinstall` passes; that on
the real `pacman.conf` a repository is called foreign exactly when it is not
served from the install's Manjaro branch; that `safeup --check` completes
against the real mirrors and leaves the real sync databases byte-for-byte
alone; that `aur-rebuild-check` scans every foreign package installed without
`ldd` running once; and that the gate, against the live AUR, passes a
checksummed release, rejects a `-git` package, and errors on a name that does
not exist. With `--build` it also drives the **real** `chrootbuild` to a
finished package — from a local stand-in for the AUR holding one trivial
PKGBUILD, so no upstream code is fetched — and confirms the chroot is on the
branch the install runs rather than `chrootbuild`'s default of `unstable`.

It is not in CI, and that is stated rather than papered over: there is no
maintained Manjaro container to run it in (`manjarolinux/base` was last built
in March 2026), and a stale image would test a Manjaro months out of date. Run
it on a Manjaro install before a release. It refuses to run anywhere else,
rather than skipping its way to "0 failed".

A check that cannot run in a given environment is reported as `SKIP` and is
never counted as a pass. A silent pass is the one outcome these suites exist to
prevent.

---

## Source-of-record layout

```
Satyrus-manjaro/
├── bin/                              → /usr/local/bin/ (root:root 0755)
│   ├── safeup                        pacman -Syu with the partial-upgrade guard
│   ├── aur-rebuild-check             post-upgrade soname scan
│   ├── aur-pin-check                 VCS source pinning policy
│   ├── aurinstall                    yay -S + gate
│   ├── aurupdate                     yay -Sua + gate
│   └── remove-versioned-kernel       kernel eviction with guards
├── etc/
│   ├── logrotate.d/safeup            → /etc/logrotate.d/safeup
│   └── aur-pin-check/allowlist.conf  → /etc/aur-pin-check/ (never overwritten)
├── config/yay/config.json            → ~/.config/yay/config.json (asked before replacing)
├── systemd/user/                     → ~/.config/systemd/user/ (monthly drift audit)
├── tests/                            the three suites above
├── docs/WHY.md                       the case against Manjaro's release model
├── audit-drift.sh                    run in place — never deployed
└── deploy.sh                         idempotent installer
```

`audit-drift.sh` checksums each source file against its deployed copy and
notifies if they diverge, catching the case where someone edits
`/usr/local/bin/safeup` directly and the change is later lost to a redeploy. The
allowlist and the yay config are deliberately excluded from that audit: the
allowlist holds *your* vetting decisions and is supposed to diverge, and the yay
config is a preference `deploy.sh` asks before replacing.

---

## Why Manjaro's release model creates these problems

The AUR assumes you are current with Arch. Manjaro's Stable branch deliberately
is not: it trails Arch by about two weeks, while the AUR does not trail at all.
Third-party repositories and AUR PKGBUILDs are built for an Arch that a Manjaro
user will not have for another fortnight; things break in the gap, in one
direction while Manjaro is behind and in the other when it catches up. Manjaro
ships AUR support in its own package manager and documents the result as "your
own risk and your own responsibility". Nobody supports the gap. **This suite is
the gap, handled.**

The full argument — the quotations, Manjaro's record with the AUR and with its
own certificates, and who answers for it — is in
[docs/WHY.md](docs/WHY.md).

---

## Disclaimers

**Not for beginners.** Everything here wraps `pacman` or `yay` and assumes you
can read a PKGBUILD, know what a partial upgrade is, and can recover your own
system if something goes wrong.

**Not affiliated with Manjaro.** This is a personal project. Nothing about it
is endorsed by, or represents, the Manjaro team — it uses Manjaro's own
`manjaro-chrootbuild` as one of its tools, and that is the extent of the
relationship. It does not make the AUR supported, by anyone.

**AI disclosure.** CI and loopback tests designed and authored by Claude. The CI
suite — real pacman transactions against throwaway loop devices — exists
precisely so that correctness never rests on anyone's word, the author's or a
model's.

## Contributing

Serious bugs only — see [CONTRIBUTING.md](CONTRIBUTING.md). Security issues go
to the address in [SECURITY.md](SECURITY.md), not to the issue tracker.

## License

MIT — see [LICENSE](LICENSE).

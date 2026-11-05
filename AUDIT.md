# Audits

## 2.0.0: full adversarial audit

**Audit and fixes by Claude Opus 5.5 at maximum effort ("Opus Max"), 5 November
2026.** Every line of the suite was in scope: the six tools, `deploy.sh`,
`audit-drift.sh`, the systemd units, CI, and the tests themselves.

| | |
|---|---|
| Baseline | v1.8.0, commit `38c6b86`, frozen before the first finding |
| Findings | **62**: 3 critical, 18 high, 19 medium, 22 low |
| Fixed in 2.0.0 | 59, and 3 partly: what remains of those is under [What is left](#what-is-left) |
| Tests | 271 in CI, up from 137. 105 of them fail against 1.8.0 |
| On real Manjaro | 15 of 15, including a real `chrootbuild` build |
| Real AUR packages | 699 compared: 6 true catches, 0 false alarms |
| CVE-form findings | 15, of which 8 high: [below](#findings-in-cve-form) |

The audit before this one, for 1.8.0, was done by Claude Fable 5.1, Anthropic's
most capable generally available model. It verified and fixed the four
priorities of an external review. This one found 62 defects, several of them in
code 1.8.0 had just added.

### How it was done

Adversarial means each part of the suite was attacked rather than read for
style, and a finding counted only once it had been reproduced.

- **Two independent reviewers** worked through a frozen copy, split between the
  AUR gate and everything else. They were told what counts as a defect and were
  not told what had already been suspected, so neither could simply confirm it.
  Both were instances of the same model, which is worth knowing: it makes them
  independent of this audit's working notes, not of its blind spots.
- **Real tools, not mocks.** Findings were proven with makepkg's own functions
  (`get_uri_fragment`, `download_git`, `extract_git`, `check_pgpsigs`), real
  pacman in throwaway roots, real yay, and real ELF files.
- **The reviewers' exploits were rerun** against the fixed tree, 14 scripts from
  the gate review and the safeup, kernel and `deploy.sh` ones from the other.
  An exploit counted as stopped only if it was stopped by the fix. Refusals for
  an unrelated reason were found and the fixtures corrected until every one
  reached the check it was aimed at, and every honest control passed.
- **Mutation testing.** 52 mutants were run against the 1.8.0 suites and 29
  survived, which is what showed which behaviour had no test. Three more were
  written for the new loader check: `ld.so --list`, an absolute `ldd`, and plain
  execution. All three are caught. One of them was not at first: the test
  itself had a blind spot, and that was fixed too.
- **Measured on real packages.** The new PKGBUILD comparison was run over 699
  packages from the AUR, the 350 most popular plus a random 349 of the rest.
  Each of the 6 it newly refused was read by hand, and all 6 are real.
- **Four toolchains.** This Manjaro Stable install (bash 5.3.20, gawk 5.4.1,
  pacman 7.1.0), CI's Arch container and Ubuntu runners, an Ubuntu VM, and CI's
  exact bash 5.2.21 and mawk 1.3.4 20240123, run by hand before pushing.

### Findings in CVE form

These are written the way a CVE record is, so they can be compared and filed.
**No CVE IDs have been requested or assigned**, and the `SAT-2026` numbers are
this project's own. Every one affects all releases up to and including 1.8.0 and
is fixed in 2.0.0, except where [What is left](#what-is-left) says otherwise.
Scores are CVSS 3.1 base scores, computed from the vectors shown.

| ID | Finding | CWE | CVSS 3.1 | Vector |
|---|---|---|---|---|
| SAT-2026-001 | Pin check accepts sources makepkg resolves to a moving ref | CWE-436 | 8.0 High | `CVSS:3.1/AV:N/AC:L/PR:L/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-002 | Remote download under `SKIP` passes as a local file (`https+lp:`) | CWE-436 | 8.0 High | `CVSS:3.1/AV:N/AC:L/PR:L/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-003 | Downloads credited with a signature that never checks them | CWE-347 | 8.0 High | `CVSS:3.1/AV:N/AC:L/PR:L/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-004 | Repo group read as a satisfied dependency: an unpinned AUR dependency is never walked | CWE-697 | 8.0 High | `CVSS:3.1/AV:N/AC:L/PR:L/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-005 | Moved allowlisted tag accepted when a decoy ref answers `ls-remote` first | CWE-697 | 7.5 High | `CVSS:3.1/AV:N/AC:H/PR:N/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-006 | Split package judged on a stale cgit branch of its name, not its live pkgbase | CWE-345 | 7.5 High | `CVSS:3.1/AV:N/AC:H/PR:N/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-007 | PKGBUILD may differ from its `.SRCINFO` in URL, checksum or signing key | CWE-345 | 7.1 High | `CVSS:3.1/AV:N/AC:H/PR:L/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-008 | A 200 reply that is not a `.SRCINFO` passes as a package with no sources | CWE-754 | 7.1 High | `CVSS:3.1/AV:A/AC:H/PR:N/UI:R/S:U/C:H/I:H/A:H` |
| SAT-2026-009 | A stand-in for an AUR package also hides a repository inconsistency | CWE-754 | 5.9 Medium | `CVSS:3.1/AV:N/AC:H/PR:N/UI:R/S:U/C:N/I:L/A:H` |
| SAT-2026-010 | The chroot path builds a deleted AUR repository over a repo package | CWE-345 | 5.3 Medium | `CVSS:3.1/AV:N/AC:H/PR:N/UI:R/S:U/C:N/I:H/A:N` |
| SAT-2026-011 | A broken `awk`, `grep` or `readelf` reads as a clean result | CWE-252 | 4.7 Medium | `CVSS:3.1/AV:L/AC:H/PR:N/UI:R/S:U/C:N/I:H/A:N` |
| SAT-2026-012 | The running kernel can be removed after an in-place upgrade | CWE-697 | 4.2 Medium | `CVSS:3.1/AV:L/AC:L/PR:H/UI:R/S:U/C:N/I:N/A:H` |
| SAT-2026-013 | A system upgrade proceeds on end of file or an unrecognised answer | CWE-754 | 3.9 Low | `CVSS:3.1/AV:L/AC:L/PR:L/UI:R/S:U/C:N/I:L/A:L` |
| SAT-2026-014 | Escape sequences from a `.SRCINFO`, an ELF or a sync database reach the terminal | CWE-150 | 3.5 Low | `CVSS:3.1/AV:N/AC:L/PR:L/UI:R/S:U/C:N/I:L/A:N` |
| SAT-2026-015 | Needed rebuilds go unreported and unlogged | CWE-778 | 3.3 Low | `CVSS:3.1/AV:L/AC:L/PR:N/UI:R/S:U/C:N/I:L/A:N` |

The vectors assume the realistic attacker: `PR:L` is someone who can push to an
AUR package, and `PR:N` someone who controls an upstream repository, a mirror, or
the network path. `UI:R` is you installing or upgrading. The high scores for the
gate reflect what it is for: when it is wrong, code nobody reviewed gets built.
A hostile maintainer can also simply write a hostile PKGBUILD, which the README
has always said no static check can stop. What these bypasses add is a package
that passes as pinned while it is not, which is exactly what you would then not
go and read.

The worst of them, SAT-2026-001, was shown end to end: the gate accepted the
source, and makepkg's own `download_git` and `extract_git` then checked out the
branch tip instead of the pinned commit. SAT-2026-006 was live on the real AUR:
`aur-pin-check xen-docs` passed by judging a deleted 4.8.0 tarball, while the
package of that name today is built from a git branch.

### Known CVEs in what the suite runs on

From `arch-audit` on this install, 5 November 2026, for the suite's runtime
dependencies. None of these is reachable through the suite.

| Package | Advisory | Why it does not apply here |
|---|---|---|
| `coreutils` 9.12 | CVE-2025-5278 | `sort` with a traditional `+N` key. The suite never gives `sort` a key |
| `openssl` | CVE-2022-2068, CVE-2025-4575 | The `c_rehash` script and `openssl x509 -addreject`. The suite runs neither |
| `systemd` | CVE-2025-4598 | `systemd-coredump`. Nothing here touches it |

`pacman`, `curl`, `git`, `gawk`, `binutils`, `fakeroot`, `bash`, `sudo`, `glibc`,
`gnupg` and `libarchive` have no open advisory. This is a snapshot: run
`arch-audit` for your own.

### What was found

**The AUR gate (`aur-pin-check`, `aurinstall`, `aurupdate`).**

| Severity | Finding |
|---|---|
| Critical | A pin was searched for anywhere in the string, so `#commit=<sha>?=main`, `#branch=main?#commit=<sha>` and a `#` in the filename prefix all passed, and built a moving ref |
| Critical | A split package name was judged on any stale cgit branch of that name instead of its live pkgbase |
| Critical | A moved allowlisted tag was accepted if a decoy ref matched the `ls-remote` pattern first |
| High | `#commit=<64-hex>` is a tag name on a SHA-1 repository, and tags move |
| High | `https+lp:…` under `SKIP` passed as a local file. makepkg downloads it |
| High | Downloads were credited with signatures that never check them: another architecture's, a VCS entry named `.sig`, a second compression |
| High | The `SKIP` tripwire missed tabs, `cksums`, swapped positions, `;` and subscript forms |
| High | Unpinned VCS sources in a PKGBUILD could hide behind literal forms the scanner missed, or behind an allowlist count |
| High | Any 200 reply passed as a `.SRCINFO`, including an HTML page |
| High | A broken `awk`, `grep` or `cut` passed packages by reading nothing |
| High | A repo group read as a satisfied dependency, so yay's AUR package of that name went unchecked |
| High | `aurinstall ripgrep` handed `chrootbuild` a deleted AUR repository at 0.1.15, when the repo has 15.2.0 |
| High | `SKIP ` with a trailing space counted as a checksum |
| Medium | `aurupdate` said "no AUR upgrades pending", exit 0, when it could not reach the AUR |
| Medium | `aurupdate` passed arguments to yay that the gate never saw |
| Medium | `--no-install` was broken by a yay fallback, `AURINSTALL_MODE=chroot` fell back anyway, and `--chroot` refused a `-bin` it is documented to force |
| Medium | AUR makedepends and split siblings you did not ask for reached the host |
| Medium | A `.SRCINFO` value was cut at ` = ` |
| Low | Rebuilding the same version with `PKGDEST` set failed with "no package produced" |
| Low | A later argument could reach pacman as an option |
| Low | The allowlist was keyed on the name, though documented as the pkgbase |
| Low | `awk -v` decoded backslashes, so a row could match a different spec |
| Low | A dependency on a split sibling read as a cycle |
| Low | False refusals: a pin behind `${x:+…}`, `libgit+extras.tar.gz`, a local `git+https-fix.patch`, conditional arrays counted twice, another architecture's arrays and dependencies |
| Low | An RPC error reply, which also says `resultcount:0`, read as a deleted package |
| Low | `--install` promised no prompt, and pacman asked anyway |

**The upgrade (`safeup`).**

| Severity | Finding |
|---|---|
| High | A stand-in for an AUR package also hid a repository inconsistency: the transaction committed, and `pacman -Dk` found the damage |
| High | A second AUR package on the same stale dependency was dropped, from the terminal, the log and the rebuild |
| High | The master prompt upgraded on Ctrl-D, `NO`, `nope` and `q` |
| High | An exported `COLUMNS` lost holds: pacman wraps even into a pipe |
| High | What the rebuild scan found never reached the log, and a missing scan said nothing |
| Medium | Both recovery paths depended on the locale |
| Medium | The pre-flight said "safe to apply" and pacman then refused the whole run: a satisfier in `IgnorePkg`, `libfoo<2` broken by the same upgrade, a new dependency's constraint, a foreign `replaces`, an unversioned dependency, a hold cascade |
| Medium | Failed pre-flight queries counted as a pass: a garbage sync database read as "nothing pending" |
| Medium | A failed log write was ignored, and a declined run still logged a hold |
| Medium | Ctrl-C mid-commit read as success, because pacman exits 0, and `--aur` then built on it |
| Low | An escape sequence in a sync-database dependency reached the terminal |
| Low | The "(or: safeup --aur, next time)" hint did nothing |
| Low | The suggested `yupdate` ran `aurupdate` after a failed upgrade |

**The rebuild scan (`aur-rebuild-check`).**

| Severity | Finding |
|---|---|
| High | A failed inspection counted as clean: a dead `readelf` reported "all satisfied" |
| Medium | "Needs rebuild" was advice nobody had checked. It told you to rebuild packages that have no source, and `-bin` packages a rebuild cannot change |
| Medium | A plugin needing what its host provides was flagged forever: a perl module and `libperl.so`, on this install, through every rebuild |
| Medium | `--fix` refused the whole set over one package |
| Medium | A text file or dangling symlink named like the soname excused a binary that cannot start |
| Medium | `/opt/app/usr/lib/python3.9/` was flagged as a stale tree |
| Medium | An `&` in a directory broke `$ORIGIN` on bash 5.2 and later |
| Low | The terminal sanitiser depended on the locale |

**`remove-versioned-kernel`.**

| Severity | Finding |
|---|---|
| High | The running-kernel guard missed the kernel you are on after an upgrade without a reboot |
| Low | A missing UKI directory printed "ok" |
| Low | A whitespace-only difference rewrote `pacman.conf` and took a backup |
| Low | A surviving kernel's UKI was listed under "should not exist" |

**`deploy.sh`, `audit-drift.sh` and CI.**

| Severity | Finding |
|---|---|
| High | Every `deploy.sh` prompt was invisible: `read -p` prompts on stderr, and stderr was silenced |
| Medium | A backup in `/etc/logrotate.d` broke logrotate on every run from then on |
| Low | Checkout paths containing `&`, `\|` or a space produced broken units or failed halfway |
| Low | Two backups in one second overwrote each other |
| Low | A symlinked deployed file reported "(mode fixed)" on every run, and a world-writable allowlist was left alone |
| Low | The drift audit did not cover the timer |
| Low | CI's checkout action was on a mutable tag, in a project that exists to refuse those |

**The tests.**

| Severity | Finding |
|---|---|
| Medium | "Never handed to the dynamic loader" could only catch an `ldd` found on `PATH`. Running every ELF passed the suite |
| Medium | Three assertions passed for the wrong reason, and integration M6 passed when the check it guards had not run |
| Low | The fixture suite read `~/.gitconfig`, so a `commit.gpgsign` there failed it |
| Low | A header claim did not match the assertion below it |

### Suspected, and disproved

Worth recording, because the checks were real and the answer was no.

- **Shell injection from a hostile ELF.** `(( memo[$key|$soname] ))` takes a
  string from a file nobody vouches for, and this shape of bash has run embedded
  commands before. It does not on bash 5.2.21, 5.3.9 or 5.3.20, tested directly on
  each, and on 5.3.20 with real ELF files carrying payloads as `DT_NEEDED`. It was
  replaced with a plain string comparison anyway, and a regression test keeps the
  payload as text.
- **Code execution from `.SRCINFO` or PKGBUILD text.** No path found. There is no
  `eval` or `source`, and nothing from either file is ever used as a regular
  expression.
- **`pkgbase = ../x`** fails closed. The pkgbase now comes from the AUR's index
  and has to match, so it never reaches a path unchecked.
- **`config/yay/config.json`.** Clean. makepkg's signature checks do run on both
  the yay and the chroot paths.

### What is left

Stated plainly, and also in the README.

- **A hostile PKGBUILD.** It is code. One that builds its URL at run time passes
  any check that does not run it. Read it.
- **A file shipped beside a signature.** makepkg verifies the first file it finds
  for a signature, which can be one outside `source=`. This part of SAT-2026-003
  is not fixed: a check reading `.SRCINFO` cannot see it.
- **SHA-256 git repositories.** On one, `#commit=<40-hex>` is a ref name, which
  could be a tag. This part of the 64-hex finding is not fixed. No package in the
  sample pins a 64-hex commit.
- **hg and fossil.** Neither is installed here, so their fragment handling was
  shown through makepkg's parsing and stubbed binaries, not real repositories.
- **A package pacman will not let go.** A foreign package that a Manjaro upgrade
  breaks, or a Manjaro package that needs something held, stops the run with
  nothing changed. A Manjaro package is never held back, so the run stays stopped
  until the repositories agree. This part of the pre-flight finding is by design.
- **The yay window.** The gate reads the AUR, then yay fetches it again.
- **The integration suite is not in CI.** No maintained Manjaro image exists.

## 1.8.0: review audit and fix

**By Claude Fable 5.1, Anthropic's most capable generally available model.**

An external review of 1.7.0 raised four priorities. Each was checked against the
code first, and all four held:

1. `aur-rebuild-check` ran `ldd` on untrusted binaries. It now reads ELF files
   with `readelf` and resolves their libraries itself.
2. A tarball with checksum `SKIP` passed the gate. It no longer does.
3. Nothing tested on real Manjaro. `tests/manjaro-integration-test.sh` does.
4. The README buried installation and did not say the wrappers can be bypassed.

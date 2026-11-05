#!/bin/bash
#
# Satyrus-manjaro — safe pacman/AUR updates on Manjaro
# https://github.com/doug445/Satyrus-manjaro
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ============================================================================
# loopback-core-test.sh — exercise the upgrade gate against REAL pacman
# transactions inside a throwaway package root on a file-backed loop device.
#
# NO REAL DISK AND NO REAL PACKAGE DATABASE IS TOUCHED. Everything happens on
# a loop-mounted ext4 image under $TMPDIR:
#
#   * a private pacman root  (RootDir/DBPath/CacheDir/LogFile/HookDir/GPGDir)
#   * private file:// repositories built with the real `repo-add`
#   * real .pkg.tar.gz packages, installed and upgraded by the real pacman
#
# The only thing shimmed onto PATH is a two-line `pacman` wrapper that adds
# `--config <the throwaway config>`, a matching `pacman-conf` wrapper, and a
# `sudo` that execs its argument (the suite already runs as root). The wrapper
# also rewrites a bare absolute path passed to `-Qo` into its RootDir-relative
# form, because pacman does not do that itself — see the `-Qo` note below.
# Dependency resolution, ABI-break detection, transaction ordering and file
# ownership are all done by the genuine pacman.
#
# What it proves:
#   1.  foreign repositories are discovered from pacman.conf, and Manjaro's own
#       repos are not mistaken for foreign ones
#   2.  a foreign package whose version-constrained dep is unsatisfiable is
#       HELD, and is still at its old version after the run  ← the whole point
#   3.  the hold is recorded in the log, so it can be chased later
#   4.  the same package is NOT held once the dep becomes satisfiable — the
#       guard is not a blanket refusal to upgrade foreign packages
#   5.  a satisfied dependency is no reason to hold, version or no version
#   6.  "installing X breaks dependency ... required by Y", with Y an AUR
#       package, is recovered from WITHOUT holding X: the repo upgrade lands in
#       full (--assume-installed stands in for Y's stale dependency), and Y is
#       named for a rebuild — the AUR package is the one out of date
#   7.  X reaches its new version, Y stays installed, and the needed rebuild
#       is logged
#   8.  an unrecoverable pacman failure exits non-zero — it is never laundered
#       into a success by the retry loop
#   9.  aur-rebuild-check flags a package with a genuinely unresolvable
#       DT_NEEDED (a real ELF built by cc, with a real missing .so)
#   10. it does NOT flag a package that ships the "missing" soname itself —
#       the $ORIGIN/bundled-library false positive that made -bin packages
#       flag forever
#   11. AUR_REBUILD_IGNORE_SONAMES suppresses a named soname
#   12. a package whose links all resolve is reported clean, exit 0
#   13. remove-versioned-kernel rejects a name that is not linuxNN
#   14. it is a no-op (exit 0) for a kernel that is not installed
#   15. it REFUSES to remove the currently-booted kernel
#   16. it REFUSES to remove the last remaining versioned kernel
#   17. a legitimate removal takes the kernel, its headers and its -nvidia
#       sibling, and rewrites IgnorePkg to name only the survivors -- and
#       still exits 0 when this system has no UKI directory at all, because
#       the post-removal probes run after the work is already done and must
#       never turn a completed removal into a failure exit
#   18. ...and still exits 0, and still lists the images, when it does
#   19. --ignore cannot manufacture a partial upgrade: pacman still resolves
#       the whole transaction and REFUSES one that would strand a dependency,
#       changing nothing -- and a real safeup hold inherits that, leaving a
#       system that `pacman -Dk` still calls consistent. This is the property
#       the entire suite's safety argument rests on, and it is an assumption
#       about pacman rather than about this code, so nothing here would notice
#       if it silently changed.
#   20. NO false hold when the satisfying dependency is pending in the SAME
#       run — Manjaro's libfoo 2.0 and the foreign package built against it
#       usually land together, and `pacman -T` alone (installed packages only)
#       held every one of those for a cycle
#   21. NO false hold for a package present in both a Manjaro repo and a
#       foreign one: pacman upgrades from the first repo in pacman.conf order,
#       so it is judged by THAT repo's dependencies, not the foreign copy's
#   22. `--check` reports pending upgrades and would-be holds, changes nothing,
#       and the REAL sync database is never refreshed by the pre-flight — the
#       refresh goes to a private snapshot, so declining the prompt cannot
#       leave `pacman -S foo` one bare -Sy away from a partial upgrade
#   23. a dependency with an epoch (`libfoo>=1:2.0`) is read whole — splitting
#       the -Si line on ':' truncated it to `libfoo>=1`, which then passed
#   24. aur-rebuild-check flags a broken ELF that is neither *.so nor under
#       bin/ — /opt/<app>/<exe> is where a great many AUR packages live
#   25. it flags a pure-Python package stranded in the PREVIOUS interpreter's
#       site-packages after a python bump, and not one under the current dir
#   26. remove-versioned-kernel takes EVERY extramodule package that depends on
#       the kernel (-nvidia, -r8168, ...), and leaves a same-prefix package that
#       does NOT depend on it (linux66-rt is a different kernel) alone
#   27. the IgnorePkg rewrite removes ONLY the evicted kernel's tokens: an
#       unrelated entry survives, and nothing is ever added
#   28. the running-kernel guard fires on a VERSION match even when nothing
#       owns the running kernel's module directory
#   29. `aur-rebuild-check --fix` runs the pin-check gate before yay, and
#       `--noconfirm` reaches yay's --rebuild
#   30. the same break between two REPOSITORY packages — a mirror mid-sync —
#       stops the run with nothing changed: nothing can stand in for that
#   31. an installed alternate interpreter (python311 from the AUR) and the
#       modules built for it are not flagged as a stale python tree
#   32. the pre-flight shows a live one-line meter on a terminal, counting every
#       pending package, never wrapping, and never leaking into --check's
#       stdout or into redirected output
#   33. aur-rebuild-check finds the break WITHOUT running ldd: a package's
#       files are read, never handed to the dynamic loader
#   34. a DT_NEEDED met through the object's own $ORIGIN RUNPATH — by a library
#       another package ships — is not a break, and becomes one the moment
#       that library is gone
#   35. a same-named library of the wrong machine does not satisfy a DT_NEEDED,
#       and an object this machine cannot load at all is foreign, not stale
#   36. a broken package in no repo and not in the AUR is not told to rebuild:
#       no yay command, the removal it can actually do, and --fix leaves it alone
#   37. a broken -bin package is not told to rebuild either: that repackages
#       the same binary
#   38. a package in the ignore file is counted, not reported, and the scan
#       exits clean
#   39. a plugin needing what its host's package ships privately (a perl XS
#       module and libperl.so) is not flagged; an executable with the same
#       need is, because nothing has mapped anything for it
#   40. a package stranded in a previous perl's tree is flagged, and a tree whose
#       perl is still installed is not
#   41. --fix judges each package by itself: one the pin check refuses does not
#       stop the rest being rebuilt, and the exit status still says so
#   42. a hostile DT_NEEDED string is data: the scan reports it without running
#       it, and with its control characters removed
#   43. two AUR packages needing the same stale dependency are BOTH named for a
#       rebuild, on the terminal and in the log
#   44. a foreign package needing something no repo has, versioned or not, is
#       held; one missing dependency used to stop the whole upgrade
#   45. a dependency on a wrapped line is still read: with COLUMNS exported,
#       pacman wraps -Si and -Qi fields even into a pipe
#   46. pacman runs in the C locale, because safeup reads its messages to
#       recover from them
#   47. remove-versioned-kernel reads a wrapped Depends On as well
#   48. a stand-in for an AUR package is not used when pacman also cannot satisfy
#       a repository package: it would answer for that one too, silently
#   49. what only the whole transaction shows is held as well: a satisfier in
#       IgnorePkg, a `libfoo<2` the same upgrade breaks, a new dependency with a
#       constraint of its own, a foreign package that replaces one
#       (and a replacement with nothing else pending reaches that dry run too);
#       an installed foreign package a Manjaro upgrade breaks stops the run,
#       with nothing changed and the right reason given
#   50. sync databases that cannot be read are an error, not "nothing pending"
#   51. the master prompt: Enter proceeds; end of file and anything unrecognised
#       do not
#   52. a run the user declined logged no hold; a log that cannot be written says so
#   53. pacman exiting 0 with the upgrade unfinished is not a clean upgrade, and
#       --aur builds nothing on top of it
#   54. what the rebuild scan finds reaches the log; a missing scan says so
#   55. --aur: aurupdate after a clean upgrade, the broken package to aurinstall,
#       and neither after a failed upgrade
#   56. recovery path 1: a conflict --noconfirm refused is retried with a prompt
#   57. a ranged dependency gets a stand-in too
#   58. the rebuild scan asks yes or no on a terminal, and only rebuilds on yes;
#       --no-prompt and no terminal print the command instead
#   59. so does safeup, for what the upgrade itself broke
#   60. a broken readelf is an error, not "all clean"; a file that cannot be
#       parsed is counted, not passed
#   61. a text file named like the soname does not excuse a binary
#   62. RPATH, ${ORIGIN} and an `&` in a directory name resolve as the loader
#       resolves them; python3.X under /opt is the application's own
#   63. remove-versioned-kernel refuses the running series after an in-place
#       upgrade; takes a backup of what it rewrites and none of what it does not;
#       says when it could not check for a UKI
#   64. no package's file is loaded or run by the scan: a constructor would
#       leave a mark, and the dynamic loader's own debug log would name it
#
# Run as root:  sudo bash tests/loopback-core-test.sh
# Requires: pacman, repo-add, bsdtar (libarchive), losetup, mkfs.ext4, cc,
# readelf (binutils).
# Section 32 also needs script(1) and stty, and is skipped without them.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }
for c in pacman pacman-conf repo-add bsdtar losetup mkfs.ext4 cc readelf awk grep; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

ARCH=$(uname -m)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/safeup-loopback-test.XXXXXX")
MNT="$WORK/mnt"
LOOP=""
PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
# A check that cannot run here is reported as SKIP. It is never counted as a
# pass — a silent pass is the one outcome this suite exists to prevent.
skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }

cleanup() {
    set +e
    umount "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== setup: 512M file-backed loop device, ext4, mounted at \$WORK/mnt =="
mkdir -p "$MNT"
truncate -s 512M "$WORK/disk.img"
LOOP=$(losetup --show -f "$WORK/disk.img") || { echo "losetup failed"; exit 1; }
mkfs.ext4 -q -F "$LOOP"
mount "$LOOP" "$MNT" || { echo "mount failed"; exit 1; }
echo "  loop device: $LOOP -> $MNT"

# ---------------------------------------------------------------------------
# Environment construction. Each scenario gets its own package root so that a
# transaction in one cannot colour the next.
# ---------------------------------------------------------------------------
ENV_DIR=""; ROOT=""; CONF=""; REPO_M=""; REPO_F=""; SHIM=""
BASE_PATH="$PATH"

mkenv() { # mkenv <name> [foreign-repo-name]  — builds and selects an env
    local name="$1" foreign="${2:-}"
    ENV_DIR="$MNT/$name"
    ROOT="$ENV_DIR/root"; CONF="$ENV_DIR/pacman.conf"
    REPO_M="$ENV_DIR/repo-manjaro"; REPO_F="$ENV_DIR/repo-foreign"
    SHIM="$ENV_DIR/shim"
    mkdir -p "$ROOT"/{var/lib/pacman,var/cache/pacman/pkg,var/log,usr/lib} \
             "$ROOT"/etc/pacman.d/{hooks,gnupg} \
             "$REPO_M" "$REPO_F" "$SHIM" "$ENV_DIR/build"

    {
        echo "[options]"
        echo "RootDir      = $ROOT"
        echo "DBPath       = $ROOT/var/lib/pacman/"
        echo "CacheDir     = $ROOT/var/cache/pacman/pkg/"
        echo "LogFile      = $ROOT/var/log/pacman.log"
        echo "GPGDir       = $ROOT/etc/pacman.d/gnupg/"
        echo "HookDir      = $ROOT/etc/pacman.d/hooks/"
        echo "Architecture = $ARCH"
        echo "SigLevel     = Never"
        echo "IgnorePkg    ="
        echo ""
        echo "[extra]"
        echo "Server = file://$REPO_M"
        if [ -n "$foreign" ]; then
            echo ""
            echo "[$foreign]"
            echo "Server = file://$REPO_F"
        fi
    } > "$CONF"

    # The shim. `--config` is prepended to every invocation; the -Qo case also
    # needs its path argument moved into the root, which pacman will not do.
    cat > "$SHIM/pacman" <<SHIMEOF
#!/bin/bash
if [ "\${1:-}" = "-Qoq" ] || [ "\${1:-}" = "-Qo" ]; then
    op="\$1"; shift
    args=()
    for a in "\$@"; do
        case "\$a" in /*) args+=("$ROOT\$a") ;; *) args+=("\$a") ;; esac
    done
    exec /usr/bin/pacman --config "$CONF" "\$op" "\${args[@]}"
fi
exec /usr/bin/pacman --config "$CONF" "\$@"
SHIMEOF
    printf '#!/bin/bash\nexec /usr/bin/pacman-conf --config "%s" "$@"\n' "$CONF" > "$SHIM/pacman-conf"
    printf '#!/bin/bash\nexec "$@"\n' > "$SHIM/sudo"
    # Which kernel "is running" must not depend on the machine under the test.
    printf '#!/bin/bash\n[ "${1:-}" = -r ] && { echo "${FAKE_UNAME_R:-5.4.250-1-TESTING}"; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$SHIM/uname"
    # yay stub: records its argv so the --fix path can prove what reached it.
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$ENV_DIR/yay.log" > "$SHIM/yay"
    chmod +x "$SHIM"/*
    : > "$ENV_DIR/yay.log"

    export PATH="$SHIM:$BIN:$BASE_PATH"
    export SAFEUP_PACMAN_CONF="$CONF"
    export SAFEUP_LOG="$ENV_DIR/safeup.log"
    # What aur-rebuild-check asks about a package it flags: never the real AUR.
    # A name with no file here is a name the index could not be asked about.
    export AUR_RPC_URL="file://$ENV_DIR/%s.json"
    export XDG_CONFIG_HOME="$ENV_DIR/config"
    : > "$SAFEUP_LOG"
}

# mkpkg <name> <ver-rel> [--at <subdir>] [--files f1,f2] [dep ...]
#   → prints the package path. Files land under usr/lib unless --at says where.
mkpkg() {
    local name="$1" ver="$2"; shift 2
    local files="" at="usr/lib"
    if [ "${1:-}" = "--at" ]; then at="$2"; shift 2; fi
    if [ "${1:-}" = "--files" ]; then files="$2"; shift 2; fi
    local d="$ENV_DIR/build/$name-$ver"
    rm -rf "$d"; mkdir -p "$d/$at"
    {
        echo "pkgname = $name"; echo "pkgbase = $name"; echo "pkgver = $ver"
        echo "pkgdesc = Satyrus-manjaro loopback fixture"
        echo "url = https://example.invalid"
        echo "builddate = 1700000000"; echo "packager = safeup-test"
        echo "size = 0"; echo "arch = $ARCH"
        for dep; do echo "depend = $dep"; done
        [ -z "${MKPKG_EXTRA:-}" ] || echo "$MKPKG_EXTRA"
    } > "$d/.PKGINFO"
    if [ -n "$files" ]; then
        local IFS=,
        for f in $files; do install -Dm644 "$f" "$d/$at/$(basename "$f")"; done
    else
        echo "$name $ver" > "$d/$at/$name.marker"
    fi
    # `--` must precede the first file name: bsdtar stops parsing options at
    # the first non-option and would otherwise try to archive a file named "--".
    ( cd "$d" && bsdtar -czf "$ENV_DIR/build/$name-$ver-$ARCH.pkg.tar.gz" -- .PKGINFO * ) \
        || echo "mkpkg: bsdtar failed for $name-$ver" >&2
    echo "$ENV_DIR/build/$name-$ver-$ARCH.pkg.tar.gz"
}

# What the AUR index answers for a name: aur_index <pkg> <resultcount>
aur_index() {
    printf '{"resultcount":%s,"results":[{"Name":"%s","PackageBase":"%s"}]}' "$2" "$1" "$1" > "$ENV_DIR/$1.json"
}

publish() { # publish <repo-dir> <db-name> <pkgfile>...
    local dir="$1" db="$2"; shift 2
    cp "$@" "$dir/"
    local names=()
    for p in "$@"; do names+=("$dir/$(basename "$p")"); done
    repo-add -q "$dir/$db.db.tar.gz" "${names[@]}" >/dev/null 2>&1
}

installed_ver() { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }

# =============================================================================
echo ""
echo "== 1. foreign-repo discovery =="
# =============================================================================
mkenv detect blackarch
# safeup opens with `pacman -Sy`, which fails outright if a configured repo has
# no database at all — so both repos need one package before it can run.
publish "$REPO_M" extra "$(mkpkg seed-manjaro 1.0-1)"
publish "$REPO_F" blackarch "$(mkpkg seed-foreign 1.0-1)"
if pacman-conf --repo-list | grep -qx blackarch && pacman-conf --repo-list | grep -qx extra; then
    pass "both repos visible to pacman-conf --repo-list"
else
    fail "repo list did not come back as expected"
fi
out=$(safeup --noconfirm 2>&1)
if grep -q 'foreign repos tracked: blackarch' <<<"$out"; then
    pass "blackarch classified as foreign; extra was not"
else
    fail "foreign-repo classification wrong: $(grep 'foreign repos' <<<"$out")"
fi

# =============================================================================
echo ""
echo "== 2-3. the Manjaro-lag hold: unsatisfiable version constraint =="
# =============================================================================
# The exact shape of a "Manjaro AUR disaster": blackarch has rebuilt toolx
# against libfoo 2.0 because Arch shipped it; Manjaro's extra is still on 1.0.
mkenv lag blackarch
publish "$REPO_M" extra "$(mkpkg libfoo 1.0-1)"
FOO1="$ENV_DIR/build/libfoo-1.0-1-$ARCH.pkg.tar.gz"
TOOL1=$(mkpkg toolx 1.0-1 "libfoo>=1.0")
publish "$REPO_F" blackarch "$(mkpkg toolx 2.0-1 "libfoo>=2.0")"
pacman -U --noconfirm "$FOO1" "$TOOL1" >/dev/null 2>&1

out=$(safeup --noconfirm 2>&1); rc=$?
if grep -q 'hold toolx (blackarch) — unsatisfied dep: libfoo>=2.0' <<<"$out"; then
    pass "toolx held on its unsatisfiable libfoo>=2.0 constraint"
else
    fail "toolx was not held: $(grep -i 'hold\|conflict' <<<"$out")"
fi
[ "$(installed_ver toolx)" = "1.0-1" ] \
    && pass "toolx still at 1.0-1 — the partial upgrade did not happen" \
    || fail "toolx was upgraded to $(installed_ver toolx) despite the hold"
[ "$rc" = "0" ] \
    && pass "safeup still exits 0 — a hold is a success, not a failure" \
    || fail "safeup exited $rc after a clean hold"
grep -q 'toolx' "$SAFEUP_LOG" \
    && pass "hold recorded in \$SAFEUP_LOG" \
    || fail "nothing logged for the held package"

# =============================================================================
echo ""
echo "== 4. no false hold once Manjaro catches up =="
# =============================================================================
# Same env: publish libfoo 2.0 and install it, exactly as a later Manjaro sync
# would. toolx must now sail through.
publish "$REPO_M" extra "$(mkpkg libfoo 2.0-1)"
pacman -U --noconfirm "$ENV_DIR/build/libfoo-2.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
: > "$SAFEUP_LOG"
out=$(safeup --noconfirm 2>&1)
if [ "$(installed_ver toolx)" = "2.0-1" ]; then
    pass "toolx upgraded to 2.0-1 once libfoo>=2.0 was satisfiable"
else
    fail "toolx stuck at $(installed_ver toolx) — false hold"
fi
grep -q 'no ABI conflicts' <<<"$out" \
    && pass "run reported no ABI conflicts" \
    || fail "still reporting conflicts with a satisfiable dep set"

# =============================================================================
echo ""
echo "== 5. a satisfied unversioned dependency is no reason to hold =="
# =============================================================================
mkenv unversioned blackarch
publish "$REPO_M" extra "$(mkpkg libbar 1.0-1)"
BAR1="$ENV_DIR/build/libbar-1.0-1-$ARCH.pkg.tar.gz"
TOOLY1=$(mkpkg tooly 1.0-1 "libbar")
publish "$REPO_F" blackarch "$(mkpkg tooly 2.0-1 "libbar")"
pacman -U --noconfirm "$BAR1" "$TOOLY1" >/dev/null 2>&1
out=$(safeup --noconfirm 2>&1)
if ! grep -q 'hold tooly' <<<"$out" && [ "$(installed_ver tooly)" = "2.0-1" ]; then
    pass "package with only unversioned deps upgraded, not held"
else
    fail "unversioned dep triggered a hold"
fi

# =============================================================================
echo ""
echo "== 6-7. recovery from 'installing X breaks dependency required by Y' =="
# =============================================================================
# This break comes from a MANJARO repo, so the pre-flight foreign check cannot
# see it: Manjaro ships appx 2.0, and consumer — built from the AUR, so in no
# repository — still declares appx=1.0. pacman refuses the whole transaction.
# The repo library must NOT be held back: that is the partial-upgrade
# direction. The repo upgrade lands in full, and the AUR package — the one
# that is out of date — is named for a rebuild.
mkenv abibreak
APPX1=$(mkpkg appx 1.0-1)
CONS1=$(mkpkg consumer 1.0-1 "appx=1.0")
OTHER1=$(mkpkg other 1.0-1)
pacman -U --noconfirm "$APPX1" "$CONS1" "$OTHER1" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg appx 2.0-1)" "$(mkpkg other 2.0-1)"

out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if grep -q "consumer (AUR) needs 'appx=1.0'" <<<"$out" && grep -q 'rebuild later with: aurinstall consumer' <<<"$out"; then
    pass "the broken AUR package was identified from pacman's own message and named for rebuild"
else
    fail "AUR break not reported: $(grep -i 'break\|error\|needs' <<<"$out" | head -3)"
fi
[ "$rc" = "0" ] \
    && pass "the repo upgrade completed" \
    || { fail "safeup exited $rc instead of recovering"; echo "--- output ---"; echo "$out" | tail -30; echo "--- end ---"; }
[ "$(installed_ver appx)" = "2.0-1" ] \
    && pass "appx reached 2.0-1 — the repo library was NOT held back" \
    || fail "appx stuck at $(installed_ver appx) — a repo library was held: a partial upgrade"
[ "$(installed_ver other)" = "2.0-1" ] \
    && pass "unrelated package 'other' got its upgrade too" \
    || fail "other stuck at $(installed_ver other) — one break blocked everything"
[ "$(installed_ver consumer)" = "1.0-1" ] \
    && pass "the AUR package is left installed, for its rebuild" \
    || fail "consumer changed: '$(installed_ver consumer)'"
grep -q 'needs AUR rebuild' "$SAFEUP_LOG" && grep -q 'consumer' "$SAFEUP_LOG" \
    && pass "the needed rebuild is recorded in \$SAFEUP_LOG" \
    || fail "needed rebuild not logged"

# 30. The same break where the dependent is a REPOSITORY package: the repos
# disagree with each other (a mirror mid-sync). Nothing stands in for that.
mkenv midsync
APPY1=$(mkpkg appy 1.0-1)
RCONS1=$(mkpkg rconsumer 1.0-1 "appy=1.0")
pacman -U --noconfirm "$APPY1" "$RCONS1" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg appy 2.0-1)" "$RCONS1"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" != "0" ] && grep -q 'mirror is mid-sync' <<<"$out" \
   && [ "$(installed_ver appy)" = "1.0-1" ] && [ "$(installed_ver rconsumer)" = "1.0-1" ]; then
    pass "a break between two repo packages stops the run, changing nothing"
else
    fail "mid-sync repos were not refused (rc=$rc, appy=$(installed_ver appy)): $(tail -5 <<<"$out")"
fi

# 43. pacman reports one line per dependent. The stand-in is the same for both,
# and the second dependent must not vanish with the duplicate.
mkenv abibreak2
APPZ1=$(mkpkg appz 1.0-1)
pacman -U --noconfirm "$APPZ1" "$(mkpkg consa 1.0-1 "appz=1.0")" "$(mkpkg consb 1.0-1 "appz=1.0")" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg appz 2.0-1)"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'rebuild later with: aurinstall consa consb' <<<"$out" \
   && grep -q 'consa' "$SAFEUP_LOG" && grep -q 'consb' "$SAFEUP_LOG"; then
    pass "two AUR packages on one stale dependency are both named, and both logged"
else
    fail "a needed rebuild went unreported (rc=$rc): $(grep -E 'rebuild|needs' <<<"$out" | head -4 | tr '\n' ' ') / log: $(tr '\n' ' ' < "$SAFEUP_LOG")"
fi

# 44. Not every unsatisfiable dependency has a version in it.
mkenv unversioned2 blackarch
pacman -U --noconfirm "$(mkpkg lonely 1.0-1)" "$(mkpkg bystander 1.0-1)" >/dev/null 2>&1
publish "$REPO_F" blackarch "$(mkpkg lonely 2.0-1 "not-in-any-repo")"
publish "$REPO_M" extra "$(mkpkg bystander 2.0-1)"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'hold lonely' <<<"$out" \
   && [ "$(installed_ver lonely)" = "1.0-1" ] && [ "$(installed_ver bystander)" = "2.0-1" ]; then
    pass "a foreign package with an unversioned, unsatisfiable dependency is held; the rest upgrades"
else
    fail "one unsatisfiable dependency stopped the upgrade (rc=$rc, bystander=$(installed_ver bystander)): $(tail -4 <<<"$out")"
fi

# 45. COLUMNS in the environment makes pacman wrap, pipe or no pipe.
mkenv wrapped blackarch
pacman -U --noconfirm "$(mkpkg wraptool 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg aaaa-first-dep 1.0-1)" "$(mkpkg bbbb-second-dep 1.0-1)" "$(mkpkg cccc-third-dep 1.0-1)"
publish "$REPO_F" blackarch "$(mkpkg wraptool 2.0-1 "aaaa-first-dep" "bbbb-second-dep" "cccc-third-dep" "libnever>=9")"
out=$(COLUMNS=40 safeup --check </dev/null 2>&1)
if grep -q 'hold wraptool.*libnever>=9' <<<"$out"; then
    pass "a dependency on a wrapped line of pacman -Si is still read"
else
    fail "COLUMNS hid a dependency from the pre-flight: $(grep -E 'hold|would hold' <<<"$out" | head -3)"
fi

# 46. safeup reads pacman's own messages, so they have to arrive in one language.
mkenv locale
LOC_SHIM="$SHIM/pacman"
mv "$LOC_SHIM" "$LOC_SHIM.real"
printf '#!/bin/bash\n[[ " $* " == *" -Syu "* ]] && echo "LC_ALL=${LC_ALL:-unset}" >> "%s"\nexec "%s" "$@"\n' \
    "$ENV_DIR/locale.log" "$LOC_SHIM.real" > "$LOC_SHIM"
chmod +x "$LOC_SHIM"
LC_ALL=de_DE.UTF-8 safeup --noconfirm </dev/null >/dev/null 2>&1
if grep -q '^LC_ALL=C$' "$ENV_DIR/locale.log" 2>/dev/null; then
    pass "pacman -Syu runs in the C locale, whatever the user's"
else
    fail "pacman -Syu ran with $(cat "$ENV_DIR/locale.log" 2>/dev/null): a translated message defeats the recovery"
fi

# =============================================================================
echo ""
echo "== 8. an unrecoverable failure is never laundered into success =="
# =============================================================================
mkenv unrecoverable
pacman -U --noconfirm "$(mkpkg widget 1.0-1)" >/dev/null 2>&1
# widget 2.0 needs something that exists nowhere: not a break, not a conflict,
# just unsatisfiable. None of the recovery patterns match it.
publish "$REPO_M" extra "$(mkpkg widget 2.0-1 "no-such-package-anywhere")"
safeup --noconfirm </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] \
    && pass "safeup exited non-zero ($rc) on an unrecoverable transaction" \
    || fail "unrecoverable pacman failure reported as success"
[ "$(installed_ver widget)" = "1.0-1" ] \
    && pass "nothing was upgraded by the failed transaction" \
    || fail "widget changed version during a failed run"

# =============================================================================
echo ""
echo "== 20. no false hold when the satisfying dependency lands in the SAME run =="
# =============================================================================
# The common case, not the edge case: Manjaro's libq 2.0 and blackarch's toolq
# rebuilt against it arrive in the same sync. `pacman -T` sees only what is
# installed, so on its own it held every one of these for a cycle. The guard
# has to ask whether the dependency will be satisfiable after THIS upgrade.
mkenv samerun blackarch
publish "$REPO_M" extra "$(mkpkg libq 1.0-1)"
LIBQ1="$ENV_DIR/build/libq-1.0-1-$ARCH.pkg.tar.gz"
TOOLQ1=$(mkpkg toolq 1.0-1 "libq>=1.0")
pacman -U --noconfirm "$LIBQ1" "$TOOLQ1" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg libq 2.0-1)"
publish "$REPO_F" blackarch "$(mkpkg toolq 2.0-1 "libq>=2.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if ! grep -q 'hold toolq' <<<"$out" && [ "$(installed_ver toolq)" = "2.0-1" ] \
   && [ "$(installed_ver libq)" = "2.0-1" ]; then
    pass "toolq NOT held: its libq>=2.0 is satisfied by the libq 2.0 pending in the same run"
else
    fail "false hold on a same-run dependency (rc=$rc): toolq=$(installed_ver toolq) libq=$(installed_ver libq)"
fi

# =============================================================================
echo ""
echo "== 21. a package carried by BOTH a Manjaro repo and a foreign one =="
# =============================================================================
# pacman upgrades from the first repository in pacman.conf order that carries
# the name, so that copy's dependencies are the ones that matter. Judging it by
# the foreign copy held a package pacman was never going to take from there.
mkenv dualrepo blackarch
pacman -U --noconfirm "$(mkpkg dual 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg dual 2.0-1)"
publish "$REPO_F" blackarch "$(mkpkg dual 2.0-1 "libnope>=9.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if ! grep -q 'hold dual' <<<"$out" && [ "$(installed_ver dual)" = "2.0-1" ]; then
    pass "dual upgraded from extra; the foreign copy's impossible dependency was never consulted"
else
    fail "package in both repos judged by the wrong copy (rc=$rc): $(grep -i 'hold' <<<"$out" | head -2 | tr '\n' ' ')"
fi

# =============================================================================
echo ""
echo "== 22. --check reports without touching the real sync database =="
# =============================================================================
# Refreshing the real database and then NOT upgrading is the textbook way to
# set up a partial upgrade: the next `pacman -S foo` installs against a
# database newer than the system. The pre-flight therefore refreshes a private
# snapshot, and the real database must be exactly as stale afterwards as it
# was before.
mkenv check blackarch
publish "$REPO_M" extra "$(mkpkg libc1 1.0-1)"
LIBC1="$ENV_DIR/build/libc1-1.0-1-$ARCH.pkg.tar.gz"
TOOLC1=$(mkpkg toolc 1.0-1 "libc1>=1.0")
pacman -U --noconfirm "$LIBC1" "$TOOLC1" >/dev/null 2>&1
pacman -Sy >/dev/null 2>&1                                       # the REAL database, synced now
publish "$REPO_F" blackarch "$(mkpkg toolc 2.0-1 "libc1>=2.0")"   # published AFTER that sync
out=$(safeup --check </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'toolc' <<<"$out" && grep -qi 'hold' <<<"$out"; then
    pass "--check sees the pending toolc upgrade and says it would be held (exit 0)"
else
    fail "--check report wrong (rc=$rc): $(tail -5 <<<"$out" | tr '\n' ' ')"
fi
[ "$(installed_ver toolc)" = "1.0-1" ] \
    && pass "--check changed nothing" \
    || fail "--check upgraded toolc to $(installed_ver toolc)"
if ! pacman -Qu 2>/dev/null | grep -q 'toolc'; then
    pass "the REAL sync database is still as stale as before the pre-flight"
else
    fail "--check refreshed the real sync database (pacman -Qu now sees toolc)"
fi
mkenv checknone
publish "$REPO_M" extra "$(mkpkg steady 1.0-1)"
pacman -U --noconfirm "$ENV_DIR/build/steady-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
safeup --check </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] \
    && pass "--check exits 2 when nothing is pending (checkupdates semantics)" \
    || fail "--check with nothing pending exited $rc, not 2"

# =============================================================================
echo ""
echo "== 23. a dependency with an epoch is read whole =="
# =============================================================================
# `Depends On : libe>=1:2.0` split on ': ' became `libe>=1`, which the
# installed libe 1.0 satisfies — so the hold that should have happened did
# not, and pacman refused the whole transaction instead.
mkenv epoch blackarch
publish "$REPO_M" extra "$(mkpkg libe 1.0-1)"
LIBE1="$ENV_DIR/build/libe-1.0-1-$ARCH.pkg.tar.gz"
TOOLE1=$(mkpkg toole 1.0-1 "libe>=1.0")
pacman -U --noconfirm "$LIBE1" "$TOOLE1" >/dev/null 2>&1
publish "$REPO_F" blackarch "$(mkpkg toole 2.0-1 "libe>=1:2.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if grep -q 'hold toole (blackarch) — unsatisfied dep: libe>=1:2.0' <<<"$out" && [ "$rc" = "0" ] \
   && [ "$(installed_ver toole)" = "1.0-1" ]; then
    pass "epoch constraint libe>=1:2.0 read whole and held; safeup still exits 0"
else
    fail "epoch dependency mishandled (rc=$rc): $(grep -i 'hold\|error\|unable' <<<"$out" | head -3 | tr '\n' ' ')"
fi

# =============================================================================
echo ""
echo "== 9-12. aur-rebuild-check against real ELF objects =="
# =============================================================================
# Real shared objects, built here by cc. libmain.so carries a genuine DT_NEEDED
# on libdep.so, and libdep.so is not on any library search path, so the break
# is real. Nothing about the objects is faked.
mkenv elf
ELF="$ENV_DIR/elf"; mkdir -p "$ELF"
echo 'int dep_fn(void){return 42;}'                 > "$ELF/dep.c"
echo 'int dep_fn(void); int main_fn(void){return dep_fn();}' > "$ELF/main.c"
echo 'int lone_fn(void){return 7;}'                 > "$ELF/lone.c"
cc -shared -fPIC -o "$ELF/libdep.so"  "$ELF/dep.c"  2>/dev/null
cc -shared -fPIC -o "$ELF/libmain.so" "$ELF/main.c" -L"$ELF" -l:libdep.so 2>/dev/null
cc -shared -fPIC -o "$ELF/liblone.so" "$ELF/lone.c" 2>/dev/null

if [ ! -f "$ELF/libmain.so" ] || ! readelf -d "$ELF/libmain.so" 2>/dev/null | grep -q 'NEEDED.*\[libdep\.so\]'; then
    skip "9-11: could not build an ELF with an unresolvable DT_NEEDED on this host"
    skip "(cc behaviour differs here; the check itself was not exercised)"
else
    # brokenapp ships ONLY the consumer → a genuine break.
    pacman -U --noconfirm "$(mkpkg brokenapp 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'brokenapp' <<<"$out"; then
        pass "package with an unresolvable DT_NEEDED flagged for rebuild"
    else
        fail "broken package not flagged (rc=$rc): $out"
    fi

    # Same missing soname, but the package ships it itself → resolved at
    # runtime through the main executable's \$ORIGIN RPATH, which this object's
    # own dynamic section does not carry.
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
    pacman -U --noconfirm \
        "$(mkpkg bundledapp 1.0-1 --files "$ELF/libmain.so,$ELF/libdep.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ] && ! grep -q 'bundledapp' <<<"$out"; then
        pass "package that ships the missing soname itself is NOT flagged"
    else
        fail "bundled-library false positive is back (rc=$rc): $out"
    fi

    # The named-soname escape hatch.
    pacman -R --noconfirm bundledapp >/dev/null 2>&1
    pacman -U --noconfirm "$ENV_DIR/build/brokenapp-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
    out=$(AUR_REBUILD_IGNORE_SONAMES=libdep.so aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ]; then
        pass "AUR_REBUILD_IGNORE_SONAMES suppresses a named soname"
    else
        fail "ignore-list did not suppress libdep.so (rc=$rc): $out"
    fi
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
fi

pacman -U --noconfirm "$(mkpkg cleanapp 1.0-1 --files "$ELF/liblone.so")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'satisfied library links' <<<"$out"; then
    pass "a package whose links all resolve is reported clean, exit 0"
else
    fail "clean package not reported clean (rc=$rc): $out"
fi

# 24. A broken executable that is neither *.so nor under a bin/ directory.
# /opt/<app>/<exe> is the layout of a large share of AUR packages, and a scan
# keyed on file NAME never opened it. ELF is identified by magic now.
pacman -R --noconfirm cleanapp >/dev/null 2>&1
echo 'int dep_fn(void); int main(void){return dep_fn();}' > "$ELF/app.c"
cc -o "$ELF/app" "$ELF/app.c" -L"$ELF" -l:libdep.so 2>/dev/null
if [ -x "$ELF/app" ] && readelf -d "$ELF/app" 2>/dev/null | grep -q 'NEEDED.*\[libdep\.so\]'; then
    pacman -U --noconfirm "$(mkpkg optapp 1.0-1 --at opt/optapp --files "$ELF/app")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'optapp' <<<"$out"; then
        pass "a broken ELF under /opt/<app>/ (not *.so, not bin/) is flagged"
    else
        fail "ELF outside *.so and bin/ was not scanned (rc=$rc): $out"
    fi
    pacman -R --noconfirm optapp >/dev/null 2>&1
else
    skip "24: could not build a dynamically linked executable with a missing DT_NEEDED here"
fi

# 25. A pure-Python package after a python bump. There is no ELF to scan; the
# files simply sit in a directory the new interpreter never looks at, and to
# pacman nothing is wrong. The current version comes from `pacman -Q python`.
pacman -U --noconfirm "$(mkpkg python 3.13.1-1)" >/dev/null 2>&1
echo 'x = 1' > "$ELF/mod.py"
pacman -U --noconfirm \
    "$(mkpkg oldpy 1.0-1 --at usr/lib/python3.12/site-packages --files "$ELF/mod.py")" \
    "$(mkpkg newpy 1.0-1 --at usr/lib/python3.13/site-packages --files "$ELF/mod.py")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "1" ] && grep -q 'oldpy' <<<"$out" && grep -q 'python3.12' <<<"$out"; then
    pass "package under the previous interpreter's site-packages is flagged, naming the stale dir"
else
    fail "stale python3.12 site-packages not flagged (rc=$rc): $out"
fi
grep -q 'newpy' <<<"$out" \
    && fail "package under the CURRENT python3.13 dir was flagged" \
    || pass "package under the current interpreter's site-packages is not flagged"
pacman -R --noconfirm oldpy newpy >/dev/null 2>&1

# 31. An alternate interpreter is not a stale tree. python311 from the AUR
# owns /usr/lib/python3.11/ on purpose, and so does a module built for it;
# flagging them meant a rebuild nag on every safeup run, forever.
echo '# stdlib marker' > "$ELF/os.py"
pacman -U --noconfirm \
    "$(mkpkg python311 3.11.9-1 --at usr/lib/python3.11 --files "$ELF/os.py")" \
    "$(mkpkg py311mod 1.0-1 --at usr/lib/python3.11/site-packages --files "$ELF/mod.py")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "0" ] && ! grep -q 'python311\|py311mod' <<<"$out"; then
    pass "an installed alternate interpreter and its modules are not flagged"
else
    fail "alternate interpreter flagged as stale (rc=$rc): $out"
fi
pacman -R --noconfirm py311mod python311 python >/dev/null 2>&1

# 29. --fix must not become a way around the gate: a rebuild goes through
# aur-pin-check first, and only a clean set reaches yay. .SRCINFO comes from a
# local file here, exactly as the fixture suite does it.
if [ -f "$ELF/libmain.so" ] && curl -V 2>/dev/null | grep -q '\bfile\b'; then
    pacman -U --noconfirm "$ENV_DIR/build/brokenapp-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
    export AUR_SRCINFO_URL="file://$ENV_DIR/%s.SRCINFO"
    export AUR_PKGBUILD_URL="file://$ENV_DIR/%s.PKGBUILD"
    aur_index brokenapp 1
    printf 'pkgbase = brokenapp\n\tsource = git+https://example.invalid/b.git\n\npkgname = brokenapp\n' \
        > "$ENV_DIR/brokenapp.SRCINFO"
    : > "$ENV_DIR/yay.log"
    out=$(aur-rebuild-check --fix --noconfirm 2>&1); rc=$?
    if [ "$rc" != "0" ] && grep -q 'REJECT brokenapp' <<<"$out" && [ ! -s "$ENV_DIR/yay.log" ]; then
        pass "--fix refuses to rebuild a package the pin-check rejects; yay never runs"
    else
        fail "--fix bypassed the gate (rc=$rc, yay: $(cat "$ENV_DIR/yay.log"))"
    fi
    printf 'pkgbase = brokenapp\n\tsource = git+https://example.invalid/b.git#commit=0123456789abcdef0123456789abcdef01234567\n\tsha256sums = SKIP\n\npkgname = brokenapp\n' \
        > "$ENV_DIR/brokenapp.SRCINFO"
    # The PKGBUILD the .SRCINFO describes: the pin check reads both.
    printf 'pkgname=brokenapp\nsource=("git+https://example.invalid/b.git#commit=0123456789abcdef0123456789abcdef01234567")\nsha256sums=(SKIP)\n' \
        > "$ENV_DIR/brokenapp.PKGBUILD"
    : > "$ENV_DIR/yay.log"
    aur-rebuild-check --fix --noconfirm >/dev/null 2>&1
    if grep -q -- '-S --rebuild --noconfirm brokenapp' "$ENV_DIR/yay.log"; then
        pass "--fix --noconfirm reaches 'yay -S --rebuild --noconfirm' for a pinned package"
    else
        fail "--fix did not rebuild a clean package: $(cat "$ENV_DIR/yay.log")"
    fi
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
else
    skip "29: needs the broken ELF from 9-11 and a curl with file:// support"
fi

# 33. The scan reads; it does not load. Up to 1.7.0 every ELF a foreign package
# owned was handed to `ldd`, i.e. to the dynamic loader — which ldd(1) itself
# says never to do with an untrusted executable. An `ldd` that records being
# called sits first on PATH here: the break must still be found, and the
# record must stay empty.
if [ -f "$ELF/libmain.so" ] && readelf -d "$ELF/libmain.so" 2>/dev/null | grep -q 'NEEDED.*\[libdep\.so\]'; then
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec /usr/bin/ldd "$@"\n' "$ENV_DIR/ldd.log" > "$SHIM/ldd"
    chmod +x "$SHIM/ldd"; : > "$ENV_DIR/ldd.log"
    pacman -U --noconfirm "$ENV_DIR/build/brokenapp-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'brokenapp' <<<"$out" && [ ! -s "$ENV_DIR/ldd.log" ]; then
        pass "the break is found by reading the ELF; ldd is never run on a package's files"
    else
        fail "ldd was run on a package's files, or the break was missed (rc=$rc, ldd: $(head -2 "$ENV_DIR/ldd.log" | tr '\n' ' '))"
    fi
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
    rm -f "$SHIM/ldd"
else
    skip "33: needs the broken ELF from 9-11"
fi

# 34. The loader's own search order, replayed from the file: an executable
# whose RUNPATH is $ORIGIN/lib finds a library ANOTHER package put there (so
# the bundled-library filter of case 10 has nothing to do with it). Take that
# package away and the same executable is broken.
cc -o "$ELF/rpapp" "$ELF/app.c" -L"$ELF" -l:libdep.so \
    -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN/lib' 2>/dev/null
if [ -x "$ELF/rpapp" ] && readelf -d "$ELF/rpapp" 2>/dev/null | grep -q 'RUNPATH.*\$ORIGIN/lib'; then
    pacman -U --noconfirm \
        "$(mkpkg rpapp 1.0-1 --at opt/rpapp --files "$ELF/rpapp")" \
        "$(mkpkg rplibs 1.0-1 --at opt/rpapp/lib --files "$ELF/libdep.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ]; then
        pass "a DT_NEEDED met through the object's own \$ORIGIN RUNPATH is not a break"
    else
        fail "\$ORIGIN RUNPATH was not searched (rc=$rc): $out"
    fi
    pacman -R --noconfirm rplibs >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'rpapp.*libdep.so not found' <<<"$out"; then
        pass "...and is one once the package that shipped the library is gone"
    else
        fail "a library missing from the RUNPATH dir was not noticed (rc=$rc): $out"
    fi

    # 35. A file with the right name and the wrong machine is not the library.
    # The loader skips it and keeps looking; a check that stopped at `-e` would
    # call a 64-bit binary satisfied by a 32-bit (here: other-architecture)
    # libfoo. The fixture is libdep.so with e_machine (2 bytes at offset 18)
    # rewritten to an architecture this host is not.
    case "$ARCH" in aarch64) em='\076\000' ;; *) em='\267\000' ;; esac   # EM_X86_64 : EM_AARCH64
    cp "$ELF/libdep.so" "$ELF/alien-dep.so"
    printf "$em" | dd of="$ELF/alien-dep.so" bs=1 seek=18 conv=notrunc 2>/dev/null
    mkdir -p "$ELF/alien"; cp "$ELF/alien-dep.so" "$ELF/alien/libdep.so"
    pacman -U --noconfirm \
        "$(mkpkg alienlibs 1.0-1 --at opt/rpapp/lib --files "$ELF/alien/libdep.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'rpapp.*libdep.so not found' <<<"$out"; then
        pass "a same-named library of the wrong machine does not satisfy a DT_NEEDED"
    else
        fail "a wrong-machine library was accepted as the dependency (rc=$rc): $out"
    fi
    pacman -R --noconfirm alienlibs rpapp >/dev/null 2>&1

    # ...and the other way round: an object this machine cannot load at all (a
    # cross-toolchain's target library) with a DT_NEEDED nothing here provides
    # is foreign, not stale. No rebuild changes that, so it is never flagged.
    cp "$ELF/libmain.so" "$ELF/alien/libmain.so"
    printf "$em" | dd of="$ELF/alien/libmain.so" bs=1 seek=18 conv=notrunc 2>/dev/null
    pacman -U --noconfirm \
        "$(mkpkg crosslib 1.0-1 --at usr/alien-target/lib --files "$ELF/alien/libmain.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ]; then
        pass "an object for a machine this host cannot load is foreign, not stale"
    else
        fail "a foreign-architecture object was flagged for rebuild (rc=$rc): $out"
    fi
    pacman -R --noconfirm crosslib >/dev/null 2>&1
else
    skip "34-35: could not build an executable with an \$ORIGIN RUNPATH here"
fi

# 36-37. "needs rebuild" is advice, and advice has to be able to work.
if [ -f "$ELF/libmain.so" ] && curl -V 2>/dev/null | grep -q '\bfile\b'; then
    pacman -U --noconfirm "$(mkpkg gonepkg 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    aur_index gonepkg 0
    : > "$ENV_DIR/yay.log"
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'gonepkg.*libdep.so not found' <<<"$out" \
       && grep -q 'no source' <<<"$out" && grep -q 'pacman -Rns gonepkg' <<<"$out" \
       && ! grep -q 'rebuild gonepkg' <<<"$out"; then
        pass "a broken package with no source gets no rebuild command, and the removal it can do"
    else
        fail "no-source package misreported (rc=$rc): $out"
    fi
    out=$(aur-rebuild-check --fix --noconfirm 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'nothing here is something a rebuild can fix' <<<"$out" \
       && [ ! -s "$ENV_DIR/yay.log" ]; then
        pass "--fix leaves a package with no source alone: yay never runs"
    else
        fail "--fix tried a package with no source (rc=$rc, yay: $(cat "$ENV_DIR/yay.log")): $out"
    fi
    pacman -R --noconfirm gonepkg >/dev/null 2>&1

    pacman -U --noconfirm "$(mkpkg brokenapp-bin 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    aur_index brokenapp-bin 1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'prebuilt' <<<"$out" && ! grep -q 'rebuild brokenapp-bin' <<<"$out"; then
        pass "a broken -bin package is told a rebuild repackages the same binary"
    else
        fail "-bin package told to rebuild (rc=$rc): $out"
    fi

    # 38. accepted breakage is counted, not reported
    mkdir -p "$XDG_CONFIG_HOME/aur-rebuild-check"
    printf '# looked at this one\nbrokenapp-bin\n' > "$XDG_CONFIG_HOME/aur-rebuild-check/ignore"
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ] && grep -q '1 broken package(s) accepted.*brokenapp-bin' <<<"$out" \
       && ! grep -q 'not found' <<<"$out"; then
        pass "a package in the ignore file is counted in one line, and the scan exits clean"
    else
        fail "ignore file not honoured (rc=$rc): $out"
    fi
    rm -f "$XDG_CONFIG_HOME/aur-rebuild-check/ignore"
    pacman -R --noconfirm brokenapp-bin >/dev/null 2>&1
else
    skip "36-38: needs the broken ELF from 9-11 and a curl with file:// support"
fi

# 39. A plugin's host has the library mapped. The dependency keeps libdep.so in
# a private directory no search path names, exactly as perl keeps libperl.so in
# CORE/, and a rebuild of the plugin would link it the same way forever.
if [ -f "$ELF/libmain.so" ] && [ -x "$ELF/app" ]; then
    pacman -U --noconfirm \
        "$(mkpkg plughost 1.0-1 --at usr/lib/plughost/private --files "$ELF/libdep.so")" \
        "$(mkpkg pluginapp 1.0-1 --at usr/lib/pluginapp --files "$ELF/libmain.so" plughost)" >/dev/null 2>&1
    aur_index pluginapp 1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ] && ! grep -q 'pluginapp' <<<"$out"; then
        pass "a plugin needing what its dependency ships privately is not flagged"
    else
        fail "plugin host's library flagged as a break (rc=$rc): $out"
    fi
    pacman -U --noconfirm \
        "$(mkpkg exeapp 1.0-1 --at opt/exeapp --files "$ELF/app" plughost)" >/dev/null 2>&1
    aur_index exeapp 1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'exeapp' <<<"$out"; then
        pass "an executable with the same need IS flagged: nothing has mapped anything for it"
    else
        fail "an executable's real break was excused (rc=$rc): $out"
    fi
    pacman -R --noconfirm exeapp pluginapp plughost >/dev/null 2>&1
else
    skip "39: needs the ELF objects from 9-11 and 24"
fi

# 40. The perl half of check 2, built like the python half.
pacman -U --noconfirm "$(mkpkg perl 5.42.2-1)" >/dev/null 2>&1
echo '1;' > "$ELF/Mod.pm"; echo '1;' > "$ELF/Config.pm"
pacman -U --noconfirm \
    "$(mkpkg oldpm 1.0-1 --at usr/lib/perl5/5.40/vendor_perl --files "$ELF/Mod.pm")" >/dev/null 2>&1
aur_index oldpm 1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "1" ] && grep -q 'oldpm.*perl5/5.40' <<<"$out"; then
    pass "a package stranded in a previous perl's tree is flagged"
else
    fail "stale perl tree not flagged (rc=$rc): $out"
fi
pacman -U --noconfirm \
    "$(mkpkg perl540 5.40.0-1 --at usr/lib/perl5/5.40/core_perl --files "$ELF/Config.pm")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "0" ]; then
    pass "a tree whose perl is still installed is live, not stale"
else
    fail "live alternate perl tree flagged (rc=$rc): $out"
fi
pacman -R --noconfirm oldpm perl540 perl >/dev/null 2>&1

# 41. One refusal must not leave the rest of the set broken.
if [ -f "$ELF/libmain.so" ] && curl -V 2>/dev/null | grep -q '\bfile\b'; then
    SHA=0123456789abcdef0123456789abcdef01234567
    export AUR_SRCINFO_URL="file://$ENV_DIR/%s.SRCINFO" AUR_PKGBUILD_URL="file://$ENV_DIR/%s.PKGBUILD"
    pacman -U --noconfirm "$(mkpkg goodfix 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    pacman -U --noconfirm "$(mkpkg badfix 1.0-1 --at usr/lib/badfix --files "$ELF/libmain.so")" >/dev/null 2>&1
    aur_index goodfix 1; aur_index badfix 1
    printf 'pkgbase = goodfix\n\tsource = git+https://example.invalid/g.git#commit=%s\n\tsha256sums = SKIP\n\npkgname = goodfix\n' "$SHA" \
        > "$ENV_DIR/goodfix.SRCINFO"
    printf 'pkgname=goodfix\nsource=("git+https://example.invalid/g.git#commit=%s")\nsha256sums=(SKIP)\n' "$SHA" \
        > "$ENV_DIR/goodfix.PKGBUILD"
    printf 'pkgbase = badfix\n\tsource = git+https://example.invalid/b.git\n\tsha256sums = SKIP\n\npkgname = badfix\n' \
        > "$ENV_DIR/badfix.SRCINFO"
    : > "$ENV_DIR/yay.log"
    out=$(aur-rebuild-check --fix --noconfirm 2>&1); rc=$?
    if [ "$rc" != "0" ] && grep -q 'REJECT badfix' <<<"$out" \
       && grep -q -- '-S --rebuild --noconfirm goodfix$' "$ENV_DIR/yay.log"; then
        pass "--fix rebuilds what passed and refuses what did not, and the exit status says so"
    else
        fail "--fix mishandled a mixed set (rc=$rc, yay: $(cat "$ENV_DIR/yay.log")): $out"
    fi
    pacman -R --noconfirm goodfix badfix >/dev/null 2>&1
    unset AUR_SRCINFO_URL AUR_PKGBUILD_URL
else
    skip "41: needs the broken ELF from 9-11 and a curl with file:// support"
fi

# 42. Everything readelf prints comes out of a file nobody vouches for. A
# library whose SONAME is a shell payload gives a program that DT_NEEDED string.
payload='libx$(touch${IFS}pwned)`touch${IFS}pwned`.so'
esc=$(printf 'lib\033[31mred.so')
if cc -shared -fPIC -Wl,-soname,"$payload" -o "$ELF/libhostile.so" "$ELF/dep.c" 2>/dev/null \
   && cc -shared -fPIC -Wl,-soname,"$esc" -o "$ELF/libesc.so" "$ELF/dep.c" 2>/dev/null \
   && cc -shared -fPIC -o "$ELF/hostile.so" "$ELF/main.c" "$ELF/libhostile.so" 2>/dev/null \
   && cc -shared -fPIC -o "$ELF/escaped.so" "$ELF/main.c" "$ELF/libesc.so" 2>/dev/null; then
    pacman -U --noconfirm "$(mkpkg hostileapp 1.0-1 --files "$ELF/hostile.so")" >/dev/null 2>&1
    aur_index hostileapp 1
    out=$(cd "$ENV_DIR" && aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -qF 'touch${IFS}pwned' <<<"$out" && [ ! -e "$ENV_DIR/pwned" ]; then
        pass "a hostile DT_NEEDED string is reported as text and never run"
    else
        fail "hostile DT_NEEDED mishandled (rc=$rc, ran: $([ -e "$ENV_DIR/pwned" ] && echo yes || echo no)): $out"
    fi
    pacman -R --noconfirm hostileapp >/dev/null 2>&1
    pacman -U --noconfirm "$(mkpkg escapp 1.0-1 --files "$ELF/escaped.so")" >/dev/null 2>&1
    aur_index escapp 1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'escapp' <<<"$out" && ! grep -q $'\033' <<<"$out"; then
        pass "control characters in a DT_NEEDED string never reach the terminal"
    else
        fail "terminal escape from an ELF reached the report (rc=$rc): $(cat -v <<<"$out")"
    fi
    pacman -R --noconfirm escapp >/dev/null 2>&1
else
    skip "42: could not build a library with a hostile SONAME here"
fi

# =============================================================================
echo ""
echo "== 13-18. remove-versioned-kernel guards =="
# =============================================================================
mkenv kernels
remove-versioned-kernel --noconfirm not-a-kernel >/dev/null 2>&1
[ "$?" = "2" ] \
    && pass "a name that is not linuxNN is rejected (exit 2)" \
    || fail "non-kernel name was accepted"

remove-versioned-kernel --noconfirm linux77 >/dev/null 2>&1
[ "$?" = "0" ] \
    && pass "a kernel that is not installed is a no-op (exit 0)" \
    || fail "uninstalled kernel did not exit 0"

# Build a linux66 that OWNS the running kernel's module directory, so the
# booted-kernel guard has something real to resolve.
RUNNING=$(uname -r)
K66="$ENV_DIR/build/k66"; mkdir -p "$K66/usr/lib/modules/$RUNNING"
echo placeholder > "$K66/usr/lib/modules/$RUNNING/.keep"
{
    echo "pkgname = linux66"; echo "pkgbase = linux66"; echo "pkgver = 6.6.1-1"
    echo "pkgdesc = Satyrus-manjaro loopback fixture"
    echo "url = https://example.invalid"
    echo "builddate = 1700000000"; echo "packager = safeup-test"
    echo "size = 0"; echo "arch = $ARCH"
} > "$K66/.PKGINFO"
( cd "$K66" && bsdtar -czf "$ENV_DIR/build/linux66-booted-$ARCH.pkg.tar.gz" .PKGINFO usr )
pacman -U --noconfirm "$ENV_DIR/build/linux66-booted-$ARCH.pkg.tar.gz" \
    "$(mkpkg linux66-headers 6.6.1-1)" "$(mkpkg linux99 9.9.9-1)" >/dev/null 2>&1

if [ "$(pacman -Qoq "/usr/lib/modules/$RUNNING" 2>/dev/null)" = "linux66" ]; then
    out=$(remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
    if [ "$rc" = "3" ] && grep -q 'currently booted into it' <<<"$out"; then
        pass "refuses to remove the currently-booted kernel (exit 3)"
    else
        fail "booted-kernel guard did not fire (rc=$rc): $(head -1 <<<"$out")"
    fi
else
    skip "15: pacman -Qo could not resolve the running kernel's module dir here"
fi

# Guard 2 is checked before guard 3, so the last-kernel case needs a state
# where NOTHING owns the running kernel's modules. Clear the board and leave a
# single plain linux99 behind.
pacman -R --noconfirm linux66 linux66-headers linux99 >/dev/null 2>&1
pacman -U --noconfirm "$(mkpkg linux99 9.9.9-2)" >/dev/null 2>&1
out=$(remove-versioned-kernel --noconfirm linux99 2>&1); rc=$?
if [ "$rc" = "3" ] && grep -q 'leave 0 versioned kernels' <<<"$out"; then
    pass "refuses to remove the last remaining versioned kernel (exit 3)"
else
    fail "last-kernel guard did not fire (rc=$rc): $(head -1 <<<"$out")"
fi

# A legitimate removal, with an IgnorePkg line to rewrite.
#
# SAFEUP_UKI_DIR is pointed at a path that does NOT exist, deliberately. The
# verification section's probes run after the removal and the IgnorePkg
# rewrite have already succeeded, so a probe that aborts the script there
# turns a completed job into a non-zero exit -- and the machines where that
# happens are exactly the ones whose ESP is not laid out like the author's.
# Pinning the variable makes this case reproducible on every host instead of
# only on the ones that happen to lack the directory.
install_kernel_set() {
    # -nvidia depends on the kernel, as Manjaro's extramodules really do; that
    # dependency is what marks it for removal alongside the kernel.
    pacman -U --noconfirm "$(mkpkg linux66 "$1")" "$(mkpkg linux66-headers "$1")" \
        "$(mkpkg linux66-nvidia "$1" "linux66")" >/dev/null 2>&1
    sed -i 's|^IgnorePkg.*|IgnorePkg = linux66 linux66-headers linux66-nvidia linux99 linux99-headers linux99-nvidia nvidia-utils lib32-nvidia-utils|' "$CONF"
}

install_kernel_set 6.6.1-3
out=$(SAFEUP_UKI_DIR="$ENV_DIR/no-such-uki-dir" \
      remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && ! pacman -Qq linux66 >/dev/null 2>&1 \
   && ! pacman -Qq linux66-headers >/dev/null 2>&1 \
   && ! pacman -Qq linux66-nvidia >/dev/null 2>&1; then
    pass "kernel, headers and -nvidia sibling removed in one transaction"
else
    fail "removal incomplete (rc=$rc): $(pacman -Qq 2>/dev/null | grep linux66 | tr '\n' ' ')"
fi
ign=$(grep '^IgnorePkg' "$CONF")
if ! grep -q 'linux66' <<<"$ign" && grep -q 'linux99' <<<"$ign" \
   && grep -q 'nvidia-utils' <<<"$ign"; then
    pass "IgnorePkg rewritten to the survivors, nvidia userspace kept"
else
    fail "IgnorePkg rewrite wrong: $ign"
fi

# 18. The same removal on a system that DOES have a UKI directory. Guarding a
# probe is only correct if the guard did not also swallow the working case.
UKI="$ENV_DIR/uki"; mkdir -p "$UKI"
: > "$UKI/manjaro-linux99.efi"
install_kernel_set 6.6.1-4
out=$(SAFEUP_UKI_DIR="$UKI" remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'manjaro-linux99.efi' <<<"$out"; then
    pass "removal exits 0 and still lists the UKIs when the directory exists"
else
    fail "UKI-present path broken (rc=$rc): $(grep -i 'boot entries' -A2 <<<"$out" | tr '\n' ' ')"
fi

# =============================================================================
echo ""
echo "== 26-27. every extramodule goes; same-prefix strangers and other IgnorePkg entries stay =="
# =============================================================================
# Manjaro extramodules are named <kernel>-<module> and depend on <kernel>.
# Removing only -headers and -nvidia by name meant pacman refused the whole
# transaction for anyone with -r8168, -zfs or -virtualbox-host-modules. The
# reverse dependency is the criterion, not the name: linux66-rt shares the
# prefix but is a different kernel and must be left alone.
mkenv extramods
pacman -U --noconfirm "$(mkpkg linux66 6.6.1-1)" "$(mkpkg linux66-headers 6.6.1-1)" \
    "$(mkpkg linux66-nvidia 6.6.1-1 "linux66")" "$(mkpkg linux66-r8168 6.6.1-1 "linux66=6.6.1")" \
    "$(mkpkg linux66-rt 6.6.1-1)" "$(mkpkg linux99 9.9.9-1)" >/dev/null 2>&1
sed -i 's|^IgnorePkg.*|IgnorePkg = linux66 linux66-headers linux66-nvidia linux66-r8168 linux99 keep-me-too|' "$CONF"
out=$(SAFEUP_UKI_DIR="$ENV_DIR/no-such-uki-dir" remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
left=$(pacman -Qq 2>/dev/null | grep -Ex 'linux66(-headers|-nvidia|-r8168)?' | tr '\n' ' ')
if [ "$rc" = "0" ] && [ -z "$left" ] \
   && pacman -Qq linux66-rt >/dev/null 2>&1 && pacman -Qq linux99 >/dev/null 2>&1; then
    pass "kernel, headers, -nvidia and -r8168 removed; linux66-rt (no dependency on linux66) kept"
else
    fail "extramodule removal wrong (rc=$rc): left '$left', rt=$(pacman -Qq linux66-rt 2>/dev/null), $(grep -i 'error' <<<"$out" | head -2 | tr '\n' ' ')"
fi
ign=$(grep '^IgnorePkg' "$CONF")
if ! grep -Eq '(^|[[:space:]])linux66(-headers|-nvidia|-r8168)?([[:space:]]|$)' <<<"$ign" \
   && grep -q 'linux99' <<<"$ign" && grep -q 'keep-me-too' <<<"$ign" \
   && ! grep -q 'nvidia-utils' <<<"$ign"; then
    pass "IgnorePkg lost only the evicted kernel's tokens; keep-me-too survived; nothing was added"
else
    fail "IgnorePkg rewrite wrong: $ign"
fi

# =============================================================================
echo ""
echo "== 28. the running-kernel guard fires on a version match alone =="
# =============================================================================
# `pacman -Qo /usr/lib/modules/$(uname -r)` is one point of failure: the
# module directory can be unowned (force-removed package, manual install)
# while that kernel is still the one running. The installed package's version
# is compared with `uname -r` as a second, independent guard.
mkenv verguard
RUNNING=$(uname -r)
KVER="${RUNNING%-*}"     # 6.18.45-1-MANJARO -> 6.18.45-1 ; 6.8.0-1017-azure -> 6.8.0-1017
if [[ "$KVER" == *-* ]]; then
    pacman -U --noconfirm "$(mkpkg linux66 "$KVER")" "$(mkpkg linux99 9.9.9-1)" >/dev/null 2>&1
    out=$(remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
    if [ "$rc" = "3" ] && grep -q 'currently booted' <<<"$out" && pacman -Qq linux66 >/dev/null 2>&1; then
        pass "refuses a kernel whose version matches uname -r ($RUNNING) with nothing owning the module dir"
    else
        fail "version-match guard did not fire (rc=$rc): $(head -2 <<<"$out" | tr '\n' ' ')"
    fi
else
    skip "28: uname -r ($RUNNING) has no <pkgver>-<pkgrel> prefix to build a fixture from"
fi

# 47. The same wrap, on the kernel side: an extramodule whose dependency on the
# kernel sits on a continuation line has to go with it, or pacman refuses.
mkenv kernelwrap
export SAFEUP_UKI_DIR="$ENV_DIR/no-such-dir"
pacman -U --noconfirm \
    "$(mkpkg linux66 6.6.1-1)" "$(mkpkg linux612 6.12.1-1)" \
    "$(mkpkg a-rather-long-dependency-name 1.0-1)" "$(mkpkg another-rather-long-dependency 1.0-1)" \
    "$(mkpkg linux66-widemodule 1.0-1 a-rather-long-dependency-name another-rather-long-dependency linux66)" >/dev/null 2>&1
out=$(COLUMNS=40 remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'removing:.*linux66-widemodule' <<<"$out" && [ -z "$(installed_ver linux66)" ]; then
    pass "an extramodule's dependency on a wrapped line of pacman -Qi is still read"
else
    fail "COLUMNS hid an extramodule from the removal (rc=$rc): $(tail -3 <<<"$out")"
fi

# =============================================================================
echo ""
echo "== 19. --ignore cannot manufacture a partial upgrade =="
# =============================================================================
# The safety argument for this whole suite rests on one property of pacman:
# --ignore suppresses an UPGRADE, it does not suppress DEPENDENCY RESOLUTION.
# If that were not true, safeup's holds would be a partial-upgrade generator
# rather than a partial-upgrade guard, and the tool would be actively harmful.
#
# It is an assumption about pacman rather than about our own code, which is
# exactly why it belongs in a test: nothing in this repository would notice if
# a future pacman changed it, and the consequence would be silent.
mkenv ignoresafety
# consumer 1.0 needs libX=1.0 exactly, and both are installed and consistent.
LIBX1=$(mkpkg libX 1.0-1)
CONS1=$(mkpkg consumer 1.0-1 "libX=1.0")
pacman -U --noconfirm "$LIBX1" "$CONS1" >/dev/null 2>&1
# The repo offers both upgrades; consumer 2.0 requires the NEW libX.
publish "$REPO_M" extra "$(mkpkg libX 2.0-1)" "$(mkpkg consumer 2.0-1 "libX=2.0")"
pacman -Sy >/dev/null 2>&1

# Ignoring libX would strand consumer 2.0 against a libX 2.0 that is not there.
# This is the exact shape of the partial upgrade people fear.
pacman -Syu --noconfirm --ignore libX >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] \
    && pass "pacman refuses an --ignore transaction that would strand a dependency" \
    || fail "pacman accepted a transaction leaving consumer 2.0 without libX 2.0"

if [ "$(installed_ver libX)" = "1.0-1" ] && [ "$(installed_ver consumer)" = "1.0-1" ]; then
    pass "the refused transaction changed nothing — no half-applied upgrade"
else
    fail "system moved: libX=$(installed_ver libX) consumer=$(installed_ver consumer)"
fi

# pacman's own database consistency check is the impartial judge here.
pacman -Dk >/dev/null 2>&1 \
    && pass "pacman -Dk: every dependency still satisfied after the refusal" \
    || fail "pacman -Dk reports an inconsistent system"

# And the same audit after a REAL safeup hold, which is the case that actually
# ships: proving pacman refuses is only useful if safeup's own holds inherit it.
mkenv holdconsistency blackarch
publish "$REPO_M" extra "$(mkpkg libz 1.0-1)"
LIBZ1="$ENV_DIR/build/libz-1.0-1-$ARCH.pkg.tar.gz"
TOOLZ1=$(mkpkg toolz 1.0-1 "libz>=1.0")
publish "$REPO_F" blackarch "$(mkpkg toolz 2.0-1 "libz>=2.0")"
pacman -U --noconfirm "$LIBZ1" "$TOOLZ1" >/dev/null 2>&1
out=$(safeup --noconfirm </dev/null 2>&1)
if grep -q 'hold toolz' <<<"$out" && pacman -Dk >/dev/null 2>&1; then
    pass "after a real safeup hold, pacman -Dk still reports a consistent system"
else
    fail "safeup's hold left the system inconsistent, or did not hold at all"
fi

# =============================================================================
echo ""
echo "== 32. the pre-flight shows a live meter on a terminal, and only there =="
# =============================================================================
# The pre-flight forks pacman once per pending package, so a big sync sat
# silent for minutes and looked hung. A terminal-only feature cannot be proved
# through a pipe, so these run safeup on a real pty with script(1).
meter_tty() { # meter_tty <cols> <typescript> <stdout-file>
    SHELL=/bin/bash script -qec "stty cols $1; safeup --check >'$3'" "$2" </dev/null >/dev/null 2>&1
}
meter_frames() { # every frame the terminal drew, one per line, erase codes gone
    tr '\r' '\n' <"$1" | sed 's/\x1b\[K//g' | grep -aE '^\[safeup\] checking [0-9]+/[0-9]+'
}
if ! command -v script >/dev/null || ! command -v stty >/dev/null; then
    skip "script(1) or stty missing: the meter needs a real pty to be tested"
else
    mkenv meter blackarch
    LONGP=averylongpackagename-that-cannot-fit-on-a-forty-column-line
    publish "$REPO_M" extra "$(mkpkg libm1 1.0-1)"
    MPKGS=("$ENV_DIR/build/libm1-1.0-1-$ARCH.pkg.tar.gz")
    for p in "$LONGP" mone mtwo; do
        MPKGS+=("$(mkpkg "$p" 1.0-1)")
        publish "$REPO_M" extra "$(mkpkg "$p" 2.0-1)"
    done
    MPKGS+=("$(mkpkg toolm 1.0-1 "libm1>=1.0")" "$(mkpkg toolok 1.0-1)")
    publish "$REPO_F" blackarch "$(mkpkg toolm 2.0-1 "libm1>=2.0")" "$(mkpkg toolok 2.0-1)"
    pacman -U --noconfirm "${MPKGS[@]}" >/dev/null 2>&1

    # A second per package, so the ETA has real elapsed time to work from.
    sed -i '2i case " $* " in *" -Si "*) sleep 1 ;; esac' "$SHIM/pacman"
    TTY40="$ENV_DIR/tty40.log"; OUT40="$ENV_DIR/stdout40.txt"
    meter_tty 40 "$TTY40" "$OUT40"; rc=$?
    sed -i '2d' "$SHIM/pacman"
    frames=$(meter_frames "$TTY40")

    [ "$rc" = "0" ] && grep -q 'would hold' "$OUT40" \
        && pass "--check on a terminal still reports the hold and exits 0" \
        || fail "--check on a terminal went wrong (rc=$rc): $(tail -3 "$OUT40" | tr '\n' ' ')"
    missing=""
    for n in 1 2 3 4 5; do grep -q "checking $n/5 " <<<"$frames" || missing+=" $n/5"; done
    [ -z "$missing" ] \
        && pass "every pending package is counted, Manjaro-repo ones included" \
        || fail "meter never showed:$missing"
    # One physical line per hold, plus the one the meter finishes on.
    lines=$(grep -ac 'checking [0-9]/5' "$TTY40")
    [ "$lines" = "2" ] \
        && pass "frames redraw in place instead of scrolling" \
        || fail "frames spread over $lines physical lines, expected 2"
    wide=$(awk 'length($0) > 39' <<<"$frames")
    [ -z "$wide" ] \
        && pass "no frame reaches the edge of a 40-column terminal, so none can wrap" \
        || fail "frame too wide for 40 columns: $(head -1 <<<"$wide")"
    grep -q 'checking 1/5 .*ETA --:--' <<<"$frames" \
        && pass "ETA is withheld until there is something to estimate from" \
        || fail "first frame has no placeholder ETA: $(head -1 <<<"$frames")"
    grep -qE 'checking 3/5 .*ETA 0:0[0-9]' <<<"$frames" \
        && pass "ETA becomes a real figure once packages have been timed" \
        || fail "no numeric ETA by 3/5: $(sed -n 3p <<<"$frames")"
    grep -qaF $'\r\033[K[safeup]   hold toolm' "$TTY40" \
        && pass "a hold message erases the meter first, so it is not glued to a frame" \
        || fail "hold message was written over a live meter line"
    grep -qaF $'\r\033[K[safeup] checked 2 pending' "$TTY40" \
        && pass "the meter is erased when the pre-flight ends" \
        || fail "the last frame was left on screen"
    if ! grep -q $'\r' "$OUT40" && ! grep -q 'checking [0-9]' "$OUT40"; then
        pass "--check's stdout carries no meter, so it stays parseable"
    else
        fail "meter leaked into --check's stdout"
    fi

    TTY100="$ENV_DIR/tty100.log"
    meter_tty 100 "$TTY100" "$ENV_DIR/stdout100.txt"
    frames=$(meter_frames "$TTY100")
    grep -q 'checking 5/5 100% .*\[====================\]' <<<"$frames" \
        && pass "the bar is full at 100%" \
        || fail "no full bar at 5/5: $(tail -1 <<<"$frames")"
    grep -q ' toolok$' <<<"$frames" \
        && pass "the meter names the package being checked" \
        || fail "no package name in: $(tail -1 <<<"$frames")"

    out=$(safeup --check 2>&1 </dev/null)
    if grep -q 'checking 5 pending upgrade' <<<"$out" \
       && ! grep -q $'\r' <<<"$out" && ! grep -q $'\033' <<<"$out"; then
        pass "redirected output gets one plain line and no control characters"
    else
        fail "redirected output wrong: $(head -3 <<<"$out" | cat -v | tr '\n' ' ')"
    fi
fi

# =============================================================================
echo ""
echo "== 48-57. the upgrade, against what a review could make it do =="
# =============================================================================
# 48. Without the AUR package, pacman refuses this. With it, the stand-in added
# for aurpkg used to answer for repopkg as well: the transaction committed, and
# pacman -Dk found the damage afterwards.
mkenv standin
pacman -U --noconfirm "$(mkpkg libd 1.0-1)" "$(mkpkg repopkg 1.0-1 "libd=1.0")" "$(mkpkg aurpkg 1.0-1 "libd=1.0")" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg libd 2.0-1)" "$(mkpkg repopkg 2.0-1 "libd=1.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" != "0" ] && [ "$(installed_ver libd)" = "1.0-1" ] && grep -q 'no stand-in is safe' <<<"$out" \
   && pacman -Dk >/dev/null 2>&1; then
    pass "no stand-in when a repository package is unsatisfiable too: nothing changed, and it says why"
else
    fail "a stand-in hid a repository inconsistency (rc=$rc, libd=$(installed_ver libd)): $(tail -4 <<<"$out")"
fi

# 49. What only the resolver sees.
held_ok() { # held_ok <pkg> <description>: held, and the run went through
    if [ "$rc" = "0" ] && grep -q "hold $1" <<<"$out" && [ "$(installed_ver "$1")" != "2.0-1" ] \
       && [ "$(installed_ver bystander)" = "2.0-1" ]; then
        pass "$2"
    else
        fail "$2 (rc=$rc, bystander=$(installed_ver bystander)): $(tail -5 <<<"$out")"
    fi
}
mkenv ignored blackarch
sed -i 's/^IgnorePkg.*/IgnorePkg = libz/' "$CONF"
pacman -U --noconfirm "$(mkpkg libz 1.0-1)" "$(mkpkg toolz 1.0-1)" "$(mkpkg bystander 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg libz 2.0-1)" "$(mkpkg bystander 2.0-1)"
publish "$REPO_F" blackarch "$(mkpkg toolz 2.0-1 "libz>=2.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
held_ok toolz "a foreign package whose satisfier is in IgnorePkg is held"

mkenv ranged2 blackarch
pacman -U --noconfirm "$(mkpkg libu 1.0-1)" "$(mkpkg toolu 1.0-1)" "$(mkpkg bystander 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg libu 2.0-1)" "$(mkpkg bystander 2.0-1)"
publish "$REPO_F" blackarch "$(mkpkg toolu 2.0-1 "libu<2.0")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
held_ok toolu "a foreign package needing libu<2.0, which this same upgrade breaks, is held"

mkenv newdep blackarch
pacman -U --noconfirm "$(mkpkg toolc 1.0-1)" "$(mkpkg bystander 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg bystander 2.0-1)"
publish "$REPO_F" blackarch "$(mkpkg toolc 2.0-1 newlib)" "$(mkpkg newlib 1.0-1 "libnever>=9")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
held_ok toolc "a foreign upgrade pulling in a dependency that cannot be met is held"

mkenv replaced blackarch
pacman -U --noconfirm "$(mkpkg oldtool 1.0-1)" "$(mkpkg bystander 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg bystander 2.0-1)"
publish "$REPO_F" blackarch "$(MKPKG_EXTRA='replaces = oldtool' mkpkg newtool 1.0-1 "libnever>=9")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'hold newtool' <<<"$out" && [ "$(installed_ver oldtool)" = "1.0-1" ] \
   && [ "$(installed_ver bystander)" = "2.0-1" ]; then
    pass "a foreign package replacing an installed one, with a dependency that cannot be met, is held"
else
    fail "a foreign replacement stopped the upgrade (rc=$rc): $(tail -4 <<<"$out")"
fi

# ...with nothing else pending: a replacement is not in -Qu, so the pre-flight
# has no pending package to start from.
mkenv replacedonly blackarch
pacman -U --noconfirm "$(mkpkg oldtool 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg filler 1.0-1)"
publish "$REPO_F" blackarch "$(MKPKG_EXTRA='replaces = oldtool' mkpkg newtool 1.0-1 "libnever>=9")"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'hold newtool' <<<"$out" && [ "$(installed_ver oldtool)" = "1.0-1" ]; then
    pass "a foreign replacement is held even when nothing else is pending"
else
    fail "a replacement alone stopped the run (rc=$rc): $(tail -4 <<<"$out")"
fi

# An installed foreign package that a Manjaro upgrade breaks. The library is not
# held, and nothing here can rebuild the package: only its repository can.
mkenv behind blackarch
TOOLB=$(mkpkg toolb 1.0-1 "libb<2.0")
pacman -U --noconfirm "$(mkpkg libb 1.0-1)" "$TOOLB" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg libb 2.0-1)"
publish "$REPO_F" blackarch "$TOOLB"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" != "0" ] && grep -q '\[blackarch\] has not caught up' <<<"$out" \
   && [ "$(installed_ver libb)" = "1.0-1" ]; then
    pass "a foreign package left behind stops the run with nothing changed, and says which repository"
else
    fail "a foreign package left behind was misreported (rc=$rc): $(tail -4 <<<"$out")"
fi

# 50. A mirror serving garbage. -Sy can succeed; what it fetched cannot be read.
mkenv garbage blackarch
pacman -U --noconfirm "$(mkpkg toolg 1.0-1)" >/dev/null 2>&1
publish "$REPO_F" blackarch "$(mkpkg toolg 2.0-1)"
head -c 200 /dev/urandom > "$REPO_F/blackarch.db.tar.gz"
out=$(safeup --check </dev/null 2>&1); rc=$?
if [ "$rc" = "1" ] && ! grep -q 'nothing pending' <<<"$out"; then
    pass "unreadable sync databases are an error, never 'nothing pending'"
else
    fail "a garbage database read as a clean result (rc=$rc): $(tail -3 <<<"$out")"
fi

# On a real terminal: script(1) forwards what is written to it as typing.
on_tty() { # on_tty <printf-format input> <command line>
    # shellcheck disable=SC2059
    printf "$1" | SHELL=/bin/bash script -qec "$2" /dev/null 2>&1
}
if command -v script >/dev/null; then
    # 51.
    mkenv prompt
    pacman -U --noconfirm "$(mkpkg widget 1.0-1)" >/dev/null 2>&1
    publish "$REPO_M" extra "$(mkpkg widget 2.0-1)"
    out=$(on_tty '\004' safeup)
    if grep -q 'aborted: no answer' <<<"$out" && [ "$(installed_ver widget)" = "1.0-1" ]; then
        pass "end of file at the master prompt is not a yes"
    else
        fail "Ctrl-D upgraded the system (widget=$(installed_ver widget)): $(tail -2 <<<"$out")"
    fi
    out=$(on_tty 'nope\n' safeup)
    if grep -q 'aborted by user' <<<"$out" && [ "$(installed_ver widget)" = "1.0-1" ]; then
        pass "an unrecognised answer at the master prompt is not a yes"
    else
        fail "'nope' upgraded the system (widget=$(installed_ver widget))"
    fi
    on_tty '\n' safeup >/dev/null
    [ "$(installed_ver widget)" = "2.0-1" ] \
        && pass "Enter at the master prompt takes the [Y] default" \
        || fail "Enter did not proceed (widget=$(installed_ver widget))"

    # 52.
    mkenv declined blackarch
    pacman -U --noconfirm "$(mkpkg toold 1.0-1)" >/dev/null 2>&1
    publish "$REPO_M" extra "$(mkpkg filler 1.0-1)"
    publish "$REPO_F" blackarch "$(mkpkg toold 2.0-1 "libnever>=9")"
    on_tty 'n\n' safeup >/dev/null
    grep -q 'held' "$SAFEUP_LOG" \
        && fail "a declined run logged a hold that never happened" \
        || pass "a declined run logs no hold"
else
    skip "51-52: script(1) is missing; the prompts need a real pty"
fi
mkenv unlogged blackarch
pacman -U --noconfirm "$(mkpkg toold 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg filler 1.0-1)"
publish "$REPO_F" blackarch "$(mkpkg toold 2.0-1 "libnever>=9")"
out=$(SAFEUP_LOG=/nonexistent/dir/safeup.log safeup --noconfirm </dev/null 2>&1)
grep -q 'could not write to /nonexistent' <<<"$out" \
    && pass "a log that cannot be written is reported" \
    || fail "a hold went unrecorded without a word: $(tail -3 <<<"$out")"

# 53. pacman really does exit 0 after Ctrl-C in the middle of a commit.
mkenv interrupted
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$ENV_DIR/aurupdate.log" > "$SHIM/aurupdate"; chmod +x "$SHIM/aurupdate"
pacman -U --noconfirm "$(mkpkg halfway 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg halfway 2.0-1)"
mv "$SHIM/pacman" "$SHIM/pacman.real"
printf '#!/bin/bash\ncase " $* " in *" -Syu "*) "%s" -Sy >/dev/null 2>&1; exit 0 ;; esac\nexec "%s" "$@"\n' \
    "$SHIM/pacman.real" "$SHIM/pacman.real" > "$SHIM/pacman"
chmod +x "$SHIM/pacman"
out=$(safeup --noconfirm --aur </dev/null 2>&1); rc=$?
if [ "$rc" != "0" ] && grep -q 'still pending' <<<"$out" && [ ! -s "$ENV_DIR/aurupdate.log" ]; then
    pass "pacman exiting 0 with upgrades still pending is not clean, and --aur builds nothing on it"
else
    fail "an unfinished upgrade read as clean (rc=$rc, aurupdate: $(cat "$ENV_DIR/aurupdate.log" 2>/dev/null))"
fi

# 54.
mkenv scanlog
publish "$REPO_M" extra "$(mkpkg filler 1.0-1)"
if [ -f "$ELF/libmain.so" ]; then
    pacman -U --noconfirm "$(mkpkg brokenapp 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    aur_index brokenapp 1
    out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
    if grep -q 'broken AUR packages: 1' "$SAFEUP_LOG" && grep -q 'brokenapp' "$SAFEUP_LOG"; then
        pass "what the rebuild scan finds reaches the log as well as the terminal"
    else
        fail "the scan's findings never reached the log: $(cat "$SAFEUP_LOG")"
    fi
else
    skip "54: needs the broken ELF from 9-11"
fi
out=$(PATH="$SHIM:/usr/bin:/bin" "$BIN/safeup" --noconfirm </dev/null 2>&1)
grep -q 'aur-rebuild-check is not on PATH' <<<"$out" \
    && pass "a rebuild scan that could not run says so" \
    || fail "the rebuild scan vanished in silence: $(tail -2 <<<"$out")"

# 55. --aur, both ways
mkenv aurchain
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$ENV_DIR/aurupdate.log" > "$SHIM/aurupdate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$ENV_DIR/aurinstall.log" > "$SHIM/aurinstall"
chmod +x "$SHIM/aurupdate" "$SHIM/aurinstall"
pacman -U --noconfirm "$(mkpkg appq 1.0-1)" "$(mkpkg consq 1.0-1 "appq=1.0")" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg appq 2.0-1)"
out=$(safeup --noconfirm --aur </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q -- '--noconfirm' "$ENV_DIR/aurupdate.log" \
   && grep -qx -- '--install consq' "$ENV_DIR/aurinstall.log"; then
    pass "--aur runs aurupdate after a clean upgrade, and hands the broken package to aurinstall"
else
    fail "--aur chain wrong (rc=$rc, aurupdate: $(cat "$ENV_DIR/aurupdate.log" 2>/dev/null), aurinstall: $(cat "$ENV_DIR/aurinstall.log" 2>/dev/null))"
fi
mkenv aurfail
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$ENV_DIR/aurupdate.log" > "$SHIM/aurupdate"; chmod +x "$SHIM/aurupdate"
mv "$SHIM/pacman" "$SHIM/pacman.real"
printf '#!/bin/bash\ncase " $* " in *" -Syu "*) echo "error: failed to commit transaction" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$SHIM/pacman.real" > "$SHIM/pacman"
chmod +x "$SHIM/pacman"
safeup --noconfirm --aur </dev/null >/dev/null 2>&1; rc=$?
if [ "$rc" != "0" ] && [ ! -s "$ENV_DIR/aurupdate.log" ]; then
    pass "--aur builds nothing after a failed repo upgrade"
else
    fail "--aur ran after a failed upgrade (rc=$rc)"
fi

# 56. --noconfirm answers a conflict prompt with no. A person has to answer it.
mkenv conflict
pacman -U --noconfirm "$(mkpkg oldp 1.0-1)" "$(mkpkg consp 1.0-1)" >/dev/null 2>&1
publish "$REPO_M" extra "$(MKPKG_EXTRA='conflict = oldp' mkpkg newp 1.0-1)" "$(mkpkg consp 2.0-1 newp)"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if grep -q 're-running interactively' <<<"$out" && [ "$(installed_ver consp)" = "1.0-1" ]; then
    pass "a conflict --noconfirm refused is retried for a person to answer, nothing changed meanwhile"
else
    fail "recovery path 1 did not fire (rc=$rc): $(tail -4 <<<"$out")"
fi

# 57. assume_for on a range: the installed version stands in.
mkenv rangedep
pacman -U --noconfirm "$(mkpkg appr 1.0-1)" "$(mkpkg consr 1.0-1 "appr<2.0")" >/dev/null 2>&1
publish "$REPO_M" extra "$(mkpkg appr 2.0-1)"
out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if [ "$rc" = "0" ] && [ "$(installed_ver appr)" = "2.0-1" ] && grep -q "consr (AUR) needs 'appr<2.0'" <<<"$out"; then
    pass "a ranged dependency of an AUR package gets a stand-in, and the repo upgrade lands"
else
    fail "ranged stand-in failed (rc=$rc): $(tail -4 <<<"$out")"
fi

# =============================================================================
echo ""
echo "== 58-64. the rebuild scan, and removing a kernel =="
# =============================================================================
mkenv elf2
ELF2="$ENV_DIR/elf"; mkdir -p "$ELF2"
cp "$ELF"/* "$ELF2/" 2>/dev/null
SHA=0123456789abcdef0123456789abcdef01234567
pinned_fixture() { # the AUR's view of a package that passes the gate
    aur_index "$1" 1
    printf 'pkgbase = %s\n\tsource = git+https://example.invalid/g.git#commit=%s\n\tsha256sums = SKIP\n\npkgname = %s\n' "$1" "$SHA" "$1" \
        > "$ENV_DIR/$1.SRCINFO"
    printf 'pkgname=%s\nsource=("git+https://example.invalid/g.git#commit=%s")\nsha256sums=(SKIP)\n' "$1" "$SHA" \
        > "$ENV_DIR/$1.PKGBUILD"
}
export AUR_SRCINFO_URL="file://$ENV_DIR/%s.SRCINFO" AUR_PKGBUILD_URL="file://$ENV_DIR/%s.PKGBUILD"

# 58.
if [ -f "$ELF2/libmain.so" ] && command -v script >/dev/null; then
    pacman -U --noconfirm "$(mkpkg asked 1.0-1 --files "$ELF2/libmain.so")" >/dev/null 2>&1
    pinned_fixture asked
    : > "$ENV_DIR/yay.log"
    out=$(on_tty 'n\n' aur-rebuild-check)
    if grep -q 'rebuild asked now with yay? \[y/N\]' <<<"$out" && [ ! -s "$ENV_DIR/yay.log" ]; then
        pass "on a terminal the scan asks, there and then, and no means no"
    else
        fail "no inline prompt, or it rebuilt on no (yay: $(cat "$ENV_DIR/yay.log")): $(tail -3 <<<"$out")"
    fi
    on_tty 'y\n' aur-rebuild-check >/dev/null
    grep -q -- '-S --rebuild asked' "$ENV_DIR/yay.log" \
        && pass "yes at the inline prompt rebuilds, past the pin check" \
        || fail "yes did not rebuild: $(cat "$ENV_DIR/yay.log")"
    : > "$ENV_DIR/yay.log"
    out=$(on_tty '' 'aur-rebuild-check --no-prompt')
    if grep -q 'fix: aur-rebuild-check --fix' <<<"$out" && ! grep -q 'now with yay' <<<"$out" && [ ! -s "$ENV_DIR/yay.log" ]; then
        pass "--no-prompt reports and leaves it there, printing the command"
    else
        fail "--no-prompt prompted, or printed no command: $(tail -3 <<<"$out")"
    fi
    out=$(on_tty '' 'aur-rebuild-check --quiet')
    grep -q 'now with yay' <<<"$out" \
        && fail "--quiet, which is for cron, prompted" \
        || pass "--quiet does not prompt"
    pacman -R --noconfirm asked >/dev/null 2>&1

    # 59. safeup, for what the upgrade itself broke
    mkenv offered
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$ENV_DIR/aurinstall.log" > "$SHIM/aurinstall"; chmod +x "$SHIM/aurinstall"
    pacman -U --noconfirm "$(mkpkg appo 1.0-1)" "$(mkpkg conso 1.0-1 "appo=1.0")" >/dev/null 2>&1
    publish "$REPO_M" extra "$(mkpkg appo 2.0-1)"
    out=$(on_tty '\ny\n' safeup)
    if grep -q 'rebuild conso now, through the pin check' <<<"$out" \
       && grep -qx -- '--install conso' "$ENV_DIR/aurinstall.log" 2>/dev/null; then
        pass "safeup offers to rebuild what the upgrade broke, and yes hands it to aurinstall"
    else
        fail "no rebuild offer, or no rebuild: $(tail -4 <<<"$out")"
    fi
    export AUR_SRCINFO_URL="file://$ENV_DIR/%s.SRCINFO" AUR_PKGBUILD_URL="file://$ENV_DIR/%s.PKGBUILD"
else
    skip "58-59: need script(1) and the ELF objects from 9-11"
fi

# 60. silence from the inspector must not read as health
mkenv inspector
ELF2="$ENV_DIR/elf"; mkdir -p "$ELF2"; cp "$ELF"/* "$ELF2/" 2>/dev/null
if [ -f "$ELF2/libmain.so" ]; then
    pacman -U --noconfirm "$(mkpkg brokenapp 1.0-1 --files "$ELF2/libmain.so")" >/dev/null 2>&1
    printf '#!/bin/bash\nexit 1\n' > "$SHIM/readelf"; chmod +x "$SHIM/readelf"
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "2" ] && grep -q 'nothing was checked' <<<"$out" && ! grep -q 'satisfied library links' <<<"$out"; then
        pass "a broken readelf is an error, not 'all clean'"
    else
        fail "a dead readelf read as a clean system (rc=$rc): $out"
    fi
    rm -f "$SHIM/readelf"
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
    # An ELF header with nothing behind it.
    mkdir -p "$ELF2/cut"; head -c 40 "$ELF2/libmain.so" > "$ELF2/cut/libcut.so"
    pacman -U --noconfirm "$(mkpkg cutapp 1.0-1 --files "$ELF2/cut/libcut.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if grep -q 'could not be inspected' <<<"$out"; then
        pass "a file that cannot be parsed is counted, not passed in silence"
    else
        fail "a truncated ELF vanished from the report (rc=$rc): $out"
    fi
    pacman -R --noconfirm cutapp >/dev/null 2>&1

    # 61. the name alone proves nothing
    mkdir -p "$ELF2/txt"; echo 'not a library' > "$ELF2/txt/libdep.so"
    pacman -U --noconfirm "$(mkpkg docapp 1.0-1 --files "$ELF2/libmain.so,$ELF2/txt/libdep.so")" >/dev/null 2>&1
    aur_index docapp 1
    out=$(aur-rebuild-check --no-prompt 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'docapp' <<<"$out"; then
        pass "a text file named like the soname does not excuse a binary"
    else
        fail "the bundled filter accepted a file that is no library (rc=$rc): $out"
    fi
    pacman -R --noconfirm docapp >/dev/null 2>&1
else
    skip "60-61: need the ELF objects from 9-11"
fi

# 62. the loader's rules, at their edges
if [ -f "$ELF2/app.c" ]; then
    mklibapp() { # mklibapp <name> <install-dir> <linker flags...>
        local name=$1 at=$2; shift 2
        cc -o "$ELF2/$name" "$ELF2/app.c" -L"$ELF2" -l:libdep.so "$@" 2>/dev/null
        pacman -U --noconfirm \
            "$(mkpkg "$name" 1.0-1 --at "$at" --files "$ELF2/$name")" \
            "$(mkpkg "$name-lib" 1.0-1 --at "$at/lib" --files "$ELF2/libdep.so")" >/dev/null 2>&1
    }
    mklibapp rpathapp opt/rpathapp -Wl,--disable-new-dtags -Wl,-rpath,'$ORIGIN/lib'
    out=$(aur-rebuild-check --no-prompt 2>&1); rc=$?
    [ "$rc" = "0" ] && pass "DT_RPATH with \$ORIGIN is searched" || fail "DT_RPATH not searched (rc=$rc): $out"
    pacman -R --noconfirm rpathapp rpathapp-lib >/dev/null 2>&1
    mklibapp braceapp opt/braceapp -Wl,--enable-new-dtags -Wl,-rpath,'${ORIGIN}/lib'
    out=$(aur-rebuild-check --no-prompt 2>&1); rc=$?
    [ "$rc" = "0" ] && pass "\${ORIGIN} is expanded like \$ORIGIN" || fail "\${ORIGIN} not expanded (rc=$rc): $out"
    pacman -R --noconfirm braceapp braceapp-lib >/dev/null 2>&1
    mklibapp ampapp 'opt/a&b' -Wl,--enable-new-dtags -Wl,-rpath,'$ORIGIN/lib'
    out=$(aur-rebuild-check --no-prompt 2>&1); rc=$?
    [ "$rc" = "0" ] && pass "an & in a directory name survives \$ORIGIN" || fail "an & broke \$ORIGIN (rc=$rc): $out"
    pacman -R --noconfirm ampapp ampapp-lib >/dev/null 2>&1
    pacman -U --noconfirm "$(mkpkg python 3.13.1-1)" >/dev/null 2>&1
    echo 'x = 1' > "$ELF2/m.py"
    pacman -U --noconfirm "$(mkpkg bundlepy 1.0-1 --at opt/bundle/usr/lib/python3.9/site-packages --files "$ELF2/m.py")" >/dev/null 2>&1
    out=$(aur-rebuild-check --no-prompt 2>&1); rc=$?
    [ "$rc" = "0" ] && pass "a python3.X tree under /opt is the application's own" \
                    || fail "an embedded interpreter tree was flagged (rc=$rc): $out"
    pacman -R --noconfirm bundlepy python >/dev/null 2>&1
else
    skip "62: needs the sources from 24"
fi

# 63. removing a kernel
mkenv series
export SAFEUP_UKI_DIR="$ENV_DIR/no-such-dir"
pacman -U --noconfirm "$(mkpkg linux66 6.6.2-1)" "$(mkpkg linux612 6.12.1-1)" >/dev/null 2>&1
out=$(FAKE_UNAME_R=6.6.1-1-MANJARO remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "3" ] && [ -n "$(installed_ver linux66)" ]; then
    pass "the running series is refused after an in-place upgrade: 6.6.1 running, linux66 at 6.6.2"
else
    fail "the kernel you are standing on was removed (rc=$rc): $(tail -2 <<<"$out")"
fi
out=$(remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'left as-is' <<<"$out" && ! ls "$CONF".bak-* >/dev/null 2>&1 \
   && grep -q 'so nothing was checked' <<<"$out"; then
    pass "an IgnorePkg with nothing to prune is not rewritten; a missing UKI directory is not called ok"
else
    fail "kernel removal output wrong (rc=$rc): $(grep -nE 'IgnorePkg|UKI|checked' <<<"$out" | head -5)"
fi
sed -i 's/^IgnorePkg.*/IgnorePkg = linux612 keepme/' "$CONF"
pacman -U --noconfirm "$(mkpkg linux618 6.18.1-1)" >/dev/null 2>&1
remove-versioned-kernel --noconfirm linux612 >/dev/null 2>&1
if ls "$CONF".bak-* >/dev/null 2>&1 && grep -q '^IgnorePkg = keepme' "$CONF" \
   && grep -q 'linux612' "$(ls "$CONF".bak-* | head -1)"; then
    pass "the IgnorePkg rewrite keeps a backup of the file as it was"
else
    fail "no backup of pacman.conf, or the rewrite is wrong: $(grep IgnorePkg "$CONF")"
fi
unset SAFEUP_UKI_DIR

# 64. The scan reads; nothing it inspects is loaded or run. Section 33 catches an
# `ldd` found on PATH and nothing else, so here the files themselves keep watch:
# a constructor leaves a mark if the object is ever really loaded, and glibc's
# LD_DEBUG log names every object any process's loader was asked for, so `ld.so
# --list`, an absolute /usr/bin/ldd and plain execution are all visible.
mkenv noload
TRAP="$ENV_DIR/trap"; mkdir -p "$TRAP"
cat > "$TRAP/trap.c" <<TRAPC
#include <fcntl.h>
__attribute__((constructor)) static void mark(void) { open("$ENV_DIR/ran", O_CREAT | O_WRONLY, 0644); }
TRAPC
echo 'int main(void) { return 0; }' > "$TRAP/main.c"
if cc -shared -fPIC -o "$TRAP/libtrapwatch.so" "$TRAP/trap.c" 2>/dev/null \
   && cc -o "$TRAP/trapwatch" "$TRAP/main.c" "$TRAP/trap.c" 2>/dev/null; then
    pacman -U --noconfirm "$(mkpkg trapped 1.0-1 --at opt/trapped --files "$TRAP/libtrapwatch.so,$TRAP/trapwatch")" >/dev/null 2>&1
    chmod 755 "$ROOT/opt/trapped/trapwatch"     # mkpkg installs 0644: it has to be runnable
    mkdir -p "$ENV_DIR/lddebug"
    LD_DEBUG=files LD_DEBUG_OUTPUT="$ENV_DIR/lddebug/ld" aur-rebuild-check --no-prompt >/dev/null 2>&1
    named=$(grep -l 'trapwatch' "$ENV_DIR"/lddebug/ld.* 2>/dev/null | wc -l)
    if [ ! -e "$ENV_DIR/ran" ] && [ "$named" = "0" ] && ls "$ENV_DIR"/lddebug/ld.* >/dev/null 2>&1; then
        pass "no package's file was loaded or run: no constructor fired, and no loader was asked for one"
    else
        fail "the scan loaded or ran what it inspects (constructor: $([ -e "$ENV_DIR/ran" ] && echo fired || echo silent), loader logs naming it: $named)"
    fi
else
    skip "64: could not build the watch objects here"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
echo "==================================================="
[ "$FAIL" -eq 0 ]

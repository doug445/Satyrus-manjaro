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
# manjaro-integration-test.sh — the parts of this suite that only a real
# Manjaro install can vouch for.
#
# The other two suites are deliberately hermetic. The fixture suite stubs
# pacman-mirrors, chrootbuild and the AUR; the loopback suite runs the real
# pacman, but in CI it does so inside an Arch container, because that is what
# GitHub can run. Neither one ever meets Manjaro's own pacman.conf, Manjaro's
# branch tooling, the manjaro-chrootbuild that Manjaro actually ships, or the
# live AUR endpoints — and those are exactly the joints where this suite
# touches things it does not control. This one runs on the real thing.
#
# It runs as an ordinary user, against the tools in THIS checkout, and changes
# nothing: no package is installed, no database is refreshed, no file outside
# $TMPDIR is written. (--build is the one exception, and says so below.)
#
# What it proves, on the machine it is run on:
#   M1.  `pacman-mirrors --get-branch` — the exact call aurinstall makes —
#        answers with a branch chrootbuild accepts
#   M2.  manjaro-chrootbuild is carried by one of Manjaro's own repositories
#        under the name deploy.sh installs it by
#   M3.  the installed chrootbuild still takes the flags aurinstall passes,
#        with the arity aurinstall assumes: -b <branch>, -p <pkg>, -n, -c
#   M4.  on the real pacman.conf, safeup calls a repository foreign exactly
#        when it is not served from this install's Manjaro branch — judged
#        independently, from each repository's Server URL
#   M5.  `safeup --check` completes without root against the real mirrors...
#   M6.  ...and the real sync databases are byte-for-byte what they were
#   M7.  aur-rebuild-check scans every foreign package actually installed and
#        reaches a verdict: one it printed at the end, not the header it opens with
#   M8.  ...without an `ldd` on PATH being run once (the loopback suite's section
#        64 is the proof that nothing is loaded by any route)
#   M9.  against the live AUR, a checksummed release package passes the gate
#   M10. ...a -git package that tracks a branch is REJECTED
#   M11. ...a name the AUR does not have is an ERROR, never a pass
#   M15. ...and the AUR's own index is what decides: a split package is judged
#        on its pkgbase, not on any stale branch of that name
#
# With --build (needs sudo; the first chroot costs ~1.1 GiB under
# /var/lib/chrootbuild, and an existing one is updated):
#   M12. aurinstall drives the REAL chrootbuild to a finished package, built
#        from a local stand-in for the AUR holding one trivial PKGBUILD — no
#        upstream code is fetched or run
#   M13. the package it reports is on disk and contains what was packaged
#   M14. the chroot is on the branch this install runs, not chrootbuild's
#        default of `unstable`
#
# Run:  bash tests/manjaro-integration-test.sh            # no root
#       bash tests/manjaro-integration-test.sh --build    # plus M12-M14
# Requires: a Manjaro install, network, and what deploy.sh installs.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"

do_build=0
for a in "$@"; do
    case "$a" in
        --build)   do_build=1 ;;
        -h|--help) sed -n '28,72p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $a (try --help)"; exit 2 ;;
    esac
done

# A green run of this suite anywhere but Manjaro would mean nothing, so it
# refuses rather than skipping its way to "0 failed".
os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
if [[ "$os_id" != manjaro ]]; then
    echo "this suite only means something on Manjaro (found ID='${os_id:-unknown}' in /etc/os-release)"
    exit 1
fi
[[ "$(id -u)" -ne 0 ]] || { echo "run as an ordinary user, not root"; exit 1; }
for c in pacman pacman-conf curl git awk grep sha256sum; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/satyrus-manjaro-test.XXXXXX")
PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
# A check that cannot run here is reported as SKIP. It is never counted as a
# pass — a silent pass is the one outcome these suites exist to prevent.
skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }
cleanup() { cd / && rm -rf "$WORK"; }
trap cleanup EXIT
cd "$WORK" || exit 1

# The tools under test are the ones in this checkout, whatever is deployed.
export PATH="$BIN:$PATH"

echo "== host =="
echo "  $(. /etc/os-release && echo "$PRETTY_NAME") — pacman $(pacman -Q pacman 2>/dev/null | awk '{print $2}')," \
     "glibc $(pacman -Q glibc 2>/dev/null | awk '{print $2}')"

# =============================================================================
echo ""
echo "== M1-M3. branch detection and manjaro-chrootbuild =="
# =============================================================================
branch=""
if command -v pacman-mirrors >/dev/null 2>&1; then
    branch=$(pacman-mirrors --get-branch 2>/dev/null); rc=$?
    case "$branch" in
        stable|testing|unstable|arm-stable|arm-testing|arm-unstable)
            (( rc == 0 )) && pass "pacman-mirrors --get-branch answers '$branch'" \
                          || fail "pacman-mirrors --get-branch printed '$branch' but exited $rc" ;;
        *)  fail "pacman-mirrors --get-branch gave '$branch' (rc=$rc), not a branch chrootbuild accepts" ;;
    esac
else
    fail "pacman-mirrors is not installed — aurinstall cannot detect the branch on this Manjaro"
fi

repo=$(LC_ALL=C pacman -Si manjaro-chrootbuild 2>/dev/null | awk -F': *' '/^Repository/ {print $2; exit}')
case "$repo" in
    core|extra|multilib|community|core-testing|extra-testing|multilib-testing)
        pass "manjaro-chrootbuild is carried by Manjaro's own [$repo]" ;;
    "") fail "no configured repository carries manjaro-chrootbuild — deploy.sh cannot install it" ;;
    *)  fail "manjaro-chrootbuild comes from [$repo], not a Manjaro repository" ;;
esac

if command -v chrootbuild >/dev/null 2>&1; then
    # The getopts string is the contract: which letters exist, and which take
    # an argument. aurinstall builds `[-c] -p <pkg> [-n] ... -b <branch>`.
    opts=$(grep -m1 -oE 'getopts[[:space:]]+"[^"]+"' "$(command -v chrootbuild)" | grep -oE '"[^"]+"' | tr -d '"')
    ok=1; why=""
    [[ "$opts" == *b:* ]] || { ok=0; why+=" -b<arg>"; }
    [[ "$opts" == *p:* ]] || { ok=0; why+=" -p<arg>"; }
    [[ "$opts" == *n* && "$opts" != *n:* ]] || { ok=0; why+=" -n(flag)"; }
    [[ "$opts" == *c* && "$opts" != *c:* ]] || { ok=0; why+=" -c(flag)"; }
    if [[ -n "$opts" ]] && (( ok )); then
        pass "chrootbuild takes -b <branch>, -p <pkg>, -n and -c as aurinstall passes them"
    else
        fail "chrootbuild's options changed under aurinstall (getopts '$opts'; missing:$why)"
    fi
else
    skip "M3: chrootbuild is not installed here (pacman -S manjaro-chrootbuild)"
fi

# =============================================================================
echo ""
echo "== M4. foreign-repository detection on the real pacman.conf =="
# =============================================================================
# safeup decides by NAME (core, extra, multilib, ...). The independent answer
# is where a repository is served from: a Manjaro repository's Server URL runs
# through this install's branch — .../<branch>/<repo>/<arch>. If Manjaro ever
# adds or renames a repository, the two disagree here first.
if [[ -n "$branch" ]]; then
    want=()
    while read -r r; do
        [[ -n "$r" ]] || continue
        pacman-conf --repo "$r" Server 2>/dev/null | grep -q "/$branch/$r/" || want+=("$r")
    done < <(pacman-conf --repo-list)
    # The same expression safeup evaluates, from the same file.
    # shellcheck disable=SC1090
    got=$(
        eval "$(grep -m1 '^MANJARO_REPOS=' "$BIN/safeup")"
        eval "$(sed -n '/^is_manjaro_repo() {/,/^}/p' "$BIN/safeup")"
        pacman-conf --repo-list | while read -r r; do is_manjaro_repo "$r" || echo "$r"; done | tr '\n' ' '
    )
    if [[ "${got% }" == "${want[*]}" ]]; then
        pass "foreign = not served from Manjaro's $branch branch: [${want[*]:-none}]"
    else
        fail "safeup calls [${got% }] foreign; by Server URL it is [${want[*]}]"
    fi
else
    skip "M4: no branch detected, so there is nothing to compare the Server URLs against"
fi

# =============================================================================
echo ""
echo "== M5-M6. safeup --check against the real mirrors =="
# =============================================================================
dbdir="$(pacman-conf DBPath)sync"
db_state() { ( cd "$dbdir" && sha256sum -- *.db 2>/dev/null; stat -c '%n %Y %s' -- *.db 2>/dev/null ); }
before=$(db_state)
mkdir -p "$WORK/tmp"
echo "  (refreshes a private database copy and checks every pending upgrade — minutes on a big sync)"
out=$(TMPDIR="$WORK/tmp" safeup --check 2>&1 </dev/null); rc=$?
after=$(db_state)
check_ran=1
if (( rc == 1 )) && grep -q 'could not refresh the sync databases' <<<"$out"; then
    check_ran=0
    skip "M5: the mirrors could not be reached, so --check never got to run"
elif (( rc == 0 || rc == 2 )); then
    pass "safeup --check completed without root (exit $rc: $( (( rc == 0 )) && echo upgrades pending || echo nothing pending))"
else
    fail "safeup --check failed on a real Manjaro (rc=$rc): $(tail -3 <<<"$out" | tr '\n' ' ')"
fi
leftover=$(find "$WORK/tmp" -mindepth 1 -maxdepth 1 2>/dev/null | head -3)
if (( ! check_ran )); then
    skip "M6: nothing ran that could have touched the databases"
elif [[ "$before" == "$after" && -n "$before" && -z "$leftover" ]]; then
    pass "the real sync databases are unchanged, and no snapshot was left behind"
else
    fail "the pre-flight touched the real sync databases, or left its snapshot (leftover: ${leftover:-none})"
fi

# =============================================================================
echo ""
echo "== M7-M8. aur-rebuild-check on the foreign packages actually installed =="
# =============================================================================
nforeign=$(pacman -Qmq 2>/dev/null | wc -l)
if (( nforeign > 0 )); then
    mkdir -p "$WORK/shim"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexec /usr/bin/ldd "$@"\n' "$WORK/ldd.log" > "$WORK/shim/ldd"
    chmod +x "$WORK/shim/ldd"; : > "$WORK/ldd.log"
    out=$(PATH="$WORK/shim:$PATH" aur-rebuild-check --no-prompt 2>&1 </dev/null); rc=$?
    if (( rc == 0 || rc == 1 )) && grep -q "scanning $nforeign AUR package" <<<"$out" \
       && grep -qE 'satisfied library links|need rebuild|prebuilt package|have no source' <<<"$out"; then
        pass "all $nforeign foreign packages scanned (exit $rc: $( (( rc == 0 )) && echo clean || echo "$(grep -c ' — ' <<<"$out") flagged"))"
    else
        fail "aur-rebuild-check did not finish its scan (rc=$rc): $(tail -2 <<<"$out" | tr '\n' ' ')"
    fi
    [[ ! -s "$WORK/ldd.log" ]] \
        && pass "the ldd on PATH was not run on any of their files" \
        || fail "ldd was run $(wc -l < "$WORK/ldd.log") time(s), first on: $(head -1 "$WORK/ldd.log")"
else
    skip "M7-M8: no foreign packages are installed here"
fi

# =============================================================================
echo ""
echo "== M9-M11. the gate against the live AUR =="
# =============================================================================
# The real cgit and RPC endpoints, which every fixture replaces with a file.
# AUR_PIN_ALLOWLIST is pointed at nothing so a local vetting decision cannot
# change the verdicts. The two named packages are the AUR's own helper: `yay`
# is a checksummed release tarball, `yay-git` builds a branch by definition.
if curl -fsS --max-time 15 -o /dev/null 'https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=yay' 2>/dev/null; then
    out=$(AUR_PIN_ALLOWLIST=/dev/null aur-pin-check --from-aur yay 2>&1); rc=$?
    (( rc == 0 )) \
        && pass "live AUR: yay (release tarball, real checksum) passes" \
        || fail "live AUR: yay was refused (rc=$rc): $(head -3 <<<"$out" | tr '\n' ' ')"
    out=$(AUR_PIN_ALLOWLIST=/dev/null aur-pin-check --from-aur yay-git 2>&1); rc=$?
    if (( rc == 1 )) && grep -q 'REJECT yay-git.*unpinned VCS' <<<"$out"; then
        pass "live AUR: yay-git (tracks a branch) is REJECTED"
    else
        fail "live AUR: yay-git was not rejected as unpinned (rc=$rc): $(head -3 <<<"$out" | tr '\n' ' ')"
    fi
    out=$(aur-pin-check --from-aur satyrus-no-such-package-zz9 2>&1); rc=$?
    if (( rc == 1 )) && grep -q 'ERROR satyrus-no-such-package-zz9' <<<"$out"; then
        pass "live AUR: a name the AUR does not have is an ERROR, not a pass"
    else
        fail "live AUR: a missing package did not surface as an error (rc=$rc)"
    fi
    # xen-docs has a dead cgit branch of its own; the live package is pkgbase xen,
    # which builds a branch. A gate that fetched by name judged a deleted tarball.
    out=$(AUR_PIN_ALLOWLIST=/dev/null aur-pin-check --from-aur xen-docs 2>&1); rc=$?
    if (( rc == 1 )) && grep -q 'REJECT xen-docs.*unpinned VCS' <<<"$out"; then
        pass "live AUR: a split package is judged on its live pkgbase, not a stale branch of its name"
    else
        fail "live AUR: xen-docs was judged on something else (rc=$rc): $(head -3 <<<"$out" | tr '\n' ' ')"
    fi
else
    skip "M9-M11, M15: aur.archlinux.org is not reachable from here"
fi

# =============================================================================
echo ""
echo "== M12-M14. a real chroot build (--build) =="
# =============================================================================
if (( ! do_build )); then
    skip "M12-M14: not requested (re-run with --build; needs sudo and a chroot under /var/lib/chrootbuild)"
elif ! command -v chrootbuild >/dev/null 2>&1 || [[ -z "$branch" ]]; then
    skip "M12-M14: needs chrootbuild and a detected branch"
else
    # A stand-in for the AUR: one git repository holding one PKGBUILD that
    # packages a single text file. aurinstall is pointed at it through the
    # same endpoint overrides the fixture suite uses; everything after that —
    # sudo, chrootbuild, the chroot, makepkg, the branch — is real.
    P=satyrus-integration-fixture
    mkdir -p "$WORK/aur/$P.git" "$WORK/rpc" "$WORK/out"
    cat > "$WORK/aur/$P.git/PKGBUILD" <<'PKGBUILD'
pkgname=satyrus-integration-fixture
pkgver=1.0
pkgrel=1
pkgdesc="Satyrus-manjaro integration fixture (safe to delete)"
arch=('any')
license=('MIT')
package() {
    install -d "$pkgdir/usr/share/satyrus-integration-fixture"
    echo "built in a chroot" > "$pkgdir/usr/share/satyrus-integration-fixture/marker"
}
PKGBUILD
    printf 'pkgbase = %s\n\tpkgdesc = Satyrus-manjaro integration fixture (safe to delete)\n\tpkgver = 1.0\n\tpkgrel = 1\n\tarch = any\n\tlicense = MIT\n\npkgname = %s\n' \
        "$P" "$P" > "$WORK/aur/$P.git/.SRCINFO"
    ( cd "$WORK/aur/$P.git" && git init -q . && git add -A \
        && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
    printf '{"resultcount":1,"results":[{"Name":"%s","PackageBase":"%s"}]}' "$P" "$P" > "$WORK/rpc/$P.json"

    echo "  (sudo chrootbuild -p $P -b $branch — syncs the chroot first; answer Y if asked)"
    out=$(cd "$WORK/out" && \
          AUR_GIT_BASE="file://$WORK/aur" \
          AUR_SRCINFO_URL="file://$WORK/aur/%s.git/.SRCINFO" \
          AUR_PKGBUILD_URL="file://$WORK/aur/%s.git/PKGBUILD" \
          AUR_RPC_URL="file://$WORK/rpc/%s.json" \
          aurinstall --chroot --no-install "$P" 2>&1 | tee /dev/stderr); rc=$?
    if (( rc == 0 )) && grep -q "built against branch '$branch'" <<<"$out"; then
        pass "aurinstall --chroot built a package through the real chrootbuild"
    else
        fail "the real chroot build did not finish (rc=$rc): $(tail -3 <<<"$out" | tr '\n' ' ')"
    fi
    artifact=$(grep -oE "/[^[:space:]]*/$P-1\.0-1-any\.pkg\.tar\.[a-z0-9]+" <<<"$out" | head -1)
    if [[ -n "$artifact" && -f "$artifact" ]] \
       && bsdtar -tf "$artifact" 2>/dev/null | grep -q "usr/share/$P/marker"; then
        pass "the package it reports is on disk and holds what was packaged (${artifact##*/})"
    else
        fail "no usable package where aurinstall said it would be ('${artifact:-none reported}')"
    fi
    # The artifact is this test's own; with PKGDEST set it sits outside $WORK.
    [[ -n "$artifact" && "$artifact" == */"$P"-1.0-1-any.pkg.tar.* ]] && rm -f -- "$artifact"
    cb_branch=$(cat /var/lib/chrootbuild/.branch 2>/dev/null)
    [[ "$cb_branch" == "$branch" ]] \
        && pass "the chroot is on '$branch', the branch this install runs" \
        || fail "the chroot is on '${cb_branch:-unknown}', not '$branch'"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
echo "==================================================="
[ "$FAIL" -eq 0 ]

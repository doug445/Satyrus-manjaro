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
# pin-fixture-test.sh — exercise the supply-chain gate (aur-pin-check, and the
# two wrappers that call it) against synthetic .SRCINFO fixtures and REAL local
# git repositories.
#
# No root. No disk. No network. Nothing outside $TMPDIR is read or written, and
# neither the user's nor the system's git configuration is consulted.
#
# What it proves:
#   1.  a commit-pinned VCS source (#commit=<40-hex>) is ACCEPTED
#   2.  a bare VCS source with no fragment is REJECTED
#   3.  a #tag= source is REJECTED — tags are mutable, that is the whole point
#   4.  a #branch= source is REJECTED (a branch moves every push)
#   5.  a short (<40 hex) commit fragment is REJECTED, not silently accepted
#   6.  non-VCS sources (tarballs) are ACCEPTED when a real checksum covers
#       them (51-60 are the cases where nothing does)
#   7.  a "name::git+..." prefixed source is still recognised as VCS
#   8.  multi-source packages reject if ANY one source is unpinned
#   9.  every rejection is reported, not just the first (multi-package runs)
#   10. the allowlist accepts a tag-pinned source whose tag STILL resolves to
#       the recorded SHA        — against a real git repo via `git ls-remote`
#   11. the allowlist REJECTS the same source once upstream moves the tag
#       — the TOFU property, exercised by actually re-pointing the tag
#   12. an allowlist row whose tag no longer exists is REJECTED, not skipped
#   13. an allowlist row for a DIFFERENT source spec does not launder the pkg
#   14. a package already in a pacman repo is skipped (not an AUR concern)
#   15. an unfetchable .SRCINFO is an ERROR, never a silent pass
#   16. the deleted-from-AUR triage hint fires on resultcount:0
#   17. aurinstall refuses to exec yay when the gate fails, and passes when it
#       succeeds — the gate is load-bearing, not decorative
#   18. aurupdate pin-checks the pending set and aborts on a failure
#   19. --chroot still runs the pin-check gate first, and an unpinned package
#       never reaches chrootbuild
#   20. a dependency in no repo and not in the AUR is refused by the gate
#       itself, before any chroot build or yay run is spent on it
#   21. --chroot always passes an explicit -b <branch>; chrootbuild's default
#       is 'unstable', and building against the wrong branch still exits 0
#       while producing exactly the soname mismatch this suite exists to stop
#   22. --chroot builds the package it was asked for
#   23. auto mode (no flag) uses the chroot when the package is eligible
#   24. auto mode falls back to yay on a chain the chroot will not build
#       (deeper than AURINSTALL_MAX_CHAIN), REPORTING why
#   25. auto mode sends *-bin to yay: nothing is compiled, so a chroot cannot
#       change the shipped ELF and would only cost a chroot sync
#   26. an explicit --chroot on an ineligible package is an ERROR -- forcing a
#       mode and then silently getting another one is the failure this suite
#       exists to prevent
#   27. --no-chroot forces yay even when the chroot would have worked
#   28. a resolvable AUR dependency chain is BUILT, deps first, as one
#       chrootbuild invocation chained with -n (-p dep2 -n -p dep1 -n -p tgt)
#   29. a chained dependency is pin-checked exactly like a named target --
#       an unvetted dep is the same supply-chain hole as an unvetted target
#   30. a dependency cycle is detected and falls back to yay, naming it
#   31. `#commit=<40-hex>?signed` is ACCEPTED — the `?signed` query is makepkg's
#       strongest form, and refusing it penalised the most careful maintainers
#   32. an unpinned VCS source under `source_x86_64 =` is REJECTED — arch-specific
#       source arrays are sources too, and skipping them was a silent pass
#   33. hg `#revision=<40-hex>` is ACCEPTED, bare hg REJECTED — hg has no
#       `#commit=`; its changeset hash is the content-addressed pin
#   34. svn `#revision=N` is ACCEPTED, bare `svn://` REJECTED
#   35. a bare `fossil+` source is REJECTED — it is a VCS makepkg supports, and
#       not recognising it meant accepting it
#   36. a SPLIT package (its own name has no cgit branch) is resolved to its
#       pkgbase through the RPC and judged on the pkgbase's sources, in both
#       directions — instead of an ERROR that blocked the whole upgrade set
#   37. aurinstall builds a split package's PKGBASE in the chroot, once
#   38. with PKGDEST unset, the built package SURVIVES in the invoking
#       directory after a no-install run — it used to be deleted with the
#       temp dir before the "install later" message could even be read
#   39. --install installs the artifact without a prompt; --no-install never
#       touches pacman -U
#   40. a name a binary repo also carries (chaotic-aur carries AUR names) is
#       skipped for yay but checked with --from-aur — and the chroot, which
#       builds the AUR copy regardless, refuses it when it is unpinned
#   41. a source pushed after the check but before the clone is caught: the
#       chroot pin-checks the clone it is about to build
#   42. on the yay path, an unpinned AUR DEPENDENCY is refused; yay never runs
#   43. aurupdate refuses a pending upgrade whose new AUR dependency is unpinned
#   44. a dependency met by an installed package is not walked by --deps
#   45. ...nor one met by a binary repo — yay builds neither
#   46. a name containing '+' is requested URL-encoded; sent raw, the AUR read
#       '+' as a space and the package could never pass
#   47. a .SRCINFO that shows a pin over a PKGBUILD that has none is REJECTED
#   48. a VCS source in the PKGBUILD that the .SRCINFO omits entirely is REJECTED
#   49. variables in a pin, a VCS-looking pkgdesc, comments and build() do not
#       trip the tripwire
#   50. a PKGBUILD that cannot be fetched is an ERROR, never a pass
#   51. a remote tarball whose only checksum is SKIP is REJECTED — makepkg
#       verifies nothing, and builds whatever the URL serves that day
#   52. SKIP under one algorithm is fine when another carries a real hash
#   53. `source_x86_64` is judged against `sha256sums_x86_64`, position by
#       position: a hash in the plain array does not launder an arch source
#   54. SKIP plus a detached signature in the source list is ACCEPTED — both
#       the `.sig` beside the file and kernel.org's `.tar.sign` for a `.tar.xz`
#   55. a "signature" that signs nothing in the list verifies nothing
#   56. `cksums` is a CRC, not an integrity check: alone, it is REJECTED
#   57. a local file (it ships in the AUR repo, beside the PKGBUILD you read)
#       is not a download, and SKIP on it is not a hole
#   58. a .SRCINFO that shows a hash over a PKGBUILD that says SKIP is REJECTED
#   59. SKIP on the VCS sources of a realistic PKGBUILD does not trip that
#   60. aurupdate refuses a pending upgrade whose maintainer switched a
#       checksum to SKIP; yay never runs
#   61. a PKGBUILD that downloads from another URL than its .SRCINFO shows is
#       REJECTED, even with the same hash
#   62. ...or that expects another checksum
#   63. ...or that has more sources than the .SRCINFO admits
#   64. ...or has no such array at all
#   65. ...or differs through a variable: `$pkgver` and a URL held in `$_u` are
#       substituted, so a stale .SRCINFO and a hidden URL both show
#   66. what cannot be known without running it is never a false alarm:
#       ${pkgver%.*}, $(...), a variable assigned twice
#   67. but the literal text around such an expansion must still fit
#   68. arrays set in if/case branches: the branch the .SRCINFO took passes, an
#       entry in no branch is REJECTED, and SKIP cannot hide in a branch
#   69. a word count only the shell knows ("${a[@]}", {a,b}) is no false alarm
#   70. an array for an architecture the .SRCINFO does not list is left alone
#   71. a different signing key is REJECTED: a signature is only as good as the
#       key it is checked against
#   72. an arch-specific checksum is compared against its own array
#   73. text that merely contains `git+` is not a VCS source
#   74. a pin is the whole fragment, read the way makepkg reads it:
#       `#tag=v1?x#commit=<sha>` builds the tag, and is REJECTED
#   75. the index decides what a name is: a stale cgit branch cannot stand in
#       for the live split package behind that name
#   76. a name a binary repo carries, with a dead branch left in cgit, is never
#       built from that branch: the chroot leaves it to yay
#   77. a 200 that is not a .SRCINFO or a PKGBUILD is an ERROR, never a pass
#   78. an RPC error reply is "could not ask", not "deleted"
#   79. a signature is good only for what is fetched with it: one in
#       source_aarch64 does not cover a file in source_x86_64
#   80. a dependency of another architecture is not walked
#   81. control characters in a .SRCINFO never reach the terminal
#   82. something that cannot be a package name is an ERROR, before any request
#   83. AURINSTALL_MODE=chroot means what --chroot means: refuse, do not fall back
#   84. --no-install is refused on the yay path, where it cannot be kept
#   85. --install reaches pacman as --noconfirm, as it promises
#   86. rebuilding the same version with PKGDEST set finds the package: the
#       file name does not change, only the file
#   87. every way of writing a pin that makepkg reads as something else is
#       REJECTED: a value after the last `=`, a `#` in the filename prefix, svn
#       and hg and fossil alike; 64-hex is not a git pin, and is a fossil one
#   88. an allowlisted tag that moved is refused even with a decoy ref named to
#       match the ls-remote pattern; the row only ever matches a plain #tag=
#   89. the allowlist is keyed on the pkgbase, as its header says, and compared
#       byte for byte: a backslash in a .SRCINFO does not match a row
#   90. makepkg's protocol rule decides what is remote: `https+lp:` downloads,
#       `git+https-fix.patch` is a local file
#   91. a VCS entry named like a signature verifies nothing; one signature
#       covers one file, the first makepkg finds
#   92. SKIP with a trailing space is still SKIP
#   93. subscript assignment: `x[0]=SKIP` is applied, consistent ones pass, and
#       a conditional one is no false alarm
#   94. a heredoc body is text; an array that is never closed is not a pass
#   95. a repo group is not a satisfied dependency: yay builds the AUR package
#   96. a broken awk cannot pass a package by reading nothing
#   97. a later argument that looks like an option is not a package name
#   98. a value runs to the end of its line, ` = ` or not
#   99. aurupdate reports an AUR it could not reach as an error, not as nothing
#       pending; passes options to -Qua as well; refuses package names
#   100. --chroot forces a -bin package through the chroot, as documented
#   101. a dependency on a sibling of the same pkgbase is not a cycle
#   102. only what was asked for is installed: an AUR makedepend and a split
#        sibling stay on disk; a runtime dependency goes in with the target
#   103. deploy.sh adds the aliases for every shell present, in that shell's
#        syntax and file, leaves a name you already use alone, keeps a backup,
#        replaces its own block on a second run, and does not ask when told
#   104. deploy.sh's questions can be seen: `read -p` prompts on stderr
#   105. a backup never lands in /etc/logrotate.d, where logrotate would parse it,
#        and two in one second do not overwrite each other
#   106. the drift audit covers the timer
#
# Run:  bash tests/pin-fixture-test.sh
# Requires: bash >= 4, git, curl (with file:// support), awk, coreutils.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"

for c in git curl awk sed grep; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done
curl -V 2>/dev/null | grep -q '\bfile\b' || {
    echo "this curl has no file:// protocol support; cannot run offline fixtures"; exit 1; }

# A commit.gpgsign or a hook in ~/.gitconfig must not decide these results.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
WORK=$(mktemp -d "${TMPDIR:-/tmp}/safeup-pin-test.XXXXXX")
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
cleanup() { cd / && rm -rf "$WORK"; }
trap cleanup EXIT
# Run from inside the scratch tree. aurinstall keeps a built package in the
# directory it was invoked from when PKGDEST is unset (case 38), so a suite run
# from the repository root used to leave *.pkg.tar.zst files in the checkout.
cd "$WORK" || exit 1

mkdir -p "$WORK/srcinfo" "$WORK/pkgbuild" "$WORK/rpc" "$WORK/shim" "$WORK/git"

# --- the environment every invocation below runs under -----------------------
# Endpoints point at local files; the allowlist points at a fixture we rewrite
# between cases. PATH is prefixed with stubs so nothing reaches the real system.
export AUR_SRCINFO_URL="file://$WORK/srcinfo/%s.SRCINFO"
export AUR_PKGBUILD_URL="file://$WORK/pkgbuild/%s.PKGBUILD"
export AUR_RPC_URL="file://$WORK/rpc/%s.json"
export AUR_PIN_ALLOWLIST="$WORK/allowlist.conf"
export PATH="$WORK/shim:$BIN:$PATH"
: > "$WORK/allowlist.conf"

# pacman stub. aur-pin-check asks it these questions and nothing else:
#   -Si <pkg>   → is this package in a binary repo? (then it is not our problem)
#   -T / -Sddp  → is a dependency met by an installed / a repo package? (--deps)
#   -Qq / -Qdtq → is it installed, and is it an orphan? (triage hints only)
# $WORK/repo-pkgs, $WORK/installed and $WORK/orphans drive the answers; a
# dependency is judged by its name, version constraint ignored.
cat > "$WORK/shim/pacman" <<'SHIM'
#!/bin/bash
last="${*: -1}"; dname="${last%%[<>=]*}"
case "$1" in
  -Si)   grep -qxF -- "$last" "$WORK_REPO_PKGS" 2>/dev/null && { echo "Repository : extra"; exit 0; }; exit 1 ;;
  -Sg)   grep -qxF -- "$last" "$WORK_GROUPS" 2>/dev/null && { echo "$last member"; exit 0; }; exit 1 ;;
  -T)    grep -qxF -- "$dname" "$WORK_INSTALLED" 2>/dev/null && exit 0; exit 127 ;;
  -Sddp) grep -qxF -- "$dname" "$WORK_REPO_PKGS" 2>/dev/null && exit 0
         grep -qxF -- "$dname" "$WORK_GROUPS" 2>/dev/null && exit 0; exit 1 ;;
  -Qq)   grep -qxF -- "$last" "$WORK_INSTALLED" 2>/dev/null && { echo "$last"; exit 0; }; exit 1 ;;
  -Qdtq) cat "$WORK_ORPHANS" 2>/dev/null; exit 0 ;;
  -U)    printf '%s\n' "$*" >> "$WORK_PACMAN_LOG"; exit 0 ;;
  *)     exit 1 ;;
esac
SHIM
chmod +x "$WORK/shim/pacman"
export WORK_REPO_PKGS="$WORK/repo-pkgs" WORK_INSTALLED="$WORK/installed" WORK_ORPHANS="$WORK/orphans"
export WORK_GROUPS="$WORK/groups"; : > "$WORK_GROUPS"
export WORK_PACMAN_LOG="$WORK/pacman.log"
: > "$WORK_REPO_PKGS"; : > "$WORK_INSTALLED"; : > "$WORK_ORPHANS"; : > "$WORK_PACMAN_LOG"
# aurinstall reads PKGDEST from makepkg.conf the way chrootbuild does: the
# invoking user's /home/<name>/.makepkg.conf, then the global file. Point the
# global file at nothing, and give `id -un` a name with no home directory, so
# neither of the host's real makepkg.conf files can leak a PKGDEST into the
# fixtures.
export MAKEPKG_CONF=/dev/null
cat > "$WORK/shim/id" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == -un ]] && { echo satyrus-fixture-user; exit 0; }
exec /usr/bin/id "$@"
SHIM
chmod +x "$WORK/shim/id"

# yay stub — records its argv so we can prove whether a gate actually blocked
# the exec, rather than assuming it from an exit code.
cat > "$WORK/shim/yay" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK_YAY_LOG"
# -Qua: emit the pending-upgrade list the aurupdate fixture wants
if [[ "$1" == "-Qua" ]]; then cat "$WORK_YAY_QUA" 2>/dev/null; fi
exit 0
SHIM
chmod +x "$WORK/shim/yay"
export WORK_YAY_LOG="$WORK/yay.log" WORK_YAY_QUA="$WORK/yay-qua"
: > "$WORK_YAY_LOG"; : > "$WORK_YAY_QUA"

# curl wrapper: the real curl, with every URL it was asked for logged. A
# file:// fixture reads '+' literally, where the AUR's web server reads it as a
# space, so only the URL itself shows whether a name was encoded (case 46).
REAL_CURL=$(command -v curl)
cat > "$WORK/shim/curl" <<SHIM
#!/bin/bash
printf '%s\n' "\${*: -1}" >> "\$WORK_CURL_LOG"
exec "$REAL_CURL" "\$@"
SHIM
chmod +x "$WORK/shim/curl"
export WORK_CURL_LOG="$WORK/curl.log"
: > "$WORK_CURL_LOG"

# chrootbuild + pacman-mirrors stubs, for --chroot mode. chrootbuild records
# its argv so we can assert on the branch flag rather than assume it.
cat > "$WORK/shim/chrootbuild" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK_CB_LOG"
# Like the real thing with PKGDEST unset: every -p <pkg> leaves its artifact in
# the directory chrootbuild was started from.
while (( $# )); do
    [[ "$1" == -p ]] && date +%s%N > "${WORK_CB_DEST:-$PWD}/$2-1.0-1-x86_64.pkg.tar.zst"
    shift
done
exit 0
SHIM
cat > "$WORK/shim/pacman-mirrors" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == "--get-branch" ]] && { echo stable; exit 0; }
exit 1
SHIM
# --chroot calls chrootbuild through sudo; run it directly under test.
cat > "$WORK/shim/sudo" <<'SHIM'
#!/bin/bash
exec "$@"
SHIM
chmod +x "$WORK/shim/chrootbuild" "$WORK/shim/pacman-mirrors" "$WORK/shim/sudo"
export WORK_CB_LOG="$WORK/chrootbuild.log"
: > "$WORK_CB_LOG"

# Write a .SRCINFO fixture: srcinfo <pkg> <source-line>... — and the PKGBUILD
# it describes, with the same sources, since the pin check compares the two.
# Checksums are what a real package carries: SKIP for a VCS source (makepkg has
# nothing to hash there; the pin is the integrity), a sha256 for anything else.
HASH_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
sum_for() {
    case "${1#*::}" in
        git+*|git://*|hg+*|hg://*|svn+*|svn://*|bzr+*|bzr://*|fossil+*|fossil://*) echo SKIP ;;
        *) echo "$HASH_A" ;;
    esac
}
srcinfo() {
    local pkg="$1"; shift
    { printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n' "$pkg"
      for s in "$@"; do printf '\tsource = %s\n' "$s"; done
      for s in "$@"; do printf '\tsha256sums = %s\n' "$(sum_for "$s")"; done
      printf '\npkgname = %s\n' "$pkg"
    } > "$WORK/srcinfo/$pkg.SRCINFO"
    { printf 'pkgname=%s\npkgver=1.0\npkgrel=1\nsource=(' "$pkg"
      for s in "$@"; do printf '"%s"\n        ' "$s"; done
      printf ')\nsha256sums=('
      for s in "$@"; do printf "'%s'\n            " "$(sum_for "$s")"; done
      printf ')\n'
    } > "$WORK/pkgbuild/$pkg.PKGBUILD"
}

# Write a fixture from literal .SRCINFO lines: fixture <pkg> "<key> = <value>"...
# The PKGBUILD is built from the same lines, one array per key, in order.
fixture() {
    local pkg="$1" line key; shift
    local -A arr=(); local -a order=()
    { printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n' "$pkg"
      for line in "$@"; do printf '\t%s\n' "$line"; done
      printf '\npkgname = %s\n' "$pkg"
    } > "$WORK/srcinfo/$pkg.SRCINFO"
    for line in "$@"; do
        key=${line%% = *}
        [[ -n "${arr[$key]+x}" ]] || order+=("$key")
        arr[$key]+="'${line#* = }' "
    done
    { printf 'pkgname=%s\npkgver=1.0\npkgrel=1\n' "$pkg"
      for key in "${order[@]}"; do printf '%s=(%s)\n' "$key" "${arr[$key]% }"; done
    } > "$WORK/pkgbuild/$pkg.PKGBUILD"
}

# Replace only the PKGBUILD fixture: pkgbuild <pkg> <file-content>
pkgbuild() { printf '%s\n' "$2" > "$WORK/pkgbuild/$1.PKGBUILD"; }

# Write an AUR RPC fixture: rpc <pkg> <resultcount> [pkgbase]
rpc() {
    if (( $2 > 0 )); then
        printf '{"resultcount":%s,"results":[{"Name":"%s","PackageBase":"%s"}]}' "$2" "$1" "${3:-$1}"
    else
        printf '{"resultcount":%s,"results":[]}' "$2"
    fi > "$WORK/rpc/$1.json"
}

# Run aur-pin-check on one package, capturing combined output.
check() { aur-pin-check "$@" >"$WORK/out" 2>&1; echo $?; }

SHA_A=0123456789abcdef0123456789abcdef01234567

# =============================================================================
echo "== 1-8. pinning policy: what is accepted and what is refused =="
# =============================================================================

srcinfo pinned      "git+https://example.invalid/a.git#commit=$SHA_A"
rpc     pinned 1
[[ $(check pinned) == 0 ]] \
    && pass "commit-pinned git source accepted" \
    || fail "commit-pinned git source rejected: $(cat "$WORK/out")"

srcinfo bare        "git+https://example.invalid/b.git"
rpc     bare 1
[[ $(check bare) == 1 ]] \
    && pass "unfragmented git source rejected" \
    || fail "unfragmented git source was accepted"

srcinfo tagged      "git+https://example.invalid/c.git#tag=v1.2.3"
rpc     tagged 1
rc=$(check tagged)
if [[ $rc == 1 ]] && grep -q 'REJECT tagged' "$WORK/out"; then
    pass "#tag= source rejected (tags are mutable)"
else
    fail "#tag= source not rejected (rc=$rc)"
fi

srcinfo branched    "git+https://example.invalid/d.git#branch=main"
rpc     branched 1
[[ $(check branched) == 1 ]] \
    && pass "#branch= source rejected" \
    || fail "#branch= source was accepted"

# A 12-char SHA is a perfectly valid git ref. It is NOT a valid pin here:
# short hashes can collide, and the policy is 40 hex or nothing.
srcinfo shortsha    "git+https://example.invalid/e.git#commit=0123456789ab"
rpc     shortsha 1
[[ $(check shortsha) == 1 ]] \
    && pass "abbreviated commit fragment rejected (40-hex or nothing)" \
    || fail "abbreviated commit fragment was accepted"

srcinfo tarball     "https://example.invalid/f-1.0.tar.gz"
rpc     tarball 1
[[ $(check tarball) == 0 ]] \
    && pass "non-VCS tarball source accepted (a real sha256 covers it)" \
    || fail "tarball source rejected: $(cat "$WORK/out")"

# `name::git+url` is the renamed-source form. Stripping the prefix is what makes
# it recognisable as VCS at all; getting that wrong means silent acceptance.
srcinfo renamed     "myname::git+https://example.invalid/g.git"
rpc     renamed 1
[[ $(check renamed) == 1 ]] \
    && pass "'name::git+...' prefixed source still recognised as VCS" \
    || fail "renamed VCS source slipped past the parser"

srcinfo mixed       "https://example.invalid/h-1.0.tar.gz" \
                    "git+https://example.invalid/h.git#commit=$SHA_A" \
                    "git+https://example.invalid/h-extra.git"
rpc     mixed 1
rc=$(check mixed)
if [[ $rc == 1 ]] && grep -q 'h-extra.git' "$WORK/out"; then
    pass "multi-source package rejected on its ONE unpinned source"
else
    fail "multi-source package: one unpinned source did not reject (rc=$rc)"
fi

# =============================================================================
echo "== 9. every package is reported, not just the first failure =="
# =============================================================================
rc=$(check bare branched pinned)
if [[ $rc == 1 ]] \
   && grep -q 'REJECT bare' "$WORK/out" \
   && grep -q 'REJECT branched' "$WORK/out"; then
    pass "all failing packages reported in a multi-package run"
else
    fail "multi-package run stopped early or lost a rejection (rc=$rc)"
fi

# =============================================================================
echo "== 10-13. allowlist TOFU against a real git repository =="
# =============================================================================
# A real repo, a real tag, resolved with a real `git ls-remote`. The point of
# these four cases is that the allowlist is not blanket trust: it records the
# SHA a tag pointed at when it was vetted, and re-verifies that every run.
REPO="$WORK/git/upstream"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$REPO" tag v1.0
SHA_V1=$(git -C "$REPO" rev-parse v1.0)
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
SHA_V2=$(git -C "$REPO" rev-parse HEAD)

SPEC="git+file://$REPO#tag=v1.0"
srcinfo allowed "$SPEC"
rpc     allowed 1

printf '%s  %s  %s\n' allowed "$SPEC" "$SHA_V1" > "$WORK/allowlist.conf"
[[ $(check allowed) == 0 ]] \
    && pass "allowlisted tag accepted while it still resolves to the vetted SHA" \
    || fail "allowlisted tag rejected though unmoved: $(cat "$WORK/out")"

# Move the tag — exactly what a compromised or careless upstream would do.
git -C "$REPO" tag -f v1.0 "$SHA_V2" >/dev/null 2>&1
rc=$(check allowed)
if [[ $rc == 1 ]] && grep -q 'tag moved upstream' "$WORK/out"; then
    pass "allowlisted tag REJECTED once upstream re-pointed it (TOFU holds)"
else
    fail "moved tag was still accepted (rc=$rc) — TOFU is broken"
fi
git -C "$REPO" tag -f v1.0 "$SHA_V1" >/dev/null 2>&1   # restore

# A deleted tag must not read as "nothing to verify, therefore fine".
git -C "$REPO" tag -d v1.0 >/dev/null 2>&1
rc=$(check allowed)
if [[ $rc == 1 ]] && grep -q 'did not resolve' "$WORK/out"; then
    pass "allowlisted tag that no longer exists is rejected, not skipped"
else
    fail "vanished tag did not reject (rc=$rc)"
fi
git -C "$REPO" tag v1.0 "$SHA_V1" >/dev/null 2>&1      # restore

# An allowlist row is scoped to one exact source spec. A row for a different
# URL must not launder an unrelated source in the same package.
printf '%s  %s  %s\n' allowed "git+file://$REPO-other#tag=v1.0" "$SHA_V1" > "$WORK/allowlist.conf"
[[ $(check allowed) == 1 ]] \
    && pass "allowlist row for a different source spec does not launder the package" \
    || fail "allowlist matched a source it was not written for"
: > "$WORK/allowlist.conf"

# =============================================================================
echo "== 14-16. scope, fetch failures, and the deleted-package hint =="
# =============================================================================
echo bare > "$WORK_REPO_PKGS"
[[ $(check bare) == 0 ]] \
    && pass "package present in a pacman repo is skipped (not an AUR concern)" \
    || fail "repo package was pin-checked anyway"
: > "$WORK_REPO_PKGS"

# No fixture file exists for this name → curl fails → must be an ERROR, and
# must NOT be reported as a clean pass.
rc=$(check does-not-exist-anywhere)
if [[ $rc == 1 ]] && grep -q 'ERROR' "$WORK/out"; then
    pass "unfetchable .SRCINFO reported as ERROR, never as a pass"
else
    fail "unfetchable .SRCINFO did not surface as an error (rc=$rc)"
fi

# cgit serves deleted packages' repos forever. resultcount:0 is the only signal
# that the PKGBUILD you just read may be years stale — the hint must fire.
srcinfo ghostpkg "git+https://example.invalid/ghost.git"
rpc     ghostpkg 0
check ghostpkg >/dev/null
if grep -q 'NOT in the AUR index' "$WORK/out"; then
    pass "deleted-from-AUR triage hint fires on resultcount:0"
else
    fail "no deleted-package hint for an unindexed package"
fi

# An orphan is better removed than allowlisted forever.
srcinfo orphanpkg "git+https://example.invalid/orphan.git"
rpc     orphanpkg 1
echo orphanpkg > "$WORK_INSTALLED"; echo orphanpkg > "$WORK_ORPHANS"
check orphanpkg >/dev/null
if grep -q 'is an orphan' "$WORK/out"; then
    pass "orphan triage hint fires (prefer -Rns over an allowlist row)"
else
    fail "no orphan hint for an installed orphan"
fi
: > "$WORK_INSTALLED"; : > "$WORK_ORPHANS"

# =============================================================================
echo "== 17-18. the wrappers: is the gate actually load-bearing? =="
# =============================================================================
# An exit code alone does not prove aurinstall stopped: it could have run yay
# and had yay fail. The stub logs its argv, so we check yay was never reached.
: > "$WORK_YAY_LOG"
aurinstall bare >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "aurinstall refuses to exec yay when pin-check rejects"
else
    fail "aurinstall reached yay despite a rejection (rc=$rc, log: $(cat "$WORK_YAY_LOG"))"
fi

: > "$WORK_YAY_LOG"
# --no-chroot, because auto mode now prefers the chroot for an eligible package.
aurinstall --no-chroot pinned >/dev/null 2>&1
if grep -q -- '-S pinned' "$WORK_YAY_LOG"; then
    pass "aurinstall execs 'yay -S' when pin-check passes"
else
    fail "aurinstall did not reach yay on a clean package"
fi

printf 'bare 1.0 -> 2.0\npinned 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate pin-checks the pending set and aborts before 'yay -Sua'"
else
    fail "aurupdate proceeded to -Sua with an unpinned package pending (rc=$rc)"
fi

printf 'pinned 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1
if grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate proceeds to 'yay -Sua' when the pending set is clean"
else
    fail "aurupdate blocked a clean pending set"
fi

# Nothing pending: it still runs `yay -Qua` to find that out, but must exit 0
# without ever reaching the upgrade itself.
: > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 0 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate exits 0 without upgrading when nothing is pending"
else
    fail "empty pending set was not handled cleanly (rc=$rc)"
fi

# =============================================================================
echo "== 19-22. aurinstall --chroot =="
# =============================================================================
# --chroot hands the build to Manjaro's own chrootbuild. The gate must still
# run first, the branch must never be left to chrootbuild's default (which is
# 'unstable' and would silently build against the wrong libraries), and a
# package whose dependencies are themselves in the AUR must be refused BEFORE
# a chroot build is spent on it, since chrootbuild cannot resolve those.

# A local "AUR" to clone from, so no network is touched.
AURGIT="$WORK/aurgit"; mkdir -p "$AURGIT"
# Each repo carries the package's current .SRCINFO and PKGBUILD fixtures, as a
# real AUR repo does: aurinstall pin-checks the CLONE, not the fetched copy.
mk_aur_repo() {
    local pkg="$1"
    local d="$AURGIT/$pkg.git"
    rm -rf "$d"; mkdir -p "$d"
    cp "$WORK/srcinfo/$pkg.SRCINFO" "$d/.SRCINFO"
    cp "$WORK/pkgbuild/$pkg.PKGBUILD" "$d/PKGBUILD"
    ( cd "$d" && git init -q . && git add PKGBUILD .SRCINFO \
      && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
}
export AUR_GIT_BASE="file://$AURGIT"

# 19. the pin-check gate still runs, and nothing reaches chrootbuild
: > "$WORK_CB_LOG"
aurinstall --chroot bare >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "--chroot still refuses an unpinned source before reaching chrootbuild"
else
    fail "--chroot bypassed the pin-check gate (rc=$rc)"
fi

# 20. a dependency that is in no repo and not in the AUR is refused up front,
# by the gate, before a chroot build or a yay run is spent on it — it cannot
# be checked, and an unchecked package is never a pass
srcinfo needsaur "https://example.invalid/x.tar.gz"
printf '\tdepends = totally-not-a-real-package-xyz\n' >> "$WORK/srcinfo/needsaur.SRCINFO"
rpc needsaur 1
rpc totally-not-a-real-package-xyz 0
mk_aur_repo needsaur
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall --chroot needsaur 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'totally-not-a-real-package-xyz (a dependency of needsaur)' <<<"$out" \
   && [[ ! -s "$WORK_CB_LOG" && ! -s "$WORK_YAY_LOG" ]]; then
    pass "an uncheckable dependency is refused by the gate before any build"
else
    fail "uncheckable dependency was not refused up front (rc=$rc): $out"
fi

# 21. a clean package reaches chrootbuild WITH an explicit branch
srcinfo cleanpkg "https://example.invalid/clean.tar.gz"
rpc cleanpkg 1
mk_aur_repo cleanpkg
: > "$WORK_CB_LOG"
aurinstall --chroot --no-install cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-b stable' "$WORK_CB_LOG"; then
    pass "--chroot passes an explicit branch, never chrootbuild's 'unstable' default"
else
    fail "chrootbuild was invoked without an explicit branch: $(cat "$WORK_CB_LOG")"
fi

# 22. ...and the package name is what got built
if grep -q -- '-p cleanpkg' "$WORK_CB_LOG"; then
    pass "--chroot builds the requested package"
else
    fail "wrong package passed to chrootbuild: $(cat "$WORK_CB_LOG")"
fi

# --- the gate, in auto mode -------------------------------------------------
# 23. an eligible package goes to the chroot with no flag at all
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
aurinstall --no-install cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-p cleanpkg' "$WORK_CB_LOG" && ! grep -q -- '-S ' "$WORK_YAY_LOG"; then
    pass "auto mode uses the chroot for an eligible package, with no flag"
else
    fail "auto mode did not choose the chroot (cb='$(cat "$WORK_CB_LOG")')"
fi

# 24. a chain the chroot will not build (here: deeper than AURINSTALL_MAX_CHAIN)
# falls back to yay, and SAYS SO
srcinfo helperdep "https://example.invalid/hd.tar.gz"
rpc helperdep 1; mk_aur_repo helperdep
srcinfo needsaur2 "https://example.invalid/x.tar.gz"
printf '\tdepends = helperdep\n' >> "$WORK/srcinfo/needsaur2.SRCINFO"
rpc needsaur2 1; mk_aur_repo needsaur2
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(AURINSTALL_MAX_CHAIN=1 aurinstall needsaur2 </dev/null 2>&1)
if grep -q -- '-S needsaur2' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]] \
   && grep -q 'using yay: cannot chain-build' <<<"$out"; then
    pass "auto mode falls back to yay on a chain it will not build, reporting why"
else
    fail "auto fallback wrong (yay='$(cat "$WORK_YAY_LOG")', said: $(grep -c 'using yay' <<<"$out"))"
fi

# 25. a -bin package is not worth a chroot; nothing is compiled
srcinfo thing-bin "https://example.invalid/x.tar.gz"
rpc thing-bin 1; mk_aur_repo thing-bin
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall thing-bin </dev/null 2>&1)
if grep -q -- '-S thing-bin' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]] \
   && grep -q 'nothing is compiled' <<<"$out"; then
    pass "auto mode sends a -bin package to yay, saying nothing is compiled"
else
    fail "-bin package was not routed to yay"
fi

# 26. --chroot on an ineligible package is an ERROR, never a silent fallback
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(AURINSTALL_MAX_CHAIN=1 aurinstall --chroot needsaur2 </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cannot be used here' <<<"$out" \
   && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "--chroot refuses an ineligible package instead of quietly using yay"
else
    fail "forced --chroot fell back silently (rc=$rc)"
fi

# 27. --no-chroot forces yay even when the chroot would have worked
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
aurinstall --no-chroot cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-S cleanpkg' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "--no-chroot forces yay even for a chroot-eligible package"
else
    fail "--no-chroot did not force yay"
fi

# --- dependency chains (28-30) -----------------------------------------------
# target -> dep1 -> dep2, none in any repo. The resolver must emit deps first
# and hand chrootbuild ONE invocation: -p dep2 -n -p dep1 -n -p target.
srcinfo chdep2  "https://example.invalid/d2.tar.gz"
srcinfo chdep1  "https://example.invalid/d1.tar.gz"
printf '\tdepends = chdep2\n' >> "$WORK/srcinfo/chdep1.SRCINFO"
srcinfo chtarget "https://example.invalid/t.tar.gz"
printf '\tdepends = chdep1\n' >> "$WORK/srcinfo/chtarget.SRCINFO"
for pkg in chdep2 chdep1 chtarget; do rpc "$pkg" 1; mk_aur_repo "$pkg"; done

# 28. build order computed and chained with -n, in one invocation
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall --no-install chtarget </dev/null 2>&1)
if grep -q -- '-p chdep2 -n -p chdep1 -n -p chtarget' "$WORK_CB_LOG"; then
    pass "chain built deps-first in one run: -p chdep2 -n -p chdep1 -n -p chtarget"
else
    fail "chain order wrong: $(cat "$WORK_CB_LOG")"
fi

# 29. chained deps get pin-checked like named targets: poison the DEEPEST dep
srcinfo chdep2 "git+https://example.invalid/evil.git"
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall chtarget </dev/null 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'REJECT chdep2' <<<"$out" \
   && [[ ! -s "$WORK_CB_LOG" && ! -s "$WORK_YAY_LOG" ]]; then
    pass "an unpinned CHAINED dependency stops the build — deps are gated too"
else
    fail "poisoned chained dep was not caught (rc=$rc)"
fi
srcinfo chdep2 "https://example.invalid/d2.tar.gz"   # restore

# 30. a dependency cycle is refused with a named reason, not an infinite loop
printf '\tdepends = chtarget\n' >> "$WORK/srcinfo/chdep2.SRCINFO"
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(timeout 30 aurinstall chtarget </dev/null 2>&1)
if grep -q 'dependency cycle' <<<"$out" && grep -q -- '-S chtarget' "$WORK_YAY_LOG"; then
    pass "a dependency cycle falls back to yay, naming the cycle"
else
    fail "cycle not handled: $(grep 'using yay' <<<"$out")"
fi

# =============================================================================
echo "== 31-35. the corners of makepkg's VCS syntax =="
# =============================================================================
# `?signed` asks makepkg to verify the commit's signature on top of the pin. It
# follows the fragment, so a pin regex anchored on whitespace-or-end refused the
# one form that is stricter than the policy itself.
srcinfo signedpin "git+https://example.invalid/s.git#commit=$SHA_A?signed"
rpc     signedpin 1
[[ $(check signedpin) == 0 ]] \
    && pass "#commit=<40-hex>?signed accepted (the strongest form is not refused)" \
    || fail "commit pin with ?signed was rejected: $(cat "$WORK/out")"

# .SRCINFO carries arch-specific arrays as `source_x86_64 = ...`. A parser that
# only reads `source =` never sees them — and an unseen source is an accepted one.
{ printf 'pkgbase = archsrc\n\tpkgver = 1.0\n\tpkgrel = 1\n'
  printf '\tsource_x86_64 = git+https://example.invalid/arch.git\n'
  printf '\npkgname = archsrc\n'; } > "$WORK/srcinfo/archsrc.SRCINFO"
pkgbuild archsrc 'source_x86_64=("git+https://example.invalid/arch.git")'
rpc archsrc 1
rc=$(check archsrc)
if [[ $rc == 1 ]] && grep -q 'arch.git' "$WORK/out"; then
    pass "unpinned VCS source under source_x86_64 is rejected (arch arrays are sources too)"
else
    fail "source_x86_64 was not inspected (rc=$rc) — a silent pass"
fi

srcinfo hgpinned "hg+https://example.invalid/h#revision=$SHA_A"
rpc     hgpinned 1
[[ $(check hgpinned) == 0 ]] \
    && pass "hg #revision=<40-hex> accepted (the changeset hash is hg's content-addressed pin)" \
    || fail "hg revision pin rejected: $(cat "$WORK/out")"
srcinfo hgbare "hg+https://example.invalid/h"
rpc     hgbare 1
[[ $(check hgbare) == 1 ]] \
    && pass "bare hg source rejected" \
    || fail "bare hg source accepted"

srcinfo svnpinned "svn+https://example.invalid/svn/trunk#revision=1234"
rpc     svnpinned 1
[[ $(check svnpinned) == 0 ]] \
    && pass "svn #revision=N accepted" \
    || fail "svn revision pin rejected: $(cat "$WORK/out")"
srcinfo svnbare "svn://example.invalid/svn/trunk"
rpc     svnbare 1
[[ $(check svnbare) == 1 ]] \
    && pass "bare svn:// source rejected" \
    || fail "bare svn:// source accepted"

srcinfo fossilbare "fossil+https://example.invalid/f"
rpc     fossilbare 1
[[ $(check fossilbare) == 1 ]] \
    && pass "bare fossil+ source rejected (a VCS makepkg supports is a VCS we check)" \
    || fail "fossil+ source was not recognised as VCS — accepted unpinned"

# =============================================================================
echo "== 36. split packages resolve to their pkgbase =="
# =============================================================================
# cgit serves .SRCINFO per pkgBASE branch. A split package's own name 404s, and
# `aurupdate` would then report an ERROR for it on every run — which, because an
# error blocks the whole set, taught people to bypass the gate with `yay -Sua`.
srcinfo basepkg "git+https://example.invalid/base.git#commit=$SHA_A"
printf 'pkgname = splitpkg\n' >> "$WORK/srcinfo/basepkg.SRCINFO"
rpc     basepkg 1
rpc     splitpkg 1 basepkg          # no splitpkg.SRCINFO exists — only the RPC knows
[[ $(check splitpkg) == 0 ]] \
    && pass "split package resolved to its pkgbase and judged on the pkgbase's (pinned) sources" \
    || fail "split package not resolved: $(cat "$WORK/out")"
srcinfo basepkg "git+https://example.invalid/base.git"        # now unpin the base
printf 'pkgname = splitpkg\n' >> "$WORK/srcinfo/basepkg.SRCINFO"
rc=$(check splitpkg)
if [[ $rc == 1 ]] && grep -q 'REJECT splitpkg' "$WORK/out"; then
    pass "split package REJECTED when its pkgbase carries an unpinned source"
else
    fail "unpinned pkgbase behind a split package slipped through (rc=$rc)"
fi
srcinfo basepkg "https://example.invalid/base.tar.gz"          # clean, for aurinstall below
printf 'pkgname = splitpkg\n' >> "$WORK/srcinfo/basepkg.SRCINFO"

# =============================================================================
echo "== 37-39. aurinstall: split pkgbase, artifact survival, --install =="
# =============================================================================
mk_aur_repo basepkg
: > "$WORK_CB_LOG"
aurinstall --no-install splitpkg </dev/null >/dev/null 2>&1
if grep -q -- '-p basepkg' "$WORK_CB_LOG" && ! grep -q -- '-p splitpkg' "$WORK_CB_LOG"; then
    pass "a split package is built by cloning and building its pkgbase, once"
else
    fail "split package chroot build wrong: $(cat "$WORK_CB_LOG")"
fi

# With PKGDEST unset, chrootbuild leaves the artifact where it was started — a
# temp dir aurinstall removes on exit. The artifact has to be moved somewhere
# durable before that, or "install later with pacman -U <path>" names a file
# that no longer exists by the time the line is printed.
INVOKE="$WORK/invoke"; mkdir -p "$INVOKE"
: > "$WORK_PACMAN_LOG"
out=$(cd "$INVOKE" && aurinstall --no-install cleanpkg </dev/null 2>&1); rc=$?
if (( rc == 0 )) && [[ -f "$INVOKE/cleanpkg-1.0-1-x86_64.pkg.tar.zst" ]] \
   && grep -q "$INVOKE/cleanpkg-1.0-1-x86_64.pkg.tar.zst" <<<"$out"; then
    pass "with PKGDEST unset the built package survives in the invoking directory, and is named"
else
    fail "built package lost or not reported (rc=$rc): $(ls "$INVOKE" 2>/dev/null | tr '\n' ' ') :: $out"
fi
[[ ! -s "$WORK_PACMAN_LOG" ]] \
    && pass "--no-install never reaches pacman -U" \
    || fail "--no-install still installed: $(cat "$WORK_PACMAN_LOG")"

: > "$WORK_PACMAN_LOG"
( cd "$INVOKE" && aurinstall --install cleanpkg </dev/null >/dev/null 2>&1 )
if grep -q -- '-U .*cleanpkg-1.0-1-x86_64.pkg.tar.zst' "$WORK_PACMAN_LOG"; then
    pass "--install runs pacman -U on the built artifact without a prompt"
else
    fail "--install did not install: $(cat "$WORK_PACMAN_LOG")"
fi

# =============================================================================
echo "== 40-41. what the chroot BUILDS is what gets checked =="
# =============================================================================
# 40. chaotic-aur carries AUR names. `yay -S` would install that repo copy, so
# a plain check skips the name — but the chroot builds the AUR's copy anyway.
srcinfo chaoticpkg "git+https://example.invalid/chaotic.git"
rpc chaoticpkg 1; mk_aur_repo chaoticpkg
echo chaoticpkg > "$WORK_REPO_PKGS"
if [[ $(check chaoticpkg) == 0 && $(check --from-aur chaoticpkg) == 1 ]]; then
    pass "a repo-carried name is skipped for yay, and checked with --from-aur"
else
    fail "--from-aur did not check a repo-carried name"
fi
: > "$WORK_CB_LOG"
out=$(aurinstall --no-install chaoticpkg </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'REJECT chaoticpkg' <<<"$out" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "the chroot refuses to build the AUR copy of a repo-carried name with an unpinned source"
else
    fail "chroot built an unchecked repo-carried name (rc=$rc, cb='$(cat "$WORK_CB_LOG")')"
fi
: > "$WORK_REPO_PKGS"

# 41. a push between the gate and the clone: the AUR said one thing when it
# was checked, and the clone that gets built says another
srcinfo racepkg "https://example.invalid/race.tar.gz"
rpc racepkg 1; mk_aur_repo racepkg
printf 'pkgbase = racepkg\n\tsource = git+https://example.invalid/late.git\n\npkgname = racepkg\n' \
    > "$AURGIT/racepkg.git/.SRCINFO"
printf 'pkgname=racepkg\nsource=("git+https://example.invalid/late.git")\n' > "$AURGIT/racepkg.git/PKGBUILD"
git -C "$AURGIT/racepkg.git" -c user.email=t@t -c user.name=t commit -qam late >/dev/null 2>&1
: > "$WORK_CB_LOG"
out=$(aurinstall --no-install racepkg </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cloned build chain failed' <<<"$out" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "a source pushed after the check but before the clone is caught in the clone"
else
    fail "the clone was built unchecked (rc=$rc)"
fi

# =============================================================================
echo "== 42-45. --deps: the AUR dependencies yay would build =="
# =============================================================================
srcinfo yaydep "git+https://example.invalid/yaydep.git"
rpc yaydep 1
srcinfo yaytop "https://example.invalid/yaytop.tar.gz"
printf '\tdepends = yaydep>=1.0\n' >> "$WORK/srcinfo/yaytop.SRCINFO"
rpc yaytop 1

# 42. the yay path: before, only the named package was checked
: > "$WORK_YAY_LOG"
out=$(aurinstall --no-chroot yaytop </dev/null 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'REJECT yaydep' <<<"$out" && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "aurinstall --no-chroot refuses an unpinned AUR dependency; yay never runs"
else
    fail "an unpinned AUR dependency reached yay (rc=$rc, yay='$(cat "$WORK_YAY_LOG")')"
fi

# 43. aurupdate: an upgrade can bring in a new AUR dependency
printf 'yaytop 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate refuses a pending upgrade whose new AUR dependency is unpinned"
else
    fail "aurupdate let an unpinned AUR dependency through (rc=$rc)"
fi
: > "$WORK_YAY_QUA"

# 44-45. a dependency yay will NOT build is not walked: one an installed
# package meets, and one a binary repo meets. Walking those would refuse
# packages over sources nobody is about to build.
srcinfo yaytop2 "https://example.invalid/yaytop2.tar.gz"
printf '\tdepends = instdep\n\tmakedepends = repodep\n' >> "$WORK/srcinfo/yaytop2.SRCINFO"
rpc yaytop2 1
echo instdep > "$WORK_INSTALLED"; echo repodep > "$WORK_REPO_PKGS"
[[ $(check --deps yaytop2) == 0 ]] \
    && pass "a dependency met by an installed package is not walked" \
    || fail "an installed dependency was walked: $(cat "$WORK/out")"
: > "$WORK_INSTALLED"
echo instdep > "$WORK_REPO_PKGS"; echo repodep >> "$WORK_REPO_PKGS"
[[ $(check --deps yaytop2) == 0 ]] \
    && pass "a dependency met by a binary repo is not walked" \
    || fail "a repo dependency was walked: $(cat "$WORK/out")"
: > "$WORK_REPO_PKGS"

# =============================================================================
echo "== 46. package names containing '+' =="
# =============================================================================
# Sent raw, '+' reaches cgit and the RPC as a space: `aewm++` was a 404 and
# could never pass. Encoded, the file:// fixture resolves exactly as cgit does.
srcinfo 'aewm++' "https://example.invalid/aewm.tar.gz"
rpc 'aewm++' 1
: > "$WORK_CURL_LOG"
rc=$(check 'aewm++')
if [[ $rc == 0 ]] && grep -q 'aewm%2B%2B' "$WORK_CURL_LOG" && ! grep -qF 'aewm++' "$WORK_CURL_LOG"; then
    pass "'aewm++' is requested as aewm%2B%2B, fetched and judged"
else
    fail "a '+' name was sent unencoded (rc=$rc): $(cat "$WORK_CURL_LOG")"
fi

# =============================================================================
echo "== 47-50. the PKGBUILD tripwire =="
# =============================================================================
# 47. the spoof: a .SRCINFO showing a pin, over a PKGBUILD that has none
srcinfo spoofed "git+https://example.invalid/s.git#commit=$SHA_A"
rpc spoofed 1
pkgbuild spoofed 'pkgname=spoofed
source=("git+https://example.invalid/evil.git")'
rc=$(check spoofed)
if [[ $rc == 1 ]] && grep -q 'does not match its .SRCINFO' "$WORK/out" && grep -q 'evil.git' "$WORK/out"; then
    pass "a .SRCINFO that hides an unpinned PKGBUILD source is REJECTED"
else
    fail "spoofed .SRCINFO accepted (rc=$rc)"
fi

# 48. a PKGBUILD naming a VCS source under a .SRCINFO that names none
srcinfo spoofed2 "https://example.invalid/s.tar.gz"
rpc spoofed2 1
pkgbuild spoofed2 "pkgname=spoofed2
source=(\"git+https://example.invalid/x.git#commit=$SHA_A\")"
[[ $(check spoofed2) == 1 ]] \
    && pass "a VCS source missing from .SRCINFO entirely is REJECTED" \
    || fail "a VCS source absent from .SRCINFO was accepted"

# 49. no false alarm on what real PKGBUILDs look like: variables in the pin,
# a VCS-looking string in pkgdesc, a commented-out source, a multi-line array
srcinfo realistic "git+https://example.invalid/r.git#commit=$SHA_A" "r.patch::https://example.invalid/r.patch"
rpc realistic 1
pkgbuild realistic "pkgname=realistic
pkgdesc=\"a git+svn bridge\"
url=https://example.invalid/r
_commit=$SHA_A
# source=(git+https://example.invalid/old.git)
source=(\"git+\$url.git#commit=\${_commit}\"   # git+https://in.a.comment
        \"r.patch::https://example.invalid/r.patch\")
sha256sums=('SKIP' '$HASH_A')
build() { echo git+https://not.a.source; }"
[[ $(check realistic) == 0 ]] \
    && pass "variables, pkgdesc, comments and build() do not trip the tripwire" \
    || fail "realistic PKGBUILD falsely rejected: $(cat "$WORK/out")"

# 50. a PKGBUILD that cannot be fetched is an ERROR, never a pass
srcinfo nopkgbuild "https://example.invalid/n.tar.gz"
rpc nopkgbuild 1
rm -f "$WORK/pkgbuild/nopkgbuild.PKGBUILD"
rc=$(check nopkgbuild)
if [[ $rc == 1 ]] && grep -q 'cannot fetch the PKGBUILD' "$WORK/out"; then
    pass "an unfetchable PKGBUILD is an ERROR, never a silent pass"
else
    fail "unfetchable PKGBUILD did not surface as an error (rc=$rc)"
fi

# =============================================================================
echo "== 51-60. a download nothing verifies =="
# =============================================================================
# "Tarballs pass, sha256sums cover them" was the gate's stated reason for
# looking at VCS sources only. makepkg accepts SKIP in a checksum array for ANY
# source, and then verifies nothing: a tarball URL under SKIP is exactly as
# mutable as an unpinned branch, and it used to walk through.
T=https://example.invalid

# 51. the hole itself
fixture skiptar "source = $T/latest.tar.gz" "sha256sums = SKIP"
rpc skiptar 1
rc=$(check skiptar)
if [[ $rc == 1 ]] && grep -q 'REJECT skiptar' "$WORK/out" && grep -q 'latest.tar.gz' "$WORK/out"; then
    pass "a remote tarball whose only checksum is SKIP is REJECTED, naming the URL"
else
    fail "an unverified tarball was accepted (rc=$rc): $(cat "$WORK/out")"
fi

# 52. makepkg checks every algorithm given; one real hash is verification
fixture twoalgo "source = $T/a.tar.gz" "sha256sums = SKIP" "b2sums = $HASH_A$HASH_A"
rpc twoalgo 1
[[ $(check twoalgo) == 0 ]] \
    && pass "SKIP under sha256sums with a real b2sums is accepted" \
    || fail "a source with one real checksum was rejected: $(cat "$WORK/out")"

# 53. arch arrays pair with arch checksums, by position
fixture archskip "source = $T/common.tar.gz" "sha256sums = $HASH_A" \
                 "source_x86_64 = $T/blob-x86_64.tar.gz" "sha256sums_x86_64 = SKIP"
rpc archskip 1
rc=$(check archskip)
if [[ $rc == 1 ]] && grep -q 'blob-x86_64.tar.gz' "$WORK/out" && ! grep -q 'common.tar.gz' "$WORK/out"; then
    pass "SKIP under sha256sums_x86_64 is REJECTED; the plain array's hash does not cover it"
else
    fail "an arch-specific unverified source slipped through (rc=$rc): $(cat "$WORK/out")"
fi
fixture posskip "source = $T/one.tar.gz" "source = $T/two.tar.gz" \
                "sha256sums = $HASH_A" "sha256sums = SKIP"
rpc posskip 1
rc=$(check posskip)
if [[ $rc == 1 ]] && grep -q 'two.tar.gz' "$WORK/out" && ! grep -q 'one.tar.gz' "$WORK/out"; then
    pass "checksums pair with sources by position: only the SKIP one is named"
else
    fail "positional pairing wrong (rc=$rc): $(cat "$WORK/out")"
fi

# 54. the signature alternative. makepkg verifies a source against a detached
# signature listed beside it, and refuses the build when that fails; SKIP on
# both is how signed upstreams are normally packaged.
fixture signed "source = $T/s-1.0.tar.gz" "source = $T/s-1.0.tar.gz.sig" \
               "validpgpkeys = ABCDEF0123456789ABCDEF0123456789ABCDEF01" \
               "sha256sums = SKIP" "sha256sums = SKIP"
rpc signed 1
[[ $(check signed) == 0 ]] \
    && pass "SKIP with a detached .sig in the source list is accepted" \
    || fail "a signed source was rejected: $(cat "$WORK/out")"
# kernel.org signs the uncompressed tar: linux.tar.xz is verified by linux.tar.sign
fixture ksigned "source = $T/k-6.1.tar.xz" "source = $T/k-6.1.tar.sign" \
                "sha256sums = SKIP" "sha256sums = SKIP"
rpc ksigned 1
[[ $(check ksigned) == 0 ]] \
    && pass "a .tar.sign covering a .tar.xz (kernel.org's form) is accepted" \
    || fail "kernel.org-style signature was rejected: $(cat "$WORK/out")"

# 55. a .sig that signs nothing listed is just another unverified download
fixture orphansig "source = $T/real.tar.gz" "source = $T/other.tar.gz.sig" \
                  "sha256sums = SKIP" "sha256sums = SKIP"
rpc orphansig 1
rc=$(check orphansig)
if [[ $rc == 1 ]] && grep -q 'real.tar.gz' "$WORK/out"; then
    pass "a signature for some other file does not cover a SKIP source"
else
    fail "an unrelated .sig laundered a SKIP source (rc=$rc): $(cat "$WORK/out")"
fi

# 56. cksums is POSIX cksum — a CRC anyone can match
fixture crconly "source = $T/c.tar.gz" "cksums = 1234567890"
rpc crconly 1
[[ $(check crconly) == 1 ]] \
    && pass "a CRC (cksums) alone is not verification: REJECTED" \
    || fail "a CRC-only source was accepted"

# 57. a local file is not a download
fixture localskip "source = $T/l.tar.gz" "source = fix-build.patch" \
                  "sha256sums = $HASH_A" "sha256sums = SKIP"
rpc localskip 1
[[ $(check localskip) == 0 ]] \
    && pass "SKIP on a local file shipped in the AUR repo is accepted" \
    || fail "a local file under SKIP was rejected: $(cat "$WORK/out")"

# 58. the spoof, checksum edition: .SRCINFO shows a hash, the PKGBUILD — the
# file makepkg actually obeys — says SKIP. Unquoted and side by side, as a
# PKGBUILD may write them: the count is of array elements, not of a pattern.
fixture sumspoof "source = git+$T/p.git#commit=$SHA_A" "source = $T/p.tar.gz" \
                 "sha256sums = SKIP" "sha256sums = $HASH_A"
rpc sumspoof 1
pkgbuild sumspoof "pkgname=sumspoof
source=(\"git+$T/p.git#commit=$SHA_A\" \"$T/p.tar.gz\")
sha256sums=(SKIP SKIP)"
rc=$(check sumspoof)
if [[ $rc == 1 ]] && grep -q 'does not match its .SRCINFO' "$WORK/out" && grep -q 'sha256sums' "$WORK/out"; then
    pass "a .SRCINFO showing a hash over a PKGBUILD that says SKIP is REJECTED"
else
    fail "a hidden SKIP was accepted (rc=$rc): $(cat "$WORK/out")"
fi

# 59. no false alarm: SKIP where it belongs, comments, += and a multi-line array
fixture sumreal "source = git+$T/r.git#commit=$SHA_A" "source = $T/r.tar.gz" \
                "source = $T/r2.tar.gz" \
                "sha256sums = SKIP" "sha256sums = $HASH_A" "sha256sums = $HASH_A"
rpc sumreal 1
pkgbuild sumreal "pkgname=sumreal
source=(\"git+$T/r.git#commit=$SHA_A\"
        \"$T/r.tar.gz\")
# sha256sums=('SKIP' 'SKIP' 'SKIP')
sha256sums=('SKIP'   # the git source: SKIP is correct here
            '$HASH_A')
source+=(\"$T/r2.tar.gz\")
sha256sums+=('$HASH_A')
build() { echo \"sha256sums=('SKIP')\"; }"
[[ $(check sumreal) == 0 ]] \
    && pass "SKIP on a pinned VCS source, comments and += do not trip the checksum tripwire" \
    || fail "realistic checksum arrays falsely rejected: $(cat "$WORK/out")"

# 60. the upgrade that quietly drops verification
printf 'skiptar 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate refuses a pending upgrade whose download nothing verifies"
else
    fail "aurupdate let an unverified download through (rc=$rc)"
fi
: > "$WORK_YAY_QUA"

# =============================================================================
echo "== 61-73. a PKGBUILD must describe what its .SRCINFO describes =="
# =============================================================================
# makepkg obeys the PKGBUILD, and the gate judges the .SRCINFO. So the verdict
# means something only while they agree; the tripwire above compared VCS sources
# and SKIP counts, and left every other URL and hash to the maintainer's word.
differs() { # differs <pkg> <text the report must contain> <description>
    local rc; rc=$(check "$1")
    if [[ $rc == 1 ]] && grep -q 'does not match its .SRCINFO' "$WORK/out" && grep -qF -- "$2" "$WORK/out"; then
        pass "$3"
    else
        fail "$3 (rc=$rc): $(cat "$WORK/out")"
    fi
}
agrees() { # agrees <pkg> <description>
    [[ $(check "$1") == 0 ]] && pass "$2" || fail "$2: $(cat "$WORK/out")"
}
HASH_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# 61-64. the plain cases
fixture urlspoof "source = $T/good-1.0.tar.gz" "sha256sums = $HASH_A"; rpc urlspoof 1
pkgbuild urlspoof "pkgname=urlspoof
source=('$T/evil-1.0.tar.gz')
sha256sums=('$HASH_A')"
differs urlspoof 'evil-1.0.tar.gz' "another download URL than the .SRCINFO shows is REJECTED, even with the same hash"

fixture sumdiff "source = $T/s.tar.gz" "sha256sums = $HASH_A"; rpc sumdiff 1
pkgbuild sumdiff "pkgname=sumdiff
source=('$T/s.tar.gz')
sha256sums=('$HASH_B')"
differs sumdiff "$HASH_B" "another checksum than the .SRCINFO shows is REJECTED"

fixture hidden "source = $T/h.tar.gz" "sha256sums = $HASH_A"; rpc hidden 1
pkgbuild hidden "pkgname=hidden
source=('$T/h.tar.gz' '$T/extra.tar.gz')
sha256sums=('$HASH_A' '$HASH_B')"
differs hidden '2 entries in the PKGBUILD, 1 in the .SRCINFO' "a source the .SRCINFO does not admit to is REJECTED"

fixture noarray "source = $T/n.tar.gz" "sha256sums = $HASH_A"; rpc noarray 1
pkgbuild noarray 'pkgname=noarray
sha256sums[0]=whatever'
differs noarray 'no such array in the PKGBUILD' "a source array absent from the PKGBUILD is REJECTED"

# 65. variables are looked up, not trusted
fixture vars "source = foo-1.2.tar.gz::$T/foo-1.2.tar.gz" "sha256sums = $HASH_A"; rpc vars 1
pkgbuild vars "pkgname=foo
pkgver='1.2' # a comment
url=\"$T\"
source=(\"\$pkgname-\${pkgver}.tar.gz::\$url/foo-\$pkgver.tar.gz\")
sha256sums=('$HASH_A')"
agrees vars "\$pkgver, \${pkgver} and \$url in a source are substituted and fit"

fixture stale "source = $T/foo-1.2.tar.gz" "sha256sums = $HASH_A"; rpc stale 1
pkgbuild stale "pkgname=foo
pkgver=1.3
source=(\"$T/foo-\$pkgver.tar.gz\")
sha256sums=('$HASH_A')"
differs stale 'foo-1.3.tar.gz' "a .SRCINFO left behind by a version bump is REJECTED"

fixture viavar "source = $T/good.tar.gz" "sha256sums = $HASH_A"; rpc viavar 1
pkgbuild viavar "pkgname=viavar
_u=$T/evil.tar.gz
_v=\$_u
source=(\"\$_v\")
sha256sums=('$HASH_A')"
differs viavar 'evil.tar.gz' "a different URL held in a variable, even at one remove, is REJECTED"

fixture pinvar "source = git+$T/p.git#commit=$SHA_A" "sha256sums = SKIP"; rpc pinvar 1
pkgbuild pinvar "pkgname=pinvar
_c=v1.0
source=(\"git+$T/p.git#commit=\$_c\")
sha256sums=('SKIP')"
differs pinvar '#commit=v1.0' "a tag behind #commit=\$var, under a .SRCINFO showing a SHA, is REJECTED"

# 66. what only the shell knows
fixture opaque "source = $T/1.2/foo-1.2.3-$(uname -m).tar.gz" "sha256sums = $HASH_A"; rpc opaque 1
pkgbuild opaque "pkgname=foo
pkgver=1.2.3
_twice=a
_twice=b
source=(\"$T/\${pkgver%.*}/foo-\$pkgver-\$(uname -m).tar\${_twice:+}.gz\")
sha256sums=('$HASH_A')"
agrees opaque "\${pkgver%.*}, \$(...) and \${x:+} are wildcards, never a false alarm"

fixture twice "source = $T/b.tar.gz" "sha256sums = $HASH_A"; rpc twice 1
pkgbuild twice "pkgname=twice
_f=a
_f=b
source=(\"$T/\$_f.tar.gz\")
sha256sums=('$HASH_A')"
agrees twice "a variable assigned twice is not guessed at"

# 67. the text around an expansion still counts
fixture around "source = $T/1.2/foo.tar.gz" "sha256sums = $HASH_A"; rpc around 1
pkgbuild around "pkgname=foo
pkgver=1.2.3
source=(\"https://evil.invalid/\${pkgver%.*}/foo.tar.gz\")
sha256sums=('$HASH_A')"
differs around 'evil.invalid' "the literal text around an expansion must still fit"

# 68. only one branch reached the .SRCINFO
branches="pkgname=br
if [[ \$CARCH == x86_64 ]]; then
source=('$T/x86.tar.gz')
sha256sums=('$HASH_A')
else
    source=('$T/arm.tar.gz')
    sha256sums=('$HASH_B')
fi"
fixture branch "source = $T/x86.tar.gz" "sha256sums = $HASH_A"; rpc branch 1
pkgbuild branch "$branches"
agrees branch "arrays set in if/else branches: the branch the .SRCINFO took passes"

fixture nobranch "source = $T/riscv.tar.gz" "sha256sums = $HASH_A"; rpc nobranch 1
pkgbuild nobranch "$branches"
differs nobranch 'riscv.tar.gz' "an entry in no branch of the PKGBUILD is REJECTED"

fixture skipbranch "source = $T/x.tar.gz" "sha256sums = $HASH_A"; rpc skipbranch 1
pkgbuild skipbranch "pkgname=sb
source=('$T/x.tar.gz')
if true; then sha256sums=('SKIP'); fi
if false; then
  sha256sums=('$HASH_A')
fi"
differs skipbranch 'SKIP x1 in the PKGBUILD, x0 in the .SRCINFO' "SKIP cannot hide in a branch behind a decoy hash"

# 69. a word count only the shell knows
fixture dyn "source = $T/a.tar.gz" "source = $T/b.tar.gz" "sha256sums = $HASH_A" "sha256sums = $HASH_B"; rpc dyn 1
pkgbuild dyn "pkgname=dyn
_files=(a b)
source=(\"\${_files[@]/#/$T/}.tar.gz\")
sha256sums=('$HASH_A' '$HASH_B')"
agrees dyn "\"\${a[@]}\" in a source array is no false alarm"

fixture brace "source = $T/a.tar.gz" "source = $T/b.tar.gz" "sha256sums = $HASH_A" "sha256sums = $HASH_B"; rpc brace 1
pkgbuild brace "pkgname=brace
source=($T/{a,b}.tar.gz)
sha256sums=('$HASH_A' '$HASH_B')"
agrees brace "brace expansion in a source array is no false alarm"

# A line continuation between elements is not an element
fixture contin "source = $T/a.tar.gz" "source = $T/b.tar.gz" "sha256sums = $HASH_A" "sha256sums = $HASH_B"; rpc contin 1
pkgbuild contin "pkgname=contin
source=(\"$T/a.tar.gz\" \\
        \"$T/b.tar.gz\")
sha256sums=('$HASH_A' \\
            '$HASH_B')"
agrees contin "a backslash-newline between elements is not an element"

# 70. makepkg leaves another architecture's arrays out of the .SRCINFO
fixture otherarch "arch = x86_64" "source = $T/o.tar.gz" "sha256sums = $HASH_A"; rpc otherarch 1
pkgbuild otherarch "pkgname=otherarch
arch=(x86_64)
source=('$T/o.tar.gz')
sha256sums=('$HASH_A')
source_i686=('$T/o-i686.tar.gz')
sha256sums_i686=('$HASH_B')"
agrees otherarch "an array for an architecture the .SRCINFO does not list is left alone"

# 71. the key a signature is checked against
fixture keydiff "source = $T/k.tar.gz" "source = $T/k.tar.gz.sig" \
                "validpgpkeys = ABCDEF0123456789ABCDEF0123456789ABCDEF01" \
                "sha256sums = SKIP" "sha256sums = SKIP"; rpc keydiff 1
pkgbuild keydiff "pkgname=keydiff
source=('$T/k.tar.gz' '$T/k.tar.gz.sig')
validpgpkeys=('0000000000000000000000000000000000000000')
sha256sums=('SKIP' 'SKIP')"
differs keydiff '0000000000000000000000000000000000000000' "a signing key the .SRCINFO does not show is REJECTED"

# 72. arch-specific arrays are compared with their own
fixture archsum "arch = x86_64" "source_x86_64 = $T/a.tar.gz" "sha256sums_x86_64 = $HASH_A"; rpc archsum 1
pkgbuild archsum "pkgname=archsum
source_x86_64=('$T/a.tar.gz')
sha256sums_x86_64=('$HASH_B')"
differs archsum 'sha256sums_x86_64' "an arch-specific checksum is compared against its own array"

# 73. a substring is not a protocol
fixture notvcs "source = $T/widgit+tool-1.0.tar.gz" "sha256sums = $HASH_A"; rpc notvcs 1
pkgbuild notvcs "pkgname=notvcs
source=('$T/widgit+tool-1.0.tar.gz')
sha256sums=('$HASH_A')"
agrees notvcs "a URL that merely contains 'git+' is not a VCS source"

# =============================================================================
echo "== 74-86. where the gate and the tools it answers to disagree =="
# =============================================================================
# 74. makepkg: from the first #, less anything from the last ?. Looking for
# #commit= anywhere in the string read this as pinned; makepkg reads the tag.
fixture fragtag "source = git+$T/f.git#tag=v1?x=#commit=$SHA_A" "sha256sums = SKIP"; rpc fragtag 1
rc=$(check fragtag)
if [[ $rc == 1 ]] && grep -q 'REJECT fragtag.*unpinned' "$WORK/out"; then
    pass "#tag=v1?x=#commit=<sha> is REJECTED: makepkg builds the tag, not the commit"
else
    fail "a pin hidden behind a query was accepted (rc=$rc): $(cat "$WORK/out")"
fi
fixture fragbr "source = git+$T/f.git#branch=main?#commit=$SHA_A" "sha256sums = SKIP"; rpc fragbr 1
[[ $(check fragbr) == 1 ]] \
    && pass "#branch=main?#commit=<sha> is REJECTED" \
    || fail "a branch behind a query was accepted: $(cat "$WORK/out")"
fixture fragok "source = git+$T/f.git#commit=$SHA_A?signed" "sha256sums = SKIP"; rpc fragok 1
[[ $(check fragok) == 0 ]] \
    && pass "#commit=<sha>?signed is still a pin" \
    || fail "a signed pin was refused: $(cat "$WORK/out")"

# 75. cgit keeps dead branches; the index knows what the name means today
srcinfo liveplit "git+$T/live.git"
printf 'pkgname = shadowed\n' >> "$WORK/srcinfo/liveplit.SRCINFO"
rpc liveplit 1
rpc shadowed 1 liveplit
srcinfo shadowed "git+$T/old.git#commit=$SHA_A"      # the dead branch, pinned
rc=$(check shadowed)
if [[ $rc == 1 ]] && grep -q 'live.git' "$WORK/out"; then
    pass "a stale cgit branch cannot stand in for the live split package of that name"
else
    fail "the dead branch was judged instead of the live pkgbase (rc=$rc): $(cat "$WORK/out")"
fi

# 76. what `aurinstall firefox` must not do
srcinfo reponame "$T/ancient.tar.gz"
rpc reponame 0
mk_aur_repo reponame
echo reponame > "$WORK_REPO_PKGS"
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall reponame </dev/null 2>&1); rc=$?
if [[ ! -s "$WORK_CB_LOG" ]] && grep -q -- '-S reponame' "$WORK_YAY_LOG"; then
    pass "a repo package with a dead AUR branch goes to yay, not through the chroot"
else
    fail "a dead AUR branch was built (rc=$rc, chrootbuild: $(cat "$WORK_CB_LOG")): $out"
fi
: > "$WORK_REPO_PKGS"

# 77. a proxy, a captive portal or an anti-bot page answers 200 with HTML
printf '<html><body>Making sure you are not a bot</body></html>\n' > "$WORK/srcinfo/htmlpage.SRCINFO"
srcinfo_html_pkgbuild='pkgname=htmlpage'
pkgbuild htmlpage "$srcinfo_html_pkgbuild"
rpc htmlpage 1
rc=$(check htmlpage)
if [[ $rc == 1 ]] && grep -q 'ERROR htmlpage.*not the .SRCINFO' "$WORK/out"; then
    pass "a 200 that is not a .SRCINFO is an ERROR, not a package with no sources"
else
    fail "a junk .SRCINFO passed (rc=$rc): $(cat "$WORK/out")"
fi
fixture htmlpb "source = $T/h.tar.gz" "sha256sums = $HASH_A"; rpc htmlpb 1
pkgbuild htmlpb '<html><body>Making sure you are not a bot</body></html>'
rc=$(check htmlpb)
if [[ $rc == 1 ]] && grep -q 'ERROR htmlpb.*not a PKGBUILD' "$WORK/out"; then
    pass "a 200 that is not a PKGBUILD is an ERROR"
else
    fail "a junk PKGBUILD passed (rc=$rc): $(cat "$WORK/out")"
fi

# 78. a rate limit is not a deletion
fixture limited "source = $T/l.tar.gz" "sha256sums = $HASH_A"
printf '{"error":"Rate limit reached","resultcount":0,"results":[],"type":"error","version":5}' > "$WORK/rpc/limited.json"
rc=$(check limited)
if [[ $rc == 1 ]] && grep -q 'could not ask' "$WORK/out" && ! grep -q 'NOT in the AUR' "$WORK/out"; then
    pass "an RPC error reply is reported as could-not-ask, not as a deleted package"
else
    fail "an RPC error was misread (rc=$rc): $(cat "$WORK/out")"
fi

# 79. makepkg only fetches the arrays of the architecture it builds for
fixture crosssig "arch = x86_64" "arch = aarch64" \
                 "source_x86_64 = $T/blob.tar.gz" "sha256sums_x86_64 = SKIP" \
                 "source_aarch64 = $T/blob.tar.gz.sig" "sha256sums_aarch64 = SKIP"; rpc crosssig 1
rc=$(check crosssig)
if [[ $rc == 1 ]] && grep -q 'blob.tar.gz$' "$WORK/out"; then
    pass "a signature in another architecture's array does not cover a file"
else
    fail "a cross-architecture signature was accepted (rc=$rc): $(cat "$WORK/out")"
fi
fixture plainsig "arch = x86_64" "source_x86_64 = $T/b.tar.gz" "sha256sums_x86_64 = SKIP" \
                 "source = $T/b.tar.gz.sig" "sha256sums = SKIP"; rpc plainsig 1
[[ $(check plainsig) == 0 ]] \
    && pass "a signature in the plain array covers what every architecture fetches" \
    || fail "a plain-array signature was refused: $(cat "$WORK/out")"

# 80. the other architecture's dependency
srcinfo archdep "$T/a.tar.gz"
printf '\tdepends_not_this_arch = no-such-dep\n' >> "$WORK/srcinfo/archdep.SRCINFO"
printf '\tdepends_%s = dep-for-here\n' "$(uname -m)" >> "$WORK/srcinfo/archdep.SRCINFO"
rpc archdep 1
srcinfo dep-for-here "git+$T/d.git"; rpc dep-for-here 1
rc=$(check --deps archdep)
if [[ $rc == 1 ]] && grep -q 'REJECT dep-for-here' "$WORK/out" && ! grep -q 'no-such-dep' "$WORK/out"; then
    pass "a dependency of this architecture is walked, and another architecture's is not"
else
    fail "architecture-specific dependencies misjudged (rc=$rc): $(cat "$WORK/out")"
fi

# 81. what a hostile .SRCINFO can write to the terminal
fixture escpkg "source = git+$T/$(printf '\033[2K\033[1A')x.git" "sha256sums = SKIP"; rpc escpkg 1
rc=$(check escpkg)
if [[ $rc == 1 ]] && grep -q 'REJECT escpkg' "$WORK/out" && ! grep -q $'\033' "$WORK/out"; then
    pass "escape sequences in a source never reach the terminal"
else
    fail "control characters reached the report (rc=$rc): $(cat -v "$WORK/out")"
fi

# 82. a dependency string off the network that cannot be a name
: > "$WORK_CURL_LOG"
rc=$(check 'aur/foo')
if [[ $rc == 1 ]] && grep -q 'not a package name' "$WORK/out" && [[ ! -s "$WORK_CURL_LOG" ]]; then
    pass "something that cannot be a package name is an ERROR, before any request"
else
    fail "an impossible name was looked up (rc=$rc): $(cat "$WORK/out")"
fi

# 83-85. the options say what happens, on every path
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
srcinfo modebin-bin "$T/b.tar.gz"; rpc modebin-bin 1; mk_aur_repo modebin-bin
: > "$WORK_YAY_LOG"
out=$(AURINSTALL_MAX_CHAIN=1 AURINSTALL_MODE=chroot aurinstall needsaur2 </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cannot be used here' <<<"$out" && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "AURINSTALL_MODE=chroot refuses rather than falls back, like --chroot"
else
    fail "AURINSTALL_MODE=chroot fell back to yay (rc=$rc, yay: $(cat "$WORK_YAY_LOG")): $out"
fi

: > "$WORK_YAY_LOG"
out=$(aurinstall --no-install modebin-bin </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cannot be kept on the yay path' <<<"$out" && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "--no-install is refused on the yay path, where yay would install anyway"
else
    fail "--no-install was broken by a fallback (rc=$rc, yay: $(cat "$WORK_YAY_LOG")): $out"
fi

srcinfo instpkg "$T/i.tar.gz"; rpc instpkg 1; mk_aur_repo instpkg
: > "$WORK_PACMAN_LOG"
aurinstall --install instpkg </dev/null >/dev/null 2>&1
if grep -q -- '^-U --noconfirm .*instpkg' "$WORK_PACMAN_LOG"; then
    pass "--install reaches pacman with --noconfirm: it promises no prompt"
else
    fail "--install left pacman's own prompt standing: $(cat "$WORK_PACMAN_LOG")"
fi

# 86. a rebuild keeps the file name, so a list of names sees nothing new
mkdir -p "$WORK/dest"
printf 'PKGDEST=%s\n' "$WORK/dest" > "$WORK/makepkg.conf"
srcinfo rebuilt "$T/r.tar.gz"; rpc rebuilt 1; mk_aur_repo rebuilt
out=$(MAKEPKG_CONF="$WORK/makepkg.conf" WORK_CB_DEST="$WORK/dest" aurinstall --no-install rebuilt </dev/null 2>&1); rc1=$?
out=$(MAKEPKG_CONF="$WORK/makepkg.conf" WORK_CB_DEST="$WORK/dest" aurinstall --no-install rebuilt </dev/null 2>&1); rc2=$?
if (( rc1 == 0 && rc2 == 0 )) && grep -q 'rebuilt-1.0-1' <<<"$out"; then
    pass "rebuilding the same version with PKGDEST set finds the package it just built"
else
    fail "a same-version rebuild was reported as producing nothing (rc=$rc1/$rc2): $out"
fi

# =============================================================================
echo "== 87-102. the review's findings, each one a case =="
# =============================================================================
# 87. makepkg reads the kind up to the first `=` and the value after the last,
# from the first `#` of the whole entry. Each of these builds something that moves.
n=0
for spec in "git+$T/f.git#commit=$SHA_A?=main?x" \
            "git+$T/f.git#commit=$SHA_A =main" \
            "git+$T/f.git#?#commit=$SHA_A" \
            "x#branch=main?::git+$T/f.git#commit=$SHA_A" \
            "svn+$T/f#revision=1?=HEAD" \
            "hg+$T/f#revision=$SHA_A?=tip" \
            "fossil+$T/f#commit=$SHA_A?=trunk?x" \
            "git+$T/f.git#commit=$HASH_A"; do
    n=$((n + 1))
    fixture "pin$n" "source = $spec" "sha256sums = SKIP"; rpc "pin$n" 1
    rc=$(check "pin$n")
    if [[ $rc == 1 ]] && grep -q "REJECT pin$n.*unpinned" "$WORK/out"; then
        pass "not a pin: $spec"
    else
        fail "accepted as a pin (rc=$rc): $spec: $(cat "$WORK/out")"
    fi
done
fixture fossil64 "source = fossil+$T/f#commit=$HASH_A" "sha256sums = SKIP"; rpc fossil64 1
[[ $(check fossil64) == 0 ]] \
    && pass "a 64-hex fossil hash is a pin: fossil's hashes are that long" \
    || fail "a fossil pin was refused: $(cat "$WORK/out")"

# 88. git ls-remote matches the TAIL of a ref. A tag called 0/refs/tags/v2.0 at
# the vetted commit answers for refs/tags/v2.0 too, and it sorts first.
DECOY="$WORK/git/decoy.git"
git init -q "$DECOY"
git -C "$DECOY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$DECOY" tag v2.0
VETTED=$(git -C "$DECOY" rev-parse HEAD)
git -C "$DECOY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m evil
git -C "$DECOY" tag -f v2.0 >/dev/null
git -C "$DECOY" tag 0/refs/tags/v2.0 "$VETTED"
fixture decoy "source = git+file://$DECOY#tag=v2.0" "sha256sums = SKIP"; rpc decoy 1
printf 'decoy  git+file://%s#tag=v2.0  %s\n' "$DECOY" "$VETTED" > "$WORK/allowlist.conf"
rc=$(check decoy)
if [[ $rc == 1 ]] && grep -q 'tag moved upstream' "$WORK/out"; then
    pass "a moved tag is refused even with a decoy ref at the vetted commit"
else
    fail "a decoy ref laundered a moved tag (rc=$rc): $(cat "$WORK/out")"
fi
# the row covers one plain tag, not what makepkg would read around it
fixture oddtag "source = x#branch=main?::git+file://$DECOY#tag=v2.0" "sha256sums = SKIP"; rpc oddtag 1
printf 'oddtag  git+file://%s#tag=v2.0  %s\n' "$DECOY" "$(git -C "$DECOY" rev-parse v2.0)" > "$WORK/allowlist.conf"
[[ $(check oddtag) == 1 ]] \
    && pass "a row does not cover an entry whose filename prefix changes what makepkg reads" \
    || fail "a filename prefix laundered an allowlist row: $(cat "$WORK/out")"
: > "$WORK/allowlist.conf"

# 89. rows are keyed on the pkgbase, and matched exactly
fixture rowbase "source = git+file://$DECOY#tag=v2.0" "sha256sums = SKIP"
printf 'pkgname = rowsplit\n' >> "$WORK/srcinfo/rowbase.SRCINFO"
rpc rowbase 1; rpc rowsplit 1 rowbase
printf 'rowbase  git+file://%s#tag=v2.0  %s\n' "$DECOY" "$(git -C "$DECOY" rev-parse v2.0)" > "$WORK/allowlist.conf"
[[ $(check rowsplit) == 0 ]] \
    && pass "an allowlist row keyed on the pkgbase covers a split package" \
    || fail "a pkgbase row did not cover its split package: $(cat "$WORK/out")"
fixture rowesc "source = git+file://$DECOY#tag=v2\.0" "sha256sums = SKIP"; rpc rowesc 1
printf 'rowesc  git+file://%s#tag=v2.0  %s\n' "$DECOY" "$(git -C "$DECOY" rev-parse v2.0)" > "$WORK/allowlist.conf"
[[ $(check rowesc) == 1 ]] \
    && pass "a row is matched byte for byte: a backslash in the source does not fit it" \
    || fail "awk's -v unescaping matched a row to a different spec"
: > "$WORK/allowlist.conf"

# 90. makepkg's get_protocol
fixture lpdl "source = https+lp:x@host.invalid/payload.tar.gz" "sha256sums = SKIP"; rpc lpdl 1
[[ $(check lpdl) == 1 ]] \
    && pass "an https+lp: entry is a download, by makepkg's rule, and SKIP on it is REJECTED" \
    || fail "a download with no :// passed as a local file"
fixture lookalike "source = git+https-fix.patch" "sha256sums = SKIP"; rpc lookalike 1
[[ $(check lookalike) == 0 ]] \
    && pass "a local file named git+https-fix.patch is not a VCS source" \
    || fail "a local file was judged as VCS: $(cat "$WORK/out")"

# 91. what a signature does not cover
fixture vcssig "source = $T/foo.tar.gz" "source = foo.tar.gz.sig::git+$T/s.git#commit=$SHA_A" \
               "sha256sums = SKIP" "sha256sums = SKIP"; rpc vcssig 1
rc=$(check vcssig)
if [[ $rc == 1 ]] && grep -q 'foo.tar.gz$' "$WORK/out"; then
    pass "a VCS entry named like a signature covers no file"
else
    fail "a VCS source was taken for a signature (rc=$rc): $(cat "$WORK/out")"
fi
fixture twoformats "source = $T/foo.tar.gz" "source = $T/foo.tar.xz" "source = $T/foo.tar.sign" \
                   "sha256sums = SKIP" "sha256sums = SKIP" "sha256sums = SKIP"; rpc twoformats 1
rc=$(check twoformats)
if [[ $rc == 1 ]] && grep -q 'foo.tar.xz' "$WORK/out" && ! grep -q 'foo.tar.gz' "$WORK/out"; then
    pass "one signature covers the first file makepkg finds, and only that"
else
    fail "a signature was credited to two files (rc=$rc): $(cat "$WORK/out")"
fi

# 92.
fixture skipspace "source = $T/x.tar.gz" "sha256sums = SKIP "; rpc skipspace 1
pkgbuild skipspace "pkgname=skipspace
source=('$T/x.tar.gz')
sha256sums=('SKIP')"
[[ $(check skipspace) == 1 ]] \
    && pass "SKIP with a trailing space is still SKIP" \
    || fail "a trailing space turned SKIP into a checksum"

# 93. subscripts. `sha512sums[4]='SKIP'` is what real PKGBUILDs do.
fixture subskip "source = $T/x.tar.gz" "sha256sums = $HASH_A"; rpc subskip 1
pkgbuild subskip "pkgname=subskip
source=('$T/x.tar.gz')
sha256sums=('$HASH_A')
sha256sums[0]=SKIP"
differs subskip 'sha256sums[1]' "x[0]=SKIP over a hash the .SRCINFO shows is REJECTED"
fixture subok "source = $T/x.tar.gz" "source = g::git+$T/g.git#commit=$SHA_A" \
              "sha256sums = $HASH_A" "sha256sums = SKIP"; rpc subok 1
pkgbuild subok "pkgname=subok
source=('$T/x.tar.gz' \"g::git+$T/g.git#commit=$SHA_A\")
sha256sums=('$HASH_A' '$HASH_B')
sha256sums[1]='SKIP'"
agrees subok "a subscript assignment the .SRCINFO agrees with passes"
fixture subcond "source = $T/x.tar.gz" "sha256sums = $HASH_A"; rpc subcond 1
pkgbuild subcond "pkgname=subcond
source=('$T/x.tar.gz')
sha256sums=('$HASH_A')
if [[ -n \$_dev ]]; then
    sha256sums[0]='SKIP'
fi"
agrees subcond "a conditional subscript assignment is no false alarm"

# 94. text in a heredoc, and an array that never ends
fixture hdoc "source = $T/x.tar.gz" "sha256sums = $HASH_A"; rpc hdoc 1
pkgbuild hdoc "pkgname=hdoc
source=('$T/x.tar.gz')
sha256sums=('$HASH_A')
_note() {
cat <<EOF
source=('$T/not-a-source.tar.gz')
EOF
}"
agrees hdoc "an array inside a heredoc is text"
fixture hdoc2 "source = $T/good.tar.gz" "sha256sums = $HASH_A"; rpc hdoc2 1
pkgbuild hdoc2 "pkgname=hdoc2
source=('$T/evil.tar.gz')
sha256sums=('$HASH_A')
: <<EOF
source=('$T/good.tar.gz')
EOF"
differs hdoc2 'evil.tar.gz' "a decoy array in a heredoc does not replace the real one"
fixture unclosed "source = $T/x.tar.gz" "sha256sums = $HASH_A"; rpc unclosed 1
pkgbuild unclosed "pkgname=unclosed
sha256sums=('$HASH_A')
source=('$T/x.tar.gz'"
differs unclosed 'never closed' "an array that is never closed is REJECTED, not dropped"

# 95. `arduino` is a repo group and a real AUR package
srcinfo grouptop "$T/g.tar.gz"
printf '\tdepends = agroup\n' >> "$WORK/srcinfo/grouptop.SRCINFO"
rpc grouptop 1
srcinfo agroup "git+$T/ag.git"; rpc agroup 1
echo agroup > "$WORK_GROUPS"
rc=$(check --deps grouptop)
if [[ $rc == 1 ]] && grep -q 'REJECT agroup' "$WORK/out"; then
    pass "a repo group does not satisfy a dependency: the AUR package of that name is walked"
else
    fail "a group passed for a dependency (rc=$rc): $(cat "$WORK/out")"
fi
: > "$WORK_GROUPS"

# 96. a half-finished upgrade can leave any of these broken
mkdir -p "$WORK/broken"; printf '#!/bin/bash\nexit 127\n' > "$WORK/broken/awk"; chmod +x "$WORK/broken/awk"
out=$(PATH="$WORK/broken:$PATH" aur-pin-check bare 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'nothing can be checked' <<<"$out"; then
    pass "a broken awk is an ERROR, not a package with no sources"
else
    fail "a broken awk passed (rc=$rc): $out"
fi

# 97.
rc=$(check pinned --noconfirm)
if [[ $rc == 1 ]] && grep -q 'not a package name' "$WORK/out"; then
    pass "a later argument that looks like an option is refused, not handed to pacman"
else
    fail "an option-shaped name went through (rc=$rc): $(cat "$WORK/out")"
fi

# 98.
printf 'pkgbase = eqval\n\tpkgver = 1\n\tpkgrel = 1\n\tsource = foo = bar::git+%s/a.git\n\tsha256sums = SKIP\n\npkgname = eqval\n' "$T" \
    > "$WORK/srcinfo/eqval.SRCINFO"
pkgbuild eqval 'pkgname=eqval
_u=x
source=("$_u")
sha256sums=(SKIP)'
rpc eqval 1
rc=$(check eqval)
if [[ $rc == 1 ]] && grep -q 'REJECT eqval.*unpinned' "$WORK/out"; then
    pass "a .SRCINFO value runs to the end of its line"
else
    fail "a value cut at ' = ' hid a source (rc=$rc): $(cat "$WORK/out")"
fi

# 99. aurupdate: real yay exits 1 with an empty stdout both ways
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$WORK_YAY_LOG"\n[[ "$1" == -Qua ]] && { echo "error: could not reach the AUR" >&2; exit 1; }\nexit 0\n' > "$WORK/broken/yay"
chmod +x "$WORK/broken/yay"; rm -f "$WORK/broken/awk"
: > "$WORK_YAY_LOG"
out=$(PATH="$WORK/broken:$PATH" aurupdate 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'could not ask' <<<"$out" && ! grep -q 'no AUR upgrades pending' <<<"$out"; then
    pass "aurupdate reports an AUR it could not reach as an error, not as nothing pending"
else
    fail "aurupdate called a failed query a clean result (rc=$rc): $out"
fi
rm -f "$WORK/broken/yay"
printf 'pinned 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate --devel >/dev/null 2>&1
if grep -qxF -- '-Qua --devel' "$WORK_YAY_LOG" && grep -qxF -- '-Sua --devel' "$WORK_YAY_LOG"; then
    pass "an option reaches -Qua as well as -Sua: the gate sees what will run"
else
    fail "aurupdate gated one set and built another: $(cat "$WORK_YAY_LOG")"
fi
: > "$WORK_YAY_LOG"
out=$(aurupdate some-package 2>&1); rc=$?
if (( rc == 2 )) && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "aurupdate refuses a package name it would otherwise pass straight to yay"
else
    fail "a package name went past the gate (rc=$rc): $(cat "$WORK_YAY_LOG")"
fi
: > "$WORK_YAY_QUA"

# 100.
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
aurinstall --chroot --no-install modebin-bin </dev/null >/dev/null 2>&1
if grep -q -- '-p modebin-bin' "$WORK_CB_LOG" && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "--chroot forces a -bin package through the chroot, as the docs say"
else
    fail "--chroot refused a -bin package (yay: $(cat "$WORK_YAY_LOG"))"
fi

# 101. one pkgbase, one build
srcinfo sibbase "$T/s.tar.gz"
printf '\nsep = x\npkgname = sibtool\n\tdepends = siblib\n\npkgname = siblib\n' >> "$WORK/srcinfo/sibbase.SRCINFO"
rpc sibbase 1; rpc sibtool 1 sibbase; rpc siblib 1 sibbase
mk_aur_repo sibbase
: > "$WORK_CB_LOG"
out=$(aurinstall --chroot --no-install sibtool </dev/null 2>&1); rc=$?
if (( rc == 0 )) && grep -q -- '-p sibbase' "$WORK_CB_LOG" && ! grep -q 'cycle' <<<"$out"; then
    pass "a dependency on a sibling of the same pkgbase is no cycle"
else
    fail "a split sibling read as a cycle (rc=$rc): $out"
fi

# 102. what reaches the host
srcinfo apptop "$T/a.tar.gz"
printf '\tdepends = rundep\n\tmakedepends = builddep\n' >> "$WORK/srcinfo/apptop.SRCINFO"
srcinfo rundep "$T/r.tar.gz"; srcinfo builddep "$T/b.tar.gz"
rpc apptop 1; rpc rundep 1; rpc builddep 1
mk_aur_repo apptop; mk_aur_repo rundep; mk_aur_repo builddep
: > "$WORK_PACMAN_LOG"
out=$(aurinstall --install apptop </dev/null 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'apptop-1.0' "$WORK_PACMAN_LOG" && grep -q 'rundep-1.0' "$WORK_PACMAN_LOG" \
   && ! grep -q 'builddep-1.0' "$WORK_PACMAN_LOG" && grep -q 'kept, not installed' <<<"$out"; then
    pass "the target and its runtime dependency are installed; an AUR makedepend stays out"
else
    fail "the wrong set reached pacman (rc=$rc): $(cat "$WORK_PACMAN_LOG"): $out"
fi

# =============================================================================
echo "== 103. the shell aliases =="
# =============================================================================
# A home of its own, and stand-ins for shells this machine may not have: what is
# under test is which file gets what, not the shells.
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME/.config/nushell"
: > "$FAKEHOME/.config/nushell/config.nu"
printf "# mine\nexport X=1\nalias pupdate='safeup ; flatpak update -y'\n" > "$FAKEHOME/.zshrc"
printf '# mine\n' > "$FAKEHOME/.bashrc"
for sh in zsh fish tcsh ksh; do printf '#!/bin/bash\n' > "$WORK/shim/$sh"; chmod +x "$WORK/shim/$sh"; done
run_aliases() { HOME="$FAKEHOME" XDG_CONFIG_HOME="$FAKEHOME/.config" ZDOTDIR="" bash "$HERE/../deploy.sh" --aliases-only --aliases </dev/null 2>&1; }
out=$(run_aliases); rc=$?
fishrc="$FAKEHOME/.config/fish/conf.d/satyrus-manjaro.fish"
if (( rc == 0 )) \
   && grep -qxF "alias yupdate='safeup --aur'" "$FAKEHOME/.bashrc" \
   && grep -qxF "alias yupdate 'safeup --aur'" "$fishrc" \
   && grep -qxF "alias yinstall 'aurinstall'" "$FAKEHOME/.tcshrc" \
   && grep -qxF "alias pupdate='safeup'" "$FAKEHOME/.kshrc" \
   && grep -qxF "alias yupdate = safeup --aur" "$FAKEHOME/.config/nushell/config.nu"; then
    pass "aliases reach bash, fish, tcsh, ksh and nushell, each in its own syntax and file"
else
    fail "aliases not installed per shell (rc=$rc): $out"
fi
bash -n "$FAKEHOME/.bashrc" && ( shopt -s expand_aliases; source "$FAKEHOME/.bashrc"; alias yinstall ) >/dev/null 2>&1 \
    && pass "the bash block is valid, and defines the aliases when sourced" \
    || fail "the bash block does not source: $(cat "$FAKEHOME/.bashrc")"
if grep -qxF "alias pupdate='safeup ; flatpak update -y'" "$FAKEHOME/.zshrc" \
   && [[ $(grep -c 'alias pupdate' "$FAKEHOME/.zshrc") == 1 ]] \
   && grep -qxF "alias yinstall='aurinstall'" "$FAKEHOME/.zshrc" \
   && grep -q 'yours.*pupdate already defined for zsh' <<<"$out"; then
    pass "a name you already define stays yours, and is reported; the others are added"
else
    fail "an existing alias was not respected: $(cat "$FAKEHOME/.zshrc")"
fi
ls "$FAKEHOME"/.zshrc.bak-* >/dev/null 2>&1 && grep -q '# mine' "$FAKEHOME"/.zshrc.bak-* \
    && pass "a changed rc file keeps a timestamped backup" \
    || fail "no backup of the rc file"
before=$(cat "$FAKEHOME/.bashrc")
out=$(run_aliases)
if [[ "$(cat "$FAKEHOME/.bashrc")" == "$before" ]] && grep -q "unchanged  $FAKEHOME/.bashrc" <<<"$out" \
   && [[ $(grep -c 'Satyrus-manjaro aliases >>>' "$FAKEHOME/.bashrc") == 1 ]]; then
    pass "running it again changes nothing, and adds no second block"
else
    fail "the alias block is not idempotent: $(cat "$FAKEHOME/.bashrc")"
fi
sed -i "s/safeup --aur/an-old-definition/" "$FAKEHOME/.bashrc"
run_aliases >/dev/null
if grep -qxF "alias yupdate='safeup --aur'" "$FAKEHOME/.bashrc" && ! grep -q 'an-old-definition' "$FAKEHOME/.bashrc"; then
    pass "a stale block of its own is replaced, not left beside a new one"
else
    fail "an old block survived: $(cat "$FAKEHOME/.bashrc")"
fi
rm -f "$WORK/shim/zsh" "$WORK/shim/fish" "$WORK/shim/tcsh" "$WORK/shim/ksh"

# 104. On a real terminal, or it proves nothing: script(1) gives it one.
if command -v script >/dev/null; then
    out=$(printf 'n\n' | HOME="$FAKEHOME" SHELL=/bin/bash script -qec "bash '$HERE/../deploy.sh' --aliases-only" /dev/null 2>&1)
    if grep -q 'add the aliases pupdate yinstall yupdate for' <<<"$out" && grep -q 'aliases not added' <<<"$out"; then
        pass "deploy.sh's question reaches the terminal, and no means no"
    else
        fail "deploy.sh asked in silence: $out"
    fi
else
    echo "  SKIP: 104 needs script(1)"
fi

# 105. the function itself, with sudo stubbed; nothing is written.
eval "$(sed -n '/^backup_of() {/,/^}/p' "$HERE/../deploy.sh")"
path=$(backup_of /etc/logrotate.d/safeup 2>/dev/null)
if [[ "$path" == /var/backups/satyrus-manjaro/safeup.bak-* ]]; then
    pass "a backup of a logrotate rule stays out of /etc/logrotate.d"
else
    fail "a backup would be parsed by logrotate: $path"
fi
printf 'x\n' > "$WORK/same-second"
printf '#!/bin/bash\necho 20261105-120000\n' > "$WORK/shim/date"; chmod +x "$WORK/shim/date"
: > "$WORK/same-second.bak-20261105-120000"
path=$(backup_of "$WORK/same-second")
[[ "$path" == "$WORK/same-second.bak-20261105-120000.1" ]] \
    && pass "a second backup in the same second does not overwrite the first" \
    || fail "same-second backup collided: $path"
rm -f "$WORK/shim/date"

# 106.
out=$(HOME="$FAKEHOME" bash "$HERE/../audit-drift.sh" 2>&1)
grep -q 'systemd/user/safeup-drift-audit.timer' <<<"$out" \
    && pass "the drift audit looks at the timer" \
    || fail "the timer is outside the drift audit: $out"

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]

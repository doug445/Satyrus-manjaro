# Why Manjaro's release model creates these problems

This is the argument behind [Satyrus-manjaro](../README.md): why the AUR and
Manjaro's Stable branch do not fit together, in Manjaro's own words and from
its own record. The README covers what the suite does and how to use it; none
of what follows is needed to install it.

## The problem, in other people's words

This suite exists because of a specific, well-documented property of Manjaro:
its Stable branch trails Arch, while the AUR does not. That gap is the whole
story, and it is worth reading the complaint before the fix.

> "some AUR packages require certain dependencies to run, which they expect to
> install from the official Arch repo. However, on Manjaro, the necessary
> dependency might be running on an older version, which has some compatibility
> issues with the AUR package. […] This can create a fundamental compatibility
> mismatch that can lead to broken installations, missing dependencies, or
> packages that simply refuse to build."
>
> — Dibakar Ghosh, [*3 Reasons I Avoid Manjaro Even Though I Love Arch
> Linux*](https://www.howtogeek.com/why-i-avoid-manjaro-even-though-i-love-arch-linux/),
> How-To Geek, 1 September 2025

Manjaro's own moderators do not dispute the risk. They document it and decline
to fix it:

> "Remember, the AUR is neither officially supported by Arch nor by Manjaro.
> Using it is at your own risk and your own responsibility."
>
> — linux-aarhus, [*Responsible use of
> AUR*](https://forum.manjaro.org/t/responsible-use-of-aur/86392), Manjaro Linux
> Forum, 14 October 2021

> "any CUSTOM package may cease to function without warning OR your system may
> cease to function due to a CUSTOM package"
>
> — linux-aarhus, [*[Need-To-Know] About Manjaro and
> AUR*](https://forum.manjaro.org/t/need-to-know-about-manjaro-and-aur/103617),
> Manjaro Linux Forum, 23 February 2022

That second sentence is an accurate description of the failure mode, and it is
also an accurate description of what this suite exists to detect. Being told
the risk is yours is only useful if you have some way of seeing it.

So: the AUR assumes you are current with Arch. Manjaro's Stable branch
deliberately is not. Nobody supports the gap. **This suite is the gap,
handled.**

### Manjaro puts the AUR in its own package manager, then disowns it

Pamac — the "Add/Remove Software" app on every Manjaro desktop — has AUR
support built in, behind a switch in its preferences. Then Manjaro's own
moderator, linux-aarhus, tells the people who flip that switch that the AUR
"is neither officially supported by Arch nor by Manjaro. Using it is at your
own risk and your own responsibility", and that "any CUSTOM package may cease
to function without warning OR your system may cease to function due to a
CUSTOM package" (both quoted above). Manjaro builds the door, holds its Stable
branch back from the Arch packages the AUR is written against, and tells you
that whatever comes through the door is your problem.

### Manjaro's record

From its own forum, mailing lists and issue tracker:

- **Pamac has been blocked from the AUR — at least twice.** The AUR's
  administrators, in Manjaro's own tracker: "Pamac user agent was responsible
  for making a very large number of requests to the AUR … We have completely
  blocked the Pamac user agent, to restore service for the users"
  ([Pamac #1017](https://gitlab.manjaro.org/applications/pamac/-/issues/1017)).
  It happened again
  ([Pamac #1135](https://gitlab.manjaro.org/applications/pamac/-/issues/1135);
  ["Manjaro banned from AUR!?"](https://forum.manjaro.org/t/manjaro-banned-from-aur/89986)).
  The AUR serves every Arch-based distribution; Manjaro's tool took it down
  for all of them — EndeavourOS users included, who were left asking
  ["Is AUR down again?"](https://web.archive.org/web/20220221092555/https://forum.endeavouros.com/t/is-aur-down-again/24287/9).
  Manjaro's response was a forum thread titled
  ["AUR — please restrain yourself"](https://web.archive.org/web/20220221090752/https://forum.manjaro.org/t/aur-please-restrain-yourself/103318),
  addressed to its users. Its wiki still warns them not to enable Pamac's AUR
  update checks, because they flood the AUR and get Pamac denylisted. The
  switch is still there.
- **Its certificates keep expiring.** In 2015 Manjaro's own notice read "Seems
  we forgot to update our SSL certificate in time" and told users to set their
  clocks back
  ([archived](https://web.archive.org/web/20150409040851/https://manjaro.github.io/expired_SSL_certificate/)).
  In 2016: "the SSL certificate has once again expired"
  ([manjaro-dev](https://lists.manjaro.org/pipermail/manjaro-dev/Week-of-Mon-20160509/001164.html)).
  In 2022 the certificate for its mirrors, downloads and AUR hosts lapsed
  ([forum](https://forum.manjaro.org/t/mirrors-download-aur-manjaro-org-ssl-certificate-expired/115074)),
  then software.manjaro.org's — "again"
  ([forum](https://forum.manjaro.org/t/software-manjaro-org-expired-certificate-again/119696)),
  then the archived forum's
  ([forum](https://forum.manjaro.org/t/am-i-the-only-one-getting-expired-certificate-warning-on-archived-forum-manjaro-org/126049)).
  A distribution that cannot keep a certificate renewed is asking you to trust
  it with your packages.
- **It rushed Apple Silicon.** Manjaro shipped Asahi Linux packages pulled
  from the latest PKGBUILD without coordinating with the Asahi developers, and
  Asahi's then project lead objected publicly
  ([archived](https://web.archive.org/web/20221208084616/https://twitter.com/marcan42/status/1576414477272387584)).
- **Arch will not help you.** The Arch forums are "for Arch Linux x86_64 ONLY.
  Not Artix, or Apricity, or Manjaro … Ask those communities for support"
  ([Arch forums](https://bbs.archlinux.org/register.php)). Manjaro's answer
  for the AUR, as above, is that it is your own responsibility.

[manjarno](https://manjarno.pages.dev/) catalogues more of the same, with
sources.

### Who answers for it

Philip Müller co-founded Manjaro, leads it, and posts its branch update
announcements. Every item above happened on his watch, most of them more than
once, and none of them changed the project's answer to the AUR: switch it on
in Pamac, and the consequences are yours. That answer is delivered by
linux-aarhus, whose forum posts are the most precise account anywhere of how a
Manjaro system breaks under the AUR — precise enough that this suite builds on
two of them (credited under [Building in a chroot](../README.md#building-in-a-chroot)).
Precision is not a fix. Five years of "your own risk and your own
responsibility" is five years of Manjaro's lead and its senior moderator
describing a hole in their own distribution and leaving users to fill it. A
project that cannot keep a certificate renewed, gets its own package manager
locked out of the AUR it advertises, and answers both with a disclaimer has not
earned the word "Stable" on its branch. If that is not good enough for you,
the answer is at the top of the [README](../README.md). 



### About those two weeks

Manjaro's headline feature is a calendar. Its Stable branch is Arch with a
two-week delay, sold as "testing" — testing that the AUR, the reason half its
users came, never takes part in. So the AUR keeps building for an Arch that
Manjaro users will not have for another fortnight, things break in the gap, and
the official response is a forum post explaining that the breakage is yours.
That is not curation; it is jet lag with a disclaimer. Two weeks late also
means two weeks late for security and bug fixes, every time. Arch and
EndeavourOS users get today's packages. Manjaro users get last fortnight's,
plus a moderator telling them it is their own fault. This suite exists so you do not have to choose between the
AUR and a system that boots.

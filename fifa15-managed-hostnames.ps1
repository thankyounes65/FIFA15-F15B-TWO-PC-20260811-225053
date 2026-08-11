# Single source of truth for the EA/GOS hostnames FIFA 15 must resolve to
# this project's relay instead of EA's real (decommissioned) servers.
#
# Dot-source this file rather than copying the array - that copy-paste is
# exactly how the 2026-08-11 regression happened: the four spring14.*
# redirector-pool names were known and present in scripts\switch-hosts-
# target.ps1 since this repo's earliest commit, but sanitize-fifa12-shared-
# state.ps1 (and six other scripts) each kept an independent copy that never
# had them. Whichever script last rebuilt the FIFA15-RELAY hosts block used
# its own incomplete copy and silently dropped the other four, and fifa15.exe
# escaped straight to a real EA IP the next time it asked for one of them.
#
# peach.online.ea.com (the DirtySDK demangler host) is deliberately NOT in
# this list. On a single machine it stays loopback like everything else here,
# but on the two-machine/Tailscale remote-client role it must stay pinned to
# 127.0.0.1 on that machine while everything else in this list routes to the
# host's relay address - callers that need peach.online.ea.com folded in
# should append it themselves; callers that must keep it separate already do.
$Fifa15RedirectableHostnames = @(
    'gosredirector.ea.com',
    'gosredirector.online.ea.com',
    'gosredirector.stest.ea.com',
    'gosredirector.scert.ea.com',
    'spring14.gosredirector.ea.com',
    'spring14.gosredirector.online.ea.com',
    'spring14.gosredirector.stest.ea.com',
    'spring14.gosredirector.scert.ea.com',
    'pal.lt.easfc.ea.com',
    'content.lt.easfc.ea.com',
    'easw.easports.com',
    'xmlns.easw.easports.com',
    'eac-fifapow02.eac.ad.ea.com',
    'fifa.easports.com'
)

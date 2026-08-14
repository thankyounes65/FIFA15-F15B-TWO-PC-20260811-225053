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
# demangler.ea.com is DirtySDK ProtoMangle's production default. In this
# two-machine runtime it follows the relay host address so Player B reaches the
# host-side TCP/3658 ProtoMangle service. peach.online.ea.com is added separately
# by remote-client.ps1 to the same host address because it is the DirtySDK
# development/test demangler name and older package revisions intentionally kept
# it role-specific.
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
    'fifa.easports.com',
    'demangler.ea.com'
)

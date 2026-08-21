# Vessel

Multi-container Instagram for **sideloaded** (non-jailbroken) iPhones.
One phone, N independent "phones": each container has its own filesystem,
keychain, preferences, cookies, device identity and GPS position.

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) first — it is the contract this code
follows, including the five non-negotiable rules and the reasons behind them.

## Hard constraints

| Constraint | Why |
|---|---|
| **Zero CydiaSubstrate / ElleKit / libhooker** | Those libraries do not exist on a non-jailbroken device. A single `LC_LOAD_DYLIB` pointing at `/Library/Frameworks/CydiaSubstrate.framework` makes dyld refuse the dylib and the whole tweak dies silently. Enforced by a CI gate. |
| Theos target is `LIBRARY_NAME`, never `TWEAK_NAME` | `tweak.mk` links Substrate automatically. `<NAME>_USE_SUBSTRATE = 0` was verified **insufficient** in this exact CI. |
| Hooks are manual | `method_setImplementation` for Objective-C, `fishhook`/`rebind_symbols` for C symbols. No `%hook`, no `MSHookFunction`. |
| Exactly one `__attribute__((constructor))` | In `Source/Entry/VSBootstrap.m`. Multiple constructors run in link order, which is undefined — that is how path redirection ended up running *after* its own dependents in the previous project. |
| arm64 only | The Instagram binary is thin arm64. |

## Build

Nothing is built on the developer's PC. GitHub Actions does everything on a
macOS runner.

```bash
gh workflow run build.yml -f mode=dylib
```

`mode=dylib` (default) compiles and runs the three hard gates — fast, and it
catches every compile-time problem. `mode=ipa` additionally downloads the base
Instagram IPA from the `base-ipa` release, injects the dylib with
`insert_dylib`, ad-hoc signs and republishes a ready-to-sideload IPA.

Two outputs:

* **`Vessel.ipa`** — release `build-<n>`. Install with Sideloadly.
* **`Vessel.dylib`** — rolling release `dylib-latest`, ~300 KB. For fast
  iteration: tick Sideloadly's *Inject dylibs/frameworks* and reuse the base
  IPA instead of moving 300 MB per test.

The base IPA is a **release asset**, not a repo file: repo files are capped at
100 MB, release assets go to 2 GB and do not count toward repository size.

## CI gates

The build fails, rather than shipping something dead, if the dylib:

1. links anything matching `substrate|ellekit|libhooker`,
2. is not arm64,
3. references `/Library/Frameworks` or `/Library/MobileSubstrate`,

and, in `ipa` mode, if the `LC_LOAD_DYLIB` for `Vessel.dylib` is missing from
the patched Instagram binary after injection.

## Layout

```
Tweak/
  Makefile                     LIBRARY target, file list grows one phase at a time
  Source/
    Entry/VSBootstrap.m        the single constructor; explicit init order
    Core/                      VSLog VSPaths VSStore VSIdentity VSContainer VSManager VSSelfTest
    Hooks/                     Home Keychain Defaults Cookies Device Location Locale
    UI/                        floating button, panel, container creation, map picker, diagnostics
    vendor/fishhook/           facebook/fishhook, for C-symbol rebinding
tools/
  machoprobe.py                offline Mach-O inspector (arch, cryptid, load commands)
```

## Diagnostics

Boot progress is recorded as numbered breadcrumbs (see `VSBootStep`). If
Instagram dies during init, the highest breadcrumb in
`<real home>/Library/Application Support/Vessel/diag/crash-*.log` names the
guilty module. Logs live under the **real** home, so they survive container
switches and "reset everything".

An optional remote sink (ntfy.sh) is available for diagnosing on-device
failures without a cable. It is **off by default**; every line goes through
`VSRedact()`, which drops cookies, tokens, passwords and long opaque blobs.

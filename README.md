# NotProton Sequoia

> **Save-data warning:** Prefix creation/rebuilding and Steam Cloud save synchronization
> have not been fully tested on Sequoia. Incorrect save paths or newly created saves
> could overwrite existing progress locally or in Steam Cloud. Back up your saves
> independently before testing; Steam Cloud is not a backup.

This community fork integrates upstream NotProton 1.1.2 and targets Apple Silicon
Macs running macOS Sequoia 15. It is not an official upstream release.
The source baseline includes upstream 1.1.2 through `caeb7ff`.

Sequoia changes include Swift 6.1 build compatibility, classic ICNS icon generation,
compatible toolbars, signed-app resource lookup, and bridge installation for every
Unix loader shipped in a runner.

Build with `make app`; the result is `out/NotProton.app`. Use `make app-zip` to package
the bundle. Building requires Xcode, the bridge toolchain and staged bridge binaries
(see the build targets and `bridge/setup-wine-tree.sh`).

App updates are manual: **Sequoia Releases…** opens this fork's releases page.
The Status pane separately shows the version of the component deployed into Steam.
**Install** installs the component bundled in the app and may stop Steam.

Before testing games, keep independent save backups. Automated prefix tests do not
prove Steam Cloud synchronization is safe for every game. Real game/Cloud validation
is still required before treating a build as fully tested.

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with Steam Client 1788652215 or 1790121765 and **CrossOver 26.3 or CrossOver Preview
20261006 or 2026082**. Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the
Preview 20261006, as it includes both the FEX version as well as the Rosetta one.

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

This release is coming several days past when I wanted to release it, so the
documentation is quite sparse. Sorry about that, I'll improve it shortly. For real this time.

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged. Contributions policy to come shortly.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently.

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself.
I would have done things differently had I been aware of that.

Thanks to everyone who has positively contributed to macOS gaming.

# FilzaSlop

FilzaJailedDS fork with:

- A sandbox escape for iOS 18, iOS 26, and iOS 27 beta 1–4.
- App container access.
- Other less interesting directories listed below.
- A PosterBoard Wallpaper Lab.

> **Not every feature currently works on iOS 18 or iOS 26.**
> [Open an issue](https://github.com/0xjohnnydev/FilzaSlop/issues) if you find a problem.

**The unsigned IPA is available on the
[Releases page](https://github.com/0xjohnnydev/FilzaSlop/releases).**

## Paths

### Container roots

```text
/private/var/mobile/Containers/Data/Application/
/private/var/mobile/Containers/Shared/AppGroup/
/private/var/mobile/Containers/Data/PluginKitPlugin/
/private/var/mobile/Containers/Data/VPNPlugin/
/private/var/mobile/Containers/Data/InternalDaemon/
/private/var/mobile/Containers/Data/System/
/private/var/mobile/Containers/Shared/SystemGroup/
/private/var/mobile/Containers/Data/Protected/
```

### Additional paths

```text
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/
/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.installcoordinationd/Library/InstallCoordination/
```

### Notable app data

```text
# Notes
/private/var/mobile/Containers/Shared/AppGroup/<Notes-group-UUID>/NoteStore.sqlite

# Safari app data
/private/var/mobile/Containers/Data/Application/<Safari-app-UUID>/

# Safari shared data: group.com.apple.safari
/private/var/mobile/Containers/Shared/AppGroup/<Safari-group-UUID>/
```

## PosterBoard

Wallpaper Lab can:

- Inspect the PosterBoard descriptor store.
- Import the bundled Cipher wallpaper.
- Import extracted `.tendies` wallpaper packages.
- Apply the PosterBoard refresh preferences.
- Roll back the latest import.

Place additional packages in:

```text
Documents/Device Storage/[MHA-C2] Wallpaper Lab/Imports/
```

Use the **Wallpaper** button at the Wallpaper Lab root. Imports add new
descriptor directories and keep a rollback backup. They do not overwrite the
PosterBoard database or existing descriptors.

## Signing

Keep this bundle and CodeDirectory identifier:

```text
com.apple.mobile.MobileHouseArrest
```

Changing it disables the MobileHouseArrest path.

## Mixed traversal map

`[MHA-Mixed EXP] Experimental` contains only the probes that succeeded during
the previous iPadOS 27.0 (`24A5390f`) device run. The retained probe numbers
remain unchanged so new `Probe Results.plist` output can be compared directly
with that run.

Each successful link requires a non-empty token from that query, successful
activation, an exact canonical-path match, and a read-only directory open.
`README.txt`, `README - Access.txt`, `Access Map.txt`, and
`Probe Results.plist` report successes, failures, activation evidence, and
errno values. Probe setup does not modify target files, and the custom Filza
copy, paste, and delete paths stay disabled inside the Mixed folder.

## iOS 26 app discovery

iOS 26 can hide third-party apps from the normal ContainerManager and
LaunchServices enumeration APIs. FilzaSlop now reads the device-local
LaunchServices store through the accessible `com.apple.lsd` service container.
It extracts bundle identifier candidates and confirms each candidate with a
direct class-2 ContainerManager lookup. The release IPA does not need a device
catalog.

`MCMIdentifiers.plist` remains an optional manual fallback. You can generate
one with `scripts/refresh_device_catalog.sh` and pass it as the third release
build argument.

## App Manager RSD cache

App Manager can refresh names, versions, bundle identifiers, and icons through
the local device-service transports used by JIT/debugging tools. This does not
scan application bundle directories.

1. Put the device pairing file in Filza's `Documents` root, next to `Device
   Storage`. Use `pairingFile.plist`, `rp_pairing_file.plist`, or a file ending
   in `.mobiledevicepairing`/`.mobiledevicepair`. Other Documents-root `.plist`
   names are also tried and accepted only if either the RemotePairing or
   traditional Lockdown parser validates them.
2. Start LocalDevVPN.
3. Launch Filza. The refresh starts in the background immediately, is retried
   when App Manager opens or Filza becomes active, and repeats every five
   minutes while Filza remains in the foreground. It connects to
   `10.7.0.1:49152`, reads `installation_proxy`, commits changed metadata, then
   downloads only missing or version-stale icons from SpringBoardServices.
4. Keep LocalDevVPN active until either `App Manager RSD Diagnostics.txt` next
   to `Device Storage`, or the copy inside `Device Storage`, reports `complete`.

A local-network privacy prompt is not expected for every configuration. A raw
unicast connection routed through the VPN interface can proceed without that
prompt, so use the staged diagnostics file rather than the presence of a popup
as the connection indicator.

Two pairing formats are supported and selected by actual parsing:

- RemotePairing records containing `public_key`, `private_key`, and
  `identifier` use RPPairing/RSD on `10.7.0.1:49152`.
- Traditional Lockdown records containing `HostCertificate`,
  `HostPrivateKey`, `RootCertificate`, and `HostID` use the Lockdown TCP
  provider on `10.7.0.1:62078`.

These formats use different cryptographic identities and are not converted
into one another. The diagnostics file records the selected transport.

The persistent result is stored under `Documents/App Manager Cache`. Later App
Manager launches use that cache without needing the VPN. A failed refresh does
not replace an existing successful cache. If the application records are
unchanged, the existing `Applications.plist` and icon cache are preserved. If
an install or uninstall changes the records, the RSD list becomes the App
Manager catalogue and the visible list is rebuilt.

App Manager search filters that catalogue directly by localized application
name or complete bundle identifier; it does not invoke Filza's filesystem
search. For RSD user applications missing from the launch-time class-2 map,
Filza retries the class-2 lookup in the background and adds the data-container
link when MobileContainerManager grants it. System records without an
independent class-2 data container remain visible for inventory purposes but
cannot be opened as application data.

The current implementation intentionally uses external LocalDevVPN. Embedding
a VPN requires a separately provisioned Packet Tunnel Provider extension; a
VPN entitlement on the main app alone is not sufficient.

## Build

```sh
export THEOS="$HOME/theos"
make clean
make package FINALPACKAGE=1
```

Inject `FilzaApplySandboxExt.dylib` into Filza and sign the app.

To build the unsigned release IPA:

```sh
./scripts/build_release_ipa.sh \
  FilzaSlop-v1.0.0-unsigned.ipa \
  FilzaSlop-v1.0.1-unsigned.ipa
```

## PoCs

- [MobileHouseArrest](https://github.com/0xjohnnydev/MobileHouseArrest-PoC)
- [Geod MCM](https://github.com/0xjohnnydev/Geod-MCM-PoC)
- [InstallCoordination](https://github.com/0xjohnnydev/InstallCoordination-PoC)
- [CFPrefs zero-file](https://github.com/0xjohnnydev/CFPrefsZeroFile-PoC)

## Credits

- [34306/FilzaJailedDS](https://github.com/34306/FilzaJailedDS)
- CrazyMind90
- XPF and ChOma contributors
- `SerStars/nugget-wallpapers`
- mightycooldude12

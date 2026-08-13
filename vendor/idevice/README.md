# idevice FFI archive

This directory contains the arm64 `libidevice_ffi.a` used by the App Manager
RSD catalogue bridge.

- Upstream: <https://github.com/jkcoxson/idevice>
- License: MIT; see `LICENSE.txt`
- Prebuilt archive source: StikDebug commit
  `ae460a7a5dc3d3fd1fd2a6ee78547f518485b897`
- SHA-256:
  `6524066d54ef23e00d46445c04dfc694e180196d54119d718f68434fa225be35`
- Architecture: arm64
- Minimum platform encoded by the archive: iOS 17.0

The Filza integration calls only the MIT-licensed C FFI exported by this
archive. No StikDebug application source is copied into FilzaReborn.

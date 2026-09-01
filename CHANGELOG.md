# Changelog

All notable changes to this project are documented here. This file is maintained
automatically by [semantic-release](https://github.com/semantic-release/semantic-release)
on every release to `main`.

## [0.4.4](https://github.com/bauer-group/XPD-RPIImage/compare/v0.4.3...v0.4.4) (2026-09-01)

### 🐛 Bug Fixes

* **build:** stopped losing the inherited base image checksum ([84d1f50](https://github.com/bauer-group/XPD-RPIImage/commit/84d1f506b9b85312bccab154c74535357b08f3d0))

## [0.4.3](https://github.com/bauer-group/XPD-RPIImage/compare/v0.4.2...v0.4.3) (2026-09-01)

### 🐛 Bug Fixes

* **build:** made the documented .env and validate flows work ([b9891a3](https://github.com/bauer-group/XPD-RPIImage/commit/b9891a3e0b576728945988863e7287c092140718))
* **hw:** emitted fan hysteresis instead of dropping it ([891b775](https://github.com/bauer-group/XPD-RPIImage/commit/891b7758b6b76f5be60ef5620f15251386d22374))

## [0.4.2](https://github.com/bauer-group/XPD-RPIImage/compare/v0.4.1...v0.4.2) (2026-09-01)

### 🐛 Bug Fixes

* **base:** made bgrpiimage-setup usable on the device ([1cffa5a](https://github.com/bauer-group/XPD-RPIImage/commit/1cffa5aedb5a0342f68b92a2a1173c68941d2d67))

## [0.4.1](https://github.com/bauer-group/XPD-RPIImage/compare/v0.4.0...v0.4.1) (2026-09-01)

### 🐛 Bug Fixes

* **tools:** made the nested Windows build actually work ([90f42be](https://github.com/bauer-group/XPD-RPIImage/commit/90f42beeb9bd00f3b4890e54ea2cabe46f2933e6))

## [0.4.0](https://github.com/bauer-group/XPD-RPIImage/compare/v0.3.2...v0.4.0) (2026-08-31)

### 🚀 Features

* **security:** expired the shipped default password at first login ([4d15019](https://github.com/bauer-group/XPD-RPIImage/commit/4d15019b7cc57536d86cb76592838a130e29b1a1))

## [0.3.2](https://github.com/bauer-group/XPD-RPIImage/compare/v0.3.1...v0.3.2) (2026-08-31)

### 🐛 Bug Fixes

* **build:** accepted an uppercase CustomPiOS SHA pin ([85cff73](https://github.com/bauer-group/XPD-RPIImage/commit/85cff739e23f52900a2e62da1189efc4a5c2fdba))
* **build:** verified the image that is actually consumed ([8df0dd5](https://github.com/bauer-group/XPD-RPIImage/commit/8df0dd570acafd260712cfad66adcd25bbe5e973))
* **security:** flagged the CI placeholder credentials as weak ([d5f7567](https://github.com/bauer-group/XPD-RPIImage/commit/d5f756764d4f33471505f594dee42a352738a0d4))
* **tools:** quoted the host path passed to the tools container ([9b1d0f6](https://github.com/bauer-group/XPD-RPIImage/commit/9b1d0f661f33c83df3928693b492112eb80d6f8c))

## [0.3.1](https://github.com/bauer-group/XPD-RPIImage/compare/v0.3.0...v0.3.1) (2026-08-31)

### 🐛 Bug Fixes

* **build:** stopped committing generated variant configs ([476da55](https://github.com/bauer-group/XPD-RPIImage/commit/476da55fc0b596cc6ada91aec14fcfe2dc39fcbd))

## [0.3.0](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.5...v0.3.0) (2026-08-31)

### 🚀 Features

* **security:** warned at build time about default credentials ([9d26fd1](https://github.com/bauer-group/XPD-RPIImage/commit/9d26fd169588e2fd45a6ef735022addd6fd60d05))

### 🐛 Bug Fixes

* **build:** corrected make clean target paths ([b04149a](https://github.com/bauer-group/XPD-RPIImage/commit/b04149ac1fadb56617ef1990726616c702af3f60))
* **build:** verified base image checksum before unpacking ([2df0b4b](https://github.com/bauer-group/XPD-RPIImage/commit/2df0b4b94b162bcb7bb6d5f520e01afc5d5477f2))
* **ci:** migrated CustomPiOS to 2.0.0 and pinned it by SHA ([b823c54](https://github.com/bauer-group/XPD-RPIImage/commit/b823c54304aab18da14f181cf2a003486d8320d3))
* **tools:** fixed sibling container mount from tools container ([ee57fae](https://github.com/bauer-group/XPD-RPIImage/commit/ee57fae0e1a9413ce71b9021f091ad6bb968341e))

## [0.2.5](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.4...v0.2.5) (2026-08-31)

### 🐛 Bug Fixes

* **base:** update base image URL to the latest version 2026-06-19 ([c54b438](https://github.com/bauer-group/XPD-RPIImage/commit/c54b438c95fe2e5678c8f9edd1e65c2f65ffcd5c))

## [0.2.4](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.3...v0.2.4) (2026-08-31)

### 🐛 Bug Fixes

* **base:** update base OS version and image URL to 2026-06-18 ([31d5fcb](https://github.com/bauer-group/XPD-RPIImage/commit/31d5fcb5ad4b1eb9c3fcdb009af9dcf6193d77f9))
* **ci:** added the missing permissions block ([22f73e6](https://github.com/bauer-group/XPD-RPIImage/commit/22f73e6c62708e968e8cea4a7dfd6178a267704b))

## [0.2.3](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.2...v0.2.3) (2026-06-17)

### 🐛 Bug Fixes

* **build:** forced MODULES=most for initramfs in chroot build ([4d4f43d](https://github.com/bauer-group/XPD-RPIImage/commit/4d4f43d6a1cfbb1ce58ed934e7aa347e2223acb6))

## [0.2.2](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.1...v0.2.2) (2026-06-17)

### 🐛 Bug Fixes

* **base:** updated Raspberry Pi OS base to 2026-04-21 ([93bd941](https://github.com/bauer-group/XPD-RPIImage/commit/93bd941d8495b6bdf6c6fff89a8aa46cefa0039d))
* **pages:** attached reconstructed manifests back to legacy releases ([0e18821](https://github.com/bauer-group/XPD-RPIImage/commit/0e188210d93b08b70b313353e6ec9c913f2f0c8a))
* **pages:** fell back to github.io default until custom DNS is wired up ([b080829](https://github.com/bauer-group/XPD-RPIImage/commit/b0808294200850a0b018de4f55dbdb515a265c77))
* **pages:** let the hero subtitle span one line + richer footer ([fad7ac7](https://github.com/bauer-group/XPD-RPIImage/commit/fad7ac78ad091b41bc10484006d7bfb7070a17a2))
* **pages:** used Imager family tags for Pi5/CM4/CM5 ([333e74c](https://github.com/bauer-group/XPD-RPIImage/commit/333e74c31b00d2c308a640b6116fa9db878c8fd2))

### ♻️ Refactoring

* **pages:** served manifests as Pages assets, not release uploads ([7ed9c9e](https://github.com/bauer-group/XPD-RPIImage/commit/7ed9c9ead7a7d56b8642ca7c90d1f0492a62988c))

## [0.2.1](https://github.com/bauer-group/XPD-RPIImage/compare/v0.2.0...v0.2.1) (2026-04-19)

### 🐛 Bug Fixes

* **pages:** fell back to previous release when latest has no images yet ([d8dc3b3](https://github.com/bauer-group/XPD-RPIImage/commit/d8dc3b3e7e1f8ebf0552649820bc34b9edb1f276))
* **pages:** installed scripts/requirements.txt before reconstruct step ([ab42e7a](https://github.com/bauer-group/XPD-RPIImage/commit/ab42e7a5ba783dc2e23785c360ec6471841b8283))

### ♻️ Refactoring

* **pages:** extracted HTML into site/*.tmpl + scoped workflow triggers ([31f4e67](https://github.com/bauer-group/XPD-RPIImage/commit/31f4e676369e040dfe55bcccb199bcda034cd23a))
* **pages:** switched to Jinja2, wired workflow_run auto-refresh, adopted BAUER GROUP CI ([5cb9a89](https://github.com/bauer-group/XPD-RPIImage/commit/5cb9a8971bb4813ac05862f02a661d8078dbc204)), closes [#FF8500](https://github.com/bauer-group/XPD-RPIImage/issues/FF8500)

## [0.2.0](https://github.com/bauer-group/XPD-RPIImage/compare/v0.1.0...v0.2.0) (2026-04-19)

### 🚀 Features

* **pages:** published RPi Imager catalog + landing page via GitHub Pages ([aef8fbb](https://github.com/bauer-group/XPD-RPIImage/commit/aef8fbb6eaa0666c4d617b11e7e40880dcf50e45))

### 🐛 Bug Fixes

* **ci:** resolved inherited variant.version in the validate summary ([404997f](https://github.com/bauer-group/XPD-RPIImage/commit/404997f7daa792d360651c7f1de9946a6af0dbf4))

## [0.1.0](https://github.com/bauer-group/XPD-RPIImage/compare/v0.0.0...v0.1.0) (2026-04-19)

### 🚀 Features

* added variant composition and reboot trigger ([7fb26f4](https://github.com/bauer-group/XPD-RPIImage/commit/7fb26f4a17fa14a060145298c32342c0933e3015))
* **base:** enabled ssh and added login banners ([7a7b3fe](https://github.com/bauer-group/XPD-RPIImage/commit/7a7b3fe6ad015cc28676f6caf12c6eefcf4fc2de))
* **ci:** reworked workflow and artifact naming ([c7a7e9a](https://github.com/bauer-group/XPD-RPIImage/commit/c7a7e9afd6efdb8745329e6a1cdc981ca63aa499))
* **cli:** integrated rich for console output ([b3c9b16](https://github.com/bauer-group/XPD-RPIImage/commit/b3c9b16c51748b77a082840258c9363ccef20453))
* **hw:** exposed every on-board Pi peripheral as structured JSON blocks ([1bf3d7e](https://github.com/bauer-group/XPD-RPIImage/commit/1bf3d7e6c76ad9ef8546f9bf774f005bc33cf9ac))
* Initial Commit ([aa86ce5](https://github.com/bauer-group/XPD-RPIImage/commit/aa86ce53bf0dedef44d9a99be0a3ad9f19db30db))
* Refactoring ([55fa330](https://github.com/bauer-group/XPD-RPIImage/commit/55fa330816ed2d8ad99190d82be29ed3acf1ae0a))
* **setup:** added post-flash setup helper ([246a2ad](https://github.com/bauer-group/XPD-RPIImage/commit/246a2ad082a13f983752b0592313a6e636cde073))
* **tools:** added portable docker-based runtime ([d7685a2](https://github.com/bauer-group/XPD-RPIImage/commit/d7685a2ce30a8626f93e6d576af081ba507901dd))

### 🐛 Bug Fixes

* **build:** also seed BASE_MOUNT_PATH in build_dist ([be4bfcb](https://github.com/bauer-group/XPD-RPIImage/commit/be4bfcb22865461c0b163dec0229933b6ab77d9e))
* **build:** chown dist/ back to invoking user after sudo run ([d9b8257](https://github.com/bauer-group/XPD-RPIImage/commit/d9b82574a34596c172c7481ee2e75765ec809d6a))
* **build:** comma-separate MODULES list for CustomPiOS ([3971cfe](https://github.com/bauer-group/XPD-RPIImage/commit/3971cfe38e4b4edcdf8dec6eab51b9948fc95f90))
* **build:** deploy module files via filesystem/root + unpack ([f2657d9](https://github.com/bauer-group/XPD-RPIImage/commit/f2657d9e6ccd4eef24aa4713a80d8b9a633030f7))
* **build:** download and pre-extract raspios image for customPiOS ([4990cff](https://github.com/bauer-group/XPD-RPIImage/commit/4990cffab8aab7bbdd9456c57ff463a6b35bfd6d))
* **build:** native ci run, pinned 1.5.0, portainer compose ([5accc88](https://github.com/bauer-group/XPD-RPIImage/commit/5accc88de8e605f6151ee6947c8fb43a8a54b93d))
* **build:** ran update-custompios-paths inside the container ([b6a319f](https://github.com/bauer-group/XPD-RPIImage/commit/b6a319f14959548860d6dbb92dd55f9c4f24d630))
* **build:** reverted customPiOS pin; dropped rpi zero 2 w ([09d6de0](https://github.com/bauer-group/XPD-RPIImage/commit/09d6de04701cfabe7b4c7df217cdb231ec8b8ccd))
* **build:** seed BASE_ROOT_PARTITION and BASE_BOOT_PARTITION ([15679c7](https://github.com/bauer-group/XPD-RPIImage/commit/15679c706756902e4d44c65e3f294eea096b98df))
* **build:** set BASE_BOOT_MOUNT_PATH for bookworm/trixie layout ([347cdaa](https://github.com/bauer-group/XPD-RPIImage/commit/347cdaaf2235b722327d6e2d76d6571df5a90ddf))
* **build:** use config.local to override BASE_ZIP_IMG ([e7dd3b0](https://github.com/bauer-group/XPD-RPIImage/commit/e7dd3b0f232fb6bd005d0a1ccf241275aa282d9d))
* **network:** dropped obsolete crda package ([cf3b271](https://github.com/bauer-group/XPD-RPIImage/commit/cf3b2718c276fbd2eb2e685c8edb974a9d590f13))
* **release:** handle identity-replacement edge case on first release ([77524c6](https://github.com/bauer-group/XPD-RPIImage/commit/77524c68c92a8d0417ead7fc853029efd67ae2a1))
* repaired ci and normalized all paths to lowercase ([fb194d5](https://github.com/bauer-group/XPD-RPIImage/commit/fb194d5bf54184a90f052ac67a94e14a6e816e8c))
* **users:** pre-create groups before usermod -aG ([e27327e](https://github.com/bauer-group/XPD-RPIImage/commit/e27327ee481bfc86d2f71deefba55cc537c32f32))

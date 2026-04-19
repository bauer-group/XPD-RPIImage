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

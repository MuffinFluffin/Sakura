# Sakura

PS1 emulator for iOS and iPadOS. Native Swift + Metal shell wrapped around the Beetle PSX libretro core.

GPL-3.0+. Repo: https://github.com/MuffinFluffin/Sakura

## Build

1. Build the PS1 core:
   ```bash
   bash scripts/build_beetle_psx_ios.sh
   ```
2. Generate the Xcode project:
   ```bash
   cmake -S src/cpp -B build/atmos -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DSakura_REAL_DEVICE=ON
   ```
3. Open `build/atmos/Sakura.xcodeproj`, configure signing, and run.

## Project Structure

- `src/cpp/`: Native bridge and Metal shaders.
- `src/swift/`: SwiftUI application shell.
- `Legal/`: Licenses and guides.

## License

GPL-3.0.

# Legal Notes

This repository contains source code and build scripts for the UWP host, GLFW
shim, compatibility mod, and related patches.

It does not grant rights to redistribute Minecraft, Mojang assets, Fabric,
LWJGL, a Java runtime, Xbox platform files, or any other third-party
component.

The Mesa UWP runtime is bundled in this repository under its own upstream
license terms and remains subject to those notices and conditions.

## Repository License

The original project code is under the custom license in `LICENSE`.

In short:

- Private forks are allowed for your own personal, educational, research, or
  internal use.
- Public content based on the project must include credit and a visible link
  back to veroxsity / BanditVault.
- Redistribution is not allowed without prior written permission from
  veroxsity / BanditVault.
- Third-party components keep their own licenses and terms.

## Local Files

The build process creates or uses local files that should stay out of git:

- Minecraft game files and assets.
- Downloaded libraries.
- Runtime images.
- Native DLLs.
- Mesa runtime DLLs in local scratch locations outside the bundled
  `mesa-runtime/` folder.
- Signed `.appx` packages.
- Development signing certificates.

Those paths are ignored in `.gitignore` and are stored under `staging` or `output`.

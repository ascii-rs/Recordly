# Recordly Nix flake
#
# Usage:
#   nix develop                       # Node 22 + native toolchain + X11 dev libs
#   nix build .#recordly              # Linux package (see caveats below)
#   nix run .#recordly                # run the packaged app
#
# Caveats:
#   * The package derivation runs `npm ci` + `electron-builder`, both of which
#     download binaries from the network (Electron dist, whisper.cpp sources,
#     ffmpeg-static, ...). Nix's default sandbox blocks that, so build with:
#         nix build .#recordly --option sandbox false
#     (or configure `sandbox = false` in nix.conf if you build often).
#   * The flake pins nixpkgs 24.11. Recordly ships Electron 43; if Electron's
#     required glibc ever outpaces 24.11's, switch the `nixpkgs` input to
#     `nixos-unstable` and re-pin `flake.lock`.
#   * Only Linux can be packaged from Nix (macOS/Windows release builds are
#     signed upstream). The dev shell still works on macOS for running
#     `npm install` / `npm run dev` / `npm run build:mac` when Xcode CLT and
#     the signing credentials are available.
#   * The app is launched with --no-sandbox because Nix can't ship the SUID
#     chrome-sandbox helper; the app only loads local content.

{
  description = "Recordly: dev shell + Linux package for the Electron screen recorder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # Electron dist zip + CUDA tooling
        };
        lib = pkgs.lib;
        isLinux = pkgs.stdenv.isLinux;

        # Version mirrors package.json so bumping the app version is enough.
        version = (builtins.fromJSON (builtins.readFile ./package.json)).version;

        # The Linux CI pipeline runs on Node 22 with a Python 3 + CMake +
        # X11-dev toolchain for the native addons (uiohook-napi, whisper.cpp).
        nodejs = pkgs.nodejs_22;

        # X11 development headers required by node-gyp/uiohook-napi on Linux
        # (mirrors the apt list in .github/workflows/build.yml).
        linuxNativeBuildLibs = with pkgs; [
          xorg.libX11
          xorg.libXt
          xorg.libXtst
          xorg.libxkbfile
          xorg.libXi
          xorg.libXrandr
          xorg.libXinerama
        ];

        # Libraries the packaged Electron app loads at runtime. When the app is
        # started from the dev shell (`npm run dev`) these are also needed, so
        # they double as the dev shell's buildInputs (mkShell exposes their lib
        # dirs via LD_LIBRARY_PATH automatically).
        linuxRuntimeLibs = with pkgs; [
          gtk3
          gsettings-desktop-schemas
          adwaita-icon-theme
          nss
          nspr
          alsa-lib
          cups
          dbus
          libdrm
          mesa
          libxkbcommon
          libsecret
          libnotify
          at-spi2-core
          xorg.libX11
          xorg.libXcomposite
          xorg.libXcursor
          xorg.libXdamage
          xorg.libXext
          xorg.libXfixes
          xorg.libXi
          xorg.libXrandr
          xorg.libXrender
          xorg.libXScrnSaver
          xorg.libXinerama
          xorg.libxcb
        ];

        # --------------------------------------------------------------------
        # Dev shell
        # --------------------------------------------------------------------
        devShell = pkgs.mkShell {
          name = "recordly-dev-shell";

          nativeBuildInputs =
            [ nodejs pkgs.python3 pkgs.cmake pkgs.pkg-config pkgs.git ]
            ++ lib.optionals isLinux linuxNativeBuildLibs;

          buildInputs = lib.optionals isLinux linuxRuntimeLibs;

          env = {
            # node-gyp resolves the Python interpreter through this.
            PYTHON = "${pkgs.python3}/bin/python3";
            # Keep native builds on the nix toolchain.
            PKG_CONFIG = "${pkgs.pkg-config}/bin/pkg-config";
          };

          shellHook = ''
            echo "🚀 Recordly dev shell (${system})"
            echo "   Node:  $(node --version 2>/dev/null || echo missing)"
            echo "   npm:   $(npm --version 2>/dev/null || echo missing)"
            echo "   CMake: $(cmake --version 2>/dev/null | head -n1 || echo missing)"
            echo ""
            echo "Suggested first run:"
            echo "  npm install"
            echo "  npm run dev"
            echo ""
            echo "NOTE: 'npm install' downloads Electron/whisper/ffmpeg binaries"
            echo "      and builds native addons; it needs network access."
          '';
        };

        # --------------------------------------------------------------------
        # Package: builds the app like `npm run build:linux` but with the
        # `dir` electron-builder target (release/linux-unpacked), which avoids
        # the AppImage toolchain/fuse and is directly wrappable for Nix.
        # --------------------------------------------------------------------
        recordlyUnwrapped = pkgs.stdenv.mkDerivation {
          pname = "recordly-unwrapped";
          inherit version;
          src = lib.cleanSource ./.;

          nativeBuildInputs =
            [ nodejs pkgs.python3 pkgs.cmake pkgs.pkg-config pkgs.git ]
            ++ linuxNativeBuildLibs;

          buildInputs = linuxRuntimeLibs;

          dontStrip = true; # electron-builder ships pre-stripped binaries
          enableParallelBuilding = true;

          configurePhase = ''
            runHook preConfigure
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            # Runs the repo postinstall: rebuilds uiohook-napi for the pinned
            # Electron and stages the whisper.cpp runtime (downloads sources).
            npm ci --no-audit --no-fund
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            # Mirrors `npm run build:linux`, except the last step targets
            # `dir` instead of AppImage. The vite build already ran its own
            # electron-main CJS smoke checks via the closeBundle guard.
            npm run build:platform-native-helpers
            ./node_modules/.bin/tsc
            ./node_modules/.bin/vite build --config vite.config.ts
            npm run normalize:electron-main-cjs
            npm run smoke:electron-main-cjs
            ./node_modules/.bin/electron-builder --linux dir
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/libexec/recordly" "$out/bin"
            cp -a release/linux-unpacked/. "$out/libexec/recordly/"
            chmod -R u+w "$out/libexec/recordly"

            if [[ -x "$out/libexec/recordly/recordly" ]]; then
              binName="recordly"
            elif [[ -x "$out/libexec/recordly/Recordly" ]]; then
              binName="Recordly"
            else
              echo "recordly executable not found in release/linux-unpacked" >&2
              ls -la "$out/libexec/recordly" >&2
              exit 1
            fi
            ln -s "$out/libexec/recordly/$binName" "$out/bin/recordly"
            runHook postInstall
          '';

          meta = {
            description = "Creator-focused screen recorder with auto-zoom, cursor effects and editing (unwrapped build)";
            homepage = "https://github.com/webadderallorg/Recordly";
            license = lib.licenses.agpl3Only;
            platforms = lib.platforms.linux;
            mainProgram = "recordly";
          };
        };

        # FHS wrapper: gives the bundled Electron binary a complete runtime
        # environment (GTK, NSS, ALSA, X11, ...) without chasing transitive
        # library paths by hand.
        recordly = pkgs.buildFHSEnv {
          name = "recordly";
          targetPkgs = pkgs': [ recordlyUnwrapped ] ++ linuxRuntimeLibs;
          runScript = "recordly --no-sandbox";
        } // {
          meta = {
            description = "Recordly – free, creator-focused screen recorder with auto-zoom, cursor effects, backgrounds, annotations, and editing";
            homepage = "https://github.com/webadderallorg/Recordly";
            license = lib.licenses.agpl3Only;
            platforms = lib.platforms.linux;
            mainProgram = "recordly";
          };
        };
      in
      {
        devShells.default = devShell;

        # Packaging only makes sense on Linux from Nix; macOS/Windows release
        # artifacts are produced by the upstream CI (macOS needs signing).
        packages = lib.optionalAttrs isLinux {
          inherit recordly recordlyUnwrapped;
          default = recordly;
        };

        formatter = pkgs.nixpkgs-fmt;
      }
    );
}

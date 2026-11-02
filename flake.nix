{
  description = "strixite built with Nix: Qwen3.8-Flash-Next on AMD Strix Halo (gfx1151)";

  # The same nixpkgs as the halogen flake on this box.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;

      # TheRock ROCm for gfx1151, the toolchain strixite is tested with (README, step 2).
      # Prebuilt binaries: autoPatchelfHook points their interpreter and libraries at the Nix store.
      therock = pkgs.stdenv.mkDerivation {
        pname = "therock-gfx1151";
        version = "10.1.0";
        src = pkgs.fetchurl {
          url = "https://stable.repo.amd.com/rocm/core/tarball/therock-dist-linux-gfx1151-10.1.0.tar.gz";
          hash = "sha256-UN65kwNbwvalq6Xj3o1HbYxRKi7sLL/VqladceC4szc=";
        };
        sourceRoot = ".";
        nativeBuildInputs = [ pkgs.autoPatchelfHook ];
        buildInputs = with pkgs; [
          stdenv.cc.cc.lib zlib zstd libxml2 ncurses numactl libdrm elfutils libffi xz bzip2 sqlite python3
        ];
        # TheRock bundles optional tools (profilers, Python bindings) whose deps are irrelevant to building and
        # running strixite; autoPatchelf reports them instead of failing.
        autoPatchelfIgnoreMissingDeps = true;
        dontConfigure = true;
        dontBuild = true;
        dontStrip = true;
        installPhase = ''
          runHook preInstall
          root=$(dirname "$(find . -path '*/include/hip/hip_runtime.h' -print -quit)")/../..
          mkdir -p $out
          cp -a "$root"/. $out/
          runHook postInstall
        '';
      };

      gcc = pkgs.stdenv.cc.cc;
      gccInstallDir = "${gcc}/lib/gcc/${pkgs.stdenv.hostPlatform.config}/${gcc.version}";
      glibc = pkgs.glibc;

      # TheRock's clang is unwrapped, so it is told where glibc and libstdc++ live; CMakeLists.txt keeps $CXXFLAGS.
      hostFlags = lib.concatStringsSep " " [
        # CMakeLists.txt passes --gcc-install-dir to C++ only; C (libwebp, and CMake's compiler check) needs it too
        # to find crtbegin.o and libgcc.
        "--gcc-install-dir=${gccInstallDir}"
        # After libstdc++'s directories, where a system install has it: libstdc++'s <cstdlib> reaches glibc's
        # <stdlib.h> with #include_next, which only searches directories after its own.
        "-idirafter ${glibc.dev}/include"
        "-B${glibc}/lib"
        "-L${glibc}/lib"
        "-L${gcc.lib}/lib"
      ];
      linkFlags = lib.concatStringsSep " " [
        "-fuse-ld=lld"
        "-Wl,-dynamic-linker,${glibc}/lib/ld-linux-x86-64.so.2"
        "-Wl,-rpath,${gcc.lib}/lib"
        "-Wl,-rpath,${glibc}/lib"
      ];

      strixite = pkgs.stdenv.mkDerivation {
        pname = "strixite";
        version = "0.5.0";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.gitTracked ./.;
        };
        nativeBuildInputs = [ pkgs.cmake pkgs.ninja ];
        cmakeFlags = [
          "-DCMAKE_BUILD_TYPE=Release"
          "-DSTRIX_ROCM_ROOT=${therock}"
          "-DSTRIX_GCC_INSTALL_DIR=${gccInstallDir}"
          # Nix's cmake hook sets these cache entries from $CC/$CXX (the wrapped GCC); strixite must be built by
          # TheRock's clang, and its CMakeLists only picks that when the cache entry is unset.
          "-DCMAKE_C_COMPILER=${therock}/lib/llvm/bin/clang"
          "-DCMAKE_CXX_COMPILER=${therock}/lib/llvm/bin/clang++"
        ];
        preConfigure = ''
          export CFLAGS="${hostFlags}"
          export CXXFLAGS="${hostFlags}"
          export LDFLAGS="${linkFlags}"
        '';
        # The project has no install rules: keep the binaries and the shipped config.
        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin $out/share/strixite
          for b in strix_server convert_qwen4exp convert_ngram_table transcode_ngram_table inspect_strixw; do
            [ -x "$b" ] && cp "$b" $out/bin/
          done
          cp ${./deploy/strix-server.conf} $out/share/strixite/strix-server.conf
          runHook postInstall
        '';
        dontStrip = true;
        meta.mainProgram = "strix_server";
      };

      # The server on a box that also runs csf, Timescale and Grafana (docs/memory.md, "also your desktop"):
      # half the context, one slot, a larger RAM margin; the startup memory check stays at its default, fail.
      # Measured on a 128 GB box with ~25 GiB used by other services: two slots left 10.6 GiB after loading and the
      # check refused them by 1.5 GiB; one slot frees ~4.2 GiB of state.
      serve = pkgs.writeShellApplication {
        name = "strixite-serve";
        text = ''
          models=''${STRIX_MODELS_DIR:-$HOME/models/strix-infer}
          export HSA_DISABLE_COREDUMP_ON_EXCEPTION=1
          exec ${strixite}/bin/strix_server \
            --config ${strixite}/share/strixite/strix-server.conf \
            --weights "$models/converted/Qwen3.8-Flash-Next.U-gdn_in-g128/weights.strixw" \
            --capacity 262144 \
            --total-slots 1 \
            --prompt-cache-ram-margin-gib 8 \
            "$@"
        '';
      };
    in
    {
      packages.${system} = { inherit therock strixite serve; default = strixite; };
      apps.${system} = {
        serve = { type = "app"; program = "${serve}/bin/strixite-serve"; };
        default = self.apps.${system}.serve;
      };
    };
}

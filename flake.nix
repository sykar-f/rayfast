{
  description = "rayfast: a tiny native macOS launcher";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "rayfast";
          version = "1.0";
          src = self;

          # The Makefile stays the single build recipe (`make run` for quick
          # iteration). Its `codesign` step is `|| true` and the sandbox has
          # none: ld64's ad-hoc signature is enough to run.
          dontStrip = true; # the Makefile already runs `strip -x`

          installPhase = ''
            runHook preInstall
            mkdir -p $out/Applications
            cp -R build/rayfast.app $out/Applications/
            runHook postInstall
          '';

          meta = {
            description = "A tiny native macOS launcher";
            homepage = "https://github.com/sykar-f/rayfast";
            license = nixpkgs.lib.licenses.mit;
            platforms = systems;
            mainProgram = "rayfast";
          };
        };
      });

      # Runs rayfast at login, the nix equivalent of `make install`. The
      # store path changes on every update; that costs nothing because global
      # hotkeys go through Carbon's RegisterEventHotKey, which needs no TCC
      # (Accessibility) grant tied to the binary's path.
      homeManagerModules.default = { config, lib, pkgs, ... }:
        let cfg = config.services.rayfast;
        in {
          options.services.rayfast = {
            enable = lib.mkEnableOption "the rayfast launcher, started at login";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "rayfast.packages.\${system}.default";
              description = "The rayfast package to run.";
            };
          };

          config = lib.mkIf cfg.enable {
            launchd.agents.rayfast = {
              enable = true;
              config = {
                ProgramArguments = [ "${cfg.package}/Applications/rayfast.app/Contents/MacOS/rayfast" ];
                RunAtLoad = true;
                # Restart after a crash, not after a clean quit.
                KeepAlive.SuccessfulExit = false;
                ProcessType = "Interactive";
              };
            };
          };
        };
    };
}

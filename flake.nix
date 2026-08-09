{
  description = "Development environment for open-init and its Linux kernel";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          bc
          bison
          binutils
          elfutils
          elfutils.dev
          flex
          gcc
          openssl
          pahole
          perl
          pkg-config
          qemu
        ];

        # The Linux host-tool build invokes gcc directly, so ensure it sees
        # elfutils' split development output even outside a Nix derivation.
        NIX_CFLAGS_COMPILE = "-I${pkgs.elfutils.dev}/include";
        NIX_LDFLAGS = "-L${pkgs.elfutils.out}/lib";
        PKG_CONFIG_PATH = "${pkgs.elfutils.dev}/lib/pkgconfig";
      };
    };
}

let
  fetchNixpkgs = import ./fetchNixpkgs.nix;
in

# version - 18.09

# to update use
# nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/$rev.tar.gz

fetchNixpkgs {
  rev          = "6a3f5bcb061e1822f50e299f5616a0731636e4e7";
  sha256       = "1ib96has10v5nr6bzf7v8kw7yzww8zanxgw2qi1ll1sbv6kj6zpd";
}

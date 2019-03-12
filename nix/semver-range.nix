{ mkDerivation, base, classy-prelude, fetchgit, hspec, parsec
, QuickCheck, stdenv, text, unordered-containers
}:
mkDerivation {
  pname = "semver-range";
  version = "0.2.7";
  src = fetchgit {
    url = "https://github.com/paulyoung/semver-range";
    sha256 = "1qpamipz3yg0n96aja3i1i6hq95vwyyw4jmig1b62faynfijvqnh";
    rev = "bcb807d314f34bf2b8f179843d9264c7a626ab03";
  };
  libraryHaskellDepends = [
    base classy-prelude parsec text unordered-containers
  ];
  testHaskellDepends = [
    base classy-prelude hspec parsec QuickCheck text
    unordered-containers
  ];
  description = "An implementation of semver and semantic version ranges";
  license = stdenv.lib.licenses.mit;
}

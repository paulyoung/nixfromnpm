{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module SemVer where

import ClassyPrelude hiding (try)

type SemVer = (Int, Int, Int)

-- | A partially specified semantic version. Implicitly defines
-- a range of acceptable versions, as seen in @wildcardToRange@.
data Wildcard = Any
              | One Int
              | Two Int Int
              | Three Int Int Int
              deriving (Show, Eq)

data SemVerRange
  = Eq SemVer
  | Gt SemVer
  | Lt SemVer
  | Geq SemVer
  | Leq SemVer
  | And SemVerRange SemVerRange
  | Or SemVerRange SemVerRange
  deriving (Show, Eq)


-- | Returns whether a given semantic version matches a range.
matches :: SemVerRange -> SemVer -> Bool
matches range ver = case range of
  Eq sv -> ver == sv
  Gt sv -> ver > sv
  Lt sv -> ver < sv
  Geq sv -> ver >= sv
  Leq sv -> ver <= sv
  And sv1 sv2 -> matches sv1 ver && matches sv2 ver
  Or sv1 sv2 -> matches sv1 ver || matches sv2 ver

-- | Fills in zeros in a wildcard.
wildcardToSemver :: Wildcard -> SemVer
wildcardToSemver Any = (0, 0, 0)
wildcardToSemver (One n) = (n, 0, 0)
wildcardToSemver (Two n m) = (n, m, 0)
wildcardToSemver (Three n m o) = (n, m, o)


-- | Translates a wildcard (partially specified version) to a range.
-- Ex: 2 := >=2.0.0 <3.0.0
-- Ex: 1.2.x := 1.2 := >=1.2.0 <1.3.0
wildcardToRange :: Wildcard -> SemVerRange
wildcardToRange = \case
  Any -> Geq (0, 0, 0)
  One n -> Geq (n, 0, 0) `And` Lt (n+1, 0, 0)
  Two n m -> Geq (n, m, 0) `And` Lt (n, m + 1, 0)
  Three n m o -> Eq (n, m, o)

-- | Translates a ~wildcard to a range.
-- Ex: ~1.2.3 := >=1.2.3 <1.(2+1).0 := >=1.2.3 <1.3.0
tildeToRange :: Wildcard -> SemVerRange
tildeToRange = \case
  Any -> tildeToRange (Three 0 0 0)
  One n -> tildeToRange (Three n 0 0)
  Two n m -> tildeToRange (Three n m 0)
  Three n m o -> And (Geq (n, m, o)) (Lt (n, m + 1, 0))


-- | Translates a ^wildcard to a range.
-- Ex: ^1.2.x := >=1.2.0 <2.0.0
caratToRange :: Wildcard -> SemVerRange
caratToRange = \case
  One n -> And (Geq (n, 0, 0)) (Lt (n+1, 0, 0))
  Two n m -> And (Geq (n, m, 0)) (Lt (n+1, 0, 0))
  Three 0 0 n -> Eq (0, 0, n)
  Three 0 n m -> And (Geq (0, n, m)) (Lt (0, n + 1, 0))
  Three n m o -> And (Geq (n, m, o)) (Lt (n+1, 0, 0))

-- | Translates two hyphenated wildcards to an actual range.
-- Ex: 1.2.3 - 2.3.4 := >=1.2.3 <=2.3.4
-- Ex: 1.2 - 2.3.4 := >=1.2.0 <=2.3.4
-- Ex: 1.2.3 - 2 := >=1.2.3 <3.0.0
hyphenatedRange :: Wildcard -> Wildcard -> SemVerRange
hyphenatedRange wc1 wc2 = And sv1 sv2 where
  sv1 = case wc1 of Any -> Geq (0, 0, 0)
                    One n -> Geq (n, 0, 0)
                    Two n m -> Geq (n, m, 0)
                    Three n m o -> Geq (n, m, o)
  sv2 = case wc2 of Any -> Geq (0, 0, 0) -- Refers to "any version"
                    One n -> Lt (n+1, 0, 0)
                    Two n m -> Lt (n, m + 1, 0)
                    Three n m o -> Leq (n, m, o)


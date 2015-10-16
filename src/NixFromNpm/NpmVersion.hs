{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
module NixFromNpm.NpmVersion where

import qualified Data.Text as T

import NixFromNpm.Common
import NixFromNpm.SemVer

data GitSource = Github | Bitbucket | Gist | GitLab deriving (Show, Eq)

data NpmVersionRange
  = SemVerRange SemVerRange
  | Tag Name
  | NpmUri URI
  | GitId GitSource Name Name (Maybe Name)
  | LocalPath FilePath
  deriving (Eq)

instance Show NpmVersionRange where
  show (SemVerRange rng) = show rng
  show (Tag name) = unpack name
  show (NpmUri uri) = uriToString uri
  show (GitId Github account repo Nothing) = show $ account <> "/" <> repo
  show (GitId Github account repo (Just hash)) = show $ account <> "/" <> repo
                                                                <> "#" <> hash
  show (GitId src _ _ _) = "git fetch from " <> show src
  show (LocalPath pth) = show pth

showPair :: Name -> SemVer -> Text
showPair name version = name <> "@" <> renderSV version

showRangePair :: Name -> NpmVersionRange -> Text
showRangePair name range = name <> "@" <> pshow range

showDeps :: [(Name, NpmVersionRange)] -> Text
showDeps ranges = mapJoinBy ", " (uncurry showRangePair) ranges

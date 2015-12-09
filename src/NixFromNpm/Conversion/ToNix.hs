{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
module NixFromNpm.Conversion.ToNix where

import qualified Prelude as P
import qualified Data.HashMap.Strict as H
import qualified Data.Map.Strict as M
import Data.Text (Text, replace)

import Data.SemVer

import NixFromNpm.Common hiding (replace)
import Nix.Types hiding (mkPath)
import Nix.Pretty (prettyNix)
import qualified Nix.Types as Nix
import Nix.Parser

import NixFromNpm.Npm.Types
import NixFromNpm.Npm.PackageMap

-- | This contains the same information as the .nix file that corresponds
-- to the package. More or less it tells us everything that we need to build
-- the package.
data ResolvedPkg = ResolvedPkg {
  rpName :: PackageName,
  rpVersion :: SemVer,
  rpDistInfo :: Maybe DistInfo,
  -- ^ If a token was necessary to fetch the package, include it here.
  rpMeta :: PackageMeta,
  rpDependencies :: PRecord ResolvedDependency,
  rpPeerDependencies :: PRecord ResolvedDependency,
  rpOptionalDependencies :: PRecord ResolvedDependency,
  rpDevDependencies :: Maybe (PRecord ResolvedDependency)
  } deriving (Show, Eq)

-- | True if any of the package's dependencies have namespaces.
hasNamespacedDependency :: ResolvedPkg -> Bool
hasNamespacedDependency rPkg = any hasNs (allDeps rPkg) where
  -- Get all of the dependency sets of the package.
  allDeps ResolvedPkg{..} = [rpDependencies, rpPeerDependencies,
                             rpOptionalDependencies,
                             maybe mempty id rpDevDependencies]
  -- Look at all of the package names (keys) to see if any are namespaced.
  hasNs = any isNamespaced . H.keys

-- | Turns a string into one that can be used as an identifier.
-- NPM package names can contain dots, so we translate these into dashes.
fixName :: Name -> Name
fixName = replace "." "-"

-- | Converts a package name and semver into an Nix expression.
-- Example: "foo" and 1.2.3 turns into "foo_1-2-3".
-- Example: "foo.bar" and 1.2.3-baz turns into "foo-bar_1-2-3-baz"
-- Example: "@foo/bar" and 1.2.3 turns into "namespaces.foo.bar_1-2-3"
toDepExpr :: PackageName -> SemVer -> NExpr
toDepExpr (PackageName name mNamespace) (SemVer a b c tags) = do
  let suffix = pack $ intercalate "-" $ (map show [a, b, c]) <> map unpack tags
      ident = fixName name <> "_" <> suffix
  case mNamespace of
    Nothing -> mkSym ident
    Just namespace -> do
      -- Parse out the expression "namespaces.namespace.pkgname"
      unsafeParseNix $ joinBy "." ["namespaces", namespace, ident]

-- | Converts a package name and semver into an Nix selector, which can
-- be used in a binding. This is very similar to @toDepExpr@, but it returns
-- something to be used in a binding rather than an expression.
toSelector :: PackageName -> SemVer -> NSelector NExpr
toSelector (PackageName name mNamespace) (SemVer a b c tags) = do
  let suffix = pack $ intercalate "-" $ (map show [a, b, c]) <> map unpack tags
      ident = fixName name <> "_" <> suffix
  StaticKey <$> case mNamespace of
    Nothing -> [ident]
    Just namespace -> ["namespaces", namespace, ident]

-- | Same as toSelector, but doesn't append a version.
toSelectorNoVersion (PackageName name mNamespace) = do
  StaticKey <$> case mNamespace of
    Nothing -> [fixName name]
    Just namespace -> ["namespaces", namespace, fixName name]


-- | Converts a ResolvedDependency to a nix expression.
toNixExpr :: PackageName -> ResolvedDependency -> NExpr
toNixExpr name (Resolved semver) = toDepExpr name semver
toNixExpr name (Broken reason) = mkApp (mkSym "brokenPackage") $ mkNonRecSet
  ["name" `bindTo` str (pshow name), "reason" `bindTo` str (pshow reason)]

-- | Write a nix expression pretty-printed to a file.
writeNix :: MonadIO io => FilePath -> NExpr -> io ()
writeNix path = writeFile path . (<> "\n") . show . prettyNix

-- | Gets the .nix filename of a semver. E.g. (0, 1, 2) -> 0.1.2.nix
toDotNix :: SemVer -> FilePath
toDotNix v = fromText $ pshow v <> ".nix"

-- | Get the .nix filename relative to the nodePackages folder of a package.
toRelPath :: PackageName -> SemVer -> FilePath
toRelPath (PackageName name mNamespace) version = do
  let subPath = fromText name </> toDotNix version -- E.g. "foo/1.2.3.nix"
  case mNamespace of
    -- Simple case: package 'foo@1.2.3' -> './foo/1.2.3.nix'
    Nothing -> subPath
    -- Namespaced: package '@foo/bar@1.2.3' -> './@foo/bar/1.2.3.nix'
    Just nspace -> fromText ("@" <> nspace) </> subPath

-- | Creates a doublequoted string from some text.
str :: Text -> NExpr
str = mkStr DoubleQuoted

-- | Parse a nix string unsafely (as in, assuming it parses correctly)
unsafeParseNix :: Text -> NExpr
unsafeParseNix source = case parseNixText source of
  Success expr -> expr
  _ -> fatalC ["Expected string '", source, "' to be valid nix."]

-- | Converts distinfo into a nix fetchurl call.
distInfoToNix :: Maybe Name -- `Just` if we are fetching from a namespace.
              -> Maybe DistInfo -> NExpr
distInfoToNix _ Nothing = Nix.mkPath False "./."
distInfoToNix maybeNamespace (Just DistInfo{..}) = do
  let fetchurl = case maybeNamespace of
        Nothing -> unsafeParseNix "pkgs.fetchurl"
        Just _ -> mkSym "fetchUrlWithHeaders"
      (algo, hash) = case diShasum of
        SHA1 hash' -> ("sha1", hash')
        SHA256 hash' -> ("sha256", hash')
      authBinding = case maybeNamespace of
        Nothing -> []
        Just namespace -> do
          let -- Equivalent to "headers.Authorization ="
            binder = NamedVar [StaticKey "headers", StaticKey "Authorization"]
            auth = pshow $ concat ["Bearer ${namespaceTokens.", namespace, "}"]
          [binder $ unsafeParseNix auth]
      bindings =
        ["url" `bindTo` str diUrl, algo `bindTo` str hash]
        <> authBinding
  fetchurl `mkApp` mkNonRecSet bindings

-- | Converts package meta to a nix expression, if it exists.
metaToNix :: PackageMeta -> Maybe NExpr
metaToNix PackageMeta{..} = do
  let
    grab name = maybe [] (\s -> [name `bindTo` str s])
    homepage = grab "homepage" (map uriToText pmHomepage)
    description = grab "description" pmDescription
    author = grab "author" pmAuthor
    keywords = case pmKeywords of
      ks | null ks -> []
         | otherwise -> ["keywords" `bindTo` mkList (toList (map str ks))]
  case homepage <> description <> keywords <> author of
    [] -> Nothing
    bindings -> Just $ mkNonRecSet bindings

-- | Returns true if any of the resolved package's dependencies were broken.
hasBroken :: ResolvedPkg -> Bool
hasBroken ResolvedPkg{..} = case rpDevDependencies of
  Nothing -> any isBroken rpDependencies
  Just devDeps -> any isBroken rpDependencies || any isBroken devDeps
  where isBroken = \case {Broken _ -> True; _ -> False}

-- | Given all of the versions defined in a node packages folder, create a
-- default.nix which defines an object that calls out to all of those files.
--
-- Essentially, given a directory structure like this:
-- > foo/
-- >   0.1.2.nix
-- >   0.2.3.nix
-- > bar/
-- >   1.2.3.nix
-- > @mynamespace/
-- >   qux/
-- >     3.4.5.nix
-- >     default.nix
--
-- We would generate a nix file that looks like this:
--
-- > {callPackage}:
-- >
-- > {
-- >   foo_0-1-2 = callPackage ./foo/0.1.2.nix {};
-- >   foo_0-2-3 = callPackage ./foo/0.2.3.nix {};
-- >   foo = callPackage ./foo/0.2.3.nix {};
-- >   bar_1-2-3 = callPackage ./bar/1.2.3.nix {};
-- >   bar = callPackage ./bar/1.2.3.nix {};
-- >   namespaces' = {
-- >     mynamespace = {
-- >       qux_3-4-5 = callPackage ./@mynamespace/qux/3.4.5.nix {};
-- >       qux = callPackage ./@mynamespace/qux/3.4.5.nix {};
-- >     };
-- >   };
-- > }
--
-- Interestingly, it doesn't matter what the packagemap actually contains. We
-- can derive all of the information we need (names and versions) from the keys
-- of the map.
packageMapToNix :: PackageMap a -> NExpr
packageMapToNix pMap = do
  let
    -- Create a parameter set with no defaults given.
    params = mkFormalSet $ [("callPackage", Nothing)]
    -- Create the function body as a single set which contains all of the
    -- packages in the set as keys, and a callPackage to their paths as values.
    toBindings :: (PackageName, [SemVer]) -> [Binding NExpr]
    toBindings (pkgName, []) = []
    -- Grab the latest version and store that under a selector without a
    -- version.
    toBindings (pkgName, (latest:vs)) = binding : bindings  where
      binding = toSelectorNoVersion pkgName `NamedVar` call latest
      -- Make a path expression relative to the nodePackages folder
      path version = mkPath $ toRelPath pkgName version
      -- Equiv. to `callPackage path {}`
      call v = mkSym "callPackage" `mkApp` path v `mkApp` mkNonRecSet []
      toBinding :: SemVer -> Binding NExpr
      toBinding version = toSelector pkgName version `NamedVar` call version
      bindings :: [Binding NExpr]
      bindings = map toBinding (latest:vs)
    sortedPackages :: [(PackageName, [SemVer])]
    sortedPackages = do
      M.toList $ M.map (map fst . M.toDescList) $ psToMap pMap
    bindings :: [Binding NExpr]
    bindings = concatMap toBindings sortedPackages
  mkFunction params $ mkNonRecSet bindings

-- | Converts a resolved package object into a nix expression. The expresion
-- will be a function where the arguments are its dependencies, and its result
-- is a call to `buildNodePackage`.
resolvedPkgToNix :: ResolvedPkg -> NExpr
resolvedPkgToNix rPkg@ResolvedPkg{..} = mkFunction funcParams body
  where
    -- Get a string representation of each dependency in name-version format.
    deps = map (uncurry toNixExpr) $ H.toList rpDependencies
    peerDeps = map (uncurry toNixExpr) $ H.toList rpPeerDependencies
    optDeps = map (uncurry toNixExpr) $ H.toList rpOptionalDependencies
    -- Same for dev dependencies.
    devDeps = map (uncurry toNixExpr) . H.toList <$> rpDevDependencies
    -- List of arguments that these functions will take.
    funcParams' = catMaybes [
      Just "pkgs",
      Just "buildNodePackage",
      Just "nodePackages",
      -- If the package has any broken dependencies, we will need to include
      -- this function.
      maybeIf (hasBroken rPkg) "brokenPackage",
      -- If the package has a namespace then it will need to set headers
      -- when fetching. So add that function as a dependency.
      maybeIf (isNamespaced rpName) "fetchUrlWithHeaders",
      maybeIf (isNamespaced rpName) "namespaceTokens",
      -- If any of the package's dependencies have namespaces, they will appear
      -- in the `namespaces` set, so we'll need that as a dependency.
      maybeIf (hasNamespacedDependency rPkg) "namespaces"
      ]
    -- None of these have defaults, so put them into pairs with Nothing.
    funcParams = mkFormalSet $ map (\x -> (x, Nothing)) funcParams'
    -- Wrap an list expression in a `with nodePackages;` syntax if non-empty.
    withNodePackages noneIfEmpty list = case list of
      [] -> if noneIfEmpty then Nothing else Just $ mkList []
      _ -> Just $ mkWith (mkSym "nodePackages") $ mkList list
    devDepBinding = case devDeps of
        Nothing -> Nothing
        Just ddeps -> bindTo "devDependencies" <$> withNodePackages False ddeps
    PackageName name namespace = rpName
    args = mkNonRecSet $ catMaybes [
      Just $ "name" `bindTo` str name,
      Just $ "version" `bindTo` (str $ pshow rpVersion),
      Just $ "src" `bindTo` distInfoToNix (pnNamespace rpName) rpDistInfo,
      bindTo "namespace" <$> map str namespace,
      bindTo "deps" <$> withNodePackages False deps,
      bindTo "peerDependencies" <$> withNodePackages True peerDeps,
      bindTo "optionalDependencies" <$> withNodePackages True optDeps,
      devDepBinding,
      bindTo "meta" <$> metaToNix rpMeta
      ]
    body = mkSym "buildNodePackage" `mkApp` args

-- | Convenience function to generate an `import /path {args}` expression.
importWith :: Bool -- ^ True if the path is from the env, e.g. <nixpkgs>
           -> FilePath -- ^ Path to import
           -> [Binding NExpr] -- ^ Arguments to pass
           -> NExpr -- ^ The resulting nix expression
importWith isEnv path args = do
  mkSym "import" `mkApp` Nix.mkPath isEnv (pathToString path)
                 `mkApp` mkNonRecSet args

-- | We use this a few times: `import <nixpkgs> {}`
importNixpkgs :: NExpr
importNixpkgs = importWith True "nixpkgs" []

-- | The default version of nodejs we are using.
defaultNodeJSVersion :: Text
defaultNodeJSVersion = "4.2"

-- | Also used a few times, these are the top-level params to the generated
-- default.nix files.
defaultParams :: Bool -- ^ Whether to use npm3 or not
              -> Formals NExpr
defaultParams npm3 =
  mkFormalSet [("pkgs", Just importNixpkgs),
               ("npm3", Just $ mkBool npm3),
               ("nodejsVersion", Just $ str defaultNodeJSVersion)]

-- | When passing through arguments, we inherit these things.
defaultInherits :: [Binding NExpr]
defaultInherits = [Inherit Nothing $
                   map mkSelector ["pkgs", "npm3", "nodejsVersion"]]

-- | The name of the subfolder within the output directory that
-- contains node packages.
nodePackagesDir :: FilePath
nodePackagesDir = "nodePackages"

bindRootPath :: Binding NExpr
bindRootPath = "nodePackagesPath" `bindTo` mkPath ("./" </> nodePackagesDir)

-- | The root-level default.nix file, which does not have any extensions.
rootDefaultNix :: Bool -> NExpr
rootDefaultNix npm3 = mkFunction (defaultParams npm3) body where
  nodeLibArgs = defaultInherits <> ["self" `bindTo` mkSym "nodeLib"]
  lets = ["nodeLib" `bindTo` importWith False "./nodeLib" nodeLibArgs]
  genPackages = unsafeParseNix "nodeLib.generatePackages"
  body = mkLet lets $ mkApp genPackages (mkNonRecSet [bindRootPath])

-- | Creates the `default.nix` file that is the top-level expression we are
-- generating.
defaultNixExtending :: Name -- ^ Name of first extension.
                    -> Record FilePath -- ^ Extensions being included.
                    -> Bool -- ^ Whether to use npm3
                    -> NExpr -- ^ A generated nix expression.
defaultNixExtending extName extensions npm3 = do
  mkFunction (defaultParams npm3) body where
    -- Map over the expression map, creating a binding for each pair.
    lets = flip map (H.toList extensions) $ \(name, path) -> do
      -- Equiv. to `name = import /path {inherit pkgs nodejsVersion;}`
      name `bindTo` importWith False path defaultInherits
    args = [bindRootPath, "extensions" `bindTo`
              mkList (map mkSym (H.keys extensions))]
    genPkgs = extName <> ".nodeLib.generatePackages"
    generatePackages = unsafeParseNix genPkgs
    body = mkLet lets $ mkApp generatePackages (mkNonRecSet args)

-- | Create a `default.nix` file for a particular package.json; this simply
-- imports the package as defined in the given path, and calls into it.
packageJsonDefaultNix :: FilePath -- ^ Path to the output directory.
                      -> Bool -- ^ Whether to use npm3
                      -> NExpr
packageJsonDefaultNix outputPath npm3 = do
  let
    libBind = "lib" `bindTo` importWith False outputPath defaultInherits
    callPkg = unsafeParseNix "lib.callPackage"
    call = callPkg `mkApp` mkPath "project.nix" `mkApp` mkNonRecSet []
  mkFunction (defaultParams npm3) $ mkLet [libBind] call

bindingsToMap :: [Binding t] -> Record t
bindingsToMap = foldl' step mempty where
  step record binding = case binding of
    NamedVar [StaticKey key] obj -> H.insert key obj record
    _ -> record

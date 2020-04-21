{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Obelisk.Command.Preprocessor where

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Builder as BU
import Data.List (intersperse, isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.Text.Lazy.Builder as TL
import qualified Data.Text.Lazy.Encoding as TL
import Distribution.Compiler (CompilerFlavor (..))
import Language.Haskell.Extension (Extension (..), Language(..))
import System.Directory (canonicalizePath)
import System.IO (IOMode (..), hPutStrLn, stderr, withFile)
import System.FilePath (hasTrailingPathSeparator, joinPath, splitPath)

import Obelisk.Command.Run (CabalPackageInfo (..), parseCabalPackage')

applyPackages :: FilePath -> FilePath -> FilePath -> [FilePath] -> IO ()
applyPackages origPath inPath outPath packagePaths' = withFile outPath WriteMode $ \outFile -> do
  -- This code is intended to be executed via ghci's -pgmF preprocessor option
  -- The command line arguments are passed in via ghc, which dictates the first three options and meanings
  -- In order for this code to execute, origPath must contain either a '.' character or a '/' character.
  -- (This is to avoid the possibility of the command line syntax conflicting with another ob command)
  -- We do have control over the remaining arguments, but they must be the same for all files.
  -- Thus, the fourth command line argument must be "apply-packages",  which has already been handled.
  -- We assume all the remaining arguments passed in are paths to cabal or hpack package specifications.
  -- Thus we must select among the packagePaths for the file we are going to parse.

  origPathCanonical <- canonicalizePath origPath
  packagePaths <- traverse canonicalizePath packagePaths'

  let takeDirs = takeWhile hasTrailingPathSeparator
      packageDirs = sortOn (negate . length . takeDirs) $ map splitPath packagePaths
      origDir = splitPath origPathCanonical
      matches = [ joinPath d | d <- packageDirs, takeDirs d `isPrefixOf` origDir ]

  -- So the first element of matches is going to be the deepest path to a package spec that contains
  -- our file as a subdirectory.

  case matches of
    [] ->
      hPutStrLn stderr $ "Error: Unable to find cabal information for " <> origPath <> "; Skipping preprocessor."
    packagePath:_ -> do
      parseCabalPackage' packagePath >>= \case
        Left err ->
          hPutStrLn stderr $ "Error: Unable to parse cabal package " <> packagePath <> "; Skipping preprocessor on " <> origPath <> ". Error: " <> show err
        Right (_warnings, packageInfo) ->
          hPutTextBuilder outFile (generateHeader origPath packageInfo)

  BL.readFile inPath >>= BL.hPut outFile

  where
    hPutTextBuilder h = BU.hPutBuilder h . TL.encodeUtf8Builder . TL.toLazyText


 -- I'm pretty sure there's a certain amount of oversimplification in CabalPackageInfo, so I doubt this is fully robust.

generateHeader :: FilePath -> CabalPackageInfo -> TL.Builder
generateHeader origPath packageInfo =
    hsExtensions <> ghcOptions <> lineNumberPragma origPath
  where
    hsExtensions =
      if not (null extList)
      then TL.fromText "{-# LANGUAGE "
        <> mconcat (intersperse (TL.fromText ", ") extList)
        <> TL.fromText " #-}\n"
      else mempty
    extList = addDefaultLanguage $ concatMap showExt $ _cabalPackageInfo_defaultExtensions packageInfo
    addDefaultLanguage =
      case _cabalPackageInfo_defaultLanguage packageInfo of
        Nothing -> id
        Just x -> case x of
          UnknownLanguage ext -> ( TL.fromString ext :)
          ext -> ( TL.fromString (show ext) :)
    showExt = \case
      EnableExtension ext -> [TL.fromString (show ext)]
      DisableExtension _ -> []
      UnknownExtension ext -> [TL.fromString ext]

    ghcOptions =
      if not (null optList)
      then TL.fromText "{-# OPTIONS_GHC "
        <> mconcat (intersperse (TL.fromText " ") optList)
        <> TL.fromText " #-}\n"
      else mempty
    optList = map TL.fromString
                $ filter (not . isPrefixOf "-O")
                $ fromMaybe []
                $ lookup GHC (_cabalPackageInfo_compilerOptions packageInfo)

lineNumberPragma :: FilePath -> TL.Builder
lineNumberPragma origPath =
  TL.fromText "{-# LINE 1 \"" <> TL.fromString origPath <> TL.fromText "\" #-}\n"

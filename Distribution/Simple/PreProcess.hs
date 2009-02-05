-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.PreProcess
-- Copyright   :  (c) 2003-2005, Isaac Jones, Malcolm Wallace
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This defines a 'PreProcessor' abstraction which represents a pre-processor
-- that can transform one kind of file into another. There is also a
-- 'PPSuffixHandler' which is a combination of a file extension and a function
-- for configuring a 'PreProcessor'. It defines a bunch of known built-in
-- preprocessors like @cpp@, @cpphs@, @c2hs@, @hsc2hs@, @happy@, @alex@ etc and
-- lists them in 'knownSuffixHandlers'. On top of this it provides a function
-- for actually preprocessing some sources given a bunch of known suffix
-- handlers. This module is not as good as it could be, it could really do with
-- a rewrite to address some of the problems we have with pre-processors.

{- Copyright (c) 2003-2005, Isaac Jones, Malcolm Wallace
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple.PreProcess (preprocessSources, knownSuffixHandlers,
                                ppSuffixes, PPSuffixHandler, PreProcessor(..),
                                mkSimplePreProcessor, runSimplePreProcessor,
                                ppCpp, ppCpp', ppGreenCard, ppC2hs, ppHsc2hs,
                                ppHappy, ppAlex, ppUnlit
                               )
    where


import Distribution.Simple.PreProcess.Unlit (unlit)
import Distribution.Package
         ( Package(..), PackageName(..) )
import Distribution.ModuleName (ModuleName)
import qualified Distribution.ModuleName as ModuleName
import Distribution.PackageDescription as PD
         ( PackageDescription(..), BuildInfo(..), Executable(..), withExe
         , Library(..), withLib, libModules )
import qualified Distribution.InstalledPackageInfo as Installed
         ( InstalledPackageInfo_(..) )
import qualified Distribution.Simple.PackageIndex as PackageIndex
         ( topologicalOrder, lookupPackageName, insert )
import Distribution.Simple.Compiler
         ( CompilerFlavor(..), Compiler(..), compilerFlavor, compilerVersion )
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo(..))
import Distribution.Simple.BuildPaths (autogenModulesDir,cppHeaderName)
import Distribution.Simple.Utils
         ( createDirectoryIfMissingVerbose, withUTF8FileContents, writeUTF8File
         , die, setupMessage, intercalate, copyFileVerbose
         , findFileWithExtension, findFileWithExtension' )
import Distribution.Simple.Program
         ( Program(..), ConfiguredProgram(..), lookupProgram, programPath
         , rawSystemProgramConf, rawSystemProgram
         , greencardProgram, cpphsProgram, hsc2hsProgram, c2hsProgram
         , happyProgram, alexProgram, haddockProgram, ghcProgram, gccProgram )
import Distribution.System
         ( OS(OSX), buildOS )
import Distribution.Version (Version(..))
import Distribution.Verbosity
import Distribution.Text
         ( display )

import Control.Monad (when, unless)
import Data.Maybe (fromMaybe)
import Data.List (nub)
import System.Directory (getModificationTime, doesFileExist)
import System.Info (os, arch)
import System.FilePath (splitExtension, dropExtensions, (</>), (<.>),
                        takeDirectory, normalise, replaceExtension)

-- |The interface to a preprocessor, which may be implemented using an
-- external program, but need not be.  The arguments are the name of
-- the input file, the name of the output file and a verbosity level.
-- Here is a simple example that merely prepends a comment to the given
-- source file:
--
-- > ppTestHandler :: PreProcessor
-- > ppTestHandler =
-- >   PreProcessor {
-- >     platformIndependent = True,
-- >     runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbosity ->
-- >       do info verbosity (inFile++" has been preprocessed to "++outFile)
-- >          stuff <- readFile inFile
-- >          writeFile outFile ("-- preprocessed as a test\n\n" ++ stuff)
-- >          return ExitSuccess
--
-- We split the input and output file names into a base directory and the
-- rest of the file name. The input base dir is the path in the list of search
-- dirs that this file was found in. The output base dir is the build dir where
-- all the generated source files are put.
--
-- The reason for splitting it up this way is that some pre-processors don't
-- simply generate one output .hs file from one input file but have
-- dependencies on other genereated files (notably c2hs, where building one
-- .hs file may require reading other .chi files, and then compiling the .hs
-- file may require reading a generated .h file). In these cases the generated
-- files need to embed relative path names to each other (eg the generated .hs
-- file mentions the .h file in the FFI imports). This path must be relative to
-- the base directory where the genereated files are located, it cannot be
-- relative to the top level of the build tree because the compilers do not
-- look for .h files relative to there, ie we do not use \"-I .\", instead we
-- use \"-I dist\/build\" (or whatever dist dir has been set by the user)
--
-- Most pre-processors do not care of course, so mkSimplePreProcessor and
-- runSimplePreProcessor functions handle the simple case.
--
data PreProcessor = PreProcessor {

  -- Is the output of the pre-processor platform independent? eg happy output
  -- is portable haskell but c2hs's output is platform dependent.
  -- This matters since only platform independent generated code can be
  -- inlcuded into a source tarball.
  platformIndependent :: Bool,

  -- TODO: deal with pre-processors that have implementaion dependent output
  --       eg alex and happy have --ghc flags. However we can't really inlcude
  --       ghc-specific code into supposedly portable source tarballs.

  runPreProcessor :: (FilePath, FilePath) -- Location of the source file relative to a base dir
                  -> (FilePath, FilePath) -- Output file name, relative to an output base dir
                  -> Verbosity -- verbosity
                  -> IO ()     -- Should exit if the preprocessor fails
  }

mkSimplePreProcessor :: (FilePath -> FilePath -> Verbosity -> IO ())
                      -> (FilePath, FilePath)
                      -> (FilePath, FilePath) -> Verbosity -> IO ()
mkSimplePreProcessor simplePP
  (inBaseDir, inRelativeFile)
  (outBaseDir, outRelativeFile) verbosity = simplePP inFile outFile verbosity
  where inFile  = normalise (inBaseDir  </> inRelativeFile)
        outFile = normalise (outBaseDir </> outRelativeFile)

runSimplePreProcessor :: PreProcessor -> FilePath -> FilePath -> Verbosity
                      -> IO ()
runSimplePreProcessor pp inFile outFile verbosity =
  runPreProcessor pp (".", inFile) (".", outFile) verbosity

-- |A preprocessor for turning non-Haskell files with the given extension
-- into plain Haskell source files.
type PPSuffixHandler
    = (String, BuildInfo -> LocalBuildInfo -> PreProcessor)

-- |Apply preprocessors to the sources from 'hsSourceDirs', to obtain
-- a Haskell source file for each module.
preprocessSources :: PackageDescription
                  -> LocalBuildInfo
                  -> Bool               -- ^ Build for SDist
                  -> Verbosity          -- ^ verbosity
                  -> [PPSuffixHandler]  -- ^ preprocessors to try
                  -> IO ()

preprocessSources pkg_descr lbi forSDist verbosity handlers = do
    withLib pkg_descr () $ \ lib -> do
        setupMessage verbosity "Preprocessing library" (packageId pkg_descr)
        let bi = libBuildInfo lib
        let biHandlers = localHandlers bi
        sequence_ [ preprocessModule (hsSourceDirs bi ++ [autogenModulesDir lbi]) (buildDir lbi) forSDist
                                     modu verbosity builtinSuffixes biHandlers
                  | modu <- libModules pkg_descr]
    unless (null (executables pkg_descr)) $
        setupMessage verbosity "Preprocessing executables for" (packageId pkg_descr)
    withExe pkg_descr $ \ theExe -> do
        let bi = buildInfo theExe
        let biHandlers = localHandlers bi
        let exeDir = buildDir lbi </> exeName theExe </> exeName theExe ++ "-tmp"
        sequence_ [ preprocessModule (hsSourceDirs bi ++ [autogenModulesDir lbi]) exeDir forSDist
                                     modu verbosity builtinSuffixes biHandlers
                  | modu <- otherModules bi]
        preprocessModule (hsSourceDirs bi) exeDir forSDist
                          --FIXME: we should not pretend it's a module name:
                         (ModuleName.simple (dropExtensions (modulePath theExe)))
                         verbosity builtinSuffixes biHandlers
  where hc = compilerFlavor (compiler lbi)
        builtinSuffixes
          | hc == NHC = ["hs", "lhs", "gc"]
          | otherwise = ["hs", "lhs"]
        localHandlers bi = [(ext, h bi lbi) | (ext, h) <- handlers]

-- |Find the first extension of the file that exists, and preprocess it
-- if required.
preprocessModule
    :: [FilePath]               -- ^source directories
    -> FilePath                 -- ^build directory
    -> Bool                     -- ^preprocess for sdist
    -> ModuleName               -- ^module name
    -> Verbosity                -- ^verbosity
    -> [String]                 -- ^builtin suffixes
    -> [(String, PreProcessor)] -- ^possible preprocessors
    -> IO ()
preprocessModule searchLoc buildLoc forSDist modu verbosity builtinSuffixes handlers = do
    -- look for files in the various source dirs with this module name
    -- and a file extension of a known preprocessor
    psrcFiles <- findFileWithExtension' (map fst handlers) searchLoc
                   (ModuleName.toFilePath modu)
    case psrcFiles of
        -- no preprocessor file exists, look for an ordinary source file
      Nothing -> do
                 bsrcFiles <- findFileWithExtension builtinSuffixes searchLoc
                                (ModuleName.toFilePath modu)
                 case bsrcFiles of
                  Nothing -> die $ "can't find source for " ++ display modu
                                ++ " in " ++ intercalate ", " searchLoc
                  _       -> return ()
        -- found a pre-processable file in one of the source dirs
      Just (psrcLoc, psrcRelFile) -> do
            let (srcStem, ext) = splitExtension psrcRelFile
                psrcFile = psrcLoc </> psrcRelFile
                pp = fromMaybe (error "Internal error in preProcess module: Just expected")
                               (lookup (tailNotNull ext) handlers)
            -- Preprocessing files for 'sdist' is different from preprocessing
            -- for 'build'.  When preprocessing for sdist we preprocess to
            -- avoid that the user has to have the preprocessors available.
            -- ATM, we don't have a way to specify which files are to be
            -- preprocessed and which not, so for sdist we only process
            -- platform independent files and put them into the 'buildLoc'
            -- (which we assume is set to the temp. directory that will become
            -- the tarball).
            when (not forSDist || forSDist && platformIndependent pp) $ do
              -- look for existing pre-processed source file in the dest dir to
              -- see if we really have to re-run the preprocessor.
              ppsrcFiles <- findFileWithExtension builtinSuffixes [buildLoc]
                              (ModuleName.toFilePath modu)
              recomp <- case ppsrcFiles of
                          Nothing -> return True
                          Just ppsrcFile -> do
                              btime <- getModificationTime ppsrcFile
                              ptime <- getModificationTime psrcFile
                              return (btime < ptime)
              when recomp $ do
                let destDir = buildLoc </> dirName srcStem
                createDirectoryIfMissingVerbose verbosity True destDir
                runPreProcessor pp
                   (psrcLoc, psrcRelFile)
                   (buildLoc, srcStem <.> "hs") verbosity

      where dirName = takeDirectory
            tailNotNull [] = []
            tailNotNull x  = tail x

-- ------------------------------------------------------------
-- * known preprocessors
-- ------------------------------------------------------------

ppGreenCard :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppGreenCard _ lbi
    = PreProcessor {
        platformIndependent = False,
        runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbosity ->
          rawSystemProgramConf verbosity greencardProgram (withPrograms lbi)
              (["-tffi", "-o" ++ outFile, inFile])
      }

-- This one is useful for preprocessors that can't handle literate source.
-- We also need a way to chain preprocessors.
ppUnlit :: PreProcessor
ppUnlit =
  PreProcessor {
    platformIndependent = True,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile _verbosity ->
      withUTF8FileContents inFile $ \contents ->
        either (writeUTF8File outFile) die (unlit inFile contents)
  }

ppCpp :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppCpp = ppCpp' []

ppCpp' :: [String] -> BuildInfo -> LocalBuildInfo -> PreProcessor
ppCpp' extraArgs bi lbi =
  case compilerFlavor (compiler lbi) of
    GHC -> ppGhcCpp (cppArgs ++ extraArgs) bi lbi
    _   -> ppCpphs  (cppArgs ++ extraArgs) bi lbi

  where cppArgs = sysDefines ++ cppOptions bi ++ getCppOptions bi lbi
        sysDefines =
                ["-D" ++ os ++ "_" ++ loc ++ "_OS" | loc <- locations] ++
                ["-D" ++ arch ++ "_" ++ loc ++ "_ARCH" | loc <- locations]
        locations = ["BUILD", "HOST"]

ppGhcCpp :: [String] -> BuildInfo -> LocalBuildInfo -> PreProcessor
ppGhcCpp extraArgs _bi lbi =
  PreProcessor {
    platformIndependent = False,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbosity ->
      rawSystemProgram verbosity ghcProg $
          ["-E", "-cpp"]
          -- This is a bit of an ugly hack. We're going to
          -- unlit the file ourselves later on if appropriate,
          -- so we need GHC not to unlit it now or it'll get
          -- double-unlitted. In the future we might switch to
          -- using cpphs --unlit instead.
       ++ (if ghcVersion >= Version [6,6] [] then ["-x", "hs"] else [])
       ++ (if use_optP_P lbi then ["-optP-P"] else [])
       ++ [ "-optP-include", "-optP"++ (autogenModulesDir lbi </> cppHeaderName) ]
       ++ ["-o", outFile, inFile]
       ++ extraArgs
  }
  where Just ghcProg = lookupProgram ghcProgram (withPrograms lbi)
        Just ghcVersion = programVersion ghcProg

ppCpphs :: [String] -> BuildInfo -> LocalBuildInfo -> PreProcessor
ppCpphs extraArgs _bi lbi =
  PreProcessor {
    platformIndependent = False,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbosity ->
      rawSystemProgram verbosity cpphsProg $
          ("-O" ++ outFile) : inFile
        : "--noline" : "--strip"
        : (if cpphsVersion >= Version [1,6] []
             then ["--include="++ (autogenModulesDir lbi </> cppHeaderName)]
             else [])
        ++ extraArgs
  }
  where Just cpphsProg = lookupProgram cpphsProgram (withPrograms lbi)
        Just cpphsVersion = programVersion cpphsProg

-- Haddock versions before 0.8 choke on #line and #file pragmas.  Those
-- pragmas are necessary for correct links when we preprocess.  So use
-- -optP-P only if the Haddock version is prior to 0.8.
use_optP_P :: LocalBuildInfo -> Bool
use_optP_P lbi
 = case lookupProgram haddockProgram (withPrograms lbi) of
     Just (ConfiguredProgram { programVersion = Just version })
       | version >= Version [0,8] [] -> False
     _                               -> True

ppHsc2hs :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppHsc2hs bi lbi = standardPP lbi hsc2hsProgram $
    [ "--cc=" ++ programPath gccProg
    , "--ld=" ++ programPath gccProg ]

    -- Additional gcc options
 ++ [ "--cflag=" ++ opt | opt <- programArgs gccProg ]
 ++ [ "--lflag=" ++ opt | opt <- programArgs gccProg ]

    -- OSX frameworks:
 ++ [ what ++ "=-F" ++ opt
    | isOSX
    , opt <- nub (concatMap Installed.frameworkDirs pkgs)
    , what <- ["--cflag", "--lflag"] ]
 ++ [ "--lflag=" ++ arg
    | isOSX
    , opt <- PD.frameworks bi ++ concatMap Installed.frameworks pkgs
    , arg <- ["-framework", opt] ]

    -- Options from the current package:
 ++ [ "--cflag="   ++ opt | opt <- hcDefines (compiler lbi) ]
 ++ [ "--cflag=-I" ++ dir | dir <- PD.includeDirs  bi ]
 ++ [ "--cflag="   ++ opt | opt <- PD.ccOptions    bi
                                ++ PD.cppOptions   bi ]
 ++ [ "--lflag="   ++ opt | opt <-    getLdOptions bi ]

    -- Options from dependent packages
 ++ [ "--cflag=" ++ opt
    | pkg <- pkgs
    , opt <- [ "-I" ++ opt | opt <- Installed.includeDirs pkg ]
          ++ [         opt | opt <- Installed.ccOptions   pkg ] ]
 ++ [ "--lflag=" ++ opt
    | pkg <- pkgs
    , opt <- [ "-L" ++ opt | opt <- Installed.libraryDirs    pkg ]
          ++ [ "-l" ++ opt | opt <- Installed.extraLibraries pkg ]
          ++ [         opt | opt <- Installed.ldOptions      pkg ] ]
  where
    pkgs = PackageIndex.topologicalOrder (packageHacks (installedPkgs lbi))
    Just gccProg = lookupProgram  gccProgram (withPrograms lbi)
    isOSX = case buildOS of OSX -> True; _ -> False
    packageHacks = case compilerFlavor (compiler lbi) of
      GHC -> hackRtsPackage
      _   -> id
    -- We don't link in the actual Haskell libraries of our dependencies, so
    -- the -u flags in the ldOptions of the rts package mean linking fails on
    -- OS X (it's ld is a tad stricter than gnu ld). Thus we remove the
    -- ldOptions for GHC's rts package:
    hackRtsPackage index =
      case PackageIndex.lookupPackageName index (PackageName "rts") of
        [rts] -> PackageIndex.insert rts { Installed.ldOptions = [] } index
        _ -> error "No (or multiple) ghc rts package is registered!!"

getLdOptions :: BuildInfo -> [String]
getLdOptions bi = map ("-L" ++) (extraLibDirs bi)
               ++ map ("-l" ++) (extraLibs bi)
               ++ PD.ldOptions bi

ppC2hs :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppC2hs bi lbi
    = PreProcessor {
        platformIndependent = False,
        runPreProcessor = \(inBaseDir, inRelativeFile)
                           (outBaseDir, outRelativeFile) verbosity ->
          rawSystemProgramConf verbosity c2hsProgram (withPrograms lbi) $
               ["--include=" ++ outBaseDir]
            ++ ["--cppopts=" ++ opt | opt <- getCppOptions bi lbi]
            ++ ["--output-dir=" ++ outBaseDir,
                "--output=" ++ outRelativeFile,
                inBaseDir </> inRelativeFile]
      }

getCppOptions :: BuildInfo -> LocalBuildInfo -> [String]
getCppOptions bi lbi
    = hcDefines (compiler lbi)
   ++ ["-I" ++ dir | dir <- PD.includeDirs bi]
   ++ [opt | opt@('-':c:_) <- PD.ccOptions bi, c `elem` "DIU"]

hcDefines :: Compiler -> [String]
hcDefines comp =
  case compilerFlavor comp of
    GHC  -> ["-D__GLASGOW_HASKELL__=" ++ versionInt version]
    JHC  -> ["-D__JHC__=" ++ versionInt version]
    NHC  -> ["-D__NHC__=" ++ versionInt version]
    Hugs -> ["-D__HUGS__"]
    _    -> []
  where version = compilerVersion comp

-- TODO: move this into the compiler abstraction
-- FIXME: this forces GHC's crazy 4.8.2 -> 408 convention on all the other
-- compilers. Check if that's really what they want.
versionInt :: Version -> String
versionInt (Version { versionBranch = [] }) = "1"
versionInt (Version { versionBranch = [n] }) = show n
versionInt (Version { versionBranch = n1:n2:_ })
  = -- 6.8.x -> 608
    -- 6.10.x -> 610
    let s1 = show n1
        s2 = show n2
        middle = case s2 of
                 _ : _ : _ -> ""
                 _         -> "0"
    in s1 ++ middle ++ s2

ppHappy :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppHappy _ lbi = pp { platformIndependent = True }
  where pp = standardPP lbi happyProgram (hcFlags hc)
        hc = compilerFlavor (compiler lbi)
        hcFlags GHC = ["-agc"]
        hcFlags _ = []

ppAlex :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppAlex _ lbi = pp { platformIndependent = True }
  where pp = standardPP lbi alexProgram (hcFlags hc)
        hc = compilerFlavor (compiler lbi)
        hcFlags GHC = ["-g"]
        hcFlags _ = []

standardPP :: LocalBuildInfo -> Program -> [String] -> PreProcessor
standardPP lbi prog args =
  PreProcessor {
    platformIndependent = False,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbosity ->
      do rawSystemProgramConf verbosity prog (withPrograms lbi)
                              (args ++ ["-o", outFile, inFile])
         -- XXX This is a nasty hack. GHC requires that hs-boot files
         -- be in the same place as the hs files, so if we put the hs
         -- file in dist/... then we need to copy the hs-boot file
         -- there too. This should probably be done another way, e.g.
         -- by preprocessing all files, with and "id" preprocessor if
         -- nothing else, so the hs-boot files automatically get copied
         -- into the right place.
         -- Possibly we should also be looking for .lhs-boot files, but
         -- I think that preprocessors only produce .hs files.
         let inBoot  = replaceExtension inFile  "hs-boot"
             outBoot = replaceExtension outFile "hs-boot"
         exists <- doesFileExist inBoot
         when exists $ copyFileVerbose verbosity inBoot outBoot
  }

-- |Convenience function; get the suffixes of these preprocessors.
ppSuffixes :: [ PPSuffixHandler ] -> [String]
ppSuffixes = map fst

-- |Standard preprocessors: GreenCard, c2hs, hsc2hs, happy, alex and cpphs.
knownSuffixHandlers :: [ PPSuffixHandler ]
knownSuffixHandlers =
  [ ("gc",     ppGreenCard)
  , ("chs",    ppC2hs)
  , ("hsc",    ppHsc2hs)
  , ("x",      ppAlex)
  , ("y",      ppHappy)
  , ("ly",     ppHappy)
  , ("cpphs",  ppCpp)
  ]
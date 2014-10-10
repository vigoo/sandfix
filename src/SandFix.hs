import Control.Applicative ((<$>))
import Control.Monad (filterM, forM, mplus, when, forM_)
import Data.List (isSuffixOf)
import qualified Data.Map as Map
import Data.Maybe (isNothing, listToMaybe, maybeToList)
import Data.Monoid
import qualified Data.Set as Set
import Distribution.InstalledPackageInfo as I
import Distribution.Package
import Distribution.Simple.Compiler
import Distribution.Simple.GHC
import Distribution.Simple.PackageIndex
import Distribution.Simple.Program
import Distribution.Text
import Distribution.Verbosity
import System.Directory
import System.Environment
import System.Exit
import System.IO

_VERBOSITY :: Verbosity
_VERBOSITY = normal

printUsage :: IO ()
printUsage = do
  prog <- getProgName
  hPutStrLn stderr $ "Usage: " ++ prog ++ " SANDBOX_PATH"

getReadPackageDB :: IO (PackageDB -> IO PackageIndex)
getReadPackageDB = do
  progConfig <- configureAllKnownPrograms _VERBOSITY $ addKnownProgram ghcProgram defaultProgramConfiguration
  return $ \pkgdb -> getPackageDBContents _VERBOSITY pkgdb progConfig

type Fix = Either String

packageIdFromInstalledPackageId :: InstalledPackageId -> Fix PackageId
packageIdFromInstalledPackageId (InstalledPackageId str) = case simpleParse $ take (length str - 33) str of
  Nothing -> Left $ "Failed to parse installed package id " ++ str
  Just pid -> return pid

fixPackageIndex :: PackageIndex -> RPT -> PackageIndex -> Fix PackageIndex
fixPackageIndex globalPkgIndex sandboxRPT brokenPackageIndex
  = fromList <$> mapM fixInstalledPackage (allPackages brokenPackageIndex)
  where
    fixInstalledPackage info
      = do
      -- 1. Fix dependencies
      fixedDependencies <- forM (I.depends info) $ \ipkgid -> do
        pkgid <- packageIdFromInstalledPackageId ipkgid
        case lookupInstalledPackageId brokenPackageIndex ipkgid `mplus`
             listToMaybe (lookupSourcePackageId globalPkgIndex pkgid)
          of
          Just fInfo -> return $ installedPackageId fInfo
          Nothing -> Left $ "Could not find package " ++ display pkgid ++ " in either the sandbox or global DB. As a last resort try cabal installing it explicitly(this specific version) into the global DB with --global"

      -- 2. Fix the global paths
      let 
        findOneOrFail path = case findPartialPathMatches path sandboxRPT of
          [] -> Left $ "Could not find sandbox path of " ++ path
          [a] -> return a
          ps -> Left $ "Multiple possible sandbox paths of " ++ path ++ ": " ++ show ps
        findFirstOrRoot path = case findPartialPathMatches path sandboxRPT of
          [] -> "/"
          (a : _) -> a
      fixedImportDirs <- mapM findOneOrFail $ importDirs info
      fixedLibDirs <- mapM findOneOrFail $ libraryDirs info
      fixedIncludeDirs <- mapM findOneOrFail $ includeDirs info
      let fixedFrameworkDirs = findFirstOrRoot <$> frameworkDirs info
          fixedHaddockIfaces = findFirstOrRoot <$> haddockInterfaces info
          fixedHaddockHTMLs =  findFirstOrRoot <$> haddockHTMLs info
      return info
        { I.depends = fixedDependencies
        , importDirs = fixedImportDirs
        , libraryDirs = fixedLibDirs
        , includeDirs = fixedIncludeDirs
        , frameworkDirs = fixedFrameworkDirs
        , haddockInterfaces = fixedHaddockIfaces
        , haddockHTMLs = fixedHaddockHTMLs
        }

main :: IO ()
main = do
  argv <- getArgs
  when (length argv /= 1) $ do
    printUsage
    exitFailure
  let sandboxPath = head argv
  brokenDBPaths <- map (\p -> sandboxPath <> "/" <> p) . filter (isSuffixOf ".conf.d") <$> getDirectoryContents sandboxPath
  when (null brokenDBPaths) $ do
    hPutStrLn stderr $ "Unable to find sandbox package database in " ++ sandboxPath
    exitFailure
  -- print comp
  readPkgDB <- getReadPackageDB
  putStr "Reading sandbox Package DB... "
  brokenPackageDBs <- mapM (readPkgDB . SpecificPackageDB) brokenDBPaths
  putStrLn "done"
  putStr "Reading global Package DB... "
  globalPackageDB <- readPkgDB GlobalPackageDB
  putStrLn "done"
  putStr "Constructing path tree of sandbox... "
  sandboxRPT <- fromDirRecursively sandboxPath
  putStrLn "done"
  putStr "Fixing sandbox package DB... "
  case mapM (fixPackageIndex globalPackageDB sandboxRPT) brokenPackageDBs of
    Left err -> hPutStrLn stderr err >> exitFailure
    Right fixedPackageDBs -> do
      putStrLn "done"
      putStr "Overwriting broken package DB... "
      forM_ (zip brokenDBPaths fixedPackageDBs) $ \(path, db) -> forM_ (allPackages db) $ \info -> do
        let filename = path <> "/" <> display (installedPackageId info) <> ".conf"
        writeFile filename $ showInstalledPackageInfo info
      putStrLn "done"
      putStrLn "Please run 'cabal sandbox hc-pkg recache' in the sandbox to update the package cache"

-- Reverse Path Tree
data RPT
  = RPT
    { rptPath :: Maybe FilePath
    , rptChildren :: Map.Map String RPT
    }
  deriving Show

instance Monoid RPT where
  mempty = RPT Nothing Map.empty
  RPT p0 cs0 `mappend` RPT p1 cs1 = RPT (p0 <> p1) (Map.unionWith (<>) cs0 cs1)

insertFilePath :: FilePath -> RPT -> RPT
insertFilePath filepath = insertFilePath' (reverseSplitFilePath filepath) filepath
  where
    insertFilePath' [] path rpt
      = rpt { rptPath = Just path }
    insertFilePath' (a : as) path rpt
      = rpt { rptChildren = Map.insertWith (<>) a (fromParts as path) $ rptChildren rpt }

    fromParts [] path = mempty { rptPath = Just path }
    fromParts (a : as) path = mempty { rptChildren = Map.singleton a $ fromParts as path }

fromFilePaths :: [FilePath] -> RPT
fromFilePaths = foldr insertFilePath mempty

fromDirRecursively :: FilePath -> IO RPT
fromDirRecursively = fromDirRecursively' Set.empty
  where
    fromDirRecursively' visited somePath = fromDirRecursively'' visited =<< canonicalizePath somePath
    fromDirRecursively'' visited path
      | path `Set.member` visited = return mempty
      | otherwise = do
        let isSub "." = False
            isSub ".." = False
            isSub _ = True
        allSubs <- map (\p -> path <> "/" <> p) . filter isSub <$> getDirectoryContents path
        subDirs <- filterM doesDirectoryExist allSubs
        subRPT <- mconcat <$> mapM (fromDirRecursively' $ Set.insert path visited) subDirs
        return $ fromFilePaths allSubs <> subRPT

reverseSplitFilePath :: FilePath -> [String]
reverseSplitFilePath filepath = reverseSplitFilePath' filepath []
  where
    reverseSplitFilePath' "" ps = ps
    reverseSplitFilePath' path ps = case span (/= '/') path of
      ("", '/' : rest) -> reverseSplitFilePath' rest ps
      (p, rest) -> reverseSplitFilePath' rest (p : ps)

findPartialPathMatches :: FilePath -> RPT -> [FilePath]
findPartialPathMatches filepath r
  | (p : _) <- parts, isNothing . Map.lookup p $ rptChildren r = []
  | otherwise = findPartialPathMatches' parts r
  where
    parts = reverseSplitFilePath filepath

    findPartialPathMatches' [] rpt = collectPaths rpt
    findPartialPathMatches' (a : as) rpt
      | Just rpt' <- Map.lookup a (rptChildren rpt) = findPartialPathMatches' as rpt'
      | otherwise                                  = collectPaths rpt

    collectPaths rpt = maybeToList (rptPath rpt) ++ (collectPaths =<< Map.elems (rptChildren rpt))
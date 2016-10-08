{-# LANGUAGE FlexibleInstances #-}

module HsDev.Scan (
	-- * Enumerate functions
	CompileFlag, ModuleToScan, ProjectToScan, PackageDbToScan, ScanContents(..),
	EnumContents(..),
	enumRescan, enumDependent, enumProject, enumSandbox, enumDirectory,

	-- * Scan
	scanProjectFile,
	scanModule, scanModify, upToDate, rescanModule, changedModule, changedModules,

	-- * Reexportss
	module HsDev.Database,
	module HsDev.Symbols.Types,
	module Control.Monad.Except,
	) where

import Control.DeepSeq
import Control.Lens hiding ((%=))
import Control.Monad.Except
import Data.Async
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe)
import Data.List (intercalate)
import System.Directory
import Text.Format

import HsDev.Error
import HsDev.Scan.Browse (browsePackages, browseModules)
import HsDev.Server.Types (FileSource(..), Session(..), askSession, CommandMonad(..))
import HsDev.Sandbox
import HsDev.Symbols
import HsDev.Symbols.Resolve
import HsDev.Symbols.Types
import HsDev.Symbols.Util (inFile)
import HsDev.Database
import HsDev.Display
import HsDev.Inspect
import HsDev.Util

-- | Compile flags
type CompileFlag = String
-- | Module with flags ready to scan
type ModuleToScan = (ModuleLocation, [CompileFlag], Maybe String)
-- | Project ready to scan
type ProjectToScan = (Project, [ModuleToScan])
-- | Package-db sandbox to scan (top of stack)
type PackageDbToScan = PackageDbStack

-- | Scan info
data ScanContents = ScanContents {
	modulesToScan :: [ModuleToScan],
	projectsToScan :: [ProjectToScan],
	sandboxesToScan :: [PackageDbStack] }

instance NFData ScanContents where
	rnf (ScanContents ms ps ss) = rnf ms `seq` rnf ps `seq` rnf ss

instance Monoid ScanContents where
	mempty = ScanContents [] [] []
	mappend (ScanContents lm lp ls) (ScanContents rm rp rs) = ScanContents
		(uniqueBy (view _1) $ lm ++ rm)
		(uniqueBy (view _1) $ lp ++ rp)
		(ordNub $ ls ++ rs)

instance FormatBuild ScanContents where
	formatBuild (ScanContents ms ps cs) = formatBuild str where
		str :: String
		str = format "modules: {}, projects: {}, package-dbs: {}"
			~~ (intercalate ", " $ ms ^.. each . _1 . moduleFile)
			~~ (intercalate ", " $ ps ^.. each . _1 . projectPath)
			~~ (intercalate ", " $ map (display . topPackageDb) $ cs ^.. each)

class EnumContents a where
	enumContents :: CommandMonad m => a -> m ScanContents

instance EnumContents ModuleLocation where
	enumContents mloc = return $ ScanContents [(mloc, [], Nothing)] [] []

instance EnumContents (Extensions ModuleLocation) where
	enumContents ex = return $ ScanContents [(view entity ex, extensionsOpts ex, Nothing)] [] []

instance EnumContents Project where
	enumContents = enumProject

instance EnumContents PackageDbStack where
	enumContents pdbs = return $ ScanContents [] [] (packageDbStacks pdbs)

instance EnumContents Sandbox where
	enumContents = enumSandbox

instance {-# OVERLAPPABLE #-} EnumContents a => EnumContents [a] where
	enumContents = liftM mconcat . tries . map enumContents

instance {-# OVERLAPPING #-} EnumContents FilePath where
	enumContents f
		| haskellSource f = hsdevLiftIO $ do
			mproj <- liftIO $ locateProject f
			case mproj of
				Nothing -> enumContents $ FileModule f Nothing
				Just proj -> do
					ScanContents _ [(_, mods)] _ <- enumContents proj
					return $ ScanContents (filter ((== Just f) . preview (_1 . moduleFile)) mods) [] []
		| otherwise = enumDirectory f

instance EnumContents FileSource where
	enumContents (FileSource f mcts)
		| haskellSource f = do
			ScanContents [(m, opts, _)] _ _ <- enumContents f
			return $ ScanContents [(m, opts, mcts)] [] []
		| otherwise = return mempty

-- | Enum rescannable (i.e. already scanned) file
enumRescan :: CommandMonad m => FilePath -> m ScanContents
enumRescan fpath = do
	dbval <- askSession sessionDatabase >>= liftIO . readAsync
	let
		mloc = dbval ^? modules . filtered (inFile fpath) . moduleId . moduleLocation
	return $ fromMaybe mempty $ do
		loc <- mloc
		return $ ScanContents [(loc, dbval ^.. databaseModules . ix loc . inspection . inspectionOpts . each, Nothing)] [] []

-- | Enum file dependent
enumDependent :: CommandMonad m => FilePath -> m ScanContents
enumDependent fpath = do
	dbval <- askSession sessionDatabase >>= liftIO . readAsync
	let
		rdeps = sourceRDeps (dbval ^. fileDepsSlice fpath)
		dependent = fromMaybe [] $ rdeps ^? ix fpath
	liftM mconcat $ mapM enumRescan dependent

-- | Enum project sources
enumProject :: CommandMonad m => Project -> m ScanContents
enumProject p = hsdevLiftIO $ do
	p' <- liftIO $ loadProject p
	pdbs <- searchPackageDbStack (view projectPath p')
	pkgs <- liftM (map $ view (package . packageName)) $ browsePackages [] pdbs
	let
		projOpts :: FilePath -> [String]
		projOpts f = concatMap makeOpts $ fileTargets p' f where
			makeOpts :: Info -> [String]
			makeOpts i = concat [
				["-hide-all-packages"],
				["-package " ++ view projectName p'],
				["-package " ++ dep | dep <- view infoDepends i, dep `elem` pkgs]]
	srcs <- liftIO $ projectSources p'
	let
		mlocs = over each (\src -> over ghcOptions (++ projOpts (view entity src)) . over entity (\f -> FileModule f (Just p')) $ src) srcs
	mods <- liftM modulesToScan $ enumContents mlocs
	return $ ScanContents [] [(p', mods)] [] -- (sandboxCabals sboxes)

-- | Enum sandbox
enumSandbox :: CommandMonad m => Sandbox -> m ScanContents
enumSandbox = sandboxPackageDbStack >=> enumContents

-- | Enum directory modules
enumDirectory :: CommandMonad m => FilePath -> m ScanContents
enumDirectory dir = hsdevLiftIO $ do
	cts <- liftIO $ traverseDirectory dir
	let
		projects = filter cabalFile cts
		sources = filter haskellSource cts
	dirs <- liftIO $ filterM doesDirectoryExist cts
	sboxes <- liftM catMaybes $ triesMap (liftIO . findSandbox) dirs
	pdbs <- mapM enumSandbox sboxes
	projs <- liftM mconcat $ triesMap (enumProject . project) projects
	let
		projPaths = map (view projectPath . fst) $ projectsToScan projs
		standalone = map (`FileModule` Nothing) $ filter (\s -> not (any (`isParent` s) projPaths)) sources
	return $ mconcat [
		ScanContents [(s, [], Nothing) | s <- standalone] [] [],
		projs,
		mconcat pdbs]

-- | Scan project file
scanProjectFile :: CommandMonad m => [String] -> FilePath -> m Project
scanProjectFile _ f = hsdevLiftIO $ do
	proj <- (liftIO $ locateProject f) >>= maybe (hsdevError $ FileNotFound f) return
	liftIO $ loadProject proj

-- | Scan module
scanModule :: CommandMonad m => [(String, String)] -> [String] -> ModuleLocation -> Maybe String -> m InspectedModule
scanModule defines opts (FileModule f p) mcts = hsdevLiftIO $ liftM setProj $ liftIO $ inspectFile defines opts f p mcts where
	setProj =
		set (inspectedKey . moduleProject) p .
		set (inspectionResult . _Right . moduleId . moduleLocation . moduleProject) p
scanModule _ opts mloc@(InstalledModule c _ n) _ = hsdevLiftIO $ do
	pdbs <- getDbs c
	ims <- browseModules opts pdbs [mloc]
	maybe (hsdevError $ BrowseNoModuleInfo n) return $ listToMaybe ims
	where
		getDbs :: CommandMonad m => PackageDb -> m PackageDbStack
		getDbs = maybe (return userDb) searchPackageDbStack . preview packageDb
scanModule _ _ (OtherLocation _) _ = hsdevError $ InspectError "Can inspect only installed or source modules"
scanModule _ _ NoLocation _ = hsdevError $ InspectError "Can inspect only installed or source modules"

-- | Scan additional info and modify scanned module
scanModify :: CommandMonad m => ([String] -> PackageDbStack -> Module -> m Module) -> InspectedModule -> m InspectedModule
scanModify f im = traverse f' im where
	f' m = do
		pdbs <- case view (moduleId . moduleLocation) m of
			-- TODO: Get actual sandbox stack
			FileModule fpath _ -> searchPackageDbStack fpath
			InstalledModule pdb _ _ -> maybe (return userDb) searchPackageDbStack $ preview packageDb pdb
			_ -> return userDb
		f (fromMaybe [] $ preview (inspection . inspectionOpts) im) pdbs m

-- | Is inspected module up to date?
upToDate :: [String] -> InspectedModule -> IO Bool
upToDate opts im = case view inspectedKey im of
	FileModule f _ -> liftM (== view inspection im) $ fileInspection f opts
	InstalledModule _ _ _ -> return $ view inspection im == InspectionAt 0 opts
	_ -> return False

-- | Rescan inspected module
rescanModule :: CommandMonad m => [(String, String)] -> [String] -> InspectedModule -> m (Maybe InspectedModule)
rescanModule defines opts im = do
	up <- liftIO $ upToDate opts im
	if up
		then return Nothing
		else fmap Just $ scanModule defines opts (view inspectedKey im) Nothing

-- | Is module new or recently changed
changedModule :: Database -> [String] -> ModuleLocation -> IO Bool
changedModule db opts m = maybe (return True) (liftM not . liftIO . upToDate opts) m' where
	m' = db ^? databaseModules . ix m

-- | Returns new (to scan) and changed (to rescan) modules
changedModules :: Database -> [String] -> [ModuleToScan] -> IO [ModuleToScan]
changedModules db opts = filterM $ \m -> if isJust (m ^. _3)
	then return True
	else changedModule db (opts ++ (m ^. _2)) (m ^. _1)

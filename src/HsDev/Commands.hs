{-# LANGUAGE RankNTypes #-}

module HsDev.Commands (
	findDeclaration, findModule,
	goToDeclaration,
	importSymbol,
	lookupSymbol,
	symbolInfo,
	completions,
	moduleCompletions
	) where

import Control.Arrow
import Control.Monad
import Control.Monad.Error
import Data.Function
import Data.List
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as M
import qualified Data.Set as S
import System.Directory

import HsDev.Util
import HsDev.Database
import HsDev.Symbols
import HsDev.Symbols.Util

findDeclaration :: Database -> String -> ErrorT String IO [Symbol Declaration]
findDeclaration db ident = return $ maybe [] S.toList $ M.lookup ident (databaseSymbols db)

findModule :: Database -> String -> ErrorT String IO [Symbol Module]
findModule db mname = return $ maybe [] S.toList $ M.lookup mname (databaseModules db)

reachablePredicate :: Database -> Maybe String -> FilePath -> Symbol Declaration -> Bool
reachablePredicate db qualifiedName f s = fromMaybe True $ do
	thisModule <- M.lookup f (databaseFiles db)
	declModule <- symbolModule s
	return (isReachable thisModule qualifiedName declModule)

goToDeclaration :: Database -> Maybe FilePath -> String -> ErrorT String IO [Symbol Declaration]
goToDeclaration db file ident = do
	fileName <- maybe (return "") (liftIO . canonicalizePath) file
	liftM (filter (filterDecl fileName)) $ findDeclaration db identName
	where
		(qualifiedName, identName) = splitIdentifier ident
		filterDecl f = satisfy [
			bySources,
			reachablePredicate db qualifiedName f]

importSymbol :: Database -> FilePath -> String -> ErrorT String IO [String]
importSymbol db file ident = do
	look <- lookupSymbol db file ident
	return $ case look of
		Right _ -> []
		Left cs -> mapMaybe (fmap makeImport . symbolModule) cs
	where
		makeImport :: Symbol Module -> String
		makeImport m = "import " ++ symbolName m

lookupSymbol :: Database -> FilePath -> String -> ErrorT String IO (Either [Symbol Declaration] (Symbol Declaration))
lookupSymbol db file ident = do
	fileName <- liftIO $ canonicalizePath file
	project <- liftIO $ locateProject fileName
	decls <- liftM (filter (filterDecl fileName project)) $ findDeclaration db identName
	let
		visibles = filter (reachablePredicate db qualifiedName fileName) decls
		bestModule = preferredModule Cabal project (mapMaybe symbolModule visibles)
		bestVisible = find ((== bestModule) . symbolModule) visibles
	return $ maybe (Left decls) Right bestVisible
	where
		(qualifiedName, identName) = splitIdentifier ident
		filterDecl f p = maybe False (\m -> isVisible Cabal p m || inFile f m) . symbolModule

symbolInfo :: Database -> Maybe FilePath -> String -> ErrorT String IO (Symbol Declaration)
symbolInfo db file ident = do
	fileName <- maybe (return "") (liftIO . canonicalizePath) file
	project <- maybe (return Nothing) (const $ liftIO $ locateProject fileName) file
	decls <- liftM (nubModules . sortDecls project . filter (filterDecl fileName project)) $ findDeclaration db identName
	case length (noPrelude decls) of
		0 -> maybe (throwError $ "Symbol '" ++ ident ++ "' not found") return $ find (inModule "Prelude") decls
		1 -> return $ head decls
		_ -> throwError $ "Ambiguous symbols: " ++ intercalate ", " (map put (noPrelude decls))
	where
		(qualifiedName, identName) = splitIdentifier ident
		filterDecl f p = satisfy [
			maybe False (\m -> isVisible Cabal p m || inFile f m) . symbolModule,
			reachablePredicate db qualifiedName f]
		sortDecls p = uncurry (++) . partition (inProject_ p)
		nubModules = nubBy ((==) `on` (fmap symbolName . symbolModule))
		noPrelude = filter (not . inModule "Prelude")
		put s = maybe "" ((++ ".") . symbolName) (symbolModule s) ++ symbolName s

completions :: Database -> Symbol Module -> String -> ErrorT String IO [Symbol Declaration]
completions db m prefix = return $ filter ((identName `isPrefixOf`) . symbolName) $ maybe [] (concatMap (M.elems . moduleDeclarations . symbol)) $ M.lookup qualifiedName moduleScope
	where
		(qualifiedName, identName) = splitIdentifier prefix

		moduleScope = scope m

		scope :: Symbol Module -> Map (Maybe String) [Symbol Module]
		scope m' = M.unionsWith (++) $ decls [Nothing, Just (symbolName m')] m' : imports m'
		decls qs m' = M.unionsWith (++) $ map (\q -> M.singleton q [m']) qs
		imports m' = map (importScope m') $ (if bySources m' then (Import "Prelude" False Nothing Nothing :) else id) $ M.elems (moduleImports (symbol m))
		importScope m' i = fromMaybe M.empty $ do
			ms <- M.lookup (importModuleName i) (databaseModules db)
			imported <- visibleModule Cabal (symbolLocation m' >>= locationProject) (S.toList ms)
			return $ decls (catMaybes [
				Just (Just (importModuleName i)),
				if not (importIsQualified i) then Just Nothing else Nothing,
				fmap Just (importAs i)]) imported

		--project = symbolLocation m >>= locationProject

moduleCompletions :: Database -> [Symbol Module] -> String -> ErrorT String IO [String]
moduleCompletions _ ms prefix = return $ nub $ completions' $ map symbolName ms where
	completions' = mapMaybe getNext where
		getNext m
			| prefix `isPrefixOf` m = listToMaybe $ map snd $ dropWhile (uncurry (==)) $ zip (splitBy '.' prefix) (splitBy '.' m)
			| otherwise = Nothing

splitBy :: Char -> String -> [String]
splitBy ch = takeWhile (not . null) . unfoldr (Just . second (drop 1) . break (== ch))

splitIdentifier :: String -> (Maybe String, String)
splitIdentifier name = (qname, name') where
	prefix = dropWhileEnd (/= '.') name
	prefix' = dropWhileEnd (== '.') prefix
	qname = if null prefix' then Nothing else Just prefix'
	name' = fromMaybe (error "Impossible happened") $ stripPrefix prefix name
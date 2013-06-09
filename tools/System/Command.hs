{-# LANGUAGE GeneralizedNewtypeDeriving, OverloadedStrings #-}

module System.Command (
	Command(..),
	cmd, cmd_,
	brief, help,
	run,
	opt, askOpt,
	split, unsplit
	) where

import Control.Arrow
import Data.Char
import Data.List (stripPrefix, unfoldr)
import Data.Maybe (mapMaybe, listToMaybe)
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid
import System.Console.GetOpt

-- | Command
data Command a = Command {
	commandName :: [String],
	commandPosArgs :: [String],
	commandDesc :: Maybe String,
	commandUsage :: [String],
	commandRun :: [String] -> Maybe (Either [String] a) }

-- | Make command
cmd :: Monoid c => [String] -> [String] -> String -> [OptDescr c] -> (c -> [String] -> a) -> Command a
cmd name posArgs descr as act = Command {
	commandName = name,
	commandPosArgs = posArgs,
	commandDesc = descr',
	commandUsage = lines $ usageInfo (unwords (name ++ map (\a -> "[" ++ a ++ "]") posArgs) ++ maybe "" (" -- " ++) descr') as,
	commandRun = \opts -> case getOpt Permute as opts of
		(opts', cs, errs) -> fmap (\cs' -> if null errs then return (act (mconcat opts') cs') else Left errs) (stripPrefix name cs) }
	where
		descr' = if null descr then Nothing else Just descr

-- | Make command without params
cmd_ :: [String] -> [String] -> String -> ([String] -> a) -> Command a
cmd_ name posArgs descr act = cmd name posArgs descr [] (act' act) where
	act' :: a -> () -> a
	act' = const

-- | Show brief help for command
brief :: Command a -> String
brief = head . commandUsage

-- | Show detailed help for command
help :: Command a -> [String]
help = commandUsage

-- | Run commands
run :: [Command a] -> a -> ([String] -> a) -> [String] -> a
run cmds onDef onError as = maybe onDef (either onError id) found where
	found = listToMaybe $ mapMaybe (`commandRun` as) cmds

opt :: String -> String -> Map String String
opt name value = M.singleton name value

askOpt :: String -> Map String String -> Maybe String
askOpt = M.lookup

-- | Split string to words
split :: String -> [String]
split "" = []
split (c:cs)
	| isSpace c = split cs
	| c == '"' = let (w, cs') = readQuote cs in w : split cs'
	| otherwise = let (ws, tl) = break isSpace cs in (c:ws) : split tl
	where
		readQuote :: String -> (String, String)
		readQuote "" = ("", "")
		readQuote ('\\':ss)
			| null ss = ("\\", "")
			| otherwise = first (head ss :) $ readQuote (tail ss)
		readQuote ('"':ss) = ("", ss)
		readQuote (s:ss) = first (s:) $ readQuote ss

unsplit :: [String] -> String
unsplit = unwords . map escape where
	escape :: String -> String
	escape str
		| any isSpace str || '"' `elem` str = "\"" ++ concat (unfoldr escape' str) ++ "\""
		| otherwise = str
	escape' :: String -> Maybe (String, String)
	escape' [] = Nothing
	escape' (ch:tl) = Just (escaped, tl) where
		escaped = case ch of
			'"' -> "\\\""
			'\\' -> "\\\\"
			_ -> [ch]
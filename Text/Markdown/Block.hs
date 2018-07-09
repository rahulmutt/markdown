{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}
module Text.Markdown.Block
    ( Block (..)
    , ListType (..)
    , ColumnAlignment(..)
    , toBlocks
    , toBlockLines
    ) where

import Prelude
import Control.Monad (msum)
#if MIN_VERSION_conduit(1, 0, 0)
import Data.Conduit
#else
import Data.Conduit hiding ((.|))
import Data.Conduit.Internal (pipeL)
#endif
import qualified Data.Conduit.Text as CT
import qualified Data.Conduit.List as CL
import Data.Text (Text)
import Data.Maybe (mapMaybe)
import Data.Monoid ((<>))
import qualified Data.Text as T
import Data.Char (isDigit)
import Text.Markdown.Types
import qualified Data.Set as Set
import qualified Data.Map as Map

toBlockLines :: Block Text -> Block [Text]
toBlockLines = fmap $ map T.stripEnd
                    . concatMap (T.splitOn "  \r\n")
                    . T.splitOn "  \n"

toBlocks :: Monad m => MarkdownSettings -> ConduitM Text (Block Text) m ()
toBlocks ms =
    mapOutput fixWS CT.lines .| toBlocksLines ms
  where
    fixWS = T.pack . go 0 . T.unpack

    go _ [] = []
    go i ('\r':cs) = go i cs
    go i ('\t':cs) =
        (replicate j ' ') ++ go (i + j) cs
      where
        j = 4 - (i `mod` 4)
    go i (c:cs) = c : go (i + 1) cs

toBlocksLines :: Monad m => MarkdownSettings -> ConduitM Text (Block Text) m ()
toBlocksLines ms = awaitForever (start ms) .| tightenLists

tightenLists :: Monad m => ConduitM (Either Blank (Block Text)) (Block Text) m ()
tightenLists =
    go Nothing
  where
    go mTightList =
        await >>= maybe (return ()) go'
      where
        go' (Left Blank) = go mTightList
        go' (Right (BlockList ltNew contents)) =
            case mTightList of
                Just (ltOld, isTight) | ltOld == ltNew -> do
                    yield $ BlockList ltNew $ (if isTight then tighten else untighten) contents
                    go mTightList
                _ -> do
                    isTight <- checkTight ltNew False
                    yield $ BlockList ltNew $ (if isTight then tighten else untighten) contents
                    go $ Just (ltNew, isTight)
        go' (Right b) = yield b >> go Nothing

    tighten (Right [BlockPara t]) = Left t
    tighten (Right []) = Left T.empty
    tighten x = x

    untighten (Left t) = Right [BlockPara t]
    untighten x = x

    checkTight lt sawBlank = do
        await >>= maybe (return $ not sawBlank) go'
      where
        go' (Left Blank) = checkTight lt True
        go' b@(Right (BlockList ltNext _)) | ltNext == lt = do
            leftover b
            return $ not sawBlank
        go' b = leftover b >> return False

data Blank = Blank

data LineType = LineList ListType Text
              | LineCode Text
              | LineFenced Text FencedHandler -- ^ terminator, language
              | LineBlockQuote Text
              | LineHeading Int Text
              | LineBlank
              | LineText Text
              | LineRule
              | LineHtml Text
              | LineReference Text Text -- ^ name, destination
              | LineTable Int [Text] -- ^ components of the header

lineType :: MarkdownSettings -> Text -> LineType
lineType ms t
    | T.null $ T.strip t = LineBlank
    | Just (term, fh) <- getFenced (Map.toList $ msFencedHandlers ms) t = LineFenced term fh
    | Just t' <- T.stripPrefix "> " t = LineBlockQuote t'
    | Just (level, t') <- stripHeading t = LineHeading level t'
    | Just t' <- T.stripPrefix "    " t = LineCode t'
    | isRule t = LineRule
    | isHtmlStart t = LineHtml t
    | Just (ltype, t') <- listStart t = LineList ltype t'
    | Just (name, dest) <- getReference t = LineReference name dest
    | header@(_:_) <- tableColumns t = LineTable (length header) header
    | otherwise = LineText t
  where
    getFenced [] _ = Nothing
    getFenced ((x, fh):xs) t'
        | Just rest <- T.stripPrefix x t' = Just (x, fh $ T.strip rest)
        | otherwise = getFenced xs t'

    isRule :: Text -> Bool
    isRule =
        go . T.strip
      where
        go "* * *" = True
        go "***" = True
        go "*****" = True
        go "- - -" = True
        go "---" = True
        go "___" = True
        go "_ _ _" = True
        go t' = T.length (T.takeWhile (== '-') t') >= 5

    stripHeading :: Text -> Maybe (Int, Text)
    stripHeading t'
        | T.null x = Nothing
        | otherwise = Just (T.length x, T.strip $ T.dropWhileEnd (== '#') y)
      where
        (x, y) = T.span (== '#') t'

    getReference :: Text -> Maybe (Text, Text)
    getReference a = do
        b <- T.stripPrefix "[" $ T.dropWhile (== ' ') a
        let (name, c) = T.break (== ']') b
        d <- T.stripPrefix "]:" c
        Just (name, T.strip d)

start :: Monad m => MarkdownSettings -> Text -> ConduitM Text (Either Blank (Block Text)) m ()
start ms t =
    go $ lineType ms t
  where
    go LineBlank = yield $ Left Blank
    go (LineFenced term fh) = do
        (finished, ls) <- takeTillConsume (== term)
        case finished of
            Just _ -> do
                let block =
                        case fh of
                            FHRaw fh' -> fh' $ T.intercalate "\n" ls
                            FHParsed fh' -> fh' $ runConduitPure $ mapM_ yield ls .| toBlocksLines ms .| CL.consume
                mapM_ (yield . Right) block
            Nothing -> mapM_ leftover (reverse $ T.cons ' ' t : ls)
    go (LineBlockQuote t') = do
        ls <- takeQuotes .| CL.consume
        let blocks = runConduitPure $ mapM_ yield (t' : ls) .| toBlocksLines ms .| CL.consume
        yield $ Right $ BlockQuote blocks
    go (LineHeading level t') = yield $ Right $ BlockHeading level t'
    go (LineCode t') = do
        ls <- getIndented 4 .| CL.consume
        yield $ Right $ BlockCode Nothing $ T.intercalate "\n" $ t' : ls
    go LineRule = yield $ Right BlockRule
    go (LineHtml t') = do
        if t' `Set.member` msStandaloneHtml ms
            then yield $ Right $ BlockHtml t'
            else do
                ls <- takeTill (T.null . T.strip) .| CL.consume
                yield $ Right $ BlockHtml $ T.intercalate "\n" $ t' : ls
    go (LineList ltype t') = do
        t2 <- CL.peek
        case fmap (lineType ms) t2 of
            -- If the next line is a non-indented text line, then we have a
            -- lazy list.
            Just (LineText t2') | T.null (T.takeWhile (== ' ') t2') -> do
                CL.drop 1
                -- Get all of the non-indented lines.
                let loop front = do
                        x <- await
                        case x of
                            Nothing -> return $ front []
                            Just y ->
                                case lineType ms y of
                                    LineText z -> loop (front . (z:))
                                    _ -> leftover y >> return (front [])
                ls <- loop (\rest -> T.dropWhile (== ' ') t' : t2' : rest)
                yield $ Right $ BlockList ltype $ Right [BlockPara $ T.intercalate "\n" ls]
            -- If the next line is an indented list, then we have a sublist. I
            -- disagree with this interpretation of Markdown, but it's the way
            -- that Github implements things, so we will too.
            _ | Just t2' <- t2
              , Just t2'' <- T.stripPrefix "    " t2'
              , LineList _ltype' _t2''' <- lineType ms t2'' -> do
                ls <- getIndented 4 .| CL.consume
                let blocks = runConduitPure $ mapM_ yield ls .| toBlocksLines ms .| CL.consume
                let addPlainText
                        | T.null $ T.strip t' = id
                        | otherwise = (BlockPlainText (T.strip t'):)
                yield $ Right $ BlockList ltype $ Right $ addPlainText blocks
            _ -> do
                let t'' = T.dropWhile (== ' ') t'
                let leader = T.length t - T.length t''
                ls <- getIndented leader .| CL.consume
                let blocks = runConduitPure $ mapM_ yield (t'' : ls) .| toBlocksLines ms .| CL.consume
                yield $ Right $ BlockList ltype $ Right blocks
    go (LineReference x y) = yield $ Right $ BlockReference x y
    go (LineText t') = do
        -- Check for underline headings
        let getUnderline :: Text -> Maybe Int
            getUnderline s
                | T.length s < 2 = Nothing
                | T.all (== '=') s = Just 1
                | T.all (== '-') s = Just 2
                | otherwise = Nothing
        t2 <- CL.peek
        case t2 >>= getUnderline of
            Just level -> do
                CL.drop 1
                yield $ Right $ BlockHeading level t'
            Nothing -> do
                let listStartIndent x =
                        case listStart x of
                            Just (_, y) -> T.take 2 y == "  "
                            Nothing -> False
                    isNonPara LineBlank = True
                    isNonPara LineFenced{} = True
                    isNonPara LineBlockQuote{} = not $ msBlankBeforeBlockquote ms
                    isNonPara LineHtml{} = True -- See example 95 in Common Markdown spec
                    isNonPara _ = False
                (mfinal, ls) <- takeTillConsume (\x -> isNonPara (lineType ms x) || listStartIndent x)
                maybe (return ()) leftover mfinal
                yield $ Right $ BlockPara $ T.intercalate "\n" $ t' : ls
    go (LineTable n header) = do
      border <- await
      case fmap (lineType ms) border of
        Just (LineTable n' header')
          | n' == n
          , Just alignedHeaders <- verifyBorder header header' -> do
              let pad n'' xs
                    | n > n''    = xs ++ replicate (n - n'') mempty
                    | otherwise = take n xs
                  isNonTable LineTable {} = False
                  isNonTable LineText {} = False
                  isNonTable _ = True
              (mfinal, rows) <- takeTillConsume (isNonTable . lineType ms)
              maybe (return ()) leftover mfinal
              let allRows =
                    map (\x -> case lineType ms x of
                            LineTable n'' row -> pad n'' row
                            LineText t' -> pad 1 [t']
                            _line -> error "Invalid line token when parsing table.")
                    rows
              yield $ Right $ BlockTable alignedHeaders allRows
        _ -> do
          maybe (return ()) leftover border
          go (LineText (T.intercalate "|" header))
      where verifyBorder ts1 ts2
              | length headers == length alignedHeaders = Just alignedHeaders
              | otherwise = Nothing
              where headers = zip ts1 ts2
                    alignedHeaders = mapMaybe maybeBorder headers
            stripColonsAndAlign x = (fromColons leftColon rightColon, z)
              where (leftColon,  y) = maybe (False, x) (True,) $ T.stripPrefix ":" x
                    (rightColon, z) = maybe (False, y) (True,) $ T.stripSuffix ":" y
            maybeBorder (title, t'')
              | not (T.null t') && T.all (== '-') t' = Just (alignment, T.length t', title)
              | otherwise = Nothing
              where (alignment, t') = stripColonsAndAlign $ T.strip t''

isHtmlStart :: T.Text -> Bool
-- Allow for up to three spaces before the opening tag.
isHtmlStart t | "    " `T.isPrefixOf` t = False
isHtmlStart t =
    case T.stripPrefix "<" $ T.dropWhile (== ' ') t of
        Nothing -> False
        Just t' ->
            let (name, rest)
                    | Just _ <- T.stripPrefix "!--" t' = ("--", t')
                    | otherwise = T.break (\c -> c == ' ' || c == '>') t'
             in (T.all isValidTagName name &&
                not (T.null name) &&
                (not ("/" `T.isPrefixOf` rest) || ("/>" `T.isPrefixOf` rest)))

                || isPI t' || isCommentCData t'
  where
    isValidTagName :: Char -> Bool
    isValidTagName c =
        ('A' <= c && c <= 'Z') ||
        ('a' <= c && c <= 'z') ||
        ('0' <= c && c <= '9') ||
        (c == '-') ||
        (c == '_') ||
        (c == '/') ||
        (c == '!')

    isPI = ("?" `T.isPrefixOf`)
    isCommentCData = ("!" `T.isPrefixOf`)

takeTill :: Monad m => (i -> Bool) -> ConduitM i i m ()
takeTill f =
    loop
  where
    loop = await >>= maybe (return ()) (\x -> if f x then return () else yield x >> loop)

takeTillConsume
  :: Monad m
  => (i -> Bool)
  -> ConduitM i o m (Maybe i, [i])
takeTillConsume f =
    loop id
  where
    loop front = await >>= maybe
        (return (Nothing, front []))
        (\x ->
            if f x
                then return (Just x, front [])
                else loop (front . (x:))
        )

listStart :: Text -> Maybe (ListType, Text)
listStart t0
    | Just t' <- stripUnorderedListSeparator t = Just (Unordered, t')
    | Just t' <- stripNumber t, Just t'' <- stripOrderedListSeparator t' = Just (Ordered, t'')
    | otherwise = Nothing
  where
    t = T.stripStart t0

stripNumber :: Text -> Maybe Text
stripNumber x
    | T.null y = Nothing
    | otherwise = Just z
  where
    (y, z) = T.span isDigit x

stripUnorderedListSeparator :: Text -> Maybe Text
stripUnorderedListSeparator =
  stripPrefixChoice ["* ", "*\t", "+ ", "+\t", "- ", "-\t"]

stripOrderedListSeparator :: Text -> Maybe Text
stripOrderedListSeparator =
  stripPrefixChoice [". ", ".\t", ") ", ")\t"]

-- | Attempt to strip each of the prefixes in @xs@ from the start of @x@. As
-- soon as one matches, return the remainder of @x@. Prefixes are tried in
-- order. If none match, return @Nothing@.
stripPrefixChoice :: [Text] -> Text -> Maybe Text
stripPrefixChoice xs x = msum $ map (flip T.stripPrefix x) xs

getIndented :: Monad m => Int -> ConduitM Text Text m ()
getIndented leader =
    go []
  where
    go blanks = await >>= maybe (mapM_ leftover blanks) (go' blanks)

    go' blanks t
        | T.null $ T.strip t = go (T.drop leader t : blanks)
        | T.length x == leader && T.null (T.strip x) = do
            mapM_ yield $ reverse blanks
            yield y
            go []
        | otherwise = mapM_ leftover (t:blanks)
      where
        (x, y) = T.splitAt leader t

takeQuotes :: Monad m => ConduitM Text Text m ()
takeQuotes =
    await >>= maybe (return ()) go
  where
    go "" = return ()
    go ">" = yield "" >> takeQuotes
    go t
        | Just t' <- T.stripPrefix "> " t = yield t' >> takeQuotes
        | otherwise = yield t >> takeQuotes

tableColumns :: Text -> [Text]
tableColumns t = reverse $ go t mempty []
  where go t prev xs
          | T.null y = (if T.null x then [] else [x]) ++ xs
          -- Make sure not to parse \| as a table separator
          | not (T.null x) && T.last x == '\\' = go (T.drop 1 y) (prev <> x <> "|") xs
          | otherwise = go (T.drop 1 y) mempty (if null xs && T.null x
                                                then xs
                                                else (prev <> x):xs)
          where (x, y) = T.break (== '|') t

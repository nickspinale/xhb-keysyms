{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude hiding (getContents, takeWhile)
import Control.Applicative
import Control.Monad
import Data.Char
import Data.List
import Data.Text (Text, unpack)
import Data.Text.IO (getContents)
import Data.Attoparsec.Text
import Data.Maybe
import System.Exit
import System.Environment
import Language.Haskell.Exts


-- Takes keysymdef.h as stdin and writes Graphics.XHB.KeySym.{Defs,Names} as
-- into defsOut and namesOut

main :: IO ()
main = do
    args <- getArgs
    case args of
        [defsOut, namesOut] -> do
            file <- getContents
            when (file == file) $ return ()
            case parseOnly keySymDefs file of
                Left err -> die $ "error parsing stdin: " ++ err
                Right defs -> do
                    writeFile defsOut . prettyPrint $ defsModule defs
                    writeFile namesOut . prettyPrint $ namesModule defs
        _ -> die "Usage: gen-xhb-keysyms <defsOut, namesOut>"


---------------------
-- CODE GENERATION --
---------------------


qname :: String -> QName
qname = UnQual . Ident

tqname :: String -> Type
tqname = TyCon . UnQual . Ident

nameSym :: String -> Name
nameSym = Ident . (++) "xK_"

emptyLoc :: SrcLoc
emptyLoc = SrcLoc "" 0 0

emptyImp :: String -> ImportDecl
emptyImp name = ImportDecl
    { importLoc = emptyLoc
    , importModule = ModuleName name
    , importQualified = False
    , importSrc = False
    , importSafe = False
    , importPkg = Nothing
    , importAs = Nothing
    , importSpecs = Nothing
    }


namesModule :: [KeySymDef] -> Module
namesModule defs = Module emptyLoc mname [] Nothing spec imps [sig, bind]
  where
    namesName = Ident "keySymNames"
    mname = ModuleName "Graphics.XHB.KeySym.Names.Internal"
    spec = Just [EVar . UnQual $ namesName]
    sig = TypeSig emptyLoc [namesName]
            (TyApp (TyApp (tqname "Map") (tqname "KEYSYM"))
                   (TyTuple Boxed [ tqname "String"
                                  , TyApp (tqname "Maybe") (tqname "Char")
                                  ]))
    bind = PatBind emptyLoc (PVar (Ident "keySymNames")) (UnGuardedRhs rhs) Nothing
    rhs = App (Var . UnQual $ Ident "fromAscList") . List . map nameTuple $ sortBy comp defs
    comp (KeySymDef _ i _) (KeySymDef _ j _) = compare i j
    imps = [ emptyImp "Graphics.XHB"
           , emptyImp "Graphics.XHB.KeySym.Defs"
           , (emptyImp "Data.Map")
                { importSpecs = Just ( False, [ IVar (Ident "fromAscList")
                                              , IAbs NoNamespace (Ident "Map")
                                              ]
                                     )
                }
           ]


nameTuple :: KeySymDef -> Exp
nameTuple (KeySymDef n v mc) = Tuple Boxed
    [ Lit (Int v)
    , Tuple Boxed [ Lit $ String n
                  , case mc of
                      Just c -> App (Con (qname "Just")) (Lit (Char c))
                      Nothing -> Con (qname "Nothing")
                  ]
    ]


defsModule :: [KeySymDef] -> Module
defsModule defs = Module emptyLoc mname [] Nothing Nothing [emptyImp "Graphics.XHB"] decls
  where
    mname = ModuleName "Graphics.XHB.KeySym.Defs"
    decls = concatMap ((\(a, b) -> [a, b]) . defDecl) defs


defDecl :: KeySymDef -> (Decl, Decl)
defDecl (KeySymDef n v _) = (sig, bind)
  where
    name = nameSym n
    sig  = TypeSig emptyLoc [name] . TyCon $ qname "KEYSYM"
    bind = PatBind emptyLoc (PVar name) (UnGuardedRhs . Lit . Int $ v) Nothing


-------------
-- PARSING --
-------------


data KeySymDef = KeySymDef String Integer (Maybe Char)
    deriving Show


keySymDefs :: Parser [KeySymDef]
keySymDefs = catMaybes <$> many (Just <$> keySymDef <|> Nothing <$ restOfLine)


keySymDef :: Parser KeySymDef
keySymDef = do
    string "#define XK_"
    name <- unpack <$> takeTill (== ' ')
    skipSpace
    string "0x"
    code <- hexadecimal :: Parser Integer
    skipWhile (== ' ')
    ucode <- Just <$> comment <|> return Nothing
    restOfLine
    return $ KeySymDef name code ucode
  where
    comment = do
        string "/* U+"
        n <- hexadecimal
        manyTill anyChar (string "*/")
        return $ chr n


restOfLine :: Parser Text
restOfLine = takeTill isEndOfLine <* endOfLine

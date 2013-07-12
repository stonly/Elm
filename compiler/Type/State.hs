{-# OPTIONS_GHC -XMultiWayIf #-}
module Type.State where

import Type.Type
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Type.Environment as Env
import qualified Data.UnionFind.IO as UF
import Control.Monad.State
import Control.Applicative ((<$>),(<*>), Applicative)
import qualified Data.Traversable as Traversable
import Text.PrettyPrint as P
import SourceSyntax.PrettyPrint

debug e = {-- liftIO e --} return ()

-- Pool
-- Holds a bunch of variables
-- The rank of each variable is less than or equal to the pool's "maxRank"
-- The young pool exists to make it possible to identify these vars in constant time.

data Pool = Pool {
  maxRank :: Int,
  inhabitants :: [Variable]
} deriving Show

emptyPool = Pool { maxRank = 0, inhabitants = [] }

-- Keeps track of the environment, type variable pool, and a list of errors
type SolverState = (Map.Map String Variable, Pool, Int, [IO P.Doc])

-- The mark must never be equal to noMark!
initialState = (Map.empty, emptyPool, noMark + 1, [])

modifyEnv  f = modify $ \(env, pool, mark, errors) -> (f env, pool, mark, errors)
modifyPool f = modify $ \(env, pool, mark, errors) -> (env, f pool, mark, errors)
addError message t1 t2 =
    modify $ \(env, pool, mark, errors) -> (env, pool, mark, err : errors)

  where
    wordify = P.fsep . map P.text . words 
    msg = wordify message
    width = maximum . map length . lines $ render msg
    spaces = List.replicate (width - 15 - 3) ' '
    err = makeError <$> extraPretty t1 <*> extraPretty t2
    makeError pt1 pt2 =
        P.vcat [ P.text $ "Type error" ++ spaces ++ "line ???"
               , P.text (List.replicate width '-')
               , msg <> P.text "\n"
               , P.text "   Expected Type:" <+> pt1
               , P.text "     Actual Type:" <+> pt2 <> P.text "\n"
               , wordify "The error comes from:" <> P.text "\n"
               , P.nest 3 (P.text "???")
               ]

switchToPool pool = modifyPool (\_ -> pool)

getPool :: StateT SolverState IO Pool
getPool = do
  (_, pool, _, _) <- get
  return pool

getEnv :: StateT SolverState IO (Map.Map String Variable)
getEnv = do
  (env, _, _, _) <- get
  return env

uniqueMark :: StateT SolverState IO Int
uniqueMark = do
  (env, pool, mark, errs) <- get
  put (env, pool, mark+1, errs)
  return mark

nextRankPool :: StateT SolverState IO Pool
nextRankPool = do
  pool <- getPool
  return $ Pool { maxRank = maxRank pool + 1, inhabitants = [] }

register :: Variable -> StateT SolverState IO Variable
register variable = do
    modifyPool $ \pool -> pool { inhabitants = variable : inhabitants pool }
    return variable

introduce :: Variable -> StateT SolverState IO Variable
introduce variable = do
  pool <- getPool
  liftIO $ UF.modifyDescriptor variable (\desc -> desc { rank = maxRank pool })
  register variable

flatten :: Type -> StateT SolverState IO Variable
flatten term =
  case term of
    VarN v -> return v
    TermN t -> do
      flatStructure <- traverseTerm flatten t
      pool <- getPool
      var <- liftIO . UF.fresh $ Descriptor {
               structure = Just flatStructure,
               rank = maxRank pool,
               flex = Flexible,
               name = Nothing,
               copy = Nothing,
               mark = noMark
             }
      register var

makeInstance :: Variable -> StateT SolverState IO Variable
makeInstance var = do
  alreadyCopied <- uniqueMark
  freshVar <- makeCopy alreadyCopied var
  restore alreadyCopied var
  return freshVar

makeCopy :: Int -> Variable -> StateT SolverState IO Variable
makeCopy alreadyCopied variable = do
  debug $ putStr "Copying: "
  desc <- liftIO $ UF.descriptor variable
  if | mark desc == alreadyCopied ->
        do debug $ putStrLn "Already Copied"
           case copy desc of
             Just v -> return v
             Nothing -> error "This should be impossible."

     | rank desc /= noRank || flex desc == Constant ->
        do debug $ putStr "did not make a copy: " >> print (mark desc, noRank, flex desc)
           return variable

     | otherwise -> do
         debug $ print "no problems!"
         pool <- getPool
         newVar <- liftIO $ UF.fresh $ Descriptor {
                     structure = Nothing,
                     rank = maxRank pool,
                     mark = noMark,
                     flex = Flexible,
                     copy = Nothing,
                     name = case flex desc of
                              Rigid -> Nothing
                              _ -> name desc
                   }

         register newVar

         -- Link the original variable to the new variable. This lets us
         -- avoid making multiple copies of the variable we are instantiating.
         --
         -- Need to do this before recursively copying the structure of
         -- the variable to avoid looping on cyclic terms.
         liftIO $ UF.modifyDescriptor variable $ \desc ->
             desc { mark = alreadyCopied, copy = Just newVar }

         -- Now we recursively copy the structure of the variable.
         -- We have already marked the variable as copied, so we
         -- will not repeat this work or crawl this variable again.
         case structure desc of
           Nothing -> return newVar
           Just term -> do
               newTerm <- traverseTerm (makeCopy alreadyCopied) term
               liftIO $ UF.modifyDescriptor newVar $ \desc ->
                   desc { structure = Just newTerm }
               return newVar

restore :: Int -> Variable -> StateT SolverState IO Variable
restore alreadyCopied variable = do
  debug $ putStr "Restoring: "
  desc <- liftIO $ UF.descriptor variable
  if mark desc /= alreadyCopied
    then do
      debug $ putStrLn "not copied, no need to do anything"
      return variable
    else do
      debug $ putStrLn "restoring"
      restoredStructure <-
          case structure desc of
            Nothing -> return Nothing
            Just term -> Just <$> traverseTerm (restore alreadyCopied) term
      debug $ UF.modifyDescriptor variable $ \desc ->
          desc { mark = noMark, rank = noRank, structure = restoredStructure }
      return variable

traverseTerm :: (Monad f, Applicative f) => (a -> f b) -> Term1 a -> f (Term1 b)
traverseTerm f term =
  case term of
    App1 a b -> App1 <$> f a <*> f b
    Fun1 a b -> Fun1 <$> f a <*> f b
    Var1 x -> Var1 <$> f x
    EmptyRecord1 -> return EmptyRecord1
    Record1 fields ext ->
        Record1 <$> Traversable.traverse (mapM f) fields <*> f ext

{-# LANGUAGE LocalImports #-}
module Main where
import qualified LocalImports_A as A
import qualified LocalImports_B as B

fooA :: Int
fooA = let import A
       in foo

fooB :: Int
fooB = let import B
       in foo

fooC = wa
  where import A
        wa = foo

main :: IO ()
main = print $ fooA == 23 && fooB == 46 && fooC == 23

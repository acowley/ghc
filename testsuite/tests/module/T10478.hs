{-# LANGUAGE ShortImports #-}
module Test where
import Data.List (foldl') as L

foo :: [Int] -> Maybe Int
foo = fmap (foldl' (+) 0) . L.stripPrefix [1,2,3]

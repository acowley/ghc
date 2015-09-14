{-# LANGUAGE ShortImports #-}
module Test where
import Data.List (foldl') as L
import Data.Char hiding (isDigit) as C

foo :: [Int] -> Maybe Int
foo = fmap (foldl' (+) 0) . L.stripPrefix [1,2,3]

testHiding :: Char -> Bool
testHiding c = C.isDigit c && not (isLower c)

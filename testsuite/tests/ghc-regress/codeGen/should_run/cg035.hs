module Main (main) where

import IOExts ( unsafePerformIO )

c :: Double -> Double
c x = cos x
  where
    cos :: Double -> Double
    cos x = unsafePerformIO (_ccall_ cos x)

main = putStr (shows (c 0.0) "\n")

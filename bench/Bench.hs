module Bench where

import Bench.BSPSCQueue
import Criterion.Main

main :: IO ()
main = defaultMain [ bspscQueueBench ]

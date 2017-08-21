{-# LANGUAGE ScopedTypeVariables #-}

module Bench.BSPSCQueue where

import Control.Concurrent
import Control.Concurrent.MVar
import Control.Monad
import Control.Monad.Primitive
import Criterion.Main
import Data.Vector.Primitive.Mutable
import ReactiveStreams.BSPSCQueue

bspscQueueBench :: Benchmark
bspscQueueBench = bgroup "BSPSCQueue"
  [ bench "delivering 100000 messages with 100 message buffer" $ nfIO $ do
      let messageCount = 100000 :: Int
          bufferSize = 100
      (queue :: BSPSCQueue MVector (PrimState IO) Int) <- newQueue bufferSize
      receiverLock <- newEmptyMVar
      void $ forkIO $ forM_ [1..messageCount] $ const $ enqueue queue 0
      void $ forkIO $ do
        forM_ [1..messageCount] $ const $ dequeue queue
        putMVar receiverLock ()
      void $ takeMVar receiverLock
      return ()
  ]

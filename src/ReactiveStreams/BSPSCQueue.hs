{-# LANGUAGE RecordWildCards #-}

module ReactiveStreams.BSPSCQueue
  ( BSPSCQueue
  , newQueue
  , enqueue
  , dequeue
  ) where

import Control.Exception
import Control.Monad
import Control.Monad.Primitive
import Control.Monad.STM
import Control.Concurrent.STM.TVar
import Data.Primitive.MutVar
import Data.Vector.Generic.Mutable as V

-- | Bounded (blocking) single-producer single-consumer queue.
data BSPSCQueue v s a = BSPSCQueue
  { _queue :: !(v s a)
  , _start :: !(MutVar s Int)
  , _end   :: !(MutVar s Int)
  , _count :: !(TVar Int)
  }

newQueue :: MVector v a => Int -> IO (BSPSCQueue v (PrimState IO) a)
newQueue capacity = do
  queue    <- unsafeNew capacity
  startVar <- newMutVar 0
  endVar   <- newMutVar 0
  countVar <- newTVarIO 0
  return BSPSCQueue { _queue = queue
                    , _start = startVar
                    , _end   = endVar
                    , _count = countVar
                    }

waitTVar :: TVar a -> (a -> Bool) -> IO ()
waitTVar var f = do
  val <- readTVarIO var
  unless (f val) $ atomically $ do
    val' <- readTVar var
    unless (f val') retry

enqueue :: MVector v a => BSPSCQueue v (PrimState IO) a -> a -> IO ()
enqueue BSPSCQueue {..} a = do
  waitTVar _count (\cnt -> cnt < V.length _queue)
  end <- readMutVar _end
  V.write _queue end a
  mask_ $ do
    writeMutVar _end $ if end + 1 < V.length _queue then end + 1 else 0
    atomically $ modifyTVar' _count succ

dequeue :: MVector v a => BSPSCQueue v (PrimState IO) a -> IO a
dequeue BSPSCQueue {..} = do
  waitTVar _count (> 0)
  start <- readMutVar _start
  a <- V.read _queue start
  mask_ $ do
    writeMutVar _start $ if start + 1 < V.length _queue then start + 1 else 0
    atomically $ modifyTVar' _count pred
  return a

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}

module ReactiveStreams.BSPSCQueue
  ( BSPSCQueue
  , newQueue
  , enqueue
  , dequeue
  ) where

import           Control.Concurrent.MVar
import           Control.Concurrent.STM.TVar
import           Control.Exception
import           Control.Monad
import           Control.Monad.Primitive
import           Control.Monad.STM
import           Data.IORef
import           Data.Primitive.MutVar
import           Data.Vector.Generic.Mutable as V
import      Data.Atomics


-- Это намного медленнее, чем unagi-chan, плюс не решает задачи.
-- Основная задача - придумать, как держать заполненным буфер
-- сообщений от производителя (нужно вовремя посылать ему сигнал на догрузку
-- данных). Сам буффер может быть unbounded канал из unagi-chan, либо
-- TQueue (он не на много медленне).

-- | Bounded (blocking) single-producer single-consumer queue.
data BSPSCQueue v a = BSPSCQueue
  { _queue          :: !(v (PrimState IO) a)
  , _start          :: !(IORef Int) -- accessed by reader only
  , _end            :: !(IORef Int) -- accessed by writer only
  , _count          :: !(IORef Int) -- accessed by writer only
  , _nonEmptySignal :: !(MVar ())
  , _nonFullSignal  :: !(MVar ())
  }

newQueue :: MVector v a => Int -> IO (BSPSCQueue v a)
newQueue capacity = do
  queue       <- unsafeNew capacity
  startVar    <- newIORef 0
  endVar      <- newIORef 0
  countVar    <- newIORef 0
  nonEmpryVar <- newEmptyMVar
  nonFullVar  <- newMVar ()
  return BSPSCQueue { _queue = queue
                    , _start = startVar
                    , _end   = endVar
                    , _count = countVar
                    , _nonEmptySignal = nonEmpryVar
                    , _nonFullSignal = nonFullVar
                    }

enqueue :: MVector v a => BSPSCQueue v a -> a -> IO ()
enqueue BSPSCQueue {..} a = do
  waitNotFull             -- ожидаем неполную очередь
  end <- readIORef _end
  V.write _queue end a    -- дописываем данные в конец очереди.
  oldCount <- atomicModifyIORefCAS _count (\count -> (count + 1, count))
  when (oldCount == 0) $ putMVar _nonEmptySignal () -- если count был 0, посылаем сигнал "не пустая"
  writeIORef _end $ if end + 1 < V.length _queue then end + 1 else 0 -- модифицируем указатель конца очереди
  where
    waitNotFull = do
      count <- readIORef _count -- берем count
      unless (count < V.length _queue) $ do
         -- putStrLn "enqueue lock"
         void $ takeMVar _nonFullSignal -- если очередь заполнена, ждём сигнал "не полная"

dequeue :: MVector v a => BSPSCQueue v a -> IO a
dequeue BSPSCQueue {..} = do
  waitNonEmpty
  start <- readIORef _start
  a <- V.read _queue start
  oldCount <- atomicModifyIORefCAS _count (\count -> (count - 1, count))
  when (oldCount == V.length _queue) $ putMVar _nonFullSignal ()
  writeIORef _start $ if start + 1 < V.length _queue then start + 1 else 0
  return a
  where
    waitNonEmpty = do
      count <- readIORef _count -- берем count
      unless (count > 0) $ do
        -- putStrLn "dequeue lock"
        void $ takeMVar _nonEmptySignal -- если очередь заполнена, ждём сигнал "не пустая"

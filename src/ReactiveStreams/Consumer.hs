{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RecordWildCards       #-}

module ReactiveStreams.Consumer where

import           Control.Monad.Primitive
import           Data.Bits
import           Data.Vector.Generic.Mutable as V
import           Data.IORef
import           Control.Concurrent.MVar
import           Control.Monad
import Control.Concurrent.Chan.Unagi

data Consumer a = NeedInput (a -> Consumer a)
                | Done

data Producer a = HasOutput a

data ProducerSignal =  Request Word | Cancel

-- можно разбить на producer-side и consumer-side подписки, т.к. не все элементы у
-- них общие и им не обязательно находиться рядом.
data ConsumerQueue v a  = ConsumerQueue
  { _queue             :: !(v (PrimState IO) a)
  , _queueMask         :: !Word  -- маска всегда на 1 меньше, чем capacity, этим можно пользоваться чтобы не вызывать length, который может быть полиморфным
  , _enqueued          :: !(IORef Word)
  , _producerCounter   :: !(IORef Word)
  , _consumerCounter   :: !(IORef Word)
  , _queueEmptyLock    :: !(MVar ()) -- TODO возможно сюда добавится сигнальная система например Next/Error/Complete от публикатора
  , _producerInChan    :: !(InChan ProducerSignal)
  , _producerOutChan   :: !(OutChan ProducerSignal)
  -- TODO: нужен канал до продъюсера, который умеет request и cancel
  }

nextPowerOf2 :: Word -> Word
nextPowerOf2 a =
  if a .&. (a - 1) == 0
    then a
    else f a `unsafeShiftL` 1
  where
    f a =
      let c = a .&. (a - 1) in
      if c /= 0 then f c else a

newConsumerQueue :: MVector v a => Word -> IO (ConsumerQueue v a)
newConsumerQueue capacity = do
  queue <- unsafeNew $ fromIntegral roundedCapacity
  enqueued <-  newIORef 0
  procuderCounter <- newIORef 0
  consumerCounter <- newIORef 0
  queueEmptyLock  <- newEmptyMVar
  (producerInChan, producerOutChan) <- newChan
  return ConsumerQueue
    { _queue = queue
    , _queueMask = roundedCapacity - 1
    , _enqueued = enqueued
    , _queueEmptyLock = queueEmptyLock
    , _producerCounter = procuderCounter
    , _consumerCounter = consumerCounter
    , _producerInChan = producerInChan
    , _producerOutChan = producerOutChan
    }
  where
    roundedCapacity = nextPowerOf2 capacity

blockingRead :: MVector v a => ConsumerQueue v a -> IO (a, Word)
blockingRead ConsumerQueue{..} = do
  enqueued <- readIORef _enqueued
  when (enqueued == 0) $ takeMVar _queueEmptyLock


  (produced, consumed) <- waitNonEmpty
  item <- unsafeRead _queue $ fromIntegral (consumed .&. _queueMask)
  writeIORef _consumerCounter (consumed + 1)
  return (item, fromIntegral (V.length _queue) - (produced - consumed + 1))
  where
    waitNonEmpty = do
      consumed <- readIORef _consumerCounter
      produced <- readIORef _producerCounter
      if produced /= consumed
        then return (produced, consumed)
        else do
          takeMVar _queueEmptyLock -- инвариант "нас отпустили": newProduced содержит значение, которое строго больше consumed
          newProduced <- readIORef _producerCounter
          return (newProduced, consumed)

nonblockinWrite :: MVector v a => ConsumerQueue v a -> a -> IO ()
nonblockinWrite ConsumerQueue{..} item = do
  produced <- readIORef _producerCounter
  unsafeWrite _queue (fromIntegral ((produced + 1) .&. _queueMask)) item
  consumed <- readIORef _consumerCounter
  writeIORef _producerCounter (produced + 1) -- может зайти читатеть, вычитать что мы только что записали и встать на блокеровке в ожидании следующей записи.
  when (produced == consumed) $ void $ tryPutMVar _queueEmptyLock ()

producerLoop :: ConsumerQueue v a -> Producer a -> IO ()
producerLoop ConsumerQueue{..} = go
  where
    go producer = do
      signal <- readChan _producerOutChan
      case signal of
        Request n -> batch producer n
        Cancel -> return ()

    batch producer 0 = go producer
    batch (HasOutput a) n = undefined

consumerLoop :: ConsumerQueue v a -> Consumer a -> IO ()
consumerLoop queue = go
  where
    go Done = undefined
    go (NeedInput f) = undefined

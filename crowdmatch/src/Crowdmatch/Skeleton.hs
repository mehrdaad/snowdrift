{-# LANGUAGE TypeFamilies #-}

-- | This is the closet, where we keep the skeletons.
--
-- Esqueleto produces the most wicked type errors when things go awry.
-- Spooky! But given the alternatives of using rawSql (and thus losing the
-- best of type safety when building sql), or using plain ol' persistent
-- and doing all the relational logic in Haskell (how depressing), I will
-- reluctantly stick with Esqueleto. Its use will merely be sequestered
-- in this module (alternate name: Model.Sequestro!)
module Crowdmatch.Skeleton where

import Control.Error hiding (isNothing, just)
import Control.Lens ((%~), _1, _2)
import Control.Monad.IO.Class (MonadIO)
import Data.Time (UTCTime)
import Database.Esqueleto

import Crowdmatch.Model

{-# ANN module ("HLint: ignore Redundant bracket" :: String) #-}

-- | Retrieve the history of donations to the project
projectDonationHistory :: MonadIO m => SqlPersistT m [(HistoryTime, Int)]
projectDonationHistory =
    fmap (map ((_1 %~ unValue) . (_2 %~ fromMaybe 0 . unValue))) $
    select $
    from $ \dh -> do
        groupBy (time dh)
        orderBy [asc (time dh)]
        pure (time dh, total dh)
  where
    time = (^. DonationHistoryTime)
    total = sum_ . (^. DonationHistoryAmount)

-- | Patrons actively pledged to Snowdrift since before a given time
activePatrons :: MonadIO m => UTCTime -> SqlPersistT m [Entity Patron]
activePatrons t =
    select $
    from $ \p -> do
        where_ (activePatron p)
        return p
  where
    activePatron p = p ^. PatronPledgeSince <. just (val t)

-- | Patrons with outstanding donation balances.
patronsReceivable :: MonadIO m => DonationUnits -> SqlPersistT m [Entity Patron]
patronsReceivable minBal =
    select $
    from $ \p -> do
        where_ (not_ (isNothing (p ^. PatronPaymentToken))
            &&. (p ^. PatronDonationPayable >=. val minBal))
        return p

sumField
  :: ( PersistEntityBackend val ~ SqlBackend
     , PersistEntity val
     , PersistField a
     , Num a
     , MonadIO m
     )
     => EntityField val a
     -> SqlPersistT m a
sumField f = do
    [row] <-
        select $
        from $ \entity ->
            return $ coalesceDefault [sum_ (entity ^. f)] $ val 0
    return $ unValue row

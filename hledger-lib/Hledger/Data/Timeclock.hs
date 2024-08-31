{-|

A 'TimeclockEntry' is a clock-in, clock-out, or other directive in a timeclock
file (see timeclock.el or the command-line version). These can be
converted to 'Transactions' and queried like a ledger.

-}

{-# LANGUAGE OverloadedStrings #-}

module Hledger.Data.Timeclock (
   timeclockEntriesToTransactions
  ,tests_Timeclock
)
where

import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time.Calendar (addDays)
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.Time.LocalTime (LocalTime(..), TimeOfDay(..), getCurrentTimeZone,
                            localTimeToUTC, midnight, utc, utcToLocalTime)
import Text.Printf (printf)

import Hledger.Utils
import Hledger.Data.Types
import Hledger.Data.Dates
import Hledger.Data.Amount
import Hledger.Data.Posting

instance Show TimeclockEntry where
    show t = printf "%s %s %s  %s" (show $ tlcode t) (show $ tldatetime t) (tlaccount t) (tldescription t)

instance Show TimeclockCode where
    show SetBalance = "b"
    show SetRequiredHours = "h"
    show In = "i"
    show Out = "o"
    show FinalOut = "O"

instance Read TimeclockCode where
    readsPrec _ ('b' : xs) = [(SetBalance, xs)]
    readsPrec _ ('h' : xs) = [(SetRequiredHours, xs)]
    readsPrec _ ('i' : xs) = [(In, xs)]
    readsPrec _ ('o' : xs) = [(Out, xs)]
    readsPrec _ ('O' : xs) = [(FinalOut, xs)]
    readsPrec _ _ = []

-- | Convert time log entries to journal transactions. When there is no
-- clockout, add one with the provided current time. Sessions crossing
-- midnight are split into days to give accurate per-day totals.
timeclockEntriesToTransactions :: LocalTime -> [TimeclockEntry] -> [Transaction]
timeclockEntriesToTransactions _ [] = []
timeclockEntriesToTransactions now [i]
    | tlcode i /= In = errorExpectedCodeButGot In i
    | odate > idate = entryFromTimeclockInOut i o' : timeclockEntriesToTransactions now [i',o]
    | otherwise = [entryFromTimeclockInOut i o]
    where
      o = TimeclockEntry (tlsourcepos i) Out end "" "" "" []
      end = if itime > now then itime else now
      (itime,otime) = (tldatetime i,tldatetime o)
      (idate,odate) = (localDay itime,localDay otime)
      o' = o{tldatetime=itime{localDay=idate, localTimeOfDay=TimeOfDay 23 59 59}}
      i' = i{tldatetime=itime{localDay=addDays 1 idate, localTimeOfDay=midnight}}
timeclockEntriesToTransactions now (i:o:rest)
    | tlcode i /= In  = errorExpectedCodeButGot In i
    | tlcode o /= Out = errorExpectedCodeButGot Out o
    | odate > idate   = entryFromTimeclockInOut i o' : timeclockEntriesToTransactions now (i':o:rest)
    | otherwise       = entryFromTimeclockInOut i o : timeclockEntriesToTransactions now rest
    where
      (itime,otime) = (tldatetime i,tldatetime o)
      (idate,odate) = (localDay itime,localDay otime)
      o' = o{tldatetime=itime{localDay=idate, localTimeOfDay=TimeOfDay 23 59 59}}
      i' = i{tldatetime=itime{localDay=addDays 1 idate, localTimeOfDay=midnight}}
{- HLINT ignore timeclockEntriesToTransactions -}

errorExpectedCodeButGot :: TimeclockCode -> TimeclockEntry -> a
errorExpectedCodeButGot expected actual = error' $ printf
  ("%s:\n%s\n%s\n\nExpected a timeclock %s entry but got %s.\n"
  ++"Only one session may be clocked in at a time.\n"
  ++"Please alternate i and o, beginning with i.")
  (sourcePosPretty $ tlsourcepos actual)
  (l ++ " | " ++ show actual)
  (replicate (length l) ' ' ++ " |" ++ replicate c ' ' ++ "^")
  (show expected)
  (show $ tlcode actual)
  where
    l = show $ unPos $ sourceLine $ tlsourcepos actual
    c = unPos $ sourceColumn $ tlsourcepos actual

-- | Convert a timeclock clockin and clockout entry to an equivalent journal
-- transaction, representing the time expenditure. Note this entry is  not balanced,
-- since we omit the \"assets:time\" transaction for simpler output.
entryFromTimeclockInOut :: TimeclockEntry -> TimeclockEntry -> Transaction
entryFromTimeclockInOut i o
    | otime >= itime = t
    | otherwise =
      -- Clockout time earlier than clockin is an error.
      -- (Clockin earlier than preceding clockin/clockout is allowed.)
      error' $ printf
        ("%s:\n%s\nThis clockout time (%s) is earlier than the previous clockin.\n"
        ++"Please adjust it to be later than %s.")
        (sourcePosPretty $ tlsourcepos o)
        (unlines [
          replicate (length l) ' '++ " | " ++ show i,
          l ++ " | " ++ show o,
          (replicate (length l) ' ' ++ " |" ++ replicate c ' ' ++ replicate 19 '^')
          ])
        (show $ tldatetime o)
        (show $ tldatetime i)
    where
      l = show $ unPos $ sourceLine $ tlsourcepos o
      c = (unPos $ sourceColumn $ tlsourcepos o) + 2
      t = Transaction {
            tindex       = 0,
            tsourcepos   = (tlsourcepos i, tlsourcepos i),
            ttimestamp   = Nothing,
            tdate        = idate,
            tdate2       = Nothing,
            tstatus      = Cleared,
            tcode        = "",
            tdescription = desc,
            tcomment     = tlcomment i,
            ttags        = tltags i,
            tpostings    = ps,
            tprecedingcomment=""
          }
      itime    = tldatetime i
      otime    = tldatetime o
      itod     = localTimeOfDay itime
      otod     = localTimeOfDay otime
      idate    = localDay itime
      desc     | T.null (tldescription i) = T.pack $ showtime itod ++ "-" ++ showtime otod
               | otherwise                = tldescription i
      showtime = take 5 . show
      hours    = elapsedSeconds (toutc otime) (toutc itime) / 3600 where toutc = localTimeToUTC utc
      acctname = tlaccount i
      -- Generate an hours amount. Unusually, we also round the internal Decimal value,
      -- since otherwise it will often have large recurring decimal parts which (since 1.21)
      -- print would display all 255 digits of. timeclock amounts have one second resolution,
      -- so two decimal places is precise enough (#1527).
      amt   = mixedAmount $ setAmountInternalPrecision 2 $ hrs hours
      ps       = [posting{paccount=acctname, pamount=amt, ptype=VirtualPosting, ptransaction=Just t}]


-- tests

tests_Timeclock = testGroup "Timeclock" [
  testCaseSteps "timeclockEntriesToTransactions tests" $ \step -> do
      step "gathering data"
      today <- getCurrentDay
      now' <- getCurrentTime
      tz <- getCurrentTimeZone
      let now = utcToLocalTime tz now'
          nowstr = showtime now
          yesterday = prevday today
          clockin = TimeclockEntry (initialPos "") In
          mktime d = LocalTime d . fromMaybe midnight .
                     parseTimeM True defaultTimeLocale "%H:%M:%S"
          showtime = formatTime defaultTimeLocale "%H:%M"
          txndescs = map (T.unpack . tdescription) . timeclockEntriesToTransactions now
          future = utcToLocalTime tz $ addUTCTime 100 now'
          futurestr = showtime future
      step "started yesterday, split session at midnight"
      txndescs [clockin (mktime yesterday "23:00:00") "" "" "" []] @?= ["23:00-23:59","00:00-"++nowstr]
      step "split multi-day sessions at each midnight"
      txndescs [clockin (mktime (addDays (-2) today) "23:00:00") "" "" "" []] @?= ["23:00-23:59","00:00-23:59","00:00-"++nowstr]
      step "auto-clock-out if needed"
      txndescs [clockin (mktime today "00:00:00") "" "" "" []] @?= ["00:00-"++nowstr]
      step "use the clockin time for auto-clockout if it's in the future"
      txndescs [clockin future "" "" "" []] @?= [printf "%s-%s" futurestr futurestr]
 ]

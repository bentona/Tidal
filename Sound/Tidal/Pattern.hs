{-# LANGUAGE DeriveDataTypeable #-}

module Sound.Tidal.Pattern where

import Control.Applicative
import Data.Monoid
import Data.Fixed
import Data.List
import Data.Maybe
import Data.Ratio
import Debug.Trace
import Data.Typeable
import Data.Function
import System.Random.Mersenne.Pure64

import Sound.Tidal.Time
import Sound.Tidal.Utils

data Pattern a = Pattern {arc :: Arc -> [Event a]}

instance (Show a) => Show (Pattern a) where
  show p@(Pattern _) = show $ arc p (0, 1)
  
instance Functor Pattern where
  fmap f (Pattern a) = Pattern $ fmap (fmap (mapSnd f)) a

instance Applicative Pattern where
  pure x = Pattern $ \(s, e) -> map 
                                (\t -> ((t%1, (t+1)%1), x)) 
                                [floor s .. ((ceiling e) - 1)]
  (Pattern fs) <*> (Pattern xs) = 
    Pattern $ \a -> concatMap applyX (fs a)
    where applyX ((s,e), f) = 
            map (\(_, x) -> ((s,e), f x)) 
                (filter 
                 (\(a', _) -> isIn a' s)
                 (xs (s,e))
                )

instance Monoid (Pattern a) where
    mempty = silence
    mappend x y = Pattern $ \a -> (arc x a) ++ (arc y a)

instance Monad Pattern where
  return = pure
  p >>= f = 
    Pattern (\a -> concatMap
                   (\((s,e), x) -> mapFsts (const (s,e)) $
                                   filter
                                   (\(a', _) -> isIn a' s)
                                   (arc (f x) (s,e))
                   )
                   (arc p a)
             )

atom :: a -> Pattern a
atom = pure

silence :: Pattern a
silence = Pattern $ const []

mapQueryArc :: (Arc -> Arc) -> Pattern a -> Pattern a
mapQueryArc f p = Pattern $ \a -> arc p (f a)

mapQueryTime :: (Time -> Time) -> Pattern a -> Pattern a
mapQueryTime = mapQueryArc . mapArc

mapResultArc :: (Arc -> Arc) -> Pattern a -> Pattern a
mapResultArc f p = Pattern $ \a -> mapFsts f $ arc p a

mapResultTime :: (Time -> Time) -> Pattern a -> Pattern a
mapResultTime = mapResultArc . mapArc

overlay :: Pattern a -> Pattern a -> Pattern a
overlay p p' = Pattern $ \a -> (arc p a) ++ (arc p' a)

(>+<) = overlay

stack :: [Pattern a] -> Pattern a
stack ps = foldr overlay silence ps

cat :: [Pattern a] -> Pattern a
cat ps = density (fromIntegral $ length ps) $ slowcat ps

append :: Pattern a -> Pattern a -> Pattern a
append a b = cat [a,b]

append' :: Pattern a -> Pattern a -> Pattern a
append' a b  = slow 2 $ cat [a,b]

slowcat' ps = Pattern $ \a -> concatMap f (arcCycles a)
  where l = length ps
        f (s,e) = arc p (s,e)
          where p = ps !! n
                n = (floor s) `mod` l

-- Concatenates so that the first loop of each pattern is played in
-- turn, second loop of each pattern, and so on..

slowcat :: [Pattern a] -> Pattern a
slowcat [] = silence
slowcat ps = Pattern $ \a -> concatMap f (arcCycles a)
  where l = length ps
        f (s,e) = arc (mapResultTime (+offset) p) (s',e')
          where p = ps !! n
                r = (floor s) :: Int
                n = (r `mod` l) :: Int
                offset = (fromIntegral $ r - ((r - n) `div` l)) :: Time
                (s', e') = (s-offset, e-offset)

listToPat :: [a] -> Pattern a
listToPat = cat . map atom

run n = listToPat [0 .. n-1]

maybeListToPat :: [Maybe a] -> Pattern a
maybeListToPat = cat . map f
  where f Nothing = silence
        f (Just x) = atom x

density :: Time -> Pattern a -> Pattern a
density 0 p = p
density 1 p = p
density r p = mapResultTime (/ r) $ mapQueryTime (* r) p

slow :: Time -> Pattern a -> Pattern a
slow 0 = id
slow t = density (1/t) 

(<~) :: Time -> Pattern a -> Pattern a
(<~) t p = filterOffsets $ mapResultTime (+ t) $ mapQueryTime (subtract t) p

(~>) :: Time -> Pattern a -> Pattern a
(~>) = (<~) . (0-)

rev :: Pattern a -> Pattern a
rev p = Pattern $ \a -> concatMap 
                        (\a' -> mapFsts mirrorArc $ 
                                (arc p (mirrorArc a')))
                        (arcCycles a)

when :: (Int -> Bool) -> (Pattern a -> Pattern a) ->  Pattern a -> Pattern a
when test f p = Pattern $ \a -> concatMap apply (arcCycles a)
  where apply a | test (floor $ fst a) = (arc $ f p) a
                | otherwise = (arc p) a

every :: Int -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
every 0 f p = p
every n f p = when ((== 0) . (`mod` n)) f p

palindrome :: Pattern a -> Pattern a
palindrome p = slowcat [p, rev p]

sig :: (Time -> a) -> Pattern a
sig f = Pattern f'
  where f' (s,e) | s > e = []
                 | otherwise = [((s,e), f s)]

sinewave :: Pattern Double
sinewave = sig $ \t -> sin $ pi * 2 * (fromRational t)
sine = sinewave
ratsine = fmap toRational sine

sinewave1 :: Pattern Double
sinewave1 = fmap ((/ 2) . (+ 1)) sinewave
sine1 = sinewave1
ratsine1 = fmap toRational sine1

sinePhase1 :: Double -> Pattern Double
sinePhase1 offset = (+ offset) <$> sinewave1

triwave1 :: Pattern Double
triwave1 = sig $ \t -> mod' (fromRational t) 1
tri1 = triwave1
rattri1 = fmap toRational tri1

triwave :: Pattern Double
triwave = ((subtract 1) . (* 2)) <$> triwave1
tri = triwave
rattri = fmap toRational tri

squarewave1 :: Pattern Double
squarewave1 = sig $ 
              \t -> fromIntegral $ floor $ (mod' (fromRational t) 1) * 2
square1 = squarewave1

squarewave :: Pattern Double
squarewave = ((subtract 1) . (* 2)) <$> squarewave1
square = squarewave

-- Filter out events that start before range
filterOffsets :: Pattern a -> Pattern a
filterOffsets (Pattern f) = 
  Pattern $ \(s, e) -> filter ((>= s) . eventStart) $ f (s, e)

seqToRelOnsets :: Arc -> Pattern a -> [(Double, a)]
seqToRelOnsets (s, e) p = mapFsts (fromRational . (/ (e-s)) . (subtract s) . fst) $ arc (filterOffsets p) (s, e)

segment :: Pattern a -> Pattern [a]
segment p = Pattern $ \(s,e) -> filter (\((s',e'),_) -> s' < e && e' > s) $ groupByTime (segment' (arc p (s,e)))

segment' :: [Event a] -> [Event a]
segment' es = foldr split es pts
  where pts = nub $ points es

split :: Time -> [Event a] -> [Event a]
split _ [] = []
split t ((ev@((s,e), v)):es) | t > s && t < e = ((s,t),v):((t,e),v):(split t es)
                             | otherwise = ev:split t es

points :: [Event a] -> [Time]
points [] = []
points (((s,e), _):es) = s:e:(points es)

groupByTime :: [Event a] -> [Event [a]]
groupByTime es = map mrg $ groupBy ((==) `on` fst) $ sortBy (compare `on` fst) es
  where mrg es@((a, _):_) = (a, map snd es)

ifp :: (Int -> Bool) -> (Pattern a -> Pattern a) -> (Pattern a -> Pattern a) -> Pattern a -> Pattern a
ifp test f1 f2 p = Pattern $ \a -> concatMap apply (arcCycles a)
  where apply a | test (floor $ fst a) = (arc $ f1 p) a
                | otherwise = (arc $ f2 p) a

rand :: Pattern Double
rand = Pattern $ \a -> [(a, fst $ randomDouble $ pureMT $ floor $ (*1000000) $ (midPoint a))]

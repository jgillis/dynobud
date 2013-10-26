{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}

module Vectorize ( Vectorize(..)
                 , GVectorize(..)
                 , Generic1
                 , None(..)
                 , vlength
                 , fill
                 ) where


import qualified GHC.Generics as G
import GHC.Generics hiding ( D1, (:+:), (:*:) )
import qualified Data.Vector as V

data None a = None deriving (Generic1, Functor, Show)
instance Vectorize None

fill :: Vectorize f => a -> f a
fill x = fmap (const x) empty

-- | fmap f == devectorize . (V.map f) . vectorize
class Functor f => Vectorize (f :: * -> *) where
  vectorize :: f a -> V.Vector a
  devectorize :: V.Vector a -> f a
  empty :: f ()

  default vectorize :: (Generic1 f, GVectorize (Rep1 f)) => f a -> V.Vector a
  vectorize f = gvectorize (from1 f)

  default devectorize :: (Generic1 f, GVectorize (Rep1 f)) => V.Vector a -> f a
  devectorize f = to1 (gdevectorize f)

  default empty :: (Generic1 f, GVectorize (Rep1 f)) => f ()
  empty = to1 gempty

class GVectorize (f :: * -> *) where
  gvectorize :: f a -> V.Vector a
  gdevectorize :: V.Vector a -> f a
  gempty :: f ()

vlength :: Vectorize f => f a -> Int
vlength = V.length . vectorize . (empty `asFunctorOf`)
  where
    asFunctorOf :: f a -> f b -> f a
    asFunctorOf x _ = x

gvlength :: GVectorize f => f a -> Int
gvlength = V.length . gvectorize . (gempty `asFunctorOf`)
  where
    asFunctorOf :: f a -> f b -> f a
    asFunctorOf x _ = x

instance (GVectorize f, GVectorize g) => GVectorize (f G.:*: g) where
  gvectorize (f G.:*: g) = gvectorize f V.++ gvectorize g
  gdevectorize v0s
    | V.length v0s < n0 =
      error $ "gdevectorize (f :*: g): V.length v0s < vlength f0"
    | V.length v1 /= n1 =
      error $ "gdevectorize (f :*: g): V.length v1 /= vlength f1"
    | otherwise = f0 G.:*: f1
    where
      f0 = gdevectorize v0
      f1 = gdevectorize v1

      n0 = gvlength f0
      n1 = gvlength f1

      (v0,v1) = V.splitAt n0 v0s

  gempty = gempty G.:*: gempty

-- Metadata (constructor name, etc)
instance GVectorize f => GVectorize (M1 i c f) where
  gvectorize = gvectorize . unM1
  gdevectorize = M1 . gdevectorize
  gempty = M1 gempty

instance GVectorize Par1 where
  gvectorize = V.singleton . unPar1
  gdevectorize v = case V.toList v of
    [] -> error "gdevectorize Par1: got empty list"
    [x] -> Par1 x
    xs -> error $ "gdevectorize Par1: got non-1 length: " ++ show (length xs)
  gempty = Par1 ()

-- data with no fields
instance GVectorize U1 where
  gvectorize = const V.empty
  gdevectorize v
    | V.null v = U1
    | otherwise = error $ "gdevectorize U1: got non-null vector, length: " ++ show (V.length v)
  gempty = U1

-- Constants, additional parameters, and rank-1 recursion
instance Vectorize f => GVectorize (Rec1 f) where
  gvectorize = vectorize . unRec1
  gdevectorize = Rec1 . devectorize
  gempty = Rec1 empty

instance (Vectorize f, GVectorize g) => GVectorize (f :.: g) where
  gempty = Comp1 ret
    where
      ret = devectorize $ V.replicate k gempty
      k = vlength ret
  gvectorize = V.concatMap gvectorize . (vectorize . unComp1)
  gdevectorize v = Comp1 ret
    where
      -- ret :: f (g a)
      ret = devectorize vs

      kf = vlength ret
      kg = gvlength (insideOf vs)

      insideOf :: V.Vector (g a) -> g a
      insideOf _ = undefined

      -- vs :: V.Vector (g a)
      vs = fmap gdevectorize (splitsAt kg kf v {-:: Vec nf (Vec ng a)-} )


-- break a vector jOuter vectors, each of length kInner
splitsAt' :: Int -> Int -> V.Vector a -> [V.Vector a]
splitsAt' 0 jOuter v
  | V.null v = replicate jOuter V.empty
  | otherwise = error $ "splitsAt 0 " ++ show jOuter ++ ": got non-zero vector"
splitsAt' kInner 0 v
  | V.null v = []
  | otherwise = error $ "splitsAt " ++ show kInner ++ " 0: leftover vector of length: " ++ show (V.length v)
splitsAt' kInner jOuter v
  | kv0 < kInner =
    error $ "splitsAt " ++ show kInner ++ " " ++ show jOuter ++ ": " ++ "ran out of vector input"
  | otherwise = v0 : splitsAt' kInner (jOuter - 1) v1
  where
    kv0 = V.length v0
    (v0,v1) = V.splitAt kInner v

-- break a vector jOuter vectors, each of length kInner
splitsAt :: Int -> Int -> V.Vector a -> V.Vector (V.Vector a)
splitsAt k j = V.fromList . splitsAt' k j

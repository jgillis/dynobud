{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module VectorizeTests
       ( Vectorizes(..)
       , Dims(..)
       , vectorizeTests
       ) where

import GHC.Generics ( Generic, Generic1 )
import GHC.TypeLits

import Data.Proxy ( Proxy(..) )
import qualified Data.Vector as V
import Linear

import qualified Test.HUnit.Base as HUnit
import Test.QuickCheck
import Test.Framework ( Test, testGroup )
import Test.Framework.Providers.HUnit ( testCase )
import Test.Framework.Providers.QuickCheck2 ( testProperty )

import Dyno.View.Vectorize
import Dyno.TypeVecs ( Vec )
import qualified Dyno.TypeVecs as TV

import Utils


data X0 a
  = X0 a (V3 a) a (V2 a)
  deriving (Show, Eq, Functor, Foldable, Traversable, Generic, Generic1)
data X1 f g h a
  = X1 (f a) (V3 (g a)) a (V2 a) a (h a)
  deriving (Show, Eq, Functor, Foldable, Traversable, Generic, Generic1)

instance Vectorize X0
instance Applicative X0 where {pure = vpure; (<*>) = vapply}
instance (Vectorize f, Vectorize g, Vectorize h) => Vectorize (X1 f g h)
instance (Vectorize f, Vectorize g, Vectorize h) => Applicative (X1 f g h) where
  {pure = vpure; (<*>) = vapply}

data Vectorizes where
  Vectorizes ::
    (Show (f Int), Eq (f Int), Vectorize f, Applicative f, Traversable f)
    => { vShrinks :: [Vectorizes]
       , vName :: String
       , vProxy :: Proxy f } -> Vectorizes


data Dims where
  Dims :: KnownNat n =>
           { dShrinks :: [Dims]
           , dProxy :: Proxy (n :: Nat)
           } -> Dims
instance Show Dims where
  show (Dims _ p) = show (natVal p)

instance Arbitrary Dims where
  arbitrary = elements [ d0, d1, d2, d3, d4, d10, d100 ]
    where
      d0   = Dims []                   (Proxy :: Proxy 0)
      d1   = Dims [d0]                 (Proxy :: Proxy 1)
      d2   = Dims [d0,d1]              (Proxy :: Proxy 2)
      d3   = Dims [d0,d1,d2]           (Proxy :: Proxy 3)
      d4   = Dims [d0,d1,d2,d3]        (Proxy :: Proxy 4)
      d10  = Dims [d0,d1,d2,d3,d4]     (Proxy :: Proxy 10)
      d100 = Dims [d0,d1,d2,d3,d4,d10] (Proxy :: Proxy 100)
  shrink = dShrinks

instance Show Vectorizes where
  show = vName

maxVSize :: Int
maxVSize = 1000

instance Arbitrary Vectorizes where
  arbitrary = do
    x <- oneof [primitives, compounds primitives, compounds (compounds primitives)]
    if vecSize x <= maxVSize then return x else arbitrary
  shrink = filter ((<= maxVSize) . vecSize) . shrink' True
    where
      shrink' True v = vShrinks v ++ concatMap (shrink' False) (vShrinks v)
      shrink' False v = vShrinks v

vecSize :: Vectorizes -> Int
vecSize (Vectorizes _ _ p) = vlength p

primitives :: Gen Vectorizes
primitives = do
  d <- arbitrary
  elements
    [ Vectorizes [] "None" (Proxy :: Proxy None)
    , Vectorizes [] "Id" (Proxy :: Proxy Id)
    , Vectorizes [] "V0" (Proxy :: Proxy V0)
    , Vectorizes [] "V1" (Proxy :: Proxy V1)
    , Vectorizes [] "V2" (Proxy :: Proxy V2)
    , Vectorizes [] "V3" (Proxy :: Proxy V3)
    , Vectorizes [] "V4" (Proxy :: Proxy V4)
    , Vectorizes [] "X0" (Proxy :: Proxy X0)
    , mkTypeVec True d
    ]

compounds :: Gen Vectorizes -> Gen Vectorizes
compounds genIt = do
  v1@(Vectorizes _ m1 p1) <- genIt
  v2@(Vectorizes _ m2 p2) <- genIt
  v3@(Vectorizes _ m3 p3) <- genIt
  elements
    [ Vectorizes
      { vShrinks = [v1, v2]
      , vName = "Tuple (" ++ m1 ++ ") (" ++ m2 ++ ")"
      , vProxy = reproxy2 (Proxy :: Proxy Tuple) p1 p2
      }
    , Vectorizes
      { vShrinks = [v1, v2, v3]
      , vName = "Triple (" ++ m1 ++ ") (" ++ m2 ++ ") (" ++ m3 ++ ")"
      , vProxy = reproxy3 (Proxy :: Proxy Triple) p1 p2 p3
      }
    , Vectorizes
      { vShrinks = [v1, v2, v3]
      , vName = "X1 (" ++ m1 ++ ") (" ++ m2 ++ ") " ++ m3 ++ ")"
      , vProxy = reproxy3 (Proxy :: Proxy X1) p1 p2 p3
      }
    ]

mkTypeVec :: Bool -> Dims -> Vectorizes
mkTypeVec shrinkThis d@(Dims _ pd) =
  Vectorizes
  { vShrinks = if shrinkThis then map (mkTypeVec False) (shrink d) else []
  , vName = "Vec " ++ show d
  , vProxy = reproxy (Proxy :: Proxy TV.Vec) pd
  }

fillInc :: forall x . Vectorize x => x Int
fillInc = devectorize $ V.fromList $ take (vlength (Proxy :: Proxy x)) [0..]

vectorizeThenDevectorize ::
  forall x
  . (Eq (x Int), Vectorize x)
  => Proxy x -> Bool
vectorizeThenDevectorize _ = case ex1 of
  Right x1 -> x0 == x1
  Left _ -> False
  where
    x0 :: x Int
    x0 = fillInc

    ex1 :: Either String (x Int)
    ex1 = devectorize' (vectorize x0)

prop_vecThenDevec :: Vectorizes -> Bool
prop_vecThenDevec (Vectorizes _ _ p) = vectorizeThenDevectorize p

vlengthEqLengthOfPure ::
  forall f
  . Vectorize f
  => Proxy f -> Bool
vlengthEqLengthOfPure p = vlength p == V.length x1
  where
    x0 :: f ()
    x0 = pure ()

    x1 :: V.Vector ()
    x1 = vectorize x0

prop_vlengthEqLengthOfPure :: Vectorizes -> Bool
prop_vlengthEqLengthOfPure (Vectorizes _ _ p) = vlengthEqLengthOfPure p

transposeUnTranspose ::
  forall n m
  . (KnownNat n, KnownNat m)
  => Proxy n -> Proxy m -> Bool
transposeUnTranspose _ _ = x0 == x2
  where
    n = fromIntegral (natVal (Proxy :: Proxy n))
    m = fromIntegral (natVal (Proxy :: Proxy m))

    x0 :: Vec n (Vec m Int)
    x0 = TV.mkVec' [TV.mkVec' [(j*m + k) | k <- [0..(m-1)]] | j <- [0..(n-1)]]

    x1 :: Vec m (Vec n Int)
    x1 = TV.tvtranspose x0

    x2 :: Vec n (Vec m Int)
    x2 = TV.tvtranspose x1

prop_transpose :: Dims -> Dims -> Bool
prop_transpose (Dims _ n) (Dims _ m) = transposeUnTranspose n m

sequenceATwice ::
  forall x y
  . ( Traversable x, Traversable y
    , Vectorize x, Vectorize y
    )
  => Proxy x -> Proxy y -> Bool
sequenceATwice _ _ = vectorize (O x0) == vectorize (O x2)
  where
    x0 :: x (y Int)
    O x0 = fillInc

    x1 :: y (x Int)
    x1 = sequenceA x0

    x2 :: x (y Int)
    x2 = sequenceA x1

prop_sequenceATwice :: Vectorizes -> Vectorizes -> Bool
prop_sequenceATwice (Vectorizes _ _ px) (Vectorizes _ _ py) = sequenceATwice px py

test_vdiag :: HUnit.Assertion
test_vdiag = HUnit.assertEqual "" x y
  where
    x :: V3 (V3 Int)
    x = V3
        (V3 7 0 0)
        (V3 0 8 0)
        (V3 0 0 9)

    y :: V3 (V3 Int)
    y = vdiag (V3 7 8 9)

test_vdiag' :: HUnit.Assertion
test_vdiag' = HUnit.assertEqual "" x y
  where
    x :: V3 (V3 Int)
    x = V3
        (V3 7 3 3)
        (V3 3 8 3)
        (V3 3 3 9)

    y :: V3 (V3 Int)
    y = vdiag' (V3 7 8 9) 3


test_vectorizeO :: HUnit.Assertion
test_vectorizeO = HUnit.assertEqual "" (vectorize x) y
  where
    x :: (V3 :. V2) Int
    x =
      O $
      V3
      (V2 0 1)
      (V2 2 3)
      (V2 4 5)

    y :: V.Vector Int
    y = V.fromList [0,1,2,3,4,5]

test_devectorizeO :: HUnit.Assertion
test_devectorizeO = HUnit.assertEqual "" x (devectorize y)
  where
    x :: (V3 :. V2) Int
    x =
      O $
      V3
      (V2 0 1)
      (V2 2 3)
      (V2 4 5)

    y :: V.Vector Int
    y = V.fromList [0,1,2,3,4,5]

test_pureO :: HUnit.Assertion
test_pureO = HUnit.assertEqual "" x y
  where
    x :: (V3 :. V2) Int
    x = pure 0

    y :: (V3 :. V2) Int
    y =
      O $
      V3
      (V2 0 0)
      (V2 0 0)
      (V2 0 0)


vectorizeTests :: Test
vectorizeTests =
  testGroup "vectorize tests"
  [ testProperty "vec . devec" prop_vecThenDevec
  , testProperty "transposeUnTranspose" prop_transpose
  , testProperty "vlengthEqLengthOfPure" prop_vlengthEqLengthOfPure
  , testProperty "sequenceA . sequenceA" prop_sequenceATwice
  , testCase "vdiag" test_vdiag
  , testCase "vdiag'" test_vdiag'
  , testCase "vectorize (:.)'" test_vectorizeO
  , testCase "devectorize (:.)'" test_devectorizeO
  , testCase "pure (:.)'" test_pureO
  ]

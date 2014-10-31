{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language GADTs #-}
{-# Language DeriveGeneric #-}
{-# Language FlexibleInstances #-}

module ViewTests
       ( Views(..)
       , CasadiMats(..)
       , viewTests
       ) where

import qualified Data.Vector as V
import GHC.Generics ( Generic )
import System.IO.Unsafe ( unsafePerformIO )
import Test.QuickCheck
import Test.Framework ( Test, testGroup )
import Test.Framework.Providers.QuickCheck2 ( testProperty )

import Casadi.Function ( evalDMatrix )
import Casadi.MXFunction ( mxFunction )
import Casadi.SharedObject ( soInit )

import Dyno.TypeVecs ( Vec, Dim )
import Dyno.Vectorize
import Dyno.View
import Dyno.View.M
import Dyno.View.CasadiMat ( CasadiMat )
import Dyno.Cov

import Utils
import VectorizeTests ( Vectorizes(..), Dims(..) )

data Views where
  Views :: View f =>
           { vwShrinks :: [Views]
           , vwName :: String
           , vwProxy :: Proxy f
           } -> Views
instance Show Views where
  show = vwName

data CasadiMats where
  CasadiMats :: (Viewable f, CasadiMat f, MyEq f) =>
                { cmName :: String
                , cmProxy :: Proxy f
                } -> CasadiMats
instance Show CasadiMats where
  show = cmName

-- MX is less frequent because evalMX takes a while
instance Arbitrary CasadiMats where
  arbitrary = frequency [ (1, return (CasadiMats "MX" (Proxy :: Proxy MX)))
                        , (5, return (CasadiMats "SX" (Proxy :: Proxy SX)))
                        , (5, return (CasadiMats "DMatrix" (Proxy :: Proxy DMatrix)))
                        ]

evalMX :: MX -> DMatrix
evalMX x = unsafePerformIO $ do
  f <- mxFunction V.empty (V.singleton x)
  soInit f
  ret <- evalDMatrix f V.empty
  return (V.head ret)

data JX0 f a = JX0 (J (JV f) a) (J (JV f) a) deriving (Show, Generic, Generic1)
instance Vectorize f => View (JX0 f)
--instance Scheme JX

data JX1 f g a = JX1 (J (JV f) a) (J g a) deriving (Show, Generic, Generic1)
instance (Vectorize f, View g) => View (JX1 f g)
--instance Scheme JX

data JX2 f g h a = JX2 (J f a) (J (JTuple g (JV h)) a) (J g a) (J (JV h) a) (J f a)
                 deriving (Show, Generic, Generic1)
instance (View f, View g, Vectorize h) => View (JX2 f g h)
----instance Scheme JX2

maxViewSize :: Int
maxViewSize = 200

class MyEq a where
  myEq :: a -> a -> Bool

instance MyEq a => MyEq (J f a) where
  myEq (UnsafeJ x) (UnsafeJ y) = myEq x y
instance MyEq a => MyEq (M f g a) where
  myEq (UnsafeM x) (UnsafeM y) = myEq x y
instance MyEq SX where
  myEq = (==)
instance MyEq DMatrix where
  myEq = (==)
instance MyEq MX where
  myEq x y = myEq (evalMX x) (evalMX y)
instance (Dim n, MyEq a) => MyEq (Vec n a) where
  myEq f g = V.and $ V.zipWith myEq (vectorize f) (vectorize g)

instance Arbitrary Views where
  arbitrary = do
    x <- oneof [primitives, compound primitives, compound (compound primitives)]
    if viewSize x <= maxViewSize then return x else arbitrary
  shrink = filter ((<= maxViewSize) . viewSize) . vwShrinks

compound :: Gen Views -> Gen Views
compound genIt = do
  vc'@(Vectorizes _ mz pz) <- arbitrary
  let vc = mkJV vc'
  vw0@(Views _ mv0 pv0) <- genIt
  vw1@(Views _ mv1 pv1) <- genIt
  elements
    [ Views [vc] ("JX0 (" ++ mz ++ ")") (reproxy (Proxy :: Proxy JX0) pz)
    , Views [vc,vw0] ("JX1 (" ++ mz ++ ") (" ++ mv0 ++ ")") (reproxy2 (Proxy :: Proxy JX1) pz pv0)
    , Views [vc, vw0, vw1] ("JX2 (" ++ mv0 ++ ") (" ++ mv1 ++ ") (" ++ mz ++ ")")
      (reproxy3 (Proxy :: Proxy JX2) pv0 pv1 pz)
    , Views [vw0] ("Cov (" ++ mv0 ++ ")") (reproxy (Proxy :: Proxy Cov) pv0)
    ]

viewSize :: Views -> Int
viewSize (Views _ _ p) = size p

mkJV :: Vectorizes -> Views
mkJV = mkJV' True
  where
    mkJV' :: Bool -> Vectorizes -> Views
    mkJV' sh v@(Vectorizes _ m p) = Views shrinks ("JV (" ++ m ++ ")") (reproxyJV p)
      where
        shrinks :: [Views]
        shrinks = if sh then map (mkJV' False) (shrink v) else []

        reproxyJV :: Proxy f -> Proxy (JV f)
        reproxyJV = const Proxy

primitives :: Gen Views
primitives = do
  v <- arbitrary
  elements
    [ Views [] "JNone" (Proxy :: Proxy JNone)
    , Views [] "S" (Proxy :: Proxy S)
    , mkJV v
    ]

--data M1 a = M1 (M JX JX2 a) deriving (Show, Generic, Generic1)
--data M2 a = M2 (M JNone JNone a) deriving (Show, Generic, Generic1)
--data M3 a = M3 (M JX2 JNone a) deriving (Show, Generic, Generic1)
--data M4 a = M4 (M JNone JX2 a) deriving (Show, Generic, Generic1)

--instance Scheme M1
--instance Scheme M2
--instance Scheme M3
--instance Scheme M4

beEqual :: (MyEq a, Show a) => a -> a -> Property
beEqual x y = counterexample (sx ++ " =/= " ++ sy) (myEq x y)
  where
    sx = show x
    sy = show y

prop_VSplitVCat :: Test
prop_VSplitVCat =
  testProperty "vcat . vsplit" $
  \(Vectorizes _ _ p1) (Views _ _ p2) (CasadiMats {cmProxy = pm}) -> test p1 p2 pm
  where
    test :: forall f g a
            . (Vectorize f, View g, CasadiMat a, MyEq a)
            => Proxy f -> Proxy g -> Proxy a -> Property
    test _ _ _ = beEqual x0 x1
      where
        x0 :: M (JV f) g a
        x0 = countUp

        x1 :: M (JV f) g a
        x1 = vcat (vsplit x0)

prop_HSplitHCat :: Test
prop_HSplitHCat  =
  testProperty "hcat . hsplit" $
  \(Views _ _ p1) (Vectorizes _ _ p2) (CasadiMats {cmProxy = pm}) -> test p1 p2 pm
  where
    test :: forall f g a
            . (View f, Vectorize g, CasadiMat a, MyEq a)
            => Proxy f -> Proxy g -> Proxy a -> Property
    test _ _ _ = beEqual x0 x1
      where
        x0 :: M f (JV g) a
        x0 = countUp

        x1 :: M f (JV g) a
        x1 = hcat (hsplit x0)

prop_VSplitVCat' :: Test
prop_VSplitVCat'  =
  testProperty "vsplit' . vcat'" $
  \(Dims _ pd) (Views _ _ p1) (Views _ _ p2) (CasadiMats {cmProxy = pm}) -> test pd p1 p2 pm
  where
    test :: forall f g n a
            . (View f, View g, Dim n, CasadiMat a, MyEq a)
            => Proxy n -> Proxy f -> Proxy g -> Proxy a -> Property
    test _ _ _ _ = beEqual x0 x1
      where
        x0 :: Vec n (M f g a)
        x0 = fill countUp

        x1 :: Vec n (M f g a)
        x1 = vsplit' (vcat' x0)


prop_HSplitHCat' :: Test
prop_HSplitHCat' =
  testProperty "hsplit' . hcat'" $
  \(Dims _ pd) (Views _ _ p1) (Views _ _ p2) (CasadiMats {cmProxy = pm}) -> test pd p1 p2 pm
  where
    test :: forall f g n a
            . (View f, View g, Dim n, CasadiMat a, MyEq a)
            => Proxy n -> Proxy f -> Proxy g -> Proxy a -> Property
    test _ _ _ _ = beEqual x0 x1
      where
        x0 :: Vec n (M f g a)
        x0 = fill countUp

        x1 :: Vec n (M f g a)
        x1 = hsplit' (hcat' x0)

prop_testSplitJ :: Test
prop_testSplitJ  =
  testProperty "split . cat J" $
  \(Vectorizes _ _ p) (CasadiMats {cmProxy = pm}) -> test p pm
  where
    test :: forall f a
            . (Vectorize f, CasadiMat a, Viewable a, MyEq a)
            => Proxy f -> Proxy a -> Property
    test _ _ = beEqual xj0 xj2
      where
        UnsafeM xm0 = ones :: M (JV f) (JV Id) a

        xj0 :: J (JV f) a
        xj0 = mkJ xm0

        xj1 :: JV f a
        xj1 = split xj0

        xj2 :: J (JV f) a
        xj2 = cat xj1

viewTests :: Test
viewTests =
  testGroup "view tests"
  [ prop_VSplitVCat
  , prop_HSplitHCat
  , prop_VSplitVCat'
  , prop_HSplitHCat'
  , prop_testSplitJ
  ]

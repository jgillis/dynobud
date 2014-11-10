{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language TypeOperators #-}
{-# Language DeriveGeneric #-}
{-# Language FlexibleContexts #-}

module Dyno.DirectCollocation.Robust
       ( CovarianceSensitivities(..)
       , CovTraj(..)
       , mkComputeSensitivities
       , mkComputeCovariances
       , mkRobustifyFunction
       ) where

import GHC.Generics ( Generic, Generic1 )
import Data.Proxy ( Proxy(..) )
import qualified Data.Vector as V
import qualified Data.Foldable as F
import qualified Data.Traversable as T
import Linear.V

import Casadi.MX ( d2m )
import Casadi.SXElement ( SXElement )
import Casadi.SX ( sdata, sdense, svector )

import Dyno.View.CasadiMat as CM
import Dyno.Cov
import Dyno.View
import qualified Dyno.View.M as M
import Dyno.View.M ( M )
--import Dyno.View.HList
import Dyno.View.FunJac
--import Dyno.View.Scheme
import Dyno.Vectorize ( Vectorize(..), Id, vzipWith3 )
import Dyno.TypeVecs ( Vec )
import qualified Dyno.TypeVecs as TV
import Dyno.LagrangePolynomials ( lagrangeDerivCoeffs )

import Dyno.DirectCollocation.Types
import Dyno.DirectCollocation.Quadratures ( QuadratureRoots(..), mkTaus, interpolate )

de :: Vectorize v => J (JV v) SX -> v SXElement
de = devectorize . sdata . sdense . unJ

de' :: J S SX -> SXElement
de' = V.head . sdata . sdense . unJ

re :: Vectorize v => v SXElement -> J (JV v) SX
re = mkJ . svector . vectorize

data CovTraj sx n a =
  CovTraj
  { ctAllButLast :: J (JVec n (Cov (JV sx))) a
  , ctLast :: J (Cov (JV sx)) a
  } deriving (Eq, Show, Generic, Generic1)
instance (Vectorize sx, Dim n) => View (CovTraj sx n)


data CovarianceSensitivities xe we n a =
  CovarianceSensitivities
  { csFs :: M (JVec n xe) xe a
  , csWs :: M (JVec n xe) we a
  } deriving (Eq, Show, Generic, Generic1)
instance (View xe, View we, Dim n) => Scheme (CovarianceSensitivities xe we n)

type Sxe = SXElement

mkComputeSensitivities ::
  forall x z u p sx sz sw sr deg n .
  (Dim deg, Dim n, Vectorize x, Vectorize p, Vectorize u, Vectorize z,
   Vectorize sr, Vectorize sw, Vectorize sz, Vectorize sx)
  => QuadratureRoots
  -> (x Sxe -> x Sxe -> z Sxe -> u Sxe -> p Sxe -> Sxe
      -> sx Sxe -> sx Sxe -> sz Sxe -> sw Sxe
      -> sr Sxe)
  -> IO (MXFun (J (CollTraj x z u p n deg)) (CovarianceSensitivities (JV sx) (JV sw) n))
mkComputeSensitivities roots covDae = do
  let -- the collocation points
      taus :: Vec deg Double
      taus = mkTaus roots deg

      deg = reflectDim (Proxy :: Proxy deg)

      -- coefficients for getting xdot by lagrange interpolating polynomials
      cijs :: Vec (TV.Succ deg) (Vec (TV.Succ deg) Double)
      cijs = lagrangeDerivCoeffs (0 TV.<| taus)

  errorDynFun <- toSXFun "error dynamics" $ errorDynamicsFunction $
            \x0 x1 x2 x3 x4 x5 x6 x7 x8 x9 ->
            let r = covDae
                    (de x0) (de x1) (de x2) (de x3) (de x4)
                    (de' x5) (de x6) (de x7) (de x8) (de x9)
            in re r

  edscf <- toMXFun "errorDynamicsStageCon" (errorDynStageConstraints cijs taus errorDynFun)
  errorDynStageConFunJac <- toFunJac edscf

  sensitivityStageFun' <- toMXFun "sensitivity stage function" $
                          sensitivityStageFunction (call errorDynStageConFunJac)
  sensitivityStageFun <- expandMXFun sensitivityStageFun'
  let sens :: J S MX
              -> J (JV p) MX
              -> J (JVec deg S) MX
              -> J (JV x) MX
              -> J (JVec deg (CollPoint (JV x) (JV z) (JV u))) MX
              -> (M (JV sx) (JV sx) MX, M (JV sx) (JV sw) MX)
      sens dt p stagetimes x0 xzus = (y0,y1)
        where
          y0 :*: y1 = call sensitivityStageFun (dt :*: p :*: stagetimes :*: x0 :*: xzus)

  let foo :: J (CollTraj x z u p n deg) MX
             -> CovarianceSensitivities (JV sx) (JV sw) n MX
      foo collTraj = CovarianceSensitivities (M.vcat' fs) (M.vcat' ws)
        where
          -- split up the design vars
          CollTraj tf parm stages' _ = split collTraj
          stages = unJVec (split stages') :: Vec n (J (CollStage (JV x) (JV z) (JV u) deg) MX)
          spstages = fmap split stages :: Vec n (CollStage (JV x) (JV z) (JV u) deg MX)
      
          -- timestep
          dt = tf / fromIntegral n
          n = reflectDim (Proxy :: Proxy n)
      
          -- initial time at each collocation stage
          t0s :: Vec n (J S MX)
          t0s = TV.mkVec' $ take n [dt * fromIntegral k | k <- [(0::Int)..]]
      
          -- times at each collocation point
          times :: Vec n (Vec deg (J S MX))
          times = fmap (\t0 -> fmap (\tau -> t0 + realToFrac tau * dt) taus) t0s
      
          times' :: Vec n (J (JVec deg S) MX)
          times' = fmap (cat . JVec) times
      
          fs :: Vec n (M (JV sx) (JV sx) MX)
          ws :: Vec n (M (JV sx) (JV sw) MX)
          (fs, ws) = TV.tvunzip $ TV.tvzipWith mkFw times' spstages
          mkFw stagetimes (CollStage x0' xzus') = sens dt parm stagetimes x0' xzus'

  toMXFun "compute all sensitivities" foo


-- todo: calculate by first multiplying all the Fs
mkComputeCovariances ::
  forall z x u p sx sw n deg .
  (Dim deg, Dim n, Vectorize x, Vectorize z, Vectorize u, Vectorize p,
   Vectorize sx, Vectorize sw)
  => MXFun (J (CollTraj x z u p n deg)) (CovarianceSensitivities (JV sx) (JV sw) n)
  -> J (Cov (JV sw)) DMatrix
  -> IO (MXFun
         (J (CollTrajCov sx x z u p n deg))
         (J (CovTraj sx n))
        )
mkComputeCovariances computeSens sq = do
  propOneCov <- mkPropOneCov
  
  let computeCovs collTrajCov = cat covTraj
        where
          CollTrajCov p0 collTraj = split collTrajCov
    
          sensitivities = call computeSens collTraj
      
          covTraj =
            CovTraj
            { ctAllButLast = cat (JVec covs)
            , ctLast = pF
            }

          covs :: Vec n (J (Cov (JV sx)) MX) -- all but last covariances
          pF :: J (Cov (JV sx)) MX -- last covariances
          (pF, covs) = T.mapAccumL ffs p0 $
                           TV.tvzip (M.vsplit' (csFs sensitivities)) (M.vsplit' (csWs sensitivities))
      
          sq_over_t :: J (Cov (JV sw)) MX
          sq_over_t = mkJ ((unJ dt) * d2m (unJ sq))
      
          ffs :: J (Cov (JV sx)) MX
                 -> (M (JV sx) (JV sx) MX, M (JV sx) (JV sw) MX)
                -> (J (Cov (JV sx)) MX, J (Cov (JV sx)) MX)
          ffs cov0 (f, w) = (cov1, cov0)
            where
              cov1 = call propOneCov (f :*: w :*: cov0 :*: sq_over_t)
      
          -- split up the design vars
          CollTraj tf _ _ _ = split collTraj
      
          -- timestep
          dt = tf / fromIntegral n
          n = reflectDim (Proxy :: Proxy n)

  toMXFun "compute all covariances" computeCovs

dot :: forall x deg a b. (Fractional (J x a), Real b) => Vec deg b -> Vec deg (J x a) -> J x a
dot cks xs = F.sum $ TV.unSeq elemwise
  where
    elemwise :: Vec deg (J x a)
    elemwise = TV.tvzipWith smul cks xs

    smul :: b -> J x a -> J x a
    smul x y = realToFrac x * y


interpolateXDots' :: (Real b, Fractional (J x a)) => Vec deg (Vec deg b) -> Vec deg (J x a) -> Vec deg (J x a)
interpolateXDots' cjks xs = fmap (`dot` xs) cjks

interpolateXDots ::
  (Real b, Dim deg, Fractional (J x a)) =>
  Vec (TV.Succ deg) (Vec (TV.Succ deg) b)
  -> Vec (TV.Succ deg) (J x a)
  -> Vec deg (J x a)
interpolateXDots cjks xs = TV.tvtail $ interpolateXDots' cjks xs


-- dynamics residual and outputs
errorDynamicsFunction ::
  forall x z u p r sx sz sw a .
  (View x, View z, View u, View r, View sx, View sz, View sw, Viewable a)
  => (J x a -> J x a -> J z a -> J u a -> J p a -> J S a
      -> J sx a -> J sx a -> J sz a -> J sw a -> J r a)
  -> (J S :*: J p :*: J x :*: J (CollPoint x z u) :*: J sx :*: J sx :*: J sz :*: J sw) a
  -> J r a
errorDynamicsFunction dae (t :*: parm :*: x' :*: collPoint :*: sx' :*: sx :*: sz :*: sw) =
  r
  where
    CollPoint x z u = split collPoint
    r = dae x' x z u parm t sx' sx sz sw


data ErrorIn0 x z u p deg a =
  ErrorIn0 (J x a) (J (JVec deg (CollPoint x z u)) a) (J S a) (J p a) (J (JVec deg S) a)
  deriving Generic
data ErrorInD sx sw sz deg a =
  ErrorInD (J sx a) (J sw a) (J (JVec deg (JTuple sx sz)) a)
  deriving Generic
data ErrorOut sr sx deg a =
  ErrorOut (J (JVec deg sr) a) (J sx a)
  deriving Generic

instance (View x, View z, View u, View p, Dim deg) => Scheme (ErrorIn0 x z u p deg)
instance (View sx, View sw, View sz, Dim deg) => View (ErrorInD sx sw sz deg)
instance (View sr, View sx, Dim deg) => View (ErrorOut sr sx deg)

-- return error dynamics constraints and interpolated state
errorDynStageConstraints ::
  forall x z u p sx sz sw sr deg .
  (Dim deg, View x, View z, View u, View p,
   View sr, View sw, View sz, View sx)
  => Vec (TV.Succ deg) (Vec (TV.Succ deg) Double)
  -> Vec deg Double
  -> SXFun (J S :*: J p :*: J x :*: J (CollPoint x z u) :*: J sx :*: J sx :*: J sz :*: J sw)
           (J sr)
  -> JacIn (ErrorInD sx sw sz deg) (ErrorIn0 x z u p deg) MX
  -> JacOut (ErrorOut sr sx deg) (J JNone) MX
errorDynStageConstraints cijs taus dynFun
  (JacIn errorInD (ErrorIn0 x0 xzus' (UnsafeJ h) p stageTimes'))
  = JacOut (cat (ErrorOut (cat (JVec dynConstrs)) sxnext)) (cat JNone)
  where
    ErrorInD sx0 sw0 sxzs' = split errorInD

    xzus = unJVec (split xzus')

    xs :: Vec deg (J x MX)
    xs = fmap ((\(CollPoint x _ _) -> x) . split) xzus

    xdots :: Vec deg (J x MX)
    xdots = fmap (/ UnsafeJ h) $ interpolateXDots cijs (x0 TV.<| xs)

--    -- interpolated final state
--    xnext :: J x MX
--    xnext = interpolate taus x0 xs

    -- interpolated final state
    sxnext :: J sx MX
    sxnext = interpolate taus sx0 sxs

    stageTimes = unJVec $ split stageTimes'

    -- dae constraints (dynamics)
    dynConstrs :: Vec deg (J sr MX)
    dynConstrs = TV.tvzipWith6 applyDae sxdots sxs szs xdots xzus stageTimes

    applyDae
      :: J sx MX -> J sx MX -> J sz MX
         -> J x MX -> J (CollPoint x z u) MX -> J S MX
         -> J sr MX
    applyDae sx' sx sz x' xzu t =
      call dynFun
      (t :*: p :*: x' :*: xzu :*: sx' :*: sx :*: sz :*: sw0)

    -- error state derivatives
    sxdots :: Vec deg (J sx MX)
    sxdots = fmap (/ UnsafeJ h) $ interpolateXDots cijs (sx0 TV.<| sxs)

    sxs :: Vec deg (J sx MX)
    szs :: Vec deg (J sz MX)
    (sxs, szs) = TV.tvunzip
                 $ fmap ((\(JTuple sx sz) -> (sx,sz)) . split)
                 $ unJVec $ split sxzs'


mkPropOneCov ::
  forall sx sw
  . (View sx, View sw)
  => IO (MXFun
         (M sx sx :*: M sx sw :*: J (Cov sx) :*: J (Cov sw))
         (J (Cov sx)))
mkPropOneCov = toMXFun "propogate one covariance" f
  where
    f (dsx1_dsx0' :*: dsx1_dsw0' :*: p0' :*: q0') = p1
      where
        q0 = toMat' q0'
        p0 = toMat' p0'
    
        p1' :: M sx sx MX
        p1' = dsx1_dsx0' `M.mm` p0 `M.mm` M.trans dsx1_dsx0' +
              dsx1_dsw0' `M.mm` q0 `M.mm` M.trans dsx1_dsw0'
    
        p1 :: J (Cov sx) MX
        p1 = fromMat' p1'


sensitivityStageFunction ::
  forall x z u p sx sz sw deg sr
  . (Dim deg, View x, View z, View u, View p, View sx, View sz, View sw, View sr)
  => (JacIn (ErrorInD sx sw sz deg) (ErrorIn0 x z u p deg) MX
      -> Jac (ErrorInD sx sw sz deg) (ErrorOut sr sx deg) (J JNone) MX)
  -> (J S :*: J p :*: J (JVec deg S) :*: J x :*: J (JVec deg (CollPoint x z u))) MX
  -> (M sx sx :*: M sx sw) MX
sensitivityStageFunction dynStageConJac
  (dt :*: parm :*: stageTimes :*: x0' :*: xzus') = dsx1_dsx0 :*: dsx1_dsw0
  where
    sx0 :: J sx MX
    sx0  = M.uncol M.zeros
    sw0 :: J sw MX
    sw0  = M.uncol M.zeros
    sxzs :: J (JVec deg (JTuple sx sz)) MX
    sxzs = M.uncol M.zeros

    mat :: M.M (ErrorOut sr sx deg) (ErrorInD sx sw sz deg) MX
    Jac mat _ _ =
      dynStageConJac $
      JacIn (cat (ErrorInD sx0 sw0 sxzs)) (ErrorIn0 x0' xzus' dt parm stageTimes)

    df_dsx0 :: M (JVec deg sr) sx MX
    df_dsw0 :: M (JVec deg sr) sw MX
    df_dsxz :: M (JVec deg sr) (JVec deg (JTuple sx sz)) MX
    dg_dsx0 :: M sx sx MX
    dg_dsw0 :: M sx sw MX
    dg_dsxz :: M sx (JVec deg (JTuple sx sz)) MX
    ((df_dsx0, df_dsw0, df_dsxz), (dg_dsx0, dg_dsw0, dg_dsxz)) =
      case fmap F.toList (F.toList (blockSplit mat)) of
      [[x00,x01,x02],[x10,x11,x12]] -> ((M.mkM x00, M.mkM x01, M.mkM x02),
                                        (M.mkM x10, M.mkM x11, M.mkM x12))
      _ -> error "stageFunction: got wrong number of elements in jacobian"

    -- TODO: this should be much simpler for radau

    -- TODO: check these next 4 lines
    dsxz_dsx0 = - (M.solve df_dsxz df_dsx0) :: M (JVec deg (JTuple sx sz)) sx MX
    dsxz_dsw0 = - (M.solve df_dsxz df_dsw0) :: M (JVec deg (JTuple sx sz)) sw MX

    dsx1_dsx0 = dg_dsx0 + dg_dsxz `M.mm` dsxz_dsx0 :: M sx sx MX
    dsx1_dsw0 = dg_dsw0 + dg_dsxz `M.mm` dsxz_dsw0 :: M sx sw MX


mkRobustifyFunction ::
  forall x sx shr .
  (Vectorize x, Vectorize sx, Vectorize shr)
  => (x Sxe -> sx Sxe -> x Sxe)
  -> (x Sxe -> shr Sxe)
  -> IO (J (JV shr) MX -> J (JV x) MX -> J (Cov (JV sx)) MX -> J (JV shr) MX)
mkRobustifyFunction project robustifyPathC = do
  proj <- toSXFun "errorSpaceProjection" $
          \(JacIn x0 x1) -> JacOut (re (project (de x1) (de x0))) (cat JNone)
  let _ = proj :: SXFun
                  (JacIn (JV sx) (J (JV x)))
                  (JacOut (JV x) (J JNone))

  projJac <- toFunJac proj
  let _ = projJac :: SXFun
                     (JacIn (JV sx) (J (JV x)))
                     (Jac (JV sx) (JV x) (J JNone))

  let zerosx = (M.uncol M.zeros) :: J (JV sx) SX
  simplifiedJac <- toSXFun "simplified error space jacobian" $
                   \x0 -> (\(Jac j0 _ _) -> j0) (callSX projJac (JacIn zerosx x0))
  let _ = simplifiedJac :: SXFun
                           (J (JV x))
                           (M.M (JV x) (JV sx))


  robustH <- toSXFun "robust constraint" $
             \(JacIn x0 (_ :: J JNone SX)) -> JacOut (re (robustifyPathC (de x0))) (cat JNone)
  let _ = robustH :: SXFun
                     (JacIn (JV x) (J JNone))
                     (JacOut (JV shr) (J JNone))
  robustHJac <- toFunJac robustH
  let _ = robustHJac :: SXFun
                        (JacIn (JV x) (J JNone))
                        (Jac (JV x) (JV shr) (J JNone))


  let gogo :: J (JV shr) MX -> J (JV x) MX -> J (Cov (JV sx)) MX -> J (JV shr) MX
      gogo gammas' x pw' = rcs'
          where
            gammas = fmap mkJ (unJV (split gammas')) :: shr (J (JV Id) MX)

            h0vec :: J (JV shr) MX
            jacH :: M.M (JV shr) (JV x) MX
            Jac jacH h0vec _ = call robustHJac (JacIn x (cat JNone))

            f :: M.M (JV x) (JV sx) MX
            f = call simplifiedJac x

            pw :: M.M (JV sx) (JV sx) MX
            pw = toMat' pw'

            px :: M.M (JV x) (JV x) MX
            px = (f `M.mm` pw) `M.mm` (M.trans f)

            jacHs :: shr (M.M (JV Id) (JV x) MX)
            jacHs = M.vsplit jacH -- THIS IS THROWING THE vsplit ERROR

            shr' = fmap mkJ (unJV (split h0vec)) :: shr (J (JV Id) MX)

            rcs' :: J (JV shr) MX
            rcs' = cat $ JV $ fmap unsafeUnJ rcs

            rcs :: shr (J (JV Id) MX)
            rcs = vzipWith3 robustify gammas shr' jacHs

            robustify :: J (JV Id) MX -> J (JV Id) MX -> M.M (JV Id) (JV x) MX -> J (JV Id) MX
            robustify gamma h0 gradH = h0 + gamma * sqrt sigma2
              where
                sigma2 :: J (JV Id) MX
                sigma2 = mkJ sigma2'

                M.UnsafeM sigma2' = gradH `M.mm` px `M.mm` (M.trans gradH) :: M.M (JV Id) (JV Id) MX

  retFun <- toMXFun "robust constraint violations" $
    \(x0 :*: x1 :*: x2) -> gogo x0 x1 x2

  retFunSX <- expandMXFun retFun

  return (\x y z -> call retFunSX (x :*: y :*: z))
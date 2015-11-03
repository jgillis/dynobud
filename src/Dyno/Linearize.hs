{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Dyno.Linearize
       ( OdeJacobian
       , ErrorOdeJacobian
       , makeOdeJacobian
       , makeErrorOdeJacobian
       , evalOdeJacobian
       , evalErrorOdeJacobian
       ) where

import Dyno.Vectorize ( Vectorize(..), Triple(..), fill )
import Dyno.View.View
import Dyno.View.M
import Dyno.View.Fun
import Dyno.View.FunJac

import Casadi.SX ( SX )
import Casadi.DMatrix ( DMatrix )

toOdeSX ::
  (Vectorize x, Vectorize u, Vectorize w, Vectorize p, Vectorize sc, Vectorize o)
  => (x (S SX) -> u (S SX) -> w (S SX) -> p (S SX) -> sc (S SX)
      -> (x (S SX), o (S SX)))
  -> JacIn (JQuad (JV x) (JV u) (JV w) (JV p)) (J (JV sc)) SX
  -> JacOut (JTuple (JV x) (JV o)) (J JNone) SX
toOdeSX ode jacIn = jacOut
  where
    jacOut = JacOut (cat (JTuple (vcat dx) (vcat outputs))) (cat JNone)
    JacIn xuwp sc = jacIn
    JQuad x u w p = split xuwp
    (dx, outputs) =
      ode (vsplit x) (vsplit u) (vsplit w) (vsplit p) (vsplit sc)

toErrorOdeSX ::
  ( Vectorize x, Vectorize e, Vectorize u, Vectorize w
  , Vectorize p, Vectorize sc, Vectorize o)
  => (x (S SX) -> e (S SX) -> u (S SX) -> u (S SX) -> w (S SX) -> p (S SX)
      -> sc (S SX) -> (e (S SX), o (S SX)))
  -> JacIn (JQuad (JV e) (JV u) (JV w) (JV p)) (J (JV (Triple x u sc))) SX
  -> JacOut (JTuple (JV e) (JV o)) (J JNone) SX
toErrorOdeSX errorOde jacIn = jacOut
  where
    jacOut = JacOut (cat (JTuple (vcat de) (vcat outputs))) (cat JNone)
    JacIn euwp nominalInputs = jacIn
    JQuad e du w p = split euwp
    Triple fs0 u0 sc = vsplit nominalInputs
    (de, outputs) = errorOde fs0 (vsplit e) u0 (vsplit du) (vsplit w)
                    (vsplit p) sc

newtype OdeJacobian x u w p sc o =
  OdeJacobian
  (SXFun
   (JacIn
    (JQuad (JV x) (JV u) (JV w) (JV p))
    (J (JV sc)))
   (Jac
    (JQuad (JV x) (JV u) (JV w) (JV p))
    (JTuple (JV x) (JV o))
    (J JNone)))

newtype ErrorOdeJacobian x e u w p sc o =
  ErrorOdeJacobian
  (SXFun
   (JacIn
    (JQuad (JV e) (JV u) (JV w) (JV p))
    (J (JV (Triple x u sc))))
   (Jac
    (JQuad (JV e) (JV u) (JV w) (JV p))
    (JTuple (JV e) (JV o))
    (J JNone)))

makeOdeJacobian ::
  forall x u w p sc o
  . (Vectorize x, Vectorize u, Vectorize w, Vectorize p, Vectorize sc, Vectorize o)
  => (x (S SX) -> u (S SX) -> w (S SX) -> p (S SX) -> sc (S SX)
      -> (x (S SX), o (S SX)))
  -> IO (OdeJacobian x u w p sc o)
makeOdeJacobian ode = do
  f <- toSXFun "odeSX" (toOdeSX ode)
  fmap OdeJacobian (toFunJac f)

makeErrorOdeJacobian ::
  ( Vectorize x, Vectorize e, Vectorize u, Vectorize w
  , Vectorize p, Vectorize sc, Vectorize o)
  => (x (S SX) -> e (S SX) -> u (S SX) -> u (S SX) -> w (S SX) -> p (S SX)
      -> sc (S SX) -> (e (S SX), o (S SX)))
  -> IO (ErrorOdeJacobian x e u w p sc o)
makeErrorOdeJacobian errorOde = do
  f <- toSXFun "errorOdeSX" (toErrorOdeSX errorOde)
  fmap ErrorOdeJacobian (toFunJac f)


evalOdeJacobian ::
  forall x u w p sc o
  . ( Vectorize x, Vectorize u, Vectorize w
    , Vectorize p, Vectorize o, Vectorize sc
    )
  => OdeJacobian x u w p sc o
  -> x Double
  -> u Double
  -> p Double
  -> sc Double
  -> IO ( M (JV x) (JV x) DMatrix
        , M (JV x) (JV u) DMatrix
        , M (JV x) (JV w) DMatrix
        , M (JV x) (JV p) DMatrix
        , M (JV o) (JV x) DMatrix
        , M (JV o) (JV u) DMatrix
        , M (JV o) (JV w) DMatrix
        , M (JV o) (JV p) DMatrix
        , J (JV x) DMatrix
        , J (JV o) DMatrix
        )
evalOdeJacobian (OdeJacobian fj) x0 u0 p0 sc0 = do
  let w  = vcat (fill 0)
      x  = vcat (fmap realToFrac x0)
      u  = vcat (fmap realToFrac u0)
      p  = vcat (fmap realToFrac p0)
      sc = vcat (fmap realToFrac sc0)
      jacIn = JacIn (cat (JQuad x u w p)) sc
  jacOut <- eval fj jacIn
  let Jac dxo_dxup xo' _ = jacOut
      (x',o) = vsplitTup xo'
      (dxo_dx,dxo_du,dxo_dw,dxo_dp) = hsplitQuad dxo_dxup
      (dx_dx, do_dx) = vsplitTup dxo_dx
      (dx_du, do_du) = vsplitTup dxo_du
      (dx_dw, do_dw) = vsplitTup dxo_dw
      (dx_dp, do_dp) = vsplitTup dxo_dp
  return (dx_dx, dx_du, dx_dw, dx_dp, do_dx, do_du, do_dw, do_dp, x', o)


evalErrorOdeJacobian ::
  forall x e u w p sc o
  . ( Vectorize x, Vectorize e, Vectorize u, Vectorize w
    , Vectorize p, Vectorize o, Vectorize sc
    )
  => ErrorOdeJacobian x e u w p sc o
  -> x Double
  -> u Double
  -> p Double
  -> sc Double
  -> IO ( M (JV e) (JV e) DMatrix
        , M (JV e) (JV u) DMatrix
        , M (JV e) (JV w) DMatrix
        , M (JV e) (JV p) DMatrix
        , M (JV o) (JV e) DMatrix
        , M (JV o) (JV u) DMatrix
        , M (JV o) (JV w) DMatrix
        , M (JV o) (JV p) DMatrix
        , J (JV e) DMatrix
        , J (JV o) DMatrix
        )
evalErrorOdeJacobian (ErrorOdeJacobian fj) x0 u0 p0 sc0 = do
  let e = vcat (fill 0)
      w = vcat (fill 0)
      du = vcat (fill 0)
      p  = vcat (fmap realToFrac p0)
      x0u0sc0 = vcat $ fmap realToFrac $ Triple x0 u0 sc0
      jacIn = JacIn (cat (JQuad e du w p)) x0u0sc0
  jacOut <- eval fj jacIn
  let Jac dxo_dxup xo' _ = jacOut
      (x',o) = vsplitTup xo'
      (dxo_dx,dxo_du,dxo_dw,dxo_dp) = hsplitQuad dxo_dxup
      (dx_dx, do_dx) = vsplitTup dxo_dx
      (dx_du, do_du) = vsplitTup dxo_du
      (dx_dw, do_dw) = vsplitTup dxo_dw
      (dx_dp, do_dp) = vsplitTup dxo_dp
  return (dx_dx, dx_du, dx_dw, dx_dp, do_dx, do_du, do_dw, do_dp, x', o)
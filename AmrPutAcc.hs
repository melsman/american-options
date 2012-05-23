{-# LANGUAGE ScopedTypeVariables #-}
module AmrPutAcc 
--       (binom, main)
where
import qualified Data.Array.Accelerate as A
import qualified Data.Vector.Storable as V

import Data.Array.Accelerate (Z(..), (:.)(..), (!),(<*),(<=*),(?))

import qualified Data.Array.Accelerate.Interpreter as AI
import qualified Data.Array.Accelerate.CUDA as ACUDA
import qualified Data.Array.Accelerate.IO as AIO

import Data.List(foldl', foldl1')
import System.Environment(getArgs)

--import qualified Criterion.Main as C


-- Pointwise manipulation of vectors and scalars
v1 ^*^ v2 = A.zipWith (*) v1 v2
v1 ^+^ v2 = A.zipWith (+) v1 v2
c -^ v = A.map (c -) v
c *^ v = A.map (c *) v

pmax v c = A.map (A.max c) v
ppmax = A.zipWith A.max 

-- Don't change the shape of the array, instead shift in zeros
vselect pf v = A.permute (\x _ -> x) zeros selectf v
  where zeros = A.fill (A.shape v) 0
        selectf ix = pf ix ? (ix, A.ignore)

vtail = vdrop 1
vdrop i = vselect dropf
  where dropf ix = (A.constant i) <=* (A.unindex1 ix)

pvtake i = vselect takef
  where takef ix = (A.unindex1 ix) <* i

vinit v = pvtake ((A.unindex1 $ A.shape v) - 1) v
vtake i = pvtake (A.constant i)

vreverse v = 
  let len = A.unindex1 (A.shape v) in
  A.backpermute (A.shape v) (\ix -> A.index1 $ len - (A.unindex1 ix) - 1) v

type FloatRep = Float
--type FloatRep = Double  -- I would like to use Double, but then I get a large numbers of of ptxas errors like:
                          --   ptxas /tmp/tmpxft_00006c13_00000000-2_dragon26988.ptx, line 83; warning : Double is not supported. Demoting to float
                          -- and I just compute NaN


binom :: Int -> A.Acc(A.Vector FloatRep)
binom expiry = first --(first ! (A.constant 0))
  where 
    uPow, dPow :: A.Acc(A.Vector FloatRep)
    uPow = A.use $ AIO.fromVector $ V.generate (n+1) (u^)
    dPow = A.use $ AIO.fromVector $ V.reverse $ V.generate (n+1) (d^)
    
    --uPow = A.generate (A.index1$ A.constant $ n+1) (\ix -> let i = A.unindex1 ix in u^i)
    --dPow = vreverse $ A.generate (A.index1$ A.constant $ n+1) (\ix -> let i = A.unindex1 ix in d^i)
    
    st = s0 *^ (uPow ^*^ dPow)
    finalPut = pmax (strike -^ st) 0

-- for (i in n:1) {
--   St<-S0*u.pow[1:i]*d.pow[i:1]
--   put[1:i]<-pmax(strike-St,(qUR*put[2:(i+1)]+qDR*put[1:i]))
-- }
    first = (foldl1' (A.>->) $ map prevPut [n, n-1 .. 1]) $ finalPut
    prevPut :: Int -> A.Acc(A.Vector FloatRep) -> A.Acc(A.Vector FloatRep)
    prevPut i put =
      ppmax(strike -^ st) ((qUR *^ vtail put) ^+^ (qDR *^ vinit put))
        where st = s0 *^ ((vtake i uPow) ^*^ (vdrop (n+1-i) dPow))

    -- standard econ parameters
    strike = 100
    bankDays = 252
    s0 = 100 
    r = 0.03; alpha = 0.07; sigma = 0.20

    n :: Int
    n = expiry*bankDays
    dt = fromIntegral expiry/fromIntegral n
    u = exp(alpha*dt+sigma*sqrt dt)
    d = exp(alpha*dt-sigma*sqrt dt)
    stepR = exp(r*dt)
    q = (stepR-d)/(u-d)
    qUR = A.constant$ q/stepR; qDR = A.constant$ (1-q)/stepR


arun run x = head $ A.toList $ run x

-- main = do
--   args <- getArgs
--   case args of
--     ["-f"] -> print $ binom 64
--     _ -> do
--       let benchmarks = [ C.bench (show years) $ C.nf binom years
--                        | years <- [1, 16, 30, 32]]
--       C.defaultMain benchmarks

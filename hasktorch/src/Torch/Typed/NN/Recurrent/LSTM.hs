{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoStarIsType #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Extra.Solver #-}

module Torch.Typed.NN.Recurrent.LSTM
  ( LSTMSpec(..)
  , NumberOfDirections
  , LSTM(..)
  -- , LSTMParams(..)
  -- , ParamsPerDirection(..)
  -- , forwardNoDropout
  -- , forwardWithDropout
  )
where

import qualified ATen.Cast                     as ATen
import qualified ATen.Class                    as ATen
import qualified ATen.Managed.Type.Tensor      as ATen
import qualified ATen.Type                     as ATen
import           Data.Kind
import           Data.HList
import           Foreign.ForeignPtr
import           GHC.Generics
import           GHC.TypeLits
import           GHC.TypeLits.Extra
import           Prelude                 hiding ( tanh )
import           System.Environment
import           System.IO.Unsafe
import qualified Torch.Autograd                as A
import qualified Torch.Device                  as D
import qualified Torch.DType                   as D
import qualified Torch.Functions               as D
import qualified Torch.NN                      as A
import qualified Torch.Tensor                  as D
import qualified Torch.TensorFactories         as D
import           Torch.Typed
import           Torch.Typed.Factories
import           Torch.Typed.Native             ( RNNDirectionality(..)
                                                , KnownRNNDirectionality
                                                , NumberOfDirections
                                                , RNNShapeOrder(..)
                                                , KnownRNNShapeOrder
                                                , RNNShape
                                                , expand
                                                , lstm
                                                )
import           Torch.Typed.NN
import           Torch.Typed.Tensor

-- | A specification for a long, short-term memory layer.
--
data LSTMSpec
  (inputSize :: Nat)
  (hiddenSize :: Nat)
  (numLayers:: Nat)
  (directionality :: RNNDirectionality)
  (dtype :: D.DType)
  (device :: (D.DeviceType, Nat)) =
    LSTMSpecZerosInit DropoutSpec   -- ^ Weights drawn from Xavier-Uniform with zeros-value
                                    --   initialized biases and cell states.
  | LSTMSpec                        -- ^ Weights drawn from Xavier-Uniform
                                    --   with zeros-value initialized biases
                                    --   and user-provided cell states.
      (Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]) -- ^ The initial values of the memory cell
      (Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]) -- ^ The initial values of the hidden state
      DropoutSpec
  | LSTMSpecLearnedInit             -- ^ Weights drawn from Xavier-Uniform
                                    --   with zeros-value initialized biases
                                    --   and learned cell states.
      (Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]) -- ^ The initial (learnable)
                                                                                         -- values of the memory cell
      (Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]) -- ^ The initial (learnable)
                                                                                         -- values of the hidden state
      DropoutSpec
  deriving (Show, Generic)

data LSTMLayer
  (inputSize :: Nat)
  (hiddenSize :: Nat)
  (directionality :: RNNDirectionality)
  (dtype :: D.DType)
  (device :: (D.DeviceType, Nat))
 where
  LSTMUnidirectionalLayer
    :: Parameter device dtype '[4 * hiddenSize, inputSize]
    -> Parameter device dtype '[4 * hiddenSize, hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> LSTMLayer inputSize hiddenSize 'Unidirectional dtype device
  LSTMBidirectionalLayer
    :: Parameter device dtype '[4 * hiddenSize, inputSize]
    -> Parameter device dtype '[4 * hiddenSize, hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize, inputSize]
    -> Parameter device dtype '[4 * hiddenSize, hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> Parameter device dtype '[4 * hiddenSize]
    -> LSTMLayer inputSize hiddenSize 'Bidirectional dtype device

deriving instance Show (LSTMLayer inputSize hiddenSize directionality dtype device)
-- deriving instance Generic (LSTMLayer inputSize hiddenSize directionality dtype device)

instance
  ( wiShape ~ '[4 * hiddenSize, inputSize]
  , whShape ~ '[4 * hiddenSize, hiddenSize]
  , biShape ~ '[4 * hiddenSize]
  , bhShape ~ '[4 * hiddenSize]
  , parameters ~ '[Parameter device dtype wiShape, Parameter device dtype whShape, Parameter device dtype biShape, Parameter device dtype bhShape]
  ) => GParameterized (K1 R (LSTMLayer inputSize hiddenSize 'Unidirectional dtype device)) parameters where
  gFlattenParameters (K1 (LSTMUnidirectionalLayer wi wh bi bh)) =
    wi :. wh :. bi :. bh :. HNil
  gReplaceParameters _ (wi :. wh :. bi :. bh :. HNil) =
    K1 (LSTMUnidirectionalLayer wi wh bi bh)

instance
  ( wiShape ~ '[4 * hiddenSize, inputSize]
  , whShape ~ '[4 * hiddenSize, hiddenSize]
  , biShape ~ '[4 * hiddenSize]
  , bhShape ~ '[4 * hiddenSize]
  , parameters ~ '[Parameter device dtype wiShape, Parameter device dtype whShape, Parameter device dtype biShape, Parameter device dtype bhShape, Parameter device dtype wiShape, Parameter device dtype whShape, Parameter device dtype biShape, Parameter device dtype bhShape]
  ) => GParameterized (K1 R (LSTMLayer inputSize hiddenSize 'Bidirectional dtype device)) parameters where
  gFlattenParameters (K1 (LSTMBidirectionalLayer wi wh bi bh wi' wh' bi' bh'))
    = wi :. wh :. bi :. bh :. wi' :. wh' :. bi' :. bh' :. HNil
  gReplaceParameters _ (wi :. wh :. bi :. bh :. wi' :. wh' :. bi' :. bh' :. HNil)
    = K1 (LSTMBidirectionalLayer wi wh bi bh wi' wh' bi' bh')

data LSTMLayerStack
  (inputSize :: Nat)
  (hiddenSize :: Nat)
  (numLayers :: Nat)
  (directionality :: RNNDirectionality)
  (dtype :: D.DType)
  (device :: (D.DeviceType, Nat))
 where
  LSTMLayer1
    :: LSTMLayer inputSize hiddenSize directionality dtype device
    -> LSTMLayerStack inputSize hiddenSize 1 directionality dtype device
  LSTMLayerK
    :: (2 <= numLayers)
    => LSTMLayerStack inputSize hiddenSize (numLayers - 1) directionality dtype device
    -> LSTMLayer (hiddenSize * NumberOfDirections directionality) hiddenSize directionality dtype device
    -> LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device

deriving instance Show (LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device)
--  TODO: Generics? see https://gist.github.com/RyanGlScott/71d9f933e823b4a03f99de54d4b94d51
-- deriving instance Generic (LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device)

instance {-# OVERLAPS #-}
  ( GParameterized (K1 R (LSTMLayer inputSize hiddenSize directionality dtype device)) parameters
  ) => GParameterized (K1 R (LSTMLayerStack inputSize hiddenSize 1 directionality dtype device)) parameters where
  gFlattenParameters (K1 (LSTMLayer1 lstmLayer))
    = gFlattenParameters (K1 @R lstmLayer)
  gReplaceParameters (K1 (LSTMLayer1 lstmLayer)) parameters
    = K1 (LSTMLayer1 (unK1 (gReplaceParameters (K1 @R lstmLayer) parameters)))

instance {-# OVERLAPPABLE #-}
  ( 2 <= numLayers
  , GParameterized (K1 R (LSTMLayerStack inputSize hiddenSize (numLayers - 1) directionality dtype device)) parameters
  , GParameterized (K1 R (LSTMLayer (hiddenSize * NumberOfDirections directionality) hiddenSize directionality dtype device)) parameters'
  , HAppendFD parameters parameters' parameters''
  , parameters'' ~ (parameters ++ parameters')
  ) => GParameterized (K1 R (LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device)) parameters'' where
  gFlattenParameters (K1 (LSTMLayerK lstmLayerStack lstmLayer))
    = let parameters  = gFlattenParameters (K1 @R lstmLayerStack)
          parameters' = gFlattenParameters (K1 @R lstmLayer)
      in  parameters `hAppendFD` parameters'
  gReplaceParameters (K1 (LSTMLayerK lstmLayerStack lstmLayer)) parameters''
    = let (parameters, parameters') = hUnappendFD parameters''
          lstmLayerStack'           = unK1 (gReplaceParameters (K1 @R lstmLayerStack) parameters)
          lstmLayer'                = unK1 (gReplaceParameters (K1 @R lstmLayer)      parameters')
      in  K1 (LSTMLayerK lstmLayerStack' lstmLayer')

-- | LSTMParams
-- Input-to-hidden, hidden-to-hidden, and bias parameters for a mulilayered
-- (and optionally) bidirectional LSTM.
--
-- data LSTMParams
--   (dtype :: D.DType)
--   (numDirections :: Nat)
--   (inputSize :: Nat)
--   (hiddenSize :: Nat)
--   (numLayers :: Nat)
--   (shapeOrder :: RNNShapeOrder)
--   (device :: (D.DeviceType, Nat))
--  where
--   LSTMLayer1
--     :: Parameter device dtype '[4 * hiddenSize, inputSize]
--     -> Parameter device dtype '[4 * hiddenSize, hiddenSize]
--     -> Parameter device dtype '[4 * hiddenSize]
--     -> Parameter device dtype '[4 * hiddenSize]
--     -> LSTMParams dtype numDirections inputSize hiddenSize 1 shapeOrder device
--   LSTMLayerK
--     :: (1 <= numLayers)
--     => LSTMParams dtype numDirections inputSize hiddenSize numLayers shapeOrder device
--     -> Parameter device dtype '[4 * hiddenSize, numDirections * hiddenSize]
--     -> Parameter device dtype '[4 * hiddenSize, hiddenSize]
--     -> Parameter device dtype '[4 * hiddenSize]
--     -> Parameter device dtype '[4 * hiddenSize]
--     -> LSTMParams dtype numDirections inputSize hiddenSize (numLayers + 1) shapeOrder device

--  A specialized singleton helper for initializing parameters
class (KnownNat numLayers) => LayerSong (numLayers :: Nat) where
  singLayerSing
    :: ( RandDTypeIsValid device dtype
       , KnownDevice device
       , KnownDType dtype
       , KnownNat numDirections
       , KnownNat inputSize
       , KnownNat hiddenSize
       )
    => IO (LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device)

-- instance {-# OVERLAPS #-} LayerSong 1 where
--   singLayerSing =
--     LSTMLayer1
--       <$> (makeIndependent =<< xavierUniormLSTM)
--       <*> (makeIndependent =<< xavierUniormLSTM)
--       <*> (makeIndependent =<< pure zeros)
--       <*> (makeIndependent =<< pure zeros)

-- instance {-# OVERLAPPABLE #-} (KnownNat n, KnownNat m, LayerSong n, m ~ (n + 1), 1 <= n) => LayerSong m where
--   singLayerSing =
--     LSTMLayerK
--       <$> singLayerSing
--       <*> (makeIndependent =<< xavierUniormLSTM)
--       <*> (makeIndependent =<< xavierUniormLSTM)
--       <*> (makeIndependent =<< pure zeros)
--       <*> (makeIndependent =<< pure zeros)

-- instance A.Parameterized (LSTMParams dtype numDirections inputSize hiddenSize numLayers shapeOrder device) where
--   flattenParameters (LSTMLayer1 a b c d) =
--     A.flattenParameters a
--       <> A.flattenParameters b
--       <> A.flattenParameters c
--       <> A.flattenParameters d
--   flattenParameters (LSTMLayerK l a b c d) =
--     A.flattenParameters l
--       <> A.flattenParameters a
--       <> A.flattenParameters b
--       <> A.flattenParameters c
--       <> A.flattenParameters d

--   replaceOwnParameters (LSTMLayer1 a b c d) =
--     LSTMLayer1
--       <$> A.replaceOwnParameters a
--       <*> A.replaceOwnParameters b
--       <*> A.replaceOwnParameters c
--       <*> A.replaceOwnParameters d
--   replaceOwnParameters (LSTMLayerK l a b c d) =
--     LSTMLayerK
--       <$> A.replaceOwnParameters l
--       <*> A.replaceOwnParameters a
--       <*> A.replaceOwnParameters b
--       <*> A.replaceOwnParameters c
--       <*> A.replaceOwnParameters d

-- data ParamsPerDirection dtype inputSize hiddenSize numLayers (directionality :: RNNDirectionality) shapeOrder device where
--   BidirectionalParams
--     :: LSTMParams dtype (NumberOfDirections 'Bidirectional) inputSize hiddenSize numLayers shapeOrder device
--     -> LSTMParams dtype (NumberOfDirections 'Bidirectional) inputSize hiddenSize numLayers shapeOrder device
--     -> ParamsPerDirection dtype inputSize hiddenSize numLayers 'Bidirectional shapeOrder device
--   UniDirectionalParams
--     :: LSTMParams dtype (NumberOfDirections 'Unidirectional) inputSize hiddenSize numLayers shapeOrder device
--     -> ParamsPerDirection dtype inputSize hiddenSize numLayers 'Unidirectional shapeOrder device

-- sampleBidirectionalParams
--   :: forall dtype inputSize hiddenSize numLayers shapeOrder device
--    . ( KnownNat hiddenSize
--      , KnownNat inputSize
--      , KnownNat numLayers
--      , KnownDType dtype
--      , LayerSong numLayers
--      , KnownDevice device
--      , RandDTypeIsValid device dtype
--      )
--   => IO
--        ( ParamsPerDirection
--            dtype
--            inputSize
--            hiddenSize
--            numLayers
--            'Bidirectional
--            shapeOrder
--            device
--        )
-- sampleBidirectionalParams =
--   BidirectionalParams <$> singLayerSing <*> singLayerSing

-- sampleUniDirectionalParams
--   :: ( KnownNat hiddenSize
--      , KnownNat inputSize
--      , KnownNat numLayers
--      , KnownDType dtype
--      , LayerSong numLayers
--      , KnownDevice device
--      , RandDTypeIsValid device dtype
--      )
--   => IO
--        ( ParamsPerDirection
--            dtype
--            inputSize
--            hiddenSize
--            numLayers
--            'Unidirectional
--            shapeOrder
--            device
--        )
-- sampleUniDirectionalParams = UniDirectionalParams <$> singLayerSing

-- instance A.Parameterized (ParamsPerDirection dtype inputSize hiddenSize numLayers directionality shapeOrder device) where
--   flattenParameters (UniDirectionalParams ps) = A.flattenParameters ps
--   flattenParameters (BidirectionalParams as bs) =
--     A.flattenParameters as <> A.flattenParameters bs
--   replaceOwnParameters (UniDirectionalParams ps) =
--     UniDirectionalParams <$> A.replaceOwnParameters ps
--   replaceOwnParameters (BidirectionalParams as bs) =
--     BidirectionalParams
--       <$> A.replaceOwnParameters as
--       <*> A.replaceOwnParameters bs

data LSTM
  (inputSize :: Nat)
  (hiddenSize :: Nat)
  (numLayers :: Nat)
  (directionality :: RNNDirectionality)
  (dtype :: D.DType)
  (device :: (D.DeviceType, Nat))
  = LSTM
      { lstm_layer_stack :: LSTMLayerStack inputSize hiddenSize numLayers directionality dtype device
      , lstm_dropout     :: Dropout
      }
  deriving (Show, Generic)

-- | A long, short-term memory layer with either fixed initial
-- states for the memory cells and hidden state or learnable
-- inital states for the memory cells and hidden state.
--
data LSTMWithInit
  (inputSize :: Nat)
  (hiddenSize :: Nat)
  (numLayers :: Nat)
  (directionality :: RNNDirectionality)
  (dtype :: D.DType)
  (device :: (D.DeviceType, Nat))
  = LSTMWithConstInit
      { lstmWithConstInit_lstm :: LSTM inputSize hiddenSize numLayers directionality dtype device
      , lstmWithConstInit_c    :: Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]
      , lstmWithConstInit_h    :: Tensor device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]
      }
  | LSTMWithLearnedInit
      { lstmWithLearnedInit_lstm :: LSTM inputSize hiddenSize numLayers directionality dtype device
      , lstmWithLearnedInit_c    :: Parameter device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]
      , lstmWithLearnedInit_h    :: Parameter device dtype '[numLayers * NumberOfDirections directionality, hiddenSize]
      }
  deriving (Show, Generic)

-- TODO: when we have cannonical initializers do this correctly:
-- https://github.com/pytorch/pytorch/issues/9221
-- https://discuss.pytorch.org/t/initializing-rnn-gru-and-lstm-correctly/23605

-- | Helper to do xavier uniform initializations on weight matrices and
-- orthagonal initializations for the gates. (When implemented.)
--
xavierUniormLSTM
  :: forall device dtype hiddenSize d
   . ( KnownDType dtype
     , KnownNat d
     , KnownNat hiddenSize
     , KnownDevice device
     , RandDTypeIsValid device dtype
     )
  => IO (Tensor device dtype '[4 * hiddenSize, d])
xavierUniormLSTM = do
  init <- randn :: IO (Tensor device dtype '[4 * hiddenSize, d])
  UnsafeMkTensor <$> xavierUniformFIXME
    (toDynamic init)
    (5.0 / 3)
    (shape @device @dtype @'[4 * hiddenSize, d] init)

-- TODO: This is taken from the initializers example code and should be replaced with cannonical,
-- tested versions. However, even a potentially incorrect implementation will likely perform
-- better than an ad-hoc random-normal distribution.
-- | Fan-in / Fan-out scaling calculation
calculateFan :: [Int] -> (Int, Int)
calculateFan shape
  | dimT < 2
  = error
    "Fan in and fan out can not be computed for tensor with fewer than 2 dimensions"
  | dimT == 2
  = (numInputFmaps, numOutputFmaps)
  | otherwise
  = (numInputFmaps * receptiveFieldSize, numOutputFmaps * receptiveFieldSize)
 where
  dimT               = length shape
  numInputFmaps      = shape !! 1
  numOutputFmaps     = shape !! 0
  receptiveFieldSize = product $ tail shape

-- | Xavier Initialization - Uniform
xavierUniformFIXME :: D.Tensor -> Float -> [Int] -> IO D.Tensor
xavierUniformFIXME init gain shape = pure
  $ D.subScalar (D.mulScalar init (bound * 2.0)) bound
 where
  (fanIn, fanOut) = calculateFan shape
  std = gain * sqrt (2.0 / (fromIntegral fanIn + fromIntegral fanOut))
  bound = sqrt 3.0 * std

-- instance
--   ( KnownDType dtype
--   , KnownNat inputSize
--   , KnownNat hiddenSize
--   , KnownNat numLayers
--   , KnownDevice device
--   , RandDTypeIsValid device dtype
--   , LayerSong numLayers
--   ) => A.Randomizable (LSTMSpec 'Bidirectional dtype numLayers inputSize hiddenSize shapeOrder device)
--                       (LSTM     'Bidirectional dtype numLayers inputSize hiddenSize shapeOrder device) where
--   sample (LSTMSpecZerosInit d) =
--     LSTM
--       <$> sampleBidirectionalParams
--       <*> A.sample d
--       <*> pure zeros
--       <*> pure zeros
--   sample s@(LSTMSpec c h d) =
--     LSTM <$> sampleBidirectionalParams <*> A.sample d <*> pure c <*> pure h
--   sample s@(LSTMSpecLearnedInit c h d) =
--     LSTMLearnedInit
--       <$> sampleBidirectionalParams
--       <*> A.sample d
--       <*> (makeIndependent =<< pure c)
--       <*> (makeIndependent =<< pure h)

-- instance
--   ( KnownDType dtype
--   , KnownNat inputSize
--   , KnownNat hiddenSize
--   , KnownNat numLayers
--   , KnownDevice device
--   , RandDTypeIsValid device dtype
--   , LayerSong numLayers
--   ) => A.Randomizable (LSTMSpec 'Unidirectional dtype numLayers inputSize hiddenSize shapeOrder device)
--                       (LSTM     'Unidirectional dtype numLayers inputSize hiddenSize shapeOrder device) where
--   sample (LSTMSpecZerosInit d) =
--     LSTM
--       <$> sampleUniDirectionalParams
--       <*> A.sample d
--       <*> pure zeros
--       <*> pure zeros
--   sample s@(LSTMSpec c h d) =
--     LSTM <$> sampleUniDirectionalParams <*> A.sample d <*> pure c <*> pure h
--   sample s@(LSTMSpecLearnedInit c h d) =
--     LSTMLearnedInit
--       <$> sampleUniDirectionalParams
--       <*> A.sample d
--       <*> (makeIndependent =<< pure c)
--       <*> (makeIndependent =<< pure h)

-- instance A.Parameterized (LSTM directionality dtype numLayers inputSize hiddenSize shapeOrder device) where
--   flattenParameters (LSTM p _ _ _) = A.flattenParameters p
--   flattenParameters (LSTMLearnedInit p _ lc lh) =
--     A.flattenParameters p <> A.flattenParameters lc <> A.flattenParameters lh
--   replaceOwnParameters (LSTM p d c h) = do
--     p' <- A.replaceOwnParameters p
--     pure $ LSTM p' d c h
--   replaceOwnParameters (LSTMLearnedInit p d lc lh) = do
--     p' <- A.replaceOwnParameters p
--     LSTMLearnedInit p' d
--       <$> A.replaceOwnParameters lc
--       <*> A.replaceOwnParameters lh

-- helpers to get params in the right order for Aten.
-- lstmParamsToTlist'
--   :: forall dtype numDirections inputSize hiddenSize numLayers shapeOrder device
--    . [D.Tensor]
--   -> LSTMParams
--        dtype
--        numDirections
--        inputSize
--        hiddenSize
--        numLayers
--        shapeOrder
--        device
--   -> [D.Tensor]
-- lstmParamsToTlist' acc (LSTMLayerK l wi wh bi bh) =
--   lstmParamsToTlist' acc l
--     <> ( toDynamic (toDependent wi)
--        : toDynamic (toDependent wh)
--        : toDynamic (toDependent bi)
--        : toDynamic (toDependent bh)
--        : []
--        )
-- lstmParamsToTlist' acc (LSTMLayer1 wi wh bi bh) =
--   toDynamic (toDependent wi)
--     : toDynamic (toDependent wh)
--     : toDynamic (toDependent bi)
--     : toDynamic (toDependent bh)
--     : acc
-- lstmParamsToTlist l = lstmParamsToTlist' [] l

-- ziplstmLayers :: [D.Tensor] -> [D.Tensor] -> [D.Tensor] -> [D.Tensor]
-- ziplstmLayers acc [] [] = acc
-- ziplstmLayers acc (a : b : c : d : xs) (a' : b' : c' : d' : xs') =
--   a : b : c : d : a' : b' : c' : d' : ziplstmLayers acc xs xs'

-- params
--   :: forall
--        device
--        dtype
--        inputSize
--        hiddenSize
--        numLayers
--        directionality
--        shapeOrder
--    . ParamsPerDirection
--        device
--        dtype
--        inputSize
--        hiddenSize
--        numLayers
--        shapeOrder
--        directionality
--   -> [D.Tensor]
-- params (BidirectionalParams fwd rvs) =
--   ziplstmLayers [] (lstmParamsToTlist' [] fwd) (lstmParamsToTlist' [] rvs)
-- params (UniDirectionalParams fwd) = lstmParamsToTlist' [] fwd

forward'
  :: forall
       shapeOrder
       directionality
       numLayers
       dtype
       seqLen
       batchSize
       inputSize
       outputSize
       hiddenSize
       inputShape
       outputShape
       hxShape
       device
   . ( KnownNat (NumberOfDirections directionality)
     , KnownNat numLayers
     , KnownNat batchSize
     , KnownNat hiddenSize
     , KnownRNNShapeOrder shapeOrder
     , KnownRNNDirectionality directionality
     , outputSize ~ (hiddenSize * NumberOfDirections directionality)
     , inputShape ~ RNNShape shapeOrder seqLen batchSize inputSize
     , outputShape ~ RNNShape shapeOrder seqLen batchSize outputSize
     , hxShape ~ '[numLayers * NumberOfDirections directionality, batchSize, hiddenSize]
     )
  => Bool
  -> LSTMWithInit
       inputSize
       hiddenSize
       numLayers
       directionality
       dtype
       device
  -> Tensor device dtype inputShape
  -> ( Tensor device dtype outputShape
     , Tensor device dtype hxShape
     , Tensor device dtype hxShape
     )
forward' dropoutOn (LSTMWithConstInit lstm@(LSTM _ (Dropout dropoutProb)) cc hc) input =
  Torch.Typed.Native.lstm
    @shapeOrder
    @directionality
    @numLayers
    @dtype
    @seqLen
    @batchSize
    @inputSize
    @outputSize
    @hiddenSize
    @inputShape
    @outputShape
    @hxShape
    @device
    (tmp . flattenParameters $ lstm)
    dropoutProb
    dropoutOn
    (cc', hc')
    input
 where
  tmp :: forall as . HList as -> [D.Tensor]
  tmp = _undefined
  cc' =
    reshape @hxShape
      $ expand
          @'[batchSize, numLayers * NumberOfDirections directionality, hiddenSize]
          False -- TODO: What does the bool do?
          cc
  hc' =
    reshape @hxShape
      $ expand
          @'[batchSize, numLayers * NumberOfDirections directionality, hiddenSize]
          False -- TODO: What does the bool do?
          hc

forwardWithDropout, forwardNoDropout
  :: forall
       shapeOrder
       directionality
       numLayers
       dtype
       seqLen
       batchSize
       inputSize
       outputSize
       hiddenSize
       inputShape
       outputShape
       hxShape
       device
   . ( KnownNat (NumberOfDirections directionality)
     , KnownNat numLayers
     , KnownNat batchSize
     , KnownNat hiddenSize
     , KnownRNNShapeOrder shapeOrder
     , KnownRNNDirectionality directionality
     , outputSize ~ (hiddenSize * NumberOfDirections directionality)
     , inputShape ~ RNNShape shapeOrder seqLen batchSize inputSize
     , outputShape ~ RNNShape shapeOrder seqLen batchSize outputSize
     , hxShape ~ '[numLayers * NumberOfDirections directionality, batchSize, hiddenSize]
     )
  => LSTMWithInit
       inputSize
       hiddenSize
       numLayers
       directionality
       dtype
       device
  -> Tensor device dtype inputShape
  -> ( Tensor device dtype outputShape
     , Tensor device dtype hxShape
     , Tensor device dtype hxShape
     )
-- ^ Forward propagage the `LSTM` module and apply dropout on the outputs of each layer.
--
-- >>> input :: CPUTensor 'D.Float '[5,16,10] <- randn
-- >>> lstm <- A.sample (LSTMSpecZerosInit (DropoutSpec 0.5) :: LSTMSpec 'Bidirectional D.Float 3 10 30 'SequenceFirst '(D.CPU,0) )
-- >>> forwardWithDropout lstm input
-- (Tensor Float [5,16,60] ,Tensor Float [6,16,30] ,Tensor Float [6,16,30] )
forwardWithDropout =
  forward'
    @shapeOrder
    @directionality
    @numLayers
    @dtype
    @seqLen
    @batchSize
    @inputSize
    @outputSize
    @hiddenSize
    @inputShape
    @outputShape
    @hxShape
    @device
    True
-- ^ Forward propagage the `LSTM` module (without applying dropout on the outputs of each layer).
--
-- >>> input :: CPUTensor 'D.Float '[5,16,10] <- randn
-- >>> lstm <- A.sample (LSTMSpecZerosInit (DropoutSpec 0.5) :: LSTMSpec 'Unidirectional D.Float 1 10 30 'SequenceFirst '(D.CPU,0))
-- >>> forwardNoDropout lstm input
-- (Tensor Float [5,16,30] ,Tensor Float [1,16,30] ,Tensor Float [1,16,30] )
forwardNoDropout =
  forward'
    @shapeOrder
    @directionality
    @numLayers
    @dtype
    @seqLen
    @batchSize
    @inputSize
    @outputSize
    @hiddenSize
    @inputShape
    @outputShape
    @hxShape
    @device
    False

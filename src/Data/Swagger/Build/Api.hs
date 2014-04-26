-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds         #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE TypeOperators     #-}

module Data.Swagger.Build.Api where

import Control.Applicative ((<$>))
import Control.Monad.Trans.State.Strict
import Data.Function (on)
import Data.Int
import Data.List (groupBy)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Swagger.Build.Util
import Data.Swagger.Model.Api as Api
import Data.Swagger.Model.Authorisation (Scope)

-----------------------------------------------------------------------------
-- Primitive types

prim :: PrimType -> Primitive a
prim t = Primitive t Nothing Nothing Nothing Nothing

int32 :: (Primitive Int32 -> Primitive Int32) -> DataType
int32 f = Prim . f $ prim PrimInt32

int64 :: (Primitive Int64 -> Primitive Int64) -> DataType
int64 f = Prim . f $ prim PrimInt64

float :: (Primitive Float -> Primitive Float) -> DataType
float f = Prim . f $ prim PrimFloat

double :: (Primitive Double -> Primitive Double) -> DataType
double f = Prim . f $ prim PrimDouble

string :: (Primitive String -> Primitive String) -> DataType
string f = Prim . f $ prim PrimString

bytes :: (Primitive String -> Primitive String) -> DataType
bytes f = Prim . f $ prim PrimByte

bool :: (Primitive Bool -> Primitive Bool) -> DataType
bool f = Prim . f $ prim PrimBool

date :: (Primitive UTCTime -> Primitive UTCTime) -> DataType
date f = Prim . f $ prim PrimDate

dateTime :: (Primitive UTCTime -> Primitive UTCTime) -> DataType
dateTime f = Prim . f $ prim PrimDateTime

int32' :: DataType
int32' = int32 id

int64' :: DataType
int64' = int64 id

float' :: DataType
float' = float id

double' :: DataType
double' = double id

string' :: DataType
string' = string id

bytes' :: DataType
bytes' = bytes id

bool' :: DataType
bool' = bool id

date' :: DataType
date' = date id

dateTime' :: DataType
dateTime' = dateTime id

def :: a -> Primitive a -> Primitive a
def a t = t { defaultValue = Just a }

enum :: [a] -> Primitive a -> Primitive a
enum a t = t { Api.enum = Just a }

min :: a -> Primitive a -> Primitive a
min a t = t { minVal = Just a }

max :: a -> Primitive a -> Primitive a
max a t = t { maxVal = Just a }

-----------------------------------------------------------------------------
-- Data types

ref :: Model -> DataType
ref = Ref . modelId

array :: DataType -> DataType
array (Prim  t) = Array (PrimItems t) Nothing
array (Ref   t) = Array (ModelItems t :: Items ()) Nothing
array t@(Array _ _) = t

unique :: DataType -> DataType
unique (Array t _) = Array t (Just True)
unique t           = t

-----------------------------------------------------------------------------
-- Fields occuring in multiple locations

data Common f a = Common
    { descr :: Maybe Text
    , reqrd :: Maybe Bool
    , prod  :: Maybe [Text]
    , cons  :: Maybe [Text]
    , modls :: Maybe [Model]
    , auths :: Maybe [(Text, Maybe Scope)]
    , other :: a
    }

common :: a -> Common f a
common = Common Nothing (Just True) Nothing Nothing Nothing Nothing

description :: Elem "description" f => Text -> State (Common f a) ()
description d = modify $ \c -> c { descr = Just d }

optional :: Elem "required" f => State (Common f a) ()
optional = modify $ \c -> c { reqrd = Nothing }

produces :: Elem "produces" f => Text -> State (Common f a) ()
produces t = modify $ \c -> c { prod = maybe (Just [t]) (Just . (t:)) (prod c) }

consumes :: Elem "consumes" f => Text -> State (Common f a) ()
consumes t = modify $ \c -> c { cons = maybe (Just [t]) (Just . (t:)) (cons c) }

model :: Elem "models" f => Model -> State (Common f a) ()
model m = modify $ \c -> c { modls = maybe (Just [m]) (Just . (m:)) (modls c) }

data Auth = Basic | ApiKey | OAuth2 Scope | None

authorisation :: Elem "authorisations" f => Auth -> State (Common f a) ()
authorisation a = modify $ \c ->
    c { auths = maybe (Just (f a)) (Just . (f a ++)) (auths c) }
  where
    f Basic      = [("basic", Nothing)]
    f ApiKey     = [("apiKey", Nothing)]
    f (OAuth2 s) = [("oauth2", Just s)]
    f None       = []

toAuthObj :: [(Text, Maybe Scope)] -> [(Text, [Scope])]
toAuthObj = map (\g -> (fst (head g), catMaybes $ map snd g)) . groupBy ((==) `on` fst)

-----------------------------------------------------------------------------
-- Api Decl

type ApiDeclSt = Common '["produces", "consumes", "models", "authorisations"] ApiDecl
type ApiDeclBuilder = State ApiDeclSt ()

declare :: Text -> Text -> ApiDeclBuilder -> ApiDecl
declare b v s = value $ execState s start
  where
    start   = common $ ApiDecl v b [] Nothing Nothing Nothing Nothing Nothing Nothing
    mmmm  c = map (\m -> (modelId m, m)) <$> modls c
    value c = (other c) { apiProduces       = prod c
                        , apiConsumes       = cons c
                        , models            = mmmm c
                        , apiAuthorisations = toAuthObj <$> auths c
                        }

apiVersion :: Text -> ApiDeclBuilder
apiVersion v = modify $ \c -> c { other = (other c) { Api.apiVersion = Just v } }

resourcePath :: Text -> ApiDeclBuilder
resourcePath p = modify $ \c -> c { other = (other c) { Api.resourcePath = Just p } }

-----------------------------------------------------------------------------
-- API

type ApiSt = Common '["description"] API
type ApiBuilder = State ApiSt ()

api :: Text -> ApiBuilder -> ApiDeclBuilder
api p s = modify $ \c -> do
    let d = other c
    c { other = d { apis = value (execState s start) : apis d } }
  where
    start   = common $ API p [] Nothing
    value c = (other c) { apiDescription = descr c }

type OperationSt = Common '["produces", "consumes", "authorisations"] Operation
type OperationBuilder = State OperationSt ()

operation :: Text -> Text -> OperationBuilder -> ApiBuilder
operation m n s = modify $ \c -> do
    let o = value (execState s start)
        a = other c
    c { other = a { operations = o : operations a } }
  where
    start   = common $ Operation m n (Left ()) [] Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    value c = (other c) { Api.produces   = prod c
                        , Api.consumes   = cons c
                        , authorisations = toAuthObj <$> auths c
                        }

-----------------------------------------------------------------------------
-- Operation

type ParameterSt = Common '["description", "required"] Parameter
type ParameterBuilder = State ParameterSt ()

returns :: DataType -> OperationBuilder
returns t = modify $ \c -> c { other = (other c) { returnType = Right t } }

parameter :: ParamType -> Text -> DataType -> ParameterBuilder -> OperationBuilder
parameter p n t s = modify $ \c -> do
    let op = other c
    c { other = op { parameters = value (execState s start) : parameters op } }
  where
    start   = common $ Parameter p (Right t) n Nothing Nothing Nothing
    value c = (other c) { Api.description = descr c, Api.required = reqrd c }

file :: Text -> ParameterBuilder -> OperationBuilder
file n s = modify $ \c -> do
    let op = other c
    c { other = op { Api.consumes = Just ["multipart/form-data"]
                   , parameters   = value (execState s start) : parameters op
                   }
      }
  where
    start   = common $ Parameter Form (Left File) n Nothing Nothing Nothing
    value c = (other c) { Api.description = descr c, Api.required = reqrd c }

body :: DataType -> ParameterBuilder -> OperationBuilder
body = parameter Body "body"

summary :: Text -> OperationBuilder
summary t = modify $ \c -> c { other = (other c) { Api.summary = Just t } }

notes :: Text -> OperationBuilder
notes t = modify $ \c -> c { other = (other c) { Api.notes = Just t } }

type ResponseSt = Common '["models"] Response
type ResponseBuilder = State ResponseSt ()

response :: Int -> Text -> ResponseBuilder -> OperationBuilder
response i m s = modify $ \x -> do
    let r = value $ execState s start
        o = other x
    x { other = o { responses = maybe (Just [r]) (Just . (r:)) (responses o) } }
  where
    start   = common $ Response i m Nothing
    value c = (other c) { responseModel = modelId . head <$> modls c }

deprecated :: OperationBuilder
deprecated = modify $ \c -> c { other = (other c) { Api.deprecated = Just True } }

-----------------------------------------------------------------------------
-- Parameter

multiple :: ParameterBuilder
multiple = modify $ \c -> c { other = (other c) { allowMultiple = Just True } }

-----------------------------------------------------------------------------
-- Model

type ModelSt = Common '["description"] Model
type ModelBuilder = State ModelSt ()

type PropertySt = Common '["description", "required"] Property
type PropertyBuilder = State PropertySt ()

defineModel :: ModelId -> ModelBuilder -> Model
defineModel m s = value (execState s start)
  where
    start   = common $ Model m [] Nothing Nothing Nothing Nothing
    value c = (other c) { modelDescription = descr c }

property :: PropertyName -> DataType -> PropertyBuilder -> ModelBuilder
property n t s = modify $ \c -> do
    let r = execState s $ common (Property t Nothing)
        p = (other r) { propDescription = descr r }
        m = other c
        x = maybe (Just [n]) (Just . (n:)) (requiredProps m)
        y = if Just True /= reqrd r then requiredProps m else x
    c { other = m { properties = (n, p) : properties m , requiredProps = y } }

children :: PropertyName -> [Model] -> ModelBuilder
children d tt = modify $ \c -> c { other = (other c) { subTypes = Just tt, discriminator = Just d } }

-----------------------------------------------------------------------------
-- Helpers

end :: Monad m => m ()
end = return ()

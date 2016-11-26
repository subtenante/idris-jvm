{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}

module IdrisJvm.Codegen.Common where

import           Control.Monad.RWS
import           Data.Char                  (isAlpha, isDigit)
import qualified Data.DList                 as DL
import           Data.List                  (elem, intercalate)
import           Data.List.Split            (splitOn)
import           Idris.Core.TT
import           IdrisJvm.Codegen.Assembler
import           IdrisJvm.Codegen.Types
import           IRTS.Lang

createThunkForLambda :: JMethodName -> [LVar] -> (MethodName -> DL.DList Asm) -> Cg ()
createThunkForLambda caller args lambdaCode = do
  let nArgs = length args
  lambdaIndex <- freshLambdaIndex
  let cname = jmethClsName caller
  let lambdaMethodName = sep "$" ["lambda", jmethName caller, show lambdaIndex]
  writeIns $ invokeDynamic cname lambdaMethodName
  writeDeps $ lambdaCode lambdaMethodName
  writeIns [Iconst nArgs, Anewarray "java/lang/Object"]
  let argNums = map (\(Loc i) -> i) args
      f :: (Int, Int) -> DL.DList Asm
      f (lhs, rhs) = [Dup, Iconst lhs, Aload rhs, Aastore]
  writeIns . join . fmap f . DL.fromList $ zip [0..] argNums
  writeIns [ InvokeMethod InvokeStatic (rtClassSig "Runtime") "thunk" createThunkSig False ]

createThunk :: JMethodName -> JMethodName -> [LVar] -> Cg ()
createThunk caller@(JMethodName callerCname _) fname args = do
  let nArgs = length args
      lambdaCode lambdaMethodName = createLambda fname callerCname lambdaMethodName nArgs
  createThunkForLambda caller args lambdaCode

createParThunk :: JMethodName -> JMethodName -> [LVar] -> Cg ()
createParThunk caller@(JMethodName callerCname _) fname args = do
  let nArgs = length args
      lambdaCode lambdaMethodName = createParLambda fname callerCname lambdaMethodName nArgs
  createThunkForLambda caller args lambdaCode

invokeDynamic :: ClassName -> MethodName -> DL.DList Asm
invokeDynamic cname lambda = [ InvokeDynamic "apply" ("()" ++ rtFuncSig) metafactoryHandle metafactoryArgs] where
  metafactoryHandle = Handle HInvokeStatic "java/lang/invoke/LambdaMetafactory" "metafactory" metafactoryDesc False
  metafactoryArgs = [ BsmArgGetType lambdaDesc
                    , BsmArgHandle lambdaHandle
                    , BsmArgGetType lambdaDesc
                    ]
  lambdaHandle = Handle HInvokeStatic cname lambda lambdaDesc False


createLambda :: JMethodName -> ClassName -> MethodName -> Int -> DL.DList Asm
createLambda (JMethodName cname fname) callerCname lambdaMethodName nArgs
  = DL.fromList [ CreateMethod [Private, Static, Synthetic] callerCname lambdaMethodName lambdaDesc Nothing Nothing
                  , MethodCodeStart
                  ] <>
                  join (fmap (\i -> [Aload 0, Iconst i, Aaload]) [0 .. (nArgs - 1)]) <> -- Retrieve lambda args
                  [ InvokeMethod InvokeStatic cname fname (sig nArgs) False -- invoke the target method
                  , Areturn
                  , MaxStackAndLocal (-1) (-1)
                  , MethodCodeEnd
                  ]

createParLambda :: JMethodName -> ClassName -> MethodName -> Int -> DL.DList Asm
createParLambda (JMethodName cname fname) callerCname lambdaMethodName nArgs
  = DL.fromList [ CreateMethod [Private, Static, Synthetic] callerCname lambdaMethodName lambdaDesc Nothing Nothing
                , MethodCodeStart
                ] <>
                join (fmap (\i -> [Aload 0, Iconst i, Aaload]) [0 .. (nArgs - 1)]) <> -- Retrieve lambda args
                [ InvokeMethod InvokeStatic cname fname (sig nArgs) False -- invoke the target method
                , Astore 1
                , Aload 1
                , InvokeMethod InvokeVirtual "java/lang/Object" "getClass" "()Ljava/lang/Class;" False
                , InvokeMethod InvokeVirtual "java/lang/Class" "isArray" "()Z" False
                , CreateLabel "elseLabel"
                , Ifeq "elseLabel"
                , Aload 1
                , InvokeMethod InvokeStatic cname fname "(Ljava/lang/Object;)Ljava/lang/Object;" False
                , Areturn
                , LabelStart "elseLabel"
                , Frame FAppend 1 ["java/lang/Object"] 0 []
                , Aload 1
                , Areturn
                , MaxStackAndLocal (-1) (-1)
                , MethodCodeEnd
                ]

addFrame :: Cg ()
addFrame = do
  needFrame <- shouldDescribeFrame <$> get
  nlocalVars <- cgStLocalVarCount <$> get
  if needFrame
    then do
      writeIns [ Frame FFull (succ nlocalVars) (replicate (succ nlocalVars)  "java/lang/Object") 0 []]
      modify . updateShouldDescribeFrame $ const False
    else writeIns [ Frame FSame 0 [] 0 []]

invokeError :: String -> Cg ()
invokeError x
  = writeIns [ Ldc $ StringConst x
             , InvokeMethod InvokeStatic (rtClassSig "Runtime") "error" "(Ljava/lang/Object;)Ljava/lang/Object;" False
             ]

locIndex :: LVar -> Int
locIndex (Loc i) = i
locIndex _       = error "Unexpected global variable"

jname :: Name -> JMethodName
jname n = JMethodName cname methName
  where
    idrisName = showCG n
    names = splitOn "." $ concatMap jchar idrisName
    (cname, methName) = f [] names

    f [] []     = ("main/Main", "main")
    f [] [x]    = ("main/Main", x)
    f [] [x, y] = ("main/" ++ x, y)
    f p []      = (intercalate "/" $ reverse p, "main")
    f p [x, y]  = (intercalate "/" $ reverse (x:p), y)
    f p (x:xs)  = f (x:p) xs

    allowed x = x `elem` ("._$" :: String)

    jchar x | isAlpha x || isDigit x || allowed x = [x]
            | otherwise = "_" ++ show (fromEnum x) ++ "_"


newBigInteger :: Integer -> Cg ()
newBigInteger i
  = writeIns [ New "java/math/BigInteger"
             , Dup
             , Ldc $ StringConst (show i)
             , InvokeMethod InvokeSpecial "java/math/BigInteger" "<init>" "(Ljava/lang/String;)V" False
             ]

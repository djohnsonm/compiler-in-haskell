module DLC.Compile
    (compileTo)
where

import Data.Map hiding (map, foldl, lookup)
import Data.Set hiding (map, foldl)
import System.IO (hPutStr, hPutStrLn, Handle)
import Text.Regex.Posix

import DLC.CompileDataObject
import DLC.TAST

regTable :: [[String]]
regTable = [
    ["%rax", "%eax",  "%ax",  "%al"],
    ["%rdi", "%edi",  "%di", "%dil"],
    ["%rsi", "%esi",  "%si", "%sil"],
    ["%rdx", "%edx",  "%dx",  "%dl"],
    ["%rcx", "%ecx",  "%cx",  "%cl"],
    [ "%r8", "%r8d", "%r8w", "%r8b"],
    [ "%r9", "%r9d", "%r9w", "%r9b"]]

compileTo :: Handle -> CDO -> IO ()
compileTo h cdo =
    let r1 = foldl (compileClass cdo) ([], []) (cdoGetClasses cdo)
        (asData, asText) = foldl (compileMethod cdo Nothing) r1 (cdoGetMethods cdo)
    in do
        writeDataSection h asData
        writeTextSection h asText

writeDataSection :: Handle -> [String] -> IO ()
writeDataSection h d = do {hPutStrLn h ".data"; mapM_ (hPutStrLn h) d}

writeTextSection :: Handle -> [String] -> IO ()
writeTextSection h d = do
    hPutStrLn h ".text"
    mapM_ (\x -> if (x =~ "^.*:$") :: Bool
                 then hPutStrLn h x
                 else hPutStrLn h $ "    " ++ x) d

compileClass :: CDO -> ([String], [String]) -> String -> ([String], [String])
compileClass cdo (asData, asText) cName =
    let (_, superName, attrList, methodList) = cdoGetClassDef cdo cName
        -- generating method table; changes:
        --     asData => asData'
        methodTable :: [String]
        methodTable = cdoGetClassMethodTable cdo cName
        methodTable' :: [String] -- className$$methodName
        methodTable' = map (\cm -> case resolveClassName cm of
                                        Nothing -> error $ "cannot find def of " ++ cm
                                        Just x -> (x ++ "$" ++ cm))
                           methodTable
        sup = if cName == "Object" then "$0" else superName ++ "$$"
        asData' = asData ++ [cName ++ "$$:", "    .quad " ++ sup] ++
                  map ("    .quad " ++) methodTable'
        resolveClassName :: String -> Maybe String
        resolveClassName cmName = r cName
            where r :: String -> Maybe String
                  r cName =
                    case cdoGetClassDef cdo cName of
                        (_, _, _, cmDefList) ->
                            if any (\(_, _, (m, _, _, _)) -> m == cmName) cmDefList
                            then Just cName
                            else if cName == "Object"
                                 then Nothing
                                 else r $ cdoGetSuperClass cdo cName
    in
        foldl (\r (_, _, (m, _, _, _)) -> compileMethod cdo (Just cName) r m)
              (asData', asText) methodList

-- when compileMethod is applied to class attribute methods,
-- the 2nd method is "Just superClassName".
-- else it should be Nothing.
compileMethod :: CDO -> Maybe String -> ([String], [String]) -> String -> ([String], [String])
compileMethod cdo cName (asData, asText) mName =
    let mName' = case cName of
                    (Just x) -> x ++ "$" ++ mName
                    Nothing -> mName
        cName' = case cName of
                    (Just x) -> x
                    Nothing -> ""
        mDef :: TMethodDef -- (String, TType, [(String, TType)], [TBodyStmt])
        (isStatic, mDef) = if cName /= Nothing
                           then case cdoGetClassMethodDef cdo cName' mName of
                                    (Just (_, y, x)) -> (y, x)
                                    Nothing -> error $ "no def of " ++ mName ++ " in " ++ cName'
                           else (False, cdoGetMethodDef cdo mName)
        (tp, argList, mBody) =
            case mDef of
                (_, mt, mArgs, mBody) ->
                    (mt, if cName /= Nothing && not isStatic
                         then ("this", TClass cName'):mArgs
                         else mArgs,
                     mBody)
        -- now we have:
        -- cName:   Maybe String       => class name
        -- mName:   String             => method name
        -- tp:      TType              => return type
        -- argList: [(String, TType)]  => argument list (modified for class attr methods)
        -- mBody:   [TBodyStmt]        => method body
        --
        -- mName':  String  => className$methodName or just methodName
        stackUsage :: [(String, TType)]
        stackUsage = (if (length argList) == 0
                      then [("", TUnknown), ("", TUnknown)]
                      else if (length argList) == 1
                           then [("", TUnknown)]
                           else []) ++ argList
        beforeBody :: [String]
        beforeBody = ["push %rbp", "mov %rsp, %rbp"] ++
                     map (\(rIdx, _) -> "push " ++ (regTable !! rIdx !! 0))
                         (zip [1..6] stackUsage) ++
                     (concat $ map (\(offset, _) ->
                                        ["mov " ++ (show offset) ++ "(%rbp), %rax",
                                         "push %rax"])
                                   -- last arg: 16
                                   -- first arg: ???
                                   $ reverse (zip [16, 24..] $ reverse $ drop 6 stackUsage))
        asDataInc :: [String]
        asMethodBody :: [String]
        su :: [(String, TType)]
        (_, asDataInc, asMethodBody, _, su, _) =
            foldl cBodyStmt (cdo, [], [], 1, stackUsage, mName') mBody
        afterBody :: [String]
        afterBody = ["add $" ++ (show $ 8 * (length su)) ++ ", %rsp",
                     "pop %rbp",
                     "ret"]
    in
        (asData ++ asDataInc,
         asText ++ [".globl " ++ mName, mName' ++ ":"]
         ++ beforeBody ++ asMethodBody ++ afterBody)

isIntType :: TType -> Bool
isIntType TInt = True
isIntType TInt32 = True
isIntType TByte = True
isIntType _ = False

getIntTypeRank :: TType -> Int
getIntTypeRank TInt = 8
getIntTypeRank TInt32 = 4
getIntTypeRank TByte = 1

-- for assignment / function call
canCoerceInto :: CDO -> TType -> TType -> Bool
canCoerceInto _ TVoid TVoid = True
canCoerceInto _ TVoid _     = False
canCoerceInto _ _     TVoid = False
canCoerceInto _ TUnknown _ = True
canCoerceInto cdo (TClass cFrom) (TClass cTo) =
    if cFrom == cTo
    then True
    else if cFrom == "Object"
         then False
         else canCoerceInto cdo (TClass $ cdoGetSuperClass cdo cFrom) (TClass cTo)
canCoerceInto cdo (TArray dep1 tp1) (TArray dep2 tp2) =
    if dep1 /= dep2
    then False
    else canCoerceInto cdo tp1 tp2
canCoerceInto cdo t1 t2 | t1 == t2  = True
                        | otherwise =
    let s = Data.Set.fromList [TInt, TInt32, TByte] -- bool canNOT be converted.
    in Data.Set.member t1 s && Data.Set.member t2 s

-- for +, -, *, /
coerce :: TType -> TType -> TType
coerce t1 t2 = if getIntTypeRank t1 > getIntTypeRank t2 then t1 else t2

-- checkCanCoerceInto :: CDO -> TType -> TType -> Bool
-- checkCanCoerceInto cdo t1 t2 =
--     if canCoerceInto cdo t1 t2
--     then True
--     else error $ "cannot coerce " ++ (show t1) ++ " into " ++ (show t2) -- TROLOLOLOL


-- 0: the first arg, "-8(%rbp)".
getStackVar :: Int -> String
getStackVar n = "-" ++ (show $ (n + 1) * 8) ++ "(%rbp)"
    
--                 .data     .text  jmpTag  stack usage      method name
type CArg = (CDO, [String], [String], Int, [(String, TType)], String)

cBodyStmt :: CArg -> TBodyStmt -> CArg
cBodyStmt x (TBSStmt s) = cStmt x s
cBodyStmt x (TBSExpr e) =
    let (cdo, d, t, jt, su, fn) = cExpr x e
    in (cdo, d,
        t ++ ["pop %rdi"], -- pop the temp var out of stack
        jt,
        init su, -- clean su record
        fn)

getJTag :: String -> Int -> String
getJTag f n = "JTag_" ++ f ++ "_" ++ (show n)

caAppendText :: [String] -> CArg -> CArg
caAppendText t (a, b, c, d, e, f) = (a, b, c++t, d, e, f)

caAddJTag :: Int -> CArg -> CArg
caAddJTag n (a, b, c, d, e, f) = (a, b, c, d+n, e, f)

caGetJTagN :: CArg -> Int
caGetJTagN (_, _, _, a, _, _) = a

getFuncReturnType :: CDO -> String -> Maybe TType
getFuncReturnType cdo fName = -- fName: "C$func" or "func"
    let mName = reverse $ takeWhile ('$' /=) $ reverse fName
        cName = let t = take (length fName - length mName) fName
                in if length t == 0
                   then t -- "func" => ""
                   else init t -- "C$func" => "C"
    in if cName == ""
       then case (cdoGetMethodDef cdo mName) of
                (_, tp, _, _) -> Just tp
       else case (cdoGetClassMethodDef cdo cName mName) of
                Nothing -> Nothing
                Just (_, _, (_, tp, _, _)) -> Just tp

cStmt :: CArg -> TStmt -> CArg
cStmt ca@(cdo, d, t, j, su, mn) (TStmtVarDef (vName, tp, expr)) = -- int i = 1;
    case lookup vName su of
        -- cExpr will push result of the expression onto the stack,
        -- so no need to pop the temporary variable out in assembly.
        Nothing -> let (_, d', t', j', su', _) = cExpr ca expr
                       (_, tp_e) = last su'
                   in if canCoerceInto cdo tp_e tp
                      then (cdo, d', t', --  ++ ["push " ++ (getStackVar $ length su')],
                            j', su ++ [(vName, tp)], mn) -- yes, su, but not su'
                      else error $ "cannot coerce " ++ (show tp_e) ++ " into " ++ (show tp)
        -- variables defined inside blocks(for, while...) will be the same as if they are
        -- defined at beginning of the whole method.
        Just x -> error $ "multiple definition of " ++ vName
cStmt ca@(cdo, dataSec, textSec, jt, su, mn) (TStmtPrint e) = -- print(15)
    let (_, dataSec', textSec', _, su', _) = cExpr ca e
        (_, tp_e) = last su'
        ptname = if tp_e == TInt || tp_e == TInt32
                 then "_dlib_print_num"
                 else case tp_e of
                        TByte -> "_dlib_print_char"
                        TBool -> "_dlib_print_bool"
        callcText = ["pop " ++ (regTable !! 1 !! 0),
                     "call " ++ ptname] -- no return value, only one arg
    in (cdo, dataSec', textSec' ++ callcText, jt, su, mn) -- not su'

cStmt ca@(cdo, dataSec, textSec, jt, su, fName) (TStmtIf e b1 b2) = -- if (c) {b1} else {b2}
    let (_, dataSec', textSec', _, su', _) = cExpr ca e
        (_, tp_e) = last su'
        elseT = getJTag fName jt
        endT = getJTag fName (jt+1)
        condSec = ["pop %rdi", "cmp %rdi, $0", "jz " ++ elseT]
        ca' = ((caAddJTag 2) . (caAppendText condSec))
              (cdo, dataSec', textSec', jt, su, fName)
        ca'' = caAppendText ["jmp " ++ endT, elseT ++ ":"]
                            (foldl cBodyStmt ca' b1)

        ca''' = caAppendText [endT ++ ":"] (foldl cBodyStmt ca'' b2)
    in if not (tp_e == TBool || tp_e == TUnknown)
       then error $ "expression in if's cond section must be boolean, found " ++ (show tp_e)
       else ca'''

-- for (initS; condS; incrS) {b}
--   =>
-- initS;
-- while(condS) {b; incrS;}
-- [undef]
cStmt ca@(cdo, dataSec, textSec, jt, su, fName) (TStmtFor initS condS incrS b) =
    let whileStmt = TStmtWhile condS (b ++ [TBSExpr incrS])
        ca' = case initS of
                Left e -> cExpr ca e
                Right (tp, varList) ->
                    foldl (\a (vName, e) -> cStmt a (TStmtVarDef (vName, tp, e)))
                          ca varList
        nTVar = case initS of
                    Left _ -> 0
                    Right (_, vl) -> length vl
        (_, dataSec', textSec', jt', su', _) = cStmt ca' whileStmt
        su'' = reverse $ drop nTVar $ reverse su'
        undefS = if nTVar /= 0
                 then ["add " ++ (show (nTVar * 8)) ++ "%rsp"]
                 else []
    in (cdo, dataSec', textSec' ++ undefS , jt', su'', fName)

-- sTag:
--  if not e:
--      goto eTag
--  [b]
--  goto sTag
-- eTag:
cStmt ca@(cdo, dataSec, textSec, jt, su, fName) (TStmtWhile e b) = -- while(e) {b;}
    let sTag = getJTag fName jt
        eTag = getJTag fName (jt+1)
        (_, dataSec', textSec', _, su', _) = cExpr ca e
        (_, tp_e) = last su'
        checkCondSec = [sTag ++ ":", "pop %rdi", "cmp %rdi, $0", "jz " ++ eTag]
        ca' = (cdo, dataSec', textSec' ++ checkCondSec, jt+2, su, fName) -- su, not su'
        ca'' = caAppendText ["jmp " ++ sTag, eTag ++ ":"] (foldl cBodyStmt ca' b)
    in if not (tp_e == TBool || tp_e == TUnknown)
       then error "expression in while's cond section must be bool"
       else ca''

-- FIXME: do-while


-- FIXME: "return;" with no argument for void methods
cStmt ca@(cdo, _, _, _, su, fName) (TStmtReturn e) =
    let ca'@(_, _, _, _, su', _) = cExpr ca e
        (_, tp_e) = last su'
        tp = case getFuncReturnType cdo fName of
                    Just x -> x
        cleanUp = ["pop %rax", "add $" ++ (show $ (length su) * 8) ++ ", %rsp", "pop %rbp", "ret"]
    in if {- tp == TVoid || -} canCoerceInto cdo tp_e tp
       then caAppendText cleanUp ca' -- stack usage is incurrect; but it will be thrown away
       else error $ "return value type for " ++ fName ++ " is incorrect"


-- -- for non-static class methods only.
-- -- static class methods don't use "this".
-- getCurrentClassName :: CArg -> Maybe String
-- getCurrentClassName (_, _, _, _, su, _) =
--     case filter (\(v, t) -> v == "this") of
--         [] -> Nothing
--         ((_, (TClass s)):_) -> Just s
hasThisInStack :: CArg -> Bool
hasThisInStack (_, _, _, _, su, _) = any (\(v, _) -> v == "this") su

-- for regular/C-bridge methods only
getMethodSignature :: CArg -> String -> Maybe (TType, [TType])
getMethodSignature ((_, _, mDefMap, cmDefMap), _, _, _, _, _) mName =
    case Data.Map.lookup mName mDefMap of
        Just (_, retTp, argList, _) -> Just (retTp, map (\(_, t) -> t) argList)
        Nothing -> case Data.Map.lookup mName cmDefMap of
                    Just (_, r) -> Just r
                    Nothing -> Nothing
-- for class methods only (no matter static or not);
-- includes "this" for non-static methods.
getClassMethodSignature :: CArg -> String -> String ->
                           Maybe (String, TClassAccessModifier, Bool, TType, [TType])
getClassMethodSignature ca@(_, cDefMap, _, _) cName mName =
    case Data.Map.lookup cName cDefMap of
        Nothing -> Nothing
        Just (_, supClass, _, mDefList) ->
            case find (\(_, _, (f, _, _, _)) -> f == mName) mDefList of
                Just (acc, isStatic, (_, retTp, argList, _)) ->
                    Just (cName, acc, isStatic, retTp,
                          (if isStatic then [] else [TClass cName]) ++ map (\(_, t) -> t) argList)
                Nothing -> if cName == "Object"
                           then Nothing
                           else getClassMethodSignature ca supClass mName

isSuperClassOf :: CArg -> String -> String -> Bool
isSuperClassOf -- FIXME

cExpr :: CArg -> TExpr -> CArg

-- (this.)hello()
-- (MyClass.)hello()
-- or just hello()
--
-- o.hello()
-- this.hello()
-- super.hello()
-- MyClass.hello()
-- 
-- non-static class methods:
--      fName => "MyClass$func", has "this" in su
-- static class methods:
--      fName => "MyClass$func", no "this" in su
-- regular methods:
--      fName => "func", no "this" in su
cExpr ca@(_, _, _, _, _, cf) (TExprFunCall maybeE f args) =
    case maybeE of
        Nothing ->
            if not insideClassBody
            then callRegF
            else case getClassMethodSignature ca curClass f of
                    Nothing -> callRegF
                    Just (c, acc, isStatic, retTp, tpList) ->
                        if isStatic && (c == curClass || acc == TPublic || acc == TProtected)
                        then callFunc ca (c ++ "$" ++ f) args tpList retTp
                        else error $ "cannot call " ++ c ++ "$" ++ f ++ " inside " ++ cf
        Just e ->
            let (eIsClassName, eClassName) = exprIsClassName e
            in if eIsClassName
               then case getClassMethodSignature ca eClassName f of
                        Just (c, acc, isStatic, retTp, tpList) ->
                            if isStatic && (acc == TPublic || curClass == c ||
                                            (curClass /= "" &&
                                             acc == TProtected &&
                                             isSuperClassOf ca c curClass))
                            then callFunc ca (eClassName ++ "$" ++ f) args tpList retTp
                            else error $ "cannot call " ++ eClassName ++ "$" ++ f ++
                                         " inside " ++ cf
                        Nothing -> error $ "cannot call " ++ eClassName ++ "$" ++ f
               else 
    where
        exprIsClassName :: TExpr -> (Bool, String)
        exprIsClassName (TExprVar s) =
            let matches = ((s =~ "^_*[A-Z][A-Za-z0-9_]*$") :: Bool)
            in if matches
               then (True, s)
               else (False, "")
        exprIsClassName _ = (False, "")

        callRegF :: CArg
        callRegF = case getMethodSignature ca f of
                            Nothing -> error $ "cannot find function " ++ f
                            Just (retTp, argTpList) -> callFunc ca f args argTpList retTp

        insideClassBody = any ('$' ==) cf
        curFName = reverse $ takeWhile ('$' /=) $ reverse cf
        curClass = if insideClassBody
                   then take ((length cf) - 1 - (length curFName)) cf
                   else ""
        callFunc :: CArg -> String -> [TExpr] -> [TType] -> TType -> CArg
        callFunc ca f args argTpList retTp =
            if (length args /= argTpList)
            then error $ "wrong number of args on calling " ++ f
            else let args' = (drop 6 args) ++ (reverse (take 6 args))
                     argTpList' = (drop 6 argTpList) ++ (reverse (take 6 argTpList))
                     ca'@(cdo', dataSec', textSec', jt', su', mn') = foldl cExpr ca args'
                     wrongTp = find (\((_, tp), aTp) -> (not $ canCoerceInto cdo' tp aTp))
                               (zip (reverse su') argTpList')
                 in case wrongTp of
                        (Just ((_, tp), aTp)) ->
                            error $ "cannot coerce " ++ (show tp) ++ " into " ++ (aTp)
                        Nothing ->
                            let (popArgs, _) =
                                    foldl (\(acc, rt) _ ->
                                            (acc ++ ["pop " ++ ((head rt) !! 0)],
                                             drop 1 rt))
                                          ([], (drop 1 regTable))
                                          (reverse $ take 6 argTpList')
                                textSec'' = textSec' ++ popArgs -- FIXME: call func && rax && alignment && clean up
                                su'' = reverse $ drop (length $ take 6 argTpList') (reverse su')
                            in (cdo', dataSec', textSec'', jt', su'', mn')

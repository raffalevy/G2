module WhereFuncs2 where

{-@ h :: x:Int -> {y:Int | x <= y} @-}
h :: Int -> Int
h x = hCalls x 7
    where
        -- Incorrect specification:
        -- hCalls x 0 = x so then x < x is false
        {-@ hCalls :: x:Int -> Int -> {z:Int | x < z} @-}
        hCalls :: Int -> Int -> Int
        hCalls x y
            | y > 0 = hCalls (x + 1) (y - 1)
            | otherwise = x

{-@ i :: x:Int -> { y:Int | x == y } @-}
i :: Int -> Int
i = iCalls
    where
        -- Correct specification, but not enough to prove i
        {-@ iCalls :: x:Int -> { y:Int | x >= y } @-}
        iCalls :: Int -> Int
        iCalls x = x
module SimpleMath where

{-@ type Pos = {v:Int | 0 < v} @-}

{-@ abs2 :: x:Int -> Pos @-}
abs2 :: Int -> Int
abs2 x
    | x > 0 = x
    | otherwise = -x

{-@ add :: x:Int -> y:Int -> {z:Int | x <= z && y <= z}@-}
add :: Int -> Int -> Int
add x y = x + y

{-@ subToPos :: x:Pos -> {y:Int | x >= y} -> Pos @-}
subToPos :: Int -> Int -> Int
subToPos x y = x - y
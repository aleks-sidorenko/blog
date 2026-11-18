+++
title = "Getting Started with Haskell"
date = 2026-02-26
description = "A practical introduction to Haskell: basic syntax, type signatures, pattern matching, and higher-order functions."
path = "blog/2026/02/getting-started-with-haskell"
[taxonomies]
tags = ["haskell", "functional-programming", "tutorial"]
categories = ["programming"]
+++

Haskell is a purely functional programming language known for its strong static type system, lazy evaluation, and mathematical elegance. This post walks through the basics that make it a great choice for building reliable software.

<!-- more -->

## Basic syntax and types

Every value in Haskell has a type. The compiler infers types on its own, but writing explicit type signatures is considered good practice:

```haskell
-- Type signature followed by definition
greeting :: String
greeting = "Hello, Haskell!"

-- Numbers
answer :: Int
answer = 42

-- Booleans
isEnabled :: Bool
isEnabled = True
```

Functions are defined with a type signature and one or more equations:

```haskell
-- A simple function
double :: Int -> Int
double x = x * 2

-- Multiple arguments
add :: Int -> Int -> Int
add x y = x + y
```

Multi-argument functions use currying: `add` takes one `Int` and returns a function that takes another `Int`.

## Pattern matching

Pattern matching lets you pull data apart and handle different cases cleanly:

```haskell
factorial :: Integer -> Integer
factorial 0 = 1
factorial n = n * factorial (n - 1)

describe :: Int -> String
describe 0 = "zero"
describe 1 = "one"
describe _ = "something else"
```

This works with any data type, including lists:

```haskell
head' :: [a] -> Maybe a
head' []    = Nothing
head' (x:_) = Just x

length' :: [a] -> Int
length' []     = 0
length' (_:xs) = 1 + length' xs
```

## Higher-order functions

Functions that take or return other functions are central to Haskell:

```haskell
-- map applies a function to every element
doubleAll :: [Int] -> [Int]
doubleAll = map (* 2)

-- filter keeps elements matching a predicate
evens :: [Int] -> [Int]
evens = filter even

-- foldr reduces a list to a single value
sum' :: [Int] -> Int
sum' = foldr (+) 0
```

Function composition with `.` lets you build pipelines:

```haskell
-- Sum of all even numbers doubled
process :: [Int] -> Int
process = sum' . map (* 2) . filter even
```

## Algebraic data types

Haskell's type system is at its best with algebraic data types (ADTs):

```haskell
data Shape
  = Circle Double
  | Rectangle Double Double
  | Triangle Double Double Double

area :: Shape -> Double
area (Circle r)        = pi * r * r
area (Rectangle w h)   = w * h
area (Triangle a b c)  = let s = (a + b + c) / 2
                          in sqrt (s * (s-a) * (s-b) * (s-c))
```

## A practical example: word frequency counter

Here are those ideas put together into something useful, a program that counts word frequencies in a text:

```haskell
import Data.Char (toLower)
import Data.List (group, sort, sortBy)
import Data.Ord (Down(..), comparing)

type WordCount = (String, Int)

-- Normalize, split, count, and sort by frequency
wordFrequencies :: String -> [WordCount]
wordFrequencies =
    sortBy (comparing (Down . snd))
  . map (\ws -> (Prelude.head ws, length ws))
  . group
  . sort
  . words
  . map toLower

-- Pretty print the results
printFrequencies :: [WordCount] -> IO ()
printFrequencies = mapM_ (\(w, c) -> putStrLn $ w ++ ": " ++ show c)

main :: IO ()
main = do
  let text = "to be or not to be that is the question"
  printFrequencies $ wordFrequencies text
```

Running this produces:

```
be: 2
to: 2
is: 1
not: 1
or: 1
question: 1
that: 1
the: 1
```

## What's Next

That covers the basics. Haskell also has type classes, monads, concurrent programming, and a large ecosystem of libraries, and I'll go into those in more depth in future posts.

If you want to follow along, install GHC through [GHCup](https://www.haskell.org/ghcup/), or if you use Nix, run `nix-shell -p ghc`.

import Base

# `do` works for any monad with `bind` and `pure` — here, Maybe.
def add_strs(a: String, b: String) -> Maybe<&2, U32>:
  do Maybe<&2, U32>:
    x : U32 <- U32.read(a)   # a None here short-circuits the whole block
    y : U32 <- U32.read(b)
    return (x + y : U32)

def show(m: Maybe<&2, U32>) -> String:
  match m:
    case Some{v}:
      U32.show(v)
    case None{}:
      "nothing"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("40 + 2   = " ++ show(add_strs("40", "2")))
    IO.print("40 + oi  = " ++ show(add_strs("40", "oi")))

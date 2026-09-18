import Base

# An Array<T> is a `Type`: exactly one owner at all times, so `a[i] <- v`
# rewrites the slot in place and hands the same array back -- pure, no copy.
# A read hands the array back *beside* the element, for the same reason.
#
# Note: a destructuring let (like a match) can only scrutinize a parameter or
# a pattern-bound variable, never a computed value -- so the pair comes into
# its own def as a parameter.

def snd(p: Array<U32> & U32) -> U32:
  (arr, x) = p   # `arr` is affine; dropping it is free
  x

def build() -> Array<U32> & U32:
  a = [0 : U32*8n]   # 8 slots, all 0
  a[5] <- 42         # in-place rewrite; on its own line it re-binds `a`
  a[5]               # as the last statement: (array, element)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("a[5] after write = " ++ U32.show(snd(build())))

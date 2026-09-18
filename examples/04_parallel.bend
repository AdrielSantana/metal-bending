import Base

# `a b = f(x) g(y)` is a parallel call: the two sides are independent.
# Compiled native, this spreads over CPU cores; `pow2!(n)` sends it to the GPU.
def pow2(+n: Nat) -> U32:
  match n:
    case 0n:
      1
    case 1n+p:
      a b = pow2(p) pow2(p)
      (a + b : U32)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("2^20 = " ++ U32.show(pow2(20n)))

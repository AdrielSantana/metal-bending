import Base

def sum(xs: List<U32>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      sum(t, (acc + h : U32))

# loop counters are Nat: `1n+p` hands a smaller `p` to recurse on
def fib(n: Nat, a: U32, +b: U32) -> U32:
  match n:
    case 0n:
      a
    case 1n+p:
      fib(p, b, (a + b : U32))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("sum [1,2,3,4] = " ++ U32.show(sum([1, 2, 3, 4], 0)))
    IO.print("fib 30        = " ++ U32.show(fib(30n, 0, 1)))

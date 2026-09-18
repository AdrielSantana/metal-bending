import Base

type Shape is Data:
  Circle{r: U32}
  Square{s: U32}

def area(x: Shape) -> U32:
  match x:
    case Circle{+r}:
      (3 * r * r : U32)
    case Square{+s}:
      (s * s : U32)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print("circle r=3 -> " ++ U32.show(area(Circle{3})))
    IO.print("square s=5 -> " ++ U32.show(area(Square{5})))

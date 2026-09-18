import Base

# Bend has no hex literals, so colors get built from components.
# The Metal kernel that rasterizes the window reads them as 0xRRGGBB.
def rgb(r: U32, g: U32, b: U32) -> U32:
  (r * 65536 + g * 256 + b : U32)

# An Image is a quadtree: Pix paints a square, Qua splits it in four.
def scene() -> Image:
  Qua{ Pix{rgb(229, 72, 77)},  Pix{rgb(48, 164, 108)}
     , Pix{rgb(0, 144, 255)},  Pix{rgb(255, 197, 61)} }

def tick(events: List<Event>, s: Unit) -> IO(Maybe<Unit>):
  match events:
    case Nil{}:
      IO.pure(Maybe<Unit>, Some{s})
    case Con{Close{}, rest}:
      IO.pure(Maybe<Unit>, None{})
    case Con{e, rest}:
      tick(rest, s)

def main() -> IO(Unit):
  App.run(~Unit, ~App{s => (s, scene()), tick}, "Bend", 512, 512, Unit{})

# LAWS.bend -- the spec. A human writes this; the AI never touches it.
# Each `law` is an open claim until PROOF.bend closes it.

import Base
import ./src/math.bend as M

# for every x, x + 0 == x
law add_zero:
  for x: Nat
  {Nat.add(x, 0n) == x : Nat}

# appending the empty list on the right changes nothing
law append_nil:
  for xs: List<Nat>
  {List.append(&1, Nat, xs, Nil{}) == xs : List<Nat>}

# about *our* code: total distributes over a cons
law total_cons:
  for h: Nat
  for t: List<Nat>
  {M.total(h <> t) == Nat.add(h, M.total(t)) : Nat}

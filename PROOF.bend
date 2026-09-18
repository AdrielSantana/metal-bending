# PROOF.bend -- the gate. `bend PROOF.bend` fails while any law is open or
# false, and prints "All terms check." once every one of them holds.
#
# There are no tactics: a proposition is a type, a proof is a def of that type.
#   {==}        proves {a == b : T} when both sides compute to the same term
#   %e : P      rewrites with e : {a == b : T}; P is the goal with `_` marking b
#   a recursive call IS the induction hypothesis

import Base
import ./LAWS.bend as Laws

def Laws.add_zero(x):
  match x:
    case 0n:
      {==}                                                    # base: 0 + 0 == 0
    case 1n+p:
      %Laws.add_zero(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}    # step: induction
      {==}

def Laws.append_nil(xs):
  match xs:
    case Nil{}:
      {==}
    case Con{h, t}:
      %Laws.append_nil(t) : {h <> List.append(&1, Nat, t, Nil{}) == h <> _ : List<Nat>}
      {==}

def Laws.total_cons(h, t):
  {==}   # true by definition of `total`: reflexivity closes it

-------------------------- MODULE kitty_lean_folds --------------------------
(***************************************************************************)
(* What the infoview's folds and widget buttons do over time               *)
(* (kitty-lean--fold-fill, kitty-lean--trace-fetch,                        *)
(* kitty-lean-widgets--edit-buffer).                                       *)
(*                                                                         *)
(* A trace node's children are asked from Lean when it is opened; the      *)
(* answer comes back later, after any number of new renders (the cursor    *)
(* moved, Lean finished, the infoview was closed).  It is put in only if   *)
(* the render it was asked for is still shown; otherwise its references    *)
(* are released at once.  Every render releases the references of the     *)
(* one before, the children's included.                                   *)
(*                                                                         *)
(* An [apply] button (Try this, MakeEditLink) edits the file with ranges   *)
(* Lean computed for the text the render was asked for.  It edits only     *)
(* while the file is still that text; otherwise it asks for a refresh.     *)
(*                                                                         *)
(* Answers of a refresh that is not rendered (a newer one was asked, one  *)
(* answer failed, the infoview was paused) are released too.               *)
(*                                                                         *)
(* Lean counts each time it sends a reference and forgets the object when  *)
(* as many releases came back; here each reference is a fresh number, so  *)
(* "released" is "its count went back to zero".                           *)
(*                                                                         *)
(* Bug names the mistake test/run.sh checks that TLC catches:              *)
(*   "norender"  fill whatever render is shown (no render id check)        *)
(*   "norelease" drop a late trace answer without releasing it             *)
(*   "nodrop"    drop a refresh that is not rendered without releasing it  *)
(*   "notick"    a button edits whatever the text is now                   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS MaxEdits, MaxRenders, MaxOpens, Bug

VARIABLES
  doc,        \* the file's text (buffer-chars-modified-tick), counted
  edits,      \* edits made, by the user or by buttons
  asked,      \* the text the latest refresh asked about (kitty-lean--last-key's tick)
  rid,        \* kitty-lean--render-id
  shown,      \* [rid, ver: its text, refs: references it holds, fills: renders its fills were asked in]
  pending,    \* children asked for and not answered: <<the render each was asked in, which open>>
  opens,
  nextRef,
  released,   \* references told to Lean as released
  applied,    \* buttons pressed that edited: [for: the text Lean meant, at: the text edited]
  drops       \* refreshes whose answers were not rendered

vars == <<doc, edits, asked, rid, shown, pending, opens, nextRef, released, applied, drops>>

Init == /\ doc = 0 /\ edits = 0 /\ asked = 0 /\ rid = 1
        /\ shown = [rid |-> 1, ver |-> 0, refs |-> {1}, fills |-> {}]
        /\ pending = {} /\ opens = 0 /\ nextRef = 2 /\ released = {} /\ applied = {} /\ drops = 0

\* the user types
Edit == /\ edits < MaxEdits
        /\ doc' = doc + 1 /\ edits' = edits + 1
        /\ UNCHANGED <<asked, rid, shown, pending, opens, nextRef, released, applied, drops>>

\* a refresh asks Lean about the text as it is now
Ask == /\ asked # doc
       /\ asked' = doc
       /\ UNCHANGED <<doc, edits, rid, shown, pending, opens, nextRef, released, applied, drops>>

\* its answers come: a new render (with a fresh reference); the old one's
\* references are released
Render == /\ rid < MaxRenders
          /\ rid' = rid + 1
          /\ shown' = [rid |-> rid + 1, ver |-> asked, refs |-> {nextRef}, fills |-> {}]
          /\ released' = released \cup shown.refs
          /\ nextRef' = nextRef + 1
          /\ UNCHANGED <<doc, edits, asked, pending, opens, applied, drops>>

\* the answers of a refresh that is not rendered (superseded, failed, paused)
Dropped == /\ nextRef' = nextRef + 1
           /\ released' = IF Bug = "nodrop" THEN released ELSE released \cup {nextRef}
           /\ drops' = drops + 1
           /\ UNCHANGED <<doc, edits, asked, rid, shown, pending, opens, applied>>

\* TAB on a trace node: its children are asked for
Open == /\ opens < MaxOpens
        /\ opens' = opens + 1
        /\ pending' = pending \cup {<<rid, opens>>}
        /\ UNCHANGED <<doc, edits, asked, rid, shown, nextRef, released, applied, drops>>

\* Lean answers, with a reference for the children
Answer(p) ==
  LET r == p[1] IN
  /\ p \in pending
  /\ pending' = pending \ {p}
  /\ nextRef' = nextRef + 1
  /\ IF r = rid \/ Bug = "norender"
     THEN /\ shown' = [shown EXCEPT !.refs = @ \cup {nextRef}, !.fills = @ \cup {r}]
          /\ UNCHANGED released
     ELSE /\ released' = IF Bug = "norelease" THEN released ELSE released \cup {nextRef}
          /\ UNCHANGED shown
  /\ UNCHANGED <<doc, edits, asked, rid, opens, applied, drops>>

\* [apply]: edits if the file is the text the render is for, else refreshes
Press == /\ edits < MaxEdits
         /\ IF shown.ver = doc \/ Bug = "notick"
            THEN /\ applied' = applied \cup {[for |-> shown.ver, at |-> doc]}
                 /\ doc' = doc + 1 /\ edits' = edits + 1
                 /\ UNCHANGED asked
            ELSE /\ asked' = doc
                 /\ UNCHANGED <<applied, doc, edits>>
         /\ UNCHANGED <<rid, shown, pending, opens, nextRef, released, drops>>

Next == Edit \/ Ask \/ Render \/ Open \/ Press \/ (drops < 2 /\ Dropped) \/ \E p \in pending : Answer(p)

Spec == Init /\ [][Next]_vars

\* The infoview shows only children asked for in the render it shows.
FillsMatch == shown.fills \subseteq {shown.rid}
\* A button edits only the text Lean computed its edit for.
EditsOnTheirText == \A a \in applied : a.for = a.at
\* No reference is forgotten: each is shown or released (or not yet asked for).
NoLeak == pending = {} => (1..(nextRef - 1)) = shown.refs \cup released

=============================================================================

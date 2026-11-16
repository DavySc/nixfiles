--------------------------- MODULE kitty_lean_diags ---------------------------
(***************************************************************************)
(* Lean's diagnostics, taken in pieces and handed on at most once an       *)
(* interval (kitty-lean--diagnostics-add, kitty-lean--diagnostics-deliver).*)
(*                                                                         *)
(* Lean checks a file and reports its diagnostics as it goes.  kittymax    *)
(* tells it it takes them in pieces (incrementalDiagnosticSupport): a      *)
(* report with isIncremental adds to the ones of the same version; any     *)
(* other report replaces them (a new version, a changed sticky message).  *)
(* Reports come in order (one stdio stream).                               *)
(*                                                                         *)
(* kittymax keeps the sum and hands it on (flymake, the marks, the         *)
(* webview): at once when nothing was handed on lately, else when the      *)
(* interval's timer fires.  What must hold: the sum is what Lean has, once *)
(* its reports are in; and what was handed on ends up being the sum: the  *)
(* last report is never left waiting.                                      *)
(*                                                                         *)
(* Bug names the mistake test/run.sh checks that TLC catches:              *)
(*   "replace"  every report replaces (isIncremental ignored)              *)
(*   "orphan"   a replacing report starts a new entry; the old entry's     *)
(*              timer, when it fires, hands on nothing (the first version  *)
(*              of kitty-lean--diagnostics-add)                            *)
(*   "leading"  only the first report of a burst is handed on              *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS MaxEdits, MaxReports, Bug

VARIABLES
  ver,       \* the document's version, as Lean last saw it
  lean,      \* how many diagnostics Lean has for that version
  reports,   \* how many reports Lean sent
  chan,      \* reports on their way: [v, inc, n] (n: added, or all when ~inc)
  acc,       \* kittymax's sum: [v, n, epoch]
  dirty,     \* the sum changed since it was last handed on
  timer,     \* the interval's timer: the epoch of the entry it belongs to, or 0
  given      \* what was handed on last: [v, n]

vars == <<ver, lean, reports, chan, acc, dirty, timer, given>>

Init == /\ ver = 0 /\ lean = 0 /\ reports = 0 /\ chan = <<>>
        /\ acc = [v |-> 0, n |-> 0, epoch |-> 1] /\ dirty = FALSE /\ timer = 0
        /\ given = [v |-> 0, n |-> 0]

\* the user edits: Lean starts the new version over, with a full report
Edit == /\ ver < MaxEdits
        /\ ver' = ver + 1 /\ lean' = 0
        /\ chan' = Append(chan, [v |-> ver + 1, inc |-> FALSE, n |-> 0])
        /\ UNCHANGED <<reports, acc, dirty, timer, given>>

\* Lean finds one more diagnostic and reports it alone
Add == /\ reports < MaxReports
       /\ lean' = lean + 1 /\ reports' = reports + 1
       /\ chan' = Append(chan, [v |-> ver, inc |-> TRUE, n |-> 1])
       /\ UNCHANGED <<ver, acc, dirty, timer, given>>

\* Lean reports all of them again (a sticky message changed)
Full == /\ reports < MaxReports
        /\ reports' = reports + 1
        /\ chan' = Append(chan, [v |-> ver, inc |-> FALSE, n |-> lean])
        /\ UNCHANGED <<ver, lean, acc, dirty, timer, given>>

Hand(a) == given' = [v |-> a.v, n |-> a.n]

\* kittymax reads the next report
Receive ==
  /\ chan # <<>>
  /\ LET r == Head(chan)
         keep == r.inc /\ r.v = acc.v /\ Bug # "replace"
         a == IF keep THEN [acc EXCEPT !.n = acc.n + r.n]
              ELSE [v |-> r.v, n |-> r.n,
                    epoch |-> IF Bug = "orphan" THEN acc.epoch + 1 ELSE acc.epoch]
         \* the "orphan" entry is new: its timer field starts as the old one's
     IN /\ chan' = Tail(chan)
        /\ acc' = a
        /\ IF timer = 0
           THEN /\ Hand(a) /\ dirty' = FALSE /\ timer' = a.epoch
           ELSE /\ dirty' = TRUE /\ UNCHANGED <<given, timer>>
  /\ UNCHANGED <<ver, lean, reports>>

\* the interval is over
Fire == /\ timer # 0
        /\ IF dirty /\ Bug # "leading" /\ (Bug # "orphan" \/ timer = acc.epoch)
           THEN /\ Hand(acc) /\ dirty' = FALSE /\ timer' = acc.epoch
           ELSE /\ timer' = IF Bug = "orphan" /\ timer # acc.epoch THEN timer ELSE 0
                /\ UNCHANGED <<given, dirty>>
        /\ UNCHANGED <<ver, lean, reports, chan, acc>>
\* (under "orphan" the old timer clears only its own entry's field: the new
\*  entry's field stays set, so no report starts a delivery again)

Next == Edit \/ Add \/ Full \/ Receive \/ Fire

Spec == Init /\ [][Next]_vars /\ WF_vars(Receive) /\ WF_vars(Fire)

\* once Lean's reports are in, the sum is what Lean has
SumIsLeans == chan = <<>> => (acc.v = ver /\ acc.n = lean)

\* what was handed on ends up being the whole sum
HandedOnInTheEnd == <>[](given.v = acc.v /\ given.n = acc.n)
================================================================================

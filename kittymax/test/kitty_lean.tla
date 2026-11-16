---------------------------- MODULE kitty_lean ----------------------------
(***************************************************************************)
(* The infoview of kitty-lean.el: what it shows always belongs to the     *)
(* latest request, and once you stop moving and typing and Lean has       *)
(* checked the file, it shows the goal at the cursor for the current text. *)
(*                                                                         *)
(* The editor asks Lean (plainGoal / plainTermGoal, one message here) when *)
(* eldoc's idle timer fires after a move or an edit, and again, forced,    *)
(* when Lean reports it finished checking the file.  A request for the    *)
(* same position and text as the last one is skipped unless forced.  Each  *)
(* request takes a new generation; answers travel back in any order;      *)
(* only an answer of the latest generation is shown, and an error or a    *)
(* timeout (Lean holds a goal request until it has checked up to there,   *)
(* and drops it with ContentModified when the text changes) leaves the    *)
(* infoview as it was.                                                     *)
(*                                                                         *)
(* One file: news from other files' checks never refreshes the infoview  *)
(* (kitty-lean--followed-p), so they add no steps here.                    *)
(*                                                                         *)
(*   tlc -config kitty_lean.cfg kitty_lean.tla    (test/run.sh runs it)   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Positions,  \* where the cursor can be
          MaxMoves,   \* bound the moves and edits, so behaviours quiesce
          MaxEdits

None == [g |-> 0, pos |-> "none", ver |-> 0, goal |-> FALSE]

VARIABLES
  cursor,      \* the cursor's position
  ver,         \* the text's version (buffer-chars-modified-tick)
  checked,     \* Lean has checked the current version
  idle,        \* eldoc's idle timer is armed (a command ran since it fired)
  gen,         \* kitty-lean--gen
  lastKey,     \* kitty-lean--last-key: <<pos, ver>> of the latest request
  inflight,    \* requests Lean has not answered: [g, pos]
  answers,     \* answers on their way back: [g, pos, ver, goal, ok]
  shown,       \* what the infoview shows: [g, pos, ver, goal]
  moves, edits

vars == <<cursor, ver, checked, idle, gen, lastKey, inflight, answers, shown, moves, edits>>

Init ==
  /\ cursor \in Positions
  /\ ver = 0
  /\ checked = FALSE
  /\ idle = TRUE
  /\ gen = 0
  /\ lastKey = <<"none", 0>>
  /\ inflight = {}
  /\ answers = {}
  /\ shown = None
  /\ moves = 0
  /\ edits = 0

\* kitty-lean-infoview-refresh
Refresh(force) ==
  IF force \/ lastKey # <<cursor, ver>>
  THEN /\ gen' = gen + 1
       /\ lastKey' = <<cursor, ver>>
       /\ inflight' = inflight \cup {[g |-> gen + 1, pos |-> cursor]}
  ELSE UNCHANGED <<gen, lastKey, inflight>>

Move ==
  /\ moves < MaxMoves
  /\ \E p \in Positions \ {cursor} : cursor' = p
  /\ moves' = moves + 1
  /\ idle' = TRUE
  /\ UNCHANGED <<ver, checked, gen, lastKey, inflight, answers, shown, edits>>

\* An edit: Lean starts checking again, and drops what it was asked before
\* with ContentModified (an answer that is not ok).
Edit ==
  /\ edits < MaxEdits
  /\ ver' = ver + 1
  /\ checked' = FALSE
  /\ idle' = TRUE
  /\ edits' = edits + 1
  /\ answers' = answers \cup {[g |-> r.g, pos |-> r.pos, ver |-> ver, goal |-> FALSE, ok |-> FALSE] : r \in inflight}
  /\ inflight' = {}
  /\ UNCHANGED <<cursor, gen, lastKey, shown, moves>>

\* eldoc's idle timer: kitty-lean--eldoc-refresh
EldocFires ==
  /\ idle
  /\ idle' = FALSE
  /\ Refresh(FALSE)
  /\ UNCHANGED <<cursor, ver, checked, answers, shown, moves, edits>>

\* $/lean/fileProgress with nothing left: kitty-lean--on-progress
CheckingDone ==
  /\ ~checked
  /\ checked' = TRUE
  /\ Refresh(TRUE)
  /\ UNCHANGED <<cursor, ver, idle, answers, shown, moves, edits>>

\* Lean answers a goal request once it has checked the file
Answer ==
  /\ checked
  /\ \E r \in inflight :
       /\ inflight' = inflight \ {r}
       /\ answers' = answers \cup {[g |-> r.g, pos |-> r.pos, ver |-> ver, goal |-> TRUE, ok |-> TRUE]}
  /\ UNCHANGED <<cursor, ver, checked, idle, gen, lastKey, shown, moves, edits>>

\* jsonrpc's timeout, while Lean is still checking
Timeout ==
  /\ ~checked
  /\ \E r \in inflight :
       /\ inflight' = inflight \ {r}
       /\ answers' = answers \cup {[g |-> r.g, pos |-> r.pos, ver |-> ver, goal |-> FALSE, ok |-> FALSE]}
  /\ UNCHANGED <<cursor, ver, checked, idle, gen, lastKey, shown, moves, edits>>

\* the answer reaches Emacs: rendered only if it is the latest generation and ok
Deliver ==
  \E a \in answers :
    /\ answers' = answers \ {a}
    /\ shown' = IF a.g = gen /\ a.ok
                THEN [g |-> a.g, pos |-> a.pos, ver |-> a.ver, goal |-> a.goal]
                ELSE shown
    /\ UNCHANGED <<cursor, ver, checked, idle, gen, lastKey, inflight, moves, edits>>

Next == Move \/ Edit \/ EldocFires \/ CheckingDone \/ Answer \/ Timeout \/ Deliver

Spec == Init /\ [][Next]_vars
        /\ WF_vars(EldocFires) /\ WF_vars(CheckingDone)
        /\ WF_vars(Answer) /\ WF_vars(Deliver)

TypeOK ==
  /\ cursor \in Positions
  /\ gen \in Nat
  /\ shown.g <= gen

\* Never an older answer over a newer one.
NeverStale == [][shown' # shown => shown'.g = gen /\ shown'.g > shown.g]_vars

\* Once the moves and edits are over: the goal at the cursor, for this text.
Settles == <>[](shown.pos = cursor /\ shown.ver = ver /\ shown.goal)

=============================================================================

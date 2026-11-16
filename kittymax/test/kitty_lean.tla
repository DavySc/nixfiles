---------------------------- MODULE kitty_lean ----------------------------
(***************************************************************************)
(* The infoview of kitty-lean.el: what it shows always belongs to the     *)
(* latest request and to the text it asked about, and once you stop       *)
(* moving and typing and Lean has checked the file, it shows the goal at  *)
(* the cursor for the current text.                                       *)
(*                                                                         *)
(* The editor asks Lean when eldoc's idle timer fires after a move or an  *)
(* edit, and again, forced, when Lean reports it finished checking.  A    *)
(* request for the same position and text as the last one is skipped      *)
(* unless forced.  Each request takes a new generation; answers travel    *)
(* back in any order; only an answer of the latest generation is shown,   *)
(* and an error or a timeout (Lean holds a goal request until it has      *)
(* checked up to there, and drops it with ContentModified when the text   *)
(* changes) leaves the infoview as it was.                                *)
(*                                                                         *)
(* Lean learns of an edit only when eglot sends didChange: on its own     *)
(* idle timer (0.4 s, after eldoc's 0.25 s), or when kitty-lean flushes   *)
(* it before asking (kitty-lean--flush).  Fix = FALSE is the version      *)
(* without the flush, which showed goals of the text before the edit.     *)
(* Diagnostics' refreshes are gathered and only for the followed file:    *)
(* they are refreshes like the ones here, so they add no new steps.       *)
(*                                                                         *)
(*   tlc -config kitty_lean.cfg kitty_lean.tla    (test/run.sh runs it,   *)
(*   and three broken versions of it, which TLC must reject)              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Positions,  \* where the cursor can be
          MaxMoves,   \* bound the moves and edits, so behaviours quiesce
          MaxEdits,
          Fix         \* flush the edit before asking

None == [g |-> 0, pos |-> "none", ver |-> 0, req |-> 0, goal |-> FALSE]

VARIABLES
  cursor,      \* the cursor's position
  ver,         \* the text's version in Emacs (buffer-chars-modified-tick)
  sent,        \* the version Lean has (didChange sent)
  checked,     \* Lean has checked the version it has
  idle,        \* eldoc's idle timer is armed (a command ran since it fired)
  gen,         \* kitty-lean--gen
  lastKey,     \* kitty-lean--last-key: <<pos, ver>> of the latest request
  inflight,    \* requests Lean has not answered: [g, pos, req (version asked about)]
  answers,     \* answers on their way back: [g, pos, ver (Lean's), req, goal, ok]
  shown,       \* what the infoview shows: [g, pos, ver, req, goal]
  moves, edits

vars == <<cursor, ver, sent, checked, idle, gen, lastKey, inflight, answers, shown, moves, edits>>

Init ==
  /\ cursor \in Positions
  /\ ver = 0 /\ sent = 0
  /\ checked = FALSE
  /\ idle = TRUE
  /\ gen = 0
  /\ lastKey = <<"none", 0>>
  /\ inflight = {}
  /\ answers = {}
  /\ shown = None
  /\ moves = 0 /\ edits = 0

\* What Lean drops (ContentModified) when it gets new text
Dropped == {[g |-> r.g, pos |-> r.pos, ver |-> sent, req |-> r.req, goal |-> FALSE, ok |-> FALSE] : r \in inflight}

Flush == Fix /\ sent # ver

\* kitty-lean-infoview-refresh (with Fix, the pending edit goes first)
Refresh(force) ==
  IF force \/ lastKey # <<cursor, ver>>
  THEN /\ gen' = gen + 1
       /\ lastKey' = <<cursor, ver>>
       /\ inflight' = (IF Flush THEN {} ELSE inflight) \cup {[g |-> gen + 1, pos |-> cursor, req |-> ver]}
       /\ answers' = IF Flush THEN answers \cup Dropped ELSE answers
  ELSE /\ UNCHANGED <<gen, lastKey>>
       /\ inflight' = IF Flush THEN {} ELSE inflight
       /\ answers' = IF Flush THEN answers \cup Dropped ELSE answers

Move ==
  /\ moves < MaxMoves
  /\ \E p \in Positions \ {cursor} : cursor' = p
  /\ moves' = moves + 1
  /\ idle' = TRUE
  /\ UNCHANGED <<ver, sent, checked, gen, lastKey, inflight, answers, shown, edits>>

\* Typing: only Emacs knows, until didChange
Edit ==
  /\ edits < MaxEdits
  /\ ver' = ver + 1
  /\ idle' = TRUE
  /\ edits' = edits + 1
  /\ UNCHANGED <<cursor, sent, checked, gen, lastKey, inflight, answers, shown, moves>>

\* eglot's idle timer: didChange.  Lean starts again and drops what it was asked.
SendChange ==
  /\ sent # ver
  /\ sent' = ver /\ checked' = FALSE
  /\ answers' = answers \cup Dropped /\ inflight' = {}
  /\ UNCHANGED <<cursor, ver, idle, gen, lastKey, shown, moves, edits>>

\* eldoc's idle timer: kitty-lean--eldoc-refresh
EldocFires ==
  /\ idle
  /\ idle' = FALSE
  /\ Refresh(FALSE)
  /\ sent' = (IF Flush THEN ver ELSE sent)
  /\ checked' = (IF Flush THEN FALSE ELSE checked)
  /\ UNCHANGED <<cursor, ver, shown, moves, edits>>

\* $/lean/fileProgress with nothing left: kitty-lean--on-progress
CheckingDone ==
  /\ ~checked
  /\ Refresh(TRUE)
  /\ sent' = (IF Flush THEN ver ELSE sent)
  /\ checked' = (IF Flush THEN FALSE ELSE TRUE)
  /\ UNCHANGED <<cursor, ver, idle, shown, moves, edits>>

\* Lean answers a goal request once it has checked, for the text IT has
Answer ==
  /\ checked
  /\ \E r \in inflight :
       /\ inflight' = inflight \ {r}
       /\ answers' = answers \cup {[g |-> r.g, pos |-> r.pos, ver |-> sent, req |-> r.req, goal |-> TRUE, ok |-> TRUE]}
  /\ UNCHANGED <<cursor, ver, sent, checked, idle, gen, lastKey, shown, moves, edits>>

\* jsonrpc's timeout, while Lean is still checking
Timeout ==
  /\ ~checked
  /\ \E r \in inflight :
       /\ inflight' = inflight \ {r}
       /\ answers' = answers \cup {[g |-> r.g, pos |-> r.pos, ver |-> sent, req |-> r.req, goal |-> FALSE, ok |-> FALSE]}
  /\ UNCHANGED <<cursor, ver, sent, checked, idle, gen, lastKey, shown, moves, edits>>

\* the answer reaches Emacs: rendered only if it is the latest generation and ok
Deliver ==
  \E a \in answers :
    /\ answers' = answers \ {a}
    /\ shown' = IF a.g = gen /\ a.ok
                THEN [g |-> a.g, pos |-> a.pos, ver |-> a.ver, req |-> a.req, goal |-> a.goal]
                ELSE shown
    /\ UNCHANGED <<cursor, ver, sent, checked, idle, gen, lastKey, inflight, moves, edits>>

Next == Move \/ Edit \/ SendChange \/ EldocFires \/ CheckingDone \/ Answer \/ Timeout \/ Deliver

Spec == Init /\ [][Next]_vars
        /\ WF_vars(EldocFires) /\ WF_vars(CheckingDone) /\ WF_vars(SendChange)
        /\ WF_vars(Answer) /\ WF_vars(Deliver)

TypeOK ==
  /\ cursor \in Positions
  /\ gen \in Nat
  /\ shown.g <= gen

\* Never an older answer over a newer one.
NeverStale == [][shown' # shown => shown'.g = gen /\ shown'.g > shown.g]_vars

\* What is shown was computed from the text it was asked about.
Honest == shown.ver = shown.req

\* Once the moves and edits are over: the goal at the cursor, for this text.
Settles == <>[](shown.pos = cursor /\ shown.ver = ver /\ shown.goal)

=============================================================================

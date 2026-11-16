---------------------------- MODULE kitty_lean_folding ----------------------------
(* The editor's folding ranges (kitty-lean.el, "Folding").                    *)
(*                                                                             *)
(* Emacs edits the text; eglot sends the edits to Lean when idle (or kittymax  *)
(* flushes them before a question).  For each text Lean reports its progress  *)
(* on one ordered stream: maybe "busy" (a quick check may skip it), then      *)
(* "done".  On "done", kittymax asks for the folding ranges when the ones it  *)
(* has are for another text; the answer comes on the same stream, later, and  *)
(* is taken only if the buffer still has the text it was asked for.          *)
(*                                                                             *)
(* Safe: no answer is ever drawn on a text it was not computed for.           *)
(* Live: once the edits stop, the ranges are for the final text.              *)
(*                                                                             *)
(* Design = "fixed"      what kitty-lean.el does                               *)
(*          "nocheck"    answers taken whatever the text now     (unsafe)     *)
(*          "transition" ask only when progress goes busy -> done (not live:  *)
(*                       Lean 4.35 sends no "busy" for a small edit)          *)
EXTENDS Naturals, Sequences

CONSTANTS MaxEdits, Design

VARIABLES text,      \* the buffer's text (a version number)
          leanText,  \* the text Lean has
          stream,    \* Lean -> Emacs, in order: [k |-> "busy"/"done"/"answer", v |-> text]
          wasBusy,   \* kitty-lean--processing was non-nil
          foldTick,  \* the text the ranges are for (0: none yet)
          bad        \* an answer was drawn on another text

vars == <<text, leanText, stream, wasBusy, foldTick, bad>>

Init == /\ text = 1 /\ leanText = 1 /\ wasBusy = FALSE /\ foldTick = 0 /\ bad = FALSE
        /\ stream \in {<<[k |-> "busy", v |-> 1], [k |-> "done", v |-> 1]>>, <<[k |-> "done", v |-> 1]>>}

\* Lean gets a new text: it checks it, maybe saying "busy" first
LeanGets(t) == \E skip \in BOOLEAN :
    stream' = stream \o (IF skip THEN <<[k |-> "done", v |-> t]>>
                         ELSE <<[k |-> "busy", v |-> t], [k |-> "done", v |-> t]>>)

Edit == /\ text < MaxEdits
        /\ text' = text + 1
        /\ UNCHANGED <<leanText, stream, wasBusy, foldTick, bad>>

\* eglot's idle timer sends the edits
SendChange == /\ leanText /= text
              /\ leanText' = text
              /\ LeanGets(text)
              /\ UNCHANGED <<text, wasBusy, foldTick, bad>>

Ask(cond) ==
    IF cond
    THEN \* kitty-lean--flush, then the question, answered for that text
         IF leanText /= text
         THEN /\ leanText' = text
              /\ \E skip \in BOOLEAN :
                   stream' = Tail(stream) \o
                     (IF skip THEN <<[k |-> "done", v |-> text]>>
                      ELSE <<[k |-> "busy", v |-> text], [k |-> "done", v |-> text]>>)
                     \o <<[k |-> "answer", v |-> text]>>
         ELSE /\ stream' = Tail(stream) \o <<[k |-> "answer", v |-> text]>>
              /\ UNCHANGED leanText
    ELSE /\ stream' = Tail(stream)
         /\ UNCHANGED leanText

Handle == /\ stream /= <<>>
          /\ LET m == Head(stream) IN
             CASE m.k = "busy" ->
                    /\ wasBusy' = TRUE
                    /\ stream' = Tail(stream)
                    /\ UNCHANGED <<text, leanText, foldTick, bad>>
               [] m.k = "done" ->
                    /\ wasBusy' = FALSE
                    /\ Ask(IF Design = "transition" THEN wasBusy ELSE foldTick /= text)
                    /\ UNCHANGED <<text, foldTick, bad>>
               [] m.k = "answer" ->
                    /\ stream' = Tail(stream)
                    /\ IF Design = "nocheck" \/ m.v = text
                       THEN /\ foldTick' = m.v
                            /\ bad' = (bad \/ m.v /= text)
                       ELSE UNCHANGED <<foldTick, bad>>
                    /\ UNCHANGED <<text, leanText, wasBusy>>

Next == Edit \/ SendChange \/ Handle

Spec == Init /\ [][Next]_vars /\ WF_vars(SendChange) /\ WF_vars(Handle)

Safe == ~bad
TypeOK == text \in 1..MaxEdits /\ foldTick \in 0..MaxEdits /\ Len(stream) <= 4 * MaxEdits
Live == <>[](foldTick = text)
=============================================================================

-------------------------- MODULE kitty_lean_start --------------------------
(***************************************************************************)
(* One Lean server per project (kitty-lean--ensure-server and friends).   *)
(* eglot knows a server only once it has answered `initialize', so the    *)
(* first Lean file of a project notes that it starts one (the starter);   *)
(* files opened meanwhile wait, and eglot takes them all when it is up.   *)
(* The starter's eglot-ensure runs after its next command.  When the      *)
(* start comes to nothing (the starter is closed before it ran, or the    *)
(* server exits before answering) a waiting file starts it instead        *)
(* (kitty-lean--hand-over); with nobody waiting the note goes.            *)
(*                                                                         *)
(* Fix = FALSE is the first version: the note stayed until 60 s passed    *)
(* (not modelled: a minute of a file without a server is the bug), so     *)
(* waiting files never got a server.  test/run.sh checks TLC catches it.  *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Files, MaxFails, MaxKills, Fix

VARIABLES
  buf,      \* per file: "closed", "open" (no server), "managed"
  ensure,   \* files whose eglot-ensure waits for their next command
  note,     \* the starter, or "none"
  server,   \* "down", "starting" (launched, no answer yet), "up"
  fails, kills

vars == <<buf, ensure, note, server, fails, kills>>

Init == /\ buf = [f \in Files |-> "closed"] /\ ensure = {} /\ note = "none"
        /\ server = "down" /\ fails = 0 /\ kills = 0

\* find-file: nael-mode-hook, kitty-lean--ensure-server
Open(f) == /\ buf[f] = "closed"
           /\ IF server = "up"
              THEN buf' = [buf EXCEPT ![f] = "managed"] /\ UNCHANGED <<ensure, note>>
              ELSE /\ buf' = [buf EXCEPT ![f] = "open"]
                   /\ IF note = "none"
                      THEN note' = f /\ ensure' = ensure \cup {f}
                      ELSE UNCHANGED <<note, ensure>>     \* waits
           /\ UNCHANGED <<server, fails, kills>>

\* eglot-ensure, after a command in that buffer
PostCommand(f) == /\ f \in ensure /\ ensure' = ensure \ {f}
                  /\ server' = IF server = "down" /\ buf[f] = "open" THEN "starting" ELSE server
                  /\ UNCHANGED <<buf, note, fails, kills>>

\* `initialize' answered: eglot takes every Lean buffer of the project
Connected == /\ server = "starting" /\ server' = "up" /\ note' = "none"
             /\ buf' = [f \in Files |-> IF buf[f] = "open" THEN "managed" ELSE buf[f]]
             /\ UNCHANGED <<ensure, fails, kills>>

\* the start came to nothing: a waiting file (not the starter) starts it,
\* at once (eglot--connect, not eglot-ensure), or nobody does
HandOver(from, b) ==      \* b: the buffers after this step
  LET waiting == {g \in Files : b[g] = "open" /\ g # from} IN
  IF waiting = {}
  THEN note' = "none" /\ server' = "down"
  ELSE \E g \in waiting : note' = g /\ server' = "starting"

\* lake exits before answering (no toolchain yet, a broken lakefile)
StartFails == /\ server = "starting" /\ fails < MaxFails /\ fails' = fails + 1
              /\ IF Fix /\ note # "none"
                 THEN HandOver(note, buf)
                 ELSE server' = "down" /\ UNCHANGED note
              /\ UNCHANGED <<buf, ensure, kills>>

Kill(f) == /\ buf[f] # "closed" /\ kills < MaxKills /\ kills' = kills + 1
           /\ buf' = [buf EXCEPT ![f] = "closed"]
           /\ ensure' = ensure \ {f}
           /\ LET left == {g \in Files \ {f} : buf[g] # "closed"} IN
              IF Fix /\ note = f /\ server = "down"          \* closed before it started
              THEN HandOver(f, [buf EXCEPT ![f] = "closed"])
              ELSE /\ server' = IF server = "up" /\ left = {} THEN "down" ELSE server
                   /\ UNCHANGED note
           /\ UNCHANGED fails

Next == Connected \/ StartFails \/ \E f \in Files : Open(f) \/ PostCommand(f) \/ Kill(f)

Spec == Init /\ [][Next]_vars /\ WF_vars(Connected) /\ \A f \in Files : WF_vars(PostCommand(f))

\* A file that waits for another's start gets the server, or starts it
\* itself (a failure of its own start is not retried: it would fail again).
WaitersServed == \A f \in Files :
  [](buf[f] = "open" /\ note \notin {"none", f} => <>(buf[f] # "open" \/ note = f))
\* A note always stands for a start that is on its way.
NoStaleNote == [](note # "none" => <>(note = "none" \/ server # "down" \/ note \in ensure))

=============================================================================

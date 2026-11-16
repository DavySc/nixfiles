-------------------------- MODULE kitty_lean_start --------------------------
(***************************************************************************)
(* One Lean server per project (kitty-lean--launch and friends).           *)
(*                                                                         *)
(* Every Lean buffer has its own eglot-ensure, which connects after the   *)
(* next command IN THAT BUFFER, so only in the selected one (sel): a file *)
(* can be opened without being shown (a second file on the command line, *)
(* find-file-noselect).  eglot knows a server only once it has answered   *)
(* `initialize', so a connect while one is starting would launch a second *)
(* server: kitty-lean--launch skips it and notes the buffer as waiting;   *)
(* eglot takes every buffer of the project when the server is up.  If     *)
(* the start fails, the waiting buffers get their eglot-ensure back.  A    *)
(* start takes Need ticks; eglot kills one that has not answered after    *)
(* Limit ticks (eglot-connect-timeout), Limit = 0 for none (kittymax's    *)
(* kitty-lean-connect-timeout).                                           *)
(*                                                                         *)
(* Design "fixed" is the above.  "pr" is the first version: the first     *)
(* file opened was noted as the starter when it was OPENED, and the others *)
(* did not ensure at all but waited for it, which strands them when the   *)
(* starter is not the selected buffer (review of PR #6, with the          *)
(* reviewer's model).  "nonote" launches from every buffer: two servers.  *)
(* test/run.sh checks that TLC rejects both, and eglot's own 30 s timeout *)
(* (Need > Limit).                                                        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Files, MaxKills, MaxFails, Design, Need, Limit

VARIABLES
  buf,      \* per file: "closed", "open" (no server), "managed", "broken" (its start failed)
  ensure,   \* files whose eglot-ensure waits for a command in them
  note,     \* "none", or the file whose launch is on its way
  waiting,  \* files that skipped their launch for it
  servers,  \* server processes of the project that have not answered yet, or are up
  up,       \* a server is up
  sel,      \* the buffer the user is in ("other": not a Lean file)
  age,      \* ticks since the launch
  kills, fails

vars == <<buf, ensure, note, waiting, servers, up, sel, age, kills, fails>>

Init == /\ buf = [f \in Files |-> "closed"] /\ ensure = {} /\ note = "none"
        /\ waiting = {} /\ servers = 0 /\ up = FALSE /\ sel = "other"
        /\ age = 0 /\ kills = 0 /\ fails = 0

\* find-file (shown: it is selected) or find-file-noselect; nael-mode-hook
Open(f, shown) ==
  /\ buf[f] = "closed"
  /\ sel' = IF shown THEN f ELSE sel
  /\ IF up
     THEN buf' = [buf EXCEPT ![f] = "managed"] /\ UNCHANGED <<ensure, note, waiting>>
     ELSE /\ buf' = [buf EXCEPT ![f] = "open"]
          /\ IF Design = "pr"
             THEN IF note = "none"
                  THEN note' = f /\ ensure' = ensure \cup {f} /\ UNCHANGED waiting
                  ELSE waiting' = waiting \cup {f} /\ UNCHANGED <<note, ensure>>
             ELSE ensure' = ensure \cup {f} /\ UNCHANGED <<note, waiting>>
  /\ UNCHANGED <<servers, up, age, kills, fails>>

Select(f) == /\ buf[f] # "closed" /\ sel # f /\ sel' = f
             /\ UNCHANGED <<buf, ensure, note, waiting, servers, up, age, kills, fails>>

\* a command ends in the selected buffer: eglot-ensure's eglot--connect
PostCommand(f) ==
  /\ sel = f /\ f \in ensure /\ ensure' = ensure \ {f}
  /\ IF buf[f] # "open" \/ up
     THEN UNCHANGED <<note, waiting, servers, age>>
     ELSE IF Design = "fixed" /\ note # "none"
     THEN waiting' = waiting \cup {f} /\ UNCHANGED <<note, servers, age>>
     ELSE IF Design = "pr" /\ servers > 0
     THEN UNCHANGED <<note, waiting, servers, age>>
     ELSE /\ servers' = servers + 1 /\ age' = 0
          /\ note' = IF Design = "pr" THEN note ELSE f
          /\ UNCHANGED waiting
  /\ UNCHANGED <<buf, up, sel, kills, fails>>

Tick == /\ servers > 0 /\ ~up /\ age < Need /\ (Limit = 0 \/ age < Limit) /\ age' = age + 1
        /\ UNCHANGED <<buf, ensure, note, waiting, servers, up, sel, kills, fails>>

\* `initialize' answered: eglot takes every Lean buffer of the project
Connected == /\ servers > 0 /\ ~up /\ age >= Need
             /\ up' = TRUE /\ note' = "none" /\ waiting' = {}
             /\ buf' = [f \in Files |-> IF buf[f] = "open" THEN "managed" ELSE buf[f]]
             /\ UNCHANGED <<ensure, servers, sel, age, kills, fails>>

\* the start ends without a server: lake exits (StartFails, the file is
\* broken: no server can come), or eglot's timeout kills it (TimedOut)
Ended(status) ==
  /\ servers' = 0 /\ age' = 0
  /\ buf' = [f \in Files |-> IF f = note /\ buf[f] = "open" THEN status ELSE buf[f]]
  /\ IF Design = "fixed"
     THEN /\ note' = "none" /\ waiting' = {}
          /\ ensure' = ensure \cup {g \in waiting : buf[g] = "open"}
     ELSE \* the first version handed the start to one waiting file, once
          /\ LET w == {g \in waiting : buf[g] = "open" /\ g # note} IN
             IF w = {} THEN note' = "none" /\ waiting' = {} /\ UNCHANGED ensure
             ELSE \E g \in w : note' = g /\ waiting' = waiting \ {g} /\ ensure' = ensure \cup {g}

StartFails == /\ servers > 0 /\ ~up /\ fails < MaxFails /\ fails' = fails + 1
              /\ Ended("broken") /\ UNCHANGED <<up, sel, kills>>

TimedOut == /\ Limit > 0 /\ servers > 0 /\ ~up /\ age >= Limit /\ age < Need
            /\ Ended("failed") /\ UNCHANGED <<up, sel, kills, fails>>

Kill(f) ==
  /\ buf[f] # "closed" /\ kills < MaxKills /\ kills' = kills + 1
  /\ buf' = [buf EXCEPT ![f] = "closed"]
  /\ ensure' = ensure \ {f} /\ waiting' = waiting \ {f}
  /\ sel' = IF sel = f THEN "other" ELSE sel
  /\ LET left == {g \in Files \ {f} : buf[g] # "closed"} IN
     IF up /\ left = {}                      \* eglot-autoshutdown
     THEN up' = FALSE /\ servers' = 0 /\ note' = "none"
     ELSE UNCHANGED <<up, servers, note>>    \* a start goes on without its file
  /\ UNCHANGED <<age, fails>>

\* Tick is tied to Limit: time passes, so a slow start reaches its timeout
Next == Connected \/ StartFails \/ TimedOut \/ Tick
        \/ \E f \in Files : Open(f, TRUE) \/ Open(f, FALSE) \/ Select(f) \/ PostCommand(f) \/ Kill(f)

\* The user keeps working in the buffer they are in; nothing says they
\* ever select another one.  Time passes.
Spec == Init /\ [][Next]_vars
        /\ WF_vars(Connected) /\ WF_vars(TimedOut) /\ WF_vars(Tick)
        /\ \A f \in Files : WF_vars(PostCommand(f))

TypeOK == /\ note \in Files \cup {"none"} /\ waiting \subseteq Files /\ servers \in Nat

\* One server per project.
OneServer == servers <= 1
\* A note always stands for a launch on its way.
NoStaleNote == Design = "fixed" => (note # "none" => servers = 1 /\ ~up)

\* Nobody sits for ever in a Lean file that has no server, unless lake
\* itself cannot start there ("broken": eglot said why).
NoFileLeftBehind == \A f \in Files : ~<>[](sel = f /\ buf[f] \in {"open", "failed"})

=============================================================================

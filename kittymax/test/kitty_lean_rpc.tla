--------------------------- MODULE kitty_lean_rpc ---------------------------
(***************************************************************************)
(* The infoview's RPC session (kitty-lean--rpc-call, --session-lost).     *)
(* A refresh connects when the buffer has no session, then sends three    *)
(* calls (goals, expected type, messages) on it.  Lean forgets a session  *)
(* nobody kept alive; a call on it fails with RpcNeedsReconnect.  The     *)
(* first such failure forgets the session, if it is still the buffer's,   *)
(* and asks for a refresh; the others only fail.  Only a refresh whose    *)
(* three answers all came back is rendered (the generation check).        *)
(*                                                                         *)
(* Fix = FALSE is the mistake the review found: every failing call        *)
(* forgot the session and connected again, so one expiry made three       *)
(* sessions and the infoview showed references from several of them,     *)
(* which K and gd could not use.  test/run.sh checks that TLC catches it. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Calls, MaxRefreshes, Fix

VARIABLES
  client,     \* kitty-lean--rpc-session (0: none)
  live,       \* the sessions Lean still knows
  nextId, connects,
  expired,    \* Lean has dropped a session once
  gen,        \* kitty-lean--gen
  call,       \* per call: [g, s (session), st: "sent" "ok" "err" "failed"]
  want,       \* a refresh was asked for after a lost session
  refreshes,
  shown       \* what the infoview shows: [g, sessions of its references]

vars == <<client, live, nextId, connects, expired, gen, call, want, refreshes, shown>>

Init == /\ client = 1 /\ live = {1} /\ nextId = 2 /\ connects = 0 /\ expired = FALSE
        /\ gen = 0 /\ call = [c \in Calls |-> [g |-> 0, s |-> 1, st |-> "ok"]]
        /\ want = FALSE /\ refreshes = 0 /\ shown = [g |-> 0, sessions |-> {1}]

\* Lean drops the buffer's session (a laptop asleep, keepAlive missed)
Expire == /\ ~expired /\ client # 0
          /\ live' = live \ {client} /\ expired' = TRUE
          /\ UNCHANGED <<client, nextId, connects, gen, call, want, refreshes, shown>>

\* kitty-lean-infoview-refresh, from the cursor or from a lost session
Refresh == /\ want \/ refreshes < MaxRefreshes
           /\ refreshes' = IF want THEN refreshes ELSE refreshes + 1
           /\ want' = FALSE
           /\ gen' = gen + 1
           /\ IF client = 0
              THEN /\ client' = nextId /\ live' = live \cup {nextId}
                   /\ nextId' = nextId + 1 /\ connects' = connects + 1
                   /\ call' = [c \in Calls |-> [g |-> gen + 1, s |-> nextId, st |-> "sent"]]
              ELSE /\ UNCHANGED <<client, live, nextId, connects>>
                   /\ call' = [c \in Calls |-> [g |-> gen + 1, s |-> client, st |-> "sent"]]
           /\ UNCHANGED <<expired, shown>>

Reply(c) == /\ call[c].st = "sent"
            /\ call' = [call EXCEPT ![c].st = IF call[c].s \in live THEN "ok" ELSE "err"]
            /\ UNCHANGED <<client, live, nextId, connects, expired, gen, want, refreshes, shown>>

\* the :error-fn: kitty-lean--session-lost
OnError(c) == /\ call[c].st = "err"
              /\ IF Fix
                 THEN /\ call' = [call EXCEPT ![c].st = "failed"]
                      /\ IF call[c].s = client
                         THEN client' = 0 /\ want' = TRUE
                         ELSE UNCHANGED <<client, want>>
                      /\ UNCHANGED <<live, nextId, connects>>
                 ELSE \* the old code: forget the session, connect, retry this call
                      /\ client' = nextId /\ live' = live \cup {nextId}
                      /\ nextId' = nextId + 1 /\ connects' = connects + 1
                      /\ call' = [call EXCEPT ![c] = [g |-> call[c].g, s |-> nextId, st |-> "sent"]]
                      /\ UNCHANGED want
              /\ UNCHANGED <<expired, gen, refreshes, shown>>

\* K or gd in the infoview (kitty-lean--rpc-call-sync) on references of a
\* session Lean dropped: the same kitty-lean--session-lost, and "try again"
UseRefs == /\ ~(shown.sessions \subseteq live)
           /\ IF client \in shown.sessions
              THEN client' = 0 /\ want' = TRUE
              ELSE UNCHANGED <<client, want>>
           /\ UNCHANGED <<live, nextId, connects, expired, gen, call, refreshes, shown>>

\* kitty-lean--render: the latest generation, all three answers ok
Render == /\ \A c \in Calls : call[c].g = gen /\ call[c].st = "ok"
          /\ shown.g # gen
          /\ shown' = [g |-> gen, sessions |-> {call[c].s : c \in Calls}]
          /\ UNCHANGED <<client, live, nextId, connects, expired, gen, call, want, refreshes>>

Next == Expire \/ Refresh \/ Render \/ UseRefs \/ \E c \in Calls : Reply(c) \/ OnError(c)

Spec == Init /\ [][Next]_vars
        /\ WF_vars(Refresh) /\ WF_vars(Render) /\ WF_vars(UseRefs)
        /\ \A c \in Calls : WF_vars(Reply(c)) /\ WF_vars(OnError(c))

\* K, gd and release send the references with the buffer's one session.
OneSessionShown == Cardinality(shown.sessions) = 1
\* One lost session costs one new one.
OneReconnect == connects <= 1
\* After the session is lost, the infoview comes back with usable references
\* (once it is used: idle, it may show dead ones, and nothing needs them).
Recovers == <>[](shown.sessions \subseteq live)

=============================================================================

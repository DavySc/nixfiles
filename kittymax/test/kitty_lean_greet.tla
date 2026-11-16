------------------------------ MODULE kitty_lean_greet ------------------------------
(***************************************************************************)
(* When a page of the webview is told "the server restarted"              *)
(* (kitty-lean-webview--greet, --on-server, --hello).                      *)
(*                                                                         *)
(* VS Code tells its infoview serverRestarted when the Lean server came    *)
(* up or came up again, and at no other time: the infoview then drops its  *)
(* RPC session and asks for everything again.                              *)
(*                                                                         *)
(* kittymax hears of servers through eglot-managed-mode-hook.  That hook   *)
(* runs for every buffer that enters or leaves eglot, of any language,     *)
(* not once per server.                                                    *)
(*                                                                         *)
(* Design = "pr":    the hook forgets that every page was greeted and      *)
(*                   greets again (the first version, caught in review).   *)
(* Design = "fixed": a page remembers which server it was greeted about;   *)
(*                   the hook greets the pages that have not heard of the  *)
(*                   server there is now.                                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Pages, MaxServers, Design

VARIABLES
  gen,      \* how many Lean servers were started
  up,       \* the latest one is running
  hook,     \* eglot-managed-mode-hook has yet to run for the server's change
  open,     \* page -> its event stream is open
  greeted,  \* page -> the server generation Emacs greeted it about (0: none)
  shown,    \* page -> the server generation the page believes it talks to
  spurious  \* a page was told "restarted" about the server it already had

vars == <<gen, up, hook, open, greeted, shown, spurious>>

Init == /\ gen = 0 /\ up = FALSE /\ hook = FALSE
        /\ open = [p \in Pages |-> FALSE]
        /\ greeted = [p \in Pages |-> 0] /\ shown = [p \in Pages |-> 0]
        /\ spurious = FALSE

\* the pages in S are greeted, those that can be: stream open, a server up
GreetAll(S, g0) ==
  LET hit == {p \in S : open[p] /\ up /\ g0[p] # gen}
  IN /\ greeted' = [p \in Pages |-> IF p \in hit THEN gen ELSE g0[p]]
     /\ shown' = [p \in Pages |-> IF p \in hit THEN gen ELSE shown[p]]
     /\ spurious' = (spurious \/ \E p \in hit : shown[p] = gen)

\* a Lean server starts (the first, or after the last one died)
Start == /\ ~up /\ gen < MaxServers
         /\ gen' = gen + 1 /\ up' = TRUE /\ hook' = TRUE
         /\ UNCHANGED <<open, greeted, shown, spurious>>

Die == /\ up /\ up' = FALSE /\ hook' = TRUE
       /\ UNCHANGED <<gen, open, greeted, shown, spurious>>

\* eglot-managed-mode-hook: for the server's change, or for any other buffer
Hook == /\ hook' = FALSE
        /\ GreetAll(Pages, IF Design = "pr" THEN [p \in Pages |-> 0] ELSE greeted)
        /\ UNCHANGED <<gen, up, open>>

\* a page opens its stream (or closes it); a cursor move greets as well
Open(p) == /\ ~open[p] /\ open' = [open EXCEPT ![p] = TRUE]
           /\ LET hit == up /\ greeted[p] # gen
              IN /\ greeted' = [greeted EXCEPT ![p] = IF hit THEN gen ELSE @]
                 /\ shown' = [shown EXCEPT ![p] = IF hit THEN gen ELSE @]
                 /\ spurious' = (spurious \/ (hit /\ shown[p] = gen))
           /\ UNCHANGED <<gen, up, hook>>
Close(p) == /\ open[p] /\ open' = [open EXCEPT ![p] = FALSE]
            /\ UNCHANGED <<gen, up, hook, greeted, shown, spurious>>
Move == /\ GreetAll(Pages, greeted) /\ UNCHANGED <<gen, up, hook, open>>

Next == Start \/ Die \/ Hook \/ Move \/ \E p \in Pages : Open(p) \/ Close(p)

Spec == Init /\ [][Next]_vars /\ WF_vars(hook /\ Hook)

\* a page is told "restarted" only about a server it did not have
NoSpuriousRestart == ~spurious

\* a page that stays open comes to know the server that stays up
KnowsTheServer == \A p \in Pages : [](([](open[p] /\ up)) => <>(shown[p] = gen))
================================================================================

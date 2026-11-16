-------------------------- MODULE kitty_lean_webview --------------------------
(***************************************************************************)
(* VS Code's infoview in a page, Emacs its editor (kitty-lean-webview.el,  *)
(* lisp/lang/webview/host.js).                                             *)
(*                                                                         *)
(* A page calls the editor with POSTs, each call an id the page counts     *)
(* from 0; the answer comes back later (Lean takes its time) on the page's *)
(* event stream.  The stream can break and the page reopens it (an        *)
(* EventSource does); a page can also go away for good, and is forgotten  *)
(* after a while.  Each answer goes to the page that asked; while its      *)
(* stream is down it waits in that page's outbox.                          *)
(*                                                                         *)
(* A page gets Emacs' hello (the position, the server's capabilities)     *)
(* once its stream is open and a Lean server is up: when it opens, or when *)
(* the server comes later.  The infoview hears it only once React has run  *)
(* its effects (its listeners): the host opens the stream after the        *)
(* infoview's first call, which an effect makes.                           *)
(*                                                                         *)
(* A write to a stream the page has closed, before Emacs has read that,    *)
(* fails: the stream is down and the answer waits.  A page whose stream    *)
(* stays down is forgotten, even one still loaded (a laptop asleep): when  *)
(* it comes back, Emacs tells it to reload, since its subscriptions and    *)
(* waiting answers are gone.                                               *)
(*                                                                         *)
(* What must hold: a page only ever gets answers to its own calls; every   *)
(* call of a page that stays is answered; a page that stays hears the      *)
(* hello; a forgotten page leaves nothing behind (outbox, RPC sessions).   *)
(*                                                                         *)
(* Bug names the mistake test/run.sh checks that TLC catches:              *)
(*   "early"      the stream opens as soon as the page loads              *)
(*   "nobox"      an answer for a page whose stream is down is dropped     *)
(*   "broadcast"  answers go to every open stream (ids clash across pages) *)
(*   "keep"       a forgotten page keeps its RPC sessions alive            *)
(*   "greetonce"  the hello is counted as sent even with no server up      *)
(*   "noreload"   a forgotten page that comes back just carries on         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Pages, Ids, Bug

VARIABLES
  mounted,   \* page -> the infoview's effects have run
  stream,    \* page -> "none" (never opened), "open", "down"
  heard,     \* page -> the infoview heard the hello
  greeted,   \* page -> Emacs sent the hello
  called,    \* page -> ids it called
  waiting,   \* calls Lean has not answered: <<page, id>>
  outbox,    \* answers waiting for a page's stream: <<page, id>>
  got,       \* answers each page received: <<to, <<from, id>>>>
  alive,     \* page -> still loaded
  forgotten, \* page -> Emacs forgot it
  sessions,  \* pages whose RPC sessions Emacs keeps alive
  serverUp   \* a Lean buffer has its server

vars == <<mounted, stream, heard, greeted, called, waiting, outbox, got, alive, forgotten, sessions, serverUp>>

Init == /\ mounted = [p \in Pages |-> FALSE] /\ stream = [p \in Pages |-> "none"]
        /\ heard = [p \in Pages |-> FALSE] /\ greeted = [p \in Pages |-> FALSE]
        /\ called = [p \in Pages |-> {}] /\ waiting = {} /\ outbox = {} /\ got = {}
        /\ alive = [p \in Pages |-> TRUE] /\ forgotten = [p \in Pages |-> FALSE]
        /\ sessions = {} /\ serverUp = FALSE

\* React commits and runs the infoview's effects: listeners on, first call out
Mount(p) == /\ alive[p] /\ ~mounted[p] /\ ~forgotten[p]
            /\ mounted' = [mounted EXCEPT ![p] = TRUE]
            /\ called' = [called EXCEPT ![p] = @ \cup {0}]
            /\ waiting' = waiting \cup {<<p, 0>>}
            /\ UNCHANGED <<stream, heard, greeted, outbox, got, alive, forgotten, sessions, serverUp>>

\* the page calls the editor again (an RPC session among them)
Call(p, i) == /\ alive[p] /\ mounted[p] /\ i \notin called[p]
              /\ called' = [called EXCEPT ![p] = @ \cup {i}]
              \* a forgotten page's calls are dropped: it reloads when its stream is back
              /\ IF forgotten[p] THEN UNCHANGED <<waiting, sessions>>
                 ELSE /\ waiting' = waiting \cup {<<p, i>>}
                      /\ sessions' = sessions \cup {p}
              /\ UNCHANGED <<mounted, stream, heard, greeted, outbox, got, alive, forgotten, serverUp>>

\* the hello, if there is a server to tell of
Hello(p) == /\ greeted' = [greeted EXCEPT ![p] = serverUp \/ Bug = "greetonce"]
            /\ heard' = IF serverUp /\ mounted[p] THEN [heard EXCEPT ![p] = TRUE] ELSE heard

\* the host opens (or reopens) the page's event stream; Emacs sends what waited
Open(p) == /\ alive[p] /\ stream[p] # "open" /\ ~forgotten[p]
           /\ (Bug = "early" \/ mounted[p])
           /\ stream' = [stream EXCEPT ![p] = "open"]
           /\ IF greeted[p] THEN UNCHANGED <<greeted, heard>> ELSE Hello(p)
           /\ got' = got \cup {<<p, a>> : a \in {x \in outbox : x[1] = p}}
           /\ outbox' = {x \in outbox : x[1] # p}
           /\ UNCHANGED <<mounted, called, waiting, alive, forgotten, sessions, serverUp>>

\* a forgotten page that is still loaded comes back: told to reload, it is a
\* new page (its calls start again from 0)
Reload(p) == /\ alive[p] /\ forgotten[p]
             /\ IF Bug = "noreload"
                THEN /\ forgotten' = [forgotten EXCEPT ![p] = FALSE]
                     /\ stream' = [stream EXCEPT ![p] = "open"]
                     /\ UNCHANGED <<mounted, called, greeted, heard>>
                ELSE /\ forgotten' = [forgotten EXCEPT ![p] = FALSE]
                     /\ stream' = [stream EXCEPT ![p] = "none"]
                     /\ mounted' = [mounted EXCEPT ![p] = FALSE]
                     /\ called' = [called EXCEPT ![p] = {}]
                     /\ greeted' = [greeted EXCEPT ![p] = FALSE]
                     /\ heard' = [heard EXCEPT ![p] = FALSE]
             /\ waiting' = {c \in waiting : c[1] # p}
             /\ got' = {g \in got : g[1] # p}
             /\ UNCHANGED <<outbox, alive, sessions, serverUp>>

\* Lean's server comes up: every page with an open stream not yet greeted is
ServerUp == /\ ~serverUp
            /\ serverUp' = TRUE
            /\ greeted' = [p \in Pages |-> greeted[p] \/ stream[p] = "open"]
            /\ heard' = [p \in Pages |-> heard[p] \/ (stream[p] = "open" /\ ~greeted[p] /\ mounted[p])]
            /\ UNCHANGED <<mounted, stream, called, waiting, outbox, got, alive, forgotten, sessions>>

Break(p) == /\ stream[p] = "open"
            /\ stream' = [stream EXCEPT ![p] = "down"]
            /\ UNCHANGED <<mounted, heard, greeted, called, waiting, outbox, got, alive, forgotten, sessions, serverUp>>

\* Lean answers a call; Emacs sends the answer on
Answer(c) ==
  /\ c \in waiting
  /\ waiting' = waiting \ {c}
  /\ LET p == c[1] IN
     IF forgotten[p] THEN UNCHANGED <<outbox, got, stream>>
     ELSE IF Bug = "broadcast"
     THEN /\ got' = got \cup {<<q, c>> : q \in {r \in Pages : stream[r] = "open"}}
          /\ outbox' = IF stream[p] = "open" THEN outbox ELSE outbox \cup {c}
          /\ UNCHANGED stream
     ELSE IF stream[p] = "open" THEN /\ got' = got \cup {<<p, c>>} /\ UNCHANGED <<outbox, stream>>
     ELSE IF Bug = "nobox" THEN UNCHANGED <<outbox, got, stream>>
     ELSE /\ outbox' = outbox \cup {c} /\ UNCHANGED <<got, stream>>
  /\ UNCHANGED <<mounted, heard, greeted, called, alive, forgotten, sessions, serverUp>>

\* the same, but the page has closed the stream and Emacs has not read that:
\* the write fails, the stream is down, the answer waits
AnswerFails(c) ==
  /\ c \in waiting /\ stream[c[1]] = "open" /\ ~forgotten[c[1]] /\ Bug # "broadcast"
  /\ waiting' = waiting \ {c}
  /\ stream' = [stream EXCEPT ![c[1]] = "down"]
  /\ outbox' = IF Bug = "nobox" THEN outbox ELSE outbox \cup {c}
  /\ UNCHANGED <<mounted, heard, greeted, called, got, alive, forgotten, sessions, serverUp>>

\* the page is closed (or reloaded: a new page)
Leave(p) == /\ alive[p]
            /\ alive' = [alive EXCEPT ![p] = FALSE]
            /\ stream' = [stream EXCEPT ![p] = IF @ = "open" THEN "down" ELSE @]
            /\ UNCHANGED <<mounted, heard, greeted, called, waiting, outbox, got, forgotten, sessions, serverUp>>

\* page-timeout seconds after its stream went down (or never came) Emacs
\* forgets it: a page closed for good, or one away too long
Forget(p) == /\ ~forgotten[p] /\ stream[p] # "open"
             /\ forgotten' = [forgotten EXCEPT ![p] = TRUE]
             /\ outbox' = {x \in outbox : x[1] # p}
             /\ sessions' = IF Bug = "keep" THEN sessions ELSE sessions \ {p}
             /\ UNCHANGED <<mounted, stream, heard, greeted, called, waiting, got, alive, serverUp>>

Next == \/ ServerUp
        \/ \E p \in Pages :
             \/ Mount(p) \/ Open(p) \/ Break(p) \/ Leave(p) \/ Forget(p) \/ Reload(p)
             \/ \E i \in Ids : Call(p, i)
             \/ \E c \in waiting : Answer(c) \/ AnswerFails(c)

\* the server comes up, pages load, streams open, Lean answers, dead pages
\* are forgotten and come-back pages reload; a page still loaded is not
\* forgotten for ever and again
Fair == /\ WF_vars(ServerUp)
        /\ \A p \in Pages : /\ WF_vars(Mount(p)) /\ WF_vars(Open(p)) /\ WF_vars(Reload(p))
                            /\ WF_vars(~alive[p] /\ Forget(p))
                            /\ \A i \in Ids : WF_vars(Answer(<<p, i>>))

Spec == Init /\ [][Next]_vars /\ Fair

TypeOK == /\ \A g \in got : g[1] \in Pages
          /\ outbox \subseteq (Pages \X Ids)

\* a page only gets answers to its own calls
OwnAnswers == \A g \in got : g[2][1] = g[1]

\* a forgotten page leaves nothing behind
NothingLeft == \A p \in Pages : forgotten[p] =>
                 /\ ~\E x \in outbox : x[1] = p
                 /\ p \notin sessions

\* a page that stays hears the hello, and gets every answer (or reloads)
Heard == \A p \in Pages : []<>(heard[p] \/ ~alive[p] \/ forgotten[p])
Answered == \A p \in Pages : \A i \in Ids :
              [](i \in called[p] => <>(<<p, <<p, i>>>> \in got \/ ~alive[p] \/ i \notin called[p]))
================================================================================

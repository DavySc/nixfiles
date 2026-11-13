;;; kitty-ocaml-test.el --- OCaml, against the real tools  -*- lexical-binding: t; -*-

;; dune's error lines (jumped to), executables, the opam environment, the
;; formatter, ocaml-lsp through eglot, utop: run for real when the tools are
;; on PATH (OCaml, dune, ocamlformat, ocaml-lsp-server, utop), skipped when not.
;;   emacs --batch -L <packages> -L lisp -L lisp/lang -l test/kitty-ocaml-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(when (locate-library "tuareg-autoloads") (load "tuareg-autoloads" nil t))
(when (locate-library "dune-autoloads") (load "dune-autoloads" nil t))
(when (locate-library "utop-autoloads") (load "utop-autoloads" nil t))
(require 'kitty-lib)
(require 'kitty-core)
(require 'kitty-prog)
(require 'kitty-ocaml)
(when (locate-library "evil") (require 'kitty-evil))
(when (locate-library "apheleia") (require 'apheleia))
(defconst kot--have-tuareg (and (locate-library "tuareg") t))

(defun kot--tree (files)
  "A temporary directory holding FILES (an alist of name and contents)."
  (let ((dir (file-name-as-directory (make-temp-file "kot" t))))
    (dolist (f files)
      (let ((path (expand-file-name (car f) dir)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path (insert (cdr f)))))
    dir))

(defconst kot--project
  '(("dune-project" . "(lang dune 3.0)\n")
    (".ocamlformat" . "profile = default\n")
    ("lib/dune" . "(library (name mylib))\n")
    ("lib/mylib.ml" . "let add a b = a + b\nlet unused x = let y = 3 in x\n")
    ("bin/dune" . "; the program\n(executable (name main) (libraries mylib))\n")
    ("bin/main.ml" . "let () = print_endline (string_of_int (Mylib.add 1 2))\n")
    ("test/dune" . "(tests (names t1 t2) (libraries mylib))\n")
    ("test/t1.ml" . "let () = assert (Mylib.add 1 2 = 3)\n")
    ("test/t2.ml" . "let () = assert (Mylib.add 1 2 = 3)\n")
    ("_build/default/bin/dune" . "(executable (name stale))\n"))
  "A dune project with a library, a program, tests and a stale _build.")

(defun kot--wait (proc-buffer)
  "Wait for the compilation in PROC-BUFFER to finish; return its text."
  (let ((proc (get-buffer-process proc-buffer)))
    (with-timeout (120 (error "The command did not finish"))
      (while (and proc (process-live-p proc)) (accept-process-output proc 0.1)))
    (with-current-buffer proc-buffer (buffer-substring-no-properties (point-min) (point-max)))))

;;;; The dune root

(ert-deftest kitty-ocaml-root-is-where-dune-looks ()
  "The outermost dune-workspace, else the outermost dune-project."
  (let ((dir (kot--tree '(("dune-project" . "") ("sub/dune-project" . "") ("sub/lib/x.ml" . "")
                          ("w/dune-workspace" . "") ("w/a/dune-project" . "") ("w/a/b/c.ml" . "")))))
    (should (equal dir (kitty-ocaml-root (expand-file-name "sub/lib/" dir))))        ; outermost project
    (should (equal (expand-file-name "w/" dir) (kitty-ocaml-root (expand-file-name "w/a/b/" dir))))))

;;;; Stanzas and executables

(ert-deftest kitty-ocaml-reads-executable-and-test-stanzas ()
  "names, comments, and stanzas that are not ours."
  (let ((f (make-temp-file "dune")))
    (with-temp-file f
      (insert "; a comment (executable (name nope))\n(library (name l) (libraries a b))\n"
              "(executable (name main) (public_name m))\n#| block (executable (name no)) |#\n"
              "(executables\n (names a\n  b) ; two\n (libraries x))\n(test (name t) (libraries alcotest))\n"
              "(tests (names u v))\n(rule (alias runtest) (action (run %{exe:x.exe})))\n"))
    (should (equal '((executable "main") (executable "a" "b") (test "t") (test "u" "v"))
                   (kitty-ocaml-dune-stanzas f)))))

(ert-deftest kitty-ocaml-debugging-needs-bytecode-mode ()
  "dune builds main.bc only with (modes byte ...): the debug command says so, and the target exists then."
  (let ((dir (kot--tree '(("dune-project" . "")
                          ("a/dune" . "(executable (name main))")
                          ("b/dune" . "(executable (name main) (modes byte exe))")
                          ("c/dune" . "(executables (names x y) (modes (byte native)))")))))
    (should-not (kitty-ocaml-bytecode-p "./a/main.exe" dir))
    (should (kitty-ocaml-bytecode-p "./b/main.exe" dir))
    (should (kitty-ocaml-bytecode-p "./c/y.exe" dir))
    (should-not (kitty-ocaml-bytecode-p "./nowhere/z.exe" dir))
    (let ((default-directory (expand-file-name "a/" dir)) (kitty-ocaml-use-opam nil))
      (should-error (kitty-ocaml-debug) :type 'user-error))))

(ert-deftest kitty-ocaml-bytecode-target-builds-with-real-dune ()
  "The target the debugger is given exists after the build command it runs."
  (skip-unless (and (executable-find "dune") (executable-find "ocaml")))
  (let* ((dir (kot--tree '(("dune-project" . "(lang dune 3.0)") ("bin/dune" . "(executable (name main) (modes byte exe))")
                           ("bin/main.ml" . "let () = print_endline \"hi\"\n"))))
         (default-directory dir))
    (should (kitty-ocaml-bytecode-p "./bin/main.exe" dir))
    (should (zerop (call-process "dune" nil nil nil "build" "--display=quiet" "./bin/main.bc")))
    (should (file-exists-p (expand-file-name "_build/default/bin/main.bc" dir)))))

(ert-deftest kitty-ocaml-executables-here-else-everywhere ()
  "The program next to the file first; without one every program, never _build's."
  (let* ((dir (kot--tree kot--project)))
    (should (equal '(("bin/main" . "./bin/main.exe"))
                   (kitty-ocaml-executables (expand-file-name "bin/" dir) dir)))
    ;; in lib/ (no program): all of the project's, the stale _build copy excluded
    (should (equal '(("bin/main" . "./bin/main.exe"))
                   (kitty-ocaml-executables (expand-file-name "lib/" dir) dir)))
    ;; a program at the root
    (with-temp-file (expand-file-name "dune" dir) (insert "(executable (name tool))\n"))
    (should (equal '("tool") (mapcar #'car (kitty-ocaml-executables dir dir))))
    (should (equal "./tool.exe" (cdar (kitty-ocaml-executables dir dir))))))

;;;; dune, really

(ert-deftest kitty-ocaml-build-errors-are-jumps ()
  "Run the real dune build: warnings and errors land on their file, line and column."
  (skip-unless (executable-find "dune"))
  (skip-unless kot--have-tuareg)
  (require 'tuareg)
  (let* ((dir (kot--tree (append '(("bin/main.ml" . "let () = print_endline (string_of_int (Mylib.add 1 \"two\"))\n")
                                   ("lib/mylib.ml" . "let add a b = a + b\n")
                                   ("test/t1.ml" . "let () = let y = 1 in assert true\n"))
                                 (seq-remove (lambda (f) (member (car f) '("bin/main.ml" "lib/mylib.ml" "test/t1.ml")))
                                             kot--project))))
         (default-directory (expand-file-name "lib/" dir))
         (kitty-ocaml-use-opam nil)
         (buf (kitty-ocaml-build))
         (out (kot--wait buf)))
    (should (string-match-p "File \"test/t1.ml\", line 1, characters 13-14:" out))
    (should-not (string-match-p "\e\\[" out))                       ; colours decoded, not left in
    (with-current-buffer buf
      (compilation--ensure-parse (point-max))
      (goto-char (point-min))
      (search-forward "File \"bin/main.ml\"")
      (beginning-of-line)
      (compile-goto-error)
      (should (equal (expand-file-name "bin/main.ml" dir) (buffer-file-name)))
      (should (= 1 (line-number-at-pos)))
      (should (= 51 (current-column))))                      ; characters 51-56: the "two"
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "File \"test/t1.ml\"")
      (beginning-of-line)
      (compilation--ensure-parse (point-max))
      (let ((msg (get-text-property (point) 'compilation-message)))
        ;; dune says "Error (warning 26 ...)": an error, since warnings are errors in dev
        (should (= 2 (compilation--message->type msg)))))))

(ert-deftest kitty-ocaml-run-and-test-through-the-real-dune ()
  "The command lines kittymax builds work: dune exec ./bin/main.exe, dune test."
  (skip-unless (executable-find "dune"))
  (skip-unless (executable-find "ocaml"))
  (let* ((dir (kot--tree (cons '("lib/mylib.ml" . "let add a b = a + b\n") (assoc-delete-all "lib/mylib.ml" (copy-sequence kot--project)))))
         (default-directory (expand-file-name "bin/" dir))
         (kitty-ocaml-use-opam nil)
         (exe (car (kitty-ocaml-executables default-directory dir))))
    (should (equal "3\n" (let ((default-directory dir))
                           (shell-command-to-string (concat "dune exec --display=quiet " (shell-quote-argument (cdr exe)) " 2>&1")))))
    (let ((out (kot--wait (let ((default-directory (expand-file-name "test/" dir))) (kitty-ocaml-test)))))
      (should (string-match-p "finished" out)))))

;;;; The opam environment

(defconst kot--opam-env
  ;; what `opam env --sexp' prints (opam 2.6.1, captured)
  "(
  (\"OPAM_LAST_ENV\" \"/home/me/.opam/.last-env/env-1-0\")
  (\"OPAM_SWITCH_PREFIX\" \"/home/me/.opam/5.2.0\")
  (\"MANPATH\" \":/home/me/.opam/5.2.0/man\")
  (\"PATH\" \"/home/me/.opam/5.2.0/bin:/usr/bin\")
)
")

(ert-deftest kitty-ocaml-parses-opam-env ()
  (let ((env (kitty-ocaml-parse-opam-env kot--opam-env)))
    (should (equal "/home/me/.opam/5.2.0" (cdr (assoc "OPAM_SWITCH_PREFIX" env))))
    (should (equal "/home/me/.opam/5.2.0/bin:/usr/bin" (cdr (assoc "PATH" env))))
    (should (= 4 (length env))))
  ;; Windows: backslashes, as OCaml's %S writes them
  (should (equal "C:\\Users\\me\\.opam\\default\\bin;C:\\Windows"
                 (cdr (assoc "Path" (kitty-ocaml-parse-opam-env "((\"Path\" \"C:\\\\Users\\\\me\\\\.opam\\\\default\\\\bin;C:\\\\Windows\"))")))))
  (should-not (kitty-ocaml-parse-opam-env "garbage ("))
  (should-not (kitty-ocaml-parse-opam-env "")))

(ert-deftest kitty-ocaml-env-reaches-programs-and-commands ()
  "A buffer finds the switch's programs; compile runs with its variables."
  (let* ((root (kot--tree '(("dune-project" . "") ("bin/x.ml" . "")
                            ("switch/bin/ocamllsp" . "#!/bin/sh\n"))))
         (switch (expand-file-name "switch" root))
         (env `(("PATH" . ,(concat switch "/bin" path-separator (or (getenv "PATH") "")))
                ("OPAM_SWITCH_PREFIX" . ,switch))))
    (set-file-modes (expand-file-name "switch/bin/ocamllsp" root) #o755)
    (puthash root (list env) kitty-ocaml--env-cache)
    (let ((default-directory (expand-file-name "bin/" root)))
      (with-temp-buffer
        (should-not (equal (expand-file-name "switch/bin/ocamllsp" root) (executable-find "ocamllsp")))
        (kitty-ocaml--apply-env (kitty-ocaml--env-now root))
        (should (equal (expand-file-name "switch/bin/ocamllsp" root) (executable-find "ocamllsp")))
        (should (equal switch (getenv "OPAM_SWITCH_PREFIX"))))
      ;; not in other buffers
      (with-temp-buffer (should-not (equal switch (getenv "OPAM_SWITCH_PREFIX"))))
      (skip-unless (not (eq system-type 'windows-nt)))
      (let ((out (kot--wait (kitty-ocaml--compile "echo prefix=$OPAM_SWITCH_PREFIX"))))
        (should (string-match-p (concat "prefix=" (regexp-quote switch)) out))))))

(ert-deftest kitty-ocaml-opam-is-asked-once-and_not-blocking ()
  "opam env runs in the background, once for many buffers; a failure means no environment."
  (skip-unless (not (eq system-type 'windows-nt)))
  (let* ((bin (kot--tree `(("opam" . ,(concat "#!/bin/sh\nsleep 0.3\necho x >> \"$0.calls\"\n"
                                              "[ \"$2\" = --sexp ] && echo '((\"FOO\" \"bar\"))'\n")))))
         (exec-path (cons (directory-file-name bin) exec-path))
         (root (kot--tree '(("dune-project" . "")))) got1 got2)
    (set-file-modes (expand-file-name "opam" bin) #o755)
    (clrhash kitty-ocaml--env-cache)
    (let ((t0 (float-time)))
      (kitty-ocaml--with-env root (lambda (e) (setq got1 (list e))))
      (kitty-ocaml--with-env root (lambda (e) (setq got2 (list e))))
      (should (< (- (float-time) t0) 0.2))                     ; did not wait for opam
      (should-not got1))
    (with-timeout (10 (error "opam never answered"))
      (while (not (and got1 got2)) (accept-process-output nil 0.05)))
    (should (equal '((("FOO" . "bar"))) got1))
    (should (equal got1 got2))
    (should (= 1 (length (split-string (with-temp-buffer (insert-file-contents (expand-file-name "opam.calls" bin)) (buffer-string)) "\n" t))))
    ;; cached: no second process
    (let (again) (kitty-ocaml--with-env root (lambda (e) (setq again (list e)))) (should again))
    ;; opam failing: no environment, and the callbacks still run
    (with-temp-file (expand-file-name "opam" bin) (insert "#!/bin/sh\nexit 1\n"))
    (let ((root2 (kot--tree '(("dune-project" . "")))) done)
      (kitty-ocaml--with-env root2 (lambda (e) (setq done (list e))))
      (with-timeout (10 (error "no answer")) (while (not done) (accept-process-output nil 0.05)))
      (should (equal '(nil) done)))))

;;;; Editing

(ert-deftest kitty-ocaml-modes-by-file ()
  (skip-unless kot--have-tuareg)
  (should (eq 'tuareg-mode (assoc-default "x/a.ml" auto-mode-alist #'string-match)))
  (should (eq 'tuareg-interface-mode (assoc-default "x/a.mli" auto-mode-alist #'string-match)))
  (should (eq 'dune-mode (assoc-default "x/dune" auto-mode-alist #'string-match)))
  (should (eq 'dune-mode (assoc-default "dune-project" auto-mode-alist #'string-match))))

(defun kot--type (text keys)
  "Type KEYS (evil, insert state first) into a tuareg buffer holding TEXT (| = point)."
  (with-temp-buffer
    (insert (replace-regexp-in-string "|" "" text))
    (let ((kitty-ocaml-use-opam nil)) (tuareg-mode))
    (setq buffer-file-name nil)
    (electric-pair-local-mode 1)
    (goto-char (1+ (or (string-search "|" text) 0)))
    (switch-to-buffer (current-buffer))
    (buffer-enable-undo)
    (evil-local-mode 1)
    (evil-normal-state)
    (execute-kbd-macro (kbd keys))
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest kitty-ocaml-electric-comment-and-quotes ()
  "(* opens a comment (* | *); a ' is a type variable, not a pair."
  (skip-unless kot--have-tuareg)
  (skip-unless (featurep 'evil))
  (should (equal "(* hi *)" (kot--type "|" "i ( * h i <escape>")))
  (should (equal "let f (x : 'a) = x" (kot--type "|" "i l e t SPC f SPC ( x SPC : SPC ' a ) SPC = SPC x <escape>")))
  ;; no pair inside a string
  (should (equal "let s = \"(*)\"" (kot--type "|" "i l e t SPC s SPC = SPC \" ( * <escape>"))))

(ert-deftest kitty-ocaml-keys ()
  "SPC m: dune commands in OCaml and dune files, and the other file."
  (skip-unless kot--have-tuareg)
  (dolist (probe '((tuareg-mode "m" kitty-ocaml-build) (tuareg-mode "c" kitty-ocaml-check)
                   (tuareg-mode "r" kitty-ocaml-run) (tuareg-mode "d" kitty-ocaml-debug)
                   (tuareg-mode "t" kitty-ocaml-test) (tuareg-mode "p" kitty-ocaml-promote)
                   (tuareg-mode "a" tuareg-find-alternate-file) (tuareg-mode "u u" kitty-ocaml-utop)
                   (tuareg-mode "u e" kitty-ocaml-eval-phrase) (tuareg-mode "f" kitty-ocaml-format)
                   (dune-mode "m" kitty-ocaml-build) (dune-mode "T" kitty-ocaml-test-all)))
    (let* ((map (gethash (nth 0 probe) kitty--local-leaders))
           (b (and map (lookup-key map (kbd (nth 1 probe))))))
      (should (eq (nth 2 probe) (if (consp b) (cdr b) b)))))
  ;; .mli buffers inherit
  (with-temp-buffer
    (tuareg-interface-mode)
    (let ((b (lookup-key (kitty--local-leader-map) (kbd "m"))))
      (should (eq 'kitty-ocaml-build (if (consp b) (cdr b) b))))))

;;;; ocamlformat and dune format, really

(ert-deftest kitty-ocaml-formatters ()
  "apheleia runs ocamlformat for .ml and .mli and dune format-dune-file for dune files."
  (skip-unless (and (locate-library "apheleia") (executable-find "ocamlformat") kot--have-tuareg))
  (require 'apheleia)
  (let ((dir (kot--tree kot--project)))
    (dolist (case '(("lib/f.ml" "let   x=1;;let f  a b=a+b" tuareg-mode "let x = 1\nlet f a b = a + b\n")
                    ("lib/f.mli" "val   f:int->int" tuareg-interface-mode "val f : int -> int\n")
                    ("lib/dune" "(library   (name   mylib))" dune-mode "(library\n (name mylib))\n")))
      (with-current-buffer (find-file-noselect (expand-file-name (nth 0 case) dir))
        (erase-buffer)
        (funcall (nth 2 case))
        (insert (nth 1 case))
        (let (done)
          (apheleia-format-buffer (apheleia--get-formatters) (lambda (&rest _) (setq done t)))
          (with-timeout (30 (error "formatter did not finish"))
            (while (not done) (accept-process-output nil 0.05))))
        (should (equal (nth 3 case) (buffer-string)))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

(ert-deftest kitty-ocaml-format-on-save-only-with-ocamlformat-file ()
  "A style is imposed on save only when the project pinned one."
  (skip-unless (and kot--have-tuareg (locate-library "apheleia")))
  (let ((with (kot--tree kot--project))
        (without (kot--tree '(("dune-project" . "") ("a.ml" . "let x = 1\n")))))
    (with-current-buffer (find-file-noselect (expand-file-name "lib/mylib.ml" with))
      (should (bound-and-true-p apheleia-mode)) (kill-buffer))
    (with-current-buffer (find-file-noselect (expand-file-name "a.ml" without))
      (should-not (bound-and-true-p apheleia-mode)) (kill-buffer))))

;;;; ocaml-lsp, really

(ert-deftest kitty-ocaml-lsp-through-eglot ()
  "ocaml-lsp starts in an OCaml buffer, reports the compiler's error and answers hover."
  (skip-unless (and (executable-find "ocamllsp") (executable-find "dune") (executable-find "ocaml") kot--have-tuareg))
  (require 'eglot)
  (let* ((dir (kot--tree (append '(("bin/main.ml" . "let n : int = Mylib.add 1 2\nlet s : string = n\n")
                                   ("lib/mylib.ml" . "let add a b = a + b\n"))
                                 (seq-remove (lambda (f) (member (car f) '("bin/main.ml" "lib/mylib.ml"))) kot--project))))
         (kitty-ocaml-use-opam nil)
         (trusted-content :all)
         (eglot-sync-connect nil)
         (file (expand-file-name "bin/main.ml" dir))
         (buf (find-file-noselect file)))
    (unwind-protect
        (with-current-buffer buf
          (should (eq major-mode 'tuareg-mode))
          (run-hooks 'post-command-hook)                          ; eglot-ensure connects on the first command
          (with-timeout (60 (error "ocamllsp did not connect"))
            (while (not (eglot-current-server)) (accept-process-output nil 0.1) (run-hooks 'post-command-hook)))
          (let ((server (eglot-current-server)))
            (should (equal '("ocamllsp") (process-command (jsonrpc--process server))))
            ;; ocaml-lsp has no configuration yet: kittymax builds it in the background, restarts
            ;; the server, and what is left is the one real error (line 2), nothing about config
            (with-timeout (120 (error "diagnostics never settled: %S" (mapcar #'flymake-diagnostic-text (flymake-diagnostics))))
              (while (not (and (file-exists-p (expand-file-name "_build/default/bin/.merlin-conf" dir))
                               (eglot-current-server)
                               (equal 1 (length (flymake-diagnostics)))
                               (not (string-match-p "No config" (flymake-diagnostic-text (car (flymake-diagnostics)))))))
                (accept-process-output nil 0.3)
                (when (eglot-current-server) (flymake-start))))
            (setq server (eglot-current-server))
            (let ((d (car (flymake-diagnostics))))
              (should (= 2 (line-number-at-pos (flymake-diagnostic-beg d))))
              (should (eq 'eglot-error (flymake-diagnostic-type d)))
              (should (string-match-p "int" (flymake-diagnostic-text d))))
            ;; hover: the type at point
            (goto-char (point-min)) (search-forward "Mylib.add")
            (let* ((hover (jsonrpc-request server :textDocument/hover (eglot--TextDocumentPositionParams)))
                   (text (format "%S" hover)))
              (should (string-match-p "int" text)))))
      (when-let* ((server (with-current-buffer buf (eglot-current-server))))
        (ignore-errors (eglot-shutdown server)))
      (kill-buffer buf))))

;;;; utop, really

(ert-deftest kitty-ocaml-utop-evaluates-a-phrase ()
  "SPC m u e: the phrase at point goes to a real utop and the answer comes back."
  (skip-unless (and (executable-find "utop") (locate-library "utop") kot--have-tuareg))
  (require 'utop)
  (let* ((dir (kot--tree kot--project))
         (kitty-ocaml-use-opam nil)
         (file (expand-file-name "bin/main.ml" dir)))
    (with-current-buffer (find-file-noselect file)
      (erase-buffer)
      (insert "let answer = 6 * 7;;\n")
      (goto-char (point-min))
      (kitty-ocaml-eval-phrase)
      (with-timeout (60 (error "utop did not answer"))
        (while (not (and (get-buffer "*utop*")
                         (with-current-buffer "*utop*" (string-match-p "val answer : int = 42" (buffer-string)))))
          (accept-process-output nil 0.2)))
      (when-let* ((p (get-buffer-process "*utop*"))) (set-process-query-on-exit-flag p nil) (delete-process p))
      (set-buffer-modified-p nil)
      (kill-buffer "*utop*")
      (kill-buffer))))

(provide 'kitty-ocaml-test)
;;; kitty-ocaml-test.el ends here

;;; kitty-ocaml.el --- OCaml  -*- lexical-binding: t; -*-

;;; Commentary:

;; tuareg-mode (and tuareg-interface-mode for .mli), dune-mode for dune files,
;; ocaml-lsp through eglot (types on hover, definitions, references, rename,
;; case-split, destruct, construct holes, diagnostics from the compiler),
;; ocamlformat, utop, and dune from SPC m:
;;
;;   m build        the whole workspace            c check (types only, faster)
;;   r run          an executable of the project   d debug it (ocamlearlybird)
;;   t test         this directory's tests         T all tests
;;   w watch        dune build -w                  p promote expect-test output
;;   a .ml / .mli   the other file                 f format (ocamlformat)
;;   F dune fmt     every file                     u utop: u start, e phrase,
;;   I install the OCaml tools with opam              r region, b buffer
;;   E read the opam environment again
;;
;; Errors and warnings from dune are jumps (]d / M-g n); paths are relative to
;; the dune root, where every command runs.
;;
;; The OCaml tools come from the project's opam switch: `opam env' of the
;; project (a local _opam switch when there is one) is read once, without
;; blocking Emacs, and applied to the OCaml buffers and the commands here.
;; Under Nix a project's dev shell comes first on PATH, and the tools
;; kittymax carries (built for one compiler version) are the fallback: a
;; language server only works with the compiler version it was built for.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)
(require 'seq)
(require 'compile)

(declare-function dape "dape")
(declare-function eglot-ensure "eglot")
(declare-function kitty-format "kitty-prog")
(declare-function kitty-eglot-ensure-for "kitty-prog")
(declare-function tuareg-run-ocaml "tuareg")
(declare-function tuareg-eval-phrase "tuareg")
(declare-function tuareg-eval-region "tuareg")
(declare-function tuareg-eval-buffer "tuareg")
(declare-function utop "utop")
(declare-function utop-eval-phrase "utop")
(declare-function utop-eval-region "utop")
(declare-function utop-eval-buffer "utop")
(defvar utop-command)
(defvar utop-edit-command)

(setq utop-edit-command nil)             ; kittymax picks the command itself

(defvar kitty-ocaml-use-opam t
  "Read `opam env' for OCaml buffers and commands (when opam is installed).")

;;;; The dune root, and what it builds

(defun kitty-ocaml-root (&optional dir)
  "The dune workspace root for DIR, as dune finds it (with a trailing slash).
The outermost dune-workspace, else the outermost dune-project; without
either, the project root."
  (let* ((start (file-name-as-directory (expand-file-name (or dir default-directory))))
         (d start) workspace project)
    (while d
      (when (file-exists-p (expand-file-name "dune-workspace" d)) (setq workspace d))
      (when (file-exists-p (expand-file-name "dune-project" d)) (setq project d))
      (setq d (let ((up (file-name-directory (directory-file-name d))))
                (unless (equal up d) up))))
    (file-name-as-directory (or workspace project
                                (let ((default-directory start)) (kitty-project-root))))))

(defun kitty-ocaml--relative (dir root)
  "DIR relative to ROOT, without a trailing slash (\".\" for ROOT itself)."
  (let ((rel (directory-file-name (file-relative-name (expand-file-name dir) root))))
    (if (string-empty-p rel) "." rel)))

(defun kitty-ocaml-ocamlformat-p (&optional dir)
  "Non-nil when the project pins a style (.ocamlformat above DIR)."
  (locate-dominating-file (or dir default-directory) ".ocamlformat"))

(defun kitty-ocaml-dune-stanzas (file)
  "The executable and test stanzas of dune FILE: a list of (KIND . NAMES).
KIND is `executable' or `test'; NAMES the names the stanza builds."
  (mapcar (lambda (s) (cons (nth 0 s) (nth 1 s))) (kitty-ocaml--dune-stanza-texts file)))

(defun kitty-ocaml--dune-stanza-texts (file)
  "Like `kitty-ocaml-dune-stanzas', as (KIND NAMES TEXT) with the stanza's own text."
  (with-temp-buffer
    (insert-file-contents file)
    (set-syntax-table lisp-data-mode-syntax-table)
    (goto-char (point-min))
    ;; #| block comments |# are not in the Lisp syntax table's reach
    (while (re-search-forward "#|\\(?:.\\|\n\\)*?|#" nil t) (replace-match " "))
    (goto-char (point-min))
    (let (found)
      (condition-case nil
          (while (progn (forward-comment (buffer-size)) (not (eobp)))
            (cond
             ((looking-at "#;") (forward-char 2) (forward-comment (buffer-size)) (forward-sexp 1))
             ((eq (char-after) ?\()
                (let* ((beg (point)) (end (scan-sexps beg 1)))
                  (when (looking-at "(\\(executables?\\|tests?\\)[ \t\n)]")
                    (let ((kind (if (string-prefix-p "exec" (match-string 1)) 'executable 'test))
                          (text (buffer-substring-no-properties beg end)) names)
                      (when (string-match "(names?[ \t\n]+\\([^()]*\\))" text)
                        (setq names (split-string (match-string 1 text) "[ \t\n]+" t)))
                      (when names (push (list kind names text) found))))
                  (goto-char end)))
             (t (forward-sexp 1))))
        (scan-error nil))
      (nreverse found))))

(defun kitty-ocaml-executables (dir root)
  "Programs to run: (LABEL . TARGET) for the executables under ROOT.
Those in DIR first.  TARGET is the path dune exec takes (./bin/main.exe)."
  (let* ((here (file-name-as-directory (expand-file-name dir)))
         (files (let ((own (expand-file-name "dune" here)))
                  (if (and (file-exists-p own)
                           (seq-some (lambda (s) (eq (car s) 'executable)) (kitty-ocaml-dune-stanzas own)))
                      (list own)
                    (directory-files-recursively
                     root "\\`dune\\'" nil
                     (lambda (d) (not (string-match-p "\\`\\(?:_build\\|_opam\\|node_modules\\|\\..*\\)\\'"
                                                      (file-name-nondirectory (directory-file-name d)))))))))
         out)
    (dolist (f files)
      (let ((rel (kitty-ocaml--relative (file-name-directory f) root)))
        (dolist (stanza (kitty-ocaml-dune-stanzas f))
          (when (eq (car stanza) 'executable)
            (dolist (name (cdr stanza))
              (push (cons (if (equal rel ".") name (concat rel "/" name))
                          (format "./%s%s.exe" (if (equal rel ".") "" (concat rel "/")) name))
                    out))))))
    (nreverse out)))

(defun kitty-ocaml-bytecode-p (target root)
  "Non-nil when the executable TARGET (./bin/main.exe) is built as bytecode too.
dune builds main.bc only when the stanza's (modes ...) lists byte; the debugger needs it."
  (let* ((rel (file-name-directory (string-remove-prefix "./" target)))
         (name (file-name-base target))
         (dune (expand-file-name "dune" (expand-file-name (or rel "") root))))
    (and (file-exists-p dune)
         (seq-some (lambda (s)
                     (and (eq (nth 0 s) 'executable) (member name (nth 1 s))
                          (string-match-p "(modes[^)]*\\_<byte\\_>" (nth 2 s))))
                   (kitty-ocaml--dune-stanza-texts dune)))))

(defun kitty-ocaml--read-executable (root)
  "The (LABEL . TARGET) program to run or debug: the only one, else ask."
  (let ((exes (or (kitty-ocaml-executables default-directory root)
                  (user-error "No executable stanza in a dune file under %s" root))))
    (if (null (cdr exes))
        (car exes)
      (assoc (completing-read "Program: " (mapcar #'car exes) nil t) exes))))

;;;; The opam environment

(defvar kitty-ocaml--env-cache (make-hash-table :test #'equal)
  "Dune root -> (ENV): ENV an alist of (NAME . VALUE) from opam, nil for none.")
(defvar kitty-ocaml--env-waiting (make-hash-table :test #'equal)
  "Dune root -> callbacks waiting for `opam env' to answer.")

(defun kitty-ocaml-parse-opam-env (text)
  "The (NAME . VALUE) pairs in TEXT, the output of `opam env --sexp'."
  (let ((forms (condition-case nil (car (read-from-string text)) (error nil))))
    (when (listp forms)
      (delq nil (mapcar (lambda (e)
                          (and (consp e) (stringp (car e)) (stringp (cadr e))
                               (cons (car e) (cadr e))))
                        forms)))))

(defun kitty-ocaml--opam-p ()
  (and kitty-ocaml-use-opam (executable-find "opam")))

(defun kitty-ocaml--env-strings (env)
  "ENV (an alist) as NAME=VALUE strings."
  (mapcar (lambda (p) (concat (car p) "=" (cdr p))) env))

(defun kitty-ocaml--env-finish (root env)
  (puthash root (list env) kitty-ocaml--env-cache)
  (let ((callbacks (reverse (gethash root kitty-ocaml--env-waiting))))
    (remhash root kitty-ocaml--env-waiting)
    (dolist (cb callbacks) (funcall cb env))))

(defun kitty-ocaml--with-env (root callback)
  "Call CALLBACK with ROOT's opam environment (an alist, or nil).
Asks opam once, in the background; until it answers Emacs is not blocked."
  (let ((hit (gethash root kitty-ocaml--env-cache)))
    (cond
     (hit (funcall callback (car hit)))
     ((not (kitty-ocaml--opam-p)) (funcall callback nil))
     ((gethash root kitty-ocaml--env-waiting) (push callback (gethash root kitty-ocaml--env-waiting)))
     (t
      (puthash root (list callback) kitty-ocaml--env-waiting)
      (let* ((out (generate-new-buffer " *opam env*"))
             (err (generate-new-buffer " *opam env stderr*"))
             (default-directory root))
        (condition-case nil
            (make-process
             :name "opam-env" :command (list "opam" "env" "--sexp") :buffer out :stderr err
             :noquery t :connection-type 'pipe
             :sentinel
             (lambda (proc _event)
               (unless (process-live-p proc)
                 (let ((env (and (zerop (process-exit-status proc))
                                 (with-current-buffer out
                                   (kitty-ocaml-parse-opam-env (buffer-string))))))
                   (kill-buffer out)
                   (kill-buffer err)
                   (kitty-ocaml--env-finish root env)))))
          (error (kill-buffer out) (kill-buffer err)
                 (kitty-ocaml--env-finish root nil))))))))

(defun kitty-ocaml--env-now (root)
  "ROOT's opam environment (an alist), asked for synchronously if not known yet."
  (let ((hit (gethash root kitty-ocaml--env-cache)))
    (if hit
        (car hit)
      (let ((env (when (kitty-ocaml--opam-p)
                   (let ((default-directory root))
                     (with-temp-buffer
                       (when (zerop (call-process "opam" nil (list t nil) nil "env" "--sexp"))
                         (kitty-ocaml-parse-opam-env (buffer-string))))))))
        (puthash root (list env) kitty-ocaml--env-cache)
        env))))

(defun kitty-ocaml--apply-env (env)
  "Make this buffer find and start programs as ENV (opam's) says."
  (when env
    (setq-local process-environment
                (append (kitty-ocaml--env-strings env) process-environment))
    (when-let* ((path (cdr (assoc-string "PATH" env t))))
      (setq-local exec-path (append (parse-colon-path path) (list exec-directory))))))

(defun kitty-ocaml-refresh-env ()
  "Read the opam environment of this project again (a new switch, a new tool)."
  (interactive)
  (let ((root (kitty-ocaml-root)) (buf (current-buffer)))
    (remhash root kitty-ocaml--env-cache)
    (kitty-ocaml--with-env
     root
     (lambda (env)
       (when (buffer-live-p buf)
         (with-current-buffer buf (kitty-ocaml--apply-env env)))
       (message "kittymax: opam environment %s" (if env "read" "not available (no opam, or no switch)"))))))

;;;; Running dune

(defun kitty-ocaml--compile (command &optional comint)
  "Run COMMAND at the dune root, with the project's opam environment."
  (let* ((root (kitty-ocaml-root))
         (default-directory root)
         (compilation-environment (append (kitty-ocaml--env-strings (kitty-ocaml--env-now root))
                                          compilation-environment)))
    (compile command comint)))

(defconst kitty-ocaml--display "--display=quiet"
  "Only errors.  dune's progress line (\"Done: 62% ...\") is redrawn in place with
carriage returns, which a compilation buffer cannot take: the carriage-return
handling invalidates the marker ansi-color keeps, and every coloured error
after the first progress line is left as raw escape codes (which no longer
match the error pattern).  --display=short prints the line too.")

(defun kitty-ocaml--dune (&rest args)
  "The command line `dune ARGS' with line-based output."
  (string-join (append (list "dune") (list (car args)) (list kitty-ocaml--display) (cdr args)) " "))

(defun kitty-ocaml-build ()
  "Build the whole dune workspace."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "build")))

(defun kitty-ocaml-check ()
  "Type-check everything without linking (dune build @check): faster than a build."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "build" "@check")))

(defun kitty-ocaml-run ()
  "Run an executable of the project (the one in this directory, else ask)."
  (interactive)
  (let ((exe (kitty-ocaml--read-executable (kitty-ocaml-root))))
    (kitty-ocaml--compile (concat "dune exec --display=quiet " (shell-quote-argument (cdr exe))) t)))

(defun kitty-ocaml-test ()
  "Run the tests of this directory (dune test DIR)."
  (interactive)
  (let ((rel (kitty-ocaml--relative default-directory (kitty-ocaml-root))))
    (kitty-ocaml--compile (if (equal rel ".")
                              (kitty-ocaml--dune "test")
                            (kitty-ocaml--dune "test" (shell-quote-argument rel))))))

(defun kitty-ocaml-test-all ()
  "Run every test of the workspace."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "test")))

(defun kitty-ocaml-watch ()
  "Rebuild on every save (dune build -w): errors stay in the buffer."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "build" "-w")))

(defun kitty-ocaml-promote ()
  "Accept the output of failing expect tests (dune promote), then reload the buffers."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "promote"))
  (add-hook 'compilation-finish-functions #'kitty-ocaml--revert-after-promote))

(defun kitty-ocaml--revert-after-promote (_buffer status)
  (remove-hook 'compilation-finish-functions #'kitty-ocaml--revert-after-promote)
  (when (string-prefix-p "finished" status)
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and buffer-file-name (derived-mode-p 'tuareg-mode) (not (buffer-modified-p))
                   (not (verify-visited-file-modtime b)))
          (revert-buffer t t t))))))

(defun kitty-ocaml-dune-fmt ()
  "Format every file of the workspace (dune fmt), as the project's .ocamlformat says."
  (interactive)
  (kitty-ocaml--compile (kitty-ocaml--dune "fmt")))

(defun kitty-ocaml-format ()
  "Format the buffer with ocamlformat (its default profile when the project has no .ocamlformat)."
  (interactive)
  (when (and (derived-mode-p 'tuareg-mode) (not (kitty-ocaml-ocamlformat-p)))
    (message "No .ocamlformat in this project: ocamlformat's default profile"))
  (kitty-format))

(defvar kitty-ocaml-opam-packages
  '("ocaml-lsp-server" "ocamlformat" "dune" "utop" "earlybird")
  "What `kitty-ocaml-install-tools' installs in the project's switch.")

(defun kitty-ocaml-install-tools ()
  "Install the OCaml tools kittymax uses into this project's opam switch."
  (interactive)
  (unless (kitty-ocaml--opam-p) (user-error "opam is not installed"))
  (kitty-ocaml--compile (concat "opam install --yes " (string-join kitty-ocaml-opam-packages " ")))
  (add-hook 'compilation-finish-functions #'kitty-ocaml--refresh-after-install))

(defun kitty-ocaml--refresh-after-install (buffer status)
  (remove-hook 'compilation-finish-functions #'kitty-ocaml--refresh-after-install)
  (when (and (string-prefix-p "finished" status) (buffer-live-p buffer))
    (clrhash kitty-ocaml--env-cache)
    (message "kittymax: tools installed; reopen the OCaml files (or SPC m E) to start the language server")))

;;;; utop

(defvar kitty-ocaml--utop-env nil "NAME=VALUE strings for the utop being started.")

(defun kitty-ocaml--utop-start-around (orig arguments)
  "Start utop (ORIG, with ARGUMENTS) in the environment kittymax prepared."
  (let ((process-environment (append kitty-ocaml--utop-env process-environment))
        (exec-path (if-let* ((path (getenv "PATH")))
                       (append (parse-colon-path path) (list exec-directory))
                     exec-path)))
    (funcall orig arguments)))
(advice-add 'utop-start :around #'kitty-ocaml--utop-start-around)

(defun kitty-ocaml--utop-command (root)
  "The utop command line: dune utop in this directory's library, else plain utop."
  (let* ((rel (kitty-ocaml--relative default-directory root))
         (dune (expand-file-name "dune" default-directory)))
    (if (and (file-exists-p dune) (file-exists-p (expand-file-name "dune-project" root))
             (with-temp-buffer (insert-file-contents dune) (re-search-forward "(library\\_>" nil t)))
        (format "dune utop %s -- -emacs" (shell-quote-argument rel))
      "utop -emacs")))

(defun kitty-ocaml-utop ()
  "Start utop (loading this directory's library when it has one), or switch to it."
  (interactive)
  (let* ((root (kitty-ocaml-root))
         (env (kitty-ocaml--env-now root))
         (kitty-ocaml--utop-env (kitty-ocaml--env-strings env))
         (default-directory root)
         (process-environment (append kitty-ocaml--utop-env process-environment))
         (exec-path (if-let* ((path (cdr (assoc-string "PATH" env t))))
                        (append (parse-colon-path path) (list exec-directory))
                      exec-path)))
    (cond
     ((and (require 'utop nil t) (executable-find "utop"))
      (let ((utop-command (kitty-ocaml--utop-command root)))
        (utop)))
     (t (message "utop is not installed: using OCaml's own toplevel (SPC m I installs utop)")
        (tuareg-run-ocaml)))))

(defvar utop-state)
(defvar utop-process)

(defun kitty-ocaml--utop-wait-ready ()
  "Wait (a few seconds at most) until utop has printed its first prompt."
  (when-let* ((buf (get-buffer "*utop*")))
    (with-current-buffer buf
      (let ((deadline (+ (float-time) 15)))
        (while (and (not (eq utop-state 'edit)) (process-live-p utop-process)
                    (< (float-time) deadline))
          (accept-process-output utop-process 0.05))))))

(defun kitty-ocaml--eval (utop-fn tuareg-fn &rest args)
  "Evaluate in utop when it runs (or can start), else in tuareg's toplevel."
  (if (and (require 'utop nil t) (executable-find "utop"))
      (let ((source (current-buffer)))
        ;; starting utop must not take this window; the answer shows below
        (unless (get-buffer "*utop*") (save-window-excursion (kitty-ocaml-utop)))
        (kitty-ocaml--utop-wait-ready)
        (with-current-buffer source (apply utop-fn args))
        (display-buffer "*utop*" '((display-buffer-reuse-window display-buffer-at-bottom)
                                   (window-height . 12))))
    (apply tuareg-fn args)))

(defun kitty-ocaml-eval-phrase ()
  "Send the phrase at point to the toplevel."
  (interactive)
  (kitty-ocaml--eval #'utop-eval-phrase #'tuareg-eval-phrase))

(defun kitty-ocaml-eval-region (beg end)
  "Send the region BEG..END to the toplevel."
  (interactive "r")
  (kitty-ocaml--eval #'utop-eval-region #'tuareg-eval-region beg end))

(defun kitty-ocaml-eval-buffer ()
  "Send the whole buffer to the toplevel."
  (interactive)
  (kitty-ocaml--eval #'utop-eval-buffer #'tuareg-eval-buffer))

;;;; Debugging: ocamlearlybird through dape

(defun kitty-ocaml-debug ()
  "Build a program as bytecode and debug it with ocamlearlybird (dape)."
  (interactive)
  (require 'dape)
  (let* ((root (kitty-ocaml-root))
         (exe (kitty-ocaml--read-executable root))
         (_ (unless (kitty-ocaml-bytecode-p (cdr exe) root)
              (user-error "Debugging needs bytecode: add (modes byte exe) to the executable stanza of %s in %sdune"
                          (car exe) (or (file-name-directory (string-remove-prefix "./" (cdr exe))) ""))))
         (bytecode (concat (file-name-sans-extension (cdr exe)) ".bc"))
         (env (kitty-ocaml--env-now root))
         (adapter (let ((exec-path (if-let* ((path (cdr (assoc-string "PATH" env t))))
                                       (append (parse-colon-path path) exec-path)
                                     exec-path)))
                    (or (executable-find "ocamlearlybird")
                        (user-error "ocamlearlybird not found (SPC m I installs it: opam package earlybird)")))))
    (dape `(command ,adapter
                    command-args ("debug")
                    command-cwd ,root
                    compile ,(format "dune build %s" (shell-quote-argument bytecode))
                    :type "ocaml"
                    :program ,(expand-file-name (concat "_build/default/" (string-remove-prefix "./" bytecode)) root)
                    :console "internalConsole"
                    :stopOnEntry nil
                    :arguments []))))

;;;; Editing

(defun kitty--ocaml-electric-comment ()
  "(* typed where electric-pair closed the paren: leave it as (* | *)."
  (when (and (eq last-command-event ?*)
             (bound-and-true-p electric-pair-mode)
             (eq (char-before (1- (point))) ?\()
             (eq (char-after) ?\))
             (not (nth 3 (syntax-ppss))))
    (insert " ")
    (save-excursion (insert " *"))))

(defun kitty--ocaml-no-pair-quote (char)
  "A ' is a type variable or part of a name in OCaml, not a pair."
  (or (eq char ?') (electric-pair-default-inhibit char)))

(defvar kitty--ocaml-warned-no-lsp nil)
(defvar kitty--ocaml-prepared nil "Dune roots whose configuration was prepared this session.")

(defun kitty-ocaml--needs-merlin-config-p (file root)
  "Non-nil when FILE's directory has no merlin configuration under ROOT's _build yet."
  (let* ((dir (file-name-directory file))
         (rel (kitty-ocaml--relative dir root)))
    (and (file-exists-p (expand-file-name "dune-project" root))
         (file-exists-p (expand-file-name "dune" dir))
         (not (file-exists-p (expand-file-name (concat "_build/default/" (if (equal rel ".") "" (concat rel "/"))
                                                       ".merlin-conf")
                                               root))))))

(declare-function eglot-current-server "eglot")
(declare-function eglot-reconnect "eglot")

(defun kitty-ocaml--prepare-config (buf root)
  "Once per project: `dune build @check' in the background, so ocaml-lsp finds its configuration.
Without it ocaml-lsp says \"No config found ... Try calling 'dune build'\" and cannot see
the project's own modules.  When it is done the server is restarted."
  (when (and buffer-file-name (executable-find "dune")
             (not (member root kitty--ocaml-prepared))
             (kitty-ocaml--needs-merlin-config-p buffer-file-name root))
    (push root kitty--ocaml-prepared)
    (message "kittymax: dune build @check (once, in the background) for the language server")
    (let ((default-directory root))
      (make-process
       :name "dune-check" :command (list "dune" "build" "@check")
       :buffer (generate-new-buffer " *dune check*") :noquery t :connection-type 'pipe
       :sentinel
       (lambda (proc _event)
         (unless (process-live-p proc)
           (kill-buffer (process-buffer proc))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (when-let* ((server (and (fboundp 'eglot-current-server) (eglot-current-server))))
                 (ignore-errors (eglot-reconnect server)))))))))))

(defun kitty--ocaml-start-lsp (buf root)
  "Start ocaml-lsp in BUF once ROOT's opam environment is known."
  (kitty-ocaml--with-env
   root
   (lambda (env)
     (when (buffer-live-p buf)
       (with-current-buffer buf
         (kitty-ocaml--apply-env env)
         (if (executable-find "ocamllsp")
             (progn (kitty-ocaml--prepare-config buf root)
                    (kitty-eglot-ensure-for "ocamllsp"))
           (unless kitty--ocaml-warned-no-lsp
             (setq kitty--ocaml-warned-no-lsp t)
             (message "kittymax: ocamllsp not found: SPC m I installs the OCaml tools with opam"))))))))

(defun kitty--ocaml-setup ()
  (setq-local tab-width 2
              indent-tabs-mode nil
              fill-column 80
              electric-pair-inhibit-predicate #'kitty--ocaml-no-pair-quote)
  (add-hook 'post-self-insert-hook #'kitty--ocaml-electric-comment nil t)
  ;; a style is only imposed on save when the project pinned one (.ocamlformat)
  (unless (kitty-ocaml-ocamlformat-p)
    (when (fboundp 'apheleia-mode) (apheleia-mode -1)))
  (when (and buffer-file-name (not (file-remote-p default-directory)))
    (kitty--ocaml-start-lsp (current-buffer) (kitty-ocaml-root))))
(kitty-add-hook 'tuareg-mode-hook #'kitty--ocaml-setup)

(with-eval-after-load 'eglot
  (defvar eglot-server-programs)
  (add-to-list 'eglot-server-programs
               '(((tuareg-mode :language-id "ocaml") (tuareg-interface-mode :language-id "ocaml.interface"))
                 . ("ocamllsp"))))

;;;; Keys

(defconst kitty-ocaml--dune-keys
  '("m" ("build" . kitty-ocaml-build)
    "c" ("check" . kitty-ocaml-check)
    "r" ("run" . kitty-ocaml-run)
    "d" ("debug" . kitty-ocaml-debug)
    "t" ("test (this directory)" . kitty-ocaml-test)
    "T" ("test (all)" . kitty-ocaml-test-all)
    "w" ("watch" . kitty-ocaml-watch)
    "p" ("promote" . kitty-ocaml-promote)
    "F" ("dune fmt" . kitty-ocaml-dune-fmt)
    "I" ("install tools (opam)" . kitty-ocaml-install-tools)
    "E" ("read opam environment" . kitty-ocaml-refresh-env))
  "SPC m keys every OCaml and dune buffer has.")

(defun kitty--ocaml-bind (mode)
  (apply #'kitty-local-leader mode (append kitty-ocaml--dune-keys '("f" ("format" . kitty-ocaml-format)))))

(kitty--ocaml-bind 'tuareg-mode)
(kitty-local-leader 'tuareg-mode
  "a" '("ml / mli" . tuareg-find-alternate-file)
  "u" (kitty-prefix "utop"
        "u" '("start / switch" . kitty-ocaml-utop)
        "e" '("eval phrase" . kitty-ocaml-eval-phrase)
        "r" '("eval region" . kitty-ocaml-eval-region)
        "b" '("eval buffer" . kitty-ocaml-eval-buffer)))
(kitty--ocaml-bind 'dune-mode)

(with-eval-after-load 'evil
  (declare-function evil-set-initial-state "evil-core")
  (evil-set-initial-state 'utop-mode 'insert))

(provide 'kitty-ocaml)
;;; kitty-ocaml.el ends here

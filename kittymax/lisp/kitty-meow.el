;;; kitty-meow.el --- modal editing and the SPC leader tree  -*- lexical-binding: t; -*-

;;; Commentary:

;; meow in its QWERTY layout (selection first, then the verb: `w' marks a
;; word, `d' deletes it), with Doom's leader tree on SPC:
;;
;;   SPC SPC  commands       SPC .  find file     SPC ,  buffers
;;   SPC /    ripgrep        SPC b  buffers       SPC f  files
;;   SPC p    project        SPC g  git           SPC w  windows
;;   SPC s    search         SPC c  code          SPC o  open
;;   SPC n    notes (org)    SPC t  toggle        SPC h  help
;;   SPC k    cursors        SPC m  this mode     SPC q  quit
;;   SPC x    the C-x map (meow's keypad, kept as the escape hatch)
;;
;; meow's leader keymap is `mode-specific-map' (C-c), so these also work as
;; C-c <key>.

;;; Code:

(require 'kitty-lib)
(require 'meow nil t)

(defvar meow-char-thing-table)
(defvar meow-mode-state-list)

;;;; Settings

(defun kitty--meow-settings ()
  "Options for meow; called once it is known to be installed."
  (setq meow-use-clipboard t                     ; kill ring <-> system clipboard
        meow-use-cursor-position-hack t          ; the cursor sits on the selection's last char
        meow-use-enhanced-selection-effect t     ; show multi-line selections properly
        meow-expand-hint-remove-delay 1.5
        meow-keypad-describe-delay 0.3
        meow-esc-delay 0.001
        ;; SPC c and SPC h are leader groups here (code, help); C-x stays on SPC x.
        meow-keypad-start-keys '((?x . ?x))
        ;; The keypad reads `m' and `g' as Meta and Ctrl-Meta *before* it looks
        ;; at the leader map, so SPC m (this mode's keys) and SPC g (git) would
        ;; never arrive.  M- and C-M- move to SPC M and SPC G.
        meow-keypad-meta-prefix ?M
        meow-keypad-ctrl-meta-prefix ?G
        meow-replace-state-name-list
        '((normal . "N") (motion . "M") (keypad . "K") (insert . "I") (beacon . "B")))

  ;; Where each major mode starts: terminals and shells want to type, read-only
  ;; tool buffers want their own keys (magit's `s' is stage, not `meow-kill').
  (setq meow-mode-state-list
        (append
         '((prog-mode . normal) (text-mode . normal) (conf-mode . normal)
           (fundamental-mode . normal)
           (eat-mode . insert) (eshell-mode . insert) (comint-mode . insert)
           (sql-interactive-mode . insert) (inferior-python-mode . insert)
           (help-mode . motion) (helpful-mode . motion) (Info-mode . motion)
           (special-mode . motion) (dired-mode . motion) (dirvish-mode . motion)
           (magit-mode . motion) (git-timemachine-mode . motion)
           (org-agenda-mode . motion) (compilation-mode . motion)
           (grep-mode . motion) (xref--xref-buffer-mode . motion)
           (messages-buffer-mode . motion) (Custom-mode . motion)
           (flymake-diagnostics-buffer-mode . motion)
           (flymake-project-diagnostics-mode . motion)
           (ibuffer-mode . motion) (process-menu-mode . motion)
           (tabulated-list-mode . motion) (markdown-view-mode . motion)
           (elfeed-search-mode . motion) (elfeed-show-mode . motion))
         meow-mode-state-list)))

;;;; Keys

(defun kitty--meow-setup-keys ()
  "The normal and motion state keys."
  (meow-motion-overwrite-define-key
   '("j" . meow-next)
   '("k" . meow-prev)
   '("<escape>" . ignore))
  (meow-normal-define-key
   ;; counts and expanding
   '("0" . meow-expand-0) '("1" . meow-expand-1) '("2" . meow-expand-2)
   '("3" . meow-expand-3) '("4" . meow-expand-4) '("5" . meow-expand-5)
   '("6" . meow-expand-6) '("7" . meow-expand-7) '("8" . meow-expand-8)
   '("9" . meow-expand-9)
   '("-" . negative-argument)
   ;; things: inner, bounds, beginning, end
   '(";" . meow-reverse)
   '("," . meow-inner-of-thing)
   '("." . meow-bounds-of-thing)
   '("[" . meow-beginning-of-thing)
   '("]" . meow-end-of-thing)
   ;; motion
   '("h" . meow-left) '("H" . meow-left-expand)
   '("j" . meow-next) '("J" . meow-next-expand)
   '("k" . meow-prev) '("K" . meow-prev-expand)
   '("l" . meow-right) '("L" . meow-right-expand)
   '("b" . meow-back-word) '("B" . meow-back-symbol)
   '("e" . meow-next-word) '("E" . meow-next-symbol)
   '("f" . meow-find) '("t" . meow-till)
   '("o" . meow-block) '("O" . meow-to-block)
   '("n" . meow-search) '("v" . meow-visit)
   '("/" . consult-line)
   '("Q" . meow-goto-line) '("X" . meow-goto-line)
   ;; selecting
   '("w" . meow-mark-word) '("W" . meow-mark-symbol)
   '("x" . meow-line)
   '("g" . meow-cancel-selection)
   '("z" . meow-pop-selection)
   ;; editing
   '("i" . meow-insert) '("I" . meow-open-above)
   '("a" . meow-append) '("A" . meow-open-below)
   '("c" . meow-change)
   '("d" . meow-delete) '("D" . meow-backward-delete)
   '("s" . meow-kill)
   '("y" . meow-save) '("p" . meow-yank)
   '("r" . meow-replace)
   '("m" . meow-join)
   '("u" . meow-undo) '("U" . meow-undo-in-selection)
   '("'" . repeat)
   '("q" . meow-quit)
   ;; grab: the secondary selection that scopes multiple cursors (kitty-mc.el)
   '("G" . meow-grab) '("R" . meow-swap-grab) '("Y" . meow-sync-grab)
   ;; multiple cursors
   '("C" . kitty-mc-mark-next)
   '("M" . kitty-mc-mark-all)
   ;; ex command line: :q :w :wq :e ...
   '(":" . kitty-ex)
   '("<escape>" . kitty-escape)))

(defun kitty-escape ()
  "Escape: drop the selection and any extra cursors, else do nothing."
  (interactive)
  (cond ((and (fboundp 'kitty-mc-active-p) (kitty-mc-active-p)) (kitty-mc-clear))
        ((region-active-p) (meow-cancel-selection))
        (t (ignore))))

;;;; Things: extra text objects (`,' / `.' then the key)

(defun kitty--meow-things ()
  (add-to-list 'meow-char-thing-table '(?a . angle))
  (meow-thing-register 'angle '(regexp "<" ">") '(regexp "<" ">")))

;;;; The leader tree

(defun kitty-switch-to-last-buffer ()
  "Switch to the previously selected buffer."
  (interactive)
  (switch-to-buffer (other-buffer (current-buffer) t)))

(defun kitty-find-in-config ()
  "Find a file in the kittymax configuration."
  (interactive)
  (let ((default-directory kitty-config-dir))
    (call-interactively #'project-find-file)))

(defun kitty-reload ()
  "Reload the configuration, recompiling what changed."
  (interactive)
  (dolist (m '(kitty-core kitty-ui kitty-splash kitty-meow kitty-mc kitty-ex kitty-completion kitty-vc
               kitty-dired kitty-org kitty-markdown kitty-prog kitty-rss kitty-c
               kitty-csharp kitty-sql kitty-verilog kitty-nix))
    (kitty-load m))
  (message "kittymax reloaded"))

(defun kitty-copy-file-path ()
  "Put the path of the current file on the kill ring."
  (interactive)
  (if-let* ((f (or buffer-file-name default-directory)))
      (progn (kill-new f) (message "%s" f))
    (user-error "No file")))

(defun kitty-toggle-inlay-hints ()
  "Toggle LSP inlay hints."
  (interactive)
  (if (fboundp 'eglot-inlay-hints-mode)
      (eglot-inlay-hints-mode 'toggle)
    (user-error "eglot is not loaded")))

(defun kitty--build-leader ()
  "Fill the leader keymap (`mode-specific-map')."
  (let ((m mode-specific-map))
    ;; single keys
    (define-key m (kbd "SPC") '("M-x" . execute-extended-command))
    (define-key m (kbd ":")   '("M-x" . execute-extended-command))
    (define-key m (kbd ";")   '("eval" . eval-expression))
    (define-key m (kbd ".")   '("find file" . find-file))
    (define-key m (kbd ",")   '("buffers" . consult-buffer))
    (define-key m (kbd "/")   '("ripgrep (project)" . consult-ripgrep))
    (define-key m (kbd "'")   '("resume search" . vertico-repeat))
    (define-key m (kbd "`")   '("last buffer" . kitty-switch-to-last-buffer))
    (define-key m (kbd "u")   '("universal arg" . universal-argument))
    (define-key m (kbd "m")   kitty-local-leader-binding)

    (define-key m (kbd "b")
      (kitty-prefix "buffer"
        "b" '("switch" . consult-buffer)
        "k" '("kill" . kill-current-buffer)
        "K" '("kill others" . kitty-kill-other-buffers)
        "n" '("next" . next-buffer)
        "p" '("previous" . previous-buffer)
        "s" '("save" . save-buffer)
        "S" '("save all" . save-some-buffers)
        "r" '("revert" . revert-buffer-quick)
        "l" '("list" . ibuffer)
        "h" '("home" . kitty-splash)
        "x" '("scratch" . scratch-buffer)
        "m" '("messages" . view-echo-area-messages)))

    (define-key m (kbd "f")
      (kitty-prefix "file"
        "f" '("find" . find-file)
        "r" '("recent" . consult-recent-file)
        "s" '("save" . save-buffer)
        "S" '("save as" . write-file)
        "d" '("dired" . dired-jump)
        "D" '("delete" . delete-file)
        "R" '("rename" . rename-visited-file)
        "y" '("copy path" . kitty-copy-file-path)
        "p" '("config" . kitty-find-in-config)
        "l" '("locate" . consult-locate)
        "u" '("sudo" . kitty-sudo-find-file)))

    (define-key m (kbd "p")
      (kitty-prefix "project"
        "p" '("switch" . project-switch-project)
        "f" '("find file" . project-find-file)
        "g" '("grep" . consult-ripgrep)
        "b" '("buffers" . consult-project-buffer)
        "d" '("dired" . project-dired)
        "c" '("compile" . project-compile)
        "k" '("kill buffers" . project-kill-buffers)
        "s" '("shell" . project-eshell)
        "!" '("command" . project-shell-command)
        "a" '("remember" . project-remember-projects-under)))

    (define-key m (kbd "g")
      (kitty-prefix "git"
        "g" '("status" . magit-status)
        "b" '("blame" . magit-blame-addition)
        "l" '("log" . magit-log-current)
        "L" '("log file" . magit-log-buffer-file)
        "d" '("diff" . magit-diff-dwim)
        "c" '("commit" . magit-commit)
        "C" '("clone" . magit-clone)
        "f" '("fetch" . magit-fetch)
        "F" '("pull" . magit-pull)
        "P" '("push" . magit-push)
        "s" '("stage file" . magit-stage-buffer-file)
        "u" '("unstage file" . magit-unstage-buffer-file)
        "t" '("timemachine" . git-timemachine)
        "z" '("stash" . magit-stash)
        "n" '("next hunk" . diff-hl-next-hunk)
        "p" '("previous hunk" . diff-hl-previous-hunk)
        "r" '("revert hunk" . diff-hl-revert-hunk)
        "v" '("show hunk" . diff-hl-show-hunk)))

    (define-key m (kbd "w")
      (kitty-prefix "window"
        "w" '("other" . other-window)
        "s" '("split below" . split-window-below)
        "v" '("split right" . split-window-right)
        "d" '("delete" . delete-window)
        "o" '("only" . delete-other-windows)
        "h" '("left" . windmove-left)
        "j" '("down" . windmove-down)
        "k" '("up" . windmove-up)
        "l" '("right" . windmove-right)
        "=" '("balance" . balance-windows)
        "u" '("undo layout" . winner-undo)
        "r" '("redo layout" . winner-redo)
        "t" '("transpose" . window-swap-states)))

    (define-key m (kbd "s")
      (kitty-prefix "search"
        "s" '("in buffer" . consult-line)
        "S" '("in all buffers" . consult-line-multi)
        "i" '("symbols (imenu)" . consult-imenu)
        "I" '("symbols (all buffers)" . consult-imenu-multi)
        "o" '("outline" . consult-outline)
        "r" '("ripgrep" . consult-ripgrep)
        "f" '("fd" . consult-fd)
        "m" '("marks" . consult-mark)
        "k" '("kill ring" . consult-yank-pop)
        "e" '("embark" . embark-act)))

    (define-key m (kbd "c")
      (kitty-prefix "code"
        "a" '("action" . eglot-code-actions)
        "r" '("rename" . eglot-rename)
        "f" '("format" . kitty-format)
        "d" '("definition" . xref-find-definitions)
        "D" '("references" . xref-find-references)
        "i" '("implementation" . eglot-find-implementation)
        "t" '("type" . eglot-find-typeDefinition)
        "k" '("docs" . eldoc-doc-buffer)
        "s" '("symbols" . consult-eglot-symbols)
        "e" '("errors" . consult-flymake)
        "x" '("error list" . flymake-show-buffer-diagnostics)
        "X" '("project errors" . flymake-show-project-diagnostics)
        "n" '("next error" . flymake-goto-next-error)
        "p" '("previous error" . flymake-goto-prev-error)
        "c" '("compile" . compile)
        "C" '("recompile" . recompile)
        "h" '("inlay hints" . kitty-toggle-inlay-hints)
        "R" '("restart server" . eglot-reconnect)
        "w" '("whitespace" . delete-trailing-whitespace)
        "o" '("organize imports" . eglot-code-action-organize-imports)))

    (define-key m (kbd "o")
      (kitty-prefix "open"
        "a" '("agenda" . org-agenda)
        "c" '("capture" . org-capture)
        "t" '("terminal" . kitty-terminal)
        "T" '("terminal here" . kitty-terminal-here)
        "e" '("eshell" . eshell)
        "d" '("dired" . dired-jump)
        "p" '("sidebar" . dirvish-side)
        "f" '("dirvish" . dirvish)
        "s" '("sql" . kitty-sql-connect)
        "r" '("rss" . kitty-rss)
        "R" '("rss feeds" . kitty-rss-edit-feeds)
        "m" '("markdown preview" . kitty-markdown-preview)))

    (define-key m (kbd "n")
      (kitty-prefix "notes"
        "a" '("agenda" . org-agenda)
        "c" '("capture" . org-capture)
        "f" '("find note" . kitty-org-find-file)
        "s" '("search notes" . kitty-org-search)
        "l" '("store link" . org-store-link)
        "j" '("journal" . kitty-org-journal)
        "t" '("todo list" . kitty-org-todo-list)))

    (define-key m (kbd "t")
      (kitty-prefix "toggle"
        "l" '("line numbers" . display-line-numbers-mode)
        "w" '("word wrap" . visual-line-mode)
        "z" '("zen / centered" . olivetti-mode)
        "v" '("variable pitch" . mixed-pitch-mode)
        "f" '("flymake" . flymake-mode)
        "h" '("inlay hints" . kitty-toggle-inlay-hints)
        "i" '("indent guides" . kitty-toggle-indent-guides)
        "t" '("theme flavor" . kitty-toggle-flavor)
        "s" '("spell" . kitty-toggle-spell)
        "m" '("hide markup" . kitty-markdown-toggle-markup)
        "r" '("read only" . read-only-mode)
        "c" '("hl-line" . hl-line-mode)
        "k" '("kitten on save" . kitty-cat-mode)))

    (define-key m (kbd "i")
      (kitty-prefix "insert"
        "y" '("from kill ring" . consult-yank-pop)
        "s" '("snippet" . yas-insert-snippet)
        "u" '("unicode" . insert-char)
        "e" '("emoji" . emoji-search)
        "f" '("file name" . kitty-insert-file-name)))

    (define-key m (kbd "q")
      (kitty-prefix "quit"
        "q" '("quit" . save-buffers-kill-terminal)
        "r" '("restart" . restart-emacs)
        "f" '("close frame" . delete-frame)
        "Q" '("quit without saving" . kill-emacs)))

    (define-key m (kbd "h")
      (kitty-prefix "help"
        "f" '("function" . helpful-callable)
        "v" '("variable" . helpful-variable)
        "k" '("key" . helpful-key)
        "o" '("symbol" . helpful-symbol)
        "m" '("mode" . describe-mode)
        "b" '("bindings" . embark-bindings)
        "i" '("info" . info)
        "e" '("messages" . view-echo-area-messages)
        "l" '("lossage" . view-lossage)
        "w" '("where is" . where-is)
        "a" '("apropos" . apropos)
        "t" '("meow tutorial" . meow-tutor)
        "r" '("reload config" . kitty-reload)
        "s" '("startup report" . kitty-startup-report)
        "c" '("cheatsheet" . meow-cheatsheet)))

    ;; Multiple cursors (kitty-mc.el).
    (define-key m (kbd "k")
      (kitty-prefix "cursors"
        "n" '("add next match" . kitty-mc-mark-next)
        "p" '("add previous match" . kitty-mc-mark-prev)
        "a" '("all matches" . kitty-mc-mark-all)
        "l" '("each line" . kitty-mc-mark-lines)
        "r" '("regexp in region" . kitty-mc-mark-regexp)
        "u" '("undo last" . kitty-mc-unmark-last)
        "c" '("clear" . kitty-mc-clear)))))

;;;; Helpers the tree refers to

(defun kitty-kill-other-buffers ()
  "Kill every file buffer except the current one."
  (interactive)
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (not (eq b (current-buffer))))
      (kill-buffer b))))

(defun kitty-terminal ()
  "A terminal in Emacs: eat where it works, eshell otherwise (native Windows)."
  (interactive)
  (if (and (fboundp 'eat) (not (kitty-windows-p))) (eat) (eshell)))

(defun kitty-terminal-here ()
  "A terminal at the project root."
  (interactive)
  (let ((default-directory (kitty-project-root)))
    (kitty-terminal)))

(defun kitty-sudo-find-file (file)
  "Open FILE as root through TRAMP."
  (interactive "FFind file as root: ")
  (when (kitty-windows-p) (user-error "There is no sudo on Windows"))
  (find-file (concat "/sudo:root@localhost:" (expand-file-name file))))

(defun kitty-insert-file-name ()
  "Insert the name of the current file."
  (interactive)
  (insert (file-name-nondirectory (or buffer-file-name (buffer-name)))))

(defun kitty-toggle-indent-guides ()
  "Toggle `indent-bars-mode' when it is installed."
  (interactive)
  (if (fboundp 'indent-bars-mode)
      (indent-bars-mode 'toggle)
    (user-error "indent-bars is not installed")))

(defun kitty-toggle-spell ()
  "Toggle spell checking: jinx when installed, flyspell otherwise."
  (interactive)
  (cond ((fboundp 'jinx-mode) (jinx-mode 'toggle))
        (t (flyspell-mode 'toggle))))

;;;; Start

(kitty--build-leader)
(when (featurep 'meow)
  (kitty--meow-settings)
  (kitty--meow-setup-keys)
  (kitty--meow-things)
  (meow-global-mode 1))

(provide 'kitty-meow)
;;; kitty-meow.el ends here

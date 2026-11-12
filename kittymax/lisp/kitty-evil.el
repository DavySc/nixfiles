;;; kitty-evil.el --- Vim keys, laid out as in my-nvim  -*- lexical-binding: t; -*-

;;; Commentary:

;; Neovim (my-nvim) is the main editor and the source of truth for every key:
;; kittymax is for what Emacs does best, without retraining the fingers.  So:
;;
;; - evil, with Vim's settings as my-nvim's init.lua has them (relative line
;;   numbers, smartcase, scrolloff 6, undo kept across restarts, splits to the
;;   right and below, Y yanks to the end of the line, C-u / C-d scroll);
;; - SPC is <leader>, with my-nvim's keys meaning the same thing here (ff,
;;   fg, ",", e, gg, h..., x..., u..., o a / o c ...);
;; - the LSP keys of Neovim 0.12 (grn gra grr gri, gd gD K, ]d [d, C-w d,
;;   C-s in insert mode for the signature; C-k stays Vim's digraphs);
;; - s jumps to anything on screen (flash -> avy), S grows a syntax node.
;;
;; Keys Neovim does not use carry the Emacs-only extras: SPC b buffers,
;; SPC p projects, SPC s search, SPC n notes, SPC t tools (terminal, eshell,
;; rss, sql), SPC q quit, SPC i insert, SPC H help.  Operators and text objects
;; (surround, align, comment, mini.ai's objects, multiple cursors) are in
;; kitty-vim.el.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)

(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-ex-define-cmd "evil-ex")
(declare-function evil-mode "evil-core")
(declare-function evil-collection-init "evil-collection")
(declare-function eglot-managed-p "eglot")
(defvar evil-normal-state-map)
(defvar evil-visual-state-map)
(defvar evil-motion-state-map)
(defvar evil-insert-state-map)
(defvar evil-operator-state-map)
(defvar evil-window-map)
(defvar eglot-mode-map)

;;;; Vim's settings, as in my-nvim's init.lua (set before evil loads)

(setq evil-want-keybinding nil              ; evil-collection does the modes
      evil-want-integration t
      evil-want-C-u-scroll t                ; C-u / C-d scroll, as in Vim
      evil-want-C-d-scroll t
      evil-want-C-u-delete t                ; ... and delete back in insert mode
      evil-want-C-w-delete t
      evil-want-C-i-jump t                  ; C-i / Tab: forward in the jump list
      evil-want-Y-yank-to-eol t             ; Neovim's Y
      evil-undo-system 'undo-redo           ; u / C-r
      evil-want-fine-undo nil               ; one insert session, one undo
      evil-search-module 'evil-search       ; / ? n N * # with Vim's regexps
      evil-ex-search-case 'smart            ; ignorecase + smartcase
      evil-ex-substitute-case 'smart
      evil-ex-search-vim-style-regexp t
      evil-ex-substitute-interactive-replace t ; :s previews as you type (inccommand)
      evil-cross-lines t                    ; f / t find on later lines, as flash does
      evil-split-window-below t             ; splitbelow
      evil-vsplit-window-right t            ; splitright
      evil-respect-visual-line-mode t       ; j / k by screen line where text wraps
      evil-shift-width 4                    ; shiftwidth 4
      evil-shift-round t
      evil-kill-on-visual-paste t           ; p over a selection keeps the old text
      evil-symbol-word-search nil
      evil-mode-line-format nil             ; doom-modeline shows the state
      evil-echo-state nil
      evil-default-cursor t
      evil-ex-interactive-search-highlight 'selected-window
      ;; evil-collection: SPC is the leader everywhere, and no [ ] keys of its
      ;; own (]d ]h ]C are Neovim's here).
      evil-collection-key-blacklist '("SPC" "S-SPC")
      evil-collection-want-unimpaired-p nil
      evil-collection-setup-minibuffer nil)

;; scrolloff=6: keep six lines between the cursor and the window's edge.
(setq scroll-margin 6
      scroll-conservatively 101
      scroll-preserve-screen-position t)

;; undofile: the undo history survives a restart.
(setq undo-fu-session-incompatible-files '("/COMMIT_EDITMSG\\'" "/git-rebase-todo\\'")
      undo-limit 400000
      undo-strong-limit 3000000)

;;;; Commands the keys call

(defun kitty-find-files ()
  "Find a file: in the project when there is one (recent picks first), else anywhere.
my-nvim's <leader>ff (snacks smart picker)."
  (interactive)
  (if (project-current)
      (call-interactively #'project-find-file)
    (call-interactively #'find-file)))

(defun kitty-registers ()
  "Show Vim's registers (my-nvim's <leader>fr)."
  (interactive)
  (if (fboundp 'evil-show-registers)
      (evil-show-registers)
    (call-interactively #'consult-register)))

(defun kitty-explorer ()
  "A file tree in a sidebar (my-nvim's <leader>e, the snacks explorer)."
  (interactive)
  (if (fboundp 'dirvish-side) (dirvish-side) (dired-jump)))

(defun kitty-oil ()
  "The directory of this file, cursor on it (my-nvim's `-' and <leader>pv, oil)."
  (interactive)
  (dired-jump))

(defun kitty-eval-line-or-region ()
  "Evaluate the selection, or the current line, as Emacs Lisp.
my-nvim's <leader>X runs the line as Lua; this is the Emacs side of it."
  (interactive)
  (if (use-region-p)
      (eval-region (region-beginning) (region-end) t)
    (eval-region (line-beginning-position) (line-end-position) t)))

(defun kitty-source-file ()
  "Evaluate this file (my-nvim's <space><space>x, `:source %')."
  (interactive)
  (eval-buffer)
  (message "Evaluated %s" (buffer-name)))

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
  "Reload the configuration, recompiling what changed (my-nvim's <leader>R)."
  (interactive)
  (dolist (m '(kitty-core kitty-ui kitty-splash kitty-evil kitty-vim kitty-completion kitty-vc
               kitty-dired kitty-org kitty-markdown kitty-prog kitty-rss kitty-c
               kitty-csharp kitty-sql kitty-sqldiff kitty-verilog kitty-nix))
    (kitty-load m))
  (message "kittymax reloaded"))

(defun kitty-copy-file-path ()
  "Put the path of the current file on the kill ring."
  (interactive)
  (if-let* ((f (or buffer-file-name default-directory)))
      (progn (kill-new f) (message "%s" f))
    (user-error "No file")))

(defun kitty-toggle-inlay-hints ()
  "Toggle LSP inlay hints (my-nvim's <leader>uh)."
  (interactive)
  (if (fboundp 'eglot-inlay-hints-mode)
      (eglot-inlay-hints-mode 'toggle)
    (user-error "eglot is not loaded")))

(defun kitty-undo-tree ()
  "The undo tree (my-nvim's <leader>uu)."
  (interactive)
  (if (fboundp 'vundo) (vundo) (user-error "vundo is not installed")))

(defun kitty-zen ()
  "A writing room: the text centred, nothing else (my-nvim's <leader>uz)."
  (interactive)
  (if (fboundp 'olivetti-mode) (olivetti-mode 'toggle) (user-error "olivetti is not installed")))

(defun kitty-kill-other-buffers ()
  "Kill every file buffer except the current one."
  (interactive)
  (dolist (b (buffer-list))
    (when (and (buffer-file-name b) (not (eq b (current-buffer))))
      (kill-buffer b))))

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

;;;; Diagnostics (my-nvim: ]d [d, C-w d, <leader>x...)

(defun kitty-diagnostic-at-point ()
  "Show the diagnostic under the cursor (Neovim's C-w d)."
  (interactive)
  (let ((diags (and (bound-and-true-p flymake-mode) (flymake-diagnostics (point)))))
    (if diags
        (message "%s" (mapconcat #'flymake-diagnostic-text diags "\n"))
      (display-local-help))))

(defun kitty-quickfix ()
  "Show the last list of locations: compile errors, grep or xref results.
my-nvim's <leader>xQ (the quickfix list)."
  (interactive)
  (let ((buf (or (and (buffer-live-p next-error-last-buffer) next-error-last-buffer)
                 (get-buffer "*compilation*") (get-buffer "*grep*") (get-buffer "*xref*"))))
    (if buf (pop-to-buffer buf) (user-error "No list of locations yet"))))

;;;; LSP (Neovim 0.12's keys, in buffers eglot manages)

(defun kitty-lookup ()
  "K: the documentation of the symbol at point, from the language server.
Outside eglot buffers: Vim's K (man)."
  (interactive)
  (if (and (fboundp 'eglot-managed-p) (eglot-managed-p))
      (eldoc-doc-buffer t)
    (call-interactively #'man)))

(defun kitty-signature-help ()
  "The signature of the call being typed (Neovim's C-s in insert mode)."
  (interactive)
  (eldoc-print-current-symbol-info))

;;;; Terminal (my-nvim's C-/ and <leader>ft: a terminal that pops up and away)

(defvar kitty--terminal-buffer nil)

(defun kitty-terminal ()
  "A terminal in Emacs: eat where it works, eshell otherwise (native Windows)."
  (interactive)
  (if (and (fboundp 'eat) (not (kitty-windows-p))) (eat) (eshell)))

(defun kitty-terminal-here ()
  "A terminal at the project root."
  (interactive)
  (let ((default-directory (kitty-project-root)))
    (kitty-terminal)))

(defun kitty-terminal-toggle ()
  "Show or hide a terminal at the bottom of the frame (my-nvim's C-/)."
  (interactive)
  (let ((win (and (buffer-live-p kitty--terminal-buffer)
                  (get-buffer-window kitty--terminal-buffer))))
    (if win
        (delete-window win)
      (unless (buffer-live-p kitty--terminal-buffer)
        (setq kitty--terminal-buffer
              (save-window-excursion
                (let ((default-directory (kitty-project-root)))
                  (kitty-terminal)
                  (current-buffer)))))
      (select-window
       (display-buffer-in-side-window kitty--terminal-buffer
                                      '((side . bottom) (window-height . 0.35)))))))

;;;; Git (my-nvim: <leader>g..., the gitsigns keys on <leader>h, ]h [h)

(defun kitty-hunk-stage ()
  "Stage the hunk under the cursor, or the selected lines (gitsigns' stage_hunk)."
  (interactive)
  (cond ((fboundp 'diff-hl-stage-dwim) (call-interactively #'diff-hl-stage-dwim))
        ((fboundp 'diff-hl-stage-current-hunk) (diff-hl-stage-current-hunk))
        (t (user-error "This diff-hl cannot stage hunks"))))

(defun kitty-git-browse ()
  "Open this file and line on GitHub / GitLab / Codeberg (my-nvim's <leader>gB)."
  (interactive)
  (let* ((root (or (locate-dominating-file default-directory ".git") (user-error "Not in a git repository")))
         (default-directory root)
         (remote (string-trim (shell-command-to-string "git config --get remote.origin.url")))
         (branch (string-trim (shell-command-to-string "git rev-parse --abbrev-ref HEAD")))
         (base (cond ((string-match "\\`git@\\([^:]+\\):\\(.+?\\)\\(?:\\.git\\)?\\'" remote)
                      (format "https://%s/%s" (match-string 1 remote) (match-string 2 remote)))
                     ((string-match "\\`\\(https?://.+?\\)\\(?:\\.git\\)?\\'" remote)
                      (match-string 1 remote))
                     (t (user-error "No web address for remote %s" remote))))
         (file (and buffer-file-name (file-relative-name buffer-file-name root))))
    (browse-url (if file
                    (format "%s/blob/%s/%s#L%d" base branch file (line-number-at-pos))
                  base))))

;;;; Debugging (my-nvim's <leader>d..., nvim-dap -> dape)

(defun kitty-debug-continue ()
  "Continue the debug session, or start one (nvim-dap's continue)."
  (interactive)
  (condition-case nil
      (call-interactively #'dape-continue)
    (error (call-interactively #'dape))))

;;;; Claude Code (my-nvim's <leader>a..., claudecode.nvim -> claude in a terminal)

(defvar kitty--claude-buffer nil)

(defun kitty-claude (&optional args)
  "Show or hide Claude Code in a terminal beside the code (my-nvim's <leader>ac).
ARGS are extra command-line arguments, such as \"--continue\"."
  (interactive)
  (unless (and (fboundp 'eat) (executable-find "claude"))
    (user-error "Needs eat and the `claude' command"))
  (let ((win (and (buffer-live-p kitty--claude-buffer) (get-buffer-window kitty--claude-buffer))))
    (if (and win (not args))
        (delete-window win)
      (unless (buffer-live-p kitty--claude-buffer)
        (let ((default-directory (kitty-project-root)))
          (setq kitty--claude-buffer
                (save-window-excursion
                  (eat (string-join (cons "claude" (and args (list args))) " "))
                  (current-buffer)))))
      (select-window (display-buffer-in-side-window kitty--claude-buffer
                                                    '((side . right) (window-width . 0.42)))))))

(defun kitty-claude-continue ()
  "Continue the last Claude Code session (my-nvim's <leader>aC)."
  (interactive)
  (kitty-claude "--continue"))

(defun kitty--claude-send (text)
  (unless (buffer-live-p kitty--claude-buffer) (kitty-claude))
  (with-current-buffer kitty--claude-buffer
    (eat-term-send-string eat-terminal text))
  (pop-to-buffer kitty--claude-buffer))

(defun kitty-claude-add-buffer ()
  "Add this file to Claude's context (my-nvim's <leader>ab)."
  (interactive)
  (kitty--claude-send (concat "@" (file-relative-name (or buffer-file-name (user-error "No file"))
                                                       (kitty-project-root))
                              " ")))

(defun kitty--claude-selection (prompt)
  (unless (use-region-p) (user-error "Select some code first"))
  (let ((code (buffer-substring-no-properties (region-beginning) (region-end)))
        (where (format "%s:%d-%d" (file-relative-name (or buffer-file-name (buffer-name)) (kitty-project-root))
                       (line-number-at-pos (region-beginning)) (line-number-at-pos (region-end)))))
    (deactivate-mark)
    (kitty--claude-send (format "%s(%s)\n```\n%s\n```\n" prompt where code))))

(defun kitty-claude-send ()
  "Send the selection to Claude; you write the question (my-nvim's <leader>as)."
  (interactive)
  (kitty--claude-selection ""))

(defun kitty-claude-explain ()
  "Ask Claude to explain the selection (my-nvim's <leader>ae)."
  (interactive)
  (kitty--claude-selection "Explain this code: "))

(defun kitty-claude-refactor ()
  "Ask Claude to refactor the selection (my-nvim's <leader>ar)."
  (interactive)
  (kitty--claude-selection "Refactor this code and say why: "))

(defun kitty-claude-teach ()
  "Ask Claude for learning tips about the selection (my-nvim's <leader>at)."
  (interactive)
  (kitty--claude-selection "What can I learn from this code? Tips, idioms, pitfalls: "))

;;;; The leader tree (my-nvim's <leader> keys; the extras on keys it leaves free)

(defun kitty--build-leader ()
  "Fill `kitty-leader-map'."
  (setcdr kitty-leader-map nil)
  (kitty-leader
   ;; my-nvim
   "SPC x" '("source this file" . kitty-source-file)
   ","   '("buffers" . consult-buffer)
   "e"   '("file explorer" . kitty-explorer)
   "M"   '("cursors on every match" . kitty-mc-all)
   "R"   '("reload config" . kitty-reload)
   "X"   '("run line / selection (elisp)" . kitty-eval-line-or-region)
   "m"   kitty-local-leader-binding
   ;; extras
   ":"   '("M-x" . execute-extended-command)
   ";"   '("eval" . eval-expression)
   "."   '("find file" . find-file)
   "/"   '("ripgrep (project)" . consult-ripgrep)
   "'"   '("resume search" . vertico-repeat)
   "`"   '("last buffer" . kitty-switch-to-last-buffer)
   "U"   '("universal arg" . universal-argument)

   "f" (kitty-prefix "find"
         "f" '("find files" . kitty-find-files)
         "g" '("grep" . consult-ripgrep)
         "r" '("registers" . kitty-registers)
         "t" '("floating terminal" . kitty-terminal-toggle)
         ;; extras
         "o" '("recent files" . consult-recent-file)
         "p" '("config" . kitty-find-in-config)
         "R" '("rename file" . rename-visited-file)
         "D" '("delete file" . delete-file)
         "y" '("copy path" . kitty-copy-file-path)
         "u" '("sudo" . kitty-sudo-find-file)
         "l" '("locate" . consult-locate))

   "u" (kitty-prefix "ui toggles"
         "z" '("zen" . kitty-zen)
         "u" '("undo tree" . kitty-undo-tree)
         "k" '("kitten on save" . kitty-cat-mode)
         "p" '("org pretty symbols" . kitty-org-toggle-pretty)
         "h" '("inlay hints" . kitty-toggle-inlay-hints)
         ;; extras
         "l" '("line numbers" . display-line-numbers-mode)
         "w" '("word wrap" . visual-line-mode)
         "v" '("variable pitch" . mixed-pitch-mode)
         "f" '("flymake" . flymake-mode)
         "i" '("indent guides" . kitty-toggle-indent-guides)
         "t" '("theme flavor" . kitty-toggle-flavor)
         "s" '("spell" . kitty-toggle-spell)
         "m" '("hide markup" . kitty-markdown-toggle-markup)
         "r" '("read only" . read-only-mode)
         "c" '("hl-line" . hl-line-mode))

   "x" (kitty-prefix "diagnostics"
         "x" '("project diagnostics" . flymake-show-project-diagnostics)
         "X" '("buffer diagnostics" . flymake-show-buffer-diagnostics)
         "L" '("location list" . flymake-show-buffer-diagnostics)
         "Q" '("quickfix list" . kitty-quickfix))

   "c" (kitty-prefix "code"
         "a" '("code action" . eglot-code-actions)
         "s" '("symbols" . consult-imenu)
         "l" '("references" . xref-find-references)
         ;; extras
         "f" '("format" . kitty-format)
         "c" '("compile" . compile)
         "C" '("recompile" . recompile)
         "R" '("restart server" . eglot-reconnect)
         "o" '("organize imports" . eglot-code-action-organize-imports))

   "r" (kitty-prefix "refactor"
         "n" '("rename" . eglot-rename))

   "g" (kitty-prefix "git"
         "g" '("magit" . magit-status)
         "h" '("file history" . magit-log-buffer-file)
         "H" '("repository history" . magit-log-current)
         "s" '("status" . magit-status)
         "l" '("log" . magit-log-current)
         "L" '("log (file)" . magit-log-buffer-file)
         "d" '("diff (hunks)" . magit-diff-unstaged)
         "b" '("branches" . magit-branch-checkout)
         "B" '("open on GitHub" . kitty-git-browse)
         ;; extras
         "t" '("timemachine" . git-timemachine)
         "c" '("commit" . magit-commit)
         "f" '("fetch" . magit-fetch)
         "F" '("pull" . magit-pull)
         "P" '("push" . magit-push)
         "z" '("stash" . magit-stash)
         "C" '("clone" . magit-clone))

   "h" (kitty-prefix "hunks"
         "s" '("stage hunk" . kitty-hunk-stage)
         "r" '("reset hunk" . diff-hl-revert-hunk)
         "S" '("stage buffer" . magit-stage-buffer-file)
         "u" '("undo stage" . magit-unstage-buffer-file)
         "p" '("preview hunk" . diff-hl-show-hunk)
         "b" '("blame" . magit-blame-addition)
         "d" '("diff against index" . magit-diff-buffer-file)
         "t" '("toggle line blame" . magit-blame-echo))

   "d" (kitty-prefix "debug"
         "b" '("breakpoint" . dape-breakpoint-toggle)
         "B" '("conditional breakpoint" . dape-breakpoint-expression)
         "c" '("continue / start" . kitty-debug-continue)
         "s" '("step over" . dape-next)
         "i" '("step into" . dape-step-in)
         "o" '("step out" . dape-step-out)
         "u" '("UI" . dape-info)
         "l" '("run last" . dape-restart)
         "q" '("terminate" . dape-quit)
         "e" '("eval" . dape-evaluate-expression))

   "a" (kitty-prefix "ai (Claude)"
         "c" '("toggle Claude" . kitty-claude)
         "f" '("focus Claude" . kitty-claude)
         "C" '("continue last session" . kitty-claude-continue)
         "b" '("add buffer to context" . kitty-claude-add-buffer)
         "s" '("send selection" . kitty-claude-send)
         "e" '("explain selection" . kitty-claude-explain)
         "r" '("refactor selection" . kitty-claude-refactor)
         "t" '("learning tips" . kitty-claude-teach))

   "o" (kitty-prefix "org"
         "a" '("agenda" . org-agenda)
         "c" '("capture" . org-capture))

   "p" (kitty-prefix "project"
         "v" '("file manager" . kitty-oil)
         ;; extras
         "p" '("switch project" . project-switch-project)
         "f" '("find file" . project-find-file)
         "b" '("buffers" . consult-project-buffer)
         "c" '("compile" . project-compile)
         "k" '("kill buffers" . project-kill-buffers)
         "s" '("shell" . project-eshell)
         "!" '("command" . project-shell-command))

   ;; ── Emacs-only, on prefixes my-nvim leaves free ──
   "b" (kitty-prefix "buffer"
         "k" '("kill" . kill-current-buffer)
         "K" '("kill others" . kitty-kill-other-buffers)
         "r" '("revert" . revert-buffer-quick)
         "l" '("list" . ibuffer)
         "h" '("home" . kitty-splash)
         "x" '("scratch" . scratch-buffer)
         "m" '("messages" . view-echo-area-messages))

   "s" (kitty-prefix "search"
         "s" '("in buffer" . consult-line)
         "S" '("in all buffers" . consult-line-multi)
         "i" '("symbols (all buffers)" . consult-imenu-multi)
         "o" '("outline" . consult-outline)
         "m" '("marks" . consult-mark)
         "k" '("kill ring" . consult-yank-pop)
         "e" '("embark" . embark-act))

   "n" (kitty-prefix "notes"
         "f" '("find note" . kitty-org-find-file)
         "s" '("search notes" . kitty-org-search)
         "l" '("store link" . org-store-link)
         "j" '("journal" . kitty-org-journal)
         "t" '("todo list" . kitty-org-todo-list))

   "t" (kitty-prefix "tools"
         "t" '("terminal" . kitty-terminal)
         "T" '("terminal here" . kitty-terminal-here)
         "e" '("eshell" . eshell)
         "r" '("rss" . kitty-rss)
         "R" '("rss feeds" . kitty-rss-edit-feeds)
         "s" '("sql" . kitty-sql-connect)
         "m" '("markdown preview" . kitty-markdown-preview)
         "d" '("dirvish" . dirvish))

   "i" (kitty-prefix "insert"
         "y" '("from kill ring" . consult-yank-pop)
         "s" '("snippet" . yas-insert-snippet)
         "u" '("unicode" . insert-char)
         "e" '("emoji" . emoji-search)
         "f" '("file name" . kitty-insert-file-name))

   "q" (kitty-prefix "quit"
         "q" '("quit" . save-buffers-kill-terminal)
         "r" '("restart" . restart-emacs)
         "f" '("close frame" . delete-frame)
         "Q" '("quit without saving" . kill-emacs))

   "H" (kitty-prefix "help (C-h)"
         "f" '("function" . helpful-callable)
         "v" '("variable" . helpful-variable)
         "k" '("key" . helpful-key)
         "o" '("symbol" . helpful-symbol)
         "m" '("mode" . describe-mode)
         "b" '("bindings" . embark-bindings)
         "i" '("info" . info)
         "s" '("startup report" . kitty-startup-report))))

(kitty--build-leader)

;; The leader is also on C-c SPC, for buffers evil leaves in Emacs state.
(define-key mode-specific-map (kbd "SPC") kitty-leader-binding)

;;;; evil

(defun kitty--evil-ex-commands ()
  "my-nvim's user commands, as ex commands."
  (dolist (cmd '(("Format" . kitty-format)
                 ("Ex" . kitty-oil)
                 ("Explore" . kitty-oil)
                 ("Oil" . kitty-oil)
                 ("Neogit" . magit-status)
                 ("Undotree" . kitty-undo-tree)
                 ("KittenPaw" . kitty-cat-paw)
                 ("ConfigReload" . kitty-reload)))
    (evil-ex-define-cmd (car cmd) (cdr cmd))))

(defun kitty--evil-keys ()
  "The global Vim-state keys my-nvim adds to Vim's own."
  (let ((nvm '(normal visual motion)))
    ;; <leader>
    (evil-define-key* nvm 'global (kbd "SPC") kitty-leader-binding)
    ;; flash: s jumps to anything on screen, also after an operator (ds..., ys...)
    (evil-define-key* '(normal visual operator) 'global (kbd "s") 'evil-avy-goto-char-timer)
    ;; oil
    (evil-define-key* 'normal 'global (kbd "-") #'kitty-oil)
    ;; diagnostics and hunks
    (evil-define-key* '(normal motion) 'global
      (kbd "]d") #'flymake-goto-next-error
      (kbd "[d") #'flymake-goto-prev-error
      (kbd "]h") #'diff-hl-next-hunk
      (kbd "[h") #'diff-hl-previous-hunk)
    (define-key evil-window-map (kbd "d") #'kitty-diagnostic-at-point)
    ;; the floating terminal: C-/ (terminals send it as C-_)
    (evil-define-key* '(normal motion insert emacs) 'global
      (kbd "C-/") #'kitty-terminal-toggle
      (kbd "C-_") #'kitty-terminal-toggle)
    ;; insert mode: C-s the signature, C-Space completion (C-k stays digraphs)
    (evil-define-key* 'insert 'global
      (kbd "C-s") #'kitty-signature-help
      (kbd "C-SPC") #'completion-at-point)
    ;; K: hover where a language server runs
    (setq evil-lookup-func #'kitty-lookup)))

(defun kitty--eglot-keys ()
  "Neovim 0.12's LSP keys in buffers eglot manages."
  ;; evil-collection binds gr (references) here; Neovim's gr is a prefix.
  (evil-define-key* '(normal visual) eglot-mode-map (kbd "gr") nil)
  (evil-define-key* 'normal eglot-mode-map
    (kbd "gD") #'eglot-find-declaration
    (kbd "grr") #'xref-find-references
    (kbd "gri") #'eglot-find-implementation
    (kbd "grn") #'eglot-rename
    (kbd "gra") #'eglot-code-actions
    (kbd "grt") #'eglot-find-typeDefinition
    (kbd "gO") #'consult-imenu)
  (evil-define-key* 'visual eglot-mode-map (kbd "gra") #'eglot-code-actions))

(defun kitty--evil-states ()
  "Where buffers start: typing in terminals, Vim keys everywhere else."
  (dolist (m '(eat-mode eshell-mode comint-mode sql-interactive-mode inferior-python-mode
               git-commit-mode))
    (evil-set-initial-state m 'insert)))

(defun kitty--evil-setup ()
  "Start evil, evil-collection and the keys, when evil is installed."
  (when (require 'evil nil t)
    ;; Options whose :set rebinds keys (Y, C-u ...) only take a plain setq
    ;; before evil loads; set them through customize so a reload, or evil
    ;; loaded early by something else, gets them too.
    (dolist (opt '(evil-want-Y-yank-to-eol evil-want-C-u-scroll evil-want-C-d-scroll
                   evil-want-C-u-delete evil-want-C-w-delete evil-want-C-i-jump
                   evil-undo-system evil-search-module))
      (customize-set-variable opt (symbol-value opt)))
    (evil-mode 1)
    (when (require 'evil-collection nil t)
      (evil-collection-init))
    ;; evil defines its avy motions (s) once avy is loaded.
    (require 'avy nil t)
    (kitty--evil-states)
    (kitty--evil-keys)
    (kitty--evil-ex-commands)
    (with-eval-after-load 'eglot (kitty--eglot-keys))
    (when (require 'undo-fu-session nil t)
      (undo-fu-session-global-mode 1))))

;; evil is most of kittymax's startup time (about 140 ms byte-compiled), and
;; nothing on the first screen needs it: the splash has its own keys.  During
;; startup it loads the moment Emacs first waits for a key, after the first
;; frame is drawn; every module's evil keys wait for it
;; (`with-eval-after-load'), and evil-mode switches it on in buffers already
;; open (a file named on the command line).  An idle timer, not a startup hook:
;; an error in any startup hook stops the hooks after it, and that must not
;; leave the editor without its keys.  Loaded any other time (a reload, the
;; tests), or with a file named on the command line (its first keys must
;; already be Vim's), it starts at once.
(defun kitty--files-on-command-line-p ()
  "Non-nil when Emacs was started with files to open."
  (seq-some (lambda (arg) (not (string-prefix-p "-" arg))) (cdr command-line-args)))

(if (or after-init-time (kitty--files-on-command-line-p))
    (kitty--evil-setup)
  (run-with-idle-timer 0 nil #'kitty--evil-setup))

(provide 'kitty-evil)
;;; kitty-evil.el ends here

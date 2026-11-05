;;; kitty-smoke-test.el --- load the whole configuration  -*- lexical-binding: t; -*-

;; Loads early-init.el and init.el into a fresh, empty home, with whatever
;; packages happen to be installed.  Every module must load without error,
;; whether or not the third-party packages exist: a missing package turns its
;; feature off, it must not break startup.

(require 'ert)
(require 'cl-lib)

(defvar kitty-test--root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun kitty-test--boot ()
  "Load early-init.el and init.el with state redirected to temporary directories."
  (let ((home (make-temp-file "kitty-home" t)))
    ;; packages are whatever is installed here: never reach for the network
    (setenv "KITTYMAX_PACKAGES" "none")
    (setenv "XDG_DATA_HOME" (expand-file-name "data" home))
    (setenv "XDG_CACHE_HOME" (expand-file-name "cache" home))
    (setq user-emacs-directory (file-name-as-directory kitty-test--root))
    (load (expand-file-name "early-init.el" kitty-test--root) nil t)
    (load (expand-file-name "init.el" kitty-test--root) nil t)))

(ert-deftest kitty-smoke-loads-every-module ()
  (let ((warnings nil)
        (orig (symbol-function 'display-warning)))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type message &rest args)
                 (push (format "%s: %s" type message) warnings)
                 (apply orig type message args))))
      (kitty-test--boot))
    (should-not warnings)
    (dolist (m '(kitty-core kitty-ui kitty-splash kitty-meow kitty-mc kitty-ex kitty-completion kitty-vc
                 kitty-dired kitty-org kitty-markdown kitty-prog kitty-rss kitty-c kitty-csharp
                 kitty-sql kitty-verilog kitty-nix))
      (should (assq m kitty--load-times))
      (should (featurep m)))))

(ert-deftest kitty-smoke-modules-are-byte-compiled-into-the-cache ()
  "A module that silently falls back to source costs startup time on every start."
  (unless (featurep 'kitty-core) (kitty-test--boot))
  (dolist (m '(kitty-core kitty-ui kitty-splash kitty-meow kitty-mc kitty-ex kitty-completion kitty-vc
               kitty-dired kitty-org kitty-markdown kitty-prog kitty-rss kitty-c kitty-csharp
               kitty-sql kitty-verilog kitty-nix))
    (should (file-exists-p (expand-file-name (format "elc/%s.elc" m) kitty-cache-dir)))))

(ert-deftest kitty-smoke-leader-tree ()
  (unless (featurep 'kitty-meow) (kitty-test--boot))
  (dolist (probe '(("f f" . find-file) ("b b" . consult-buffer) ("g g" . magit-status)
                   ("w v" . split-window-right) ("p f" . project-find-file)
                   ("c a" . eglot-code-actions) ("k a" . kitty-mc-mark-all)
                   ("h t" . meow-tutor) ("o a" . org-agenda) ("o r" . kitty-rss) ("SPC" . execute-extended-command)))
    (let ((b (lookup-key mode-specific-map (kbd (car probe)))))
      (should (eq (cdr probe) (if (consp b) (cdr b) b))))))

(ert-deftest kitty-smoke-local-leaders-per-language ()
  (unless (featurep 'kitty-meow) (kitty-test--boot))
  (dolist (probe '((org-mode "t" org-todo)
                   (markdown-mode "p" kitty-markdown-preview)
                   (c-ts-mode "b" kitty-c-build)
                   (c++-ts-mode "r" kitty-c-run)
                   (csharp-ts-mode "t" kitty-csharp-test)
                   (sql-mode "e" kitty-sql-send-dwim)
                   (verilog-mode "l" kitty-verilog-lint)
                   (verilog-mode "i m" verilog-sk-module)
                   (nix-ts-mode "f" kitty-format)
                   (elfeed-search-mode "a" kitty-rss-mark-all-read)))
    (let* ((map (gethash (nth 0 probe) kitty--local-leaders))
           (b (and map (lookup-key map (kbd (nth 1 probe))))))
      (should map)
      (should (eq (nth 2 probe) (if (consp b) (cdr b) b))))))

(ert-deftest kitty-smoke-state-directories-are-outside-the-checkout ()
  (unless (featurep 'kitty-core) (kitty-test--boot))
  (should-not (string-prefix-p (file-truename kitty-test--root)
                               (file-truename kitty-cache-dir)))
  (should (file-directory-p kitty-cache-dir)))

(provide 'kitty-smoke-test)
;;; kitty-smoke-test.el ends here

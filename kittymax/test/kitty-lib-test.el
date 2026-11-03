;;; kitty-lib-test.el --- tests for the loader and keymap helpers  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (file-name-as-directory (make-temp-file "kitty-cache" t)))
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)

(ert-deftest kitty-keymap-binds-keys ()
  (let ((map (kitty-keymap "a" #'ignore "b c" '("desc" . forward-char))))
    (should (eq 'ignore (lookup-key map (kbd "a"))))
    ;; "b c" is three keys: b, SPC, c
    ;; lookup-key hands back the command (which-key still sees the label)
    (should (eq 'forward-char (lookup-key map (kbd "b c"))))))

(ert-deftest kitty-prefix-labels-a-map ()
  (let ((p (kitty-prefix "things" "x" #'ignore)))
    (should (equal "things" (car p)))
    (should (keymapp (cdr p)))
    (should (eq 'ignore (lookup-key (cdr p) (kbd "x"))))))

(ert-deftest kitty-local-leader-follows-mode-inheritance ()
  (define-derived-mode kitty-test-parent-mode prog-mode "P")
  (define-derived-mode kitty-test-child-mode kitty-test-parent-mode "C")
  (kitty-local-leader 'kitty-test-parent-mode "p" #'forward-word)
  (kitty-local-leader 'kitty-test-child-mode "c" #'forward-char)
  (with-temp-buffer
    (kitty-test-child-mode)
    (let ((map (kitty--local-leader-map)))
      (should (eq 'forward-char (lookup-key map (kbd "c"))))
      (should (eq 'forward-word (lookup-key map (kbd "p"))))))
  (with-temp-buffer
    (kitty-test-parent-mode)
    (let ((map (kitty--local-leader-map)))
      (should (eq 'forward-word (lookup-key map (kbd "p"))))
      (should-not (lookup-key map (kbd "c"))))))

(ert-deftest kitty-local-leader-is-nil-without-bindings ()
  (with-temp-buffer
    (fundamental-mode)
    (should-not (kitty--local-leader-map))))

(ert-deftest kitty-local-leader-binding-resolves-in-the-leader-map ()
  (define-derived-mode kitty-test-lead-mode prog-mode "L")
  (kitty-local-leader 'kitty-test-lead-mode "z" #'forward-line)
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "m") kitty-local-leader-binding)
    (with-temp-buffer
      (kitty-test-lead-mode)
      (should (eq 'forward-line (lookup-key m (kbd "m z")))))))

(ert-deftest kitty-load-compiles-into-the-cache-and-reloads-when-stale ()
  (let* ((dir (make-temp-file "kitty-mod" t))
         (src (expand-file-name "kitty-test-mod.el" dir))
         (load-path (cons dir load-path)))
    (with-temp-file src
      (insert ";;; -*- lexical-binding: t; -*-\n(defvar kitty-test-mod-value 1)\n(provide 'kitty-test-mod)\n"))
    (kitty-load 'kitty-test-mod)
    (let ((elc (expand-file-name "elc/kitty-test-mod.elc" kitty-cache-dir)))
      (should (file-exists-p elc))
      (should (= 1 kitty-test-mod-value))
      ;; a newer source is recompiled
      (sleep-for 1.1)
      (with-temp-file src
        (insert ";;; -*- lexical-binding: t; -*-\n(setq kitty-test-mod-value 2)\n(provide 'kitty-test-mod)\n"))
      (kitty-load 'kitty-test-mod)
      (should (= 2 kitty-test-mod-value)))))

(ert-deftest kitty-load-reports-a-broken-module-and-carries-on ()
  (let* ((dir (make-temp-file "kitty-mod" t))
         (src (expand-file-name "kitty-test-broken.el" dir))
         (load-path (cons dir load-path))
         (warnings nil))
    (with-temp-file src (insert ";;; -*- lexical-binding: t; -*-\n(setq kitty-test-broken-ran t)\n(unbalanced\n"))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (should (eq 'kitty-test-broken (kitty-load 'kitty-test-broken))))
    ;; (the byte-compiler adds its own complaints about the file)
    (should (seq-find (lambda (w) (string-match-p "kitty-test-broken failed" w)) warnings))))

(ert-deftest kitty-load-reports-a-module-that-errors-when-run ()
  (let* ((dir (make-temp-file "kitty-mod" t))
         (src (expand-file-name "kitty-test-raises.el" dir))
         (load-path (cons dir load-path))
         (warnings nil))
    (with-temp-file src (insert ";;; -*- lexical-binding: t; -*-\n(error \"boom\")\n"))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (kitty-load 'kitty-test-raises))
    (should (seq-find (lambda (w) (string-match-p "boom" w)) warnings))))

(defvar kitty-test-hook nil)

(ert-deftest kitty-add-hook-contains-errors-and-keeps-going ()
  (setq kitty-test-hook nil)
  (let ((ran nil) (warnings nil))
    (kitty-add-hook 'kitty-test-hook (lambda () (error "nope")))
    (kitty-add-hook 'kitty-test-hook (lambda () (setq ran t)))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _) (push message warnings))))
      (run-hooks 'kitty-test-hook))
    (should ran)
    (should (seq-find (lambda (w) (string-match-p "nope" w)) warnings))))

(ert-deftest kitty-add-hook-does-not-stack-on-reload ()
  (setq kitty-test-hook nil)
  (defun kitty-test-hook-fn () nil)
  (kitty-add-hook 'kitty-test-hook #'kitty-test-hook-fn)
  (kitty-add-hook 'kitty-test-hook #'kitty-test-hook-fn)
  (should (= 1 (length kitty-test-hook))))

(ert-deftest kitty-project-root-falls-back-to-default-directory ()
  (let ((default-directory (file-name-as-directory (make-temp-file "plain" t))))
    (should (equal default-directory (kitty-project-root)))))

;;; kitty-lib-test.el ends here

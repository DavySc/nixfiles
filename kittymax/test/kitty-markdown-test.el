;;; kitty-markdown-test.el --- tests for kitty-markdown  -*- lexical-binding: t; -*-

(require 'ert)
(transient-mark-mode 1)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'markdown-mode)
(require 'kitty-markdown)

(defmacro kitty-test-md (text &rest body)
  "Run BODY in a gfm-mode buffer with TEXT, markup hiding on, fontified."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (gfm-mode)
     (kitty--markdown-hide-heading-hashes)
     (setq-local markdown-hide-markup nil)
     (kitty-markdown-reveal-mode 1)
     (font-lock-ensure)
     (goto-char (point-min))
     ,@body))

(defun kitty-test-hidden-at (pos)
  (and (invisible-p pos) t))

(ert-deftest kitty-markdown-hides-markup-off-the-cursor-line ()
  (kitty-test-md "first **bold** line\n\nsecond **other** line\n"
    ;; cursor on line 1: its markup is visible, line 3's is hidden
    (kitty--md-reveal-update)
    (should-not (kitty-test-hidden-at 7))               ; the ** on line 1
    (let ((line3 (save-excursion (goto-char (point-max)) (forward-line -1)
                                 (+ (point) (length "second ")))))
      (should (kitty-test-hidden-at line3)))))

(ert-deftest kitty-markdown-reveals-where-the-cursor-goes ()
  (kitty-test-md "first **bold** line\n\nsecond **other** line\n"
    (let ((line3 (save-excursion (goto-char (point-max)) (forward-line -1)
                                 (+ (point) (length "second ")))))
      (should (kitty-test-hidden-at line3))
      (goto-char line3)
      (kitty--md-reveal-update)
      (should-not (kitty-test-hidden-at line3))
      (should (kitty-test-hidden-at 7)))))

(ert-deftest kitty-markdown-toggle-off-shows-everything ()
  (kitty-test-md "a **b** c\n\n# H\n"
    (kitty-markdown-reveal-mode -1)
    (font-lock-ensure)
    (should-not (kitty-test-hidden-at 3))
    (should-not markdown-hide-markup)))

(ert-deftest kitty-markdown-headings-hide-hashes ()
  (kitty-test-md "text\n\n# Title\n\nmore\n"
    (goto-char (point-max))
    (kitty--md-reveal-update)
    (let ((hash (save-excursion (goto-char (point-min)) (search-forward "# ") (- (point) 2))))
      (should (kitty-test-hidden-at hash)))))

(ert-deftest kitty-markdown-heading-hashes-reveal-on-their-line ()
  (kitty-test-md "# Title\n\ntext\n"
    (goto-char (point-max))
    (kitty--md-reveal-update)
    (should (kitty-test-hidden-at 1))
    (goto-char (point-min))
    (kitty--md-reveal-update)
    (should-not (kitty-test-hidden-at 1))))

(ert-deftest kitty-markdown-task-item-detection ()
  (with-temp-buffer
    (insert "- [ ] one\n- [x] two\n- plain\n")
    (goto-char (point-min))
    (should (kitty--markdown-task-item-p))
    (forward-line 1) (should (kitty--markdown-task-item-p))
    (forward-line 1) (should-not (kitty--markdown-task-item-p))))

(ert-deftest kitty-markdown-gfm-for-md-files ()
  (should (eq 'gfm-mode (cdr (assoc "\\.md\\'" auto-mode-alist)))))

(ert-deftest kitty-markdown-local-leader-found-from-gfm ()
  (with-temp-buffer
    (gfm-mode)
    (let ((map (kitty--local-leader-map)))
      (should (keymapp map))
      (should (eq 'kitty-markdown-preview (lookup-key map (kbd "p")))))))

(ert-deftest kitty-markdown-clipboard-image-uses-powershell-on-windows ()
  (let (called (system-type 'windows-nt) (orig (symbol-function 'call-process)))
    (fset 'call-process (lambda (&rest args) (setq called args) 0))
    ;; only exists on a real Windows Emacs; `convert-standard-filename' calls it there
    (fset 'w32-convert-standard-filename #'identity)
    (unwind-protect
        (progn
          (should (= 0 (kitty-markdown--save-clipboard-image "C:/notes/it's.png")))
          (should (equal "powershell" (car called)))
          (let ((cmd (car (last called))))
            (should (string-match-p "GetImage" cmd))
            (should (string-match-p "C:/notes/it''s.png" cmd))))   ; quote doubled for PowerShell
      (fset 'call-process orig)
      (fmakunbound 'w32-convert-standard-filename))))

(ert-deftest kitty-markdown-clipboard-image-uses-wl-paste-elsewhere ()
  (let (cmd (system-type 'gnu/linux) (orig (symbol-function 'call-process-shell-command)))
    (fset 'call-process-shell-command (lambda (c &rest _) (setq cmd c) 0))
    (unwind-protect
        (progn (kitty-markdown--save-clipboard-image "/tmp/x y.png")
               (should (string-match-p "\\`wl-paste --type image/png > " cmd))
               (should (string-match-p "x\\\\ y.png" cmd)))
      (fset 'call-process-shell-command orig))))

;;; kitty-markdown-test.el ends here

;;; kitty-ex-test.el --- tests for the : command line  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'kitty-ex)

(defmacro kitty-ex-test-calls (&rest body)
  "Run BODY with the exit and save commands recorded instead of run.
Return the recorded calls, in order."
  `(let (calls)
     (cl-letf (((symbol-function 'save-buffers-kill-terminal) (lambda (&rest _) (push 'exit calls)))
               ((symbol-function 'kill-emacs) (lambda (&rest _) (push 'exit-now calls)))
               ((symbol-function 'save-buffer) (lambda (&rest _) (push 'save calls)))
               ((symbol-function 'write-file) (lambda (f &rest _) (push (list 'write-file f) calls)))
               ((symbol-function 'save-some-buffers) (lambda (&rest _) (push 'save-all calls))))
       ,@body)
     (nreverse calls)))

(ert-deftest kitty-ex-q-exits ()
  (should (equal '(exit) (kitty-ex-test-calls (kitty-ex-run "q"))))
  (should (equal '(exit) (kitty-ex-test-calls (kitty-ex-run ":q"))))
  (should (equal '(exit) (kitty-ex-test-calls (kitty-ex-run "qa")))))

(ert-deftest kitty-ex-q-bang-exits-without-asking ()
  (should (equal '(exit-now) (kitty-ex-test-calls (kitty-ex-run "q!")))))

(ert-deftest kitty-ex-wq-saves-a-modified-file-buffer-then-exits ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/kitty-ex-test-file")
    (insert "x")
    (should (equal '(save exit) (kitty-ex-test-calls (kitty-ex-run "wq"))))
    (should (equal '(save exit) (kitty-ex-test-calls (kitty-ex-run "x"))))
    (set-buffer-modified-p nil)
    (should (equal '(exit) (kitty-ex-test-calls (kitty-ex-run "wq"))))))

(ert-deftest kitty-ex-w ()
  (should (equal '(save) (kitty-ex-test-calls (kitty-ex-run "w"))))
  (should (equal '((write-file "/tmp/new.txt")) (kitty-ex-test-calls (kitty-ex-run "w /tmp/new.txt"))))
  (should (equal '(save-all) (kitty-ex-test-calls (kitty-ex-run "wa")))))

(ert-deftest kitty-ex-goto-line ()
  (with-temp-buffer
    (insert "a\nb\nc\nd\n")
    (kitty-ex-run "3")
    (should (= 3 (line-number-at-pos)))))

(ert-deftest kitty-ex-substitute-whole-buffer ()
  (with-temp-buffer
    (insert "foo foo\nbar foo\n")
    (kitty-ex-run "%s/foo/X/g")
    (should (equal "X X\nbar X\n" (buffer-string)))))

(ert-deftest kitty-ex-substitute-current-line-first-match ()
  (with-temp-buffer
    (insert "foo foo\nfoo\n")
    (goto-char (point-min))
    (kitty-ex-run "s/foo/X/")
    (should (equal "X foo\nfoo\n" (buffer-string)))))

(ert-deftest kitty-ex-substitute-uses-regexps-and-other-delimiters ()
  (with-temp-buffer
    (insert "a1 b22\n")
    (kitty-ex-run "%s#[0-9]+#N#g")
    (should (equal "aN bN\n" (buffer-string)))))

(ert-deftest kitty-ex-unknown-command-errors ()
  (should-error (kitty-ex-run "definitely-not-a-command") :type 'user-error))

(ert-deftest kitty-ex-falls-back-to-emacs-commands ()
  (with-temp-buffer
    (insert "abc")
    (goto-char (point-min))
    (kitty-ex-run "forward-char")
    (should (= 2 (point)))))

(ert-deftest kitty-ex-empty-line-is-ignored ()
  (should-not (kitty-ex-test-calls (kitty-ex-run "")) )
  (should-not (kitty-ex-test-calls (kitty-ex-run ":  "))))

(ert-deftest kitty-ex-is-bound-to-colon-in-normal-state ()
  "Only meaningful with meow loaded: the key must exist in its normal keymap."
  (skip-unless (require 'meow nil t))
  (require 'kitty-meow)
  (should (eq 'kitty-ex (lookup-key meow-normal-state-keymap (kbd ":")))))

;;; kitty-ex-test.el ends here

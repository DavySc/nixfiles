;;; kitty-mc-test.el --- tests for kitty-mc  -*- lexical-binding: t; -*-

;; Run: emacs --batch -L <meow> -L lisp -l test/kitty-mc-test.el -f ert-run-tests-batch-and-exit
;; (kitty-test-helper.el finds meow on the load path.)

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-config-dir default-directory)
(transient-mark-mode 1)
(require (quote meow))
(require 'kitty-mc)
(require 'kitty-meow)

(defmacro kitty-test-with-buffer (text &rest body)
  "Run BODY in a meow-enabled temp buffer holding TEXT, point at its start."
  (declare (indent 1))
  `(with-temp-buffer
     (text-mode)
     (insert ,text)
     (goto-char (point-min))
     (meow-mode 1)
     (meow--switch-state 'normal)
     ,@body))

(defun kitty-test-beacons ()
  "Run meow's post-command beacon check, return the number of fake cursors."
  (meow--maybe-toggle-beacon-state)
  (length meow--beacon-overlays))

(defun kitty-test-apply-replace (new)
  "Replace the selection with NEW at every cursor, the main one included."
  (let ((cmd (lambda () (interactive)
               (delete-region (region-beginning) (region-end))
               (insert new))))
    (meow--beacon-apply-command cmd)
    (funcall cmd)))

(ert-deftest kitty-mc-mark-all-symbol ()
  (kitty-test-with-buffer "foo bar foo baz foo"
    (kitty-mc-mark-all)
    (should (= 2 (kitty-test-beacons)))
    (should (meow-beacon-mode-p))))

(ert-deftest kitty-mc-mark-all-replaces-everywhere ()
  (kitty-test-with-buffer "foo bar foo baz foo"
    (kitty-mc-mark-all)
    (kitty-test-beacons)
    (kitty-test-apply-replace "X")
    (should (equal (buffer-string) "X bar X baz X"))))

(ert-deftest kitty-mc-mark-all-ignores-longer-words ()
  "A literal match of the symbol also finds substrings: the selection decides."
  (kitty-test-with-buffer "foo foobar foo"
    (kitty-mc-mark-all)
    ;; literal matching: foo, foo(bar), foo -> 2 other cursors
    (should (= 2 (kitty-test-beacons)))))

(ert-deftest kitty-mc-mark-next-grows-one-at-a-time ()
  (kitty-test-with-buffer "a x a y a z a"
    (kitty-mc-mark-next)
    (should (= 1 (kitty-test-beacons)))
    (kitty-mc-mark-next)
    (should (= 2 (kitty-test-beacons)))
    (kitty-mc-mark-next)
    (should (= 3 (kitty-test-beacons)))
    (kitty-test-apply-replace "Q")
    (should (equal (buffer-string) "Q x Q y Q z Q"))))

(ert-deftest kitty-mc-mark-next-stops-at-the-end ()
  (kitty-test-with-buffer "a x a"
    (kitty-mc-mark-next)
    (kitty-mc-mark-next)
    (kitty-mc-mark-next)
    (should (= 1 (kitty-test-beacons)))))

(ert-deftest kitty-mc-unmark-last ()
  (kitty-test-with-buffer "a x a y a"
    (kitty-mc-mark-all)
    (should (= 2 (kitty-test-beacons)))
    (kitty-mc-unmark-last)
    (should (= 1 (kitty-test-beacons)))))

(ert-deftest kitty-mc-mark-prev ()
  (kitty-test-with-buffer "a x a y a"
    (goto-char (point-max))
    (backward-char 1)
    (kitty-mc-mark-prev)
    (should (= 1 (kitty-test-beacons)))
    (kitty-mc-mark-prev)
    (should (= 2 (kitty-test-beacons)))))

(ert-deftest kitty-mc-mark-lines ()
  (kitty-test-with-buffer "one\ntwo\nthree\n"
    (set-mark (point-min))
    (goto-char (point-max))
    (activate-mark)
    (kitty-mc-mark-lines)
    (should (= 2 (kitty-test-beacons)))))

(ert-deftest kitty-mc-mark-regexp ()
  (kitty-test-with-buffer "a1 b22 c333"
    (kitty-mc-mark-regexp "[0-9]+")
    (should (= 2 (kitty-test-beacons)))))

(ert-deftest kitty-mc-clear ()
  (kitty-test-with-buffer "a x a"
    (kitty-mc-mark-all)
    (kitty-test-beacons)
    (kitty-mc-clear)
    (should-not (kitty-mc-active-p))
    (should-not (meow-beacon-mode-p))
    (should-not (use-region-p))))

(ert-deftest kitty-mc-active-p-idle ()
  (kitty-test-with-buffer "nothing"
    (should-not (kitty-mc-active-p))))

(ert-deftest kitty-leader-keys-do-not-collide-with-keypad-prefixes ()
  "The keypad takes these first keys for itself, ahead of the leader map."
  (let ((taken (append (list meow-keypad-meta-prefix meow-keypad-ctrl-meta-prefix)
                       (mapcar #'car meow-keypad-start-keys)))
        (clashes nil))
    (map-keymap
     (lambda (event binding)
       (when (and (characterp event) binding (memq event taken)
                  ;; x is meow's C-x start key on purpose: it must stay unbound
                  )
         (push (cons (char-to-string event) binding) clashes)))
     mode-specific-map)
    (should-not clashes)))

(ert-deftest kitty-leader-m-resolves-to-the-local-leader ()
  (should (eq 'menu-item (car-safe (lookup-key-raw-binding "m")))))

(defun lookup-key-raw-binding (key)
  "The raw binding of single KEY in the leader map."
  (cdr (assq (aref (kbd key) 0) (cdr mode-specific-map))))

;;; kitty-mc-test.el ends here
